"""
Servicio de auditoría SSL/TLS (`7. CertScope`): sondas TLS/STARTTLS en vivo, parseo X.509 PEM y avisos de caducidad.
"""

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
from ..logging_setup import get_logger
from ..time_utils import utcnow

logger = get_logger(__name__)


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
    """Convierte cadenas de fecha ASN.1/OpenSSL a objetos `datetime` en UTC."""
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
    """Normaliza fechas ISO-8601 o formatos habituales de entrada manual a `datetime` UTC."""
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
    """Extrae un atributo concreto (p. ej. `CN` u `O`) de una tupla Distinguished Name X.509."""
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
    """Calcula el estado operativo (`valid`, `expiring`, `critical`, `expired`, `error`) y días restantes."""
    if valid_until is None:
        if check_mode == "manual":
            return "manual_unverified", None
        return ("unreachable" if probe_error else "unknown"), None

    now = utcnow()
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


# Catálogo de puertos TLS/SSL habituales en entornos empresariales (Web, Tomcat, WildFly, JBoss, WebLogic, WebSphere, Proxmox, K8s, LDAPS, STARTTLS)
STANDARD_TLS_PORTS_CATALOG: List[Dict[str, Any]] = [
    {"port": 443, "service": "HTTPS / Reverse Proxy (Nginx / Apache / IIS / Firewall)", "starttls": ""},
    {"port": 8443, "service": "Apache Tomcat / WildFly / JBoss / Spring Boot HTTPS", "starttls": ""},
    {"port": 9993, "service": "WildFly / JBoss EAP Management Console HTTPS", "starttls": ""},
    {"port": 9443, "service": "IBM WebSphere / OpenLiberty / WSO2 / Portainer HTTPS", "starttls": ""},
    {"port": 9043, "service": "IBM WebSphere Admin Console HTTPS", "starttls": ""},
    {"port": 7002, "service": "Oracle WebLogic Server SSL", "starttls": ""},
    {"port": 8006, "service": "Proxmox VE Web / API HTTPS", "starttls": ""},
    {"port": 6443, "service": "Kubernetes API Server TLS", "starttls": ""},
    {"port": 8444, "service": "Tomcat / App Server HTTPS Secundario", "starttls": ""},
    {"port": 9090, "service": "Cockpit Linux / Prometheus TLS", "starttls": ""},
    {"port": 10000, "service": "Webmin / Virtualmin HTTPS", "starttls": ""},
    {"port": 10443, "service": "FortiGate / VPN SSL Portal HTTPS", "starttls": ""},
    {"port": 636, "service": "LDAPS (Active Directory / OpenLDAP SSL)", "starttls": ""},
    {"port": 3269, "service": "Active Directory Global Catalog LDAPS", "starttls": ""},
    {"port": 465, "service": "SMTPS (Correo Saliente SSL Implícito)", "starttls": ""},
    {"port": 993, "service": "IMAPS (Correo Entrante SSL Implícito)", "starttls": ""},
    {"port": 587, "service": "SMTP Submission (STARTTLS)", "starttls": "smtp"},
    {"port": 389, "service": "LDAP (STARTTLS)", "starttls": "ldap"},
    {"port": 5432, "service": "PostgreSQL Database (STARTTLS)", "starttls": "postgres"},
]

STARTTLS_BY_PORT: Dict[int, str] = {
    25: "smtp",
    587: "smtp",
    143: "imap",
    110: "pop3",
    389: "ldap",
    5432: "postgres",
    3306: "mysql",
    21: "ftp",
}

SERVICE_LABEL_BY_PORT: Dict[int, str] = {
    item["port"]: item["service"] for item in STANDARD_TLS_PORTS_CATALOG
}


def _is_ip_literal(val: str) -> bool:
    """Indica si la cadena corresponde a una dirección IPv4/IPv6 literal (para omitirla como SNI)."""
    import ipaddress
    try:
        ipaddress.ip_address((val or "").strip())
        return True
    except ValueError:
        return False


