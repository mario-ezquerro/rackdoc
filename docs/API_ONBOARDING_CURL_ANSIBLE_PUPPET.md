# Guía de Alta y Sincronización Automática de Dispositivos vía API REST (`cURL`, `Ansible`, `Puppet` e IaC)

**RackDoc DCIM & CMDB** expone una API RESTful idempotente (**OpenAPI 3.1.0**) diseñada para que cualquier herramienta de aprovisionamiento o gestión de configuración (**cURL**, **Ansible**, **Puppet**, **Terraform**, **SaltStack** o scripts de CI/CD) pueda dar de alta o actualizar un dispositivo completo en una única llamada HTTP.

Al registrar un equipo mediante la API, RackDoc sincroniza automáticamente su información en todos los módulos de la plataforma:
1. **`6. CMDB & Control IPs`**: Ficha del activo (CI), recursos hardware (`CPU`, `RAM`, `Disco`, `S.O.`, `UUID/Serial`) y tabla multi-IP (`IP`, `Máscara`, `Gateway`, `VLAN`, `MAC`, `FQDN` y flag `Heartbeat`).
2. **`2. Datacenter (Plantas)` y `3. Rack Editor`**: Vinculación con su Rack físico (`host_rack_device_code` / `linked_rack_id`) o su icono en el plano de Planta (`floor_id` / `floor_device_type`).
3. **`4. Red & Host` y `5. Prometheus`**: Alta automática en `HostGroups`, creación de chequeos `ICMP / HTTP / HTTPS / TCP`, registro de `Exporters` (`node_exporter`, `windows_exporter`, etc.) y regeneración en caliente de `targets_dynamic.json` para **Prometheus**.
4. **`7. CertScope (SSL/TLS)`**: Si se activa `"certscope_enabled": true`, el backend conecta en vivo al puerto TLS del equipo (`443`, `8443`, `8006`, etc.), extrae su certificado X.509 (`Common Name`, `Emisor CA`, `SANs`, `Fecha de Caducidad`, `Días Restantes`, `SHA-256`) y programa avisos a las personas o grupos responsables.

---

## 1. Métodos de Autenticación

RackDoc soporta dos mecanismos de autenticación para automatización:

| Método | Cabecera HTTP | Uso recomendado | Valor por defecto en laboratorio |
| :--- | :--- | :--- | :--- |
| **Clave de Automatización (IaC)** | `X-API-Key: <CLAVE>` | **Ansible, Puppet, Terraform, Cron, CI/CD** contra `/api/v1/automation/webhook/*` | `rackdoc-ansible-secret-key-2026` *(configurable vía variable de entorno `AUTOMATION_API_KEY`)* |
| **Token de Sesión JWT** | `Authorization: Bearer <TOKEN>` | Scripts interactivos o llamadas a cualquier endpoint general (`/api/v1/cmdb/*`, `/api/v1/certscope/*`, `/api/v1/racks/*`) | Se obtiene invocando `POST /api/v1/auth/login` |

---

## 2. Ejemplo 1 (`cURL`): Alta Completa Todo-en-Uno con Todos los Campos Posibles

El endpoint **`POST /api/v1/automation/webhook/host-upsert`** es **idempotente**:
- Si el equipo no existe (buscando por `code` o `hostname`), **lo crea**.
- Si ya existe, **actualiza** sus datos, IPs, servicios monitorizados, accesos remotos y certificado SSL/TLS en **CertScope** sin duplicar registros.

