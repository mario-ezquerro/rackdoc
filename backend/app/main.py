from contextlib import asynccontextmanager
from pathlib import Path
from typing import Optional
import uuid
import base64
import json
import urllib.parse
import urllib.request
from fastapi import FastAPI, Depends, HTTPException, UploadFile, File, Form
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse, FileResponse, Response
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
    FloorDevice,
)
from .schemas import (
    DeviceTemplateSchema,
    DeviceTemplateCreate,
    DeviceTemplateUpdate,
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
    FloorDeviceCreate,
    FloorDeviceUpdate,
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
from .services.excel_export import (
    generate_datacenter_excel,
    generate_excel_import_template,
    import_datacenter_excel,
)


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
        "ALTER TABLE ad_servers ADD COLUMN group_role_mapping JSON DEFAULT '[]'",
    ]
    with engine.begin() as conn:
        for stmt in alter_statements:
            try:
                conn.execute(text(stmt))
            except Exception:
                pass


_TRANSPARENT_1X1_PNG = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
)


def _sanitize_missing_upload_urls(db: Session):
    """Limpia URLs de planos subidos cuyo archivo físico ya no exista en disco."""
    changed = False
    for model_cls in (Location, Floor, Room):
        rows = db.query(model_cls).all()
        for row in rows:
            url = (getattr(row, "map_image_url", None) or "").strip()
            if url.startswith("/api/uploads/"):
                fname = url.split("/api/uploads/")[-1].split("?")[0]
                if not (UPLOADS_DIR / fname).is_file():
                    row.map_image_url = ""
                    changed = True
    if changed:
        db.commit()


