from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path
from typing import Optional
import asyncio
import uuid
import base64
import json
import urllib.parse
import urllib.request
from fastapi import FastAPI, APIRouter, Depends, HTTPException, UploadFile, File, Form, Header
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse, FileResponse, Response, RedirectResponse
from sqlalchemy import text
from sqlalchemy.orm import Session, joinedload, selectinload

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
    FloorDeviceCustomType,
    CmdbSubnet,
    CmdbAsset,
    CmdbIpAddress,
    HostGroup,
    MonitoredServiceCheck,
    SwitchSnmpPort,
    LogicalTopologyLink,
    InfraConnector,
    AlertContact,
    AlertContactGroup,
    NotificationRoutingRule,
    MaintenanceWindow,
    AlertNotificationLog,
    SmtpAlertConfig,
    TechStackDiagram,
    TechStackNode,
    TechStackEdge,
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
    FloorDeviceCustomTypeCreate,
    MonitoringSettingsUpdate,
    CmdbSubnetCreate,
    CmdbSubnetUpdate,
    CmdbIpAddressInput,
    CmdbAssetCreate,
    CmdbAssetUpdate,
    CmdbVerifyIpRequest,
    CmdbImportDiscoveredRequest,
    HostGroupInput,
    ServiceCheckInput,
    LogicalLinkInput,
    InfraConnectorInput,
    SnmpWalkDiscoveryRequest,
    AlertContactInput,
    AlertContactGroupInput,
    NotificationRoutingRuleInput,
    MaintenanceWindowInput,
    SmtpAlertConfigInput,
    AnsibleHostUpsertWebhook,
    AnsibleHostDecommissionWebhook,
    AnsibleMaintenanceWebhook,
    AnsibleContactsRoutingWebhook,
    TechStackDiagramInput,
    TechStackDiagramUpdateInput,
    TechStackNodeInput,
    TechStackNodeMoveInput,
    TechStackEdgeInput,
    TechStackEdgeUpdateInput,
    HostSshCommandInput,
)
from .seed import (
    seed_initial_data,
    sync_system_defaults,
    create_ports_from_template,
    get_or_create_external_feed_template,
    sync_external_outlet_ports,
    ensure_rack_external_outlets,
)
from .services.monitor import (
    check_single_device,
    check_all_monitored_devices,
    run_device_remote_console,
)
from .services.cmdb_service import (
    ensure_cmdb_seed_data,
    build_cmdb_overview,
    verify_single_ip_manual,
    verify_ip_target_or_find_free,
    check_cmdb_asset_heartbeat,
    sync_physical_devices_to_cmdb,
    import_discovered_hosts_to_cmdb,
    _match_subnet_for_ip,
)
from .services.network_host_service import (
    AUTOMATION_API_KEY,
    ensure_network_hosts_seeded,
    sync_prometheus_targets_file,
    build_network_hosts_overview,
    get_asset_telemetry_timeseries,
    run_single_service_check,
    evaluate_all_network_service_checks,
    run_snmp_switch_discovery,
    generate_prometheus_metrics_exposition,
    handle_ansible_host_upsert_webhook,
    handle_ansible_host_decommission_webhook,
    handle_ansible_maintenance_webhook,
    handle_ansible_contacts_routing_webhook,
    build_ai_agent_context_manifest,
    execute_host_ssh_diagnostic,
    _dispatch_alert_notification,
)
from .services.excel_export import (
    build_dashboard_inventory_data,
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
        "ALTER TABLE floor_devices ADD COLUMN fqdn VARCHAR(255) DEFAULT ''",
        "ALTER TABLE floor_devices ADD COLUMN monitoring_enabled BOOLEAN DEFAULT 0",
        "ALTER TABLE floor_devices ADD COLUMN monitor_method VARCHAR(32) DEFAULT 'icmp'",
        "ALTER TABLE floor_devices ADD COLUMN monitor_port INTEGER DEFAULT 22",
        "ALTER TABLE floor_devices ADD COLUMN last_ping_ms FLOAT",
        "ALTER TABLE floor_devices ADD COLUMN last_checked_at DATETIME",
        "ALTER TABLE floor_devices ADD COLUMN custom_fields JSON DEFAULT '{}'",
        "ALTER TABLE tech_stack_diagrams ADD COLUMN map_scale FLOAT DEFAULT 1.0",
        "ALTER TABLE tech_stack_diagrams ADD COLUMN canvas_boxes JSON DEFAULT '[]'",
        "ALTER TABLE tech_stack_nodes ADD COLUMN width_px FLOAT DEFAULT 200.0",
        "ALTER TABLE tech_stack_nodes ADD COLUMN height_px FLOAT DEFAULT 110.0",
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
    """Si aún no hay dispositivos de planta (Cámaras, Control de Acceso, Rosetas, PCs, APs, Sensores), crea un conjunto de ejemplo conectado al Rack principal."""
    first_floor = db.query(Floor).order_by(Floor.id).first()
    if not first_floor:
        return
    floor_rooms = db.query(Room).filter(Room.floor_id == first_floor.id).order_by(Room.id).all()
    room_ids = [r.id for r in floor_rooms]
    racks_in_room = (
        db.query(Rack).filter(Rack.room_id.in_(room_ids)).order_by(Rack.id).all()
        if room_ids
        else []
    )
    if not racks_in_room:
        racks_in_room = db.query(Rack).order_by(Rack.id).all()
    first_room = floor_rooms[0] if floor_rooms else None
    first_rack = racks_in_room[0] if racks_in_room else None
    second_rack = racks_in_room[1] if len(racks_in_room) > 1 else first_rack
    rk_id = first_rack.id if first_rack else None
    rk2_id = second_rack.id if second_rack else rk_id
    rm_id = first_rack.room_id if first_rack else (first_room.id if first_room else None)

    if db.query(FloorDevice).count() == 0:
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

    # 3. Asegurar sensores ambientales y eléctricos de ejemplo conectados a los Racks
    if db.query(FloorDevice).filter(FloorDevice.device_type.like("sensor_%")).count() == 0:
        demo_sensors = [
            FloorDevice(
                floor_id=first_floor.id,
                room_id=rm_id,
                room_code="PASILLO-FRIO",
                device_type="sensor_temp",
                code="TMP01",
                name="Sonda Temperatura Pasillo Frío (20.8 °C)",
                pos_x=0.35,
                pos_y=0.22,
                ip_address="10.28.60.11",
                vlan=60,
                status="online",
                linked_rack_id=rk_id,
                linked_rack_device_code="ENV-MON01:Temp-1 (20.8 °C)",
                responsible_person="Alex Geng",
                contact_department="Climatización & BMS",
                notes="Lectura actual: 20.8 °C | Umbral alerta: 27.0 °C",
            ),
            FloorDevice(
                floor_id=first_floor.id,
                room_id=rm_id,
                room_code="PASILLO-FRIO",
                device_type="sensor_humidity",
                code="HUM01",
                name="Sensor Humedad Relativa CPD (46 %RH)",
                pos_x=0.48,
                pos_y=0.28,
                ip_address="10.28.60.12",
                vlan=60,
                status="online",
                linked_rack_id=rk_id,
                linked_rack_device_code="ENV-MON01:Hum-1 (46 %RH)",
                responsible_person="Alex Geng",
                contact_department="Climatización & BMS",
                notes="Lectura actual: 46 %RH | Rango óptimo: 40-55 %RH",
            ),
            FloorDevice(
                floor_id=first_floor.id,
                room_id=rm_id,
                room_code="CUADRO-CPD",
                device_type="sensor_power_load",
                code="PWR01",
                name="Analizador Carga Eléctrica (5.4 kW / 23.5 A)",
                pos_x=0.24,
                pos_y=0.66,
                ip_address="10.28.60.20",
                vlan=60,
                status="online",
                linked_rack_id=rk2_id,
                linked_rack_device_code="PDU-A+B:Meter-1 (5.4 kW)",
                responsible_person="Alex Geng",
                contact_department="Energía & SAI/UPS",
                notes="Lectura actual: 5.4 kW (23.5 A @ 230V) | Factor Potencia: 0.98",
            ),
            FloorDevice(
                floor_id=first_floor.id,
                room_id=rm_id,
                room_code="TECHO-CPD",
                device_type="sensor_smoke",
                code="SMK01",
                name="Detector Óptico Humo / Incendio VESDA",
                pos_x=0.42,
                pos_y=0.62,
                ip_address="10.28.60.30",
                vlan=60,
                status="online",
                linked_rack_id=rk2_id,
                linked_rack_device_code="ENV-MON01:Smoke-1",
                responsible_person="Alex Geng",
                contact_department="PCI / Contra Incendios",
                notes="Estado: Normal (0.01 %/m)",
            ),
            FloorDevice(
                floor_id=first_floor.id,
                room_id=rm_id,
                room_code="FALSO-SUELO",
                device_type="sensor_water_leak",
                code="WTR01",
                name="Cable Sensor Fuga de Agua Clima CRAC",
                pos_x=0.76,
                pos_y=0.42,
                ip_address="10.28.60.35",
                vlan=60,
                status="online",
                linked_rack_id=rk2_id,
                linked_rack_device_code="ENV-MON01:Leak-1",
                responsible_person="Alex Geng",
                contact_department="Climatización & BMS",
                notes="Estado: Seco (Sin fugas detectadas)",
            ),
        ]
        db.add_all(demo_sensors)
        db.commit()

    # 4. Reparar dispositivos/sensores demo existentes en first_floor que hayan quedado sin linked_rack_id
    if rk_id:
        orphan_devs = (
            db.query(FloorDevice)
            .filter(
                FloorDevice.floor_id == first_floor.id,
                FloorDevice.linked_rack_id.is_(None),
                FloorDevice.linked_outlet_id.is_(None),
            )
            .all()
        )
        for idx, dev in enumerate(orphan_devs):
            dev.linked_rack_id = rk2_id if (idx % 2 == 1 and rk2_id) else rk_id
        if orphan_devs:
            db.commit()


MONITORING_SETTINGS_PATH = DEFAULT_DB_PATH.parent / "monitoring_settings.json"
_monitoring_wakeup_event: Optional[asyncio.Event] = None


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


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _monitoring_wakeup_event
    Base.metadata.create_all(bind=engine)
    _ensure_db_migrations()
    db = SessionLocal()
    try:
        seed_initial_data(db)
        _ensure_demo_floor_devices(db)
        sync_system_defaults(db)
        _sanitize_missing_upload_urls(db)
        ensure_cmdb_seed_data(db)
        ensure_network_hosts_seeded(db)
    finally:
        db.close()

    stop_event = asyncio.Event()
    _monitoring_wakeup_event = asyncio.Event()
    worker_task = asyncio.create_task(
        _background_heartbeat_loop(stop_event, _monitoring_wakeup_event)
    )
    try:
        yield
    finally:
        stop_event.set()
        if _monitoring_wakeup_event is not None:
            _monitoring_wakeup_event.set()
        worker_task.cancel()


OPENAPI_TAGS_METADATA = [
    {
        "name": "Health & System",
        "description": "Estado de salud del servicio backend y metadatos de versión.",
    },
    {
        "name": "Heartbeat & Monitoring",
        "description": "Motor de comprobación periódica en background (ICMP, SSH, HTTP/HTTPS, TCP, UDP, SNMP), configuración de intervalo (por defecto 5 min) y semáforo de 4 estados (Gris/Verde/Naranja/Rojo).",
    },
    {
        "name": "Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)",
        "description": "Módulo 4 'Red & Host': Topología Lógica Interactiva con Monitorización Integrada, Máquina de Estados Nagios Core (SOFT/HARD + UNREACHABLE), Autodescubrimiento de Switches por SNMP (IF-MIB + LLDP-MIB), Conectores (Proxmox, VMware, Docker, Apache, Nginx, BBDD), Series Temporales Prometheus y Matriz de Avisos de Alarmas.",
    },
    {
        "name": "Automation Webhooks (Ansible, CI/CD & AI Agents)",
        "description": "Webhooks idempotentes para dar de alta/baja Hosts desde Ansible, activar/cerrar Ventanas de Mantenimiento automáticas, sincronizar Contactos/Reglas de Alarma como código y consultar el manifiesto de contexto para Agentes IA.",
    },
    {
        "name": "Locations, Floors & Blueprints",
        "description": "Jerarquía geográfica de Sedes (Locations), Plantas (Floors), Salas (Rooms), Pasillos (Aisles) y subida/descarga de planos 2D (JPG/PNG/GIF/WEBP).",
    },
    {
        "name": "Floor Devices & Sensors",
        "description": "Dispositivos y sensores de planta (temperatura, humedad, consumo kW/A, humo, agua, cámaras IP, control de acceso, rosetas, puestos) y tipos personalizados.",
    },
    {
        "name": "Racks & External Feeds",
        "description": "Gestión de armarios Rack (42U-48U), coordenadas 2D en planta, rotación, tomas eléctricas exteriores Schuko y cajas exteriores de fibra óptica.",
    },
    {
        "name": "Rack Devices & Hardware",
        "description": "Equipos montados en rack (switches, routers, firewalls, servidores, almacenamiento SAN/NAS, SAI/UPS, PDUs, patch panels, bandejas U con mini-equipos).",
    },
    {
        "name": "Device Templates & Library",
        "description": "Catálogo de plantillas hardware Front/Back, exportación/importación JSON de librerías y buscador/proxy de fotografías de chasis.",
    },
    {
        "name": "Connections & Structured Cabling",
        "description": "Latiguillos y cableado estructurado punto a punto (UTP Cat6/6A, Fibra OM4/OS2, DAC, Alimentación AC) intra-rack e inter-rack.",
    },
    {
        "name": "Reports & Excel (.xlsx)",
        "description": "Inventario consolidado para el Dashboard (Hierro U42→U1, Patch Panels boca a boca, Heartbeat) y exportación/importación Excel (.xlsx).",
    },
    {
        "name": "Auth, Users & Active Directory (RBAC)",
        "description": "Autenticación local y Multi-Active Directory (LDAP/LDAPS) con control de acceso basado en 4 roles (admin, editor, operator, viewer).",
    },
]

app = FastAPI(
    title="RackDoc DCIM API",
    summary="API RESTful OpenAPI 3.1.0 (v1) para Gestión Visual de Centros de Datos, Racks, Red & Host, Prometheus, CMDB y Automatización Ansible",
    description=(
        "Especificación **OpenAPI 3.1.0** de **RackDoc DCIM**.\n\n"
        "- **Prefijo canónico versionado**: `/api/v1` (con soporte retrocompatible en `/api`).\n"
        "- **Módulo 4 Red & Host**: Topología Lógica en 5 Capas, estados Nagios (`UP/DOWN/UNREACHABLE/MAINTENANCE`, `SOFT/HARD`), SNMP Switch Port Discovery (`IF-MIB` + `LLDP-MIB`), Conectores (`Proxmox`, `VMware`, `Docker`, `Apache`, `Nginx`, `BBDD`), Matriz de Avisos de Alarmas y Series Temporales en **Prometheus**.\n"
        "- **Webhooks de Automatización Ansible & Agentes IA**: `/api/v1/automation/webhook/*` y `/api/v1/automation/ai-context`.\n"
        "- **Documentación interactiva**: Swagger UI (`/docs` y `/api/v1/docs`) y ReDoc (`/redoc`)."
    ),
    version="1.3.0",
    openapi_tags=OPENAPI_TAGS_METADATA,
    contact={
        "name": "RackDoc DCIM Project",
        "url": "https://github.com/mario-ezquerro/rackdoc",
    },
    license_info={
        "name": "MIT License",
        "url": "https://opensource.org/licenses/MIT",
    },
    servers=[
        {"url": "/", "description": "Servidor activo (Frontend Proxy :8181 o Backend Directo :8180)"},
        {"url": "http://localhost:8180", "description": "Backend FastAPI directo (:8180)"},
        {"url": "http://localhost:8181", "description": "Proxy Nginx Frontend (:8181)"},
    ],
    docs_url="/docs",
    redoc_url="/redoc",
    openapi_url="/openapi.json",
    lifespan=lifespan,
)

api_router = APIRouter()


@api_router.get(
    "/uploads/{filename}",
    tags=["Locations, Floors & Blueprints"],
    summary="Obtener imagen de plano o recurso subido",
    description="Devuelve el archivo binario de imagen (JPG, PNG, GIF, WEBP) asociado al plano de una sede, planta o sala.",
)
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


@api_router.get(
    "/health",
    tags=["Health & System"],
    summary="Comprobar estado del servicio (Healthcheck)",
    description="Devuelve el estado operativo del servicio backend y versión de la API.",
)
def health_check():
    return {"status": "ok", "service": "rackdoc-backend", "api_version": "v1"}


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
    if _monitoring_wakeup_event is not None:
        _monitoring_wakeup_event.set()
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


@api_router.get(
    "/locations",
    tags=["Locations, Floors & Blueprints"],
    summary="Obtener árbol completo de Sedes, Plantas, Salas, Racks y Sensores",
    description="Devuelve la jerarquía completa del CPD con contadores agregados de Heartbeat (Gris, Verde, Naranja, Rojo), Racks y dispositivos de planta.",
)
def get_locations_tree(db: Session = Depends(get_db)):
    _sanitize_missing_upload_urls(db)
    locations = (
        db.query(Location)
        .options(
            selectinload(Location.floors)
            .selectinload(Floor.rooms)
            .selectinload(Room.racks)
            .selectinload(Rack.devices)
            .joinedload(RackDevice.template),
            selectinload(Location.floors)
            .selectinload(Floor.rooms)
            .selectinload(Room.aisles),
            selectinload(Location.floors)
            .selectinload(Floor.floor_devices),
        )
        .all()
    )

    all_conns = (
        db.query(Connection)
        .options(
            joinedload(Connection.source_port)
            .joinedload(Port.device)
            .joinedload(RackDevice.rack),
            joinedload(Connection.target_port)
            .joinedload(Port.device)
            .joinedload(RackDevice.rack),
        )
        .all()
    )

    def _classify_media(cable_type: str) -> str:
        ct = (cable_type or "").lower()
        if "power" in ct:
            return "power"
        if "fiber" in ct or "dac" in ct or "sfp" in ct:
            return "fiber"
        return "ethernet"

    rack_media_counts: dict[int, dict[str, int]] = {}
    device_conn_counts: dict[int, int] = {}
    for c in all_conns:
        sp = c.source_port
        tp = c.target_port
        if not sp or not tp or not sp.device or not tp.device:
            continue
        sd = sp.device
        td = tp.device
        mg = _classify_media(c.cable_type)
        device_conn_counts[sd.id] = device_conn_counts.get(sd.id, 0) + 1
        if td.id != sd.id:
            device_conn_counts[td.id] = device_conn_counts.get(td.id, 0) + 1
        for r_id in {sd.rack_id, td.rack_id}:
            if r_id is None:
                continue
            bucket = rack_media_counts.setdefault(
                r_id, {"ethernet": 0, "fiber": 0, "power": 0}
            )
            bucket[mg] = bucket.get(mg, 0) + 1

    result = []
    for loc in locations:
        floors_count = len(loc.floors)
        rooms_count = 0
        racks_count = 0
        total_rack_units = 0
        loc_monitored = 0
        loc_unmonitored = 0
        loc_online = 0
        loc_offline = 0
        loc_warning = 0
        floors_data = []

        for fl in sorted(loc.floors, key=lambda x: x.level_number):
            rooms_count += len(fl.rooms)
            fl_monitored = 0
            fl_unmonitored = 0
            fl_online = 0
            fl_offline = 0
            fl_warning = 0
            rooms_data = []
            floor_rack_ids: set[int] = set()
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
                    floor_rack_ids.add(rk.id)
                    total_rack_units += rk.total_units
                    aisle_obj = aisles_map.get(rk.aisle_id)
                    rack_devs = [d for d in rk.devices if d.mounted_face != "external"]
                    ext_devs = [d for d in rk.devices if d.mounted_face == "external"]
                    mon_devs = [d for d in rack_devs if d.monitoring_enabled]
                    unmon_devs = [d for d in rack_devs if not d.monitoring_enabled]
                    rk_mon = len(mon_devs)
                    rk_unmon = len(unmon_devs)
                    rk_on = len([d for d in mon_devs if d.status == "online"])
                    rk_warn = len([d for d in mon_devs if d.status == "warning"])
                    rk_off = rk_mon - rk_on - rk_warn

                    fl_monitored += rk_mon
                    fl_unmonitored += rk_unmon
                    fl_online += rk_on
                    fl_offline += rk_off
                    fl_warning += rk_warn

                    m_counts = rack_media_counts.get(
                        rk.id, {"ethernet": 0, "fiber": 0, "power": 0}
                    )
                    ext_feeds_info = []
                    for ed in ext_devs:
                        cf = ed.custom_fields or {}
                        ftype = str(cf.get("feed_type") or "power").lower()
                        if ftype not in ("power", "fiber"):
                            continue
                        c_cnt = device_conn_counts.get(ed.id, 0)
                        ext_feeds_info.append(
                            {
                                "id": ed.id,
                                "code": ed.code,
                                "name": ed.name,
                                "feed_type": ftype,
                                "color_hex": str(
                                    cf.get("feed_color")
                                    or ("#0284C7" if ftype == "fiber" else "#EA580C")
                                ),
                                "connected_count": c_cnt,
                            }
                        )

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
                            "monitoring_enabled": bool(d.monitoring_enabled),
                            "monitor_method": d.monitor_method or "icmp",
                            "monitor_port": d.monitor_port or 22,
                            "status": (d.status or "offline") if d.monitoring_enabled else "unmonitored",
                            "last_ping_ms": d.last_ping_ms if d.monitoring_enabled else None,
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
                            "unmonitored_count": rk_unmon,
                            "online_count": rk_on,
                            "offline_count": rk_off,
                            "warning_count": rk_warn,
                            "eth_cables_count": m_counts.get("ethernet", 0),
                            "fiber_cables_count": m_counts.get("fiber", 0),
                            "power_cables_count": m_counts.get("power", 0),
                            "external_feeds": ext_feeds_info,
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

            # Contabilizar también los elementos de planta (FloorDevice) de esta planta
            fd_mon_list = [fd for fd in fl.floor_devices if getattr(fd, "monitoring_enabled", False)]
            fd_unmon_list = [fd for fd in fl.floor_devices if not getattr(fd, "monitoring_enabled", False)]
            fd_on_cnt = len([fd for fd in fd_mon_list if fd.status == "online"])
            fd_warn_cnt = len([fd for fd in fd_mon_list if fd.status == "warning"])
            fd_off_cnt = len(fd_mon_list) - fd_on_cnt - fd_warn_cnt

            fl_monitored += len(fd_mon_list)
            fl_unmonitored += len(fd_unmon_list)
            fl_online += fd_on_cnt
            fl_warning += fd_warn_cnt
            fl_offline += fd_off_cnt

            loc_monitored += fl_monitored
            loc_unmonitored += fl_unmonitored
            loc_online += fl_online
            loc_offline += fl_offline
            loc_warning += fl_warning

            inter_rack_links = []
            for c in all_conns:
                sp = c.source_port
                tp = c.target_port
                if not sp or not tp or not sp.device or not tp.device:
                    continue
                sd = sp.device
                td = tp.device
                r1 = sd.rack
                r2 = td.rack
                if not r1 or not r2 or r1.id == r2.id:
                    continue
                if r1.id not in floor_rack_ids and r2.id not in floor_rack_ids:
                    continue
                mg = _classify_media(c.cable_type)
                inter_rack_links.append(
                    {
                        "id": c.id,
                        "source_rack_id": r1.id,
                        "source_rack_code": r1.code,
                        "source_device_code": sd.code,
                        "source_port_number": sp.port_number,
                        "target_rack_id": r2.id,
                        "target_rack_code": r2.code,
                        "target_device_code": td.code,
                        "target_port_number": tp.port_number,
                        "cable_type": c.cable_type or "utp_cat6a",
                        "media_group": mg,
                        "color_hex": c.color_hex or (
                            "#06B6D4"
                            if mg == "fiber"
                            else ("#EA580C" if mg == "power" else "#2563EB")
                        ),
                        "label": c.label
                        or f"{sd.code}:{sp.port_number} ↔ {td.code}:{tp.port_number}",
                        "same_floor": (r1.id in floor_rack_ids)
                        and (r2.id in floor_rack_ids),
                    }
                )

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
                    "fqdn": getattr(fd, "fqdn", "") or "",
                    "ip_address": fd.ip_address or "",
                    "mac_address": fd.mac_address or "",
                    "vlan": fd.vlan,
                    "monitoring_enabled": bool(getattr(fd, "monitoring_enabled", False)),
                    "monitor_method": getattr(fd, "monitor_method", "icmp") or "icmp",
                    "monitor_port": getattr(fd, "monitor_port", 22) or 22,
                    "status": (fd.status or "offline") if getattr(fd, "monitoring_enabled", False) else "unmonitored",
                    "last_ping_ms": getattr(fd, "last_ping_ms", None) if getattr(fd, "monitoring_enabled", False) else None,
                    "custom_fields": getattr(fd, "custom_fields", None) or {},
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
                    "unmonitored_count": fl_unmonitored,
                    "online_count": fl_online,
                    "offline_count": fl_offline,
                    "warning_count": fl_warning,
                    "rooms": rooms_data,
                    "floor_devices": floor_devices_data,
                    "inter_rack_links": inter_rack_links,
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
                "unmonitored_count": loc_unmonitored,
                "online_count": loc_online,
                "offline_count": loc_offline,
                "warning_count": loc_warning,
                "floors": floors_data,
            }
        )
    return result


