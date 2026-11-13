part of '../network_hosts_view.dart';

/// Pestaña 2 de `4. Red & Host`: mapa automático de topología lógica en 5 capas
/// e inspector lateral de enlaces y servicios por activo.
extension _NetworkHostsLogicalTopologyTabExt on _NetworkHostsViewState {
  // ===========================================================================
  // TAB 2: DIAGRAMA LÓGICO DE CONEXIÓN CON MONITORIZACIÓN INTEGRADA (5 CAPAS)
  // ===========================================================================

  Widget _buildLogicalTopologyTab() {
    final allHosts = _hosts;
    final filteredHosts = allHosts.where((h) {
      if (_layerFilter != 'all' && h['logical_layer'] != _layerFilter) {
        return false;
      }
      if (_stateFilter != 'all' && h['nagios_host_state'] != _stateFilter) {
        return false;
      }
      if (_searchQuery.trim().isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final hay =
            '${h['code']} ${h['name']} ${h['hostname']} ${h['heartbeat_ip']} ${h['rack_location_badge']}'
                .toLowerCase();
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList();

    final selectedHost = allHosts.firstWhere(
      (h) => h['id'] == _selectedHostId,
      orElse: () => allHosts.isNotEmpty ? allHosts.first : <String, dynamic>{},
    );

    final layers = [
      (
        'edge_security',
        'CAPA 1 • WAN / FIREWALLS / PERÍMETRO',
        AppTheme.error,
      ),
      (
        'network_switching',
        'CAPA 2 • SWITCHING CORE / ACCESO & VLANs (SNMP + LLDP)',
        AppTheme.accentCyan,
      ),
      (
        'hypervisors_phys',
        'CAPA 3 • SERVIDORES FÍSICOS DEL RACK / HIPERVISORES VMWARE & PROXMOX / BAREBONE',
        AppTheme.accentBlue,
      ),
      (
        'vms_containers',
        'CAPA 4 • MÁQUINAS VIRTUALES (VMs), DOCKER, LXC & VIPs DE CLÚSTER',
        AppTheme.accentPurple,
      ),
      (
        'services_apps',
        'CAPA 5 • SERVICIOS DE APLICACIÓN Y BASES DE DATOS',
        AppTheme.accentTeal,
      ),
    ];

    return Row(
      children: [
        // Lienzo interactivo de Topología Lógica en 5 Capas
        Expanded(
          flex: 7,
          child: Column(
            children: [
              // Barra de filtros y acciones del Diagrama Lógico
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: const BoxDecoration(
                  color: AppTheme.bgCard,
                  border: Border(bottom: BorderSide(color: AppTheme.border)),
                ),
                child: Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 240,
                      height: 34,
                      child: TextField(
                        onChanged: (v) => _rebuildState(() => _searchQuery = v),
                        style: const TextStyle(fontSize: 12),
                        decoration: const InputDecoration(
                          hintText: 'Filtrar nodo por código, IP, Rack...',
                          prefixIcon: Icon(Icons.search, size: 15),
                          contentPadding: EdgeInsets.symmetric(vertical: 0),
                        ),
                      ),
                    ),
                    DropdownButton<String>(
                      value: _layerFilter,
                      underline: const SizedBox.shrink(),
                      dropdownColor: AppTheme.bgElevated,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.textPrimary,
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'all',
                          child: Text('Todas las Capas Lógicas (1-5)'),
                        ),
                        DropdownMenuItem(
                          value: 'edge_security',
                          child: Text('Capa 1: Edge / Firewalls'),
                        ),
                        DropdownMenuItem(
                          value: 'network_switching',
                          child: Text('Capa 2: Switches SNMP / VLANs'),
                        ),
                        DropdownMenuItem(
                          value: 'hypervisors_phys',
                          child: Text('Capa 3: Físicos Rack / Hipervisores'),
                        ),
                        DropdownMenuItem(
                          value: 'vms_containers',
                          child: Text('Capa 4: VMs / Contenedores / VIPs'),
                        ),
                      ],
                      onChanged: (v) =>
                          _rebuildState(() => _layerFilter = v ?? 'all'),
                    ),
                    DropdownButton<String>(
                      value: _stateFilter,
                      underline: const SizedBox.shrink(),
                      dropdownColor: AppTheme.bgElevated,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.textPrimary,
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'all',
                          child: Text('Todos los Estados Nagios'),
                        ),
                        DropdownMenuItem(
                          value: 'UP',
                          child: Text('Solo UP (Online)'),
                        ),
                        DropdownMenuItem(
                          value: 'DOWN',
                          child: Text('Solo DOWN (Caídos)'),
                        ),
                        DropdownMenuItem(
                          value: 'UNREACHABLE',
                          child: Text('Solo UNREACHABLE'),
                        ),
                        DropdownMenuItem(
                          value: 'MAINTENANCE',
                          child: Text('Solo en Mantenimiento'),
                        ),
                      ],
                      onChanged: (v) =>
                          _rebuildState(() => _stateFilter = v ?? 'all'),
                    ),
                    if (widget.canEdit)
                      OutlinedButton.icon(
                        onPressed: _showCreateLogicalLinkDialog,
                        icon: const Icon(Icons.add_link_rounded, size: 15),
                        label: const Text(
                          '+ Documentar Enlace Lógico',
                          style: TextStyle(fontSize: 11.5),
                        ),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(14),
                  children: [
                    // Tarjeta visual de Topología de Enlaces Lógicos con Monitorización Integrada
                    _buildLogicalLinksFlowBanner(allHosts),
                    const SizedBox(height: 14),
                    // Nodos agrupados por Capa Lógica
                    for (final layer in layers) ...[
                      Builder(
                        builder: (context) {
                          final layerHosts = filteredHosts
                              .where((h) => h['logical_layer'] == layer.$1)
                              .toList();
                          if (layerHosts.isEmpty) {
                            return const SizedBox.shrink();
                          }
                          return Container(
                            margin: const EdgeInsets.only(bottom: 14),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: AppTheme.bgSecondary,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: layer.$3.withValues(alpha: 0.35),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      _layerIcon(layer.$1),
                                      color: layer.$3,
                                      size: 17,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      layer.$2,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w800,
                                        color: layer.$3,
                                        letterSpacing: 0.4,
                                      ),
                                    ),
                                    const Spacer(),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: layer.$3.withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Text(
                                        '${layerHosts.length} nodos',
                                        style: TextStyle(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w700,
                                          color: layer.$3,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  children: layerHosts
                                      .map((h) => _buildLogicalNodeCard(h))
                                      .toList(),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        // Inspector lateral derecho del Nodo seleccionado (con enlaces a Rack Editor, CMDB y Gráficas)
        Container(
          width: 410,
          decoration: const BoxDecoration(
            color: AppTheme.bgSecondary,
            border: Border(left: BorderSide(color: AppTheme.border)),
          ),
          child: selectedHost.isEmpty
              ? const Center(child: Text('Selecciona un nodo del diagrama'))
              : _buildSelectedNodeInspector(selectedHost),
        ),
      ],
    );
  }

  Widget _buildLogicalLinksFlowBanner(List<Map<String, dynamic>> allHosts) {
    final links = _logicalLinks;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.polyline_rounded,
                size: 16,
                color: AppTheme.accentCyan,
              ),
              const SizedBox(width: 8),
              Text(
                'ENLACES LÓGICOS DOCUMENTADOS Y AUTODESCUBIERTOS CON ESTADO EN VIVO (${links.length})',
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.textPrimary,
                ),
              ),
              const Spacer(),
              const Text(
                'Haz clic en cualquier enlace para inspeccionar sus extremos',
                style: TextStyle(fontSize: 10.5, color: AppTheme.textMuted),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 78,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: links.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final lnk = links[index];
                final st = (lnk['status'] as String?) ?? 'UP';
                final col = _nagiosStateColor(st);
                final isSelected =
                    lnk['source_asset_id'] == _selectedHostId ||
                    lnk['target_asset_id'] == _selectedHostId;
                return InkWell(
                  onTap: () {
                    _rebuildState(() {
                      _selectedHostId = lnk['target_asset_id'] as int?;
                    });
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    width: 265,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? AppTheme.accentCyan.withValues(alpha: 0.12)
                          : AppTheme.bgSecondary,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSelected
                            ? AppTheme.accentCyan
                            : col.withValues(alpha: 0.45),
                      ),
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
                                color: col,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                '${lnk['source_code']}  ➔  ${lnk['target_code']}',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w800,
                                  color: AppTheme.textPrimary,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (widget.canEdit)
                              InkWell(
                                onTap: () async {
                                  final res = await widget.api.deleteLogicalLink(
                                    lnk['id'] as int,
                                  );
                                  _rebuildState(() => _overview = res);
                                },
                                child: const Icon(
                                  Icons.close,
                                  size: 13,
                                  color: AppTheme.textMuted,
                                ),
                              ),
                          ],
                        ),
                        Text(
                          '${lnk['source_interface']} ⇄ ${lnk['target_interface']}',
                          style: const TextStyle(
                            fontSize: 10,
                            color: AppTheme.textSecondary,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: col.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '${lnk['protocol_label']}',
                                style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w700,
                                  color: col,
                                ),
                              ),
                            ),
                            const Spacer(),
                            if (lnk['vlan_id'] != null)
                              Text(
                                'VLAN ${lnk['vlan_id']}',
                                style: const TextStyle(
                                  fontSize: 9.5,
                                  color: AppTheme.textMuted,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLogicalNodeCard(Map<String, dynamic> host) {
    final id = host['id'] as int;
    final isSelected = _selectedHostId == id;
    final state = (host['nagios_host_state'] as String?) ?? 'UP';
    final stateCol = _nagiosStateColor(state);
    final checks = ((host['service_checks'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final rackId = host['rack_id'] as int?;
    final targetRackDevId = host['target_rack_device_id'] as int?;

    return InkWell(
      onTap: () {
        _rebuildState(() => _selectedHostId = id);
        _loadHostTelemetry(id);
      },
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 280,
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.bgElevated : AppTheme.bgCard,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected
                ? AppTheme.accentCyan
                : stateCol.withValues(alpha: 0.55),
            width: isSelected ? 2 : 1.2,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: AppTheme.accentCyan.withValues(alpha: 0.18),
                    blurRadius: 10,
                  ),
                ]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Cabecera con Estado Nagios + Código + Latencia
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: stateCol.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: stateCol),
                  ),
                  child: Text(
                    state,
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w800,
                      color: stateCol,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${host['code']}',
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (host['last_ping_ms'] != null)
                  Text(
                    '${host['last_ping_ms']} ms',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.accentTeal,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${host['name']}',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppTheme.textSecondary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            // IP Heartbeat + Multi-IP + Enlace al Rack
            Row(
              children: [
                const Icon(
                  Icons.lan_rounded,
                  size: 12,
                  color: AppTheme.accentCyan,
                ),
                const SizedBox(width: 4),
                Text(
                  '${host['heartbeat_ip']}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                ),
                if (((host['ip_count'] as num?) ?? 1) > 1) ...[
                  const SizedBox(width: 5),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.accentPurple.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '+${(host['ip_count'] as int) - 1} IPs',
                      style: const TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.accentPurple,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 5),
            // Ubicación física en el Rack o Hipervisor Padre
            Row(
              children: [
                const Icon(
                  Icons.view_in_ar_rounded,
                  size: 12,
                  color: AppTheme.warning,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '${host['rack_location_badge']}',
                    style: const TextStyle(
                      fontSize: 10,
                      color: AppTheme.textSecondary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Mini barras de telemetría Prometheus (CPU / RAM)
            Row(
              children: [
                Expanded(
                  child: _buildMiniMetricBar(
                    'CPU',
                    (host['cpu_pct'] as num?)?.toDouble() ?? 0,
                    AppTheme.accentBlue,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildMiniMetricBar(
                    'RAM',
                    (host['ram_pct'] as num?)?.toDouble() ?? 0,
                    AppTheme.accentPurple,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Botones rápidos de Coordinación: Rack Editor / CMDB / Gráficas
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${checks.length} servicios',
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppTheme.textMuted,
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (rackId != null && widget.onNavigateToRackDevice != null)
                      InkWell(
                        onTap: () => widget.onNavigateToRackDevice!(
                          rackId,
                          targetRackDevId,
                        ),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.accentBlue.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Row(
                            children: [
                              Icon(
                                Icons.dns_rounded,
                                size: 11,
                                color: AppTheme.accentBlue,
                              ),
                              SizedBox(width: 3),
                              Text(
                                'Rack Editor',
                                style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.accentBlue,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(width: 5),
                    if (widget.onNavigateToCmdb != null)
                      InkWell(
                        onTap: () =>
                            widget.onNavigateToCmdb!(host['code'] as String?),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.accentTeal.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'CMDB',
                            style: TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.accentTeal,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMiniMetricBar(String label, double pct, Color color) {
    final clamped = pct.clamp(0.0, 100.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 9.5, color: AppTheme.textMuted),
            ),
            Text(
              '${clamped.toStringAsFixed(0)}%',
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: clamped / 100.0,
            minHeight: 4,
            backgroundColor: AppTheme.bgPrimary,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
      ],
    );
  }

  Widget _buildSelectedNodeInspector(Map<String, dynamic> host) {
    final checks = ((host['service_checks'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final allIps = ((host['all_ips'] as List?) ?? []).cast<String>();
    final rackId = host['rack_id'] as int?;
    final targetRackDevId = host['target_rack_device_id'] as int?;
    final state = (host['nagios_host_state'] as String?) ?? 'UP';
    final stateCol = _nagiosStateColor(state);

    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: stateCol.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: stateCol),
              ),
              child: Text(
                '$state (${host['nagios_state_type']})',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  color: stateCol,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${host['code']}',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.textPrimary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${host['name']}',
          style: const TextStyle(fontSize: 12.5, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 10),
        // Botones de coordinación directa con Rack Editor, CMDB y Gráficas Prometheus
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (widget.canEdit)
              ElevatedButton.icon(
                onPressed: () => _showCreateVirtualMachineWithServicesDialog(
                  existingHost: host,
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.accentCyan,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.tune_rounded, size: 15),
                label: const Text(
                  'Configurar Host (Alojamiento, Healthchecks & SSH)',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            if (rackId != null && widget.onNavigateToRackDevice != null)
              ElevatedButton.icon(
                onPressed: () =>
                    widget.onNavigateToRackDevice!(rackId, targetRackDevId),
                icon: const Icon(Icons.view_in_ar_rounded, size: 15),
                label: Text(
                  'Abrir en Rack Editor (${host['rack_code']} U${host['start_u']})',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            if (widget.onNavigateToCmdb != null)
              OutlinedButton.icon(
                onPressed: () =>
                    widget.onNavigateToCmdb!(host['code'] as String?),
                icon: const Icon(Icons.hub_rounded, size: 15),
                label: const Text(
                  'Ver Ficha en CMDB',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            OutlinedButton.icon(
              onPressed: () {
                _tabController.animateTo(4);
                _loadHostTelemetry(host['id'] as int);
              },
              icon: const Icon(Icons.show_chart_rounded, size: 15),
              label: const Text(
                'Ver Gráficas Prometheus',
                style: TextStyle(fontSize: 11),
              ),
            ),
            if (host['ssh_enabled'] != false)
              OutlinedButton.icon(
                onPressed: () => _showSshWebConsoleDialog(
                  {
                    'ssh_user': host['ssh_user'] ?? 'root',
                    'ssh_port': host['ssh_port'] ?? 22,
                  },
                  host,
                ),
                icon: const Icon(Icons.terminal_rounded, size: 15),
                label: Text(
                  'Consola SSH (${host['ssh_user'] ?? 'root'}@${host['ssh_host'] ?? host['heartbeat_ip']})',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
            if (host['web_https_enabled'] == true &&
                (host['web_https_url'] as String? ?? '').isNotEmpty)
              OutlinedButton.icon(
                onPressed: () {
                  launchUrl(
                    Uri.parse('${host['web_https_url']}'),
                    mode: LaunchMode.externalApplication,
                  );
                },
                icon: const Icon(Icons.open_in_new_rounded, size: 15),
                label: const Text(
                  'Abrir Web HTTPS',
                  style: TextStyle(fontSize: 11),
                ),
              ),
          ],
        ),
        const Divider(height: 22),
        _buildKeyValRow('Hostname / FQDN', '${host['hostname']} (${host['fqdn']})'),
        _buildKeyValRow('Capa Lógica', '${host['logical_layer_label']}'),
        _buildKeyValRow('Ubicación Rack / Host', '${host['rack_location_badge']}'),
        _buildKeyValRow('SO / Plataforma', '${host['os_or_firmware']}'),
        _buildKeyValRow(
          'Responsable / Equipo',
          '${host['responsible_person']} • ${host['owner_team']}',
        ),
        _buildKeyValRow(
          'HostGroups Asociados',
          ((host['host_groups'] as List?) ?? []).join(', '),
        ),
        const SizedBox(height: 8),
        const Text(
          'DIRECCIONES IP SINCRONIZADAS CON CMDB',
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
            color: AppTheme.accentCyan,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: allIps
              .map(
                (ip) => Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.bgCard,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: ip == host['heartbeat_ip']
                          ? AppTheme.accentCyan
                          : AppTheme.border,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        ip == host['heartbeat_ip']
                            ? Icons.favorite_rounded
                            : Icons.lan_rounded,
                        size: 12,
                        color: ip == host['heartbeat_ip']
                            ? AppTheme.accentCyan
                            : AppTheme.textSecondary,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        ip,
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              )
              .toList(),
        ),
        const Divider(height: 22),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'HEARTBEATS Y CHEQUEOS NAGIOS (${checks.length})',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: AppTheme.textPrimary,
              ),
            ),
            if (widget.canEdit)
              TextButton.icon(
                onPressed: _showCreateServiceCheckDialog,
                icon: const Icon(Icons.add, size: 14),
                label: const Text('Añadir', style: TextStyle(fontSize: 11)),
              ),
          ],
        ),
        const SizedBox(height: 6),
        ...checks.map((chk) {
          final st = (chk['nagios_state'] as String?) ?? 'OK';
          final col = _nagiosStateColor(st);
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.bgCard,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: col.withValues(alpha: 0.45)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: col.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '$st • ${chk['state_type']} (${chk['attempt_label']})',
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w800,
                          color: col,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${chk['service_name']}',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.play_arrow_rounded, size: 16),
                      tooltip: 'Ejecutar este chequeo ahora',
                      constraints: const BoxConstraints(),
                      padding: EdgeInsets.zero,
                      onPressed: () async {
                        final res = await widget.api
                            .runSingleNetworkServiceCheck(chk['id'] as int);
                        if (res['overview'] is Map) {
                          _rebuildState(() {
                            _overview = Map<String, dynamic>.from(
                              res['overview'] as Map,
                            );
                          });
                        }
                        _showSnack(
                          'Chequeo ejecutado: ${chk['service_name']}',
                        );
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${chk['status_output']}',
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: AppTheme.textSecondary,
                  ),
                ),
                if (chk['ssl_days_remaining'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.lock_clock_rounded,
                          size: 12,
                          color: AppTheme.accentTeal,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Certificado SSL/TLS válido por ${chk['ssl_days_remaining']} días',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.accentTeal,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _buildKeyValRow(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              k,
              style: const TextStyle(
                fontSize: 11,
                color: AppTheme.textMuted,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              v.isEmpty ? '—' : v,
              style: const TextStyle(
                fontSize: 11,
                color: AppTheme.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