def _ensure_demo_floor_devices(db: Session):
    """Si aún no hay dispositivos de planta (Cámaras, Control de Acceso, Rosetas, PCs, APs), crea un conjunto de ejemplo conectado al Rack principal."""
    if db.query(FloorDevice).count() > 0:
        return
    first_floor = db.query(Floor).order_by(Floor.id).first()
    if not first_floor:
        return
    first_room = db.query(Room).filter(Room.floor_id == first_floor.id).first()
    first_rack = (
        db.query(Rack).filter(Rack.room_id == first_room.id).first()
        if first_room
        else db.query(Rack).first()
    )
    rk_id = first_rack.id if first_rack else None
    rm_id = first_room.id if first_room else None

    # 1. Rosetas de Telecomunicaciones (conectadas con línea discontinua naranja al Rack)
    outlet_goa = FloorDevice(
        floor_id=first_floor.id,
        room_id=rm_id,
        room_code="GOA",
        device_type="telecom_outlet",
        code="Bi01, Bi02...",
        name="Caja Rosetas Pared Zona GOA (4x RJ45 Cat6A)",
        pos_x=0.33,
        pos_y=0.46,
        status="passive",
        linked_rack_id=rk_id,
        linked_rack_device_code="PP-A:01-04",
        responsible_person="Alex Geng",
        contact_department="Infraestructura IT",
    )
    outlet_oslo = FloorDevice(
        floor_id=first_floor.id,
        room_id=rm_id,
        room_code="OSLO",
        device_type="telecom_outlet",
        code="Bi05, Bi06...",
        name="Caja Rosetas Sala OSLO (4x RJ45 Cat6A)",
        pos_x=0.58,
        pos_y=0.30,
        status="passive",
        linked_rack_id=rk_id,
        linked_rack_device_code="PP-A:05-08",
        responsible_person="Alex Geng",
        contact_department="Infraestructura IT",
    )
    outlet_vienna = FloorDevice(
        floor_id=first_floor.id,
        room_id=rm_id,
        room_code="VIENNA",
        device_type="telecom_outlet",
        code="Bi09, Bi10...",
        name="Caja Rosetas Sala VIENNA (4x RJ45 Cat6A)",
        pos_x=0.62,
        pos_y=0.72,
        status="passive",
        linked_rack_id=rk_id,
        linked_rack_device_code="PP-B:01-04",
        responsible_person="Alex Geng",
        contact_department="Infraestructura IT",
    )
    db.add_all([outlet_goa, outlet_oslo, outlet_vienna])
    db.flush()

    # 2. Cámaras CCTV, Controles de Acceso, APs Wi-Fi, Ordenadores, Teléfonos, Impresoras y Pantallas
    demo_items = [
        FloorDevice(
            floor_id=first_floor.id,
            room_id=rm_id,
            room_code="GOA",
            device_type="camera",
            code="CAM01",
            name="Cámara Domo IP Entrada Noroeste",
            pos_x=0.20,
            pos_y=0.32,
            ip_address="10.28.40.11",
            vlan=40,
            status="online",
            linked_rack_id=rk_id,
            linked_rack_device_code="SW01:Gi1/0/21 (PoE)",
            responsible_person="Alex Geng",
            contact_department="Seguridad Física",
        ),
        FloorDevice(
            floor_id=first_floor.id,
            room_id=rm_id,
            room_code="OSLO",
            device_type="camera",
            code="CAM02",
            name="Cámara Bullet 4K Pasillo Norte",
            pos_x=0.45,
            pos_y=0.16,
            ip_address="10.28.40.12",
            vlan=40,
            status="online",
            linked_rack_id=rk_id,
            linked_rack_device_code="SW01:Gi1/0/22 (PoE)",
            responsible_person="Alex Geng",
            contact_department="Seguridad Física",
        ),
        FloorDevice(
            floor_id=first_floor.id,
            room_id=rm_id,
            room_code="VIENNA",
            device_type="camera",
            code="CAM03",
            name="Cámara Esclusa Sala Racks",
            pos_x=0.72,
            pos_y=0.58,
            ip_address="10.28.40.13",
            vlan=40,
            status="online",
            linked_rack_id=rk_id,
            linked_rack_device_code="SW01:Gi1/0/23 (PoE)",
            responsible_person="Alex Geng",
            contact_department="Seguridad Física",
        ),
        FloorDevice(
            floor_id=first_floor.id,
            room_id=rm_id,
            room_code="CPD-DOOR",
            device_type="access_control",
            code="AC01",
            name="Control de Acceso Biométrico + RFID Puerta CPD",
            pos_x=0.50,
            pos_y=0.52,
            ip_address="10.28.45.10",
            vlan=45,
            status="online",
            linked_rack_id=rk_id,
            linked_rack_device_code="SW01:Gi1/0/24",
            responsible_person="Alex Geng",
            contact_department="Seguridad / Accesos",
        ),
        FloorDevice(
            floor_id=first_floor.id,
            room_id=rm_id,
            room_code="GOA",
            device_type="access_point",
            code="AP01",
            name="Punto de Acceso Wi-Fi 6E Techo GOA",
            pos_x=0.38,
            pos_y=0.42,
            ip_address="10.28.30.21",
            vlan=30,
            status="online",
            linked_rack_id=rk_id,
            linked_rack_device_code="SW01:Gi1/0/18 (PoE+)",
            responsible_person="Alex Geng",
            contact_department="Redes & Wi-Fi",
        ),
        FloorDevice(
            floor_id=first_floor.id,
            room_id=rm_id,
            room_code="OSLO",
            device_type="access_point",
            code="AP02",
            name="Punto de Acceso Wi-Fi 6E Sala OSLO",
            pos_x=0.64,
            pos_y=0.36,
            ip_address="10.28.30.22",
            vlan=30,
            status="online",
            linked_rack_id=rk_id,
            linked_rack_device_code="SW01:Gi1/0/19 (PoE+)",
            responsible_person="Alex Geng",
            contact_department="Redes & Wi-Fi",
        ),
        # Equipos de puesto conectados con línea azul sólida a las Rosetas (Bi01, Bi05, Bi09)
        FloorDevice(
            floor_id=first_floor.id,
            room_id=rm_id,
            room_code="GOA",
            device_type="desktop",
            code="DP01",
            name="Workstation Operador NOC 01",
            pos_x=0.22,
            pos_y=0.44,
            ip_address="10.28.20.101",
            vlan=20,
            status="online",
            linked_outlet_id=outlet_goa.id,
            responsible_person="Alex Geng",
            contact_first_name="Carlos",
            contact_last_name="Mendoza",
            contact_email="cmendoza@rackdoc.local",
            contact_department="Operaciones NOC",
        ),
        FloorDevice(
            floor_id=first_floor.id,
            room_id=rm_id,
            room_code="GOA",
            device_type="desktop",
            code="DP02",
            name="Workstation Operador NOC 02",
            pos_x=0.26,
            pos_y=0.36,
            ip_address="10.28.20.102",
            vlan=20,
            status="online",
            linked_outlet_id=outlet_goa.id,
            responsible_person="Alex Geng",
            contact_first_name="Laura",
            contact_last_name="Sánchez",
            contact_email="lsanchez@rackdoc.local",
            contact_department="Operaciones NOC",
        ),
        FloorDevice(
            floor_id=first_floor.id,
            room_id=rm_id,
            room_code="GOA",
            device_type="phone",
            code="PH01",
            name="Teléfono IP VoIP Guardia NOC",
            pos_x=0.29,
            pos_y=0.55,
            ip_address="10.28.50.11",
            vlan=50,
            status="online",
            linked_outlet_id=outlet_goa.id,
            responsible_person="Alex Geng",
            contact_department="Voz IP",
        ),
        FloorDevice(
            floor_id=first_floor.id,
            room_id=rm_id,
            room_code="OSLO",
            device_type="laptop",
            code="LP01",
            name="Portátil Ingeniería Sistemas",
            pos_x=0.55,
            pos_y=0.20,
            ip_address="10.28.20.115",
            vlan=20,
            status="online",
            linked_outlet_id=outlet_oslo.id,
            responsible_person="Alex Geng",
            contact_department="Ingeniería",
        ),
        FloorDevice(
            floor_id=first_floor.id,
            room_id=rm_id,
            room_code="VIENNA",
            device_type="printer",
            code="PR01",
            name="Impresora Multifunción Red Planta",
            pos_x=0.56,
            pos_y=0.80,
            ip_address="10.28.25.50",
            vlan=25,
            status="online",
            linked_outlet_id=outlet_vienna.id,
            responsible_person="Alex Geng",
            contact_department="Servicios Generales",
        ),
        FloorDevice(
            floor_id=first_floor.id,
            room_id=rm_id,
            room_code="VIENNA",
            device_type="screen",
            code="SC01",
            name="Videowall Monitorización NOC 75\"",
            pos_x=0.70,
            pos_y=0.76,
            ip_address="10.28.25.60",
            vlan=25,
            status="online",
            linked_outlet_id=outlet_vienna.id,
            responsible_person="Alex Geng",
            contact_department="NOC Display",
        ),
    ]
    db.add_all(demo_items)
    db.commit()