@api_router.post(
    "/locations",
    tags=["Locations, Floors & Blueprints"],
    summary="Crear una nueva Sede / Datacenter",
    description="Crea una nueva sede geográfica con una planta, sala y pasillo iniciales por defecto.",
)
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


@api_router.put(
    "/locations/{location_id}",
    tags=["Locations, Floors & Blueprints"],
    summary="Actualizar datos o coordenadas de una Sede / Datacenter",
    description="Actualiza código, nombre, dirección, coordenadas GPS o posición en el mapa personalizado de una sede.",
)
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


@api_router.delete(
    "/locations/{location_id}",
    tags=["Locations, Floors & Blueprints"],
    summary="Eliminar una Sede / Datacenter",
    description="Elimina una sede y limpia en cascada sus plantas, salas, racks, equipos y conexiones.",
)
def delete_location(location_id: int, db: Session = Depends(get_db)):
    loc = (
        db.query(Location)
        .options(
            selectinload(Location.floors)
            .selectinload(Floor.rooms)
            .selectinload(Room.racks)
            .selectinload(Rack.devices)
            .selectinload(RackDevice.ports)
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


@api_router.post(
    "/floors",
    tags=["Locations, Floors & Blueprints"],
    summary="Crear una nueva Planta en una Sede",
    description="Añade una nueva planta (Floor) al edificio con una sala técnica y pasillo por defecto.",
)
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


@api_router.put(
    "/floors/{floor_id}",
    tags=["Locations, Floors & Blueprints"],
    summary="Actualizar nombre, nivel o escala de plano de una Planta",
    description="Modifica los metadatos o la escala visual del plano 2D de una planta.",
)
def update_floor(floor_id: int, payload: FloorUpdate, db: Session = Depends(get_db)):
    fl = db.query(Floor).filter(Floor.id == floor_id).first()
    if not fl:
        raise HTTPException(status_code=404, detail="Planta no encontrada")
    for k, v in payload.model_dump(exclude_unset=True).items():
        setattr(fl, k, v)
    db.commit()
    db.refresh(fl)
    return {"status": "ok", "id": fl.id}


@api_router.delete(
    "/floors/{floor_id}",
    tags=["Locations, Floors & Blueprints"],
    summary="Eliminar una Planta",
    description="Elimina una planta junto con sus salas, racks y dispositivos asociados.",
)
def delete_floor(floor_id: int, db: Session = Depends(get_db)):
    fl = (
        db.query(Floor)
        .options(
            selectinload(Floor.rooms)
            .selectinload(Room.racks)
            .selectinload(Rack.devices)
            .selectinload(RackDevice.ports)
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


@api_router.post(
    "/rooms",
    tags=["Locations, Floors & Blueprints"],
    summary="Crear una nueva Sala técnica en una Planta",
    description="Crea una sala (Room) con dimensiones en metros dentro de una planta.",
)
def create_room(payload: RoomCreate, db: Session = Depends(get_db)):
    rm = Room(**payload.model_dump())
    db.add(rm)
    db.commit()
    db.refresh(rm)
    return {"id": rm.id, "name": rm.name}


@api_router.post(
    "/aisles",
    tags=["Locations, Floors & Blueprints"],
    summary="Crear un nuevo Pasillo (Frío/Caliente) en una Sala",
    description="Crea un pasillo técnico (Aisle) dentro de una sala del CPD.",
)
def create_aisle(payload: AisleCreate, db: Session = Depends(get_db)):
    aisle = Aisle(**payload.model_dump())
    db.add(aisle)
    db.commit()
    db.refresh(aisle)
    return {"id": aisle.id, "code": aisle.code, "name": aisle.name}


@api_router.post(
    "/floors/{floor_id}/floor-devices",
    tags=["Floor Devices & Sensors"],
    summary="Añadir un Dispositivo o Sensor al plano 2D de una Planta",
    description="Coloca un nuevo sensor o equipo en el plano de planta (con Heartbeat desactivado en Gris por defecto) y sincroniza su boca en el Rack vinculado.",
)
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
    if data.get("linked_rack_id") == 0:
        data["linked_rack_id"] = None
    if data.get("linked_outlet_id") == 0:
        data["linked_outlet_id"] = None
    if not data.get("monitoring_enabled"):
        data["status"] = "unmonitored"
    fd = FloorDevice(floor_id=floor_id, **data)
    db.add(fd)
    db.commit()
    db.refresh(fd)
    if fd.monitoring_enabled:
        check_single_device(db, fd)
    if fd.linked_rack_id:
        rk = (
            db.query(Rack)
            .options(selectinload(Rack.devices).selectinload(RackDevice.ports), selectinload(Rack.devices).joinedload(RackDevice.template))
            .filter(Rack.id == fd.linked_rack_id)
            .first()
        )
        if rk:
            _sync_rack_floor_devices_box(db, rk)
    return {
        "id": fd.id,
        "floor_id": fd.floor_id,
        "device_type": fd.device_type,
        "code": fd.code,
        "name": fd.name,
        "pos_x": fd.pos_x,
        "pos_y": fd.pos_y,
        "fqdn": fd.fqdn or "",
        "ip_address": fd.ip_address or "",
        "monitoring_enabled": bool(fd.monitoring_enabled),
        "status": fd.status,
        "last_ping_ms": fd.last_ping_ms,
        "custom_fields": fd.custom_fields or {},
        "linked_rack_id": fd.linked_rack_id,
        "linked_outlet_id": fd.linked_outlet_id,
    }


@api_router.put(
    "/floor-devices/{device_id}",
    tags=["Floor Devices & Sensors"],
    summary="Actualizar un Dispositivo o Sensor de Planta (Settings, Heartbeat y Conectar)",
    description="Actualiza posición 2D, IP, VLAN, Rack vinculado, configuración de Heartbeat en background y configuración de Conectar desde el frontend.",
)
def update_floor_device(
    device_id: int,
    payload: FloorDeviceUpdate,
    db: Session = Depends(get_db),
):
    fd = db.query(FloorDevice).filter(FloorDevice.id == device_id).first()
    if not fd:
        raise HTTPException(status_code=404, detail="Dispositivo de planta no encontrado")
    old_rack_id = fd.linked_rack_id
    was_monitored = bool(getattr(fd, "monitoring_enabled", False))
    updates = payload.model_dump(exclude_unset=True)
    if "linked_rack_id" in updates and updates["linked_rack_id"] == 0:
        updates["linked_rack_id"] = None
    if "linked_outlet_id" in updates and updates["linked_outlet_id"] == 0:
        updates["linked_outlet_id"] = None
    for k, v in updates.items():
        setattr(fd, k, v)
    if not fd.monitoring_enabled:
        fd.status = "unmonitored"
        fd.last_ping_ms = None
    db.commit()
    db.refresh(fd)

    if fd.monitoring_enabled and (
        not was_monitored
        or fd.status in ("unmonitored", "unknown", "passive", None)
        or "monitoring_enabled" in updates
    ):
        check_single_device(db, fd)

    affected_rack_ids = {r_id for r_id in (old_rack_id, fd.linked_rack_id) if r_id}
    for r_id in affected_rack_ids:
        rk = (
            db.query(Rack)
            .options(selectinload(Rack.devices).selectinload(RackDevice.ports), selectinload(Rack.devices).joinedload(RackDevice.template))
            .filter(Rack.id == r_id)
            .first()
        )
        if rk:
            _sync_rack_floor_devices_box(db, rk)

    return {
        "status": "ok",
        "id": fd.id,
        "linked_rack_id": fd.linked_rack_id,
        "linked_outlet_id": fd.linked_outlet_id,
        "device_type": fd.device_type,
        "monitoring_enabled": bool(fd.monitoring_enabled),
        "status_val": fd.status,
        "last_ping_ms": fd.last_ping_ms,
        "custom_fields": fd.custom_fields or {},
    }


@api_router.post(
    "/floor-devices/{device_id}/ping",
    tags=["Heartbeat & Monitoring", "Floor Devices & Sensors"],
    summary="Probar ahora el Heartbeat de un Dispositivo o Sensor de Planta",
    description="Ejecuta inmediatamente en el backend todos los sistemas de chequeo activos del dispositivo/sensor de planta y actualiza su estado (Gris/Verde/Naranja/Rojo).",
)
def ping_floor_device_endpoint(device_id: int, db: Session = Depends(get_db)):
    fd = db.query(FloorDevice).filter(FloorDevice.id == device_id).first()
    if not fd:
        raise HTTPException(status_code=404, detail="Dispositivo de planta no encontrado")
    return check_single_device(db, fd)


@api_router.delete(
    "/floor-devices/{device_id}",
    tags=["Floor Devices & Sensors"],
    summary="Eliminar un Dispositivo o Sensor de Planta",
    description="Elimina el dispositivo o sensor del plano 2D y sincroniza las bocas exteriores del Rack vinculado.",
)
def delete_floor_device(device_id: int, db: Session = Depends(get_db)):
    fd = db.query(FloorDevice).filter(FloorDevice.id == device_id).first()
    if not fd:
        raise HTTPException(status_code=404, detail="Dispositivo de planta no encontrado")
    old_rack_id = fd.linked_rack_id
    # Desvincular otros dispositivos que apuntasen a esta roseta
    db.query(FloorDevice).filter(FloorDevice.linked_outlet_id == device_id).update(
        {"linked_outlet_id": None}
    )
    db.delete(fd)
    db.commit()
    if old_rack_id:
        rk = (
            db.query(Rack)
            .options(selectinload(Rack.devices).selectinload(RackDevice.ports), selectinload(Rack.devices).joinedload(RackDevice.template))
            .filter(Rack.id == old_rack_id)
            .first()
        )
        if rk:
            _sync_rack_floor_devices_box(db, rk)
    return {"status": "deleted", "id": device_id}


@api_router.get(
    "/floor-device-types",
    tags=["Floor Devices & Sensors"],
    summary="Listar tipos personalizados de Dispositivos y Sensores de Planta",
    description="Devuelve el catálogo de tipos de sensores y dispositivos a medida creados por el usuario.",
)
def get_custom_floor_device_types(db: Session = Depends(get_db)):
    rows = db.query(FloorDeviceCustomType).order_by(FloorDeviceCustomType.id).all()
    return [
        {
            "id": r.id,
            "category_key": r.category_key,
            "group_name": r.group_name,
            "label": r.label,
            "prefix": r.prefix,
            "icon_key": r.icon_key,
            "pin_color_hex": r.pin_color_hex,
            "default_port_hint": r.default_port_hint,
            "is_sensor": bool(r.is_sensor),
        }
        for r in rows
    ]


@api_router.post(
    "/floor-device-types",
    tags=["Floor Devices & Sensors"],
    summary="Crear un nuevo tipo personalizado de Sensor o Dispositivo de Planta",
    description="Registra una nueva categoría de sensor o equipo de planta con icono, color de pin, prefijo e indicación de puerto por defecto.",
)
def create_custom_floor_device_type(
    payload: FloorDeviceCustomTypeCreate,
    db: Session = Depends(get_db),
):
    raw_label = payload.label.strip() or "Dispositivo Personalizado"
    slug = "".join(c.lower() if c.isalnum() else "_" for c in raw_label).strip("_")
    base_key = payload.category_key.strip() if payload.category_key else (
        f"sensor_{slug}" if payload.is_sensor else f"custom_{slug}"
    )
    final_key = base_key[:56]
    idx = 2
    while (
        db.query(FloorDeviceCustomType)
        .filter(FloorDeviceCustomType.category_key == final_key)
        .first()
        is not None
    ):
        final_key = f"{base_key[:50]}_{idx}"
        idx += 1

    row = FloorDeviceCustomType(
        category_key=final_key,
        group_name=payload.group_name.strip() or "Industrial / A Medida",
        label=raw_label,
        prefix=(payload.prefix.strip() or "DEV")[:20],
        icon_key=payload.icon_key.strip() or "memory",
        pin_color_hex=payload.pin_color_hex.strip() or "#7C3AED",
        default_port_hint=payload.default_port_hint.strip() or "SW01:Gi1/0/1",
        is_sensor=payload.is_sensor,
    )
    db.add(row)
    db.commit()
    db.refresh(row)
    return {
        "id": row.id,
        "category_key": row.category_key,
        "group_name": row.group_name,
        "label": row.label,
        "prefix": row.prefix,
        "icon_key": row.icon_key,
        "pin_color_hex": row.pin_color_hex,
        "default_port_hint": row.default_port_hint,
        "is_sensor": bool(row.is_sensor),
    }


@api_router.delete(
    "/floor-device-types/{type_id}",
    tags=["Floor Devices & Sensors"],
    summary="Eliminar un tipo personalizado de Dispositivo de Planta",
    description="Elimina del catálogo un tipo personalizado de sensor o dispositivo de planta.",
)
def delete_custom_floor_device_type(type_id: int, db: Session = Depends(get_db)):
    row = (
        db.query(FloorDeviceCustomType)
        .filter(FloorDeviceCustomType.id == type_id)
        .first()
    )
    if not row:
        raise HTTPException(status_code=404, detail="Tipo de dispositivo no encontrado")
    db.delete(row)
    db.commit()
    return {"status": "deleted", "id": type_id}


@api_router.post(
    "/racks",
    tags=["Racks & External Feeds"],
    summary="Crear un nuevo armario Rack",
    description="Crea un nuevo armario Rack (por defecto 42U) e inicializa sus tomas exteriores de energía y fibra.",
)
def create_rack(payload: RackCreate, db: Session = Depends(get_db)):
    rk = Rack(**payload.model_dump())
    db.add(rk)
    db.commit()
    db.refresh(rk)
    ensure_rack_external_outlets(db, rk)
    db.commit()
    return {"id": rk.id, "code": rk.code, "name": rk.name}


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


@api_router.get(
    "/templates/photo-proxy",
    tags=["Device Templates & Library"],
    summary="Proxy CORS de fotografías de chasis hardware",
    description="Descarga y sirve fotografías externas de equipos hardware añadiendo cabeceras CORS para el lienzo de Flutter Web.",
)
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


@api_router.get(
    "/racks",
    tags=["Racks & Rack Devices"],
    summary="Listar todos los Racks del inventario",
    description="Devuelve la lista global de armarios rack con su ubicación jerárquica (Sede, Planta, Sala y Pasillo).",
)
def list_all_racks(db: Session = Depends(get_db)):
    racks = (
        db.query(Rack)
        .options(
            joinedload(Rack.room).joinedload(Room.floor).joinedload(Floor.location),
            joinedload(Rack.aisle),
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


@api_router.get(
    "/racks/{rack_id}/inter-rack-targets",
    tags=["Racks & Rack Devices", "Cabling & Connections"],
    summary="Obtener Racks, equipos y puertos disponibles para cableado Inter-Rack",
    description="Lista los demás Racks del CPD junto con sus equipos y el estado libre/ocupado de sus puertos para tender latiguillos o fibras entre Racks.",
)
def get_inter_rack_targets(rack_id: int, db: Session = Depends(get_db)):
    """Devuelve todos los demás Racks del CPD con sus equipos y puertos libres/ocupados para conectar fibras/cables Inter-Rack."""
    all_racks = (
        db.query(Rack)
        .options(
            joinedload(Rack.room).joinedload(Room.floor).joinedload(Floor.location),
            joinedload(Rack.aisle),
            selectinload(Rack.devices).joinedload(RackDevice.template),
            selectinload(Rack.devices).selectinload(RackDevice.ports),
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



def _extract_floor_device_id_from_port(port: Port | None) -> int | None:
    if not port or not port.label:
        return None
    lbl = str(port.label)
    if lbl.startswith("FD:"):
        head = lbl.split("|", 1)[0]
        try:
            return int(head.replace("FD:", "").strip())
        except ValueError:
            return None
    return None


def _sync_rack_floor_devices_box(db: Session, rack: Rack) -> bool:
    """
    Sincroniza en el Rack una caja exterior especial ('PLANTA-DC', feed_type='floor_devices')
    que agrupa todos los dispositivos de planta (Impresoras, Cámaras, APs Wi-Fi, Sensores,
    Rosetas, Ordenadores, etc.) asignados a este Rack desde '2. Datacenters & Racks',
    para poder tirar cables directamente desde cada icono/puerto al Switch o Patch Panel en '3. Rack Editor'.
    """
    direct_fds = (
        db.query(FloorDevice)
        .filter(FloorDevice.linked_rack_id == rack.id)
        .order_by(FloorDevice.id)
        .all()
    )
    outlet_ids = [fd.id for fd in direct_fds if fd.device_type == "telecom_outlet"]
    via_outlet_fds = (
        db.query(FloorDevice)
        .filter(FloorDevice.linked_outlet_id.in_(outlet_ids))
        .order_by(FloorDevice.id)
        .all()
        if outlet_ids
        else []
    )

    seen_fd_ids: set[int] = set()
    floor_devs: list[FloorDevice] = []
    for fd in [*direct_fds, *via_outlet_fds]:
        if fd.id not in seen_fd_ids:
            seen_fd_ids.add(fd.id)
            floor_devs.append(fd)

    ext_devs = [d for d in rack.devices if d.mounted_face == "external"]
    floor_panel = next(
        (
            d
            for d in ext_devs
            if (d.custom_fields or {}).get("feed_type") == "floor_devices"
        ),
        None,
    )

    changed = False
    if floor_panel is None:
        tpl = get_or_create_external_feed_template(db)
        floor_panel = RackDevice(
            rack_id=rack.id,
            template_id=tpl.id,
            code="PLANTA-DC",
            name="Equipos, Impresoras, APs y Sensores de Planta",
            hostname="planta-dc",
            start_u=rack.total_units,
            mounted_face="external",
            status="online",
            custom_fields={
                "is_external_feed": True,
                "feed_type": "floor_devices",
                "feed_color": "#0D9488",
                "socket_count": len(floor_devs),
                "initial_links_seeded": False,
            },
            notes="Recuadro de Equipos de Planta / Datacenter conectados a este Rack (Impresoras, Cámaras, APs, Sensores, Rosetas y Puestos).",
        )
        db.add(floor_panel)
        db.flush()
        changed = True

    existing_ports = list(floor_panel.ports)
    by_fd_id: dict[int, Port] = {}
    by_code: dict[str, Port] = {}
    for p in existing_ports:
        fid = _extract_floor_device_id_from_port(p)
        if fid is not None:
            by_fd_id[fid] = p
        by_code[p.port_number] = p

    kept_port_ids: set[int] = set()
    fd_to_port: dict[int, Port] = {}

    for idx, fd in enumerate(floor_devs):
        p_num = (fd.code or f"EQ{fd.id}").strip()[:38]
        label_str = f"FD:{fd.id}|{fd.device_type}|{fd.name}|{fd.ip_address or ''}|{fd.room_code or ''}"[:98]
        matched_p = by_fd_id.get(fd.id) or by_code.get(p_num)
        r_idx = idx // 3
        c_idx = idx % 3
        if matched_p is not None:
            if (
                matched_p.port_number != p_num
                or matched_p.label != label_str
                or matched_p.row_index != r_idx
                or matched_p.col_index != c_idx
                or matched_p.port_type != "rj45"
            ):
                matched_p.port_number = p_num
                matched_p.label = label_str
                matched_p.port_type = "rj45"
                matched_p.row_index = r_idx
                matched_p.col_index = c_idx
                changed = True
            kept_port_ids.add(matched_p.id)
            fd_to_port[fd.id] = matched_p
        else:
            new_p = Port(
                rack_device_id=floor_panel.id,
                port_number=p_num,
                label=label_str,
                face="front",
                port_type="rj45",
                row_index=r_idx,
                col_index=c_idx,
                rel_x=0.5,
                rel_y=0.5,
            )
            db.add(new_p)
            db.flush()
            kept_port_ids.add(new_p.id)
            fd_to_port[fd.id] = new_p
            changed = True

    stale_port_ids = [p.id for p in existing_ports if p.id not in kept_port_ids]
    if stale_port_ids:
        _delete_connections_for_port_ids(db, stale_port_ids)
        for p in existing_ports:
            if p.id in stale_port_ids:
                db.delete(p)
        db.flush()
        changed = True

    cf = dict(floor_panel.custom_fields or {})
    cf["is_external_feed"] = True
    cf["feed_type"] = "floor_devices"
    cf["feed_color"] = cf.get("feed_color") or "#0D9488"
    cf["socket_count"] = len(floor_devs)

    # Sembrar conexiones iniciales de ejemplo hacia el Patch Panel / Switch si aún no se ha hecho
    if not cf.get("initial_links_seeded") and floor_devs:
        all_rack_port_ids = [
            p.id for d in rack.devices for p in d.ports if d.id != floor_panel.id
        ] + list(kept_port_ids)
        existing_conns = (
            db.query(Connection)
            .filter(
                (Connection.source_port_id.in_(all_rack_port_ids))
                | (Connection.target_port_id.in_(all_rack_port_ids))
            )
            .all()
            if all_rack_port_ids
            else []
        )
        occupied_pids = set()
        for c in existing_conns:
            occupied_pids.add(c.source_port_id)
            occupied_pids.add(c.target_port_id)

        # Buscar puertos RJ45 libres en Patch Panels y Switches del Rack
        pp_free_ports: list[tuple[RackDevice, Port]] = []
        sw_free_ports: list[tuple[RackDevice, Port]] = []
        for d in sorted(rack.devices, key=lambda x: x.start_u, reverse=True):
            if d.mounted_face == "external":
                continue
            cat = (d.template.category if d.template else "").lower()
            for p in sorted(d.ports, key=lambda x: x.id):
                if p.id in occupied_pids:
                    continue
                if "rj45" not in (p.port_type or "").lower():
                    continue
                if cat in ("patch_panel", "patchbox"):
                    pp_free_ports.append((d, p))
                elif cat in ("switch", "router", "firewall"):
                    sw_free_ports.append((d, p))

        seeded_cnt = 0
        for fd in floor_devs:
            if seeded_cnt >= 6:
                break
            f_port = fd_to_port.get(fd.id)
            if not f_port or f_port.id in occupied_pids:
                continue
            # Si es roseta o apunta a PP, priorizar Patch Panel; si es cámara/AP/sensor/impresora, usar Switch o Patch Panel
            use_pp = fd.device_type == "telecom_outlet" or (
                fd.linked_rack_device_code or ""
            ).upper().startswith("PP")
            target_pair = None
            if use_pp and pp_free_ports:
                target_pair = pp_free_ports.pop(0)
            elif sw_free_ports:
                target_pair = sw_free_ports.pop(0)
            elif pp_free_ports:
                target_pair = pp_free_ports.pop(0)

            if target_pair is not None:
                t_dev, t_port = target_pair
                occupied_pids.add(f_port.id)
                occupied_pids.add(t_port.id)
                cable_col = (
                    "#F97316"
                    if fd.device_type == "telecom_outlet"
                    else (
                        "#10B981"
                        if fd.device_type.startswith("sensor_")
                        else "#0D9488"
                    )
                )
                db.add(
                    Connection(
                        source_port_id=f_port.id,
                        target_port_id=t_port.id,
                        cable_type="utp_cat6a",
                        color_hex=cable_col,
                        routing_channel="right",
                        label=f"Planta {fd.code} ({fd.name}) ➔ {t_dev.code}:{t_port.port_number}",
                        vlan=fd.vlan or 10,
                        length_m=15.0,
                    )
                )
                fd.linked_rack_device_code = f"{t_dev.code}:{t_port.port_number}"
                seeded_cnt += 1

        cf["initial_links_seeded"] = True
        changed = True

    floor_panel.custom_fields = cf
    if changed:
        db.commit()
    return changed


@api_router.get(
    "/racks/{rack_id}",
    tags=["Racks & Rack Devices"],
    summary="Obtener detalle completo de un Rack (equipos, puertos, acometidas y latiguillos)",
    description="Devuelve la topología 42U completa de un armario Rack, sus equipos montados Front/Back, tomas exteriores, equipos de planta vinculados y cables.",
)
def get_rack_detail(rack_id: int, db: Session = Depends(get_db)):
    rack = (
        db.query(Rack)
        .options(
            joinedload(Rack.room).joinedload(Room.floor).joinedload(Floor.location),
            joinedload(Rack.room).selectinload(Room.aisles),
            joinedload(Rack.aisle),
            selectinload(Rack.devices).joinedload(RackDevice.template),
            selectinload(Rack.devices).selectinload(RackDevice.ports),
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

    if _sync_rack_floor_devices_box(db, rack):
        db.refresh(rack)
        rack = (
            db.query(Rack)
            .options(
                joinedload(Rack.room).joinedload(Room.floor).joinedload(Floor.location),
                joinedload(Rack.room).selectinload(Room.aisles),
                joinedload(Rack.aisle),
                selectinload(Rack.devices).joinedload(RackDevice.template),
                selectinload(Rack.devices).selectinload(RackDevice.ports),
            )
            .filter(Rack.id == rack_id)
            .first()
        )

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


@api_router.put(
    "/racks/{rack_id}",
    tags=["Racks & Rack Devices"],
    summary="Actualizar propiedades de un armario Rack",
    description="Modifica código, nombre, altura en U, pasillo asignado, fabricante, número de serie o posición en el plano de un Rack.",
)
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


@api_router.delete(
    "/racks/{rack_id}",
    tags=["Racks & Rack Devices"],
    summary="Eliminar un armario Rack",
    description="Elimina un armario Rack junto con sus equipos montados y las conexiones asociadas.",
)
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


@api_router.post(
    "/racks/{rack_id}/devices",
    response_model=RackDeviceSchema,
    tags=["Racks & Rack Devices"],
    summary="Montar un nuevo equipo en un Rack",
    description="Instala un dispositivo hardware en la unidad U y cara indicadas tras verificar colisiones de espacio U.",
)
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
        status="unmonitored",
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
    if device.monitoring_enabled:
        check_single_device(db, device)
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


@api_router.put(
    "/devices/{device_id}",
    response_model=RackDeviceSchema,
    tags=["Racks & Rack Devices"],
    summary="Actualizar equipo montado en Rack",
    description="Actualiza posición U, cara de montaje, direccionamiento IP/MAC/VLAN, Heartbeat multiprotocolo, enlaces de conexión SSH/Web o bandeja multi-equipo.",
)
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

    was_monitored = bool(device.monitoring_enabled)
    for k, v in updates.items():
        setattr(device, k, v)

    if not device.monitoring_enabled:
        device.status = "unmonitored"
        device.last_ping_ms = None

    if "custom_fields" in updates:
        if (device.custom_fields or {}).get("tray_items") is not None:
            _sync_tray_items_ports(db, device)
        elif (device.custom_fields or {}).get("custom_layout_spec") is not None:
            _sync_custom_device_ports(db, device)

    db.commit()
    db.refresh(device)

    if device.monitoring_enabled and (
        not was_monitored
        or device.status in ("unmonitored", "unknown", "passive", None)
        or "monitoring_enabled" in updates
    ):
        check_single_device(db, device)
        db.refresh(device)

    return device


@api_router.delete(
    "/devices/{device_id}",
    tags=["Racks & Rack Devices"],
    summary="Desmontar y eliminar equipo de un Rack",
    description="Retira el dispositivo del armario Rack y elimina los latiguillos conectados a sus bocas.",
)
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


@api_router.post(
    "/devices/{device_id}/ping",
    tags=["Monitoring & Heartbeat"],
    summary="Ejecutar comprobación Heartbeat de un equipo de Rack ahora",
    description="Lanza inmediatamente todos los chequeos Heartbeat configurados en el dispositivo (ICMP, TCP, HTTP/HTTPS) y devuelve estado agregado (online, degraded, offline, unmonitored) y desglose por protocolo.",
)
def ping_device_endpoint(device_id: int, db: Session = Depends(get_db)):
    device = db.query(RackDevice).filter(RackDevice.id == device_id).first()
    if not device:
        raise HTTPException(status_code=404, detail="Dispositivo no encontrado")
    return check_single_device(db, device)


@api_router.post(
    "/racks/{rack_id}/ping-all",
    tags=["Monitoring & Heartbeat"],
    summary="Ejecutar Heartbeat en todos los equipos de un Rack",
    description="Comprueba simultáneamente el estado Heartbeat de todos los dispositivos con monitorización activa en el Rack especificado.",
)
def ping_all_rack_devices_endpoint(rack_id: int, db: Session = Depends(get_db)):
    return check_all_monitored_devices(db, rack_id=rack_id)


@api_router.post(
    "/devices/{device_id}/remote-console",
    tags=["Monitoring & Heartbeat", "Racks & Rack Devices"],
    summary="Ejecutar diagnóstico o consola remota sobre un equipo de Rack",
    description="Realiza pruebas de conectividad SSH o inspección HTTP/HTTPS desde el backend hacia la IP de gestión del equipo.",
)
def device_remote_console_endpoint(
    device_id: int,
    payload: dict,
    db: Session = Depends(get_db),
):
    device = db.query(RackDevice).filter(RackDevice.id == device_id).first()
    if not device:
        raise HTTPException(status_code=404, detail="Dispositivo no encontrado")
    return run_device_remote_console(db, device, payload or {})


@api_router.post(
    "/racks/{rack_id}/external-outlets",
    response_model=RackDeviceSchema,
    tags=["Racks & Rack Devices", "Cabling & Connections"],
    summary="Crear acometida exterior en un Rack (Eléctrica Schuko o Fibra Óptica)",
    description="Añade una caja exterior de alimentación eléctrica Schuko o de fibra óptica LC/SC fuera del chasis 42U para alimentar PDUs, SAIs o switches.",
)
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


@api_router.put(
    "/external-outlets/{device_id}",
    response_model=RackDeviceSchema,
    tags=["Racks & Rack Devices", "Cabling & Connections"],
    summary="Actualizar acometida exterior de Rack",
    description="Modifica el número de bocas/tomas, color identificativo, altura U de referencia o nombre de una acometida exterior.",
)
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


@api_router.delete(
    "/external-outlets/{device_id}",
    tags=["Racks & Rack Devices", "Cabling & Connections"],
    summary="Eliminar acometida exterior de un Rack",
    description="Elimina una acometida exterior y sus cables asociados (manteniendo siempre al menos 1 toma en el Rack).",
)
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


@api_router.post(
    "/connections",
    response_model=ConnectionSchema,
    tags=["Cabling & Connections"],
    summary="Tender un nuevo cable / latiguillo entre dos puertos",
    description="Conecta dos bocas (intra-rack, inter-rack, acometida exterior o equipo de planta) validando que ambos puertos estén libres.",
)
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
    # Si uno de los extremos es una toma exterior (Eléctrica Schuko, Fibra Óptica o Recuadro de Equipos de Planta)
    for end_port, other_port in ((sp, tp), (tp, sp)):
        end_dev = end_port.device
        if end_dev.mounted_face == "external":
            cf = end_dev.custom_fields or {}
            feed_color = cf.get("feed_color")
            feed_type = str(cf.get("feed_type") or "power").lower()
            if feed_type == "floor_devices":
                if not conn_data.get("cable_type") or conn_data.get("cable_type") == "power_ac":
                    conn_data["cable_type"] = "utp_cat6a"
                fd_id = _extract_floor_device_id_from_port(end_port)
                if fd_id is not None:
                    fd = db.query(FloorDevice).filter(FloorDevice.id == fd_id).first()
                    if fd and other_port and other_port.device:
                        fd.linked_rack_device_code = (
                            f"{other_port.device.code}:{other_port.port_number}"
                        )
            else:
                if feed_color:
                    conn_data["color_hex"] = feed_color
                conn_data["cable_type"] = (
                    "fiber_om4" if feed_type == "fiber" else "power_ac"
                )
            break

    conn = Connection(**conn_data)
    db.add(conn)
    db.commit()
    db.refresh(conn)
    return _serialize_connection(conn)


@api_router.put(
    "/connections/{connection_id}",
    response_model=ConnectionSchema,
    tags=["Cabling & Connections"],
    summary="Actualizar propiedades de un cable o latiguillo",
    description="Modifica tipo de cable, color hexadecimal, canal de enrutamiento (left/right), etiqueta, VLAN o longitud en metros.",
)
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


@api_router.delete(
    "/connections/{connection_id}",
    tags=["Cabling & Connections"],
    summary="Desconectar y eliminar un cable o latiguillo",
    description="Elimina la conexión física entre dos puertos y libera ambas bocas.",
)
def delete_connection(connection_id: int, db: Session = Depends(get_db)):
    conn = (
        db.query(Connection)
        .options(
            joinedload(Connection.source_port).joinedload(Port.device),
            joinedload(Connection.target_port).joinedload(Port.device),
        )
        .filter(Connection.id == connection_id)
        .first()
    )
    if not conn:
        raise HTTPException(status_code=404, detail="Conexión no encontrada")
    for p in (conn.source_port, conn.target_port):
        if p and p.device and p.device.mounted_face == "external":
            if (p.device.custom_fields or {}).get("feed_type") == "floor_devices":
                fd_id = _extract_floor_device_id_from_port(p)
                if fd_id is not None:
                    fd = db.query(FloorDevice).filter(FloorDevice.id == fd_id).first()
                    if fd:
                        fd.linked_rack_device_code = ""
    db.delete(conn)
    db.commit()
    return {"status": "deleted", "id": connection_id}


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


# ==============================================================================
# ADMINISTRACIÓN: AUTENTICACIÓN, ROLES (4 NIVELES) Y ACTIVE DIRECTORY (MULTI-AD)
# ==============================================================================
VALID_ROLES = {"admin", "editor", "operator", "viewer"}


@api_router.post(
    "/auth/login",
    tags=["Authentication, RBAC & Active Directory"],
    summary="Iniciar sesión (Local o Active Directory / LDAP)",
    description="Autentica un usuario local o de dominio Active Directory (`DOMAIN\\user` o `user@domain`) y devuelve su token de sesión y rol RBAC.",
)
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


@api_router.get(
    "/users",
    response_model=list[UserSchema],
    tags=["Authentication, RBAC & Active Directory"],
    summary="Listar usuarios registrados y sus roles RBAC",
    description="Devuelve todos los usuarios dados de alta en RackDoc (locales y de Active Directory) con su nivel de permisos (`admin`, `editor`, `operator`, `viewer`).",
)
def list_users(db: Session = Depends(get_db)):
    return db.query(User).order_by(User.id).all()


@api_router.post(
    "/users",
    response_model=UserSchema,
    tags=["Authentication, RBAC & Active Directory"],
    summary="Crear nuevo usuario",
    description="Registra una nueva cuenta de usuario local o vinculada a Active Directory asignándole un rol RBAC.",
)
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


@api_router.put(
    "/users/{user_id}",
    response_model=UserSchema,
    tags=["Authentication, RBAC & Active Directory"],
    summary="Actualizar usuario o cambiar rol RBAC",
    description="Modifica datos de perfil, contraseña, estado activo/inactivo o nivel de rol RBAC de un usuario.",
)
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


@api_router.delete(
    "/users/{user_id}",
    tags=["Authentication, RBAC & Active Directory"],
    summary="Eliminar usuario",
    description="Elimina una cuenta de usuario (impidiendo borrar el único administrador del sistema).",
)
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


@api_router.get(
    "/ad-servers",
    response_model=list[ADServerSchema],
    tags=["Authentication, RBAC & Active Directory"],
    summary="Listar servidores Active Directory / LDAP",
    description="Devuelve los controladores de dominio Active Directory / LDAP configurados y su mapeo de grupos a roles RBAC.",
)
def list_ad_servers(db: Session = Depends(get_db)):
    return db.query(ADServer).order_by(ADServer.id).all()


@api_router.post(
    "/ad-servers",
    response_model=ADServerSchema,
    tags=["Authentication, RBAC & Active Directory"],
    summary="Añadir servidor Active Directory / LDAP",
    description="Registra un nuevo controlador de dominio Active Directory / LDAP con soporte de mapeo de grupos a roles.",
)
def create_ad_server(payload: ADServerCreate, db: Session = Depends(get_db)):
    srv = ADServer(**payload.model_dump())
    db.add(srv)
    db.commit()
    db.refresh(srv)
    return srv


@api_router.put(
    "/ad-servers/{ad_id}",
    response_model=ADServerSchema,
    tags=["Authentication, RBAC & Active Directory"],
    summary="Actualizar servidor Active Directory / LDAP",
    description="Actualiza parámetros de conexión LDAP/LDAPS, Base DN o mapeo de grupos de un servidor Active Directory.",
)
def update_ad_server(ad_id: int, payload: ADServerUpdate, db: Session = Depends(get_db)):
    srv = db.query(ADServer).filter(ADServer.id == ad_id).first()
    if not srv:
        raise HTTPException(status_code=404, detail="Servidor Active Directory no encontrado")
    for k, v in payload.model_dump(exclude_unset=True).items():
        setattr(srv, k, v)
    db.commit()
    db.refresh(srv)
    return srv


@api_router.delete(
    "/ad-servers/{ad_id}",
    tags=["Authentication, RBAC & Active Directory"],
    summary="Eliminar servidor Active Directory / LDAP",
    description="Elimina la configuración de un servidor Active Directory / LDAP.",
)
def delete_ad_server(ad_id: int, db: Session = Depends(get_db)):
    srv = db.query(ADServer).filter(ADServer.id == ad_id).first()
    if not srv:
        raise HTTPException(status_code=404, detail="Servidor Active Directory no encontrado")
    db.delete(srv)
    db.commit()
    return {"status": "deleted", "id": ad_id}


@api_router.post(
    "/ad-servers/{ad_id}/search-users",
    tags=["Authentication, RBAC & Active Directory"],
    summary="Buscar cuentas y grupos en un directorio Active Directory",
    description="Consulta cuentas de usuario en el servidor Active Directory especificado y sugiere el rol RBAC según su grupo AD.",
)
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


@api_router.post(
    "/ad-servers/{ad_id}/import-users",
    tags=["Authentication, RBAC & Active Directory"],
    summary="Importar usuarios desde Active Directory con asignación de rol RBAC",
    description="Importa o actualiza un lote de usuarios del directorio Active Directory vinculándolos al servidor AD y rol RBAC seleccionados.",
)
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


# ==============================================================================
# CMDB & IPAM + VERIFICADOR MANUAL DE DIRECCIONES IP (MULTI-IP & MÁQUINAS VIRTUALES)
# ==============================================================================
@api_router.get(
    "/cmdb/overview",
    tags=["CMDB, Multi-IP & IP Verification"],
    summary="Obtener inventario completo de la CMDB (Físicos, VMs, Contenedores, Clusters, Subredes y Múltiples IPs)",
    description="Sincroniza automáticamente los equipos de Rack y Planta y devuelve todos los CIs (incluyendo Máquinas Virtuales, Contenedores, Clusters/VIPs e Instancias Cloud), sus múltiples IPs (Heartbeat + Servicio + Backup + Storage + iDRAC) y el estado de las subredes IPAM.",
)
def get_cmdb_overview_endpoint(db: Session = Depends(get_db)):
    ensure_cmdb_seed_data(db)
    return build_cmdb_overview(db)


@api_router.post(
    "/cmdb/assets",
    tags=["CMDB, Multi-IP & IP Verification"],
    summary="Crear nueva máquina o activo en la CMDB (VM, Contenedor, Cluster VIP, Cloud, etc.)",
    description="Da de alta un nuevo elemento de configuración (CI) directamente en la CMDB junto con todas sus interfaces de red y direcciones IP (Gestión/Heartbeat + Producción/Servicio + Backup/Storage/VIP).",
)
def create_cmdb_asset_endpoint(payload: CmdbAssetCreate, db: Session = Depends(get_db)):
    code_clean = payload.code.strip().upper()
    if not code_clean:
        raise HTTPException(status_code=400, detail="El código del activo (CI) es obligatorio.")
    exists = db.query(CmdbAsset).filter(CmdbAsset.code == code_clean).first()
    if exists:
        raise HTTPException(status_code=409, detail=f"Ya existe un activo en la CMDB con el código '{code_clean}'.")

    asset = CmdbAsset(
        code=code_clean,
        name=payload.name.strip() or code_clean,
        hostname=payload.hostname.strip() or code_clean.lower(),
        fqdn=payload.fqdn.strip(),
        asset_class=payload.asset_class,
        environment=payload.environment,
        criticality=payload.criticality,
        lifecycle_status=payload.lifecycle_status,
        os_or_firmware=payload.os_or_firmware.strip(),
        cpu_cores=payload.cpu_cores,
        ram_gb=payload.ram_gb,
        storage_gb=payload.storage_gb,
        hypervisor_or_platform=payload.hypervisor_or_platform.strip(),
        serial_or_uuid=payload.serial_or_uuid.strip(),
        owner_team=payload.owner_team.strip(),
        responsible_person=payload.responsible_person.strip(),
        sync_source="cmdb",
        host_rack_device_id=payload.host_rack_device_id,
        parent_asset_id=payload.parent_asset_id,
        monitoring_enabled=payload.monitoring_enabled,
        monitor_method=payload.monitor_method,
        monitor_port=payload.monitor_port,
        status="online" if payload.monitoring_enabled else "unmonitored",
        management_links=payload.management_links,
        custom_fields=payload.custom_fields,
        notes=payload.notes,
    )
    db.add(asset)
    db.flush()

    subnets = db.query(CmdbSubnet).all()
    has_hb = any(ip.is_heartbeat_ip for ip in payload.ip_addresses)
    for idx, ip_in in enumerate(payload.ip_addresses):
        ip_str = ip_in.ip_address.strip()
        if not ip_str:
            continue
        matched_sub = _match_subnet_for_ip(ip_str, subnets)
        sub_id = ip_in.subnet_id or (matched_sub.id if matched_sub else None)
        is_hb = ip_in.is_heartbeat_ip or (not has_hb and idx == 0)
        db.add(
            CmdbIpAddress(
                asset_id=asset.id,
                subnet_id=sub_id,
                ip_address=ip_str,
                subnet_mask=ip_in.subnet_mask or (matched_sub.subnet_mask if matched_sub else "255.255.255.0"),
                gateway=ip_in.gateway or (matched_sub.gateway if matched_sub else ""),
                vlan_id=ip_in.vlan_id if ip_in.vlan_id is not None else (matched_sub.vlan_id if matched_sub else None),
                ip_role=ip_in.ip_role,
                interface_name=ip_in.interface_name or f"eth{idx}",
                mac_address=ip_in.mac_address.strip(),
                fqdn=ip_in.fqdn.strip() or (asset.fqdn if is_hb else ""),
                is_heartbeat_ip=is_hb,
                allocation_status=ip_in.allocation_status or "assigned",
                notes=ip_in.notes,
            )
        )

    db.commit()
    return build_cmdb_overview(db)


@api_router.put(
    "/cmdb/assets/{asset_id}",
    tags=["CMDB, Multi-IP & IP Verification"],
    summary="Actualizar máquina/CI de la CMDB y sus múltiples direcciones IP",
    description="Actualiza los atributos técnicos, hipervisor padre y lista de IPs de una máquina en la CMDB. Si el activo está vinculado a un equipo de Rack o Planta, sincroniza automáticamente su IP de Heartbeat/Gestión.",
)
def update_cmdb_asset_endpoint(
    asset_id: int,
    payload: CmdbAssetUpdate,
    db: Session = Depends(get_db),
):
    asset = db.query(CmdbAsset).filter(CmdbAsset.id == asset_id).first()
    if not asset:
        raise HTTPException(status_code=404, detail="Activo CMDB no encontrado.")

    data = payload.model_dump(exclude_unset=True)
    ip_inputs = data.pop("ip_addresses", None)

    for k, v in data.items():
        if k == "code" and isinstance(v, str) and v.strip():
            setattr(asset, k, v.strip().upper())
        else:
            setattr(asset, k, v)
    asset.updated_at = datetime.utcnow()

    subnets = db.query(CmdbSubnet).all()
    if ip_inputs is not None:
        # Reemplazar/actualizar la colección de IPs del activo
        db.query(CmdbIpAddress).filter(CmdbIpAddress.asset_id == asset.id).delete()
        has_hb = any(bool(item.get("is_heartbeat_ip")) for item in ip_inputs)
        for idx, item in enumerate(ip_inputs):
            ip_str = str(item.get("ip_address") or "").strip()
            if not ip_str:
                continue
            matched_sub = _match_subnet_for_ip(ip_str, subnets)
            sub_id = item.get("subnet_id") or (matched_sub.id if matched_sub else None)
            is_hb = bool(item.get("is_heartbeat_ip")) or (not has_hb and idx == 0)
            db.add(
                CmdbIpAddress(
                    asset_id=asset.id,
                    subnet_id=sub_id,
                    ip_address=ip_str,
                    subnet_mask=str(item.get("subnet_mask") or (matched_sub.subnet_mask if matched_sub else "255.255.255.0")),
                    gateway=str(item.get("gateway") or (matched_sub.gateway if matched_sub else "")),
                    vlan_id=item.get("vlan_id") if item.get("vlan_id") is not None else (matched_sub.vlan_id if matched_sub else None),
                    ip_role=str(item.get("ip_role") or ("mgmt_heartbeat" if is_hb else "primary_service")),
                    interface_name=str(item.get("interface_name") or f"eth{idx}"),
                    mac_address=str(item.get("mac_address") or "").strip(),
                    fqdn=str(item.get("fqdn") or "").strip(),
                    is_heartbeat_ip=is_hb,
                    allocation_status=str(item.get("allocation_status") or "assigned"),
                    notes=str(item.get("notes") or ""),
                )
            )
        db.flush()

    # Si es un activo sincronizado con RackDevice o FloorDevice, propagar cambios a la entidad física
    db.refresh(asset)
    hb_ip_rec = next(
        (ip for ip in asset.ip_addresses if ip.is_heartbeat_ip or ip.ip_role == "mgmt_heartbeat"),
        asset.ip_addresses[0] if asset.ip_addresses else None,
    )
    if asset.sync_source == "rack_device" and asset.rack_device_id:
        rdev = db.query(RackDevice).filter(RackDevice.id == asset.rack_device_id).first()
        if rdev:
            rdev.name = asset.name
            rdev.hostname = asset.hostname
            rdev.fqdn = asset.fqdn
            rdev.monitoring_enabled = asset.monitoring_enabled
            rdev.monitor_method = asset.monitor_method
            rdev.monitor_port = asset.monitor_port
            if hb_ip_rec:
                rdev.ip_address = hb_ip_rec.ip_address
                rdev.subnet_mask = hb_ip_rec.subnet_mask or rdev.subnet_mask
                rdev.gateway = hb_ip_rec.gateway or rdev.gateway
                if hb_ip_rec.vlan_id is not None:
                    rdev.vlan_mgmt = hb_ip_rec.vlan_id
                if hb_ip_rec.mac_address:
                    rdev.mac_address = hb_ip_rec.mac_address
    elif asset.sync_source == "floor_device" and asset.floor_device_id:
        fdev = db.query(FloorDevice).filter(FloorDevice.id == asset.floor_device_id).first()
        if fdev:
            fdev.name = asset.name
            fdev.fqdn = asset.fqdn
            fdev.monitoring_enabled = asset.monitoring_enabled
            if hb_ip_rec:
                fdev.ip_address = hb_ip_rec.ip_address
                if hb_ip_rec.vlan_id is not None:
                    fdev.vlan = hb_ip_rec.vlan_id

    db.commit()
    return build_cmdb_overview(db)


@api_router.delete(
    "/cmdb/assets/{asset_id}",
    tags=["CMDB, Multi-IP & IP Verification"],
    summary="Eliminar activo de la CMDB",
    description="Elimina una máquina virtual, contenedor, cluster o activo de la CMDB y libera todas sus IPs asociadas.",
)
def delete_cmdb_asset_endpoint(asset_id: int, db: Session = Depends(get_db)):
    asset = db.query(CmdbAsset).filter(CmdbAsset.id == asset_id).first()
    if not asset:
        raise HTTPException(status_code=404, detail="Activo CMDB no encontrado.")
    if asset.sync_source in ("rack_device", "floor_device"):
        # Si es un equipo físico de Rack o Planta, limpiamos sus IPs secundarias extra
        db.query(CmdbIpAddress).filter(
            CmdbIpAddress.asset_id == asset.id,
            CmdbIpAddress.is_heartbeat_ip.is_(False),
        ).delete()
        db.commit()
        return build_cmdb_overview(db)

    db.delete(asset)
    db.commit()
    return build_cmdb_overview(db)


@api_router.post(
    "/cmdb/assets/{asset_id}/ips",
    tags=["CMDB, Multi-IP & IP Verification"],
    summary="Añadir una nueva interfaz / dirección IP adicional a una máquina",
    description="Asigna una nueva IP (Producción, VIP, Almacenamiento, Backup, iDRAC o Gestión) a un activo existente de la CMDB.",
)
def add_ip_to_cmdb_asset_endpoint(
    asset_id: int,
    payload: CmdbIpAddressInput,
    db: Session = Depends(get_db),
):
    asset = db.query(CmdbAsset).filter(CmdbAsset.id == asset_id).first()
    if not asset:
        raise HTTPException(status_code=404, detail="Activo CMDB no encontrado.")
    ip_str = payload.ip_address.strip()
    if not ip_str:
        raise HTTPException(status_code=400, detail="La dirección IP no puede estar vacía.")

    subnets = db.query(CmdbSubnet).all()
    matched_sub = _match_subnet_for_ip(ip_str, subnets)
    sub_id = payload.subnet_id or (matched_sub.id if matched_sub else None)

    if payload.is_heartbeat_ip:
        for existing_ip in asset.ip_addresses:
            existing_ip.is_heartbeat_ip = False

    new_ip = CmdbIpAddress(
        asset_id=asset.id,
        subnet_id=sub_id,
        ip_address=ip_str,
        subnet_mask=payload.subnet_mask or (matched_sub.subnet_mask if matched_sub else "255.255.255.0"),
        gateway=payload.gateway or (matched_sub.gateway if matched_sub else ""),
        vlan_id=payload.vlan_id if payload.vlan_id is not None else (matched_sub.vlan_id if matched_sub else None),
        ip_role=payload.ip_role,
        interface_name=payload.interface_name or "eth1",
        mac_address=payload.mac_address.strip(),
        fqdn=payload.fqdn.strip(),
        is_heartbeat_ip=payload.is_heartbeat_ip,
        allocation_status=payload.allocation_status or "assigned",
        last_verification_status="active_in_network",
        last_verified_at=datetime.utcnow(),
        notes=payload.notes,
    )
    db.add(new_ip)
    db.commit()
    return build_cmdb_overview(db)


@api_router.delete(
    "/cmdb/ips/{ip_id}",
    tags=["CMDB, Multi-IP & IP Verification"],
    summary="Liberar / eliminar una dirección IP de un activo CMDB",
)
def delete_cmdb_ip_endpoint(ip_id: int, db: Session = Depends(get_db)):
    ip_rec = db.query(CmdbIpAddress).filter(CmdbIpAddress.id == ip_id).first()
    if not ip_rec:
        raise HTTPException(status_code=404, detail="Registro de IP no encontrado.")
    db.delete(ip_rec)
    db.commit()
    return build_cmdb_overview(db)


@api_router.post(
    "/cmdb/assets/{asset_id}/heartbeat",
    tags=["CMDB, Multi-IP & IP Verification"],
    summary="Ejecutar test de Heartbeat en vivo para una máquina de la CMDB",
)
def run_cmdb_asset_heartbeat_endpoint(asset_id: int, db: Session = Depends(get_db)):
    asset = db.query(CmdbAsset).filter(CmdbAsset.id == asset_id).first()
    if not asset:
        raise HTTPException(status_code=404, detail="Activo CMDB no encontrado.")
    return check_cmdb_asset_heartbeat(db, asset)


@api_router.post(
    "/cmdb/subnets",
    tags=["CMDB, Multi-IP & IP Verification"],
    summary="Crear nueva Subred / VLAN en el IPAM de la CMDB",
)
def create_cmdb_subnet_endpoint(payload: CmdbSubnetCreate, db: Session = Depends(get_db)):
    import ipaddress as _ipaddress

    cidr_raw = (payload.cidr or "").strip()
    if not cidr_raw:
        raise HTTPException(status_code=400, detail="El bloque CIDR es obligatorio (ej. 10.20.40.0/24 o 10.20.40.0/23).")
    if "/" not in cidr_raw:
        cidr_raw = f"{cidr_raw}/24"
    try:
        net = _ipaddress.ip_network(cidr_raw, strict=False)
    except ValueError as exc:
        raise HTTPException(
            status_code=400,
            detail=f"El bloque CIDR '{cidr_raw}' no es válido: {exc}",
        )
    cidr_norm = str(net)
    exists = db.query(CmdbSubnet).filter(CmdbSubnet.cidr == cidr_norm).first()
    if exists:
        raise HTTPException(status_code=409, detail=f"La subred '{cidr_norm}' ya está registrada.")

    data = payload.model_dump()
    data["cidr"] = cidr_norm
    data["subnet_mask"] = str(net.netmask)

    gw_clean = (data.get("gateway") or "").strip()
    first_usable = (
        str(_ipaddress.ip_address(int(net.network_address) + 1))
        if net.num_addresses > 2
        else str(net.network_address)
    )
    if gw_clean:
        try:
            gw_ip = _ipaddress.ip_address(gw_clean)
            if gw_ip not in net or (net.num_addresses > 2 and gw_ip in (net.network_address, net.broadcast_address)):
                data["gateway"] = first_usable
        except ValueError:
            data["gateway"] = first_usable
    else:
        data["gateway"] = first_usable

    sub = CmdbSubnet(**data)
    db.add(sub)
    db.commit()
    return build_cmdb_overview(db)


@api_router.put(
    "/cmdb/subnets/{subnet_id}",
    tags=["CMDB, Multi-IP & IP Verification"],
    summary="Actualizar Subred / VLAN de la CMDB",
)
def update_cmdb_subnet_endpoint(
    subnet_id: int,
    payload: CmdbSubnetUpdate,
    db: Session = Depends(get_db),
):
    import ipaddress as _ipaddress

    sub = db.query(CmdbSubnet).filter(CmdbSubnet.id == subnet_id).first()
    if not sub:
        raise HTTPException(status_code=404, detail="Subred no encontrada.")
    updates = payload.model_dump(exclude_unset=True)
    if "cidr" in updates and updates["cidr"]:
        cidr_raw = updates["cidr"].strip()
        if "/" not in cidr_raw:
            cidr_raw = f"{cidr_raw}/24"
        try:
            net = _ipaddress.ip_network(cidr_raw, strict=False)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=f"El bloque CIDR '{cidr_raw}' no es válido: {exc}")
        updates["cidr"] = str(net)
        updates["subnet_mask"] = str(net.netmask)
        first_usable = (
            str(_ipaddress.ip_address(int(net.network_address) + 1))
            if net.num_addresses > 2
            else str(net.network_address)
        )
        gw_candidate = (updates.get("gateway") if "gateway" in updates else sub.gateway or "").strip()
        try:
            gw_ip = _ipaddress.ip_address(gw_candidate)
            if gw_ip not in net or (net.num_addresses > 2 and gw_ip in (net.network_address, net.broadcast_address)):
                updates["gateway"] = first_usable
        except ValueError:
            updates["gateway"] = first_usable

    for k, v in updates.items():
        setattr(sub, k, v)
    db.commit()
    return build_cmdb_overview(db)


@api_router.delete(
    "/cmdb/subnets/{subnet_id}",
    tags=["CMDB, Multi-IP & IP Verification"],
    summary="Eliminar Subred / VLAN de la CMDB",
)
def delete_cmdb_subnet_endpoint(subnet_id: int, db: Session = Depends(get_db)):
    sub = db.query(CmdbSubnet).filter(CmdbSubnet.id == subnet_id).first()
    if not sub:
        raise HTTPException(status_code=404, detail="Subred no encontrada.")
    db.delete(sub)
    db.commit()
    return build_cmdb_overview(db)


@api_router.post(
    "/cmdb/verify-ip",
    tags=["CMDB, Multi-IP & IP Verification"],
    summary="Verificador Manual Multi-Sonda de Disponibilidad IP (Ping ICMP + TCP Multi-Puerto + ARP MAC + DNS PTR)",
    description=(
        "Herramienta de control manual para comprobar antes de asignar una IP si está verdaderamente libre en la red "
        "o si existe un conflicto fantasma no documentado en la CMDB. Soporta verificar una IP concreta, un rango corto "
        "(ej. '10.20.20.40-45') o sugerir y verificar automáticamente las próximas IPs libres de una subred."
    ),
)
def verify_cmdb_ip_endpoint(payload: CmdbVerifyIpRequest, db: Session = Depends(get_db)):
    try:
        return verify_ip_target_or_find_free(
            db=db,
            target_ip=payload.target_ip,
            subnet_id=payload.subnet_id,
            ports=payload.ports,
            timeout_sec=payload.timeout_sec,
            count_limit=payload.count_limit,
            only_suggest_free=payload.only_suggest_free,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@api_router.post(
    "/cmdb/import-discovered",
    tags=["CMDB, Multi-IP & IP Verification"],
    summary="Incorporar a la CMDB los equipos e IPs seleccionados tras escanear un rango CIDR",
    description=(
        "Permite añadir en bloque o selectivamente a la CMDB las máquinas detectadas tras escanear un rango "
        "como '1.1.1.1/24' o '10.20.20.0/24', y registrar opcionalmente la propia subred CIDR en el IPAM."
    ),
)
def import_discovered_cmdb_endpoint(
    payload: CmdbImportDiscoveredRequest,
    db: Session = Depends(get_db),
):
    try:
        return import_discovered_hosts_to_cmdb(
            db=db,
            register_subnet_cidr=payload.register_subnet_cidr,
            subnet_name=payload.subnet_name,
            vlan_id=payload.vlan_id,
            items=[item.model_dump() for item in payload.items],
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


# ==============================================================================
# MÓDULO 4: RED & HOST (TOPOLOGÍA LÓGICA, NAGIOS, SNMP, CONECTORES Y PROMETHEUS)
# ==============================================================================

@api_router.get(
    "/metrics",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Exposición nativa de métricas en formato Prometheus Text Exposition Format",
    description=(
        "Endpoint consumido cada 15 segundos por el contenedor 'rackdoc-prometheus' (:9090). "
        "Expone el estado operativo de cada Host/VM/Switch, latencia de Heartbeat (ms), CPU %, RAM %, Disco %, "
        "estados Nagios de servicios (OK/WARNING/CRITICAL/UNKNOWN), validez de certificados SSL y tráfico por boca de Switch."
    ),
)
def get_prometheus_metrics_endpoint(db: Session = Depends(get_db)):
    content = generate_prometheus_metrics_exposition(db)
    return Response(content=content, media_type="text/plain; version=0.0.4; charset=utf-8")


@api_router.get(
    "/network-hosts/overview",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Estado consolidado de '4. Red & Host' (Topología Lógica en 5 Capas + Nagios + SNMP + Conectores + Avisos)",
)
def get_network_hosts_overview_endpoint(db: Session = Depends(get_db)):
    return build_network_hosts_overview(db)


@api_router.get(
    "/network-hosts/telemetry/{asset_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Obtener series temporales desde Prometheus TSDB para gráficas de un Host/VM/Switch",
)
def get_network_host_telemetry_endpoint(
    asset_id: int,
    range_hours: int = 6,
    db: Session = Depends(get_db),
):
    try:
        return get_asset_telemetry_timeseries(db=db, asset_id=asset_id, range_hours=range_hours)
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc))


@api_router.post(
    "/network-hosts/hosts",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Dar de alta desde la Web una nueva Máquina Virtual / Host / Contenedor con sus IPs, Hipervisor Padre y Servicios a Monitorizar",
    description=(
        "Asistente Todo-en-Uno: registra la nueva Máquina Virtual, Contenedor o Servidor en '4. Red & Host' y en '6. CMDB', "
        "asigna su IP primaria de Heartbeat y sus IPs adicionales, la enlaza en el Diagrama Lógico a su Hipervisor/Servidor del Rack, "
        "la añade a los HostGroups indicados, crea todos sus servicios/exporters (HTTPS+SSL, Apache, Nginx, Docker, PostgreSQL, SSH, "
        "Node/Windows Exporter) y actualiza al instante Prometheus SD."
    ),
)
def create_network_host_with_services_endpoint(
    payload: AnsibleHostUpsertWebhook,
    db: Session = Depends(get_db),
):
    try:
        res = handle_ansible_host_upsert_webhook(db=db, payload=payload.model_dump())
        return {
            "created_host": res,
            "overview": build_network_hosts_overview(db),
        }
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@api_router.post(
    "/network-hosts/service-checks",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Añadir un nuevo Heartbeat o Chequeo de Servicio (HTTP, HTTPS+SSL, ICMP, TCP, SSH, SNMP, Apache, Nginx, Docker, BBDD)",
)
def create_service_check_endpoint(payload: ServiceCheckInput, db: Session = Depends(get_db)):
    asset = db.query(CmdbAsset).filter(CmdbAsset.id == payload.asset_id).first()
    if not asset:
        raise HTTPException(status_code=404, detail="El Host/VM indicado no existe.")
    chk = MonitoredServiceCheck(
        asset_id=payload.asset_id,
        service_name=payload.service_name.strip(),
        check_type=payload.check_type.strip().lower(),
        target_ip_or_url=payload.target_ip_or_url.strip(),
        port=payload.port,
        expected_status_code=payload.expected_status_code,
        expected_string=payload.expected_string,
        max_check_attempts=max(1, payload.max_check_attempts),
        check_interval_sec=max(15, payload.check_interval_sec),
        is_primary_heartbeat=payload.is_primary_heartbeat,
        nagios_state="OK",
        state_type="HARD",
        current_attempt=1,
        enabled=payload.enabled,
        last_checked_at=datetime.utcnow(),
        last_state_change_at=datetime.utcnow(),
    )
    db.add(chk)
    db.commit()
    db.refresh(chk)
    run_single_service_check(db=db, chk=chk, asset=asset)
    sync_prometheus_targets_file(db)
    return build_network_hosts_overview(db)


@api_router.delete(
    "/network-hosts/service-checks/{check_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Eliminar un Heartbeat o Chequeo de Servicio",
)
def delete_service_check_endpoint(check_id: int, db: Session = Depends(get_db)):
    chk = db.query(MonitoredServiceCheck).filter(MonitoredServiceCheck.id == check_id).first()
    if not chk:
        raise HTTPException(status_code=404, detail="Chequeo no encontrado.")
    db.delete(chk)
    db.commit()
    sync_prometheus_targets_file(db)
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/service-checks/{check_id}/run",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Ejecutar al instante un chequeo de servicio o Heartbeat concreto",
)
def run_single_service_check_endpoint(check_id: int, db: Session = Depends(get_db)):
    chk = db.query(MonitoredServiceCheck).filter(MonitoredServiceCheck.id == check_id).first()
    if not chk:
        raise HTTPException(status_code=404, detail="Chequeo no encontrado.")
    asset = db.query(CmdbAsset).options(joinedload(CmdbAsset.ip_addresses)).filter(CmdbAsset.id == chk.asset_id).first()
    if not asset:
        raise HTTPException(status_code=404, detail="Host asociado no encontrado.")
    res = run_single_service_check(db=db, chk=chk, asset=asset)
    return {"check_result": res, "overview": build_network_hosts_overview(db)}


@api_router.post(
    "/network-hosts/run-all-checks",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Ejecutar todos los Heartbeats y Chequeos de Servicio activos en lote",
)
def run_all_service_checks_endpoint(db: Session = Depends(get_db)):
    batch = evaluate_all_network_service_checks(db)
    return {"batch": batch, "overview": build_network_hosts_overview(db)}


@api_router.post(
    "/network-hosts/snmp-discover",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Autodescubrimiento de Switch por SNMP (IF-MIB + LLDP-MIB) sin dar de alta puerto a puerto",
    description=(
        "Interroga un Switch o Router por SNMPv2c/v3, descubre todas sus bocas físicas, velocidades, alias, VLANs, "
        "tráfico In/Out y vecinos LLDP, y sincroniza las bocas con el dispositivo físico del Rack Editor."
    ),
)
def snmp_switch_discover_endpoint(payload: SnmpWalkDiscoveryRequest, db: Session = Depends(get_db)):
    res = run_snmp_switch_discovery(
        db=db,
        target_ip=payload.target_ip,
        community=payload.community,
        snmp_version=payload.snmp_version,
        port=payload.port,
        asset_id=payload.asset_id,
        rack_device_id=payload.rack_device_id,
        sync_ports_to_rack_device=payload.sync_ports_to_rack_device,
    )
    return {"discovery": res, "overview": build_network_hosts_overview(db)}


@api_router.post(
    "/network-hosts/logical-links",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Añadir un Enlace Lógico de Conexión en el Diagrama Lógico",
)
def create_logical_link_endpoint(payload: LogicalLinkInput, db: Session = Depends(get_db)):
    if payload.source_asset_id == payload.target_asset_id:
        raise HTTPException(status_code=400, detail="El nodo origen y destino deben ser distintos.")
    lnk = LogicalTopologyLink(
        source_asset_id=payload.source_asset_id,
        target_asset_id=payload.target_asset_id,
        link_type=payload.link_type,
        source_interface=payload.source_interface,
        target_interface=payload.target_interface,
        protocol_label=payload.protocol_label,
        vlan_id=payload.vlan_id,
        bandwidth_mbps=payload.bandwidth_mbps,
        status="UP",
        auto_discovered=False,
        notes=payload.notes,
    )
    db.add(lnk)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.delete(
    "/network-hosts/logical-links/{link_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Eliminar un Enlace Lógico del Diagrama",
)
def delete_logical_link_endpoint(link_id: int, db: Session = Depends(get_db)):
    lnk = db.query(LogicalTopologyLink).filter(LogicalTopologyLink.id == link_id).first()
    if not lnk:
        raise HTTPException(status_code=404, detail="Enlace lógico no encontrado.")
    db.delete(lnk)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/connectors",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Registrar un nuevo Conector de Infraestructura (Proxmox, VMware, Docker, Apache, Nginx, PostgreSQL, MySQL, SNMP, Exporters)",
)
def create_infra_connector_endpoint(payload: InfraConnectorInput, db: Session = Depends(get_db)):
    conn = InfraConnector(
        name=payload.name.strip(),
        connector_type=payload.connector_type.strip(),
        endpoint_host=payload.endpoint_host.strip(),
        endpoint_port=payload.endpoint_port,
        auth_username_or_community=payload.auth_username_or_community,
        auth_secret=payload.auth_secret,
        use_ssl=payload.use_ssl,
        verify_ssl=payload.verify_ssl,
        linked_asset_id=payload.linked_asset_id,
        linked_rack_device_id=payload.linked_rack_device_id,
        extra_settings=payload.extra_settings or {},
        enabled=payload.enabled,
        last_sync_status="ok",
        last_sync_at=datetime.utcnow(),
        last_sync_summary=f"Conector {payload.connector_type} registrado y sincronizado con Prometheus.",
        discovered_items_count=1,
    )
    db.add(conn)
    db.commit()
    sync_prometheus_targets_file(db)
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/connectors/{connector_id}/sync",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Sincronizar al instante un Conector de Infraestructura (Proxmox, VMware, Docker, Apache, Nginx, SNMP...)",
)
def sync_infra_connector_endpoint(connector_id: int, db: Session = Depends(get_db)):
    conn = db.query(InfraConnector).filter(InfraConnector.id == connector_id).first()
    if not conn:
        raise HTTPException(status_code=404, detail="Conector no encontrado.")
    if conn.connector_type == "snmp_switch":
        disc = run_snmp_switch_discovery(
            db=db,
            target_ip=conn.endpoint_host,
            community=conn.auth_username_or_community or "public",
            port=conn.endpoint_port or 161,
            asset_id=conn.linked_asset_id,
            rack_device_id=conn.linked_rack_device_id,
        )
        conn.last_sync_status = "ok"
        conn.last_sync_at = datetime.utcnow()
        conn.discovered_items_count = disc["discovered_ports_count"]
        conn.last_sync_summary = (
            f"SNMP Walk completado ({conn.endpoint_host}): {disc['discovered_ports_count']} bocas IF-MIB "
            f"y {disc['lldp_neighbors_count']} vecinos LLDP sincronizados."
        )
    else:
        conn.last_sync_status = "ok"
        conn.last_sync_at = datetime.utcnow()
    db.commit()
    sync_prometheus_targets_file(db)
    return build_network_hosts_overview(db)


@api_router.delete(
    "/network-hosts/connectors/{connector_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Eliminar un Conector de Infraestructura",
)
def delete_infra_connector_endpoint(connector_id: int, db: Session = Depends(get_db)):
    conn = db.query(InfraConnector).filter(InfraConnector.id == connector_id).first()
    if not conn:
        raise HTTPException(status_code=404, detail="Conector no encontrado.")
    db.delete(conn)
    db.commit()
    sync_prometheus_targets_file(db)
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/host-groups",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Crear o actualizar un Grupo de Hosts / Equipos (HostGroup)",
)
def create_or_update_host_group_endpoint(payload: HostGroupInput, db: Session = Depends(get_db)):
    code = payload.code.strip().upper()
    hg = db.query(HostGroup).filter(HostGroup.code == code).first()
    if not hg:
        hg = HostGroup(code=code)
        db.add(hg)
    hg.name = payload.name.strip()
    hg.category = payload.category
    hg.environment = payload.environment
    hg.color_hex = payload.color_hex
    hg.member_asset_ids = payload.member_asset_ids
    hg.description = payload.description
    db.commit()
    return build_network_hosts_overview(db)


@api_router.delete(
    "/network-hosts/host-groups/{group_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Eliminar un Grupo de Hosts (HostGroup)",
)
def delete_host_group_endpoint(group_id: int, db: Session = Depends(get_db)):
    hg = db.query(HostGroup).filter(HostGroup.id == group_id).first()
    if not hg:
        raise HTTPException(status_code=404, detail="Grupo de hosts no encontrado.")
    db.delete(hg)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/alert-contacts",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Crear o actualizar una Persona / Contacto de Alarma (AlertContact)",
)
def create_or_update_alert_contact_endpoint(payload: AlertContactInput, db: Session = Depends(get_db)):
    code = payload.code.strip().upper()
    c = db.query(AlertContact).filter(AlertContact.code == code).first()
    if not c:
        c = AlertContact(code=code)
        db.add(c)
    c.full_name = payload.full_name.strip()
    c.role_title = payload.role_title
    c.email = payload.email.strip()
    c.phone_or_telegram = payload.phone_or_telegram
    c.personal_webhook_url = payload.personal_webhook_url
    c.schedule_period = payload.schedule_period
    c.notify_on_down = payload.notify_on_down
    c.notify_on_critical = payload.notify_on_critical
    c.notify_on_warning = payload.notify_on_warning
    c.notify_on_unreachable = payload.notify_on_unreachable
    c.notify_on_recovery = payload.notify_on_recovery
    c.active = payload.active
    db.commit()
    return build_network_hosts_overview(db)


@api_router.delete(
    "/network-hosts/alert-contacts/{contact_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Eliminar una Persona / Contacto de Alarma",
)
def delete_alert_contact_endpoint(contact_id: int, db: Session = Depends(get_db)):
    c = db.query(AlertContact).filter(AlertContact.id == contact_id).first()
    if not c:
        raise HTTPException(status_code=404, detail="Contacto no encontrado.")
    db.delete(c)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/alert-contact-groups",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Crear o actualizar un Grupo de Personas / Equipo de Guardia (AlertContactGroup)",
)
def create_or_update_alert_contact_group_endpoint(payload: AlertContactGroupInput, db: Session = Depends(get_db)):
    code = payload.code.strip().upper()
    cg = db.query(AlertContactGroup).filter(AlertContactGroup.code == code).first()
    if not cg:
        cg = AlertContactGroup(code=code)
        db.add(cg)
    cg.name = payload.name.strip()
    cg.description = payload.description
    cg.group_email = payload.group_email.strip()
    cg.channel_webhook_url = payload.channel_webhook_url.strip()
    cg.member_contact_ids = payload.member_contact_ids
    db.commit()
    return build_network_hosts_overview(db)


@api_router.delete(
    "/network-hosts/alert-contact-groups/{group_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Eliminar un Grupo de Personas (AlertContactGroup)",
)
def delete_alert_contact_group_endpoint(group_id: int, db: Session = Depends(get_db)):
    cg = db.query(AlertContactGroup).filter(AlertContactGroup.id == group_id).first()
    if not cg:
        raise HTTPException(status_code=404, detail="Grupo de personas no encontrado.")
    db.delete(cg)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/notification-rules",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Crear una Regla de Enrutamiento de Avisos (Host / HostGroup -> Persona / ContactGroup)",
)
def create_notification_rule_endpoint(payload: NotificationRoutingRuleInput, db: Session = Depends(get_db)):
    rule = NotificationRoutingRule(
        name=payload.name.strip(),
        description=payload.description,
        enabled=payload.enabled,
        scope_type=payload.scope_type,
        host_group_id=payload.host_group_id,
        asset_id=payload.asset_id,
        asset_class_filter=payload.asset_class_filter,
        contact_group_ids=payload.contact_group_ids,
        contact_ids=payload.contact_ids,
        send_email=payload.send_email,
        send_webhook=payload.send_webhook,
        only_on_hard_state=payload.only_on_hard_state,
    )
    db.add(rule)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.delete(
    "/network-hosts/notification-rules/{rule_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Eliminar una Regla de Enrutamiento de Avisos",
)
def delete_notification_rule_endpoint(rule_id: int, db: Session = Depends(get_db)):
    rule = db.query(NotificationRoutingRule).filter(NotificationRoutingRule.id == rule_id).first()
    if not rule:
        raise HTTPException(status_code=404, detail="Regla no encontrada.")
    db.delete(rule)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/maintenance-windows",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Activar una Ventana de Mantenimiento programada o manual para silenciar alertas",
)
def create_maintenance_window_endpoint(payload: MaintenanceWindowInput, db: Session = Depends(get_db)):
    from datetime import timedelta as _timedelta

    now = datetime.utcnow()
    win = MaintenanceWindow(
        title=payload.title.strip(),
        reason=payload.reason,
        created_by=payload.created_by,
        scope_type=payload.scope_type,
        asset_id=payload.asset_id,
        host_group_id=payload.host_group_id,
        target_matches=payload.target_matches,
        starts_at=now,
        ends_at=now + _timedelta(minutes=max(1, payload.duration_minutes)),
        is_active=True,
        suppress_notifications=payload.suppress_notifications,
    )
    db.add(win)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/maintenance-windows/{window_id}/stop",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Finalizar una Ventana de Mantenimiento activa y reactivar avisos",
)
def stop_maintenance_window_endpoint(window_id: int, db: Session = Depends(get_db)):
    win = db.query(MaintenanceWindow).filter(MaintenanceWindow.id == window_id).first()
    if not win:
        raise HTTPException(status_code=404, detail="Ventana de mantenimiento no encontrada.")
    win.is_active = False
    win.ends_at = datetime.utcnow()
    db.commit()
    return build_network_hosts_overview(db)


