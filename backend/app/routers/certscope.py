"""Módulo 7: CertScope — Auditoría y Caducidad de Certificados SSL/TLS (Automáticos y Manuales)."""

from datetime import datetime
from typing import Dict, Any
from fastapi import Depends, HTTPException, Request
from sqlalchemy.orm import Session

from .. import models, schemas
from ..database import get_db
from ..routers._common import api_router
from ..services import certscope_service


@api_router.get("/certscope/overview", tags=["CertScope SSL/TLS"])
def get_certscope_overview(db: Session = Depends(get_db)) -> Dict[str, Any]:
    return certscope_service.build_certscope_overview(db)


@api_router.get("/certscope/api-onboarding-guide", tags=["CertScope SSL/TLS"])
def get_api_onboarding_guide(request: Request) -> Dict[str, Any]:
    base_url = str(request.base_url).rstrip("/")
    return certscope_service.build_api_onboarding_examples(base_url)


@api_router.post("/certscope/probe", tags=["CertScope SSL/TLS"])
def probe_certificate_endpoint(
    payload: schemas.TlsCertificateProbeRequest,
) -> Dict[str, Any]:
    if payload.pem_text and payload.pem_text.strip():
        res = certscope_service.parse_pem_certificate(payload.pem_text)
        res.pop("valid_from_dt", None)
        res.pop("valid_until_dt", None)
        return res

    res = certscope_service.probe_tls_certificate(
        target_host=payload.target_host,
        port=payload.port or 443,
        sni_hostname=payload.sni_hostname or "",
        timeout_sec=payload.timeout_sec or 4.0,
    )
    res.pop("valid_from_dt", None)
    res.pop("valid_until_dt", None)
    return res


@api_router.post("/certscope/certificates", tags=["CertScope SSL/TLS"])
def create_certificate(
    payload: schemas.TlsCertificateCreate,
    db: Session = Depends(get_db),
) -> Dict[str, Any]:
    code = (payload.code or "").strip().upper()
    if not code:
        count = db.query(models.TlsCertificate).count() + 1
        code = f"CERT-{count:03d}"
        while db.query(models.TlsCertificate).filter(models.TlsCertificate.code == code).first():
            count += 1
            code = f"CERT-{count:03d}"
    else:
        exists = db.query(models.TlsCertificate).filter(models.TlsCertificate.code == code).first()
        if exists:
            raise HTTPException(status_code=400, detail=f"Ya existe un certificado con el código '{code}'.")

    host_clean, clean_port, default_sni = certscope_service.clean_host_and_port(
        payload.target_host, payload.port or 443
    )

    cert = models.TlsCertificate(
        code=code,
        name=payload.name.strip() or f"Certificado {host_clean or code}",
        check_mode=payload.check_mode or "https_live",
        target_host=host_clean,
        port=clean_port,
        sni_hostname=(payload.sni_hostname or "").strip() or default_sni,
        environment=payload.environment or "production",
        common_name=(payload.common_name or "").strip(),
        issuer_cn=(payload.issuer_cn or "").strip(),
        issuer_org=(payload.issuer_org or "").strip(),
        san_domains=payload.san_domains or [],
        serial_number=(payload.serial_number or "").strip(),
        fingerprint_sha256=(payload.fingerprint_sha256 or "").strip(),
        valid_from=certscope_service.parse_date_flexible(payload.valid_from),
        valid_until=certscope_service.parse_date_flexible(payload.valid_until),
        renewal_type=payload.renewal_type or "manual",
        warn_days_before=payload.warn_days_before if payload.warn_days_before is not None else 30,
        critical_days_before=payload.critical_days_before if payload.critical_days_before is not None else 7,
        auto_probe_enabled=bool(payload.auto_probe_enabled),
        notify_enabled=bool(payload.notify_enabled),
        contact_group_ids=payload.contact_group_ids or [],
        contact_ids=payload.contact_ids or [],
        notify_emails=(payload.notify_emails or "").strip(),
        owner_team=(payload.owner_team or "Seguridad & Sistemas").strip(),
        responsible_person=(payload.responsible_person or "Alex Geng").strip(),
        asset_id=payload.asset_id,
        rack_device_id=payload.rack_device_id,
        floor_device_id=payload.floor_device_id,
        location_id=payload.location_id,
        renewal_notes=payload.renewal_notes or "",
        notes=payload.notes or "",
        created_at=datetime.utcnow(),
        updated_at=datetime.utcnow(),
    )
    db.add(cert)
    certscope_service.auto_link_certificate_entities(cert, db)

    if payload.pem_text and payload.pem_text.strip():
        pem_res = certscope_service.parse_pem_certificate(payload.pem_text)
        if pem_res.get("ok"):
            cert.common_name = pem_res.get("common_name") or cert.common_name
            cert.issuer_cn = pem_res.get("issuer_cn") or cert.issuer_cn
            cert.issuer_org = pem_res.get("issuer_org") or cert.issuer_org
            cert.san_domains = pem_res.get("san_domains") or cert.san_domains
            cert.serial_number = pem_res.get("serial_number") or cert.serial_number
            cert.fingerprint_sha256 = pem_res.get("fingerprint_sha256") or cert.fingerprint_sha256
            cert.is_self_signed = bool(pem_res.get("is_self_signed"))
            cert.valid_from = pem_res.get("valid_from_dt") or cert.valid_from
            cert.valid_until = pem_res.get("valid_until_dt") or cert.valid_until
            cert.last_checked_at = datetime.utcnow()
            cert.last_probe_error = ""
    elif cert.check_mode == "https_live" and cert.target_host:
        probe = certscope_service.probe_tls_certificate(
            cert.target_host, cert.port, cert.sni_hostname, timeout_sec=3.5
        )
        cert.last_checked_at = datetime.utcnow()
        if probe.get("ok"):
            cert.common_name = probe.get("common_name") or cert.common_name or cert.target_host
            cert.issuer_cn = probe.get("issuer_cn") or cert.issuer_cn
            cert.issuer_org = probe.get("issuer_org") or cert.issuer_org
            cert.san_domains = probe.get("san_domains") or cert.san_domains
            cert.serial_number = probe.get("serial_number") or cert.serial_number
            cert.fingerprint_sha256 = probe.get("fingerprint_sha256") or cert.fingerprint_sha256
            cert.tls_version = probe.get("tls_version") or ""
            cert.cipher_suite = probe.get("cipher_suite") or ""
            cert.is_self_signed = bool(probe.get("is_self_signed"))
            cert.valid_from = probe.get("valid_from_dt") or cert.valid_from
            cert.valid_until = probe.get("valid_until_dt") or cert.valid_until
            cert.last_probe_error = ""
        else:
            cert.last_probe_error = probe.get("error", "Sin respuesta HTTPS/TLS")

    cert.status, cert.days_remaining = certscope_service.compute_cert_status_and_days(
        cert.valid_until,
        cert.warn_days_before or 30,
        cert.critical_days_before or 7,
        cert.check_mode,
        cert.last_probe_error or "",
    )
    db.commit()
    return certscope_service.build_certscope_overview(db)


