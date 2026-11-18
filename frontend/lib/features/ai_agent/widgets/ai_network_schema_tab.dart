import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../core/api_client.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/avisos.dart';
import '../../../shared/widgets/diagram_exporter.dart';

/// Pestaña **`Esquemas de Red 2D (Según Análisis IA)`**:
/// Renderiza en un lienzo interactivo 2D (con zoom/pan, curvas Bézier, líneas
/// discontinuas para flujos descubiertos pasivamente RO, insignias de riesgo SPOF
/// e inspector lateral) la topología real calculada por el Agente IA, permitiendo:
/// 1. Exportar directamente a `.DRAWIO`, `.DIA`, `.PNG` (2x), `.PDF` (A4), `.SVG`, `.CSV`, `.JSON`.
/// 2. Publicar con 1 clic como Stack Tecnológico editable en **`4. Red & Host`**.
class AiNetworkSchemaTab extends StatefulWidget {
  final RackDocApiClient api;
  final Map<String, dynamic> scopeTargets;
  final bool canEdit;
  final void Function(int rackId, int? deviceId)? onNavigateToRack;
  final void Function(int stackId)? onNavigateToTechStack;

  const AiNetworkSchemaTab({
    super.key,
    required this.api,
    required this.scopeTargets,
    required this.canEdit,
    this.onNavigateToRack,
    this.onNavigateToTechStack,
  });

  @override
  State<AiNetworkSchemaTab> createState() => _AiNetworkSchemaTabState();
}

class _AiNetworkSchemaTabState extends State<AiNetworkSchemaTab> {
  final GlobalKey _repaintKey = GlobalKey();
  final TransformationController _transformCtrl = TransformationController();

  bool _loading = true;
  bool _publishing = false;
  String? _error;

  String _scopeType = 'global_cpd';
  int? _scopeTargetId;
  String _edgeFilter = 'all';
  bool _onlyRisks = false;
  bool _showAllEdgeLabels = false;

  Map<String, dynamic> _schema = const {};
  String? _selectedNodeId;

  @override
  void initState() {
    super.initState();
    _loadSchema();
  }

  @override
  void dispose() {
    _transformCtrl.dispose();
    super.dispose();
  }

