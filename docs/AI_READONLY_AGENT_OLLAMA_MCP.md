# RackDoc AI (`v1.4.0`) — Guía del Agente IA Solo-Lectura, Autodocumentador, Esquemas 2D, Descubrimiento Pasivo y Servidor MCP

> **Módulos implicados:** `10. Agente IA (RO)` · `9. Administración -> Motor de IA` · `backend/mcp_server/rackdoc_mcp.py`

---

## 1. Principio de Seguridad: Triple Candado Solo-Lectura

El Agente IA de RackDoc está diseñado específicamente para operar sobre **infraestructura crítica de CPD** sin riesgo de caída ni alteración accidental:

1. **`Zero-Touch` hacia la red y servidores**:
   - En análisis base solo consulta SQLite/PostgreSQL y series temporales de Prometheus (`GET /api/v1/query`).
   - En **Descubrimiento Pasivo (Fase 2)** ejecuta únicamente lecturas en memoria (`ss -tulnpH`, `ss -tnpH`, `systemctl`, `docker ps`, `Get-NetTCPConnection`) con `become: false` y `changed_when: false`, guardando el JSON en el controlador local (**cero ficheros escritos en los servidores auditados**), o datagramas UDP `GetNextRequest (0xA1)` de lectura sobre `IF-MIB` y `LLDP-MIB`.
2. **Sanitizador recursivo obligatorio (`sanitize_context_payload`)**:
   - Antes de construir cualquier prompt hacia un LLM o responder al servidor MCP, se expurgan hashes `bcrypt`, secretos cifrados con Fernet, `bind_password` de Active Directory, contraseñas SMTP, comunidades SNMP, certificados privados y tokens `Bearer` / `sk-*` / `rdk_ro_*`.
3. **`Human-in-the-Loop` hacia la CMDB y Topología**:
   - El agente **jamás escribe directamente** sobre `racks`, `rack_devices`, `cmdb_assets`, `network_logical_links` ni `network_switch_snmp_ports`.
   - Sus resultados viven aislados en `ai_generated_documents`, `ai_cmdb_suggestions` y `ai_passive_discovery_snapshots` hasta que un operador con rol `editor` o `admin` pulsa explícitamente **Aplicar**.

---

## 2. Motor LLM Local por Defecto (`rackdoc-ollama`) y Proveedores Externos

Por defecto `docker-compose.yml` levanta el contenedor **`rackdoc-ollama`** (`:11434`, persistido en `./data/ollama`) para que **ninguna dirección IP ni topología salga del CPD**:

```bash
# Descargar el modelo recomendado por defecto (desde terminal o con 1 clic en 9. Administración)
docker exec rackdoc-ollama ollama pull qwen2.5:7b
```

Desde **`9. Administración -> Motor de IA Solo-Lectura`** (exclusivo rol `admin`) puedes:
- Descargar modelos locales (`qwen2.5:7b`, `llama3.2:3b`, `qwen2.5-coder:7b`, `mistral:7b`).
- Apuntar a un Ollama nativo con GPU en el host (`http://host.docker.internal:11434`).
- Conmutar a un proveedor externo (`openai_compatible` como OpenAI/vLLM/LM Studio, `gemini` o `anthropic`) almacenando su API Key cifrada en reposo mediante **Fernet (`AES-128-CBC + HMAC-SHA256`)**.
- Activar la **Auditoría periódica automática en background** (`6h`, `12h`, `24h`, `48h` o `7d`).

> Si el contenedor LLM está apagado o aún no se ha descargado el modelo, RackDoc activa automáticamente su **modo determinista de respaldo**, generando igualmente el Dossier técnico, la tabla de SPOFs y el diagrama Mermaid verificado.

---

## 3. Las 6 Pestañas de `10. Agente IA (RO)` en la Interfaz Web

1. **`1. Autodocumentación & Runbooks`**:
   - Genera dossiers completos en GitHub-Flavored Markdown + diagramas `Mermaid` por alcance (*CPD Completo*, *Auditoría Integral SPOF*, *Sede*, *Bastidor Rack*, *Stack 2D* o *Host*).
   - Incorpora el **Visor Gráfico Mermaid Nativo (`MermaidVisualViewer`)** 100% local/offline (sin CDNs externos), con modos `Dossier + Visor`, `Solo Visor Mermaid` y `Solo Markdown`, conmutador en vivo `Vertical (TD)` ⇄ `Horizontal (LR)`, zoom/pan, vista a pantalla completa, exportación PNG 2x y descarga directa `.md`.