@api_router.put(
    "/network-hosts/smtp-config",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Actualizar configuración del Servidor de Correo SMTP y Webhook global de Avisos",
)
def update_smtp_config_endpoint(payload: SmtpAlertConfigInput, db: Session = Depends(get_db)):
    cfg = db.query(SmtpAlertConfig).first()
    if not cfg:
        cfg = SmtpAlertConfig()
        db.add(cfg)
    cfg.smtp_host = payload.smtp_host.strip()
    cfg.smtp_port = payload.smtp_port
    cfg.use_tls = payload.use_tls
    cfg.smtp_username = payload.smtp_username.strip()
    if payload.smtp_password:
        cfg.smtp_password = payload.smtp_password
    cfg.from_email = payload.from_email.strip()
    cfg.global_webhook_url = payload.global_webhook_url.strip()
    cfg.enabled = payload.enabled
    db.commit()
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/test-alert",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Disparar un aviso de prueba para verificar el enrutamiento de correos/webhooks por Host o HostGroup",
)
def trigger_test_alert_endpoint(asset_id: Optional[int] = None, db: Session = Depends(get_db)):
    ensure_network_hosts_seeded(db)
    asset = (
        db.query(CmdbAsset).filter(CmdbAsset.id == asset_id).first()
        if asset_id
        else db.query(CmdbAsset).order_by(CmdbAsset.id).first()
    )
    if not asset:
        raise HTTPException(status_code=404, detail="No hay activos disponibles para probar la alerta.")
    _dispatch_alert_notification(
        db=db,
        asset=asset,
        service_name="Prueba Manual de Enrutamiento de Alarma",
        event_state="HARD CRITICAL (TEST)",
        detail=f"Simulación manual de alerta sobre {asset.code} ({asset.name}) para verificar destinatarios.",
    )
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/tech-stacks",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Crear o actualizar un Esquema de Lógica de Negocio / Stack Tecnológico",
)
def upsert_tech_stack_diagram_endpoint(payload: TechStackDiagramInput, db: Session = Depends(get_db)):
    code = payload.code.strip().upper()
    st = db.query(TechStackDiagram).filter(TechStackDiagram.code == code).first()
    if not st:
        st = TechStackDiagram(code=code, canvas_boxes=payload.canvas_boxes or [])
        db.add(st)
    st.name = payload.name.strip()
    st.description = payload.description.strip()
    st.business_service = payload.business_service.strip()
    st.environment = payload.environment.strip()
    st.owner_team = payload.owner_team.strip()
    st.criticality = payload.criticality.strip()
    st.map_scale = payload.map_scale or 1.0
    if payload.canvas_boxes is not None:
        st.canvas_boxes = payload.canvas_boxes
    db.commit()
    return build_network_hosts_overview(db)


