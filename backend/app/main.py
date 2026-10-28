from contextlib import asynccontextmanager
from pathlib import Path
from typing import Optional
import uuid
from fastapi import FastAPI, Depends, HTTPException, UploadFile, File, Form
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from fastapi.staticfiles import StaticFiles
from sqlalchemy import text
from sqlalchemy.orm import Session, joinedload

from .database import engine, Base, SessionLocal, get_db, DEFAULT_DB_PATH
from .models import (
    User,
    ADServer,
    Location,
    Floor,
    Room,
    Aisle,
    Rack,
    DeviceTemplate,
    RackDevice,
    Port,
    Connection,
)
from .schemas import (
    DeviceTemplateSchema,
    DeviceTemplateCreate,
    DeviceLibraryImportRequest,
    ExternalOutletCreate,
    ExternalOutletUpdate,
    LoginRequest,
    UserSchema,
    UserCreate,
    UserUpdate,
    ADServerSchema,
    ADServerCreate,
    ADServerUpdate,
    ADUserSearchRequest,
    ADUserImportRequest,
    RackDeviceSchema,
    RackDeviceCreate,
    RackDeviceUpdate,
    ConnectionSchema,
    ConnectionCreate,
    ConnectionUpdate,
    ConnectionEndpointInfo,
    RackUpdate,
    RackCreate,
    LocationCreate,
    LocationUpdate,
    FloorCreate,
    FloorUpdate,
    RoomCreate,
    AisleCreate,
)
from .seed import (
    seed_initial_data,
    sync_system_defaults,
    create_ports_from_template,
    get_or_create_external_feed_template,
    sync_external_outlet_ports,
    ensure_rack_external_outlets,
)
from .services.monitor import check_single_device, check_all_monitored_devices
from .services.excel_export import generate_datacenter_excel


UPLOADS_DIR = DEFAULT_DB_PATH.parent / "uploads"
UPLOADS_DIR.mkdir(parents=True, exist_ok=True)


def _ensure_db_migrations():
    """Añade columnas nuevas sin perder los datos existentes en SQLite."""
    alter_statements = [
        "ALTER TABLE locations ADD COLUMN map_image_url VARCHAR(500) DEFAULT ''",
        "ALTER TABLE locations ADD COLUMN plan_pos_x FLOAT DEFAULT 0.30",
        "ALTER TABLE locations ADD COLUMN plan_pos_y FLOAT DEFAULT 0.40",
        "ALTER TABLE locations ADD COLUMN plan_width FLOAT DEFAULT 140.0",
        "ALTER TABLE locations ADD COLUMN plan_height FLOAT DEFAULT 80.0",
        "ALTER TABLE locations ADD COLUMN map_scale FLOAT DEFAULT 1.0",
        "ALTER TABLE floors ADD COLUMN map_image_url VARCHAR(500) DEFAULT ''",
        "ALTER TABLE floors ADD COLUMN map_scale FLOAT DEFAULT 1.0",
        "ALTER TABLE rooms ADD COLUMN map_image_url VARCHAR(500) DEFAULT ''",
        "ALTER TABLE racks ADD COLUMN width_px FLOAT DEFAULT 96.0",
        "ALTER TABLE racks ADD COLUMN depth_px FLOAT DEFAULT 116.0",
        "ALTER TABLE racks ADD COLUMN rotation_deg INTEGER DEFAULT 0",
        "ALTER TABLE device_templates ADD COLUMN library_group VARCHAR(80) DEFAULT 'Network'",
        "ALTER TABLE users ADD COLUMN username VARCHAR(80) DEFAULT 'admin'",
        "ALTER TABLE users ADD COLUMN auth_source VARCHAR(30) DEFAULT 'local'",
        "ALTER TABLE users ADD COLUMN ad_server_id INTEGER",
        "ALTER TABLE users ADD COLUMN ad_dn VARCHAR(255) DEFAULT ''",
        "ALTER TABLE users ADD COLUMN is_active BOOLEAN DEFAULT 1",
    ]
    with engine.begin() as conn:
        for stmt in alter_statements:
            try:
                conn.execute(text(stmt))
            except Exception:
                pass


@asynccontextmanager
async def lifespan(app: FastAPI):
    Base.metadata.create_all(bind=engine)
    _ensure_db_migrations()
    db = SessionLocal()
    try:
        seed_initial_data(db)
        sync_system_defaults(db)
    finally:
        db.close()
    yield


app = FastAPI(
    title="RackDoc DCIM API",
    description="API de Gestión Visual de Centros de Datos, Racks (Front/Back), Planos JPG/PNG/GIF, Red, Monitorización y Exportación Excel",
    version="1.1.0",
    lifespan=lifespan,
)

app.mount("/api/uploads", StaticFiles(directory=str(UPLOADS_DIR)), name="uploads")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def _build_endpoint_info(port: Port) -> ConnectionEndpointInfo:
    dev = port.device
    rack = dev.rack
    return ConnectionEndpointInfo(
        port_id=port.id,
        port_number=port.port_number,
        port_type=port.port_type,
        face=port.face,
        device_id=dev.id,
        device_code=dev.code,
        device_name=dev.name,
        rack_id=rack.id,
        rack_code=rack.code,
        rack_name=rack.name,
        start_u=dev.start_u,
    )


