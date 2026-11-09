from datetime import datetime
from typing import Dict, Any, List, Optional, Tuple
import re
import socket
import ssl
import subprocess
import smtplib
from email.mime.text import MIMEText
from email.utils import parsedate_to_datetime
import urllib.request
import json

from sqlalchemy.orm import Session

from .. import models


def clean_host_and_port(raw_host: str, default_port: int = 443) -> Tuple[str, int, str]:
    """Limpia URLs o host:puerto (ej. 'https://192.168.2.1:8443/login' -> ('192.168.2.1', 8443, '192.168.2.1'))."""
    val = (raw_host or "").strip()
    if not val:
        return "", default_port or 443, ""
    val = re.sub(r"^https?://", "", val, flags=re.IGNORECASE)
    val = val.split("/")[0].strip()
    port = default_port or 443
    if ":" in val and not val.startswith("["):
        parts = val.rsplit(":", 1)
        host_part = parts[0].strip()
        try:
            port = int(parts[1].strip())
        except ValueError:
            pass
        val = host_part
    return val, port, val


def _parse_openssl_date(date_str: str) -> Optional[datetime]:
    raw = (date_str or "").strip()
    if not raw:
        return None
    for prefix in ("notBefore=", "notAfter="):
        if raw.startswith(prefix):
            raw = raw[len(prefix):].strip()
    # Try standard OpenSSL ASN1_TIME format: 'Nov  9 21:15:00 2026 GMT'
    normalized = re.sub(r"\s+", " ", raw.replace("GMT", "").strip())
    for fmt in ("%b %d %H:%M:%S %Y", "%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d"):
        try:
            return datetime.strptime(normalized, fmt)
        except ValueError:
            continue
    try:
        dt = parsedate_to_datetime(raw)
        return dt.replace(tzinfo=None)
    except Exception:
        return None


def parse_date_flexible(date_val: Optional[str]) -> Optional[datetime]:
    if not date_val:
        return None
    raw = str(date_val).strip()
    if not raw:
        return None
    raw_clean = raw.replace("Z", "").split("+")[0].strip()
    for fmt in (
        "%Y-%m-%d",
        "%Y-%m-%d %H:%M:%S",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%dT%H:%M:%S.%f",
        "%d/%m/%Y",
    ):
        try:
            return datetime.strptime(raw_clean, fmt)
        except ValueError:
            continue
    return _parse_openssl_date(raw)


def _extract_dn_field(dn_text: str, key: str) -> str:
    # Matches CN=foo or CN = foo in RFC2253 or slash-separated subject/issuer
    pattern = rf"(?:^|[,/]\s*){re.escape(key)}\s*=\s*([^,/]+)"
    m = re.search(pattern, dn_text or "", flags=re.IGNORECASE)
    if m:
        return m.group(1).strip().strip('"')
    return ""


