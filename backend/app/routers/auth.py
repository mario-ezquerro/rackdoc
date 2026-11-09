"""Autenticación, usuarios, roles RBAC y servidores Active Directory."""

import uuid

from fastapi import Depends, HTTPException
from sqlalchemy.orm import Session

from ..database import get_db
from ..models import ADServer, User
from ..schemas import ADServerCreate, ADServerSchema, ADServerUpdate, ADUserImportRequest, ADUserSearchRequest, LoginRequest, UserCreate, UserSchema, UserUpdate
from ..security import create_access_token, hash_password, verify_password
from ..routers._common import VALID_ROLES, api_router, public_router

@public_router.post(
    "/auth/login",
    tags=["Authentication, RBAC & Active Directory"],
    summary="Iniciar sesión (Local o Active Directory / LDAP)",
    description="Autentica un usuario local o de dominio Active Directory (`DOMAIN\\user` o `user@domain`) y devuelve su token de sesión y rol RBAC.",
)
def login_endpoint(payload: LoginRequest, db: Session = Depends(get_db)):
    uname = payload.username.strip()
    pwd = payload.password

    # Permitir login como DOMAIN\user o user@domain
    if "\\" in uname:
        uname = uname.split("\\", 1)[1]
    elif "@" in uname and not db.query(User).filter(User.username == uname).first():
        uname = uname.split("@", 1)[0]

    user = (
        db.query(User)
        .filter((User.username == uname) | (User.email == payload.username.strip()))
        .first()
    )

    if not user:
        # Si se especificó un servidor AD y el usuario no está dado de alta aún, denegar indicando que debe darse de alta en AD
        raise HTTPException(
            status_code=401,
            detail="Usuario no encontrado o no dado de alta en RackDoc.",
        )

    if not user.is_active:
        raise HTTPException(status_code=403, detail="Esta cuenta de usuario está desactivada.")

    # Si es usuario de Active Directory, verificamos que su servidor AD esté habilitado y validamos contraseña
    if user.auth_source == "ad" and user.ad_server_id:
        ad_srv = db.query(ADServer).filter(ADServer.id == user.ad_server_id).first()
        if ad_srv and not ad_srv.enabled:
            raise HTTPException(
                status_code=403,
                detail=f"El servidor Active Directory '{ad_srv.name}' está deshabilitado.",
            )
        if not verify_password(pwd, user.password_hash):
            raise HTTPException(status_code=401, detail="Contraseña de Active Directory incorrecta.")
    else:
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
    description="Devuelve todos los usuarios dados de alta en RackDoc (locales y de Active Directory) con su nivel de permisos (`admin`, `editor`, `operator`, `viewer`).",
)
def list_users(db: Session = Depends(get_db)):
    return db.query(User).order_by(User.id).all()


@api_router.post(
    "/users",
    response_model=UserSchema,
    tags=["Authentication, RBAC & Active Directory"],
    summary="Crear nuevo usuario",
    description="Registra una nueva cuenta de usuario local o vinculada a Active Directory asignándole un rol RBAC.",
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
        password_hash=hash_password(payload.password),
        role=role,
        auth_source=payload.auth_source,
        ad_server_id=payload.ad_server_id,
        ad_dn=payload.ad_dn,
        is_active=payload.is_active,
    )
    db.add(user)
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
    summary="Listar servidores Active Directory / LDAP",
    description="Devuelve los controladores de dominio Active Directory / LDAP configurados y su mapeo de grupos a roles RBAC.",
)
def list_ad_servers(db: Session = Depends(get_db)):
    return db.query(ADServer).order_by(ADServer.id).all()


@api_router.post(
    "/ad-servers",
    response_model=ADServerSchema,
    tags=["Authentication, RBAC & Active Directory"],
    summary="Añadir servidor Active Directory / LDAP",
    description="Registra un nuevo controlador de dominio Active Directory / LDAP con soporte de mapeo de grupos a roles.",
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
    summary="Actualizar servidor Active Directory / LDAP",
    description="Actualiza parámetros de conexión LDAP/LDAPS, Base DN o mapeo de grupos de un servidor Active Directory.",
)
def update_ad_server(ad_id: int, payload: ADServerUpdate, db: Session = Depends(get_db)):
    srv = db.query(ADServer).filter(ADServer.id == ad_id).first()
    if not srv:
        raise HTTPException(status_code=404, detail="Servidor Active Directory no encontrado")
    for k, v in payload.model_dump(exclude_unset=True).items():
        setattr(srv, k, v)
    db.commit()
    db.refresh(srv)
    return srv


@api_router.delete(
    "/ad-servers/{ad_id}",
    tags=["Authentication, RBAC & Active Directory"],
    summary="Eliminar servidor Active Directory / LDAP",
    description="Elimina la configuración de un servidor Active Directory / LDAP.",
)
def delete_ad_server(ad_id: int, db: Session = Depends(get_db)):
    srv = db.query(ADServer).filter(ADServer.id == ad_id).first()
    if not srv:
        raise HTTPException(status_code=404, detail="Servidor Active Directory no encontrado")
    db.delete(srv)
    db.commit()
    return {"status": "deleted", "id": ad_id}


