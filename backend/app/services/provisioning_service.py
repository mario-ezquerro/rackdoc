"""
Motor de aprovisionamiento Ansible (Linux SSH y Windows WinRM), verificación previa
de agentes instalados de serie (`node_exporter`, `windows_exporter`, `otelcol`),
baúl cifrado de credenciales (Fernet), scripts de auto-alta con token (`.sh` / `.ps1`)
y pasarela OTLP hacia Prometheus.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import os
import re
import secrets
import shutil
import stat
import tempfile
from datetime import timedelta
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import httpx
from sqlalchemy.orm import Session

from ..database import SessionLocal
from ..logging_setup import get_logger
from ..models import (
    CmdbAsset,
    CmdbIpAddress,
    Location,
    ProvisioningCredential,
    ProvisioningJob,
    ProvisioningToken,
)
from ..security import AUTOMATION_API_KEY, decrypt_vault_secret, encrypt_vault_secret
from ..time_utils import utcnow
from .network_host_service import handle_ansible_host_upsert_webhook

logger = get_logger(__name__)

PLAYBOOKS_DIR = Path(__file__).resolve().parent.parent / "ansible_playbooks"
AGENT_CACHE_DIR = Path(os.getenv("RACKDOC_DATA_DIR", "/app/data")) / "agent_cache"
PROMETHEUS_INTERNAL_URL = (
    os.getenv("PROMETHEUS_URL", "http://rackdoc-prometheus:9090") or "http://rackdoc-prometheus:9090"
).rstrip("/")

_TARGET_SAFE_RE = re.compile(r"^[A-Za-z0-9._:-]{1,253}$")
_BUILD_VERSION_RE = re.compile(
    r'(?:node_exporter_build_info|windows_exporter_build_info)\{[^}]*version="([^"]+)"'
)

VALID_ACTION_PROFILES = {
    "verify_and_propose",
    "ensure_native_exporter",
    "ensure_otel_collector",
    "ensure_both",
}


def sanitize_target_host(raw: str) -> str:
    """Valida una IP o FQDN objetivo para evitar inyección en inventarios INI o shell."""
    cleaned = (raw or "").strip()
    if not cleaned or not _TARGET_SAFE_RE.match(cleaned) or cleaned.startswith("-"):
        raise ValueError(f"Destino inválido o no permitido: '{raw}'")
    return cleaned


def _compute_secret_fingerprint(credential_type: str, secret: str) -> str:
    """Genera una huella legible no reversible para identificar llaves o contraseñas en UI."""
    raw = (secret or "").strip()
    if not raw:
        return "sin-secreto"
    digest = hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]
    if credential_type == "ssh_key":
        key_kind = "RSA/PEM"
        if "OPENSSH" in raw:
            key_kind = "OpenSSH"
        return f"{key_kind} SHA256:{digest}"
    return f"Secret SHA256:{digest[:10]}••••••••"


# ==============================================================================
# 1. BAÚL DE CREDENCIALES CIFRADAS (FERNET)
# ==============================================================================


def serialize_credential(cred: ProvisioningCredential) -> Dict[str, Any]:
    """Serializa metadatos de una credencial del baúl sin exponer jamás secretos en claro."""
    return {
        "id": cred.id,
        "name": cred.name or "",
        "credential_type": cred.credential_type or "ssh_key",
        "os_family": cred.os_family or "linux",
        "username": cred.username or "root",
        "port": cred.port or (5985 if cred.os_family == "windows" else 22),
        "has_secret": bool(cred.secret_ciphertext),
        "has_passphrase": bool(cred.passphrase_ciphertext),
        "has_become_password": bool(cred.become_password_ciphertext),
        "winrm_transport": cred.winrm_transport or "ntlm",
        "winrm_use_ssl": bool(cred.winrm_use_ssl),
        "winrm_validate_certs": bool(cred.winrm_validate_certs),
        "key_fingerprint": cred.key_fingerprint or "",
        "notes": cred.notes or "",
        "created_by": cred.created_by or "admin",
        "created_at": cred.created_at.isoformat() if cred.created_at else None,
        "updated_at": cred.updated_at.isoformat() if cred.updated_at else None,
    }


def upsert_provisioning_credential(
    db: Session,
    payload: Dict[str, Any],
    created_by: str = "admin",
    credential_id: Optional[int] = None,
) -> Dict[str, Any]:
    """Crea o actualiza una credencial SSH / WinRM cifrando sus secretos con Fernet."""
    name = str(payload.get("name") or "").strip()
    if not name:
        raise ValueError("El nombre descriptivo de la credencial es obligatorio.")

    cred_type = str(payload.get("credential_type") or "ssh_key").strip().lower()
    if cred_type not in {"ssh_key", "ssh_password", "winrm"}:
        raise ValueError("credential_type debe ser 'ssh_key', 'ssh_password' o 'winrm'.")

    os_family = "windows" if cred_type == "winrm" else str(payload.get("os_family") or "linux").strip().lower()
    default_port = 5986 if (cred_type == "winrm" and payload.get("winrm_use_ssl")) else (5985 if cred_type == "winrm" else 22)
    port = int(payload.get("port") or default_port)

    if credential_id is not None:
        cred = db.query(ProvisioningCredential).filter(ProvisioningCredential.id == credential_id).first()
        if not cred:
            raise ValueError("La credencial solicitada no existe.")
    else:
        cred = db.query(ProvisioningCredential).filter(ProvisioningCredential.name == name).first()
        if not cred:
            cred = ProvisioningCredential(created_by=created_by)
            db.add(cred)

    cred.name = name
    cred.credential_type = cred_type
    cred.os_family = os_family
    cred.username = str(payload.get("username") or ("Administrator" if os_family == "windows" else "root")).strip()
    cred.port = port
    cred.winrm_transport = str(payload.get("winrm_transport") or "ntlm").strip().lower()
    cred.winrm_use_ssl = bool(payload.get("winrm_use_ssl", port == 5986))
    cred.winrm_validate_certs = bool(payload.get("winrm_validate_certs", False))
    cred.notes = str(payload.get("notes") or "").strip()

    raw_secret = str(payload.get("secret") or "").strip()
    if raw_secret:
        cred.secret_ciphertext = encrypt_vault_secret(raw_secret)
        cred.key_fingerprint = _compute_secret_fingerprint(cred_type, raw_secret)
    elif not cred.secret_ciphertext:
        raise ValueError("Debes proporcionar la clave privada SSH o contraseña para crear la credencial.")

    if payload.get("passphrase") is not None and str(payload.get("passphrase")).strip():
        cred.passphrase_ciphertext = encrypt_vault_secret(str(payload.get("passphrase")))
    if payload.get("become_password") is not None and str(payload.get("become_password")).strip():
        cred.become_password_ciphertext = encrypt_vault_secret(str(payload.get("become_password")))

    db.commit()
    db.refresh(cred)
    return serialize_credential(cred)


def delete_provisioning_credential(db: Session, credential_id: int) -> None:
    """Elimina una credencial del baúl cifrado."""
    cred = db.query(ProvisioningCredential).filter(ProvisioningCredential.id == credential_id).first()
    if not cred:
        raise ValueError("Credencial no encontrada.")
    db.delete(cred)
    db.commit()


# ==============================================================================
# 2. PRE-CHECK RÁPIDO NO INTRUSIVO (DETECCIÓN DE EXPORTERS DE SERIE SIN SSH)
# ==============================================================================


async def _probe_tcp_port(host: str, port: int, timeout_sec: float) -> bool:
    try:
        conn = asyncio.open_connection(host, port)
        reader, writer = await asyncio.wait_for(conn, timeout=timeout_sec)
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass
        return True
    except Exception:
        return False


async def _probe_http_exporter(
    client: httpx.AsyncClient, host: str, port: int, expected_marker: str
) -> Tuple[bool, str]:
    try:
        resp = await client.get(f"http://{host}:{port}/metrics")
        if resp.status_code == 200 and expected_marker in resp.text:
            m = _BUILD_VERSION_RE.search(resp.text)
            return True, (m.group(1) if m else "detectado")
    except Exception:
        pass
    return False, ""


async def run_provisioning_precheck_async(
    db: Session, targets: List[str], timeout_sec: float = 1.8
) -> List[Dict[str, Any]]:
    """
    Sondea en paralelo si los servidores destino ya traen `node_exporter` (:9100),
    `windows_exporter` (:9182) u `otelcol` (:13133) activos de serie, y qué puerto
    de gestión (`SSH :22` vs `WinRM :5985/:5986`) tienen disponible.
    """
    cleaned_targets = [sanitize_target_host(t) for t in targets if (t or "").strip()]
    if not cleaned_targets:
        raise ValueError("Indica al menos una dirección IP o hostname a verificar.")

    # Mapa rápido de activos ya existentes en CMDB por IP o hostname
    ip_rows = (
        db.query(CmdbIpAddress)
        .filter(CmdbIpAddress.ip_address.in_(cleaned_targets))
        .all()
    )
    asset_by_ip: Dict[str, CmdbAsset] = {}
    for row in ip_rows:
        if row.asset:
            asset_by_ip[row.ip_address] = row.asset
    host_assets = (
        db.query(CmdbAsset)
        .filter(CmdbAsset.hostname.in_(cleaned_targets))
        .all()
    )
    for a in host_assets:
        asset_by_ip.setdefault(a.hostname, a)

    timeout = max(0.5, min(float(timeout_sec or 1.8), 6.0))

    async with httpx.AsyncClient(timeout=timeout) as client:

        async def _inspect_one(target: str) -> Dict[str, Any]:
            ssh_22, winrm_5985, winrm_5986, otel_13133, ne_res, we_res = await asyncio.gather(
                _probe_tcp_port(target, 22, timeout),
                _probe_tcp_port(target, 5985, timeout),
                _probe_tcp_port(target, 5986, timeout),
                _probe_tcp_port(target, 13133, timeout),
                _probe_http_exporter(client, target, 9100, "node_"),
                _probe_http_exporter(client, target, 9182, "windows_"),
            )
            ne_active, ne_ver = ne_res
            we_active, we_ver = we_res

            detected_os = "windows" if (we_active or winrm_5985 or winrm_5986) and not ssh_22 else "linux"
            native_active = we_active if detected_os == "windows" else ne_active
            native_port = 9182 if we_active else (9100 if ne_active else (9182 if detected_os == "windows" else 9100))
            native_ver = we_ver if we_active else ne_ver

            existing = asset_by_ip.get(target)
            if native_active:
                recommendation = "already_active_link_only"
                summary = (
                    f"Exporter nativo ya activo de serie en :{native_port}"
                    + (f" (v{native_ver})" if native_ver else "")
                    + " — listo para vincular a CMDB y Prometheus sin reinstalar."
                )
            elif ssh_22 or winrm_5985 or winrm_5986:
                recommendation = "verify_and_propose_install"
                mgmt_proto = "WinRM" if (winrm_5985 or winrm_5986) and not ssh_22 else "SSH"
                summary = (
                    f"Sin exporter respondiendo en :{native_port}. Gestión {mgmt_proto} disponible: "
                    "se recomienda verificar por Ansible e instalar si falta."
                )
            else:
                recommendation = "use_bootstrap_script"
                summary = (
                    "No responde exporter ni puertos SSH/WinRM desde RackDoc. "
                    "Usa el script one-liner (.sh / .ps1 con token) en la máquina."
                )

            return {
                "target": target,
                "detected_os_family": detected_os,
                "ssh_open": ssh_22,
                "winrm_http_open": winrm_5985,
                "winrm_https_open": winrm_5986,
                "native_exporter_active": native_active,
                "native_exporter_port": native_port,
                "native_exporter_version": native_ver,
                "otel_health_open": otel_13133,
                "existing_asset_id": existing.id if existing else None,
                "existing_asset_code": existing.code if existing else None,
                "recommendation": recommendation,
                "summary": summary,
            }

        return list(await asyncio.gather(*[_inspect_one(t) for t in cleaned_targets]))


# ==============================================================================
# 3. INGESTA DE FACTS / AGENTES EN CMDB + PROMETHEUS SD
# ==============================================================================


def _ingest_host_facts_into_cmdb(
    db: Session,
    host_data: Dict[str, Any],
    target_location_id: Optional[int],
    host_groups: List[str],
    ssh_user: str = "root",
    ssh_port: int = 22,
) -> Dict[str, Any]:
    """
    Convierte el JSON de hechos recolectados por Ansible o por `bootstrap.sh/.ps1`
    en una ficha completa de CMDB y configura los chequeos/targets de Prometheus.
    """
    target = str(host_data.get("target") or "").strip()
    default_ipv4 = host_data.get("default_ipv4") or {}
    primary_ip = str(
        host_data.get("primary_ip")
        or default_ipv4.get("address")
        or target
    ).strip()
    primary_mac = str(
        host_data.get("primary_mac_address")
        or default_ipv4.get("macaddress")
        or ""
    ).strip()

    hostname = str(host_data.get("hostname") or target).strip()
    os_family = str(host_data.get("os_family") or "linux").strip().lower()

    # Si esa IP ya pertenece a un activo existente en CMDB, enriquecemos ese mismo activo
    existing_ip = (
        db.query(CmdbIpAddress)
        .filter(CmdbIpAddress.ip_address == primary_ip)
        .first()
    )
    existing_asset_id = existing_ip.asset_id if existing_ip else None

    ram_gb = float(host_data.get("ram_gb") or 0.0)
    if not ram_gb and host_data.get("ram_mb"):
        ram_gb = round(float(host_data["ram_mb"]) / 1024.0, 1)

    storage_gb = float(host_data.get("storage_gb") or 0.0)
    if not storage_gb and isinstance(host_data.get("mounts"), list):
        total_bytes = sum(
            int(m.get("size_total") or 0)
            for m in host_data["mounts"]
            if isinstance(m, dict)
        )
        if total_bytes > 0:
            storage_gb = round(total_bytes / (1024**3), 1)

    virt_role = str(host_data.get("virtualization_role") or "").lower()
    virt_type = str(host_data.get("virtualization_type") or "").strip()
    product_name = str(host_data.get("product_name") or "").strip()
    is_vm = virt_role == "guest" or any(
        k in product_name.lower() for k in ("vmware", "virtual", "kvm", "qemu", "proxmox", "hyper-v")
    )
    asset_class = "virtual_machine" if is_vm else "physical_server"

    all_ips = [
        str(ip).strip()
        for ip in (host_data.get("all_ipv4_addresses") or [])
        if str(ip).strip() and str(ip).strip() not in {primary_ip, "127.0.0.1"}
    ]
    additional_ips = [
        {"ip_address": ip, "interface_name": f"nic{idx + 1}", "ip_role": "secondary_service"}
        for idx, ip in enumerate(all_ips[:8])
    ]

    pre_agent = host_data.get("pre_agent") or {}
    post_agent = host_data.get("post_agent") or pre_agent
    native_status = str(post_agent.get("native_status") or "missing").lower()
    native_ver = str(post_agent.get("native_version") or pre_agent.get("native_version") or "")
    otel_status = str(post_agent.get("otel_status") or "missing").lower()

    exporters: List[Dict[str, Any]] = []
    if native_status == "active":
        if os_family == "windows":
            exporters.append({"type": "windows_exporter", "port": 9182})
        else:
            exporters.append({"type": "node_exporter", "port": 9100})

    upsert_payload: Dict[str, Any] = {
        "asset_id": existing_asset_id,
        "hostname": hostname,
        "fqdn": str(host_data.get("fqdn") or hostname).strip(),
        "asset_class": asset_class,
        "os_or_firmware": str(host_data.get("os_or_firmware") or os_family.capitalize()).strip(),
        "cpu_cores": max(1, int(host_data.get("cpu_cores") or 1)),
        "ram_gb": max(0.5, ram_gb or 2.0),
        "storage_gb": max(5.0, storage_gb or 20.0),
        "serial_or_uuid": str(host_data.get("serial_or_uuid") or "").strip(),
        "model_name": product_name,
        "hosting_mode": "cluster_pool" if is_vm else "standalone",
        "hypervisor_or_platform": virt_type or product_name or ("Linux Host" if os_family == "linux" else "Windows Server"),
        "primary_ip": primary_ip,
        "primary_mac_address": primary_mac,
        "additional_ips": additional_ips,
        "host_groups": host_groups or [],
        "monitoring_enabled": True,
        "enable_icmp_ping": True,
        "exporters": exporters,
        "connect_enabled": os_family == "linux",
        "ssh_enabled": os_family == "linux",
        "ssh_user": ssh_user,
        "ssh_port": ssh_port,
        "ssh_host": primary_ip,
        "notes": (
            f"Inventariado automáticamente por RackDoc Provisioning ({os_family}). "
            f"Exporter nativo: {native_status}{f' v{native_ver}' if native_ver else ''}; OTel: {otel_status}."
        ),
    }

    created = handle_ansible_host_upsert_webhook(db=db, payload=upsert_payload)
    asset_id = created.get("asset_id")
    if asset_id and target_location_id:
        asset_obj = db.query(CmdbAsset).filter(CmdbAsset.id == int(asset_id)).first()
        if asset_obj:
            cf = dict(asset_obj.custom_fields or {})
            cf["location_id"] = int(target_location_id)
            asset_obj.custom_fields = cf
            db.commit()

    # Calcular propuesta inteligente para la UI según lo detectado antes y después
    pre_native = str(pre_agent.get("native_status") or "missing").lower()
    if pre_native == "active" and native_status == "active":
        proposal = "linked_existing_exporter"
        proposal_label = "Detectado de serie y vinculado a Prometheus (sin reinstalar)"
    elif pre_native != "active" and native_status == "active":
        proposal = "installed_or_started"
        proposal_label = "Exporter activado y vinculado a Prometheus"
    elif native_status == "stopped":
        proposal = "propose_start_exporter"
        proposal_label = "Exporter instalado pero detenido — pulsa 'Activar Exporter' para arrancarlo"
    else:
        proposal = "propose_install_exporter"
        proposal_label = "Sin exporter instalado — pulsa 'Instalar Exporter' para desplegarlo"

    return {
        "asset_id": asset_id,
        "asset_code": created.get("code"),
        "hostname": hostname,
        "primary_ip": primary_ip,
        "os_or_firmware": upsert_payload["os_or_firmware"],
        "cpu_cores": upsert_payload["cpu_cores"],
        "ram_gb": upsert_payload["ram_gb"],
        "storage_gb": upsert_payload["storage_gb"],
        "pre_native_status": pre_native,
        "native_status": native_status,
        "native_version": native_ver,
        "otel_status": otel_status,
        "proposal": proposal,
        "proposal_label": proposal_label,
    }


# ==============================================================================
# 4. EJECUCIÓN ASÍNCRONA DE JOBS ANSIBLE (SUBPROCESOS AISLADOS)
# ==============================================================================


def serialize_job(job: ProvisioningJob, include_log: bool = False) -> Dict[str, Any]:
    """Serializa un `ProvisioningJob` para el panel de seguimiento e historial."""
    data = {
        "id": job.id,
        "job_code": job.job_code or "",
        "title": job.title or "",
        "os_family": job.os_family or "linux",
        "action_profile": job.action_profile or "verify_and_propose",
        "targets": job.targets or [],
        "credential_id": job.credential_id,
        "credential_name": job.credential.name if job.credential else ("Efímera (memoria)" if job.credential_mode == "ephemeral" else ""),
        "credential_mode": job.credential_mode or "vault",
        "target_location_id": job.target_location_id,
        "host_groups": job.host_groups or [],
        "otel_endpoint_url": job.otel_endpoint_url or "",
        "use_local_cache": bool(job.use_local_cache),
        "status": job.status or "queued",
        "host_results": job.host_results or {},
        "created_by": job.created_by or "admin",
        "started_at": job.started_at.isoformat() if job.started_at else None,
        "finished_at": job.finished_at.isoformat() if job.finished_at else None,
        "created_at": job.created_at.isoformat() if job.created_at else None,
    }
    if include_log:
        data["console_log"] = job.console_log or ""
    return data


def _resolve_credential_dict(
    db: Session,
    credential_id: Optional[int],
    ephemeral: Optional[Dict[str, Any]],
    os_family: str,
) -> Tuple[Dict[str, Any], str]:
    """Obtiene en memoria los parámetros de conexión desde el baúl o desde entrada efímera."""
    if ephemeral and str(ephemeral.get("secret") or "").strip():
        ctype = str(ephemeral.get("credential_type") or ("winrm" if os_family == "windows" else "ssh_password")).lower()
        return (
            {
                "credential_type": ctype,
                "username": str(ephemeral.get("username") or ("Administrator" if os_family == "windows" else "root")).strip(),
                "port": int(ephemeral.get("port") or (5985 if os_family == "windows" else 22)),
                "secret": str(ephemeral.get("secret") or ""),
                "passphrase": str(ephemeral.get("passphrase") or ""),
                "become_password": str(ephemeral.get("become_password") or ""),
                "winrm_transport": str(ephemeral.get("winrm_transport") or "ntlm"),
                "winrm_use_ssl": bool(ephemeral.get("winrm_use_ssl", False)),
                "winrm_validate_certs": bool(ephemeral.get("winrm_validate_certs", False)),
            },
            "ephemeral",
        )

    if not credential_id:
        raise ValueError("Selecciona una credencial del baúl o introduce una credencial puntual.")

    cred = db.query(ProvisioningCredential).filter(ProvisioningCredential.id == int(credential_id)).first()
    if not cred:
        raise ValueError("La credencial seleccionada ya no existe en el baúl.")

    return (
        {
            "credential_type": cred.credential_type,
            "username": cred.username,
            "port": cred.port or (5985 if os_family == "windows" else 22),
            "secret": decrypt_vault_secret(cred.secret_ciphertext),
            "passphrase": decrypt_vault_secret(cred.passphrase_ciphertext),
            "become_password": decrypt_vault_secret(cred.become_password_ciphertext),
            "winrm_transport": cred.winrm_transport or "ntlm",
            "winrm_use_ssl": bool(cred.winrm_use_ssl),
            "winrm_validate_certs": bool(cred.winrm_validate_certs),
        },
        "vault",
    )


def _write_ansible_inventory(
    work_dir: Path,
    targets: List[str],
    os_family: str,
    cred_data: Dict[str, Any],
) -> Tuple[Path, Dict[str, Any]]:
    """Construye el inventario INI y ficheros temporales `0600` dentro del directorio aislado del job."""
    inv_path = work_dir / "inventory.ini"
    extra_vars: Dict[str, Any] = {}
    lines = ["[rackdoc_targets]"]
    for t in targets:
        lines.append(t)
    lines.append("")
    lines.append("[rackdoc_targets:vars]")
    lines.append(f"ansible_user={cred_data['username']}")
    lines.append(f"ansible_port={int(cred_data['port'])}")

    ctype = cred_data["credential_type"]
    if os_family == "windows" or ctype == "winrm":
        scheme = "https" if cred_data.get("winrm_use_ssl") else "http"
        cert_val = "validate" if cred_data.get("winrm_validate_certs") else "ignore"
        lines.append("ansible_connection=winrm")
        lines.append(f"ansible_winrm_scheme={scheme}")
        lines.append(f"ansible_winrm_transport={cred_data.get('winrm_transport') or 'ntlm'}")
        lines.append(f"ansible_winrm_server_cert_validation={cert_val}")
        extra_vars["ansible_password"] = cred_data["secret"]
    else:
        lines.append("ansible_connection=ssh")
        lines.append("ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8'")
        if ctype == "ssh_key":
            key_path = work_dir / "id_ansible_key"
            secret_txt = cred_data["secret"].rstrip() + "\n"
            key_path.write_text(secret_txt, encoding="utf-8")
            os.chmod(key_path, stat.S_IRUSR | stat.S_IWUSR)
            lines.append(f"ansible_ssh_private_key_file={key_path}")
        else:
            extra_vars["ansible_password"] = cred_data["secret"]

        if cred_data.get("become_password"):
            extra_vars["ansible_become_password"] = cred_data["become_password"]
        if str(cred_data["username"]).strip() == "root":
            extra_vars["rackdoc_become"] = False

    inv_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.chmod(inv_path, stat.S_IRUSR | stat.S_IWUSR)
    return inv_path, extra_vars


async def _execute_provisioning_job_async(job_id: int, cred_data: Dict[str, Any]) -> None:
    """Worker asíncrono en segundo plano que invoca `ansible-playbook` y actualiza CMDB/Prometheus."""
    work_dir = Path(tempfile.mkdtemp(prefix=f"rackdoc_job_{job_id}_"))
    os.chmod(work_dir, stat.S_IRWXU)
    results_dir = work_dir / "results"
    results_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    AGENT_CACHE_DIR.mkdir(parents=True, exist_ok=True)

    db = SessionLocal()
    try:
        job = db.query(ProvisioningJob).filter(ProvisioningJob.id == job_id).first()
        if not job:
            return
        job.status = "running"
        job.started_at = utcnow()
        job.console_log = (
            f"[{job.started_at.isoformat()}] Iniciando trabajo {job.job_code} "
            f"({job.os_family} / perfil={job.action_profile}) sobre {', '.join(job.targets or [])}...\n"
        )
        db.commit()

        ansible_bin = shutil.which("ansible-playbook")
        if not ansible_bin:
            venv_candidate = Path(__file__).resolve().parents[2] / ".venv" / "bin" / "ansible-playbook"
            if venv_candidate.exists():
                ansible_bin = str(venv_candidate)
        if not ansible_bin:
            job.status = "failed"
            job.finished_at = utcnow()
            job.console_log += "ERROR: 'ansible-playbook' no está instalado en el entorno del backend.\n"
            db.commit()
            return

        playbook_file = (
            PLAYBOOKS_DIR / "windows_provision.yml"
            if job.os_family == "windows"
            else PLAYBOOKS_DIR / "linux_provision.yml"
        )
        inv_path, secret_extra_vars = _write_ansible_inventory(
            work_dir=work_dir,
            targets=list(job.targets or []),
            os_family=job.os_family,
            cred_data=cred_data,
        )

        extra_vars_payload = {
            **secret_extra_vars,
            "rackdoc_action_profile": job.action_profile,
            "rackdoc_otel_endpoint": job.otel_endpoint_url or "",
            "rackdoc_otel_api_key": AUTOMATION_API_KEY,
            "rackdoc_agent_cache_dir": str(AGENT_CACHE_DIR) if job.use_local_cache else "",
            "rackdoc_results_dir": str(results_dir),
        }
        extra_vars_path = work_dir / "extra_vars.json"
        extra_vars_path.write_text(json.dumps(extra_vars_payload), encoding="utf-8")
        os.chmod(extra_vars_path, stat.S_IRUSR | stat.S_IWUSR)

        env = os.environ.copy()
        env["ANSIBLE_HOST_KEY_CHECKING"] = "False"
        env["ANSIBLE_NOCOLOR"] = "1"
        env["PYTHONUNBUFFERED"] = "1"

        proc = await asyncio.create_subprocess_exec(
            ansible_bin,
            "-i",
            str(inv_path),
            str(playbook_file),
            "--extra-vars",
            f"@{extra_vars_path}",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            env=env,
            cwd=str(work_dir),
        )

        log_buffer: List[str] = [job.console_log or ""]
        last_flush = asyncio.get_event_loop().time()
        assert proc.stdout is not None
        while True:
            line_bytes = await proc.stdout.readline()
            if not line_bytes:
                break
            line_str = line_bytes.decode("utf-8", errors="replace")
            log_buffer.append(line_str)
            now_t = asyncio.get_event_loop().time()
            if now_t - last_flush >= 0.8:
                job.console_log = "".join(log_buffer)[-90_000:]
                db.commit()
                last_flush = now_t

        return_code = await proc.wait()

        # Procesar resultados estructurados de cada host objetivo
        host_results: Dict[str, Any] = {}
        ok_count = 0
        for target in (job.targets or []):
            res_file = results_dir / f"{target}.json"
            if res_file.exists():
                try:
                    parsed = json.loads(res_file.read_text(encoding="utf-8"))
                    ingested = _ingest_host_facts_into_cmdb(
                        db=db,
                        host_data=parsed,
                        target_location_id=job.target_location_id,
                        host_groups=list(job.host_groups or []),
                        ssh_user=str(cred_data.get("username") or "root"),
                        ssh_port=int(cred_data.get("port") or 22),
                    )
                    host_results[target] = {"state": "ok", **ingested}
                    ok_count += 1
                    log_buffer.append(
                        f"\n[RackDoc CMDB] {target} -> {ingested['asset_code']} ({ingested['proposal_label']})\n"
                    )
                except Exception as ingest_exc:
                    host_results[target] = {
                        "state": "failed",
                        "error": f"Fallo al registrar en CMDB: {ingest_exc}",
                    }
            else:
                host_results[target] = {
                    "state": "unreachable_or_failed",
                    "error": f"Playbook finalizó sin reporte para {target} (código={return_code}). Revisa la consola.",
                }

        total_targets = len(job.targets or [])
        if ok_count == total_targets and return_code == 0:
            job.status = "completed"
        elif ok_count > 0:
            job.status = "partial"
        else:
            job.status = "failed"

        job.host_results = host_results
        job.finished_at = utcnow()
        log_buffer.append(
            f"\n[{job.finished_at.isoformat()}] Trabajo finalizado con estado '{job.status.upper()}' "
            f"({ok_count}/{total_targets} hosts procesados).\n"
        )
        job.console_log = "".join(log_buffer)[-100_000:]
        db.commit()
    except Exception as exc:
        logger.exception("Error ejecutando ProvisioningJob %s: %s", job_id, exc)
        try:
            job = db.query(ProvisioningJob).filter(ProvisioningJob.id == job_id).first()
            if job:
                job.status = "failed"
                job.finished_at = utcnow()
                job.console_log = (job.console_log or "") + f"\n[ERROR CRÍTICO] {exc}\n"
                db.commit()
        except Exception:
            pass
    finally:
        db.close()
        shutil.rmtree(work_dir, ignore_errors=True)


def create_and_launch_provisioning_job(
    db: Session,
    payload: Dict[str, Any],
    created_by: str,
    default_public_base_url: str,
) -> Dict[str, Any]:
    """Valida la petición, registra el `ProvisioningJob` y lanza su ejecución asíncrona."""
    targets = [sanitize_target_host(t) for t in (payload.get("targets") or []) if (t or "").strip()]
    if not targets:
        raise ValueError("Debes indicar al menos un servidor destino (IP o FQDN).")

    os_family = str(payload.get("os_family") or "linux").strip().lower()
    if os_family not in {"linux", "windows"}:
        raise ValueError("os_family debe ser 'linux' o 'windows'.")

    action_profile = str(payload.get("action_profile") or "verify_and_propose").strip().lower()
    if action_profile not in VALID_ACTION_PROFILES:
        raise ValueError(f"action_profile inválido. Valores permitidos: {sorted(VALID_ACTION_PROFILES)}")

    cred_data, cred_mode = _resolve_credential_dict(
        db=db,
        credential_id=payload.get("credential_id"),
        ephemeral=payload.get("ephemeral_credential"),
        os_family=os_family,
    )

    otel_url = str(payload.get("otel_endpoint_url") or "").strip()
    if not otel_url and action_profile in {"ensure_otel_collector", "ensure_both"}:
        otel_url = f"{default_public_base_url.rstrip('/')}/api/v1/automation/otlp/v1/metrics"

    stamp = utcnow().strftime("%Y%m%d-%H%M%S")
    job_code = f"PROV-{stamp}-{secrets.token_hex(2).upper()}"
    title = str(payload.get("title") or "").strip() or (
        f"{action_profile} ({os_family}) -> {', '.join(targets[:3])}"
        + (f" +{len(targets) - 3}" if len(targets) > 3 else "")
    )

    job = ProvisioningJob(
        job_code=job_code,
        title=title,
        os_family=os_family,
        action_profile=action_profile,
        targets=targets,
        credential_id=payload.get("credential_id") if cred_mode == "vault" else None,
        credential_mode=cred_mode,
        target_location_id=payload.get("target_location_id"),
        host_groups=list(payload.get("host_groups") or []),
        otel_endpoint_url=otel_url,
        use_local_cache=bool(payload.get("use_local_cache", True)),
        status="queued",
        host_results={},
        console_log="Trabajo encolado...\n",
        created_by=created_by,
    )
    db.add(job)
    db.commit()
    db.refresh(job)

    try:
        loop = asyncio.get_running_loop()
        loop.create_task(_execute_provisioning_job_async(job.id, cred_data))
    except RuntimeError:
        # En tests síncronos sin loop activo, ejecutar de forma directa en un loop efímero
        asyncio.run(_execute_provisioning_job_async(job.id, cred_data))
        db.refresh(job)

    return serialize_job(job, include_log=True)


# ==============================================================================
# 5. TOKENS Y GENERADOR DE SCRIPTS ONE-LINER (.SH / .PS1) + PASARELA OTLP
# ==============================================================================


def _hash_token(raw_token: str) -> str:
    return hashlib.sha256((raw_token or "").strip().encode("utf-8")).hexdigest()


def serialize_token(tok: ProvisioningToken) -> Dict[str, Any]:
    return {
        "id": tok.id,
        "name": tok.name or "",
        "token_prefix": tok.token_prefix or "",
        "os_family": tok.os_family or "any",
        "action_profile": tok.action_profile or "ensure_native_exporter",
        "target_location_id": tok.target_location_id,
        "host_groups": tok.host_groups or [],
        "reusable": bool(tok.reusable),
        "uses_count": tok.uses_count or 0,
        "max_uses": tok.max_uses or 0,
        "expires_at": tok.expires_at.isoformat() if tok.expires_at else None,
        "revoked": bool(tok.revoked),
        "created_by": tok.created_by or "admin",
        "last_used_at": tok.last_used_at.isoformat() if tok.last_used_at else None,
        "notes": tok.notes or "",
        "created_at": tok.created_at.isoformat() if tok.created_at else None,
    }


def create_provisioning_token(
    db: Session, payload: Dict[str, Any], created_by: str, base_url: str
) -> Dict[str, Any]:
    """Emite un nuevo token de bootstrap y devuelve el secreto en claro una única vez junto con los one-liners."""
    name = str(payload.get("name") or "").strip()
    if not name:
        raise ValueError("El nombre del token de auto-alta es obligatorio.")

    action_profile = str(payload.get("action_profile") or "ensure_native_exporter").strip().lower()
    if action_profile not in VALID_ACTION_PROFILES:
        raise ValueError("Perfil de acción inválido para el token.")

    raw_token = f"rkd_{secrets.token_urlsafe(28)}"
    ttl_hours = int(payload.get("ttl_hours") if payload.get("ttl_hours") is not None else 24)
    expires_at = utcnow() + timedelta(hours=ttl_hours) if ttl_hours > 0 else None

    tok = ProvisioningToken(
        name=name,
        token_hash=_hash_token(raw_token),
        token_prefix=raw_token[:12],
        os_family=str(payload.get("os_family") or "any").strip().lower(),
        action_profile=action_profile,
        target_location_id=payload.get("target_location_id"),
        host_groups=list(payload.get("host_groups") or []),
        reusable=bool(payload.get("reusable", True)),
        max_uses=max(0, int(payload.get("max_uses") or 0)),
        expires_at=expires_at,
        revoked=False,
        created_by=created_by,
        notes=str(payload.get("notes") or "").strip(),
    )
    db.add(tok)
    db.commit()
    db.refresh(tok)

    clean_base = base_url.rstrip("/")
    return {
        "token": serialize_token(tok),
        "plain_token": raw_token,
        "linux_oneliner": f"curl -fsSL '{clean_base}/api/v1/automation/bootstrap.sh?token={raw_token}' | sudo bash",
        "windows_oneliner": f"irm '{clean_base}/api/v1/automation/bootstrap.ps1?token={raw_token}' | iex",
    }


def revoke_provisioning_token(db: Session, token_id: int) -> Dict[str, Any]:
    tok = db.query(ProvisioningToken).filter(ProvisioningToken.id == token_id).first()
    if not tok:
        raise ValueError("Token no encontrado.")
    tok.revoked = True
    db.commit()
    db.refresh(tok)
    return serialize_token(tok)


def validate_provisioning_token(
    db: Session, raw_token: str, consume_use: bool = False
) -> ProvisioningToken:
    """Valida vigencia, revocación y límite de usos de un token de auto-alta u OTLP."""
    cleaned = (raw_token or "").strip()
    if not cleaned:
        raise PermissionError("Falta el token de aprovisionamiento.")

    tok = (
        db.query(ProvisioningToken)
        .filter(ProvisioningToken.token_hash == _hash_token(cleaned))
        .first()
    )
    if not tok or tok.revoked:
        raise PermissionError("Token de aprovisionamiento inválido o revocado.")

    now = utcnow()
    if tok.expires_at and tok.expires_at.replace(tzinfo=None) < now.replace(tzinfo=None):
        raise PermissionError("El token de aprovisionamiento ha caducado.")

    if not tok.reusable and (tok.uses_count or 0) >= 1 and consume_use:
        raise PermissionError("Este token era de un solo uso y ya fue consumido.")

    if (tok.max_uses or 0) > 0 and (tok.uses_count or 0) >= tok.max_uses and consume_use:
        raise PermissionError("El token alcanzó su número máximo de usos permitidos.")

    if consume_use:
        tok.uses_count = (tok.uses_count or 0) + 1
        tok.last_used_at = now
        db.commit()
        db.refresh(tok)

    return tok


def render_linux_bootstrap_script(tok: ProvisioningToken, raw_token: str, base_url: str) -> str:
    """Genera el script Bash idempotente que verifica primero si `node_exporter` ya viene de serie."""
    clean_base = base_url.rstrip("/")
    otel_endpoint = f"{clean_base}/api/v1/automation/otlp/v1/metrics"
    return f"""#!/usr/bin/env bash
