"""
Seguridad de RackDoc: hashing de contraseñas, emisión/validación de tokens JWT
y aplicación de los roles RBAC documentados en `models.User.role`.

Jerarquía de roles (de menor a mayor privilegio):
    viewer   -> Solo lectura estricta (GET).
    operator -> Lectura + acciones de interacción que no modifican el inventario
                (ping, consola remota/SSH, heartbeats, lanzar chequeos).
    editor   -> Todo lo anterior + crear/editar/borrar inventario.
    admin    -> Todo lo anterior + gestión de usuarios, servidores AD y ajustes
                globales de monitorización.
"""

import base64
import hashlib
import os
import secrets
from datetime import datetime, timedelta, timezone
from typing import Optional

import bcrypt
import jwt
from fastapi import Depends, Header, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from .database import get_db
from .models import User

# ---------------------------------------------------------------------------
# Configuración
# ---------------------------------------------------------------------------

JWT_ALGORITHM = "HS256"
JWT_TTL_MINUTES = max(5, int(os.getenv("JWT_TTL_MINUTES", "480") or 480))

_env_secret = (os.getenv("JWT_SECRET", "") or "").strip()
# Sin JWT_SECRET configurado generamos uno aleatorio por proceso: el servicio
# arranca igual en desarrollo, pero nunca se firma con un secreto conocido.
# El efecto es que al reiniciar el backend caducan las sesiones abiertas.
JWT_SECRET_IS_EPHEMERAL = not _env_secret
JWT_SECRET = _env_secret or secrets.token_urlsafe(48)

AUTOMATION_API_KEY = (os.getenv("AUTOMATION_API_KEY", "") or "").strip()

# ---------------------------------------------------------------------------
# Contraseñas
# ---------------------------------------------------------------------------

_BCRYPT_ROUNDS = max(10, int(os.getenv("BCRYPT_ROUNDS", "12") or 12))
_BCRYPT_PREFIXES = ("$2a$", "$2b$", "$2x$", "$2y$")


def _prepare(plain: str) -> bytes:
    """
    bcrypt ignora todo lo que pase de 72 bytes. Pre-hasheamos con SHA-256 en
    base64 para que contraseñas largas o con muchos caracteres multibyte se
    tengan en cuenta completas.
    """
    digest = hashlib.sha256((plain or "").encode("utf-8")).digest()
    return base64.b64encode(digest)


def hash_password(plain: str) -> str:
    """Devuelve el hash bcrypt de una contraseña en claro."""
    return bcrypt.hashpw(_prepare(plain), bcrypt.gensalt(rounds=_BCRYPT_ROUNDS)).decode("utf-8")


def is_password_hashed(stored: Optional[str]) -> bool:
    """True si el valor almacenado ya es un hash bcrypt y no texto plano."""
    return bool(stored) and str(stored).startswith(_BCRYPT_PREFIXES)


def verify_password(plain: str, stored: Optional[str]) -> bool:
    """
    Comprueba una contraseña contra el hash almacenado. Nunca acepta valores
    vacíos y jamás compara en texto plano.
    """
    if not plain or not stored or not is_password_hashed(stored):
        return False
    try:
        return bcrypt.checkpw(_prepare(plain), str(stored).encode("utf-8"))
    except (ValueError, TypeError):
        return False


# ---------------------------------------------------------------------------
# Tokens JWT
# ---------------------------------------------------------------------------


def create_access_token(user: User) -> dict:
    """Emite un JWT firmado para el usuario y devuelve el payload de respuesta."""
    now = datetime.now(timezone.utc)
    expires_at = now + timedelta(minutes=JWT_TTL_MINUTES)
    token = jwt.encode(
        {
            "sub": str(user.id),
            "username": user.username or "",
            "role": user.role or "viewer",
            "iat": int(now.timestamp()),
            "exp": int(expires_at.timestamp()),
        },
        JWT_SECRET,
        algorithm=JWT_ALGORITHM,
    )
    return {
        "token": token,
        "token_type": "Bearer",
        "expires_in": JWT_TTL_MINUTES * 60,
        "expires_at": expires_at.isoformat(),
    }