def _serialize_connection(c: Connection) -> ConnectionSchema:
    return ConnectionSchema(
        id=c.id,
        source_port_id=c.source_port_id,
        target_port_id=c.target_port_id,
        cable_type=c.cable_type,
        color_hex=c.color_hex,
        routing_channel=c.routing_channel,
        label=c.label,
        vlan=c.vlan,
        length_m=c.length_m,
        notes=c.notes,
        source_info=_build_endpoint_info(c.source_port),
        target_info=_build_endpoint_info(c.target_port),
    )


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
        other_end = other.start_u + other.template.u_height - 1
        u_overlaps = not (end_u < other.start_u or start_u > other_end)
        if not u_overlaps:
            continue

        # Si cualquiera de los dos es full-depth o están en la misma cara, hay colisión
        face_conflict = (
            is_full_depth
            or other.template.is_full_depth
            or (mounted_face == other.mounted_face)
        )
        if face_conflict:
            raise HTTPException(
                status_code=409,
                detail=(
                    f"Colisión en U{start_u}-U{end_u} ({mounted_face.upper()}) con el equipo "
                    f"'{other.code}' (U{other.start_u}-U{other_end}, cara {other.mounted_face.upper()}"
                    f"{', profundidad completa' if other.template.is_full_depth else ''})."
                ),
            )


@app.get("/api/health")
def health_check():
    return {"status": "ok", "service": "rackdoc-backend"}


@app.get("/api/locations")
def get_locations_tree(db: Session = Depends(get_db)):
    locations = (
        db.query(Location)
        .options(
            joinedload(Location.floors)
            .joinedload(Floor.rooms)
            .joinedload(Room.racks)
            .joinedload(Rack.devices),
            joinedload(Location.floors)
            .joinedload(Floor.rooms)
            .joinedload(Room.aisles),
        )
        .all()
    )

    result = []
    for loc in locations:
        floors_count = len(loc.floors)
        rooms_count = 0
        racks_count = 0
        total_rack_units = 0
        floors_data = []

        for fl in sorted(loc.floors, key=lambda x: x.level_number):
            rooms_count += len(fl.rooms)
            rooms_data = []
            for rm in fl.rooms:
                racks_count += len(rm.racks)
                aisles_map = {a.id: a for a in rm.aisles}
                aisles_data = [
                    {
                        "id": a.id,
                        "code": a.code,
                        "name": a.name,
                        "aisle_type": a.aisle_type,
                    }
                    for a in rm.aisles
                ]
                racks_data = []
                for rk in rm.racks:
                    total_rack_units += rk.total_units
                    aisle_obj = aisles_map.get(rk.aisle_id)
                    racks_data.append(
                        {
                            "id": rk.id,
                            "code": rk.code,
                            "name": rk.name,
                            "total_units": rk.total_units,
                            "manufacturer": rk.manufacturer,
                            "model_name": rk.model_name,
                            "responsible_person": rk.responsible_person,
                            "aisle_id": rk.aisle_id,
                            "aisle_name": aisle_obj.name if aisle_obj else "General",
                            "aisle_type": aisle_obj.aisle_type if aisle_obj else "standard",
                            "pos_x": rk.pos_x if rk.pos_x is not None else 0.25,
                            "pos_y": rk.pos_y if rk.pos_y is not None else 0.35,
                            "width_px": rk.width_px or 96.0,
                            "depth_px": rk.depth_px or 116.0,
                            "rotation_deg": rk.rotation_deg or 0,
                            "device_count": len([d for d in rk.devices if d.mounted_face != "external"]),
                        }
                    )
                rooms_data.append(
                    {
                        "id": rm.id,
                        "name": rm.name,
                        "width_m": rm.width_m,
                        "depth_m": rm.depth_m,
                        "map_image_url": rm.map_image_url or "",
                        "aisles": aisles_data,
                        "racks": racks_data,
                    }
                )
            floors_data.append(
                {
                    "id": fl.id,
                    "name": fl.name,
                    "level_number": fl.level_number,
                    "map_image_url": fl.map_image_url or "",
                    "map_scale": fl.map_scale or 1.0,
                    "rooms": rooms_data,
                }
            )

        result.append(
            {
                "id": loc.id,
                "code": loc.code,
                "name": loc.name,
                "latitude": loc.latitude,
                "longitude": loc.longitude,
                "address": loc.address,
                "description": loc.description,
                "map_image_url": loc.map_image_url or "",
                "plan_pos_x": loc.plan_pos_x if loc.plan_pos_x is not None else 0.25,
                "plan_pos_y": loc.plan_pos_y if loc.plan_pos_y is not None else 0.35,
                "plan_width": loc.plan_width or 140.0,
                "plan_height": loc.plan_height or 80.0,
                "map_scale": loc.map_scale or 1.0,
                "floors_count": floors_count,
                "rooms_count": rooms_count,
                "racks_count": racks_count,
                "total_rack_units": total_rack_units,
                "floors": floors_data,
            }
        )
    return result


@app.post("/api/locations")
def create_location(payload: LocationCreate, db: Session = Depends(get_db)):
    loc = Location(**payload.model_dict() if hasattr(payload, "model_dict") else payload.model_dump())
    db.add(loc)
    db.commit()
    db.refresh(loc)
    # Crear una planta, sala y pasillo por defecto para facilitar el uso inmediato
    fl = Floor(location_id=loc.id, name="Floor 1", level_number=1)
    db.add(fl)
    db.flush()
    rm = Room(floor_id=fl.id, name="01 - Server Room", width_m=10.0, depth_m=8.0)
    db.add(rm)
    db.flush()
    aisle = Aisle(room_id=rm.id, code="PASILLO-A", name="Pasillo Frío A", aisle_type="cold")
    db.add(aisle)
    db.commit()
    return {"id": loc.id, "code": loc.code, "name": loc.name}


