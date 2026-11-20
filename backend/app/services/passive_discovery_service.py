"""
Fase 2 — Motor de Descubrimiento Pasivo 100% Solo-Lectura (`RackDoc Passive Discovery`).

Capacidades:
1. **Walk SNMP Solo-Lectura Nativo ASN.1/BER (`IF-MIB` + `LLDP-MIB`)**: recorre interfaces,
   estados admin/oper, velocidades, MACs, alias de bocas y vecinos LLDP por UDP (:161) usando
   únicamente `GetNextRequest` de lectura.
2. **Auditoría Pasiva SSH / WinRM (`linux_audit_ro.yml` / `windows_audit_ro.yml`)**: ejecuta
   inspección en memoria de sockets en escucha, conexiones TCP establecidas (mapa real de
   dependencias entre servidores), servicios activos y contenedores Docker/Podman sin escribir
   un solo fichero en las máquinas auditadas.
3. **Aplicación `Human-in-the-Loop`**: guarda todo en `ai_passive_discovery_snapshots` y solo
   vuelca bocas a `SwitchSnmpPort` o enlaces a `LogicalTopologyLink` cuando un `editor`/`admin`
   pulsa aprobar explícitamente.
"""

from __future__ import annotations

import asyncio
from concurrent.futures import ThreadPoolExecutor
import ipaddress
import json
import os
import secrets
import shutil
import socket
import stat
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from sqlalchemy.orm import Session, joinedload

from ..models import (
    AiPassiveDiscoverySnapshot,
    CmdbAsset,
    CmdbIpAddress,
    LogicalTopologyLink,
    ProvisioningCredential,
    SwitchSnmpPort,
)
from ..time_utils import utcnow
from .cmdb_service import _probe_ip_network_only
from .monitor import _encode_ber_length, _encode_oid
from .provisioning_service import (
    PLAYBOOKS_DIR,
    _resolve_credential_dict,
    _write_ansible_inventory,
    sanitize_target_host,
    serialize_credential,
)


# ==============================================================================
# 1. CÓDEC ASN.1 / BER SOLO-LECTURA PARA WALK SNMP (`IF-MIB` + `LLDP-MIB`)
# ==============================================================================

OID_SYS_DESCR = "1.3.6.1.2.1.1.1"
OID_SYS_NAME = "1.3.6.1.2.1.1.5"

# IF-MIB
OID_IF_DESCR = "1.3.6.1.2.1.2.2.1.2"
OID_IF_SPEED = "1.3.6.1.2.1.2.2.1.5"
OID_IF_PHYS_ADDR = "1.3.6.1.2.1.2.2.1.6"
OID_IF_ADMIN_STATUS = "1.3.6.1.2.1.2.2.1.7"
OID_IF_OPER_STATUS = "1.3.6.1.2.1.2.2.1.8"
OID_IF_NAME = "1.3.6.1.2.1.31.1.1.1.1"
OID_IF_HIGH_SPEED = "1.3.6.1.2.1.31.1.1.1.15"
OID_IF_ALIAS = "1.3.6.1.2.1.31.1.1.1.18"

# LLDP-MIB
OID_LLDP_LOC_PORT_ID = "1.0.8802.1.1.2.1.3.7.1.3"
OID_LLDP_REM_PORT_ID = "1.0.8802.1.1.2.1.4.1.1.7"
OID_LLDP_REM_SYS_NAME = "1.0.8802.1.1.2.1.4.1.1.9"
OID_LLDP_REM_MAN_ADDR = "1.0.8802.1.1.2.1.4.2.1.4"


def build_snmp_getnext_packet(
    community: str,
    oid_str: str,
    version_str: str = "v2c",
    request_id: int = 0x23456789,
) -> bytes:
    """Construye un datagrama UDP `GetNextRequest-PDU (0xA1)` estrictamente de lectura."""
    ver_num = 0 if version_str.lower() == "v1" else 1
    oid_tlv = _encode_oid(oid_str)
    null_tlv = b"\x05\x00"
    varbind = b"\x30" + _encode_ber_length(len(oid_tlv) + len(null_tlv)) + oid_tlv + null_tlv
    varbind_list = b"\x30" + _encode_ber_length(len(varbind)) + varbind

    req_bytes = int(request_id & 0x7FFFFFFF).to_bytes(4, byteorder="big", signed=False)
    req_tlv = b"\x02\x04" + req_bytes
    err_stat = b"\x02\x01\x00"
    err_idx = b"\x02\x01\x00"
    pdu_body = req_tlv + err_stat + err_idx + varbind_list
    pdu = b"\xa1" + _encode_ber_length(len(pdu_body)) + pdu_body  # 0xA1 = GetNextRequest

    ver_tlv = bytes([0x02, 0x01, ver_num])
    comm_bytes = (community or "public").encode("utf-8")
    comm_tlv = bytes([0x04]) + _encode_ber_length(len(comm_bytes)) + comm_bytes

    msg_body = ver_tlv + comm_tlv + pdu
    return b"\x30" + _encode_ber_length(len(msg_body)) + msg_body


