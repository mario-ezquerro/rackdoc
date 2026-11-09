"""Sedes, plantas, salas, pasillos y dispositivos de planta."""

from fastapi import Depends, HTTPException
from sqlalchemy.orm import Session, joinedload, selectinload

from ..database import get_db
from ..models import Aisle, CmdbAsset, CmdbIpAddress, Connection, Floor, FloorDevice, FloorDeviceCustomType, Location, Port, Rack, RackDevice, Room, TlsCertificate
from ..rack_sync import _rack_ids_vinculados_a_floor_devices, _resync_rack_boxes, _sync_rack_floor_devices_box
from ..schemas import AisleCreate, FloorCreate, FloorDeviceCreate, FloorDeviceCustomTypeCreate, FloorDeviceUpdate, FloorUpdate, LocationCreate, LocationUpdate, RoomCreate
from ..routers._common import _delete_connections_for_port_ids, _effective_device_u_height, api_router
from ..services.cmdb_service import sync_physical_devices_to_cmdb
from ..services.monitor import check_single_device
from ..services.certscope_service import sync_or_probe_device_certificate

@api_router.get(
    "/locations",
    tags=["Locations, Floors & Blueprints"],
    summary="Obtener árbol completo de Sedes, Plantas, Salas, Racks y Sensores",
    description="Devuelve la jerarquía completa del CPD con contadores agregados de Heartbeat (Gris, Verde, Naranja, Rojo), Racks y dispositivos de planta.",
)
def get_locations_tree(db: Session = Depends(get_db)):
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
    # Enlaces entre racks distintos, serializados UNA sola vez e indexados por
    # cada rack extremo. Antes la lista completa de conexiones se recorría
    # dentro del bucle de plantas, es decir O(plantas x conexiones); ahora es
    # una pasada O(conexiones) más, por planta, solo sus enlaces.
    enlaces_inter_rack: list[tuple[int, int, dict]] = []
    enlaces_por_rack: dict[int, list[int]] = {}

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

        r1 = sd.rack
        r2 = td.rack
        if not r1 or not r2 or r1.id == r2.id:
            continue
        indice = len(enlaces_inter_rack)
        enlaces_inter_rack.append(
            (
                r1.id,
                r2.id,
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
                },
            )
        )
        enlaces_por_rack.setdefault(r1.id, []).append(indice)
        enlaces_por_rack.setdefault(r2.id, []).append(indice)

    # Mapa de activos CMDB vinculados a FloorDevice para exponer cmdb_asset_id/code en el plano 2D
    floor_cmdb_map = {
        a.floor_device_id: a
        for a in db.query(CmdbAsset).filter(CmdbAsset.floor_device_id.isnot(None)).all()
    }

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

            # Solo los enlaces que tocan algún rack de esta planta. El orden se
            # mantiene (los índices crecen con el recorrido de all_conns).
            indices_planta = sorted(
                {
                    i
                    for r_id in floor_rack_ids
                    for i in enlaces_por_rack.get(r_id, ())
                }
            )
            inter_rack_links = [
                {
                    **base,
                    "same_floor": (r1_id in floor_rack_ids)
                    and (r2_id in floor_rack_ids),
                }
                for r1_id, r2_id, base in (
                    enlaces_inter_rack[i] for i in indices_planta
                )
            ]

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
                    "cmdb_asset_id": floor_cmdb_map[fd.id].id if fd.id in floor_cmdb_map else None,
                    "cmdb_asset_code": floor_cmdb_map[fd.id].code if fd.id in floor_cmdb_map else "",
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
    racks_afectados = _rack_ids_vinculados_a_floor_devices(db, location_id=location_id)
    db.delete(loc)
    db.commit()
    _resync_rack_boxes(db, racks_afectados)
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
    # Los dispositivos de planta caen en cascada: hay que anotar qué Racks
    # quedan con una caja 'PLANTA-DC' obsoleta para recalcularla tras el borrado.
    racks_afectados = _rack_ids_vinculados_a_floor_devices(db, floor_id=floor_id)
    db.delete(fl)
    db.commit()
    _resync_rack_boxes(db, racks_afectados)
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
    cmdb_asset_id = data.pop("cmdb_asset_id", None)
    certscope_enabled = data.pop("certscope_enabled", False)
    certscope_port = data.pop("certscope_port", 443)
    certscope_renewal_type = data.pop("certscope_renewal_type", "manual")
    certscope_sni = data.pop("certscope_sni", "")
    if data.get("room_id") is None and fl.rooms:
        data["room_id"] = fl.rooms[0].id
    if data.get("linked_rack_id") == 0:
        data["linked_rack_id"] = None
    if data.get("linked_outlet_id") == 0:
        data["linked_outlet_id"] = None

    linked_ast = None
    if cmdb_asset_id:
        linked_ast = (
            db.query(CmdbAsset)
            .options(joinedload(CmdbAsset.ip_addresses))
            .filter(CmdbAsset.id == cmdb_asset_id)
            .first()
        )
        if linked_ast:
            hb_ip = next(
                (ip for ip in linked_ast.ip_addresses if ip.is_heartbeat_ip or ip.ip_role == "mgmt_heartbeat"),
                linked_ast.ip_addresses[0] if linked_ast.ip_addresses else None,
            )
            if not (data.get("ip_address") or "").strip() and hb_ip:
                data["ip_address"] = hb_ip.ip_address
            if not (data.get("mac_address") or "").strip() and hb_ip and hb_ip.mac_address:
                data["mac_address"] = hb_ip.mac_address
            if not (data.get("fqdn") or "").strip():
                data["fqdn"] = (hb_ip.fqdn if hb_ip and hb_ip.fqdn else "") or linked_ast.fqdn or ""
            if data.get("vlan") is None and hb_ip and hb_ip.vlan_id is not None:
                data["vlan"] = hb_ip.vlan_id
            if linked_ast.status == "online":
                data["monitoring_enabled"] = True
                data["status"] = "online"

    if not data.get("monitoring_enabled"):
        data["status"] = "unmonitored"
    fd = FloorDevice(floor_id=floor_id, **data)
    db.add(fd)
    db.commit()
    db.refresh(fd)

    if linked_ast:
        linked_ast.floor_device_id = fd.id
        linked_ast.sync_source = "floor_device"
        linked_ast.asset_class = "floor_endpoint"
        linked_ast.name = fd.name
        linked_ast.os_or_firmware = f"Endpoint ({fd.device_type})"
        linked_ast.hypervisor_or_platform = f"Planta: {fl.name} ({fd.room_code})"
        if linked_ast.last_ping_ms is not None and fd.last_ping_ms is None:
            fd.last_ping_ms = linked_ast.last_ping_ms
            fd.last_checked_at = linked_ast.last_checked_at
        db.commit()

    sync_physical_devices_to_cmdb(db)

    if certscope_enabled:
        target_host = (fd.ip_address or "").strip() or (fd.fqdn or "").strip()
        if target_host:
            sync_or_probe_device_certificate(
                db,
                name=f"Certificado TLS {fd.name}",
                target_host=target_host,
                port=certscope_port or 443,
                sni_hostname=certscope_sni or fd.fqdn or "",
                renewal_type=certscope_renewal_type or "manual",
                responsible_person=fd.responsible_person or "Alex Geng",
                asset_id=linked_ast.id if linked_ast else None,
                floor_device_id=fd.id,
                location_id=fl.location_id,
            )
            db.commit()

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
    cmdb_asset_id = updates.pop("cmdb_asset_id", None)
    certscope_enabled = updates.pop("certscope_enabled", None)
    certscope_port = updates.pop("certscope_port", None)
    certscope_renewal_type = updates.pop("certscope_renewal_type", None)
    certscope_sni = updates.pop("certscope_sni", None)
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

    if cmdb_asset_id:
        linked_ast = (
            db.query(CmdbAsset)
            .options(joinedload(CmdbAsset.ip_addresses))
            .filter(CmdbAsset.id == cmdb_asset_id)
            .first()
        )
        if linked_ast:
            # Desvincular cualquier otro CmdbAsset previo de este FloorDevice si era distinto
            for prev_ast in db.query(CmdbAsset).filter(CmdbAsset.floor_device_id == fd.id, CmdbAsset.id != linked_ast.id).all():
                prev_ast.floor_device_id = None
                if prev_ast.code.startswith("FLR-"):
                    db.query(CmdbIpAddress).filter(CmdbIpAddress.asset_id == prev_ast.id).delete()
                    db.delete(prev_ast)
            linked_ast.floor_device_id = fd.id
            linked_ast.sync_source = "floor_device"
            linked_ast.asset_class = "floor_endpoint"
            db.commit()

    sync_physical_devices_to_cmdb(db)

    if certscope_enabled:
        target_host = (fd.ip_address or "").strip() or (fd.fqdn or "").strip()
        if target_host:
            sync_or_probe_device_certificate(
                db,
                name=f"Certificado TLS {fd.name}",
                target_host=target_host,
                port=certscope_port or 443,
                sni_hostname=certscope_sni or fd.fqdn or "",
                renewal_type=certscope_renewal_type or "manual",
                responsible_person=fd.responsible_person or "Alex Geng",
                asset_id=fd.cmdb_asset_id,
                floor_device_id=fd.id,
                location_id=fd.floor.location_id if fd.floor else None,
            )
            db.commit()

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
    # Desvincular activos CMDB asociados a este dispositivo de planta
    for ast in db.query(CmdbAsset).filter(CmdbAsset.floor_device_id == device_id).all():
        ast.floor_device_id = None
        if ast.code.startswith("FLR-"):
            db.query(CmdbIpAddress).filter(CmdbIpAddress.asset_id == ast.id).delete()
            db.delete(ast)
        else:
            ast.sync_source = "cmdb"
    # Desvincular otros dispositivos que apuntasen a esta roseta
    db.query(FloorDevice).filter(FloorDevice.linked_outlet_id == device_id).update(
        {"linked_outlet_id": None}
    )
    db.query(TlsCertificate).filter(TlsCertificate.floor_device_id == device_id).update(
        {"floor_device_id": None}
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
