part of '../network_hosts_view.dart';

/// Pestaña 1 de `8. Alarmas SRE`: monitor en vivo de dispositivos en alarma,
/// cálculo de antigüedad de incidencia, filtros multi-criterio y saltos directos.
extension _NetworkHostsSreAlarmsLiveTabExt on _NetworkHostsViewState {
  // ===========================================================================
  // PESTAÑA 1 DE 8. ALARMAS SRE: ESTADO DE TODOS LOS DISPOSITIVOS, ALARMAS EN VIVO,
  // DESDE CUÁNDO ESTÁN EN ALARMA, BÚSQUEDAS/FILTROS Y ENLACES AL FINAL DE LA LÍNEA
  // ===========================================================================

  String _effectiveDeviceAlarmState(Map<String, dynamic> host) {
    final backendState =
        (host['overall_alarm_state'] as String? ?? '').toUpperCase();
    if (backendState.isNotEmpty) return backendState;
    final hostState =
        (host['nagios_host_state'] as String? ?? 'UP').toUpperCase();
    if (hostState == 'MAINTENANCE') return 'MAINTENANCE';
    final checks = ((host['service_checks'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final hasCrit = checks.any(
      (c) => (c['nagios_state'] as String? ?? '').toUpperCase() == 'CRITICAL',
    );
    if (hostState == 'DOWN' || hasCrit) return 'CRITICAL';
    if (hostState == 'UNREACHABLE') return 'UNREACHABLE';
    final hasWarn = checks.any(
      (c) => (c['nagios_state'] as String? ?? '').toUpperCase() == 'WARNING',
    );
    if (hasWarn) return 'WARNING';
    return 'OK';
  }

  int _alarmPriorityRank(String alarmState) {
    switch (alarmState.toUpperCase()) {
      case 'CRITICAL':
      case 'DOWN':
        return 0;
      case 'UNREACHABLE':
        return 1;
      case 'WARNING':
        return 2;
      case 'MAINTENANCE':
        return 3;
      default:
        return 4;
    }
  }

  DateTime? _parseHostStateSince(Map<String, dynamic> host) {
    final raw = (host['state_since_at'] as String?) ??
        (host['last_checked_at'] as String?);
    if (raw != null && raw.isNotEmpty) {
      final parsed = DateTime.tryParse(raw);
      if (parsed != null) return parsed.toLocal();
    }
    final checks = ((host['service_checks'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    DateTime? earliest;
    for (final c in checks) {
      final ts = (c['last_state_change_at'] as String?) ??
          (c['last_checked_at'] as String?);
      if (ts != null && ts.isNotEmpty) {
        final dt = DateTime.tryParse(ts)?.toLocal();
        if (dt != null && (earliest == null || dt.isBefore(earliest))) {
          earliest = dt;
        }
      }
    }
    return earliest;
  }

  String _formatDateTimeShort(DateTime? dt) {
    if (dt == null) return 'Sin registro';
    final dd = dt.day.toString().padLeft(2, '0');
    final mm = dt.month.toString().padLeft(2, '0');
    final yyyy = dt.year;
    final hh = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '$dd/$mm/$yyyy $hh:$min:$ss';
  }

  String _formatDurationElapsed(DateTime? since) {
    if (since == null) return 'Reciente';
    final diff = DateTime.now().difference(since);
    if (diff.isNegative || diff.inSeconds < 60) {
      return 'hace ${math.max(1, diff.inSeconds)}s';
    }
    if (diff.inMinutes < 60) {
      return 'hace ${diff.inMinutes} min';
    }
    if (diff.inHours < 24) {
      final mins = diff.inMinutes % 60;
      return 'hace ${diff.inHours}h ${mins}m';
    }
    final days = diff.inDays;
    final hours = diff.inHours % 24;
    return 'hace ${days}d ${hours}h';
  }

  Widget _buildSreDevicesAlarmStatusTab() {
    final allHosts = _hosts;
    int critCount = 0;
    int warnCount = 0;
    int unreachCount = 0;
    int maintCount = 0;
    int okCount = 0;

    for (final h in allHosts) {
      final st = _effectiveDeviceAlarmState(h);
      if (st == 'CRITICAL') {
        critCount++;
      } else if (st == 'WARNING') {
        warnCount++;
      } else if (st == 'UNREACHABLE') {
        unreachCount++;
      } else if (st == 'MAINTENANCE') {
        maintCount++;
      } else {
        okCount++;
      }
    }
    final inAlarmCount = critCount + warnCount + unreachCount;

    final q = _sreDeviceSearchQuery.trim().toLowerCase();
    final filtered = allHosts.where((h) {
      final st = _effectiveDeviceAlarmState(h);
      if (_sreDeviceStateFilter == 'in_alarm') {
        if (st != 'CRITICAL' && st != 'WARNING' && st != 'UNREACHABLE') {
          return false;
        }
      } else if (_sreDeviceStateFilter != 'all' &&
          st != _sreDeviceStateFilter) {
        return false;
      }

      if (_sreDeviceGroupFilter != 'all') {
        final groups = ((h['host_groups'] as List?) ?? []).cast<String>();
        if (!groups.contains(_sreDeviceGroupFilter)) return false;
      }

      if (_sreDeviceLayerFilter != 'all') {
        if ((h['logical_layer'] as String? ?? '') != _sreDeviceLayerFilter) {
          return false;
        }
      }

      if (_sreDeviceLocationFilter == 'in_rack' && h['rack_id'] == null) {
        return false;
      } else if (_sreDeviceLocationFilter == 'in_floor' &&
          h['floor_id'] == null &&
          h['floor_device_id'] == null) {
        return false;
      } else if (_sreDeviceLocationFilter == 'in_stack' &&
          (((h['stack_links'] as List?) ?? []).isEmpty)) {
        return false;
      } else if (_sreDeviceLocationFilter == 'virtual' &&
          h['rack_device_id'] != null) {
        return false;
      }

      if (q.isNotEmpty) {
        final checks = ((h['service_checks'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        final checkText = checks
            .map(
              (c) =>
                  '${c['service_name'] ?? ''} ${c['status_output'] ?? ''} ${c['target_ip_or_url'] ?? ''}',
            )
            .join(' ');
        final haystack = [
          h['code'],
          h['name'],
          h['hostname'],
          h['fqdn'],
          h['heartbeat_ip'],
          ...((h['all_ips'] as List?) ?? []),
          h['asset_class_label'],
          h['logical_layer_label'],
          h['rack_code'],
          h['rack_name'],
          h['floor_name'],
          h['location_name'],
          h['owner_team'],
          h['responsible_person'],
          ...((h['host_groups'] as List?) ?? []),
          checkText,
        ].where((x) => x != null).join(' ').toLowerCase();
        if (!haystack.contains(q)) return false;
      }
      return true;
    }).toList();

    filtered.sort((a, b) {
      final stA = _effectiveDeviceAlarmState(a);
      final stB = _effectiveDeviceAlarmState(b);
      final dtA = _parseHostStateSince(a);
      final dtB = _parseHostStateSince(b);

      switch (_sreDeviceSortMode) {
        case 'longest_alarm':
          final rA = _alarmPriorityRank(stA) < 3 ? 0 : 1;
          final rB = _alarmPriorityRank(stB) < 3 ? 0 : 1;
          if (rA != rB) return rA.compareTo(rB);
          if (dtA != null && dtB != null) return dtA.compareTo(dtB);
          break;
        case 'recent_change':
          if (dtA != null && dtB != null) return dtB.compareTo(dtA);
          break;
        case 'name_asc':
          return '${a['code'] ?? ''}'.compareTo('${b['code'] ?? ''}');
        case 'latency_desc':
          final lA = (a['last_ping_ms'] as num?)?.toDouble() ?? 0.0;
          final lB = (b['last_ping_ms'] as num?)?.toDouble() ?? 0.0;
          return lB.compareTo(lA);
        case 'alarm_priority':
        default:
          final cmp = _alarmPriorityRank(stA).compareTo(_alarmPriorityRank(stB));
          if (cmp != 0) return cmp;
          if (dtA != null && dtB != null) return dtA.compareTo(dtB);
      }
      return '${a['code'] ?? ''}'.compareTo('${b['code'] ?? ''}');
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Barra de filtros y búsqueda de lado a lado
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
          decoration: const BoxDecoration(
            color: AppTheme.bgSecondary,
            border: Border(bottom: BorderSide(color: AppTheme.border)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Fila 1: Chips rápidos de estado de alarma + buscador + ordenación
              LayoutBuilder(
                builder: (context, constraints) {
                  final filterChips = Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _buildSreAlarmFilterChip(
                        keyValue: 'all',
                        label: 'Todos (${allHosts.length})',
                        color: AppTheme.accentCyan,
                        icon: Icons.apps_rounded,
                      ),
                      _buildSreAlarmFilterChip(
                        keyValue: 'in_alarm',
                        label: 'En Alarma ($inAlarmCount)',
                        color: AppTheme.error,
                        icon: Icons.crisis_alert_rounded,
                      ),
                      _buildSreAlarmFilterChip(
                        keyValue: 'CRITICAL',
                        label: 'Crítico / DOWN ($critCount)',
                        color: AppTheme.error,
                        icon: Icons.gpp_bad_rounded,
                      ),
                      _buildSreAlarmFilterChip(
                        keyValue: 'WARNING',
                        label: 'Warning ($warnCount)',
                        color: AppTheme.warning,
                        icon: Icons.warning_amber_rounded,
                      ),
                      _buildSreAlarmFilterChip(
                        keyValue: 'UNREACHABLE',
                        label: 'Unreachable ($unreachCount)',
                        color: AppTheme.accentPurple,
                        icon: Icons.account_tree_outlined,
                      ),
                      _buildSreAlarmFilterChip(
                        keyValue: 'MAINTENANCE',
                        label: 'Mantenimiento ($maintCount)',
                        color: AppTheme.accentBlue,
                        icon: Icons.build_circle_rounded,
                      ),
                      _buildSreAlarmFilterChip(
                        keyValue: 'OK',
                        label: 'OK / Online ($okCount)',
                        color: AppTheme.success,
                        icon: Icons.check_circle_rounded,
                      ),
                    ],
                  );

                  return filterChips;
                },
              ),
              const SizedBox(height: 8),
              // Fila 2: Buscador + Selectores de Grupo de Host, Capa, Ubicación y Orden
              Wrap(
                spacing: 10,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 340,
                    height: 34,
                    child: TextField(
                      onChanged: (v) =>
                          _rebuildState(() => _sreDeviceSearchQuery = v),
                      style: const TextStyle(fontSize: 12),
                      decoration: InputDecoration(
                        hintText:
                            'Buscar por host, IP, servicio en fallo, rack, planta, grupo...',
                        hintStyle: const TextStyle(fontSize: 11.5),
                        prefixIcon: const Icon(Icons.search_rounded, size: 16),
                        suffixIcon: _sreDeviceSearchQuery.isNotEmpty
                            ? IconButton(
                                padding: EdgeInsets.zero,
                                icon: const Icon(Icons.clear, size: 14),
                                onPressed: () => _rebuildState(
                                  () => _sreDeviceSearchQuery = '',
                                ),
                              )
                            : null,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 0,
                        ),
                      ),
                    ),
                  ),
                  _buildSreCompactDropdown(
                    label: 'Grupo Host',
                    value: _sreDeviceGroupFilter,
                    items: {
                      'all': 'Todos los HostGroups',
                      for (final hg in _hostGroups)
                        '${hg['code']}': '${hg['name']} (${hg['code']})',
                    },
                    onChanged: (v) =>
                        _rebuildState(() => _sreDeviceGroupFilter = v ?? 'all'),
                  ),
                  _buildSreCompactDropdown(
                    label: 'Capa / Tipo',
                    value: _sreDeviceLayerFilter,
                    items: const {
                      'all': 'Todas las Capas',
                      'edge_security': 'Seguridad / Perímetro',
                      'network_switching': 'Switching / Red',
                      'hypervisors_phys': 'Servidores Físicos / Hipervisores',
                      'vms_containers': 'VMs / Contenedores',
                      'services_apps': 'BBDD / Middleware / Apps',
                    },
                    onChanged: (v) =>
                        _rebuildState(() => _sreDeviceLayerFilter = v ?? 'all'),
                  ),
                  _buildSreCompactDropdown(
                    label: 'Ubicación',
                    value: _sreDeviceLocationFilter,
                    items: const {
                      'all': 'Cualquier Ubicación',
                      'in_rack': 'Alojados en Rack (3)',
                      'in_floor': 'En Planta Datacenter (2)',
                      'in_stack': 'En Stack Tecnológico (4)',
                      'virtual': 'Virtuales / Cloud',
                    },
                    onChanged: (v) =>
                        _rebuildState(() => _sreDeviceLocationFilter = v ?? 'all'),
                  ),
                  _buildSreCompactDropdown(
                    label: 'Ordenar por',
                    value: _sreDeviceSortMode,
                    items: const {
                      'alarm_priority': 'Prioridad Alarma (Críticos 1º)',
                      'longest_alarm': 'Más tiempo en alarma',
                      'recent_change': 'Cambio de estado más reciente',
                      'name_asc': 'Código / Nombre (A-Z)',
                      'latency_desc': 'Mayor Latencia (ms)',
                    },
                    onChanged: (v) => _rebuildState(
                      () => _sreDeviceSortMode = v ?? 'alarm_priority',
                    ),
                  ),
                  Text(
                    'Mostrando ${filtered.length} de ${allHosts.length} dispositivos',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        // Cabecera de columnas de la tabla adaptativa
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          decoration: BoxDecoration(
            color: AppTheme.bgPrimary.withValues(alpha: 0.7),
            border: const Border(bottom: BorderSide(color: AppTheme.border)),
          ),
          child: const Row(
            children: [
              SizedBox(
                width: 132,
                child: Text(
                  'ESTADO ACTUAL',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textSecondary,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              Expanded(
                flex: 24,
                child: Text(
                  'DISPOSITIVO / IP / TIPO & UBICACIÓN',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textSecondary,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              Expanded(
                flex: 18,
                child: Text(
                  '¿DESDE CUÁNDO EN ALARMA? / DURACIÓN',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textSecondary,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              Expanded(
                flex: 28,
                child: Text(
                  'CHEQUEOS ACTIVOS, DIAGNÓSTICO & GUARDIA',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textSecondary,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              Expanded(
                flex: 30,
                child: Text(
                  'IR AL DASHBOARD DONDE ESTÁ CONFIGURADO',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textSecondary,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
        ),
        // Lista de dispositivos con enlaces al final de cada línea
        Expanded(
          child: filtered.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.verified_rounded,
                        size: 42,
                        color: AppTheme.success,
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'No hay dispositivos que coincidan con el filtro seleccionado.',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: () => _rebuildState(() {
                          _sreDeviceStateFilter = 'all';
                          _sreDeviceGroupFilter = 'all';
                          _sreDeviceLayerFilter = 'all';
                          _sreDeviceLocationFilter = 'all';
                          _sreDeviceSearchQuery = '';
                        }),
                        icon: const Icon(Icons.filter_alt_off_rounded, size: 15),
                        label: const Text('Limpiar filtros'),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 18),
                  itemCount: filtered.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    return _buildSreDeviceAlarmRowCard(filtered[index]);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildSreAlarmFilterChip({
    required String keyValue,
    required String label,
    required Color color,
    required IconData icon,
  }) {
    final active = _sreDeviceStateFilter == keyValue;
    return InkWell(
      onTap: () => _rebuildState(() => _sreDeviceStateFilter = keyValue),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? color.withValues(alpha: 0.22)
              : color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? color : color.withValues(alpha: 0.30),
            width: active ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.2,
                fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                color: active ? AppTheme.textPrimary : AppTheme.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSreCompactDropdown({
    required String label,
    required String value,
    required Map<String, String> items,
    required ValueChanged<String?> onChanged,
  }) {
    final safeVal = items.containsKey(value) ? value : items.keys.first;
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: AppTheme.bgPrimary,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.border),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: safeVal,
          isDense: true,
          style: const TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
          ),
          dropdownColor: AppTheme.bgSecondary,
          items: items.entries
              .map(
                (e) => DropdownMenuItem<String>(
                  value: e.key,
                  child: Text('$label: ${e.value}'),
                ),
              )
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildSreDeviceAlarmRowCard(Map<String, dynamic> host) {
    final hostId = host['id'] as int;
    final alarmState = _effectiveDeviceAlarmState(host);
    final hostNagiosState =
        (host['nagios_host_state'] as String? ?? 'UP').toUpperCase();
    final isAlarm = alarmState == 'CRITICAL' ||
        alarmState == 'WARNING' ||
        alarmState == 'UNREACHABLE';
    final stateColor = _nagiosStateColor(alarmState);

    final sinceDt = _parseHostStateSince(host);
    final sinceFormatted = _formatDateTimeShort(sinceDt);
    final elapsedFormatted = _formatDurationElapsed(sinceDt);

    final checks = ((host['service_checks'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final failingChecks = checks
        .where(
          (c) =>
              (c['nagios_state'] as String? ?? '').toUpperCase() ==
                  'CRITICAL' ||
              (c['nagios_state'] as String? ?? '').toUpperCase() == 'WARNING',
        )
        .toList();

    final hostGroupCodes =
        ((host['host_groups'] as List?) ?? []).cast<String>();

    // Resolver grupos de usuarios/guardia asignados a este host o a sus HostGroups
    final assignedUserGroups = <String>{};
    for (final r in _notificationRules) {
      final rAssetId = r['asset_id'] as int?;
      final rHgCode = r['host_group_code'] as String?;
      if (rAssetId == hostId ||
          (rHgCode != null && hostGroupCodes.contains(rHgCode))) {
        for (final g in ((r['contact_groups'] as List?) ?? [])) {
          final gm = Map<String, dynamic>.from(g as Map);
          assignedUserGroups.add('${gm['name'] ?? gm['code']}');
        }
        for (final c in ((r['contacts'] as List?) ?? [])) {
          final cm = Map<String, dynamic>.from(c as Map);
          assignedUserGroups.add('👤 ${cm['full_name'] ?? cm['code']}');
        }
      }
    }

    final int? locationId = host['location_id'] as int?;
    final String locationCode = (host['location_code'] as String? ?? '').trim();
    final int? floorId = host['floor_id'] as int?;
    final String floorName = (host['floor_name'] as String? ?? '').trim();
    final int? floorDeviceId = host['floor_device_id'] as int?;
    final int? rackId = host['rack_id'] as int?;
    final String rackCode = (host['rack_code'] as String? ?? '').trim();
    final int? targetRackDeviceId =
        (host['target_rack_device_id'] as int?) ??
        (host['rack_device_id'] as int?) ??
        (host['host_rack_device_id'] as int?);
    final stackLinks = ((host['stack_links'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final firstStack = stackLinks.isNotEmpty ? stackLinks.first : null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isAlarm
            ? stateColor.withValues(alpha: 0.06)
            : AppTheme.bgSecondary,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isAlarm
              ? stateColor.withValues(alpha: 0.55)
              : AppTheme.border,
          width: isAlarm ? 1.4 : 1.0,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 1. ESTADO ACTUAL
          SizedBox(
            width: 132,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: stateColor.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(7),
                    border: Border.all(color: stateColor.withValues(alpha: 0.6)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        alarmState == 'CRITICAL'
                            ? Icons.gpp_bad_rounded
                            : (alarmState == 'WARNING'
                                  ? Icons.warning_amber_rounded
                                  : (alarmState == 'UNREACHABLE'
                                        ? Icons.account_tree_outlined
                                        : (alarmState == 'MAINTENANCE'
                                              ? Icons.build_circle_rounded
                                              : Icons.check_circle_rounded))),
                        size: 14,
                        color: stateColor,
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          alarmState == 'CRITICAL' && hostNagiosState == 'DOWN'
                              ? 'HOST DOWN'
                              : alarmState,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            color: stateColor,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Host: $hostNagiosState • ${checks.length} chks',
                  style: const TextStyle(
                    fontSize: 10,
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),

          // 2. DISPOSITIVO / IP / UBICACIÓN
          Expanded(
            flex: 24,
            child: Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(
                        _layerIcon(host['logical_layer'] as String? ?? ''),
                        size: 15,
                        color: AppTheme.accentCyan,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${host['code']} — ${host['name']}',
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: AppTheme.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Wrap(
                    spacing: 6,
                    runSpacing: 3,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        'IP: ${(host['heartbeat_ip'] as String?)?.isNotEmpty == true ? host['heartbeat_ip'] : 'Sin IP'}',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.accentCyan,
                        ),
                      ),
                      Text(
                        '• ${host['asset_class_label'] ?? host['asset_class'] ?? ''}',
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                      if ((host['rack_location_badge'] as String?)?.isNotEmpty ==
                          true)
                        Text(
                          '• ${host['rack_location_badge']}',
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // 3. ¿DESDE CUÁNDO ESTÁ EN ALARMA? / TIEMPO TRANSCURRIDO
          Expanded(
            flex: 18,
            child: Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Icon(
                        isAlarm
                            ? Icons.timer_outlined
                            : Icons.history_toggle_off_rounded,
                        size: 14,
                        color: isAlarm ? stateColor : AppTheme.textSecondary,
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          isAlarm
                              ? 'En alarma $elapsedFormatted'
                              : (alarmState == 'MAINTENANCE'
                                    ? 'En mant. $elapsedFormatted'
                                    : 'Estable ($elapsedFormatted)'),
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                            color: isAlarm ? stateColor : AppTheme.textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Desde: $sinceFormatted',
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: AppTheme.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ),

          // 4. CHEQUEOS EN FALLO / MÉTRICAS / GUARDIA ASIGNADA
          Expanded(
            flex: 28,
            child: Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (failingChecks.isNotEmpty)
                    ...failingChecks.take(2).map(
                      (chk) => Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: Text(
                          '⚠️ ${chk['service_name']}: ${chk['status_output'] ?? chk['nagios_state']}',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: _nagiosStateColor(
                              '${chk['nagios_state'] ?? 'WARNING'}',
                            ),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                  else
                    Text(
                      checks.isNotEmpty
                          ? '✓ ${checks.first['service_name']}: ${checks.first['status_output'] ?? 'OK'}'
                          : '✓ Ping: ${host['last_ping_ms'] ?? 1.0} ms • CPU: ${host['cpu_pct'] ?? 0}%',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.textSecondary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  const SizedBox(height: 3),
                  Wrap(
                    spacing: 6,
                    runSpacing: 3,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (assignedUserGroups.isNotEmpty)
                        Text(
                          'Guardia: ${assignedUserGroups.take(2).join(', ')}',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.accentTeal,
                          ),
                        )
                      else
                        const Text(
                          'Sin guardia asignada',
                          style: TextStyle(
                            fontSize: 10,
                            color: AppTheme.textMuted,
                          ),
                        ),
                      InkWell(
                        onTap: () {
                          if (hostGroupCodes.isNotEmpty) {
                            final hg = _hostGroups
                                .where((g) => g['code'] == hostGroupCodes.first)
                                .firstOrNull;
                            if (hg != null) {
                              _rebuildState(
                                () => _selectedAlertHostGroupId =
                                    hg['id'] as int,
                              );
                            }
                          }
                          _tabController.animateTo(1);
                        },
                        child: const Text(
                          '[Configurar Aviso]',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            color: AppTheme.accentCyan,
                            decoration: TextDecoration.underline,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // 5. AL FINAL DE LA LÍNEA: ENLACES DIRECTOS A TODAS LAS DASHBOARDS DONDE ESTÁ CONFIGURADO
          Expanded(
            flex: 30,
            child: Wrap(
              spacing: 5,
              runSpacing: 5,
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (locationId != null && widget.onNavigateToLocation != null)
                  _buildDashboardJumpChip(
                    icon: Icons.public_rounded,
                    label:
                        '1. Mapa${locationCode.isNotEmpty ? ' ($locationCode)' : ''}',
                    color: AppTheme.accentBlue,
                    tooltip:
                        'Abrir sede ${host['location_name'] ?? locationCode} en 1. Mapa Global',
                    onTap: () => widget.onNavigateToLocation!(locationId),
                  ),
                if ((floorId != null || floorDeviceId != null) &&
                    widget.onNavigateToFloorDevice != null)
                  _buildDashboardJumpChip(
                    icon: Icons.grid_view_rounded,
                    label:
                        '2. Planta${floorName.isNotEmpty ? ' ($floorName)' : ''}',
                    color: AppTheme.accentTeal,
                    tooltip: 'Abrir en 2. Planta Datacenter',
                    onTap: () => widget.onNavigateToFloorDevice!(
                      locationId,
                      floorId,
                      floorDeviceId,
                    ),
                  ),
                if (rackId != null && widget.onNavigateToRackDevice != null)
                  _buildDashboardJumpChip(
                    icon: Icons.dns_rounded,
                    label:
                        '3. Rack ${rackCode.isNotEmpty ? rackCode : '#$rackId'}${host['start_u'] != null ? ' (U${host['start_u']})' : ''}',
                    color: AppTheme.accentCyan,
                    tooltip:
                        'Abrir en 3. Rack Editor (42U) y resaltar este dispositivo',
                    onTap: () => widget.onNavigateToRackDevice!(
                      rackId,
                      targetRackDeviceId,
                    ),
                  ),
                if (widget.onNavigateToNetworkHost != null)
                  _buildDashboardJumpChip(
                    icon: Icons.account_tree_rounded,
                    label: firstStack != null
                        ? '4. Red & Host (${firstStack['stack_code'] ?? 'Stack'})'
                        : '4. Red & Host',
                    color: AppTheme.accentPurple,
                    tooltip: 'Abrir topología y telemetría en 4. Red & Host',
                    onTap: () => widget.onNavigateToNetworkHost!(
                      hostId,
                      firstStack?['stack_id'] as int?,
                      firstStack?['node_id'] as int?,
                    ),
                  ),
                if (rackId != null && widget.onNavigateToDashboard != null)
                  _buildDashboardJumpChip(
                    icon: Icons.dashboard_outlined,
                    label: '5. Dashboard',
                    color: AppTheme.warning,
                    tooltip: 'Ver inventario de su Rack en 5. Dashboard & Excel',
                    onTap: () => widget.onNavigateToDashboard!(rackId),
                  ),
                if (widget.onNavigateToCmdb != null)
                  _buildDashboardJumpChip(
                    icon: Icons.hub_rounded,
                    label: '6. CMDB',
                    color: AppTheme.accentBlue,
                    tooltip: 'Abrir ficha en 6. CMDB & Control IPs',
                    onTap: () =>
                        widget.onNavigateToCmdb!('${host['code'] ?? ''}'),
                  ),
                if (widget.onNavigateToCertScope != null)
                  _buildDashboardJumpChip(
                    icon: Icons.verified_user_rounded,
                    label: '7. CertScope',
                    color: AppTheme.success,
                    tooltip: 'Auditar certificados SSL/TLS en 7. CertScope',
                    onTap: () => widget.onNavigateToCertScope!(
                      '${host['heartbeat_ip'] ?? host['code'] ?? ''}',
                    ),
                  ),
                Tooltip(
                  message: 'Ejecutar chequeo inmediato de este dispositivo',
                  child: InkWell(
                    onTap: () async {
                      Map<String, dynamic>? lastRes;
                      if (checks.isNotEmpty) {
                        for (final c in checks) {
                          final cid = c['id'] as int?;
                          if (cid != null) {
                            lastRes = await widget.api
                                .runSingleNetworkServiceCheck(cid);
                          }
                        }
                      } else {
                        lastRes = await widget.api.runAllNetworkServiceChecks();
                      }
                      if (!mounted) return;
                      if (lastRes != null && lastRes['overview'] is Map) {
                        _rebuildState(() {
                          _overview = Map<String, dynamic>.from(
                            lastRes!['overview'] as Map,
                          );
                        });
                      } else {
                        await _loadOverview(silent: true);
                      }
                      _showSnack(
                        'Dispositivo ${host['code']} evaluado en vivo.',
                      );
                    },
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.bgPrimary,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: AppTheme.border),
                      ),
                      child: const Icon(
                        Icons.bolt_rounded,
                        size: 14,
                        color: AppTheme.warning,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDashboardJumpChip({
    required IconData icon,
    required String label,
    required Color color,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color.withValues(alpha: 0.45)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: color),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.2,
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.open_in_new_rounded, size: 10, color: color),
            ],
          ),
        ),
      ),
    );
  }
}
