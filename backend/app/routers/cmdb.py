"""CMDB, IPAM, verificación de direcciones IP y resolución de colisiones."""

from datetime import datetime
from fastapi import Depends, HTTPException
from sqlalchemy.orm import Session
from typing import Optional

from ..database import get_db
from ..models import CmdbAsset, CmdbIpAddress, CmdbSubnet, FloorDevice, LogicalTopologyLink, MonitoredServiceCheck, RackDevice, SwitchSnmpPort, TechStackNode
from ..schemas import CmdbAssetCreate, CmdbAssetUpdate, CmdbImportDiscoveredRequest, CmdbIpAddressInput, CmdbSubnetCreate, CmdbSubnetUpdate, CmdbVerifyIpRequest
from ..routers._common import api_router
from ..services.cmdb_service import _match_subnet_for_ip, build_cmdb_overview, check_cmdb_asset_heartbeat, check_ip_collision_in_cmdb, ensure_cmdb_seed_data, import_discovered_hosts_to_cmdb, resolve_cmdb_ip_collision, verify_ip_target_or_find_free
from ..services.network_host_service import sync_prometheus_targets_file

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
    summary="Eliminar activo de la CMDB y liberar todas sus IPs",
    description="Elimina una máquina virtual, contenedor, cluster o activo de la CMDB y deja libres todas sus IPs asociadas.",
)
def delete_cmdb_asset_endpoint(asset_id: int, db: Session = Depends(get_db)):
    asset = db.query(CmdbAsset).filter(CmdbAsset.id == asset_id).first()
    if not asset:
        raise HTTPException(status_code=404, detail="Activo CMDB no encontrado.")

    # Si está vinculado a un equipo físico de Rack o Planta, limpiar la IP del equipo físico para que no se regenere
    if asset.rack_device_id:
        rdev = db.query(RackDevice).filter(RackDevice.id == asset.rack_device_id).first()
        if rdev:
            rdev.ip_address = None
    if asset.floor_device_id:
        fdev = db.query(FloorDevice).filter(FloorDevice.id == asset.floor_device_id).first()
        if fdev:
            fdev.ip_address = None

    # Limpiar referencias en monitorización, topología y stack
    db.query(MonitoredServiceCheck).filter(MonitoredServiceCheck.cmdb_asset_id == asset.id).delete()
    db.query(SwitchSnmpPort).filter(SwitchSnmpPort.cmdb_asset_id == asset.id).delete()
    db.query(LogicalTopologyLink).filter(
        (LogicalTopologyLink.source_asset_id == asset.id) | (LogicalTopologyLink.target_asset_id == asset.id)
    ).delete(synchronize_session=False)
    for tnode in db.query(TechStackNode).filter(TechStackNode.cmdb_asset_id == asset.id).all():
        tnode.cmdb_asset_id = None

    # Eliminar todas las IPs asociadas para dejarlas libres en el mapa IPAM
    db.query(CmdbIpAddress).filter(CmdbIpAddress.asset_id == asset.id).delete()

    if asset.sync_source in ("rack_device", "floor_device"):
        db.commit()
        sync_prometheus_targets_file(db)
        return build_cmdb_overview(db)

    db.delete(asset)
    db.commit()
    sync_prometheus_targets_file(db)
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
    db.flush()
    if payload.is_heartbeat_ip and asset.sync_source == "rack_device" and asset.rack_device_id:
        rdev = db.query(RackDevice).filter(RackDevice.id == asset.rack_device_id).first()
        if rdev:
            rdev.ip_address = new_ip.ip_address
            if new_ip.subnet_mask:
                rdev.subnet_mask = new_ip.subnet_mask
            if new_ip.gateway:
                rdev.gateway = new_ip.gateway
            if new_ip.vlan_id is not None:
                rdev.vlan_mgmt = new_ip.vlan_id
            if new_ip.mac_address:
                rdev.mac_address = new_ip.mac_address
    elif payload.is_heartbeat_ip and asset.sync_source == "floor_device" and asset.floor_device_id:
        fdev = db.query(FloorDevice).filter(FloorDevice.id == asset.floor_device_id).first()
        if fdev:
            fdev.ip_address = new_ip.ip_address
            if new_ip.vlan_id is not None:
                fdev.vlan = new_ip.vlan_id
    db.commit()
    return build_cmdb_overview(db)


@api_router.delete(
    "/cmdb/ips/{ip_id}",
    tags=["CMDB, Multi-IP & IP Verification"],
    summary="Liberar / eliminar una dirección IP de un activo CMDB (dejándola libre en IPAM)",
)
def delete_cmdb_ip_endpoint(ip_id: int, db: Session = Depends(get_db)):
    ip_rec = db.query(CmdbIpAddress).filter(CmdbIpAddress.id == ip_id).first()
    if not ip_rec:
        raise HTTPException(status_code=404, detail="Registro de IP no encontrado.")
    ast = ip_rec.asset
    if ast:
        if ast.rack_device_id and ip_rec.is_heartbeat_ip:
            rdev = db.query(RackDevice).filter(RackDevice.id == ast.rack_device_id).first()
            if rdev and rdev.ip_address == ip_rec.ip_address:
                rdev.ip_address = None
        if ast.floor_device_id and ip_rec.is_heartbeat_ip:
            fdev = db.query(FloorDevice).filter(FloorDevice.id == ast.floor_device_id).first()
            if fdev and fdev.ip_address == ip_rec.ip_address:
                fdev.ip_address = None
    db.delete(ip_rec)
    db.commit()
    sync_prometheus_targets_file(db)
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
            location_id=payload.location_id,
            items=[item.model_dump() for item in payload.items],
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@api_router.get(
    "/cmdb/check-ip-owner",
    tags=["CMDB, Multi-IP & IP Verification"],
    summary="Comprobar si una IP ya está asignada en CMDB o Rack Editor antes de guardar",
)
def check_cmdb_ip_owner_endpoint(
    ip: str,
    exclude_asset_id: Optional[int] = None,
    exclude_rack_device_id: Optional[int] = None,
    exclude_floor_device_id: Optional[int] = None,
    db: Session = Depends(get_db),
):
    return check_ip_collision_in_cmdb(
        db=db,
        ip_address=ip,
        exclude_asset_id=exclude_asset_id,
        exclude_rack_device_id=exclude_rack_device_id,
        exclude_floor_device_id=exclude_floor_device_id,
    )


@api_router.post(
    "/cmdb/resolve-ip-collision",
    tags=["CMDB, Multi-IP & IP Verification"],
    summary="Resolver una colisión de IP unificando equipos (Rack Editor + CMDB) o reasignando/liberando la IP",
)
def resolve_cmdb_ip_collision_endpoint(
    payload: dict,
    db: Session = Depends(get_db),
):
    try:
        return resolve_cmdb_ip_collision(
            db=db,
            ip_address=str(payload.get("ip_address") or ""),
            action=str(payload.get("action") or "merge"),
            keep_asset_id=int(payload["keep_asset_id"]),
            other_asset_id=int(payload["other_asset_id"]),
            new_ip_for_other=str(payload.get("new_ip_for_other") or ""),
            preferred_name=str(payload.get("preferred_name") or ""),
            preferred_hostname=str(payload.get("preferred_hostname") or ""),
            preferred_fqdn=str(payload.get("preferred_fqdn") or ""),
        )
    except (ValueError, KeyError) as exc:
        raise HTTPException(status_code=400, detail=str(exc))
