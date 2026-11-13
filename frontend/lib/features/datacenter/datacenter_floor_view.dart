import 'package:flutter/material.dart';
import '../../core/widgets/avisos.dart';
import '../../core/theme.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/api_client.dart';
import '../../core/image_file_picker.dart';
import '../../models/datacenter_models.dart';
import '../../shared/widgets/cmdb_asset_explorer_dialog.dart';
import '../../shared/widgets/diagram_exporter.dart';

part 'sections/datacenter_actions_and_dialogs.dart';
part 'sections/datacenter_canvas_2d_section.dart';
part 'sections/datacenter_inspector_panel.dart';
part 'widgets/datacenter_floor_painters.dart';

/// Editor 2D multi-planta de salas técnicas, pasillos, racks y dispositivos de planta (`2. Datacenter`).
class DatacenterFloorView extends StatefulWidget {
  final RackDocApiClient api;
  final List<LocationNode> locations;
  final int activeLocationId;
  final int? initialFloorId;
  final int? initialFloorDeviceId;
  final ValueChanged<int> onChangeLocation;
  final VoidCallback onBackToLocations;
  final ValueChanged<int> onOpenRack;
  final VoidCallback onRefresh;
  final bool isKioskMode;
  final VoidCallback? onToggleKioskMode;

  const DatacenterFloorView({
    super.key,
    required this.api,
    required this.locations,
    required this.activeLocationId,
    this.initialFloorId,
    this.initialFloorDeviceId,
    required this.onChangeLocation,
    required this.onBackToLocations,
    required this.onOpenRack,
    required this.onRefresh,
    this.isKioskMode = false,
    this.onToggleKioskMode,
  });

  @override
  State<DatacenterFloorView> createState() => _DatacenterFloorViewState();
}

class _DatacenterFloorViewState extends State<DatacenterFloorView> {
  /// Puente interno para reconstruir el estado desde extensiones `part`.
  void _rebuildState(VoidCallback fn) => setState(fn);

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
  final TextEditingController _devModelCtrl = TextEditingController();
  final TextEditingController _devSerialCtrl = TextEditingController();
  final TextEditingController _devNotesCtrl = TextEditingController();
  int? _devLinkedRackId;
  int? _devLinkedOutletId;
  String _devStatus = 'unmonitored';
  String _devCategory = 'camera';
  String? _settingsSavedBanner;
  bool _settingsSaveError = false;
  int _bannerSeq = 0;

  // 1) HEARTBEAT (Background Monitoring) para Dispositivos / Sensores de Planta
  bool _fdMonitorEnabled = false;
  Set<String> _fdEnabledMonitorSystems = {'icmp'};
  final TextEditingController _fdPingTargetCtrl = TextEditingController();
  final TextEditingController _fdPingTimeoutCtrl = TextEditingController(
    text: '1.5',
  );
  final TextEditingController _fdSshHbHostCtrl = TextEditingController();
  final TextEditingController _fdSshHbPortCtrl = TextEditingController(
    text: '22',
  );
  final TextEditingController _fdSshHbUserCtrl = TextEditingController(
    text: 'admin',
  );
  final TextEditingController _fdHttpHbUrlCtrl = TextEditingController();
  final TextEditingController _fdHttpHbExpectedCodeCtrl =
      TextEditingController(text: '200');
  final TextEditingController _fdTcpHbHostCtrl = TextEditingController();
  final TextEditingController _fdTcpHbPortCtrl = TextEditingController(
    text: '443',
  );
  final TextEditingController _fdUdpHbHostCtrl = TextEditingController();
  final TextEditingController _fdUdpHbPortCtrl = TextEditingController(
    text: '161',
  );
  final TextEditingController _fdSnmpHbHostCtrl = TextEditingController();
  final TextEditingController _fdSnmpHbPortCtrl = TextEditingController(
    text: '161',
  );
  final TextEditingController _fdSnmpHbCommunityCtrl = TextEditingController(
    text: 'public',
  );
  bool _fdPinging = false;
  Map<String, dynamic>? _fdLastPingResult;

