"""Racks, equipos montados, tomas exteriores y cableado."""

from fastapi import Depends, HTTPException
from sqlalchemy.orm import Session, joinedload, selectinload

from ..database import get_db
from ..models import CmdbAsset, Connection, DeviceTemplate, Floor, FloorDevice, Port, Rack, RackDevice, Room, TlsCertificate
from ..rack_sync import _extract_floor_device_id_from_port, _sync_rack_floor_devices_box
from ..schemas import ConnectionCreate, ConnectionSchema, ConnectionUpdate, ExternalOutletCreate, ExternalOutletUpdate, RackCreate, RackDeviceCreate, RackDeviceSchema, RackDeviceUpdate, RackUpdate
from ..seed import create_ports_from_template, ensure_rack_external_outlets, get_or_create_external_feed_template, sync_external_outlet_ports
from ..routers._common import _check_u_collision, _delete_connections_for_port_ids, _effective_device_u_height, _serialize_connection, api_router
from ..services.cmdb_service import resolve_cmdb_ip_collision, sync_physical_devices_to_cmdb
from ..services.monitor import check_all_monitored_devices, check_single_device, run_device_remote_console
from ..services.certscope_service import sync_or_probe_device_certificate

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
    # Todo Rack nace con su recuadro 'PLANTA-DC' (antes lo creaba, de tapadillo,
    # el primer GET /racks/{id} que alguien hiciera).
    _sync_rack_floor_devices_box(db, rk)
    db.commit()
    return {"id": rk.id, "code": rk.code, "name": rk.name}


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

    # Este endpoint es de solo lectura: no crea tomas exteriores ni recalcula la
    # caja 'PLANTA-DC'. De eso se encargan las rutas de escritura que pueden
    # invalidarlas (alta de Rack, alta/edición/baja de dispositivos de planta y
    # borrado de Plantas/Sedes) y el arranque, en sync_system_defaults().
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

    # Sincronizar inmediatamente con la CMDB y aplicar resolución de colisión si el operario la indicó desde el Rack Editor
    sync_physical_devices_to_cmdb(db)
    cf_clean = dict(device.custom_fields or {})
    col_action = cf_clean.pop("on_ip_collision_action", None)
    col_target_id = cf_clean.pop("collision_target_asset_id", None)
    if col_action or col_target_id is not None:
        device.custom_fields = cf_clean
        db.commit()
    if col_action and col_target_id and (device.ip_address or "").strip():
        my_asset = db.query(CmdbAsset).filter(CmdbAsset.rack_device_id == device.id).first()
        if my_asset and my_asset.id != int(col_target_id):
            try:
                resolve_cmdb_ip_collision(
                    db=db,
                    ip_address=device.ip_address.strip(),
                    action=str(col_action),
                    keep_asset_id=my_asset.id,
                    other_asset_id=int(col_target_id),
                )
                db.refresh(device)
            except Exception:
                pass
    if payload.certscope_enabled:
        target_host = (device.ip_address or "").strip() or (device.fqdn or "").strip() or (device.hostname or "").strip()
        if target_host:
            my_asset = db.query(CmdbAsset).filter(CmdbAsset.rack_device_id == device.id).first()
            sync_or_probe_device_certificate(
                db,
                name=f"Certificado TLS {device.name}",
                target_host=target_host,
                port=payload.certscope_port or 443,
                sni_hostname=payload.certscope_sni or device.fqdn or "",
                renewal_type=payload.certscope_renewal_type or "manual",
                asset_id=my_asset.id if my_asset else None,
                rack_device_id=device.id,
                location_id=rack.room.floor.location_id if (rack.room and rack.room.floor) else None,
            )
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
    certscope_enabled = updates.pop("certscope_enabled", None)
    certscope_port = updates.pop("certscope_port", None)
    certscope_renewal_type = updates.pop("certscope_renewal_type", None)
    certscope_sni = updates.pop("certscope_sni", None)
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

    # Sincronizar inmediatamente con la CMDB y aplicar resolución de colisión si el operario la indicó desde el Rack Editor
    sync_physical_devices_to_cmdb(db)
    cf_clean = dict(device.custom_fields or {})
    col_action = cf_clean.pop("on_ip_collision_action", None)
    col_target_id = cf_clean.pop("collision_target_asset_id", None)
    if col_action or col_target_id is not None:
        device.custom_fields = cf_clean
        db.commit()
    if col_action and col_target_id and (device.ip_address or "").strip():
        my_asset = db.query(CmdbAsset).filter(CmdbAsset.rack_device_id == device.id).first()
        if my_asset and my_asset.id != int(col_target_id):
            try:
                resolve_cmdb_ip_collision(
                    db=db,
                    ip_address=device.ip_address.strip(),
                    action=str(col_action),
                    keep_asset_id=my_asset.id,
                    other_asset_id=int(col_target_id),
                )
                db.refresh(device)
            except Exception:
                pass

    if certscope_enabled:
        target_host = (device.ip_address or "").strip() or (device.fqdn or "").strip() or (device.hostname or "").strip()
        if target_host:
            my_asset = db.query(CmdbAsset).filter(CmdbAsset.rack_device_id == device.id).first()
            rk = device.rack
            sync_or_probe_device_certificate(
                db,
                name=f"Certificado TLS {device.name}",
                target_host=target_host,
                port=certscope_port or 443,
                sni_hostname=certscope_sni or device.fqdn or "",
                renewal_type=certscope_renewal_type or "manual",
                asset_id=my_asset.id if my_asset else None,
                rack_device_id=device.id,
                location_id=rk.room.floor.location_id if (rk and rk.room and rk.room.floor) else None,
            )
            db.commit()
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

    db.query(TlsCertificate).filter(TlsCertificate.rack_device_id == device_id).update(
        {"rack_device_id": None}
    )
    for ast in db.query(CmdbAsset).filter(CmdbAsset.rack_device_id == device_id).all():
        ast.rack_device_id = None
    for ast in db.query(CmdbAsset).filter(CmdbAsset.host_rack_device_id == device_id).all():
        ast.host_rack_device_id = None

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