def compute_cert_status_and_days(
    valid_until: Optional[datetime],
    warn_days: int = 30,
    critical_days: int = 7,
    check_mode: str = "https_live",
    probe_error: str = "",
) -> Tuple[str, Optional[int]]:
    if valid_until is None:
        if check_mode == "manual":
            return "manual_unverified", None
        return ("unreachable" if probe_error else "unknown"), None

    now = datetime.utcnow()
    delta_seconds = (valid_until - now).total_seconds()
    days_remaining = int(delta_seconds // 86400)

    if delta_seconds < 0:
        return "expired", days_remaining
    if days_remaining <= (critical_days or 7):
        return "critical", days_remaining
    if days_remaining <= (warn_days or 30):
        return "expiring_soon", days_remaining
    return "valid", days_remaining


def parse_pem_certificate(pem_text: str) -> Dict[str, Any]:
    """Extrae metadatos X.509 de un certificado en texto PEM usando `openssl x509`."""
    cleaned = (pem_text or "").strip()
    if "-----BEGIN CERTIFICATE-----" not in cleaned:
        return {
            "ok": False,
            "error": "El texto proporcionado no contiene un bloque -----BEGIN CERTIFICATE----- válido.",
        }

    try:
        proc = subprocess.run(
            [
                "openssl",
                "x509",
                "-noout",
                "-subject",
                "-issuer",
                "-startdate",
                "-enddate",
                "-serial",
                "-fingerprint",
                "-sha256",
                "-ext",
                "subjectAltName",
                "-nameopt",
                "RFC2253",
            ],
            input=cleaned,
            text=True,
            capture_output=True,
            timeout=5,
        )
    except Exception as exc:
        return {"ok": False, "error": f"Error invocando openssl x509: {exc}"}

    if proc.returncode != 0:
        err = (proc.stderr or proc.stdout or "Certificado PEM inválido").strip()
        return {"ok": False, "error": f"OpenSSL no pudo leer el certificado: {err}"}

    subject_raw = ""
    issuer_raw = ""
    valid_from: Optional[datetime] = None
    valid_until: Optional[datetime] = None
    serial_number = ""
    fingerprint_sha256 = ""
    san_domains: List[str] = []

    lines = (proc.stdout or "").splitlines()
    in_san = False
    for line in lines:
        s = line.strip()
        if s.startswith("subject="):
            subject_raw = s[len("subject="):].strip()
            in_san = False
        elif s.startswith("issuer="):
            issuer_raw = s[len("issuer="):].strip()
            in_san = False
        elif s.startswith("notBefore="):
            valid_from = _parse_openssl_date(s)
            in_san = False
        elif s.startswith("notAfter="):
            valid_until = _parse_openssl_date(s)
            in_san = False
        elif s.startswith("serial="):
            serial_number = s[len("serial="):].strip()
            in_san = False
        elif "Fingerprint=" in s:
            fingerprint_sha256 = s.split("Fingerprint=", 1)[1].strip()
            in_san = False
        elif "X509v3 Subject Alternative Name" in s:
            in_san = True
        elif in_san:
            # e.g. DNS:example.com, DNS:*.example.com, IP Address:192.168.2.1
            tokens = [t.strip() for t in s.split(",") if t.strip()]
            for tok in tokens:
                if ":" in tok:
                    val = tok.split(":", 1)[1].strip()
                    if val and val not in san_domains:
                        san_domains.append(val)
            in_san = False

    common_name = _extract_dn_field(subject_raw, "CN") or subject_raw
    issuer_cn = _extract_dn_field(issuer_raw, "CN") or _extract_dn_field(issuer_raw, "OU") or issuer_raw
    issuer_org = _extract_dn_field(issuer_raw, "O")
    is_self_signed = bool(subject_raw and issuer_raw and subject_raw == issuer_raw)

    status, days_remaining = compute_cert_status_and_days(valid_until, 30, 7, "manual", "")

    return {
        "ok": True,
        "common_name": common_name,
        "issuer_cn": issuer_cn,
        "issuer_org": issuer_org,
        "san_domains": san_domains,
        "serial_number": serial_number,
        "fingerprint_sha256": fingerprint_sha256,
        "is_self_signed": is_self_signed,
        "valid_from": valid_from.isoformat() if valid_from else None,
        "valid_until": valid_until.isoformat() if valid_until else None,
        "valid_from_dt": valid_from,
        "valid_until_dt": valid_until,
        "days_remaining": days_remaining,
        "status": status,
    }


def probe_tls_certificate(
    target_host: str,
    port: int = 443,
    sni_hostname: str = "",
    timeout_sec: float = 3.8,
) -> Dict[str, Any]:
    """Conecta por TLS/SSL en vivo a `target_host:port` (aceptando autofirmados/PKI privada) y extrae el certificado X.509."""
    host, clean_port, default_sni = clean_host_and_port(target_host, port or 443)
    if not host:
        return {"ok": False, "error": "Debe indicar un host, dominio o dirección IP para conectar."}

    sni = (sni_hostname or "").strip() or default_sni
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE

    try:
        with socket.create_connection((host, clean_port), timeout=timeout_sec) as raw_sock:
            with ctx.wrap_socket(raw_sock, server_hostname=sni if sni else None) as ssock:
                der_bytes = ssock.getpeercert(binary_form=True)
                tls_version = ssock.version() or ""
                cipher_info = ssock.cipher()
                cipher_suite = cipher_info[0] if cipher_info else ""
    except Exception as exc:
        return {
            "ok": False,
            "target_host": host,
            "port": clean_port,
            "sni_hostname": sni,
            "error": f"No se pudo establecer handshake TLS en {host}:{clean_port} ({exc})",
        }

    if not der_bytes:
        return {
            "ok": False,
            "target_host": host,
            "port": clean_port,
            "sni_hostname": sni,
            "error": f"El servidor {host}:{clean_port} no entregó ningún certificado X.509.",
        }

    pem_text = ssl.DER_cert_to_PEM_cert(der_bytes)
    parsed = parse_pem_certificate(pem_text)
    if not parsed.get("ok"):
        return {
            "ok": False,
            "target_host": host,
            "port": clean_port,
            "sni_hostname": sni,
            "error": parsed.get("error", "Error procesando certificado recibido."),
        }

    parsed["target_host"] = host
    parsed["port"] = clean_port
    parsed["sni_hostname"] = sni
    parsed["tls_version"] = tls_version
    parsed["cipher_suite"] = cipher_suite
    return parsed


def auto_link_certificate_entities(cert: models.TlsCertificate, db: Session) -> None:
    """Vincula automáticamente un certificado con su activo CMDB, RackDevice, FloorDevice y Location si coinciden por ID o IP/Host."""
    host_clean, _, _ = clean_host_and_port(cert.target_host, cert.port)

    # 1. Si no tiene asset_id pero tiene rack_device_id o floor_device_id o host_clean
    if not cert.asset_id and cert.floor_device_id:
        fdev = db.query(models.FloorDevice).filter(models.FloorDevice.id == cert.floor_device_id).first()
        if fdev and fdev.cmdb_asset_id:
            cert.asset_id = fdev.cmdb_asset_id

    if not cert.asset_id and cert.rack_device_id:
        asset_by_rdev = (
            db.query(models.CmdbAsset)
            .filter(models.CmdbAsset.host_rack_device_id == cert.rack_device_id)
            .first()
        )
        if asset_by_rdev:
            cert.asset_id = asset_by_rdev.id

    if not cert.asset_id and host_clean:
        ip_row = (
            db.query(models.CmdbIpAddress)
            .filter(models.CmdbIpAddress.ip_address == host_clean)
            .first()
        )
        if ip_row and ip_row.asset_id:
            cert.asset_id = ip_row.asset_id
        else:
            asset_by_host = (
                db.query(models.CmdbAsset)
                .filter(
                    (models.CmdbAsset.fqdn == host_clean)
                    | (models.CmdbAsset.hostname == host_clean)
                )
                .first()
            )
            if asset_by_host:
                cert.asset_id = asset_by_host.id

    # 2. Si tiene asset_id, propagar vínculos a rack_device_id y floor_device_id si faltan
    if cert.asset_id:
        asset = db.query(models.CmdbAsset).filter(models.CmdbAsset.id == cert.asset_id).first()
        if asset:
            if not cert.rack_device_id and asset.host_rack_device_id:
                cert.rack_device_id = asset.host_rack_device_id
            if not cert.floor_device_id:
                fdev = (
                    db.query(models.FloorDevice)
                    .filter(models.FloorDevice.cmdb_asset_id == asset.id)
                    .first()
                )
                if fdev:
                    cert.floor_device_id = fdev.id

    # 3. Si sigue sin rack_device_id ni floor_device_id, buscar por IP/FQDN directo
    if not cert.rack_device_id and host_clean:
        rdev = (
            db.query(models.RackDevice)
            .filter(
                (models.RackDevice.ip_address == host_clean)
                | (models.RackDevice.fqdn == host_clean)
                | (models.RackDevice.hostname == host_clean)
            )
            .first()
        )
        if rdev:
            cert.rack_device_id = rdev.id

    if not cert.floor_device_id and host_clean:
        fdev = (
            db.query(models.FloorDevice)
            .filter(
                (models.FloorDevice.ip_address == host_clean)
                | (models.FloorDevice.fqdn == host_clean)
            )
            .first()
        )
        if fdev:
            cert.floor_device_id = fdev.id

    # 4. Resolver location_id si no está fijado
    if not cert.location_id:
        if cert.rack_device_id:
            rdev = db.query(models.RackDevice).filter(models.RackDevice.id == cert.rack_device_id).first()
            if rdev and rdev.rack and rdev.rack.room and rdev.rack.room.floor:
                cert.location_id = rdev.rack.room.floor.location_id
        if not cert.location_id and cert.floor_device_id:
            fdev = db.query(models.FloorDevice).filter(models.FloorDevice.id == cert.floor_device_id).first()
            if fdev and fdev.floor:
                cert.location_id = fdev.floor.location_id
        if not cert.location_id and cert.asset_id:
            asset = db.query(models.CmdbAsset).filter(models.CmdbAsset.id == cert.asset_id).first()
            if asset:
                for ip_item in asset.ip_addresses or []:
                    if ip_item.subnet and ip_item.subnet.location_id:
                        cert.location_id = ip_item.subnet.location_id
                        break


def serialize_certificate(
    cert: models.TlsCertificate,
    db: Session,
    contacts_by_id: Dict[int, models.AlertContact],
    groups_by_id: Dict[int, models.AlertContactGroup],
    stack_by_asset_id: Dict[int, List[Dict[str, Any]]],
) -> Dict[str, Any]:
    status, days_remaining = compute_cert_status_and_days(
        cert.valid_until,
        cert.warn_days_before or 30,
        cert.critical_days_before or 7,
        cert.check_mode or "https_live",
        cert.last_probe_error or "",
    )
    # Persist updated status/days in memory
    cert.status = status
    cert.days_remaining = days_remaining

    # Cross-links info
    asset_info = None
    rack_info = None
    floor_info = None
    location_info = None

    if cert.asset:
        asset_info = {
            "id": cert.asset.id,
            "code": cert.asset.code,
            "name": cert.asset.name,
            "hostname": cert.asset.hostname,
            "asset_class": cert.asset.asset_class,
        }

    rdev = cert.rack_device
    if not rdev and cert.asset and cert.asset.host_rack_device:
        rdev = cert.asset.host_rack_device
    if rdev and rdev.rack:
        rack_info = {
            "rack_device_id": rdev.id,
            "rack_device_code": rdev.code,
            "rack_device_name": rdev.name,
            "rack_id": rdev.rack.id,
            "rack_code": rdev.rack.code,
            "rack_name": rdev.rack.name,
            "start_u": rdev.start_u,
            "u_label": f"U{rdev.start_u}",
        }
        if not location_info and rdev.rack.room and rdev.rack.room.floor and rdev.rack.room.floor.location:
            loc = rdev.rack.room.floor.location
            location_info = {
                "id": loc.id,
                "code": loc.code,
                "name": loc.name,
                "label": f"{loc.code} — {loc.name}",
            }

    fdev = cert.floor_device
    if not fdev and cert.asset_id:
        fdev = (
            db.query(models.FloorDevice)
            .filter(models.FloorDevice.cmdb_asset_id == cert.asset_id)
            .first()
        )
    if fdev and fdev.floor:
        floor_info = {
            "floor_device_id": fdev.id,
            "floor_device_code": fdev.code,
            "floor_device_name": fdev.name,
            "device_type": fdev.device_type,
            "floor_id": fdev.floor_id,
            "floor_name": fdev.floor.name,
            "room_code": fdev.room_code,
        }
        if not location_info and fdev.floor.location:
            loc = fdev.floor.location
            location_info = {
                "id": loc.id,
                "code": loc.code,
                "name": loc.name,
                "label": f"{loc.code} — {loc.name}",
            }
        if not rack_info and fdev.linked_rack_id:
            rk = db.query(models.Rack).filter(models.Rack.id == fdev.linked_rack_id).first()
            if rk:
                rack_info = {
                    "rack_device_id": None,
                    "rack_device_code": fdev.linked_rack_device_code or fdev.code,
                    "rack_device_name": fdev.name,
                    "rack_id": rk.id,
                    "rack_code": rk.code,
                    "rack_name": rk.name,
                    "start_u": 1,
                    "u_label": fdev.linked_rack_device_code or rk.code,
                }

    if not location_info and cert.location:
        location_info = {
            "id": cert.location.id,
            "code": cert.location.code,
            "name": cert.location.name,
            "label": f"{cert.location.code} — {cert.location.name}",
        }

    stacks = stack_by_asset_id.get(cert.asset_id or -1, []) if cert.asset_id else []
    primary_stack = stacks[0] if stacks else None

    assigned_groups = []
    for gid in cert.contact_group_ids or []:
        try:
            g = groups_by_id.get(int(gid))
            if g:
                assigned_groups.append({"id": g.id, "code": g.code, "name": g.name, "email": g.group_email})
        except (ValueError, TypeError):
            pass

    assigned_contacts = []
    for cid in cert.contact_ids or []:
        try:
            c = contacts_by_id.get(int(cid))
            if c:
                assigned_contacts.append({"id": c.id, "code": c.code, "full_name": c.full_name, "email": c.email})
        except (ValueError, TypeError):
            pass

    return {
        "id": cert.id,
        "code": cert.code,
        "name": cert.name,
        "check_mode": cert.check_mode or "https_live",
        "target_host": cert.target_host or "",
        "port": cert.port or 443,
        "sni_hostname": cert.sni_hostname or "",
        "environment": cert.environment or "production",
        "common_name": cert.common_name or "",
        "issuer_cn": cert.issuer_cn or "",
        "issuer_org": cert.issuer_org or "",
        "san_domains": cert.san_domains or [],
        "serial_number": cert.serial_number or "",
        "fingerprint_sha256": cert.fingerprint_sha256 or "",
        "tls_version": cert.tls_version or "",
        "cipher_suite": cert.cipher_suite or "",
        "is_self_signed": bool(cert.is_self_signed),
        "valid_from": cert.valid_from.isoformat() if cert.valid_from else None,
        "valid_until": cert.valid_until.isoformat() if cert.valid_until else None,
        "days_remaining": days_remaining,
        "status": status,
        "last_checked_at": cert.last_checked_at.isoformat() if cert.last_checked_at else None,
        "last_probe_error": cert.last_probe_error or "",
        "renewal_type": cert.renewal_type or "manual",
        "warn_days_before": cert.warn_days_before if cert.warn_days_before is not None else 30,
        "critical_days_before": cert.critical_days_before if cert.critical_days_before is not None else 7,
        "auto_probe_enabled": bool(cert.auto_probe_enabled),
        "notify_enabled": bool(cert.notify_enabled),
        "contact_group_ids": cert.contact_group_ids or [],
        "contact_ids": cert.contact_ids or [],
        "assigned_groups": assigned_groups,
        "assigned_contacts": assigned_contacts,
        "notify_emails": cert.notify_emails or "",
        "last_notified_at": cert.last_notified_at.isoformat() if cert.last_notified_at else None,
        "last_notified_severity": cert.last_notified_severity or "",
        "owner_team": cert.owner_team or "Seguridad & Sistemas",
        "responsible_person": cert.responsible_person or "Alex Geng",
        "asset_id": cert.asset_id,
        "rack_device_id": cert.rack_device_id,
        "floor_device_id": cert.floor_device_id,
        "location_id": cert.location_id,
        "asset_info": asset_info,
        "rack_info": rack_info,
        "floor_info": floor_info,
        "location_info": location_info,
        "stack_memberships": stacks,
        "primary_stack_diagram_id": primary_stack["stack_id"] if primary_stack else None,
        "primary_stack_label": f"{primary_stack['stack_code']} ({primary_stack['role_layer']})" if primary_stack else "",
        "renewal_notes": cert.renewal_notes or "",
        "notes": cert.notes or "",
    }


def sync_or_probe_device_certificate(
    db: Session,
    *,
    name: str,
    target_host: str,
    port: int = 443,
    sni_hostname: str = "",
    renewal_type: str = "manual",
    environment: str = "production",
    responsible_person: str = "Alex Geng",
    owner_team: str = "Seguridad & Sistemas",
    asset_id: Optional[int] = None,
    rack_device_id: Optional[int] = None,
    floor_device_id: Optional[int] = None,
    location_id: Optional[int] = None,
    contact_group_ids: Optional[List[int]] = None,
    contact_ids: Optional[List[int]] = None,
    notify_emails: str = "",
) -> Optional[models.TlsCertificate]:
    """Crea o actualiza y verifica en vivo un certificado en CertScope al dar de alta/editar un equipo en Rack, Planta, CMDB o API."""
    host_clean, clean_port, default_sni = clean_host_and_port(target_host, port or 443)
    if not host_clean:
        return None

    existing: Optional[models.TlsCertificate] = None
    if asset_id:
        existing = (
            db.query(models.TlsCertificate)
            .filter(models.TlsCertificate.asset_id == asset_id, models.TlsCertificate.port == clean_port)
            .first()
        )
    if not existing and rack_device_id:
        existing = (
            db.query(models.TlsCertificate)
            .filter(models.TlsCertificate.rack_device_id == rack_device_id, models.TlsCertificate.port == clean_port)
            .first()
        )
    if not existing and floor_device_id:
        existing = (
            db.query(models.TlsCertificate)
            .filter(models.TlsCertificate.floor_device_id == floor_device_id, models.TlsCertificate.port == clean_port)
            .first()
        )
    if not existing:
        existing = (
            db.query(models.TlsCertificate)
            .filter(models.TlsCertificate.target_host == host_clean, models.TlsCertificate.port == clean_port)
            .first()
        )

    if not existing:
        count = db.query(models.TlsCertificate).count() + 1
        code = f"CERT-{count:03d}"
        while db.query(models.TlsCertificate).filter(models.TlsCertificate.code == code).first():
            count += 1
            code = f"CERT-{count:03d}"
        existing = models.TlsCertificate(
            code=code,
            name=name or f"Certificado TLS {host_clean}:{clean_port}",
            check_mode="https_live",
            target_host=host_clean,
            port=clean_port,
            sni_hostname=sni_hostname or default_sni,
            environment=environment or "production",
            renewal_type=renewal_type or "manual",
            owner_team=owner_team or "Seguridad & Sistemas",
            responsible_person=responsible_person or "Alex Geng",
            asset_id=asset_id,
            rack_device_id=rack_device_id,
            floor_device_id=floor_device_id,
            location_id=location_id,
            contact_group_ids=contact_group_ids or [],
            contact_ids=contact_ids or [],
            notify_emails=notify_emails or "",
            created_at=datetime.utcnow(),
        )
        db.add(existing)
    else:
        existing.target_host = host_clean
        existing.port = clean_port
        if sni_hostname:
            existing.sni_hostname = sni_hostname
        if renewal_type:
            existing.renewal_type = renewal_type
        if asset_id:
            existing.asset_id = asset_id
        if rack_device_id:
            existing.rack_device_id = rack_device_id
        if floor_device_id:
            existing.floor_device_id = floor_device_id
        if location_id:
            existing.location_id = location_id
        if contact_group_ids is not None:
            existing.contact_group_ids = contact_group_ids
        if contact_ids is not None:
            existing.contact_ids = contact_ids
        if notify_emails:
            existing.notify_emails = notify_emails

    auto_link_certificate_entities(existing, db)

    # Intentar sondar el certificado HTTPS en vivo
    probe = probe_tls_certificate(host_clean, clean_port, existing.sni_hostname, timeout_sec=2.8)
    existing.last_checked_at = datetime.utcnow()
    if probe.get("ok"):
        existing.common_name = probe.get("common_name") or host_clean
        existing.issuer_cn = probe.get("issuer_cn") or ""
        existing.issuer_org = probe.get("issuer_org") or ""
        existing.san_domains = probe.get("san_domains") or []
        existing.serial_number = probe.get("serial_number") or ""
        existing.fingerprint_sha256 = probe.get("fingerprint_sha256") or ""
        existing.tls_version = probe.get("tls_version") or ""
        existing.cipher_suite = probe.get("cipher_suite") or ""
        existing.is_self_signed = bool(probe.get("is_self_signed"))
        existing.valid_from = probe.get("valid_from_dt")
        existing.valid_until = probe.get("valid_until_dt")
        existing.last_probe_error = ""
        existing.status, existing.days_remaining = compute_cert_status_and_days(
            existing.valid_until,
            existing.warn_days_before or 30,
            existing.critical_days_before or 7,
            existing.check_mode,
            "",
        )
    else:
        existing.last_probe_error = probe.get("error", "Sin respuesta HTTPS/TLS")
        existing.status, existing.days_remaining = compute_cert_status_and_days(
            existing.valid_until,
            existing.warn_days_before or 30,
            existing.critical_days_before or 7,
            existing.check_mode,
            existing.last_probe_error,
        )

    existing.updated_at = datetime.utcnow()
    db.flush()
    return existing


def send_certificate_expiry_notification(
    db: Session,
    cert: models.TlsCertificate,
    custom_message: str = "",
    force_send: bool = False,
) -> Dict[str, Any]:
    """Envía alerta por correo/webhook a las Personas y Grupos asignados al certificado y registra en AlertNotificationLog."""
    status, days_remaining = compute_cert_status_and_days(
        cert.valid_until,
        cert.warn_days_before or 30,
        cert.critical_days_before or 7,
        cert.check_mode,
        cert.last_probe_error or "",
    )
    cert.status = status
    cert.days_remaining = days_remaining

    # Recopilar destinatarios (AlertContact + AlertContactGroup + notify_emails)
    emails_set = set()
    webhooks_set = set()
    recipient_labels: List[str] = []

    if cert.notify_emails:
        for e in cert.notify_emails.split(","):
            if e.strip():
                emails_set.add(e.strip())
                recipient_labels.append(e.strip())

    for cid in cert.contact_ids or []:
        c = db.query(models.AlertContact).filter(models.AlertContact.id == int(cid)).first()
        if c:
            recipient_labels.append(f"{c.full_name} <{c.email}>")
            if c.email:
                emails_set.add(c.email)
            if c.personal_webhook_url:
                webhooks_set.add(c.personal_webhook_url)

    for gid in cert.contact_group_ids or []:
        g = db.query(models.AlertContactGroup).filter(models.AlertContactGroup.id == int(gid)).first()
        if g:
            recipient_labels.append(f"Grupo {g.name}")
            if g.group_email:
                emails_set.add(g.group_email)
            if g.channel_webhook_url:
                webhooks_set.add(g.channel_webhook_url)
            for m_id in g.member_contact_ids or []:
                mc = db.query(models.AlertContact).filter(models.AlertContact.id == int(m_id)).first()
                if mc and mc.email:
                    emails_set.add(mc.email)

    # Si no tiene contactos específicos, buscar cualquier AlertContact activo por defecto
    if not emails_set and not recipient_labels:
        default_contacts = db.query(models.AlertContact).filter(models.AlertContact.active == True).limit(3).all()
        for c in default_contacts:
            if c.email:
                emails_set.add(c.email)
                recipient_labels.append(f"{c.full_name} <{c.email}>")

    severity_map = {
        "expired": "CRITICAL (CADUCADO)",
        "critical": "CRITICAL (<=7 DÍAS)",
        "expiring_soon": "WARNING (PRÓXIMO A CADUCAR)",
        "unreachable": "WARNING (SIN ACCESO TLS)",
        "valid": "INFO (VÁLIDO)",
    }
    sev_label = severity_map.get(status, status.upper())
    exp_str = cert.valid_until.strftime("%Y-%m-%d %H:%M UTC") if cert.valid_until else "Fecha no definida"
    days_str = f"{days_remaining} días" if days_remaining is not None else "N/A"

    subject = f"[RackDoc CertScope] {sev_label} — {cert.name} ({cert.common_name or cert.target_host})"
    body_lines = [
        f"ALERTA DE CERTIFICADO SSL/TLS — RACKDOC CERTSCOPE",
        f"====================================================",
        f"• Certificado: {cert.code} — {cert.name}",
        f"• Common Name (CN): {cert.common_name or 'N/A'}",
        f"• Emisor (CA): {cert.issuer_cn or 'N/A'} ({cert.issuer_org or 'PKI'})",
        f"• Endpoint / Host: {cert.target_host or 'Certificado Manual / Offline'}:{cert.port or 443}",
        f"• Modo de Comprobación: {'Automático HTTPS/TLS' if cert.check_mode == 'https_live' else 'Manual / Registrado a mano'}",
        f"• Tipo de Renovación: {'Manual (Requiere intervención del equipo)' if cert.renewal_type == 'manual' else 'Automática (ACME / PKI)'}",
        f"• Estado Actual: {sev_label}",
        f"• Fecha de Caducidad: {exp_str} ({days_str} restantes)",
        f"• Equipo Responsable: {cert.owner_team} ({cert.responsible_person})",
    ]
    if cert.renewal_notes:
        body_lines.append(f"• Instrucciones de Renovación: {cert.renewal_notes}")
    if custom_message:
        body_lines.append(f"• Nota del Operador: {custom_message}")

    body_text = "\n".join(body_lines)

    smtp_cfg = db.query(models.SmtpAlertConfig).first()
    delivery_status = "logged_simulated"
    error_detail = ""

    # Envío Webhook si hay configurado
    if smtp_cfg and smtp_cfg.global_webhook_url:
        webhooks_set.add(smtp_cfg.global_webhook_url)

    for wh_url in webhooks_set:
        try:
            payload_bytes = json.dumps({"text": f"*{subject}*\n```{body_text}```"}).encode("utf-8")
            req = urllib.request.Request(wh_url, data=payload_bytes, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=3.0):
                delivery_status = "sent_webhook"
        except Exception as exc:
            error_detail = str(exc)

    # Envío SMTP real si está habilitado y no es host dummy
    if smtp_cfg and smtp_cfg.enabled and emails_set and smtp_cfg.smtp_host not in ("", "smtp.empresa.local"):
        try:
            msg = MIMEText(body_text, "plain", "utf-8")
            msg["Subject"] = subject
            msg["From"] = smtp_cfg.from_email or "alertas-rackdoc@empresa.local"
            msg["To"] = ", ".join(sorted(emails_set))
            with smtplib.SMTP(smtp_cfg.smtp_host, smtp_cfg.smtp_port or 587, timeout=4.0) as server:
                if smtp_cfg.use_tls:
                    server.starttls()
                if smtp_cfg.smtp_username and smtp_cfg.smtp_password:
                    server.login(smtp_cfg.smtp_username, smtp_cfg.smtp_password)
                server.sendmail(msg["From"], list(emails_set), msg.as_string())
            delivery_status = "sent_smtp"
        except Exception as exc:
            error_detail = f"SMTP: {exc}"

    recipients_summary = ", ".join(recipient_labels) if recipient_labels else "Equipo de Seguridad & Sistemas"

    log_entry = models.AlertNotificationLog(
        created_at=datetime.utcnow(),
        asset_code=cert.code,
        service_name=f"CertScope SSL/TLS ({cert.common_name or cert.target_host}:{cert.port})",
        event_state="HARD CRITICAL" if status in ("expired", "critical") else f"CERTSCOPE {status.upper()}",
        matched_rule_name=f"CertScope — {cert.name}",
        recipients_summary=recipients_summary,
        delivery_channel="smtp+webhook" if webhooks_set else "smtp",
        delivery_status=delivery_status,
        detail=body_text + (f"\n\n[Detalle transporte: {error_detail}]" if error_detail else ""),
    )
    db.add(log_entry)

    cert.last_notified_at = datetime.utcnow()
    cert.last_notified_severity = status
    db.commit()

    return {
        "ok": True,
        "certificate_id": cert.id,
        "code": cert.code,
        "status": status,
        "days_remaining": days_remaining,
        "recipients": list(emails_set) or recipient_labels,
        "recipients_summary": recipients_summary,
        "delivery_status": delivery_status,
        "subject": subject,
        "message": body_text,
    }


def build_certscope_overview(db: Session) -> Dict[str, Any]:
    certs = db.query(models.TlsCertificate).order_by(models.TlsCertificate.id.asc()).all()
    contacts = db.query(models.AlertContact).order_by(models.AlertContact.full_name.asc()).all()
    groups = db.query(models.AlertContactGroup).order_by(models.AlertContactGroup.name.asc()).all()
    contacts_by_id = {c.id: c for c in contacts}
    groups_by_id = {g.id: g for g in groups}

    # Mapa de pertenencia a Stacks Tecnológicos por asset_id
    stack_by_asset_id: Dict[int, List[Dict[str, Any]]] = {}
    diagrams_by_id = {d.id: d for d in db.query(models.TechStackDiagram).all()}
    all_nodes = db.query(models.TechStackNode).all()
    for sn in all_nodes:
        diag = diagrams_by_id.get(sn.stack_id)
        if diag and sn.asset_id:
            stack_by_asset_id.setdefault(sn.asset_id, []).append(
                {
                    "stack_id": diag.id,
                    "stack_code": diag.code,
                    "stack_name": diag.name,
                    "node_id": sn.id,
                    "role_layer": sn.role_layer,
                }
            )

    serialized_certs = []
    kpi = {
        "total": len(certs),
        "valid": 0,
        "expiring_soon": 0,
        "critical": 0,
        "expired": 0,
        "unreachable": 0,
        "manual_mode": 0,
        "auto_mode": 0,
        "manual_renewal": 0,
        "self_signed": 0,
    }

    for cert in certs:
        auto_link_certificate_entities(cert, db)
        item = serialize_certificate(cert, db, contacts_by_id, groups_by_id, stack_by_asset_id)
        serialized_certs.append(item)

        st = item["status"]
        if st == "valid":
            kpi["valid"] += 1
        elif st == "expiring_soon":
            kpi["expiring_soon"] += 1
        elif st == "critical":
            kpi["critical"] += 1
        elif st == "expired":
            kpi["expired"] += 1
        else:
            kpi["unreachable"] += 1

        if item["check_mode"] == "manual":
            kpi["manual_mode"] += 1
        else:
            kpi["auto_mode"] += 1

        if item["renewal_type"] == "manual":
            kpi["manual_renewal"] += 1
        if item["is_self_signed"]:
            kpi["self_signed"] += 1

    db.commit()

    # Ordenar por urgencia (caducados/críticos primero, luego por días restantes ascendente)
    def _sort_key(c: Dict[str, Any]):
        days = c.get("days_remaining")
        if days is None:
            return (1, 999999)
        return (0, days)

    serialized_certs.sort(key=_sort_key)

    # Catálogos ligeros para los selectores de vinculación y avisos en el modal de alta/edición
    assets_catalog = [
        {
            "id": a.id,
            "code": a.code,
            "name": a.name,
            "hostname": a.hostname,
            "fqdn": a.fqdn,
            "asset_class": a.asset_class,
            "primary_ip": a.ip_addresses[0].ip_address if a.ip_addresses else "",
        }
        for a in db.query(models.CmdbAsset).order_by(models.CmdbAsset.code.asc()).all()
    ]
    rack_devices_catalog = [
        {
            "id": r.id,
            "code": r.code,
            "name": r.name,
            "ip_address": r.ip_address,
            "fqdn": r.fqdn,
            "rack_id": r.rack_id,
            "rack_code": r.rack.code if r.rack else "",
            "start_u": r.start_u,
        }
        for r in db.query(models.RackDevice).order_by(models.RackDevice.code.asc()).all()
    ]
    floor_devices_catalog = [
        {
            "id": f.id,
            "code": f.code,
            "name": f.name,
            "device_type": f.device_type,
            "ip_address": f.ip_address,
            "fqdn": f.fqdn,
            "floor_id": f.floor_id,
            "floor_name": f.floor.name if f.floor else "",
        }
        for f in db.query(models.FloorDevice).order_by(models.FloorDevice.code.asc()).all()
    ]
    locations_catalog = [
        {"id": l.id, "code": l.code, "name": l.name, "label": f"{l.code} — {l.name}"}
        for l in db.query(models.Location).order_by(models.Location.code.asc()).all()
    ]
    contacts_catalog = [
        {"id": c.id, "code": c.code, "full_name": c.full_name, "email": c.email, "role_title": c.role_title}
        for c in contacts
    ]
    groups_catalog = [
        {
            "id": g.id,
            "code": g.code,
            "name": g.name,
            "group_email": g.group_email,
            "member_count": len(g.member_contact_ids or []),
        }
        for g in groups
    ]

    return {
        "kpi": kpi,
        "certificates": serialized_certs,
        "catalogs": {
            "assets": assets_catalog,
            "rack_devices": rack_devices_catalog,
            "floor_devices": floor_devices_catalog,
            "locations": locations_catalog,
            "contacts": contacts_catalog,
            "contact_groups": groups_catalog,
        },
    }


def build_api_onboarding_examples(base_url: str = "http://localhost:8180") -> Dict[str, Any]:
    """Devuelve ejemplos completos y funcionales (cURL, Ansible, Puppet y esquema JSON) para dar de alta dispositivos vía API."""
    clean_base = (base_url or "http://localhost:8180").rstrip("/")
    curl_webhook_example = f"""# ==============================================================================
# OPCIÓN 1 (RECOMENDADA PARA AUTOMATIZACIÓN): WEBHOOK IDEMPOTENTE TODO-EN-UNO
# Endpoint: POST {clean_base}/api/v1/automation/webhook/host-upsert
# Autenticación: Cabecera X-API-Key (o Bearer Token JWT)
# Crea o actualiza en una sola llamada: Activo CMDB + IPs/VLAN/Máscara + Planta/Rack
# + Monitorización ICMP/HTTP + Exporters Prometheus + Accesos SSH/Web + CertScope SSL
# ==============================================================================

curl -X POST "{clean_base}/api/v1/automation/webhook/host-upsert" \\
  -H "Content-Type: application/json" \\
  -H "X-API-Key: rackdoc-ansible-secret-key-2026" \\
  -d '{{
    "code": "SRV-ERP-PROD-01",
    "name": "Servidor ERP Corporativo & API HTTPS",
    "hostname": "srv-erp-prod-01",
    "fqdn": "erp.empresa.local",
    "asset_class": "virtual_machine",
    "environment": "production",
    "criticality": "critical",
    "os_or_firmware": "Ubuntu 24.04.1 LTS (Kernel 6.8)",
    "cpu_cores": 8,
    "ram_gb": 32.0,
    "storage_gb": 500.0,
    "serial_or_uuid": "VMware-42-1a-88-90-bc-ef-001122334455",
    "hosting_mode": "cluster_pool",
    "cluster_or_pool_name": "CLUSTER-PROXMOX-HA-01",
    "hypervisor_or_platform": "Proxmox VE 8.2",
    "owner_team": "Sistemas & Plataforma",
    "responsible_person": "Alex Geng",
    "primary_ip": "192.168.2.50",
    "primary_subnet_mask": "255.255.255.0",
    "primary_gateway": "192.168.2.1",
    "primary_vlan_id": 20,
    "primary_mac_address": "00:50:56:9A:12:50",
    "additional_ips": [
      {{
        "ip_address": "10.20.99.50",
        "subnet_mask": "255.255.255.0",
        "gateway": "10.20.99.1",
        "vlan_id": 99,
        "interface_name": "eth1 (Storage/Backup)",
        "mac_address": "00:50:56:9A:12:51",
        "fqdn": "erp-backup.empresa.local",
        "ip_role": "storage",
        "is_heartbeat_ip": false
      }}
    ],
    "host_groups": ["HG-PROD-ERP", "HG-LINUX-SERVERS"],
    "monitoring_enabled": true,
    "enable_icmp_ping": true,
    "exporters": [
      {{
        "type": "node_exporter",
        "name": "Prometheus Node Exporter",
        "port": 9100
      }}
    ],
    "heartbeats": [
      {{
        "name": "Portal HTTPS ERP",
        "type": "https",
        "url": "https://192.168.2.50:443/health",
        "port": 443
      }}
    ],
    "connect_enabled": true,
    "ssh_enabled": true,
    "ssh_user": "root",
    "ssh_port": 22,
    "web_https_enabled": true,
    "web_https_url": "https://192.168.2.50:443",
    "certscope_enabled": true,
    "certscope_port": 443,
    "certscope_sni": "erp.empresa.local",
    "certscope_renewal_type": "manual",
    "certscope_notify_emails": "seguridad@empresa.local,sistemas@empresa.local",
    "notes": "Dado de alta automáticamente vía API REST (cURL / IaC)"
  }}'"""

    curl_jwt_cmdb_example = f"""# ==============================================================================
# OPCIÓN 2: AUTENTICACIÓN JWT + ALTA DIRECTA EN CMDB Y CERTSCOPE
# Paso 1: Obtener Token Bearer en /api/v1/auth/login
# Paso 2: Crear activo en /api/v1/cmdb/assets (con certscope_enabled=true)
# ==============================================================================

TOKEN=$(curl -s -X POST "{clean_base}/api/v1/auth/login" \\
  -H "Content-Type: application/json" \\
  -d '{{"username": "admin", "password": "admin"}}' | jq -r '.token // .access_token')

curl -X POST "{clean_base}/api/v1/cmdb/assets" \\
  -H "Content-Type: application/json" \\
  -H "Authorization: Bearer $TOKEN" \\
  -d '{{
    "code": "IMP-PLANTA1-01",
    "name": "Impresora Multifunción HP LaserJet Planta 1",
    "hostname": "imp-planta1-01",
    "fqdn": "imp-planta1-01.empresa.local",
    "asset_class": "printer",
    "environment": "production",
    "criticality": "medium",
    "lifecycle_status": "active",
    "os_or_firmware": "HP FutureSmart 5.7",
    "serial_or_uuid": "VNC3K19283",
    "owner_team": "Soporte Microinformática",
    "responsible_person": "Alex Geng",
    "floor_id": 1,
    "floor_device_type": "printer",
    "room_code": "PLANTA-1",
    "monitoring_enabled": true,
    "monitor_method": "icmp",
    "monitor_port": 443,
    "certscope_enabled": true,
    "certscope_port": 443,
    "certscope_renewal_type": "manual",
    "ip_addresses": [
      {{
        "ip_address": "192.168.2.180",
        "subnet_mask": "255.255.255.0",
        "gateway": "192.168.2.1",
        "vlan_id": 20,
        "ip_role": "primary_service",
        "interface_name": "eth0",
        "mac_address": "3C:D9:2B:11:22:33",
        "fqdn": "imp-planta1-01.empresa.local",
        "is_heartbeat_ip": true
      }}
    ],
    "notes": "Impresora sincronizada simultáneamente en CMDB, Datacenter Planta y CertScope"
  }}'"""

    ansible_playbook_example = f"""# ==============================================================================
# PLAYBOOK ANSIBLE: Registro Automático en RackDoc CMDB + Red & Host + CertScope
# Archivo: playbooks/rackdoc_register_host.yml
# Ejecución: ansible-playbook -i inventory.ini playbooks/rackdoc_register_host.yml
# ==============================================================================
---
- name: Registrar o Actualizar Servidor en RackDoc (CMDB + Prometheus + CertScope)
  hosts: all
  gather_facts: true
  vars:
    rackdoc_url: "{clean_base}"
    rackdoc_api_key: "rackdoc-ansible-secret-key-2026"
    enable_https_certscope: true
    https_port: 443

  tasks:
    - name: Enviar inventario completo del nodo a RackDoc API
      ansible.builtin.uri:
        url: "{{{{ rackdoc_url }}}}/api/v1/automation/webhook/host-upsert"
        method: POST
        headers:
          X-API-Key: "{{{{ rackdoc_api_key }}}}"
        body_format: json
        status_code: [200, 201]
        body:
          hostname: "{{{{ ansible_hostname }}}}"
          fqdn: "{{{{ ansible_fqdn | default(ansible_hostname) }}}}"
          name: "{{{{ ansible_hostname }}}} ({{{{ ansible_distribution }}}} {{{{ ansible_distribution_version }}}})"
          asset_class: "{{{{ 'virtual_machine' if ansible_virtualization_role == 'guest' else 'physical_server' }}}}"
          environment: "production"
          criticality: "high"
          os_or_firmware: "{{{{ ansible_distribution }}}} {{{{ ansible_distribution_version }}}} (Kernel {{{{ ansible_kernel }}}})"
          cpu_cores: "{{{{ ansible_processor_vcpus | default(2) | int }}}}"
          ram_gb: "{{{{ (ansible_memtotal_mb / 1024) | round(1) }}}}"
          storage_gb: 100.0
          serial_or_uuid: "{{{{ ansible_product_serial | default(ansible_machine_id) }}}}"
          hypervisor_or_platform: "{{{{ ansible_virtualization_type | default('BareMetal') }}}}"
          primary_ip: "{{{{ ansible_default_ipv4.address }}}}"
          primary_subnet_mask: "{{{{ ansible_default_ipv4.netmask | default('255.255.255.0') }}}}"
          primary_gateway: "{{{{ ansible_default_ipv4.gateway | default('') }}}}"
          primary_mac_address: "{{{{ ansible_default_ipv4.macaddress | default('') }}}}"
          host_groups:
            - "ANSIBLE-MANAGED"
          monitoring_enabled: true
          enable_icmp_ping: true
          exporters:
            - type: "node_exporter"
              port: 9100
          ssh_enabled: true
          ssh_user: "root"
          ssh_port: 22
          certscope_enabled: "{{{{ enable_https_certscope }}}}"
          certscope_port: "{{{{ https_port }}}}"
          certscope_renewal_type: "manual"
          notes: "Registrado automáticamente por Ansible Facts"
      delegate_to: localhost"""

    puppet_manifest_example = f"""# ==============================================================================
# MANIFIESTO PUPPET: Autorregistro de Nodo en RackDoc CMDB + CertScope
# Archivo: manifests/rackdoc_node_onboarding.pp
# Usa hechos nativos de Facter ($facts) para mantener la CMDB siempre al día
# ==============================================================================
class profile::rackdoc_onboarding (
  String  $rackdoc_url     = '{clean_base}',
  String  $rackdoc_api_key = 'rackdoc-ansible-secret-key-2026',
  Boolean $certscope_check = true,
  Integer $certscope_port  = 443,
) {{
  $payload = {{
    hostname               => $facts['networking']['hostname'],
    fqdn                   => $facts['networking']['fqdn'],
    name                   => "${{facts['networking']['hostname']}} (${{facts['os']['name']}} ${{facts['os']['release']['full']}})",
    asset_class            => $facts['is_virtual'] ? {{ true => 'virtual_machine', default => 'physical_server' }},
    environment            => $environment,
    criticality            => 'high',
    os_or_firmware         => "${{facts['os']['name']}} ${{facts['os']['release']['full']}}",
    cpu_cores              => $facts['processors']['count'],
    ram_gb                 => round($facts['memory']['system']['total_bytes'] / 1073741824.0, 1),
    serial_or_uuid         => $facts['dmi']['product']['uuid'],
    primary_ip             => $facts['networking']['ip'],
    primary_subnet_mask    => $facts['networking']['netmask'],
    primary_mac_address    => $facts['networking']['mac'],
    monitoring_enabled     => true,
    enable_icmp_ping       => true,
    certscope_enabled      => $certscope_check,
    certscope_port         => $certscope_port,
    certscope_renewal_type => 'manual',
    notes                  => 'Sincronizado automáticamente por Puppet Agent (Facter)',
  }}

  $json_payload = to_json($payload)

  exec {{ 'register_node_in_rackdoc_cmdb':
    command => "/usr/bin/curl -sS -X POST '${{rackdoc_url}}/api/v1/automation/webhook/host-upsert' -H 'Content-Type: application/json' -H 'X-API-Key: ${{rackdoc_api_key}}' -d '${{json_payload}}'",
    path    => ['/usr/bin', '/bin'],
    timeout => 15,
  }}
}}"""

    return {
        "base_url": clean_base,
        "default_api_key": "rackdoc-ansible-secret-key-2026",
        "markdown_doc_path": "docs/API_ONBOARDING_CURL_ANSIBLE_PUPPET.md",
        "curl_webhook_example": curl_webhook_example,
        "curl_jwt_cmdb_example": curl_jwt_cmdb_example,
        "ansible_playbook_example": ansible_playbook_example,
        "puppet_manifest_example": puppet_manifest_example,
    }
