"""
Motor de Huella Digital de Red, Pila TCP/IP, Firmas de Sistema Operativo y OUI MAC (`os_fingerprint_service.py`).

Diseñado para ejecutarse 100% en espacio de usuario (sin requerir `CAP_NET_RAW` ni root en contenedores Docker)
y en modo estrictamente pasivo/lectura sobre cualquier máquina activa detectada durante un barrido de red:

1. **Pila TCP/IP e ICMP (`TCP/IP Stack Fingerprinting`)**:
   - Extracción del `TTL` real en respuestas ICMP Echo Reply, cálculo del `TTL inicial` (`32`, `64`, `128`, `255`),
     estimación de saltos L3 (`hops`) y familia de pila (`Linux/Unix/BSD`, `Windows`, `Cisco/Appliance`).
   - Inspección del socket TCP conectado (`TCP_MAXSEG` -> `MSS` negociado y, en Linux, `TCP_INFO` del kernel ->
     `Window Scale` del par remoto, `TCP Timestamps`, `SACK`, `ECN` y `PMTU`).
2. **Firmas de Sistema Operativo, Banners y Descubrimiento L7 (`OS & Protocol Signatures`)**:
   - Banner SSH (`:22`, `:2222`) con mapeo de versiones exactas de Ubuntu, Debian, Windows OpenSSH, RouterOS,
     Cisco IOS, FortiOS, FreeBSD y Dropbear.
   - Cabeceras HTTP/HTTPS (`Server`, `X-Powered-By`, `WWW-Authenticate`), `<title>` HTML y certificado X.509 TLS
     (`Subject CN`, `SAN`, `Issuer`) en puertos web y de gestión (`:80`, `:443`, `:8006`, `:8443`, `:8080`, `:5000`, `:5001`).
   - Desafío público `SMB2 + NTLMSSP Type-2` sin autenticación (`:445`) para extraer la build exacta de Windows
     (`Server 2025/2022/2019/2016`, `Windows 11/10`) o Samba, nombre NetBIOS, dominio AD y FQDN DNS.
   - Consulta `NetBIOS NBSTAT` (`UDP :137`) para obtener nombre NetBIOS, grupo de trabajo y dirección MAC real
     incluso a través de subredes enrutadas L3.
   - Consulta `SNMP v2c` de lectura (`UDP :161` `public`) para `sysDescr.0`, `sysObjectID.0` y `sysName.0`.
   - Consulta `mDNS` unicast inversa (`UDP :5353`) para nombres `.local` (macOS, Linux Avahi, Raspberry Pi, impresoras).
3. **Inteligencia L2 por Dirección MAC (`IEEE OUI & Virtualization Detection`)**:
   - Normalización canónica (`00:50:56:0A:01:FF` corrigiendo octetos de 1 dígito de `arp -n` en macOS/BSD).
   - Detección de bit `U/L` (MAC localmente administrada / contenedor / SDN) y base OUI integrada de fabricantes
     CPD, hipervisores (`VMware`, `Proxmox`, `KVM/QEMU`, `Hyper-V`, `VirtualBox`, `Xen`, `Docker`), switches,
     firewalls, cabinas NAS, SAIs e impresoras.
"""

from __future__ import annotations

import html
import os
import platform
import re
import socket
import ssl
import struct
import subprocess
import time
from typing import Any, Dict, List, Optional, Tuple

from cryptography import x509

from ..logging_setup import get_logger
from .monitor import _encode_ber_length, _encode_oid

logger = get_logger(__name__)


