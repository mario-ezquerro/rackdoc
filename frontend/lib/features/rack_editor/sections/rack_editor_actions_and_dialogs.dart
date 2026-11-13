part of '../rack_editor_view.dart';

/// Operaciones CRUD, movimiento en unidades `U`, alineación con activos CMDB,
/// asistente anti-colisiones de IP, trazado de latiguillos y diálogos del Rack Editor.
extension _RackEditorActionsAndDialogsExt on _RackEditorViewState {
  Future<void> _quickAdjustDeviceUHeight(
    RackDeviceModel dev,
    int newUHeight,
  ) async {
    if (!_canEdit) return;
    final rack = _rack;
    if (rack == null) return;
    final clamped = newUHeight.clamp(1, 16);
    if (clamped == dev.uHeight) return;

    final messenger = ScaffoldMessenger.of(context);
    if (!_canFitAtU(rack, dev.startU, clamped, excludeDeviceId: dev.id)) {
      final blocker = _findBlockingDevice(
        rack,
        dev.startU,
        clamped,
        excludeDeviceId: dev.id,
      );
      messenger.avisoError(blocker != null
                ? 'No se puede ampliar "${dev.code}" a ${clamped}U en U${dev.startU}-U${dev.startU + clamped - 1}: choca con "${blocker.code}" (U${blocker.startU}).'
                : 'No cabe "${dev.code}" con ${clamped}U en U${dev.startU} (excede U${rack.totalUnits}).');
      return;
    }

    try {
      final updatedCustom = Map<String, dynamic>.from(dev.customFields);
      updatedCustom['u_height_override'] = clamped;
      await widget.api.updateDevice(dev.id, {'custom_fields': updatedCustom});
      await _loadRack();
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          content: Text(
            'Altura de "${dev.code}" actualizada a ${clamped}U (ocupa U${dev.startU}${clamped > 1 ? '-U${dev.startU + clamped - 1}' : ''}).',
          ),
        ),
      );
    } catch (e) {
      messenger.avisoError('$e');
    }
  }

  Future<void> _moveDeviceToU(RackDeviceModel dev, int targetStartU) async {
    if (!_canEdit) return;
    final rack = _rack;
    if (rack == null) return;
    if (targetStartU == dev.startU) return;

    final uHeight = dev.uHeight;
    final targetEndU = targetStartU + uHeight - 1;
    final messenger = ScaffoldMessenger.of(context);

    if (targetStartU < 1 || targetEndU > rack.totalUnits) {
      messenger.avisoError('No se puede colocar "${dev.code}" ($uHeight U) en U$targetStartU: necesita hasta U$targetEndU y el rack tiene ${rack.totalUnits}U.');
      return;
    }

    final blocker = _findBlockingDevice(
      rack,
      targetStartU,
      uHeight,
      excludeDeviceId: dev.id,
    );
    if (blocker != null) {
      final rangeLabel =
          uHeight > 1 ? 'U$targetStartU-U$targetEndU' : 'U$targetStartU';
      final blockerRange = blocker.uHeight > 1
          ? 'U${blocker.startU}-U${blocker.endU}'
          : 'U${blocker.startU}';
      messenger.avisoError('No hay suficientes "U" libres en $rangeLabel para "${dev.code}" (${uHeight}U): ocupado por "${blocker.code}" ($blockerRange).');
      return;
    }

    final previousStartU = dev.startU;
    try {
      await widget.api.updateDevice(dev.id, {'start_u': targetStartU});
      _undoStack.add(
        _RackUndoAction(
          deviceId: dev.id,
          deviceCode: dev.code,
          previousStartU: previousStartU,
          newStartU: targetStartU,
        ),
      );
      if (_undoStack.length > 35) {
        _undoStack.removeAt(0);
      }
      await _loadRack();
      _rebuildState(() => _selectedDeviceId = dev.id);
      final rangeLabel =
          uHeight > 1 ? 'U$targetStartU-U$targetEndU' : 'U$targetStartU';
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 3),
          content: Text(
            'Equipo "${dev.code}" (${uHeight}U) movido a $rangeLabel libre (Ctrl+Z / ⌘Z para deshacer).',
          ),
          action: SnackBarAction(
            label: 'Deshacer',
            onPressed: _performUndo,
          ),
        ),
      );
    } catch (e) {
      messenger.avisoError('No se pudo mover a U$targetStartU: $e');
    }
  }

  Future<void> _showMoveDeviceToUDialog(RackDeviceModel dev) async {
    if (!_canEdit) return;
    final rack = _rack;
    if (rack == null) return;
    final uHeight = dev.uHeight;
    final maxU = rack.totalUnits - uHeight + 1;

    final freePositions = <int>[
      for (int u = maxU; u >= 1; u--)
        if (u == dev.startU ||
            _canFitAtU(rack, u, uHeight, excludeDeviceId: dev.id))
          u,
    ];

    int chosenU = dev.startU;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: Text('Mover "${dev.code}" (${uHeight}U) a U Libre'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Solo se muestran las posiciones que tienen ${uHeight}U libres consecutivas en el rack (o también puedes arrastrar el equipo directamente con el ratón):',
                  style: const TextStyle(fontSize: 12, color: AppPalette.slate600),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: chosenU,
                  decoration: InputDecoration(
                    labelText: 'Posición Destino (${uHeight}U libres)',
                  ),
                  items: [
                    for (final u in freePositions)
                      DropdownMenuItem(
                        value: u,
                        child: Text(
                          uHeight > 1
                              ? 'U$u - U${u + uHeight - 1} (${uHeight}U)${u == dev.startU ? ' • Posición actual' : ' • Libre'}'
                              : 'U$u (1U)${u == dev.startU ? ' • Posición actual' : ' • Libre'}',
                        ),
                      ),
                  ],
                  onChanged: (v) => setModal(() => chosenU = v ?? dev.startU),
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
              icon: const Icon(Icons.open_with_rounded, size: 16),
              label: const Text('Mover a U Libre'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true && chosenU != dev.startU) {
      await _moveDeviceToU(dev, chosenU);
    }
  }

  Future<void> _quickDeleteDevice(RackDeviceModel dev) async {
    if (!_canEdit) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.api.deleteDevice(dev.id);
      if (_selectedDeviceId == dev.id) {
        _selectedDeviceId = null;
      }
      await _loadRack();
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          content: Text(
            'Equipo "${dev.code}" desmontado y eliminado del rack (U${dev.startU}).',
          ),
        ),
      );
    } catch (e) {
      messenger.avisoError('$e');
    }
  }

  Future<void> _handleDropOnUSlot(
    Object droppedData,
    int targetStartU, {
    RackDeviceModel? targetMountedDevice,
  }) async {
    if (!_canEdit) return;
    _rebuildState(() {
      _draggingData = null;
      _hoveredDropU = null;
    });
    // Si suelta un mini-equipo de bandeja ("Bandeja - Equipos Mini") sobre una Bandeja ya montada
    if (droppedData is DeviceTemplateModel &&
        droppedData.isTrayMiniDevice &&
        targetMountedDevice != null &&
        targetMountedDevice.isRackTray) {
      await _showManageTrayItemsDialog(
        targetMountedDevice,
        initialAddTemplate: droppedData,
      );
      return;
    }
    if (droppedData is RackDeviceModel) {
      await _moveDeviceToU(droppedData, targetStartU);
    } else if (droppedData is DeviceTemplateModel) {
      await _handleDropOrMountTemplate(droppedData, targetStartU);
    }
  }

  /// Extrae el número de bocas RJ45, SFP/Fibra, PSU y Schuko tanto de FRONT como de BACK desde un layout_spec.
  Map<String, int> _extractPortCountsFromSpec(
    Map<String, dynamic> spec, {
    String category = 'switch',
  }) {
    int fRj = 0, fSfp = 0, fPsu = 0, fSch = 0;
    int bRj = 0, bSfp = 0, bPsu = 0, bSch = 0;

    void parseFace(dynamic rawList, bool isFront) {
      if (rawList is! List) return;
      for (final g in rawList) {
        if (g is! Map) continue;
        final pt = (g['port_type'] ?? 'rj45').toString().toLowerCase();
        final cnt = int.tryParse('${g['count'] ?? 0}') ?? 0;
        if (cnt <= 0) continue;
        if (pt.contains('sfp') || pt.contains('fiber') || pt.contains('qsfp')) {
          if (isFront) {
            fSfp += cnt;
          } else {
            bSfp += cnt;
          }
        } else if (pt.contains('schuko')) {
          if (isFront) {
            fSch += cnt;
          } else {
            bSch += cnt;
          }
        } else if (pt.contains('power') || pt.contains('c14') || pt.contains('c13')) {
          if (isFront) {
            fPsu += cnt;
          } else {
            bPsu += cnt;
          }
        } else {
          if (isFront) {
            fRj += cnt;
          } else {
            bRj += cnt;
          }
        }
      }
    }

    parseFace(spec['front'], true);
    parseFace(spec['back'], false);

    if (spec['back'] == null &&
        bRj == 0 &&
        bSfp == 0 &&
        bPsu == 0 &&
        bSch == 0 &&
        category != 'rack_tray') {
      bPsu = 2;
    }

    return {
      'front_rj45': fRj,
      'front_sfp': fSfp,
      'front_psu': fPsu,
      'front_schuko': fSch,
      'back_rj45': bRj,
      'back_sfp': bSfp,
      'back_psu': bPsu,
      'back_schuko': bSch,
    };
  }

  /// Construye la lista de grupos de puertos (RJ45, SFP/Fibra, PSU C14, Schuko) para una cara ('front' o 'back')
  /// repartiendo proporcionalmente el espacio horizontal [0.14 .. 0.92] para que no se solapen.
  List<Map<String, dynamic>> _buildFacePortGroups({
    required int rj45Count,
    required int sfpCount,
    required int psuCount,
    required int schukoCount,
    required bool isBackFace,
  }) {
    final rawBlocks = <Map<String, dynamic>>[];
    if (psuCount > 0) {
      rawBlocks.add({
        'port_type': 'power_c14',
        'prefix': isBackFace ? 'PSU' : 'F-PSU',
        'count': psuCount,
        'rows': 1,
        'weight': psuCount.clamp(1, 4).toDouble() * 1.2,
      });
    }
    if (rj45Count > 0) {
      rawBlocks.add({
        'port_type': 'rj45',
        'prefix': isBackFace ? 'B-ETH' : '',
        'count': rj45Count,
        'rows': rj45Count >= 12 ? 2 : 1,
        'weight': (rj45Count >= 12 ? (rj45Count / 2.0) : rj45Count.toDouble())
            .clamp(2.0, 16.0),
      });
    }
    if (sfpCount > 0) {
      final useTwoSfpRows = sfpCount >= 4 || (sfpCount >= 2 && rj45Count >= 12);
      rawBlocks.add({
        'port_type': 'sfp_plus',
        'prefix': isBackFace ? 'B-SFP' : 'SFP',
        'count': sfpCount,
        'rows': useTwoSfpRows ? 2 : 1,
        'weight': (useTwoSfpRows ? (sfpCount / 2.0) : sfpCount.toDouble())
                .clamp(1.5, 10.0) *
            1.15,
      });
    }
    if (schukoCount > 0) {
      rawBlocks.add({
        'port_type': 'power_schuko',
        'prefix': isBackFace ? 'B-SCH' : 'SCH',
        'count': schukoCount,
        'rows': 1,
        'weight': schukoCount.clamp(1, 10).toDouble() * 1.3,
      });
    }

    if (rawBlocks.isEmpty) return [];

    final totalWeight =
        rawBlocks.fold<double>(0.0, (sum, b) => sum + (b['weight'] as double));
    const double minX = 0.14;
    const double maxX = 0.92;
    final double gap = rawBlocks.length > 1 ? 0.04 : 0.0;
    final double usableWidth = maxX - minX - gap * (rawBlocks.length - 1);

    double cursor = minX;
    final result = <Map<String, dynamic>>[];
    for (int i = 0; i < rawBlocks.length; i++) {
      final b = rawBlocks[i];
      final w = b['weight'] as double;
      final span = usableWidth * (w / totalWeight);
      final sx = cursor;
      final ex = (cursor + span).clamp(sx + 0.04, maxX);
      result.add({
        'port_type': b['port_type'],
        'prefix': b['prefix'],
        'count': b['count'],
        'rows': b['rows'],
        'start_x': double.parse(sx.toStringAsFixed(3)),
        'end_x': double.parse(ex.toStringAsFixed(3)),
      });
      cursor = ex + gap;
    }
    return result;
  }

  // ===========================================================================
  // GESTIÓN DE EQUIPOS PEQUEÑOS / NO ENRACABLES DENTRO DE UNA BANDEJA (TRAY)
  // ===========================================================================
  Future<void> _showManageTrayItemsDialog(
    RackDeviceModel trayDev, {
    DeviceTemplateModel? initialAddTemplate,
    Map<String, dynamic>? initialCmdbAsset,
  }) async {
    if (!_canEdit) return;
    final messenger = ScaffoldMessenger.of(context);
    final miniTemplates =
        widget.templates.where((t) => t.isTrayMiniDevice).toList();
    if (miniTemplates.isEmpty) {
      messenger.aviso('No se encontraron plantillas en la librería "Bandeja - Equipos Mini".');
      return;
    }

    List<Map<String, dynamic>> cmdbAssets = [];
    try {
      final overview = await widget.api.fetchCmdbOverview();
      cmdbAssets = ((overview['assets'] as List?) ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      cmdbAssets.sort((a, b) {
        final aUnplaced =
            (a['rack_device_id'] == null && a['rack_id'] == null) ? 0 : 1;
        final bUnplaced =
            (b['rack_device_id'] == null && b['rack_id'] == null) ? 0 : 1;
        if (aUnplaced != bUnplaced) return aUnplaced.compareTo(bUnplaced);
        return (a['code'] ?? '')
            .toString()
            .compareTo((b['code'] ?? '').toString());
      });
    } catch (_) {}
    if (!mounted) return;

    final items = trayDev.trayItems
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    DeviceTemplateModel selectedTpl = initialAddTemplate ?? miniTemplates.first;
    int? selectedCmdbAssetId;
    Map<String, dynamic>? selectedCmdbAsset;

    String suggestCodeFor(DeviceTemplateModel t, int index) {
      final m = t.modelName.toUpperCase();
      if (m.contains('ONT') || m.contains('GPON')) return 'ONT$index';
      if (m.contains('FORTI')) return 'FW$index';
      if (m.contains('MIKROTIK') || m.contains('CISCO') || m.contains('RUTX')) {
        return 'RTR$index';
      }
      if (m.contains('SWITCH')) return 'SWM$index';
      if (m.contains('CONVERSOR')) return 'MC$index';
      if (m.contains('NUC') ||
          m.contains('TINY') ||
          m.contains('MAC') ||
          m.contains('RASPBERRY')) {
        return 'PC$index';
      }
      return 'EQ$index';
    }

    final initialCounts = _extractPortCountsFromSpec(
      selectedTpl.layoutSpec,
      category: selectedTpl.category,
    );
    final fRjCtrl = TextEditingController(text: '${initialCounts['front_rj45']}');
    final fSfpCtrl = TextEditingController(text: '${initialCounts['front_sfp']}');
    final fPsuCtrl = TextEditingController(text: '${initialCounts['front_psu']}');
    final bRjCtrl = TextEditingController(text: '${initialCounts['back_rj45']}');
    final bSfpCtrl = TextEditingController(text: '${initialCounts['back_sfp']}');
    final bPsuCtrl = TextEditingController(text: '${initialCounts['back_psu']}');

    final codeCtrl = TextEditingController(
      text: suggestCodeFor(selectedTpl, items.length + 1),
    );
    final nameCtrl = TextEditingController(
      text: '${selectedTpl.manufacturer} ${selectedTpl.modelName}',
    );
    final ipCtrl = TextEditingController(
      text: '10.28.1.${60 + trayDev.startU * 2 + items.length}',
    );

    void applyTrayCmdbAsset(Map<String, dynamic>? ast) {
      selectedCmdbAsset = ast;
      selectedCmdbAssetId = (ast?['id'] as num?)?.toInt();
      if (ast == null) return;
      final rawCode = (ast['code'] ?? '').toString().trim();
      if (rawCode.isNotEmpty &&
          !rawCode.startsWith('DISC-') &&
          !rawCode.startsWith('FLR-')) {
        codeCtrl.text = rawCode;
      }
      final rawName = (ast['name'] ?? '').toString().trim();
      if (rawName.isNotEmpty && !rawName.startsWith('Equipo Detectado')) {
        nameCtrl.text = rawName;
      }
      final resIp =
          (ast['_resolved_ip'] ?? ast['heartbeat_ip'] ?? '').toString().trim();
      if (resIp.isNotEmpty) {
        ipCtrl.text = resIp;
      }
      final modelHint =
          '${ast['model_name'] ?? ''} ${ast['name'] ?? ''}'.toLowerCase();
      for (final mt in miniTemplates) {
        if (modelHint.contains(mt.manufacturer.toLowerCase()) ||
            modelHint.contains(mt.modelName.toLowerCase())) {
          selectedTpl = mt;
          break;
        }
      }
    }

    if (initialCmdbAsset != null) {
      applyTrayCmdbAsset(initialCmdbAsset);
    }

    Map<String, dynamic> buildTrayItemSpec() {
      return {
        'front': _buildFacePortGroups(
          rj45Count: int.tryParse(fRjCtrl.text.trim()) ?? 0,
          sfpCount: int.tryParse(fSfpCtrl.text.trim()) ?? 0,
          psuCount: int.tryParse(fPsuCtrl.text.trim()) ?? 0,
          schukoCount: 0,
          isBackFace: false,
        ),
        'back': _buildFacePortGroups(
          rj45Count: int.tryParse(bRjCtrl.text.trim()) ?? 0,
          sfpCount: int.tryParse(bSfpCtrl.text.trim()) ?? 0,
          psuCount: int.tryParse(bPsuCtrl.text.trim()) ?? 0,
          schukoCount: 0,
          isBackFace: true,
        ),
      };
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: Row(
            children: [
              const Icon(
                Icons.inbox_outlined,
                color: AppPalette.blue700,
                size: 22,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Equipos Alojados en Bandeja ${trayDev.code} (U${trayDev.startU})',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 610,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppPalette.blue50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppPalette.blue300),
                    ),
                    child: const Text(
                      '💡 En una Bandeja puedes colocar hasta 4 equipos pequeños o de sobremesa (Routers, Mini-Switches, ONTs, Mini-PCs). Puedes definir sus bocas RJ45, SFP Fibra y Tomas Eléctricas tanto por DELANTE (Front) como por DETRÁS (Back).',
                      style: TextStyle(fontSize: 11.5, color: AppPalette.blue900),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '1. EQUIPOS ACTUALMENTE EN LA BANDEJA (${items.length} / 4 máx.):',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: AppPalette.slate900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (items.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppPalette.slate50,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppPalette.slate200),
                      ),
                      child: const Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 16,
                            color: AppPalette.slate500,
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'La bandeja está vacía. Selecciona abajo un Router, Switch o Mini-PC para colocarlo encima.',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: AppPalette.slate500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    ...items.asMap().entries.map((entry) {
                      final idx = entry.key;
                      final it = entry.value;
                      return Container(
                        margin: const EdgeInsets.only(bottom: 6),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: AppPalette.slate50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppPalette.slate300),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: AppPalette.slate800,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '#${idx + 1} • ${it['code'] ?? 'EQ${idx + 1}'}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '${it['name'] ?? it['model_name'] ?? 'Mini Equipo'}',
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: AppPalette.slate900,
                                    ),
                                  ),
                                  Text(
                                    'Modelo: ${it['manufacturer'] ?? ''} ${it['model_name'] ?? ''}${it['ip_address']?.toString().isNotEmpty == true ? ' • IP: ${it['ip_address']}' : ''}',
                                    style: const TextStyle(
                                      fontSize: 10.5,
                                      color: AppPalette.slate500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              onPressed: () {
                                setModal(() {
                                  items.removeAt(idx);
                                });
                              },
                              icon: const Icon(
                                Icons.delete_outline,
                                size: 17,
                                color: AppPalette.red600,
                              ),
                              tooltip: 'Sacar este equipo de la bandeja',
                              visualDensity: VisualDensity.compact,
                            ),
                          ],
                        ),
                      );
                    }),

                  const Divider(height: 24),
                  const Text(
                    '2. METER NUEVO EQUIPO EN ESTA BANDEJA (Routers, Switches, ONTs, Mini-PCs):',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: AppPalette.blue900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Selector CMDB para equipo de bandeja
                  Container(
                    padding: const EdgeInsets.all(10),
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      color: selectedCmdbAsset != null
                          ? const Color(0xFFF0FDF4)
                          : const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: selectedCmdbAsset != null
                            ? const Color(0xFF22C55E)
                            : AppPalette.blue300,
                        width: 1.3,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.fact_check_outlined,
                              size: 16,
                              color: selectedCmdbAsset != null
                                  ? const Color(0xFF15803D)
                                  : AppPalette.blue900,
                            ),
                            const SizedBox(width: 6),
                            const Expanded(
                              child: Text(
                                '0. ¿Seleccionar equipo ya detectado / registrado en la CMDB?',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w900,
                                  color: AppPalette.slate900,
                                ),
                              ),
                            ),
                            if (selectedCmdbAsset != null)
                              TextButton.icon(
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  foregroundColor: AppPalette.red600,
                                ),
                                onPressed: () => setModal(() {
                                  applyTrayCmdbAsset(null);
                                }),
                                icon: const Icon(Icons.link_off, size: 14),
                                label: const Text(
                                  'Desvincular',
                                  style: TextStyle(fontSize: 11),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        if (cmdbAssets.isNotEmpty) ...[
                          DropdownButtonFormField<int?>(
                            key: ValueKey('tray_cmdb_$selectedCmdbAssetId'),
                            initialValue: cmdbAssets.any(
                              (a) =>
                                  (a['id'] as num?)?.toInt() ==
                                  selectedCmdbAssetId,
                            )
                                ? selectedCmdbAssetId
                                : null,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText:
                                  'Elegir directamente de la lista CMDB (o usa el Explorador por Redes abajo)',
                              prefixIcon: Icon(
                                Icons.inventory_2_outlined,
                                size: 17,
                              ),
                              isDense: true,
                              filled: true,
                              fillColor: Colors.white,
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                            ),
                            items: [
                              const DropdownMenuItem<int?>(
                                value: null,
                                child: Text(
                                  '— Nuevo equipo (Sin vincular a CMDB) —',
                                  style: TextStyle(fontSize: 12),
                                ),
                              ),
                              for (final ast in cmdbAssets)
                                DropdownMenuItem<int?>(
                                  value: (ast['id'] as num?)?.toInt(),
                                  child: Text(
                                    '[${ast['code']}] ${ast['name']} • ${(ast['heartbeat_ip'] ?? '').toString().isNotEmpty ? ast['heartbeat_ip'] : 'Sin IP'}${(ast['rack_device_id'] == null && ast['rack_id'] == null) ? ' (SIN RACK)' : ''}',
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                            ],
                            onChanged: (astId) {
                              setModal(() {
                                if (astId == null) {
                                  applyTrayCmdbAsset(null);
                                } else {
                                  final found = cmdbAssets.firstWhere(
                                    (a) => (a['id'] as num?)?.toInt() == astId,
                                  );
                                  applyTrayCmdbAsset(found);
                                }
                              });
                            },
                          ),
                          const SizedBox(height: 6),
                        ],
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              backgroundColor: Colors.white,
                              side: const BorderSide(color: AppPalette.blue600),
                            ),
                            onPressed: () async {
                              final picked = await CmdbAssetExplorerDialog.show(
                                ctx,
                                api: widget.api,
                                initialAssets:
                                    cmdbAssets.isNotEmpty ? cmdbAssets : null,
                                contextMode: 'rack',
                                preselectedAssetId: selectedCmdbAssetId,
                                title:
                                    'Seleccionar Equipo de la CMDB para Bandeja ${trayDev.code}',
                                subtitle:
                                    'Navega por las Redes / Subredes (Máscara CIDR) y elige el activo para autocompletar sus datos.',
                              );
                              if (picked != null) {
                                setModal(() => applyTrayCmdbAsset(picked));
                              }
                            },
                            icon: const Icon(
                              Icons.manage_search_rounded,
                              size: 16,
                              color: AppPalette.blue700,
                            ),
                            label: Text(
                              selectedCmdbAsset != null
                                  ? 'Cambiar Equipo de la CMDB (Explorador por Redes / Máscara)'
                                  : 'Abrir Explorador CMDB por Redes / Máscara de Red...',
                              style: const TextStyle(
                                fontSize: 11.2,
                                fontWeight: FontWeight.w800,
                                color: AppPalette.blue900,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  DropdownButtonFormField<DeviceTemplateModel>(
                    initialValue: selectedTpl,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Modelo de la Librería "Bandeja - Equipos Mini"',
                      isDense: true,
                    ),
                    items: miniTemplates
                        .map(
                          (t) => DropdownMenuItem(
                            value: t,
                            child: Text(
                              '${t.manufacturer} — ${t.modelName}',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (t) {
                      if (t == null) return;
                      setModal(() {
                        selectedTpl = t;
                        codeCtrl.text = suggestCodeFor(t, items.length + 1);
                        nameCtrl.text = '${t.manufacturer} ${t.modelName}';
                        final cnts = _extractPortCountsFromSpec(
                          t.layoutSpec,
                          category: t.category,
                        );
                        fRjCtrl.text = '${cnts['front_rj45']}';
                        fSfpCtrl.text = '${cnts['front_sfp']}';
                        fPsuCtrl.text = '${cnts['front_psu']}';
                        bRjCtrl.text = '${cnts['back_rj45']}';
                        bSfpCtrl.text = '${cnts['back_sfp']}';
                        bPsuCtrl.text = '${cnts['back_psu']}';
                      });
                    },
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: codeCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Código (ej. ONT1, SWM1, NUC1)',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: nameCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Nombre / Función en Bandeja',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: ipCtrl,
                          decoration: const InputDecoration(
                            labelText: 'IP (Opcional)',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Bocas en FRONT (Delante) y BACK (Detrás) de este mini-equipo:',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppPalette.slate700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: fRjCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'RJ45 (Front)',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: TextField(
                          controller: fSfpCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'SFP Fibra (Front)',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: TextField(
                          controller: fPsuCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'PSU (Front)',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: bRjCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'RJ45 (Back)',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: TextField(
                          controller: bSfpCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'SFP Fibra (Back)',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: TextField(
                          controller: bPsuCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'PSU (Back)',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonalIcon(
                      onPressed: items.length >= 4
                          ? null
                          : () {
                              setModal(() {
                                items.add({
                                  'template_id': selectedTpl.id,
                                  'code': codeCtrl.text.trim().isEmpty
                                      ? suggestCodeFor(
                                          selectedTpl,
                                          items.length + 1,
                                        )
                                      : codeCtrl.text.trim().toUpperCase(),
                                  'name': nameCtrl.text.trim().isEmpty
                                      ? '${selectedTpl.manufacturer} ${selectedTpl.modelName}'
                                      : nameCtrl.text.trim(),
                                  'manufacturer': selectedTpl.manufacturer,
                                  'model_name': selectedTpl.modelName,
                                  'ip_address': ipCtrl.text.trim(),
                                  'cmdb_asset_id': ?selectedCmdbAssetId,
                                  'layout_spec': buildTrayItemSpec(),
                                });
                                codeCtrl.text = suggestCodeFor(
                                  selectedTpl,
                                  items.length + 1,
                                );
                              });
                            },
                      icon: const Icon(Icons.add_box_outlined, size: 16),
                      label: Text(
                        items.length >= 4
                            ? 'Bandeja llena (máx. 4 equipos)'
                            : '+ Añadir a la Bandeja (${items.length}/4)',
                      ),
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
              onPressed: () {
                if ((initialAddTemplate != null || initialCmdbAsset != null) &&
                    items.length == trayDev.trayItems.length &&
                    items.length < 4) {
                  items.add({
                    'template_id': selectedTpl.id,
                    'code': codeCtrl.text.trim().isEmpty
                        ? suggestCodeFor(selectedTpl, items.length + 1)
                        : codeCtrl.text.trim().toUpperCase(),
                    'name': nameCtrl.text.trim().isEmpty
                        ? '${selectedTpl.manufacturer} ${selectedTpl.modelName}'
                        : nameCtrl.text.trim(),
                    'manufacturer': selectedTpl.manufacturer,
                    'model_name': selectedTpl.modelName,
                    'ip_address': ipCtrl.text.trim(),
                    'cmdb_asset_id': ?selectedCmdbAssetId,
                    'layout_spec': buildTrayItemSpec(),
                  });
                }
                Navigator.pop(ctx, true);
              },
              icon: const Icon(Icons.save_outlined, size: 16),
              label: const Text('Guardar Bandeja y Generar Puertos'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      try {
        final updatedCustom = Map<String, dynamic>.from(trayDev.customFields);
        updatedCustom['tray_items'] = items;
        await widget.api.updateDevice(trayDev.id, {
          'custom_fields': updatedCustom,
        });
        await _loadRack();
        _rebuildState(() {
          _selectedDeviceId = trayDev.id;
        });
        messenger.aviso('Bandeja "${trayDev.code}" actualizada con ${items.length} equipo(s) alojado(s) y sus bocas RJ45/Fibra/PSU sincronizadas.');
      } catch (e) {
        messenger.avisoError('$e');
      }
    }
  }

  // ===========================================================================
  // SELECTOR EN CASCADA (GRUPO ➔ CATEGORÍA ➔ DISPOSITIVO CONCRETO) AL PULSAR "+" EN UNA U LIBRE
  // ===========================================================================
  static const Map<String, String> _quickCategoryLabels = {
    'switch': 'Switch (Conmutador Red)',
    'router': 'Router',
    'firewall': 'Firewall / NGFW',
    'gateway': 'Gateway / Fibra / Voz',
    'server': 'Servidor / Host Rack',
    'storage_san': 'Cabina Storage SAN (FC / NVMe / iSCSI)',
    'storage_nas': 'Cabina Storage NAS',
    'pdu': 'PDU / Regleta Eléctrica Schuko/C13',
    'ups': 'SAI / UPS',
    'patch_panel': 'Patch Panel Cobre/Fibra',
    'patchbox': 'PATCHBOX',
    'cable_manager': 'Pasacables / Guía Hilos',
    'rack_tray': 'Bandeja de Rack 19"',
    'rack_tray_device': 'Mini-Equipo sobre Bandeja (Router/Switch/Mini-PC)',
    'miscellaneous': 'Accesorios / Ventiladores / Panel Ciego',
  };

  Future<void> _openInstallFromCmdbAtFirstFreeU() async {
    final rack = _rack;
    if (rack == null || !_canEdit) return;
    int firstFreeU = rack.totalUnits;
    for (int u = rack.totalUnits; u >= 1; u--) {
      if (_canFitAtU(rack, u, 1)) {
        firstFreeU = u;
        break;
      }
    }
    await _showQuickInstallAtUDialog(
      firstFreeU,
      _activeFace == 'back' ? 'back' : 'front',
      focusCmdbSelector: true,
    );
  }

  Future<void> _showQuickInstallAtUDialog(
    int initialTargetU,
    String initialFace, {
    bool focusCmdbSelector = false,
  }) async {
    if (!_canEdit) return;
    final rack = _rack;
    if (rack == null) return;

    int targetU = initialTargetU;
    String face = initialFace;

    final availableTemplates = widget.templates
        .where(
          (t) =>
              t.category != 'external_outlet' &&
              t.category != 'external_power_feed' &&
              t.libraryGroup != 'External Power',
        )
        .toList();
    if (availableTemplates.isEmpty) return;

    List<Map<String, dynamic>> cmdbAssets = [];
    try {
      final overview = await widget.api.fetchCmdbOverview();
      cmdbAssets = ((overview['assets'] as List?) ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      cmdbAssets.sort((a, b) {
        final aUnplaced =
            (a['rack_device_id'] == null && a['rack_id'] == null) ? 0 : 1;
        final bUnplaced =
            (b['rack_device_id'] == null && b['rack_id'] == null) ? 0 : 1;
        if (aUnplaced != bUnplaced) return aUnplaced.compareTo(bUnplaced);
        return (a['code'] ?? '')
            .toString()
            .compareTo((b['code'] ?? '').toString());
      });
    } catch (_) {}
    if (!mounted) return;

    // 1. Construir lista ordenada de Grupos / Librerías
    const preferredOrder = [
      'Network',
      'Power',
      'Host - HP',
      'Host - Dell',
      'Host - Supermicro',
      'Storage - SAN',
      'Storage - NAS',
      'Patching & Passive',
      'Bandeja - Equipos Mini',
    ];
    final groupSet = <String>{};
    for (final g in preferredOrder) {
      if (availableTemplates.any(
        (t) => t.libraryGroup.toLowerCase() == g.toLowerCase(),
      )) {
        groupSet.add(g);
      }
    }
    for (final t in availableTemplates) {
      final g = t.libraryGroup.trim();
      if (g.isNotEmpty) groupSet.add(g);
    }
    final groups = groupSet.toList();

    String selectedGroup =
        (_selectedLibraryGroup != 'all' &&
                groups.contains(_selectedLibraryGroup))
            ? _selectedLibraryGroup
            : (groups.isNotEmpty ? groups.first : 'Network');
    String selectedCategory = 'all';

    List<DeviceTemplateModel> templatesForSelection(
      String grp,
      String cat,
    ) {
      return availableTemplates.where((t) {
        final matchGrp =
            grp == 'all' || t.libraryGroup.toLowerCase() == grp.toLowerCase();
        if (!matchGrp) return false;
        final matchCat = cat == 'all' || t.category == cat;
        return matchCat;
      }).toList();
    }

    List<String> categoriesForGroup(String grp) {
      final cats = <String>{};
      for (final t in availableTemplates) {
        if (grp == 'all' || t.libraryGroup.toLowerCase() == grp.toLowerCase()) {
          cats.add(t.category);
        }
      }
      return cats.toList();
    }

    var filteredList = templatesForSelection(selectedGroup, selectedCategory);
    DeviceTemplateModel? selectedTemplate =
        filteredList.isNotEmpty ? filteredList.first : availableTemplates.first;
    int? selectedCmdbAssetId;
    Map<String, dynamic>? selectedCmdbAsset;

    void autoMatchTemplateFromCmdb(Map<String, dynamic> asset) {
      final assetClass = (asset['asset_class'] ?? '').toString().toLowerCase();
      final modelStr =
          '${asset['manufacturer'] ?? ''} ${asset['model_name'] ?? ''} ${asset['name'] ?? ''}'
              .toLowerCase();

      // 1. Buscar coincidencia directa por nombre de modelo/fabricante en el catálogo
      for (final t in availableTemplates) {
        final mName = t.modelName.toLowerCase();
        if (mName.length >= 4 && modelStr.contains(mName)) {
          selectedGroup = t.libraryGroup;
          selectedCategory = t.category;
          selectedTemplate = t;
          return;
        }
      }

      // 2. Mapear clase CMDB a grupo y categoría del catálogo de Rack
      if (assetClass.contains('switch')) {
        selectedGroup = 'Network';
        selectedCategory = 'switch';
      } else if (assetClass.contains('router') || assetClass.contains('gateway')) {
        selectedGroup = 'Network';
        selectedCategory = 'router';
      } else if (assetClass.contains('firewall')) {
        selectedGroup = 'Network';
        selectedCategory = 'firewall';
      } else if (assetClass.contains('storage') || assetClass.contains('nas')) {
        selectedGroup = groups.contains('Storage - NAS') ? 'Storage - NAS' : 'Network';
        selectedCategory = 'all';
      } else if (assetClass.contains('san')) {
        selectedGroup = groups.contains('Storage - SAN') ? 'Storage - SAN' : 'Network';
        selectedCategory = 'all';
      } else if (assetClass.contains('ups') || assetClass.contains('pdu')) {
        selectedGroup = 'Power';
        selectedCategory = 'all';
      } else if (assetClass.contains('server') ||
          assetClass.contains('hypervisor') ||
          assetClass.contains('host')) {
        if (modelStr.contains('dell') && groups.contains('Host - Dell')) {
          selectedGroup = 'Host - Dell';
        } else if (modelStr.contains('supermicro') &&
            groups.contains('Host - Supermicro')) {
          selectedGroup = 'Host - Supermicro';
        } else if (groups.contains('Host - HP')) {
          selectedGroup = 'Host - HP';
        }
        selectedCategory = 'all';
      }
      final nextList = templatesForSelection(selectedGroup, selectedCategory);
      if (nextList.isNotEmpty) {
        selectedTemplate = nextList.first;
      }
    }

    final chosenResult = await showDialog<
        ({
          DeviceTemplateModel template,
          Map<String, dynamic>? cmdbAsset,
          int targetU,
          String face,
        })>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) {
          final groupCategories = categoriesForGroup(selectedGroup);
          if (selectedCategory != 'all' &&
              !groupCategories.contains(selectedCategory)) {
            selectedCategory = 'all';
          }
          filteredList = templatesForSelection(selectedGroup, selectedCategory);
          if (selectedTemplate == null ||
              !filteredList.any((t) => t.id == selectedTemplate!.id)) {
            selectedTemplate =
                filteredList.isNotEmpty ? filteredList.first : null;
          }

          final tpl = selectedTemplate;
          final bool fits = tpl != null &&
              (tpl.isTrayMiniDevice
                  ? _canFitAtU(rack, targetU, 1)
                  : _canFitAtU(rack, targetU, tpl.uHeight));
          final counts = tpl != null
              ? _extractPortCountsFromSpec(
                  tpl.layoutSpec,
                  category: tpl.category,
                )
              : null;

          return AlertDialog(
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: AppPalette.blue100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.add_circle_outline,
                    color: AppPalette.blue700,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Instalar Dispositivo en U$targetU (${face.toUpperCase()})',
                        style: const TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const Text(
                        'Puedes elegir un equipo ya existente en la CMDB o seleccionar su plantilla física del catálogo',
                        style: TextStyle(
                          fontSize: 11,
                          color: AppPalette.slate500,
                          fontWeight: FontWeight.w500,
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
                    // PASO 0: SELECCIONAR EQUIPO YA EXISTENTE EN LA CMDB (IGUAL QUE EN DATACENTERS Y RED & HOST)
                    Container(
                      padding: const EdgeInsets.all(10),
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: selectedCmdbAsset != null
                            ? const Color(0xFFF0FDF4)
                            : const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: selectedCmdbAsset != null
                              ? const Color(0xFF22C55E)
                              : AppPalette.blue300,
                          width: focusCmdbSelector ? 1.8 : 1.3,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.account_tree_rounded,
                                size: 16,
                                color: selectedCmdbAsset != null
                                    ? const Color(0xFF15803D)
                                    : AppPalette.blue900,
                              ),
                              const SizedBox(width: 6),
                              const Expanded(
                                child: Text(
                                  '0. ¿Seleccionar equipo ya detectado / registrado en la CMDB?',
                                  style: TextStyle(
                                    fontSize: 11.8,
                                    fontWeight: FontWeight.w900,
                                    color: AppPalette.slate900,
                                  ),
                                ),
                              ),
                              if (selectedCmdbAsset != null)
                                TextButton.icon(
                                  style: TextButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    foregroundColor: AppPalette.red600,
                                  ),
                                  onPressed: () {
                                    setModal(() {
                                      selectedCmdbAssetId = null;
                                      selectedCmdbAsset = null;
                                    });
                                  },
                                  icon: const Icon(Icons.link_off, size: 14),
                                  label: const Text(
                                    'Desvincular',
                                    style: TextStyle(fontSize: 11),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          if (cmdbAssets.isNotEmpty) ...[
                            DropdownButtonFormField<int?>(
                              key: ValueKey('quick_cmdb_$selectedCmdbAssetId'),
                              initialValue: cmdbAssets.any(
                                      (a) => a['id'] == selectedCmdbAssetId)
                                  ? selectedCmdbAssetId
                                  : null,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText:
                                    'Seleccionar directamente activo de 6. CMDB (Autocompleta Nombre, IP, Hostname y Modelo)',
                                prefixIcon: Icon(
                                  Icons.inventory_2_outlined,
                                  size: 17,
                                  color: AppPalette.blue700,
                                ),
                                isDense: true,
                                filled: true,
                                fillColor: Colors.white,
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 9,
                                ),
                              ),
                              items: [
                                const DropdownMenuItem<int?>(
                                  value: null,
                                  child: Text(
                                    '— Crear nuevo equipo desde cero (o selecciona uno de la CMDB) —',
                                    style: TextStyle(
                                      fontSize: 11.8,
                                      color: AppPalette.slate500,
                                    ),
                                  ),
                                ),
                                ...cmdbAssets.map((a) {
                                  final id = (a['id'] as num?)?.toInt();
                                  final code = (a['code'] ?? '').toString();
                                  final name = (a['name'] ?? '').toString();
                                  final ip = (a['_resolved_ip'] ??
                                          a['heartbeat_ip'] ??
                                          a['ip_address'] ??
                                          '')
                                      .toString();
                                  return DropdownMenuItem<int?>(
                                    value: id,
                                    child: Text(
                                      '[$code] $name ${ip.isNotEmpty ? "• IP: $ip" : ""}',
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  );
                                }),
                              ],
                              onChanged: (val) {
                                setModal(() {
                                  selectedCmdbAssetId = val;
                                  if (val == null) {
                                    selectedCmdbAsset = null;
                                  } else {
                                    final picked = cmdbAssets.firstWhere(
                                      (a) => a['id'] == val,
                                    );
                                    selectedCmdbAsset = picked;
                                    autoMatchTemplateFromCmdb(picked);
                                  }
                                });
                              },
                            ),
                            const SizedBox(height: 6),
                          ],
                          if (selectedCmdbAsset != null)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 6,
                              ),
                              margin: const EdgeInsets.only(bottom: 6),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: const Color(0xFF86EFAC),
                                ),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.check_circle,
                                    size: 15,
                                    color: Color(0xFF16A34A),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      'Activo CMDB seleccionado: [${selectedCmdbAsset!['code']}] ${selectedCmdbAsset!['name']} '
                                      '• IP: ${selectedCmdbAsset!['_resolved_ip'] ?? selectedCmdbAsset!['heartbeat_ip'] ?? "Sin IP"}',
                                      style: const TextStyle(
                                        fontSize: 11.2,
                                        fontWeight: FontWeight.w800,
                                        color: Color(0xFF14532D),
                                      ),
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
                                side:
                                    const BorderSide(color: AppPalette.blue600),
                              ),
                              onPressed: () async {
                                final picked =
                                    await CmdbAssetExplorerDialog.show(
                                  ctx,
                                  api: widget.api,
                                  contextMode: 'rack',
                                  preselectedAssetId: selectedCmdbAssetId,
                                  title:
                                      'Seleccionar Equipo de la CMDB para Montar en U$targetU',
                                  subtitle:
                                      'Navega por las Redes / Subredes (Máscara CIDR) en la columna izquierda y elige el activo para autocompletar todos sus datos.',
                                );
                                if (picked != null) {
                                  setModal(() {
                                    selectedCmdbAsset = picked;
                                    selectedCmdbAssetId =
                                        (picked['id'] as num?)?.toInt();
                                    if (!cmdbAssets.any(
                                      (a) => a['id'] == selectedCmdbAssetId,
                                    )) {
                                      cmdbAssets = [picked, ...cmdbAssets];
                                    }
                                    autoMatchTemplateFromCmdb(picked);
                                  });
                                }
                              },
                              icon: const Icon(
                                Icons.manage_search_rounded,
                                size: 17,
                                color: AppPalette.blue700,
                              ),
                              label: Text(
                                selectedCmdbAsset != null
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
                        ],
                      ),
                    ),

                    // POSICIÓN U Y CARA DE MONTAJE (ÚTIL CUANDO SE ABRE DESDE "+ DESDE CMDB")
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            key: ValueKey('pos_u_$targetU'),
                            initialValue: targetU,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Posición en Rack (Unidad U)',
                              prefixIcon: Icon(
                                Icons.vertical_align_center_rounded,
                                size: 17,
                              ),
                              isDense: true,
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 9,
                              ),
                            ),
                            items: [
                              for (int u = rack.totalUnits; u >= 1; u--)
                                DropdownMenuItem<int>(
                                  value: u,
                                  child: Text(
                                    'U$u ${_canFitAtU(rack, u, 1) ? "(Libre)" : "(Ocupada)"}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: _canFitAtU(rack, u, 1)
                                          ? AppPalette.slate900
                                          : AppPalette.slate400,
                                    ),
                                  ),
                                ),
                            ],
                            onChanged: (val) {
                              if (val != null) {
                                setModal(() => targetU = val);
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            key: ValueKey('pos_face_$face'),
                            initialValue: face,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: 'Cara del Bastidor',
                              prefixIcon: Icon(Icons.flip_rounded, size: 17),
                              isDense: true,
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 9,
                              ),
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'front',
                                child: Text(
                                  'Cara Frontal (FRONT)',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              DropdownMenuItem(
                                value: 'back',
                                child: Text(
                                  'Cara Trasera (BACK)',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                            onChanged: (val) {
                              if (val != null) {
                                setModal(() => face = val);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // PASO 1: DESPLEGABLE DE GRUPO / LIBRERÍA
                    const Text(
                      '1. GRUPO / FAMILIA DE EQUIPOS (PLANTILLA CHASIS):',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: AppPalette.blue900,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 6),
                    DropdownButtonFormField<String>(
                      key: ValueKey('grp_$selectedGroup'),
                      initialValue: selectedGroup,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.folder_outlined, size: 18),
                        isDense: true,
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                      items: [
                        for (final g in groups)
                          DropdownMenuItem<String>(
                            value: g,
                            child: Text(
                              '$g (${availableTemplates.where((t) => t.libraryGroup.toLowerCase() == g.toLowerCase()).length} modelos)',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        DropdownMenuItem<String>(
                          value: 'all',
                          child: Text(
                            'Todos los Grupos (${availableTemplates.length} modelos)',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ],
                      onChanged: (val) {
                        if (val == null) return;
                        setModal(() {
                          selectedGroup = val;
                          selectedCategory = 'all';
                          final nextList = templatesForSelection(
                            selectedGroup,
                            selectedCategory,
                          );
                          selectedTemplate =
                              nextList.isNotEmpty ? nextList.first : null;
                        });
                      },
                    ),

                    // PASO 2: DESPLEGABLE DE SUBCATEGORÍA (SI EL GRUPO TIENE VARIAS CATEGORÍAS)
                    if (groupCategories.length > 1) ...[
                      const SizedBox(height: 14),
                      const Text(
                        '2. SUBGRUPO / TIPO DE DISPOSITIVO:',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: AppPalette.blue900,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 6),
                      DropdownButtonFormField<String>(
                        key: ValueKey('cat_${selectedGroup}_$selectedCategory'),
                        initialValue: selectedCategory,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.category_outlined, size: 18),
                          isDense: true,
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                        ),
                        items: [
                          DropdownMenuItem<String>(
                            value: 'all',
                            child: Text(
                              'Todos los tipos de "$selectedGroup" (${templatesForSelection(selectedGroup, 'all').length})',
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          for (final c in groupCategories)
                            DropdownMenuItem<String>(
                              value: c,
                              child: Text(
                                '${_quickCategoryLabels[c] ?? c.toUpperCase()} (${templatesForSelection(selectedGroup, c).length})',
                                style: const TextStyle(fontSize: 12.5),
                              ),
                            ),
                        ],
                        onChanged: (val) {
                          if (val == null) return;
                          setModal(() {
                            selectedCategory = val;
                            final nextList = templatesForSelection(
                              selectedGroup,
                              selectedCategory,
                            );
                            selectedTemplate =
                                nextList.isNotEmpty ? nextList.first : null;
                          });
                        },
                      ),
                    ],

                    // PASO 3: DESPLEGABLE DE DISPOSITIVO CONCRETO
                    const SizedBox(height: 14),
                    Text(
                      groupCategories.length > 1
                          ? '3. MODELO / PLANTILLA FÍSICA A INSTALAR (${filteredList.length} disponibles):'
                          : '2. MODELO / PLANTILLA FÍSICA A INSTALAR (${filteredList.length} disponibles):',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: AppPalette.slate900,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (filteredList.isNotEmpty && selectedTemplate != null)
                      DropdownButtonFormField<int>(
                        key: ValueKey(
                          'tpl_${selectedGroup}_${selectedCategory}_${selectedTemplate!.id}',
                        ),
                        initialValue: selectedTemplate!.id,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.dns_outlined, size: 18),
                          isDense: true,
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                        ),
                        items: filteredList.map((item) {
                          final itemFits = item.isTrayMiniDevice
                              ? _canFitAtU(rack, targetU, 1)
                              : _canFitAtU(rack, targetU, item.uHeight);
                          return DropdownMenuItem<int>(
                            value: item.id,
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${item.manufacturer} — ${item.modelName}',
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: itemFits
                                        ? AppPalette.green100
                                        : const Color(0xFFFEE2E2),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    item.isTrayMiniDevice
                                        ? 'Bandeja 1U'
                                        : '${item.uHeight}U',
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w800,
                                      color: itemFits
                                          ? const Color(0xFF166534)
                                          : AppPalette.red800,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                        onChanged: (tplId) {
                          if (tplId == null) return;
                          final found = filteredList.firstWhere(
                            (t) => t.id == tplId,
                            orElse: () => filteredList.first,
                          );
                          setModal(() => selectedTemplate = found);
                        },
                      ),

                    // FICHA RESUMEN DEL DISPOSITIVO SELECCIONADO
                    if (tpl != null && counts != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: fits
                              ? AppPalette.slate50
                              : AppPalette.red50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: fits
                                ? AppPalette.slate300
                                : AppPalette.red300,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  fits
                                      ? Icons.check_circle_outline
                                      : Icons.warning_amber_rounded,
                                  size: 16,
                                  color: fits
                                      ? AppPalette.green600
                                      : AppPalette.red600,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    '${tpl.manufacturer} ${tpl.modelName}',
                                    style: const TextStyle(
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w800,
                                      color: AppPalette.slate900,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              tpl.isTrayMiniDevice
                                  ? '• Se instalará sobre una Bandeja 19" en U$targetU'
                                  : '• Posición en Rack: U$targetU${tpl.uHeight > 1 ? ' a U${targetU + tpl.uHeight - 1}' : ''} (${tpl.uHeight}U • ${tpl.isFullDepth ? 'Profundidad Completa Front+Back' : 'Cara ${face.toUpperCase()}'})',
                              style: const TextStyle(
                                fontSize: 11.2,
                                color: AppPalette.slate700,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '• Bocas por defecto — Front: ${counts['front_rj45']} RJ45, ${counts['front_sfp']} SFP, ${counts['front_psu']} PSU, ${counts['front_schuko']} Schuko | Back: ${counts['back_rj45']} RJ45, ${counts['back_sfp']} SFP, ${counts['back_psu']} PSU, ${counts['back_schuko']} Schuko (personalizables en el siguiente paso)',
                              style: const TextStyle(
                                fontSize: 10.8,
                                color: AppPalette.slate600,
                              ),
                            ),
                            if (!fits) ...[
                              const SizedBox(height: 6),
                              Text(
                                '⚠ Atención: Este modelo ocupa ${tpl.uHeight}U y no hay ${tpl.uHeight}U libres consecutivas a partir de U$targetU (puedes ajustar su altura U en el siguiente paso o elegir otra U).',
                                style: const TextStyle(
                                  fontSize: 10.8,
                                  fontWeight: FontWeight.w700,
                                  color: AppPalette.red600,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actionsAlignment: MainAxisAlignment.spaceBetween,
            actions: [
              TextButton.icon(
                onPressed: () async {
                  Navigator.pop(ctx, null);
                  await _showCreateCustomTemplateDialog();
                },
                icon: const Icon(Icons.add_box_outlined, size: 16),
                label: const Text(
                  '+ Crear Nuevo Modelo',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, null),
                    child: const Text('Cancelar'),
                  ),
                  const SizedBox(width: 6),
                  FilledButton.icon(
                    onPressed: selectedTemplate == null
                        ? null
                        : () => Navigator.pop(ctx, (
                              template: selectedTemplate!,
                              cmdbAsset: selectedCmdbAsset,
                              targetU: targetU,
                              face: face,
                            )),
                    icon: const Icon(Icons.arrow_forward, size: 16),
                    label: Text(
                      selectedCmdbAsset != null
                          ? 'Continuar con Activo CMDB en U$targetU'
                          : 'Seleccionar para U$targetU',
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );

    if (chosenResult != null && mounted) {
      await _handleDropOrMountTemplate(
        chosenResult.template,
        chosenResult.targetU,
        targetFace: chosenResult.face,
        initialCmdbAsset: chosenResult.cmdbAsset,
      );
    }
  }

  Future<void> _handleDropOrMountTemplate(
    DeviceTemplateModel tpl,
    int targetStartU, {
    String? targetFace,
    Map<String, dynamic>? initialCmdbAsset,
  }) async {
    if (!_canEdit) return;
    final rack = _rack;
    if (rack == null) return;

    // Si es un equipo de "Bandeja - Equipos Mini" (Router sobremesa, Mini-Switch, ONT, Mini-PC)
    // y se suelta en una U donde ya hay una Bandeja, abrimos el gestor de esa bandeja (con soporte CMDB).
    // Si se suelta en una U libre, creamos la Bandeja 1U y abrimos el gestor de bandeja para configurar/vincular CMDB.
    if (tpl.isTrayMiniDevice) {
      for (final d in rack.devices) {
        if (d.isRackTray && targetStartU >= d.startU && targetStartU <= d.endU) {
          await _showManageTrayItemsDialog(
            d,
            initialAddTemplate: tpl,
            initialCmdbAsset: initialCmdbAsset,
          );
          return;
        }
      }
      final trayTemplate = widget.templates.firstWhere(
        (t) => t.isRackTray,
        orElse: () => tpl,
      );
      if (!_canFitAtU(rack, targetStartU, 1)) {
        ScaffoldMessenger.of(context).avisoError('Para colocar "${tpl.modelName}" en U$targetStartU hace falta una Bandeja en esa U o que U$targetStartU esté libre.');
        return;
      }
      try {
        final trayCount = rack.devices.where((d) => d.isRackTray).length + 1;
        final createdTray = await widget.api.addDeviceToRack(rack.id, {
          'template_id': trayTemplate.id,
          'code': 'BDJ$trayCount',
          'name': 'Bandeja 19" (${tpl.modelName})',
          'hostname': 'bdj$trayCount',
          'fqdn': '',
          'start_u': targetStartU,
          'mounted_face': 'front',
          'ip_address': '10.28.1.${60 + targetStartU}',
          'subnet_mask': '255.255.255.0',
          'gateway': '10.28.1.1',
          'monitoring_enabled': true,
          'custom_fields': {
            'tray_items': <Map<String, dynamic>>[],
          },
        });
        await _loadRack();
        final freshTray = _rack?.devices.firstWhere(
              (d) => d.id == createdTray.id,
              orElse: () => createdTray,
            ) ??
            createdTray;
        _rebuildState(() {
          _selectedDeviceId = freshTray.id;
          _selectedTemplateForClick = null;
        });
        if (mounted) {
          await _showManageTrayItemsDialog(
            freshTray,
            initialAddTemplate: tpl,
            initialCmdbAsset: initialCmdbAsset,
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).avisoError('$e');
        }
      }
      return;
    }

    // Verificar antes de abrir el formulario que existan suficientes unidades U libres consecutivas
    final targetEndU = targetStartU + tpl.uHeight - 1;
    if (!_canFitAtU(rack, targetStartU, tpl.uHeight)) {
      final blocker = _findBlockingDevice(rack, targetStartU, tpl.uHeight);
      final reason = targetEndU > rack.totalUnits
          ? 'supera la altura máxima del rack (U${rack.totalUnits})'
          : (blocker != null
              ? 'choca con "${blocker.code}" en U${blocker.startU}'
              : 'las unidades U no están libres');
      ScaffoldMessenger.of(context).avisoError('No se puede montar "${tpl.modelName}" (${tpl.uHeight}U) en U$targetStartU${tpl.uHeight > 1 ? '-U$targetEndU' : ''}: necesita ${tpl.uHeight}U libres consecutivas ($reason).');
      return;
    }

    List<Map<String, dynamic>> cmdbAssets = [];
    try {
      final overview = await widget.api.fetchCmdbOverview();
      cmdbAssets = ((overview['assets'] as List?) ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      cmdbAssets.sort((a, b) {
        final aUnplaced =
            (a['rack_device_id'] == null && a['rack_id'] == null) ? 0 : 1;
        final bUnplaced =
            (b['rack_device_id'] == null && b['rack_id'] == null) ? 0 : 1;
        if (aUnplaced != bUnplaced) return aUnplaced.compareTo(bUnplaced);
        return (a['code'] ?? '')
            .toString()
            .compareTo((b['code'] ?? '').toString());
      });
    } catch (_) {}
    if (!mounted) return;

    final prefix = tpl.category
        .substring(0, tpl.category.length.clamp(1, 3))
        .toUpperCase();
    final suggestedCode = '$prefix${rack.devices.length + 1}';
    final codeCtrl = TextEditingController(text: suggestedCode);
    final nameCtrl =
        TextEditingController(text: '${tpl.manufacturer} ${tpl.modelName}');
    final hostnameCtrl =
        TextEditingController(text: suggestedCode.toLowerCase());
    final fqdnCtrl = TextEditingController(
      text:
          '${suggestedCode.toLowerCase()}.${(rack.breadcrumb['location_code'] ?? 'hq').toString().toLowerCase()}.rackdoc.local',
    );
    final ipCtrl =
        TextEditingController(text: '10.28.1.${20 + rack.devices.length}');
    final maskCtrl = TextEditingController(text: '255.255.255.0');
    final gwCtrl = TextEditingController(text: '10.28.1.1');
    final modelCtrl = TextEditingController(
      text: '${tpl.manufacturer} ${tpl.modelName}'.trim(),
    );
    final serialCtrl = TextEditingController();

    final initialCounts = _extractPortCountsFromSpec(
      tpl.layoutSpec,
      category: tpl.category,
    );
    final fRjCtrl = TextEditingController(text: '${initialCounts['front_rj45']}');
    final fSfpCtrl = TextEditingController(text: '${initialCounts['front_sfp']}');
    final fPsuCtrl = TextEditingController(text: '${initialCounts['front_psu']}');
    final fSchCtrl = TextEditingController(
      text: '${initialCounts['front_schuko']}',
    );
    final bRjCtrl = TextEditingController(text: '${initialCounts['back_rj45']}');
    final bSfpCtrl = TextEditingController(text: '${initialCounts['back_sfp']}');
    final bPsuCtrl = TextEditingController(text: '${initialCounts['back_psu']}');
    final bSchCtrl = TextEditingController(
      text: '${initialCounts['back_schuko']}',
    );

    int chosenUHeight = tpl.uHeight;
    bool certscopeEnabled = false;
    final certscopePortCtrl = TextEditingController(text: '443');
    int? selectedCmdbAssetId;
    Map<String, dynamic>? selectedCmdbAsset;

    void applyCmdbAssetToControllers(Map<String, dynamic> picked) {
      selectedCmdbAsset = picked;
      selectedCmdbAssetId = (picked['id'] as num?)?.toInt();
      final rawCode = (picked['code'] ?? '').toString().trim();
      if (rawCode.isNotEmpty &&
          !rawCode.startsWith('DISC-') &&
          !rawCode.startsWith('FLR-')) {
        codeCtrl.text = rawCode;
      }
      final rawName = (picked['name'] ?? '').toString().trim();
      if (rawName.isNotEmpty && !rawName.startsWith('Equipo Detectado')) {
        nameCtrl.text = rawName;
      }
      final rawHost = (picked['hostname'] ?? '').toString().trim();
      if (rawHost.isNotEmpty) {
        hostnameCtrl.text = rawHost;
      }
      final resFqdn =
          (picked['_resolved_fqdn'] ?? picked['fqdn'] ?? '').toString().trim();
      if (resFqdn.isNotEmpty) {
        fqdnCtrl.text = resFqdn;
      }
      final resIp = (picked['_resolved_ip'] ??
              picked['heartbeat_ip'] ??
              picked['ip_address'] ??
              '')
          .toString()
          .trim();
      if (resIp.isNotEmpty) {
        ipCtrl.text = resIp;
      }
      final resMask = (picked['_resolved_subnet_mask'] ?? '').toString().trim();
      if (resMask.isNotEmpty) {
        maskCtrl.text = resMask;
      }
      final resGw = (picked['_resolved_gateway'] ?? '').toString().trim();
      if (resGw.isNotEmpty) {
        gwCtrl.text = resGw;
      }
      final resModel = (picked['model_name'] ?? '').toString().trim();
      if (resModel.isNotEmpty) {
        modelCtrl.text = resModel;
      }
      final resSerial = (picked['serial_or_uuid'] ?? '').toString().trim();
      if (resSerial.isNotEmpty) {
        serialCtrl.text = resSerial;
      }
    }

    if (initialCmdbAsset != null) {
      applyCmdbAssetToControllers(initialCmdbAsset);
      if (selectedCmdbAssetId != null &&
          !cmdbAssets.any((a) => a['id'] == selectedCmdbAssetId)) {
        cmdbAssets = [initialCmdbAsset, ...cmdbAssets];
      }
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: Text(
            'Montar ${tpl.modelName} en U$targetStartU (Configura Front y Back)',
          ),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 0. VINCULAR CON ACTIVO DE LA CMDB (DESPLEGABLE DIRECTO + EXPLORADOR POR RED / MÁSCARA)
                  Container(
                    padding: const EdgeInsets.all(10),
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      color: selectedCmdbAsset != null
                          ? const Color(0xFFF0FDF4)
                          : const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: selectedCmdbAsset != null
                            ? const Color(0xFF22C55E)
                            : AppPalette.blue300,
                        width: 1.3,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.account_tree_rounded,
                              size: 16,
                              color: selectedCmdbAsset != null
                                  ? const Color(0xFF15803D)
                                  : AppPalette.blue900,
                            ),
                            const SizedBox(width: 6),
                            const Expanded(
                              child: Text(
                                '0. ¿Es un equipo ya detectado / registrado en la CMDB?',
                                style: TextStyle(
                                  fontSize: 11.8,
                                  fontWeight: FontWeight.w900,
                                  color: AppPalette.slate900,
                                ),
                              ),
                            ),
                            if (selectedCmdbAsset != null)
                              TextButton.icon(
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  foregroundColor: AppPalette.red600,
                                ),
                                onPressed: () {
                                  setModal(() {
                                    selectedCmdbAssetId = null;
                                    selectedCmdbAsset = null;
                                  });
                                },
                                icon: const Icon(Icons.link_off, size: 14),
                                label: const Text(
                                  'Desvincular',
                                  style: TextStyle(fontSize: 11),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        if (cmdbAssets.isNotEmpty) ...[
                          DropdownButtonFormField<int?>(
                            key: ValueKey('mount_cmdb_$selectedCmdbAssetId'),
                            initialValue: cmdbAssets
                                    .any((a) => a['id'] == selectedCmdbAssetId)
                                ? selectedCmdbAssetId
                                : null,
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText:
                                  'Seleccionar directamente activo de 6. CMDB (Autocompleta Nombre, IP, Hostname y Serie)',
                              prefixIcon: Icon(
                                Icons.inventory_2_outlined,
                                size: 17,
                                color: AppPalette.blue700,
                              ),
                              isDense: true,
                              filled: true,
                              fillColor: Colors.white,
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 9,
                              ),
                            ),
                            items: [
                              const DropdownMenuItem<int?>(
                                value: null,
                                child: Text(
                                  '— Crear nuevo equipo desde cero (sin vincular a activo previo) —',
                                  style: TextStyle(
                                    fontSize: 11.8,
                                    color: AppPalette.slate500,
                                  ),
                                ),
                              ),
                              ...cmdbAssets.map((a) {
                                final id = (a['id'] as num?)?.toInt();
                                final code = (a['code'] ?? '').toString();
                                final name = (a['name'] ?? '').toString();
                                final ip = (a['_resolved_ip'] ??
                                        a['heartbeat_ip'] ??
                                        a['ip_address'] ??
                                        '')
                                    .toString();
                                return DropdownMenuItem<int?>(
                                  value: id,
                                  child: Text(
                                    '[$code] $name ${ip.isNotEmpty ? "• IP: $ip" : ""}',
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                );
                              }),
                            ],
                            onChanged: (val) {
                              setModal(() {
                                if (val == null) {
                                  selectedCmdbAssetId = null;
                                  selectedCmdbAsset = null;
                                } else {
                                  final picked = cmdbAssets.firstWhere(
                                    (a) => a['id'] == val,
                                  );
                                  applyCmdbAssetToControllers(picked);
                                }
                              });
                            },
                          ),
                          const SizedBox(height: 6),
                        ],
                        if (selectedCmdbAsset != null)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 6,
                            ),
                            margin: const EdgeInsets.only(bottom: 6),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: const Color(0xFF86EFAC),
                              ),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.check_circle,
                                  size: 15,
                                  color: Color(0xFF16A34A),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    'Vinculado: [${selectedCmdbAsset!['code']}] ${selectedCmdbAsset!['name']} '
                                    '• IP: ${selectedCmdbAsset!['_resolved_ip'] ?? selectedCmdbAsset!['heartbeat_ip'] ?? "Sin IP"}',
                                    style: const TextStyle(
                                      fontSize: 11.2,
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFF14532D),
                                    ),
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
                              side: const BorderSide(color: AppPalette.blue600),
                            ),
                            onPressed: () async {
                              final picked = await CmdbAssetExplorerDialog.show(
                                ctx,
                                api: widget.api,
                                contextMode: 'rack',
                                preselectedAssetId: selectedCmdbAssetId,
                                title:
                                    'Seleccionar Equipo de la CMDB para Montar en U$targetStartU',
                                subtitle:
                                    'Navega por las Redes / Subredes (Máscara CIDR) en la columna izquierda y elige el activo para autocompletar todos sus datos.',
                              );
                              if (picked != null) {
                                setModal(() {
                                  applyCmdbAssetToControllers(picked);
                                  if (selectedCmdbAssetId != null &&
                                      !cmdbAssets.any(
                                        (a) => a['id'] == selectedCmdbAssetId,
                                      )) {
                                    cmdbAssets = [picked, ...cmdbAssets];
                                  }
                                });
                              }
                            },
                            icon: const Icon(
                              Icons.manage_search_rounded,
                              size: 17,
                              color: AppPalette.blue700,
                            ),
                            label: Text(
                              selectedCmdbAsset != null
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
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(8),
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      color: AppPalette.blue50,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: AppPalette.blue300),
                    ),
                    child: const Row(
                      children: [
                        Icon(
                          Icons.sync_alt,
                          size: 16,
                          color: AppPalette.blue700,
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Puedes personalizar cuántas bocas RJ45, SFP Fibra, Tomas PSU y Schuko lleva este equipo tanto por DELANTE (Front) como por DETRÁS (Back).',
                            style: TextStyle(
                              fontSize: 11,
                              color: AppPalette.blue900,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: codeCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Código en Rack (ej. SW04, SRV02)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: TextField(
                          controller: hostnameCtrl,
                          decoration:
                              const InputDecoration(labelText: 'Hostname'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 1,
                        child: DropdownButtonFormField<int>(
                          initialValue: chosenUHeight.clamp(1, 16),
                          decoration: const InputDecoration(
                            labelText: 'Altura (U)',
                          ),
                          items: List.generate(16, (idx) => idx + 1)
                              .map(
                                (uVal) => DropdownMenuItem<int>(
                                  value: uVal,
                                  child: Text('${uVal}U'),
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            if (v != null) {
                              setModal(() => chosenUHeight = v);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: nameCtrl,
                    decoration:
                        const InputDecoration(labelText: 'Nombre Descriptivo'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: fqdnCtrl,
                    decoration: const InputDecoration(labelText: 'FQDN'),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: modelCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Marca / Modelo del Equipo',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: serialCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Número de Serie (S/N) / Service Tag',
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
                          controller: ipCtrl,
                          decoration:
                              const InputDecoration(labelText: 'Dirección IP'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: maskCtrl,
                          decoration:
                              const InputDecoration(labelText: 'Máscara'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: gwCtrl,
                          decoration:
                              const InputDecoration(labelText: 'Gateway'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
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
                            width: 95,
                            child: TextField(
                              controller: certscopePortCtrl,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Puerto TLS',
                                isDense: true,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (!tpl.isRackTray && !tpl.isRoofFan) ...[
                    const Divider(height: 22),
                    const Text(
                      '1. BOCAS EN CARA DELANTERA (FRONT):',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: AppPalette.slate900,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: fRjCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'RJ45 (Front)',
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: fSfpCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'SFP Fibra (Front)',
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: fPsuCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Tomas PSU (Front)',
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: fSchCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Schuko (Front)',
                              isDense: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '2. BOCAS EN CARA TRASERA (BACK):',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: AppPalette.blue900,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: bRjCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'RJ45 (Back)',
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: bSfpCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'SFP Fibra (Back)',
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: bPsuCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Tomas PSU (Back)',
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: bSchCtrl,
                            keyboardType: TextInputType.number,
                            decoration: const InputDecoration(
                              labelText: 'Schuko (Back)',
                              isDense: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Montar en el Rack'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return;

    final targetIp = ipCtrl.text.trim();
    String? collisionAction;
    int? collisionTargetAssetId;
    if (targetIp.isNotEmpty) {
      try {
        final check = await widget.api.checkCmdbIpOwner(ip: targetIp);
        if (check['has_collision'] == true) {
          final owners = ((check['owners'] as List?) ?? [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .where((o) =>
                  selectedCmdbAssetId == null ||
                  (o['id'] as num?)?.toInt() != selectedCmdbAssetId)
              .toList();
          if (owners.isNotEmpty && mounted) {
            final owner = owners.first;
            final ownerCode = '${owner['asset_code'] ?? ''}';
            final ownerName = '${owner['name'] ?? ''}';
            final ownerHost = '${owner['hostname'] ?? ''}';
            String selAct = 'merge';
            final chosen = await showDialog<String>(
              context: context,
              builder: (ctx) => StatefulBuilder(
                builder: (ctx, setModal) => AlertDialog(
                  title: Row(
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        color: AppPalette.red600,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Colisión de IP detectada en CMDB ($targetIp)',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                  content: SizedBox(
                    width: 540,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppPalette.red50,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppPalette.red300),
                          ),
                          child: Text(
                            'La IP $targetIp ya figura en la CMDB asociada al activo:\n'
                            '• [$ownerCode] $ownerName${ownerHost.isNotEmpty ? ' ($ownerHost)' : ''}\n\n'
                            '¿Cómo deseas alinear el equipo montado en el Rack con la CMDB?',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF7F1D1D),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            selAct == 'merge'
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off,
                            color: AppPalette.blue600,
                          ),
                          title: const Text(
                            'Es el mismo equipo: Unificar con el activo existente en CMDB (Recomendado)',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          subtitle: Text(
                            'Fusiona [$ownerCode] con este equipo recién montado en U$targetStartU, conservando su estado ONLINE/ping e IPs sin duplicar registros.',
                            style: const TextStyle(fontSize: 11),
                          ),
                          onTap: () => setModal(() => selAct = 'merge'),
                        ),
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            selAct == 'reassign_or_clear'
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off,
                            color: AppPalette.blue600,
                          ),
                          title: const Text(
                            'Son equipos distintos: Reasignar la IP a este equipo del Rack y liberarla del otro',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          subtitle: Text(
                            'Libera $targetIp de [$ownerCode] y la asigna exclusivamente a este equipo del Rack.',
                            style: const TextStyle(fontSize: 11),
                          ),
                          onTap: () => setModal(
                            () => selAct = 'reassign_or_clear',
                          ),
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, null),
                      child: const Text('Cancelar montaje'),
                    ),
                    FilledButton.icon(
                      onPressed: () => Navigator.pop(ctx, selAct),
                      icon: const Icon(Icons.merge_type_rounded, size: 16),
                      label: const Text('Confirmar y Montar en Rack'),
                    ),
                  ],
                ),
              ),
            );
            if (chosen == null) return;
            collisionAction = chosen;
            collisionTargetAssetId = owner['id'] as int?;
          }
        }
      } catch (_) {}
    }

    final newCounts = {
      'front_rj45': int.tryParse(fRjCtrl.text.trim()) ?? 0,
      'front_sfp': int.tryParse(fSfpCtrl.text.trim()) ?? 0,
      'front_psu': int.tryParse(fPsuCtrl.text.trim()) ?? 0,
      'front_schuko': int.tryParse(fSchCtrl.text.trim()) ?? 0,
      'back_rj45': int.tryParse(bRjCtrl.text.trim()) ?? 0,
      'back_sfp': int.tryParse(bSfpCtrl.text.trim()) ?? 0,
      'back_psu': int.tryParse(bPsuCtrl.text.trim()) ?? 0,
      'back_schuko': int.tryParse(bSchCtrl.text.trim()) ?? 0,
    };
    final bool portsCustomized = !tpl.isRackTray &&
        !tpl.isRoofFan &&
        newCounts.entries.any((e) => initialCounts[e.key] != e.value);

    try {
      final created = await widget.api.addDeviceToRack(rack.id, {
        'template_id': tpl.id,
        'code': codeCtrl.text.trim(),
        'name': nameCtrl.text.trim(),
        'hostname': hostnameCtrl.text.trim(),
        'fqdn': fqdnCtrl.text.trim(),
        'start_u': targetStartU,
        'mounted_face':
            targetFace ?? (_activeFace == 'back' ? 'back' : 'front'),
        'ip_address': targetIp,
        'subnet_mask': maskCtrl.text.trim(),
        'gateway': gwCtrl.text.trim(),
        'monitoring_enabled': targetIp.isNotEmpty,
        'serial_number': serialCtrl.text.trim(),
        'certscope_enabled': certscopeEnabled,
        'certscope_port': int.tryParse(certscopePortCtrl.text.trim()) ?? 443,
        'custom_fields': {
          'linked_cmdb_asset_id': ?selectedCmdbAssetId,
          if (modelCtrl.text.trim().isNotEmpty)
            'model_name': modelCtrl.text.trim(),
          if (chosenUHeight != tpl.uHeight) 'u_height_override': chosenUHeight,
          if (collisionAction != null && collisionTargetAssetId != null) ...{
            'on_ip_collision_action': collisionAction,
            'collision_target_asset_id': collisionTargetAssetId,
          },
          if (portsCustomized)
            'custom_layout_spec': {
              'front': _buildFacePortGroups(
                rj45Count: newCounts['front_rj45']!,
                sfpCount: newCounts['front_sfp']!,
                psuCount: newCounts['front_psu']!,
                schukoCount: newCounts['front_schuko']!,
                isBackFace: false,
              ),
              'back': _buildFacePortGroups(
                rj45Count: newCounts['back_rj45']!,
                sfpCount: newCounts['back_sfp']!,
                psuCount: newCounts['back_psu']!,
                schukoCount: newCounts['back_schuko']!,
                isBackFace: true,
              ),
            },
        },
      });
      await _loadRack();
      _rebuildState(() {
        _selectedDeviceId = created.id;
        _selectedConnectionId = null;
        _selectedTemplateForClick = null;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).avisoError('$e');
      }
    }
  }

  Future<void> _handlePortTap(RackDeviceModel dev, PortModel port) async {
    final rack = _rack;
    if (rack == null) return;

    ConnectionModel? existingConn;
    for (final c in rack.connections) {
      if (c.sourcePortId == port.id || c.targetPortId == port.id) {
        existingConn = c;
        break;
      }
    }

    if (_pendingSourcePort == null && existingConn != null) {
      _rebuildState(() {
        _selectedConnectionId = existingConn!.id;
        _selectedDeviceId = null;
      });
      return;
    }

    if (!_canEdit) {
      ScaffoldMessenger.of(context).aviso('Modo lectura: tu rol actual no permite crear nuevos cables.');
      return;
    }

    if (existingConn != null) {
      ScaffoldMessenger.of(context).aviso('La boca ${dev.code}:${port.portNumber} ya está ocupada por un cable. Selecciónala sin cable activo para editarla o desconectarla.');
      return;
    }

    if (_pendingSourcePort == null) {
      _rebuildState(() {
        _pendingSourcePort = port;
        _pendingSourceDevice = dev;
      });
      return;
    }

    if (_pendingSourcePort!.id == port.id) {
      _rebuildState(() {
        _pendingSourcePort = null;
        _pendingSourceDevice = null;
      });
      return;
    }

    final srcPort = _pendingSourcePort!;
    final srcDev = _pendingSourceDevice!;

    String defaultCableType = 'utp_cat6a';
    String defaultColor = '#2563EB';
    String? forcedExternalFeedName;
    bool isExtFiber = false;
    bool isFloorDeviceConn =
        srcDev.isFloorDevicesFeed || dev.isFloorDevicesFeed;

    if (isFloorDeviceConn) {
      defaultCableType = 'utp_cat6a';
      defaultColor = '#0D9488';
    } else if (srcDev.isExternalFeed) {
      isExtFiber = srcDev.isFiberFeed;
      defaultCableType = isExtFiber ? 'fiber_om4' : 'power_ac';
      defaultColor = srcDev.feedColorHex;
      forcedExternalFeedName = '${srcDev.code} (${srcDev.name})';
    } else if (dev.isExternalFeed) {
      isExtFiber = dev.isFiberFeed;
      defaultCableType = isExtFiber ? 'fiber_om4' : 'power_ac';
      defaultColor = dev.feedColorHex;
      forcedExternalFeedName = '${dev.code} (${dev.name})';
    } else if (srcPort.portType.contains('fiber') ||
        srcPort.portType.contains('sfp') ||
        port.portType.contains('fiber') ||
        port.portType.contains('sfp')) {
      defaultCableType = 'fiber_om4';
      defaultColor = '#F59E0B';
    } else if (srcPort.portType.contains('power') ||
        port.portType.contains('power')) {
      defaultCableType = 'power_ac';
      defaultColor = '#DC2626';
    }

    String floorDefaultLabel =
        '${srcDev.code}:${srcPort.portNumber} ➔ ${dev.code}:${port.portNumber}';
    if (isFloorDeviceConn) {
      final fPort = srcDev.isFloorDevicesFeed ? srcPort : port;
      final rDev = srcDev.isFloorDevicesFeed ? dev : srcDev;
      final rPort = srcDev.isFloorDevicesFeed ? port : srcPort;
      final parts = fPort.label.split('|');
      final fName = parts.length >= 3 ? parts[2] : fPort.portNumber;
      floorDefaultLabel =
          'Planta ${fPort.portNumber} ($fName) ➔ ${rDev.code}:${rPort.portNumber}';
    }

    String cableType = defaultCableType;
    String colorHex = defaultColor;
    String channel = (srcDev.isExternalFeed || dev.isExternalFeed)
        ? 'right'
        : 'auto';
    final labelCtrl = TextEditingController(
      text: isFloorDeviceConn
          ? floorDefaultLabel
          : (forcedExternalFeedName != null
              ? '${isExtFiber ? 'Fibra Exterior' : 'Alimentación'} $forcedExternalFeedName ➔ ${srcDev.isExternalFeed ? dev.code : srcDev.code}'
              : '${srcDev.code}:${srcPort.portNumber} ➔ ${dev.code}:${port.portNumber}'),
    );
    final vlanCtrl = TextEditingController(
      text: defaultCableType.startsWith('power') ? '' : '10',
    );
    final lengthCtrl = TextEditingController(text: '1.8');

    const powerColors = [
      '#DC2626',
      '#2563EB',
      '#EA580C',
      '#16A34A',
      '#7C3AED',
      '#CA8A04',
      '#0284C7',
      '#334155',
    ];

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: const Text('Nueva Conexión de Cable'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppPalette.slate100,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Origen: ${srcDev.code} (${srcPort.portNumber})',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const Icon(Icons.arrow_forward, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Destino: ${dev.code} (${port.portNumber})',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (forcedExternalFeedName != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: CableGeometryBuilder.parseHexColor(
                        colorHex,
                      ).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: CableGeometryBuilder.parseHexColor(colorHex),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isExtFiber
                              ? Icons.settings_input_hdmi_outlined
                              : Icons.electrical_services,
                          size: 16,
                          color: CableGeometryBuilder.parseHexColor(colorHex),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Conectado a toma exterior $forcedExternalFeedName: el cable adopta automáticamente el color identificativo de esa línea ($colorHex).',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: cableType,
                  decoration:
                      const InputDecoration(labelText: 'Tipo de Conexión'),
                  items: const [
                    DropdownMenuItem(
                      value: 'utp_cat6a',
                      child: Text('Red Cobre UTP Cat.6a'),
                    ),
                    DropdownMenuItem(
                      value: 'fiber_om4',
                      child: Text('Fibra Óptica Multimodo OM4'),
                    ),
                    DropdownMenuItem(
                      value: 'fiber_os2',
                      child: Text('Fibra Óptica Monomodo OS2'),
                    ),
                    DropdownMenuItem(
                      value: 'power_ac',
                      child: Text('Electricidad AC (Schuko / C13 / C14 / PDU)'),
                    ),
                  ],
                  onChanged: (v) {
                    setModal(() {
                      cableType = v ?? 'utp_cat6a';
                      if (forcedExternalFeedName == null) {
                        if (cableType.startsWith('fiber')) colorHex = '#F59E0B';
                        if (cableType.startsWith('power')) colorHex = '#DC2626';
                        if (cableType.startsWith('utp')) colorHex = '#2563EB';
                      }
                    });
                  },
                ),
                const SizedBox(height: 10),
                const Text(
                  'Color Identificativo del Cable',
                  style: TextStyle(fontSize: 11, color: AppPalette.slate500),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: powerColors.map((hex) {
                    final isSel = colorHex.toUpperCase() == hex.toUpperCase();
                    final col = CableGeometryBuilder.parseHexColor(hex);
                    return GestureDetector(
                      onTap: () => setModal(() => colorHex = hex),
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: col,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isSel ? Colors.black : Colors.white,
                            width: isSel ? 2.5 : 1.2,
                          ),
                        ),
                        child: isSel
                            ? const Icon(
                                Icons.check,
                                size: 14,
                                color: Colors.white,
                              )
                            : null,
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: channel,
                  decoration: const InputDecoration(
                    labelText: 'Canaleta del Rack',
                  ),
                  items: const [
                    DropdownMenuItem(value: 'auto', child: Text('Automática')),
                    DropdownMenuItem(
                      value: 'left',
                      child: Text('Canaleta Izquierda'),
                    ),
                    DropdownMenuItem(
                      value: 'right',
                      child: Text('Canaleta Derecha (Hacia Tomas Exteriores)'),
                    ),
                  ],
                  onChanged: (v) => setModal(() => channel = v ?? 'auto'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: labelCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Indicaciones / Etiqueta del Cable',
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: vlanCtrl,
                        decoration: const InputDecoration(labelText: 'VLAN'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: lengthCtrl,
                        decoration:
                            const InputDecoration(labelText: 'Longitud (m)'),
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
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Conectar Cable'),
            ),
          ],
        ),
      ),
    );

    _rebuildState(() {
      _pendingSourcePort = null;
      _pendingSourceDevice = null;
    });

    if (confirmed == true) {
      try {
        final created = await widget.api.createConnection({
          'source_port_id': srcPort.id,
          'target_port_id': port.id,
          'cable_type': cableType,
          'color_hex': colorHex,
          'routing_channel': channel,
          'label': labelCtrl.text.trim(),
          'vlan': int.tryParse(vlanCtrl.text.trim()),
          'length_m': double.tryParse(lengthCtrl.text.trim()) ?? 1.5,
        });
        await _loadRack();
        _rebuildState(() {
          _selectedConnectionId = created.id;
          _selectedDeviceId = null;
        });
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).avisoError('$e');
        }
      }
    }
  }

  // ===========================================================================
  // CONEXIÓN DE FIBRA / CABLE ENTRE DISTINTOS RACKS (INTER-RACK PATCHING)
  // ===========================================================================
  Future<void> _showInterRackConnectionDialog({
    RackDeviceModel? initialSourceDev,
    PortModel? initialSourcePort,
  }) async {
    if (!_canEdit) return;
    final rack = _rack;
    if (rack == null) return;
    final messenger = ScaffoldMessenger.of(context);

    List<Map<String, dynamic>> otherRacks = [];
    try {
      otherRacks = await widget.api.getInterRackTargets(rack.id);
    } catch (e) {
      messenger.avisoError('Error obteniendo otros racks: $e');
      return;
    }

    if (otherRacks.isEmpty) {
      if (!mounted) return;
      messenger.aviso('No hay otros Racks dados de alta en el Datacenter para conectar fibra/cable Inter-Rack.');
      return;
    }

    // Puertos ocupados en el rack actual
    final occupiedLocalPorts = <int>{};
    for (final c in rack.connections) {
      occupiedLocalPorts.add(c.sourcePortId);
      occupiedLocalPorts.add(c.targetPortId);
    }

    final localDevices =
        rack.devices.where((d) => !d.isExternalFeed && d.ports.isNotEmpty).toList();
    if (localDevices.isEmpty) {
      if (!mounted) return;
      messenger.aviso('Este rack no tiene equipos con puertos para conectar.');
      return;
    }

    RackDeviceModel selectedLocalDev = initialSourceDev != null &&
            !initialSourceDev.isExternalFeed
        ? initialSourceDev
        : localDevices.first;

    List<PortModel> freeLocalPortsFor(RackDeviceModel d) => d.ports
        .where((p) => !occupiedLocalPorts.contains(p.id) || p.id == initialSourcePort?.id)
        .toList();

    List<PortModel> localPorts = freeLocalPortsFor(selectedLocalDev);
    PortModel? selectedLocalPort = initialSourcePort ??
        (localPorts.isNotEmpty ? localPorts.first : null);

    Map<String, dynamic> selectedTargetRack = otherRacks.first;
    List<Map<String, dynamic>> targetDevicesFor(Map<String, dynamic> rk) =>
        ((rk['devices'] ?? []) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();

    List<Map<String, dynamic>> targetDevs = targetDevicesFor(selectedTargetRack);
    Map<String, dynamic>? selectedTargetDev =
        targetDevs.isNotEmpty ? targetDevs.first : null;

    List<Map<String, dynamic>> freeTargetPortsFor(Map<String, dynamic>? d) {
      if (d == null) return [];
      return ((d['ports'] ?? []) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((p) => p['occupied'] != true)
          .toList();
    }

    List<Map<String, dynamic>> targetPorts =
        freeTargetPortsFor(selectedTargetDev);
    Map<String, dynamic>? selectedTargetPort =
        targetPorts.isNotEmpty ? targetPorts.first : null;

    final isInitialFiber = (selectedLocalPort?.portType.contains('fiber') ?? false) ||
        (selectedLocalPort?.portType.contains('sfp') ?? false);
    String cableType = isInitialFiber ? 'fiber_om4' : 'fiber_os2';
    String colorHex = isInitialFiber ? '#0284C7' : '#F59E0B';
    final labelCtrl = TextEditingController(
      text:
          'Troncal Fibra ${rack.code} ➔ ${selectedTargetRack['code']}',
    );
    final vlanCtrl = TextEditingController(text: '');
    final lengthCtrl = TextEditingController(text: '12.0');

    const fiberPalette = [
      '#0284C7', // Aqua OM4
      '#F59E0B', // Amarillo OS2 Monomodo
      '#7C3AED', // Violeta OM4/OM5
      '#10B981', // Verde Trunk
      '#2563EB', // Azul Red
      '#DC2626', // Rojo
      '#EA580C', // Naranja OM2
      '#334155', // Negro DAC
    ];

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.cable, color: AppPalette.sky600, size: 22),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Conectar Fibra / Cable hacia Otro Rack (Inter-Rack)',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 540,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppPalette.sky50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppPalette.sky200),
                    ),
                    child: const Text(
                      '💡 Las fibras o cables entre Racks se trazan hacia la Bandeja Aérea Inter-Rack superior con una etiqueta interactiva (⇢ RACK destino) que te permite saltar al otro Rack con 1 clic.',
                      style: TextStyle(fontSize: 11.5, color: AppPalette.sky700),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 1. ORIGEN EN ESTE RACK
                  Text(
                    '1. ORIGEN EN ESTE RACK (${rack.code} — ${rack.name})',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: AppPalette.blue900,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: DropdownButtonFormField<RackDeviceModel>(
                          initialValue: selectedLocalDev,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Equipo Origen (Este Rack)',
                            isDense: true,
                          ),
                          items: localDevices
                              .map(
                                (d) => DropdownMenuItem(
                                  value: d,
                                  child: Text(
                                    'U${d.startU} • ${d.code} (${d.name})',
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (val) {
                            if (val == null) return;
                            setModal(() {
                              selectedLocalDev = val;
                              localPorts = freeLocalPortsFor(val);
                              selectedLocalPort =
                                  localPorts.isNotEmpty ? localPorts.first : null;
                            });
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: DropdownButtonFormField<PortModel>(
                          initialValue: selectedLocalPort,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Boca / Conector Libre',
                            isDense: true,
                          ),
                          items: localPorts
                              .map(
                                (p) => DropdownMenuItem(
                                  value: p,
                                  child: Text(
                                    '${p.portNumber} (${p.face.toUpperCase()} • ${p.portType})',
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (val) =>
                              setModal(() => selectedLocalPort = val),
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 24),
                  // 2. DESTINO EN OTRO RACK
                  const Text(
                    '2. DESTINO EN OTRO RACK DEL CPD',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF047857),
                    ),
                  ),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<Map<String, dynamic>>(
                    initialValue: selectedTargetRack,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Rack Destino',
                      isDense: true,
                    ),
                    items: otherRacks
                        .map(
                          (rk) => DropdownMenuItem(
                            value: rk,
                            child: Text(
                              '${rk['code']} — ${rk['name']} (${rk['floor_name']} • ${rk['room_name']})',
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (rk) {
                      if (rk == null) return;
                      setModal(() {
                        selectedTargetRack = rk;
                        targetDevs = targetDevicesFor(rk);
                        selectedTargetDev =
                            targetDevs.isNotEmpty ? targetDevs.first : null;
                        targetPorts = freeTargetPortsFor(selectedTargetDev);
                        selectedTargetPort =
                            targetPorts.isNotEmpty ? targetPorts.first : null;
                        labelCtrl.text =
                            'Troncal Fibra ${rack.code} ➔ ${rk['code']}';
                      });
                    },
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: DropdownButtonFormField<Map<String, dynamic>>(
                          initialValue: selectedTargetDev,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Equipo en Rack Destino',
                            isDense: true,
                          ),
                          items: targetDevs
                              .map(
                                (d) => DropdownMenuItem(
                                  value: d,
                                  child: Text(
                                    'U${d['start_u']} • ${d['code']} (${d['name']})',
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (d) {
                            setModal(() {
                              selectedTargetDev = d;
                              targetPorts = freeTargetPortsFor(d);
                              selectedTargetPort = targetPorts.isNotEmpty
                                  ? targetPorts.first
                                  : null;
                            });
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: DropdownButtonFormField<Map<String, dynamic>>(
                          initialValue: selectedTargetPort,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Puerto Destino Libre',
                            isDense: true,
                          ),
                          items: targetPorts
                              .map(
                                (p) => DropdownMenuItem(
                                  value: p,
                                  child: Text(
                                    '${p['port_number']} (${p['face'].toString().toUpperCase()} • ${p['port_type']})',
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (p) =>
                              setModal(() => selectedTargetPort = p),
                        ),
                      ),
                    ],
                  ),
                  const Divider(height: 22),
                  // 3. PROPIEDADES DE LA FIBRA / CABLE TRONCAL
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: DropdownButtonFormField<String>(
                          initialValue: cableType,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Tipo de Fibra / Cable',
                            isDense: true,
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'fiber_om4',
                              child: Text('Fibra Multimodo OM4 (Aqua)'),
                            ),
                            DropdownMenuItem(
                              value: 'fiber_os2',
                              child: Text('Fibra Monomodo OS2 (Amarilla)'),
                            ),
                            DropdownMenuItem(
                              value: 'utp_cat6a',
                              child: Text('Red Cobre UTP Cat.6a'),
                            ),
                            DropdownMenuItem(
                              value: 'power_ac',
                              child: Text('Línea Eléctrica AC'),
                            ),
                          ],
                          onChanged: (v) {
                            if (v == null) return;
                            setModal(() {
                              cableType = v;
                              if (v == 'fiber_om4') colorHex = '#0284C7';
                              if (v == 'fiber_os2') colorHex = '#F59E0B';
                              if (v == 'utp_cat6a') colorHex = '#2563EB';
                              if (v == 'power_ac') colorHex = '#DC2626';
                            });
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 1,
                        child: TextField(
                          controller: lengthCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Longitud (m)',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 1,
                        child: TextField(
                          controller: vlanCtrl,
                          decoration: const InputDecoration(
                            labelText: 'VLAN / SAN ID',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    children: fiberPalette.map((hex) {
                      final isSel = colorHex.toUpperCase() == hex.toUpperCase();
                      final col = CableGeometryBuilder.parseHexColor(hex);
                      return GestureDetector(
                        onTap: () => setModal(() => colorHex = hex),
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: col,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isSel ? Colors.black : Colors.white,
                              width: isSel ? 2.4 : 1.2,
                            ),
                          ),
                          child: isSel
                              ? const Icon(
                                  Icons.check,
                                  size: 13,
                                  color: Colors.white,
                                )
                              : null,
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: labelCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Etiqueta de la Fibra / Enlace Inter-Rack',
                      isDense: true,
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
              onPressed: (selectedLocalPort == null || selectedTargetPort == null)
                  ? null
                  : () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.add_link, size: 16),
              label: const Text('Conectar entre Racks'),
            ),
          ],
        ),
      ),
    );

    _rebuildState(() {
      _pendingSourcePort = null;
      _pendingSourceDevice = null;
    });

    if (confirmed == true &&
        selectedLocalPort != null &&
        selectedTargetPort != null) {
      try {
        final created = await widget.api.createConnection({
          'source_port_id': selectedLocalPort!.id,
          'target_port_id': selectedTargetPort!['id'] as int,
          'cable_type': cableType,
          'color_hex': colorHex,
          'routing_channel': 'right',
          'label': labelCtrl.text.trim(),
          'vlan': int.tryParse(vlanCtrl.text.trim()),
          'length_m': double.tryParse(lengthCtrl.text.trim()) ?? 12.0,
        });
        await _loadRack();
        _rebuildState(() {
          _selectedConnectionId = created.id;
          _selectedDeviceId = null;
        });
        messenger.aviso('Fibra / Cable Inter-Rack conectado hacia ${selectedTargetRack['code']} (${selectedTargetDev?['code']}:${selectedTargetPort!['port_number']}).');
      } catch (e) {
        messenger.avisoError('$e');
      }
    }
  }

  String _resolvePhotoNetworkUrl(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return '${widget.api.baseUrl}/templates/photo-proxy?url=${Uri.encodeComponent(trimmed)}';
    }
    return trimmed;
  }

  // ===========================================================================
  // BUSCADOR DE FOTOS DE REFERENCIA EN INTERNET PARA PLANTILLAS Y EQUIPOS
  // ===========================================================================
  Future<void> _showHardwarePhotoSearchDialog({
    DeviceTemplateModel? template,
    RackDeviceModel? device,
  }) async {
    final tpl = template ?? device?.template;
    if (tpl == null) return;
    final messenger = ScaffoldMessenger.of(context);

    final queryCtrl = TextEditingController(
      text: '${tpl.manufacturer} ${tpl.modelName}',
    );
    final urlCtrl = TextEditingController(
      text: device?.photoUrl.isNotEmpty == true
          ? device!.photoUrl
          : tpl.photoUrl,
    );
    List<Map<String, dynamic>> searchResults = [];
    bool searching = false;
    String? searchError;
    bool applyToTemplateLibrary = true;

    Future<void> triggerSearch(StateSetter setModal) async {
      final q = queryCtrl.text.trim();
      if (q.isEmpty) return;
      setModal(() {
        searching = true;
        searchError = null;
      });
      try {
        final res = await widget.api.searchHardwarePhotos(q);
        setModal(() {
          searchResults = res;
          searching = false;
        });
      } catch (e) {
        setModal(() {
          searchError = '$e';
          searching = false;
        });
      }
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        bool initialTriggered = false;
        return StatefulBuilder(
          builder: (ctx, setModal) {
            if (!initialTriggered) {
              initialTriggered = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                triggerSearch(setModal);
              });
            }
            return AlertDialog(
              title: Row(
                children: [
                  const Icon(
                    Icons.photo_camera_outlined,
                    color: AppPalette.blue700,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Foto de Referencia — ${tpl.manufacturer} ${tpl.modelName}',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
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
                      const Text(
                        'Busca referencias fotográficas en Internet (Wikimedia Commons), pega una URL de imagen de catálogo del fabricante o sube una foto local:',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: AppPalette.slate600,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: queryCtrl,
                              onSubmitted: (_) => triggerSearch(setModal),
                              decoration: const InputDecoration(
                                labelText:
                                    'Buscar en Internet (ej. Dell PowerEdge, NetApp AFF, Cisco Switch, IBM FlashSystem...)',
                                isDense: true,
                                prefixIcon: Icon(Icons.search, size: 18),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton.tonalIcon(
                            onPressed:
                                searching ? null : () => triggerSearch(setModal),
                            icon: const Icon(Icons.travel_explore, size: 16),
                            label: Text(searching ? 'Buscando...' : 'Buscar Web'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      if (searching)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 18),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (searchError != null)
                        Text(
                          'Aviso: $searchError',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppPalette.red600,
                          ),
                        )
                      else if (searchResults.isNotEmpty) ...[
                        const Text(
                          'Resultados encontrados en Internet (haz clic en una foto para usarla):',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: AppPalette.slate800,
                          ),
                        ),
                        const SizedBox(height: 6),
                        SizedBox(
                          height: 135,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: searchResults.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 8),
                            itemBuilder: (_, idx) {
                              final item = searchResults[idx];
                              final thumb =
                                  (item['thumb_url'] ?? '').toString();
                              final title = (item['title'] ?? '').toString();
                              final isSel = urlCtrl.text.trim() == thumb;
                              return InkWell(
                                onTap: () =>
                                    setModal(() => urlCtrl.text = thumb),
                                child: Container(
                                  width: 165,
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: isSel
                                        ? AppPalette.blue100
                                        : AppPalette.slate50,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: isSel
                                          ? AppPalette.blue600
                                          : AppPalette.slate300,
                                      width: isSel ? 2.2 : 1.0,
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Expanded(
                                        child: ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(4),
                                          child: Image.network(
                                            _resolvePhotoNetworkUrl(thumb),
                                            fit: BoxFit.cover,
                                            errorBuilder: (_, _, _) =>
                                                const Center(
                                              child: Icon(
                                                Icons.broken_image_outlined,
                                                size: 22,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: urlCtrl,
                              onChanged: (_) => setModal(() {}),
                              decoration: const InputDecoration(
                                labelText:
                                    'URL de Foto del Equipo (o déjalo vacío para Bisel Técnico CAD)',
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: () {
                              setModal(() => urlCtrl.text = '');
                            },
                            icon: const Icon(Icons.clear, size: 15),
                            label: const Text('Quitar'),
                          ),
                        ],
                      ),
                      if (urlCtrl.text.trim().isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Container(
                          height: 68,
                          width: double.infinity,
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: AppPalette.slate900,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Image.network(
                            _resolvePhotoNetworkUrl(urlCtrl.text.trim()),
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => const Center(
                              child: Text(
                                'Previsualización no disponible para esta URL',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                      if (device != null) ...[
                        const SizedBox(height: 8),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          value: applyToTemplateLibrary,
                          onChanged: (v) => setModal(
                            () => applyToTemplateLibrary = v ?? true,
                          ),
                          title: Text(
                            'Guardar también como foto por defecto del modelo "${tpl.modelName}" en la Librería',
                            style: const TextStyle(fontSize: 11.5),
                          ),
                        ),
                      ],
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
                  icon: const Icon(Icons.save_outlined, size: 16),
                  label: const Text('Guardar Foto y Activar Vista Foto'),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirmed == true) {
      final newUrl = urlCtrl.text.trim();
      try {
        if (device != null) {
          final updatedCf = Map<String, dynamic>.from(device.customFields);
          updatedCf['photo_url'] = newUrl;
          updatedCf['show_photo'] = true;
          await widget.api.updateDevice(device.id, {
            'custom_fields': updatedCf,
          });
        }
        if (device == null || applyToTemplateLibrary) {
          await widget.api.updateTemplate(tpl.id, {'photo_url': newUrl});
          widget.onTemplatesChanged();
        }
        await _loadRack();
        _rebuildState(() => _showEquipmentPhotos = true);
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              newUrl.isNotEmpty
                  ? 'Foto de referencia asociada a "${tpl.modelName}" y modo Foto Equipos activado.'
                  : 'Foto personalizada eliminada (usando bisel realista automático).',
            ),
          ),
        );
      } catch (e) {
        messenger.avisoError('$e');
      }
    }
  }

  // ===========================================================================
  // GESTIÓN DE TOMAS EXTERIORES (ELÉCTRICAS SCHUKO Y CAJAS DE FIBRA ÓPTICA)
  // ===========================================================================
  Future<void> _quickAdjustExternalOutletCount(
    RackDeviceModel ext,
    int newCount,
  ) async {
    if (!_canEdit) return;
    final maxAllowed = ext.isFiberFeed ? 48 : 16;
    final clamped = newCount.clamp(1, maxAllowed);
    if (clamped == ext.ports.length) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.api.updateExternalOutlet(ext.id, {
        'socket_count': clamped,
        'feed_type': ext.feedType,
      });
      await _loadRack();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${ext.code}: ajustado a $clamped ${ext.isFiberFeed ? 'conectores de fibra' : 'enchufes Schuko'}.',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      messenger.avisoError('$e');
    }
  }

  Future<void> _showAddOrEditExternalOutletDialog({
    RackDeviceModel? existing,
    String initialFeedType = 'power',
  }) async {
    if (!_canEdit) return;
    final rack = _rack;
    if (rack == null) return;
    final messenger = ScaffoldMessenger.of(context);

    final extList = _getExternalOutlets(rack);
    String feedType = existing?.feedType ?? initialFeedType;
    final powerCount = extList.where((d) => !d.isFiberFeed).length;
    final fiberCount = extList.where((d) => d.isFiberFeed).length;
    final nextPowerLetter = String.fromCharCode(65 + powerCount);
    final nextFiberNum = fiberCount + 1;

    const palette = [
      '#DC2626',
      '#2563EB',
      '#0284C7',
      '#F59E0B',
      '#10B981',
      '#EA580C',
      '#7C3AED',
      '#0F172A',
    ];

    final codeCtrl = TextEditingController(
      text: existing?.code ??
          (feedType == 'fiber'
              ? 'FIBRA-EXT-$nextFiberNum'
              : 'TOMA-$nextPowerLetter'),
    );
    final nameCtrl = TextEditingController(
      text: existing?.name ??
          (feedType == 'fiber'
              ? 'Caja Exterior de Fibra Óptica $nextFiberNum (Acometida CPD)'
              : 'Línea $nextPowerLetter (Cuadro Eléctrico Sala)'),
    );
    final socketsCtrl = TextEditingController(
      text: '${existing?.socketCount ?? (feedType == 'fiber' ? 8 : 4)}',
    );
    String selectedColor = existing?.feedColorHex ??
        (feedType == 'fiber'
            ? '#0284C7'
            : palette[powerCount % palette.length]);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) {
          final isFiber = feedType == 'fiber';
          return AlertDialog(
            title: Text(
              existing == null
                  ? (isFiber
                      ? 'Añadir Toma Exterior de Fibra Óptica'
                      : 'Añadir Toma Eléctrica Schuko Exterior')
                  : 'Editar Toma Exterior (${existing.code})',
            ),
            content: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isFiber
                        ? 'Las tomas exteriores de fibra representan acometidas ópticas o cajas murales fuera del bastidor donde puedes ajustar el número de conectores (FO1..FON) y conectar latiguillos al rack.'
                        : 'Las tomas eléctricas exteriores representan enchufes Schuko o acometidas fuera del bastidor a las que puedes enchufar equipos o regletas del rack.',
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: AppPalette.slate600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: feedType,
                    decoration: const InputDecoration(
                      labelText: 'Tipo de Toma Exterior',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'power',
                        child: Text(
                          '⚡ Toma Eléctrica Exterior (Enchufes Schuko 230V)',
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'fiber',
                        child: Text(
                          '🔆 Toma Exterior de Fibra Óptica (Conectores LC/SC)',
                        ),
                      ),
                    ],
                    onChanged: existing != null
                        ? null
                        : (val) {
                            if (val == null) return;
                            setModal(() {
                              feedType = val;
                              if (val == 'fiber') {
                                codeCtrl.text = 'FIBRA-EXT-$nextFiberNum';
                                nameCtrl.text =
                                    'Caja Exterior de Fibra Óptica $nextFiberNum (Acometida CPD)';
                                socketsCtrl.text = '8';
                                selectedColor = '#0284C7';
                              } else {
                                codeCtrl.text = 'TOMA-$nextPowerLetter';
                                nameCtrl.text =
                                    'Línea $nextPowerLetter (Cuadro Eléctrico Sala)';
                                socketsCtrl.text = '4';
                                selectedColor = '#DC2626';
                              }
                            });
                          },
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: codeCtrl,
                          decoration: InputDecoration(
                            labelText: isFiber
                                ? 'Código (ej. FIBRA-EXT-1)'
                                : 'Código (ej. TOMA-A, TOMA-B)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: socketsCtrl,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: isFiber
                                ? 'Nº Conectores Fibra (1-48)'
                                : 'Nº Enchufes Schuko (1-16)',
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (isFiber) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        const Text(
                          'Ajuste rápido conectores: ',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: AppPalette.slate600,
                          ),
                        ),
                        for (final preset in [4, 6, 8, 12, 16, 24])
                          Padding(
                            padding: const EdgeInsets.only(right: 5),
                            child: ActionChip(
                              visualDensity: VisualDensity.compact,
                              label: Text(
                                '${preset}x FO',
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              onPressed: () {
                                setModal(() => socketsCtrl.text = '$preset');
                              },
                            ),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 10),
                  TextField(
                    controller: nameCtrl,
                    decoration: InputDecoration(
                      labelText: isFiber
                          ? 'Descripción de la Acometida / Caja de Fibra Exterior'
                          : 'Descripción de la Línea / Circuito Eléctrico',
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    isFiber
                        ? 'Color Identificativo de la Fibra (Aqua OM4 #0284C7, Amarillo OS2 #F59E0B, Verde APC #10B981...):'
                        : 'Color Estándar de la Línea Eléctrica (sus cables heredarán este color):',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: AppPalette.slate800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: palette.map((hex) {
                      final isSel =
                          selectedColor.toUpperCase() == hex.toUpperCase();
                      final col = CableGeometryBuilder.parseHexColor(hex);
                      return GestureDetector(
                        onTap: () => setModal(() => selectedColor = hex),
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: col,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isSel ? Colors.black : Colors.white,
                              width: isSel ? 2.8 : 1.5,
                            ),
                          ),
                          child: isSel
                              ? Icon(
                                  isFiber
                                      ? Icons.settings_input_hdmi_outlined
                                      : Icons.bolt,
                                  size: 17,
                                  color: Colors.white,
                                )
                              : null,
                        ),
                      );
                    }).toList(),
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
                icon: const Icon(Icons.save_outlined, size: 16),
                label: Text(
                  existing == null ? 'Añadir Toma Exterior' : 'Guardar Cambios',
                ),
              ),
            ],
          );
        },
      ),
    );

    if (confirmed == true) {
      try {
        final isFiber = feedType == 'fiber';
        final maxPorts = isFiber ? 48 : 16;
        final count = (int.tryParse(socketsCtrl.text.trim()) ??
                (isFiber ? 8 : 4))
            .clamp(1, maxPorts);
        if (existing == null) {
          await widget.api.createExternalOutlet(rack.id, {
            'code': codeCtrl.text.trim(),
            'name': nameCtrl.text.trim(),
            'color_hex': selectedColor,
            'socket_count': count,
            'feed_type': feedType,
          });
        } else {
          await widget.api.updateExternalOutlet(existing.id, {
            'code': codeCtrl.text.trim(),
            'name': nameCtrl.text.trim(),
            'color_hex': selectedColor,
            'socket_count': count,
            'feed_type': feedType,
          });
        }
        await _loadRack();
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              existing == null
                  ? 'Nueva toma exterior "${codeCtrl.text.trim()}" ($count ${isFiber ? 'conectores fibra' : 'enchufes Schuko'}) añadida.'
                  : 'Toma exterior "${codeCtrl.text.trim()}" actualizada ($count ${isFiber ? 'conectores fibra' : 'enchufes Schuko'}).',
            ),
          ),
        );
      } catch (e) {
        messenger.avisoError('$e');
      }
    }
  }

  Future<void> _deleteExternalOutlet(RackDeviceModel ext) async {
    if (!_canEdit) return;
    final rack = _rack;
    if (rack == null) return;
    final extOutlets = _getExternalOutlets(rack);
    final messenger = ScaffoldMessenger.of(context);
    if (extOutlets.length <= 1) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'Debe existir como mínimo 1 toma eléctrica exterior en el rack.',
          ),
          backgroundColor: AppPalette.amber600,
        ),
      );
      return;
    }

    try {
      await widget.api.deleteExternalOutlet(ext.id);
      await _loadRack();
      messenger.aviso('Toma exterior "${ext.code}" eliminada.');
    } catch (e) {
      messenger.avisoError('$e');
    }
  }

  // ===========================================================================
  // IMPORTAR / EXPORTAR LIBRERÍAS DE DISPOSITIVOS POR GRUPO (.JSON)
  // ===========================================================================
  Future<void> _handleExportLibraryDialog() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final groupParam =
          _selectedLibraryGroup == 'all' ? null : _selectedLibraryGroup;
      final exported = await widget.api.exportTemplates(
        libraryGroup: groupParam,
      );
      final prettyJson =
          const JsonEncoder.withIndent('  ').convert(exported);

      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(
            'Exportar Librería (${_selectedLibraryGroup == 'all' ? 'Todas' : _selectedLibraryGroup})',
          ),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Se han exportado ${exported['count'] ?? 0} plantillas en formato JSON estándar de RackDoc. Puedes copiar este JSON para guardarlo o importarlo en otro grupo/instancia:',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppPalette.slate600,
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  height: 280,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppPalette.slate900,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      prettyJson,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: AppPalette.slate200,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cerrar'),
            ),
            FilledButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: prettyJson));
                if (ctx.mounted) Navigator.pop(ctx);
                messenger.aviso('JSON de la librería copiado al portapapeles.');
              },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copiar JSON'),
            ),
          ],
        ),
      );
    } catch (e) {
      messenger.aviso('Error exportando librería: $e');
    }
  }

  Future<void> _handleImportLibraryDialog() async {
    if (!_canEdit) return;
    final messenger = ScaffoldMessenger.of(context);
    final groupCtrl = TextEditingController(
      text: _selectedLibraryGroup == 'all' ? 'Network' : _selectedLibraryGroup,
    );
    final jsonCtrl = TextEditingController();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: const Text('Importar Librería de Dispositivos (.json)'),
          content: SizedBox(
            width: 540,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: groupCtrl,
                    decoration: const InputDecoration(
                      labelText:
                          'Grupo / Librería Destino (ej. Network, Power, Host - HP, Host - Cisco)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Carga un fichero .json o pega su contenido abajo:',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      OutlinedButton.icon(
                        onPressed: () async {
                          final picked = await FilePicker.pickFiles(
                            type: FileType.custom,
                            allowedExtensions: ['json'],
                          );
                          if (picked.isNotEmpty) {
                            final bytes =
                                await picked.first.xFile.readAsBytes();
                            final content = utf8.decode(bytes);
                            setModal(() {
                              jsonCtrl.text = content;
                            });
                          }
                        },
                        icon: const Icon(Icons.folder_open, size: 16),
                        label: const Text('Seleccionar archivo .json'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: jsonCtrl,
                    maxLines: 9,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                    decoration: const InputDecoration(
                      hintText:
                          '{\n  "library_group": "Host - HP",\n  "templates": [ ... ]\n}',
                      border: OutlineInputBorder(),
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
              icon: const Icon(Icons.upload_outlined, size: 16),
              label: const Text('Importar al Grupo'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true && jsonCtrl.text.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(jsonCtrl.text.trim());
        List<Map<String, dynamic>> list = [];
        if (decoded is Map && decoded['templates'] is List) {
          list = (decoded['templates'] as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        } else if (decoded is List) {
          list = decoded
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        }
        final targetGroup = groupCtrl.text.trim().isEmpty
            ? 'General'
            : groupCtrl.text.trim();
        final res = await widget.api.importTemplates(
          libraryGroup: targetGroup,
          templates: list,
        );
        widget.onTemplatesChanged();
        _rebuildState(() => _selectedLibraryGroup = targetGroup);
        messenger.aviso('Librería "$targetGroup" importada: ${res['created']} creados, ${res['updated']} actualizados.');
      } catch (e) {
        messenger.avisoError('Error importando JSON: $e');
      }
    }
  }

  Future<void> _showConfigureDevicePortsDialog(RackDeviceModel dev) async {
    if (!_canEdit) return;
    if (dev.isRackTray) {
      await _showManageTrayItemsDialog(dev);
      return;
    }
    final messenger = ScaffoldMessenger.of(context);

    int countTypeOnFace(String face, bool Function(String) match) {
      return dev
          .portsForFace(face)
          .where((p) => match(p.portType.toLowerCase()))
          .length;
    }

    final fRjCtrl = TextEditingController(
      text: '${countTypeOnFace('front', (t) => t.contains('rj45') || t.contains('eth'))}',
    );
    final fSfpCtrl = TextEditingController(
      text: '${countTypeOnFace('front', (t) => t.contains('sfp') || t.contains('fiber') || t.contains('qsfp'))}',
    );
    final fPsuCtrl = TextEditingController(
      text: '${countTypeOnFace('front', (t) => (t.contains('power') || t.contains('c14') || t.contains('c13')) && !t.contains('schuko'))}',
    );
    final fSchCtrl = TextEditingController(
      text: '${countTypeOnFace('front', (t) => t.contains('schuko'))}',
    );

    final bRjCtrl = TextEditingController(
      text: '${countTypeOnFace('back', (t) => t.contains('rj45') || t.contains('eth'))}',
    );
    final bSfpCtrl = TextEditingController(
      text: '${countTypeOnFace('back', (t) => t.contains('sfp') || t.contains('fiber') || t.contains('qsfp'))}',
    );
    final bPsuCtrl = TextEditingController(
      text: '${countTypeOnFace('back', (t) => (t.contains('power') || t.contains('c14') || t.contains('c13')) && !t.contains('schuko'))}',
    );
    final bSchCtrl = TextEditingController(
      text: '${countTypeOnFace('back', (t) => t.contains('schuko'))}',
    );

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(
              Icons.settings_input_component_rounded,
              color: AppPalette.blue700,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Configurar Bocas FRONT y BACK — ${dev.code} (${dev.name})',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Define cuántas bocas RJ45 (Cobre), SFP/Fibra Óptica, Tomas Eléctricas PSU (C14) y Enchufes Schuko tiene este equipo tanto por DELANTE (Front) como por DETRÁS (Back):',
                style: TextStyle(fontSize: 11.5, color: AppPalette.slate600),
              ),
              const SizedBox(height: 14),
              const Text(
                '1. BOCAS EN CARA DELANTERA (FRONT):',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: AppPalette.slate900,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: fRjCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'RJ45 (Front)',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: fSfpCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'SFP Fibra (Front)',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: fPsuCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Tomas PSU (Front)',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: fSchCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Schuko (Front)',
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              const Text(
                '2. BOCAS EN CARA TRASERA (BACK):',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: AppPalette.blue900,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: bRjCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'RJ45 (Back)',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: bSfpCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'SFP Fibra (Back)',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: bPsuCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Tomas PSU (Back)',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: bSchCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Schuko (Back)',
                        isDense: true,
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
            icon: const Icon(Icons.save_outlined, size: 16),
            label: const Text('Guardar Bocas Front & Back'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final updatedCustom = Map<String, dynamic>.from(dev.customFields);
        updatedCustom['custom_layout_spec'] = {
          'front': _buildFacePortGroups(
            rj45Count: int.tryParse(fRjCtrl.text.trim()) ?? 0,
            sfpCount: int.tryParse(fSfpCtrl.text.trim()) ?? 0,
            psuCount: int.tryParse(fPsuCtrl.text.trim()) ?? 0,
            schukoCount: int.tryParse(fSchCtrl.text.trim()) ?? 0,
            isBackFace: false,
          ),
          'back': _buildFacePortGroups(
            rj45Count: int.tryParse(bRjCtrl.text.trim()) ?? 0,
            sfpCount: int.tryParse(bSfpCtrl.text.trim()) ?? 0,
            psuCount: int.tryParse(bPsuCtrl.text.trim()) ?? 0,
            schukoCount: int.tryParse(bSchCtrl.text.trim()) ?? 0,
            isBackFace: true,
          ),
        };
        await widget.api.updateDevice(dev.id, {
          'custom_fields': updatedCustom,
        });
        await _loadRack();
        messenger.aviso('Bocas Front y Back de "${dev.code}" actualizadas correctamente.');
      } catch (e) {
        messenger.avisoError('$e');
      }
    }
  }

  Future<void> _showCreateCustomTemplateDialog() async {
    if (!_canEdit) return;
    String category = _selectedLibraryGroup == 'Power'
        ? 'pdu'
        : (_selectedLibraryGroup == 'Bandeja - Equipos Mini'
            ? 'rack_tray_device'
            : (_selectedLibraryGroup.startsWith('Host')
                ? 'server'
                : (_selectedLibraryGroup == 'Storage - SAN'
                    ? 'storage_san'
                    : (_selectedLibraryGroup == 'Storage - NAS'
                        ? 'storage_nas'
                        : 'switch'))));
    final libraryCtrl = TextEditingController(
      text: _selectedLibraryGroup == 'all' ? 'Network' : _selectedLibraryGroup,
    );
    final manufCtrl = TextEditingController(
      text: _selectedLibraryGroup == 'Host - HP'
          ? 'HPE'
          : (_selectedLibraryGroup == 'Power' ? 'APC / Schuko' : 'Cisco'),
    );
    final modelCtrl = TextEditingController(text: 'Custom Device 1U');
    final uCtrl = TextEditingController(text: '1');

    // Bocas en Cara Delantera (FRONT)
    final frontRj45Ctrl = TextEditingController(
      text: category == 'pdu' ? '0' : (category == 'server' ? '2' : '24'),
    );
    final frontFiberCtrl = TextEditingController(
      text: category == 'pdu' ? '0' : (category == 'server' ? '0' : '4'),
    );
    final frontPowerCtrl = TextEditingController(text: '0');
    final frontSchukoCtrl = TextEditingController(
      text: category == 'pdu' ? '6' : '0',
    );

    // Bocas en Cara Trasera (BACK) — RJ45, SFP Fibra, Tomas PSU y Schuko
    final backRj45Ctrl = TextEditingController(
      text: category == 'server' ? '4' : '0',
    );
    final backFiberCtrl = TextEditingController(
      text: (category == 'server' ||
              category == 'storage_san' ||
              category == 'storage_nas')
          ? '4'
          : '0',
    );
    final backPowerCtrl = TextEditingController(text: '2');
    final backSchukoCtrl = TextEditingController(text: '0');

    bool isFullDepth = true;

    const presetGroups = [
      'Network',
      'Bandeja - Equipos Mini',
      'Storage - SAN',
      'Storage - NAS',
      'Power',
      'Host - HP',
      'Host - Dell',
      'Host - Supermicro',
      'Patching & Passive',
    ];

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: const Text('Crear Nuevo Equipo en Librería (Con Puertos Front y Back)'),
          content: SizedBox(
            width: 540,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Grupo / Librería (selecciona uno existente o escribe uno nuevo):',
                    style: TextStyle(fontSize: 11, color: AppPalette.slate500),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: presetGroups.map((g) {
                      final active = libraryCtrl.text.trim() == g;
                      return ChoiceChip(
                        label: Text(g, style: const TextStyle(fontSize: 11)),
                        selected: active,
                        onSelected: (_) {
                          setModal(() {
                            libraryCtrl.text = g;
                            if (g == 'Power') {
                              category = 'pdu';
                              frontRj45Ctrl.text = '0';
                              frontFiberCtrl.text = '0';
                              frontPowerCtrl.text = '0';
                              frontSchukoCtrl.text = '8';
                              backRj45Ctrl.text = '0';
                              backFiberCtrl.text = '0';
                              backPowerCtrl.text = '2';
                              backSchukoCtrl.text = '0';
                            } else if (g.startsWith('Host')) {
                              category = 'server';
                              frontRj45Ctrl.text = '2';
                              frontFiberCtrl.text = '0';
                              frontPowerCtrl.text = '0';
                              frontSchukoCtrl.text = '0';
                              backRj45Ctrl.text = '4';
                              backFiberCtrl.text = '2';
                              backPowerCtrl.text = '2';
                              backSchukoCtrl.text = '0';
                              isFullDepth = true;
                            } else if (g == 'Storage - SAN' ||
                                g == 'Storage - NAS') {
                              category = g == 'Storage - SAN'
                                  ? 'storage_san'
                                  : 'storage_nas';
                              frontRj45Ctrl.text = '2';
                              frontFiberCtrl.text = '4';
                              backRj45Ctrl.text = '4';
                              backFiberCtrl.text = '8';
                              backPowerCtrl.text = '2';
                              isFullDepth = true;
                            } else if (g == 'Bandeja - Equipos Mini') {
                              category = 'rack_tray_device';
                              frontRj45Ctrl.text = '5';
                              frontFiberCtrl.text = '1';
                              backRj45Ctrl.text = '1';
                              backFiberCtrl.text = '0';
                              backPowerCtrl.text = '1';
                            }
                          });
                        },
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: libraryCtrl,
                    decoration: const InputDecoration(
                      labelText:
                          'Nombre de Librería (ej. Network, Power, Host - HP, Bandeja - Equipos Mini)',
                    ),
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: category,
                    decoration:
                        const InputDecoration(labelText: 'Categoría Técnica'),
                    items: const [
                      DropdownMenuItem(value: 'switch', child: Text('Switch')),
                      DropdownMenuItem(value: 'router', child: Text('Router')),
                      DropdownMenuItem(
                        value: 'firewall',
                        child: Text('Firewall'),
                      ),
                      DropdownMenuItem(
                        value: 'server',
                        child: Text('Server / Host (HP, Dell, etc.)'),
                      ),
                      DropdownMenuItem(
                        value: 'storage_san',
                        child: Text('Storage SAN (Cabina Fibra/NVMe)'),
                      ),
                      DropdownMenuItem(
                        value: 'storage_nas',
                        child: Text('Storage NAS (Almacenamiento Red)'),
                      ),
                      DropdownMenuItem(
                        value: 'rack_tray_device',
                        child: Text(
                          'Bandeja - Equipo Mini (Router / Switch / Mini-PC sobre Bandeja)',
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'pdu',
                        child: Text('Power — PDU / Regleta Enchufes Schuko'),
                      ),
                      DropdownMenuItem(
                        value: 'ups',
                        child: Text('Power — UPS / SAI'),
                      ),
                      DropdownMenuItem(
                        value: 'patch_panel',
                        child: Text('Patch Panel'),
                      ),
                      DropdownMenuItem(
                        value: 'rack_tray',
                        child: Text('Rack Tray (Bandeja 19")'),
                      ),
                    ],
                    onChanged: (v) => setModal(() => category = v ?? 'switch'),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: manufCtrl,
                          decoration:
                              const InputDecoration(labelText: 'Fabricante'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: uCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Altura en U (1, 2, 4)',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: modelCtrl,
                    decoration:
                        const InputDecoration(labelText: 'Nombre del Modelo'),
                  ),
                  const SizedBox(height: 10),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Autorrellenar Cara Trasera (Ocupa Front y Back)',
                      style: TextStyle(fontSize: 13),
                    ),
                    value: isFullDepth,
                    onChanged: (v) => setModal(() => isFullDepth = v),
                  ),
                  const Divider(height: 18),
                  const Text(
                    '1. BOCAS EN CARA DELANTERA (FRONT):',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: AppPalette.slate900,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: frontRj45Ctrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'RJ45 (Front)',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: frontFiberCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'SFP Fibra (Front)',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: frontPowerCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Tomas PSU (Front)',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: frontSchukoCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Schuko (Front)',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    '2. BOCAS EN CARA TRASERA (BACK — RJ45, SFP Fibra y Electricidad):',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: AppPalette.blue900,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: backRj45Ctrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'RJ45 (Back)',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: backFiberCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'SFP Fibra (Back)',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: backPowerCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Tomas PSU (Back)',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: backSchukoCtrl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            labelText: 'Schuko (Back)',
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
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
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Guardar en Librería'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      final frontGroups = _buildFacePortGroups(
        rj45Count: int.tryParse(frontRj45Ctrl.text.trim()) ?? 0,
        sfpCount: int.tryParse(frontFiberCtrl.text.trim()) ?? 0,
        psuCount: int.tryParse(frontPowerCtrl.text.trim()) ?? 0,
        schukoCount: int.tryParse(frontSchukoCtrl.text.trim()) ?? 0,
        isBackFace: false,
      );

      final backGroups = _buildFacePortGroups(
        rj45Count: int.tryParse(backRj45Ctrl.text.trim()) ?? 0,
        sfpCount: int.tryParse(backFiberCtrl.text.trim()) ?? 0,
        psuCount: int.tryParse(backPowerCtrl.text.trim()) ?? 0,
        schukoCount: int.tryParse(backSchukoCtrl.text.trim()) ?? 0,
        isBackFace: true,
      );

      final targetLib = libraryCtrl.text.trim().isEmpty
          ? 'General'
          : libraryCtrl.text.trim();

      await widget.api.createTemplate({
        'category': category,
        'library_group': targetLib,
        'manufacturer': manufCtrl.text.trim(),
        'model_name': modelCtrl.text.trim(),
        'u_height': int.tryParse(uCtrl.text.trim()) ?? 1,
        'is_full_depth': isFullDepth,
        'layout_spec': {'front': frontGroups, 'back': backGroups},
      });
      widget.onTemplatesChanged();
      _rebuildState(() => _selectedLibraryGroup = targetLib);
    }
  }
}
