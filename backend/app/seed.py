"""
Inicialización idempotente del catálogo hardware, usuario administrador inicial y tomas exteriores de rack.
"""

from __future__ import annotations
import os
from sqlalchemy.orm import Session
from .security import hash_password, verify_password
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


def create_ports_from_template(db: Session, device: RackDevice, template: DeviceTemplate) -> list[Port]:
    """
    Genera automáticamente todos los puertos (Front y Back) de un RackDevice
    a partir de la especificación layout_spec de su plantilla.
    Al montar un equipo en Front, rellena automáticamente su cara trasera (Back)
    con sus puertos traseros (fuentes PSU, latiguillos traseros Krone/Cassette, etc.).
    """
    spec = dict(template.layout_spec or {})
    created_ports: list[Port] = []

    back_groups = list(spec.get("back", []))
    if not back_groups and template.category != "external_outlet":
        if template.category in ("patchbox", "patch_panel"):
            back_groups = [
                {
                    "port_type": "rj45",
                    "prefix": "R-",
                    "count": 24,
                    "rows": 2 if template.category == "patchbox" else 1,
                    "start_x": 0.10,
                    "end_x": 0.90,
                }
            ]
        elif template.category in ("switch", "router", "firewall", "server", "gateway", "ups", "pdu"):
            back_groups = [
                {
                    "port_type": "power_c14",
                    "prefix": "PSU",
                    "count": 2,
                    "rows": 1,
                    "start_x": 0.15,
                    "end_x": 0.30,
                }
            ]

    resolved_spec = {
        "front": list(spec.get("front", [])),
        "back": back_groups,
    }

    for tpl_face in ("front", "back"):
        face_groups = resolved_spec.get(tpl_face, [])
        if device.mounted_face == "back":
            effective_face = "back" if tpl_face == "front" else "front"
        else:
            effective_face = tpl_face

        for group in face_groups:
            port_type = group.get("port_type", "rj45")
            prefix = group.get("prefix", "")
            count = int(group.get("count", 0))
            rows = int(group.get("rows", 1))
            start_x = float(group.get("start_x", 0.12))
            end_x = float(group.get("end_x", 0.88))
            start_num = int(group.get("start_num", 1))

            cols = max(1, (count + rows - 1) // rows)
            for idx in range(count):
                r = idx % rows
                c = idx // rows
                num = start_num + idx
                p_num = f"{prefix}{num}" if prefix else str(num)
                rel_x = start_x + (end_x - start_x) * (c / max(1, cols - 1)) if cols > 1 else (start_x + end_x) / 2.0
                rel_y = 0.32 if (rows > 1 and r == 0) else (0.68 if rows > 1 else 0.5)

                port = Port(
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
                db.add(port)
                created_ports.append(port)

    db.flush()
    return created_ports


def seed_initial_data(db: Session):
    """Crea el usuario administrador inicial y la jerarquía base si la base de datos arranca vacía."""
    if db.query(Location).count() > 0:
        return

    # 1. Catálogo de Plantillas de Dispositivos (con caras Front y Back)
    templates_data = [
        {
            "category": "patch_panel",
            "manufacturer": "R&M",
            "model_name": "Patch Panel 24p Cat6A 1U",
            "u_height": 1,
            "is_full_depth": False,
            "default_color": "#FFFFFF",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "", "count": 24, "rows": 1, "start_x": 0.10, "end_x": 0.90}
                ],
                "back": [
                    {"port_type": "rj45", "prefix": "KR-", "count": 24, "rows": 1, "start_x": 0.10, "end_x": 0.90}
                ],
            },
        },
        {
            "category": "patchbox",
            "manufacturer": "PATCHBOX",
            "model_name": "PATCHBOX Plus+ 24p Cat.6a",
            "u_height": 1,
            "is_full_depth": False,
            "default_color": "#F1F5F9",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "", "count": 24, "rows": 2, "start_x": 0.08, "end_x": 0.92}
                ],
                "back": [],
            },
        },
        {
            "category": "switch",
            "manufacturer": "Cisco",
            "model_name": "Catalyst 9300-24T + 4xSFP+",
            "u_height": 1,
            "is_full_depth": False,
            "default_color": "#F8FAFC",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "", "count": 24, "rows": 2, "start_x": 0.35, "end_x": 0.78},
                    {"port_type": "sfp_plus", "prefix": "SFP", "count": 4, "rows": 2, "start_x": 0.82, "end_x": 0.92},
                ],
                "back": [
                    {"port_type": "power_c14", "prefix": "PSU", "count": 2, "rows": 1, "start_x": 0.15, "end_x": 0.30},
                ],
            },
        },
        {
            "category": "router",
            "manufacturer": "MikroTik",
            "model_name": "CCR2116-12G-4S+ Cloud Core Router",
            "u_height": 1,
            "is_full_depth": False,
            "default_color": "#F8FAFC",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "", "count": 8, "rows": 2, "start_x": 0.52, "end_x": 0.72},
                    {"port_type": "sfp_plus", "prefix": "SFP", "count": 4, "rows": 2, "start_x": 0.78, "end_x": 0.88},
                ],
                "back": [
                    {"port_type": "power_c14", "prefix": "PSU", "count": 2, "rows": 1, "start_x": 0.15, "end_x": 0.30},
                ],
            },
        },
        {
            "category": "firewall",
            "manufacturer": "Fortinet",
            "model_name": "FortiGate 200F NGFW 1U",
            "u_height": 1,
            "is_full_depth": False,
            "default_color": "#FEF2F2",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "WAN", "count": 2, "rows": 1, "start_x": 0.25, "end_x": 0.32},
                    {"port_type": "rj45", "prefix": "", "count": 16, "rows": 2, "start_x": 0.38, "end_x": 0.74},
                    {"port_type": "sfp_plus", "prefix": "SFP", "count": 4, "rows": 2, "start_x": 0.80, "end_x": 0.90},
                ],
                "back": [
                    {"port_type": "power_c14", "prefix": "PSU", "count": 2, "rows": 1, "start_x": 0.15, "end_x": 0.28},
                ],
            },
        },
        {
            "category": "gateway",
            "manufacturer": "Ubiquiti",
            "model_name": "Enterprise Fiber Gateway 1U",
            "u_height": 1,
            "is_full_depth": False,
            "default_color": "#FFFFFF",
            "layout_spec": {
                "front": [
                    {"port_type": "fiber_lc", "prefix": "F", "count": 24, "rows": 1, "start_x": 0.10, "end_x": 0.90},
                ],
                "back": [
                    {"port_type": "fiber_lc", "prefix": "TRK", "count": 12, "rows": 1, "start_x": 0.20, "end_x": 0.80},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 1, "rows": 1, "start_x": 0.10, "end_x": 0.12},
                ],
            },
        },
        {
            "category": "server",
            "manufacturer": "HPE",
            "model_name": "ProLiant DL380 Gen11 (2U Full-Depth)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "iLO-F", "count": 1, "rows": 1, "start_x": 0.88, "end_x": 0.90},
                ],
                "back": [
                    {"port_type": "rj45", "prefix": "iLO", "count": 1, "rows": 1, "start_x": 0.12, "end_x": 0.15},
                    {"port_type": "rj45", "prefix": "NIC", "count": 4, "rows": 1, "start_x": 0.22, "end_x": 0.42},
                    {"port_type": "sfp_plus", "prefix": "SFP", "count": 2, "rows": 1, "start_x": 0.50, "end_x": 0.60},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 2, "rows": 1, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },
        {
            "category": "server",
            "manufacturer": "Dell",
            "model_name": "PowerEdge R660 (1U Full-Depth)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "MGMT", "count": 1, "rows": 1, "start_x": 0.90, "end_x": 0.92},
                ],
                "back": [
                    {"port_type": "rj45", "prefix": "iDRAC", "count": 1, "rows": 1, "start_x": 0.12, "end_x": 0.15},
                    {"port_type": "rj45", "prefix": "NIC", "count": 4, "rows": 1, "start_x": 0.24, "end_x": 0.44},
                    {"port_type": "sfp_plus", "prefix": "SFP", "count": 2, "rows": 1, "start_x": 0.52, "end_x": 0.62},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 2, "rows": 1, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },
        {
            "category": "pdu",
            "manufacturer": "APC",
            "model_name": "NetShelter Switched Rack PDU 12x C13 1U",
            "u_height": 1,
            "is_full_depth": False,
            "default_color": "#FEFCE8",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "NET", "count": 1, "rows": 1, "start_x": 0.10, "end_x": 0.14},
                    {"port_type": "power_c13", "prefix": "P", "count": 12, "rows": 1, "start_x": 0.22, "end_x": 0.92},
                ],
                "back": [
                    {"port_type": "power_c14", "prefix": "IN", "count": 1, "rows": 1, "start_x": 0.15, "end_x": 0.20},
                ],
            },
        },
        {
            "category": "ups",
            "manufacturer": "APC",
            "model_name": "Smart-UPS 3000VA LCD 2U (Full-Depth)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F8FAFC",
            "layout_spec": {
                "front": [],
                "back": [
                    {"port_type": "rj45", "prefix": "NMC", "count": 1, "rows": 1, "start_x": 0.12, "end_x": 0.16},
                    {"port_type": "power_c13", "prefix": "OUT", "count": 8, "rows": 2, "start_x": 0.28, "end_x": 0.72},
                    {"port_type": "power_c14", "prefix": "MAIN-IN", "count": 1, "rows": 1, "start_x": 0.86, "end_x": 0.90},
                ],
            },
        },
        {
            "category": "cable_manager",
            "manufacturer": "Rittal",
            "model_name": "Brush Cable Pass-Through 1U",
            "u_height": 1,
            "is_full_depth": False,
            "default_color": "#F8FAFC",
            "layout_spec": {
                "front": [
                    {"port_type": "passthrough", "prefix": "PASS-", "count": 4, "rows": 1, "start_x": 0.20, "end_x": 0.80}
                ],
                "back": [
                    {"port_type": "passthrough", "prefix": "PASS-", "count": 4, "rows": 1, "start_x": 0.20, "end_x": 0.80}
                ],
            },
        },
        {
            "category": "rack_tray",
            "manufacturer": "Rittal",
            "model_name": "Bandeja Ventilada Fija 1U",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F8FAFC",
            "layout_spec": {"front": [], "back": []},
        },
        {
            "category": "rack_tray_device",
            "manufacturer": "Nokia",
            "model_name": "ONT / Conversor Fibra ISP",
            "u_height": 1,
            "is_full_depth": False,
            "default_color": "#F8FAFC",
            "layout_spec": {
                "front": [
                    {"port_type": "fiber_lc", "prefix": "PON", "count": 2, "rows": 1, "start_x": 0.25, "end_x": 0.35},
                    {"port_type": "rj45", "prefix": "LAN", "count": 4, "rows": 1, "start_x": 0.50, "end_x": 0.78},
                ],
                "back": [
                    {"port_type": "power_c14", "prefix": "DC", "count": 1, "rows": 1, "start_x": 0.20, "end_x": 0.25},
                ],
            },
        },
        {
            "category": "miscellaneous",
            "manufacturer": "Generic",
            "model_name": "Panel Ciego / Blank Panel 1U",
            "u_height": 1,
            "is_full_depth": False,
            "default_color": "#FFFFFF",
            "layout_spec": {"front": [], "back": []},
        },
        {
            "category": "miscellaneous",
            "manufacturer": "Rittal / APC",
            "model_name": "Ventiladores de Techo 1U (Smart Roof Fan + ETH)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F0F9FF",
            "layout_spec": {
                "front": [
                    {
                        "port_type": "rj45",
                        "prefix": "ETH",
                        "count": 1,
                        "rows": 1,
                        "start_x": 0.16,
                        "end_x": 0.20,
                    },
                    {
                        "port_type": "power_plug_male",
                        "prefix": "MACHO-IN",
                        "count": 1,
                        "rows": 1,
                        "start_x": 0.86,
                        "end_x": 0.90,
                    },
                ],
                "back": [
                    {
                        "port_type": "rj45",
                        "prefix": "ETH-R",
                        "count": 1,
                        "rows": 1,
                        "start_x": 0.16,
                        "end_x": 0.20,
                    },
                    {
                        "port_type": "power_c14",
                        "prefix": "PSU",
                        "count": 1,
                        "rows": 1,
                        "start_x": 0.86,
                        "end_x": 0.90,
                    },
                ],
            },
        },
        {
            "category": "miscellaneous",
            "manufacturer": "Rittal",
            "model_name": "Bandeja Regulable en U (1U por defecto — U Editable)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F8FAFC",
            "layout_spec": {"front": [], "back": []},
        },
    ]

    tpl_map: dict[str, DeviceTemplate] = {}
    for td in templates_data:
        t = DeviceTemplate(**td)
        db.add(t)
        db.flush()
        tpl_map[f"{td['category']}:{td['model_name']}"] = t
        tpl_map[td["category"]] = t

    # 2. Estructura limpia inicial para POC Real (1 Sede, 1 Planta, 1 Sala y 1 Rack vacío sin equipos ni cables inventados)
    loc_poc = Location(
        code="CPD-01",
        name="Centro de Datos Principal (POC)",
        latitude=40.4168,
        longitude=-3.7038,
        address="CPD Principal",
        description="Sede inicial limpia para Prueba de Concepto (POC) real.",
    )
    db.add(loc_poc)
    db.flush()

    f_poc = Floor(location_id=loc_poc.id, name="Planta Principal CPD", level_number=1)
    db.add(f_poc)
    db.flush()

    room_poc = Room(floor_id=f_poc.id, name="Sala Técnica 01", width_m=12.0, depth_m=8.0)
    db.add(room_poc)
    db.flush()

    aisle_poc = Aisle(room_id=room_poc.id, code="PASILLO-A", name="Pasillo Frío A", aisle_type="cold")
    db.add(aisle_poc)
    db.flush()

    rack_poc = Rack(
        room_id=room_poc.id,
        aisle_id=aisle_poc.id,
        code="RACK-01",
        name="Rack Principal 01",
        total_units=42,
        manufacturer="Rittal",
        model_name="VX IT 42U 800x1000",
        serial_number="",
        responsible_person="",
        pos_x=2.0,
        pos_y=2.0,
        notes="Rack limpio listo para montar equipamiento real de la POC.",
    )
    db.add(rack_poc)
    db.commit()


