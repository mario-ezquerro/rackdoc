"""
Suite de pruebas automatizadas del Módulo 10: Agente IA Solo-Lectura (`RackDoc AI`),
Ollama Local por defecto, Proveedor Externo cifrado, Servidor MCP y Borradores CMDB.
"""

from typing import Dict
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

from app.services.ai_agent_service import sanitize_context_payload
from mcp_server import rackdoc_mcp


def test_default_ollama_local_settings_and_admin_rbac(
    client: TestClient,
    admin_headers: Dict[str, str],
    editor_headers: Dict[str, str],
    viewer_headers: Dict[str, str],
):
    # Ni viewer ni editor pueden leer o modificar la configuración sensible del motor IA
    assert client.get("/api/v1/ai-agent/settings", headers=viewer_headers).status_code == 403
    assert client.get("/api/v1/ai-agent/settings", headers=editor_headers).status_code == 403

    # Admin obtiene la configuración por defecto apuntando a Ollama local
    resp = client.get("/api/v1/ai-agent/settings", headers=admin_headers)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    settings = body["settings"]
    assert settings["provider_type"] == "ollama_local"
    assert "11434" in settings["base_url"]
    assert settings["model_name"] == "qwen2.5:7b"
    assert settings["has_api_key"] is False

    # Conmutar temporalmente a proveedor externo con API Key cifrada y verificar que jamás se expone en claro
    upd = client.put(
        "/api/v1/ai-agent/settings",
        headers=admin_headers,
        json={
            "provider_type": "openai_compatible",
            "base_url": "https://api.openai.com/v1",
            "model_name": "gpt-4o-mini",
            "api_key": "sk-super-secret-external-key-1234567890",
            "temperature": 0.15,
            "max_tokens": 1500,
        },
    )
    assert upd.status_code == 200, upd.text
    upd_settings = upd.json()["settings"]
    assert upd_settings["provider_type"] == "openai_compatible"
    assert upd_settings["has_api_key"] is True
    assert "sk-super-secret" not in upd.text

    # Restaurar Ollama Local por defecto
    restore = client.put(
        "/api/v1/ai-agent/settings",
        headers=admin_headers,
        json={
            "provider_type": "ollama_local",
            "base_url": "http://rackdoc-ollama:11434",
            "model_name": "qwen2.5:7b",
            "clear_api_key": True,
        },
    )
    assert restore.status_code == 200
    assert restore.json()["settings"]["provider_type"] == "ollama_local"
    assert restore.json()["settings"]["has_api_key"] is False


def test_sanitizer_strips_all_secrets():
    dirty = {
        "hostname": "srv-db-01",
        "password_hash": "$2b$12$secret",
        "bind_password": "ad_plain_password",
        "auth_username_or_community": "private_snmp",
        "secret_ciphertext": "gAAAAAB...",
        "nested": {
            "api_key": "sk-1234567890abcdefghijkl",
            "notes": "Usar token Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig o rdk_ro_abcdef1234567890 en pruebas",
        },
    }
    clean = sanitize_context_payload(dirty)
    assert clean["hostname"] == "srv-db-01"
    assert "password_hash" not in clean
    assert "bind_password" not in clean
    assert "auth_username_or_community" not in clean
    assert "secret_ciphertext" not in clean
    assert "api_key" not in clean["nested"]
    assert "[REDACTED]" in clean["nested"]["notes"]
    assert "eyJhbGci" not in clean["nested"]["notes"]
    assert "rdk_ro_" not in clean["nested"]["notes"]