def _delete_connections_for_port_ids(db: Session, port_ids: list[int]):
    if not port_ids:
        return
    db.query(Connection).filter(
        (Connection.source_port_id.in_(port_ids))
        | (Connection.target_port_id.in_(port_ids))
    ).delete(synchronize_session=False)


@app.put("/api/locations/{location_id}")
def update_location(location_id: int, payload: LocationUpdate, db: Session = Depends(get_db)):
    loc = db.query(Location).filter(Location.id == location_id).first()
    if not loc:
        raise HTTPException(status_code=404, detail="Sede no encontrada")
    for k, v in payload.model_dump(exclude_unset=True).items():
        setattr(loc, k, v)
    db.commit()
    db.refresh(loc)
    return {"status": "ok", "id": loc.id}


@app.delete("/api/locations/{location_id}")
def delete_location(location_id: int, db: Session = Depends(get_db)):
    loc = (
        db.query(Location)
        .options(
            joinedload(Location.floors)
            .joinedload(Floor.rooms)
            .joinedload(Room.racks)
            .joinedload(Rack.devices)
            .joinedload(RackDevice.ports)
        )
        .filter(Location.id == location_id)
        .first()
    )
    if not loc:
        raise HTTPException(status_code=404, detail="Datacenter no encontrado")

    port_ids = [
        p.id
        for fl in loc.floors
        for rm in fl.rooms
        for rk in rm.racks
        for dv in rk.devices
        for p in dv.ports
    ]
    _delete_connections_for_port_ids(db, port_ids)
    db.delete(loc)
    db.commit()
    return {"status": "deleted", "id": location_id}


@app.post("/api/floors")
def create_floor(payload: FloorCreate, db: Session = Depends(get_db)):
    fl = Floor(**payload.model_dump())
    db.add(fl)
    db.commit()
    db.refresh(fl)
    # Crear una sala y pasillo por defecto en la nueva planta para que puedan añadir Racks directamente
    rm = Room(floor_id=fl.id, name=f"Sala CPD Planta {fl.level_number}", width_m=14.0, depth_m=10.0)
    db.add(rm)
    db.flush()
    aisle = Aisle(room_id=rm.id, code=f"PASILLO-P{fl.level_number}", name="Pasillo Frío Principal", aisle_type="cold")
    db.add(aisle)
    db.commit()
    return {"id": fl.id, "name": fl.name}


@app.put("/api/floors/{floor_id}")
def update_floor(floor_id: int, payload: FloorUpdate, db: Session = Depends(get_db)):
    fl = db.query(Floor).filter(Floor.id == floor_id).first()
    if not fl:
        raise HTTPException(status_code=404, detail="Planta no encontrada")
    for k, v in payload.model_dump(exclude_unset=True).items():
        setattr(fl, k, v)
    db.commit()
    db.refresh(fl)
    return {"status": "ok", "id": fl.id}


@app.delete("/api/floors/{floor_id}")
def delete_floor(floor_id: int, db: Session = Depends(get_db)):
    fl = (
        db.query(Floor)
        .options(
            joinedload(Floor.rooms)
            .joinedload(Room.racks)
            .joinedload(Rack.devices)
            .joinedload(RackDevice.ports)
        )
        .filter(Floor.id == floor_id)
        .first()
    )
    if not fl:
        raise HTTPException(status_code=404, detail="Planta no encontrada")

    port_ids = [
        p.id
        for rm in fl.rooms
        for rk in rm.racks
        for dv in rk.devices
        for p in dv.ports
    ]
    _delete_connections_for_port_ids(db, port_ids)
    db.delete(fl)
    db.commit()
    return {"status": "deleted", "id": floor_id}


@app.post("/api/rooms")
def create_room(payload: RoomCreate, db: Session = Depends(get_db)):
    rm = Room(**payload.model_dump())
    db.add(rm)
    db.commit()
    db.refresh(rm)
    return {"id": rm.id, "name": rm.name}


@app.post("/api/aisles")
def create_aisle(payload: AisleCreate, db: Session = Depends(get_db)):
    aisle = Aisle(**payload.model_dump())
    db.add(aisle)
    db.commit()
    db.refresh(aisle)
    return {"id": aisle.id, "code": aisle.code, "name": aisle.name}


@app.post("/api/racks")
def create_rack(payload: RackCreate, db: Session = Depends(get_db)):
    rk = Rack(**payload.model_dump())
    db.add(rk)
    db.commit()
    db.refresh(rk)
    ensure_rack_external_outlets(db, rk)
    db.commit()
    return {"id": rk.id, "code": rk.code, "name": rk.name}


@app.get("/api/templates", response_model=list[DeviceTemplateSchema])
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


@app.post("/api/templates", response_model=DeviceTemplateSchema)
def create_device_template(payload: DeviceTemplateCreate, db: Session = Depends(get_db)):
    tpl = DeviceTemplate(**payload.model_dump())
    db.add(tpl)
    db.commit()
    db.refresh(tpl)
    return tpl


@app.delete("/api/templates/{template_id}")
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


@app.get("/api/templates/export")
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


@app.post("/api/templates/import")
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


