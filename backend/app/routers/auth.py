"""Autenticación local y Active Directory (LDAP / LDAPS), usuarios y roles RBAC."""

import ssl
import time
from urllib.parse import urlparse

from fastapi import Depends, HTTPException
from ldap3 import ALL, Connection, Server, SUBTREE, Tls
from ldap3.core.exceptions import LDAPBindError, LDAPException
from ldap3.utils.conv import escape_filter_chars
from sqlalchemy.orm import Session

from ..database import get_db
from ..logging_setup import get_logger
from ..models import ADServer, AlertContact, User

logger = get_logger(__name__)
from ..routers._common import VALID_ROLES, api_router, public_router
from ..schemas import (
    ADServerCreate,
    ADServerSchema,
    ADServerUpdate,
    ADUserImportRequest,
    ADUserSearchRequest,
    LoginRequest,
    UserCreate,
    UserSchema,
    UserUpdate,
)
from ..security import create_access_token, hash_password, verify_password

ROLE_PRIORITY = {"admin": 4, "editor": 3, "operator": 2, "viewer": 1}


def _parse_ldap_url(ldap_url: str) -> tuple[str, int, bool]:
    raw = (ldap_url or "").strip()
    if not raw.startswith(("ldap://", "ldaps://")):
        raw = f"ldap://{raw}"
    parsed = urlparse(raw)
    use_ssl = parsed.scheme.lower() == "ldaps"
    host = parsed.hostname or raw.replace("ldaps://", "").replace("ldap://", "").split(":")[0]
    port = parsed.port or (636 if use_ssl else 389)
    return host, int(port), use_ssl


def _build_ldap_server(srv: ADServer, connect_timeout: float = 4.0) -> Server:
    host, port, use_ssl = _parse_ldap_url(srv.ldap_url)
    tls_cfg = Tls(validate=ssl.CERT_NONE) if use_ssl else None
    return Server(
        host=host,
        port=port,
        use_ssl=use_ssl,
        tls=tls_cfg,
        get_info=ALL,
        connect_timeout=connect_timeout,
    )


def _extract_group_key(rule: dict) -> tuple[str, str, str]:
    gname = str(rule.get("group_name") or rule.get("group") or "").strip()
    gdn = str(rule.get("group_dn") or rule.get("group") or "").strip()
    role = str(rule.get("role") or "viewer").strip().lower()
    if role not in VALID_ROLES:
        role = "viewer"
    return gname.lower(), gdn.lower(), role


def _resolve_role_from_ad_groups(srv: ADServer, member_of: list[str]) -> str:
    default_role = srv.default_role if srv.default_role in VALID_ROLES else "viewer"
    if not member_of or not srv.group_role_mapping:
        return default_role

    matched_roles: list[str] = []
    member_of_lower = [str(m).lower() for m in member_of]
    for rule in (srv.group_role_mapping or []):
        gname_l, gdn_l, role = _extract_group_key(rule)
        short_cn = gname_l.replace("cn=", "").split(",")[0].strip()
        for m in member_of_lower:
            m_cn = m.replace("cn=", "").split(",")[0].strip()
            if (
                (gdn_l and gdn_l in m)
                or (gname_l and gname_l in m)
                or (short_cn and (short_cn == m_cn or short_cn in m))
            ):
                matched_roles.append(role)

    if not matched_roles:
        return default_role
    return max(matched_roles, key=lambda r: ROLE_PRIORITY.get(r, 0))


def _build_user_search_filter(srv: ADServer, username: str) -> str:
    safe_u = escape_filter_chars(username)
    tpl = (srv.user_filter or "").strip()
    if tpl and "{username}" in tpl:
        return tpl.replace("{username}", safe_u)
    return (
        f"(&(|(objectClass=user)(objectClass=person)(objectClass=inetOrgPerson))"
        f"(|(sAMAccountName={safe_u})(uid={safe_u})(userPrincipalName={safe_u}@*)(mail={safe_u})(cn={safe_u})))"
    )