  // 2) CONECTAR (Ejecutado desde el Frontend — independiente del Heartbeat)
  bool _fdConnectEnabled = false;
  Set<String> _fdEnabledConnectSystems = {'https'};
  final TextEditingController _fdConnSshHostCtrl = TextEditingController();
  final TextEditingController _fdConnSshPortCtrl = TextEditingController(
    text: '22',
  );
  final TextEditingController _fdConnSshUserCtrl = TextEditingController(
    text: 'admin',
  );
  final TextEditingController _fdConnHttpUrlCtrl = TextEditingController();
  final TextEditingController _fdConnHttpsUrlCtrl = TextEditingController();

  // 3) CERTSCOPE (Verificación Certificado HTTPS/TLS — sincronizado con 7. CertScope)
  bool _fdCertScopeEnabled = false;
  final TextEditingController _fdCertScopeUrlCtrl = TextEditingController();
  final TextEditingController _fdCertScopePortCtrl = TextEditingController(
    text: '443',
  );
  String _fdCertScopeRenewalType = 'manual';
  bool _fdProbingCertScope = false;
  Map<String, dynamic> _fdCertScopeSummary = {};

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
    return AppPalette.slate900;
  }

  static const List<_FloorDeviceCatalogItem> _floorDeviceCatalog = [
    // 1. FAMILIA: Sensores & Clima / Energía
    _FloorDeviceCatalogItem(
      category: 'sensor_temp',
      groupName: 'Sensores & Clima / Energía',
      label: 'Sensor Temperatura (°C)',
      prefix: 'TMP',
      icon: Icons.thermostat_rounded,
      pinColor: AppPalette.teal600,
      defaultPortHint: 'ENV-MON01:Temp-1 (21.2 °C)',
      isSensor: true,
    ),
    _FloorDeviceCatalogItem(
      category: 'sensor_humidity',
      groupName: 'Sensores & Clima / Energía',
      label: 'Sensor Humedad (%RH)',
      prefix: 'HUM',
      icon: Icons.water_drop_outlined,
      pinColor: AppPalette.sky600,
      defaultPortHint: 'ENV-MON01:Hum-1 (45 %RH)',
      isSensor: true,
    ),
    _FloorDeviceCatalogItem(
      category: 'sensor_temp_hum',
      groupName: 'Sensores & Clima / Energía',
      label: 'Sensor Temp + Humedad',
      prefix: 'TH',
      icon: Icons.device_thermostat_rounded,
      pinColor: AppPalette.teal600,
      defaultPortHint: 'ENV-MON01:TH-1 (21.0 °C / 46 %RH)',
      isSensor: true,
    ),
    _FloorDeviceCatalogItem(
      category: 'sensor_power_load',
      groupName: 'Sensores & Clima / Energía',
      label: 'Sensor Carga Eléctrica (kW/A)',
      prefix: 'PWR',
      icon: Icons.bolt_rounded,
      pinColor: AppPalette.amber600,
      defaultPortHint: 'PDU-A:Meter-1 (4.8 kW / 20.9 A)',
      isSensor: true,
    ),
    _FloorDeviceCatalogItem(
      category: 'sensor_smoke',
      groupName: 'Sensores & Clima / Energía',
      label: 'Detector Humo / Incendio',
      prefix: 'SMK',
      icon: Icons.local_fire_department_outlined,
      pinColor: AppPalette.red600,
      defaultPortHint: 'ENV-MON01:Smoke-1 (Normal)',
      isSensor: true,
    ),
    _FloorDeviceCatalogItem(
      category: 'sensor_water_leak',
      groupName: 'Sensores & Clima / Energía',
      label: 'Sensor Fuga de Agua',
      prefix: 'WTR',
      icon: Icons.waves_rounded,
      pinColor: AppPalette.sky600,
      defaultPortHint: 'ENV-MON01:Leak-1 (Seco)',
      isSensor: true,
    ),
    _FloorDeviceCatalogItem(
      category: 'sensor_airflow',
      groupName: 'Sensores & Clima / Energía',
      label: 'Sensor Flujo Aire / Presión',
      prefix: 'AIR',
      icon: Icons.air_rounded,
      pinColor: AppPalette.teal600,
      defaultPortHint: 'ENV-MON01:Airflow-1 (2.4 m/s)',
      isSensor: true,
    ),
    _FloorDeviceCatalogItem(
      category: 'sensor_door',
      groupName: 'Sensores & Clima / Energía',
      label: 'Sensor Contacto Puerta',
      prefix: 'DOR',
      icon: Icons.sensor_door_outlined,
      pinColor: AppPalette.teal600,
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
      pinColor: AppPalette.slate900,
      defaultPortHint: 'SW01:Gi1/0/21 (PoE)',
    ),
    _FloorDeviceCatalogItem(
      category: 'access_control',
      groupName: 'Seguridad & Control de Acceso',
      label: 'Access Control Panel',
      prefix: 'AC',
      icon: Icons.dialpad_rounded,
      pinColor: AppPalette.slate900,
      defaultPortHint: 'SW01:Gi1/0/24',
    ),

    // 3. FAMILIA: Red, Wi-Fi & Rosetas
    _FloorDeviceCatalogItem(
      category: 'telecom_outlet',
      groupName: 'Red, Wi-Fi & Rosetas',
      label: 'Telecommunications Outlet',
      prefix: 'Bi',
      icon: Icons.settings_input_hdmi_outlined,
      pinColor: AppPalette.slate500,
      defaultPortHint: 'PP-A:01-04',
    ),
    _FloorDeviceCatalogItem(
      category: 'access_point',
      groupName: 'Red, Wi-Fi & Rosetas',
      label: 'Access Point Wi-Fi',
      prefix: 'AP',
      icon: Icons.wifi_tethering_rounded,
      pinColor: AppPalette.slate900,
      defaultPortHint: 'SW01:Gi1/0/18 (PoE+)',
    ),
    _FloorDeviceCatalogItem(
      category: 'isp_uplink',
      groupName: 'Red, Wi-Fi & Rosetas',
      label: 'ISP Uplink / Acometida',
      prefix: 'ISP',
      icon: Icons.public_rounded,
      pinColor: AppPalette.blue900,
      defaultPortHint: 'FW01:WAN1',
    ),
    _FloorDeviceCatalogItem(
      category: 'rack',
      groupName: 'Red, Wi-Fi & Rosetas',
      label: 'Rack Cabinet',
      prefix: 'RK',
      icon: Icons.dns_outlined,
      pinColor: AppPalette.blue900,
      defaultPortHint: '',
    ),

    // 4. FAMILIA: Puestos de Trabajo & AV
    _FloorDeviceCatalogItem(
      category: 'desktop',
      groupName: 'Puestos de Trabajo & AV',
      label: 'Desktop',
      prefix: 'DP',
      icon: Icons.desktop_windows_outlined,
      pinColor: AppPalette.slate900,
      defaultPortHint: 'SW01:Gi1/0/1',
    ),
    _FloorDeviceCatalogItem(
      category: 'laptop',
      groupName: 'Puestos de Trabajo & AV',
      label: 'Laptop',
      prefix: 'LP',
      icon: Icons.laptop_mac_outlined,
      pinColor: AppPalette.slate900,
      defaultPortHint: 'SW01:Gi1/0/2',
    ),
    _FloorDeviceCatalogItem(
      category: 'phone',
      groupName: 'Puestos de Trabajo & AV',
      label: 'Phone VoIP',
      prefix: 'PH',
      icon: Icons.phone_in_talk_outlined,
      pinColor: AppPalette.slate900,
      defaultPortHint: 'SW01:Gi1/0/5 (VoIP)',
    ),
    _FloorDeviceCatalogItem(
      category: 'printer',
      groupName: 'Puestos de Trabajo & AV',
      label: 'Printer',
      prefix: 'PR',
      icon: Icons.print_outlined,
      pinColor: AppPalette.slate900,
      defaultPortHint: 'SW01:Gi1/0/8',
    ),
    _FloorDeviceCatalogItem(
      category: '3d_printer',
      groupName: 'Puestos de Trabajo & AV',
      label: '3D Printer',
      prefix: '3DP',
      icon: Icons.view_in_ar_rounded,
      pinColor: AppPalette.slate900,
      defaultPortHint: 'SW01:Gi1/0/9',
    ),
    _FloorDeviceCatalogItem(
      category: 'screen',
      groupName: 'Puestos de Trabajo & AV',
      label: 'Screen / Videowall',
      prefix: 'SC',
      icon: Icons.tv_rounded,
      pinColor: AppPalette.slate900,
      defaultPortHint: 'SW01:Gi1/0/12',
    ),
    _FloorDeviceCatalogItem(
      category: 'speaker',
      groupName: 'Puestos de Trabajo & AV',
      label: 'Speaker',
      prefix: 'SPK',
      icon: Icons.speaker_outlined,
      pinColor: AppPalette.slate900,
      defaultPortHint: 'SW01:Gi1/0/14',
    ),
    _FloorDeviceCatalogItem(
      category: 'microphone',
      groupName: 'Puestos de Trabajo & AV',
      label: 'Microphone',
      prefix: 'MIC',
      icon: Icons.mic_none_rounded,
      pinColor: AppPalette.slate900,
      defaultPortHint: 'SW01:Gi1/0/15',
    ),
    _FloorDeviceCatalogItem(
      category: 'ndi_box',
      groupName: 'Puestos de Trabajo & AV',
      label: 'NDI Box',
      prefix: 'NDI',
      icon: Icons.cast_connected_rounded,
      pinColor: AppPalette.slate900,
      defaultPortHint: 'SW01:Gi1/0/16',
    ),

    // 5. FAMILIA: Industrial / A Medida
    _FloorDeviceCatalogItem(
      category: 'custom_crac',
      groupName: 'Industrial / A Medida',
      label: 'Climatizador CRAC / InRow',
      prefix: 'CRAC',
      icon: Icons.ac_unit_rounded,
      pinColor: AppPalette.violet600,
      defaultPortHint: 'BMS:Modbus-CRAC1 (18.5 °C)',
      isSensor: true,
    ),
    _FloorDeviceCatalogItem(
      category: 'custom_ups_plant',
      groupName: 'Industrial / A Medida',
      label: 'SAI / UPS Industrial Planta',
      prefix: 'UPS',
      icon: Icons.battery_charging_full_rounded,
      pinColor: AppPalette.amber600,
      defaultPortHint: 'PDU-MAIN:Feed-A+B (98% Bat)',
      isSensor: true,
    ),
    _FloorDeviceCatalogItem(
      category: 'custom_elec_board',
      groupName: 'Industrial / A Medida',
      label: 'Cuadro Eléctrico General',
      prefix: 'CEG',
      icon: Icons.bolt_rounded,
      pinColor: AppPalette.amber600,
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
      pinColor: AppPalette.violet600,
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
    if (widget.initialFloorDeviceId != null) {
      _selectedFloorDeviceId = widget.initialFloorDeviceId;
      _showRightSettings = true;
    }
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
    if (widget.initialFloorDeviceId != null &&
        widget.initialFloorDeviceId != oldWidget.initialFloorDeviceId) {
      _selectedFloorDeviceId = widget.initialFloorDeviceId;
      _selectedRackIds.clear();
      _showRightSettings = true;
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
    _devModelCtrl.dispose();
    _devSerialCtrl.dispose();
    _devNotesCtrl.dispose();
    _fdPingTargetCtrl.dispose();
    _fdPingTimeoutCtrl.dispose();
    _fdSshHbHostCtrl.dispose();
    _fdSshHbPortCtrl.dispose();
    _fdSshHbUserCtrl.dispose();
    _fdHttpHbUrlCtrl.dispose();
    _fdHttpHbExpectedCodeCtrl.dispose();
    _fdTcpHbHostCtrl.dispose();
    _fdTcpHbPortCtrl.dispose();
    _fdUdpHbHostCtrl.dispose();
    _fdUdpHbPortCtrl.dispose();
    _fdSnmpHbHostCtrl.dispose();
    _fdSnmpHbPortCtrl.dispose();
    _fdSnmpHbCommunityCtrl.dispose();
    _fdConnSshHostCtrl.dispose();
    _fdConnSshPortCtrl.dispose();
    _fdConnSshUserCtrl.dispose();
    _fdConnHttpUrlCtrl.dispose();
    _fdConnHttpsUrlCtrl.dispose();
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
    _devModelCtrl.text = (dev.customFields['model_name'] ?? '').toString();
    _devSerialCtrl.text =
        (dev.customFields['serial_number'] ?? dev.customFields['serial_or_uuid'] ?? '').toString();
    _devNotesCtrl.text = dev.notes;
    _devLinkedRackId = dev.linkedRackId;
    _devLinkedOutletId = dev.linkedOutletId;
    _fdMonitorEnabled = dev.monitoringEnabled;
    _devStatus = !dev.monitoringEnabled
        ? 'unmonitored'
        : (dev.status.isEmpty ? 'online' : dev.status);

    final baseHost = dev.ipAddress.trim().isNotEmpty
        ? dev.ipAddress.trim()
        : dev.fqdn.trim();
    final hbCfgRaw = dev.customFields['heartbeat_config'];
    final hbCfg = hbCfgRaw is Map
        ? Map<String, dynamic>.from(hbCfgRaw)
        : <String, dynamic>{};

    final rawHbSystems = hbCfg['enabled_systems'];
    if (rawHbSystems is List && rawHbSystems.isNotEmpty) {
      _fdEnabledMonitorSystems = rawHbSystems
          .map((e) => e.toString().toLowerCase())
          .toSet();
    } else {
      _fdEnabledMonitorSystems = {
        dev.monitorMethod.isEmpty ? 'icmp' : dev.monitorMethod,
      };
    }

    _fdPingTargetCtrl.text = (hbCfg['icmp_target'] ?? baseHost).toString();
    _fdPingTimeoutCtrl.text = (hbCfg['icmp_timeout_s'] ?? '1.5').toString();
    _fdSshHbHostCtrl.text = (hbCfg['ssh_host'] ?? baseHost).toString();
    _fdSshHbPortCtrl.text = (hbCfg['ssh_port'] ?? '22').toString();
    _fdSshHbUserCtrl.text = (hbCfg['ssh_user'] ?? 'admin').toString();

    final defaultWebUrl = baseHost.isNotEmpty ? 'https://$baseHost' : '';
    _fdHttpHbUrlCtrl.text = (hbCfg['http_url'] ?? defaultWebUrl).toString();
    _fdHttpHbExpectedCodeCtrl.text =
        (hbCfg['http_expected_code'] ?? '200').toString();

    _fdTcpHbHostCtrl.text = (hbCfg['tcp_host'] ?? baseHost).toString();
    _fdTcpHbPortCtrl.text =
        (hbCfg['tcp_port'] ?? (dev.monitorPort > 0 ? dev.monitorPort : 443))
            .toString();

    _fdUdpHbHostCtrl.text = (hbCfg['udp_host'] ?? baseHost).toString();
    _fdUdpHbPortCtrl.text = (hbCfg['udp_port'] ?? '161').toString();

    _fdSnmpHbHostCtrl.text = (hbCfg['snmp_host'] ?? baseHost).toString();
    _fdSnmpHbPortCtrl.text = (hbCfg['snmp_port'] ?? '161').toString();
    _fdSnmpHbCommunityCtrl.text =
        (hbCfg['snmp_community'] ?? 'public').toString();

    final connCfgRaw = dev.customFields['connect_config'];
    final connCfg = connCfgRaw is Map
        ? Map<String, dynamic>.from(connCfgRaw)
        : <String, dynamic>{};
    _fdConnectEnabled = connCfg['enabled'] == true;
    final rawConnSystems = connCfg['enabled_systems'];
    if (rawConnSystems is List && rawConnSystems.isNotEmpty) {
      _fdEnabledConnectSystems = rawConnSystems
          .map((e) => e.toString().toLowerCase())
          .toSet();
    } else {
      _fdEnabledConnectSystems = {'https'};
    }
    _fdConnSshHostCtrl.text = (connCfg['ssh_host'] ?? baseHost).toString();
    _fdConnSshPortCtrl.text = (connCfg['ssh_port'] ?? '22').toString();
    _fdConnSshUserCtrl.text = (connCfg['ssh_user'] ?? 'admin').toString();
    _fdConnHttpUrlCtrl.text = (connCfg['http_url'] ??
            (baseHost.isNotEmpty ? 'http://$baseHost' : ''))
        .toString();
    _fdConnHttpsUrlCtrl.text = (connCfg['https_url'] ??
            (baseHost.isNotEmpty ? 'https://$baseHost' : ''))
        .toString();

    final csRaw = dev.customFields['certscope_config'];
    final csCfg = csRaw is Map
        ? Map<String, dynamic>.from(csRaw)
        : <String, dynamic>{};
    if (csCfg.containsKey('enabled')) {
      _fdCertScopeEnabled = csCfg['enabled'] == true;
    } else {
      _fdCertScopeEnabled =
          (_fdConnectEnabled && _fdEnabledConnectSystems.contains('https')) ||
          (_fdEnabledMonitorSystems.contains('http') &&
              _fdHttpHbUrlCtrl.text.trim().toLowerCase().startsWith('https://'));
    }
    _fdCertScopeUrlCtrl.text = (csCfg['url'] ??
            csCfg['target_url'] ??
            _fdConnHttpsUrlCtrl.text)
        .toString();
    _fdCertScopePortCtrl.text = (csCfg['port'] ?? 443).toString();
    _fdCertScopeRenewalType =
        (csCfg['renewal_type'] ?? 'manual').toString() == 'auto_acme'
            ? 'auto_acme'
            : 'manual';
    _fdCertScopeSummary = csCfg;

    _fdLastPingResult = null;
  }

  Map<String, dynamic> _buildFloorDevicePayload(FloorDeviceNode? currentDev) {
    final existingCustom = currentDev != null
        ? Map<String, dynamic>.from(currentDev.customFields)
        : <String, dynamic>{};
    existingCustom['model_name'] = _devModelCtrl.text.trim();
    existingCustom['serial_number'] = _devSerialCtrl.text.trim();
    final baseHost = _devIpCtrl.text.trim();
    existingCustom['heartbeat_config'] = {
      'enabled_systems': _fdEnabledMonitorSystems.toList(),
      'icmp_target': _fdPingTargetCtrl.text.trim().isEmpty
          ? baseHost
          : _fdPingTargetCtrl.text.trim(),
      'icmp_timeout_s':
          double.tryParse(_fdPingTimeoutCtrl.text.trim()) ?? 1.5,
      'ssh_host': _fdSshHbHostCtrl.text.trim().isEmpty
          ? baseHost
          : _fdSshHbHostCtrl.text.trim(),
      'ssh_port': int.tryParse(_fdSshHbPortCtrl.text.trim()) ?? 22,
      'ssh_user': _fdSshHbUserCtrl.text.trim().isEmpty
          ? 'admin'
          : _fdSshHbUserCtrl.text.trim(),
      'http_url': _fdHttpHbUrlCtrl.text.trim(),
      'http_expected_code':
          int.tryParse(_fdHttpHbExpectedCodeCtrl.text.trim()) ?? 200,
      'tcp_host': _fdTcpHbHostCtrl.text.trim().isEmpty
          ? baseHost
          : _fdTcpHbHostCtrl.text.trim(),
      'tcp_port': int.tryParse(_fdTcpHbPortCtrl.text.trim()) ?? 443,
      'udp_host': _fdUdpHbHostCtrl.text.trim().isEmpty
          ? baseHost
          : _fdUdpHbHostCtrl.text.trim(),
      'udp_port': int.tryParse(_fdUdpHbPortCtrl.text.trim()) ?? 161,
      'snmp_host': _fdSnmpHbHostCtrl.text.trim().isEmpty
          ? baseHost
          : _fdSnmpHbHostCtrl.text.trim(),
      'snmp_port': int.tryParse(_fdSnmpHbPortCtrl.text.trim()) ?? 161,
      'snmp_community': _fdSnmpHbCommunityCtrl.text.trim().isEmpty
          ? 'public'
          : _fdSnmpHbCommunityCtrl.text.trim(),
    };
    existingCustom['connect_config'] = {
      'enabled': _fdConnectEnabled,
      'enabled_systems': _fdEnabledConnectSystems.toList(),
      'ssh_host': _fdConnSshHostCtrl.text.trim(),
      'ssh_port': int.tryParse(_fdConnSshPortCtrl.text.trim()) ?? 22,
      'ssh_user': _fdConnSshUserCtrl.text.trim().isEmpty
          ? 'admin'
          : _fdConnSshUserCtrl.text.trim(),
      'http_url': _fdConnHttpUrlCtrl.text.trim(),
      'https_url': _fdConnHttpsUrlCtrl.text.trim(),
    };
    final prevCs = existingCustom['certscope_config'] is Map
        ? Map<String, dynamic>.from(existingCustom['certscope_config'] as Map)
        : <String, dynamic>{};
    final csUrl = _fdCertScopeUrlCtrl.text.trim().isNotEmpty
        ? _fdCertScopeUrlCtrl.text.trim()
        : (_fdConnHttpsUrlCtrl.text.trim().isNotEmpty
            ? _fdConnHttpsUrlCtrl.text.trim()
            : (baseHost.isNotEmpty ? 'https://$baseHost/' : ''));
    existingCustom['certscope_config'] = {
      ...prevCs,
      ..._fdCertScopeSummary,
      'enabled': _fdCertScopeEnabled,
      'url': csUrl,
      'target_url': csUrl,
      'port': int.tryParse(_fdCertScopePortCtrl.text.trim()) ?? 443,
      'renewal_type': _fdCertScopeRenewalType,
    };

    final primaryMethod = _fdEnabledMonitorSystems.isNotEmpty
        ? _fdEnabledMonitorSystems.first
        : 'icmp';
    int primaryPort = 22;
    if (primaryMethod == 'ssh') {
      primaryPort = int.tryParse(_fdSshHbPortCtrl.text.trim()) ?? 22;
    } else if (primaryMethod == 'http') {
      primaryPort =
          _fdHttpHbUrlCtrl.text.trim().startsWith('http://') ? 80 : 443;
    } else if (primaryMethod == 'tcp') {
      primaryPort = int.tryParse(_fdTcpHbPortCtrl.text.trim()) ?? 443;
    } else if (primaryMethod == 'udp') {
      primaryPort = int.tryParse(_fdUdpHbPortCtrl.text.trim()) ?? 161;
    } else if (primaryMethod == 'snmp') {
      primaryPort = int.tryParse(_fdSnmpHbPortCtrl.text.trim()) ?? 161;
    }

    return {
      'device_type': _devCategory,
      'code': _devCodeCtrl.text.trim(),
      'name': _devNameCtrl.text.trim(),
      'room_code': _devRoomCodeCtrl.text.trim(),
      'ip_address': _devIpCtrl.text.trim(),
      'vlan': int.tryParse(_devVlanCtrl.text.trim()),
      'status': _fdMonitorEnabled ? _devStatus : 'unmonitored',
      'monitoring_enabled': _fdMonitorEnabled,
      'monitor_method': primaryMethod,
      'monitor_port': primaryPort,
      'custom_fields': existingCustom,
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
    };
  }

  Future<void> _toggleFloorDeviceHeartbeat(
    FloorDeviceNode dev,
    bool enabled,
  ) async {
    setState(() {
      _fdMonitorEnabled = enabled;
      if (!enabled) {
        _devStatus = 'unmonitored';
        _fdLastPingResult = null;
      } else if (_fdEnabledMonitorSystems.isEmpty) {
        _fdEnabledMonitorSystems = {'icmp'};
      }
    });
    await _saveSelectedFloorDeviceSettings(
      customToast: enabled
          ? '✓ Heartbeat activado en background para "${dev.code}".'
          : '⚪ Heartbeat desactivado (Gris) para "${dev.code}".',
    );
  }

  Future<void> _testFloorDeviceHeartbeatNow(FloorDeviceNode dev) async {
    setState(() => _fdPinging = true);
    try {
      await widget.api.updateFloorDevice(dev.id, _buildFloorDevicePayload(dev));
      final res = await widget.api.pingFloorDevice(dev.id);
      if (mounted) {
        final newStatus = (res['status'] ?? 'offline').toString();
        setState(() {
          _fdLastPingResult = res;
          _devStatus = newStatus;
          _editingDeviceId = null;
        });
        widget.onRefresh();
        _showInlineSettingsBanner(
          newStatus == 'online'
              ? '🟢 Heartbeat OK en "${dev.code}" (${res['last_ping_ms'] ?? '-'} ms)'
              : (newStatus == 'warning'
                  ? '🟠 Heartbeat parcial (Naranja) en "${dev.code}"'
                  : '🔴 Heartbeat fallido (Rojo) en "${dev.code}"'),
          isError: newStatus == 'offline',
        );
      }
    } catch (e) {
      if (mounted) {
        _showInlineSettingsBanner('Error en Probar ahora: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _fdPinging = false);
    }
  }

  Future<void> _probeFloorDeviceCertScopeNow(FloorDeviceNode dev) async {
    final baseHost = _devIpCtrl.text.trim();
    final rawTarget = _fdCertScopeUrlCtrl.text.trim().isNotEmpty
        ? _fdCertScopeUrlCtrl.text.trim()
        : (_fdConnHttpsUrlCtrl.text.trim().isNotEmpty
            ? _fdConnHttpsUrlCtrl.text.trim()
            : baseHost);
    if (rawTarget.isEmpty) {
      _showInlineSettingsBanner(
        'Indica primero la IP o URL HTTPS del dispositivo en planta.',
        isError: true,
      );
      return;
    }
    final port = int.tryParse(_fdCertScopePortCtrl.text.trim()) ?? 443;
    setState(() => _fdProbingCertScope = true);
    try {
      final res = await widget.api.probeCertificate({
        'target_host': rawTarget,
        'port': port,
      });
      if (!mounted) return;
      setState(() {
        if (res['port'] != null) {
          _fdCertScopePortCtrl.text = '${res['port']}';
        }
        _fdCertScopeSummary = {
          ..._fdCertScopeSummary,
          'enabled': _fdCertScopeEnabled,
          'port': res['port'] ?? port,
          'status': res['status'] ?? (res['ok'] == true ? 'valid' : 'unreachable'),
          'days_remaining': res['days_remaining'],
          'common_name': res['common_name'] ?? '',
          'issuer_cn': res['issuer_cn'] ?? '',
          'valid_until': res['valid_until'] ?? '',
          'last_error': res['error'] ?? '',
        };
      });
      await widget.api.updateFloorDevice(dev.id, _buildFloorDevicePayload(dev));
      widget.onRefresh();
      if (mounted) {
        if (res['ok'] == true) {
          _showInlineSettingsBanner(
            '🔒 Certificado HTTPS verificado (${res['days_remaining']} días restantes) y sincronizado en 7. CertScope',
          );
        } else {
          _showInlineSettingsBanner(
            '🔒 Registrado en 7. CertScope (sin respuesta TLS en :$port): ${res['error'] ?? 'Revisa conectividad'}',
            isError: true,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        _showInlineSettingsBanner('Error analizando certificado HTTPS: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _fdProbingCertScope = false);
    }
  }

  Future<void> _launchFloorDeviceConnect(String proto) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (proto == 'ssh') {
        final host = _fdConnSshHostCtrl.text.trim().isNotEmpty
            ? _fdConnSshHostCtrl.text.trim()
            : _devIpCtrl.text.trim();
        if (host.isEmpty) {
          messenger.aviso('Indica el Host/IP para Conectar SSH.');
          return;
        }
        final user = _fdConnSshUserCtrl.text.trim().isEmpty
            ? 'admin'
            : _fdConnSshUserCtrl.text.trim();
        final port = int.tryParse(_fdConnSshPortCtrl.text.trim()) ?? 22;
        final sshCmd =
            port == 22 ? 'ssh $user@$host' : 'ssh -p $port $user@$host';
        await Clipboard.setData(ClipboardData(text: sshCmd));
        final uri = Uri.parse('ssh://$user@$host:$port');
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (mounted) {
          messenger.showSnackBar(
            SnackBar(
              content: Text('Abriendo SSH ($sshCmd copiado al portapapeles)'),
              backgroundColor: AppPalette.slate900,
            ),
          );
        }
      } else if (proto == 'http') {
        String raw = _fdConnHttpUrlCtrl.text.trim();
        if (raw.isEmpty && _devIpCtrl.text.trim().isNotEmpty) {
          raw = 'http://${_devIpCtrl.text.trim()}';
        }
        if (raw.isEmpty) return;
        if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
          raw = 'http://$raw';
        }
        await launchUrl(Uri.parse(raw), mode: LaunchMode.externalApplication);
      } else if (proto == 'https') {
        String raw = _fdConnHttpsUrlCtrl.text.trim();
        if (raw.isEmpty && _devIpCtrl.text.trim().isNotEmpty) {
          raw = 'https://${_devIpCtrl.text.trim()}';
        }
        if (raw.isEmpty) return;
        if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
          raw = 'https://$raw';
        }
        await launchUrl(Uri.parse(raw), mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      if (mounted) {
        messenger.aviso('No se pudo abrir la conexión: $e');
      }
    }
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
      color: AppPalette.slate100,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. CABECERA DEL DATACENTER + SELECTOR DE SEDE + PESTAÑAS DE PLANTAS DEL EDIFICIO
          if (!widget.isKioskMode)
            _buildCabeceraDatacenter(loc, floor),

          // 2. BARRA DE CONTROLES DE LA VISTA DE PLANTA (oculta en Modo Kiosco)
          if (floor != null && !widget.isKioskMode)
            _buildBarraControlesPlanta(floor, floorRacks),

          // 3. ÁREA PRINCIPAL: [DEVICES LIBRARY (Izq)] + [LIENZO DE PLANTA 2D (Centro)] + [SETTINGS (Der)]
          _buildAreaPrincipal(floor, floorRacks, floorImageUrl),
        ],
      ),
    );
  }
}