  List<Map<String, dynamic>> _targetsForScope() {
    String? key;
    if (_scopeType == 'location') key = 'locations';
    if (_scopeType == 'rack') key = 'racks';
    if (_scopeType == 'logical_stack') key = 'logical_stacks';
    if (_scopeType == 'host') key = 'hosts';
    if (key == null) return const [];
    return ((widget.scopeTargets[key] ?? const []) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<void> _loadSchema() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.api.getAiAnalyzedNetworkSchema(
        scopeType: _scopeType,
        scopeTargetId: _scopeTargetId,
      );
      if (!mounted) return;
      setState(() {
        _schema = data;
        _selectedNodeId = null;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _publishToRedAndHost() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _publishing = true);
    try {
      final res = await widget.api.publishAiNetworkSchemaToStack({
        'scope_type': _scopeType,
        'scope_target_id': _scopeTargetId,
        'stack_name': '',
        'include_passive_ro_edges': true,
      });
      if (!mounted) return;
      final stackId = res['stack_id'] as int?;
      messenger.avisoExito(
        'Publicado en Red & Host: "${res['stack_name']}" (${res['nodes_created']} nodos, ${res['edges_created']} enlaces).',
      );
      if (stackId != null && widget.onNavigateToTechStack != null) {
        widget.onNavigateToTechStack!(stackId);
      }
    } catch (e) {
      messenger.avisoError(e);
    } finally {
      if (mounted) {
        setState(() => _publishing = false);
      }
    }
  }

  List<Map<String, dynamic>> _visibleNodes() {
    final raw = ((_schema['nodes'] ?? const []) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    if (!_onlyRisks) return raw;
    return raw
        .where((n) => ((n['risk_badges'] ?? const []) as List).isNotEmpty)
        .toList();
  }

  List<Map<String, dynamic>> _visibleEdges(Set<String> visibleNodeIds) {
    final raw = ((_schema['edges'] ?? const []) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    return raw.where((e) {
      if (_edgeFilter != 'all' && e['edge_kind'] != _edgeFilter) {
        return false;
      }
      return visibleNodeIds.contains(e['source_id']) &&
          visibleNodeIds.contains(e['target_id']);
    }).toList();
  }

  DiagramExportDocument _buildExportDocument() {
    final zones = ((_schema['zones'] ?? const []) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .map(
          (z) => DiagramExportZone(
            id: (z['id'] ?? '').toString(),
            title: (z['title'] ?? '').toString(),
            subtitle: (z['subtitle'] ?? '').toString(),
            x: ((z['x'] ?? 0) as num).toDouble(),
            y: ((z['y'] ?? 0) as num).toDouble(),
            width: ((z['width'] ?? 1400) as num).toDouble(),
            height: ((z['height'] ?? 180) as num).toDouble(),
            colorHex: (z['color_hex'] ?? '#2563EB').toString(),
          ),
        )
        .toList();

    final vNodes = _visibleNodes();
    final vNodeIds = vNodes.map((n) => (n['id'] ?? '').toString()).toSet();
    final vEdges = _visibleEdges(vNodeIds);

    return DiagramExportDocument(
      moduleName: 'RackDoc AI (Análisis Solo-Lectura)',
      title: (_schema['title'] ?? 'Esquema de Red IA').toString(),
      subtitle: (_schema['subtitle'] ?? '').toString(),
      fileBaseName: 'rackdoc_esquema_red_ia_$_scopeType',
      canvasWidth: ((_schema['canvas_width'] ?? 1480) as num).toDouble(),
      canvasHeight: ((_schema['canvas_height'] ?? 860) as num).toDouble(),
      zones: zones,
      nodes: vNodes
          .map(
            (n) => DiagramExportNode(
              id: (n['id'] ?? '').toString(),
              code: (n['code'] ?? '').toString(),
              name: (n['name'] ?? '').toString(),
              ip: (n['ip'] ?? '').toString(),
              subtitle: (n['subtitle'] ?? '').toString(),
              modelName: (n['model_name'] ?? '').toString(),
              serialNumber: (n['serial_number'] ?? '').toString(),
              status: (n['status'] ?? 'online').toString(),
              x: ((n['x'] ?? 0) as num).toDouble(),
              y: ((n['y'] ?? 0) as num).toDouble(),
              width: ((n['width'] ?? 236) as num).toDouble(),
              height: ((n['height'] ?? 88) as num).toDouble(),
              colorHex: (n['color_hex'] ?? '#1E293B').toString(),
            ),
          )
          .toList(),
      edges: vEdges
          .map(
            (e) => DiagramExportEdge(
              id: (e['id'] ?? '').toString(),
              sourceId: (e['source_id'] ?? '').toString(),
              targetId: (e['target_id'] ?? '').toString(),
              label: (e['label'] ?? '').toString(),
              detail: (e['detail'] ?? '').toString(),
              colorHex: (e['color_hex'] ?? '#2563EB').toString(),
              dashed: e['dashed'] == true,
            ),
          )
          .toList(),
      repaintBoundaryKey: _repaintKey,
    );
  }

  Color _parseHex(String hex, {Color fallback = AppPalette.blue600}) {
    final clean = hex.replaceAll('#', '').trim();
    if (clean.length == 6) {
      final v = int.tryParse('FF$clean', radix: 16);
      if (v != null) return Color(v);
    }
    return fallback;
  }

  @override
  Widget build(BuildContext context) {
    final scopeTargetsList = _targetsForScope();

    return Column(
      children: [
        // BARRA DE CONTROLES, FILTROS DE CAPA/ARISTA Y EXPORTACIÓN CAD/VISIO/PNG/PDF
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: AppPalette.slate200)),
          ),
          child: Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 220,
                child: DropdownButtonFormField<String>(
                  initialValue: _scopeType,
                  isDense: true,
                  decoration: const InputDecoration(
                    labelText: 'Esquema según Análisis',
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'global_cpd',
                      child: Text('CPD Completo (5 Capas)'),
                    ),
                    DropdownMenuItem(
                      value: 'location',
                      child: Text('Por Sede / Ubicación'),
                    ),
                    DropdownMenuItem(
                      value: 'rack',
                      child: Text('Por Bastidor Rack'),
                    ),
                    DropdownMenuItem(
                      value: 'logical_stack',
                      child: Text('Por Servicio / Stack'),
                    ),
                    DropdownMenuItem(
                      value: 'host',
                      child: Text('Vecindario de un Host'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() {
                      _scopeType = v;
                      final nextList = _targetsForScope();
                      _scopeTargetId = nextList.isNotEmpty
                          ? nextList.first['id'] as int
                          : null;
                    });
                    _loadSchema();
                  },
                ),
              ),
              if (scopeTargetsList.isNotEmpty)
                SizedBox(
                  width: 220,
                  child: DropdownButtonFormField<int>(
                    initialValue: scopeTargetsList
                            .any((t) => t['id'] == _scopeTargetId)
                        ? _scopeTargetId
                        : (scopeTargetsList.first['id'] as int),
                    isDense: true,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Objetivo',
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    items: scopeTargetsList
                        .map(
                          (t) => DropdownMenuItem<int>(
                            value: t['id'] as int,
                            child: Text(
                              (t['label'] ?? '').toString(),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (id) {
                      setState(() => _scopeTargetId = id);
                      _loadSchema();
                    },
                  ),
                ),
              SizedBox(
                width: 205,
                child: DropdownButtonFormField<String>(
                  initialValue: _edgeFilter,
                  isDense: true,
                  decoration: const InputDecoration(
                    labelText: 'Capa de Enlaces',
                    border: OutlineInputBorder(),
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'all',
                      child: Text('Todos los Enlaces'),
                    ),
                    DropdownMenuItem(
                      value: 'physical_cabling',
                      child: Text('Cableado Físico Rack'),
                    ),
                    DropdownMenuItem(
                      value: 'hosting_parent',
                      child: Text('Hipervisor ➔ VM'),
                    ),
                    DropdownMenuItem(
                      value: 'logical_confirmed',
                      child: Text('Lógicos Confirmados'),
                    ),
                    DropdownMenuItem(
                      value: 'subnet_l3',
                      child: Text('Enrutamiento Subredes L3'),
                    ),
                    DropdownMenuItem(
                      value: 'passive_ro_discovered',
                      child: Text('Descubiertos RO (TCP/LLDP)'),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _edgeFilter = v);
                  },
                ),
              ),
              FilterChip(
                label: const Text(
                  'Solo Riesgo / SPOF',
                  style: TextStyle(fontSize: 11.5),
                ),
                selected: _onlyRisks,
                onSelected: (v) => setState(() => _onlyRisks = v),
              ),
              FilterChip(
                label: const Text(
                  'Todas las Etiquetas',
                  style: TextStyle(fontSize: 11.5),
                ),
                selected: _showAllEdgeLabels,
                onSelected: (v) => setState(() => _showAllEdgeLabels = v),
              ),
              IconButton(
                tooltip: 'Centrar / Reset Zoom',
                onPressed: () => _transformCtrl.value = Matrix4.identity(),
                icon: const Icon(Icons.center_focus_strong_rounded, size: 19),
              ),
              DiagramExportMenuButton(
                compact: true,
                buttonLabel: 'Exportar Esquema (.drawio / .png / .pdf / .svg)',
                documentBuilder: _buildExportDocument,
              ),
              if (widget.canEdit)
                FilledButton.tonalIcon(
                  onPressed: _publishing ? null : _publishToRedAndHost,
                  icon: _publishing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.publish_rounded, size: 16),
                  label: const Text('Publicar en 4. Red & Host'),
                ),
            ],
          ),
        ),

        // LEYENDA RÁPIDA DE ARISTAS
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          color: AppPalette.slate100,
          child: const Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              _LegendDot(
                color: AppPalette.blue600,
                label: 'Cableado Físico (UTP/Fibra)',
              ),
              _LegendDot(
                color: AppPalette.indigo600,
                label: 'Alojamiento Hipervisor ➔ VM',
              ),
              _LegendDot(
                color: AppPalette.green600,
                label: 'Enlace Lógico Confirmado',
              ),
              _LegendDot(
                color: AppPalette.cyan500,
                label: 'Descubierto Pasivamente RO (Línea Discontinua)',
                dashed: true,
              ),
              _LegendDot(
                color: AppPalette.red600,
                label: 'Borde Rojo = Alerta SPOF / SRE / TLS',
              ),
            ],
          ),
        ),

        // CUERPO PRINCIPAL: LIENZO 2D INTERACTIVO + INSPECTOR LATERAL
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(child: Text('Error generando esquema: $_error'))
                  : _buildCanvasAndInspector(),
        ),
      ],
    );
  }

  Widget _buildCanvasAndInspector() {
    final zones = ((_schema['zones'] ?? const []) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final nodes = _visibleNodes();
    final nodeIds = nodes.map((n) => (n['id'] ?? '').toString()).toSet();
    final edges = _visibleEdges(nodeIds);
    final cw = ((_schema['canvas_width'] ?? 1480) as num).toDouble();
    final ch = ((_schema['canvas_height'] ?? 860) as num).toDouble();

    final selectedNode = nodes.firstWhere(
      (n) => n['id'] == _selectedNodeId,
      orElse: () => nodes.isNotEmpty ? nodes.first : <String, dynamic>{},
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // LIENZO 2D AISLADO DE SELECTIONAREA PARA GESTOS FLUIDOS DE ARRASTRE/ZOOM
        Expanded(
          child: SelectionContainer.disabled(
            child: Container(
              color: AppPalette.slate50,
              child: InteractiveViewer(
                transformationController: _transformCtrl,
                constrained: false,
                boundaryMargin: const EdgeInsets.all(240),
                minScale: 0.35,
                maxScale: 2.4,
                child: RepaintBoundary(
                  key: _repaintKey,
                  child: SizedBox(
                    width: cw,
                    height: ch,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // 1. Bandas de Zonas y Líneas Curvas de Conexión (clic en fondo limpia selección)
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTap: () =>
                                setState(() => _selectedNodeId = null),
                            child: CustomPaint(
                              painter: _AiNetworkTopologyPainter(
                                zones: zones,
                                nodes: nodes,
                                edges: edges,
                                selectedNodeId: _selectedNodeId,
                                showAllEdgeLabels: _showAllEdgeLabels,
                              ),
                            ),
                          ),
                        ),

                        // 2. Nodos Interactivos Posicionados
                        for (final n in nodes) _buildNodeCardWidget(n),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),

        // PANEL INSPECTOR DERECHO DEL NODO SELECCIONADO
        Container(
          width: 330,
          padding: const EdgeInsets.all(16),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(left: BorderSide(color: AppPalette.slate200)),
          ),
          child: selectedNode.isEmpty
              ? const Center(
                  child: Text(
                    'No hay nodos en este filtro.',
                    style: TextStyle(color: AppPalette.slate500),
                  ),
                )
              : SingleChildScrollView(
                  child: _buildSelectedNodeInspector(selectedNode, edges, nodes),
                ),
        ),
      ],
    );
  }

  Widget _buildNodeCardWidget(Map<String, dynamic> n) {
    final nid = (n['id'] ?? '').toString();
    final isSelected = nid == _selectedNodeId;
    final x = ((n['x'] ?? 0) as num).toDouble();
    final y = ((n['y'] ?? 0) as num).toDouble();
    final w = ((n['width'] ?? 236) as num).toDouble();
    final h = ((n['height'] ?? 88) as num).toDouble();
    final strokeCol = _parseHex((n['color_hex'] ?? '#2563EB').toString());
    final risks = ((n['risk_badges'] ?? const []) as List);
    final status = (n['status'] ?? 'online').toString();
    final dotCol = status == 'online'
        ? AppPalette.green600
        : (status == 'offline' ? AppPalette.red600 : AppPalette.slate400);

    return Positioned(
      left: x,
      top: y,
      width: w,
      height: h,
      child: GestureDetector(
        onTap: () => setState(() => _selectedNodeId = nid),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? AppPalette.blue50 : Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected ? AppPalette.blue700 : strokeCol,
              width: isSelected ? 2.6 : 1.8,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isSelected ? 0.12 : 0.05),
                blurRadius: isSelected ? 10 : 5,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: dotCol,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '[${n['code']}] ${n['name']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                        color: AppPalette.slate900,
                      ),
                    ),
                  ),
                  if (risks.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 1.5,
                      ),
                      decoration: BoxDecoration(
                        color: AppPalette.red50,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: AppPalette.red300),
                      ),
                      child: Text(
                        '⚠ ${risks.length}',
                        style: const TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w800,
                          color: AppPalette.red700,
                        ),
                      ),
                    ),
                ],
              ),
              if ((n['ip'] ?? '').toString().isNotEmpty)
                Text(
                  (n['ip'] ?? '').toString(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    color: AppPalette.blue700,
                  ),
                ),
              Text(
                (n['subtitle'] ?? '').toString(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 10,
                  color: AppPalette.slate600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSelectedNodeInspector(
    Map<String, dynamic> node,
    List<Map<String, dynamic>> edges,
    List<Map<String, dynamic>> allNodes,
  ) {
    final nid = (node['id'] ?? '').toString();
    final nodeMap = {for (final x in allNodes) (x['id'] ?? '').toString(): x};
    final relatedEdges = edges
        .where((e) => e['source_id'] == nid || e['target_id'] == nid)
        .toList();
    final risks = ((node['risk_badges'] ?? const []) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final listenPorts = (node['listening_ports'] ?? const []) as List;
    final containers = (node['containers'] ?? const []) as List;
    final rackId = node['rack_id'] as int?;
    final rackDevId = node['rack_device_id'] as int?;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${node['code']} — ${node['name']}',
          style: const TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w800,
            color: AppPalette.slate900,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'IP: ${(node['ip'] ?? '').toString().isEmpty ? "—" : node['ip']}  ·  Estado: ${node['status']}',
          style: const TextStyle(fontSize: 12, color: AppPalette.slate600),
        ),
        if ((node['model_name'] ?? '').toString().isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            'SO / Modelo: ${node['model_name']}',
            style: const TextStyle(fontSize: 11.5, color: AppPalette.slate500),
          ),
        ],
        if (rackId != null && widget.onNavigateToRack != null) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => widget.onNavigateToRack!(rackId, rackDevId),
              icon: const Icon(Icons.developer_board_outlined, size: 16),
              label: const Text('Abrir Ubicación en Rack 42U'),
            ),
          ),
        ],
        if (node['cpu_pct'] != null ||
            node['ram_pct'] != null ||
            node['disk_pct'] != null) ...[
          const Divider(height: 22),
          const Text(
            'Telemetría Prometheus / Capacidad',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text(
            'CPU: ${node['cpu_pct'] ?? "—"}%   ·   RAM: ${node['ram_pct'] ?? "—"}%   ·   Disco: ${node['disk_pct'] ?? "—"}%',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppPalette.blue700,
            ),
          ),
        ],
        if (listenPorts.isNotEmpty || containers.isNotEmpty) ...[
          const Divider(height: 22),
          const Text(
            'Descubrimiento Pasivo RO',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
          ),
          if (listenPorts.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Puertos en escucha: ${listenPorts.map((p) => ":$p").join(", ")}',
              style: const TextStyle(fontSize: 11.5),
            ),
          ],
          if (containers.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Contenedores: ${containers.join(", ")}',
              style: const TextStyle(
                fontSize: 11.5,
                color: AppPalette.indigo600,
              ),
            ),
          ],
        ],
        if (risks.isNotEmpty) ...[
          const Divider(height: 22),
          Text(
            'Riesgos / SPOFs Detectados (${risks.length})',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: AppPalette.red700,
            ),
          ),
          const SizedBox(height: 6),
          for (final r in risks)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                '• [${(r['severity'] ?? '').toString().toUpperCase()}] ${r['title']}',
                style: const TextStyle(
                  fontSize: 11.5,
                  color: AppPalette.red800,
                ),
              ),
            ),
        ],
        const Divider(height: 22),
        Text(
          'Conexiones en el Esquema (${relatedEdges.length})',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 6),
        if (relatedEdges.isEmpty)
          const Text(
            'Sin enlaces visibles en este filtro.',
            style: TextStyle(fontSize: 11.5, color: AppPalette.slate500),
          )
        else
          for (final e in relatedEdges)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                e['source_id'] == nid
                    ? '➔ ${(nodeMap[e['target_id']]?['code']) ?? e['target_id']} (${e['label']})'
                    : '⬅ ${(nodeMap[e['source_id']]?['code']) ?? e['source_id']} (${e['label']})',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: e['dashed'] == true
                      ? AppPalette.sky700
                      : AppPalette.slate800,
                ),
              ),
            ),
      ],
    );
  }
}

