import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/api_client.dart';
import '../../models/datacenter_models.dart';
import 'widgets/cable_painter.dart';
import 'widgets/device_catalog_panel.dart';
import 'widgets/properties_panel.dart';

class RackEditorView extends StatefulWidget {
  final RackDocApiClient api;
  final int rackId;
  final int? initialHighlightDeviceId;
  final List<DeviceTemplateModel> templates;
  final VoidCallback onBackToLocations;
  final ValueChanged<int> onSwitchRack;
  final void Function(int rackId, int? deviceId)? onJumpToRackAndDevice;
  final VoidCallback onTemplatesChanged;
  final UserModel? currentUser;

  const RackEditorView({
    super.key,
    required this.api,
    required this.rackId,
    this.initialHighlightDeviceId,
    required this.templates,
    required this.onBackToLocations,
    required this.onSwitchRack,
    this.onJumpToRackAndDevice,
    required this.onTemplatesChanged,
    this.currentUser,
  });

  @override
  State<RackEditorView> createState() => _RackEditorViewState();
}

class _RackEditorViewState extends State<RackEditorView> {
  RackDetailModel? _rack;
  bool _loading = true;
  String? _error;

  // Cara activa del rack ('front', 'back' o 'both' para ver Front & Back a la vez)
  String _activeFace = 'both';

  // Mostrar / Ocultar foto de referencia / bisel realista en los equipos montados
  bool _showEquipmentPhotos = false;

  // Filtro de visualización de cables ('all' | 'network' | 'fiber' | 'power')
  String _cableFilter = 'all';

  // Librería seleccionada en el catálogo izquierdo ('all' | 'Bandeja - Equipos Mini' | 'Network' | 'Power' | ...)
  String _selectedLibraryGroup = 'all';

  // Selección activa para el panel derecho, resaltado desde búsqueda/alarma y hover para controles rápidos
  int? _selectedDeviceId;
  int? _highlightedDeviceId;
  int? _hoveredDeviceId;
  int? _selectedConnectionId;
  int? _hoveredConnectionId;
  final TextEditingController _rackQuickSearchCtrl = TextEditingController();

  // Estado durante el arrastre (Drag & Drop) de un equipo ya colocado o desde el catálogo
  Object? _draggingData;
  int? _hoveredDropU;

  // Plantilla seleccionada para montar con clic en '+'
  DeviceTemplateModel? _selectedTemplateForClick;

  // Estado para tirar un cable nuevo entre dos puertos (incluso entre Front, Back y Tomas Exteriores)
  PortModel? _pendingSourcePort;
  RackDeviceModel? _pendingSourceDevice;
  Offset? _cursorCanvasPos;

  // Controlador de Zoom / Pan del lienzo
  final TransformationController _transformController =
      TransformationController();

  // Dimensiones constantes del dibujo técnico del Rack (estilo Patchbox CAD) + Vista Dual (Front + Back) + Zona Exterior
  static const double _canvasWidth = 1140.0;
  static const double _dualCanvasWidth = 1890.0;
  static const double _rackOuterLeft = 104.0;
  static const double _rackOuterWidth = 628.0;
  static const double _rackInnerLeft = 152.0;
  static const double _rackInnerWidth = 532.0;
  static const double _backRackOuterLeft = 836.0;
  static const double _backRackInnerLeft = 884.0;
  static const double _dualFaceGap = 104.0;
  static const double _railWidth = 18.0;
  static const double _rackTopMargin = 76.0;
  static const double _uHeightPx = 42.0;

  // Coordenadas del cuadro de Tomas Eléctricas y de Fibra Exteriores (fuera del rack a la derecha)
  static const double _extZoneLeft = 785.0;
  static const double _dualExtZoneLeft = 1530.0;
  static const double _extZoneWidth = 315.0;
  static const double _extCardTopStart = 114.0;
  static const double _extCardHeight = 128.0;
  static const double _extCardGap = 18.0;

  bool get _isDualFace => _activeFace == 'both';
  double get _effectiveExtZoneLeft =>
      _isDualFace ? _dualExtZoneLeft : _extZoneLeft;
  double get _effectiveCanvasWidth =>
      _isDualFace ? _dualCanvasWidth : _canvasWidth;

  bool get _canEdit => widget.currentUser?.canEdit ?? true;
  bool get _canConnectRemote => widget.currentUser?.canConnectRemote ?? true;