_bearer_scheme = HTTPBearer(auto_error=False, scheme_name="RackDocJWT")

_UNAUTHENTICATED = HTTPException(
    status_code=status.HTTP_401_UNAUTHORIZED,
    detail="Se requiere un token de sesión válido (cabecera 'Authorization: Bearer <token>').",
    headers={"WWW-Authenticate": "Bearer"},
)


def get_current_user(
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(_bearer_scheme),
    db: Session = Depends(get_db),
) -> User:
    """Resuelve y valida el usuario autenticado a partir del JWT de la petición."""
    if credentials is None or not (credentials.credentials or "").strip():
        raise _UNAUTHENTICATED

    try:
        payload = jwt.decode(
            credentials.credentials,
            JWT_SECRET,
            algorithms=[JWT_ALGORITHM],
            options={"require": ["exp", "sub"]},
        )
    except jwt.ExpiredSignatureError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="La sesión ha caducado. Vuelve a iniciar sesión.",
            headers={"WWW-Authenticate": "Bearer"},
        )
    except jwt.PyJWTError:
        raise _UNAUTHENTICATED

    try:
        user_id = int(payload.get("sub") or 0)
    except (TypeError, ValueError):
        raise _UNAUTHENTICATED

    user = db.query(User).filter(User.id == user_id).first()
    if not user or not user.is_active:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="El usuario de la sesión ya no existe o está desactivado.",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return user


# ---------------------------------------------------------------------------
# RBAC
# ---------------------------------------------------------------------------

ROLE_LEVELS = {"viewer": 0, "operator": 1, "editor": 2, "admin": 3}

# Prefijos de ruta (ya sin el prefijo /api o /api/v1) reservados a 'admin'.
_ADMIN_PREFIXES = (
    "/users",
    "/ad-servers",
    "/settings/monitoring",
)

# Acciones de interacción que un 'operator' puede lanzar aunque usen POST,
# porque consultan o contactan equipos sin modificar el inventario.
_OPERATOR_ACTION_SUFFIXES = (
    "/ping",
    "/ping-all",
    "/remote-console",
    "/ssh-console",
    "/heartbeat",
    "/run",
    "/run-now",
    "/run-all-checks",
    "/snmp-discover",
    "/verify-ip",
    "/test-alert",
)

_SAFE_METHODS = frozenset({"GET", "HEAD", "OPTIONS"})


def strip_api_prefix(path: str) -> str:
    """Quita el prefijo de montaje del router ('/api/v1' o '/api')."""
    for prefix in ("/api/v1", "/api"):
        if path.startswith(prefix):
            return path[len(prefix):] or "/"
    return path


def minimum_role_for(method: str, path: str) -> str:
    """Rol mínimo exigido para un método HTTP y una ruta de la API."""
    route = strip_api_prefix(path).rstrip("/") or "/"
    method = (method or "GET").upper()

    if any(route == p or route.startswith(p + "/") for p in _ADMIN_PREFIXES):
        # Consultar la lista de usuarios o de servidores AD ya es información
        # sensible, así que también las lecturas son de admin.
        return "admin"

    if method in _SAFE_METHODS:
        return "viewer"

    if route.endswith(_OPERATOR_ACTION_SUFFIXES):
        return "operator"

    return "editor"


def has_role(user: User, minimum: str) -> bool:
    return ROLE_LEVELS.get(user.role or "viewer", 0) >= ROLE_LEVELS.get(minimum, 3)


