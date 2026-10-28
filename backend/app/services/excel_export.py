from io import BytesIO
import json
from typing import Optional
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter
from sqlalchemy.orm import Session
from ..models import Location, Floor, Room, Aisle, Rack, RackDevice, Connection, Port


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
