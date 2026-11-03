from __future__ import annotations
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import ipaddress
import platform
import re
import socket
import subprocess
import time
from typing import Any, Dict, List, Optional, Tuple
from sqlalchemy.orm import Session, joinedload

from ..models import (
    CmdbAsset,
    CmdbIpAddress,
    CmdbSubnet,
    Floor,
    FloorDevice,
    Location,
    Rack,
    RackDevice,
    Room,
)
from .monitor import check_host_connectivity


ASSET_CLASS_LABELS: Dict[str, str] = {
    "virtual_machine": "Máquina Virtual (VM)",
    "container_lxc": "Contenedor / LXC / K8s",
    "physical_server": "Servidor / Host Físico",
    "cluster_vip": "Cluster HA / Balanceador VIP",
    "virtual_appliance": "Appliance Virtual (vApp)",
    "cloud_instance": "Instancia Cloud / VPS",
    "network_security": " Electrónica de Red / Firewall",
    "storage_san_nas": "Almacenamiento SAN / NAS",
    "floor_endpoint": "Dispositivo de Planta / IoT",
    "other_machine": "Otro Equipo / Máquina",
}

IP_ROLE_LABELS: Dict[str, str] = {
    "mgmt_heartbeat": "Gestión / Manager (Heartbeat)",
    "ilo_idrac": "OOB / iDRAC / iLO / IPMI",
    "primary_service": "Producción / Servicio Principal",
    "secondary_service": "Servicio Secundario / App",
    "vip_cluster": "VIP Flotante / Cluster HA",
    "storage": "Almacenamiento (iSCSI / NFS)",
    "backup": "Red de Backup / Contingencia",
    "vmotion_replication": "vMotion / Réplica / Cluster Sync",
    "public_wan": "IP Pública / WAN / DMZ",
    "reserved": "Reserva IPAM",
}


def _match_subnet_for_ip(ip_str: str, subnets: List[CmdbSubnet]) -> Optional[CmdbSubnet]:
    cleaned = (ip_str or "").strip().split("/")[0].strip()
    if not cleaned:
        return None
    try:
        ip_obj = ipaddress.ip_address(cleaned)
    except ValueError:
        return None
    for sub in subnets:
        try:
            net = ipaddress.ip_network(sub.cidr.strip(), strict=False)
            if ip_obj in net:
                return sub
        except ValueError:
            continue
    return None


def _infer_asset_class_from_rack_device(dev: RackDevice) -> str:
    cat = (dev.template.category if dev.template else "").lower().strip()
    if cat == "server":
        return "physical_server"
    if cat in ("switch", "san_switch", "router", "firewall", "gateway"):
        return "network_security"
    if cat in ("storage_san", "storage_nas"):
        return "storage_san_nas"
    return "other_machine"


def sync_physical_devices_to_cmdb(db: Session) -> None:
    """
    Sincroniza automáticamente los equipos activos de Rack (RackDevice) y Planta (FloorDevice)
    con la CMDB, asegurando que su IP principal figure como IP de Gestión/Heartbeat
    y conservando todas las IPs secundarias (servicio, VIP, backup, storage, iDRAC)
    que el usuario haya añadido al activo.
    """
    subnets = db.query(CmdbSubnet).all()

    # 1. Sincronizar RackDevices (excluyendo elementos pasivos sin IP)
    rack_devices = (
        db.query(RackDevice)
        .options(joinedload(RackDevice.template), joinedload(RackDevice.rack))
        .all()
    )
    passive_categories = {
        "patch_panel",
        "patchbox",
        "cable_manager",
        "rack_tray",
        "external_power_feed",
        "schuko",
    }

    existing_rack_assets = {
        a.rack_device_id: a
        for a in db.query(CmdbAsset)
        .filter(CmdbAsset.rack_device_id.isnot(None), CmdbAsset.sync_source == "rack_device")
        .all()
    }

    changed = False
    for rdev in rack_devices:
        if (rdev.mounted_face or "").lower() == "external":
            continue
        cat = (rdev.template.category if rdev.template else "").lower()
        has_ip_or_host = bool((rdev.ip_address or "").strip() or (rdev.hostname or "").strip())
        if cat in passive_categories and not has_ip_or_host:
            continue

        asset = existing_rack_assets.get(rdev.id)
        rack_code = rdev.rack.code if rdev.rack else "RACK"
        desired_code = f"{rack_code}-{rdev.code}".upper()

        if not asset:
            # Asegurar unicidad de code
            if db.query(CmdbAsset).filter(CmdbAsset.code == desired_code).first():
                desired_code = f"{desired_code}-R{rdev.id}"
            cf = dict(rdev.custom_fields or {})
            asset = CmdbAsset(
                code=desired_code,
                name=rdev.name,
                hostname=rdev.hostname or rdev.code.lower(),
                fqdn=rdev.fqdn or "",
                asset_class=_infer_asset_class_from_rack_device(rdev),
                environment="production",
                criticality="critical" if cat in ("server", "firewall", "router", "switch", "storage_san") else "high",
                lifecycle_status="active",
                os_or_firmware=str(cf.get("os") or cf.get("firmware") or (rdev.template.model_name if rdev.template else "")),
                cpu_cores=int(cf.get("cpu_cores") or (32 if cat == "server" else 0)),
                ram_gb=float(cf.get("ram_gb") or (128.0 if cat == "server" else 0.0)),
                storage_gb=float(cf.get("storage_gb") or (2000.0 if cat in ("server", "storage_san", "storage_nas") else 0.0)),
                hypervisor_or_platform="Baremetal / Chasis en Rack" if cat != "server" else str(cf.get("hypervisor") or "VMware ESXi / Proxmox Host"),
                serial_or_uuid=rdev.serial_number or "",
                owner_team="Sistemas & CPD" if cat == "server" else "NetOps & Comms",
                responsible_person=rdev.rack.responsible_person if rdev.rack else "Alex Geng",
                sync_source="rack_device",
                rack_device_id=rdev.id,
                monitoring_enabled=rdev.monitoring_enabled,
                monitor_method=rdev.monitor_method or "icmp",
                monitor_port=rdev.monitor_port or 22,
                status=rdev.status or "unmonitored",
                last_ping_ms=rdev.last_ping_ms,
                last_checked_at=rdev.last_checked_at,
                management_links=list(rdev.management_links or []),
                custom_fields=cf,
                notes=rdev.notes or "",
            )
            db.add(asset)
            db.flush()
            changed = True
        else:
            # Mantener estado de monitorización y datos base sincronizados desde el Rack
            asset.name = rdev.name
            if rdev.hostname:
                asset.hostname = rdev.hostname
            if rdev.fqdn:
                asset.fqdn = rdev.fqdn
            asset.monitoring_enabled = rdev.monitoring_enabled
            asset.monitor_method = rdev.monitor_method or asset.monitor_method
            asset.monitor_port = rdev.monitor_port or asset.monitor_port
            asset.status = rdev.status or asset.status
            asset.last_ping_ms = rdev.last_ping_ms
            asset.last_checked_at = rdev.last_checked_at
            if rdev.serial_number:
                asset.serial_or_uuid = rdev.serial_number

        # Sincronizar la IP primaria (Heartbeat / Gestión) del RackDevice
        primary_ip = (rdev.ip_address or "").strip()
        if primary_ip:
            hb_ip_obj = next(
                (ip for ip in asset.ip_addresses if ip.is_heartbeat_ip or ip.ip_role == "mgmt_heartbeat"),
                None,
            )
            matched_sub = _match_subnet_for_ip(primary_ip, subnets)
            if not hb_ip_obj:
                hb_ip_obj = CmdbIpAddress(
                    asset_id=asset.id,
                    subnet_id=matched_sub.id if matched_sub else None,
                    ip_address=primary_ip,
                    subnet_mask=rdev.subnet_mask or (matched_sub.subnet_mask if matched_sub else "255.255.255.0"),
                    gateway=rdev.gateway or (matched_sub.gateway if matched_sub else ""),
                    vlan_id=rdev.vlan_mgmt or (matched_sub.vlan_id if matched_sub else None),
                    ip_role="mgmt_heartbeat",
                    interface_name="mgmt0",
                    mac_address=rdev.mac_address or "",
                    fqdn=rdev.fqdn or "",
                    is_heartbeat_ip=True,
                    allocation_status="assigned",
                    last_verification_status="active_in_network" if rdev.status == "online" else "unverified",
                    notes="IP principal de Gestión / Heartbeat (Sincronizada con Rack Editor)",
                )
                db.add(hb_ip_obj)
                changed = True
            else:
                if hb_ip_obj.ip_address != primary_ip:
                    hb_ip_obj.ip_address = primary_ip
                    hb_ip_obj.subnet_id = matched_sub.id if matched_sub else hb_ip_obj.subnet_id
                    changed = True
                if rdev.mac_address and not hb_ip_obj.mac_address:
                    hb_ip_obj.mac_address = rdev.mac_address
                if rdev.vlan_mgmt and not hb_ip_obj.vlan_id:
                    hb_ip_obj.vlan_id = rdev.vlan_mgmt

    # 2. Sincronizar FloorDevices con IP
    floor_devices = db.query(FloorDevice).all()
    existing_floor_assets = {
        a.floor_device_id: a
        for a in db.query(CmdbAsset)
        .filter(CmdbAsset.floor_device_id.isnot(None), CmdbAsset.sync_source == "floor_device")
        .all()
    }
    for fdev in floor_devices:
        f_ip = (fdev.ip_address or "").strip()
        if not f_ip and fdev.device_type == "telecom_outlet":
            continue
        if not f_ip and not (fdev.fqdn or "").strip():
            continue

        asset = existing_floor_assets.get(fdev.id)
        desired_code = f"FLR-{fdev.code}".upper()
        if not asset:
            if db.query(CmdbAsset).filter(CmdbAsset.code == desired_code).first():
                desired_code = f"{desired_code}-F{fdev.id}"
            asset = CmdbAsset(
                code=desired_code,
                name=fdev.name,
                hostname=fdev.code.lower(),
                fqdn=fdev.fqdn or "",
                asset_class="floor_endpoint",
                environment="production",
                criticality="medium",
                lifecycle_status="active",
                os_or_firmware=f"Endpoint ({fdev.device_type})",
                hypervisor_or_platform=f"Planta / Sala {fdev.room_code}",
                owner_team=fdev.contact_department or "Infraestructura Planta",
                responsible_person=fdev.responsible_person or "Alex Geng",
                sync_source="floor_device",
                floor_device_id=fdev.id,
                host_rack_device_id=None,
                monitoring_enabled=fdev.monitoring_enabled,
                monitor_method=fdev.monitor_method or "icmp",
                monitor_port=fdev.monitor_port or 22,
                status=fdev.status or "unmonitored",
                last_ping_ms=fdev.last_ping_ms,
                last_checked_at=fdev.last_checked_at,
                custom_fields=dict(fdev.custom_fields or {}),
                notes=fdev.notes or "",
            )
            db.add(asset)
            db.flush()
            changed = True
        else:
            asset.name = fdev.name
            asset.monitoring_enabled = fdev.monitoring_enabled
            asset.status = fdev.status or asset.status
            asset.last_ping_ms = fdev.last_ping_ms
            asset.last_checked_at = fdev.last_checked_at

        if f_ip:
            hb_ip_obj = next(
                (ip for ip in asset.ip_addresses if ip.is_heartbeat_ip or ip.ip_role == "mgmt_heartbeat"),
                None,
            )
            matched_sub = _match_subnet_for_ip(f_ip, subnets)
            if not hb_ip_obj:
                hb_ip_obj = CmdbIpAddress(
                    asset_id=asset.id,
                    subnet_id=matched_sub.id if matched_sub else None,
                    ip_address=f_ip,
                    subnet_mask=matched_sub.subnet_mask if matched_sub else "255.255.255.0",
                    gateway=matched_sub.gateway if matched_sub else "",
                    vlan_id=fdev.vlan or (matched_sub.vlan_id if matched_sub else None),
                    ip_role="mgmt_heartbeat",
                    interface_name="eth0",
                    mac_address=fdev.mac_address or "",
                    fqdn=fdev.fqdn or "",
                    is_heartbeat_ip=True,
                    allocation_status="assigned",
                    notes="IP de Dispositivo en Planta (Sincronizada)",
                )
                db.add(hb_ip_obj)
                changed = True
            elif hb_ip_obj.ip_address != f_ip:
                hb_ip_obj.ip_address = f_ip
                hb_ip_obj.subnet_id = matched_sub.id if matched_sub else hb_ip_obj.subnet_id
                changed = True

    if changed:
        db.commit()


