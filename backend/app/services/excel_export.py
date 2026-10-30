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
    FloorDevice,
)
from ..seed import create_ports_from_template, ensure_rack_external_outlets


FLOOR_DEVICE_TYPE_LABELS: Dict[str, str] = {
    "telecom_outlet": "Roseta RJ45 / Toma Pared",
    "camera": "Cámara CCTV IP",
    "access_control": "Control de Acceso Biométrico/RFID",
    "access_point": "Punto de Acceso Wi-Fi",
    "desktop": "Ordenador / Workstation PC",
    "laptop": "Portátil Corporativo",
    "phone": "Teléfono IP VoIP",
    "printer": "Impresora Multifunción de Red",
    "3d_printer": "Impresora 3D Industrial",
    "screen": "Pantalla / Videowall",
    "speaker": "Altavoz / Megafonía IP",
    "microphone": "Micrófono Sala IP",
    "ndi_box": "Codificador Vídeo NDI",
    "isp_uplink": "Acometida Operador ISP",
    "sensor_temp": "Sonda Temperatura (°C)",
    "sensor_humidity": "Sensor Humedad (%RH)",
    "sensor_power_load": "Analizador Carga Eléctrica (kW/A)",
    "sensor_smoke": "Detector Humo / Incendio",
    "sensor_water_leak": "Sensor Fuga de Agua",
    "custom_crac": "Climatizador CRAC / InRow",
    "custom_elec_board": "Cuadro Eléctrico General",
}

ACTIVE_HW_CATEGORIES = {
    "switch",
    "san_switch",
    "router",
    "firewall",
    "server",
    "storage_san",
    "storage_nas",
    "ups",
    "pdu",
    "roof_fan",
    "rack_tray_device",
}

PATCH_PANEL_CATEGORIES = {
    "patch_panel",
    "gateway",
    "patchbox",
}


def _category_display_info(cat: str, dev_name: str = "", dev_code: str = "") -> tuple[bool, str, str]:
    """
    Devuelve (is_active_hardware, kind_group, badge_label) para diferenciar claramente
    entre 'Hierro' (Switches, Routers, Firewalls, Servidores, Cabinas, SAI, PDU) y
    'Patch Panels / Elementos Pasivos' de cada línea del Rack.
    """
    c = (cat or "").strip().lower()
    code_up = (dev_code or "").strip().upper()
    name_low = (dev_name or "").strip().lower()

    if c in ("switch", "san_switch"):
        return True, "hierro", "HIERRO • SWITCH"
    if c == "router":
        return True, "hierro", "HIERRO • ROUTER"
    if c == "firewall":
        return True, "hierro", "HIERRO • FIREWALL"
    if c == "server":
        return True, "hierro", "HIERRO • SERVIDOR / HOST"
    if c == "storage_san":
        return True, "hierro", "HIERRO • CABINA SAN"
    if c == "storage_nas":
        return True, "hierro", "HIERRO • CABINA NAS"
    if c == "ups":
        return True, "hierro", "HIERRO • SAI / UPS"
    if c == "pdu":
        return True, "hierro", "HIERRO • PDU ELÉCTRICA"
    if c == "roof_fan":
        return True, "hierro", "HIERRO • VENTILADOR TECHO"
    if c == "rack_tray_device":
        return True, "hierro", "HIERRO • EQUIPO EN BANDEJA"
    if c == "patch_panel":
        return False, "patch_panel", "PATCH PANEL • COBRE RJ45"
    if c == "patchbox":
        return False, "patch_panel", "PATCHBOX • CASETES"
    if c == "gateway":
        if code_up.startswith(("FI", "ODF")) or "bandeja" in name_low or "patch panel" in name_low or "fibra" in name_low:
            return False, "patch_panel", "PATCH PANEL • BANDEJA FIBRA (ODF)"
        return True, "hierro", "HIERRO • GATEWAY FIBRA"
    if c == "cable_manager":
        return False, "pasivo", "PASIVO • PASACABLES 1U"
    if c == "rack_tray":
        return False, "pasivo", "PASIVO • BANDEJA FIJA"
    return False, "pasivo", f"PASIVO • {c.upper() or 'ACCESORIO'}"


def _extract_slot_number(port_number: str) -> Optional[int]:
    if not port_number:
        return None
    m = re.search(r"(\d+)$", str(port_number).strip())
    if m:
        return int(m.group(1))
    m2 = re.search(r"(\d+)", str(port_number).strip())
    return int(m2.group(1)) if m2 else None


def _parse_linked_rack_target(raw_code: str) -> Optional[tuple[str, int, int]]:
    """
    Parsea cadenas como 'PP-A:01-04', 'PP-A:01', 'A:1', 'PBX01:2', 'SW01:Gi1/0/21 (PoE)'
    y devuelve (device_code_normalized, start_port, end_port).
    """
    if not raw_code or ":" not in raw_code:
        return None
    left, right = raw_code.split(":", 1)
    dev_code = left.strip().upper()
    if dev_code.startswith("PP-") and len(dev_code) > 3:
        dev_code = dev_code[3:]
    right_clean = right.split("(")[0].strip()
    m_range = re.search(r"(\d+)\s*-\s*(\d+)", right_clean)
    if m_range:
        p1, p2 = int(m_range.group(1)), int(m_range.group(2))
        return dev_code, min(p1, p2), max(p1, p2)
    m_last = re.search(r"(\d+)\s*$", right_clean)
    if m_last:
        p = int(m_last.group(1))
        return dev_code, p, p
    m_any = re.search(r"(\d+)", right_clean)
    if m_any:
        p = int(m_any.group(1))
        return dev_code, p, p
    return None