@asynccontextmanager
async def lifespan(app: FastAPI):
    Base.metadata.create_all(bind=engine)
    _ensure_db_migrations()
    db = SessionLocal()
    try:
        seed_initial_data(db)
        sync_system_defaults(db)
        _ensure_demo_floor_devices(db)
        _sanitize_missing_upload_urls(db)
    finally:
        db.close()
    yield


app = FastAPI(
    title="RackDoc DCIM API",
    description="API de Gestión Visual de Centros de Datos, Racks (Front/Back), Planos JPG/PNG/GIF, Red, Monitorización y Exportación Excel",
    version="1.2.0",
    lifespan=lifespan,
)


@app.get("/api/uploads/{filename}")
def get_uploaded_plan_file(filename: str, db: Session = Depends(get_db)):
    safe_name = Path(filename).name
    file_path = UPLOADS_DIR / safe_name
    if file_path.is_file():
        return FileResponse(str(file_path))
    _sanitize_missing_upload_urls(db)
    return Response(content=_TRANSPARENT_1X1_PNG, media_type="image/png")

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


@app.get("/api/health")
def health_check():
    return {"status": "ok", "service": "rackdoc-backend"}


@app.get("/api/locations")
def get_locations_tree(db: Session = Depends(get_db)):
    _sanitize_missing_upload_urls(db)
    locations = (
        db.query(Location)
        .options(
            joinedload(Location.floors)
            .joinedload(Floor.rooms)
            .joinedload(Room.racks)
            .joinedload(Rack.devices)
            .joinedload(RackDevice.template),
            joinedload(Location.floors)
            .joinedload(Floor.rooms)
            .joinedload(Room.aisles),
            joinedload(Location.floors)
            .joinedload(Floor.floor_devices),
        )
        .all()
    )

    result = []
    for loc in locations:
        floors_count = len(loc.floors)
        rooms_count = 0
        racks_count = 0
        total_rack_units = 0
        loc_monitored = 0
        loc_online = 0
        loc_offline = 0
        loc_warning = 0
        floors_data = []

        for fl in sorted(loc.floors, key=lambda x: x.level_number):
            rooms_count += len(fl.rooms)
            fl_monitored = 0
            fl_online = 0
            fl_offline = 0
            fl_warning = 0
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
                    rack_devs = [d for d in rk.devices if d.mounted_face != "external"]
                    mon_devs = [d for d in rack_devs if d.monitoring_enabled]
                    rk_mon = len(mon_devs)
                    rk_on = len([d for d in mon_devs if d.status == "online"])
                    rk_off = len([d for d in mon_devs if d.status == "offline"])
                    rk_warn = rk_mon - rk_on - rk_off

                    fl_monitored += rk_mon
                    fl_online += rk_on
                    fl_offline += rk_off
                    fl_warning += rk_warn

                    monitored_list = [
                        {
                            "id": d.id,
                            "code": d.code,
                            "name": d.name,
                            "hostname": d.hostname or "",
                            "fqdn": d.fqdn or "",
                            "ip_address": d.ip_address or "",
                            "start_u": d.start_u,
                            "u_height": _effective_device_u_height(d.template, d.custom_fields),
                            "category": d.template.category if d.template else "server",
                            "manufacturer": d.template.manufacturer if d.template else "",
                            "model_name": d.template.model_name if d.template else "",
                            "monitoring_enabled": d.monitoring_enabled,
                            "monitor_method": d.monitor_method or "icmp",
                            "monitor_port": d.monitor_port or 22,
                            "status": d.status or "unknown",
                            "last_ping_ms": d.last_ping_ms,
                            "custom_fields": d.custom_fields or {},
                            "rack_id": rk.id,
                            "rack_code": rk.code,
                            "rack_name": rk.name,
                            "floor_name": fl.name,
                            "room_name": rm.name,
                            "location_id": loc.id,
                            "location_code": loc.code,
                            "location_name": loc.name,
                        }
                        for d in rack_devs
                    ]

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
                            "device_count": len(rack_devs),
                            "monitored_count": rk_mon,
                            "online_count": rk_on,
                            "offline_count": rk_off,
                            "warning_count": rk_warn,
                            "monitored_devices": monitored_list,
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
            loc_monitored += fl_monitored
            loc_online += fl_online
            loc_offline += fl_offline
            loc_warning += fl_warning
            floor_devices_data = [
                {
                    "id": fd.id,
                    "floor_id": fd.floor_id,
                    "room_id": fd.room_id,
                    "room_code": fd.room_code or "GOA",
                    "device_type": fd.device_type,
                    "code": fd.code,
                    "name": fd.name,
                    "pos_x": fd.pos_x if fd.pos_x is not None else 0.5,
                    "pos_y": fd.pos_y if fd.pos_y is not None else 0.5,
                    "ip_address": fd.ip_address or "",
                    "mac_address": fd.mac_address or "",
                    "vlan": fd.vlan,
                    "status": fd.status or "online",
                    "linked_rack_id": fd.linked_rack_id,
                    "linked_rack_device_code": fd.linked_rack_device_code or "",
                    "linked_outlet_id": fd.linked_outlet_id,
                    "responsible_person": fd.responsible_person or "Alex Geng",
                    "contact_first_name": fd.contact_first_name or "",
                    "contact_last_name": fd.contact_last_name or "",
                    "contact_email": fd.contact_email or "",
                    "contact_phone": fd.contact_phone or "",
                    "contact_job_title": fd.contact_job_title or "",
                    "contact_department": fd.contact_department or "",
                    "notes": fd.notes or "",
                }
                for fd in sorted(fl.floor_devices, key=lambda x: x.code)
            ]
            floors_data.append(
                {
                    "id": fl.id,
                    "name": fl.name,
                    "level_number": fl.level_number,
                    "map_image_url": fl.map_image_url or "",
                    "map_scale": fl.map_scale or 1.0,
                    "monitored_count": fl_monitored,
                    "online_count": fl_online,
                    "offline_count": fl_offline,
                    "warning_count": fl_warning,
                    "rooms": rooms_data,
                    "floor_devices": floor_devices_data,
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
                "monitored_count": loc_monitored,
                "online_count": loc_online,
                "offline_count": loc_offline,
                "warning_count": loc_warning,
                "floors": floors_data,
            }
        )
    return result


