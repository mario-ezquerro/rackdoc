from io import BytesIO
import json
import re
from typing import Optional, Dict, Any
from openpyxl import Workbook, load_workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter
from sqlalchemy.orm import Session
from ..models import (
    Location,
    Floor,
    Room,
    Aisle,
    Rack,
    DeviceTemplate,
    RackDevice,
    Connection,
    Port,
)
from ..seed import create_ports_from_template, ensure_rack_external_outlets


def _style_worksheet(ws):
    header_fill = PatternFill(start_color="0F172A", end_color="0F172A", fill_type="solid")
    header_font = Font(name="Calibri", size=11, bold=True, color="FFFFFF")
    cell_font = Font(name="Calibri", size=10, color="1E293B")
    thin_border = Border(
        left=Side(style="thin", color="E2E8F0"),
        right=Side(style="thin", color="E2E8F0"),
        top=Side(style="thin", color="E2E8F0"),
        bottom=Side(style="thin", color="E2E8F0"),
    )

    for cell in ws[1]:
        cell.fill = header_fill
        cell.font = header_font
        cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)

    for row in ws.iter_rows(min_row=2):
        for cell in row:
            cell.font = cell_font
            cell.border = thin_border
            cell.alignment = Alignment(vertical="center")

    for col in ws.columns:
        max_len = 0
        col_letter = get_column_letter(col[0].column)
        for cell in col:
            val_str = str(cell.value or "")
            if len(val_str) > max_len:
                max_len = len(val_str)
        ws.column_dimensions[col_letter].width = min(max(max_len + 4, 12), 45)

    ws.freeze_panes = "A2"


