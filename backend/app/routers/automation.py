"""Métricas Prometheus y API de automatización (Ansible, CI/CD y agentes de IA)."""

from fastapi import Depends, HTTPException
from fastapi.responses import Response
from sqlalchemy.orm import Session

from ..database import get_db
from ..schemas import AnsibleContactsRoutingWebhook, AnsibleHostDecommissionWebhook, AnsibleHostUpsertWebhook, AnsibleMaintenanceWebhook
from ..routers._common import automation_router
from ..services.network_host_service import build_ai_agent_context_manifest, generate_prometheus_metrics_exposition, handle_ansible_contacts_routing_webhook, handle_ansible_host_decommission_webhook, handle_ansible_host_upsert_webhook, handle_ansible_maintenance_webhook

# ==============================================================================
# MÓDULO 4: RED & HOST (TOPOLOGÍA LÓGICA, NAGIOS, SNMP, CONECTORES Y PROMETHEUS)
# ==============================================================================

@automation_router.get(
    "/metrics",
    tags=["Red & Host (Topología Lógica, Nagios, SNMP & Prometheus)"],
    summary="Exposición nativa de métricas en formato Prometheus Text Exposition Format",
    description=(
        "Endpoint consumido cada 15 segundos por el contenedor 'rackdoc-prometheus' (:9090). "
        "Expone el estado operativo de cada Host/VM/Switch, latencia de Heartbeat (ms), CPU %, RAM %, Disco %, "
        "estados Nagios de servicios (OK/WARNING/CRITICAL/UNKNOWN), validez de certificados SSL y tráfico por boca de Switch."
    ),
)
def get_prometheus_metrics_endpoint(db: Session = Depends(get_db)):
    content = generate_prometheus_metrics_exposition(db)
    return Response(content=content, media_type="text/plain; version=0.0.4; charset=utf-8")


# ==============================================================================
# WEBHOOKS DE AUTOMATIZACIÓN ANSIBLE, CI/CD Y AGENTES DE IA (/api/v1/automation/*)
# ==============================================================================

@automation_router.post(
    "/automation/webhook/host-upsert",
    tags=["Automation Webhooks (Ansible, CI/CD & AI Agents)"],
    summary="Webhook Ansible: Alta o actualización automática de Host, IPs, Exporters, Heartbeats y Prometheus SD",
    description=(
        "Permite que un Playbook de Ansible registre o actualice una máquina física o virtual, asigne sus IPs en la CMDB, "
        "la asocie a HostGroups, registre sus Exporters (node_exporter, windows_exporter, apache, nginx, docker) "
        "y regenere al instante el fichero 'targets_dynamic.json' de Prometheus."
    ),
)
def ansible_host_upsert_webhook_endpoint(
    payload: AnsibleHostUpsertWebhook,
    db: Session = Depends(get_db),
):
    try:
        return handle_ansible_host_upsert_webhook(db=db, payload=payload.model_dump())
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@automation_router.post(
    "/automation/webhook/host-decommission",
    tags=["Automation Webhooks (Ansible, CI/CD & AI Agents)"],
    summary="Webhook Ansible: Baja automática de Host/VM y retirada de Prometheus SD",
)
def ansible_host_decommission_webhook_endpoint(
    payload: AnsibleHostDecommissionWebhook,
    db: Session = Depends(get_db),
):
    try:
        return handle_ansible_host_decommission_webhook(db=db, payload=payload.model_dump())
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc))


@automation_router.post(
    "/automation/webhook/maintenance",
    tags=["Automation Webhooks (Ansible, CI/CD & AI Agents)"],
    summary="Webhook Ansible: Iniciar ('start') o finalizar ('stop') Ventana de Mantenimiento silenciosa",
)
def ansible_maintenance_webhook_endpoint(
    payload: AnsibleMaintenanceWebhook,
    db: Session = Depends(get_db),
):
    return handle_ansible_maintenance_webhook(db=db, payload=payload.model_dump())


@automation_router.post(
    "/automation/webhook/contacts-and-routing",
    tags=["Automation Webhooks (Ansible, CI/CD & AI Agents)"],
    summary="Webhook Ansible: Sincronizar Personas, Grupos de Personas y Reglas de Alarma como Código",
)
def ansible_contacts_routing_webhook_endpoint(
    payload: AnsibleContactsRoutingWebhook,
    db: Session = Depends(get_db),
):
    return handle_ansible_contacts_routing_webhook(db=db, payload=payload.model_dump())


@automation_router.get(
    "/automation/ai-context",
    tags=["Automation Webhooks (Ansible, CI/CD & AI Agents)"],
    summary="Manifiesto estructurado JSON de Contexto para Agentes de IA y Automatización",
)
def get_ai_agent_context_endpoint(db: Session = Depends(get_db)):
    return build_ai_agent_context_manifest(db)
