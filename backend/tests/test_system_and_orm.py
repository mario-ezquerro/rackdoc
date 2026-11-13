"""Pruebas de salud del sistema, especificación OpenAPI y consistencia estática ORM."""

import subprocess
import sys
from pathlib import Path
from typing import Dict

from fastapi.testclient import TestClient


def test_healthcheck_v1_and_legacy_alias(client: TestClient) -> None:
    """Verifica el healthcheck público tanto en `/api/v1/health` como en `/api/health`."""
    r_v1 = client.get("/api/v1/health")
    assert r_v1.status_code == 200
    body = r_v1.json()
    assert body["status"] == "ok"
    assert body["service"] == "rackdoc-backend"

    r_legacy = client.get("/api/health")
    assert r_legacy.status_code == 200
    assert r_legacy.json()["status"] == "ok"


def test_openapi_schema_generation(client: TestClient) -> None:
    """Garantiza que FastAPI genera `/openapi.json` sin errores de modelos Pydantic."""
    resp = client.get("/openapi.json")
    assert resp.status_code == 200
    schema = resp.json()
    assert schema["info"]["title"] == "RackDoc DCIM API"
    assert "/api/v1/health" in schema["paths"]
    assert "/api/v1/auth/login" in schema["paths"]


def test_monitoring_settings_roundtrip(
    client: TestClient, admin_headers: Dict[str, str]
) -> None:
    """Comprueba la lectura y ajuste acotado del intervalo global de Heartbeat."""
    get_resp = client.get("/api/v1/settings/monitoring", headers=admin_headers)
    assert get_resp.status_code == 200
    assert "interval_seconds" in get_resp.json()

    put_resp = client.put(
        "/api/v1/settings/monitoring",
        headers=admin_headers,
        json={"interval_seconds": 120, "background_enabled": True},
    )
    assert put_resp.status_code == 200
    assert put_resp.json()["interval_seconds"] == 120


def test_sqlalchemy_orm_attributes_static_scanner() -> None:
    """Ejecuta `escaneo_atributos_orm.py` para verificar 0 columnas inexistentes."""
    scanner = Path(__file__).resolve().parent.parent / "tools" / "escaneo_atributos_orm.py"
    proc = subprocess.run(
        [sys.executable, str(scanner)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert proc.returncode == 0, f"Atributos ORM inválidos:\n{proc.stdout}\n{proc.stderr}"
    assert "atributos inexistentes: 0" in proc.stdout
