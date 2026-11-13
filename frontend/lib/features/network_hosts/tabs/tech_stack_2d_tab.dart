part of '../network_hosts_view.dart';

/// Pestaña 1 de `4. Red & Host`: lienzo arquitectónico 2D de Stacks Tecnológicos,
/// zonas delimitadoras, nodos arrastrables, enlaces y ventana técnica flotante.
extension _NetworkHostsTechStack2dTabExt on _NetworkHostsViewState {
  // ===========================================================================
  // TAB 1: STACKS TECNOLÓGICOS & LÓGICA DE NEGOCIO (ESTILO DATACENTER FLOOR:
  // LIENZO 2D LIBRE + CAJAS CON TEXTO EN ESQUINA + ENLACES LIBRES + VENTANA FLOTANTE MOVIBLE + PANEL SETTINGS)
  // ===========================================================================

  Map<String, dynamic> get _activeStack {
    final stacks = _techStacks;
    return stacks.firstWhere(
      (s) => s['id'] == _selectedStackId,
      orElse: () => stacks.isNotEmpty ? stacks.first : <String, dynamic>{},
    );
  }

  Future<void> _persistStackBoxesAndScale({
    List<Map<String, dynamic>>? boxes,
    double? mapScale,
  }) async {
    final st = _activeStack;
    final stId = st['id'] as int?;
    if (stId == null) return;
    try {
      final res = await widget.api.updateTechStackDiagram(stId, {
        'canvas_boxes': ?boxes,
        'map_scale': ?mapScale,
      });
      if (mounted) {
        _rebuildState(() {
          _overview = res;
          _syncStackCanvasState();
        });
      }
    } catch (e) {
      _showSnack('Error al guardar lienzo del Stack: $e', isError: true);
    }
  }