def generate_datacenter_excel(
    db: Session,
    location_id: Optional[int] = None,
    rack_id: Optional[int] = None,
) -> BytesIO:
    """
    Genera un informe Excel (.xlsx) completo con 3 hojas:
    1. Ubicaciones, Pasillos y Racks
    2. Inventario de Equipos, Red (FQDN, IP, Máscara, Gateway, SSH/Web) y Estado Ping
    3. Mapa de Cableado (Red, Fibra y Electricidad en Front y Back)
    """
    wb = Workbook()

    # 1. Hoja de Racks y Pasillos
    ws_racks = wb.active
    ws_racks.title = "Racks y Pasillos"
    ws_racks.append([
        "Sede (Código)",
        "Sede (Nombre)",
        "Planta",
        "Sala",
        "Pasillo / Fila",
        "Tipo Pasillo",
        "Código Rack",
        "Nombre Rack",
        "U Totales",
        "Equipos Montados",
        "Fabricante",
        "Modelo",
        "Nº Serie",
        "Responsable",
        "Inicio Operación",
        "Notas",
    ])

    racks_query = db.query(Rack).join(Room).join(Floor).join(Location)
    if location_id is not None:
        racks_query = racks_query.filter(Location.id == location_id)
    if rack_id is not None:
        racks_query = racks_query.filter(Rack.id == rack_id)

    racks = racks_query.all()
    rack_ids = {r.id for r in racks}

    for r in racks:
        room = r.room
        floor = room.floor if room else None
        loc = floor.location if floor else None
        aisle = r.aisle
        ws_racks.append([
            loc.code if loc else "",
            loc.name if loc else "",
            floor.name if floor else "",
            room.name if room else "",
            aisle.name if aisle else "Sin pasillo",
            aisle.aisle_type if aisle else "",
            r.code,
            r.name,
            r.total_units,
            len(r.devices),
            r.manufacturer,
            r.model_name,
            r.serial_number,
            r.responsible_person,
            r.operation_start,
            r.notes,
        ])
    _style_worksheet(ws_racks)

    # 2. Hoja de Hardware, Red y Monitorización
    ws_devs = wb.create_sheet(title="Hardware y Red")
    ws_devs.append([
        "Rack",
        "Pasillo",
        "Unidad U",
        "Altura (U)",
        "Cara Montaje",
        "Profundidad Completa",
        "Código",
        "Nombre Dispositivo",
        "Categoría",
        "Fabricante / Modelo",
        "Hostname",
        "FQDN",
        "Dirección IP",
        "Máscara de Subred",
        "Gateway",
        "VLAN Gestión",
        "MAC Address",
        "Accesos Remotos (SSH/Telnet/Web)",
        "Estado Ping",
        "Latencia (ms)",
        "Último Check",
        "Nº Serie",
        "Variables Extra (Custom)",
        "Notas",
    ])

    devs_query = db.query(RackDevice)
    if rack_ids:
        devs_query = devs_query.filter(RackDevice.rack_id.in_(rack_ids))
    elif location_id is not None or rack_id is not None:
        devs_query = devs_query.filter(RackDevice.id == -1)

    devices = devs_query.order_by(RackDevice.rack_id, RackDevice.start_u.desc()).all()
    for d in devices:
        tpl = d.template
        u_end = d.start_u + (tpl.u_height - 1 if tpl else 0)
        u_range = f"U{d.start_u}" if u_end == d.start_u else f"U{d.start_u}-U{u_end}"
        links_str = ", ".join(
            f"{lnk.get('protocol', '').upper()}:{lnk.get('port', '')}"
            for lnk in (d.management_links or [])
        )
        custom_str = json.dumps(d.custom_fields, ensure_ascii=False) if d.custom_fields else ""

        ws_devs.append([
            d.rack.code if d.rack else "",
            d.rack.aisle.name if (d.rack and d.rack.aisle) else "",
            u_range,
            tpl.u_height if tpl else 1,
            d.mounted_face.upper(),
            "Sí (Front+Back)" if (tpl and tpl.is_full_depth) else "No",
            d.code,
            d.name,
            tpl.category if tpl else "",
            f"{tpl.manufacturer} {tpl.model_name}" if tpl else "",
            d.hostname,
            d.fqdn,
            d.ip_address,
            d.subnet_mask,
            d.gateway,
            d.vlan_mgmt or "",
            d.mac_address,
            links_str,
            d.status.upper(),
            d.last_ping_ms if d.last_ping_ms is not None else "",
            d.last_checked_at.strftime("%Y-%m-%d %H:%M:%S") if d.last_checked_at else "",
            d.serial_number,
            custom_str,
            d.notes,
        ])
    _style_worksheet(ws_devs)

    # 3. Hoja de Mapa de Cableado (Patching)
    ws_cables = wb.create_sheet(title="Mapa de Cableado")
    ws_cables.append([
        "ID Cable",
        "Tipo de Conexión",
        "Etiqueta / Circuito",
        "VLAN",
        "Canaleta",
        "Longitud (m)",
        "Rack Origen",
        "Equipo Origen",
        "Cara Origen",
        "Boca Origen",
        "Rack Destino",
        "Equipo Destino",
        "Cara Destino",
        "Boca Destino",
        "Ámbito",
        "Notas",
    ])

    conns = db.query(Connection).all()
    for c in conns:
        sp: Port = c.source_port
        tp: Port = c.target_port
        if not sp or not tp or not sp.device or not tp.device:
            continue
        if rack_ids and (sp.device.rack_id not in rack_ids and tp.device.rack_id not in rack_ids):
            continue

        s_dev = sp.device
        t_dev = tp.device
        if s_dev.rack_id != t_dev.rack_id:
            scope = "OUTBOUND (Entre Racks)"
        elif sp.face != tp.face:
            scope = "PASS-THROUGH (Front <-> Back)"
        else:
            scope = f"Misma Cara ({sp.face.upper()})"

        ws_cables.append([
            c.id,
            c.cable_type,
            c.label,
            c.vlan or "",
            c.routing_channel,
            c.length_m,
            s_dev.rack.code if s_dev.rack else "",
            f"{s_dev.code} ({s_dev.name})",
            sp.face.upper(),
            f"{sp.port_number} ({sp.port_type})",
            t_dev.rack.code if t_dev.rack else "",
            f"{t_dev.code} ({t_dev.name})",
            tp.face.upper(),
            f"{tp.port_number} ({tp.port_type})",
            scope,
            c.notes,
        ])
    _style_worksheet(ws_cables)

    output = BytesIO()
    wb.save(output)
    output.seek(0)
    return output


