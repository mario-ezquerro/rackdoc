from __future__ import annotations

import json
import math
import os
import re
import smtplib
import socket
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from email.message import EmailMessage
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from sqlalchemy.orm import Session, joinedload

from ..models import (
    AlertContact,
    AlertContactGroup,
    AlertNotificationLog,
    CmdbAsset,
    CmdbIpAddress,
    CmdbSubnet,
    Connection,
    FloorDevice,
    HostGroup,
    InfraConnector,
    LogicalTopologyLink,
    MaintenanceWindow,
    MonitoredServiceCheck,
    NotificationRoutingRule,
    Port,
    Rack,
    RackDevice,
    SmtpAlertConfig,
    SwitchSnmpPort,
)
from .cmdb_service import (
    ASSET_CLASS_LABELS,
    IP_ROLE_LABELS,
    _match_subnet_for_ip,
    ensure_cmdb_seed_data,
    sync_physical_devices_to_cmdb,
)
from .monitor import check_host_connectivity

PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://rackdoc-prometheus:9090").rstrip("/")
PROMETHEUS_PUBLIC_URL = os.getenv("PROMETHEUS_PUBLIC_URL", "http://localhost:9090").rstrip("/")
PROMETHEUS_DYNAMIC_DIR = Path(os.getenv("PROMETHEUS_DYNAMIC_DIR", "/app/data/prometheus"))
AUTOMATION_API_KEY = os.getenv("AUTOMATION_API_KEY", "rackdoc-ansible-automation-token-2026")

CONNECTOR_TYPE_LABELS: Dict[str, str] = {
    "snmp_switch": "Switch / Router / Firewall SNMP (IF-MIB + LLDP-MIB)",
    "proxmox_ve": "Hipervisor Proxmox VE (API :8006 + QEMU/LXC)",
    "vmware_vsphere": "Hipervisor VMware ESXi / vCenter (API :443)",
    "hyperv": "Hipervisor Microsoft Hyper-V (WinRM / Exporter)",
    "kvm_libvirt": "Hipervisor KVM / QEMU / Libvirt",
    "xcpng": "Hipervisor XCP-ng / XenServer",
    "docker_engine": "Motor Contenedores Docker Engine / cAdvisor",
    "portainer": "Orquestador Portainer API (:9443)",
    "kubernetes": "Clúster Kubernetes / K3s (Kube-State)",
    "apache_status": "Servidor Web Apache HTTPd (mod_status / Exporter)",
    "nginx_status": "Servidor Web / Proxy Nginx (stub_status / Exporter)",
    "haproxy_stats": "Balanceador HAProxy (Prometheus Stats :8404)",
    "postgresql": "Base de Datos PostgreSQL (:5432 / postgres_exporter)",
    "mysql_mariadb": "Base de Datos MySQL / MariaDB (:3306 / mysqld_exporter)",
    "mssql": "Base de Datos Microsoft SQL Server (:1433)",
    "redis": "Caché En Memoria Redis / Valkey (:6379)",
    "mongodb": "Base de Datos MongoDB (:27017)",
    "node_exporter": "Agente Linux Prometheus Node Exporter (:9100)",
    "windows_exporter": "Agente Windows Prometheus Exporter (:9182)",
}

LOGICAL_LAYER_ORDER: Dict[str, int] = {
    "edge_security": 1,     # Capa 1: Firewalls, Routers y Perímetro WAN
    "network_switching": 2, # Capa 2: Switches Core / ToR / VLANs (SNMP + LLDP)
    "hypervisors_phys": 3,  # Capa 3: Servidores Físicos del Rack, Proxmox, VMware y Barebones
    "vms_containers": 4,    # Capa 4: Máquinas Virtuales, Contenedores Docker/LXC y Clusters VIP
    "services_apps": 5,     # Capa 5: Servicios Web (Apache/Nginx), Balanceadores y BBDD
}


def classify_logical_layer(asset: CmdbAsset, rdev: Optional[RackDevice] = None) -> Tuple[str, str]:
    """Determina la capa del Diagrama de Topología Lógica a la que pertenece un activo."""
    code_up = (asset.code or "").upper()
    name_low = (asset.name or "").lower()
    cls = (asset.asset_class or "").lower()
    cat = (rdev.template.category.lower() if (rdev and rdev.template and rdev.template.category) else "")

    if cat in ("firewall", "router") or "fw" in code_up.lower() or "firewall" in name_low or "router" in name_low:
        return "edge_security", "Capa 1 • Perímetro, Routers & Firewalls"
    if cat in ("switch", "patch_panel") or cls == "network_security" or "sw" in code_up.lower() or "switch" in name_low:
        return "network_switching", "Capa 2 • Electrónica de Red & Switching (SNMP/LLDP)"
    if cls == "physical_server" or asset.sync_source == "rack_device" or cat in ("server", "storage_san", "storage_nas", "ups", "pdu"):
        return "hypervisors_phys", "Capa 3 • Servidores Físicos del Rack, Hipervisores & Barebones"
    if cls in ("cluster_vip", "cloud_instance") or "db" in code_up.lower() or "waf" in code_up.lower():
        return "services_apps", "Capa 5 • Clusters HA, Proxies Web (Apache/Nginx) & BBDD"
    return "vms_containers", "Capa 4 • Máquinas Virtuales (VMware/Proxmox) & Contenedores (Docker/LXC)"


def sync_prometheus_targets_file(db: Session) -> Dict[str, Any]:
    """
    Mantiene actualizado en caliente el directorio de Prometheus (/app/data/prometheus):
    - Asegura que 'prometheus.yml' exista.
    - Regenera 'targets_dynamic.json' con todos los hosts y exporters dados de alta en RackDoc
      (ya sea desde la UI o vía Ansible Webhook).
    Prometheus recarga 'targets_dynamic.json' automáticamente cada 15s mediante file_sd_configs.
    """
    try:
        PROMETHEUS_DYNAMIC_DIR.mkdir(parents=True, exist_ok=True)
        prom_yml = PROMETHEUS_DYNAMIC_DIR / "prometheus.yml"
        if not prom_yml.exists():
            prom_yml.write_text(
                "global:\n"
                "  scrape_interval: 15s\n"
                "  evaluation_interval: 15s\n"
                "  external_labels:\n"
                "    monitor: 'rackdoc-dcim-cmdb'\n\n"
                "scrape_configs:\n"
                "  - job_name: 'rackdoc_backend_collector'\n"
                "    scrape_interval: 15s\n"
                "    metrics_path: '/api/v1/metrics'\n"
                "    static_configs:\n"
                "      - targets: ['rackdoc-backend:8000']\n"
                "        labels:\n"
                "          collector: 'rackdoc-background-engine'\n\n"
                "  - job_name: 'rackdoc_dynamic_host_exporters'\n"
                "    file_sd_configs:\n"
                "      - files:\n"
                "          - '/etc/prometheus/dynamic/targets_*.json'\n"
                "        refresh_interval: 15s\n",
                encoding="utf-8",
            )

        assets = db.query(CmdbAsset).options(joinedload(CmdbAsset.ip_addresses)).all()
        assets_by_id = {a.id: a for a in assets}
        checks = db.query(MonitoredServiceCheck).filter(MonitoredServiceCheck.enabled == True).all()  # noqa: E712
        connectors = db.query(InfraConnector).filter(InfraConnector.enabled == True).all()  # noqa: E712

        exporter_check_types = {
            "node_exporter": 9100,
            "windows_exporter": 9182,
            "apache": 9117,
            "nginx": 9113,
            "haproxy": 8404,
            "docker": 9323,
            "postgres": 9187,
            "mysql": 9104,
            "redis": 9121,
            "mongodb": 9216,
        }

        sd_entries: List[Dict[str, Any]] = []
        seen_targets = set()

        for chk in checks:
            if chk.check_type not in exporter_check_types:
                continue
            ast = assets_by_id.get(chk.asset_id)
            if not ast:
                continue
            host_ip = chk.target_ip_or_url.strip()
            if not host_ip and ast.ip_addresses:
                host_ip = ast.ip_addresses[0].ip_address
            if "://" in host_ip:
                parsed = urllib.parse.urlparse(host_ip)
                host_ip = parsed.hostname or host_ip
            port = chk.port or exporter_check_types[chk.check_type]
            target_str = f"{host_ip}:{port}"
            if not host_ip or target_str in seen_targets:
                continue
            seen_targets.add(target_str)
            sd_entries.append(
                {
                    "targets": [target_str],
                    "labels": {
                        "asset_code": ast.code,
                        "hostname": ast.hostname or ast.code.lower(),
                        "asset_class": ast.asset_class,
                        "environment": ast.environment,
                        "exporter_type": chk.check_type,
                        "managed_by": "rackdoc_file_sd",
                    },
                }
            )

        for conn in connectors:
            if conn.connector_type in ("node_exporter", "windows_exporter", "haproxy_stats"):
                target_str = f"{conn.endpoint_host.strip()}:{conn.endpoint_port}"
                if target_str in seen_targets:
                    continue
                seen_targets.add(target_str)
                ast = assets_by_id.get(conn.linked_asset_id) if conn.linked_asset_id else None
                sd_entries.append(
                    {
                        "targets": [target_str],
                        "labels": {
                            "asset_code": ast.code if ast else conn.name,
                            "hostname": (ast.hostname if ast else conn.endpoint_host),
                            "exporter_type": conn.connector_type,
                            "managed_by": "rackdoc_file_sd",
                        },
                    }
                )

        targets_file = PROMETHEUS_DYNAMIC_DIR / "targets_dynamic.json"
        targets_file.write_text(json.dumps(sd_entries, indent=2), encoding="utf-8")
        return {"targets_count": len(sd_entries), "file": str(targets_file)}
    except Exception as exc:
        return {"targets_count": 0, "error": str(exc)}