@api_router.put("/certscope/certificates/{cert_id}", tags=["CertScope SSL/TLS"])
def update_certificate(
    cert_id: int,
    payload: schemas.TlsCertificateUpdate,
    db: Session = Depends(get_db),
) -> Dict[str, Any]:
    cert = db.query(models.TlsCertificate).filter(models.TlsCertificate.id == cert_id).first()
    if not cert:
        raise HTTPException(status_code=404, detail="Certificado no encontrado en CertScope.")

    if payload.code is not None and payload.code.strip():
        new_code = payload.code.strip().upper()
        if new_code != cert.code:
            dup = db.query(models.TlsCertificate).filter(models.TlsCertificate.code == new_code).first()
            if dup:
                raise HTTPException(status_code=400, detail=f"El código '{new_code}' ya está en uso.")
            cert.code = new_code

    if payload.name is not None:
        cert.name = payload.name.strip()
    if payload.check_mode is not None:
        cert.check_mode = payload.check_mode
    if payload.target_host is not None or payload.port is not None:
        raw_h = payload.target_host if payload.target_host is not None else cert.target_host
        raw_p = payload.port if payload.port is not None else cert.port
        h_clean, p_clean, def_sni = certscope_service.clean_host_and_port(raw_h, raw_p)
        cert.target_host = h_clean
        cert.port = p_clean
        if not cert.sni_hostname:
            cert.sni_hostname = def_sni
    if payload.sni_hostname is not None:
        cert.sni_hostname = payload.sni_hostname.strip()
    if payload.environment is not None:
        cert.environment = payload.environment
    if payload.common_name is not None:
        cert.common_name = payload.common_name.strip()
    if payload.issuer_cn is not None:
        cert.issuer_cn = payload.issuer_cn.strip()
    if payload.issuer_org is not None:
        cert.issuer_org = payload.issuer_org.strip()
    if payload.san_domains is not None:
        cert.san_domains = payload.san_domains
    if payload.serial_number is not None:
        cert.serial_number = payload.serial_number.strip()
    if payload.fingerprint_sha256 is not None:
        cert.fingerprint_sha256 = payload.fingerprint_sha256.strip()
    if payload.valid_from is not None:
        cert.valid_from = certscope_service.parse_date_flexible(payload.valid_from)
    if payload.valid_until is not None:
        cert.valid_until = certscope_service.parse_date_flexible(payload.valid_until)
    if payload.renewal_type is not None:
        cert.renewal_type = payload.renewal_type
    if payload.warn_days_before is not None:
        cert.warn_days_before = payload.warn_days_before
    if payload.critical_days_before is not None:
        cert.critical_days_before = payload.critical_days_before
    if payload.auto_probe_enabled is not None:
        cert.auto_probe_enabled = payload.auto_probe_enabled
    if payload.notify_enabled is not None:
        cert.notify_enabled = payload.notify_enabled
    if payload.contact_group_ids is not None:
        cert.contact_group_ids = payload.contact_group_ids
    if payload.contact_ids is not None:
        cert.contact_ids = payload.contact_ids
    if payload.notify_emails is not None:
        cert.notify_emails = payload.notify_emails.strip()
    if payload.owner_team is not None:
        cert.owner_team = payload.owner_team.strip()
    if payload.responsible_person is not None:
        cert.responsible_person = payload.responsible_person.strip()

    data_dict = payload.model_dump(exclude_unset=True)
    if "asset_id" in data_dict:
        cert.asset_id = payload.asset_id
    if "rack_device_id" in data_dict:
        cert.rack_device_id = payload.rack_device_id
    if "floor_device_id" in data_dict:
        cert.floor_device_id = payload.floor_device_id
    if "location_id" in data_dict:
        cert.location_id = payload.location_id

    if payload.renewal_notes is not None:
        cert.renewal_notes = payload.renewal_notes
    if payload.notes is not None:
        cert.notes = payload.notes

    if payload.pem_text and payload.pem_text.strip():
        pem_res = certscope_service.parse_pem_certificate(payload.pem_text)
        if pem_res.get("ok"):
            cert.common_name = pem_res.get("common_name") or cert.common_name
            cert.issuer_cn = pem_res.get("issuer_cn") or cert.issuer_cn
            cert.issuer_org = pem_res.get("issuer_org") or cert.issuer_org
            cert.san_domains = pem_res.get("san_domains") or cert.san_domains
            cert.serial_number = pem_res.get("serial_number") or cert.serial_number
            cert.fingerprint_sha256 = pem_res.get("fingerprint_sha256") or cert.fingerprint_sha256
            cert.is_self_signed = bool(pem_res.get("is_self_signed"))
            cert.valid_from = pem_res.get("valid_from_dt") or cert.valid_from
            cert.valid_until = pem_res.get("valid_until_dt") or cert.valid_until
            cert.last_probe_error = ""

    certscope_service.auto_link_certificate_entities(cert, db)
    cert.status, cert.days_remaining = certscope_service.compute_cert_status_and_days(
        cert.valid_until,
        cert.warn_days_before or 30,
        cert.critical_days_before or 7,
        cert.check_mode,
        cert.last_probe_error or "",
    )
    cert.updated_at = datetime.utcnow()
    db.commit()
    return certscope_service.build_certscope_overview(db)


