part of '../network_hosts_view.dart';

/// Pestañas 3, 4 y 5 de `4. Red & Host`: máquina de estados Nagios Core,
/// conectores y switches SNMP, y telemetría de series temporales Prometheus.
extension _NetworkHostsNagiosSnmpPrometheusExt on _NetworkHostsViewState {
  // ===========================================================================
  // TAB 2: MONITOR DE ESTADOS (NAGIOS TAC) & HEARTBEATS MULTI-PROTOCOLO
  // ===========================================================================

  Widget _buildNagiosServiceMonitorTab() {
    final allRows = <Map<String, dynamic>>[];
    for (final h in _hosts) {
      final checks = ((h['service_checks'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      for (final c in checks) {
        allRows.add({...c, 'host': h});
      }
    }

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.monitor_heart_rounded,
                color: AppTheme.accentCyan,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                'MATRIZ DE ESTADOS NAGIOS CORE (SOFT/HARD 1/3..3/3) Y HEARTBEATS MULTI-PROTOCOLO (${allRows.length})',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.textPrimary,
                ),
              ),
              const Spacer(),
              if (widget.canEdit)
                ElevatedButton.icon(
                  onPressed: _showCreateServiceCheckDialog,
                  icon: const Icon(Icons.add, size: 15),
                  label: const Text(
                    'Añadir Heartbeat HTTP / HTTPS / TCP / SSH / Apache / Nginx / Docker / BBDD',
                    style: TextStyle(fontSize: 11.5),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: AppTheme.bgSecondary,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.border),
              ),
              child: ListView.separated(
                itemCount: allRows.length,
                separatorBuilder: (_, _) =>
                    const Divider(height: 1, color: AppTheme.border),
                itemBuilder: (context, idx) {
                  final row = allRows[idx];
                  final host = Map<String, dynamic>.from(row['host'] as Map);
                  final st = (row['nagios_state'] as String?) ?? 'OK';
                  final col = _nagiosStateColor(st);
                  final hostState =
                      (host['nagios_host_state'] as String?) ?? 'UP';
                  final hostCol = _nagiosStateColor(hostState);

                  return ListTile(
                    dense: true,
                    leading: Container(
                      width: 86,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: col.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: col),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        '$st (${row['attempt_label']})',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: col,
                        ),
                      ),
                    ),
                    title: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: hostCol.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '${host['code']} [$hostState]',
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                              color: hostCol,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${row['service_name']}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.bgCard,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: AppTheme.border),
                          ),
                          child: Text(
                            '${row['check_type']}'.toUpperCase(),
                            style: const TextStyle(
                              fontSize: 9.5,
                              fontFamily: 'monospace',
                              color: AppTheme.accentCyan,
                            ),
                          ),
                        ),
                        if (row['ssl_days_remaining'] != null) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.accentTeal.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'SSL: ${row['ssl_days_remaining']}d',
                              style: const TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.accentTeal,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    subtitle: Text(
                      'Target: ${row['target_ip_or_url']} • ${row['status_output']}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (row['latency_ms'] != null)
                          Text(
                            '${row['latency_ms']} ms',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.accentTeal,
                            ),
                          ),
                        const SizedBox(width: 8),
                        IconButton(
                          icon: const Icon(Icons.refresh_rounded, size: 17),
                          tooltip: 'Forzar chequeo ahora',
                          onPressed: () async {
                            final res = await widget.api
                                .runSingleNetworkServiceCheck(row['id'] as int);
                            if (res['overview'] is Map) {
                              _rebuildState(() {
                                _overview = Map<String, dynamic>.from(
                                  res['overview'] as Map,
                                );
                              });
                            }
                            _showSnack(
                              'Chequeo actualizado: ${row['service_name']}',
                            );
                          },
                        ),
                        if (widget.canEdit)
                          IconButton(
                            icon: const Icon(
                              Icons.delete_outline_rounded,
                              size: 17,
                              color: AppTheme.error,
                            ),
                            tooltip: 'Eliminar chequeo',
                            onPressed: () async {
                              final res = await widget.api
                                  .deleteNetworkServiceCheck(row['id'] as int);
                              _rebuildState(() => _overview = res);
                            },
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // TAB 3: SWITCHES SNMP Y CONECTORES DE INFRAESTRUCTURA
  // Ojo: el inventario de bocas IF-MIB / LLDP-MIB no está implementado en el
  // backend (la tabla switch_snmp_ports nunca se rellena), así que la rejilla de
  // bocas sale siempre vacía. Ver "Estado de implementación" en el README.
  // ===========================================================================

  Widget _buildSnmpSwitchesAndConnectorsTab() {
    final swHosts = _hosts
        .where(
          (h) =>
              h['logical_layer'] == 'network_switching' ||
              ((h['snmp_ports_count'] as num?) ?? 0) > 0,
        )
        .toList();
    final selectedSw = swHosts.firstWhere(
      (h) => h['id'] == _selectedSwitchAssetId,
      orElse: () => swHosts.isNotEmpty ? swHosts.first : <String, dynamic>{},
    );
    final swPorts = ((selectedSw['snmp_ports'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 1. Panel Visual de Switch SNMP + LLDP
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.bgSecondary,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.settings_ethernet_rounded,
                        color: AppTheme.accentCyan,
                        size: 20,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'COMPROBACIÓN SNMP DE SWITCHES Y ALTA EN LA CMDB',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (swHosts.isNotEmpty)
                        DropdownButton<int>(
                          value: selectedSw['id'] as int?,
                          dropdownColor: AppTheme.bgElevated,
                          underline: const SizedBox.shrink(),
                          items: swHosts
                              .map(
                                (s) => DropdownMenuItem<int>(
                                  value: s['id'] as int,
                                  child: Text(
                                    '${s['code']} — ${s['name']} (${s['heartbeat_ip']})',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (v) =>
                              _rebuildState(() => _selectedSwitchAssetId = v),
                        ),
                      const SizedBox(width: 10),
                      ElevatedButton.icon(
                        onPressed: _showSnmpDiscoveryDialog,
                        icon: const Icon(Icons.radar_rounded, size: 15),
                        label: const Text(
                          'Comprobar Switch por SNMP',
                          style: TextStyle(fontSize: 11.5),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (swPorts.isEmpty)
                const Text(
                  'El inventario de bocas (IF-MIB) y de vecinos (LLDP-MIB) no está implementado: esta rejilla '
                  'siempre sale vacía. "Comprobar Switch por SNMP" sí interroga de verdad al equipo con un '
                  'GetRequest y lo da de alta en la CMDB si responde.',
                  style: TextStyle(color: AppTheme.textSecondary),
                )
              else ...[
                // Frontal gráfico de 28 bocas del Switch
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.bgPrimary,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: swPorts.map((p) {
                      final isUp = p['oper_status'] == 'up';
                      final hasLldp =
                          ((p['lldp_neighbor_sysname'] as String?) ?? '')
                              .isNotEmpty;
                      final col = isUp ? AppTheme.success : AppTheme.textMuted;
                      return Tooltip(
                        message:
                            '${p['if_name']} (${p['if_alias']})\n'
                            'Estado: ${p['oper_status'].toString().toUpperCase()} • ${p['speed_mbps']} Mbps • VLAN ${p['vlan_id']} (${p['vlan_mode']})\n'
                            'Tráfico: Rx ${p['in_mbps']} Mbps / Tx ${p['out_mbps']} Mbps\n'
                            'Vecino LLDP: ${hasLldp ? "${p['lldp_neighbor_sysname']} (${p['lldp_neighbor_port']})" : "Ninguno"}',
                        child: Container(
                          width: 72,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: isUp
                                ? col.withValues(alpha: 0.14)
                                : AppTheme.bgSecondary,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: hasLldp
                                  ? AppTheme.accentCyan
                                  : col.withValues(alpha: 0.5),
                            ),
                          ),
                          child: Column(
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Container(
                                    width: 7,
                                    height: 7,
                                    decoration: BoxDecoration(
                                      color: col,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  Text(
                                    '${p['if_name']}',
                                    style: const TextStyle(
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 3),
                              Text(
                                isUp ? '${p['in_mbps']}M' : 'DOWN',
                                style: TextStyle(
                                  fontSize: 9,
                                  color: col,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                hasLldp
                                    ? '${p['lldp_neighbor_sysname']}'
                                    : 'VLAN ${p['vlan_id']}',
                                style: const TextStyle(
                                  fontSize: 8.5,
                                  color: AppTheme.textSecondary,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 18),
        // 2. Conectores de Infraestructura (Proxmox, VMware, Docker, Apache, Nginx, BBDD, Exporters)
        Row(
          children: [
            const Icon(Icons.power_rounded, color: AppTheme.accentTeal, size: 20),
            const SizedBox(width: 8),
            Text(
              'CONECTORES REGISTRADOS DE VIRTUALIZACIÓN, CONTENEDORES, SERVIDORES WEB Y BBDD (${_connectors.length})',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
            ),
            const Spacer(),
            if (widget.canEdit)
              ElevatedButton.icon(
                onPressed: _showCreateConnectorDialog,
                icon: const Icon(Icons.add, size: 15),
                label: const Text(
                  '+ Nuevo Conector (Proxmox / VMware / Docker / Apache / Nginx / BBDD)',
                  style: TextStyle(fontSize: 11.5),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        // El semáforo de un conector no significa lo mismo según su tipo, así que
        // se explica aquí en lugar de dejar que el verde se lea como "comprobado".
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: AppTheme.bgElevated,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppTheme.warning.withValues(alpha: 0.45)),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline_rounded,
                  color: AppTheme.warning, size: 16),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Qué comprueba realmente «Sincronizar»: los conectores SNMP interrogan al equipo; los '
                  'exporters (node_exporter, windows_exporter, haproxy_stats) quedan publicados para que '
                  'Prometheus los raspe cada 15 s. Para el resto de tipos (Proxmox, VMware, Docker, Apache, '
                  'Nginx, bases de datos) la sincronización no está implementada: no se contacta con el '
                  'sistema remoto y el conector es solo un registro de inventario.',
                  style: TextStyle(fontSize: 11.5, height: 1.45),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: _connectors.map((c) {
            return Container(
              width: 350,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.bgSecondary,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // El color sale del estado, no es verde fijo: 'never' significa
                      // que no se ha contactado con el sistema remoto y no puede
                      // pintarse igual que una sincronización correcta.
                      Builder(
                        builder: (_) {
                          final estado = '${c['last_sync_status']}'.toLowerCase();
                          final color = switch (estado) {
                            'ok' => AppTheme.success,
                            'warning' => AppTheme.warning,
                            'error' => AppTheme.error,
                            _ => AppTheme.textMuted,
                          };
                          final rotulo = switch (estado) {
                            'never' => 'SIN COMPROBAR',
                            '' => 'SIN COMPROBAR',
                            _ => estado.toUpperCase(),
                          };
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              rotulo,
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                                color: color,
                              ),
                            ),
                          );
                        },
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${c['name']}',
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${c['connector_type_label']}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.accentCyan,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Endpoint: ${c['endpoint_host']}:${c['endpoint_port']} • Nodo: ${c['linked_asset_code']}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${c['last_sync_summary']}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () async {
                          final res = await widget.api.syncInfraConnector(
                            c['id'] as int,
                          );
                          _rebuildState(() => _overview = res);
                          _showSnack('Conector actualizado: ${c['name']}');
                        },
                        icon: const Icon(Icons.sync_rounded, size: 14),
                        label: const Text(
                          'Sincronizar Ahora',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                      if (widget.canEdit) ...[
                        const SizedBox(width: 6),
                        IconButton(
                          icon: const Icon(
                            Icons.delete_outline,
                            size: 16,
                            color: AppTheme.error,
                          ),
                          onPressed: () async {
                            final res = await widget.api.deleteInfraConnector(
                              c['id'] as int,
                            );
                            _rebuildState(() => _overview = res);
                          },
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  // ===========================================================================
  // TAB 5: GRÁFICAS PROMETHEUS TSDB (COLUMNA IZQUIERDA: DATOS Y GRÁFICAS DEL
  // ELEMENTO SELECCIONADO | COLUMNA DERECHA: LISTA ORGANIZADA DE ELEMENTOS)
  // + BOTÓN PARA VER Y DESCARGAR QUÉ INSTALAR EN FORMATO MARKDOWN (.MD)
  // ===========================================================================

  Widget _buildPrometheusChartsAndAgentsTab() {
    final allHosts = _hosts;
    if (_selectedHostId == null && allHosts.isNotEmpty) {
      _selectedHostId = allHosts.first['id'] as int;
    }
    final selectedHost = allHosts.firstWhere(
      (h) => h['id'] == _selectedHostId,
      orElse: () => allHosts.isNotEmpty ? allHosts.first : <String, dynamic>{},
    );

    final rawPts = ((_telemetryData?['points'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final pts = rawPts.isNotEmpty
        ? rawPts
        : (selectedHost.isNotEmpty
              ? _buildFallbackSeriesFromMini(selectedHost)
              : <Map<String, dynamic>>[]);

    final promQueries = Map<String, dynamic>.from(
      (_telemetryData?['promql_examples'] as Map?) ?? {},
    );
    final checks = ((selectedHost['service_checks'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    // Filtrado y organización de la columna derecha de elementos
    final filteredRightHosts = allHosts.where((h) {
      if (_promCategoryFilter != 'all') {
        final layer = '${h['logical_layer'] ?? ''}';
        if (_promCategoryFilter == 'apps' && layer != 'services_apps') {
          return false;
        }
        if (_promCategoryFilter == 'Compute' &&
            layer != 'virtualization_compute' &&
            layer != 'physical_rack') {
          return false;
        }
        if (_promCategoryFilter == 'net' &&
            layer != 'network_switching' &&
            layer != 'perimeter_security') {
          return false;
        }
      }
      if (_promHostSearch.trim().isNotEmpty) {
        final q = _promHostSearch.trim().toLowerCase();
        final hay =
            '${h['code']} ${h['name']} ${h['heartbeat_ip']} ${h['os_or_firmware']} ${h['asset_class_label']}'
                .toLowerCase();
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList();

    final hostState = (selectedHost['nagios_host_state'] as String?) ?? 'UP';
    final hostStateCol = _nagiosStateColor(hostState);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // =====================================================================
        // COLUMNA IZQUIERDA (FIJA 350PX): DIRECTORIO ORGANIZADO DE ELEMENTOS
        // Al pulsar sobre cualquiera, sus datos y gráficas aparecen a la derecha
        // =====================================================================
        Container(
          width: 350,
          decoration: const BoxDecoration(
            color: AppTheme.bgCard,
            border: Border(right: BorderSide(color: AppTheme.border)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'ELEMENTOS / HOSTS (${filteredRightHosts.length})',
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w900,
                            color: AppTheme.textPrimary,
                            letterSpacing: 0.4,
                          ),
                        ),
                        const Text(
                          'Pulsa para ver gráficas',
                          style: TextStyle(
                            fontSize: 9.8,
                            color: AppTheme.accentBlue,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      onChanged: (v) => _rebuildState(() => _promHostSearch = v),
                      style: const TextStyle(fontSize: 11.5),
                      decoration: InputDecoration(
                        hintText: 'Buscar por código, nombre o IP...',
                        prefixIcon: const Icon(Icons.search, size: 16),
                        isDense: true,
                        filled: true,
                        fillColor: AppTheme.bgSecondary,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: AppTheme.border),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final cat in [
                            ('all', 'Todos (${allHosts.length})'),
                            ('apps', 'VMs / Apps / BBDD'),
                            ('Compute', 'Físicos / Hiperv.'),
                            ('net', 'Switches / Red'),
                          ])
                            Padding(
                              padding: const EdgeInsets.only(right: 5),
                              child: ChoiceChip(
                                label: Text(
                                  cat.$2,
                                  style: const TextStyle(fontSize: 9.8),
                                ),
                                selected: _promCategoryFilter == cat.$1,
                                onSelected: (_) => _rebuildState(
                                  () => _promCategoryFilter = cat.$1,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(10),
                  itemCount: filteredRightHosts.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, idx) {
                    final h = filteredRightHosts[idx];
                    final hid = h['id'] as int;
                    final isSel = hid == selectedHost['id'];
                    final st = (h['nagios_host_state'] as String?) ?? 'UP';
                    final stCol = _nagiosStateColor(st);

                    return InkWell(
                      borderRadius: BorderRadius.circular(9),
                      onTap: () {
                        _rebuildState(() => _selectedHostId = hid);
                        _loadHostTelemetry(hid);
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: isSel
                              ? AppTheme.accentBlue.withValues(alpha: 0.12)
                              : AppTheme.bgSecondary,
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(
                            color: isSel
                                ? AppTheme.accentBlue
                                : AppTheme.border,
                            width: isSel ? 1.8 : 1.0,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
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
                                Expanded(
                                  child: Text(
                                    '${h['code']}',
                                    style: TextStyle(
                                      fontSize: 11.2,
                                      fontWeight: FontWeight.w900,
                                      color: isSel
                                          ? AppTheme.accentBlue
                                          : AppTheme.textPrimary,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(
                                  '${h['heartbeat_ip']}',
                                  style: const TextStyle(
                                    fontSize: 9.8,
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.accentTeal,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${h['name']}',
                              style: const TextStyle(
                                fontSize: 10.2,
                                color: AppTheme.textSecondary,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'CPU ${h['cpu_pct'] ?? 0}% • RAM ${h['ram_pct'] ?? 0}%',
                                  style: const TextStyle(
                                    fontSize: 9.2,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.textMuted,
                                  ),
                                ),
                                Text(
                                  '${h['last_ping_ms'] ?? '-'} ms',
                                  style: const TextStyle(
                                    fontSize: 9.2,
                                    fontFamily: 'monospace',
                                    color: AppTheme.accentCyan,
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
        ),

        // =====================================================================
        // COLUMNA DERECHA (EXPANDED): DATOS DEL ELEMENTO SELECCIONADO +
        // GRÁFICAS PROMETHEUS EN CUADRÍCULA 2X2 NIVELADA + CHEQUEOS + BOTÓN .MD
        // =====================================================================
        Expanded(
          child: selectedHost.isEmpty
              ? const Center(
                  child: Text(
                    'Selecciona un elemento en la columna de la izquierda para ver sus datos y gráficas Prometheus.',
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    // 1. Cabecera organizada con todos los datos clave del elemento + Botón Qué Instalar (.md)
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppTheme.bgSecondary,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppTheme.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 10,
                            runSpacing: 8,
                            alignment: WrapAlignment.spaceBetween,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: hostStateCol.withValues(
                                        alpha: 0.16,
                                      ),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(color: hostStateCol),
                                    ),
                                    child: Text(
                                      hostState,
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w900,
                                        color: hostStateCol,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '${selectedHost['code']} — ${selectedHost['name']}',
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w900,
                                          color: AppTheme.textPrimary,
                                        ),
                                      ),
                                      Text(
                                        'IP: ${selectedHost['heartbeat_ip']} • ${selectedHost['asset_class_label']} • ${selectedHost['rack_location_badge']}',
                                        style: const TextStyle(
                                          fontSize: 11,
                                          fontFamily: 'monospace',
                                          color: AppTheme.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              Wrap(
                                spacing: 8,
                                runSpacing: 6,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  // Selector de ventana temporal (1h, 6h, 24h, 7d)
                                  for (final hrs in [1, 6, 24, 168])
                                    ChoiceChip(
                                      label: Text(
                                        hrs == 168 ? '7d' : '${hrs}h',
                                        style: const TextStyle(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      selected: _telemetryRangeHours == hrs,
                                      onSelected: (_) {
                                        _rebuildState(
                                          () => _telemetryRangeHours = hrs,
                                        );
                                        if (_selectedHostId != null) {
                                          _loadHostTelemetry(_selectedHostId!);
                                        }
                                      },
                                    ),
                                  // BOTÓN DE ENLACE AL CENTRO DE DOCUMENTACIÓN EN 8. ALARMAS SRE
                                  ElevatedButton.icon(
                                    onPressed: () {
                                      if (widget.onOpenSreDocs != null) {
                                        widget.onOpenSreDocs!();
                                      } else if (widget.isSreAlarmsMode) {
                                        _tabController.animateTo(2);
                                      } else {
                                        _showWhatToInstallMarkdownDialog(
                                          selectedHost,
                                        );
                                      }
                                    },
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppTheme.accentBlue,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 9,
                                      ),
                                    ),
                                    icon: const Icon(
                                      Icons.menu_book_rounded,
                                      size: 16,
                                    ),
                                    label: const Text(
                                      'Ir a Documentación Agentes (.md) en 8. Alarmas SRE',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const Divider(height: 18),
                          // Píldoras de resumen técnico del elemento seleccionado
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              _buildTechMetricBadge(
                                'CPU Actual',
                                '${selectedHost['cpu_pct'] ?? 0}%',
                                AppTheme.accentBlue,
                              ),
                              _buildTechMetricBadge(
                                'Memoria RAM',
                                '${selectedHost['ram_pct'] ?? 0}%',
                                AppTheme.accentPurple,
                              ),
                              _buildTechMetricBadge(
                                'Uso Disco',
                                '${selectedHost['disk_pct'] ?? 0}%',
                                AppTheme.warning,
                              ),
                              _buildTechMetricBadge(
                                'Latencia Ping',
                                '${selectedHost['last_ping_ms'] ?? '-'} ms',
                                AppTheme.accentTeal,
                              ),
                              _buildTechMetricBadge(
                                'SO / Plataforma',
                                '${selectedHost['os_or_firmware'] ?? '-'}',
                                AppTheme.accentCyan,
                              ),
                              _buildTechMetricBadge(
                                'Responsable / Equipo',
                                '${selectedHost['owner_team'] ?? '-'}',
                                AppTheme.textSecondary,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),

                    // 2. Cuadrícula 2x2 perfectamente alineada con las 4 Gráficas Prometheus del elemento
                    if (_loadingTelemetry)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(36),
                          child: CircularProgressIndicator(),
                        ),
                      )
                    else ...[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _buildTelemetryChartCard(
                              title: '1. USO DE CPU (%) & MEMORIA RAM (%)',
                              promQl:
                                  '${promQueries['cpu'] ?? 'node_cpu_seconds_total / node_memory_MemAvailable_bytes'}',
                              points: pts,
                              metricKeyA: 'cpu_pct',
                              labelA: 'CPU %',
                              colorA: AppTheme.accentBlue,
                              metricKeyB: 'ram_pct',
                              labelB: 'RAM %',
                              colorB: AppTheme.accentPurple,
                              unit: '%',
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildTelemetryChartCard(
                              title: '2. LATENCIA DEL HEARTBEAT ICMP/HTTP (MS)',
                              promQl:
                                  '${promQueries['latency'] ?? 'probe_duration_seconds * 1000'}',
                              points: pts,
                              metricKeyA: 'latency_ms',
                              labelA: 'RTT ms',
                              colorA: AppTheme.accentTeal,
                              unit: 'ms',
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: _buildTelemetryChartCard(
                              title:
                                  '3. TRÁFICO DE RED RX / TX (MBPS - IF-MIB / NODE_EXPORTER)',
                              promQl:
                                  '${promQueries['switch_traffic'] ?? 'rate(node_network_receive_bytes_total[5m])'}',
                              points: pts,
                              metricKeyA: 'rx_mbps',
                              labelA: 'RX (Mbps)',
                              colorA: AppTheme.accentCyan,
                              metricKeyB: 'tx_mbps',
                              labelB: 'TX (Mbps)',
                              colorB: AppTheme.warning,
                              unit: 'Mbps',
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildTelemetryChartCard(
                              title:
                                  '4. PETICIONES WEB (REQ/S) & OCUPACIÓN DE DISCO (%)',
                              promQl: 'rackdoc_host_disk_usage_percent',
                              points: pts,
                              metricKeyA: 'web_req_per_sec',
                              labelA: 'Web req/s',
                              colorA: AppTheme.success,
                              metricKeyB: 'disk_pct',
                              labelB: 'Disco %',
                              colorB: AppTheme.error,
                              unit: '',
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 14),

                    // 3. Ficha de Servicios Monitorizados y Datos Técnicos del Elemento Seleccionado
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppTheme.bgSecondary,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppTheme.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'CHEQUEOS ACTIVOS Y SERVICIOS DEL ELEMENTO (${checks.length})',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w900,
                                  color: AppTheme.accentCyan,
                                ),
                              ),
                              if (selectedHost['ssh_enabled'] != false &&
                                  selectedHost['connect_enabled'] != false)
                                OutlinedButton.icon(
                                  onPressed: () => _showSshWebConsoleDialog(
                                    {
                                      'ssh_user':
                                          selectedHost['ssh_user'] ?? 'root',
                                      'ssh_port':
                                          selectedHost['ssh_port'] ?? 22,
                                    },
                                    selectedHost,
                                  ),
                                  icon: const Icon(
                                    Icons.terminal_rounded,
                                    size: 14,
                                  ),
                                  label: Text(
                                    'Conectar SSH (${selectedHost['ssh_user'] ?? 'root'}@${selectedHost['heartbeat_ip']})',
                                    style: const TextStyle(fontSize: 10.5),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (checks.isEmpty)
                            const Text(
                              'Este elemento no tiene chequeos activos configurados.',
                              style: TextStyle(
                                fontSize: 11,
                                color: AppTheme.textMuted,
                              ),
                            )
                          else
                            for (final chk in checks)
                              Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 7,
                                ),
                                decoration: BoxDecoration(
                                  color: AppTheme.bgCard,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: AppTheme.border),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.circle,
                                      size: 9,
                                      color: _nagiosStateColor(
                                        (chk['nagios_state'] as String?) ??
                                            'OK',
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        '${chk['service_name']} [${chk['check_type'].toString().toUpperCase()}] ➔ ${chk['target_ip_or_url']}',
                                        style: const TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      '${chk['status_output']}',
                                      style: const TextStyle(
                                        fontSize: 10.5,
                                        color: AppTheme.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildTechMetricBadge(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label: ',
            style: const TextStyle(
              fontSize: 10,
              color: AppTheme.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w900,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  String _buildMonitoringInstallMarkdown(Map<String, dynamic> host) {
    final code = '${host['code'] ?? 'HOST'}';
    final name = '${host['name'] ?? 'Sistema'}';
    final ip = '${host['heartbeat_ip'] ?? '10.0.0.10'}';
    final os = '${host['os_or_firmware'] ?? 'Linux / Windows'}';
    final cls = '${host['asset_class_label'] ?? 'Servidor / VM'}';

    return '''# Guía de Instalación de Agentes y Exporters para Monitorización en Prometheus y RackDoc

## 1. Ficha del Elemento Seleccionado
- **Código CMDB / Host**: `$code`
- **Nombre**: $name
- **Dirección IP Principal**: `$ip`
- **Tipo de Elemento**: $cls
- **SO / Firmware**: $os
- **Fichero de Service Discovery en RackDoc**: `/app/data/prometheus/targets_dynamic.json` (actualizado automáticamente cada vez que guardas un elemento en RackDoc).

---

## 2. Linux (Ubuntu / Debian / RHEL / Proxmox VE) — `prometheus-node-exporter (:9100)`
Expone uso de CPU, Memoria RAM, Carga de sistema, Espacio e I/O de Discos, Tráfico de Interfaces de Red y estado de unidades `systemd`.

```bash
# En Ubuntu / Debian / Proxmox VE ($ip):
sudo apt-get update && sudo apt-get install -y prometheus-node-exporter
sudo systemctl enable --now prometheus-node-exporter

# En RHEL / Rocky / AlmaLinux:
sudo dnf install -y golang-github-prometheus-node-exporter
sudo systemctl enable --now node_exporter

# Verificar que responde métricas en el puerto 9100:
curl -s http://$ip:9100/metrics | head -n 20
```

---

## 3. Windows Server (Active Directory / IIS / SQL Server / Hyper-V) — `windows_exporter (:9182)`
Expone CPU, Memoria RAM, Discos NTFS, Servicios de Windows, IIS y contadores de Hyper-V/AD.

```powershell
# Ejecutar en PowerShell como Administrador en $ip:
Invoke-WebRequest -Uri "https://github.com/prometheus-community/windows_exporter/releases/latest/download/windows_exporter-0.27.3-amd64.msi" -OutFile C:\\windows_exporter.msi
msiexec /i C:\\windows_exporter.msi ENABLED_COLLECTORS="cpu,cs,logical_disk,net,os,service,system,memory" LISTEN_PORT=9182 /qn

# Verificar respuesta:
Invoke-WebRequest -Uri "http://localhost:9182/metrics" -UseBasicParsing
```

---

## 4. Switches, Routers y Firewalls (Cisco, Aruba, FortiGate, MikroTik) — `SNMPv2c/v3 (:161/UDP)`
Permite a RackDoc comprobar que el equipo responde por SNMP y darlo de alta en la CMDB con su IP de gestión.

> **Nota**: el inventario de bocas (`IF-MIB`) y de vecinos (`LLDP-MIB`) **no está implementado**. Dejar `lldp run` configurado no hace daño y servirá cuando lo esté, pero hoy RackDoc no lee esas tablas.

```text
! Configuración en Switch Cisco IOS / Catalyst / Aruba ($ip):
snmp-server community public RO
snmp-server location "CPD Principal RackDoc"
lldp run
```

---

## 5. Servidores Web Apache HTTPd & Nginx
Permite medir peticiones por segundo (`req/s`), workers activos y conexiones concurrentes.

```nginx
# En Nginx (/etc/nginx/conf.d/status.conf):
location /nginx_status {
    stub_status on;
    allow 10.0.0.0/8;
    allow 127.0.0.1;
    deny all;
}
```

```apache
# En Apache (/etc/apache2/mods-enabled/status.conf):
ExtendedStatus On
<Location "/server-status">
    SetHandler server-status
    Require ip 10.0.0.0/8 127.0.0.1
</Location>
```

---

## 6. Bases de Datos (PostgreSQL / MySQL / Redis) y Docker Engine
```bash
# PostgreSQL Exporter (:9187):
DATA_SOURCE_NAME="postgresql://postgres:password@$ip:5432/postgres?sslmode=disable" prometheus-postgres-exporter

# Redis Exporter (:9121):
prometheus-redis-exporter --redis.addr="redis://$ip:6379"

# Docker Engine (/etc/docker/daemon.json -> puerto 9323):
# { "metrics-addr": "0.0.0.0:9323", "experimental": true }
```
''';
  }

  Future<void> _downloadMarkdownGuide(
    String markdownContent,
    String filename,
  ) async {
    try {
      await Clipboard.setData(ClipboardData(text: markdownContent));
      final uri = Uri.dataFromString(
        markdownContent,
        mimeType: 'text/markdown',
        encoding: utf8,
      );
      await launchUrl(uri, webOnlyWindowName: '_blank');
      _showSnack(
        'Descargando $filename (y copiado al portapapeles en formato Markdown .md)',
      );
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: markdownContent));
      _showSnack(
        'Contenido Markdown (.md) copiado al portapapeles listo para guardar como $filename',
      );
    }
  }

  Future<void> _showWhatToInstallMarkdownDialog(
    Map<String, dynamic> host,
  ) async {
    final code = '${host['code'] ?? 'host'}'.toLowerCase();
    final filename = 'guia_monitorizacion_$code.md';
    final mdText = _buildMonitoringInstallMarkdown(host);

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                '¿Qué instalar para monitorizar ${host['code'] ?? "un elemento"}? ($filename)',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => Navigator.pop(ctx),
            ),
          ],
        ),
        content: SizedBox(
          width: 760,
          height: 520,
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.bgPrimary,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.border),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                mdText,
                style: const TextStyle(
                  fontSize: 11.5,
                  fontFamily: 'monospace',
                  color: AppTheme.textPrimary,
                  height: 1.45,
                ),
              ),
            ),
          ),
        ),
        actions: [
          OutlinedButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: mdText));
              _showSnack('Documento Markdown copiado al portapapeles');
            },
            icon: const Icon(Icons.copy_rounded, size: 15),
            label: const Text('Copiar Markdown'),
          ),
          ElevatedButton.icon(
            onPressed: () => _downloadMarkdownGuide(mdText, filename),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.accentBlue,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.download_rounded, size: 16),
            label: Text('Descargar $filename'),
          ),
        ],
      ),
    );
  }

  Widget _buildTelemetryChartCard({
    required String title,
    required String promQl,
    required List<Map<String, dynamic>> points,
    required String metricKeyA,
    required String labelA,
    required Color colorA,
    String? metricKeyB,
    String? labelB,
    Color? colorB,
    required String unit,
  }) {
    final valsA = points
        .map((p) => (p[metricKeyA] as num?)?.toDouble() ?? 0.0)
        .toList();
    final lastA = valsA.isNotEmpty ? valsA.last : 0.0;
    final maxA = valsA.isNotEmpty ? valsA.reduce(math.max) : 0.0;
    final minA = valsA.isNotEmpty ? valsA.reduce(math.min) : 0.0;
    final avgA = valsA.isNotEmpty
        ? valsA.reduce((a, b) => a + b) / valsA.length
        : 0.0;

    final valsB = metricKeyB != null
        ? points
              .map((p) => (p[metricKeyB] as num?)?.toDouble() ?? 0.0)
              .toList()
        : <double>[];
    final lastB = valsB.isNotEmpty ? valsB.last : null;

    return Container(
      height: 242,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.bgSecondary,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: colorA.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  '$labelA: ${lastA.toStringAsFixed(1)} $unit',
                  style: TextStyle(
                    fontSize: 10.2,
                    fontWeight: FontWeight.w800,
                    color: colorA,
                  ),
                ),
              ),
              if (lastB != null && labelB != null && colorB != null) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colorB.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    '$labelB: ${lastB.toStringAsFixed(1)} $unit',
                    style: TextStyle(
                      fontSize: 10.2,
                      fontWeight: FontWeight.w800,
                      color: colorB,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  'PromQL: $promQl',
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontFamily: 'monospace',
                    color: AppTheme.textMuted,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                'Máx ${maxA.toStringAsFixed(1)}$unit • Media ${avgA.toStringAsFixed(1)}$unit • Mín ${minA.toStringAsFixed(1)}$unit',
                style: const TextStyle(
                  fontSize: 9.2,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Expanded(
            child: SizedBox(
              width: double.infinity,
              child: ClipRect(
                child: CustomPaint(
                  painter: _PrometheusSeriesChartPainter(
                    points: points,
                    keyA: metricKeyA,
                    colorA: colorA,
                    keyB: metricKeyB,
                    colorB: colorB,
                    unit: unit,
                    warnThreshold: unit == '%' ? 75.0 : null,
                    critThreshold: unit == '%' ? 90.0 : null,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