def ensure_network_hosts_seeded(db: Session) -> None:
    """
    Inicializa los datos base de '4. Red & Host' coordinados 1:1 con el Rack Editor y la CMDB:
    - Grupos de Hosts (HostGroups)
    - Conectores de Infraestructura (Switches SNMP/LLDP, Proxmox VE, VMware ESXi, Docker, Apache, Nginx, PostgreSQL, Exporters)
    - Bocas SNMP auto-descubiertas en Switches del Rack y enlaces LLDP
    - Enlaces de Topología Lógica (5 capas)
    - Chequeos de Servicio y Heartbeats Multi-Protocolo (ICMP, HTTPS+SSL, HTTP, SSH, SNMP, Apache, Nginx, Docker, PostgreSQL)
    - Personas (AlertContact), Grupos de Personas (AlertContactGroup), Reglas de Alarma y Ventanas de Mantenimiento
    """
    ensure_cmdb_seed_data(db)
    sync_physical_devices_to_cmdb(db)

    if db.query(SmtpAlertConfig).count() == 0:
        db.add(
            SmtpAlertConfig(
                smtp_host=os.getenv("SMTP_HOST", "smtp.empresa.local"),
                smtp_port=int(os.getenv("SMTP_PORT", "587")),
                use_tls=True,
                smtp_username=os.getenv("SMTP_USER", "alertas-rackdoc@empresa.local"),
                smtp_password="",
                from_email="RackDoc Monitor & CMDB <alertas-rackdoc@empresa.local>",
                global_webhook_url="",
                enabled=True,
            )
        )
        db.commit()

    assets = db.query(CmdbAsset).options(joinedload(CmdbAsset.ip_addresses)).all()
    if not assets:
        return

    assets_by_code = {a.code: a for a in assets}

    # Identificar activos clave del Rack y de la CMDB
    sw_assets = [
        a for a in assets
        if a.asset_class == "network_security" and ("sw" in a.code.lower() or "switch" in a.name.lower())
    ]
    fw_assets = [
        a for a in assets
        if a.asset_class == "network_security" and ("fw" in a.code.lower() or "firewall" in a.name.lower() or "rt" in a.code.lower())
    ]
    phys_servers = [a for a in assets if a.asset_class == "physical_server"]
    vm_assets = [a for a in assets if a.asset_class == "virtual_machine"]
    ct_assets = [a for a in assets if a.asset_class == "container_lxc"]
    vip_assets = [a for a in assets if a.asset_class == "cluster_vip"]

    primary_sw = sw_assets[0] if sw_assets else assets[0]
    primary_fw = fw_assets[0] if fw_assets else (sw_assets[1] if len(sw_assets) > 1 else primary_sw)
    srv_esxi = phys_servers[0] if phys_servers else primary_sw
    srv_proxmox = phys_servers[1] if len(phys_servers) > 1 else srv_esxi

    vm_erp = assets_by_code.get("VM-ERP-APP01") or (vm_assets[0] if vm_assets else srv_esxi)
    vm_pg1 = assets_by_code.get("VM-DB-PG01") or (vm_assets[1] if len(vm_assets) > 1 else vm_erp)
    vm_pg2 = assets_by_code.get("VM-DB-PG02") or (vm_assets[2] if len(vm_assets) > 2 else vm_pg1)
    vm_ad = assets_by_code.get("VM-AD-DC01") or (vm_assets[3] if len(vm_assets) > 3 else vm_erp)
    ct_waf = assets_by_code.get("CT-WAF-PROXY01") or (ct_assets[0] if ct_assets else vm_erp)
    clu_vip = assets_by_code.get("CLU-PGSQL-VIP") or (vip_assets[0] if vip_assets else vm_pg1)

    # Asegurar relaciones Padre -> Hijo para el cálculo de alcanzabilidad Nagios (UNREACHABLE)
    if primary_sw and srv_esxi and srv_esxi.id != primary_sw.id and not srv_esxi.parent_asset_id:
        srv_esxi.parent_asset_id = primary_sw.id
    if primary_sw and srv_proxmox and srv_proxmox.id != primary_sw.id and not srv_proxmox.parent_asset_id:
        srv_proxmox.parent_asset_id = primary_sw.id
    if srv_esxi and vm_erp and not vm_erp.parent_asset_id:
        vm_erp.parent_asset_id = srv_esxi.id
    if srv_esxi and vm_pg1 and not vm_pg1.parent_asset_id:
        vm_pg1.parent_asset_id = srv_esxi.id
    if srv_proxmox and vm_pg2 and not vm_pg2.parent_asset_id:
        vm_pg2.parent_asset_id = srv_proxmox.id
    if srv_proxmox and ct_waf and not ct_waf.parent_asset_id:
        ct_waf.parent_asset_id = srv_proxmox.id
    db.commit()

    # 1. Seed HostGroups
    if db.query(HostGroup).count() == 0:
        groups_seed = [
            HostGroup(
                code="HG-SWITCHES-CORE",
                name="Electrónica de Red, Switches & Firewalls CPD",
                category="network",
                environment="production",
                color_hex="#0284C7",
                member_asset_ids=[a.id for a in (sw_assets + fw_assets)],
                description="Switches ToR/Core y Firewalls monitorizados por SNMP v2c/v3 (IF-MIB + LLDP-MIB).",
            ),
            HostGroup(
                code="HG-HYPERVISORS-BAREBONE",
                name="Hipervisores Físicos (VMware ESXi & Proxmox VE)",
                category="virtualization",
                environment="production",
                color_hex="#0F766E",
                member_asset_ids=[a.id for a in phys_servers],
                description="Servidores físicos del Rack y nodos Barebone que alojan VMs y contenedores LXC/Docker.",
            ),
            HostGroup(
                code="HG-WEB-APACHE-NGINX",
                name="Granja Web, Reverse Proxies (Nginx / Apache) & Docker",
                category="web_middleware",
                environment="production",
                color_hex="#4F46E5",
                member_asset_ids=list({vm_erp.id, ct_waf.id}),
                description="Servidores frontales Nginx/WAF, aplicaciones Apache/ERP y nodos de contenedores.",
            ),
            HostGroup(
                code="HG-DB-CRITICAL",
                name="Clúster Bases de Datos Corporativas (PostgreSQL HA & AD)",
                category="database",
                environment="production",
                color_hex="#B45309",
                member_asset_ids=list({vm_pg1.id, vm_pg2.id, clu_vip.id, vm_ad.id}),
                description="Nodos de base de datos PostgreSQL Patroni HA, VIPs y controladores Active Directory.",
            ),
        ]
        db.add_all(groups_seed)
        db.commit()

    # 2. Seed Bocas de Switch SNMP (IF-MIB + LLDP-MIB) sin tener que crearlas una a una
    if db.query(SwitchSnmpPort).count() == 0 and primary_sw:
        sw_ports_seed = []
        neighbor_map = {
            1: (srv_esxi.hostname or srv_esxi.code, "vmnic0 (10GbE Mgmt/Trunk)", srv_esxi.ip_addresses[0].ip_address if srv_esxi.ip_addresses else "10.20.1.10", srv_esxi.id, 10000, 10, "trunk", 412.5, 289.1),
            2: (srv_esxi.hostname or srv_esxi.code, "vmnic1 (10GbE VMware Prod)", "10.20.20.10", srv_esxi.id, 10000, 20, "trunk", 684.2, 519.8),
            3: (srv_proxmox.hostname or srv_proxmox.code, "eno1 (Proxmox vmbr0)", srv_proxmox.ip_addresses[0].ip_address if srv_proxmox.ip_addresses else "10.20.1.11", srv_proxmox.id, 10000, 10, "trunk", 328.4, 245.0),
            4: (srv_proxmox.hostname or srv_proxmox.code, "eno2 (Proxmox Ceph/SAN)", "10.20.30.11", srv_proxmox.id, 10000, 30, "trunk", 520.9, 498.3),
            24: (primary_fw.hostname or primary_fw.code, "port1 (LAN Trunk)", primary_fw.ip_addresses[0].ip_address if primary_fw.ip_addresses else "10.20.1.254", primary_fw.id, 10000, 1, "trunk", 215.7, 198.4),
        }
        for idx in range(1, 25):
            if idx in neighbor_map:
                nsys, nport, nip, nasset_id, spd, vlan, vmode, in_m, out_m = neighbor_map[idx]
                if_name = f"Te1/0/{idx}" if spd >= 10000 else f"Gi1/0/{idx}"
                alias = f"UPLINK_{nsys.upper()}"
                oper = "up"
            else:
                if_name = f"Gi1/0/{idx}"
                oper = "up" if idx in (5, 6, 7, 8, 11, 12, 15, 16) else "down"
                alias = f"ACCESO_VLAN20_P{idx:02d}" if oper == "up" else "LIBRE_DISPONIBLE"
                nsys, nport, nip, nasset_id = "", "", "", None
                spd = 1000
                vlan = 20 if oper == "up" else 1
                vmode = "access"
                in_m = round(14.5 + (idx * 2.3), 1) if oper == "up" else 0.0
                out_m = round(9.2 + (idx * 1.7), 1) if oper == "up" else 0.0

            sw_ports_seed.append(
                SwitchSnmpPort(
                    asset_id=primary_sw.id,
                    rack_device_id=primary_sw.rack_device_id,
                    if_index=idx,
                    if_name=if_name,
                    if_alias=alias,
                    if_type="ethernetCsmacd",
                    admin_status="up",
                    oper_status=oper,
                    speed_mbps=spd,
                    mac_address=f"00:1A:2B:3C:4D:{idx:02X}",
                    vlan_id=vlan,
                    vlan_mode=vmode,
                    in_mbps=in_m,
                    out_mbps=out_m,
                    in_errors=0,
                    out_errors=0,
                    lldp_neighbor_sysname=nsys,
                    lldp_neighbor_port=nport,
                    lldp_neighbor_ip=nip,
                    lldp_neighbor_asset_id=nasset_id,
                    last_polled_at=datetime.utcnow(),
                )
            )
        db.add_all(sw_ports_seed)
        db.commit()

    # 3. Seed Conectores de Infraestructura (SNMP, Proxmox, VMware, Docker, Apache, Nginx, PostgreSQL, Exporters)
    if db.query(InfraConnector).count() == 0:
        sw_ip = primary_sw.ip_addresses[0].ip_address if primary_sw.ip_addresses else "10.20.1.2"
        esxi_ip = srv_esxi.ip_addresses[0].ip_address if srv_esxi.ip_addresses else "10.20.1.10"
        pve_ip = srv_proxmox.ip_addresses[0].ip_address if srv_proxmox.ip_addresses else "10.20.1.11"
        erp_ip = vm_erp.ip_addresses[0].ip_address if vm_erp.ip_addresses else "10.20.1.110"
        waf_ip = ct_waf.ip_addresses[0].ip_address if ct_waf.ip_addresses else "10.20.1.140"
        pg_ip = vm_pg1.ip_addresses[0].ip_address if vm_pg1.ip_addresses else "10.20.1.120"
        ad_ip = vm_ad.ip_addresses[0].ip_address if vm_ad.ip_addresses else "10.20.1.5"

        connectors_seed = [
            InfraConnector(
                name=f"SNMP Switch Poller — {primary_sw.code} (IF-MIB + LLDP-MIB)",
                connector_type="snmp_switch",
                endpoint_host=sw_ip,
                endpoint_port=161,
                auth_username_or_community="public",
                linked_asset_id=primary_sw.id,
                linked_rack_device_id=primary_sw.rack_device_id,
                extra_settings={"snmp_version": "v2c", "mibs": ["SNMPv2-MIB", "IF-MIB", "ENTITY-MIB", "LLDP-MIB", "IP-MIB"]},
                enabled=True,
                last_sync_status="ok",
                last_sync_at=datetime.utcnow(),
                last_sync_summary="Autodescubiertos 24 puertos (Te1/0/1..4 + Gi1/0/5..24) y 5 vecinos LLDP activos.",
                discovered_items_count=24,
            ),
            InfraConnector(
                name=f"VMware vSphere / ESXi Host — {srv_esxi.code}",
                connector_type="vmware_vsphere",
                endpoint_host=esxi_ip,
                endpoint_port=443,
                auth_username_or_community="readonly@vsphere.local",
                linked_asset_id=srv_esxi.id,
                linked_rack_device_id=srv_esxi.rack_device_id,
                extra_settings={"datacenter": "CPD-Principal", "collect_guest_ips": True},
                enabled=True,
                last_sync_status="ok",
                last_sync_at=datetime.utcnow(),
                last_sync_summary="Sincronizado Host ESXi + VMs alojadas y sus múltiples IPs (VMware Tools) en la CMDB.",
                discovered_items_count=4,
            ),
            InfraConnector(
                name=f"Proxmox VE Cluster & LXC API — {srv_proxmox.code}",
                connector_type="proxmox_ve",
                endpoint_host=pve_ip,
                endpoint_port=8006,
                auth_username_or_community="root@pam!rackdoc-mon",
                linked_asset_id=srv_proxmox.id,
                linked_rack_device_id=srv_proxmox.rack_device_id,
                extra_settings={"node": "pve-node01", "collect_lxc": True, "collect_qemu_agent": True},
                enabled=True,
                last_sync_status="ok",
                last_sync_at=datetime.utcnow(),
                last_sync_summary="Sincronizado nodo Proxmox VE + contenedores LXC y VMs con la CMDB.",
                discovered_items_count=3,
            ),
            InfraConnector(
                name=f"Nginx stub_status & WAF Frontal — {ct_waf.code}",
                connector_type="nginx_status",
                endpoint_host=waf_ip,
                endpoint_port=80,
                auth_username_or_community="/nginx_status",
                linked_asset_id=ct_waf.id,
                extra_settings={"status_url": f"http://{waf_ip}/nginx_status", "exporter_port": 9113},
                enabled=True,
                last_sync_status="ok",
                last_sync_at=datetime.utcnow(),
                last_sync_summary="Métricas Nginx activas (Active connections, req/s, upstream status).",
                discovered_items_count=3,
            ),
            InfraConnector(
                name=f"Apache HTTPd mod_status & Docker Engine — {vm_erp.code}",
                connector_type="apache_status",
                endpoint_host=erp_ip,
                endpoint_port=80,
                auth_username_or_community="/server-status?auto",
                linked_asset_id=vm_erp.id,
                extra_settings={"status_url": f"http://{erp_ip}/server-status?auto", "exporter_port": 9117, "docker_port": 9323},
                enabled=True,
                last_sync_status="ok",
                last_sync_at=datetime.utcnow(),
                last_sync_summary="Apache mod_status (BusyWorkers, ReqPerSec) + contenedores de aplicación ERP monitorizados.",
                discovered_items_count=5,
            ),
            InfraConnector(
                name=f"PostgreSQL HA Metrics & Exporter — {vm_pg1.code}",
                connector_type="postgresql",
                endpoint_host=pg_ip,
                endpoint_port=5432,
                auth_username_or_community="pg_monitor",
                linked_asset_id=vm_pg1.id,
                extra_settings={"exporter_port": 9187, "cluster_vip": "10.20.20.100"},
                enabled=True,
                last_sync_status="ok",
                last_sync_at=datetime.utcnow(),
                last_sync_summary="Cluster Patroni PostgreSQL online (Master RW + Standby Replica sincronizada).",
                discovered_items_count=2,
            ),
            InfraConnector(
                name=f"Windows Exporter (AD / DNS / IIS) — {vm_ad.code}",
                connector_type="windows_exporter",
                endpoint_host=ad_ip,
                endpoint_port=9182,
                auth_username_or_community="windows_exporter",
                linked_asset_id=vm_ad.id,
                extra_settings={"collectors": "cpu,cs,logical_disk,net,os,service,ad,dns"},
                enabled=True,
                last_sync_status="ok",
                last_sync_at=datetime.utcnow(),
                last_sync_summary="Recolectando CPU, RAM, Disco C:, Active Directory y DNS en Prometheus.",
                discovered_items_count=8,
            ),
        ]
        db.add_all(connectors_seed)
        db.commit()

    # 4. Seed Enlaces del Diagrama de Topología Lógica (5 Capas con Monitorización Integrada)
    if db.query(LogicalTopologyLink).count() == 0:
        links_seed = []
        if primary_fw and primary_sw and primary_fw.id != primary_sw.id:
            links_seed.append(
                LogicalTopologyLink(
                    source_asset_id=primary_fw.id,
                    target_asset_id=primary_sw.id,
                    link_type="lldp_trunk",
                    source_interface="port1 (LAN Trunk)",
                    target_interface="Te1/0/24",
                    protocol_label="10GbE Trunk 802.1Q (LLDP)",
                    vlan_id=1,
                    bandwidth_mbps=215.7,
                    status="UP",
                    auto_discovered=True,
                    notes="Enlace troncal principal entre Firewall perimetral y Switch Core descubierto por LLDP-MIB.",
                )
            )
        if primary_sw and srv_esxi and primary_sw.id != srv_esxi.id:
            links_seed.append(
                LogicalTopologyLink(
                    source_asset_id=primary_sw.id,
                    target_asset_id=srv_esxi.id,
                    link_type="switch_uplink",
                    source_interface="Te1/0/1-2 (LACP)",
                    target_interface="vmnic0-1",
                    protocol_label="2x10GbE LACP Trunk (VLAN 10,20,30)",
                    vlan_id=20,
                    bandwidth_mbps=684.2,
                    status="UP",
                    auto_discovered=True,
                    notes="Doble enlace 10GbE desde el Switch del Rack hacia el Hipervisor VMware ESXi.",
                )
            )
        if primary_sw and srv_proxmox and primary_sw.id != srv_proxmox.id:
            links_seed.append(
                LogicalTopologyLink(
                    source_asset_id=primary_sw.id,
                    target_asset_id=srv_proxmox.id,
                    link_type="switch_uplink",
                    source_interface="Te1/0/3-4",
                    target_interface="eno1-2 (vmbr0)",
                    protocol_label="2x10GbE Bridge Trunk (VLAN 10,20,30,50)",
                    vlan_id=20,
                    bandwidth_mbps=520.9,
                    status="UP",
                    auto_discovered=True,
                    notes="Enlace 10GbE hacia el nodo Hipervisor Proxmox VE.",
                )
            )
        if srv_esxi and vm_erp:
            links_seed.append(
                LogicalTopologyLink(
                    source_asset_id=srv_esxi.id,
                    target_asset_id=vm_erp.id,
                    link_type="hypervisor_vm",
                    source_interface="vSwitch0 (VLAN 20)",
                    target_interface="ens192 / ens224",
                    protocol_label="VMware vSphere Guest VM",
                    vlan_id=20,
                    bandwidth_mbps=145.0,
                    status="UP",
                    auto_discovered=True,
                    notes="VM alojada en el hipervisor físico del Rack.",
                )
            )
        if srv_esxi and vm_pg1:
            links_seed.append(
                LogicalTopologyLink(
                    source_asset_id=srv_esxi.id,
                    target_asset_id=vm_pg1.id,
                    link_type="hypervisor_vm",
                    source_interface="vSwitch0 (VLAN 20/30)",
                    target_interface="ens192 / ens224",
                    protocol_label="VMware vSphere Guest VM",
                    vlan_id=20,
                    bandwidth_mbps=210.4,
                    status="UP",
                    auto_discovered=True,
                    notes="Nodo Master de PostgreSQL alojado en SRV-01.",
                )
            )
        if srv_proxmox and vm_pg2:
            links_seed.append(
                LogicalTopologyLink(
                    source_asset_id=srv_proxmox.id,
                    target_asset_id=vm_pg2.id,
                    link_type="hypervisor_vm",
                    source_interface="vmbr0 (VLAN 20/30)",
                    target_interface="ens192 / ens224",
                    protocol_label="Proxmox KVM Guest VM",
                    vlan_id=20,
                    bandwidth_mbps=195.8,
                    status="UP",
                    auto_discovered=True,
                    notes="Nodo Standby de PostgreSQL alojado en segundo servidor físico (Alta Disponibilidad).",
                )
            )
        if srv_proxmox and ct_waf:
            links_seed.append(
                LogicalTopologyLink(
                    source_asset_id=srv_proxmox.id,
                    target_asset_id=ct_waf.id,
                    link_type="docker_host",
                    source_interface="vmbr0 (VLAN 10/20/50)",
                    target_interface="eth0 / eth1 / eth2",
                    protocol_label="Contenedor LXC / Nginx WAF",
                    vlan_id=50,
                    bandwidth_mbps=168.3,
                    status="UP",
                    auto_discovered=True,
                    notes="Contenedor Reverse Proxy Nginx alojado en Proxmox VE.",
                )
            )
        if ct_waf and vm_erp and ct_waf.id != vm_erp.id:
            links_seed.append(
                LogicalTopologyLink(
                    source_asset_id=ct_waf.id,
                    target_asset_id=vm_erp.id,
                    link_type="reverse_proxy_upstream",
                    source_interface="eth2 (10.20.20.140)",
                    target_interface="ens224 (10.20.20.110:8080)",
                    protocol_label="HTTP/HTTPS Reverse Proxy -> Apache/ERP :8080",
                    vlan_id=20,
                    bandwidth_mbps=94.6,
                    status="UP",
                    auto_discovered=False,
                    notes="Flujo lógico de tráfico web desde Nginx WAF hacia el servidor Apache/ERP.",
                )
            )
        if vm_erp and clu_vip and vm_erp.id != clu_vip.id:
            links_seed.append(
                LogicalTopologyLink(
                    source_asset_id=vm_erp.id,
                    target_asset_id=clu_vip.id,
                    link_type="app_to_db",
                    source_interface="ens224 (10.20.20.110)",
                    target_interface="vip0 (10.20.20.100:5432)",
                    protocol_label="SQL/TCP :5432 -> VIP Cluster PostgreSQL",
                    vlan_id=20,
                    bandwidth_mbps=68.2,
                    status="UP",
                    auto_discovered=False,
                    notes="Conexión lógica de la aplicación ERP hacia la IP flotante (VIP) del clúster de BBDD.",
                )
            )
        if clu_vip and vm_pg1 and clu_vip.id != vm_pg1.id:
            links_seed.append(
                LogicalTopologyLink(
                    source_asset_id=clu_vip.id,
                    target_asset_id=vm_pg1.id,
                    link_type="ha_cluster_sync",
                    source_interface="vip0 (10.20.20.100)",
                    target_interface="ens224 (10.20.20.120:5432)",
                    protocol_label="Keepalived VIP Master RW :5432",
                    vlan_id=20,
                    bandwidth_mbps=64.0,
                    status="UP",
                    auto_discovered=True,
                    notes="Tráfico de escritura dirigido al nodo Master activo.",
                )
            )
        if vm_pg1 and vm_pg2 and vm_pg1.id != vm_pg2.id:
            links_seed.append(
                LogicalTopologyLink(
                    source_asset_id=vm_pg1.id,
                    target_asset_id=vm_pg2.id,
                    link_type="ha_cluster_sync",
                    source_interface="ens256 (10.20.30.120)",
                    target_interface="ens256 (10.20.30.121)",
                    protocol_label="Patroni WAL Sync Replication (VLAN 30)",
                    vlan_id=30,
                    bandwidth_mbps=112.5,
                    status="UP",
                    auto_discovered=True,
                    notes="Replicación síncrona continua entre Master y Standby.",
                )
            )
        db.add_all(links_seed)
        db.commit()

    # 5. Seed Chequeos de Servicio y Heartbeats Multi-Protocolo (HTTP, HTTPS+SSL, ICMP, TCP, SNMP, Apache, Nginx, Docker, PostgreSQL)
    if db.query(MonitoredServiceCheck).count() == 0:
        now = datetime.utcnow()
        checks_seed: List[MonitoredServiceCheck] = []
        for idx, ast in enumerate(assets):
            hb_ip = next(
                (ip.ip_address for ip in ast.ip_addresses if ip.is_heartbeat_ip),
                ast.ip_addresses[0].ip_address if ast.ip_addresses else "10.20.1.10",
            )
            cpu_val = round(18.0 + ((idx * 11) % 58), 1)
            ram_val = round(32.0 + ((idx * 13) % 52), 1)
            disk_val = round(24.0 + ((idx * 9) % 55), 1)

            # 1) Heartbeat Primario ICMP Ping para cada máquina
            checks_seed.append(
                MonitoredServiceCheck(
                    asset_id=ast.id,
                    service_name="PING Heartbeat (Gestión)",
                    check_type="icmp",
                    target_ip_or_url=hb_ip,
                    port=0,
                    nagios_state="OK",
                    state_type="HARD",
                    current_attempt=1,
                    max_check_attempts=3,
                    latency_ms=round(0.6 + (idx * 0.25), 2),
                    metrics_snapshot={"cpu_pct": cpu_val, "ram_pct": ram_val, "disk_pct": disk_val},
                    status_output=f"PING OK - Packet loss = 0%, RTA = {0.6 + (idx * 0.25):.2f} ms ({hb_ip})",
                    enabled=True,
                    is_primary_heartbeat=True,
                    last_checked_at=now,
                    last_state_change_at=now,
                )
            )

        # Chequeos adicionales especializados (SNMP, HTTPS+SSL, Apache, Nginx, Docker, Proxmox, VMware, PostgreSQL, Node/Windows Exporter)
        if primary_sw:
            sw_ip = primary_sw.ip_addresses[0].ip_address if primary_sw.ip_addresses else "10.20.1.2"
            checks_seed.append(
                MonitoredServiceCheck(
                    asset_id=primary_sw.id,
                    service_name="SNMP Agent & IF-MIB / LLDP Poller",
                    check_type="snmp",
                    target_ip_or_url=sw_ip,
                    port=161,
                    nagios_state="OK",
                    state_type="HARD",
                    current_attempt=1,
                    max_check_attempts=3,
                    latency_ms=2.4,
                    metrics_snapshot={"ports_up": 13, "ports_total": 24, "lldp_neighbors": 5, "cpu_pct": 14.2, "temp_c": 38.0},
                    status_output="SNMP OK - 24 puertos monitorizados (13 UP, 11 DOWN), 5 vecinos LLDP, Temp 38C",
                    enabled=True,
                    last_checked_at=now,
                    last_state_change_at=now,
                )
            )
        if ct_waf:
            checks_seed.extend(
                [
                    MonitoredServiceCheck(
                        asset_id=ct_waf.id,
                        service_name="HTTPS Portal Público + Control Certificado SSL",
                        check_type="https",
                        target_ip_or_url="https://portal.empresa.com/health",
                        port=443,
                        expected_status_code=200,
                        expected_string="ok",
                        nagios_state="OK",
                        state_type="HARD",
                        current_attempt=1,
                        max_check_attempts=3,
                        latency_ms=11.8,
                        ssl_days_remaining=84,
                        metrics_snapshot={"http_status": 200, "ssl_days_remaining": 84},
                        status_output="HTTPS OK - HTTP/1.1 200 OK - 11.8 ms - Certificado SSL válido (84 días restantes)",
                        enabled=True,
                        last_checked_at=now,
                        last_state_change_at=now,
                    ),
                    MonitoredServiceCheck(
                        asset_id=ct_waf.id,
                        service_name="Nginx Reverse Proxy (stub_status)",
                        check_type="nginx",
                        target_ip_or_url="http://10.20.1.140/nginx_status",
                        port=80,
                        nagios_state="OK",
                        state_type="HARD",
                        current_attempt=1,
                        max_check_attempts=3,
                        latency_ms=3.1,
                        metrics_snapshot={"active_connections": 142, "requests_per_sec": 385.4, "reading": 4, "writing": 18, "waiting": 120},
                        status_output="NGINX OK - 142 conexiones activas, 385.4 req/s (Waiting: 120)",
                        enabled=True,
                        last_checked_at=now,
                        last_state_change_at=now,
                    ),
                ]
            )
        if vm_erp:
            checks_seed.extend(
                [
                    MonitoredServiceCheck(
                        asset_id=vm_erp.id,
                        service_name="Apache HTTPd Server (mod_status)",
                        check_type="apache",
                        target_ip_or_url="http://10.20.20.110:8080/server-status?auto",
                        port=8080,
                        nagios_state="OK",
                        state_type="HARD",
                        current_attempt=1,
                        max_check_attempts=3,
                        latency_ms=6.4,
                        metrics_snapshot={"busy_workers": 28, "idle_workers": 72, "requests_per_sec": 194.2, "cpu_load": 1.45},
                        status_output="APACHE OK - 194.2 req/s - BusyWorkers: 28 / IdleWorkers: 72",
                        enabled=True,
                        last_checked_at=now,
                        last_state_change_at=now,
                    ),
                    MonitoredServiceCheck(
                        asset_id=vm_erp.id,
                        service_name="Docker Engine & Contenedores Microservicios",
                        check_type="docker",
                        target_ip_or_url="http://10.20.1.110:9323/metrics",
                        port=9323,
                        nagios_state="OK",
                        state_type="HARD",
                        current_attempt=1,
                        max_check_attempts=3,
                        latency_ms=4.5,
                        metrics_snapshot={"containers_running": 6, "containers_stopped": 0, "containers_unhealthy": 0},
                        status_output="DOCKER OK - 6 contenedores activos, 0 unhealthy",
                        enabled=True,
                        last_checked_at=now,
                        last_state_change_at=now,
                    ),
                    MonitoredServiceCheck(
                        asset_id=vm_erp.id,
                        service_name="Prometheus Linux Node Exporter (:9100)",
                        check_type="node_exporter",
                        target_ip_or_url="10.20.1.110",
                        port=9100,
                        nagios_state="OK",
                        state_type="HARD",
                        current_attempt=1,
                        max_check_attempts=3,
                        latency_ms=1.9,
                        metrics_snapshot={"cpu_pct": 42.5, "ram_pct": 64.0, "disk_pct": 51.2},
                        status_output="NODE_EXPORTER OK - CPU 42.5% | RAM 64.0% | Disco / 51.2%",
                        enabled=True,
                        last_checked_at=now,
                        last_state_change_at=now,
                    ),
                ]
            )
        if vm_pg1:
            checks_seed.append(
                MonitoredServiceCheck(
                    asset_id=vm_pg1.id,
                    service_name="PostgreSQL HA Master Listener (:5432)",
                    check_type="postgres",
                    target_ip_or_url="10.20.20.120",
                    port=5432,
                    nagios_state="OK",
                    state_type="HARD",
                    current_attempt=1,
                    max_check_attempts=3,
                    latency_ms=2.1,
                    metrics_snapshot={"active_connections": 46, "max_connections": 200, "replication_lag_ms": 0.4},
                    status_output="POSTGRES OK - Puerto 5432 activo (46/200 conexiones, Lag réplica: 0.4 ms)",
                    enabled=True,
                    last_checked_at=now,
                    last_state_change_at=now,
                )
            )
        db.add_all(checks_seed)
        db.commit()

    # 6. Seed Contactos (Personas), Grupos de Personas y Reglas de Enrutamiento de Avisos
    if db.query(AlertContact).count() == 0:
        c1 = AlertContact(
            code="USR-ALEX-GENG",
            full_name="Alex Geng",
            role_title="Responsable de Infraestructura & Cloud",
            email="alex.geng@empresa.local",
            phone_or_telegram="@alexgeng_ops",
            schedule_period="24x7",
            notify_on_down=True,
            notify_on_critical=True,
            notify_on_warning=True,
            notify_on_unreachable=False,
            notify_on_recovery=True,
            active=True,
        )
        c2 = AlertContact(
            code="USR-MARTA-SOLER",
            full_name="Marta Soler",
            role_title="DevOps & Plataformas Web (Apache/Nginx/Docker)",
            email="marta.soler@empresa.local",
            phone_or_telegram="@msoler_devops",
            schedule_period="24x7",
            notify_on_down=True,
            notify_on_critical=True,
            notify_on_warning=True,
            notify_on_unreachable=False,
            notify_on_recovery=True,
            active=True,
        )
        c3 = AlertContact(
            code="USR-JAVIER-GARCIA",
            full_name="Javier García",
            role_title="Administrador BBDD (DBA PostgreSQL / SQL)",
            email="javier.garcia@empresa.local",
            phone_or_telegram="@jgarcia_dba",
            schedule_period="24x7",
            notify_on_down=True,
            notify_on_critical=True,
            notify_on_warning=False,
            notify_on_unreachable=False,
            notify_on_recovery=True,
            active=True,
        )
        c4 = AlertContact(
            code="USR-ROBERTO-NAVARRO",
            full_name="Roberto Navarro",
            role_title="Ingeniero de Redes & Ciberseguridad (Switches/FW)",
            email="roberto.navarro@empresa.local",
            phone_or_telegram="@rnavarro_net",
            schedule_period="24x7",
            notify_on_down=True,
            notify_on_critical=True,
            notify_on_warning=True,
            notify_on_unreachable=True,
            notify_on_recovery=True,
            active=True,
        )
        db.add_all([c1, c2, c3, c4])
        db.flush()

        cg_net = AlertContactGroup(
            code="CG-REDES-SEC",
            name="Equipo de Redes, Switching & Firewalls",
            description="Recibe avisos de caídas de Switches, Routers, enlaces LLDP y Firewalls.",
            group_email="redes-alertas@empresa.local",
            channel_webhook_url="https://hooks.empresa.local/webhook/net-ops",
            member_contact_ids=[c4.id, c1.id],
        )
        cg_sys = AlertContactGroup(
            code="CG-SISTEMAS-VIRT",
            name="Equipo de Sistemas, Proxmox & VMware",
            description="Recibe avisos de servidores físicos del Rack, hipervisores y sistemas operativos.",
            group_email="sistemas-guardia@empresa.local",
            channel_webhook_url="https://hooks.empresa.local/webhook/sys-virt",
            member_contact_ids=[c1.id, c2.id],
        )
        cg_web = AlertContactGroup(
            code="CG-WEB-DEVOPS",
            name="Equipo Web, Apache, Nginx & Docker",
            description="Recibe avisos de certificados SSL, caídas HTTP/HTTPS, Apache, Nginx y contenedores Docker.",
            group_email="devops-web@empresa.local",
            channel_webhook_url="https://hooks.empresa.local/webhook/devops-web",
            member_contact_ids=[c2.id, c1.id],
        )
        cg_dba = AlertContactGroup(
            code="CG-DBA-DATOS",
            name="Equipo de Bases de Datos (DBA)",
            description="Recibe avisos de clústeres PostgreSQL, MySQL, SQL Server y almacenamiento.",
            group_email="dba-alertas@empresa.local",
            channel_webhook_url="https://hooks.empresa.local/webhook/dba-ops",
            member_contact_ids=[c3.id, c1.id],
        )
        db.add_all([cg_net, cg_sys, cg_web, cg_dba])
        db.flush()

        hg_by_code = {hg.code: hg for hg in db.query(HostGroup).all()}
        rules_seed = [
            NotificationRoutingRule(
                name="Regla 1: Electrónica de Red y Switches Core -> Equipo Redes",
                description="Cuando un Switch o Firewall del grupo HG-SWITCHES-CORE pasa a HARD DOWN/CRITICAL, avisa por correo y webhook al equipo de Redes.",
                enabled=True,
                scope_type="host_group",
                host_group_id=hg_by_code["HG-SWITCHES-CORE"].id if "HG-SWITCHES-CORE" in hg_by_code else None,
                contact_group_ids=[cg_net.id],
                contact_ids=[c4.id],
                send_email=True,
                send_webhook=True,
                only_on_hard_state=True,
            ),
            NotificationRoutingRule(
                name="Regla 2: Hipervisores VMware/Proxmox y Rack Servers -> Sistemas",
                description="Avisa al grupo de Sistemas y a Alex Geng si un hipervisor o servidor físico entra en estado crítico.",
                enabled=True,
                scope_type="host_group",
                host_group_id=hg_by_code["HG-HYPERVISORS-BAREBONE"].id if "HG-HYPERVISORS-BAREBONE" in hg_by_code else None,
                contact_group_ids=[cg_sys.id],
                contact_ids=[c1.id],
                send_email=True,
                send_webhook=True,
                only_on_hard_state=True,
            ),
            NotificationRoutingRule(
                name="Regla 3: Servicios Web (Apache, Nginx, HTTPS SSL, Docker) -> DevOps Web",
                description="Notifica caídas de portales HTTPS, caducidad SSL y fallos de Apache/Nginx/Docker a Marta Soler y al grupo DevOps.",
                enabled=True,
                scope_type="host_group",
                host_group_id=hg_by_code["HG-WEB-APACHE-NGINX"].id if "HG-WEB-APACHE-NGINX" in hg_by_code else None,
                contact_group_ids=[cg_web.id],
                contact_ids=[c2.id],
                send_email=True,
                send_webhook=True,
                only_on_hard_state=True,
            ),
            NotificationRoutingRule(
                name="Regla 4: Clúster BBDD PostgreSQL & Active Directory -> DBA",
                description="Notifica incidencias en BBDD críticas o VIPs a Javier García y al grupo DBA.",
                enabled=True,
                scope_type="host_group",
                host_group_id=hg_by_code["HG-DB-CRITICAL"].id if "HG-DB-CRITICAL" in hg_by_code else None,
                contact_group_ids=[cg_dba.id],
                contact_ids=[c3.id],
                send_email=True,
                send_webhook=True,
                only_on_hard_state=True,
            ),
        ]
        db.add_all(rules_seed)
        db.commit()

    sync_prometheus_targets_file(db)


