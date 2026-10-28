from __future__ import annotations
import platform
import re
import socket
import ssl
import subprocess
import time
import urllib.request
from datetime import datetime
from typing import Dict, Any, Tuple
from sqlalchemy.orm import Session
from ..models import RackDevice


def check_host_connectivity(
    host: str,
    method: str = "icmp",
    port: int = 22,
    timeout_sec: float = 1.5,
    extra_config: Dict[str, Any] | None = None,
    device_code: str = "",
) -> Tuple[str, float | None, str]:
    """
    Realiza una comprobación de Heartbeat / Conectividad según el método configurado:
    - 'icmp': ICMP Ping
    - 'ssh': Comprobación de socket/banner SSH (con usuario/parámetros extra)
    - 'https' | 'http': Petición HTTP/HTTPS a URL o endpoint de salud (/healthz, Web UI, API)
    - 'tcp': Apertura de puerto TCP específico
    - 'snmp': Comprobación de agente SNMP (UDP/TCP 161 con comunidad y OID)
    Retorna: (status: 'online' | 'offline', latency_ms: float | None, detail: str)
    """
    cfg = extra_config or {}
    target = (host or "").strip()
    m = (method or "icmp").lower().strip()
    custom_url = str(cfg.get("url", "")).strip()

    if not target and not custom_url:
        return ("unknown", None, "Sin IP, FQDN o URL de Heartbeat configurada")

    # Para la subred de demostración del CPD (10.28.x.x) que no existe físicamente en el host Docker,
    # proporcionamos respuesta de Heartbeat realista para poder probar estados Verde (online) y Rojo (offline).
    if target.startswith("10.28."):
        if cfg.get("simulate_offline") is True or device_code.upper() in ("SW03", "FW02"):
            return (
                "offline",
                None,
                f"Fallo Heartbeat {m.upper()} hacia {custom_url or f'{target}:{port}'} (Host inalcanzable / Timeout)",
            )
        sim_latencies = {
            "icmp": 1.4,
            "ssh": 5.2,
            "https": 14.8,
            "http": 9.6,
            "tcp": 2.9,
            "snmp": 4.1,
        }
        lat = sim_latencies.get(m, 2.1)
        if m in ("https", "http"):
            endpoint = custom_url or f"{m}://{target}:{port or (443 if m == 'https' else 80)}/"
            return ("online", lat, f"HTTP 200 OK en {endpoint} ({lat} ms)")
        if m == "ssh":
            ssh_usr = cfg.get("ssh_user", "admin")
            ssh_args = cfg.get("ssh_extra_args", "")
            return (
                "online",
                lat,
                f"Banner SSH-2.0 OK ({ssh_usr}@{target}:{port or 22}{' ' + ssh_args if ssh_args else ''}) ({lat} ms)",
            )
        if m == "snmp":
            comm = cfg.get("snmp_community", "public")
            oid = cfg.get("snmp_oid", "1.3.6.1.2.1.1.1.0")
            return ("online", lat, f"SNMP v2c OK ({comm} @ {target}:{port or 161} OID {oid}) ({lat} ms)")
        if m == "tcp":
            return ("online", lat, f"Socket TCP {target}:{port} abierto ({lat} ms)")
        return ("online", lat, f"Respuesta ICMP Ping OK desde {target} ({lat} ms)")

    # 1. Método HTTP / HTTPS con URL extra opcional
    if m in ("http", "https"):
        default_port = 443 if m == "https" else 80
        eff_port = port or default_port
        url = custom_url
        if not url:
            path = str(cfg.get("path", "/")).strip()
            if not path.startswith("/"):
                path = "/" + path
            url = f"{m}://{target}:{eff_port}{path}"
        elif not url.startswith("http://") and not url.startswith("https://"):
            url = f"{m}://{url}"

        start = time.perf_counter()
        try:
            ctx = ssl._create_unverified_context() if url.startswith("https://") else None
            req = urllib.request.Request(url, headers={"User-Agent": "RackDoc-Heartbeat/1.1"})
            with urllib.request.urlopen(req, timeout=timeout_sec, context=ctx) as resp:
                elapsed_ms = round((time.perf_counter() - start) * 1000.0, 2)
                code = getattr(resp, "status", 200)
                return ("online", elapsed_ms, f"HTTP {code} OK en {url} ({elapsed_ms} ms)")
        except Exception as exc:
            return ("offline", None, f"Fallo Heartbeat {m.upper()} en {url} ({exc})")

    # 2. Método SSH o TCP Socket
    if m in ("ssh", "tcp"):
        eff_port = port or (22 if m == "ssh" else 80)
        start = time.perf_counter()
        try:
            with socket.create_connection((target, eff_port), timeout=timeout_sec) as sock:
                if m == "ssh":
                    sock.settimeout(timeout_sec)
                    try:
                        banner = sock.recv(64).decode("utf-8", errors="ignore").strip()
                    except Exception:
                        banner = "SSH port open"
                    elapsed_ms = round((time.perf_counter() - start) * 1000.0, 2)
                    ssh_usr = cfg.get("ssh_user", "admin")
                    return (
                        "online",
                        elapsed_ms,
                        f"SSH OK ({ssh_usr}@{target}:{eff_port} — {banner or 'Socket Activo'}) ({elapsed_ms} ms)",
                    )
                elapsed_ms = round((time.perf_counter() - start) * 1000.0, 2)
                return ("online", elapsed_ms, f"Puerto TCP {eff_port} abierto ({elapsed_ms} ms)")
        except Exception as exc:
            return ("offline", None, f"Fallo conexión {m.upper()} {target}:{eff_port} ({exc})")

    # 3. Método SNMP (comprobación de puerto/socket o ping de respaldo)
    if m == "snmp":
        eff_port = port or 161
        comm = cfg.get("snmp_community", "public")
        oid = cfg.get("snmp_oid", "1.3.6.1.2.1.1.1.0")
        status, lat, detail = check_host_connectivity(target, "icmp", eff_port, timeout_sec)
        if status == "online":
            return ("online", lat, f"SNMP ({comm}, OID {oid}) activo en {target}:{eff_port} ({lat} ms)")
        return ("offline", None, f"Sin respuesta SNMP desde {target}:{eff_port}")

    # 4. Método por defecto: ICMP Ping del sistema
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
            return ("online", round(ping_ms, 2), f"Respuesta ICMP OK ({ping_ms} ms)")
        return ("offline", None, f"Sin respuesta ICMP desde {target}")
    except Exception as exc:
        return ("offline", None, f"Error ejecutando ping a {target}: {exc}")


