import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/api_client.dart';
import '../../core/image_file_picker.dart';
import '../../models/datacenter_models.dart';

class DatacenterFloorView extends StatefulWidget {
  final RackDocApiClient api;
  final List<LocationNode> locations;
  final int activeLocationId;
  final int? initialFloorId;
  final ValueChanged<int> onChangeLocation;
  final VoidCallback onBackToLocations;
  final ValueChanged<int> onOpenRack;
  final VoidCallback onRefresh;

  const DatacenterFloorView({
    super.key,
    required this.api,
    required this.locations,
    required this.activeLocationId,
    this.initialFloorId,
    required this.onChangeLocation,
    required this.onBackToLocations,
    required this.onOpenRack,
    required this.onRefresh,
  });

  @override
  State<DatacenterFloorView> createState() => _DatacenterFloorViewState();
}

class _DatacenterFloorViewState extends State<DatacenterFloorView> {
  int? _selectedFloorId;
  bool _uploading = false;
  bool _floorPlanLoadError = false;

  // Estado local en vivo para arrastrar y dimensionar los Racks en la Vista de Planta
  final Map<int, Offset> _rackPositions = {};
  final Map<int, Size> _rackSizes = {};
  final Map<int, int> _rackRotations = {};
  double _floorImageScale = 1.0;

  // Selección múltiple de Racks (Caja de selección con ratón o Shift + Clic)
  final Set<int> _selectedRackIds = {};
  Offset? _marqueeStart;
  Offset? _marqueeCurrent;

  LocationNode? get _location {
    if (widget.locations.isEmpty) return null;
    return widget.locations.firstWhere(
      (l) => l.id == widget.activeLocationId,
      orElse: () => widget.locations.first,
    );
  }

  FloorNode? get _floor {
    final loc = _location;
    if (loc == null || loc.floors.isEmpty) return null;
    final targetId = _selectedFloorId ?? widget.initialFloorId;
    if (targetId != null) {
      for (final f in loc.floors) {
        if (f.id == targetId) return f;
      }
    }
    // Por defecto elegimos la primera planta que tenga racks (o la primera disponible)
    for (final f in loc.floors) {
      final hasRacks = f.rooms.any((r) => r.racks.isNotEmpty);
      if (hasRacks) return f;
    }
    return loc.floors.first;
  }

  @override
  void initState() {
    super.initState();
    _syncFloorState();
  }

  @override
  void didUpdateWidget(covariant DatacenterFloorView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncFloorState();
  }

  void _syncFloorState() {
    final fl = _floor;
    if (fl == null) return;
    _selectedFloorId = fl.id;
    _floorImageScale = fl.mapScale.clamp(0.4, 3.0);

    int idx = 0;
    for (final rm in fl.rooms) {
      for (final rk in rm.racks) {
        double nx = rk.posX;
        double ny = rk.posY;
        if (nx <= 0.01 || nx >= 0.95) {
          nx = (0.14 + (idx % 5) * 0.16).clamp(0.08, 0.84);
        }
        if (ny <= 0.01 || ny >= 0.95) {
          ny = (0.22 + (idx ~/ 5) * 0.24).clamp(0.10, 0.80);
        }
        _rackPositions[rk.id] = Offset(nx, ny);
        _rackSizes[rk.id] = Size(
          rk.widthPx.clamp(70.0, 280.0),
          rk.depthPx.clamp(60.0, 260.0),
        );
        _rackRotations[rk.id] = rk.rotationDeg;
        idx++;
      }
    }
  }

  Future<void> _uploadFloorBlueprint(FloorNode floor) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final picked = await pickPlanImageFile();
      if (picked == null) return;