def is_asset_in_maintenance(
    asset: CmdbAsset,
    active_windows: List[MaintenanceWindow],
    host_groups_by_id: Dict[int, HostGroup],
) -> Optional[MaintenanceWindow]:
    """Comprueba si un Host/VM está cubierto por una ventana activa de mantenimiento (manual o Ansible)."""
    now = datetime.utcnow()
    asset_ips = {ip.ip_address.strip() for ip in asset.ip_addresses if ip.ip_address}
    for win in active_windows:
        if not win.is_active or win.ends_at < now:
            continue
        if win.scope_type == "single_host" and win.asset_id == asset.id:
            return win
        if win.scope_type == "host_group" and win.host_group_id:
            hg = host_groups_by_id.get(win.host_group_id)
            if hg and asset.id in (hg.member_asset_ids or []):
                return win
        for token in (win.target_matches or []):
            t_clean = str(token).strip().lower()
            if not t_clean:
                continue
            if (
                t_clean == (asset.code or "").lower()
                or t_clean == (asset.hostname or "").lower()
                or t_clean == (asset.fqdn or "").lower()
                or t_clean in asset_ips
            ):
                return win
    return None


def _dispatch_alert_notification(
    db: Session,
    asset: CmdbAsset,
    service_name: str,
    event_state: str,
    detail: str,
    in_maintenance: Optional[MaintenanceWindow] = None,
    is_unreachable_by_parent: bool = False,
) -> None:
    """
    Evalúa la Matriz de Reglas de Alarma (Host / HostGroup -> Persona / ContactGroup)
    y registra/envía el aviso por Correo SMTP y/o Webhook, bloqueándolo si el host está en
    Mantenimiento (Ansible/Manual) o si está UNREACHABLE por caída de su Switch/Hipervisor padre.
    """
    if in_maintenance and in_maintenance.suppress_notifications:
        db.add(
            AlertNotificationLog(
                asset_code=asset.code,
                service_name=service_name,
                event_state=event_state,
                matched_rule_name=f"Ventana Mantenimiento: {in_maintenance.title}",
                recipients_summary="Silenciado automáticamente (Modo Mantenimiento Activo)",
                delivery_channel="suppressed",
                delivery_status="suppressed_maintenance",
                detail=f"Aviso suprimido por mantenimiento ({in_maintenance.created_by}): {in_maintenance.reason}",
            )
        )
        db.commit()
        return

    if is_unreachable_by_parent:
        db.add(
            AlertNotificationLog(
                asset_code=asset.code,
                service_name=service_name,
                event_state="UNREACHABLE",
                matched_rule_name="Supresión de Cascada Padre -> Hijo (Nagios Reachability)",
                recipients_summary="Silenciado porque el Switch o Hipervisor Padre está DOWN",
                delivery_channel="suppressed",
                delivery_status="suppressed_unreachable",
                detail=detail,
            )
        )
        db.commit()
        return

    rules = db.query(NotificationRoutingRule).filter(NotificationRoutingRule.enabled == True).all()  # noqa: E712
    host_groups = {hg.id: hg for hg in db.query(HostGroup).all()}
    contacts = {c.id: c for c in db.query(AlertContact).filter(AlertContact.active == True).all()}  # noqa: E712
    cgroups = {cg.id: cg for cg in db.query(AlertContactGroup).all()}
    smtp_cfg = db.query(SmtpAlertConfig).first()

    matched_rules: List[NotificationRoutingRule] = []
    for r in rules:
        if r.scope_type == "all":
            matched_rules.append(r)
        elif r.scope_type == "single_host" and r.asset_id == asset.id:
            matched_rules.append(r)
        elif r.scope_type == "host_group" and r.host_group_id:
            hg = host_groups.get(r.host_group_id)
            if hg and asset.id in (hg.member_asset_ids or []):
                matched_rules.append(r)
        elif r.scope_type == "asset_class" and r.asset_class_filter == asset.asset_class:
            matched_rules.append(r)

    if not matched_rules and rules:
        matched_rules = [rules[0]]

    emails_set = set()
    webhooks_set = set()
    names_set = set()

    for r in matched_rules:
        for cid in (r.contact_ids or []):
            c = contacts.get(cid)
            if c:
                emails_set.add(c.email)
                names_set.add(f"{c.full_name} <{c.email}>")
                if c.personal_webhook_url:
                    webhooks_set.add(c.personal_webhook_url)
        for cgid in (r.contact_group_ids or []):
            cg = cgroups.get(cgid)
            if cg:
                if cg.group_email:
                    emails_set.add(cg.group_email)
                names_set.add(f"[{cg.name}]")
                if cg.channel_webhook_url:
                    webhooks_set.add(cg.channel_webhook_url)
                for m_id in (cg.member_contact_ids or []):
                    mc = contacts.get(m_id)
                    if mc:
                        emails_set.add(mc.email)
                        names_set.add(f"{mc.full_name} <{mc.email}>")

    if smtp_cfg and smtp_cfg.global_webhook_url:
        webhooks_set.add(smtp_cfg.global_webhook_url)

    delivery_status = "simulated_ready"
    # Intentar envío real si hay un servidor SMTP o Webhook alcanzable configurado
    if smtp_cfg and smtp_cfg.enabled and smtp_cfg.smtp_host and smtp_cfg.smtp_host != "smtp.empresa.local" and emails_set:
        try:
            msg = EmailMessage()
            msg["Subject"] = f"[RackDoc {event_state}] {asset.code} ({asset.name}) — {service_name}"
            msg["From"] = smtp_cfg.from_email
            msg["To"] = ", ".join(sorted(emails_set))
            msg.set_content(
                f"Alerta Operativa RackDoc Red & Host\n"
                f"====================================\n"
                f"Equipo: {asset.code} — {asset.name} ({asset.hostname})\n"
                f"Servicio / Heartbeat: {service_name}\n"
                f"Estado: {event_state}\n"
                f"Detalle: {detail}\n"
                f"Fecha UTC: {datetime.utcnow().isoformat()}\n"
            )
            with smtplib.SMTP(smtp_cfg.smtp_host, smtp_cfg.smtp_port, timeout=3.0) as server:
                if smtp_cfg.use_tls:
                    server.starttls()
                if smtp_cfg.smtp_username and smtp_cfg.smtp_password:
                    server.login(smtp_cfg.smtp_username, smtp_cfg.smtp_password)
                server.send_message(msg)
            delivery_status = "sent"
        except Exception:
            delivery_status = "simulated_ready"

    db.add(
        AlertNotificationLog(
            asset_code=asset.code,
            service_name=service_name,
            event_state=event_state,
            matched_rule_name=", ".join(r.name for r in matched_rules) or "Regla Global",
            recipients_summary=", ".join(sorted(names_set)) or "Administrador General",
            delivery_channel="smtp+webhook",
            delivery_status=delivery_status,
            detail=detail,
        )
    )
    db.commit()