def _probe_via_openssl_s_client(
    host: str,
    port: int,
    sni: str = "",
    starttls_proto: str = "",
    timeout_sec: float = 4.0,
) -> Dict[str, Any]:
    """
    Sondeo TLS todoterreno mediante `openssl s_client`:
    - Soporta servidores Java antiguos (Tomcat 7/8/9, WildFly, JBoss, WebLogic, WebSphere) con DH pequeño, TLS 1.0/1.1 o renegociación legacy.
    - Soporta protocolos con negociación STARTTLS (SMTP :587/:25, LDAP :389, IMAP :143, PostgreSQL :5432, MySQL :3306).
    - Evita enviar IPs literales como SNI (`-noservername`) para no provocar `SSLHandshakeException` en motores JSSE (Tomcat/WildFly).
    """
    cmd = [
        "openssl",
        "s_client",
        "-connect",
        f"{host}:{port}",
        "-showcerts",
        "-cipher",
        "ALL:@SECLEVEL=0",
    ]
    if sni and not _is_ip_literal(sni):
        cmd.extend(["-servername", sni])
    else:
        cmd.append("-noservername")

    eff_starttls = (starttls_proto or STARTTLS_BY_PORT.get(port, "")).strip().lower()
    if eff_starttls in ("smtp", "imap", "pop3", "ldap", "postgres", "mysql", "ftp"):
        cmd.extend(["-starttls", eff_starttls])

    try:
        proc = subprocess.run(
            cmd,
            input="Q\n",
            text=True,
            capture_output=True,
            timeout=max(2.5, timeout_sec),
        )
    except Exception as exc:
        return {"ok": False, "error": f"Fallo ejecutando openssl s_client en {host}:{port}: {exc}"}

    combined = (proc.stdout or "") + "\n" + (proc.stderr or "")
    m = re.search(
        r"(-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)",
        combined,
        flags=re.DOTALL,
    )
    if not m:
        return {
            "ok": False,
            "error": f"No se obtuvo certificado X.509 en {host}:{port} tras probar TLS directo/legacy/STARTTLS.",
        }

    pem_block = m.group(1)
    parsed = parse_pem_certificate(pem_block)
    if not parsed.get("ok"):
        return parsed

    proto_m = re.search(r"Protocol\s*:\s*([^\s\r\n]+)", combined)
    cipher_m = re.search(r"Cipher\s*(?:is|:)\s*([^\s\r\n]+)", combined)
    parsed["target_host"] = host
    parsed["port"] = port
    parsed["sni_hostname"] = sni if not _is_ip_literal(sni) else ""
    parsed["tls_version"] = proto_m.group(1) if proto_m else "TLS"
    parsed["cipher_suite"] = cipher_m.group(1) if cipher_m else ""
    parsed["detected_service"] = SERVICE_LABEL_BY_PORT.get(port, f"Servicio TLS (:{port})")
    return parsed


def probe_tls_certificate(
    target_host: str,
    port: int = 443,
    sni_hostname: str = "",
    timeout_sec: float = 3.8,
    starttls_protocol: str = "",
) -> Dict[str, Any]:
    """
    Conecta por TLS/SSL en vivo a `target_host:port` y extrae el certificado X.509 contemplando todos los escenarios:
    1. HTTPS / TLS estándar (443, 8443 Tomcat/WildFly, 9993 WildFly Admin, 9443 WebSphere, 7002 WebLogic, 8006 Proxmox, 6443 K8s, 636 LDAPS...).
    2. Servidores Java JSSE (Tomcat / WildFly / JBoss / WebLogic): evita mandar IPs literales en la extensión SNI RFC 6066 (que provoca rechazo en Java) y reintenta sin SNI si fuera necesario.
    3. TLS Legacy (TLS 1.0 / 1.1, claves DH/RSA pequeñas, SHA-1, renegociación legacy `SECLEVEL=0`).
    4. Protocolos STARTTLS (SMTP :587/:25, LDAP :389, IMAP :143, PostgreSQL :5432, MySQL :3306) mediante fallback automático con `openssl s_client`.
    """
    host, clean_port, default_sni = clean_host_and_port(target_host, port or 443)
    if not host:
        return {"ok": False, "error": "Debe indicar un host, dominio o dirección IP para conectar."}

    raw_sni = (sni_hostname or "").strip() or default_sni
    # En Tomcat/WildFly/JBoss (Java JSSE), enviar una IP literal como SNI viola RFC 6066 y puede abortar el handshake
    effective_sni = "" if _is_ip_literal(raw_sni) else raw_sni

    eff_starttls = (starttls_protocol or STARTTLS_BY_PORT.get(clean_port, "")).strip().lower()
    if eff_starttls:
        return _probe_via_openssl_s_client(
            host=host,
            port=clean_port,
            sni=effective_sni,
            starttls_proto=eff_starttls,
            timeout_sec=timeout_sec,
        )

    der_bytes = None
    tls_version = ""
    cipher_suite = ""
    last_exc: Optional[Exception] = None

    # Intento 1: Contexto TLS flexible (con SECLEVEL=0 y OP_LEGACY_SERVER_CONNECT si están disponibles para soportar Tomcat/WildFly antiguos)
    sni_candidates = [effective_sni, ""] if effective_sni else [""]
    for sni_try in sni_candidates:
        for use_legacy_ciphers in (False, True):
            try:
                ctx = ssl.create_default_context()
                ctx.check_hostname = False
                ctx.verify_mode = ssl.CERT_NONE
                if hasattr(ssl, "OP_LEGACY_SERVER_CONNECT"):
                    ctx.options |= getattr(ssl, "OP_LEGACY_SERVER_CONNECT")
                if use_legacy_ciphers:
                    try:
                        ctx.minimum_version = ssl.TLSVersion.MINIMUM_SUPPORTED
                    except (AttributeError, ValueError, ssl.SSLError) as exc:
                        logger.debug("No se pudo ajustar TLSVersion.MINIMUM_SUPPORTED: %s", exc)
                    try:
                        ctx.set_ciphers("ALL:@SECLEVEL=0")
                    except ssl.SSLError as exc:
                        logger.debug("OpenSSL rechazó SECLEVEL=0: %s", exc)
                with socket.create_connection((host, clean_port), timeout=timeout_sec) as raw_sock:
                    with ctx.wrap_socket(
                        raw_sock,
                        server_hostname=sni_try if sni_try else None,
                    ) as ssock:
                        der_bytes = ssock.getpeercert(binary_form=True)
                        tls_version = ssock.version() or ""
                        cipher_info = ssock.cipher()
                        cipher_suite = cipher_info[0] if cipher_info else ""
                if der_bytes:
                    break
            except Exception as exc:
                last_exc = exc
        if der_bytes:
            break

    # Intento 2: Fallback con `openssl s_client` (para handshakes peculiares de Java/WildFly/WebLogic o STARTTLS no estándar)
    if not der_bytes:
        fallback = _probe_via_openssl_s_client(
            host=host,
            port=clean_port,
            sni=effective_sni,
            starttls_proto=eff_starttls,
            timeout_sec=timeout_sec,
        )
        if fallback.get("ok"):
            return fallback
        return {
            "ok": False,
            "target_host": host,
            "port": clean_port,
            "sni_hostname": effective_sni,
            "detected_service": SERVICE_LABEL_BY_PORT.get(clean_port, f"Puerto :{clean_port}"),
            "error": f"No se pudo establecer handshake TLS en {host}:{clean_port} ({last_exc or fallback.get('error', 'sin respuesta')})",
        }

    pem_text = ssl.DER_cert_to_PEM_cert(der_bytes)
    parsed = parse_pem_certificate(pem_text)
    if not parsed.get("ok"):
        return {
            "ok": False,
            "target_host": host,
            "port": clean_port,
            "sni_hostname": effective_sni,
            "error": parsed.get("error", "Error procesando certificado recibido."),
        }

    parsed["target_host"] = host
    parsed["port"] = clean_port
    parsed["sni_hostname"] = effective_sni
    parsed["tls_version"] = tls_version
    parsed["cipher_suite"] = cipher_suite
    parsed["detected_service"] = SERVICE_LABEL_BY_PORT.get(clean_port, f"Servicio TLS (:{clean_port})")
    return parsed


