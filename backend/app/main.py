"""
RackDoc — API del backend.

Este módulo solo ensambla la aplicación: ciclo de vida, CORS y montaje de los
routers. Los endpoints viven en app/routers/, agrupados por dominio.
"""

import asyncio
import os
import uuid

from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import RedirectResponse
from sqlalchemy.orm import Session

from .database import SessionLocal
from .db_migrations import run_migrations
from .logging_setup import configure_logging, get_logger
from .models import Rack, User
from .monitoring_settings import _background_heartbeat_loop, crear_evento_despertar_monitorizacion, despertar_monitorizacion
from .rack_sync import _resync_rack_boxes
from .security import JWT_SECRET_IS_EPHEMERAL, hash_password, is_password_hashed
from .seed import seed_initial_data, sync_system_defaults
from .uploads_store import _sanitize_missing_upload_urls
from .routers._common import api_router, automation_router, public_router
from .services.cmdb_service import ensure_cmdb_seed_data
from .services.network_host_service import ensure_network_hosts_seeded

# Importar cada router registra sus endpoints en los objetos APIRouter de _common.
from .routers import (  # noqa: F401
    system,
    locations,
    device_templates,
    racks,
    reports,
    auth,
    cmdb,
    network_hosts,
    automation,
    certscope,
)

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
        "description": (
            "Módulo 4 'Red & Host': Topología Lógica Interactiva con Monitorización Integrada, "
            "Máquina de Estados Nagios Core (SOFT/HARD + UNREACHABLE), comprobación SNMP de Switches, "
            "registro de Conectores de Infraestructura, Series Temporales Prometheus y Matriz de Avisos. "
            "NO IMPLEMENTADO: el recorrido de bocas IF-MIB / LLDP-MIB (la tabla switch_snmp_ports nunca se "
            "rellena) y la sincronización de los conectores que no son snmp_switch ni exporters de Prometheus, "
            "que no contactan con el sistema remoto. Ver 'Estado de implementación' en el README."
        ),
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
        "description": (
            "Autenticación local con bcrypt + JWT y control de acceso basado en 4 roles "
            "(admin, editor, operator, viewer) aplicado a todas las rutas de /api/v1. "
            "NO IMPLEMENTADO: la autenticación contra Active Directory. No hay cliente LDAP en el backend; "
            "las rutas /ad-servers almacenan configuración, la búsqueda de usuarios devuelve un catálogo de "
            "ejemplo y las cuentas importadas como AD no pueden iniciar sesión. "
            "Ver 'Estado de implementación' en el README."
        ),
    },
]


def _migrate_plaintext_passwords(db: Session) -> int:
    """
    Convierte a bcrypt las contraseñas que quedaran guardadas en texto plano por
    versiones anteriores. Es idempotente: los hashes existentes se dejan como
    están, de forma que los usuarios siguen entrando con la misma contraseña.
    """
    migrated = 0
    for user in db.query(User).all():
        stored = user.password_hash or ""
        if is_password_hashed(stored):
            continue
        # Sin contraseña previa dejamos un hash aleatorio: la cuenta queda sin
        # acceso hasta que un admin le asigne una, en lugar de aceptar "".
        user.password_hash = hash_password(stored or uuid.uuid4().hex)
        migrated += 1
    if migrated:
        db.commit()
        get_logger(__name__).warning(
            "%d contraseña(s) en texto plano migradas a bcrypt.", migrated
        )
    return migrated


def _ensure_demo_floor_devices(db: Session):
    """Sin dispositivos de planta de demostración: el plano de planta arranca limpio para una POC real."""
    return


@asynccontextmanager
async def lifespan(app: FastAPI):
    nivel = configure_logging()
    logger = get_logger(__name__)
    logger.info("Registro iniciado (LOG_LEVEL=%s).", nivel)
    if JWT_SECRET_IS_EPHEMERAL:
        logger.warning(
            "JWT_SECRET no está configurado: se ha generado un secreto aleatorio "
            "para este proceso. Las sesiones caducarán al reiniciar y no se "
            "compartirán entre réplicas. Define JWT_SECRET en producción."
        )
    # El esquema lo gobierna Alembic (backend/alembic/versions), no create_all.
    accion = run_migrations()
    logger.info("Esquema al día mediante Alembic (acción: %s).", accion)
    db = SessionLocal()
    try:
        seed_initial_data(db)
        _migrate_plaintext_passwords(db)
        _ensure_demo_floor_devices(db)
        sync_system_defaults(db)
        _resync_rack_boxes(db, {r_id for (r_id,) in db.query(Rack.id).all()})
        _sanitize_missing_upload_urls(db)
        ensure_cmdb_seed_data(db)
        ensure_network_hosts_seeded(db)
    finally:
        db.close()

    stop_event = asyncio.Event()
    wakeup_event = crear_evento_despertar_monitorizacion()
    worker_task = asyncio.create_task(
        _background_heartbeat_loop(stop_event, wakeup_event)
    )
    try:
        yield
    finally:
        stop_event.set()
        despertar_monitorizacion()
        worker_task.cancel()


app = FastAPI(
    title="RackDoc DCIM API",
    summary="API RESTful OpenAPI 3.1.0 (v1) para Gestión Visual de Centros de Datos, Racks, Red & Host, Prometheus, CMDB y Automatización Ansible",
    description=(
        "Especificación **OpenAPI 3.1.0** de **RackDoc DCIM**.\n\n"
        "- **Prefijo canónico versionado**: `/api/v1` (con soporte retrocompatible en `/api`).\n"
        "- **Módulo 4 Red & Host**: Topología Lógica en 5 Capas, estados Nagios (`UP/DOWN/UNREACHABLE/MAINTENANCE`, `SOFT/HARD`), comprobación SNMP de switches, Conectores de Infraestructura, Matriz de Avisos y Series Temporales en **Prometheus**.\n"
        "- **⚠️ Funciones no implementadas**: el recorrido de bocas `IF-MIB`/`LLDP-MIB`, la sincronización de los conectores que no son `snmp_switch` ni exporters, y la autenticación contra Active Directory. Cada endpoint afectado lo indica en su descripción.\n"
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


# Orígenes permitidos: lista blanca vía CORS_ALLOW_ORIGINS (separados por comas).
# Por defecto solo los puertos locales del frontend. 'allow_credentials' va a False
# porque la sesión viaja en la cabecera Authorization, no en cookies.
_cors_env = (os.getenv("CORS_ALLOW_ORIGINS", "") or "").strip()
CORS_ALLOW_ORIGINS = (
    [o.strip() for o in _cors_env.split(",") if o.strip()]
    if _cors_env
    else [
        "http://localhost:8181",
        "http://127.0.0.1:8181",
        "http://localhost:8180",
        "http://127.0.0.1:8180",
    ]
)


app.add_middleware(
    CORSMiddleware,
    allow_origins=CORS_ALLOW_ORIGINS,
    allow_credentials=False,
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "Accept", "X-API-Key"],
)


# El orden importa: public_router va primero para que rutas fijas como
# /templates/photo-proxy se resuelvan antes que las paramétricas de api_router.
for _prefijo, _en_esquema in (("/api/v1", True), ("/api", False)):
    app.include_router(public_router, prefix=_prefijo, include_in_schema=_en_esquema)
    app.include_router(automation_router, prefix=_prefijo, include_in_schema=_en_esquema)
    app.include_router(api_router, prefix=_prefijo, include_in_schema=_en_esquema)


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