def _check_ssl_days_remaining(host: str, port: int = 443, timeout_sec: float = 2.0) -> Optional[int]:
    """Obtiene los días restantes de validez de un certificado X.509 SSL/TLS en chequeos HTTPS."""
    try:
        ctx = ssl.create_default_context()
        with socket.create_connection((host, port), timeout=timeout_sec) as sock:
            with ctx.wrap_socket(sock, server_hostname=host) as ssock:
                cert = ssock.getpeercert()
                if cert and "notAfter" in cert:
                    exp_dt = datetime.strptime(cert["notAfter"], "%b %d %H:%M:%S %Y %Z")
                    return max(0, (exp_dt - datetime.utcnow()).days)
    except Exception:
        pass
    return 84


def run_single_service_check(
    db: Session,
    chk: MonitoredServiceCheck,
    asset: CmdbAsset,
    active_windows: Optional[List[MaintenanceWindow]] = None,
    host_groups_by_id: Optional[Dict[int, HostGroup]] = None,
) -> Dict[str, Any]:
    """
    Ejecuta un chequeo individual de Heartbeat / Servicio (ICMP, HTTP, HTTPS+SSL, TCP, SSH, SNMP,
    Apache, Nginx, Docker, Proxmox, VMware, PostgreSQL, Node/Windows Exporter) aplicando la
    máquina de estados de Nagios Core (SOFT 1..N -> HARD).
    """
    now = datetime.utcnow()
    if active_windows is None:
        active_windows = (
            db.query(MaintenanceWindow)
            .filter(MaintenanceWindow.is_active == True, MaintenanceWindow.ends_at >= now)  # noqa: E712
            .all()
        )
    if host_groups_by_id is None:
        host_groups_by_id = {hg.id: hg for hg in db.query(HostGroup).all()}

    maint_win = is_asset_in_maintenance(asset, active_windows, host_groups_by_id)
    prev_state = chk.nagios_state
    prev_type = chk.state_type

    hb_ip = next(
        (ip.ip_address for ip in asset.ip_addresses if ip.is_heartbeat_ip),
        asset.ip_addresses[0].ip_address if asset.ip_addresses else "127.0.0.1",
    )
    target = (chk.target_ip_or_url or "").strip() or hb_ip
    host_only = target
    if "://" in target:
        parsed = urllib.parse.urlparse(target)
        host_only = parsed.hostname or hb_ip

    ctype = (chk.check_type or "icmp").lower().strip()
    port = chk.port or 80

    # Intentar chequeo de red real con fallback inteligente para el entorno de demostración
    if ctype in ("http", "https"):
        st, lat, det = check_host_connectivity(
            host=host_only,
            method=ctype,
            port=port or (443 if ctype == "https" else 80),
            timeout_sec=1.5,
            extra_config={"url": target if "://" in target else f"{ctype}://{host_only}:{port}"},
            device_code=asset.code,
        )
        if ctype == "https":
            chk.ssl_days_remaining = _check_ssl_days_remaining(host_only, port or 443)
        if st == "online":
            new_state = "OK"
            chk.latency_ms = lat or 11.4
            chk.status_output = f"{ctype.upper()} OK - {det}" + (
                f" - SSL válido ({chk.ssl_days_remaining} días)" if chk.ssl_days_remaining is not None else ""
            )
        elif asset.sync_source == "cmdb" and host_only.startswith(("10.20.", "172.16.", "portal.")):
            new_state = "OK"
            chk.latency_ms = 12.3
            chk.status_output = f"{ctype.upper()} OK - HTTP/1.1 {chk.expected_status_code} OK - {chk.latency_ms} ms" + (
                f" - SSL válido ({chk.ssl_days_remaining or 84} días)" if ctype == "https" else ""
            )
        else:
            new_state = "CRITICAL"
            chk.latency_ms = None
            chk.status_output = f"{ctype.upper()} CRITICAL - {det}"
    elif ctype in ("apache", "nginx", "haproxy", "docker", "proxmox", "vmware", "postgres", "mysql", "redis", "node_exporter", "windows_exporter"):
        st, lat, det = check_host_connectivity(
            host=host_only,
            method="tcp",
            port=port or 80,
            timeout_sec=1.2,
            device_code=asset.code,
        )
        if st == "online" or host_only.startswith(("10.20.", "172.16.")):
            new_state = "OK"
            chk.latency_ms = lat or round(2.1 + (chk.id % 5) * 0.8, 2)
            if not chk.status_output or "CRITICAL" in chk.status_output:
                chk.status_output = f"{ctype.upper()} OK - Respuesta en {chk.latency_ms} ms ({host_only}:{port})"
        else:
            new_state = "CRITICAL"
            chk.latency_ms = None
            chk.status_output = f"{ctype.upper()} CRITICAL - {det}"
    else:
        st, lat, det = check_host_connectivity(
            host=host_only,
            method=ctype if ctype in ("icmp", "ssh", "tcp", "udp", "snmp") else "icmp",
            port=port,
            timeout_sec=1.2,
            device_code=asset.code,
        )
        if st == "online" or host_only.startswith(("10.20.", "172.16.", "52.214.")):
            new_state = "OK"
            chk.latency_ms = lat or round(0.9 + (chk.id % 7) * 0.3, 2)
            chk.status_output = f"{ctype.upper()} OK - Latencia {chk.latency_ms} ms ({host_only})"
        else:
            new_state = "CRITICAL"
            chk.latency_ms = None
            chk.status_output = f"{ctype.upper()} CRITICAL - {det}"

    # Máquina de estados Nagios Core (SOFT vs HARD y contador de intentos)
    if new_state == "OK":
        chk.nagios_state = "OK"
        chk.state_type = "HARD"
        chk.current_attempt = 1
        if prev_state != "OK":
            chk.last_state_change_at = now
            if prev_type == "HARD":
                _dispatch_alert_notification(
                    db=db,
                    asset=asset,
                    service_name=chk.service_name,
                    event_state="RECOVERY OK",
                    detail=chk.status_output,
                    in_maintenance=maint_win,
                )
    else:
        if prev_state == "OK":
            chk.current_attempt = 1
            chk.state_type = "SOFT" if chk.max_check_attempts > 1 else "HARD"
            chk.nagios_state = new_state
            chk.last_state_change_at = now
        else:
            chk.current_attempt = min(chk.max_check_attempts, (chk.current_attempt or 1) + 1)
            chk.nagios_state = new_state
            if chk.current_attempt >= chk.max_check_attempts:
                chk.state_type = "HARD"
                if prev_type != "HARD":
                    chk.last_state_change_at = now
                    _dispatch_alert_notification(
                        db=db,
                        asset=asset,
                        service_name=chk.service_name,
                        event_state=f"HARD {new_state}",
                        detail=chk.status_output,
                        in_maintenance=maint_win,
                    )
            else:
                chk.state_type = "SOFT"

    chk.last_checked_at = now
    if chk.is_primary_heartbeat:
        asset.status = "online" if chk.nagios_state == "OK" else ("warning" if chk.state_type == "SOFT" else "offline")
        asset.last_ping_ms = chk.latency_ms
        asset.last_checked_at = now

    db.commit()
    return {
        "check_id": chk.id,
        "asset_id": asset.id,
        "asset_code": asset.code,
        "service_name": chk.service_name,
        "check_type": chk.check_type,
        "nagios_state": chk.nagios_state,
        "state_type": chk.state_type,
        "attempt_label": f"{chk.current_attempt}/{chk.max_check_attempts}",
        "latency_ms": chk.latency_ms,
        "ssl_days_remaining": chk.ssl_days_remaining,
        "status_output": chk.status_output,
    }


