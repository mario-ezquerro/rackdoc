# 🗄️ RackDoc — Visual Datacenter & 42U Rack Infrastructure Manager (DCIM)

**RackDoc** es una plataforma visual de gestión y documentación de centros de datos (**DCIM**) desarrollada con **Flutter Web** (Canvas 2D interactivo), **FastAPI (Python)**, **SQLite** y **Docker Compose**.

Permite gestionar visualmente desde la ubicación geográfica de los Datacenters en **OpenStreetMap** o planos personalizados, pasando por las **distintas plantas 2D del edificio**, hasta el **Rack Editor 42U** con vista **Front & Back**, librerías de equipamiento importables/exportables, **tomas eléctricas Schuko exteriores con código de color por circuito**, lanzamiento de sesiones **SSH / Telnet / HTTPS Web UI**, chequeo **Ping en vivo**, informes **Excel (.xlsx)** y control de acceso basado en **4 roles (RBAC)** con soporte **Multi-Active Directory (LDAP/LDAPS)**.

---

## 📸 Recorrido Visual por la Plataforma

### 1. Locations — Mapa OpenStreetMap y Planos Personalizados (`JPG` / `PNG` / `GIF`)
- Visualización sobre **OpenStreetMap** sin necesidad de API Keys (*OSM Estándar*, *OSM Claro* y *Topográfico*) con buscador mundial de calles y coordenadas (**Nominatim**).
- **Arrastre directo con el ratón (Drag & Drop)** de los Datacenters sobre el mapa OpenStreetMap o sobre un plano propio subido en formato `JPG`, `PNG` o `GIF` con control de zoom/escala y redimensionado.
- Creación, edición y borrado completo de sedes (**Locations**).

![1. Locations - OpenStreetMap y Planos](docs/screenshots/01_locations_osm.png)

---

### 2. Datacenter — Vista de Planta 2D Multi-Planta y Distribución de Racks
- Gestión de edificios con **múltiples plantas** (`Planta 1`, `Planta 2`, etc.): permite **añadir y eliminar plantas**, así como subir el plano arquitectónico de cada planta.
- Dibujo interactivo en planta 2D de los **Pasillos Frío / Caliente** y de los **Racks** con su código y numeración (`RK001_M`, `RK002_S`, etc.).
- Arrastra y redimensiona cada rack para colocarlo en su posición física real dentro de la sala, **elimina o añade racks**, y **haz clic sobre cualquier rack para saltar directamente a su editor 42U**.

![2. Datacenter - Vista de Planta 2D](docs/screenshots/02_datacenter_floors.png)

---

### 3. Rack Editor (42U) — Librerías por Grupo, Vista Front/Back y Tomas Schuko Exteriores
- **Librerías de Dispositivos por Grupo (`Devices & Librerías`)**:
  - Filtra y organiza el catálogo por librerías seleccionables: **`Network`**, **`Power`** (incluyendo **PDU**, **UPS/SAI** y **Regletas/Enchufes Schuko**), **`Host - HP`**, **`Host - Dell`**, **`Patching & Passive`**, o cualquier grupo nuevo creado por el usuario.
  - **Importación y Exportación en JSON por grupo** (`GET /api/templates/export?library_group=Power`, `POST /api/templates/import`) y creación de nuevas plantillas asignándolas directamente a un grupo concreto.
- **Tomas / Enchufes Schuko Exteriores al Rack (`⚡ TOMAS ELÉCTRICAS EXTERIORES`)**:
  - Situadas fuera del bastidor a la derecha del rack para enchufar equipamiento desde la cara **Front** o **Back**.
  - Mínimo 1 toma exterior y **2 por defecto** siguiendo el estándar de doble acometida en centros de datos: **`TOMA-A` (Roja `#DC2626`)** y **`TOMA-B` (Azul `#2563EB`)**, ampliables (`+ Ampliar`) y editables en nombre, número de enchufes Schuko y color identificativo.
  - Los **cables de alimentación heredan y sincronizan automáticamente el color** de la toma exterior a la que están conectados.
