"""
Pruebas del motor de aprovisionamiento Ansible (Linux SSH y Windows WinRM),
baúl cifrado Fernet, detección previa de exporters de serie, scripts bootstrap
(.sh / .ps1 con token) y pasarela OpenTelemetry (OTLP).
"""

from typing import Dict
from unittest.mock import AsyncMock, patch

from fastapi.testclient import TestClient

from app.database import SessionLocal
from app.models import MonitoredServiceCheck, ProvisioningCredential
from app.services.provisioning_service import _ingest_host_facts_into_cmdb


def test_vault_encryption_never_leaks_plaintext_and_precheck_validates_targets(
    client: TestClient, admin_headers: Dict[str, str]
) -> None:
    """Verifica cifrado Fernet en reposo, ocultación write-only en API y sanitización de Pre-Check."""
    fake_ssh_key = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmU=\n-----END OPENSSH PRIVATE KEY-----"
    create_resp = client.post(
        "/api/v1/provisioning/credentials",
        headers=admin_headers,
        json={
            "name": "Clave SSH Linux CPD",
            "credential_type": "ssh_key",
            "os_family": "linux",
            "username": "ubuntu",
            "port": 22,
            "secret": fake_ssh_key,
            "become_password": "MiSudoSuperSecreto!",
            "notes": "Llave maestra de provisión Linux",
        },
    )
    assert create_resp.status_code == 200, create_resp.text
    cred_json = create_resp.json()["credential"]
    assert cred_json["has_secret"] is True
    assert cred_json["has_become_password"] is True
    assert "secret" not in cred_json
    assert "MiSudoSuperSecreto!" not in create_resp.text
    assert "b3BlbnNzaC1rZXktdjE" not in create_resp.text

    # En base de datos el texto cifrado tampoco coincide con el texto en claro
    db = SessionLocal()
    try:
        stored = (
            db.query(ProvisioningCredential)
            .filter(ProvisioningCredential.id == cred_json["id"])
            .first()
        )
        assert stored is not None
        assert stored.secret_ciphertext != fake_ssh_key
        assert stored.secret_ciphertext.startswith("gAAAAA")
    finally:
        db.close()

    # Inyección de flags o caracteres inválidos en targets es rechazada con 400
    bad_pre = client.post(
        "/api/v1/provisioning/precheck",
        headers=admin_headers,
        json={"targets": ["-oProxyCommand=evil", "127.0.0.1;id"]},
    )
    assert bad_pre.status_code == 400

    ok_pre = client.post(
        "/api/v1/provisioning/precheck",
        headers=admin_headers,
        json={"targets": ["127.0.0.1"], "timeout_sec": 0.5},
    )
    assert ok_pre.status_code == 200, ok_pre.text
    res_item = ok_pre.json()["results"][0]
    assert res_item["target"] == "127.0.0.1"
    assert res_item["recommendation"] in {
        "already_active_link_only",
        "verify_and_propose_install",
        "use_bootstrap_script",
    }


def test_preinstalled_node_exporter_is_linked_while_missing_proposes_install() -> None:
    """
    Verifica la regla clave de diseño:
    - Si la máquina ya trae `node_exporter` activo de serie, se enlaza a CMDB y Prometheus sin reinstalar.
    - Si la máquina NO lo trae, inventaría el hardware en CMDB y devuelve `propose_install_exporter`.
    """
    db = SessionLocal()
    try:
        # Caso 1: Servidor con node_exporter de serie activo (v1.7.0)
        linked = _ingest_host_facts_into_cmdb(
            db=db,
            host_data={
                "target": "10.210.1.15",
                "hostname": "srv-debian-serie",
                "fqdn": "srv-debian-serie.cpd.local",
                "os_family": "linux",
                "os_or_firmware": "Debian GNU/Linux 12 (6.1.0)",
                "cpu_cores": 8,
                "ram_mb": 16384,
                "storage_gb": 120.0,
                "serial_or_uuid": "SN-DEBIAN-001",
                "default_ipv4": {"address": "10.210.1.15", "macaddress": "00:11:22:33:44:55"},
                "pre_agent": {"native_status": "active", "native_version": "1.7.0", "otel_status": "missing"},
                "post_agent": {"native_status": "active", "native_version": "1.7.0", "otel_status": "missing"},
            },
            target_location_id=None,
            host_groups=["LINUX-SERIE"],
        )
        assert linked["proposal"] == "linked_existing_exporter"
        checks_1 = (
            db.query(MonitoredServiceCheck)
            .filter(
                MonitoredServiceCheck.asset_id == linked["asset_id"],
                MonitoredServiceCheck.check_type == "node_exporter",
            )
            .all()
        )
        assert len(checks_1) == 1
        assert checks_1[0].port == 9100

        # Caso 2: Servidor limpio sin exporter -> inventariado en CMDB y propone instalar
        missing = _ingest_host_facts_into_cmdb(
            db=db,
            host_data={
                "target": "10.210.1.16",
                "hostname": "srv-rocky-clean",
                "fqdn": "srv-rocky-clean.cpd.local",
                "os_family": "linux",
                "os_or_firmware": "Rocky Linux 9.4",
                "cpu_cores": 4,
                "ram_mb": 8192,
                "storage_gb": 80.0,
                "default_ipv4": {"address": "10.210.1.16"},
                "pre_agent": {"native_status": "missing", "otel_status": "missing"},
                "post_agent": {"native_status": "missing", "otel_status": "missing"},
            },
            target_location_id=None,
            host_groups=[],
        )
        assert missing["proposal"] == "propose_install_exporter"
        assert missing["asset_id"] is not None
    finally:
        db.close()


