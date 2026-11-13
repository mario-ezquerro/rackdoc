part of '../cmdb_view.dart';

/// Pestaña 3 de `6. CMDB & Control IPs`: gestión de subredes/VLANs por sede
/// y matriz visual interactiva de ocupación IPAM (`.1` a `.254`).
extension _CmdbSubnetsIpamTabExt on _CmdbViewState {
  // ===========================================================================
  // PESTAÑA 3: SUBREDES, VLANs Y MAPA VISUAL IPAM (SEGÚN MÁSCARA REAL /23, /24, /25...)
  // ===========================================================================
  Widget _buildSubnetsAndIpamGridTab() {
    final subnets = _subnets;
    final selectedSubnet = subnets.firstWhere(
      (s) => s['id'] == _selectedIpamSubnetId,
      orElse: () => subnets.isNotEmpty ? subnets.first : <String, dynamic>{},
    );

    final String cidr = (selectedSubnet['cidr'] ?? '10.20.20.0/24').toString();
    final parsedCidr = _ParsedCidrBlock.tryParse(cidr);

    final int prefixLen = (selectedSubnet['prefixlen'] as int?) ??
        parsedCidr?.prefixLen ??
        24;
    final String subnetMask =
        (selectedSubnet['subnet_mask'] ?? parsedCidr?.subnetMask ?? '255.255.255.0')
            .toString();
    final String networkAddress =
        (selectedSubnet['network_address'] ?? parsedCidr?.networkAddress ?? '')
            .toString();
    final String broadcastAddress =
        (selectedSubnet['broadcast_address'] ?? parsedCidr?.broadcastAddress ?? '')
            .toString();
    final String firstUsableIp =
        (selectedSubnet['first_usable_ip'] ?? parsedCidr?.firstUsableIp ?? '')
            .toString();
    final String lastUsableIp =
        (selectedSubnet['last_usable_ip'] ?? parsedCidr?.lastUsableIp ?? '')
            .toString();
    final int totalAddresses = (selectedSubnet['total_addresses'] as int?) ??
        parsedCidr?.totalAddresses ??
        256;
    final int totalUsable = (selectedSubnet['total_usable'] as int?) ??
        parsedCidr?.totalUsable ??
        254;

    // Lista completa de direcciones IP del bloque según su máscara real (incluyendo Dirección de Red y Broadcast)
    List<String> fullAddressList =
        ((selectedSubnet['address_list'] as List?) ?? [])
            .map((e) => e.toString())
            .toList();
    if (fullAddressList.isEmpty && parsedCidr != null) {
      fullAddressList = parsedCidr.buildAddressList(maxLimit: 4096);
    }

    final List<String> subBlocks24 =
        ((selectedSubnet['sub_blocks_24'] as List?) ?? [])
            .map((e) => e.toString())
            .toList();
    if (subBlocks24.isEmpty && prefixLen < 24 && fullAddressList.isNotEmpty) {
      final seen = <String>{};
      for (final ip in fullAddressList) {
        final b24 = ip.rsplitThreeOctets();
        if (seen.add(b24)) {
          subBlocks24.add(b24);
        }
      }
    }

    final String activeBlockFilter =
        (subBlocks24.length > 1 && subBlocks24.contains(_selectedIpamSubBlock24))
            ? _selectedIpamSubBlock24
            : 'all';

    final List<String> displayedAddresses = activeBlockFilter == 'all'
        ? fullAddressList
        : fullAddressList
            .where((ip) => ip.startsWith('$activeBlockFilter.'))
            .toList();

    final List<Map<String, dynamic>> allocatedList =
        ((selectedSubnet['allocated_ips'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
    final Map<String, Map<String, dynamic>> allocatedByIp = {
      for (final item in allocatedList)
        (item['ip_address'] ?? '').toString(): item,
    };
    final String gwIp = (selectedSubnet['gateway'] ?? '').toString();
    final bool multiOctetLabel = prefixLen < 24;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Columna izquierda: Lista de Subredes / VLANs
        Container(
          width: 355,
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(right: BorderSide(color: AppPalette.slate200)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    const Icon(
                      Icons.lan_rounded,
                      size: 18,
                      color: AppPalette.blue900,
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Subredes & VLANs (IPAM)',
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    if (widget.canEdit)
                      FilledButton.tonalIcon(
                        onPressed: () => _openCreateSubnetDialog(),
                        icon: const Icon(Icons.add, size: 15),
                        label: const Text(
                          'Nueva Red / VLAN',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(10),
                  itemCount: subnets.length,
                  itemBuilder: (ctx, i) {
                    final s = subnets[i];
                    final id = s['id'] as int;
                    final isSel = id == selectedSubnet['id'];
                    final double pct =
                        (s['usage_percent'] as num?)?.toDouble() ?? 0.0;
                    final String sMask = (s['subnet_mask'] ?? '').toString();
                    final String sNetAddr =
                        (s['network_address'] ?? '').toString();
                    final String sBcastAddr =
                        (s['broadcast_address'] ?? '').toString();
                    return Card(
                      elevation: 0,
                      margin: const EdgeInsets.only(bottom: 8),
                      color: isSel
                          ? AppPalette.blue50
                          : AppPalette.slate50,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                        side: BorderSide(
                          color: isSel
                              ? AppPalette.blue600
                              : AppPalette.slate200,
                          width: isSel ? 1.5 : 1.0,
                        ),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: () => _rebuildState(() {
                          _selectedIpamSubnetId = id;
                          _selectedIpamSubBlock24 = 'all';
                        }),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      (s['cidr'] ?? '').toString(),
                                      style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w900,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ),
                                  if (s['vlan_id'] != null)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: AppPalette.blue900,
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        'VLAN ${s['vlan_id']}',
                                        style: const TextStyle(
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.w800,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  if (widget.canEdit) ...[
                                    const SizedBox(width: 4),
                                    InkWell(
                                      borderRadius: BorderRadius.circular(4),
                                      onTap: () =>
                                          _openCreateSubnetDialog(existing: s),
                                      child: const Padding(
                                        padding: EdgeInsets.all(3),
                                        child: Icon(
                                          Icons.edit_outlined,
                                          size: 15,
                                          color: AppPalette.slate600,
                                        ),
                                      ),
                                    ),
                                    InkWell(
                                      borderRadius: BorderRadius.circular(4),
                                      onTap: () => _confirmDeleteSubnet(s),
                                      child: const Padding(
                                        padding: EdgeInsets.all(3),
                                        child: Icon(
                                          Icons.delete_outline,
                                          size: 15,
                                          color: Colors.redAccent,
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 3),
                              Text(
                                (s['name'] ?? '').toString(),
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppPalette.slate700,
                                ),
                              ),
                              if ((s['location_label'] ?? '')
                                  .toString()
                                  .isNotEmpty) ...[
                                const SizedBox(height: 3),
                                Row(
                                  children: [
                                    const Icon(
                                      Icons.location_on_rounded,
                                      size: 12,
                                      color: AppPalette.teal700,
                                    ),
                                    const SizedBox(width: 3),
                                    Expanded(
                                      child: Text(
                                        'Sede: ${s['location_label']}',
                                        style: const TextStyle(
                                          fontSize: 10.5,
                                          fontWeight: FontWeight.w800,
                                          color: AppPalette.teal700,
                                        ),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                              const SizedBox(height: 4),
                              Text(
                                'Máscara: $sMask • Red: $sNetAddr • Bcast: $sBcastAddr',
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontFamily: 'monospace',
                                  color: AppPalette.slate600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              LinearProgressIndicator(
                                value: (pct / 100.0).clamp(0.0, 1.0),
                                backgroundColor: AppPalette.slate200,
                                color: pct > 80
                                    ? Colors.redAccent
                                    : AppPalette.sky600,
                                minHeight: 6,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'Ocupadas: ${s['occupied_count']} / ${s['total_usable']} útiles (${pct.toStringAsFixed(1)}%) • GW: ${s['gateway'] ?? '-'}',
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  color: AppPalette.slate500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        // Lienzo derecho: Mapa Visual de todas las IPs según su máscara (/23 = 512 IPs, /24 = 256 IPs, /25 = 128 IPs, etc.)
        Expanded(
          child: selectedSubnet.isEmpty
              ? const Center(child: Text('Selecciona o crea una subred'))
              : Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Mapa Visual de Direcciones IP: ${selectedSubnet['cidr']} — ${selectedSubnet['name']}',
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Mostrando las $totalAddresses direcciones de la máscara /$prefixLen ($subnetMask): incluyendo Dirección de Red ($networkAddress), $totalUsable hosts útiles ($firstUsableIp a $lastUsableIp) y Dirección de Broadcast ($broadcastAddress).',
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    color: AppPalette.slate600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.tonalIcon(
                            onPressed: () {
                              _rebuildState(() {
                                _verifyIpCtrl.text = cidr;
                                _verifySelectedSubnetId =
                                    selectedSubnet['id'] as int?;
                                _activeTab = 'verifier';
                              });
                              _runManualVerification(customIp: cidr);
                            },
                            icon: const Icon(Icons.radar_rounded, size: 16),
                            label: Text(
                              'Escanear Rango $cidr',
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: () {
                              _rebuildState(() {
                                _verifySelectedSubnetId =
                                    selectedSubnet['id'] as int?;
                                _activeTab = 'verifier';
                              });
                              _runManualVerification(onlySuggestFree: true);
                            },
                            icon: const Icon(Icons.auto_fix_high_rounded, size: 15),
                            label: const Text(
                              'Sugerir IP Libre',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      // Ficha técnica de la Red según su Máscara (Dirección de Red, Broadcast, Máscara, Rango Útil, Gateway)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          color: AppPalette.slate50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppPalette.slate300),
                        ),
                        child: Wrap(
                          spacing: 14,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            _buildSubnetSpecPill(
                              icon: Icons.tag_rounded,
                              label: 'Máscara',
                              value: '$subnetMask (/$prefixLen)',
                              color: AppPalette.slate900,
                            ),
                            _buildSubnetSpecPill(
                              icon: Icons.hub_rounded,
                              label: 'Dirección de Red (No asignable)',
                              value: networkAddress,
                              color: const Color(0xFF3730A3),
                              bgColor: AppPalette.indigo100,
                            ),
                            _buildSubnetSpecPill(
                              icon: Icons.podcasts_rounded,
                              label: 'Dirección de Broadcast (No asignable)',
                              value: broadcastAddress,
                              color: const Color(0xFF86198F),
                              bgColor: const Color(0xFFFAE8FF),
                            ),
                            _buildSubnetSpecPill(
                              icon: Icons.swap_horiz_rounded,
                              label: 'Rango Hosts Útiles',
                              value: '$firstUsableIp ➔ $lastUsableIp ($totalUsable IPs)',
                              color: AppPalette.sky700,
                            ),
                            _buildSubnetSpecPill(
                              icon: Icons.router_rounded,
                              label: 'Gateway',
                              value: gwIp.isEmpty ? '-' : gwIp,
                              color: AppPalette.amber700,
                              bgColor: AppPalette.amber100,
                            ),
                            _buildSubnetSpecPill(
                              icon: Icons.location_on_rounded,
                              label: 'Sede / Location',
                              value: (selectedSubnet['location_label'] ?? '')
                                      .toString()
                                      .isNotEmpty
                                  ? (selectedSubnet['location_label'])
                                      .toString()
                                  : 'Sin Sede específica',
                              color: AppPalette.teal700,
                              bgColor: const Color(0xFFF0FDFA),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      // Leyenda de colores + Selector de sub-bloque /24 cuando la máscara es mayor (/23, /22, etc.)
                      Row(
                        children: [
                          Expanded(
                            child: Wrap(
                              spacing: 10,
                              runSpacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                _buildLegendDot(
                                  AppPalette.indigo100,
                                  const Color(0xFF4338CA),
                                  'DIR. RED ($networkAddress)',
                                ),
                                _buildLegendDot(
                                  const Color(0xFFFAE8FF),
                                  const Color(0xFFA21CAF),
                                  'BROADCAST ($broadcastAddress)',
                                ),
                                _buildLegendDot(
                                  AppPalette.amber100,
                                  AppPalette.amber500,
                                  'Gateway ($gwIp)',
                                ),
                                _buildLegendDot(
                                  AppPalette.sky100,
                                  AppPalette.sky600,
                                  'Ocupada (Heartbeat)',
                                ),
                                _buildLegendDot(
                                  AppPalette.green100,
                                  AppPalette.green600,
                                  'Ocupada (Servicio/VIP)',
                                ),
                                _buildLegendDot(
                                  AppPalette.slate50,
                                  AppPalette.slate300,
                                  'IP Libre Asignable',
                                ),
                              ],
                            ),
                          ),
                          if (subBlocks24.length > 1)
                            Wrap(
                              spacing: 6,
                              children: [
                                ChoiceChip(
                                  selected: activeBlockFilter == 'all',
                                  label: Text(
                                    'Toda la red /$prefixLen (${fullAddressList.length} IPs)',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  onSelected: (_) => _rebuildState(
                                    () => _selectedIpamSubBlock24 = 'all',
                                  ),
                                ),
                                ...subBlocks24.map((b24) {
                                  final isBlockSel = activeBlockFilter == b24;
                                  return ChoiceChip(
                                    selected: isBlockSel,
                                    label: Text(
                                      'Bloque $b24.x (256)',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                    onSelected: (_) => _rebuildState(
                                      () => _selectedIpamSubBlock24 = b24,
                                    ),
                                  );
                                }),
                              ],
                            ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: AppPalette.slate200),
                          ),
                          child: GridView.builder(
                            gridDelegate:
                                SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: multiOctetLabel ? 84 : 72,
                              mainAxisSpacing: 6,
                              crossAxisSpacing: 6,
                              childAspectRatio: multiOctetLabel ? 1.48 : 1.32,
                            ),
                            itemCount: displayedAddresses.length,
                            itemBuilder: (ctx, idx) {
                              final ipStr = displayedAddresses[idx];
                              final bool isNetworkAddr =
                                  ipStr == networkAddress && totalAddresses > 2;
                              final bool isBroadcastAddr =
                                  ipStr == broadcastAddress && totalAddresses > 2;
                              final bool isGw = ipStr == gwIp &&
                                  !isNetworkAddr &&
                                  !isBroadcastAddr;
                              final alloc = allocatedByIp[ipStr];
                              final bool isOccupied = alloc != null;
                              final bool isHb =
                                  alloc?['is_heartbeat_ip'] == true;

                              final parts = ipStr.split('.');
                              final String cellIpLabel =
                                  (multiOctetLabel && parts.length == 4)
                                      ? '.${parts[2]}.${parts[3]}'
                                      : (parts.isNotEmpty
                                          ? '.${parts.last}'
                                          : ipStr);

                              Color bg = AppPalette.slate50;
                              Color border = AppPalette.slate200;
                              Color txt = AppPalette.slate600;
                              String roleBadge = 'Libre';

                              if (isNetworkAddr) {
                                bg = AppPalette.indigo100;
                                border = const Color(0xFF4338CA);
                                txt = const Color(0xFF312E81);
                                roleBadge = 'DIR. RED';
                              } else if (isBroadcastAddr) {
                                bg = const Color(0xFFFAE8FF);
                                border = const Color(0xFFA21CAF);
                                txt = const Color(0xFF701A75);
                                roleBadge = 'BROADCAST';
                              } else if (isGw) {
                                bg = AppPalette.amber100;
                                border = AppPalette.amber500;
                                txt = AppPalette.amber800;
                                roleBadge = 'GATEWAY';
                              } else if (isOccupied) {
                                bg = isHb
                                    ? AppPalette.sky100
                                    : AppPalette.green100;
                                border = isHb
                                    ? AppPalette.sky600
                                    : AppPalette.green600;
                                txt = isHb
                                    ? const Color(0xFF075985)
                                    : const Color(0xFF14532D);
                                roleBadge =
                                    (alloc['asset_code'] ?? '').toString();
                              }

                              final String tooltipMsg = isNetworkAddr
                                  ? '$ipStr • DIRECCIÓN DE RED ($cidr)\nIdentificador de la subred (Todos los bits de host a 0). Reservada por protocolo IPv4; NO asignable a equipos.'
                                  : isBroadcastAddr
                                      ? '$ipStr • DIRECCIÓN DE BROADCAST ($cidr)\nDirección de difusión de la subred (Todos los bits de host a 1). Reservada por protocolo IPv4; NO asignable a equipos.'
                                      : isGw
                                          ? '$ipStr • PUERTA DE ENLACE (GATEWAY) DE LA SUBRED'
                                          : isOccupied
                                              ? '$ipStr • OCUPADA por ${alloc['asset_code']} (${alloc['asset_name']})\nRol: ${alloc['ip_role_label']} (${alloc['interface_name']})'
                                              : '$ipStr • IP LIBRE ASIGNABLE en $cidr (Clic para verificar en red o asignar)';

                              return Tooltip(
                                message: tooltipMsg,
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(6),
                                  onTap: () => _onTapIpamCell(
                                    ipStr: ipStr,
                                    subnet: selectedSubnet,
                                    allocated: alloc,
                                    isGateway: isGw,
                                    isNetworkAddress: isNetworkAddr,
                                    isBroadcastAddress: isBroadcastAddr,
                                  ),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: bg,
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: border,
                                        width: (isNetworkAddr ||
                                                isBroadcastAddr ||
                                                isGw ||
                                                isOccupied)
                                            ? 1.4
                                            : 1.0,
                                      ),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 2,
                                    ),
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          cellIpLabel,
                                          style: TextStyle(
                                            fontSize:
                                                multiOctetLabel ? 10.0 : 11.0,
                                            fontWeight: FontWeight.w900,
                                            fontFamily: 'monospace',
                                            color: txt,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        Text(
                                          roleBadge,
                                          style: TextStyle(
                                            fontSize: 8.0,
                                            fontWeight: (isNetworkAddr ||
                                                    isBroadcastAddr ||
                                                    isGw ||
                                                    isOccupied)
                                                ? FontWeight.w900
                                                : FontWeight.w600,
                                            color: txt,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildSubnetSpecPill({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
    Color? bgColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor ?? Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            '$label: ',
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              color: color.withValues(alpha: 0.85),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w900,
              fontFamily: 'monospace',
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLegendDot(Color bg, Color border, String text) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: border, width: 1.4),
          ),
        ),
        const SizedBox(width: 5),
        Text(
          text,
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppPalette.slate700,
          ),
        ),
      ],
    );
  }

  Widget _buildDetailInfoRow(String label, String value, {bool mono = false}) {
    if (value.trim().isEmpty || value == '-') return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 155,
            child: Text(
              '$label:',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: AppPalette.slate600,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(
                fontSize: 12,
                fontFamily: mono ? 'monospace' : null,
                fontWeight: mono ? FontWeight.w800 : FontWeight.w600,
                color: AppPalette.slate900,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onTapIpamCell({
    required String ipStr,
    required Map<String, dynamic> subnet,
    required Map<String, dynamic>? allocated,
    required bool isGateway,
    bool isNetworkAddress = false,
    bool isBroadcastAddress = false,
  }) {
    final int? assetId = allocated?['asset_id'] as int?;
    final int? ipId = allocated?['ip_id'] as int?;
    final Map<String, dynamic>? fullAsset = assetId != null
        ? _assets.cast<Map<String, dynamic>?>().firstWhere(
              (a) => a?['id'] == assetId,
              orElse: () => null,
            )
        : null;

    final String status =
        (fullAsset?['status'] ?? allocated?['status'] ?? 'unknown').toString();
    final double? pingMs = ((fullAsset?['last_ping_ms'] ?? allocated?['last_ping_ms']) as num?)
        ?.toDouble();
    final int cores = (fullAsset?['cpu_cores'] ?? allocated?['cpu_cores'] ?? 0) as int? ?? 0;
    final double ramGb =
        ((fullAsset?['ram_gb'] ?? allocated?['ram_gb']) as num?)?.toDouble() ?? 0.0;
    final double storageGb =
        ((fullAsset?['storage_gb'] ?? allocated?['storage_gb']) as num?)?.toDouble() ?? 0.0;
    final String resourcesStr = (cores > 0 || ramGb > 0 || storageGb > 0)
        ? '$cores vCPU • ${ramGb.toStringAsFixed(0)} GB RAM • ${storageGb.toStringAsFixed(0)} GB Disco'
        : '';
    final List<Map<String, dynamic>> allAssetIps =
        ((fullAsset?['ip_addresses'] as List?) ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(
              allocated != null
                  ? Icons.computer_rounded
                  : Icons.check_box_outline_blank_rounded,
              color: allocated != null
                  ? AppPalette.sky600
                  : AppPalette.green700,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                allocated != null
                    ? 'IP $ipStr — ${allocated['asset_code']} (${allocated['asset_name']})'
                    : 'Dirección IP $ipStr (${subnet['cidr']})',
                style: const TextStyle(
                  fontSize: 15.5,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isNetworkAddress)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppPalette.indigo100,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF4338CA)),
                    ),
                    child: Text(
                      'DIRECCIÓN DE RED (${subnet['cidr']} • Máscara ${subnet['subnet_mask']})\n\n'
                      'La dirección $ipStr es la Dirección de Red del bloque CIDR (todos los bits de host a 0). '
                      'Está reservada por el protocolo IPv4 para identificar la subred en las tablas de encaminamiento y NO debe asignarse a ninguna máquina.',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                        color: Color(0xFF312E81),
                      ),
                    ),
                  )
                else if (isBroadcastAddress)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFAE8FF),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFA21CAF)),
                    ),
                    child: Text(
                      'DIRECCIÓN DE BROADCAST (${subnet['cidr']} • Máscara ${subnet['subnet_mask']})\n\n'
                      'La dirección $ipStr es la Dirección de Difusión (Broadcast) del bloque CIDR (todos los bits de host a 1). '
                      'Está reservada por el protocolo IPv4 para enviar paquetes a todos los nodos de la subred y NO debe asignarse a ninguna máquina.',
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                        color: Color(0xFF701A75),
                      ),
                    ),
                  )
                else if (isGateway && allocated == null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppPalette.amber100,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppPalette.amber500),
                    ),
                    child: const Text(
                      'Esta IP es la Puerta de Enlace (Gateway) configurada para esta subred.',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  )
                else if (allocated != null) ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppPalette.slate50,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: AppPalette.slate300),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: status == 'online'
                                    ? AppPalette.green100
                                    : const Color(0xFFFEE2E2),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                status == 'online'
                                    ? 'ONLINE${pingMs != null ? ' (${pingMs.toStringAsFixed(1)} ms)' : ''}'
                                    : status.toUpperCase(),
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                  color: status == 'online'
                                      ? AppPalette.green700
                                      : AppPalette.red700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: AppPalette.sky100,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                (fullAsset?['asset_class_label'] ??
                                        allocated['asset_class_label'] ??
                                        allocated['asset_class'] ??
                                        'Equipo')
                                    .toString(),
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                  color: AppPalette.sky700,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const Divider(height: 18),
                        _buildDetailInfoRow(
                          'Código CMDB',
                          (allocated['asset_code'] ?? '').toString(),
                          mono: true,
                        ),
                        _buildDetailInfoRow(
                          'Nombre del Equipo',
                          (allocated['asset_name'] ?? '').toString(),
                        ),
                        _buildDetailInfoRow(
                          'Hostname',
                          (fullAsset?['hostname'] ?? allocated['hostname'] ?? '')
                              .toString(),
                          mono: true,
                        ),
                        _buildDetailInfoRow(
                          'FQDN / DNS',
                          (allocated['fqdn'] ?? fullAsset?['fqdn'] ?? '')
                              .toString(),
                          mono: true,
                        ),
                        _buildDetailInfoRow(
                          'Dirección IP Actual',
                          '$ipStr (${allocated['ip_role_label']})',
                          mono: true,
                        ),
                        _buildDetailInfoRow(
                          'Interfaz / VLAN',
                          '${allocated['interface_name'] ?? 'eth0'}${allocated['vlan_id'] != null ? ' • VLAN ${allocated['vlan_id']}' : ''}',
                          mono: true,
                        ),
                        _buildDetailInfoRow(
                          'MAC Address',
                          (allocated['mac_address'] ?? '').toString(),
                          mono: true,
                        ),
                        _buildDetailInfoRow(
                          'SO / Firmware / Puertos',
                          (fullAsset?['os_or_firmware'] ??
                                  allocated['os_or_firmware'] ??
                                  '')
                              .toString(),
                        ),
                        _buildDetailInfoRow('Recursos Hardware', resourcesStr),
                        _buildDetailInfoRow(
                          'Ubicación / Hipervisor',
                          (fullAsset?['physical_location_label'] ??
                                  fullAsset?['hypervisor_or_platform'] ??
                                  allocated['hypervisor_or_platform'] ??
                                  '')
                              .toString(),
                        ),
                        _buildDetailInfoRow(
                          'Entorno',
                          (fullAsset?['environment'] ??
                                  allocated['environment'] ??
                                  '')
                              .toString()
                              .toUpperCase(),
                        ),
                        _buildDetailInfoRow(
                          'Equipo / Responsable',
                          [
                            (fullAsset?['owner_team'] ??
                                    allocated['owner_team'] ??
                                    '')
                                .toString(),
                            (fullAsset?['responsible_person'] ??
                                    allocated['responsible_person'] ??
                                    '')
                                .toString(),
                          ].where((s) => s.trim().isNotEmpty).join(' • '),
                        ),
                        _buildDetailInfoRow(
                          'Notas',
                          (fullAsset?['notes'] ?? allocated['notes'] ?? '')
                              .toString(),
                        ),
                        if (allAssetIps.length > 1) ...[
                          const Divider(height: 16),
                          const Text(
                            'Todas las IPs configuradas en este equipo:',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                              color: AppPalette.slate700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: allAssetIps.map((ipItem) {
                              return Chip(
                                visualDensity: VisualDensity.compact,
                                label: Text(
                                  '${ipItem['ip_address']} (${ipItem['interface_name']} • ${ipItem['ip_role_label'] ?? ipItem['ip_role']})',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (widget.canEdit) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppPalette.red50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppPalette.red200),
                      ),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Icon(
                            Icons.cleaning_services_rounded,
                            size: 16,
                            color: AppPalette.red700,
                          ),
                          const Text(
                            '¿El equipo ya no está o quieres liberar esta IP?',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                              color: AppPalette.red800,
                            ),
                          ),
                          if (ipId != null)
                            OutlinedButton.icon(
                              onPressed: () async {
                                Navigator.pop(ctx);
                                await widget.api.deleteCmdbIp(ipId);
                                await _loadOverview(silent: true);
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    backgroundColor: AppPalette.green700,
                                    content: Text(
                                      'La IP $ipStr ha quedado marcada como NO OCUPADA (Libre) en el mapa IPAM.',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                );
                              },
                              style: OutlinedButton.styleFrom(
                                foregroundColor: AppPalette.red700,
                                side: const BorderSide(color: AppPalette.red300),
                                visualDensity: VisualDensity.compact,
                              ),
                              icon: const Icon(Icons.link_off_rounded, size: 15),
                              label: const Text(
                                'Dejar IP como No Ocupada (Liberar IP)',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          if (assetId != null)
                            FilledButton.icon(
                              onPressed: () async {
                                Navigator.pop(ctx);
                                await widget.api.deleteCmdbAsset(assetId);
                                await _loadOverview(silent: true);
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    backgroundColor: AppPalette.green700,
                                    content: Text(
                                      'Equipo ${allocated['asset_code']} eliminado e IP $ipStr marcada como NO OCUPADA (Libre).',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                );
                              },
                              style: FilledButton.styleFrom(
                                backgroundColor: AppPalette.red600,
                                visualDensity: VisualDensity.compact,
                              ),
                              icon: const Icon(
                                Icons.delete_forever_rounded,
                                size: 15,
                              ),
                              label: const Text(
                                'Quitar Equipo de CMDB y Liberar IP',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ] else
                  const Text(
                    'Esta dirección IP de host figura como LIBRE (No Ocupada) en la CMDB.\n'
                    'Puedes verificarla ahora en la red (Ping + Puertos TCP + ARP + DNS) o asignarla directamente a un equipo.',
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cerrar'),
          ),
          if (!isNetworkAddress && !isBroadcastAddress)
            OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _verifyIpCtrl.text = ipStr;
                _rebuildState(() => _activeTab = 'verifier');
                _runManualVerification(customIp: ipStr);
              },
              icon: const Icon(Icons.radar_rounded, size: 16),
              label: const Text('Verificar en Red'),
            ),
          if (allocated != null && assetId != null) ...[
            if (widget.canEdit && fullAsset != null)
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _openAssetEditorDialog(existing: fullAsset);
                },
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('Editar Equipo'),
              ),
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _rebuildState(() {
                  _classFilter = 'all';
                  _envFilter = 'all';
                  _onlyMultiIp = false;
                  _searchCtrl.clear();
                  _highlightedAssetId = assetId;
                  _expandedAssetId = assetId;
                  _activeTab = 'inventory';
                });
              },
              style: FilledButton.styleFrom(
                backgroundColor: AppPalette.blue900,
              ),
              icon: const Icon(Icons.table_rows_rounded, size: 16),
              label: const Text('Ir a su Casilla en Inventario CMDB'),
            ),
          ],
          if (widget.canEdit &&
              allocated == null &&
              !isGateway &&
              !isNetworkAddress &&
              !isBroadcastAddress) ...[
            FilledButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _openAssignVerifiedIpToExistingAssetDialog(
                  ipStr,
                  defaultSubnetId: subnet['id'] as int?,
                  defaultVlan: subnet['vlan_id'] as int?,
                  defaultGw: (subnet['gateway'] ?? '').toString(),
                );
              },
              icon: const Icon(Icons.add_link_rounded, size: 16),
              label: const Text('Asignar a Host Existente'),
            ),
            FilledButton.tonalIcon(
              onPressed: () {
                Navigator.pop(ctx);
                _openAssetEditorDialog(prefilledIp: ipStr);
              },
              icon: const Icon(Icons.add_box_outlined, size: 16),
              label: const Text('Nueva VM/Host'),
            ),
          ],
        ],
      ),
    );
  }
}