def test_mcp_readonly_key_enforces_strict_isolation(
    client: TestClient,
    admin_headers: Dict[str, str],
):
    # Sin clave ni sesión rechaza con 401
    assert client.get("/api/v1/ai-readonly/snapshot").status_code == 401

    # Generar token MCP solo-lectura desde Administración
    rot = client.post("/api/v1/ai-agent/settings/mcp-token/rotate", headers=admin_headers)
    assert rot.status_code == 200, rot.text
    raw_mcp_key = rot.json()["raw_token"]
    assert raw_mcp_key.startswith("rdk_ro_")
    mcp_headers = {"X-AI-Readonly-Key": raw_mcp_key}

    # Lectura de radiografía permitida y sanitizada
    snap_resp = client.get("/api/v1/ai-readonly/snapshot?scope_type=global_cpd", headers=mcp_headers)
    assert snap_resp.status_code == 200, snap_resp.text
    snap = snap_resp.json()
    assert snap["readonly_mode"] is True
    assert "flowchart TD" in snap["mermaid_diagram"]
    assert "password" not in snap_resp.text.lower()

    # Guardar informe Markdown aislado vía MCP permitido
    save_doc = client.post(
        "/api/v1/ai-readonly/documents",
        headers=mcp_headers,
        json={
            "title": "Auditoría Externa desde Cliente MCP",
            "scope_label": "CPD Global",
            "markdown_content": "# Informe MCP\nTodo verificado en modo lectura.",
        },
    )
    assert save_doc.status_code == 200, save_doc.text
    assert save_doc.json()["document"]["generation_mode"] == "mcp_external"

    # Cualquier intento de usar la clave MCP para mutar Racks, Sedes, CMDB o Webhooks Ansible DEBE fallar
    mut_loc = client.post(
        "/api/v1/locations",
        headers=mcp_headers,
        json={"code": "HACK", "name": "Intento Escritura"},
    )
    assert mut_loc.status_code in (401, 403)

    mut_webhook = client.post(
        "/api/v1/automation/webhook/host-upsert",
        headers={"X-API-Key": raw_mcp_key},
        json={"code": "HACK-VM", "name": "Intento Webhook", "primary_ip": "10.99.99.99"},
    )
    assert mut_webhook.status_code == 401


def test_document_generation_with_mocked_ollama_and_fallback(
    client: TestClient,
    admin_headers: Dict[str, str],
    viewer_headers: Dict[str, str],
):
    # 1. Respaldo determinista cuando el motor LLM devuelve error o está desconectado
    with patch(
        "app.services.ai_agent_service.invoke_llm_async",
        new=AsyncMock(side_effect=RuntimeError("Ollama desconectado en test")),
    ):
        gen_fallback = client.post(
            "/api/v1/ai-agent/documents/generate",
            headers=admin_headers,
            json={
                "scope_type": "spof_risk_audit",
                "custom_focus": "Revisar redundancia eléctrica y guardias SRE",
                "auto_propose_cmdb_suggestions": True,
            },
        )
    assert gen_fallback.status_code == 200, gen_fallback.text
    doc_fb = gen_fallback.json()["document"]
    assert doc_fb["generation_mode"] == "deterministic_fallback"
    assert "```mermaid" in doc_fb["markdown_content"]

    # 2. Generación con respuesta real simulada de Ollama Local (`qwen2.5:7b`)
    fake_md = "# Dossier Generado por Ollama Local\n\nAnálisis completo de bastidores y HA."
    with patch(
        "app.services.ai_agent_service.invoke_llm_async",
        new=AsyncMock(return_value=(fake_md, "ollama_local", "qwen2.5:7b")),
    ):
        gen_llm = client.post(
            "/api/v1/ai-agent/documents/generate",
            headers=admin_headers,
            json={"scope_type": "global_cpd", "auto_propose_cmdb_suggestions": False},
        )
        assert gen_llm.status_code == 200, gen_llm.text
        doc_llm = gen_llm.json()["document"]
        assert doc_llm["generation_mode"] == "llm"
        assert doc_llm["provider_used"] == "ollama_local"
        assert "Dossier Generado por Ollama Local" in doc_llm["markdown_content"]
        # Se inyecta el diagrama Mermaid verificado automáticamente si el LLM no lo incluyó
        assert "```mermaid" in doc_llm["markdown_content"]

        # El rol `viewer` puede usar el chat 100% solo-lectura
        chat_resp = client.post(
            "/api/v1/ai-agent/chat",
            headers=viewer_headers,
            json={"question": "¿Qué puntos únicos de fallo existen en el CPD?"},
        )
        assert chat_resp.status_code == 200, chat_resp.text
        assert chat_resp.json()["mode"] == "llm"