class _AiNetworkTopologyPainter extends CustomPainter {
  final List<Map<String, dynamic>> zones;
  final List<Map<String, dynamic>> nodes;
  final List<Map<String, dynamic>> edges;
  final String? selectedNodeId;
  final bool showAllEdgeLabels;

  _AiNetworkTopologyPainter({
    required this.zones,
    required this.nodes,
    required this.edges,
    required this.selectedNodeId,
    required this.showAllEdgeLabels,
  });

  Color _hex(String raw, Color fallback) {
    final c = raw.replaceAll('#', '').trim();
    if (c.length == 6) {
      final v = int.tryParse('FF$c', radix: 16);
      if (v != null) return Color(v);
    }
    return fallback;
  }

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Pintar bandas de Zonas (5 niveles Norte -> Sur)
    for (final z in zones) {
      final col =
          _hex((z['color_hex'] ?? '#2563EB').toString(), AppPalette.blue600);
      final rect = Rect.fromLTWH(
        ((z['x'] ?? 0) as num).toDouble(),
        ((z['y'] ?? 0) as num).toDouble(),
        ((z['width'] ?? 1400) as num).toDouble(),
        ((z['height'] ?? 160) as num).toDouble(),
      );
      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(10));
      canvas.drawRRect(
        rrect,
        Paint()..color = col.withValues(alpha: 0.045),
      );
      canvas.drawRRect(
        rrect,
        Paint()
          ..color = col.withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4,
      );

