"""
Endpoints REST y Bootstrap de Aprovisionamiento Ansible (Linux SSH y Windows WinRM),
Baúl Cifrado de Credenciales, Detección Previa de Exporters de Serie y Pasarela OTLP.
"""

import secrets
from typing import Optional

from fastapi import Depends, Header, HTTPException, Query, Request
from fastapi.responses import PlainTextResponse, Response
from sqlalchemy.orm import Session

from ..database import get_db
from ..models import ProvisioningJob, User
from ..routers._common import api_router, public_router
from ..schemas import (
    BootstrapAgentRegisterPayload,
    ProvisioningCredentialInput,
    ProvisioningJobLaunchInput,
    ProvisioningPrecheckRequest,
    ProvisioningTokenCreateInput,
)
from ..security import AUTOMATION_API_KEY, get_current_user, require_role
from ..services.provisioning_service import (
    build_provisioning_overview,
    create_and_launch_provisioning_job,
    create_provisioning_token,
    delete_provisioning_credential,
    forward_otlp_metrics_to_prometheus,
    register_bootstrapped_host,
    render_linux_bootstrap_script,
    render_windows_bootstrap_script,
    revoke_provisioning_token,
    run_provisioning_precheck_async,
    serialize_job,
    upsert_provisioning_credential,
    validate_provisioning_token,
)


def _infer_base_url(request: Request) -> str:
    """Deduce la URL pública del backend para incrustarla en one-liners y endpoints OTLP."""
    proto = request.headers.get("x-forwarded-proto") or request.url.scheme or "http"
    host = request.headers.get("x-forwarded-host") or request.headers.get("host") or "localhost:8180"
    return f"{proto}://{host}"


@api_router.get(
    "/provisioning/overview",
    tags=["Provisioning Ansible, Exporters & OpenTelemetry"],
    summary="Estado consolidado de Aprovisionamiento Ansible, Baúl Cifrado, Jobs y Tokens Bootstrap",
)
def get_provisioning_overview_endpoint(db: Session = Depends(get_db)):
    return build_provisioning_overview(db)


@api_router.post(
    "/provisioning/precheck",
    tags=["Provisioning Ansible, Exporters & OpenTelemetry"],
    summary="Verificación instantánea no intrusiva de agentes ya instalados de serie (:9100 / :9182 / SSH / WinRM)",
)
async def provisioning_precheck_endpoint(
    payload: ProvisioningPrecheckRequest,
    db: Session = Depends(get_db),
):
    try:
        results = await run_provisioning_precheck_async(
            db=db,
            targets=payload.targets,
            timeout_sec=payload.timeout_sec,
        )
        return {"results": results}
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@api_router.post(
    "/provisioning/credentials",
    tags=["Provisioning Ansible, Exporters & OpenTelemetry"],
    summary="Guardar credencial SSH o WinRM cifrada con Fernet en el baúl (solo Admin)",
)
def create_or_update_credential_endpoint(
    payload: ProvisioningCredentialInput,
    user: User = Depends(require_role("admin")),
    db: Session = Depends(get_db),
):
    try:
        cred = upsert_provisioning_credential(
            db=db,
            payload=payload.model_dump(),
            created_by=user.username or "admin",
        )
        return {"credential": cred, "overview": build_provisioning_overview(db)}
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@api_router.put(
    "/provisioning/credentials/{credential_id}",
    tags=["Provisioning Ansible, Exporters & OpenTelemetry"],
    summary="Actualizar una credencial existente del baúl cifrado (solo Admin)",
)
def update_credential_endpoint(
    credential_id: int,
    payload: ProvisioningCredentialInput,
    user: User = Depends(require_role("admin")),
    db: Session = Depends(get_db),
):
    try:
        cred = upsert_provisioning_credential(
            db=db,
            payload=payload.model_dump(),
            created_by=user.username or "admin",
            credential_id=credential_id,
        )
        return {"credential": cred, "overview": build_provisioning_overview(db)}
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@api_router.delete(
    "/provisioning/credentials/{credential_id}",
    tags=["Provisioning Ansible, Exporters & OpenTelemetry"],
    summary="Eliminar credencial del baúl cifrado (solo Admin)",
)
def delete_credential_endpoint(
    credential_id: int,
    _user: User = Depends(require_role("admin")),
    db: Session = Depends(get_db),
):
    try:
        delete_provisioning_credential(db=db, credential_id=credential_id)
        return {"deleted_id": credential_id, "overview": build_provisioning_overview(db)}
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc))