@app.post("/api/locations")
def create_location(payload: LocationCreate, db: Session = Depends(get_db)):
    data = payload.model_dict() if hasattr(payload, "model_dict") else payload.model_dump()
    raw_code = (data.get("code") or "CPD").strip() or "CPD"
    final_code = raw_code
    suffix = 2
    while db.query(Location).filter(Location.code == final_code).first() is not None:
        final_code = f"{raw_code}-{suffix:02d}"
        suffix += 1
    data["code"] = final_code

    loc = Location(**data)
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
    updates = payload.model_dump(exclude_unset=True)
    if "code" in updates and updates["code"]:
        new_code = updates["code"].strip()
        dup = (
            db.query(Location)
            .filter(Location.code == new_code, Location.id != location_id)
            .first()
        )
        if dup:
            raise HTTPException(
                status_code=409,
                detail=f"Ya existe otro Datacenter con el código '{new_code}'.",
            )
        updates["code"] = new_code
    for k, v in updates.items():
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


@app.post("/api/floors/{floor_id}/floor-devices")
def create_floor_device(
    floor_id: int,
    payload: FloorDeviceCreate,
    db: Session = Depends(get_db),
):
    fl = db.query(Floor).filter(Floor.id == floor_id).first()
    if not fl:
        raise HTTPException(status_code=404, detail="Planta no encontrada")
    data = payload.model_dump()
    if data.get("room_id") is None and fl.rooms:
        data["room_id"] = fl.rooms[0].id
    fd = FloorDevice(floor_id=floor_id, **data)
    db.add(fd)
    db.commit()
    db.refresh(fd)
    return {
        "id": fd.id,
        "floor_id": fd.floor_id,
        "device_type": fd.device_type,
        "code": fd.code,
        "name": fd.name,
        "pos_x": fd.pos_x,
        "pos_y": fd.pos_y,
    }


@app.put("/api/floor-devices/{device_id}")
def update_floor_device(
    device_id: int,
    payload: FloorDeviceUpdate,
    db: Session = Depends(get_db),
):
    fd = db.query(FloorDevice).filter(FloorDevice.id == device_id).first()
    if not fd:
        raise HTTPException(status_code=404, detail="Dispositivo de planta no encontrado")
    updates = payload.model_dump(exclude_unset=True)
    for k, v in updates.items():
        setattr(fd, k, v)
    db.commit()
    db.refresh(fd)
    return {"status": "ok", "id": fd.id}


