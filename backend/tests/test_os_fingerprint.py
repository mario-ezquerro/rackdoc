"""
Pruebas unitarias e integración del Motor de Huella Digital de Sistema Operativo,
Pila TCP/IP (`TTL`, `MSS`, `WScale`, `TS/SACK`) e Inteligencia MAC OUI (`os_fingerprint_service.py`).
"""

from typing import Dict
from unittest.mock import patch

from fastapi.testclient import TestClient

from app.services.os_fingerprint_service import (
    classify_icmp_ttl,
    fingerprint_active_host,
    lookup_mac_vendor,
    normalize_mac_address,
    parse_ssh_banner_os,
)


def test_mac_normalization_and_ieee_oui_lookup():
    # Normalización de octetos de 1 dígito (salida típica de `arp -n` en macOS/BSD) y formato Cisco
    assert normalize_mac_address("0:50:56:a:1:f") == "00:50:56:0A:01:0F"
    assert normalize_mac_address("bc24.114a.0219") == "BC:24:11:4A:02:19"
    assert normalize_mac_address("ff:ff:ff:ff:ff:ff") is None
    assert normalize_mac_address("00:00:00:00:00:00") is None

    proxmox = lookup_mac_vendor("bc:24:11:99:88:77")
    assert "Proxmox" in proxmox["vendor"]
    assert proxmox["is_virtual"] is True
    assert proxmox["category_hint"] == "virtual_machine"

    cisco = lookup_mac_vendor("00:00:0c:12:34:56")
    assert "Cisco" in cisco["vendor"]
    assert cisco["is_virtual"] is False
    assert cisco["category_hint"] == "network_security"

    # Bit U/L localmente administrado (0x02) fuera de tabla estática
    local_mac = lookup_mac_vendor("06:aa:bb:cc:dd:ee")
    assert local_mac["is_locally_administered"] is True
    assert local_mac["is_virtual"] is True


def test_tcpip_ttl_and_ssh_banner_signatures():
    linux_ttl = classify_icmp_ttl(64)
    assert linux_ttl["initial_ttl"] == 64
    assert linux_ttl["estimated_hops"] == 0
    assert linux_ttl["ttl_family"] == "unix_linux"

    win_ttl = classify_icmp_ttl(126)
    assert win_ttl["initial_ttl"] == 128
    assert win_ttl["estimated_hops"] == 2
    assert win_ttl["ttl_family"] == "windows"

    net_ttl = classify_icmp_ttl(253)
    assert net_ttl["initial_ttl"] == 255
    assert net_ttl["estimated_hops"] == 2
    assert net_ttl["ttl_family"] == "network_os"

    os_u24, fam_u24, _ = parse_ssh_banner_os("SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.5")
    assert "Ubuntu Linux 24.04" in os_u24
    assert fam_u24 == "linux"

    os_deb, fam_deb, _ = parse_ssh_banner_os("SSH-2.0-OpenSSH_9.2p1 Debian-2+deb12u3")
    assert "Debian GNU/Linux 12" in os_deb
    assert fam_deb == "linux"

    os_mt, fam_mt, _ = parse_ssh_banner_os("SSH-2.0-ROSSSH")
    assert "MikroTik RouterOS" in os_mt
    assert fam_mt == "network_os"


