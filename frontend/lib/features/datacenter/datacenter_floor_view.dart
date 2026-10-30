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

  // Pila de Deshacer (Undo: Ctrl+Z en Windows/Linux o Cmd+Z en Mac) y Modo Mano (Barra Espaciadora)
  final List<_FloorUndoSnapshot> _undoStack = [];
  bool _isSpacePressed = false;
  bool _isHandToolPinned = false;
  bool _isSpaceDragging = false;
  Offset _canvasPanOffset = Offset.zero;

  bool get _isPanHandMode => _isSpacePressed || _isHandToolPinned;

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
  String _devCategory = 'camera';

  // Tipos personalizados creados por el usuario ("+ Nuevo Tipo a Medida")
  List<_FloorDeviceCatalogItem> _customCatalogItems = [];
  final Set<String> _expandedLibraryGroups = {
    'Sensores & Clima / Energía',
    'Seguridad & Control de Acceso',
    'Red, Wi-Fi & Rosetas',
    'Puestos de Trabajo & AV',
    'Industrial / A Medida',
  };

  static const List<String> _libraryGroupOrder = [
    'Sensores & Clima / Energía',
    'Seguridad & Control de Acceso',
    'Red, Wi-Fi & Rosetas',
    'Puestos de Trabajo & AV',
    'Industrial / A Medida',
  ];

  static const Map<String, IconData> _customIconMap = {
    'thermostat': Icons.thermostat_rounded,
    'water_drop': Icons.water_drop_outlined,
    'bolt': Icons.bolt_rounded,
    'fire': Icons.local_fire_department_outlined,
    'waves': Icons.waves_rounded,
    'air': Icons.air_rounded,
    'ac_unit': Icons.ac_unit_rounded,
    'battery': Icons.battery_charging_full_rounded,
    'sensors': Icons.sensors_rounded,
    'videocam': Icons.videocam_outlined,
    'dialpad': Icons.dialpad_rounded,
    'wifi': Icons.wifi_tethering_rounded,
    'router': Icons.router_outlined,
    'memory': Icons.memory_rounded,
    'shield': Icons.shield_outlined,
    'precision_manufacturing': Icons.precision_manufacturing_outlined,
  };

  static IconData _iconFromKey(String key) =>
      _customIconMap[key] ?? Icons.sensors_rounded;

  static Color _colorFromHex(String hex) {
    final cleaned = hex.replaceAll('#', '').trim();
    if (cleaned.length == 6) {
      final val = int.tryParse('FF$cleaned', radix: 16);
      if (val != null) return Color(val);
    }
    return const Color(0xFF0F172A);
  }

  static const List<_FloorDeviceCatalogItem> _floorDeviceCatalog = [
    // 1. FAMILIA: Sensores & Clima / Energía
    _FloorDeviceCatalogItem(
      category: 'sensor_temp',
      groupName: 'Sensores & Clima / Energía',
      label: 'Sensor Temperatura (°C)',
      prefix: 'TMP',
      icon: Icons.thermostat_rounded,
      pinColor: Color(0xFF0D9488),
      defaultPortHint: 'ENV-MON01:Temp-1 (21.2 °C)',
      isSensor: true,
    ),
    _FloorDeviceCatalogItem(
      category: 'sensor_humidity',
      groupName: 'Sensores & Clima / Energía',
      label: 'Sensor Humedad (%RH)',
      prefix: 'HUM',
      icon: Icons.water_drop_outlined,
      pinColor: Color(0xFF0284C7),
      defaultPortHint: 'ENV-MON01:Hum-1 (45 %RH)',
      isSensor: true,
    ),
    _FloorDeviceCatalogItem(
      category: 'sensor_temp_hum',
      groupName: 'Sensores & Clima / Energía',
      label: 'Sensor Temp + Humedad',
      prefix: 'TH',
      icon: Icons.device_thermostat_rounded,
      pinColor: Color(0xFF0D9488),
      defaultPortHint: 'ENV-MON01:TH-1 (21.0 °C / 46 %RH)',
      isSensor: true,
    ),
    _FloorDeviceCatalogItem(
      category: 'sensor_power_load',
      groupName: 'Sensores & Clima / Energía',
      label: 'Sensor Carga Eléctrica (kW/A)',
      prefix: 'PWR',
      icon: Icons.bolt_rounded,
      pinColor: Color(0xFFD97706),
      defaultPortHint: 'PDU-A:Meter-1 (4.8 kW / 20.9 A)',
      isSensor: true,
    ),
    _FloorDeviceCatalogItem(
      category: 'sensor_smoke',
      groupName: 'Sensores & Clima / Energía',
      label: 'Detector Humo / Incendio',
      prefix: 'SMK',
      icon: Icons.local_fire_department_outlined,
      pinColor: Color(0xFFDC2626),
      defaultPortHint: 'ENV-MON01:Smoke-1 (Normal)',
      isSensor: true,
    ),
    _FloorDeviceCatalogItem(
      category: 'sensor_water_leak',
      groupName: 'Sensores & Clima / Energía',
      label: 'Sensor Fuga de Agua',
      prefix: 'WTR',
      icon: Icons.waves_rounded,
      pinColor: Color(0xFF0284C7),
      defaultPortHint: 'ENV-MON01:Leak-1 (Seco)',
      isSensor: true,
    ),
    _FloorDeviceCatalogItem(
      category: 'sensor_airflow',
      groupName: 'Sensores & Clima / Energía',
      label: 'Sensor Flujo Aire / Presión',
      prefix: 'AIR',
      icon: Icons.air_rounded,
      pinColor: Color(0xFF0D9488),
      defaultPortHint: 'ENV-MON01:Airflow-1 (2.4 m/s)',
      isSensor: true,
    ),
    _FloorDeviceCatalogItem(
      category: 'sensor_door',
      groupName: 'Sensores & Clima / Energía',
      label: 'Sensor Contacto Puerta',
      prefix: 'DOR',
      icon: Icons.sensor_door_outlined,
      pinColor: Color(0xFF0D9488),
      defaultPortHint: 'ENV-MON01:Door-1 (Cerrada)',
      isSensor: true,
    ),

    // 2. FAMILIA: Seguridad & Control de Acceso
    _FloorDeviceCatalogItem(
      category: 'camera',
      groupName: 'Seguridad & Control de Acceso',
      label: 'Camera CCTV',
      prefix: 'CAM',
      icon: Icons.videocam_outlined,
      pinColor: Color(0xFF0F172A),
      defaultPortHint: 'SW01:Gi1/0/21 (PoE)',
    ),
    _FloorDeviceCatalogItem(
      category: 'access_control',
      groupName: 'Seguridad & Control de Acceso',
      label: 'Access Control Panel',
      prefix: 'AC',
      icon: Icons.dialpad_rounded,
      pinColor: Color(0xFF0F172A),
      defaultPortHint: 'SW01:Gi1/0/24',
    ),

    // 3. FAMILIA: Red, Wi-Fi & Rosetas
    _FloorDeviceCatalogItem(
      category: 'telecom_outlet',
      groupName: 'Red, Wi-Fi & Rosetas',
      label: 'Telecommunications Outlet',
      prefix: 'Bi',
      icon: Icons.settings_input_hdmi_outlined,
      pinColor: Color(0xFF64748B),
      defaultPortHint: 'PP-A:01-04',
    ),
    _FloorDeviceCatalogItem(
      category: 'access_point',
      groupName: 'Red, Wi-Fi & Rosetas',
      label: 'Access Point Wi-Fi',
      prefix: 'AP',
      icon: Icons.wifi_tethering_rounded,
      pinColor: Color(0xFF0F172A),
      defaultPortHint: 'SW01:Gi1/0/18 (PoE+)',
    ),
    _FloorDeviceCatalogItem(
      category: 'isp_uplink',
      groupName: 'Red, Wi-Fi & Rosetas',
      label: 'ISP Uplink / Acometida',
      prefix: 'ISP',
      icon: Icons.public_rounded,
      pinColor: Color(0xFF1E3A8A),
      defaultPortHint: 'FW01:WAN1',
    ),
    _FloorDeviceCatalogItem(
      category: 'rack',
      groupName: 'Red, Wi-Fi & Rosetas',
      label: 'Rack Cabinet',
      prefix: 'RK',
      icon: Icons.dns_outlined,
      pinColor: Color(0xFF1E3A8A),
      defaultPortHint: '',
    ),

    // 4. FAMILIA: Puestos de Trabajo & AV
    _FloorDeviceCatalogItem(
      category: 'desktop',
      groupName: 'Puestos de Trabajo & AV',
      label: 'Desktop',
      prefix: 'DP',
      icon: Icons.desktop_windows_outlined,
      pinColor: Color(0xFF0F172A),
      defaultPortHint: 'SW01:Gi1/0/1',
    ),
    _FloorDeviceCatalogItem(
      category: 'laptop',
      groupName: 'Puestos de Trabajo & AV',
      label: 'Laptop',
      prefix: 'LP',
      icon: Icons.laptop_mac_outlined,
      pinColor: Color(0xFF0F172A),
      defaultPortHint: 'SW01:Gi1/0/2',
    ),
    _FloorDeviceCatalogItem(
      category: 'phone',
      groupName: 'Puestos de Trabajo & AV',
      label: 'Phone VoIP',
      prefix: 'PH',
      icon: Icons.phone_in_talk_outlined,
      pinColor: Color(0xFF0F172A),
      defaultPortHint: 'SW01:Gi1/0/5 (VoIP)',
    ),
    _FloorDeviceCatalogItem(
      category: 'printer',
      groupName: 'Puestos de Trabajo & AV',
      label: 'Printer',
      prefix: 'PR',
      icon: Icons.print_outlined,
      pinColor: Color(0xFF0F172A),
      defaultPortHint: 'SW01:Gi1/0/8',
    ),
    _FloorDeviceCatalogItem(
      category: '3d_printer',
      groupName: 'Puestos de Trabajo & AV',
      label: '3D Printer',
      prefix: '3DP',
      icon: Icons.view_in_ar_rounded,
      pinColor: Color(0xFF0F172A),
      defaultPortHint: 'SW01:Gi1/0/9',
    ),
    _FloorDeviceCatalogItem(
      category: 'screen',
      groupName: 'Puestos de Trabajo & AV',
      label: 'Screen / Videowall',
      prefix: 'SC',
      icon: Icons.tv_rounded,
      pinColor: Color(0xFF0F172A),
      defaultPortHint: 'SW01:Gi1/0/12',
    ),
    _FloorDeviceCatalogItem(
      category: 'speaker',
      groupName: 'Puestos de Trabajo & AV',
      label: 'Speaker',
      prefix: 'SPK',
      icon: Icons.speaker_outlined,
      pinColor: Color(0xFF0F172A),
      defaultPortHint: 'SW01:Gi1/0/14',
    ),
    _FloorDeviceCatalogItem(
      category: 'microphone',
      groupName: 'Puestos de Trabajo & AV',
      label: 'Microphone',
      prefix: 'MIC',
      icon: Icons.mic_none_rounded,
      pinColor: Color(0xFF0F172A),
      defaultPortHint: 'SW01:Gi1/0/15',
    ),
    _FloorDeviceCatalogItem(
      category: 'ndi_box',
      groupName: 'Puestos de Trabajo & AV',
      label: 'NDI Box',
      prefix: 'NDI',
      icon: Icons.cast_connected_rounded,
      pinColor: Color(0xFF0F172A),
      defaultPortHint: 'SW01:Gi1/0/16',
    ),

    // 5. FAMILIA: Industrial / A Medida
    _FloorDeviceCatalogItem(
      category: 'custom_crac',
      groupName: 'Industrial / A Medida',
      label: 'Climatizador CRAC / InRow',
      prefix: 'CRAC',
      icon: Icons.ac_unit_rounded,
      pinColor: Color(0xFF7C3AED),
      defaultPortHint: 'BMS:Modbus-CRAC1 (18.5 °C)',
      isSensor: true,
    ),
    _FloorDeviceCatalogItem(
      category: 'custom_ups_plant',
      groupName: 'Industrial / A Medida',
      label: 'SAI / UPS Industrial Planta',
      prefix: 'UPS',
      icon: Icons.battery_charging_full_rounded,
      pinColor: Color(0xFFD97706),
      defaultPortHint: 'PDU-MAIN:Feed-A+B (98% Bat)',
      isSensor: true,
    ),
    _FloorDeviceCatalogItem(
      category: 'custom_elec_board',
      groupName: 'Industrial / A Medida',
      label: 'Cuadro Eléctrico General',
      prefix: 'CEG',
      icon: Icons.bolt_rounded,
      pinColor: Color(0xFFD97706),
      defaultPortHint: 'CEG-01:Disyuntor-Rack',
    ),
  ];

  List<_FloorDeviceCatalogItem> get _allCatalogItems => [
    ..._floorDeviceCatalog,
    ..._customCatalogItems,
  ];

  bool _isSensorCategory(String category) {
    if (category.startsWith('sensor_')) return true;
    final item = _catalogItemFor(category);
    return item.isSensor;
  }

  String _defaultPortHintForCategory(String category) {
    final item = _catalogItemFor(category);
    if (item.defaultPortHint.isNotEmpty) return item.defaultPortHint;
    return 'SW01:Gi1/0/1';
  }

  _FloorDeviceCatalogItem _catalogItemFor(String category) {
    for (final item in _allCatalogItems) {
      if (item.category == category) return item;
    }
    return _FloorDeviceCatalogItem(
      category: category,
      groupName: 'Industrial / A Medida',
      label: category.toUpperCase(),
      prefix: 'DEV',
      icon: Icons.sensors_rounded,
      pinColor: const Color(0xFF7C3AED),
    );
  }

  Future<void> _loadCustomFloorDeviceTypes() async {
    try {
      final rows = await widget.api.fetchCustomFloorDeviceTypes();
      if (!mounted) return;
      setState(() {
        _customCatalogItems = rows.map((r) {
          final catKey = (r['category_key'] ?? 'custom_dev').toString();
          return _FloorDeviceCatalogItem(
            category: catKey,
            groupName: (r['group_name'] ?? 'Industrial / A Medida').toString(),
            label: (r['label'] ?? catKey).toString(),
            prefix: (r['prefix'] ?? 'DEV').toString(),
            icon: _iconFromKey((r['icon_key'] ?? 'sensors').toString()),
            pinColor: _colorFromHex((r['pin_color_hex'] ?? '#7C3AED').toString()),
            defaultPortHint:
                (r['default_port_hint'] ?? 'SW01:Gi1/0/1').toString(),
            isSensor: r['is_sensor'] == true,
            customTypeId: (r['id'] as num?)?.toInt(),
          );
        }).toList();
      });
    } catch (_) {}
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
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
    _syncFloorState();
    _loadCustomFloorDeviceTypes();
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
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
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

  bool _isTextInputFocused() {
    final focus = FocusManager.instance.primaryFocus;
    final ctx = focus?.context;
    if (ctx == null) return false;
    if (ctx.widget is EditableText) return true;
    return ctx.findAncestorWidgetOfExactType<EditableText>() != null ||
        ctx.findAncestorStateOfType<EditableTextState>() != null;
  }

  bool _handleHardwareKey(KeyEvent event) {
    if (!mounted) return false;
    // No interceptar teclas cuando el usuario está escribiendo dentro de un TextField
    if (_isTextInputFocused()) {
      if (_isSpacePressed) {
        setState(() {
          _isSpacePressed = false;
          _isSpaceDragging = false;
        });
      }
      return false;
    }

    // 1. Barra Espaciadora -> Modo Mano (Pan del Dashboard)
    if (event.logicalKey == LogicalKeyboardKey.space) {
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        if (!_isSpacePressed) {
          setState(() => _isSpacePressed = true);
        }
        return true;
      } else if (event is KeyUpEvent) {
        if (_isSpacePressed || _isSpaceDragging) {
          setState(() {
            _isSpacePressed = false;
            _isSpaceDragging = false;
          });
        }
        return true;
      }
    }

    // 2. Tecla ESC -> Cancelar selección o Modo Mano fijado
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      if (_marqueeStart != null ||
          _isHandToolPinned ||
          _selectedRackIds.isNotEmpty ||
          _selectedFloorDeviceId != null) {
        setState(() {
          _marqueeStart = null;
          _marqueeCurrent = null;
          _isHandToolPinned = false;
          _selectedRackIds.clear();
          _selectedFloorDeviceId = null;
          _editingDeviceId = null;
        });
        return true;
      }
    }

    // 3. Deshacer movimiento: Ctrl + Z (Windows/Linux) o Cmd + Z (macOS)
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyZ) {
      final keys = HardwareKeyboard.instance.logicalKeysPressed;
      final isMetaOrCtrl = keys.contains(LogicalKeyboardKey.metaLeft) ||
          keys.contains(LogicalKeyboardKey.metaRight) ||
          keys.contains(LogicalKeyboardKey.controlLeft) ||
          keys.contains(LogicalKeyboardKey.controlRight);
      final isShift = keys.contains(LogicalKeyboardKey.shiftLeft) ||
          keys.contains(LogicalKeyboardKey.shiftRight);
      if (isMetaOrCtrl && !isShift) {
        _performUndo();
        return true;
      }
    }
    return false;
  }

  void _pushUndoSnapshot({
    required String description,
    Iterable<int> affectedRackIds = const [],
    Iterable<int> affectedDeviceIds = const [],
  }) {
    _undoStack.add(
      _FloorUndoSnapshot(
        description: description,
        rackPositions: Map<int, Offset>.from(_rackPositions),
        rackSizes: Map<int, Size>.from(_rackSizes),
        rackRotations: Map<int, int>.from(_rackRotations),
        floorDevicePositions: Map<int, Offset>.from(_floorDevicePositions),
        affectedRackIds: affectedRackIds.toSet(),
        affectedDeviceIds: affectedDeviceIds.toSet(),
      ),
    );
    if (_undoStack.length > 35) {
      _undoStack.removeAt(0);
    }
  }

  Future<void> _performUndo() async {
    if (_undoStack.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No hay movimientos recientes para deshacer.'),
          duration: Duration(seconds: 1),
        ),
      );
      return;
    }
    final snap = _undoStack.removeLast();
    setState(() {
      _rackPositions
        ..clear()
        ..addAll(snap.rackPositions);
      _rackSizes
        ..clear()
        ..addAll(snap.rackSizes);
      _rackRotations
        ..clear()
        ..addAll(snap.rackRotations);
      _floorDevicePositions
        ..clear()
        ..addAll(snap.floorDevicePositions);
    });
    if (snap.affectedRackIds.isNotEmpty) {
      await _saveMultipleRacksGeometry(snap.affectedRackIds);
    }
    for (final devId in snap.affectedDeviceIds) {
      await _saveFloorDevicePosition(devId);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('↩ Deshecho: ${snap.description}'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
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
    _devCategory = dev.category.isEmpty ? 'camera' : dev.category;
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
        'device_type': _devCategory,
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
                  color: _colorFromHex(selectedColorHex),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  _iconFromKey(selectedIconKey),
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
                      style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
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
                    items: _libraryGroupOrder
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
                      color: Color(0xFF334155),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: _customIconMap.entries.map((entry) {
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
                                ? _colorFromHex(selectedColorHex)
                                : const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: isSel
                                  ? const Color(0xFF0F172A)
                                  : const Color(0xFFCBD5E1),
                              width: isSel ? 1.8 : 1.0,
                            ),
                          ),
                          child: Icon(
                            entry.value,
                            size: 17,
                            color: isSel
                                ? Colors.white
                                : const Color(0xFF334155),
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
                      color: Color(0xFF334155),
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
                          backgroundColor: _colorFromHex(hex),
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
                  setState(() {
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

  Future<void> _showAddFloorDeviceModal(
    FloorNode floor, {
    String initialCategory = 'sensor_temp',
    double? targetPosX,
    double? targetPosY,
  }) async {
    String selectedCat = initialCategory == 'rack'
        ? 'sensor_temp'
        : initialCategory;
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
                            ? 'Posición en plano seleccionada (${(targetPosX * 100).round()}%, ${(targetPosY! * 100).round()}%) • Elige el Rack de conexión'
                            : 'Selecciona el tipo de equipo y el Rack al que va conectado',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 1. CAJA DESTACADA: SELECCIÓN DE RACK AL QUE VA CONECTADO
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFFBEB),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: const Color(0xFFF59E0B),
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
                                color: Color(0xFFB45309),
                              ),
                              SizedBox(width: 6),
                              Text(
                                '1. ¿A qué Rack está conectado este sensor / dispositivo? *',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w900,
                                  color: Color(0xFF92400E),
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
                            '2. Categoría / Tipo de Sensor o Dispositivo',
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
                          nameCtrl.text =
                              '${_catalogItemFor(selectedCat).label} $auto';
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
                                  'ID / Código * (ej. TMP01, HUM01, PWR01, CAM01)',
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
                              labelText: 'Dirección IP (opcional)',
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
                label: const Text('Colocar y Conectar al Rack'),
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
        'pos_x': normX,
        'pos_y': normY,
        'status': 'online',
        'linked_rack_id': linkedRackId,
        'linked_rack_device_code': portCtrl.text.trim(),
        'linked_outlet_id': linkedOutletId,
        'responsible_person': respCtrl.text.trim(),
        'notes': notesCtrl.text.trim(),
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
    _pushUndoSnapshot(
      description: 'Igualar dimensiones de ${_selectedRackIds.length} Racks',
      affectedRackIds: _selectedRackIds,
    );
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
                  const SizedBox(width: 8),
                  // Botón Deshacer (Ctrl+Z en Windows/Linux o Cmd+Z en Mac)
                  Tooltip(
                    message:
                        'Deshacer último movimiento de Rack o Dispositivo (Ctrl+Z / ⌘Z)',
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        backgroundColor: _undoStack.isNotEmpty
                            ? const Color(0xFFF8FAFC)
                            : Colors.white,
                      ),
                      onPressed: _undoStack.isEmpty ? null : _performUndo,
                      icon: const Icon(Icons.undo_rounded, size: 15),
                      label: Text(
                        _undoStack.isEmpty
                            ? 'Deshacer (⌘Z / Ctrl+Z)'
                            : 'Deshacer (${_undoStack.length})',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Botón Modo Mano (Barra Espaciadora) para mover el dashboard
                  Tooltip(
                    message:
                        'Mantén pulsada la Barra Espaciadora (o activa este botón) para convertir el ratón en una mano y mover todo el dashboard',
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        backgroundColor: _isPanHandMode
                            ? const Color(0xFF0F172A)
                            : Colors.white,
                        foregroundColor: _isPanHandMode
                            ? Colors.white
                            : const Color(0xFF334155),
                        side: BorderSide(
                          color: _isPanHandMode
                              ? const Color(0xFF38BDF8)
                              : const Color(0xFFCBD5E1),
                        ),
                      ),
                      onPressed: () => setState(
                        () => _isHandToolPinned = !_isHandToolPinned,
                      ),
                      icon: Icon(
                        Icons.pan_tool_alt_rounded,
                        size: 15,
                        color: _isPanHandMode
                            ? const Color(0xFF38BDF8)
                            : const Color(0xFF475569),
                      ),
                      label: Text(
                        _isPanHandMode
                            ? 'Mano: ACTIVA (Espacio)'
                            : 'Mano (Espacio)',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  if (_canvasPanOffset != Offset.zero) ...[
                    const SizedBox(width: 4),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Restablecer posición centrada del lienzo',
                      onPressed: () =>
                          setState(() => _canvasPanOffset = Offset.zero),
                      icon: const Icon(
                        Icons.center_focus_strong_rounded,
                        size: 16,
                        color: Color(0xFF2563EB),
                      ),
                    ),
                  ],
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Espacio + Arrastrar: Mover Dashboard ✋  •  Ctrl+Z / ⌘Z: Deshacer  •  Doble Clic en Rack: Abrir en Rack Editor',
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
                                        // Lienzo desplazable con Modo Mano (Barra Espaciadora)
                                        Transform.translate(
                                          offset: _canvasPanOffset,
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              // A. Fondo interactivo: clic en vacío limpia selección, arrastrar dibuja caja de selección (Marquee)
                                              GestureDetector(
                                                behavior:
                                                    HitTestBehavior.opaque,
                                                onTap: () {
                                                  setState(() {
                                                    if (!_isShiftPressed) {
                                                      _selectedRackIds.clear();
                                                    }
                                                    _selectedFloorDeviceId =
                                                        null;
                                                    _editingDeviceId = null;
                                                  });
                                                },
                                                onPanStart: (details) {
                                                  setState(() {
                                                    if (!_isShiftPressed) {
                                                      _selectedRackIds.clear();
                                                    }
                                                    _selectedFloorDeviceId =
                                                        null;
                                                    _editingDeviceId = null;
                                                    _marqueeStart =
                                                        details.localPosition;
                                                    _marqueeCurrent =
                                                        details.localPosition;
                                                  });
                                                },
                                                onPanUpdate: (details) {
                                                  if (_marqueeStart == null) {
                                                    return;
                                                  }
                                                  final cur =
                                                      details.localPosition;
                                                  final selRect =
                                                      Rect.fromPoints(
                                                    _marqueeStart!,
                                                    cur,
                                                  );
                                                  setState(() {
                                                    _marqueeCurrent = cur;
                                                    for (final rk
                                                        in floorRacks) {
                                                      final normPos =
                                                          _rackPositions[
                                                                  rk.id] ??
                                                              const Offset(
                                                                0.25,
                                                                0.35,
                                                              );
                                                      final sz =
                                                          _rackSizes[rk.id] ??
                                                              const Size(
                                                                120.0,
                                                                90.0,
                                                              );
                                                      final leftPx = (normPos
                                                                  .dx *
                                                              canvasW)
                                                          .clamp(
                                                        8.0,
                                                        (canvasW -
                                                                sz.width -
                                                                8.0)
                                                            .clamp(
                                                              8.0,
                                                              canvasW,
                                                            ),
                                                      );
                                                      final topPx = (normPos
                                                                  .dy *
                                                              canvasH)
                                                          .clamp(
                                                        8.0,
                                                        (canvasH -
                                                                sz.height -
                                                                8.0)
                                                            .clamp(
                                                              8.0,
                                                              canvasH,
                                                            ),
                                                      );
                                                      final rkRect =
                                                          Rect.fromLTWH(
                                                        leftPx,
                                                        topPx,
                                                        sz.width,
                                                        sz.height,
                                                      );
                                                      if (selRect.overlaps(
                                                        rkRect,
                                                      )) {
                                                        _selectedRackIds.add(
                                                          rk.id,
                                                        );
                                                      } else if (!_isShiftPressed) {
                                                        _selectedRackIds.remove(
                                                          rk.id,
                                                        );
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
                                                    if (floorImageUrl
                                                        .isNotEmpty)
                                                      Center(
                                                        child: Transform.scale(
                                                          scale:
                                                              _floorImageScale,
                                                          child: Image.network(
                                                            floorImageUrl,
                                                            fit: BoxFit.contain,
                                                            errorBuilder:
                                                                (ctx, err, _) {
                                                              WidgetsBinding
                                                                  .instance
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
                                                            rackSizes:
                                                                _rackSizes,
                                                            floorDevices: floor
                                                                .floorDevices,
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

                                              // B. Dibujos de los Racks en Vista de Planta (Top-Down)
                                              for (final rk in floorRacks)
                                                _buildTopDownRackBox(
                                                  rk: rk,
                                                  canvasW: canvasW,
                                                  canvasH: canvasH,
                                                ),

                                              // B2. Pines de Dispositivos de Planta (Cámaras, Rosetas Bi01, PCs, Control de Acceso, APs...)
                                              for (final dev
                                                  in floor.floorDevices)
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
                                                        color: const Color(
                                                          0xFF2563EB,
                                                        ).withValues(
                                                          alpha: 0.16,
                                                        ),
                                                        border: Border.all(
                                                          color: const Color(
                                                            0xFF2563EB,
                                                          ),
                                                          width: 1.8,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(4),
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),

                                        // Capa superior cuando se pulsa la Barra Espaciadora (Modo Mano para arrastrar todo el dashboard)
                                        if (_isPanHandMode)
                                          Positioned.fill(
                                            child: MouseRegion(
                                              cursor: _isSpaceDragging
                                                  ? SystemMouseCursors.grabbing
                                                  : SystemMouseCursors.grab,
                                              child: GestureDetector(
                                                behavior:
                                                    HitTestBehavior.opaque,
                                                onPanStart: (_) {
                                                  setState(
                                                    () =>
                                                        _isSpaceDragging = true,
                                                  );
                                                },
                                                onPanUpdate: (details) {
                                                  setState(() {
                                                    _canvasPanOffset +=
                                                        details.delta;
                                                  });
                                                },
                                                onPanEnd: (_) {
                                                  setState(
                                                    () => _isSpaceDragging =
                                                        false,
                                                  );
                                                },
                                                onPanCancel: () {
                                                  setState(
                                                    () => _isSpaceDragging =
                                                        false,
                                                  );
                                                },
                                                child: Align(
                                                  alignment:
                                                      Alignment.topCenter,
                                                  child: Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                      top: 12,
                                                    ),
                                                    child: Container(
                                                      padding: const EdgeInsets
                                                          .symmetric(
                                                        horizontal: 14,
                                                        vertical: 6,
                                                      ),
                                                      decoration: BoxDecoration(
                                                        color: const Color(
                                                          0xEE0F172A,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(20),
                                                        border: Border.all(
                                                          color: const Color(
                                                            0xFF38BDF8,
                                                          ),
                                                          width: 1.4,
                                                        ),
                                                      ),
                                                      child: const Row(
                                                        mainAxisSize:
                                                            MainAxisSize.min,
                                                        children: [
                                                          Icon(
                                                            Icons
                                                                .pan_tool_alt_rounded,
                                                            size: 15,
                                                            color: Color(
                                                              0xFF38BDF8,
                                                            ),
                                                          ),
                                                          SizedBox(width: 6),
                                                          Text(
                                                            'Modo Mano activo — Arrastra con el ratón para mover el dashboard',
                                                            style: TextStyle(
                                                              color:
                                                                  Colors.white,
                                                              fontSize: 11.5,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w800,
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
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
            final targetIds = _selectedRackIds.contains(rk.id)
                ? _selectedRackIds
                : <int>{rk.id};
            _pushUndoSnapshot(
              description: targetIds.length > 1
                  ? 'Mover ${targetIds.length} Racks'
                  : 'Mover Rack ${rk.code}',
              affectedRackIds: targetIds,
            );
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
                            _pushUndoSnapshot(
                              description: 'Rotar Rack ${rk.code}',
                              affectedRackIds: [rk.id],
                            );
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
                  onPanStart: (_) {
                    _pushUndoSnapshot(
                      description: 'Redimensionar Rack ${rk.code}',
                      affectedRackIds: [rk.id],
                    );
                  },
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
  // COLUMNA IZQUIERDA: DEVICES LIBRARY POR FAMILIAS DESPLEGABLES + A MEDIDA
  // ===========================================================================
  Widget _buildLeftDevicesLibraryPanel(FloorNode floor) {
    final query = _deviceLibrarySearch.trim().toLowerCase();
    final filteredCatalog = _allCatalogItems.where((item) {
      if (query.isEmpty) return true;
      return item.label.toLowerCase().contains(query) ||
          item.category.toLowerCase().contains(query) ||
          item.groupName.toLowerCase().contains(query) ||
          item.prefix.toLowerCase().contains(query);
    }).toList();

    final grouped = <String, List<_FloorDeviceCatalogItem>>{};
    for (final g in _libraryGroupOrder) {
      grouped[g] = [];
    }
    for (final item in filteredCatalog) {
      grouped.putIfAbsent(item.groupName, () => []).add(item);
    }

    IconData groupIconFor(String g) {
      if (g.startsWith('Sensores')) return Icons.thermostat_rounded;
      if (g.startsWith('Seguridad')) return Icons.videocam_outlined;
      if (g.startsWith('Red')) return Icons.hub_outlined;
      if (g.startsWith('Puestos')) return Icons.desktop_windows_outlined;
      return Icons.precision_manufacturing_outlined;
    }

    Color groupAccentFor(String g) {
      if (g.startsWith('Sensores')) return const Color(0xFF0D9488);
      if (g.startsWith('Seguridad')) return const Color(0xFF0F172A);
      if (g.startsWith('Red')) return const Color(0xFF2563EB);
      if (g.startsWith('Puestos')) return const Color(0xFF1E3A8A);
      return const Color(0xFF7C3AED);
    }

    return Container(
      width: 265,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(right: BorderSide(color: Color(0xFFE2E8F0))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 4),
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
              'Arrastra un equipo o sensor a la planta para elegir su Rack de conexión',
              style: TextStyle(
                fontSize: 10.5,
                color: Color(0xFF64748B),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
            child: SizedBox(
              height: 32,
              child: TextField(
                onChanged: (v) => setState(() => _deviceLibrarySearch = v),
                style: const TextStyle(fontSize: 12),
                decoration: InputDecoration(
                  hintText: 'Buscar sensor, cámara, PC...',
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
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                foregroundColor: const Color(0xFF7C3AED),
                backgroundColor: const Color(0xFFF5F3FF),
                side: const BorderSide(color: Color(0xFFC4B5FD)),
              ),
              onPressed: () => _showCreateCustomDeviceTypeModal(floor),
              icon: const Icon(Icons.add_box_outlined, size: 15),
              label: const Text(
                '+ Nuevo Tipo a Medida',
                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800),
              ),
            ),
          ),
          const Divider(height: 1, color: Color(0xFFE2E8F0)),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
              children: [
                for (final entry in grouped.entries)
                  if (entry.value.isNotEmpty) ...[
                    // Cabecera desplegable de Familia
                    InkWell(
                      onTap: () {
                        setState(() {
                          if (_expandedLibraryGroups.contains(entry.key)) {
                            _expandedLibraryGroups.remove(entry.key);
                          } else {
                            _expandedLibraryGroups.add(entry.key);
                          }
                        });
                      },
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        margin: const EdgeInsets.only(top: 4, bottom: 3),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              groupIconFor(entry.key),
                              size: 14,
                              color: groupAccentFor(entry.key),
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                entry.key,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                  color: groupAccentFor(entry.key),
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: const Color(0xFFCBD5E1),
                                ),
                              ),
                              child: Text(
                                '${entry.value.length}',
                                style: const TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF475569),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              (_expandedLibraryGroups.contains(entry.key) ||
                                      query.isNotEmpty)
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                              size: 16,
                              color: const Color(0xFF64748B),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_expandedLibraryGroups.contains(entry.key) ||
                        query.isNotEmpty)
                      for (final item in entry.value)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 3, left: 4),
                          child: _buildLibraryCatalogTile(floor, item),
                        ),
                  ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLibraryCatalogTile(
    FloorNode floor,
    _FloorDeviceCatalogItem item,
  ) {
    final countInFloor = item.category == 'rack'
        ? floor.rooms.fold<int>(0, (s, r) => s + r.racks.length)
        : floor.floorDevices.where((d) => d.category == item.category).length;

    final tileContent = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 8,
        vertical: 6,
      ),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFF1F5F9)),
      ),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: item.pinColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              item.icon,
              size: 14,
              color: item.pinColor,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              item.label,
              style: const TextStyle(
                fontSize: 11.5,
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
                  fontSize: 9.5,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF64748B),
                ),
              ),
            ),
          if (item.customTypeId != null)
            InkWell(
              onTap: () async {
                await widget.api.deleteCustomFloorDeviceType(
                  item.customTypeId!,
                );
                await _loadCustomFloorDeviceTypes();
              },
              borderRadius: BorderRadius.circular(4),
              child: const Tooltip(
                message: 'Eliminar este tipo personalizado de la librería',
                child: Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(
                    Icons.delete_outline,
                    size: 14,
                    color: Color(0xFF94A3B8),
                  ),
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
              message: 'Colocar en planta y elegir Rack de conexión',
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
        color: item.pinColor,
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
  }

  // ===========================================================================
  // PIN DE GOTA (TEARDROP PIN) EN EL PLANO 2D PARA CADA DISPOSITIVO / SENSOR
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

    // Buscar código del Rack conectado para mostrarlo en el tooltip y badge
    String linkedRackCode = '';
    if (dev.linkedRackId != null && _floor != null) {
      for (final rm in _floor!.rooms) {
        for (final rk in rm.racks) {
          if (rk.id == dev.linkedRackId) {
            linkedRackCode = rk.code;
            break;
          }
        }
      }
    }

    // Coordenadas de la punta del pin
    final centerX = (normPos.dx * canvasW).clamp(20.0, canvasW - 20.0);
    final centerY = (normPos.dy * canvasH).clamp(24.0, canvasH - 16.0);

    final Color pinBgColor =
        isSelected ? const Color(0xFF2563EB) : catItem.pinColor;

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
          'Familia: ${catItem.groupName}',
          if (linkedRackCode.isNotEmpty) 'Conectado a Rack: $linkedRackCode',
          if (dev.linkedRackPort.isNotEmpty)
            'Puerto/Sonda en Rack: ${dev.linkedRackPort}',
          if (dev.roomCode.isNotEmpty) 'Sala/Zona: ${dev.roomCode}',
          if (dev.ipAddress.isNotEmpty) 'IP: ${dev.ipAddress}',
          if (dev.notes.isNotEmpty) dev.notes,
          if (dev.contactFirstName.isNotEmpty || dev.contactLastName.isNotEmpty)
            'Contacto: ${dev.contactFirstName} ${dev.contactLastName}',
          '• Clic: Abrir Settings  • Arrastrar: Mover en planta',
        ].join('\n'),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _selectFloorDevice(dev),
          onPanStart: (_) {
            _pushUndoSnapshot(
              description: 'Mover dispositivo ${dev.code}',
              affectedDeviceIds: [dev.id],
            );
            _selectFloorDevice(dev);
          },
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
                // Etiqueta junto al pin (ej. TMP01, CAM01, DP01, Bi01, Bi02...)
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
                          : (catItem.isSensor
                              ? catItem.pinColor.withValues(alpha: 0.55)
                              : const Color(0xFFCBD5E1)),
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
                      if (linkedRackCode.isNotEmpty &&
                          (catItem.isSensor || isSelected)) ...[
                        const SizedBox(width: 4),
                        Text(
                          '→$linkedRackCode',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w700,
                            color: isSelected
                                ? const Color(0xFFFDE047)
                                : const Color(0xFFB45309),
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
      width: 310,
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
                      color: _catalogItemFor(selectedDev.category).pinColor,
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
                    color: Color(0xFF2563EB),
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: safeCategory,
                  isExpanded: true,
                  isDense: true,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0xFF0F172A),
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
                    if (v != null) setState(() => _devCategory = v);
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
                // Bloque destacado de Conexión al Rack
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFFBEB),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFCD34D)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(
                            Icons.dns_rounded,
                            size: 14,
                            color: Color(0xFFB45309),
                          ),
                          SizedBox(width: 6),
                          Text(
                            'Rack Conectado & Cableado',
                            style: TextStyle(
                              fontSize: 11.5,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF92400E),
                            ),
                          ),
                        ],
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
                        onChanged: (v) => setState(() => _devLinkedRackId = v),
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
                          initialValue: safeLinkedOutletId,
                          isExpanded: true,
                          isDense: true,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF0F172A),
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
                          onChanged: (v) =>
                              setState(() => _devLinkedOutletId = v),
                        ),
                      ],
                    ],
                  ),
                ),
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
            'SENSORES, TOMAS Y DISPOSITIVOS CONECTADOS A ESTE RACK (${connectedDevices.length})',
            style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w900,
              color: Color(0xFF64748B),
            ),
          ),
          const SizedBox(height: 8),
          if (connectedDevices.isEmpty)
            const Text(
              'Ningún sensor, roseta o cámara vinculado aún a este Rack.',
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
            'Haz clic en cualquier sensor, cámara, roseta, PC o Rack del plano para editar sus Settings (${floor.floorDevices.length} elementos en planta).',
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
      labelStyle: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      filled: true,
      fillColor: Colors.white,
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
  final String groupName;
  final String label;
  final String prefix;
  final IconData icon;
  final Color pinColor;
  final String defaultPortHint;
  final bool isSensor;
  final int? customTypeId;

  const _FloorDeviceCatalogItem({
    required this.category,
    this.groupName = 'Industrial / A Medida',
    required this.label,
    required this.prefix,
    required this.icon,
    this.pinColor = const Color(0xFF0F172A),
    this.defaultPortHint = 'SW01:Gi1/0/1',
    this.isSensor = false,
    this.customTypeId,
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

class _FloorUndoSnapshot {
  final String description;
  final Map<int, Offset> rackPositions;
  final Map<int, Size> rackSizes;
  final Map<int, int> rackRotations;
  final Map<int, Offset> floorDevicePositions;
  final Set<int> affectedRackIds;
  final Set<int> affectedDeviceIds;

  const _FloorUndoSnapshot({
    required this.description,
    required this.rackPositions,
    required this.rackSizes,
    required this.rackRotations,
    required this.floorDevicePositions,
    required this.affectedRackIds,
    required this.affectedDeviceIds,
  });
}
