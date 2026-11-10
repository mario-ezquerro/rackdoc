"""Red y Host: topología lógica, chequeos Nagios, SNMP, avisos y tech-stacks."""

from datetime import datetime
from fastapi import Depends, HTTPException
from sqlalchemy.orm import Session, joinedload
from typing import Optional

from ..database import get_db
from ..models import AlertContact, AlertContactGroup, CmdbAsset, HostGroup, InfraConnector, LogicalTopologyLink, MaintenanceWindow, MonitoredServiceCheck, NotificationRoutingRule, SmtpAlertConfig, TechStackDiagram, TechStackEdge, TechStackNode
from ..schemas import AlertContactGroupInput, AlertContactInput, AnsibleHostUpsertWebhook, HostGroupInput, HostSshCommandInput, InfraConnectorInput, LogicalLinkInput, MaintenanceWindowInput, NotificationRoutingRuleInput, ServiceCheckInput, SmtpAlertConfigInput, SnmpWalkDiscoveryRequest, TechStackDiagramInput, TechStackDiagramUpdateInput, TechStackEdgeInput, TechStackEdgeUpdateInput, TechStackNodeInput, TechStackNodeMoveInput
from ..routers._common import api_router
from ..services.network_host_service import _dispatch_alert_notification, build_network_hosts_overview, ensure_network_hosts_seeded, evaluate_all_network_service_checks, execute_host_ssh_diagnostic, get_asset_telemetry_timeseries, handle_ansible_host_upsert_webhook, run_single_service_check, run_snmp_switch_discovery, sync_prometheus_targets_file

@api_router.get(
    "/network-hosts/overview",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Estado consolidado de '4. Red & Host' (Topología Lógica en 5 Capas + Nagios + SNMP + Conectores + Avisos)",
)
def get_network_hosts_overview_endpoint(db: Session = Depends(get_db)):
    return build_network_hosts_overview(db)


@api_router.get(
    "/network-hosts/telemetry/{asset_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Obtener series temporales desde Prometheus TSDB para gráficas de un Host/VM/Switch",
)
def get_network_host_telemetry_endpoint(
    asset_id: int,
    range_hours: int = 6,
    db: Session = Depends(get_db),
):
    try:
        return get_asset_telemetry_timeseries(db=db, asset_id=asset_id, range_hours=range_hours)
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc))


@api_router.post(
    "/network-hosts/hosts",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Dar de alta desde la Web una nueva Máquina Virtual / Host / Contenedor con sus IPs, Hipervisor Padre y Servicios a Monitorizar",
    description=(
        "Asistente Todo-en-Uno: registra la nueva Máquina Virtual, Contenedor o Servidor en '4. Red & Host' y en '6. CMDB', "
        "asigna su IP primaria de Heartbeat y sus IPs adicionales, la enlaza en el Diagrama Lógico a su Hipervisor/Servidor del Rack, "
        "la añade a los HostGroups indicados, crea todos sus servicios/exporters (HTTPS+SSL, Apache, Nginx, Docker, PostgreSQL, SSH, "
        "Node/Windows Exporter) y actualiza al instante Prometheus SD."
    ),
)
def create_network_host_with_services_endpoint(
    payload: AnsibleHostUpsertWebhook,
    db: Session = Depends(get_db),
):
    try:
        res = handle_ansible_host_upsert_webhook(db=db, payload=payload.model_dump())
        return {
            "created_host": res,
            "overview": build_network_hosts_overview(db),
        }
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@api_router.post(
    "/network-hosts/service-checks",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Añadir un nuevo Heartbeat o Chequeo de Servicio (HTTP, HTTPS+SSL, ICMP, TCP, SSH, SNMP, Apache, Nginx, Docker, BBDD)",
)
def create_service_check_endpoint(payload: ServiceCheckInput, db: Session = Depends(get_db)):
    asset = db.query(CmdbAsset).filter(CmdbAsset.id == payload.asset_id).first()
    if not asset:
        raise HTTPException(status_code=404, detail="El Host/VM indicado no existe.")
    chk = MonitoredServiceCheck(
        asset_id=payload.asset_id,
        service_name=payload.service_name.strip(),
        check_type=payload.check_type.strip().lower(),
        target_ip_or_url=payload.target_ip_or_url.strip(),
        port=payload.port,
        expected_status_code=payload.expected_status_code,
        expected_string=payload.expected_string,
        max_check_attempts=max(1, payload.max_check_attempts),
        check_config=payload.check_config or {},
        is_primary_heartbeat=payload.is_primary_heartbeat,
        nagios_state="OK",
        state_type="HARD",
        current_attempt=1,
        enabled=payload.enabled,
        last_checked_at=datetime.utcnow(),
        last_state_change_at=datetime.utcnow(),
    )
    db.add(chk)
    db.commit()
    db.refresh(chk)
    run_single_service_check(db=db, chk=chk, asset=asset)
    sync_prometheus_targets_file(db)
    return build_network_hosts_overview(db)


