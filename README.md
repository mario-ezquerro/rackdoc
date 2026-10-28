# 🗄️ RackDoc8 — Visual Datacenter & 42U Rack Infrastructure Manager (DCIM)

**RackDoc8** es una plataforma visual de gestión, monitorización y documentación de centros de datos (**DCIM**) desarrollada con **Flutter Web** (Canvas 2D interactivo estilo CAD), **FastAPI (Python)**, **SQLite** y **Docker Compose**.

Permite gestionar visualmente desde la ubicación geográfica de los Datacenters en **OpenStreetMap** o planos personalizados, pasando por las **distintas plantas 2D del edificio**, hasta el **Rack Editor 42U** con vista **Front & Back**, validación de **unidades U libres al arrastrar equipos**, librerías ampliadas (**HP ProLiant**, **Dell PowerEdge**, **Supermicro**, **Network**, **Power**), **tomas eléctricas Schuko exteriores** y **tomas exteriores de fibra óptica con número de conectores ajustable**, monitorización **Heartbeat multi-método** (ICMP, SSH, HTTPS/SSL, HTTP, TCP, SNMP), **importación y exportación Excel (`.xlsx`) con plantilla de ejemplo descargable**, y control de acceso basado en **4 roles (RBAC)** con soporte **Multi-Active Directory (LDAP/LDAPS)** por usuarios y grupos.

---

## ✨ Novedades Principales de RackDoc8

- **🎨 Identidad Visual RackDoc8**: Logo y favicon personalizado de **RackDoc8** en la pestaña del navegador (`favicon.svg` / `favicon.png`) y en toda la interfaz.
- **🔆 Tomas Exteriores de Fibra Óptica con Conectores Ajustables (`FIBRA-EXT-1`)**:
  - Además de las tomas eléctricas exteriores Schuko (`TOMA-A`, `TOMA-B`), cada rack cuenta con **Tomas Exteriores de Fibra Óptica** (`FIBRA-EXT-1`, conectores ópticos `FO1..FON` LC/SC).
  - Permite **ajustar en vivo el número de conectores de fibra (`1..48`)** tanto desde los botones rápidos `[-]` / `[+]` de la tarjeta exterior como desde el diálogo de edición (con presets `4x`, `6x`, `8x`, `12x`, `16x`, `24x FO`) y elegir el color estándar de la acometida óptica (`#0284C7` Aqua OM4, `#F59E0B` Amarillo OS2, `#10B981` Verde APC, `#7C3AED` Violeta OM5).
- **⚡ Regletas Schuko 1U con Conector Macho de Entrada (`MACHO-IN1`)**:
  - Las regletas `Power Strip 1U (8x Schuko)` incluyen8 tomas hembra (`SCH1..SCH8`) para alimentar los equipos del rack y **1 conector macho de entrada (`MACHO-IN1` — `power_schuko_male`)** para enchufar la regleta directamente a las tomas eléctricas exteriores (`TOMA-A` / `TOMA-B`).
- **📥 Importación de Datos desde Excel (`.xlsx`) con Plantilla de Ejemplo**:
  - Nuevo flujo en **Sidebar** y **4. Dashboard & Excel**: permite **descargar primero un Excel de ejemplo (`RackDoc_Plantilla_Importacion_Ejemplo.xlsx`)** con 3 hojas guiadas (`1_Racks_y_Sedes`, `2_Equipos_y_Hosts`, `3_Instrucciones_y_Librerias`) y a continuación **subir/importar un archivo `.xlsx`** para dar de alta o actualizar masivamente Sedes, Plantas, Racks y Equipos/Hosts.
- **💓 Monitorización Heartbeat Multi-Método y Indicadores Inteligentes**:
  - Cada switch, firewall o servidor permite activar Heartbeat (`ICMP Ping`, `SSH`, `HTTPS/SSL`, `HTTP URL`, `TCP Port`, `SNMP`) con parámetros extra (URL Path, Host Header/SNI, validación SSL, usuario SSH, comunidad SNMP, timeout).
  - Visualización del nº de sistemas monitorizados en **Locations**, **Datacenter**, **Rack** y **Dashboard** (con buscador y ordenación), **ocultando automáticamente los puntos de color (`🟢` / `🔴`) cuando su contador es `0`** (solo se muestran si hay más de cero equipos en ese estado).
- **🖼️ Gestión Resiliente de Planos Personalizados**:
  - Persistencia garantizada de planos subidos en el volumen Docker `/app/data/uploads` y tarjeta UX interactiva en caso de plano no disponible para subir uno nuevo o conmutar a la cuadrícula técnica CAD sin errores en pantalla.

---

## 📸 Recorrido Visual por la Plataforma

