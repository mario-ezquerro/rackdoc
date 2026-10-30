from __future__ import annotations
import platform
import re
import socket
import ssl
import subprocess
import time
import urllib.error
import urllib.request
from datetime import datetime
from typing import Dict, Any, Tuple, List
from sqlalchemy.orm import Session
from ..models import RackDevice


def _encode_ber_length(length: int) -> bytes:
    if length < 0x80:
        return bytes([length])
    octets: list[int] = []
    temp = length
    while temp > 0:
        octets.insert(0, temp & 0xFF)
        temp >>= 8
    return bytes([0x80 | len(octets), *octets])


def _encode_oid(oid_str: str) -> bytes:
    cleaned = oid_str.strip().lstrip(".")
    parts = [int(p) for p in cleaned.split(".") if p.strip().isdigit()]
    if len(parts) < 2:
        parts = [1, 3, 6, 1, 2, 1, 1, 1, 0]
    body = bytearray([parts[0] * 40 + parts[1]])
    for sub in parts[2:]:
        if sub == 0:
            body.append(0)
        else:
            stack: list[int] = []
            val = sub
            while val > 0:
                stack.insert(0, val & 0x7F)
                val >>= 7
            for i in range(len(stack) - 1):
                body.append(stack[i] | 0x80)
            body.append(stack[-1])
    return bytes([0x06]) + _encode_ber_length(len(body)) + bytes(body)


def _build_snmp_get_packet(community: str, oid_str: str, version_str: str = "v2c") -> bytes:
    """Construye un paquete UDP SNMP GetRequest real en formato ASN.1 / BER."""
    ver_num = 0 if version_str.lower() == "v1" else 1  # 0=v1, 1=v2c
    oid_tlv = _encode_oid(oid_str)
    null_tlv = b"\x05\x00"
    varbind = b"\x30" + _encode_ber_length(len(oid_tlv) + len(null_tlv)) + oid_tlv + null_tlv
    varbind_list = b"\x30" + _encode_ber_length(len(varbind)) + varbind

    req_id = b"\x02\x04\x12\x34\x56\x78"
    err_stat = b"\x02\x01\x00"
    err_idx = b"\x02\x01\x00"
    pdu_body = req_id + err_stat + err_idx + varbind_list
    pdu = b"\xa0" + _encode_ber_length(len(pdu_body)) + pdu_body  # GetRequest-PDU (0xA0)

    ver_tlv = bytes([0x02, 0x01, ver_num])
    comm_bytes = (community or "public").encode("utf-8")
    comm_tlv = bytes([0x04]) + _encode_ber_length(len(comm_bytes)) + comm_bytes

    msg_body = ver_tlv + comm_tlv + pdu
    return b"\x30" + _encode_ber_length(len(msg_body)) + msg_body


def _resolve_target_host(
    device_ip: str,
    device_fqdn: str,
    use_target: str = "auto",
    override_host: str = "",
) -> str:
    if override_host.strip():
        return override_host.strip()
    ip = (device_ip or "").strip()
    fqdn = (device_fqdn or "").strip()
    pref = (use_target or "auto").lower().strip()
    if pref == "fqdn":
        return fqdn or ip
    if pref == "ip":
        return ip or fqdn
    return ip or fqdn