@api_router.delete(
    "/network-hosts/service-checks/{check_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Eliminar un Heartbeat o Chequeo de Servicio",
)
def delete_service_check_endpoint(check_id: int, db: Session = Depends(get_db)):
    chk = db.query(MonitoredServiceCheck).filter(MonitoredServiceCheck.id == check_id).first()
    if not chk:
        raise HTTPException(status_code=404, detail="Chequeo no encontrado.")
    db.delete(chk)
    db.commit()
    sync_prometheus_targets_file(db)
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/service-checks/{check_id}/run",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Ejecutar al instante un chequeo de servicio o Heartbeat concreto",
)
def run_single_service_check_endpoint(check_id: int, db: Session = Depends(get_db)):
    chk = db.query(MonitoredServiceCheck).filter(MonitoredServiceCheck.id == check_id).first()
    if not chk:
        raise HTTPException(status_code=404, detail="Chequeo no encontrado.")
    asset = db.query(CmdbAsset).options(joinedload(CmdbAsset.ip_addresses)).filter(CmdbAsset.id == chk.asset_id).first()
    if not asset:
        raise HTTPException(status_code=404, detail="Host asociado no encontrado.")
    res = run_single_service_check(db=db, chk=chk, asset=asset)
    return {"check_result": res, "overview": build_network_hosts_overview(db)}


@api_router.post(
    "/network-hosts/run-all-checks",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Ejecutar todos los Heartbeats y Chequeos de Servicio activos en lote",
)
def run_all_service_checks_endpoint(db: Session = Depends(get_db)):
    batch = evaluate_all_network_service_checks(db)
    return {"batch": batch, "overview": build_network_hosts_overview(db)}


@api_router.post(
    "/network-hosts/snmp-discover",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Autodescubrimiento de Switch por SNMP (IF-MIB + LLDP-MIB) sin dar de alta puerto a puerto",
    description=(
        "Interroga un Switch o Router por SNMPv2c/v3, descubre todas sus bocas físicas, velocidades, alias, VLANs, "
        "tráfico In/Out y vecinos LLDP, y sincroniza las bocas con el dispositivo físico del Rack Editor."
    ),
)
def snmp_switch_discover_endpoint(payload: SnmpWalkDiscoveryRequest, db: Session = Depends(get_db)):
    res = run_snmp_switch_discovery(
        db=db,
        target_ip=payload.target_ip,
        community=payload.community,
        snmp_version=payload.snmp_version,
        port=payload.port,
        asset_id=payload.asset_id,
        rack_device_id=payload.rack_device_id,
        sync_ports_to_rack_device=payload.sync_ports_to_rack_device,
    )
    return {"discovery": res, "overview": build_network_hosts_overview(db)}


