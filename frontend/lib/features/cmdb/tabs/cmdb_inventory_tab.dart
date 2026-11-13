part of '../cmdb_view.dart';

/// Pestaña 1 de `6. CMDB & Control IPs`: tabla estilo hoja de cálculo ordenable,
/// gestión Multi-IP, saltos a Rack/Stack y asistente de colisiones de IP.
extension _CmdbInventoryTabExt on _CmdbViewState {
  // ===========================================================================
  // PESTAÑA 1: INVENTARIO CMDB & MULTI-IP (VISTA TABLA ESTILO EXCEL ORDENABLE)
  // ===========================================================================
  void _onSortInventoryBy(String colKey) {
    _rebuildState(() {
      if (_sortColumn == colKey) {
        _sortAscending = !_sortAscending;
      } else {
        _sortColumn = colKey;
        _sortAscending = true;
      }
    });
  }

  Future<void> _deleteSelectedInventoryAssets() async {
    if (_selectedInventoryAssetIds.isEmpty) return;
    final count = _selectedInventoryAssetIds.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Eliminar $count equipo(s) y liberar sus IPs'),
        content: Text(
          '¿Confirmas que deseas eliminar los $count equipo(s) seleccionados de la CMDB y dejar todas sus direcciones IP como NO OCUPADAS (Libres) en el mapa IPAM?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppPalette.red600,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sí, Eliminar y Liberar IPs'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final ids = _selectedInventoryAssetIds.toList();
    for (final id in ids) {
      try {
        await widget.api.deleteCmdbAsset(id);
      } catch (_) {}
    }
    _rebuildState(() {
      _selectedInventoryAssetIds.clear();
    });
    await _loadOverview(silent: true);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: AppPalette.green700,
        content: Text(
          'Se han eliminado $count equipo(s) y sus IPs han quedado libres.',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ),
    );
  }

  void _jumpToIpInIpamMap(String ipAddr) {
    if (ipAddr.isEmpty) return;
    int? targetSubnetId = _selectedIpamSubnetId;
    final prefix3 = ipAddr.rsplitThreeOctets();
    for (final s in _subnets) {
      final cidr = (s['cidr'] ?? '').toString();
      if (cidr.startsWith('$prefix3.')) {
        targetSubnetId = s['id'] as int?;
        break;
      }
    }
    _rebuildState(() {
      if (targetSubnetId != null) {
        _selectedIpamSubnetId = targetSubnetId;
      }
      _activeTab = 'subnets_ipam';
    });
  }