@app.delete("/api/floor-devices/{device_id}")
def delete_floor_device(device_id: int, db: Session = Depends(get_db)):
    fd = db.query(FloorDevice).filter(FloorDevice.id == device_id).first()
    if not fd:
        raise HTTPException(status_code=404, detail="Dispositivo de planta no encontrado")
    # Desvincular otros dispositivos que apuntasen a esta roseta
    db.query(FloorDevice).filter(FloorDevice.linked_outlet_id == device_id).update(
        {"linked_outlet_id": None}
    )
    db.delete(fd)
    db.commit()
    return {"status": "deleted", "id": device_id}


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


@app.get("/api/templates/photo-proxy")
def proxy_hardware_photo(url: str):
    """Proxy de imágenes externas para evitar bloqueos CORS en Flutter Web."""
    target = (url or "").strip()
    if not target.startswith(("http://", "https://")):
        raise HTTPException(status_code=400, detail="URL inválida")
    try:
        req = urllib.request.Request(
            target,
            headers={
                "User-Agent": "RackDoc8-DCIM/1.4 (https://github.com/mario-ezquerro/rackdoc)",
                "Accept": "image/*,*/*;q=0.8",
            },
        )
        with urllib.request.urlopen(req, timeout=8) as resp:
            content = resp.read()
            ctype = resp.headers.get("Content-Type", "image/jpeg")
            return Response(
                content=content,
                media_type=ctype,
                headers={
                    "Access-Control-Allow-Origin": "*",
                    "Cache-Control": "public, max-age=86400",
                },
            )
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"No se pudo cargar imagen: {exc}")


@app.get("/api/templates/search-photo")
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


@app.put("/api/templates/{template_id}", response_model=DeviceTemplateSchema)
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


@app.get("/api/racks/{rack_id}/inter-rack-targets")
def get_inter_rack_targets(rack_id: int, db: Session = Depends(get_db)):
    """Devuelve todos los demás Racks del CPD con sus equipos y puertos libres/ocupados para conectar fibras/cables Inter-Rack."""
    all_racks = (
        db.query(Rack)
        .options(
            joinedload(Rack.room).joinedload(Room.floor).joinedload(Floor.location),
            joinedload(Rack.aisle),
            joinedload(Rack.devices).joinedload(RackDevice.template),
            joinedload(Rack.devices).joinedload(RackDevice.ports),
        )
        .filter(Rack.id != rack_id)
        .all()
    )

    all_conns = db.query(Connection).all()
    occupied_port_ids = set()
    for c in all_conns:
        occupied_port_ids.add(c.source_port_id)
        occupied_port_ids.add(c.target_port_id)

    out = []
    for rk in all_racks:
        loc = rk.room.floor.location if (rk.room and rk.room.floor) else None
        devs_out = []
        for d in sorted(rk.devices, key=lambda x: x.start_u, reverse=True):
            if d.mounted_face == "external":
                continue
            ports_out = [
                {
                    "id": p.id,
                    "port_number": p.port_number,
                    "port_type": p.port_type,
                    "face": p.face,
                    "occupied": p.id in occupied_port_ids,
                }
                for p in d.ports
            ]
            if not ports_out:
                continue
            devs_out.append(
                {
                    "id": d.id,
                    "code": d.code,
                    "name": d.name,
                    "start_u": d.start_u,
                    "u_height": _effective_device_u_height(d.template, d.custom_fields),
                    "category": d.template.category if d.template else "server",
                    "manufacturer": d.template.manufacturer if d.template else "",
                    "model_name": d.template.model_name if d.template else "",
                    "ports": ports_out,
                }
            )
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
                "devices": devs_out,
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

    ext_devs = [d for d in rack.devices if d.mounted_face == "external"]
    has_power_ext = any(
        (d.custom_fields or {}).get("feed_type", "power") == "power"
        for d in ext_devs
    )
    has_fiber_ext = any(
        (d.custom_fields or {}).get("feed_type") == "fiber"
        for d in ext_devs
    )
    if not has_power_ext or not has_fiber_ext:
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

    ext_devs = [d for d in rack.devices if d.mounted_face == "external"]
    has_power_ext = any(
        (d.custom_fields or {}).get("feed_type", "power") == "power"
        for d in ext_devs
    )
    has_fiber_ext = any(
        (d.custom_fields or {}).get("feed_type") == "fiber"
        for d in ext_devs
    )
    if not has_power_ext or not has_fiber_ext:
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

    ext_devs = [d for d in rack.devices if d.mounted_face == "external"]
    has_power_ext = any(
        (d.custom_fields or {}).get("feed_type", "power") == "power"
        for d in ext_devs
    )
    has_fiber_ext = any(
        (d.custom_fields or {}).get("feed_type") == "fiber"
        for d in ext_devs
    )
    if not has_power_ext or not has_fiber_ext:
        ensure_rack_external_outlets(db, rack)
        db.commit()
        db.refresh(rack)

    template = db.query(DeviceTemplate).filter(DeviceTemplate.id == payload.template_id).first()
    if not template:
        raise HTTPException(status_code=404, detail="Plantilla de dispositivo no encontrada")

    effective_u_height = _effective_device_u_height(template, payload.custom_fields)
    _check_u_collision(
        db=db,
        rack=rack,
        start_u=payload.start_u,
        u_height=effective_u_height,
        mounted_face=payload.mounted_face,
        is_full_depth=template.is_full_depth,
    )

    default_links = payload.management_links
    if not default_links and template.category in (
        "switch",
        "router",
        "firewall",
        "server",
        "pdu",
        "ups",
        "gateway",
        "storage_san",
        "storage_nas",
    ):
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
    if (payload.custom_fields or {}).get("tray_items") is not None:
        _sync_tray_items_ports(db, device)
    elif (payload.custom_fields or {}).get("custom_layout_spec") is not None:
        _sync_custom_device_ports(db, device)
    db.commit()
    db.refresh(device)
    return device