def get_or_create_external_feed_template(db: Session) -> DeviceTemplate:
    """Obtiene o registra la plantilla de sistema para tomas eléctricas Schuko o cajas de fibra exteriores."""
    tpl = (
        db.query(DeviceTemplate)
        .filter(DeviceTemplate.category == "external_power_feed")
        .first()
    )
    if not tpl:
        tpl = DeviceTemplate(
            library_group="Power",
            category="external_power_feed",
            manufacturer="Industrial Schuko",
            model_name="Cuadro Tomas Schuko Exterior",
            u_height=1,
            is_full_depth=True,
            default_color="#FEF2F2",
            layout_spec={"front": [], "back": []},
        )
        db.add(tpl)
        db.flush()
    return tpl


def sync_external_outlet_ports(db: Session, device: RackDevice, socket_count: int):
    """Sincroniza el número y geometría de bocas de una toma exterior de rack."""
    cf = dict(device.custom_fields or {})
    feed_type = str(cf.get("feed_type") or "power").lower()
    is_fiber = feed_type == "fiber"
    max_sockets = 48 if is_fiber else 16
    socket_count = max(1, min(max_sockets, int(socket_count)))
    existing_ports = sorted(device.ports, key=lambda p: p.col_index)

    # Si sobran puertos no conectados, borrarlos desde el final
    while len(existing_ports) > socket_count:
        cand = existing_ports.pop()
        has_conn = (
            db.query(Connection)
            .filter(
                (Connection.source_port_id == cand.id)
                | (Connection.target_port_id == cand.id)
            )
            .first()
        )
        if not has_conn:
            db.delete(cand)

    prefix = "FO" if is_fiber else "SCH"
    p_type = "fiber_lc" if is_fiber else "power_schuko"

    # Actualizar tipo/prefijo de los existentes si cambió feed_type
    for idx, p in enumerate(existing_ports):
        num = idx + 1
        p.port_number = f"{prefix}{num}"
        p.label = f"{device.code}:{prefix}{num}"
        p.port_type = p_type

    # Si faltan puertos, crearlos
    current_len = len(existing_ports)
    for idx in range(current_len, socket_count):
        num = idx + 1
        p_num = f"{prefix}{num}"
        port = Port(
            rack_device_id=device.id,
            port_number=p_num,
            label=f"{device.code}:{p_num}",
            face="front",
            port_type=p_type,
            row_index=0,
            col_index=idx,
            rel_x=round(0.10 + 0.80 * (idx / max(1, socket_count - 1)), 4),
            rel_y=0.5,
        )
        db.add(port)

    db.flush()


def ensure_rack_external_outlets(db: Session, rack: Rack):
    """Garantiza que el bastidor disponga de sus regletas/cajas de acometida exterior por defecto."""
    ext_devices = [d for d in rack.devices if d.mounted_face == "external"]
    tpl = get_or_create_external_feed_template(db)

    has_power = any(
        (d.custom_fields or {}).get("feed_type", "power") == "power"
        for d in ext_devices
    )
    has_fiber = any(
        (d.custom_fields or {}).get("feed_type") == "fiber"
        for d in ext_devices
    )

    if not has_power:
        feed_a = RackDevice(
            rack_id=rack.id,
            template_id=tpl.id,
            code="TOMA-A",
            name="Línea Eléctrica A (Schuko Rojo)",
            hostname="feed-a",
            start_u=38,
            mounted_face="external",
            status="online",
            custom_fields={
                "is_external_feed": True,
                "feed_type": "power",
                "feed_color": "#DC2626",
                "socket_count": 4,
            },
            notes="Acometida eléctrica exterior Línea A (Estándar Rojo)",
        )
        feed_b = RackDevice(
            rack_id=rack.id,
            template_id=tpl.id,
            code="TOMA-B",
            name="Línea Eléctrica B (Schuko Azul)",
            hostname="feed-b",
            start_u=22,
            mounted_face="external",
            status="online",
            custom_fields={
                "is_external_feed": True,
                "feed_type": "power",
                "feed_color": "#2563EB",
                "socket_count": 4,
            },
            notes="Acometida eléctrica exterior Línea B (Estándar Azul)",
        )
        db.add_all([feed_a, feed_b])
        db.flush()
        sync_external_outlet_ports(db, feed_a, 4)
        sync_external_outlet_ports(db, feed_b, 4)
    else:
        feed_a = next((d for d in ext_devices if d.code == "TOMA-A"), None)
        feed_b = next((d for d in ext_devices if d.code == "TOMA-B"), None)

    if not has_fiber:
        fiber_ext = RackDevice(
            rack_id=rack.id,
            template_id=tpl.id,
            code="FIBRA-EXT-1",
            name="Toma Exterior de Fibra Óptica (LC/SC)",
            hostname="fiber-ext-1",
            start_u=41,
            mounted_face="external",
            status="online",
            custom_fields={
                "is_external_feed": True,
                "feed_type": "fiber",
                "feed_color": "#0284C7",
                "socket_count": 8,
            },
            notes="Roseta / Caja mural exterior de Fibra Óptica con número de conectores ajustable",
        )
        db.add(fiber_ext)
        db.flush()
        sync_external_outlet_ports(db, fiber_ext, 8)

    if has_power and has_fiber:
        return

    # Si este rack es RK001_M y tiene UPS01 / PDU-B con entrada libre, conectarlos como ejemplo visual
    if rack.code == "RK001_M":
        db.refresh(feed_a)
        db.refresh(feed_b)
        ups_in = (
            db.query(Port)
            .join(RackDevice, Port.rack_device_id == RackDevice.id)
            .filter(
                RackDevice.rack_id == rack.id,
                RackDevice.code == "UPS01",
                Port.port_number == "MAIN-IN1",
            )
            .first()
        )
        pdu_b_in = (
            db.query(Port)
            .join(RackDevice, Port.rack_device_id == RackDevice.id)
            .filter(
                RackDevice.rack_id == rack.id,
                RackDevice.code == "PDU-B",
                Port.port_number == "IN1",
            )
            .first()
        )
        if ups_in and feed_a.ports:
            sch1_a = feed_a.ports[0]
            already = (
                db.query(Connection)
                .filter(
                    Connection.source_port_id.in_([sch1_a.id, ups_in.id])
                    | Connection.target_port_id.in_([sch1_a.id, ups_in.id])
                )
                .first()
            )
            if not already:
                db.add(
                    Connection(
                        source_port_id=sch1_a.id,
                        target_port_id=ups_in.id,
                        cable_type="power_ac",
                        color_hex="#DC2626",
                        routing_channel="right",
                        label="Acometida Schuko TOMA-A (Rojo) -> UPS01",
                        length_m=2.0,
                    )
                )
        if pdu_b_in and feed_b.ports:
            sch1_b = feed_b.ports[0]
            already = (
                db.query(Connection)
                .filter(
                    Connection.source_port_id.in_([sch1_b.id, pdu_b_in.id])
                    | Connection.target_port_id.in_([sch1_b.id, pdu_b_in.id])
                )
                .first()
            )
            if not already:
                db.add(
                    Connection(
                        source_port_id=sch1_b.id,
                        target_port_id=pdu_b_in.id,
                        cable_type="power_ac",
                        color_hex="#2563EB",
                        routing_channel="right",
                        label="Acometida Schuko TOMA-B (Azul) -> PDU-B",
                        length_m=2.0,
                    )
                )


