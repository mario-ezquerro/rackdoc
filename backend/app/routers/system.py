"""Endpoints de sistema: healthcheck, planos subidos y ajustes de monitorización."""

import asyncio

from fastapi import Depends
from fastapi.responses import FileResponse, Response
from pathlib import Path
from sqlalchemy.orm import Session

from ..database import get_db
from ..monitoring_settings import _build_global_monitoring_summary, _execute_background_monitoring_pass, _save_monitoring_settings, despertar_monitorizacion
from ..schemas import MonitoringSettingsUpdate
from ..uploads_store import UPLOADS_DIR, _TRANSPARENT_1X1_PNG
from ..routers._common import api_router, public_router

@public_router.get(
    "/uploads/{filename}",
    tags=["Locations, Floors & Blueprints"],
    summary="Obtener imagen de plano o recurso subido",
    description="Devuelve el archivo binario de imagen (JPG, PNG, GIF, WEBP) asociado al plano de una sede, planta o sala.",
)
def get_uploaded_plan_file(filename: str):
    safe_name = Path(filename).name
    file_path = UPLOADS_DIR / safe_name
    if file_path.is_file():
        return FileResponse(str(file_path))
    # Si el fichero ya no está se devuelve un PNG transparente. La limpieza de
    # las URLs huérfanas en base de datos se hace al arrancar, no en cada GET.
    return Response(content=_TRANSPARENT_1X1_PNG, media_type="image/png")


@public_router.get(
    "/health",
    tags=["Health & System"],
    summary="Comprobar estado del servicio (Healthcheck)",
    description="Devuelve el estado operativo del servicio backend y versión de la API.",
)
def health_check():
    return {"status": "ok", "service": "rackdoc-backend", "api_version": "v1"}


@api_router.get(
    "/settings/monitoring",
    tags=["Heartbeat & Monitoring"],
    summary="Obtener configuración y contadores globales de Heartbeat",
    description="Devuelve la frecuencia de chequeo en background (por defecto 300s / 5 min) y los contadores globales de los 4 estados: Gris (unmonitored), Verde (online), Naranja (warning) y Rojo (offline).",
)
def get_monitoring_settings_endpoint(db: Session = Depends(get_db)):
    return _build_global_monitoring_summary(db)


@api_router.put(
    "/settings/monitoring",
    tags=["Heartbeat & Monitoring"],
    summary="Actualizar frecuencia del motor de Heartbeat en background",
    description="Permite modificar el intervalo de comprobación periódica en minutos o segundos y activar/pausar el worker de background.",
)
def update_monitoring_settings_endpoint(
    payload: MonitoringSettingsUpdate,
    db: Session = Depends(get_db),
):
    updates = {}
    if payload.interval_seconds is not None:
        updates["interval_seconds"] = max(15, min(86400, int(payload.interval_seconds)))
    elif payload.interval_minutes is not None:
        updates["interval_seconds"] = max(15, min(86400, int(payload.interval_minutes) * 60))
    if payload.background_enabled is not None:
        updates["background_enabled"] = bool(payload.background_enabled)
    _save_monitoring_settings(updates)
    despertar_monitorizacion()
    return _build_global_monitoring_summary(db)


@api_router.post(
    "/settings/monitoring/run-now",
    tags=["Heartbeat & Monitoring"],
    summary="Ejecutar pasada completa de Heartbeat ahora mismo",
    description="Lanza inmediatamente en background la comprobación de todos los equipos de rack y dispositivos/sensores de planta que tengan Heartbeat activo.",
)
async def run_monitoring_now_endpoint(db: Session = Depends(get_db)):
    results = await asyncio.to_thread(_execute_background_monitoring_pass)
    summary = _build_global_monitoring_summary(db)
    summary["results"] = results
    return summary
