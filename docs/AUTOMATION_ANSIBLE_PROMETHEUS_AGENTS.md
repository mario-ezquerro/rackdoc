# RackDoc — Guía Maestra de Monitorización `4. Red & Host`, Prometheus TSDB, Avisos de Alarmas, Ansible Webhooks y Agentes de IA

> **Repositorio Oficial GitHub:** [https://github.com/mario-ezquerro/rackdoc](https://github.com/mario-ezquerro/rackdoc)  
> **Versión:** `1.3.0`  
> **Dirigido a:** Administradores de Sistemas, Equipos de Redes/DevOps, Playbooks de **Ansible** y **Agentes de IA** (*Antigravity, Claude Code, Cursor, MCP*).

---

## 1. Visión General de la Arquitectura (`3. Rack Editor` ⇄ `4. Red & Host` ⇄ `6. CMDB` ⇄ `Prometheus`)

El módulo **`4. Red & Host`** une en una sola plataforma cuatro mundos tradicionalmente separados:
1. **Topología de Red y Autodescubrimiento SNMP + LLDP** (*inspirado en NetBox y Observium*): interroga Switches y Routers por SNMP (`IF-MIB`, `LLDP-MIB`) descubriendo todas sus bocas, velocidades, VLANs, caudal Rx/Tx y vecinos LLDP sin tener que dar de alta puerto a puerto, sincronizando además las bocas físicas con el equipo en **`3. Rack Editor (42U)`**.
2. **Grafo Lógico en 5 Capas y Virtualización / Contenedores** (*inspirado en Combodo iTop*): relaciona el servidor físico del Rack (`SRV-ESXI-01`, `SRV-PVE-01` o un servidor Barebone externo) con sus Máquinas Virtuales (`VMware`, `Proxmox`, `Hyper-V`, `KVM`), Contenedores (`Docker`, `LXC`, `Kubernetes`), IPs Virtuales (`VIP Keepalived`) y Servicios (`Apache`, `Nginx`, `HAProxy`, `PostgreSQL`, `MySQL`, `Active Directory`). Todo activo e IP termina sincronizado en **`6. CMDB & Control IPs`**.
3. **Máquina de Estados Operativos y Avisos** (*inspirado en Nagios Core*):
   - Estados de Host: `UP`, `DOWN`, `UNREACHABLE` (cuando cae el Switch o Hipervisor padre, suprimiendo cascadas de falsas alarmas en las VMs hijas) y `MAINTENANCE` (durante despliegues de Ansible o ventanas programadas).
   - Estados de Servicio / Heartbeat: `OK`, `WARNING`, `CRITICAL`, `UNKNOWN` con intentos `SOFT (1/3 .. 2/3)` antes de consolidar `HARD (3/3)` y disparar avisos.
4. **Series Temporales en Prometheus (`rackdoc-prometheus`)**:
   - Integrado en `docker-compose.yml` en el puerto `:9090`.
   - Raspea cada `15s` tanto el endpoint nativo de RackDoc (`GET /api/v1/metrics`) como el fichero dinámico de *Service Discovery* (`/app/data/prometheus/targets_dynamic.json` montado en `/etc/prometheus/dynamic/targets_dynamic.json`).

---

## 2. ¿Qué hay que instalar en cada Host y cómo se entera Prometheus automáticamente?

Cada vez que se da de alta o modifica un Host (ya sea desde la interfaz web de **`4. Red & Host`** o mediante un Playbook de **Ansible**), RackDoc regenera al instante el archivo `/app/data/prometheus/targets_dynamic.json`. Prometheus detecta el cambio mediante `file_sd_configs` sin necesidad de reiniciar contenedores.

### 2.1. Servidores Linux (Físicos, VMs o Proxmox) — `node_exporter (:9100)`
```bash
# Ubuntu / Debian / Proxmox VE
sudo apt-get update && sudo apt-get install -y prometheus-node-exporter
sudo systemctl enable --now prometheus-node-exporter

# RHEL / Rocky / AlmaLinux
sudo dnf install -y golang-github-prometheus-node-exporter
sudo systemctl enable --now node_exporter
```

### 2.2. Servidores Windows Server — `windows_exporter (:9182)`
```powershell
# PowerShell (Administrador)
Invoke-WebRequest -Uri "https://github.com/prometheus-community/windows_exporter/releases/latest/download/windows_exporter-0.27.3-amd64.msi" -OutFile C:\windows_exporter.msi
msiexec /i C:\windows_exporter.msi ENABLED_COLLECTORS="cpu,cs,logical_disk,net,os,service,system,memory" LISTEN_PORT=9182 /qn
```

### 2.3. Switches, Routers y Firewalls — `SNMPv2c/v3 (:161/UDP) + LLDP`
```text
! Cisco IOS / Catalyst / Nexus / Aruba
snmp-server community public RO
snmp-server location "CPD Principal RackDoc"
lldp run
```

### 2.4. Apache HTTPd (`mod_status`) y Nginx (`stub_status`)
```nginx
# Nginx (/etc/nginx/conf.d/status.conf)
location /nginx_status {
    stub_status on;
    allow 10.0.0.0/8;
    allow 127.0.0.1;
    deny all;
}
```
```apache
# Apache (/etc/apache2/mods-enabled/status.conf)
ExtendedStatus On
<Location "/server-status">
    SetHandler server-status
    Require ip 10.0.0.0/8 127.0.0.1
</Location>
```

### 2.5. Docker Engine (`:9323/metrics`)
```json
{
  "metrics-addr": "0.0.0.0:9323",
  "experimental": true
}
```

---

## 3. Webhooks de Automatización para Ansible (`X-API-Key`)

Todos los endpoints de automatización aceptan la cabecera:
```http
X-API-Key: rackdoc-ansible-secret-key-2026
Content-Type: application/json
```
*(Configurable mediante la variable de entorno `AUTOMATION_API_KEY` en `docker-compose.yml`).*

### 3.1. Alta o Actualización Idempotente de Host (`POST /api/v1/automation/webhook/host-upsert`)

Crea o actualiza el Host en `4. Red & Host` y en `6. CMDB`, asigna su IP de Heartbeat y sus IPs secundarias/VIPs, lo vincula a su servidor físico en el Rack Editor, lo añade a sus `HostGroups`, crea sus chequeos de servicio y actualiza `targets_dynamic.json` de Prometheus.

```bash
curl -X POST "http://localhost:8180/api/v1/automation/webhook/host-upsert" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: rackdoc-ansible-secret-key-2026" \
  -d '{
    "code": "VM-WEB-ANSIBLE-01",
    "name": "Frontend Nginx Desplegado por Ansible",
    "hostname": "vm-web-ansible-01",
    "fqdn": "vm-web-ansible-01.hq.local",
    "asset_class": "virtual_machine",
    "environment": "production",
    "criticality": "critical",
    "os_or_firmware": "Ubuntu 24.04 LTS",
    "cpu_cores": 4,
    "ram_gb": 16,
    "storage_gb": 120,
    "primary_ip": "10.20.20.145",
    "additional_ips": [
      {"ip_address": "172.16.30.145", "vlan_id": 30, "ip_role": "dmz_public", "interface_name": "eth1"}
    ],
    "host_rack_device_code": "SRV-ESXI-01",
    "host_groups": ["HG-WEB-APACHE-NGINX"],
    "exporters": [
      {"type": "node_exporter", "port": 9100},
      {"type": "nginx", "port": 8080, "url": "http://10.20.20.145:8080/nginx_status"}
    ],
    "heartbeats": [
      {"name": "Portal HTTPS Corporativo", "type": "https", "port": 443, "url": "https://vm-web-ansible-01.hq.local/health"}
    ]
  }'
```

### 3.2. Ventana de Mantenimiento Silenciosa desde Ansible (`POST /api/v1/automation/webhook/maintenance`)

Permite que un Playbook de Ansible ponga un Host o `HostGroup` completo en estado `MAINTENANCE` antes de reiniciar servicios (`action: "start"`) y cierre la ventana al terminar (`action: "stop"`), evitando el envío de correos de falsa alarma durante el mantenimiento.

```yaml
---
- name: Mantenimiento controlado de servidores Web con RackDoc
  hosts: webservers
  pre_tasks:
    - name: Silenciar alarmas en RackDoc antes de actualizar paquetes
      ansible.builtin.uri:
        url: "http://localhost:8180/api/v1/automation/webhook/maintenance"
        method: POST
        headers:
          X-API-Key: "rackdoc-ansible-secret-key-2026"
        body_format: json
        body:
          action: "start"
          title: "Actualización de Nginx y Reinicio Controlado"
          reason: "Playbook Ansible rolling-update"
          duration_minutes: 45
          host_group_code: "HG-WEB-APACHE-NGINX"
      delegate_to: localhost
      run_once: true

  roles:
    - role: nginx_upgrade

  post_tasks:
    - name: Reactivar alarmas en RackDoc tras verificar servicios
      ansible.builtin.uri:
        url: "http://localhost:8180/api/v1/automation/webhook/maintenance"
        method: POST
        headers:
          X-API-Key: "rackdoc-ansible-secret-key-2026"
        body_format: json
        body:
          action: "stop"
          host_group_code: "HG-WEB-APACHE-NGINX"
      delegate_to: localhost
      run_once: true
```

### 3.3. Gestión de Avisos de Alarmas (Personas, Grupos de Personas y Reglas) vía Ansible (`POST /api/v1/automation/webhook/contacts-and-routing`)

Permite mantener como código quién recibe los avisos por correo/webhook para cada grupo de máquinas:

```bash
curl -X POST "http://localhost:8180/api/v1/automation/webhook/contacts-and-routing" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: rackdoc-ansible-secret-key-2026" \
  -d '{
    "contacts": [
      {
        "code": "USR-CARLOS-SRE",
        "full_name": "Carlos Mendoza",
        "role_title": "SRE On-Call Lead",
        "email": "carlos.mendoza@empresa.local",
        "phone_or_telegram": "@cmendoza_sre",
        "schedule_period": "24x7"
      }
    ],
    "contact_groups": [
      {
        "code": "CG-SRE-GUARDIA",
        "name": "Guardia SRE 24x7",
        "group_email": "sre-oncall@empresa.local",
        "member_contact_codes": ["USR-CARLOS-SRE", "USR-ALEX-GENG"]
      }
    ],
    "routing_rules": [
      {
        "name": "Regla Ansible: Servicios Web -> Guardia SRE 24x7",
        "scope_type": "host_group",
        "host_group_code": "HG-WEB-APACHE-NGINX",
        "contact_group_codes": ["CG-SRE-GUARDIA"],
        "contact_codes": ["USR-CARLOS-SRE"],
        "send_email": true,
        "send_webhook": true,
        "only_on_hard_state": true
      }
    ]
  }'
```

### 3.4. Baja de Host (`POST /api/v1/automation/webhook/host-decommission`)

```bash
curl -X POST "http://localhost:8180/api/v1/automation/webhook/host-decommission" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: rackdoc-ansible-secret-key-2026" \
  -d '{
    "code": "VM-WEB-ANSIBLE-01",
    "delete_permanently": false,
    "reason": "Retirado por escalado automático Ansible"
  }'
```

---

## 4. Guía para Agentes de IA (`GET /api/v1/automation/ai-context`)

Cualquier Agente de IA puede consultar en una sola llamada `GET /api/v1/automation/ai-context` para obtener:
- Las métricas exactas exportadas a Prometheus (`rackdoc_host_up`, `rackdoc_host_cpu_usage_percent`, `rackdoc_service_nagios_state`, `rackdoc_switch_port_rx_mbps`, etc.).
- El inventario completo de Hosts, sus estados Nagios (`UP`, `DOWN`, `UNREACHABLE`, `MAINTENANCE`), sus IPs y su ubicación exacta en el Rack físico (`rack_location_badge`).
- Los contratos de los Webhooks de automatización.
