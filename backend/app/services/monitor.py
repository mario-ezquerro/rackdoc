from __future__ import annotations
import platform
import re
import socket
import subprocess
import time
from datetime import datetime
from typing import Dict, Any, Tuple
from sqlalchemy.orm import Session
from ..models import RackDevice


def check_host_connectivity(
    host: str,
    method: str = "icmp",
    port: int = 22,
    timeout_sec: float = 1.5,
) -> Tuple[str, float | None, str]:
    """
    Realiza una comprobación real de conectividad (ICMP Ping o TCP Socket)
    hacia la IP o FQDN del dispositivo del CPD.
    Retorna: (status: 'online' | 'offline', latency_ms: float | None, detail: str)
    """
    target = (host or "").strip()
    if not target:
        return ("unknown", None, "Sin IP o FQDN configurado")

    if method == "tcp":
        start = time.perf_counter()
        try:
            with socket.create_connection((target, port), timeout=timeout_sec):
                elapsed_ms = round((time.perf_counter() - start) * 1000.0, 2)
                return ("online", elapsed_ms, f"Puerto TCP {port} abierto ({elapsed_ms} ms)")
        except Exception as exc:
            return ("offline", None, f"Fallo conexión TCP {target}:{port} ({exc})")

    # Método por defecto: ICMP Ping del sistema
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
    status, latency_ms, detail = check_host_connectivity(
        host=target,
        method=device.monitor_method or "icmp",
        port=device.monitor_port or 22,
    )
    device.status = status
    device.last_ping_ms = latency_ms
    device.last_checked_at = datetime.utcnow()
    db.commit()
    db.refresh(device)
    return {
        "device_id": device.id,
        "code": device.code,
        "target": target,
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
