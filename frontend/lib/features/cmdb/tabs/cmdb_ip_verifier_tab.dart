part of '../cmdb_view.dart';

/// Pestaña 2 de `6. CMDB & Control IPs`: verificador profundo de IPs libres
/// (*Deep IP Probe*) y escáner de rangos CIDR con alta directa en CMDB.
extension _CmdbIpVerifierTabExt on _CmdbViewState {
  // ===========================================================================
  // PESTAÑA 2: VERIFICADOR MANUAL DE IPs Y ESCÁNER DE RANGOS CIDR (ej. 1.1.1.1/24)
  // ===========================================================================
  Widget _buildManualIpVerifierTab() {
    final allResults = ((_verificationReport?['results'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((r) => !_dismissedScanIps.contains((r['ip_address'] ?? '').toString()))
        .toList();

    final int conflictCount = allResults
        .where((r) => r['verdict'] == 'conflict_unregistered')
        .length;
    final int freeCount = allResults
        .where((r) => r['verdict'] == 'free_confirmed')
        .length;
    final int activeInCmdbCount = allResults
        .where((r) => r['verdict'] == 'active_in_network')
        .length;
    final int noResponseCount = allResults
        .where((r) => r['verdict'] == 'no_response')
        .length;

    final int detectedOrCmdbCount =
        conflictCount + activeInCmdbCount + noResponseCount;

    final filteredResults = allResults.where((r) {
      if (_scanResultFilter == 'all') return true;
      if (_scanResultFilter == 'detected_or_cmdb') {
        return (r['verdict'] ?? '').toString() != 'free_confirmed';
      }
      return (r['verdict'] ?? '').toString() == _scanResultFilter;
    }).toList();

    final String? suggestedFree =
        _verificationReport?['suggested_free_ip'] as String?;
    final String? scannedCidr =
        _verificationReport?['scanned_cidr'] as String?;
    final bool cidrAlreadyInCmdb =
        _verificationReport?['cidr_already_in_cmdb'] == true;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Panel de control manual
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppPalette.slate300),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.verified_user_rounded,
                      color: AppPalette.sky600,
                      size: 22,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Escáner y Verificador Manual de IPs, Rangos y Redes CIDR (ej. 1.1.1.1/24) con Incorporación Selectiva a la CMDB',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          color: AppPalette.slate900,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'Introduce una IP concreta (10.20.20.45), un rango (10.20.20.1-50) o una red CIDR completa (ej. 1.1.1.1/24 o 10.20.20.0/24). '
                  'El sistema analizará en paralelo todo el rango con 4 sondas reales (Ping ICMP + Puertos TCP + Caché ARP MAC + DNS PTR) '
                  'y te permitirá decidir qué equipos o IPs encontradas quieres añadir a la CMDB y cuáles descartar.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppPalette.slate600,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 360,
                      child: TextField(
                        controller: _verifyIpCtrl,
                        onSubmitted: (_) =>
                            _runManualVerification(onlySuggestFree: false),
                        style: const TextStyle(
                          fontSize: 13,
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w800,
                        ),
                        decoration: InputDecoration(
                          labelText:
                              'IP, Rango o Red CIDR (ej. 1.1.1.1/24, 10.20.20.0/24 o 10.20.20.1-50)',
                          prefixIcon: const Icon(Icons.radar_rounded, size: 18),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          isDense: true,
                        ),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _verifyingIp
                          ? null
                          : () => _runManualVerification(onlySuggestFree: false),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppPalette.slate900,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                      icon: _verifyingIp
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.play_arrow_rounded, size: 18),
                      label: Text(
                        _verifyingIp
                            ? 'Analizando Rango en Red...'
                            : 'Analizar IP / Rango CIDR Ahora',
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      height: 36,
                      width: 1,
                      color: AppPalette.slate200,
                    ),
                    const SizedBox(width: 8),
                    DropdownButtonHideUnderline(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: AppPalette.slate50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppPalette.slate300),
                        ),
                        child: DropdownButton<int>(
                          value: _verifySelectedSubnetId,
                          hint: const Text('Seleccionar Subred VLAN'),
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                            color: AppPalette.slate900,
                          ),
                          items: _subnets.map((s) {
                            return DropdownMenuItem<int>(
                              value: s['id'] as int,
                              child: Text('${s['cidr']} — ${s['name']}'),
                            );
                          }).toList(),
                          onChanged: (v) {
                            _rebuildState(() {
                              _verifySelectedSubnetId = v;
                              if (v != null) {
                                final match = _subnets
                                    .where((s) => s['id'] == v)
                                    .firstOrNull;
                                final cidr =
                                    (match?['cidr'] ?? '').toString().trim();
                                if (cidr.isNotEmpty) {
                                  _verifyIpCtrl.text = cidr;
                                }
                              }
                            });
                          },
                        ),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: _verifyingIp || _verifySelectedSubnetId == null
                          ? null
                          : () {
                              final match = _subnets
                                  .where(
                                    (s) => s['id'] == _verifySelectedSubnetId,
                                  )
                                  .firstOrNull;
                              final cidr =
                                  (match?['cidr'] ?? '').toString().trim();
                              if (cidr.isNotEmpty) {
                                _rebuildState(() => _verifyIpCtrl.text = cidr);
                                _runManualVerification(
                                  customIp: cidr,
                                  onlySuggestFree: false,
                                );
                              }
                            },
                      style: FilledButton.styleFrom(
                        backgroundColor: AppPalette.blue600,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 15,
                          vertical: 14,
                        ),
                      ),
                      icon: const Icon(Icons.radar_rounded, size: 17),
                      label: const Text(
                        'Escanear Subred Seleccionada',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: _verifyingIp
                          ? null
                          : () => _runManualVerification(onlySuggestFree: true),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppPalette.green100,
                        foregroundColor: const Color(0xFF166534),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 14,
                        ),
                      ),
                      icon: const Icon(Icons.auto_fix_high_rounded, size: 17),
                      label: const Text(
                        'Sugerir Próximas IPs Libres en Subred',
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
                // Barra rápida de Rangos de la CMDB (Subredes dadas de alta + Rangos /24 autodetectados en activos) con botón directo de Escanear
                Builder(
                  builder: (context) {
                    final explicitCidrs = <String>{};
                    final rangeCards = <Map<String, dynamic>>[];

                    for (final s in _subnets) {
                      final cidr = (s['cidr'] ?? '').toString().trim();
                      if (cidr.isEmpty) continue;
                      explicitCidrs.add(cidr);
                      rangeCards.add({
                        'cidr': cidr,
                        'label': (s['name'] ?? cidr).toString(),
                        'subnet_id': s['id'] as int?,
                        'vlan_id': s['vlan_id'],
                        'occupied': s['occupied_count'] ?? 0,
                        'is_explicit': true,
                      });
                    }

                    final autoCounts = <String, int>{};
                    for (final a in _assets) {
                      final ip = (a['heartbeat_ip'] ?? '').toString().trim();
                      final parts = ip.split('.');
                      if (parts.length == 4) {
                        final cidr24 =
                            '${parts[0]}.${parts[1]}.${parts[2]}.0/24';
                        if (!explicitCidrs.contains(cidr24)) {
                          autoCounts[cidr24] = (autoCounts[cidr24] ?? 0) + 1;
                        }
                      }
                    }
                    for (final entry in autoCounts.entries) {
                      rangeCards.add({
                        'cidr': entry.key,
                        'label': 'Rango detectado en CMDB',
                        'subnet_id': null,
                        'vlan_id': null,
                        'occupied': entry.value,
                        'is_explicit': false,
                      });
                    }

                    if (rangeCards.isEmpty) return const SizedBox.shrink();

                    return Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: AppPalette.slate50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppPalette.slate200),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Row(
                              children: [
                                Icon(
                                  Icons.lan_outlined,
                                  size: 14,
                                  color: AppPalette.blue700,
                                ),
                                SizedBox(width: 6),
                                Text(
                                  'RANGOS EN CMDB (Redes dadas de alta y rangos detectados en activos — Pulsa "Escanear" directamente):',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w900,
                                    color: AppPalette.slate700,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: rangeCards.map((rc) {
                                final cidr = rc['cidr'] as String;
                                final label = rc['label'] as String;
                                final subId = rc['subnet_id'] as int?;
                                final vlanId = rc['vlan_id'];
                                final occ = rc['occupied'] as int;
                                final isExp = rc['is_explicit'] as bool;
                                final isCurrent =
                                    _verifyIpCtrl.text.trim() == cidr;

                                return Container(
                                  padding: const EdgeInsets.fromLTRB(
                                    10,
                                    5,
                                    6,
                                    5,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isCurrent
                                        ? AppPalette.blue50
                                        : Colors.white,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: isCurrent
                                          ? AppPalette.blue600
                                          : AppPalette.slate300,
                                      width: isCurrent ? 1.5 : 1.0,
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      InkWell(
                                        onTap: () {
                                          _rebuildState(() {
                                            _verifyIpCtrl.text = cidr;
                                            if (subId != null) {
                                              _verifySelectedSubnetId = subId;
                                            }
                                          });
                                        },
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              isExp
                                                  ? Icons.hub_outlined
                                                  : Icons.auto_awesome_mosaic,
                                              size: 13,
                                              color: isExp
                                                  ? AppPalette.blue700
                                                  : AppPalette.sky700,
                                            ),
                                            const SizedBox(width: 5),
                                            Text(
                                              cidr,
                                              style: const TextStyle(
                                                fontSize: 11.5,
                                                fontFamily: 'monospace',
                                                fontWeight: FontWeight.w900,
                                                color: AppPalette.slate900,
                                              ),
                                            ),
                                            const SizedBox(width: 5),
                                            Text(
                                              '• $label${vlanId != null ? " (VLAN $vlanId)" : ""} ($occ eq.)',
                                              style: const TextStyle(
                                                fontSize: 10.8,
                                                fontWeight: FontWeight.w600,
                                                color: AppPalette.slate600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      FilledButton.tonalIcon(
                                        style: FilledButton.styleFrom(
                                          visualDensity: VisualDensity.compact,
                                          backgroundColor: AppPalette.blue600,
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 4,
                                          ),
                                          minimumSize: const Size(0, 26),
                                        ),
                                        onPressed: _verifyingIp
                                            ? null
                                            : () {
                                                _rebuildState(() {
                                                  _verifyIpCtrl.text = cidr;
                                                  if (subId != null) {
                                                    _verifySelectedSubnetId =
                                                        subId;
                                                  }
                                                });
                                                _runManualVerification(
                                                  customIp: cidr,
                                                  onlySuggestFree: false,
                                                );
                                              },
                                        icon: const Icon(
                                          Icons.radar_rounded,
                                          size: 13,
                                        ),
                                        label: const Text(
                                          'Escanear',
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.w900,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }).toList(),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                if (_verifyError != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppPalette.red50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppPalette.red200),
                    ),
                    child: Text(
                      'Error: $_verifyError',
                      style: const TextStyle(
                        color: AppPalette.red700,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
                if (suggestedFree != null) ...[
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: AppPalette.green50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppPalette.green300),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.check_circle_rounded,
                          color: AppPalette.green700,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'Primera IP Libre Confirmada en el análisis: $suggestedFree (0 respuestas en Ping, TCP, ARP y DNS + Libre en CMDB)',
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF14532D),
                              fontSize: 13,
                            ),
                          ),
                        ),
                        if (widget.canEdit) ...[
                          FilledButton.icon(
                            onPressed: () =>
                                _openAssignVerifiedIpToExistingAssetDialog(
                              suggestedFree,
                            ),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppPalette.green700,
                            ),
                            icon: const Icon(Icons.add_link_rounded, size: 16),
                            label: const Text('Asignar a Host Existente'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: () => _openAssetEditorDialog(
                              prefilledIp: suggestedFree,
                            ),
                            icon: const Icon(Icons.add_box_outlined, size: 16),
                            label: const Text('Crear Nueva VM/Host con esta IP'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
                // Barra de Filtros e Incorporación Selectiva a la CMDB tras escanear un rango
                if (allResults.isNotEmpty) ...[
                  const Divider(height: 24),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text(
                        'Filtrar resultados del rango:',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: AppPalette.slate900,
                        ),
                      ),
                      _buildScanFilterChip(
                        'detected_or_cmdb',
                        'Equipos Detectados / En CMDB ($detectedOrCmdbCount)',
                        AppPalette.slate900,
                      ),
                      _buildScanFilterChip(
                        'conflict_unregistered',
                        'Detectados NO en CMDB - Rojo ($conflictCount)',
                        AppPalette.red700,
                      ),
                      _buildScanFilterChip(
                        'active_in_network',
                        'En CMDB y Activos - Verde ($activeInCmdbCount)',
                        AppPalette.green700,
                      ),
                      _buildScanFilterChip(
                        'no_response',
                        'En CMDB Sin Respuesta ($noResponseCount)',
                        AppPalette.amber700,
                      ),
                      _buildScanFilterChip(
                        'free_confirmed',
                        'IPs Libres / No Ocupadas ($freeCount)',
                        AppPalette.sky600,
                      ),
                      _buildScanFilterChip(
                        'all',
                        'Ver Rango Completo (${allResults.length})',
                        AppPalette.slate600,
                      ),
                    ],
                  ),
                  if (widget.canEdit) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppPalette.slate50,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppPalette.slate300),
                      ),
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Icon(
                            Icons.playlist_add_check_rounded,
                            color: AppPalette.blue900,
                          ),
                          Text(
                            'Seleccionados para añadir a CMDB: ${_selectedDiscoveredIps.length}',
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w900,
                              color: AppPalette.slate900,
                            ),
                          ),
                          OutlinedButton(
                            onPressed: () {
                              _rebuildState(() {
                                _selectedDiscoveredIps.clear();
                                for (final r in allResults) {
                                  if (r['verdict'] == 'conflict_unregistered') {
                                    _selectedDiscoveredIps.add(
                                      (r['ip_address'] ?? '').toString(),
                                    );
                                  }
                                }
                              });
                            },
                            child: Text(
                              'Marcar Detectados en Red ($conflictCount)',
                              style: const TextStyle(fontSize: 11.5),
                            ),
                          ),
                          OutlinedButton(
                            onPressed: () => _rebuildState(
                              () => _selectedDiscoveredIps.clear(),
                            ),
                            child: const Text(
                              'Desmarcar Todos',
                              style: TextStyle(fontSize: 11.5),
                            ),
                          ),
                          DropdownButtonHideUnderline(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: AppPalette.slate300,
                                ),
                              ),
                              child: DropdownButton<String>(
                                value: _bulkImportAssetClass,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppPalette.slate900,
                                ),
                                items: _CmdbViewState._assetClassLabels.entries.map((e) {
                                  return DropdownMenuItem<String>(
                                    value: e.key,
                                    child: Text('Crear como: ${e.value}'),
                                  );
                                }).toList(),
                                onChanged: (v) {
                                  if (v != null) {
                                    _rebuildState(() => _bulkImportAssetClass = v);
                                  }
                                },
                              ),
                            ),
                          ),
                          DropdownButtonHideUnderline(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: AppPalette.slate300,
                                ),
                              ),
                              child: DropdownButton<int?>(
                                value: _locations.any(
                                          (l) =>
                                              l['id'] == _bulkImportLocationId,
                                        )
                                    ? _bulkImportLocationId
                                    : null,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppPalette.slate900,
                                ),
                                items: [
                                  const DropdownMenuItem<int?>(
                                    value: null,
                                    child: Text(
                                      'Sede (Location): Sin Sede específica',
                                    ),
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
                                onChanged: (v) =>
                                    _rebuildState(() => _bulkImportLocationId = v),
                              ),
                            ),
                          ),
                          if (scannedCidr != null &&
                              scannedCidr.isNotEmpty &&
                              !cidrAlreadyInCmdb)
                            FilterChip(
                              selected: _alsoRegisterScannedSubnet,
                              label: Text(
                                'Registrar también subred $scannedCidr en IPAM',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              onSelected: (v) => _rebuildState(
                                () => _alsoRegisterScannedSubnet = v,
                              ),
                            ),
                          FilledButton.icon(
                            onPressed: _importingDiscovered
                                ? null
                                : () =>
                                    _importSelectedDiscoveredToCmdb(allResults),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppPalette.blue900,
                            ),
                            icon: _importingDiscovered
                                ? const SizedBox(
                                    width: 15,
                                    height: 15,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(
                                    Icons.library_add_check_rounded,
                                    size: 16,
                                  ),
                            label: Text(
                              'Añadir Seleccionados (${_selectedDiscoveredIps.length}) a la CMDB',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: _selectedDiscoveredIps.isEmpty
                                ? null
                                : () => ProvisioningWorkspaceView.showQuickProvisionDialog(
                                    context,
                                    api: widget.api,
                                    initialTargets: _selectedDiscoveredIps
                                        .toList(),
                                    canEdit: widget.canEdit,
                                    onCompleted: _loadOverview,
                                  ),
                            icon: const Icon(
                              Icons.rocket_launch_rounded,
                              size: 15,
                            ),
                            label: Text(
                              'Verificar / Desplegar Ansible (${_selectedDiscoveredIps.length})',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 12,
                              ),
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
          const SizedBox(height: 16),
          if (filteredResults.isEmpty && !_verifyingIp)
            Container(
              padding: const EdgeInsets.all(32),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppPalette.slate200),
              ),
              child: const Column(
                children: [
                  Icon(
                    Icons.network_check_rounded,
                    size: 46,
                    color: AppPalette.slate400,
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Introduce una IP, rango o red CIDR (ej. 1.1.1.1/24 o 10.20.20.0/24) y pulsa "Analizar IP / Rango CIDR Ahora".',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppPalette.slate500,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            )
          else
            ...filteredResults.map(_buildSingleVerificationResultCard),
        ],
      ),
    );
  }

  Widget _buildScanFilterChip(String key, String label, Color color) {
    final active = _scanResultFilter == key;
    return ChoiceChip(
      selected: active,
      selectedColor: color,
      backgroundColor: Colors.white,
      label: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: active ? FontWeight.w900 : FontWeight.w700,
          color: active ? Colors.white : color,
        ),
      ),
      onSelected: (_) => _rebuildState(() => _scanResultFilter = key),
    );
  }

  Widget _buildSingleVerificationResultCard(Map<String, dynamic> r) {
    final String ip = (r['ip_address'] ?? '').toString();
    final String verdict = (r['verdict'] ?? '').toString();
    final String verdictLabel = (r['verdict_label'] ?? '').toString();
    final String recommendation = (r['recommendation'] ?? '').toString();
    final bool documentedInCmdb = r['documented_in_cmdb'] == true;
    final bool isSelectedForImport = _selectedDiscoveredIps.contains(ip);
    final Map<String, dynamic> probes = Map<String, dynamic>.from(
      (r['probes'] as Map?) ?? {},
    );
    final Map<String, dynamic> icmp = Map<String, dynamic>.from(
      (probes['icmp'] as Map?) ?? {},
    );
    final Map<String, dynamic> tcp = Map<String, dynamic>.from(
      (probes['tcp'] as Map?) ?? {},
    );
    final Map<String, dynamic> arp = Map<String, dynamic>.from(
      (probes['arp'] as Map?) ?? {},
    );
    final Map<String, dynamic> dns = Map<String, dynamic>.from(
      (probes['dns_ptr'] as Map?) ?? {},
    );
    final List<Map<String, dynamic>> owners =
        ((r['cmdb_owners'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();

    // Por defecto (free_confirmed): azul/pizarra informativo (IP libre, sin equipo en red)
    Color borderCol = AppPalette.sky200;
    Color headerBg = AppPalette.sky50;
    Color badgeCol = AppPalette.sky600;
    IconData vIcon = Icons.check_circle_outline_rounded;

    if (verdict == 'conflict_unregistered') {
      // ROJO: Dispositivo detectado en red pendiente de añadir a CMDB
      borderCol = AppPalette.red300;
      headerBg = AppPalette.red50;
      badgeCol = AppPalette.red700;
      vIcon = Icons.warning_amber_rounded;
    } else if (verdict == 'active_in_network') {
      // VERDE: Dispositivo añadido a la CMDB y activo en red
      borderCol = AppPalette.green300;
      headerBg = AppPalette.green50;
      badgeCol = AppPalette.green700;
      vIcon = Icons.check_circle_rounded;
    } else if (verdict == 'no_response') {
      borderCol = AppPalette.amber300;
      headerBg = AppPalette.amber50;
      badgeCol = AppPalette.amber700;
      vIcon = Icons.help_outline_rounded;
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderCol, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: headerBg,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(9),
              ),
            ),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (widget.canEdit &&
                    !documentedInCmdb &&
                    verdict == 'conflict_unregistered')
                  Checkbox(
                    value: isSelectedForImport,
                    activeColor: AppPalette.blue900,
                    visualDensity: VisualDensity.compact,
                    onChanged: (v) {
                      _rebuildState(() {
                        if (v == true) {
                          _selectedDiscoveredIps.add(ip);
                        } else {
                          _selectedDiscoveredIps.remove(ip);
                        }
                      });
                    },
                  ),
                Icon(vIcon, color: badgeCol, size: 20),
                Text(
                  ip,
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w900,
                    fontFamily: 'monospace',
                    color: badgeCol,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: badgeCol,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    verdictLabel,
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                    ),
                  ),
                ),
                Text(
                  '(${r['elapsed_ms'] ?? '--'} ms)',
                  style: const TextStyle(
                    fontSize: 11,
                    color: AppPalette.slate600,
                  ),
                ),
                if (widget.canEdit &&
                    !documentedInCmdb &&
                    verdict == 'conflict_unregistered') ...[
                  FilledButton.icon(
                    onPressed: _importingDiscovered
                        ? null
                        : () async {
                            await _importSelectedDiscoveredToCmdb(
                              [r],
                              forceDirectRows: true,
                            );
                          },
                    style: FilledButton.styleFrom(
                      backgroundColor: AppPalette.red700,
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.add_task_rounded, size: 15),
                    label: const Text(
                      'Añadir a CMDB (Pasa a Verde)',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _openAssetEditorDialog(
                      prefilledIp: ip,
                      prefilledFqdn: (dns['ptr_hostname'] ?? '').toString(),
                      prefilledMac: (arp['mac_address'] ?? '').toString(),
                    ),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.edit_note_rounded, size: 15),
                    label: const Text(
                      'Editar y Añadir a CMDB',
                      style: TextStyle(fontSize: 11.5),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () =>
                        _openAssignVerifiedIpToExistingAssetDialog(ip),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.add_link_rounded, size: 15),
                    label: const Text(
                      'Vincular a Host Existente',
                      style: TextStyle(fontSize: 11.5),
                    ),
                  ),
                ] else if (widget.canEdit &&
                    !documentedInCmdb &&
                    verdict == 'free_confirmed') ...[
                  OutlinedButton.icon(
                    onPressed: () => _openAssetEditorDialog(prefilledIp: ip),
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.add_box_outlined, size: 15),
                    label: const Text(
                      'Asignar IP Libre a Nueva VM/Host',
                      style: TextStyle(fontSize: 11.5),
                    ),
                  ),
                ] else if (documentedInCmdb && owners.isNotEmpty) ...[
                  OutlinedButton.icon(
                    onPressed: () {
                      final aid = owners.first['asset_id'] as int?;
                      _rebuildState(() {
                        _activeTab = 'inventory';
                        if (aid != null) {
                          _highlightedAssetId = aid;
                          _expandedAssetId = aid;
                        }
                      });
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppPalette.green700,
                      side: const BorderSide(color: AppPalette.green300),
                      visualDensity: VisualDensity.compact,
                    ),
                    icon: const Icon(Icons.table_chart_outlined, size: 15),
                    label: const Text(
                      'Ver en Inventario CMDB',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
                TextButton.icon(
                  onPressed: () {
                    _rebuildState(() {
                      _dismissedScanIps.add(ip);
                      _selectedDiscoveredIps.remove(ip);
                    });
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: AppPalette.slate500,
                    visualDensity: VisualDensity.compact,
                  ),
                  icon: const Icon(Icons.close_rounded, size: 15),
                  label: const Text(
                    'Ocultar de la lista',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  recommendation,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AppPalette.slate800,
                  ),
                ),
                if (owners.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: owners.map((o) {
                      return Chip(
                        avatar: const Icon(Icons.computer, size: 15),
                        label: Text(
                          'Asignada en CMDB a: ${o['asset_code']} — ${o['asset_name']} [${o['ip_role_label']}]',
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _buildProbeResultBox(
                        title: '1. Sonda ICMP Ping',
                        active: icmp['alive'] == true,
                        detail: (icmp['detail'] ?? '').toString(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildProbeResultBox(
                        title: '2. Sonda Puertos TCP',
                        active: tcp['alive'] == true,
                        detail: (tcp['detail'] ?? '').toString(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildProbeResultBox(
                        title: '3. Caché ARP / MAC L2',
                        active: arp['alive'] == true,
                        detail: (arp['detail'] ?? '').toString(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _buildProbeResultBox(
                        title: '4. DNS Inverso (PTR)',
                        active: dns['has_ptr'] == true,
                        detail: (dns['detail'] ?? '').toString(),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProbeResultBox({
    required String title,
    required bool active,
    required String detail,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: active ? AppPalette.blue50 : AppPalette.slate50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: active ? const Color(0xFF60A5FA) : AppPalette.slate200,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                active
                    ? Icons.sensors_rounded
                    : Icons.sensors_off_rounded,
                size: 15,
                color: active
                    ? AppPalette.blue700
                    : AppPalette.slate500,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: active
                        ? AppPalette.blue900
                        : AppPalette.slate600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            detail,
            style: const TextStyle(fontSize: 11, color: AppPalette.slate700),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