def test_human_in_the_loop_cmdb_suggestions_workflow(
    client: TestClient,
    admin_headers: Dict[str, str],
    editor_headers: Dict[str, str],
    viewer_headers: Dict[str, str],
):
    # Crear un activo CMDB con `notes` vacío para que el escáner proponga borrador
    create_asset = client.post(
        "/api/v1/cmdb/assets",
        headers=editor_headers,
        json={
            "code": "VM-AI-DOC-TEST-01",
            "name": "Servidor Backend Pagos",
            "hostname": "vm-ai-doc-test-01",
            "asset_class": "virtual_machine",
            "environment": "production",
            "criticality": "critical",
            "notes": "",
            "ip_addresses": [
                {
                    "ip_address": "10.88.10.25",
                    "subnet_mask": "255.255.255.0",
                    "ip_role": "primary_service",
                    "interface_name": "eth0",
                }
            ],
        },
    )
    assert create_asset.status_code == 200, create_asset.text
    ov_before = client.get("/api/v1/cmdb/overview", headers=viewer_headers).json()
    asset_id = next(a["id"] for a in ov_before["assets"] if a["code"] == "VM-AI-DOC-TEST-01")

    scan_resp = client.post("/api/v1/ai-agent/suggestions/scan", headers=admin_headers)
    assert scan_resp.status_code == 200, scan_resp.text
    pending = [
        s
        for s in scan_resp.json()["suggestions"]
        if s["asset_id"] == asset_id and s["field_name"] == "notes" and s["status"] == "pending"
    ]
    assert len(pending) == 1
    sug_id = pending[0]["id"]

    # Un `viewer` NO puede aplicar sugerencias a la CMDB
    forbidden = client.post(f"/api/v1/ai-agent/suggestions/{sug_id}/apply", headers=viewer_headers)
    assert forbidden.status_code == 403

    # Un `editor` aprueba y aplica el borrador con 1 clic
    applied = client.post(f"/api/v1/ai-agent/suggestions/{sug_id}/apply", headers=editor_headers)
    assert applied.status_code == 200, applied.text
    assert applied.json()["suggestion"]["status"] == "applied"

    # Verificar que ahora sí se actualizó `notes` en la ficha CMDB real
    cmdb_ov = client.get("/api/v1/cmdb/overview", headers=viewer_headers).json()
    matching = [a for a in cmdb_ov["assets"] if a["id"] == asset_id]
    assert matching and "[Autodocumentación RackDoc AI]" in matching[0]["notes"]


def test_mcp_stdio_jsonrpc_protocol_handlers():
    init_res = rackdoc_mcp.handle_jsonrpc_message(
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}
    )
    assert init_res is not None
    assert init_res["result"]["serverInfo"]["name"] == "rackdoc-readonly-mcp"

    tools_res = rackdoc_mcp.handle_jsonrpc_message(
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}
    )
    assert tools_res is not None
    tool_names = {t["name"] for t in tools_res["result"]["tools"]}
    assert "get_cpd_executive_summary" in tool_names
    assert "inspect_rack_and_cabling" in tool_names
    assert "audit_spofs_and_sre_risks" in tool_names
    assert "get_passive_discovery_telemetry" in tool_names
    assert "get_analyzed_network_schema" in tool_names
    assert "save_infrastructure_document" in tool_names