- **Gestión de Red, Ping en Vivo y Lanzadores Remotos**:
  - Configuración de `IP`, `Máscara`, `Gateway`, `FQDN`, `MAC`, `VLAN`, variables personalizadas (`Custom Fields`) y acceso directo en 1 clic a **`SSH`**, **`Telnet`** y **`HTTPS / Web UI (iLO / iDRAC)`**.

![3. Rack Editor 42U - Librerías y Tomas Schuko Exteriores](docs/screenshots/03_rack_editor_schuko.png)

---

### 4. Administración — Usuario `.env` (`admin/admin`), 4 Roles RBAC y Multi-Active Directory
- **Credenciales `admin` / `admin` por fichero `.env`**:
  - El usuario administrador principal se configura mediante variables de entorno en el fichero [`.env`](.env.example) (`ADMIN_USERNAME=admin`, `ADMIN_PASSWORD=admin`, `ADMIN_EMAIL=admin@rackdoc.local`) inyectadas directamente al contenedor Docker.
- **4 Roles de Acceso (RBAC)**:
  1. **`admin` (*Administrador*)**: Control total del sistema, gestión de usuarios locales y servidores Active Directory, edición completa y conexión remota a los hosts.
  2. **`editor` (*Editor*)**: Puede crear, mover, editar y eliminar Locations, Plantas, Racks, Librerías, Tomas Schuko y Cables, además de lanzar conexiones `SSH`/`Telnet`/`Web` y `Ping`.
  3. **`operator` (*Ver y Conectarse*)**: Solo lectura sobre el diseño físico del rack (no puede mover ni borrar equipos/cables), **pero sí puede interactuar con cada host** mediante `SSH`, `Telnet`, `Web UI` y `Test Ping`.
  4. **`viewer` (*Solo Ver*)**: Modo visualización/auditoría estricto (sin edición y con los lanzadores `SSH`/`Telnet`/`Web` bloqueados).
- **Integración con Uno o Múltiples Active Directory (`Multi-AD / LDAP / LDAPS`)**:
  - Permite dar de alta tantos servidores Active Directory como se necesiten, buscar usuarios en cada directorio y asignarle a cada usuario cualquiera de los 4 roles (`admin`, `editor`, `operator`, `viewer`).

![4. Administración - 4 Roles RBAC y Multi-AD](docs/screenshots/04_admin_rbac_ad.png)

---

## 🚀 Despliegue Rápido con Docker Compose

### 1. Configurar el fichero `.env`
Copia la plantilla `.env.example` a `.env` (o edita el fichero `.env` incluido):

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
│       ├── main.py               # Endpoints REST (Locations, Floors, Racks, Libraries, Outlets, RBAC, Multi-AD, Excel)
│       ├── models.py             # Modelos SQLAlchemy (Location, Floor, Room, Rack, DeviceTemplate, RackDevice, Port, Connection, User, ADServer)
│       ├── schemas.py            # Esquemas Pydantic v2
│       ├── seed.py               # Semilla automática (.env admin, 4 roles, Multi-AD, librerías Network/Power/HP y Tomas Schuko)
│       └── excel_service.py      # Generador de inventario multicapa en Excel (.xlsx)
└── frontend/                     # Aplicación interactiva en Flutter Web
    └── lib/
        ├── main.dart             # Shell de navegación en 5 vistas + selector de sesión/login RBAC
        ├── core/api_client.dart  # Cliente HTTP REST hacia FastAPI y Nominatim OpenStreetMap
        ├── models/               # Modelos de datos tipados en Dart
        └── features/
            ├── locations/        # 1. Mapa OpenStreetMap arrastrable + subida de planos JPG/PNG/GIF
            ├── datacenter/       # 2. Editor de Plantas 2D del edificio y posicionamiento de Racks
            ├── rack_editor/      # 3. Rack Editor 42U (Front/Back, Librerías JSON, Tomas Schuko Exteriores, Cables Ortogonales)
            └── admin/            # 5. Administración de Usuarios, 4 Roles RBAC y Servidores Active Directory
```