def sync_system_defaults(db: Session):
    """
    Asegura en cada arranque:
    1. Usuario admin configurado según variables .env (ADMIN_USERNAME / ADMIN_PASSWORD) y usuarios/AD de ejemplo.
    2. Clasificación por grupos de librerías ('Network', 'Power', 'Host - HP', 'Host - Dell', 'Patching & Passive')
       más plantillas de enchufes Schuko y servidores HP.
    3. Tomas de corriente Schuko exteriores (TOMA-A Roja y TOMA-B Azul) en cada Rack existente.
    """
    admin_user = os.getenv("ADMIN_USERNAME", "admin").strip() or "admin"
    admin_pass = os.getenv("ADMIN_PASSWORD", "admin").strip() or "admin"
    admin_email = os.getenv("ADMIN_EMAIL", "admin@rackdoc.local").strip()

    existing_admin = db.query(User).filter(User.username == admin_user).first()
    if not existing_admin:
        existing_admin = db.query(User).filter(User.role == "admin").first()
    if existing_admin:
        existing_admin.username = admin_user
        # Solo se re-escribe el hash si la contraseña de .env ha cambiado, para no
        # invalidar en cada arranque una contraseña ya rotada desde la interfaz.
        if not verify_password(admin_pass, existing_admin.password_hash):
            existing_admin.password_hash = hash_password(admin_pass)
        existing_admin.role = "admin"
        existing_admin.is_active = True
        if not existing_admin.full_name:
            existing_admin.full_name = "Administrador Principal"
        if not existing_admin.email:
            existing_admin.email = admin_email
    else:
        db.add(
            User(
                username=admin_user,
                email=admin_email,
                full_name="Administrador Principal (.env)",
                password_hash=hash_password(admin_pass),
                role="admin",
                auth_source="local",
                is_active=True,
            )
        )
    db.flush()

    # Sin servidores AD ni usuarios ficticios por defecto: solo el administrador real definido en .env

    # Actualizar library_group de todas las plantillas existentes
    all_tpls = db.query(DeviceTemplate).all()
    for t in all_tpls:
        if t.category in ("switch", "router", "firewall", "gateway"):
            if not t.library_group or t.library_group == "Network":
                t.library_group = "Network"
        elif t.category in ("pdu", "ups", "schuko", "external_power_feed"):
            t.library_group = "Power"
        elif t.category == "server":
            if "hp" in t.manufacturer.lower():
                t.library_group = "Host - HP"
            elif "dell" in t.manufacturer.lower():
                t.library_group = "Host - Dell"
            elif "supermicro" in t.manufacturer.lower():
                t.library_group = "Host - Supermicro"
            elif not t.library_group or t.library_group == "Network":
                t.library_group = "Host - HP"
        else:
            if t.library_group == "Network":
                t.library_group = "Patching & Passive"

    def _srv_spec(front_mgmt: str, back_mgmt: str, nics: int = 4, sfps: int = 2, psus: int = 2):
        back_list = [
            {
                "port_type": "rj45",
                "prefix": back_mgmt,
                "count": 1,
                "rows": 1,
                "start_x": 0.10,
                "end_x": 0.14,
            }
        ]
        if nics > 0:
            back_list.append(
                {
                    "port_type": "rj45",
                    "prefix": "NIC",
                    "count": nics,
                    "rows": 1,
                    "start_x": 0.22,
                    "end_x": 0.44,
                }
            )
        if sfps > 0:
            back_list.append(
                {
                    "port_type": "sfp_plus",
                    "prefix": "SFP",
                    "count": sfps,
                    "rows": 1,
                    "start_x": 0.50,
                    "end_x": 0.66,
                }
            )
        if psus > 0:
            back_list.append(
                {
                    "port_type": "power_c14",
                    "prefix": "PSU",
                    "count": psus,
                    "rows": 1,
                    "start_x": 0.74,
                    "end_x": 0.92,
                }
            )
        return {
            "front": [
                {
                    "port_type": "rj45",
                    "prefix": front_mgmt,
                    "count": 1,
                    "rows": 1,
                    "start_x": 0.88,
                    "end_x": 0.92,
                }
            ],
            "back": back_list,
        }

    # Asegurar plantillas adicionales para 'Network' (Switches 48p), 'Patching & Passive' (Patch Panel 48p), 'Power', 'Host - HP', 'Host - Dell' y 'Host - Supermicro'
    extra_templates = [
        # --- NETWORK (SWITCHES 48 PUERTOS + SFP+) ---
        {
            "library_group": "Network",
            "category": "switch",
            "manufacturer": "Cisco",
            "model_name": "Catalyst 9300-48P PoE+ (48x RJ45 + 4x SFP+)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F8FAFC",
            "layout_spec": {
                "front": [
                    {
                        "port_type": "rj45",
                        "prefix": "",
                        "count": 48,
                        "rows": 2,
                        "start_x": 0.06,
                        "end_x": 0.81,
                    },
                    {
                        "port_type": "sfp_plus",
                        "prefix": "SFP",
                        "count": 4,
                        "rows": 2,
                        "start_x": 0.85,
                        "end_x": 0.94,
                    },
                ],
                "back": [
                    {
                        "port_type": "power_c14",
                        "prefix": "PSU",
                        "count": 2,
                        "rows": 1,
                        "start_x": 0.15,
                        "end_x": 0.30,
                    },
                ],
            },
        },
        {
            "library_group": "Network",
            "category": "switch",
            "manufacturer": "HPE Aruba",
            "model_name": "Aruba CX 6300M 48G PoE+ (48x RJ45 + 4x SFP56)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F8FAFC",
            "layout_spec": {
                "front": [
                    {
                        "port_type": "rj45",
                        "prefix": "",
                        "count": 48,
                        "rows": 2,
                        "start_x": 0.06,
                        "end_x": 0.81,
                    },
                    {
                        "port_type": "sfp_plus",
                        "prefix": "SFP",
                        "count": 4,
                        "rows": 2,
                        "start_x": 0.85,
                        "end_x": 0.94,
                    },
                ],
                "back": [
                    {
                        "port_type": "power_c14",
                        "prefix": "PSU",
                        "count": 2,
                        "rows": 1,
                        "start_x": 0.15,
                        "end_x": 0.30,
                    },
                ],
            },
        },
        {
            "library_group": "Network",
            "category": "switch",
            "manufacturer": "Ubiquiti",
            "model_name": "UniFi Pro Max 48 PoE (48x RJ45 + 4x SFP+)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F8FAFC",
            "layout_spec": {
                "front": [
                    {
                        "port_type": "rj45",
                        "prefix": "",
                        "count": 48,
                        "rows": 2,
                        "start_x": 0.06,
                        "end_x": 0.81,
                    },
                    {
                        "port_type": "sfp_plus",
                        "prefix": "SFP",
                        "count": 4,
                        "rows": 2,
                        "start_x": 0.85,
                        "end_x": 0.94,
                    },
                ],
                "back": [
                    {
                        "port_type": "power_c14",
                        "prefix": "PSU",
                        "count": 2,
                        "rows": 1,
                        "start_x": 0.15,
                        "end_x": 0.30,
                    },
                ],
            },
        },
        {
            "library_group": "Patching & Passive",
            "category": "patch_panel",
            "manufacturer": "R&M",
            "model_name": "Patch Panel 48p Cat6A Alta Densidad (48x RJ45)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#FFFFFF",
            "layout_spec": {
                "front": [
                    {
                        "port_type": "rj45",
                        "prefix": "",
                        "count": 48,
                        "rows": 2,
                        "start_x": 0.08,
                        "end_x": 0.92,
                    }
                ],
                "back": [
                    {
                        "port_type": "rj45",
                        "prefix": "KR-",
                        "count": 48,
                        "rows": 2,
                        "start_x": 0.08,
                        "end_x": 0.92,
                    }
                ],
            },
        },
        # --- POWER ---
        {
            "library_group": "Power",
            "category": "pdu",
            "manufacturer": "Rittal",
            "model_name": "Regleta PDU 8x Enchufes Schuko 1U",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#FEFCE8",
            "layout_spec": {
                "front": [
                    {
                        "port_type": "power_plug_male",
                        "prefix": "MACHO-IN",
                        "count": 1,
                        "rows": 1,
                        "start_x": 0.09,
                        "end_x": 0.12,
                    },
                    {
                        "port_type": "power_schuko",
                        "prefix": "SCH",
                        "count": 8,
                        "rows": 1,
                        "start_x": 0.22,
                        "end_x": 0.90,
                    },
                ],
                "back": [
                    {
                        "port_type": "power_plug_male",
                        "prefix": "IN",
                        "count": 1,
                        "rows": 1,
                        "start_x": 0.14,
                        "end_x": 0.20,
                    }
                ],
            },
        },
        {
            "library_group": "Power",
            "category": "pdu",
            "manufacturer": "Schneider",
            "model_name": "Enchufe Schuko Simple / Doble Carril DIN 1U",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#FEF2F2",
            "layout_spec": {
                "front": [
                    {
                        "port_type": "power_plug_male",
                        "prefix": "MACHO-IN",
                        "count": 1,
                        "rows": 1,
                        "start_x": 0.10,
                        "end_x": 0.14,
                    },
                    {
                        "port_type": "power_schuko",
                        "prefix": "SCH",
                        "count": 2,
                        "rows": 1,
                        "start_x": 0.35,
                        "end_x": 0.65,
                    },
                ],
                "back": [
                    {
                        "port_type": "power_plug_male",
                        "prefix": "IN",
                        "count": 1,
                        "rows": 1,
                        "start_x": 0.20,
                        "end_x": 0.25,
                    }
                ],
            },
        },

        # --- HOST - HP (HPE ProLiant / Alletra / Apollo / SimpliVity — 12 modelos en total con DL380 Gen11) ---
        {
            "library_group": "Host - HP",
            "category": "server",
            "manufacturer": "HPE",
            "model_name": "ProLiant DL360 Gen11 (1U Full-Depth)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("iLO-F", "iLO", nics=4, sfps=2, psus=2),
        },
        {
            "library_group": "Host - HP",
            "category": "server",
            "manufacturer": "HPE",
            "model_name": "ProLiant DL320 Gen11 (1U Single-Socket Edge)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("iLO-F", "iLO", nics=2, sfps=2, psus=2),
        },
        {
            "library_group": "Host - HP",
            "category": "server",
            "manufacturer": "HPE",
            "model_name": "ProLiant DL345 Gen11 (2U AMD EPYC Storage)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("iLO-F", "iLO", nics=4, sfps=2, psus=2),
        },
        {
            "library_group": "Host - HP",
            "category": "server",
            "manufacturer": "HPE",
            "model_name": "ProLiant DL365 Gen11 (1U Dual AMD EPYC)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("iLO-F", "iLO", nics=4, sfps=2, psus=2),
        },
        {
            "library_group": "Host - HP",
            "category": "server",
            "manufacturer": "HPE",
            "model_name": "ProLiant DL385 Gen11 (2U Dual AMD EPYC GPU)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("iLO-F", "iLO", nics=4, sfps=4, psus=2),
        },
        {
            "library_group": "Host - HP",
            "category": "server",
            "manufacturer": "HPE",
            "model_name": "ProLiant DL560 Gen11 (2U Quad-Socket SAP HANA)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("iLO-F", "iLO", nics=4, sfps=4, psus=4),
        },
        {
            "library_group": "Host - HP",
            "category": "server",
            "manufacturer": "HPE",
            "model_name": "ProLiant DL380a Gen11 (4U 4x GPU AI Workload)",
            "u_height": 4,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("iLO-F", "iLO", nics=4, sfps=4, psus=4),
        },
        {
            "library_group": "Host - HP",
            "category": "server",
            "manufacturer": "HPE",
            "model_name": "ProLiant DL20 Gen11 (1U Short-Depth Branch)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("iLO-F", "iLO", nics=2, sfps=0, psus=2),
        },
        {
            "library_group": "Host - HP",
            "category": "server",
            "manufacturer": "HPE",
            "model_name": "ProLiant DL380 Gen10 Plus (2U Enterprise)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("iLO-F", "iLO", nics=4, sfps=2, psus=2),
        },
        {
            "library_group": "Host - HP",
            "category": "server",
            "manufacturer": "HPE",
            "model_name": "Alletra Storage Server 4120 (2U 24x NVMe)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("iLO-F", "iLO", nics=2, sfps=4, psus=2),
        },
        {
            "library_group": "Host - HP",
            "category": "server",
            "manufacturer": "HPE",
            "model_name": "Apollo 4200 Gen10 Plus (2U 28-Bay LFF Storage)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("iLO-F", "iLO", nics=4, sfps=2, psus=2),
        },
        {
            "library_group": "Host - HP",
            "category": "server",
            "manufacturer": "HPE",
            "model_name": "SimpliVity 380 Gen11 (2U Hyperconverged Node)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("iLO-F", "iLO", nics=4, sfps=4, psus=2),
        },

        # --- HOST - DELL (Dell PowerEdge / VxRail — 12 modelos en total con R660) ---
        {
            "library_group": "Host - Dell",
            "category": "server",
            "manufacturer": "Dell",
            "model_name": "PowerEdge R760 (2U Dual Xeon Flagship)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("MGMT", "iDRAC", nics=4, sfps=2, psus=2),
        },
        {
            "library_group": "Host - Dell",
            "category": "server",
            "manufacturer": "Dell",
            "model_name": "PowerEdge R760xs (2U Virtualization & SDS)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("MGMT", "iDRAC", nics=4, sfps=2, psus=2),
        },
        {
            "library_group": "Host - Dell",
            "category": "server",
            "manufacturer": "Dell",
            "model_name": "PowerEdge R660xs (1U Dense Cloud Compute)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("MGMT", "iDRAC", nics=4, sfps=2, psus=2),
        },
        {
            "library_group": "Host - Dell",
            "category": "server",
            "manufacturer": "Dell",
            "model_name": "PowerEdge R6615 (1U Single AMD EPYC 9004)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("MGMT", "iDRAC", nics=2, sfps=2, psus=2),
        },
        {
            "library_group": "Host - Dell",
            "category": "server",
            "manufacturer": "Dell",
            "model_name": "PowerEdge R6625 (1U Dual AMD EPYC 9004)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("MGMT", "iDRAC", nics=4, sfps=2, psus=2),
        },
        {
            "library_group": "Host - Dell",
            "category": "server",
            "manufacturer": "Dell",
            "model_name": "PowerEdge R7615 (2U Single AMD EPYC NVMe)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("MGMT", "iDRAC", nics=4, sfps=2, psus=2),
        },
        {
            "library_group": "Host - Dell",
            "category": "server",
            "manufacturer": "Dell",
            "model_name": "PowerEdge R7625 (2U Dual AMD EPYC AI/DB)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("MGMT", "iDRAC", nics=4, sfps=4, psus=2),
        },
        {
            "library_group": "Host - Dell",
            "category": "server",
            "manufacturer": "Dell",
            "model_name": "PowerEdge R860 (2U Quad-Socket SAP HANA)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("MGMT", "iDRAC", nics=4, sfps=4, psus=4),
        },
        {
            "library_group": "Host - Dell",
            "category": "server",
            "manufacturer": "Dell",
            "model_name": "PowerEdge R960 (4U Quad-Socket Mission Critical)",
            "u_height": 4,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("MGMT", "iDRAC", nics=4, sfps=4, psus=4),
        },
        {
            "library_group": "Host - Dell",
            "category": "server",
            "manufacturer": "Dell",
            "model_name": "PowerEdge R360 (1U Entry Xeon E-2400)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("MGMT", "iDRAC", nics=2, sfps=0, psus=2),
        },
        {
            "library_group": "Host - Dell",
            "category": "server",
            "manufacturer": "Dell",
            "model_name": "PowerEdge XE8640 (4U 4x H100 GPU AI Server)",
            "u_height": 4,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("MGMT", "iDRAC", nics=4, sfps=4, psus=4),
        },
        {
            "library_group": "Host - Dell",
            "category": "server",
            "manufacturer": "Dell",
            "model_name": "VxRail P670F (2U All-Flash vSAN HCI Node)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("MGMT", "iDRAC", nics=4, sfps=4, psus=2),
        },

        # --- HOST - SUPERMICRO (Supermicro Hyper / A+ / CloudDC / Storage / BigTwin / GPU — 11 modelos) ---
        {
            "library_group": "Host - Supermicro",
            "category": "server",
            "manufacturer": "Supermicro",
            "model_name": "Hyper SuperServer SYS-121H-TNR (1U Dual Xeon)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("IPMI-F", "IPMI", nics=4, sfps=2, psus=2),
        },
        {
            "library_group": "Host - Supermicro",
            "category": "server",
            "manufacturer": "Supermicro",
            "model_name": "Hyper SuperServer SYS-221H-TNR (2U Dual Xeon)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("IPMI-F", "IPMI", nics=4, sfps=2, psus=2),
        },
        {
            "library_group": "Host - Supermicro",
            "category": "server",
            "manufacturer": "Supermicro",
            "model_name": "A+ Server AS-1115HS-TNR (1U Single AMD EPYC)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("IPMI-F", "IPMI", nics=2, sfps=2, psus=2),
        },
        {
            "library_group": "Host - Supermicro",
            "category": "server",
            "manufacturer": "Supermicro",
            "model_name": "A+ Server AS-2115HS-TNR (2U 24x NVMe EPYC)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("IPMI-F", "IPMI", nics=4, sfps=2, psus=2),
        },
        {
            "library_group": "Host - Supermicro",
            "category": "server",
            "manufacturer": "Supermicro",
            "model_name": "A+ Server AS-2125HS-TNR (2U Dual AMD EPYC)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("IPMI-F", "IPMI", nics=4, sfps=4, psus=2),
        },
        {
            "library_group": "Host - Supermicro",
            "category": "server",
            "manufacturer": "Supermicro",
            "model_name": "CloudDC SYS-111C-NR (1U Single Xeon All-Flash)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("IPMI-F", "IPMI", nics=2, sfps=2, psus=2),
        },
        {
            "library_group": "Host - Supermicro",
            "category": "server",
            "manufacturer": "Supermicro",
            "model_name": "CloudDC SYS-621C-TN12R (2U 12-Bay LFF Hybrid)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("IPMI-F", "IPMI", nics=4, sfps=2, psus=2),
        },
        {
            "library_group": "Host - Supermicro",
            "category": "server",
            "manufacturer": "Supermicro",
            "model_name": "SuperStorage SSG-621E-ACR12H (2U Ceph/ZFS Storage)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("IPMI-F", "IPMI", nics=2, sfps=4, psus=2),
        },
        {
            "library_group": "Host - Supermicro",
            "category": "server",
            "manufacturer": "Supermicro",
            "model_name": "Petascale SYS-121E-NE316R (1U 16x E3.S NVMe)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("IPMI-F", "IPMI", nics=2, sfps=4, psus=2),
        },
        {
            "library_group": "Host - Supermicro",
            "category": "server",
            "manufacturer": "Supermicro",
            "model_name": "BigTwin SYS-221BT-HNTR (2U 4-Node HCI Chassis)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("IPMI-F", "IPMI", nics=4, sfps=4, psus=2),
        },
        {
            "library_group": "Host - Supermicro",
            "category": "server",
            "manufacturer": "Supermicro",
            "model_name": "GPU SuperServer SYS-421GE-TNRT (4U 8x GPU AI)",
            "u_height": 4,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": _srv_spec("IPMI-F", "IPMI", nics=4, sfps=4, psus=4),
        },

        # --- MISCELLANEOUS & BANDEJAS (Ventiladores de Techo 1U con ETH + Bandejas de 1U con U Editable) ---
        {
            "library_group": "Patching & Passive",
            "category": "miscellaneous",
            "manufacturer": "Rittal / APC",
            "model_name": "Ventiladores de Techo 1U (Smart Roof Fan + ETH)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F0F9FF",
            "layout_spec": {
                "front": [
                    {
                        "port_type": "rj45",
                        "prefix": "ETH",
                        "count": 1,
                        "rows": 1,
                        "start_x": 0.16,
                        "end_x": 0.20,
                    },
                    {
                        "port_type": "power_plug_male",
                        "prefix": "MACHO-IN",
                        "count": 1,
                        "rows": 1,
                        "start_x": 0.86,
                        "end_x": 0.90,
                    },
                ],
                "back": [
                    {
                        "port_type": "rj45",
                        "prefix": "ETH-R",
                        "count": 1,
                        "rows": 1,
                        "start_x": 0.16,
                        "end_x": 0.20,
                    },
                    {
                        "port_type": "power_c14",
                        "prefix": "PSU",
                        "count": 1,
                        "rows": 1,
                        "start_x": 0.86,
                        "end_x": 0.90,
                    },
                ],
            },
        },
        {
            "library_group": "Patching & Passive",
            "category": "miscellaneous",
            "manufacturer": "Rittal",
            "model_name": "Bandeja Regulable en U (1U por defecto — U Editable)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F8FAFC",
            "layout_spec": {"front": [], "back": []},
        },
        {
            "library_group": "Patching & Passive",
            "category": "rack_tray",
            "manufacturer": "Rittal",
            "model_name": "Bandeja Telescópica Extraíble 1U (U Editable)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F8FAFC",
            "layout_spec": {"front": [], "back": []},
        },

        # --- STORAGE - SAN (Dell EMC, NetApp, IBM, HPE, Pure Storage, Hitachi — 14 modelos reales del mercado) ---
        {
            "library_group": "Storage - SAN",
            "category": "storage_san",
            "manufacturer": "NetApp",
            "model_name": "NetApp AFF A400 (4U All-Flash NVMe SAN HA Pair)",
            "u_height": 4,
            "is_full_depth": True,
            "default_color": "#EFF6FF",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "BMC", "count": 2, "rows": 1, "start_x": 0.14, "end_x": 0.22},
                    {"port_type": "fiber_lc", "prefix": "FC32G-", "count": 8, "rows": 2, "start_x": 0.30, "end_x": 0.62},
                    {"port_type": "sfp_plus", "prefix": "NVMe25G-", "count": 4, "rows": 2, "start_x": 0.68, "end_x": 0.88},
                ],
                "back": [
                    {"port_type": "rj45", "prefix": "e0M", "count": 2, "rows": 1, "start_x": 0.12, "end_x": 0.20},
                    {"port_type": "fiber_lc", "prefix": "FC-", "count": 8, "rows": 2, "start_x": 0.26, "end_x": 0.56},
                    {"port_type": "sfp_plus", "prefix": "HA-", "count": 4, "rows": 1, "start_x": 0.60, "end_x": 0.74},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 4, "rows": 2, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },
        {
            "library_group": "Storage - SAN",
            "category": "storage_san",
            "manufacturer": "NetApp",
            "model_name": "NetApp AFF A250 (2U All-Flash NVMe SAN/FC)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#EFF6FF",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "MGMT", "count": 2, "rows": 1, "start_x": 0.14, "end_x": 0.22},
                    {"port_type": "fiber_lc", "prefix": "FC32G-", "count": 4, "rows": 1, "start_x": 0.32, "end_x": 0.58},
                    {"port_type": "sfp_plus", "prefix": "25GbE-", "count": 4, "rows": 1, "start_x": 0.64, "end_x": 0.88},
                ],
                "back": [
                    {"port_type": "rj45", "prefix": "e0M", "count": 2, "rows": 1, "start_x": 0.12, "end_x": 0.20},
                    {"port_type": "fiber_lc", "prefix": "FC-", "count": 4, "rows": 1, "start_x": 0.28, "end_x": 0.52},
                    {"port_type": "sfp_plus", "prefix": "CNA-", "count": 4, "rows": 1, "start_x": 0.56, "end_x": 0.74},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 2, "rows": 1, "start_x": 0.80, "end_x": 0.90},
                ],
            },
        },
        {
            "library_group": "Storage - SAN",
            "category": "storage_san",
            "manufacturer": "NetApp",
            "model_name": "NetApp ASA A150 (2U Enterprise SAN FC/iSCSI)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#EFF6FF",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "MGMT", "count": 2, "rows": 1, "start_x": 0.14, "end_x": 0.22},
                    {"port_type": "fiber_lc", "prefix": "FC16G-", "count": 4, "rows": 1, "start_x": 0.34, "end_x": 0.62},
                    {"port_type": "sfp_plus", "prefix": "iSCSI-", "count": 4, "rows": 1, "start_x": 0.66, "end_x": 0.88},
                ],
                "back": [
                    {"port_type": "rj45", "prefix": "e0M", "count": 2, "rows": 1, "start_x": 0.14, "end_x": 0.22},
                    {"port_type": "fiber_lc", "prefix": "FC-", "count": 4, "rows": 1, "start_x": 0.30, "end_x": 0.60},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 2, "rows": 1, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },
        {
            "library_group": "Storage - SAN",
            "category": "storage_san",
            "manufacturer": "NetApp",
            "model_name": "NetApp E-Series EF600 (2U NVMe Block SAN Array)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#EFF6FF",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "MGMT", "count": 2, "rows": 1, "start_x": 0.14, "end_x": 0.22},
                    {"port_type": "fiber_lc", "prefix": "FC32G-", "count": 8, "rows": 2, "start_x": 0.34, "end_x": 0.86},
                ],
                "back": [
                    {"port_type": "fiber_lc", "prefix": "FC-", "count": 8, "rows": 2, "start_x": 0.20, "end_x": 0.68},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 2, "rows": 1, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },
        {
            "library_group": "Storage - SAN",
            "category": "storage_san",
            "manufacturer": "Dell EMC",
            "model_name": "Dell PowerStore 1200T (2U All-Flash NVMe SAN)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "MGMT", "count": 2, "rows": 1, "start_x": 0.14, "end_x": 0.22},
                    {"port_type": "fiber_lc", "prefix": "FC32G-", "count": 8, "rows": 2, "start_x": 0.32, "end_x": 0.64},
                    {"port_type": "sfp_plus", "prefix": "25GbE-", "count": 4, "rows": 2, "start_x": 0.70, "end_x": 0.88},
                ],
                "back": [
                    {"port_type": "rj45", "prefix": "SVC", "count": 2, "rows": 1, "start_x": 0.12, "end_x": 0.20},
                    {"port_type": "fiber_lc", "prefix": "FC-", "count": 8, "rows": 2, "start_x": 0.26, "end_x": 0.64},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 2, "rows": 1, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },
        {
            "library_group": "Storage - SAN",
            "category": "storage_san",
            "manufacturer": "Dell EMC",
            "model_name": "Dell PowerStore 5200T (2U Enterprise NVMe FC SAN)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "MGMT", "count": 2, "rows": 1, "start_x": 0.14, "end_x": 0.22},
                    {"port_type": "fiber_lc", "prefix": "FC32G-", "count": 8, "rows": 2, "start_x": 0.30, "end_x": 0.64},
                    {"port_type": "sfp_plus", "prefix": "iSCSI-", "count": 4, "rows": 2, "start_x": 0.70, "end_x": 0.88},
                ],
                "back": [
                    {"port_type": "fiber_lc", "prefix": "FC-", "count": 8, "rows": 2, "start_x": 0.20, "end_x": 0.68},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 2, "rows": 1, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },
        {
            "library_group": "Storage - SAN",
            "category": "storage_san",
            "manufacturer": "Dell EMC",
            "model_name": "Dell PowerVault ME5024 (2U 24-Bay FC/iSCSI SAN)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "MGMT", "count": 2, "rows": 1, "start_x": 0.14, "end_x": 0.22},
                    {"port_type": "fiber_lc", "prefix": "FC16G-", "count": 8, "rows": 2, "start_x": 0.34, "end_x": 0.86},
                ],
                "back": [
                    {"port_type": "fiber_lc", "prefix": "FC-", "count": 8, "rows": 2, "start_x": 0.20, "end_x": 0.68},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 2, "rows": 1, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },
        {
            "library_group": "Storage - SAN",
            "category": "storage_san",
            "manufacturer": "Dell EMC",
            "model_name": "Dell PowerMax 2500 (4U Mission-Critical NVMe SAN)",
            "u_height": 4,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "MGMT", "count": 2, "rows": 1, "start_x": 0.12, "end_x": 0.20},
                    {"port_type": "fiber_lc", "prefix": "FC64G-", "count": 12, "rows": 2, "start_x": 0.28, "end_x": 0.88},
                ],
                "back": [
                    {"port_type": "fiber_lc", "prefix": "FC-", "count": 12, "rows": 2, "start_x": 0.18, "end_x": 0.72},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 4, "rows": 2, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },
        {
            "library_group": "Storage - SAN",
            "category": "storage_san",
            "manufacturer": "IBM",
            "model_name": "IBM FlashSystem 5200 (1U NVMe All-Flash SAN)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F8FAFC",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "MGMT", "count": 2, "rows": 1, "start_x": 0.14, "end_x": 0.22},
                    {"port_type": "fiber_lc", "prefix": "FC32G-", "count": 4, "rows": 1, "start_x": 0.34, "end_x": 0.62},
                    {"port_type": "sfp_plus", "prefix": "25GbE-", "count": 4, "rows": 1, "start_x": 0.66, "end_x": 0.88},
                ],
                "back": [
                    {"port_type": "fiber_lc", "prefix": "FC-", "count": 4, "rows": 1, "start_x": 0.24, "end_x": 0.56},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 2, "rows": 1, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },
        {
            "library_group": "Storage - SAN",
            "category": "storage_san",
            "manufacturer": "IBM",
            "model_name": "IBM FlashSystem 7300 (2U Enterprise NVMe FC SAN)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F8FAFC",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "MGMT", "count": 2, "rows": 1, "start_x": 0.14, "end_x": 0.22},
                    {"port_type": "fiber_lc", "prefix": "FC32G-", "count": 8, "rows": 2, "start_x": 0.32, "end_x": 0.66},
                    {"port_type": "sfp_plus", "prefix": "iSCSI-", "count": 4, "rows": 2, "start_x": 0.72, "end_x": 0.88},
                ],
                "back": [
                    {"port_type": "fiber_lc", "prefix": "FC-", "count": 8, "rows": 2, "start_x": 0.20, "end_x": 0.68},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 2, "rows": 1, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },
        {
            "library_group": "Storage - SAN",
            "category": "storage_san",
            "manufacturer": "IBM",
            "model_name": "IBM FlashSystem 9500 (4U Tier-0 Mission-Critical SAN)",
            "u_height": 4,
            "is_full_depth": True,
            "default_color": "#F8FAFC",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "MGMT", "count": 2, "rows": 1, "start_x": 0.12, "end_x": 0.20},
                    {"port_type": "fiber_lc", "prefix": "FC64G-", "count": 12, "rows": 2, "start_x": 0.28, "end_x": 0.88},
                ],
                "back": [
                    {"port_type": "fiber_lc", "prefix": "FC-", "count": 12, "rows": 2, "start_x": 0.18, "end_x": 0.72},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 4, "rows": 2, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },
        {
            "library_group": "Storage - SAN",
            "category": "storage_san",
            "manufacturer": "HPE",
            "model_name": "HPE Alletra 6050 (4U All-Flash NVMe SAN)",
            "u_height": 4,
            "is_full_depth": True,
            "default_color": "#ECFDF5",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "MGMT", "count": 2, "rows": 1, "start_x": 0.14, "end_x": 0.22},
                    {"port_type": "fiber_lc", "prefix": "FC32G-", "count": 8, "rows": 2, "start_x": 0.32, "end_x": 0.86},
                ],
                "back": [
                    {"port_type": "fiber_lc", "prefix": "FC-", "count": 8, "rows": 2, "start_x": 0.20, "end_x": 0.68},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 4, "rows": 2, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },
        {
            "library_group": "Storage - SAN",
            "category": "storage_san",
            "manufacturer": "Pure Storage",
            "model_name": "Pure Storage FlashArray//X70 R4 (3U 100% NVMe SAN)",
            "u_height": 3,
            "is_full_depth": True,
            "default_color": "#FFF7ED",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "MGMT", "count": 2, "rows": 1, "start_x": 0.14, "end_x": 0.22},
                    {"port_type": "fiber_lc", "prefix": "FC32G-", "count": 8, "rows": 2, "start_x": 0.32, "end_x": 0.66},
                    {"port_type": "sfp_plus", "prefix": "NVMe-", "count": 4, "rows": 2, "start_x": 0.72, "end_x": 0.88},
                ],
                "back": [
                    {"port_type": "fiber_lc", "prefix": "FC-", "count": 8, "rows": 2, "start_x": 0.20, "end_x": 0.68},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 2, "rows": 1, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },
        {
            "library_group": "Storage - SAN",
            "category": "storage_san",
            "manufacturer": "Hitachi Vantara",
            "model_name": "Hitachi VSP E590 (2U All-Flash NVMe FC SAN)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#FEF2F2",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "SVP", "count": 2, "rows": 1, "start_x": 0.14, "end_x": 0.22},
                    {"port_type": "fiber_lc", "prefix": "FC32G-", "count": 8, "rows": 2, "start_x": 0.34, "end_x": 0.86},
                ],
                "back": [
                    {"port_type": "fiber_lc", "prefix": "FC-", "count": 8, "rows": 2, "start_x": 0.20, "end_x": 0.68},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 2, "rows": 1, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },

        # --- STORAGE - NAS (NetApp FAS/AFF, Dell PowerScale/Isilon/Unity, IBM Scale, Synology, QNAP — 12 modelos) ---
        {
            "library_group": "Storage - NAS",
            "category": "storage_nas",
            "manufacturer": "NetApp",
            "model_name": "NetApp FAS2750 (2U 24-Bay Hybrid Flash NAS)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#EFF6FF",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "MGMT", "count": 2, "rows": 1, "start_x": 0.14, "end_x": 0.22},
                    {"port_type": "rj45", "prefix": "10G-", "count": 4, "rows": 1, "start_x": 0.32, "end_x": 0.56},
                    {"port_type": "sfp_plus", "prefix": "SFP-", "count": 4, "rows": 1, "start_x": 0.62, "end_x": 0.88},
                ],
                "back": [
                    {"port_type": "rj45", "prefix": "e0M", "count": 2, "rows": 1, "start_x": 0.14, "end_x": 0.22},
                    {"port_type": "sfp_plus", "prefix": "NAS-", "count": 4, "rows": 1, "start_x": 0.30, "end_x": 0.64},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 2, "rows": 1, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },
        {
            "library_group": "Storage - NAS",
            "category": "storage_nas",
            "manufacturer": "NetApp",
            "model_name": "NetApp FAS8300 (4U Enterprise Scale-Out NAS)",
            "u_height": 4,
            "is_full_depth": True,
            "default_color": "#EFF6FF",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "MGMT", "count": 2, "rows": 1, "start_x": 0.14, "end_x": 0.22},
                    {"port_type": "sfp_plus", "prefix": "25GbE-", "count": 8, "rows": 2, "start_x": 0.32, "end_x": 0.86},
                ],
                "back": [
                    {"port_type": "sfp_plus", "prefix": "NAS-", "count": 8, "rows": 2, "start_x": 0.20, "end_x": 0.68},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 4, "rows": 2, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },
        {
            "library_group": "Storage - NAS",
            "category": "storage_nas",
            "manufacturer": "NetApp",
            "model_name": "NetApp AFF C250 (2U Capacity QLC Flash NAS)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#EFF6FF",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "MGMT", "count": 2, "rows": 1, "start_x": 0.14, "end_x": 0.22},
                    {"port_type": "sfp_plus", "prefix": "25GbE-", "count": 4, "rows": 1, "start_x": 0.36, "end_x": 0.86},
                ],
                "back": [
                    {"port_type": "sfp_plus", "prefix": "NAS-", "count": 4, "rows": 1, "start_x": 0.24, "end_x": 0.64},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 2, "rows": 1, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },
        {
            "library_group": "Storage - NAS",
            "category": "storage_nas",
            "manufacturer": "Dell EMC",
            "model_name": "Dell PowerScale (Isilon) F200 (1U All-Flash NAS)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "iDRAC", "count": 1, "rows": 1, "start_x": 0.14, "end_x": 0.18},
                    {"port_type": "sfp_plus", "prefix": "25GbE-", "count": 4, "rows": 1, "start_x": 0.34, "end_x": 0.86},
                ],
                "back": [
                    {"port_type": "sfp_plus", "prefix": "NAS-", "count": 4, "rows": 1, "start_x": 0.24, "end_x": 0.64},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 2, "rows": 1, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },
        {
            "library_group": "Storage - NAS",
            "category": "storage_nas",
            "manufacturer": "Dell EMC",
            "model_name": "Dell PowerScale (Isilon) F600 (2U NVMe Scale-Out NAS)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "MGMT", "count": 2, "rows": 1, "start_x": 0.14, "end_x": 0.22},
                    {"port_type": "sfp_plus", "prefix": "100GbE-", "count": 4, "rows": 1, "start_x": 0.34, "end_x": 0.86},
                ],
                "back": [
                    {"port_type": "sfp_plus", "prefix": "NAS-", "count": 4, "rows": 1, "start_x": 0.24, "end_x": 0.64},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 2, "rows": 1, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },
        {
            "library_group": "Storage - NAS",
            "category": "storage_nas",
            "manufacturer": "Dell EMC",
            "model_name": "Dell PowerScale H700 (4U High-Capacity Hybrid NAS)",
            "u_height": 4,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "MGMT", "count": 2, "rows": 1, "start_x": 0.14, "end_x": 0.22},
                    {"port_type": "sfp_plus", "prefix": "40GbE-", "count": 8, "rows": 2, "start_x": 0.34, "end_x": 0.86},
                ],
                "back": [
                    {"port_type": "sfp_plus", "prefix": "NAS-", "count": 8, "rows": 2, "start_x": 0.20, "end_x": 0.68},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 4, "rows": 2, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },
        {
            "library_group": "Storage - NAS",
            "category": "storage_nas",
            "manufacturer": "Dell EMC",
            "model_name": "Dell Unity XT 480F (2U Unified All-Flash NAS/SAN)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "MGMT", "count": 2, "rows": 1, "start_x": 0.14, "end_x": 0.22},
                    {"port_type": "rj45", "prefix": "10GbE-", "count": 4, "rows": 1, "start_x": 0.32, "end_x": 0.56},
                    {"port_type": "sfp_plus", "prefix": "25GbE-", "count": 4, "rows": 1, "start_x": 0.62, "end_x": 0.88},
                ],
                "back": [
                    {"port_type": "sfp_plus", "prefix": "CNA-", "count": 4, "rows": 1, "start_x": 0.24, "end_x": 0.64},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 2, "rows": 1, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },
        {
            "library_group": "Storage - NAS",
            "category": "storage_nas",
            "manufacturer": "IBM",
            "model_name": "IBM Storage Scale System 3500 (2U GPFS NVMe NAS)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F8FAFC",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "MGMT", "count": 2, "rows": 1, "start_x": 0.14, "end_x": 0.22},
                    {"port_type": "sfp_plus", "prefix": "100GbE-", "count": 4, "rows": 1, "start_x": 0.36, "end_x": 0.86},
                ],
                "back": [
                    {"port_type": "sfp_plus", "prefix": "GPFS-", "count": 4, "rows": 1, "start_x": 0.24, "end_x": 0.64},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 2, "rows": 1, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },
        {
            "library_group": "Storage - NAS",
            "category": "storage_nas",
            "manufacturer": "Synology",
            "model_name": "Synology RackStation RS3621xs+ (2U 12-Bay Xeon NAS)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F8FAFC",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "1GbE-", "count": 4, "rows": 1, "start_x": 0.16, "end_x": 0.42},
                    {"port_type": "rj45", "prefix": "10GbE-", "count": 2, "rows": 1, "start_x": 0.48, "end_x": 0.62},
                    {"port_type": "sfp_plus", "prefix": "SFP-", "count": 2, "rows": 1, "start_x": 0.68, "end_x": 0.84},
                ],
                "back": [
                    {"port_type": "rj45", "prefix": "LAN-", "count": 4, "rows": 1, "start_x": 0.20, "end_x": 0.56},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 2, "rows": 1, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },
        {
            "library_group": "Storage - NAS",
            "category": "storage_nas",
            "manufacturer": "Synology",
            "model_name": "Synology FlashStation FS3410 (2U 24-Bay All-Flash NAS)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F8FAFC",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "MGMT", "count": 1, "rows": 1, "start_x": 0.14, "end_x": 0.18},
                    {"port_type": "rj45", "prefix": "10GbE-", "count": 2, "rows": 1, "start_x": 0.28, "end_x": 0.44},
                    {"port_type": "sfp_plus", "prefix": "25GbE-", "count": 4, "rows": 1, "start_x": 0.52, "end_x": 0.86},
                ],
                "back": [
                    {"port_type": "sfp_plus", "prefix": "SFP-", "count": 4, "rows": 1, "start_x": 0.24, "end_x": 0.64},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 2, "rows": 1, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },
        {
            "library_group": "Storage - NAS",
            "category": "storage_nas",
            "manufacturer": "QNAP",
            "model_name": "QNAP TS-h1886XU-RP R2 (2U ZFS QuTS hero 10GbE NAS)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F8FAFC",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "2.5G-", "count": 4, "rows": 1, "start_x": 0.16, "end_x": 0.46},
                    {"port_type": "sfp_plus", "prefix": "10G-SFP-", "count": 2, "rows": 1, "start_x": 0.56, "end_x": 0.78},
                ],
                "back": [
                    {"port_type": "rj45", "prefix": "LAN-", "count": 4, "rows": 1, "start_x": 0.20, "end_x": 0.56},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 2, "rows": 1, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },
        {
            "library_group": "Storage - NAS",
            "category": "storage_nas",
            "manufacturer": "QNAP",
            "model_name": "QNAP TDS-h2489FU (2U Dual-Xeon 24x NVMe All-Flash NAS)",
            "u_height": 2,
            "is_full_depth": True,
            "default_color": "#F8FAFC",
            "layout_spec": {
                "front": [
                    {"port_type": "rj45", "prefix": "2.5G-", "count": 2, "rows": 1, "start_x": 0.14, "end_x": 0.24},
                    {"port_type": "sfp_plus", "prefix": "25GbE-", "count": 4, "rows": 1, "start_x": 0.36, "end_x": 0.86},
                ],
                "back": [
                    {"port_type": "sfp_plus", "prefix": "25G-", "count": 4, "rows": 1, "start_x": 0.24, "end_x": 0.64},
                    {"port_type": "power_c14", "prefix": "PSU", "count": 2, "rows": 1, "start_x": 0.78, "end_x": 0.90},
                ],
            },
        },

        # --- BANDEJA - EQUIPOS MINI (Equipos pequeños / no enracables para colocar encima de Bandejas: Routers, Mini-Switches, ONTs, Mini-PCs / NUC — 12 modelos) ---
        {
            "library_group": "Bandeja - Equipos Mini",
            "category": "rack_tray_device",
            "manufacturer": "Nokia / Huawei",
            "model_name": "ONT / Conversor Fibra ISP GPON/XGS-PON (Sobre Bandeja)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F8FAFC",
            "layout_spec": {
                "is_tray_item": True,
                "tray_item_kind": "ont",
                "front": [
                    {"port_type": "fiber_lc", "prefix": "PON", "count": 1, "rows": 1, "start_x": 0.22, "end_x": 0.28},
                    {"port_type": "rj45", "prefix": "LAN", "count": 4, "rows": 1, "start_x": 0.38, "end_x": 0.76},
                ],
                "back": [
                    {"port_type": "power_c14", "prefix": "DC", "count": 1, "rows": 1, "start_x": 0.45, "end_x": 0.55},
                ],
            },
        },
        {
            "library_group": "Bandeja - Equipos Mini",
            "category": "rack_tray_device",
            "manufacturer": "Fortinet",
            "model_name": "FortiGate 40F / 60F Desktop Firewall (Sobre Bandeja)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#FEF2F2",
            "layout_spec": {
                "is_tray_item": True,
                "tray_item_kind": "firewall",
                "front": [
                    {"port_type": "rj45", "prefix": "WAN", "count": 1, "rows": 1, "start_x": 0.20, "end_x": 0.26},
                    {"port_type": "rj45", "prefix": "LAN", "count": 4, "rows": 1, "start_x": 0.34, "end_x": 0.76},
                ],
                "back": [
                    {"port_type": "power_c14", "prefix": "DC", "count": 1, "rows": 1, "start_x": 0.45, "end_x": 0.55},
                ],
            },
        },
        {
            "library_group": "Bandeja - Equipos Mini",
            "category": "rack_tray_device",
            "manufacturer": "MikroTik",
            "model_name": "MikroTik hEX S / RB5009 Mini Router PoE+SFP (Sobre Bandeja)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#EFF6FF",
            "layout_spec": {
                "is_tray_item": True,
                "tray_item_kind": "router",
                "front": [
                    {"port_type": "sfp_plus", "prefix": "SFP", "count": 1, "rows": 1, "start_x": 0.18, "end_x": 0.24},
                    {"port_type": "rj45", "prefix": "ETH", "count": 5, "rows": 1, "start_x": 0.32, "end_x": 0.78},
                ],
                "back": [
                    {"port_type": "power_c14", "prefix": "DC", "count": 1, "rows": 1, "start_x": 0.45, "end_x": 0.55},
                ],
            },
        },
        {
            "library_group": "Bandeja - Equipos Mini",
            "category": "rack_tray_device",
            "manufacturer": "Cisco",
            "model_name": "Cisco Catalyst / ISR 1100-4P Mini Router (Sobre Bandeja)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F0F9FF",
            "layout_spec": {
                "is_tray_item": True,
                "tray_item_kind": "router",
                "front": [
                    {"port_type": "sfp_plus", "prefix": "WAN-SFP", "count": 1, "rows": 1, "start_x": 0.20, "end_x": 0.26},
                    {"port_type": "rj45", "prefix": "GE", "count": 4, "rows": 1, "start_x": 0.36, "end_x": 0.76},
                ],
                "back": [
                    {"port_type": "power_c14", "prefix": "PSU", "count": 1, "rows": 1, "start_x": 0.45, "end_x": 0.55},
                ],
            },
        },
        {
            "library_group": "Bandeja - Equipos Mini",
            "category": "rack_tray_device",
            "manufacturer": "Teltonika",
            "model_name": "Teltonika RUTX50 Router 5G/4G LTE Dual-SIM (Sobre Bandeja)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F8FAFC",
            "layout_spec": {
                "is_tray_item": True,
                "tray_item_kind": "router",
                "front": [
                    {"port_type": "rj45", "prefix": "WAN", "count": 1, "rows": 1, "start_x": 0.22, "end_x": 0.28},
                    {"port_type": "rj45", "prefix": "LAN", "count": 4, "rows": 1, "start_x": 0.36, "end_x": 0.76},
                ],
                "back": [
                    {"port_type": "power_c14", "prefix": "DC", "count": 1, "rows": 1, "start_x": 0.45, "end_x": 0.55},
                ],
            },
        },
        {
            "library_group": "Bandeja - Equipos Mini",
            "category": "rack_tray_device",
            "manufacturer": "Netgear / TP-Link",
            "model_name": "Mini Switch 5 Bocas GbE Desktop (Sobre Bandeja)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F8FAFC",
            "layout_spec": {
                "is_tray_item": True,
                "tray_item_kind": "switch",
                "front": [
                    {"port_type": "rj45", "prefix": "P", "count": 5, "rows": 1, "start_x": 0.22, "end_x": 0.78},
                ],
                "back": [
                    {"port_type": "power_c14", "prefix": "DC", "count": 1, "rows": 1, "start_x": 0.45, "end_x": 0.55},
                ],
            },
        },
        {
            "library_group": "Bandeja - Equipos Mini",
            "category": "rack_tray_device",
            "manufacturer": "Ubiquiti / Cisco",
            "model_name": "Mini Switch 8 Bocas PoE + 2 SFP Compacto (Sobre Bandeja)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F8FAFC",
            "layout_spec": {
                "is_tray_item": True,
                "tray_item_kind": "switch",
                "front": [
                    {"port_type": "rj45", "prefix": "P", "count": 8, "rows": 1, "start_x": 0.16, "end_x": 0.66},
                    {"port_type": "sfp_plus", "prefix": "SFP", "count": 2, "rows": 1, "start_x": 0.72, "end_x": 0.84},
                ],
                "back": [
                    {"port_type": "power_c14", "prefix": "PSU", "count": 1, "rows": 1, "start_x": 0.45, "end_x": 0.55},
                ],
            },
        },
        {
            "library_group": "Bandeja - Equipos Mini",
            "category": "rack_tray_device",
            "manufacturer": "Allied Telesis / TP-Link",
            "model_name": "Conversor de Medios Fibra Óptica ↔ RJ45 (Media Converter)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#FEFCE8",
            "layout_spec": {
                "is_tray_item": True,
                "tray_item_kind": "converter",
                "front": [
                    {"port_type": "fiber_lc", "prefix": "FO", "count": 1, "rows": 1, "start_x": 0.34, "end_x": 0.42},
                    {"port_type": "rj45", "prefix": "ETH", "count": 1, "rows": 1, "start_x": 0.56, "end_x": 0.64},
                ],
                "back": [
                    {"port_type": "power_c14", "prefix": "DC", "count": 1, "rows": 1, "start_x": 0.45, "end_x": 0.55},
                ],
            },
        },
        {
            "library_group": "Bandeja - Equipos Mini",
            "category": "rack_tray_device",
            "manufacturer": "Intel / ASUS",
            "model_name": "Intel NUC Pro Mini PC (Ordenador Compacto Dual-LAN)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": {
                "is_tray_item": True,
                "tray_item_kind": "minipc",
                "front": [
                    {"port_type": "rj45", "prefix": "ETH", "count": 2, "rows": 1, "start_x": 0.38, "end_x": 0.62},
                ],
                "back": [
                    {"port_type": "rj45", "prefix": "LAN", "count": 2, "rows": 1, "start_x": 0.32, "end_x": 0.52},
                    {"port_type": "power_c14", "prefix": "DC", "count": 1, "rows": 1, "start_x": 0.64, "end_x": 0.72},
                ],
            },
        },
        {
            "library_group": "Bandeja - Equipos Mini",
            "category": "rack_tray_device",
            "manufacturer": "Lenovo / Dell / HP",
            "model_name": "ThinkCentre Tiny / OptiPlex Micro / EliteDesk Mini PC",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": {
                "is_tray_item": True,
                "tray_item_kind": "minipc",
                "front": [
                    {"port_type": "rj45", "prefix": "ETH", "count": 2, "rows": 1, "start_x": 0.38, "end_x": 0.62},
                ],
                "back": [
                    {"port_type": "rj45", "prefix": "LAN", "count": 2, "rows": 1, "start_x": 0.32, "end_x": 0.52},
                    {"port_type": "power_c14", "prefix": "DC", "count": 1, "rows": 1, "start_x": 0.64, "end_x": 0.72},
                ],
            },
        },
        {
            "library_group": "Bandeja - Equipos Mini",
            "category": "rack_tray_device",
            "manufacturer": "Apple",
            "model_name": "Mac mini Pro 10GbE (Mini Ordenador / Nodo Servidor)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F8FAFC",
            "layout_spec": {
                "is_tray_item": True,
                "tray_item_kind": "minipc",
                "front": [
                    {"port_type": "rj45", "prefix": "10GbE", "count": 1, "rows": 1, "start_x": 0.46, "end_x": 0.54},
                ],
                "back": [
                    {"port_type": "rj45", "prefix": "10G-R", "count": 1, "rows": 1, "start_x": 0.38, "end_x": 0.46},
                    {"port_type": "power_c14", "prefix": "AC", "count": 1, "rows": 1, "start_x": 0.58, "end_x": 0.66},
                ],
            },
        },
        {
            "library_group": "Bandeja - Equipos Mini",
            "category": "rack_tray_device",
            "manufacturer": "Raspberry Pi / IoT",
            "model_name": "Raspberry Pi 5 / Sonda Hardware Monitorización (PoE/ETH)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#ECFDF5",
            "layout_spec": {
                "is_tray_item": True,
                "tray_item_kind": "minipc",
                "front": [
                    {"port_type": "rj45", "prefix": "ETH", "count": 1, "rows": 1, "start_x": 0.46, "end_x": 0.54},
                ],
                "back": [
                    {"port_type": "power_c14", "prefix": "USB-C", "count": 1, "rows": 1, "start_x": 0.46, "end_x": 0.54},
                ],
            },
        },
    ]
    for et in extra_templates:
        exists = (
            db.query(DeviceTemplate)
            .filter(DeviceTemplate.model_name == et["model_name"])
            .first()
        )
        if not exists:
            db.add(DeviceTemplate(**et))
        elif et["category"] in ("pdu", "miscellaneous", "rack_tray_device"):
            exists.library_group = et["library_group"]
            exists.layout_spec = et["layout_spec"]
    db.flush()

    # Reasignar también la ONT preexistente al grupo "Bandeja - Equipos Mini"
    for tpl_ont in db.query(DeviceTemplate).filter(DeviceTemplate.category == "rack_tray_device").all():
        tpl_ont.library_group = "Bandeja - Equipos Mini"

    get_or_create_external_feed_template(db)

    # Asegurar que todas las plantillas y dispositivos existentes autorrellenen Front y Back sin solaparse
    for tpl in db.query(DeviceTemplate).all():
        if tpl.category != "external_outlet":
            tpl.is_full_depth = True
            spec = dict(tpl.layout_spec or {})
            if tpl.category == "patchbox" and not spec.get("back"):
                spec["back"] = [
                    {
                        "port_type": "rj45",
                        "prefix": "R-",
                        "count": 24,
                        "rows": 2,
                        "start_x": 0.08,
                        "end_x": 0.92,
                    }
                ]
                tpl.layout_spec = spec
            elif tpl.category == "switch":
                front_groups = list(spec.get("front") or [])
                changed_spec = False
                for g in front_groups:
                    pt = str(g.get("port_type", "")).lower()
                    cnt = int(g.get("count", 0))
                    if ("sfp" in pt or "fiber" in pt) and cnt >= 4 and int(g.get("rows", 1)) == 1:
                        g["rows"] = 2
                        changed_spec = True
                if changed_spec:
                    spec["front"] = front_groups
                    tpl.layout_spec = spec

    # Normalizar también puertos SFP frontales en Switches ya montados que se crearon con row_index=0 para >=4 SFP
    for sw_dev in db.query(RackDevice).all():
        if sw_dev.template and sw_dev.template.category == "switch":
            front_sfps = [
                p
                for p in sw_dev.ports
                if p.face == "front"
                and (
                    p.port_type == "sfp_plus"
                    or "fiber" in (p.port_type or "")
                    or (p.port_number or "").startswith("SFP")
                )
            ]
            if len(front_sfps) >= 4 and all(p.row_index == 0 for p in front_sfps):
                front_sfps.sort(key=lambda x: x.id)
                cols = max(1, (len(front_sfps) + 1) // 2)
                for idx, p in enumerate(front_sfps):
                    p.row_index = idx % 2
                    p.col_index = idx // 2
                    p.rel_y = 0.32 if p.row_index == 0 else 0.68
                    p.rel_x = round(0.85 + (0.09 * (p.col_index / max(1, cols - 1))), 4)

    db.flush()

    # Si PDU-B estaba en U36 (colisionando con Patch Panel A en U36), moverlo a U25 libre
    pdu_b = db.query(RackDevice).filter(RackDevice.code == "PDU-B").first()
    if pdu_b and pdu_b.start_u == 36:
        pdu_b.start_u = 25

    # Asegurar que toda regleta PDU / Schuko montada tenga su conector MACHO de entrada (power_plug_male) en Front
    for pdu_dev in db.query(RackDevice).all():
        if pdu_dev.template and pdu_dev.template.category == "pdu":
            has_front_male = any(
                p.face == "front"
                and (
                    p.port_type == "power_plug_male"
                    or p.port_number.startswith("IN")
                    or p.port_number.startswith("MACHO")
                )
                for p in pdu_dev.ports
            )
            if not has_front_male:
                back_in = next(
                    (
                        p
                        for p in pdu_dev.ports
                        if p.port_number.startswith("IN")
                        or p.port_number.startswith("MACHO")
                    ),
                    None,
                )
                if back_in:
                    back_in.face = "front"
                    back_in.port_type = "power_plug_male"
                    back_in.rel_x = 0.095
                else:
                    db.add(
                        Port(
                            rack_device_id=pdu_dev.id,
                            port_number="MACHO-IN1",
                            label=f"{pdu_dev.code}:MACHO-IN1",
                            face="front",
                            port_type="power_plug_male",
                            row_index=0,
                            col_index=0,
                            rel_x=0.095,
                            rel_y=0.5,
                        )
                    )
            else:
                for p in pdu_dev.ports:
                    if p.port_number.startswith("IN") or p.port_number.startswith("MACHO"):
                        p.port_type = "power_plug_male"

    # Asegurar que cualquier equipo montado en Front tenga también sus puertos traseros en Back
    for dev in db.query(RackDevice).all():
        if dev.mounted_face == "external":
            continue
        has_back = any(p.face == "back" for p in dev.ports)
        if not has_back and dev.template:
            spec = dict(dev.template.layout_spec or {})
            back_groups = list(spec.get("back", []))
            for group in back_groups:
                port_type = group.get("port_type", "rj45")
                prefix = group.get("prefix", "R-")
                count = int(group.get("count", 0))
                rows = int(group.get("rows", 1))
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
                    rel_y = 0.32 if (rows > 1 and r == 0) else (0.68 if rows > 1 else 0.5)
                    db.add(
                        Port(
                            rack_device_id=dev.id,
                            port_number=p_num,
                            label=f"{dev.code}:{p_num}",
                            face="back",
                            port_type=port_type,
                            row_index=r,
                            col_index=c,
                            rel_x=round(rel_x, 4),
                            rel_y=round(rel_y, 4),
                        )
                    )

    # Asegurar mapeos de Grupos de AD -> Roles en los servidores AD existentes
    for ad_srv in db.query(ADServer).all():
        if not ad_srv.group_role_mapping:
            base = ad_srv.base_dn or "DC=corp,DC=rackdoc,DC=local"
            ad_srv.group_role_mapping = [
                {
                    "group_name": "Domain Admins / Arquitectura TI",
                    "group_dn": f"CN=Domain Admins,OU=Groups,{base}",
                    "role": "admin",
                },
                {
                    "group_name": "NetOps & SysAdmins (Ingeniería CPD)",
                    "group_dn": f"CN=NetOps-Engineers,OU=Groups,{base}",
                    "role": "editor",
                },
                {
                    "group_name": "NOC 24x7 & Guardia Operaciones (SSH/Web)",
                    "group_dn": f"CN=NOC-Operators,OU=Groups,{base}",
                    "role": "operator",
                },
                {
                    "group_name": "Auditores & Seguridad Compliance",
                    "group_dn": f"CN=Auditores-TI,OU=Groups,{base}",
                    "role": "viewer",
                },
            ]

    # Asegurar que todos los equipos (Rack y Planta) tengan Heartbeat desactivado por defecto
    # (estado 'unmonitored' = Gris) hasta que el usuario lo active explícitamente, y dispongan
    # de su estructura heartbeat_config y connect_config lista para usar.
    for dev in db.query(RackDevice).all():
        if dev.mounted_face == "external":
            continue
        cf = dict(dev.custom_fields or {})
        cat = (dev.template.category if dev.template else "").lower()
        ip_val = (dev.ip_address or "").strip()
        fqdn_val = (dev.fqdn or dev.hostname or "").strip()

        if "heartbeat_config" not in cf:
            if cat in ("switch", "router"):
                enabled_list = ["icmp", "ssh"]
            elif cat in ("firewall", "gateway"):
                enabled_list = ["icmp", "http"]
            elif cat in ("server", "storage_nas", "storage_san"):
                enabled_list = ["icmp", "ssh"]
            elif cat in ("pdu", "ups"):
                enabled_list = ["icmp", "snmp"]
            else:
                enabled_list = ["icmp"]

            cf["heartbeat_config"] = {
                "enabled_checks": enabled_list,
                "checks": {
                    "icmp": {"target_type": "ip"},
                    "ssh": {
                        "target_type": "ip",
                        "port": 22,
                        "username": "admin",
                    },
                    "http": {
                        "target_type": "ip",
                        "scheme": "https",
                        "port": 443,
                        "url": f"https://{ip_val or fqdn_val}:443/" if (ip_val or fqdn_val) else "",
                        "path": "/",
                        "expected_status": 200,
                    },
                    "tcp": {
                        "target_type": "ip",
                        "port": dev.monitor_port or 8080,
                    },
                    "udp": {
                        "target_type": "ip",
                        "port": 161,
                    },
                    "snmp": {
                        "target_type": "ip",
                        "port": 161,
                        "version": "2c",
                        "community": "public",
                        "oid": "1.3.6.1.2.1.1.1.0",
                    },
                },
            }

        if "connect_config" not in cf:
            cf["connect_config"] = {
                "enabled": False,
                "protocols": ["ssh", "https"],
                "ssh": {
                    "host": ip_val or fqdn_val,
                    "port": 22,
                    "username": "admin",
                },
                "http": {
                    "url": f"http://{ip_val or fqdn_val}:80/" if (ip_val or fqdn_val) else "",
                },
                "https": {
                    "url": f"https://{ip_val or fqdn_val}:443/" if (ip_val or fqdn_val) else "",
                },
            }

        if not cf.get("heartbeat_v4_default_off"):
            dev.monitoring_enabled = False
            dev.status = "unmonitored"
            dev.last_ping_ms = None
            cf["heartbeat_v4_default_off"] = True

        if not dev.monitoring_enabled:
            dev.status = "unmonitored"
            dev.last_ping_ms = None

        for str_attr in (
            "ip_address",
            "hostname",
            "fqdn",
            "subnet_mask",
            "gateway",
            "mac_address",
            "serial_number",
            "notes",
        ):
            if getattr(dev, str_attr, None) is None:
                setattr(dev, str_attr, "255.255.255.0" if str_attr == "subnet_mask" else "")

        dev.custom_fields = cf

    for fd in db.query(FloorDevice).all():
        for str_attr in ("ip_address", "fqdn", "mac_address", "notes"):
            if getattr(fd, str_attr, None) is None:
                setattr(fd, str_attr, "")
        cf = dict(fd.custom_fields or {})
        ip_val = (fd.ip_address or "").strip()
        fqdn_val = (getattr(fd, "fqdn", "") or "").strip()
        if "heartbeat_config" not in cf:
            cf["heartbeat_config"] = {
                "enabled_checks": ["icmp"],
                "checks": {
                    "icmp": {"target_type": "ip"},
                    "ssh": {"target_type": "ip", "port": 22, "username": "admin"},
                    "http": {
                        "target_type": "ip",
                        "scheme": "http",
                        "port": 80,
                        "url": f"http://{ip_val or fqdn_val}:80/" if (ip_val or fqdn_val) else "",
                        "path": "/",
                        "expected_status": 200,
                    },
                    "tcp": {"target_type": "ip", "port": 80},
                    "udp": {"target_type": "ip", "port": 161},
                    "snmp": {
                        "target_type": "ip",
                        "port": 161,
                        "version": "2c",
                        "community": "public",
                        "oid": "1.3.6.1.2.1.1.1.0",
                    },
                },
            }
        if "connect_config" not in cf:
            cf["connect_config"] = {
                "enabled": False,
                "protocols": ["https"],
                "ssh": {"host": ip_val or fqdn_val, "port": 22, "username": "admin"},
                "http": {"url": f"http://{ip_val or fqdn_val}:80/" if (ip_val or fqdn_val) else ""},
                "https": {"url": f"https://{ip_val or fqdn_val}:443/" if (ip_val or fqdn_val) else ""},
            }
        if not cf.get("heartbeat_v4_default_off"):
            fd.monitoring_enabled = False
            fd.status = "unmonitored"
            fd.last_ping_ms = None
            cf["heartbeat_v4_default_off"] = True
        if not fd.monitoring_enabled:
            fd.status = "unmonitored"
            fd.last_ping_ms = None
        fd.custom_fields = cf

    # Asegurar que cada Rack tenga sus Tomas Exteriores Schuko (mínimo 1, por defecto 2: Línea A Roja y Línea B Azul)
    racks = db.query(Rack).all()
    for rk in racks:
        ensure_rack_external_outlets(db, rk)

    db.commit()