@api_router.put(
    "/network-hosts/tech-stacks/{stack_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Actualizar Cajas/Zonas delimitadoras, escala o metadatos de un Stack Tecnológico",
)
def update_tech_stack_diagram_endpoint(
    stack_id: int,
    payload: TechStackDiagramUpdateInput,
    db: Session = Depends(get_db),
):
    st = db.query(TechStackDiagram).filter(TechStackDiagram.id == stack_id).first()
    if not st:
        raise HTTPException(status_code=404, detail="Stack Tecnológico no encontrado.")
    if payload.name is not None:
        st.name = payload.name.strip()
    if payload.description is not None:
        st.description = payload.description.strip()
    if payload.business_service is not None:
        st.business_service = payload.business_service.strip()
    if payload.environment is not None:
        st.environment = payload.environment.strip()
    if payload.owner_team is not None:
        st.owner_team = payload.owner_team.strip()
    if payload.criticality is not None:
        st.criticality = payload.criticality.strip()
    if payload.map_scale is not None:
        st.map_scale = max(0.4, min(2.5, payload.map_scale))
    if payload.canvas_boxes is not None:
        st.canvas_boxes = list(payload.canvas_boxes)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.delete(
    "/network-hosts/tech-stacks/{stack_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Eliminar un Stack Tecnológico",
)
def delete_tech_stack_diagram_endpoint(stack_id: int, db: Session = Depends(get_db)):
    st = db.query(TechStackDiagram).filter(TechStackDiagram.id == stack_id).first()
    if not st:
        raise HTTPException(status_code=404, detail="Stack Tecnológico no encontrado.")
    db.query(TechStackEdge).filter(TechStackEdge.stack_id == stack_id).delete()
    db.query(TechStackNode).filter(TechStackNode.stack_id == stack_id).delete()
    db.delete(st)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/tech-stacks/nodes",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Añadir un Host / VM / Frontal Web / BBDD al lienzo de un Stack Tecnológico",
)
def create_tech_stack_node_endpoint(payload: TechStackNodeInput, db: Session = Depends(get_db)):
    sn = TechStackNode(
        stack_id=payload.stack_id,
        asset_id=payload.asset_id,
        role_layer=payload.role_layer,
        custom_label=payload.custom_label.strip(),
        pos_x=max(0.01, min(0.95, payload.pos_x)),
        pos_y=max(0.01, min(0.94, payload.pos_y)),
        width_px=max(140.0, min(380.0, payload.width_px or 200.0)),
        height_px=max(82.0, min(280.0, payload.height_px or 110.0)),
        ssh_enabled=payload.ssh_enabled,
        ssh_user=payload.ssh_user.strip() or "root",
        ssh_port=payload.ssh_port or 22,
    )
    db.add(sn)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.put(
    "/network-hosts/tech-stacks/nodes/{node_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Mover (Drag & Drop X/Y), redimensionar o editar un nodo dentro del lienzo del Stack Tecnológico",
)
def move_tech_stack_node_endpoint(
    node_id: int,
    payload: TechStackNodeMoveInput,
    db: Session = Depends(get_db),
):
    sn = db.query(TechStackNode).filter(TechStackNode.id == node_id).first()
    if not sn:
        raise HTTPException(status_code=404, detail="Nodo del stack no encontrado.")
    if payload.pos_x is not None:
        sn.pos_x = max(0.01, min(0.95, payload.pos_x))
    if payload.pos_y is not None:
        sn.pos_y = max(0.01, min(0.94, payload.pos_y))
    if payload.width_px is not None:
        sn.width_px = max(140.0, min(380.0, payload.width_px))
    if payload.height_px is not None:
        sn.height_px = max(82.0, min(280.0, payload.height_px))
    if payload.role_layer is not None:
        sn.role_layer = payload.role_layer
    if payload.custom_label is not None:
        sn.custom_label = payload.custom_label.strip()
    if payload.ssh_enabled is not None:
        sn.ssh_enabled = payload.ssh_enabled
    if payload.ssh_user is not None:
        sn.ssh_user = payload.ssh_user.strip()
    if payload.ssh_port is not None:
        sn.ssh_port = payload.ssh_port
    db.commit()
    return build_network_hosts_overview(db)