def scan_host_tls_ports(
    target_host: str,
    sni_hostname: str = "",
    extra_ports: Optional[List[int]] = None,
    timeout_sec: float = 1.6,
) -> List[Dict[str, Any]]:
    """
    Escanea en paralelo todos los puertos TLS/SSL habituales de un servidor (443, 8443 Tomcat/WildFly,
    9993 WildFly Admin, 9443 WebSphere/Portainer, 7002 WebLogic, 8006 Proxmox, 6443 K8s, 636 LDAPS, 587 STARTTLS, etc.)
    y devuelve todos los conectores donde se haya encontrado un certificado X.509 activo.
    """
    from concurrent.futures import ThreadPoolExecutor

    host, explicit_port, default_sni = clean_host_and_port(target_host, 443)
    if not host:
        return []

    candidate_ports: List[int] = []
    if explicit_port and explicit_port not in candidate_ports:
        candidate_ports.append(explicit_port)
    for item in STANDARD_TLS_PORTS_CATALOG:
        p = int(item["port"])
        if p not in candidate_ports:
            candidate_ports.append(p)
    for ep in (extra_ports or []):
        try:
            p = int(ep)
            if 1 <= p <= 65535 and p not in candidate_ports:
                candidate_ports.append(p)
        except (TypeError, ValueError) as exc:
            logger.debug("Puerto TLS adicional inválido ignorado (%r): %s", ep, exc)

    def _check_single_port(p: int) -> Optional[Dict[str, Any]]:
        # Primero comprobar rápidamente si el socket TCP abre antes de negociar TLS
        try:
            with socket.create_connection((host, p), timeout=min(1.1, timeout_sec)):
                pass
        except Exception:
            return None
        res = probe_tls_certificate(
            target_host=host,
            port=p,
            sni_hostname=sni_hostname or default_sni,
            timeout_sec=timeout_sec,
        )
        if res.get("ok"):
            return res
        return None

    discovered: List[Dict[str, Any]] = []
    with ThreadPoolExecutor(max_workers=min(12, len(candidate_ports) or 1)) as pool:
        for res in pool.map(_check_single_port, candidate_ports):
            if res is not None:
                discovered.append(res)
    return discovered