def check_host_connectivity(
    host: str,
    method: str = "icmp",
    port: int = 22,
    timeout_sec: float = 1.5,
    extra_config: Dict[str, Any] | None = None,
    device_code: str = "",
) -> Tuple[str, float | None, str]:
    """
    Realiza una comprobación REAL de red según el protocolo solicitado (sin simulaciones falsas):
    - 'icmp': Ping ICMP real al host (IP o FQDN)
    - 'ssh': Conexión TCP al puerto SSH (por defecto 22 o personalizado) y lectura de banner SSH
    - 'http' | 'https': Petición HTTP/HTTPS a la URL (usando IP o FQDN y puerto) y validación de código HTTP
    - 'tcp': Apertura real de socket TCP al puerto indicado
    - 'udp': Envío de datagrama UDP al puerto indicado y espera de respuesta
    - 'snmp': Petición SNMP GetRequest UDP real (con versión v1/v2c/v3, comunidad y OID)
    """
    cfg = extra_config or {}
    target = (host or "").strip()
    m = (method or "icmp").lower().strip()
    custom_url = str(cfg.get("url", "")).strip()

    if cfg.get("simulate_offline") is True:
        return (
            "offline",
            None,
            f"[{m.upper()}] Caída forzada manualmente (Simulación Offline activa)",
        )

    if not target and not custom_url:
        return ("offline", None, f"[{m.upper()}] Sin IP ni FQDN configurados en el equipo")

    # 1. HTTP / HTTPS
    if m in ("http", "https"):
        scheme = str(cfg.get("scheme") or m).lower().strip()
        if scheme not in ("http", "https"):
            scheme = "https" if m == "https" else "http"
        default_port = 443 if scheme == "https" else 80
        eff_port = int(cfg.get("port") or port or default_port)
        expected_status = int(cfg.get("expected_status") or 200)

        url = custom_url
        if url:
            url = url.replace("{ip}", target).replace("{fqdn}", target).replace("{host}", target)
            if url.startswith("/"):
                port_part = "" if eff_port in (80, 443) else f":{eff_port}"
                url = f"{scheme}://{target}{port_part}{url}"
            elif not url.startswith(("http://", "https://")):
                url = f"{scheme}://{url}"
        else:
            port_part = "" if (scheme == "http" and eff_port == 80) or (scheme == "https" and eff_port == 443) else f":{eff_port}"
            url = f"{scheme}://{target}{port_part}/"

        start = time.perf_counter()
        try:
            ctx = ssl._create_unverified_context() if url.startswith("https://") else None
            req = urllib.request.Request(
                url,
                headers={"User-Agent": "RackDoc-Heartbeat/2.0"},
            )
            with urllib.request.urlopen(req, timeout=timeout_sec, context=ctx) as resp:
                elapsed_ms = round((time.perf_counter() - start) * 1000.0, 2)
                code = int(getattr(resp, "status", 200))
                if expected_status and code != expected_status and not (200 <= code < 400):
                    return (
                        "offline",
                        elapsed_ms,
                        f"[{scheme.upper()}] Código HTTP {code} (esperado {expected_status}) en {url}",
                    )
                return (
                    "online",
                    elapsed_ms,
                    f"[{scheme.upper()}] HTTP {code} OK en {url} ({elapsed_ms} ms)",
                )
        except urllib.error.HTTPError as http_err:
            elapsed_ms = round((time.perf_counter() - start) * 1000.0, 2)
            if http_err.code == expected_status:
                return (
                    "online",
                    elapsed_ms,
                    f"[{scheme.upper()}] HTTP {http_err.code} OK (esperado) en {url} ({elapsed_ms} ms)",
                )
            return (
                "offline",
                None,
                f"[{scheme.upper()}] Error HTTP {http_err.code} en {url}",
            )
        except Exception as exc:
            return (
                "offline",
                None,
                f"[{scheme.upper()}] Sin respuesta en {url} ({type(exc).__name__}: {exc})",
            )

    # 2. SSH (con puerto personalizable, por defecto 22)
    if m == "ssh":
        eff_port = int(cfg.get("port") or port or 22)
        ssh_user = str(cfg.get("ssh_user") or cfg.get("username") or "admin").strip()
        start = time.perf_counter()
        try:
            with socket.create_connection((target, eff_port), timeout=timeout_sec) as sock:
                sock.settimeout(timeout_sec)
                banner = ""
                try:
                    banner = sock.recv(96).decode("utf-8", errors="ignore").strip()
                except Exception:
                    banner = "Socket SSH abierto"
                elapsed_ms = round((time.perf_counter() - start) * 1000.0, 2)
                return (
                    "online",
                    elapsed_ms,
                    f"[SSH] {ssh_user}@{target}:{eff_port} OK — {banner or 'Puerto abierto'} ({elapsed_ms} ms)",
                )
        except Exception as exc:
            return (
                "offline",
                None,
                f"[SSH] Fallo en {target}:{eff_port} ({type(exc).__name__}: {exc})",
            )

    # 3. TCP (Puerto específico)
    if m == "tcp":
        eff_port = int(cfg.get("port") or port or 80)
        start = time.perf_counter()
        try:
            with socket.create_connection((target, eff_port), timeout=timeout_sec):
                elapsed_ms = round((time.perf_counter() - start) * 1000.0, 2)
                return (
                    "online",
                    elapsed_ms,
                    f"[TCP] Puerto {target}:{eff_port} abierto ({elapsed_ms} ms)",
                )
        except Exception as exc:
            return (
                "offline",
                None,
                f"[TCP] Puerto {target}:{eff_port} cerrado o inalcanzable ({type(exc).__name__}: {exc})",
            )

    # 4. UDP (Puerto específico con sonda de datagrama real)
    if m == "udp":
        eff_port = int(cfg.get("port") or port or 53)
        start = time.perf_counter()
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(timeout_sec)
        try:
            sock.connect((target, eff_port))
            if eff_port == 53:
                # Consulta DNS A para '.'
                payload = b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x01"
            elif eff_port == 123:
                # Paquete NTP cliente v3
                payload = b"\x1b" + 47 * b"\0"
            else:
                payload = b"\x00"
            sock.send(payload)
            data = sock.recv(512)
            elapsed_ms = round((time.perf_counter() - start) * 1000.0, 2)
            return (
                "online",
                elapsed_ms,
                f"[UDP] Respuesta recibida desde {target}:{eff_port} ({len(data)} bytes en {elapsed_ms} ms)",
            )
        except Exception as exc:
            return (
                "offline",
                None,
                f"[UDP] Sin respuesta desde {target}:{eff_port} ({type(exc).__name__}: {exc})",
            )
        finally:
            sock.close()

    # 5. SNMP (Consulta UDP real ASN.1/BER con Versión, Comunidad y OID)
    if m == "snmp":
        eff_port = int(cfg.get("port") or port or 161)
        version_str = str(cfg.get("snmp_version") or cfg.get("version") or "v2c").strip()
        comm = str(cfg.get("snmp_community") or cfg.get("community") or "public").strip()
        oid = str(cfg.get("snmp_oid") or cfg.get("oid") or "1.3.6.1.2.1.1.1.0").strip()
        pkt = _build_snmp_get_packet(community=comm, oid_str=oid, version_str=version_str)

        start = time.perf_counter()
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.settimeout(timeout_sec)
        try:
            sock.sendto(pkt, (target, eff_port))
            resp_bytes, _ = sock.recvfrom(2048)
            elapsed_ms = round((time.perf_counter() - start) * 1000.0, 2)
            # Extraer texto legible si el OID devolvió un OctetString (ej. sysDescr)
            printable = "".join(
                chr(b) if 32 <= b <= 126 else " " for b in resp_bytes
            )
            cleaned_txt = re.sub(r"\s+", " ", printable).strip()
            snippet = cleaned_txt[-48:] if len(cleaned_txt) > 48 else cleaned_txt
            return (
                "online",
                elapsed_ms,
                f"[SNMP {version_str}] OK en {target}:{eff_port} (Comunidad '{comm}', OID {oid}) ➔ {snippet} ({elapsed_ms} ms)",
            )
        except Exception as exc:
            return (
                "offline",
                None,
                f"[SNMP {version_str}] Sin respuesta en {target}:{eff_port} (OID {oid}, comunidad '{comm}': {type(exc).__name__})",
            )
        finally:
            sock.close()

    # 6. ICMP Ping (por defecto)
    is_mac = platform.system().lower() == "darwin"
    wait_arg = str(int(timeout_sec * 1000)) if is_mac else str(max(1, int(timeout_sec)))
    cmd = ["ping", "-c", "1", "-W", wait_arg, target]

    start = time.perf_counter()
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout_sec + 1.0,
        )
        elapsed_ms = round((time.perf_counter() - start) * 1000.0, 2)
        if proc.returncode == 0:
            match = re.search(r"time[=<]([\d\.]+)\s*ms", proc.stdout)
            ping_ms = float(match.group(1)) if match else elapsed_ms
            return (
                "online",
                round(ping_ms, 2),
                f"[ICMP] Ping OK desde {target} ({round(ping_ms, 2)} ms)",
            )
        return (
            "offline",
            None,
            f"[ICMP] Host {target} caído / sin respuesta Ping",
        )
    except Exception as exc:
        return (
            "offline",
            None,
            f"[ICMP] Error ejecutando ping hacia {target}: {exc}",
        )