# ==============================================================================
# 1. BASE DE CONOCIMIENTO IEEE OUI (FABRICANTES CPD, HIPERVISORES, RED E IOT)
# ==============================================================================
# Tupla: (Fabricante, categoría_sugerida_cmdb, hipervisor_o_plataforma, es_virtual)
OUI_DATABASE: Dict[str, Tuple[str, str, str, bool]] = {
    # --- Virtualización, Cloud y Contenedores ---
    "00:50:56": ("VMware, Inc.", "virtual_machine", "VMware vSphere / ESXi", True),
    "00:0C:29": ("VMware, Inc.", "virtual_machine", "VMware vSphere / ESXi", True),
    "00:05:69": ("VMware, Inc.", "virtual_machine", "VMware vSphere / ESXi", True),
    "00:1C:14": ("VMware, Inc.", "virtual_machine", "VMware vSphere / ESXi", True),
    "BC:24:11": ("Proxmox Server Solutions GmbH", "virtual_machine", "Proxmox VE (QEMU/LXC)", True),
    "52:54:00": ("QEMU / KVM Virtual NIC", "virtual_machine", "KVM / QEMU / Libvirt", True),
    "00:15:5D": ("Microsoft Corporation (Hyper-V)", "virtual_machine", "Microsoft Hyper-V", True),
    "00:03:FF": ("Microsoft Corporation (Virtual PC)", "virtual_machine", "Microsoft Hyper-V", True),
    "08:00:27": ("PCS Systemtechnik / Oracle VirtualBox", "virtual_machine", "Oracle VirtualBox", True),
    "0A:00:27": ("Oracle VirtualBox Host-Only", "virtual_machine", "Oracle VirtualBox", True),
    "00:16:3E": ("XenSource / Citrix / XCP-ng", "virtual_machine", "Xen / XCP-ng", True),
    "00:1C:42": ("Parallels, Inc.", "virtual_machine", "Parallels Desktop/Server", True),
    "02:42:AC": ("Docker Container Engine", "container_lxc", "Docker Engine", True),
    "50:6B:8D": ("Nutanix, Inc.", "virtual_machine", "Nutanix AHV", True),
    "FA:16:3E": ("OpenStack Neutron Virtual NIC", "cloud_instance", "OpenStack Cloud", True),

    # --- Electrónica de Red, Switches y Firewalls ---
    "00:00:0C": ("Cisco Systems, Inc.", "network_security", "Cisco IOS / NX-OS", False),
    "00:01:42": ("Cisco Systems, Inc.", "network_security", "Cisco IOS", False),
    "00:04:9A": ("Cisco Systems, Inc.", "network_security", "Cisco IOS", False),
    "00:09:7C": ("Cisco Systems, Inc.", "network_security", "Cisco IOS", False),
    "00:0C:85": ("Cisco Systems, Inc.", "network_security", "Cisco IOS", False),
    "00:12:43": ("Cisco Systems, Inc.", "network_security", "Cisco IOS", False),
    "00:18:BA": ("Cisco Systems, Inc.", "network_security", "Cisco IOS", False),
    "00:1B:D4": ("Cisco Systems, Inc.", "network_security", "Cisco IOS", False),
    "00:21:55": ("Cisco Systems, Inc.", "network_security", "Cisco IOS", False),
    "00:24:C4": ("Cisco Systems, Inc.", "network_security", "Cisco IOS", False),
    "00:26:0B": ("Cisco Systems, Inc.", "network_security", "Cisco IOS", False),
    "18:9C:5D": ("Cisco Systems, Inc.", "network_security", "Cisco IOS-XE", False),
    "28:94:0F": ("Cisco Systems, Inc.", "network_security", "Cisco Catalyst", False),
    "34:DB:FD": ("Cisco Systems, Inc.", "network_security", "Cisco Systems", False),
    "50:3D:E5": ("Cisco Systems, Inc.", "network_security", "Cisco Systems", False),
    "68:BC:0C": ("Cisco Systems, Inc.", "network_security", "Cisco Systems", False),
    "70:DB:98": ("Cisco Systems, Inc.", "network_security", "Cisco Systems", False),
    "84:B8:02": ("Cisco Systems, Inc.", "network_security", "Cisco Systems", False),
    "B0:7D:47": ("Cisco Systems, Inc.", "network_security", "Cisco Systems", False),
    "C8:00:84": ("Cisco Systems, Inc.", "network_security", "Cisco Systems", False),
    "F4:CF:E2": ("Cisco Systems, Inc.", "network_security", "Cisco Systems", False),
    "0C:8D:DB": ("Cisco Meraki", "network_security", "Cisco Meraki Cloud", False),
    "88:15:44": ("Cisco Meraki", "network_security", "Cisco Meraki Cloud", False),
    "E0:55:3D": ("Cisco Meraki", "network_security", "Cisco Meraki Cloud", False),

    "00:09:0F": ("Fortinet, Inc.", "network_security", "Fortinet FortiGate", False),
    "04:D5:90": ("Fortinet, Inc.", "network_security", "Fortinet FortiGate", False),
    "08:5B:0E": ("Fortinet, Inc.", "network_security", "Fortinet FortiGate", False),
    "70:4C:A5": ("Fortinet, Inc.", "network_security", "Fortinet FortiGate", False),
    "90:6C:AC": ("Fortinet, Inc.", "network_security", "Fortinet FortiGate", False),
    "E8:1C:BA": ("Fortinet, Inc.", "network_security", "Fortinet FortiGate", False),

    "00:05:85": ("Juniper Networks", "network_security", "Juniper Junos", False),
    "00:12:1E": ("Juniper Networks", "network_security", "Juniper Junos", False),
    "28:C0:DA": ("Juniper Networks", "network_security", "Juniper Junos", False),
    "54:E0:32": ("Juniper Networks", "network_security", "Juniper Junos", False),
    "84:B5:9C": ("Juniper Networks", "network_security", "Juniper Junos", False),

    "00:1B:17": ("Palo Alto Networks", "network_security", "PAN-OS Firewall", False),
    "7C:89:C1": ("Palo Alto Networks", "network_security", "PAN-OS Firewall", False),
    "D4:F4:BE": ("Palo Alto Networks", "network_security", "PAN-OS Firewall", False),
    "00:1C:7F": ("Check Point Software Technologies", "network_security", "Check Point Gaia", False),
    "00:90:7F": ("WatchGuard Technologies", "network_security", "WatchGuard Fireware", False),
    "00:1A:8C": ("Sophos Ltd", "network_security", "Sophos Firewall", False),
    "00:17:C5": ("SonicWall", "network_security", "SonicOS", False),
    "00:01:E8": ("F5 Networks, Inc.", "cluster_vip", "F5 BIG-IP", False),
    "00:23:E9": ("F5 Networks, Inc.", "cluster_vip", "F5 BIG-IP", False),

    "00:0C:42": ("MikroTikls SIA", "network_security", "MikroTik RouterOS", False),
    "08:55:31": ("MikroTikls SIA", "network_security", "MikroTik RouterOS", False),
    "18:FD:74": ("MikroTikls SIA", "network_security", "MikroTik RouterOS", False),
    "2C:C8:1B": ("MikroTikls SIA", "network_security", "MikroTik RouterOS", False),
    "48:8F:5A": ("MikroTikls SIA", "network_security", "MikroTik RouterOS", False),
    "48:A9:8A": ("MikroTikls SIA", "network_security", "MikroTik RouterOS", False),
    "4C:5E:0C": ("MikroTikls SIA", "network_security", "MikroTik RouterOS", False),
    "64:D1:54": ("MikroTikls SIA", "network_security", "MikroTik RouterOS", False),
    "6C:3B:6B": ("MikroTikls SIA", "network_security", "MikroTik RouterOS", False),
    "74:4D:28": ("MikroTikls SIA", "network_security", "MikroTik RouterOS", False),
    "B8:69:F4": ("MikroTikls SIA", "network_security", "MikroTik RouterOS", False),
    "C4:AD:34": ("MikroTikls SIA", "network_security", "MikroTik RouterOS", False),
    "CC:2D:E0": ("MikroTikls SIA", "network_security", "MikroTik RouterOS", False),
    "D4:01:C3": ("MikroTikls SIA", "network_security", "MikroTik RouterOS", False),
    "D4:CA:6D": ("MikroTikls SIA", "network_security", "MikroTik RouterOS", False),
    "DC:2C:6E": ("MikroTikls SIA", "network_security", "MikroTik RouterOS", False),
    "E4:8D:8C": ("MikroTikls SIA", "network_security", "MikroTik RouterOS", False),

    "00:15:6D": ("Ubiquiti Inc.", "network_security", "Ubiquiti UniFi / EdgeOS", False),
    "00:27:22": ("Ubiquiti Inc.", "network_security", "Ubiquiti UniFi / EdgeOS", False),
    "04:18:D6": ("Ubiquiti Inc.", "network_security", "Ubiquiti UniFi", False),
    "18:E8:29": ("Ubiquiti Inc.", "network_security", "Ubiquiti UniFi", False),
    "24:5A:4C": ("Ubiquiti Inc.", "network_security", "Ubiquiti UniFi", False),
    "24:A4:3C": ("Ubiquiti Inc.", "network_security", "Ubiquiti UniFi", False),
    "44:D9:E7": ("Ubiquiti Inc.", "network_security", "Ubiquiti UniFi", False),
    "60:22:32": ("Ubiquiti Inc.", "network_security", "Ubiquiti UniFi", False),
    "68:D7:9A": ("Ubiquiti Inc.", "network_security", "Ubiquiti UniFi", False),
    "70:A7:41": ("Ubiquiti Inc.", "network_security", "Ubiquiti UniFi", False),
    "74:83:C2": ("Ubiquiti Inc.", "network_security", "Ubiquiti UniFi", False),
    "74:AC:B9": ("Ubiquiti Inc.", "network_security", "Ubiquiti UniFi", False),
    "78:8A:20": ("Ubiquiti Inc.", "network_security", "Ubiquiti UniFi", False),
    "80:2A:A8": ("Ubiquiti Inc.", "network_security", "Ubiquiti UniFi", False),
    "B4:FB:E4": ("Ubiquiti Inc.", "network_security", "Ubiquiti UniFi", False),
    "DC:9F:DB": ("Ubiquiti Inc.", "network_security", "Ubiquiti UniFi", False),
    "E0:63:DA": ("Ubiquiti Inc.", "network_security", "Ubiquiti UniFi", False),
    "F0:9F:C2": ("Ubiquiti Inc.", "network_security", "Ubiquiti UniFi", False),
    "FC:EC:DA": ("Ubiquiti Inc.", "network_security", "Ubiquiti UniFi", False),

    "00:0B:86": ("Aruba Networks (HPE)", "network_security", "ArubaOS / HPE Networking", False),
    "00:1A:1E": ("Aruba Networks (HPE)", "network_security", "ArubaOS / HPE Networking", False),
    "18:64:72": ("Aruba Networks (HPE)", "network_security", "ArubaOS / HPE Networking", False),
    "20:4C:03": ("Aruba Networks (HPE)", "network_security", "ArubaOS / HPE Networking", False),
    "24:DE:C6": ("Aruba Networks (HPE)", "network_security", "ArubaOS / HPE Networking", False),
    "38:17:C3": ("Aruba Networks (HPE)", "network_security", "ArubaOS / HPE Networking", False),
    "40:E3:D6": ("Aruba Networks (HPE)", "network_security", "ArubaOS / HPE Networking", False),
    "6C:C2:17": ("Aruba Networks (HPE)", "network_security", "ArubaOS / HPE Networking", False),
    "94:B4:0F": ("Aruba Networks (HPE)", "network_security", "ArubaOS / HPE Networking", False),
    "B4:5D:50": ("Aruba Networks (HPE)", "network_security", "ArubaOS / HPE Networking", False),
    "D8:C7:C8": ("Aruba Networks (HPE)", "network_security", "ArubaOS / HPE Networking", False),

    "14:CC:20": ("TP-Link Systems Inc.", "network_security", "TP-Link / Omada", False),
    "50:C7:BF": ("TP-Link Systems Inc.", "network_security", "TP-Link / Omada", False),
    "60:32:B1": ("TP-Link Systems Inc.", "network_security", "TP-Link / Omada", False),
    "98:DA:C4": ("TP-Link Systems Inc.", "network_security", "TP-Link / Omada", False),
    "B0:BE:76": ("TP-Link Systems Inc.", "network_security", "TP-Link / Omada", False),
    "C0:06:C3": ("TP-Link Systems Inc.", "network_security", "TP-Link / Omada", False),
    "00:1D:AA": ("DrayTek Corp.", "network_security", "DrayTek Vigor", False),

    # --- Servidores Físicos CPD y BMC (Dell, HPE, Supermicro, Lenovo) ---
    "00:14:22": ("Dell Inc.", "physical_server", "Dell PowerEdge", False),
    "00:18:8B": ("Dell Inc.", "physical_server", "Dell PowerEdge", False),
    "00:1E:4F": ("Dell Inc.", "physical_server", "Dell PowerEdge", False),
    "00:21:9B": ("Dell Inc.", "physical_server", "Dell PowerEdge", False),
    "14:18:77": ("Dell Inc.", "physical_server", "Dell Hardware", False),
    "18:03:73": ("Dell Inc.", "physical_server", "Dell PowerEdge", False),
    "18:66:DA": ("Dell Inc.", "physical_server", "Dell PowerEdge", False),
    "24:6E:96": ("Dell Inc.", "physical_server", "Dell PowerEdge", False),
    "34:17:EB": ("Dell Inc.", "physical_server", "Dell PowerEdge", False),
    "4C:76:25": ("Dell Inc.", "physical_server", "Dell PowerEdge", False),
    "54:9F:35": ("Dell Inc.", "physical_server", "Dell PowerEdge", False),
    "74:86:7A": ("Dell Inc.", "physical_server", "Dell PowerEdge", False),
    "84:7B:EB": ("Dell Inc.", "physical_server", "Dell PowerEdge", False),
    "B0:83:FE": ("Dell Inc.", "physical_server", "Dell PowerEdge", False),
    "D0:94:66": ("Dell Inc.", "physical_server", "Dell PowerEdge", False),
    "E4:43:4B": ("Dell Inc.", "physical_server", "Dell PowerEdge", False),
    "F8:BC:12": ("Dell Inc.", "physical_server", "Dell PowerEdge", False),

    "00:17:A4": ("Hewlett Packard Enterprise (HPE)", "physical_server", "HPE ProLiant", False),
    "00:1E:0B": ("Hewlett Packard Enterprise (HPE)", "physical_server", "HPE ProLiant", False),
    "00:21:5A": ("Hewlett Packard Enterprise (HPE)", "physical_server", "HPE ProLiant", False),
    "00:25:B3": ("Hewlett Packard Enterprise (HPE)", "physical_server", "HPE ProLiant", False),
    "14:02:EC": ("Hewlett Packard Enterprise (HPE)", "physical_server", "HPE ProLiant", False),
    "2C:44:FD": ("Hewlett Packard Enterprise (HPE)", "physical_server", "HPE ProLiant", False),
    "3C:A8:2A": ("Hewlett Packard Enterprise (HPE)", "physical_server", "HPE ProLiant", False),
    "3C:D9:2B": ("Hewlett Packard Enterprise (HPE)", "physical_server", "HPE ProLiant", False),
    "48:DF:37": ("Hewlett Packard Enterprise (HPE)", "physical_server", "HPE ProLiant", False),
    "94:57:A5": ("Hewlett Packard Enterprise (HPE)", "physical_server", "HPE ProLiant", False),
    "9C:8E:99": ("Hewlett Packard Enterprise (HPE)", "physical_server", "HPE ProLiant", False),
    "B4:99:BA": ("Hewlett Packard Enterprise (HPE)", "physical_server", "HPE ProLiant", False),
    "D4:85:64": ("Hewlett Packard Enterprise (HPE)", "physical_server", "HPE ProLiant", False),
    "EC:EB:B8": ("Hewlett Packard Enterprise (HPE)", "physical_server", "HPE ProLiant", False),

    "00:25:90": ("Super Micro Computer, Inc.", "physical_server", "Supermicro Server", False),
    "00:30:48": ("Super Micro Computer, Inc.", "physical_server", "Supermicro Server", False),
    "0C:C4:7A": ("Super Micro Computer, Inc.", "physical_server", "Supermicro Server", False),
    "3C:EC:EF": ("Super Micro Computer, Inc.", "physical_server", "Supermicro Server", False),
    "7C:C2:55": ("Super Micro Computer, Inc.", "physical_server", "Supermicro Server", False),
    "AC:1F:6B": ("Super Micro Computer, Inc.", "physical_server", "Supermicro Server", False),

    "00:09:6B": ("IBM / Lenovo", "physical_server", "Lenovo ThinkSystem / IBM", False),
    "00:14:5E": ("IBM / Lenovo", "physical_server", "Lenovo ThinkSystem / IBM", False),
    "00:21:5E": ("IBM / Lenovo", "physical_server", "Lenovo ThinkSystem / IBM", False),
    "08:94:EF": ("Lenovo Enterprise", "physical_server", "Lenovo ThinkSystem", False),
    "40:F2:E9": ("Lenovo Enterprise", "physical_server", "Lenovo ThinkSystem", False),
    "5C:F3:FC": ("IBM / Lenovo", "physical_server", "Lenovo ThinkSystem", False),
    "7C:D3:0A": ("Lenovo", "physical_server", "Lenovo Hardware", False),
    "90:E2:BA": ("Intel Server / Data Center", "physical_server", "Servidor x86_64 (NIC Intel)", False),

    # --- Almacenamiento NAS / SAN y SAIs / Energía ---
    "00:11:32": ("Synology Incorporated", "storage_san_nas", "Synology DiskStation / RackStation", False),
    "90:09:D0": ("Synology Incorporated", "storage_san_nas", "Synology DiskStation / RackStation", False),
    "00:08:9B": ("QNAP Systems, Inc.", "storage_san_nas", "QNAP NAS", False),
    "24:5E:BE": ("QNAP Systems, Inc.", "storage_san_nas", "QNAP NAS", False),
    "00:A0:98": ("NetApp, Inc.", "storage_san_nas", "NetApp ONTAP", False),
    "24:A9:37": ("Pure Storage", "storage_san_nas", "Pure Storage FlashArray", False),
    "00:C0:B7": ("American Power Conversion (APC)", "floor_endpoint", "SAI / PDU APC Schneider", False),
    "28:29:86": ("Schneider Electric / APC", "floor_endpoint", "SAI / PDU APC Schneider", False),
    "00:20:85": ("Eaton Corporation", "floor_endpoint", "SAI / PDU Eaton", False),
    "00:E0:D8": ("Eaton Corporation", "floor_endpoint", "SAI / PDU Eaton", False),

    # --- Endpoints, Apple, Intel, Raspberry Pi, Impresoras e IoT ---
    "28:CD:C1": ("Raspberry Pi Trading Ltd", "floor_endpoint", "Raspberry Pi SBC", False),
    "2C:CF:67": ("Raspberry Pi Trading Ltd", "floor_endpoint", "Raspberry Pi 5 / SBC", False),
    "B8:27:EB": ("Raspberry Pi Foundation", "floor_endpoint", "Raspberry Pi SBC", False),
    "D8:3A:DD": ("Raspberry Pi Trading Ltd", "floor_endpoint", "Raspberry Pi SBC", False),
    "DC:A6:32": ("Raspberry Pi Trading Ltd", "floor_endpoint", "Raspberry Pi 4 / SBC", False),
    "E4:5F:01": ("Raspberry Pi Trading Ltd", "floor_endpoint", "Raspberry Pi 4 / SBC", False),

    "00:1C:B3": ("Apple, Inc.", "other_machine", "Apple Hardware", False),
    "28:CF:E9": ("Apple, Inc.", "other_machine", "Apple Mac / iOS", False),
    "3C:06:30": ("Apple, Inc.", "other_machine", "Apple Mac", False),
    "3C:22:FB": ("Apple, Inc.", "other_machine", "Apple Mac", False),
    "40:6C:8F": ("Apple, Inc.", "other_machine", "Apple Mac", False),
    "5C:F9:38": ("Apple, Inc.", "other_machine", "Apple Mac", False),
    "60:03:08": ("Apple, Inc.", "other_machine", "Apple Mac", False),
    "78:4F:43": ("Apple, Inc.", "other_machine", "Apple Mac", False),
    "88:66:5A": ("Apple, Inc.", "other_machine", "Apple Mac", False),
    "A4:83:E7": ("Apple, Inc.", "other_machine", "Apple Mac", False),
    "AC:BC:32": ("Apple, Inc.", "other_machine", "Apple Mac", False),
    "BC:D0:74": ("Apple, Inc.", "other_machine", "Apple Mac", False),
    "F0:18:98": ("Apple, Inc.", "other_machine", "Apple Mac", False),
    "F8:FF:C2": ("Apple, Inc.", "other_machine", "Apple Silicon Mac", False),

    "00:1B:21": ("Intel Corporate", "physical_server", "Hardware x86 (NIC Intel)", False),
    "3C:FD:FE": ("Intel Corporate", "physical_server", "Servidor x86 (Intel X710)", False),
    "48:21:0B": ("Intel Corporate", "other_machine", "Equipo x86 (NIC Intel)", False),
    "68:05:CA": ("Intel Corporate", "physical_server", "Equipo x86 (NIC Intel)", False),
    "8C:EC:4B": ("Dell / Intel NIC", "other_machine", "Equipo x86", False),
    "A0:36:9F": ("Intel Corporate", "physical_server", "Servidor x86 (NIC Intel)", False),
    "B4:96:91": ("Intel Corporate", "physical_server", "Servidor x86 (NIC Intel)", False),
    "00:E0:4C": ("Realtek Semiconductor Corp.", "other_machine", "Equipo x86 (NIC Realtek)", False),
    "FC:34:97": ("ASUSTek Computer Inc.", "other_machine", "Equipo ASUS / x86", False),

    "24:0A:C4": ("Espressif Inc. (ESP32/IoT)", "floor_endpoint", "Sensor IoT ESP32/ESP8266", False),
    "30:AE:A4": ("Espressif Inc. (ESP32/IoT)", "floor_endpoint", "Sensor IoT ESP32", False),
    "84:CC:A8": ("Espressif Inc. (ESP32/IoT)", "floor_endpoint", "Sensor IoT ESP32", False),
    "A4:CF:12": ("Espressif Inc. (ESP32/IoT)", "floor_endpoint", "Sensor IoT ESP32", False),
    "EC:FA:BC": ("Espressif Inc. (ESP32/IoT)", "floor_endpoint", "Sensor IoT ESP32", False),
    "18:68:CB": ("Hangzhou Hikvision Digital", "floor_endpoint", "Cámara IP / NVR Hikvision", False),
    "28:57:BE": ("Hangzhou Hikvision Digital", "floor_endpoint", "Cámara IP / NVR Hikvision", False),
    "44:19:B6": ("Hangzhou Hikvision Digital", "floor_endpoint", "Cámara IP / NVR Hikvision", False),
    "C0:56:E3": ("Hangzhou Hikvision Digital", "floor_endpoint", "Cámara IP / NVR Hikvision", False),
    "00:40:8C": ("Axis Communications AB", "floor_endpoint", "Cámara IP Axis", False),
    "AC:CC:8E": ("Axis Communications AB", "floor_endpoint", "Cámara IP Axis", False),
    "B8:A4:4F": ("Axis Communications AB", "floor_endpoint", "Cámara IP Axis", False),

    "00:80:77": ("Brother Industries, Ltd.", "floor_endpoint", "Impresora Brother", False),
    "30:05:5C": ("Brother Industries, Ltd.", "floor_endpoint", "Impresora Brother", False),
    "00:1E:8F": ("Canon Inc.", "floor_endpoint", "Impresora Multifunción Canon", False),
    "18:0C:AC": ("Canon Inc.", "floor_endpoint", "Impresora Multifunción Canon", False),
    "00:26:AB": ("Seiko Epson Corporation", "floor_endpoint", "Impresora Epson", False),
    "64:EB:8C": ("Seiko Epson Corporation", "floor_endpoint", "Impresora Epson", False),
    "00:00:74": ("Ricoh Company, Ltd.", "floor_endpoint", "Impresora Multifunción Ricoh", False),
    "00:07:4D": ("Zebra Technologies", "floor_endpoint", "Impresora Industrial Zebra", False),
    "48:A4:93": ("Zebra Technologies", "floor_endpoint", "Impresora Industrial Zebra", False),
}


