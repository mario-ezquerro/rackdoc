"""Ajustes y bucle de fondo de la monitorización (Heartbeat periódico)."""

import asyncio
import json

from datetime import datetime
from sqlalchemy.orm import Session
from typing import Optional

from .database import DEFAULT_DB_PATH, SessionLocal
from .models import FloorDevice, RackDevice
from .services.monitor import check_all_monitored_devices
from .services.network_host_service import evaluate_all_network_service_checks

MONITORING_SETTINGS_PATH = DEFAULT_DB_PATH.parent / "monitoring_settings.json"


_monitoring_wakeup_event: Optional[asyncio.Event] = None


def crear_evento_despertar_monitorizacion() -> asyncio.Event:
    """Crea (y publica) el evento con el que se adelanta la pasada de Heartbeat."""
    global _monitoring_wakeup_event
    _monitoring_wakeup_event = asyncio.Event()
    return _monitoring_wakeup_event


def despertar_monitorizacion() -> None:
    """Despierta al bucle de fondo para que no espere al siguiente intervalo."""
    if _monitoring_wakeup_event is not None:
        _monitoring_wakeup_event.set()


def _load_monitoring_settings() -> dict:
    default_cfg = {
        "interval_seconds": 300,  # 5 minutos por defecto
        "background_enabled": True,
        "last_run_at": None,
        "last_checked_count": 0,
    }
    if MONITORING_SETTINGS_PATH.is_file():
        try:
            raw = json.loads(MONITORING_SETTINGS_PATH.read_text(encoding="utf-8"))
            if isinstance(raw, dict):
                default_cfg.update(raw)
        except Exception:
            pass
    sec = int(default_cfg.get("interval_seconds") or 300)
    default_cfg["interval_seconds"] = max(15, min(86400, sec))
    default_cfg["interval_minutes"] = max(1, round(default_cfg["interval_seconds"] / 60))
    return default_cfg


def _save_monitoring_settings(cfg: dict) -> dict:
    current = _load_monitoring_settings()
    current.update(cfg)
    sec = int(current.get("interval_seconds") or 300)
    current["interval_seconds"] = max(15, min(86400, sec))
    current["interval_minutes"] = max(1, round(current["interval_seconds"] / 60))
    try:
        MONITORING_SETTINGS_PATH.parent.mkdir(parents=True, exist_ok=True)
        MONITORING_SETTINGS_PATH.write_text(
            json.dumps(current, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
    except Exception:
        pass
    return current


def _execute_background_monitoring_pass() -> list[dict]:
    db = SessionLocal()
    try:
        results = check_all_monitored_devices(db)
        try:
            evaluate_all_network_service_checks(db)
        except Exception:
            pass
        _save_monitoring_settings(
            {
                "last_run_at": datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC"),
                "last_checked_count": len(results),
            }
        )
        return results
    except Exception:
        return []
    finally:
        db.close()


async def _background_heartbeat_loop(
    stop_event: asyncio.Event,
    wakeup_event: asyncio.Event,
):
    # Ejecución inicial ligera al arrancar para actualizar cualquier equipo con Heartbeat activo
    await asyncio.sleep(2.0)
    while not stop_event.is_set():
        cfg = _load_monitoring_settings()
        if cfg.get("background_enabled", True):
            await asyncio.to_thread(_execute_background_monitoring_pass)
        interval_sec = float(cfg.get("interval_seconds") or 300)
        wakeup_event.clear()
        try:
            await asyncio.wait_for(wakeup_event.wait(), timeout=interval_sec)
        except asyncio.TimeoutError:
            pass


def _build_global_monitoring_summary(db: Session) -> dict:
    cfg = _load_monitoring_settings()
    rack_devs = (
        db.query(RackDevice)
        .filter(RackDevice.mounted_face != "external")
        .all()
    )
    floor_devs = db.query(FloorDevice).all()
    all_items = [*rack_devs, *floor_devs]

    unmonitored_cnt = 0
    monitored_cnt = 0
    online_cnt = 0
    warning_cnt = 0
    offline_cnt = 0

    for item in all_items:
        if not getattr(item, "monitoring_enabled", False):
            unmonitored_cnt += 1
        else:
            monitored_cnt += 1
            st = (getattr(item, "status", "") or "offline").lower()
            if st == "online":
                online_cnt += 1
            elif st == "warning":
                warning_cnt += 1
            else:
                offline_cnt += 1

    return {
        **cfg,
        "total_elements": len(all_items),
        "unmonitored_count": unmonitored_cnt,
        "monitored_count": monitored_cnt,
        "online_count": online_cnt,
        "warning_count": warning_cnt,
        "offline_count": offline_cnt,
    }
