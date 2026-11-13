part of '../../main.dart';

/// Módulo **`5. Dashboard & Excel`**: auditoría de Hierro línea a línea (`U42 -> U1`),
/// Patch Panels boca a boca, sistemas monitorizados e importación/exportación `.xlsx`.
extension _RackDocDashboardOverviewExt on _RackDocShellState {
  DiagramExportDocument _buildGlobalExportDocument() {
    final rawRackLines =
        (_dashboardInventory?['rack_lines'] as List?) ?? const [];
    final allRackLines = rawRackLines
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where(
          (ln) =>
              _dashSelectedRackId == null ||
              ln['rack_id'] == _dashSelectedRackId,
        )
        .toList();

    final zones = <DiagramExportZone>[];
    for (int i = 0; i < _locations.length; i++) {
      final loc = _locations[i];
      zones.add(
        DiagramExportZone(
          id: 'loc_${loc.id}',
          title: '${loc.name} (${loc.code})',
          subtitle:
              '${loc.floorsCount} Plantas • ${loc.racksCount} Racks • ${loc.monitoredCount} Monitorizados',
          x: 24.0 + (i % 2) * 680.0,
          y: 24.0 + (i ~/ 2) * 320.0,
          width: 650.0,
          height: 295.0,
          colorHex: '#1E3A8A',
        ),
      );
    }

    final nodes = <DiagramExportNode>[];
    final edges = <DiagramExportEdge>[];
    for (int i = 0; i < allRackLines.length; i++) {
      final ln = allRackLines[i];
      final id = 'dev_${ln['device_id'] ?? i}';
      final col = i % 5;
      final row = i ~/ 5;
      nodes.add(
        DiagramExportNode(
          id: id,
          code: '${ln['code'] ?? ''}',
          name: '${ln['name'] ?? ''}',
          subtitle: '${ln['rack_code'] ?? ''} • ${ln['u_range'] ?? ''}',
          ip: '${ln['ip_address'] ?? ''}',
          modelName: '${ln['manufacturer'] ?? ''} ${ln['model_name'] ?? ''}'
              .trim(),
          serialNumber: '${ln['serial_number'] ?? ''}',
          status: '${ln['status'] ?? 'online'}',
          x: 40.0 + col * 265.0,
          y: 55.0 + row * 110.0,
          width: 240.0,
          height: 86.0,
          colorHex: ln['kind_group'] == 'hierro' ? '#1E3A8A' : '#475569',
        ),
      );
    }

    final rawPatchPanels =
        (_dashboardInventory?['patch_panels'] as List?) ?? const [];
    int edgeIdx = 1;
    for (final rawPp in rawPatchPanels) {
      final pp = Map<String, dynamic>.from(rawPp as Map);
      final ppDevId = 'dev_${pp['device_id']}';
      final bocas = (pp['bocas'] as List?) ?? const [];
      for (final rawB in bocas) {
        final b = Map<String, dynamic>.from(rawB as Map);
        if (b['occupied'] == true && b['peer_device_id'] != null) {
          edges.add(
            DiagramExportEdge(
              id: 'pp_edge_${edgeIdx++}',
              sourceId: ppDevId,
              targetId: 'dev_${b['peer_device_id']}',
              label: 'Boca ${b['port_number']} -> ${b['peer_port_number'] ?? ''}',
              detail: '${b['peer_ip'] ?? b['cable_type'] ?? 'RJ45'}',
              colorHex: '#0284C7',
            ),
          );
        }
      }
    }

    return DiagramExportDocument(
      moduleName: '5. Dashboard Global & Inventario DCIM',
      title: 'Inventario Global RackDoc — Hierro, Patch Panels y Enlaces (${nodes.length} equipos)',
      subtitle:
          '${_locations.length} Sedes • ${nodes.length} Equipos en Racks • ${edges.length} Bocas Conectadas',
      fileBaseName: 'rackdoc_inventario_global',
      canvasWidth: 1420,
      canvasHeight:
          (120.0 + ((nodes.length ~/ 5) + 1) * 115.0).clamp(900.0, 2800.0),
      zones: zones,
      nodes: nodes,
      edges: edges,
    );
  }

