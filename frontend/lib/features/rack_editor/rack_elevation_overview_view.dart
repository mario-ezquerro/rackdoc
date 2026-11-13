import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/api_client.dart';
import '../../core/theme.dart';
import '../../models/datacenter_models.dart';
import 'widgets/cable_painter.dart';

/// Vista previa panorámica de **Alzado Frontal Multi-Rack** (*Row / Room Elevation*).
///
/// Muestra todos los armarios Rack (filtrables por Sede o globales) de frente y en paralelo
/// junto con su bandeja aérea superior y todas sus conexiones Intra-Rack e Inter-Rack.
/// Al pulsar sobre cualquier armario o sobre un equipo concreto se abre [`RackEditorView`].
class RackElevationOverviewView extends StatefulWidget {
  final RackDocApiClient api;
  final int? activeLocationId;
  final void Function(int rackId, {int? highlightDeviceId}) onOpenRack;
  final bool isKioskMode;
  final VoidCallback? onToggleKioskMode;

  const RackElevationOverviewView({
    super.key,
    required this.api,
    this.activeLocationId,
    required this.onOpenRack,
    this.isKioskMode = false,
    this.onToggleKioskMode,
  });

  @override
  State<RackElevationOverviewView> createState() =>
      _RackElevationOverviewViewState();
}

class _RackElevationOverviewViewState extends State<RackElevationOverviewView> {
  bool _loading = true;
  String? _error;

  /// `null` equivale a "Todas las Sedes".
  int? _selectedLocationId;
  bool _initializedLocation = false;

  List<Map<String, dynamic>> _locationsSummary = [];
  List<RackDetailModel> _racks = [];
  List<ConnectionModel> _connections = [];

  /// Modo de trazado Inter-Rack: `'trunk'` (mazo agrupado + rayos X al pasar ratón) o `'wires'` (hilo a hilo).
  String _interRackViewMode = 'wires';

  /// Filtro de categoría de cable: `'all'` | `'network'` | `'fiber'` | `'power'` | `'inter_rack'`.
  String _cableFilter = 'all';

  int? _hoveredRackId;
  int? _hoveredDeviceId;

  final TransformationController _transformController =
      TransformationController();
  Size _lastViewportSize = Size.zero;

  // Geometría constante del lienzo panorámico de alzado frontal
  static const double _marginX = 64.0;
  static const double _trayTop = 28.0;
  static const double _trayHeight = 96.0;
  static const double _headerCardTop = 148.0;
  static const double _headerCardHeight = 82.0;
  static const double _cabinetTop = 242.0;
  static const double _rackOuterWidth = 372.0;
  static const double _railWidth = 26.0;
  static const double _rackInnerWidth = _rackOuterWidth - _railWidth * 2;
  static const double _rackGap = 96.0;
  static const double _uHeightPx = 22.0;
  static const double _bottomPadding = 68.0;

  @override
  void initState() {
    super.initState();
    _selectedLocationId = widget.activeLocationId;
    _initializedLocation = true;
    _loadOverview();
  }

