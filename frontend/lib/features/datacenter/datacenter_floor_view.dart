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

  // Estado para Dispositivos de Planta (Cámaras, Control de Acceso, PCs, Rosetas, APs...)
  final Map<int, Offset> _floorDevicePositions = {};
  int? _selectedFloorDeviceId;
  bool _showLeftLibrary = true;
  bool _showRightSettings = true;
  bool _showFloorCables = true;
  String _deviceLibrarySearch = '';

  // Controladores del panel derecho de Settings para el dispositivo seleccionado
  int? _editingDeviceId;
  final TextEditingController _devCodeCtrl = TextEditingController();
  final TextEditingController _devNameCtrl = TextEditingController();
  final TextEditingController _devRoomCodeCtrl = TextEditingController();
  final TextEditingController _devIpCtrl = TextEditingController();
  final TextEditingController _devVlanCtrl = TextEditingController();
  final TextEditingController _devRackPortCtrl = TextEditingController();
  final TextEditingController _devRespCtrl = TextEditingController();
  final TextEditingController _devContactFirstCtrl = TextEditingController();
  final TextEditingController _devContactLastCtrl = TextEditingController();
  final TextEditingController _devContactEmailCtrl = TextEditingController();
  final TextEditingController _devContactPhoneCtrl = TextEditingController();
  final TextEditingController _devContactJobCtrl = TextEditingController();
  final TextEditingController _devContactDeptCtrl = TextEditingController();
  final TextEditingController _devNotesCtrl = TextEditingController();
  int? _devLinkedRackId;
  int? _devLinkedOutletId;
  String _devStatus = 'online';

  static const List<_FloorDeviceCatalogItem> _floorDeviceCatalog = [
    _FloorDeviceCatalogItem(
      category: '3d_printer',
      label: '3D Printer',
      prefix: '3DP',
      icon: Icons.view_in_ar_rounded,
    ),
    _FloorDeviceCatalogItem(
      category: 'access_control',
      label: 'Access Control Panel',
      prefix: 'AC',
      icon: Icons.dialpad_rounded,
    ),
    _FloorDeviceCatalogItem(
      category: 'access_point',
      label: 'Access Point',
      prefix: 'AP',
      icon: Icons.wifi_tethering_rounded,
    ),
    _FloorDeviceCatalogItem(
      category: 'camera',
      label: 'Camera',
      prefix: 'CAM',
      icon: Icons.videocam_outlined,
    ),
    _FloorDeviceCatalogItem(
      category: 'desktop',
      label: 'Desktop',
      prefix: 'DP',
      icon: Icons.desktop_windows_outlined,
    ),
    _FloorDeviceCatalogItem(
      category: 'isp_uplink',
      label: 'ISP Uplink',
      prefix: 'ISP',
      icon: Icons.public_rounded,
    ),
    _FloorDeviceCatalogItem(
      category: 'laptop',
      label: 'Laptop',
      prefix: 'LP',
      icon: Icons.laptop_mac_outlined,
    ),
    _FloorDeviceCatalogItem(
      category: 'microphone',
      label: 'Microphone',
      prefix: 'MIC',
      icon: Icons.mic_none_rounded,
    ),
    _FloorDeviceCatalogItem(
      category: 'ndi_box',
      label: 'NDI Box',
      prefix: 'NDI',
      icon: Icons.cast_connected_rounded,
    ),
    _FloorDeviceCatalogItem(
      category: 'phone',
      label: 'Phone',
      prefix: 'PH',
      icon: Icons.phone_in_talk_outlined,
    ),
    _FloorDeviceCatalogItem(
      category: 'printer',
      label: 'Printer',
      prefix: 'PR',
      icon: Icons.print_outlined,
    ),
    _FloorDeviceCatalogItem(
      category: 'rack',
      label: 'Rack',
      prefix: 'RK',
      icon: Icons.dns_outlined,
    ),
    _FloorDeviceCatalogItem(
      category: 'screen',
      label: 'Screen',
      prefix: 'SC',
      icon: Icons.tv_rounded,
    ),
    _FloorDeviceCatalogItem(
      category: 'speaker',
      label: 'Speaker',
      prefix: 'SPK',
      icon: Icons.speaker_outlined,
    ),
    _FloorDeviceCatalogItem(
      category: 'telecom_outlet',
      label: 'Telecommunications Outlet',
      prefix: 'Bi',
      icon: Icons.settings_input_hdmi_outlined,
    ),
  ];

  static _FloorDeviceCatalogItem _catalogItemFor(String category) {
    for (final item in _floorDeviceCatalog) {
      if (item.category == category) return item;
    }
    return _floorDeviceCatalog[4]; // Desktop fallback
  }

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
    if (widget.initialFloorId != null &&
        widget.initialFloorId != oldWidget.initialFloorId) {
      _selectedFloorId = widget.initialFloorId;
    } else if (widget.activeLocationId != oldWidget.activeLocationId) {
      _selectedFloorId = widget.initialFloorId;
    }
    _syncFloorState();
  }

  @override
  void dispose() {
    _devCodeCtrl.dispose();
    _devNameCtrl.dispose();
    _devRoomCodeCtrl.dispose();
    _devIpCtrl.dispose();
    _devVlanCtrl.dispose();
    _devRackPortCtrl.dispose();
    _devRespCtrl.dispose();
    _devContactFirstCtrl.dispose();
    _devContactLastCtrl.dispose();
    _devContactEmailCtrl.dispose();
    _devContactPhoneCtrl.dispose();
    _devContactJobCtrl.dispose();
    _devContactDeptCtrl.dispose();
    _devNotesCtrl.dispose();
    super.dispose();
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

    int devIdx = 0;
    for (final fd in fl.floorDevices) {
      double nx = fd.posX;
      double ny = fd.posY;
      if (nx <= 0.01 || nx >= 0.96) {
        nx = (0.18 + (devIdx % 6) * 0.12).clamp(0.06, 0.92);
      }
      if (ny <= 0.01 || ny >= 0.96) {
        ny = (0.28 + (devIdx ~/ 6) * 0.16).clamp(0.08, 0.90);
      }
      _floorDevicePositions[fd.id] = Offset(nx, ny);
      devIdx++;
    }

    if (_selectedFloorDeviceId != null) {
      final matches = fl.floorDevices.where((d) => d.id == _selectedFloorDeviceId);
      if (matches.isEmpty) {
        _selectedFloorDeviceId = null;
        _editingDeviceId = null;
      } else {
        _loadFloorDeviceToControllers(matches.first);
      }
    }
  }

  void _selectFloorDevice(FloorDeviceNode dev) {
    setState(() {
      _selectedRackIds.clear();
      _selectedFloorDeviceId = dev.id;
      _showRightSettings = true;
      _loadFloorDeviceToControllers(dev, force: true);
    });
  }

  void _loadFloorDeviceToControllers(FloorDeviceNode dev, {bool force = false}) {
    if (!force && _editingDeviceId == dev.id) return;
    _editingDeviceId = dev.id;
    _devCodeCtrl.text = dev.code;
    _devNameCtrl.text = dev.name;
    _devRoomCodeCtrl.text = dev.roomCode;
    _devIpCtrl.text = dev.ipAddress;
    _devVlanCtrl.text = dev.vlan?.toString() ?? '';
    _devRackPortCtrl.text = dev.linkedRackPort;
    _devRespCtrl.text = dev.responsiblePerson;
    _devContactFirstCtrl.text = dev.contactFirstName;
    _devContactLastCtrl.text = dev.contactLastName;
    _devContactEmailCtrl.text = dev.contactEmail;
    _devContactPhoneCtrl.text = dev.contactPhone;
    _devContactJobCtrl.text = dev.contactJobTitle;
    _devContactDeptCtrl.text = dev.contactDepartment;
    _devNotesCtrl.text = dev.notes;
    _devLinkedRackId = dev.linkedRackId;
    _devLinkedOutletId = dev.linkedOutletId;
    _devStatus = dev.status.isEmpty ? 'online' : dev.status;
  }

  Future<void> _saveFloorDevicePosition(int deviceId) async {
    final pos = _floorDevicePositions[deviceId];
    if (pos == null) return;
    try {
      await widget.api.updateFloorDevice(deviceId, {
        'pos_x': double.parse(pos.dx.toStringAsFixed(4)),
        'pos_y': double.parse(pos.dy.toStringAsFixed(4)),
      });
      widget.onRefresh();
    } catch (_) {}
  }

  Future<void> _saveSelectedFloorDeviceSettings() async {
    final devId = _selectedFloorDeviceId;
    if (devId == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.api.updateFloorDevice(devId, {
        'code': _devCodeCtrl.text.trim(),
        'name': _devNameCtrl.text.trim(),
        'room_code': _devRoomCodeCtrl.text.trim(),
        'ip_address': _devIpCtrl.text.trim(),
        'vlan': int.tryParse(_devVlanCtrl.text.trim()),
        'status': _devStatus,
        'linked_rack_id': _devLinkedRackId ?? 0,
        'linked_rack_device_code': _devRackPortCtrl.text.trim(),
        'linked_outlet_id': _devLinkedOutletId ?? 0,
        'responsible_person': _devRespCtrl.text.trim(),
        'contact_first_name': _devContactFirstCtrl.text.trim(),
        'contact_last_name': _devContactLastCtrl.text.trim(),
        'contact_email': _devContactEmailCtrl.text.trim(),
        'contact_phone': _devContactPhoneCtrl.text.trim(),
        'contact_job_title': _devContactJobCtrl.text.trim(),
        'contact_department': _devContactDeptCtrl.text.trim(),
        'notes': _devNotesCtrl.text.trim(),
      });
      widget.onRefresh();
      messenger.showSnackBar(
        SnackBar(
          content: Text('Ajustes de "${_devCodeCtrl.text.trim()}" guardados.'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('Error al guardar dispositivo: $e'),
          backgroundColor: Colors.red.shade700,
        ),
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

    final catItem = _catalogItemFor(category);
    final autoCode = _nextAutoCodeForCategory(floor, category);

    // Buscamos un rack o roseta por defecto en esta planta para pre-conectar
    int? defaultRackId;
    for (final rm in floor.rooms) {
      if (rm.racks.isNotEmpty) {
        defaultRackId = rm.racks.first.id;
        break;
      }
    }

    int? defaultOutletId;
    const outletLinkedCategories = {
      'desktop',
      'laptop',
      'phone',
      'printer',
      '3d_printer',
      'screen',
      'speaker',
      'microphone',
      'ndi_box',
    };
    if (outletLinkedCategories.contains(category)) {
      // Buscar la roseta más cercana en el plano
      double bestDist = 999.0;
      for (final fd in floor.floorDevices) {
        if (fd.category == 'telecom_outlet') {
          final dx = fd.posX - normX;
          final dy = fd.posY - normY;
          final dist = dx * dx + dy * dy;
          if (dist < bestDist) {
            bestDist = dist;
            defaultOutletId = fd.id;
          }
        }
      }
    }

    try {
      final res = await widget.api.createFloorDevice(floor.id, {
        'device_type': category,
        'code': autoCode,
        'name': '${catItem.label} $autoCode',
        'room_code': floor.rooms.isNotEmpty ? floor.rooms.first.name : 'GOA',
        'pos_x': double.parse(normX.clamp(0.04, 0.94).toStringAsFixed(4)),
        'pos_y': double.parse(normY.clamp(0.06, 0.92).toStringAsFixed(4)),
        'status': 'online',
        'linked_rack_id':
            defaultOutletId == null ? defaultRackId : null,
        'linked_rack_device_code':
            defaultOutletId == null && defaultRackId != null ? 'SW01:Gi1/0/1' : '',
        'linked_outlet_id': defaultOutletId,
        'responsible_person': 'Alex Geng',
      });
      final newId = (res['id'] as num?)?.toInt();
      if (newId != null) {
        setState(() {
          _selectedRackIds.clear();
          _selectedFloorDeviceId = newId;
          _editingDeviceId = null;
          _showRightSettings = true;
        });
      }
      widget.onRefresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error al colocar dispositivo: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    }
  }

  Future<void> _showAddFloorDeviceModal(
    FloorNode floor, {
    String initialCategory = 'camera',
  }) async {
    String selectedCat = initialCategory == 'rack' ? 'camera' : initialCategory;
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
    final portCtrl = TextEditingController(text: 'PP-A:01');
    final respCtrl = TextEditingController(text: 'Alex Geng');

    final floorRacks = <RackSummary>[];
    for (final rm in floor.rooms) {
      floorRacks.addAll(rm.racks);
    }
    final floorOutlets = floor.floorDevices
        .where((d) => d.category == 'telecom_outlet')
        .toList();

    int? linkedRackId = floorRacks.isNotEmpty ? floorRacks.first.id : null;
    int? linkedOutletId;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: Row(
            children: [
              Icon(
                _catalogItemFor(selectedCat).icon,
                color: const Color(0xFF1E3A8A),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Añadir Dispositivo / Toma en ${floor.name}',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: selectedCat,
                    decoration: const InputDecoration(
                      labelText: 'Categoría del Dispositivo (Devices Library)',
                    ),
                    items: _floorDeviceCatalog
                        .where((c) => c.category != 'rack')
                        .map(
                          (c) => DropdownMenuItem<String>(
                            value: c.category,
                            child: Row(
                              children: [
                                Icon(c.icon, size: 17, color: const Color(0xFF1E293B)),
                                const SizedBox(width: 8),
                                Text(c.label),
                              ],
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (v) {
                      if (v == null) return;
                      setModal(() {
                        selectedCat = v;
                        final auto = _nextAutoCodeForCategory(floor, selectedCat);
                        codeCtrl.text = auto;
                        nameCtrl.text = '${_catalogItemFor(selectedCat).label} $auto';
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
                            labelText: 'ID / Código * (ej. CAM01, DP01, Bi01...)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: nameCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Nombre Descriptivo',
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
                            labelText: 'Sala / Zona (ej. GOA, OSLO, VIENNA)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: ipCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Dirección IP (opcional)',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<int?>(
                    initialValue: linkedRackId,
                    decoration: const InputDecoration(
                      labelText: 'Conectado a Rack (Línea Naranja Discontinua)',
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
                    onChanged: (v) => setModal(() => linkedRackId = v),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: portCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Puerto en Rack (ej. PP-A:01 / SW01:Gi1/0/5)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: respCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Persona Responsable',
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (selectedCat != 'telecom_outlet' &&
                      floorOutlets.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    DropdownButtonFormField<int?>(
                      initialValue: linkedOutletId,
                      decoration: const InputDecoration(
                        labelText:
                            'Conectado a Roseta / Telecommunications Outlet (Línea Azul)',
                      ),
                      items: [
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: Text('Sin roseta intermedia'),
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
              label: const Text('Añadir al Plano'),
            ),
          ],
        ),
      ),
    );

    if (ok == true) {
      final count = floor.floorDevices.length;
      final normX = (0.20 + (count % 5) * 0.14).clamp(0.10, 0.86);
      final normY = (0.30 + (count ~/ 5) * 0.15).clamp(0.14, 0.86);
      final res = await widget.api.createFloorDevice(floor.id, {
        'device_type': selectedCat,
        'code': codeCtrl.text.trim(),
        'name': nameCtrl.text.trim(),
        'room_code': roomCtrl.text.trim(),
        'ip_address': ipCtrl.text.trim(),
        'pos_x': normX,
        'pos_y': normY,
        'status': 'online',
        'linked_rack_id': linkedRackId,
        'linked_rack_device_code': portCtrl.text.trim(),
        'linked_outlet_id': linkedOutletId,
        'responsible_person': respCtrl.text.trim(),
      });
      final newId = (res['id'] as num?)?.toInt();
      if (newId != null) {
        setState(() {
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
              backgroundColor: const Color(0xFFDC2626),
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
        setState(() {
          _floorDevicePositions.remove(dev.id);
          if (_selectedFloorDeviceId == dev.id) {
            _selectedFloorDeviceId = null;
            _editingDeviceId = null;
          }
        });
        widget.onRefresh();
        messenger.showSnackBar(
          SnackBar(content: Text('Dispositivo "${dev.code}" eliminado.')),
        );
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Error al eliminar dispositivo: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
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
                      OutlinedButton.icon(
                        onPressed: () => _showDrawNewRackDialog(floor),
                        icon: const Icon(Icons.dns_outlined, size: 16),
                        label: const Text('+ Rack'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF1E3A8A),
                          side: const BorderSide(color: Color(0xFF93C5FD)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: () => _showAddFloorDeviceModal(floor),
                        icon: const Icon(Icons.add_location_alt_outlined, size: 17),
                        label: const Text('+ Device'),
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF2563EB),
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
                        final dCount = fl.floorDevices.length;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8, bottom: 8),
                          child: InkWell(
                            onTap: () {
                              setState(() {
                                _selectedFloorId = fl.id;
                                _selectedFloorDeviceId = null;
                                _editingDeviceId = null;
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
                                        if (dCount > 0) '$dCount disp.',
                                        if (fl.monitoredCount > 0)
                                          'Monit: ${fl.monitoredCount}',
                                        if (fl.onlineCount > 0)
                                          '🟢${fl.onlineCount}',
                                        if (fl.offlineCount > 0)
                                          '🔴${fl.offlineCount}',
                                      ].join(' • '),
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

          // 2. BARRA DE CONTROLES DE LA VISTA DE PLANTA (Paneles, Cableado de Planta, Escala y Selección)
          if (floor != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: const BoxDecoration(
                color: Color(0xFFF8FAFC),
                border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
              ),
              child: Row(
                children: [
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      backgroundColor: _showLeftLibrary
                          ? const Color(0xFFEFF6FF)
                          : Colors.white,
                      side: BorderSide(
                        color: _showLeftLibrary
                            ? const Color(0xFF3B82F6)
                            : const Color(0xFFCBD5E1),
                      ),
                    ),
                    onPressed: () =>
                        setState(() => _showLeftLibrary = !_showLeftLibrary),
                    icon: const Icon(Icons.widgets_outlined, size: 15),
                    label: Text(
                      _showLeftLibrary
                          ? 'Devices Library: ON'
                          : 'Devices Library: OFF',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      backgroundColor: _showFloorCables
                          ? const Color(0xFFFFFBEB)
                          : Colors.white,
                      side: BorderSide(
                        color: _showFloorCables
                            ? const Color(0xFFF59E0B)
                            : const Color(0xFFCBD5E1),
                      ),
                    ),
                    onPressed: () =>
                        setState(() => _showFloorCables = !_showFloorCables),
                    icon: Icon(
                      Icons.timeline_rounded,
                      size: 15,
                      color: _showFloorCables
                          ? const Color(0xFFD97706)
                          : const Color(0xFF64748B),
                    ),
                    label: Text(
                      _showFloorCables
                          ? 'Cableado Estructurado: ON (${floor.floorDevices.length} disp.)'
                          : 'Cableado Estructurado: OFF',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: _showFloorCables
                            ? const Color(0xFFB45309)
                            : const Color(0xFF475569),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Arrastra equipos desde DEVICES LIBRARY al plano  •  1 Clic: Ver Settings  •  Doble Clic en Rack: Abrir en 3. Rack Editor',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(0xFF334155),
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (floorRacks.isNotEmpty) ...[
                    TextButton.icon(
                      onPressed: () {
                        setState(() {
                          _selectedFloorDeviceId = null;
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
                            ? 'Deseleccionar Racks'
                            : 'Sel. Racks (${floorRacks.length})',
                        style: const TextStyle(fontSize: 11),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  const Text(
                    'Escala:',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF475569),
                    ),
                  ),
                  SizedBox(
                    width: 110,
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
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      backgroundColor: _showRightSettings
                          ? const Color(0xFFEFF6FF)
                          : Colors.white,
                      side: BorderSide(
                        color: _showRightSettings
                            ? const Color(0xFF3B82F6)
                            : const Color(0xFFCBD5E1),
                      ),
                    ),
                    onPressed: () =>
                        setState(() => _showRightSettings = !_showRightSettings),
                    icon: const Icon(Icons.tune_rounded, size: 15),
                    label: const Text(
                      'Settings',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // 3. ÁREA PRINCIPAL: [DEVICES LIBRARY (Izq)] + [LIENZO DE PLANTA 2D (Centro)] + [SETTINGS (Der)]
          Expanded(
            child: floor == null
                ? const Center(child: Text('Crea una planta para empezar.'))
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // COLUMNA IZQUIERDA: DEVICES LIBRARY
                      if (_showLeftLibrary)
                        _buildLeftDevicesLibraryPanel(floor),

                      // COLUMNA CENTRAL: LIENZO INTERACTIVO DE PLANTA 2D CON DRAG TARGET Y CABLEADO
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: const Color(0xFFCBD5E1),
                              ),
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

                                return DragTarget<String>(
                                  onWillAcceptWithDetails: (_) => true,
                                  onAcceptWithDetails: (details) {
                                    final renderBox = context.findRenderObject()
                                        as RenderBox?;
                                    if (renderBox == null) return;
                                    final localPos = renderBox.globalToLocal(
                                      details.offset,
                                    );
                                    final normX = (localPos.dx / canvasW).clamp(
                                      0.04,
                                      0.94,
                                    );
                                    final normY = (localPos.dy / canvasH).clamp(
                                      0.06,
                                      0.92,
                                    );
                                    _dropNewDeviceFromLibrary(
                                      floor: floor,
                                      category: details.data,
                                      normX: normX,
                                      normY: normY,
                                    );
                                  },
                                  builder: (context, candidateData, _) {
                                    final isDraggingNew =
                                        candidateData.isNotEmpty;
                                    return Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        // A. Fondo interactivo: clic en vacío limpia selección, arrastrar dibuja caja de selección (Marquee)
                                        GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () {
                                            setState(() {
                                              if (!_isShiftPressed) {
                                                _selectedRackIds.clear();
                                              }
                                              _selectedFloorDeviceId = null;
                                              _editingDeviceId = null;
                                            });
                                          },
                                          onPanStart: (details) {
                                            setState(() {
                                              if (!_isShiftPressed) {
                                                _selectedRackIds.clear();
                                              }
                                              _selectedFloorDeviceId = null;
                                              _editingDeviceId = null;
                                              _marqueeStart =
                                                  details.localPosition;
                                              _marqueeCurrent =
                                                  details.localPosition;
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
                                                final normPos =
                                                    _rackPositions[rk.id] ??
                                                        const Offset(
                                                          0.25,
                                                          0.35,
                                                        );
                                                final sz = _rackSizes[rk.id] ??
                                                    const Size(120.0, 90.0);
                                                final leftPx =
                                                    (normPos.dx * canvasW).clamp(
                                                  8.0,
                                                  (canvasW - sz.width - 8.0)
                                                      .clamp(8.0, canvasW),
                                                );
                                                final topPx =
                                                    (normPos.dy * canvasH).clamp(
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
                                                painter:
                                                    _ArchitecturalGridPainter(),
                                              ),
                                              if (floorImageUrl.isNotEmpty)
                                                Center(
                                                  child: Transform.scale(
                                                    scale: _floorImageScale,
                                                    child: Image.network(
                                                      floorImageUrl,
                                                      fit: BoxFit.contain,
                                                      errorBuilder:
                                                          (ctx, err, _) {
                                                        WidgetsBinding.instance
                                                            .addPostFrameCallback(
                                                                (_) {
                                                          if (mounted &&
                                                              !_floorPlanLoadError) {
                                                            setState(
                                                              () =>
                                                                  _floorPlanLoadError =
                                                                      true,
                                                            );
                                                          }
                                                        });
                                                        return const SizedBox
                                                            .shrink();
                                                      },
                                                    ),
                                                  ),
                                                ),
                                              // A2. Líneas de Cableado Estructurado en Planta (Rack -> Roseta/ Cámara/AP y Roseta -> PC/Teléfono)
                                              if (_showFloorCables)
                                                IgnorePointer(
                                                  child: CustomPaint(
                                                    painter:
                                                        _FloorConnectionsPainter(
                                                      racks: floorRacks,
                                                      rackPositions:
                                                          _rackPositions,
                                                      rackSizes: _rackSizes,
                                                      floorDevices:
                                                          floor.floorDevices,
                                                      devicePositions:
                                                          _floorDevicePositions,
                                                      selectedDeviceId:
                                                          _selectedFloorDeviceId,
                                                      selectedRackIds:
                                                          _selectedRackIds,
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),

                                        if (isDraggingNew)
                                          IgnorePointer(
                                            child: Container(
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF2563EB)
                                                    .withValues(alpha: 0.06),
                                                border: Border.all(
                                                  color:
                                                      const Color(0xFF2563EB),
                                                  width: 2.5,
                                                ),
                                              ),
                                              alignment: Alignment.topCenter,
                                              padding: const EdgeInsets.only(
                                                top: 14,
                                              ),
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 14,
                                                  vertical: 6,
                                                ),
                                                decoration: BoxDecoration(
                                                  color:
                                                      const Color(0xFF1E3A8A),
                                                  borderRadius:
                                                      BorderRadius.circular(20),
                                                ),
                                                child: const Text(
                                                  'Suelta aquí para colocar el dispositivo en la planta',
                                                  style: TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.bold,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),

                                        if (_floorPlanLoadError &&
                                            floorImageUrl.isNotEmpty)
                                          Positioned(
                                            bottom: 14,
                                            left: 14,
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 14,
                                                vertical: 10,
                                              ),
                                              decoration: BoxDecoration(
                                                color: Colors.white,
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                                border: Border.all(
                                                  color:
                                                      const Color(0xFFFCD34D),
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
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color: Color(0xFF334155),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 12),
                                                  FilledButton.tonalIcon(
                                                    onPressed: () async {
                                                      setState(
                                                        () =>
                                                            _floorPlanLoadError =
                                                                false,
                                                      );
                                                      await _uploadFloorBlueprint(
                                                        floor,
                                                      );
                                                    },
                                                    icon: const Icon(
                                                      Icons
                                                          .upload_file_outlined,
                                                      size: 15,
                                                    ),
                                                    label: const Text(
                                                      'Subir Nuevo Plano',
                                                      style: TextStyle(
                                                        fontSize: 11.5,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 6),
                                                  TextButton(
                                                    onPressed: () async {
                                                      setState(
                                                        () =>
                                                            _floorPlanLoadError =
                                                                false,
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
                                                      style: TextStyle(
                                                        fontSize: 11.5,
                                                      ),
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

                                        // B2. Pines de Dispositivos de Planta (Cámaras, Rosetas Bi01, PCs, Control de Acceso, APs...)
                                        for (final dev in floor.floorDevices)
                                          _buildFloorDevicePin(
                                            dev: dev,
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
                                                    color:
                                                        const Color(0xFF2563EB),
                                                    width: 1.8,
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                ),
                                              ),
                                            ),
                                          ),

                                        // D. Leyenda inferior de Cableado de Planta
                                        if (_showFloorCables &&
                                            floor.floorDevices.isNotEmpty)
                                          Positioned(
                                            bottom: 10,
                                            right: 12,
                                            child: IgnorePointer(
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 10,
                                                  vertical: 6,
                                                ),
                                                decoration: BoxDecoration(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.92),
                                                  borderRadius:
                                                      BorderRadius.circular(8),
                                                  border: Border.all(
                                                    color:
                                                        const Color(0xFFCBD5E1),
                                                  ),
                                                ),
                                                child: const Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Icon(
                                                      Icons.horizontal_rule,
                                                      size: 16,
                                                      color: Color(0xFFF59E0B),
                                                    ),
                                                    SizedBox(width: 4),
                                                    Text(
                                                      'Troncal Rack → Roseta / Cámara / AP',
                                                      style: TextStyle(
                                                        fontSize: 10,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        color:
                                                            Color(0xFF334155),
                                                      ),
                                                    ),
                                                    SizedBox(width: 12),
                                                    Icon(
                                                      Icons.horizontal_rule,
                                                      size: 16,
                                                      color: Color(0xFF2563EB),
                                                    ),
                                                    SizedBox(width: 4),
                                                    Text(
                                                      'Latiguillo Roseta → Puesto (PC/Tel/Impr)',
                                                      style: TextStyle(
                                                        fontSize: 10,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        color:
                                                            Color(0xFF334155),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),

                                        // E. Barra Flotante de Colocación/Alineación cuando hay Racks seleccionados
                                        if (_selectedRackIds.isNotEmpty)
                                          Positioned(
                                            top: 12,
                                            left: 16,
                                            right: 16,
                                            child: Center(
                                              child: Material(
                                                elevation: 6,
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                                color: const Color(0xFF0F172A),
                                                child: Padding(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                    horizontal: 14,
                                                    vertical: 8,
                                                  ),
                                                  child: Wrap(
                                                    crossAxisAlignment:
                                                        WrapCrossAlignment
                                                            .center,
                                                    spacing: 8,
                                                    runSpacing: 6,
                                                    children: [
                                                      Container(
                                                        padding:
                                                            const EdgeInsets
                                                                .symmetric(
                                                          horizontal: 8,
                                                          vertical: 3,
                                                        ),
                                                        decoration:
                                                            BoxDecoration(
                                                          color: const Color(
                                                            0xFF2563EB,
                                                          ),
                                                          borderRadius:
                                                              BorderRadius
                                                                  .circular(12),
                                                        ),
                                                        child: Text(
                                                          '${_selectedRackIds.length} ${_selectedRackIds.length == 1 ? 'Rack seleccionado' : 'Racks seleccionados'}',
                                                          style:
                                                              const TextStyle(
                                                            color: Colors.white,
                                                            fontSize: 11,
                                                            fontWeight:
                                                                FontWeight.w800,
                                                          ),
                                                        ),
                                                      ),
                                                      if (_selectedRackIds
                                                              .length ==
                                                          1)
                                                        FilledButton.icon(
                                                          style: FilledButton
                                                              .styleFrom(
                                                            backgroundColor:
                                                                const Color(
                                                              0xFF10B981,
                                                            ),
                                                            visualDensity:
                                                                VisualDensity
                                                                    .compact,
                                                          ),
                                                          onPressed: () =>
                                                              widget.onOpenRack(
                                                            _selectedRackIds
                                                                .first,
                                                          ),
                                                          icon: const Icon(
                                                            Icons.open_in_new,
                                                            size: 14,
                                                          ),
                                                          label: const Text(
                                                            'Abrir en Rack Editor (Doble Clic)',
                                                            style: TextStyle(
                                                              fontSize: 11,
                                                            ),
                                                          ),
                                                        ),
                                                      if (_selectedRackIds
                                                              .length >=
                                                          2) ...[
                                                        OutlinedButton.icon(
                                                          style: OutlinedButton
                                                              .styleFrom(
                                                            foregroundColor:
                                                                Colors.white,
                                                            side:
                                                                const BorderSide(
                                                              color: Color(
                                                                0xFF475569,
                                                              ),
                                                            ),
                                                            visualDensity:
                                                                VisualDensity
                                                                    .compact,
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
                                                            style: TextStyle(
                                                              fontSize: 11,
                                                            ),
                                                          ),
                                                        ),
                                                        OutlinedButton.icon(
                                                          style: OutlinedButton
                                                              .styleFrom(
                                                            foregroundColor:
                                                                Colors.white,
                                                            side:
                                                                const BorderSide(
                                                              color: Color(
                                                                0xFF475569,
                                                              ),
                                                            ),
                                                            visualDensity:
                                                                VisualDensity
                                                                    .compact,
                                                          ),
                                                          onPressed: () =>
                                                              _alignSelectedRacksHorizontally(
                                                            canvasW: canvasW,
                                                            packTightly: true,
                                                          ),
                                                          icon: const Icon(
                                                            Icons
                                                                .view_column_outlined,
                                                            size: 14,
                                                          ),
                                                          label: const Text(
                                                            'Juntar en Fila (Pasillo)',
                                                            style: TextStyle(
                                                              fontSize: 11,
                                                            ),
                                                          ),
                                                        ),
                                                        OutlinedButton.icon(
                                                          style: OutlinedButton
                                                              .styleFrom(
                                                            foregroundColor:
                                                                Colors.white,
                                                            side:
                                                                const BorderSide(
                                                              color: Color(
                                                                0xFF475569,
                                                              ),
                                                            ),
                                                            visualDensity:
                                                                VisualDensity
                                                                    .compact,
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
                                                            style: TextStyle(
                                                              fontSize: 11,
                                                            ),
                                                          ),
                                                        ),
                                                        OutlinedButton.icon(
                                                          style: OutlinedButton
                                                              .styleFrom(
                                                            foregroundColor:
                                                                Colors.white,
                                                            side:
                                                                const BorderSide(
                                                              color: Color(
                                                                0xFF475569,
                                                              ),
                                                            ),
                                                            visualDensity:
                                                                VisualDensity
                                                                    .compact,
                                                          ),
                                                          onPressed: () =>
                                                              _alignSelectedRacksVertically(
                                                            canvasH: canvasH,
                                                            packTightly: true,
                                                          ),
                                                          icon: const Icon(
                                                            Icons
                                                                .table_rows_outlined,
                                                            size: 14,
                                                          ),
                                                          label: const Text(
                                                            'Juntar en Columna',
                                                            style: TextStyle(
                                                              fontSize: 11,
                                                            ),
                                                          ),
                                                        ),
                                                        OutlinedButton.icon(
                                                          style: OutlinedButton
                                                              .styleFrom(
                                                            foregroundColor:
                                                                Colors.white,
                                                            side:
                                                                const BorderSide(
                                                              color: Color(
                                                                0xFF475569,
                                                              ),
                                                            ),
                                                            visualDensity:
                                                                VisualDensity
                                                                    .compact,
                                                          ),
                                                          onPressed:
                                                              _equalizeSelectedRacksSize,
                                                          icon: const Icon(
                                                            Icons.aspect_ratio,
                                                            size: 14,
                                                          ),
                                                          label: const Text(
                                                            'Igualar Tamaño',
                                                            style: TextStyle(
                                                              fontSize: 11,
                                                            ),
                                                          ),
                                                        ),
                                                      ],
                                                      IconButton(
                                                        onPressed: () =>
                                                            setState(
                                                          () => _selectedRackIds
                                                              .clear(),
                                                        ),
                                                        icon: const Icon(
                                                          Icons.close,
                                                          size: 16,
                                                          color: Colors.white70,
                                                        ),
                                                        tooltip:
                                                            'Limpiar selección',
                                                        visualDensity:
                                                            VisualDensity
                                                                .compact,
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
                                );
                              },
                            ),
                          ),
                        ),
                      ),

                      // COLUMNA DERECHA: PANEL DE SETTINGS (Dispositivo o Rack seleccionado)
                      if (_showRightSettings)
                        _buildRightSettingsPanel(floor, floorRacks),
                    ],
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
              _selectedFloorDeviceId = null;
              _editingDeviceId = null;
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
            setState(() {
              _selectedFloorDeviceId = null;
              _editingDeviceId = null;
              if (!_selectedRackIds.contains(rk.id)) {
                if (!_isShiftPressed) {
                  _selectedRackIds.clear();
                }
                _selectedRackIds.add(rk.id);
              }
            });
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

  // ===========================================================================
  // COLUMNA IZQUIERDA: DEVICES LIBRARY (Arrastrar o pulsar '+' para añadir)
  // ===========================================================================
  Widget _buildLeftDevicesLibraryPanel(FloorNode floor) {
    final query = _deviceLibrarySearch.trim().toLowerCase();
    final filteredCatalog = _floorDeviceCatalog.where((item) {
      if (query.isEmpty) return true;
      return item.label.toLowerCase().contains(query) ||
          item.category.toLowerCase().contains(query) ||
          item.prefix.toLowerCase().contains(query);
    }).toList();

    return Container(
      width: 245,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(right: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 6),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'DEVICES LIBRARY',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.6,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => setState(() => _showLeftLibrary = false),
                  icon: const Icon(
                    Icons.keyboard_double_arrow_left_rounded,
                    size: 18,
                    color: Color(0xFF64748B),
                  ),
                  tooltip: 'Ocultar Devices Library',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14),
            child: Text(
              'Drag device to a room to add it',
              style: TextStyle(
                fontSize: 11,
                color: Color(0xFF64748B),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: SizedBox(
              height: 32,
              child: TextField(
                onChanged: (v) => setState(() => _deviceLibrarySearch = v),
                style: const TextStyle(fontSize: 12),
                decoration: InputDecoration(
                  hintText: 'Search...',
                  hintStyle: const TextStyle(
                    fontSize: 11.5,
                    color: Color(0xFF94A3B8),
                  ),
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    size: 16,
                    color: Color(0xFF94A3B8),
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  filled: true,
                  fillColor: const Color(0xFFF8FAFC),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                  ),
                ),
              ),
            ),
          ),
          const Divider(height: 1, color: Color(0xFFE2E8F0)),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
              itemCount: filteredCatalog.length,
              separatorBuilder: (_, _) => const SizedBox(height: 2),
              itemBuilder: (ctx, i) {
                final item = filteredCatalog[i];
                final countInFloor = item.category == 'rack'
                    ? floor.rooms.fold<int>(0, (s, r) => s + r.racks.length)
                    : floor.floorDevices
                        .where((d) => d.category == item.category)
                        .length;
                final tileContent = Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: const Color(0xFFF1F5F9)),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: item.category == 'telecom_outlet'
                              ? const Color(0xFFF1F5F9)
                              : const Color(0xFFEFF6FF),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Icon(
                          item.icon,
                          size: 15,
                          color: item.category == 'telecom_outlet'
                              ? const Color(0xFF475569)
                              : const Color(0xFF1E3A8A),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          item.label,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1E293B),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (countInFloor > 0)
                        Container(
                          margin: const EdgeInsets.only(right: 4),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '$countInFloor',
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF64748B),
                            ),
                          ),
                        ),
                      InkWell(
                        onTap: () {
                          if (item.category == 'rack') {
                            _showDrawNewRackDialog(floor);
                          } else {
                            _showAddFloorDeviceModal(
                              floor,
                              initialCategory: item.category,
                            );
                          }
                        },
                        borderRadius: BorderRadius.circular(4),
                        child: const Tooltip(
                          message: 'Añadir al plano',
                          child: Padding(
                            padding: EdgeInsets.all(2),
                            child: Icon(
                              Icons.add_circle_outline_rounded,
                              size: 16,
                              color: Color(0xFF2563EB),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );

                return Draggable<String>(
                  data: item.category,
                  feedback: Material(
                    elevation: 8,
                    borderRadius: BorderRadius.circular(20),
                    color: const Color(0xFF0F172A),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(item.icon, size: 16, color: Colors.white),
                          const SizedBox(width: 8),
                          Text(
                            item.label,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  childWhenDragging: Opacity(
                    opacity: 0.45,
                    child: tileContent,
                  ),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: tileContent,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // PIN DE GOTA (TEARDROP PIN) EN EL PLANO 2D PARA CADA DISPOSITIVO / ROSETA
  // ===========================================================================
  Widget _buildFloorDevicePin({
    required FloorDeviceNode dev,
    required double canvasW,
    required double canvasH,
  }) {
    final normPos = _floorDevicePositions[dev.id] ?? Offset(dev.posX, dev.posY);
    final isSelected = _selectedFloorDeviceId == dev.id;
    final catItem = _catalogItemFor(dev.category);
    final isOutlet = dev.category == 'telecom_outlet';

    // Coordenadas de la punta del pin
    final centerX = (normPos.dx * canvasW).clamp(20.0, canvasW - 20.0);
    final centerY = (normPos.dy * canvasH).clamp(24.0, canvasH - 16.0);

    final Color pinBgColor = isSelected
        ? const Color(0xFF2563EB)
        : (isOutlet ? const Color(0xFF64748B) : const Color(0xFF0F172A));

    Color statusDotColor = const Color(0xFF22C55E);
    if (dev.status == 'offline') {
      statusDotColor = const Color(0xFFEF4444);
    } else if (dev.status == 'warning') {
      statusDotColor = const Color(0xFFF59E0B);
    }

    return Positioned(
      left: centerX - 16,
      top: centerY - 34,
      child: Tooltip(
        message: [
          '${dev.code} • ${dev.name}',
          if (dev.roomCode.isNotEmpty) 'Sala/Zona: ${dev.roomCode}',
          if (dev.ipAddress.isNotEmpty) 'IP: ${dev.ipAddress}',
          if (dev.linkedRackPort.isNotEmpty) 'Puerto Rack: ${dev.linkedRackPort}',
          if (dev.contactFirstName.isNotEmpty || dev.contactLastName.isNotEmpty)
            'Contacto: ${dev.contactFirstName} ${dev.contactLastName}',
          '• Clic: Abrir Settings  • Arrastrar: Mover en planta',
        ].join('\n'),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _selectFloorDevice(dev),
          onPanStart: (_) => _selectFloorDevice(dev),
          onPanUpdate: (details) {
            final dxNorm = details.delta.dx / canvasW;
            final dyNorm = details.delta.dy / canvasH;
            setState(() {
              final cur =
                  _floorDevicePositions[dev.id] ?? Offset(dev.posX, dev.posY);
              _floorDevicePositions[dev.id] = Offset(
                (cur.dx + dxNorm).clamp(0.02, 0.96),
                (cur.dy + dyNorm).clamp(0.04, 0.95),
              );
            });
          },
          onPanEnd: (_) => _saveFloorDevicePosition(dev.id),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Gota (Teardrop Marker) con icono blanco
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: pinBgColor,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isSelected
                              ? const Color(0xFFFACC15)
                              : Colors.white,
                          width: isSelected ? 2.4 : 1.6,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: isSelected
                                ? const Color(0x882563EB)
                                : const Color(0x38000000),
                            blurRadius: isSelected ? 10 : 5,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Icon(
                        catItem.icon,
                        size: 15,
                        color: Colors.white,
                      ),
                    ),
                    CustomPaint(
                      size: const Size(10, 6),
                      painter: _PinTailPainter(color: pinBgColor),
                    ),
                  ],
                ),
                const SizedBox(width: 3),
                // Etiqueta junto al pin (ej. CAM01, DP01, Bi01, Bi02...)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? const Color(0xFF1E3A8A)
                        : Colors.white.withValues(alpha: 0.94),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: isSelected
                          ? const Color(0xFFFACC15)
                          : const Color(0xFFCBD5E1),
                      width: isSelected ? 1.5 : 1.0,
                    ),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x18000000),
                        blurRadius: 4,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!isOutlet) ...[
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: statusDotColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
                      Text(
                        dev.code,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          color: isSelected
                              ? Colors.white
                              : (isOutlet
                                  ? const Color(0xFF475569)
                                  : const Color(0xFF0F172A)),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // COLUMNA DERECHA: SETTINGS PANEL (Igual a la captura de referencia)
  // ===========================================================================
  Widget _buildRightSettingsPanel(
    FloorNode floor,
    List<RackSummary> floorRacks,
  ) {
    FloorDeviceNode? selectedDev;
    if (_selectedFloorDeviceId != null) {
      for (final d in floor.floorDevices) {
        if (d.id == _selectedFloorDeviceId) {
          selectedDev = d;
          break;
        }
      }
    }

    RackSummary? selectedRack;
    if (selectedDev == null && _selectedRackIds.isNotEmpty) {
      final firstId = _selectedRackIds.first;
      for (final r in floorRacks) {
        if (r.id == firstId) {
          selectedRack = r;
          break;
        }
      }
    }

    final floorOutlets = floor.floorDevices
        .where((d) => d.category == 'telecom_outlet')
        .toList();

    return Container(
      width: 300,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(left: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Cabecera Settings
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
            ),
            child: Row(
              children: [
                if (selectedDev != null) ...[
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(
                      _catalogItemFor(selectedDev.category).icon,
                      size: 15,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          selectedDev.code,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF0F172A),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          _catalogItemFor(selectedDev.category).label,
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => _confirmDeleteFloorDevice(selectedDev!),
                    icon: const Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: Color(0xFFDC2626),
                    ),
                    tooltip: 'Eliminar dispositivo',
                    visualDensity: VisualDensity.compact,
                  ),
                ] else if (selectedRack != null) ...[
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E3A8A),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Icon(
                      Icons.dns_outlined,
                      size: 15,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          selectedRack.code,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                        const Text(
                          'Rack Cabinet',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: Color(0xFF64748B),
                          ),
                        ),
                      ],
                    ),
                  ),
                ] else ...[
                  const Icon(
                    Icons.tune_rounded,
                    size: 18,
                    color: Color(0xFF1E3A8A),
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Settings & Floor Inventory',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                  ),
                ],
                IconButton(
                  onPressed: () => setState(() => _showRightSettings = false),
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 18,
                    color: Color(0xFF64748B),
                  ),
                  tooltip: 'Cerrar panel Settings',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),

          // Cuerpo del panel derecho según selección
          Expanded(
            child: selectedDev != null
                ? _buildFloorDeviceSettingsForm(
                    selectedDev,
                    floorRacks,
                    floorOutlets,
                  )
                : (selectedRack != null
                    ? _buildSelectedRackSettingsSummary(floor, selectedRack)
                    : _buildFloorOverviewSettingsList(floor, floorRacks)),
          ),
        ],
      ),
    );
  }

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
                    color: Color(0xFF2563EB),
                  ),
                ),
                const SizedBox(height: 10),
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
                Row(
                  children: [
                    Expanded(
                      child: _buildCompactField(
                        label: 'IP Address',
                        controller: _devIpCtrl,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue:
                            const {'online', 'warning', 'offline'}.contains(
                                  _devStatus,
                                )
                                ? _devStatus
                                : 'online',
                        isDense: true,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF0F172A),
                        ),
                        decoration: _compactInputDecoration('Status'),
                        items: const [
                          DropdownMenuItem(
                            value: 'online',
                            child: Text('🟢 Online'),
                          ),
                          DropdownMenuItem(
                            value: 'warning',
                            child: Text('🟠 Warning'),
                          ),
                          DropdownMenuItem(
                            value: 'offline',
                            child: Text('🔴 Offline'),
                          ),
                        ],
                        onChanged: (v) {
                          if (v != null) setState(() => _devStatus = v);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Divider(height: 1, color: Color(0xFFE2E8F0)),
                const SizedBox(height: 10),
                const Text(
                  'Structured Cabling & Rack Link',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<int?>(
                  initialValue: safeLinkedRackId,
                  isExpanded: true,
                  isDense: true,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF0F172A),
                  ),
                  decoration: _compactInputDecoration(
                    'Linked Rack (Dashed Orange Line)',
                  ),
                  items: [
                    const DropdownMenuItem<int?>(
                      value: null,
                      child: Text('None'),
                    ),
                    ...floorRacks.map(
                      (rk) => DropdownMenuItem<int?>(
                        value: rk.id,
                        child: Text('${rk.code} (${rk.name})'),
                      ),
                    ),
                  ],
                  onChanged: (v) => setState(() => _devLinkedRackId = v),
                ),
                const SizedBox(height: 8),
                _buildCompactField(
                  label: 'Rack Patch Panel / Switch Port (ej. PP-A:01)',
                  controller: _devRackPortCtrl,
                ),
                if (dev.category != 'telecom_outlet') ...[
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int?>(
                    initialValue: safeLinkedOutletId,
                    isExpanded: true,
                    isDense: true,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF0F172A),
                    ),
                    decoration: _compactInputDecoration(
                      'Telecommunications Outlet (Blue Line)',
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
                    onChanged: (v) => setState(() => _devLinkedOutletId = v),
                  ),
                ],
                const SizedBox(height: 8),
                _buildCompactField(
                  label: 'Responsible person',
                  controller: _devRespCtrl,
                ),
                const SizedBox(height: 12),
                const Divider(height: 1, color: Color(0xFFE2E8F0)),
                const SizedBox(height: 10),
                const Text(
                  'Contact person',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
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
                  label: 'Notes',
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
            color: Color(0xFFF8FAFC),
            border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
          ),
          child: FilledButton.icon(
            onPressed: _saveSelectedFloorDeviceSettings,
            icon: const Icon(Icons.save_outlined, size: 16),
            label: const Text('Save Settings'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
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

    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${rk.code} — ${rk.name}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF0F172A),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Altura: ${rk.totalUnits}U  •  Equipos en Rack: ${rk.deviceCount}',
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: Color(0xFF475569),
                  ),
                ),
                if (rk.responsiblePerson.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Responsable: ${rk.responsiblePerson}',
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: Color(0xFF475569),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: () => widget.onOpenRack(rk.id),
                  icon: const Icon(Icons.open_in_new, size: 15),
                  label: const Text('Abrir en 3. Rack Editor'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF1E3A8A),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'TOMAS Y DISPOSITIVOS DE PLANTA CONECTADOS (${connectedDevices.length})',
            style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w900,
              color: Color(0xFF64748B),
            ),
          ),
          const SizedBox(height: 8),
          if (connectedDevices.isEmpty)
            const Text(
              'Ninguna roseta o cámara vinculada aún a este Rack.',
              style: TextStyle(fontSize: 11.5, color: Color(0xFF94A3B8)),
            )
          else
            ...connectedDevices.map((d) {
              final cat = _catalogItemFor(d.category);
              return Card(
                margin: const EdgeInsets.only(bottom: 6),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                  side: const BorderSide(color: Color(0xFFE2E8F0)),
                ),
                child: ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  leading: Icon(
                    cat.icon,
                    size: 16,
                    color: const Color(0xFF1E3A8A),
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
                        ? 'Puerto: ${d.linkedRackPort}'
                        : cat.label,
                    style: const TextStyle(fontSize: 10.5),
                  ),
                  onTap: () => _selectFloorDevice(d),
                ),
              );
            }),
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
            'Haz clic en cualquier cámara, roseta, PC o Rack del plano para editar sus Settings (${floor.floorDevices.length} dispositivos en planta).',
            style: const TextStyle(
              fontSize: 11,
              color: Color(0xFF64748B),
            ),
          ),
        ),
        const Divider(height: 1, color: Color(0xFFE2E8F0)),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(10),
            children: [
              if (floor.floorDevices.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'No hay dispositivos en esta planta. Arrastra elementos desde DEVICES LIBRARY a la izquierda.',
                    style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                  ),
                )
              else
                ...floor.floorDevices.map((d) {
                  final cat = _catalogItemFor(d.category);
                  return Container(
                    margin: const EdgeInsets.only(bottom: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFFE2E8F0)),
                    ),
                    child: ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      leading: Icon(
                        cat.icon,
                        size: 16,
                        color: d.category == 'telecom_outlet'
                            ? const Color(0xFF475569)
                            : const Color(0xFF0F172A),
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
      labelStyle: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      filled: true,
      fillColor: const Color(0xFFF8FAFC),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
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
      style: const TextStyle(fontSize: 12, color: Color(0xFF0F172A)),
      decoration: _compactInputDecoration(label),
    );
  }
}

class _FloorDeviceCatalogItem {
  final String category;
  final String label;
  final String prefix;
  final IconData icon;

  const _FloorDeviceCatalogItem({
    required this.category,
    required this.label,
    required this.prefix,
    required this.icon,
  });
}

class _PinTailPainter extends CustomPainter {
  final Color color;

  const _PinTailPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _PinTailPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _FloorConnectionsPainter extends CustomPainter {
  final List<RackSummary> racks;
  final Map<int, Offset> rackPositions;
  final Map<int, Size> rackSizes;
  final List<FloorDeviceNode> floorDevices;
  final Map<int, Offset> devicePositions;
  final int? selectedDeviceId;
  final Set<int> selectedRackIds;

  _FloorConnectionsPainter({
    required this.racks,
    required this.rackPositions,
    required this.rackSizes,
    required this.floorDevices,
    required this.devicePositions,
    required this.selectedDeviceId,
    required this.selectedRackIds,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rackCenters = <int, Offset>{};
    for (final rk in racks) {
      final norm = rackPositions[rk.id] ?? Offset(rk.posX, rk.posY);
      final sz = rackSizes[rk.id] ?? Size(rk.widthPx, rk.depthPx);
      final leftPx = (norm.dx * size.width)
          .clamp(8.0, (size.width - sz.width - 8.0).clamp(8.0, size.width));
      final topPx = (norm.dy * size.height)
          .clamp(8.0, (size.height - sz.height - 8.0).clamp(8.0, size.height));
      rackCenters[rk.id] = Offset(
        leftPx + sz.width / 2,
        topPx + sz.height / 2,
      );
    }

    final devCenters = <int, Offset>{};
    for (final d in floorDevices) {
      final norm = devicePositions[d.id] ?? Offset(d.posX, d.posY);
      final cx = (norm.dx * size.width).clamp(20.0, size.width - 20.0);
      final cy = (norm.dy * size.height).clamp(24.0, size.height - 16.0);
      devCenters[d.id] = Offset(cx, cy);
    }

    // 1. Líneas naranjas discontinuas (Troncal: Rack -> Roseta Bi01 o Cámara/AP directo)
    for (final d in floorDevices) {
      final rId = d.linkedRackId;
      if (rId == null) continue;
      // Si el equipo ya va conectado a una roseta, el tramo al rack lo pinta la roseta
      if (d.linkedOutletId != null && devCenters.containsKey(d.linkedOutletId)) {
        continue;
      }
      final p1 = rackCenters[rId];
      final p2 = devCenters[d.id];
      if (p1 == null || p2 == null) continue;

      final isHighlighted =
          selectedDeviceId == d.id || selectedRackIds.contains(rId);
      final paint = Paint()
        ..color = isHighlighted
            ? const Color(0xFFD97706)
            : const Color(0xFFF59E0B).withValues(alpha: 0.78)
        ..strokeWidth = isHighlighted ? 2.4 : 1.5
        ..style = PaintingStyle.stroke;

      _drawDashedLine(canvas, p1, p2, paint, dashWidth: 6, dashSpace: 4);
    }

    // 2. Líneas azules continuas (Latiguillo de área de trabajo: Roseta Bi01 -> Desktop/Phone/Printer)
    for (final d in floorDevices) {
      final outId = d.linkedOutletId;
      if (outId == null) continue;
      final p1 = devCenters[outId];
      final p2 = devCenters[d.id];
      if (p1 == null || p2 == null) continue;

      final isHighlighted =
          selectedDeviceId == d.id || selectedDeviceId == outId;
      final paint = Paint()
        ..color = isHighlighted
            ? const Color(0xFF1D4ED8)
            : const Color(0xFF3B82F6).withValues(alpha: 0.85)
        ..strokeWidth = isHighlighted ? 2.5 : 1.7
        ..style = PaintingStyle.stroke;

      canvas.drawLine(p1, p2, paint);
    }
  }

  void _drawDashedLine(
    Canvas canvas,
    Offset p1,
    Offset p2,
    Paint paint, {
    double dashWidth = 6,
    double dashSpace = 4,
  }) {
    final dx = p2.dx - p1.dx;
    final dy = p2.dy - p1.dy;
    final distance = Offset(dx, dy).distance;
    if (distance <= 0.1) return;
    final ux = dx / distance;
    final uy = dy / distance;

    double start = 0;
    while (start < distance) {
      final end = (start + dashWidth).clamp(0.0, distance);
      canvas.drawLine(
        Offset(p1.dx + ux * start, p1.dy + uy * start),
        Offset(p1.dx + ux * end, p1.dy + uy * end),
        paint,
      );
      start += dashWidth + dashSpace;
    }
  }

  @override
  bool shouldRepaint(covariant _FloorConnectionsPainter oldDelegate) => true;
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