def ensure_cmdb_seed_data(db: Session) -> None:
    """
    Crea las Subredes/VLANs iniciales, sincroniza los equipos físicos y añade:
    1) IPs adicionales de producción/servicio/storage/iDRAC a los servidores físicos del Rack.
    2) Máquinas Virtuales (VMs), Contenedores, Clusters con VIPs, Appliances virtuales e instancias Cloud
       gestionables íntegramente desde la CMDB.
    """
    first_loc = db.query(Location).order_by(Location.id).first()
    loc_id = first_loc.id if first_loc else None

    default_subnets = [
        {
            "cidr": "10.20.1.0/24",
            "name": "VLAN 10 — Gestión CPD & Heartbeat (Manager)",
            "vlan_id": 10,
            "gateway": "10.20.1.1",
            "subnet_mask": "255.255.255.0",
            "dns_servers": "10.20.1.5, 10.20.1.6",
            "environment": "mgmt",
            "notes": "Red dedicada a la gestión e interrogación Heartbeat de switches, firewalls, hipervisores y VMs.",
        },
        {
            "cidr": "10.20.20.0/24",
            "name": "VLAN 20 — Producción Servicios & Máquinas Virtuales",
            "vlan_id": 20,
            "gateway": "10.20.20.1",
            "subnet_mask": "255.255.255.0",
            "dns_servers": "10.20.1.5, 10.20.1.6",
            "environment": "production",
            "notes": "Subred principal de servicio donde escuchan las aplicaciones corporativas, BBDD, ERP y VIPs internas.",
        },
        {
            "cidr": "10.20.30.0/24",
            "name": "VLAN 30 — Almacenamiento SAN/iSCSI, vMotion & Backup",
            "vlan_id": 30,
            "gateway": "10.20.30.1",
            "subnet_mask": "255.255.255.0",
            "dns_servers": "10.20.1.5",
            "environment": "storage",
            "notes": "Tráfico multipathing de cabinas de almacenamiento, replicación de hipervisores y agentes de backup.",
        },
        {
            "cidr": "10.20.99.0/24",
            "name": "VLAN 99 — Out-of-Band (iDRAC / iLO / IPMI)",
            "vlan_id": 99,
            "gateway": "10.20.99.1",
            "subnet_mask": "255.255.255.0",
            "dns_servers": "10.20.1.5",
            "environment": "mgmt",
            "notes": "Red física aislada para controladoras de placa base (Dell iDRAC, HPE iLO, Supermicro IPMI).",
        },
        {
            "cidr": "172.16.50.0/24",
            "name": "VLAN 50 — DMZ & Balanceadores Frontales (VIPs)",
            "vlan_id": 50,
            "gateway": "172.16.50.1",
            "subnet_mask": "255.255.255.0",
            "dns_servers": "1.1.1.1, 8.8.8.8",
            "environment": "dmz",
            "notes": "Zona desmilitarizada para proxies inversos, balanceadores HAProxy/Keepalived y portales públicos.",
        },
    ]

    for sdata in default_subnets:
        exists = db.query(CmdbSubnet).filter(CmdbSubnet.cidr == sdata["cidr"]).first()
        if not exists:
            db.add(CmdbSubnet(location_id=loc_id, **sdata))
    db.commit()

    # Sincronizar equipos físicos primero
    sync_physical_devices_to_cmdb(db)

    subnets = db.query(CmdbSubnet).all()
    sub_by_vlan = {s.vlan_id: s for s in subnets if s.vlan_id is not None}

    # Añadir IPs secundarias a los servidores físicos del Rack si sólo tienen 1 IP
    phys_servers = (
        db.query(CmdbAsset)
        .filter(CmdbAsset.sync_source == "rack_device", CmdbAsset.asset_class == "physical_server")
        .order_by(CmdbAsset.id)
        .all()
    )
    for idx, srv_asset in enumerate(phys_servers, start=1):
        if len(srv_asset.ip_addresses) <= 1:
            extra_ips = [
                CmdbIpAddress(
                    asset_id=srv_asset.id,
                    subnet_id=sub_by_vlan[99].id if 99 in sub_by_vlan else None,
                    ip_address=f"10.20.99.{20 + idx}",
                    subnet_mask="255.255.255.0",
                    gateway="10.20.99.1",
                    vlan_id=99,
                    ip_role="ilo_idrac",
                    interface_name="iDRAC / iLO Dedicated",
                    mac_address=f"D0:94:66:FA:99:{20 + idx:02X}",
                    fqdn=f"idrac-{srv_asset.hostname or f'srv0{idx}'}.hq.local",
                    is_heartbeat_ip=False,
                    allocation_status="assigned",
                    notes="Consola fuera de banda (KVM HTML5 / Virtual Media)",
                ),
                CmdbIpAddress(
                    asset_id=srv_asset.id,
                    subnet_id=sub_by_vlan[20].id if 20 in sub_by_vlan else None,
                    ip_address=f"10.20.20.{10 + idx}",
                    subnet_mask="255.255.255.0",
                    gateway="10.20.20.1",
                    vlan_id=20,
                    ip_role="primary_service",
                    interface_name="bond0.20 (Trunk 10GbE)",
                    mac_address=f"00:50:56:B0:20:{10 + idx:02X}",
                    fqdn=f"{srv_asset.hostname or f'srv0{idx}'}-prod.hq.local",
                    is_heartbeat_ip=False,
                    allocation_status="assigned",
                    notes="Bridge de producción / publicación de servicios del host",
                ),
                CmdbIpAddress(
                    asset_id=srv_asset.id,
                    subnet_id=sub_by_vlan[30].id if 30 in sub_by_vlan else None,
                    ip_address=f"10.20.30.{10 + idx}",
                    subnet_mask="255.255.255.0",
                    gateway="10.20.30.1",
                    vlan_id=30,
                    ip_role="storage",
                    interface_name="ens2f0.30 (SAN/vMotion)",
                    mac_address=f"00:50:56:B0:30:{10 + idx:02X}",
                    fqdn=f"{srv_asset.hostname or f'srv0{idx}'}-san.hq.local",
                    is_heartbeat_ip=False,
                    allocation_status="assigned",
                    notes="Interfaz dedicada a almacenamiento multipathing y vMotion",
                ),
            ]
            for eip in extra_ips:
                db.add(eip)
    db.commit()

    # Si ya existen activos exclusivos de la CMDB (VMs, Clusters, etc.), no duplicar
    cmdb_only_count = db.query(CmdbAsset).filter(CmdbAsset.sync_source == "cmdb").count()
    if cmdb_only_count > 0:
        return

    # Buscar los hipervisores físicos en RackDevice para vincularles las VMs de demostración
    srv1_rack_id = phys_servers[0].rack_device_id if len(phys_servers) >= 1 else None
    srv2_rack_id = phys_servers[1].rack_device_id if len(phys_servers) >= 2 else srv1_rack_id

    demo_cmdb_machines = [
        {
            "code": "VM-ERP-APP01",
            "name": "Servidor Aplicaciones ERP Corporativo (Nodo 1)",
            "hostname": "vm-erp-app01",
            "fqdn": "vm-erp-app01.hq.local",
            "asset_class": "virtual_machine",
            "environment": "production",
            "criticality": "critical",
            "lifecycle_status": "active",
            "os_or_firmware": "Ubuntu Server 24.04 LTS",
            "cpu_cores": 8,
            "ram_gb": 32.0,
            "storage_gb": 500.0,
            "hypervisor_or_platform": "VMware vSphere 8.0",
            "serial_or_uuid": "VMware-42 1a 9b 01-erp-app01",
            "owner_team": "Sistemas & ERP",
            "responsible_person": "Marta Fernández",
            "host_rack_device_id": srv1_rack_id,
            "monitoring_enabled": True,
            "monitor_method": "icmp",
            "monitor_port": 22,
            "status": "online",
            "notes": "Máquina Virtual de producción. Tiene IP de gestión (VLAN 10) para Heartbeat/SSH e IPs de servicio (VLAN 20) y Backup (VLAN 30).",
            "ips": [
                {
                    "ip_address": "10.20.1.110",
                    "vlan_id": 10,
                    "gateway": "10.20.1.1",
                    "ip_role": "mgmt_heartbeat",
                    "interface_name": "ens192 (Mgmt)",
                    "mac_address": "00:50:56:9A:10:01",
                    "fqdn": "vm-erp-app01-mgmt.hq.local",
                    "is_heartbeat_ip": True,
                    "notes": "IP para Heartbeat, monitorización y administración SSH",
                },
                {
                    "ip_address": "10.20.20.110",
                    "vlan_id": 20,
                    "gateway": "10.20.20.1",
                    "ip_role": "primary_service",
                    "interface_name": "ens224 (Prod App)",
                    "mac_address": "00:50:56:9A:20:01",
                    "fqdn": "erp.hq.local",
                    "is_heartbeat_ip": False,
                    "notes": "IP de servicio ERP (HTTPS 443 / API 8080)",
                },
                {
                    "ip_address": "10.20.30.110",
                    "vlan_id": 30,
                    "gateway": "10.20.30.1",
                    "ip_role": "backup",
                    "interface_name": "ens256 (Veeam Backup)",
                    "mac_address": "00:50:56:9A:30:01",
                    "fqdn": "vm-erp-app01-bkp.hq.local",
                    "is_heartbeat_ip": False,
                    "notes": "Tráfico de copias de seguridad nocturnas",
                },
            ],
        },
        {
            "code": "VM-DB-PG01",
            "name": "Base de Datos PostgreSQL HA (Master)",
            "hostname": "vm-db-pg01",
            "fqdn": "vm-db-pg01.hq.local",
            "asset_class": "virtual_machine",
            "environment": "production",
            "criticality": "critical",
            "lifecycle_status": "active",
            "os_or_firmware": "Red Hat Enterprise Linux 9.4",
            "cpu_cores": 16,
            "ram_gb": 64.0,
            "storage_gb": 2000.0,
            "hypervisor_or_platform": "VMware vSphere 8.0",
            "serial_or_uuid": "VMware-42 1a 9b 02-db-pg01",
            "owner_team": "DBA & Datos",
            "responsible_person": "Javier García",
            "host_rack_device_id": srv1_rack_id,
            "monitoring_enabled": True,
            "monitor_method": "tcp",
            "monitor_port": 5432,
            "status": "online",
            "notes": "Nodo primario del cluster Patroni/PostgreSQL. Maneja IP de gestión, IP de servicio BBDD, VIP de escritura e IP de réplica síncrona.",
            "ips": [
                {
                    "ip_address": "10.20.1.120",
                    "vlan_id": 10,
                    "gateway": "10.20.1.1",
                    "ip_role": "mgmt_heartbeat",
                    "interface_name": "ens192 (Mgmt)",
                    "mac_address": "00:50:56:9A:10:20",
                    "fqdn": "vm-db-pg01-mgmt.hq.local",
                    "is_heartbeat_ip": True,
                    "notes": "IP de gestión / Heartbeat",
                },
                {
                    "ip_address": "10.20.20.120",
                    "vlan_id": 20,
                    "gateway": "10.20.20.1",
                    "ip_role": "primary_service",
                    "interface_name": "ens224 (DB Listener)",
                    "mac_address": "00:50:56:9A:20:20",
                    "fqdn": "db-node1.hq.local",
                    "is_heartbeat_ip": False,
                    "notes": "IP fija del nodo 1 (Puerto 5432)",
                },
                {
                    "ip_address": "10.20.30.120",
                    "vlan_id": 30,
                    "gateway": "10.20.30.1",
                    "ip_role": "vmotion_replication",
                    "interface_name": "ens256 (WAL Sync)",
                    "mac_address": "00:50:56:9A:30:20",
                    "fqdn": "db-repl1.hq.local",
                    "is_heartbeat_ip": False,
                    "notes": "Red dedicada a replicación síncrona WAL entre nodos",
                },
            ],
        },
        {
            "code": "VM-DB-PG02",
            "name": "Base de Datos PostgreSQL HA (Standby Replica)",
            "hostname": "vm-db-pg02",
            "fqdn": "vm-db-pg02.hq.local",
            "asset_class": "virtual_machine",
            "environment": "production",
            "criticality": "critical",
            "lifecycle_status": "active",
            "os_or_firmware": "Red Hat Enterprise Linux 9.4",
            "cpu_cores": 16,
            "ram_gb": 64.0,
            "storage_gb": 2000.0,
            "hypervisor_or_platform": "VMware vSphere 8.0",
            "serial_or_uuid": "VMware-42 1a 9b 03-db-pg02",
            "owner_team": "DBA & Datos",
            "responsible_person": "Javier García",
            "host_rack_device_id": srv2_rack_id,
            "monitoring_enabled": True,
            "monitor_method": "tcp",
            "monitor_port": 5432,
            "status": "online",
            "notes": "Nodo secundario en otro servidor físico para tolerancia a fallos de hardware.",
            "ips": [
                {
                    "ip_address": "10.20.1.121",
                    "vlan_id": 10,
                    "gateway": "10.20.1.1",
                    "ip_role": "mgmt_heartbeat",
                    "interface_name": "ens192 (Mgmt)",
                    "mac_address": "00:50:56:9A:10:21",
                    "fqdn": "vm-db-pg02-mgmt.hq.local",
                    "is_heartbeat_ip": True,
                    "notes": "IP de gestión / Heartbeat",
                },
                {
                    "ip_address": "10.20.20.121",
                    "vlan_id": 20,
                    "gateway": "10.20.20.1",
                    "ip_role": "primary_service",
                    "interface_name": "ens224 (DB Listener)",
                    "mac_address": "00:50:56:9A:20:21",
                    "fqdn": "db-node2.hq.local",
                    "is_heartbeat_ip": False,
                    "notes": "IP fija del nodo 2 (Puerto 5432)",
                },
                {
                    "ip_address": "10.20.30.121",
                    "vlan_id": 30,
                    "gateway": "10.20.30.1",
                    "ip_role": "vmotion_replication",
                    "interface_name": "ens256 (WAL Sync)",
                    "mac_address": "00:50:56:9A:30:21",
                    "fqdn": "db-repl2.hq.local",
                    "is_heartbeat_ip": False,
                    "notes": "Red dedicada a replicación síncrona WAL",
                },
            ],
        },
        {
            "code": "CLU-PGSQL-VIP",
            "name": "Cluster BBDD Corporativa (VIP Alta Disponibilidad)",
            "hostname": "clu-pgsql-vip",
            "fqdn": "db-cluster.hq.local",
            "asset_class": "cluster_vip",
            "environment": "production",
            "criticality": "critical",
            "lifecycle_status": "active",
            "os_or_firmware": "Patroni + Keepalived HA",
            "cpu_cores": 32,
            "ram_gb": 128.0,
            "storage_gb": 2000.0,
            "hypervisor_or_platform": "Cluster Lógico Multi-Host",
            "serial_or_uuid": "CLU-HA-PGSQL-001",
            "owner_team": "DBA & Datos",
            "responsible_person": "Javier García",
            "host_rack_device_id": srv1_rack_id,
            "monitoring_enabled": True,
            "monitor_method": "tcp",
            "monitor_port": 5432,
            "status": "online",
            "notes": "Agrupa las IPs virtuales flotantes (VIP Read/Write y VIP Read-Only) compartidas entre VM-DB-PG01 y VM-DB-PG02.",
            "ips": [
                {
                    "ip_address": "10.20.20.100",
                    "vlan_id": 20,
                    "gateway": "10.20.20.1",
                    "ip_role": "vip_cluster",
                    "interface_name": "vip0 (Master RW)",
                    "mac_address": "00:00:5E:00:01:64",
                    "fqdn": "db-rw.hq.local",
                    "is_heartbeat_ip": True,
                    "notes": "VIP Flotante de Escritura (Apunta siempre al nodo Master activo)",
                },
                {
                    "ip_address": "10.20.20.101",
                    "vlan_id": 20,
                    "gateway": "10.20.20.1",
                    "ip_role": "secondary_service",
                    "interface_name": "vip1 (Replica RO)",
                    "mac_address": "00:00:5E:00:01:65",
                    "fqdn": "db-ro.hq.local",
                    "is_heartbeat_ip": False,
                    "notes": "VIP Balanceada de Solo Lectura para informes y BI",
                },
            ],
        },
        {
            "code": "VM-AD-DC01",
            "name": "Controlador de Dominio Active Directory & DNS Primario",
            "hostname": "dc01",
            "fqdn": "dc01.corp.local",
            "asset_class": "virtual_machine",
            "environment": "production",
            "criticality": "critical",
            "lifecycle_status": "active",
            "os_or_firmware": "Windows Server 2022 Datacenter",
            "cpu_cores": 4,
            "ram_gb": 16.0,
            "storage_gb": 250.0,
            "hypervisor_or_platform": "VMware vSphere 8.0",
            "serial_or_uuid": "VMware-42 1a 9b 04-ad-dc01",
            "owner_team": "Sistemas & Identidad",
            "responsible_person": "Alex Geng",
            "host_rack_device_id": srv2_rack_id,
            "monitoring_enabled": True,
            "monitor_method": "tcp",
            "monitor_port": 389,
            "status": "online",
            "notes": "Servidor Active Directory, Kerberos y DNS interno.",
            "ips": [
                {
                    "ip_address": "10.20.1.5",
                    "vlan_id": 10,
                    "gateway": "10.20.1.1",
                    "ip_role": "mgmt_heartbeat",
                    "interface_name": "Ethernet0 (Mgmt/DNS)",
                    "mac_address": "00:50:56:9A:10:05",
                    "fqdn": "dc01.corp.local",
                    "is_heartbeat_ip": True,
                    "notes": "IP primaria DNS y Gestión AD",
                },
                {
                    "ip_address": "10.20.20.5",
                    "vlan_id": 20,
                    "gateway": "10.20.20.1",
                    "ip_role": "primary_service",
                    "interface_name": "Ethernet1 (LDAP VLAN 20)",
                    "mac_address": "00:50:56:9A:20:05",
                    "fqdn": "ldap.corp.local",
                    "is_heartbeat_ip": False,
                    "notes": "Interfaz de autenticación LDAPS para aplicaciones de producción",
                },
            ],
        },
        {
            "code": "CT-WAF-PROXY01",
            "name": "Reverse Proxy & WAF Frontal (Contenedor LXC)",
            "hostname": "ct-waf-proxy01",
            "fqdn": "waf01.dmz.local",
            "asset_class": "container_lxc",
            "environment": "production",
            "criticality": "high",
            "lifecycle_status": "active",
            "os_or_firmware": "Alpine / Debian 12 LXC (Nginx + ModSecurity)",
            "cpu_cores": 4,
            "ram_gb": 8.0,
            "storage_gb": 60.0,
            "hypervisor_or_platform": "Proxmox VE / LXC",
            "serial_or_uuid": "LXC-104-WAF01",
            "owner_team": "Seguridad & Redes",
            "responsible_person": "Roberto Navarro",
            "host_rack_device_id": srv2_rack_id,
            "monitoring_enabled": True,
            "monitor_method": "https",
            "monitor_port": 443,
            "status": "online",
            "notes": "Contenedor con pata en gestión interna, pata en DMZ y pata hacia backend de producción.",
            "ips": [
                {
                    "ip_address": "10.20.1.140",
                    "vlan_id": 10,
                    "gateway": "10.20.1.1",
                    "ip_role": "mgmt_heartbeat",
                    "interface_name": "eth0 (Mgmt)",
                    "mac_address": "BC:24:11:00:10:40",
                    "fqdn": "waf01-mgmt.hq.local",
                    "is_heartbeat_ip": True,
                    "notes": "IP de gestión SSH y monitoreo Heartbeat",
                },
                {
                    "ip_address": "172.16.50.10",
                    "vlan_id": 50,
                    "gateway": "172.16.50.1",
                    "ip_role": "public_wan",
                    "interface_name": "eth1 (DMZ Frontend)",
                    "mac_address": "BC:24:11:00:50:10",
                    "fqdn": "portal.empresa.com",
                    "is_heartbeat_ip": False,
                    "notes": "IP expuesta en DMZ para entrada HTTPS 443",
                },
                {
                    "ip_address": "10.20.20.140",
                    "vlan_id": 20,
                    "gateway": "10.20.20.1",
                    "ip_role": "secondary_service",
                    "interface_name": "eth2 (Upstream Prod)",
                    "mac_address": "BC:24:11:00:20:40",
                    "fqdn": "waf01-upstream.hq.local",
                    "is_heartbeat_ip": False,
                    "notes": "Comunicación interna hacia los servidores de aplicaciones",
                },
            ],
        },
        {
            "code": "CLOUD-DR-VPS01",
            "name": "Nodo Contingencia & Pasarela Cloud (AWS eu-west-1)",
            "hostname": "aws-dr-gw01",
            "fqdn": "dr-gw01.cloud.empresa.local",
            "asset_class": "cloud_instance",
            "environment": "dr",
            "criticality": "high",
            "lifecycle_status": "active",
            "os_or_firmware": "Amazon Linux 2023",
            "cpu_cores": 8,
            "ram_gb": 32.0,
            "storage_gb": 1000.0,
            "hypervisor_or_platform": "AWS EC2 (VPC Túnel IPsec)",
            "serial_or_uuid": "i-0a98bc7654321fedc",
            "owner_team": "Cloud & Arquitectura",
            "responsible_person": "Alex Geng",
            "host_rack_device_id": None,
            "monitoring_enabled": True,
            "monitor_method": "icmp",
            "monitor_port": 22,
            "status": "online",
            "notes": "Instancia en nube externa fuera de los racks físicos, conectada por VPN Site-to-Site.",
            "ips": [
                {
                    "ip_address": "10.20.1.240",
                    "vlan_id": 10,
                    "gateway": "10.20.1.1",
                    "ip_role": "mgmt_heartbeat",
                    "interface_name": "wg0 / vti0 (Túnel VPN)",
                    "mac_address": "02:42:AC:11:00:F0",
                    "fqdn": "dr-gw01-vpn.hq.local",
                    "is_heartbeat_ip": True,
                    "notes": "IP interna del túnel para Heartbeat desde el CPD",
                },
                {
                    "ip_address": "52.214.88.19",
                    "vlan_id": None,
                    "gateway": "52.214.88.1",
                    "ip_role": "public_wan",
                    "interface_name": "ens5 (Elastic IP AWS)",
                    "mac_address": "0A:54:21:88:19:01",
                    "fqdn": "dr.empresa.com",
                    "is_heartbeat_ip": False,
                    "notes": "Elastic IP pública del nodo Cloud",
                },
            ],
        },
    ]

    for mdata in demo_cmdb_machines:
        ips_list = mdata.pop("ips", [])
        asset = CmdbAsset(sync_source="cmdb", **mdata)
        db.add(asset)
        db.flush()
        for ip_item in ips_list:
            matched_sub = _match_subnet_for_ip(ip_item["ip_address"], subnets)
            db.add(
                CmdbIpAddress(
                    asset_id=asset.id,
                    subnet_id=matched_sub.id if matched_sub else None,
                    subnet_mask="255.255.255.0",
                    allocation_status="assigned",
                    last_verification_status="active_in_network",
                    last_verified_at=datetime.utcnow(),
                    last_verification_detail="Verificado en aprovisionamiento inicial",
                    **ip_item,
                )
            )
    db.commit()


