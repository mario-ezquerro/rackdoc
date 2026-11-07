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
                cpu_cores=int(cf.get("cpu_cores") or 0),
                ram_gb=float(cf.get("ram_gb") or 0.0),
                storage_gb=float(cf.get("storage_gb") or 0.0),
                hypervisor_or_platform="Baremetal / Chasis en Rack" if cat != "server" else str(cf.get("hypervisor") or "Servidor Físico en Rack"),
                serial_or_uuid=rdev.serial_number or "",
                owner_team="",
                responsible_person=rdev.rack.responsible_person if rdev.rack else "",
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
    Sincroniza únicamente los equipos reales de Rack y Planta con la CMDB,
    sin inyectar subredes ni máquinas virtuales ficticias de demostración.
    """
    sync_physical_devices_to_cmdb(db)



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


def _probe_ip_network_only(
    ip_clean: str,
    probe_ports: List[int],
    timeout_sec: float = 0.6,
    is_bulk_scan: bool = False,
) -> Dict[str, Any]:
    """
    Sondeo puro de red (sin tocar sesión de BD, 100% thread-safe para escanear /24 en paralelo).
    Ejecuta:
    1) ICMP Ping
    2) Sondeo TCP a puertos comunes (detectando tanto SYN-ACK 'open' como rechazo activo 'refused_alive')
    3) Tabla ARP local (MAC Address)
    4) DNS Inverso (PTR)
    """
    start_ts = time.perf_counter()
    eff_icmp_timeout = 0.35 if is_bulk_scan else max(0.45, min(timeout_sec, 1.5))
    eff_tcp_timeout = 0.25 if is_bulk_scan else max(0.3, min(timeout_sec, 0.8))

    icmp_status, icmp_ms, icmp_detail = check_host_connectivity(
        host=ip_clean,
        method="icmp",
        port=0,
        timeout_sec=eff_icmp_timeout,
    )
    icmp_alive = icmp_status == "online"

    open_ports: List[int] = []
    refused_ports: List[int] = []
    ports_to_check = probe_ports[:4] if is_bulk_scan else probe_ports
    for p in ports_to_check:
        p_num, p_state = _probe_single_tcp_port(ip_clean, p, eff_tcp_timeout)
        if p_state == "open":
            open_ports.append(p_num)
        elif p_state == "refused_alive":
            refused_ports.append(p_num)

    # Si en modo masivo respondió a ping o algún puerto, probamos el resto de puertos para dar el informe completo
    if is_bulk_scan and (icmp_alive or open_ports or refused_ports) and len(probe_ports) > 4:
        for p in probe_ports[4:]:
            p_num, p_state = _probe_single_tcp_port(ip_clean, p, eff_tcp_timeout)
            if p_state == "open":
                open_ports.append(p_num)
            elif p_state == "refused_alive":
                refused_ports.append(p_num)

    tcp_alive = len(open_ports) > 0 or len(refused_ports) > 0
    arp_mac = _lookup_arp_mac(ip_clean) if (not is_bulk_scan or icmp_alive or tcp_alive) else None
    if not arp_mac and not is_bulk_scan:
        arp_mac = _lookup_arp_mac(ip_clean)
    arp_alive = arp_mac is not None

    # En escaneos masivos (/24), hacer DNS PTR sobre las IPs activas (o todas si es rango pequeño) para no bloquear 254 timeouts DNS
    ptr_hostname = (
        _lookup_reverse_dns(ip_clean)
        if (not is_bulk_scan or icmp_alive or tcp_alive or arp_alive)
        else None
    )
    has_ptr = ptr_hostname is not None and ptr_hostname != ip_clean
    elapsed_total_ms = round((time.perf_counter() - start_ts) * 1000.0, 1)

    return {
        "ip_clean": ip_clean,
        "icmp_alive": icmp_alive,
        "icmp_ms": icmp_ms,
        "icmp_detail": icmp_detail,
        "tcp_alive": tcp_alive,
        "tested_ports": probe_ports,
        "open_ports": open_ports,
        "refused_ports": refused_ports,
        "arp_alive": arp_alive,
        "arp_mac": arp_mac,
        "has_ptr": has_ptr,
        "ptr_hostname": ptr_hostname,
        "elapsed_ms": elapsed_total_ms,
    }


def _assemble_ip_verification_result(
    probe_data: Dict[str, Any],
    cmdb_owners: List[Dict[str, Any]],
    matched_sub: Optional[CmdbSubnet],
    now_dt: datetime,
) -> Dict[str, Any]:
    ip_clean = probe_data["ip_clean"]
    icmp_alive = probe_data["icmp_alive"]
    icmp_ms = probe_data["icmp_ms"]
    icmp_detail = probe_data["icmp_detail"]
    tcp_alive = probe_data["tcp_alive"]
    probe_ports = probe_data["tested_ports"]
    open_ports = probe_data["open_ports"]
    refused_ports = probe_data["refused_ports"]
    arp_alive = probe_data["arp_alive"]
    arp_mac = probe_data["arp_mac"]
    has_ptr = probe_data["has_ptr"]
    ptr_hostname = probe_data["ptr_hostname"]
    elapsed_total_ms = probe_data["elapsed_ms"]

    documented_in_cmdb = len(cmdb_owners) > 0
    network_responding = icmp_alive or tcp_alive or arp_alive

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
        verdict_label = "DETECTADO EN RED (No registrado en CMDB)"
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
            f"Equipo activo detectado en la red ({', '.join(reasons)}) que aún NO está registrado en la CMDB. "
            "Puedes seleccionarlo y añadirlo a la CMDB directamente desde aquí (y no debes asignar su IP a otra máquina)."
        )
    elif documented_in_cmdb and network_responding:
        verdict = "active_in_network"
        verdict_label = "YA EN CMDB Y ACTIVA EN RED"
        verdict_severity = "info"
        can_safely_assign = False
        owner_names = ", ".join(f"{o['asset_code']} ({o['ip_role_label']})" for o in cmdb_owners)
        recommendation = (
            f"La IP ya está asignada en la CMDB a [{owner_names}] y responde activamente en la red."
        )
    else:
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


def verify_single_ip_manual(
    db: Session,
    target_ip: str,
    ports: Optional[List[int]] = None,
    timeout_sec: float = 0.8,
) -> Dict[str, Any]:
    res = verify_ip_target_or_find_free(
        db=db,
        target_ip=target_ip,
        ports=ports,
        timeout_sec=timeout_sec,
        count_limit=1,
        only_suggest_free=False,
    )
    return res["results"][0]


def verify_ip_target_or_find_free(
    db: Session,
    target_ip: str = "",
    subnet_id: Optional[int] = None,
    ports: Optional[List[int]] = None,
    timeout_sec: float = 0.6,
    count_limit: int = 254,
    only_suggest_free: bool = False,
) -> Dict[str, Any]:
    """
    Soporta 4 modos de operación manual:
    1) Red CIDR completa (ej. '1.1.1.1/24', '10.20.20.0/24', '192.168.1.0/28'):
       Analiza en paralelo todas las IPs del rango CIDR (hasta 254 hosts), detectando qué máquinas responden
       en la red (estén o no en la CMDB) y qué IPs están libres, permitiendo añadir los hallazgos a la CMDB.
    2) Rango con guion (ej. '10.20.20.1-254' o '10.20.20.40-10.20.20.60'):
       Analiza todas las IPs del intervalo indicado.
    3) IP única o lista separada por comas (ej. '10.20.20.45' o '1.1.1.1, 1.1.1.2').
    4) Buscador inteligente por Subred ('only_suggest_free=True'): sugiere y verifica las siguientes IPs libres.
    """
    raw = (target_ip or "").strip()
    ips_to_test: List[str] = []
    scanned_cidr: Optional[str] = None
    eff_limit = max(1, min(count_limit or 254, 256))

    if raw and not only_suggest_free:
        if "/" in raw:
            # Soportar notación CIDR como '1.1.1.1/24' o '10.20.20.0/24' (strict=False convierte 1.1.1.1/24 en la red 1.1.1.0/24)
            try:
                net = ipaddress.ip_network(raw, strict=False)
            except ValueError as exc:
                raise ValueError(
                    f"El rango CIDR '{raw}' no es válido (ejemplo válido: 1.1.1.1/24 o 10.20.20.0/24): {exc}"
                )
            scanned_cidr = str(net)
            if net.num_addresses <= 2:
                ips_to_test = [str(ip) for ip in net][:eff_limit]
            else:
                for idx, host_ip in enumerate(net.hosts()):
                    if idx >= eff_limit:
                        break
                    ips_to_test.append(str(host_ip))
        elif "-" in raw:
            left, right = [x.strip() for x in raw.split("-", 1)]
            try:
                start_ip = ipaddress.ip_address(left)
                if "." in right:
                    end_ip = ipaddress.ip_address(right)
                else:
                    prefix = left.rsplit(".", 1)[0]
                    end_ip = ipaddress.ip_address(f"{prefix}.{int(right)}")
            except ValueError as exc:
                raise ValueError(f"El rango de IPs '{raw}' no tiene un formato válido: {exc}")
            curr = int(start_ip)
            end_val = int(end_ip)
            if end_val < curr:
                curr, end_val = end_val, curr
            max_span = min(end_val - curr + 1, eff_limit)
            for offset in range(max_span):
                ips_to_test.append(str(ipaddress.ip_address(curr + offset)))
        elif "," in raw:
            parts = [p.strip() for p in raw.split(",") if p.strip()]
            for p in parts[:eff_limit]:
                ipaddress.ip_address(p)
                ips_to_test.append(p)
        else:
            try:
                ipaddress.ip_address(raw)
            except ValueError:
                raise ValueError(
                    f"La IP o rango '{raw}' no es válido. Usa una IP (10.20.20.45), un CIDR (1.1.1.1/24) o un rango (10.20.20.1-50)."
                )
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
        scanned_cidr = str(net)
        used_ips = {
            row.ip_address.strip()
            for row in db.query(CmdbIpAddress).all()
            if row.ip_address
        }
        if subnet.gateway:
            used_ips.add(subnet.gateway.strip())

        suggest_cap = min(eff_limit, 12)
        candidates: List[str] = []
        for host_ip in net.hosts():
            ip_str = str(host_ip)
            last_octet = int(ip_str.rsplit(".", 1)[-1]) if "." in ip_str else 10
            if last_octet < 15 or last_octet >= 250:
                continue
            if ip_str not in used_ips:
                candidates.append(ip_str)
            if len(candidates) >= suggest_cap:
                break
        ips_to_test = candidates

    probe_ports = ports or [22, 80, 443, 3389, 445, 8006, 902, 161]
    is_bulk = len(ips_to_test) > 12

    # 1. Pre-cargar datos CMDB en el hilo principal (thread-safe)
    all_cmdb_records = (
        db.query(CmdbIpAddress)
        .options(joinedload(CmdbIpAddress.asset))
        .filter(CmdbIpAddress.ip_address.in_(ips_to_test))
        .all()
        if ips_to_test
        else []
    )
    records_by_ip: Dict[str, List[CmdbIpAddress]] = {}
    owners_by_ip: Dict[str, List[Dict[str, Any]]] = {}
    for rec in all_cmdb_records:
        records_by_ip.setdefault(rec.ip_address, []).append(rec)
        ast = rec.asset
        owners_by_ip.setdefault(rec.ip_address, []).append(
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

    subnets = db.query(CmdbSubnet).all()

    # 2. Ejecutar el sondeo de red en paralelo (alta velocidad para rangos /24)
    max_workers = min(48, max(1, len(ips_to_test)))
    probe_outputs_by_ip: Dict[str, Dict[str, Any]] = {}
    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        fut_map = {
            pool.submit(
                _probe_ip_network_only,
                ip_candidate,
                probe_ports,
                timeout_sec,
                is_bulk,
            ): ip_candidate
            for ip_candidate in ips_to_test
        }
        for fut, ip_key in fut_map.items():
            probe_outputs_by_ip[ip_key] = fut.result()

    # 3. Ensamblar resultados manteniendo el orden y actualizar registros CMDB existentes
    now_dt = datetime.utcnow()
    results: List[Dict[str, Any]] = []
    db_modified = False

    for ip_candidate in ips_to_test:
        pdata = probe_outputs_by_ip[ip_candidate]
        c_owners = owners_by_ip.get(ip_candidate, [])
        matched_sub = _match_subnet_for_ip(ip_candidate, subnets)
        assembled = _assemble_ip_verification_result(
            probe_data=pdata,
            cmdb_owners=c_owners,
            matched_sub=matched_sub,
            now_dt=now_dt,
        )
        results.append(assembled)

        if ip_candidate in records_by_ip:
            for rec in records_by_ip[ip_candidate]:
                rec.last_verification_status = assembled["verdict"]
                rec.last_verified_at = now_dt
                rec.last_verification_detail = assembled["summary"]
                db_modified = True

    if db_modified:
        db.commit()

    # Si es un escaneo masivo (> 1 IP), ordenar poniendo primero los equipos detectados en red y los registrados en CMDB
    if len(results) > 1 and not only_suggest_free:
        verdict_priority = {
            "conflict_unregistered": 0,  # Nuevos equipos encontrados en la red que NO están en la CMDB
            "active_in_network": 1,      # Equipos en la CMDB que responden en la red
            "no_response": 2,            # Equipos en la CMDB que no responden
            "free_confirmed": 3,         # IPs libres confirmadas
        }
        results.sort(
            key=lambda r: (
                verdict_priority.get(r["verdict"], 9),
                int(ipaddress.ip_address(r["ip_address"])),
            )
        )

    free_confirmed_list = [r["ip_address"] for r in results if r["verdict"] == "free_confirmed"]
    conflicts_list = [r["ip_address"] for r in results if r["verdict"] == "conflict_unregistered"]
    active_in_cmdb_list = [r["ip_address"] for r in results if r["verdict"] == "active_in_network"]
    no_response_list = [r["ip_address"] for r in results if r["verdict"] == "no_response"]

    cidr_already_in_cmdb = False
    if scanned_cidr:
        cidr_already_in_cmdb = any(s.cidr.strip() == scanned_cidr for s in subnets)

    return {
        "scanned_input": raw,
        "scanned_cidr": scanned_cidr,
        "cidr_already_in_cmdb": cidr_already_in_cmdb,
        "tested_count": len(results),
        "free_confirmed_count": len(free_confirmed_list),
        "conflict_count": len(conflicts_list),
        "active_in_cmdb_count": len(active_in_cmdb_list),
        "no_response_count": len(no_response_list),
        "suggested_free_ip": free_confirmed_list[0] if free_confirmed_list else None,
        "results": results,
    }


def import_discovered_hosts_to_cmdb(
    db: Session,
    register_subnet_cidr: Optional[str] = None,
    subnet_name: Optional[str] = None,
    vlan_id: Optional[int] = None,
    items: Optional[List[Dict[str, Any]]] = None,
) -> Dict[str, Any]:
    """
    Permite incorporar de una sola vez a la CMDB los equipos/IPs encontrados tras analizar un rango CIDR
    (ej. '1.1.1.1/24' o '10.20.20.0/24') que el administrador haya seleccionado, así como registrar
    opcionalmente la propia subred CIDR en el IPAM si aún no existía.
    """
    created_subnet = None
    if register_subnet_cidr and register_subnet_cidr.strip():
        net = ipaddress.ip_network(register_subnet_cidr.strip(), strict=False)
        cidr_norm = str(net)
        existing_sub = db.query(CmdbSubnet).filter(CmdbSubnet.cidr == cidr_norm).first()
        if not existing_sub:
            first_host = str(next(net.hosts(), net.network_address))
            existing_sub = CmdbSubnet(
                cidr=cidr_norm,
                name=(subnet_name or "").strip() or f"Subred Descubierta {cidr_norm}",
                vlan_id=vlan_id,
                gateway=first_host,
                subnet_mask=str(net.netmask),
                environment="production",
                notes="Subred añadida desde el Escáner/Verificador de Rangos IP de la CMDB.",
            )
            db.add(existing_sub)
            db.flush()
            created_subnet = cidr_norm

    subnets = db.query(CmdbSubnet).all()
    created_assets_count = 0
    for item in (items or []):
        ip_str = str(item.get("ip_address") or "").strip()
        if not ip_str:
            continue
        # Comprobar si ya existe la IP en la CMDB
        existing_ip = db.query(CmdbIpAddress).filter(CmdbIpAddress.ip_address == ip_str).first()
        if existing_ip:
            continue

        last_oct = ip_str.replace(".", "-")
        ptr_fqdn = str(item.get("fqdn") or "").strip()
        raw_host = str(item.get("hostname") or "").strip()
        if not raw_host and ptr_fqdn:
            raw_host = ptr_fqdn.split(".")[0]
        if not raw_host:
            raw_host = f"host-{last_oct}"

        base_code = f"DISC-{ip_str.split('.')[-2]}-{ip_str.split('.')[-1]}" if "." in ip_str else f"DISC-{last_oct}"
        code = base_code.upper()
        suffix = 1
        while db.query(CmdbAsset).filter(CmdbAsset.code == code).first():
            suffix += 1
            code = f"{base_code}-{suffix}".upper()

        open_ports = item.get("open_ports") or []
        asset_class = str(item.get("asset_class") or "other_machine")
        mon_method = "icmp"
        mon_port = 22
        if 22 in open_ports:
            mon_method, mon_port = "ssh", 22
        elif 443 in open_ports:
            mon_method, mon_port = "https", 443
        elif 80 in open_ports:
            mon_method, mon_port = "http", 80
        elif open_ports:
            mon_method, mon_port = "tcp", int(open_ports[0])

        matched_sub = _match_subnet_for_ip(ip_str, subnets)
        asset = CmdbAsset(
            code=code,
            name=ptr_fqdn or f"Equipo Detectado ({ip_str})",
            hostname=raw_host,
            fqdn=ptr_fqdn,
            asset_class=asset_class,
            environment=str(item.get("environment") or "production"),
            criticality="medium",
            lifecycle_status="active",
            os_or_firmware=f"Detectado en escaneo (Puertos: {open_ports})" if open_ports else "Detectado por Sondeo de Red",
            hypervisor_or_platform="Descubrimiento Manual CMDB",
            owner_team="Sistemas & Redes",
            responsible_person="Alex Geng",
            sync_source="cmdb",
            monitoring_enabled=True,
            monitor_method=mon_method,
            monitor_port=mon_port,
            status="online",
            last_checked_at=datetime.utcnow(),
            notes=str(item.get("notes") or f"Incorporado desde escaneo de rango ({ip_str})"),
        )
        db.add(asset)
        db.flush()

        db.add(
            CmdbIpAddress(
                asset_id=asset.id,
                subnet_id=matched_sub.id if matched_sub else None,
                ip_address=ip_str,
                subnet_mask=matched_sub.subnet_mask if matched_sub else "255.255.255.0",
                gateway=matched_sub.gateway if matched_sub else "",
                vlan_id=matched_sub.vlan_id if matched_sub else vlan_id,
                ip_role="mgmt_heartbeat",
                interface_name="eth0",
                mac_address=str(item.get("mac_address") or "").strip(),
                fqdn=ptr_fqdn,
                is_heartbeat_ip=True,
                allocation_status="assigned",
                last_verification_status="active_in_network",
                last_verified_at=datetime.utcnow(),
                last_verification_detail="Añadido tras verificación de rango IP en CMDB",
            )
        )
        created_assets_count += 1

    db.commit()
    overview = build_cmdb_overview(db)
    overview["imported_assets_count"] = created_assets_count
    overview["created_subnet"] = created_subnet
    return overview



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

    # Construir detalle de subredes y mapa de ocupación (respetando la máscara real /23, /24, /25, /26, etc.)
    all_ips = db.query(CmdbIpAddress).options(joinedload(CmdbIpAddress.asset)).all()
    serialized_subnets = []
    subnets_dirty = False
    for sub in subnets:
        raw_cidr = (sub.cidr or "").strip()
        if raw_cidr and "/" not in raw_cidr:
            raw_cidr = f"{raw_cidr}/24"
        try:
            net = ipaddress.ip_network(raw_cidr, strict=False)
            total_addresses = net.num_addresses
            total_usable = max(1, net.num_addresses - 2) if net.num_addresses > 2 else net.num_addresses
            canonical_cidr = str(net)
            real_mask = str(net.netmask)
            network_addr_str = str(net.network_address)
            broadcast_addr_str = str(net.broadcast_address) if net.num_addresses > 1 else ""
            first_usable_str = (
                str(ipaddress.ip_address(int(net.network_address) + 1))
                if net.num_addresses > 2
                else str(net.network_address)
            )
            last_usable_str = (
                str(ipaddress.ip_address(int(net.broadcast_address) - 1))
                if net.num_addresses > 2
                else str(net.broadcast_address)
            )
            prefix_len = net.prefixlen

            # Normalizar automáticamente si la subred tenía máscara por defecto errónea o CIDR sin alinear a dirección de red
            if sub.cidr != canonical_cidr:
                existing_same = (
                    db.query(CmdbSubnet)
                    .filter(CmdbSubnet.cidr == canonical_cidr, CmdbSubnet.id != sub.id)
                    .first()
                )
                if not existing_same:
                    sub.cidr = canonical_cidr
                    subnets_dirty = True
            if sub.subnet_mask != real_mask:
                sub.subnet_mask = real_mask
                subnets_dirty = True
            gw_val = (sub.gateway or "").strip()
            try:
                gw_ip = ipaddress.ip_address(gw_val) if gw_val else None
                if gw_ip is None or gw_ip not in net or (net.num_addresses > 2 and gw_ip in (net.network_address, net.broadcast_address)):
                    sub.gateway = first_usable_str
                    subnets_dirty = True
            except ValueError:
                sub.gateway = first_usable_str
                subnets_dirty = True

            # Generar todas las direcciones del bloque CIDR (incluyendo Dirección de Red y Broadcast) hasta 4096 IPs (/20)
            max_grid_ips = min(net.num_addresses, 4096)
            base_int = int(net.network_address)
            address_list = [str(ipaddress.ip_address(base_int + offset)) for offset in range(max_grid_ips)]
            sub_blocks_24: List[str] = []
            if net.prefixlen < 24 and net.num_addresses <= 4096:
                seen_b24 = set()
                for ip_s in address_list:
                    b24 = ip_s.rsplit(".", 1)[0]
                    if b24 not in seen_b24:
                        seen_b24.add(b24)
                        sub_blocks_24.append(b24)
        except ValueError:
            net = None
            total_addresses = 256
            total_usable = 254
            canonical_cidr = sub.cidr
            real_mask = sub.subnet_mask or "255.255.255.0"
            network_addr_str = ""
            broadcast_addr_str = ""
            first_usable_str = ""
            last_usable_str = ""
            prefix_len = 24
            address_list = []
            sub_blocks_24 = []

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
                "prefixlen": prefix_len,
                "name": sub.name,
                "vlan_id": sub.vlan_id,
                "gateway": sub.gateway,
                "subnet_mask": sub.subnet_mask,
                "network_address": network_addr_str,
                "broadcast_address": broadcast_addr_str,
                "first_usable_ip": first_usable_str,
                "last_usable_ip": last_usable_str,
                "total_addresses": total_addresses,
                "dns_servers": sub.dns_servers,
                "environment": sub.environment,
                "location_id": sub.location_id,
                "notes": sub.notes or "",
                "total_usable": total_usable,
                "occupied_count": occupied_count,
                "free_count": max(0, total_usable - occupied_count),
                "usage_percent": usage_pct,
                "allocated_ips": list(used_map.values()),
                "address_list": address_list,
                "sub_blocks_24": sub_blocks_24,
            }
        )

    if subnets_dirty:
        db.commit()

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