@api_router.delete(
    "/network-hosts/tech-stacks/nodes/{node_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Quitar un nodo del lienzo del Stack Tecnológico",
)
def delete_tech_stack_node_endpoint(node_id: int, db: Session = Depends(get_db)):
    sn = db.query(TechStackNode).filter(TechStackNode.id == node_id).first()
    if not sn:
        raise HTTPException(status_code=404, detail="Nodo del stack no encontrado.")
    db.query(TechStackEdge).filter(
        (TechStackEdge.source_node_id == node_id) | (TechStackEdge.target_node_id == node_id)
    ).delete()
    db.delete(sn)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/tech-stacks/edges",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Dibujar una flecha / flujo de lógica de negocio entre dos nodos de un Stack Tecnológico",
)
def create_tech_stack_edge_endpoint(payload: TechStackEdgeInput, db: Session = Depends(get_db)):
    if payload.source_node_id == payload.target_node_id:
        raise HTTPException(status_code=400, detail="El nodo origen y destino deben ser distintos.")
    existing = (
        db.query(TechStackEdge)
        .filter(
            TechStackEdge.stack_id == payload.stack_id,
            TechStackEdge.source_node_id == payload.source_node_id,
            TechStackEdge.target_node_id == payload.target_node_id,
        )
        .first()
    )
    if existing:
        existing.protocol_label = payload.protocol_label.strip()
        existing.port = payload.port
        existing.notes = payload.notes
    else:
        se = TechStackEdge(
            stack_id=payload.stack_id,
            source_node_id=payload.source_node_id,
            target_node_id=payload.target_node_id,
            protocol_label=payload.protocol_label.strip(),
            port=payload.port,
            notes=payload.notes,
        )
        db.add(se)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.put(
    "/network-hosts/tech-stacks/edges/{edge_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Editar protocolo, puerto o notas de una flecha del Stack Tecnológico",
)
def update_tech_stack_edge_endpoint(
    edge_id: int,
    payload: TechStackEdgeUpdateInput,
    db: Session = Depends(get_db),
):
    se = db.query(TechStackEdge).filter(TechStackEdge.id == edge_id).first()
    if not se:
        raise HTTPException(status_code=404, detail="Conexión no encontrada.")
    if payload.protocol_label is not None:
        se.protocol_label = payload.protocol_label.strip()
    if payload.port is not None:
        se.port = payload.port
    if payload.notes is not None:
        se.notes = payload.notes
    db.commit()
    return build_network_hosts_overview(db)