      setState(() => _uploading = true);
      await widget.api.uploadCustomPlanImage(
        targetType: 'floor',
        targetId: floor.id,
        filename: picked.name,
        fileBytes: picked.bytes,
      );
      widget.onRefresh();
      messenger.showSnackBar(
        SnackBar(
          content: Text('Plano de planta "${floor.name}" subido correctamente.'),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Error al subir plano de planta: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
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
    setState(() {
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
    setState(() {
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
    final refId = _selectedRackIds.first;
    final refSize = _rackSizes[refId] ?? const Size(120.0, 90.0);
    setState(() {
      for (final id in _selectedRackIds) {
        _rackSizes[id] = refSize;
      }
    });
    await _saveMultipleRacksGeometry(_selectedRackIds);
  }

  Future<void> _saveFloorScale(FloorNode floor, double newScale) async {
    setState(() => _floorImageScale = newScale);
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
              backgroundColor: const Color(0xFFDC2626),
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
        messenger.showSnackBar(
          SnackBar(content: Text('Planta "${fl.name}" eliminada.')),
        );
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Error eliminando planta: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
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
              backgroundColor: const Color(0xFFDC2626),
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
        messenger.showSnackBar(
          SnackBar(content: Text('Rack "${rk.code}" eliminado.')),
        );
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Error eliminando rack: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
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
              color: Color(0xFFDC2626),
            ),
            label: const Text(
              'Eliminar Rack',
              style: TextStyle(color: Color(0xFFDC2626)),
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

  @override
  Widget build(BuildContext context) {
    final loc = _location;
    final floor = _floor;

    if (loc == null) {
      return const Center(child: Text('No hay ningún Datacenter creado.'));
    }

    // Todos los racks de la planta seleccionada
    final floorRacks = <RackSummary>[];
    if (floor != null) {
      for (final rm in floor.rooms) {
        floorRacks.addAll(rm.racks);
      }
    }

    final floorImageUrl = floor != null
        ? widget.api.resolvePlanImageUrl(floor.mapImageUrl)
        : '';

    return Container(
      color: const Color(0xFFF1F5F9),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. CABECERA DEL DATACENTER + SELECTOR DE SEDE + PESTAÑAS DE PLANTAS DEL EDIFICIO
          Container(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    IconButton(
                      onPressed: widget.onBackToLocations,
                      icon: const Icon(Icons.arrow_back_rounded, size: 20),
                      tooltip: 'Volver al Mapa Global de Locations',
                    ),
                    const SizedBox(width: 6),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.apartment_rounded,
                              size: 20,
                              color: Color(0xFF1E3A8A),
                            ),
                            const SizedBox(width: 8),
                            DropdownButton<int>(
                              value: loc.id,
                              underline: const SizedBox.shrink(),
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF0F172A),
                              ),
                              items: widget.locations
                                  .map(
                                    (l) => DropdownMenuItem<int>(
                                      value: l.id,
                                      child: Text('${l.name} (${l.code})'),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (id) {
                                if (id != null) {
                                  setState(() => _selectedFloorId = null);
                                  widget.onChangeLocation(id);
                                }
                              },
                            ),
                          ],
                        ),
                        Text(
                          'PBX  >  Locations  >  ${loc.code}  >  ${floor?.name ?? 'Sin Planta'} (Vista de Planta 2D)',
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    if (loc.monitoredCount > 0) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: loc.offlineCount > 0
                              ? const Color(0xFFFEF2F2)
                              : const Color(0xFFF0FDF4),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: loc.offlineCount > 0
                                ? const Color(0xFFFECACA)
                                : const Color(0xFFBBF7D0),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.monitor_heart_rounded,
                              size: 14,
                              color: loc.offlineCount > 0
                                  ? const Color(0xFFDC2626)
                                  : const Color(0xFF16A34A),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              [
                                'Datacenter Monitorizados: ${loc.monitoredCount}',
                                if (loc.onlineCount > 0) '🟢 ${loc.onlineCount}',
                                if (loc.offlineCount > 0) '🔴 ${loc.offlineCount}',
                                if (loc.warningCount > 0) '🟠 ${loc.warningCount}',
                              ].join(' • '),
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                    ],
                    if (floor != null) ...[
                      OutlinedButton.icon(
                        onPressed: _uploading
                            ? null
                            : () => _uploadFloorBlueprint(floor),
                        icon: const Icon(Icons.upload_file_outlined, size: 16),
                        label: Text(
                          _uploading
                              ? 'Subiendo...'
                              : (floor.mapImageUrl.isNotEmpty
                                  ? 'Cambiar Plano de Planta (JPG/PNG/GIF)'
                                  : 'Subir Plano de Planta (JPG/PNG/GIF)'),
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      if (floor.mapImageUrl.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        IconButton(
                          onPressed: () async {
                            await widget.api.deleteCustomPlanImage(
                              targetType: 'floor',
                              targetId: floor.id,
                            );
                            widget.onRefresh();
                          },
                          icon: const Icon(
                            Icons.delete_outline,
                            size: 18,
                            color: Color(0xFFDC2626),
                          ),
                          tooltip: 'Quitar imagen de fondo de esta planta',
                        ),
                      ],
                      const SizedBox(width: 10),
                      FilledButton.icon(
                        onPressed: () => _showDrawNewRackDialog(floor),
                        icon: const Icon(Icons.add_box_outlined, size: 17),
                        label: const Text('+ Dibujar Nuevo Rack en Planta'),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF1E3A8A),
                        ),
                      ),
                    ],
                  ],
                ),

                const SizedBox(height: 12),

                // BARRA DE PESTAÑAS DE PLANTAS DEL EDIFICIO (Floor 1, Floor 2, Floor 3...)
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      const Text(
                        'PLANTAS DEL EDIFICIO:',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF64748B),
                        ),
                      ),
                      const SizedBox(width: 12),
                      ...loc.floors.map((fl) {
                        final isSel = fl.id == floor?.id;
                        int rCount = 0;
                        for (final r in fl.rooms) {
                          rCount += r.racks.length;
                        }
                        return Padding(
                          padding: const EdgeInsets.only(right: 8, bottom: 8),
                          child: InkWell(
                            onTap: () {
                              setState(() {
                                _selectedFloorId = fl.id;
                                _syncFloorState();
                              });
                            },
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: isSel
                                    ? const Color(0xFF0F172A)
                                    : const Color(0xFFF1F5F9),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: isSel
                                      ? const Color(0xFF0F172A)
                                      : const Color(0xFFCBD5E1),
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.layers,
                                    size: 15,
                                    color: isSel
                                        ? const Color(0xFF38BDF8)
                                        : const Color(0xFF475569),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    fl.name,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: isSel
                                          ? Colors.white
                                          : const Color(0xFF1E293B),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 1.5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: isSel
                                          ? Colors.white24
                                          : const Color(0xFFE2E8F0),
                                      borderRadius: BorderRadius.circular(10),
                                    ),
                                    child: Text(
                                      [
                                        '$rCount racks',
                                        if (fl.monitoredCount > 0)
                                          'Monit: ${fl.monitoredCount}',
                                        if (fl.onlineCount > 0)
                                          '🟢${fl.onlineCount}',
                                        if (fl.offlineCount > 0)
                                          '🔴${fl.offlineCount}',
                                      ].join(' '),
                                      style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: isSel
                                            ? Colors.white
                                            : const Color(0xFF334155),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  InkWell(
                                    onTap: () => _confirmDeleteFloor(fl),
                                    child: Tooltip(
                                      message:
                                          'Eliminar esta Planta (${fl.name})',
                                      child: Icon(
                                        Icons.delete_outline,
                                        size: 15,
                                        color: isSel
                                            ? const Color(0xFFFCA5A5)
                                            : const Color(0xFFDC2626),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: TextButton.icon(
                          onPressed: () => _showAddFloorDialog(loc),
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('+ Añadir Planta'),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // 2. BARRA DE CONTROLES DE LA VISTA DE PLANTA (Escala del Plano, Selección Múltiple y Doble Clic)
          if (floor != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              decoration: const BoxDecoration(
                color: Color(0xFFF8FAFC),
                border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.ads_click_rounded,
                    size: 16,
                    color: Color(0xFF2563EB),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      '1 Clic o Mayús+Clic / Caja de Ratón: Seleccionar uno o varios Racks para moverlos y alinearlos en bloque  •  Doble Clic en el Rack: Abrir en 3. Rack Editor.',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Color(0xFF1E293B),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (floorRacks.isNotEmpty) ...[
                    TextButton.icon(
                      onPressed: () {
                        setState(() {
                          if (_selectedRackIds.length == floorRacks.length) {
                            _selectedRackIds.clear();
                          } else {
                            _selectedRackIds
                              ..clear()
                              ..addAll(floorRacks.map((r) => r.id));
                          }
                        });
                      },
                      icon: Icon(
                        _selectedRackIds.length == floorRacks.length
                            ? Icons.deselect
                            : Icons.select_all,
                        size: 15,
                      ),
                      label: Text(
                        _selectedRackIds.length == floorRacks.length
                            ? 'Deseleccionar Todos'
                            : 'Seleccionar Todos (${floorRacks.length})',
                        style: const TextStyle(fontSize: 11.5),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  const Text(
                    'Escala del Plano:',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF475569),
                    ),
                  ),
                  SizedBox(
                    width: 130,
                    child: Slider(
                      value: _floorImageScale,
                      min: 0.4,
                      max: 2.5,
                      divisions: 21,
                      label: '${(_floorImageScale * 100).round()}%',
                      onChanged: (v) {
                        setState(() => _floorImageScale = v);
                      },
                      onChangeEnd: (v) => _saveFloorScale(floor, v),
                    ),
                  ),
                  Text(
                    '${(_floorImageScale * 100).round()}%',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                ],
              ),
            ),

          // 3. LIENZO DE LA VISTA DE PLANTA 2D DEL EDIFICIO (CON CAJA DE SELECCIÓN MARQUEE, MULTISELECCIÓN SHIFT Y DOBLE CLIC)
          Expanded(
            child: floor == null
                ? const Center(child: Text('Crea una planta para empezar.'))
                : Padding(
                    padding: const EdgeInsets.all(16),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFCBD5E1)),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x0A000000),
                            blurRadius: 12,
                            offset: Offset(0, 4),
                          ),
                        ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final canvasW = constraints.maxWidth;
                          final canvasH = constraints.maxHeight;
                          final marqueeRect = (_marqueeStart != null &&
                                  _marqueeCurrent != null)
                              ? Rect.fromPoints(
                                  _marqueeStart!,
                                  _marqueeCurrent!,
                                )
                              : null;

                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              // A. Fondo interactivo: clic en vacío limpia selección, arrastrar dibuja caja de selección (Marquee)
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () {
                                  if (!_isShiftPressed &&
                                      _selectedRackIds.isNotEmpty) {
                                    setState(() => _selectedRackIds.clear());
                                  }
                                },
                                onPanStart: (details) {
                                  setState(() {
                                    if (!_isShiftPressed) {
                                      _selectedRackIds.clear();
                                    }
                                    _marqueeStart = details.localPosition;
                                    _marqueeCurrent = details.localPosition;
                                  });
                                },
                                onPanUpdate: (details) {
                                  if (_marqueeStart == null) return;
                                  final cur = details.localPosition;
                                  final selRect = Rect.fromPoints(
                                    _marqueeStart!,
                                    cur,
                                  );
                                  setState(() {
                                    _marqueeCurrent = cur;
                                    for (final rk in floorRacks) {
                                      final normPos = _rackPositions[rk.id] ??
                                          const Offset(0.25, 0.35);
                                      final sz = _rackSizes[rk.id] ??
                                          const Size(120.0, 90.0);
                                      final leftPx = (normPos.dx * canvasW)
                                          .clamp(
                                            8.0,
                                            (canvasW - sz.width - 8.0)
                                                .clamp(8.0, canvasW),
                                          );
                                      final topPx = (normPos.dy * canvasH)
                                          .clamp(
                                            8.0,
                                            (canvasH - sz.height - 8.0)
                                                .clamp(8.0, canvasH),
                                          );
                                      final rkRect = Rect.fromLTWH(
                                        leftPx,
                                        topPx,
                                        sz.width,
                                        sz.height,
                                      );
                                      if (selRect.overlaps(rkRect)) {
                                        _selectedRackIds.add(rk.id);
                                      } else if (!_isShiftPressed) {
                                        _selectedRackIds.remove(rk.id);
                                      }
                                    }
                                  });
                                },
                                onPanEnd: (_) {
                                  setState(() {
                                    _marqueeStart = null;
                                    _marqueeCurrent = null;
                                  });
                                },
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    CustomPaint(
                                      painter: _ArchitecturalGridPainter(),
                                    ),
                                    if (floorImageUrl.isNotEmpty)
                                      Center(
                                        child: Transform.scale(
                                          scale: _floorImageScale,
                                          child: Image.network(
                                            floorImageUrl,
                                            fit: BoxFit.contain,
                                            errorBuilder: (ctx, err, _) {
                                              WidgetsBinding.instance
                                                  .addPostFrameCallback((_) {
                                                if (mounted &&
                                                    !_floorPlanLoadError) {
                                                  setState(
                                                    () => _floorPlanLoadError =
                                                        true,
                                                  );
                                                }
                                              });
                                              return const SizedBox.shrink();
                                            },
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),

                              if (_floorPlanLoadError &&
                                  floorImageUrl.isNotEmpty)
                                Positioned(
                                  bottom: 14,
                                  left: 14,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: const Color(0xFFFCD34D),
                                        width: 1.5,
                                      ),
                                      boxShadow: const [
                                        BoxShadow(
                                          color: Colors.black12,
                                          blurRadius: 10,
                                          offset: Offset(0, 3),
                                        ),
                                      ],
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Icon(
                                          Icons.broken_image_outlined,
                                          color: Color(0xFFD97706),
                                          size: 20,
                                        ),
                                        const SizedBox(width: 10),
                                        const Text(
                                          'El plano de fondo anterior no se encuentra disponible. Mostrando cuadrícula técnica.',
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: Color(0xFF334155),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        FilledButton.tonalIcon(
                                          onPressed: () async {
                                            setState(
                                              () => _floorPlanLoadError = false,
                                            );
                                            await _uploadFloorBlueprint(floor);
                                          },
                                          icon: const Icon(
                                            Icons.upload_file_outlined,
                                            size: 15,
                                          ),
                                          label: const Text(
                                            'Subir Nuevo Plano',
                                            style: TextStyle(fontSize: 11.5),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        TextButton(
                                          onPressed: () async {
                                            setState(
                                              () => _floorPlanLoadError = false,
                                            );
                                            await widget.api
                                                .deleteCustomPlanImage(
                                              targetType: 'floor',
                                              targetId: floor.id,
                                            );
                                            widget.onRefresh();
                                          },
                                          child: const Text(
                                            'Usar solo cuadrícula',
                                            style: TextStyle(fontSize: 11.5),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),

                              // B. Dibujos de los Racks en Vista de Planta (Top-Down)
                              for (final rk in floorRacks)
                                _buildTopDownRackBox(
                                  rk: rk,
                                  canvasW: canvasW,
                                  canvasH: canvasH,
                                ),

                              // C. Caja de selección visual (Marquee) al arrastrar con el ratón
                              if (marqueeRect != null)
                                Positioned(
                                  left: marqueeRect.left,
                                  top: marqueeRect.top,
                                  width: marqueeRect.width,
                                  height: marqueeRect.height,
                                  child: IgnorePointer(
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF2563EB)
                                            .withValues(alpha: 0.16),
                                        border: Border.all(
                                          color: const Color(0xFF2563EB),
                                          width: 1.8,
                                        ),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                    ),
                                  ),
                                ),

                              // D. Barra Flotante de Colocación/Alineación cuando hay Racks seleccionados
                              if (_selectedRackIds.isNotEmpty)
                                Positioned(
                                  top: 12,
                                  left: 16,
                                  right: 16,
                                  child: Center(
                                    child: Material(
                                      elevation: 6,
                                      borderRadius: BorderRadius.circular(10),
                                      color: const Color(0xFF0F172A),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 14,
                                          vertical: 8,
                                        ),
                                        child: Wrap(
                                          crossAxisAlignment:
                                              WrapCrossAlignment.center,
                                          spacing: 8,
                                          runSpacing: 6,
                                          children: [
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 8,
                                                vertical: 3,
                                              ),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF2563EB),
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                              ),
                                              child: Text(
                                                '${_selectedRackIds.length} ${_selectedRackIds.length == 1 ? 'Rack seleccionado' : 'Racks seleccionados'}',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                            ),
                                            if (_selectedRackIds.length == 1)
                                              FilledButton.icon(
                                                style: FilledButton.styleFrom(
                                                  backgroundColor:
                                                      const Color(0xFF10B981),
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                ),
                                                onPressed: () => widget
                                                    .onOpenRack(
                                                  _selectedRackIds.first,
                                                ),
                                                icon: const Icon(
                                                  Icons.open_in_new,
                                                  size: 14,
                                                ),
                                                label: const Text(
                                                  'Abrir en Rack Editor (Doble Clic)',
                                                  style:
                                                      TextStyle(fontSize: 11),
                                                ),
                                              ),
                                            if (_selectedRackIds.length >=
                                                2) ...[
                                              OutlinedButton.icon(
                                                style: OutlinedButton.styleFrom(
                                                  foregroundColor: Colors.white,
                                                  side: const BorderSide(
                                                    color: Color(0xFF475569),
                                                  ),
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                ),
                                                onPressed: () =>
                                                    _alignSelectedRacksHorizontally(
                                                  canvasW: canvasW,
                                                  packTightly: false,
                                                ),
                                                icon: const Icon(
                                                  Icons
                                                      .align_vertical_center_rounded,
                                                  size: 14,
                                                ),
                                                label: const Text(
                                                  'Alinear en Fila',
                                                  style:
                                                      TextStyle(fontSize: 11),
                                                ),
                                              ),
                                              OutlinedButton.icon(
                                                style: OutlinedButton.styleFrom(
                                                  foregroundColor: Colors.white,
                                                  side: const BorderSide(
                                                    color: Color(0xFF475569),
                                                  ),
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                ),
                                                onPressed: () =>
                                                    _alignSelectedRacksHorizontally(
                                                  canvasW: canvasW,
                                                  packTightly: true,
                                                ),
                                                icon: const Icon(
                                                  Icons.view_column_outlined,
                                                  size: 14,
                                                ),
                                                label: const Text(
                                                  'Juntar en Fila (Pasillo)',
                                                  style:
                                                      TextStyle(fontSize: 11),
                                                ),
                                              ),
                                              OutlinedButton.icon(
                                                style: OutlinedButton.styleFrom(
                                                  foregroundColor: Colors.white,
                                                  side: const BorderSide(
                                                    color: Color(0xFF475569),
                                                  ),
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                ),
                                                onPressed: () =>
                                                    _alignSelectedRacksVertically(
                                                  canvasH: canvasH,
                                                  packTightly: false,
                                                ),
                                                icon: const Icon(
                                                  Icons
                                                      .align_horizontal_center_rounded,
                                                  size: 14,
                                                ),
                                                label: const Text(
                                                  'Alinear en Columna',
                                                  style:
                                                      TextStyle(fontSize: 11),
                                                ),
                                              ),
                                              OutlinedButton.icon(
                                                style: OutlinedButton.styleFrom(
                                                  foregroundColor: Colors.white,
                                                  side: const BorderSide(
                                                    color: Color(0xFF475569),
                                                  ),
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                ),
                                                onPressed: () =>
                                                    _alignSelectedRacksVertically(
                                                  canvasH: canvasH,
                                                  packTightly: true,
                                                ),
                                                icon: const Icon(
                                                  Icons.table_rows_outlined,
                                                  size: 14,
                                                ),
                                                label: const Text(
                                                  'Juntar en Columna',
                                                  style:
                                                      TextStyle(fontSize: 11),
                                                ),
                                              ),
                                              OutlinedButton.icon(
                                                style: OutlinedButton.styleFrom(
                                                  foregroundColor: Colors.white,
                                                  side: const BorderSide(
                                                    color: Color(0xFF475569),
                                                  ),
                                                  visualDensity:
                                                      VisualDensity.compact,
                                                ),
                                                onPressed:
                                                    _equalizeSelectedRacksSize,
                                                icon: const Icon(
                                                  Icons.aspect_ratio,
                                                  size: 14,
                                                ),
                                                label: const Text(
                                                  'Igualar Tamaño',
                                                  style:
                                                      TextStyle(fontSize: 11),
                                                ),
                                              ),
                                            ],
                                            IconButton(
                                              onPressed: () => setState(
                                                () => _selectedRackIds.clear(),
                                              ),
                                              icon: const Icon(
                                                Icons.close,
                                                size: 16,
                                                color: Colors.white70,
                                              ),
                                              tooltip: 'Limpiar selección',
                                              visualDensity:
                                                  VisualDensity.compact,
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopDownRackBox({
    required RackSummary rk,
    required double canvasW,
    required double canvasH,
  }) {
    final normPos = _rackPositions[rk.id] ?? const Offset(0.25, 0.35);
    final baseSize = _rackSizes[rk.id] ?? const Size(120.0, 90.0);
    final rot = _rackRotations[rk.id] ?? 0;
    final isSelected = _selectedRackIds.contains(rk.id);

    final boxW = baseSize.width;
    final boxH = baseSize.height;
    final leftPx = (normPos.dx * canvasW)
        .clamp(8.0, (canvasW - boxW - 8.0).clamp(8.0, canvasW));
    final topPx = (normPos.dy * canvasH)
        .clamp(8.0, (canvasH - boxH - 8.0).clamp(8.0, canvasH));

    final isCold = rk.aisleType == 'cold';
    final frontStripColor = isCold
        ? const Color(0xFF0284C7)
        : const Color(0xFF2563EB);

    return Positioned(
      left: leftPx,
      top: topPx,
      width: boxW,
      height: boxH,
      child: Tooltip(
        message:
            '${rk.code} (${rk.name})\n• 1 Clic: Seleccionar Rack (Mayús+Clic para selección múltiple)\n• Doble Clic: Abrir en 3. Rack Editor\n• Arrastrar: Mover Rack (o grupo seleccionado)',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            setState(() {
              if (_isShiftPressed) {
                if (_selectedRackIds.contains(rk.id)) {
                  _selectedRackIds.remove(rk.id);
                } else {
                  _selectedRackIds.add(rk.id);
                }
              } else {
                _selectedRackIds
                  ..clear()
                  ..add(rk.id);
              }
            });
          },
          onDoubleTap: () => widget.onOpenRack(rk.id),
          onPanStart: (_) {
            if (!_selectedRackIds.contains(rk.id)) {
              setState(() {
                if (!_isShiftPressed) {
                  _selectedRackIds.clear();
                }
                _selectedRackIds.add(rk.id);
              });
            }
          },
          onPanUpdate: (details) {
            final dxNorm = details.delta.dx / canvasW;
            final dyNorm = details.delta.dy / canvasH;
            final targetIds = _selectedRackIds.contains(rk.id)
                ? _selectedRackIds
                : <int>{rk.id};
            setState(() {
              for (final id in targetIds) {
                final cur = _rackPositions[id] ?? const Offset(0.25, 0.35);
                final nextX = (cur.dx + dxNorm).clamp(0.01, 0.92);
                final nextY = (cur.dy + dyNorm).clamp(0.01, 0.90);
                _rackPositions[id] = Offset(nextX, nextY);
              }
            });
          },
          onPanEnd: (_) {
            final targetIds = _selectedRackIds.contains(rk.id)
                ? _selectedRackIds.toList()
                : <int>[rk.id];
            _saveMultipleRacksGeometry(targetIds);
          },
          child: Container(
            decoration: BoxDecoration(
              color: isSelected
                  ? const Color(0xFF1E3A8A)
                  : const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: isSelected
                    ? const Color(0xFFFACC15)
                    : const Color(0xFF38BDF8),
                width: isSelected ? 2.8 : 1.8,
              ),
              boxShadow: [
                BoxShadow(
                  color: isSelected
                      ? const Color(0x66FACC15)
                      : const Color(0x33000000),
                  blurRadius: isSelected ? 12 : 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Indicador del lado FRONT del Rack según su rotación (0=Arriba, 90=Derecha, 180=Abajo, 270=Izquierda)
              _buildFrontEdgeStrip(rot, frontStripColor),

              // Contenido central del dibujo del Rack en planta (Numeración / Código + Nombre + Acciones)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Botón rotar orientación Front/Back
                        InkWell(
                          onTap: () {
                            setState(() {
                              _rackRotations[rk.id] = ((rot + 90) % 360);
                            });
                            _saveRackGeometry(rk.id);
                          },
                          child: const Tooltip(
                            message: 'Rotar orientación Front/Back del Rack 90°',
                            child: Icon(
                              Icons.rotate_right,
                              size: 14,
                              color: Color(0xFF94A3B8),
                            ),
                          ),
                        ),
                        // Botón editar numeración / nombre y botón eliminar Rack
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            InkWell(
                              onTap: () => _showRenameRackDialog(rk),
                              child: const Tooltip(
                                message: 'Cambiar numeración o nombre del Rack',
                                child: Icon(
                                  Icons.edit_outlined,
                                  size: 13,
                                  color: Color(0xFF94A3B8),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            InkWell(
                              onTap: () => _confirmDeleteRack(rk),
                              child: const Tooltip(
                                message: 'Eliminar este Rack',
                                child: Icon(
                                  Icons.delete_outline,
                                  size: 14,
                                  color: Color(0xFFFCA5A5),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const Spacer(),
                    Text(
                      rk.code,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.3,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      rk.name,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFFBAE6FD),
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${rk.totalUnits}U • ${rk.deviceCount} eq.',
                      style: const TextStyle(
                        color: Color(0xFF94A3B8),
                        fontSize: 9.5,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (rk.monitoredCount > 0) ...[
                      const SizedBox(height: 2),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1.5,
                        ),
                        decoration: BoxDecoration(
                          color: rk.offlineCount > 0
                              ? const Color(0x44DC2626)
                              : const Color(0x3316A34A),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: rk.offlineCount > 0
                                ? const Color(0xFFF87171)
                                : const Color(0xFF4ADE80),
                            width: 0.8,
                          ),
                        ),
                        child: Text(
                          [
                            'Monit:${rk.monitoredCount}',
                            if (rk.onlineCount > 0) '🟢${rk.onlineCount}',
                            if (rk.offlineCount > 0) '🔴${rk.offlineCount}',
                          ].join(' '),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 8.5,
                            fontWeight: FontWeight.w800,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    const Spacer(),
                  ],
                ),
              ),

              // Tirador de Redimensionado (Resize Handle) en la esquina inferior derecha
              Positioned(
                right: 0,
                bottom: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: (details) {
                    setState(() {
                      final curSize = _rackSizes[rk.id] ?? baseSize;
                      final nextW =
                          (curSize.width + details.delta.dx).clamp(76.0, 300.0);
                      final nextH =
                          (curSize.height + details.delta.dy).clamp(64.0, 280.0);
                      _rackSizes[rk.id] = Size(nextW, nextH);
                    });
                  },
                  onPanEnd: (_) => _saveRackGeometry(rk.id),
                  child: Tooltip(
                    message: 'Arrastra para dimensionar el tamaño del Rack en el plano',
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: const BoxDecoration(
                        color: Color(0xFF38BDF8),
                        borderRadius: BorderRadius.only(
                          topLeft: Radius.circular(6),
                          bottomRight: Radius.circular(4),
                        ),
                      ),
                      child: const Icon(
                        Icons.open_in_full_rounded,
                        size: 11,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }

  Widget _buildFrontEdgeStrip(int rot, Color color) {
    if (rot == 90) {
      return Positioned(
        right: 0,
        top: 0,
        bottom: 0,
        width: 5,
        child: Container(color: color),
      );
    } else if (rot == 180) {
      return Positioned(
        bottom: 0,
        left: 0,
        right: 0,
        height: 5,
        child: Container(color: color),
      );
    } else if (rot == 270) {
      return Positioned(
        left: 0,
        top: 0,
        bottom: 0,
        width: 5,
        child: Container(color: color),
      );
    }
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      height: 5,
      child: Container(color: color),
    );
  }
}

class _ArchitecturalGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final minorPaint = Paint()
      ..color = const Color(0xFFF1F5F9)
      ..strokeWidth = 1.0;
    final majorPaint = Paint()
      ..color = const Color(0xFFE2E8F0)
      ..strokeWidth = 1.2;

    const step = 32.0;
    int i = 0;
    for (double x = 0; x <= size.width; x += step) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        (i % 4 == 0) ? majorPaint : minorPaint,
      );
      i++;
    }
    int j = 0;
    for (double y = 0; y <= size.height; y += step) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        (j % 4 == 0) ? majorPaint : minorPaint,
      );
      j++;
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