@app.get("/api/racks")
def list_all_racks(db: Session = Depends(get_db)):
    racks = (
        db.query(Rack)
        .options(
            joinedload(Rack.room).joinedload(Room.floor).joinedload(Floor.location),
            joinedload(Rack.aisle),
            joinedload(Rack.devices).joinedload(RackDevice.ports),
        )
        .all()
    )
    out = []
    for rk in racks:
        loc = rk.room.floor.location if (rk.room and rk.room.floor) else None
        out.append(
            {
                "id": rk.id,
                "code": rk.code,
                "name": rk.name,
                "total_units": rk.total_units,
                "location_code": loc.code if loc else "",
                "location_name": loc.name if loc else "",
                "floor_name": rk.room.floor.name if (rk.room and rk.room.floor) else "",
                "room_name": rk.room.name if rk.room else "",
                "aisle_name": rk.aisle.name if rk.aisle else "Sin pasillo",
            }
        )
    return out


@app.get("/api/racks/{rack_id}")
def get_rack_detail(rack_id: int, db: Session = Depends(get_db)):
    rack = (
        db.query(Rack)
        .options(
            joinedload(Rack.room).joinedload(Room.floor).joinedload(Floor.location),
            joinedload(Rack.room).joinedload(Room.aisles),
            joinedload(Rack.aisle),
            joinedload(Rack.devices).joinedload(RackDevice.template),
            joinedload(Rack.devices).joinedload(RackDevice.ports),
        )
        .filter(Rack.id == rack_id)
        .first()
    )
    if not rack:
        raise HTTPException(status_code=404, detail="Rack no encontrado")

    if not any(d.mounted_face == "external" for d in rack.devices):
        ensure_rack_external_outlets(db, rack)
        db.commit()
        db.refresh(rack)

    room = rack.room
    floor = room.floor if room else None
    loc = floor.location if floor else None

    # Obtener todos los IDs de puertos de este rack
    port_ids = [p.id for d in rack.devices for p in d.ports]
    connections_serialized = []
    if port_ids:
        conns = (
            db.query(Connection)
            .options(
                joinedload(Connection.source_port).joinedload(Port.device).joinedload(RackDevice.rack),
                joinedload(Connection.target_port).joinedload(Port.device).joinedload(RackDevice.rack),
            )
            .filter(
                (Connection.source_port_id.in_(port_ids))
                | (Connection.target_port_id.in_(port_ids))
            )
            .all()
        )
        connections_serialized = [_serialize_connection(c).model_dump() for c in conns]

    devices_serialized = [
        RackDeviceSchema.model_validate(d).model_dump()
        for d in sorted(rack.devices, key=lambda x: x.start_u, reverse=True)
    ]

    return {
        "id": rack.id,
        "code": rack.code,
        "name": rack.name,
        "total_units": rack.total_units,
        "manufacturer": rack.manufacturer,
        "model_name": rack.model_name,
        "serial_number": rack.serial_number,
        "responsible_person": rack.responsible_person,
        "purchase_date": rack.purchase_date,
        "operation_start": rack.operation_start,
        "notes": rack.notes,
        "room_id": rack.room_id,
        "aisle_id": rack.aisle_id,
        "breadcrumb": {
            "location_id": loc.id if loc else None,
            "location_code": loc.code if loc else "HQ",
            "location_name": loc.name if loc else "Headquarter",
            "floor_id": floor.id if floor else None,
            "floor_name": floor.name if floor else "Floor 1",
            "room_id": room.id if room else None,
            "room_name": room.name if room else "Room",
            "aisle_id": rack.aisle.id if rack.aisle else None,
            "aisle_code": rack.aisle.code if rack.aisle else "",
            "aisle_name": rack.aisle.name if rack.aisle else "Sin pasillo",
        },
        "available_aisles": [
            {"id": a.id, "code": a.code, "name": a.name, "aisle_type": a.aisle_type}
            for a in (room.aisles if room else [])
        ],
        "devices": devices_serialized,
        "connections": connections_serialized,
    }


@app.put("/api/racks/{rack_id}")
def update_rack(rack_id: int, payload: RackUpdate, db: Session = Depends(get_db)):
    rack = db.query(Rack).filter(Rack.id == rack_id).first()
    if not rack:
        raise HTTPException(status_code=404, detail="Rack no encontrado")

    if not any(d.mounted_face == "external" for d in rack.devices):
        ensure_rack_external_outlets(db, rack)
        db.commit()
        db.refresh(rack)

    for k, v in payload.model_dump(exclude_unset=True).items():
        setattr(rack, k, v)

    db.commit()
    db.refresh(rack)
    return {"status": "ok", "id": rack.id}


@app.delete("/api/racks/{rack_id}")
def delete_rack(rack_id: int, db: Session = Depends(get_db)):
    rack = (
        db.query(Rack)
        .options(joinedload(Rack.devices).joinedload(RackDevice.ports))
        .filter(Rack.id == rack_id)
        .first()
    )
    if not rack:
        raise HTTPException(status_code=404, detail="Rack no encontrado")

    port_ids = [p.id for dv in rack.devices for p in dv.ports]
    _delete_connections_for_port_ids(db, port_ids)
    db.delete(rack)
    db.commit()
    return {"status": "deleted", "id": rack_id}