set -euo pipefail

# RackDoc Bootstrap Linux — Perfil: {tok.action_profile}
RACKDOC_BASE="{clean_base}"
RACKDOC_TOKEN="{raw_token}"
ACTION_PROFILE="{tok.action_profile}"
OTEL_ENDPOINT="{otel_endpoint}"

echo "[RackDoc] 1/3 Verificando agentes instalados de serie en $(hostname)..."
NATIVE_STATUS="missing"
NATIVE_VER=""
for unit in node_exporter prometheus-node-exporter; do
  if systemctl is-active --quiet "$unit" 2>/dev/null; then
    NATIVE_STATUS="active"
    break
  elif systemctl list-unit-files "$unit.service" >/dev/null 2>&1; then
    NATIVE_STATUS="stopped"
    if [[ "$ACTION_PROFILE" == "ensure_native_exporter" || "$ACTION_PROFILE" == "ensure_both" ]]; then
      systemctl enable --now "$unit" && NATIVE_STATUS="active"
    fi
    break
  fi
done

if curl -fsS -m 2 http://127.0.0.1:9100/metrics >/tmp/rkd_ne_metrics 2>/dev/null; then
  NATIVE_STATUS="active"
  NATIVE_VER="$(grep -m1 '^node_exporter_build_info' /tmp/rkd_ne_metrics | sed -n 's/.*version="\\([^"]*\\)".*/\\1/p' || true)"
  rm -f /tmp/rkd_ne_metrics
  echo "[RackDoc] Detectado node_exporter activo de serie (v${{NATIVE_VER:-detectado}}) — se respeta sin reinstalar."
elif [[ "$NATIVE_STATUS" == "missing" && ( "$ACTION_PROFILE" == "ensure_native_exporter" || "$ACTION_PROFILE" == "ensure_both" ) ]]; then
  echo "[RackDoc] 2/3 node_exporter no detectado; instalando servicio systemd en :9100..."
  ARCH="$(uname -m)"
  [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && RKD_ARCH="arm64" || RKD_ARCH="amd64"
  NE_VER="1.8.2"
  curl -fsSL -o /tmp/ne.tar.gz "https://github.com/prometheus/node_exporter/releases/download/v${{NE_VER}}/node_exporter-${{NE_VER}}.linux-${{RKD_ARCH}}.tar.gz"
  tar -xzf /tmp/ne.tar.gz -C /tmp
  cp "/tmp/node_exporter-${{NE_VER}}.linux-${{RKD_ARCH}}/node_exporter" /usr/local/bin/node_exporter
  chmod 0755 /usr/local/bin/node_exporter
  id -u node_exporter >/dev/null 2>&1 || useradd --no-create-home --shell /usr/sbin/nologin node_exporter || true
  cat >/etc/systemd/system/node_exporter.service <<'EOF'
[Unit]
Description=Prometheus Node Exporter (RackDoc Bootstrap)
After=network-online.target

[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter --web.listen-address=:9100
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  rm -rf /tmp/ne.tar.gz "/tmp/node_exporter-${{NE_VER}}.linux-${{RKD_ARCH}}"
  systemctl daemon-reload
  systemctl enable --now node_exporter
  NATIVE_STATUS="active"
  NATIVE_VER="$NE_VER"
fi

OTEL_STATUS="missing"
if systemctl is-active --quiet otelcol-contrib 2>/dev/null || systemctl is-active --quiet otelcol 2>/dev/null; then
  OTEL_STATUS="active"
elif [[ "$ACTION_PROFILE" == "ensure_otel_collector" || "$ACTION_PROFILE" == "ensure_both" ]]; then
  echo "[RackDoc] Configurando OpenTelemetry Collector (OTLP -> RackDoc)..."
  ARCH="$(uname -m)"
  [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && RKD_ARCH="arm64" || RKD_ARCH="amd64"
  OTEL_VER="0.114.0"
  mkdir -p /tmp/rkd_otel /etc/otelcol-contrib
  curl -fsSL -o /tmp/otel.tar.gz "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${{OTEL_VER}}/otelcol-contrib_${{OTEL_VER}}_linux_${{RKD_ARCH}}.tar.gz"
  tar -xzf /tmp/otel.tar.gz -C /tmp/rkd_otel
  cp /tmp/rkd_otel/otelcol-contrib /usr/local/bin/otelcol-contrib
  chmod 0755 /usr/local/bin/otelcol-contrib
  rm -rf /tmp/otel.tar.gz /tmp/rkd_otel
  cat >/etc/otelcol-contrib/config.yaml <<EOF
receivers:
  hostmetrics:
    collection_interval: 30s
    scrapers: {{ cpu: {{}}, memory: {{}}, disk: {{}}, filesystem: {{}}, load: {{}}, network: {{}} }}
processors:
  batch: {{}}
exporters:
  otlphttp:
    metrics_endpoint: "${{OTEL_ENDPOINT}}"
    headers:
      X-RackDoc-Token: "${{RACKDOC_TOKEN}}"
service:
  pipelines:
    metrics:
      receivers: [hostmetrics]
      processors: [batch]
      exporters: [otlphttp]
EOF
  cat >/etc/systemd/system/otelcol-contrib.service <<'EOF'
[Unit]
Description=OpenTelemetry Collector Contrib (RackDoc Bootstrap)
After=network-online.target

[Service]
ExecStart=/usr/local/bin/otelcol-contrib --config=/etc/otelcol-contrib/config.yaml
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now otelcol-contrib
  OTEL_STATUS="active"
fi

echo "[RackDoc] 3/3 Registrando inventario hardware y estado en RackDoc CMDB..."
PRIMARY_IP="$(hostname -I 2>/dev/null | awk '{{print $1}}')"
CPU_CORES="$(nproc 2>/dev/null || echo 1)"
RAM_GB="$(awk '/MemTotal/ {{printf "%.1f", $2/1048576}}' /proc/meminfo 2>/dev/null || echo 2.0)"
DISK_GB="$(df -BG / 2>/dev/null | awk 'NR==2 {{gsub("G","",$2); print $2}}' || echo 20)"
OS_NAME="$(. /etc/os-release 2>/dev/null && echo "${{PRETTY_NAME:-Linux}}" || uname -sr)"
SERIAL="$(cat /sys/class/dmi/id/product_serial 2>/dev/null | tr -d '\\n\"' || true)"

curl -fsSL -X POST "${{RACKDOC_BASE}}/api/v1/automation/bootstrap/register" \\
  -H "Content-Type: application/json" \\
  -H "X-RackDoc-Token: ${{RACKDOC_TOKEN}}" \\
  -d "{{
    \\"hostname\\": \\"$(hostname -s)\\",
    \\"fqdn\\": \\"$(hostname -f 2>/dev/null || hostname)\\",
    \\"os_family\\": \\"linux\\",
    \\"os_or_firmware\\": \\"${{OS_NAME}}\\",
    \\"cpu_cores\\": ${{CPU_CORES}},
    \\"ram_gb\\": ${{RAM_GB}},
    \\"storage_gb\\": ${{DISK_GB}},
    \\"serial_or_uuid\\": \\"${{SERIAL}}\\",
    \\"primary_ip\\": \\"${{PRIMARY_IP}}\\",
    \\"native_exporter_status\\": \\"${{NATIVE_STATUS}}\\",
    \\"native_exporter_port\\": 9100,
    \\"native_exporter_version\\": \\"${{NATIVE_VER}}\\",
    \\"otel_collector_status\\": \\"${{OTEL_STATUS}}\\"
  }}"
echo ""
echo "[RackDoc] Registro completado correctamente."
"""


def render_windows_bootstrap_script(tok: ProvisioningToken, raw_token: str, base_url: str) -> str:
    """Genera el script PowerShell idempotente que verifica primero `windows_exporter` antes de instalar."""
    clean_base = base_url.rstrip("/")
    return f"""# RackDoc Bootstrap Windows PowerShell — Perfil: {tok.action_profile}
$ErrorActionPreference = 'Stop'
$RackDocBase = '{clean_base}'
$RackDocToken = '{raw_token}'
$ActionProfile = '{tok.action_profile}'

Write-Host "[RackDoc] 1/3 Verificando si windows_exporter ya existe de serie..."
$NativeStatus = 'missing'
$NativeVer = ''
$svc = Get-Service -Name 'windows_exporter','wmi_exporter' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($svc) {{
  if ($svc.Status -eq 'Running') {{
    $NativeStatus = 'active'
  }} else {{
    $NativeStatus = 'stopped'
    if ($ActionProfile -in @('ensure_native_exporter', 'ensure_both')) {{
      Set-Service -Name $svc.Name -StartupType Automatic
      Start-Service -Name $svc.Name
      $NativeStatus = 'active'
    }}
  }}
}}

if ($NativeStatus -eq 'missing' -and $ActionProfile -in @('ensure_native_exporter', 'ensure_both')) {{
  Write-Host "[RackDoc] 2/3 Instalando windows_exporter MSI en :9182..."
  $WeVer = '0.29.2'
  $Msi = "$env:TEMP\\windows_exporter.msi"
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -Uri "https://github.com/prometheus-community/windows_exporter/releases/download/v$WeVer/windows_exporter-$WeVer-amd64.msi" -OutFile $Msi -UseBasicParsing
  Start-Process msiexec.exe -ArgumentList "/i `"$Msi`" ENABLED_COLLECTORS=cpu,cs,logical_disk,net,os,service,system LISTEN_PORT=9182 /qn /norestart" -Wait
  Remove-Item $Msi -Force -ErrorAction SilentlyContinue
  $NativeStatus = 'active'
  $NativeVer = $WeVer
}}

$cs = Get-CimInstance Win32_ComputerSystem
$os = Get-CimInstance Win32_OperatingSystem
$bios = Get-CimInstance Win32_BIOS
$ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object {{ $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown' }} | Select-Object -First 1).IPAddress

$Body = @{{
  hostname = $env:COMPUTERNAME
  fqdn = if ($cs.Domain -and $cs.Domain -ne 'WORKGROUP') {{ "$($env:COMPUTERNAME).$($cs.Domain)" }} else {{ $env:COMPUTERNAME }}
  os_family = 'windows'
  os_or_firmware = "$($os.Caption) ($($os.Version))"
  cpu_cores = [int]$cs.NumberOfLogicalProcessors
  ram_gb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
  storage_gb = 60.0
  serial_or_uuid = [string]$bios.SerialNumber
  primary_ip = [string]$ip
  native_exporter_status = $NativeStatus
  native_exporter_port = 9182
  native_exporter_version = $NativeVer
  otel_collector_status = 'missing'
}} | ConvertTo-Json

Write-Host "[RackDoc] 3/3 Registrando máquina en RackDoc CMDB..."
Invoke-RestMethod -Method Post -Uri "$RackDocBase/api/v1/automation/bootstrap/register" -Headers @{{ 'X-RackDoc-Token' = $RackDocToken }} -ContentType 'application/json' -Body $Body
Write-Host "[RackDoc] Completado."
"""


def register_bootstrapped_host(
    db: Session, tok: ProvisioningToken, payload: Dict[str, Any]
) -> Dict[str, Any]:
    """Procesa el callback JSON de `bootstrap.sh` / `bootstrap.ps1` y registra el servidor en CMDB + Prometheus."""
    host_data = {
        "target": payload.get("primary_ip"),
        "hostname": payload.get("hostname"),
        "fqdn": payload.get("fqdn") or payload.get("hostname"),
        "os_family": payload.get("os_family") or "linux",
        "os_or_firmware": payload.get("os_or_firmware") or "",
        "cpu_cores": payload.get("cpu_cores") or 1,
        "ram_gb": payload.get("ram_gb") or 1.0,
        "storage_gb": payload.get("storage_gb") or 20.0,
        "serial_or_uuid": payload.get("serial_or_uuid") or "",
        "product_name": payload.get("hypervisor_or_platform") or "",
        "primary_ip": payload.get("primary_ip"),
        "primary_mac_address": payload.get("primary_mac_address") or "",
        "all_ipv4_addresses": [
            x.get("ip_address")
            for x in (payload.get("additional_ips") or [])
            if isinstance(x, dict) and x.get("ip_address")
        ],
        "pre_agent": {
            "native_status": payload.get("native_exporter_status") or "missing",
            "native_version": payload.get("native_exporter_version") or "",
            "otel_status": payload.get("otel_collector_status") or "missing",
        },
        "post_agent": {
            "native_status": payload.get("native_exporter_status") or "missing",
            "native_version": payload.get("native_exporter_version") or "",
            "otel_status": payload.get("otel_collector_status") or "missing",
        },
    }
    return _ingest_host_facts_into_cmdb(
        db=db,
        host_data=host_data,
        target_location_id=tok.target_location_id,
        host_groups=list(tok.host_groups or []),
    )


async def forward_otlp_metrics_to_prometheus(
    raw_body: bytes, content_type: str
) -> Tuple[int, bytes, str]:
    """Reenvía cargas OTLP HTTP autenticadas hacia `rackdoc-prometheus` (`--web.enable-otlp-receiver`)."""
    target_url = f"{PROMETHEUS_INTERNAL_URL}/api/v1/otlp/v1/metrics"
    headers = {"Content-Type": content_type or "application/x-protobuf"}
    async with httpx.AsyncClient(timeout=8.0) as client:
        resp = await client.post(target_url, content=raw_body, headers=headers)
        return (
            resp.status_code,
            resp.content,
            resp.headers.get("content-type", "application/json"),
        )


def build_provisioning_overview(db: Session) -> Dict[str, Any]:
    """Construye el estado completo de la pestaña de Aprovisionamiento Ansible & Agentes."""
    creds = (
        db.query(ProvisioningCredential)
        .order_by(ProvisioningCredential.id.desc())
        .all()
    )
    jobs = (
        db.query(ProvisioningJob)
        .order_by(ProvisioningJob.id.desc())
        .limit(40)
        .all()
    )
    tokens = (
        db.query(ProvisioningToken)
        .order_by(ProvisioningToken.id.desc())
        .limit(30)
        .all()
    )
    locations = db.query(Location).order_by(Location.id.asc()).all()
    ansible_installed = bool(
        shutil.which("ansible-playbook")
        or (Path(__file__).resolve().parents[2] / ".venv" / "bin" / "ansible-playbook").exists()
    )

    return {
        "engine": {
            "ansible_available": ansible_installed,
            "prometheus_otlp_receiver_url": "/api/v1/automation/otlp/v1/metrics",
            "prometheus_direct_otlp_hint": ":9090/api/v1/otlp/v1/metrics",
            "agent_cache_dir": str(AGENT_CACHE_DIR),
        },
        "credentials": [serialize_credential(c) for c in creds],
        "jobs": [serialize_job(j, include_log=False) for j in jobs],
        "tokens": [serialize_token(t) for t in tokens],
        "locations": [
            {"id": loc.id, "code": loc.code or "", "name": loc.name or ""}
            for loc in locations
        ],
    }