def _read_ber_tlv(buf: bytes, offset: int) -> Tuple[int, bytes, int]:
    """Lee un elemento `(tag, value_bytes, next_offset)` de un buffer ASN.1 BER."""
    if offset >= len(buf):
        raise ValueError("Buffer BER truncado al leer tag.")
    tag = buf[offset]
    offset += 1
    if offset >= len(buf):
        raise ValueError("Buffer BER truncado al leer longitud.")
    first_len = buf[offset]
    offset += 1
    if first_len < 0x80:
        length = first_len
    else:
        num_octets = first_len & 0x7F
        if num_octets == 0 or offset + num_octets > len(buf):
            raise ValueError("Longitud BER inválida o truncada.")
        length = int.from_bytes(buf[offset : offset + num_octets], byteorder="big")
        offset += num_octets
    end = offset + length
    if end > len(buf):
        raise ValueError("Valor BER excede el tamaño del datagrama.")
    return tag, buf[offset:end], end


def decode_ber_oid(oid_bytes: bytes) -> str:
    """Decodifica bytes de un OID ASN.1 BER a notación punteada (`1.3.6.1...`)."""
    if not oid_bytes:
        return ""
    first = oid_bytes[0]
    first_arc = min(2, first // 40)
    second_arc = first - (first_arc * 40)
    arcs = [str(first_arc), str(second_arc)]
    val = 0
    for b in oid_bytes[1:]:
        val = (val << 7) | (b & 0x7F)
        if not (b & 0x80):
            arcs.append(str(val))
            val = 0
    return ".".join(arcs)


def _decode_ber_scalar(tag: int, val: bytes) -> Tuple[str, Any]:
    """Convierte el valor de un VarBind SNMP a tipo Python limpio."""
    # Excepciones SNMPv2c de fin de vista / instancia inexistente
    if tag in (0x80, 0x81, 0x82):
        return ("end", None)
    # INTEGER, Counter32, Gauge32, TimeTicks, Counter64
    if tag in (0x02, 0x41, 0x42, 0x43, 0x46):
        signed = tag == 0x02
        return ("int", int.from_bytes(val, byteorder="big", signed=signed) if val else 0)
    # IpAddress (4 bytes)
    if tag == 0x40 and len(val) == 4:
        return ("ip", ".".join(str(b) for b in val))
    # OBJECT IDENTIFIER
    if tag == 0x06:
        return ("oid", decode_ber_oid(val))
    # OCTET STRING
    if tag == 0x04:
        if not val:
            return ("str", "")
        # Si son exactamente 6 octetos y contiene bytes no imprimibles, es una dirección MAC binaria
        if len(val) == 6 and any(b < 32 or b > 126 for b in val):
            return ("mac", ":".join(f"{b:02X}" for b in val))
        return ("str", val.decode("utf-8", errors="replace").strip("\x00").strip())
    return ("raw", val.hex())


def parse_snmp_response_first_varbind(packet: bytes) -> Tuple[str, str, Any]:
    """
    Parsea un datagrama `GetResponse-PDU (0xA2)` y devuelve `(oid_str, value_kind, value)`.
    """
    seq_tag, seq_body, _ = _read_ber_tlv(packet, 0)
    if seq_tag != 0x30:
        raise ValueError("El datagrama SNMP no comienza con SEQUENCE (0x30).")
    _, _ver_val, off = _read_ber_tlv(seq_body, 0)
    _, _comm_val, off = _read_ber_tlv(seq_body, off)
    pdu_tag, pdu_body, _ = _read_ber_tlv(seq_body, off)
    if pdu_tag != 0xA2:
        raise ValueError(f"PDU inesperado en respuesta SNMP: 0x{pdu_tag:02X}")

    _, _req_id, p_off = _read_ber_tlv(pdu_body, 0)
    _, err_stat_bytes, p_off = _read_ber_tlv(pdu_body, p_off)
    _, _err_idx, p_off = _read_ber_tlv(pdu_body, p_off)

    err_code = int.from_bytes(err_stat_bytes, byteorder="big", signed=True) if err_stat_bytes else 0
    if err_code == 2:
        # noSuchName en SNMPv1 equivale al final del árbol
        return ("", "end", None)
    if err_code != 0:
        raise ValueError(f"Agente SNMP devolvió error_status={err_code}")

    vbl_tag, vbl_body, _ = _read_ber_tlv(pdu_body, p_off)
    if vbl_tag != 0x30 or not vbl_body:
        return ("", "end", None)

    vb_tag, vb_body, _ = _read_ber_tlv(vbl_body, 0)
    if vb_tag != 0x30:
        return ("", "end", None)

    oid_tag, oid_raw, vb_off = _read_ber_tlv(vb_body, 0)
    if oid_tag != 0x06:
        raise ValueError("VarBind sin OID válido.")
    val_tag, val_raw, _ = _read_ber_tlv(vb_body, vb_off)
    oid_str = decode_ber_oid(oid_raw)
    kind, decoded_val = _decode_ber_scalar(val_tag, val_raw)
    return oid_str, kind, decoded_val


def snmp_walk_subtree(
    target_host: str,
    port: int,
    community: str,
    root_oid: str,
    version_str: str = "v2c",
    timeout_sec: float = 2.0,
    max_rows: int = 128,
) -> List[Tuple[str, Any]]:
    """
    Recorre en modo 100% Solo-Lectura (`GetNextRequest`) todas las entradas bajo `root_oid`.
    Devuelve lista de `(suffix_after_root, value)`.
    """
    clean_root = root_oid.strip(".")
    prefix_dot = clean_root + "."
    current_oid = clean_root
    results: List[Tuple[str, Any]] = []

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(max(0.4, min(float(timeout_sec or 2.0), 6.0)))
    try:
        for step in range(max(1, min(int(max_rows or 128), 512))):
            pkt = build_snmp_getnext_packet(
                community=community,
                oid_str=current_oid,
                version_str=version_str,
                request_id=0x10000 + step,
            )
            sock.sendto(pkt, (target_host, int(port)))
            resp_bytes, _ = sock.recvfrom(4096)
            next_oid, kind, val = parse_snmp_response_first_varbind(resp_bytes)
            if kind == "end" or not next_oid or next_oid == current_oid:
                break
            if next_oid == clean_root:
                results.append(("0", val))
                current_oid = next_oid
                continue
            if not next_oid.startswith(prefix_dot):
                break
            suffix = next_oid[len(prefix_dot) :]
            results.append((suffix, val))
            current_oid = next_oid
    finally:
        sock.close()

    return results


# ==============================================================================
# 2. RESOLUCIÓN DE DEPENDENCIAS CONTRA LA CMDB
# ==============================================================================


def _build_cmdb_lookup_maps(db: Session) -> Tuple[Dict[str, CmdbAsset], Dict[str, CmdbAsset]]:
    """Devuelve `(asset_by_ip, asset_by_name_lower)` para correlacionar peers e hilos LLDP."""
    assets = (
        db.query(CmdbAsset)
        .options(joinedload(CmdbAsset.ip_addresses))
        .filter(CmdbAsset.lifecycle_status != "decommissioned")
        .all()
    )
    by_ip: Dict[str, CmdbAsset] = {}
    by_name: Dict[str, CmdbAsset] = {}
    for a in assets:
        for ip_row in a.ip_addresses:
            if ip_row.ip_address:
                by_ip[ip_row.ip_address.strip()] = a
        for candidate in (a.hostname, a.fqdn, a.code, a.name):
            c_clean = (candidate or "").strip().lower()
            if c_clean:
                by_name[c_clean] = a
                if "." in c_clean:
                    by_name.setdefault(c_clean.split(".")[0], a)
    return by_ip, by_name


def _classify_port_dependency(port: int) -> Tuple[str, str]:
    db_ports = {
        5432: "PostgreSQL :5432",
        3306: "MySQL/MariaDB :3306",
        1433: "SQL Server :1433",
        6379: "Redis :6379",
        27017: "MongoDB :27017",
        1521: "Oracle :1521",
    }
    if port in db_ports:
        return "app_to_db", db_ports[port]
    web_ports = {
        80: "HTTP :80",
        443: "HTTPS :443",
        8080: "HTTP Upstream :8080",
        8443: "HTTPS Upstream :8443",
        8000: "API Backend :8000",
        3000: "App Upstream :3000",
        9000: "FastCGI/App :9000",
    }
    if port in web_ports:
        return "reverse_proxy_upstream", web_ports[port]
    if port in (2049, 3260, 445):
        return "storage_san_nfs", f"Storage :{port}"
    return "custom_logical", f"TCP :{port}"


# ==============================================================================
# 3. EJECUTOR WALK SNMP `IF-MIB` + `LLDP-MIB` SOLO-LECTURA
# ==============================================================================


def run_passive_snmp_walk_discovery(
    db: Session,
    target_host: str,
    port: int = 161,
    community: str = "public",
    version: str = "v2c",
    timeout_sec: float = 2.0,
    max_oids_per_table: int = 128,
    collected_by: str = "operator",
) -> Dict[str, Any]:
    """
    Interroga en modo 100% Solo-Lectura un Switch/Router por SNMP (`IF-MIB` + `LLDP-MIB`),
    correlaciona vecinos LLDP con activos de la CMDB y guarda la instantánea en
    `ai_passive_discovery_snapshots` sin alterar tablas operativas.
    """
    clean_target = sanitize_target_host(target_host)
    run_code = f"RO-SNMP-{secrets.token_hex(3).upper()}"
    by_ip, by_name = _build_cmdb_lookup_maps(db)
    matched_asset = by_ip.get(clean_target) or by_name.get(clean_target.lower())

    try:
        sys_descr_rows = snmp_walk_subtree(clean_target, port, community, OID_SYS_DESCR, version, timeout_sec, 4)
        sys_name_rows = snmp_walk_subtree(clean_target, port, community, OID_SYS_NAME, version, timeout_sec, 4)
        sys_descr = str(sys_descr_rows[0][1]) if sys_descr_rows else ""
        sys_name = str(sys_name_rows[0][1]) if sys_name_rows else clean_target

        if not matched_asset and sys_name:
            matched_asset = by_name.get(sys_name.lower()) or by_name.get(sys_name.lower().split(".")[0])

        if_descr_map = {k: str(v) for k, v in snmp_walk_subtree(clean_target, port, community, OID_IF_DESCR, version, timeout_sec, max_oids_per_table)}
        if_name_map = {k: str(v) for k, v in snmp_walk_subtree(clean_target, port, community, OID_IF_NAME, version, timeout_sec, max_oids_per_table)}
        if_alias_map = {k: str(v) for k, v in snmp_walk_subtree(clean_target, port, community, OID_IF_ALIAS, version, timeout_sec, max_oids_per_table)}
        if_admin_map = {k: int(v) for k, v in snmp_walk_subtree(clean_target, port, community, OID_IF_ADMIN_STATUS, version, timeout_sec, max_oids_per_table) if isinstance(v, int)}
        if_oper_map = {k: int(v) for k, v in snmp_walk_subtree(clean_target, port, community, OID_IF_OPER_STATUS, version, timeout_sec, max_oids_per_table) if isinstance(v, int)}
        if_hspeed_map = {k: int(v) for k, v in snmp_walk_subtree(clean_target, port, community, OID_IF_HIGH_SPEED, version, timeout_sec, max_oids_per_table) if isinstance(v, int)}
        if_speed_map = {k: int(v) for k, v in snmp_walk_subtree(clean_target, port, community, OID_IF_SPEED, version, timeout_sec, max_oids_per_table) if isinstance(v, int)}
        if_mac_map = {k: str(v) for k, v in snmp_walk_subtree(clean_target, port, community, OID_IF_PHYS_ADDR, version, timeout_sec, max_oids_per_table)}

        # Tablas opcionales LLDP-MIB (si el switch tiene `lldp run` habilitado)
        lldp_loc_port_map = {
            k: str(v)
            for k, v in snmp_walk_subtree(clean_target, port, community, OID_LLDP_LOC_PORT_ID, version, timeout_sec, max_oids_per_table)
        }
        lldp_rem_sys = snmp_walk_subtree(clean_target, port, community, OID_LLDP_REM_SYS_NAME, version, timeout_sec, max_oids_per_table)
        lldp_rem_port = {
            k: str(v)
            for k, v in snmp_walk_subtree(clean_target, port, community, OID_LLDP_REM_PORT_ID, version, timeout_sec, max_oids_per_table)
        }
        lldp_rem_man = snmp_walk_subtree(clean_target, port, community, OID_LLDP_REM_MAN_ADDR, version, timeout_sec, max_oids_per_table)

        # Extraer IP de gestión remota LLDP desde sufijo `<timeMark>.<localPortNum>.<remIdx>.1.4.A.B.C.D`
        rem_ip_by_local_port: Dict[str, str] = {}
        for suffix, _val in lldp_rem_man:
            parts = suffix.split(".")
            if len(parts) >= 9 and parts[3] == "1" and parts[4] == "4":
                local_pnum = parts[1]
                rem_ip_by_local_port[local_pnum] = ".".join(parts[5:9])

        neighbor_by_local_port: Dict[str, Dict[str, Any]] = {}
        for suffix, rem_name_val in lldp_rem_sys:
            parts = suffix.split(".")
            local_pnum = parts[1] if len(parts) >= 2 else suffix
            rem_sysname = str(rem_name_val or "").strip()
            rem_port_id = lldp_rem_port.get(suffix, "")
            rem_ip = rem_ip_by_local_port.get(local_pnum, "")
            neighbor_asset = (
                (by_ip.get(rem_ip) if rem_ip else None)
                or by_name.get(rem_sysname.lower())
                or by_name.get(rem_sysname.lower().split(".")[0])
            )
            neighbor_by_local_port[local_pnum] = {
                "local_port_ref": lldp_loc_port_map.get(local_pnum, local_pnum),
                "neighbor_sysname": rem_sysname,
                "neighbor_port": rem_port_id,
                "neighbor_ip": rem_ip,
                "neighbor_asset_id": neighbor_asset.id if neighbor_asset else None,
                "neighbor_asset_code": neighbor_asset.code if neighbor_asset else "",
            }

        all_if_keys = sorted(
            set(if_descr_map.keys()) | set(if_name_map.keys()),
            key=lambda x: int(x) if x.isdigit() else 999999,
        )
        interfaces_list: List[Dict[str, Any]] = []
        inferred_deps: List[Dict[str, Any]] = []

        for if_key in all_if_keys:
            if_idx = int(if_key) if if_key.isdigit() else 0
            if_name = if_name_map.get(if_key) or if_descr_map.get(if_key) or f"if{if_key}"
            admin_num = if_admin_map.get(if_key, 1)
            oper_num = if_oper_map.get(if_key, 2)
            speed_mbps = if_hspeed_map.get(if_key) or (if_speed_map.get(if_key, 0) // 1_000_000) or 1000

            # Emparejar vecino LLDP por ifIndex directo o por coincidencia de `lldpLocPortId == if_name`
            nb = neighbor_by_local_port.get(if_key)
            if not nb:
                for _lp, cand_nb in neighbor_by_local_port.items():
                    if cand_nb["local_port_ref"] and cand_nb["local_port_ref"].lower() == if_name.lower():
                        nb = cand_nb
                        break

            iface_entry = {
                "if_index": if_idx,
                "if_name": if_name,
                "if_alias": if_alias_map.get(if_key, ""),
                "admin_status": "up" if admin_num == 1 else "down",
                "oper_status": "up" if oper_num == 1 else ("dormant" if oper_num == 5 else "down"),
                "speed_mbps": int(speed_mbps),
                "mac_address": if_mac_map.get(if_key, ""),
                "lldp_neighbor_sysname": nb["neighbor_sysname"] if nb else "",
                "lldp_neighbor_port": nb["neighbor_port"] if nb else "",
                "lldp_neighbor_ip": nb["neighbor_ip"] if nb else "",
                "lldp_neighbor_asset_id": nb["neighbor_asset_id"] if nb else None,
                "lldp_neighbor_asset_code": nb["neighbor_asset_code"] if nb else "",
            }
            interfaces_list.append(iface_entry)

            if nb and (nb["neighbor_sysname"] or nb["neighbor_ip"]):
                inferred_deps.append(
                    {
                        "link_type": "lldp_trunk",
                        "source_asset_id": matched_asset.id if matched_asset else None,
                        "source_code": matched_asset.code if matched_asset else sys_name,
                        "source_interface": if_name,
                        "target_asset_id": nb["neighbor_asset_id"],
                        "target_code": nb["neighbor_asset_code"] or nb["neighbor_sysname"],
                        "target_interface": nb["neighbor_port"],
                        "protocol_label": f"LLDP {speed_mbps}Mbps ({if_name} -> {nb['neighbor_port'] or 'peer'})",
                    }
                )

        snap = AiPassiveDiscoverySnapshot(
            run_code=run_code,
            collector_type="snmp_if_lldp_ro",
            target_host=clean_target,
            asset_id=matched_asset.id if matched_asset else None,
            status="completed",
            hostname_detected=sys_name[:180],
            os_or_sysdescr=sys_descr[:255],
            snmp_interfaces=interfaces_list,
            inferred_dependencies=inferred_deps,
            collected_by=collected_by,
        )
        db.add(snap)
        db.commit()
        db.refresh(snap)
        return serialize_passive_snapshot(snap)

    except Exception as exc:
        snap_err = AiPassiveDiscoverySnapshot(
            run_code=run_code,
            collector_type="snmp_if_lldp_ro",
            target_host=clean_target,
            asset_id=matched_asset.id if matched_asset else None,
            status="failed",
            error_detail=str(exc),
            collected_by=collected_by,
        )
        db.add(snap_err)
        db.commit()
        db.refresh(snap_err)
        raise RuntimeError(f"Walk SNMP Solo-Lectura falló en {clean_target}:{port}: {exc}") from exc


# ==============================================================================
# 4. EJECUTOR AUDITORÍA PASIVA SSH / WINRM SOLO-LECTURA
# ==============================================================================


async def run_passive_host_audit_async(
    db: Session,
    os_family: str,
    targets: List[str],
    credential_id: Optional[int],
    ephemeral_credential: Optional[Dict[str, Any]],
    collected_by: str = "operator",
) -> List[Dict[str, Any]]:
    """
    Ejecuta `linux_audit_ro.yml` o `windows_audit_ro.yml` sobre los hosts indicados
    en estricto modo lectura (cero escritura en disco remoto) y persiste las
    instantáneas en `ai_passive_discovery_snapshots`.
    """
    clean_os = (os_family or "linux").strip().lower()
    if clean_os not in ("linux", "windows"):
        raise ValueError("os_family debe ser 'linux' o 'windows'.")

    cleaned_targets = [sanitize_target_host(t) for t in targets if (t or "").strip()]
    if not cleaned_targets:
        raise ValueError("Indica al menos una IP o hostname objetivo.")

    cred_data, _mode = _resolve_credential_dict(
        db=db,
        credential_id=credential_id,
        ephemeral=ephemeral_credential,
        os_family=clean_os,
    )

    ansible_bin = shutil.which("ansible-playbook")
    if not ansible_bin:
        venv_candidate = Path(__file__).resolve().parents[2] / ".venv" / "bin" / "ansible-playbook"
        if venv_candidate.exists():
            ansible_bin = str(venv_candidate)
    if not ansible_bin:
        raise RuntimeError("'ansible-playbook' no está disponible en el contenedor backend.")

    playbook_file = (
        PLAYBOOKS_DIR / "windows_audit_ro.yml"
        if clean_os == "windows"
        else PLAYBOOKS_DIR / "linux_audit_ro.yml"
    )

    work_dir = Path(tempfile.mkdtemp(prefix="rackdoc_ro_audit_"))
    os.chmod(work_dir, stat.S_IRWXU)
    results_dir = work_dir / "results"
    results_dir.mkdir(mode=0o700, parents=True, exist_ok=True)

    run_code = f"RO-{clean_os.upper()[:3]}-{secrets.token_hex(3).upper()}"
    collector_type = "winrm_windows_ro" if clean_os == "windows" else "ssh_linux_ro"

    try:
        inv_path, secret_extra_vars = _write_ansible_inventory(
            work_dir=work_dir,
            targets=cleaned_targets,
            os_family=clean_os,
            cred_data=cred_data,
        )
        extra_vars_path = work_dir / "extra_vars.json"
        extra_vars_path.write_text(
            json.dumps({**secret_extra_vars, "rackdoc_results_dir": str(results_dir)}),
            encoding="utf-8",
        )
        os.chmod(extra_vars_path, stat.S_IRUSR | stat.S_IWUSR)

        env = os.environ.copy()
        env["ANSIBLE_HOST_KEY_CHECKING"] = "False"
        env["ANSIBLE_NOCOLOR"] = "1"

        proc = await asyncio.create_subprocess_exec(
            ansible_bin,
            "-i",
            str(inv_path),
            str(playbook_file),
            "--extra-vars",
            f"@{extra_vars_path}",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            env=env,
            cwd=str(work_dir),
        )
        stdout_bytes, _ = await asyncio.wait_for(proc.communicate(), timeout=120.0)
        ansible_output = stdout_bytes.decode("utf-8", errors="replace")

        by_ip, by_name = _build_cmdb_lookup_maps(db)
        created_snapshots: List[Dict[str, Any]] = []

        for target in cleaned_targets:
            matched_asset = by_ip.get(target) or by_name.get(target.lower())
            res_file = results_dir / f"{target}.json"
            if res_file.exists():
                raw = json.loads(res_file.read_text(encoding="utf-8"))
                probe = raw.get("probe") or {}
                hname = str(raw.get("hostname") or target).strip()
                if not matched_asset and hname:
                    matched_asset = by_name.get(hname.lower())

                peers_enriched = []
                inferred_deps = []
                for p in (probe.get("peer_connections") or []):
                    rem_ip = str(p.get("remote_ip") or "").strip()
                    rem_port = int(p.get("remote_port") or 0)
                    peer_asset = by_ip.get(rem_ip)
                    link_type, proto_lbl = _classify_port_dependency(rem_port)
                    peers_enriched.append(
                        {
                            "remote_ip": rem_ip,
                            "remote_port": rem_port,
                            "process": p.get("process") or "",
                            "resolved_asset_id": peer_asset.id if peer_asset else None,
                            "resolved_asset_code": peer_asset.code if peer_asset else "",
                        }
                    )
                    if peer_asset and (not matched_asset or peer_asset.id != matched_asset.id):
                        inferred_deps.append(
                            {
                                "link_type": link_type,
                                "source_asset_id": matched_asset.id if matched_asset else None,
                                "source_code": matched_asset.code if matched_asset else hname,
                                "source_interface": "",
                                "target_asset_id": peer_asset.id,
                                "target_code": peer_asset.code,
                                "target_interface": "",
                                "protocol_label": proto_lbl,
                            }
                        )

                snap = AiPassiveDiscoverySnapshot(
                    run_code=run_code,
                    collector_type=collector_type,
                    target_host=target,
                    asset_id=matched_asset.id if matched_asset else None,
                    status="completed",
                    hostname_detected=hname[:180],
                    os_or_sysdescr=str(raw.get("os_or_sysdescr") or "")[:255],
                    listening_ports=probe.get("listening_ports") or [],
                    peer_connections=peers_enriched,
                    running_services=probe.get("running_services") or [],
                    containers=probe.get("containers") or [],
                    web_vhosts_or_dbs=probe.get("web_vhosts_or_dbs") or [],
                    inferred_dependencies=inferred_deps,
                    collected_by=collected_by,
                )
            else:
                snap = AiPassiveDiscoverySnapshot(
                    run_code=run_code,
                    collector_type=collector_type,
                    target_host=target,
                    asset_id=matched_asset.id if matched_asset else None,
                    status="failed",
                    error_detail=ansible_output[-1500:],
                    collected_by=collected_by,
                )

            db.add(snap)
            db.commit()
            db.refresh(snap)
            created_snapshots.append(serialize_passive_snapshot(snap))

        return created_snapshots
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)


# ==============================================================================
# 5. APROBACIÓN HUMAN-IN-THE-LOOP: VOLCAR BOCAS SNMP Y ENLACES LÓGICOS A CMDB
# ==============================================================================


def apply_passive_snapshot_to_topology(
    db: Session,
    snapshot_id: int,
    applied_by: str = "editor",
) -> Dict[str, Any]:
    """
    Aplica bajo aprobación humana (`editor`/`admin`) los hallazgos de una instantánea
    pasiva sobre las tablas reales `SwitchSnmpPort` y `LogicalTopologyLink`.
    """
    snap = (
        db.query(AiPassiveDiscoverySnapshot)
        .options(joinedload(AiPassiveDiscoverySnapshot.asset))
        .filter(AiPassiveDiscoverySnapshot.id == snapshot_id)
        .first()
    )
    if not snap:
        raise ValueError("Instantánea de descubrimiento pasivo no encontrada.")
    if snap.status != "completed":
        raise ValueError("Solo se pueden aplicar instantáneas completadas con éxito.")

    ports_upserted = 0
    links_created = 0

    # 1. Si proviene de Walk SNMP y el switch está identificado en CMDB, sincronizar `SwitchSnmpPort`
    if snap.collector_type == "snmp_if_lldp_ro" and snap.asset_id and snap.snmp_interfaces:
        asset_obj = snap.asset
        rack_dev_id = asset_obj.rack_device_id if asset_obj else None
        existing_ports = {
            p.if_name: p
            for p in db.query(SwitchSnmpPort).filter(SwitchSnmpPort.asset_id == snap.asset_id).all()
        }
        for iface in snap.snmp_interfaces:
            if_name = str(iface.get("if_name") or "").strip()
            if not if_name:
                continue
            row = existing_ports.get(if_name)
            if not row:
                row = SwitchSnmpPort(
                    asset_id=snap.asset_id,
                    rack_device_id=rack_dev_id,
                    if_name=if_name,
                )
                db.add(row)
            row.if_index = int(iface.get("if_index") or 1)
            row.if_alias = str(iface.get("if_alias") or "")[:160]
            row.admin_status = str(iface.get("admin_status") or "up")[:16]
            row.oper_status = str(iface.get("oper_status") or "up")[:16]
            row.speed_mbps = int(iface.get("speed_mbps") or 1000)
            row.mac_address = str(iface.get("mac_address") or "")[:64]
            row.lldp_neighbor_sysname = str(iface.get("lldp_neighbor_sysname") or "")[:140]
            row.lldp_neighbor_port = str(iface.get("lldp_neighbor_port") or "")[:64]
            row.lldp_neighbor_ip = str(iface.get("lldp_neighbor_ip") or "")[:64]
            row.lldp_neighbor_asset_id = iface.get("lldp_neighbor_asset_id")
            row.last_polled_at = utcnow()
            ports_upserted += 1

    # 2. Sincronizar enlaces lógicos deducidos cuando ambos extremos existen en CMDB
    existing_links = {
        (lk.source_asset_id, lk.target_asset_id, lk.protocol_label)
        for lk in db.query(LogicalTopologyLink).all()
    }
    for dep in (snap.inferred_dependencies or []):
        src_id = dep.get("source_asset_id") or snap.asset_id
        tgt_id = dep.get("target_asset_id")
        proto = str(dep.get("protocol_label") or "TCP/IP")[:80]
        if not src_id or not tgt_id or int(src_id) == int(tgt_id):
            continue
        key = (int(src_id), int(tgt_id), proto)
        if key in existing_links:
            continue
        db.add(
            LogicalTopologyLink(
                source_asset_id=int(src_id),
                target_asset_id=int(tgt_id),
                link_type=str(dep.get("link_type") or "custom_logical")[:48],
                source_interface=str(dep.get("source_interface") or "")[:64],
                target_interface=str(dep.get("target_interface") or "")[:64],
                protocol_label=proto,
                status="UP",
                auto_discovered=True,
                notes=f"Descubierto pasivamente en modo RO ({snap.run_code})",
            )
        )
        existing_links.add(key)
        links_created += 1

    snap.topology_applied = True
    snap.applied_by = applied_by
    snap.applied_at = utcnow()
    db.commit()
    db.refresh(snap)

    return {
        "snapshot": serialize_passive_snapshot(snap),
        "snmp_ports_upserted": ports_upserted,
        "logical_links_created": links_created,
    }


def serialize_passive_snapshot(snap: AiPassiveDiscoverySnapshot) -> Dict[str, Any]:
    return {
        "id": snap.id,
        "run_code": snap.run_code,
        "collector_type": snap.collector_type,
        "target_host": snap.target_host,
        "asset_id": snap.asset_id,
        "asset_code": snap.asset.code if snap.asset else "",
        "asset_name": snap.asset.name if snap.asset else "",
        "status": snap.status,
        "hostname_detected": snap.hostname_detected or "",
        "os_or_sysdescr": snap.os_or_sysdescr or "",
        "listening_ports": snap.listening_ports or [],
        "peer_connections": snap.peer_connections or [],
        "running_services": snap.running_services or [],
        "containers": snap.containers or [],
        "web_vhosts_or_dbs": snap.web_vhosts_or_dbs or [],
        "snmp_interfaces": snap.snmp_interfaces or [],
        "inferred_dependencies": snap.inferred_dependencies or [],
        "topology_applied": bool(snap.topology_applied),
        "applied_by": snap.applied_by or "",
        "applied_at": snap.applied_at.isoformat() if snap.applied_at else None,
        "error_detail": snap.error_detail or "",
        "collected_by": snap.collected_by or "",
        "collected_at": snap.collected_at.isoformat() if snap.collected_at else None,
    }


def list_passive_discovery_snapshots(db: Session, limit: int = 50) -> Dict[str, Any]:
    snaps = (
        db.query(AiPassiveDiscoverySnapshot)
        .options(joinedload(AiPassiveDiscoverySnapshot.asset))
        .order_by(AiPassiveDiscoverySnapshot.id.desc())
        .limit(limit)
        .all()
    )
    creds = (
        db.query(ProvisioningCredential)
        .order_by(ProvisioningCredential.name.asc())
        .all()
    )
    return {
        "snapshots": [serialize_passive_snapshot(s) for s in snaps],
        "vault_credentials": [serialize_credential(c) for c in creds],
    }


def run_passive_network_fingerprint_scan(
    db: Session,
    target_range: str,
    timeout_sec: float = 0.6,
    count_limit: int = 254,
    collected_by: str = "operator",
) -> List[Dict[str, Any]]:
    """
    Ejecuta un barrido 100% Solo-Lectura sobre una IP, rango o red CIDR sin escribir en `cmdb_assets`
    ni en `cmdb_ip_addresses`. Por cada máquina activa detectada, genera una instantánea
    `AiPassiveDiscoverySnapshot` (`collector_type='network_fingerprint_ro'`) con Sistema Operativo,
    firma de Pila TCP/IP (`TTL`, `MSS`, `WScale`, `TS/SACK`), OUI MAC y banners L7.
    """
    raw = (target_range or "").strip()
    if not raw:
        raise ValueError("Debes indicar una IP, rango (ej. 10.20.20.1-50) o red CIDR (ej. 10.20.20.0/24).")

    eff_limit = max(1, min(count_limit or 254, 256))
    ips_to_test: List[str] = []

    if "/" in raw:
        try:
            net = ipaddress.ip_network(raw, strict=False)
        except ValueError as exc:
            raise ValueError(f"El bloque CIDR '{raw}' no es válido: {exc}")
        if net.num_addresses <= 2:
            ips_to_test = [str(ip) for ip in net][:eff_limit]
        else:
            for idx, h_ip in enumerate(net.hosts()):
                if idx >= eff_limit:
                    break
                ips_to_test.append(str(h_ip))
    elif "-" in raw:
        left, right = [x.strip() for x in raw.split("-", 1)]
        try:
            s_ip = ipaddress.ip_address(left)
            if "." in right:
                e_ip = ipaddress.ip_address(right)
            else:
                prefix = left.rsplit(".", 1)[0]
                e_ip = ipaddress.ip_address(f"{prefix}.{int(right)}")
        except ValueError as exc:
            raise ValueError(f"El rango de IPs '{raw}' no es válido: {exc}")
        curr, end_v = int(s_ip), int(e_ip)
        if end_v < curr:
            curr, end_v = end_v, curr
        for off in range(min(end_v - curr + 1, eff_limit)):
            ips_to_test.append(str(ipaddress.ip_address(curr + off)))
    elif "," in raw:
        for p in [x.strip() for x in raw.split(",") if x.strip()][:eff_limit]:
            ipaddress.ip_address(p)
            ips_to_test.append(p)
    else:
        try:
            ipaddress.ip_address(raw)
            ips_to_test = [raw]
        except ValueError as exc:
            raise ValueError(f"Destino de red '{raw}' no válido: {exc}")

    base_ports = [22, 80, 443, 3389, 445, 8006, 902, 161]
    is_bulk = len(ips_to_test) > 12
    max_workers = min(24, max(1, len(ips_to_test)))
    probe_by_ip: Dict[str, Dict[str, Any]] = {}
    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        futs = {
            pool.submit(_probe_ip_network_only, ip_s, base_ports, timeout_sec, is_bulk): ip_s
            for ip_s in ips_to_test
        }
        for fut, ip_k in futs.items():
            probe_by_ip[ip_k] = fut.result()

    # Mapear IPs conocidas en CMDB (solo lectura)
    ip_rows = (
        db.query(CmdbIpAddress)
        .filter(CmdbIpAddress.ip_address.in_(ips_to_test))
        .all()
        if ips_to_test
        else []
    )
    asset_id_by_ip = {r.ip_address: r.asset_id for r in ip_rows if r.asset_id}

    run_code = f"NETFP-{secrets.token_hex(3).upper()}"
    created_snaps: List[AiPassiveDiscoverySnapshot] = []
    for ip_s in ips_to_test:
        pdata = probe_by_ip[ip_s]
        if not (pdata.get("icmp_alive") or pdata.get("tcp_alive") or pdata.get("arp_alive")):
            continue
        fp = pdata.get("fingerprint") or {}
        os_str = fp.get("os_guess") or "Activo en red (OS indeterminado)"
        conf = fp.get("confidence")
        os_full = f"{os_str} [{conf}%]" if conf else os_str
        if fp.get("mac_vendor"):
            os_full = f"{os_full} • {fp['mac_vendor']}"

        l_ports = [
            {
                "port": svc.get("port"),
                "proto": svc.get("protocol") or "tcp",
                "process": svc.get("service") or "",
                "banner": svc.get("banner") or "",
            }
            for svc in (fp.get("open_services") or [])
        ]
        meta_entry = {
            "mac_address": fp.get("mac_address") or pdata.get("arp_mac") or "",
            "mac_vendor": fp.get("mac_vendor") or "",
            "device_type_guess": fp.get("device_type_guess") or "",
            "suggested_asset_class": fp.get("suggested_asset_class") or "other_machine",
            "suggested_asset_class_label": fp.get("suggested_asset_class_label") or "",
            "tcpip_stack": fp.get("tcpip_stack") or {},
            "banners": fp.get("banners") or {},
        }
        snap = AiPassiveDiscoverySnapshot(
            run_code=run_code,
            collector_type="network_fingerprint_ro",
            target_host=ip_s,
            asset_id=asset_id_by_ip.get(ip_s),
            status="completed",
            hostname_detected=(fp.get("fqdn_detected") or fp.get("hostname_detected") or pdata.get("ptr_hostname") or "")[:180],
            os_or_sysdescr=os_full[:250],
            listening_ports=l_ports,
            peer_connections=[],
            running_services=list(fp.get("evidence") or []),
            containers=[],
            web_vhosts_or_dbs=[meta_entry],
            snmp_interfaces=[],
            inferred_dependencies=[],
            collected_by=collected_by,
        )
        db.add(snap)
        created_snaps.append(snap)

    if created_snaps:
        db.commit()
        for s in created_snaps:
            db.refresh(s)

    return [serialize_passive_snapshot(s) for s in created_snaps]