  Widget _buildDashboardOverview() {
    int totalFloors = 0;
    int totalRooms = 0;
    int totalRacks = 0;
    int totalUnmonitored = 0;
    int totalMonitored = 0;
    int totalOnline = 0;
    int totalOffline = 0;
    int totalWarning = 0;

    final allMonitoredSystems = <Map<String, dynamic>>[];
    final allRacksMeta = <Map<String, dynamic>>[];

    for (final l in _locations) {
      totalFloors += l.floorsCount;
      totalRooms += l.roomsCount;
      totalRacks += l.racksCount;
      totalUnmonitored += l.unmonitoredCount;
      totalMonitored += l.monitoredCount;
      totalOnline += l.onlineCount;
      totalOffline += l.offlineCount;
      totalWarning += l.warningCount;
      for (final f in l.floors) {
        for (final r in f.rooms) {
          for (final rk in r.racks) {
            allRacksMeta.add({
              'id': rk.id,
              'code': rk.code,
              'name': rk.name,
              'location_code': l.code,
              'floor_name': f.name,
            });
            for (final md in rk.monitoredDevices) {
              allMonitoredSystems.add({
                ...md,
                'location_id': l.id,
                'location_code': l.code,
                'location_name': l.name,
                'floor_name': f.name,
                'room_name': r.name,
                'rack_id': rk.id,
                'rack_code': rk.code,
                'rack_name': rk.name,
              });
            }
          }
        }
      }
    }

    // Extraer datos detallados de Hierro (Línea a Línea del Rack) y Patch Panels (Bocas 1..24)
    final rawRackLines = (_dashboardInventory?['rack_lines'] as List?) ?? const [];
    final rawPatchPanels = (_dashboardInventory?['patch_panels'] as List?) ?? const [];

    final allRackLines = rawRackLines
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((ln) =>
            _dashSelectedRackId == null || ln['rack_id'] == _dashSelectedRackId)
        .toList();

    final allPatchPanels = rawPatchPanels
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((pp) =>
            _dashSelectedRackId == null || pp['rack_id'] == _dashSelectedRackId)
        .toList();

    final int hierroCount =
        allRackLines.where((ln) => ln['kind_group'] == 'hierro').length;
    final int pasivoCount =
        allRackLines.where((ln) => ln['kind_group'] != 'hierro').length;
    final int totalPpBocas = allPatchPanels.fold<int>(
      0,
      (acc, pp) => acc + ((pp['total_bocas'] as num?)?.toInt() ?? 0),
    );
    final int occupiedPpBocas = allPatchPanels.fold<int>(
      0,
      (acc, pp) => acc + ((pp['occupied_bocas'] as num?)?.toInt() ?? 0),
    );
    final int freePpBocas = (totalPpBocas - occupiedPpBocas).clamp(0, 999999);

    // Filtrado de líneas del Rack (Hierro vs Pasivo + texto)
    final q = _dashSearchCtrl.text.trim().toLowerCase();
    final filteredRackLines = allRackLines.where((ln) {
      final kg = (ln['kind_group'] ?? '').toString();
      if (_dashRackLineKindFilter == 'hierro' && kg != 'hierro') return false;
      if (_dashRackLineKindFilter == 'pasivo' && kg == 'hierro') return false;
      if (q.isNotEmpty) {
        final hay = [
          ln['code'],
          ln['name'],
          ln['equipment_type_badge'],
          ln['manufacturer'],
          ln['model_name'],
          ln['hostname'],
          ln['fqdn'],
          ln['ip_address'],
          ln['rack_code'],
          ln['u_range'],
        ].map((e) => (e ?? '').toString().toLowerCase()).join(' ');
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList();

    // Filtrado de Patch Panels
    final filteredPatchPanels = allPatchPanels.where((pp) {
      if (_dashSelectedPatchPanelId != null &&
          pp['device_id'] != _dashSelectedPatchPanelId) {
        return false;
      }
      return true;
    }).toList();

    // Filtrado por texto, estado y método Heartbeat
    final filtered = allMonitoredSystems.where((sys) {
      if (_dashSelectedRackId != null && sys['rack_id'] != _dashSelectedRackId) {
        return false;
      }
      final st = (sys['status'] ?? 'unknown').toString().toLowerCase();
      final method = (sys['monitor_method'] ?? 'icmp').toString().toLowerCase();
      if (_dashStatusFilter != 'all' && st != _dashStatusFilter) {
        return false;
      }
      if (_dashMethodFilter != 'all' && method != _dashMethodFilter) {
        return false;
      }
      if (q.isNotEmpty) {
        final hay = [
          sys['code'],
          sys['name'],
          sys['hostname'],
          sys['ip_address'],
          sys['model_name'],
          sys['rack_code'],
          sys['location_code'],
          sys['monitor_method'],
        ].map((e) => (e ?? '').toString().toLowerCase()).join(' ');
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList();

    // Ordenación interactiva Heartbeat
    int statusPriority(String st) {
      if (st == 'offline') return 0; // Rojo primero
      if (st == 'warning') return 1;
      if (st == 'online') return 2; // Verde
      return 3;
    }

    filtered.sort((a, b) {
      int cmp = 0;
      switch (_dashSortBy) {
        case 'status':
          cmp = statusPriority((a['status'] ?? '').toString()).compareTo(
            statusPriority((b['status'] ?? '').toString()),
          );
          if (cmp == 0) {
            cmp = (a['code'] ?? '').toString().compareTo(
                  (b['code'] ?? '').toString(),
                );
          }
          break;
        case 'code':
          cmp = (a['code'] ?? '').toString().compareTo(
                (b['code'] ?? '').toString(),
              );
          break;
        case 'ip':
          cmp = (a['ip_address'] ?? '').toString().compareTo(
                (b['ip_address'] ?? '').toString(),
              );
          break;
        case 'rack':
          cmp = (a['rack_code'] ?? '').toString().compareTo(
                (b['rack_code'] ?? '').toString(),
              );
          break;
        case 'method':
          cmp = (a['monitor_method'] ?? '').toString().compareTo(
                (b['monitor_method'] ?? '').toString(),
              );
          break;
        case 'latency':
          final la = (a['last_ping_ms'] as num?)?.toDouble() ?? 999999.0;
          final lb = (b['last_ping_ms'] as num?)?.toDouble() ?? 999999.0;
          cmp = la.compareTo(lb);
          break;
      }
      return _dashSortAsc ? cmp : -cmp;
    });

    final bool showHierroLines = _dashMainSection == 'all_sections' ||
        _dashMainSection == 'hierro_lines';
    final bool showPatchPanels = _dashMainSection == 'all_sections' ||
        _dashMainSection == 'patch_panels';
    final bool showHeartbeat =
        _dashMainSection == 'all_sections' || _dashMainSection == 'heartbeat';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Dashboard: Hierro del Rack (U42→U1), Patch Panels (Bocas 1-24) & Excel',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: AppPalette.slate900,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Diferenciación línea por línea entre "Hierro" (Switches, Routers, Servidores, SAN/NAS, SAI, PDU) y Patch Panels boca a boca (ocupada o libre, qué aparato está conectado y qué IP tiene).',
                      style: TextStyle(fontSize: 13, color: AppPalette.slate500),
                    ),
                  ],
                ),
              ),
              if (!_isKioskMode) ...[
                OutlinedButton.icon(
                  onPressed: _toggleKioskMode,
                  icon: const Icon(Icons.tv_rounded, size: 17),
                  label: const Text('Modo Kiosco'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppPalette.slate900,
                    side: const BorderSide(color: AppPalette.slate400),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: _refreshDataSilently,
                  icon: const Icon(Icons.refresh, size: 17),
                  label: const Text('Actualizar Datos'),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: () {
                    final url = Uri.parse(_api.getExcelTemplateUrl());
                    launchUrl(url, mode: LaunchMode.externalApplication);
                  },
                  icon: const Icon(Icons.description_outlined, size: 17),
                  label: const Text('Plantilla Ejemplo (.xlsx)'),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: _showImportExcelDialog,
                  icon: const Icon(Icons.upload_file_rounded, size: 18),
                  label: const Text('Importar Excel (.xlsx)'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppPalette.blue900,
                  ),
                ),
                const SizedBox(width: 10),
                DiagramExportMenuButton(
                  buttonLabel: _dashSelectedRackId != null
                      ? 'Exportar Rack (.xlsx / .dia / .png / .pdf / .csv)'
                      : 'Exportar Todo (.xlsx / .dia / .png / .pdf / .csv)',
                  onExportExcel: () {
                    final url = Uri.parse(
                      _api.getExcelExportUrl(rackId: _dashSelectedRackId),
                    );
                    launchUrl(url, mode: LaunchMode.externalApplication);
                  },
                  documentBuilder: _buildGlobalExportDocument,
                ),
              ],
            ],
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: [
              _DashboardCard(
                title: 'Datacenters / Plantas / Racks',
                value:
                    '${_locations.length} Sedes / $totalFloors Plantas / $totalRacks Racks ($totalRooms Salas)',
                icon: Icons.public,
                color: AppPalette.blue600,
              ),
              _DashboardCard(
                title: 'Hierro en Rack (Equipos Activos)',
                value: '$hierroCount Equipos Hierro • $pasivoCount Pasivos',
                icon: Icons.dns_rounded,
                color: AppPalette.indigo600,
              ),
              _DashboardCard(
                title: 'Patch Panels (Mapa de Bocas)',
                value:
                    '${allPatchPanels.length} Panels • $occupiedPpBocas Ocup. / $freePpBocas Libres',
                icon: Icons.settings_input_component_rounded,
                color: AppPalette.teal600,
              ),
              _DashboardCard(
                title: 'Sin Heartbeat (Gris)',
                value: '⚪ $totalUnmonitored Desactivados',
                icon: Icons.radio_button_unchecked_rounded,
                color: AppPalette.slate500,
              ),
              _DashboardCard(
                title: 'Estado Online (Verde)',
                value: '🟢 $totalOnline Online (de $totalMonitored act.)',
                icon: Icons.check_circle_outline,
                color: AppPalette.green600,
              ),
              _DashboardCard(
                title: 'Fallo Parcial (Naranja)',
                value: '🟠 $totalWarning Parcial (1+ chequeo)',
                icon: Icons.warning_amber_rounded,
                color: AppPalette.amber600,
              ),
              _DashboardCard(
                title: 'Fallo Total (Rojo)',
                value: '🔴 $totalOffline Offline',
                icon: Icons.error_outline,
                color: AppPalette.red600,
              ),
            ],
          ),

          const SizedBox(height: 20),

          // BARRA GLOBAL DE FILTRO POR RACK Y NAVEGACIÓN DE SECCIONES DEL DASHBOARD
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppPalette.slate300),
            ),
            child: Wrap(
              spacing: 16,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.filter_alt_outlined,
                      size: 18,
                      color: AppPalette.blue900,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Filtrar por Rack:',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: AppPalette.slate900,
                      ),
                    ),
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 260,
                      child: DropdownButtonFormField<int?>(
                        initialValue: _dashSelectedRackId,
                        isDense: true,
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          filled: true,
                          fillColor: AppPalette.slate50,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        items: [
                          const DropdownMenuItem<int?>(
                            value: null,
                            child: Text(
                              'Todos los Racks del CPD',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          ...allRacksMeta.map(
                            (rk) => DropdownMenuItem<int?>(
                              value: rk['id'] as int,
                              child: Text(
                                '${rk['location_code']} > ${rk['code']} (${rk['name']})',
                                style: const TextStyle(fontSize: 12),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                        ],
                        onChanged: (val) {
                          _rebuildState(() {
                            _dashSelectedRackId = val;
                            _dashSelectedPatchPanelId = null;
                          });
                        },
                      ),
                    ),
                  ],
                ),
                SegmentedButton<String>(
                  segments: [
                    const ButtonSegment(
                      value: 'all_sections',
                      icon: Icon(Icons.view_agenda_outlined, size: 16),
                      label: Text('Todo', style: TextStyle(fontSize: 11.5)),
                    ),
                    ButtonSegment(
                      value: 'hierro_lines',
                      icon: const Icon(Icons.dns_rounded, size: 16),
                      label: Text(
                        '1. Hierro & Líneas Rack (${allRackLines.length})',
                        style: const TextStyle(fontSize: 11.5),
                      ),
                    ),
                    ButtonSegment(
                      value: 'patch_panels',
                      icon: const Icon(
                        Icons.settings_input_component_rounded,
                        size: 16,
                      ),
                      label: Text(
                        '2. Patch Panels Bocas 1-24 (${allPatchPanels.length})',
                        style: const TextStyle(fontSize: 11.5),
                      ),
                    ),
                    ButtonSegment(
                      value: 'heartbeat',
                      icon: const Icon(Icons.monitor_heart_outlined, size: 16),
                      label: Text(
                        '3. Heartbeat ($totalMonitored)',
                        style: const TextStyle(fontSize: 11.5),
                      ),
                    ),
                  ],
                  selected: {_dashMainSection},
                  onSelectionChanged: (s) {
                    _rebuildState(() => _dashMainSection = s.first);
                  },
                ),
                SizedBox(
                  width: 260,
                  child: TextField(
                    controller: _dashSearchCtrl,
                    onChanged: (_) => _rebuildState(() {}),
                    decoration: InputDecoration(
                      hintText: 'Buscar equipo, boca, aparato o IP...',
                      prefixIcon: const Icon(Icons.search, size: 17),
                      suffixIcon: _dashSearchCtrl.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 15),
                              onPressed: () {
                                _dashSearchCtrl.clear();
                                _rebuildState(() {});
                              },
                            )
                          : null,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      filled: true,
                      fillColor: AppPalette.slate50,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ====================================================================
          // SECCIÓN 1: HIERRO vs PASIVOS — LÍNEA POR LÍNEA DEL RACK (U42 -> U1)
          // ====================================================================
          if (showHierroLines) ...[
            const SizedBox(height: 24),
            _buildRackLinesSection(
              filteredRackLines: filteredRackLines,
              hierroCount: hierroCount,
              pasivoCount: pasivoCount,
            ),
          ],

          // ====================================================================
          // SECCIÓN 2: PATCH PANELS — DETALLE BOCA POR BOCA (1..24)
          // ====================================================================
          if (showPatchPanels) ...[
            const SizedBox(height: 24),
            _buildPatchPanelsBocasSection(
              allPatchPanels: allPatchPanels,
              filteredPatchPanels: filteredPatchPanels,
              totalPpBocas: totalPpBocas,
              occupiedPpBocas: occupiedPpBocas,
              freePpBocas: freePpBocas,
              searchQuery: q,
            ),
          ],

          // ====================================================================
          // SECCIÓN 3: LISTADO DE SISTEMAS MONITORIZADOS (HEARTBEAT)
          // ====================================================================
          if (showHeartbeat) ...[
            const SizedBox(height: 24),

          // LISTADO ORGANIZABLE Y BUSCABLE DE SISTEMAS MONITORIZADOS
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppPalette.slate200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.monitor_heart_rounded,
                      color: AppPalette.blue900,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '3. Monitorización Heartbeat en Tiempo Real (${filtered.length} de $totalMonitored)',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: AppPalette.slate900,
                      ),
                    ),
                    const Spacer(),
                    // Filtro rápido por estado
                    SegmentedButton<String>(
                      segments: [
                        ButtonSegment(
                          value: 'all',
                          label: Text(
                            'Todos ($totalMonitored)',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                        ButtonSegment(
                          value: 'online',
                          label: Text(
                            '${totalOnline > 0 ? '🟢 ' : ''}Verde ($totalOnline)',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                        ButtonSegment(
                          value: 'offline',
                          label: Text(
                            '${totalOffline > 0 ? '🔴 ' : ''}Rojo ($totalOffline)',
                            style: const TextStyle(fontSize: 11),
                          ),
                        ),
                      ],
                      selected: {_dashStatusFilter},
                      onSelectionChanged: (s) {
                        _rebuildState(() => _dashStatusFilter = s.first);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                // Barra de búsqueda, filtro por método y selector de ordenación
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _dashSearchCtrl,
                        onChanged: (_) => _rebuildState(() {}),
                        decoration: InputDecoration(
                          hintText:
                              'Buscar por hostname, código, IP, modelo, rack o datacenter...',
                          prefixIcon: const Icon(Icons.search, size: 18),
                          suffixIcon: _dashSearchCtrl.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 16),
                                  onPressed: () {
                                    _dashSearchCtrl.clear();
                                    _rebuildState(() {});
                                  },
                                )
                              : null,
                          isDense: true,
                          filled: true,
                          fillColor: AppPalette.slate50,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(
                              color: AppPalette.slate300,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: DropdownButtonFormField<String>(
                        initialValue: _dashMethodFilter,
                        isDense: true,
                        decoration: InputDecoration(
                          labelText: 'Filtrar Método Heartbeat',
                          isDense: true,
                          filled: true,
                          fillColor: AppPalette.slate50,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'all',
                            child: Text('Todos los métodos', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'icmp',
                            child: Text('ICMP Ping', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'ssh',
                            child: Text('SSH (22)', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'https',
                            child: Text('HTTPS / SSL', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'http',
                            child: Text('HTTP URL', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'tcp',
                            child: Text('TCP Port', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'snmp',
                            child: Text('SNMP', style: TextStyle(fontSize: 12)),
                          ),
                        ],
                        onChanged: (v) =>
                            _rebuildState(() => _dashMethodFilter = v ?? 'all'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: DropdownButtonFormField<String>(
                        initialValue: _dashSortBy,
                        isDense: true,
                        decoration: InputDecoration(
                          labelText: 'Organizar / Ordenar por',
                          isDense: true,
                          filled: true,
                          fillColor: AppPalette.slate50,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'status',
                            child: Text('Estado (Rojo / Alertas primero)', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'code',
                            child: Text('Código / Hostname', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'ip',
                            child: Text('Dirección IP', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'rack',
                            child: Text('Datacenter / Rack', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'method',
                            child: Text('Método Heartbeat', style: TextStyle(fontSize: 12)),
                          ),
                          DropdownMenuItem(
                            value: 'latency',
                            child: Text('Latencia (ms)', style: TextStyle(fontSize: 12)),
                          ),
                        ],
                        onChanged: (v) =>
                            _rebuildState(() => _dashSortBy = v ?? 'status'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.outlined(
                      tooltip: _dashSortAsc
                          ? 'Orden Ascendente (pulsa para invertir)'
                          : 'Orden Descendente (pulsa para invertir)',
                      onPressed: () =>
                          _rebuildState(() => _dashSortAsc = !_dashSortAsc),
                      icon: Icon(
                        _dashSortAsc
                            ? Icons.arrow_upward_rounded
                            : Icons.arrow_downward_rounded,
                        size: 18,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                const Divider(height: 1),
                if (filtered.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(
                      child: Text(
                        'No se encontraron sistemas monitorizados con los filtros actuales.',
                        style: TextStyle(color: AppPalette.slate500),
                      ),
                    ),
                  )
                else
                  ...filtered.map((sys) {
                    final st = (sys['status'] ?? 'unknown').toString();
                    final isOnline = st == 'online';
                    final isOffline = st == 'offline';
                    final stCol = isOnline
                        ? AppPalette.green600
                        : (isOffline
                            ? AppPalette.red600
                            : AppPalette.amber600);
                    final method = (sys['monitor_method'] ?? 'icmp')
                        .toString()
                        .toUpperCase();
                    final port = sys['monitor_port'] ?? 22;
                    final pingMs = sys['last_ping_ms'];
                    final rackId = sys['rack_id'] as int;

                    final devId = sys['id'] as int?;

                    return InkWell(
                      onTap: () => _openRack(
                        rackId,
                        highlightDeviceId: devId,
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: isOffline
                              ? AppPalette.red50
                              : Colors.transparent,
                          border: const Border(
                            bottom: BorderSide(color: AppPalette.slate100),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: stCol.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: stCol.withValues(alpha: 0.45),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      color: stCol,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    isOnline
                                        ? 'VERDE (ONLINE)'
                                        : (isOffline
                                            ? 'ROJO (OFFLINE)'
                                            : st.toUpperCase()),
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w800,
                                      color: stCol,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              flex: 3,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${sys['code']} — ${sys['name']}',
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w800,
                                      color: AppPalette.slate900,
                                    ),
                                  ),
                                  Text(
                                    '${sys['model_name']} • Hostname: ${sys['hostname']?.toString().isNotEmpty == true ? sys['hostname'] : '-'}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: AppPalette.slate500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'IP: ${sys['ip_address']?.toString().isNotEmpty == true ? sys['ip_address'] : 'Sin IP'}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: AppPalette.slate800,
                                    ),
                                  ),
                                  Text(
                                    'Heartbeat: $method (Puerto $port)${pingMs != null ? ' • $pingMs ms' : ''}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: AppPalette.slate600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              flex: 2,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${sys['location_code']} > ${sys['rack_code']} (U${sys['start_u']})',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: AppPalette.blue900,
                                    ),
                                  ),
                                  Text(
                                    '${sys['floor_name']} • ${sys['rack_name']}',
                                    style: const TextStyle(
                                      fontSize: 10.5,
                                      color: AppPalette.slate500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            FilledButton.tonalIcon(
                              onPressed: () => _openRack(
                                rackId,
                                highlightDeviceId: devId,
                              ),
                              icon: const Icon(
                                Icons.my_location_rounded,
                                size: 15,
                              ),
                              label: const Text(
                                'Localizar en Rack',
                                style: TextStyle(fontSize: 11.5),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
              ],
            ),
          ),
          ],
        ],
      ),
    );
  }

  Widget _buildRackLinesSection({
    required List<Map<String, dynamic>> filteredRackLines,
    required int hierroCount,
    required int pasivoCount,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppPalette.slate200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.dns_rounded,
                color: AppPalette.indigo600,
                size: 21,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '1. Desglose Línea a Línea del Rack (U42 → U1) — "Hierro" vs Patch Panels (${filteredRackLines.length} líneas)',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: AppPalette.slate900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      'Diferencia claramente qué hay montado en cada U del armario: equipos de "Hierro" activos (Switches, Routers, Firewalls, Servidores, SAN/NAS, SAI, PDUs) frente a Patch Panels y pasivos.',
                      style: TextStyle(fontSize: 12, color: AppPalette.slate500),
                    ),
                  ],
                ),
              ),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                    value: 'all',
                    label: Text(
                      'Todas (${hierroCount + pasivoCount})',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  ButtonSegment(
                    value: 'hierro',
                    label: Text(
                      '⚙️ Solo Hierro ($hierroCount)',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  ButtonSegment(
                    value: 'pasivo',
                    label: Text(
                      '🔌 Patch Panels / Pasivos ($pasivoCount)',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ],
                selected: {_dashRackLineKindFilter},
                onSelectionChanged: (s) {
                  _rebuildState(() => _dashRackLineKindFilter = s.first);
                },
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(height: 1),
          if (filteredRackLines.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: Text(
                  'No hay líneas de Rack para el filtro seleccionado.',
                  style: TextStyle(color: AppPalette.slate500),
                ),
              ),
            )
          else
            ...filteredRackLines.map((ln) {
              final kg = (ln['kind_group'] ?? 'hierro').toString();
              final isHierro = kg == 'hierro';
              final isPatchPanel = kg == 'patch_panel';
              final badgeText = (ln['equipment_type_badge'] ?? '').toString();
              final badgeColor = isHierro
                  ? AppPalette.indigo600
                  : (isPatchPanel
                      ? AppPalette.teal600
                      : AppPalette.slate500);

              final st = (ln['status'] ?? 'unknown').toString().toLowerCase();
              final isOnline = st == 'online';
              final isOffline = st == 'offline';
              final ipStr = (ln['ip_address'] ?? '').toString();
              final occPorts = (ln['occupied_ports'] as num?)?.toInt() ?? 0;
              final totPorts = (ln['total_ports'] as num?)?.toInt() ?? 0;
              final freePorts = (ln['free_ports'] as num?)?.toInt() ?? 0;
              final rackId = ln['rack_id'] as int;
              final devId = ln['device_id'] as int?;

              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: isHierro
                      ? AppPalette.slate50
                      : const Color(0xFFF0FDFA).withValues(alpha: 0.45),
                  border: const Border(
                    bottom: BorderSide(color: AppPalette.slate200),
                  ),
                ),
                child: Row(
                  children: [
                    // Unidad U + Cara
                    Container(
                      width: 82,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: AppPalette.slate900,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Column(
                        children: [
                          Text(
                            '${ln['u_range']}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w900,
                              color: Colors.white,
                            ),
                          ),
                          Text(
                            '${ln['rack_code']} • ${ln['mounted_face']}',
                            style: const TextStyle(
                              fontSize: 9.5,
                              color: AppPalette.slate400,
                              fontWeight: FontWeight.w700,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Badge HIERRO vs PATCH PANEL
                    Container(
                      width: 185,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: badgeColor.withValues(alpha: 0.45),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isHierro
                                ? Icons.memory_rounded
                                : Icons.settings_input_component_rounded,
                            size: 14,
                            color: badgeColor,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              badgeText,
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                color: badgeColor,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 14),
                    // Código, Nombre y Modelo
                    Expanded(
                      flex: 3,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${ln['code']} — ${ln['name']}',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              color: AppPalette.slate900,
                            ),
                          ),
                          Text(
                            '${ln['manufacturer']} ${ln['model_name']}${ln['hostname']?.toString().isNotEmpty == true ? ' • Host: ${ln['hostname']}' : ''}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppPalette.slate500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // IP y Estado
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.lan_outlined,
                                size: 14,
                                color: AppPalette.slate700,
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  ipStr.isNotEmpty
                                      ? 'IP: $ipStr'
                                      : (isHierro
                                          ? 'IP: Sin IP asignada'
                                          : 'Elemento Pasivo (Sin IP)'),
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w800,
                                    color: ipStr.isNotEmpty
                                        ? AppPalette.blue700
                                        : AppPalette.slate500,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            isHierro
                                ? (isOnline
                                    ? '🟢 ONLINE${ln['last_ping_ms'] != null ? ' (${ln['last_ping_ms']} ms)' : ''}'
                                    : (isOffline
                                        ? '🔴 OFFLINE / CAÍDO'
                                        : '⚪ Estado: ${st.toUpperCase()}'))
                                : '🔌 Panel Pasivo en Rack',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: isHierro
                                  ? (isOnline
                                      ? AppPalette.green600
                                      : (isOffline
                                          ? AppPalette.red600
                                          : AppPalette.slate500))
                                  : AppPalette.teal600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Ocupación de Bocas
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            totPorts > 0
                                ? '$occPorts ocupadas / $freePorts libres (de $totPorts)'
                                : 'Sin bocas de datos',
                            style: const TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                              color: AppPalette.slate800,
                            ),
                          ),
                          if (totPorts > 0) ...[
                            const SizedBox(height: 4),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: (occPorts / totPorts).clamp(0.0, 1.0),
                                minHeight: 6,
                                backgroundColor: AppPalette.slate200,
                                color: isPatchPanel
                                    ? AppPalette.teal600
                                    : AppPalette.indigo600,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    if (isPatchPanel) ...[
                      OutlinedButton.icon(
                        onPressed: () {
                          _rebuildState(() {
                            _dashMainSection = 'patch_panels';
                            _dashSelectedPatchPanelId = devId;
                          });
                        },
                        icon: const Icon(
                          Icons.grid_view_rounded,
                          size: 14,
                        ),
                        label: const Text(
                          'Ver Bocas 1-24',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                      const SizedBox(width: 6),
                    ],
                    FilledButton.tonalIcon(
                      onPressed: () => _openRack(
                        rackId,
                        highlightDeviceId: devId,
                      ),
                      icon: const Icon(Icons.my_location_rounded, size: 14),
                      label: const Text(
                        'Ir al Rack',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildPatchPanelsBocasSection({
    required List<Map<String, dynamic>> allPatchPanels,
    required List<Map<String, dynamic>> filteredPatchPanels,
    required int totalPpBocas,
    required int occupiedPpBocas,
    required int freePpBocas,
    required String searchQuery,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppPalette.slate200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Icon(
                Icons.settings_input_component_rounded,
                color: AppPalette.teal600,
                size: 22,
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '2. Información de Patch Panels — Detalle Boca por Boca ($occupiedPpBocas Ocupadas / $freePpBocas Libres de $totalPpBocas)',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      color: AppPalette.slate900,
                    ),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'Muestra cada boca (1..24) del Patch Panel: si está conectada o libre, a qué Switch ("Hierro") va unida y qué aparato final está conectado (cuál es, tipo y dirección IP).',
                    style: TextStyle(fontSize: 12, color: AppPalette.slate500),
                  ),
                ],
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 240,
                child: DropdownButtonFormField<int?>(
                  initialValue: _dashSelectedPatchPanelId,
                  isDense: true,
                  decoration: InputDecoration(
                    labelText: 'Seleccionar Patch Panel',
                    isDense: true,
                    filled: true,
                    fillColor: AppPalette.slate50,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  items: [
                    const DropdownMenuItem<int?>(
                      value: null,
                      child: Text(
                        'Todos los Patch Panels',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    ...allPatchPanels.map(
                      (pp) => DropdownMenuItem<int?>(
                        value: pp['device_id'] as int,
                        child: Text(
                          '[${pp['rack_code']} ${pp['u_range']}] ${pp['code']} — ${pp['name']}',
                          style: const TextStyle(fontSize: 11.5),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                  ],
                  onChanged: (val) {
                    _rebuildState(() => _dashSelectedPatchPanelId = val);
                  },
                ),
              ),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                    value: 'all',
                    label: Text(
                      'Todas ($totalPpBocas)',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  ButtonSegment(
                    value: 'occupied',
                    label: Text(
                      '🟢 Con Aparato / Conectadas ($occupiedPpBocas)',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                  ButtonSegment(
                    value: 'free',
                    label: Text(
                      '⚪ Bocas Libres ($freePpBocas)',
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                ],
                selected: {_dashPatchBocaFilter},
                onSelectionChanged: (s) {
                  _rebuildState(() => _dashPatchBocaFilter = s.first);
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),
          if (filteredPatchPanels.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: Text(
                  'No hay Patch Panels registrados en el Rack seleccionado.',
                  style: TextStyle(color: AppPalette.slate500),
                ),
              ),
            )
          else
            ...filteredPatchPanels.map((pp) {
              final rawBocas = (pp['bocas'] as List?) ?? const [];
              final allBocas = rawBocas
                  .map((b) => Map<String, dynamic>.from(b as Map))
                  .toList();

              final visibleBocas = allBocas.where((b) {
                final isOcc = b['is_occupied'] == true;
                if (_dashPatchBocaFilter == 'occupied' && !isOcc) return false;
                if (_dashPatchBocaFilter == 'free' && isOcc) return false;
                if (searchQuery.isNotEmpty) {
                  final sw = (b['switch_hardware'] as Map?) ?? const {};
                  final ep = (b['connected_device'] as Map?) ?? const {};
                  final hay = [
                    pp['code'],
                    pp['name'],
                    b['port_label'],
                    b['status_text'],
                    b['cable_label'],
                    sw['code'],
                    sw['name'],
                    sw['ip_address'],
                    ep['code'],
                    ep['name'],
                    ep['device_type_label'],
                    ep['ip_address'],
                    ep['room_code'],
                  ].map((e) => (e ?? '').toString().toLowerCase()).join(' ');
                  if (!hay.contains(searchQuery)) return false;
                }
                return true;
              }).toList();

              final rackId = pp['rack_id'] as int;
              final devId = pp['device_id'] as int?;
              final occCnt = (pp['occupied_bocas'] as num?)?.toInt() ?? 0;
              final freeCnt = (pp['free_bocas'] as num?)?.toInt() ?? 0;
              final totCnt = (pp['total_bocas'] as num?)?.toInt() ?? 24;

              return Container(
                margin: const EdgeInsets.only(top: 16),
                decoration: BoxDecoration(
                  color: AppPalette.slate50,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppPalette.slate300),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Cabecera del Patch Panel + tira visual de 24 bocas
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: const BoxDecoration(
                        color: AppPalette.slate900,
                        borderRadius: BorderRadius.vertical(
                          top: Radius.circular(9),
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: AppPalette.teal600,
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              '${pp['rack_code']} • ${pp['u_range']}',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w900,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Patch Panel ${pp['code']} — ${pp['name']} (${pp['manufacturer']} ${pp['model_name']})',
                              style: const TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: AppPalette.slate800,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: AppPalette.slate600,
                              ),
                            ),
                            child: Text(
                              '🟢 $occCnt Ocupadas  •  ⚪ $freeCnt Libres  (Total: $totCnt bocas)',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: AppPalette.slate200,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          FilledButton.tonalIcon(
                            onPressed: () => _openRack(
                              rackId,
                              highlightDeviceId: devId,
                            ),
                            icon: const Icon(
                              Icons.open_in_new_rounded,
                              size: 14,
                            ),
                            label: const Text(
                              'Ver en Rack Editor',
                              style: TextStyle(fontSize: 11),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Tira gráfica rápida de las 24 bocas (clic o resumen visual)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: const BoxDecoration(
                        color: AppPalette.slate100,
                        border: Border(
                          bottom: BorderSide(color: AppPalette.slate300),
                        ),
                      ),
                      child: Wrap(
                        spacing: 5,
                        runSpacing: 5,
                        children: allBocas.map((b) {
                          final isOcc = b['is_occupied'] == true;
                          final ep = (b['connected_device'] as Map?) ?? const {};
                          final sw = (b['switch_hardware'] as Map?) ?? const {};
                          final tooltipMsg = isOcc
                              ? 'Boca ${b['port_label']}: OCUPADA\n'
                                  'Aparato: ${ep['code'] ?? '-'} (${ep['name'] ?? '-'})\n'
                                  'IP Aparato: ${ep['ip_address'] ?? 'Sin IP'}\n'
                                  'Switch: ${sw['code'] ?? '-'} (Puerto ${sw['port'] ?? '-'})'
                              : 'Boca ${b['port_label']}: LIBRE (Sin nada conectado)';
                          return Tooltip(
                            message: tooltipMsg,
                            child: Container(
                              width: 34,
                              height: 24,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: isOcc
                                    ? AppPalette.teal600
                                    : Colors.white,
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                  color: isOcc
                                      ? AppPalette.teal700
                                      : AppPalette.slate300,
                                  width: isOcc ? 1.4 : 1.0,
                                ),
                              ),
                              child: Text(
                                '${b['port_label']}',
                                style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w800,
                                  color: isOcc
                                      ? Colors.white
                                      : AppPalette.slate500,
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),

                    // Encabezado de columnas de las bocas
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      color: AppPalette.slate200.withValues(alpha: 0.55),
                      child: const Row(
                        children: [
                          SizedBox(
                            width: 92,
                            child: Text(
                              'BOCA Nº',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w900,
                                color: AppPalette.slate700,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 135,
                            child: Text(
                              'ESTADO BOCA',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w900,
                                color: AppPalette.slate700,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Text(
                              'CONEXIÓN EN RACK (HACIA SWITCH / HIERRO)',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w900,
                                color: AppPalette.slate700,
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 3,
                            child: Text(
                              'APARATO CONECTADO (CUÁL ES, TIPO Y UBICACIÓN)',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w900,
                                color: AppPalette.slate700,
                              ),
                            ),
                          ),
                          SizedBox(
                            width: 175,
                            child: Text(
                              'DIRECCIÓN IP APARATO',
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w900,
                                color: AppPalette.slate700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    if (visibleBocas.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'No hay bocas en este Patch Panel que coincidan con el filtro actual.',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppPalette.slate500,
                          ),
                        ),
                      )
                    else
                      ...visibleBocas.map((b) {
                        final isOcc = b['is_occupied'] == true;
                        final sw = b['switch_hardware'] != null
                            ? Map<String, dynamic>.from(
                                b['switch_hardware'] as Map,
                              )
                            : null;
                        final ep = b['connected_device'] != null
                            ? Map<String, dynamic>.from(
                                b['connected_device'] as Map,
                              )
                            : null;
                        final slotNum =
                            (b['slot_number'] as num?)?.toInt() ?? 1;
                        final portLbl = (b['port_label'] ?? '$slotNum').toString();
                        final portType =
                            (b['port_type'] ?? 'rj45').toString().toUpperCase();
                        final epIp = (ep?['ip_address'] ?? '').toString();
                        final hasValidIp = epIp.isNotEmpty &&
                            !epIp.toLowerCase().contains('sin ip') &&
                            !epIp.toLowerCase().contains('pasiv');

                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: isOcc
                                ? Colors.white
                                : AppPalette.slate50,
                            border: const Border(
                              bottom: BorderSide(color: AppPalette.slate200),
                            ),
                          ),
                          child: Row(
                            children: [
                              // Boca Nº
                              SizedBox(
                                width: 92,
                                child: Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 7,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isOcc
                                            ? AppPalette.slate900
                                            : AppPalette.slate200,
                                        borderRadius: BorderRadius.circular(5),
                                      ),
                                      child: Text(
                                        'Boca ${slotNum.toString().padLeft(2, '0')}',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w900,
                                          color: isOcc
                                              ? Colors.white
                                              : AppPalette.slate600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // Estado (OCUPADA vs LIBRE)
                              SizedBox(
                                width: 135,
                                child: Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isOcc
                                            ? AppPalette.green100
                                            : AppPalette.slate100,
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(
                                          color: isOcc
                                              ? AppPalette.green600
                                              : AppPalette.slate300,
                                        ),
                                      ),
                                      child: Text(
                                        isOcc
                                            ? '🟢 OCUPADA ($portLbl)'
                                            : '⚪ LIBRE ($portType)',
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w800,
                                          color: isOcc
                                              ? AppPalette.green700
                                              : AppPalette.slate500,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // Lado Switch / Hierro del Rack
                              Expanded(
                                flex: 2,
                                child: sw != null
                                    ? Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '${sw['code']} : Boca ${sw['port']}',
                                            style: const TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w800,
                                              color: AppPalette.indigo600,
                                            ),
                                          ),
                                          Text(
                                            '${sw['name']}${sw['ip_address']?.toString().isNotEmpty == true ? ' • IP SW: ${sw['ip_address']}' : ''}',
                                            style: const TextStyle(
                                              fontSize: 10.5,
                                              color: AppPalette.slate500,
                                            ),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      )
                                    : Text(
                                        isOcc
                                            ? 'Conexión directa en planta / trasera'
                                            : '— Sin conexión a Switch —',
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: AppPalette.slate400,
                                        ),
                                      ),
                              ),

                              // Lado Aparato / Dispositivo Conectado (Cuál es y tipo)
                              Expanded(
                                flex: 3,
                                child: ep != null
                                    ? Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 6,
                                                  vertical: 1.5,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: AppPalette.sky100,
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                ),
                                                child: Text(
                                                  '${ep['device_type_label'] ?? ep['device_type'] ?? 'Aparato'}',
                                                  style: const TextStyle(
                                                    fontSize: 9.5,
                                                    fontWeight: FontWeight.w800,
                                                    color: AppPalette.sky700,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              Expanded(
                                                child: Text(
                                                  '${ep['code']} — ${ep['name']}',
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w800,
                                                    color: AppPalette.slate900,
                                                  ),
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            'Ubicación: ${ep['room_code']?.toString().isNotEmpty == true ? ep['room_code'] : 'Planta'}${b['vlan'] != null ? ' • VLAN ${b['vlan']}' : ''}',
                                            style: const TextStyle(
                                              fontSize: 10.5,
                                              color: AppPalette.slate500,
                                            ),
                                          ),
                                        ],
                                      )
                                    : const Text(
                                        'Sin nada conectado (Boca disponible)',
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          fontStyle: FontStyle.italic,
                                          color: AppPalette.slate400,
                                        ),
                                      ),
                              ),

                              // Dirección IP del Aparato conectado
                              SizedBox(
                                width: 175,
                                child: ep != null
                                    ? Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 9,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: hasValidIp
                                              ? AppPalette.blue50
                                              : AppPalette.slate100,
                                          borderRadius:
                                              BorderRadius.circular(6),
                                          border: Border.all(
                                            color: hasValidIp
                                                ? AppPalette.blue300
                                                : AppPalette.slate300,
                                          ),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.language_rounded,
                                              size: 13,
                                              color: hasValidIp
                                                  ? AppPalette.blue700
                                                  : AppPalette.slate500,
                                            ),
                                            const SizedBox(width: 5),
                                            Expanded(
                                              child: Text(
                                                hasValidIp
                                                    ? 'IP: $epIp'
                                                    : (epIp.isNotEmpty
                                                        ? epIp
                                                        : 'Sin IP'),
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w800,
                                                  color: hasValidIp
                                                      ? AppPalette.blue900
                                                      : AppPalette.slate500,
                                                ),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      )
                                    : const Text(
                                        '—',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: AppPalette.slate300,
                                        ),
                                      ),
                              ),
                            ],
                          ),
                        );
                      }),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }
}
