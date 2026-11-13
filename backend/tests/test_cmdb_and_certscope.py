"""Pruebas de `6. CMDB & Control IPs` (Multi-IP, Subredes, Duplicados) y `7. CertScope`."""

from typing import Dict
from fastapi.testclient import TestClient


def test_cmdb_multi_ip_asset_and_duplicate_code_guard(
    client: TestClient, admin_headers: Dict[str, str]
) -> None:
    """Crea una subred y un activo Multi-IP en la CMDB y verifica rechazo 409 ante código duplicado."""
    sub_resp = client.post(
        "/api/v1/cmdb/subnets",
        headers=admin_headers,
        json={
            "cidr": "10.251.20.0/24",
            "name": "VLAN Pytest Backend",
            "vlan_id": 251,
            "gateway": "10.251.20.1",
            "subnet_mask": "255.255.255.0",
        },
    )
    assert sub_resp.status_code == 200, sub_resp.text

    asset_payload = {
        "code": "VM-PYTEST-DB01",
        "name": "PostgreSQL Cluster Node 01",
        "hostname": "pg-node01",
        "fqdn": "pg-node01.corp.local",
        "asset_class": "virtual_machine",
        "cpu_cores": 8,
        "ram_gb": 32.0,
        "storage_gb": 500.0,
        "ip_addresses": [
            {
                "ip_address": "10.251.20.15",
                "subnet_mask": "255.255.255.0",
                "interface_name": "eth0",
                "ip_role": "mgmt_heartbeat",
                "is_primary": True,
                "is_heartbeat_ip": True,
            },
            {
                "ip_address": "10.251.20.100",
                "subnet_mask": "255.255.255.0",
                "interface_name": "eth0:vip",
                "ip_role": "vip_cluster",
                "is_primary": False,
                "is_heartbeat_ip": False,
            },
        ],
    }
    create_resp = client.post("/api/v1/cmdb/assets", headers=admin_headers, json=asset_payload)
    assert create_resp.status_code == 200, create_resp.text

    # Mismo código CI debe devolver 409 Conflict
    dup_resp = client.post("/api/v1/cmdb/assets", headers=admin_headers, json=asset_payload)
    assert dup_resp.status_code == 409

    ov_resp = client.get("/api/v1/cmdb/overview", headers=admin_headers)
    assert ov_resp.status_code == 200
    assets = ov_resp.json()["assets"]
    created = next((a for a in assets if a["code"] == "VM-PYTEST-DB01"), None)
    assert created is not None
    assert len(created["ip_addresses"]) == 2


def test_certscope_manual_certificate_lifecycle(
    client: TestClient, admin_headers: Dict[str, str]
) -> None:
    """Verifica el alta, listado y borrado de un certificado X.509 manual en `7. CertScope`."""
    create_resp = client.post(
        "/api/v1/certscope/certificates",
        headers=admin_headers,
        json={
            "code": "CERT-PYTEST-VPN",
            "name": "Certificado VPN IPsec Sede Central",
            "check_mode": "manual",
            "common_name": "vpn.corp.local",
            "issuer_cn": "Corp Internal Root CA",
            "valid_from": "2026-01-01T00:00:00Z",
            "valid_until": "2027-06-01T00:00:00Z",
            "warn_days_before": 30,
            "critical_days_before": 7,
        },
    )
    assert create_resp.status_code == 200, create_resp.text
    cert_id = next(
        c["id"]
        for c in create_resp.json()["certificates"]
        if c["code"] == "CERT-PYTEST-VPN"
    )

    ov_resp = client.get("/api/v1/certscope/overview", headers=admin_headers)
    assert ov_resp.status_code == 200
    certs = ov_resp.json()["certificates"]
    assert any(c["id"] == cert_id for c in certs)

    del_resp = client.delete(
        f"/api/v1/certscope/certificates/{cert_id}",
        headers=admin_headers,
    )
    assert del_resp.status_code == 200