def generate_excel_import_template() -> BytesIO:
    """
    Genera una plantilla Excel (.xlsx) de ejemplo lista para rellenar e importar en RackDoc:
    - Hoja 1: 1_Racks_y_Sedes (para dar de alta o actualizar Sedes, Plantas, Salas y Racks)
    - Hoja 2: 2_Equipos_y_Hosts (para montar o actualizar switches, servidores, PDUs, IPs y Heartbeat)
    - Hoja 3: 3_Instrucciones_y_Librerias (guía rápida de campos y librerías soportadas)
    """
    wb = Workbook()

    # Hoja 1: Racks y Sedes
    ws_racks = wb.active
    ws_racks.title = "1_Racks_y_Sedes"
    ws_racks.append([
        "Sede (Código)",
        "Sede (Nombre)",
        "Planta",
        "Sala",
        "Pasillo / Fila",
        "Código Rack",
        "Nombre Rack",
        "U Totales",
        "Fabricante",
        "Modelo",
        "Responsable",
        "Notas",
    ])
    ws_racks.append([
        "HQ",
        "Headquarter",
        "Floor 2 - Core CPD",
        "28 - Sala Servidores",
        "Pasillo Frío A (Core)",
        "RK005_NEW",
        "Rack Expansión Core 05",
        42,
        "Rittal",
        "VX IT 42U",
        "Equipo Infraestructura",
        "Rack de ejemplo importado desde Excel",
    ])
    _style_worksheet(ws_racks)

    # Hoja 2: Equipos y Hosts
    ws_devs = wb.create_sheet(title="2_Equipos_y_Hosts")
    ws_devs.append([
        "Código Rack",
        "Unidad U Inicial",
        "Altura (U)",
        "Cara Montaje",
        "Código Equipo",
        "Nombre Dispositivo",
        "Librería",
        "Fabricante",
        "Modelo",
        "Hostname",
        "FQDN",
        "Dirección IP",
        "Máscara de Subred",
        "Gateway",
        "VLAN Gestión",
        "Heartbeat Activo",
        "Método Heartbeat",
        "Puerto Heartbeat",
        "URL Extra Heartbeat",
        "Usuario SSH",
        "Nº Serie",
        "Notas",
    ])
    ws_devs.append([
        "RK001_M",
        18,
        2,
        "FRONT",
        "SRV-HP-09",
        "Nodo Virtualización Proxmox 09",
        "Host - HP",
        "HPE",
        "ProLiant DL380 Gen11 24SFF",
        "pve09",
        "pve09.hq.rackdoc.local",
        "10.28.0.59",
        "255.255.255.0",
        "10.28.0.1",
        10,
        "SI",
        "https",
        8006,
        "https://10.28.0.59:8006/api2/json/version",
        "root",
        "CZ24090099",
        "Importado desde plantilla Excel",
    ])
    ws_devs.append([
        "RK005_NEW",
        40,
        1,
        "FRONT",
        "SW-TOR-05",
        "Switch Top of Rack 48p",
        "Network",
        "Cisco",
        "Catalyst 9300-48P",
        "sw-tor-05",
        "sw-tor-05.hq.rackdoc.local",
        "10.28.0.105",
        "255.255.255.0",
        "10.28.0.1",
        10,
        "SI",
        "ssh",
        22,
        "",
        "admin",
        "FCW2345L099",
        "Switch principal del nuevo rack",
    ])
    ws_devs.append([
        "RK005_NEW",
        20,
        2,
        "FRONT",
        "SRV-SM-01",
        "Storage Server ZFS",
        "Host - Supermicro",
        "Supermicro",
        "SuperServer 2U Hyper SYS-221H-TNR (8x NVMe)",
        "zfs-sm-01",
        "zfs01.hq.rackdoc.local",
        "10.28.0.120",
        "255.255.255.0",
        "10.28.0.1",
        20,
        "SI",
        "icmp",
        22,
        "",
        "admin",
        "SM20269911",
        "Servidor Supermicro importado por Excel",
    ])
    _style_worksheet(ws_devs)

    # Hoja 3: Instrucciones
    ws_help = wb.create_sheet(title="3_Instrucciones_y_Librerias")
    ws_help.append(["Campo / Columna", "Descripción y Valores Permitidos", "Ejemplo"])
    ws_help.append([
        "1_Racks_y_Sedes",
        "Si el Código Rack no existe, RackDoc crea automáticamente la Sede, Planta, Sala y el Rack (con sus 2 tomas eléctricas exteriores).",
        "RK005_NEW",
    ])
    ws_help.append([
        "Código Rack",
        "Código del Rack donde se montará el equipo (ej. RK001_M, RK003_B, RK005_NEW).",
        "RK001_M",
    ])
    ws_help.append([
        "Unidad U Inicial",
        "Posición U inferior donde empieza el equipo (1 a 42). También acepta formato 'U18' o 'U18-U19'.",
        "18",
    ])
    ws_help.append([
        "Librería",
        "Network | Power | Host - HP | Host - Dell | Host - Supermicro | Organizers",
        "Host - HP",
    ])
    ws_help.append([
        "Heartbeat Activo",
        "SI / TRUE / 1 para activar la monitorización en verde/rojo del equipo.",
        "SI",
    ])
    ws_help.append([
        "Método Heartbeat",
        "icmp | ssh | https | http | tcp | snmp",
        "https",
    ])
    ws_help.append([
        "Compatibilidad Exportación",
        "También puedes modificar y volver a importar directamente el archivo Excel descargado desde 'Descargar Inventario Completo (.xlsx)'.",
        "RackDoc_Inventory.xlsx",
    ])
    _style_worksheet(ws_help)

    output = BytesIO()
    wb.save(output)
    output.seek(0)
    return output


