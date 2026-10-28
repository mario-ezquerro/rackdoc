from __future__ import annotations
import os
from datetime import datetime
from sqlalchemy.orm import Session
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
    ]

    tpl_map: dict[str, DeviceTemplate] = {}
    for td in templates_data:
        t = DeviceTemplate(**td)
        db.add(t)
        db.flush()
        tpl_map[f"{td['category']}:{td['model_name']}"] = t
        tpl_map[td["category"]] = t

    # 2. Sedes (Locations), Plantas (Floors), Salas (Rooms) y Pasillos (Aisles)
    loc_hq = Location(
        code="HQ",
        name="Headquarter",
        latitude=48.2082,
        longitude=16.3738,
        address=" Donau-City-Straße 11, Vienna / CPD Central",
        description="Sede principal con 3 plantas técnicas y pasillos frío/caliente.",
    )
    loc_new = Location(
        code="HQ_NEW",
        name="The New Headquarter",
        latitude=48.1950,
        longitude=16.3400,
        address="Mariahilfer Straße 88, Campus Sur",
        description="Centro de respaldo secundario.",
    )
    loc_prod = Location(
        code="PRD",
        name="Production Datacenter",
        latitude=48.2250,
        longitude=16.4100,
        address="Industriestraße 42, Zona Franca",
        description="Planta de producción y comunicaciones industriales.",
    )
    db.add_all([loc_hq, loc_new, loc_prod])
    db.flush()

    # Plantas para HQ (3 plantas)
    f1 = Floor(location_id=loc_hq.id, name="Floor 1 - Entrada & Operación", level_number=1)
    f2 = Floor(location_id=loc_hq.id, name="Floor 2 - Core CPD", level_number=2)
    f3 = Floor(location_id=loc_hq.id, name="Floor 3 - Laboratorio & DR", level_number=3)
    f_new = Floor(location_id=loc_new.id, name="Floor 1 - Sala Principal", level_number=1)
    f_prd = Floor(location_id=loc_prod.id, name="Floor 0 - Nave CPD", level_number=0)
    db.add_all([f1, f2, f3, f_new, f_prd])
    db.flush()

    # Salas
    room_28 = Room(floor_id=f2.id, name="28 - Main Server Room", width_m=16.0, depth_m=10.0)
    room_29 = Room(floor_id=f2.id, name="29 - Telecom & Meet-Me Room", width_m=8.0, depth_m=6.0)
    room_10 = Room(floor_id=f1.id, name="10 - Access Wiring Room", width_m=6.0, depth_m=5.0)
    room_new = Room(floor_id=f_new.id, name="01 - Core Room", width_m=10.0, depth_m=8.0)
    room_prd1 = Room(floor_id=f_prd.id, name="P1 - Sala Control", width_m=12.0, depth_m=8.0)
    room_prd2 = Room(floor_id=f_prd.id, name="P2 - Sala Racks OT", width_m=12.0, depth_m=8.0)
    db.add_all([room_28, room_29, room_10, room_new, room_prd1, room_prd2])
    db.flush()

    # Pasillos en Sala 28
    aisle_a = Aisle(room_id=room_28.id, code="PASILLO-A", name="Pasillo Frío A (Core)", aisle_type="cold")
    aisle_b = Aisle(room_id=room_28.id, code="PASILLO-B", name="Pasillo Caliente B (Servidores)", aisle_type="hot")
    aisle_new = Aisle(room_id=room_new.id, code="FILA-1", name="Fila 1 Principal", aisle_type="cold")
    aisle_prd = Aisle(room_id=room_prd1.id, code="FILA-OT", name="Pasillo OT 1", aisle_type="standard")
    db.add_all([aisle_a, aisle_b, aisle_new, aisle_prd])
    db.flush()

    # Racks
    rack_1 = Rack(
        room_id=room_28.id,
        aisle_id=aisle_a.id,
        code="RK001_M",
        name="M_Rack001",
        total_units=42,
        manufacturer="Rittal",
        model_name="VX IT 42U 800x1000",
        serial_number="RIT-2026-88412",
        responsible_person="Alex Geng",
        purchase_date="2026-04-01",
        operation_start="2026-05-01",
        pos_x=2.0,
        pos_y=2.0,
        notes="Rack principal de distribución y servidores críticos.",
    )
    rack_2 = Rack(
        room_id=room_28.id,
        aisle_id=aisle_a.id,
        code="RK002_M",
        name="M_Rack002",
        total_units=42,
        manufacturer="Rittal",
        model_name="VX IT 42U 800x1000",
        serial_number="RIT-2026-88413",
        responsible_person="Alex Geng",
        purchase_date="2026-04-01",
        operation_start="2026-05-01",
        pos_x=3.0,
        pos_y=2.0,
        notes="Rack adyacente en Pasillo Frío A (Core Backup y Almacenamiento).",
    )
    rack_3 = Rack(
        room_id=room_28.id,
        aisle_id=aisle_b.id,
        code="RK003_B",
        name="B_Rack003",
        total_units=42,
        manufacturer="APC",
        model_name="NetShelter SX 42U",
        serial_number="APC-99102",
        responsible_person="Mario Admin",
        pos_x=2.0,
        pos_y=5.5,
    )
    rack_new1 = Rack(
        room_id=room_new.id,
        aisle_id=aisle_new.id,
        code="RK_NEW_01",
        name="NewHQ_Rack01",
        total_units=42,
        manufacturer="Rittal",
    )
    rack_prd1 = Rack(
        room_id=room_prd1.id,
        aisle_id=aisle_prd.id,
        code="RK_PRD_01",
        name="Prod_Rack01",
        total_units=42,
        manufacturer="Rittal",
    )
    db.add_all([rack_1, rack_2, rack_3, rack_new1, rack_prd1])
    db.flush()

    # 3. Montar dispositivos en RK001_M (inspirado en la imagen 1, con Front y Back)
    tpl_fiber = tpl_map["gateway"]
    tpl_router = tpl_map["router"]
    tpl_pbx = tpl_map["patchbox"]
    tpl_sw = tpl_map["switch"]
    tpl_pp = tpl_map["patch_panel"]
    tpl_srv2u = tpl_map["server:ProLiant DL380 Gen11 (2U Full-Depth)"]
    tpl_srv1u = tpl_map["server:PowerEdge R660 (1U Full-Depth)"]
    tpl_ups = tpl_map["ups"]
    tpl_pdu = tpl_map["pdu"]
    tpl_fw = tpl_map["firewall"]

    devices_spec = [
        # FRONT DEVICES
        dict(
            rack_id=rack_1.id,
            template=tpl_fiber,
            code="FI-01",
            name="Bandeja Fibra Principal FI-01",
            hostname="fi-01-tray",
            fqdn="fi01.hq.rackdoc.local",
            start_u=41,
            mounted_face="front",
            ip_address="127.0.0.1",
            subnet_mask="255.255.255.0",
            gateway="10.28.0.1",
            vlan_mgmt=10,
            management_links=[{"protocol": "https", "port": 443, "username": "admin", "label": "Web Panel"}],
            monitoring_enabled=True,
            monitor_method="icmp",
            status="online",
            last_ping_ms=0.8,
            serial_number="FIB-2026-001",
            custom_fields={"Proveedor Fibra": "DarkFiber EU", "Conector": "LC/APC OM4"},
        ),
        dict(
            rack_id=rack_1.id,
            template=tpl_router,
            code="RT01",
            name="Core Router CCR2116",
            hostname="rt01-core",
            fqdn="rt01.hq.rackdoc.local",
            start_u=39,
            mounted_face="front",
            ip_address="127.0.0.1",
            subnet_mask="255.255.255.0",
            gateway="10.28.0.1",
            vlan_mgmt=1,
            management_links=[
                {"protocol": "ssh", "port": 22, "username": "admin", "label": "SSH Terminal"},
                {"protocol": "https", "port": 8443, "username": "admin", "label": "WebFig HTTPS"},
                {"protocol": "telnet", "port": 23, "username": "admin", "label": "Telnet Console"},
            ],
            monitoring_enabled=True,
            monitor_method="icmp",
            status="online",
            last_ping_ms=1.1,
            serial_number="MT-CCR-99812",
            custom_fields={"BGP ASN": "65001", "OS Version": "RouterOS 7.16", "Contrato": "24x7 Gold"},
        ),
        dict(
            rack_id=rack_1.id,
            template=tpl_pbx,
            code="PBX01",
            name="PATCHBOX Plus+ 01",
            hostname="",
            fqdn="",
            start_u=38,
            mounted_face="front",
            serial_number="PBX-001",
            custom_fields={"Cassettes": "24x Cat.6a Azul"},
        ),
        dict(
            rack_id=rack_1.id,
            template=tpl_sw,
            code="SW01",
            name="Switch Acceso Planta 2 (SW01)",
            hostname="sw01-acc-hq",
            fqdn="sw01.hq.rackdoc.local",
            start_u=37,
            mounted_face="front",
            ip_address="127.0.0.1",
            subnet_mask="255.255.255.0",
            gateway="10.28.0.1",
            vlan_mgmt=10,
            management_links=[
                {"protocol": "ssh", "port": 22, "username": "netadmin", "label": "SSH CLI"},
                {"protocol": "https", "port": 443, "username": "netadmin", "label": "Cisco WebUI"},
            ],
            monitoring_enabled=True,
            monitor_method="icmp",
            status="online",
            last_ping_ms=1.4,
            serial_number="FOC2614Y12A",
            custom_fields={"IOS Version": "17.9.4a", "PoE Budget": "740W", "Stack ID": "1"},
        ),
        dict(
            rack_id=rack_1.id,
            template=tpl_pp,
            code="A",
            name="Patch Panel A (Tomas Sala 28 Norte)",
            start_u=36,
            mounted_face="front",
            serial_number="PP-A-28",
        ),
        dict(
            rack_id=rack_1.id,
            template=tpl_pp,
            code="B",
            name="Patch Panel B (Tomas Sala 28 Sur)",
            start_u=35,
            mounted_face="front",
            serial_number="PP-B-28",
        ),
        dict(
            rack_id=rack_1.id,
            template=tpl_pp,
            code="C",
            name="Patch Panel C (Oficinas Planta 2)",
            start_u=34,
            mounted_face="front",
            serial_number="PP-C-28",
        ),
        dict(
            rack_id=rack_1.id,
            template=tpl_pp,
            code="D",
            name="Patch Panel D (Wi-Fi APs & CCTV)",
            start_u=33,
            mounted_face="front",
            serial_number="PP-D-28",
        ),
        dict(
            rack_id=rack_1.id,
            template=tpl_pp,
            code="E",
            name="Patch Panel E (Voz & Salas Reuniones)",
            start_u=32,
            mounted_face="front",
            serial_number="PP-E-28",
        ),
        dict(
            rack_id=rack_1.id,
            template=tpl_sw,
            code="SW02",
            name="Switch Acceso Planta 2 (SW02)",
            hostname="sw02-acc-hq",
            fqdn="sw02.hq.rackdoc.local",
            start_u=31,
            mounted_face="front",
            ip_address="10.28.1.12",
            subnet_mask="255.255.255.0",
            gateway="10.28.1.1",
            vlan_mgmt=10,
            management_links=[
                {"protocol": "ssh", "port": 22, "username": "netadmin", "label": "SSH CLI"},
                {"protocol": "https", "port": 443, "username": "netadmin", "label": "Cisco WebUI"},
            ],
            monitoring_enabled=True,
            monitor_method="icmp",
            status="online",
            last_ping_ms=2.3,
            serial_number="FOC2614Y12B",
            custom_fields={"IOS Version": "17.9.4a", "Stack ID": "2"},
        ),
        dict(
            rack_id=rack_1.id,
            template=tpl_pbx,
            code="PBX02",
            name="PATCHBOX Plus+ 02",
            start_u=30,
            mounted_face="front",
            serial_number="PBX-002",
        ),
        dict(
            rack_id=rack_1.id,
            template=tpl_sw,
            code="SW03",
            name="Switch Servidores & DMZ (SW03)",
            hostname="sw03-dmz-hq",
            fqdn="sw03.hq.rackdoc.local",
            start_u=29,
            mounted_face="front",
            ip_address="10.28.1.13",
            subnet_mask="255.255.255.0",
            gateway="10.28.1.1",
            vlan_mgmt=10,
            management_links=[
                {"protocol": "ssh", "port": 22, "username": "netadmin", "label": "SSH CLI"},
                {"protocol": "telnet", "port": 23, "username": "netadmin", "label": "Telnet Legacy"},
            ],
            monitoring_enabled=True,
            monitor_method="icmp",
            status="online",
            last_ping_ms=1.9,
            serial_number="FOC2614Y12C",
        ),
        dict(
            rack_id=rack_1.id,
            template=tpl_pbx,
            code="PBX03",
            name="PATCHBOX Plus+ 03",
            start_u=28,
            mounted_face="front",
            serial_number="PBX-003",
        ),
        dict(
            rack_id=rack_1.id,
            template=tpl_fw,
            code="FW01",
            name="Firewall Perimetral FortiGate 200F",
            hostname="fw01-perimeter",
            fqdn="fw01.hq.rackdoc.local",
            start_u=26,
            mounted_face="front",
            ip_address="10.28.0.254",
            subnet_mask="255.255.255.0",
            gateway="10.28.0.1",
            vlan_mgmt=99,
            management_links=[
                {"protocol": "https", "port": 8443, "username": "secadmin", "label": "FortiOS Web"},
                {"protocol": "ssh", "port": 22, "username": "secadmin", "label": "SSH Console"},
            ],
            monitoring_enabled=True,
            monitor_method="icmp",
            status="online",
            last_ping_ms=1.5,
            serial_number="FG200F-884120",
            custom_fields={"FortiOS": "v7.4.3", "HA Mode": "Active-Passive"},
        ),
        dict(
            rack_id=rack_1.id,
            template=tpl_srv2u,
            code="SRV01",
            name="Hypervisor Proxmox Cluster Node 01",
            hostname="pve-node-01",
            fqdn="pve01.hq.rackdoc.local",
            start_u=22,
            mounted_face="front",
            ip_address="10.28.10.21",
            subnet_mask="255.255.255.0",
            gateway="10.28.10.1",
            vlan_mgmt=20,
            management_links=[
                {"protocol": "https", "port": 8006, "username": "root", "label": "Proxmox Web UI"},
                {"protocol": "ssh", "port": 22, "username": "root", "label": "SSH Root"},
                {"protocol": "https", "port": 443, "username": "Administrator", "label": "HPE iLO 6"},
            ],
            monitoring_enabled=True,
            monitor_method="icmp",
            status="online",
            last_ping_ms=0.6,
            serial_number="CZ2411098A",
            custom_fields={"CPU": "2x Xeon Gold 6430", "RAM": "512 GB DDR5", "RAID": "ZFS NVMe 16TB"},
        ),
        dict(
            rack_id=rack_1.id,
            template=tpl_srv1u,
            code="SRV02",
            name="Database Server PostgreSQL Primary",
            hostname="db-pg-01",
            fqdn="db01.hq.rackdoc.local",
            start_u=20,
            mounted_face="front",
            ip_address="10.28.10.30",
            subnet_mask="255.255.255.0",
            gateway="10.28.10.1",
            vlan_mgmt=20,
            management_links=[
                {"protocol": "ssh", "port": 22, "username": "postgres", "label": "SSH Server"},
                {"protocol": "https", "port": 443, "username": "root", "label": "Dell iDRAC 9"},
            ],
            monitoring_enabled=True,
            monitor_method="icmp",
            status="warning",
            last_ping_ms=42.5,
            serial_number="DELL-R660-771",
            custom_fields={"CPU": "2x Xeon Silver", "RAM": "256 GB", "Rol": "BBDD Transaccional"},
        ),
        dict(
            rack_id=rack_1.id,
            template=tpl_ups,
            code="UPS01",
            name="SAI Principal APC Smart-UPS 3000VA",
            hostname="ups01-hq",
            fqdn="ups01.hq.rackdoc.local",
            start_u=2,
            mounted_face="front",
            ip_address="10.28.99.10",
            subnet_mask="255.255.255.0",
            gateway="10.28.99.1",
            vlan_mgmt=99,
            management_links=[
                {"protocol": "https", "port": 443, "username": "apc", "label": "APC Network Mgmt"},
                {"protocol": "telnet", "port": 23, "username": "apc", "label": "Telnet NMC"},
            ],
            monitoring_enabled=True,
            monitor_method="icmp",
            status="online",
            last_ping_ms=3.1,
            serial_number="AS26119920",
            custom_fields={"Autonomía": "38 min @ 65%", "Baterías Cambiadas": "2026-01-15"},
        ),
        # BACK DEVICES (Montados en la cara trasera del mismo rack RK001_M)
        dict(
            rack_id=rack_1.id,
            template=tpl_pdu,
            code="PDU-A",
            name="PDU Eléctrica Circuito A (Línea SAI)",
            hostname="pdu-a-rk01",
            fqdn="pdua.rk01.hq.rackdoc.local",
            start_u=40,
            mounted_face="back",
            ip_address="10.28.99.11",
            subnet_mask="255.255.255.0",
            gateway="10.28.99.1",
            vlan_mgmt=99,
            management_links=[{"protocol": "https", "port": 443, "username": "apc", "label": "PDU Web"}],
            monitoring_enabled=True,
            monitor_method="icmp",
            status="online",
            last_ping_ms=2.8,
            serial_number="PDU-A-001",
            custom_fields={"Circuito": "Línea A - SAI", "Consumo Actual": "6.4 A (1.47 kW)"},
        ),
        dict(
            rack_id=rack_1.id,
            template=tpl_pdu,
            code="PDU-B",
            name="PDU Eléctrica Circuito B (Línea Red/Grupo)",
            hostname="pdu-b-rk01",
            fqdn="pdub.rk01.hq.rackdoc.local",
            start_u=36,
            mounted_face="back",
            ip_address="10.28.99.12",
            subnet_mask="255.255.255.0",
            gateway="10.28.99.1",
            vlan_mgmt=99,
            management_links=[{"protocol": "https", "port": 443, "username": "apc", "label": "PDU Web"}],
            monitoring_enabled=True,
            monitor_method="icmp",
            status="online",
            last_ping_ms=2.9,
            serial_number="PDU-B-002",
            custom_fields={"Circuito": "Línea B - Grupo Electrógeno", "Consumo Actual": "5.8 A (1.33 kW)"},
        ),
        # Equipo en el Rack 2 para demostrar conexiones OUTBOUND entre Racks
        dict(
            rack_id=rack_2.id,
            template=tpl_sw,
            code="SW-RK2-01",
            name="Switch Distribución Rack 02",
            hostname="sw01-rk02",
            fqdn="sw01.rk02.hq.rackdoc.local",
            start_u=40,
            mounted_face="front",
            ip_address="10.28.1.21",
            subnet_mask="255.255.255.0",
            gateway="10.28.1.1",
            vlan_mgmt=10,
            management_links=[{"protocol": "ssh", "port": 22, "username": "netadmin", "label": "SSH CLI"}],
            monitoring_enabled=True,
            status="online",
            last_ping_ms=1.7,
            serial_number="FOC2614Y99Z",
        ),
    ]

    dev_by_code: dict[str, RackDevice] = {}
    ports_by_key: dict[str, Port] = {}

    for spec in devices_spec:
        tpl = spec.pop("template")
        dev = RackDevice(
            template_id=tpl.id,
            last_checked_at=datetime.utcnow(),
            **spec,
        )
        db.add(dev)
        db.flush()
        dev_by_code[dev.code] = dev
        ports = create_ports_from_template(db, dev, tpl)
        for p in ports:
            ports_by_key[f"{dev.code}:{p.face}:{p.port_number}"] = p

    def connect(
        src_key: str,
        dst_key: str,
        cable_type: str = "utp_cat6a",
        color_hex: str = "#2563EB",
        channel: str = "auto",
        label: str = "",
        vlan: int | None = None,
        length_m: float = 1.5,
    ):
        sp = ports_by_key.get(src_key)
        tp = ports_by_key.get(dst_key)
        if sp and tp:
            db.add(
                Connection(
                    source_port_id=sp.id,
                    target_port_id=tp.id,
                    cable_type=cable_type,
                    color_hex=color_hex,
                    routing_channel=channel,
                    label=label,
                    vlan=vlan,
                    length_m=length_m,
                )
            )

    # 4. Crear Cableado Frontal (Red Cobre + Fibra Óptica + Outbound)
    # Conexiones Fibra Óptica (FI-01 -> RT01 -> SW01 / SW02 / FW01)
    connect("FI-01:front:F23", "RT01:front:SFP1", "fiber_om4", "#0284C7", "right", "Uplink Fibra ISP1", 100, 2.0)
    connect("RT01:front:SFP2", "SW01:front:SFP1", "fiber_om4", "#F59E0B", "right", "Trunk Core -> SW01 10G", 1, 1.5)
    connect("RT01:front:SFP3", "SW02:front:SFP1", "fiber_om4", "#F59E0B", "right", "Trunk Core -> SW02 10G", 1, 2.5)
    connect("RT01:front:SFP4", "FW01:front:SFP1", "fiber_om4", "#06B6D4", "right", "Enlace Firewall HA 10G", 99, 2.0)

    # Conexión OUTBOUND hacia el Rack 2 (M_Rack002)
    connect(
        "SW01:front:SFP4",
        "SW-RK2-01:front:SFP1",
        "fiber_os2",
        "#10B981",
        "right",
        "Inter-Rack Fiber Trunk RK001 -> RK002",
        10,
        8.0,
    )

    # Latiguillos de Red Cobre en cara Frontal (estilo captura Patchbox por canaletas izq y der)
    for port_n, ch in [(1, "left"), (3, "left"), (5, "left"), (7, "left")]:
        connect(
            f"PBX01:front:{port_n}",
            f"A:front:{port_n}",
            "utp_cat6a",
            "#2563EB",
            ch,
            f"Patching Planta 2 Norte P{port_n}",
            20,
            1.0,
        )

    for port_n, ch in [(10, "left"), (12, "left"), (14, "left")]:
        connect(
            f"SW01:front:{port_n}",
            f"B:front:{port_n}",
            "utp_cat6a",
            "#2563EB",
            ch,
            f"Acceso Usuarios Sur P{port_n}",
            20,
            1.2,
        )

    for port_n, ch in [(18, "right"), (20, "right"), (22, "right"), (24, "right")]:
        connect(
            f"PBX01:front:{port_n}",
            f"SW01:front:{port_n}",
            "utp_cat6a",
            "#2563EB",
            ch,
            f"Puente PBX01 -> SW01 #{port_n}",
            30,
            0.8,
        )

    for port_n, ch in [(2, "left"), (6, "left"), (11, "left")]:
        connect(
            f"C:front:{port_n}",
            f"SW02:front:{port_n}",
            "utp_cat6a",
            "#2563EB",
            ch,
            f"Oficinas Planta 2 #{port_n}",
            30,
            1.5,
        )

    for port_n, ch in [(4, "left"), (8, "left"), (16, "right"), (19, "right")]:
        connect(
            f"D:front:{port_n}",
            f"PBX02:front:{port_n}",
            "utp_cat6a",
            "#2563EB",
            ch,
            f"AP Wi-Fi 6E #{port_n}",
            40,
            1.5,
        )

    for port_n, ch in [(15, "right"), (17, "right"), (21, "right"), (23, "right")]:
        connect(
            f"E:front:{port_n}",
            f"SW03:front:{port_n}",
            "utp_cat6a",
            "#2563EB",
            ch,
            f"VoIP Teléfonos #{port_n}",
            50,
            1.5,
        )

    # 5. Crear Cableado Trasero (Electricidad Redundante A+B y Red de Servidores / Pass-Through)
    # SAI (UPS01) alimentando PDU-A
    connect("UPS01:back:OUT1", "PDU-A:back:IN1", "power_ac", "#DC2626", "left", "Alimentación General SAI -> PDU-A", None, 3.0)

    # Fuentes redundantes PSU1 (a PDU-A en rojo) y PSU2 (a PDU-B en naranja/negro) en cara BACK
    connect("PDU-A:back:P1", "RT01:back:PSU1", "power_ac", "#DC2626", "left", "Línea Eléctrica A -> RT01 PSU1", None, 1.0)
    connect("PDU-B:back:P1", "RT01:back:PSU2", "power_ac", "#EA580C", "right", "Línea Eléctrica B -> RT01 PSU2", None, 1.2)

    connect("PDU-A:back:P2", "SW01:back:PSU1", "power_ac", "#DC2626", "left", "Línea Eléctrica A -> SW01 PSU1", None, 1.0)
    connect("PDU-B:back:P2", "SW01:back:PSU2", "power_ac", "#EA580C", "right", "Línea Eléctrica B -> SW01 PSU2", None, 1.0)

    connect("PDU-A:back:P3", "FW01:back:PSU1", "power_ac", "#DC2626", "left", "Línea Eléctrica A -> FW01 PSU1", None, 1.5)
    connect("PDU-B:back:P3", "FW01:back:PSU2", "power_ac", "#EA580C", "right", "Línea Eléctrica B -> FW01 PSU2", None, 1.5)

    connect("PDU-A:back:P4", "SRV01:back:PSU1", "power_ac", "#DC2626", "left", "Línea Eléctrica A -> SRV01 PSU1", None, 1.8)
    connect("PDU-B:back:P4", "SRV01:back:PSU2", "power_ac", "#EA580C", "right", "Línea Eléctrica B -> SRV01 PSU2", None, 1.8)

    connect("PDU-A:back:P5", "SRV02:back:PSU1", "power_ac", "#DC2626", "left", "Línea Eléctrica A -> SRV02 PSU1", None, 2.0)
    connect("PDU-B:back:P5", "SRV02:back:PSU2", "power_ac", "#EA580C", "right", "Línea Eléctrica B -> SRV02 PSU2", None, 2.0)

    # Conexiones PASS-THROUGH (de la trasera de los servidores SRV01/SRV02 hacia el Switch frontal SW03)
    connect(
        "SRV01:back:NIC1",
        "SW03:front:1",
        "utp_cat6a",
        "#2563EB",
        "left",
        "Pass-Through SRV01 NIC1 -> SW03 P1",
        20,
        2.5,
    )
    connect(
        "SRV01:back:SFP1",
        "SW03:front:SFP1",
        "fiber_om4",
        "#F59E0B",
        "right",
        "Pass-Through Fibra 10G SRV01 -> SW03",
        20,
        2.5,
    )
    connect(
        "SRV02:back:NIC1",
        "SW03:front:2",
        "utp_cat6a",
        "#2563EB",
        "left",
        "Pass-Through SRV02 NIC1 -> SW03 P2",
        20,
        2.5,
    )

    db.commit()