PORT_SERVICE_NAMES: Dict[int, str] = {
    21: "ftp",
    22: "ssh",
    23: "telnet",
    25: "smtp",
    53: "dns",
    80: "http",
    88: "kerberos",
    111: "rpcbind",
    135: "msrpc",
    139: "netbios-ssn",
    161: "snmp",
    389: "ldap",
    443: "https",
    445: "microsoft-ds/smb",
    548: "afp-macos",
    631: "ipp-cups",
    636: "ldaps",
    902: "vmware-esxi",
    1433: "mssql",
    2049: "nfs",
    2222: "ssh-alt",
    2375: "docker",
    2376: "docker-tls",
    3306: "mysql",
    3389: "rdp",
    5000: "http-nas/upnp",
    5001: "https-synology",
    5432: "postgresql",
    5900: "vnc",
    5985: "winrm-http",
    5986: "winrm-https",
    6379: "redis",
    6443: "kubernetes-api",
    8006: "proxmox-ve",
    8080: "http-alt",
    8291: "mikrotik-winbox",
    8443: "https-mgmt",
    9090: "prometheus/cockpit",
    9100: "jetdirect/node-exporter",
}


# Puertos extra probados únicamente cuando el host demuestra estar vivo (para perfilar OS y rol sin penalizar IPs vacías)
ENRICHMENT_TCP_PORTS: List[int] = [
    22, 80, 443, 445, 3389, 135, 139, 5985, 8006, 902,
    8443, 8080, 5000, 5001, 8291, 9100, 548, 88, 389, 6443,
]


# ==============================================================================
# 2. NORMALIZACIÓN MAC, LECTURA ARP RÁPIDA Y CONSULTA OUI
# ==============================================================================

def normalize_mac_address(raw_mac: Optional[str]) -> Optional[str]:
    """
    Normaliza cualquier representación MAC (`0:50:56:a:1:f`, `00-50-56-0A-01-0F`, `0050.560a.010f`)
    al formato canónico `AA:BB:CC:DD:EE:FF`. Descarta `00:00:00:00:00:00` y `FF:FF:FF:FF:FF:FF`.
    """
    if not raw_mac:
        return None
    txt = raw_mac.strip()
    if not txt:
        return None

    # Formato Cisco punteado xxxx.xxxx.xxxx
    cisco_m = re.fullmatch(r"([0-9a-fA-F]{4})\.([0-9a-fA-F]{4})\.([0-9a-fA-F]{4})", txt)
    if cisco_m:
        hex12 = "".join(cisco_m.groups()).upper()
        parts = [hex12[i : i + 2] for i in range(0, 12, 2)]
    else:
        sep_m = re.search(r"([0-9a-fA-F]{1,2}(?:[:\-][0-9a-fA-F]{1,2}){5})", txt)
        if not sep_m:
            return None
        raw_parts = re.split(r"[:\-]", sep_m.group(1))
        if len(raw_parts) != 6:
            return None
        parts = [p.upper().zfill(2) for p in raw_parts]

    mac = ":".join(parts)
    if mac in ("00:00:00:00:00:00", "FF:FF:FF:FF:FF:FF"):
        return None
    return mac


def lookup_arp_mac_fast(target_ip: str) -> Optional[str]:
    """
    Obtiene la MAC L2 de `target_ip` priorizando `/proc/net/arp` en Linux (sin lanzar subprocesos)
    y cayendo a `ip neigh` / `arp -n` en macOS o sistemas sin procfs.
    """
    # 1. Lectura directa en memoria de /proc/net/arp (Linux / Contenedores Docker)
    proc_arp = "/proc/net/arp"
    if os.path.exists(proc_arp):
        try:
            with open(proc_arp, "r", encoding="utf-8", errors="ignore") as fh:
                for line in fh.readlines()[1:]:
                    cols = line.split()
                    if len(cols) >= 4 and cols[0] == target_ip:
                        flags = cols[2].lower()
                        if flags == "0x0":
                            continue
                        mac_norm = normalize_mac_address(cols[3])
                        if mac_norm:
                            return mac_norm
        except OSError:
            pass

    # 2. Fallback multiplataforma (macOS / BSD / iproute2)
    for cmd in (["ip", "neigh", "show", target_ip], ["arp", "-n", target_ip]):
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=1.2)
            out = f"{proc.stdout or ''} {proc.stderr or ''}"
            low = out.lower()
            if "incomplete" in low or "failed" in low or "no entry" in low:
                continue
            mac_norm = normalize_mac_address(out)
            if mac_norm:
                return mac_norm
        except Exception:
            continue
    return None


def lookup_mac_vendor(raw_mac: Optional[str]) -> Dict[str, Any]:
    """
    Analiza los primeros 3 octetos (OUI IEEE) y el bit U/L de la dirección MAC para identificar
    fabricante hardware, hipervisor virtual o interfaz de contenedor/SDN.
    """
    mac = normalize_mac_address(raw_mac)
    if not mac:
        return {
            "mac_address": "",
            "oui_prefix": "",
            "vendor": "",
            "category_hint": "",
            "platform_hint": "",
            "is_virtual": False,
            "is_locally_administered": False,
        }

    oui = mac[:8]
    first_byte = int(mac[:2], 16)
    is_local_admin = bool(first_byte & 0x02)

    if oui in OUI_DATABASE:
        vendor, cat_hint, plat_hint, is_virt = OUI_DATABASE[oui]
        return {
            "mac_address": mac,
            "oui_prefix": oui,
            "vendor": vendor,
            "category_hint": cat_hint,
            "platform_hint": plat_hint,
            "is_virtual": is_virt,
            "is_locally_administered": is_local_admin,
        }

    if is_local_admin:
        return {
            "mac_address": mac,
            "oui_prefix": oui,
            "vendor": "MAC Virtual / Localmente Administrada (VM, Contenedor, Cloud o Privacidad Wi-Fi)",
            "category_hint": "virtual_machine",
            "platform_hint": "Interfaz Virtual / SDN",
            "is_virtual": True,
            "is_locally_administered": True,
        }

    return {
        "mac_address": mac,
        "oui_prefix": oui,
        "vendor": f"Fabricante OUI {oui}",
        "category_hint": "",
        "platform_hint": "",
        "is_virtual": False,
        "is_locally_administered": False,
    }


# ==============================================================================
# 3. PILA TCP/IP E ICMP (`TTL`, `MSS`, `WINDOW SCALE`, `TIMESTAMPS`, `SACK`)
# ==============================================================================

def classify_icmp_ttl(ttl: Optional[int]) -> Dict[str, Any]:
    """
    Deduce el `TTL inicial` de la pila IP remota (`32`, `64`, `128` o `255`),
    los saltos de router aproximados y la familia de sistema operativo asociada.
    """
    if ttl is None or ttl <= 0:
        return {
            "icmp_ttl": None,
            "initial_ttl": None,
            "estimated_hops": None,
            "ttl_family": "unknown",
            "ttl_os_hint": "",
        }
    if ttl <= 32:
        init_ttl = 32
        fam = "embedded"
        hint = "Pila Embebida / Industrial Legacy (TTL base 32)"
    elif ttl <= 64:
        init_ttl = 64
        fam = "unix_linux"
        hint = "Linux / Unix / macOS / BSD / Appliance de Red (TTL base 64)"
    elif ttl <= 128:
        init_ttl = 128
        fam = "windows"
        hint = "Microsoft Windows Server / Desktop (TTL base 128)"
    else:
        init_ttl = 255
        fam = "network_os"
        hint = "Cisco IOS / Juniper / Hardware Switch-Router / Solaris (TTL base 255)"

    return {
        "icmp_ttl": ttl,
        "initial_ttl": init_ttl,
        "estimated_hops": max(0, init_ttl - ttl),
        "ttl_family": fam,
        "ttl_os_hint": hint,
    }


