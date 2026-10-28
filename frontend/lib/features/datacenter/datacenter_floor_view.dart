import 'package:flutter/material.dart';
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

  // Estado local en vivo para arrastrar y dimensionar los Racks en la Vista de Planta
  final Map<int, Offset> _rackPositions = {};
  final Map<int, Size> _rackSizes = {};
  final Map<int, int> _rackRotations = {};
  double _floorImageScale = 1.0;

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
                            'Datacenter Monitorizados: ${loc.monitoredCount} • 🟢 ${loc.onlineCount} • 🔴 ${loc.offlineCount}${loc.warningCount > 0 ? ' • 🟠 ${loc.warningCount}' : ''}',
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
                                      '$rCount racks • Monit: ${fl.monitoredCount} (🟢${fl.onlineCount} 🔴${fl.offlineCount})',
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

          // 2. BARRA DE CONTROLES DE LA VISTA DE PLANTA (Escala del Plano, Ayuda interactiva)
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
                    Icons.info_outline,
                    size: 16,
                    color: Color(0xFF2563EB),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Vista de Planta: Arrastra cada Rack para colocarlo en su sitio • Estira su esquina inferior derecha (◢) para dimensionarlo • Pulsa ↻ para rotar su frontal • Haz clic en el Rack para abrir su editor de 42U.',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: Color(0xFF334155),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Tamaño/Escala del Plano:',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF475569),
                    ),
                  ),
                  SizedBox(
                    width: 140,
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

          // 3. LIENZO DE LA VISTA DE PLANTA 2D DEL EDIFICIO (CON PLANO JPG/PNG/GIF Y RACKS ARRASTRABLES/DIMENSIONABLES)
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

                          return Stack(
                            fit: StackFit.expand,
                            children: [
                              // A. Fondo: Cuadrícula técnica arquitectónica + Imagen del Plano subida (escalable)
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
                                      errorBuilder: (ctx, err, _) => Center(
                                        child: Text('Error cargando plano: $err'),
                                      ),
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

    final boxW = baseSize.width;
    final boxH = baseSize.height;
    final leftPx = (normPos.dx * canvasW).clamp(8.0, (canvasW - boxW - 8.0).clamp(8.0, canvasW));
    final topPx = (normPos.dy * canvasH).clamp(8.0, (canvasH - boxH - 8.0).clamp(8.0, canvasH));

    final isCold = rk.aisleType == 'cold';
    final frontStripColor = isCold
        ? const Color(0xFF0284C7)
        : const Color(0xFF2563EB);

    return Positioned(
      left: leftPx,
      top: topPx,
      width: boxW,
      height: boxH,
      child: GestureDetector(
        onTap: () => widget.onOpenRack(rk.id),
        onPanUpdate: (details) {
          setState(() {
            final cur = _rackPositions[rk.id] ?? normPos;
            final nextX = (cur.dx + details.delta.dx / canvasW).clamp(0.01, 0.92);
            final nextY = (cur.dy + details.delta.dy / canvasH).clamp(0.01, 0.90);
            _rackPositions[rk.id] = Offset(nextX, nextY);
          });
        },
        onPanEnd: (_) => _saveRackGeometry(rk.id),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: const Color(0xFF38BDF8),
              width: 1.8,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33000000),
                blurRadius: 8,
                offset: Offset(0, 3),
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
                        'Monit:${rk.monitoredCount} 🟢${rk.onlineCount} 🔴${rk.offlineCount}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 8.5,
                          fontWeight: FontWeight.w800,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
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
