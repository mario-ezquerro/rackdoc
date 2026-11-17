"""
Endpoints del Módulo 10: Agente IA Solo-Lectura y Documentador Automático (`RackDoc AI`),
Configuración en 9. Administración (Ollama Local por defecto + Proveedor Externo) y
API Solo-Lectura dedicada para el Servidor MCP (`rackdoc-mcp`).
"""

from typing import Optional

from fastapi import Depends, HTTPException, Query, Request
from sqlalchemy.orm import Session

from ..database import get_db
from ..models import AiGeneratedDocument, AiPassiveDiscoverySnapshot, User
from ..routers._common import ai_readonly_router, api_router
from ..schemas import (
    AiAgentSettingsUpdateInput,
    AiGenerateDocumentInput,
    AiMcpSaveDocumentInput,
    AiOllamaPullInput,
    AiPassiveHostAuditInput,
    AiPassiveSnmpWalkInput,
    AiPublishNetworkSchemaInput,
    AiReadonlyChatInput,
)
from ..security import get_current_user, require_role
from ..services.ai_network_schema_service import (
    build_analyzed_network_schema,
    publish_analyzed_schema_to_tech_stack,
)
from ..services.passive_discovery_service import (
    apply_passive_snapshot_to_topology,
    list_passive_discovery_snapshots,
    run_passive_host_audit_async,
    run_passive_snmp_walk_discovery,
)
from ..services.ai_agent_service import (
    build_ai_agent_overview,
    build_federated_readonly_snapshot,
    chat_readonly_with_infrastructure_async,
    generate_infrastructure_document_async,
    get_or_create_ai_settings,
    list_cmdb_suggestions,
    probe_ollama_status_async,
    pull_ollama_model_async,
    query_prometheus_readonly_instant,
    review_cmdb_suggestion,
    rotate_mcp_readonly_token,
    save_external_mcp_document,
    scan_and_create_cmdb_suggestions,
    serialize_ai_document,
    serialize_ai_settings,
    test_ai_provider_connection_async,
    update_ai_settings,
)


def _infer_base_url(request: Request) -> str:
    proto = request.headers.get("x-forwarded-proto") or request.url.scheme or "http"
    host = request.headers.get("x-forwarded-host") or request.headers.get("host") or "localhost:8180"
    return f"{proto}://{host}"


# ==============================================================================
# 1. ENDPOINTS DE ADMINISTRACIÓN DEL MOTOR IA (SOLO ROL `admin`)
# ==============================================================================


@api_router.get(
    "/ai-agent/settings",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="Obtener configuración del Motor IA (Ollama Local / Proveedor Externo) y estado MCP (solo Admin)",
)
async def get_ai_agent_settings_endpoint(
    request: Request,
    _user: User = Depends(require_role("admin")),
    db: Session = Depends(get_db),
):
    cfg = get_or_create_ai_settings(db)
    ollama_probe = await probe_ollama_status_async(db)
    return {
        "settings": serialize_ai_settings(cfg, base_backend_url=_infer_base_url(request)),
        "ollama_status": ollama_probe,
    }


@api_router.put(
    "/ai-agent/settings",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="Actualizar proveedor IA (Ollama Local por defecto o API Externa cifrada con Fernet)",
)
async def update_ai_agent_settings_endpoint(
    payload: AiAgentSettingsUpdateInput,
    request: Request,
    user: User = Depends(require_role("admin")),
    db: Session = Depends(get_db),
):
    try:
        cfg = update_ai_settings(
            db=db,
            payload=payload.model_dump(),
            updated_by=user.username or "admin",
        )
        ollama_probe = await probe_ollama_status_async(db)
        return {
            "settings": serialize_ai_settings(cfg, base_backend_url=_infer_base_url(request)),
            "ollama_status": ollama_probe,
        }
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@api_router.post(
    "/ai-agent/settings/test",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="Probar conectividad en vivo contra el modelo Ollama Local o Proveedor Externo configurado",
)
async def test_ai_agent_provider_endpoint(
    _user: User = Depends(require_role("admin")),
    db: Session = Depends(get_db),
):
    return await test_ai_provider_connection_async(db)


@api_router.post(
    "/ai-agent/settings/ollama/pull",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="Descargar (`ollama pull`) un modelo local en el contenedor `rackdoc-ollama`",
)
async def pull_ollama_model_endpoint(
    payload: AiOllamaPullInput,
    _user: User = Depends(require_role("admin")),
    db: Session = Depends(get_db),
):
    try:
        return await pull_ollama_model_async(db=db, model_name=payload.model_name)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc))


