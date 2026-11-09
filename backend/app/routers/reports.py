"""Subida de planos, cuadro de mando e informes Excel."""

import uuid

from fastapi import Depends, File, Form, HTTPException, UploadFile
from fastapi.responses import StreamingResponse
from pathlib import Path
from sqlalchemy.orm import Session
from typing import Optional

from ..database import get_db
from ..models import Floor, Location, Room
from ..uploads_store import UPLOADS_DIR
from ..routers._common import api_router
from ..services.excel_export import build_dashboard_inventory_data, generate_datacenter_excel, generate_excel_import_template, import_datacenter_excel

@api_router.post(
    "/upload-plan",
    tags=["Static Assets & Uploads"],
    summary="Subir plano arquitectónico personalizado (Sede, Planta o Sala)",
    description="Permite subir una imagen (PNG, JPG, WEBP, GIF) y asociarla como plano de fondo de una Sede, Planta o Sala.",
)
async def upload_custom_plan_image(
    target_type: str = Form(...),  # location | floor | room
    target_id: int = Form(...),
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
):
    allowed_exts = {".jpg", ".jpeg", ".png", ".gif", ".webp"}
    orig_name = file.filename or "plano.png"
    ext = Path(orig_name).suffix.lower()
    if ext not in allowed_exts:
        raise HTTPException(
            status_code=400,
            detail="Formato no soportado. Sube una imagen JPG, PNG, GIF o WEBP.",
        )

    safe_filename = f"{target_type}_{target_id}_{uuid.uuid4().hex[:10]}{ext}"
    dest_path = UPLOADS_DIR / safe_filename
    content = await file.read()
    dest_path.write_bytes(content)

    relative_url = f"/api/v1/uploads/{safe_filename}"

    if target_type == "location":
        obj = db.query(Location).filter(Location.id == target_id).first()
    elif target_type == "floor":
        obj = db.query(Floor).filter(Floor.id == target_id).first()
    elif target_type == "room":
        obj = db.query(Room).filter(Room.id == target_id).first()
    else:
        raise HTTPException(status_code=400, detail="target_type debe ser location, floor o room")

    if not obj:
        raise HTTPException(status_code=404, detail="Elemento no encontrado")

    obj.map_image_url = relative_url
    db.commit()
    return {"status": "ok", "map_image_url": relative_url}


@api_router.delete(
    "/upload-plan/{target_type}/{target_id}",
    tags=["Static Assets & Uploads"],
    summary="Restablecer plano arquitectónico por defecto",
    description="Elimina la referencia al plano personalizado de una Sede, Planta o Sala.",
)
def delete_custom_plan_image(
    target_type: str,
    target_id: int,
    db: Session = Depends(get_db),
):
    if target_type == "location":
        obj = db.query(Location).filter(Location.id == target_id).first()
    elif target_type == "floor":
        obj = db.query(Floor).filter(Floor.id == target_id).first()
    elif target_type == "room":
        obj = db.query(Room).filter(Room.id == target_id).first()
    else:
        raise HTTPException(status_code=400, detail="target_type inválido")

    if not obj:
        raise HTTPException(status_code=404, detail="Elemento no encontrado")

    obj.map_image_url = ""
    db.commit()
    return {"status": "deleted"}


@api_router.get(
    "/reports/dashboard-inventory",
    tags=["Dashboard, KPIs & Excel Reports"],
    summary="Obtener KPIs ejecutivos e inventario consolidado del Dashboard",
    description="Devuelve métricas de capacidad U, estados Heartbeat (online, degraded, offline, unmonitored), desglose por sede/rack y matriz de cableado.",
)
def get_dashboard_inventory_report(
    location_id: Optional[int] = None,
    rack_id: Optional[int] = None,
    db: Session = Depends(get_db),
):
    return build_dashboard_inventory_data(
        db=db,
        location_id=location_id,
        rack_id=rack_id,
    )


@api_router.get(
    "/reports/excel",
    tags=["Dashboard, KPIs & Excel Reports"],
    summary="Exportar auditoría completa DCIM en libro Excel (.xlsx)",
    description="Genera y descarga un archivo Excel multi-pestaña con el inventario de sedes, racks, equipos montados, mapa de puertos y matriz de conexiones.",
)
def export_excel_report(
    location_id: Optional[int] = None,
    rack_id: Optional[int] = None,
    db: Session = Depends(get_db),
):
    excel_io = generate_datacenter_excel(db=db, location_id=location_id, rack_id=rack_id)
    filename = f"rackdoc_report_rack_{rack_id}.xlsx" if rack_id else "rackdoc_datacenter_inventory.xlsx"
    return StreamingResponse(
        excel_io,
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


@api_router.get(
    "/reports/excel/template",
    tags=["Dashboard, KPIs & Excel Reports"],
    summary="Descargar plantilla Excel de ejemplo para importación masiva",
    description="Genera una plantilla Excel (.xlsx) con ejemplos e instrucciones para carga masiva de infraestructura DCIM.",
)
def download_excel_import_template():
    excel_io = generate_excel_import_template()
    return StreamingResponse(
        excel_io,
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={
            "Content-Disposition": 'attachment; filename="RackDoc_Plantilla_Importacion_Ejemplo.xlsx"'
        },
    )


@api_router.post(
    "/reports/excel/import",
    tags=["Dashboard, KPIs & Excel Reports"],
    summary="Importar inventario DCIM desde archivo Excel (.xlsx)",
    description="Procesa un archivo Excel multi-hoja e importa o actualiza sedes, salas, racks, equipos y conexiones.",
)
async def import_excel_report(
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
):
    if not file.filename or not file.filename.lower().endswith((".xlsx", ".xlsm")):
        raise HTTPException(
            status_code=400,
            detail="El archivo debe ser un documento Excel (.xlsx).",
        )
    content = await file.read()
    try:
        summary = import_datacenter_excel(db=db, file_bytes=content)
        return {"status": "ok", **summary}
    except Exception as exc:
        raise HTTPException(
            status_code=400,
            detail=f"Error procesando el archivo Excel: {exc}",
        )