@api_router.post(
    "/network-hosts/logical-links",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Añadir un Enlace Lógico de Conexión en el Diagrama Lógico",
)
def create_logical_link_endpoint(payload: LogicalLinkInput, db: Session = Depends(get_db)):
    if payload.source_asset_id == payload.target_asset_id:
        raise HTTPException(status_code=400, detail="El nodo origen y destino deben ser distintos.")
    lnk = LogicalTopologyLink(
        source_asset_id=payload.source_asset_id,
        target_asset_id=payload.target_asset_id,
        link_type=payload.link_type,
        source_interface=payload.source_interface,
        target_interface=payload.target_interface,
        protocol_label=payload.protocol_label,
        vlan_id=payload.vlan_id,
        bandwidth_mbps=payload.bandwidth_mbps,
        status="UP",
        auto_discovered=False,
        notes=payload.notes,
    )
    db.add(lnk)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.delete(
    "/network-hosts/logical-links/{link_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Eliminar un Enlace Lógico del Diagrama",
)
def delete_logical_link_endpoint(link_id: int, db: Session = Depends(get_db)):
    lnk = db.query(LogicalTopologyLink).filter(LogicalTopologyLink.id == link_id).first()
    if not lnk:
        raise HTTPException(status_code=404, detail="Enlace lógico no encontrado.")
    db.delete(lnk)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/connectors",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Registrar un nuevo Conector de Infraestructura (Proxmox, VMware, Docker, Apache, Nginx, PostgreSQL, MySQL, SNMP, Exporters)",
)
def create_infra_connector_endpoint(payload: InfraConnectorInput, db: Session = Depends(get_db)):
    conn = InfraConnector(
        name=payload.name.strip(),
        connector_type=payload.connector_type.strip(),
        endpoint_host=payload.endpoint_host.strip(),
        endpoint_port=payload.endpoint_port,
        auth_username_or_community=payload.auth_username_or_community,
        auth_secret=payload.auth_secret,
        linked_asset_id=payload.linked_asset_id,
        linked_rack_device_id=payload.linked_rack_device_id,
        extra_settings=payload.extra_settings or {},
        enabled=payload.enabled,
        last_sync_status="ok",
        last_sync_at=datetime.utcnow(),
        last_sync_summary=f"Conector {payload.connector_type} registrado y sincronizado con Prometheus.",
        discovered_items_count=1,
    )
    db.add(conn)
    db.commit()
    sync_prometheus_targets_file(db)
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/connectors/{connector_id}/sync",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Sincronizar al instante un Conector de Infraestructura (Proxmox, VMware, Docker, Apache, Nginx, SNMP...)",
)
def sync_infra_connector_endpoint(connector_id: int, db: Session = Depends(get_db)):
    conn = db.query(InfraConnector).filter(InfraConnector.id == connector_id).first()
    if not conn:
        raise HTTPException(status_code=404, detail="Conector no encontrado.")
    if conn.connector_type == "snmp_switch":
        disc = run_snmp_switch_discovery(
            db=db,
            target_ip=conn.endpoint_host,
            community=conn.auth_username_or_community or "public",
            port=conn.endpoint_port or 161,
            asset_id=conn.linked_asset_id,
            rack_device_id=conn.linked_rack_device_id,
        )
        conn.last_sync_status = "ok"
        conn.last_sync_at = datetime.utcnow()
        conn.discovered_items_count = disc["discovered_ports_count"]
        conn.last_sync_summary = (
            f"SNMP Walk completado ({conn.endpoint_host}): {disc['discovered_ports_count']} bocas IF-MIB "
            f"y {disc['lldp_neighbors_count']} vecinos LLDP sincronizados."
        )
    else:
        conn.last_sync_status = "ok"
        conn.last_sync_at = datetime.utcnow()
    db.commit()
    sync_prometheus_targets_file(db)
    return build_network_hosts_overview(db)