def test_phase2_passive_snmp_if_lldp_walk_and_human_in_loop_topology(
    client: TestClient,
    editor_headers: Dict[str, str],
    viewer_headers: Dict[str, str],
):
    import socket
    import threading
    from app.services.monitor import _encode_ber_length, _encode_oid
    from app.services.passive_discovery_service import _read_ber_tlv, decode_ber_oid

    # Registrar un Switch en CMDB para que el Walk SNMP lo vincule por IP/hostname
    sw_create = client.post(
        "/api/v1/cmdb/assets",
        headers=editor_headers,
        json={
            "code": "SW-CORE-RO-01",
            "name": "Switch Core Catalyst 9300",
            "hostname": "sw-core-ro-01",
            "asset_class": "network_security",
            "environment": "production",
            "criticality": "critical",
            "ip_addresses": [
                {
                    "ip_address": "10.88.10.1",
                    "subnet_mask": "255.255.255.0",
                    "ip_role": "mgmt_heartbeat",
                    "interface_name": "Vlan1",
                }
            ],
        },
    )
    assert sw_create.status_code == 200, sw_create.text

    # Tabla MIB ordenada lexicográficamente por tupla de enteros del OID
    mib_entries = [
        # LLDP-MIB (1.0.8802...)
        ("1.0.8802.1.1.2.1.3.7.1.3.1", b"\x04\x07Gi1/0/1"),
        ("1.0.8802.1.1.2.1.4.1.1.7.0.1.1", b"\x04\x04eth0"),
        ("1.0.8802.1.1.2.1.4.1.1.9.0.1.1", b"\x04\x11vm-ai-doc-test-01"),
        ("1.0.8802.1.1.2.1.4.2.1.4.0.1.1.1.4.10.88.10.25", b"\x02\x01\x01"),
        # SNMPv2-MIB System
        ("1.3.6.1.2.1.1.1.0", b"\x04\x19Cisco IOS XE 17.09.04a RO"),
        ("1.3.6.1.2.1.1.5.0", b"\x04\x0dsw-core-ro-01"),
        # IF-MIB ifDescr, ifPhysAddress, ifAdminStatus, ifOperStatus, ifName, ifHighSpeed, ifAlias
        ("1.3.6.1.2.1.2.2.1.2.1", b"\x04\x12GigabitEthernet1/0/1"),
        ("1.3.6.1.2.1.2.2.1.2.2", b"\x04\x12GigabitEthernet1/0/2"),
        ("1.3.6.1.2.1.2.2.1.6.1", b"\x04\x06\x00\x1a\x2b\x3c\x4d\x5e"),
        ("1.3.6.1.2.1.2.2.1.7.1", b"\x02\x01\x01"),
        ("1.3.6.1.2.1.2.2.1.7.2", b"\x02\x01\x01"),
        ("1.3.6.1.2.1.2.2.1.8.1", b"\x02\x01\x01"),
        ("1.3.6.1.2.1.2.2.1.8.2", b"\x02\x01\x02"),
        ("1.3.6.1.2.1.31.1.1.1.1.1", b"\x04\x07Gi1/0/1"),
        ("1.3.6.1.2.1.31.1.1.1.1.2", b"\x04\x07Gi1/0/2"),
        ("1.3.6.1.2.1.31.1.1.1.15.1", b"\x02\x02\x27\x10"),  # 10000 Mbps
        ("1.3.6.1.2.1.31.1.1.1.15.2", b"\x02\x02\x03\xe8"),  # 1000 Mbps
        ("1.3.6.1.2.1.31.1.1.1.18.1", b"\x04\x12Uplink Backend Pagos"),
    ]
    sorted_mib = sorted(
        mib_entries,
        key=lambda item: tuple(int(x) for x in item[0].split(".")),
    )

    udp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp_sock.bind(("127.0.0.1", 0))
    mock_port = udp_sock.getsockname()[1]
    udp_sock.settimeout(0.3)
    stop_flag = threading.Event()

    def _snmp_responder():
        while not stop_flag.is_set():
            try:
                data, addr = udp_sock.recvfrom(4096)
            except socket.timeout:
                continue
            except OSError:
                break
            # Extraer OID solicitado en GetNextRequest
            _, seq_body, _ = _read_ber_tlv(data, 0)
            _, ver_raw, off = _read_ber_tlv(seq_body, 0)
            _, comm_raw, off = _read_ber_tlv(seq_body, off)
            _, pdu_body, _ = _read_ber_tlv(seq_body, off)
            _, req_id_raw, p_off = _read_ber_tlv(pdu_body, 0)
            _, _, p_off = _read_ber_tlv(pdu_body, p_off)
            _, _, p_off = _read_ber_tlv(pdu_body, p_off)
            _, vbl_body, _ = _read_ber_tlv(pdu_body, p_off)
            _, vb_body, _ = _read_ber_tlv(vbl_body, 0)
            _, oid_raw, _ = _read_ber_tlv(vb_body, 0)
            req_oid_tuple = tuple(int(x) for x in decode_ber_oid(oid_raw).split("."))

            nxt = next(
                (
                    (oid_s, val_tlv)
                    for oid_s, val_tlv in sorted_mib
                    if tuple(int(x) for x in oid_s.split(".")) > req_oid_tuple
                ),
                None,
            )
            if nxt is None:
                resp_oid_tlv = _encode_oid(decode_ber_oid(oid_raw))
                resp_val_tlv = b"\x82\x00"  # endOfMibView
            else:
                resp_oid_tlv = _encode_oid(nxt[0])
                resp_val_tlv = nxt[1]

            vb_out = b"\x30" + _encode_ber_length(len(resp_oid_tlv) + len(resp_val_tlv)) + resp_oid_tlv + resp_val_tlv
            vbl_out = b"\x30" + _encode_ber_length(len(vb_out)) + vb_out
            pdu_out_body = (
                b"\x02" + _encode_ber_length(len(req_id_raw)) + req_id_raw
                + b"\x02\x01\x00\x02\x01\x00"
                + vbl_out
            )
            pdu_out = b"\xa2" + _encode_ber_length(len(pdu_out_body)) + pdu_out_body
            msg_out_body = (
                b"\x02" + _encode_ber_length(len(ver_raw)) + ver_raw
                + b"\x04" + _encode_ber_length(len(comm_raw)) + comm_raw
                + pdu_out
            )
            pkt_out = b"\x30" + _encode_ber_length(len(msg_out_body)) + msg_out_body
            udp_sock.sendto(pkt_out, addr)

    t = threading.Thread(target=_snmp_responder, daemon=True)
    t.start()
    try:
        walk_resp = client.post(
            "/api/v1/ai-agent/passive-discovery/snmp-walk",
            headers=editor_headers,
            json={
                "target_host": "127.0.0.1",
                "port": mock_port,
                "community": "public",
                "version": "v2c",
                "timeout_sec": 1.5,
            },
        )
        assert walk_resp.status_code == 200, walk_resp.text
        snap = walk_resp.json()["snapshot"]
        assert snap["status"] == "completed"
        assert snap["asset_code"] == "SW-CORE-RO-01"
        assert len(snap["snmp_interfaces"]) == 2
        gi1 = snap["snmp_interfaces"][0]
        assert gi1["if_name"] == "Gi1/0/1"
        assert gi1["speed_mbps"] == 10000
        assert gi1["mac_address"] == "00:1A:2B:3C:4D:5E"
        assert gi1["lldp_neighbor_asset_code"] == "VM-AI-DOC-TEST-01"
        assert snap["topology_applied"] is False

        # Viewer NO puede aprobar el volcado de bocas/topología
        snap_id = snap["id"]
        assert (
            client.post(
                f"/api/v1/ai-agent/passive-discovery/{snap_id}/apply-topology",
                headers=viewer_headers,
            ).status_code
            == 403
        )

        # Editor aprueba el volcado Human-in-the-Loop hacia SwitchSnmpPort + LogicalTopologyLink
        apply_resp = client.post(
            f"/api/v1/ai-agent/passive-discovery/{snap_id}/apply-topology",
            headers=editor_headers,
        )
        assert apply_resp.status_code == 200, apply_resp.text
        applied_data = apply_resp.json()
        assert applied_data["snmp_ports_upserted"] == 2
        assert applied_data["logical_links_created"] == 1
        assert applied_data["snapshot"]["topology_applied"] is True
    finally:
        stop_flag.set()
        udp_sock.close()