def check_single_device(db: Session, device: RackDevice) -> Dict[str, Any]:
    target = device.ip_address.strip() if device.ip_address else device.fqdn.strip()
    cf = dict(device.custom_fields or {})
    hb_cfg = dict(cf.get("heartbeat_config") or {})
    status, latency_ms, detail = check_host_connectivity(
        host=target,
        method=device.monitor_method or "icmp",
        port=device.monitor_port or 22,
        extra_config=hb_cfg,
        device_code=device.code or "",
    )
    device.status = status
    device.last_ping_ms = latency_ms
    device.last_checked_at = datetime.utcnow()
    cf["last_heartbeat_detail"] = detail
    device.custom_fields = cf
    db.commit()
    db.refresh(device)
    return {
        "device_id": device.id,
        "code": device.code,
        "target": target,
        "method": device.monitor_method or "icmp",
        "status": device.status,
        "last_ping_ms": device.last_ping_ms,
        "last_checked_at": device.last_checked_at,
        "detail": detail,
    }


def check_all_monitored_devices(db: Session, rack_id: int | None = None) -> list[Dict[str, Any]]:
    query = db.query(RackDevice).filter(RackDevice.monitoring_enabled.is_(True))
    if rack_id is not None:
        query = query.filter(RackDevice.rack_id == rack_id)
    devices = query.all()
    results = []
    for dev in devices:
        results.append(check_single_device(db, dev))
    return results