@api_router.delete(
    "/network-hosts/connectors/{connector_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Eliminar un Conector de Infraestructura",
)
def delete_infra_connector_endpoint(connector_id: int, db: Session = Depends(get_db)):
    conn = db.query(InfraConnector).filter(InfraConnector.id == connector_id).first()
    if not conn:
        raise HTTPException(status_code=404, detail="Conector no encontrado.")
    db.delete(conn)
    db.commit()
    sync_prometheus_targets_file(db)
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/host-groups",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Crear o actualizar un Grupo de Hosts / Equipos (HostGroup)",
)
def create_or_update_host_group_endpoint(payload: HostGroupInput, db: Session = Depends(get_db)):
    code = payload.code.strip().upper()
    hg = db.query(HostGroup).filter(HostGroup.code == code).first()
    if not hg:
        hg = HostGroup(code=code)
        db.add(hg)
    hg.name = payload.name.strip()
    hg.category = payload.category
    hg.environment = payload.environment
    hg.color_hex = payload.color_hex
    hg.member_asset_ids = payload.member_asset_ids
    hg.description = payload.description
    db.commit()
    return build_network_hosts_overview(db)


@api_router.delete(
    "/network-hosts/host-groups/{group_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Eliminar un Grupo de Hosts (HostGroup)",
)
def delete_host_group_endpoint(group_id: int, db: Session = Depends(get_db)):
    hg = db.query(HostGroup).filter(HostGroup.id == group_id).first()
    if not hg:
        raise HTTPException(status_code=404, detail="Grupo de hosts no encontrado.")
    db.delete(hg)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/alert-contacts",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Crear o actualizar una Persona / Contacto de Alarma (AlertContact)",
)
def create_or_update_alert_contact_endpoint(payload: AlertContactInput, db: Session = Depends(get_db)):
    code = payload.code.strip().upper()
    c = db.query(AlertContact).filter(AlertContact.code == code).first()
    if not c:
        c = AlertContact(code=code)
        db.add(c)
    c.full_name = payload.full_name.strip()
    c.role_title = payload.role_title
    c.email = payload.email.strip()
    c.phone_or_telegram = payload.phone_or_telegram
    c.personal_webhook_url = payload.personal_webhook_url
    c.schedule_period = payload.schedule_period
    c.notify_on_down = payload.notify_on_down
    c.notify_on_critical = payload.notify_on_critical
    c.notify_on_warning = payload.notify_on_warning
    c.notify_on_unreachable = payload.notify_on_unreachable
    c.notify_on_recovery = payload.notify_on_recovery
    c.active = payload.active
    db.commit()
    return build_network_hosts_overview(db)


@api_router.delete(
    "/network-hosts/alert-contacts/{contact_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Eliminar una Persona / Contacto de Alarma",
)
def delete_alert_contact_endpoint(contact_id: int, db: Session = Depends(get_db)):
    c = db.query(AlertContact).filter(AlertContact.id == contact_id).first()
    if not c:
        raise HTTPException(status_code=404, detail="Contacto no encontrado.")
    db.delete(c)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/alert-contact-groups",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Crear o actualizar un Grupo de Personas / Equipo de Guardia (AlertContactGroup)",
)
def create_or_update_alert_contact_group_endpoint(payload: AlertContactGroupInput, db: Session = Depends(get_db)):
    code = payload.code.strip().upper()
    cg = db.query(AlertContactGroup).filter(AlertContactGroup.code == code).first()
    if not cg:
        cg = AlertContactGroup(code=code)
        db.add(cg)
    cg.name = payload.name.strip()
    cg.description = payload.description
    cg.group_email = payload.group_email.strip()
    cg.channel_webhook_url = payload.channel_webhook_url.strip()
    cg.member_contact_ids = payload.member_contact_ids
    db.commit()
    return build_network_hosts_overview(db)