def _ldap_authenticate_and_fetch_profile(
    srv: ADServer,
    username: str,
    password: str,
    known_dn: str = "",
) -> dict:
    """
    Autentica un usuario contra Active Directory / LDAP mediante Bind real.
    1. Si hay bind_dn configurado, abre conexión de servicio para buscar el DN, correo, nombre y memberOf del usuario.
    2. Ejecuta Bind LDAP real con las credenciales del usuario (probando su DN, UPN usuario@dominio y NetBIOS DOMINIO\\usuario).
    """
    if not password:
        return {"authenticated": False, "ldap_unreachable": False, "error": "Contraseña vacía."}

    server = _build_ldap_server(srv, connect_timeout=4.0)
    domain = (srv.domain or "corp.local").strip()
    netbios = domain.split(".")[0].upper() if domain else "CORP"
    base_dn = (srv.base_dn or "DC=corp,DC=local").strip()

    resolved_dn = (known_dn or "").strip()
    full_name = username
    email = f"{username}@{domain.lower()}"
    department = "Active Directory"
    member_of: list[str] = []

    # Paso 1: Si tenemos cuenta de servicio (bind_dn), buscar primero el DN y atributos del usuario
    if (srv.bind_dn or "").strip():
        try:
            with Connection(
                server,
                user=srv.bind_dn.strip(),
                password=srv.bind_password or "",
                auto_bind=True,
                receive_timeout=4,
            ) as svc_conn:
                search_filter = _build_user_search_filter(srv, username)
                svc_conn.search(
                    search_base=base_dn,
                    search_filter=search_filter,
                    search_scope=SUBTREE,
                    attributes=[
                        "distinguishedName",
                        "sAMAccountName",
                        "uid",
                        "cn",
                        "displayName",
                        "mail",
                        "userPrincipalName",
                        "department",
                        "memberOf",
                    ],
                )
                if svc_conn.entries:
                    entry = svc_conn.entries[0]
                    resolved_dn = str(entry.entry_dn)
                    full_name = str(
                         getattr(entry, "displayName", None)
                        or getattr(entry, "cn", None)
                        or username
                    )
                    email = str(
                        getattr(entry, "mail", None)
                        or getattr(entry, "userPrincipalName", None)
                        or email
                    )
                    if hasattr(entry, "department") and entry.department.value:
                        department = str(entry.department.value)
                    if hasattr(entry, "memberOf") and entry.memberOf.values:
                        member_of = [str(x) for x in entry.memberOf.values]
        except LDAPBindError as exc:
            # La cuenta de servicio falló, pero aún podemos intentar bind directo con el propio usuario
            pass
        except LDAPException as exc:
            return {
                "authenticated": False,
                "ldap_unreachable": True,
                "error": f"No se pudo conectar al servidor LDAP '{srv.ldap_url}': {exc}",
            }
        except Exception as exc:
            return {
                "authenticated": False,
                "ldap_unreachable": True,
                "error": f"Error de red hacia LDAP '{srv.ldap_url}': {exc}",
            }

    # Paso 2: Candidatos de Bind para validar la contraseña del usuario en Active Directory / OpenLDAP
    candidate_principals: list[str] = []
    if resolved_dn:
        candidate_principals.append(resolved_dn)
    if "@" in username:
        candidate_principals.append(username)
    else:
        if domain:
            candidate_principals.append(f"{username}@{domain}")
            candidate_principals.append(f"{netbios}\\{username}")
        candidate_principals.append(f"CN={username},{base_dn}")
        candidate_principals.append(f"uid={username},{base_dn}")

    seen = set()
    unique_principals = [p for p in candidate_principals if not (p in seen or seen.add(p))]

    last_bind_error = None
    for principal in unique_principals:
        try:
            with Connection(
                server,
                user=principal,
                password=password,
                auto_bind=True,
                receive_timeout=4,
            ) as user_conn:
                # Si aún no habíamos obtenido sus atributos (p.ej. sin bind_dn), consultarlos con su propia sesión
                if not member_of and base_dn:
                    try:
                        user_conn.search(
                            search_base=base_dn,
                            search_filter=_build_user_search_filter(srv, username.split("@")[0]),
                            search_scope=SUBTREE,
                            attributes=[
                                "distinguishedName",
                                "cn",
                                "displayName",
                                "mail",
                                "userPrincipalName",
                                "department",
                                "memberOf",
                            ],
                        )
                        if user_conn.entries:
                            entry = user_conn.entries[0]
                            resolved_dn = str(entry.entry_dn)
                            full_name = str(
                                getattr(entry, "displayName", None)
                                or getattr(entry, "cn", None)
                                or full_name
                            )
                            email = str(
                                getattr(entry, "mail", None)
                                or getattr(entry, "userPrincipalName", None)
                                or email
                            )
                            if hasattr(entry, "memberOf") and entry.memberOf.values:
                                member_of = [str(x) for x in entry.memberOf.values]
                    except Exception as exc:
                        logger.debug(
                            "Lectura suplementaria de perfil LDAP omitida para '%s': %s",
                            username,
                            exc,
                        )

                role = _resolve_role_from_ad_groups(srv, member_of)
                return {
                    "authenticated": True,
                    "ldap_unreachable": False,
                    "ad_dn": resolved_dn or principal,
                    "full_name": full_name,
                    "email": email,
                    "department": department,
                    "member_of": member_of,
                    "role": role,
                }
        except LDAPBindError as exc:
            last_bind_error = str(exc)
            continue
        except LDAPException as exc:
            return {
                "authenticated": False,
                "ldap_unreachable": True,
                "error": f"Servidor LDAP '{srv.ldap_url}' no accesible: {exc}",
            }
        except Exception as exc:
            return {
                "authenticated": False,
                "ldap_unreachable": True,
                "error": f"Error de conexión LDAP '{srv.ldap_url}': {exc}",
            }

    return {
        "authenticated": False,
        "ldap_unreachable": False,
        "error": f"Credenciales rechazadas por Active Directory ({last_bind_error or 'Bind inválido'}).",
    }