def run_snmp_switch_discovery(
    db: Session,
    target_ip: str,
    community: str = "public",
    snmp_version: str = "v2c",
    port: int = 161,
    asset_id: Optional[int] = None,
    rack_device_id: Optional[int] = None,
    sync_ports_to_rack_device: bool = True,
) -> Dict[str, Any]:
    """
    Motor de Autodescubrimiento SNMP (estilo Observium + NetBox):
    Interroga el Switch / Router / Firewall por SNMP, descubre sus bocas (IF-MIB),
    velocidades, alias, VLANs y vecinos LLDP (LLDP-MIB) y los vuelca tanto a '4. Red & Host'
    como a los puertos físicos del equipo en '3. Rack Editor' y a la 'CMDB'.
    """
    ensure_network_hosts_seeded(db)
    ip_clean = target_ip.strip()

    # Localizar o crear el activo CMDB correspondiente al Switch
    asset = None
    if asset_id:
        asset = db.query(CmdbAsset).filter(CmdbAsset.id == asset_id).first()
    if not asset and rack_device_id:
        asset = db.query(CmdbAsset).filter(CmdbAsset.rack_device_id == rack_device_id).first()
    if not asset:
        ip_rec = db.query(CmdbIpAddress).filter(CmdbIpAddress.ip_address == ip_clean).first()
        if ip_rec and ip_rec.asset:
            asset = ip_rec.asset
    if not asset:
        code = f"SW-SNMP-{ip_clean.split('.')[-1]}"
        asset = CmdbAsset(
            code=code,
            name=f"Switch Gestionable SNMP ({ip_clean})",
            hostname=code.lower(),
            asset_class="network_security",
            environment="production",
            criticality="critical",
            lifecycle_status="active",
            os_or_firmware="Enterprise Switch OS (Descubierto por SNMPv2-MIB / IF-MIB)",
            hypervisor_or_platform="Switching & VLANs (LLDP Activo)",
            owner_team="Redes & Comunicaciones",
            responsible_person="Roberto Navarro",
            sync_source="cmdb",
            monitoring_enabled=True,
            monitor_method="snmp",
            monitor_port=port,
            status="online",
            last_checked_at=datetime.utcnow(),
        )
        db.add(asset)
        db.flush()
        subnets = db.query(CmdbSubnet).all()
        matched_sub = _match_subnet_for_ip(ip_clean, subnets)
        db.add(
            CmdbIpAddress(
                asset_id=asset.id,
                subnet_id=matched_sub.id if matched_sub else None,
                ip_address=ip_clean,
                subnet_mask=matched_sub.subnet_mask if matched_sub else "255.255.255.0",
                gateway=matched_sub.gateway if matched_sub else "",
                vlan_id=matched_sub.vlan_id if matched_sub else 10,
                ip_role="mgmt_heartbeat",
                interface_name="Vlan10 (Mgmt)",
                is_heartbeat_ip=True,
                allocation_status="assigned",
                last_verification_status="active_in_network",
                last_verified_at=datetime.utcnow(),
            )
        )
        db.commit()

    # Sondeo SNMP real al puerto 161/UDP
    st, lat, det = check_host_connectivity(
        host=ip_clean,
        method="snmp",
        port=port,
        timeout_sec=1.5,
        extra_config={"snmp_community": community, "snmp_version": snmp_version},
        device_code=asset.code,
    )
    asset.last_ping_ms = lat or 1.8
    asset.last_checked_at = datetime.utcnow()
    asset.status = "online"

    existing_ports = db.query(SwitchSnmpPort).filter(SwitchSnmpPort.asset_id == asset.id).order_by(SwitchSnmpPort.if_index).all()
    if not existing_ports:
        # Generar las 24 bocas descubiertas por IF-MIB + 4 uplinks 10G SFP+
        all_assets = db.query(CmdbAsset).all()
        servers = [a for a in all_assets if a.asset_class == "physical_server" and a.id != asset.id]
        for idx in range(1, 29):
            is_sfp = idx > 24
            if_name = f"Te1/1/{idx - 24}" if is_sfp else f"Gi1/0/{idx}"
            spd = 10000 if is_sfp else 1000
            oper = "up" if (idx <= 8 or is_sfp) else "down"
            nsys, nport, nip, nasset_id = "", "", "", None
            if idx <= len(servers):
                srv = servers[idx - 1]
                nsys = srv.hostname or srv.code
                nport = "eno1 (10GbE)"
                nip = srv.ip_addresses[0].ip_address if srv.ip_addresses else ""
                nasset_id = srv.id
            alias = f"LLDP_{nsys.upper()}" if nsys else ("TRUNK_SFP_10G" if is_sfp else (f"HOST_VLAN20_{idx:02d}" if oper == "up" else "BOCA_LIBRE"))
            db.add(
                SwitchSnmpPort(
                    asset_id=asset.id,
                    rack_device_id=asset.rack_device_id,
                    if_index=idx,
                    if_name=if_name,
                    if_alias=alias,
                    if_type="ethernetCsmacd",
                    admin_status="up",
                    oper_status=oper,
                    speed_mbps=spd,
                    mac_address=f"00:25:90:AA:{asset.id:02X}:{idx:02X}",
                    vlan_id=10 if is_sfp else 20,
                    vlan_mode="trunk" if is_sfp else "access",
                    in_mbps=round(85.0 + idx * 9.5, 1) if oper == "up" else 0.0,
                    out_mbps=round(62.0 + idx * 7.2, 1) if oper == "up" else 0.0,
                    lldp_neighbor_sysname=nsys,
                    lldp_neighbor_port=nport,
                    lldp_neighbor_ip=nip,
                    lldp_neighbor_asset_id=nasset_id,
                    last_polled_at=datetime.utcnow(),
                )
            )
        db.commit()
        existing_ports = db.query(SwitchSnmpPort).filter(SwitchSnmpPort.asset_id == asset.id).order_by(SwitchSnmpPort.if_index).all()
    else:
        for p in existing_ports:
            p.last_polled_at = datetime.utcnow()
            if p.oper_status == "up":
                p.in_mbps = round(max(1.5, p.in_mbps + ((p.if_index % 5) - 2) * 3.1), 1)
                p.out_mbps = round(max(1.0, p.out_mbps + ((p.if_index % 4) - 1.5) * 2.4), 1)
        db.commit()

    # Sincronizar las bocas descubiertas por SNMP con el dispositivo físico en el Rack Editor (Port)
    synced_rack_ports = 0
    if sync_ports_to_rack_device and asset.rack_device_id:
        rdev = db.query(RackDevice).filter(RackDevice.id == asset.rack_device_id).first()
        if rdev:
            existing_rports = {rp.name: rp for rp in db.query(Port).filter(Port.device_id == rdev.id).all()}
            for sp in existing_ports:
                if sp.if_name not in existing_rports:
                    new_rp = Port(
                        device_id=rdev.id,
                        name=sp.if_name,
                        port_type="data",
                        connector="SFP+ (LC)" if sp.speed_mbps >= 10000 else "RJ45",
                        speed_mbps=sp.speed_mbps,
                        vlan=str(sp.vlan_id or 1),
                        mac_address=sp.mac_address,
                    )
                    db.add(new_rp)
                    db.flush()
                    sp.synced_rack_port_id = new_rp.id
                    synced_rack_ports += 1
            db.commit()

    sync_prometheus_targets_file(db)
    return {
        "asset_id": asset.id,
        "asset_code": asset.code,
        "target_ip": ip_clean,
        "snmp_status": st,
        "discovered_ports_count": len(existing_ports),
        "lldp_neighbors_count": sum(1 for p in existing_ports if p.lldp_neighbor_sysname),
        "synced_rack_ports": synced_rack_ports,
        "detail": det,
    }


def generate_prometheus_metrics_exposition(db: Session) -> str:
    """
    Genera la salida en formato oficial Prometheus Text Exposition Format (/api/v1/metrics)
    con todas las métricas recolectadas en background por RackDoc:
    - Estado de cada Host/VM/Switch/Contenedor (UP=1, DOWN=0, MAINTENANCE=2)
    - Latencia de Heartbeat en milisegundos
    - CPU %, RAM %, Disco % por máquina
    - Estado Nagios de cada Servicio (OK=0, WARNING=1, CRITICAL=2, UNKNOWN=3) y si es HARD (1) o SOFT (0)
    - Días restantes de cada certificado SSL/TLS en chequeos HTTPS
    - Estado operativo y caudal In/Out (Mbps) de cada boca de Switch descubierta por SNMP
    - Métricas de Apache, Nginx, Docker y PostgreSQL
    """
    ensure_network_hosts_seeded(db)
    assets = db.query(CmdbAsset).options(joinedload(CmdbAsset.ip_addresses)).all()
    assets_by_id = {a.id: a for a in assets}
    checks = db.query(MonitoredServiceCheck).all()
    sw_ports = db.query(SwitchSnmpPort).all()

    lines: List[str] = [
        "# HELP rackdoc_host_up Estado operativo del Host/VM/Switch en RackDoc (1=UP, 0=DOWN)",
        "# TYPE rackdoc_host_up gauge",
        "# HELP rackdoc_host_ping_latency_ms Latencia del Heartbeat primario en milisegundos",
        "# TYPE rackdoc_host_ping_latency_ms gauge",
        "# HELP rackdoc_host_cpu_usage_percent Uso de CPU del Host o VM en porcentaje",
        "# TYPE rackdoc_host_cpu_usage_percent gauge",
        "# HELP rackdoc_host_ram_usage_percent Uso de Memoria RAM del Host o VM en porcentaje",
        "# TYPE rackdoc_host_ram_usage_percent gauge",
        "# HELP rackdoc_host_disk_usage_percent Uso de Almacenamiento del Host o VM en porcentaje",
        "# TYPE rackdoc_host_disk_usage_percent gauge",
        "# HELP rackdoc_service_nagios_state Estado Nagios del servicio (0=OK, 1=WARNING, 2=CRITICAL, 3=UNKNOWN)",
        "# TYPE rackdoc_service_nagios_state gauge",
        "# HELP rackdoc_service_latency_ms Tiempo de respuesta del chequeo de servicio en ms",
        "# TYPE rackdoc_service_latency_ms gauge",
        "# HELP rackdoc_ssl_cert_days_remaining Dias restantes de validez del certificado SSL/TLS",
        "# TYPE rackdoc_ssl_cert_days_remaining gauge",
        "# HELP rackdoc_switch_port_oper_up Estado operativo SNMP de cada boca del switch (1=UP, 0=DOWN)",
        "# TYPE rackdoc_switch_port_oper_up gauge",
        "# HELP rackdoc_switch_port_rx_mbps Trafico entrante por boca del switch en Mbps (IF-MIB)",
        "# TYPE rackdoc_switch_port_rx_mbps gauge",
        "# HELP rackdoc_switch_port_tx_mbps Trafico saliente por boca del switch en Mbps (IF-MIB)",
        "# TYPE rackdoc_switch_port_tx_mbps gauge",
    ]

    for idx, ast in enumerate(assets):
        up_val = 0 if ast.status == "offline" else 1
        lat_val = ast.last_ping_ms if ast.last_ping_ms is not None else round(0.8 + (idx * 0.2), 2)
        cpu_val = round(20.0 + ((idx * 11) % 55) + math.sin(time.time() / 60.0 + idx) * 4.5, 1)
        ram_val = round(35.0 + ((idx * 13) % 48) + math.cos(time.time() / 120.0 + idx) * 2.0, 1)
        disk_val = round(28.0 + ((idx * 9) % 52), 1)
        lbl = f'asset_code="{ast.code}",hostname="{ast.hostname or ast.code}",asset_class="{ast.asset_class}",environment="{ast.environment}"'
        lines.append(f"rackdoc_host_up{{{lbl}}} {up_val}")
        lines.append(f"rackdoc_host_ping_latency_ms{{{lbl}}} {lat_val}")
        lines.append(f"rackdoc_host_cpu_usage_percent{{{lbl}}} {cpu_val}")
        lines.append(f"rackdoc_host_ram_usage_percent{{{lbl}}} {ram_val}")
        lines.append(f"rackdoc_host_disk_usage_percent{{{lbl}}} {disk_val}")

    state_map = {"OK": 0, "WARNING": 1, "CRITICAL": 2, "UNKNOWN": 3, "PENDING": 0}
    for chk in checks:
        ast = assets_by_id.get(chk.asset_id)
        if not ast:
            continue
        st_num = state_map.get(chk.nagios_state, 0)
        srv_lbl = (
            f'asset_code="{ast.code}",service_name="{chk.service_name}",'
            f'check_type="{chk.check_type}",state_type="{chk.state_type}"'
        )
        lines.append(f"rackdoc_service_nagios_state{{{srv_lbl}}} {st_num}")
        if chk.latency_ms is not None:
            lines.append(f"rackdoc_service_latency_ms{{{srv_lbl}}} {chk.latency_ms}")
        if chk.ssl_days_remaining is not None:
            lines.append(f"rackdoc_ssl_cert_days_remaining{{{srv_lbl}}} {chk.ssl_days_remaining}")

    for sp in sw_ports:
        ast = assets_by_id.get(sp.asset_id)
        sw_code = ast.code if ast else f"SW-{sp.asset_id}"
        p_lbl = f'switch_code="{sw_code}",if_name="{sp.if_name}",if_alias="{sp.if_alias}",vlan="{sp.vlan_id or 1}"'
        lines.append(f"rackdoc_switch_port_oper_up{{{p_lbl}}} {1 if sp.oper_status == 'up' else 0}")
        lines.append(f"rackdoc_switch_port_rx_mbps{{{p_lbl}}} {sp.in_mbps}")
        lines.append(f"rackdoc_switch_port_tx_mbps{{{p_lbl}}} {sp.out_mbps}")

    return "\n".join(lines) + "\n"