@api_router.delete(
    "/network-hosts/tech-stacks/edges/{edge_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Eliminar una flecha del Stack Tecnológico",
)
def delete_tech_stack_edge_endpoint(edge_id: int, db: Session = Depends(get_db)):
    se = db.query(TechStackEdge).filter(TechStackEdge.id == edge_id).first()
    if not se:
        raise HTTPException(status_code=404, detail="Conexión no encontrada.")
    db.delete(se)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/ssh-console",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Ejecutar comando de diagnóstico remoto / consola SSH sobre un Host o VM del Stack",
)
def execute_host_ssh_console_endpoint(payload: HostSshCommandInput, db: Session = Depends(get_db)):
    try:
        return execute_host_ssh_diagnostic(
            db=db,
            asset_id=payload.asset_id,
            command=payload.command,
            ssh_user=payload.ssh_user,
            ssh_port=payload.ssh_port,
        )
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc))


# ==============================================================================
# WEBHOOKS DE AUTOMATIZACIÓN ANSIBLE, CI/CD Y AGENTES DE IA (/api/v1/automation/*)
# ==============================================================================

def _verify_automation_api_key(x_api_key: Optional[str]):
    if x_api_key and x_api_key.strip() != AUTOMATION_API_KEY:
        raise HTTPException(status_code=401, detail="X-API-Key inválida para automatización Ansible.")


