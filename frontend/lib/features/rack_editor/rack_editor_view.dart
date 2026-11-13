import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../../core/widgets/avisos.dart';
import '../../core/theme.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/api_client.dart';
import '../../models/datacenter_models.dart';
import '../../shared/widgets/cmdb_asset_explorer_dialog.dart';
import '../../shared/widgets/diagram_exporter.dart';
import 'widgets/cable_painter.dart';
import 'widgets/device_catalog_panel.dart';
import 'widgets/properties_panel.dart';

part 'sections/rack_editor_actions_and_dialogs.dart';
part 'sections/rack_editor_canvas_section.dart';
part 'sections/rack_editor_devices_and_outlets.dart';
part 'widgets/rack_technical_port_painter.dart';

/// Editor visual CAD interactivo de armarios Rack (`42U–48U`) en vista simple o dual (`Front + Back`).
///
/// Submódulos (`part`):
/// - `sections/rack_editor_actions_and_dialogs.dart`: altas alineadas con CMDB, colisiones IP y cableado.
/// - `sections/rack_editor_canvas_section.dart`: lienzo interactivo, barra superior y raíles 19".
/// - `sections/rack_editor_devices_and_outlets.dart`: chasis montados, puertos y tomas exteriores.
/// - `widgets/rack_technical_port_painter.dart`: `CustomPainter` de conectores físicos.
class RackEditorView extends StatefulWidget {
  final RackDocApiClient api;
  final int rackId;
  final int? initialHighlightDeviceId;
  final List<DeviceTemplateModel> templates;
  final VoidCallback onBackToLocations;
  final VoidCallback? onOpenElevationOverview;
  final ValueChanged<int> onSwitchRack;
  final void Function(int rackId, int? deviceId)? onJumpToRackAndDevice;
  final VoidCallback onTemplatesChanged;
  final UserModel? currentUser;
  final bool isKioskMode;
  final VoidCallback? onToggleKioskMode;

  const RackEditorView({
    super.key,
    required this.api,
    required this.rackId,
    this.initialHighlightDeviceId,
    required this.templates,
    required this.onBackToLocations,
    this.onOpenElevationOverview,
    required this.onSwitchRack,
    this.onJumpToRackAndDevice,
    required this.onTemplatesChanged,
    this.currentUser,
    this.isKioskMode = false,
    this.onToggleKioskMode,
  });

  @override
  State<RackEditorView> createState() => _RackEditorViewState();
}

class _RackEditorViewState extends State<RackEditorView> {
  /// Puente interno para reconstruir el estado desde extensiones `part`.
  void _rebuildState(VoidCallback fn) => setState(fn);

  RackDetailModel? _rack;
  bool _loading = true;
  String? _error;

  // Cara activa del rack ('front', 'back' o 'both' para ver Front & Back a la vez)
  String _activeFace = 'front';

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

  // Pila de Deshacer (Undo: Ctrl+Z en Windows/Linux o Cmd+Z en Mac) y Modo Mano (Barra Espaciadora)
  final List<_RackUndoAction> _undoStack = [];
  bool _isSpacePressed = false;
  bool _isHandToolPinned = false;
  bool _isSpaceDragging = false;

  bool get _isPanHandMode => _isSpacePressed || _isHandToolPinned;

  // Dimensiones constantes del dibujo técnico del Rack (estilo Patchbox CAD) + Vista Dual (Front + Back) + Zona Exterior
  static const double _canvasWidth = 1165.0;
  static const double _dualCanvasWidth = 1915.0;
  static const double _rackOuterLeft = 104.0;
  static const double _rackOuterWidth = 628.0;
  static const double _rackInnerLeft = 152.0;
  static const double _rackInnerWidth = 532.0;
  static const double _backRackOuterLeft = 836.0;
  static const double _backRackInnerLeft = 884.0;
  static const double _dualFaceGap = 104.0;
  static const double _railWidth = 21.0;
  static const double _rackTopMargin = 76.0;
  static const double _uHeightPx = 42.0;

