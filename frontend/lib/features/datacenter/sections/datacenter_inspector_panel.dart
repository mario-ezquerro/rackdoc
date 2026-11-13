part of '../datacenter_floor_view.dart';

/// Panel derecho de propiedades e inspector técnico de dispositivos de planta,
/// sensores, tomas de red y resumen del rack seleccionado.
extension _DatacenterInspectorPanelExt on _DatacenterFloorViewState {
  Widget _buildFloorDeviceSettingsForm(
    FloorDeviceNode dev,
    List<RackSummary> floorRacks,
    List<FloorDeviceNode> floorOutlets,
  ) {
    final validRackIds = <int>{for (final r in floorRacks) r.id};
    final safeLinkedRackId =
        (_devLinkedRackId != null && validRackIds.contains(_devLinkedRackId))
            ? _devLinkedRackId
            : null;

    final validOutletIds = <int>{
      for (final o in floorOutlets)
        if (o.id != dev.id) o.id,
    };
    final safeLinkedOutletId = (_devLinkedOutletId != null &&
            validOutletIds.contains(_devLinkedOutletId))
        ? _devLinkedOutletId
        : null;

    final validCategories = <String>{
      for (final c in _allCatalogItems)
        if (c.category != 'rack') c.category,
    };
    final safeCategory = validCategories.contains(_devCategory)
        ? _devCategory
        : 'camera';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Settings',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: AppPalette.blue600,
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  key: ValueKey('cat_${dev.id}_$safeCategory'),
                  initialValue: safeCategory,
                  isExpanded: true,
                  isDense: true,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppPalette.slate900,
                  ),
                  decoration: _compactInputDecoration('Device / Sensor Type'),
                  items: _allCatalogItems
                      .where((c) => c.category != 'rack')
                      .map(
                        (c) => DropdownMenuItem<String>(
                          value: c.category,
                          child: Row(
                            children: [
                              Icon(c.icon, size: 15, color: c.pinColor),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  c.label,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v != null && v != _devCategory) {
                      _rebuildState(() => _devCategory = v);
                      _saveSelectedFloorDeviceSettings(
                        customToast:
                            '✓ Tipo cambiado a "${_catalogItemFor(v).label}".',
                      );
                    }
                  },
                ),
                const SizedBox(height: 8),
                _buildCompactField(label: 'ID *', controller: _devCodeCtrl),
                const SizedBox(height: 8),
                _buildCompactField(label: 'Name', controller: _devNameCtrl),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _buildCompactField(
                        label: 'Room / Zone (GOA, OSLO)',
                        controller: _devRoomCodeCtrl,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildCompactField(
                        label: 'VLAN',
                        controller: _devVlanCtrl,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _buildCompactField(
                  label: 'IP Address / Host',
                  controller: _devIpCtrl,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _buildCompactField(
                        label: 'Marca / Modelo',
                        controller: _devModelCtrl,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildCompactField(
                        label: 'Número de Serie (S/N)',
                        controller: _devSerialCtrl,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: dev.cmdbAssetId != null
                        ? const Color(0xFFF0FDF4)
                        : const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: dev.cmdbAssetId != null
                          ? const Color(0xFF86EFAC)
                          : AppPalette.blue300,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.fact_check_outlined,
                            size: 14,
                            color: dev.cmdbAssetId != null
                                ? const Color(0xFF15803D)
                                : AppPalette.blue700,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              dev.cmdbAssetId != null
                                  ? 'Alineado con CMDB: ${dev.cmdbAssetCode}'
                                  : 'Alineación CMDB & Control IPs',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w900,
                                color: dev.cmdbAssetId != null
                                    ? const Color(0xFF166534)
                                    : AppPalette.blue900,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          backgroundColor: Colors.white,
                          foregroundColor: AppPalette.blue900,
                          side: const BorderSide(color: AppPalette.blue300),
                        ),
                        onPressed: () => _showLinkExistingFloorDeviceWithCmdbDialog(dev),
                        icon: const Icon(Icons.sync_alt_rounded, size: 14),
                        label: Text(
                          dev.cmdbAssetId != null
                              ? 'Cambiar / Autocompletar desde CMDB'
                              : 'Seleccionar equipo detectado en CMDB',
                          style: const TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),

                // =============================================================
                // SECCIÓN A: HEARTBEAT (Background Monitoring)
                // - Desactivado por defecto (Gris). Si está desactivado, sólo
                //   muestra el switch para activar/desactivar.
                // - Si se activa, permite elegir 1 o varios sistemas + botón
                //   "Probar ahora" (ejecutado en el Backend).
                // =============================================================
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _fdMonitorEnabled
                        ? (_devStatus == 'offline'
                            ? AppPalette.red50
                            : (_devStatus == 'warning'
                                ? AppPalette.amber50
                                : AppPalette.green50))
                        : AppPalette.slate50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _fdMonitorEnabled
                          ? (_devStatus == 'offline'
                              ? AppPalette.red300
                              : (_devStatus == 'warning'
                                  ? AppPalette.amber300
                                  : AppPalette.green300))
                          : AppPalette.slate300,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: !_fdMonitorEnabled
                                  ? AppPalette.slate400
                                  : (_devStatus == 'online'
                                      ? AppPalette.green600
                                      : (_devStatus == 'warning'
                                          ? AppPalette.amber600
                                          : AppPalette.red600)),
                            ),
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _fdMonitorEnabled
                                      ? 'Heartbeat: ACTIVO (${_devStatus == 'online' ? 'Verde • OK' : (_devStatus == 'warning' ? 'Naranja • Parcial' : 'Rojo • Fallo')})'
                                      : 'Heartbeat: DESACTIVADO (Gris)',
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w900,
                                    color: AppPalette.slate900,
                                  ),
                                ),
                                Text(
                                  _fdMonitorEnabled
                                      ? 'Comprobación periódica desde el Background'
                                      : 'Sin chequeo automático de estado',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: AppPalette.slate500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch.adaptive(
                            value: _fdMonitorEnabled,
                            activeTrackColor: AppPalette.green600,
                            onChanged: (v) =>
                                _toggleFloorDeviceHeartbeat(dev, v),
                          ),
                        ],
                      ),
                      if (_fdMonitorEnabled) ...[
                        const Divider(height: 14, color: AppPalette.slate300),
                        const Text(
                          'Sistemas de chequeo activos (elige uno o varios):',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            color: AppPalette.slate700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 5,
                          runSpacing: 5,
                          children: [
                            for (final entry in const [
                              ('icmp', 'ICMP Ping'),
                              ('ssh', 'SSH'),
                              ('http', 'HTTP / HTTPS'),
                              ('tcp', 'TCP'),
                              ('udp', 'UDP'),
                              ('snmp', 'SNMP'),
                            ])
                              FilterChip(
                                label: Text(
                                  entry.$2,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w800,
                                    color: _fdEnabledMonitorSystems
                                            .contains(entry.$1)
                                        ? Colors.white
                                        : AppPalette.slate800,
                                  ),
                                ),
                                selected: _fdEnabledMonitorSystems
                                    .contains(entry.$1),
                                selectedColor: AppPalette.slate900,
                                checkmarkColor: const Color(0xFF4ADE80),
                                backgroundColor: Colors.white,
                                visualDensity: VisualDensity.compact,
                                onSelected: (sel) {
                                  _rebuildState(() {
                                    if (sel) {
                                      _fdEnabledMonitorSystems.add(entry.$1);
                                    } else if (_fdEnabledMonitorSystems.length >
                                        1) {
                                      _fdEnabledMonitorSystems.remove(entry.$1);
                                    }
                                  });
                                },
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (_fdEnabledMonitorSystems.contains('icmp')) ...[
                          Row(
                            children: [
                              Expanded(
                                flex: 2,
                                child: _buildCompactField(
                                  label: 'ICMP Host / IP',
                                  controller: _fdPingTargetCtrl,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: _buildCompactField(
                                  label: 'Timeout (s)',
                                  controller: _fdPingTimeoutCtrl,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                        ],
                        if (_fdEnabledMonitorSystems.contains('ssh')) ...[
                          Row(
                            children: [
                              Expanded(
                                flex: 2,
                                child: _buildCompactField(
                                  label: 'SSH Host / IP (HB)',
                                  controller: _fdSshHbHostCtrl,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: _buildCompactField(
                                  label: 'Puerto SSH',
                                  controller: _fdSshHbPortCtrl,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                        ],
                        if (_fdEnabledMonitorSystems.contains('http')) ...[
                          Row(
                            children: [
                              Expanded(
                                flex: 2,
                                child: _buildCompactField(
                                  label: 'URL HTTP/HTTPS (HB)',
                                  controller: _fdHttpHbUrlCtrl,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: _buildCompactField(
                                  label: 'Cód. HTTP',
                                  controller: _fdHttpHbExpectedCodeCtrl,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                        ],
                        if (_fdEnabledMonitorSystems.contains('tcp')) ...[
                          Row(
                            children: [
                              Expanded(
                                flex: 2,
                                child: _buildCompactField(
                                  label: 'TCP Host / IP',
                                  controller: _fdTcpHbHostCtrl,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: _buildCompactField(
                                  label: 'Puerto TCP',
                                  controller: _fdTcpHbPortCtrl,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                        ],
                        if (_fdEnabledMonitorSystems.contains('udp')) ...[
                          Row(
                            children: [
                              Expanded(
                                flex: 2,
                                child: _buildCompactField(
                                  label: 'UDP Host / IP',
                                  controller: _fdUdpHbHostCtrl,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: _buildCompactField(
                                  label: 'Puerto UDP',
                                  controller: _fdUdpHbPortCtrl,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                        ],
                        if (_fdEnabledMonitorSystems.contains('snmp')) ...[
                          Row(
                            children: [
                              Expanded(
                                flex: 2,
                                child: _buildCompactField(
                                  label: 'SNMP Host / IP',
                                  controller: _fdSnmpHbHostCtrl,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: _buildCompactField(
                                  label: 'Comunidad',
                                  controller: _fdSnmpHbCommunityCtrl,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                        ],
                        if (_fdLastPingResult != null &&
                            _fdLastPingResult!['protocol_results'] is List) ...[
                          const SizedBox(height: 4),
                          for (final pr
                              in (_fdLastPingResult!['protocol_results']
                                  as List))
                            if (pr is Map)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 3),
                                child: Row(
                                  children: [
                                    Icon(
                                      pr['status'] == 'online'
                                          ? Icons.check_circle_rounded
                                          : Icons.cancel_rounded,
                                      size: 13,
                                      color: pr['status'] == 'online'
                                          ? AppPalette.green600
                                          : AppPalette.red600,
                                    ),
                                    const SizedBox(width: 5),
                                    Expanded(
                                      child: Text(
                                        '${(pr['protocol'] ?? '').toString().toUpperCase()} (${pr['target'] ?? ''}): ${pr['detail'] ?? ''}',
                                        style: const TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          color: AppPalette.slate800,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                        ],
                        const SizedBox(height: 6),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _fdPinging
                                ? null
                                : () => _testFloorDeviceHeartbeatNow(dev),
                            icon: _fdPinging
                                ? const SizedBox(
                                    width: 13,
                                    height: 13,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(
                                    Icons.bolt_rounded,
                                    size: 15,
                                  ),
                            label: Text(
                              _fdPinging
                                  ? 'Comprobando en Background...'
                                  : 'Probar ahora',
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppPalette.slate900,
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 10),

                // =============================================================
                // SECCIÓN B: CONECTAR (Ejecutado desde el Frontend)
                // - Independiente de las URLs/IPs del Heartbeat.
                // - Si está desactivado, sólo muestra el switch para activar.
                // - Si se activa, permite elegir SSH, HTTP y/o HTTPS y lanzar
                //   la conexión directamente desde el navegador/cliente.
                // =============================================================
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _fdConnectEnabled
                        ? AppPalette.blue50
                        : AppPalette.slate50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _fdConnectEnabled
                          ? AppPalette.blue300
                          : AppPalette.slate300,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.open_in_new_rounded,
                            size: 15,
                            color: _fdConnectEnabled
                                ? AppPalette.blue600
                                : AppPalette.slate500,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _fdConnectEnabled
                                      ? 'Conectar: ACTIVO (Frontend)'
                                      : 'Conectar: DESACTIVADO',
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w900,
                                    color: AppPalette.slate900,
                                  ),
                                ),
                                const Text(
                                  'Acceso directo SSH / HTTP / HTTPS desde el navegador',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: AppPalette.slate500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch.adaptive(
                            value: _fdConnectEnabled,
                            activeTrackColor: AppPalette.blue600,
                            onChanged: (v) {
                              _rebuildState(() {
                                _fdConnectEnabled = v;
                                if (v && _fdEnabledConnectSystems.isEmpty) {
                                  _fdEnabledConnectSystems = {'https'};
                                }
                              });
                              _saveSelectedFloorDeviceSettings(
                                customToast: v
                                    ? '✓ Panel Conectar activado en "${dev.code}".'
                                    : '✓ Panel Conectar desactivado en "${dev.code}".',
                              );
                            },
                          ),
                        ],
                      ),
                      if (_fdConnectEnabled) ...[
                        const Divider(height: 14, color: Color(0xFFBFDBFE)),
                        Wrap(
                          spacing: 6,
                          runSpacing: 5,
                          children: [
                            for (final entry in const [
                              ('ssh', 'SSH'),
                              ('http', 'HTTP'),
                              ('https', 'HTTPS'),
                            ])
                              FilterChip(
                                label: Text(
                                  entry.$2,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w800,
                                    color: _fdEnabledConnectSystems
                                            .contains(entry.$1)
                                        ? Colors.white
                                        : AppPalette.blue900,
                                  ),
                                ),
                                selected: _fdEnabledConnectSystems
                                    .contains(entry.$1),
                                selectedColor: AppPalette.blue600,
                                checkmarkColor: Colors.white,
                                backgroundColor: Colors.white,
                                visualDensity: VisualDensity.compact,
                                onSelected: (sel) {
                                  _rebuildState(() {
                                    if (sel) {
                                      _fdEnabledConnectSystems.add(entry.$1);
                                    } else if (_fdEnabledConnectSystems.length >
                                        1) {
                                      _fdEnabledConnectSystems.remove(entry.$1);
                                    }
                                  });
                                },
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        if (_fdEnabledConnectSystems.contains('ssh')) ...[
                          Row(
                            children: [
                              Expanded(
                                flex: 2,
                                child: _buildCompactField(
                                  label: 'SSH Host / IP',
                                  controller: _fdConnSshHostCtrl,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: _buildCompactField(
                                  label: 'Puerto',
                                  controller: _fdConnSshPortCtrl,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: _buildCompactField(
                                  label: 'Usuario',
                                  controller: _fdConnSshUserCtrl,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 5),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: () => _launchFloorDeviceConnect('ssh'),
                              icon: const Icon(Icons.terminal_rounded, size: 14),
                              label: const Text(
                                'Conectar por SSH',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppPalette.slate900,
                                backgroundColor: Colors.white,
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                        if (_fdEnabledConnectSystems.contains('http')) ...[
                          _buildCompactField(
                            label: 'URL HTTP (independiente de Heartbeat)',
                            controller: _fdConnHttpUrlCtrl,
                          ),
                          const SizedBox(height: 5),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              onPressed: () =>
                                  _launchFloorDeviceConnect('http'),
                              icon: const Icon(Icons.http_rounded, size: 15),
                              label: const Text(
                                'Conectar por HTTP',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppPalette.blue700,
                                backgroundColor: Colors.white,
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                        ],
                        if (_fdEnabledConnectSystems.contains('https')) ...[
                          _buildCompactField(
                            label: 'URL HTTPS (independiente de Heartbeat)',
                            controller: _fdConnHttpsUrlCtrl,
                          ),
                          const SizedBox(height: 5),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: () =>
                                  _launchFloorDeviceConnect('https'),
                              icon: const Icon(Icons.lock_outline, size: 14),
                              label: const Text(
                                'Conectar por HTTPS',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                              style: FilledButton.styleFrom(
                                backgroundColor: AppPalette.blue600,
                                visualDensity: VisualDensity.compact,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // =============================================================
                // SECCIÓN C (3ª GESTIÓN): CERTSCOPE — VERIFICACIÓN CERTIFICADO HTTPS/TLS
                // =============================================================
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _fdCertScopeEnabled
                        ? const Color(0xFFF5F3FF)
                        : AppPalette.slate100,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _fdCertScopeEnabled
                          ? AppPalette.violet600
                          : AppPalette.slate300,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.verified_user_rounded,
                            size: 15,
                            color: _fdCertScopeEnabled
                                ? AppPalette.violet600
                                : AppPalette.slate500,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '3. CERTSCOPE — VERIFICACIÓN HTTPS/TLS',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w900,
                                    color: _fdCertScopeEnabled
                                        ? AppPalette.slate900
                                        : AppPalette.slate600,
                                  ),
                                ),
                                Text(
                                  _fdCertScopeEnabled
                                      ? 'Analiza caducidad X.509 y vincula este equipo en 7. CertScope'
                                      : 'Desactivado (no se verifica certificado HTTPS)',
                                  style: const TextStyle(
                                    fontSize: 9.5,
                                    color: AppPalette.slate600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Switch.adaptive(
                            value: _fdCertScopeEnabled,
                            activeThumbColor: AppPalette.violet600,
                            onChanged: (v) async {
                              _rebuildState(() => _fdCertScopeEnabled = v);
                              await _saveSelectedFloorDeviceSettings(
                                customToast: v
                                    ? '🔒 CertScope activado y sincronizado para "${dev.code}".'
                                    : '⚪ CertScope desactivado para "${dev.code}".',
                              );
                            },
                          ),
                        ],
                      ),
                      if (_fdCertScopeEnabled) ...[
                        const SizedBox(height: 6),
                        _buildCompactField(
                          label: 'URL / Host HTTPS a verificar en CertScope',
                          controller: _fdCertScopeUrlCtrl,
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            SizedBox(
                              width: 90,
                              child: _buildCompactField(
                                label: 'Puerto TLS',
                                controller: _fdCertScopePortCtrl,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                initialValue: _fdCertScopeRenewalType,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: 'Renovación Certificado',
                                  isDense: true,
                                  filled: true,
                                  fillColor: Colors.white,
                                  contentPadding: EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 8,
                                  ),
                                  border: OutlineInputBorder(),
                                ),
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: AppPalette.slate900,
                                  fontWeight: FontWeight.w700,
                                ),
                                items: const [
                                  DropdownMenuItem(
                                    value: 'manual',
                                    child: Text('🔔 Manual (Avisar)'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'auto_acme',
                                    child: Text('🤖 Automática ACME'),
                                  ),
                                ],
                                onChanged: (v) {
                                  if (v != null) {
                                    _rebuildState(() => _fdCertScopeRenewalType = v);
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _fdProbingCertScope
                                ? null
                                : () => _probeFloorDeviceCertScopeNow(dev),
                            icon: _fdProbingCertScope
                                ? const SizedBox(
                                    width: 13,
                                    height: 13,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.sync_lock_rounded, size: 14),
                            label: Text(
                              _fdProbingCertScope
                                  ? 'Analizando Certificado HTTPS...'
                                  : 'Analizar Certificado HTTPS Ahora (7. CertScope)',
                              style: const TextStyle(
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppPalette.violet600,
                              visualDensity: VisualDensity.compact,
                            ),
                          ),
                        ),
                        if ((_fdCertScopeSummary['common_name'] ?? '')
                                .toString()
                                .isNotEmpty ||
                            (_fdCertScopeSummary['last_error'] ?? '')
                                .toString()
                                .isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.all(7),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: (_fdCertScopeSummary['status'] == 'valid')
                                    ? AppPalette.green300
                                    : AppPalette.amber300,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  (_fdCertScopeSummary['common_name'] ?? '')
                                          .toString()
                                          .isNotEmpty
                                      ? 'CN: ${_fdCertScopeSummary['common_name']} (${_fdCertScopeSummary['days_remaining'] ?? '?'} días)'
                                      : 'Estado TLS: ${_fdCertScopeSummary['status'] ?? 'Pendiente'}',
                                  style: const TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w800,
                                    color: AppPalette.slate900,
                                  ),
                                ),
                                if ((_fdCertScopeSummary['issuer_cn'] ?? '')
                                    .toString()
                                    .isNotEmpty)
                                  Text(
                                    'CA: ${_fdCertScopeSummary['issuer_cn']} · Vence: ${(_fdCertScopeSummary['valid_until'] ?? '').toString().split('T').first}',
                                    style: const TextStyle(
                                      fontSize: 9.8,
                                      color: AppPalette.slate600,
                                    ),
                                  ),
                                if ((_fdCertScopeSummary['last_error'] ?? '')
                                    .toString()
                                    .isNotEmpty)
                                  Text(
                                    'Detalle: ${_fdCertScopeSummary['last_error']}',
                                    style: const TextStyle(
                                      fontSize: 9.5,
                                      color: AppPalette.red700,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // Bloque destacado de Conexión al Rack
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppPalette.amber50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppPalette.amber300),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(
                            Icons.dns_rounded,
                            size: 14,
                            color: AppPalette.amber700,
                          ),
                          SizedBox(width: 6),
                          Text(
                            'Rack Conectado & Cableado',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w900,
                              color: AppPalette.amber800,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<int?>(
                        key: ValueKey('rack_${dev.id}_$safeLinkedRackId'),
                        initialValue: safeLinkedRackId,
                        isExpanded: true,
                        isDense: true,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppPalette.slate900,
                        ),
                        decoration: _compactInputDecoration(
                          'Conectado al Rack (Línea Naranja)',
                        ),
                        items: [
                          const DropdownMenuItem<int?>(
                            value: null,
                            child: Text('Sin conexión directa a Rack'),
                          ),
                          ...floorRacks.map(
                            (rk) => DropdownMenuItem<int?>(
                              value: rk.id,
                              child: Text('${rk.code} (${rk.name})'),
                            ),
                          ),
                        ],
                        onChanged: (v) {
                          _rebuildState(() => _devLinkedRackId = v);
                          String rackLabel = 'Sin Rack';
                          if (v != null) {
                            for (final rk in floorRacks) {
                              if (rk.id == v) {
                                rackLabel = '${rk.code} (${rk.name})';
                                break;
                              }
                            }
                          }
                          _saveSelectedFloorDeviceSettings(
                            customToast: v == null
                                ? '✓ "${_devCodeCtrl.text.trim()}" desvinculado de Rack.'
                                : '✓ "${_devCodeCtrl.text.trim()}" conectado al Rack $rackLabel.',
                          );
                        },
                      ),
                      const SizedBox(height: 8),
                      _buildCompactField(
                        label:
                            'Puerto / Sonda en Rack (ej. ENV-MON:Temp1 / PP-A:01)',
                        controller: _devRackPortCtrl,
                      ),
                      if (dev.category != 'telecom_outlet') ...[
                        const SizedBox(height: 8),
                        DropdownButtonFormField<int?>(
                          key: ValueKey('out_${dev.id}_$safeLinkedOutletId'),
                          initialValue: safeLinkedOutletId,
                          isExpanded: true,
                          isDense: true,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppPalette.slate900,
                          ),
                          decoration: _compactInputDecoration(
                            'Telecommunications Outlet (Línea Azul)',
                          ),
                          items: [
                            const DropdownMenuItem<int?>(
                              value: null,
                              child: Text('None (Direct to Rack)'),
                            ),
                            ...floorOutlets
                                .where((o) => o.id != dev.id)
                                .map(
                                  (o) => DropdownMenuItem<int?>(
                                    value: o.id,
                                    child: Text('${o.code} (${o.roomCode})'),
                                  ),
                                ),
                          ],
                          onChanged: (v) {
                            _rebuildState(() => _devLinkedOutletId = v);
                            _saveSelectedFloorDeviceSettings(
                              customToast:
                                  '✓ Roseta de "${_devCodeCtrl.text.trim()}" actualizada.',
                            );
                          },
                        ),
                      ],
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () => _saveSelectedFloorDeviceSettings(),
                          icon: const Icon(Icons.check_circle_outline, size: 15),
                          label: const Text(
                            'Aplicar Conexión / Puerto de Rack',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: AppPalette.amber800,
                            backgroundColor: Colors.white,
                            side: const BorderSide(color: AppPalette.amber500),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                _buildCompactField(
                  label: 'Responsible person',
                  controller: _devRespCtrl,
                ),
                const SizedBox(height: 12),
                const Divider(height: 1, color: AppPalette.slate200),
                const SizedBox(height: 10),
                const Text(
                  'Contact person',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: AppPalette.slate900,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _buildCompactField(
                        label: 'First name',
                        controller: _devContactFirstCtrl,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildCompactField(
                        label: 'Last name',
                        controller: _devContactLastCtrl,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _buildCompactField(
                  label: 'Email',
                  controller: _devContactEmailCtrl,
                ),
                const SizedBox(height: 8),
                _buildCompactField(
                  label: 'Phone',
                  controller: _devContactPhoneCtrl,
                ),
                const SizedBox(height: 8),
                _buildCompactField(
                  label: 'Job title',
                  controller: _devContactJobCtrl,
                ),
                const SizedBox(height: 8),
                _buildCompactField(
                  label: 'Department',
                  controller: _devContactDeptCtrl,
                ),
                const SizedBox(height: 8),
                _buildCompactField(
                  label: 'Lectura Sensor / Notas',
                  controller: _devNotesCtrl,
                  maxLines: 2,
                ),
              ],
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: const BoxDecoration(
            color: AppPalette.slate50,
            border: Border(top: BorderSide(color: AppPalette.slate200)),
          ),
          child: FilledButton.icon(
            onPressed: () => _saveSelectedFloorDeviceSettings(),
            icon: const Icon(Icons.save_outlined, size: 16),
            label: const Text('Guardar Cambios (Save Settings)'),
            style: FilledButton.styleFrom(
              backgroundColor: AppPalette.blue600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSelectedRackSettingsSummary(
    FloorNode floor,
    RackSummary rk,
  ) {
    final connectedDevices = floor.floorDevices
        .where((d) => d.linkedRackId == rk.id)
        .toList();
    final otherDevices = floor.floorDevices
        .where((d) => d.linkedRackId != rk.id)
        .toList();
    final rackInterLinks = floor.interRackLinks.where((l) {
      return l['source_rack_id'] == rk.id || l['target_rack_id'] == rk.id;
    }).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppPalette.slate50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppPalette.slate200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${rk.code} — ${rk.name}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: AppPalette.slate900,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Altura: ${rk.totalUnits}U  •  Equipos en Rack: ${rk.deviceCount}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: AppPalette.slate600,
                  ),
                ),
                if (rk.responsiblePerson.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Responsable: ${rk.responsiblePerson}',
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppPalette.slate600,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: () => widget.onOpenRack(rk.id),
                  icon: const Icon(Icons.open_in_new, size: 15),
                  label: const Text('Abrir en 3. Rack Editor'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppPalette.blue900,
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Resumen de Líneas Conectadas (Electricidad, Fibra, Ethernet y Enlaces Inter-Rack)
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppPalette.sky50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppPalette.sky200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'LÍNEAS CONECTADAS EN RACK (ETH / FIBRA / ELECTRICIDAD)',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    color: AppPalette.sky700,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          vertical: 6,
                          horizontal: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFFFED7AA)),
                        ),
                        child: Column(
                          children: [
                            Text(
                              '⚡ ${rk.powerCablesCount}',
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w900,
                                color: AppPalette.orange600,
                              ),
                            ),
                            const Text(
                              'Eléctrica',
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                                color: AppPalette.slate500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          vertical: 6,
                          horizontal: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFFA5F3FC)),
                        ),
                        child: Column(
                          children: [
                            Text(
                              '🌐 ${rk.fiberCablesCount}',
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF0891B2),
                              ),
                            ),
                            const Text(
                              'Fibra Óptica',
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                                color: AppPalette.slate500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          vertical: 6,
                          horizontal: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFFBFDBFE)),
                        ),
                        child: Column(
                          children: [
                            Text(
                              '🔌 ${rk.ethCablesCount}',
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w900,
                                color: AppPalette.blue600,
                              ),
                            ),
                            const Text(
                              'Ethernet',
                              style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                                color: AppPalette.slate500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                if (rk.externalFeeds.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 5,
                    runSpacing: 4,
                    children: rk.externalFeeds.map((ef) {
                      final ftype = (ef['feed_type'] ?? 'power').toString();
                      final cnt = (ef['connected_count'] ?? 0) as int;
                      final code = (ef['code'] ?? '').toString();
                      final isFib = ftype == 'fiber';
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2.5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(
                            color: isFib
                                ? AppPalette.cyan500
                                : AppPalette.orange600,
                          ),
                        ),
                        child: Text(
                          '${isFib ? '🌐' : '⚡'} $code: $cnt líns.',
                          style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w800,
                            color: isFib
                                ? const Color(0xFF0E7490)
                                : const Color(0xFFC2410C),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
                if (rackInterLinks.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  const Divider(height: 1, color: AppPalette.sky200),
                  const SizedBox(height: 6),
                  Text(
                    'ENLACES INTER-RACK (${rackInterLinks.length}):',
                    style: const TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w900,
                      color: AppPalette.sky700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  ...rackInterLinks.map((lnk) {
                    final isSrc = lnk['source_rack_id'] == rk.id;
                    final otherRackCode = isSrc
                        ? (lnk['target_rack_code'] ?? '').toString()
                        : (lnk['source_rack_code'] ?? '').toString();
                    final myEnd = isSrc
                        ? '${lnk['source_device_code']}:${lnk['source_port_number']}'
                        : '${lnk['target_device_code']}:${lnk['target_port_number']}';
                    final otherEnd = isSrc
                        ? '${lnk['target_device_code']}:${lnk['target_port_number']}'
                        : '${lnk['source_device_code']}:${lnk['source_port_number']}';
                    final mg = (lnk['media_group'] ?? 'fiber').toString();
                    final iconStr = mg == 'fiber'
                        ? '🌐 FIB'
                        : (mg == 'power' ? '⚡ PWR' : '🔌 ETH');
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        '$iconStr • $myEnd ⟷ $otherRackCode ($otherEnd)',
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: AppPalette.slate900,
                        ),
                      ),
                    );
                  }),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'SENSORES, TOMAS Y DISPOSITIVOS CONECTADOS A ESTE RACK (${connectedDevices.length})',
            style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w900,
              color: AppPalette.slate500,
            ),
          ),
          const SizedBox(height: 8),
          if (connectedDevices.isEmpty)
            const Text(
              'Ningún sensor, roseta o cámara vinculado aún a este Rack.',
              style: TextStyle(fontSize: 11.5, color: AppPalette.slate400),
            )
          else
            ...connectedDevices.map((d) {
              final cat = _catalogItemFor(d.category);
              return Card(
                margin: const EdgeInsets.only(bottom: 6),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                  side: const BorderSide(color: AppPalette.slate200),
                ),
                child: ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  leading: Icon(
                    cat.icon,
                    size: 16,
                    color: cat.pinColor,
                  ),
                  title: Text(
                    '${d.code} (${d.roomCode})',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(
                    d.linkedRackPort.isNotEmpty
                        ? 'Puerto/Sonda: ${d.linkedRackPort}'
                        : cat.label,
                    style: const TextStyle(fontSize: 10.5),
                  ),
                  trailing: IconButton(
                    tooltip: 'Desvincular de ${rk.code}',
                    icon: const Icon(
                      Icons.link_off_rounded,
                      size: 16,
                      color: AppPalette.red600,
                    ),
                    onPressed: () => _quickLinkDeviceToRack(d, null, rk.code),
                  ),
                  onTap: () => _selectFloorDevice(d),
                ),
              );
            }),
          if (otherDevices.isNotEmpty) ...[
            const SizedBox(height: 14),
            const Divider(height: 1, color: AppPalette.slate200),
            const SizedBox(height: 12),
            Text(
              'MOVER / CONECTAR OTROS SENSORES DE PLANTA A ${rk.code} (${otherDevices.length})',
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w900,
                color: AppPalette.amber700,
              ),
            ),
            const SizedBox(height: 6),
            ...otherDevices.map((d) {
              final cat = _catalogItemFor(d.category);
              return Card(
                margin: const EdgeInsets.only(bottom: 5),
                elevation: 0,
                color: AppPalette.amber50,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                  side: const BorderSide(color: Color(0xFFFDE68A)),
                ),
                child: ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  leading: Icon(
                    cat.icon,
                    size: 15,
                    color: cat.pinColor,
                  ),
                  title: Text(
                    '${d.code} • ${d.name}',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    cat.label,
                    style: const TextStyle(fontSize: 10),
                  ),
                  trailing: FilledButton.tonal(
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      backgroundColor: AppPalette.amber100,
                      foregroundColor: AppPalette.amber800,
                    ),
                    onPressed: () => _quickLinkDeviceToRack(d, rk.id, rk.code),
                    child: Text(
                      '→ ${rk.code}',
                      style: const TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  onTap: () => _selectFloorDevice(d),
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  Widget _buildFloorOverviewSettingsList(
    FloorNode floor,
    List<RackSummary> floorRacks,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          child: Text(
            'Haz clic en cualquier sensor, cámara, roseta, PC o Rack del plano para editar sus Settings (${floor.floorDevices.length} elementos en planta).',
            style: const TextStyle(
              fontSize: 11,
              color: AppPalette.slate500,
            ),
          ),
        ),
        const Divider(height: 1, color: AppPalette.slate200),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(10),
            children: [
              if (floor.floorDevices.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'No hay dispositivos en esta planta. Arrastra elementos desde DEVICES LIBRARY a la izquierda.',
                    style: TextStyle(fontSize: 12, color: AppPalette.slate400),
                  ),
                )
              else
                ...floor.floorDevices.map((d) {
                  final cat = _catalogItemFor(d.category);
                  return Container(
                    margin: const EdgeInsets.only(bottom: 5),
                    decoration: BoxDecoration(
                      color: AppPalette.slate50,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppPalette.slate200),
                    ),
                    child: ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      leading: Icon(
                        cat.icon,
                        size: 16,
                        color: cat.pinColor,
                      ),
                      title: Text(
                        '${d.code}  •  ${d.name}',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        [
                          if (d.roomCode.isNotEmpty) 'Sala: ${d.roomCode}',
                          if (d.ipAddress.isNotEmpty) d.ipAddress,
                          if (d.linkedRackPort.isNotEmpty) d.linkedRackPort,
                        ].join(' • '),
                        style: const TextStyle(fontSize: 10),
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right, size: 16),
                      onTap: () => _selectFloorDevice(d),
                    ),
                  );
                }),
            ],
          ),
        ),
      ],
    );
  }

  InputDecoration _compactInputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(fontSize: 11, color: AppPalette.slate500),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: AppPalette.slate300),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: AppPalette.slate200),
      ),
    );
  }

  Widget _buildCompactField({
    required String label,
    required TextEditingController controller,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      textInputAction:
          maxLines == 1 ? TextInputAction.done : TextInputAction.newline,
      onSubmitted:
          maxLines == 1 ? (_) => _saveSelectedFloorDeviceSettings() : null,
      style: const TextStyle(fontSize: 12, color: AppPalette.slate900),
      decoration: _compactInputDecoration(label),
    );
  }
}