### 1. Locations — Mapa OpenStreetMap y Planos Personalizados (`JPG` / `PNG` / `GIF`)
- Visualización sobre **OpenStreetMap** sin necesidad de API Keys (*OSM Estándar*, *OSM Claro* y *Topográfico*) con buscador mundial de calles y coordenadas (**Nominatim**).
- **Arrastre directo con el ratón (Drag & Drop)** de los Datacenters sobre el mapa OpenStreetMap o sobre un plano propio subido en formato `JPG`, `PNG` o `GIF` con control de zoom/escala y redimensionado.
- Indicadores de sistemas monitorizados por sede (mostrando los contadores verde/rojo únicamente cuando son `> 0`).

![1. Locations - OpenStreetMap y Planos](docs/screenshots/01_locations_osm.png)

---

### 2. Datacenter — Vista de Planta 2D Multi-Planta y Distribución de Racks
- Gestión de edificios con **múltiples plantas** (`Planta 1`, `Planta 2`, etc.): permite **añadir y eliminar plantas**, así como subir el plano arquitectónico de cada planta con gestión UX ante imágenes ausentes.
- Dibujo interactivo en planta 2D de los **Pasillos Frío / Caliente** y de los **Racks** con su código, numeración y estado de monitorización Heartbeat.
- Arrastra y redimensiona cada rack para colocarlo en su posición física real dentro de la sala, **elimina o añade racks**, y **haz clic sobre cualquier rack para saltar directamente a su editor 42U**.

![2. Datacenter - Vista de Planta 2D](docs/screenshots/02_datacenter_floors.png)

---

### 3. Rack Editor (42U) — Arrastrar con Comprobación de U Libres, Catálogos Ampliados y Tomas Exteriores (Eléctricas & Fibra)
- **Movimiento y Arrastre Directo con Validación de Unidades `U` Libres**:
  - Arrastra cualquier equipo ya montado a otra posición del rack: el lienzo resalta en **verde** si todas las unidades `U` necesarias están libres o en **rojo** si hay colisión, además de incluir botones rápidos `▲ Subir a U libre`, `▼ Bajar a U libre`, `Mover a U...` y `Borrar Equipo`.
- **Librerías Ampliadas por Fabricante (`Devices & Librerías`)**:
  - **`Host - HP`** (12 modelos reales: *ProLiant DL20 Gen11*, *DL320 Gen11*, *DL325 Gen11*, *DL345 Gen11*, *DL360 Gen10/Gen11*, *DL365 Gen11*, *DL380 Gen10/Gen11*, *DL385 Gen11*, *DL560 Gen11*, *Alletra Storage Server 4120*).
  - **`Host - Dell`** (12 modelos reales: *PowerEdge R250*, *R350*, *R450*, *R550*, *R650*, *R650xs*, *R660*, *R6615*, *R750*, *R760*, *R760xd2*, *R7625*, *XE9680*).
  - **`Host - Supermicro`** (11 modelos reales: *SuperServer SYS-111C-NR*, *SYS-121H-TNR*, *AS-1115SV-WTNRT*, *SYS-511E-WR*, *SYS-221H-TNR*, *AS-2115HV-TNRT*, *SYS-621C-TN12R*, *SYS-211E-FRN2T*, *SuperStorage SSG-621E-ACR12H*, *GPU SYS-421GE-TNRT*, *SuperBlade SBE-820C*).
  - **`Network`**, **`Power`** y **`Patching & Passive`**.
- **Tomas Exteriores Eléctricas (`Schuko 230V`) y de Fibra Óptica (`FO1..FON LC/SC`)**:
  - Situadas fuera del bastidor a la derecha del rack: incluye por defecto **`TOMA-A`** (Roja), **`TOMA-B`** (Azul) y **`FIBRA-EXT-1`** (Caja Exterior de Fibra Óptica Aqua OM4).
  - Permite añadir nuevas tomas eléctricas (`+Schuko`) o de fibra (`+Fibra`) y **ajustar el número de conectores de fibra (`1..48`) o enchufes Schuko (`1..16`)** en cualquier momento.

![3. Rack Editor 42U - Librerías y Tomas Exteriores](docs/screenshots/03_rack_editor_schuko.png)

---

### 4. Dashboard Monitorizado & Importación/Exportación Excel (`.xlsx`)
- **Listado Organizable y Buscable de Sistemas Monitorizados**:
  - Filtra en tiempo real por estado (`Todos`, `🟢 Verde`, `🔴 Rojo`), por método de Heartbeat (`ICMP`, `SSH`, `HTTPS`, `HTTP`, `TCP`, `SNMP`), busca por hostname/IP/modelo/rack y ordena por estado, latencia, código, IP o rack.