@api_router.delete("/certscope/certificates/{cert_id}", tags=["CertScope SSL/TLS"])
def delete_certificate(
    cert_id: int,
    db: Session = Depends(get_db),
) -> Dict[str, Any]:
    cert = db.query(models.TlsCertificate).filter(models.TlsCertificate.id == cert_id).first()
    if not cert:
        raise HTTPException(status_code=404, detail="Certificado no encontrado.")
    db.delete(cert)
    db.commit()
    return certscope_service.build_certscope_overview(db)


@api_router.post("/certscope/certificates/{cert_id}/verify", tags=["CertScope SSL/TLS"])
def verify_single_certificate(
    cert_id: int,
    db: Session = Depends(get_db),
) -> Dict[str, Any]:
    cert = db.query(models.TlsCertificate).filter(models.TlsCertificate.id == cert_id).first()
    if not cert:
        raise HTTPException(status_code=404, detail="Certificado no encontrado.")

    cert.last_checked_at = datetime.utcnow()
    if cert.check_mode == "https_live" and cert.target_host:
        probe = certscope_service.probe_tls_certificate(
            cert.target_host, cert.port or 443, cert.sni_hostname or "", timeout_sec=3.8
        )
        if probe.get("ok"):
            cert.common_name = probe.get("common_name") or cert.common_name or cert.target_host
            cert.issuer_cn = probe.get("issuer_cn") or cert.issuer_cn
            cert.issuer_org = probe.get("issuer_org") or cert.issuer_org
            cert.san_domains = probe.get("san_domains") or cert.san_domains
            cert.serial_number = probe.get("serial_number") or cert.serial_number
            cert.fingerprint_sha256 = probe.get("fingerprint_sha256") or cert.fingerprint_sha256
            cert.tls_version = probe.get("tls_version") or ""
            cert.cipher_suite = probe.get("cipher_suite") or ""
            cert.is_self_signed = bool(probe.get("is_self_signed"))
            cert.valid_from = probe.get("valid_from_dt") or cert.valid_from
            cert.valid_until = probe.get("valid_until_dt") or cert.valid_until
            cert.last_probe_error = ""
        else:
            cert.last_probe_error = probe.get("error", "Fallo en conexión TLS")

    certscope_service.auto_link_certificate_entities(cert, db)
    cert.status, cert.days_remaining = certscope_service.compute_cert_status_and_days(
        cert.valid_until,
        cert.warn_days_before or 30,
        cert.critical_days_before or 7,
        cert.check_mode,
        cert.last_probe_error or "",
    )
    cert.updated_at = datetime.utcnow()
    db.commit()
    return certscope_service.build_certscope_overview(db)