def _sync_ad_user_to_alert_contacts(db: Session, user: User, srv: ADServer | None = None) -> None:
    """Sincroniza automáticamente un usuario de Active Directory / Local como AlertContact para 8. Alarmas SRE."""
    u_email = (user.email or f"{user.username}@empresa.local").strip()
    u_code = f"USR-{'AD' if user.auth_source == 'ad' else 'LOCAL'}-{user.username.upper().replace('.', '-')}"[:48]
    existing_c = (
        db.query(AlertContact)
        .filter((AlertContact.code == u_code) | (AlertContact.email == u_email))
        .first()
    )
    dom_label = f"AD {srv.domain or srv.name}" if srv else "Active Directory"
    prefix = f"[{dom_label}]" if user.auth_source == "ad" else "[Usuario Local]"
    role_desc = f"{prefix} Rol RBAC: {user.role.upper()}" + (f" • {user.ad_dn}" if user.ad_dn else "")
    if not existing_c:
        db.add(
            AlertContact(
                code=u_code,
                full_name=user.full_name or user.username,
                role_title=role_desc[:120],
                email=u_email,
                phone_or_telegram=f"@{user.username}",
                schedule_period="24x7",
                notify_on_down=True,
                notify_on_critical=True,
                notify_on_warning=True,
                notify_on_unreachable=False,
                notify_on_recovery=True,
                active=bool(user.is_active),
            )
        )
    else:
        existing_c.full_name = user.full_name or existing_c.full_name
        existing_c.email = u_email
        existing_c.role_title = role_desc[:120]