@api_router.delete(
    "/network-hosts/alert-contact-groups/{group_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Eliminar un Grupo de Personas (AlertContactGroup)",
)
def delete_alert_contact_group_endpoint(group_id: int, db: Session = Depends(get_db)):
    cg = db.query(AlertContactGroup).filter(AlertContactGroup.id == group_id).first()
    if not cg:
        raise HTTPException(status_code=404, detail="Grupo de personas no encontrado.")
    db.delete(cg)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/notification-rules",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Crear o actualizar una Regla de Enrutamiento de Avisos (Host / HostGroup -> Persona / ContactGroup)",
)
def create_notification_rule_endpoint(payload: NotificationRoutingRuleInput, db: Session = Depends(get_db)):
    existing = None
    if payload.scope_type == "host_group" and payload.host_group_id:
        existing = (
            db.query(NotificationRoutingRule)
            .filter(
                NotificationRoutingRule.scope_type == "host_group",
                NotificationRoutingRule.host_group_id == payload.host_group_id,
            )
            .first()
        )
    elif payload.scope_type == "single_host" and payload.asset_id:
        existing = (
            db.query(NotificationRoutingRule)
            .filter(
                NotificationRoutingRule.scope_type == "single_host",
                NotificationRoutingRule.asset_id == payload.asset_id,
            )
            .first()
        )

    is_replace = (payload.description or "").strip() == "__REPLACE__"
    clean_desc = "" if is_replace else (payload.description or "")

    if existing:
        if is_replace:
            new_cg_ids = list(dict.fromkeys(payload.contact_group_ids or []))
            new_c_ids = list(dict.fromkeys(payload.contact_ids or []))
            if not new_cg_ids and not new_c_ids:
                db.delete(existing)
                db.commit()
                return build_network_hosts_overview(db)
            existing.contact_group_ids = new_cg_ids
            existing.contact_ids = new_c_ids
        else:
            merged_cg = list(existing.contact_group_ids or [])
            for gid in (payload.contact_group_ids or []):
                if gid not in merged_cg:
                    merged_cg.append(gid)
            merged_c = list(existing.contact_ids or [])
            for cid in (payload.contact_ids or []):
                if cid not in merged_c:
                    merged_c.append(cid)
            existing.contact_group_ids = merged_cg
            existing.contact_ids = merged_c
        if payload.name and payload.name.strip():
            existing.name = payload.name.strip()
        if clean_desc:
            existing.description = clean_desc
        existing.enabled = payload.enabled
        existing.send_email = payload.send_email
        existing.send_webhook = payload.send_webhook
        existing.only_on_hard_state = payload.only_on_hard_state
        db.commit()
        return build_network_hosts_overview(db)

    if is_replace and not (payload.contact_group_ids or []) and not (payload.contact_ids or []):
        return build_network_hosts_overview(db)

    rule = NotificationRoutingRule(
        name=payload.name.strip(),
        description=clean_desc,
        enabled=payload.enabled,
        scope_type=payload.scope_type,
        host_group_id=payload.host_group_id,
        asset_id=payload.asset_id,
        asset_class_filter=payload.asset_class_filter,
        contact_group_ids=list(dict.fromkeys(payload.contact_group_ids or [])),
        contact_ids=list(dict.fromkeys(payload.contact_ids or [])),
        send_email=payload.send_email,
        send_webhook=payload.send_webhook,
        only_on_hard_state=payload.only_on_hard_state,
    )
    db.add(rule)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.delete(
    "/network-hosts/notification-rules/{rule_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Eliminar una Regla de Enrutamiento de Avisos",
)
def delete_notification_rule_endpoint(rule_id: int, db: Session = Depends(get_db)):
    rule = db.query(NotificationRoutingRule).filter(NotificationRoutingRule.id == rule_id).first()
    if not rule:
        raise HTTPException(status_code=404, detail="Regla no encontrada.")
    db.delete(rule)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/maintenance-windows",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Activar una Ventana de Mantenimiento programada o manual para silenciar alertas",
)
def create_maintenance_window_endpoint(payload: MaintenanceWindowInput, db: Session = Depends(get_db)):
    from datetime import timedelta as _timedelta

    now = datetime.utcnow()
    win = MaintenanceWindow(
        title=payload.title.strip(),
        reason=payload.reason,
        created_by=payload.created_by,
        scope_type=payload.scope_type,
        asset_id=payload.asset_id,
        host_group_id=payload.host_group_id,
        target_matches=payload.target_matches,
        starts_at=now,
        ends_at=now + _timedelta(minutes=max(1, payload.duration_minutes)),
        is_active=True,
        suppress_notifications=payload.suppress_notifications,
    )
    db.add(win)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/maintenance-windows/{window_id}/stop",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Finalizar una Ventana de Mantenimiento activa y reactivar avisos",
)
def stop_maintenance_window_endpoint(window_id: int, db: Session = Depends(get_db)):
    win = db.query(MaintenanceWindow).filter(MaintenanceWindow.id == window_id).first()
    if not win:
        raise HTTPException(status_code=404, detail="Ventana de mantenimiento no encontrada.")
    win.is_active = False
    win.ends_at = datetime.utcnow()
    db.commit()
    return build_network_hosts_overview(db)