@api_router.post(
    "/ai-agent/settings/mcp-token/rotate",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="Generar o rotar el token `X-AI-Readonly-Key` para el Servidor MCP (`rackdoc-mcp`)",
)
def rotate_mcp_token_endpoint(
    request: Request,
    user: User = Depends(require_role("admin")),
    db: Session = Depends(get_db),
):
    return rotate_mcp_readonly_token(
        db=db,
        updated_by=user.username or "admin",
        base_backend_url=_infer_base_url(request),
    )


# ==============================================================================
# 2. MÓDULO 10 EN INTERFAZ WEB: AUDITORÍA, DOSSIERS, CHAT RO Y SUGERENCIAS CMDB
# ==============================================================================


@api_router.get(
    "/ai-agent/overview",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="Estado consolidado del Agente IA, hallazgos SPOF en vivo, biblioteca de documentos y sugerencias CMDB",
)
def get_ai_agent_overview_endpoint(
    request: Request,
    db: Session = Depends(get_db),
):
    return build_ai_agent_overview(db=db, base_backend_url=_infer_base_url(request))


@api_router.get(
    "/ai-agent/network-schema",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="Esquema Visual 2D en 5 Capas generado según los análisis (Racks + CMDB + SPOFs + Descubrimiento Pasivo RO)",
)
def get_ai_analyzed_network_schema_endpoint(
    scope_type: str = Query(default="global_cpd"),
    scope_target_id: Optional[int] = Query(default=None),
    db: Session = Depends(get_db),
):
    try:
        return build_analyzed_network_schema(
            db=db,
            scope_type=scope_type,
            scope_target_id=scope_target_id,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@api_router.post(
    "/ai-agent/network-schema/publish-stack",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="Publicar el esquema de red analizado como Stack Tecnológico 2D editable en 4. Red & Host (rol editor+)",
)
def publish_ai_network_schema_endpoint(
    payload: AiPublishNetworkSchemaInput,
    user: User = Depends(require_role("editor")),
    db: Session = Depends(get_db),
):
    try:
        return publish_analyzed_schema_to_tech_stack(
            db=db,
            scope_type=payload.scope_type,
            scope_target_id=payload.scope_target_id,
            stack_name=payload.stack_name,
            include_passive_ro_edges=payload.include_passive_ro_edges,
            published_by=user.username or "editor",
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@api_router.post(
    "/ai-agent/documents/generate",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="Analizar en modo lectura y generar Dossier Técnico Markdown + Mermaid",
)
async def generate_ai_document_endpoint(
    payload: AiGenerateDocumentInput,
    request: Request,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    try:
        created = await generate_infrastructure_document_async(
            db=db,
            scope_type=payload.scope_type,
            scope_target_id=payload.scope_target_id,
            custom_focus=payload.custom_focus,
            auto_propose_cmdb_suggestions=payload.auto_propose_cmdb_suggestions,
            created_by=user.username or "operator",
        )
        return {
            **created,
            "overview": build_ai_agent_overview(db=db, base_backend_url=_infer_base_url(request)),
        }
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@api_router.get(
    "/ai-agent/documents/{doc_id}",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="Leer el contenido completo Markdown + Mermaid de un documento generado",
)
def get_ai_document_detail_endpoint(
    doc_id: int,
    db: Session = Depends(get_db),
):
    doc = db.query(AiGeneratedDocument).filter(AiGeneratedDocument.id == doc_id).first()
    if not doc:
        raise HTTPException(status_code=404, detail="Documento IA no encontrado.")
    return serialize_ai_document(doc, include_markdown=True)


@api_router.delete(
    "/ai-agent/documents/{doc_id}",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="Eliminar un documento de la biblioteca IA (requiere rol editor o admin)",
)
def delete_ai_document_endpoint(
    doc_id: int,
    request: Request,
    db: Session = Depends(get_db),
):
    doc = db.query(AiGeneratedDocument).filter(AiGeneratedDocument.id == doc_id).first()
    if not doc:
        raise HTTPException(status_code=404, detail="Documento IA no encontrado.")
    db.delete(doc)
    db.commit()
    return {
        "deleted_id": doc_id,
        "overview": build_ai_agent_overview(db=db, base_backend_url=_infer_base_url(request)),
    }


@api_router.post(
    "/ai-agent/chat",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="Copiloto conversacional 100% Solo-Lectura contextualizado con el CPD real",
)
async def ai_readonly_chat_endpoint(
    payload: AiReadonlyChatInput,
    db: Session = Depends(get_db),
):
    try:
        return await chat_readonly_with_infrastructure_async(
            db=db,
            question=payload.question,
            scope_type=payload.scope_type,
            scope_target_id=payload.scope_target_id,
            history=[m.model_dump() for m in payload.history],
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@api_router.post(
    "/ai-agent/suggestions/scan",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="Escanear brechas documentales en CMDB y proponer borradores sin modificar activos",
)
def scan_cmdb_suggestions_endpoint(
    request: Request,
    db: Session = Depends(get_db),
):
    res = scan_and_create_cmdb_suggestions(db=db)
    return {
        **res,
        "overview": build_ai_agent_overview(db=db, base_backend_url=_infer_base_url(request)),
    }


@api_router.get(
    "/ai-agent/suggestions",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="Listar borradores de enriquecimiento CMDB (`pending`, `applied`, `dismissed`)",
)
def list_cmdb_suggestions_endpoint(
    status: str = Query(default="all"),
    db: Session = Depends(get_db),
):
    return {"suggestions": list_cmdb_suggestions(db=db, status_filter=status)}


@api_router.post(
    "/ai-agent/suggestions/{suggestion_id}/apply",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="Aprobar y aplicar una sugerencia documental sobre el activo CMDB (requiere rol editor+)",
)
def apply_cmdb_suggestion_endpoint(
    suggestion_id: int,
    request: Request,
    user: User = Depends(require_role("editor")),
    db: Session = Depends(get_db),
):
    try:
        reviewed = review_cmdb_suggestion(
            db=db,
            suggestion_id=suggestion_id,
            action="apply",
            reviewed_by=user.username or "editor",
        )
        return {
            "suggestion": reviewed,
            "overview": build_ai_agent_overview(db=db, base_backend_url=_infer_base_url(request)),
        }
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@api_router.post(
    "/ai-agent/suggestions/{suggestion_id}/dismiss",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="Descartar una sugerencia documental CMDB sin tocar el activo (requiere rol editor+)",
)
def dismiss_cmdb_suggestion_endpoint(
    suggestion_id: int,
    request: Request,
    user: User = Depends(require_role("editor")),
    db: Session = Depends(get_db),
):
    try:
        reviewed = review_cmdb_suggestion(
            db=db,
            suggestion_id=suggestion_id,
            action="dismiss",
            reviewed_by=user.username or "editor",
        )
        return {
            "suggestion": reviewed,
            "overview": build_ai_agent_overview(db=db, base_backend_url=_infer_base_url(request)),
        }
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


# ==============================================================================
# 3. FASE 2: DESCUBRIMIENTO PASIVO SOLO-LECTURA (SSH/WINRM RO + WALK SNMP IF/LLDP)
# ==============================================================================


@api_router.get(
    "/ai-agent/passive-discovery",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="Listar instantáneas de Descubrimiento Pasivo RO y credenciales disponibles del baúl",
)
def get_passive_discovery_endpoint(db: Session = Depends(get_db)):
    return list_passive_discovery_snapshots(db=db, limit=60)


@api_router.post(
    "/ai-agent/passive-discovery/audit-hosts",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="Ejecutar auditoría en memoria 100% Solo-Lectura vía SSH (Linux) o WinRM (Windows)",
)
async def launch_passive_host_audit_endpoint(
    payload: AiPassiveHostAuditInput,
    request: Request,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    try:
        snaps = await run_passive_host_audit_async(
            db=db,
            os_family=payload.os_family,
            targets=payload.targets,
            credential_id=payload.credential_id,
            ephemeral_credential=payload.ephemeral_credential.model_dump()
            if payload.ephemeral_credential
            else None,
            collected_by=user.username or "operator",
        )
        scan_and_create_cmdb_suggestions(db=db)
        return {
            "snapshots": snaps,
            "overview": build_ai_agent_overview(db=db, base_backend_url=_infer_base_url(request)),
        }
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc))


@api_router.post(
    "/ai-agent/passive-discovery/snmp-walk",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="Ejecutar Walk SNMP Solo-Lectura (`IF-MIB` + `LLDP-MIB`) sobre un Switch/Router",
)
def launch_passive_snmp_walk_endpoint(
    payload: AiPassiveSnmpWalkInput,
    request: Request,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    try:
        snap = run_passive_snmp_walk_discovery(
            db=db,
            target_host=payload.target_host,
            port=payload.port,
            community=payload.community,
            version=payload.version,
            timeout_sec=payload.timeout_sec,
            max_oids_per_table=payload.max_oids_per_table,
            collected_by=user.username or "operator",
        )
        scan_and_create_cmdb_suggestions(db=db)
        return {
            "snapshot": snap,
            "overview": build_ai_agent_overview(db=db, base_backend_url=_infer_base_url(request)),
        }
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    except RuntimeError as exc:
        raise HTTPException(status_code=502, detail=str(exc))


@api_router.post(
    "/ai-agent/passive-discovery/{snapshot_id}/apply-topology",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="Aprobar y sincronizar bocas SNMP (`SwitchSnmpPort`) y enlaces lógicos deducidos (rol editor+)",
)
def apply_passive_snapshot_endpoint(
    snapshot_id: int,
    request: Request,
    user: User = Depends(require_role("editor")),
    db: Session = Depends(get_db),
):
    try:
        applied = apply_passive_snapshot_to_topology(
            db=db,
            snapshot_id=snapshot_id,
            applied_by=user.username or "editor",
        )
        return {
            **applied,
            "overview": build_ai_agent_overview(db=db, base_backend_url=_infer_base_url(request)),
        }
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@api_router.delete(
    "/ai-agent/passive-discovery/{snapshot_id}",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="Eliminar una instantánea de descubrimiento pasivo (rol editor+)",
)
def delete_passive_snapshot_endpoint(
    snapshot_id: int,
    request: Request,
    db: Session = Depends(get_db),
):
    snap = db.query(AiPassiveDiscoverySnapshot).filter(AiPassiveDiscoverySnapshot.id == snapshot_id).first()
    if not snap:
        raise HTTPException(status_code=404, detail="Instantánea no encontrada.")
    db.delete(snap)
    db.commit()
    return {
        "deleted_id": snapshot_id,
        "overview": build_ai_agent_overview(db=db, base_backend_url=_infer_base_url(request)),
    }


# ==============================================================================
# 4. API ESTRICTA SOLO-LECTURA PARA SERVIDOR MCP EXTERNO (`/api/v1/ai-readonly/*`)
# ==============================================================================


@ai_readonly_router.get(
    "/ai-readonly/passive-discovery",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="MCP Solo-Lectura: Consultar telemetría de puertos, conexiones TCP, contenedores y vecinos LLDP",
)
def mcp_readonly_passive_discovery_endpoint(db: Session = Depends(get_db)):
    data = list_passive_discovery_snapshots(db=db, limit=40)
    return {"snapshots": data["snapshots"]}


@ai_readonly_router.get(
    "/ai-readonly/network-schema",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="MCP Solo-Lectura: Obtener el esquema visual de red en 5 capas (zonas, nodos, enlaces y FinOps)",
)
def mcp_readonly_network_schema_endpoint(
    scope_type: str = Query(default="global_cpd"),
    scope_target_id: Optional[int] = Query(default=None),
    db: Session = Depends(get_db),
):
    return build_analyzed_network_schema(
        db=db,
        scope_type=scope_type,
        scope_target_id=scope_target_id,
    )


@ai_readonly_router.get(
    "/ai-readonly/snapshot",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="MCP Solo-Lectura: Obtener radiografía sanitizada y diagrama Mermaid por alcance",
)
def mcp_readonly_snapshot_endpoint(
    scope_type: str = Query(default="global_cpd"),
    scope_target_id: Optional[int] = Query(default=None),
    db: Session = Depends(get_db),
):
    try:
        return build_federated_readonly_snapshot(
            db=db,
            scope_type=scope_type,
            scope_target_id=scope_target_id,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@ai_readonly_router.get(
    "/ai-readonly/prometheus-query",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="MCP Solo-Lectura: Ejecutar consulta PromQL instantánea (`GET`) contra Prometheus",
)
def mcp_readonly_prometheus_endpoint(
    query: str = Query(..., description="Expresión PromQL de lectura (ej. rackdoc_host_up)"),
):
    try:
        return query_prometheus_readonly_instant(query)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@ai_readonly_router.get(
    "/ai-readonly/documents",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="MCP Solo-Lectura: Listar biblioteca de informes y dossiers generados",
)
def mcp_readonly_list_documents_endpoint(
    db: Session = Depends(get_db),
):
    docs = (
        db.query(AiGeneratedDocument)
        .order_by(AiGeneratedDocument.id.desc())
        .limit(50)
        .all()
    )
    return {"documents": [serialize_ai_document(d, include_markdown=False) for d in docs]}


@ai_readonly_router.post(
    "/ai-readonly/documents",
    tags=["AI Agent Read-Only & Auto-Documenter (Ollama + MCP)"],
    summary="MCP Documentador Seguro: Archivar un informe Markdown externo en la biblioteca IA",
)
def mcp_save_document_endpoint(
    payload: AiMcpSaveDocumentInput,
    db: Session = Depends(get_db),
):
    try:
        return {"document": save_external_mcp_document(db=db, payload=payload.model_dump())}
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