@public_router.post(
    "/auth/login",
    tags=["Authentication, RBAC & Active Directory"],
    summary="Iniciar sesión (Usuario Local o Active Directory / LDAP con Auto-Provisioning RBAC)",
    description=(
        "Autentica usuarios locales contra bcrypt y usuarios de Active Directory mediante **Bind LDAP/LDAPS real** "
        "contra el controlador de dominio configurado (`DOMAIN\\user`, `user@domain` o `sAMAccountName`).\n\n"
        "- Si el usuario existe como `auth_source = 'ad'`, valida su contraseña contra el servidor LDAP/AD y actualiza "
        "su rol RBAC según `memberOf` y su hash de respaldo.\n"
        "- Si el usuario aún no existe en la tabla local pero pertenece a un servidor Active Directory habilitado, "
        "realiza **Auto-Provisioning Just-In-Time (JIT)** tras autenticar contra LDAP."
    ),
)
def login_endpoint(payload: LoginRequest, db: Session = Depends(get_db)):
    raw_input = payload.username.strip()
    pwd = payload.password

    uname = raw_input
    domain_hint = ""
    if "\\" in raw_input:
        domain_hint, uname = raw_input.split("\\", 1)
    elif "@" in raw_input and not db.query(User).filter(User.username == raw_input).first():
        uname, domain_hint = raw_input.split("@", 1)

    user = (
        db.query(User)
        .filter((User.username == uname) | (User.email == raw_input))
        .first()
    )

    # Caso 1: El usuario aún no está en la BBDD local -> intentar Auto-Provisioning contra servidores AD activos
    if not user:
        enabled_ads = db.query(ADServer).filter(ADServer.enabled == True).order_by(ADServer.id).all()  # noqa: E712
        if domain_hint:
            prioritized = [
                s for s in enabled_ads if domain_hint.lower() in (s.domain or "").lower() or domain_hint.lower() in (s.name or "").lower()
            ]
            others = [s for s in enabled_ads if s not in prioritized]
            enabled_ads = prioritized + others

        for ad_srv in enabled_ads:
            ldap_res = _ldap_authenticate_and_fetch_profile(ad_srv, uname, pwd)
            if ldap_res.get("authenticated"):
                user = User(
                    username=uname,
                    full_name=ldap_res.get("full_name") or uname,
                    email=ldap_res.get("email") or f"{uname}@{ad_srv.domain or 'corp.local'}",
                    password_hash=hash_password(pwd),
                    role=ldap_res.get("role") or ad_srv.default_role,
                    auth_source="ad",
                    ad_server_id=ad_srv.id,
                    ad_dn=ldap_res.get("ad_dn") or f"CN={uname},{ad_srv.base_dn}",
                    is_active=True,
                )
                db.add(user)
                db.flush()
                _sync_ad_user_to_alert_contacts(db, user, ad_srv)
                db.commit()
                db.refresh(user)
                break

        if not user:
            raise HTTPException(
                status_code=401,
                detail="Usuario no encontrado en RackDoc ni autenticado en Active Directory.",
            )

    if not user.is_active:
        raise HTTPException(status_code=403, detail="Esta cuenta de usuario está desactivada.")

    # Caso 2: Usuario de Active Directory registrado
    if user.auth_source == "ad":
        ad_srv = (
            db.query(ADServer).filter(ADServer.id == user.ad_server_id).first()
            if user.ad_server_id
            else db.query(ADServer).filter(ADServer.enabled == True).first()  # noqa: E712
        )
        if ad_srv and not ad_srv.enabled:
            raise HTTPException(
                status_code=403,
                detail=f"El servidor Active Directory '{ad_srv.name}' está deshabilitado.",
            )

        if ad_srv:
            ldap_res = _ldap_authenticate_and_fetch_profile(
                ad_srv,
                user.username,
                pwd,
                known_dn=user.ad_dn or "",
            )
            if ldap_res.get("authenticated"):
                # Actualizar caché de contraseña y metadatos AD tras bind exitoso
                user.password_hash = hash_password(pwd)
                if ldap_res.get("ad_dn"):
                    user.ad_dn = ldap_res["ad_dn"]
                if ldap_res.get("full_name"):
                    user.full_name = ldap_res["full_name"]
                if ldap_res.get("email"):
                    user.email = ldap_res["email"]
                if ldap_res.get("member_of"):
                    user.role = ldap_res.get("role") or user.role
                db.commit()
                db.refresh(user)
            elif ldap_res.get("ldap_unreachable"):
                # Si el Controlador de Dominio no responde por red (entorno offline / laboratorio),
                # permitimos validar contra el hash bcrypt cacheado del usuario AD.
                if not verify_password(pwd, user.password_hash):
                    raise HTTPException(
                        status_code=401,
                        detail=(
                            f"El servidor LDAP '{ad_srv.ldap_url}' no responde en red y la contraseña "
                            "no coincide con la credencial cacheada del usuario."
                        ),
                    )
            else:
                raise HTTPException(
                    status_code=401,
                    detail=ldap_res.get("error") or "Contraseña de Active Directory incorrecta.",
                )
        else:
            if not verify_password(pwd, user.password_hash):
                raise HTTPException(status_code=401, detail="Contraseña de Active Directory incorrecta.")
    else:
        # Caso 3: Usuario Local
        if not verify_password(pwd, user.password_hash):
            raise HTTPException(status_code=401, detail="Usuario o contraseña incorrectos.")

    session = create_access_token(user)
    return {
        "status": "ok",
        "token": session["token"],
        "token_type": session["token_type"],
        "expires_in": session["expires_in"],
        "expires_at": session["expires_at"],
        "user": UserSchema.model_validate(user).model_dump(),
    }


@api_router.get(
    "/users",
    response_model=list[UserSchema],
    tags=["Authentication, RBAC & Active Directory"],
    summary="Listar usuarios registrados y sus roles RBAC",
    description="Devuelve todos los usuarios dados de alta en RackDoc (locales y Active Directory) con su nivel de permisos (`admin`, `editor`, `operator`, `viewer`).",
)
def list_users(db: Session = Depends(get_db)):
    return db.query(User).order_by(User.id).all()


@api_router.post(
    "/users",
    response_model=UserSchema,
    tags=["Authentication, RBAC & Active Directory"],
    summary="Crear nuevo usuario (Local o Active Directory)",
    description="Registra una nueva cuenta de usuario con contraseña bcrypt/LDAP y rol RBAC, y la sincroniza con los contactos de alarma SRE.",
)
def create_user(payload: UserCreate, db: Session = Depends(get_db)):
    uname = payload.username.strip()
    if not uname:
        raise HTTPException(status_code=400, detail="El nombre de usuario es obligatorio.")
    role = payload.role if payload.role in VALID_ROLES else "viewer"

    exists = db.query(User).filter(User.username == uname).first()
    if exists:
        raise HTTPException(status_code=409, detail=f"El usuario '{uname}' ya existe.")

    user = User(
        username=uname,
        email=payload.email.strip() or f"{uname}@rackdoc.local",
        full_name=payload.full_name.strip() or uname,
        password_hash=hash_password(payload.password or f"{uname}123"),
        role=role,
        auth_source=payload.auth_source,
        ad_server_id=payload.ad_server_id,
        ad_dn=payload.ad_dn,
        is_active=payload.is_active,
    )
    db.add(user)
    db.flush()
    ad_srv = db.query(ADServer).filter(ADServer.id == user.ad_server_id).first() if user.ad_server_id else None
    _sync_ad_user_to_alert_contacts(db, user, ad_srv)
    db.commit()
    db.refresh(user)
    return user