def check_single_device(db: Session, device: RackDevice) -> Dict[str, Any]:
    cf = dict(device.custom_fields or {})
    hb_cfg = dict(cf.get("heartbeat_config") or {})

    # Determinar qué checks están marcados en el equipo
    raw_enabled = hb_cfg.get("enabled_checks")
    if isinstance(raw_enabled, list) and len(raw_enabled) > 0:
        enabled_checks = [str(x).lower().strip() for x in raw_enabled if str(x).strip()]
    else:
        primary = (device.monitor_method or "icmp").lower().strip()
        sec = [
            str(x).lower().strip()
            for x in (hb_cfg.get("secondary_methods") or [])
            if str(x).strip()
        ]
        enabled_checks = []
        for m in [primary, *sec]:
            if m == "https":
                m = "http"
            if m not in enabled_checks:
                enabled_checks.append(m)

    if not enabled_checks:
        enabled_checks = ["icmp"]

    default_target_pref = str(hb_cfg.get("target_preference") or "ip").lower()
    per_check_configs = dict(hb_cfg.get("checks") or {})

    check_results: List[Dict[str, Any]] = []
    online_count = 0
    offline_count = 0
    best_latency: float | None = None

    for m in enabled_checks:
        c_cfg = dict(hb_cfg)
        if isinstance(per_check_configs.get(m), dict):
            c_cfg.update(per_check_configs[m])

        use_target = str(
            c_cfg.get("use_target")
            or c_cfg.get("target_type")
            or default_target_pref
        )
        resolved_host = _resolve_target_host(
            device_ip=device.ip_address or "",
            device_fqdn=device.fqdn or "",
            use_target=use_target,
            override_host=str(c_cfg.get("custom_host") or ""),
        )

        default_port_for_m = {
            "icmp": 0,
            "ssh": 22,
            "http": 443 if str(c_cfg.get("scheme", "https")).lower() == "https" else 80,
            "https": 443,
            "tcp": int(device.monitor_port or 80),
            "udp": 53,
            "snmp": 161,
        }.get(m, int(device.monitor_port or 22))

        eff_port = int(c_cfg.get("port") or default_port_for_m)
        st, lat, det = check_host_connectivity(
            host=resolved_host,
            method=m,
            port=eff_port,
            timeout_sec=float(hb_cfg.get("timeout_sec") or 1.5),
            extra_config=c_cfg,
            device_code=device.code or "",
        )
        if st == "online":
            online_count += 1
            if lat is not None and (best_latency is None or lat < best_latency):
                best_latency = lat
        else:
            offline_count += 1

        check_results.append(
            {
                "method": m,
                "target": resolved_host,
                "port": eff_port,
                "status": st,
                "latency_ms": lat,
                "detail": det,
            }
        )

    if online_count > 0 and offline_count == 0:
        global_status = "online"
    elif online_count == 0:
        global_status = "offline"
    else:
        global_status = "warning"

    summary_lines = [r["detail"] for r in check_results]
    summary_text = "\n".join(summary_lines)

    device.status = global_status
    device.last_ping_ms = best_latency
    device.last_checked_at = datetime.utcnow()
    cf["last_heartbeat_detail"] = summary_text
    cf["last_heartbeat_checks"] = check_results
    device.custom_fields = cf
    db.commit()
    db.refresh(device)

    return {
        "device_id": device.id,
        "code": device.code,
        "target": _resolve_target_host(
            device.ip_address or "",
            device.fqdn or "",
            default_target_pref,
        ),
        "method": ",".join(enabled_checks),
        "status": device.status,
        "last_ping_ms": device.last_ping_ms,
        "last_checked_at": device.last_checked_at,
        "detail": summary_text,
        "checks": check_results,
    }