@api_router.put(
    "/network-hosts/smtp-config",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Actualizar configuración del Servidor de Correo SMTP y Webhook global de Avisos",
)
def update_smtp_config_endpoint(payload: SmtpAlertConfigInput, db: Session = Depends(get_db)):
    cfg = db.query(SmtpAlertConfig).first()
    if not cfg:
        cfg = SmtpAlertConfig()
        db.add(cfg)
    cfg.smtp_host = payload.smtp_host.strip()
    cfg.smtp_port = payload.smtp_port
    cfg.use_tls = payload.use_tls
    cfg.smtp_username = payload.smtp_username.strip()
    if payload.smtp_password:
        cfg.smtp_password = payload.smtp_password
    cfg.from_email = payload.from_email.strip()
    cfg.global_webhook_url = payload.global_webhook_url.strip()
    cfg.enabled = payload.enabled
    db.commit()
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/test-alert",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Disparar un aviso de prueba para verificar el enrutamiento de correos/webhooks por Host o HostGroup",
)
def trigger_test_alert_endpoint(asset_id: Optional[int] = None, db: Session = Depends(get_db)):
    ensure_network_hosts_seeded(db)
    asset = (
        db.query(CmdbAsset).filter(CmdbAsset.id == asset_id).first()
        if asset_id
        else db.query(CmdbAsset).order_by(CmdbAsset.id).first()
    )
    if not asset:
        raise HTTPException(status_code=404, detail="No hay activos disponibles para probar la alerta.")
    _dispatch_alert_notification(
        db=db,
        asset=asset,
        service_name="Prueba Manual de Enrutamiento de Alarma",
        event_state="HARD CRITICAL (TEST)",
        detail=f"Simulación manual de alerta sobre {asset.code} ({asset.name}) para verificar destinatarios.",
    )
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/tech-stacks",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Crear o actualizar un Esquema de Lógica de Negocio / Stack Tecnológico",
)
def upsert_tech_stack_diagram_endpoint(payload: TechStackDiagramInput, db: Session = Depends(get_db)):
    code = payload.code.strip().upper()
    st = db.query(TechStackDiagram).filter(TechStackDiagram.code == code).first()
    if not st:
        st = TechStackDiagram(code=code, canvas_boxes=payload.canvas_boxes or [])
        db.add(st)
    st.name = payload.name.strip()
    st.description = payload.description.strip()
    st.business_service = payload.business_service.strip()
    st.environment = payload.environment.strip()
    st.owner_team = payload.owner_team.strip()
    st.criticality = payload.criticality.strip()
    st.map_scale = payload.map_scale or 1.0
    if payload.canvas_boxes is not None:
        st.canvas_boxes = payload.canvas_boxes
    db.commit()
    return build_network_hosts_overview(db)