@api_router.put(
    "/users/{user_id}",
    response_model=UserSchema,
    tags=["Authentication, RBAC & Active Directory"],
    summary="Actualizar usuario o cambiar rol RBAC",
    description="Modifica datos de perfil, contraseña, estado activo/inactivo o nivel de rol RBAC de un usuario.",
)
def update_user(user_id: int, payload: UserUpdate, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="Usuario no encontrado")

    if payload.username is not None and payload.username.strip():
        user.username = payload.username.strip()
    if payload.email is not None:
        user.email = payload.email.strip()
    if payload.full_name is not None:
        user.full_name = payload.full_name.strip()
    if payload.password is not None and payload.password.strip():
        user.password_hash = hash_password(payload.password.strip())
    if payload.role is not None and payload.role in VALID_ROLES:
        user.role = payload.role
    if payload.is_active is not None:
        user.is_active = payload.is_active
    if payload.ad_server_id is not None:
        user.ad_server_id = payload.ad_server_id

    ad_srv = db.query(ADServer).filter(ADServer.id == user.ad_server_id).first() if user.ad_server_id else None
    _sync_ad_user_to_alert_contacts(db, user, ad_srv)
    db.commit()
    db.refresh(user)
    return user


@api_router.delete(
    "/users/{user_id}",
    tags=["Authentication, RBAC & Active Directory"],
    summary="Eliminar usuario",
    description="Elimina una cuenta de usuario (impidiendo borrar el único administrador del sistema).",
)
def delete_user(user_id: int, db: Session = Depends(get_db)):
    user = db.query(User).filter(User.id == user_id).first()
    if not user:
        raise HTTPException(status_code=404, detail="Usuario no encontrado")
    if user.role == "admin":
        admin_count = db.query(User).filter(User.role == "admin").count()
        if admin_count <= 1:
            raise HTTPException(
                status_code=400,
                detail="No puedes eliminar el único usuario Administrador del sistema.",
            )
    db.delete(user)
    db.commit()
    return {"status": "deleted", "id": user_id}


@api_router.get(
    "/ad-servers",
    response_model=list[ADServerSchema],
    tags=["Authentication, RBAC & Active Directory"],
    summary="Listar servidores Active Directory / LDAP configurados",
    description="Devuelve los controladores de dominio Active Directory / LDAP configurados y su mapeo de grupos a roles RBAC.",
)
def list_ad_servers(db: Session = Depends(get_db)):
    return db.query(ADServer).order_by(ADServer.id).all()


@api_router.post(
    "/ad-servers",
    response_model=ADServerSchema,
    tags=["Authentication, RBAC & Active Directory"],
    summary="Añadir un servidor Active Directory / LDAP",
    description="Guarda un controlador de dominio LDAP/LDAPS y su mapeo de grupos a roles RBAC.",
)
def create_ad_server(payload: ADServerCreate, db: Session = Depends(get_db)):
    srv = ADServer(**payload.model_dump())
    db.add(srv)
    db.commit()
    db.refresh(srv)
    return srv


@api_router.put(
    "/ad-servers/{ad_id}",
    response_model=ADServerSchema,
    tags=["Authentication, RBAC & Active Directory"],
    summary="Actualizar un servidor Active Directory / LDAP",
    description="Actualiza los parámetros LDAP/LDAPS, el Base DN, el Bind DN o el mapeo de grupos a roles.",
)
def update_ad_server(ad_id: int, payload: ADServerUpdate, db: Session = Depends(get_db)):
    srv = db.query(ADServer).filter(ADServer.id == ad_id).first()
    if not srv:
        raise HTTPException(status_code=404, detail="Servidor Active Directory no encontrado")
    data = payload.model_dump(exclude_unset=True)
    # Si bind_password viene vacío al editar, conservar la contraseña guardada previamente
    if "bind_password" in data and not data["bind_password"]:
        data.pop("bind_password")
    for k, v in data.items():
        setattr(srv, k, v)
    db.commit()
    db.refresh(srv)
    return srv


