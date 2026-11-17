#!/usr/bin/env python3
"""
Servidor MCP Oficial Solo-Lectura de RackDoc8 (`rackdoc-readonly-mcp`).

Transporte: JSON-RPC 2.0 sobre `stdio` (sin dependencias externas, funciona con Python 3.9+ nativo).
Autenticación: Cabecera `X-AI-Readonly-Key` contra `/api/v1/ai-readonly/*` (garantía en backend de
cero mutaciones sobre Racks, Red & Host, CertScope o CMDB).

Variables de entorno:
  - RACKDOC_BASE_URL        (por defecto: http://localhost:8180)
  - RACKDOC_AI_READONLY_KEY (token generado en 9. Administración -> Motor IA o AI_READONLY_API_KEY en .env)
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Dict, Optional

BASE_URL = (os.getenv("RACKDOC_BASE_URL", "http://localhost:8180") or "http://localhost:8180").rstrip("/")
READONLY_KEY = (os.getenv("RACKDOC_AI_READONLY_KEY") or os.getenv("AI_READONLY_API_KEY") or "").strip()
PROTOCOL_VERSION = "2024-11-05"


def _http_request(method: str, path: str, params: Optional[Dict[str, Any]] = None, body: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    url = f"{BASE_URL}{path}"
    if params:
        clean_params = {k: v for k, v in params.items() if v is not None}
        if clean_params:
            url = f"{url}?{urllib.parse.urlencode(clean_params)}"

    headers = {
        "Accept": "application/json",
        "User-Agent": "rackdoc-readonly-mcp/1.0",
    }
    if READONLY_KEY:
        headers["X-AI-Readonly-Key"] = READONLY_KEY

    raw_data = None
    if body is not None:
        headers["Content-Type"] = "application/json; charset=utf-8"
        raw_data = json.dumps(body, ensure_ascii=False).encode("utf-8")

    req = urllib.request.Request(url=url, data=raw_data, headers=headers, method=method.upper())
    try:
        with urllib.request.urlopen(req, timeout=25) as resp:
            payload = resp.read().decode("utf-8")
            return json.loads(payload) if payload else {}
    except urllib.error.HTTPError as exc:
        err_txt = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {exc.code} desde RackDoc ({path}): {err_txt}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"No se pudo conectar con RackDoc en '{BASE_URL}': {exc}") from exc


TOOLS_SCHEMA = [
    {
        "name": "get_cpd_executive_summary",
        "description": (
            "Obtiene en modo solo-lectura la radiografía ejecutiva del CPD completo en RackDoc: "
            "KPIs, sedes, bastidores racks, activos CMDB, subredes IPAM, stacks 2D, certificados TLS "
            "y diagrama Mermaid global."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "location_id": {
                    "type": "integer",
                    "description": "Opcional. Si se indica, acota la consulta a una Sede concreta.",
                }
            },
        },
    },
    {
        "name": "inspect_rack_and_cabling",
        "description": (
            "Inspecciona en modo solo-lectura un bastidor Rack concreto (ocupación U, equipos montados, "
            "cables de red/fibra, acometidas eléctricas PDU/SAI, activos CMDB alojados y diagrama Mermaid)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "rack_id": {
                    "type": "integer",
                    "description": "ID numérico del Rack en RackDoc.",
                }
            },
            "required": ["rack_id"],
        },
    },
    {
        "name": "inspect_logical_stack_or_host",
        "description": (
            "Analiza las dependencias aguas arriba y aguas abajo de un Stack Tecnológico 2D "
            "('logical_stack') o de un Host/VM concreto de la CMDB ('host')."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "scope_type": {
                    "type": "string",
                    "enum": ["logical_stack", "host"],
                    "description": "Tipo de elemento a inspeccionar.",
                },
                "target_id": {
                    "type": "integer",
                    "description": "ID numérico del Stack Tecnológico o del Activo CMDB.",
                },
            },
            "required": ["scope_type", "target_id"],
        },
    },
    {
        "name": "audit_spofs_and_sre_risks",
        "description": (
            "Ejecuta la auditoría determinista de Puntos Únicos de Fallo (SPOFs de hipervisor, rack o energía), "
            "hosts críticos sin regla de guardia SRE, falta de monitorización, certificados TLS próximos a vencer "
            "y deriva documental en la CMDB."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {},
        },
    },
    {
        "name": "query_prometheus_readonly",
        "description": (
            "Ejecuta una consulta instantánea PromQL en modo solo-lectura contra el contenedor "
            "Prometheus TSDB de RackDoc (ej. 'rackdoc_host_up', 'rackdoc_host_cpu_usage_percent')."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "promql": {
                    "type": "string",
                    "description": "Expresión PromQL de lectura.",
                }
            },
            "required": ["promql"],
        },
    },
    {
        "name": "get_passive_discovery_telemetry",
        "description": (
            "Fase 2: Obtiene en modo solo-lectura las instantáneas de descubrimiento pasivo profundo "
            "(puertos TCP/UDP en escucha, conexiones establecidas entre servidores, contenedores Docker/Podman "
            "y tablas de bocas SNMP IF-MIB + vecinos LLDP-MIB)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {},
        },
    },
    {
        "name": "get_analyzed_network_schema",
        "description": (
            "Fase 3: Obtiene el esquema de red completo en 5 capas calculado por el Agente IA "
            "(zonas, nodos posicionados, cableado físico, virtualización, enlaces lógicos, flujos "
            "descubiertos pasivamente RO e indicadores FinOps de Prometheus)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "scope_type": {
                    "type": "string",
                    "enum": ["global_cpd", "location", "rack", "logical_stack", "host"],
                    "description": "Ámbito del esquema de red (por defecto global_cpd).",
                },
                "scope_target_id": {
                    "type": "integer",
                    "description": "ID opcional cuando scope_type != global_cpd.",
                },
            },
        },
    },
    {
        "name": "save_infrastructure_document",
        "description": (
            "Guarda un dossier técnico, informe de auditoría o runbook DRP en formato Markdown "
            "dentro de la biblioteca aislada de documentos IA de RackDoc (sin modificar la CMDB ni los Racks)."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "title": {"type": "string", "description": "Título descriptivo del informe."},
                "scope_label": {"type": "string", "description": "Etiqueta del ámbito documentado."},
                "markdown_content": {"type": "string", "description": "Contenido completo en Markdown."},
                "mermaid_diagram": {"type": "string", "description": "Código Mermaid opcional."},
            },
            "required": ["title", "markdown_content"],
        },
    },
]


def _handle_tool_call(name: str, args: Dict[str, Any]) -> Dict[str, Any]:
    if name == "get_cpd_executive_summary":
        loc_id = args.get("location_id")
        if loc_id is not None:
            data = _http_request(
                "GET",
                "/api/v1/ai-readonly/snapshot",
                params={"scope_type": "location", "scope_target_id": int(loc_id)},
            )
        else:
            data = _http_request("GET", "/api/v1/ai-readonly/snapshot", params={"scope_type": "global_cpd"})
        return data

    if name == "inspect_rack_and_cabling":
        rack_id = int(args["rack_id"])
        return _http_request(
            "GET",
            "/api/v1/ai-readonly/snapshot",
            params={"scope_type": "rack", "scope_target_id": rack_id},
        )

    if name == "inspect_logical_stack_or_host":
        st = str(args["scope_type"])
        tid = int(args["target_id"])
        return _http_request(
            "GET",
            "/api/v1/ai-readonly/snapshot",
            params={"scope_type": st, "scope_target_id": tid},
        )

    if name == "audit_spofs_and_sre_risks":
        snap = _http_request(
            "GET",
            "/api/v1/ai-readonly/snapshot",
            params={"scope_type": "spof_risk_audit"},
        )
        return {
            "generated_at": snap.get("generated_at"),
            "kpis": snap.get("kpis"),
            "findings": snap.get("findings", []),
            "certificates": snap.get("certificates", []),
        }

    if name == "query_prometheus_readonly":
        return _http_request(
            "GET",
            "/api/v1/ai-readonly/prometheus-query",
            params={"query": str(args["promql"])},
        )

    if name == "get_passive_discovery_telemetry":
        return _http_request("GET", "/api/v1/ai-readonly/passive-discovery")

    if name == "get_analyzed_network_schema":
        return _http_request(
            "GET",
            "/api/v1/ai-readonly/network-schema",
            params={
                "scope_type": str(args.get("scope_type") or "global_cpd"),
                "scope_target_id": args.get("scope_target_id"),
            },
        )

    if name == "save_infrastructure_document":
        return _http_request(
            "POST",
            "/api/v1/ai-readonly/documents",
            body={
                "title": str(args["title"]),
                "scope_type": "global_cpd",
                "scope_label": str(args.get("scope_label") or "Informe MCP Externo"),
                "markdown_content": str(args["markdown_content"]),
                "mermaid_diagram": str(args.get("mermaid_diagram") or ""),
            },
        )

    raise ValueError(f"Herramienta MCP desconocida: '{name}'")


def handle_jsonrpc_message(msg: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    method = msg.get("method", "")
    req_id = msg.get("id")
    params = msg.get("params") or {}

    # Las notificaciones JSON-RPC (sin 'id') no llevan respuesta.
    if req_id is None:
        return None

    try:
        if method == "initialize":
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "protocolVersion": PROTOCOL_VERSION,
                    "capabilities": {
                        "tools": {},
                        "resources": {},
                    },
                    "serverInfo": {
                        "name": "rackdoc-readonly-mcp",
                        "version": "1.0.0",
                    },
                },
            }

        if method == "ping":
            return {"jsonrpc": "2.0", "id": req_id, "result": {}}

        if method == "tools/list":
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {"tools": TOOLS_SCHEMA},
            }

        if method == "tools/call":
            tool_name = str(params.get("name") or "")
            tool_args = params.get("arguments") or {}
            try:
                output = _handle_tool_call(tool_name, tool_args)
                return {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "content": [
                            {
                                "type": "text",
                                "text": json.dumps(output, ensure_ascii=False, indent=2),
                            }
                        ],
                        "isError": False,
                    },
                }
            except Exception as tool_exc:
                return {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "content": [{"type": "text", "text": f"Error MCP: {tool_exc}"}],
                        "isError": True,
                    },
                }

        if method == "resources/list":
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "resources": [
                        {
                            "uri": "rackdoc://snapshot/global_cpd",
                            "name": "Radiografía Solo-Lectura del CPD (RackDoc8)",
                            "description": "Grafo completo sanitizado de Racks, CMDB, Red & Host, CertScope y hallazgos SPOF.",
                            "mimeType": "application/json",
                        }
                    ]
                },
            }

        if method == "resources/read":
            uri = str(params.get("uri") or "")
            if uri != "rackdoc://snapshot/global_cpd":
                raise ValueError(f"Recurso MCP no soportado: {uri}")
            snap = _http_request("GET", "/api/v1/ai-readonly/snapshot", params={"scope_type": "global_cpd"})
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "contents": [
                        {
                            "uri": uri,
                            "mimeType": "application/json",
                            "text": json.dumps(snap, ensure_ascii=False, indent=2),
                        }
                    ]
                },
            }

        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32601, "message": f"Método no soportado: {method}"},
        }
    except Exception as exc:
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32603, "message": str(exc)},
        }


def main() -> None:
    for raw_line in sys.stdin:
        line = raw_line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError as exc:
            err_resp = {
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32700, "message": f"JSON inválido: {exc}"},
            }
            sys.stdout.write(json.dumps(err_resp, ensure_ascii=False) + "\n")
            sys.stdout.flush()
            continue

        resp = handle_jsonrpc_message(msg)
        if resp is not None:
            sys.stdout.write(json.dumps(resp, ensure_ascii=False) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