```bash
curl -X POST "http://localhost:8180/api/v1/automation/webhook/host-upsert" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: rackdoc-ansible-secret-key-2026" \
  -d '{
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
    "host_rack_device_code": null,
    "parent_asset_code": null,
    "owner_team": "Sistemas & Plataforma",
    "responsible_person": "Alex Geng",
    "primary_ip": "192.168.2.50",
    "primary_subnet_mask": "255.255.255.0",
    "primary_gateway": "192.168.2.1",
    "primary_vlan_id": 20,
    "primary_mac_address": "00:50:56:9A:12:50",
    "additional_ips": [
      {
        "ip_address": "10.20.99.50",
        "subnet_mask": "255.255.255.0",
        "gateway": "10.20.99.1",
        "vlan_id": 99,
        "interface_name": "eth1 (Storage/Backup)",
        "mac_address": "00:50:56:9A:12:51",
        "fqdn": "erp-backup.empresa.local",
        "ip_role": "storage",
        "is_heartbeat_ip": false
      },
      {
        "ip_address": "192.168.2.55",
        "subnet_mask": "255.255.255.0",
        "gateway": "192.168.2.1",
        "vlan_id": 20,
        "interface_name": "eth0:vip",
        "fqdn": "vip-erp.empresa.local",
        "ip_role": "vip_cluster",
        "is_heartbeat_ip": false
      }
    ],
    "host_groups": [
      "HG-PROD-ERP",
      "HG-LINUX-SERVERS"
    ],
    "monitoring_enabled": true,
    "enable_icmp_ping": true,
    "replace_checks": false,
    "exporters": [
      {
        "type": "node_exporter",
        "name": "Prometheus Node Exporter",
        "port": 9100
      }
    ],
    "heartbeats": [
      {
        "name": "Healthcheck API HTTPS",
        "type": "https",
        "url": "https://192.168.2.50:443/health",
        "port": 443,
        "expected_status_code": 200
      }
    ],
    "connect_enabled": true,
    "ssh_enabled": true,
    "ssh_user": "root",
    "ssh_port": 22,
    "ssh_host": "192.168.2.50",
    "web_http_enabled": false,
    "web_https_enabled": true,
    "web_https_url": "https://192.168.2.50:443",
    "certscope_enabled": true,
    "certscope_port": 443,
    "certscope_sni": "erp.empresa.local",
    "certscope_renewal_type": "manual",
    "certscope_contact_group_ids": [],
    "certscope_contact_ids": [],
    "certscope_notify_emails": "seguridad@empresa.local,sistemas@empresa.local",
    "notes": "Dado de alta automáticamente vía API REST (cURL / IaC)"
  }'
```

### Respuesta JSON del Servidor:
```json
{
  "status": "ok",
  "action": "created",
  "asset_id": 14,
  "code": "SRV-ERP-PROD-01",
  "hostname": "srv-erp-prod-01",
  "primary_ip": "192.168.2.50",
  "certscope": {
    "id": 1,
    "code": "CERT-001",
    "status": "valid",
    "days_remaining": 89,
    "common_name": "erp.empresa.local",
    "valid_until": "2027-02-07T23:59:59"
  },
  "prometheus_sd_sync": {
    "targets_written": 5
  }
}
```

---

## 3. Referencia Completa de Campos del Payload