@app.post("/api/racks/{rack_id}/devices", response_model=RackDeviceSchema)
def add_device_to_rack(rack_id: int, payload: RackDeviceCreate, db: Session = Depends(get_db)):
    rack = db.query(Rack).filter(Rack.id == rack_id).first()
    if not rack:
        raise HTTPException(status_code=404, detail="Rack no encontrado")

    if not any(d.mounted_face == "external" for d in rack.devices):
        ensure_rack_external_outlets(db, rack)
        db.commit()
        db.refresh(rack)

    template = db.query(DeviceTemplate).filter(DeviceTemplate.id == payload.template_id).first()
    if not template:
        raise HTTPException(status_code=404, detail="Plantilla de dispositivo no encontrada")

    _check_u_collision(
        db=db,
        rack=rack,
        start_u=payload.start_u,
        u_height=template.u_height,
        mounted_face=payload.mounted_face,
        is_full_depth=template.is_full_depth,
    )

    default_links = payload.management_links
    if not default_links and template.category in ("switch", "router", "firewall", "server", "pdu", "ups", "gateway"):
        default_links = [
            {"protocol": "ssh", "port": 22, "username": "admin", "label": "SSH CLI"},
            {"protocol": "https", "port": 443, "username": "admin", "label": "Web UI"},
        ]

    device = RackDevice(
        rack_id=rack.id,
        template_id=template.id,
        code=payload.code,
        name=payload.name,
        hostname=payload.hostname or payload.code.lower(),
        fqdn=payload.fqdn,
        start_u=payload.start_u,
        mounted_face=payload.mounted_face,
        ip_address=payload.ip_address,
        subnet_mask=payload.subnet_mask,
        gateway=payload.gateway,
        mac_address=payload.mac_address,
        vlan_mgmt=payload.vlan_mgmt,
        management_links=default_links,
        monitoring_enabled=payload.monitoring_enabled,
        monitor_method=payload.monitor_method,
        monitor_port=payload.monitor_port,
        status="unknown",
        serial_number=payload.serial_number,
        custom_fields=payload.custom_fields,
        notes=payload.notes,
    )
    db.add(device)
    db.flush()

    create_ports_from_template(db, device, template)
    db.commit()
    db.refresh(device)
    return device


@app.put("/api/devices/{device_id}", response_model=RackDeviceSchema)
def update_rack_device(device_id: int, payload: RackDeviceUpdate, db: Session = Depends(get_db)):
    device = (
        db.query(RackDevice)
        .options(joinedload(RackDevice.template), joinedload(RackDevice.rack), joinedload(RackDevice.ports))
        .filter(RackDevice.id == device_id)
        .first()
    )
    if not device:
        raise HTTPException(status_code=404, detail="Dispositivo no encontrado")

    updates = payload.model_dump(exclude_unset=True)
    new_start_u = updates.get("start_u", device.start_u)
    new_face = updates.get("mounted_face", device.mounted_face)

    if new_start_u != device.start_u or new_face != device.mounted_face:
        _check_u_collision(
            db=db,
            rack=device.rack,
            start_u=new_start_u,
            u_height=device.template.u_height,
            mounted_face=new_face,
            is_full_depth=device.template.is_full_depth,
            exclude_device_id=device.id,
        )

    for k, v in updates.items():
        setattr(device, k, v)

    db.commit()
    db.refresh(device)
    return device


@app.delete("/api/devices/{device_id}")
def delete_rack_device(device_id: int, db: Session = Depends(get_db)):
    device = db.query(RackDevice).filter(RackDevice.id == device_id).first()
    if not device:
        raise HTTPException(status_code=404, detail="Dispositivo no encontrado")

    port_ids = [p.id for p in device.ports]
    if port_ids:
        db.query(Connection).filter(
            (Connection.source_port_id.in_(port_ids))
            | (Connection.target_port_id.in_(port_ids))
        ).delete(synchronize_session=False)

    db.delete(device)
    db.commit()
    return {"status": "deleted", "id": device_id}


@app.post("/api/devices/{device_id}/ping")
def ping_device_endpoint(device_id: int, db: Session = Depends(get_db)):
    device = db.query(RackDevice).filter(RackDevice.id == device_id).first()
    if not device:
        raise HTTPException(status_code=404, detail="Dispositivo no encontrado")
    return check_single_device(db, device)


@app.post("/api/racks/{rack_id}/ping-all")
def ping_all_rack_devices_endpoint(rack_id: int, db: Session = Depends(get_db)):
    return check_all_monitored_devices(db, rack_id=rack_id)


@app.post("/api/racks/{rack_id}/external-outlets", response_model=RackDeviceSchema)
def create_external_outlet(
    rack_id: int,
    payload: ExternalOutletCreate,
    db: Session = Depends(get_db),
):
    rack = db.query(Rack).filter(Rack.id == rack_id).first()
    if not rack:
        raise HTTPException(status_code=404, detail="Rack no encontrado")

    if not any(d.mounted_face == "external" for d in rack.devices):
        ensure_rack_external_outlets(db, rack)
        db.commit()
        db.refresh(rack)

    tpl = get_or_create_external_feed_template(db)
    dev = RackDevice(
        rack_id=rack.id,
        template_id=tpl.id,
        code=payload.code.strip() or "TOMA-EXT",
        name=payload.name.strip() or "Línea Eléctrica Exterior (Schuko)",
        hostname=payload.code.strip().lower(),
        start_u=max(1, min(rack.total_units, payload.start_u)),
        mounted_face="external",
        status="online",
        custom_fields={
            "is_external_feed": True,
            "feed_color": payload.color_hex,
            "socket_count": max(1, min(16, payload.socket_count)),
        },
        notes="Acometida eléctrica Schuko exterior al rack",
    )
    db.add(dev)
    db.flush()
    sync_external_outlet_ports(db, dev, payload.socket_count)
    db.commit()
    db.refresh(dev)
    return dev