  @override
  void didUpdateWidget(covariant RackElevationOverviewView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_initializedLocation &&
        widget.activeLocationId != oldWidget.activeLocationId) {
      _selectedLocationId = widget.activeLocationId;
      _loadOverview();
    }
  }

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  Future<void> _loadOverview() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.api.getRacksElevationOverview(
        locationId: _selectedLocationId,
      );
      final locsRaw = (data['locations'] ?? []) as List;
      final racksRaw = (data['racks'] ?? []) as List;
      final connsRaw = (data['connections'] ?? []) as List;

      var parsedRacks = racksRaw
          .map((e) => RackDetailModel.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      var parsedConns = connsRaw
          .map((e) => ConnectionModel.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
      final parsedLocs = locsRaw
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();

      // Si la sede filtrada inicialmente no tiene racks pero existen racks en otras sedes, mostrar todos
      if (parsedRacks.isEmpty && _selectedLocationId != null) {
        final fallback = await widget.api.getRacksElevationOverview();
        final fbRacks = ((fallback['racks'] ?? []) as List)
            .map((e) =>
                RackDetailModel.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        if (fbRacks.isNotEmpty) {
          _selectedLocationId = null;
          parsedRacks = fbRacks;
          parsedConns = ((fallback['connections'] ?? []) as List)
              .map((e) =>
                  ConnectionModel.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList();
        }
      }

      if (!mounted) return;
      final interCount = parsedConns.where((c) => c.isOutbound).length;
      setState(() {
        _locationsSummary = parsedLocs;
        _racks = parsedRacks;
        _connections = parsedConns;
        _interRackViewMode = interCount > 24 ? 'trunk' : 'wires';
        _loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _fitCameraToViewport();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  int get _maxUnits {
    int maxU = 42;
    for (final r in _racks) {
      if (r.totalUnits > maxU) maxU = r.totalUnits;
    }
    return maxU;
  }

  double get _canvasWidth {
    if (_racks.isEmpty) return 1100.0;
    return _marginX * 2 +
        _racks.length * _rackOuterWidth +
        math.max(0, _racks.length - 1) * _rackGap;
  }

  double get _canvasHeight =>
      _cabinetTop + _maxUnits * _uHeightPx + _bottomPadding;

  double _rackLeft(int index) =>
      _marginX + index * (_rackOuterWidth + _rackGap);

  void _fitCameraToViewport() {
    if (!mounted || _racks.isEmpty || _lastViewportSize == Size.zero) return;
    final vw = _lastViewportSize.width;
    final vh = _lastViewportSize.height;
    if (vw <= 40 || vh <= 40) return;

    final cw = _canvasWidth;
    final ch = _canvasHeight;
    final scaleX = (vw - 32.0) / cw;
    final scaleY = (vh - 24.0) / ch;
    final scale = math.min(scaleX, scaleY).clamp(0.28, 1.12);

    final dx = math.max(12.0, (vw - cw * scale) / 2.0);
    final dy = math.max(8.0, (vh - ch * scale) / 2.0);

    final matrix = Matrix4.identity();
    matrix.storage[0] = scale;
    matrix.storage[5] = scale;
    matrix.storage[10] = 1.0;
    matrix.storage[12] = dx;
    matrix.storage[13] = dy;
    _transformController.value = matrix;
  }

  List<ConnectionModel> get _filteredConnections {
    return _connections.where((c) {
      if (_cableFilter == 'all') return true;
      if (_cableFilter == 'inter_rack') return c.isOutbound;
      return c.categoryGroup == _cableFilter;
    }).toList();
  }

  /// Calcula la posición exacta en el lienzo global para cada `portId` y para cada `deviceId`.
  ({Map<int, Offset> portOffsets, Map<int, Offset> deviceOffsets})
      _computeGlobalAnchors() {
    final portOffsets = <int, Offset>{};
    final deviceOffsets = <int, Offset>{};

    for (int rIdx = 0; rIdx < _racks.length; rIdx++) {
      final rack = _racks[rIdx];
      final outerL = _rackLeft(rIdx);
      final innerL = outerL + _railWidth;

      for (final dev in rack.devices) {
        if (dev.isExternalFeed) continue;
        final topU = dev.endU.clamp(1, rack.totalUnits);
        final devTop =
            _cabinetTop + (rack.totalUnits - topU) * _uHeightPx;
        final devH = dev.uHeight * _uHeightPx;
        final center = Offset(innerL + _rackInnerWidth * 0.78, devTop + devH / 2);
        deviceOffsets[dev.id] = center;

        // Zona derecha del frontal reservada a la tira de bocas miniatura (56%..96% del ancho interior)
        final portStripLeft = innerL + _rackInnerWidth * 0.54;
        final portStripWidth = _rackInnerWidth * 0.42;
        for (final p in dev.ports) {
          final px = portStripLeft + p.relX.clamp(0.05, 0.95) * portStripWidth;
          final py = devTop + p.relY.clamp(0.20, 0.80) * devH;
          portOffsets[p.id] = Offset(px, py);
        }
      }
    }
    return (portOffsets: portOffsets, deviceOffsets: deviceOffsets);
  }

  Color _deviceCategoryAccent(String category) {
    switch (category.toLowerCase()) {
      case 'switch':
      case 'san_switch':
        return AppPalette.sky400;
      case 'router':
      case 'gateway':
        return AppPalette.sky600;
      case 'firewall':
        return AppPalette.red600;
      case 'server':
        return AppPalette.indigo600;
      case 'storage_san':
      case 'storage_nas':
        return AppPalette.violet600;
      case 'pdu':
      case 'ups':
        return AppPalette.amber500;
      default:
        return AppPalette.slate500;
    }
  }

  Color _heartbeatColor(RackDeviceModel dev) {
    if (!dev.monitoringEnabled) return AppPalette.slate400;
    switch (dev.status) {
      case 'online':
        return AppPalette.emerald500;
      case 'offline':
        return AppPalette.red600;
      default:
        return AppPalette.amber500;
    }
  }

  @override
  Widget build(BuildContext context) {
    final visibleConns = _filteredConnections;
    final totalDevices = _racks.fold<int>(
      0,
      (sum, r) => sum + r.devices.where((d) => !d.isExternalFeed).length,
    );
    final interRackCount = visibleConns.where((c) => c.isOutbound).length;
    final intraRackCount = visibleConns.length - interRackCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.isKioskMode)
          _buildFullWidthHeader(
            totalDevices: totalDevices,
            intraCount: intraRackCount,
            interCount: interRackCount,
          ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? _buildErrorState()
                  : _racks.isEmpty
                      ? _buildEmptyState()
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            final newSize = Size(
                              constraints.maxWidth,
                              constraints.maxHeight,
                            );
                            if ((_lastViewportSize.width - newSize.width)
                                        .abs() >
                                    4 ||
                                (_lastViewportSize.height - newSize.height)
                                        .abs() >
                                    4) {
                              final wasZero = _lastViewportSize == Size.zero;
                              _lastViewportSize = newSize;
                              if (wasZero) {
                                WidgetsBinding.instance.addPostFrameCallback(
                                  (_) => _fitCameraToViewport(),
                                );
                              }
                            }
                            return SelectionContainer.disabled(
                              child: Container(
                                color: const Color(0xFFF1F5F9),
                                child: Stack(
                                  children: [
                                    InteractiveViewer(
                                      transformationController:
                                          _transformController,
                                      constrained: false,
                                      boundaryMargin:
                                          const EdgeInsets.all(420),
                                      minScale: 0.22,
                                      maxScale: 2.8,
                                      child: _buildElevationCanvas(visibleConns),
                                    ),
                                    _buildBottomHintOrHoverHud(visibleConns),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
        ),
      ],
    );
  }

  Widget _buildFullWidthHeader({
    required int totalDevices,
    required int intraCount,
    required int interCount,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: AppPalette.slate200)),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 10,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // Título + KPIs compactos
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppPalette.slate900,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.view_column_rounded,
                  color: AppPalette.sky400,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Alzado Frontal de Racks y Conexiones',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: AppPalette.slate900,
                        ),
                      ),
                      const SizedBox(width: 10),
                      _buildKpiBadge(
                        '${_racks.length} Racks',
                        AppPalette.blue700,
                        AppPalette.blue50,
                      ),
                      const SizedBox(width: 6),
                      _buildKpiBadge(
                        '$totalDevices Equipos',
                        AppPalette.slate700,
                        AppPalette.slate100,
                      ),
                      const SizedBox(width: 6),
                      _buildKpiBadge(
                        '$interCount Inter-Rack • $intraCount Locales',
                        const Color(0xFF0369A1),
                        const Color(0xFFE0F2FE),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'Pulsa sobre cualquier Rack o sobre un equipo concreto para abrir su Editor CAD 42U detallado (Front / Back).',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: AppPalette.slate500,
                    ),
                  ),
                ],
              ),
            ],
          ),

          // Controles de Sede, Modo Troncal/Hilo, Filtro de Cable y Cámara
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // Selector de Sede
              SizedBox(
                width: 240,
                height: 34,
                child: DropdownButtonFormField<int?>(
                  key: ValueKey<int?>(_selectedLocationId),
                  initialValue: _locationsSummary.any(
                    (l) => l['id'] == _selectedLocationId,
                  )
                      ? _selectedLocationId
                      : null,
                  isExpanded: true,
                  decoration: InputDecoration(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 0,
                    ),
                    prefixIcon: const Icon(
                      Icons.domain_rounded,
                      size: 16,
                      color: AppPalette.slate600,
                    ),
                    filled: true,
                    fillColor: AppPalette.slate50,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppPalette.slate300),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: const BorderSide(color: AppPalette.slate300),
                    ),
                  ),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppPalette.slate800,
                  ),
                  items: [
                    const DropdownMenuItem<int?>(
                      value: null,
                      child: Text(
                        'Todas las Sedes',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    for (final loc in _locationsSummary)
                      DropdownMenuItem<int?>(
                        value: loc['id'] as int,
                        child: Text(
                          '${loc['code']} — ${loc['name']} (${loc['racks_count']})',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (val) {
                    setState(() => _selectedLocationId = val);
                    _loadOverview();
                  },
                ),
              ),

              // Conmutador Troncal vs Hilo a Hilo
              Container(
                height: 34,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: AppPalette.slate100,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppPalette.slate300),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildModeSegment(
                      label: 'Troncal',
                      icon: Icons.linear_scale_rounded,
                      selected: _interRackViewMode == 'trunk',
                      tooltip:
                          'Agrupa los mazos entre Racks en la bandeja superior e ilumina hilos al pasar el ratón',
                      onTap: () => setState(() => _interRackViewMode = 'trunk'),
                    ),
                    _buildModeSegment(
                      label: 'Hilo a Hilo',
                      icon: Icons.cable_rounded,
                      selected: _interRackViewMode == 'wires',
                      tooltip:
                          'Dibuja cada latiguillo y fibra individual de boca a boca',
                      onTap: () => setState(() => _interRackViewMode = 'wires'),
                    ),
                  ],
                ),
              ),

              // Filtro rápido de tipo de cable
              Container(
                height: 34,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: AppPalette.slate50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppPalette.slate300),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildFilterChip('all', 'Todos'),
                    _buildFilterChip('inter_rack', 'Inter-Rack'),
                    _buildFilterChip('fiber', 'Fibra'),
                    _buildFilterChip('network', 'UTP'),
                    _buildFilterChip('power', 'Energía'),
                  ],
                ),
              ),

              OutlinedButton.icon(
                onPressed: _fitCameraToViewport,
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                ),
                icon: const Icon(Icons.fit_screen_rounded, size: 16),
                label: const Text(
                  'Encajar',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                onPressed: _loadOverview,
                tooltip: 'Actualizar alzado y conexiones',
                icon: const Icon(Icons.refresh_rounded, size: 19),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildKpiBadge(String text, Color fg, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: fg,
        ),
      ),
    );
  }

  Widget _buildModeSegment({
    required String label,
    required IconData icon,
    required bool selected,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: selected ? AppPalette.slate900 : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 14,
                color: selected ? AppPalette.sky400 : AppPalette.slate600,
              ),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: selected ? Colors.white : AppPalette.slate700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilterChip(String key, String label) {
    final active = _cableFilter == key;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => setState(() => _cableFilter = key),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: active ? AppPalette.blue700 : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: active ? Colors.white : AppPalette.slate600,
          ),
        ),
      ),
    );
  }

  Widget _buildElevationCanvas(List<ConnectionModel> visibleConns) {
    final anchors = _computeGlobalAnchors();
    final portColors = <int, Color>{};
    for (final c in visibleConns) {
      final col = CableGeometryBuilder.parseHexColor(c.colorHex);
      portColors[c.sourcePortId] = col;
      portColors[c.targetPortId] = col;
    }

    final rackIndexById = <int, int>{
      for (int i = 0; i < _racks.length; i++) _racks[i].id: i,
    };

    return SizedBox(
      width: _canvasWidth,
      height: _canvasHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 1. Bandeja portacables aérea superior (Overhead Cable Tray)
          Positioned(
            left: _marginX - 18,
            top: _trayTop,
            width: _canvasWidth - (_marginX - 18) * 2,
            height: _trayHeight,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFFE2E8F0),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppPalette.slate400, width: 1.2),
              ),
              child: Stack(
                children: [
                  Positioned(
                    left: 12,
                    top: 6,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.settings_ethernet_rounded,
                          size: 13,
                          color: AppPalette.slate600,
                        ),
                        const SizedBox(width: 5),
                        Text(
                          'BANDEJA PORTACABLES AÉREA INTER-RACK (${visibleConns.where((c) => c.isOutbound).length} enlaces entre armarios)',
                          style: const TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.6,
                            color: AppPalette.slate600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Bajantes verticales desde la bandeja aérea hacia el techo de cada Rack
          for (int i = 0; i < _racks.length; i++)
            Positioned(
              left: _rackLeft(i) + _rackOuterWidth / 2 - 22,
              top: _trayTop + _trayHeight - 2,
              width: 44,
              height: _cabinetTop - (_trayTop + _trayHeight) + 4,
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFCBD5E1).withValues(alpha: 0.45),
                  border: const Border.symmetric(
                    vertical: BorderSide(color: AppPalette.slate400, width: 1),
                  ),
                ),
              ),
            ),

          // 2. Bastidores frontales de todos los Racks
          for (int i = 0; i < _racks.length; i++)
            ..._buildSingleRackFrontColumn(
              index: i,
              rack: _racks[i],
              portColors: portColors,
              visibleConns: visibleConns,
            ),

          // 3. Capa vectorial superior de cables Intra-Rack e Inter-Rack (IgnorePointer para permitir clic en racks/equipos)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _MultiRackElevationCablePainter(
                  racks: _racks,
                  rackIndexById: rackIndexById,
                  rackLeftOf: _rackLeft,
                  rackOuterWidth: _rackOuterWidth,
                  railWidth: _railWidth,
                  trayTop: _trayTop + 24.0,
                  trayBottom: _trayTop + _trayHeight - 10.0,
                  connections: visibleConns,
                  portOffsets: anchors.portOffsets,
                  deviceOffsets: anchors.deviceOffsets,
                  interRackMode: _interRackViewMode,
                  hoveredRackId: _hoveredRackId,
                  hoveredDeviceId: _hoveredDeviceId,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildSingleRackFrontColumn({
    required int index,
    required RackDetailModel rack,
    required Map<int, Color> portColors,
    required List<ConnectionModel> visibleConns,
  }) {
    final left = _rackLeft(index);
    final innerLeft = left + _railWidth;
    final cabHeight = rack.totalUnits * _uHeightPx;
    final isRackHovered = _hoveredRackId == rack.id;

    final frontDevices = rack.devices
        .where((d) => !d.isExternalFeed && d.isVisibleOnFace('front'))
        .toList();
    final usedUnits = <int>{};
    for (final d in frontDevices) {
      for (int u = d.startU; u <= d.endU; u++) {
        usedUnits.add(u);
      }
    }
    final rackConnCount = visibleConns
        .where(
          (c) =>
              c.sourceInfo.rackId == rack.id || c.targetInfo.rackId == rack.id,
        )
        .length;
    final bc = rack.breadcrumb;
    final locCode = (bc['location_code'] ?? '').toString();
    final roomName = (bc['room_name'] ?? '').toString();

    return [
      // A. Tarjeta Cabecera del Rack (clicable para abrir RackEditorView)
      Positioned(
        left: left,
        top: _headerCardTop,
        width: _rackOuterWidth,
        height: _headerCardHeight,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hoveredRackId = rack.id),
          onExit: (_) {
            if (_hoveredRackId == rack.id) {
              setState(() => _hoveredRackId = null);
            }
          },
          child: GestureDetector(
            onTap: () => widget.onOpenRack(rack.id),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: isRackHovered ? const Color(0xFF0F172A) : Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isRackHovered
                      ? AppPalette.sky400
                      : AppPalette.slate300,
                  width: isRackHovered ? 2.0 : 1.2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: isRackHovered ? 0.16 : 0.05,
                    ),
                    blurRadius: isRackHovered ? 12 : 5,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: isRackHovered
                              ? AppPalette.sky600
                              : AppPalette.slate900,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          rack.code,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          rack.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: isRackHovered
                                ? Colors.white
                                : AppPalette.slate900,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: isRackHovered
                              ? AppPalette.sky400.withValues(alpha: 0.22)
                              : AppPalette.blue50,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Editar Rack',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                color: isRackHovered
                                    ? AppPalette.sky200
                                    : AppPalette.blue700,
                              ),
                            ),
                            const SizedBox(width: 3),
                            Icon(
                              Icons.arrow_forward_rounded,
                              size: 12,
                              color: isRackHovered
                                  ? AppPalette.sky200
                                  : AppPalette.blue700,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '$locCode • $roomName',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 10.5,
                            color: isRackHovered
                                ? AppPalette.slate300
                                : AppPalette.slate500,
                          ),
                        ),
                      ),
                      Text(
                        '${usedUnits.length}/${rack.totalUnits}U  •  ${frontDevices.length} eq.  •  $rackConnCount cables',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: isRackHovered
                              ? AppPalette.sky200
                              : AppPalette.slate700,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),

      // B. Bastidor Metálico Frontal 19" EIA-310 (clicable en cualquier zona libre para abrir el Rack)
      Positioned(
        left: left,
        top: _cabinetTop,
        width: _rackOuterWidth,
        height: cabHeight,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hoveredRackId = rack.id),
          onExit: (_) {
            if (_hoveredRackId == rack.id) {
              setState(() => _hoveredRackId = null);
            }
          },
          child: GestureDetector(
            onTap: () => widget.onOpenRack(rack.id),
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isRackHovered
                      ? AppPalette.sky400
                      : const Color(0xFF0F172A),
                  width: isRackHovered ? 2.2 : 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 10,
                    offset: const Offset(0, 5),
                  ),
                ],
              ),
              child: Stack(
                children: [
                  // Fondo interior de ranuras U vacías
                  Positioned(
                    left: _railWidth,
                    top: 0,
                    width: _rackInnerWidth,
                    height: cabHeight,
                    child: Container(
                      color: const Color(0xFFF8FAFC),
                      child: Column(
                        children: List.generate(rack.totalUnits, (idx) {
                          final uNum = rack.totalUnits - idx;
                          return Container(
                            height: _uHeightPx,
                            decoration: BoxDecoration(
                              color: uNum.isEven
                                  ? const Color(0xFFF8FAFC)
                                  : const Color(0xFFF1F5F9),
                              border: const Border(
                                bottom: BorderSide(
                                  color: Color(0xFFE2E8F0),
                                  width: 0.7,
                                ),
                              ),
                            ),
                          );
                        }),
                      ),
                    ),
                  ),

                  // Raíl numérico izquierdo (U42..U1)
                  Positioned(
                    left: 0,
                    top: 0,
                    width: _railWidth,
                    height: cabHeight,
                    child: Column(
                      children: List.generate(rack.totalUnits, (idx) {
                        final uNum = rack.totalUnits - idx;
                        return SizedBox(
                          height: _uHeightPx,
                          child: Center(
                            child: Text(
                              '$uNum',
                              style: TextStyle(
                                fontSize: 8.5,
                                fontWeight: uNum % 5 == 0
                                    ? FontWeight.w800
                                    : FontWeight.w500,
                                color: uNum % 5 == 0
                                    ? Colors.white
                                    : AppPalette.slate400,
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                  ),

                  // Raíl numérico derecho (U42..U1)
                  Positioned(
                    right: 0,
                    top: 0,
                    width: _railWidth,
                    height: cabHeight,
                    child: Column(
                      children: List.generate(rack.totalUnits, (idx) {
                        final uNum = rack.totalUnits - idx;
                        return SizedBox(
                          height: _uHeightPx,
                          child: Center(
                            child: Text(
                              '$uNum',
                              style: TextStyle(
                                fontSize: 8.5,
                                fontWeight: uNum % 5 == 0
                                    ? FontWeight.w800
                                    : FontWeight.w500,
                                color: uNum % 5 == 0
                                    ? Colors.white
                                    : AppPalette.slate400,
                              ),
                            ),
                          ),
                        );
                      }),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),

      // C. Equipos montados en el frontal de este Rack
      for (final dev in frontDevices)
        _buildMountedFrontDeviceTile(
          rack: rack,
          dev: dev,
          innerLeft: innerLeft,
          portColors: portColors,
        ),
    ];
  }

  Widget _buildMountedFrontDeviceTile({
    required RackDetailModel rack,
    required RackDeviceModel dev,
    required double innerLeft,
    required Map<int, Color> portColors,
  }) {
    final topU = dev.endU.clamp(1, rack.totalUnits);
    final topPx = _cabinetTop + (rack.totalUnits - topU) * _uHeightPx;
    final heightPx = dev.uHeight * _uHeightPx;
    final isHovered = _hoveredDeviceId == dev.id;
    final accent = _deviceCategoryAccent(dev.template.category);
    final hbCol = _heartbeatColor(dev);
    final frontPorts = dev.ports.where((p) => p.face == 'front').toList();

    return Positioned(
      left: innerLeft,
      top: topPx,
      width: _rackInnerWidth,
      height: heightPx,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() {
          _hoveredRackId = rack.id;
          _hoveredDeviceId = dev.id;
        }),
        onExit: (_) => setState(() {
          if (_hoveredDeviceId == dev.id) _hoveredDeviceId = null;
        }),
        child: GestureDetector(
          onTap: () =>
              widget.onOpenRack(rack.id, highlightDeviceId: dev.id),
          child: Container(
            decoration: BoxDecoration(
              color: isHovered
                  ? const Color(0xFF0F172A)
                  : const Color(0xFF1E293B),
              border: Border.all(
                color: isHovered ? AppPalette.sky400 : const Color(0xFF334155),
                width: isHovered ? 1.6 : 0.9,
              ),
            ),
            child: Stack(
              children: [
                // Banda lateral de categoría + LED estado + Código e IP
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: _rackInnerWidth * 0.53,
                  child: Row(
                    children: [
                      Container(width: 4, color: accent),
                      const SizedBox(width: 5),
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: hbCol,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          dev.ipAddress.isNotEmpty
                              ? '${dev.code} · ${dev.ipAddress}'
                              : dev.code,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w800,
                            color: isHovered
                                ? AppPalette.sky200
                                : Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // Mini-bocas físicas reales en la mitad derecha del chasis (exactas a las anclas de cable)
                for (final p in frontPorts)
                  Positioned(
                    left: _rackInnerWidth * 0.54 +
                        p.relX.clamp(0.05, 0.95) * (_rackInnerWidth * 0.42) -
                        2.2,
                    top: p.relY.clamp(0.20, 0.80) * heightPx - 2.2,
                    width: 4.4,
                    height: 4.4,
                    child: Container(
                      decoration: BoxDecoration(
                        color: portColors[p.id] ??
                            (p.portType.startsWith('sfp')
                                ? const Color(0xFF475569)
                                : const Color(0xFF334155)),
                        borderRadius: BorderRadius.circular(1),
                        border: portColors.containsKey(p.id)
                            ? Border.all(color: Colors.white, width: 0.5)
                            : null,
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

  Widget _buildBottomHintOrHoverHud(List<ConnectionModel> visibleConns) {
    if (_hoveredDeviceId != null) {
      RackDeviceModel? hovDev;
      RackDetailModel? hovRack;
      for (final r in _racks) {
        for (final d in r.devices) {
          if (d.id == _hoveredDeviceId) {
            hovDev = d;
            hovRack = r;
            break;
          }
        }
        if (hovDev != null) break;
      }
      if (hovDev != null && hovRack != null) {
        final devConns = visibleConns
            .where(
              (c) =>
                  c.sourceInfo.deviceId == hovDev!.id ||
                  c.targetInfo.deviceId == hovDev.id,
            )
            .toList();
        final interCnt = devConns.where((c) => c.isOutbound).length;
        final intraCnt = devConns.length - interCnt;
        return Positioned(
          left: 16,
          right: 16,
          bottom: 14,
          child: Center(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xEE0F172A),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppPalette.sky400, width: 1.2),
              ),
              child: Text(
                '${hovRack.code} › ${hovDev.code} (${hovDev.template.modelName})'
                '${hovDev.ipAddress.isNotEmpty ? ' • IP ${hovDev.ipAddress}' : ''}'
                '  —  ${devConns.length} conexiones ($interCnt Inter-Rack, $intraCnt locales)  •  Clic para abrir en Editor CAD',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        );
      }
    }

    return Positioned(
      right: 16,
      bottom: 12,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppPalette.slate300),
        ),
        child: const Text(
          'Rueda/Pinch: Zoom  •  Arrastrar: Desplazar  •  Pasar ratón: Rayos X de cables  •  Clic en Rack/Equipo: Abrir Editor CAD',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: AppPalette.slate600,
          ),
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, size: 40, color: AppPalette.red600),
          const SizedBox(height: 10),
          Text(
            'Error cargando el alzado de Racks: $_error',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _loadOverview,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('Reintentar'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.view_column_outlined,
            size: 44,
            color: AppPalette.slate400,
          ),
          const SizedBox(height: 10),
          const Text(
            'No hay armarios Rack registrados en esta sede.',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: AppPalette.slate700,
            ),
          ),
          const SizedBox(height: 10),
          if (_selectedLocationId != null)
            OutlinedButton(
              onPressed: () {
                setState(() => _selectedLocationId = null);
                _loadOverview();
              },
              child: const Text('Ver Racks de todas las sedes'),
            ),
        ],
      ),
    );
  }
}

/// Pintor vectorial de cables Intra-Rack y enlaces aéreos Inter-Rack entre múltiples bastidores.
class _MultiRackElevationCablePainter extends CustomPainter {
  final List<RackDetailModel> racks;
  final Map<int, int> rackIndexById;
  final double Function(int index) rackLeftOf;
  final double rackOuterWidth;
  final double railWidth;
  final double trayTop;
  final double trayBottom;
  final List<ConnectionModel> connections;
  final Map<int, Offset> portOffsets;
  final Map<int, Offset> deviceOffsets;
  final String interRackMode;
  final int? hoveredRackId;
  final int? hoveredDeviceId;

  _MultiRackElevationCablePainter({
    required this.racks,
    required this.rackIndexById,
    required this.rackLeftOf,
    required this.rackOuterWidth,
    required this.railWidth,
    required this.trayTop,
    required this.trayBottom,
    required this.connections,
    required this.portOffsets,
    required this.deviceOffsets,
    required this.interRackMode,
    required this.hoveredRackId,
    required this.hoveredDeviceId,
  });

  bool _isConnectionHighlighted(ConnectionModel c) {
    if (hoveredDeviceId != null) {
      return c.sourceInfo.deviceId == hoveredDeviceId ||
          c.targetInfo.deviceId == hoveredDeviceId;
    }
    if (hoveredRackId != null) {
      return c.sourceInfo.rackId == hoveredRackId ||
          c.targetInfo.rackId == hoveredRackId;
    }
    return false;
  }

  Offset? _resolveEndpoint(ConnectionEndpointInfoModel ep) {
    return portOffsets[ep.portId] ?? deviceOffsets[ep.deviceId];
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (racks.isEmpty || connections.isEmpty) return;

    final hasHoverFilter = hoveredDeviceId != null || hoveredRackId != null;

    // 1. Pintar cables Intra-Rack (dentro de cada armario)
    final intraByRack = <int, List<ConnectionModel>>{};
    final interConns = <ConnectionModel>[];
    for (final c in connections) {
      if (c.isOutbound) {
        interConns.add(c);
      } else {
        intraByRack.putIfAbsent(c.sourceInfo.rackId, () => []).add(c);
      }
    }

    for (final entry in intraByRack.entries) {
      final rIdx = rackIndexById[entry.key];
      if (rIdx == null) continue;
      final rLeft = rackLeftOf(rIdx);
      final rightGutterBase = rLeft + rackOuterWidth - railWidth + 4.0;
      final list = entry.value;

      for (int i = 0; i < list.length; i++) {
        final c = list[i];
        final p1 = _resolveEndpoint(c.sourceInfo);
        final p2 = _resolveEndpoint(c.targetInfo);
        if (p1 == null || p2 == null) continue;

        final highlighted = _isConnectionHighlighted(c);
        final alpha = hasHoverFilter ? (highlighted ? 0.96 : 0.14) : 0.72;
        final baseColor =
            CableGeometryBuilder.parseHexColor(c.colorHex).withValues(alpha: alpha);
        final gutterX = rightGutterBase + (i % 6) * 3.0;

        final path = Path()
          ..moveTo(p1.dx, p1.dy)
          ..lineTo(gutterX, p1.dy)
          ..lineTo(gutterX, p2.dy)
          ..lineTo(p2.dx, p2.dy);

        canvas.drawPath(
          path,
          Paint()
            ..color = baseColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = highlighted ? 2.4 : 1.4
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        );
      }
    }

    // 2. En modo 'trunk', dibujar los mazos agrupados por pareja de Racks en la bandeja superior
    if (interRackMode == 'trunk') {
      final bundles = <String, List<ConnectionModel>>{};
      for (final c in interConns) {
        final a = math.min(c.sourceInfo.rackId, c.targetInfo.rackId);
        final b = math.max(c.sourceInfo.rackId, c.targetInfo.rackId);
        bundles.putIfAbsent('$a-$b', () => []).add(c);
      }

      int bundleIdx = 0;
      for (final bEntry in bundles.entries) {
        final list = bEntry.value;
        final first = list.first;
        final idxA = rackIndexById[first.sourceInfo.rackId];
        final idxB = rackIndexById[first.targetInfo.rackId];
        if (idxA == null || idxB == null) continue;

        final xA = rackLeftOf(idxA) + rackOuterWidth / 2 + (bundleIdx % 3 - 1) * 10.0;
        final xB = rackLeftOf(idxB) + rackOuterWidth / 2 + (bundleIdx % 3 - 1) * 10.0;
        final laneY =
            trayTop + 14.0 + (bundleIdx * 20.0) % math.max(24.0, trayBottom - trayTop - 16.0);
        bundleIdx++;

        final anyHighlighted = list.any(_isConnectionHighlighted);
        final trunkAlpha = hasHoverFilter ? (anyHighlighted ? 0.35 : 0.16) : 0.88;
        final domColor = CableGeometryBuilder.parseHexColor(first.colorHex)
            .withValues(alpha: trunkAlpha);

        final trunkPath = Path()
          ..moveTo(xA, trayBottom + 112.0)
          ..lineTo(xA, laneY)
          ..lineTo(xB, laneY)
          ..lineTo(xB, trayBottom + 112.0);

        canvas.drawPath(
          trunkPath,
          Paint()
            ..color = domColor
            ..style = PaintingStyle.stroke
            ..strokeWidth = (3.5 + math.min(5.5, list.length * 0.18))
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        );

        // Etiqueta del mazo en el punto medio de la bandeja
        final midX = (xA + xB) / 2;
        final tp = TextPainter(
          text: TextSpan(
            text: '${list.length}× enlaces  (${first.sourceInfo.rackCode} ↔ ${first.targetInfo.rackCode})',
            style: TextStyle(
              color: Colors.white.withValues(alpha: hasHoverFilter ? 0.55 : 1.0),
              fontSize: 10,
              fontWeight: FontWeight.w800,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();

        final pillRect = RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(midX, laneY),
            width: tp.width + 14,
            height: tp.height + 6,
          ),
          const Radius.circular(10),
        );
        canvas.drawRRect(
          pillRect,
          Paint()
            ..color = const Color(0xFF0F172A)
                .withValues(alpha: hasHoverFilter ? 0.45 : 0.90),
        );
        tp.paint(
          canvas,
          Offset(midX - tp.width / 2, laneY - tp.height / 2),
        );
      }
    }

    // 3. Pintar hilos individuales Inter-Rack (todos en modo 'wires', o los iluminados por hover en modo 'trunk')
    final traySpan = math.max(24.0, trayBottom - trayTop);
    for (int i = 0; i < interConns.length; i++) {
      final c = interConns[i];
      final highlighted = _isConnectionHighlighted(c);
      if (interRackMode == 'trunk' && !highlighted) continue;

      final p1 = _resolveEndpoint(c.sourceInfo);
      final p2 = _resolveEndpoint(c.targetInfo);
      if (p1 == null && p2 == null) continue;

      final alpha = hasHoverFilter ? (highlighted ? 0.96 : 0.14) : 0.68;
      final col =
          CableGeometryBuilder.parseHexColor(c.colorHex).withValues(alpha: alpha);
      final laneY = trayTop + ((i * 5.5) % traySpan);

      final sIdx = rackIndexById[c.sourceInfo.rackId];
      final tIdx = rackIndexById[c.targetInfo.rackId];

      if (p1 != null && p2 != null && sIdx != null && tIdx != null) {
        final sRiserX =
            rackLeftOf(sIdx) + rackOuterWidth - railWidth - 6.0 - (i % 7) * 2.2;
        final tRiserX =
            rackLeftOf(tIdx) + railWidth + 6.0 + (i % 7) * 2.2;

        final wirePath = Path()
          ..moveTo(p1.dx, p1.dy)
          ..lineTo(sRiserX, p1.dy)
          ..lineTo(sRiserX, laneY)
          ..lineTo(tRiserX, laneY)
          ..lineTo(tRiserX, p2.dy)
          ..lineTo(p2.dx, p2.dy);

        canvas.drawPath(
          wirePath,
          Paint()
            ..color = col
            ..style = PaintingStyle.stroke
            ..strokeWidth = highlighted ? 2.4 : 1.25
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round,
        );
      } else {
        // Uno de los dos extremos pertenece a un Rack de otra sede no filtrada actualmente
        final localPt = p1 ?? p2!;
        final localIdx = sIdx ?? tIdx ?? 0;
        final riserX = rackLeftOf(localIdx) + rackOuterWidth / 2;
        final stub = Path()
          ..moveTo(localPt.dx, localPt.dy)
          ..lineTo(riserX, localPt.dy)
          ..lineTo(riserX, laneY);
        canvas.drawPath(
          stub,
          Paint()
            ..color = col
            ..style = PaintingStyle.stroke
            ..strokeWidth = highlighted ? 2.2 : 1.2,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MultiRackElevationCablePainter oldDelegate) {
    return oldDelegate.connections != connections ||
        oldDelegate.racks != racks ||
        oldDelegate.interRackMode != interRackMode ||
        oldDelegate.hoveredRackId != hoveredRackId ||
        oldDelegate.hoveredDeviceId != hoveredDeviceId;
  }
}