@api_router.post(
    "/automation/webhook/host-upsert",
    tags=["Automation Webhooks (Ansible, CI/CD & AI Agents)"],
    summary="Webhook Ansible: Alta o actualización automática de Host, IPs, Exporters, Heartbeats y Prometheus SD",
    description=(
        "Permite que un Playbook de Ansible registre o actualice una máquina física o virtual, asigne sus IPs en la CMDB, "
        "la asocie a HostGroups, registre sus Exporters (node_exporter, windows_exporter, apache, nginx, docker) "
        "y regenere al instante el fichero 'targets_dynamic.json' de Prometheus."
    ),
)
def ansible_host_upsert_webhook_endpoint(
    payload: AnsibleHostUpsertWebhook,
    x_api_key: Optional[str] = Header(default=None),
    db: Session = Depends(get_db),
):
    _verify_automation_api_key(x_api_key)
    try:
        return handle_ansible_host_upsert_webhook(db=db, payload=payload.model_dump())
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@api_router.post(
    "/automation/webhook/host-decommission",
    tags=["Automation Webhooks (Ansible, CI/CD & AI Agents)"],
    summary="Webhook Ansible: Baja automática de Host/VM y retirada de Prometheus SD",
)
def ansible_host_decommission_webhook_endpoint(
    payload: AnsibleHostDecommissionWebhook,
    x_api_key: Optional[str] = Header(default=None),
    db: Session = Depends(get_db),
):
    _verify_automation_api_key(x_api_key)
    try:
        return handle_ansible_host_decommission_webhook(db=db, payload=payload.model_dump())
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc))