@api_router.post(
    "/provisioning/jobs/launch",
    tags=["Provisioning Ansible, Exporters & OpenTelemetry"],
    summary="Lanzar trabajo asíncrono Ansible (verificar de serie, auditar hardware CMDB o desplegar Exporter / OTel)",
)
async def launch_provisioning_job_endpoint(
    payload: ProvisioningJobLaunchInput,
    request: Request,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    try:
        job = create_and_launch_provisioning_job(
            db=db,
            payload=payload.model_dump(),
            created_by=user.username or "operator",
            default_public_base_url=_infer_base_url(request),
        )
        return {"job": job, "overview": build_provisioning_overview(db)}
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@api_router.get(
    "/provisioning/jobs/{job_id}",
    tags=["Provisioning Ansible, Exporters & OpenTelemetry"],
    summary="Obtener detalle y consola en vivo de un trabajo de aprovisionamiento Ansible",
)
def get_provisioning_job_detail_endpoint(
    job_id: int,
    db: Session = Depends(get_db),
):
    job = db.query(ProvisioningJob).filter(ProvisioningJob.id == job_id).first()
    if not job:
        raise HTTPException(status_code=404, detail="Trabajo de aprovisionamiento no encontrado.")
    return serialize_job(job, include_log=True)


@api_router.post(
    "/provisioning/tokens",
    tags=["Provisioning Ansible, Exporters & OpenTelemetry"],
    summary="Generar token y comandos one-liner (.sh Linux / .ps1 Windows) para redes sin SSH/WinRM",
)
def create_bootstrap_token_endpoint(
    payload: ProvisioningTokenCreateInput,
    request: Request,
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    try:
        created = create_provisioning_token(
            db=db,
            payload=payload.model_dump(),
            created_by=user.username or "admin",
            base_url=_infer_base_url(request),
        )
        return {**created, "overview": build_provisioning_overview(db)}
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@api_router.delete(
    "/provisioning/tokens/{token_id}",
    tags=["Provisioning Ansible, Exporters & OpenTelemetry"],
    summary="Revocar un token de auto-alta bootstrap",
)
def revoke_bootstrap_token_endpoint(
    token_id: int,
    db: Session = Depends(get_db),
):
    try:
        tok = revoke_provisioning_token(db=db, token_id=token_id)
        return {"token": tok, "overview": build_provisioning_overview(db)}
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc))


# ==============================================================================
# ENDPOINTS ACOTADOS POR TOKEN PARA SCRIPTS BOOTSTRAP (.SH / .PS1) Y PROXY OTLP
# ==============================================================================


@public_router.get(
    "/automation/bootstrap.sh",
    tags=["Provisioning Ansible, Exporters & OpenTelemetry"],
    summary="Script Bash one-liner de verificación de serie y auto-registro para Linux / cloud-init",
)
def download_linux_bootstrap_script(
    request: Request,
    token: str = Query(..., description="Token válido de aprovisionamiento"),
    db: Session = Depends(get_db),
):
    try:
        tok = validate_provisioning_token(db=db, raw_token=token, consume_use=False)
    except PermissionError as exc:
        raise HTTPException(status_code=401, detail=str(exc))
    script = render_linux_bootstrap_script(
        tok=tok, raw_token=token, base_url=_infer_base_url(request)
    )
    return PlainTextResponse(content=script, media_type="text/x-shellscript; charset=utf-8")


@public_router.get(
    "/automation/bootstrap.ps1",
    tags=["Provisioning Ansible, Exporters & OpenTelemetry"],
    summary="Script PowerShell one-liner de verificación de serie y auto-registro para Windows Server",
)
def download_windows_bootstrap_script(
    request: Request,
    token: str = Query(..., description="Token válido de aprovisionamiento"),
    db: Session = Depends(get_db),
):
    try:
        tok = validate_provisioning_token(db=db, raw_token=token, consume_use=False)
    except PermissionError as exc:
        raise HTTPException(status_code=401, detail=str(exc))
    script = render_windows_bootstrap_script(
        tok=tok, raw_token=token, base_url=_infer_base_url(request)
    )
    return PlainTextResponse(content=script, media_type="text/plain; charset=utf-8")


@public_router.post(
    "/automation/bootstrap/register",
    tags=["Provisioning Ansible, Exporters & OpenTelemetry"],
    summary="Auto-alta de máquina ejecutada por bootstrap.sh o bootstrap.ps1 con token",
)
def bootstrap_register_host_endpoint(
    payload: BootstrapAgentRegisterPayload,
    token: Optional[str] = Query(default=None),
    x_rackdoc_token: Optional[str] = Header(default=None),
    db: Session = Depends(get_db),
):
    effective_token = (x_rackdoc_token or token or "").strip()
    try:
        tok = validate_provisioning_token(db=db, raw_token=effective_token, consume_use=True)
        registered = register_bootstrapped_host(
            db=db,
            tok=tok,
            payload=payload.model_dump(),
        )
        return {"status": "registered", "host": registered}
    except PermissionError as exc:
        raise HTTPException(status_code=401, detail=str(exc))
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@public_router.post(
    "/automation/otlp/v1/metrics",
    tags=["Provisioning Ansible, Exporters & OpenTelemetry"],
    summary="Pasarela autenticada OpenTelemetry (OTLP HTTP) hacia Prometheus TSDB",
)
async def otlp_metrics_gateway_endpoint(
    request: Request,
    x_api_key: Optional[str] = Header(default=None),
    x_rackdoc_token: Optional[str] = Header(default=None),
    db: Session = Depends(get_db),
):
    authorized = False
    if AUTOMATION_API_KEY and x_api_key and secrets.compare_digest(x_api_key.strip(), AUTOMATION_API_KEY):
        authorized = True
    elif x_rackdoc_token or x_api_key:
        candidate = (x_rackdoc_token or x_api_key or "").strip()
        try:
            validate_provisioning_token(db=db, raw_token=candidate, consume_use=False)
            authorized = True
        except PermissionError:
            authorized = False

    if not authorized:
        raise HTTPException(
            status_code=401,
            detail="Credencial OTLP inválida. Envía 'X-API-Key' o 'X-RackDoc-Token' válido.",
        )

    raw_body = await request.body()
    content_type = request.headers.get("content-type") or "application/x-protobuf"
    try:
        status_code, resp_body, resp_ct = await forward_otlp_metrics_to_prometheus(
            raw_body=raw_body,
            content_type=content_type,
        )
        return Response(content=resp_body, status_code=status_code, media_type=resp_ct)
    except Exception as exc:
        raise HTTPException(
            status_code=502,
            detail=f"No se pudo reenviar la carga OTLP a rackdoc-prometheus: {exc}",
        )