def test_bootstrap_scripts_windows_register_and_otlp_gateway(
    client: TestClient, admin_headers: Dict[str, str]
) -> None:
    """Verifica emisión de token, scripts .sh/.ps1, auto-alta Windows, pasarela OTLP y revocación."""
    tok_resp = client.post(
        "/api/v1/provisioning/tokens",
        headers=admin_headers,
        json={
            "name": "Token DMZ Híbrida",
            "action_profile": "ensure_both",
            "reusable": True,
            "ttl_hours": 24,
        },
    )
    assert tok_resp.status_code == 200, tok_resp.text
    bundle = tok_resp.json()
    plain_token = bundle["plain_token"]
    token_id = bundle["token"]["id"]

    # Descarga de scripts Bash y PowerShell usando el token (sin JWT de navegador)
    sh_resp = client.get(f"/api/v1/automation/bootstrap.sh?token={plain_token}")
    assert sh_resp.status_code == 200
    assert "node_exporter_build_info" in sh_resp.text
    assert "ensure_both" in sh_resp.text

    ps_resp = client.get(f"/api/v1/automation/bootstrap.ps1?token={plain_token}")
    assert ps_resp.status_code == 200
    assert "windows_exporter" in ps_resp.text

    # Auto-registro de un Windows Server ejecutando el bootstrap
    reg_resp = client.post(
        "/api/v1/automation/bootstrap/register",
        headers={"X-RackDoc-Token": plain_token},
        json={
            "hostname": "WIN-SQL-DMZ01",
            "fqdn": "WIN-SQL-DMZ01.corp.local",
            "os_family": "windows",
            "os_or_firmware": "Microsoft Windows Server 2022 Datacenter",
            "cpu_cores": 16,
            "ram_gb": 64.0,
            "storage_gb": 500.0,
            "serial_or_uuid": "VMWARE-WIN-01",
            "primary_ip": "10.210.20.50",
            "native_exporter_status": "active",
            "native_exporter_port": 9182,
            "native_exporter_version": "0.29.2",
            "otel_collector_status": "active",
        },
    )
    assert reg_resp.status_code == 200, reg_resp.text
    host_info = reg_resp.json()["host"]
    assert host_info["hostname"] == "WIN-SQL-DMZ01"
    assert host_info["proposal"] == "linked_existing_exporter"

    # Pasarela OTLP rechaza peticiones anónimas y reenvía las autenticadas con X-RackDoc-Token
    unauth_otlp = client.post(
        "/api/v1/automation/otlp/v1/metrics",
        content=b"{}",
        headers={"Content-Type": "application/json"},
    )
    assert unauth_otlp.status_code == 401

    with patch(
        "app.routers.provisioning.forward_otlp_metrics_to_prometheus",
        new=AsyncMock(return_value=(200, b'{"partialSuccess":{}}', "application/json")),
    ):
        ok_otlp = client.post(
            "/api/v1/automation/otlp/v1/metrics",
            content=b'{"resourceMetrics":[]}',
            headers={
                "Content-Type": "application/json",
                "X-RackDoc-Token": plain_token,
            },
        )
        assert ok_otlp.status_code == 200

    # Revocar el token bloquea cualquier uso posterior
    rev_resp = client.delete(
        f"/api/v1/provisioning/tokens/{token_id}",
        headers=admin_headers,
    )
    assert rev_resp.status_code == 200
    blocked_sh = client.get(f"/api/v1/automation/bootstrap.sh?token={plain_token}")
    assert blocked_sh.status_code == 401