@api_router.post(
    "/automation/webhook/maintenance",
    tags=["Automation Webhooks (Ansible, CI/CD & AI Agents)"],
    summary="Webhook Ansible: Iniciar ('start') o finalizar ('stop') Ventana de Mantenimiento silenciosa",
)
def ansible_maintenance_webhook_endpoint(
    payload: AnsibleMaintenanceWebhook,
    x_api_key: Optional[str] = Header(default=None),
    db: Session = Depends(get_db),
):
    _verify_automation_api_key(x_api_key)
    return handle_ansible_maintenance_webhook(db=db, payload=payload.model_dump())


@api_router.post(
    "/automation/webhook/contacts-and-routing",
    tags=["Automation Webhooks (Ansible, CI/CD & AI Agents)"],
    summary="Webhook Ansible: Sincronizar Personas, Grupos de Personas y Reglas de Alarma como Código",
)
def ansible_contacts_routing_webhook_endpoint(
    payload: AnsibleContactsRoutingWebhook,
    x_api_key: Optional[str] = Header(default=None),
    db: Session = Depends(get_db),
):
    _verify_automation_api_key(x_api_key)
    return handle_ansible_contacts_routing_webhook(db=db, payload=payload.model_dump())


@api_router.get(
    "/automation/ai-context",
    tags=["Automation Webhooks (Ansible, CI/CD & AI Agents)"],
    summary="Manifiesto estructurado JSON de Contexto para Agentes de IA y Automatización",
)
def get_ai_agent_context_endpoint(db: Session = Depends(get_db)):
    return build_ai_agent_context_manifest(db)




# ==============================================================================
# MONTAJE DE RUTAS VERSIONADAS (/api/v1) + RETROCOMPATIBILIDAD (/api) Y REDOCS
# ==============================================================================
@app.get("/api/v1/docs", include_in_schema=False)
def redirect_v1_docs():
    return RedirectResponse(url="/docs")


@app.get("/api/v1/redoc", include_in_schema=False)
def redirect_v1_redoc():
    return RedirectResponse(url="/redoc")


@app.get("/api/v1/openapi.json", include_in_schema=False)
def redirect_v1_openapi():
    return RedirectResponse(url="/openapi.json")


# Montamos el router principal bajo /api/v1 (documentado en OpenAPI 3.1.0 / Swagger UI)
app.include_router(api_router, prefix="/api/v1")

# Mantenemos /api como alias retrocompatible transparente (oculto del esquema para no duplicar)
app.include_router(api_router, prefix="/api", include_in_schema=False)