@api_router.delete(
    "/ad-servers/{ad_id}",
    tags=["Authentication, RBAC & Active Directory"],
    summary="Eliminar un servidor Active Directory / LDAP",
    description="Elimina la configuración de un servidor de dominio.",
)
def delete_ad_server(ad_id: int, db: Session = Depends(get_db)):
    srv = db.query(ADServer).filter(ADServer.id == ad_id).first()
    if not srv:
        raise HTTPException(status_code=404, detail="Servidor Active Directory no encontrado")
    db.delete(srv)
    db.commit()
    return {"status": "deleted", "id": ad_id}


@api_router.post(
    "/ad-servers/{ad_id}/test",
    tags=["Authentication, RBAC & Active Directory"],
    summary="Probar conexión y Bind LDAP/LDAPS contra el servidor Active Directory",
    description="Abre una conexión TCP/TLS y realiza el Bind LDAP real contra el controlador de dominio para verificar conectividad, credenciales de servicio y Base DN.",
)
def test_ad_server_connection(ad_id: int, db: Session = Depends(get_db)):
    srv = db.query(ADServer).filter(ADServer.id == ad_id).first()
    if not srv:
        raise HTTPException(status_code=404, detail="Servidor AD no encontrado")

    t0 = time.perf_counter()
    server = _build_ldap_server(srv, connect_timeout=4.0)
    try:
        bind_user = (srv.bind_dn or "").strip() or None
        bind_pwd = (srv.bind_password or "") if bind_user else None
        with Connection(
            server,
            user=bind_user,
            password=bind_pwd,
            auto_bind=True,
            receive_timeout=4,
        ) as conn:
            elapsed_ms = round((time.perf_counter() - t0) * 1000, 1)
            entries_found = 0
            if (srv.base_dn or "").strip():
                conn.search(
                    search_base=srv.base_dn.strip(),
                    search_filter="(|(objectClass=user)(objectClass=person)(objectClass=organizationalUnit))",
                    search_scope=SUBTREE,
                    attributes=["cn"],
                    size_limit=50,
                )
                entries_found = len(conn.entries)
            return {
                "status": "ok",
                "connected": True,
                "ad_server_id": srv.id,
                "ldap_url": srv.ldap_url,
                "base_dn": srv.base_dn,
                "bind_dn": srv.bind_dn or "Anonymous Bind",
                "latency_ms": elapsed_ms,
                "entries_sampled": entries_found,
                "message": (
                    f"Conexión LDAP exitosa a {srv.ldap_url} en {elapsed_ms} ms "
                    f"({entries_found} objetos verificados bajo {srv.base_dn})."
                ),
            }
    except LDAPBindError as exc:
        elapsed_ms = round((time.perf_counter() - t0) * 1000, 1)
        return {
            "status": "bind_error",
            "connected": False,
            "ad_server_id": srv.id,
            "ldap_url": srv.ldap_url,
            "latency_ms": elapsed_ms,
            "message": f"El servidor LDAP respondió pero rechazó las credenciales de Bind DN ({srv.bind_dn}): {exc}",
        }
    except Exception as exc:
        elapsed_ms = round((time.perf_counter() - t0) * 1000, 1)
        return {
            "status": "unreachable",
            "connected": False,
            "ad_server_id": srv.id,
            "ldap_url": srv.ldap_url,
            "latency_ms": elapsed_ms,
            "message": f"No se pudo establecer conexión con {srv.ldap_url} ({elapsed_ms} ms): {exc}",
        }