  DiagramExportDocument _buildCurrentStackExportDocument() {
    final activeStack = _activeStack;
    final stackName = (activeStack['name'] ?? 'Topología Red & Hosts').toString();
    final stackCode = (activeStack['code'] ?? 'STACK').toString();
    final rawNodes = ((activeStack['nodes'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final rawEdges = ((activeStack['edges'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    const double canvasW = 1400.0;
    const double canvasH = 860.0;

    final zones = <DiagramExportZone>[
      for (final box in _stackBoxes)
        DiagramExportZone(
          id: (box['id'] ?? 'zone').toString(),
          title: (box['title'] ?? 'Zona').toString(),
          subtitle: (box['subtitle'] ?? '').toString(),
          x: ((box['x'] as num?)?.toDouble() ?? 0.08) * canvasW,
          y: ((box['y'] as num?)?.toDouble() ?? 0.10) * canvasH,
          width: (((box['w'] as num?)?.toDouble() ?? 0.35) * canvasW)
              .clamp(160.0, canvasW),
          height: (((box['h'] as num?)?.toDouble() ?? 0.35) * canvasH)
              .clamp(120.0, canvasH),
          colorHex: (box['color_hex'] ?? '#0EA5E9').toString(),
        ),
    ];

    final exportNodes = <DiagramExportNode>[];
    for (int i = 0; i < rawNodes.length; i++) {
      final n = rawNodes[i];
      final nid = 'node_${n['id']}';
      final pos = _stackNodePositions[n['id'] as int? ?? -1];
      final normX = pos?.dx ?? (n['pos_x'] as num?)?.toDouble() ?? (0.12 + (i % 5) * 0.17);
      final normY = pos?.dy ?? (n['pos_y'] as num?)?.toDouble() ?? (0.16 + (i ~/ 5) * 0.22);
      final hostInfo = n['host'] is Map
          ? Map<String, dynamic>.from(n['host'] as Map)
          : <String, dynamic>{};
      final code = (n['code'] ?? hostInfo['code'] ?? 'N-${n['id']}').toString();
      final name = (n['label'] ?? n['name'] ?? hostInfo['name'] ?? code).toString();
      final ip = (n['ip_address'] ?? hostInfo['ip_address'] ?? '').toString();
      final modelName = (n['model_name'] ?? hostInfo['model_name'] ?? '').toString();
      final serialNumber =
          (n['serial_or_uuid'] ?? hostInfo['serial_or_uuid'] ?? '').toString();
      final status = (n['status'] ?? hostInfo['status'] ?? 'online').toString();
      final category =
          (n['node_type'] ?? hostInfo['host_type'] ?? 'host').toString();

      exportNodes.add(
        DiagramExportNode(
          id: nid,
          code: code,
          name: name,
          subtitle: category.toUpperCase(),
          ip: ip,
          modelName: modelName,
          serialNumber: serialNumber,
          status: status,
          x: (normX * (canvasW - 210)).clamp(20.0, canvasW - 200),
          y: (normY * (canvasH - 120)).clamp(20.0, canvasH - 100),
          width: 195,
          height: 82,
          colorHex: status == 'offline'
              ? '#DC2626'
              : (status == 'warning' ? '#D97706' : '#0284C7'),
        ),
      );
    }

    final exportEdges = <DiagramExportEdge>[];
    for (int i = 0; i < rawEdges.length; i++) {
      final e = rawEdges[i];
      final srcId = 'node_${e['source_node_id']}';
      final dstId = 'node_${e['target_node_id']}';
      final protocol = (e['protocol'] ?? e['edge_type'] ?? '').toString();
      final port = e['port'] != null ? ':${e['port']}' : '';
      final lbl = (e['label'] ?? '$protocol$port').toString().trim();
      exportEdges.add(
        DiagramExportEdge(
          id: 'edge_${e['id'] ?? i}',
          sourceId: srcId,
          targetId: dstId,
          label: lbl.isEmpty ? 'LINK' : lbl,
          detail: protocol.isEmpty ? 'TCP/IP' : protocol.toUpperCase(),
          colorHex: (e['color_hex'] ?? '#0284C7').toString(),
          dashed: (e['edge_type'] ?? '').toString().contains('logical'),
        ),
      );
    }

    return DiagramExportDocument(
      moduleName: '4. Red & Host',
      title: 'Red & Host — $stackName',
      subtitle:
          'Stack: $stackCode • ${exportNodes.length} Nodos • ${exportEdges.length} Enlaces Lógicos/Físicos',
      fileBaseName: 'esquema_red_host_${stackCode.toLowerCase()}',
      canvasWidth: canvasW,
      canvasHeight: canvasH,
      zones: zones,
      nodes: exportNodes,
      edges: exportEdges,
    );
  }

  Widget _buildTechStacksCanvasTab() {
    final stacks = _techStacks;
    final activeStack = _activeStack;
    final nodes = ((activeStack['nodes'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final edges = ((activeStack['edges'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    final selectedNode = nodes.firstWhere(
      (n) => n['id'] == _selectedStackNodeId,
      orElse: () => nodes.isNotEmpty ? nodes.first : <String, dynamic>{},
    );

    return Column(
      children: [
        // Barra superior estilo Datacenter Dashboard
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: const BoxDecoration(
            color: AppTheme.bgCard,
            border: Border(bottom: BorderSide(color: AppTheme.border)),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _rebuildState(
                      () => _showStackLeftLibrary = !_showStackLeftLibrary,
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      backgroundColor: _showStackLeftLibrary
                          ? AppTheme.accentBlue.withValues(alpha: 0.14)
                          : null,
                    ),
                    icon: const Icon(Icons.widgets_outlined, size: 14),
                    label: Text(
                      _showStackLeftLibrary ? 'Library: ON' : 'Library: OFF',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.layers_rounded,
                    size: 17,
                    color: AppTheme.accentCyan,
                  ),
                  const SizedBox(width: 6),
                  if (stacks.isNotEmpty)
                    DropdownButton<int>(
                      value: activeStack['id'] as int?,
                      dropdownColor: AppTheme.bgElevated,
                      underline: const SizedBox.shrink(),
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: AppTheme.accentBlue,
                      ),
                      items: stacks
                          .map(
                            (st) => DropdownMenuItem<int>(
                              value: st['id'] as int,
                              child: Text(
                                '${st['name']} (${st['nodes_count']} elem.)',
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => _rebuildState(() {
                        _selectedStackId = v;
                        _selectedStackNodeId = null;
                        _selectedBoxId = null;
                        _isLinkModeActive = false;
                        _linkSourceNodeId = null;
                        _syncStackCanvasState();
                      }),
                    ),
                  if (widget.canEdit) ...[
                    const SizedBox(width: 4),
                    IconButton(
                      tooltip: 'Crear nuevo Stack Tecnológico',
                      icon: const Icon(
                        Icons.create_new_folder_rounded,
                        size: 16,
                        color: AppTheme.accentCyan,
                      ),
                      onPressed: _showCreateTechStackDialog,
                    ),
                  ],
                ],
              ),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  // Toggle Ver Conexiones
                  OutlinedButton.icon(
                    onPressed: () =>
                        _rebuildState(() => _showStackEdges = !_showStackEdges),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 6,
                      ),
                      backgroundColor: _showStackEdges
                          ? AppTheme.accentCyan.withValues(alpha: 0.14)
                          : null,
                    ),
                    icon: const Icon(Icons.hub_rounded, size: 14),
                    label: Text(
                      _showStackEdges
                          ? 'Enlaces (${edges.length}): ON'
                          : 'Enlaces: OFF',
                      style: const TextStyle(
                        fontSize: 10.8,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  DiagramExportMenuButton(
                    documentBuilder: _buildCurrentStackExportDocument,
                    darkStyle: true,
                  ),
                  if (widget.canEdit && activeStack.isNotEmpty) ...[
                    // Modo Enlazar interactivo (clic origen -> clic destino en cualquier dirección)
                    ElevatedButton.icon(
                      onPressed: () {
                        _rebuildState(() {
                          _isLinkModeActive = !_isLinkModeActive;
                          _linkSourceNodeId = _isLinkModeActive
                              ? _selectedStackNodeId
                              : null;
                        });
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isLinkModeActive
                            ? AppTheme.warning
                            : AppTheme.bgElevated,
                        foregroundColor: _isLinkModeActive
                            ? Colors.black
                            : AppTheme.textPrimary,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                      ),
                      icon: const Icon(Icons.add_link_rounded, size: 15),
                      label: Text(
                        _isLinkModeActive
                            ? (_linkSourceNodeId == null
                                  ? '🔗 1º Clic en Origen...'
                                  : '🔗 2º Clic en Destino...')
                            : '🔗 Enlazar Elementos',
                        style: const TextStyle(
                          fontSize: 10.8,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    // Añadir Caja / Zona dibujable con texto en esquina superior
                    OutlinedButton.icon(
                      onPressed: () => _showAddOrEditStackZoneBoxDialog(),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                      ),
                      icon: const Icon(
                        Icons.select_all_rounded,
                        size: 14,
                        color: AppTheme.accentPurple,
                      ),
                      label: const Text(
                        '+ Caja / Zona con Datos',
                        style: TextStyle(
                          fontSize: 10.8,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    // Añadir Elemento / Host estilo Datacenter
                    ElevatedButton.icon(
                      onPressed: () =>
                          _showCreateVirtualMachineWithServicesDialog(
                            attachToCurrentStack: true,
                          ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.accentBlue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                      ),
                      icon: const Icon(Icons.add_circle_outline, size: 14),
                      label: const Text(
                        '+ Añadir Elemento / Host',
                        style: TextStyle(
                          fontSize: 10.8,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                  // Modo Mano (Pan) y Escala estilo Datacenter
                  OutlinedButton.icon(
                    onPressed: () => _rebuildState(
                      () => _isStackHandMode = !_isStackHandMode,
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 6,
                      ),
                      backgroundColor: _isStackHandMode
                          ? AppTheme.accentTeal.withValues(alpha: 0.16)
                          : null,
                    ),
                    icon: const Icon(Icons.pan_tool_alt_rounded, size: 14),
                    label: Text(
                      _isStackHandMode ? 'Mano: ON' : 'Mano',
                      style: const TextStyle(
                        fontSize: 10.8,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  // Botón para mostrar/ocultar la Ventana Flotante Movible de Datos Técnicos y Gráficas
                  OutlinedButton.icon(
                    onPressed: () => _rebuildState(() {
                      _showFloatingTechWindow = !_showFloatingTechWindow;
                      if (_showFloatingTechWindow &&
                          _selectedStackNodeId == null &&
                          nodes.isNotEmpty) {
                        _selectedStackNodeId = nodes.first['id'] as int;
                        final h = Map<String, dynamic>.from(
                          (nodes.first['host'] as Map?) ?? {},
                        );
                        if (h['id'] != null) {
                          _selectedHostId = h['id'] as int;
                          _loadHostTelemetry(_selectedHostId!);
                        }
                      }
                    }),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 6,
                      ),
                      backgroundColor: _showFloatingTechWindow
                          ? AppTheme.accentTeal.withValues(alpha: 0.15)
                          : null,
                    ),
                    icon: const Icon(
                      Icons.analytics_outlined,
                      size: 14,
                      color: AppTheme.accentTeal,
                    ),
                    label: Text(
                      _showFloatingTechWindow
                          ? '📊 Ventana Flotante: ON'
                          : '📊 Ventana Flotante',
                      style: const TextStyle(
                        fontSize: 10.8,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  // Toggle Panel Derecho Settings (igual que en Datacenter)
                  OutlinedButton.icon(
                    onPressed: () => _rebuildState(
                      () => _showStackRightSettings = !_showStackRightSettings,
                    ),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 6,
                      ),
                      backgroundColor: _showStackRightSettings
                          ? AppTheme.accentBlue.withValues(alpha: 0.14)
                          : null,
                    ),
                    icon: const Icon(Icons.tune_rounded, size: 14),
                    label: Text(
                      _showStackRightSettings ? 'Settings: ON' : 'Settings',
                      style: const TextStyle(
                        fontSize: 10.8,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        // Cuerpo en 3 columnas idéntico al Dashboard de Datacenter:
        // [Left Elements Library] + [Central 2D Architectural Grid Canvas + Floating Window] + [Right Settings Panel]
        Expanded(
          child: activeStack.isEmpty
              ? const Center(
                  child: Text('Crea un Stack Tecnológico para empezar'),
                )
              : Row(
                  children: [
                    if (_showStackLeftLibrary)
                      SelectionContainer.disabled(
                        child: _buildStackLeftLibraryPanel(activeStack, nodes),
                      ),
                    Expanded(
                      child: SelectionContainer.disabled(
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                          return DragTarget<String>(
                            onWillAcceptWithDetails: (_) => widget.canEdit,
                            onAcceptWithDetails: (details) async {
                              final box =
                                  _stackCanvasKey.currentContext
                                          ?.findRenderObject()
                                      as RenderBox?;
                              Offset rel = const Offset(0.35, 0.35);
                              if (box != null) {
                                final local = box.globalToLocal(details.offset);
                                rel = Offset(
                                  (local.dx / box.size.width).clamp(0.02, 0.86),
                                  (local.dy / box.size.height).clamp(
                                    0.03,
                                    0.84,
                                  ),
                                );
                              }
                              await _handleStackCanvasDrop(
                                details.data,
                                rel,
                                activeStack['id'] as int,
                              );
                            },
                            builder: (context, candidateData, rejectedData) {
                              return MouseRegion(
                                onHover: (event) {
                                  if (_isLinkModeActive &&
                                      _linkSourceNodeId != null) {
                                    _rebuildState(() {
                                      _linkLiveMousePos = event.localPosition;
                                    });
                                  }
                                },
                                child: GestureDetector(
                                  behavior: HitTestBehavior.translucent,
                                  onTap: () {
                                    _rebuildState(() {
                                      if (_isLinkModeActive) {
                                        _isLinkModeActive = false;
                                        _linkSourceNodeId = null;
                                        _linkSourceSide = null;
                                        _linkLiveMousePos = null;
                                      } else {
                                        _selectedBoxId = null;
                                      }
                                    });
                                  },
                                  child: Container(
                                    key: _stackCanvasKey,
                                    width: constraints.maxWidth,
                                    height: constraints.maxHeight,
                                    color: AppTheme.bgPrimary,
                                    child: Stack(
                                      clipBehavior: Clip.none,
                                      children: [
                                        // 0. Cuadrícula arquitectónica libre estilo Datacenter (IgnorePointer para no bloquear eventos)
                                        Positioned.fill(
                                          child: IgnorePointer(
                                            child: CustomPaint(
                                              painter:
                                                  _StackArchitecturalGridPainter(
                                                    scale: _stackCanvasScale,
                                                  ),
                                            ),
                                          ),
                                        ),
                                        // 1. Cajas / Zonas seleccionables, redimensionables y arrastrables con el ratón + borrar en "X" superior izquierda
                                        for (final zBox in _stackBoxes)
                                          _buildStackCanvasZoneBox(
                                            zBox: zBox,
                                            canvasWidth: constraints.maxWidth,
                                            canvasHeight: constraints.maxHeight,
                                          ),
                                        // 2. Flechas de unión multi-dirección + Flecha en vivo desde los cuadrados laterales (IgnorePointer para no tapar cajas)
                                        if (_showStackEdges || _isLinkModeActive)
                                          Positioned.fill(
                                            child: IgnorePointer(
                                              child: CustomPaint(
                                                painter: _TechStackEdgesPainter(
                                                  nodes: nodes,
                                                  edges: _showStackEdges
                                                      ? edges
                                                      : const [],
                                                  nodePositions:
                                                      _stackNodePositions,
                                                  nodeSizes: _stackNodeSizes,
                                                  canvasSize: Size(
                                                    constraints.maxWidth,
                                                    constraints.maxHeight,
                                                  ),
                                                  liveSourceNodeId:
                                                      _isLinkModeActive
                                                      ? _linkSourceNodeId
                                                      : null,
                                                  liveSourceSide:
                                                      _linkSourceSide,
                                                  liveMousePos:
                                                      _linkLiveMousePos,
                                                  hoveredTargetNodeId:
                                                      _hoveredSideNodeId,
                                                  hoveredTargetSide:
                                                      _hoveredSideName,
                                                ),
                                              ),
                                            ),
                                          ),
                                        if (_showStackEdges)
                                          ..._buildEdgeInteractivePills(
                                            nodes: nodes,
                                            edges: edges,
                                            canvasWidth: constraints.maxWidth,
                                            canvasHeight: constraints.maxHeight,
                                          ),
                                        // 3. Elementos / Nodos libremente arrastrables (1:1 con ratón), redimensionables y con 4 cuadrados laterales de enlace
                                        for (final sn in nodes)
                                          _buildDraggableStackNodeCard(
                                            sn: sn,
                                            allNodes: nodes,
                                            canvasWidth: constraints.maxWidth,
                                            canvasHeight: constraints.maxHeight,
                                          ),
                                        // 4. Banner de ayuda cuando el Modo Enlazar o un cuadrado lateral está activo
                                        if (_isLinkModeActive)
                                          Positioned(
                                            top: 10,
                                            left: 16,
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 12,
                                                    vertical: 7,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: AppTheme.warning,
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                                boxShadow: const [
                                                  BoxShadow(
                                                    color: Colors.black26,
                                                    blurRadius: 8,
                                                  ),
                                                ],
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  const Icon(
                                                    Icons.link_rounded,
                                                    size: 16,
                                                    color: Colors.black,
                                                  ),
                                                  const SizedBox(width: 6),
                                                  Text(
                                                    _linkSourceNodeId == null
                                                        ? 'MODO ENLAZAR: Haz clic en un cuadrado lateral (o elemento) ORIGEN'
                                                        : 'FLECHA DE UNIÓN ACTIVA (${_linkSourceSide?.toUpperCase() ?? "AUTO"}): Haz clic o suelta en cualquier cuadrado lateral o elemento DESTINO',
                                                    style: const TextStyle(
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w900,
                                                      color: Colors.black,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  InkWell(
                                                    onTap: () => _rebuildState(() {
                                                      _isLinkModeActive = false;
                                                      _linkSourceNodeId = null;
                                                      _linkSourceSide = null;
                                                      _linkLiveMousePos = null;
                                                    }),
                                                    child: const Icon(
                                                      Icons.close,
                                                      size: 15,
                                                      color: Colors.black87,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                      // 5. Ventana Flotante Movible con Datos Técnicos, SSH y Gráficas Prometheus Afinadas
                                      if (_showFloatingTechWindow &&
                                          selectedNode.isNotEmpty)
                                        _buildFloatingTechnicalAndChartsWindow(
                                          sn: selectedNode,
                                          canvasWidth: constraints.maxWidth,
                                          canvasHeight: constraints.maxHeight,
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        );
                        },
                      ),
                    ),
                  ),
                    if (_showStackRightSettings)
                      _buildStackRightSettingsPanel(
                        activeStack: activeStack,
                        nodes: nodes,
                        edges: edges,
                        selectedNode: selectedNode,
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  // ===========================================================================
  // PANEL IZQUIERDO ESTILO DATACENTER: ELEMENTS & HOSTS LIBRARY (DRAG & DROP)
  // ===========================================================================

  Widget _buildStackLeftLibraryPanel(
    Map<String, dynamic> activeStack,
    List<Map<String, dynamic>> currentNodes,
  ) {
    final stackId = activeStack['id'] as int;
    final inStackAssetIds = currentNodes
        .map((n) => (n['host'] as Map?)?['id'] as int?)
        .whereType<int>()
        .toSet();

    final zoneTemplates = [
      (
        'box:dmz',
        'Caja Zona DMZ / Perímetro',
        'VLAN 10 • 10.10.0.0/24 • WAF/LB',
        '#0EA5E9',
        Icons.shield_outlined,
      ),
      (
        'box:app',
        'Caja Clúster Frontales & Apps',
        'VLAN 20 • VMware/Proxmox HA • K8s',
        '#6366F1',
        Icons.dns_rounded,
      ),
      (
        'box:db',
        'Caja Zona Datos & Storage',
        'VLAN 30 • PostgreSQL / Redis HA',
        '#14B8A6',
        Icons.storage_rounded,
      ),
    ];

    final elementTemplates = [
      (
        'tpl:virtual_machine',
        'Máquina Virtual (VM)',
        'VMware / Proxmox / Hyper-V',
        Icons.computer_rounded,
        AppTheme.accentBlue,
      ),
      (
        'tpl:container',
        'Contenedor / Pod / Servicio Web',
        'Docker / Kubernetes / LXC',
        Icons.view_in_ar_rounded,
        AppTheme.accentPurple,
      ),
      (
        'tpl:vip_cluster',
        'Balanceador / VIP / API Gateway',
        'HAProxy / Nginx / Keepalived',
        Icons.alt_route_rounded,
        AppTheme.accentCyan,
      ),
      (
        'tpl:database',
        'Motor Base de Datos / Caché',
        'PostgreSQL / MySQL / Redis',
        Icons.table_chart_rounded,
        AppTheme.accentTeal,
      ),
      (
        'tpl:physical_server',
        'Servidor Físico / Barebone',
        'Host Físico o Servidor Dedicado',
        Icons.dns_outlined,
        AppTheme.success,
      ),
    ];

    return Container(
      width: 255,
      decoration: const BoxDecoration(
        color: AppTheme.bgCard,
        border: Border(right: BorderSide(color: AppTheme.border)),
      ),
      child: ListView(
        padding: const EdgeInsets.all(10),
        children: [
          const Text(
            'ELEMENTS & ZONES LIBRARY',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w900,
              color: AppTheme.textPrimary,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 3),
          const Text(
            'Arrastra al lienzo o pulsa + para añadir cajas con texto o elementos libres.',
            style: TextStyle(fontSize: 10, color: AppTheme.textMuted),
          ),
          const SizedBox(height: 10),
          // 1. Cajas / Zonas agrupadoras con datos en esquina superior
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'CAJAS / ZONAS CON TEXTO',
                style: TextStyle(
                  fontSize: 9.8,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.accentPurple,
                ),
              ),
              InkWell(
                onTap: () => _showAddOrEditStackZoneBoxDialog(),
                child: const Text(
                  '+ Personalizada',
                  style: TextStyle(
                    fontSize: 9.8,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.accentBlue,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final z in zoneTemplates)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Draggable<String>(
                data: z.$1,
                feedback: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.bgSecondary,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.accentPurple),
                    ),
                    child: Text(
                      z.$2,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                child: InkWell(
                  onTap: () => _handleStackCanvasDrop(
                    z.$1,
                    const Offset(0.08, 0.12),
                    stackId,
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.bgSecondary,
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: AppTheme.border),
                    ),
                    child: Row(
                      children: [
                        Icon(z.$5, size: 15, color: AppTheme.accentPurple),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                z.$2,
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                z.$3,
                                style: const TextStyle(
                                  fontSize: 9,
                                  color: AppTheme.textMuted,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const Icon(
                          Icons.add_circle_outline,
                          size: 14,
                          color: AppTheme.accentPurple,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          const Divider(height: 18),
          // 2. Nuevos Elementos / Sistemas
          const Text(
            'NUEVOS ELEMENTOS / HOSTS',
            style: TextStyle(
              fontSize: 9.8,
              fontWeight: FontWeight.w800,
              color: AppTheme.accentCyan,
            ),
          ),
          const SizedBox(height: 6),
          for (final tpl in elementTemplates)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Draggable<String>(
                data: tpl.$1,
                feedback: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.bgSecondary,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: tpl.$5),
                    ),
                    child: Text(
                      tpl.$2,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                child: InkWell(
                  onTap: () => _showCreateVirtualMachineWithServicesDialog(
                    attachToCurrentStack: true,
                    initialAssetClass: tpl.$1.replaceFirst('tpl:', ''),
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.bgSecondary,
                      borderRadius: BorderRadius.circular(7),
                      border: Border.all(color: AppTheme.border),
                    ),
                    child: Row(
                      children: [
                        Icon(tpl.$4, size: 15, color: tpl.$5),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                tpl.$2,
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              Text(
                                tpl.$3,
                                style: const TextStyle(
                                  fontSize: 9,
                                  color: AppTheme.textMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          Icons.add_circle_outline,
                          size: 14,
                          color: tpl.$5,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          const Divider(height: 18),
          // 3. Hosts ya registrados en CMDB / Red & Host para arrastrar o añadir al Stack
          Row(
            children: [
              Expanded(
                child: Text(
                  'HOSTS EN CMDB (${_hosts.length})',
                  style: const TextStyle(
                    fontSize: 9.8,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.accentTeal,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (widget.canEdit)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 7,
                    ),
                    backgroundColor: AppTheme.accentTeal.withValues(
                      alpha: 0.08,
                    ),
                    side: const BorderSide(color: AppTheme.accentTeal),
                  ),
                  onPressed: () async {
                    final picked = await CmdbAssetExplorerDialog.show(
                      context,
                      api: widget.api,
                      contextMode: 'stack',
                      alreadyInStackAssetIds: inStackAssetIds
                          .whereType<int>()
                          .toSet(),
                      title:
                          'Añadir Equipo desde CMDB al Stack (Agrupado por Redes / Máscara)',
                      subtitle:
                          'Selecciona una Subred / Máscara CIDR en la columna izquierda y elige el equipo a incorporar en este Stack.',
                    );
                    if (picked != null && picked['id'] != null) {
                      await _handleStackCanvasDrop(
                        'host:${picked['id']}',
                        const Offset(0.32, 0.32),
                        stackId,
                      );
                    }
                  },
                  icon: const Icon(
                    Icons.account_tree_rounded,
                    size: 14,
                    color: AppTheme.accentTeal,
                  ),
                  label: const Text(
                    'Explorar por Redes / Subredes',
                    style: TextStyle(
                      fontSize: 10.2,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.accentTeal,
                    ),
                  ),
                ),
              ),
            ),
          for (final h in _hosts.take(25))
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Draggable<String>(
                data: 'host:${h['id']}',
                feedback: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.bgSecondary,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.accentTeal),
                    ),
                    child: Text(
                      '${h['code']} (${h['heartbeat_ip']})',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: inStackAssetIds.contains(h['id'])
                        ? AppTheme.accentTeal.withValues(alpha: 0.08)
                        : AppTheme.bgSecondary,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: inStackAssetIds.contains(h['id'])
                          ? AppTheme.accentTeal.withValues(alpha: 0.4)
                          : AppTheme.border,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.circle,
                        size: 7,
                        color: _nagiosStateColor(
                          (h['nagios_host_state'] as String?) ?? 'UP',
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${h['code']}',
                              style: const TextStyle(
                                fontSize: 10.2,
                                fontWeight: FontWeight.w800,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '${h['heartbeat_ip']} • ${h['name']}',
                              style: const TextStyle(
                                fontSize: 8.8,
                                color: AppTheme.textMuted,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      if (widget.canEdit)
                        InkWell(
                          onTap: () => _handleStackCanvasDrop(
                            'host:${h['id']}',
                            const Offset(0.32, 0.32),
                            stackId,
                          ),
                          child: const Icon(
                            Icons.add_box_outlined,
                            size: 14,
                            color: AppTheme.accentTeal,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _handleStackCanvasDrop(
    String data,
    Offset relPos,
    int stackId,
  ) async {
    if (data.startsWith('box:')) {
      final kind = data.substring(4);
      final Map<String, (String, String, String)> presets = {
        'dmz': (
          'ZONA PERÍMETRO / DMZ / BALANCEO',
          'VLAN 10 • 10.10.0.0/24 • HAProxy / WAF',
          '#0EA5E9',
        ),
        'app': (
          'CLÚSTER APLICACIONES & FRONTALES WEB',
          'VLAN 20 • VMware vSphere / Proxmox HA • 10.20.20.0/24',
          '#6366F1',
        ),
        'db': (
          'ZONA BASES DE DATOS & CACHÉ',
          'VLAN 30 • PostgreSQL 16 + Redis Cluster • Backup Diario',
          '#14B8A6',
        ),
      };
      final p = presets[kind] ?? ('NUEVA ZONA / CAJA', 'Datos técnicos', '#0EA5E9');
      final newBox = <String, dynamic>{
        'id': 'box-${DateTime.now().millisecondsSinceEpoch}',
        'title': p.$1,
        'corner_data': p.$2,
        'pos_x': relPos.dx.clamp(0.02, 0.72),
        'pos_y': relPos.dy.clamp(0.03, 0.70),
        'width_rel': 0.36,
        'height_rel': 0.42,
        'color_hex': p.$3,
      };
      final updated = [..._stackBoxes, newBox];
      _rebuildState(() {
        _stackBoxes = updated;
        _selectedBoxId = newBox['id'] as String;
      });
      await _persistStackBoxesAndScale(boxes: updated);
      return;
    }

    if (data.startsWith('host:')) {
      final hostId = int.tryParse(data.substring(5));
      if (hostId == null) return;
      final hostObj = _hosts.firstWhere(
        (h) => h['id'] == hostId,
        orElse: () => <String, dynamic>{},
      );
      if (hostObj.isEmpty) return;
      final res = await widget.api.createTechStackNode({
        'stack_id': stackId,
        'asset_id': hostId,
        'role_layer': 'app_middleware',
        'custom_label': '${hostObj['name']}',
        'pos_x': relPos.dx.clamp(0.02, 0.86),
        'pos_y': relPos.dy.clamp(0.03, 0.84),
        'width_px': 236.0,
        'height_px': 134.0,
        'ssh_enabled': hostObj['ssh_enabled'] != false,
        'ssh_user': hostObj['ssh_user'] ?? 'root',
        'ssh_port': hostObj['ssh_port'] ?? 22,
      });
      if (mounted) {
        _rebuildState(() {
          _overview = res;
          _syncStackCanvasState();
        });
      }
      return;
    }

    if (data.startsWith('tpl:')) {
      final cls = data.substring(4);
      await _showCreateVirtualMachineWithServicesDialog(
        attachToCurrentStack: true,
        initialAssetClass: cls == 'database' ? 'virtual_machine' : cls,
        initialDropPosition: relPos,
      );
    }
  }

  // ===========================================================================
  // CAJAS / ZONAS CON TEXTO EN ESQUINA SUPERIOR (ARRASTRABLES Y REDIMENSIONABLES)
  // ===========================================================================

  Color _parseBoxHexColor(String? hex) {
    final clean = (hex ?? '#0EA5E9').replaceAll('#', '').trim();
    if (clean.length == 6) {
      final v = int.tryParse('FF$clean', radix: 16);
      if (v != null) return Color(v);
    }
    return AppTheme.accentCyan;
  }

  Widget _buildStackCanvasZoneBox({
    required Map<String, dynamic> zBox,
    required double canvasWidth,
    required double canvasHeight,
  }) {
    final boxId = '${zBox['id']}';
    final px = ((zBox['pos_x'] as num?)?.toDouble() ??
            (((zBox['x_px'] as num?)?.toDouble() ?? 40.0) / canvasWidth))
        .clamp(0.01, 0.92)
        .toDouble();
    final py = ((zBox['pos_y'] as num?)?.toDouble() ??
            (((zBox['y_px'] as num?)?.toDouble() ?? 40.0) / canvasHeight))
        .clamp(0.01, 0.90)
        .toDouble();
    final wRel = ((zBox['width_rel'] as num?)?.toDouble() ??
            (((zBox['width_px'] as num?)?.toDouble() ?? 520.0) / canvasWidth))
        .clamp(0.12, 0.95)
        .toDouble();
    final hRel = ((zBox['height_rel'] as num?)?.toDouble() ??
            (((zBox['height_px'] as num?)?.toDouble() ?? 430.0) / canvasHeight))
        .clamp(0.14, 0.95)
        .toDouble();

    final left = px * canvasWidth;
    final top = py * canvasHeight;
    final width = wRel * canvasWidth;
    final height = hRel * canvasHeight;
    final col = _parseBoxHexColor(zBox['color_hex'] as String?);
    final isSelected = _selectedBoxId == boxId;
    final cornerText = ((zBox['corner_data'] as String?) ??
            (zBox['subtitle'] as String?) ??
            '')
        .trim();

    Future<void> deleteThisBox() async {
      final updated = _stackBoxes.where((b) => '${b['id']}' != boxId).toList();
      _rebuildState(() {
        _stackBoxes = updated;
        if (_selectedBoxId == boxId) {
          _selectedBoxId = null;
        }
      });
      await _persistStackBoxesAndScale(boxes: updated);
    }

    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          _rebuildState(() {
            _selectedBoxId = boxId;
            _selectedStackNodeId = null;
          });
        },
        onDoubleTap: widget.canEdit
            ? () {
                _rebuildState(() {
                  _selectedBoxId = boxId;
                  _selectedStackNodeId = null;
                });
                _showAddOrEditStackZoneBoxDialog(existingBox: zBox);
              }
            : null,
        onPanStart: widget.canEdit
            ? (details) {
                _rebuildState(() {
                  _selectedBoxId = boxId;
                  _selectedStackNodeId = null;
                  _boxDragStartGlobal = details.globalPosition;
                  _boxDragStartPx = Offset(left, top);
                });
              }
            : null,
        onPanUpdate: widget.canEdit
            ? (details) {
                if (_boxDragStartGlobal == null || _boxDragStartPx == null) {
                  return;
                }
                final globalDelta =
                    details.globalPosition - _boxDragStartGlobal!;
                final newLeft = (_boxDragStartPx!.dx + globalDelta.dx).clamp(
                  4.0,
                  math.max(8.0, canvasWidth - width - 4.0),
                );
                final newTop = (_boxDragStartPx!.dy + globalDelta.dy).clamp(
                  4.0,
                  math.max(8.0, canvasHeight - height - 4.0),
                );
                _rebuildState(() {
                  zBox['pos_x'] = (newLeft / canvasWidth)
                      .clamp(0.005, 0.96)
                      .toDouble();
                  zBox['pos_y'] = (newTop / canvasHeight)
                      .clamp(0.005, 0.95)
                      .toDouble();
                });
              }
            : null,
        onPanEnd: widget.canEdit
            ? (_) {
                _boxDragStartGlobal = null;
                _boxDragStartPx = null;
                _persistStackBoxesAndScale(boxes: _stackBoxes);
              }
            : null,
        child: MouseRegion(
          cursor: widget.canEdit
              ? SystemMouseCursors.move
              : SystemMouseCursors.basic,
          child: Container(
            decoration: BoxDecoration(
              color: col.withValues(alpha: isSelected ? 0.08 : 0.045),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected ? col : col.withValues(alpha: 0.45),
                width: isSelected ? 2.4 : 1.4,
              ),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: col.withValues(alpha: 0.16),
                        blurRadius: 10,
                      ),
                    ]
                  : null,
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Cabecera en la ESQUINA SUPERIOR IZQUIERDA:
                // [ Botón "X" Borrar ] + [ Título editable + Datos Técnicos + Botón Editar Nombre ]
                Positioned(
                  left: 8,
                  top: 8,
                  right: 24,
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      // Botón "X" en la esquina superior izquierda para borrar la caja
                      if (widget.canEdit)
                        Tooltip(
                          message: 'Borrar esta caja / zona',
                          child: InkWell(
                            onTap: deleteThisBox,
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              width: 24,
                              height: 24,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: AppTheme.error.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: AppTheme.error.withValues(alpha: 0.75),
                                ),
                              ),
                              child: const Icon(
                                Icons.close_rounded,
                                size: 14,
                                color: AppTheme.error,
                              ),
                            ),
                          ),
                        ),
                      // Etiqueta clicable para seleccionar o cambiar nombre/datos de la caja
                      InkWell(
                        onTap: () {
                          _rebuildState(() {
                            _selectedBoxId = boxId;
                            _selectedStackNodeId = null;
                          });
                          if (widget.canEdit) {
                            _showAddOrEditStackZoneBoxDialog(existingBox: zBox);
                          }
                        },
                        borderRadius: BorderRadius.circular(7),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.bgSecondary.withValues(alpha: 0.96),
                            borderRadius: BorderRadius.circular(7),
                            border: Border.all(
                              color: col.withValues(alpha: 0.8),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.crop_free_rounded,
                                size: 12,
                                color: col,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  '${zBox['title'] ?? 'ZONA'}',
                                  style: TextStyle(
                                    fontSize: 10.8,
                                    fontWeight: FontWeight.w900,
                                    color: col,
                                    letterSpacing: 0.3,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (cornerText.isNotEmpty) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 1.5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: col.withValues(alpha: 0.14),
                                    borderRadius: BorderRadius.circular(5),
                                  ),
                                  child: Text(
                                    cornerText,
                                    style: const TextStyle(
                                      fontSize: 9.5,
                                      fontFamily: 'monospace',
                                      fontWeight: FontWeight.w700,
                                      color: AppTheme.textPrimary,
                                    ),
                                  ),
                                ),
                              ],
                              if (widget.canEdit) ...[
                                const SizedBox(width: 6),
                                const Icon(
                                  Icons.edit_outlined,
                                  size: 13,
                                  color: AppTheme.textSecondary,
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Tirador de redimensionado DERECHO (ancho) 1:1 con el ratón
                if (widget.canEdit)
                  Positioned(
                    right: -4,
                    top: height * 0.25,
                    bottom: height * 0.25,
                    width: 12,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (details) {
                        _rebuildState(() {
                          _selectedBoxId = boxId;
                          _boxResizeStartGlobal = details.globalPosition;
                          _boxResizeStartRect = Rect.fromLTWH(
                            left,
                            top,
                            width,
                            height,
                          );
                        });
                      },
                      onPanUpdate: (details) {
                        if (_boxResizeStartGlobal == null ||
                            _boxResizeStartRect == null) {
                          return;
                        }
                        final dx =
                            details.globalPosition.dx -
                            _boxResizeStartGlobal!.dx;
                        final nw =
                            ((_boxResizeStartRect!.width + dx) / canvasWidth)
                                .clamp(0.10, 0.98 - px)
                                .toDouble();
                        _rebuildState(() => zBox['width_rel'] = nw);
                      },
                      onPanEnd: (_) {
                        _boxResizeStartGlobal = null;
                        _boxResizeStartRect = null;
                        _persistStackBoxesAndScale(boxes: _stackBoxes);
                      },
                      child: MouseRegion(
                        cursor: SystemMouseCursors.resizeLeftRight,
                        child: Center(
                          child: Container(
                            width: 5,
                            height: 28,
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? col
                                  : col.withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                // Tirador de redimensionado INFERIOR (alto) 1:1 con el ratón
                if (widget.canEdit)
                  Positioned(
                    bottom: -4,
                    left: width * 0.25,
                    right: width * 0.25,
                    height: 12,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (details) {
                        _rebuildState(() {
                          _selectedBoxId = boxId;
                          _boxResizeStartGlobal = details.globalPosition;
                          _boxResizeStartRect = Rect.fromLTWH(
                            left,
                            top,
                            width,
                            height,
                          );
                        });
                      },
                      onPanUpdate: (details) {
                        if (_boxResizeStartGlobal == null ||
                            _boxResizeStartRect == null) {
                          return;
                        }
                        final dy =
                            details.globalPosition.dy -
                            _boxResizeStartGlobal!.dy;
                        final nh =
                            ((_boxResizeStartRect!.height + dy) / canvasHeight)
                                .clamp(0.12, 0.98 - py)
                                .toDouble();
                        _rebuildState(() => zBox['height_rel'] = nh);
                      },
                      onPanEnd: (_) {
                        _boxResizeStartGlobal = null;
                        _boxResizeStartRect = null;
                        _persistStackBoxesAndScale(boxes: _stackBoxes);
                      },
                      child: MouseRegion(
                        cursor: SystemMouseCursors.resizeUpDown,
                        child: Center(
                          child: Container(
                            width: 28,
                            height: 5,
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? col
                                  : col.withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                // Tirador de redimensionado ESQUINA INFERIOR DERECHA (ancho + alto 1:1 con ratón)
                if (widget.canEdit)
                  Positioned(
                    right: -4,
                    bottom: -4,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (details) {
                        _rebuildState(() {
                          _selectedBoxId = boxId;
                          _boxResizeStartGlobal = details.globalPosition;
                          _boxResizeStartRect = Rect.fromLTWH(
                            left,
                            top,
                            width,
                            height,
                          );
                        });
                      },
                      onPanUpdate: (details) {
                        if (_boxResizeStartGlobal == null ||
                            _boxResizeStartRect == null) {
                          return;
                        }
                        final delta =
                            details.globalPosition - _boxResizeStartGlobal!;
                        final nw =
                            ((_boxResizeStartRect!.width + delta.dx) /
                                    canvasWidth)
                                .clamp(0.10, 0.98 - px)
                                .toDouble();
                        final nh =
                            ((_boxResizeStartRect!.height + delta.dy) /
                                    canvasHeight)
                                .clamp(0.12, 0.98 - py)
                                .toDouble();
                        _rebuildState(() {
                          zBox['width_rel'] = nw;
                          zBox['height_rel'] = nh;
                        });
                      },
                      onPanEnd: (_) {
                        _boxResizeStartGlobal = null;
                        _boxResizeStartRect = null;
                        _persistStackBoxesAndScale(boxes: _stackBoxes);
                      },
                      child: MouseRegion(
                        cursor: SystemMouseCursors.resizeDownRight,
                        child: Container(
                          width: 22,
                          height: 22,
                          alignment: Alignment.bottomRight,
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: AppTheme.bgSecondary.withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(color: col),
                          ),
                          child: Icon(
                            Icons.south_east_rounded,
                            size: 13,
                            color: col,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showAddOrEditStackZoneBoxDialog({
    Map<String, dynamic>? existingBox,
  }) async {
    final isEdit = existingBox != null;
    final titleCtrl = TextEditingController(
      text:
          (existingBox?['title'] as String?) ??
          'ZONA LÓGICA / AGRUPACIÓN DE SISTEMAS',
    );
    final cornerDataCtrl = TextEditingController(
      text:
          (existingBox?['corner_data'] as String?) ??
          'VLAN 20 • 10.20.20.0/24 • Clúster HA',
    );
    String colorHex = (existingBox?['color_hex'] as String?) ?? '#0EA5E9';
    final colorChoices = [
      ('#0EA5E9', 'Cyan Red'),
      ('#6366F1', 'Índigo / App'),
      ('#14B8A6', 'Teal / BBDD'),
      ('#F59E0B', 'Ámbar / DMZ'),
      ('#EC4899', 'Rosa / Core'),
      ('#10B981', 'Verde / Producción'),
    ];

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          backgroundColor: AppTheme.bgCard,
          title: Text(
            isEdit
                ? 'Editar Caja / Zona con Datos en Esquina Superior'
                : 'Añadir Caja / Zona al Lienzo',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
          ),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: titleCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Título de la Caja (Esquina Superior Izquierda)',
                    hintText: 'Ej: FRONTALES WEB / CLÚSTER KUBERNETES',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: cornerDataCtrl,
                  decoration: const InputDecoration(
                    labelText:
                        'Datos Técnicos en la Esquina Superior (VLAN, Subred, Notas)',
                    hintText: 'Ej: VLAN 20 • 10.20.20.0/24 • VIP 10.20.20.10',
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Color del Borde y Etiqueta:',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final c in colorChoices)
                      ChoiceChip(
                        label: Text(
                          c.$2,
                          style: const TextStyle(fontSize: 10.5),
                        ),
                        selected: colorHex == c.$1,
                        selectedColor: _parseBoxHexColor(
                          c.$1,
                        ).withValues(alpha: 0.25),
                        onSelected: (_) =>
                            setModalState(() => colorHex = c.$1),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(ctx);
                if (isEdit) {
                  existingBox['title'] = titleCtrl.text.trim();
                  existingBox['corner_data'] = cornerDataCtrl.text.trim();
                  existingBox['color_hex'] = colorHex;
                  _rebuildState(() {});
                  await _persistStackBoxesAndScale(boxes: _stackBoxes);
                } else {
                  final newBox = <String, dynamic>{
                    'id': 'box-${DateTime.now().millisecondsSinceEpoch}',
                    'title': titleCtrl.text.trim(),
                    'corner_data': cornerDataCtrl.text.trim(),
                    'pos_x': 0.08,
                    'pos_y': 0.10,
                    'width_rel': 0.38,
                    'height_rel': 0.46,
                    'color_hex': colorHex,
                  };
                  final updated = [..._stackBoxes, newBox];
                  _rebuildState(() {
                    _stackBoxes = updated;
                    _selectedBoxId = newBox['id'] as String;
                  });
                  await _persistStackBoxesAndScale(boxes: updated);
                }
              },
              child: Text(isEdit ? 'Guardar Cambios' : 'Añadir Caja al Lienzo'),
            ),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // PÍLDORAS INTERACTIVAS DE ENLACES (CLIC PARA EDITAR PROTOCOLO O ELIMINAR)
  // ===========================================================================

  List<Widget> _buildEdgeInteractivePills({
    required List<Map<String, dynamic>> nodes,
    required List<Map<String, dynamic>> edges,
    required double canvasWidth,
    required double canvasHeight,
  }) {
    final nodesById = <int, Map<String, dynamic>>{};
    for (final n in nodes) {
      nodesById[n['id'] as int] = n;
    }

    final pills = <Widget>[];
    for (final e in edges) {
      final src = nodesById[e['source_node_id'] as int];
      final dst = nodesById[e['target_node_id'] as int];
      if (src == null || dst == null) continue;

      final anchors = _computeSmartEdgeAnchors(
        src: src,
        dst: dst,
        canvasSize: Size(canvasWidth, canvasHeight),
        edgeNotes: (e['notes'] as String?) ?? '',
      );
      final midX = (anchors.$1.dx + anchors.$2.dx) / 2;
      final midY = (anchors.$1.dy + anchors.$2.dy) / 2;
      final isDown = (e['status'] as String?) == 'DOWN';
      final color = isDown ? AppTheme.error : AppTheme.accentCyan;

      pills.add(
        Positioned(
          left: (midX - 54).clamp(4.0, math.max(8.0, canvasWidth - 115)),
          top: (midY - 12).clamp(4.0, math.max(8.0, canvasHeight - 28)),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: widget.canEdit
                ? () => _showEditOrDeleteEdgeDialog(e, nodesById)
                : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
              decoration: BoxDecoration(
                color: AppTheme.bgSecondary.withValues(alpha: 0.96),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: color.withValues(alpha: 0.75)),
                boxShadow: const [
                  BoxShadow(color: Colors.black26, blurRadius: 4),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${e['protocol_label']}',
                    style: TextStyle(
                      fontSize: 9.2,
                      fontWeight: FontWeight.w800,
                      color: color,
                    ),
                  ),
                  if (widget.canEdit) ...[
                    const SizedBox(width: 4),
                    Icon(
                      Icons.edit_outlined,
                      size: 10,
                      color: color.withValues(alpha: 0.8),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    }
    return pills;
  }

  Offset _sideAnchorPoint(Rect r, String? side) {
    switch (side) {
      case 'top':
        return r.topCenter;
      case 'bottom':
        return r.bottomCenter;
      case 'left':
        return r.centerLeft;
      case 'right':
        return r.centerRight;
      default:
        return r.centerRight;
    }
  }

  (Offset, Offset) _computeSmartEdgeAnchors({
    required Map<String, dynamic> src,
    required Map<String, dynamic> dst,
    required Size canvasSize,
    String edgeNotes = '',
  }) {
    final srcId = src['id'] as int;
    final dstId = dst['id'] as int;
    final sPos =
        _stackNodePositions[srcId] ??
        Offset(
          ((src['pos_x'] as num?)?.toDouble() ?? 0.2),
          ((src['pos_y'] as num?)?.toDouble() ?? 0.3),
        );
    final dPos =
        _stackNodePositions[dstId] ??
        Offset(
          ((dst['pos_x'] as num?)?.toDouble() ?? 0.5),
          ((dst['pos_y'] as num?)?.toDouble() ?? 0.3),
        );
    final sSize =
        _stackNodeSizes[srcId] ??
        Size(
          (src['width_px'] as num?)?.toDouble() ?? 220.0,
          (src['height_px'] as num?)?.toDouble() ?? 124.0,
        );
    final dSize =
        _stackNodeSizes[dstId] ??
        Size(
          (dst['width_px'] as num?)?.toDouble() ?? 220.0,
          (dst['height_px'] as num?)?.toDouble() ?? 124.0,
        );

    final sRect = Rect.fromLTWH(
      sPos.dx * canvasSize.width,
      sPos.dy * canvasSize.height,
      sSize.width,
      sSize.height,
    );
    final dRect = Rect.fromLTWH(
      dPos.dx * canvasSize.width,
      dPos.dy * canvasSize.height,
      dSize.width,
      dSize.height,
    );

    if (edgeNotes.startsWith('side:') && edgeNotes.contains('->')) {
      final parts = edgeNotes.substring(5).split('->');
      if (parts.length == 2) {
        return (
          _sideAnchorPoint(sRect, parts[0].trim()),
          _sideAnchorPoint(dRect, parts[1].trim()),
        );
      }
    }

    final sCenters = [
      sRect.centerRight,
      sRect.centerLeft,
      sRect.bottomCenter,
      sRect.topCenter,
    ];
    final dCenters = [
      dRect.centerLeft,
      dRect.centerRight,
      dRect.topCenter,
      dRect.bottomCenter,
    ];

    Offset bestS = sRect.centerRight;
    Offset bestD = dRect.centerLeft;
    double bestDist = double.infinity;
    for (final sc in sCenters) {
      for (final dc in dCenters) {
        final dist = (sc - dc).distanceSquared;
        if (dist < bestDist) {
          bestDist = dist;
          bestS = sc;
          bestD = dc;
        }
      }
    }
    return (bestS, bestD);
  }

  Future<void> _showEditOrDeleteEdgeDialog(
    Map<String, dynamic> edge,
    Map<int, Map<String, dynamic>> nodesById,
  ) async {
    final srcNode = nodesById[edge['source_node_id'] as int];
    final dstNode = nodesById[edge['target_node_id'] as int];
    final protoCtrl = TextEditingController(
      text: (edge['protocol_label'] as String?) ?? 'HTTPS :443',
    );
    final portCtrl = TextEditingController(
      text: '${edge['target_port'] ?? 443}',
    );

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        title: const Text(
          'Editar o Eliminar Enlace entre Elementos',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
        ),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Origen: ${(srcNode?['host'] as Map?)?['code'] ?? srcNode?['custom_label']}  ➔  Destino: ${(dstNode?['host'] as Map?)?['code'] ?? dstNode?['custom_label']}',
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.accentCyan,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: protoCtrl,
                decoration: const InputDecoration(
                  labelText: 'Etiqueta de Protocolo / Servicio',
                  hintText: 'Ej: HTTPS :443 / PostgreSQL :5432 / gRPC :9000',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: portCtrl,
                decoration: const InputDecoration(
                  labelText: 'Puerto Destino',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () async {
              Navigator.pop(ctx);
              final res = await widget.api.deleteTechStackEdge(
                edge['id'] as int,
              );
              if (mounted) {
                _rebuildState(() {
                  _overview = res;
                  _syncStackCanvasState();
                });
              }
            },
            icon: const Icon(
              Icons.delete_outline,
              size: 15,
              color: AppTheme.error,
            ),
            label: const Text(
              'Eliminar Enlace',
              style: TextStyle(color: AppTheme.error),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final res = await widget.api.updateTechStackEdge(
                edge['id'] as int,
                {
                  'protocol_label': protoCtrl.text.trim(),
                  'target_port': int.tryParse(portCtrl.text.trim()) ?? 443,
                },
              );
              if (mounted) {
                _rebuildState(() {
                  _overview = res;
                  _syncStackCanvasState();
                });
              }
            },
            child: const Text('Guardar Enlace'),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // TARJETA DE NODO ARRASTRABLE (1:1 CON RATÓN), REDIMENSIONABLE Y CON
  // 4 PEQUEÑOS CUADRADOS EN EL MEDIO DE LOS LADOS PARA LAS FLECHAS DE UNIÓN
  // ===========================================================================

  Widget _buildDraggableStackNodeCard({
    required Map<String, dynamic> sn,
    required List<Map<String, dynamic>> allNodes,
    required double canvasWidth,
    required double canvasHeight,
  }) {
    final nodeId = sn['id'] as int;
    final host = Map<String, dynamic>.from((sn['host'] as Map?) ?? {});
    final pos =
        _stackNodePositions[nodeId] ??
        Offset(
          ((sn['pos_x'] as num?)?.toDouble() ?? 0.2).clamp(0.01, 0.90),
          ((sn['pos_y'] as num?)?.toDouble() ?? 0.3).clamp(0.01, 0.88),
        );
    final nodeSize =
        _stackNodeSizes[nodeId] ??
        Size(
          ((sn['width_px'] as num?)?.toDouble() ?? 220.0).clamp(160.0, 500.0),
          ((sn['height_px'] as num?)?.toDouble() ?? 124.0).clamp(96.0, 340.0),
        );

    final left = (pos.dx * canvasWidth)
        .clamp(4.0, math.max(8.0, canvasWidth - nodeSize.width - 4))
        .toDouble();
    final top = (pos.dy * canvasHeight)
        .clamp(4.0, math.max(8.0, canvasHeight - nodeSize.height - 4))
        .toDouble();

    final state = (host['nagios_host_state'] as String?) ?? 'UP';
    final stateCol = _nagiosStateColor(state);
    final mini = Map<String, dynamic>.from((host['mini_series'] as Map?) ?? {});
    final cpuSeries = ((mini['cpu'] as List?) ?? [])
        .map((e) => (e as num).toDouble())
        .toList();
    final checks = ((host['service_checks'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    final isSelected = _selectedStackNodeId == nodeId;
    final isLinkSource = _isLinkModeActive && _linkSourceNodeId == nodeId;
    final rackId = host['rack_id'] as int?;
    final targetRackDevId = host['target_rack_device_id'] as int?;

    const double portPad = 8.0;

    return Positioned(
      left: left - portPad,
      top: top - portPad,
      width: nodeSize.width + (portPad * 2),
      height: nodeSize.height + (portPad * 2),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 1. Cuerpo de la tarjeta con su propio GestureDetector para selección y arrastre 1:1
          Positioned(
            left: portPad,
            top: portPad,
            width: nodeSize.width,
            height: nodeSize.height,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () async {
                if (_isLinkModeActive) {
                  if (_linkSourceNodeId == null) {
                    _rebuildState(() {
                      _linkSourceNodeId = nodeId;
                      _linkSourceSide = 'right';
                      _selectedStackNodeId = nodeId;
                    });
                  } else if (_linkSourceNodeId != nodeId) {
                    final srcId = _linkSourceNodeId!;
                    final srcSide = _linkSourceSide;
                    _rebuildState(() {
                      _isLinkModeActive = false;
                      _linkSourceNodeId = null;
                      _linkSourceSide = null;
                      _linkLiveMousePos = null;
                      _selectedStackNodeId = nodeId;
                    });
                    await _instantConnectNodes(
                      srcId,
                      nodeId,
                      allNodes,
                      sourceSide: srcSide,
                      targetSide: null,
                    );
                  }
                  return;
                }
                _rebuildState(() {
                  _selectedStackNodeId = nodeId;
                  _selectedBoxId = null;
                  _selectedHostId = host['id'] as int?;
                });
                if (host['id'] != null) {
                  _loadHostTelemetry(host['id'] as int);
                }
              },
              onDoubleTap: () {
                _rebuildState(() {
                  _selectedStackNodeId = nodeId;
                  _selectedHostId = host['id'] as int?;
                  _showFloatingTechWindow = true;
                  _floatingWinMinimized = false;
                });
                if (host['id'] != null) {
                  _loadHostTelemetry(host['id'] as int);
                }
              },
              onPanStart: widget.canEdit
                  ? (details) {
                      _rebuildState(() {
                        _selectedStackNodeId = nodeId;
                        _selectedBoxId = null;
                        _nodeDragStartGlobal = details.globalPosition;
                        _nodeDragStartPx = Offset(left, top);
                      });
                    }
                  : null,
              onPanUpdate: widget.canEdit
                  ? (details) {
                      if (_nodeDragStartGlobal == null ||
                          _nodeDragStartPx == null) {
                        return;
                      }
                      final globalDelta =
                          details.globalPosition - _nodeDragStartGlobal!;
                      final newLeft =
                          (_nodeDragStartPx!.dx + globalDelta.dx).clamp(
                            4.0,
                            math.max(8.0, canvasWidth - nodeSize.width - 4.0),
                          );
                      final newTop =
                          (_nodeDragStartPx!.dy + globalDelta.dy).clamp(
                            4.0,
                            math.max(8.0, canvasHeight - nodeSize.height - 4.0),
                          );
                      final newPx = (newLeft / canvasWidth)
                          .clamp(0.005, 0.96)
                          .toDouble();
                      final newPy = (newTop / canvasHeight)
                          .clamp(0.005, 0.95)
                          .toDouble();
                      _rebuildState(() {
                        _stackNodePositions[nodeId] = Offset(newPx, newPy);
                        sn['pos_x'] = newPx;
                        sn['pos_y'] = newPy;
                      });
                    }
                  : null,
              onPanEnd: widget.canEdit
                  ? (_) async {
                      _nodeDragStartGlobal = null;
                      _nodeDragStartPx = null;
                      final finalPos = _stackNodePositions[nodeId];
                      final finalSize = _stackNodeSizes[nodeId] ?? nodeSize;
                      if (finalPos == null) return;
                      final res = await widget.api.moveTechStackNode(nodeId, {
                        'pos_x': finalPos.dx,
                        'pos_y': finalPos.dy,
                        'width_px': finalSize.width,
                        'height_px': finalSize.height,
                      });
                      if (mounted) {
                        _rebuildState(() {
                          _overview = res;
                          _syncStackCanvasState();
                        });
                      }
                    }
                  : null,
              child: Container(
                padding: const EdgeInsets.fromLTRB(9, 7, 9, 6),
                decoration: BoxDecoration(
                  color: AppTheme.bgSecondary,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isLinkSource
                        ? AppTheme.warning
                        : (isSelected ? AppTheme.accentBlue : stateCol),
                    width: (isSelected || isLinkSource) ? 2.2 : 1.4,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: (isSelected ? AppTheme.accentBlue : stateCol)
                          .withValues(alpha: 0.18),
                      blurRadius: isSelected ? 12 : 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    // Cabecera del nodo: Estado + Código + Latencia + Acciones rápidas
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4.5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: stateCol.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: stateCol),
                          ),
                          child: Text(
                            state,
                            style: TextStyle(
                              fontSize: 8.5,
                              fontWeight: FontWeight.w900,
                              color: stateCol,
                            ),
                          ),
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            '${host['code']}',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: AppTheme.textPrimary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (host['last_ping_ms'] != null)
                          Text(
                            '${host['last_ping_ms']}ms',
                            style: const TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.accentTeal,
                            ),
                          ),
                        const SizedBox(width: 4),
                        // Botón para abrir la Ventana Flotante Movible de Datos Técnicos y Gráficas
                        InkWell(
                          onTap: () {
                            _rebuildState(() {
                              _selectedStackNodeId = nodeId;
                              _selectedHostId = host['id'] as int?;
                              _showFloatingTechWindow = true;
                              _floatingWinMinimized = false;
                            });
                            if (host['id'] != null) {
                              _loadHostTelemetry(host['id'] as int);
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.all(2.5),
                            decoration: BoxDecoration(
                              color: AppTheme.accentBlue.withValues(
                                alpha: 0.15,
                              ),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Icon(
                              Icons.analytics_outlined,
                              size: 12,
                              color: AppTheme.accentBlue,
                            ),
                          ),
                        ),
                        if (widget.canEdit) ...[
                          const SizedBox(width: 3),
                          InkWell(
                            onTap: () async {
                              final res = await widget.api.deleteTechStackNode(
                                nodeId,
                              );
                              if (mounted) {
                                _rebuildState(() {
                                  _overview = res;
                                  if (_selectedStackNodeId == nodeId) {
                                    _selectedStackNodeId = null;
                                  }
                                  _syncStackCanvasState();
                                });
                              }
                            },
                            child: const Icon(
                              Icons.close,
                              size: 12.5,
                              color: AppTheme.textMuted,
                            ),
                          ),
                        ],
                      ],
                    ),
                    // Nombre/Rol y dirección IP + Alojamiento
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${sn['custom_label'] ?? host['name']}',
                          style: const TextStyle(
                            fontSize: 10.2,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.accentBlue,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${host['heartbeat_ip']} • ${host['rack_location_badge']}',
                          style: const TextStyle(
                            fontSize: 8.8,
                            fontFamily: 'monospace',
                            color: AppTheme.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                    // Sparkline Prometheus refinado con valores en vivo
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'CPU ${host['cpu_pct']}% • RAM ${host['ram_pct']}%',
                              style: const TextStyle(
                                fontSize: 8.8,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                            Text(
                              host['monitoring_enabled'] == false
                                  ? 'HB Off'
                                  : '${checks.length} chk',
                              style: const TextStyle(
                                fontSize: 8.5,
                                color: AppTheme.textMuted,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        SizedBox(
                          height: 18,
                          width: double.infinity,
                          child: CustomPaint(
                            painter: _MiniSparklinePainter(
                              values: cpuSeries,
                              color: AppTheme.accentBlue,
                            ),
                          ),
                        ),
                      ],
                    ),
                    // Barra inferior de acciones rápidas (SSH, Gráficas Flotantes, Rack)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        if (sn['ssh_enabled'] != false &&
                            host['ssh_enabled'] != false &&
                            host['connect_enabled'] != false)
                          InkWell(
                            onTap: () => _showSshWebConsoleDialog(sn, host),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: AppPalette.slate900,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.terminal_rounded,
                                    size: 10,
                                    color: AppPalette.sky400,
                                  ),
                                  SizedBox(width: 3),
                                  Text(
                                    'SSH',
                                    style: TextStyle(
                                      fontSize: 8.8,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        else
                          const Text(
                            'SSH Off',
                            style: TextStyle(
                              fontSize: 8.5,
                              color: AppTheme.textMuted,
                            ),
                          ),
                        InkWell(
                          onTap: () {
                            _rebuildState(() {
                              _selectedStackNodeId = nodeId;
                              _selectedHostId = host['id'] as int?;
                              _showFloatingTechWindow = true;
                              _floatingWinMinimized = false;
                            });
                            if (host['id'] != null) {
                              _loadHostTelemetry(host['id'] as int);
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.accentTeal.withValues(
                                alpha: 0.14,
                              ),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              '📊 Datos & Gráficas',
                              style: TextStyle(
                                fontSize: 8.8,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.accentTeal,
                              ),
                            ),
                          ),
                        ),
                        if (rackId != null &&
                            widget.onNavigateToRackDevice != null)
                          InkWell(
                            onTap: () => widget.onNavigateToRackDevice!(
                              rackId,
                              targetRackDevId,
                            ),
                            child: const Text(
                              'Rack ↗',
                              style: TextStyle(
                                fontSize: 8.8,
                                fontWeight: FontWeight.w800,
                                color: AppTheme.accentBlue,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ===================================================================
          // 2. LOS 4 CUADRADITOS DE UNIÓN EXACTAMENTE CENTRADOS EN EL BORDE DE CADA LADO
          // Gracias al margen 'portPad = 8.0' del Positioned padre, el cuadradito
          // completo (16x16 px) está 100% dentro de los límites de hit-test de Flutter.
          // ===================================================================
          if (widget.canEdit) ...[
            // Lado SUPERIOR (centro exacto del borde superior: y = portPad)
            Positioned(
              left: portPad + (nodeSize.width / 2) - 8,
              top: portPad - 8,
              width: 16,
              height: 16,
              child: _buildNodeSideConnectorSquare(
                nodeId: nodeId,
                side: 'top',
                allNodes: allNodes,
                nodeRectInCanvas: Rect.fromLTWH(
                  left,
                  top,
                  nodeSize.width,
                  nodeSize.height,
                ),
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight,
              ),
            ),
            // Lado INFERIOR (centro exacto del borde inferior: y = portPad + height)
            Positioned(
              left: portPad + (nodeSize.width / 2) - 8,
              top: portPad + nodeSize.height - 8,
              width: 16,
              height: 16,
              child: _buildNodeSideConnectorSquare(
                nodeId: nodeId,
                side: 'bottom',
                allNodes: allNodes,
                nodeRectInCanvas: Rect.fromLTWH(
                  left,
                  top,
                  nodeSize.width,
                  nodeSize.height,
                ),
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight,
              ),
            ),
            // Lado IZQUIERDO (centro exacto del borde izquierdo: x = portPad)
            Positioned(
              left: portPad - 8,
              top: portPad + (nodeSize.height / 2) - 8,
              width: 16,
              height: 16,
              child: _buildNodeSideConnectorSquare(
                nodeId: nodeId,
                side: 'left',
                allNodes: allNodes,
                nodeRectInCanvas: Rect.fromLTWH(
                  left,
                  top,
                  nodeSize.width,
                  nodeSize.height,
                ),
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight,
              ),
            ),
            // Lado DERECHO (centro exacto del borde derecho: x = portPad + width)
            Positioned(
              left: portPad + nodeSize.width - 8,
              top: portPad + (nodeSize.height / 2) - 8,
              width: 16,
              height: 16,
              child: _buildNodeSideConnectorSquare(
                nodeId: nodeId,
                side: 'right',
                allNodes: allNodes,
                nodeRectInCanvas: Rect.fromLTWH(
                  left,
                  top,
                  nodeSize.width,
                  nodeSize.height,
                ),
                canvasWidth: canvasWidth,
                canvasHeight: canvasHeight,
              ),
            ),
          ],

          // 3. Tirador de redimensionado en la esquina inferior derecha del nodo (1:1 con ratón)
          if (widget.canEdit)
            Positioned(
              left: portPad + nodeSize.width - 14,
              top: portPad + nodeSize.height - 14,
              width: 18,
              height: 18,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (details) {
                  _rebuildState(() {
                    _selectedStackNodeId = nodeId;
                    _nodeResizeStartGlobal = details.globalPosition;
                    _nodeResizeStartSize = nodeSize;
                  });
                },
                onPanUpdate: (details) {
                  if (_nodeResizeStartGlobal == null ||
                      _nodeResizeStartSize == null) {
                    return;
                  }
                  final delta =
                      details.globalPosition - _nodeResizeStartGlobal!;
                  final nw = (_nodeResizeStartSize!.width + delta.dx)
                      .clamp(160.0, 500.0)
                      .toDouble();
                  final nh = (_nodeResizeStartSize!.height + delta.dy)
                      .clamp(96.0, 340.0)
                      .toDouble();
                  _rebuildState(() {
                    _stackNodeSizes[nodeId] = Size(nw, nh);
                    sn['width_px'] = nw;
                    sn['height_px'] = nh;
                  });
                },
                onPanEnd: (_) async {
                  _nodeResizeStartGlobal = null;
                  _nodeResizeStartSize = null;
                  final finalPos = _stackNodePositions[nodeId] ?? pos;
                  final finalSize = _stackNodeSizes[nodeId] ?? nodeSize;
                  final res = await widget.api.moveTechStackNode(nodeId, {
                    'pos_x': finalPos.dx,
                    'pos_y': finalPos.dy,
                    'width_px': finalSize.width,
                    'height_px': finalSize.height,
                  });
                  if (mounted) {
                    _rebuildState(() {
                      _overview = res;
                      _syncStackCanvasState();
                    });
                  }
                },
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeDownRight,
                  child: Container(
                    width: 18,
                    height: 18,
                    alignment: Alignment.bottomRight,
                    padding: const EdgeInsets.all(2),
                    child: const Icon(
                      Icons.south_east_rounded,
                      size: 10,
                      color: AppTheme.textMuted,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildNodeSideConnectorSquare({
    required int nodeId,
    required String side,
    required List<Map<String, dynamic>> allNodes,
    required Rect nodeRectInCanvas,
    required double canvasWidth,
    required double canvasHeight,
  }) {
    final isOriginPort =
        _isLinkModeActive &&
        _linkSourceNodeId == nodeId &&
        _linkSourceSide == side;
    final isHovered =
        _hoveredSideNodeId == nodeId && _hoveredSideName == side;

    final anchorInCanvas = _sideAnchorPoint(nodeRectInCanvas, side);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) async {
        final box =
            _stackCanvasKey.currentContext?.findRenderObject() as RenderBox?;
        final localPt = box != null
            ? box.globalToLocal(details.globalPosition)
            : anchorInCanvas;

        // Si aún no hay origen: activar flecha en vivo inmediatamente al pulsar sobre cualquier punto del cuadradito
        if (!_isLinkModeActive || _linkSourceNodeId == null) {
          _rebuildState(() {
            _isLinkModeActive = true;
            _linkSourceNodeId = nodeId;
            _linkSourceSide = side;
            _linkLiveMousePos = localPt;
            _selectedStackNodeId = nodeId;
          });
          return;
        }
        // Si se vuelve a pulsar el mismo nodo origen, cambia el lado de salida o cancela si es el mismo
        if (_linkSourceNodeId == nodeId) {
          if (_linkSourceSide == side) {
            _rebuildState(() {
              _isLinkModeActive = false;
              _linkSourceNodeId = null;
              _linkSourceSide = null;
              _linkLiveMousePos = null;
            });
          } else {
            _rebuildState(() {
              _linkSourceSide = side;
              _linkLiveMousePos = localPt;
            });
          }
          return;
        }
        // Si ya había un cuadrado lateral origen en otro nodo -> Conectar inmediatamente con flecha de unión
        final srcId = _linkSourceNodeId!;
        final srcSide = _linkSourceSide;
        _rebuildState(() {
          _isLinkModeActive = false;
          _linkSourceNodeId = null;
          _linkSourceSide = null;
          _linkLiveMousePos = null;
          _selectedStackNodeId = nodeId;
        });
        await _instantConnectNodes(
          srcId,
          nodeId,
          allNodes,
          sourceSide: srcSide,
          targetSide: side,
        );
      },
      onPanStart: (details) {
        final box =
            _stackCanvasKey.currentContext?.findRenderObject() as RenderBox?;
        final local = box != null
            ? box.globalToLocal(details.globalPosition)
            : anchorInCanvas;
        _rebuildState(() {
          _isLinkModeActive = true;
          _linkSourceNodeId = nodeId;
          _linkSourceSide = side;
          _linkLiveMousePos = local;
          _selectedStackNodeId = nodeId;
        });
      },
      onPanUpdate: (details) {
        final box =
            _stackCanvasKey.currentContext?.findRenderObject() as RenderBox?;
        if (box != null) {
          final local = box.globalToLocal(details.globalPosition);
          int? snapNodeId;
          String? snapSide;
          double bestDist = 26.0;
          for (final other in allNodes) {
            final oid = other['id'] as int;
            if (oid == nodeId) continue;
            final oPos =
                _stackNodePositions[oid] ??
                Offset(
                  ((other['pos_x'] as num?)?.toDouble() ?? 0.2),
                  ((other['pos_y'] as num?)?.toDouble() ?? 0.3),
                );
            final oSize =
                _stackNodeSizes[oid] ??
                Size(
                  ((other['width_px'] as num?)?.toDouble() ?? 220.0),
                  ((other['height_px'] as num?)?.toDouble() ?? 124.0),
                );
            final oRect = Rect.fromLTWH(
              oPos.dx * canvasWidth,
              oPos.dy * canvasHeight,
              oSize.width,
              oSize.height,
            );
            for (final sName in ['left', 'right', 'top', 'bottom']) {
              final sp = _sideAnchorPoint(oRect, sName);
              final d = (sp - local).distance;
              if (d < bestDist) {
                bestDist = d;
                snapNodeId = oid;
                snapSide = sName;
              }
            }
          }
          _rebuildState(() {
            _linkLiveMousePos = local;
            _hoveredSideNodeId = snapNodeId;
            _hoveredSideName = snapSide;
          });
        }
      },
      onPanEnd: (_) async {
        final dropPt = _linkLiveMousePos;
        if (dropPt == null || _linkSourceNodeId == null) return;
        // Buscar si hemos soltado la flecha sobre otro elemento o cerca de alguno de sus 4 cuadrados laterales
        int? targetNodeId;
        String? targetSide;
        double bestDist = double.infinity;

        for (final other in allNodes) {
          final oid = other['id'] as int;
          if (oid == nodeId) continue;
          final oPos =
              _stackNodePositions[oid] ??
              Offset(
                ((other['pos_x'] as num?)?.toDouble() ?? 0.2),
                ((other['pos_y'] as num?)?.toDouble() ?? 0.3),
              );
          final oSize =
              _stackNodeSizes[oid] ??
              Size(
                ((other['width_px'] as num?)?.toDouble() ?? 220.0),
                ((other['height_px'] as num?)?.toDouble() ?? 124.0),
              );
          final oRect = Rect.fromLTWH(
            oPos.dx * canvasWidth,
            oPos.dy * canvasHeight,
            oSize.width,
            oSize.height,
          );
          if (oRect.inflate(22).contains(dropPt)) {
            targetNodeId = oid;
            for (final sName in ['left', 'right', 'top', 'bottom']) {
              final sp = _sideAnchorPoint(oRect, sName);
              final d = (sp - dropPt).distance;
              if (d < bestDist) {
                bestDist = d;
                targetSide = sName;
              }
            }
            break;
          }
        }

        if (targetNodeId != null) {
          final srcId = _linkSourceNodeId!;
          final srcSide = _linkSourceSide;
          _rebuildState(() {
            _isLinkModeActive = false;
            _linkSourceNodeId = null;
            _linkSourceSide = null;
            _linkLiveMousePos = null;
            _selectedStackNodeId = targetNodeId;
          });
          await _instantConnectNodes(
            srcId,
            targetNodeId,
            allNodes,
            sourceSide: srcSide,
            targetSide: targetSide,
          );
        }
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => _rebuildState(() {
          _hoveredSideNodeId = nodeId;
          _hoveredSideName = side;
        }),
        onExit: (_) => _rebuildState(() {
          if (_hoveredSideNodeId == nodeId && _hoveredSideName == side) {
            _hoveredSideNodeId = null;
            _hoveredSideName = null;
          }
        }),
        child: Container(
          width: 16,
          height: 16,
          alignment: Alignment.center,
          color: Colors.transparent,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            width: (isOriginPort || isHovered) ? 14 : 12,
            height: (isOriginPort || isHovered) ? 14 : 12,
            decoration: BoxDecoration(
              color: isOriginPort
                  ? AppTheme.warning
                  : (isHovered ? AppTheme.accentCyan : AppTheme.bgSecondary),
              borderRadius: BorderRadius.circular(3),
              border: Border.all(
                color: isOriginPort
                    ? Colors.black
                    : (isHovered ? AppTheme.accentBlue : AppTheme.accentCyan),
                width: (isOriginPort || isHovered) ? 2.2 : 1.8,
              ),
              boxShadow: (isOriginPort || isHovered)
                  ? [
                      BoxShadow(
                        color:
                            (isOriginPort
                                    ? AppTheme.warning
                                    : AppTheme.accentCyan)
                                .withValues(alpha: 0.55),
                        blurRadius: 6,
                      ),
                    ]
                  : null,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _instantConnectNodes(
    int sourceNodeId,
    int targetNodeId,
    List<Map<String, dynamic>> nodes, {
    String? sourceSide,
    String? targetSide,
  }) async {
    final activeStack = _activeStack;
    final stackId = activeStack['id'] as int?;
    if (stackId == null || sourceNodeId == targetNodeId) return;
    final dstNode = nodes.firstWhere(
      (n) => n['id'] == targetNodeId,
      orElse: () => <String, dynamic>{},
    );
    final dstHost = Map<String, dynamic>.from((dstNode['host'] as Map?) ?? {});
    final dstCode = ('${dstHost['code'] ?? ''} ${dstHost['name'] ?? ''}')
        .toUpperCase();

    String proto = 'HTTPS / TCP :443';
    int port = 443;
    if (dstCode.contains('PGSQL') || dstCode.contains('POSTGRES')) {
      proto = 'PostgreSQL :5432';
      port = 5432;
    } else if (dstCode.contains('REDIS')) {
      proto = 'Redis :6379';
      port = 6379;
    } else if (dstCode.contains('MYSQL') || dstCode.contains('MARIADB')) {
      proto = 'MySQL :3306';
      port = 3306;
    } else if (dstCode.contains('API') || dstCode.contains('BACKEND')) {
      proto = 'HTTP/gRPC :8080';
      port = 8080;
    }

    final sideNotes = (sourceSide != null || targetSide != null)
        ? 'side:${sourceSide ?? "right"}->${targetSide ?? "left"}'
        : '';

    final res = await widget.api.createTechStackEdge({
      'stack_id': stackId,
      'source_node_id': sourceNodeId,
      'target_node_id': targetNodeId,
      'protocol_label': proto,
      'port': port,
      'target_port': port,
      'notes': sideNotes,
    });
    if (mounted) {
      _rebuildState(() {
        _overview = res;
        _syncStackCanvasState();
      });
      _showSnack(
        'Flecha de unión creada ($proto). Haz clic en su etiqueta si quieres cambiar el puerto/protocolo.',
      );
    }
  }

  Future<void> _quickCreateEdgeBetweenNodes(
    int sourceNodeId,
    int targetNodeId,
    List<Map<String, dynamic>> nodes,
  ) async {
    await _instantConnectNodes(sourceNodeId, targetNodeId, nodes);
  }

  // ===========================================================================
  // VENTANA FLOTANTE MOVIBLE (1:1 CON RATÓN) CON DATOS TÉCNICOS Y PROMETHEUS
  // ===========================================================================

  Widget _buildFloatingTechnicalAndChartsWindow({
    required Map<String, dynamic> sn,
    required double canvasWidth,
    required double canvasHeight,
  }) {
    final host = Map<String, dynamic>.from((sn['host'] as Map?) ?? {});
    final checks = ((host['service_checks'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final state = (host['nagios_host_state'] as String?) ?? 'UP';
    final stateCol = _nagiosStateColor(state);

    final telemetryPoints =
        (_telemetryData != null &&
            (_telemetryData!['host'] as Map?)?['id'] == host['id'])
        ? (((_telemetryData!['points'] as List?) ??
                  (_telemetryData!['series'] as List?) ??
                  [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList())
        : _buildFallbackSeriesFromMini(host);

    final winWidth = _floatingWinMinimized ? 320.0 : 520.0;
    final left = _floatingWinPos.dx
        .clamp(8.0, math.max(12.0, canvasWidth - winWidth - 8))
        .toDouble();
    final top = _floatingWinPos.dy
        .clamp(8.0, math.max(12.0, canvasHeight - 80))
        .toDouble();

    return Positioned(
      left: left,
      top: top,
      child: Material(
        elevation: 16,
        borderRadius: BorderRadius.circular(12),
        color: Colors.transparent,
        child: Container(
          width: winWidth,
          decoration: BoxDecoration(
            color: AppTheme.bgSecondary.withValues(alpha: 0.98),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.accentBlue, width: 1.8),
            boxShadow: const [
              BoxShadow(
                color: Colors.black45,
                blurRadius: 20,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Barra de título ARRASTRABLE 1:1 con el ratón para mover la ventana flotante
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onPanStart: (details) {
                  _floatWinDragStartGlobal = details.globalPosition;
                  _floatWinDragStartPos = Offset(left, top);
                },
                onPanUpdate: (details) {
                  if (_floatWinDragStartGlobal == null ||
                      _floatWinDragStartPos == null) {
                    return;
                  }
                  final delta =
                      details.globalPosition - _floatWinDragStartGlobal!;
                  _rebuildState(() {
                    _floatingWinPos = Offset(
                      (_floatWinDragStartPos!.dx + delta.dx).clamp(
                        6.0,
                        math.max(12.0, canvasWidth - winWidth - 6),
                      ),
                      (_floatWinDragStartPos!.dy + delta.dy).clamp(
                        6.0,
                        math.max(12.0, canvasHeight - 60),
                      ),
                    );
                  });
                },
                onPanEnd: (_) {
                  _floatWinDragStartGlobal = null;
                  _floatWinDragStartPos = null;
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.bgCard,
                    borderRadius: BorderRadius.vertical(
                      top: const Radius.circular(11),
                      bottom: _floatingWinMinimized
                          ? const Radius.circular(11)
                          : Radius.zero,
                    ),
                    border: const Border(
                      bottom: BorderSide(color: AppTheme.border),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.drag_indicator_rounded,
                        size: 16,
                        color: AppTheme.accentCyan,
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1.5,
                        ),
                        decoration: BoxDecoration(
                          color: stateCol.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: stateCol),
                        ),
                        child: Text(
                          state,
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                            color: stateCol,
                          ),
                        ),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          '${host['code']} • ${sn['custom_label'] ?? host['name']}',
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                            color: AppTheme.textPrimary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        tooltip: _floatingWinMinimized
                            ? 'Expandir ventana flotante'
                            : 'Minimizar ventana flotante',
                        constraints: const BoxConstraints(),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        icon: Icon(
                          _floatingWinMinimized
                              ? Icons.open_in_full_rounded
                              : Icons.minimize_rounded,
                          size: 14,
                          color: AppTheme.textSecondary,
                        ),
                        onPressed: () => _rebuildState(
                          () => _floatingWinMinimized = !_floatingWinMinimized,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Cerrar ventana flotante',
                        constraints: const BoxConstraints(),
                        padding: const EdgeInsets.only(left: 4),
                        icon: const Icon(
                          Icons.close_rounded,
                          size: 15,
                          color: AppTheme.textSecondary,
                        ),
                        onPressed: () =>
                            _rebuildState(() => _showFloatingTechWindow = false),
                      ),
                    ],
                  ),
                ),
              ),
              if (!_floatingWinMinimized)
                SelectionArea(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Selector de pestaña interna + rango horario de Prometheus
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Wrap(
                            spacing: 6,
                            children: [
                              ChoiceChip(
                                label: const Text(
                                  '📊 Gráficas Prometheus',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                selected: _floatingWinTab == 'charts',
                                onSelected: (_) =>
                                    _rebuildState(() => _floatingWinTab = 'charts'),
                              ),
                              ChoiceChip(
                                label: Text(
                                  '🖧 Datos Técnicos & Checks (${checks.length})',
                                  style: const TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                selected: _floatingWinTab == 'tech',
                                onSelected: (_) =>
                                    _rebuildState(() => _floatingWinTab = 'tech'),
                              ),
                            ],
                          ),
                          if (_floatingWinTab == 'charts')
                            Wrap(
                              spacing: 4,
                              children: [
                                for (final r in [
                                  (1, '1h'),
                                  (6, '6h'),
                                  (24, '24h'),
                                  (168, '7d'),
                                ])
                                  InkWell(
                                    onTap: () {
                                      _rebuildState(
                                        () => _telemetryRangeHours = r.$1,
                                      );
                                      if (host['id'] != null) {
                                        _loadHostTelemetry(host['id'] as int);
                                      }
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2.5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: _telemetryRangeHours == r.$1
                                            ? AppTheme.accentBlue
                                            : AppTheme.bgCard,
                                        borderRadius: BorderRadius.circular(5),
                                        border: Border.all(
                                          color: AppTheme.border,
                                        ),
                                      ),
                                      child: Text(
                                        r.$2,
                                        style: TextStyle(
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.w800,
                                          color: _telemetryRangeHours == r.$1
                                              ? Colors.white
                                              : AppTheme.textSecondary,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (_floatingWinTab == 'charts') ...[
                        _buildRefinedCompactChartBox(
                          title: 'CPU & Memoria RAM (%)',
                          points: telemetryPoints,
                          keyA: 'cpu_pct',
                          labelA: 'CPU',
                          colorA: AppTheme.accentBlue,
                          keyB: 'ram_pct',
                          labelB: 'RAM',
                          colorB: AppTheme.accentPurple,
                          unit: '%',
                          warnThreshold: 75,
                          critThreshold: 90,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: _buildRefinedCompactChartBox(
                                title: 'Latencia ICMP / HTTP (ms)',
                                points: telemetryPoints,
                                keyA: 'latency_ms',
                                labelA: 'RTT',
                                colorA: AppTheme.accentTeal,
                                unit: 'ms',
                                height: 82,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _buildRefinedCompactChartBox(
                                title: 'Tráfico Red RX/TX (Mbps)',
                                points: telemetryPoints,
                                keyA: 'rx_mbps',
                                labelA: 'RX',
                                colorA: AppTheme.accentCyan,
                                keyB: 'tx_mbps',
                                labelB: 'TX',
                                colorB: AppTheme.warning,
                                unit: 'Mbps',
                                height: 82,
                              ),
                            ),
                          ],
                        ),
                      ] else ...[
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: AppTheme.bgCard,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppTheme.border),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'IP Principal: ${host['heartbeat_ip']} • FQDN: ${host['fqdn'] ?? host['hostname']}',
                                style: const TextStyle(
                                  fontSize: 10.2,
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                'SO / Plataforma: ${host['os_or_firmware']} • ${host['rack_location_badge']}',
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                'Recursos: ${host['cpu_cores'] ?? 4} vCPU • ${host['ram_gb'] ?? 16} GB RAM • Disco ${host['disk_pct']}% ocupado',
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          height: 120,
                          child: ListView(
                            children: [
                              for (final c in checks)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.circle,
                                        size: 8,
                                        color: _nagiosStateColor(
                                          (c['nagios_state'] as String?) ??
                                              'OK',
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          '${c['service_name']} (${c['check_type']} :${c['port'] ?? '-'}): ${c['status_output']}',
                                          style: const TextStyle(
                                            fontSize: 10,
                                            color: AppTheme.textSecondary,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      // Pie de la ventana flotante con acceso SSH y salto a Tab 5
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          if (sn['ssh_enabled'] != false &&
                              host['ssh_enabled'] != false)
                            ElevatedButton.icon(
                              onPressed: () =>
                                  _showSshWebConsoleDialog(sn, host),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppPalette.slate900,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 6,
                                ),
                              ),
                              icon: const Icon(
                                Icons.terminal_rounded,
                                size: 13,
                                color: AppPalette.sky400,
                              ),
                              label: Text(
                                'SSH ${sn['ssh_user'] ?? 'root'}@${host['ssh_host'] ?? host['heartbeat_ip']}',
                                style: const TextStyle(fontSize: 10),
                              ),
                            ),
                          OutlinedButton.icon(
                            onPressed: () {
                              _rebuildState(
                                () => _selectedHostId = host['id'] as int,
                              );
                              _tabController.animateTo(4);
                              _loadHostTelemetry(host['id'] as int);
                            },
                            icon: const Icon(
                              Icons.open_in_new_rounded,
                              size: 13,
                            ),
                            label: const Text(
                              'Ver Pantalla Completa Prometheus',
                              style: TextStyle(fontSize: 10),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  List<Map<String, dynamic>> _buildFallbackSeriesFromMini(
    Map<String, dynamic> host,
  ) {
    final mini = Map<String, dynamic>.from((host['mini_series'] as Map?) ?? {});
    final cpu = ((mini['cpu'] as List?) ?? [])
        .map((e) => (e as num).toDouble())
        .toList();
    final ram = ((mini['ram'] as List?) ?? [])
        .map((e) => (e as num).toDouble())
        .toList();
    final lat = ((mini['latency'] as List?) ?? [])
        .map((e) => (e as num).toDouble())
        .toList();
    final traf = ((mini['traffic'] as List?) ?? [])
        .map((e) => (e as num).toDouble())
        .toList();
    final len = [
      cpu.length,
      ram.length,
      lat.length,
      traf.length,
    ].fold<int>(0, math.max);
    if (len == 0) return [];
    return List.generate(len, (i) {
      return {
        'label': '${i * 5}m',
        'time_label': '${i * 5}m',
        'cpu_pct': i < cpu.length ? cpu[i] : 0.0,
        'ram_pct': i < ram.length ? ram[i] : 0.0,
        'latency_ms': i < lat.length ? lat[i] : 0.0,
        'rx_mbps': i < traf.length ? traf[i] : 0.0,
        'tx_mbps': i < traf.length ? traf[i] : 0.0,
        'web_req_per_sec': 0.0,
        'disk_pct': (host['disk_pct'] as num?)?.toDouble() ?? 0.0,
      };
    });
  }

  Widget _buildRefinedCompactChartBox({
    required String title,
    required List<Map<String, dynamic>> points,
    required String keyA,
    required String labelA,
    required Color colorA,
    String? keyB,
    String? labelB,
    Color? colorB,
    required String unit,
    double height = 98,
    double? warnThreshold,
    double? critThreshold,
  }) {
    final valsA = points
        .map((p) => (p[keyA] as num?)?.toDouble() ?? 0.0)
        .toList();
    final curA = valsA.isNotEmpty ? valsA.last : 0.0;
    final maxA = valsA.isNotEmpty ? valsA.reduce(math.max) : 0.0;
    final avgA = valsA.isNotEmpty
        ? valsA.reduce((a, b) => a + b) / valsA.length
        : 0.0;

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '$labelA: ${curA.toStringAsFixed(1)}$unit (Máx ${maxA.toStringAsFixed(1)} • Med ${avgA.toStringAsFixed(1)})',
                style: TextStyle(
                  fontSize: 9.2,
                  fontWeight: FontWeight.w800,
                  color: colorA,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          SizedBox(
            height: height,
            width: double.infinity,
            child: ClipRect(
              child: CustomPaint(
                painter: _PrometheusSeriesChartPainter(
                  points: points,
                  keyA: keyA,
                  colorA: colorA,
                  keyB: keyB,
                  colorB: colorB,
                  unit: unit,
                  warnThreshold: warnThreshold,
                  critThreshold: critThreshold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // PANEL DERECHO DE CONFIGURACIÓN DEL ELEMENTO (ESTILO DATACENTER FLOOR)
  // ===========================================================================

  Widget _buildStackRightSettingsPanel({
    required Map<String, dynamic> activeStack,
    required List<Map<String, dynamic>> nodes,
    required List<Map<String, dynamic>> edges,
    required Map<String, dynamic> selectedNode,
  }) {
    // Si hay una Caja/Zona seleccionada, mostramos sus ajustes editables en directo
    if (_selectedBoxId != null) {
      final box = _stackBoxes.firstWhere(
        (b) => '${b['id']}' == _selectedBoxId,
        orElse: () => <String, dynamic>{},
      );
      if (box.isNotEmpty) {
        final boxId = '${box['id']}';
        final wRel = ((box['width_rel'] as num?)?.toDouble() ?? 0.38).clamp(
          0.10,
          0.96,
        );
        final hRel = ((box['height_rel'] as num?)?.toDouble() ?? 0.45).clamp(
          0.12,
          0.96,
        );
        final colorHex = (box['color_hex'] as String?) ?? '#0EA5E9';
        final colorChoices = [
          ('#0EA5E9', 'Cyan'),
          ('#2563EB', 'Azul'),
          ('#7C3AED', 'Violeta'),
          ('#0D9488', 'Teal'),
          ('#F59E0B', 'Ámbar'),
          ('#EC4899', 'Rosa'),
        ];

        return Container(
          width: 340,
          decoration: const BoxDecoration(
            color: AppTheme.bgCard,
            border: Border(left: BorderSide(color: AppTheme.border)),
          ),
          padding: const EdgeInsets.all(12),
          child: ListView(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'CONFIGURACIÓN DE CAJA / ZONA',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      color: AppTheme.accentPurple,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 15),
                    onPressed: () => _rebuildState(() => _selectedBoxId = null),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: ValueKey('box-title-$boxId'),
                initialValue: '${box['title'] ?? ''}',
                enabled: widget.canEdit,
                decoration: const InputDecoration(
                  labelText: 'Nombre / Título de la Caja',
                  isDense: true,
                ),
                onChanged: (v) {
                  _rebuildState(() => box['title'] = v);
                },
                onFieldSubmitted: (_) =>
                    _persistStackBoxesAndScale(boxes: _stackBoxes),
              ),
              const SizedBox(height: 10),
              TextFormField(
                key: ValueKey('box-corner-$boxId'),
                initialValue:
                    '${box['corner_data'] ?? box['subtitle'] ?? ''}',
                enabled: widget.canEdit,
                decoration: const InputDecoration(
                  labelText: 'Datos Técnicos (Esquina Superior)',
                  isDense: true,
                ),
                onChanged: (v) {
                  _rebuildState(() {
                    box['corner_data'] = v;
                    box['subtitle'] = v;
                  });
                },
                onFieldSubmitted: (_) =>
                    _persistStackBoxesAndScale(boxes: _stackBoxes),
              ),
              const SizedBox(height: 12),
              Text(
                'Ancho de la Caja: ${(wRel * 100).round()}% del lienzo',
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Slider(
                value: wRel.toDouble(),
                min: 0.10,
                max: 0.96,
                onChanged: widget.canEdit
                    ? (v) => _rebuildState(() => box['width_rel'] = v)
                    : null,
                onChangeEnd: widget.canEdit
                    ? (_) => _persistStackBoxesAndScale(boxes: _stackBoxes)
                    : null,
              ),
              Text(
                'Alto de la Caja: ${(hRel * 100).round()}% del lienzo',
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Slider(
                value: hRel.toDouble(),
                min: 0.12,
                max: 0.96,
                onChanged: widget.canEdit
                    ? (v) => _rebuildState(() => box['height_rel'] = v)
                    : null,
                onChangeEnd: widget.canEdit
                    ? (_) => _persistStackBoxesAndScale(boxes: _stackBoxes)
                    : null,
              ),
              const SizedBox(height: 6),
              const Text(
                'Color de la Caja:',
                style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final c in colorChoices)
                    ChoiceChip(
                      label: Text(
                        c.$2,
                        style: const TextStyle(fontSize: 10),
                      ),
                      selected: colorHex.toUpperCase() == c.$1.toUpperCase(),
                      onSelected: widget.canEdit
                          ? (_) {
                              _rebuildState(() => box['color_hex'] = c.$1);
                              _persistStackBoxesAndScale(boxes: _stackBoxes);
                            }
                          : null,
                    ),
                ],
              ),
              const SizedBox(height: 14),
              if (widget.canEdit) ...[
                ElevatedButton.icon(
                  onPressed: () =>
                      _persistStackBoxesAndScale(boxes: _stackBoxes),
                  icon: const Icon(Icons.save_outlined, size: 15),
                  label: const Text('Guardar Cambios de la Caja'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    final updated = _stackBoxes
                        .where((b) => '${b['id']}' != boxId)
                        .toList();
                    _rebuildState(() {
                      _stackBoxes = updated;
                      _selectedBoxId = null;
                    });
                    await _persistStackBoxesAndScale(boxes: updated);
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.error,
                  ),
                  icon: const Icon(Icons.close_rounded, size: 15),
                  label: const Text('Borrar Caja / Zona'),
                ),
              ],
            ],
          ),
        );
      }
    }

    if (selectedNode.isEmpty) {
      return Container(
        width: 320,
        decoration: const BoxDecoration(
          color: AppTheme.bgCard,
          border: Border(left: BorderSide(color: AppTheme.border)),
        ),
        padding: const EdgeInsets.all(14),
        child: const Center(
          child: Text(
            'Selecciona un elemento en el lienzo para configurar sus datos, enlaces, Heartbeat y Conexión SSH/Web.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11.5, color: AppTheme.textMuted),
          ),
        ),
      );
    }

    final host = Map<String, dynamic>.from((selectedNode['host'] as Map?) ?? {});
    final nodeId = selectedNode['id'] as int;
    final nodeEdges = edges
        .where(
          (e) =>
              e['source_node_id'] == nodeId || e['target_node_id'] == nodeId,
        )
        .toList();

    return Container(
      width: 345,
      decoration: const BoxDecoration(
        color: AppTheme.bgCard,
        border: Border(left: BorderSide(color: AppTheme.border)),
      ),
      child: _DatacenterStyleHostConfigPanel(
        key: ValueKey('dc-panel-${host['id']}-${selectedNode['id']}'),
        host: host,
        stackNode: selectedNode,
        allStackNodes: nodes,
        nodeEdges: nodeEdges,
        hostsList: _hosts,
        canEdit: widget.canEdit,
        onStartLinkMode: () {
          _rebuildState(() {
            _isLinkModeActive = true;
            _linkSourceNodeId = nodeId;
          });
        },
        onQuickConnectToNode: (targetNodeId) =>
            _quickCreateEdgeBetweenNodes(nodeId, targetNodeId, nodes),
        onDeleteEdge: (edgeId) async {
          final res = await widget.api.deleteTechStackEdge(edgeId);
          if (mounted) {
            _rebuildState(() {
              _overview = res;
              _syncStackCanvasState();
            });
          }
        },
        onOpenSsh: () => _showSshWebConsoleDialog(selectedNode, host),
        onOpenFloatingCharts: () {
          _rebuildState(() {
            _showFloatingTechWindow = true;
            _floatingWinMinimized = false;
          });
          if (host['id'] != null) {
            _loadHostTelemetry(host['id'] as int);
          }
        },
        onSaveHostConfig: (payload) async {
          final res = await widget.api.createNetworkHostWithServices(payload);
          if (res['overview'] is Map && mounted) {
            _rebuildState(() {
              _overview = Map<String, dynamic>.from(res['overview'] as Map);
              _syncStackCanvasState();
            });
            _showSnack('Elemento ${payload['code']} actualizado.');
          }
        },
      ),
    );
  }
}