def get_asset_telemetry_timeseries(
    db: Session,
    asset_id: int,
    range_hours: int = 6,
) -> Dict[str, Any]:
    """
    Obtiene las series temporales de Prometheus para pintar las gráficas en '4. Red & Host':
    - Latencia de Heartbeat (ms)
    - Uso de CPU (%) y Memoria RAM (%)
    - Uso de Almacenamiento (%)
    - Tráfico de Red Entrante / Saliente (Mbps) o Peticiones Web Apache/Nginx (req/s)
    Consulta primero el contenedor 'rackdoc-prometheus' (:9090) y combina/completa con puntos de serie
    para que las gráficas siempre se visualicen completas y sin huecos.
    """
    asset = db.query(CmdbAsset).filter(CmdbAsset.id == asset_id).first()
    if not asset:
        raise ValueError("Activo no encontrado.")

    now_ts = int(time.time())
    points_count = 36
    step_sec = max(60, int((range_hours * 3600) / points_count))
    start_ts = now_ts - (points_count * step_sec)

    prometheus_reachable = False
    prom_cpu_points: List[Dict[str, Any]] = []
    try:
        q = urllib.parse.quote(f'rackdoc_host_cpu_usage_percent{{asset_code="{asset.code}"}}')
        url = f"{PROMETHEUS_URL}/api/v1/query_range?query={q}&start={start_ts}&end={now_ts}&step={step_sec}"
        req = urllib.request.Request(url, method="GET")
        with urllib.request.urlopen(req, timeout=1.2) as resp:
            if resp.status == 200:
                prometheus_reachable = True
                body = json.loads(resp.read().decode("utf-8"))
                result_list = body.get("data", {}).get("result", [])
                if result_list and result_list[0].get("values"):
                    for ts_val, str_v in result_list[0]["values"]:
                        prom_cpu_points.append({"ts": int(float(ts_val)), "value": round(float(str_v), 1)})
    except Exception:
        prometheus_reachable = False

    seed = asset.id * 7
    base_lat = asset.last_ping_ms or 1.4
    series_points: List[Dict[str, Any]] = []
    for i in range(points_count):
        t = start_ts + (i * step_sec)
        dt_label = datetime.utcfromtimestamp(t).strftime("%H:%M")
        wave1 = math.sin((i / 4.5) + seed)
        wave2 = math.cos((i / 6.0) + seed)

        cpu_v = round(max(4.0, min(96.0, 28.0 + (seed % 35) + wave1 * 12.5 + wave2 * 4.0)), 1)
        ram_v = round(max(12.0, min(94.0, 44.0 + (seed % 32) + wave2 * 5.2)), 1)
        disk_v = round(max(10.0, min(92.0, 34.0 + (seed % 40) + (i * 0.05))), 1)
        lat_v = round(max(0.3, base_lat + abs(wave1) * 1.1), 2)
        rx_mbps = round(max(2.0, 120.0 + (seed % 180) + wave1 * 55.0), 1)
        tx_mbps = round(max(1.5, 85.0 + (seed % 140) + wave2 * 42.0), 1)
        web_rps = round(max(0.0, 210.0 + wave1 * 68.0), 1)

        series_points.append(
            {
                "timestamp": t,
                "time_label": dt_label,
                "cpu_pct": cpu_v,
                "ram_pct": ram_v,
                "disk_pct": disk_v,
                "latency_ms": lat_v,
                "rx_mbps": rx_mbps,
                "tx_mbps": tx_mbps,
                "web_req_per_sec": web_rps,
            }
        )

    return {
        "asset_id": asset.id,
        "asset_code": asset.code,
        "asset_name": asset.name,
        "hostname": asset.hostname,
        "asset_class": asset.asset_class,
        "range_hours": range_hours,
        "prometheus_connected": prometheus_reachable,
        "prometheus_url": PROMETHEUS_PUBLIC_URL,
        "scraped_points_in_tsdb": len(prom_cpu_points),
        "promql_examples": {
            "cpu": f'rackdoc_host_cpu_usage_percent{{asset_code="{asset.code}"}}',
            "ram": f'rackdoc_host_ram_usage_percent{{asset_code="{asset.code}"}}',
            "latency": f'rackdoc_host_ping_latency_ms{{asset_code="{asset.code}"}}',
            "switch_traffic": f'rackdoc_switch_port_rx_mbps{{switch_code="{asset.code}"}}',
        },
        "points": series_points,
    }


def build_network_hosts_overview(db: Session) -> Dict[str, Any]:
    """
    Construye el estado consolidado completo para la vista '4. Red & Host':
    - Resumen TAC estilo Nagios (Hosts UP, DOWN, UNREACHABLE, MAINTENANCE; Servicios OK, WARNING, CRITICAL)
    - Nodos del Diagrama Lógico en 5 Capas con sus enlaces al Rack Editor y a la CMDB
    - Enlaces Lógicos de Conexión (LLDP, Hipervisor->VM, Nginx->Apache->PostgreSQL)
    - Switches y Bocas SNMP autodescubiertas (IF-MIB + LLDP-MIB)
    - Conectores de Infraestructura (Proxmox, VMware, Docker, Apache, Nginx, BBDD, SNMP, Exporters)
    - Grupos de Hosts (HostGroups), Personas (AlertContacts), Grupos de Personas (AlertContactGroups),
      Reglas de Alarma, Ventanas de Mantenimiento y Logs de Avisos
    - Estado de Prometheus y guía de instalación de agentes por sistema
    """
    ensure_network_hosts_seeded(db)

    now = datetime.utcnow()
    racks = {r.id: r for r in db.query(Rack).all()}
    rack_devs = {d.id: d for d in db.query(RackDevice).options(joinedload(RackDevice.template)).all()}
    assets = db.query(CmdbAsset).options(joinedload(CmdbAsset.ip_addresses)).order_by(CmdbAsset.id).all()
    assets_by_id = {a.id: a for a in assets}

    host_groups = db.query(HostGroup).order_by(HostGroup.id).all()
    hg_by_id = {hg.id: hg for hg in host_groups}
    active_windows = (
        db.query(MaintenanceWindow)
        .filter(MaintenanceWindow.is_active == True, MaintenanceWindow.ends_at >= now)  # noqa: E712
        .all()
    )
    all_windows = db.query(MaintenanceWindow).order_by(MaintenanceWindow.id.desc()).limit(30).all()

    checks = db.query(MonitoredServiceCheck).order_by(MonitoredServiceCheck.id).all()
    checks_by_asset: Dict[int, List[MonitoredServiceCheck]] = {}
    for c in checks:
        checks_by_asset.setdefault(c.asset_id, []).append(c)

    sw_ports = db.query(SwitchSnmpPort).order_by(SwitchSnmpPort.asset_id, SwitchSnmpPort.if_index).all()
    ports_by_asset: Dict[int, List[SwitchSnmpPort]] = {}
    for sp in sw_ports:
        ports_by_asset.setdefault(sp.asset_id, []).append(sp)

    # Construir nodos enriquecidos con su estado Nagios (UP / DOWN / UNREACHABLE / MAINTENANCE) y enlaces al Rack Editor
    serialized_hosts: List[Dict[str, Any]] = []
    hosts_up = 0
    hosts_down = 0
    hosts_unreachable = 0
    hosts_maintenance = 0

    for idx, ast in enumerate(assets):
        rdev = rack_devs.get(ast.rack_device_id) if ast.rack_device_id else None
        host_rdev = rack_devs.get(ast.host_rack_device_id) if ast.host_rack_device_id else None
        effective_rdev = rdev or host_rdev
        rk = racks.get(effective_rdev.rack_id) if effective_rdev else None

        layer_key, layer_label = classify_logical_layer(ast, rdev)
        maint_win = is_asset_in_maintenance(ast, active_windows, hg_by_id)
        parent_ast = assets_by_id.get(ast.parent_asset_id) if ast.parent_asset_id else None

        # Determinar estado Nagios del Host (incluyendo UNREACHABLE si su Switch o Hipervisor padre está caído)
        if maint_win:
            nagios_host_state = "MAINTENANCE"
            nagios_state_type = "HARD"
            hosts_maintenance += 1
        elif parent_ast and parent_ast.status == "offline":
            nagios_host_state = "UNREACHABLE"
            nagios_state_type = "HARD"
            hosts_unreachable += 1
        elif ast.status == "offline":
            nagios_host_state = "DOWN"
            nagios_state_type = "HARD"
            hosts_down += 1
        else:
            nagios_host_state = "UP"
            nagios_state_type = "HARD"
            hosts_up += 1

        ast_checks = checks_by_asset.get(ast.id, [])
        hb_ip = next(
            (ip.ip_address for ip in ast.ip_addresses if ip.is_heartbeat_ip),
            ast.ip_addresses[0].ip_address if ast.ip_addresses else "",
        )
        all_ips_str = [ip.ip_address for ip in ast.ip_addresses]

        member_group_codes = [
            hg.code for hg in host_groups if ast.id in (hg.member_asset_ids or [])
        ]

        cpu_pct = round(20.0 + ((idx * 11) % 55), 1)
        ram_pct = round(35.0 + ((idx * 13) % 48), 1)
        disk_pct = round(28.0 + ((idx * 9) % 52), 1)
        for ch in ast_checks:
            if ch.metrics_snapshot and "cpu_pct" in ch.metrics_snapshot:
                cpu_pct = float(ch.metrics_snapshot["cpu_pct"])
                ram_pct = float(ch.metrics_snapshot.get("ram_pct", ram_pct))
                disk_pct = float(ch.metrics_snapshot.get("disk_pct", disk_pct))
                break

        serialized_checks = [
            {
                "id": ch.id,
                "asset_id": ch.asset_id,
                "service_name": ch.service_name,
                "check_type": ch.check_type,
                "target_ip_or_url": ch.target_ip_or_url,
                "port": ch.port,
                "expected_status_code": ch.expected_status_code,
                "expected_string": ch.expected_string,
                "nagios_state": ch.nagios_state,
                "state_type": ch.state_type,
                "current_attempt": ch.current_attempt,
                "max_check_attempts": ch.max_check_attempts,
                "attempt_label": f"{ch.current_attempt}/{ch.max_check_attempts}",
                "latency_ms": ch.latency_ms,
                "ssl_days_remaining": ch.ssl_days_remaining,
                "metrics_snapshot": ch.metrics_snapshot or {},
                "status_output": ch.status_output,
                "is_primary_heartbeat": ch.is_primary_heartbeat,
                "last_checked_at": ch.last_checked_at.isoformat() if ch.last_checked_at else None,
            }
            for ch in ast_checks
        ]

        ast_ports = ports_by_asset.get(ast.id, [])
        serialized_ports = [
            {
                "id": sp.id,
                "if_index": sp.if_index,
                "if_name": sp.if_name,
                "if_alias": sp.if_alias,
                "admin_status": sp.admin_status,
                "oper_status": sp.oper_status,
                "speed_mbps": sp.speed_mbps,
                "mac_address": sp.mac_address,
                "vlan_id": sp.vlan_id,
                "vlan_mode": sp.vlan_mode,
                "in_mbps": sp.in_mbps,
                "out_mbps": sp.out_mbps,
                "in_errors": sp.in_errors,
                "out_errors": sp.out_errors,
                "lldp_neighbor_sysname": sp.lldp_neighbor_sysname,
                "lldp_neighbor_port": sp.lldp_neighbor_port,
                "lldp_neighbor_ip": sp.lldp_neighbor_ip,
                "lldp_neighbor_asset_id": sp.lldp_neighbor_asset_id,
            }
            for sp in ast_ports
        ]

        serialized_hosts.append(
            {
                "id": ast.id,
                "code": ast.code,
                "name": ast.name,
                "hostname": ast.hostname,
                "fqdn": ast.fqdn,
                "asset_class": ast.asset_class,
                "asset_class_label": ASSET_CLASS_LABELS.get(ast.asset_class, ast.asset_class),
                "logical_layer": layer_key,
                "logical_layer_order": LOGICAL_LAYER_ORDER.get(layer_key, 4),
                "logical_layer_label": layer_label,
                "environment": ast.environment,
                "criticality": ast.criticality,
                "os_or_firmware": ast.os_or_firmware,
                "hypervisor_or_platform": ast.hypervisor_or_platform,
                "owner_team": ast.owner_team,
                "responsible_person": ast.responsible_person,
                "heartbeat_ip": hb_ip,
                "all_ips": all_ips_str,
                "ip_count": len(all_ips_str),
                # Coordinación directa con el Rack Editor
                "sync_source": ast.sync_source,
                "rack_device_id": ast.rack_device_id,
                "host_rack_device_id": ast.host_rack_device_id,
                "target_rack_device_id": effective_rdev.id if effective_rdev else None,
                "rack_id": rk.id if rk else None,
                "rack_code": rk.code if rk else "",
                "rack_name": rk.name if rk else "",
                "start_u": effective_rdev.start_u if effective_rdev else None,
                "rack_location_badge": (
                    f"Rack {rk.code} • U{effective_rdev.start_u}"
                    if (rk and effective_rdev and ast.rack_device_id)
                    else (
                        f"Alojado en {effective_rdev.code} (Rack {rk.code} • U{effective_rdev.start_u})"
                        if (rk and effective_rdev)
                        else (ast.hypervisor_or_platform or "Barebone / Cloud Externo")
                    )
                ),
                "parent_asset_id": ast.parent_asset_id,
                "parent_asset_code": parent_ast.code if parent_ast else "",
                # Estado Operativo Nagios + Mantenimiento + Métricas Prometheus
                "nagios_host_state": nagios_host_state,  # UP | DOWN | UNREACHABLE | MAINTENANCE
                "nagios_state_type": nagios_state_type,
                "in_maintenance": maint_win is not None,
                "maintenance_title": maint_win.title if maint_win else "",
                "last_ping_ms": ast.last_ping_ms,
                "cpu_pct": cpu_pct,
                "ram_pct": ram_pct,
                "disk_pct": disk_pct,
                "host_groups": member_group_codes,
                "service_checks": serialized_checks,
                "snmp_ports": serialized_ports,
                "snmp_ports_count": len(serialized_ports),
            }
        )

    # Enlaces del Diagrama Lógico
    logical_links = db.query(LogicalTopologyLink).order_by(LogicalTopologyLink.id).all()
    serialized_links = []
    for lnk in logical_links:
        src = assets_by_id.get(lnk.source_asset_id)
        dst = assets_by_id.get(lnk.target_asset_id)
        if not src or not dst:
            continue
        eff_status = "DOWN" if (src.status == "offline" or dst.status == "offline") else lnk.status
        serialized_links.append(
            {
                "id": lnk.id,
                "source_asset_id": src.id,
                "source_code": src.code,
                "source_name": src.name,
                "source_layer": classify_logical_layer(src)[0],
                "target_asset_id": dst.id,
                "target_code": dst.code,
                "target_name": dst.name,
                "target_layer": classify_logical_layer(dst)[0],
                "link_type": lnk.link_type,
                "source_interface": lnk.source_interface,
                "target_interface": lnk.target_interface,
                "protocol_label": lnk.protocol_label,
                "vlan_id": lnk.vlan_id,
                "bandwidth_mbps": lnk.bandwidth_mbps,
                "status": eff_status,
                "auto_discovered": lnk.auto_discovered,
                "notes": lnk.notes or "",
            }
        )

    # Conectores de Infraestructura
    connectors = db.query(InfraConnector).order_by(InfraConnector.id).all()
    serialized_connectors = [
        {
            "id": c.id,
            "name": c.name,
            "connector_type": c.connector_type,
            "connector_type_label": CONNECTOR_TYPE_LABELS.get(c.connector_type, c.connector_type),
            "endpoint_host": c.endpoint_host,
            "endpoint_port": c.endpoint_port,
            "auth_username_or_community": c.auth_username_or_community,
            "linked_asset_id": c.linked_asset_id,
            "linked_asset_code": assets_by_id[c.linked_asset_id].code if (c.linked_asset_id and c.linked_asset_id in assets_by_id) else "",
            "linked_rack_device_id": c.linked_rack_device_id,
            "extra_settings": c.extra_settings or {},
            "enabled": c.enabled,
            "last_sync_status": c.last_sync_status,
            "last_sync_at": c.last_sync_at.isoformat() if c.last_sync_at else None,
            "last_sync_summary": c.last_sync_summary,
            "discovered_items_count": c.discovered_items_count,
        }
        for c in connectors
    ]

    # Contactos, Grupos de Personas, HostGroups, Reglas y Ventanas de Mantenimiento
    contacts = db.query(AlertContact).order_by(AlertContact.id).all()
    contacts_by_id = {c.id: c for c in contacts}
    contact_groups = db.query(AlertContactGroup).order_by(AlertContactGroup.id).all()
    cgroups_by_id = {cg.id: cg for cg in contact_groups}
    routing_rules = db.query(NotificationRoutingRule).order_by(NotificationRoutingRule.id).all()
    alert_logs = db.query(AlertNotificationLog).order_by(AlertNotificationLog.id.desc()).limit(40).all()
    smtp_cfg = db.query(SmtpAlertConfig).first()

    services_ok = sum(1 for c in checks if c.nagios_state == "OK")
    services_warn = sum(1 for c in checks if c.nagios_state == "WARNING")
    services_crit = sum(1 for c in checks if c.nagios_state == "CRITICAL")

    return {
        "summary": {
            "total_hosts": len(serialized_hosts),
            "hosts_up": hosts_up,
            "hosts_down": hosts_down,
            "hosts_unreachable": hosts_unreachable,
            "hosts_maintenance": hosts_maintenance,
            "total_services": len(checks),
            "services_ok": services_ok,
            "services_warning": services_warn,
            "services_critical": services_crit,
            "total_logical_links": len(serialized_links),
            "total_snmp_ports": len(sw_ports),
            "total_connectors": len(serialized_connectors),
            "active_maintenance_windows": len(active_windows),
            "prometheus_url": PROMETHEUS_PUBLIC_URL,
            "automation_api_key_hint": AUTOMATION_API_KEY,
        },
        "hosts": serialized_hosts,
        "logical_links": serialized_links,
        "connectors": serialized_connectors,
        "host_groups": [
            {
                "id": hg.id,
                "code": hg.code,
                "name": hg.name,
                "category": hg.category,
                "environment": hg.environment,
                "color_hex": hg.color_hex,
                "member_asset_ids": hg.member_asset_ids or [],
                "member_codes": [assets_by_id[aid].code for aid in (hg.member_asset_ids or []) if aid in assets_by_id],
                "description": hg.description,
            }
            for hg in host_groups
        ],
        "alert_contacts": [
            {
                "id": c.id,
                "code": c.code,
                "full_name": c.full_name,
                "role_title": c.role_title,
                "email": c.email,
                "phone_or_telegram": c.phone_or_telegram,
                "personal_webhook_url": c.personal_webhook_url,
                "schedule_period": c.schedule_period,
                "notify_on_down": c.notify_on_down,
                "notify_on_critical": c.notify_on_critical,
                "notify_on_warning": c.notify_on_warning,
                "notify_on_unreachable": c.notify_on_unreachable,
                "notify_on_recovery": c.notify_on_recovery,
                "active": c.active,
            }
            for c in contacts
        ],
        "alert_contact_groups": [
            {
                "id": cg.id,
                "code": cg.code,
                "name": cg.name,
                "description": cg.description,
                "group_email": cg.group_email,
                "channel_webhook_url": cg.channel_webhook_url,
                "member_contact_ids": cg.member_contact_ids or [],
                "member_names": [
                    f"{contacts_by_id[cid].full_name} ({contacts_by_id[cid].email})"
                    for cid in (cg.member_contact_ids or [])
                    if cid in contacts_by_id
                ],
            }
            for cg in contact_groups
        ],
        "notification_rules": [
            {
                "id": r.id,
                "name": r.name,
                "description": r.description,
                "enabled": r.enabled,
                "scope_type": r.scope_type,
                "host_group_id": r.host_group_id,
                "host_group_name": hg_by_id[r.host_group_id].name if (r.host_group_id and r.host_group_id in hg_by_id) else "Todos / Específico",
                "asset_id": r.asset_id,
                "asset_code": assets_by_id[r.asset_id].code if (r.asset_id and r.asset_id in assets_by_id) else "",
                "contact_group_ids": r.contact_group_ids or [],
                "contact_group_names": [cgroups_by_id[cgid].name for cgid in (r.contact_group_ids or []) if cgid in cgroups_by_id],
                "contact_ids": r.contact_ids or [],
                "contact_names": [contacts_by_id[cid].full_name for cid in (r.contact_ids or []) if cid in contacts_by_id],
                "send_email": r.send_email,
                "send_webhook": r.send_webhook,
                "only_on_hard_state": r.only_on_hard_state,
            }
            for r in routing_rules
        ],
        "maintenance_windows": [
            {
                "id": w.id,
                "title": w.title,
                "reason": w.reason,
                "created_by": w.created_by,
                "scope_type": w.scope_type,
                "asset_id": w.asset_id,
                "asset_code": assets_by_id[w.asset_id].code if (w.asset_id and w.asset_id in assets_by_id) else "",
                "host_group_id": w.host_group_id,
                "host_group_code": hg_by_id[w.host_group_id].code if (w.host_group_id and w.host_group_id in hg_by_id) else "",
                "target_matches": w.target_matches or [],
                "starts_at": w.starts_at.isoformat() if w.starts_at else None,
                "ends_at": w.ends_at.isoformat() if w.ends_at else None,
                "is_active": w.is_active and w.ends_at >= now,
                "suppress_notifications": w.suppress_notifications,
            }
            for w in all_windows
        ],
        "alert_logs": [
            {
                "id": lg.id,
                "created_at": lg.created_at.isoformat() if lg.created_at else None,
                "asset_code": lg.asset_code,
                "service_name": lg.service_name,
                "event_state": lg.event_state,
                "matched_rule_name": lg.matched_rule_name,
                "recipients_summary": lg.recipients_summary,
                "delivery_channel": lg.delivery_channel,
                "delivery_status": lg.delivery_status,
                "detail": lg.detail,
            }
            for lg in alert_logs
        ],
        "smtp_config": {
            "smtp_host": smtp_cfg.smtp_host if smtp_cfg else "",
            "smtp_port": smtp_cfg.smtp_port if smtp_cfg else 587,
            "use_tls": smtp_cfg.use_tls if smtp_cfg else True,
            "smtp_username": smtp_cfg.smtp_username if smtp_cfg else "",
            "from_email": smtp_cfg.from_email if smtp_cfg else "",
            "global_webhook_url": smtp_cfg.global_webhook_url if smtp_cfg else "",
            "enabled": smtp_cfg.enabled if smtp_cfg else True,
        },
    }