      final tp = TextPainter(
        text: TextSpan(
          text: '${z['title']}  —  ${z['subtitle']}',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w800,
            color: col,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: rect.width - 24);
      tp.paint(canvas, Offset(rect.left + 14, rect.top + 11));
    }

    // 2. Pintar curvas Bézier ancladas a los bordes reales (Norte-Sur / Este-Oeste)
    final nodeMap = {
      for (final n in nodes) (n['id'] ?? '').toString(): n,
    };
    final hasSelection = selectedNodeId != null;

    // Dibujar primero las aristas no seleccionadas y al final las resaltadas (encima)
    final sortedEdges = List<Map<String, dynamic>>.from(edges)
      ..sort((a, b) {
        final aSel = hasSelection &&
            (a['source_id'] == selectedNodeId ||
                a['target_id'] == selectedNodeId);
        final bSel = hasSelection &&
            (b['source_id'] == selectedNodeId ||
                b['target_id'] == selectedNodeId);
        if (aSel == bSel) return 0;
        return aSel ? 1 : -1;
      });

    for (final e in sortedEdges) {
      final s = nodeMap[e['source_id']];
      final t = nodeMap[e['target_id']];
      if (s == null || t == null) continue;

      final sLeft = ((s['x'] ?? 0) as num).toDouble();
      final sTop = ((s['y'] ?? 0) as num).toDouble();
      final sW = ((s['width'] ?? 232) as num).toDouble();
      final sH = ((s['height'] ?? 84) as num).toDouble();

      final tLeft = ((t['x'] ?? 0) as num).toDouble();
      final tTop = ((t['y'] ?? 0) as num).toDouble();
      final tW = ((t['width'] ?? 232) as num).toDouble();
      final tH = ((t['height'] ?? 84) as num).toDouble();

      final sCx = sLeft + sW / 2;
      final sCy = sTop + sH / 2;
      final tCx = tLeft + tW / 2;
      final tCy = tTop + tH / 2;

      late Offset p1;
      late Offset p2;
      late Offset c1;
      late Offset c2;

      if ((sCy - tCy).abs() <= 22.0) {
        // Misma fila horizontal (ej. LACP Core A <-> Core B)
        final leftToRight = sCx <= tCx;
        if ((sCx - tCx).abs() <= sW + 50) {
          p1 = Offset(leftToRight ? sLeft + sW : sLeft, sCy);
          p2 = Offset(leftToRight ? tLeft : tLeft + tW, tCy);
          c1 = Offset((p1.dx + p2.dx) / 2, p1.dy);
          c2 = Offset((p1.dx + p2.dx) / 2, p2.dy);
        } else {
          // Arco limpio superior para no cruzar cajas intermedias de la fila
          p1 = Offset(sCx, sTop);
          p2 = Offset(tCx, tTop);
          final archY = math.min(sTop, tTop) - 28.0;
          c1 = Offset(sCx, archY);
          c2 = Offset(tCx, archY);
        }
      } else if (tCy > sCy) {
        // Flujo Norte -> Sur: borde inferior del padre al borde superior del hijo
        p1 = Offset(sCx, sTop + sH);
        p2 = Offset(tCx, tTop);
        final midY = (p1.dy + p2.dy) / 2;
        c1 = Offset(p1.dx, midY);
        c2 = Offset(p2.dx, midY);
      } else {
        // Flujo Sur -> Norte
        p1 = Offset(sCx, sTop);
        p2 = Offset(tCx, tTop + tH);
        final midY = (p1.dy + p2.dy) / 2;
        c1 = Offset(p1.dx, midY);
        c2 = Offset(p2.dx, midY);
      }

      final isRelated = hasSelection &&
          (e['source_id'] == selectedNodeId ||
              e['target_id'] == selectedNodeId);
      final bundleCnt = ((e['bundle_count'] ?? 1) as num).toInt();
      final baseCol =
          _hex((e['color_hex'] ?? '#2563EB').toString(), AppPalette.blue600);
      final alpha = hasSelection ? (isRelated ? 0.98 : 0.16) : 0.72;
      final drawCol = baseCol.withValues(alpha: alpha);

      final strokeW = isRelated
          ? 3.0
          : (bundleCnt >= 2 ? 2.5 : (e['edge_kind'] == 'subnet_l3' ? 1.5 : 1.9));
      final paint = Paint()
        ..color = drawCol
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeW;

      final path = Path()
        ..moveTo(p1.dx, p1.dy)
        ..cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);

