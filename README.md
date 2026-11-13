# 🗄️ RackDoc8 — Visual Datacenter, 42U Rack Editor, CMDB Multi-IP, CertScope & SRE Telemetry (DCIM)

**RackDoc8 (`v1.3.1`)** es una plataforma integral de gestión visual de centros de datos (**DCIM**), **CMDB Multi-IP con control anti-colisiones**, **Auditoría de Certificados X.509 (`CertScope`)**, **Topología Lógica / Stack Tecnológico 2D**, **Centro de Operaciones y Alarmas SRE** y **Telemetría Real (Heartbeat + Nagios + SNMP + Prometheus + OpenTelemetry)** desarrollada con **Flutter Web** (Canvas 2D interactivo estilo CAD + selección global de texto), **FastAPI (Python 3.12)**, **SQLAlchemy 2.0 + Alembic**, **SQLite WAL**, **Active Directory / LDAP (`ldap3`)**, **Prometheus TSDB** y **Docker Compose**.

Diseñada para operar sobre **infraestructura real**: las sondas de red, los chequeos de servicio, la negociación TLS, la autenticación LDAP/AD, la exposición Prometheus y el inventario parten siempre de una medida o de un dato introducido, nunca de valores inventados.

> **Antes de nada, revisa [⚠️ Estado de implementación](#️-estado-de-implementación).** Dos capacidades que aparecen en la interfaz están **a medias o sin implementar**: el *walk* SNMP de bocas (`IF-MIB` / `LLDP-MIB`) y la sincronización remota de los conectores que no son SNMP ni exporters de Prometheus (además del envío por webhook en `8. Alarmas SRE`, donde hoy opera SMTP real). Se documentan ahí con exactitud.

---

## 🧭 Los 9 Módulos Principales de RackDoc8

La barra lateral izquierda estructura el flujo completo de extremo a extremo en **9 módulos** más el conmutador unificado de **`Modo Kiosco (Monitor)`**, manteniendo **todos los textos e inspectores seleccionables y copiables (`Ctrl+C` / `Cmd+C`)** sin interferir con el arrastre en los lienzos 2D:

### 1. 📍 `1. Locations (Mapa)` — Mapa Geográfico OpenStreetMap y Planos Personalizados
- Visualización interactiva sobre **OpenStreetMap** sin necesidad de API Keys (*OSM Estándar*, *OSM Claro* y *Topográfico*) con buscador mundial de direcciones y coordenadas (**Nominatim**).
- **Arrastre directo con el ratón (Drag & Drop)** de las Sedes / Datacenters sobre el mapa o sobre planos propios (`JPG`, `PNG`, `GIF`, `WEBP`) con control de zoom y escala.
- Resumen en vivo de plantas, salas, racks y estado Heartbeat (`⚪ Sin monitorizar`, `🟢 Online`, `🟠 Warning`, `🔴 Offline`) por cada sede.

![1. Locations - OpenStreetMap y Planos](docs/screenshots/01_locations_osm.png)

---

### 2. 🏢 `2. Datacenter (Plantas)` — Editor 2D Multi-Planta, Pasillos y Equipos de Planta
- Gestión de edificios con **múltiples plantas** (`Planta 1`, `Planta 2`, etc.) y subida resiliente de planos arquitectónicos en `/app/data/uploads`.
- Posicionamiento y redimensionado 2D de **Pasillos Frío / Caliente**, **Racks** y **Equipos de Planta (`FloorDevice`)** (Cámaras IP, Puntos de Acceso Wi-Fi, Impresoras, SAI/UPS, Sensores IoT y Rosetas de pared).
- **Sincronización bidireccional con CMDB**: permite vincular activos existentes de la CMDB o dar de alta equipos nuevos que se sincronizan automáticamente con su sede correspondiente.

![2. Datacenter - Vista de Planta 2D](docs/screenshots/02_datacenter_floors.png)

---

### 3. 🗄️ `3. Rack Editor (42U)` — Bastidor CAD Front & Back, Cableado y Alineación con CMDB
- **Vista Dual Simultánea (`Front + Back`) o Individual**:
  - Validación automática de **unidades `U` libres consecutivas** al arrastrar equipos con el ratón, historial de deshacer (`Ctrl+Z` / `⌘Z`) y modo mano con barra espaciadora.
  - **Bandejas de Rack 19" (`BDJ`)**: permite alojar hasta 4 mini-equipos (*Routers MikroTik/UniFi, ONTs, Mini-Switches, Mini-PCs/NUCs*) sobre una misma bandeja 1U.
- **Vinculación Directa con Activos Existentes de la CMDB**:
  - Al montar un equipo en una unidad `U`, en una bandeja `BDJ` o como equipo de planta asociado al rack, puedes **seleccionar un activo ya registrado en la CMDB** (mediante el explorador interactivo de activos) para autorrellenar código, hostname, FQDN, IP, modelo y nº de serie sin duplicar registros.
- **Librerías Hardware por Fabricante (`Devices & Librerías`)**:
  - **`Host - HP`**, **`Host - Dell`**, **`Host - Supermicro`**, **`Storage - SAN / NAS`**, **`Network`**, **`Power`**, **`Patching & Passive` (`PATCHBOX` / Patch Panels 24p y 48p)** y **`Bandeja - Equipos Mini`**.
- **Tomas Exteriores Eléctricas (`Schuko 230V`) y de Fibra Óptica (`FIBRA-EXT-1`)** situadas a la derecha del bastidor.
- **Detección Proactiva de Colisiones de IP con la CMDB**: asistente interactivo para **unificar ambos registros en un único activo** o **reasignar la IP**.

![3. Rack Editor 42U - Vista Dual Front & Back, Cableado Punto a Punto y Equipos de Planta](docs/screenshots/03_rack_editor_dual_front_back.png)

![3. Rack Editor 42U - Librerías y Tomas Exteriores](docs/screenshots/03_rack_editor_schuko.png)

---

### 4. 🕸️ `4. Red & Host` — Stack Tecnológico 2D, Topología Lógica, Nagios, SNMP y Prometheus
Cabecera limpia y adaptativa a todo el ancho de ventana, organizada en **5 pestañas operativas**:
1. **`1. Stack Tecnológico (Lógica de Negocio)`**:
   - Lienzo 2D estilo CAD para diseñar múltiples esquemas de servicio (ej. *Portal Ecommerce, ERP, Clúster K8s*), dibujar **zonas delimitadoras**, arrastrar **nodos vinculados a activos CMDB**, trazar **flechas de flujo** y abrir la **ventana técnica flotante** con gráficas Prometheus y acceso SSH.
2. **`2. Topología Lógica & Capas`**:
   - Mapa automático en 5 capas (`Core/Firewall`, `Switches`, `Hipervisores`, `VMs/Contenedores`, `BBDD/Middleware`) y gestión de enlaces lógicos.
3. **`3. Hosts, Servicios & Estados (Nagios)`**:
   - Máquina de estados estilo **Nagios Core (`OK`, `WARNING`, `CRITICAL`, `UNKNOWN` en modo `SOFT`/`HARD`)** sobre 6 transportes reales (`ICMP`, `TCP`, `UDP`, `SSH`, `HTTP/HTTPS` con validación SSL y `SNMP` ASN.1/BER v1/v2c/v3).
4. **`4. Switches SNMP & Conectores`**:
   - Comprobación SNMP real al puerto `161/UDP` (`sysDescr`) y registro de conectores hacia exporters Prometheus. *(Nota: el inventario automático de bocas `IF-MIB`/`LLDP-MIB` no está implementado; ver abajo).*
5. **`5. Telemetría Prometheus & Agentes (OpenTelemetry / Exporters)`**:
   - Integración directa con **`rackdoc-prometheus` (`:9090`)**, descubrimiento dinámico `File SD` (`targets_dynamic.json`), receptor HTTP **OpenTelemetry (`POST /api/v1/otel/v1/metrics`)** y guías descargables en Markdown para instalar agentes en Linux/Windows.

---

### 5. 📊 `5. Dashboard & Excel` — Auditoría Hierro Línea a Línea, Patch Panels Boca a Boca y Excel
- **Hierro Línea a Línea (`U42 -> U1`)**, **Patch Panels Boca a Boca (`1..24` / `1..48`)** y **Sistemas Monitorizados (Heartbeat)**.
- **Importación y Exportación Excel (`.xlsx`)**: plantilla descargable, importación masiva y exportación multicapa completa.

---

### 6. 🗂️ `6. CMDB & Control IPs` — Inventario Estilo Excel, Multi-IP, Locations y Anti-Colisiones
1. **`1. Inventario CMDB & Multi-IP`**: tabla ordenable estilo hoja de cálculo con saltos directos al Rack (`U`) y al Stack Tecnológico, activación de Heartbeat en 1 clic y resolución guiada de colisiones IP.
2. **`2. Verificador Manual de IPs Libres` (*Deep IP Probe* & Escáner CIDR)**: combina *ICMP + TCP Multi-Puerto + ARP/MAC + DNS PTR*.
3. **`3. Subredes, VLANs & Mapa de Red (`.1` a `.254`)**: matriz IPAM interactiva vinculada a Sedes (`1. Locations`).
4. **`4. Árbol Servidor Físico -> VMs`**: jerarquía de virtualización y contenedores sobre cada hipervisor físico.

![6. CMDB & Control IPs - Tabla Inventario Estilo Excel, Multi-IP y Detección de Colisiones](docs/screenshots/06_cmdb_inventario_excel_multi_ip.png)

---

### 7. 🔐 `7. CertScope (SSL/TLS)` — Auditoría, Verificación Automática y Alertas de Caducidad
- **Modo Automático (`https_live` + `STARTTLS`)** y **Modo Manual / PEM (`manual`)** con extracción de `CN`, `CA`, `SANs`, `Serial`, `SHA-256`, versión TLS y días restantes.
- Enlaces directos de salto a Rack, Planta, CMDB y Stack Tecnológico, más avisos por correo y webhook a equipos de guardia.

---

### 8. 🚨 `8. Alarmas SRE` — Estado en Vivo, Navegador de 5 Columnas, SLOs y Automatización
Cabecera adaptativa de ancho completo y **4 pestañas especializadas**:
1. **`1. Estado de Dispositivos & Alarmas en Vivo` (Pestaña Principal)**:
   - Muestra todos los dispositivos priorizados por severidad (`DOWN / CRITICAL` primero), buscador instantáneo y filtros combinables.
   - Indica **desde cuándo está en alarma (`Fecha/Hora` y tiempo transcurrido)**, chequeos fallidos y grupos de guardia asignados.
   - Al final de cada fila incorpora **enlaces directos en 1 clic a todos los dashboards donde participa el activo** (`1. Mapa`, `2. Planta`, `3. Rack`, `4. Red & Host`, `5. Dashboard`, `6. CMDB` y `7. CertScope`).
2. **`2. Avisos de Alarmas, Contactos AD/Local & Matriz de 5 Columnas`**:
   - Navegador interactivo con Drag & Drop y botones de **edición (lápiz) y borrado (papelera)**:
     `1. GRUPOS DE HOSTS` $\rightarrow$ `2. HOSTS DEL GRUPO` $\rightarrow$ `3. GRUPOS DE USUARIOS` $\rightarrow$ `4. MIEMBROS DEL GRUPO` $\leftarrow$ **`5. USUARIOS CONOCIDOS (AD / Locales / Contactos)`**.
   - Configuración directa del **servidor SMTP** para envío real de correos de alarma, ventanas de mantenimiento programadas e historial de entregas.
3. **`3. Objetivos SLO / Error Budgets & Políticas SRE`**.
4. **`4. Automatización Ansible, API REST (`cURL` / `Puppet`) & Manifiesto IA`**.

---

### 9. ⚙️ `9. Administración` — Usuarios Locales, Active Directory / LDAP Real y 4 Roles RBAC
- **Autenticación Local (`bcrypt` + `JWT`)** y **4 roles RBAC** (`admin`, `editor`, `operator`, `viewer`) aplicados globalmente en `/api/v1`.
- **Integración Real con Active Directory / LDAP (`ldap3`)**:
  - Gestión de múltiples controladores de dominio (`ldap://` y `ldaps://`), botón **«Probar Conexión LDAP»** en vivo y explorador real de usuarios del directorio.
  - **Inicio de sesión contra AD/LDAP** (`DOMINIO\usuario`, `usuario@dominio` o `sAMAccountName`) con **Auto-Provisioning Just-In-Time (JIT)**, mapeo automático de grupos `memberOf` a roles RBAC y sincronización automática con los contactos de `8. Alarmas SRE`.

![4. Administración - 4 Roles RBAC y fichas de servidor AD](docs/screenshots/04_admin_rbac_ad.png)

---

## ⚠️ Estado de implementación

RackDoc no inventa medidas: las sondas, los chequeos de servicio, la autenticación LDAP/AD y las métricas que publica salen siempre de una comprobación real o de un dato introducido a mano. Quedan dos áreas parciales/pendientes que conviene conocer:

### 1. Inventario de bocas por SNMP (`IF-MIB` / `LLDP-MIB`) — sin implementar
- **Qué sí hace**: `POST /api/v1/network-hosts/snmp-discover` envía un `GetRequest` SNMP real (ASN.1/BER v1/v2c/v3) al puerto `161/UDP` (`sysDescr`), dando de alta o actualizando el switch en la CMDB.
- **Qué no hace**: no recorre `IF-MIB` ni `LLDP-MIB`; la tabla `switch_snmp_ports` permanece vacía hasta que se implemente el `GetNextRequest`/`GetBulkRequest` iterativo.

### 2. Sincronización de Conectores de Infraestructura y Webhooks en Alarmas SRE — parcial
- **`snmp_switch`** y exporters de **Prometheus (`node_exporter`, `windows_exporter`, `haproxy_stats`)**: operativos y raspados cada 15 s por `rackdoc-prometheus`.
- **Otros conectores (`proxmox_ve`, `vmware_vsphere`, `docker_engine`, `kubernetes`, BBDD)**: actúan hoy como fichas de inventario documental (`last_sync_status = "never"`).
- **Transporte de avisos**: el envío por **correo SMTP es 100% real** tanto en `8. Alarmas SRE` como en `7. CertScope`; los webhooks HTTP están implementados en `7. CertScope` y pendientes de conectar en la ruta de `8. Alarmas SRE`.

---

## 🤖 Guías de Automatización (`cURL`, `Ansible`, `Puppet` y `Prometheus`)
- 👉 **[Guía de Alta Automática vía API REST (`cURL`, `Ansible` y `Puppet`) — `docs/API_ONBOARDING_CURL_ANSIBLE_PUPPET.md`](docs/API_ONBOARDING_CURL_ANSIBLE_PUPPET.md)**
- 👉 **[Guía Maestra de Monitorización Prometheus, Webhooks Ansible y Agentes IA — `docs/AUTOMATION_ANSIBLE_PROMETHEUS_AGENTS.md`](docs/AUTOMATION_ANSIBLE_PROMETHEUS_AGENTS.md)**
- 👉 **[Arquitectura Técnica y Estructura Modular — `ARCHITECTURE.md`](ARCHITECTURE.md)**

---

## 🚀 Despliegue Rápido con Docker Compose

```bash
cp .env.example .env
docker compose up -d --build
```

| Servicio / Contenedor | URL Local | Descripción |
| :--- | :--- | :--- |
| **`rackdoc-frontend`** | [http://localhost:8181](http://localhost:8181) | Interfaz gráfica interactiva **RackDoc8** (Flutter Web + Nginx). |
| **`rackdoc-backend`** | [http://localhost:8180/docs](http://localhost:8180/docs) | API REST **FastAPI (`/api/v1`)**, Swagger UI, ReDoc (`/redoc`) y receptor OTLP. |
| **`rackdoc-prometheus`** | [http://localhost:9090](http://localhost:9090) | Servidor **Prometheus TSDB** integrado con scrape automático cada 15 s. |

---

## 🧪 Calidad de Código y Tests Automatizados

```bash
# 1. Backend: escáner estático de atributos ORM SQLAlchemy + batería pytest aislada
cd backend
.venv/bin/python tools/escaneo_atributos_orm.py
.venv/bin/pytest

# 2. Frontend: análisis estático estricto (0 issues) + tests de widgets y modelos RBAC
cd ../frontend
flutter analyze
flutter test
```

---

## 🏗️ Estructura Modular del Proyecto

```text
rackdoc/
├── .env.example                        # Variables de entorno por defecto
├── VERSION                             # Versión canónica del sistema (1.3.1)
├── docker-compose.yml                  # Orquestación de 3 contenedores (backend :8180, frontend :8181, prometheus :9090)
├── ARCHITECTURE.md                     # Arquitectura técnica detallada, flujo de datos y modelo SQL
├── docs/                               # Guías operativas Ansible/Puppet/cURL/Prometheus y capturas
├── backend/                            # API REST en Python 3.12 + FastAPI + SQLAlchemy 2.0 + Alembic + ldap3
│   ├── alembic/                        # Migraciones versionadas del esquema SQL (31 tablas)
│   ├── tools/escaneo_atributos_orm.py  # Verificador AST estático de columnas y relaciones SQLAlchemy
│   ├── tests/                          # Suite pytest sobre base de datos temporal aislada
│   └── app/
│       ├── main.py                     # Ensamblaje FastAPI, ciclo de vida, CORS y OpenAPI 3.1.0 (/api/v1)
│       ├── database.py                 # Motor SQLite WAL / SQLAlchemy y gestión de sesiones
│       ├── security.py                 # Hashing bcrypt+SHA256, tokens JWT y matriz RBAC de 4 roles
│       ├── models.py                   # 31 modelos ORM SQLAlchemy
│       ├── schemas.py                  # 70 esquemas de validación Pydantic v2
│       ├── routers/                    # 11 routers por dominio (auth/AD, locations, racks, cmdb, network_hosts, certscope, automation, reports...)
│       └── services/                   # Lógica de negocio (cmdb_service, network_host_service, certscope_service, monitor, excel_export)
└── frontend/                           # Aplicación interactiva modular en Flutter Web
    ├── test/widget_test.dart           # Tests de interfaz (Login Gate, SelectionArea) y matriz RBAC
    └── lib/
        ├── main.dart                   # Shell principal, navegación de 9 módulos, Login Gate y Modo Kiosco
        ├── core/                       # Cliente HTTP REST (/api/v1), paleta visual y utilidades Web/IO
        ├── models/                     # Modelos tipados de dominio (datacenter_models.dart)
        ├── shared/widgets/             # Explorador de activos CMDB y exportador vectorial de diagramas
        └── features/
            ├── locations/              # 1. Mapa OpenStreetMap y planos personalizados
            ├── datacenter/             # 2. Planta 2D (dividido en sections/ y widgets/)
            ├── rack_editor/            # 3. Rack Editor 42U Front/Back (dividido en sections/ y widgets/)
            ├── network_hosts/          # 4. Red & Host (dividido en tabs/, sre_alarms/, dialogs/ y widgets/)
            ├── dashboard/              # 5. Dashboard Hierro, Patch Panels y Excel
            ├── cmdb/                   # 6. CMDB Multi-IP, Deep IP Probe e IPAM (dividido en tabs/)
            ├── certscope/              # 7. CertScope auditoría X.509 SSL/TLS
            ├── sre_alarms/             # 8. Alarmas SRE (vista dedicada SreAlarmsView + 5 columnas)
            └── admin/                  # 9. Administración (Usuarios locales, AD/LDAP real y RBAC)
```