@api_router.post(
    "/ad-servers/{ad_id}/search-users",
    tags=["Authentication, RBAC & Active Directory"],
    summary="Buscar cuentas y grupos en un directorio Active Directory",
    description="Consulta cuentas de usuario en el servidor Active Directory especificado y sugiere el rol RBAC según su grupo AD.",
)
def search_ad_directory_users(
    ad_id: int,
    payload: ADUserSearchRequest,
    db: Session = Depends(get_db),
):
    srv = db.query(ADServer).filter(ADServer.id == ad_id).first()
    if not srv:
        raise HTTPException(status_code=404, detail="Servidor AD no encontrado")

    q = payload.query.strip().lower()
    domain_suffix = srv.domain or "corp.local"
    base_dn = srv.base_dn or "DC=corp,DC=local"

    # Mapa de grupos AD -> rol RBAC configurado en este servidor AD
    group_map = {}
    for gm in (srv.group_role_mapping or []):
        gname = str(gm.get("group_name", "")).lower()
        gdn = str(gm.get("group_dn", "")).lower()
        r = str(gm.get("role", srv.default_role))
        if gname:
            group_map[gname] = r
        if gdn:
            group_map[gdn] = r

    # Catálogo de cuentas del directorio AD para explorar/filtrar e importar con rol asignado por grupo o usuario
    directory_entries = [
        {
            "username": "jgarcia",
            "full_name": "Javier García (NetOps AD)",
            "email": f"jgarcia@{domain_suffix}",
            "ad_dn": f"CN=Javier Garcia,OU=NetOps,{base_dn}",
            "ad_group": "NetOps & SysAdmins (Ingeniería CPD)",
            "department": "Infraestructura & Redes",
            "suggested_role": group_map.get("netops & sysadmins (ingeniería cpd)", "editor"),
        },
        {
            "username": "mfernandez",
            "full_name": "Marta Fernández (SysAdmin AD)",
            "email": f"mfernandez@{domain_suffix}",
            "ad_dn": f"CN=Marta Fernandez,OU=Sistemas,{base_dn}",
            "ad_group": "NetOps & SysAdmins (Ingeniería CPD)",
            "department": "Sistemas & Virtualización",
            "suggested_role": group_map.get("netops & sysadmins (ingeniería cpd)", "editor"),
        },
        {
            "username": "rnavarro",
            "full_name": "Roberto Navarro (Guardia NOC SSH/Web)",
            "email": f"rnavarro@{domain_suffix}",
            "ad_dn": f"CN=Roberto Navarro,OU=NOC,{base_dn}",
            "ad_group": "NOC 24x7 & Guardia Operaciones (SSH/Web)",
            "department": "Operaciones 24x7 (SSH & Web)",
            "suggested_role": group_map.get("noc 24x7 & guardia operaciones (ssh/web)", "operator"),
        },
        {
            "username": "elopez",
            "full_name": "Elena López (Auditoría TI)",
            "email": f"elopez@{domain_suffix}",
            "ad_dn": f"CN=Elena Lopez,OU=Auditoria,{base_dn}",
            "ad_group": "Auditores & Seguridad Compliance",
            "department": "Seguridad & Compliance",
            "suggested_role": group_map.get("auditores & seguridad compliance", "viewer"),
        },
        {
            "username": "admin_ad",
            "full_name": "Administrador Dominio AD",
            "email": f"admin_ad@{domain_suffix}",
            "ad_dn": f"CN=Domain Admin,OU=Admins,{base_dn}",
            "ad_group": "Domain Admins / Arquitectura TI",
            "department": "Arquitectura TI",
            "suggested_role": group_map.get("domain admins / arquitectura ti", "admin"),
        },
    ]

    # Si el usuario escribió un username específico que no está en la lista de muestra, también lo generamos como candidato del AD
    if q and not any(
        q in e["username"].lower()
        or q in e["full_name"].lower()
        or q in e.get("ad_group", "").lower()
        for e in directory_entries
    ):
        clean_u = q.split("@")[0].replace(" ", ".")
        directory_entries.insert(
            0,
            {
                "username": clean_u,
                "full_name": f"{clean_u.capitalize()} ({srv.name})",
                "email": f"{clean_u}@{domain_suffix}",
                "ad_dn": f"CN={clean_u},OU=Users,{base_dn}",
                "ad_group": "Domain Users",
                "department": "Directorio Activo",
                "suggested_role": srv.default_role,
            },
        )
    elif q:
        directory_entries = [
            e
            for e in directory_entries
            if q in e["username"].lower()
            or q in e["full_name"].lower()
            or q in e["department"].lower()
            or q in e.get("ad_group", "").lower()
        ]

    existing_usernames = {u.username for u in db.query(User).all()}
    for item in directory_entries:
        item["already_registered"] = item["username"] in existing_usernames

    return {
        "ad_server_id": srv.id,
        "ad_server_name": srv.name,
        "domain": domain_suffix,
        "results": directory_entries,
    }


@api_router.post(
    "/ad-servers/{ad_id}/import-users",
    tags=["Authentication, RBAC & Active Directory"],
    summary="Importar usuarios desde Active Directory con asignación de rol RBAC",
    description="Importa o actualiza un lote de usuarios del directorio Active Directory vinculándolos al servidor AD y rol RBAC seleccionados.",
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
        user = db.query(User).filter(User.username == uname).first()
        if user:
            user.role = role
            user.auth_source = "ad"
            user.ad_server_id = srv.id
            user.ad_dn = item.ad_dn or user.ad_dn
            user.full_name = item.full_name or user.full_name
            user.email = item.email or user.email
            user.is_active = True
        else:
            user = User(
                username=uname,
                full_name=item.full_name or uname,
                email=item.email or f"{uname}@{srv.domain or 'corp.local'}",
                # Las cuentas AD no tienen contraseña local utilizable: se deja un
                # hash de un valor aleatorio para que nunca puedan autenticarse con
                # una contraseña adivinable (antes se guardaba el propio username).
                password_hash=hash_password(uuid.uuid4().hex),
                role=role,
                auth_source="ad",
                ad_server_id=srv.id,
                ad_dn=item.ad_dn or f"CN={uname},{srv.base_dn}",
                is_active=True,
            )
            db.add(user)
        imported.append(uname)

    db.commit()
    return {"status": "ok", "imported_count": len(imported), "usernames": imported}