def _probe_single_tcp_port(target_ip: str, port: int, timeout_sec: float = 0.65) -> Tuple[int, str]:
    """
    Intenta abrir una conexión TCP a target_ip:port.
    Devuelve (port, state) donde state puede ser:
    - 'open': El puerto aceptó el handshake TCP (SYN-ACK).
    - 'refused_alive': El host devolvió un paquete TCP RST inmediato (ConnectionRefusedError),
      lo cual demuestra al 100% que la IP está viva en la red aunque ese puerto esté cerrado.
    - 'filtered_or_down': Timeout o inalcanzable.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout_sec)
    try:
        sock.connect((target_ip, port))
        return port, "open"
    except ConnectionRefusedError:
        return port, "refused_alive"
    except Exception:
        return port, "filtered_or_down"
    finally:
        try:
            sock.close()
        except Exception:
            pass


def _lookup_arp_mac(target_ip: str) -> Optional[str]:
    """
    Consulta la tabla ARP del sistema operativo (macOS / Linux) tras haber enviado sondas a target_ip.
    Si aparece una dirección MAC válida (distinta de incomplete/ff:ff:ff:ff:ff:ff), la devuelve.
    """
    for cmd in (["arp", "-n", target_ip], ["ip", "neigh", "show", target_ip]):
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=1.5)
            out = (proc.stdout or "") + " " + (proc.stderr or "")
            if "incomplete" in out.lower() or "failed" in out.lower():
                continue
            m = re.search(r"([0-9a-fA-F]{1,2}(?::[0-9a-fA-F]{1,2}){5})", out)
            if m:
                mac = m.group(1).upper()
                if mac != "FF:FF:FF:FF:FF:FF" and mac != "00:00:00:00:00:00":
                    return mac
        except Exception:
            continue
    return None


def _lookup_reverse_dns(target_ip: str) -> Optional[str]:
    """Intenta resolución DNS inversa (PTR) para la IP indicada."""
    try:
        old_to = socket.getdefaulttimeout()
        socket.setdefaulttimeout(0.8)
        try:
            host, _, _ = socket.gethostbyaddr(target_ip)
            return host
        finally:
            socket.setdefaulttimeout(old_to)
    except Exception:
        return None


def verify_single_ip_manual(
    db: Session,
    target_ip: str,
    ports: Optional[List[int]] = None,
    timeout_sec: float = 0.8,
) -> Dict[str, Any]:
    """
    Ejecuta la verificación manual multicapa ("Deep IP Probe") sobre una IP para comprobar:
    1) Estado documental en la CMDB (¿está libre o asignada a qué máquina y con qué rol?)
    2) Sonda 1 - Ping ICMP real y latencia en ms
    3) Sonda 2 - Sondeo TCP multi-puerto en paralelo (detecta puertos abiertos o respuestas TCP RST de hosts con Ping bloqueado)
    4) Sonda 3 - Tabla ARP / Vecinos L2 (detecta dirección MAC en la red local aunque tenga firewall estricto)
    5) Sonda 4 - Resolución DNS Inversa (PTR)
    """
    ip_clean = (target_ip or "").strip().split("/")[0].strip()
    try:
        ipaddress.ip_address(ip_clean)
    except ValueError:
        raise ValueError(f"La dirección IP '{target_ip}' no tiene un formato IPv4/IPv6 válido.")

    probe_ports = ports or [22, 80, 443, 3389, 445, 8006, 902, 161]
    start_ts = time.perf_counter()

    # 1. Buscar en CMDB si la IP está documentada
    cmdb_records = (
        db.query(CmdbIpAddress)
        .options(joinedload(CmdbIpAddress.asset))
        .filter(CmdbIpAddress.ip_address == ip_clean)
        .all()
    )
    documented_in_cmdb = len(cmdb_records) > 0
    cmdb_owners: List[Dict[str, Any]] = []
    for rec in cmdb_records:
        ast = rec.asset
        cmdb_owners.append(
            {
                "ip_id": rec.id,
                "asset_id": ast.id if ast else None,
                "asset_code": ast.code if ast else "RESERVA-IPAM",
                "asset_name": ast.name if ast else "IP Reservada sin Máquina",
                "asset_class": ast.asset_class if ast else "reserved",
                "ip_role": rec.ip_role,
                "ip_role_label": IP_ROLE_LABELS.get(rec.ip_role, rec.ip_role),
                "interface_name": rec.interface_name,
                "is_heartbeat_ip": rec.is_heartbeat_ip,
                "fqdn": rec.fqdn or (ast.fqdn if ast else ""),
                "allocation_status": rec.allocation_status,
            }
        )

    # 2. Sonda ICMP Ping
    icmp_status, icmp_ms, icmp_detail = check_host_connectivity(
        host=ip_clean,
        method="icmp",
        port=0,
        timeout_sec=max(0.5, min(timeout_sec, 2.0)),
    )
    icmp_alive = icmp_status == "online"

    # 3. Sonda TCP Multi-Puerto concurrente
    open_ports: List[int] = []
    refused_ports: List[int] = []
    with ThreadPoolExecutor(max_workers=min(8, max(1, len(probe_ports)))) as pool:
        futures = [
            pool.submit(_probe_single_tcp_port, ip_clean, p, max(0.35, min(timeout_sec, 1.0)))
            for p in probe_ports
        ]
        for fut in futures:
            p_num, p_state = fut.result()
            if p_state == "open":
                open_ports.append(p_num)
            elif p_state == "refused_alive":
                refused_ports.append(p_num)

    tcp_alive = len(open_ports) > 0 or len(refused_ports) > 0

    # 4. Sonda ARP (Caché L2 tras haber enviado paquetes ICMP y TCP SYN)
    arp_mac = _lookup_arp_mac(ip_clean)
    arp_alive = arp_mac is not None

    # 5. Sonda DNS Inverso (PTR)
    ptr_hostname = _lookup_reverse_dns(ip_clean)
    has_ptr = ptr_hostname is not None and ptr_hostname != ip_clean

    network_responding = icmp_alive or tcp_alive or arp_alive
    elapsed_total_ms = round((time.perf_counter() - start_ts) * 1000.0, 1)

    # Determinar veredicto del semáforo CMDB
    if not documented_in_cmdb and not network_responding and not has_ptr:
        verdict = "free_confirmed"
        verdict_label = "LIBRE CONFIRMADA (Segura para asignar)"
        verdict_severity = "success"
        can_safely_assign = True
        recommendation = (
            "La IP no figura en la CMDB y ninguna de las 4 sondas (Ping ICMP, Puertos TCP, ARP L2 ni DNS PTR) "
            "ha detectado actividad. Puedes asignarla con seguridad a una nueva máquina."
        )
    elif not documented_in_cmdb and (network_responding or has_ptr):
        verdict = "conflict_unregistered"
        verdict_label = "¡CONFLICTO FANTASMA! (Responde en red pero NO está en la CMDB)"
        verdict_severity = "danger"
        can_safely_assign = False
        reasons = []
        if icmp_alive:
            reasons.append(f"responde a Ping ({icmp_ms} ms)")
        if open_ports:
            reasons.append(f"tiene puertos TCP abiertos ({', '.join(map(str, open_ports))})")
        elif refused_ports:
            reasons.append(f"su pila TCP/IP rechaza activamente paquetes RST ({', '.join(map(str, refused_ports[:3]))})")
        if arp_mac:
            reasons.append(f"resuelve MAC en tabla ARP ({arp_mac})")
        if has_ptr:
            reasons.append(f"tiene DNS PTR ({ptr_hostname})")
        recommendation = (
            f"¡PELIGRO DE CONFLICTO IP! Aunque figuraba libre en la CMDB, un equipo en la red {', '.join(reasons)}. "
            "NO asignes esta IP a otra máquina; regístrala en la CMDB para corregir el desfase."
        )
    elif documented_in_cmdb and network_responding:
        verdict = "active_in_network"
        verdict_label = "OCUPADA Y ACTIVA (Coherente con CMDB)"
        verdict_severity = "info"
        can_safely_assign = False
        owner_names = ", ".join(f"{o['asset_code']} ({o['ip_role_label']})" for o in cmdb_owners)
        recommendation = (
            f"La IP ya está asignada en la CMDB a [{owner_names}] y responde activamente en la red."
        )
    else:
        # documented_in_cmdb and not network_responding
        verdict = "no_response"
        verdict_label = "ASIGNADA EN CMDB PERO SIN RESPUESTA EN RED"
        verdict_severity = "warning"
        can_safely_assign = False
        owner_names = ", ".join(f"{o['asset_code']} ({o['ip_role_label']})" for o in cmdb_owners)
        recommendation = (
            f"La IP figura asignada en la CMDB a [{owner_names}], pero actualmente no responde a Ping, TCP ni ARP. "
            "Puede tratarse de una máquina apagada por mantenimiento o de un registro obsoleto que conviene auditar/liberar."
        )

    probe_summary_parts = [
        f"ICMP: {'OK (' + str(icmp_ms) + ' ms)' if icmp_alive else 'Sin respuesta'}",
        f"TCP: {'Abiertos ' + str(open_ports) if open_ports else ('Activo RST ' + str(refused_ports[:3]) if refused_ports else '0 puertos')}",
        f"ARP: {arp_mac or 'Sin MAC local'}",
        f"DNS PTR: {ptr_hostname or 'Sin PTR'}",
    ]
    summary_text = " | ".join(probe_summary_parts)

    # Si existe en la CMDB, guardar la fecha y resultado de esta verificación manual
    now_dt = datetime.utcnow()
    if cmdb_records:
        for rec in cmdb_records:
            rec.last_verification_status = verdict
            rec.last_verified_at = now_dt
            rec.last_verification_detail = summary_text
        db.commit()

    subnets = db.query(CmdbSubnet).all()
    matched_sub = _match_subnet_for_ip(ip_clean, subnets)

    return {
        "ip_address": ip_clean,
        "subnet_id": matched_sub.id if matched_sub else None,
        "subnet_cidr": matched_sub.cidr if matched_sub else "",
        "subnet_name": matched_sub.name if matched_sub else "",
        "vlan_id": matched_sub.vlan_id if matched_sub else None,
        "gateway": matched_sub.gateway if matched_sub else "",
        "documented_in_cmdb": documented_in_cmdb,
        "cmdb_owners": cmdb_owners,
        "network_responding": network_responding,
        "can_safely_assign": can_safely_assign,
        "verdict": verdict,
        "verdict_label": verdict_label,
        "verdict_severity": verdict_severity,
        "recommendation": recommendation,
        "summary": summary_text,
        "elapsed_ms": elapsed_total_ms,
        "checked_at": now_dt.isoformat(),
        "probes": {
            "icmp": {
                "alive": icmp_alive,
                "latency_ms": icmp_ms,
                "detail": icmp_detail,
            },
            "tcp": {
                "alive": tcp_alive,
                "tested_ports": probe_ports,
                "open_ports": open_ports,
                "refused_alive_ports": refused_ports,
                "detail": (
                    f"Puertos abiertos: {open_ports}"
                    if open_ports
                    else (
                        f"Host vivo (rechazo TCP RST en {refused_ports})"
                        if refused_ports
                        else f"Sin respuesta en puertos {probe_ports}"
                    )
                ),
            },
            "arp": {
                "alive": arp_alive,
                "mac_address": arp_mac or "",
                "detail": f"MAC detectada en caché ARP: {arp_mac}" if arp_mac else "Sin entrada ARP L2 local",
            },
            "dns_ptr": {
                "has_ptr": has_ptr,
                "ptr_hostname": ptr_hostname or "",
                "detail": f"Resolución inversa PTR: {ptr_hostname}" if has_ptr else "Sin registro DNS inverso (PTR)",
            },
        },
    }


def verify_ip_target_or_find_free(
    db: Session,
    target_ip: str = "",
    subnet_id: Optional[int] = None,
    ports: Optional[List[int]] = None,
    timeout_sec: float = 0.7,
    count_limit: int = 8,
    only_suggest_free: bool = False,
) -> Dict[str, Any]:
    """
    Soporta 3 modos de operación manual:
    1) Si se pasa una IP única (ej. '10.20.20.45'): verifica esa IP en profundidad.
    2) Si se pasa un rango corto (ej. '10.20.20.40-10.20.20.48' o '10.20.20.40-48'): verifica cada IP del rango.
    3) Si 'only_suggest_free=True' (o no se pasa target_ip pero sí subnet_id): busca en la subred seleccionada
       las siguientes IPs que no estén asignadas en la CMDB y las verifica en vivo en la red hasta encontrar
       IPs libres confirmadas ('free_confirmed') listas para asignar.
    """
    raw = (target_ip or "").strip()
    ips_to_test: List[str] = []

    if raw and not only_suggest_free:
        if "-" in raw:
            left, right = [x.strip() for x in raw.split("-", 1)]
            start_ip = ipaddress.ip_address(left)
            if "." in right:
                end_ip = ipaddress.ip_address(right)
            else:
                prefix = left.rsplit(".", 1)[0]
                end_ip = ipaddress.ip_address(f"{prefix}.{int(right)}")
            curr = int(start_ip)
            end_val = int(end_ip)
            if end_val < curr:
                curr, end_val = end_val, curr
            max_span = min(end_val - curr + 1, max(1, min(count_limit, 25)))
            for offset in range(max_span):
                ips_to_test.append(str(ipaddress.ip_address(curr + offset)))
        elif "," in raw:
            parts = [p.strip() for p in raw.split(",") if p.strip()]
            ips_to_test = parts[: max(1, min(count_limit, 25))]
        else:
            ips_to_test = [raw]
    else:
        # Buscar candidatas libres en la subred indicada (o la primera subred disponible)
        subnet = None
        if subnet_id is not None:
            subnet = db.query(CmdbSubnet).filter(CmdbSubnet.id == subnet_id).first()
        if not subnet:
            subnet = db.query(CmdbSubnet).order_by(CmdbSubnet.id).first()
        if not subnet:
            raise ValueError("No hay subredes configuradas en la CMDB para buscar IPs libres.")

        net = ipaddress.ip_network(subnet.cidr.strip(), strict=False)
        used_ips = {
            row.ip_address.strip()
            for row in db.query(CmdbIpAddress).all()
            if row.ip_address
        }
        if subnet.gateway:
            used_ips.add(subnet.gateway.strip())

        # Empezar a buscar a partir de .15 (dejando margen de primeros hosts de red/gateways)
        candidates: List[str] = []
        for host_ip in net.hosts():
            ip_str = str(host_ip)
            last_octet = int(ip_str.rsplit(".", 1)[-1]) if "." in ip_str else 10
            if last_octet < 15 or last_octet >= 250:
                continue
            if ip_str not in used_ips:
                candidates.append(ip_str)
            if len(candidates) >= max(1, min(count_limit, 15)):
                break
        ips_to_test = candidates

    results: List[Dict[str, Any]] = []
    for ip_candidate in ips_to_test:
        res = verify_single_ip_manual(
            db=db,
            target_ip=ip_candidate,
            ports=ports,
            timeout_sec=timeout_sec,
        )
        results.append(res)

    free_confirmed_list = [r["ip_address"] for r in results if r["verdict"] == "free_confirmed"]
    conflicts_list = [r["ip_address"] for r in results if r["verdict"] == "conflict_unregistered"]

    return {
        "tested_count": len(results),
        "free_confirmed_count": len(free_confirmed_list),
        "conflict_count": len(conflicts_list),
        "suggested_free_ip": free_confirmed_list[0] if free_confirmed_list else None,
        "results": results,
    }


def check_cmdb_asset_heartbeat(db: Session, asset: CmdbAsset) -> Dict[str, Any]:
    """
    Ejecuta el chequeo de Heartbeat sobre un activo de la CMDB (ej. una Máquina Virtual, Contenedor o Cluster)
    usando su IP marcada como 'is_heartbeat_ip' (o su primera IP disponible).
    Si el activo está sincronizado con un RackDevice o FloorDevice, delega/sincroniza también su estado.
    """
    hb_ip_obj = next(
        (ip for ip in asset.ip_addresses if ip.is_heartbeat_ip),
        asset.ip_addresses[0] if asset.ip_addresses else None,
    )
    target = (hb_ip_obj.ip_address if hb_ip_obj else "") or asset.fqdn or asset.hostname or ""
    method = (asset.monitor_method or "icmp").lower().strip()
    port = int(asset.monitor_port or 22)

    if not target:
        asset.status = "offline"
        asset.last_ping_ms = None
        asset.last_checked_at = datetime.utcnow()
        db.commit()
        return {
            "asset_id": asset.id,
            "code": asset.code,
            "target": "",
            "method": method,
            "status": "offline",
            "last_ping_ms": None,
            "detail": "El activo no tiene ninguna IP de Heartbeat ni FQDN configurados.",
        }

    st, lat, det = check_host_connectivity(
        host=target,
        method=method,
        port=port,
        timeout_sec=1.5,
        extra_config=dict(asset.custom_fields or {}),
        device_code=asset.code,
    )
    now_dt = datetime.utcnow()
    asset.status = st
    asset.last_ping_ms = lat
    asset.last_checked_at = now_dt
    if hb_ip_obj:
        hb_ip_obj.last_verification_status = "active_in_network" if st == "online" else "no_response"
        hb_ip_obj.last_verified_at = now_dt
        hb_ip_obj.last_verification_detail = det

    # Si está vinculado 1:1 con un RackDevice o FloorDevice, reflejar el estado
    if asset.sync_source == "rack_device" and asset.rack_device_id:
        rdev = db.query(RackDevice).filter(RackDevice.id == asset.rack_device_id).first()
        if rdev:
            rdev.status = st
            rdev.last_ping_ms = lat
            rdev.last_checked_at = now_dt
    elif asset.sync_source == "floor_device" and asset.floor_device_id:
        fdev = db.query(FloorDevice).filter(FloorDevice.id == asset.floor_device_id).first()
        if fdev:
            fdev.status = st
            fdev.last_ping_ms = lat
            fdev.last_checked_at = now_dt

    db.commit()
    db.refresh(asset)
    return {
        "asset_id": asset.id,
        "code": asset.code,
        "name": asset.name,
        "target": target,
        "method": method,
        "port": port,
        "status": st,
        "last_ping_ms": lat,
        "last_checked_at": now_dt.isoformat(),
        "detail": det,
    }


def serialize_cmdb_asset(
    asset: CmdbAsset,
    racks_by_id: Dict[int, Rack],
    rack_devs_by_id: Dict[int, RackDevice],
    subnets_by_id: Dict[int, CmdbSubnet],
    assets_by_id: Dict[int, CmdbAsset],
) -> Dict[str, Any]:
    ips_serialized = []
    heartbeat_ip = ""
    service_ips: List[str] = []

    for ip in asset.ip_addresses:
        sub = subnets_by_id.get(ip.subnet_id) if ip.subnet_id else None
        if ip.is_heartbeat_ip or (not heartbeat_ip and ip.ip_role == "mgmt_heartbeat"):
            heartbeat_ip = ip.ip_address
        else:
            service_ips.append(ip.ip_address)
        ips_serialized.append(
            {
                "id": ip.id,
                "asset_id": ip.asset_id,
                "subnet_id": ip.subnet_id,
                "subnet_cidr": sub.cidr if sub else "",
                "subnet_name": sub.name if sub else "",
                "ip_address": ip.ip_address,
                "subnet_mask": ip.subnet_mask,
                "gateway": ip.gateway,
                "vlan_id": ip.vlan_id,
                "ip_role": ip.ip_role,
                "ip_role_label": IP_ROLE_LABELS.get(ip.ip_role, ip.ip_role),
                "interface_name": ip.interface_name,
                "mac_address": ip.mac_address,
                "fqdn": ip.fqdn,
                "is_heartbeat_ip": ip.is_heartbeat_ip,
                "allocation_status": ip.allocation_status,
                "last_verification_status": ip.last_verification_status,
                "last_verified_at": ip.last_verified_at.isoformat() if ip.last_verified_at else None,
                "last_verification_detail": ip.last_verification_detail or "",
                "notes": ip.notes or "",
            }
        )

    if not heartbeat_ip and ips_serialized:
        heartbeat_ip = ips_serialized[0]["ip_address"]

    # Información de ubicación física o Hipervisor Padre
    physical_location_label = "Virtual / No ubicado en Rack"
    rack_id = None
    rack_code = ""
    start_u = None
    host_server_label = ""

    if asset.sync_source == "rack_device" and asset.rack_device_id:
        rdev = rack_devs_by_id.get(asset.rack_device_id)
        if rdev:
            rk = racks_by_id.get(rdev.rack_id)
            rack_id = rdev.rack_id
            rack_code = rk.code if rk else ""
            start_u = rdev.start_u
            physical_location_label = f"Rack {rack_code} • U{rdev.start_u} ({rdev.mounted_face.upper()})"
    elif asset.host_rack_device_id:
        host_dev = rack_devs_by_id.get(asset.host_rack_device_id)
        if host_dev:
            rk = racks_by_id.get(host_dev.rack_id)
            rack_id = host_dev.rack_id
            rack_code = rk.code if rk else ""
            start_u = host_dev.start_u
            host_server_label = f"{host_dev.code} ({host_dev.name})"
            physical_location_label = f"Alojado en {host_dev.code} [Rack {rack_code} • U{host_dev.start_u}]"
    elif asset.sync_source == "floor_device":
        physical_location_label = asset.hypervisor_or_platform or "Dispositivo en Planta"
    elif asset.asset_class == "cloud_instance":
        physical_location_label = asset.hypervisor_or_platform or "Cloud / Externo"

    parent_ast = assets_by_id.get(asset.parent_asset_id) if asset.parent_asset_id else None

    return {
        "id": asset.id,
        "code": asset.code,
        "name": asset.name,
        "hostname": asset.hostname,
        "fqdn": asset.fqdn,
        "asset_class": asset.asset_class,
        "asset_class_label": ASSET_CLASS_LABELS.get(asset.asset_class, asset.asset_class),
        "environment": asset.environment,
        "criticality": asset.criticality,
        "lifecycle_status": asset.lifecycle_status,
        "os_or_firmware": asset.os_or_firmware,
        "cpu_cores": asset.cpu_cores,
        "ram_gb": asset.ram_gb,
        "storage_gb": asset.storage_gb,
        "hypervisor_or_platform": asset.hypervisor_or_platform,
        "serial_or_uuid": asset.serial_or_uuid,
        "owner_team": asset.owner_team,
        "responsible_person": asset.responsible_person,
        "sync_source": asset.sync_source,
        "rack_device_id": asset.rack_device_id,
        "floor_device_id": asset.floor_device_id,
        "host_rack_device_id": asset.host_rack_device_id,
        "host_server_label": host_server_label,
        "parent_asset_id": asset.parent_asset_id,
        "parent_asset_code": parent_ast.code if parent_ast else "",
        "rack_id": rack_id,
        "rack_code": rack_code,
        "start_u": start_u,
        "physical_location_label": physical_location_label,
        "monitoring_enabled": asset.monitoring_enabled,
        "monitor_method": asset.monitor_method,
        "monitor_port": asset.monitor_port,
        "status": asset.status,
        "last_ping_ms": asset.last_ping_ms,
        "last_checked_at": asset.last_checked_at.isoformat() if asset.last_checked_at else None,
        "management_links": asset.management_links or [],
        "custom_fields": asset.custom_fields or {},
        "notes": asset.notes or "",
        "heartbeat_ip": heartbeat_ip,
        "service_ips": service_ips,
        "ip_count": len(ips_serialized),
        "ip_addresses": ips_serialized,
    }


def build_cmdb_overview(db: Session) -> Dict[str, Any]:
    """
    Devuelve el estado completo de la CMDB:
    - 'summary': KPIs (Total máquinas, VMs, Físicos, Contenedores/Clusters, Total IPs, Subredes, Conflictos)
    - 'assets': Todas las máquinas/CIs (físicas sincronizadas + virtuales/clusters/cloud gestionadas en CMDB) con sus múltiples IPs
    - 'subnets': Todas las subredes con su ocupación y mapa de direcciones (.1 a .254)
    - 'physical_hosts': Lista de servidores físicos de Rack disponibles para seleccionarlos como Hipervisor/Host Padre de VMs
    """
    sync_physical_devices_to_cmdb(db)

    racks = db.query(Rack).all()
    racks_by_id = {r.id: r for r in racks}
    rack_devs = db.query(RackDevice).options(joinedload(RackDevice.template)).all()
    rack_devs_by_id = {d.id: d for d in rack_devs}

    subnets = db.query(CmdbSubnet).order_by(CmdbSubnet.vlan_id, CmdbSubnet.id).all()
    subnets_by_id = {s.id: s for s in subnets}

    assets = (
        db.query(CmdbAsset)
        .options(joinedload(CmdbAsset.ip_addresses))
        .order_by(CmdbAsset.id)
        .all()
    )
    assets_by_id = {a.id: a for a in assets}

    serialized_assets = [
        serialize_cmdb_asset(a, racks_by_id, rack_devs_by_id, subnets_by_id, assets_by_id)
        for a in assets
    ]

    # Construir detalle de subredes y mapa de ocupación
    all_ips = db.query(CmdbIpAddress).options(joinedload(CmdbIpAddress.asset)).all()
    serialized_subnets = []
    for sub in subnets:
        try:
            net = ipaddress.ip_network(sub.cidr.strip(), strict=False)
            total_usable = max(1, net.num_addresses - 2) if net.num_addresses > 2 else net.num_addresses
        except ValueError:
            net = None
            total_usable = 254

        sub_ips = [
            ip for ip in all_ips
            if ip.subnet_id == sub.id or (net is not None and _match_subnet_for_ip(ip.ip_address, [sub]) is not None)
        ]
        used_map: Dict[str, Dict[str, Any]] = {}
        for ip_rec in sub_ips:
            ast = ip_rec.asset
            used_map[ip_rec.ip_address] = {
                "ip_id": ip_rec.id,
                "ip_address": ip_rec.ip_address,
                "asset_id": ast.id if ast else None,
                "asset_code": ast.code if ast else "RESERVA",
                "asset_name": ast.name if ast else "Reservada",
                "asset_class": ast.asset_class if ast else "reserved",
                "ip_role": ip_rec.ip_role,
                "ip_role_label": IP_ROLE_LABELS.get(ip_rec.ip_role, ip_rec.ip_role),
                "interface_name": ip_rec.interface_name,
                "fqdn": ip_rec.fqdn or (ast.fqdn if ast else ""),
                "is_heartbeat_ip": ip_rec.is_heartbeat_ip,
                "allocation_status": ip_rec.allocation_status,
                "last_verification_status": ip_rec.last_verification_status,
                "last_verified_at": ip_rec.last_verified_at.isoformat() if ip_rec.last_verified_at else None,
            }

        occupied_count = len(used_map)
        usage_pct = round((occupied_count / total_usable) * 100.0, 1) if total_usable > 0 else 0.0

        serialized_subnets.append(
            {
                "id": sub.id,
                "cidr": sub.cidr,
                "name": sub.name,
                "vlan_id": sub.vlan_id,
                "gateway": sub.gateway,
                "subnet_mask": sub.subnet_mask,
                "dns_servers": sub.dns_servers,
                "environment": sub.environment,
                "location_id": sub.location_id,
                "notes": sub.notes or "",
                "total_usable": total_usable,
                "occupied_count": occupied_count,
                "free_count": max(0, total_usable - occupied_count),
                "usage_percent": usage_pct,
                "allocated_ips": list(used_map.values()),
            }
        )

    # Lista de servidores físicos del Rack para selector de "Host Hipervisor Padre"
    physical_hosts = []
    for d in rack_devs:
        if (d.mounted_face or "").lower() == "external":
            continue
        cat = (d.template.category if d.template else "").lower()
        if cat in ("server", "firewall", "router", "switch", "storage_san", "storage_nas"):
            rk = racks_by_id.get(d.rack_id)
            hosted_vms = [
                a["code"]
                for a in serialized_assets
                if a["host_rack_device_id"] == d.id and a["sync_source"] == "cmdb"
            ]
            physical_hosts.append(
                {
                    "rack_device_id": d.id,
                    "code": d.code,
                    "name": d.name,
                    "category": cat,
                    "rack_id": d.rack_id,
                    "rack_code": rk.code if rk else "",
                    "start_u": d.start_u,
                    "ip_address": d.ip_address,
                    "hosted_vms_count": len(hosted_vms),
                    "hosted_vm_codes": hosted_vms,
                }
            )

    vm_count = sum(1 for a in serialized_assets if a["asset_class"] in ("virtual_machine", "virtual_appliance"))
    container_cluster_count = sum(1 for a in serialized_assets if a["asset_class"] in ("container_lxc", "cluster_vip", "cloud_instance"))
    phys_count = sum(1 for a in serialized_assets if a["sync_source"] in ("rack_device", "floor_device") or a["asset_class"] == "physical_server")
    multi_ip_hosts = sum(1 for a in serialized_assets if a["ip_count"] > 1)
    conflict_ips = sum(1 for ip in all_ips if ip.last_verification_status == "conflict_unregistered")

    return {
        "summary": {
            "total_assets": len(serialized_assets),
            "virtual_machines_count": vm_count,
            "containers_and_clusters_count": container_cluster_count,
            "physical_assets_count": phys_count,
            "multi_ip_assets_count": multi_ip_hosts,
            "total_ip_addresses": len(all_ips),
            "total_subnets": len(serialized_subnets),
            "conflict_ips_count": conflict_ips,
        },
        "assets": serialized_assets,
        "subnets": serialized_subnets,
        "physical_hosts": physical_hosts,
    }