def probe_icmp_with_ttl(target_ip: str, timeout_sec: float = 0.5) -> Dict[str, Any]:
    """
    Ejecuta un Echo Request ICMP real (`ping -c 1`) capturando tanto la latencia en ms
    como el `TTL` devuelto por la pila IP de la máquina remota.
    """
    is_mac = platform.system().lower() == "darwin"
    wait_arg = str(max(200, int(timeout_sec * 1000))) if is_mac else str(max(1, int(round(timeout_sec))))
    cmd = ["ping", "-c", "1", "-W", wait_arg, target_ip]

    start = time.perf_counter()
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout_sec + 1.0,
        )
        elapsed_ms = round((time.perf_counter() - start) * 1000.0, 2)
        stdout = proc.stdout or ""
        if proc.returncode == 0:
            t_match = re.search(r"time[=<]([\d\.]+)\s*ms", stdout, re.IGNORECASE)
            ping_ms = round(float(t_match.group(1)), 2) if t_match else elapsed_ms
            ttl_match = re.search(r"\b(?:ttl|hlim)=(\d+)\b", stdout, re.IGNORECASE)
            ttl_val = int(ttl_match.group(1)) if ttl_match else None
            ttl_info = classify_icmp_ttl(ttl_val)
            ttl_suffix = (
                f", TTL={ttl_val} [base {ttl_info['initial_ttl']}, {ttl_info['estimated_hops']} salto(s)]"
                if ttl_val is not None
                else ""
            )
            return {
                "alive": True,
                "latency_ms": ping_ms,
                "ttl": ttl_val,
                "ttl_info": ttl_info,
                "detail": f"[ICMP] Ping OK desde {target_ip} ({ping_ms} ms{ttl_suffix})",
            }
        return {
            "alive": False,
            "latency_ms": None,
            "ttl": None,
            "ttl_info": classify_icmp_ttl(None),
            "detail": f"[ICMP] Host {target_ip} sin respuesta Ping",
        }
    except Exception as exc:
        return {
            "alive": False,
            "latency_ms": None,
            "ttl": None,
            "ttl_info": classify_icmp_ttl(None),
            "detail": f"[ICMP] Error sondeando {target_ip}: {exc}",
        }


def _extract_socket_tcp_stack_metrics(sock: socket.socket) -> Dict[str, Any]:
    """
    Inspecciona en espacio de usuario las opciones negociadas en el handshake `SYN -> SYN-ACK`
    del socket conectado (`MSS`, `Window Scale` del par, `Timestamps`, `SACK`, `ECN` y `PMTU`).
    """
    metrics: Dict[str, Any] = {
        "tcp_mss": None,
        "peer_window_scale": None,
        "tcp_timestamps": None,
        "tcp_sack": None,
        "tcp_ecn": None,
        "pmtu": None,
    }
    try:
        tcp_maxseg = getattr(socket, "TCP_MAXSEG", 2)
        mss = sock.getsockopt(socket.IPPROTO_TCP, tcp_maxseg)
        if isinstance(mss, int) and 64 <= mss <= 65535:
            metrics["tcp_mss"] = mss
    except OSError:
        pass

    # En Linux (`rackdoc-backend` contenedor Debian), `TCP_INFO` (11) expone `struct tcp_info` del kernel
    if platform.system().lower() == "linux":
        try:
            tcp_info_opt = getattr(socket, "TCP_INFO", 11)
            raw = sock.getsockopt(socket.IPPROTO_TCP, tcp_info_opt, 104)
            if len(raw) >= 32:
                tcpi_options = raw[5]
                wscale_byte = raw[6]
                # En little-endian (x86_64 y arm64): bits 0..3 = snd_wscale (anunciado por el peer en SYN-ACK)
                peer_wscale = wscale_byte & 0x0F
                metrics["tcp_timestamps"] = bool(tcpi_options & 0x01)
                metrics["tcp_sack"] = bool(tcpi_options & 0x02)
                has_wscale = bool(tcpi_options & 0x04)
                metrics["tcp_ecn"] = bool(tcpi_options & 0x08)
                metrics["peer_window_scale"] = peer_wscale if has_wscale else 0
                # offset 24 = tcpi_pmtu (uint32)
                pmtu = struct.unpack_from("I", raw, 24)[0]
                if 500 <= pmtu <= 9216:
                    metrics["pmtu"] = pmtu
        except OSError:
            pass

    return metrics