@app.put("/api/external-outlets/{device_id}", response_model=RackDeviceSchema)
def update_external_outlet(
    device_id: int,
    payload: ExternalOutletUpdate,
    db: Session = Depends(get_db),
):
    dev = (
        db.query(RackDevice)
        .options(joinedload(RackDevice.ports), joinedload(RackDevice.template))
        .filter(RackDevice.id == device_id, RackDevice.mounted_face == "external")
        .first()
    )
    if not dev:
        raise HTTPException(status_code=404, detail="Toma exterior no encontrada")

    cf = dict(dev.custom_fields or {})
    cf["is_external_feed"] = True

    if payload.code is not None:
        dev.code = payload.code.strip()
    if payload.name is not None:
        dev.name = payload.name.strip()
    if payload.start_u is not None:
        dev.start_u = max(1, min(42, payload.start_u))
    if payload.color_hex is not None:
        cf["feed_color"] = payload.color_hex.strip()
        # Actualizar también el color de todos los cables conectados a esta toma exterior
        port_ids = [p.id for p in dev.ports]
        if port_ids:
            conns = (
                db.query(Connection)
                .filter(
                    (Connection.source_port_id.in_(port_ids))
                    | (Connection.target_port_id.in_(port_ids))
                )
                .all()
            )
            for c in conns:
                c.color_hex = payload.color_hex.strip()

    if payload.socket_count is not None:
        sc = max(1, min(16, payload.socket_count))
        cf["socket_count"] = sc
        sync_external_outlet_ports(db, dev, sc)

    dev.custom_fields = cf
    db.commit()
    db.refresh(dev)
    return dev


@app.delete("/api/external-outlets/{device_id}")
def delete_external_outlet(device_id: int, db: Session = Depends(get_db)):
    dev = (
        db.query(RackDevice)
        .options(joinedload(RackDevice.ports))
        .filter(RackDevice.id == device_id, RackDevice.mounted_face == "external")
        .first()
    )
    if not dev:
        raise HTTPException(status_code=404, detail="Toma exterior no encontrada")

    total_ext_in_rack = (
        db.query(RackDevice)
        .filter(
            RackDevice.rack_id == dev.rack_id,
            RackDevice.mounted_face == "external",
        )
        .count()
    )
    if total_ext_in_rack <= 1:
        raise HTTPException(
            status_code=400,
            detail="El rack debe mantener como mínimo 1 toma de corriente exterior (Schuko).",
        )

    port_ids = [p.id for p in dev.ports]
    _delete_connections_for_port_ids(db, port_ids)
    db.delete(dev)
    db.commit()
    return {"status": "deleted", "id": device_id}


@app.post("/api/connections", response_model=ConnectionSchema)
def create_connection(payload: ConnectionCreate, db: Session = Depends(get_db)):
    if payload.source_port_id == payload.target_port_id:
        raise HTTPException(status_code=400, detail="No puedes conectar un puerto consigo mismo.")

    sp = (
        db.query(Port)
        .options(joinedload(Port.device).joinedload(RackDevice.rack))
        .filter(Port.id == payload.source_port_id)
        .first()
    )
    tp = (
        db.query(Port)
        .options(joinedload(Port.device).joinedload(RackDevice.rack))
        .filter(Port.id == payload.target_port_id)
        .first()
    )
    if not sp or not tp:
        raise HTTPException(status_code=404, detail="Puerto origen o destino no encontrado.")

    # Verificar que ninguno de los dos puertos esté ya ocupado
    existing = (
        db.query(Connection)
        .filter(
            Connection.source_port_id.in_([sp.id, tp.id])
            | Connection.target_port_id.in_([sp.id, tp.id])
        )
        .first()
    )
    if existing:
        raise HTTPException(
            status_code=409,
            detail="Uno de los puertos seleccionados ya tiene un cable conectado.",
        )

    conn_data = payload.model_dump()
    # Si uno de los extremos es una toma eléctrica exterior (Schuko), el cable adopta el color identificativo de esa línea
    for end_dev in (sp.device, tp.device):
        if end_dev.mounted_face == "external":
            feed_color = (end_dev.custom_fields or {}).get("feed_color")
            if feed_color:
                conn_data["color_hex"] = feed_color
                conn_data["cable_type"] = "power_ac"
            break

    conn = Connection(**conn_data)
    db.add(conn)
    db.commit()
    db.refresh(conn)
    return _serialize_connection(conn)


@app.put("/api/connections/{connection_id}", response_model=ConnectionSchema)
def update_connection(connection_id: int, payload: ConnectionUpdate, db: Session = Depends(get_db)):
    conn = (
        db.query(Connection)
        .options(
            joinedload(Connection.source_port).joinedload(Port.device).joinedload(RackDevice.rack),
            joinedload(Connection.target_port).joinedload(Port.device).joinedload(RackDevice.rack),
        )
        .filter(Connection.id == connection_id)
        .first()
    )
    if not conn:
        raise HTTPException(status_code=404, detail="Conexión no encontrada")

    for k, v in payload.model_dump(exclude_unset=True).items():
        setattr(conn, k, v)

    db.commit()
    db.refresh(conn)
    return _serialize_connection(conn)


@app.delete("/api/connections/{connection_id}")
def delete_connection(connection_id: int, db: Session = Depends(get_db)):
    conn = db.query(Connection).filter(Connection.id == connection_id).first()
    if not conn:
        raise HTTPException(status_code=404, detail="Conexión no encontrada")
    db.delete(conn)
    db.commit()
    return {"status": "deleted", "id": connection_id}


