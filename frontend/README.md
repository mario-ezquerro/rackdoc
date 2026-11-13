# RackDoc8 Frontend (Flutter Web)

Interfaz gráfica interactiva de **RackDoc8 DCIM** construida con **Flutter Web (`SDK ^3.12.0`)**.

## Estructura de `lib/`

- `main.dart`: marco principal (`RackDocApp` + `RackDocShell`), puerta de autenticación local/AD, navegación lateral de 9 módulos, modo Kiosco y `SelectionArea` global.
- `core/`: cliente HTTP (`api_client.dart`), sistema de diseño (`theme.dart`), notificaciones (`widgets/avisos.dart`) y adaptadores multiplataforma Web/IO para descarga y selección de ficheros.
- `models/datacenter_models.dart`: modelos inmutables tipados de sedes, plantas, salas, racks, dispositivos, puertos, conexiones, usuarios RBAC y servidores Active Directory.
- `shared/widgets/`: selector reutilizable de activos CMDB (`cmdb_asset_explorer_dialog.dart`) y motor de exportación de diagramas (`diagram_exporter.dart`).
- `features/`: módulos funcionales (`locations`, `datacenter`, `rack_editor`, `network_hosts`, `dashboard`, `cmdb`, `certscope`, `sre_alarms`, `admin`), organizados en submódulos `part` por pestaña/sección.

## Convención de Selección de Texto vs. Drag & Drop

La aplicación habilita selección y copia de texto (`Ctrl+C` / `Cmd+C`) de forma global mediante `SelectionArea` en `main.dart`. Cualquier lienzo interactivo 2D con `GestureDetector(onPanUpdate: ...)` o lista de tarjetas `Draggable<T>` debe envolverse en `SelectionContainer.disabled(...)` para evitar colisiones en la arena de gestos del navegador.

## Comandos habituales

```bash
# Análisis estático (objetivo: 0 issues)
flutter analyze

# Suite de tests unitarios y de widgets
flutter test

# Compilación de producción para el contenedor Nginx
flutter build web --release --pwa-strategy=none
```