def test_active_host_fingerprint_fusion_linux_vm_and_windows_ad():
    # Caso 1: VM Ubuntu 24.04 sobre Proxmox VE con pila TCP/IP Linux (TTL=64, MSS=1460, WScale=7, TS+SACK)
    with (
        patch("app.services.os_fingerprint_service.probe_tcp_port_with_stack") as mock_tcp,
        patch("app.services.os_fingerprint_service._probe_snmp_sysinfo", return_value={"responded": False}),
        patch("app.services.os_fingerprint_service._probe_netbios_nbstat", return_value={"responded": False}),
        patch("app.services.os_fingerprint_service._probe_mdns_ptr", return_value=""),
    ):
        mock_tcp.return_value = {"port": 9999, "state": "filtered_or_down", "stack": {}, "banner": ""}
        fp_vm = fingerprint_active_host(
            target_ip="10.20.20.51",
            icmp_probe={
                "alive": True,
                "latency_ms": 0.42,
                "ttl": 64,
                "ttl_info": classify_icmp_ttl(64),
            },
            initial_tcp_results=[
                {
                    "port": 22,
                    "state": "open",
                    "stack": {
                        "tcp_mss": 1460,
                        "peer_window_scale": 7,
                        "tcp_timestamps": True,
                        "tcp_sack": True,
                        "tcp_ecn": False,
                        "pmtu": 1500,
                    },
                    "banner": "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.5",
                }
            ],
            arp_mac="bc:24:11:10:20:30",
            ptr_hostname="app01.cpd.local",
            is_bulk_scan=True,
        )
        assert "Ubuntu Linux 24.04" in fp_vm["os_guess"]
        assert fp_vm["suggested_asset_class"] == "virtual_machine"
        assert fp_vm["is_virtual_machine"] is True
        assert "Proxmox" in fp_vm["mac_vendor"]
        assert fp_vm["tcpip_stack"]["icmp_ttl"] == 64
        assert fp_vm["tcpip_stack"]["peer_window_scale"] == 7
        assert fp_vm["confidence"] >= 90

    # Caso 2: Controlador de Dominio Windows Server 2022 detectado por NTLMSSP + TTL=128 + Hyper-V OUI
    with (
        patch("app.services.os_fingerprint_service.probe_tcp_port_with_stack") as mock_tcp_w,
        patch(
            "app.services.os_fingerprint_service._probe_smb_ntlmssp_challenge",
            return_value={
                "responded": True,
                "os_string": "Windows Server 2022 (Build 20348)",
                "os_family": "windows",
                "nb_computer": "DC01",
                "nb_domain": "CORP",
                "dns_computer": "dc01.corp.local",
                "dns_domain": "corp.local",
            },
        ),
        patch(
            "app.services.os_fingerprint_service._probe_netbios_nbstat",
            return_value={
                "responded": True,
                "netbios_name": "DC01",
                "workgroup": "CORP",
                "is_domain_controller": True,
                "mac_address": "00:15:5D:01:02:03",
            },
        ),
        patch("app.services.os_fingerprint_service._probe_snmp_sysinfo", return_value={"responded": False}),
    ):
        mock_tcp_w.return_value = {"port": 9999, "state": "filtered_or_down", "stack": {}, "banner": ""}
        fp_win = fingerprint_active_host(
            target_ip="10.20.20.10",
            icmp_probe={
                "alive": True,
                "latency_ms": 0.8,
                "ttl": 128,
                "ttl_info": classify_icmp_ttl(128),
            },
            initial_tcp_results=[
                {
                    "port": 445,
                    "state": "open",
                    "stack": {"tcp_mss": 1460, "peer_window_scale": 8, "tcp_timestamps": False, "tcp_sack": True},
                    "banner": "",
                },
                {"port": 88, "state": "open", "stack": {}, "banner": ""},
                {"port": 389, "state": "open", "stack": {}, "banner": ""},
            ],
            arp_mac=None,  # Incluso sin ARP local (subred L3), recupera MAC desde NBSTAT Unit ID
            ptr_hostname=None,
            is_bulk_scan=True,
        )
        assert fp_win["os_guess"] == "Windows Server 2022 (Build 20348)"
        assert fp_win["hostname_detected"] == "DC01"
        assert fp_win["fqdn_detected"] == "dc01.corp.local"
        assert fp_win["mac_address"] == "00:15:5D:01:02:03"
        assert "Hyper-V" in fp_win["mac_vendor"]
        assert fp_win["suggested_asset_class"] == "virtual_machine"


def test_import_discovered_auto_classifies_and_persists_fingerprint(
    client: TestClient,
    admin_headers: Dict[str, str],
):
    fake_fp = {
        "os_guess": "Fortinet FortiOS v7.4",
        "os_family": "network_os",
        "device_type_guess": "Firewall FortiGate",
        "suggested_asset_class": "network_security",
        "suggested_asset_class_label": "Electrónica de Red / Firewall",
        "confidence": 95,
        "confidence_label": "Alta",
        "mac_address": "00:09:0F:AA:BB:CC",
        "mac_vendor": "Fortinet, Inc.",
        "hypervisor_or_platform": "Fortinet FortiGate",
        "hostname_detected": "FW-PERIMETRO-01",
        "fqdn_detected": "fw01.cpd.local",
        "domain_or_workgroup": "cpd.local",
        "tcpip_stack": {"icmp_ttl": 64, "initial_ttl": 64, "estimated_hops": 0, "stack_signature": "TTL=64 • MSS=1460"},
        "open_ports": [22, 443, 161],
        "evidence": ["SNMP sysDescr: FortiGate-100F v7.4", "MAC OUI 00:09:0F ➔ Fortinet, Inc."],
    }

    resp = client.post(
        "/api/v1/cmdb/import-discovered",
        headers=admin_headers,
        json={
            "register_subnet_cidr": "10.99.88.0/24",
            "subnet_name": "Red Seguridad Test",
            "items": [
                {
                    "ip_address": "10.99.88.254",
                    "asset_class": "auto",
                    "open_ports": [22, 443, 161],
                    "fingerprint": fake_fp,
                }
            ],
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["imported_assets_count"] == 1
    created = next(a for a in body["assets"] if a["heartbeat_ip"] == "10.99.88.254")
    assert created["asset_class"] == "network_security"
    assert created["os_or_firmware"] == "Fortinet FortiOS v7.4"
    assert created["hypervisor_or_platform"] == "Fortinet FortiGate"
    assert created["hostname"] == "FW-PERIMETRO-01"
    assert created["fqdn"] == "fw01.cpd.local"
    assert created["ip_addresses"][0]["mac_address"] == "00:09:0F:AA:BB:CC"