- **Importación y Exportación Excel (`.xlsx`)**:
  - **`Plantilla Ejemplo (.xlsx)`** (`GET /api/reports/excel/template`): Descarga una plantilla Excel de ejemplo con instrucciones y datos de muestra listos para rellenar.
  - **`Importar Excel (.xlsx)`** (`POST /api/reports/excel/import`): Carga un fichero Excel para crear o actualizar Sedes, Plantas, Racks y Equipos/Hosts automáticamente.
  - **`Exportar Inventario (.xlsx)`** (`GET /api/reports/excel`): Descarga el inventario completo multicapa del Datacenter.

---

### 5. Configuración (`⚙️`) — Login Obligatorio, Usuarios, 4 Roles RBAC y Multi-Active Directory
- **Pantalla de Login y Verificación de Contraseña al Cambiar de Usuario**:
  - Acceso inicial protegido por usuario y contraseña, y solicitud de contraseña al cambiar de sesión de usuario.
- **Icono de Rueda de Configuración (`⚙️`)**:
  - Permite dar de alta usuarios locales con contraseña, asignar cualquiera de los **4 roles RBAC** (`admin`, `editor`, `operator`, `viewer`), registrar múltiples servidores **Active Directory (LDAP/LDAPS)** y aplicar roles tanto a **Usuarios AD** como a **Grupos de Active Directory (`ADRoleMapping`)**.

![4. Administración - 4 Roles RBAC y Multi-AD](docs/screenshots/04_admin_rbac_ad.png)

---

## 🚀 Despliegue Rápido con Docker Compose

### 1. Configurar el fichero `.env`
```bash
cp .env.example .env
```

Variables principales en `.env`:
```env
ADMIN_USERNAME=admin
ADMIN_PASSWORD=admin
ADMIN_EMAIL=admin@rackdoc.local
RACKDOC_DB_PATH=/app/data/rackdoc.db
```

### 2. Levantar los contenedores
```bash
docker compose up -d --build
```

- **Aplicación Web (Frontend Flutter + Nginx)**: [http://localhost:8181](http://localhost:8181)
- **API REST & Documentación OpenAPI (FastAPI)**: [http://localhost:8180/docs](http://localhost:8180/docs)
- **Credenciales por defecto**: Usuario `admin` / Contraseña `admin`

---

## 🏗️ Arquitectura del Proyecto

```text
rackdoc/
├── .env.example                  # Variables de entorno (ADMIN_USERNAME=admin, ADMIN_PASSWORD=admin)
├── docker-compose.yml            # Orquestación Docker (Backend FastAPI :8180 + Frontend Nginx :8181)
├── docs/screenshots/             # Capturas de pantalla de la documentación
├── backend/                      # API REST en Python 3.12 + FastAPI + SQLAlchemy + OpenPyXL
│   └── app/
│       ├── main.py               # Endpoints REST (Locations, Floors, Racks, Libraries, Outlets Power/Fiber, RBAC, Multi-AD, Excel Import/Export)
│       ├── database.py           # Persistencia SQLite y directorio /app/data/uploads en volumen Docker
│       ├── models.py             # Modelos SQLAlchemy (Location, Floor, Room, Rack, DeviceTemplate, RackDevice, Port, Connection, User, ADServer, ADRoleMapping)
│       ├── schemas.py            # Esquemas Pydantic v2
│       ├── seed.py               # Semilla automática (.env admin, HP/Dell/Supermicro, Regletas Schuko Macho, Tomas Eléctricas y de Fibra)
│       └── services/
│           └── excel_export.py   # Exportación, Plantilla de Ejemplo e Importación masiva en Excel (.xlsx)
└── frontend/                     # Aplicación interactiva en Flutter Web (RackDoc8)
    ├── web/                      # Favicon SVG/PNG y Manifiesto Web con el logo oficial de RackDoc8
    └── lib/
        ├── main.dart             # Shell de navegación, Login Gate, Dashboard Monitorizado e Importador Excel (.xlsx)
        ├── core/api_client.dart  # Cliente HTTP REST hacia FastAPI y Nominatim OpenStreetMap
        ├── models/               # Modelos de datos tipados en Dart
        └── features/
            ├── locations/        # 1. Mapa OpenStreetMap arrastrable + subida resiliente de planos JPG/PNG/GIF
            ├── datacenter/       # 2. Editor de Plantas 2D del edificio y posicionamiento de Racks
            ├── rack_editor/      # 3. Rack Editor 42U (Front/Back, Drag & Drop U libres, Tomas Eléctricas y de Fibra Exteriores)
            └── admin/            # 5. Configuración (⚙️) de Usuarios, Contraseñas, 4 Roles RBAC y Grupos/Usuarios Active Directory
```