def build_dashboard_inventory_data(
    db: Session,
    location_id: Optional[int] = None,
    rack_id: Optional[int] = None,
) -> Dict[str, Any]:
    """
    Construye el inventario detallado para '4. Dashboard & Excel' y la exportación Excel:
    1) 'rack_lines': Línea a línea de cada Rack (U42..U1), diferenciando claramente 'Hierro'
       (Switches, Routers, Firewalls, Servidores, SAN/NAS, SAI, PDU) de 'Patch Panels / Pasivos'.
    2) 'patch_panels': Todos los Patch Panels / Bandejas de Fibra / Patchboxes con sus 24 bocas
       (1..24), indicando si cada boca está OCUPADA o LIBRE, a qué Switch/Hierro va conectada
       y qué Aparato final tiene conectado (código, nombre, tipo de aparato, IP, sala y estado).
    """
    racks_q = db.query(Rack).join(Room).join(Floor).join(Location)
    if location_id is not None:
        racks_q = racks_q.filter(Location.id == location_id)
    if rack_id is not None:
        racks_q = racks_q.filter(Rack.id == rack_id)

    racks = racks_q.order_by(Location.id, Floor.level_number, Rack.id).all()
    rack_ids = {r.id for r in racks}

    all_conns = db.query(Connection).all()
    conns_by_port_id: Dict[int, list[Connection]] = {}
    for c in all_conns:
        conns_by_port_id.setdefault(c.source_port_id, []).append(c)
        conns_by_port_id.setdefault(c.target_port_id, []).append(c)

    all_floor_devs = db.query(FloorDevice).order_by(FloorDevice.id).all()
    floor_dev_by_id: Dict[int, FloorDevice] = {fd.id: fd for fd in all_floor_devs}
    children_by_outlet_id: Dict[int, list[FloorDevice]] = {}
    for fd in all_floor_devs:
        if fd.linked_outlet_id:
            children_by_outlet_id.setdefault(fd.linked_outlet_id, []).append(fd)

    rack_lines: list[Dict[str, Any]] = []
    patch_panels: list[Dict[str, Any]] = []

    for r in racks:
        room = r.room
        floor = room.floor if room else None
        loc = floor.location if floor else None
        aisle = r.aisle

        mounted_devices = [
            d for d in r.devices if (d.mounted_face or "front").lower() != "external"
        ]
        mounted_devices.sort(
            key=lambda d: (
                d.start_u,
                1 if (d.mounted_face or "front").lower() == "front" else 0,
            ),
            reverse=True,
        )

        # Mapa de switches del rack para resolver puentes vía Patchbox (PBX01->SW01, PBX02->SW02, PBX03->SW03)
        rack_switches = [
            d
            for d in mounted_devices
            if d.template and (d.template.category or "").lower() in ("switch", "router", "firewall")
        ]

        def _find_paired_switch_for_patchbox(pbx_dev: RackDevice) -> Optional[RackDevice]:
            pbx_num = _extract_slot_number(pbx_dev.code)
            if pbx_num is not None:
                for sw in rack_switches:
                    if sw.code.upper() == f"SW0{pbx_num}" or sw.code.upper() == f"SW{pbx_num}":
                        return sw
            # Si no coincide por número, buscar el switch más cercano en U
            closest = None
            min_dist = 999
            for sw in rack_switches:
                dist = abs(sw.start_u - pbx_dev.start_u)
                if dist < min_dist:
                    min_dist = dist
                    closest = sw
            return closest

        # Indexar FloorDevices vinculados a este Rack o a la misma Planta
        rack_floor_devs = [
            fd
            for fd in all_floor_devs
            if fd.linked_rack_id == r.id
            or (fd.linked_rack_id is None and floor and fd.floor_id == floor.id)
        ]

        # Mapa (dev_code_upper, slot_num) -> list[tuple[FloorDevice, Optional[FloorDevice]]]
        # donde cada tupla es (endpoint_fd, via_outlet_fd)
        direct_fd_map: Dict[tuple[str, int], list[tuple[FloorDevice, Optional[FloorDevice]]]] = {}
        for fd in rack_floor_devs:
            parsed = _parse_linked_rack_target(fd.linked_rack_device_code or "")
            if not parsed:
                continue
            target_code, p_start, p_end = parsed
            if fd.device_type == "telecom_outlet":
                outlet_children = children_by_outlet_id.get(fd.id, [])
                for idx, p_num in enumerate(range(p_start, p_end + 1)):
                    if idx < len(outlet_children):
                        direct_fd_map.setdefault((target_code, p_num), []).append(
                            (outlet_children[idx], fd)
                        )
                    else:
                        direct_fd_map.setdefault((target_code, p_num), []).append((fd, None))
            else:
                for p_num in range(p_start, p_end + 1):
                    outlet_parent = (
                        floor_dev_by_id.get(fd.linked_outlet_id)
                        if fd.linked_outlet_id
                        else None
                    )
                    direct_fd_map.setdefault((target_code, p_num), []).append(
                        (fd, outlet_parent)
                    )

        # Además, para que las rosetas clásicas de la planta (GOA Bi01..04 -> A:1..4, OSLO Bi05..08 -> A:5..8,
        # VIENNA Bi09..12 -> B:1..4) siempre conserven su trazabilidad hacia Patch Panel A y B en el Rack 1:
        for fd in all_floor_devs:
            if fd.device_type == "telecom_outlet" and (
                fd.linked_rack_id == r.id or r.code == "RK001_M"
            ):
                code_up = (fd.code or "").upper()
                outlet_children = children_by_outlet_id.get(fd.id, [])
                fallback_range: Optional[tuple[str, int, int]] = None
                if "BI01" in code_up:
                    fallback_range = ("A", 1, 4)
                elif "BI05" in code_up:
                    fallback_range = ("A", 5, 8)
                elif "BI09" in code_up:
                    fallback_range = ("B", 1, 4)
                if fallback_range:
                    t_code, s_p, e_p = fallback_range
                    for idx, p_num in enumerate(range(s_p, e_p + 1)):
                        if not direct_fd_map.get((t_code, p_num)):
                            if idx < len(outlet_children):
                                direct_fd_map.setdefault((t_code, p_num), []).append(
                                    (outlet_children[idx], fd)
                                )
                            else:
                                direct_fd_map.setdefault((t_code, p_num), []).append(
                                    (fd, None)
                                )

        # 1) Construir líneas del Rack (Hierro y Pasivos)
        for d in mounted_devices:
            tpl = d.template
            cat = (tpl.category if tpl else "server").lower()
            cf = d.custom_fields or {}
            u_height = int(cf.get("u_height_override") or (tpl.u_height if tpl else 1))
            end_u = d.start_u + u_height - 1
            u_range = f"U{d.start_u}" if end_u == d.start_u else f"U{d.start_u}-U{end_u}"

            is_active_hw, kind_group, badge_label = _category_display_info(
                cat, d.name, d.code
            )
            if d.ip_address and d.ip_address.strip() and kind_group == "pasivo":
                is_active_hw = True

            data_ports = [
                p
                for p in d.ports
                if not (p.port_type or "").lower().startswith("power")
                and (p.port_type or "").lower() != "passthrough"
            ]
            if not data_ports:
                data_ports = list(d.ports)

            # Si es patch_panel o patchbox con front+back duplicados (1..24 y KR-1..KR-24),
            # contabilizar las bocas frontales como capacidad nominal (24 bocas)
            front_data_ports = [
                p for p in data_ports if (p.face or "front").lower() == "front"
            ]
            if cat in PATCH_PANEL_CATEGORIES and front_data_ports:
                nominal_total = len(front_data_ports)
                occupied_slots = set()
                for p in data_ports:
                    if conns_by_port_id.get(p.id):
                        sn = _extract_slot_number(p.port_number)
                        occupied_slots.add(sn if sn is not None else p.id)
                for (dc, sn), fds in direct_fd_map.items():
                    if dc == d.code.upper() and fds:
                        occupied_slots.add(sn)
                occupied_cnt = min(nominal_total, len(occupied_slots))
            else:
                nominal_total = len(data_ports)
                occupied_cnt = sum(
                    1 for p in data_ports if conns_by_port_id.get(p.id)
                )

            free_cnt = max(0, nominal_total - occupied_cnt)

            rack_lines.append(
                {
                    "device_id": d.id,
                    "rack_id": r.id,
                    "rack_code": r.code,
                    "rack_name": r.name,
                    "location_id": loc.id if loc else None,
                    "location_code": loc.code if loc else "",
                    "location_name": loc.name if loc else "",
                    "floor_name": floor.name if floor else "",
                    "room_name": room.name if room else "",
                    "aisle_name": aisle.name if aisle else "General",
                    "start_u": d.start_u,
                    "end_u": end_u,
                    "u_height": u_height,
                    "u_range": u_range,
                    "mounted_face": (d.mounted_face or "front").upper(),
                    "is_full_depth": bool(tpl and tpl.is_full_depth),
                    "code": d.code,
                    "name": d.name,
                    "category": cat,
                    "is_active_hardware": is_active_hw,
                    "kind_group": kind_group,  # 'hierro' | 'patch_panel' | 'pasivo'
                    "equipment_type_badge": badge_label,
                    "manufacturer": tpl.manufacturer if tpl else "",
                    "model_name": tpl.model_name if tpl else "",
                    "hostname": d.hostname or "",
                    "fqdn": d.fqdn or "",
                    "ip_address": d.ip_address or "",
                    "subnet_mask": d.subnet_mask or "",
                    "gateway": d.gateway or "",
                    "vlan_mgmt": d.vlan_mgmt,
                    "mac_address": d.mac_address or "",
                    "status": (d.status or "unknown").lower(),
                    "monitoring_enabled": bool(d.monitoring_enabled),
                    "monitor_method": (d.monitor_method or "icmp").lower(),
                    "monitor_port": d.monitor_port or 22,
                    "last_ping_ms": d.last_ping_ms,
                    "last_checked_at": (
                        d.last_checked_at.strftime("%Y-%m-%d %H:%M:%S")
                        if d.last_checked_at
                        else ""
                    ),
                    "management_links": d.management_links or [],
                    "total_ports": nominal_total,
                    "occupied_ports": occupied_cnt,
                    "free_ports": free_cnt,
                    "serial_number": d.serial_number or "",
                    "custom_fields": cf,
                    "notes": d.notes or "",
                }
            )

        # 2) Construir el detalle Boca a Boca (1..24) de todos los Patch Panels / Bandejas de Fibra / Patchboxes
        for d in mounted_devices:
            tpl = d.template
            cat = (tpl.category if tpl else "").lower()
            if cat not in PATCH_PANEL_CATEGORIES:
                continue

            cf = d.custom_fields or {}
            u_height = int(cf.get("u_height_override") or (tpl.u_height if tpl else 1))
            end_u = d.start_u + u_height - 1
            u_range = f"U{d.start_u}" if end_u == d.start_u else f"U{d.start_u}-U{end_u}"

            # Agrupar puertos por número de boca (1..24)
            slot_ports: Dict[int, Dict[str, Port]] = {}
            for p in d.ports:
                if (p.port_type or "").lower().startswith("power"):
                    continue
                sn = _extract_slot_number(p.port_number)
                if sn is None:
                    continue
                face_key = "back" if (p.face or "front").lower() == "back" else "front"
                slot_ports.setdefault(sn, {})[face_key] = p

            max_slot = max(slot_ports.keys()) if slot_ports else 24
            total_slots = max(24, max_slot) if cat in ("patch_panel", "patchbox") else max_slot

            bocas_list: list[Dict[str, Any]] = []
            occupied_bocas_count = 0

            for slot_num in range(1, total_slots + 1):
                faces_dict = slot_ports.get(slot_num, {})
                front_p = faces_dict.get("front")
                back_p = faces_dict.get("back")
                primary_p = front_p or back_p

                port_label = (
                    front_p.port_number
                    if front_p
                    else (back_p.port_number if back_p else str(slot_num))
                )
                port_type = (
                    primary_p.port_type
                    if primary_p
                    else ("fiber_lc" if cat == "gateway" else "rj45")
                )

                # Recopilar todas las conexiones en front y back de esta boca
                slot_conns: list[tuple[Connection, Port, Port]] = []
                for p_obj in (front_p, back_p):
                    if not p_obj:
                        continue
                    for c in conns_by_port_id.get(p_obj.id, []):
                        other_p = (
                            c.target_port
                            if c.source_port_id == p_obj.id
                            else c.source_port
                        )
                        if other_p and other_p.device:
                            slot_conns.append((c, p_obj, other_p))

                # Resolver lado Switch / Hierro y lado Aparato / Dispositivo Conectado
                hw_info: Optional[Dict[str, Any]] = None
                endpoint_info: Optional[Dict[str, Any]] = None
                cable_labels: list[str] = []
                cable_vlan: Optional[int] = None
                cable_type_str = ""

                for c, my_p, other_p in slot_conns:
                    other_dev = other_p.device
                    other_tpl = other_dev.template
                    other_cat = (other_tpl.category if other_tpl else "").lower()
                    if c.label:
                        cable_labels.append(c.label)
                    if c.vlan and not cable_vlan:
                        cable_vlan = c.vlan
                    if c.cable_type and not cable_type_str:
                        cable_type_str = c.cable_type

                    # Caso A: Conectado a PLANTA-DC (Equipo de planta / Roseta / Cámara / Impresora / Sensor)
                    if (other_dev.mounted_face or "").lower() == "external":
                        feed_t = str((other_dev.custom_fields or {}).get("feed_type") or "")
                        if feed_t == "floor_devices":
                            # Extraer ID de FloorDevice de label="FD:<id>|..."
                            m_fd = re.match(r"^FD:(\d+)\|", str(other_p.label or ""))
                            fd_obj = (
                                floor_dev_by_id.get(int(m_fd.group(1)))
                                if m_fd
                                else None
                            )
                            if fd_obj:
                                if fd_obj.device_type == "telecom_outlet":
                                    ch_list = children_by_outlet_id.get(fd_obj.id, [])
                                    if ch_list:
                                        first_ch = ch_list[0]
                                        extra_names = (
                                            f" (+{len(ch_list) - 1} más)"
                                            if len(ch_list) > 1
                                            else ""
                                        )
                                        endpoint_info = {
                                            "code": f"{first_ch.code}{extra_names}",
                                            "name": f"{first_ch.name} (vía Roseta {fd_obj.code})",
                                            "device_type": first_ch.device_type,
                                            "device_type_label": FLOOR_DEVICE_TYPE_LABELS.get(
                                                first_ch.device_type,
                                                first_ch.device_type,
                                            ),
                                            "ip_address": first_ch.ip_address or "Sin IP",
                                            "room_code": first_ch.room_code or fd_obj.room_code or "",
                                            "status": (first_ch.status or "online").lower(),
                                            "vlan": first_ch.vlan or cable_vlan,
                                            "via_outlet": fd_obj.code,
                                        }
                                    else:
                                        endpoint_info = {
                                            "code": fd_obj.code,
                                            "name": fd_obj.name,
                                            "device_type": fd_obj.device_type,
                                            "device_type_label": FLOOR_DEVICE_TYPE_LABELS.get(
                                                fd_obj.device_type,
                                                "Roseta RJ45",
                                            ),
                                            "ip_address": fd_obj.ip_address or "Pasivo (Sin IP)",
                                            "room_code": fd_obj.room_code or "",
                                            "status": "passive",
                                            "vlan": fd_obj.vlan or cable_vlan,
                                            "via_outlet": fd_obj.code,
                                        }
                                else:
                                    endpoint_info = {
                                        "code": fd_obj.code,
                                        "name": fd_obj.name,
                                        "device_type": fd_obj.device_type,
                                        "device_type_label": FLOOR_DEVICE_TYPE_LABELS.get(
                                            fd_obj.device_type,
                                            fd_obj.device_type,
                                        ),
                                        "ip_address": fd_obj.ip_address or "Sin IP",
                                        "room_code": fd_obj.room_code or "",
                                        "status": (fd_obj.status or "online").lower(),
                                        "vlan": fd_obj.vlan or cable_vlan,
                                        "via_outlet": "",
                                    }
                        elif feed_t == "fiber":
                            endpoint_info = {
                                "code": other_dev.code,
                                "name": f"{other_dev.name} ({other_p.port_number})",
                                "device_type": "isp_uplink",
                                "device_type_label": "Acometida Fibra Exterior",
                                "ip_address": "Óptica Pasiva",
                                "room_code": "Acometida CPD",
                                "status": "online",
                                "vlan": cable_vlan,
                                "via_outlet": "",
                            }
                        continue

                    # Caso B: Conectado a un Switch / Router / Firewall / Servidor / Hierro activo
                    if other_cat in ACTIVE_HW_CATEGORIES:
                        hw_info = {
                            "device_id": other_dev.id,
                            "code": other_dev.code,
                            "name": other_dev.name,
                            "category": other_cat,
                            "port": other_p.port_number,
                            "face": (other_p.face or "front").upper(),
                            "ip_address": other_dev.ip_address or "",
                            "status": (other_dev.status or "unknown").lower(),
                            "rack_code": other_dev.rack.code if other_dev.rack else r.code,
                        }
                        # Ver si en ese puerto del Switch hay vinculado un FloorDevice (ej. SW01:Gi1/0/21)
                        other_sn = _extract_slot_number(other_p.port_number)
                        if other_sn is not None and not endpoint_info:
                            sw_fds = direct_fd_map.get((other_dev.code.upper(), other_sn), [])
                            if sw_fds:
                                f_dev, via_out = sw_fds[0]
                                endpoint_info = {
                                    "code": f_dev.code,
                                    "name": f_dev.name,
                                    "device_type": f_dev.device_type,
                                    "device_type_label": FLOOR_DEVICE_TYPE_LABELS.get(
                                        f_dev.device_type, f_dev.device_type
                                    ),
                                    "ip_address": f_dev.ip_address or "Sin IP",
                                    "room_code": f_dev.room_code or "",
                                    "status": (f_dev.status or "online").lower(),
                                    "vlan": f_dev.vlan or cable_vlan,
                                    "via_outlet": via_out.code if via_out else "",
                                }
                        continue

                    # Caso C: Conectado a un PATCHBOX (ej. A:1 <-> PBX01:1 o D:4 <-> PBX02:4) o a otro Patch Panel
                    if other_cat in PATCH_PANEL_CATEGORIES:
                        other_sn = _extract_slot_number(other_p.port_number) or slot_num
                        # Buscar si el otro Patchbox/Panel tiene otro cable en la misma boca hacia un Switch o Planta
                        traced_sw = None
                        for p2 in other_dev.ports:
                            if _extract_slot_number(p2.port_number) == other_sn and p2.id != other_p.id:
                                for c2 in conns_by_port_id.get(p2.id, []):
                                    hop_p = (
                                        c2.target_port
                                        if c2.source_port_id == p2.id
                                        else c2.source_port
                                    )
                                    if hop_p and hop_p.device and hop_p.device.id != d.id:
                                        hop_cat = (
                                            hop_p.device.template.category
                                            if hop_p.device.template
                                            else ""
                                        ).lower()
                                        if hop_cat in ACTIVE_HW_CATEGORIES:
                                            traced_sw = (hop_p.device, hop_p.port_number)
                        if not traced_sw and other_cat == "patchbox":
                            paired_sw = _find_paired_switch_for_patchbox(other_dev)
                            if paired_sw:
                                traced_sw = (paired_sw, str(other_sn))

                        if traced_sw and not hw_info:
                            sw_dev, sw_port_num = traced_sw
                            hw_info = {
                                "device_id": sw_dev.id,
                                "code": f"{sw_dev.code} (vía {other_dev.code})",
                                "name": f"{sw_dev.name} [Casete {other_dev.code}:{other_p.port_number}]",
                                "category": (
                                    sw_dev.template.category if sw_dev.template else "switch"
                                ),
                                "port": sw_port_num,
                                "face": "FRONT",
                                "ip_address": sw_dev.ip_address or "",
                                "status": (sw_dev.status or "unknown").lower(),
                                "rack_code": sw_dev.rack.code if sw_dev.rack else r.code,
                            }
                        elif not hw_info:
                            hw_info = {
                                "device_id": other_dev.id,
                                "code": other_dev.code,
                                "name": other_dev.name,
                                "category": other_cat,
                                "port": other_p.port_number,
                                "face": (other_p.face or "front").upper(),
                                "ip_address": other_dev.ip_address or "",
                                "status": (other_dev.status or "unknown").lower(),
                                "rack_code": other_dev.rack.code if other_dev.rack else r.code,
                            }

                        # Si el propio Patch Panel es un Patchbox (ej. PBX01) y el otro extremo es un Patch Panel (ej. A:1),
                        # también comprobamos si A:1 tiene un aparato de planta conectado:
                        if not endpoint_info:
                            other_fds = direct_fd_map.get((other_dev.code.upper(), other_sn), [])
                            if other_fds:
                                f_dev, via_out = other_fds[0]
                                endpoint_info = {
                                    "code": f_dev.code,
                                    "name": f"{f_dev.name} (vía Patch Panel {other_dev.code}:{other_p.port_number})",
                                    "device_type": f_dev.device_type,
                                    "device_type_label": FLOOR_DEVICE_TYPE_LABELS.get(
                                        f_dev.device_type, f_dev.device_type
                                    ),
                                    "ip_address": f_dev.ip_address or "Sin IP",
                                    "room_code": f_dev.room_code or "",
                                    "status": (f_dev.status or "online").lower(),
                                    "vlan": f_dev.vlan or cable_vlan,
                                    "via_outlet": via_out.code if via_out else f"PP-{other_dev.code}:{other_p.port_number}",
                                }

                # Caso D: Comprobar si hay un FloorDevice directamente asignado a (d.code, slot_num)
                if not endpoint_info:
                    my_fds = direct_fd_map.get((d.code.upper(), slot_num), [])
                    if my_fds:
                        f_dev, via_out = my_fds[0]
                        endpoint_info = {
                            "code": f_dev.code,
                            "name": (
                                f"{f_dev.name} (vía Roseta {via_out.code})"
                                if via_out
                                else f_dev.name
                            ),
                            "device_type": f_dev.device_type,
                            "device_type_label": FLOOR_DEVICE_TYPE_LABELS.get(
                                f_dev.device_type, f_dev.device_type
                            ),
                            "ip_address": f_dev.ip_address or "Pasivo (Sin IP)",
                            "room_code": f_dev.room_code or (via_out.room_code if via_out else ""),
                            "status": (f_dev.status or "online").lower(),
                            "vlan": f_dev.vlan or cable_vlan,
                            "via_outlet": via_out.code if via_out else "",
                        }
                        # Si esta boca de Patch Panel tiene un aparato de planta en back pero no latiguillo frontal explícito,
                        # pero existe un Patchbox/Switch asociado, mantener hw_info si existe

                # Caso E: Si no hay un FloorDevice separado pero sí hay un equipo activo conectado (ej. FI-01:F19 -> RAC27 ONT Nokia,
                # FI-01:F23 -> RT01 Core Router, PBX01:15 -> FW01 FortiGate) o circuito etiquetado:
                if not endpoint_info and (hw_info or cable_labels):
                    lbl_joined = " | ".join(dict.fromkeys(cable_labels))
                    if hw_info and hw_info.get("category") in (
                        "router",
                        "firewall",
                        "server",
                        "rack_tray_device",
                        "storage_san",
                        "storage_nas",
                    ):
                        endpoint_info = {
                            "code": hw_info["code"],
                            "name": hw_info["name"],
                            "device_type": hw_info["category"],
                            "device_type_label": f"Equipo Rack ({hw_info['category'].upper()})",
                            "ip_address": hw_info.get("ip_address") or "Sin IP",
                            "room_code": f"Rack {hw_info.get('rack_code', r.code)}",
                            "status": hw_info.get("status", "online"),
                            "vlan": cable_vlan,
                            "via_outlet": f"Puerto {hw_info.get('port', '')}",
                        }
                    elif lbl_joined:
                        endpoint_info = {
                            "code": f"TOMA-{d.code}{slot_num:02d}",
                            "name": lbl_joined,
                            "device_type": "telecom_outlet",
                            "device_type_label": "Circuito / Línea Cableada",
                            "ip_address": (
                                hw_info.get("ip_address")
                                if (hw_info and hw_info.get("ip_address"))
                                else "Asignación DHCP / VLAN"
                            ),
                            "room_code": room.name if room else "Planta",
                            "status": "online",
                            "vlan": cable_vlan,
                            "via_outlet": f"{d.code}:{port_label}",
                        }

                is_occupied = bool(slot_conns or hw_info or endpoint_info)
                if is_occupied:
                    occupied_bocas_count += 1

                bocas_list.append(
                    {
                        "slot_number": slot_num,
                        "port_label": port_label,
                        "port_type": port_type,
                        "is_occupied": is_occupied,
                        "status_text": "OCUPADA" if is_occupied else "LIBRE",
                        "cable_type": cable_type_str,
                        "cable_label": " | ".join(dict.fromkeys(cable_labels)),
                        "vlan": (
                            endpoint_info.get("vlan")
                            if (endpoint_info and endpoint_info.get("vlan"))
                            else cable_vlan
                        ),
                        "switch_hardware": hw_info,
                        "connected_device": endpoint_info,
                    }
                )

            patch_panels.append(
                {
                    "device_id": d.id,
                    "rack_id": r.id,
                    "rack_code": r.code,
                    "rack_name": r.name,
                    "location_id": loc.id if loc else None,
                    "location_code": loc.code if loc else "",
                    "location_name": loc.name if loc else "",
                    "floor_name": floor.name if floor else "",
                    "room_name": room.name if room else "",
                    "start_u": d.start_u,
                    "u_range": u_range,
                    "code": d.code,
                    "name": d.name,
                    "category": cat,
                    "equipment_type_badge": _category_display_info(cat, d.name, d.code)[2],
                    "manufacturer": tpl.manufacturer if tpl else "",
                    "model_name": tpl.model_name if tpl else "",
                    "ip_address": d.ip_address or "",
                    "total_bocas": total_slots,
                    "occupied_bocas": occupied_bocas_count,
                    "free_bocas": max(0, total_slots - occupied_bocas_count),
                    "bocas": bocas_list,
                }
            )

    active_hw_lines = [ln for ln in rack_lines if ln["kind_group"] == "hierro"]
    passive_lines = [ln for ln in rack_lines if ln["kind_group"] != "hierro"]
    total_pp_bocas = sum(pp["total_bocas"] for pp in patch_panels)
    occupied_pp_bocas = sum(pp["occupied_bocas"] for pp in patch_panels)

    return {
        "summary": {
            "racks_count": len(racks),
            "total_rack_lines": len(rack_lines),
            "active_hierro_count": len(active_hw_lines),
            "passive_lines_count": len(passive_lines),
            "patch_panels_count": len(patch_panels),
            "total_patch_panel_bocas": total_pp_bocas,
            "occupied_patch_panel_bocas": occupied_pp_bocas,
            "free_patch_panel_bocas": max(0, total_pp_bocas - occupied_pp_bocas),
        },
        "rack_lines": rack_lines,
        "patch_panels": patch_panels,
    }



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
    Genera un informe Excel (.xlsx) completo con 4 hojas diferenciadas:
    1. Racks y Pasillos (Ubicaciones, Plantas, Salas, Pasillos y Racks con desglose Hierro vs Pasivos)
    2. Hardware y Red (Línea a Línea del Rack U42..U1 diferenciando 'HIERRO' activo vs 'PATCH PANEL / PASIVO')
    3. Patch Panels (Bocas 1-24) (Detalle boca por boca 1..24 de cada Patch Panel: OCUPADA o LIBRE, Switch/Hierro y Aparato conectado con su IP y tipo)
    4. Mapa de Cableado (Red, Fibra, Planta y Electricidad en Front y Back)
    """
    inv = build_dashboard_inventory_data(db=db, location_id=location_id, rack_id=rack_id)
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
        "Equipos Hierro (Activos)",
        "Patch Panels / Pasivos",
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
        r_lines = [ln for ln in inv["rack_lines"] if ln["rack_id"] == r.id]
        hierro_cnt = sum(1 for ln in r_lines if ln["kind_group"] == "hierro")
        pasivo_cnt = sum(1 for ln in r_lines if ln["kind_group"] != "hierro")
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
            hierro_cnt,
            pasivo_cnt,
            r.manufacturer,
            r.model_name,
            r.serial_number,
            r.responsible_person,
            r.operation_start,
            r.notes,
        ])
    _style_worksheet(ws_racks)

    # 2. Hoja de Hardware y Red (Línea a Línea del Rack: Hierro vs Pasivos)
    ws_devs = wb.create_sheet(title="Hardware y Red")
    ws_devs.append([
        "Rack",
        "Pasillo",
        "Unidad U",
        "Altura (U)",
        "Cara Montaje",
        "Tipo en Rack (Hierro / Pasivo)",
        "Código",
        "Nombre Dispositivo",
        "Categoría",
        "Fabricante / Modelo",
        "Bocas Ocupadas / Totales",
        "Bocas Libres",
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

    for ln in inv["rack_lines"]:
        links_str = ", ".join(
            f"{lnk.get('protocol', '').upper()}:{lnk.get('port', '')}"
            for lnk in (ln.get("management_links") or [])
        )
        custom_str = (
            json.dumps(ln["custom_fields"], ensure_ascii=False)
            if ln.get("custom_fields")
            else ""
        )
        ws_devs.append([
            ln["rack_code"],
            ln["aisle_name"],
            ln["u_range"],
            ln["u_height"],
            ln["mounted_face"],
            ln["equipment_type_badge"],
            ln["code"],
            ln["name"],
            ln["category"],
            f"{ln['manufacturer']} {ln['model_name']}".strip(),
            f"{ln['occupied_ports']} / {ln['total_ports']}",
            ln["free_ports"],
            ln["hostname"],
            ln["fqdn"],
            ln["ip_address"] or ("—" if ln["kind_group"] != "hierro" else "Sin IP"),
            ln["subnet_mask"],
            ln["gateway"],
            ln["vlan_mgmt"] or "",
            ln["mac_address"],
            links_str,
            ln["status"].upper() if ln["kind_group"] == "hierro" else "PASIVO",
            ln["last_ping_ms"] if ln["last_ping_ms"] is not None else "",
            ln["last_checked_at"],
            ln["serial_number"],
            custom_str,
            ln["notes"],
        ])
    _style_worksheet(ws_devs)

    # 3. Hoja de Patch Panels — Detalle Boca por Boca (1 a 24)
    ws_pp = wb.create_sheet(title="Patch Panels (Bocas 1-24)")
    ws_pp.append([
        "Rack",
        "Unidad U",
        "Patch Panel (Código)",
        "Nombre Patch Panel",
        "Tipo Panel",
        "Boca Nº",
        "Conector",
        "Estado Boca",
        "Switch / Hierro Conectado",
        "Boca del Switch / Hierro",
        "IP del Switch / Hierro",
        "Aparato / Dispositivo Conectado (Cuál es)",
        "Tipo de Aparato",
        "IP del Aparato",
        "Sala / Ubicación / Roseta",
        "VLAN",
        "Estado Aparato",
        "Etiqueta / Circuito",
    ])

    occupied_fill = PatternFill(start_color="EFF6FF", end_color="EFF6FF", fill_type="solid")
    free_fill = PatternFill(start_color="F8FAFC", end_color="F8FAFC", fill_type="solid")

    for pp in inv["patch_panels"]:
        for boca in pp["bocas"]:
            sw = boca.get("switch_hardware") or {}
            ep = boca.get("connected_device") or {}
            is_occ = boca["is_occupied"]

            sw_name_str = (
                f"{sw.get('code', '')} — {sw.get('name', '')}".strip(" —")
                if sw
                else "Sin conexión a Switch"
            )
            sw_port_str = (
                f"{sw.get('code', '').split(' ')[0]}:{sw.get('port', '')}"
                if sw and sw.get("port")
                else "—"
            )
            sw_ip_str = sw.get("ip_address") or "—"

            if ep:
                ep_identity = f"{ep.get('code', '')} — {ep.get('name', '')}".strip(" —")
                ep_type = ep.get("device_type_label") or ep.get("device_type") or "Dispositivo"
                ep_ip = ep.get("ip_address") or "Sin IP"
                ep_room = ep.get("room_code") or "—"
                if ep.get("via_outlet") and ep.get("via_outlet") not in ep_room:
                    ep_room = f"{ep_room} ({ep.get('via_outlet')})".strip()
                ep_status = str(ep.get("status") or "online").upper()
            else:
                ep_identity = "LIBRE — Sin aparato conectado"
                ep_type = "—"
                ep_ip = "—"
                ep_room = "—"
                ep_status = "LIBRE"

            ws_pp.append([
                pp["rack_code"],
                pp["u_range"],
                pp["code"],
                pp["name"],
                pp["equipment_type_badge"],
                f"Boca {boca['slot_number']:02d} ({boca['port_label']})",
                str(boca["port_type"] or "rj45").upper(),
                "OCUPADA" if is_occ else "LIBRE (Sin conexión)",
                sw_name_str if is_occ else "—",
                sw_port_str if is_occ else "—",
                sw_ip_str if is_occ else "—",
                ep_identity,
                ep_type,
                ep_ip,
                ep_room,
                boca.get("vlan") or "",
                ep_status,
                boca.get("cable_label") or "",
            ])
    _style_worksheet(ws_pp)
    for row in ws_pp.iter_rows(min_row=2):
        state_val = str(row[7].value or "")
        row_fill = occupied_fill if state_val.startswith("OCUPADA") else free_fill
        for cell in row:
            cell.fill = row_fill

    # 4. Hoja de Mapa de Cableado (Patching)
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
    Genera una plantilla Excel (.xlsx) de ejemplo multi-datacenter, multi-planta, multi-rack y con
    equipos variados (Switches, Servidores, SAN, NAS, Ventiladores de Techo 1U con ETH, Bandejas U editables, PDUs)
    y conexiones (Intra-Rack, Front<->Back e Inter-Rack) lista para importar en RackDoc:
    - Hoja 1: 1_Racks_y_Sedes (3 Datacenters, 5 Plantas y 10 Racks)
    - Hoja 2: 2_Equipos_y_Hosts (28 equipos repartidos en los Racks)
    - Hoja 3: 3_Conexiones_y_Fibras (Latiguillos UTP, Fibras Front<->Back, Fibras Inter-Rack y Alimentación)
    - Hoja 4: 4_Instrucciones_y_Librerias (Guía de referencia)
    """
    wb = Workbook()

    # Hoja 1: Racks y Sedes (3 Datacenters, múltiples plantas y 10 Racks)
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

    sample_racks = [
        # DATACENTER 1: MADRID CORE (MAD-DC1) — Planta 1 y Planta 2
        ("MAD-DC1", "Madrid Core Datacenter", "Planta 1 - Sala Producción Core", "Sala 101 - Core & Storage", "Pasillo Frío A (Core)", "RK-MAD-01", "Rack Core Networking & ODF 01", 42, "Rittal", "VX IT 42U", "Carlos Mendoza", "Cabecera óptica y switches Core"),
        ("MAD-DC1", "Madrid Core Datacenter", "Planta 1 - Sala Producción Core", "Sala 101 - Core & Storage", "Pasillo Frío A (Core)", "RK-MAD-02", "Rack Compute Virtualización 02", 42, "Rittal", "VX IT 42U", "Carlos Mendoza", "Nodos Proxmox / VMware conectados por fibra a RK-MAD-01 y RK-MAD-03"),
        ("MAD-DC1", "Madrid Core Datacenter", "Planta 1 - Sala Producción Core", "Sala 101 - Core & Storage", "Pasillo Frío B (Storage)", "RK-MAD-03", "Rack Cabinas SAN & NAS 03", 42, "Schneider APC", "NetShelter SX 42U", "Elena Gómez", "Cabinas Dell PowerStore, NetApp AFF e IBM FlashSystem"),
        ("MAD-DC1", "Madrid Core Datacenter", "Planta 2 - Cloud & IA", "Sala 201 - Clúster Kubernetes", "Pasillo Frío C (Cloud)", "RK-MAD-04", "Rack K8s Workers & NVMe 04", 42, "Rittal", "VX IT 42U", "David Ruiz", "Clúster Kubernetes de alta densidad"),
        ("MAD-DC1", "Madrid Core Datacenter", "Planta 2 - Cloud & IA", "Sala 201 - Clúster Kubernetes", "Pasillo Frío C (Cloud)", "RK-MAD-05", "Rack NAS Backup & Archivo 05", 42, "Rittal", "VX IT 42U", "David Ruiz", "Repositorio inmutable NAS Synology/QNAP/PowerScale"),
        # DATACENTER 2: BARCELONA EDGE (BCN-DC2) — Planta 1 y Planta Sótano
        ("BCN-DC2", "Barcelona Edge 22@ Datacenter", "Planta 1 - Sala Principal 22@", "Sala B1 - Producción", "Pasillo Frío A (BCN)", "RK-BCN-01", "Rack Networking & Firewall BCN 01", 42, "Rittal", "VX IT 42U", "Marc Puig", "Cabecera de red y seguridad BCN"),
        ("BCN-DC2", "Barcelona Edge 22@ Datacenter", "Planta 1 - Sala Principal 22@", "Sala B1 - Producción", "Pasillo Frío A (BCN)", "RK-BCN-02", "Rack Storage SAN/NAS & Compute BCN 02", 42, "Schneider APC", "NetShelter SX 42U", "Marc Puig", "Almacenamiento unificado NetApp y nodos Dell"),
        ("BCN-DC2", "Barcelona Edge 22@ Datacenter", "Planta Sótano - Meet-Me & Telco", "Sala B0 - Operadores Fibra", "Fila MMR-01", "RK-BCN-03", "Rack Operadores & Dark Fiber BCN 03", 42, "Rittal", "TS IT 42U", "Laura Vidal", "Interconexión de fibra oscura metropolitana"),
        # DATACENTER 3: VALENCIA CONTINGENCIA DRP (VAL-DR3) — Planta 1
        ("VAL-DR3", "Valencia Contingencia DRP", "Planta 1 - Sala Búnker DRP", "Sala V1 - Réplica Síncrona", "Pasillo Frío DR-A", "RK-VAL-01", "Rack Core & Réplica SAN VAL 01", 42, "Rittal", "VX IT 42U", "Sergio Navarro", "Cabina Pure Storage y enlaces DWDM"),
        ("VAL-DR3", "Valencia Contingencia DRP", "Planta 1 - Sala Búnker DRP", "Sala V1 - Réplica Síncrona", "Pasillo Frío DR-A", "RK-VAL-02", "Rack Recuperación Desastres VAL 02", 42, "Rittal", "VX IT 42U", "Sergio Navarro", "Clúster de contingencia y NAS backup"),
    ]
    for r_row in sample_racks:
        ws_racks.append(list(r_row))
    _style_worksheet(ws_racks)

    # Hoja 2: Equipos y Hosts (28 equipos variados en los 10 Racks)
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

    sample_devs = [
        # --- RK-MAD-01 (Madrid Planta 1 - Core Networking & ODF) ---
        ("RK-MAD-01", 42, 1, "FRONT", "FAN-MAD-01", "Ventiladores Techo Smart ETH 01", "Organizers", "Rittal / APC", "Ventiladores de Techo 1U (Smart Roof Fan + ETH)", "fan-mad01", "fan01.mad.rackdoc.local", "10.10.1.42", "255.255.255.0", "10.10.1.1", 10, "SI", "http", 80, "/status", "admin", "FAN-2026-001", "Sonda térmica + Ethernet RJ45"),
        ("RK-MAD-01", 40, 1, "FRONT", "ODF-MAD-01", "Bandeja Fibra Inter-Rack 24x LC", "Organizers", "Corning", "Patch Panel Fibra Óptica 24x LC Duplex 1U", "", "", "", "", "", "", "NO", "icmp", 22, "", "admin", "COR-ODF-001", "Cabecera de fibras hacia RK-MAD-02 y RK-MAD-03"),
        ("RK-MAD-01", 38, 1, "FRONT", "FW-MAD-01", "Firewall Perimetral FortiGate 200F", "Network", "Fortinet", "FortiGate 200F Next-Gen Firewall", "fw-mad01", "fw01.mad.rackdoc.local", "10.10.1.2", "255.255.255.0", "10.10.1.1", 10, "SI", "https", 443, "/login", "admin", "FG200F-9911", "Clúster HA Activo"),
        ("RK-MAD-01", 36, 1, "FRONT", "SW-MAD-CORE1", "Switch Core Fibra 10G/25G", "Network", "Arista", "DCS-7050SX3-48YC8 1U", "sw-mad-core1", "sw-core1.mad.rackdoc.local", "10.10.1.10", "255.255.255.0", "10.10.1.1", 10, "SI", "ssh", 22, "", "admin", "ARI-7050-01", "Switch de agregación óptica"),
        ("RK-MAD-01", 34, 1, "FRONT", "SW-MAD-ACC1", "Switch Acceso PoE+ 48 Bocas", "Network", "Cisco", "Catalyst 9300-48P", "sw-mad-acc1", "sw-acc1.mad.rackdoc.local", "10.10.1.11", "255.255.255.0", "10.10.1.1", 10, "SI", "ssh", 22, "", "admin", "FCW2401A01", "Gestión y acceso LAN"),
        ("RK-MAD-01", 28, 2, "FRONT", "TRAY-MAD-01", "Bandeja Sonda Óptica y Módem (Ocupa 2U)", "Organizers", "RackDoc Custom", "Bandeja Regulable en U (1U por defecto — U Editable)", "", "", "", "", "", "", "NO", "icmp", 22, "", "admin", "TRAY-001", "Bandeja configurada a 2U de altura"),
        ("RK-MAD-01", 4, 1, "BACK", "PDU-MAD-01", "Regleta PDU Trasera Schuko 8 Tomas", "Power", "APC / Schuko", "PDU Regleta Rack 19\" 8x Enchufes Schuko + Macho IN", "", "", "", "", "", "", "NO", "icmp", 22, "", "admin", "PDU-MAD-01", "Montada en cara trasera (BACK)"),

        # --- RK-MAD-02 (Madrid Planta 1 - Compute Virtualización) ---
        ("RK-MAD-02", 42, 1, "FRONT", "FAN-MAD-02", "Ventiladores Techo Smart ETH 02", "Organizers", "Rittal / APC", "Ventiladores de Techo 1U (Smart Roof Fan + ETH)", "fan-mad02", "fan02.mad.rackdoc.local", "10.10.1.43", "255.255.255.0", "10.10.1.1", 10, "SI", "http", 80, "/status", "admin", "FAN-2026-002", "Ventilación activa"),
        ("RK-MAD-02", 40, 1, "FRONT", "ODF-MAD-02", "Bandeja Fibra 24x LC (Enlace a RK-MAD-01/03)", "Organizers", "Corning", "Patch Panel Fibra Óptica 24x LC Duplex 1U", "", "", "", "", "", "", "NO", "icmp", 22, "", "admin", "COR-ODF-002", "Puente óptico inter-rack"),
        ("RK-MAD-02", 38, 1, "FRONT", "SW-MAD-TOR2", "Switch ToR Compute 48p", "Network", "Cisco", "Catalyst 9300-48P", "sw-mad-tor2", "sw-tor2.mad.rackdoc.local", "10.10.1.12", "255.255.255.0", "10.10.1.1", 10, "SI", "ssh", 22, "", "admin", "FCW2401A02", "Top of Rack Compute"),
        ("RK-MAD-02", 30, 2, "FRONT", "ESX-MAD-01", "Hipervisor VMware / ProLiant DL380 Gen11", "Host - HP", "HPE", "ProLiant DL380 Gen11 24SFF", "esx-mad01", "esx01.mad.rackdoc.local", "10.10.1.51", "255.255.255.0", "10.10.1.1", 20, "SI", "https", 443, "/ui", "root", "CZ2601001", "Conectado por FC a SAN en RK-MAD-03"),
        ("RK-MAD-02", 26, 2, "FRONT", "ESX-MAD-02", "Hipervisor VMware / PowerEdge R760", "Host - Dell", "Dell EMC", "PowerEdge R760 2U (Dual Xeon)", "esx-mad02", "esx02.mad.rackdoc.local", "10.10.1.52", "255.255.255.0", "10.10.1.1", 20, "SI", "https", 443, "/ui", "root", "DL760-002", "Conectado por fibra a RK-MAD-03"),
        ("RK-MAD-02", 2, 2, "FRONT", "UPS-MAD-02", "SAI Doble Conversión 3000VA", "Power", "APC", "Smart-UPS 3000VA LCD RM 2U", "ups-mad02", "ups02.mad.rackdoc.local", "10.10.1.92", "255.255.255.0", "10.10.1.1", 10, "SI", "snmp", 161, "", "admin", "APC-3000-02", "Respaldo eléctrico Compute"),

        # --- RK-MAD-03 (Madrid Planta 1 - Cabinas SAN & NAS) ---
        ("RK-MAD-03", 40, 1, "FRONT", "ODF-MAD-03", "Bandeja Fibra SAN 24x LC", "Organizers", "Corning", "Patch Panel Fibra Óptica 24x LC Duplex 1U", "", "", "", "", "", "", "NO", "icmp", 22, "", "admin", "COR-ODF-003", "Recepción fibras desde RK-MAD-01 y RK-MAD-02"),
        ("RK-MAD-03", 34, 2, "FRONT", "SAN-DELL-01", "Cabina All-Flash Dell PowerStore 1200T", "Storage - SAN", "Dell EMC", "PowerStore 1200T All-Flash NVMe SAN 2U", "san-dell01", "powerstore01.mad.rackdoc.local", "10.10.2.10", "255.255.255.0", "10.10.2.1", 30, "SI", "https", 443, "/", "admin", "PST1200-01", "LUNs producción VMware"),
        ("RK-MAD-03", 28, 4, "FRONT", "SAN-NETAPP-01", "Cabina NetApp AFF A400 Dual Controller", "Storage - SAN", "NetApp", "AFF A400 All-Flash SAN 4U (HA Dual Controller)", "san-netapp01", "affa400.mad.rackdoc.local", "10.10.2.11", "255.255.255.0", "10.10.2.1", 30, "SI", "https", 443, "/sysmgr", "admin", "NTAP-A400-01", "Cabina crítica 4U"),
        ("RK-MAD-03", 22, 2, "FRONT", "SAN-IBM-01", "Cabina IBM FlashSystem 5200 NVMe", "Storage - SAN", "IBM", "FlashSystem 5200 NVMe FC SAN 2U", "san-ibm01", "fs5200.mad.rackdoc.local", "10.10.2.12", "255.255.255.0", "10.10.2.1", 30, "SI", "https", 443, "/", "superuser", "IBM-FS52-01", "Bases de datos Oracle/ DB2"),
        ("RK-MAD-03", 16, 2, "FRONT", "NAS-SYNO-01", "Servidor NAS Synology RS3621xs+ 12 Bahías", "Storage - NAS", "Synology", "RackStation RS3621xs+ 2U 12-Bay NAS", "nas-syno01", "syno01.mad.rackdoc.local", "10.10.2.20", "255.255.255.0", "10.10.2.1", 30, "SI", "https", 5001, "/", "admin", "SYNO-3621-01", "Repositorios NFS y SMB"),

        # --- RK-MAD-04 & RK-MAD-05 (Madrid Planta 2 - Cloud & IA) ---
        ("RK-MAD-04", 40, 1, "FRONT", "SW-MAD-K8S", "Switch Cloud Leaf 25G/100G", "Network", "Arista", "DCS-7050SX3-48YC8 1U", "sw-mad-k8s", "sw-k8s.mad.rackdoc.local", "10.10.20.10", "255.255.255.0", "10.10.20.1", 20, "SI", "ssh", 22, "", "admin", "ARI-K8S-01", "Leaf Switch Planta 2"),
        ("RK-MAD-04", 32, 2, "FRONT", "K8S-NODE-01", "Worker IA Supermicro Hyper NVMe", "Host - Supermicro", "Supermicro", "SuperServer 2U Hyper SYS-221H-TNR (8x NVMe)", "k8s-node01", "k8s01.mad.rackdoc.local", "10.10.20.51", "255.255.255.0", "10.10.20.1", 20, "SI", "ssh", 22, "", "ubuntu", "SM-K8S-01", "Nodo GPU/NVMe"),
        ("RK-MAD-05", 30, 2, "FRONT", "NAS-ISILON-01", "Nodo Dell PowerScale F600 NVMe NAS", "Storage - NAS", "Dell EMC", "PowerScale F600 All-Flash NVMe NAS 2U", "nas-isilon01", "powerscale01.mad.rackdoc.local", "10.10.20.60", "255.255.255.0", "10.10.20.1", 30, "SI", "https", 8080, "/", "root", "PS-F600-01", "Data Lake IA & S3"),

        # --- RK-BCN-01, RK-BCN-02 & RK-BCN-03 (Barcelona Edge 22@ - Planta 1 y Sótano) ---
        ("RK-BCN-01", 42, 1, "FRONT", "FAN-BCN-01", "Ventiladores Techo Smart BCN 01", "Organizers", "Rittal / APC", "Ventiladores de Techo 1U (Smart Roof Fan + ETH)", "fan-bcn01", "fan01.bcn.rackdoc.local", "10.20.1.42", "255.255.255.0", "10.20.1.1", 10, "SI", "http", 80, "/status", "admin", "FAN-BCN-01", "Control térmico BCN"),
        ("RK-BCN-01", 38, 1, "FRONT", "SW-BCN-CORE1", "Switch Core BCN 48p", "Network", "Cisco", "Catalyst 9300-48P", "sw-bcn-core1", "sw-core1.bcn.rackdoc.local", "10.20.1.10", "255.255.255.0", "10.20.1.1", 10, "SI", "ssh", 22, "", "admin", "FCW-BCN-01", "Core Switch Barcelona"),
        ("RK-BCN-02", 32, 4, "FRONT", "NAS-NETAPP-BCN", "Cabina Unificada NetApp FAS8300 4U", "Storage - NAS", "NetApp", "FAS8300 Unified Enterprise NAS 4U", "nas-bcn01", "fas8300.bcn.rackdoc.local", "10.20.1.30", "255.255.255.0", "10.20.1.1", 30, "SI", "https", 443, "/", "admin", "NTAP-BCN-01", "Almacenamiento corporativo BCN"),
        ("RK-BCN-02", 24, 2, "FRONT", "SRV-BCN-01", "Servidor HPE ProLiant DL380 Gen11 BCN", "Host - HP", "HPE", "ProLiant DL380 Gen11 24SFF", "srv-bcn01", "srv01.bcn.rackdoc.local", "10.20.1.51", "255.255.255.0", "10.20.1.1", 20, "SI", "https", 443, "/", "Administrator", "CZ-BCN-051", "Host principal Barcelona"),
        ("RK-BCN-03", 40, 1, "FRONT", "ODF-BCN-MMR", "Cabecera Fibra Oscura Operadores 24x LC", "Organizers", "Corning", "Patch Panel Fibra Óptica 24x LC Duplex 1U", "", "", "", "", "", "", "NO", "icmp", 22, "", "admin", "ODF-MMR-01", "Planta Sótano Meet-Me Room"),

        # --- RK-VAL-01 & RK-VAL-02 (Valencia Contingencia DRP - Planta 1) ---
        ("RK-VAL-01", 34, 3, "FRONT", "SAN-PURE-VAL", "Cabina Pure Storage FlashArray//X50 R4 3U", "Storage - SAN", "Pure Storage", "FlashArray//X50 R4 All-NVMe SAN 3U", "san-val01", "purex50.val.rackdoc.local", "10.30.1.20", "255.255.255.0", "10.30.1.1", 30, "SI", "https", 443, "/", "pureuser", "PURE-X50-01", "Réplica ActiveCluster DRP"),
        ("RK-VAL-02", 30, 2, "FRONT", "NAS-QNAP-VAL", "Cabina QNAP ZFS All-Flash TS-h1290FX", "Storage - NAS", "QNAP", "TS-h1290FX ZFS All-Flash U.2 NVMe NAS 2U", "nas-val01", "qnap01.val.rackdoc.local", "10.30.1.30", "255.255.255.0", "10.30.1.1", 30, "SI", "https", 8080, "/", "admin", "QNAP-VAL-01", "Backup DRP Valencia"),
    ]
    for d_row in sample_devs:
        ws_devs.append(list(d_row))
    _style_worksheet(ws_devs)

    # Hoja 3: Conexiones y Fibras (Intra-Rack, Front<->Back e Inter-Rack)
    ws_conns = wb.create_sheet(title="3_Conexiones_y_Fibras")
    ws_conns.append([
        "Rack Origen",
        "Equipo Origen",
        "Boca Origen",
        "Rack Destino",
        "Equipo Destino",
        "Boca Destino",
        "Tipo de Cable",
        "Color Hex",
        "Etiqueta / Circuito",
        "VLAN",
        "Longitud (m)",
    ])
    sample_conns = [
        # Conexiones Intra-Rack y Front<->Back en RK-MAD-01
        ("RK-MAD-01", "FAN-MAD-01", "ETH1", "RK-MAD-01", "SW-MAD-ACC1", "1", "utp_cat6a", "#2563EB", "Telemetría Ventilador Techo -> SW-MAD-ACC1", 10, 1.5),
        ("RK-MAD-01", "FW-MAD-01", "F1", "RK-MAD-01", "SW-MAD-CORE1", "SFP1", "fiber_om4", "#0284C7", "Uplink Óptico 10G Firewall -> Core", 10, 2.0),
        ("RK-MAD-01", "SW-MAD-CORE1", "SFP2", "RK-MAD-01", "ODF-MAD-01", "LC1", "fiber_om4", "#0284C7", "Puente Óptico Core -> ODF-MAD-01", 10, 1.5),
        ("RK-MAD-01", "SW-MAD-ACC1", "PSU1", "RK-MAD-01", "PDU-MAD-01", "SCHUKO-1", "power_ac", "#DC2626", "Alimentación Front<->Back SW-MAD-ACC1 -> PDU Trasera", "", 1.8),
        # Conexiones Inter-Rack (de un Rack a otro Rack)
        ("RK-MAD-01", "ODF-MAD-01", "R-LC1", "RK-MAD-02", "ODF-MAD-02", "R-LC1", "fiber_om4", "#0284C7", "Troncal Fibra OM4 Inter-Rack RK-MAD-01 <-> RK-MAD-02", 20, 12.0),
        ("RK-MAD-01", "ODF-MAD-01", "R-LC2", "RK-MAD-03", "ODF-MAD-03", "R-LC1", "fiber_os2", "#F59E0B", "Troncal Fibra OS2 Inter-Rack RK-MAD-01 <-> RK-MAD-03", 30, 15.0),
        ("RK-MAD-02", "ESX-MAD-01", "SFP1", "RK-MAD-03", "SAN-DELL-01", "FC1", "fiber_om4", "#0284C7", "Fibre Channel 32G Inter-Rack ESX-MAD-01 -> PowerStore SAN", 30, 10.0),
        ("RK-MAD-02", "ESX-MAD-02", "SFP1", "RK-MAD-03", "SAN-NETAPP-01", "FC1", "fiber_om4", "#7C3AED", "Fibre Channel 32G Inter-Rack ESX-MAD-02 -> NetApp AFF A400", 30, 10.0),
        ("RK-BCN-01", "SW-BCN-CORE1", "SFP49", "RK-BCN-02", "NAS-NETAPP-BCN", "25G-1", "fiber_om4", "#0284C7", "Enlace 25GbE Inter-Rack BCN Core -> NetApp FAS8300", 30, 8.0),
    ]
    for c_row in sample_conns:
        ws_conns.append(list(c_row))
    _style_worksheet(ws_conns)

    # Hoja 4: Instrucciones
    ws_help = wb.create_sheet(title="4_Instrucciones_y_Librerias")
    ws_help.append(["Campo / Columna", "Descripción y Valores Permitidos", "Ejemplo"])
    ws_help.append([
        "1_Racks_y_Sedes",
        "Crea o actualiza múltiples Datacenters (Sedes), Plantas, Salas, Pasillos y Racks (incluyendo sus tomas exteriores eléctricas y de fibra).",
        "MAD-DC1 / BCN-DC2 / VAL-DR3",
    ])
    ws_help.append([
        "2_Equipos_y_Hosts",
        "Monta automáticamente Switches, Firewalls, Servidores, Cabinas Storage - SAN, Cabinas Storage - NAS, Ventiladores de Techo 1U con ETH y Bandejas con U editables.",
        "SAN-DELL-01, FAN-MAD-01, TRAY-MAD-01",
    ])
    ws_help.append([
        "3_Conexiones_y_Fibras",
        "Conecta automáticamente cables UTP, fibras ópticas y enchufes tanto dentro del mismo Rack (Front<->Front o Front<->Back) como entre distintos Racks (Inter-Rack).",
        "RK-MAD-02 -> RK-MAD-03",
    ])
    ws_help.append([
        "Librerías Soportadas",
        "Network | Storage - SAN | Storage - NAS | Host - HP | Host - Dell | Host - Supermicro | Organizers | Power",
        "Storage - SAN",
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
                    existing_locs = db.query(Location).count()
                    loc_pos_x = min(0.85, 0.25 + (existing_locs % 4) * 0.18)
                    loc_pos_y = min(0.82, 0.30 + (existing_locs // 4) * 0.22)
                    loc = Location(
                        code=loc_code,
                        name=loc_name,
                        latitude=40.4168,
                        longitude=-3.7038,
                        pos_x=loc_pos_x,
                        pos_y=loc_pos_y,
                    )
                    db.add(loc)
                    db.flush()

                fl = (
                    db.query(Floor)
                    .filter(Floor.location_id == loc.id, Floor.name == floor_name)
                    .first()
                )
                if not fl:
                    fl_cnt = db.query(Floor).filter(Floor.location_id == loc.id).count()
                    fl = Floor(location_id=loc.id, name=floor_name, level_number=fl_cnt + 1)
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
                    racks_in_room = db.query(Rack).filter(Rack.room_id == rm.id).count()
                    rk_pos_x = min(0.84, 0.14 + (racks_in_room % 4) * 0.18)
                    rk_pos_y = min(0.80, 0.24 + (racks_in_room // 4) * 0.26)
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
                        pos_x=rk_pos_x,
                        pos_y=rk_pos_y,
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
                    if u_height != tpl.u_height:
                        cf["u_height_override"] = u_height
                    existing_dev.custom_fields = cf
                    devices_updated += 1
                else:
                    init_cf: Dict[str, Any] = {"heartbeat_config": hb_cfg}
                    if u_height != tpl.u_height:
                        init_cf["u_height_override"] = u_height
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
                        custom_fields=init_cf,
                        notes=notes,
                    )
                    db.add(new_dev)
                    db.flush()
                    create_ports_from_template(db, new_dev, tpl)
                    devices_created += 1

    # 3. Procesar hoja de Conexiones si existe ('3_Conexiones_y_Fibras')
    conn_sheet = wb["3_Conexiones_y_Fibras"] if "3_Conexiones_y_Fibras" in wb.sheetnames else None
    if conn_sheet is not None:
        c_rows = list(conn_sheet.iter_rows(values_only=True))
        if len(c_rows) > 1:
            c_headers = [str(h or "").strip().lower() for h in c_rows[0]]

            def c_val(row_tuple, *candidates) -> str:
                for c in candidates:
                    for idx, h in enumerate(c_headers):
                        if c == h or c in h:
                            if idx < len(row_tuple):
                                v = row_tuple[idx]
                                return "" if v is None else str(v).strip()
                return ""

            for row in c_rows[1:]:
                s_rack_code = c_val(row, "rack origen")
                s_dev_code = c_val(row, "equipo origen")
                s_port_num = c_val(row, "boca origen")
                t_rack_code = c_val(row, "rack destino")
                t_dev_code = c_val(row, "equipo destino")
                t_port_num = c_val(row, "boca destino")
                if not (s_rack_code and s_dev_code and s_port_num and t_rack_code and t_dev_code and t_port_num):
                    continue
                s_rk = db.query(Rack).filter(Rack.code == s_rack_code).first()
                t_rk = db.query(Rack).filter(Rack.code == t_rack_code).first()
                if not s_rk or not t_rk:
                    continue
                s_dev = (
                    db.query(RackDevice)
                    .filter(RackDevice.rack_id == s_rk.id, RackDevice.code == s_dev_code)
                    .first()
                )
                t_dev = (
                    db.query(RackDevice)
                    .filter(RackDevice.rack_id == t_rk.id, RackDevice.code == t_dev_code)
                    .first()
                )
                if not s_dev or not t_dev:
                    continue
                sp = (
                    db.query(Port)
                    .filter(Port.device_id == s_dev.id, Port.port_number == s_port_num)
                    .first()
                )
                tp = (
                    db.query(Port)
                    .filter(Port.device_id == t_dev.id, Port.port_number == t_port_num)
                    .first()
                )
                if not sp:
                    sp = db.query(Port).filter(Port.device_id == s_dev.id).first()
                if not tp:
                    tp = db.query(Port).filter(Port.device_id == t_dev.id).first()
                if not sp or not tp or sp.id == tp.id:
                    continue
                busy = (
                    db.query(Connection)
                    .filter(
                        (Connection.source_port_id.in_([sp.id, tp.id]))
                        | (Connection.target_port_id.in_([sp.id, tp.id]))
                    )
                    .first()
                )
                if busy:
                    continue
                cable_type = c_val(row, "tipo de cable") or "fiber_om4"
                color_hex = c_val(row, "color hex") or "#0284C7"
                label = c_val(row, "etiqueta") or f"{s_dev_code}:{sp.port_number} -> {t_dev_code}:{tp.port_number}"
                vlan_s = c_val(row, "vlan")
                vlan_val = int(float(vlan_s)) if vlan_s.replace(".", "", 1).isdigit() else None
                len_s = c_val(row, "longitud")
                len_val = float(len_s) if len_s.replace(".", "", 1).isdigit() else 2.0
                db.add(
                    Connection(
                        source_port_id=sp.id,
                        target_port_id=tp.id,
                        cable_type=cable_type,
                        color_hex=color_hex,
                        routing_channel="auto",
                        label=label,
                        vlan=vlan_val,
                        length_m=len_val,
                    )
                )

    db.commit()
    return {
        "racks_created": racks_created,
        "racks_updated": racks_updated,
        "devices_created": devices_created,
        "devices_updated": devices_updated,
        "warnings": warnings,
    }