      if (e['dashed'] == true) {
        for (final metric in path.computeMetrics()) {
          double dist = 0.0;
          while (dist < metric.length) {
            final next = math.min(dist + 6.5, metric.length);
            canvas.drawPath(metric.extractPath(dist, next), paint);
            dist += 11.5;
          }
        }
      } else {
        canvas.drawPath(path, paint);
      }

      // Punta de flecha direccional en p2
      final angle = math.atan2(p2.dy - c2.dy, p2.dx - c2.dx);
      const arrowLen = 7.5;
      final a1 = Offset(
        p2.dx - arrowLen * math.cos(angle - 0.45),
        p2.dy - arrowLen * math.sin(angle - 0.45),
      );
      final a2 = Offset(
        p2.dx - arrowLen * math.cos(angle + 0.45),
        p2.dy - arrowLen * math.sin(angle + 0.45),
      );
      final arrowPath = Path()
        ..moveTo(p2.dx, p2.dy)
        ..lineTo(a1.dx, a1.dy)
        ..lineTo(a2.dx, a2.dy)
        ..close();
      canvas.drawPath(arrowPath, Paint()..color = drawCol);

      // Mostrar etiquetas sin saturación visual: siempre si pocas aristas, si `showAllEdgeLabels`,
      // si la arista pertenece al nodo seleccionado o si es un troncal agregado/gateway.
      final lbl = (e['label'] ?? '').toString();
      final shouldDrawLabel = lbl.isNotEmpty &&
          (showAllEdgeLabels ||
              edges.length <= 18 ||
              isRelated ||
              (!hasSelection &&
                  (bundleCnt >= 2 && lbl.contains('LACP') ||
                      lbl.startsWith('GW '))));

