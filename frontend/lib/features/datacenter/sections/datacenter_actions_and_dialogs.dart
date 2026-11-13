part of '../datacenter_floor_view.dart';

/// Acciones de persistencia, subida de planos arquitectónicos, gestión de plantas,
/// alta de racks y dispositivos de planta sincronizados con CMDB.
extension _DatacenterActionsAndDialogsExt on _DatacenterFloorViewState {
  void _showInlineSettingsBanner(String message, {bool isError = false}) {
    if (!mounted) return;
    final seq = ++_bannerSeq;
    _rebuildState(() {
      _settingsSavedBanner = message;
      _settingsSaveError = isError;
    });
    Future.delayed(const Duration(milliseconds: 2200), () {
      if (mounted && _bannerSeq == seq) {
        _rebuildState(() {
          _settingsSavedBanner = null;
        });
      }
    });
  }

  Future<void> _saveSelectedFloorDeviceSettings({String? customToast}) async {
    final devId = _selectedFloorDeviceId;
    if (devId == null) return;
    FloorDeviceNode? currentDev;
    if (_floor != null) {
      for (final d in _floor!.floorDevices) {
        if (d.id == devId) {
          currentDev = d;
          break;
        }
      }
    }
    try {
      await widget.api.updateFloorDevice(
        devId,
        _buildFloorDevicePayload(currentDev),
      );
      _editingDeviceId = null;
      widget.onRefresh();
      _showInlineSettingsBanner(
        customToast ??
            '✓ Ajustes de "${_devCodeCtrl.text.trim()}" guardados.',
      );
    } catch (e) {
      _showInlineSettingsBanner(
        'Error al guardar: $e',
        isError: true,
      );
    }
  }

  Future<void> _quickLinkDeviceToRack(
    FloorDeviceNode dev,
    int? targetRackId,
    String targetRackCode,
  ) async {
    try {
      await widget.api.updateFloorDevice(dev.id, {
        'linked_rack_id': targetRackId ?? 0,
      });
      if (_selectedFloorDeviceId == dev.id) {
        _rebuildState(() {
          _devLinkedRackId = targetRackId;
          _editingDeviceId = null;
        });
      }
      widget.onRefresh();
      _showInlineSettingsBanner(
        targetRackId == null
            ? '✓ "${dev.code}" desvinculado del Rack.'
            : '✓ "${dev.code}" conectado al Rack $targetRackCode.',
      );
    } catch (e) {
      _showInlineSettingsBanner(
        'Error al cambiar Rack: $e',
        isError: true,
      );
    }
  }

  String _nextAutoCodeForCategory(FloorNode floor, String category) {
    final catItem = _catalogItemFor(category);
    final existing = floor.floorDevices
        .where((d) => d.category == category)
        .length;
    final nextNum = existing + 1;
    if (category == 'telecom_outlet') {
      final startPort = (existing * 4) + 1;
      final p1 = startPort.toString().padLeft(2, '0');
      final p2 = (startPort + 1).toString().padLeft(2, '0');
      return 'Bi$p1, Bi$p2...';
    }
    return '${catItem.prefix}${nextNum.toString().padLeft(2, '0')}';
  }

  Future<void> _dropNewDeviceFromLibrary({
    required FloorNode floor,
    required String category,
    required double normX,
    required double normY,
  }) async {
    if (category == 'rack') {
      await _showDrawNewRackDialog(floor);
      return;
    }

    // Al soltar un sensor o dispositivo en el plano, abrimos el diálogo en esas
    // coordenadas para que el usuario elija a qué Rack (o Roseta) va conectado
    await _showAddFloorDeviceModal(
      floor,
      initialCategory: category,
      targetPosX: normX,
      targetPosY: normY,
    );
  }

