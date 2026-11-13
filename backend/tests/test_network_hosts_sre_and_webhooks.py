"""Pruebas de `4. Red & Host`, `8. Alarmas SRE` (5 columnas + borrado) y Webhooks Ansible/Prometheus."""

from typing import Dict
from fastapi.testclient import TestClient


def test_network_hosts_and_sre_alarms_crud(
    client: TestClient, admin_headers: Dict[str, str]
) -> None:
    """
    Verifica el overview unificado de `4. Red & Host` y `8. Alarmas SRE`:
    - Presencia de `hosts` con `overall_alarm_state` y `known_users` (columna 5).
    - Alta y borrado (`DELETE`) de `HostGroup`, `AlertContact` y `AlertContactGroup`.
    """
    ov_resp = client.get("/api/v1/network-hosts/overview", headers=admin_headers)
    assert ov_resp.status_code == 200, ov_resp.text
    ov = ov_resp.json()
    assert "hosts" in ov
    assert "known_directory_users" in ov
    assert isinstance(ov["known_directory_users"], list)

    # 1. Crear y borrar Contacto SRE
    c_resp = client.post(
        "/api/v1/network-hosts/alert-contacts",
        headers=admin_headers,
        json={
            "code": "USR-PYTEST-01",
            "full_name": "Laura Guardia SRE",
            "email": "laura.sre@rackdoc.test",
            "schedule_period": "24x7",
        },
    )
    assert c_resp.status_code == 200, c_resp.text
    contact = next(
        x for x in c_resp.json()["alert_contacts"] if x["code"] == "USR-PYTEST-01"
    )

    # 2. Crear Grupo de Guardia con ese miembro
    cg_resp = client.post(
        "/api/v1/network-hosts/alert-contact-groups",
        headers=admin_headers,
        json={
            "code": "CG-PYTEST-GUARDIA",
            "name": "Guardia SRE Pytest",
            "group_email": "guardia-pytest@rackdoc.test",
            "member_contact_ids": [contact["id"]],
        },
    )
    assert cg_resp.status_code == 200, cg_resp.text
    cg = next(
        g for g in cg_resp.json()["alert_contact_groups"] if g["code"] == "CG-PYTEST-GUARDIA"
    )
    assert contact["id"] in cg["member_contact_ids"]

    # 3. Crear Grupo de Hosts
    hg_resp = client.post(
        "/api/v1/network-hosts/host-groups",
        headers=admin_headers,
        json={
            "code": "HG-PYTEST-CORE",
            "name": "Core Routers Pytest",
            "category": "network",
        },
    )
    assert hg_resp.status_code == 200, hg_resp.text
    hg = next(g for g in hg_resp.json()["host_groups"] if g["code"] == "HG-PYTEST-CORE")

    # 4. Borrar Contacto -> debe limpiarse automáticamente de member_contact_ids del grupo
    del_c = client.delete(
        f"/api/v1/network-hosts/alert-contacts/{contact['id']}",
        headers=admin_headers,
    )
    assert del_c.status_code == 200
    cg_after = next(
        g for g in del_c.json()["alert_contact_groups"] if g["id"] == cg["id"]
    )
    assert contact["id"] not in cg_after["member_contact_ids"]

    # 5. Borrar Grupo de Guardia y Grupo de Hosts
    assert (
        client.delete(
            f"/api/v1/network-hosts/alert-contact-groups/{cg['id']}",
            headers=admin_headers,
        ).status_code
        == 200
    )
    assert (
        client.delete(
            f"/api/v1/network-hosts/host-groups/{hg['id']}",
            headers=admin_headers,
        ).status_code
        == 200
    )


def test_automation_webhooks_prometheus_metrics_and_ai_context(
    client: TestClient,
    automation_headers: Dict[str, str],
) -> None:
    """Verifica autenticación por `X-API-Key`, alta Ansible, `/metrics` Prometheus y `/ai-context`."""
    # Sin X-API-Key debe rechazar con 401
    assert client.get("/api/v1/metrics").status_code == 401

    upsert_resp = client.post(
        "/api/v1/automation/webhook/host-upsert",
        headers=automation_headers,
        json={
            "code": "ANSIBLE-WEB-01",
            "name": "Frontend Nginx Ansible",
            "hostname": "ansible-web-01",
            "fqdn": "ansible-web-01.corp.local",
            "primary_ip": "10.252.30.10",
            "asset_class": "virtual_machine",
            "host_groups": ["HG-WEB-AUTO"],
            "exporters": [{"type": "node_exporter", "port": 9100}],
        },
    )
    assert upsert_resp.status_code == 200, upsert_resp.text

    metrics_resp = client.get("/api/v1/metrics", headers=automation_headers)
    assert metrics_resp.status_code == 200
    assert "rackdoc_" in metrics_resp.text

    ai_resp = client.get("/api/v1/automation/ai-context", headers=automation_headers)
    assert ai_resp.status_code == 200
    assert "ANSIBLE-WEB-01" in ai_resp.text
