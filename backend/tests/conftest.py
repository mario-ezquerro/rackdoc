"""
Fixtures compartidas de `pytest` para RackDoc Backend.

Configura un directorio temporal aislado (`RACKDOC_DATA_DIR` y `DATABASE_URL`)
antes de importar `app.main`, garantizando que las migraciones Alembic y los
datos semilla de prueba jamás alteren `data/rackdoc.db`.
"""

import os
import shutil
import tempfile
import uuid
from typing import Dict, Generator

import pytest

# Configurar entorno aislado ANTES de importar cualquier módulo de `app.*`
_TEST_DATA_DIR = tempfile.mkdtemp(prefix="rackdoc_pytest_")
os.environ["RACKDOC_DATA_DIR"] = _TEST_DATA_DIR
os.environ["DATABASE_URL"] = f"sqlite:///{_TEST_DATA_DIR}/test_rackdoc.db"
os.environ["JWT_SECRET"] = "pytest-deterministic-jwt-secret-key-2026-rackdoc"
os.environ["AUTOMATION_API_KEY"] = "pytest-automation-api-key-2026"
os.environ["ADMIN_USERNAME"] = "admin"
os.environ["ADMIN_PASSWORD"] = "admin_test_pwd"
os.environ["ADMIN_EMAIL"] = "admin@rackdoc.test"
os.environ["BCRYPT_ROUNDS"] = "10"

from fastapi.testclient import TestClient  # noqa: E402
from app.main import app  # noqa: E402


@pytest.fixture(scope="session")
def client() -> Generator[TestClient, None, None]:
    """Cliente HTTP FastAPI con ciclo de vida completo (Alembic + seed inicial)."""
    with TestClient(app) as test_client:
        yield test_client
    shutil.rmtree(_TEST_DATA_DIR, ignore_errors=True)


@pytest.fixture(scope="session")
def admin_headers(client: TestClient) -> Dict[str, str]:
    """Cabeceras JWT autenticadas como usuario `admin`."""
    resp = client.post(
        "/api/v1/auth/login",
        json={"username": "admin", "password": "admin_test_pwd"},
    )
    assert resp.status_code == 200, resp.text
    token = resp.json()["token"]
    return {"Authorization": f"Bearer {token}"}


def _create_and_login_role(
    client: TestClient, admin_headers: Dict[str, str], role: str
) -> Dict[str, str]:
    uname = f"{role}_{uuid.uuid4().hex[:6]}"
    pwd = f"Pwd_{role}_2026!"
    create_resp = client.post(
        "/api/v1/users",
        headers=admin_headers,
        json={
            "username": uname,
            "full_name": f"Test {role.title()}",
            "email": f"{uname}@rackdoc.test",
            "password": pwd,
            "role": role,
            "auth_source": "local",
            "is_active": True,
        },
    )
    assert create_resp.status_code == 200, create_resp.text
    login_resp = client.post(
        "/api/v1/auth/login",
        json={"username": uname, "password": pwd},
    )
    assert login_resp.status_code == 200, login_resp.text
    return {"Authorization": f"Bearer {login_resp.json()['token']}"}


@pytest.fixture(scope="session")
def editor_headers(client: TestClient, admin_headers: Dict[str, str]) -> Dict[str, str]:
    """Cabeceras JWT autenticadas con rol `editor`."""
    return _create_and_login_role(client, admin_headers, "editor")


@pytest.fixture(scope="session")
def viewer_headers(client: TestClient, admin_headers: Dict[str, str]) -> Dict[str, str]:
    """Cabeceras JWT autenticadas con rol `viewer` (solo lectura)."""
    return _create_and_login_role(client, admin_headers, "viewer")


@pytest.fixture(scope="session")
def automation_headers() -> Dict[str, str]:
    """Cabecera `X-API-Key` para webhooks Ansible y scrape de Prometheus."""
    return {"X-API-Key": os.environ["AUTOMATION_API_KEY"]}
