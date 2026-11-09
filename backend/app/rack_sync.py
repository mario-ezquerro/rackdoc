"""Sincronización del recuadro 'PLANTA-DC' que cada Rack expone en el editor."""

from sqlalchemy.orm import Session, selectinload
from typing import Optional

from .models import Connection, Floor, FloorDevice, Port, Rack, RackDevice
from .seed import get_or_create_external_feed_template
from .routers._common import _delete_connections_for_port_ids

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


def _rack_ids_vinculados_a_floor_devices(
    db: Session,
    floor_id: Optional[int] = None,
    location_id: Optional[int] = None,
) -> set[int]:
    """Racks que tienen enganchado algún dispositivo de la planta o sede indicada."""
    q = db.query(FloorDevice.linked_rack_id).filter(FloorDevice.linked_rack_id.isnot(None))
    if floor_id is not None:
        q = q.filter(FloorDevice.floor_id == floor_id)
    if location_id is not None:
        q = q.join(Floor, Floor.id == FloorDevice.floor_id).filter(Floor.location_id == location_id)
    return {row[0] for row in q.all() if row[0]}


def _resync_rack_boxes(db: Session, rack_ids: set[int]) -> None:
    """Recalcula la caja 'PLANTA-DC' de los Racks indicados tras un borrado."""
    cambiado = False
    for rack_id in rack_ids:
        rk = (
            db.query(Rack)
            .options(
                selectinload(Rack.devices).selectinload(RackDevice.ports),
                selectinload(Rack.devices).joinedload(RackDevice.template),
            )
            .filter(Rack.id == rack_id)
            .first()
        )
        if rk and _sync_rack_floor_devices_box(db, rk):
            cambiado = True
    if cambiado:
        db.commit()


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