  Future<void> _showCreateCustomDeviceTypeModal(FloorNode floor) async {
    String selectedGroup = 'Industrial / A Medida';
    final labelCtrl = TextEditingController();
    final prefixCtrl = TextEditingController(text: 'DEV');
    final portHintCtrl = TextEditingController(text: 'ENV-MON01:Canal-1');
    bool isSensor = true;
    String selectedIconKey = 'sensors';
    String selectedColorHex = '#7C3AED';

    const colorOptions = <Map<String, String>>[
      {'hex': '#0D9488', 'name': 'Verde Azulado (Sensor Clima)'},
      {'hex': '#D97706', 'name': 'Ámbar (Energía / Carga)'},
      {'hex': '#DC2626', 'name': 'Rojo (Alarma / PCI)'},
      {'hex': '#7C3AED', 'name': 'Morado (Industrial / A Medida)'},
      {'hex': '#0284C7', 'name': 'Azul Cian (Agua / Humedad)'},
      {'hex': '#0F172A', 'name': 'Negro (Equipo Activo)'},
      {'hex': '#64748B', 'name': 'Gris Pizarra (Toma / Pasivo)'},
    ];

    final createdKey = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: _DatacenterFloorViewState._colorFromHex(selectedColorHex),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  _DatacenterFloorViewState._iconFromKey(selectedIconKey),
                  color: Colors.white,
                  size: 19,
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Crear Nuevo Tipo de Dispositivo / Sensor a Medida',
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      'Se añadirá a DEVICES LIBRARY para arrastrarlo o colocarlo en cualquier planta',
                      style: TextStyle(fontSize: 11, color: AppPalette.slate500),
                    ),
                  ],
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: selectedGroup,
                    decoration: const InputDecoration(
                      labelText: 'Familia / Grupo en DEVICES LIBRARY',
                      isDense: true,
                    ),
                    items: _DatacenterFloorViewState._libraryGroupOrder
                        .map(
                          (g) => DropdownMenuItem(value: g, child: Text(g)),
                        )
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setModal(() => selectedGroup = v);
                    },
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: labelCtrl,
                          decoration: const InputDecoration(
                            labelText:
                                'Nombre del Tipo * (ej. Sensor CO2, Grupo Electrógeno, Torno)',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: prefixCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Prefijo ID (ej. CO2, GEN)',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: portHintCtrl,
                    decoration: const InputDecoration(
                      labelText:
                          'Puerto / Sonda por defecto en Rack (ej. ENV-MON01:CO2-1)',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text(
                      'Es un Sensor / Equipo con lectura o umbral (muestra lectura en el plano)',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    value: isSensor,
                    onChanged: (v) => setModal(() => isSensor = v),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Icono del Marcador:',
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
                    children: _DatacenterFloorViewState._customIconMap.entries.map((entry) {
                      final isSel = selectedIconKey == entry.key;
                      return InkWell(
                        onTap: () =>
                            setModal(() => selectedIconKey = entry.key),
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: isSel
                                ? _DatacenterFloorViewState._colorFromHex(selectedColorHex)
                                : AppPalette.slate100,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: isSel
                                  ? AppPalette.slate900
                                  : AppPalette.slate300,
                              width: isSel ? 1.8 : 1.0,
                            ),
                          ),
                          child: Icon(
                            entry.value,
                            size: 17,
                            color: isSel
                                ? Colors.white
                                : AppPalette.slate700,
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Color del Pin en el Plano:',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: AppPalette.slate700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: colorOptions.map((c) {
                      final hex = c['hex']!;
                      final isSel = selectedColorHex == hex;
                      return ChoiceChip(
                        selected: isSel,
                        avatar: CircleAvatar(
                          backgroundColor: _DatacenterFloorViewState._colorFromHex(hex),
                          radius: 7,
                        ),
                        label: Text(
                          c['name']!,
                          style: const TextStyle(fontSize: 11),
                        ),
                        onSelected: (_) =>
                            setModal(() => selectedColorHex = hex),
                      );
                    }).toList(),
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
                final lbl = labelCtrl.text.trim();
                if (lbl.isEmpty) return;
                try {
                  final res = await widget.api.createCustomFloorDeviceType({
                    'group_name': selectedGroup,
                    'label': lbl,
                    'prefix': prefixCtrl.text.trim().isEmpty
                        ? 'DEV'
                        : prefixCtrl.text.trim().toUpperCase(),
                    'icon_key': selectedIconKey,
                    'pin_color_hex': selectedColorHex,
                    'default_port_hint': portHintCtrl.text.trim(),
                    'is_sensor': isSensor,
                  });
                  await _loadCustomFloorDeviceTypes();
                  _rebuildState(() {
                    _expandedLibraryGroups.add(selectedGroup);
                  });
                  if (ctx.mounted) {
                    Navigator.pop(
                      ctx,
                      (res['category_key'] ?? '').toString(),
                    );
                  }
                } catch (_) {}
              },
              icon: const Icon(Icons.add_circle_outline, size: 16),
              label: const Text('Guardar en Librería y Colocar'),
            ),
          ],
        ),
      ),
    );

    if (createdKey != null && createdKey.isNotEmpty) {
      await _showAddFloorDeviceModal(floor, initialCategory: createdKey);
    }
  }

  Future<void> _showLinkExistingFloorDeviceWithCmdbDialog(
    FloorDeviceNode dev,
  ) async {
    final selectedAst = await CmdbAssetExplorerDialog.show(
      context,
      api: widget.api,
      contextMode: 'floor',
      preselectedAssetId: dev.cmdbAssetId,
      title: 'Vincular y Cumplimentar "${dev.code}" desde CMDB (Por Redes)',
      subtitle:
          'Selecciona una Subred / Máscara en la columna izquierda y elige el equipo detectado en CMDB para unificarlo con este elemento de planta.',
    );

    if (selectedAst != null) {
      final astId = (selectedAst['id'] as num).toInt();
      final hbIp =
          (selectedAst['_resolved_ip'] ?? selectedAst['heartbeat_ip'] ?? '')
              .toString()
              .trim();
      final rawName = (selectedAst['name'] ?? '').toString().trim();
      final rawHost = (selectedAst['hostname'] ?? '').toString().trim();
      final fqdn =
          (selectedAst['_resolved_fqdn'] ?? selectedAst['fqdn'] ?? '')
              .toString()
              .trim();
      final fType = (selectedAst['floor_device_type'] ?? '').toString().trim();
      final modelName = (selectedAst['model_name'] ?? '').toString().trim();
      final serialNum = (selectedAst['serial_or_uuid'] ?? '').toString().trim();
      String mac = (selectedAst['_resolved_mac'] ?? '').toString().trim();
      int? vlan = int.tryParse(
        (selectedAst['_resolved_vlan'] ?? '').toString().trim(),
      );
      final ips = (selectedAst['ip_addresses'] as List?) ?? [];
      if (ips.isNotEmpty && ips.first is Map) {
        final firstIp = Map<String, dynamic>.from(ips.first as Map);
        if (mac.isEmpty) {
          mac = (firstIp['mac_address'] ?? '').toString().trim();
        }
        vlan ??= (firstIp['vlan_id'] as num?)?.toInt();
      }
      _rebuildState(() {
        if (fType.isNotEmpty &&
            _allCatalogItems.any((c) => c.category == fType)) {
          _devCategory = fType;
        }
        if (hbIp.isNotEmpty) _devIpCtrl.text = hbIp;
        if (vlan != null) _devVlanCtrl.text = vlan.toString();
        if (modelName.isNotEmpty) _devModelCtrl.text = modelName;
        if (serialNum.isNotEmpty) _devSerialCtrl.text = serialNum;
        final catLabel = _catalogItemFor(_devCategory).label;
        if (rawName.isNotEmpty && !rawName.startsWith('Equipo Detectado')) {
          _devNameCtrl.text = rawName;
        } else if (rawHost.isNotEmpty && !rawHost.startsWith('host-')) {
          _devNameCtrl.text = '$catLabel • $rawHost';
        }
        final resp = (selectedAst['responsible_person'] ?? '').toString().trim();
        if (resp.isNotEmpty) _devRespCtrl.text = resp;
        final notes = (selectedAst['notes'] ?? '').toString().trim();
        if (notes.isNotEmpty && _devNotesCtrl.text.trim().isEmpty) {
          _devNotesCtrl.text = notes;
        }
        if (selectedAst['status'] == 'online' ||
            selectedAst['monitoring_enabled'] == true) {
          _fdMonitorEnabled = true;
          _devStatus = 'online';
        }
      });
      final updatedCustom = Map<String, dynamic>.from(dev.customFields);
      if (_devModelCtrl.text.trim().isNotEmpty) {
        updatedCustom['model_name'] = _devModelCtrl.text.trim();
      }
      if (_devSerialCtrl.text.trim().isNotEmpty) {
        updatedCustom['serial_number'] = _devSerialCtrl.text.trim();
      }
      await widget.api.updateFloorDevice(dev.id, {
        'device_type': _devCategory,
        'code': _devCodeCtrl.text.trim(),
        'name': _devNameCtrl.text.trim(),
        'room_code': _devRoomCodeCtrl.text.trim(),
        'ip_address': _devIpCtrl.text.trim(),
        'fqdn': fqdn,
        'mac_address': mac,
        'vlan': int.tryParse(_devVlanCtrl.text.trim()),
        'monitoring_enabled': _fdMonitorEnabled,
        'responsible_person': _devRespCtrl.text.trim(),
        'notes': _devNotesCtrl.text.trim(),
        'cmdb_asset_id': astId,
        'custom_fields': updatedCustom,
      });
      widget.onRefresh();
    }
  }

  Future<void> _showAddFloorDeviceModal(
    FloorNode floor, {
    String initialCategory = 'sensor_temp',
    double? targetPosX,
    double? targetPosY,
    bool focusCmdbSelector = false,
  }) async {
    List<Map<String, dynamic>> cmdbAssets = [];
    try {
      final overview = await widget.api.fetchCmdbOverview();
      cmdbAssets = ((overview['assets'] as List?) ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .where((a) => a['rack_device_id'] == null)
          .toList();
      // Priorizar primero los activos detectados en CMDB que aún no están colocados en una planta
      cmdbAssets.sort((a, b) {
        final aUnplaced = a['floor_device_id'] == null ? 0 : 1;
        final bUnplaced = b['floor_device_id'] == null ? 0 : 1;
        if (aUnplaced != bUnplaced) return aUnplaced.compareTo(bUnplaced);
        return (a['code'] ?? '').toString().compareTo((b['code'] ?? '').toString());
      });
    } catch (_) {}

    if (!mounted) return;

    String selectedCat = initialCategory == 'rack'
        ? (focusCmdbSelector ? 'printer' : 'sensor_temp')
        : initialCategory;
    int? selectedCmdbAssetId;
    String detectedFqdn = '';
    String detectedMac = '';
    int? detectedVlan;
    bool enableHeartbeatFromCmdb = false;
    bool certscopeEnabled = false;
    final certscopePortCtrl = TextEditingController(text: '443');

    final codeCtrl = TextEditingController(
      text: _nextAutoCodeForCategory(floor, selectedCat),
    );
    final nameCtrl = TextEditingController(
      text: '${_catalogItemFor(selectedCat).label} ${codeCtrl.text}',
    );
    final roomCtrl = TextEditingController(
      text: floor.rooms.isNotEmpty ? floor.rooms.first.name : 'GOA',
    );
    final ipCtrl = TextEditingController();
    final portCtrl = TextEditingController(
      text: _defaultPortHintForCategory(selectedCat),
    );
    final notesCtrl = TextEditingController(
      text: _isSensorCategory(selectedCat)
          ? 'Lectura actual: OK | Monitorizado en Rack'
          : '',
    );
    final respCtrl = TextEditingController(text: 'Alex Geng');
    final modelCtrl = TextEditingController();
    final serialCtrl = TextEditingController();

    void applyCmdbAssetSelection(Map<String, dynamic>? ast) {
      if (ast == null) {
        selectedCmdbAssetId = null;
        detectedFqdn = '';
        detectedMac = '';
        detectedVlan = null;
        enableHeartbeatFromCmdb = false;
        return;
      }
      selectedCmdbAssetId = (ast['id'] as num?)?.toInt();
      final astModel = (ast['model_name'] ?? '').toString().trim();
      if (astModel.isNotEmpty) modelCtrl.text = astModel;
      final astSerial = (ast['serial_or_uuid'] ?? '').toString().trim();
      if (astSerial.isNotEmpty) serialCtrl.text = astSerial;
      final fType = (ast['floor_device_type'] ?? '').toString().trim();
      if (fType.isNotEmpty &&
          _allCatalogItems.any((c) => c.category == fType)) {
        selectedCat = fType;
      } else if (_isSensorCategory(selectedCat)) {
        selectedCat = 'printer';
      }
      final autoCode = _nextAutoCodeForCategory(floor, selectedCat);
      final rawCode = (ast['code'] ?? '').toString().trim();
      codeCtrl.text = (rawCode.startsWith('DISC-') || rawCode.startsWith('FLR-'))
          ? autoCode
          : (rawCode.isNotEmpty ? rawCode : autoCode);

      final hbIp = (ast['heartbeat_ip'] ?? '').toString().trim();
      ipCtrl.text = hbIp;
      detectedFqdn = (ast['fqdn'] ?? '').toString().trim();
      final ips = (ast['ip_addresses'] as List?) ?? [];
      if (ips.isNotEmpty && ips.first is Map) {
        final firstIp = Map<String, dynamic>.from(ips.first as Map);
        detectedMac = (firstIp['mac_address'] ?? '').toString().trim();
        detectedVlan = (firstIp['vlan_id'] as num?)?.toInt();
        if (detectedFqdn.isEmpty) {
          detectedFqdn = (firstIp['fqdn'] ?? '').toString().trim();
        }
      }
      final rawName = (ast['name'] ?? '').toString().trim();
      final rawHost = (ast['hostname'] ?? '').toString().trim();
      final catLabel = _catalogItemFor(selectedCat).label;
      if (rawName.isNotEmpty && !rawName.startsWith('Equipo Detectado')) {
        nameCtrl.text = rawName;
      } else if (rawHost.isNotEmpty && !rawHost.startsWith('host-')) {
        nameCtrl.text = '$catLabel • $rawHost';
      } else if (hbIp.isNotEmpty) {
        nameCtrl.text = '$catLabel ($hbIp)';
      } else {
        nameCtrl.text = '$catLabel ${codeCtrl.text}';
      }
      final resp = (ast['responsible_person'] ?? '').toString().trim();
      if (resp.isNotEmpty) respCtrl.text = resp;
      final notes = (ast['notes'] ?? '').toString().trim();
      if (notes.isNotEmpty) notesCtrl.text = notes;
      portCtrl.text = _defaultPortHintForCategory(selectedCat);
      enableHeartbeatFromCmdb =
          ast['monitoring_enabled'] == true || ast['status'] == 'online';
    }

    if (focusCmdbSelector && cmdbAssets.isNotEmpty) {
      applyCmdbAssetSelection(cmdbAssets.first);
    }

    final floorRacks = <RackSummary>[];
    for (final rm in floor.rooms) {
      floorRacks.addAll(rm.racks);
    }
    final floorOutlets = floor.floorDevices
        .where((d) => d.category == 'telecom_outlet')
        .toList();

    // Si se arrastró al plano, preseleccionamos el Rack más cercano al punto donde se soltó
    int? linkedRackId;
    if (floorRacks.isNotEmpty) {
      if (targetPosX != null && targetPosY != null) {
        double bestRackDist = 999.0;
        for (final rk in floorRacks) {
          final rPos = _rackPositions[rk.id] ?? Offset(rk.posX, rk.posY);
          final dx = rPos.dx - targetPosX;
          final dy = rPos.dy - targetPosY;
          final dist = dx * dx + dy * dy;
          if (dist < bestRackDist) {
            bestRackDist = dist;
            linkedRackId = rk.id;
          }
        }
      } else {
        linkedRackId = floorRacks.first.id;
      }
    }

    int? linkedOutletId;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) {
          final isSensor = _isSensorCategory(selectedCat);
          return AlertDialog(
            title: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: _catalogItemFor(selectedCat).pinColor,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    _catalogItemFor(selectedCat).icon,
                    color: Colors.white,
                    size: 19,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isSensor
                            ? 'Colocar Sensor en ${floor.name} y Conectar a Rack'
                            : 'Colocar Dispositivo / Toma en ${floor.name}',
                        style: const TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        targetPosX != null
                            ? 'Posición en plano seleccionada (${(targetPosX * 100).round()}%, ${(targetPosY! * 100).round()}%) • Puedes vincularlo con un equipo detectado en CMDB'
                            : 'Selecciona un equipo detectado en la CMDB o crea uno nuevo y elige su categoría (Impresora, Cámara, Wi-Fi...)',
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppPalette.slate500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 0. CAJA DESTACADA: SELECCIONAR EQUIPO DETECTADO EN LA CMDB (ALINEACIÓN UNIFICADA)
                    Container(
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: AppPalette.blue500,
                          width: 1.4,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(
                                Icons.fact_check_outlined,
                                size: 16,
                                color: AppPalette.blue700,
                              ),
                              const SizedBox(width: 6),
                              const Expanded(
                                child: Text(
                                  '0. ¿Seleccionar equipo ya detectado / registrado en la CMDB? (Mismo elemento)',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w900,
                                    color: AppPalette.blue900,
                                  ),
                                ),
                              ),
                              if (selectedCmdbAssetId != null)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 7,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFDCFCE7),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: const Color(0xFF16A34A),
                                    ),
                                  ),
                                  child: const Text(
                                    'VINCULADO A CMDB',
                                    style: TextStyle(
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w900,
                                      color: Color(0xFF166534),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Al elegir un dispositivo detectado en la CMDB (agrupado por su Red / Máscara CIDR), se autorrellenan su IP, Hostname, MAC, Modelo, S/N y estado, y queda unido como el mismo elemento en CMDB y Datacenter.',
                            style: TextStyle(
                              fontSize: 10.5,
                              color: AppPalette.slate600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (selectedCmdbAssetId != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 7,
                              ),
                              margin: const EdgeInsets.only(bottom: 8),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(7),
                                border: Border.all(
                                  color: const Color(0xFF22C55E),
                                ),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.check_circle,
                                    size: 16,
                                    color: Color(0xFF16A34A),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Seleccionado de CMDB: [${codeCtrl.text}] ${nameCtrl.text} • IP: ${ipCtrl.text}',
                                      style: const TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w800,
                                        color: Color(0xFF14532D),
                                      ),
                                    ),
                                  ),
                                  TextButton.icon(
                                    style: TextButton.styleFrom(
                                      visualDensity: VisualDensity.compact,
                                      foregroundColor: AppPalette.red600,
                                    ),
                                    onPressed: () => setModal(
                                      () => applyCmdbAssetSelection(null),
                                    ),
                                    icon: const Icon(Icons.link_off, size: 14),
                                    label: const Text(
                                      'Desvincular',
                                      style: TextStyle(fontSize: 11),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          SizedBox(
                            width: double.infinity,
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                backgroundColor: Colors.white,
                                side: const BorderSide(
                                  color: AppPalette.blue600,
                                ),
                              ),
                              onPressed: () async {
                                final picked =
                                    await CmdbAssetExplorerDialog.show(
                                      ctx,
                                      api: widget.api,
                                      initialAssets: cmdbAssets.isNotEmpty
                                          ? cmdbAssets
                                          : null,
                                      contextMode: 'floor',
                                      preselectedAssetId: selectedCmdbAssetId,
                                      title:
                                          'Seleccionar Equipo de la CMDB para Colocar en ${floor.name}',
                                      subtitle:
                                          'Navega por las Redes / Subredes (Máscara CIDR) en la columna izquierda y elige el equipo detectado.',
                                    );
                                if (picked != null) {
                                  setModal(() {
                                    applyCmdbAssetSelection(picked);
                                  });
                                }
                              },
                              icon: const Icon(
                                Icons.manage_search_rounded,
                                size: 17,
                                color: AppPalette.blue700,
                              ),
                              label: Text(
                                selectedCmdbAssetId != null
                                    ? 'Cambiar Equipo de la CMDB (Explorador por Redes / Máscara)'
                                    : 'Abrir Explorador CMDB por Redes / Máscara de Red...',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w800,
                                  color: AppPalette.blue900,
                                ),
                              ),
                            ),
                          ),
                          if (selectedCmdbAssetId != null &&
                              (detectedFqdn.isNotEmpty ||
                                  detectedMac.isNotEmpty ||
                                  detectedVlan != null)) ...[
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                if (detectedFqdn.isNotEmpty)
                                  Chip(
                                    visualDensity: VisualDensity.compact,
                                    backgroundColor: Colors.white,
                                    label: Text(
                                      'FQDN/PTR: $detectedFqdn',
                                      style: const TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                if (detectedMac.isNotEmpty)
                                  Chip(
                                    visualDensity: VisualDensity.compact,
                                    backgroundColor: Colors.white,
                                    label: Text(
                                      'MAC: $detectedMac',
                                      style: const TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                if (detectedVlan != null)
                                  Chip(
                                    visualDensity: VisualDensity.compact,
                                    backgroundColor: Colors.white,
                                    label: Text(
                                      'VLAN: $detectedVlan',
                                      style: const TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),

                    // 1. CAJA DESTACADA: SELECCIÓN DE RACK AL QUE VA CONECTADO
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppPalette.amber50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: AppPalette.amber500,
                          width: 1.4,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Row(
                            children: [
                              Icon(
                                Icons.dns_rounded,
                                size: 16,
                                color: AppPalette.amber700,
                              ),
                              SizedBox(width: 6),
                              Text(
                                '1. ¿A qué Rack está conectado este sensor / dispositivo? *',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w900,
                                  color: AppPalette.amber800,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          DropdownButtonFormField<int?>(
                            initialValue: linkedRackId,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText:
                                  'Rack de Conexión en Planta (Traza línea al Rack)',
                              filled: true,
                              fillColor: Colors.white,
                              isDense: true,
                            ),
                            items: [
                              const DropdownMenuItem<int?>(
                                value: null,
                                child: Text('Sin conexión directa a Rack'),
                              ),
                              ...floorRacks.map(
                                (rk) => DropdownMenuItem<int?>(
                                  value: rk.id,
                                  child: Text(
                                    'Rack ${rk.code} — ${rk.name} (${rk.totalUnits}U • ${rk.deviceCount} eq.)',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                            onChanged: (v) => setModal(() => linkedRackId = v),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            controller: portCtrl,
                            decoration: InputDecoration(
                              labelText: isSensor
                                  ? 'Equipo / Sonda / PDU en el Rack y Lectura (ej. ENV-MON01:Temp-1 21.2°C o PDU-A:Meter)'
                                  : 'Puerto / Equipo en el Rack (ej. PP-A:01 o SW01:Gi1/0/10)',
                              filled: true,
                              fillColor: Colors.white,
                              isDense: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),

                    // 2. CATEGORÍA DEL SENSOR O DISPOSITIVO
                    DropdownButtonFormField<String>(
                      initialValue: selectedCat,
                      decoration: const InputDecoration(
                        labelText:
                            '2. Categoría / Tipo de Dispositivo (ej. Printer / Impresora, Cámara, Wi-Fi AP...)',
                        isDense: true,
                      ),
                      items: _allCatalogItems
                          .where((c) => c.category != 'rack')
                          .map(
                            (c) => DropdownMenuItem<String>(
                              value: c.category,
                              child: Row(
                                children: [
                                  Icon(
                                    c.icon,
                                    size: 17,
                                    color: c.pinColor,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '${c.label} (${c.groupName})',
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: c.isSensor
                                          ? FontWeight.w700
                                          : FontWeight.normal,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (v) {
                        if (v == null) return;
                        setModal(() {
                          selectedCat = v;
                          final auto = _nextAutoCodeForCategory(
                            floor,
                            selectedCat,
                          );
                          codeCtrl.text = auto;
                          final catLabel = _catalogItemFor(selectedCat).label;
                          if (selectedCmdbAssetId != null &&
                              ipCtrl.text.trim().isNotEmpty) {
                            final hostHint = detectedFqdn.isNotEmpty
                                ? detectedFqdn.split('.').first
                                : ipCtrl.text.trim();
                            nameCtrl.text = '$catLabel • $hostHint';
                          } else {
                            nameCtrl.text = '$catLabel $auto';
                          }
                          portCtrl.text =
                              _defaultPortHintForCategory(selectedCat);
                        });
                      },
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: codeCtrl,
                            decoration: const InputDecoration(
                              labelText:
                                  'ID / Código * (ej. PR01, CAM01, AP01, TMP01)',
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: nameCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Nombre Descriptivo',
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
                            controller: roomCtrl,
                            decoration: const InputDecoration(
                              labelText:
                                  'Sala / Pasillo (ej. PASILLO-FRIO, GOA)',
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: ipCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Dirección IP (sincronizada con CMDB)',
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
                            controller: modelCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Marca / Modelo del Equipo',
                              hintText: 'Ej: HP LaserJet M428, Hikvision IP...',
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: serialCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Número de Serie (S/N) / Service Tag',
                              hintText: 'S/N o UUID del fabricante',
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
                            controller: notesCtrl,
                            decoration: InputDecoration(
                              labelText: isSensor
                                  ? 'Lectura / Umbral (ej. 21.4 °C | 46 %RH | 5.2 kW)'
                                  : 'Notas técnicas',
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: respCtrl,
                            decoration: const InputDecoration(
                              labelText: 'Persona Responsable',
                              isDense: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (selectedCat != 'telecom_outlet' &&
                        !isSensor &&
                        floorOutlets.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      DropdownButtonFormField<int?>(
                        initialValue: linkedOutletId,
                        decoration: const InputDecoration(
                          labelText:
                              'Conectado a Roseta / Telecommunications Outlet (Línea Azul)',
                          isDense: true,
                        ),
                        items: [
                          const DropdownMenuItem<int?>(
                            value: null,
                            child: Text('Sin roseta intermedia (Directo a Rack)'),
                          ),
                          ...floorOutlets.map(
                            (o) => DropdownMenuItem<int?>(
                              value: o.id,
                              child: Text('${o.code} (${o.roomCode})'),
                            ),
                          ),
                        ],
                        onChanged: (v) => setModal(() => linkedOutletId = v),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
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
                      child: Row(
                        children: [
                          Expanded(
                            child: CheckboxListTile(
                              value: certscopeEnabled,
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                '7. CertScope: Verificar caducidad de Certificado HTTPS al guardar',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w800,
                                  color: AppPalette.blue900,
                                ),
                              ),
                              onChanged: (v) =>
                                  setModal(() => certscopeEnabled = v ?? false),
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
                                  isDense: true,
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancelar'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(ctx, true),
                icon: const Icon(Icons.add_location_alt_outlined, size: 16),
                label: Text(
                  selectedCmdbAssetId != null
                      ? 'Colocar y Vincular con CMDB'
                      : 'Colocar y Conectar al Rack',
                ),
              ),
            ],
          );
        },
      ),
    );

    if (ok == true) {
      final count = floor.floorDevices.length;
      final normX = targetPosX != null
          ? double.parse(targetPosX.clamp(0.04, 0.94).toStringAsFixed(4))
          : (0.20 + (count % 5) * 0.14).clamp(0.10, 0.86);
      final normY = targetPosY != null
          ? double.parse(targetPosY.clamp(0.06, 0.92).toStringAsFixed(4))
          : (0.30 + (count ~/ 5) * 0.15).clamp(0.14, 0.86);
      final res = await widget.api.createFloorDevice(floor.id, {
        'device_type': selectedCat,
        'code': codeCtrl.text.trim(),
        'name': nameCtrl.text.trim(),
        'room_code': roomCtrl.text.trim(),
        'ip_address': ipCtrl.text.trim(),
        'fqdn': detectedFqdn,
        'mac_address': detectedMac,
        'vlan': detectedVlan,
        'pos_x': normX,
        'pos_y': normY,
        'status': enableHeartbeatFromCmdb ? 'online' : 'unmonitored',
        'monitoring_enabled': enableHeartbeatFromCmdb,
        'linked_rack_id': linkedRackId,
        'linked_rack_device_code': portCtrl.text.trim(),
        'linked_outlet_id': linkedOutletId,
        'cmdb_asset_id': selectedCmdbAssetId,
        'responsible_person': respCtrl.text.trim(),
        'notes': notesCtrl.text.trim(),
        'certscope_enabled': certscopeEnabled,
        'certscope_port': int.tryParse(certscopePortCtrl.text.trim()) ?? 443,
        'custom_fields': {
          if (modelCtrl.text.trim().isNotEmpty)
            'model_name': modelCtrl.text.trim(),
          if (serialCtrl.text.trim().isNotEmpty)
            'serial_number': serialCtrl.text.trim(),
        },
      });
      final newId = (res['id'] as num?)?.toInt();
      if (newId != null) {
        _rebuildState(() {
          _selectedRackIds.clear();
          _selectedFloorDeviceId = newId;
          _editingDeviceId = null;
          _showRightSettings = true;
        });
      }
      widget.onRefresh();
    }
  }

  Future<void> _confirmDeleteFloorDevice(FloorDeviceNode dev) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Eliminar "${dev.code}"'),
        content: Text(
          '¿Deseas eliminar "${dev.code} (${dev.name})" del plano de esta planta?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: AppPalette.red600,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.delete_outline, size: 16),
            label: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await widget.api.deleteFloorDevice(dev.id);
        _rebuildState(() {
          _floorDevicePositions.remove(dev.id);
          if (_selectedFloorDeviceId == dev.id) {
            _selectedFloorDeviceId = null;
            _editingDeviceId = null;
          }
        });
        widget.onRefresh();
        messenger.aviso('Dispositivo "${dev.code}" eliminado.');
      } catch (e) {
        messenger.avisoError('Error al eliminar dispositivo: $e');
      }
    }
  }

  Future<void> _uploadFloorBlueprint(FloorNode floor) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final picked = await pickPlanImageFile();
      if (picked == null) return;

      _rebuildState(() => _uploading = true);
      await widget.api.uploadCustomPlanImage(
        targetType: 'floor',
        targetId: floor.id,
        filename: picked.name,
        fileBytes: picked.bytes,
      );
      widget.onRefresh();
      messenger.aviso('Plano de planta "${floor.name}" subido correctamente.');
    } catch (e) {
      messenger.avisoError('Error al subir plano de planta: $e');
    } finally {
      if (mounted) _rebuildState(() => _uploading = false);
    }
  }

  Future<void> _saveRackGeometry(int rackId) async {
    final pos = _rackPositions[rackId];
    final size = _rackSizes[rackId];
    final rot = _rackRotations[rackId];
    if (pos == null || size == null) return;
    try {
      await widget.api.updateRack(rackId, {
        'pos_x': double.parse(pos.dx.toStringAsFixed(4)),
        'pos_y': double.parse(pos.dy.toStringAsFixed(4)),
        'width_px': size.width.roundToDouble(),
        'depth_px': size.height.roundToDouble(),
        'rotation_deg': rot ?? 0,
      });
      widget.onRefresh();
    } catch (_) {}
  }

  Future<void> _saveMultipleRacksGeometry(Iterable<int> rackIds) async {
    for (final rackId in rackIds) {
      final pos = _rackPositions[rackId];
      final size = _rackSizes[rackId];
      final rot = _rackRotations[rackId];
      if (pos == null || size == null) continue;
      try {
        await widget.api.updateRack(rackId, {
          'pos_x': double.parse(pos.dx.toStringAsFixed(4)),
          'pos_y': double.parse(pos.dy.toStringAsFixed(4)),
          'width_px': size.width.roundToDouble(),
          'depth_px': size.height.roundToDouble(),
          'rotation_deg': rot ?? 0,
        });
      } catch (_) {}
    }
    widget.onRefresh();
  }

  bool get _isShiftPressed {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(LogicalKeyboardKey.shiftLeft) ||
        keys.contains(LogicalKeyboardKey.shiftRight) ||
        keys.contains(LogicalKeyboardKey.metaLeft) ||
        keys.contains(LogicalKeyboardKey.controlLeft);
  }

  /// Alinea los Racks seleccionados en una fila horizontal limpia (misma coordenada Y)
  Future<void> _alignSelectedRacksHorizontally({
    required double canvasW,
    bool packTightly = false,
  }) async {
    if (_selectedRackIds.length < 2) return;
    _pushUndoSnapshot(
      description: 'Alineación horizontal de ${_selectedRackIds.length} Racks',
      affectedRackIds: _selectedRackIds,
    );
    final ids = _selectedRackIds.toList()
      ..sort(
        (a, b) => (_rackPositions[a]?.dx ?? 0).compareTo(
          _rackPositions[b]?.dx ?? 0,
        ),
      );
    final avgY = ids
            .map((id) => _rackPositions[id]?.dy ?? 0.35)
            .reduce((a, b) => a + b) /
        ids.length;
    _rebuildState(() {
      double runningX = _rackPositions[ids.first]?.dx ?? 0.15;
      for (final id in ids) {
        final curX = _rackPositions[id]?.dx ?? runningX;
        final targetX = packTightly ? runningX : curX;
        _rackPositions[id] = Offset(
          targetX.clamp(0.02, 0.90),
          avgY.clamp(0.04, 0.88),
        );
        final wNorm = ((_rackSizes[id]?.width ?? 120.0) + 10.0) / canvasW;
        runningX = targetX + wNorm;
      }
    });
    await _saveMultipleRacksGeometry(ids);
  }

  /// Alinea los Racks seleccionados en una columna vertical limpia (misma coordenada X)
  Future<void> _alignSelectedRacksVertically({
    required double canvasH,
    bool packTightly = false,
  }) async {
    if (_selectedRackIds.length < 2) return;
    _pushUndoSnapshot(
      description: 'Alineación vertical de ${_selectedRackIds.length} Racks',
      affectedRackIds: _selectedRackIds,
    );
    final ids = _selectedRackIds.toList()
      ..sort(
        (a, b) => (_rackPositions[a]?.dy ?? 0).compareTo(
          _rackPositions[b]?.dy ?? 0,
        ),
      );
    final avgX = ids
            .map((id) => _rackPositions[id]?.dx ?? 0.25)
            .reduce((a, b) => a + b) /
        ids.length;
    _rebuildState(() {
      double runningY = _rackPositions[ids.first]?.dy ?? 0.15;
      for (final id in ids) {
        final curY = _rackPositions[id]?.dy ?? runningY;
        final targetY = packTightly ? runningY : curY;
        _rackPositions[id] = Offset(
          avgX.clamp(0.02, 0.90),
          targetY.clamp(0.04, 0.88),
        );
        final hNorm = ((_rackSizes[id]?.height ?? 90.0) + 10.0) / canvasH;
        runningY = targetY + hNorm;
      }
    });
    await _saveMultipleRacksGeometry(ids);
  }

  /// Iguala las dimensiones de todos los Racks seleccionados tomando el primero como referencia
  Future<void> _equalizeSelectedRacksSize() async {
    if (_selectedRackIds.length < 2) return;
    _pushUndoSnapshot(
      description: 'Igualar dimensiones de ${_selectedRackIds.length} Racks',
      affectedRackIds: _selectedRackIds,
    );
    final refId = _selectedRackIds.first;
    final refSize = _rackSizes[refId] ?? const Size(120.0, 90.0);
    _rebuildState(() {
      for (final id in _selectedRackIds) {
        _rackSizes[id] = refSize;
      }
    });
    await _saveMultipleRacksGeometry(_selectedRackIds);
  }

  Future<void> _saveFloorScale(FloorNode floor, double newScale) async {
    _rebuildState(() => _floorImageScale = newScale);
    try {
      await widget.api.updateFloor(floor.id, {'map_scale': newScale});
    } catch (_) {}
  }

  Future<void> _showAddFloorDialog(LocationNode loc) async {
    final nextNum = loc.floors.length + 1;
    final levelCtrl = TextEditingController(text: '$nextNum');
    final nameCtrl = TextEditingController(text: 'Planta $nextNum - Sala Técnica');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Añadir Nueva Planta en ${loc.name}'),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: levelCtrl,
                decoration: const InputDecoration(
                  labelText: 'Número de Planta (ej. 0, 1, 2, -1)',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Nombre de la Planta',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Crear Planta'),
          ),
        ],
      ),
    );

    if (ok == true) {
      await widget.api.createFloor(
        locationId: loc.id,
        name: nameCtrl.text.trim(),
        levelNumber: int.tryParse(levelCtrl.text.trim()) ?? nextNum,
      );
      widget.onRefresh();
    }
  }

  Future<void> _showDrawNewRackDialog(FloorNode floor) async {
    // Asegurarnos de que la planta tenga al menos una sala
    RoomNode? targetRoom = floor.rooms.isNotEmpty ? floor.rooms.first : null;
    if (targetRoom == null) {
      await widget.api.createRoom(
        floorId: floor.id,
        name: 'Sala CPD ${floor.name}',
      );
      widget.onRefresh();
      return;
    }

    int countInFloor = 0;
    for (final r in floor.rooms) {
      countInFloor += r.racks.length;
    }

    final codeCtrl = TextEditingController(text: 'RK00${countInFloor + 1}_M');
    final nameCtrl = TextEditingController(text: 'M_Rack00${countInFloor + 1}');
    final unitsCtrl = TextEditingController(text: '42');
    final respCtrl = TextEditingController(text: 'Alex Geng');
    int selectedRoomId = targetRoom.id;
    int? selectedAisleId =
        targetRoom.aisles.isNotEmpty ? targetRoom.aisles.first.id : null;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: Text('Dibujar / Añadir Nuevo Rack en ${floor.name}'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (floor.rooms.length > 1) ...[
                  DropdownButtonFormField<int>(
                    initialValue: selectedRoomId,
                    decoration: const InputDecoration(labelText: 'Sala dentro de la Planta'),
                    items: floor.rooms
                        .map(
                          (rm) => DropdownMenuItem(
                            value: rm.id,
                            child: Text('Sala ${rm.name}'),
                          ),
                        )
                        .toList(),
                    onChanged: (v) {
                      if (v != null) {
                        final rm = floor.rooms.firstWhere((e) => e.id == v);
                        setModal(() {
                          selectedRoomId = v;
                          selectedAisleId =
                              rm.aisles.isNotEmpty ? rm.aisles.first.id : null;
                        });
                      }
                    },
                  ),
                  const SizedBox(height: 10),
                ],
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: codeCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Numeración / Código (ej. RK004_M)',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: nameCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Nombre del Rack',
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
                        controller: unitsCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Altura Unidades U (ej. 42)',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: respCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Responsable',
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.add_box_outlined, size: 16),
              label: const Text('Colocar Rack en Planta'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      await widget.api.createRack(
        roomId: selectedRoomId,
        aisleId: selectedAisleId,
        code: codeCtrl.text.trim(),
        name: nameCtrl.text.trim(),
        totalUnits: int.tryParse(unitsCtrl.text.trim()) ?? 42,
        responsiblePerson: respCtrl.text.trim(),
      );
      widget.onRefresh();
    }
  }

  Future<void> _confirmDeleteFloor(FloorNode fl) async {
    final messenger = ScaffoldMessenger.of(context);
    int rCount = 0;
    for (final r in fl.rooms) {
      rCount += r.racks.length;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Eliminar Planta "${fl.name}"'),
        content: Text(
          '¿Estás seguro de que quieres eliminar la planta "${fl.name}"?\n\n'
          'Se eliminarán también las salas y los $rCount racks que estén dentro de esta planta.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: AppPalette.red600,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.delete_outline, size: 16),
            label: const Text('Sí, eliminar Planta'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await widget.api.deleteFloor(fl.id);
        if (_selectedFloorId == fl.id) {
          _selectedFloorId = null;
        }
        widget.onRefresh();
        messenger.aviso('Planta "${fl.name}" eliminada.');
      } catch (e) {
        messenger.avisoError('Error eliminando planta: $e');
      }
    }
  }

  Future<void> _confirmDeleteRack(RackSummary rk) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Eliminar Rack "${rk.code}"'),
        content: Text(
          '¿Estás seguro de que quieres eliminar el Rack "${rk.code} (${rk.name})"?\n\n'
          'Se borrarán también los ${rk.deviceCount} equipos y cables alojados en él.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: AppPalette.red600,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.delete_outline, size: 16),
            label: const Text('Sí, eliminar Rack'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await widget.api.deleteRack(rk.id);
        _rackPositions.remove(rk.id);
        _rackSizes.remove(rk.id);
        _rackRotations.remove(rk.id);
        widget.onRefresh();
        messenger.aviso('Rack "${rk.code}" eliminado.');
      } catch (e) {
        messenger.avisoError('Error eliminando rack: $e');
      }
    }
  }

  Future<void> _showRenameRackDialog(RackSummary rk) async {
    final codeCtrl = TextEditingController(text: rk.code);
    final nameCtrl = TextEditingController(text: rk.name);
    final unitsCtrl = TextEditingController(text: '${rk.totalUnits}');

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Editar Numeración y Nombre (${rk.code})'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: codeCtrl,
                decoration: const InputDecoration(
                  labelText: 'Numeración / Código (ej. RK001_M)',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Nombre del Rack (ej. M_Rack001)',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: unitsCtrl,
                decoration: const InputDecoration(
                  labelText: 'Unidades U Totales',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.pop(ctx, false);
              _confirmDeleteRack(rk);
            },
            icon: const Icon(
              Icons.delete_outline,
              size: 16,
              color: AppPalette.red600,
            ),
            label: const Text(
              'Eliminar Rack',
              style: TextStyle(color: AppPalette.red600),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );

    if (ok == true) {
      await widget.api.updateRack(rk.id, {
        'code': codeCtrl.text.trim(),
        'name': nameCtrl.text.trim(),
        'total_units': int.tryParse(unitsCtrl.text.trim()) ?? rk.totalUnits,
      });
      widget.onRefresh();
    }
  }
}