def get_or_create_external_feed_template(db: Session) -> DeviceTemplate:
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
    socket_count = max(1, min(16, int(socket_count)))
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

    # Si faltan puertos Schuko, crearlos
    current_len = len(existing_ports)
    for idx in range(current_len, socket_count):
        num = idx + 1
        p_num = f"SCH{num}"
        port = Port(
            rack_device_id=device.id,
            port_number=p_num,
            label=f"{device.code}:{p_num}",
            face="front",
            port_type="power_schuko",
            row_index=0,
            col_index=idx,
            rel_x=round(0.15 + 0.70 * (idx / max(1, socket_count - 1)), 4),
            rel_y=0.5,
        )
        db.add(port)

    db.flush()


def ensure_rack_external_outlets(db: Session, rack: Rack):
    ext_devices = [d for d in rack.devices if d.mounted_face == "external"]
    if ext_devices:
        return

    tpl = get_or_create_external_feed_template(db)
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
            "feed_color": "#2563EB",
            "socket_count": 4,
        },
        notes="Acometida eléctrica exterior Línea B (Estándar Azul)",
    )
    db.add_all([feed_a, feed_b])
    db.flush()
    sync_external_outlet_ports(db, feed_a, 4)
    sync_external_outlet_ports(db, feed_b, 4)

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
        existing_admin.password_hash = admin_pass
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
                password_hash=admin_pass,
                role="admin",
                auth_source="local",
                is_active=True,
            )
        )
    db.flush()

    # Crear servidores AD de ejemplo si no hay ninguno todavía
    if db.query(ADServer).count() == 0:
        ad1 = ADServer(
            name="AD Corporativo Central (HQ)",
            ldap_url="ldap://dc01.corp.rackdoc.local:389",
            domain="corp.rackdoc.local",
            base_dn="DC=corp,DC=rackdoc,DC=local",
            bind_dn="CN=svc_rackdoc,OU=ServiceAccounts,DC=corp,DC=rackdoc,DC=local",
            bind_password="secret",
            user_filter="(&(objectClass=user)(sAMAccountName={username}))",
            default_role="operator",
            enabled=True,
        )
        ad2 = ADServer(
            name="AD Planta Producción & OT",
            ldap_url="ldap://ad-ot.industrial.local:389",
            domain="industrial.local",
            base_dn="DC=industrial,DC=local",
            bind_dn="CN=ldap_reader,OU=Admins,DC=industrial,DC=local",
            bind_password="secret",
            user_filter="(&(objectClass=user)(sAMAccountName={username}))",
            default_role="viewer",
            enabled=True,
        )
        db.add_all([ad1, ad2])
        db.flush()

    # Crear usuarios de muestra con los otros 3 roles si solo existe admin
    if db.query(User).count() <= 1:
        first_ad = db.query(ADServer).first()
        demo_users = [
            User(
                username="editor",
                email="editor@rackdoc.local",
                full_name="Carlos Ingeniero (Rol Editor)",
                password_hash="editor",
                role="editor",
                auth_source="local",
                is_active=True,
            ),
            User(
                username="operador",
                email="operador@rackdoc.local",
                full_name="Laura NOC (Ver + Conectarse SSH/Web)",
                password_hash="operador",
                role="operator",
                auth_source="ad" if first_ad else "local",
                ad_server_id=first_ad.id if first_ad else None,
                ad_dn="CN=Laura NOC,OU=NOC,DC=corp,DC=rackdoc,DC=local",
                is_active=True,
            ),
            User(
                username="visor",
                email="visor@rackdoc.local",
                full_name="Auditor Externo (Rol Solo Ver)",
                password_hash="visor",
                role="viewer",
                auth_source="local",
                is_active=True,
            ),
        ]
        db.add_all(demo_users)
        db.flush()

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
            else:
                t.library_group = "Host - HP"
        else:
            if t.library_group == "Network":
                t.library_group = "Patching & Passive"

    # Asegurar plantillas adicionales para 'Power' (Regleta Schuko, Enchufe Schuko Simple) y 'Host - HP'
    extra_templates = [
        {
            "library_group": "Power",
            "category": "pdu",
            "manufacturer": "Rittal",
            "model_name": "Regleta PDU 8x Enchufes Schuko 1U",
            "u_height": 1,
            "is_full_depth": False,
            "default_color": "#FEFCE8",
            "layout_spec": {
                "front": [
                    {
                        "port_type": "power_schuko",
                        "prefix": "SCH",
                        "count": 8,
                        "rows": 1,
                        "start_x": 0.16,
                        "end_x": 0.90,
                    }
                ],
                "back": [
                    {
                        "port_type": "power_c14",
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
            "is_full_depth": False,
            "default_color": "#FEF2F2",
            "layout_spec": {
                "front": [
                    {
                        "port_type": "power_schuko",
                        "prefix": "SCH",
                        "count": 2,
                        "rows": 1,
                        "start_x": 0.35,
                        "end_x": 0.65,
                    }
                ],
                "back": [
                    {
                        "port_type": "power_schuko",
                        "prefix": "IN",
                        "count": 1,
                        "rows": 1,
                        "start_x": 0.20,
                        "end_x": 0.25,
                    }
                ],
            },
        },
        {
            "library_group": "Host - HP",
            "category": "server",
            "manufacturer": "HPE",
            "model_name": "ProLiant DL360 Gen11 (1U Full-Depth)",
            "u_height": 1,
            "is_full_depth": True,
            "default_color": "#F1F5F9",
            "layout_spec": {
                "front": [
                    {
                        "port_type": "rj45",
                        "prefix": "iLO-F",
                        "count": 1,
                        "rows": 1,
                        "start_x": 0.88,
                        "end_x": 0.90,
                    }
                ],
                "back": [
                    {
                        "port_type": "rj45",
                        "prefix": "iLO",
                        "count": 1,
                        "rows": 1,
                        "start_x": 0.12,
                        "end_x": 0.15,
                    },
                    {
                        "port_type": "rj45",
                        "prefix": "NIC",
                        "count": 4,
                        "rows": 1,
                        "start_x": 0.24,
                        "end_x": 0.44,
                    },
                    {
                        "port_type": "sfp_plus",
                        "prefix": "SFP",
                        "count": 2,
                        "rows": 1,
                        "start_x": 0.52,
                        "end_x": 0.62,
                    },
                    {
                        "port_type": "power_c14",
                        "prefix": "PSU",
                        "count": 2,
                        "rows": 1,
                        "start_x": 0.78,
                        "end_x": 0.90,
                    },
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
    db.flush()

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

    db.flush()

    # Si PDU-B estaba en U36 (colisionando con Patch Panel A en U36), moverlo a U25 libre
    pdu_b = db.query(RackDevice).filter(RackDevice.code == "PDU-B").first()
    if pdu_b and pdu_b.start_u == 36:
        pdu_b.start_u = 25

    for pdu_dev in db.query(RackDevice).filter(RackDevice.code.in_(["PDU-A", "PDU-B"])).all():
        for p in pdu_dev.ports:
            if p.port_number.startswith("IN"):
                p.face = "front"

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

    # Asegurar que cada Rack tenga sus Tomas Exteriores Schuko (mínimo 1, por defecto 2: Línea A Roja y Línea B Azul)
    racks = db.query(Rack).all()
    for rk in racks:
        ensure_rack_external_outlets(db, rk)

    db.commit()