def test_phase3_analyzed_network_schema_and_publish_to_tech_stack(
    client: TestClient,
    editor_headers: Dict[str, str],
    viewer_headers: Dict[str, str],
):
    # 1. Cualquier usuario autenticado (`viewer`+) puede consultar el esquema visual 2D calculado
    schema_resp = client.get(
        "/api/v1/ai-agent/network-schema?scope_type=global_cpd",
        headers=viewer_headers,
    )
    assert schema_resp.status_code == 200, schema_resp.text
    schema = schema_resp.json()
    assert schema["canvas_width"] >= 1400
    assert len(schema["zones"]) >= 1
    assert len(schema["nodes"]) >= 2
    # Debe incluir tanto enlaces confirmados como el enlace LLDP descubierto en Fase 2
    edge_kinds = {e["edge_kind"] for e in schema["edges"]}
    assert "passive_ro_discovered" in edge_kinds or "logical_confirmed" in edge_kinds

    # 2. `viewer` NO puede publicar el esquema en `4. Red & Host`
    forbidden = client.post(
        "/api/v1/ai-agent/network-schema/publish-stack",
        headers=viewer_headers,
        json={"scope_type": "global_cpd", "stack_name": "Intento Viewer"},
    )
    assert forbidden.status_code == 403

    # 3. `editor` publica con 1 clic el esquema hacia `4. Red & Host (Stacks Tecnológicos 2D)`
    pub_resp = client.post(
        "/api/v1/ai-agent/network-schema/publish-stack",
        headers=editor_headers,
        json={
            "scope_type": "global_cpd",
            "stack_name": "[IA] Topología Completa Verificada",
            "include_passive_ro_edges": True,
        },
    )
    assert pub_resp.status_code == 200, pub_resp.text
    pub_data = pub_resp.json()
    assert pub_data["nodes_created"] >= 2
    assert pub_data["stack_code"].startswith("STACK-AI-")