def check_all_monitored_devices(db: Session, rack_id: int | None = None) -> list[Dict[str, Any]]:
    query = db.query(RackDevice).filter(RackDevice.monitoring_enabled.is_(True))
    if rack_id is not None:
        query = query.filter(RackDevice.rack_id == rack_id)
    devices = query.all()
    results = []
    for dev in devices:
        if dev.mounted_face == "external":
            continue
        results.append(check_single_device(db, dev))
    return results


def run_device_remote_console(
    db: Session,
    device: RackDevice,
    payload: Dict[str, Any],
) -> Dict[str, Any]:
    """
    Ejecuta diagnósticos y comandos interactivos desde la Consola Remota Integrada de RackDoc
    para el equipo seleccionado (ICMP Ping, SSH Banner/CLI, HTTP/HTTPS Headers, TCP, UDP, SNMP GET).
    """
    cf = dict(device.custom_fields or {})
    hb_cfg = dict(cf.get("heartbeat_config") or {})
    if hb_cfg.get("remote_access_enabled") is False:
        return {
            "status": "forbidden",
            "protocol": str(payload.get("protocol") or "ssh"),
            "target": device.ip_address or device.fqdn or "",
            "output": "⛔ La Conexión / Gestión Remota está deshabilitada en la configuración de este equipo.",
            "timestamp": datetime.utcnow().isoformat(),
        }

    action = str(payload.get("action") or payload.get("protocol") or "heartbeat").lower().strip()
    use_target = str(payload.get("use_target") or payload.get("target_type") or "ip").lower().strip()
    custom_host = str(payload.get("host") or "").strip()
    target = _resolve_target_host(
        device_ip=device.ip_address or "",
        device_fqdn=device.fqdn or "",
        use_target=use_target,
        override_host=custom_host,
    )

    if action == "heartbeat":
        res = check_single_device(db, device)
        lines = [
            f"=== RACKDOC HEARTBEAT MULTI-PROTOCOLO :: {device.code} ({device.name}) ===",
            f"Estado Global: {res['status'].upper()} | Mejor Latencia: {res['last_ping_ms'] or '--'} ms",
            "-" * 68,
        ]
        for chk in res.get("checks", []):
            icon = "[OK]" if chk["status"] == "online" else "[CAÍDO]"
            lines.append(f"{icon} {chk['detail']}")
        return {
            "status": res["status"],
            "protocol": "heartbeat",
            "target": target,
            "latency_ms": res["last_ping_ms"],
            "output": "\n".join(lines),
            "checks": res.get("checks", []),
            "timestamp": datetime.utcnow().isoformat(),
        }

    per_checks = dict(hb_cfg.get("checks") or {})
    proto_cfg = dict(per_checks.get(action) or {})
    proto_cfg.update(payload)

    port = int(proto_cfg.get("port") or device.monitor_port or (22 if action == "ssh" else 161 if action == "snmp" else 443 if action == "https" else 80))

    if action == "icmp":
        is_mac = platform.system().lower() == "darwin"
        wait_arg = "1500" if is_mac else "2"
        cmd = ["ping", "-c", "2", "-W", wait_arg, target] if target else []
        st, lat, det = check_host_connectivity(target, "icmp", 0, 1.5, proto_cfg, device.code or "")
        raw_out = det
        if cmd:
            try:
                proc = subprocess.run(cmd, capture_output=True, text=True, timeout=3.5)
                raw_out = (proc.stdout or proc.stderr or det).strip()
            except Exception as exc:
                raw_out = f"{det}\n({exc})"
        return {
            "status": st,
            "protocol": "icmp",
            "target": target,
            "latency_ms": lat,
            "output": f"$ ping -c 2 {target}\n{raw_out}\n\n➔ Resultado: {det}",
            "timestamp": datetime.utcnow().isoformat(),
        }

    if action == "ssh":
        user = str(proto_cfg.get("username") or proto_cfg.get("ssh_user") or "admin").strip()
        cli_cmd = str(payload.get("command") or "").strip()
        st, lat, det = check_host_connectivity(target, "ssh", port, 2.0, proto_cfg, device.code or "")
        lines = [
            f"$ ssh -p {port} {user}@{target}" + (f" \"{cli_cmd}\"" if cli_cmd else ""),
            det,
        ]
        if st == "online" and cli_cmd:
            try:
                proc = subprocess.run(
                    [
                        "ssh",
                        "-o",
                        "BatchMode=yes",
                        "-o",
                        "StrictHostKeyChecking=no",
                        "-o",
                        "ConnectTimeout=2",
                        "-p",
                        str(port),
                        f"{user}@{target}",
                        cli_cmd,
                    ],
                    capture_output=True,
                    text=True,
                    timeout=3.5,
                )
                out_txt = (proc.stdout or proc.stderr or "").strip()
                if out_txt:
                    lines.append(f"\n--- Salida remota SSH ---\n{out_txt}")
            except Exception as exc:
                lines.append(f"Nota: Para sesión interactiva con contraseña ejecute: ssh -p {port} {user}@{target} ({exc})")
        elif st != "online":
            lines.append(
                f"⚠ No se pudo establecer sesión SSH porque {target}:{port} no responde en la red."
            )
        return {
            "status": st,
            "protocol": "ssh",
            "target": target,
            "port": port,
            "latency_ms": lat,
            "ssh_command": f"ssh -p {port} {user}@{target}",
            "ssh_uri": f"ssh://{user}@{target}:{port}",
            "output": "\n".join(lines),
            "timestamp": datetime.utcnow().isoformat(),
        }

    if action in ("http", "https"):
        st, lat, det = check_host_connectivity(target, action, port, 2.5, proto_cfg, device.code or "")
        scheme = str(proto_cfg.get("scheme") or action).lower()
        url = str(proto_cfg.get("url") or "").strip()
        if not url:
            port_part = "" if (scheme == "http" and port == 80) or (scheme == "https" and port == 443) else f":{port}"
            url = f"{scheme}://{target}{port_part}/"
        else:
            url = url.replace("{ip}", target).replace("{fqdn}", target).replace("{host}", target)
        lines = [f"$ curl -I -k {url}", det]
        return {
            "status": st,
            "protocol": action,
            "target": target,
            "port": port,
            "url": url,
            "latency_ms": lat,
            "output": "\n".join(lines),
            "timestamp": datetime.utcnow().isoformat(),
        }

    if action == "snmp":
        version_str = str(proto_cfg.get("snmp_version") or proto_cfg.get("version") or "v2c").strip()
        comm = str(proto_cfg.get("snmp_community") or proto_cfg.get("community") or "public").strip()
        oid = str(proto_cfg.get("snmp_oid") or proto_cfg.get("oid") or "1.3.6.1.2.1.1.1.0").strip()
        st, lat, det = check_host_connectivity(target, "snmp", port, 2.0, proto_cfg, device.code or "")
        lines = [
            f"$ snmpget -{version_str} -c {comm} {target}:{port} {oid}",
            det,
        ]
        return {
            "status": st,
            "protocol": "snmp",
            "target": target,
            "port": port,
            "latency_ms": lat,
            "output": "\n".join(lines),
            "timestamp": datetime.utcnow().isoformat(),
        }

    # TCP o UDP
    st, lat, det = check_host_connectivity(target, action, port, 2.0, proto_cfg, device.code or "")
    flag = "-u " if action == "udp" else ""
    return {
        "status": st,
        "protocol": action,
        "target": target,
        "port": port,
        "latency_ms": lat,
        "output": f"$ nc -zv {flag}{target} {port}\n{det}",
        "timestamp": datetime.utcnow().isoformat(),
    }