@app.post("/api/upload-plan")
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

    relative_url = f"/api/uploads/{safe_filename}"

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


@app.delete("/api/upload-plan/{target_type}/{target_id}")
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


@app.get("/api/reports/excel")
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


# ==============================================================================
# ADMINISTRACIÓN: AUTENTICACIÓN, ROLES (4 NIVELES) Y ACTIVE DIRECTORY (MULTI-AD)
# ==============================================================================
VALID_ROLES = {"admin", "editor", "operator", "viewer"}


@app.post("/api/auth/login")
def login_endpoint(payload: LoginRequest, db: Session = Depends(get_db)):
    uname = payload.username.strip()
    pwd = payload.password

    # Permitir login como DOMAIN\user o user@domain
    if "\\" in uname:
        uname = uname.split("\\", 1)[1]
    elif "@" in uname and not db.query(User).filter(User.username == uname).first():
        uname = uname.split("@", 1)[0]

    user = (
        db.query(User)
        .filter((User.username == uname) | (User.email == payload.username.strip()))
        .first()
    )

    if not user:
        # Si se especificó un servidor AD y el usuario no está dado de alta aún, denegar indicando que debe darse de alta en AD
        raise HTTPException(
            status_code=401,
            detail="Usuario no encontrado o no dado de alta en RackDoc.",
        )

    if not user.is_active:
        raise HTTPException(status_code=403, detail="Esta cuenta de usuario está desactivada.")

    # Si es usuario de Active Directory, verificamos que su servidor AD esté habilitado y validamos contraseña
    if user.auth_source == "ad" and user.ad_server_id:
        ad_srv = db.query(ADServer).filter(ADServer.id == user.ad_server_id).first()
        if ad_srv and not ad_srv.enabled:
            raise HTTPException(
                status_code=403,
                detail=f"El servidor Active Directory '{ad_srv.name}' está deshabilitado.",
            )
        # Validamos contra password_hash local o permitimos bind simulado si password no está vacía
        if user.password_hash and pwd != user.password_hash:
            raise HTTPException(status_code=401, detail="Contraseña de Active Directory incorrecta.")
    else:
        if pwd != user.password_hash:
            raise HTTPException(status_code=401, detail="Usuario o contraseña incorrectos.")

    return {
        "status": "ok",
        "token": f"rackdoc-session-{user.id}-{user.role}",
        "user": UserSchema.model_validate(user).model_dump(),
    }


@app.get("/api/users", response_model=list[UserSchema])
def list_users(db: Session = Depends(get_db)):
    return db.query(User).order_by(User.id).all()


@app.post("/api/users", response_model=UserSchema)
def create_user(payload: UserCreate, db: Session = Depends(get_db)):
    uname = payload.username.strip()
    if not uname:
        raise HTTPException(status_code=400, detail="El nombre de usuario es obligatorio.")
    role = payload.role if payload.role in VALID_ROLES else "viewer"

    exists = db.query(User).filter(User.username == uname).first()
    if exists:
        raise HTTPException(status_code=409, detail=f"El usuario '{uname}' ya existe.")

    user = User(
        username=uname,
        email=payload.email.strip() or f"{uname}@rackdoc.local",
        full_name=payload.full_name.strip() or uname,
        password_hash=payload.password or "changeme",
        role=role,
        auth_source=payload.auth_source,
        ad_server_id=payload.ad_server_id,
        ad_dn=payload.ad_dn,
        is_active=payload.is_active,
    )
    db.add(user)
    db.commit()
    db.refresh(user)
    return user


@app.put("/api/users/{user_id}", response_model=UserSchema)
def update_user(user_id: int, payload: UserUpdate, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="Usuario no encontrado")

    if payload.username is not None and payload.username.strip():
        user.username = payload.username.strip()
    if payload.email is not None:
        user.email = payload.email.strip()
    if payload.full_name is not None:
        user.full_name = payload.full_name.strip()
    if payload.password is not None and payload.password.strip():
        user.password_hash = payload.password.strip()
    if payload.role is not None and payload.role in VALID_ROLES:
        user.role = payload.role
    if payload.is_active is not None:
        user.is_active = payload.is_active
    if payload.ad_server_id is not None:
        user.ad_server_id = payload.ad_server_id

    db.commit()
    db.refresh(user)
    return user


@app.delete("/api/users/{user_id}")
def delete_user(user_id: int, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="Usuario no encontrado")
    if user.role == "admin":
        admin_count = db.query(User).filter(User.role == "admin").count()
        if admin_count <= 1:
            raise HTTPException(
                status_code=400,
                detail="No puedes eliminar el único usuario Administrador del sistema.",
            )
    db.delete(user)
    db.commit()
    return {"status": "deleted", "id": user_id}


@app.get("/api/ad-servers", response_model=list[ADServerSchema])
def list_ad_servers(db: Session = Depends(get_db)):
    return db.query(ADServer).order_by(ADServer.id).all()


@app.post("/api/ad-servers", response_model=ADServerSchema)
def create_ad_server(payload: ADServerCreate, db: Session = Depends(get_db)):
    srv = ADServer(**payload.model_dump())
    db.add(srv)
    db.commit()
    db.refresh(srv)
    return srv