@api_router.put(
    "/network-hosts/tech-stacks/{stack_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Actualizar Cajas/Zonas delimitadoras, escala o metadatos de un Stack Tecnológico",
)
def update_tech_stack_diagram_endpoint(
    stack_id: int,
    payload: TechStackDiagramUpdateInput,
    db: Session = Depends(get_db),
):
    st = db.query(TechStackDiagram).filter(TechStackDiagram.id == stack_id).first()
    if not st:
        raise HTTPException(status_code=404, detail="Stack Tecnológico no encontrado.")
    if payload.name is not None:
        st.name = payload.name.strip()
    if payload.description is not None:
        st.description = payload.description.strip()
    if payload.business_service is not None:
        st.business_service = payload.business_service.strip()
    if payload.environment is not None:
        st.environment = payload.environment.strip()
    if payload.owner_team is not None:
        st.owner_team = payload.owner_team.strip()
    if payload.criticality is not None:
        st.criticality = payload.criticality.strip()
    if payload.map_scale is not None:
        st.map_scale = max(0.4, min(2.5, payload.map_scale))
    if payload.canvas_boxes is not None:
        st.canvas_boxes = list(payload.canvas_boxes)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.delete(
    "/network-hosts/tech-stacks/{stack_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Eliminar un Stack Tecnológico",
)
def delete_tech_stack_diagram_endpoint(stack_id: int, db: Session = Depends(get_db)):
    st = db.query(TechStackDiagram).filter(TechStackDiagram.id == stack_id).first()
    if not st:
        raise HTTPException(status_code=404, detail="Stack Tecnológico no encontrado.")
    db.query(TechStackEdge).filter(TechStackEdge.stack_id == stack_id).delete()
    db.query(TechStackNode).filter(TechStackNode.stack_id == stack_id).delete()
    db.delete(st)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/tech-stacks/nodes",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Añadir un Host / VM / Frontal Web / BBDD al lienzo de un Stack Tecnológico",
)
def create_tech_stack_node_endpoint(payload: TechStackNodeInput, db: Session = Depends(get_db)):
    sn = TechStackNode(
        stack_id=payload.stack_id,
        asset_id=payload.asset_id,
        role_layer=payload.role_layer,
        custom_label=payload.custom_label.strip(),
        pos_x=max(0.01, min(0.95, payload.pos_x)),
        pos_y=max(0.01, min(0.94, payload.pos_y)),
        width_px=max(140.0, min(520.0, payload.width_px or 236.0)),
        height_px=max(82.0, min(360.0, payload.height_px or 134.0)),
        ssh_enabled=payload.ssh_enabled,
        ssh_user=payload.ssh_user.strip() or "root",
        ssh_port=payload.ssh_port or 22,
    )
    db.add(sn)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.put(
    "/network-hosts/tech-stacks/nodes/{node_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Mover (Drag & Drop X/Y), redimensionar o editar un nodo dentro del lienzo del Stack Tecnológico",
)
def move_tech_stack_node_endpoint(
    node_id: int,
    payload: TechStackNodeMoveInput,
    db: Session = Depends(get_db),
):
    sn = db.query(TechStackNode).filter(TechStackNode.id == node_id).first()
    if not sn:
        raise HTTPException(status_code=404, detail="Nodo del stack no encontrado.")
    if payload.pos_x is not None:
        sn.pos_x = max(0.01, min(0.95, payload.pos_x))
    if payload.pos_y is not None:
        sn.pos_y = max(0.01, min(0.94, payload.pos_y))
    if payload.width_px is not None:
        sn.width_px = max(140.0, min(520.0, payload.width_px))
    if payload.height_px is not None:
        sn.height_px = max(82.0, min(360.0, payload.height_px))
    if payload.role_layer is not None:
        sn.role_layer = payload.role_layer
    if payload.custom_label is not None:
        sn.custom_label = payload.custom_label.strip()
    if payload.ssh_enabled is not None:
        sn.ssh_enabled = payload.ssh_enabled
    if payload.ssh_user is not None:
        sn.ssh_user = payload.ssh_user.strip()
    if payload.ssh_port is not None:
        sn.ssh_port = payload.ssh_port
    db.commit()
    return build_network_hosts_overview(db)


