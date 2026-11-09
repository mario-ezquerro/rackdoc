"""Catálogo de plantillas de hardware y búsqueda de fotografías."""

import json
import urllib.request

from fastapi import Depends, HTTPException
from fastapi.responses import Response
from sqlalchemy.orm import Session
from typing import Optional

from ..database import get_db
from ..models import DeviceTemplate, RackDevice
from ..schemas import DeviceLibraryImportRequest, DeviceTemplateCreate, DeviceTemplateSchema, DeviceTemplateUpdate
from ..security import MAX_EXTERNAL_DOWNLOAD_BYTES, assert_safe_external_url, no_redirect_opener
from ..routers._common import api_router, public_router

@api_router.get(
    "/templates",
    response_model=list[DeviceTemplateSchema],
    tags=["Device Templates & Library"],
    summary="Listar catálogo de Plantillas de Equipos Hardware",
    description="Devuelve todas las plantillas de chasis hardware con su geometría de puertos Front y Back.",
)
def get_device_templates(db: Session = Depends(get_db)):
    return (
        db.query(DeviceTemplate)
        .filter(DeviceTemplate.category != "external_power_feed")
        .order_by(
            DeviceTemplate.library_group,
            DeviceTemplate.category,
            DeviceTemplate.model_name,
        )
        .all()
    )


@api_router.post(
    "/templates",
    response_model=DeviceTemplateSchema,
    tags=["Device Templates & Library"],
    summary="Crear una nueva Plantilla de Equipo Hardware",
    description="Registra en la librería un nuevo modelo de equipo rackeable o de bandeja con su altura U y distribución de bocas Front/Back.",
)
def create_device_template(payload: DeviceTemplateCreate, db: Session = Depends(get_db)):
    tpl = DeviceTemplate(**payload.model_dump())
    db.add(tpl)
    db.commit()
    db.refresh(tpl)
    return tpl


@public_router.get(
    "/templates/photo-proxy",
    tags=["Device Templates & Library"],
    summary="Proxy CORS de fotografías de chasis hardware",
    description="Descarga y sirve fotografías externas de equipos hardware añadiendo cabeceras CORS para el lienzo de Flutter Web.",
)
def proxy_hardware_photo(url: str):
    """Proxy de imágenes externas para evitar bloqueos CORS en Flutter Web."""
    # Esta ruta es pública (el navegador la pide desde <img src>), así que se
    # valida el destino para que no sirva como SSRF hacia la red interna.
    target = assert_safe_external_url(url)
    try:
        req = urllib.request.Request(
            target,
            headers={
                "User-Agent": "RackDoc8-DCIM/1.4 (https://github.com/mario-ezquerro/rackdoc)",
                "Accept": "image/*,*/*;q=0.8",
            },
        )
        with no_redirect_opener.open(req, timeout=8) as resp:
            content = resp.read(MAX_EXTERNAL_DOWNLOAD_BYTES + 1)
            if len(content) > MAX_EXTERNAL_DOWNLOAD_BYTES:
                raise HTTPException(status_code=413, detail="La imagen remota es demasiado grande.")
            ctype = resp.headers.get("Content-Type", "image/jpeg")
            if not ctype.lower().startswith("image/"):
                raise HTTPException(status_code=415, detail="La URL no devuelve una imagen.")
            return Response(
                content=content,
                media_type=ctype,
                headers={"Cache-Control": "public, max-age=86400"},
            )
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"No se pudo cargar imagen: {exc}")