def enforce_rbac(request: Request, user: User = Depends(get_current_user)) -> User:
    """
    Dependencia global del router de la API: exige un JWT válido y comprueba que
    el rol del usuario alcance el nivel mínimo de la ruta solicitada.
    """
    minimum = minimum_role_for(request.method, request.url.path)
    if not has_role(user, minimum):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=(
                f"Tu rol '{user.role}' no permite esta operación. "
                f"Se requiere '{minimum}' o superior."
            ),
        )
    return user


def require_role(minimum: str):
    """Dependencia para exigir un rol concreto en un endpoint puntual."""

    def _dependency(user: User = Depends(get_current_user)) -> User:
        if not has_role(user, minimum):
            raise HTTPException(
                status_code=status.HTTP_403_FORBIDDEN,
                detail=f"Se requiere rol '{minimum}' o superior.",
            )
        return user

    return _dependency


# ---------------------------------------------------------------------------
# Clave de automatización (Ansible / Prometheus / agentes)
# ---------------------------------------------------------------------------


def require_automation_key(
    x_api_key: Optional[str] = Header(default=None),
    authorization: Optional[str] = Header(default=None),
) -> None:
    """
    Valida la clave de automatización. A diferencia de la versión anterior,
    rechaza la petición cuando la cabecera falta y cuando el servicio no tiene
    AUTOMATION_API_KEY configurada (fail closed).
    """
    if not AUTOMATION_API_KEY:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=(
                "Los endpoints de automatización están deshabilitados: "
                "configura la variable de entorno AUTOMATION_API_KEY."
            ),
        )

    provided = (x_api_key or "").strip()
    if not provided and authorization:
        scheme, _, value = authorization.partition(" ")
        if scheme.lower() in ("bearer", "apikey"):
            provided = value.strip()

    if not provided or not secrets.compare_digest(provided, AUTOMATION_API_KEY):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Cabecera 'X-API-Key' ausente o inválida para la API de automatización.",
        )


# ---------------------------------------------------------------------------
# Protección SSRF para las descargas externas (proxy y búsqueda de fotos)
# ---------------------------------------------------------------------------

import ipaddress  # noqa: E402  (agrupado aquí por pertenecer a este bloque)
import socket  # noqa: E402
import urllib.request  # noqa: E402
from urllib.parse import urlparse  # noqa: E402

MAX_EXTERNAL_DOWNLOAD_BYTES = int(os.getenv("MAX_EXTERNAL_DOWNLOAD_BYTES", str(8 * 1024 * 1024)))


class _NoRedirects(urllib.request.HTTPRedirectHandler):
    """
    Bloquea los redirects: si no, un host público podría redirigir la petición
    a 169.254.169.254 o a la red interna y saltarse la validación de IP.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="La URL externa redirige y los redirects no están permitidos.",
        )


no_redirect_opener = urllib.request.build_opener(_NoRedirects)


def assert_safe_external_url(raw_url: str) -> str:
    """
    Valida que una URL apunte a un host público antes de que el backend la
    descargue. Evita que el proxy de imágenes se use como SSRF contra la red
    interna, localhost o los endpoints de metadatos de los proveedores cloud.
    """
    target = (raw_url or "").strip()
    parsed = urlparse(target)

    if parsed.scheme not in ("http", "https"):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Solo se permiten URLs http:// o https://.",
        )
    if not parsed.hostname:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="La URL no contiene un host válido.",
        )

    try:
        resolved = socket.getaddrinfo(parsed.hostname, parsed.port or 0, proto=socket.IPPROTO_TCP)
    except socket.gaierror:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"No se pudo resolver el host '{parsed.hostname}'.",
        )

    for family, _type, _proto, _canon, sockaddr in resolved:
        ip = ipaddress.ip_address(sockaddr[0])
        if (
            ip.is_private
            or ip.is_loopback
            or ip.is_link_local
            or ip.is_reserved
            or ip.is_multicast
            or ip.is_unspecified
        ):
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="No se permiten URLs que apunten a direcciones internas o reservadas.",
            )

    return target