def probe_tcp_port_with_stack(
    target_ip: str,
    port: int,
    timeout_sec: float = 0.35,
) -> Dict[str, Any]:
    """
    Intenta handshake TCP contra `target_ip:port`. Si abre (`SYN-ACK`), extrae además
    las métricas de la pila TCP/IP negociadas en ese socket antes de cerrarlo.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout_sec)
    try:
        sock.connect((target_ip, port))
        stack = _extract_socket_tcp_stack_metrics(sock)
        banner_peek = ""
        # Si es un protocolo donde el servidor envía saludo inmediato (SSH/FTP/SMTP), leerlo al vuelo
        if port in (21, 22, 25, 2222):
            try:
                sock.settimeout(min(0.35, timeout_sec))
                raw_b = sock.recv(160)
                if raw_b:
                    banner_peek = raw_b.decode("utf-8", errors="ignore").splitlines()[0].strip()[:140]
            except OSError:
                pass
        return {
            "port": port,
            "state": "open",
            "stack": stack,
            "banner": banner_peek,
        }
    except Exception:
        return {
            "port": port,
            "state": "filtered_or_down",
            "stack": {},
            "banner": "",
        }
    finally:
        try:
            sock.close()
        except OSError:
            pass


# ==============================================================================
# 4. SONDAS L7 SOLO-LECTURA DE FIRMA DE OS (SSH, HTTP/TLS, SMB/NTLMSSP, NBSTAT, SNMP, mDNS)
# ==============================================================================

def parse_ssh_banner_os(banner: str) -> Tuple[str, str, str]:
    """
    Traduce un banner `SSH-2.0-...` a `(os_guess, os_family, device_type)`.
    """
    if not banner:
        return ("", "", "")
    b = banner.strip()
    low = b.lower()

    if "ubuntu" in low:
        if "3ubuntu13" in low or "openssh_9.6" in low or "openssh_9.7" in low:
            return ("Ubuntu Linux 24.04 LTS (Noble)", "linux", "Servidor Linux")
        if "3ubuntu0" in low or "openssh_8.9" in low:
            return ("Ubuntu Linux 22.04 LTS (Jammy)", "linux", "Servidor Linux")
        if "4ubuntu0" in low or "openssh_8.2" in low:
            return ("Ubuntu Linux 20.04 LTS (Focal)", "linux", "Servidor Linux")
        if "openssh_7.6" in low:
            return ("Ubuntu Linux 18.04 LTS", "linux", "Servidor Linux")
        return ("Ubuntu Linux", "linux", "Servidor Linux")

    if "debian" in low or "+deb" in low:
        if "deb13" in low:
            return ("Debian GNU/Linux 13 (Trixie)", "linux", "Servidor Linux")
        if "deb12" in low or "openssh_9.2p1 debian" in low:
            return ("Debian GNU/Linux 12 (Bookworm)", "linux", "Servidor Linux")
        if "deb11" in low or "openssh_8.4p1 debian" in low:
            return ("Debian GNU/Linux 11 (Bullseye)", "linux", "Servidor Linux")
        if "deb10" in low:
            return ("Debian GNU/Linux 10 (Buster)", "linux", "Servidor Linux")
        return ("Debian GNU/Linux", "linux", "Servidor Linux")

    if "openssh_for_windows" in low:
        return ("Microsoft Windows (OpenSSH Server)", "windows", "Servidor / Host Windows")
    if "rosssh" in low:
        return ("MikroTik RouterOS", "network_os", "Router / Switch MikroTik")
    if "cisco" in low:
        return ("Cisco IOS / IOS-XE", "network_os", "Switch / Router Cisco")
    if "fortissh" in low or "fortios" in low:
        return ("Fortinet FortiOS", "network_os", "Firewall FortiGate")
    if "freebsd" in low:
        return ("FreeBSD / pfSense / OPNsense", "bsd", "Servidor / Appliance BSD")
    if "vmware" in low:
        return ("VMware ESXi Hypervisor", "hypervisor", "Hipervisor VMware ESXi")
    if "dropbear" in low:
        return ("Linux Embebido / OpenWrt / Ubiquiti (Dropbear)", "linux", "Appliance Linux / Red")
    if "sun_ssh" in low:
        return ("Oracle Solaris / Illumos", "unix", "Servidor Unix Solaris")
    if "openssh" in low:
        m = re.search(r"OpenSSH_([\d\.p]+)", b, re.IGNORECASE)
        ver = f" (OpenSSH {m.group(1)})" if m else ""
        return (f"Linux / Unix{ver}", "linux", "Servidor Linux / Unix")
    return ("", "", "")


def _probe_http_and_tls_signature(
    target_ip: str,
    port: int,
    use_tls: bool,
    timeout_sec: float = 0.55,
) -> Dict[str, Any]:
    """
    Envía `GET / HTTP/1.1` de lectura y, si es HTTPS, inspecciona el certificado X.509
    para extraer `Server`, `X-Powered-By`, `<title>`, `TLS Subject CN`, `SAN` e `Issuer`.
    """
    info: Dict[str, Any] = {
        "port": port,
        "tls": use_tls,
        "status_code": None,
        "server": "",
        "powered_by": "",
        "www_authenticate": "",
        "title": "",
        "tls_cn": "",
        "tls_sans": [],
        "tls_issuer": "",
    }
    raw_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    raw_sock.settimeout(timeout_sec)
    conn: socket.socket = raw_sock
    try:
        raw_sock.connect((target_ip, port))
        if use_tls:
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            tls_sock = ctx.wrap_socket(raw_sock, server_hostname=target_ip)
            conn = tls_sock
            der_cert = tls_sock.getpeercert(binary_form=True)
            if der_cert:
                try:
                    cert = x509.load_der_x509_certificate(der_cert)
                    cns = cert.subject.get_attributes_for_oid(x509.oid.NameOID.COMMON_NAME)
                    if cns:
                        info["tls_cn"] = str(cns[0].value).strip()
                    iss_cn = cert.issuer.get_attributes_for_oid(x509.oid.NameOID.COMMON_NAME)
                    iss_org = cert.issuer.get_attributes_for_oid(x509.oid.NameOID.ORGANIZATION_NAME)
                    iss_parts = []
                    if iss_org:
                        iss_parts.append(str(iss_org[0].value).strip())
                    if iss_cn:
                        iss_parts.append(str(iss_cn[0].value).strip())
                    info["tls_issuer"] = " / ".join(dict.fromkeys(p for p in iss_parts if p))
                    try:
                        san_ext = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName)
                        dns_names = [
                            n.strip()
                            for n in san_ext.value.get_values_for_type(x509.DNSName)
                            if n and n.strip() and n.strip() != "localhost"
                        ]
                        info["tls_sans"] = dns_names[:6]
                    except x509.ExtensionNotFound:
                        pass
                except Exception:
                    pass

        req_bytes = (
            f"GET / HTTP/1.1\r\n"
            f"Host: {target_ip}\r\n"
            f"User-Agent: RackDoc-Discovery/1.4\r\n"
            f"Accept: text/html,*/*\r\n"
            f"Connection: close\r\n\r\n"
        ).encode("ascii", errors="ignore")
        conn.sendall(req_bytes)

        chunks: List[bytes] = []
        total = 0
        while total < 6144:
            try:
                piece = conn.recv(2048)
            except OSError:
                break
            if not piece:
                break
            chunks.append(piece)
            total += len(piece)
        resp_txt = b"".join(chunks).decode("utf-8", errors="ignore")
        if resp_txt:
            head_part, _, body_part = resp_txt.partition("\r\n\r\n")
            lines = head_part.splitlines()
            if lines:
                st_m = re.match(r"HTTP/\d(?:\.\d)?\s+(\d{3})", lines[0])
                if st_m:
                    info["status_code"] = int(st_m.group(1))
            for hline in lines[1:]:
                k, sep, v = hline.partition(":")
                if not sep:
                    continue
                kl = k.strip().lower()
                val = v.strip()[:120]
                if kl == "server" and not info["server"]:
                    info["server"] = val
                elif kl == "x-powered-by" and not info["powered_by"]:
                    info["powered_by"] = val
                elif kl == "www-authenticate" and not info["www_authenticate"]:
                    info["www_authenticate"] = val

            t_m = re.search(r"<title[^>]*>(.*?)</title>", body_part or resp_txt, re.IGNORECASE | re.DOTALL)
            if t_m:
                clean_t = re.sub(r"\s+", " ", html.unescape(t_m.group(1))).strip()
                info["title"] = clean_t[:120]
    except Exception:
        pass
    finally:
        try:
            conn.close()
        except OSError:
            pass
    return info


def _map_windows_nt_build(major: int, minor: int, build: int) -> str:
    """Traduce `Major.Minor.Build` devuelto por el desafío NTLMSSP a versión legible de Windows."""
    if major == 10 and minor == 0:
        if build >= 26100:
            return f"Windows Server 2025 / Windows 11 24H2 (Build {build})"
        if build >= 22000:
            return f"Windows 11 / Windows Server Insider (Build {build})"
        if build == 20348:
            return "Windows Server 2022 (Build 20348)"
        if build >= 19041:
            return f"Windows 10 20H1–22H2 (Build {build})"
        if build == 17763:
            return "Windows Server 2019 / Windows 10 LTSC (Build 17763)"
        if build == 14393:
            return "Windows Server 2016 (Build 14393)"
        return f"Microsoft Windows 10 / Server (Build {build})"
    if major == 6:
        if minor == 3:
            return f"Windows Server 2012 R2 / Windows 8.1 (Build {build})"
        if minor == 2:
            return f"Windows Server 2012 / Windows 8 (Build {build})"
        if minor == 1:
            return f"Windows Server 2008 R2 / Windows 7 (Build {build})"
        if minor == 0:
            return f"Windows Server 2008 / Vista (Build {build})"
    if major == 5:
        return f"Windows Server 2003 / XP Legacy (Build {build})"
    return ""


def _probe_smb_ntlmssp_challenge(target_ip: str, timeout_sec: float = 0.55) -> Dict[str, Any]:
    """
    Inspecciona pasivamente el desafío `SMB2 SESSION_SETUP -> NTLMSSP_CHALLENGE (Type 2)` en `:445`
    sin enviar credenciales (cero intentos de login), extrayendo:
    - Versión exacta del kernel NT (`Major.Minor.Build`) o presencia de Samba.
    - Nombre NetBIOS del equipo, Dominio NetBIOS, FQDN DNS y Dominio AD/DNS.
    """
    result: Dict[str, Any] = {
        "responded": False,
        "os_string": "",
        "os_family": "",
        "nb_computer": "",
        "nb_domain": "",
        "dns_computer": "",
        "dns_domain": "",
    }

    # 1) Paquete SMB2 NEGOTIATE (Dialectos 0x0202, 0x0210, 0x0300, 0x0302, 0x0311)
    smb2_neg_hdr = (
        b"\xfeSMB"
        + struct.pack("<H", 64)       # Header length
        + struct.pack("<H", 0)        # CreditCharge
        + struct.pack("<I", 0)        # Status
        + struct.pack("<H", 0)        # Command = NEGOTIATE (0)
        + struct.pack("<H", 1)        # Credits
        + struct.pack("<I", 0)        # Flags
        + struct.pack("<I", 0)        # NextCommand
        + struct.pack("<Q", 0)        # MessageId = 0
        + struct.pack("<I", 0)        # ProcessId
        + struct.pack("<I", 0)        # TreeId
        + struct.pack("<Q", 0)        # SessionId
        + (b"\x00" * 16)              # Signature
    )
    dialects = struct.pack("<5H", 0x0202, 0x0210, 0x0300, 0x0302, 0x0311)
    smb2_neg_body = (
        struct.pack("<H", 36)         # StructureSize
        + struct.pack("<H", 5)        # DialectCount = 5
        + struct.pack("<H", 1)        # SecurityMode = Signing Enabled
        + struct.pack("<H", 0)        # Reserved
        + struct.pack("<I", 0)        # Capabilities
        + (b"\x11" * 16)              # ClientGuid
        + struct.pack("<Q", 0)        # NegotiateContextOffset/Reserved2
        + dialects
    )
    neg_pkt = struct.pack(">I", len(smb2_neg_hdr) + len(smb2_neg_body)) + smb2_neg_hdr + smb2_neg_body

    # 2) Paquete SMB2 SESSION_SETUP con NTLMSSP_NEGOTIATE (Type 1) mínimo en crudo
    ntlm_type1 = (
        b"NTLMSSP\x00"
        + struct.pack("<I", 1)            # MessageType = 1 (Negotiate)
        + struct.pack("<I", 0x02088207)   # Flags: UNICODE | REQUEST_TARGET | NTLM | ALWAYS_SIGN | TARGET_INFO | VERSION
        + struct.pack("<HHI", 0, 0, 0)    # DomainNameFields
        + struct.pack("<HHI", 0, 0, 0)    # WorkstationFields
        + struct.pack("<BBHBBBB", 10, 0, 19041, 0, 0, 0, 15)  # Version (8 bytes)
    )
    # Envolver en SPNEGO NegTokenInit mínimo (OID NTLMSSP 1.3.6.1.4.1.311.2.2.10) para compatibilidad universal
    ntlm_oid = b"\x06\x0a\x2b\x06\x01\x04\x01\x82\x37\x02\x02\x0a"
    mech_types = b"\x30" + bytes([len(ntlm_oid)]) + ntlm_oid
    mech_field = b"\xa0" + bytes([len(mech_types)]) + mech_types
    tok_oct = b"\x04" + bytes([len(ntlm_type1)]) + ntlm_type1
    tok_field = b"\xa2" + bytes([len(tok_oct)]) + tok_oct
    neg_tok_seq = b"\x30" + bytes([len(mech_field) + len(tok_field)]) + mech_field + tok_field
    neg_tok_ctx = b"\xa0" + bytes([len(neg_tok_seq)]) + neg_tok_seq
    spnego_oid = b"\x06\x06\x2b\x06\x01\x05\x05\x02"
    gss_blob = b"\x60" + bytes([len(spnego_oid) + len(neg_tok_ctx)]) + spnego_oid + neg_tok_ctx

    smb2_sess_hdr = (
        b"\xfeSMB"
        + struct.pack("<H", 64)
        + struct.pack("<H", 0)
        + struct.pack("<I", 0)
        + struct.pack("<H", 1)        # Command = SESSION_SETUP (1)
        + struct.pack("<H", 1)
        + struct.pack("<I", 0)
        + struct.pack("<I", 0)
        + struct.pack("<Q", 1)        # MessageId = 1
        + struct.pack("<I", 0)
        + struct.pack("<I", 0)
        + struct.pack("<Q", 0)
        + (b"\x00" * 16)
    )
    sec_offset = 64 + 24
    smb2_sess_body = (
        struct.pack("<H", 25)         # StructureSize = 25
        + struct.pack("<B", 0)        # Flags
        + struct.pack("<B", 1)        # SecurityMode
        + struct.pack("<I", 0)        # Capabilities
        + struct.pack("<I", 0)        # Channel
        + struct.pack("<H", sec_offset)
        + struct.pack("<H", len(gss_blob))
        + struct.pack("<Q", 0)        # PreviousSessionId
        + gss_blob
    )
    sess_pkt = struct.pack(">I", len(smb2_sess_hdr) + len(smb2_sess_body)) + smb2_sess_hdr + smb2_sess_body

    def _recv_netbios_frame(s: socket.socket) -> bytes:
        hdr4 = b""
        while len(hdr4) < 4:
            chunk = s.recv(4 - len(hdr4))
            if not chunk:
                return b""
            hdr4 += chunk
        length = struct.unpack(">I", hdr4)[0] & 0x00FFFFFF
        if length == 0 or length > 65536:
            return b""
        payload = b""
        while len(payload) < length:
            chunk = s.recv(min(4096, length - len(payload)))
            if not chunk:
                break
            payload += chunk
        return payload

    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout_sec)
    try:
        sock.connect((target_ip, 445))
        sock.sendall(neg_pkt)
        neg_resp = _recv_netbios_frame(sock)
        if not neg_resp or not neg_resp.startswith(b"\xfeSMB"):
            return result

        sock.sendall(sess_pkt)
        sess_resp = _recv_netbios_frame(sock)
        if not sess_resp:
            return result

        idx = sess_resp.find(b"NTLMSSP\x00\x02\x00\x00\x00")
        if idx < 0:
            return result

        result["responded"] = True
        ntlm = sess_resp[idx:]
        if len(ntlm) < 48:
            return result

        flags = struct.unpack_from("<I", ntlm, 20)[0]
        ti_len, _ti_max, ti_off = struct.unpack_from("<HHI", ntlm, 40)

        # Versión del sistema operativo NT en offset 48 si el servidor soporta NTLMSSP_NEGOTIATE_VERSION (0x02000000)
        has_version = bool(flags & 0x02000000) and len(ntlm) >= 56 and (ti_off == 0 or ti_off >= 56)
        if has_version:
            ver_major, ver_minor, ver_build = struct.unpack_from("<BBH", ntlm, 48)
            if ver_major > 0:
                mapped = _map_windows_nt_build(ver_major, ver_minor, ver_build)
                if mapped:
                    result["os_string"] = mapped
                    result["os_family"] = "windows"

        # Parsear AV_PAIRs en TargetInfo (nombres NetBIOS y DNS)
        if ti_len > 0 and 48 <= ti_off < len(ntlm) and ti_off + ti_len <= len(ntlm):
            pos = ti_off
            end = ti_off + ti_len
            while pos + 4 <= end:
                av_id, av_len = struct.unpack_from("<HH", ntlm, pos)
                pos += 4
                if av_id == 0 or pos + av_len > end:
                    break
                raw_val = ntlm[pos : pos + av_len]
                pos += av_len
                if av_id in (1, 2, 3, 4):
                    txt = raw_val.decode("utf-16le", errors="ignore").strip("\x00").strip()
                    if av_id == 1:
                        result["nb_computer"] = txt
                    elif av_id == 2:
                        result["nb_domain"] = txt
                    elif av_id == 3:
                        result["dns_computer"] = txt
                    elif av_id == 4:
                        result["dns_domain"] = txt

        # Si respondió NTLMSSP sin versión NT (típico de Samba en Linux/NAS)
        if not result["os_string"]:
            result["os_string"] = "Linux / NAS (Servidor SMB Samba)"
            result["os_family"] = "linux"
    except Exception:
        pass
    finally:
        try:
            sock.close()
        except OSError:
            pass
    return result


def _probe_netbios_nbstat(target_ip: str, timeout_sec: float = 0.25) -> Dict[str, Any]:
    """
    Envía consulta estándar RFC 1002 `NBSTAT *` (`UDP :137`) para descubrir nombre NetBIOS,
    grupo de trabajo/dominio, rol DC y la dirección MAC Unit ID (incluso a través de routers L3).
    """
    info: Dict[str, Any] = {
        "responded": False,
        "netbios_name": "",
        "workgroup": "",
        "is_domain_controller": False,
        "mac_address": "",
    }
    # Paquete NBSTAT wildcard ('*' + 15 NULs codificados en nivel 1 NetBIOS = 'CKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')
    query = (
        b"\x82\x28\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00"
        b"\x20CKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\x00"
        b"\x00\x21\x00\x01"
    )
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout_sec)
    try:
        sock.sendto(query, (target_ip, 137))
        resp, _ = sock.recvfrom(1024)
        if len(resp) < 57:
            return info
        num_names = resp[56]
        offset = 57
        end_names = offset + (num_names * 18)
        if len(resp) < end_names:
            return info

        info["responded"] = True
        for _ in range(num_names):
            entry = resp[offset : offset + 18]
            offset += 18
            raw_name = entry[:15].decode("latin-1", errors="ignore").strip()
            suffix = entry[15]
            nb_flags = struct.unpack(">H", entry[16:18])[0]
            is_group = bool(nb_flags & 0x8000)
            if not raw_name or raw_name.startswith("__"):
                continue
            if suffix == 0x00 and not is_group and not info["netbios_name"]:
                info["netbios_name"] = raw_name
            elif suffix == 0x00 and is_group and not info["workgroup"]:
                info["workgroup"] = raw_name
            elif suffix == 0x1C and is_group:
                info["is_domain_controller"] = True

        if len(resp) >= end_names + 6:
            unit_mac = ":".join(f"{b:02X}" for b in resp[end_names : end_names + 6])
            norm = normalize_mac_address(unit_mac)
            if norm:
                info["mac_address"] = norm
    except Exception:
        pass
    finally:
        sock.close()
    return info


def _build_multi_oid_snmp_get(community: str, oids: List[str]) -> bytes:
    """Construye un único datagrama `SNMPv2c GetRequest` consultando varios OIDs escalares a la vez."""
    vbs = bytearray()
    for oid in oids:
        oid_tlv = _encode_oid(oid)
        null_tlv = b"\x05\x00"
        vb = b"\x30" + _encode_ber_length(len(oid_tlv) + len(null_tlv)) + oid_tlv + null_tlv
        vbs.extend(vb)
    vb_list = b"\x30" + _encode_ber_length(len(vbs)) + bytes(vbs)
    req_id = b"\x02\x04\x44\x55\x66\x77"
    pdu_body = req_id + b"\x02\x01\x00\x02\x01\x00" + vb_list
    pdu = b"\xa0" + _encode_ber_length(len(pdu_body)) + pdu_body
    comm_b = (community or "public").encode("utf-8")
    msg_body = b"\x02\x01\x01\x04" + _encode_ber_length(len(comm_b)) + comm_b + pdu
    return b"\x30" + _encode_ber_length(len(msg_body)) + msg_body


def _read_tlv_simple(buf: bytes, off: int) -> Tuple[int, bytes, int]:
    tag = buf[off]
    off += 1
    first = buf[off]
    off += 1
    if first < 0x80:
        ln = first
    else:
        n = first & 0x7F
        ln = int.from_bytes(buf[off : off + n], "big")
        off += n
    return tag, buf[off : off + ln], off + ln


def _decode_oid_simple(oid_b: bytes) -> str:
    if not oid_b:
        return ""
    first = oid_b[0]
    a1 = min(2, first // 40)
    a2 = first - (a1 * 40)
    arcs = [str(a1), str(a2)]
    val = 0
    for b in oid_b[1:]:
        val = (val << 7) | (b & 0x7F)
        if not (b & 0x80):
            arcs.append(str(val))
            val = 0
    return ".".join(arcs)


def _probe_snmp_sysinfo(target_ip: str, timeout_sec: float = 0.28) -> Dict[str, Any]:
    """
    Sonda pasiva `SNMPv2c` (`UDP :161`, comunidad `public`) que lee `sysDescr.0`,
    `sysObjectID.0` y `sysName.0` en un único datagrama.
    """
    info = {
        "responded": False,
        "sys_descr": "",
        "sys_object_id": "",
        "sys_name": "",
    }
    oids = [
        "1.3.6.1.2.1.1.1.0",  # sysDescr.0
        "1.3.6.1.2.1.1.2.0",  # sysObjectID.0
        "1.3.6.1.2.1.1.5.0",  # sysName.0
    ]
    pkt = _build_multi_oid_snmp_get("public", oids)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout_sec)
    try:
        sock.sendto(pkt, (target_ip, 161))
        resp, _ = sock.recvfrom(2048)
        t0, seq_b, _ = _read_tlv_simple(resp, 0)
        if t0 != 0x30:
            return info
        _, _, off = _read_tlv_simple(seq_b, 0)
        _, _, off = _read_tlv_simple(seq_b, off)
        pdu_t, pdu_b, _ = _read_tlv_simple(seq_b, off)
        if pdu_t != 0xA2:
            return info
        _, _, p_off = _read_tlv_simple(pdu_b, 0)
        _, _, p_off = _read_tlv_simple(pdu_b, p_off)
        _, _, p_off = _read_tlv_simple(pdu_b, p_off)
        vbl_t, vbl_b, _ = _read_tlv_simple(pdu_b, p_off)
        if vbl_t != 0x30:
            return info

        v_off = 0
        while v_off < len(vbl_b):
            vb_t, vb_b, v_off = _read_tlv_simple(vbl_b, v_off)
            if vb_t != 0x30:
                continue
            ot, ob, inner = _read_tlv_simple(vb_b, 0)
            vt, vb_val, _ = _read_tlv_simple(vb_b, inner)
            if ot != 0x06 or vt in (0x80, 0x81, 0x82):
                continue
            oid_s = _decode_oid_simple(ob)
            if vt == 0x04:
                txt = vb_val.decode("utf-8", errors="replace").strip("\x00").strip()
                if oid_s.startswith("1.3.6.1.2.1.1.1"):
                    info["sys_descr"] = re.sub(r"\s+", " ", txt)[:200]
                elif oid_s.startswith("1.3.6.1.2.1.1.5"):
                    info["sys_name"] = txt[:120]
            elif vt == 0x06 and oid_s.startswith("1.3.6.1.2.1.1.2"):
                info["sys_object_id"] = _decode_oid_simple(vb_val)

        if info["sys_descr"] or info["sys_name"] or info["sys_object_id"]:
            info["responded"] = True
    except Exception:
        pass
    finally:
        sock.close()
    return info


def _decode_dns_name(buf: bytes, offset: int) -> Tuple[str, int]:
    labels: List[str] = []
    jumped = False
    orig_next = offset
    hops = 0
    while offset < len(buf) and hops < 20:
        hops += 1
        ln = buf[offset]
        if ln == 0:
            offset += 1
            if not jumped:
                orig_next = offset
            break
        if (ln & 0xC0) == 0xC0:
            if offset + 1 >= len(buf):
                break
            ptr = ((ln & 0x3F) << 8) | buf[offset + 1]
            if not jumped:
                orig_next = offset + 2
                jumped = True
            offset = ptr
            continue
        offset += 1
        labels.append(buf[offset : offset + ln].decode("utf-8", errors="ignore"))
        offset += ln
    return ".".join(labels), orig_next


def _probe_mdns_ptr(target_ip: str, timeout_sec: float = 0.22) -> str:
    """Consulta inversa unicast `mDNS` (`UDP :5353`) para descubrir nombres `.local`."""
    parts = target_ip.split(".")
    if len(parts) != 4:
        return ""
    rev_labels = [*reversed(parts), "in-addr", "arpa"]
    qname = b"".join(bytes([len(lbl)]) + lbl.encode("ascii") for lbl in rev_labels) + b"\x00"
    pkt = struct.pack(">6H", 0x1337, 0x0000, 1, 0, 0, 0) + qname + struct.pack(">2H", 12, 1)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout_sec)
    try:
        sock.sendto(pkt, (target_ip, 5353))
        resp, _ = sock.recvfrom(1024)
        if len(resp) < 12:
            return ""
        _tid, _fl, qdcount, ancount, _ns, _ar = struct.unpack_from(">6H", resp, 0)
        off = 12
        for _ in range(qdcount):
            _, off = _decode_dns_name(resp, off)
            off += 4
        for _ in range(ancount):
            if off + 10 > len(resp):
                break
            _, off = _decode_dns_name(resp, off)
            rtype, _rclass, _ttl, rdlen = struct.unpack_from(">HHIH", resp, off)
            off += 10
            if rtype == 12 and off + rdlen <= len(resp):
                ptr_name, _ = _decode_dns_name(resp, off)
                return ptr_name.rstrip(".")
            off += rdlen
    except Exception:
        pass
    finally:
        sock.close()
    return ""


# ==============================================================================
# 5. MOTOR DE FUSIÓN MULTISEÑAL (`fingerprint_active_host`)
# ==============================================================================

ASSET_CLASS_DISPLAY: Dict[str, str] = {
    "virtual_machine": "Máquina Virtual (VM)",
    "container_lxc": "Contenedor / LXC / K8s",
    "physical_server": "Servidor / Host Físico",
    "cluster_vip": "Cluster HA / Balanceador VIP",
    "virtual_appliance": "Appliance Virtual (vApp)",
    "cloud_instance": "Instancia Cloud / VPS",
    "network_security": "Electrónica de Red / Firewall",
    "storage_san_nas": "Almacenamiento SAN / NAS",
    "floor_endpoint": "Dispositivo de Planta / IoT",
    "other_machine": "Otro Equipo / Máquina",
}


def _classify_http_signature(http_list: List[Dict[str, Any]]) -> Tuple[str, str, str, str, str]:
    """
    Inspecciona cabeceras HTTP/HTTPS, títulos HTML y certificados TLS para deducir
    `(os_guess, os_family, device_type, asset_class, extracted_hostname)`.
    """
    for h in http_list:
        blob = " | ".join(
            [
                h.get("server") or "",
                h.get("powered_by") or "",
                h.get("www_authenticate") or "",
                h.get("title") or "",
                h.get("tls_issuer") or "",
                h.get("tls_cn") or "",
            ]
        )
        low = blob.lower()
        title = h.get("title") or ""
        server = h.get("server") or ""

        if "proxmox virtual environment" in low or "pve-api-daemon" in low:
            # El título de Proxmox suele ser "<nodename> - Proxmox Virtual Environment"
            node_h = title.split(" - ")[0].strip() if " - " in title else ""
            return ("Proxmox VE (Debian GNU/Linux)", "hypervisor", "Hipervisor Proxmox VE", "physical_server", node_h)
        if "vmware esxi" in low or "vsphere" in low:
            return ("VMware ESXi Hypervisor", "hypervisor", "Hipervisor VMware ESXi", "physical_server", "")
        if "fortigate" in low or "fortinet" in low:
            return ("Fortinet FortiOS", "network_os", "Firewall FortiGate", "network_security", "")
        if "pfsense" in low:
            return ("pfSense (FreeBSD)", "bsd", "Firewall pfSense", "network_security", "")
        if "opnsense" in low:
            return ("OPNsense (FreeBSD)", "bsd", "Firewall OPNsense", "network_security", "")
        if "routeros" in low or "webfig" in low or "mikrotik" in low:
            return ("MikroTik RouterOS", "network_os", "Router / Switch MikroTik", "network_security", "")
        if "unifi" in low or "ubiquiti" in low or "airmax" in low or "edgeos" in low:
            return ("Ubiquiti UniFi OS / EdgeOS", "network_os", "Electrónica Ubiquiti UniFi", "network_security", "")
        if "synology" in low or "diskstation" in low or "rackstation" in low:
            return ("Synology DSM (Linux NAS)", "storage_nas", "Cabina NAS Synology", "storage_san_nas", "")
        if "qnap" in low or "qts" in low:
            return ("QNAP QTS (Linux NAS)", "storage_nas", "Cabina NAS QNAP", "storage_san_nas", "")
        if "truenas" in low or "freenas" in low:
            return ("TrueNAS Scale/Core", "storage_nas", "Cabina TrueNAS", "storage_san_nas", "")
        if "idrac" in low:
            return ("Dell iDRAC Out-of-Band BMC", "embedded", "Controladora BMC Dell iDRAC", "physical_server", "")
        if "integrated lights-out" in low or "hpe ilo" in low or "ilo " in low:
            return ("HPE iLO Out-of-Band BMC", "embedded", "Controladora BMC HPE iLO", "physical_server", "")
        if "supermicro" in low or "aten" in low or "megarac" in low:
            return ("Supermicro IPMI BMC", "embedded", "Controladora BMC IPMI", "physical_server", "")
        if "microsoft-iis/10.0" in low:
            return ("Microsoft Windows Server 2016/2019/2022 (IIS 10.0)", "windows", "Servidor Windows IIS", "virtual_machine", "")
        if "microsoft-iis/8.5" in low:
            return ("Microsoft Windows Server 2012 R2 (IIS 8.5)", "windows", "Servidor Windows IIS", "virtual_machine", "")
        if "microsoft-iis" in low or "microsoft-httpapi" in low:
            return ("Microsoft Windows (HTTP.sys / IIS)", "windows", "Servidor / Host Windows", "virtual_machine", "")
        if any(p in low for p in ("laserjet", "jetdirect", "hp-chaisoe", "brother", "ricoh", "kyocera", "epson")):
            return ("Firmware Impresora de Red", "printer_iot", "Impresora Multifunción / Red", "floor_endpoint", "")
        if "aruba" in low or "procurve" in low:
            return ("HPE ArubaOS Switch / AP", "network_os", "Switch / AP HPE Aruba", "network_security", "")
        if "ubuntu" in server.lower():
            return (f"Ubuntu Linux ({server})", "linux", "Servidor Web Linux", "virtual_machine", "")
        if "debian" in server.lower():
            return (f"Debian GNU/Linux ({server})", "linux", "Servidor Web Linux", "virtual_machine", "")
        if any(d in server.lower() for d in ("rocky", "alma", "rhel", "red hat", "centos", "fedora")):
            return (f"RHEL / Rocky / AlmaLinux ({server})", "linux", "Servidor Web Linux", "virtual_machine", "")
    return ("", "", "", "", "")


def _classify_snmp_sysdescr(sys_descr: str) -> Tuple[str, str, str, str]:
    """Interpreta `SNMP sysDescr.0` hacia `(os_guess, os_family, device_type, asset_class)`."""
    if not sys_descr:
        return ("", "", "", "")
    low = sys_descr.lower()
    if "cisco ios" in low or "cisco nx-os" in low or "catalyst" in low:
        return (sys_descr[:95], "network_os", "Switch / Router Cisco", "network_security")
    if "routeros" in low or "mikrotik" in low:
        return (sys_descr[:95], "network_os", "Router / Switch MikroTik", "network_security")
    if "fortigate" in low or "fortios" in low:
        return (sys_descr[:95], "network_os", "Firewall FortiGate", "network_security")
    if "aruba" in low or "procurve" in low or "hewlett-packard" in low and "switch" in low:
        return (sys_descr[:95], "network_os", "Switch HPE / Aruba", "network_security")
    if "juniper" in low or "junos" in low:
        return (sys_descr[:95], "network_os", "Switch / Router Juniper", "network_security")
    if "windows" in low:
        m = re.search(r"Software:\s*(Windows.*)", sys_descr, re.IGNORECASE)
        return ((m.group(1)[:95] if m else "Microsoft Windows (SNMP)"), "windows", "Servidor Windows", "virtual_machine")
    if "synology" in low or "diskstation" in low:
        return ("Synology DSM (Linux NAS)", "storage_nas", "Cabina NAS Synology", "storage_san_nas")
    if "linux" in low:
        # Formato típico: Linux hostname 6.8.0-45-generic #45-Ubuntu SMP ... x86_64
        if "ubuntu" in low:
            k_m = re.search(r"Linux\s+\S+\s+([\d\.\-a-zA-Z]+)", sys_descr)
            kern = f" (Kernel {k_m.group(1)})" if k_m else ""
            return (f"Ubuntu Linux{kern}", "linux", "Servidor Linux", "virtual_machine")
        if "pve" in low:
            k_m = re.search(r"Linux\s+\S+\s+([\d\.\-pve]+)", sys_descr)
            kern = f" ({k_m.group(1)})" if k_m else ""
            return (f"Proxmox VE Debian Linux{kern}", "hypervisor", "Hipervisor Proxmox VE", "physical_server")
        if "debian" in low:
            return ("Debian GNU/Linux", "linux", "Servidor Linux", "virtual_machine")
        if "darwin" in low:
            return ("Apple macOS (Darwin)", "macos", "Equipo Apple macOS", "other_machine")
        return (sys_descr[:95], "linux", "Servidor / Appliance Linux", "virtual_machine")
    if "darwin" in low:
        return ("Apple macOS", "macos", "Equipo Apple macOS", "other_machine")
    if "jetdirect" in low or "laserjet" in low or "printer" in low:
        return (sys_descr[:95], "printer_iot", "Impresora de Red", "floor_endpoint")
    return (sys_descr[:95], "unknown", "Dispositivo SNMP", "other_machine")


def fingerprint_active_host(
    target_ip: str,
    icmp_probe: Dict[str, Any],
    initial_tcp_results: List[Dict[str, Any]],
    arp_mac: Optional[str],
    ptr_hostname: Optional[str],
    is_bulk_scan: bool = False,
) -> Dict[str, Any]:
    """
    Ejecuta la identificación integral de Sistema Operativo, Pila TCP/IP, Servicios y OUI MAC
    sobre un host que ya ha demostrado estar vivo en la red.
    """
    evidence: List[str] = []
    by_port: Dict[int, Dict[str, Any]] = {
        r["port"]: r for r in initial_tcp_results if r.get("state") == "open"
    }
    tested_set = {r["port"] for r in initial_tcp_results}

    # 1. Completar barrido rápido de puertos de firma OS que no estuvieran ya en la tanda inicial
    extra_timeout = 0.22 if is_bulk_scan else 0.32
    for ep in ENRICHMENT_TCP_PORTS:
        if ep in tested_set:
            continue
        tested_set.add(ep)
        res = probe_tcp_port_with_stack(target_ip, ep, timeout_sec=extra_timeout)
        if res["state"] == "open":
            by_port[ep] = res

    open_ports = sorted(by_port.keys())

    # 2. Consolidar métricas de Pila TCP/IP (ICMP TTL + primer socket TCP abierto con métricas)
    ttl_info = icmp_probe.get("ttl_info") or classify_icmp_ttl(icmp_probe.get("ttl"))
    sample_stack: Dict[str, Any] = {}
    for p in open_ports:
        st = by_port[p].get("stack") or {}
        if st:
            sample_stack = st
            if st.get("peer_window_scale") is not None or st.get("tcp_mss") is not None:
                break

    tcp_mss = sample_stack.get("tcp_mss")
    peer_wscale = sample_stack.get("peer_window_scale")
    tcp_ts = sample_stack.get("tcp_timestamps")
    tcp_sack = sample_stack.get("tcp_sack")
    tcp_ecn = sample_stack.get("tcp_ecn")
    pmtu = sample_stack.get("pmtu")

    stack_parts: List[str] = []
    if ttl_info.get("icmp_ttl") is not None:
        stack_parts.append(
            f"TTL={ttl_info['icmp_ttl']} (base {ttl_info['initial_ttl']}, {ttl_info['estimated_hops']} salto(s))"
        )
    if tcp_mss is not None:
        mss_tag = "Ethernet" if tcp_mss == 1460 else ("Jumbo" if tcp_mss > 1460 else "Túnel/VPN")
        stack_parts.append(f"MSS={tcp_mss} ({mss_tag})")
    if peer_wscale is not None:
        stack_parts.append(f"WScale={peer_wscale}")
    opt_flags: List[str] = []
    if tcp_ts is True:
        opt_flags.append("TS")
    elif tcp_ts is False:
        opt_flags.append("No-TS")
    if tcp_sack is True:
        opt_flags.append("SACK")
    if tcp_ecn is True:
        opt_flags.append("ECN")
    if opt_flags:
        stack_parts.append("+".join(opt_flags))

    stack_signature = " • ".join(stack_parts) if stack_parts else "Sin telemetría de cabeceras L3/L4"
    if ttl_info.get("ttl_os_hint"):
        evidence.append(f"Pila IP: {ttl_info['ttl_os_hint']} [{stack_signature}]")
    elif stack_parts:
        evidence.append(f"Pila TCP: {stack_signature}")

    # 3. Sondas de protocolo L7 dirigidas únicamente a los servicios abiertos (+ UDP ligeros SNMP/NBSTAT/mDNS)
    ssh_banner = ""
    for sp in (22, 2222):
        if sp in by_port:
            ssh_banner = by_port[sp].get("banner") or ""
            if not ssh_banner:
                # Reintento corto si el servidor tardó unos ms en escupir el saludo SSH
                r2 = probe_tcp_port_with_stack(target_ip, sp, timeout_sec=0.45)
                ssh_banner = r2.get("banner") or ""
            if ssh_banner:
                evidence.append(f"Banner SSH (:{sp}): {ssh_banner}")
                break

    http_infos: List[Dict[str, Any]] = []
    web_candidates: List[Tuple[int, bool]] = [
        (8006, True),
        (443, True),
        (8443, True),
        (5001, True),
        (6443, True),
        (80, False),
        (8080, False),
        (5000, False),
    ]
    probed_web = 0
    for wp, is_tls in web_candidates:
        if wp in by_port and probed_web < 2:
            probed_web += 1
            hinfo = _probe_http_and_tls_signature(
                target_ip,
                wp,
                use_tls=is_tls,
                timeout_sec=0.45 if is_bulk_scan else 0.65,
            )
            http_infos.append(hinfo)
            desc_bits = [x for x in (hinfo.get("server"), hinfo.get("title"), hinfo.get("tls_cn")) if x]
            if desc_bits:
                evidence.append(f"{'HTTPS' if is_tls else 'HTTP'} (:{wp}): {' — '.join(desc_bits[:2])}")

    smb_info: Dict[str, Any] = {}
    if 445 in by_port:
        smb_info = _probe_smb_ntlmssp_challenge(target_ip, timeout_sec=0.45 if is_bulk_scan else 0.65)
        if smb_info.get("responded"):
            smb_ev = smb_info.get("os_string") or "SMB activo"
            if smb_info.get("dns_computer") or smb_info.get("nb_computer"):
                smb_ev += f" [Host: {smb_info.get('dns_computer') or smb_info.get('nb_computer')}]"
            evidence.append(f"Firma SMB/NTLMSSP (:445): {smb_ev}")

    # NBSTAT UDP 137 si tiene puertos Windows/Samba, o si no tenemos MAC/PTR
    nbstat_info: Dict[str, Any] = {}
    if any(p in by_port for p in (135, 139, 445, 3389)) or not arp_mac or not ptr_hostname:
        nbstat_info = _probe_netbios_nbstat(target_ip, timeout_sec=0.22 if is_bulk_scan else 0.3)
        if nbstat_info.get("responded") and nbstat_info.get("netbios_name"):
            wg = f" (Dominio/WG: {nbstat_info['workgroup']})" if nbstat_info.get("workgroup") else ""
            evidence.append(f"NetBIOS (:137/udp): {nbstat_info['netbios_name']}{wg}")

    # SNMP UDP 161 (muy rápido, 1 datagrama UDP: clave para Switches, Routers, Impresoras, ESXi y Linux con snmpd)
    snmp_info = _probe_snmp_sysinfo(target_ip, timeout_sec=0.22 if is_bulk_scan else 0.32)
    if snmp_info.get("responded"):
        if snmp_info.get("sys_descr"):
            evidence.append(f"SNMP sysDescr (:161/udp): {snmp_info['sys_descr'][:110]}")
        if snmp_info.get("sys_name"):
            evidence.append(f"SNMP sysName: {snmp_info['sys_name']}")
        if 161 not in open_ports:
            open_ports.append(161)
            open_ports.sort()

    # 4. Consolidar Dirección MAC (ARP L2 local o Unit ID de NetBIOS a través de L3) y OUI Fabricante
    effective_mac = normalize_mac_address(arp_mac) or normalize_mac_address(nbstat_info.get("mac_address"))
    mac_info = lookup_mac_vendor(effective_mac)
    if mac_info["mac_address"] and mac_info["vendor"]:
        virt_tag = " [Virtual]" if mac_info["is_virtual"] else ""
        evidence.append(f"MAC OUI {mac_info['mac_address']} ➔ {mac_info['vendor']}{virt_tag}")

    # 5. Consolidar Hostname / FQDN / Dominio (PTR > SMB DNS > SNMP sysName > TLS CN/SAN > NetBIOS > mDNS > HTTP Title)
    mdns_host = ""
    if not ptr_hostname and not smb_info.get("dns_computer") and not snmp_info.get("sys_name"):
        mdns_host = _probe_mdns_ptr(target_ip, timeout_sec=0.18 if is_bulk_scan else 0.25)
        if mdns_host:
            evidence.append(f"mDNS (:5353/udp): {mdns_host}")

    tls_fqdn = ""
    for h in http_infos:
        for cand in [h.get("tls_cn", ""), *(h.get("tls_sans") or [])]:
            c = str(cand or "").strip().lstrip("*.")
            if c and "." in c and not re.fullmatch(r"[\d\.]+", c) and "localhost" not in c.lower():
                tls_fqdn = c
                break
        if tls_fqdn:
            break

    os_http, fam_http, dev_http, cls_http, title_host = _classify_http_signature(http_infos)
    os_ssh, fam_ssh, dev_ssh = parse_ssh_banner_os(ssh_banner)
    os_snmp, fam_snmp, dev_snmp, cls_snmp = _classify_snmp_sysdescr(snmp_info.get("sys_descr") or "")

    fqdn_detected = (
        (ptr_hostname or "").strip()
        or (smb_info.get("dns_computer") or "").strip()
        or tls_fqdn
        or mdns_host
    )
    hostname_detected = (
        (snmp_info.get("sys_name") or "").strip()
        or (smb_info.get("nb_computer") or "").strip()
        or (nbstat_info.get("netbios_name") or "").strip()
        or (fqdn_detected.split(".")[0] if fqdn_detected else "")
        or title_host
    )
    domain_detected = (
        (smb_info.get("dns_domain") or "").strip()
        or (smb_info.get("nb_domain") or "").strip()
        or (nbstat_info.get("workgroup") or "").strip()
        or (".".join(fqdn_detected.split(".")[1:]) if "." in fqdn_detected else "")
    )

    # 6. Jerarquía ponderada de inferencia de Sistema Operativo, Tipo de Máquina y Clase CMDB
    os_guess = ""
    os_family = "unknown"
    device_type = "Equipo en Red"
    asset_class = mac_info.get("category_hint") or "other_machine"
    confidence = 35

    # Prioridad A: Firmas de hipervisores dedicados / appliances críticas (Proxmox :8006, ESXi :902, WinBox :8291)
    if 8006 in open_ports or fam_http == "hypervisor" or fam_snmp == "hypervisor":
        os_guess = os_snmp or os_http or "Proxmox VE (Debian GNU/Linux)"
        os_family = "hypervisor"
        device_type = dev_http or dev_snmp or "Hipervisor de Virtualización"
        asset_class = "physical_server"
        confidence = 96
    elif 902 in open_ports and (443 in open_ports or os_http or "vmware" in (mac_info.get("vendor") or "").lower()):
        os_guess = os_http or os_snmp or "VMware ESXi Hypervisor"
        os_family = "hypervisor"
        device_type = "Hipervisor VMware ESXi"
        asset_class = "physical_server"
        confidence = 95
    elif 8291 in open_ports:
        os_guess = os_snmp or os_ssh or "MikroTik RouterOS"
        os_family = "network_os"
        device_type = "Router / Switch MikroTik"
        asset_class = "network_security"
        confidence = 96
    # Prioridad B: SNMP sysDescr exacto
    elif os_snmp:
        os_guess = os_snmp
        os_family = fam_snmp
        device_type = dev_snmp
        asset_class = cls_snmp or asset_class
        confidence = 95
    # Prioridad C: Windows exacto vía desafío SMB NTLMSSP Build
    elif smb_info.get("os_family") == "windows" and smb_info.get("os_string"):
        os_guess = smb_info["os_string"]
        os_family = "windows"
        is_dc = bool(88 in open_ports or 389 in open_ports or nbstat_info.get("is_domain_controller"))
        device_type = "Controlador de Dominio Active Directory" if is_dc else "Servidor / Host Windows"
        asset_class = "virtual_machine" if mac_info.get("is_virtual") else "physical_server"
        confidence = 96
    # Prioridad D: Firma HTTP/HTTPS específica de Appliance / NAS / Firewall / BMC / IIS
    elif os_http and fam_http in ("network_os", "storage_nas", "embedded", "bsd", "windows", "printer_iot"):
        os_guess = os_http
        os_family = fam_http
        device_type = dev_http
        asset_class = cls_http or asset_class
        confidence = 91
    # Prioridad E: Banner SSH específico (Ubuntu 24.04/22.04, Debian 12/11, Cisco, FortiOS, Windows OpenSSH...)
    elif os_ssh:
        os_guess = os_ssh
        os_family = fam_ssh
        device_type = dev_ssh
        if fam_ssh in ("linux", "bsd", "unix"):
            if 6443 in open_ports:
                device_type = "Nodo Cluster Kubernetes (Linux)"
            asset_class = "virtual_machine" if mac_info.get("is_virtual") else (
                mac_info.get("category_hint") or "physical_server"
            )
        elif fam_ssh == "network_os":
            asset_class = "network_security"
        elif fam_ssh == "windows":
            asset_class = "virtual_machine" if mac_info.get("is_virtual") else "physical_server"
        confidence = 92 if any(k in os_ssh.lower() for k in ("ubuntu", "debian", "cisco", "mikrotik", "forti", "windows")) else 82
    # Prioridad F: Servidor Web Linux / Samba con distribución en cabecera
    elif os_http:
        os_guess = os_http
        os_family = fam_http
        device_type = dev_http
        asset_class = "virtual_machine" if mac_info.get("is_virtual") else (cls_http or "physical_server")
        confidence = 85
    elif smb_info.get("os_family") == "linux":
        os_guess = smb_info["os_string"]
        os_family = "linux"
        device_type = "Servidor de Archivos Linux / NAS (Samba)"
        asset_class = "storage_san_nas" if mac_info.get("category_hint") == "storage_san_nas" else (
            "virtual_machine" if mac_info.get("is_virtual") else "physical_server"
        )
        confidence = 80
    # Prioridad G: Combinación de puertos típicos + Pila TCP/IP + OUI MAC
    elif any(p in open_ports for p in (135, 139, 445, 3389, 5985, 5986)):
        os_guess = "Microsoft Windows (Server / Desktop)"
        if peer_wscale == 8:
            os_guess = "Microsoft Windows 10/11 o Server 2019/2022 (TCP WScale=8)"
        os_family = "windows"
        device_type = "Servidor / Escritorio Remoto Windows" if 3389 in open_ports else "Host Microsoft Windows"
        asset_class = "virtual_machine" if mac_info.get("is_virtual") else "physical_server"
        confidence = 82
    elif 548 in open_ports or "apple" in (mac_info.get("vendor") or "").lower():
        os_guess = "Apple macOS / iOS"
        os_family = "macos"
        device_type = "Equipo Apple (macOS / iOS)"
        asset_class = "other_machine"
        confidence = 78
    elif 9100 in open_ports and 22 not in open_ports and (
        mac_info.get("category_hint") == "floor_endpoint" or 631 in open_ports
    ):
        os_guess = f"Firmware Impresora ({mac_info['vendor']})" if mac_info.get("vendor") else "Impresora JetDirect (:9100)"
        os_family = "printer_iot"
        device_type = "Impresora de Red"
        asset_class = "floor_endpoint"
        confidence = 80
    # Prioridad H: Inferencia pura por Pila TCP/IP (`TTL` + `Window Scale` + `Timestamps`) + OUI MAC
    else:
        ttl_fam = ttl_info.get("ttl_family")
        if ttl_fam == "windows":
            w_detail = " (Pila moderna WScale=8)" if peer_wscale == 8 else " (TTL base 128)"
            os_guess = f"Microsoft Windows{w_detail}"
            os_family = "windows"
            device_type = "Máquina Virtual Windows" if mac_info.get("is_virtual") else "Host Microsoft Windows"
            asset_class = "virtual_machine" if mac_info.get("is_virtual") else "other_machine"
            confidence = 72 if peer_wscale is not None else 65
        elif ttl_fam == "network_os" or mac_info.get("category_hint") == "network_security":
            plat = mac_info.get("platform_hint") or "Switch / Router Gestionable"
            os_guess = f"{plat} (TTL base 255)" if ttl_fam == "network_os" else plat
            os_family = "network_os"
            device_type = "Electrónica de Red / Firewall"
            asset_class = "network_security"
            confidence = 76 if mac_info.get("vendor") else 66
        elif ttl_fam == "unix_linux":
            if mac_info.get("category_hint") == "storage_san_nas":
                os_guess = f"{mac_info['platform_hint']} (Linux NAS)"
                os_family = "storage_nas"
                device_type = "Cabina de Almacenamiento NAS"
                asset_class = "storage_san_nas"
                confidence = 82
            elif mac_info.get("category_hint") == "floor_endpoint":
                os_guess = f"Linux / Embebido ({mac_info['platform_hint']})"
                os_family = "printer_iot"
                device_type = mac_info["platform_hint"]
                asset_class = "floor_endpoint"
                confidence = 78
            elif peer_wscale == 6 and tcp_ts is True:
                os_guess = "macOS / BSD / iOS (TTL base 64, WScale=6)"
                os_family = "macos"
                device_type = "Equipo macOS / BSD"
                asset_class = "other_machine"
                confidence = 66
            else:
                ws_note = "Kernel 5.x/6.x (WScale=7)" if peer_wscale == 7 else "TTL base 64"
                os_guess = f"Linux / Unix ({ws_note})"
                os_family = "linux"
                device_type = "Máquina Virtual Linux" if mac_info.get("is_virtual") else "Host Linux / Unix"
                asset_class = "virtual_machine" if mac_info.get("is_virtual") else (
                    mac_info.get("category_hint") or "other_machine"
                )
                confidence = 70 if peer_wscale == 7 else 60
        elif mac_info.get("vendor"):
            os_guess = f"Sistema en Hardware {mac_info['platform_hint'] or mac_info['vendor']}"
            os_family = "unknown"
            device_type = mac_info["platform_hint"] or "Dispositivo L2 Activo"
            asset_class = mac_info.get("category_hint") or "other_machine"
            confidence = 52
        else:
            os_guess = "Sistema Operativo No Determinado (Host silencioso / Firewall activo)"
            os_family = "unknown"
            device_type = "Equipo Activo en Red"
            asset_class = "other_machine"
            confidence = 30

    # Ajuste final si la MAC OUI confirma virtualización sobre un servidor genérico
    if mac_info.get("is_virtual") and asset_class == "physical_server" and os_family not in ("hypervisor", "network_os"):
        asset_class = "container_lxc" if mac_info.get("category_hint") == "container_lxc" else "virtual_machine"

    if asset_class not in ASSET_CLASS_DISPLAY:
        asset_class = "other_machine"

    conf_label = "Alta" if confidence >= 85 else ("Media" if confidence >= 60 else "Baja")

    # Servicios abiertos enriquecidos con banner
    open_services: List[Dict[str, Any]] = []
    http_by_port = {h["port"]: h for h in http_infos}
    for p in open_ports:
        svc_name = PORT_SERVICE_NAMES.get(p, f"tcp/{p}")
        b_txt = ""
        if p in (22, 2222) and ssh_banner:
            b_txt = ssh_banner
        elif p in http_by_port:
            hi = http_by_port[p]
            b_txt = " — ".join(x for x in (hi.get("server"), hi.get("title")) if x)
        elif p == 445 and smb_info.get("os_string"):
            b_txt = smb_info["os_string"]
        elif p == 161 and snmp_info.get("sys_descr"):
            b_txt = snmp_info["sys_descr"][:90]
        open_services.append({
            "port": p,
            "protocol": "udp" if p == 161 and 161 not in by_port else "tcp",
            "service": svc_name,
            "banner": b_txt,
        })

    primary_http = http_infos[0] if http_infos else {}
    hypervisor_or_platform = (
        mac_info.get("platform_hint")
        or mac_info.get("vendor")
        or ("Proxmox VE" if os_family == "hypervisor" and "proxmox" in os_guess.lower() else "")
        or "Descubrimiento Activo CMDB"
    )

    return {
        "os_guess": os_guess,
        "os_family": os_family,
        "device_type_guess": device_type,
        "suggested_asset_class": asset_class,
        "suggested_asset_class_label": ASSET_CLASS_DISPLAY.get(asset_class, asset_class),
        "confidence": confidence,
        "confidence_label": conf_label,
        "mac_address": mac_info["mac_address"],
        "mac_oui": mac_info["oui_prefix"],
        "mac_vendor": mac_info["vendor"],
        "is_virtual_machine": mac_info["is_virtual"],
        "is_locally_administered_mac": mac_info["is_locally_administered"],
        "hypervisor_or_platform": hypervisor_or_platform,
        "hostname_detected": hostname_detected,
        "fqdn_detected": fqdn_detected,
        "domain_or_workgroup": domain_detected,
        "tcpip_stack": {
            "icmp_ttl": ttl_info.get("icmp_ttl"),
            "initial_ttl": ttl_info.get("initial_ttl"),
            "estimated_hops": ttl_info.get("estimated_hops"),
            "ttl_os_hint": ttl_info.get("ttl_os_hint") or "",
            "tcp_mss": tcp_mss,
            "peer_window_scale": peer_wscale,
            "tcp_timestamps": tcp_ts,
            "tcp_sack": tcp_sack,
            "tcp_ecn": tcp_ecn,
            "pmtu": pmtu,
            "stack_signature": stack_signature,
        },
        "banners": {
            "ssh_banner": ssh_banner,
            "http_server": primary_http.get("server") or "",
            "http_title": primary_http.get("title") or "",
            "tls_cn": primary_http.get("tls_cn") or "",
            "tls_issuer": primary_http.get("tls_issuer") or "",
            "tls_sans": primary_http.get("tls_sans") or [],
            "smb_os": smb_info.get("os_string") or "",
            "netbios_name": nbstat_info.get("netbios_name") or smb_info.get("nb_computer") or "",
            "snmp_sys_descr": snmp_info.get("sys_descr") or "",
            "snmp_sys_name": snmp_info.get("sys_name") or "",
            "snmp_sys_object_id": snmp_info.get("sys_object_id") or "",
            "mdns_hostname": mdns_host,
        },
        "open_ports": open_ports,
        "open_services": open_services,
        "evidence": evidence,
    }