@api_router.get(
    "/templates/search-photo",
    tags=["Device Templates & Library"],
    summary="Buscar fotografías de hardware en Wikimedia Commons",
    description="Busca imágenes reales de chasis hardware (servidores, switches, routers, firewalls, SAIs, PDUs) mediante Wikimedia Commons API con limpieza semántica.",
)
def search_hardware_photos(q: str = "server rack"):
    """Busca imágenes de referencia de equipos hardware en Internet (Wikimedia Commons API) con limpieza inteligente de modelo."""
    import re

    query_str = (q or "").strip()
    if not query_str:
        return {"query": q, "results": []}

    # Limpiar paréntesis, alturas U, especificaciones de puertos ("+ 4xSFP+", "24p", "Cat6A", "Gen11", etc.)
    cleaned = re.sub(r"\([^)]*\)", " ", query_str)
    cleaned = re.sub(
        r"\b(\d+U|\d+p|\d+x\S+|\d+T|\d+G|Cat\.?\d+\w*|Gen\d+|Full-Depth|Short-Depth|Plus\+?)\b",
        " ",
        cleaned,
        flags=re.IGNORECASE,
    )
    cleaned = re.sub(r"[+/\\\-_]+", " ", cleaned)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()

    tokens = [t for t in cleaned.split(" ") if len(t) >= 2]
    brand = tokens[0] if tokens else ""
    family = " ".join(tokens[:2]) if len(tokens) >= 2 else cleaned
    low_q = query_str.lower()

    # Detectar categoría semántica para fallback garantizado
    if any(k in low_q for k in ["switch", "catalyst", "aruba", "nexus"]):
        cat_hint = "Ethernet switch rack"
    elif any(k in low_q for k in ["router", "mikrotik", "ccr", "isr", "rutx"]):
        cat_hint = "MikroTik router rack"
    elif any(k in low_q for k in ["forti", "firewall", "palo alto", "ngfw"]):
        cat_hint = "Firewall appliance rack"
    elif any(k in low_q for k in ["patch", "patchbox", "cat6"]):
        cat_hint = "19-inch rackmount Ethernet switches and patch panels"
    elif any(k in low_q for k in ["ups", "sai", "smart-ups"]):
        cat_hint = "APC UPS rack"
    elif any(k in low_q for k in ["pdu", "schuko", "regleta", "netshelter"]):
        cat_hint = "APC rackmount 19-inch PDU"
    elif any(k in low_q for k in ["netapp", "flashsystem", "powerstore", "alletra", "synology", "qnap", "san", "nas"]):
        cat_hint = "NetApp storage server rack"
    elif any(k in low_q for k in ["proliant", "hpe", "apollo"]):
        cat_hint = "HP ProLiant server"
    elif any(k in low_q for k in ["poweredge", "dell", "vxrail"]):
        cat_hint = "Dell PowerEdge server"
    else:
        cat_hint = "19-inch server rack hardware"

    search_variants = []
    for cand in [cleaned, family, f"{brand} rack" if brand else "", cat_hint, "19-inch rackmount Ethernet switches"]:
        c = cand.strip()
        if c and c not in search_variants:
            search_variants.append(c)

    results = []
    seen_urls = set()

    for variant in search_variants:
        if len(results) >= 10:
            break
        params = urllib.parse.urlencode(
            {
                "action": "query",
                "generator": "search",
                "gsrsearch": f"filetype:bitmap {variant}",
                "gsrnamespace": "6",
                "gsrlimit": "8",
                "prop": "imageinfo",
                "iiprop": "url|dimensions|extmetadata",
                "iiurlwidth": "640",
                "format": "json",
            }
        )
        api_url = f"https://commons.wikimedia.org/w/api.php?{params}"
        try:
            req = urllib.request.Request(
                api_url,
                headers={"User-Agent": "RackDoc8-DCIM/1.4 (https://github.com/mario-ezquerro/rackdoc)"},
            )
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = json.loads(resp.read().decode("utf-8", errors="ignore"))
                pages = (data.get("query") or {}).get("pages") or {}
                for _, page in pages.items():
                    title = str(page.get("title", "")).replace("File:", "")
                    iinfo = (page.get("imageinfo") or [{}])[0]
                    thumb_url = iinfo.get("thumburl") or iinfo.get("url") or ""
                    full_url = iinfo.get("url") or thumb_url
                    if not thumb_url or thumb_url in seen_urls:
                        continue
                    seen_urls.add(thumb_url)
                    results.append(
                        {
                            "title": title,
                            "thumb_url": thumb_url,
                            "url": full_url,
                            "width": iinfo.get("width", 0),
                            "height": iinfo.get("height", 0),
                            "source": f"Wikimedia ({variant})",
                        }
                    )
        except Exception:
            continue

    return {"query": query_str, "results": results[:12]}


@api_router.put(
    "/templates/{template_id}",
    response_model=DeviceTemplateSchema,
    tags=["Device Templates & Library"],
    summary="Actualizar plantilla de equipamiento hardware",
    description="Modifica especificaciones de plantilla (altura U, fabricante, modelo, color, layout de puertos o URL de foto).",
)
def update_device_template(
    template_id: int,
    payload: DeviceTemplateUpdate,
    db: Session = Depends(get_db),
):
    tpl = db.query(DeviceTemplate).filter(DeviceTemplate.id == template_id).first()
    if not tpl:
        raise HTTPException(status_code=404, detail="Plantilla no encontrada")

    updates = payload.model_dump(exclude_unset=True)
    photo_url = updates.pop("photo_url", None)

    for k, v in updates.items():
        setattr(tpl, k, v)

    if photo_url is not None:
        spec = dict(tpl.layout_spec or {})
        spec["photo_url"] = photo_url.strip()
        tpl.layout_spec = spec

    db.commit()
    db.refresh(tpl)
    return tpl