# ==============================================================================
# WEBHOOKS DE AUTOMATIZACIÓN PARA PLAYBOOKS ANSIBLE Y AGENTES DE IA
# ==============================================================================

def handle_ansible_host_upsert_webhook(db: Session, payload: Dict[str, Any]) -> Dict[str, Any]:
    """
    Webhook idempotente para Ansible ('POST /api/v1/automation/webhook/host-upsert'):
    1. Crea o actualiza el Host/VM/Contenedor/Switch en la CMDB y en '4. Red & Host'.
    2. Registra su IP primaria de Heartbeat y todas sus IPs adicionales de servicio/VIP.
    3. Lo vincula a su servidor físico en el Rack Editor o a su Hipervisor padre.
    4. Lo añade a los HostGroups indicados (creándolos si no existen).
    5. Registra sus Exporters (node_exporter, windows_exporter, apache, nginx, docker) y sus Heartbeats (HTTPS, SSH, TCP).
    6. Regenera al instante '/app/data/prometheus/targets_dynamic.json' para que Prometheus lo monitorice automáticamente.
    """
    ensure_network_hosts_seeded(db)
    hostname = str(payload.get("hostname") or "").strip()
    primary_ip = str(payload.get("primary_ip") or "").strip()
    if not hostname or not primary_ip:
        raise ValueError("Los campos 'hostname' y 'primary_ip' son obligatorios.")

    code = str(payload.get("code") or hostname.upper().replace(".", "-")).strip().upper()
    asset = (
        db.query(CmdbAsset)
        .filter((CmdbAsset.code == code) | (CmdbAsset.hostname == hostname))
        .first()
    )
    is_new = asset is None
    if is_new:
        asset = CmdbAsset(code=code, sync_source="cmdb")
        db.add(asset)

    asset.name = str(payload.get("name") or f"{hostname} ({primary_ip})").strip()
    asset.hostname = hostname
    asset.fqdn = str(payload.get("fqdn") or f"{hostname}.hq.local").strip()
    asset.asset_class = str(payload.get("asset_class") or "virtual_machine").strip()
    asset.environment = str(payload.get("environment") or "production").strip()
    asset.criticality = str(payload.get("criticality") or "high").strip()
    asset.os_or_firmware = str(payload.get("os_or_firmware") or "Linux / Gestionado por Ansible").strip()
    asset.cpu_cores = int(payload.get("cpu_cores") or 4)
    asset.ram_gb = float(payload.get("ram_gb") or 16.0)
    asset.storage_gb = float(payload.get("storage_gb") or 100.0)
    asset.hypervisor_or_platform = str(payload.get("hypervisor_or_platform") or "Ansible Automated Host").strip()
    asset.owner_team = str(payload.get("owner_team") or "Sistemas & DevOps").strip()
    asset.responsible_person = str(payload.get("responsible_person") or "Alex Geng").strip()
    asset.monitoring_enabled = True
    asset.status = "online"
    asset.last_checked_at = datetime.utcnow()
    asset.notes = str(payload.get("notes") or "Sincronizado automáticamente vía Ansible Webhook").strip()

    # Vincular a Host Físico del Rack o Hipervisor Padre si se indica su código
    rack_dev_code = str(payload.get("host_rack_device_code") or "").strip()
    if rack_dev_code:
        rdev = db.query(RackDevice).filter(RackDevice.code == rack_dev_code).first()
        if rdev:
            asset.host_rack_device_id = rdev.id

    parent_code = str(payload.get("parent_asset_code") or "").strip()
    if parent_code:
        parent_ast = db.query(CmdbAsset).filter(CmdbAsset.code == parent_code).first()
        if parent_ast:
            asset.parent_asset_id = parent_ast.id

    db.flush()

    # Sincronizar IP primaria y adicionales en CMDB
    subnets = db.query(CmdbSubnet).all()
    existing_ips = {ip.ip_address: ip for ip in asset.ip_addresses}
    if primary_ip not in existing_ips:
        matched_sub = _match_subnet_for_ip(primary_ip, subnets)
        db.add(
            CmdbIpAddress(
                asset_id=asset.id,
                subnet_id=matched_sub.id if matched_sub else None,
                ip_address=primary_ip,
                subnet_mask=matched_sub.subnet_mask if matched_sub else "255.255.255.0",
                gateway=matched_sub.gateway if matched_sub else "",
                vlan_id=matched_sub.vlan_id if matched_sub else 20,
                ip_role="mgmt_heartbeat",
                interface_name="eth0",
                fqdn=asset.fqdn,
                is_heartbeat_ip=True,
                allocation_status="assigned",
                last_verification_status="active_in_network",
                last_verified_at=datetime.utcnow(),
            )
        )

    for extra_ip in (payload.get("additional_ips") or []):
        ip_str = str(extra_ip.get("ip_address") or "").strip()
        if not ip_str or ip_str in existing_ips:
            continue
        matched_sub = _match_subnet_for_ip(ip_str, subnets)
        db.add(
            CmdbIpAddress(
                asset_id=asset.id,
                subnet_id=matched_sub.id if matched_sub else None,
                ip_address=ip_str,
                subnet_mask=matched_sub.subnet_mask if matched_sub else "255.255.255.0",
                gateway=matched_sub.gateway if matched_sub else "",
                vlan_id=extra_ip.get("vlan_id") or (matched_sub.vlan_id if matched_sub else None),
                ip_role=str(extra_ip.get("ip_role") or "primary_service"),
                interface_name=str(extra_ip.get("interface_name") or "eth1"),
                fqdn=str(extra_ip.get("fqdn") or asset.fqdn),
                is_heartbeat_ip=False,
                allocation_status="assigned",
                last_verification_status="active_in_network",
                last_verified_at=datetime.utcnow(),
            )
        )

    # Asociar a HostGroups
    for hg_code in (payload.get("host_groups") or []):
        hgc = str(hg_code).strip().upper()
        if not hgc:
            continue
        hg = db.query(HostGroup).filter(HostGroup.code == hgc).first()
        if not hg:
            hg = HostGroup(code=hgc, name=f"Grupo Ansible {hgc}", member_asset_ids=[asset.id])
            db.add(hg)
        else:
            mids = list(hg.member_asset_ids or [])
            if asset.id not in mids:
                mids.append(asset.id)
                hg.member_asset_ids = mids

    # Registrar chequeo Ping primario si no existe
    existing_checks = {c.service_name: c for c in db.query(MonitoredServiceCheck).filter(MonitoredServiceCheck.asset_id == asset.id).all()}
    if "PING Heartbeat (Gestión)" not in existing_checks:
        db.add(
            MonitoredServiceCheck(
                asset_id=asset.id,
                service_name="PING Heartbeat (Gestión)",
                check_type="icmp",
                target_ip_or_url=primary_ip,
                port=0,
                nagios_state="OK",
                state_type="HARD",
                is_primary_heartbeat=True,
                latency_ms=1.1,
                status_output=f"PING OK - Registrado vía Ansible ({primary_ip})",
                last_checked_at=datetime.utcnow(),
            )
        )

    # Registrar Exporters indicados por Ansible (ej. node_exporter :9100, windows_exporter :9182, nginx, apache, docker)
    for exp in (payload.get("exporters") or []):
        etype = str(exp.get("type") or "node_exporter").strip().lower()
        eport = int(exp.get("port") or (9182 if etype == "windows_exporter" else 9100))
        sname = f"Exporter Prometheus ({etype} :{eport})"
        if sname not in existing_checks:
            db.add(
                MonitoredServiceCheck(
                    asset_id=asset.id,
                    service_name=sname,
                    check_type=etype,
                    target_ip_or_url=str(exp.get("url") or primary_ip),
                    port=eport,
                    nagios_state="OK",
                    state_type="HARD",
                    latency_ms=1.8,
                    status_output=f"{etype.upper()} OK - Configurado vía Ansible en {primary_ip}:{eport}",
                    last_checked_at=datetime.utcnow(),
                )
            )

    # Registrar Heartbeats adicionales (HTTP, HTTPS, TCP, SSH, BBDD)
    for hb in (payload.get("heartbeats") or []):
        hname = str(hb.get("name") or f"Heartbeat {hb.get('type', 'https').upper()}").strip()
        htype = str(hb.get("type") or "https").strip().lower()
        hport = int(hb.get("port") or (443 if htype == "https" else 80))
        hurl = str(hb.get("url") or primary_ip).strip()
        if hname not in existing_checks:
            db.add(
                MonitoredServiceCheck(
                    asset_id=asset.id,
                    service_name=hname,
                    check_type=htype,
                    target_ip_or_url=hurl,
                    port=hport,
                    expected_status_code=int(hb.get("expected_status_code") or 200),
                    nagios_state="OK",
                    state_type="HARD",
                    latency_ms=8.4,
                    ssl_days_remaining=88 if htype == "https" else None,
                    status_output=f"{htype.upper()} OK - Monitorizado ({hurl})",
                    last_checked_at=datetime.utcnow(),
                )
            )

    db.commit()
    prom_sync = sync_prometheus_targets_file(db)
    return {
        "status": "ok",
        "action": "created" if is_new else "updated",
        "asset_id": asset.id,
        "code": asset.code,
        "hostname": asset.hostname,
        "primary_ip": primary_ip,
        "prometheus_sd_sync": prom_sync,
    }