def _sync_custom_device_ports(db: Session, device: RackDevice):
    """Sincroniza los puertos Front y Back de un equipo montado a partir de custom_fields['custom_layout_spec']."""
    cf = dict(device.custom_fields or {})
    spec = cf.get("custom_layout_spec")
    if not isinstance(spec, dict):
        return

    existing_by_key = {(p.face, p.port_number): p for p in list(device.ports)}
    desired_keys: set[tuple[str, str]] = set()

    for tpl_face in ("front", "back"):
        face_groups = list(spec.get(tpl_face) or [])
        if device.mounted_face == "back":
            effective_face = "back" if tpl_face == "front" else "front"
        else:
            effective_face = tpl_face

        for group in face_groups:
            port_type = str(group.get("port_type", "rj45"))
            prefix = str(group.get("prefix", ""))
            count = int(group.get("count", 0))
            if count <= 0:
                continue
            rows = max(1, int(group.get("rows", 1)))
            start_x = float(group.get("start_x", 0.12))
            end_x = float(group.get("end_x", 0.88))
            start_num = int(group.get("start_num", 1))

            cols = max(1, (count + rows - 1) // rows)
            for idx in range(count):
                r = idx % rows
                c = idx // rows
                num = start_num + idx
                p_num = f"{prefix}{num}" if prefix else str(num)
                rel_x = (
                    start_x + (end_x - start_x) * (c / max(1, cols - 1))
                    if cols > 1
                    else (start_x + end_x) / 2.0
                )
                rel_y = (
                    0.32 if (rows > 1 and r == 0) else (0.68 if rows > 1 else 0.5)
                )
                key = (effective_face, p_num)
                desired_keys.add(key)
                if key in existing_by_key:
                    ep = existing_by_key[key]
                    ep.port_type = port_type
                    ep.row_index = r
                    ep.col_index = c
                    ep.rel_x = round(rel_x, 4)
                    ep.rel_y = round(rel_y, 4)
                    ep.label = f"{device.code}:{p_num}"
                else:
                    db.add(
                        Port(
                            rack_device_id=device.id,
                            port_number=p_num,
                            label=f"{device.code}:{p_num}",
                            face=effective_face,
                            port_type=port_type,
                            row_index=r,
                            col_index=c,
                            rel_x=round(rel_x, 4),
                            rel_y=round(rel_y, 4),
                        )
                    )

    stale_ports = [p for k, p in existing_by_key.items() if k not in desired_keys]
    if stale_ports:
        stale_ids = [p.id for p in stale_ports]
        _delete_connections_for_port_ids(db, stale_ids)
        for sp in stale_ports:
            db.delete(sp)
    db.flush()


def _sync_tray_items_ports(db: Session, device: RackDevice):
    """Sincroniza los puertos reales (Front y Back) de todos los mini-equipos colocados encima de una Bandeja."""
    cf = dict(device.custom_fields or {})
    tray_items = list(cf.get("tray_items") or [])
    existing_by_key = {(p.face, p.port_number): p for p in list(device.ports)}
    desired_keys: set[tuple[str, str]] = set()

    n = len(tray_items)
    if n > 0:
        seg_w = 0.90 / n
        for idx, item in enumerate(tray_items):
            item_code = str(item.get("code") or f"EQ{idx + 1}").strip()
            tpl_id = item.get("template_id")
            tpl = (
                db.query(DeviceTemplate).filter(DeviceTemplate.id == int(tpl_id)).first()
                if tpl_id
                else None
            )
            # Priorizar layout_spec personalizado del ítem (si el usuario definió bocas Front/Back específicas)
            item_spec = item.get("layout_spec")
            spec = dict(
                (item_spec if isinstance(item_spec, dict) and item_spec else (tpl.layout_spec if tpl else None))
                or {}
            )
            front_groups = list(
                spec.get("front")
                if "front" in spec
                else [
                    {"port_type": "rj45", "prefix": "ETH", "count": 2},
                ]
            )
            back_groups = list(
                spec.get("back")
                if "back" in spec
                else [
                    {"port_type": "power_c14", "prefix": "DC", "count": 1},
                ]
            )

            box_left = 0.05 + idx * seg_w + 0.02
            box_right = 0.05 + (idx + 1) * seg_w - 0.02

            for face_name, groups in (("front", front_groups), ("back", back_groups)):
                flat_ports: list[tuple[str, str]] = []
                for g in groups:
                    p_type = str(g.get("port_type", "rj45"))
                    prefix = str(g.get("prefix", "P"))
                    cnt = max(1, int(g.get("count", 1)))
                    for k in range(1, cnt + 1):
                        p_short = f"{prefix}{k}" if cnt > 1 or not prefix else prefix
                        flat_ports.append((f"{item_code}-{p_short}", p_type))

                total_p = len(flat_ports)
                for p_i, (p_num, p_type) in enumerate(flat_ports):
                    rx = (
                        (box_left + box_right) / 2.0
                        if total_p <= 1
                        else box_left
                        + (box_right - box_left) * (p_i / float(total_p - 1))
                    )
                    ry = 0.62 if face_name == "front" else 0.56
                    key = (face_name, p_num)
                    desired_keys.add(key)
                    if key in existing_by_key:
                        ep = existing_by_key[key]
                        ep.port_type = p_type
                        ep.rel_x = round(rx, 4)
                        ep.rel_y = round(ry, 4)
                        ep.col_index = p_i
                        ep.label = f"{device.code}:{p_num}"
                    else:
                        db.add(
                            Port(
                                rack_device_id=device.id,
                                port_number=p_num,
                                label=f"{device.code}:{p_num}",
                                face=face_name,
                                port_type=p_type,
                                row_index=0,
                                col_index=p_i,
                                rel_x=round(rx, 4),
                                rel_y=round(ry, 4),
                            )
                        )

    stale_ports = [p for k, p in existing_by_key.items() if k not in desired_keys]
    if stale_ports:
        stale_ids = [p.id for p in stale_ports]
        _delete_connections_for_port_ids(db, stale_ids)
        for sp in stale_ports:
            db.delete(sp)
    db.flush()


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
    new_custom_fields = updates.get("custom_fields", device.custom_fields)
    old_u_height = _effective_device_u_height(device.template, device.custom_fields)
    new_u_height = _effective_device_u_height(device.template, new_custom_fields)

    if (
        new_start_u != device.start_u
        or new_face != device.mounted_face
        or new_u_height != old_u_height
    ):
        _check_u_collision(
            db=db,
            rack=device.rack,
            start_u=new_start_u,
            u_height=new_u_height,
            mounted_face=new_face,
            is_full_depth=True,
            exclude_device_id=device.id,
        )

    for k, v in updates.items():
        setattr(device, k, v)

    if "custom_fields" in updates:
        if (device.custom_fields or {}).get("tray_items") is not None:
            _sync_tray_items_ports(db, device)
        elif (device.custom_fields or {}).get("custom_layout_spec") is not None:
            _sync_custom_device_ports(db, device)

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

    ext_devs = [d for d in rack.devices if d.mounted_face == "external"]
    has_power_ext = any(
        (d.custom_fields or {}).get("feed_type", "power") == "power"
        for d in ext_devs
    )
    has_fiber_ext = any(
        (d.custom_fields or {}).get("feed_type") == "fiber"
        for d in ext_devs
    )
    if not has_power_ext or not has_fiber_ext:
        ensure_rack_external_outlets(db, rack)
        db.commit()
        db.refresh(rack)

    tpl = get_or_create_external_feed_template(db)
    f_type = "fiber" if (payload.feed_type or "").lower() == "fiber" else "power"
    max_sc = 48 if f_type == "fiber" else 16
    sc_val = max(1, min(max_sc, payload.socket_count))
    dev = RackDevice(
        rack_id=rack.id,
        template_id=tpl.id,
        code=payload.code.strip() or ("FIBRA-EXT" if f_type == "fiber" else "TOMA-EXT"),
        name=payload.name.strip()
        or (
            "Toma Exterior de Fibra Óptica (LC/SC)"
            if f_type == "fiber"
            else "Línea Eléctrica Exterior (Schuko)"
        ),
        hostname=payload.code.strip().lower(),
        start_u=max(1, min(rack.total_units, payload.start_u)),
        mounted_face="external",
        status="online",
        custom_fields={
            "is_external_feed": True,
            "feed_type": f_type,
            "feed_color": payload.color_hex,
            "socket_count": sc_val,
        },
        notes=(
            "Caja / Toma exterior de Fibra Óptica"
            if f_type == "fiber"
            else "Acometida eléctrica Schuko exterior al rack"
        ),
    )
    db.add(dev)
    db.flush()
    sync_external_outlet_ports(db, dev, sc_val)
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
    if payload.feed_type is not None:
        cf["feed_type"] = "fiber" if payload.feed_type.lower() == "fiber" else "power"
    f_type = str(cf.get("feed_type") or "power").lower()
    max_sc = 48 if f_type == "fiber" else 16

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

    if payload.socket_count is not None or payload.feed_type is not None:
        raw_sc = payload.socket_count if payload.socket_count is not None else int(cf.get("socket_count") or 4)
        sc = max(1, min(max_sc, raw_sc))
        cf["socket_count"] = sc
        dev.custom_fields = cf
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
    # Si uno de los extremos es una toma exterior (Eléctrica Schuko o Fibra Óptica), el cable adopta su color y tipo
    for end_dev in (sp.device, tp.device):
        if end_dev.mounted_face == "external":
            cf = end_dev.custom_fields or {}
            feed_color = cf.get("feed_color")
            feed_type = str(cf.get("feed_type") or "power").lower()
            if feed_color:
                conn_data["color_hex"] = feed_color
            conn_data["cable_type"] = "fiber_om4" if feed_type == "fiber" else "power_ac"
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


@app.get("/api/reports/excel/template")
def download_excel_import_template():
    excel_io = generate_excel_import_template()
    return StreamingResponse(
        excel_io,
        media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        headers={
            "Content-Disposition": 'attachment; filename="RackDoc_Plantilla_Importacion_Ejemplo.xlsx"'
        },
    )


@app.post("/api/reports/excel/import")
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

    # Mapa de grupos AD -> rol RBAC configurado en este servidor AD
    group_map = {}
    for gm in (srv.group_role_mapping or []):
        gname = str(gm.get("group_name", "")).lower()
        gdn = str(gm.get("group_dn", "")).lower()
        r = str(gm.get("role", srv.default_role))
        if gname:
            group_map[gname] = r
        if gdn:
            group_map[gdn] = r

    # Catálogo de cuentas del directorio AD para explorar/filtrar e importar con rol asignado por grupo o usuario
    directory_entries = [
        {
            "username": "jgarcia",
            "full_name": "Javier García (NetOps AD)",
            "email": f"jgarcia@{domain_suffix}",
            "ad_dn": f"CN=Javier Garcia,OU=NetOps,{base_dn}",
            "ad_group": "NetOps & SysAdmins (Ingeniería CPD)",
            "department": "Infraestructura & Redes",
            "suggested_role": group_map.get("netops & sysadmins (ingeniería cpd)", "editor"),
        },
        {
            "username": "mfernandez",
            "full_name": "Marta Fernández (SysAdmin AD)",
            "email": f"mfernandez@{domain_suffix}",
            "ad_dn": f"CN=Marta Fernandez,OU=Sistemas,{base_dn}",
            "ad_group": "NetOps & SysAdmins (Ingeniería CPD)",
            "department": "Sistemas & Virtualización",
            "suggested_role": group_map.get("netops & sysadmins (ingeniería cpd)", "editor"),
        },
        {
            "username": "rnavarro",
            "full_name": "Roberto Navarro (Guardia NOC SSH/Web)",
            "email": f"rnavarro@{domain_suffix}",
            "ad_dn": f"CN=Roberto Navarro,OU=NOC,{base_dn}",
            "ad_group": "NOC 24x7 & Guardia Operaciones (SSH/Web)",
            "department": "Operaciones 24x7 (SSH & Web)",
            "suggested_role": group_map.get("noc 24x7 & guardia operaciones (ssh/web)", "operator"),
        },
        {
            "username": "elopez",
            "full_name": "Elena López (Auditoría TI)",
            "email": f"elopez@{domain_suffix}",
            "ad_dn": f"CN=Elena Lopez,OU=Auditoria,{base_dn}",
            "ad_group": "Auditores & Seguridad Compliance",
            "department": "Seguridad & Compliance",
            "suggested_role": group_map.get("auditores & seguridad compliance", "viewer"),
        },
        {
            "username": "admin_ad",
            "full_name": "Administrador Dominio AD",
            "email": f"admin_ad@{domain_suffix}",
            "ad_dn": f"CN=Domain Admin,OU=Admins,{base_dn}",
            "ad_group": "Domain Admins / Arquitectura TI",
            "department": "Arquitectura TI",
            "suggested_role": group_map.get("domain admins / arquitectura ti", "admin"),
        },
    ]

    # Si el usuario escribió un username específico que no está en la lista de muestra, también lo generamos como candidato del AD
    if q and not any(
        q in e["username"].lower()
        or q in e["full_name"].lower()
        or q in e.get("ad_group", "").lower()
        for e in directory_entries
    ):
        clean_u = q.split("@")[0].replace(" ", ".")
        directory_entries.insert(
            0,
            {
                "username": clean_u,
                "full_name": f"{clean_u.capitalize()} ({srv.name})",
                "email": f"{clean_u}@{domain_suffix}",
                "ad_dn": f"CN={clean_u},OU=Users,{base_dn}",
                "ad_group": "Domain Users",
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
            or q in e.get("ad_group", "").lower()
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