@api_router.delete(
    "/templates/{template_id}",
    tags=["Device Templates & Library"],
    summary="Eliminar plantilla de equipamiento hardware",
    description="Elimina una plantilla del catálogo si no está montada actualmente en ningún equipo de rack.",
)
def delete_device_template(template_id: int, db: Session = Depends(get_db)):
    tpl = db.query(DeviceTemplate).filter(DeviceTemplate.id == template_id).first()
    if not tpl:
        raise HTTPException(status_code=404, detail="Plantilla no encontrada")
    in_use = db.query(RackDevice).filter(RackDevice.template_id == template_id).count()
    if in_use > 0:
        raise HTTPException(
            status_code=409,
            detail=f"No se puede borrar la plantilla porque está montada en {in_use} equipo(s).",
        )
    db.delete(tpl)
    db.commit()
    return {"status": "deleted", "id": template_id}


@api_router.get(
    "/templates/export",
    tags=["Device Templates & Library"],
    summary="Exportar librería de plantillas hardware en JSON",
    description="Exporta todas las plantillas de chasis hardware (o un grupo específico) en formato JSON portable.",
)
def export_device_templates(
    library_group: Optional[str] = None,
    db: Session = Depends(get_db),
):
    q = db.query(DeviceTemplate).filter(DeviceTemplate.category != "external_power_feed")
    if library_group and library_group != "all":
        q = q.filter(DeviceTemplate.library_group == library_group)
    items = q.order_by(DeviceTemplate.library_group, DeviceTemplate.model_name).all()
    return {
        "library_group": library_group or "all",
        "count": len(items),
        "templates": [
            {
                "library_group": t.library_group,
                "category": t.category,
                "manufacturer": t.manufacturer,
                "model_name": t.model_name,
                "u_height": t.u_height,
                "is_full_depth": t.is_full_depth,
                "default_color": t.default_color,
                "layout_spec": t.layout_spec or {},
            }
            for t in items
        ],
    }


@api_router.post(
    "/templates/import",
    tags=["Device Templates & Library"],
    summary="Importar librería de plantillas hardware desde JSON",
    description="Importa o actualiza un lote de plantillas de chasis hardware en el catálogo del sistema.",
)
def import_device_templates(
    payload: DeviceLibraryImportRequest,
    db: Session = Depends(get_db),
):
    created_count = 0
    updated_count = 0
    for item in payload.templates:
        target_group = (
            payload.library_group
            if (payload.library_group and payload.library_group.strip())
            else item.get("library_group", "Network")
        )
        cat = str(item.get("category", "switch")).strip()
        manuf = str(item.get("manufacturer", "Generic")).strip()
        model_name = str(item.get("model_name", "")).strip()
        if not model_name:
            continue

        existing = (
            db.query(DeviceTemplate)
            .filter(
                DeviceTemplate.model_name == model_name,
                DeviceTemplate.manufacturer == manuf,
            )
            .first()
        )
        if existing:
            existing.library_group = target_group
            existing.category = cat
            existing.u_height = int(item.get("u_height", existing.u_height))
            existing.is_full_depth = bool(item.get("is_full_depth", existing.is_full_depth))
            existing.default_color = str(item.get("default_color", existing.default_color))
            if "layout_spec" in item and isinstance(item["layout_spec"], dict):
                existing.layout_spec = item["layout_spec"]
            updated_count += 1
        else:
            tpl = DeviceTemplate(
                library_group=target_group,
                category=cat,
                manufacturer=manuf,
                model_name=model_name,
                u_height=int(item.get("u_height", 1)),
                is_full_depth=bool(item.get("is_full_depth", False)),
                default_color=str(item.get("default_color", "#F8FAFC")),
                layout_spec=item.get("layout_spec", {"front": [], "back": []}),
            )
            db.add(tpl)
            created_count += 1

    db.commit()
    return {
        "status": "ok",
        "created": created_count,
        "updated": updated_count,
    }