@api_router.post(
    "/ad-servers/{ad_id}/search-users",
    tags=["Authentication, RBAC & Active Directory"],
    summary="Buscar usuarios en Active Directory / LDAP en tiempo real (con fallback de laboratorio)",
    description=(
        "Conecta por LDAP/LDAPS al controlador de dominio usando `bind_dn` y `bind_password`, "
        "busca cuentas en `base_dn` y calcula el rol RBAC según `group_role_mapping`. "
        "Si el controlador de dominio no es alcanzable desde la red actual, devuelve plantillas de laboratorio "
        "indicando `ldap_connected: false` para permitir pruebas en entornos aislados."
    ),
)
def search_ad_directory_users(
    ad_id: int,
    payload: ADUserSearchRequest,
    db: Session = Depends(get_db),
):
    srv = db.query(ADServer).filter(ADServer.id == ad_id).first()
    if not srv:
        raise HTTPException(status_code=404, detail="Servidor AD no encontrado")

    q = payload.query.strip()
    q_lower = q.lower()
    domain_suffix = srv.domain or "corp.local"
    base_dn = srv.base_dn or "DC=corp,DC=local"

    ldap_connected = False
    ldap_error = ""
    directory_entries: list[dict] = []

    # 1. Intentar búsqueda LDAP en vivo contra el Controlador de Dominio
    try:
        server = _build_ldap_server(srv, connect_timeout=3.5)
        bind_user = (srv.bind_dn or "").strip() or None
        bind_pwd = (srv.bind_password or "") if bind_user else None
        with Connection(
            server,
            user=bind_user,
            password=bind_pwd,
            auto_bind=True,
            receive_timeout=4,
        ) as conn:
            ldap_connected = True
            if q:
                safe_q = escape_filter_chars(q)
                ldap_filter = (
                    f"(&(|(objectClass=user)(objectClass=person)(objectClass=inetOrgPerson))"
                    f"(!(objectClass=computer))"
                    f"(|(sAMAccountName=*{safe_q}*)(uid=*{safe_q}*)(cn=*{safe_q}*)(displayName=*{safe_q}*)(mail=*{safe_q}*)))"
                )
            else:
                ldap_filter = (
                    "(&(|(objectClass=user)(objectClass=person)(objectClass=inetOrgPerson))"
                    "(!(objectClass=computer)))"
                )

            conn.search(
                search_base=base_dn,
                search_filter=ldap_filter,
                search_scope=SUBTREE,
                attributes=[
                    "sAMAccountName",
                    "uid",
                    "cn",
                    "displayName",
                    "mail",
                    "userPrincipalName",
                    "department",
                    "memberOf",
                ],
                size_limit=100,
            )
            for entry in conn.entries:
                uname = str(
                    getattr(entry, "sAMAccountName", None)
                    or getattr(entry, "uid", None)
                    or getattr(entry, "cn", None)
                    or ""
                ).strip()
                if not uname or uname.endswith("$"):
                    continue
                fname = str(
                    getattr(entry, "displayName", None)
                    or getattr(entry, "cn", None)
                    or uname
                ).strip()
                mail = str(
                    getattr(entry, "mail", None)
                    or getattr(entry, "userPrincipalName", None)
                    or f"{uname}@{domain_suffix.lower()}"
                ).strip()
                dept = (
                    str(entry.department.value)
                    if hasattr(entry, "department") and entry.department.value
                    else "Directorio Activo"
                )
                member_of = (
                    [str(x) for x in entry.memberOf.values]
                    if hasattr(entry, "memberOf") and entry.memberOf.values
                    else []
                )
                first_group = (
                    member_of[0].replace("CN=", "").split(",")[0]
                    if member_of
                    else "Domain Users"
                )
                suggested_role = _resolve_role_from_ad_groups(srv, member_of)
                directory_entries.append(
                    {
                        "username": uname,
                        "full_name": fname,
                        "email": mail,
                        "ad_dn": str(entry.entry_dn),
                        "ad_group": first_group,
                        "department": dept,
                        "suggested_role": suggested_role,
                        "source": "ldap_live",
                    }
                )
    except Exception as exc:
        ldap_connected = False
        ldap_error = str(exc)

    # 2. Si el servidor LDAP no es alcanzable desde esta red (p.ej. entorno demo/lab sin DC en vivo),
    # ofrecer entradas de pre-aprovisionamiento adaptadas al mapeo de grupos del servidor AD
    if not ldap_connected:
        sample_templates = [
            {
                "username": "jgarcia",
                "full_name": "Javier García (NetOps AD)",
                "email": f"jgarcia@{domain_suffix.lower()}",
                "ad_dn": f"CN=Javier Garcia,OU=NetOps,{base_dn}",
                "ad_group": "CN=NetOps_Infrastructure,OU=Groups",
                "department": "Infraestructura & Redes",
            },
            {
                "username": "mfernandez",
                "full_name": "Marta Fernández (SysAdmin AD)",
                "email": f"mfernandez@{domain_suffix.lower()}",
                "ad_dn": f"CN=Marta Fernandez,OU=Sistemas,{base_dn}",
                "ad_group": "CN=NetOps_Infrastructure,OU=Groups",
                "department": "Sistemas & Virtualización",
            },
            {
                "username": "rnavarro",
                "full_name": "Roberto Navarro (Guardia NOC SSH/Web)",
                "email": f"rnavarro@{domain_suffix.lower()}",
                "ad_dn": f"CN=Roberto Navarro,OU=NOC,{base_dn}",
                "ad_group": "CN=NOC_Operators,OU=Groups",
                "department": "Operaciones 24x7 (SSH & Web)",
            },
            {
                "username": "elopez",
                "full_name": "Elena López (Auditoría TI)",
                "email": f"elopez@{domain_suffix.lower()}",
                "ad_dn": f"CN=Elena Lopez,OU=Auditoria,{base_dn}",
                "ad_group": "CN=SecAudit_ReadOnly,OU=Groups",
                "department": "Seguridad & Compliance",
            },
            {
                "username": "admin_ad",
                "full_name": "Administrador Dominio AD",
                "email": f"admin_ad@{domain_suffix.lower()}",
                "ad_dn": f"CN=Domain Admin,OU=Admins,{base_dn}",
                "ad_group": "CN=Domain Admins,OU=Groups",
                "department": "Arquitectura TI",
            },
        ]
        for tpl in sample_templates:
            tpl["suggested_role"] = _resolve_role_from_ad_groups(srv, [tpl["ad_group"]])
            tpl["source"] = "preprovision_template"
            directory_entries.append(tpl)

        if q_lower and not any(
            q_lower in e["username"].lower()
            or q_lower in e["full_name"].lower()
            or q_lower in e.get("ad_group", "").lower()
            for e in directory_entries
        ):
            clean_u = q_lower.split("@")[0].replace(" ", ".")
            directory_entries.insert(
                0,
                {
                    "username": clean_u,
                    "full_name": f"{clean_u.capitalize()} ({srv.name})",
                    "email": f"{clean_u}@{domain_suffix.lower()}",
                    "ad_dn": f"CN={clean_u},OU=Users,{base_dn}",
                    "ad_group": "Domain Users",
                    "department": "Directorio Activo",
                    "suggested_role": srv.default_role,
                    "source": "preprovision_template",
                },
            )
        elif q_lower:
            directory_entries = [
                e
                for e in directory_entries
                if q_lower in e["username"].lower()
                or q_lower in e["full_name"].lower()
                or q_lower in e["department"].lower()
                or q_lower in e.get("ad_group", "").lower()
            ]

    existing_usernames = {u.username for u in db.query(User).all()}
    for item in directory_entries:
        item["already_registered"] = item["username"] in existing_usernames

    return {
        "ad_server_id": srv.id,
        "ad_server_name": srv.name,
        "domain": domain_suffix,
        "ldap_connected": ldap_connected,
        "ldap_error": ldap_error,
        "results": directory_entries,
    }


