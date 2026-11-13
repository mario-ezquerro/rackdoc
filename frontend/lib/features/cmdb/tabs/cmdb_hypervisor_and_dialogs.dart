part of '../cmdb_view.dart';

/// Pestaña 4 de `6. CMDB & Control IPs` (árbol Hipervisor Físico -> VMs),
/// diálogos CRUD de activos/IPs/subredes y utilidades de cálculo CIDR.
extension _CmdbHypervisorAndDialogsExt on _CmdbViewState {
  // ===========================================================================
  // PESTAÑA 4: TOPOLOGÍA HIPERVISORES FÍSICOS ➔ VMs, CONTENEDORES Y CLUSTERS
  // ===========================================================================
  Widget _buildHypervisorTreeTab() {
    final hosts = _physicalHosts.where((h) => h['category'] == 'server').toList();
    final standaloneAssets = _assets
        .where(
          (a) =>
              a['sync_source'] == 'cmdb' &&
              (a['host_rack_device_id'] == null),
        )
        .toList();

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Relación Hipervisores / Servidores Físicos del Rack ➔ Máquinas Virtuales, Contenedores y Clusters Alojados',
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w900,
            color: AppPalette.slate900,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Permite visualizar qué Máquinas Virtuales (VMs), Contenedores o Clusters dependen de cada servidor físico del Rack, además de las instancias Cloud o autónomas que no están en ningún rack.',
          style: TextStyle(fontSize: 12, color: AppPalette.slate600),
        ),
        const SizedBox(height: 14),
        ...hosts.map((h) {
          final int rDevId = h['rack_device_id'] as int;
          final hostedAssets = _assets
              .where(
                (a) =>
                    a['sync_source'] == 'cmdb' &&
                    a['host_rack_device_id'] == rDevId,
              )
              .toList();

          return Card(
            elevation: 0,
            margin: const EdgeInsets.only(bottom: 14),
            color: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: const BorderSide(color: AppPalette.slate300),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: AppPalette.teal700.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.dns_rounded,
                          color: AppPalette.teal700,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'HOST FÍSICO / HIPERVISOR: ${h['code']} — ${h['name']}',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            Text(
                              'Ubicación: Rack ${h['rack_code']} (U${h['start_u']}) • IP Gestión Host: ${h['ip_address']} • VMs/CIs alojados: ${hostedAssets.length}',
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: AppPalette.slate600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (widget.canEdit)
                        OutlinedButton.icon(
                          onPressed: () => _openAssetEditorDialog(
                            defaultHostRackDeviceId: rDevId,
                          ),
                          icon: const Icon(Icons.add, size: 15),
                          label: const Text(
                            'Crear VM / Contenedor en este Host',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (hostedAssets.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(left: 12),
                      child: Text(
                        'Sin máquinas virtuales vinculadas actualmente a este servidor físico.',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppPalette.slate500,
                        ),
                      ),
                    )
                  else
                    ...hostedAssets.map((vm) => _buildAssetCard(vm)),
                ],
              ),
            ),
          );
        }),
        const SizedBox(height: 10),
        Card(
          elevation: 0,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: AppPalette.slate300),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: AppPalette.indigo600.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.cloud_done_rounded,
                        color: AppPalette.indigo600,
                        size: 20,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'MÁQUINAS AUTÓNOMAS, CLOUD, CLUSTERS EXTERNOS Y OTROS CIs (Sin Rack Físico Local)',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          Text(
                            'Máquinas gestionadas directamente en la CMDB que corren en Cloud (AWS/Azure/GCP), clusters externos o sedes sin rack (${standaloneAssets.length} máquinas)',
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: AppPalette.slate600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (widget.canEdit)
                      OutlinedButton.icon(
                        onPressed: () => _openAssetEditorDialog(),
                        icon: const Icon(Icons.add, size: 15),
                        label: const Text(
                          'Añadir Máquina Autónoma / Cloud',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                ...standaloneAssets.map((vm) => _buildAssetCard(vm)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ===========================================================================
  // DIÁLOGOS DE CREACIÓN / EDICIÓN DE MÁQUINAS (CON MÚLTIPLES IPs) Y SUBREDES
  // ===========================================================================
  Future<void> _openAssignVerifiedIpToExistingAssetDialog(
    String ipAddress, {
    int? defaultSubnetId,
    int? defaultVlan,
    String defaultGw = '',
  }) async {
    if (_assets.isEmpty) return;
    int selectedAssetId = _assets.first['id'] as int;
    String selectedRole = 'primary_service';
    final ifaceCtrl = TextEditingController(text: 'eth1');
    final fqdnCtrl = TextEditingController();
    final notesCtrl = TextEditingController(
      text: 'Asignada tras verificación manual en CMDB',
    );
    bool isHb = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: Text('Asignar IP Libre ($ipAddress) a una Máquina de la CMDB'),
          content: SizedBox(
            width: 500,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int>(
                  initialValue: selectedAssetId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Seleccionar Máquina / Host / VM destino',
                    border: OutlineInputBorder(),
                  ),
                  items: _assets.map((a) {
                    return DropdownMenuItem<int>(
                      value: a['id'] as int,
                      child: Text(
                        '[${a['code']}] ${a['name']} (${a['asset_class_label']})',
                        overflow: TextOverflow.ellipsis,
                      ),
                    );
                  }).toList(),
                  onChanged: (v) {
                    if (v != null) setModalState(() => selectedAssetId = v);
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: selectedRole,
                  decoration: const InputDecoration(
                    labelText: 'Función / Rol de esta IP en la máquina',
                    border: OutlineInputBorder(),
                  ),
                  items: _CmdbViewState._ipRoleLabels.entries.map((e) {
                    return DropdownMenuItem<String>(
                      value: e.key,
                      child: Text(e.value),
                    );
                  }).toList(),
                  onChanged: (v) {
                    if (v != null) {
                      setModalState(() {
                        selectedRole = v;
                        if (v == 'mgmt_heartbeat') isHb = true;
                      });
                    }
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: ifaceCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Interfaz (ej. eth1, ens224, vip0)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: fqdnCtrl,
                        decoration: const InputDecoration(
                          labelText: 'FQDN / DNS específico de esta IP',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                CheckboxListTile(
                  value: isHb,
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Usar esta IP como IP principal de Gestión / Heartbeat de la máquina',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
                  ),
                  onChanged: (v) => setModalState(() => isHb = v ?? false),
                ),
                TextField(
                  controller: notesCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Notas',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
            FilledButton.icon(
              onPressed: () async {
                await widget.api.addCmdbAssetIp(selectedAssetId, {
                  'subnet_id': defaultSubnetId,
                  'ip_address': ipAddress,
                  'gateway': defaultGw,
                  'vlan_id': defaultVlan,
                  'ip_role': selectedRole,
                  'interface_name': ifaceCtrl.text.trim(),
                  'fqdn': fqdnCtrl.text.trim(),
                  'is_heartbeat_ip': isHb,
                  'notes': notesCtrl.text.trim(),
                });
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                await _loadOverview(silent: true);
              },
              icon: const Icon(Icons.check, size: 16),
              label: const Text('Asignar IP al Host'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openAddSingleIpDialog(Map<String, dynamic> asset) async {
    final ipCtrl = TextEditingController();
    final maskCtrl = TextEditingController(
      text: _primaryMaskOfAsset(asset).isNotEmpty
          ? _primaryMaskOfAsset(asset)
          : '255.255.255.0',
    );
    final ifaceCtrl = TextEditingController(
      text: 'eth${(asset['ip_count'] as int? ?? 1)}',
    );
    final fqdnCtrl = TextEditingController();
    final macCtrl = TextEditingController();
    final vlanCtrl = TextEditingController(text: '20');
    final gwCtrl = TextEditingController(text: '192.168.2.1');
    final notesCtrl = TextEditingController();
    String selectedRole = 'primary_service';
    bool isHb = false;
    bool enableAssetHeartbeat = asset['monitoring_enabled'] ?? true;
    Map<String, dynamic>? liveCheckResult;
    bool checkingNow = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: Text(
            'Añadir / Configurar IP en ${asset['code']} (${asset['name']})',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
          ),
          content: SizedBox(
            width: 580,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: ipCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Dirección IP (ej. 192.168.2.55)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: maskCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Máscara de Red (ej. 255.255.255.0)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: checkingNow
                            ? null
                            : () async {
                                final candidate = ipCtrl.text.trim();
                                if (candidate.isEmpty) return;
                                setModalState(() => checkingNow = true);
                                try {
                                  final r = await widget.api.verifyCmdbIp(
                                    targetIp: candidate,
                                  );
                                  final list = (r['results'] as List?) ?? [];
                                  if (list.isNotEmpty) {
                                    setModalState(() {
                                      liveCheckResult = Map<String, dynamic>.from(
                                        list.first as Map,
                                      );
                                    });
                                  }
                                } finally {
                                  setModalState(() => checkingNow = false);
                                }
                              },
                        icon: checkingNow
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.radar_rounded, size: 16),
                        label: const Text('Verificar IP'),
                      ),
                    ],
                  ),
                  if (liveCheckResult != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: liveCheckResult!['can_safely_assign'] == true
                            ? AppPalette.green50
                            : AppPalette.red50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: liveCheckResult!['can_safely_assign'] == true
                              ? AppPalette.green300
                              : AppPalette.red300,
                        ),
                      ),
                      child: Text(
                        '${liveCheckResult!['verdict_label']}\n${liveCheckResult!['summary']}',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: liveCheckResult!['can_safely_assign'] == true
                              ? const Color(0xFF14532D)
                              : AppPalette.red700,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: selectedRole,
                    decoration: const InputDecoration(
                      labelText:
                          'Diferenciar Tipo / Rol de la IP (Gestión/Heartbeat, Servicio, VIP, Storage, iDRAC...)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: _CmdbViewState._ipRoleLabels.entries.map((e) {
                      return DropdownMenuItem<String>(
                        value: e.key,
                        child: Text(e.value),
                      );
                    }).toList(),
                    onChanged: (v) {
                      if (v != null) {
                        setModalState(() {
                          selectedRole = v;
                          if (v == 'mgmt_heartbeat') isHb = true;
                        });
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: ifaceCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Interfaz (eth1, ens224, vip0...)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: vlanCtrl,
                          decoration: const InputDecoration(
                            labelText: 'VLAN ID',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: gwCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Gateway',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: fqdnCtrl,
                          decoration: const InputDecoration(
                            labelText: 'FQDN / DNS asociado a esta IP',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: macCtrl,
                          decoration: const InputDecoration(
                            labelText: 'MAC Address (opcional)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  CheckboxListTile(
                    value: isHb,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Usar esta IP como IP principal de Gestión / Heartbeat de la máquina',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    onChanged: (v) => setModalState(() => isHb = v ?? false),
                  ),
                  SwitchListTile(
                    value: enableAssetHeartbeat,
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Activar Heartbeat de la conexión para este equipo',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        color: AppPalette.sky700,
                      ),
                    ),
                    onChanged: (v) =>
                        setModalState(() => enableAssetHeartbeat = v),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: notesCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Notas de la interfaz / servicio',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
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
              onPressed: () async {
                final cleanIp = ipCtrl.text.trim();
                if (cleanIp.isEmpty) return;
                await widget.api.addCmdbAssetIp(asset['id'] as int, {
                  'ip_address': cleanIp,
                  'subnet_mask': maskCtrl.text.trim().isNotEmpty
                      ? maskCtrl.text.trim()
                      : '255.255.255.0',
                  'ip_role': selectedRole,
                  'interface_name': ifaceCtrl.text.trim(),
                  'vlan_id': int.tryParse(vlanCtrl.text.trim()),
                  'gateway': gwCtrl.text.trim(),
                  'fqdn': fqdnCtrl.text.trim(),
                  'mac_address': macCtrl.text.trim(),
                  'is_heartbeat_ip': isHb,
                  'notes': notesCtrl.text.trim(),
                });
                if (enableAssetHeartbeat !=
                    (asset['monitoring_enabled'] ?? true)) {
                  await widget.api.updateCmdbAsset(asset['id'] as int, {
                    'monitoring_enabled': enableAssetHeartbeat,
                  });
                }
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                await _loadOverview(silent: true);
              },
              icon: const Icon(Icons.save_rounded, size: 16),
              label: const Text('Guardar Nueva IP'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openAssetEditorDialog({
    Map<String, dynamic>? existing,
    String? prefilledIp,
    String? prefilledFqdn,
    String? prefilledMac,
    int? defaultHostRackDeviceId,
  }) async {
    final bool isEdit = existing != null;
    final codeCtrl = TextEditingController(
      text: (existing?['code'] ?? 'VM-APP-02').toString(),
    );
    final nameCtrl = TextEditingController(
      text: (existing?['name'] ?? '').toString(),
    );
    final hostCtrl = TextEditingController(
      text: (existing?['hostname'] ?? '').toString(),
    );
    final fqdnCtrl = TextEditingController(
      text: (existing?['fqdn'] ?? prefilledFqdn ?? '').toString(),
    );
    final osCtrl = TextEditingController(
      text: (existing?['os_or_firmware'] ?? 'Ubuntu Server 24.04 LTS').toString(),
    );
    final cpuCtrl = TextEditingController(
      text: '${existing?['cpu_cores'] ?? 8}',
    );
    final ramCtrl = TextEditingController(
      text: '${existing?['ram_gb'] ?? 32}',
    );
    final diskCtrl = TextEditingController(
      text: '${existing?['storage_gb'] ?? 250}',
    );
    final platCtrl = TextEditingController(
      text: (existing?['hypervisor_or_platform'] ?? 'VMware vSphere 8.0').toString(),
    );
    final existingCfInit = (existing?['custom_fields'] is Map)
        ? Map<String, dynamic>.from(existing!['custom_fields'] as Map)
        : <String, dynamic>{};
    final modelCtrl = TextEditingController(
      text: (existing?['model_name'] ?? existingCfInit['model_name'] ?? '').toString(),
    );
    final serialCtrl = TextEditingController(
      text: (existing?['serial_or_uuid'] ?? existingCfInit['serial_number'] ?? '').toString(),
    );
    final teamCtrl = TextEditingController(
      text: (existing?['owner_team'] ?? 'Sistemas & Virtualización').toString(),
    );
    final respCtrl = TextEditingController(
      text: (existing?['responsible_person'] ?? 'Alex Geng').toString(),
    );
    final notesCtrl = TextEditingController(
      text: (existing?['notes'] ?? '').toString(),
    );

    String assetClass =
        (existing?['asset_class'] ?? 'virtual_machine').toString();
    String environment = (existing?['environment'] ?? 'production').toString();
    String criticality = (existing?['criticality'] ?? 'high').toString();
    int? hostRackDeviceId =
        (existing?['host_rack_device_id'] as int?) ?? defaultHostRackDeviceId;
    int? selectedLocationId = existing?['location_id'] as int?;
    int? selectedFloorId = existing?['floor_id'] as int?;
    String? selectedFloorDeviceType =
        (existing?['floor_device_type'] ?? '').toString().trim().isNotEmpty
            ? (existing?['floor_device_type']).toString().trim()
            : null;
    bool monitoringEnabled = existing?['monitoring_enabled'] ?? true;
    String monitorMethod = (existing?['monitor_method'] ?? 'icmp').toString();
    final monitorPortCtrl = TextEditingController(
      text: '${existing?['monitor_port'] ?? 22}',
    );
    final rawCsCfg = (existing?['custom_fields'] is Map)
        ? (existing!['custom_fields'] as Map)['certscope_config']
        : null;
    final csCfg = rawCsCfg is Map
        ? Map<String, dynamic>.from(rawCsCfg)
        : <String, dynamic>{};
    bool certscopeEnabled = csCfg.containsKey('enabled')
        ? csCfg['enabled'] == true
        : (monitorMethod == 'https');
    final certscopePortCtrl = TextEditingController(
      text: '${csCfg['port'] ?? 443}',
    );
    String certscopeRenewalType =
        (csCfg['renewal_type'] ?? 'manual').toString() == 'auto_acme'
            ? 'auto_acme'
            : 'manual';
    bool probingCertNow = false;
    Map<String, dynamic> certProbeResult = Map<String, dynamic>.from(csCfg);

    List<Map<String, dynamic>> ipDrafts = [];
    if (isEdit && existing['ip_addresses'] is List) {
      ipDrafts = (existing['ip_addresses'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } else {
      ipDrafts = [
        {
          'ip_address': prefilledIp ?? '192.168.2.150',
          'subnet_mask': '255.255.255.0',
          'ip_role': 'mgmt_heartbeat',
          'interface_name': 'eth0 (Mgmt)',
          'vlan_id': 1,
          'gateway': '192.168.2.1',
          'fqdn': prefilledFqdn ?? '',
          'mac_address': prefilledMac ?? '',
          'is_heartbeat_ip': true,
          'notes': 'IP de Gestión / Heartbeat',
        },
      ];
    }

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => AlertDialog(
          title: Text(
            isEdit
                ? 'Editar Máquina / CI e Interfaces IP en CMDB: ${existing['code']}'
                : 'Alta en CMDB: Nueva Máquina Virtual, Contenedor, Cluster o Activo Multi-IP',
            style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w900),
          ),
          content: SizedBox(
            width: 860,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: codeCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Código CI (ej. VM-ERP-02, ROU-CORE-01)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: nameCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Nombre Descriptivo de la Máquina / Servicio',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButtonFormField<int?>(
                          initialValue: _locations.any(
                                    (l) => l['id'] == selectedLocationId,
                                  )
                              ? selectedLocationId
                              : null,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Sede / Location (Opcional)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: [
                            const DropdownMenuItem<int?>(
                              value: null,
                              child: Text('Sin Sede específica / Automática'),
                            ),
                            ..._locations.map((loc) {
                              return DropdownMenuItem<int?>(
                                value: loc['id'] as int,
                                child: Text(
                                  '${loc['code']} — ${loc['name']}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              );
                            }),
                          ],
                          onChanged: (v) =>
                              setModalState(() => selectedLocationId = v),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _CmdbViewState._assetClassLabels.containsKey(assetClass)
                              ? assetClass
                              : 'virtual_machine',
                          decoration: const InputDecoration(
                            labelText: 'Tipo / Clase de Máquina',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: _CmdbViewState._assetClassLabels.entries.map((e) {
                            return DropdownMenuItem<String>(
                              value: e.key,
                              child: Text(e.value),
                            );
                          }).toList(),
                          onChanged: (v) {
                            if (v != null) {
                              setModalState(() {
                                assetClass = v;
                                if (v == 'floor_endpoint') {
                                  selectedFloorDeviceType ??= 'printer';
                                  if (selectedFloorId == null &&
                                      _floors.isNotEmpty) {
                                    final locFloor = _floors
                                        .where(
                                          (fl) =>
                                              fl['location_id'] ==
                                              selectedLocationId,
                                        )
                                        .firstOrNull;
                                    selectedFloorId =
                                        (locFloor?['id'] ?? _floors.first['id'])
                                            as int?;
                                  }
                                }
                              });
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButtonFormField<int?>(
                          initialValue: _physicalHosts.any(
                                    (h) =>
                                        h['rack_device_id'] ==
                                        hostRackDeviceId,
                                  )
                              ? hostRackDeviceId
                              : null,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText:
                                'Servidor Físico Padre / Hipervisor en Rack (Opcional)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: [
                            const DropdownMenuItem<int?>(
                              value: null,
                              child: Text(
                                'Autónoma / Cloud / Sin Host Físico en Rack',
                              ),
                            ),
                            ..._physicalHosts.map((h) {
                              return DropdownMenuItem<int?>(
                                value: h['rack_device_id'] as int,
                                child: Text(
                                  '${h['code']} (${h['name']}) — Rack ${h['rack_code']} U${h['start_u']}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              );
                            }),
                          ],
                          onChanged: (v) =>
                              setModalState(() => hostRackDeviceId = v),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // SECCIÓN DE ALINEACIÓN CON DATACENTER (PLANTAS): IMPRESORA, CÁMARA, WI-FI AP, PC...
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: (selectedFloorDeviceType != null ||
                              selectedFloorId != null ||
                              assetClass == 'floor_endpoint')
                          ? const Color(0xFFF0FDF4)
                          : AppPalette.slate50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: (selectedFloorDeviceType != null ||
                                selectedFloorId != null ||
                                assetClass == 'floor_endpoint')
                            ? const Color(0xFF86EFAC)
                            : AppPalette.slate300,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(
                              Icons.print_rounded,
                              size: 15,
                              color: AppPalette.teal700,
                            ),
                            SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                'Alineación con 2. Datacenter (Plantas): Indicar si este equipo es Impresora, Cámara, Wi-Fi AP, PC o Sensor en Planta (Mismo elemento)',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w900,
                                  color: AppPalette.slate900,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: DropdownButtonFormField<String?>(
                                initialValue: selectedFloorDeviceType != null &&
                                        _CmdbViewState._floorDeviceTypeLabels.containsKey(
                                          selectedFloorDeviceType,
                                        )
                                    ? selectedFloorDeviceType
                                    : null,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText:
                                      'Tipo de Dispositivo en Planta (ej. Impresora, Cámara, Wi-Fi...)',
                                  filled: true,
                                  fillColor: Colors.white,
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                                items: [
                                  const DropdownMenuItem<String?>(
                                    value: null,
                                    child: Text(
                                      '— No es dispositivo de planta (VM / Rack / Cloud) —',
                                    ),
                                  ),
                                  ..._CmdbViewState._floorDeviceTypeLabels.entries.map(
                                    (e) => DropdownMenuItem<String?>(
                                      value: e.key,
                                      child: Text(e.value),
                                    ),
                                  ),
                                ],
                                onChanged: (val) {
                                  setModalState(() {
                                    selectedFloorDeviceType = val;
                                    if (val != null) {
                                      assetClass = 'floor_endpoint';
                                      final lbl =
                                          _CmdbViewState._floorDeviceTypeLabels[val] ?? val;
                                      osCtrl.text = 'Endpoint ($lbl)';
                                      if (nameCtrl.text
                                          .trim()
                                          .startsWith('Equipo Detectado')) {
                                        final h = hostCtrl.text.trim().isNotEmpty
                                            ? hostCtrl.text.trim()
                                            : (ipDrafts.isNotEmpty
                                                  ? (ipDrafts.first['ip_address'] ??
                                                            '')
                                                        .toString()
                                                  : '');
                                        nameCtrl.text =
                                            '${lbl.split('(').first.trim()} • $h';
                                      }
                                      if (selectedFloorId == null &&
                                          _floors.isNotEmpty) {
                                        final locFloor = _floors
                                            .where(
                                              (fl) =>
                                                  fl['location_id'] ==
                                                  selectedLocationId,
                                            )
                                            .firstOrNull;
                                        selectedFloorId = (locFloor?['id'] ??
                                            _floors.first['id']) as int?;
                                      }
                                    }
                                  });
                                },
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: DropdownButtonFormField<int?>(
                                initialValue: _floors.any(
                                          (fl) => fl['id'] == selectedFloorId,
                                        )
                                    ? selectedFloorId
                                    : null,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText:
                                      'Planta del Datacenter donde ubicarlo (Plano 2D)',
                                  filled: true,
                                  fillColor: Colors.white,
                                  border: OutlineInputBorder(),
                                  isDense: true,
                                ),
                                items: [
                                  const DropdownMenuItem<int?>(
                                    value: null,
                                    child: Text('— Sin planta asignada —'),
                                  ),
                                  ..._floors.map(
                                    (fl) => DropdownMenuItem<int?>(
                                      value: fl['id'] as int,
                                      child: Text(
                                        (fl['label'] ?? fl['name'] ?? '')
                                            .toString(),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                ],
                                onChanged: (val) {
                                  setModalState(() {
                                    selectedFloorId = val;
                                    if (val != null) {
                                      assetClass = 'floor_endpoint';
                                      selectedFloorDeviceType ??= 'printer';
                                      final flObj = _floors
                                          .where((f) => f['id'] == val)
                                          .firstOrNull;
                                      if (flObj != null &&
                                          flObj['location_id'] != null) {
                                        selectedLocationId =
                                            flObj['location_id'] as int;
                                      }
                                    }
                                  });
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: hostCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Hostname',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: fqdnCtrl,
                          decoration: const InputDecoration(
                            labelText: 'FQDN Principal',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: environment,
                          decoration: const InputDecoration(
                            labelText: 'Entorno',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'production',
                              child: Text('Producción'),
                            ),
                            DropdownMenuItem(
                              value: 'preprod',
                              child: Text('Preproducción'),
                            ),
                            DropdownMenuItem(
                              value: 'dev',
                              child: Text('Desarrollo'),
                            ),
                            DropdownMenuItem(
                              value: 'mgmt',
                              child: Text('Gestión'),
                            ),
                            DropdownMenuItem(
                              value: 'dr',
                              child: Text('Contingencia DR'),
                            ),
                          ],
                          onChanged: (v) {
                            if (v != null) setModalState(() => environment = v);
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: osCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Sistema Operativo / Firmware',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: cpuCtrl,
                          decoration: const InputDecoration(
                            labelText: 'vCPUs / Cores',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: ramCtrl,
                          decoration: const InputDecoration(
                            labelText: 'RAM (GB)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: diskCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Disco (GB)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: platCtrl,
                          decoration: const InputDecoration(
                            labelText:
                                'Plataforma (VMware, Proxmox, K8s, AWS, Hyper-V)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: teamCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Equipo Propietario',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: respCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Persona Responsable',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: modelCtrl,
                          decoration: const InputDecoration(
                            labelText:
                                'Marca / Modelo del Equipo Físico o Servidor (ej. Dell PowerEdge R760, HPE DL380, Cisco C9300)',
                            prefixIcon: Icon(Icons.memory_rounded, size: 17),
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: serialCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Número de Serie (S/N) / Service Tag / UUID',
                            prefixIcon: Icon(Icons.qr_code_2_rounded, size: 17),
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: monitoringEnabled
                          ? AppPalette.green50
                          : AppPalette.slate50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: monitoringEnabled
                            ? AppPalette.green300
                            : AppPalette.slate300,
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: SwitchListTile(
                            value: monitoringEnabled,
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: const Text(
                              'Activar Heartbeat de la Conexión (Monitorización continua sobre la IP marcada como ★ Heartbeat)',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            onChanged: (v) =>
                                setModalState(() => monitoringEnabled = v),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 150,
                          child: DropdownButtonFormField<String>(
                            initialValue: monitorMethod,
                            decoration: const InputDecoration(
                              labelText: 'Método Heartbeat',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                            items: const [
                              DropdownMenuItem(value: 'icmp', child: Text('ICMP Ping')),
                              DropdownMenuItem(value: 'ssh', child: Text('SSH')),
                              DropdownMenuItem(value: 'https', child: Text('HTTPS')),
                              DropdownMenuItem(value: 'http', child: Text('HTTP')),
                              DropdownMenuItem(value: 'tcp', child: Text('TCP Puerto')),
                              DropdownMenuItem(value: 'snmp', child: Text('SNMP')),
                            ],
                            onChanged: (v) {
                              if (v != null) {
                                setModalState(() => monitorMethod = v);
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 90,
                          child: TextField(
                            controller: monitorPortCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Puerto',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: certscopeEnabled
                          ? AppPalette.blue50
                          : AppPalette.slate50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: certscopeEnabled
                            ? AppPalette.blue300
                            : AppPalette.slate300,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: SwitchListTile(
                                value: certscopeEnabled,
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: const Text(
                                  '3ª Gestión (7. CertScope): Verificar y controlar caducidad de Certificado HTTPS/TLS',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w900,
                                    color: AppPalette.blue900,
                                  ),
                                ),
                                subtitle: const Text(
                                  'Conecta este activo CMDB con 7. CertScope y analiza automáticamente su certificado X.509',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: AppPalette.slate600,
                                  ),
                                ),
                                onChanged: (v) =>
                                    setModalState(() => certscopeEnabled = v),
                              ),
                            ),
                            if (certscopeEnabled) ...[
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 100,
                                child: TextField(
                                  controller: certscopePortCtrl,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: 'Puerto TLS',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 175,
                                child: DropdownButtonFormField<String>(
                                  initialValue: certscopeRenewalType,
                                  decoration: const InputDecoration(
                                    labelText: 'Renovación Certificado',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: 'manual',
                                      child: Text('Manual (Avisar)'),
                                    ),
                                    DropdownMenuItem(
                                      value: 'auto_acme',
                                      child: Text('Automática ACME'),
                                    ),
                                  ],
                                  onChanged: (v) {
                                    if (v != null) {
                                      setModalState(
                                        () => certscopeRenewalType = v,
                                      );
                                    }
                                  },
                                ),
                              ),
                              const SizedBox(width: 8),
                              FilledButton.tonalIcon(
                                onPressed: probingCertNow
                                    ? null
                                    : () async {
                                        final primaryIp = ipDrafts.isNotEmpty
                                            ? (ipDrafts.first['ip_address'] ??
                                                      '')
                                                  .toString()
                                                  .trim()
                                            : '';
                                        final target = primaryIp.isNotEmpty
                                            ? primaryIp
                                            : fqdnCtrl.text.trim();
                                        if (target.isEmpty) return;
                                        setModalState(
                                          () => probingCertNow = true,
                                        );
                                        try {
                                          final res = await widget.api
                                              .probeCertificate({
                                                'target_host': target,
                                                'port':
                                                    int.tryParse(
                                                      certscopePortCtrl.text
                                                          .trim(),
                                                    ) ??
                                                    443,
                                                'sni_hostname': fqdnCtrl.text
                                                    .trim(),
                                              });
                                          setModalState(() {
                                            probingCertNow = false;
                                            if (res['port'] != null) {
                                              certscopePortCtrl.text = '${res['port']}';
                                            }
                                            certProbeResult = {
                                              ...certProbeResult,
                                              'port': res['port'],
                                              'detected_service': res['detected_service'] ?? '',
                                              'status':
                                                  res['status'] ??
                                                  (res['ok'] == true
                                                      ? 'valid'
                                                      : 'unreachable'),
                                              'days_remaining':
                                                  res['days_remaining'],
                                              'common_name':
                                                  res['common_name'] ?? '',
                                              'issuer_cn':
                                                  res['issuer_cn'] ?? '',
                                              'valid_until':
                                                  res['valid_until'] ?? '',
                                              'last_error': res['error'] ?? '',
                                            };
                                          });
                                        } catch (e) {
                                          setModalState(() {
                                            probingCertNow = false;
                                            certProbeResult = {
                                              'last_error': '$e',
                                            };
                                          });
                                        }
                                      },
                                icon: probingCertNow
                                    ? const SizedBox(
                                        width: 13,
                                        height: 13,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(
                                        Icons.sync_lock_rounded,
                                        size: 15,
                                      ),
                                label: const Text('Analizar HTTPS'),
                              ),
                            ],
                          ],
                        ),
                        if (certscopeEnabled &&
                            ((certProbeResult['common_name'] ?? '')
                                    .toString()
                                    .isNotEmpty ||
                                (certProbeResult['last_error'] ?? '')
                                    .toString()
                                    .isNotEmpty)) ...[
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: AppPalette.blue300),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  (certProbeResult['status'] == 'valid')
                                      ? Icons.verified_user_rounded
                                      : Icons.info_outline_rounded,
                                  size: 15,
                                  color: (certProbeResult['status'] == 'valid')
                                      ? AppPalette.green700
                                      : AppPalette.amber700,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    (certProbeResult['common_name'] ?? '')
                                            .toString()
                                            .isNotEmpty
                                        ? 'Certificado X.509: CN=${certProbeResult['common_name']} · Emisor=${certProbeResult['issuer_cn']} · Vence=${(certProbeResult['valid_until'] ?? '').toString().split('T').first} (${certProbeResult['days_remaining'] ?? '?'} días)'
                                        : 'Aviso TLS: ${certProbeResult['last_error']}',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: AppPalette.slate800,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const Divider(height: 22),
                  Row(
                    children: [
                      const Icon(
                        Icons.lan_rounded,
                        size: 18,
                        color: AppPalette.blue900,
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'Direcciones IP y Máscaras de Red (Diferenciar IP de Gestión/Heartbeat vs IPs de Servicio/VIP/iDRAC)',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () {
                          setModalState(() {
                            ipDrafts.add({
                              'ip_address': '',
                              'subnet_mask': '255.255.255.0',
                              'ip_role': 'secondary_service',
                              'interface_name': 'eth${ipDrafts.length}',
                              'vlan_id': 20,
                              'gateway': '192.168.2.1',
                              'fqdn': '',
                              'mac_address': '',
                              'is_heartbeat_ip': false,
                              'notes': '',
                            });
                          });
                        },
                        icon: const Icon(Icons.add, size: 15),
                        label: const Text('Añadir otra Interfaz / IP'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ...ipDrafts.asMap().entries.map((entry) {
                    final idx = entry.key;
                    final item = entry.value;
                    final bool isHb = item['is_heartbeat_ip'] == true;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isHb
                            ? AppPalette.sky50
                            : AppPalette.slate50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isHb
                              ? AppPalette.sky400
                              : AppPalette.slate300,
                        ),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                flex: 2,
                                child: TextFormField(
                                  initialValue:
                                      (item['ip_address'] ?? '').toString(),
                                  decoration: const InputDecoration(
                                    labelText: 'Dirección IP',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  onChanged: (v) => item['ip_address'] = v,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                flex: 2,
                                child: TextFormField(
                                  initialValue:
                                      (item['subnet_mask'] ?? '255.255.255.0')
                                          .toString(),
                                  decoration: const InputDecoration(
                                    labelText: 'Máscara de Red',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  onChanged: (v) => item['subnet_mask'] = v,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                flex: 3,
                                child: DropdownButtonFormField<String>(
                                  initialValue:
                                      _CmdbViewState._ipRoleLabels.containsKey(item['ip_role'])
                                          ? item['ip_role'] as String
                                          : 'primary_service',
                                  decoration: const InputDecoration(
                                    labelText: 'Rol / Diferenciación de IP',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  items: _CmdbViewState._ipRoleLabels.entries.map((e) {
                                    return DropdownMenuItem<String>(
                                      value: e.key,
                                      child: Text(
                                        e.value,
                                        style: const TextStyle(fontSize: 11.5),
                                      ),
                                    );
                                  }).toList(),
                                  onChanged: (v) {
                                    if (v != null) {
                                      setModalState(() => item['ip_role'] = v);
                                    }
                                  },
                                ),
                              ),
                              const SizedBox(width: 6),
                              Tooltip(
                                message:
                                    'Marcar esta IP como la IP principal de Gestión / Heartbeat de la conexión',
                                child: InkWell(
                                  onTap: () {
                                    setModalState(() {
                                      for (final d in ipDrafts) {
                                        d['is_heartbeat_ip'] = false;
                                      }
                                      item['is_heartbeat_ip'] = true;
                                    });
                                  },
                                  child: Chip(
                                    backgroundColor: isHb
                                        ? AppPalette.sky600
                                        : AppPalette.slate200,
                                    label: Text(
                                      isHb ? '★ Heartbeat ON' : 'Marcar Heartbeat',
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w800,
                                        color: isHb
                                            ? Colors.white
                                            : AppPalette.slate600,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              if (ipDrafts.length > 1)
                                IconButton(
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 18,
                                    color: Colors.redAccent,
                                  ),
                                  onPressed: () {
                                    setModalState(() => ipDrafts.removeAt(idx));
                                  },
                                ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Expanded(
                                child: TextFormField(
                                  initialValue:
                                      (item['interface_name'] ?? '').toString(),
                                  decoration: const InputDecoration(
                                    labelText: 'Interfaz (eth0...)',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  onChanged: (v) => item['interface_name'] = v,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: TextFormField(
                                  initialValue:
                                      (item['gateway'] ?? '').toString(),
                                  decoration: const InputDecoration(
                                    labelText: 'Gateway',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  onChanged: (v) => item['gateway'] = v,
                                ),
                              ),
                              const SizedBox(width: 6),
                              SizedBox(
                                width: 85,
                                child: TextFormField(
                                  initialValue:
                                      '${item['vlan_id'] ?? ''}',
                                  decoration: const InputDecoration(
                                    labelText: 'VLAN',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  onChanged: (v) =>
                                      item['vlan_id'] = int.tryParse(v.trim()),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                flex: 2,
                                child: TextFormField(
                                  initialValue: (item['fqdn'] ?? '').toString(),
                                  decoration: const InputDecoration(
                                    labelText: 'FQDN / DNS de esta IP',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  onChanged: (v) => item['fqdn'] = v,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                flex: 2,
                                child: TextFormField(
                                  initialValue:
                                      (item['mac_address'] ?? '').toString(),
                                  decoration: const InputDecoration(
                                    labelText: 'MAC Address',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  onChanged: (v) => item['mac_address'] = v,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 8),
                  TextField(
                    controller: notesCtrl,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Notas técnicas / Aplicaciones / Observaciones CMDB',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
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
              onPressed: () async {
                final existingCf = Map<String, dynamic>.from(
                  (existing?['custom_fields'] as Map?) ?? {},
                );
                if (selectedLocationId != null) {
                  existingCf['location_id'] = selectedLocationId;
                } else {
                  existingCf.remove('location_id');
                }
                if (modelCtrl.text.trim().isNotEmpty) {
                  existingCf['model_name'] = modelCtrl.text.trim();
                } else {
                  existingCf.remove('model_name');
                }
                if (serialCtrl.text.trim().isNotEmpty) {
                  existingCf['serial_number'] = serialCtrl.text.trim();
                } else {
                  existingCf.remove('serial_number');
                }

                final validIps = ipDrafts
                    .where(
                      (d) =>
                          (d['ip_address'] ?? '').toString().trim().isNotEmpty,
                    )
                    .toList();

                // Comprobar si alguna de las IPs colisiona con otro equipo (ej. montado en Rack Editor)
                for (final d in validIps) {
                  final candidateIp =
                      (d['ip_address'] ?? '').toString().trim();
                  final checkRes = await widget.api.checkCmdbIpOwner(
                    ip: candidateIp,
                    excludeAssetId: isEdit ? existing['id'] as int : null,
                  );
                  if (checkRes['has_collision'] == true) {
                    final owners = (checkRes['owners'] as List?) ?? [];
                    if (owners.isNotEmpty && ctx.mounted) {
                      final owner = Map<String, dynamic>.from(
                        owners.first as Map,
                      );
                      final String? choice = await showDialog<String>(
                        context: ctx,
                        builder: (dCtx) => AlertDialog(
                          title: Row(
                            children: [
                              const Icon(
                                Icons.warning_amber_rounded,
                                color: AppPalette.red700,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Colisión de IP Detectada ($candidateIp)',
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          content: Text(
                            'La dirección IP $candidateIp ya está asignada a:\n'
                            '• [${owner['code']}] ${owner['name']} (${owner['physical_location_label']})\n\n'
                            '¿Cómo deseas proceder?',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(dCtx, 'cancel'),
                              child: const Text('Cancelar y cambiar IP'),
                            ),
                            OutlinedButton(
                              onPressed: () => Navigator.pop(dCtx, 'save_anyway'),
                              child: const Text('Guardar igualmente'),
                            ),
                            FilledButton.icon(
                              style: FilledButton.styleFrom(
                                backgroundColor: AppPalette.green700,
                              ),
                              onPressed: () => Navigator.pop(dCtx, 'merge'),
                              icon: const Icon(
                                Icons.merge_type_rounded,
                                size: 16,
                              ),
                              label: const Text(
                                'Es el mismo equipo: Unificar con existente',
                              ),
                            ),
                          ],
                        ),
                      );
                      if (choice == 'cancel' || choice == null) {
                        return;
                      }
                      if (choice == 'merge') {
                        if (isEdit) {
                          final updated =
                              await widget.api.resolveCmdbIpCollision({
                            'ip_address': candidateIp,
                            'action': 'merge',
                            'keep_asset_id': owner['id'],
                            'other_asset_id': existing['id'],
                            'preferred_name': nameCtrl.text.trim(),
                            'preferred_hostname': hostCtrl.text.trim(),
                            'preferred_fqdn': fqdnCtrl.text.trim(),
                          });
                          if (!ctx.mounted) return;
                          Navigator.pop(ctx);
                          _rebuildState(() => _overview = updated);
                          return;
                        } else {
                          await widget.api.updateCmdbAsset(
                            owner['id'] as int,
                            {
                              if (nameCtrl.text.trim().isNotEmpty)
                                'name': nameCtrl.text.trim(),
                              if (hostCtrl.text.trim().isNotEmpty)
                                'hostname': hostCtrl.text.trim(),
                              if (fqdnCtrl.text.trim().isNotEmpty)
                                'fqdn': fqdnCtrl.text.trim(),
                              'monitoring_enabled': monitoringEnabled,
                              'monitor_method': monitorMethod,
                              'monitor_port':
                                  int.tryParse(monitorPortCtrl.text.trim()) ??
                                      22,
                            },
                          );
                          if (!ctx.mounted) return;
                          Navigator.pop(ctx);
                          await _loadOverview(silent: true);
                          return;
                        }
                      }
                    }
                  }
                }

                final payload = {
                  'code': codeCtrl.text.trim(),
                  'name': nameCtrl.text.trim(),
                  'hostname': hostCtrl.text.trim(),
                  'fqdn': fqdnCtrl.text.trim(),
                  'asset_class': assetClass,
                  'environment': environment,
                  'criticality': criticality,
                  'os_or_firmware': osCtrl.text.trim(),
                  'cpu_cores': int.tryParse(cpuCtrl.text.trim()) ?? 0,
                  'ram_gb': double.tryParse(ramCtrl.text.trim()) ?? 0.0,
                  'storage_gb': double.tryParse(diskCtrl.text.trim()) ?? 0.0,
                  'hypervisor_or_platform': platCtrl.text.trim(),
                  'model_name': modelCtrl.text.trim(),
                  'serial_or_uuid': serialCtrl.text.trim(),
                  'owner_team': teamCtrl.text.trim(),
                  'responsible_person': respCtrl.text.trim(),
                  'host_rack_device_id': hostRackDeviceId,
                  'floor_id': selectedFloorId,
                  'floor_device_type': selectedFloorDeviceType,
                  'monitoring_enabled': monitoringEnabled,
                  'monitor_method': monitorMethod,
                  'monitor_port': int.tryParse(monitorPortCtrl.text.trim()) ?? 22,
                  'certscope_enabled': certscopeEnabled,
                  'certscope_port': int.tryParse(certscopePortCtrl.text.trim()) ?? 443,
                  'certscope_renewal_type': certscopeRenewalType,
                  'custom_fields': existingCf,
                  'notes': notesCtrl.text.trim(),
                  'ip_addresses': validIps,
                };
                try {
                  if (isEdit) {
                    await widget.api.updateCmdbAsset(
                      existing['id'] as int,
                      payload,
                    );
                  } else {
                    await widget.api.createCmdbAsset(payload);
                  }
                  if (!ctx.mounted) return;
                  Navigator.pop(ctx);
                  await _loadOverview(silent: true);
                } catch (e) {
                  if (!ctx.mounted) return;
                  ScaffoldMessenger.of(ctx).aviso('Error guardando en CMDB: $e');
                }
              },
              icon: const Icon(Icons.save_rounded, size: 16),
              label: Text(isEdit ? 'Guardar Cambios' : 'Crear Máquina en CMDB'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDeleteAsset(Map<String, dynamic> asset) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('¿Eliminar ${asset['code']} de la CMDB?'),
        content: Text(
          'Se dará de baja "${asset['name']}" y todas sus direcciones IP quedarán liberadas en la CMDB.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.api.deleteCmdbAsset(asset['id'] as int);
      await _loadOverview(silent: true);
    }
  }

  Future<void> _openCreateSubnetDialog({
    Map<String, dynamic>? existing,
  }) async {
    final bool isEdit = existing != null;
    final cidrCtrl = TextEditingController(
      text: (existing?['cidr'] ?? '10.20.40.0/24').toString(),
    );
    final nameCtrl = TextEditingController(
      text: (existing?['name'] ?? 'VLAN 40 — Nueva Red de Servicios').toString(),
    );
    final vlanCtrl = TextEditingController(
      text: (existing?['vlan_id'] ?? '40').toString(),
    );
    final gwCtrl = TextEditingController(
      text: (existing?['gateway'] ?? '10.20.40.1').toString(),
    );
    final dnsCtrl = TextEditingController(
      text: (existing?['dns_servers'] ?? '10.20.1.5').toString(),
    );
    final notesCtrl = TextEditingController(
      text: (existing?['notes'] ?? '').toString(),
    );
    String env = (existing?['environment'] ?? 'production').toString();
    int? selectedLocationId = existing?['location_id'] as int?;
    bool userEditedGateway = isEdit;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          final parsed = _ParsedCidrBlock.tryParse(cidrCtrl.text.trim());
          return AlertDialog(
            title: Text(
              isEdit
                  ? 'Editar Subred / VLAN (${existing['cidr']})'
                  : 'Registrar Nueva Subred / VLAN en IPAM',
            ),
            content: SizedBox(
              width: 540,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: cidrCtrl,
                      onChanged: (val) {
                        final p = _ParsedCidrBlock.tryParse(val.trim());
                        setModalState(() {
                          if (p != null && !userEditedGateway) {
                            gwCtrl.text = p.firstUsableIp;
                          }
                        });
                      },
                      decoration: const InputDecoration(
                        labelText:
                            'Bloque CIDR con su máscara (ej. 10.20.40.0/23, 10.20.40.0/24, 192.168.1.128/25)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (parsed != null)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppPalette.sky50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFF7DD3FC)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Cálculo automático por máscara /${parsed.prefixLen} (${parsed.subnetMask}):',
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w900,
                                color: AppPalette.sky900,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '• Red normalizada: ${parsed.canonicalCidr}\n'
                              '• Dirección de Red (No asignable): ${parsed.networkAddress}\n'
                              '• Dirección de Broadcast (No asignable): ${parsed.broadcastAddress}\n'
                              '• Rango de IPs útiles: ${parsed.firstUsableIp} a ${parsed.lastUsableIp} (${parsed.totalUsable} hosts útiles / ${parsed.totalAddresses} totales)',
                              style: const TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                                fontWeight: FontWeight.w700,
                                color: AppPalette.sky700,
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      const Text(
                        'Introduce un bloque CIDR válido (por ejemplo 10.20.40.0/23 o 192.168.10.0/24).',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.redAccent,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Nombre Descriptivo de la Subred / VLAN',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<int?>(
                      initialValue: _locations.any(
                                (l) => l['id'] == selectedLocationId,
                              )
                          ? selectedLocationId
                          : null,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText:
                            'Sede / Location asociada al rango de IPs (Opcional)',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: Text(
                            'Sin Sede específica (Global / Multi-sede)',
                          ),
                        ),
                        ..._locations.map((loc) {
                          return DropdownMenuItem<int?>(
                            value: loc['id'] as int,
                            child: Text(
                              '${loc['code']} — ${loc['name']}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        }),
                      ],
                      onChanged: (v) =>
                          setModalState(() => selectedLocationId = v),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: vlanCtrl,
                            decoration: const InputDecoration(
                              labelText: 'VLAN ID',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: gwCtrl,
                            onChanged: (_) => userEditedGateway = true,
                            decoration: const InputDecoration(
                              labelText: 'Gateway de la Subred',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: dnsCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Servidores DNS',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: notesCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Notas',
                        border: OutlineInputBorder(),
                      ),
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
                onPressed: parsed == null
                    ? null
                    : () async {
                        final payload = {
                          'cidr': parsed.canonicalCidr,
                          'subnet_mask': parsed.subnetMask,
                          'name': nameCtrl.text.trim(),
                          'vlan_id': int.tryParse(vlanCtrl.text.trim()),
                          'location_id': selectedLocationId,
                          'gateway': gwCtrl.text.trim().isNotEmpty
                              ? gwCtrl.text.trim()
                              : parsed.firstUsableIp,
                          'dns_servers': dnsCtrl.text.trim(),
                          'environment': env,
                          'notes': notesCtrl.text.trim(),
                        };
                        try {
                          if (isEdit) {
                            await widget.api.updateCmdbSubnet(
                              existing['id'] as int,
                              payload,
                            );
                          } else {
                            await widget.api.createCmdbSubnet(payload);
                          }
                          if (!ctx.mounted) return;
                          Navigator.pop(ctx);
                          _rebuildState(() => _selectedIpamSubBlock24 = 'all');
                          await _loadOverview(silent: true);
                        } catch (e) {
                          if (!ctx.mounted) return;
                          ScaffoldMessenger.of(ctx).aviso('Error guardando subred: $e');
                        }
                      },
                icon: const Icon(Icons.save, size: 16),
                label: Text(isEdit ? 'Guardar Cambios' : 'Guardar Subred'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmDeleteSubnet(Map<String, dynamic> subnet) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('¿Eliminar subred ${subnet['cidr']}?'),
        content: Text(
          'Se eliminará la subred "${subnet['name']}" del IPAM. Las máquinas e IPs seguirán existiendo en el inventario CMDB.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Eliminar Subred'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.api.deleteCmdbSubnet(subnet['id'] as int);
      if (_selectedIpamSubnetId == subnet['id']) {
        _selectedIpamSubnetId = null;
      }
      await _loadOverview(silent: true);
    }
  }
}

class _ParsedCidrBlock {
  final String canonicalCidr;
  final int prefixLen;
  final String subnetMask;
  final String networkAddress;
  final String broadcastAddress;
  final String firstUsableIp;
  final String lastUsableIp;
  final int totalAddresses;
  final int totalUsable;
  final int networkInt;

  const _ParsedCidrBlock({
    required this.canonicalCidr,
    required this.prefixLen,
    required this.subnetMask,
    required this.networkAddress,
    required this.broadcastAddress,
    required this.firstUsableIp,
    required this.lastUsableIp,
    required this.totalAddresses,
    required this.totalUsable,
    required this.networkInt,
  });

  static _ParsedCidrBlock? tryParse(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    final slashParts = s.split('/');
    if (slashParts.length > 2) return null;
    final ipPart = slashParts[0].trim();
    final prefix = slashParts.length == 2
        ? int.tryParse(slashParts[1].trim())
        : 24;
    if (prefix == null || prefix < 8 || prefix > 32) return null;

    final octets = ipPart.split('.');
    if (octets.length != 4) return null;
    int ipInt = 0;
    for (final o in octets) {
      final v = int.tryParse(o);
      if (v == null || v < 0 || v > 255) return null;
      ipInt = (ipInt << 8) | v;
    }
    ipInt = ipInt & 0xFFFFFFFF;

    final int hostBits = 32 - prefix;
    final int maskInt =
        prefix == 0 ? 0 : ((0xFFFFFFFF << hostBits) & 0xFFFFFFFF);
    final int netInt = (ipInt & maskInt) & 0xFFFFFFFF;
    final int totalAddr = 1 << hostBits;
    final int bcastInt = (netInt + totalAddr - 1) & 0xFFFFFFFF;
    final int firstInt = totalAddr > 2 ? netInt + 1 : netInt;
    final int lastInt = totalAddr > 2 ? bcastInt - 1 : bcastInt;
    final int usable = totalAddr > 2 ? totalAddr - 2 : totalAddr;

    final netStr = _intToIpv4(netInt);
    return _ParsedCidrBlock(
      canonicalCidr: '$netStr/$prefix',
      prefixLen: prefix,
      subnetMask: _intToIpv4(maskInt),
      networkAddress: netStr,
      broadcastAddress: _intToIpv4(bcastInt),
      firstUsableIp: _intToIpv4(firstInt),
      lastUsableIp: _intToIpv4(lastInt),
      totalAddresses: totalAddr,
      totalUsable: usable,
      networkInt: netInt,
    );
  }

  List<String> buildAddressList({int maxLimit = 4096}) {
    final count = totalAddresses < maxLimit ? totalAddresses : maxLimit;
    return List<String>.generate(
      count,
      (offset) => _intToIpv4((networkInt + offset) & 0xFFFFFFFF),
    );
  }

  static String _intToIpv4(int val) {
    final a = (val >> 24) & 0xFF;
    final b = (val >> 16) & 0xFF;
    final c = (val >> 8) & 0xFF;
    final d = val & 0xFF;
    return '$a.$b.$c.$d';
  }
}

class _TableHeaderCell extends StatelessWidget {
  final String text;
  const _TableHeaderCell(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w900,
          color: AppPalette.slate700,
        ),
      ),
    );
  }
}

class _TableBodyCell extends StatelessWidget {
  final String text;
  final bool mono;
  final bool bold;
  const _TableBodyCell(
    this.text, {
    this.mono = false,
    this.bold = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          fontFamily: mono ? 'monospace' : null,
          fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
          color: AppPalette.slate800,
        ),
      ),
    );
  }
}

extension _IpPrefixStringExt on String {
  String rsplitThreeOctets() {
    final parts = split('.');
    if (parts.length >= 3) {
      return '${parts[0]}.${parts[1]}.${parts[2]}';
    }
    return this;
  }
}