@app.put("/api/ad-servers/{ad_id}", response_model=ADServerSchema)
def update_ad_server(ad_id: int, payload: ADServerUpdate, db: Session = Depends(get_db)):
    srv = db.query(ADServer).filter(ADServer.id == ad_id).first()
    if not srv:
        raise HTTPException(status_code=404, detail="Servidor Active Directory no encontrado")
    for k, v in payload.model_dump(exclude_unset=True).items():
        setattr(srv, k, v)
    db.commit()
    db.refresh(srv)
    return srv


@app.delete("/api/ad-servers/{ad_id}")
def delete_ad_server(ad_id: int, db: Session = Depends(get_db)):
    srv = db.query(ADServer).filter(ADServer.id == ad_id).first()
    if not srv:
        raise HTTPException(status_code=404, detail="Servidor Active Directory no encontrado")
    db.delete(srv)
    db.commit()
    return {"status": "deleted", "id": ad_id}


@app.post("/api/ad-servers/{ad_id}/search-users")
def search_ad_directory_users(
    ad_id: int,
    payload: ADUserSearchRequest,
    db: Session = Depends(get_db),
):
    srv = db.query(ADServer).filter(ADServer.id == ad_id).first()
    if not srv:
        raise HTTPException(status_code=404, detail="Servidor AD no encontrado")

    q = payload.query.strip().lower()
    domain_suffix = srv.domain or "corp.local"
    base_dn = srv.base_dn or "DC=corp,DC=local"

    # Catálogo de cuentas del directorio AD para explorar/filtrar e importar con rol asignado
    directory_entries = [
        {
            "username": "jgarcia",
            "full_name": "Javier García (NetOps AD)",
            "email": f"jgarcia@{domain_suffix}",
            "ad_dn": f"CN=Javier Garcia,OU=NetOps,{base_dn}",
            "department": "Infraestructura & Redes",
            "suggested_role": srv.default_role,
        },
        {
            "username": "mfernandez",
            "full_name": "Marta Fernández (SysAdmin AD)",
            "email": f"mfernandez@{domain_suffix}",
            "ad_dn": f"CN=Marta Fernandez,OU=Sistemas,{base_dn}",
            "department": "Sistemas & Virtualización",
            "suggested_role": "editor",
        },
        {
            "username": "rnavarro",
            "full_name": "Roberto Navarro (Guardia NOC SSH/Web)",
            "email": f"rnavarro@{domain_suffix}",
            "ad_dn": f"CN=Roberto Navarro,OU=NOC,{base_dn}",
            "department": "Operaciones 24x7 (SSH & Web)",
            "suggested_role": "operator",
        },
        {
            "username": "elopez",
            "full_name": "Elena López (Auditoría TI)",
            "email": f"elopez@{domain_suffix}",
            "ad_dn": f"CN=Elena Lopez,OU=Auditoria,{base_dn}",
            "department": "Seguridad & Compliance",
            "suggested_role": "viewer",
        },
        {
            "username": "admin_ad",
            "full_name": "Administrador Dominio AD",
            "email": f"admin_ad@{domain_suffix}",
            "ad_dn": f"CN=Domain Admin,OU=Admins,{base_dn}",
            "department": "Arquitectura TI",
            "suggested_role": "admin",
        },
    ]

    # Si el usuario escribió un username específico que no está en la lista de muestra, también lo generamos como candidato del AD
    if q and not any(q in e["username"].lower() or q in e["full_name"].lower() for e in directory_entries):
        clean_u = q.split("@")[0].replace(" ", ".")
        directory_entries.insert(
            0,
            {
                "username": clean_u,
                "full_name": f"{clean_u.capitalize()} ({srv.name})",
                "email": f"{clean_u}@{domain_suffix}",
                "ad_dn": f"CN={clean_u},OU=Users,{base_dn}",
                "department": "Directorio Activo",
                "suggested_role": srv.default_role,
            },
        )
    elif q:
        directory_entries = [
            e
            for e in directory_entries
            if q in e["username"].lower()
            or q in e["full_name"].lower()
            or q in e["department"].lower()
        ]

    existing_usernames = {u.username for u in db.query(User).all()}
    for item in directory_entries:
        item["already_registered"] = item["username"] in existing_usernames

    return {
        "ad_server_id": srv.id,
        "ad_server_name": srv.name,
        "domain": domain_suffix,
        "results": directory_entries,
    }


@app.post("/api/ad-servers/{ad_id}/import-users")
def import_ad_users(
    ad_id: int,
    payload: ADUserImportRequest,
    db: Session = Depends(get_db),
):
    srv = db.query(ADServer).filter(ADServer.id == ad_id).first()
    if not srv:
        raise HTTPException(status_code=404, detail="Servidor AD no encontrado")

    imported = []
    for item in payload.users:
        uname = item.username.strip()
        if not uname:
            continue
        role = item.role if item.role in VALID_ROLES else srv.default_role
        user = db.query(User).filter(User.username == uname).first()
        if user:
            user.role = role
            user.auth_source = "ad"
            user.ad_server_id = srv.id
            user.ad_dn = item.ad_dn or user.ad_dn
            user.full_name = item.full_name or user.full_name
            user.email = item.email or user.email
            user.is_active = True
        else:
            user = User(
                username=uname,
                full_name=item.full_name or uname,
                email=item.email or f"{uname}@{srv.domain or 'corp.local'}",
                password_hash=uname,
                role=role,
                auth_source="ad",
                ad_server_id=srv.id,
                ad_dn=item.ad_dn or f"CN={uname},{srv.base_dn}",
                is_active=True,
            )
            db.add(user)
        imported.append(uname)

    db.commit()
    return {"status": "ok", "imported_count": len(imported), "usernames": imported}