@api_router.post("/certscope/verify-all", tags=["CertScope SSL/TLS"])
def verify_all_certificates(
    db: Session = Depends(get_db),
) -> Dict[str, Any]:
    disc = certscope_service.auto_discover_https_devices_into_certscope(db, probe_all_active_ips=True)
    certs = db.query(models.TlsCertificate).all()
    probed_count = disc.get("probed_candidates", 0)
    alerts_triggered = 0

    for cert in certs:
        if cert.check_mode == "https_live" and cert.target_host and cert.auto_probe_enabled:
            probed_count += 1
            probe = certscope_service.probe_tls_certificate(
                cert.target_host, cert.port or 443, cert.sni_hostname or "", timeout_sec=2.8
            )
            cert.last_checked_at = datetime.utcnow()
            if probe.get("ok"):
                cert.common_name = probe.get("common_name") or cert.common_name or cert.target_host
                cert.issuer_cn = probe.get("issuer_cn") or cert.issuer_cn
                cert.issuer_org = probe.get("issuer_org") or cert.issuer_org
                cert.san_domains = probe.get("san_domains") or cert.san_domains
                cert.serial_number = probe.get("serial_number") or cert.serial_number
                cert.fingerprint_sha256 = probe.get("fingerprint_sha256") or cert.fingerprint_sha256
                cert.tls_version = probe.get("tls_version") or ""
                cert.cipher_suite = probe.get("cipher_suite") or ""
                cert.is_self_signed = bool(probe.get("is_self_signed"))
                cert.valid_from = probe.get("valid_from_dt") or cert.valid_from
                cert.valid_until = probe.get("valid_until_dt") or cert.valid_until
                cert.last_probe_error = ""
            else:
                cert.last_probe_error = probe.get("error", "Fallo en conexión TLS")

        certscope_service.auto_link_certificate_entities(cert, db)
        cert.status, cert.days_remaining = certscope_service.compute_cert_status_and_days(
            cert.valid_until,
            cert.warn_days_before or 30,
            cert.critical_days_before or 7,
            cert.check_mode,
            cert.last_probe_error or "",
        )
        cert.updated_at = datetime.utcnow()

        if (
            cert.notify_enabled
            and cert.status in ("expiring_soon", "critical", "expired")
            and cert.last_notified_severity != cert.status
        ):
            certscope_service.send_certificate_expiry_notification(db, cert, force_send=False)
            alerts_triggered += 1

    db.commit()
    overview = certscope_service.build_certscope_overview(db)
    overview["last_batch_result"] = {
        "probed_count": probed_count,
        "alerts_triggered": alerts_triggered,
    }
    return overview


@api_router.post("/certscope/certificates/{cert_id}/notify", tags=["CertScope SSL/TLS"])
def notify_certificate_contacts(
    cert_id: int,
    payload: schemas.TlsCertificateNotifyRequest,
    db: Session = Depends(get_db),
) -> Dict[str, Any]:
    cert = db.query(models.TlsCertificate).filter(models.TlsCertificate.id == cert_id).first()
    if not cert:
        raise HTTPException(status_code=404, detail="Certificado no encontrado.")

    return certscope_service.send_certificate_expiry_notification(
        db=db,
        cert=cert,
        custom_message=payload.custom_message or "",
        force_send=payload.force_send,
    )