@api_router.delete(
    "/network-hosts/tech-stacks/nodes/{node_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Quitar un nodo del lienzo del Stack Tecnológico",
)
def delete_tech_stack_node_endpoint(node_id: int, db: Session = Depends(get_db)):
    sn = db.query(TechStackNode).filter(TechStackNode.id == node_id).first()
    if not sn:
        raise HTTPException(status_code=404, detail="Nodo del stack no encontrado.")
    db.query(TechStackEdge).filter(
        (TechStackEdge.source_node_id == node_id) | (TechStackEdge.target_node_id == node_id)
    ).delete()
    db.delete(sn)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/tech-stacks/edges",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Dibujar una flecha / flujo de lógica de negocio entre dos nodos de un Stack Tecnológico",
)
def create_tech_stack_edge_endpoint(payload: TechStackEdgeInput, db: Session = Depends(get_db)):
    if payload.source_node_id == payload.target_node_id:
        raise HTTPException(status_code=400, detail="El nodo origen y destino deben ser distintos.")
    existing = (
        db.query(TechStackEdge)
        .filter(
            TechStackEdge.stack_id == payload.stack_id,
            TechStackEdge.source_node_id == payload.source_node_id,
            TechStackEdge.target_node_id == payload.target_node_id,
        )
        .first()
    )
    if existing:
        existing.protocol_label = payload.protocol_label.strip()
        existing.port = payload.port
        existing.notes = payload.notes
    else:
        se = TechStackEdge(
            stack_id=payload.stack_id,
            source_node_id=payload.source_node_id,
            target_node_id=payload.target_node_id,
            protocol_label=payload.protocol_label.strip(),
            port=payload.port,
            notes=payload.notes,
        )
        db.add(se)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.put(
    "/network-hosts/tech-stacks/edges/{edge_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Editar protocolo, puerto o notas de una flecha del Stack Tecnológico",
)
def update_tech_stack_edge_endpoint(
    edge_id: int,
    payload: TechStackEdgeUpdateInput,
    db: Session = Depends(get_db),
):
    se = db.query(TechStackEdge).filter(TechStackEdge.id == edge_id).first()
    if not se:
        raise HTTPException(status_code=404, detail="Conexión no encontrada.")
    if payload.protocol_label is not None:
        se.protocol_label = payload.protocol_label.strip()
    if payload.port is not None:
        se.port = payload.port
    if payload.notes is not None:
        se.notes = payload.notes
    db.commit()
    return build_network_hosts_overview(db)


@api_router.delete(
    "/network-hosts/tech-stacks/edges/{edge_id}",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Eliminar una flecha del Stack Tecnológico",
)
def delete_tech_stack_edge_endpoint(edge_id: int, db: Session = Depends(get_db)):
    se = db.query(TechStackEdge).filter(TechStackEdge.id == edge_id).first()
    if not se:
        raise HTTPException(status_code=404, detail="Conexión no encontrada.")
    db.delete(se)
    db.commit()
    return build_network_hosts_overview(db)


@api_router.post(
    "/network-hosts/ssh-console",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Ejecutar comando de diagnóstico remoto / consola SSH sobre un Host o VM del Stack",
)
def execute_host_ssh_console_endpoint(payload: HostSshCommandInput, db: Session = Depends(get_db)):
    try:
        return execute_host_ssh_diagnostic(
            db=db,
            asset_id=payload.asset_id,
            command=payload.command,
            ssh_user=payload.ssh_user,
            ssh_port=payload.ssh_port,
        )
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc))