  // Coordenadas del cuadro de Equipos de Planta, Tomas Eléctricas y de Fibra Exteriores (fuera del rack a la derecha)
  static const double _extZoneLeft = 785.0;
  static const double _dualExtZoneLeft = 1530.0;
  static const double _extZoneWidth = 340.0;
  static const double _extCardTopStart = 114.0;
  static const double _extCardHeight = 128.0;
  static const double _extCardGap = 18.0;

  bool get _isDualFace => _activeFace == 'both';
  double get _effectiveExtZoneLeft =>
      _isDualFace ? _dualExtZoneLeft : _extZoneLeft;
  double get _effectiveCanvasWidth =>
      _isDualFace ? _dualCanvasWidth : _canvasWidth;

  bool get _canEdit =>
      !widget.isKioskMode && (widget.currentUser?.canEdit ?? true);
  bool get _canConnectRemote => widget.currentUser?.canConnectRemote ?? true;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
    _highlightedDeviceId = widget.initialHighlightDeviceId;
    _selectedDeviceId = widget.initialHighlightDeviceId;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyFaceCameraZoom(_activeFace);
    });
    _loadRack();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    _rackQuickSearchCtrl.dispose();
    _transformController.dispose();
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
    if (_isTextInputFocused()) {
      if (_isSpacePressed) {
        setState(() {
          _isSpacePressed = false;
          _isSpaceDragging = false;
        });
      }
      return false;
    }

    // 1. Barra Espaciadora -> Modo Mano (Pan del Dashboard del Rack)
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

    // 2. Tecla ESC -> Cancelar tirada de cable en curso, plantilla activa o selección
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      if (_pendingSourcePort != null) {
        setState(() {
          _pendingSourcePort = null;
          _pendingSourceDevice = null;
          _cursorCanvasPos = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Tirada de conexión cancelada (Esc).'),
            duration: Duration(seconds: 1),
          ),
        );
        return true;
      }
      if (_selectedTemplateForClick != null ||
          _isHandToolPinned ||
          _selectedConnectionId != null ||
          _selectedDeviceId != null) {
        setState(() {
          _selectedTemplateForClick = null;
          _isHandToolPinned = false;
          _selectedConnectionId = null;
          _selectedDeviceId = null;
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

  Future<void> _performUndo() async {
    if (!_canEdit) return;
    final messenger = ScaffoldMessenger.of(context);
    if (_undoStack.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('No hay movimientos recientes en el Rack para deshacer.'),
          duration: Duration(seconds: 1),
        ),
      );
      return;
    }
    final action = _undoStack.removeLast();
    try {
      await widget.api.updateDevice(action.deviceId, {
        'start_u': action.previousStartU,
      });
      await _loadRack();
      setState(() => _selectedDeviceId = action.deviceId);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '↩ Deshecho: "${action.deviceCode}" devuelto a U${action.previousStartU}',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      messenger.avisoError('No se pudo deshacer el movimiento: $e');
    }
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
        await widget.api.deleteRack(rack.id);
        widget.onBackToLocations();
        messenger.aviso('Rack "${rack.code}" eliminado.');
      } catch (e) {
        messenger.avisoError('Error eliminando rack: $e');
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
    list.sort((a, b) {
      if (a.isFloorDevicesFeed != b.isFloorDevicesFeed) {
        return a.isFloorDevicesFeed ? -1 : 1;
      }
      return a.id.compareTo(b.id);
    });
    return list;
  }

  /// Determina si una boca debe dibujarse en la fila inferior (par en switches/routers/SFP, o 25..48 en patch panels de 48p).
  bool _isPortBottomRow(RackDeviceModel dev, PortModel port, String face) {
    final cat = dev.template.category;
    if (cat == 'patchbox' && face == 'front') {
      return false;
    }
    final numVal = int.tryParse(
      port.portNumber.replaceAll(RegExp(r'[^0-9]'), ''),
    );
    final facePorts = dev.portsForFace(face);
    if ((cat == 'patch_panel' || cat == 'gateway') &&
        facePorts.length > 24 &&
        numVal != null) {
      return numVal > 24;
    }
    if ((cat == 'switch' || cat == 'router' || cat == 'firewall') &&
        face == 'front' &&
        numVal != null) {
      final isSfp = port.portType == 'sfp_plus' ||
          port.portType.contains('fiber') ||
          port.portNumber.startsWith('SFP');
      if (isSfp) {
        final sfpCount = facePorts
            .where(
              (p) =>
                  p.portType == 'sfp_plus' ||
                  p.portType.contains('fiber') ||
                  p.portNumber.startsWith('SFP'),
            )
            .length;
        if (sfpCount >= 2) {
          return numVal.isEven;
        }
      } else if (!port.portType.contains('power')) {
        final rjCount = facePorts
            .where(
              (p) =>
                  p.portType != 'sfp_plus' &&
                  !p.portType.contains('fiber') &&
                  !p.portNumber.startsWith('SFP') &&
                  !p.portType.contains('power'),
            )
            .length;
        if (rjCount >= 8) {
          return numVal.isEven;
        }
      }
    }
    return port.rowIndex > 0;
  }

  /// Ajusta la posición horizontal relativa `relX` para agrupar visualmente en bloques:
  /// - Patch Panels de 24p (1 fila de 3x8) y de 48p (2 filas de 3x8: 1..24 arriba y 25..48 abajo)
  /// - Casetes verticales de PATCHBOX (24 módulos en 1 sola fila)
  /// - Switches de 24 bocas (2x12 RJ45 + 2x2 SFP+) y Switches de 48 bocas (4 bloques de 2x6 = 48 RJ45 + bloque SFP+ a la derecha)
  double _computeVisualRelX(RackDeviceModel dev, PortModel port) {
    final cat = dev.template.category;
    final numVal = int.tryParse(
      port.portNumber.replaceAll(RegExp(r'[^0-9]'), ''),
    );
    // 1. Patch Panels (24p o 48p) y Bandeja de Fibra (FI-01): 3 bloques de 8 bocas por fila
    if ((cat == 'patch_panel' || cat == 'gateway') &&
        numVal != null &&
        numVal >= 1 &&
        numVal <= 48) {
      final idx = (numVal - 1) % 24; // 0..23 dentro de su fila
      final block = idx ~/ 8; // 0, 1, 2
      final inBlock = idx % 8; // 0..7
      const baseStart = 0.082;
      const blockSpan = 0.252;
      const blockGap = 0.042;
      return baseStart +
          block * (blockSpan + blockGap) +
          (inBlock / 7.0) * blockSpan;
    }
    // 2. PATCHBOX (PBX01, PBX02, PBX03) en cara frontal: 24 casetes verticales en 1 sola fila (1..24)
    if (cat == 'patchbox' &&
        port.face == 'front' &&
        numVal != null &&
        numVal >= 1 &&
        numVal <= 24) {
      final idx = numVal - 1; // 0..23
      return 0.052 + (idx / 23.0) * 0.896;
    }
    // 3. Router (RT01): bloque compacto 2x4 RJ45 (1..8) y a su derecha bloque 2x2 SFP+ (9..12)
    if (cat == 'router' && port.face == 'front' && numVal != null) {
      if (port.portType == 'sfp_plus' || port.portNumber.startsWith('SFP')) {
        final col = ((numVal - 1) ~/ 2).clamp(0, 1);
        return 0.725 + col * 0.046;
      }
      if (numVal >= 1 && numVal <= 8) {
        final col = ((numVal - 1) ~/ 2).clamp(0, 3);
        return 0.545 + (col / 3.0) * 0.115;
      }
    }
    // 4. Switch (24 puertos, 48 puertos o medida personalizada):
    if (cat == 'switch' && port.face == 'front' && numVal != null) {
      final frontPorts = dev.portsForFace('front');
      final isSfp = port.portType == 'sfp_plus' ||
          port.portType.contains('fiber') ||
          port.portNumber.startsWith('SFP');
      final rjCount = frontPorts
          .where(
            (p) =>
                p.portType != 'sfp_plus' &&
                !p.portType.contains('fiber') &&
                !p.portNumber.startsWith('SFP') &&
                !p.portType.contains('power'),
          )
          .length;
      final sfpCount = frontPorts
          .where(
            (p) =>
                p.portType == 'sfp_plus' ||
                p.portType.contains('fiber') ||
                p.portNumber.startsWith('SFP'),
          )
          .length;

      if (isSfp) {
        final sfpCols = ((sfpCount + 1) ~/ 2).clamp(1, 8);
        final col = ((numVal - 1) ~/ 2).clamp(0, sfpCols - 1);
        if (rjCount > 24) {
          // En Switches de 48 bocas, las jaulas SFP+ se sitúan en el extremo derecho [0.858 .. 0.942]
          final startSfp = 0.858;
          final step = sfpCols <= 1 ? 0.0 : (0.084 / (sfpCols - 1)).clamp(0.028, 0.042);
          return startSfp + col * step;
        }
        return 0.775 + col * 0.036;
      }

      if (rjCount > 24) {
        // Switch de alta densidad (ej. 48 bocas RJ45 = 24 columnas organizadas en 4 bloques de 12 bocas / 6 columnas)
        final totalCols = ((rjCount + 1) ~/ 2).clamp(1, 32);
        final col = ((numVal - 1) ~/ 2).clamp(0, totalCols - 1);
        final numBlocks = ((totalCols + 5) ~/ 6).clamp(1, 6);
        final blockIdx = col ~/ 6;
        final colInBlock = col % 6;
        final minX = 0.056;
        final maxX = sfpCount > 0 ? 0.808 : 0.938;
        final blockGap = numBlocks > 1 ? 0.025 : 0.0;
        final totalSpan = maxX - minX - blockGap * (numBlocks - 1);
        final blockSpan = totalSpan / numBlocks;
        final colsInThisBlock = (blockIdx == numBlocks - 1)
            ? (totalCols - blockIdx * 6)
            : 6;
        final localFrac = colsInThisBlock <= 1
            ? 0.5
            : (colInBlock / (colsInThisBlock - 1));
        return minX + blockIdx * (blockSpan + blockGap) + localFrac * blockSpan;
      }

      if (numVal >= 1 && numVal <= 24) {
        final col = ((numVal - 1) ~/ 2).clamp(0, 11);
        return 0.365 + (col / 11.0) * 0.365;
      }
    }
    return port.relX;
  }

  double _computeVisualRelY(RackDeviceModel dev, PortModel port, String face) {
    final cat = dev.template.category;
    if (cat == 'patchbox' && face == 'front') {
      // En PATCHBOX los 24 casetes van en 1 sola fila y el conector RJ45 queda en la mitad inferior del casete
      return 0.65;
    }
    final facePorts = dev.portsForFace(face);
    final hasTwoRows = facePorts.any((p) => _isPortBottomRow(dev, p, face));
    if (hasTwoRows) {
      return _isPortBottomRow(dev, port, face) ? 0.60 : 0.31;
    }
    return 0.56;
  }

  int _externalColsPerRow(RackDeviceModel ext) {
    final count = ext.ports.isEmpty ? 1 : ext.ports.length;
    if (ext.isFloorDevicesFeed) {
      return 3;
    }
    if (ext.isFiberFeed) {
      return count <= 8 ? count : 8;
    }
    return count <= 6 ? count : 6;
  }

  double _externalCardHeight(RackDeviceModel ext) {
    final count = ext.ports.length;
    if (ext.isFloorDevicesFeed) {
      if (count <= 0) return 118.0;
      final rows = ((count - 1) ~/ 3) + 1;
      return 74.0 + rows * 68.0;
    }
    if (count <= 0) return _extCardHeight;
    final colsPerRow = _externalColsPerRow(ext);
    final rows = ((count - 1) ~/ colsPerRow) + 1;
    return 78.0 + rows * 50.0;
  }

  Offset _externalPortLocalCenter(RackDeviceModel ext, int pIdx) {
    final count = ext.ports.length;
    if (ext.isFloorDevicesFeed) {
      if (count <= 0) return const Offset(_extZoneWidth * 0.5, 92.0);
      final rowIdx = pIdx ~/ 3;
      final colIdx = pIdx % 3;
      final relX = 0.18 + colIdx * 0.32;
      final centerY = 92.0 + rowIdx * 68.0;
      return Offset(relX * _extZoneWidth, centerY);
    }
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
        // 1. BARRA SUPERIOR (oculta en Modo Kiosco para presentar el Rack a pantalla completa)
        if (!widget.isKioskMode)
          _buildBarraSuperior(rack, bc, selDev, selConn, nextFreeUpU, nextFreeDownU),

        // 2. CUERPO CENTRAL EN 3 COLUMNAS: Catálogo Izquierdo | Lienzo Central 42U (Front+Back / Individual) + Tomas Exteriores | Panel Derecho
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // COLUMNA IZQUIERDA: Librería de Dispositivos (oculta en Modo Kiosco)
              if (!widget.isKioskMode)
                SelectionContainer.disabled(
                  child: DeviceCatalogPanel(
                    templates: widget.templates,
                    selectedTemplateForClickMount: _selectedTemplateForClick,
                    onSelectTemplate: (tpl) {
                      setState(() => _selectedTemplateForClick = tpl);
                    },
                    onMountFromCmdb: _openInstallFromCmdbAtFirstFreeU,
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
                ),

              // COLUMNA CENTRAL: Lienzo interactivo del Rack con soporte simultáneo Front + Back y Bandeja Inter-Rack
              Expanded(
                child: SelectionContainer.disabled(
                  child: Container(
                    color: const Color(0xFFF4F5F7),
                    child: Stack(
                      children: [
                        _buildBastidoresInteractivos(rack, extOutlets, totalCanvasHeight, computedRoutes, activeSourceOffset, connectedPortColors, occupiedUsFront, occupiedUsBack, outboundConnections),

                        // Capa superior cuando se pulsa la Barra Espaciadora (Modo Mano para arrastrar todo el dashboard del Rack)
                        if (_isPanHandMode)
                          Positioned.fill(
                            child: MouseRegion(
                              cursor: _isSpaceDragging
                                  ? SystemMouseCursors.grabbing
                                  : SystemMouseCursors.grab,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onPanStart: (_) {
                                  setState(() => _isSpaceDragging = true);
                                },
                                onPanUpdate: (details) {
                                  final m = _transformController.value.clone();
                                  m.storage[12] += details.delta.dx;
                                  m.storage[13] += details.delta.dy;
                                  _transformController.value = m;
                                },
                                onPanEnd: (_) {
                                  setState(() => _isSpaceDragging = false);
                                },
                                onPanCancel: () {
                                  setState(() => _isSpaceDragging = false);
                                },
                                child: Align(
                                  alignment: Alignment.bottomCenter,
                                  child: Padding(
                                    padding: const EdgeInsets.only(bottom: 18),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 14,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(0xEE0F172A),
                                        borderRadius: BorderRadius.circular(20),
                                        border: Border.all(
                                          color: AppPalette.sky400,
                                          width: 1.4,
                                        ),
                                      ),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.pan_tool_alt_rounded,
                                            size: 15,
                                            color: AppPalette.sky400,
                                          ),
                                          SizedBox(width: 6),
                                          Text(
                                            'Modo Mano activo — Arrastra con el ratón para mover el dashboard del Rack',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w800,
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

                        // Controles Flotantes Superiores Izquierdos: [♊ Front + Back | Front | Back] + [📷 Foto Equipos ON/OFF] + Filtro de Cables + Mano + Deshacer
                        _buildControlesFlotantes(),
                      ],
                    ),
                  ),
                ),
              ),

              // COLUMNA DERECHA: Panel de Propiedades (oculto en Modo Kiosco)
              if (!widget.isKioskMode)
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
}