  Future<void> _toggleAssetHeartbeatMonitoring(Map<String, dynamic> asset) async {
    final int id = asset['id'] as int;
    final bool currentVal = asset['monitoring_enabled'] ?? true;
    final bool nextVal = !currentVal;
    try {
      await widget.api.updateCmdbAsset(id, {
        'monitoring_enabled': nextVal,
      });
      await _loadOverview(silent: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor:
              nextVal ? AppPalette.green700 : AppPalette.slate600,
          content: Text(
            nextVal
                ? 'Heartbeat ACTIVADO para [${asset['code']}] (${_primaryIpOfAsset(asset)})'
                : 'Heartbeat DESACTIVADO para [${asset['code']}]',
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).aviso('Error actualizando Heartbeat: $e');
    }
  }

  Widget _buildIpCollisionsAlertBanner() {
    final collisions = _ipCollisions;
    if (collisions.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppPalette.red50,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: const Color(0xFFEF4444), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                color: AppPalette.red700,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Atención: Se han detectado ${collisions.length} colisión(es) de IP entre equipos de la CMDB y el Rack Editor',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w900,
                    color: AppPalette.red800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ...collisions.map((c) {
            final String ipAddr = (c['ip_address'] ?? '').toString();
            final List<Map<String, dynamic>> involved =
                ((c['assets'] as List?) ?? [])
                    .map((e) => Map<String, dynamic>.from(e as Map))
                    .toList();
            final String desc = involved
                .map(
                  (a) =>
                      '[${a['code']}] ${a['name']} (${a['sync_source'] == 'rack_device' ? 'Rack Editor: ${a['physical_location_label']}' : 'CMDB'})',
                )
                .join('  ⚡  ');
            return Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppPalette.red700,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'IP $ipAddr',
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      desc,
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF7F1D1D),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (widget.canEdit)
                    FilledButton.icon(
                      onPressed: () => _openResolveCollisionDialog(c),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppPalette.red700,
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(Icons.merge_type_rounded, size: 15),
                      label: const Text(
                        'Resolver Colisión / Unificar Equipos',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
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
  }

  Future<void> _openResolveCollisionDialog(
    Map<String, dynamic> collision,
  ) async {
    final String ipAddr = (collision['ip_address'] ?? '').toString();
    final List<Map<String, dynamic>> involved =
        ((collision['assets'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
    if (involved.length < 2) return;

    // Priorizar como "keep" el equipo que esté montado físicamente en el Rack Editor
    Map<String, dynamic> primaryAsset = involved.firstWhere(
      (a) => a['sync_source'] == 'rack_device' || a['sync_source'] == 'floor_device',
      orElse: () => involved.first,
    );
    Map<String, dynamic> secondaryAsset = involved.firstWhere(
      (a) => a['id'] != primaryAsset['id'],
      orElse: () => involved[1],
    );

    String action = 'merge'; // 'merge' | 'reassign_or_clear' | 'delete_other'
    int keepId = primaryAsset['id'] as int;
    int otherId = secondaryAsset['id'] as int;

    final String bestName = !(primaryAsset['name'] ?? '')
            .toString()
            .startsWith('Equipo Detectado')
        ? (primaryAsset['name'] ?? '').toString()
        : (secondaryAsset['name'] ?? primaryAsset['name'] ?? '').toString();
    final String bestHost = !(primaryAsset['hostname'] ?? '')
            .toString()
            .startsWith('host-')
        ? (primaryAsset['hostname'] ?? '').toString()
        : (secondaryAsset['hostname'] ?? primaryAsset['hostname'] ?? '')
            .toString();
    final String bestFqdn = (primaryAsset['fqdn'] ?? '').toString().isNotEmpty
        ? (primaryAsset['fqdn'] ?? '').toString()
        : (secondaryAsset['fqdn'] ?? '').toString();

    final nameCtrl = TextEditingController(text: bestName);
    final hostCtrl = TextEditingController(text: bestHost);
    final fqdnCtrl = TextEditingController(text: bestFqdn);
    final newIpCtrl = TextEditingController();
    bool saving = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          final keepObj = involved.firstWhere(
            (a) => a['id'] == keepId,
            orElse: () => primaryAsset,
          );
          final otherObj = involved.firstWhere(
            (a) => a['id'] == otherId,
            orElse: () => secondaryAsset,
          );
          return AlertDialog(
            title: Row(
              children: [
                const Icon(
                  Icons.merge_type_rounded,
                  color: AppPalette.red700,
                  size: 22,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Resolver Colisión de IP $ipAddr (Alinear Rack Editor y CMDB)',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 660,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppPalette.amber50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppPalette.amber300),
                      ),
                      child: Text(
                        'La dirección IP $ipAddr figura simultáneamente en dos registros. Selecciona cómo deseas solucionarlo:',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppPalette.amber800,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    ...involved.map((a) {
                      final bool isRack = a['sync_source'] == 'rack_device';
                      return Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: isRack
                              ? AppPalette.blue50
                              : AppPalette.slate50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isRack
                                ? const Color(0xFF60A5FA)
                                : AppPalette.slate300,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              isRack
                                  ? Icons.developer_board_rounded
                                  : Icons.radar_rounded,
                              size: 18,
                              color: isRack
                                  ? AppPalette.blue700
                                  : AppPalette.slate600,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '[${a['code']}] ${a['name']}',
                                    style: const TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  Text(
                                    'Origen: ${isRack ? 'Montado en Rack (${a['physical_location_label']})' : 'Descubierto/Creado en CMDB'} • Hostname/FQDN: ${(a['fqdn'] ?? '').toString().isNotEmpty ? a['fqdn'] : (a['hostname'] ?? '-')} • Estado: ${(a['status'] ?? '').toString().toUpperCase()}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: AppPalette.slate600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                    const Divider(height: 18),
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        action == 'merge'
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        color: AppPalette.blue600,
                      ),
                      title: const Text(
                        '1. Es el mismo dispositivo físico: Unificar y alinear en un único equipo (Recomendado)',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w900,
                          color: AppPalette.slate900,
                        ),
                      ),
                      subtitle: const Text(
                        'Conserva la ubicación del Rack Editor y fusiona el estado Online, latencia, MAC, FQDN e IPs secundarias de la CMDB eliminando la fila duplicada.',
                        style: TextStyle(fontSize: 11),
                      ),
                      onTap: () => setModalState(() => action = 'merge'),
                    ),
                    if (action == 'merge') ...[
                      Padding(
                        padding: const EdgeInsets.only(left: 28, top: 6, bottom: 8),
                        child: Column(
                          children: [
                            TextField(
                              controller: nameCtrl,
                              decoration: const InputDecoration(
                                labelText: 'Nombre definitivo del dispositivo unificado',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: hostCtrl,
                                    decoration: const InputDecoration(
                                      labelText: 'Hostname definitivo',
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: TextField(
                                    controller: fqdnCtrl,
                                    decoration: const InputDecoration(
                                      labelText: 'FQDN / DNS definitivo',
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        action == 'reassign_or_clear'
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        color: AppPalette.blue600,
                      ),
                      title: const Text(
                        '2. Son equipos distintos: Cambiar o liberar la IP de uno de ellos',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      subtitle: Text(
                        'Mantiene $ipAddr en [${keepObj['code']}] y asigna otra IP (o deja sin IP) a [${otherObj['code']}].',
                        style: const TextStyle(fontSize: 11),
                      ),
                      onTap: () => setModalState(() => action = 'reassign_or_clear'),
                    ),
                    if (action == 'reassign_or_clear') ...[
                      Padding(
                        padding: const EdgeInsets.only(left: 28, top: 6, bottom: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: DropdownButtonFormField<int>(
                                    initialValue: keepId,
                                    decoration: const InputDecoration(
                                      labelText: 'Equipo que conserva la IP actual',
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                    ),
                                    items: involved.map((a) {
                                      return DropdownMenuItem<int>(
                                        value: a['id'] as int,
                                        child: Text('[${a['code']}] ${a['name']}'),
                                      );
                                    }).toList(),
                                    onChanged: (v) {
                                      if (v != null) {
                                        setModalState(() {
                                          keepId = v;
                                          otherId = involved
                                              .firstWhere((a) => a['id'] != v)['id']
                                              as int;
                                        });
                                      }
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            TextField(
                              controller: newIpCtrl,
                              decoration: InputDecoration(
                                labelText:
                                    'Nueva IP para [${otherObj['code']}] (dejar vacío para liberar su IP)',
                                border: const OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        action == 'delete_other'
                            ? Icons.radio_button_checked
                            : Icons.radio_button_off,
                        color: AppPalette.red700,
                      ),
                      title: Text(
                        '3. Eliminar directamente el registro duplicado [${otherObj['code']}]',
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                          color: AppPalette.red700,
                        ),
                      ),
                      onTap: () => setModalState(() => action = 'delete_other'),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancelar'),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppPalette.green700,
                ),
                onPressed: saving
                    ? null
                    : () async {
                        setModalState(() => saving = true);
                        try {
                          final updated =
                              await widget.api.resolveCmdbIpCollision({
                            'ip_address': ipAddr,
                            'action': action,
                            'keep_asset_id': keepId,
                            'other_asset_id': otherId,
                            'new_ip_for_other': newIpCtrl.text.trim(),
                            'preferred_name': nameCtrl.text.trim(),
                            'preferred_hostname': hostCtrl.text.trim(),
                            'preferred_fqdn': fqdnCtrl.text.trim(),
                          });
                          if (!ctx.mounted) return;
                          Navigator.pop(ctx);
                          if (!mounted) return;
                          _rebuildState(() => _overview = updated);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              backgroundColor: AppPalette.green700,
                              content: Text(
                                '✓ Colisión en IP $ipAddr resuelta y datos alineados entre Rack Editor y CMDB.',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          );
                        } catch (e) {
                          if (!ctx.mounted) return;
                          setModalState(() => saving = false);
                          ScaffoldMessenger.of(ctx).aviso('Error resolviendo colisión: $e');
                        }
                      },
                icon: const Icon(Icons.check_circle_outline, size: 16),
                label: const Text('Aplicar Solución Ahora'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildInventoryTab() {
    final items = _filteredAssets;
    final allVisibleSelected = items.isNotEmpty &&
        items.every((a) => _selectedInventoryAssetIds.contains(a['id'] as int));

    return Column(
      children: [
        _buildIpCollisionsAlertBanner(),
        // Barra superior de búsqueda universal, filtros y acciones en lote (estilo Excel)
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: AppPalette.slate300)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: SizedBox(
                      height: 36,
                      child: TextField(
                        controller: _searchCtrl,
                        onChanged: (_) => _rebuildState(() {}),
                        style: const TextStyle(fontSize: 12.5),
                        decoration: InputDecoration(
                          hintText:
                              'Buscar por cualquier dato (Código, Nombre, IP, Modelo, Nº Serie, Máscara 255.255..., Sede, Rack, Stack, MAC, VLAN, SO)...',
                          prefixIcon: const Icon(Icons.search, size: 18),
                          suffixIcon: _searchCtrl.text.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear, size: 16),
                                  onPressed: () {
                                    _searchCtrl.clear();
                                    _rebuildState(() {});
                                  },
                                )
                              : null,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(7),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilterChip(
                    selected: _onlyMultiIp,
                    visualDensity: VisualDensity.compact,
                    label: const Text(
                      'Multi-IP (>1 IP)',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    onSelected: (v) => _rebuildState(() => _onlyMultiIp = v),
                  ),
                  const SizedBox(width: 8),
                  // Selector de Sede / Location
                  DropdownButtonHideUnderline(
                    child: Container(
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        border: Border.all(color: AppPalette.slate300),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: DropdownButton<int?>(
                        value: _locationFilter,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppPalette.slate900,
                          fontWeight: FontWeight.w700,
                        ),
                        items: [
                          const DropdownMenuItem<int?>(
                            value: null,
                            child: Text('Sede (Location): Todas'),
                          ),
                          const DropdownMenuItem<int?>(
                            value: -1,
                            child: Text('Sin Sede Asignada'),
                          ),
                          ..._locations.map((loc) {
                            return DropdownMenuItem<int?>(
                              value: loc['id'] as int,
                              child: Text(
                                'Sede: ${loc['code']} (${loc['name']})',
                              ),
                            );
                          }),
                        ],
                        onChanged: (v) => _rebuildState(() => _locationFilter = v),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  DropdownButtonHideUnderline(
                    child: Container(
                      height: 36,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      decoration: BoxDecoration(
                        border: Border.all(color: AppPalette.slate300),
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: DropdownButton<String>(
                        value: _envFilter,
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: AppPalette.slate900,
                          fontWeight: FontWeight.w700,
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'all',
                            child: Text('Entorno: Todos'),
                          ),
                          DropdownMenuItem(
                            value: 'production',
                            child: Text('Producción (PROD)'),
                          ),
                          DropdownMenuItem(
                            value: 'preprod',
                            child: Text('Preproducción (PRE)'),
                          ),
                          DropdownMenuItem(
                            value: 'dev',
                            child: Text('Desarrollo (DEV)'),
                          ),
                          DropdownMenuItem(
                            value: 'mgmt',
                            child: Text('Gestión (MGMT)'),
                          ),
                          DropdownMenuItem(
                            value: 'dr',
                            child: Text('Contingencia (DR)'),
                          ),
                        ],
                        onChanged: (v) {
                          if (v != null) _rebuildState(() => _envFilter = v);
                        },
                      ),
                    ),
                  ),
                  if (widget.canEdit && _selectedInventoryAssetIds.isNotEmpty) ...[
                    const SizedBox(width: 10),
                    FilledButton.icon(
                      onPressed: _deleteSelectedInventoryAssets,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppPalette.red600,
                        visualDensity: VisualDensity.compact,
                      ),
                      icon: const Icon(Icons.delete_sweep_rounded, size: 16),
                      label: Text(
                        'Eliminar y Liberar IPs (${_selectedInventoryAssetIds.length})',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _buildClassFilterPill(
                            'all',
                            'Todos (${_assets.length})',
                          ),
                          _buildClassFilterPill(
                            'vms_only',
                            'Máquinas Virtuales (VMs)',
                          ),
                          _buildClassFilterPill(
                            'containers_clusters',
                            'Contenedores & Clusters VIP',
                          ),
                          _buildClassFilterPill(
                            'physical_server',
                            'Servidores Físicos (Rack)',
                          ),
                          _buildClassFilterPill(
                            'network_security',
                            'Switches, Routers & Firewalls',
                          ),
                          _buildClassFilterPill(
                            'storage_san_nas',
                            'Cabinas SAN / NAS',
                          ),
                          _buildClassFilterPill(
                            'floor_endpoint',
                            'Equipos de Planta',
                          ),
                          _buildClassFilterPill(
                            'other_machine',
                            'Otros Equipos Detectados',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Mostrando ${items.length} de ${_assets.length} filas • Clic en cualquier cabecera para ordenar ▲▼',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppPalette.slate600,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        // Cabecera fija estilo Hoja de Cálculo Excel
        Container(
          decoration: const BoxDecoration(
            color: AppPalette.slate200,
            border: Border(
              bottom: BorderSide(color: AppPalette.slate400, width: 1.5),
            ),
          ),
          child: Row(
            children: [
              if (widget.canEdit)
                Container(
                  width: 34,
                  alignment: Alignment.center,
                  decoration: const BoxDecoration(
                    border: Border(right: BorderSide(color: AppPalette.slate300)),
                  ),
                  child: Checkbox(
                    value: allVisibleSelected,
                    visualDensity: VisualDensity.compact,
                    onChanged: (v) {
                      _rebuildState(() {
                        if (v == true) {
                          for (final a in items) {
                            _selectedInventoryAssetIds.add(a['id'] as int);
                          }
                        } else {
                          _selectedInventoryAssetIds.clear();
                        }
                      });
                    },
                  ),
                ),
              _buildExcelSortableHeaderCell('#', null, width: 34),
              _buildExcelSortableHeaderCell(
                'Heartbeat / Ping',
                'status',
                width: 116,
              ),
              _buildExcelSortableHeaderCell('Código', 'code', width: 108),
              _buildExcelSortableHeaderCell(
                'IP Principal (Gestión)',
                'primary_ip',
                width: 142,
              ),
              _buildExcelSortableHeaderCell(
                'Máscara de Red',
                'subnet_mask',
                width: 118,
              ),
              _buildExcelSortableHeaderCell(
                'Sede / Location',
                'site_location',
                flex: 12,
              ),
              _buildExcelSortableHeaderCell(
                'Nombre del Equipo',
                'name',
                flex: 15,
              ),
              _buildExcelSortableHeaderCell(
                'Hostname / FQDN',
                'hostname',
                flex: 13,
              ),
              _buildExcelSortableHeaderCell(
                'MAC / VLAN / +IPs',
                'mac_vlan',
                flex: 12,
              ),
              _buildExcelSortableHeaderCell(
                'Clase / Tipo',
                'asset_class',
                flex: 11,
              ),
              _buildExcelSortableHeaderCell(
                'Posición Rack / Stack',
                'location',
                flex: 16,
              ),
              _buildExcelSortableHeaderCell(
                'SO / Firmware',
                'os_or_firmware',
                flex: 12,
              ),
              _buildExcelSortableHeaderCell(
                'Acciones',
                null,
                width: widget.canEdit ? 78 : 82,
              ),
            ],
          ),
        ),
        // Cuerpo de filas estilo Excel con líneas de cuadrícula
        Expanded(
          child: items.isEmpty
              ? const Center(
                  child: Text(
                    'No hay equipos o activos en la CMDB que coincidan con la búsqueda o filtro actual.',
                    style: TextStyle(color: AppPalette.slate500, fontSize: 13),
                  ),
                )
              : ListView.builder(
                  itemCount: items.length,
                  itemBuilder: (ctx, idx) =>
                      _buildExcelAssetRow(items[idx], idx),
                ),
        ),
      ],
    );
  }

  Widget _buildExcelSortableHeaderCell(
    String label,
    String? colKey, {
    double? width,
    int? flex,
  }) {
    final bool isSorted = colKey != null && _sortColumn == colKey;
    final Widget content = InkWell(
      onTap: colKey != null ? () => _onSortInventoryBy(colKey) : null,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 7),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: isSorted ? AppPalette.blue100 : Colors.transparent,
          border: const Border(right: BorderSide(color: AppPalette.slate300)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  color: isSorted
                      ? AppPalette.blue900
                      : AppPalette.slate800,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (colKey != null)
              Icon(
                isSorted
                    ? (_sortAscending
                        ? Icons.arrow_drop_up_rounded
                        : Icons.arrow_drop_down_rounded)
                    : Icons.unfold_more_rounded,
                size: isSorted ? 18 : 13,
                color: isSorted
                    ? AppPalette.blue900
                    : AppPalette.slate500,
              ),
          ],
        ),
      ),
    );
    if (width != null) {
      return SizedBox(width: width, child: content);
    }
    return Expanded(flex: flex ?? 10, child: content);
  }

  Widget _buildExcelBodyCell(
    Widget child, {
    double? width,
    int? flex,
    Alignment alignment = Alignment.centerLeft,
  }) {
    final cell = Container(
      constraints: const BoxConstraints(minHeight: 34),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
      alignment: alignment,
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: AppPalette.slate200)),
      ),
      child: child,
    );
    if (width != null) {
      return SizedBox(width: width, child: cell);
    }
    return Expanded(flex: flex ?? 10, child: cell);
  }

  Widget _buildInventoryActions(
    Map<String, dynamic> asset, {
    required bool heartbeatEnabled,
    required bool expanded,
  }) {
    final assetId = asset['id'] as int;
    final rawConfig = (asset['custom_fields'] is Map)
        ? (asset['custom_fields'] as Map)['certscope_config']
        : null;
    final certScopeEnabled = rawConfig is Map
        ? rawConfig['enabled'] == true
        : (asset['monitor_method'] ?? '').toString().toLowerCase() == 'https';

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Comprobar conexión ahora',
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
          onPressed: _runningHeartbeatAssetId == assetId
              ? null
              : () => _triggerAssetHeartbeat(asset),
          icon: _runningHeartbeatAssetId == assetId
              ? const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.network_ping_rounded, size: 16),
        ),
        if (widget.canEdit)
          PopupMenuButton<String>(
            tooltip: 'Más acciones',
            icon: const Icon(Icons.more_horiz_rounded, size: 19),
            padding: EdgeInsets.zero,
            onSelected: (action) {
              switch (action) {
                case 'heartbeat':
                  _toggleAssetHeartbeatMonitoring(asset);
                  break;
                case 'certscope':
                  _toggleInventoryCertScope(asset, !certScopeEnabled);
                  break;
                case 'provision_ansible':
                  final targetHost =
                      '${asset['heartbeat_ip'] ?? asset['primary_ip'] ?? asset['hostname'] ?? ''}'
                          .trim();
                  if (targetHost.isNotEmpty) {
                    ProvisioningWorkspaceView.showQuickProvisionDialog(
                      context,
                      api: widget.api,
                      initialTargets: [targetHost],
                      canEdit: widget.canEdit,
                      onCompleted: _loadOverview,
                    );
                  }
                  break;
                case 'add_ip':
                  _openAddSingleIpDialog(asset);
                  break;
                case 'edit':
                  _openAssetEditorDialog(existing: asset);
                  break;
                case 'delete':
                  _confirmDeleteAsset(asset);
                  break;
                case 'details':
                  _rebuildState(() => _expandedAssetId = expanded ? null : assetId);
                  break;
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'heartbeat',
                child: Text(heartbeatEnabled
                    ? 'Desactivar monitorización'
                    : 'Activar monitorización'),
              ),
              PopupMenuItem(
                value: 'certscope',
                child: Text(certScopeEnabled
                    ? 'Desactivar análisis TLS'
                    : 'Analizar certificado TLS'),
              ),
              const PopupMenuItem(
                value: 'provision_ansible',
                child: Text('Verificar Exporter / Desplegar Ansible & OTel'),
              ),
              const PopupMenuItem(
                value: 'add_ip',
                child: Text('Añadir dirección IP'),
              ),
              const PopupMenuItem(value: 'edit', child: Text('Editar activo')),
              PopupMenuItem(
                value: 'details',
                child: Text(expanded ? 'Ocultar detalles' : 'Ver detalles e IPs'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(value: 'delete', child: Text('Eliminar activo')),
            ],
          )
        else
          IconButton(
            tooltip: expanded ? 'Ocultar detalles' : 'Ver detalles e IPs',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            onPressed: () => _rebuildState(
              () => _expandedAssetId = expanded ? null : assetId,
            ),
            icon: Icon(expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded),
          ),
      ],
    );
  }

  Future<void> _toggleInventoryCertScope(
    Map<String, dynamic> asset,
    bool enabled,
  ) async {
    final assetId = asset['id'] as int;
    try {
      await widget.api.updateCmdbAsset(assetId, {
        'certscope_enabled': enabled,
        'certscope_port': 443,
      });
      await _loadOverview(silent: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).aviso(
        enabled
            ? 'Análisis HTTPS activado para ${asset['code']}.'
            : 'Análisis HTTPS desactivado para ${asset['code']}.',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).avisoError('$e');
    }
  }

  Widget _buildExcelAssetRow(Map<String, dynamic> asset, int rowIndex) {
    final int assetId = asset['id'] as int;
    final String code = (asset['code'] ?? '').toString();
    final String name = (asset['name'] ?? '').toString();
    final String hostname = (asset['hostname'] ?? '').toString();
    final String fqdn = (asset['fqdn'] ?? '').toString();
    final String assetClass = (asset['asset_class'] ?? '').toString();
    final String classLabel =
        (asset['asset_class_label'] ?? _CmdbViewState._assetClassLabels[assetClass] ?? assetClass)
            .toString();
    final String status = (asset['status'] ?? 'unmonitored').toString();
    final bool hbEnabled = asset['monitoring_enabled'] ?? true;
    final double? pingMs = (asset['last_ping_ms'] as num?)?.toDouble();
    final List<Map<String, dynamic>> ips = ((asset['ip_addresses'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final String primaryIp = _primaryIpOfAsset(asset);
    final String primaryMask = _primaryMaskOfAsset(asset);
    final String primaryMac = _primaryMacOfAsset(asset);
    final String primaryVlan = _primaryVlanOfAsset(asset);
    final int extraIpsCount = ips.length > 1 ? ips.length - 1 : 0;
    final bool hasIpCollision = asset['has_ip_collision'] == true;

    final String os = (asset['os_or_firmware'] ?? '-').toString();
    final String siteLocLabel = (asset['location_label'] ?? '').toString();
    final String locLabel =
        (asset['physical_location_label'] ?? asset['hypervisor_or_platform'] ?? '-')
            .toString();
    final int? rackId = asset['rack_id'] as int?;
    final int? rackDevId =
        (asset['rack_device_id'] as int?) ?? (asset['host_rack_device_id'] as int?);
    final int? floorId = asset['floor_id'] as int?;
    final int? floorDeviceId = asset['floor_device_id'] as int?;
    final int? assetLocId = asset['location_id'] as int?;
    final int? stackDiagramId = asset['primary_stack_diagram_id'] as int?;
    final int? stackNodeId = asset['primary_stack_node_id'] as int?;
    final String stackLabel = (asset['primary_stack_label'] ?? '').toString();

    final bool isExpanded = _expandedAssetId == assetId;
    final bool isHighlighted = _highlightedAssetId == assetId;
    final bool isSelected = _selectedInventoryAssetIds.contains(assetId);
    final Color badgeColor = _classBadgeColor(assetClass);

    Color statusColor = AppPalette.slate500;
    String statusText = hbEnabled ? 'PEND.' : 'HB OFF';
    if (!hbEnabled) {
      statusColor = AppPalette.slate500;
      statusText = 'HB OFF';
    } else if (status == 'online') {
      statusColor = AppPalette.green600;
      statusText =
          'ONLINE${pingMs != null ? ' ${pingMs.toStringAsFixed(0)}ms' : ''}';
    } else if (status == 'offline') {
      statusColor = AppPalette.red600;
      statusText = 'OFFLINE';
    } else if (status == 'warning') {
      statusColor = AppPalette.amber600;
      statusText = 'WARN';
    }

    final Color rowBg = hasIpCollision
        ? AppPalette.red50
        : isHighlighted
            ? const Color(0xFFFEF9C3)
            : isSelected
                ? AppPalette.sky100
                : isExpanded
                    ? AppPalette.sky50
                    : (rowIndex.isEven ? Colors.white : AppPalette.slate50);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: () {
            _rebuildState(() {
              _highlightedAssetId = assetId;
              _expandedAssetId = isExpanded ? null : assetId;
            });
          },
          child: Container(
            decoration: BoxDecoration(
              color: rowBg,
              border: Border(
                bottom: BorderSide(
                  color: hasIpCollision
                      ? const Color(0xFFF87171)
                      : isHighlighted
                          ? const Color(0xFFEAB308)
                          : AppPalette.slate300,
                  width: (hasIpCollision || isHighlighted) ? 1.5 : 0.8,
                ),
              ),
            ),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.canEdit)
                    Container(
                      width: 34,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        border: Border(
                          right: BorderSide(color: AppPalette.slate200),
                        ),
                      ),
                      child: Checkbox(
                        value: isSelected,
                        visualDensity: VisualDensity.compact,
                        onChanged: (v) {
                          _rebuildState(() {
                            if (v == true) {
                              _selectedInventoryAssetIds.add(assetId);
                            } else {
                              _selectedInventoryAssetIds.remove(assetId);
                            }
                          });
                        },
                      ),
                    ),
                  _buildExcelBodyCell(
                    Text(
                      '${rowIndex + 1}',
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontFamily: 'monospace',
                        color: AppPalette.slate500,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    width: 34,
                    alignment: Alignment.center,
                  ),
                  _buildExcelBodyCell(
                    InkWell(
                      onTap: widget.canEdit
                          ? () => _toggleAssetHeartbeatMonitoring(asset)
                          : null,
                      child: Tooltip(
                        message: widget.canEdit
                            ? (hbEnabled
                                ? 'Heartbeat ACTIVO (${asset['monitor_method'] ?? 'icmp'}). Clic para desactivar Heartbeat'
                                : 'Heartbeat DESACTIVADO. Clic para activar Heartbeat')
                            : statusText,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: statusColor.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: statusColor.withValues(alpha: 0.35),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                hbEnabled
                                    ? Icons.monitor_heart_rounded
                                    : Icons.heart_broken_outlined,
                                size: 11,
                                color: statusColor,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  statusText,
                                  style: TextStyle(
                                    fontSize: 9.8,
                                    fontWeight: FontWeight.w900,
                                    color: statusColor,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    width: 116,
                  ),
                  _buildExcelBodyCell(
                    SelectableText(
                      code,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        fontFamily: 'monospace',
                        color: AppPalette.slate900,
                      ),
                    ),
                    width: 108,
                  ),
                  _buildExcelBodyCell(
                    primaryIp.isEmpty
                        ? const Text(
                            'Sin IP',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppPalette.slate400,
                            ),
                          )
                        : Row(
                            children: [
                              Expanded(
                                child: InkWell(
                                  onTap: () => _jumpToIpInIpamMap(primaryIp),
                                  child: Row(
                                    children: [
                                      Icon(
                                        hasIpCollision
                                            ? Icons.warning_amber_rounded
                                            : Icons.lan_outlined,
                                        size: 13,
                                        color: hasIpCollision
                                            ? AppPalette.red700
                                            : AppPalette.sky600,
                                      ),
                                      const SizedBox(width: 4),
                                      Expanded(
                                        child: Text(
                                          primaryIp,
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.w900,
                                            fontFamily: 'monospace',
                                            color: hasIpCollision
                                                ? AppPalette.red700
                                                : AppPalette.sky700,
                                            decoration:
                                                TextDecoration.underline,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              if (hasIpCollision && widget.canEdit)
                                Tooltip(
                                  message:
                                      'Colisión de IP detectada. Pulsa para unificar o resolver.',
                                  child: InkWell(
                                    onTap: () {
                                      final col = _ipCollisions.firstWhere(
                                        (c) => c['ip_address'] == primaryIp,
                                        orElse: () => _ipCollisions.first,
                                      );
                                      _openResolveCollisionDialog(col);
                                    },
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                        vertical: 1,
                                      ),
                                      decoration: BoxDecoration(
                                        color: AppPalette.red700,
                                        borderRadius: BorderRadius.circular(3),
                                      ),
                                      child: const Text(
                                        'UNIFICAR',
                                        style: TextStyle(
                                          fontSize: 8.5,
                                          fontWeight: FontWeight.w900,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                    width: 142,
                  ),
                  _buildExcelBodyCell(
                    Text(
                      primaryMask.isEmpty ? '-' : primaryMask,
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w700,
                        color: AppPalette.slate700,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    width: 118,
                  ),
                  _buildExcelBodyCell(
                    siteLocLabel.isEmpty
                        ? const Text(
                            'Sin Sede',
                            style: TextStyle(
                              fontSize: 10.5,
                              color: AppPalette.slate400,
                            ),
                          )
                        : Row(
                            children: [
                              const Icon(
                                Icons.location_on_outlined,
                                size: 13,
                                color: AppPalette.teal700,
                              ),
                              const SizedBox(width: 3),
                              Expanded(
                                child: Text(
                                  siteLocLabel,
                                  style: const TextStyle(
                                    fontSize: 10.8,
                                    fontWeight: FontWeight.w800,
                                    color: AppPalette.teal700,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                    flex: 12,
                  ),
                  _buildExcelBodyCell(
                    Text(
                      name,
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: AppPalette.slate800,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    flex: 15,
                  ),
                  _buildExcelBodyCell(
                    Text(
                      fqdn.isNotEmpty
                          ? fqdn
                          : (hostname.isNotEmpty ? hostname : '-'),
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: AppPalette.slate700,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    flex: 13,
                  ),
                  _buildExcelBodyCell(
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            [
                              if (primaryMac.isNotEmpty) primaryMac,
                              if (primaryVlan.isNotEmpty) primaryVlan,
                            ].join(' • ').isEmpty
                                ? '-'
                                : [
                                    if (primaryMac.isNotEmpty) primaryMac,
                                    if (primaryVlan.isNotEmpty) primaryVlan,
                                  ].join(' • '),
                            style: const TextStyle(
                              fontSize: 10.5,
                              fontFamily: 'monospace',
                              color: AppPalette.slate600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (extraIpsCount > 0)
                          Container(
                            margin: const EdgeInsets.only(left: 4),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: AppPalette.blue100,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '+$extraIpsCount IP',
                              style: const TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w900,
                                color: AppPalette.blue900,
                              ),
                            ),
                          ),
                      ],
                    ),
                    flex: 12,
                  ),
                  _buildExcelBodyCell(
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        classLabel,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: badgeColor,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    flex: 11,
                  ),
                  // Columna con enlaces directos a Posición de Rack (si tiene) y Posición de Stack Tecnológico (si tiene)
                  _buildExcelBodyCell(
                    Wrap(
                      spacing: 4,
                      runSpacing: 3,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (rackId != null &&
                            widget.onNavigateToRackDevice != null)
                          InkWell(
                            borderRadius: BorderRadius.circular(4),
                            onTap: () => widget.onNavigateToRackDevice!(
                              rackId,
                              rackDevId,
                            ),
                            child: Tooltip(
                              message:
                                  'Ir a la posición en el Rack Editor ($locLabel)',
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: AppPalette.sky100,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: const Color(0xFF7DD3FC),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.developer_board_rounded,
                                      size: 12,
                                      color: AppPalette.sky700,
                                    ),
                                    const SizedBox(width: 3),
                                    Flexible(
                                      child: Text(
                                        locLabel,
                                        style: const TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w900,
                                          color: AppPalette.sky700,
                                          decoration: TextDecoration.underline,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          )
                        else if (floorDeviceId != null &&
                            floorId != null &&
                            widget.onNavigateToFloorDevice != null)
                          InkWell(
                            borderRadius: BorderRadius.circular(4),
                            onTap: () => widget.onNavigateToFloorDevice!(
                              assetLocId,
                              floorId,
                              floorDeviceId,
                            ),
                            child: Tooltip(
                              message:
                                  'Ir a la posición en Datacenter / Planta ($locLabel)',
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFDCFCE7),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: const Color(0xFF86EFAC),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.location_on_rounded,
                                      size: 12,
                                      color: Color(0xFF15803D),
                                    ),
                                    const SizedBox(width: 3),
                                    Flexible(
                                      child: Text(
                                        locLabel,
                                        style: const TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w900,
                                          color: Color(0xFF15803D),
                                          decoration: TextDecoration.underline,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          )
                        else if (stackDiagramId == null)
                          Text(
                            locLabel,
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: AppPalette.slate500,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (stackDiagramId != null &&
                            widget.onNavigateToStackNode != null)
                          InkWell(
                            borderRadius: BorderRadius.circular(4),
                            onTap: () => widget.onNavigateToStackNode!(
                              stackDiagramId,
                              stackNodeId,
                            ),
                            child: Tooltip(
                              message:
                                  'Ir a la posición en el Stack Tecnológico ($stackLabel)',
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF3E8FF),
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(
                                    color: const Color(0xFFD8B4FE),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.layers_rounded,
                                      size: 12,
                                      color: Color(0xFF7E22CE),
                                    ),
                                    const SizedBox(width: 3),
                                    Flexible(
                                      child: Text(
                                        'Stack: $stackLabel',
                                        style: const TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w900,
                                          color: Color(0xFF7E22CE),
                                          decoration: TextDecoration.underline,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    flex: 16,
                  ),
                  _buildExcelBodyCell(
                    Text(
                      os,
                      style: const TextStyle(
                        fontSize: 10.8,
                        color: AppPalette.slate700,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    flex: 12,
                  ),
                  _buildExcelBodyCell(
                    _buildInventoryActions(
                      asset,
                      heartbeatEnabled: hbEnabled,
                      expanded: isExpanded,
                    ),
                    width: widget.canEdit ? 78 : 82,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (isExpanded)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: const BoxDecoration(
              color: AppPalette.slate50,
              border: Border(
                bottom: BorderSide(color: AppPalette.slate400, width: 1.2),
              ),
            ),
            child: _buildExpandedIpTableForAsset(asset, ips),
          ),
      ],
    );
  }

  Widget _buildClassFilterPill(String key, String label) {
    final active = _classFilter == key;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        selected: active,
        label: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: active ? FontWeight.w800 : FontWeight.w600,
            color: active ? Colors.white : AppPalette.slate700,
          ),
        ),
        selectedColor: AppPalette.blue900,
        backgroundColor: AppPalette.slate100,
        onSelected: (_) => _rebuildState(() => _classFilter = key),
      ),
    );
  }

  Color _classBadgeColor(String assetClass) {
    switch (assetClass) {
      case 'virtual_machine':
      case 'virtual_appliance':
        return AppPalette.violet600;
      case 'container_lxc':
        return AppPalette.sky600;
      case 'cluster_vip':
        return AppPalette.amber600;
      case 'cloud_instance':
        return AppPalette.indigo600;
      case 'physical_server':
        return AppPalette.teal700;
      case 'network_security':
        return AppPalette.blue900;
      case 'storage_san_nas':
        return const Color(0xFF9333EA);
      default:
        return AppPalette.slate600;
    }
  }

  Color _ipRoleColor(String role) {
    switch (role) {
      case 'mgmt_heartbeat':
        return AppPalette.sky600;
      case 'ilo_idrac':
        return AppPalette.violet600;
      case 'primary_service':
        return AppPalette.green700;
      case 'secondary_service':
        return AppPalette.teal600;
      case 'vip_cluster':
        return AppPalette.amber600;
      case 'storage':
      case 'backup':
      case 'vmotion_replication':
        return AppPalette.indigo600;
      case 'public_wan':
        return const Color(0xFFBE123C);
      default:
        return AppPalette.slate600;
    }
  }

  Widget _buildAssetCard(Map<String, dynamic> asset) {
    final int assetId = asset['id'] as int;
    final String code = (asset['code'] ?? '').toString();
    final String name = (asset['name'] ?? '').toString();
    final String hostname = (asset['hostname'] ?? '').toString();
    final String fqdn = (asset['fqdn'] ?? '').toString();
    final String assetClass = (asset['asset_class'] ?? '').toString();
    final String classLabel =
        (asset['asset_class_label'] ?? _CmdbViewState._assetClassLabels[assetClass] ?? assetClass)
            .toString();
    final String syncSource = (asset['sync_source'] ?? 'cmdb').toString();
    final String status = (asset['status'] ?? 'unmonitored').toString();
    final double? pingMs = (asset['last_ping_ms'] as num?)?.toDouble();
    final List<Map<String, dynamic>> ips = ((asset['ip_addresses'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final bool isExpanded = _expandedAssetId == assetId;
    final Color badgeColor = _classBadgeColor(assetClass);

    final int cores = (asset['cpu_cores'] as int?) ?? 0;
    final double ramGb = (asset['ram_gb'] as num?)?.toDouble() ?? 0.0;
    final double storageGb = (asset['storage_gb'] as num?)?.toDouble() ?? 0.0;
    final String os = (asset['os_or_firmware'] ?? '').toString();
    final String locLabel = (asset['physical_location_label'] ?? '').toString();
    final int? rackId = asset['rack_id'] as int?;
    final int? rackDevId =
        (asset['rack_device_id'] as int?) ?? (asset['host_rack_device_id'] as int?);

    Color statusColor = AppPalette.slate500;
    String statusText = 'SIN MONITORIZAR';
    if (status == 'online') {
      statusColor = AppPalette.green600;
      statusText =
          'ONLINE${pingMs != null ? ' (${pingMs.toStringAsFixed(1)} ms)' : ''}';
    } else if (status == 'offline') {
      statusColor = AppPalette.red600;
      statusText = 'CAÍDO / OFFLINE';
    } else if (status == 'warning') {
      statusColor = AppPalette.amber600;
      statusText = 'WARNING';
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: isExpanded
              ? AppPalette.sky400
              : AppPalette.slate200,
          width: isExpanded ? 1.6 : 1.0,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Cabecera del activo
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Badge Clase (VM, Servidor Físico, Cluster, Contenedor, Cloud)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: badgeColor.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Text(
                    classLabel.toUpperCase(),
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      color: badgeColor,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: syncSource == 'cmdb'
                        ? const Color(0xFFF3E8FF)
                        : AppPalette.sky100,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    syncSource == 'cmdb'
                        ? 'NATIVO CMDB (Virtual / Lógico / Cloud)'
                        : syncSource == 'rack_device'
                            ? 'SINCRONIZADO RACK 42U'
                            : 'SINCRONIZADO PLANTA',
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                      color: syncSource == 'cmdb'
                          ? const Color(0xFF6B21A8)
                          : AppPalette.sky700,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            code,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w900,
                              color: AppPalette.slate900,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              name,
                              style: const TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                                color: AppPalette.slate800,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        children: [
                          if (hostname.isNotEmpty)
                            Text(
                              'Hostname: $hostname',
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: AppPalette.slate600,
                              ),
                            ),
                          if (fqdn.isNotEmpty)
                            Text(
                              'FQDN: $fqdn',
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: AppPalette.sky700,
                              ),
                            ),
                          if (os.isNotEmpty)
                            Text(
                              'SO/FW: $os',
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: AppPalette.slate600,
                              ),
                            ),
                          if ((asset['model_name'] ?? '').toString().trim().isNotEmpty)
                            Text(
                              'Modelo: ${asset['model_name']}',
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: AppPalette.blue900,
                              ),
                            ),
                          if ((asset['serial_or_uuid'] ?? '').toString().trim().isNotEmpty)
                            Text(
                              'S/N: ${asset['serial_or_uuid']}',
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                fontFamily: 'monospace',
                                color: AppPalette.teal700,
                              ),
                            ),
                          if (cores > 0 || ramGb > 0)
                            Text(
                              'Recursos: ${cores}vCPU • ${ramGb.toStringAsFixed(0)}GB RAM${storageGb > 0 ? ' • ${storageGb.toStringAsFixed(0)}GB Disco' : ''}',
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: AppPalette.slate700,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                // Indicador de estado Heartbeat y botón de chequeo rápido
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: statusColor.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: statusColor,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        statusText,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w900,
                          color: statusColor,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: 'Comprobar Heartbeat en su IP de Gestión ahora',
                  onPressed: _runningHeartbeatAssetId == assetId
                      ? null
                      : () => _triggerAssetHeartbeat(asset),
                  icon: _runningHeartbeatAssetId == assetId
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(
                          Icons.network_ping_rounded,
                          size: 18,
                          color: AppPalette.sky600,
                        ),
                ),
                if (rackId != null && widget.onNavigateToRackDevice != null)
                  TextButton.icon(
                    onPressed: () =>
                        widget.onNavigateToRackDevice!(rackId, rackDevId),
                    icon: const Icon(Icons.developer_board_rounded, size: 15),
                    label: Text(
                      locLabel,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: Text(
                      locLabel,
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: AppPalette.slate500,
                      ),
                    ),
                  ),
                if (widget.canEdit) ...[
                  IconButton(
                    tooltip:
                        'Verificar Exporter de serie / Desplegar con Ansible u OpenTelemetry',
                    onPressed: () {
                      final targetHost =
                          '${asset['heartbeat_ip'] ?? asset['primary_ip'] ?? asset['hostname'] ?? ''}'
                              .trim();
                      ProvisioningWorkspaceView.showQuickProvisionDialog(
                        context,
                        api: widget.api,
                        initialTargets: targetHost.isEmpty ? [] : [targetHost],
                        canEdit: widget.canEdit,
                        onCompleted: _loadOverview,
                      );
                    },
                    icon: const Icon(
                      Icons.rocket_launch_outlined,
                      size: 18,
                      color: AppPalette.indigo600,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Añadir otra IP a esta máquina',
                    onPressed: () => _openAddSingleIpDialog(asset),
                    icon: const Icon(
                      Icons.add_link_rounded,
                      size: 19,
                      color: AppPalette.green700,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Editar máquina y sus múltiples IPs',
                    onPressed: () => _openAssetEditorDialog(existing: asset),
                    icon: const Icon(
                      Icons.edit_outlined,
                      size: 18,
                      color: AppPalette.blue900,
                    ),
                  ),
                  if (syncSource == 'cmdb')
                    IconButton(
                      tooltip: 'Eliminar máquina de la CMDB',
                      onPressed: () => _confirmDeleteAsset(asset),
                      icon: const Icon(
                        Icons.delete_outline_rounded,
                        size: 18,
                        color: AppPalette.red600,
                      ),
                    ),
                ],
                IconButton(
                  tooltip: isExpanded ? 'Contraer detalle' : 'Ver detalle de IPs',
                  onPressed: () => _rebuildState(
                    () => _expandedAssetId = isExpanded ? null : assetId,
                  ),
                  icon: Icon(
                    isExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // Tira visual con todas las IPs de la máquina (diferenciando Gestión/Heartbeat de Servicio/VIP/Backup/iDRAC)
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                ...ips.map((ip) => _buildIpBadgePill(asset, ip)),
                if (widget.canEdit)
                  ActionChip(
                    avatar: const Icon(
                      Icons.add_rounded,
                      size: 15,
                      color: AppPalette.blue900,
                    ),
                    label: const Text(
                      'Añadir IP (Servicio / VIP / Backup)',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: AppPalette.blue900,
                      ),
                    ),
                    backgroundColor: AppPalette.blue50,
                    side: const BorderSide(color: Color(0xFFBFDBFE)),
                    onPressed: () => _openAddSingleIpDialog(asset),
                  ),
              ],
            ),
            if (isExpanded) ...[
              const Divider(height: 20),
              _buildExpandedIpTableForAsset(asset, ips),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildIpBadgePill(
    Map<String, dynamic> asset,
    Map<String, dynamic> ip,
  ) {
    final String addr = (ip['ip_address'] ?? '').toString();
    final String role = (ip['ip_role'] ?? 'primary_service').toString();
    final String iface = (ip['interface_name'] ?? 'eth0').toString();
    final bool isHb = ip['is_heartbeat_ip'] == true;
    final int? vlan = ip['vlan_id'] as int?;
    final String ipFqdn = (ip['fqdn'] ?? '').toString();
    final Color c = _ipRoleColor(role);

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () {
        _verifyIpCtrl.text = addr;
        _rebuildState(() => _activeTab = 'verifier');
        _runManualVerification(customIp: addr);
      },
      child: Tooltip(
        message:
            'Clic para verificar IP $addr con Ping + TCP + ARP + DNS\nInterfaz: $iface${ipFqdn.isNotEmpty ? ' • DNS: $ipFqdn' : ''}',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: c.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isHb ? c : c.withValues(alpha: 0.35),
              width: isHb ? 1.5 : 1.0,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isHb ? Icons.monitor_heart_rounded : Icons.lan_outlined,
                size: 14,
                color: c,
              ),
              const SizedBox(width: 6),
              Text(
                addr,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w900,
                  color: c,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: c.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  isHb
                      ? 'HEARTBEAT / MGMT'
                      : (_CmdbViewState._ipRoleLabels[role] ?? role).toUpperCase(),
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                    color: c,
                  ),
                ),
              ),
              if (vlan != null) ...[
                const SizedBox(width: 5),
                Text(
                  'VLAN $vlan',
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: AppPalette.slate600,
                  ),
                ),
              ],
              const SizedBox(width: 5),
              Text(
                '($iface)',
                style: const TextStyle(
                  fontSize: 10,
                  color: AppPalette.slate500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExpandedIpTableForAsset(
    Map<String, dynamic> asset,
    List<Map<String, dynamic>> ips,
  ) {
    final int? rackId = asset['rack_id'] as int?;
    final int? rackDevId =
        (asset['rack_device_id'] as int?) ?? (asset['host_rack_device_id'] as int?);
    final int? floorId = asset['floor_id'] as int?;
    final int? floorDeviceId = asset['floor_device_id'] as int?;
    final int? assetLocId = asset['location_id'] as int?;
    final int? stackDiagramId = asset['primary_stack_diagram_id'] as int?;
    final int? stackNodeId = asset['primary_stack_node_id'] as int?;
    final String stackLabel = (asset['primary_stack_label'] ?? '').toString();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Icon(
              Icons.settings_ethernet_rounded,
              size: 16,
              color: AppPalette.blue900,
            ),
            Text(
              'Desglose de Interfaces de Red e IPs de ${asset['code']} (${ips.length} IPs configuradas)',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: AppPalette.slate900,
              ),
            ),
            if ((asset['location_label'] ?? '').toString().isNotEmpty)
              Chip(
                visualDensity: VisualDensity.compact,
                avatar: const Icon(
                  Icons.location_on_rounded,
                  size: 14,
                  color: AppPalette.teal700,
                ),
                label: Text(
                  'Sede: ${asset['location_label']}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: AppPalette.teal700,
                  ),
                ),
              ),
            if (rackId != null && widget.onNavigateToRackDevice != null)
              ActionChip(
                visualDensity: VisualDensity.compact,
                avatar: const Icon(
                  Icons.developer_board_rounded,
                  size: 14,
                  color: AppPalette.sky700,
                ),
                label: Text(
                  'Ir al Rack: ${asset['physical_location_label']}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: AppPalette.sky700,
                  ),
                ),
                onPressed: () =>
                    widget.onNavigateToRackDevice!(rackId, rackDevId),
              ),
            if (floorDeviceId != null &&
                floorId != null &&
                widget.onNavigateToFloorDevice != null)
              ActionChip(
                visualDensity: VisualDensity.compact,
                avatar: const Icon(
                  Icons.location_on_rounded,
                  size: 14,
                  color: Color(0xFF15803D),
                ),
                label: Text(
                  'Ir a Planta: ${asset['physical_location_label']}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF15803D),
                  ),
                ),
                onPressed: () => widget.onNavigateToFloorDevice!(
                  assetLocId,
                  floorId,
                  floorDeviceId,
                ),
              ),
            if (stackDiagramId != null && widget.onNavigateToStackNode != null)
              ActionChip(
                visualDensity: VisualDensity.compact,
                avatar: const Icon(
                  Icons.layers_rounded,
                  size: 14,
                  color: Color(0xFF7E22CE),
                ),
                label: Text(
                  'Ir al Stack: $stackLabel',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF7E22CE),
                  ),
                ),
                onPressed: () =>
                    widget.onNavigateToStackNode!(stackDiagramId, stackNodeId),
              ),
            if ((asset['model_name'] ?? '').toString().trim().isNotEmpty)
              Chip(
                visualDensity: VisualDensity.compact,
                backgroundColor: AppPalette.blue50,
                side: const BorderSide(color: AppPalette.blue300),
                avatar: const Icon(
                  Icons.memory_rounded,
                  size: 14,
                  color: AppPalette.blue900,
                ),
                label: Text(
                  'Modelo: ${asset['model_name']}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: AppPalette.blue900,
                  ),
                ),
              ),
            if ((asset['serial_or_uuid'] ?? '').toString().trim().isNotEmpty)
              Chip(
                visualDensity: VisualDensity.compact,
                backgroundColor: const Color(0xFFF0FDFA),
                side: const BorderSide(color: AppPalette.teal600),
                avatar: const Icon(
                  Icons.qr_code_2_rounded,
                  size: 14,
                  color: AppPalette.teal700,
                ),
                label: Text(
                  'Nº Serie / S/N: ${asset['serial_or_uuid']}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    fontFamily: 'monospace',
                    color: AppPalette.teal700,
                  ),
                ),
              ),
            Text(
              'Propietario: ${asset['owner_team'] ?? '-'} • Resp: ${asset['responsible_person'] ?? '-'}',
              style: const TextStyle(fontSize: 11, color: AppPalette.slate500),
            ),
          ],
        ),
        if ((asset['notes'] ?? '').toString().isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            'Notas: ${asset['notes']}',
            style: const TextStyle(
              fontSize: 11.5,
              fontStyle: FontStyle.italic,
              color: AppPalette.slate600,
            ),
          ),
        ],
        const SizedBox(height: 8),
        Table(
          border: TableBorder.all(color: AppPalette.slate200),
          columnWidths: const {
            0: FlexColumnWidth(1.3),
            1: FlexColumnWidth(1.2),
            2: FlexColumnWidth(1.0),
            3: FlexColumnWidth(1.6),
            4: FlexColumnWidth(0.7),
            5: FlexColumnWidth(1.4),
            6: FlexColumnWidth(1.2),
            7: FlexColumnWidth(1.5),
            8: IntrinsicColumnWidth(),
          },
          children: [
            const TableRow(
              decoration: BoxDecoration(color: AppPalette.slate100),
              children: [
                _TableHeaderCell('Dirección IP'),
                _TableHeaderCell('Máscara de Red'),
                _TableHeaderCell('Interfaz'),
                _TableHeaderCell('Función / Rol de la IP'),
                _TableHeaderCell('VLAN'),
                _TableHeaderCell('FQDN / DNS Asociado'),
                _TableHeaderCell('MAC Address'),
                _TableHeaderCell('Notas / Última Verificación'),
                _TableHeaderCell('Acciones'),
              ],
            ),
            ...ips.map((ip) {
              final ipId = ip['id'] as int?;
              final addr = (ip['ip_address'] ?? '').toString();
              final mask = (ip['subnet_mask'] ?? '255.255.255.0').toString();
              final isHb = ip['is_heartbeat_ip'] == true;
              return TableRow(
                children: [
                  _TableBodyCell(
                    addr,
                    mono: true,
                    bold: true,
                  ),
                  _TableBodyCell(
                    mask,
                    mono: true,
                  ),
                  _TableBodyCell((ip['interface_name'] ?? '').toString()),
                  _TableBodyCell(
                    '${ip['ip_role_label'] ?? ip['ip_role']}${isHb ? ' ★ [HEARTBEAT]' : ''}',
                    bold: isHb,
                  ),
                  _TableBodyCell('${ip['vlan_id'] ?? '-'}'),
                  _TableBodyCell((ip['fqdn'] ?? '-').toString()),
                  _TableBodyCell(
                    (ip['mac_address'] ?? '-').toString(),
                    mono: true,
                  ),
                  _TableBodyCell(
                    (ip['notes'] ?? ip['last_verification_detail'] ?? '')
                        .toString(),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.canEdit)
                          IconButton(
                            tooltip:
                                'Editar IP, Máscara de Red, Rol y Heartbeat',
                            icon: const Icon(
                              Icons.edit_outlined,
                              size: 15,
                              color: AppPalette.blue900,
                            ),
                            onPressed: () =>
                                _openAssetEditorDialog(existing: asset),
                          ),
                        IconButton(
                          tooltip: 'Copiar IP $addr',
                          icon: const Icon(Icons.copy, size: 15),
                          onPressed: () {
                            Clipboard.setData(ClipboardData(text: addr));
                            ScaffoldMessenger.of(context).aviso('IP $addr copiada al portapapeles');
                          },
                        ),
                        IconButton(
                          tooltip: 'Sondear esta IP en el Verificador Manual',
                          icon: const Icon(
                            Icons.radar_rounded,
                            size: 16,
                            color: AppPalette.sky600,
                          ),
                          onPressed: () {
                            _verifyIpCtrl.text = addr;
                            _rebuildState(() => _activeTab = 'verifier');
                            _runManualVerification(customIp: addr);
                          },
                        ),
                        if (widget.canEdit && ipId != null)
                          IconButton(
                            tooltip:
                                'Liberar esta IP (dejar como NO OCUPADA en el mapa IPAM)',
                            icon: const Icon(
                              Icons.link_off_rounded,
                              size: 16,
                              color: Colors.redAccent,
                            ),
                            onPressed: () async {
                              await widget.api.deleteCmdbIp(ipId);
                              await _loadOverview(silent: true);
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  backgroundColor: AppPalette.green700,
                                  content: Text(
                                    'IP $addr liberada (marcada como No Ocupada en el mapa IPAM).',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                      ],
                    ),
                  ),
                ],
              );
            }),
          ],
        ),
      ],
    );
  }
}
