"""
Servicio del Agente IA Solo-Lectura y Documentador Automático (`RackDoc AI`).

Garantías arquitectónicas:
1. **100% Solo-Lectura hacia la infraestructura**: jamás abre conexiones mutables contra equipos
   ni modifica tablas de Racks, Red & Host, CertScope o CMDB de forma autónoma.
2. **Sanitizador obligatorio (`sanitize_context_payload`)**: expurga cualquier credencial, hash,
   secreto Fernet, comunidad SNMP o clave API antes de construir prompts o respuestas MCP.
3. **Motor Local por defecto (`rackdoc-ollama`) + Alternativa Externa**: usa Ollama en local por
   defecto (`qwen2.5:7b`) y soporta proveedores externos (`openai_compatible`, `gemini`, `anthropic`)
   con API Key cifrada con Fernet, además de un modo determinista de respaldo si el modelo aún no
   está descargado.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import time
from typing import Any, Dict, List, Optional, Tuple
from urllib.parse import urlparse

import httpx
from sqlalchemy.orm import Session, joinedload

from ..models import (
    AiAgentSettings,
    AiCmdbSuggestion,
    AiGeneratedDocument,
    AiPassiveDiscoverySnapshot,
    AlertContact,
    AlertContactGroup,
    CmdbAsset,
    CmdbSubnet,
    Connection,
    HostGroup,
    Location,
    LogicalTopologyLink,
    MonitoredServiceCheck,
    NotificationRoutingRule,
    Port,
    Rack,
    RackDevice,
    TechStackDiagram,
    TechStackEdge,
    TechStackNode,
    TlsCertificate,
)
from .passive_discovery_service import list_passive_discovery_snapshots
from ..security import (
    AI_READONLY_API_KEY,
    decrypt_vault_secret,
    encrypt_vault_secret,
)
from ..time_utils import utcnow

DEFAULT_OLLAMA_BASE_URL = (
    os.getenv("OLLAMA_BASE_URL", "http://rackdoc-ollama:11434") or "http://rackdoc-ollama:11434"
).strip()
DEFAULT_OLLAMA_MODEL = (
    os.getenv("OLLAMA_DEFAULT_MODEL", "qwen2.5:7b") or "qwen2.5:7b"
).strip()
PROMETHEUS_INTERNAL_URL = (
    os.getenv("PROMETHEUS_URL", "http://rackdoc-prometheus:9090") or "http://rackdoc-prometheus:9090"
).strip()

ALLOWED_PROVIDERS = ("ollama_local", "openai_compatible", "gemini", "anthropic")
ALLOWED_SCOPES = (
    "global_cpd",
    "location",
    "rack",
    "logical_stack",
    "host",
    "spof_risk_audit",
)
ALLOWED_SUGGESTION_FIELDS = ("notes", "criticality", "owner_team", "os_or_firmware")

RECOMMENDED_OLLAMA_MODELS: List[Dict[str, str]] = [
    {
        "name": "qwen2.5:7b",
        "size_hint": "~4.7 GB",
        "description": "Recomendado por defecto: excelente redacción técnica en español, tablas y diagramas Mermaid.",
    },
    {
        "name": "llama3.2:3b",
        "size_hint": "~2.0 GB",
        "description": "Ligero y rápido para máquinas con poca RAM o ejecución en CPU pura.",
    },
    {
        "name": "qwen2.5-coder:7b",
        "size_hint": "~4.7 GB",
        "description": "Especializado en topologías técnicas, PromQL, JSON estructurado y análisis de red.",
    },
    {
        "name": "mistral:7b",
        "size_hint": "~4.1 GB",
        "description": "Equilibrado para resúmenes ejecutivos de CPD y manuales DRP.",
    },
]

EXTERNAL_PROVIDER_PRESETS: List[Dict[str, str]] = [
    {
        "provider_type": "ollama_local",
        "label": "Ollama Local (Por defecto On-Premise)",
        "default_base_url": DEFAULT_OLLAMA_BASE_URL,
        "default_model": DEFAULT_OLLAMA_MODEL,
    },
    {
        "provider_type": "openai_compatible",
        "label": "OpenAI / vLLM / OpenRouter / LM Studio (Compatible OpenAI)",
        "default_base_url": "https://api.openai.com/v1",
        "default_model": "gpt-4o-mini",
    },
    {
        "provider_type": "gemini",
        "label": "Google Gemini API",
        "default_base_url": "https://generativelanguage.googleapis.com/v1beta",
        "default_model": "gemini-2.5-flash",
    },
    {
        "provider_type": "anthropic",
        "label": "Anthropic Claude API",
        "default_base_url": "https://api.anthropic.com",
        "default_model": "claude-3-5-sonnet-latest",
    },
]

# Claves que jamás deben viajar a un LLM ni salir por MCP.
_SENSITIVE_KEY_SUBSTRINGS = (
    "password",
    "passwd",
    "secret",
    "ciphertext",
    "token_hash",
    "api_key",
    "private_key",
    "community",
    "pem_certificate",
    "bind_dn",
)

_SECRET_TOKEN_REGEX = re.compile(
    r"(Bearer\s+[A-Za-z0-9\-._~+/]+=*|sk-[A-Za-z0-9]{16,}|AIza[0-9A-Za-z\-_]{20,}|rdk_ro_[A-Za-z0-9_\-]{12,})",
    re.IGNORECASE,
)


def sanitize_context_payload(value: Any) -> Any:
    """
    Elimina recursivamente cualquier campo sensible o patrón de credencial antes de
    entregar datos al modelo LLM o al servidor MCP.
    """
    if isinstance(value, dict):
        cleaned: Dict[str, Any] = {}
        for k, v in value.items():
            key_low = str(k).lower()
            if any(sub in key_low for sub in _SENSITIVE_KEY_SUBSTRINGS):
                continue
            cleaned[str(k)] = sanitize_context_payload(v)
        return cleaned
    if isinstance(value, list):
        return [sanitize_context_payload(item) for item in value]
    if isinstance(value, tuple):
        return [sanitize_context_payload(item) for item in value]
    if isinstance(value, str):
        return _SECRET_TOKEN_REGEX.sub("[REDACTED]", value)
    return value


def _mermaid_safe_label(text: str) -> str:
    """Limpia etiquetas de nodos Mermaid evitando comillas dobles, HTML o saltos bruscos."""
    raw = (text or "").replace('"', "'").replace("<", "(").replace(">", ")").strip()
    return re.sub(r"\s+", " ", raw)[:90]


# ==============================================================================
# 1. CONFIGURACIÓN DEL MOTOR IA Y CONTROL DE OLLAMA LOCAL
# ==============================================================================


def get_or_create_ai_settings(db: Session) -> AiAgentSettings:
    cfg = db.query(AiAgentSettings).order_by(AiAgentSettings.id.asc()).first()
    if cfg is None:
        cfg = AiAgentSettings(
            provider_type="ollama_local",
            base_url=DEFAULT_OLLAMA_BASE_URL,
            model_name=DEFAULT_OLLAMA_MODEL,
            api_key_ciphertext="",
            temperature=0.2,
            max_tokens=2048,
            timeout_seconds=90,
            language="es",
            custom_system_instructions="",
            mcp_token_hash="",
            mcp_token_prefix="",
            passive_discovery_enabled=False,
            updated_by="system",
        )
        db.add(cfg)
        db.commit()
        db.refresh(cfg)
    return cfg


def serialize_ai_settings(cfg: AiAgentSettings, base_backend_url: str = "http://localhost:8180") -> Dict[str, Any]:
    return {
        "id": cfg.id,
        "provider_type": cfg.provider_type or "ollama_local",
        "base_url": cfg.base_url or DEFAULT_OLLAMA_BASE_URL,
        "model_name": cfg.model_name or DEFAULT_OLLAMA_MODEL,
        "has_api_key": bool((cfg.api_key_ciphertext or "").strip()),
        "temperature": float(cfg.temperature if cfg.temperature is not None else 0.2),
        "max_tokens": int(cfg.max_tokens or 2048),
        "timeout_seconds": int(cfg.timeout_seconds or 90),
        "language": cfg.language or "es",
        "custom_system_instructions": cfg.custom_system_instructions or "",
        "passive_discovery_enabled": bool(cfg.passive_discovery_enabled),
        "auto_audit_enabled": bool(cfg.auto_audit_enabled),
        "auto_audit_interval_hours": int(cfg.auto_audit_interval_hours or 24),
        "last_auto_audit_at": cfg.last_auto_audit_at.isoformat() if cfg.last_auto_audit_at else None,
        "has_mcp_ui_token": bool((cfg.mcp_token_hash or "").strip()),
        "mcp_token_prefix": cfg.mcp_token_prefix or "",
        "env_mcp_key_configured": bool(AI_READONLY_API_KEY),
        "updated_by": cfg.updated_by or "system",
        "updated_at": cfg.updated_at.isoformat() if cfg.updated_at else None,
        "recommended_ollama_models": RECOMMENDED_OLLAMA_MODELS,
        "provider_presets": EXTERNAL_PROVIDER_PRESETS,
        "mcp_server_guide": {
            "script_path": "backend/mcp_server/rackdoc_mcp.py",
            "readonly_api_prefix": f"{base_backend_url.rstrip('/')}/api/v1/ai-readonly",
            "header_name": "X-AI-Readonly-Key",
        },
    }


def update_ai_settings(
    db: Session,
    payload: Dict[str, Any],
    updated_by: str = "admin",
) -> AiAgentSettings:
    cfg = get_or_create_ai_settings(db)
    provider = str(payload.get("provider_type") or cfg.provider_type or "ollama_local").strip()
    if provider not in ALLOWED_PROVIDERS:
        raise ValueError(f"Proveedor IA no soportado: '{provider}'. Usa uno de {ALLOWED_PROVIDERS}.")

    base_url = str(payload.get("base_url") or "").strip().rstrip("/")
    if not base_url:
        raise ValueError("Debes indicar la URL base del proveedor IA (ej. http://rackdoc-ollama:11434).")
    parsed = urlparse(base_url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        raise ValueError("La URL base del motor IA debe comenzar por http:// o https:// y tener un host válido.")

    model_name = str(payload.get("model_name") or "").strip()
    if not model_name:
        raise ValueError("Debes especificar el nombre del modelo (ej. qwen2.5:7b).")

    cfg.provider_type = provider
    cfg.base_url = base_url
    cfg.model_name = model_name
    cfg.temperature = max(0.0, min(1.5, float(payload.get("temperature", 0.2))))
    cfg.max_tokens = max(256, min(16384, int(payload.get("max_tokens", 2048))))
    cfg.timeout_seconds = max(10, min(300, int(payload.get("timeout_seconds", 90))))
    cfg.language = str(payload.get("language") or "es").strip()[:16] or "es"
    cfg.custom_system_instructions = str(payload.get("custom_system_instructions") or "").strip()
    cfg.passive_discovery_enabled = bool(payload.get("passive_discovery_enabled", False))
    cfg.auto_audit_enabled = bool(payload.get("auto_audit_enabled", False))
    cfg.auto_audit_interval_hours = max(1, min(168, int(payload.get("auto_audit_interval_hours") or 24)))

    if payload.get("clear_api_key"):
        cfg.api_key_ciphertext = ""
    else:
        raw_key = payload.get("api_key")
        if raw_key is not None and str(raw_key).strip():
            cfg.api_key_ciphertext = encrypt_vault_secret(str(raw_key).strip())

    cfg.updated_by = updated_by
    cfg.updated_at = utcnow()
    db.commit()
    db.refresh(cfg)
    return cfg


def rotate_mcp_readonly_token(
    db: Session,
    updated_by: str = "admin",
    base_backend_url: str = "http://localhost:8180",
) -> Dict[str, Any]:
    """
    Genera o rota un token de solo-lectura para clientes MCP externos (`rackdoc-mcp`),
    almacenando únicamente su hash SHA-256 en base de datos.
    """
    cfg = get_or_create_ai_settings(db)
    raw_token = f"rdk_ro_{secrets.token_urlsafe(28)}"
    cfg.mcp_token_hash = hashlib.sha256(raw_token.encode("utf-8")).hexdigest()
    cfg.mcp_token_prefix = f"{raw_token[:12]}..."
    cfg.updated_by = updated_by
    cfg.updated_at = utcnow()
    db.commit()
    db.refresh(cfg)

    mcp_snippet = {
        "mcpServers": {
            "rackdoc-readonly": {
                "command": "python3",
                "args": ["backend/mcp_server/rackdoc_mcp.py"],
                "env": {
                    "RACKDOC_BASE_URL": base_backend_url.rstrip("/"),
                    "RACKDOC_AI_READONLY_KEY": raw_token,
                },
            }
        }
    }
    return {
        "raw_token": raw_token,
        "token_prefix": cfg.mcp_token_prefix,
        "mcp_client_config": mcp_snippet,
        "settings": serialize_ai_settings(cfg, base_backend_url=base_backend_url),
    }


def _candidate_ollama_urls(configured_url: str) -> List[str]:
    """
    Si el backend corre fuera de Docker en desarrollo y la URL es `http://rackdoc-ollama:11434`,
    prueba también `http://127.0.0.1:11434` automáticamente sin perder el valor por defecto Docker.
    """
    primary = (configured_url or DEFAULT_OLLAMA_BASE_URL).rstrip("/")
    candidates = [primary]
    if "rackdoc-ollama:11434" in primary:
        candidates.append("http://127.0.0.1:11434")
    return candidates


async def probe_ollama_status_async(db: Session) -> Dict[str, Any]:
    cfg = get_or_create_ai_settings(db)
    target_base = cfg.base_url if cfg.provider_type == "ollama_local" else DEFAULT_OLLAMA_BASE_URL
    last_err = ""

    for url in _candidate_ollama_urls(target_base):
        try:
            async with httpx.AsyncClient(timeout=4.5) as client:
                resp = await client.get(f"{url}/api/tags")
                resp.raise_for_status()
                data = resp.json()
                models_raw = data.get("models") or []
                installed = []
                for m in models_raw:
                    name = str(m.get("name") or "")
                    size_bytes = int(m.get("size") or 0)
                    installed.append(
                        {
                            "name": name,
                            "size_gb": round(size_bytes / (1024 ** 3), 2) if size_bytes else 0.0,
                            "modified_at": m.get("modified_at"),
                        }
                    )
                names_set = {m["name"] for m in installed}
                names_no_tag = {m["name"].split(":")[0] for m in installed}
                model_ready = (
                    cfg.model_name in names_set
                    or cfg.model_name.split(":")[0] in names_no_tag
                )
                return {
                    "reachable": True,
                    "resolved_url": url,
                    "configured_model": cfg.model_name,
                    "configured_model_installed": model_ready,
                    "installed_models": installed,
                    "recommended_models": RECOMMENDED_OLLAMA_MODELS,
                    "error": "",
                }
        except Exception as exc:
            last_err = str(exc)

    return {
        "reachable": False,
        "resolved_url": target_base,
        "configured_model": cfg.model_name,
        "configured_model_installed": False,
        "installed_models": [],
        "recommended_models": RECOMMENDED_OLLAMA_MODELS,
        "error": (
            f"No se pudo conectar con Ollama en '{target_base}' ({last_err}). "
            "Levanta el servicio con 'docker compose up -d rackdoc-ollama' o apunta a una instancia accesible."
        ),
    }


async def pull_ollama_model_async(db: Session, model_name: str) -> Dict[str, Any]:
    clean_model = (model_name or "").strip()
    if not clean_model:
        raise ValueError("Indica el nombre del modelo Ollama a descargar (ej. qwen2.5:7b).")

    cfg = get_or_create_ai_settings(db)
    target_base = cfg.base_url if cfg.provider_type == "ollama_local" else DEFAULT_OLLAMA_BASE_URL
    last_err = ""

    for url in _candidate_ollama_urls(target_base):
        try:
            async with httpx.AsyncClient(timeout=600.0) as client:
                resp = await client.post(
                    f"{url}/api/pull",
                    json={"name": clean_model, "stream": False},
                )
                resp.raise_for_status()
                body = resp.json() if resp.content else {}
                status_after = await probe_ollama_status_async(db)
                return {
                    "pulled": True,
                    "model_name": clean_model,
                    "ollama_status": body.get("status", "success"),
                    "probe": status_after,
                }
        except Exception as exc:
            last_err = str(exc)

    raise RuntimeError(
        f"No fue posible descargar el modelo '{clean_model}' en Ollama ({target_base}): {last_err}"
    )


# ==============================================================================
# 2. INVOCACIÓN AGNÓSTICA DE MODELOS (OLLAMA LOCAL / OPENAI / GEMINI / ANTHROPIC)
# ==============================================================================


async def invoke_llm_async(
    cfg: AiAgentSettings,
    system_prompt: str,
    messages: List[Dict[str, str]],
) -> Tuple[str, str, str]:
    """
    Ejecuta una completación de chat contra el proveedor configurado.
    Devuelve `(response_text, provider_used, model_used)`.
    """
    provider = cfg.provider_type or "ollama_local"
    model = cfg.model_name or DEFAULT_OLLAMA_MODEL
    timeout = float(cfg.timeout_seconds or 90)
    temperature = float(cfg.temperature if cfg.temperature is not None else 0.2)
    max_tokens = int(cfg.max_tokens or 2048)

    if provider == "ollama_local":
        ollama_msgs = [{"role": "system", "content": system_prompt}] + messages
        last_err = ""
        for url in _candidate_ollama_urls(cfg.base_url):
            try:
                async with httpx.AsyncClient(timeout=timeout) as client:
                    resp = await client.post(
                        f"{url}/api/chat",
                        json={
                            "model": model,
                            "messages": ollama_msgs,
                            "stream": False,
                            "options": {
                                "temperature": temperature,
                                "num_predict": max_tokens,
                            },
                        },
                    )
                    if resp.status_code == 404:
                        detail = resp.text[:240]
                        raise RuntimeError(
                            f"El modelo '{model}' aún no está descargado en Ollama ({url}). "
                            f"Descárgalo desde 9. Administración -> Motor IA. Detalle: {detail}"
                        )
                    resp.raise_for_status()
                    data = resp.json()
                    content = ((data.get("message") or {}).get("content") or "").strip()
                    if not content:
                        raise RuntimeError("Ollama devolvió una respuesta vacía.")
                    return content, "ollama_local", model
            except RuntimeError:
                raise
            except Exception as exc:
                last_err = str(exc)
        raise RuntimeError(f"Ollama local no disponible en '{cfg.base_url}': {last_err}")

    api_key = decrypt_vault_secret(cfg.api_key_ciphertext)
    if provider in ("gemini", "anthropic") and not api_key:
        raise RuntimeError(
            f"El proveedor externo '{provider}' requiere una API Key configurada en 9. Administración."
        )

    if provider == "openai_compatible":
        headers = {"Content-Type": "application/json"}
        if api_key:
            headers["Authorization"] = f"Bearer {api_key}"
        endpoint = cfg.base_url.rstrip("/")
        if not endpoint.endswith("/chat/completions"):
            endpoint = f"{endpoint}/chat/completions"
        oai_msgs = [{"role": "system", "content": system_prompt}] + messages
        async with httpx.AsyncClient(timeout=timeout) as client:
            resp = await client.post(
                endpoint,
                headers=headers,
                json={
                    "model": model,
                    "messages": oai_msgs,
                    "temperature": temperature,
                    "max_tokens": max_tokens,
                },
            )
            resp.raise_for_status()
            data = resp.json()
            choices = data.get("choices") or []
            if not choices:
                raise RuntimeError("El endpoint OpenAI-compatible no devolvió 'choices'.")
            content = ((choices[0].get("message") or {}).get("content") or "").strip()
            return content, "openai_compatible", model

    if provider == "gemini":
        base = cfg.base_url.rstrip("/")
        url = f"{base}/models/{model}:generateContent"
        contents = []
        for m in messages:
            role = "model" if m.get("role") == "assistant" else "user"
            contents.append({"role": role, "parts": [{"text": m.get("content", "")}]})
        async with httpx.AsyncClient(timeout=timeout) as client:
            resp = await client.post(
                url,
                params={"key": api_key},
                json={
                    "systemInstruction": {"parts": [{"text": system_prompt}]},
                    "contents": contents,
                    "generationConfig": {
                        "temperature": temperature,
                        "maxOutputTokens": max_tokens,
                    },
                },
            )
            resp.raise_for_status()
            data = resp.json()
            cands = data.get("candidates") or []
            parts = (((cands[0] if cands else {}).get("content") or {}).get("parts") or [])
            content = "\n".join(str(p.get("text", "")) for p in parts).strip()
            if not content:
                raise RuntimeError("Gemini no devolvió texto en 'candidates'.")
            return content, "gemini", model

    if provider == "anthropic":
        base = cfg.base_url.rstrip("/")
        url = base if base.endswith("/v1/messages") else f"{base}/v1/messages"
        async with httpx.AsyncClient(timeout=timeout) as client:
            resp = await client.post(
                url,
                headers={
                    "x-api-key": api_key,
                    "anthropic-version": "2023-06-01",
                    "content-type": "application/json",
                },
                json={
                    "model": model,
                    "system": system_prompt,
                    "max_tokens": max_tokens,
                    "temperature": temperature,
                    "messages": messages,
                },
            )
            resp.raise_for_status()
            data = resp.json()
            blocks = data.get("content") or []
            content = "\n".join(
                str(b.get("text", "")) for b in blocks if b.get("type") == "text"
            ).strip()
            if not content:
                raise RuntimeError("Anthropic no devolvió bloques de texto.")
            return content, "anthropic", model

    raise ValueError(f"Proveedor desconocido: {provider}")


async def test_ai_provider_connection_async(db: Session) -> Dict[str, Any]:
    cfg = get_or_create_ai_settings(db)
    t0 = time.perf_counter()
    try:
        reply, provider, model = await invoke_llm_async(
            cfg=cfg,
            system_prompt="Eres el verificador de salud de RackDoc AI. Sé conciso.",
            messages=[
                {
                    "role": "user",
                    "content": "Responde en una sola frase confirmando que estás operativo en modo solo-lectura.",
                }
            ],
        )
        elapsed_ms = round((time.perf_counter() - t0) * 1000, 1)
        return {
            "ok": True,
            "provider_type": provider,
            "model_name": model,
            "latency_ms": elapsed_ms,
            "sample_reply": reply[:300],
            "error": "",
        }
    except Exception as exc:
        elapsed_ms = round((time.perf_counter() - t0) * 1000, 1)
        return {
            "ok": False,
            "provider_type": cfg.provider_type,
            "model_name": cfg.model_name,
            "latency_ms": elapsed_ms,
            "sample_reply": "",
            "error": str(exc),
        }


# ==============================================================================
# 3. GRAFO FEDERADO SOLO-LECTURA Y DETECTOR DETERMINISTA DE RIESGOS / SPOFs
# ==============================================================================


def query_prometheus_readonly_instant(promql: str) -> Dict[str, Any]:
    """
    Consulta PromQL estrictamente de solo lectura (`GET /api/v1/query`) contra
    `rackdoc-prometheus`. Si Prometheus no está levantado en local, degrada en limpio.
    """
    clean_q = (promql or "").strip()
    if not clean_q or len(clean_q) > 400:
        raise ValueError("Consulta PromQL vacía o demasiado larga (máximo 400 caracteres).")
    try:
        with httpx.Client(timeout=3.0) as client:
            resp = client.get(
                f"{PROMETHEUS_INTERNAL_URL.rstrip('/')}/api/v1/query",
                params={"query": clean_q},
            )
            resp.raise_for_status()
            payload = resp.json()
            return sanitize_context_payload(
                {
                    "reachable": True,
                    "query": clean_q,
                    "data": payload.get("data", {}),
                }
            )
    except Exception as exc:
        return {
            "reachable": False,
            "query": clean_q,
            "data": {"resultType": "vector", "result": []},
            "note": f"Prometheus TSDB no accesible en este momento: {exc}",
        }


def build_federated_readonly_snapshot(
    db: Session,
    scope_type: str = "global_cpd",
    scope_target_id: Optional[int] = None,
) -> Dict[str, Any]:
    """
    Construye una radiografía completa y 100% sanitizada de la infraestructura
    registrada en RackDoc, más los hallazgos deterministas de SPOF, monitorización,
    certificados y deriva documental.
    """
    if scope_type not in ALLOWED_SCOPES:
        raise ValueError(f"Ámbito '{scope_type}' no válido. Usa uno de {ALLOWED_SCOPES}.")

    locations = (
        db.query(Location)
        .options(joinedload(Location.floors))
        .order_by(Location.id.asc())
        .all()
    )
    racks = (
        db.query(Rack)
        .options(
            joinedload(Rack.room),
            joinedload(Rack.devices).joinedload(RackDevice.template),
            joinedload(Rack.devices).joinedload(RackDevice.ports),
        )
        .order_by(Rack.id.asc())
        .all()
    )
    connections = (
        db.query(Connection)
        .options(
            joinedload(Connection.source_port).joinedload(Port.device).joinedload(RackDevice.rack),
            joinedload(Connection.target_port).joinedload(Port.device).joinedload(RackDevice.rack),
        )
        .all()
    )
    assets = (
        db.query(CmdbAsset)
        .options(joinedload(CmdbAsset.ip_addresses), joinedload(CmdbAsset.host_rack_device))
        .order_by(CmdbAsset.id.asc())
        .all()
    )
    subnets = db.query(CmdbSubnet).order_by(CmdbSubnet.id.asc()).all()
    host_groups = db.query(HostGroup).order_by(HostGroup.id.asc()).all()
    service_checks = db.query(MonitoredServiceCheck).all()
    logical_links = db.query(LogicalTopologyLink).all()
    routing_rules = db.query(NotificationRoutingRule).filter(NotificationRoutingRule.enabled.is_(True)).all()
    contacts = db.query(AlertContact).filter(AlertContact.active.is_(True)).all()
    contact_groups = db.query(AlertContactGroup).all()
    stacks = db.query(TechStackDiagram).order_by(TechStackDiagram.id.asc()).all()
    stack_nodes = db.query(TechStackNode).all()
    stack_edges = db.query(TechStackEdge).all()
    certs = db.query(TlsCertificate).order_by(TlsCertificate.id.asc()).all()

    floor_to_loc: Dict[int, Location] = {}
    for loc in locations:
        for fl in loc.floors:
            floor_to_loc[fl.id] = loc

    rack_by_id: Dict[int, Rack] = {rk.id: rk for rk in racks}
    rack_dev_by_id: Dict[int, RackDevice] = {}
    for rk in racks:
        for dv in rk.devices:
            rack_dev_by_id[dv.id] = dv

    asset_by_id: Dict[int, CmdbAsset] = {a.id: a for a in assets}

    # Contabilizar acometidas eléctricas (`power_ac`) y cables de datos por RackDevice
    power_feeds_by_dev: Dict[int, int] = {}
    data_cables_by_dev: Dict[int, int] = {}
    cabling_items: List[Dict[str, Any]] = []
    for conn in connections:
        sp = conn.source_port
        tp = conn.target_port
        if not sp or not tp or not sp.device or not tp.device:
            continue
        is_power = (conn.cable_type == "power_ac") or ("power" in (sp.port_type or "")) or ("power" in (tp.port_type or ""))
        if is_power:
            power_feeds_by_dev[sp.device.id] = power_feeds_by_dev.get(sp.device.id, 0) + 1
            power_feeds_by_dev[tp.device.id] = power_feeds_by_dev.get(tp.device.id, 0) + 1
        else:
            data_cables_by_dev[sp.device.id] = data_cables_by_dev.get(sp.device.id, 0) + 1
            data_cables_by_dev[tp.device.id] = data_cables_by_dev.get(tp.device.id, 0) + 1
        cabling_items.append(
            {
                "id": conn.id,
                "cable_type": conn.cable_type,
                "vlan": conn.vlan,
                "label": conn.label or "",
                "source_rack": sp.device.rack.code if sp.device.rack else "",
                "source_device": sp.device.code,
                "source_port": sp.port_number,
                "target_rack": tp.device.rack.code if tp.device.rack else "",
                "target_device": tp.device.code,
                "target_port": tp.port_number,
            }
        )

    checks_by_asset: Dict[int, List[MonitoredServiceCheck]] = {}
    for chk in service_checks:
        checks_by_asset.setdefault(chk.asset_id, []).append(chk)

    groups_by_asset: Dict[int, List[HostGroup]] = {}
    for hg in host_groups:
        for aid in (hg.member_asset_ids or []):
            try:
                groups_by_asset.setdefault(int(aid), []).append(hg)
            except (TypeError, ValueError):
                continue

    # Cobertura de reglas de guardia SRE por activo
    has_global_rule = any(r.scope_type == "all" for r in routing_rules)
    covered_group_ids = {r.host_group_id for r in routing_rules if r.scope_type == "host_group" and r.host_group_id}
    covered_asset_ids = {r.asset_id for r in routing_rules if r.scope_type == "single_host" and r.asset_id}
    covered_classes = {r.asset_class_filter for r in routing_rules if r.scope_type == "asset_class" and r.asset_class_filter}

    def _is_asset_sre_covered(asset_obj: CmdbAsset) -> bool:
        if has_global_rule or asset_obj.id in covered_asset_ids or asset_obj.asset_class in covered_classes:
            return True
        asset_hgs = groups_by_asset.get(asset_obj.id, [])
        return any(g.id in covered_group_ids for g in asset_hgs)

    def _resolve_physical_rack_for_asset(asset_obj: CmdbAsset) -> Tuple[Optional[Rack], Optional[RackDevice]]:
        if asset_obj.rack_device_id and asset_obj.rack_device_id in rack_dev_by_id:
            rd = rack_dev_by_id[asset_obj.rack_device_id]
            return rack_by_id.get(rd.rack_id), rd
        if asset_obj.host_rack_device_id and asset_obj.host_rack_device_id in rack_dev_by_id:
            rd = rack_dev_by_id[asset_obj.host_rack_device_id]
            return rack_by_id.get(rd.rack_id), rd
        if asset_obj.parent_asset_id and asset_obj.parent_asset_id in asset_by_id:
            parent = asset_by_id[asset_obj.parent_asset_id]
            if parent.rack_device_id and parent.rack_device_id in rack_dev_by_id:
                rd = rack_dev_by_id[parent.rack_device_id]
                return rack_by_id.get(rd.rack_id), rd
        return None, None

    # --- Resumen de Racks ---
    rack_summaries: List[Dict[str, Any]] = []
    findings: List[Dict[str, Any]] = []

    for rk in racks:
        used_u = 0
        power_units = 0
        net_units = 0
        server_units = 0
        dev_list = []
        for dv in sorted(rk.devices, key=lambda d: d.start_u, reverse=True):
            cat = dv.template.category if dv.template else "miscellaneous"
            uh = dv.template.u_height if dv.template else 1
            if dv.mounted_face != "external":
                used_u += uh
            if cat in ("pdu", "ups", "external_power_feed", "schuko"):
                power_units += 1
            elif cat in ("switch", "router", "firewall", "gateway"):
                net_units += 1
            elif cat in ("server", "storage"):
                server_units += 1
            dev_list.append(
                {
                    "id": dv.id,
                    "code": dv.code,
                    "name": dv.name,
                    "category": cat,
                    "model": f"{dv.template.manufacturer} {dv.template.model_name}" if dv.template else "",
                    "u_range": f"U{dv.start_u}-U{dv.start_u + uh - 1}" if uh > 1 else f"U{dv.start_u}",
                    "ip_address": dv.ip_address or "",
                    "status": dv.status,
                    "power_cables": power_feeds_by_dev.get(dv.id, 0),
                    "data_cables": data_cables_by_dev.get(dv.id, 0),
                }
            )

        loc_obj = floor_to_loc.get(rk.room.floor_id) if rk.room else None
        occ_pct = round((used_u / max(1, rk.total_units)) * 100, 1)
        rack_summaries.append(
            {
                "id": rk.id,
                "code": rk.code,
                "name": rk.name,
                "location_id": loc_obj.id if loc_obj else None,
                "location_name": loc_obj.name if loc_obj else "",
                "room_name": rk.room.name if rk.room else "",
                "total_units": rk.total_units,
                "used_units": used_u,
                "occupancy_pct": occ_pct,
                "power_devices_count": power_units,
                "network_devices_count": net_units,
                "server_devices_count": server_units,
                "responsible_person": rk.responsible_person,
                "devices": dev_list,
            }
        )

        if server_units > 0 and power_units < 2:
            findings.append(
                {
                    "severity": "warning",
                    "category": "SPOF Eléctrico",
                    "target_code": rk.code,
                    "title": f"Rack {rk.code} sin doble cadena eléctrica (PDU/SAI redundante)",
                    "detail": (
                        f"El bastidor '{rk.name}' aloja {server_units} equipo(s) de cómputo pero solo tiene "
                        f"{power_units} elemento(s) de distribución/respaldo eléctrico registrado(s)."
                    ),
                }
            )

    # --- Resumen de Activos CMDB y detección de brechas ---
    asset_summaries: List[Dict[str, Any]] = []
    for a in assets:
        if a.lifecycle_status == "decommissioned":
            continue
        rk_obj, rd_obj = _resolve_physical_rack_for_asset(a)
        ips = [ip.ip_address for ip in a.ip_addresses]
        a_checks = checks_by_asset.get(a.id, [])
        crit_checks = [c.service_name for c in a_checks if c.nagios_state in ("CRITICAL", "WARNING")]
        sre_covered = _is_asset_sre_covered(a)

        asset_summaries.append(
            {
                "id": a.id,
                "code": a.code,
                "name": a.name,
                "hostname": a.hostname or "",
                "asset_class": a.asset_class,
                "environment": a.environment,
                "criticality": a.criticality,
                "os_or_firmware": a.os_or_firmware or "",
                "cpu_cores": a.cpu_cores,
                "ram_gb": a.ram_gb,
                "storage_gb": a.storage_gb,
                "owner_team": a.owner_team or "",
                "status": a.status,
                "ips": ips,
                "rack_code": rk_obj.code if rk_obj else "",
                "host_rack_device_code": rd_obj.code if rd_obj else "",
                "host_groups": [g.code for g in groups_by_asset.get(a.id, [])],
                "checks_count": len(a_checks),
                "degraded_checks": crit_checks,
                "sre_alert_covered": sre_covered,
                "has_notes": bool((a.notes or "").strip()),
            }
        )

        if a.environment == "production" and a.criticality == "critical":
            if not sre_covered:
                findings.append(
                    {
                        "severity": "high",
                        "category": "Gobierno SRE",
                        "target_code": a.code,
                        "title": f"Activo crítico '{a.code}' sin regla de guardia SRE activa",
                        "detail": (
                            f"'{a.name}' ({', '.join(ips) or 'sin IP'}) está marcado como production/critical "
                            "pero ninguna regla en 8. Alarmas SRE enruta sus caídas a un equipo de guardia."
                        ),
                    }
                )
            if not a.monitoring_enabled and len(a_checks) == 0:
                findings.append(
                    {
                        "severity": "high",
                        "category": "Ceguera Operativa",
                        "target_code": a.code,
                        "title": f"Activo crítico '{a.code}' sin monitorización Heartbeat ni chequeos Nagios",
                        "detail": f"'{a.name}' no tiene monitorización ICMP/TCP ni chequeos de servicio configurados.",
                    }
                )

        if not (a.notes or "").strip():
            findings.append(
                {
                    "severity": "info",
                    "category": "Deriva Documental CMDB",
                    "target_code": a.code,
                    "title": f"Ficha CMDB de '{a.code}' sin descripción funcional/operativa",
                    "detail": f"El activo '{a.name}' carece de notas técnicas documentadas en la CMDB.",
                }
            )

    # --- Detección de SPOF Físico/Virtualización en Grupos de Hosts ---
    for hg in host_groups:
        member_objs = [
            asset_by_id[int(aid)]
            for aid in (hg.member_asset_ids or [])
            if str(aid).isdigit() and int(aid) in asset_by_id
        ]
        if len(member_objs) >= 2:
            racks_set = set()
            hypervisors_set = set()
            for m in member_objs:
                rk_m, rd_m = _resolve_physical_rack_for_asset(m)
                if rk_m:
                    racks_set.add(rk_m.code)
                if m.host_rack_device_id and rd_m:
                    hypervisors_set.add(rd_m.code)
            if len(hypervisors_set) == 1 and all(m.host_rack_device_id for m in member_objs):
                hyp_code = next(iter(hypervisors_set))
                findings.append(
                    {
                        "severity": "critical",
                        "category": "SPOF Hipervisor",
                        "target_code": hg.code,
                        "title": f"SPOF en grupo '{hg.name}': todos sus miembros residen en {hyp_code}",
                        "detail": (
                            f"Los {len(member_objs)} nodos del grupo '{hg.code}' dependen del mismo servidor físico "
                            f"'{hyp_code}'. Un fallo hardware tumbaría el grupo completo."
                        ),
                    }
                )
            elif len(racks_set) == 1 and len(racks) > 1:
                rk_code = next(iter(racks_set))
                findings.append(
                    {
                        "severity": "warning",
                        "category": "SPOF de Bastidor",
                        "target_code": hg.code,
                        "title": f"Concentración física del grupo '{hg.name}' en un único Rack ({rk_code})",
                        "detail": (
                            f"Todos los activos ubicados de '{hg.code}' están concentrados en '{rk_code}' "
                            "pese a existir múltiples racks disponibles en el CPD."
                        ),
                    }
                )

    # --- Riesgos CertScope TLS ---
    cert_summaries: List[Dict[str, Any]] = []
    for cert in certs:
        cert_summaries.append(
            {
                "id": cert.id,
                "code": cert.code,
                "name": cert.name,
                "target": f"{cert.target_host}:{cert.port}",
                "environment": cert.environment,
                "status": cert.status,
                "days_remaining": cert.days_remaining,
                "is_self_signed": bool(cert.is_self_signed),
                "asset_id": cert.asset_id,
            }
        )
        if cert.days_remaining is not None and cert.days_remaining <= 30:
            sev = "critical" if cert.days_remaining <= 7 else "high"
            findings.append(
                {
                    "severity": sev,
                    "category": "Caducidad TLS (CertScope)",
                    "target_code": cert.code,
                    "title": f"Certificado '{cert.name}' vence en {cert.days_remaining} día(s)",
                    "detail": f"Endpoint {cert.target_host}:{cert.port} ({cert.environment}) en estado '{cert.status}'.",
                }
            )
        if cert.environment == "production" and cert.is_self_signed:
            findings.append(
                {
                    "severity": "warning",
                    "category": "Seguridad TLS",
                    "target_code": cert.code,
                    "title": f"Certificado autofirmado en producción ({cert.target_host}:{cert.port})",
                    "detail": f"'{cert.name}' utiliza un certificado X.509 autofirmado en entorno productivo.",
                }
            )

    # --- Stacks Tecnológicos 2D ---
    nodes_by_stack: Dict[int, List[TechStackNode]] = {}
    for sn in stack_nodes:
        nodes_by_stack.setdefault(sn.stack_id, []).append(sn)
    edges_by_stack: Dict[int, List[TechStackEdge]] = {}
    for se in stack_edges:
        edges_by_stack.setdefault(se.stack_id, []).append(se)

    stack_summaries: List[Dict[str, Any]] = []
    node_by_id: Dict[int, TechStackNode] = {n.id: n for n in stack_nodes}
    for st in stacks:
        st_nodes = nodes_by_stack.get(st.id, [])
        st_edges = edges_by_stack.get(st.id, [])
        stack_summaries.append(
            {
                "id": st.id,
                "code": st.code,
                "name": st.name,
                "business_service": st.business_service,
                "environment": st.environment,
                "criticality": st.criticality,
                "owner_team": st.owner_team,
                "nodes": [
                    {
                        "node_id": n.id,
                        "role_layer": n.role_layer,
                        "label": n.custom_label or (asset_by_id[n.asset_id].name if n.asset_id in asset_by_id else ""),
                        "asset_code": asset_by_id[n.asset_id].code if n.asset_id in asset_by_id else "",
                        "rack_code": (
                            _resolve_physical_rack_for_asset(asset_by_id[n.asset_id])[0].code
                            if n.asset_id in asset_by_id and _resolve_physical_rack_for_asset(asset_by_id[n.asset_id])[0]
                            else ""
                        ),
                    }
                    for n in st_nodes
                ],
                "edges": [
                    {
                        "from": (
                            asset_by_id[node_by_id[e.source_node_id].asset_id].code
                            if e.source_node_id in node_by_id and node_by_id[e.source_node_id].asset_id in asset_by_id
                            else str(e.source_node_id)
                        ),
                        "to": (
                            asset_by_id[node_by_id[e.target_node_id].asset_id].code
                            if e.target_node_id in node_by_id and node_by_id[e.target_node_id].asset_id in asset_by_id
                            else str(e.target_node_id)
                        ),
                        "protocol": e.protocol_label,
                        "port": e.port,
                    }
                    for e in st_edges
                ],
            }
        )

    # Ordenar hallazgos por severidad
    sev_rank = {"critical": 0, "high": 1, "warning": 2, "info": 3}
    findings.sort(key=lambda f: sev_rank.get(f["severity"], 9))

    # Filtrado focalizado según `scope_type` y `scope_target_id`
    scope_label = "CPD Completo (Global)"
    focused_racks = rack_summaries
    focused_assets = asset_summaries
    focused_stacks = stack_summaries
    focused_cabling = cabling_items[:80]

    if scope_type == "location" and scope_target_id is not None:
        loc_match = next((l for l in locations if l.id == scope_target_id), None)
        if not loc_match:
            raise ValueError(f"Sede con id={scope_target_id} no encontrada.")
        scope_label = f"Sede {loc_match.code} — {loc_match.name}"
        focused_racks = [r for r in rack_summaries if r["location_id"] == loc_match.id]
        rk_codes = {r["code"] for r in focused_racks}
        focused_assets = [a for a in asset_summaries if a["rack_code"] in rk_codes]
        focused_cabling = [
            c for c in cabling_items if c["source_rack"] in rk_codes or c["target_rack"] in rk_codes
        ][:80]

    elif scope_type == "rack" and scope_target_id is not None:
        rk_match = next((r for r in rack_summaries if r["id"] == scope_target_id), None)
        if not rk_match:
            raise ValueError(f"Rack con id={scope_target_id} no encontrado.")
        scope_label = f"Rack {rk_match['code']} — {rk_match['name']}"
        focused_racks = [rk_match]
        focused_assets = [a for a in asset_summaries if a["rack_code"] == rk_match["code"]]
        focused_cabling = [
            c for c in cabling_items
            if c["source_rack"] == rk_match["code"] or c["target_rack"] == rk_match["code"]
        ]
        findings = [
            f for f in findings
            if f["target_code"] == rk_match["code"]
            or f["target_code"] in {a["code"] for a in focused_assets}
        ] or findings[:10]

    elif scope_type == "logical_stack" and scope_target_id is not None:
        st_match = next((s for s in stack_summaries if s["id"] == scope_target_id), None)
        if not st_match:
            raise ValueError(f"Stack Tecnológico con id={scope_target_id} no encontrado.")
        scope_label = f"Stack {st_match['code']} — {st_match['name']}"
        focused_stacks = [st_match]
        st_asset_codes = {n["asset_code"] for n in st_match["nodes"] if n["asset_code"]}
        focused_assets = [a for a in asset_summaries if a["code"] in st_asset_codes]
        st_rack_codes = {a["rack_code"] for a in focused_assets if a["rack_code"]}
        focused_racks = [r for r in rack_summaries if r["code"] in st_rack_codes]
        findings = [f for f in findings if f["target_code"] in st_asset_codes or f["target_code"] in st_rack_codes]

    elif scope_type == "host" and scope_target_id is not None:
        a_match = next((a for a in asset_summaries if a["id"] == scope_target_id), None)
        if not a_match:
            raise ValueError(f"Activo CMDB con id={scope_target_id} no encontrado.")
        scope_label = f"Host {a_match['code']} — {a_match['name']}"
        focused_assets = [a_match]
        focused_racks = [r for r in rack_summaries if r["code"] == a_match["rack_code"]]
        findings = [f for f in findings if f["target_code"] in (a_match["code"], a_match["rack_code"])]

    elif scope_type == "spof_risk_audit":
        scope_label = "Auditoría Integral de SPOFs, Riesgos SRE y Deriva Documental"

    # Fase 2: Incorporar instantáneas recientes de Descubrimiento Pasivo RO (SSH/WinRM/SNMP)
    ro_rows = (
        db.query(AiPassiveDiscoverySnapshot)
        .filter(AiPassiveDiscoverySnapshot.status == "completed")
        .order_by(AiPassiveDiscoverySnapshot.id.desc())
        .limit(40)
        .all()
    )
    seen_ro_targets = set()
    latest_ro_snaps: List[Dict[str, Any]] = []
    passive_mermaid_links: List[Dict[str, str]] = []
    for rs in ro_rows:
        tkey = (rs.collector_type, rs.target_host)
        if tkey in seen_ro_targets:
            continue
        seen_ro_targets.add(tkey)
        latest_ro_snaps.append(
            {
                "id": rs.id,
                "collector_type": rs.collector_type,
                "target_host": rs.target_host,
                "asset_code": asset_by_id[rs.asset_id].code if rs.asset_id and rs.asset_id in asset_by_id else "",
                "hostname_detected": rs.hostname_detected,
                "os_or_sysdescr": rs.os_or_sysdescr,
                "listening_ports_sample": (rs.listening_ports or [])[:15],
                "peer_connections_sample": (rs.peer_connections or [])[:15],
                "containers_sample": (rs.containers or [])[:10],
                "snmp_interfaces_count": len(rs.snmp_interfaces or []),
                "inferred_dependencies": rs.inferred_dependencies or [],
            }
        )
        for dep in (rs.inferred_dependencies or []):
            if dep.get("source_code") and dep.get("target_code"):
                passive_mermaid_links.append(
                    {
                        "source": str(dep["source_code"]),
                        "target": str(dep["target_code"]),
                        "label": f"RO: {dep.get('protocol_label', 'TCP')}",
                    }
                )

    combined_mermaid_links = [
        {
            "source": asset_by_id[lk.source_asset_id].code if lk.source_asset_id in asset_by_id else "",
            "target": asset_by_id[lk.target_asset_id].code if lk.target_asset_id in asset_by_id else "",
            "label": lk.protocol_label or lk.link_type,
        }
        for lk in logical_links
    ] + passive_mermaid_links

    mermaid = build_scope_mermaid_diagram(
        scope_type=scope_type,
        scope_label=scope_label,
        racks=focused_racks,
        assets=focused_assets,
        stacks=focused_stacks,
        logical_links=combined_mermaid_links,
    )

    snapshot = {
        "generated_at": utcnow().isoformat(),
        "readonly_mode": True,
        "scope_type": scope_type,
        "scope_target_id": scope_target_id,
        "scope_label": scope_label,
        "kpis": {
            "locations_count": len(locations),
            "racks_count": len(racks),
            "cabling_connections_count": len(cabling_items),
            "active_cmdb_assets_count": len(asset_summaries),
            "ipam_subnets_count": len(subnets),
            "tech_stacks_count": len(stack_summaries),
            "service_checks_count": len(service_checks),
            "tls_certificates_count": len(cert_summaries),
            "sre_contacts_count": len(contacts),
            "sre_contact_groups_count": len(contact_groups),
            "findings_critical_or_high": sum(1 for f in findings if f["severity"] in ("critical", "high")),
            "findings_total": len(findings),
        },
        "locations": [
            {
                "id": l.id,
                "code": l.code,
                "name": l.name,
                "address": l.address,
                "floors_count": len(l.floors),
            }
            for l in locations
        ],
        "racks": focused_racks[:25],
        "assets": focused_assets[:60],
        "subnets": [
            {
                "cidr": s.cidr,
                "name": s.name,
                "vlan_id": s.vlan_id,
                "gateway": s.gateway,
                "environment": s.environment,
            }
            for s in subnets[:30]
        ],
        "tech_stacks": focused_stacks[:15],
        "cabling_sample": focused_cabling[:40],
        "certificates": cert_summaries[:30],
        "findings": findings[:40],
        "mermaid_diagram": mermaid,
        "phase2_passive_discovery_slot": {
            "status": "active" if latest_ro_snaps else "ready_no_snapshots_yet",
            "supported_collectors": ["ssh_linux_ro", "winrm_windows_ro", "snmp_if_lldp_ro"],
            "snapshots_count": len(latest_ro_snaps),
            "collected_snapshots": latest_ro_snaps[:20],
        },
    }
    return sanitize_context_payload(snapshot)


def build_scope_mermaid_diagram(
    scope_type: str,
    scope_label: str,
    racks: List[Dict[str, Any]],
    assets: List[Dict[str, Any]],
    stacks: List[Dict[str, Any]],
    logical_links: List[Dict[str, str]],
) -> str:
    """Genera un diagrama Mermaid válido y auto-contenido para el alcance seleccionado."""
    lines = ["flowchart TD"]
    root_lbl = _mermaid_safe_label(scope_label)
    lines.append(f'    ROOT["{root_lbl}"]')

    if scope_type == "logical_stack" and stacks:
        st = stacks[0]
        for idx, n in enumerate(st.get("nodes", [])[:20]):
            code = n.get("asset_code") or f"N{idx}"
            nid = re.sub(r"[^A-Za-z0-9_]", "_", code)
            rk_tag = f" ({n['rack_code']})" if n.get("rack_code") else ""
            lbl = _mermaid_safe_label(f"{code}: {n.get('label', '')}{rk_tag}")
            lines.append(f'    N_{nid}["{lbl}"]')
            lines.append(f"    ROOT --> N_{nid}")
        for edge in st.get("edges", [])[:25]:
            s_id = re.sub(r"[^A-Za-z0-9_]", "_", edge.get("from", ""))
            t_id = re.sub(r"[^A-Za-z0-9_]", "_", edge.get("to", ""))
            plbl = _mermaid_safe_label(edge.get("protocol", "TCP"))
            if s_id and t_id:
                lines.append(f'    N_{s_id} -->|"{plbl}"| N_{t_id}')
        return "\n".join(lines)

    for rk in racks[:8]:
        rk_id = re.sub(r"[^A-Za-z0-9_]", "_", rk["code"])
        rk_lbl = _mermaid_safe_label(
            f"Rack {rk['code']} ({rk['used_units']}/{rk['total_units']}U - {rk['occupancy_pct']}%)"
        )
        lines.append(f'    R_{rk_id}["{rk_lbl}"]')
        lines.append(f"    ROOT --> R_{rk_id}")
        for dv in rk.get("devices", [])[:8]:
            dv_id = re.sub(r"[^A-Za-z0-9_]", "_", f"{rk['code']}_{dv['code']}")
            dv_lbl = _mermaid_safe_label(f"{dv['u_range']} {dv['code']} - {dv['name']}")
            lines.append(f'    D_{dv_id}["{dv_lbl}"]')
            lines.append(f"    R_{rk_id} --> D_{dv_id}")

    asset_codes_drawn = set()
    for a in assets[:15]:
        a_id = re.sub(r"[^A-Za-z0-9_]", "_", a["code"])
        asset_codes_drawn.add(a["code"])
        ip_txt = a["ips"][0] if a.get("ips") else "sin-IP"
        a_lbl = _mermaid_safe_label(f"{a['code']} ({a['asset_class']}) {ip_txt}")
        lines.append(f'    A_{a_id}["{a_lbl}"]')
        if a.get("rack_code"):
            rk_id = re.sub(r"[^A-Za-z0-9_]", "_", a["rack_code"])
            lines.append(f"    R_{rk_id} -.-> A_{a_id}")
        else:
            lines.append(f"    ROOT -.-> A_{a_id}")

    for lk in logical_links[:18]:
        if lk["source"] in asset_codes_drawn and lk["target"] in asset_codes_drawn:
            s_id = re.sub(r"[^A-Za-z0-9_]", "_", lk["source"])
            t_id = re.sub(r"[^A-Za-z0-9_]", "_", lk["target"])
            llbl = _mermaid_safe_label(lk["label"])
            lines.append(f'    A_{s_id} -->|"{llbl}"| A_{t_id}')

    return "\n".join(lines)


# ==============================================================================
# 4. AUTODOCUMENTACIÓN, RESPALDO DETERMINISTA Y CHAT SOLO-LECTURA
# ==============================================================================


def _render_deterministic_dossier_markdown(
    snapshot: Dict[str, Any],
    fallback_reason: str = "",
) -> str:
    """
    Construye un dossier técnico completo y riguroso directamente desde el grafo
    verificado cuando el motor LLM aún no tiene descargado su modelo local o no responde.
    """
    kpis = snapshot["kpis"]
    findings = snapshot["findings"]
    mermaid = snapshot["mermaid_diagram"]
    lines = [
        f"# Dossier de Infraestructura — {snapshot['scope_label']}",
        "",
        f"> **Modo de seguridad**: `100% Solo-Lectura` | **Generado**: `{snapshot['generated_at']}`",
    ]
    if fallback_reason:
        lines.extend(
            [
                "",
                f"> **Nota del Motor IA**: Informe compilado por el motor determinista de RackDoc "
                f"({fallback_reason}). Puedes descargar/activar `{DEFAULT_OLLAMA_MODEL}` en "
                "`9. Administración -> Motor IA` para añadir redacción ejecutiva con LLM local.",
            ]
        )

    lines.extend(
        [
            "",
            "## 1. Resumen Ejecutivo de Capacidad y Estado",
            "",
            "| Indicador | Valor |",
            "| :--- | :--- |",
            f"| Sedes / CPDs | `{kpis['locations_count']}` |",
            f"| Bastidores Racks | `{kpis['racks_count']}` |",
            f"| Latiguillos / Acometidas documentadas | `{kpis['cabling_connections_count']}` |",
            f"| Activos activos en CMDB | `{kpis['active_cmdb_assets_count']}` |",
            f"| Subredes IPAM | `{kpis['ipam_subnets_count']}` |",
            f"| Stacks Tecnológicos 2D | `{kpis['tech_stacks_count']}` |",
            f"| Certificados X.509 (`CertScope`) | `{kpis['tls_certificates_count']}` |",
            f"| Hallazgos Críticos / Altos | `{kpis['findings_critical_or_high']}` (de `{kpis['findings_total']}` totales) |",
            "",
            "## 2. Topología Física y Lógica (Mermaid)",
            "",
            "```mermaid",
            mermaid,
            "```",
            "",
            "## 3. Auditoría de Puntos Únicos de Fallo (SPOF), Guardias SRE y Riesgos",
            "",
        ]
    )

    if not findings:
        lines.append("- Sin hallazgos críticos ni advertencias detectadas en el alcance analizado.")
    else:
        for f in findings[:25]:
            badge = f["severity"].upper()
            lines.append(
                f"- **[{badge}] [{f['category']}] `{f['target_code']}` — {f['title']}**: {f['detail']}"
            )

    lines.extend(["", "## 4. Inventario de Bastidores en Alcance", ""])
    if not snapshot["racks"]:
        lines.append("_No hay bastidores registrados en este alcance._")
    else:
        lines.append("| Rack | Sala / Sede | Ocupación U | Red | Servidores | Energía (PDU/SAI) | Responsable |")
        lines.append("| :--- | :--- | :--- | :--- | :--- | :--- | :--- |")
        for rk in snapshot["racks"]:
            lines.append(
                f"| `{rk['code']}` | {rk['room_name']} ({rk['location_name']}) | "
                f"`{rk['used_units']}/{rk['total_units']}U` ({rk['occupancy_pct']}%) | "
                f"`{rk['network_devices_count']}` | `{rk['server_devices_count']}` | "
                f"`{rk['power_devices_count']}` | {rk['responsible_person']} |"
            )

    lines.extend(["", "## 5. Activos CMDB, Monitorización y Cobertura de Guardia SRE", ""])
    if not snapshot["assets"]:
        lines.append("_No hay activos CMDB en este alcance._")
    else:
        lines.append("| Código | Nombre | Clase | Criticidad | IPs | Rack | Guardia SRE | Estado |")
        lines.append("| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |")
        for a in snapshot["assets"][:35]:
            ips_str = ", ".join(a["ips"][:2]) or "—"
            sre_txt = "Cubierto" if a["sre_alert_covered"] else "SIN REGLA"
            lines.append(
                f"| `{a['code']}` | {a['name']} | `{a['asset_class']}` | `{a['criticality']}` | "
                f"`{ips_str}` | `{a['rack_code'] or '—'}` | **{sre_txt}** | `{a['status']}` |"
            )

    return "\n".join(lines)


def _build_documenter_system_prompt(cfg: AiAgentSettings) -> str:
    extra = f"\nInstrucciones adicionales del administrador:\n{cfg.custom_system_instructions}" if (cfg.custom_system_instructions or "").strip() else ""
    return (
        "Eres 'RackDoc AI Auditor', un Arquitecto Senior de Sistemas, Redes DCIM y SRE operando "
        "en modo ESTRICTAMENTE SOLO-LECTURA sobre la infraestructura de centros de datos de RackDoc8.\n"
        "Reglas inquebrantables:\n"
        "1. Basa TODOS los nombres de racks, códigos, direcciones IP, métricas y hallazgos EXCLUSIVAMENTE "
        "en el JSON de contexto verificado que recibes. Jamás inventes IPs, equipos ni cifras.\n"
        "2. Redacta en español técnico claro usando formato GitHub-Flavored Markdown estructurado: "
        "Resumen Ejecutivo, Arquitectura y Dependencias, Análisis de SPOFs y Riesgos Operativos, "
        "Cobertura de Monitorización/Certificados/Guardias SRE y Plan de Acción / Runbook DRP.\n"
        "3. Incluye el bloque ```mermaid proporcionado en el contexto (puedes enriquecer la explicación alrededor).\n"
        "4. Nunca propongas ejecutar comandos destructivos; enfócate en resiliencia, HA, seguridad y documentación."
        f"{extra}"
    )


async def generate_infrastructure_document_async(
    db: Session,
    scope_type: str = "global_cpd",
    scope_target_id: Optional[int] = None,
    custom_focus: str = "",
    auto_propose_cmdb_suggestions: bool = True,
    created_by: str = "admin",
) -> Dict[str, Any]:
    cfg = get_or_create_ai_settings(db)
    snapshot = build_federated_readonly_snapshot(
        db=db,
        scope_type=scope_type,
        scope_target_id=scope_target_id,
    )

    focus_clause = (
        f"\nFoco específico solicitado por el operador: {custom_focus.strip()}"
        if (custom_focus or "").strip()
        else ""
    )
    user_prompt = (
        f"Analiza y documenta el alcance '{snapshot['scope_label']}' (`{scope_type}`).{focus_clause}\n\n"
        "Contexto real verificado de RackDoc (JSON solo-lectura sanitizado):\n"
        f"```json\n{json.dumps(snapshot, ensure_ascii=False, indent=2)}\n```"
    )

    generation_mode = "llm"
    provider_used = cfg.provider_type
    model_used = cfg.model_name
    try:
        md_content, provider_used, model_used = await invoke_llm_async(
            cfg=cfg,
            system_prompt=_build_documenter_system_prompt(cfg),
            messages=[{"role": "user", "content": user_prompt}],
        )
        if "```mermaid" not in md_content and snapshot.get("mermaid_diagram"):
            md_content = (
                f"{md_content}\n\n## Diagrama de Topología Verificada\n\n"
                f"```mermaid\n{snapshot['mermaid_diagram']}\n```\n"
            )
    except Exception as exc:
        generation_mode = "deterministic_fallback"
        md_content = _render_deterministic_dossier_markdown(snapshot, fallback_reason=str(exc))

    doc_code = f"DOC-AI-{int(time.time())}-{secrets.token_hex(2).upper()}"
    doc = AiGeneratedDocument(
        doc_code=doc_code,
        title=f"Dossier Técnico: {snapshot['scope_label']}",
        scope_type=scope_type,
        scope_target_id=scope_target_id,
        scope_label=snapshot["scope_label"],
        markdown_content=md_content,
        mermaid_diagram=snapshot.get("mermaid_diagram", ""),
        structured_findings=snapshot.get("findings", []),
        provider_used=provider_used,
        model_used=model_used,
        generation_mode=generation_mode,
        created_by=created_by,
    )
    db.add(doc)
    db.commit()
    db.refresh(doc)

    created_suggestions = 0
    if auto_propose_cmdb_suggestions:
        sug_res = scan_and_create_cmdb_suggestions(db=db, source_doc_id=doc.id)
        created_suggestions = sug_res["created_count"]

    return {
        "document": serialize_ai_document(doc, include_markdown=True),
        "created_suggestions_count": created_suggestions,
    }


def save_external_mcp_document(
    db: Session,
    payload: Dict[str, Any],
    created_by: str = "mcp-agent",
) -> Dict[str, Any]:
    """Permite a un agente MCP externo archivar un dossier Markdown en la biblioteca IA sin tocar la CMDB."""
    scope_type = str(payload.get("scope_type") or "global_cpd").strip()
    if scope_type not in ALLOWED_SCOPES:
        scope_type = "global_cpd"
    title = str(payload.get("title") or "").strip()
    if not title:
        raise ValueError("El título del documento es obligatorio.")
    md = sanitize_context_payload(str(payload.get("markdown_content") or "").strip())
    if not md:
        raise ValueError("El contenido Markdown no puede estar vacío.")

    doc = AiGeneratedDocument(
        doc_code=f"DOC-MCP-{int(time.time())}-{secrets.token_hex(2).upper()}",
        title=title[:220],
        scope_type=scope_type,
        scope_target_id=payload.get("scope_target_id"),
        scope_label=str(payload.get("scope_label") or "Informe MCP Externo")[:180],
        markdown_content=md,
        mermaid_diagram=str(payload.get("mermaid_diagram") or ""),
        structured_findings=sanitize_context_payload(payload.get("structured_findings") or []),
        provider_used="mcp_external",
        model_used="external_client",
        generation_mode="mcp_external",
        created_by=created_by,
    )
    db.add(doc)
    db.commit()
    db.refresh(doc)
    return serialize_ai_document(doc, include_markdown=True)


async def chat_readonly_with_infrastructure_async(
    db: Session,
    question: str,
    scope_type: str = "global_cpd",
    scope_target_id: Optional[int] = None,
    history: Optional[List[Dict[str, str]]] = None,
) -> Dict[str, Any]:
    clean_q = (question or "").strip()
    if not clean_q:
        raise ValueError("Escribe una pregunta sobre tu infraestructura.")

    cfg = get_or_create_ai_settings(db)
    snapshot = build_federated_readonly_snapshot(
        db=db,
        scope_type=scope_type,
        scope_target_id=scope_target_id,
    )

    system_prompt = (
        _build_documenter_system_prompt(cfg)
        + "\n\nContexto vivo de la infraestructura de RackDoc (JSON solo-lectura):\n"
        + json.dumps(snapshot, ensure_ascii=False)
    )

    msgs: List[Dict[str, str]] = []
    for item in (history or [])[-8:]:
        role = item.get("role", "user")
        if role not in ("user", "assistant"):
            role = "user"
        content = str(item.get("content") or "").strip()
        if content:
            msgs.append({"role": role, "content": content[:2500]})
    msgs.append({"role": "user", "content": clean_q})

    try:
        answer, provider_used, model_used = await invoke_llm_async(
            cfg=cfg,
            system_prompt=system_prompt,
            messages=msgs,
        )
        return {
            "answer": answer,
            "mode": "llm",
            "provider_used": provider_used,
            "model_used": model_used,
            "scope_label": snapshot["scope_label"],
            "findings_referenced": len(snapshot["findings"]),
        }
    except Exception as exc:
        # Respuesta analítica determinista útil si Ollama aún no descargó el modelo
        kpis = snapshot["kpis"]
        top_findings = snapshot["findings"][:6]
        bullet_lines = [
            f"- **[{f['severity'].upper()}] {f['target_code']}**: {f['title']} — {f['detail']}"
            for f in top_findings
        ] or ["- No se detectan alertas ni SPOFs activos en este alcance."]
        fallback_answer = (
            f"*(Modo Analítico Local — El motor LLM `{cfg.model_name}` aún no está disponible: {exc})*\n\n"
            f"He analizado en modo solo-lectura **{snapshot['scope_label']}**:\n"
            f"- **Inventario**: `{kpis['locations_count']}` sedes, `{kpis['racks_count']}` racks, "
            f"`{kpis['active_cmdb_assets_count']}` activos CMDB, `{kpis['cabling_connections_count']}` conexiones físicas "
            f"y `{kpis['tls_certificates_count']}` certificados TLS.\n\n"
            "### Principales Hallazgos y Dependencias Detectadas\n"
            + "\n".join(bullet_lines)
            + "\n\n> Descarga el modelo en **9. Administración -> Motor de IA** para habilitar respuestas conversacionales abiertas con Ollama local."
        )
        return {
            "answer": fallback_answer,
            "mode": "deterministic_fallback",
            "provider_used": cfg.provider_type,
            "model_used": cfg.model_name,
            "scope_label": snapshot["scope_label"],
            "findings_referenced": len(top_findings),
        }


# ==============================================================================
# 5. BORRADORES DE ENRIQUECIMIENTO CMDB (`HUMAN-IN-THE-LOOP`)
# ==============================================================================


def scan_and_create_cmdb_suggestions(
    db: Session,
    source_doc_id: Optional[int] = None,
) -> Dict[str, Any]:
    """
    Inspecciona en modo lectura los activos de la CMDB cruzándolos con Racks, Stacks 2D,
    Chequeos Nagios y CertScope para proponer mejoras documentales en `ai_cmdb_suggestions`
    sin modificar `cmdb_assets`.
    """
    assets = (
        db.query(CmdbAsset)
        .options(joinedload(CmdbAsset.ip_addresses), joinedload(CmdbAsset.host_rack_device))
        .all()
    )
    racks_by_id = {r.id: r for r in db.query(Rack).all()}
    rack_devs_by_id = {d.id: d for d in db.query(RackDevice).options(joinedload(RackDevice.template)).all()}
    checks = db.query(MonitoredServiceCheck).all()
    certs = db.query(TlsCertificate).all()
    stacks = {s.id: s for s in db.query(TechStackDiagram).all()}
    stack_nodes = db.query(TechStackNode).all()

    existing_pending = {
        (s.asset_id, s.field_name)
        for s in db.query(AiCmdbSuggestion).filter(AiCmdbSuggestion.status == "pending").all()
    }

    checks_by_asset: Dict[int, List[MonitoredServiceCheck]] = {}
    for c in checks:
        checks_by_asset.setdefault(c.asset_id, []).append(c)

    certs_by_asset: Dict[int, List[TlsCertificate]] = {}
    for cert in certs:
        if cert.asset_id:
            certs_by_asset.setdefault(cert.asset_id, []).append(cert)

    stacks_by_asset: Dict[int, List[TechStackDiagram]] = {}
    for sn in stack_nodes:
        if sn.stack_id in stacks:
            stacks_by_asset.setdefault(sn.asset_id, []).append(stacks[sn.stack_id])

    passive_by_asset: Dict[int, AiPassiveDiscoverySnapshot] = {}
    for ps in (
        db.query(AiPassiveDiscoverySnapshot)
        .filter(
            AiPassiveDiscoverySnapshot.status == "completed",
            AiPassiveDiscoverySnapshot.asset_id.isnot(None),
        )
        .order_by(AiPassiveDiscoverySnapshot.id.desc())
        .all()
    ):
        if ps.asset_id is not None and ps.asset_id not in passive_by_asset:
            passive_by_asset[ps.asset_id] = ps

    created = 0
    for asset in assets:
        if asset.lifecycle_status == "decommissioned":
            continue
        ps_snap = passive_by_asset.get(asset.id)

        # 1. Sugerir ficha documental (`notes`) si está vacía
        if not (asset.notes or "").strip() and (asset.id, "notes") not in existing_pending:
            ips_desc = ", ".join(
                f"{ip.ip_address} ({ip.ip_role})" for ip in asset.ip_addresses
            ) or "sin IP registrada"
            loc_piece = "No vinculado a bastidor físico"
            if asset.rack_device_id and asset.rack_device_id in rack_devs_by_id:
                rd = rack_devs_by_id[asset.rack_device_id]
                rk = racks_by_id.get(rd.rack_id)
                loc_piece = f"Equipo físico en Rack {rk.code if rk else '?'} (U{rd.start_u}, código {rd.code})"
            elif asset.host_rack_device_id and asset.host_rack_device_id in rack_devs_by_id:
                rd = rack_devs_by_id[asset.host_rack_device_id]
                rk = racks_by_id.get(rd.rack_id)
                loc_piece = f"Alojado sobre hipervisor físico {rd.code} en Rack {rk.code if rk else '?'}"

            svc_names = [c.service_name for c in checks_by_asset.get(asset.id, [])]
            st_names = list({s.name for s in stacks_by_asset.get(asset.id, [])})
            cert_names = [c.code for c in certs_by_asset.get(asset.id, [])]

            parts = [
                f"[Autodocumentación RackDoc AI] Activo {asset.asset_class} ({asset.environment}).",
                f"Ubicación física/host: {loc_piece}.",
                f"Interfaces IP: {ips_desc}.",
            ]
            if st_names:
                parts.append(f"Participa en Stack(s): {', '.join(st_names)}.")
            if svc_names:
                parts.append(f"Servicios monitorizados: {', '.join(svc_names[:6])}.")
            if cert_names:
                parts.append(f"Certificados TLS asociados: {', '.join(cert_names)}.")
            if ps_snap:
                if ps_snap.listening_ports:
                    ports_str = ", ".join(
                        f"{lp.get('port')}/{lp.get('proto', 'tcp')} ({lp.get('process') or 'svc'})"
                        for lp in ps_snap.listening_ports[:8]
                    )
                    parts.append(f"Puertos reales escuchando (Descubrimiento RO): {ports_str}.")
                if ps_snap.containers:
                    cts_str = ", ".join(str(c.get("name") or "") for c in ps_snap.containers[:6])
                    parts.append(f"Contenedores activos: {cts_str}.")
                if ps_snap.snmp_interfaces:
                    up_ifs = sum(1 for i in ps_snap.snmp_interfaces if i.get("oper_status") == "up")
                    parts.append(
                        f"Walk SNMP RO: {len(ps_snap.snmp_interfaces)} bocas inventariadas ({up_ifs} operativas UP)."
                    )

            db.add(
                AiCmdbSuggestion(
                    asset_id=asset.id,
                    field_name="notes",
                    current_value="",
                    proposed_value=" ".join(parts),
                    rationale="Activo sin documentación operativa en CMDB; ficha sintetizada cruzando Rack, IPAM, Stacks y Nagios.",
                    confidence=0.92,
                    status="pending",
                    source_doc_id=source_doc_id,
                )
            )
            existing_pending.add((asset.id, "notes"))
            created += 1

        # 2. Sugerir alineación de `criticality` si participa en un Stack `critical` pero figura como `low` o `medium`
        st_list = stacks_by_asset.get(asset.id, [])
        if (
            asset.criticality in ("low", "medium")
            and any(s.criticality == "critical" for s in st_list)
            and (asset.id, "criticality") not in existing_pending
        ):
            crit_stack_names = ", ".join({s.name for s in st_list if s.criticality == "critical"})
            db.add(
                AiCmdbSuggestion(
                    asset_id=asset.id,
                    field_name="criticality",
                    current_value=asset.criticality or "",
                    proposed_value="critical",
                    rationale=(
                        f"El activo forma parte del Stack crítico '{crit_stack_names}', "
                        f"pero su criticidad en CMDB figura como '{asset.criticality}'."
                    ),
                    confidence=0.89,
                    status="pending",
                    source_doc_id=source_doc_id,
                )
            )
            existing_pending.add((asset.id, "criticality"))
            created += 1

        # 3. Sugerir `os_or_firmware` desde Descubrimiento Pasivo RO o desde catálogo hardware si está vacío
        if not (asset.os_or_firmware or "").strip() and (asset.id, "os_or_firmware") not in existing_pending:
            inferred_os = ""
            reason_os = ""
            if ps_snap and (ps_snap.os_or_sysdescr or "").strip():
                inferred_os = ps_snap.os_or_sysdescr.strip()[:120]
                reason_os = f"Detectado en vivo mediante descubrimiento pasivo RO ({ps_snap.collector_type})."
            elif asset.rack_device_id and asset.rack_device_id in rack_devs_by_id:
                rd = rack_devs_by_id[asset.rack_device_id]
                if rd.template:
                    inferred_os = f"{rd.template.manufacturer} {rd.template.model_name} ({rd.template.category})"[:120]
                    reason_os = "Campo OS/Firmware vacío en CMDB; inferido desde la plantilla hardware montada en el Rack."
            if inferred_os:
                db.add(
                    AiCmdbSuggestion(
                        asset_id=asset.id,
                        field_name="os_or_firmware",
                        current_value="",
                        proposed_value=inferred_os,
                        rationale=reason_os,
                        confidence=0.94 if ps_snap else 0.84,
                        status="pending",
                        source_doc_id=source_doc_id,
                    )
                )
                existing_pending.add((asset.id, "os_or_firmware"))
                created += 1

    if created:
        db.commit()

    return {
        "created_count": created,
        "suggestions": list_cmdb_suggestions(db=db, status_filter="pending"),
    }


def list_cmdb_suggestions(db: Session, status_filter: str = "all") -> List[Dict[str, Any]]:
    q = db.query(AiCmdbSuggestion).options(joinedload(AiCmdbSuggestion.asset))
    if status_filter in ("pending", "applied", "dismissed"):
        q = q.filter(AiCmdbSuggestion.status == status_filter)
    rows = q.order_by(AiCmdbSuggestion.id.desc()).limit(200).all()
    return [
        {
            "id": r.id,
            "asset_id": r.asset_id,
            "asset_code": r.asset.code if r.asset else f"ID-{r.asset_id}",
            "asset_name": r.asset.name if r.asset else "",
            "field_name": r.field_name,
            "current_value": r.current_value or "",
            "proposed_value": r.proposed_value,
            "rationale": r.rationale or "",
            "confidence": round(float(r.confidence or 0.85), 2),
            "status": r.status,
            "source_doc_id": r.source_doc_id,
            "reviewed_by": r.reviewed_by or "",
            "reviewed_at": r.reviewed_at.isoformat() if r.reviewed_at else None,
            "created_at": r.created_at.isoformat() if r.created_at else None,
        }
        for r in rows
    ]


def review_cmdb_suggestion(
    db: Session,
    suggestion_id: int,
    action: str,
    reviewed_by: str = "editor",
) -> Dict[str, Any]:
    sug = (
        db.query(AiCmdbSuggestion)
        .options(joinedload(AiCmdbSuggestion.asset))
        .filter(AiCmdbSuggestion.id == suggestion_id)
        .first()
    )
    if not sug:
        raise ValueError("Sugerencia CMDB no encontrada.")
    if sug.status != "pending":
        raise ValueError(f"La sugerencia ya fue procesada previamente (estado: {sug.status}).")

    if action not in ("apply", "dismiss"):
        raise ValueError("Acción inválida. Usa 'apply' o 'dismiss'.")

    if action == "apply":
        if sug.field_name not in ALLOWED_SUGGESTION_FIELDS:
            raise ValueError(f"Campo '{sug.field_name}' no permitido para aplicación directa.")
        asset = sug.asset
        if not asset:
            raise ValueError("El activo CMDB asociado ya no existe.")
        if sug.field_name == "notes":
            asset.notes = sug.proposed_value
        elif sug.field_name == "criticality":
            asset.criticality = sug.proposed_value[:32]
        elif sug.field_name == "owner_team":
            asset.owner_team = sug.proposed_value[:120]
        elif sug.field_name == "os_or_firmware":
            asset.os_or_firmware = sug.proposed_value[:120]
        asset.updated_at = utcnow()
        sug.status = "applied"
    else:
        sug.status = "dismissed"

    sug.reviewed_by = reviewed_by
    sug.reviewed_at = utcnow()
    db.commit()
    db.refresh(sug)
    return {
        "id": sug.id,
        "status": sug.status,
        "asset_id": sug.asset_id,
        "field_name": sug.field_name,
        "reviewed_by": sug.reviewed_by,
    }


# ==============================================================================
# 6. SERIALIZACIÓN Y VISTA CONSOLIDADA PARA FRONTEND FLUTTER
# ==============================================================================


def serialize_ai_document(doc: AiGeneratedDocument, include_markdown: bool = False) -> Dict[str, Any]:
    res = {
        "id": doc.id,
        "doc_code": doc.doc_code,
        "title": doc.title,
        "scope_type": doc.scope_type,
        "scope_target_id": doc.scope_target_id,
        "scope_label": doc.scope_label,
        "findings_count": len(doc.structured_findings or []),
        "structured_findings": doc.structured_findings or [],
        "provider_used": doc.provider_used,
        "model_used": doc.model_used,
        "generation_mode": doc.generation_mode,
        "created_by": doc.created_by,
        "created_at": doc.created_at.isoformat() if doc.created_at else None,
    }
    if include_markdown:
        res["markdown_content"] = doc.markdown_content or ""
        res["mermaid_diagram"] = doc.mermaid_diagram or ""
    return res


def build_ai_agent_overview(db: Session, base_backend_url: str = "http://localhost:8180") -> Dict[str, Any]:
    from .ai_network_schema_service import collect_finops_telemetry_and_findings

    cfg = get_or_create_ai_settings(db)
    snapshot = build_federated_readonly_snapshot(db=db, scope_type="global_cpd")
    _tel_map, finops_findings = collect_finops_telemetry_and_findings(db)
    merged_findings = list(snapshot["findings"]) + finops_findings
    kpis_out = dict(snapshot["kpis"])
    kpis_out["findings_total"] = len(merged_findings)
    kpis_out["findings_critical_or_high"] = sum(
        1 for f in merged_findings if f["severity"] in ("critical", "high")
    )
    docs = (
        db.query(AiGeneratedDocument)
        .order_by(AiGeneratedDocument.id.desc())
        .limit(50)
        .all()
    )
    suggestions = list_cmdb_suggestions(db=db, status_filter="all")
    pending_count = sum(1 for s in suggestions if s["status"] == "pending")

    # Selectores disponibles para el generador de documentación en la UI
    locations = db.query(Location).order_by(Location.name.asc()).all()
    racks = db.query(Rack).order_by(Rack.code.asc()).all()
    stacks = db.query(TechStackDiagram).order_by(TechStackDiagram.name.asc()).all()
    hosts = (
        db.query(CmdbAsset)
        .filter(CmdbAsset.lifecycle_status != "decommissioned")
        .order_by(CmdbAsset.code.asc())
        .limit(200)
        .all()
    )

    return {
        "engine_summary": {
            "provider_type": cfg.provider_type,
            "base_url": cfg.base_url,
            "model_name": cfg.model_name,
            "readonly_enforced": True,
            "passive_discovery_enabled": bool(cfg.passive_discovery_enabled),
            "auto_audit_enabled": bool(cfg.auto_audit_enabled),
            "auto_audit_interval_hours": int(cfg.auto_audit_interval_hours or 24),
            "last_auto_audit_at": cfg.last_auto_audit_at.isoformat() if cfg.last_auto_audit_at else None,
            "mcp_ready": bool((cfg.mcp_token_hash or "").strip() or AI_READONLY_API_KEY),
        },
        "kpis": kpis_out,
        "live_findings": merged_findings,
        "global_mermaid": snapshot["mermaid_diagram"],
        "scope_targets": {
            "locations": [{"id": l.id, "label": f"{l.code} — {l.name}"} for l in locations],
            "racks": [{"id": r.id, "label": f"{r.code} — {r.name}"} for r in racks],
            "logical_stacks": [{"id": s.id, "label": f"{s.code} — {s.name}"} for s in stacks],
            "hosts": [{"id": h.id, "label": f"{h.code} — {h.name}"} for h in hosts],
        },
        "documents": [serialize_ai_document(d, include_markdown=False) for d in docs],
        "suggestions": suggestions,
        "pending_suggestions_count": pending_count,
        "passive_discovery": list_passive_discovery_snapshots(db=db, limit=50),
        "mcp_endpoint_base": f"{base_backend_url.rstrip('/')}/api/v1/ai-readonly",
    }


async def background_ai_auto_audit_loop(stop_event: Any) -> None:
    """
    Worker periódico no intrusivo: cuando `auto_audit_enabled=True` en `AiAgentSettings`,
    ejecuta cada `auto_audit_interval_hours` la auditoría global de riesgos/SPOF y el
    escaneo de borradores CMDB en modo 100% Solo-Lectura.
    """
    import asyncio
    from ..database import SessionLocal

    while not stop_event.is_set():
        try:
            await asyncio.wait_for(stop_event.wait(), timeout=600.0)
            break
        except asyncio.TimeoutError:
            pass

        db = SessionLocal()
        try:
            cfg = get_or_create_ai_settings(db)
            if not cfg.auto_audit_enabled:
                continue
            interval_sec = max(3600, int(cfg.auto_audit_interval_hours or 24) * 3600)
            now = utcnow()
            if cfg.last_auto_audit_at is not None:
                elapsed = (now - cfg.last_auto_audit_at).total_seconds()
                if elapsed < interval_sec:
                    continue
            await generate_infrastructure_document_async(
                db=db,
                scope_type="spof_risk_audit",
                custom_focus="Auditoría periódica programada en modo Solo-Lectura",
                auto_propose_cmdb_suggestions=True,
                created_by="auto-scheduler-ro",
            )
            cfg.last_auto_audit_at = utcnow()
            db.commit()
        except Exception:
            pass
        finally:
            db.close()
