"""Pruebas de autenticación JWT, matriz RBAC de 4 roles y Active Directory / LDAP JIT."""

from typing import Dict
import pytest
from fastapi.testclient import TestClient

from app.routers import auth as auth_router


def test_protected_endpoint_rejects_anonymous_requests(client: TestClient) -> None:
    """Cualquier ruta de `/api/v1` protegida debe rechazar peticiones sin token con 401."""
    resp = client.get("/api/v1/locations")
    assert resp.status_code == 401


def test_login_rejects_wrong_password(client: TestClient) -> None:
    """Credenciales incorrectas deben devolver 401 sin emitir token."""
    resp = client.post(
        "/api/v1/auth/login",
        json={"username": "admin", "password": "wrong-password"},
    )
    assert resp.status_code == 401


def test_rbac_four_tier_enforcement(
    client: TestClient,
    admin_headers: Dict[str, str],
    editor_headers: Dict[str, str],
    viewer_headers: Dict[str, str],
) -> None:
    """
    Verifica la matriz RBAC:
    - `viewer`: puede leer (`GET`), pero recibe `403` al intentar mutar inventario (`POST`).
    - `editor`: puede crear inventario, pero recibe `403` en rutas exclusivas de `admin` (`/users`).
    - `admin`: acceso completo a gestión de usuarios y servidores AD.
    """
    assert client.get("/api/v1/locations", headers=viewer_headers).status_code == 200

    viewer_post = client.post(
        "/api/v1/locations",
        headers=viewer_headers,
        json={
            "code": "LOC-FORBIDDEN",
            "name": "Forbidden Site",
            "latitude": 40.4,
            "longitude": -3.7,
        },
    )
    assert viewer_post.status_code == 403

    editor_admin_attempt = client.post(
        "/api/v1/users",
        headers=editor_headers,
        json={
            "username": "sneaky_admin",
            "full_name": "Sneaky",
            "email": "sneaky@rackdoc.test",
            "password": "Password123!",
            "role": "admin",
        },
    )
    assert editor_admin_attempt.status_code == 403

    assert client.get("/api/v1/users", headers=admin_headers).status_code == 200


def test_active_directory_ldap_jit_autoprovisioning_and_login(
    client: TestClient,
    admin_headers: Dict[str, str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """
    Verifica el alta de un servidor AD y el inicio de sesión con Auto-Provisioning JIT
    (`CORP\\sre_guardia`), comprobando que mapea el rol RBAC y sincroniza contactos SRE.
    """
    ad_resp = client.post(
        "/api/v1/ad-servers",
        headers=admin_headers,
        json={
            "name": "AD Corp Test",
            "domain": "corp.local",
            "ldap_url": "ldap://dc01.corp.local:389",
            "base_dn": "DC=corp,DC=local",
            "bind_dn": "CN=svc_rackdoc,OU=Service,DC=corp,DC=local",
            "bind_password": "svc_secret_password",
            "user_filter": "(sAMAccountName={username})",
            "default_role": "viewer",
            "enabled": True,
        },
    )
    assert ad_resp.status_code == 200, ad_resp.text

    def _fake_ldap_auth(ad_srv, username: str, password: str, **kwargs) -> dict:
        if username == "sre_guardia" and password == "AdPass2026!":
            return {
                "authenticated": True,
                "username": "sre_guardia",
                "full_name": "Ingeniero Guardia AD",
                "email": "sre_guardia@corp.local",
                "ad_dn": "CN=Ingeniero Guardia AD,OU=SRE,DC=corp,DC=local",
                "groups": ["CN=RackDoc-Editors,OU=Groups,DC=corp,DC=local"],
                "role": "editor",
            }
        return {"authenticated": False, "error": "Invalid credentials"}

    monkeypatch.setattr(auth_router, "_ldap_authenticate_and_fetch_profile", _fake_ldap_auth)

    login_ok = client.post(
        "/api/v1/auth/login",
        json={"username": r"CORP\sre_guardia", "password": "AdPass2026!"},
    )
    assert login_ok.status_code == 200, login_ok.text
    payload = login_ok.json()
    assert payload["token"]
    assert payload["user"]["username"] == "sre_guardia"
    assert payload["user"]["auth_source"] == "ad"
    assert payload["user"]["role"] == "editor"

    login_bad = client.post(
        "/api/v1/auth/login",
        json={"username": r"CORP\sre_guardia", "password": "WrongPassword"},
    )
    assert login_bad.status_code == 401
