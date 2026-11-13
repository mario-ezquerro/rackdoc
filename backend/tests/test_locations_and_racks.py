"""Pruebas de jerarquía física DCIM (Sedes, Plantas, Racks 42U, colisiones U y alineación CMDB)."""

from typing import Dict
from fastapi.testclient import TestClient


def test_locations_racks_mount_and_u_collision(
    client: TestClient, admin_headers: Dict[str, str]
) -> None:
    """
    Recorre el flujo físico completo:
    1. Consulta el árbol inicial de sedes y plantillas hardware.
    2. Crea un nuevo armario Rack de 42U.
    3. Monta un equipo en U10 vinculado a un activo existente de la CMDB.
    4. Verifica el bloqueo `409 Conflict` si otro equipo intenta solapar U10.
    """
    locs_resp = client.get("/api/v1/locations", headers=admin_headers)
    assert locs_resp.status_code == 200
    locs = locs_resp.json()
    assert len(locs) >= 1
    first_room_id = locs[0]["floors"][0]["rooms"][0]["id"]

    tpls_resp = client.get("/api/v1/templates", headers=admin_headers)
    assert tpls_resp.status_code == 200
    templates = tpls_resp.json()
    assert len(templates) >= 1
    one_u_tpl = next(
        (t for t in templates if t["u_height"] == 1 and t["category"] != "tray"),
        templates[0],
    )

    rack_resp = client.post(
        "/api/v1/racks",
        headers=admin_headers,
        json={
            "room_id": first_room_id,
            "code": "RK-PYTEST-01",
            "name": "Rack Pytest Sala CPD",
            "total_units": 42,
        },
    )
    assert rack_resp.status_code == 200, rack_resp.text
    rack_id = rack_resp.json()["id"]

    cmdb_resp = client.post(
        "/api/v1/cmdb/assets",
        headers=admin_headers,
        json={
            "code": "CI-ALIGN-SW01",
            "name": "Switch Core Pre-registrado CMDB",
            "hostname": "sw-align-01",
            "fqdn": "sw-align-01.corp.local",
            "asset_class": "network_switch",
            "ip_addresses": [
                {
                    "ip_address": "10.250.10.11",
                    "subnet_mask": "255.255.255.0",
                    "interface_name": "vlan1",
                    "ip_role": "mgmt_heartbeat",
                    "is_primary": True,
                    "is_heartbeat_ip": True,
                }
            ],
        },
    )
    assert cmdb_resp.status_code == 200, cmdb_resp.text
    cmdb_asset_id = next(
        a["id"] for a in cmdb_resp.json()["assets"] if a["code"] == "CI-ALIGN-SW01"
    )

    dev1_resp = client.post(
        f"/api/v1/racks/{rack_id}/devices",
        headers=admin_headers,
        json={
            "template_id": one_u_tpl["id"],
            "code": "CI-ALIGN-SW01",
            "name": "Switch Core Pre-registrado CMDB",
            "hostname": "sw-align-01",
            "start_u": 10,
            "mounted_face": "front",
            "ip_address": "10.250.10.11",
            "custom_fields": {"linked_cmdb_asset_id": cmdb_asset_id},
        },
    )
    assert dev1_resp.status_code == 200, dev1_resp.text

    collision_resp = client.post(
        f"/api/v1/racks/{rack_id}/devices",
        headers=admin_headers,
        json={
            "template_id": one_u_tpl["id"],
            "code": "SW-OVERLAP",
            "name": "Equipo Solapado",
            "start_u": 10,
            "mounted_face": "front",
        },
    )
    assert collision_resp.status_code == 409