2. **`2. Esquemas de Red 2D (IA)`**:
   - Lienzo interactivo CAD 2D en **5 capas** (*Subredes/Perímetro*, *Conmutación/Racks*, *Hipervisores/Hierro*, *VMs/Apps/Contenedores*, *BBDD/Almacenamiento*).
   - Distingue visualmente cableado físico, relación `Hipervisor -> VM`, enlaces lógicos confirmados y **enlaces descubiertos pasivamente en modo RO (línea discontinua cian)**, marcando con borde rojo los nodos con SPOF o riesgo TLS/SRE.
   - Exporta en **`.DRAWIO` (Visio / diagrams.net)**, **`.DIA` (GNOME Dia)**, **`.PNG` (2x)**, **`.PDF` (A4 apaisado)**, **`.SVG`**, **`.CSV`** y **`.JSON`**, o publica el esquema con 1 clic en **`4. Red & Host`**.
3. **`3. SPOFs, SRE & FinOps`**:
   - Detecta concentración de clusters en un mismo hipervisor o rack, falta de doble cadena eléctrica PDU/SAI, hosts críticos sin regla de guardia SRE, certificados TLS próximos a caducar, **saturación de CPU/RAM/Disco (`>85%`)** y **sobredimensionamiento FinOps (`<10%` en máquinas grandes)** en Prometheus.
4. **`4. Copiloto Solo-Lectura`**:
   - Chat técnico contextualizado con el inventario real (accesible incluso con rol `viewer`).
5. **`5. Borradores CMDB (`Human-in-the-Loop`)`**:
   - Revisa y aplica con 1 clic descripciones operativas, sistemas operativos/firmware o alineaciones de criticidad sugeridas.
6. **`6. Descubrimiento Pasivo RO`**:
   - **Walk SNMP `IF-MIB` + `LLDP-MIB` (`161/UDP`)**: descubre bocas, velocidades, MACs, estados y vecinos LLDP.
   - **Auditoría SSH (Linux) / WinRM (Windows)**: descubre puertos escuchando, conexiones TCP establecidas entre servidores y contenedores Docker/Podman sin escribir en el disco remoto.

---

## 4. Servidor MCP Oficial (`rackdoc-mcp`) para Antigravity, Claude Desktop y Cursor

1. Entra en **`9. Administración -> Motor de IA`** y pulsa **`Generar Token Servidor MCP Solo-Lectura`** (o define `AI_READONLY_API_KEY` en `.env`).
2. Añade el bloque JSON en tu cliente MCP:

```json
{
  "mcpServers": {
    "rackdoc-readonly": {
      "command": "python3",
      "args": ["/ruta/absoluta/a/rackdoc/backend/mcp_server/rackdoc_mcp.py"],
      "env": {
        "RACKDOC_BASE_URL": "http://localhost:8180",
        "RACKDOC_AI_READONLY_KEY": "rdk_ro_TU_TOKEN_GENERADO"
      }
    }
  }
}
```

### Herramientas MCP expuestas
| Herramienta MCP | Descripción |
| :--- | :--- |
| `get_cpd_executive_summary` | Radiografía global o por sede (KPIs, racks, CMDB, subredes, certificados y Mermaid). |
| `inspect_rack_and_cabling` | Detalle U a U, acometidas eléctricas y latiguillos de un Rack concreto. |
| `inspect_logical_stack_or_host` | Dependencias aguas arriba y aguas abajo de un Stack 2D o Host CMDB. |
| `audit_spofs_and_sre_risks` | Lista priorizada de SPOFs, brechas de guardia SRE y caducidades TLS. |
| `get_passive_discovery_telemetry` | Puertos escuchando, conexiones TCP entre máquinas, contenedores y bocas/vecinos LLDP. |
| `get_analyzed_network_schema` | Grafo geométrico en 5 capas (zonas, nodos, enlaces y alertas FinOps). |
| `query_prometheus_readonly` | Consulta instantánea PromQL en modo solo-lectura contra `rackdoc-prometheus`. |
| `save_infrastructure_document` | Archiva un informe Markdown externo en la biblioteca IA sin modificar la CMDB. |