def _parse_start_u(val: Any) -> int:
    if val is None:
        return 1
    if isinstance(val, (int, float)):
        return max(1, int(val))
    s = str(val).strip().upper()
    m = re.search(r"(\d+)", s)
    return max(1, int(m.group(1))) if m else 1


def import_datacenter_excel(db: Session, file_bytes: bytes) -> Dict[str, Any]:
    """
    Importa datos desde un fichero Excel (.xlsx) siguiendo la Plantilla de Ejemplo
    o el propio formato exportado por RackDoc ('Racks y Pasillos' + 'Hardware y Red').
    """
    wb = load_workbook(filename=BytesIO(file_bytes), data_only=True)

    racks_created = 0
    racks_updated = 0
    devices_created = 0
    devices_updated = 0
    warnings = []

    # 1. Procesar hoja de Racks si existe ('1_Racks_y_Sedes' o 'Racks y Pasillos')
    rack_sheet = None
    for name in ("1_Racks_y_Sedes", "Racks y Pasillos"):
        if name in wb.sheetnames:
            rack_sheet = wb[name]
            break

    if rack_sheet is not None:
        rows = list(rack_sheet.iter_rows(values_only=True))
        if len(rows) > 1:
            headers = [str(h or "").strip().lower() for h in rows[0]]

            def col_val(row_tuple, *candidates) -> str:
                for c in candidates:
                    for idx, h in enumerate(headers):
                        if c in h and idx < len(row_tuple):
                            v = row_tuple[idx]
                            return "" if v is None else str(v).strip()
                return ""

            for r_idx, row in enumerate(rows[1:], start=2):
                rack_code = col_val(row, "código rack", "codigo rack")
                if not rack_code:
                    continue
                loc_code = col_val(row, "sede (código)", "sede (codigo)") or "HQ"
                loc_name = col_val(row, "sede (nombre)") or loc_code
                floor_name = col_val(row, "planta") or "Planta Principal"
                room_name = col_val(row, "sala") or "Sala Servidores"
                aisle_name = col_val(row, "pasillo") or "Pasillo General"
                rack_name = col_val(row, "nombre rack") or rack_code
                u_str = col_val(row, "u totales")
                total_u = int(float(u_str)) if u_str.replace(".", "", 1).isdigit() else 42
                manuf = col_val(row, "fabricante") or "Rittal"
                model = col_val(row, "modelo") or "VX IT 42U"
                resp = col_val(row, "responsable")
                notes = col_val(row, "notas")

                loc = db.query(Location).filter(Location.code == loc_code).first()
                if not loc:
                    loc = Location(code=loc_code, name=loc_name, latitude=40.4168, longitude=-3.7038)
                    db.add(loc)
                    db.flush()

                fl = (
                    db.query(Floor)
                    .filter(Floor.location_id == loc.id, Floor.name == floor_name)
                    .first()
                )
                if not fl:
                    fl = Floor(location_id=loc.id, name=floor_name, level_number=1)
                    db.add(fl)
                    db.flush()

                rm = (
                    db.query(Room)
                    .filter(Room.floor_id == fl.id, Room.name == room_name)
                    .first()
                )
                if not rm:
                    rm = Room(floor_id=fl.id, name=room_name)
                    db.add(rm)
                    db.flush()

                aisle = (
                    db.query(Aisle)
                    .filter(Aisle.room_id == rm.id, Aisle.name == aisle_name)
                    .first()
                )
                if not aisle:
                    aisle = Aisle(room_id=rm.id, code=aisle_name[:8].upper(), name=aisle_name)
                    db.add(aisle)
                    db.flush()

                rk = db.query(Rack).filter(Rack.code == rack_code).first()
                if not rk:
                    rk = Rack(
                        room_id=rm.id,
                        aisle_id=aisle.id,
                        code=rack_code,
                        name=rack_name,
                        total_units=total_u,
                        manufacturer=manuf,
                        model_name=model,
                        responsible_person=resp,
                        notes=notes,
                    )
                    db.add(rk)
                    db.flush()
                    ensure_rack_external_outlets(db, rk)
                    racks_created += 1
                else:
                    rk.name = rack_name or rk.name
                    rk.total_units = total_u or rk.total_units
                    if manuf:
                        rk.manufacturer = manuf
                    if model:
                        rk.model_name = model
                    if resp:
                        rk.responsible_person = resp
                    if notes:
                        rk.notes = notes
                    racks_updated += 1

    # 2. Procesar hoja de Equipos ('2_Equipos_y_Hosts' o 'Hardware y Red')
    dev_sheet = None
    for name in ("2_Equipos_y_Hosts", "Hardware y Red"):
        if name in wb.sheetnames:
            dev_sheet = wb[name]
            break
    if dev_sheet is None and len(wb.sheetnames) == 1:
        dev_sheet = wb[wb.sheetnames[0]]

    if dev_sheet is not None:
        rows = list(dev_sheet.iter_rows(values_only=True))
        if len(rows) > 1:
            headers = [str(h or "").strip().lower() for h in rows[0]]

            def d_val(row_tuple, *candidates) -> str:
                for c in candidates:
                    for idx, h in enumerate(headers):
                        if c == h or c in h:
                            if idx < len(row_tuple):
                                v = row_tuple[idx]
                                return "" if v is None else str(v).strip()
                return ""

            for r_idx, row in enumerate(rows[1:], start=2):
                rack_code = d_val(row, "código rack", "codigo rack", "rack")
                dev_code = d_val(row, "código equipo", "codigo equipo", "código", "codigo")
                if not rack_code or not dev_code:
                    continue

                rk = db.query(Rack).filter(Rack.code == rack_code).first()
                if not rk:
                    # Crear el Rack en la primera sala disponible si aún no existe
                    first_room = db.query(Room).first()
                    if not first_room:
                        warnings.append(f"Fila {r_idx}: No existe sala para crear el rack {rack_code}.")
                        continue
                    rk = Rack(
                        room_id=first_room.id,
                        code=rack_code,
                        name=rack_code,
                        total_units=42,
                        manufacturer="Rittal",
                        model_name="VX IT 42U",
                    )
                    db.add(rk)
                    db.flush()
                    ensure_rack_external_outlets(db, rk)
                    racks_created += 1

                start_u = _parse_start_u(d_val(row, "unidad u inicial", "unidad u", "start_u"))
                u_height_str = d_val(row, "altura (u)", "u_height")
                u_height = int(float(u_height_str)) if u_height_str.replace(".", "", 1).isdigit() else 1
                face_raw = (d_val(row, "cara montaje", "face") or "FRONT").lower()
                mounted_face = "back" if "back" in face_raw or "tras" in face_raw else "front"

                dev_name = d_val(row, "nombre dispositivo", "nombre") or dev_code
                lib_group = d_val(row, "librería", "libreria", "categoría", "categoria") or "Host - HP"
                manuf = d_val(row, "fabricante") or "Generic"
                model_name = d_val(row, "modelo", "fabricante / modelo") or dev_name

                # Buscar o crear plantilla DeviceTemplate
                tpl = (
                    db.query(DeviceTemplate)
                    .filter(DeviceTemplate.model_name.ilike(f"%{model_name}%"))
                    .first()
                )
                if not tpl:
                    cat = "server"
                    lg_low = lib_group.lower()
                    if "net" in lg_low or "sw" in dev_code.lower():
                        cat = "switch"
                        lib_group = "Network"
                    elif "pow" in lg_low or "pdu" in dev_code.lower():
                        cat = "pdu"
                        lib_group = "Power"
                    elif "dell" in lg_low:
                        lib_group = "Host - Dell"
                    elif "super" in lg_low:
                        lib_group = "Host - Supermicro"
                    elif "hp" in lg_low:
                        lib_group = "Host - HP"

                    tpl = DeviceTemplate(
                        category=cat,
                        library_group=lib_group,
                        manufacturer=manuf,
                        model_name=model_name,
                        u_height=max(1, u_height),
                        is_full_depth=(cat in ("server", "switch", "ups", "firewall")),
                        default_color="#1E293B" if cat == "server" else "#F8FAFC",
                        layout_spec={
                            "port_groups": [
                                {
                                    "port_type": "rj45",
                                    "prefix": "GE",
                                    "count": 4,
                                    "rows": 1,
                                    "start_x": 0.55,
                                    "end_x": 0.78,
                                },
                                {
                                    "port_type": "power_c13",
                                    "prefix": "PSU",
                                    "count": 2,
                                    "rows": 1,
                                    "start_x": 0.84,
                                    "end_x": 0.94,
                                },
                            ],
                            "back_port_groups": [
                                {
                                    "port_type": "rj45",
                                    "prefix": "ETH",
                                    "count": 4,
                                    "rows": 1,
                                    "start_x": 0.45,
                                    "end_x": 0.70,
                                },
                                {
                                    "port_type": "power_c13",
                                    "prefix": "PSU-B",
                                    "count": 2,
                                    "rows": 1,
                                    "start_x": 0.80,
                                    "end_x": 0.94,
                                },
                            ],
                        },
                    )
                    db.add(tpl)
                    db.flush()

                hostname = d_val(row, "hostname")
                fqdn = d_val(row, "fqdn")
                ip_addr = d_val(row, "dirección ip", "direccion ip", "ip")
                mask = d_val(row, "máscara", "mascara") or "255.255.255.0"
                gw = d_val(row, "gateway")
                vlan_str = d_val(row, "vlan")
                vlan_mgmt = int(float(vlan_str)) if vlan_str.replace(".", "", 1).isdigit() else None
                serial = d_val(row, "nº serie", "serie")
                notes = d_val(row, "notas")

                hb_active_raw = d_val(row, "heartbeat activo", "estado ping").upper()
                hb_enabled = hb_active_raw in ("SI", "SÍ", "YES", "TRUE", "1", "ONLINE", "OFFLINE")
                hb_method = (d_val(row, "método heartbeat", "metodo heartbeat") or "icmp").lower()
                if hb_method not in ("icmp", "ssh", "https", "http", "tcp", "snmp"):
                    hb_method = "icmp"
                hb_port_str = d_val(row, "puerto heartbeat")
                hb_port = int(float(hb_port_str)) if hb_port_str.replace(".", "", 1).isdigit() else 22
                hb_url = d_val(row, "url extra heartbeat")
                ssh_user = d_val(row, "usuario ssh") or "admin"

                existing_dev = (
                    db.query(RackDevice)
                    .filter(RackDevice.rack_id == rk.id, RackDevice.code == dev_code)
                    .first()
                )
                hb_cfg = {
                    "url": hb_url or "/",
                    "path": hb_url or "/",
                    "expected_status": 200,
                    "ssh_user": ssh_user,
                    "ssh_extra_args": "-o StrictHostKeyChecking=no",
                    "snmp_community": "public",
                    "snmp_oid": "1.3.6.1.2.1.1.1.0",
                    "secondary_methods": [],
                    "simulate_offline": False,
                }

                if existing_dev:
                    existing_dev.name = dev_name
                    existing_dev.start_u = start_u
                    existing_dev.mounted_face = mounted_face
                    existing_dev.hostname = hostname or existing_dev.hostname
                    existing_dev.fqdn = fqdn or existing_dev.fqdn
                    existing_dev.ip_address = ip_addr or existing_dev.ip_address
                    existing_dev.subnet_mask = mask or existing_dev.subnet_mask
                    existing_dev.gateway = gw or existing_dev.gateway
                    if vlan_mgmt is not None:
                        existing_dev.vlan_mgmt = vlan_mgmt
                    existing_dev.monitoring_enabled = hb_enabled
                    existing_dev.monitor_method = hb_method
                    existing_dev.monitor_port = hb_port
                    if hb_enabled and existing_dev.status == "unknown":
                        existing_dev.status = "online"
                    existing_dev.serial_number = serial or existing_dev.serial_number
                    existing_dev.notes = notes or existing_dev.notes
                    cf = dict(existing_dev.custom_fields or {})
                    cf["heartbeat_config"] = hb_cfg
                    existing_dev.custom_fields = cf
                    devices_updated += 1
                else:
                    new_dev = RackDevice(
                        rack_id=rk.id,
                        template_id=tpl.id,
                        code=dev_code,
                        name=dev_name,
                        hostname=hostname,
                        fqdn=fqdn,
                        start_u=start_u,
                        mounted_face=mounted_face,
                        ip_address=ip_addr,
                        subnet_mask=mask,
                        gateway=gw,
                        vlan_mgmt=vlan_mgmt,
                        management_links=[
                            {"protocol": "ssh", "port": 22, "username": ssh_user, "label": "SSH"},
                            {"protocol": "https", "port": 443, "username": ssh_user, "label": "Web UI"},
                        ],
                        monitoring_enabled=hb_enabled,
                        monitor_method=hb_method,
                        monitor_port=hb_port,
                        status="online" if hb_enabled else "unknown",
                        last_ping_ms=1.2 if hb_enabled else None,
                        serial_number=serial,
                        custom_fields={"heartbeat_config": hb_cfg},
                        notes=notes,
                    )
                    db.add(new_dev)
                    db.flush()
                    create_ports_from_template(db, new_dev, tpl)
                    devices_created += 1

    db.commit()
    return {
        "racks_created": racks_created,
        "racks_updated": racks_updated,
        "devices_created": devices_created,
        "devices_updated": devices_updated,
        "warnings": warnings,
    }