  @override
  void initState() {
    super.initState();
    _highlightedDeviceId = widget.initialHighlightDeviceId;
    _selectedDeviceId = widget.initialHighlightDeviceId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyFaceCameraZoom(_activeFace);
    });
    _loadRack();
  }

  @override
  void dispose() {
    _rackQuickSearchCtrl.dispose();
    _transformController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant RackEditorView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rackId != widget.rackId) {
      _highlightedDeviceId = widget.initialHighlightDeviceId;
      _selectedDeviceId = widget.initialHighlightDeviceId;
      _selectedConnectionId = null;
      _pendingSourcePort = null;
      _loadRack();
    } else if (oldWidget.initialHighlightDeviceId !=
            widget.initialHighlightDeviceId &&
        widget.initialHighlightDeviceId != null) {
      setState(() {
        _highlightedDeviceId = widget.initialHighlightDeviceId;
        _selectedDeviceId = widget.initialHighlightDeviceId;
      });
    }
  }

  void _applyFaceCameraZoom(String face) {
    final m = Matrix4.identity();
    if (face == 'both') {
      // Escala inicial ~0.58 para que tanto el bastidor FRONT (delante) como el BACK (detrás) se vean enteros a la vez
      m.scaleByDouble(0.58, 0.58, 1.0, 1.0);
    } else {
      m.scaleByDouble(0.84, 0.84, 1.0, 1.0);
    }
    _transformController.value = m;
  }

  void _setFaceMode(String face) {
    setState(() => _activeFace = face);
    _applyFaceCameraZoom(face);
  }

  Future<void> _confirmDeleteCurrentRack() async {
    if (!_canEdit) return;
    final rack = _rack;
    if (rack == null) return;
    final messenger = ScaffoldMessenger.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Eliminar Rack "${rack.code}"'),
        content: Text(
          '¿Estás seguro de que quieres eliminar el Rack "${rack.code} (${rack.name})"?\n\n'
          'Se borrarán también todos sus dispositivos (${rack.devices.length}) y conexiones.',
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
        await widget.api.deleteRack(rack.id);
        widget.onBackToLocations();
        messenger.showSnackBar(
          SnackBar(content: Text('Rack "${rack.code}" eliminado.')),
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

  Future<void> _loadRack() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await widget.api.getRackDetail(widget.rackId);
      if (mounted) {
        setState(() {
          _rack = detail;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  RackDeviceModel? get _selectedDevice {
    if (_rack == null || _selectedDeviceId == null) return null;
    for (final d in _rack!.devices) {
      if (d.id == _selectedDeviceId) return d;
    }
    return null;
  }

  ConnectionModel? get _selectedConnection {
    if (_rack == null || _selectedConnectionId == null) return null;
    for (final c in _rack!.connections) {
      if (c.id == _selectedConnectionId) return c;
    }
    return null;
  }

  List<RackDeviceModel> _getExternalOutlets(RackDetailModel rack) {
    final list = rack.devices.where((d) => d.isExternalFeed).toList();
    list.sort((a, b) => a.id.compareTo(b.id));
    return list;
  }

  /// Ajusta la posición horizontal relativa `relX` para agrupar visualmente en bloques de 8 bocas
  /// los paneles de 24 puertos de 1 fila (como Patch Panels A..E y FI-01 en la imagen de referencia).
  double _computeVisualRelX(RackDeviceModel dev, PortModel port) {
    final cat = dev.template.category;
    final numVal = int.tryParse(
      port.portNumber.replaceAll(RegExp(r'[^0-9]'), ''),
    );
    if ((cat == 'patch_panel' || cat == 'gateway') &&
        numVal != null &&
        numVal >= 1 &&
        numVal <= 24) {
      final idx = numVal - 1; // 0..23
      final block = idx ~/ 8; // 0, 1, 2
      final inBlock = idx % 8; // 0..7
      const baseStart = 0.085;
      const blockSpan = 0.245;
      const blockGap = 0.042;
      return baseStart +
          block * (blockSpan + blockGap) +
          (inBlock / 7.0) * blockSpan;
    }
    return port.relX;
  }

  double _computeVisualRelY(RackDeviceModel dev, PortModel port, String face) {
    final facePorts = dev.portsForFace(face);
    final hasTwoRows = facePorts.any((p) => p.rowIndex > 0);
    if (hasTwoRows) {
      return port.rowIndex == 0 ? 0.34 : 0.72;
    }
    return 0.56;
  }

  int _externalColsPerRow(RackDeviceModel ext) {
    final count = ext.ports.isEmpty ? 1 : ext.ports.length;
    if (ext.isFiberFeed) {
      return count <= 8 ? count : 8;
    }
    return count <= 6 ? count : 6;
  }

  double _externalCardHeight(RackDeviceModel ext) {
    final count = ext.ports.length;
    if (count <= 0) return _extCardHeight;
    final colsPerRow = _externalColsPerRow(ext);
    final rows = ((count - 1) ~/ colsPerRow) + 1;
    return 78.0 + rows * 50.0;
  }

  Offset _externalPortLocalCenter(RackDeviceModel ext, int pIdx) {
    final count = ext.ports.length;
    if (count <= 0) return const Offset(_extZoneWidth * 0.5, 84.0);
    final colsPerRow = _externalColsPerRow(ext);
    final rows = ((count - 1) ~/ colsPerRow) + 1;
    final rowIdx = pIdx ~/ colsPerRow;
    final colIdx = pIdx % colsPerRow;
    final colsInThisRow =
        (rowIdx == rows - 1) ? (count - rowIdx * colsPerRow) : colsPerRow;
    final relX = colsInThisRow <= 1
        ? 0.5
        : (0.12 + (0.76 * colIdx / (colsInThisRow - 1)));
    final centerY = 84.0 + rowIdx * 48.0;
    return Offset(relX * _extZoneWidth, centerY);
  }

  /// Calcula la coordenada exacta (x, y) en el lienzo de cada puerto visible en la cara activa
  /// (o en AMBAS caras Front y Back cuando `_activeFace == 'both'`) MÁS las tomas exteriores.
  Map<int, Offset> _computePortCoordinates(RackDetailModel rack) {
    final map = <int, Offset>{};
    final totalU = rack.totalUnits;

    // 1. Dispositivos montados dentro del Rack
    for (final dev in rack.devices) {
      if (dev.isExternalFeed) continue;

      final topU = dev.endU;
      final devTopY = _rackTopMargin + (totalU - topU) * _uHeightPx;
      final devHeight = dev.uHeight * _uHeightPx;

      if (_isDualFace) {
        // En modo Dual (Front + Back), calculamos tanto los puertos Front (izquierda) como los Back (derecha)
        for (final p in dev.portsForFace('front')) {
          final rx = _computeVisualRelX(dev, p);
          final ry = _computeVisualRelY(dev, p, 'front');
          map[p.id] = Offset(
            _rackInnerLeft + rx * _rackInnerWidth,
            devTopY + ry * devHeight,
          );
        }
        for (final p in dev.portsForFace('back')) {
          final rx = _computeVisualRelX(dev, p);
          final ry = _computeVisualRelY(dev, p, 'back');
          map[p.id] = Offset(
            _backRackInnerLeft + rx * _rackInnerWidth,
            devTopY + ry * devHeight,
          );
        }
      } else {
        if (!dev.isVisibleOnFace(_activeFace)) continue;
        final facePorts = dev.portsForFace(_activeFace);
        for (final p in facePorts) {
          final rx = _computeVisualRelX(dev, p);
          final ry = _computeVisualRelY(dev, p, _activeFace);
          final px = _rackInnerLeft + rx * _rackInnerWidth;
          final py = devTopY + ry * devHeight;
          map[p.id] = Offset(px, py);
        }
      }
    }

    // 2. Tomas Exteriores (Eléctricas Schuko y de Fibra Óptica fuera del rack a la derecha)
    final extOutlets = _getExternalOutlets(rack);
    final extLeft = _effectiveExtZoneLeft;
    double runningCardTop = _extCardTopStart;
    for (int idx = 0; idx < extOutlets.length; idx++) {
      final ext = extOutlets[idx];
      final cardTop = runningCardTop;
      final count = ext.ports.length;
      for (int pIdx = 0; pIdx < count; pIdx++) {
        final port = ext.ports[pIdx];
        final localCenter = _externalPortLocalCenter(ext, pIdx);
        map[port.id] = Offset(
          extLeft + localCenter.dx,
          cardTop + localCenter.dy,
        );
      }
      runningCardTop += _externalCardHeight(ext) + _extCardGap;
    }

    return map;
  }

  // ===========================================================================
  // COMPROBACIÓN DE UNIDADES "U" LIBRES Y MOVIMIENTO / ARRASTRE DE EQUIPOS
  // ===========================================================================
  /// Devuelve el primer equipo que choca con el rango `[targetStartU .. targetStartU + uHeight - 1]`,
  /// ignorando `excludeDeviceId` (el propio equipo que se está moviendo) y tomas exteriores.
  RackDeviceModel? _findBlockingDevice(
    RackDetailModel rack,
    int targetStartU,
    int uHeight, {
    int? excludeDeviceId,
  }) {
    final targetEndU = targetStartU + uHeight - 1;
    for (final other in rack.devices) {
      if (other.isExternalFeed) continue;
      if (excludeDeviceId != null && other.id == excludeDeviceId) continue;
      if (!(targetEndU < other.startU || targetStartU > other.endU)) {
        return other;
      }
    }
    return null;
  }

  /// Comprueba que el rango completo `[targetStartU .. targetStartU + uHeight - 1]` esté dentro del rack
  /// y que todas sus unidades "U" estén completamente libres.
  bool _canFitAtU(
    RackDetailModel rack,
    int targetStartU,
    int uHeight, {
    int? excludeDeviceId,
  }) {
    final targetEndU = targetStartU + uHeight - 1;
    if (targetStartU < 1 || targetEndU > rack.totalUnits) {
      return false;
    }
    return _findBlockingDevice(
          rack,
          targetStartU,
          uHeight,
          excludeDeviceId: excludeDeviceId,
        ) ==
        null;
  }

  /// Busca la unidad U libre más cercana hacia arriba (`direction = 1`) o hacia abajo (`direction = -1`)
  /// donde quepa el equipo completo (`dev.uHeight` unidades U libres).
  int? _findNearestFreeU(
    RackDetailModel rack,
    RackDeviceModel dev,
    int direction,
  ) {
    final uHeight = dev.uHeight;
    final maxStartU = rack.totalUnits - uHeight + 1;
    int candidate = dev.startU + direction;
    while (candidate >= 1 && candidate <= maxStartU) {
      if (_canFitAtU(rack, candidate, uHeight, excludeDeviceId: dev.id)) {
        return candidate;
      }
      candidate += direction;
    }
    return null;
  }

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
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            blocker != null
                ? 'No se puede ampliar "${dev.code}" a ${clamped}U en U${dev.startU}-U${dev.startU + clamped - 1}: choca con "${blocker.code}" (U${blocker.startU}).'
                : 'No cabe "${dev.code}" con ${clamped}U en U${dev.startU} (excede U${rack.totalUnits}).',
          ),
          backgroundColor: Colors.red.shade700,
        ),
      );
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
      messenger.showSnackBar(
        SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700),
      );
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
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'No se puede colocar "${dev.code}" ($uHeight U) en U$targetStartU: necesita hasta U$targetEndU y el rack tiene ${rack.totalUnits}U.',
          ),
          backgroundColor: Colors.red.shade700,
        ),
      );
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
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'No hay suficientes "U" libres en $rangeLabel para "${dev.code}" (${uHeight}U): ocupado por "${blocker.code}" ($blockerRange).',
          ),
          backgroundColor: Colors.red.shade700,
        ),
      );
      return;
    }

    try {
      await widget.api.updateDevice(dev.id, {'start_u': targetStartU});
      await _loadRack();
      setState(() => _selectedDeviceId = dev.id);
      final rangeLabel =
          uHeight > 1 ? 'U$targetStartU-U$targetEndU' : 'U$targetStartU';
      messenger.showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          content: Text(
            'Equipo "${dev.code}" (${uHeight}U) movido a $rangeLabel libre (Front y Back sincronizados).',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text('No se pudo mover a U$targetStartU: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
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
                  style: const TextStyle(fontSize: 12, color: Color(0xFF475569)),
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
      messenger.showSnackBar(
        SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700),
      );
    }
  }

  Future<void> _handleDropOnUSlot(
    Object droppedData,
    int targetStartU, {
    RackDeviceModel? targetMountedDevice,
  }) async {
    if (!_canEdit) return;
    setState(() {
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
      rawBlocks.add({
        'port_type': 'sfp_plus',
        'prefix': isBackFace ? 'B-SFP' : 'SFP',
        'count': sfpCount,
        'rows': sfpCount >= 6 ? 2 : 1,
        'weight': (sfpCount >= 6 ? (sfpCount / 2.0) : sfpCount.toDouble())
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
  }) async {
    if (!_canEdit) return;
    final messenger = ScaffoldMessenger.of(context);
    final miniTemplates =
        widget.templates.where((t) => t.isTrayMiniDevice).toList();
    if (miniTemplates.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'No se encontraron plantillas en la librería "Bandeja - Equipos Mini".',
          ),
        ),
      );
      return;
    }

    final items = trayDev.trayItems
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    DeviceTemplateModel selectedTpl = initialAddTemplate ?? miniTemplates.first;

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
                color: Color(0xFF1D4ED8),
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
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFF93C5FD)),
                    ),
                    child: const Text(
                      '💡 En una Bandeja puedes colocar hasta 4 equipos pequeños o de sobremesa (Routers, Mini-Switches, ONTs, Mini-PCs). Puedes definir sus bocas RJ45, SFP Fibra y Tomas Eléctricas tanto por DELANTE (Front) como por DETRÁS (Back).',
                      style: TextStyle(fontSize: 11.5, color: Color(0xFF1E3A8A)),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '1. EQUIPOS ACTUALMENTE EN LA BANDEJA (${items.length} / 4 máx.):',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (items.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: const Row(
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 16,
                            color: Color(0xFF64748B),
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'La bandeja está vacía. Selecciona abajo un Router, Switch o Mini-PC para colocarlo encima.',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: Color(0xFF64748B),
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
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0xFFCBD5E1)),
                        ),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E293B),
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
                                      color: Color(0xFF0F172A),
                                    ),
                                  ),
                                  Text(
                                    'Modelo: ${it['manufacturer'] ?? ''} ${it['model_name'] ?? ''}${it['ip_address']?.toString().isNotEmpty == true ? ' • IP: ${it['ip_address']}' : ''}',
                                    style: const TextStyle(
                                      fontSize: 10.5,
                                      color: Color(0xFF64748B),
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
                                color: Color(0xFFDC2626),
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
                      color: Color(0xFF1E3A8A),
                    ),
                  ),
                  const SizedBox(height: 8),
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
                      color: Color(0xFF334155),
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
                if (initialAddTemplate != null &&
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
        setState(() {
          _selectedDeviceId = trayDev.id;
        });
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Bandeja "${trayDev.code}" actualizada con ${items.length} equipo(s) alojado(s) y sus bocas RJ45/Fibra/PSU sincronizadas.',
            ),
          ),
        );
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700),
        );
      }
    }
  }

  Future<void> _handleDropOrMountTemplate(
    DeviceTemplateModel tpl,
    int targetStartU,
  ) async {
    if (!_canEdit) return;
    final rack = _rack;
    if (rack == null) return;

    // Si es un equipo de "Bandeja - Equipos Mini" (Router sobremesa, Mini-Switch, ONT, Mini-PC)
    // y se suelta en una U donde ya hay una Bandeja, lo metemos en esa bandeja.
    // Si se suelta en una U libre, montamos automáticamente una Bandeja 1U con este mini-equipo dentro.
    if (tpl.isTrayMiniDevice) {
      for (final d in rack.devices) {
        if (d.isRackTray && targetStartU >= d.startU && targetStartU <= d.endU) {
          await _showManageTrayItemsDialog(d, initialAddTemplate: tpl);
          return;
        }
      }
      final trayTemplate = widget.templates.firstWhere(
        (t) => t.isRackTray,
        orElse: () => tpl,
      );
      if (!_canFitAtU(rack, targetStartU, 1)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Para colocar "${tpl.modelName}" en U$targetStartU hace falta una Bandeja en esa U o que U$targetStartU esté libre.',
            ),
            backgroundColor: Colors.red.shade700,
          ),
        );
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
            'tray_items': [
              {
                'template_id': tpl.id,
                'code': 'EQ1',
                'name': '${tpl.manufacturer} ${tpl.modelName}',
                'manufacturer': tpl.manufacturer,
                'model_name': tpl.modelName,
                'ip_address': '10.28.1.${60 + targetStartU}',
              },
            ],
          },
        });
        await _loadRack();
        setState(() {
          _selectedDeviceId = createdTray.id;
          _selectedTemplateForClick = null;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Bandeja BDJ$trayCount montada en U$targetStartU con "${tpl.manufacturer} ${tpl.modelName}" alojado encima. Pulsa "+ Equipos en Bandeja" para meter más.',
              ),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700),
          );
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'No se puede montar "${tpl.modelName}" (${tpl.uHeight}U) en U$targetStartU${tpl.uHeight > 1 ? '-U$targetEndU' : ''}: necesita ${tpl.uHeight}U libres consecutivas ($reason).',
          ),
          backgroundColor: Colors.red.shade700,
        ),
      );
      return;
    }

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
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: Text(
            'Montar ${tpl.modelName} en U$targetStartU (Configura Front y Back)',
          ),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    margin: const EdgeInsets.only(bottom: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: const Color(0xFF93C5FD)),
                    ),
                    child: const Row(
                      children: [
                        Icon(
                          Icons.sync_alt,
                          size: 16,
                          color: Color(0xFF1D4ED8),
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Puedes personalizar cuántas bocas RJ45, SFP Fibra, Tomas PSU y Schuko lleva este equipo tanto por DELANTE (Front) como por DETRÁS (Back).',
                            style: TextStyle(
                              fontSize: 11,
                              color: Color(0xFF1E3A8A),
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
                  if (!tpl.isRackTray && !tpl.isRoofFan) ...[
                    const Divider(height: 22),
                    const Text(
                      '1. BOCAS EN CARA DELANTERA (FRONT):',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF0F172A),
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
                        color: Color(0xFF1E3A8A),
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
        'mounted_face': _activeFace == 'back' ? 'back' : 'front',
        'ip_address': ipCtrl.text.trim(),
        'subnet_mask': maskCtrl.text.trim(),
        'gateway': gwCtrl.text.trim(),
        'monitoring_enabled': ipCtrl.text.trim().isNotEmpty,
        'custom_fields': {
          if (chosenUHeight != tpl.uHeight) 'u_height_override': chosenUHeight,
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
      setState(() {
        _selectedDeviceId = created.id;
        _selectedConnectionId = null;
        _selectedTemplateForClick = null;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700),
        );
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
      setState(() {
        _selectedConnectionId = existingConn!.id;
        _selectedDeviceId = null;
      });
      return;
    }

    if (!_canEdit) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Modo lectura: tu rol actual no permite crear nuevos cables.',
          ),
        ),
      );
      return;
    }

    if (existingConn != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'La boca ${dev.code}:${port.portNumber} ya está ocupada por un cable. Selecciónala sin cable activo para editarla o desconectarla.',
          ),
        ),
      );
      return;
    }

    if (_pendingSourcePort == null) {
      setState(() {
        _pendingSourcePort = port;
        _pendingSourceDevice = dev;
      });
      return;
    }

    if (_pendingSourcePort!.id == port.id) {
      setState(() {
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

    if (srcDev.isExternalFeed) {
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

    String cableType = defaultCableType;
    String colorHex = defaultColor;
    String channel = (srcDev.isExternalFeed || dev.isExternalFeed)
        ? 'right'
        : 'auto';
    final labelCtrl = TextEditingController(
      text: forcedExternalFeedName != null
          ? '${isExtFiber ? 'Fibra Exterior' : 'Alimentación'} $forcedExternalFeedName ➔ ${srcDev.isExternalFeed ? dev.code : srcDev.code}'
          : '${srcDev.code}:${srcPort.portNumber} ➔ ${dev.code}:${port.portNumber}',
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
                    color: const Color(0xFFF1F5F9),
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
                  style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
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

    setState(() {
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
        setState(() {
          _selectedConnectionId = created.id;
          _selectedDeviceId = null;
        });
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700),
          );
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
      messenger.showSnackBar(
        SnackBar(
          content: Text('Error obteniendo otros racks: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
      return;
    }

    if (otherRacks.isEmpty) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'No hay otros Racks dados de alta en el Datacenter para conectar fibra/cable Inter-Rack.',
          ),
        ),
      );
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
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Este rack no tiene equipos con puertos para conectar.'),
        ),
      );
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
              Icon(Icons.cable, color: Color(0xFF0284C7), size: 22),
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
                      color: const Color(0xFFF0F9FF),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFBAE6FD)),
                    ),
                    child: const Text(
                      '💡 Las fibras o cables entre Racks se trazan hacia la Bandeja Aérea Inter-Rack superior con una etiqueta interactiva (⇢ RACK destino) que te permite saltar al otro Rack con 1 clic.',
                      style: TextStyle(fontSize: 11.5, color: Color(0xFF0369A1)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 1. ORIGEN EN ESTE RACK
                  Text(
                    '1. ORIGEN EN ESTE RACK (${rack.code} — ${rack.name})',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1E3A8A),
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

    setState(() {
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
        setState(() {
          _selectedConnectionId = created.id;
          _selectedDeviceId = null;
        });
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Fibra / Cable Inter-Rack conectado hacia ${selectedTargetRack['code']} (${selectedTargetDev?['code']}:${selectedTargetPort!['port_number']}).',
            ),
          ),
        );
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700),
        );
      }
    }
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
                    color: Color(0xFF1D4ED8),
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
                          color: Color(0xFF475569),
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
                            color: Color(0xFFDC2626),
                          ),
                        )
                      else if (searchResults.isNotEmpty) ...[
                        const Text(
                          'Resultados encontrados en Internet (haz clic en una foto para usarla):',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFF1E293B),
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
                                        ? const Color(0xFFDBEAFE)
                                        : const Color(0xFFF8FAFC),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: isSel
                                          ? const Color(0xFF2563EB)
                                          : const Color(0xFFCBD5E1),
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
                                            thumb,
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
                            color: const Color(0xFF0F172A),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Image.network(
                            urlCtrl.text.trim(),
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
        setState(() => _showEquipmentPhotos = true);
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
        messenger.showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700),
        );
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
      messenger.showSnackBar(
        SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700),
      );
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
                      color: Color(0xFF475569),
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
                            color: Color(0xFF475569),
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
                      color: Color(0xFF1E293B),
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
        messenger.showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700),
        );
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
          backgroundColor: Color(0xFFD97706),
        ),
      );
      return;
    }

    try {
      await widget.api.deleteExternalOutlet(ext.id);
      await _loadRack();
      messenger.showSnackBar(
        SnackBar(content: Text('Toma exterior "${ext.code}" eliminada.')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700),
      );
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
                    color: Color(0xFF475569),
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  height: 280,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      prettyJson,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: Color(0xFFE2E8F0),
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
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text(
                      'JSON de la librería copiado al portapapeles.',
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copiar JSON'),
            ),
          ],
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Error exportando librería: $e')),
      );
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
        setState(() => _selectedLibraryGroup = targetGroup);
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Librería "$targetGroup" importada: ${res['created']} creados, ${res['updated']} actualizados.',
            ),
          ),
        );
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(
            content: Text('Error importando JSON: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
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
              color: Color(0xFF1D4ED8),
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
                style: TextStyle(fontSize: 11.5, color: Color(0xFF475569)),
              ),
              const SizedBox(height: 14),
              const Text(
                '1. BOCAS EN CARA DELANTERA (FRONT):',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF0F172A),
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
                  color: Color(0xFF1E3A8A),
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
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Bocas Front y Back de "${dev.code}" actualizadas correctamente.',
            ),
          ),
        );
      } catch (e) {
        messenger.showSnackBar(
          SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700),
        );
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
                    style: TextStyle(fontSize: 11, color: Color(0xFF64748B)),
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
                      color: Color(0xFF0F172A),
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
                      color: Color(0xFF1E3A8A),
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
      setState(() => _selectedLibraryGroup = targetLib);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null || _rack == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Error cargando el rack: $_error'),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _loadRack,
              child: const Text('Reintentar'),
            ),
          ],
        ),
      );
    }

    final rack = _rack!;
    final bc = rack.breadcrumb;
    final extOutlets = _getExternalOutlets(rack);
    final totalCanvasHeight =
        _rackTopMargin + rack.totalUnits * _uHeightPx + 75.0;

    final portCoords = _computePortCoordinates(rack);
    final outboundAnchor = Offset(
      (_isDualFace ? _backRackOuterLeft : _rackOuterLeft) +
          _rackOuterWidth -
          36,
      22,
    );

    final computedRoutes = CableGeometryBuilder.computeRoutes(
      connections: rack.connections,
      portPositionsOnActiveFace: portCoords,
      activeFace: _activeFace,
      currentRackId: rack.id,
      leftChannelBaseX: _rackInnerLeft - 24.0,
      rightChannelBaseX: _rackInnerLeft + _rackInnerWidth + 24.0,
      backLeftChannelBaseX: _isDualFace ? (_backRackInnerLeft - 24.0) : null,
      backRightChannelBaseX: _isDualFace
          ? (_backRackInnerLeft + _rackInnerWidth + 24.0)
          : null,
      outboundAnchor: outboundAnchor,
      cableFilter: _cableFilter,
    );

    final activeSourceOffset = _pendingSourcePort != null
        ? portCoords[_pendingSourcePort!.id]
        : null;

    // Contar puertos conectados para colorear las bocas ocupadas
    final connectedPortColors = <int, Color>{};
    for (final c in rack.connections) {
      final col = CableGeometryBuilder.parseHexColor(c.colorHex);
      connectedPortColors[c.sourcePortId] = col;
      connectedPortColors[c.targetPortId] = col;
    }

    // Determinar qué unidades U están ocupadas (excluyendo el equipo que se está arrastrando actualmente
    // para que sus propias U queden disponibles si se desplaza 1U arriba/abajo un equipo de 2U/4U)
    final draggingDevId = _draggingData is RackDeviceModel
        ? (_draggingData as RackDeviceModel).id
        : null;
    final occupiedUsFront = <int>{};
    final occupiedUsBack = <int>{};
    for (final d in rack.devices) {
      if (d.id == draggingDevId) continue;
      if (d.isVisibleOnFace('front')) {
        for (int u = d.startU; u <= d.endU; u++) {
          occupiedUsFront.add(u);
        }
      }
      if (d.isVisibleOnFace('back')) {
        for (int u = d.startU; u <= d.endU; u++) {
          occupiedUsBack.add(u);
        }
      }
    }

    final outboundConnections =
        rack.connections.where((c) => c.isOutbound).toList();
    final selDev = _selectedDevice;
    final selConn = _selectedConnection;
    final nextFreeUpU = (selDev != null && !selDev.isExternalFeed)
        ? _findNearestFreeU(rack, selDev, 1)
        : null;
    final nextFreeDownU = (selDev != null && !selDev.isExternalFeed)
        ? _findNearestFreeU(rack, selDev, -1)
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. BARRA SUPERIOR (Nombre del Rack + Breadcrumb + Controles Rápidos de Mover/Borrar Elemento)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
          ),
          child: Row(
            children: [
              IconButton(
                onPressed: widget.onBackToLocations,
                icon: const Icon(Icons.arrow_back_rounded, size: 20),
                tooltip: 'Volver al Mapa de Sedes y Pasillos',
              ),
              const SizedBox(width: 6),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    rack.name,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                  InkWell(
                    onTap: widget.onBackToLocations,
                    child: Text(
                      'PBX  >  Locations  >  ${bc['location_code']}  >  ${bc['room_name']?.toString().split(' ').first ?? '28'}  >  ${rack.code}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 14),
              // Resumen de Sistemas Monitorizados (Heartbeat) en este Rack y su estado (Verde / Rojo / Ámbar)
              Builder(
                builder: (_) {
                  final monDevs = rack.devices
                      .where((d) => !d.isExternalFeed && d.monitoringEnabled)
                      .toList();
                  final onlineCnt =
                      monDevs.where((d) => d.status == 'online').length;
                  final offlineCnt =
                      monDevs.where((d) => d.status == 'offline').length;
                  final warnCnt = monDevs.length - onlineCnt - offlineCnt;
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: offlineCnt > 0
                            ? const Color(0xFFFCA5A5)
                            : const Color(0xFFCBD5E1),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.monitor_heart_outlined,
                          size: 14,
                          color: Color(0xFF0F172A),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          'Monitorizados: ${monDevs.length}',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                        if (onlineCnt > 0) ...[
                          const SizedBox(width: 8),
                          Container(
                            width: 7,
                            height: 7,
                            decoration: const BoxDecoration(
                              color: Color(0xFF16A34A),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 3),
                          Text(
                            '$onlineCnt',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFF15803D),
                            ),
                          ),
                        ],
                        if (offlineCnt > 0) ...[
                          const SizedBox(width: 7),
                          Container(
                            width: 7,
                            height: 7,
                            decoration: const BoxDecoration(
                              color: Color(0xFFDC2626),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 3),
                          Text(
                            '$offlineCnt',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFFB91C1C),
                            ),
                          ),
                        ],
                        if (warnCnt > 0) ...[
                          const SizedBox(width: 7),
                          Container(
                            width: 7,
                            height: 7,
                            decoration: const BoxDecoration(
                              color: Color(0xFFD97706),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 3),
                          Text(
                            '$warnCnt',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFFB45309),
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
              const Spacer(),

              // Selector / Buscador rápido de Equipos o Alarmas en este Rack (con resaltado de fondo gris)
              PopupMenuButton<int>(
                tooltip:
                    'Buscar o localizar un equipo / alarma en este Rack (resaltado con fondo gris)',
                onSelected: (devId) {
                  setState(() {
                    _selectedDeviceId = devId;
                    _highlightedDeviceId = devId;
                  });
                },
                itemBuilder: (ctx) {
                  final list = rack.devices
                      .where((d) => !d.isExternalFeed)
                      .toList()
                    ..sort((a, b) => b.startU.compareTo(a.startU));
                  return list.map((d) {
                    final isAlarm =
                        d.monitoringEnabled && d.status != 'online';
                    return PopupMenuItem<int>(
                      value: d.id,
                      child: Row(
                        children: [
                          Icon(
                            isAlarm
                                ? Icons.warning_amber_rounded
                                : (d.isRackTray
                                    ? Icons.inbox_outlined
                                    : Icons.dns_outlined),
                            size: 16,
                            color: isAlarm
                                ? const Color(0xFFDC2626)
                                : const Color(0xFF334155),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'U${d.startU} • ${d.code} — ${d.name}${d.isRackTray && d.trayItems.isNotEmpty ? ' [${d.trayItems.length} mini-eq]' : ''}',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: d.id == _highlightedDeviceId ||
                                        d.id == _selectedDeviceId
                                    ? FontWeight.w800
                                    : FontWeight.w600,
                                color: isAlarm
                                    ? const Color(0xFFB91C1C)
                                    : const Color(0xFF0F172A),
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList();
                },
                child: Container(
                  margin: const EdgeInsets.only(right: 10),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: _highlightedDeviceId != null
                        ? const Color(0xFFE2E8F0)
                        : const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFCBD5E1)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.search_rounded,
                        size: 15,
                        color: Color(0xFF334155),
                      ),
                      SizedBox(width: 5),
                      Text(
                        'Localizar en Rack',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1E293B),
                        ),
                      ),
                      SizedBox(width: 3),
                      Icon(
                        Icons.arrow_drop_down,
                        size: 16,
                        color: Color(0xFF475569),
                      ),
                    ],
                  ),
                ),
              ),

              // Conmutador directo en barra superior: [Front | Back | Front & Back]
              Container(
                margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: const Color(0xFFCBD5E1)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _FaceToggleButton(
                      label: 'Front',
                      active: _activeFace == 'front',
                      onTap: () => _setFaceMode('front'),
                    ),
                    _FaceToggleButton(
                      label: 'Back',
                      active: _activeFace == 'back',
                      onTap: () => _setFaceMode('back'),
                    ),
                    _FaceToggleButton(
                      label: 'Front & Back',
                      active: _activeFace == 'both',
                      onTap: () => _setFaceMode('both'),
                    ),
                  ],
                ),
              ),

              // Barra rápida cuando hay un equipo seleccionado: Subir 1U, Bajar 1U, Ajustar U ocupadas, Equipos en Bandeja, Foto, Cable Inter-Rack, Borrar Equipo
              if (_canEdit && selDev != null && !selDev.isExternalFeed)
                Container(
                  margin: const EdgeInsets.only(right: 10),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF93C5FD)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${selDev.code} (U${selDev.startU}•${selDev.uHeight}U): ',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF1E3A8A),
                        ),
                      ),
                      IconButton(
                        onPressed: nextFreeUpU != null
                            ? () => _moveDeviceToU(selDev, nextFreeUpU)
                            : null,
                        icon: const Icon(Icons.arrow_upward_rounded, size: 15),
                        tooltip: nextFreeUpU != null
                            ? 'Subir a siguiente posición con ${selDev.uHeight}U libres (U$nextFreeUpU)'
                            : 'No hay ${selDev.uHeight}U libres por encima',
                        visualDensity: VisualDensity.compact,
                      ),
                      IconButton(
                        onPressed: nextFreeDownU != null
                            ? () => _moveDeviceToU(selDev, nextFreeDownU)
                            : null,
                        icon: const Icon(
                          Icons.arrow_downward_rounded,
                          size: 15,
                        ),
                        tooltip: nextFreeDownU != null
                            ? 'Bajar a siguiente posición con ${selDev.uHeight}U libres (U$nextFreeDownU)'
                            : 'No hay ${selDev.uHeight}U libres por debajo',
                        visualDensity: VisualDensity.compact,
                      ),
                      // Control rápido de cuántas U ocupa (especialmente útil para Bandejas y equipos misceláneos)
                      Container(
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFF93C5FD)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            InkWell(
                              onTap: selDev.uHeight > 1
                                  ? () => _quickAdjustDeviceUHeight(
                                        selDev,
                                        selDev.uHeight - 1,
                                      )
                                  : null,
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 3),
                                child: Icon(
                                  Icons.remove,
                                  size: 12,
                                  color: Color(0xFF1D4ED8),
                                ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 3,
                              ),
                              child: Text(
                                '${selDev.uHeight}U',
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF1E3A8A),
                                ),
                              ),
                            ),
                            InkWell(
                              onTap: selDev.uHeight < 16
                                  ? () => _quickAdjustDeviceUHeight(
                                        selDev,
                                        selDev.uHeight + 1,
                                      )
                                  : null,
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 3),
                                child: Icon(
                                  Icons.add,
                                  size: 12,
                                  color: Color(0xFF1D4ED8),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (selDev.isRackTray)
                        Padding(
                          padding: const EdgeInsets.only(right: 4),
                          child: FilledButton.tonalIcon(
                            onPressed: () =>
                                _showManageTrayItemsDialog(selDev),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFFEDE9FE),
                              foregroundColor: const Color(0xFF6D28D9),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 4,
                              ),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            icon: const Icon(Icons.inbox_outlined, size: 14),
                            label: Text(
                              '+ Equipos en Bandeja (${selDev.trayItems.length})',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                      TextButton.icon(
                        onPressed: () =>
                            _showConfigureDevicePortsDialog(selDev),
                        icon: const Icon(
                          Icons.settings_input_component,
                          size: 14,
                        ),
                        label: const Text(
                          'Bocas F/B',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () =>
                            _showHardwarePhotoSearchDialog(device: selDev),
                        icon: const Icon(Icons.photo_camera_outlined, size: 14),
                        label: const Text(
                          'Foto',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => _showInterRackConnectionDialog(
                          initialSourceDev: selDev,
                        ),
                        icon: const Icon(Icons.compare_arrows, size: 14),
                        label: const Text(
                          'A Otro Rack',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => _showMoveDeviceToUDialog(selDev),
                        icon: const Icon(Icons.swap_vert, size: 14),
                        label: const Text(
                          'Mover a U...',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => _quickDeleteDevice(selDev),
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFFDC2626),
                        ),
                        icon: const Icon(Icons.delete_outline, size: 15),
                        label: const Text(
                          'Borrar',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              // Barra rápida cuando hay un cable seleccionado: Borrar Cable en 1 clic
              if (_canEdit && selConn != null)
                Container(
                  margin: const EdgeInsets.only(right: 10),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFEF2F2),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFFCA5A5)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Cable ${selConn.sourceInfo.deviceCode}:${selConn.sourceInfo.portNumber} ➔ ${selConn.targetInfo.deviceCode}:${selConn.targetInfo.portNumber}',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF991B1B),
                        ),
                      ),
                      const SizedBox(width: 6),
                      TextButton.icon(
                        onPressed: () async {
                          await widget.api.deleteConnection(selConn.id);
                          setState(() => _selectedConnectionId = null);
                          await _loadRack();
                        },
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFFDC2626),
                        ),
                        icon: const Icon(Icons.link_off, size: 15),
                        label: const Text(
                          'Borrar Cable',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              if (_pendingSourcePort != null)
                Container(
                  margin: const EdgeInsets.only(right: 12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDBEAFE),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFF2563EB)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.cable,
                        size: 15,
                        color: Color(0xFF1D4ED8),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Tirando desde ${_pendingSourceDevice?.code}:${_pendingSourcePort?.portNumber} — Clic en boca Front/Back',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1E3A8A),
                        ),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () {
                          final srcDev = _pendingSourceDevice;
                          final srcPort = _pendingSourcePort;
                          setState(() {
                            _pendingSourcePort = null;
                            _pendingSourceDevice = null;
                          });
                          _showInterRackConnectionDialog(
                            initialSourceDev: srcDev,
                            initialSourcePort: srcPort,
                          );
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1D4ED8),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.compare_arrows,
                                size: 12,
                                color: Colors.white,
                              ),
                              SizedBox(width: 4),
                              Text(
                                'Llevar a Otro Rack...',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () => setState(() {
                          _pendingSourcePort = null;
                          _pendingSourceDevice = null;
                        }),
                        child: const Icon(
                          Icons.close,
                          size: 15,
                          color: Color(0xFF1E3A8A),
                        ),
                      ),
                    ],
                  ),
                ),
              if (_canConnectRemote)
                OutlinedButton.icon(
                  onPressed: () async {
                    final messenger = ScaffoldMessenger.of(context);
                    await widget.api.pingAllRackDevices(rack.id);
                    await _loadRack();
                    if (mounted) {
                      messenger.showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Chequeo de Ping completado en todos los equipos del rack.',
                          ),
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.network_ping, size: 16),
                  label:
                      const Text('Ping Rack', style: TextStyle(fontSize: 12)),
                ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () {
                  final url = Uri.parse(
                    widget.api.getExcelExportUrl(rackId: rack.id),
                  );
                  launchUrl(url, mode: LaunchMode.externalApplication);
                },
                icon: const Icon(Icons.table_view_outlined, size: 16),
                label:
                    const Text('Excel (.xlsx)', style: TextStyle(fontSize: 12)),
              ),
              if (_canEdit) ...[
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _confirmDeleteCurrentRack,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFDC2626),
                    side: const BorderSide(color: Color(0xFFFCA5A5)),
                  ),
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text(
                    'Eliminar Rack',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ],
          ),
        ),

        // 2. CUERPO CENTRAL EN 3 COLUMNAS: Catálogo Izquierdo | Lienzo Central 42U (Front+Back / Individual) + Tomas Exteriores | Panel Derecho
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // COLUMNA IZQUIERDA: Librería de Dispositivos (con Storage SAN, Storage NAS, Ventiladores y Bandejas U editables)
              DeviceCatalogPanel(
                templates: widget.templates,
                selectedTemplateForClickMount: _selectedTemplateForClick,
                onSelectTemplate: (tpl) {
                  setState(() => _selectedTemplateForClick = tpl);
                },
                onCreateCustomTemplate: _showCreateCustomTemplateDialog,
                onConfigureTemplatePhoto: (tpl) =>
                    _showHardwarePhotoSearchDialog(template: tpl),
                selectedLibraryGroup: _selectedLibraryGroup,
                onSelectLibraryGroup: (group) {
                  setState(() => _selectedLibraryGroup = group);
                },
                onExportLibrary: _handleExportLibraryDialog,
                onImportLibrary: _handleImportLibraryDialog,
                canEdit: _canEdit,
              ),

              // COLUMNA CENTRAL: Lienzo interactivo del Rack con soporte simultáneo Front + Back y Bandeja Inter-Rack
              Expanded(
                child: Container(
                  color: const Color(0xFFF4F5F7),
                  child: Stack(
                    children: [
                      InteractiveViewer(
                        transformationController: _transformController,
                        minScale: 0.38,
                        maxScale: 2.8,
                        boundaryMargin: const EdgeInsets.all(320),
                        constrained: false,
                        child: MouseRegion(
                          onHover: (event) {
                            if (_pendingSourcePort != null) {
                              setState(
                                () => _cursorCanvasPos = event.localPosition,
                              );
                              return;
                            }
                            int? hitId;
                            double bestDist = 7.0;
                            for (final r in computedRoutes) {
                              final d =
                                  CableGeometryBuilder.distanceToPolyline(
                                event.localPosition,
                                r.points,
                              );
                              if (d < bestDist) {
                                bestDist = d;
                                hitId = r.connection.id;
                              }
                            }
                            if (hitId != _hoveredConnectionId) {
                              setState(() => _hoveredConnectionId = hitId);
                            }
                          },
                          child: GestureDetector(
                            onTapUp: (details) {
                              for (final r in computedRoutes) {
                                final d =
                                    CableGeometryBuilder.distanceToPolyline(
                                  details.localPosition,
                                  r.points,
                                );
                                if (d < 8.0) {
                                  setState(() {
                                    _selectedConnectionId = r.connection.id;
                                    _selectedDeviceId = null;
                                  });
                                  return;
                                }
                              }
                            },
                            child: SizedBox(
                              width: _effectiveCanvasWidth,
                              height: totalCanvasHeight,
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  if (_isDualFace) ...[
                                    // BASTIDOR 1 (IZQUIERDA): ALZADO DELANTERO (FRONT)
                                    ..._buildSingleRackCabinetStack(
                                      rack: rack,
                                      face: 'front',
                                      faceBannerLabel: 'FRONT (DELANTE)',
                                      faceBannerColor: const Color(0xFF0F172A),
                                      outerLeft: _rackOuterLeft,
                                      innerLeft: _rackInnerLeft,
                                      occupiedUsOnFace: occupiedUsFront,
                                      connectedPortColors: connectedPortColors,
                                      showDropPreview: true,
                                    ),

                                    // PASAMUROS CENTRAL FRONT ↔ BACK
                                    Positioned(
                                      left:
                                          _rackOuterLeft + _rackOuterWidth + 28,
                                      top: _rackTopMargin - 42,
                                      width: _dualFaceGap - 56,
                                      height:
                                          rack.totalUnits * _uHeightPx + 62,
                                      child: IgnorePointer(
                                        child: Column(
                                          children: [
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 8,
                                                vertical: 4,
                                              ),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF1E293B),
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                border: Border.all(
                                                  color:
                                                      const Color(0xFF38BDF8),
                                                ),
                                              ),
                                              child: const Text(
                                                '⇄ PASAMUROS F↔B',
                                                style: TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 8.5,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                            ),
                                            Expanded(
                                              child: Container(
                                                width: 2,
                                                margin:
                                                    const EdgeInsets.symmetric(
                                                  vertical: 6,
                                                ),
                                                color: const Color(0xFFCBD5E1),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),

                                    // BASTIDOR 2 (DERECHA): ALZADO TRASERO (BACK)
                                    ..._buildSingleRackCabinetStack(
                                      rack: rack,
                                      face: 'back',
                                      faceBannerLabel: 'BACK (DETRÁS)',
                                      faceBannerColor: const Color(0xFF1E3A8A),
                                      outerLeft: _backRackOuterLeft,
                                      innerLeft: _backRackInnerLeft,
                                      occupiedUsOnFace: occupiedUsBack,
                                      connectedPortColors: connectedPortColors,
                                      showDropPreview: false,
                                    ),
                                  ] else ...[
                                    // MODO INDIVIDUAL (SOLO FRONT O SOLO BACK)
                                    ..._buildSingleRackCabinetStack(
                                      rack: rack,
                                      face: _activeFace,
                                      faceBannerLabel: _activeFace == 'front'
                                          ? 'FRONT (DELANTE)'
                                          : 'BACK (DETRÁS)',
                                      faceBannerColor: _activeFace == 'front'
                                          ? const Color(0xFF0F172A)
                                          : const Color(0xFF1E3A8A),
                                      outerLeft: _rackOuterLeft,
                                      innerLeft: _rackInnerLeft,
                                      occupiedUsOnFace: _activeFace == 'front'
                                          ? occupiedUsFront
                                          : occupiedUsBack,
                                      connectedPortColors: connectedPortColors,
                                      showDropPreview: true,
                                    ),
                                  ],

                                  // C2. TOMAS ELÉCTRICAS EXTERIORES Y CAJAS EXTERIORES DE FIBRA
                                  _buildExternalPowerOutletsZone(
                                    extOutlets: extOutlets,
                                    connectedPortColors: connectedPortColors,
                                  ),

                                  // D. Capa de Cables Ortogonales (Intra-Rack, Front↔Back e Inter-Rack)
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      child: CustomPaint(
                                        painter: RackCablePainter(
                                          routes: computedRoutes,
                                          selectedConnectionId:
                                              _selectedConnectionId,
                                          hoveredConnectionId:
                                              _hoveredConnectionId,
                                          activeSourcePortOffset:
                                              activeSourceOffset,
                                          cursorPosition: _cursorCanvasPos,
                                        ),
                                      ),
                                    ),
                                  ),

                                  // D2. OPCIÓN 3: BANDEROLAS "CROSS-CONNECT" CLICABLES EN EL LATERAL DEL RACK
                                  ...computedRoutes
                                      .where(
                                        (r) =>
                                            r.isOutbound &&
                                            r.badgePosition != null,
                                      )
                                      .map((r) {
                                    final c = r.connection;
                                    final isSrcHere =
                                        c.sourceInfo.rackId == rack.id;
                                    final localEnd = isSrcHere
                                        ? c.sourceInfo
                                        : c.targetInfo;
                                    final remoteEnd = isSrcHere
                                        ? c.targetInfo
                                        : c.sourceInfo;
                                    final cCol =
                                        CableGeometryBuilder.parseHexColor(
                                      c.colorHex,
                                    );
                                    final isSel =
                                        _selectedConnectionId == c.id;
                                    final isHov =
                                        _hoveredConnectionId == c.id;
                                    final pin = r.badgePosition!;
                                    return Positioned(
                                      left: pin.dx + 4,
                                      top: pin.dy - 12,
                                      child: MouseRegion(
                                        onEnter: (_) => setState(
                                          () => _hoveredConnectionId = c.id,
                                        ),
                                        onExit: (_) {
                                          if (_hoveredConnectionId == c.id) {
                                            setState(
                                              () => _hoveredConnectionId = null,
                                            );
                                          }
                                        },
                                        child: GestureDetector(
                                          onTap: () {
                                            setState(() {
                                              _selectedConnectionId = c.id;
                                              _selectedDeviceId = null;
                                            });
                                          },
                                          onDoubleTap: () {
                                            if (widget.onJumpToRackAndDevice !=
                                                null) {
                                              widget.onJumpToRackAndDevice!(
                                                remoteEnd.rackId,
                                                remoteEnd.deviceId,
                                              );
                                            } else {
                                              widget.onSwitchRack(
                                                remoteEnd.rackId,
                                              );
                                            }
                                          },
                                          child: Tooltip(
                                            message:
                                                'BANDEROLA CROSS-CONNECT INTER-RACK\n'
                                                '• Origen local: ${localEnd.deviceCode}:${localEnd.portNumber} (${localEnd.face.toUpperCase()})\n'
                                                '• Destino remoto: ${remoteEnd.rackCode} • ${remoteEnd.deviceCode}:${remoteEnd.portNumber}\n'
                                                '• 1 Clic: Seleccionar cable y ver propiedades\n'
                                                '• Doble Clic o botón ↗: Saltar a ${remoteEnd.rackCode} resaltando ${remoteEnd.deviceCode}',
                                            child: AnimatedContainer(
                                              duration: const Duration(
                                                milliseconds: 140,
                                              ),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 7,
                                                vertical: 3.5,
                                              ),
                                              decoration: BoxDecoration(
                                                color: isSel
                                                    ? cCol
                                                    : (isHov
                                                        ? const Color(
                                                            0xFF1E293B,
                                                          )
                                                        : const Color(
                                                            0xFF0F172A,
                                                          )),
                                                borderRadius:
                                                    const BorderRadius.only(
                                                  topLeft: Radius.circular(3),
                                                  bottomLeft:
                                                      Radius.circular(3),
                                                  topRight:
                                                      Radius.circular(12),
                                                  bottomRight:
                                                      Radius.circular(12),
                                                ),
                                                border: Border.all(
                                                  color: isSel || isHov
                                                      ? Colors.white
                                                      : cCol,
                                                  width:
                                                      isSel || isHov ? 1.8 : 1.4,
                                                ),
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: cCol.withValues(
                                                      alpha: isSel || isHov
                                                          ? 0.48
                                                          : 0.25,
                                                    ),
                                                    blurRadius:
                                                        isSel || isHov ? 8 : 4,
                                                    offset: const Offset(0, 2),
                                                  ),
                                                ],
                                              ),
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Container(
                                                    width: 7,
                                                    height: 7,
                                                    decoration: BoxDecoration(
                                                      color: isSel
                                                          ? Colors.white
                                                          : cCol,
                                                      shape: BoxShape.circle,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 4),
                                                  const Icon(
                                                    Icons.label_important,
                                                    size: 11,
                                                    color: Color(0xFF38BDF8),
                                                  ),
                                                  const SizedBox(width: 3),
                                                  Text(
                                                    '➔ ${remoteEnd.rackCode} • ${remoteEnd.deviceCode}:${remoteEnd.portNumber}',
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 9.2,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      letterSpacing: 0.1,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 5),
                                                  InkWell(
                                                    onTap: () {
                                                      if (widget
                                                              .onJumpToRackAndDevice !=
                                                          null) {
                                                        widget
                                                            .onJumpToRackAndDevice!(
                                                          remoteEnd.rackId,
                                                          remoteEnd.deviceId,
                                                        );
                                                      } else {
                                                        widget.onSwitchRack(
                                                          remoteEnd.rackId,
                                                        );
                                                      }
                                                    },
                                                    child: Container(
                                                      padding:
                                                          const EdgeInsets.all(
                                                        2,
                                                      ),
                                                      decoration: BoxDecoration(
                                                        color: Colors.white
                                                            .withValues(
                                                          alpha: 0.16,
                                                        ),
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(4),
                                                      ),
                                                      child: const Icon(
                                                        Icons.open_in_new,
                                                        size: 10,
                                                        color:
                                                            Color(0xFF38BDF8),
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  }),

                                  // D3. BANDEROLA CROSS-CONNECT FLOTANTE DE CONEXIÓN RÁPIDA CUANDO HAY UN PUERTO ORIGEN SELECCIONADO
                                  if (_pendingSourcePort != null &&
                                      activeSourceOffset != null)
                                    Builder(
                                      builder: (_) {
                                        final srcPort = _pendingSourcePort!;
                                        RackDeviceModel? srcDev;
                                        for (final d in rack.devices) {
                                          if (d.ports.any(
                                            (p) => p.id == srcPort.id,
                                          )) {
                                            srcDev = d;
                                            break;
                                          }
                                        }
                                        final isBack =
                                            (srcPort.face).toLowerCase() ==
                                                'back';
                                        final flagLeft = (_isDualFace && isBack)
                                            ? (_backRackOuterLeft +
                                                _rackOuterWidth +
                                                12)
                                            : (_rackOuterLeft +
                                                _rackOuterWidth +
                                                12);
                                        return Positioned(
                                          left: flagLeft,
                                          top: activeSourceOffset.dy - 14,
                                          child: Material(
                                            color: Colors.transparent,
                                            child: InkWell(
                                              onTap: () {
                                                final dev = srcDev;
                                                final port = srcPort;
                                                setState(() {
                                                  _pendingSourcePort = null;
                                                });
                                                _showInterRackConnectionDialog(
                                                  initialSourceDev: dev,
                                                  initialSourcePort: port,
                                                );
                                              },
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 10,
                                                  vertical: 5,
                                                ),
                                                decoration: BoxDecoration(
                                                  gradient:
                                                      const LinearGradient(
                                                    colors: [
                                                      Color(0xFF0284C7),
                                                      Color(0xFF2563EB),
                                                    ],
                                                  ),
                                                  borderRadius:
                                                      const BorderRadius.only(
                                                    topLeft: Radius.circular(4),
                                                    bottomLeft:
                                                        Radius.circular(4),
                                                    topRight:
                                                        Radius.circular(14),
                                                    bottomRight:
                                                        Radius.circular(14),
                                                  ),
                                                  border: Border.all(
                                                    color: Colors.white,
                                                    width: 1.5,
                                                  ),
                                                  boxShadow: const [
                                                    BoxShadow(
                                                      color: Color(0x550284C7),
                                                      blurRadius: 10,
                                                      offset: Offset(0, 3),
                                                    ),
                                                  ],
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    const Icon(
                                                      Icons.label_important,
                                                      size: 13,
                                                      color: Colors.white,
                                                    ),
                                                    const SizedBox(width: 5),
                                                    Text(
                                                      '🏷️ ➔ Conectar ${srcDev?.code ?? ''}:${srcPort.portNumber} a Otro Rack...',
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 10,
                                                        fontWeight:
                                                            FontWeight.w900,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    ),

                                  // E. BANDEJA AÉREA INTER-RACK SUPERIOR CON PÍLDORAS INTERACTIVAS DE SALTO A OTROS RACKS
                                  Positioned(
                                    left: _rackOuterLeft,
                                    top: 4,
                                    width: _isDualFace
                                        ? (_backRackOuterLeft +
                                            _rackOuterWidth -
                                            _rackOuterLeft)
                                        : _rackOuterWidth,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF0F172A),
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(
                                          color: outboundConnections.isNotEmpty
                                              ? const Color(0xFF10B981)
                                              : const Color(0xFF475569),
                                          width: 1.5,
                                        ),
                                        boxShadow: const [
                                          BoxShadow(
                                            color: Color(0x22000000),
                                            blurRadius: 8,
                                            offset: Offset(0, 2),
                                          ),
                                        ],
                                      ),
                                      child: Row(
                                        children: [
                                          const Icon(
                                            Icons.compare_arrows_rounded,
                                            size: 16,
                                            color: Color(0xFF38BDF8),
                                          ),
                                          const SizedBox(width: 6),
                                          Text(
                                            'BANDEJA AÉREA INTER-RACK (${outboundConnections.length} fibras/cables hacia otros Racks):',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 10.5,
                                              fontWeight: FontWeight.w800,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: outboundConnections.isEmpty
                                                ? const Text(
                                                    'Ningún cable sale a otro Rack aún. Pulsa "+ Conectar con Otro Rack" para enlazar fibras/cables entre Racks.',
                                                    style: TextStyle(
                                                      color: Color(0xFF94A3B8),
                                                      fontSize: 10,
                                                    ),
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  )
                                                : SingleChildScrollView(
                                                    scrollDirection:
                                                        Axis.horizontal,
                                                    child: Row(
                                                      children:
                                                          outboundConnections
                                                              .map((c) {
                                                        final isSrcHere = c
                                                                .sourceInfo
                                                                .rackId ==
                                                            rack.id;
                                                        final localEnd =
                                                            isSrcHere
                                                                ? c.sourceInfo
                                                                : c.targetInfo;
                                                        final remoteEnd =
                                                            isSrcHere
                                                                ? c.targetInfo
                                                                : c.sourceInfo;
                                                        final cCol =
                                                            CableGeometryBuilder
                                                                .parseHexColor(
                                                          c.colorHex,
                                                        );
                                                        final isSel =
                                                            _selectedConnectionId ==
                                                                c.id;
                                                        return Padding(
                                                          padding:
                                                              const EdgeInsets
                                                                  .only(
                                                            right: 6,
                                                          ),
                                                          child: InkWell(
                                                            onTap: () {
                                                              setState(() {
                                                                _selectedConnectionId =
                                                                    c.id;
                                                                _selectedDeviceId =
                                                                    null;
                                                              });
                                                            },
                                                            onDoubleTap: () {
                                                              if (widget
                                                                      .onJumpToRackAndDevice !=
                                                                  null) {
                                                                widget
                                                                    .onJumpToRackAndDevice!(
                                                                  remoteEnd
                                                                      .rackId,
                                                                  remoteEnd
                                                                      .deviceId,
                                                                );
                                                              } else {
                                                                widget
                                                                    .onSwitchRack(
                                                                  remoteEnd
                                                                      .rackId,
                                                                );
                                                              }
                                                            },
                                                            child: Tooltip(
                                                              message:
                                                                  'Clic: Resaltar cable (${localEnd.deviceCode}:${localEnd.portNumber} ➔ ${remoteEnd.rackCode} ${remoteEnd.deviceCode}:${remoteEnd.portNumber})\nDoble Clic o icono ↗: Abrir ${remoteEnd.rackCode} en el Rack Editor',
                                                              child: Container(
                                                                padding:
                                                                    const EdgeInsets
                                                                        .symmetric(
                                                                  horizontal: 8,
                                                                  vertical: 3,
                                                                ),
                                                                decoration:
                                                                    BoxDecoration(
                                                                  color: isSel
                                                                      ? cCol
                                                                      : const Color(
                                                                          0xFF1E293B,
                                                                        ),
                                                                  borderRadius:
                                                                      BorderRadius
                                                                          .circular(
                                                                    14,
                                                                  ),
                                                                  border:
                                                                      Border.all(
                                                                    color: cCol,
                                                                    width: 1.5,
                                                                  ),
                                                                ),
                                                                child: Row(
                                                                  mainAxisSize:
                                                                      MainAxisSize
                                                                          .min,
                                                                  children: [
                                                                    Container(
                                                                      width: 7,
                                                                      height: 7,
                                                                      decoration:
                                                                          BoxDecoration(
                                                                        color: isSel
                                                                            ? Colors.white
                                                                            : cCol,
                                                                        shape: BoxShape
                                                                            .circle,
                                                                      ),
                                                                    ),
                                                                    const SizedBox(
                                                                      width: 5,
                                                                    ),
                                                                    Text(
                                                                      '${localEnd.deviceCode}:${localEnd.portNumber} ⇢ ${remoteEnd.rackCode} (${remoteEnd.deviceCode}:${remoteEnd.portNumber})',
                                                                      style:
                                                                          const TextStyle(
                                                                        color: Colors
                                                                            .white,
                                                                        fontSize:
                                                                            9.8,
                                                                        fontWeight:
                                                                            FontWeight.w700,
                                                                      ),
                                                                    ),
                                                                    const SizedBox(
                                                                      width: 5,
                                                                    ),
                                                                    InkWell(
                                                                      onTap: () {
                                                                        if (widget.onJumpToRackAndDevice !=
                                                                            null) {
                                                                          widget.onJumpToRackAndDevice!(
                                                                            remoteEnd.rackId,
                                                                            remoteEnd.deviceId,
                                                                          );
                                                                        } else {
                                                                          widget.onSwitchRack(
                                                                            remoteEnd.rackId,
                                                                          );
                                                                        }
                                                                      },
                                                                      child:
                                                                          const Icon(
                                                                        Icons
                                                                            .open_in_new,
                                                                        size:
                                                                            11,
                                                                        color: Color(
                                                                          0xFF38BDF8,
                                                                        ),
                                                                      ),
                                                                    ),
                                                                  ],
                                                                ),
                                                              ),
                                                            ),
                                                          ),
                                                        );
                                                      }).toList(),
                                                    ),
                                                  ),
                                          ),
                                          if (_canEdit) ...[
                                            const SizedBox(width: 8),
                                            InkWell(
                                              onTap: () =>
                                                  _showInterRackConnectionDialog(),
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                  horizontal: 9,
                                                  vertical: 4,
                                                ),
                                                decoration: BoxDecoration(
                                                  color:
                                                      const Color(0xFF0284C7),
                                                  borderRadius:
                                                      BorderRadius.circular(6),
                                                ),
                                                child: const Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Icon(
                                                      Icons.add_link,
                                                      size: 13,
                                                      color: Colors.white,
                                                    ),
                                                    SizedBox(width: 4),
                                                    Text(
                                                      '+ Conectar con Otro Rack',
                                                      style: TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 10,
                                                        fontWeight:
                                                            FontWeight.w800,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),

                      // Controles Flotantes Superiores Izquierdos: [♊ Front + Back | Front | Back] + [📷 Foto Equipos ON/OFF] + Filtro de Cables
                      Positioned(
                        top: 14,
                        left: 14,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(8),
                                border:
                                    Border.all(color: const Color(0xFFCBD5E1)),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Color(0x0D000000),
                                    blurRadius: 6,
                                  ),
                                ],
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.zoom_in, size: 18),
                                    tooltip: 'Acercar',
                                    onPressed: () {
                                      final m =
                                          _transformController.value.clone();
                                      m.scaleByDouble(1.2, 1.2, 1.0, 1.0);
                                      _transformController.value = m;
                                    },
                                  ),
                                  const Divider(height: 1),
                                  IconButton(
                                    icon: const Icon(Icons.zoom_out, size: 18),
                                    tooltip: 'Alejar',
                                    onPressed: () {
                                      final m =
                                          _transformController.value.clone();
                                      m.scaleByDouble(
                                        1 / 1.2,
                                        1 / 1.2,
                                        1.0,
                                        1.0,
                                      );
                                      _transformController.value = m;
                                    },
                                  ),
                                  const Divider(height: 1),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.crop_free_rounded,
                                      size: 17,
                                    ),
                                    tooltip: 'Restablecer vista 100%',
                                    onPressed: () {
                                      _transformController.value =
                                          Matrix4.identity();
                                    },
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),

                            // Conmutador [Front | Back | Front & Back]
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(6),
                                border:
                                    Border.all(color: const Color(0xFFCBD5E1)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _FaceToggleButton(
                                    label: 'Front',
                                    active: _activeFace == 'front',
                                    onTap: () => _setFaceMode('front'),
                                  ),
                                  _FaceToggleButton(
                                    label: 'Back',
                                    active: _activeFace == 'back',
                                    onTap: () => _setFaceMode('back'),
                                  ),
                                  _FaceToggleButton(
                                    label: 'Front & Back',
                                    active: _activeFace == 'both',
                                    onTap: () => _setFaceMode('both'),
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(width: 10),

                            // Conmutador de Foto Real / Bisel de Equipos ON / OFF
                            InkWell(
                              onTap: () => setState(
                                () => _showEquipmentPhotos =
                                    !_showEquipmentPhotos,
                              ),
                              borderRadius: BorderRadius.circular(6),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 7,
                                ),
                                decoration: BoxDecoration(
                                  color: _showEquipmentPhotos
                                      ? const Color(0xFF0F172A)
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: _showEquipmentPhotos
                                        ? const Color(0xFF38BDF8)
                                        : const Color(0xFFCBD5E1),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      _showEquipmentPhotos
                                          ? Icons.photo_camera
                                          : Icons.photo_camera_outlined,
                                      size: 14,
                                      color: _showEquipmentPhotos
                                          ? const Color(0xFF38BDF8)
                                          : const Color(0xFF475569),
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      _showEquipmentPhotos
                                          ? 'Foto Equipos: ON'
                                          : 'Foto Equipos: OFF',
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w700,
                                        color: _showEquipmentPhotos
                                            ? Colors.white
                                            : const Color(0xFF475569),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            const SizedBox(width: 10),

                            // Filtro rápido por Tipo de Cable
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(6),
                                border:
                                    Border.all(color: const Color(0xFFCBD5E1)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _FilterChipBtn(
                                    label: 'Todos',
                                    color: const Color(0xFF0F172A),
                                    active: _cableFilter == 'all',
                                    onTap: () =>
                                        setState(() => _cableFilter = 'all'),
                                  ),
                                  _FilterChipBtn(
                                    label: 'Red UTP',
                                    color: const Color(0xFF2563EB),
                                    active: _cableFilter == 'network',
                                    onTap: () => setState(
                                      () => _cableFilter = 'network',
                                    ),
                                  ),
                                  _FilterChipBtn(
                                    label: 'Fibra',
                                    color: const Color(0xFFF59E0B),
                                    active: _cableFilter == 'fiber',
                                    onTap: () =>
                                        setState(() => _cableFilter = 'fiber'),
                                  ),
                                  _FilterChipBtn(
                                    label: 'Electricidad',
                                    color: const Color(0xFFDC2626),
                                    active: _cableFilter == 'power',
                                    onTap: () =>
                                        setState(() => _cableFilter = 'power'),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // COLUMNA DERECHA: Panel de Propiedades
              PropertiesPanel(
                api: widget.api,
                rack: rack,
                selectedDevice: _selectedDevice,
                selectedConnection: _selectedConnection,
                onRefreshRack: _loadRack,
                onClearSelection: () {
                  setState(() {
                    _selectedDeviceId = null;
                    _selectedConnectionId = null;
                  });
                },
                onSwitchFace: (face) {
                  setState(() => _activeFace = face);
                },
                onNavigateToRack: widget.onSwitchRack,
                onDeleteRack: _canEdit ? _confirmDeleteCurrentRack : null,
                onConfigureDevicePhoto: (dev) =>
                    _showHardwarePhotoSearchDialog(device: dev),
                currentUser: widget.currentUser,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Construye un armario Rack completo (estructura metálica, raíles 19", regla U, slots vacíos y equipos de esa cara).
  List<Widget> _buildSingleRackCabinetStack({
    required RackDetailModel rack,
    required String face,
    required String faceBannerLabel,
    required Color faceBannerColor,
    required double outerLeft,
    required double innerLeft,
    required Set<int> occupiedUsOnFace,
    required Map<int, Color> connectedPortColors,
    required bool showDropPreview,
  }) {
    return [
      // A0. Etiqueta de Cara del Bastidor (FRONT / BACK)
      Positioned(
        left: outerLeft,
        top: _rackTopMargin - 66,
        width: _rackOuterWidth,
        height: 22,
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: faceBannerColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
          ),
          child: Text(
            '${rack.code} — $faceBannerLabel',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
            ),
          ),
        ),
      ),

      // A1. Cabezal superior del armario Rack
      Positioned(
        left: outerLeft,
        top: _rackTopMargin - 42,
        width: _rackOuterWidth,
        height: 22,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            border: Border.all(
              color: const Color(0xFF334155),
              width: 1.4,
            ),
          ),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              height: 4,
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: Color(0xFF334155),
                    width: 1.2,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),

      // A2. Marco exterior de doble pared del Armario Rack
      Positioned(
        left: outerLeft,
        top: _rackTopMargin - 20,
        width: _rackOuterWidth,
        height: rack.totalUnits * _uHeightPx + 40,
        child: Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFC),
            border: Border.all(
              color: const Color(0xFF334155),
              width: 1.5,
            ),
          ),
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFFFDFEFE),
              border: Border.all(
                color: const Color(0xFF475569),
                width: 1.2,
              ),
            ),
          ),
        ),
      ),

      // A3. Raíles verticales perforados de 19" con los 3 agujeros cuadrados por cada U
      Positioned(
        left: innerLeft - _railWidth,
        top: _rackTopMargin,
        width: _railWidth,
        height: rack.totalUnits * _uHeightPx,
        child: _buildPerforated19InchRail(rack.totalUnits),
      ),
      Positioned(
        left: innerLeft + _rackInnerWidth,
        top: _rackTopMargin,
        width: _railWidth,
        height: rack.totalUnits * _uHeightPx,
        child: _buildPerforated19InchRail(rack.totalUnits),
      ),

      // A4. Línea vertical continua de la regla U a la izquierda del armario
      Positioned(
        left: outerLeft - 18,
        top: _rackTopMargin,
        width: 1.5,
        height: rack.totalUnits * _uHeightPx,
        child: Container(color: const Color(0xFF475569)),
      ),

      // B. Regla numerada de Unidades U (42 .. 1) y Slots vacíos
      for (int u = rack.totalUnits; u >= 1; u--) ...[
        Positioned(
          left: outerLeft - 56,
          top: _rackTopMargin + (rack.totalUnits - u) * _uHeightPx,
          width: 44,
          height: _uHeightPx,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                right: 2,
                top: 0,
                child: Container(
                  width: 6,
                  height: 1.3,
                  color: const Color(0xFF475569),
                ),
              ),
              if (u == 1)
                Positioned(
                  right: 2,
                  bottom: 0,
                  child: Container(
                    width: 6,
                    height: 1.3,
                    color: const Color(0xFF475569),
                  ),
                ),
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Text(
                    '$u',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF334155),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        if (!occupiedUsOnFace.contains(u))
          Positioned(
            left: innerLeft,
            top: _rackTopMargin + (rack.totalUnits - u) * _uHeightPx,
            width: _rackInnerWidth,
            height: _uHeightPx,
            child: DragTarget<Object>(
              onWillAcceptWithDetails: (details) {
                if (!_canEdit) return false;
                if (details.data is! DeviceTemplateModel &&
                    details.data is! RackDeviceModel) {
                  return false;
                }
                if (_hoveredDropU != u || _draggingData != details.data) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) {
                      setState(() {
                        _draggingData = details.data;
                        _hoveredDropU = u;
                      });
                    }
                  });
                }
                return true;
              },
              onLeave: (_) {
                if (_hoveredDropU == u) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && _hoveredDropU == u) {
                      setState(() => _hoveredDropU = null);
                    }
                  });
                }
              },
              onAcceptWithDetails: (details) {
                _handleDropOnUSlot(details.data, u);
              },
              builder: (ctx, candidate, _) {
                final isHovering = candidate.isNotEmpty;
                return InkWell(
                  onTap: (_canEdit && _selectedTemplateForClick != null)
                      ? () => _handleDropOrMountTemplate(
                            _selectedTemplateForClick!,
                            u,
                          )
                      : null,
                  child: Container(
                    decoration: BoxDecoration(
                      color: isHovering
                          ? const Color(0xFFDBEAFE)
                          : Colors.transparent,
                      border: Border(
                        bottom: BorderSide(
                          color: const Color(0xFFE2E8F0)
                              .withValues(alpha: 0.55),
                          width: 0.7,
                        ),
                      ),
                    ),
                    child: Center(
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isHovering
                                ? const Color(0xFF2563EB)
                                : const Color(0xFF64748B),
                            width: 1.2,
                          ),
                        ),
                        child: Icon(
                          Icons.add,
                          size: 13,
                          color: isHovering
                              ? const Color(0xFF2563EB)
                              : const Color(0xFF64748B),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
      ],

      // C. Dispositivos Montados en esta cara (Front o Back)
      for (final dev in rack.devices)
        if (dev.isVisibleOnFace(face))
          _buildMountedDeviceWidget(
            dev: dev,
            face: face,
            innerLeft: innerLeft,
            totalUnits: rack.totalUnits,
            connectedPortColors: connectedPortColors,
          ),

      // C1. Previsualización Multi-U en tiempo real al arrastrar un equipo
      if (showDropPreview && _hoveredDropU != null && _draggingData != null)
        Builder(
          builder: (_) {
            final int uH = _draggingData is RackDeviceModel
                ? (_draggingData as RackDeviceModel).uHeight
                : (_draggingData as DeviceTemplateModel).uHeight;
            final int? exId = _draggingData is RackDeviceModel
                ? (_draggingData as RackDeviceModel).id
                : null;
            final int startU = _hoveredDropU!;
            final int endU = startU + uH - 1;
            final bool canFit = _canFitAtU(
              rack,
              startU,
              uH,
              excludeDeviceId: exId,
            );
            final int clampedEndU = endU.clamp(1, rack.totalUnits);
            final double topPx = _rackTopMargin +
                (rack.totalUnits - clampedEndU) * _uHeightPx;
            final double boxH = (clampedEndU - startU + 1) * _uHeightPx;
            final String rangeTxt =
                uH > 1 ? 'U$startU - U$endU ($uH U)' : 'U$startU (1U)';
            return Positioned(
              left: innerLeft,
              top: topPx,
              width: _rackInnerWidth,
              height: boxH,
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    color: (canFit
                            ? const Color(0xFF16A34A)
                            : const Color(0xFFDC2626))
                        .withValues(alpha: 0.22),
                    border: Border.all(
                      color: canFit
                          ? const Color(0xFF16A34A)
                          : const Color(0xFFDC2626),
                      width: 2.2,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: canFit
                            ? const Color(0xFF15803D)
                            : const Color(0xFFB91C1C),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        canFit
                            ? '✓ Soltar en $rangeTxt (${uH}U libres)'
                            : '✕ No cabe en $rangeTxt (necesita ${uH}U libres)',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
    ];
  }

  /// Dibuja el raíl vertical de 19 pulgadas con las 3 perforaciones cuadradas por cada U (idéntico a la imagen).
  Widget _buildPerforated19InchRail(int totalUnits) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFE2E8F0),
        border: Border.symmetric(
          vertical: BorderSide(color: Color(0xFFCBD5E1), width: 1.0),
        ),
      ),
      child: Column(
        children: [
          for (int u = 0; u < totalUnits; u++)
            SizedBox(
              height: _uHeightPx,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (int h = 0; h < 3; h++)
                    Container(
                      width: 4.0,
                      height: 4.0,
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        border: Border.all(
                          color: const Color(0xFF94A3B8),
                          width: 0.8,
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // ===========================================================================
  // WIDGET DE ZONA EXTERIOR DE TOMAS ELÉCTRICAS SCHUKO Y FIBRA ÓPTICA
  // ===========================================================================
  Widget _buildExternalPowerOutletsZone({
    required List<RackDeviceModel> extOutlets,
    required Map<int, Color> connectedPortColors,
  }) {
    double runningTopInZone = _extCardTopStart - (_rackTopMargin - 20);
    final cardPositions = <double>[];
    final cardHeights = <double>[];
    for (final ext in extOutlets) {
      cardPositions.add(runningTopInZone);
      final h = _externalCardHeight(ext);
      cardHeights.add(h);
      runningTopInZone += h + _extCardGap;
    }
    final totalHeight = runningTopInZone + 40.0;

    return Positioned(
      left: _effectiveExtZoneLeft,
      top: _rackTopMargin - 20,
      width: _extZoneWidth,
      height: totalHeight + 60,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(8),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x18000000),
                    blurRadius: 8,
                    offset: Offset(0, 3),
                  ),
                ],
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.electrical_services,
                    color: Color(0xFFFACC15),
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'TOMAS EXTERIORES (ELÉCTRICAS & FIBRA)',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 9.8,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.3,
                          ),
                        ),
                        Text(
                          'Schuko 230V y Acometidas de Fibra con nº conectores ajustable',
                          style: TextStyle(
                            color: Color(0xFF94A3B8),
                            fontSize: 8.8,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_canEdit) ...[
                    InkWell(
                      onTap: () => _showAddOrEditExternalOutletDialog(
                        initialFeedType: 'power',
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFFDC2626),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.bolt, size: 11, color: Colors.white),
                            SizedBox(width: 2),
                            Text(
                              '+Schuko',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 9.2,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    InkWell(
                      onTap: () => _showAddOrEditExternalOutletDialog(
                        initialFeedType: 'fiber',
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0284C7),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add, size: 11, color: Colors.white),
                            SizedBox(width: 2),
                            Text(
                              '+Fibra',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 9.2,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          for (int idx = 0; idx < extOutlets.length; idx++)
            _buildSingleExternalOutletCard(
              ext: extOutlets[idx],
              topInZone: cardPositions[idx],
              cardHeight: cardHeights[idx],
              canDelete: _canEdit && extOutlets.length > 1,
              connectedPortColors: connectedPortColors,
            ),
        ],
      ),
    );
  }

  Widget _buildSingleExternalOutletCard({
    required RackDeviceModel ext,
    required double topInZone,
    required double cardHeight,
    required bool canDelete,
    required Map<int, Color> connectedPortColors,
  }) {
    final feedColor = CableGeometryBuilder.parseHexColor(ext.feedColorHex);
    final count = ext.ports.length;
    final isFiber = ext.isFiberFeed;

    return Positioned(
      left: 0,
      top: topInZone,
      width: _extZoneWidth,
      height: cardHeight,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: feedColor, width: 2.2),
          boxShadow: [
            BoxShadow(
              color: feedColor.withValues(alpha: 0.14),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              top: 0,
              right: 0,
              height: 36,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: feedColor,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(7),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      isFiber
                          ? Icons.settings_input_hdmi_outlined
                          : Icons.bolt,
                      size: 15,
                      color: Colors.white,
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: Text(
                        '${ext.code} • ${ext.name}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10.8,
                          fontWeight: FontWeight.w800,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_canEdit)
                      IconButton(
                        onPressed: () =>
                            _showAddOrEditExternalOutletDialog(existing: ext),
                        icon: const Icon(
                          Icons.edit_outlined,
                          size: 14,
                          color: Colors.white,
                        ),
                        tooltip: isFiber
                            ? 'Editar caja exterior de fibra y nº de conectores'
                            : 'Editar nombre, color o número de enchufes',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 24,
                          minHeight: 24,
                        ),
                      ),
                    if (canDelete)
                      IconButton(
                        onPressed: () => _deleteExternalOutlet(ext),
                        icon: const Icon(
                          Icons.delete_outline,
                          size: 14,
                          color: Colors.white,
                        ),
                        tooltip: 'Eliminar esta toma exterior',
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 24,
                          minHeight: 24,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 10,
              top: 40,
              right: 8,
              child: Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: feedColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      isFiber
                          ? 'Fibra Óptica Exterior ($count conectores FO)'
                          : 'Enchufes Schuko 230V ($count tomas)',
                      style: const TextStyle(
                        fontSize: 9.2,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF475569),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_canEdit)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFFCBD5E1)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          InkWell(
                            onTap: count > 1
                                ? () => _quickAdjustExternalOutletCount(
                                      ext,
                                      count - (isFiber && count > 8 ? 2 : 1),
                                    )
                                : null,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 3),
                              child: Icon(
                                Icons.remove,
                                size: 11,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 3),
                            child: Text(
                              '$count',
                              style: const TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                          ),
                          InkWell(
                            onTap: count < (isFiber ? 48 : 16)
                                ? () => _quickAdjustExternalOutletCount(
                                      ext,
                                      count + (isFiber && count >= 8 ? 2 : 1),
                                    )
                                : null,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 3),
                              child: Icon(
                                Icons.add,
                                size: 11,
                                color: Color(0xFF0F172A),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            for (int pIdx = 0; pIdx < count; pIdx++)
              _buildExternalPortWidget(
                ext: ext,
                port: ext.ports[pIdx],
                index: pIdx,
                feedColor: feedColor,
                connectedColor: connectedPortColors[ext.ports[pIdx].id],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildExternalPortWidget({
    required RackDeviceModel ext,
    required PortModel port,
    required int index,
    required Color feedColor,
    required Color? connectedColor,
  }) {
    final isPending = _pendingSourcePort?.id == port.id;
    final isConnected = connectedColor != null;
    final localCenter = _externalPortLocalCenter(ext, index);
    final isFiber = ext.isFiberFeed;
    final socketSize = isFiber ? 28.0 : 34.0;
    final leftPx = localCenter.dx - socketSize / 2.0;
    final topPx = localCenter.dy - socketSize / 2.0;

    if (isFiber) {
      // Conector óptico exterior LC/SC (Duplex Ferrule)
      return Positioned(
        left: leftPx,
        top: topPx,
        width: socketSize,
        height: socketSize + 13,
        child: Tooltip(
          message:
              '${ext.code} (${ext.name}) — Conector Fibra ${port.portNumber} (LC/SC)\n${isConnected ? 'Ocupado (Clic para seleccionar latiguillo)' : 'Libre (Clic para conectar fibra al Rack)'}',
          child: InkWell(
            onTap: () => _handlePortTap(ext, port),
            borderRadius: BorderRadius.circular(6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: socketSize,
                  height: socketSize - 4,
                  decoration: BoxDecoration(
                    color: isPending
                        ? const Color(0xFF10B981)
                        : (isConnected
                            ? feedColor
                            : feedColor.withValues(alpha: 0.12)),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: isPending ? Colors.amber : feedColor,
                      width: isPending ? 2.4 : 1.8,
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: isConnected
                              ? Colors.white
                              : const Color(0xFF0F172A),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isConnected ? feedColor : Colors.white,
                            width: 1.0,
                          ),
                        ),
                      ),
                      const SizedBox(width: 3),
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: isConnected
                              ? Colors.white
                              : const Color(0xFF0F172A),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isConnected ? feedColor : Colors.white,
                            width: 1.0,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  port.portNumber,
                  style: TextStyle(
                    fontSize: 7.8,
                    fontWeight: FontWeight.w800,
                    color: isConnected ? feedColor : const Color(0xFF334155),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Positioned(
      left: leftPx,
      top: topPx,
      width: socketSize,
      height: socketSize + 14,
      child: Tooltip(
        message:
            '${ext.code} (${ext.name}) — Enchufe ${port.portNumber} (SCHUKO 230V)\n${isConnected ? 'Ocupado (Clic para seleccionar cable)' : 'Libre (Clic para enchufar a Front o Back)'}',
        child: InkWell(
          onTap: () => _handlePortTap(ext, port),
          borderRadius: BorderRadius.circular(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: socketSize,
                height: socketSize,
                decoration: BoxDecoration(
                  color: isPending
                      ? const Color(0xFF10B981)
                      : (isConnected
                          ? feedColor
                          : feedColor.withValues(alpha: 0.10)),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: isPending ? Colors.amber : feedColor,
                    width: isPending ? 2.5 : 2.0,
                  ),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned(
                      top: 3,
                      child: Container(
                        width: 4,
                        height: 3,
                        color: isConnected ? Colors.white70 : feedColor,
                      ),
                    ),
                    Positioned(
                      bottom: 3,
                      child: Container(
                        width: 4,
                        height: 3,
                        color: isConnected ? Colors.white70 : feedColor,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 5.5,
                          height: 5.5,
                          decoration: BoxDecoration(
                            color: isConnected
                                ? Colors.white
                                : const Color(0xFF0F172A),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          width: 5.5,
                          height: 5.5,
                          decoration: BoxDecoration(
                            color: isConnected
                                ? Colors.white
                                : const Color(0xFF0F172A),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 2),
              Text(
                port.portNumber,
                style: TextStyle(
                  fontSize: 8.5,
                  fontWeight: FontWeight.w800,
                  color: isConnected ? feedColor : const Color(0xFF334155),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // CHASIS DE EQUIPO MONTADO EN RACK (ESTILO TÉCNICO PATCHBOX + FOTO REAL/BISEL + ARRASTRAR A U LIBRE)
  // ===========================================================================
  Widget _buildMountedDeviceWidget({
    required RackDeviceModel dev,
    required String face,
    required double innerLeft,
    required int totalUnits,
    required Map<int, Color> connectedPortColors,
  }) {
    final topU = dev.endU;
    final topY = _rackTopMargin + (totalUnits - topU) * _uHeightPx;
    final heightPx = dev.uHeight * _uHeightPx;
    final isSelected = dev.id == _selectedDeviceId;
    final isHighlighted = dev.id == _highlightedDeviceId;
    final isHovered = dev.id == _hoveredDeviceId;
    final facePorts = dev.portsForFace(face);
    final isRearAutoView = dev.mountedFace != face;
    final rack = _rack;
    final nextUpU = rack != null ? _findNearestFreeU(rack, dev, 1) : null;
    final nextDownU = rack != null ? _findNearestFreeU(rack, dev, -1) : null;
    final isTray = dev.template.category == 'rack_tray' ||
        dev.template.modelName.toLowerCase().contains('bandeja');
    final isRoofFan = dev.template.isRoofFan;

    final isOnline = dev.status == 'online';
    final isOffline = dev.status == 'offline';
    final statusColor = !dev.monitoringEnabled
        ? const Color(0xFF94A3B8)
        : (isOnline
            ? const Color(0xFF16A34A)
            : (isOffline
                ? const Color(0xFFDC2626)
                : const Color(0xFFD97706)));

    Widget buildChassisContent({required bool isDropTarget}) {
      return Container(
        decoration: BoxDecoration(
          // Cuando el equipo es seleccionado o localizado desde búsqueda/alarma, aplicamos un fondo grisáceo destacado
          color: isDropTarget
              ? const Color(0xFFFEE2E2)
              : ((isHighlighted || isSelected)
                  ? const Color(0xFFD1D5DB)
                  : (isTray
                      ? const Color(0xFFF1F5F9)
                      : (isRearAutoView
                          ? const Color(0xFFF8FAFC)
                          : Colors.white))),
          border: Border.symmetric(
            horizontal: BorderSide(
              color: (isHighlighted || isSelected)
                  ? const Color(0xFF1E293B)
                  : const Color(0xFFCBD5E1),
              width: (isHighlighted || isSelected) ? 2.0 : 0.9,
            ),
          ),
          boxShadow: (isHighlighted || isSelected)
              ? [
                  BoxShadow(
                    color: const Color(0xFF475569).withValues(alpha: 0.28),
                    blurRadius: 8,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Etiqueta de equipo localizado a la izquierda de la regla U cuando viene de búsqueda/alarma
            if (isHighlighted || isSelected)
              Positioned(
                left: -68,
                top: (heightPx / 2) - 10,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF334155),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '▶ U${dev.startU}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
              ),

            // Fondo de Foto de Referencia o Bisel Gráfico Industrial (cuando "Foto Equipos: ON" está activo, o siempre para Ventiladores/Bandejas)
            if (_showEquipmentPhotos || isTray || isRoofFan)
              Positioned(
                left: _railWidth + 24,
                right: _railWidth + 4,
                top: 1,
                bottom: 1,
                child: _buildRealisticPhotoBezelOverlay(dev, face),
              ),

            // Orejetas laterales de anclaje sobre el raíl de 19" izquierdo y derecho
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: _railWidth,
              child: _buildDeviceMountingEar(dev.uHeight),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: _railWidth,
              child: _buildDeviceMountingEar(dev.uHeight),
            ),

            // Código del equipo rotado 90° en vertical a la izquierda (con punto de estado Heartbeat Verde/Rojo/Ámbar)
            Positioned(
              left: _railWidth + 2,
              top: 2,
              bottom: 2,
              width: 22,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  RotatedBox(
                    quarterTurns: 3,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (dev.monitoringEnabled) ...[
                          Container(
                            width: 5.5,
                            height: 5.5,
                            decoration: BoxDecoration(
                              color: statusColor,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 3),
                        ],
                        Text(
                          dev.code,
                          style: const TextStyle(
                            fontSize: 8.5,
                            fontWeight: FontWeight.w800,
                            color: Color(0xFF0F172A),
                            letterSpacing: 0.3,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Información sutil cuando tiene pocas bocas en esta cara (ej. parte trasera con PSU o servidor o cabina SAN/NAS)
            if (facePorts.length <= 12 && !(isTray && dev.trayItems.isNotEmpty))
              Positioned(
                left: _railWidth + 28,
                top: 3,
                child: Container(
                  padding: _showEquipmentPhotos && dev.photoUrl.isNotEmpty
                      ? const EdgeInsets.symmetric(horizontal: 5, vertical: 1)
                      : EdgeInsets.zero,
                  decoration: _showEquipmentPhotos && dev.photoUrl.isNotEmpty
                      ? BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.86),
                          borderRadius: BorderRadius.circular(3),
                        )
                      : null,
                  child: Text(
                    '${dev.name}${dev.uHeight > 1 ? ' (${dev.uHeight}U)' : ''}${isRearAutoView ? ' • [${face.toUpperCase()} U${dev.startU}]' : ''}${dev.ipAddress.isNotEmpty ? ' • ${dev.ipAddress}' : ''}${dev.monitoringEnabled ? ' • HB:${dev.monitorMethod.toUpperCase()}' : ''}',
                    style: const TextStyle(
                      fontSize: 8.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF334155),
                    ),
                  ),
                ),
              ),

            // Bocas / Puertos individuales (desplazados por _railWidth porque el chasis incluye las orejetas)
            for (final port in facePorts)
              _buildPortWidget(
                dev: dev,
                port: port,
                face: face,
                devHeight: heightPx,
                connectedColor: connectedPortColors[port.id],
              ),

            // Controles rápidos flotantes en el propio equipo (Arrastrar, Subir, Bajar, U Ocupadas -/+, Equipos en Bandeja, Foto, Cable a Otro Rack, Borrar)
            if (_canEdit && (isHovered || isSelected))
              Positioned(
                left: _railWidth + 24,
                top: 2,
                child: Material(
                  elevation: 3,
                  borderRadius: BorderRadius.circular(5),
                  color: const Color(0xFF0F172A).withValues(alpha: 0.92),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 1.5,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Tooltip(
                          message:
                              'Arrastra el equipo directamente a cualquier posición con U libres',
                          child: Padding(
                            padding: EdgeInsets.symmetric(horizontal: 3),
                            child: Icon(
                              Icons.open_with_rounded,
                              size: 13,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        InkWell(
                          onTap: nextUpU != null
                              ? () => _moveDeviceToU(dev, nextUpU)
                              : null,
                          child: Tooltip(
                            message: nextUpU != null
                                ? 'Subir a U$nextUpU (${dev.uHeight}U libres)'
                                : 'No hay ${dev.uHeight}U libres más arriba',
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 3,
                              ),
                              child: Icon(
                                Icons.keyboard_arrow_up,
                                size: 14,
                                color: nextUpU != null
                                    ? Colors.white
                                    : Colors.white38,
                              ),
                            ),
                          ),
                        ),
                        InkWell(
                          onTap: nextDownU != null
                              ? () => _moveDeviceToU(dev, nextDownU)
                              : null,
                          child: Tooltip(
                            message: nextDownU != null
                                ? 'Bajar a U$nextDownU (${dev.uHeight}U libres)'
                                : 'No hay ${dev.uHeight}U libres más abajo',
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 3,
                              ),
                              child: Icon(
                                Icons.keyboard_arrow_down,
                                size: 14,
                                color: nextDownU != null
                                    ? Colors.white
                                    : Colors.white38,
                              ),
                            ),
                          ),
                        ),
                        InkWell(
                          onTap: () => _showMoveDeviceToUDialog(dev),
                          child: Tooltip(
                            message:
                                'Elegir U libre destino (Actual: U${dev.startU})',
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 3,
                              ),
                              child: Text(
                                'U${dev.startU}',
                                style: const TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF93C5FD),
                                ),
                              ),
                            ),
                          ),
                        ),
                        // Selector rápido -/+ de cuántas U ocupa en el propio chasis
                        Container(
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 3,
                            vertical: 0.5,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E293B),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: const Color(0xFF475569)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              InkWell(
                                onTap: dev.uHeight > 1
                                    ? () => _quickAdjustDeviceUHeight(
                                          dev,
                                          dev.uHeight - 1,
                                        )
                                    : null,
                                child: const Tooltip(
                                  message: 'Reducir 1U de altura',
                                  child: Icon(
                                    Icons.remove,
                                    size: 11,
                                    color: Color(0xFF38BDF8),
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 3,
                                ),
                                child: Text(
                                  '${dev.uHeight}U',
                                  style: const TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                              InkWell(
                                onTap: dev.uHeight < 16
                                    ? () => _quickAdjustDeviceUHeight(
                                          dev,
                                          dev.uHeight + 1,
                                        )
                                    : null,
                                child: const Tooltip(
                                  message: 'Ampliar +1U de altura',
                                  child: Icon(
                                    Icons.add,
                                    size: 11,
                                    color: Color(0xFF38BDF8),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (isTray)
                          InkWell(
                            onTap: () => _showManageTrayItemsDialog(dev),
                            child: Tooltip(
                              message:
                                  'Colocar o gestionar Mini-Equipos dentro de esta Bandeja (Routers, Switches, Mini-PCs)',
                              child: Container(
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 3,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF7C3AED),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.inbox_outlined,
                                      size: 11,
                                      color: Colors.white,
                                    ),
                                    const SizedBox(width: 3),
                                    Text(
                                      '+ Equipos (${dev.trayItems.length})',
                                      style: const TextStyle(
                                        fontSize: 8.5,
                                        fontWeight: FontWeight.w800,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        InkWell(
                          onTap: () =>
                              _showHardwarePhotoSearchDialog(device: dev),
                          child: const Tooltip(
                            message:
                                'Buscar o cambiar Foto de Referencia del equipo',
                            child: Padding(
                              padding: EdgeInsets.symmetric(horizontal: 3),
                              child: Icon(
                                Icons.photo_camera_outlined,
                                size: 12.5,
                                color: Color(0xFF38BDF8),
                              ),
                            ),
                          ),
                        ),
                        InkWell(
                          onTap: () => _showInterRackConnectionDialog(
                            initialSourceDev: dev,
                          ),
                          child: const Tooltip(
                            message:
                                'Conectar fibra/cable desde este equipo hacia otro Rack',
                            child: Padding(
                              padding: EdgeInsets.symmetric(horizontal: 3),
                              child: Icon(
                                Icons.compare_arrows,
                                size: 13,
                                color: Color(0xFF34D399),
                              ),
                            ),
                          ),
                        ),
                        InkWell(
                          onTap: () => _quickDeleteDevice(dev),
                          child: const Tooltip(
                            message: 'Borrar / Desmontar este equipo',
                            child: Padding(
                              padding: EdgeInsets.symmetric(horizontal: 3),
                              child: Icon(
                                Icons.delete_outline,
                                size: 13,
                                color: Color(0xFFF87171),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    }

    return Positioned(
      left: innerLeft - _railWidth,
      top: topY,
      width: _rackInnerWidth + _railWidth * 2,
      height: heightPx,
      child: DragTarget<Object>(
        onWillAcceptWithDetails: (details) {
          if (!_canEdit) return false;
          if (details.data is RackDeviceModel &&
              (details.data as RackDeviceModel).id == dev.id) {
            return false;
          }
          if (_hoveredDropU != dev.startU || _draggingData != details.data) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                setState(() {
                  _draggingData = details.data;
                  _hoveredDropU = dev.startU;
                });
              }
            });
          }
          return true;
        },
        onLeave: (_) {
          if (_hoveredDropU == dev.startU) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _hoveredDropU == dev.startU) {
                setState(() => _hoveredDropU = null);
              }
            });
          }
        },
        onAcceptWithDetails: (details) {
          _handleDropOnUSlot(
            details.data,
            dev.startU,
            targetMountedDevice: dev,
          );
        },
        builder: (ctx, candidate, _) {
          final isDropTarget = candidate.isNotEmpty;
          final interactiveChassis = MouseRegion(
            cursor: _canEdit ? SystemMouseCursors.grab : SystemMouseCursors.basic,
            onEnter: (_) => setState(() => _hoveredDeviceId = dev.id),
            onExit: (_) {
              if (_hoveredDeviceId == dev.id) {
                setState(() => _hoveredDeviceId = null);
              }
            },
            child: GestureDetector(
              onTap: () {
                if (_canEdit &&
                    isTray &&
                    _selectedTemplateForClick != null &&
                    _selectedTemplateForClick!.isTrayMiniDevice) {
                  _showManageTrayItemsDialog(
                    dev,
                    initialAddTemplate: _selectedTemplateForClick,
                  );
                  return;
                }
                setState(() {
                  _selectedDeviceId = dev.id;
                  _highlightedDeviceId = dev.id;
                  _selectedConnectionId = null;
                });
              },
              child: buildChassisContent(isDropTarget: isDropTarget),
            ),
          );

          if (!_canEdit) {
            return interactiveChassis;
          }

          return Draggable<Object>(
            data: dev,
            onDragStarted: () {
              setState(() {
                _draggingData = dev;
                _selectedDeviceId = dev.id;
              });
            },
            onDragEnd: (_) {
              if (mounted) {
                setState(() {
                  _draggingData = null;
                  _hoveredDropU = null;
                });
              }
            },
            onDraggableCanceled: (_, _) {
              if (mounted) {
                setState(() {
                  _draggingData = null;
                  _hoveredDropU = null;
                });
              }
            },
            feedback: Material(
              elevation: 10,
              borderRadius: BorderRadius.circular(6),
              color: Colors.transparent,
              child: Container(
                width: _rackInnerWidth * 0.85,
                height: heightPx.clamp(38.0, 120.0),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A).withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: const Color(0xFF38BDF8),
                    width: 2.0,
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.open_with_rounded,
                      color: Color(0xFF38BDF8),
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Moviendo ${dev.code} (${dev.name}) • Requiere ${dev.uHeight}U libres',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            childWhenDragging: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF).withValues(alpha: 0.60),
                  border: Border.all(
                    color: const Color(0xFF3B82F6),
                    width: 1.5,
                  ),
                ),
                child: Center(
                  child: Text(
                    'Moviendo ${dev.code} (${dev.uHeight}U) — Suelta en una posición con ${dev.uHeight}U libres',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF1D4ED8),
                    ),
                  ),
                ),
              ),
            ),
            child: interactiveChassis,
          );
        },
      ),
    );
  }

  /// Dibuja la Foto de Referencia de Internet (si existe y Foto Equipos está ON) o un bisel realista industrial.
  Widget _buildRealisticPhotoBezelOverlay(RackDeviceModel dev, String face) {
    final hasPhoto = _showEquipmentPhotos && dev.photoUrl.isNotEmpty;
    final cat = dev.template.category;
    final isRoofFan = dev.template.isRoofFan;
    final isTray = cat == 'rack_tray' ||
        dev.template.modelName.toLowerCase().contains('bandeja');
    final isStorageOrServer =
        cat == 'storage_san' || cat == 'storage_nas' || cat == 'server';

    if (hasPhoto && !(isTray && dev.trayItems.isNotEmpty)) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: Opacity(
          opacity: 0.34,
          child: Image.network(
            dev.photoUrl,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
      );
    }

    if (isRoofFan) {
      // Módulo de Ventiladores de Techo 1U con 4 turbinas y pantalla digital de temperatura
      return IgnorePointer(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(width: 90),
            for (int f = 0; f < 4; f++)
              Container(
                width: 28,
                height: 28,
                margin: const EdgeInsets.symmetric(horizontal: 5),
                decoration: BoxDecoration(
                  color: const Color(0xFFF1F5F9),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFF475569),
                    width: 1.4,
                  ),
                ),
                child: const Icon(
                  Icons.cyclone,
                  size: 17,
                  color: Color(0xFF0284C7),
                ),
              ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: const Color(0xFF10B981)),
              ),
              child: const Text(
                '21.4°C • FAN OK',
                style: TextStyle(
                  color: Color(0xFF4ADE80),
                  fontSize: 7.5,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
      );
    }

    if (isTray) {
      final trayItems = dev.trayItems;
      // Bandeja de Rack perforada con soporte visual para Mini-Equipos apoyados encima (Routers, Switches, Mini-PCs)
      return IgnorePointer(
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          decoration: BoxDecoration(
            color: const Color(0xFFE2E8F0).withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(3),
            border: Border(
              bottom: const BorderSide(color: Color(0xFF334155), width: 3.5),
              left: const BorderSide(color: Color(0xFF64748B), width: 1.5),
              right: const BorderSide(color: Color(0xFF64748B), width: 1.5),
              top: BorderSide(
                color: const Color(0xFF94A3B8).withValues(alpha: 0.45),
                width: 0.8,
              ),
            ),
          ),
          child: trayItems.isEmpty
              ? Center(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.inbox_outlined,
                        size: 13,
                        color: Color(0xFF475569),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'BANDEJA RACK 19" (${dev.uHeight}U) • Arrastra aquí equipos de "Bandeja - Equipos Mini" o pulsa "+ Equipos"',
                        style: const TextStyle(
                          fontSize: 8.5,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF334155),
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.only(
                    left: 4,
                    right: 4,
                    top: 2,
                    bottom: 3,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (int idx = 0; idx < trayItems.length; idx++)
                        Expanded(
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1E293B)
                                  .withValues(alpha: 0.88),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(
                                color: const Color(0xFF64748B),
                                width: 1.1,
                              ),
                            ),
                            child: Align(
                              alignment: Alignment.topLeft,
                              child: Row(
                                children: [
                                  Icon(
                                    (trayItems[idx]['model_name'] ?? '')
                                                .toString()
                                                .toLowerCase()
                                                .contains('switch')
                                        ? Icons.commit
                                        : ((trayItems[idx]['model_name'] ?? '')
                                                    .toString()
                                                    .toLowerCase()
                                                    .contains('pc') ||
                                                (trayItems[idx]['model_name'] ??
                                                        '')
                                                    .toString()
                                                    .toLowerCase()
                                                    .contains('nuc') ||
                                                (trayItems[idx]['model_name'] ??
                                                        '')
                                                    .toString()
                                                    .toLowerCase()
                                                    .contains('raspberry')
                                            ? Icons.computer
                                            : Icons.router_outlined),
                                    size: 11,
                                    color: const Color(0xFF38BDF8),
                                  ),
                                  const SizedBox(width: 4),
                                  Expanded(
                                    child: Text(
                                      '${trayItems[idx]['code'] ?? 'MINI-${idx + 1}'}: ${trayItems[idx]['name'] ?? trayItems[idx]['model_name'] ?? ''}'
                                      '${(trayItems[idx]['ip_address'] ?? '').toString().isNotEmpty ? ' (${trayItems[idx]['ip_address']})' : ''}',
                                      style: const TextStyle(
                                        fontSize: 8.0,
                                        fontWeight: FontWeight.w800,
                                        color: Colors.white,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
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

    if (_showEquipmentPhotos && isStorageOrServer && face == 'front') {
      // Bisel frontal de bahías NVMe/SAS para cabinas SAN/NAS (Dell, NetApp, IBM, Pure) y Servidores
      final bayCols = dev.uHeight >= 2 ? 12 : 8;
      return IgnorePointer(
        child: Padding(
          padding: const EdgeInsets.only(
            left: 140,
            right: 70,
            top: 16,
            bottom: 4,
          ),
          child: Row(
            children: [
              for (int b = 0; b < bayCols; b++)
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 1.5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(2),
                      border: Border.all(
                        color: const Color(0xFF64748B).withValues(alpha: 0.35),
                        width: 0.8,
                      ),
                    ),
                    child: Align(
                      alignment: Alignment.topRight,
                      child: Container(
                        width: 3.5,
                        height: 3.5,
                        margin: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(
                          color: Color(0xFF10B981),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildDeviceMountingEar(int uHeight) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFE2E8F0),
        border: Border.symmetric(
          vertical: BorderSide(color: Color(0xFFCBD5E1), width: 0.8),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (int i = 0; i < uHeight * 3; i++)
            Container(
              width: 4.0,
              height: 4.0,
              decoration: BoxDecoration(
                color: const Color(0xFF94A3B8),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
        ],
      ),
    );
  }

  /// Dibuja cada puerto con su conector RJ45 / Fibra / PSU / Enchufe Schuko Hembra / Conector Macho IN.
  Widget _buildPortWidget({
    required RackDeviceModel dev,
    required PortModel port,
    required String face,
    required double devHeight,
    required Color? connectedColor,
  }) {
    final isPendingSource = _pendingSourcePort?.id == port.id;
    final isConnected = connectedColor != null;
    final isMalePlug = port.portType == 'power_plug_male' ||
        (dev.template.category == 'pdu' &&
            (port.portNumber.startsWith('IN') ||
                port.portNumber.startsWith('MACHO')));
    final isSchuko = port.portType == 'power_schuko' && !isMalePlug;
    final isPower = port.portType.contains('power') || isMalePlug;
    final isFiberHollow =
        port.portType == 'fiber_lc' && dev.template.category == 'gateway';

    final rx = _computeVisualRelX(dev, port);
    final ry = _computeVisualRelY(dev, port, face);

    final jackW = isMalePlug
        ? 22.0
        : (isSchuko ? 16.0 : (isPower ? 15.0 : 10.5));
    final jackH = isMalePlug
        ? 15.0
        : (isSchuko ? 14.0 : (isPower ? 11.0 : 8.5));

    final centerX = _railWidth + rx * _rackInnerWidth;
    final centerY = ry * devHeight;

    final facePorts = dev.portsForFace(face);
    final hasTwoRows = facePorts.any((p) => p.rowIndex > 0);
    final labelBelow = hasTwoRows && port.rowIndex > 0;

    Color jackFill;
    Color jackBorder;
    if (isPendingSource) {
      jackFill = const Color(0xFF10B981);
      jackBorder = Colors.amber;
    } else if (isConnected) {
      jackFill = isFiberHollow ? Colors.white : connectedColor;
      jackBorder = connectedColor;
    } else if (isFiberHollow) {
      jackFill = Colors.white;
      jackBorder = const Color(0xFF475569);
    } else if (isMalePlug) {
      jackFill = const Color(0xFFEA580C);
      jackBorder = const Color(0xFFFACC15);
    } else if (isPower) {
      jackFill = const Color(0xFF450A0A);
      jackBorder = const Color(0xFF991B1B);
    } else {
      jackFill = const Color(0xFF0F172A);
      jackBorder = const Color(0xFF0F172A);
    }

    // Etiqueta corta para mostrar encima/debajo del puerto (1..24, PSU1, MACHO, etc.)
    final shortLabel = isMalePlug
        ? 'MACHO'
        : port.portNumber.replaceFirst(RegExp(r'^(KR-|R-|F)'), '');

    final halfWidth = isMalePlug ? 16.0 : 10.0;

    return Positioned(
      left: centerX - halfWidth,
      top: labelBelow ? (centerY - jackH / 2) : (centerY - jackH / 2 - 9),
      width: halfWidth * 2,
      height: jackH + 10,
      child: Tooltip(
        message: isMalePlug
            ? '${dev.code} • Conector MACHO de Entrada (${port.portNumber})\nConéctalo a las Tomas Eléctricas Exteriores (TOMA-A / TOMA-B)'
            : '${dev.code} • Boca ${port.portNumber} (${port.portType.toUpperCase()} • ${port.face.toUpperCase()})\n${isConnected ? 'Conectado (Clic para ver cable)' : 'Libre (Clic para tirar cable)'}',
        child: InkWell(
          onTap: () => _handlePortTap(dev, port),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!labelBelow)
                Text(
                  shortLabel,
                  style: TextStyle(
                    fontSize: isMalePlug ? 5.8 : 6.2,
                    height: 1.0,
                    fontWeight: FontWeight.w800,
                    color: isConnected
                        ? connectedColor
                        : (isMalePlug
                            ? const Color(0xFFC2410C)
                            : const Color(0xFF475569)),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.visible,
                ),
              if (!labelBelow) const SizedBox(height: 1),
              Container(
                width: jackW,
                height: jackH,
                decoration: BoxDecoration(
                  color: jackFill,
                  borderRadius: BorderRadius.circular(
                    isMalePlug ? 4 : (isSchuko ? 7 : 1.5),
                  ),
                  border: Border.all(
                    color: jackBorder,
                    width:
                        (isFiberHollow || isPendingSource || isMalePlug)
                            ? 1.5
                            : 0.8,
                  ),
                ),
                child: isMalePlug
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.power,
                            size: 10,
                            color: Colors.white,
                          ),
                          const Text(
                            'IN',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 5.5,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      )
                    : (isPower && !isFiberHollow
                        ? Center(
                            child: Text(
                              shortLabel,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 5.5,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          )
                        : null),
              ),
              if (labelBelow) const SizedBox(height: 1),
              if (labelBelow)
                Text(
                  shortLabel,
                  style: TextStyle(
                    fontSize: 6.2,
                    height: 1.0,
                    fontWeight: FontWeight.w700,
                    color: isConnected
                        ? connectedColor
                        : const Color(0xFF475569),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.visible,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FaceToggleButton extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _FaceToggleButton({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: active ? const Color(0xFF0F172A) : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: active ? Colors.white : const Color(0xFF475569),
          ),
        ),
      ),
    );
  }
}

class _FilterChipBtn extends StatelessWidget {
  final String label;
  final Color color;
  final bool active;
  final VoidCallback onTap;

  const _FilterChipBtn({
    required this.label,
    required this.color,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: active ? color : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: active ? Colors.white : const Color(0xFF475569),
          ),
        ),
      ),
    );
  }
}