@api_router.post(
    "/ad-servers/{ad_id}/import-users",
    tags=["Authentication, RBAC & Active Directory"],
    summary="Importar o pre-aprovisionar cuentas de Active Directory con rol RBAC y sincronización SRE",
    description=(
        "Da de alta o actualiza cuentas de dominio (`auth_source = 'ad'`) vinculadas al servidor AD indicado. "
        "Al iniciar sesión, RackDoc validará sus credenciales por **Bind LDAP real** contra el servidor AD "
        "(o contra la contraseña inicial/cacheada si el DC no está accesible en red), y las sincroniza "
        "automáticamente como contactos conocidos en **8. Alarmas SRE**."
    ),
)
def import_ad_users(
    ad_id: int,
    payload: ADUserImportRequest,
    db: Session = Depends(get_db),
):
    srv = db.query(ADServer).filter(ADServer.id == ad_id).first()
    if not srv:
        raise HTTPException(status_code=404, detail="Servidor AD no encontrado")

    imported = []
    for item in payload.users:
        uname = item.username.strip()
        if not uname:
            continue
        role = item.role if item.role in VALID_ROLES else srv.default_role
        fallback_pwd = (item.initial_password or "").strip() or f"{uname}123"
        user = db.query(User).filter(User.username == uname).first()
        if user:
            user.role = role
            user.auth_source = "ad"
            user.ad_server_id = srv.id
            user.ad_dn = item.ad_dn or user.ad_dn
            user.full_name = item.full_name or user.full_name
            user.email = item.email or user.email
            if (item.initial_password or "").strip():
                user.password_hash = hash_password(item.initial_password.strip())
            user.is_active = True
        else:
            user = User(
                username=uname,
                full_name=item.full_name or uname,
                email=item.email or f"{uname}@{(srv.domain or 'corp.local').lower()}",
                password_hash=hash_password(fallback_pwd),
                role=role,
                auth_source="ad",
                ad_server_id=srv.id,
                ad_dn=item.ad_dn or f"CN={uname},{srv.base_dn}",
                is_active=True,
            )
            db.add(user)
            db.flush()
        _sync_ad_user_to_alert_contacts(db, user, srv)
        imported.append(uname)

    db.commit()
    return {
        "status": "ok",
        "imported_count": len(imported),
        "usernames": imported,
    }