      if (shouldDrawLabel) {
        final mx = 0.125 * p1.dx + 0.375 * c1.dx + 0.375 * c2.dx + 0.125 * p2.dx;
        final my = 0.125 * p1.dy + 0.375 * c1.dy + 0.375 * c2.dy + 0.125 * p2.dy;
        final tp = TextPainter(
          text: TextSpan(
            text: lbl,
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              color: isRelated ? AppPalette.slate900 : AppPalette.slate700,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final pill = RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(mx, my),
            width: tp.width + 10,
            height: tp.height + 5,
          ),
          const Radius.circular(4),
        );
        canvas.drawRRect(pill, Paint()..color = Colors.white);
        canvas.drawRRect(
          pill,
          Paint()
            ..color = baseCol.withValues(alpha: 0.75)
            ..style = PaintingStyle.stroke
            ..strokeWidth = isRelated ? 1.4 : 1.0,
        );
        tp.paint(canvas, Offset(mx - tp.width / 2, my - tp.height / 2));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _AiNetworkTopologyPainter oldDelegate) {
    return oldDelegate.nodes != nodes ||
        oldDelegate.edges != edges ||
        oldDelegate.selectedNodeId != selectedNodeId ||
        oldDelegate.showAllEdgeLabels != showAllEdgeLabels;
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  final bool dashed;

  const _LegendDot({
    required this.color,
    required this.label,
    this.dashed = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 16,
          height: 3.5,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        if (dashed) ...[
          const SizedBox(width: 2),
          Container(width: 5, height: 3.5, color: color),
        ],
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: AppPalette.slate700,
          ),
        ),
      ],
    );
  }
}