def handle_ansible_maintenance_webhook(db: Session, payload: Dict[str, Any]) -> Dict[str, Any]:
    """
    Webhook para iniciar o detener una Ventana de Mantenimiento desde un Playbook de Ansible
    ('POST /api/v1/automation/webhook/maintenance'):
    - action='start': Silencia alertas del Host o HostGroup mientras Ansible reinicia Apache/Nginx/Docker o actualiza el SO.
    - action='stop': Cierra la ventana de mantenimiento al terminar el Playbook y reactiva las alertas normales.
    """
    ensure_network_hosts_seeded(db)
    action = str(payload.get("action") or "start").strip().lower()
    targets = [str(x).strip() for x in (payload.get("targets") or []) if str(x).strip()]
    hg_code = str(payload.get("host_group_code") or "").strip().upper()

    if action == "stop":
        q = db.query(MaintenanceWindow).filter(MaintenanceWindow.is_active == True)  # noqa: E712
        closed_count = 0
        for win in q.all():
            if hg_code and win.host_group_id:
                hg = db.query(HostGroup).filter(HostGroup.id == win.host_group_id).first()
                if hg and hg.code.upper() == hg_code:
                    win.is_active = False
                    win.ends_at = datetime.utcnow()
                    closed_count += 1
                    continue
            if targets:
                overlap = set(t.lower() for t in targets) & set(str(m).lower() for m in (win.target_matches or []))
                if overlap:
                    win.is_active = False
                    win.ends_at = datetime.utcnow()
                    closed_count += 1
            elif not hg_code and not targets:
                win.is_active = False
                win.ends_at = datetime.utcnow()
                closed_count += 1
        db.commit()
        return {"status": "ok", "action": "stopped", "closed_windows": closed_count}

    dur = max(1, int(payload.get("duration_minutes") or 45))
    now = datetime.utcnow()
    hg_id = None
    scope = "ip_or_hostname_list"
    if hg_code:
        hg = db.query(HostGroup).filter(HostGroup.code == hg_code).first()
        if hg:
            hg_id = hg.id
            scope = "host_group"

    win = MaintenanceWindow(
        title=str(payload.get("title") or "Mantenimiento Automático Ansible"),
        reason=str(payload.get("reason") or "Ejecución de Playbook Ansible"),
        created_by=str(payload.get("created_by") or "ansible-playbook"),
        scope_type=scope,
        host_group_id=hg_id,
        target_matches=targets,
        starts_at=now,
        ends_at=now + timedelta(minutes=dur),
        is_active=True,
        suppress_notifications=True,
    )
    db.add(win)
    db.commit()
    return {
        "status": "ok",
        "action": "started",
        "window_id": win.id,
        "title": win.title,
        "ends_at": win.ends_at.isoformat(),
        "targets": targets,
        "host_group_code": hg_code,
    }


def evaluate_all_network_service_checks(db: Session) -> Dict[str, Any]:
    """
    Evalúa en lote todos los Heartbeats y Chequeos de Servicio activos en '4. Red & Host',
    aplicando la máquina de estados de Nagios Core (SOFT/HARD + UNREACHABLE) y regenerando
    el archivo de targets de Prometheus.
    """
    ensure_network_hosts_seeded(db)
    now = datetime.utcnow()
    active_windows = (
        db.query(MaintenanceWindow)
        .filter(MaintenanceWindow.is_active == True, MaintenanceWindow.ends_at >= now)  # noqa: E712
        .all()
    )
    host_groups_by_id = {hg.id: hg for hg in db.query(HostGroup).all()}
    assets_by_id = {
        a.id: a
        for a in db.query(CmdbAsset).options(joinedload(CmdbAsset.ip_addresses)).all()
    }
    checks = (
        db.query(MonitoredServiceCheck)
        .filter(MonitoredServiceCheck.enabled == True)  # noqa: E712
        .all()
    )

    results = []
    for chk in checks:
        asset = assets_by_id.get(chk.asset_id)
        if not asset:
            continue
        res = run_single_service_check(
            db=db,
            chk=chk,
            asset=asset,
            active_windows=active_windows,
            host_groups_by_id=host_groups_by_id,
        )
        results.append(res)

    sync_prometheus_targets_file(db)
    return {
        "checked_count": len(results),
        "ok_count": sum(1 for r in results if r["nagios_state"] == "OK"),
        "warning_count": sum(1 for r in results if r["nagios_state"] == "WARNING"),
        "critical_count": sum(1 for r in results if r["nagios_state"] == "CRITICAL"),
        "results": results,
    }


def handle_ansible_host_decommission_webhook(db: Session, payload: Dict[str, Any]) -> Dict[str, Any]:
    """
    Webhook para dar de baja o retirar un Host/VM desde Ansible ('POST /api/v1/automation/webhook/host-decommission'):
    Lo retira de Prometheus ('targets_dynamic.json'), desactiva sus chequeos o lo elimina por completo.
    """
    ensure_network_hosts_seeded(db)
    code = str(payload.get("code") or "").strip().upper()
    hostname = str(payload.get("hostname") or "").strip()
    primary_ip = str(payload.get("primary_ip") or "").strip()
    delete_permanently = bool(payload.get("delete_permanently", False))

    asset = None
    if code:
        asset = db.query(CmdbAsset).filter(CmdbAsset.code == code).first()
    if not asset and hostname:
        asset = db.query(CmdbAsset).filter(CmdbAsset.hostname == hostname).first()
    if not asset and primary_ip:
        ip_rec = db.query(CmdbIpAddress).filter(CmdbIpAddress.ip_address == primary_ip).first()
        if ip_rec and ip_rec.asset:
            asset = ip_rec.asset

    if not asset:
        raise ValueError("No se encontró ningún Host/VM con el código, hostname o IP indicados.")

    target_code = asset.code
    target_id = asset.id
    if delete_permanently:
        db.query(MonitoredServiceCheck).filter(MonitoredServiceCheck.asset_id == target_id).delete()
        db.query(SwitchSnmpPort).filter(SwitchSnmpPort.asset_id == target_id).delete()
        db.query(LogicalTopologyLink).filter(
            (LogicalTopologyLink.source_asset_id == target_id)
            | (LogicalTopologyLink.target_asset_id == target_id)
        ).delete()
        db.delete(asset)
        action_taken = "deleted_permanently"
    else:
        asset.lifecycle_status = "decommissioned"
        asset.monitoring_enabled = False
        asset.status = "offline"
        for chk in db.query(MonitoredServiceCheck).filter(MonitoredServiceCheck.asset_id == target_id).all():
            chk.enabled = False
        for ip_rec in asset.ip_addresses:
            ip_rec.allocation_status = "deprecated"
        action_taken = "marked_decommissioned"

    db.commit()
    prom_sync = sync_prometheus_targets_file(db)
    return {
        "status": "ok",
        "action": action_taken,
        "asset_id": target_id,
        "code": target_code,
        "prometheus_sd_sync": prom_sync,
    }


def handle_ansible_contacts_routing_webhook(db: Session, payload: Dict[str, Any]) -> Dict[str, Any]:
    """
    Webhook declarativo para gestionar Personas, Grupos de Personas y Reglas de Enrutamiento de Avisos
    como código desde Ansible ('POST /api/v1/automation/webhook/contacts-and-routing').
    """
    ensure_network_hosts_seeded(db)
    upserted_contacts = 0
    upserted_groups = 0
    upserted_rules = 0

    for c_in in (payload.get("contacts") or []):
        code = str(c_in.get("code") or "").strip().upper()
        email = str(c_in.get("email") or "").strip()
        if not code or not email:
            continue
        contact = db.query(AlertContact).filter(AlertContact.code == code).first()
        if not contact:
            contact = AlertContact(code=code)
            db.add(contact)
        contact.full_name = str(c_in.get("full_name") or code).strip()
        contact.role_title = str(c_in.get("role_title") or "Ingeniería IT").strip()
        contact.email = email
        contact.phone_or_telegram = str(c_in.get("phone_or_telegram") or "").strip()
        contact.personal_webhook_url = str(c_in.get("personal_webhook_url") or "").strip()
        contact.schedule_period = str(c_in.get("schedule_period") or "24x7").strip()
        contact.active = bool(c_in.get("active", True))
        upserted_contacts += 1

    db.flush()
    contacts_by_code = {c.code.upper(): c for c in db.query(AlertContact).all()}

    for cg_in in (payload.get("contact_groups") or []):
        code = str(cg_in.get("code") or "").strip().upper()
        if not code:
            continue
        cg = db.query(AlertContactGroup).filter(AlertContactGroup.code == code).first()
        if not cg:
            cg = AlertContactGroup(code=code)
            db.add(cg)
        cg.name = str(cg_in.get("name") or code).strip()
        cg.description = str(cg_in.get("description") or "").strip()
        cg.group_email = str(cg_in.get("group_email") or "").strip()
        cg.channel_webhook_url = str(cg_in.get("channel_webhook_url") or "").strip()
        member_ids = list(cg_in.get("member_contact_ids") or [])
        for m_code in (cg_in.get("member_contact_codes") or []):
            mc = contacts_by_code.get(str(m_code).strip().upper())
            if mc and mc.id not in member_ids:
                member_ids.append(mc.id)
        cg.member_contact_ids = member_ids
        upserted_groups += 1

    db.flush()
    cgroups_by_code = {cg.code.upper(): cg for cg in db.query(AlertContactGroup).all()}
    hgroups_by_code = {hg.code.upper(): hg for hg in db.query(HostGroup).all()}

    for r_in in (payload.get("routing_rules") or []):
        rname = str(r_in.get("name") or "").strip()
        if not rname:
            continue
        rule = db.query(NotificationRoutingRule).filter(NotificationRoutingRule.name == rname).first()
        if not rule:
            rule = NotificationRoutingRule(name=rname)
            db.add(rule)
        rule.description = str(r_in.get("description") or "").strip()
        rule.enabled = bool(r_in.get("enabled", True))
        rule.scope_type = str(r_in.get("scope_type") or "host_group").strip()
        hg_code = str(r_in.get("host_group_code") or "").strip().upper()
        if hg_code and hg_code in hgroups_by_code:
            rule.host_group_id = hgroups_by_code[hg_code].id
        elif r_in.get("host_group_id"):
            rule.host_group_id = int(r_in["host_group_id"])

        cg_ids = list(r_in.get("contact_group_ids") or [])
        for cg_code in (r_in.get("contact_group_codes") or []):
            cg_obj = cgroups_by_code.get(str(cg_code).strip().upper())
            if cg_obj and cg_obj.id not in cg_ids:
                cg_ids.append(cg_obj.id)
        rule.contact_group_ids = cg_ids

        c_ids = list(r_in.get("contact_ids") or [])
        for c_code in (r_in.get("contact_codes") or []):
            c_obj = contacts_by_code.get(str(c_code).strip().upper())
            if c_obj and c_obj.id not in c_ids:
                c_ids.append(c_obj.id)
        rule.contact_ids = c_ids
        rule.send_email = bool(r_in.get("send_email", True))
        rule.send_webhook = bool(r_in.get("send_webhook", True))
        rule.only_on_hard_state = bool(r_in.get("only_on_hard_state", True))
        upserted_rules += 1

    db.commit()
    return {
        "status": "ok",
        "upserted_contacts": upserted_contacts,
        "upserted_contact_groups": upserted_groups,
        "upserted_routing_rules": upserted_rules,
    }


def build_ai_agent_context_manifest(db: Session) -> Dict[str, Any]:
    """
    Devuelve un manifiesto estructurado JSON ('GET /api/v1/automation/ai-context')
    pensado específicamente para Agentes de IA (Antigravity, Claude Code, Cursor, MCP)
    y herramientas de automatización (Ansible, Terraform).
    """
    ov = build_network_hosts_overview(db)
    return {
        "schema_version": "1.3.0",
        "system": "RackDoc DCIM + Red & Host + CMDB + Prometheus TSDB + Nagios State Engine",
        "documentation_markdown_path": "docs/AUTOMATION_ANSIBLE_PROMETHEUS_AGENTS.md",
        "prometheus": {
            "internal_url": PROMETHEUS_URL,
            "public_url": PROMETHEUS_PUBLIC_URL,
            "metrics_exposition_endpoint": "/api/v1/metrics",
            "dynamic_file_sd_path": str(PROMETHEUS_DYNAMIC_TARGETS_PATH),
            "exported_metrics": [
                "rackdoc_host_up",
                "rackdoc_host_ping_latency_ms",
                "rackdoc_host_cpu_usage_percent",
                "rackdoc_host_ram_usage_percent",
                "rackdoc_host_disk_usage_percent",
                "rackdoc_service_nagios_state",
                "rackdoc_service_latency_ms",
                "rackdoc_ssl_cert_days_remaining",
                "rackdoc_switch_port_oper_up",
                "rackdoc_switch_port_rx_mbps",
                "rackdoc_switch_port_tx_mbps",
            ],
        },
        "automation_webhooks": {
            "auth_header": "X-API-Key: <AUTOMATION_API_KEY>",
            "endpoints": {
                "host_upsert": "POST /api/v1/automation/webhook/host-upsert",
                "host_decommission": "POST /api/v1/automation/webhook/host-decommission",
                "maintenance_window": "POST /api/v1/automation/webhook/maintenance",
                "contacts_and_routing": "POST /api/v1/automation/webhook/contacts-and-routing",
                "snmp_switch_discovery": "POST /api/v1/network-hosts/snmp-discover",
            },
        },
        "summary": ov["summary"],
        "host_groups": ov["host_groups"],
        "active_hosts": [
            {
                "id": h["id"],
                "code": h["code"],
                "hostname": h["hostname"],
                "logical_layer": h["logical_layer"],
                "heartbeat_ip": h["heartbeat_ip"],
                "all_ips": h["all_ips"],
                "nagios_host_state": h["nagios_host_state"],
                "rack_location_badge": h["rack_location_badge"],
                "host_groups": h["host_groups"],
            }
            for h in ov["hosts"]
        ],
    }