| Campo | Tipo | Valores admitidos / Descripción |
| :--- | :--- | :--- |
| `code` | `string` | Código único en CMDB (ej. `SRV-ERP-PROD-01`). Si se omite, se genera desde `hostname`. |
| `name` | `string` | Nombre descriptivo del servidor, VM o dispositivo. |
| `hostname` | `string` | **(Obligatorio)** Nombre de host de red (`srv-erp-prod-01`). |
| `fqdn` | `string` | Dominio completo (`erp.empresa.local`). |
| `asset_class` | `string` | `virtual_machine`, `physical_server`, `container`, `network_switch`, `router_firewall`, `storage_san_nas`, `printer`, `camera_iot`, `ups_pdu`, `floor_endpoint`, `other_machine`. |
| `environment` | `string` | `production`, `staging`, `development`, `dmz`, `dr_contingency`, `management`. |
| `criticality` | `string` | `mission_critical`, `critical`, `high`, `medium`, `low`. |
| `os_or_firmware` | `string` | Sistema operativo, distribución Linux/Windows o versión de firmware. |
| `cpu_cores` / `ram_gb` / `storage_gb` | `number` | Recursos asignados (vCPUs/Cores, GB de RAM, GB de Almacenamiento). |
| `serial_or_uuid` | `string` | Número de serie físico, Service Tag o UUID de máquina virtual (`dmidecode`). |
| `hosting_mode` | `string` | `cluster_pool` (VM en clúster Proxmox/VMware), `physical_rack_server` (en un servidor concreto del Rack) o `standalone`. |
| `host_rack_device_code` | `string` | Código del equipo físico en `3. Rack Editor` (si está alojado en un servidor de un Rack concreto). |
| `primary_ip` | `string` | **(Obligatorio)** Dirección IPv4 principal de gestión/Heartbeat. |
| `primary_subnet_mask` | `string` | Máscara de subred (ej. `255.255.255.0`). Si la IP cae dentro de un rango registrado en `CMDB -> Subredes`, se vincula automáticamente a su **Sede (`Location`)** y **VLAN**. |
| `primary_gateway` / `primary_vlan_id` / `primary_mac_address` | `mixed` | Puerta de enlace, ID de VLAN (`1..4094`) y dirección MAC (`AA:BB:CC:DD:EE:FF`). |
| `additional_ips` | `array` | Lista de interfaces o IPs secundarias (`ip_address`, `subnet_mask`, `gateway`, `vlan_id`, `interface_name`, `mac_address`, `fqdn`, `ip_role`). |
| `monitoring_enabled` | `boolean` | Activa el Heartbeat automático en background y los chequeos Nagios. |
| `exporters` | `array` | Exporters de Prometheus a registrar (ej. `{"type": "node_exporter", "port": 9100}`). |
| `heartbeats` | `array` | Chequeos adicionales HTTP/HTTPS/TCP/SSH (ej. `{"name": "Web HTTPS", "type": "https", "port": 443}`). |
| `certscope_enabled` | `boolean` | Si es `true`, registra el equipo en **`7. CertScope`** y verifica en vivo su certificado SSL/TLS. |
| `certscope_port` / `certscope_sni` | `int / str` | Puerto TLS (`443`, `8443`, `8006`, `9443`) y nombre SNI opcional para verificar el certificado. |
| `certscope_renewal_type` | `string` | `manual` (envía avisos a personas/grupos antes de caducar) o `auto_acme` (Let's Encrypt / ACME). |
| `certscope_notify_emails` | `string` | Correos separados por comas a notificar cuando el certificado entre en umbral de aviso (`<=30 días`) o crítico (`<=7 días`). |

---

## 4. Ejemplo 2 (`cURL` + Token JWT): Alta Directa de Dispositivo de Planta y CMDB (ej. Impresora / Cámara IP)

Si deseas dar de alta un equipo que además aparezca posicionado en el plano de **`2. Datacenter (Plantas)`** (por ejemplo una impresora de red, punto de acceso Wi-Fi o cámara IP) y verifique su certificado web en **`7. CertScope`**:

```bash
# 1. Obtener Token JWT de sesión
TOKEN=$(curl -s -X POST "http://localhost:8180/api/v1/auth/login" \
  -H "Content-Type: application/json" \
  -d '{"username": "admin", "password": "admin"}' | jq -r '.token // .access_token')

# 2. Dar de alta el activo en CMDB + Planta Datacenter + CertScope SSL
curl -X POST "http://localhost:8180/api/v1/cmdb/assets" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
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
      {
        "ip_address": "192.168.2.180",
        "subnet_mask": "255.255.255.0",
        "gateway": "192.168.2.1",
        "vlan_id": 20,
        "ip_role": "primary_service",
        "interface_name": "eth0",
        "mac_address": "3C:D9:2B:11:22:33",
        "fqdn": "imp-planta1-01.empresa.local",
        "is_heartbeat_ip": true
      }
    ],
    "notes": "Sincronizada en CMDB, Plano de Planta Datacenter y CertScope SSL"
  }'
```

---

## 5. Ejemplo 3 (`Ansible`): Playbook Funcional con `ansible_facts`

Guarda este archivo como `playbooks/rackdoc_register_host.yml` y ejecútalo con `ansible-playbook -i inventory.ini playbooks/rackdoc_register_host.yml`. Extrae automáticamente CPU, RAM, SO, Kernel, UUID, IP, Máscara, Gateway, MAC e interfaces adicionales de cada servidor y los registra en **RackDoc**:

```yaml
---
- name: Autorregistro de Servidores en RackDoc (CMDB + Prometheus + CertScope SSL)
  hosts: all
  gather_facts: true
  vars:
    rackdoc_url: "http://192.168.2.10:8180"
    rackdoc_api_key: "rackdoc-ansible-secret-key-2026"
    enable_https_certscope: true
    https_port: 443

  tasks:
    - name: Publicar ficha completa del servidor en RackDoc API
      ansible.builtin.uri:
        url: "{{ rackdoc_url }}/api/v1/automation/webhook/host-upsert"
        method: POST
        headers:
          X-API-Key: "{{ rackdoc_api_key }}"
        body_format: json
        status_code: [200, 201]
        body:
          hostname: "{{ ansible_hostname }}"
          fqdn: "{{ ansible_fqdn | default(ansible_hostname) }}"
          name: "{{ ansible_hostname }} ({{ ansible_distribution }} {{ ansible_distribution_version }})"
          asset_class: "{{ 'virtual_machine' if ansible_virtualization_role == 'guest' else 'physical_server' }}"
          environment: "production"
          criticality: "high"
          os_or_firmware: "{{ ansible_distribution }} {{ ansible_distribution_version }} (Kernel {{ ansible_kernel }})"
          cpu_cores: "{{ ansible_processor_vcpus | default(2) | int }}"
          ram_gb: "{{ (ansible_memtotal_mb / 1024) | round(1) }}"
          storage_gb: 100.0
          serial_or_uuid: "{{ ansible_product_serial | default(ansible_machine_id) }}"
          hypervisor_or_platform: "{{ ansible_virtualization_type | default('BareMetal') }}"
          primary_ip: "{{ ansible_default_ipv4.address }}"
          primary_subnet_mask: "{{ ansible_default_ipv4.netmask | default('255.255.255.0') }}"
          primary_gateway: "{{ ansible_default_ipv4.gateway | default('') }}"
          primary_mac_address: "{{ ansible_default_ipv4.macaddress | default('') }}"
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
          certscope_enabled: "{{ enable_https_certscope }}"
          certscope_port: "{{ https_port }}"
          certscope_renewal_type: "manual"
          notes: "Inventario sincronizado automáticamente desde Ansible Playbook"
      delegate_to: localhost
```

---

## 6. Ejemplo 4 (`Puppet`): Manifiesto con `Facter` (`$facts`)

En entornos gestionados con **Puppet**, puedes incluir esta clase en tu `site.pp` o rol base para que cada agente mantenga actualizado su inventario en RackDoc:

```puppet
class profile::rackdoc_onboarding (
  String  $rackdoc_url     = 'http://192.168.2.10:8180',
  String  $rackdoc_api_key = 'rackdoc-ansible-secret-key-2026',
  Boolean $certscope_check = true,
  Integer $certscope_port  = 443,
) {
  $payload = {
    hostname               => $facts['networking']['hostname'],
    fqdn                   => $facts['networking']['fqdn'],
    name                   => "${facts['networking']['hostname']} (${facts['os']['name']} ${facts['os']['release']['full']})",
    asset_class            => $facts['is_virtual'] ? { true => 'virtual_machine', default => 'physical_server' },
    environment            => $environment,
    criticality            => 'high',
    os_or_firmware         => "${facts['os']['name']} ${facts['os']['release']['full']}",
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
  }

  $json_payload = to_json($payload)

  exec { 'register_node_in_rackdoc_cmdb':
    command => "/usr/bin/curl -sS -X POST '${rackdoc_url}/api/v1/automation/webhook/host-upsert' -H 'Content-Type: application/json' -H 'X-API-Key: ${rackdoc_api_key}' -d '${json_payload}'",
    path    => ['/usr/bin', '/bin'],
    timeout => 15,
  }
}
```

---

## 7. Ejemplo 5 (`cURL`): Alta de Certificados Manuales u Offline en `7. CertScope`

Para certificados que no están expuestos por HTTPS (certificados VPN IPsec, firmas de código, certificados APNS/ SAML o redes aisladas), puedes registrarlos mediante **`POST /api/v1/certscope/certificates`** indicando su fecha de vencimiento manual (`valid_until`) o pegando el bloque `pem_text`:

```bash
curl -X POST "http://localhost:8180/api/v1/certscope/certificates" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "code": "CERT-VPN-CORP-01",
    "name": "Certificado Raíz VPN IPsec & SAML SSO",
    "check_mode": "manual",
    "target_host": "vpn.empresa.local",
    "port": 443,
    "environment": "production",
    "common_name": "vpn.empresa.local",
    "issuer_cn": "PKI Interna Corporativa CA",
    "issuer_org": "Empresa Corp Security",
    "valid_from": "2026-01-15",
    "valid_until": "2026-12-01",
    "renewal_type": "manual",
    "warn_days_before": 30,
    "critical_days_before": 7,
    "notify_enabled": true,
    "notify_emails": "seguridad@empresa.local,redes@empresa.local",
    "owner_team": "Seguridad & Redes",
    "responsible_person": "Alex Geng",
    "renewal_notes": "Generar CSR en FortiGate Cluster y firmar en servidor AD CS interno antes del vencimiento."
  }'
```

---

## 8. Escenarios Especiales: Apache Tomcat, WildFly / JBoss, WebLogic, WebSphere, STARTTLS y Keystores Java (`JKS` / `PKCS12`)

El motor de auto-verificación de **CertScope** contempla tanto servidores web estándar como servidores de aplicaciones Java, consolas de gestión con TLS antiguo y servicios con negociación `STARTTLS`:

1. **Auto-Descubrimiento Multi-Puerto (`STANDARD_TLS_PORTS_CATALOG`)**:
   - Cuando activas **`3. CertScope`** en una máquina o pulsas **«Auto-Analizar Equipos HTTPS»** (o **«🔍 Escanear Todos los Puertos TLS»**), si el puerto `:443` no responde o hay varios conectores, RackDoc escanea en paralelo:
     - `:443` — HTTPS Estándar / Nginx / Apache / IIS / Balanceadores
     - `:8443` — **Apache Tomcat / WildFly / JBoss EAP / Spring Boot / Jenkins / Nexus**
     - `:9993` — **WildFly / JBoss EAP Management Console** (`management-https`)
     - `:9443` / `:9043` — **IBM WebSphere / OpenLiberty / WSO2 / Portainer**
     - `:7002` — **Oracle WebLogic Server SSL**
     - `:8006` — **Proxmox VE** · `:6443` — **Kubernetes API** · `:9090` — **Cockpit** · `:10000` — **Webmin**
     - `:636` / `:3269` — **LDAPS / Active Directory Global Catalog**
     - `:465` / `:993` — **SMTPS / IMAPS**
     - `:587` (SMTP), `:389` (LDAP), `:5432` (PostgreSQL) — **Negociación `STARTTLS`**
   - Si una misma máquina tiene varios conectores TLS activos (por ejemplo, **WildFly** en `:8443` para la app y `:9993` para administración), **CertScope registra y monitoriza cada puerto como un certificado independiente** vinculado a la misma máquina.
2. **Compatibilidad con Java JSSE (RFC 6066 SNI) y TLS Legacy (`SECLEVEL=0`)**:
   - Los motores Java (`sun.security.ssl` en Tomcat/WildFly/JBoss/WebLogic) rechazan el handshake si se envía una dirección IP literal dentro de la extensión `server_name` (SNI). CertScope detecta automáticamente si el objetivo es una IP y omite el SNI literal (`-noservername`), además de soportar `ALL:@SECLEVEL=0` y renegociación legacy para servidores Java 7/8 o iDRAC/iLO antiguos.
3. **Extracción desde Keystore Java Local (`JKS` / `PKCS12` `.p12`) vía Ansible o `keytool` (cuando el puerto está cerrado al exterior)**:
   - Si un Tomcat o WildFly está en una red aislada sin acceso desde RackDoc, puedes extraer el PEM directamente del `keystore.jks` o `keystore.p12` con `keytool` y enviarlo a `POST /api/v1/certscope/certificates` para que RackDoc calcule automáticamente su `CN`, `CA`, `SHA-256` y fecha de caducidad:

```bash
# Extraer certificado X.509 en formato PEM desde un Keystore JKS/PKCS12 de Tomcat o WildFly y subirlo a CertScope
PEM_CONTENT=$(keytool -exportcert -rfc -keystore /opt/wildfly/standalone/configuration/application.keystore -alias server -storepass changeit)

curl -X POST "http://localhost:8180/api/v1/certscope/certificates" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "$(jq -n \
    --arg code "CERT-WILDFLY-ERP-8443" \
    --arg name "WildFly ERP Keystore (application.keystore :8443)" \
    --arg host "10.20.20.45" \
    --arg pem "$PEM_CONTENT" \
    '{
      code: $code,
      name: $name,
      check_mode: "manual",
      target_host: $host,
      port: 8443,
      pem_text: $pem,
      renewal_type: "manual",
      owner_team: "Middleware & Java Apps",
      responsible_person: "Alex Geng"
    }')"
```
