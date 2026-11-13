"""Routers compartidos y utilidades de serialización comunes a los endpoints."""

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session, joinedload
from typing import Optional

from ..models import Connection, DeviceTemplate, Port, Rack, RackDevice
from ..schemas import ConnectionEndpointInfo, ConnectionSchema
from ..security import (
    enforce_rbac,
    require_automation_key,
    require_automation_key_or_session,
)

# Router principal de la API: TODA ruta montada aquí exige un JWT válido y
# que el rol del usuario alcance el mínimo de la ruta (ver security.enforce_rbac).
api_router = APIRouter(dependencies=[Depends(enforce_rbac)])


# Rutas que no pueden transportar la cabecera Authorization:
#   - el propio login y el healthcheck de Docker/orquestadores,
#   - las imágenes, que el navegador solicita vía <img src> y por tanto sin cabeceras.
public_router = APIRouter()


# Rutas máquina-a-máquina (Prometheus, Ansible, agentes): se autentican con X-API-Key.
automation_router = APIRouter(dependencies=[Depends(require_automation_key)])


# Rutas de solo lectura que consultan tanto los agentes como la propia interfaz:
# valen la X-API-Key o el JWT de sesión. Montar aquí lo que el navegador también
# necesita evita que un 401 de clave de automatización tumbe la sesión del usuario.
agent_or_session_router = APIRouter(
    dependencies=[Depends(require_automation_key_or_session)]
)


def _build_endpoint_info(port: Port) -> ConnectionEndpointInfo:
    dev = port.device
    rack = dev.rack
    return ConnectionEndpointInfo(
        port_id=port.id,
        port_number=port.port_number or "",
        port_type=port.port_type or "rj45",
        face=port.face or "front",
        device_id=dev.id,
        device_code=dev.code or "",
        device_name=dev.name or "",
        rack_id=rack.id,
        rack_code=rack.code or "",
        rack_name=rack.name or "",
        start_u=dev.start_u or 1,
    )


def _serialize_connection(c: Connection) -> ConnectionSchema:
    return ConnectionSchema(
        id=c.id,
        source_port_id=c.source_port_id,
        target_port_id=c.target_port_id,
        cable_type=c.cable_type or "utp_cat6",
        color_hex=c.color_hex or "#2563EB",
        routing_channel=c.routing_channel or "auto",
        label=c.label or "",
        vlan=c.vlan,
        length_m=c.length_m if c.length_m is not None else 1.5,
        notes=c.notes or "",
        source_info=_build_endpoint_info(c.source_port),
        target_info=_build_endpoint_info(c.target_port),
    )


def _effective_device_u_height(
    template: Optional[DeviceTemplate],
    custom_fields: Optional[dict],
) -> int:
    cf = custom_fields or {}
    override = cf.get("u_height_override")
    if override is not None:
        try:
            val = int(override)
            if 1 <= val <= 48:
                return val
        except (ValueError, TypeError):
            pass
    return template.u_height if template else 1


def _check_u_collision(
    db: Session,
    rack: Rack,
    start_u: int,
    u_height: int,
    mounted_face: str,
    is_full_depth: bool,
    exclude_device_id: Optional[int] = None,
):
    if mounted_face == "external":
        return

    end_u = start_u + u_height - 1
    if start_u < 1 or end_u > rack.total_units:
        raise HTTPException(
            status_code=400,
            detail=f"El dispositivo (U{start_u}-U{end_u}) excede los límites del rack (1..{rack.total_units}U).",
        )

    existing_devices = (
        db.query(RackDevice)
        .options(joinedload(RackDevice.template))
        .filter(RackDevice.rack_id == rack.id)
        .all()
    )
    for other in existing_devices:
        if other.mounted_face == "external":
            continue
        if exclude_device_id is not None and other.id == exclude_device_id:
            continue
        other_u_height = _effective_device_u_height(other.template, other.custom_fields)
        other_end = other.start_u + other_u_height - 1
        u_overlaps = not (end_u < other.start_u or start_u > other_end)
        if not u_overlaps:
            continue

        # Todo equipo montado en el rack ocupa la unidad U tanto en Front como en Back
        if True:
            raise HTTPException(
                status_code=409,
                detail=(
                    f"Colisión en U{start_u}-U{end_u} con el equipo "
                    f"'{other.code}' (U{other.start_u}-U{other_end})."
                ),
            )


def _delete_connections_for_port_ids(db: Session, port_ids: list[int]):
    if not port_ids:
        return
    db.query(Connection).filter(
        (Connection.source_port_id.in_(port_ids))
        | (Connection.target_port_id.in_(port_ids))
    ).delete(synchronize_session=False)


# ==============================================================================
# ADMINISTRACIÓN: AUTENTICACIÓN, ROLES (4 NIVELES) Y ACTIVE DIRECTORY (MULTI-AD)
# ==============================================================================
VALID_ROLES = {"admin", "editor", "operator", "viewer"}