def auto_link_certificate_entities(cert: models.TlsCertificate, db: Session) -> None:
    """Vincula automáticamente un certificado con su activo CMDB, RackDevice, FloorDevice y Location si coinciden por ID o IP/Host."""
    host_clean, _, _ = clean_host_and_port(cert.target_host, cert.port)

    # 1. Si no tiene asset_id pero tiene rack_device_id o floor_device_id o host_clean
    # No existe FloorDevice.cmdb_asset_id: la clave ajena vive en
    # cmdb_assets.floor_device_id, así que se busca el activo por su columna,
    # igual que el bloque de abajo hace con el equipo de rack.
    if not cert.asset_id and cert.floor_device_id:
        asset_by_fdev = (
            db.query(models.CmdbAsset)
            .filter(models.CmdbAsset.floor_device_id == cert.floor_device_id)
            .first()
        )
        if asset_by_fdev:
            cert.asset_id = asset_by_fdev.id

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
            # El vínculo va de CmdbAsset hacia FloorDevice (columna
            # cmdb_assets.floor_device_id), no al revés: FloorDevice no tiene
            # cmdb_asset_id. Se lee igual que la línea de arriba para el rack.
            if not cert.floor_device_id and asset.floor_device_id:
                cert.floor_device_id = asset.floor_device_id

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
    """Serializa un registro `TlsCertificate` enriquecido con enlaces cruzados a CMDB, Rack y Planta."""
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
        # Igual que arriba: la columna vive en cmdb_assets.floor_device_id,
        # así que se llega al dispositivo de planta a través del activo.
        fdev = (
            db.query(models.FloorDevice)
            .join(models.CmdbAsset, models.CmdbAsset.floor_device_id == models.FloorDevice.id)
            .filter(models.CmdbAsset.id == cert.asset_id)
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
            created_at=utcnow(),
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
    existing.last_checked_at = utcnow()
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

    existing.updated_at = utcnow()
    db.flush()
    return existing


def extract_https_config_from_custom_fields(
    cf: Optional[Dict[str, Any]],
    default_ip: str = "",
    default_fqdn: str = "",
    monitor_method: str = "",
    monitor_port: int = 443,
) -> Dict[str, Any]:
    """
    Evalúa la 3ª gestión ('certscope_config') o, si aún no fue definida explícitamente,
    auto-detecta si el dispositivo tiene HTTPS activo en 'connect_config' o 'heartbeat_config'.
    """
    custom = dict(cf or {})
    cs_cfg = custom.get("certscope_config")
    conn_cfg = custom.get("connect_config") if isinstance(custom.get("connect_config"), dict) else {}
    hb_cfg = custom.get("heartbeat_config") if isinstance(custom.get("heartbeat_config"), dict) else {}

    # Determinar URL/Host HTTPS candidato desde Conectar o Heartbeat
    conn_https_url = str(conn_cfg.get("https_url") or "").strip()
    hb_http_url = str(hb_cfg.get("http_url") or "").strip()
    candidate_url = ""
    if isinstance(cs_cfg, dict) and str(cs_cfg.get("target_url") or cs_cfg.get("target_host") or "").strip():
        candidate_url = str(cs_cfg.get("target_url") or cs_cfg.get("target_host") or "").strip()
    elif conn_https_url:
        candidate_url = conn_https_url
    elif hb_http_url.lower().startswith("https://"):
        candidate_url = hb_http_url
    elif default_fqdn.strip():
        candidate_url = default_fqdn.strip()
    elif default_ip.strip():
        candidate_url = default_ip.strip()

    host_clean, port_clean, default_sni = clean_host_and_port(
        candidate_url or default_ip or default_fqdn,
        int((cs_cfg or {}).get("port") or (monitor_port if monitor_method == "https" else 443) or 443)
        if isinstance(cs_cfg, dict)
        else (monitor_port if monitor_method == "https" and monitor_port else 443),
    )

    if isinstance(cs_cfg, dict) and "enabled" in cs_cfg:
        enabled = bool(cs_cfg.get("enabled"))
        explicit = True
    else:
        explicit = False
        conn_protos = [
            str(x).lower()
            for x in (conn_cfg.get("protocols") or conn_cfg.get("enabled_systems") or [])
        ]
        hb_protos = [
            str(x).lower()
            for x in (hb_cfg.get("protocols") or hb_cfg.get("enabled_systems") or [])
        ]
        has_conn_https = bool(conn_cfg.get("enabled")) and (
            "https" in conn_protos or bool(conn_cfg.get("https_enabled"))
        )
        has_hb_https = bool(hb_cfg.get("enabled")) and (
            "https" in hb_protos
            or ("http" in hb_protos and hb_http_url.lower().startswith("https://"))
        )
        enabled = bool(
            has_conn_https
            or has_hb_https
            or (str(monitor_method or "").lower() == "https")
        )

    return {
        "enabled": enabled,
        "explicit": explicit,
        "target_host": host_clean,
        "port": port_clean or 443,
        "sni_hostname": str((cs_cfg or {}).get("sni_hostname") or default_fqdn or default_sni or "").strip()
        if isinstance(cs_cfg, dict)
        else (default_fqdn or default_sni or ""),
        "renewal_type": str((cs_cfg or {}).get("renewal_type") or "manual").strip()
        if isinstance(cs_cfg, dict)
        else "manual",
    }


def sync_entity_certscope_from_custom_fields(
    db: Session,
    *,
    rack_device: Optional[models.RackDevice] = None,
    floor_device: Optional[models.FloorDevice] = None,
    cmdb_asset: Optional[models.CmdbAsset] = None,
    explicit_enabled: Optional[bool] = None,
    explicit_port: Optional[int] = None,
    explicit_renewal: Optional[str] = None,
    explicit_sni: Optional[str] = None,
) -> Optional[models.TlsCertificate]:
    """
    Sincroniza la 3ª gestión ('CertScope HTTPS') de cualquier elemento de Rack Editor, Datacenter Planta o CMDB
    con la tabla `certscope_certificates` y actualiza `custom_fields['certscope_config']` con el resumen del certificado.
    """
    # Resolver entidades vinculadas si faltan
    if rack_device and not cmdb_asset:
        cmdb_asset = (
            db.query(models.CmdbAsset)
            .filter(
                (models.CmdbAsset.rack_device_id == rack_device.id)
                | (models.CmdbAsset.host_rack_device_id == rack_device.id)
            )
            .first()
        )
    if floor_device and not cmdb_asset:
        # Antes se intentaba primero floor_device.cmdb_asset_id, que no existe.
        # La consulta buena es esta: el activo apunta al dispositivo de planta.
        cmdb_asset = db.query(models.CmdbAsset).filter(models.CmdbAsset.floor_device_id == floor_device.id).first()
    if cmdb_asset:
        if not rack_device and (cmdb_asset.rack_device_id or cmdb_asset.host_rack_device_id):
            r_id = cmdb_asset.rack_device_id or cmdb_asset.host_rack_device_id
            rack_device = db.query(models.RackDevice).filter(models.RackDevice.id == r_id).first()
        if not floor_device and cmdb_asset.floor_device_id:
            floor_device = db.query(models.FloorDevice).filter(models.FloorDevice.id == cmdb_asset.floor_device_id).first()

    primary_entity = rack_device or floor_device or cmdb_asset
    if not primary_entity:
        return None

    cf = dict(getattr(primary_entity, "custom_fields", None) or {})
    default_ip = ""
    default_fqdn = getattr(primary_entity, "fqdn", "") or ""
    if rack_device and rack_device.ip_address:
        default_ip = rack_device.ip_address
    elif floor_device and floor_device.ip_address:
        default_ip = floor_device.ip_address
    elif cmdb_asset and cmdb_asset.ip_addresses:
        hb_ip = next(
            (ip for ip in cmdb_asset.ip_addresses if ip.is_heartbeat_ip or ip.ip_role == "mgmt_heartbeat"),
            cmdb_asset.ip_addresses[0],
        )
        default_ip = hb_ip.ip_address or ""

    parsed = extract_https_config_from_custom_fields(
        cf,
        default_ip=default_ip,
        default_fqdn=default_fqdn,
        monitor_method=getattr(primary_entity, "monitor_method", "") or "",
        monitor_port=getattr(primary_entity, "monitor_port", 443) or 443,
    )

    enabled = explicit_enabled if explicit_enabled is not None else parsed["enabled"]
    target_host = parsed["target_host"] or default_ip or default_fqdn
    port = explicit_port or parsed["port"] or 443
    renewal_type = explicit_renewal or parsed["renewal_type"] or "manual"
    sni_hostname = explicit_sni if explicit_sni is not None else parsed["sni_hostname"]

    if not enabled:
        # Si fue desactivado explícitamente, desactivar o eliminar certificado automático vinculado
        if explicit_enabled is False or parsed["explicit"]:
            q = db.query(models.TlsCertificate).filter(models.TlsCertificate.check_mode == "https_live")
            conds = []
            if cmdb_asset:
                conds.append(models.TlsCertificate.asset_id == cmdb_asset.id)
            if rack_device:
                conds.append(models.TlsCertificate.rack_device_id == rack_device.id)
            if floor_device:
                conds.append(models.TlsCertificate.floor_device_id == floor_device.id)
            if conds:
                from sqlalchemy import or_
                for c_del in q.filter(or_(*conds)).all():
                    db.delete(c_del)
            cs_Summary = {
                "enabled": False,
                "target_url": f"https://{target_host}:{port}" if target_host else "",
                "port": port,
                "renewal_type": renewal_type,
                "sni_hostname": sni_hostname,
            }
            for ent in (rack_device, floor_device, cmdb_asset):
                if ent is not None:
                    ecf = dict(getattr(ent, "custom_fields", None) or {})
                    ecf["certscope_config"] = cs_Summary
                    ent.custom_fields = ecf
            db.flush()
        return None

    if not target_host:
        return None

    loc_id = None
    if rack_device and rack_device.rack and rack_device.rack.room and rack_device.rack.room.floor:
        loc_id = rack_device.rack.room.floor.location_id
    elif floor_device and floor_device.floor:
        loc_id = floor_device.floor.location_id

    dev_name = getattr(primary_entity, "name", "") or target_host
    svc_label = SERVICE_LABEL_BY_PORT.get(port, "")
    cert_title = (
        f"Certificado TLS {dev_name} ({svc_label.split('(')[0].strip()} :{port})"
        if port != 443 and svc_label
        else f"Certificado TLS {dev_name}"
    )
    cert = sync_or_probe_device_certificate(
        db,
        name=cert_title,
        target_host=target_host,
        port=port,
        sni_hostname=sni_hostname,
        renewal_type=renewal_type,
        environment=getattr(cmdb_asset, "environment", "production") if cmdb_asset else "production",
        responsible_person=getattr(primary_entity, "responsible_person", "Alex Geng") or "Alex Geng",
        owner_team=getattr(cmdb_asset, "owner_team", "Seguridad & Sistemas") if cmdb_asset else "Seguridad & Sistemas",
        asset_id=cmdb_asset.id if cmdb_asset else None,
        rack_device_id=rack_device.id if rack_device else None,
        floor_device_id=floor_device.id if floor_device else None,
        location_id=loc_id,
    )

    # Si el puerto por defecto (:443) no responde (p.ej. es un Tomcat en :8443, un WildFly en :8443/:9993,
    # un WebLogic en :7002, un WebSphere en :9443, un Proxmox en :8006, un K8s en :6443 o LDAPS en :636),
    # auto-escanear todos los puertos TLS estándar del host y registrar cada conector TLS encontrado
    detected_ports_summary: List[Dict[str, Any]] = []
    if cert and cert.status == "unreachable" and explicit_port is None:
        discovered_list = scan_host_tls_ports(target_host, sni_hostname=sni_hostname, timeout_sec=1.5)
        if discovered_list:
            # Eliminar el registro :443 vacío si no era el puerto real y registrar todos los puertos TLS reales encontrados
            if all(int(d.get("port") or 0) != port for d in discovered_list):
                db.delete(cert)
                db.flush()
                cert = None
            for idx, d_item in enumerate(discovered_list):
                d_port = int(d_item.get("port") or 443)
                d_svc = str(d_item.get("detected_service") or f"Puerto :{d_port}")
                c_obj = sync_or_probe_device_certificate(
                    db,
                    name=f"Certificado TLS {dev_name} — {d_svc}",
                    target_host=target_host,
                    port=d_port,
                    sni_hostname=sni_hostname,
                    renewal_type=renewal_type,
                    environment=getattr(cmdb_asset, "environment", "production") if cmdb_asset else "production",
                    responsible_person=getattr(primary_entity, "responsible_person", "Alex Geng") or "Alex Geng",
                    owner_team=getattr(cmdb_asset, "owner_team", "Seguridad & Sistemas") if cmdb_asset else "Seguridad & Sistemas",
                    asset_id=cmdb_asset.id if cmdb_asset else None,
                    rack_device_id=rack_device.id if rack_device else None,
                    floor_device_id=floor_device.id if floor_device else None,
                    location_id=loc_id,
                )
                if c_obj:
                    if idx == 0:
                        cert = c_obj
                    detected_ports_summary.append(
                        {
                            "port": d_port,
                            "service": d_svc,
                            "common_name": c_obj.common_name or "",
                            "days_remaining": c_obj.days_remaining,
                            "status": c_obj.status,
                        }
                    )

    if cert:
        cs_summary = {
            "enabled": True,
            "cert_id": cert.id,
            "cert_code": cert.code,
            "target_url": f"https://{cert.target_host}:{cert.port}",
            "target_host": cert.target_host,
            "port": cert.port,
            "detected_service": SERVICE_LABEL_BY_PORT.get(cert.port, f"TLS :{cert.port}"),
            "detected_ports": detected_ports_summary,
            "sni_hostname": cert.sni_hostname or "",
            "renewal_type": cert.renewal_type or "manual",
            "status": cert.status,
            "days_remaining": cert.days_remaining,
            "common_name": cert.common_name or "",
            "issuer_cn": cert.issuer_cn or "",
            "valid_until": cert.valid_until.isoformat() if cert.valid_until else None,
            "tls_version": cert.tls_version or "",
            "is_self_signed": bool(cert.is_self_signed),
            "last_error": cert.last_probe_error or "",
            "last_checked_at": cert.last_checked_at.isoformat() if cert.last_checked_at else None,
        }
        for ent in (rack_device, floor_device, cmdb_asset):
            if ent is not None:
                ecf = dict(getattr(ent, "custom_fields", None) or {})
                ecf["certscope_config"] = cs_summary
                ent.custom_fields = ecf
        db.flush()
    return cert


def auto_discover_https_devices_into_certscope(
    db: Session,
    probe_all_active_ips: bool = False,
) -> Dict[str, int]:
    """
    Recorre los elementos creados en Rack Editor, Datacenter Planta y CMDB:
    - Si tienen HTTPS/TLS activo (en 'certscope_config', 'connect_config', 'heartbeat_config' o 'MonitoredServiceCheck'),
      los vincula y analiza automáticamente en CertScope (incluyendo múltiples puertos TLS por máquina, ej. :443 + :8443 Tomcat + :9993 WildFly).
    - Si `probe_all_active_ips=True` (botón 'Auto-Analizar Equipos HTTPS'), escanea todos los puertos TLS empresariales
      (`STANDARD_TLS_PORTS_CATALOG`: 443, 8443 Tomcat/WildFly, 9993 WildFly Admin, 9443 WebSphere/Portainer, 7002 WebLogic,
      8006 Proxmox, 6443 K8s, 636 LDAPS, 587 STARTTLS, etc.) en todos los equipos de CMDB/Rack/Planta y registra cada conector TLS encontrado.
    """
    synced_count = 0
    probed_candidates = 0

    # 1. Equipos de Rack Editor
    for rdev in db.query(models.RackDevice).all():
        if rdev.mounted_face == "external":
            continue
        cf = dict(rdev.custom_fields or {})
        cs_cfg = cf.get("certscope_config")
        if isinstance(cs_cfg, dict) and cs_cfg.get("enabled") is False:
            continue
        parsed = extract_https_config_from_custom_fields(
            cf,
            default_ip=rdev.ip_address or "",
            default_fqdn=rdev.fqdn or "",
            monitor_method=rdev.monitor_method or "",
            monitor_port=rdev.monitor_port or 443,
        )
        if parsed["enabled"]:
            existing = (
                db.query(models.TlsCertificate)
                .filter(models.TlsCertificate.rack_device_id == rdev.id)
                .first()
            )
            if not existing or probe_all_active_ips:
                cert = sync_entity_certscope_from_custom_fields(db, rack_device=rdev, explicit_enabled=True)
                if cert:
                    synced_count += 1
        elif probe_all_active_ips and (rdev.ip_address or rdev.fqdn):
            probed_candidates += 1
            host = (rdev.ip_address or rdev.fqdn or "").strip()
            found_ports = scan_host_tls_ports(host, sni_hostname=rdev.fqdn or "", timeout_sec=1.4)
            for fp in found_ports:
                cert = sync_entity_certscope_from_custom_fields(
                    db,
                    rack_device=rdev,
                    explicit_enabled=True,
                    explicit_port=int(fp.get("port") or 443),
                )
                if cert:
                    synced_count += 1

    # 2. Dispositivos de Datacenter Planta
    for fdev in db.query(models.FloorDevice).all():
        cf = dict(fdev.custom_fields or {})
        cs_cfg = cf.get("certscope_config")
        if isinstance(cs_cfg, dict) and cs_cfg.get("enabled") is False:
            continue
        parsed = extract_https_config_from_custom_fields(
            cf,
            default_ip=fdev.ip_address or "",
            default_fqdn=fdev.fqdn or "",
            monitor_method=fdev.monitor_method or "",
            monitor_port=fdev.monitor_port or 443,
        )
        if parsed["enabled"]:
            existing = (
                db.query(models.TlsCertificate)
                .filter(models.TlsCertificate.floor_device_id == fdev.id)
                .first()
            )
            if not existing or probe_all_active_ips:
                cert = sync_entity_certscope_from_custom_fields(db, floor_device=fdev, explicit_enabled=True)
                if cert:
                    synced_count += 1
        elif probe_all_active_ips and (fdev.ip_address or fdev.fqdn):
            probed_candidates += 1
            host = (fdev.ip_address or fdev.fqdn or "").strip()
            found_ports = scan_host_tls_ports(host, sni_hostname=fdev.fqdn or "", timeout_sec=1.4)
            for fp in found_ports:
                cert = sync_entity_certscope_from_custom_fields(
                    db,
                    floor_device=fdev,
                    explicit_enabled=True,
                    explicit_port=int(fp.get("port") or 443),
                )
                if cert:
                    synced_count += 1

    # 3. Máquinas y Activos en CMDB y Red & Host (incluyendo TODOS los chequeos HTTPS/TLS de Nagios por máquina)
    https_checks_by_asset: Dict[int, List[models.MonitoredServiceCheck]] = {}
    for chk in db.query(models.MonitoredServiceCheck).filter(models.MonitoredServiceCheck.enabled == True).all():
        chk_port = int(chk.port or 0)
        is_tls_chk = (
            chk.check_type == "https"
            or str(chk.target_ip_or_url or "").lower().startswith("https://")
            or chk_port in (443, 8443, 9993, 9443, 9043, 7002, 8006, 6443, 636, 3269, 465, 993)
        )
        if is_tls_chk:
            https_checks_by_asset.setdefault(chk.asset_id, []).append(chk)

    for asset in db.query(models.CmdbAsset).all():
        cf = dict(asset.custom_fields or {})
        cs_cfg = cf.get("certscope_config")
        if isinstance(cs_cfg, dict) and cs_cfg.get("enabled") is False:
            continue
        hb_ip = next(
            (ip.ip_address for ip in (asset.ip_addresses or []) if ip.is_heartbeat_ip or ip.ip_role == "mgmt_heartbeat"),
            asset.ip_addresses[0].ip_address if asset.ip_addresses else "",
        )
        parsed = extract_https_config_from_custom_fields(
            cf,
            default_ip=hb_ip or "",
            default_fqdn=asset.fqdn or "",
            monitor_method=asset.monitor_method or "",
            monitor_port=asset.monitor_port or 443,
        )
        asset_tls_checks = https_checks_by_asset.get(asset.id, [])
        if parsed["enabled"] or asset_tls_checks:
            existing = (
                db.query(models.TlsCertificate)
                .filter(models.TlsCertificate.asset_id == asset.id)
                .first()
            )
            if not existing or probe_all_active_ips:
                ports_to_sync: List[int] = []
                if parsed["enabled"] and parsed["port"]:
                    ports_to_sync.append(int(parsed["port"]))
                for chk in asset_tls_checks:
                    p = int(chk.port or 443)
                    if p not in ports_to_sync:
                        ports_to_sync.append(p)
                if not ports_to_sync:
                    ports_to_sync.append(443)
                for p in ports_to_sync:
                    cert = sync_entity_certscope_from_custom_fields(
                        db,
                        cmdb_asset=asset,
                        explicit_enabled=True,
                        explicit_port=p,
                    )
                    if cert:
                        synced_count += 1
        elif probe_all_active_ips and (hb_ip or asset.fqdn):
            probed_candidates += 1
            host = (hb_ip or asset.fqdn or "").strip()
            found_ports = scan_host_tls_ports(host, sni_hostname=asset.fqdn or "", timeout_sec=1.4)
            for fp in found_ports:
                cert = sync_entity_certscope_from_custom_fields(
                    db,
                    cmdb_asset=asset,
                    explicit_enabled=True,
                    explicit_port=int(fp.get("port") or 443),
                )
                if cert:
                    synced_count += 1

    db.commit()
    return {"synced_count": synced_count, "probed_candidates": probed_candidates}


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
    # Sin intento de envío todavía: el aviso queda registrado y nadie lo recibe.
    # Si algún transporte se intenta y falla, el estado pasa a "error", no se queda
    # en un valor que se lea como éxito parcial.
    delivery_status = "not_configured"
    intento_de_envio = False
    error_detail = ""

    # Envío Webhook si hay configurado
    if smtp_cfg and smtp_cfg.global_webhook_url:
        webhooks_set.add(smtp_cfg.global_webhook_url)

    for wh_url in webhooks_set:
        intento_de_envio = True
        try:
            payload_bytes = json.dumps({"text": f"*{subject}*\n```{body_text}```"}).encode("utf-8")
            req = urllib.request.Request(wh_url, data=payload_bytes, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=3.0):
                delivery_status = "sent_webhook"
        except Exception as exc:
            error_detail = str(exc)
            logger.warning("Falló el webhook de CertScope para %s.", cert.code, exc_info=True)

    # Envío SMTP real si está habilitado y no es host dummy
    if smtp_cfg and smtp_cfg.enabled and emails_set and smtp_cfg.smtp_host not in ("", "smtp.empresa.local"):
        intento_de_envio = True
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
            logger.error(
                "No se pudo enviar por SMTP el aviso de CertScope para %s a %s.",
                cert.code, ", ".join(sorted(emails_set)), exc_info=True,
            )

    # Se intentó enviar por algún transporte y ninguno lo consiguió: es un fallo de
    # entrega, no un aviso "registrado y listo".
    if intento_de_envio and delivery_status == "not_configured":
        delivery_status = "error"

    recipients_summary = ", ".join(recipient_labels) if recipient_labels else "Equipo de Seguridad & Sistemas"

    log_entry = models.AlertNotificationLog(
        created_at=utcnow(),
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

    cert.last_notified_at = utcnow()
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
    """Construye el resumen global, KPIs y listado completo de certificados para `7. CertScope`."""
    auto_discover_https_devices_into_certscope(db, probe_all_active_ips=False)
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
