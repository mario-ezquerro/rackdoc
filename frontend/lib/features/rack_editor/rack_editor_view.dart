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
  final List<DeviceTemplateModel> templates;
  final VoidCallback onBackToLocations;
  final ValueChanged<int> onSwitchRack;
  final VoidCallback onTemplatesChanged;
  final UserModel? currentUser;

  const RackEditorView({
    super.key,
    required this.api,
    required this.rackId,
    required this.templates,
    required this.onBackToLocations,
    required this.onSwitchRack,
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

  // Cara activa del rack ('front' o 'back')
  String _activeFace = 'front';

  // Filtro de visualización de cables ('all' | 'network' | 'fiber' | 'power')
  String _cableFilter = 'all';

  // Librería seleccionada en el catálogo izquierdo ('all' | 'Network' | 'Power' | 'Host - HP' | ...)
  String _selectedLibraryGroup = 'all';

  // Selección activa para el panel derecho y hover para controles rápidos
  int? _selectedDeviceId;
  int? _hoveredDeviceId;
  int? _selectedConnectionId;
  int? _hoveredConnectionId;

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

  // Dimensiones constantes del dibujo técnico del Rack (estilo Patchbox CAD) + Zona Exterior Schuko
  static const double _canvasWidth = 1140.0;
  static const double _rackOuterLeft = 104.0;
  static const double _rackOuterWidth = 628.0;
  static const double _rackInnerLeft = 152.0;
  static const double _rackInnerWidth = 532.0;
  static const double _railWidth = 18.0;
  static const double _rackTopMargin = 58.0;
  static const double _uHeightPx = 42.0;

  // Coordenadas del cuadro de Tomas Eléctricas Exteriores (fuera del rack a la derecha)
  static const double _extZoneLeft = 785.0;
  static const double _extZoneWidth = 315.0;
  static const double _extCardTopStart = 96.0;
  static const double _extCardHeight = 128.0;
  static const double _extCardGap = 18.0;

  bool get _canEdit => widget.currentUser?.canEdit ?? true;
  bool get _canConnectRemote => widget.currentUser?.canConnectRemote ?? true;

  @override
  void initState() {
    super.initState();
    _loadRack();
  }

  @override
  void didUpdateWidget(covariant RackEditorView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rackId != widget.rackId) {
      _selectedDeviceId = null;
      _selectedConnectionId = null;
      _pendingSourcePort = null;
      _loadRack();
    }
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

  double _computeVisualRelY(RackDeviceModel dev, PortModel port) {
    final facePorts = dev.portsForFace(_activeFace);
    final hasTwoRows = facePorts.any((p) => p.rowIndex > 0);
    if (hasTwoRows) {
      return port.rowIndex == 0 ? 0.34 : 0.72;
    }
    return 0.56;
  }

  /// Calcula la coordenada exacta (x, y) en el lienzo de cada puerto visible en la cara activa
  /// MÁS las tomas eléctricas exteriores (Schuko) que siempre son visibles fuera del rack.
  Map<int, Offset> _computePortCoordinates(RackDetailModel rack) {
    final map = <int, Offset>{};
    final totalU = rack.totalUnits;

    // 1. Dispositivos montados dentro del Rack (visibles tanto en Front como en Back)
    for (final dev in rack.devices) {
      if (dev.isExternalFeed) continue;
      if (!dev.isVisibleOnFace(_activeFace)) continue;

      final topU = dev.endU;
      final devTopY = _rackTopMargin + (totalU - topU) * _uHeightPx;
      final devHeight = dev.template.uHeight * _uHeightPx;

      final facePorts = dev.portsForFace(_activeFace);
      for (final p in facePorts) {
        final rx = _computeVisualRelX(dev, p);
        final ry = _computeVisualRelY(dev, p);
        final px = _rackInnerLeft + rx * _rackInnerWidth;
        final py = devTopY + ry * devHeight;
        map[p.id] = Offset(px, py);
      }
    }

    // 2. Tomas / Enchufes Schuko Exteriores (fuera del rack a la derecha)
    final extOutlets = _getExternalOutlets(rack);
    for (int idx = 0; idx < extOutlets.length; idx++) {
      final ext = extOutlets[idx];
      final cardTop = _extCardTopStart + idx * (_extCardHeight + _extCardGap);
      final socketsTopCenterY = cardTop + 82.0;
      final count = ext.ports.length;
      for (int pIdx = 0; pIdx < count; pIdx++) {
        final port = ext.ports[pIdx];
        final rel = count == 1 ? 0.5 : (0.14 + (0.72 * pIdx / (count - 1)));
        final px = _extZoneLeft + rel * _extZoneWidth;
        map[port.id] = Offset(px, socketsTopCenterY);
      }
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
  /// donde quepa el equipo completo (`dev.template.uHeight` unidades U libres).
  int? _findNearestFreeU(
    RackDetailModel rack,
    RackDeviceModel dev,
    int direction,
  ) {
    final uHeight = dev.template.uHeight;
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

  Future<void> _moveDeviceToU(RackDeviceModel dev, int targetStartU) async {
    if (!_canEdit) return;
    final rack = _rack;
    if (rack == null) return;
    if (targetStartU == dev.startU) return;

    final uHeight = dev.template.uHeight;
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
      final blockerRange = blocker.template.uHeight > 1
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
    final uHeight = dev.template.uHeight;
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

  Future<void> _handleDropOnUSlot(Object droppedData, int targetStartU) async {
    if (!_canEdit) return;
    setState(() {
      _draggingData = null;
      _hoveredDropU = null;
    });
    if (droppedData is RackDeviceModel) {
      await _moveDeviceToU(droppedData, targetStartU);
    } else if (droppedData is DeviceTemplateModel) {
      await _handleDropOrMountTemplate(droppedData, targetStartU);
    }
  }

  Future<void> _handleDropOrMountTemplate(
    DeviceTemplateModel tpl,
    int targetStartU,
  ) async {
    if (!_canEdit) return;
    final rack = _rack;
    if (rack == null) return;

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

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Montar ${tpl.modelName} en U$targetStartU (Autorrellena Front y Back)',
        ),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
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
                          'Al montar este equipo en Front, su parte trasera (fuentes PSU / puertos traseros) se rellena automáticamente en la vista Back.',
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
                      child: TextField(
                        controller: codeCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Código en Rack (ej. SW04, SRV03)',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: hostnameCtrl,
                        decoration: const InputDecoration(labelText: 'Hostname'),
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
                        decoration: const InputDecoration(labelText: 'Máscara'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: gwCtrl,
                        decoration: const InputDecoration(labelText: 'Gateway'),
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
            child: const Text('Montar en el Rack'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final created = await widget.api.addDeviceToRack(rack.id, {
        'template_id': tpl.id,
        'code': codeCtrl.text.trim(),
        'name': nameCtrl.text.trim(),
        'hostname': hostnameCtrl.text.trim(),
        'fqdn': fqdnCtrl.text.trim(),
        'start_u': targetStartU,
        'mounted_face': _activeFace,
        'ip_address': ipCtrl.text.trim(),
        'subnet_mask': maskCtrl.text.trim(),
        'gateway': gwCtrl.text.trim(),
        'monitoring_enabled': ipCtrl.text.trim().isNotEmpty,
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

    if (srcDev.isExternalFeed) {
      defaultCableType = 'power_ac';
      defaultColor = srcDev.feedColorHex;
      forcedExternalFeedName = '${srcDev.code} (${srcDev.name})';
    } else if (dev.isExternalFeed) {
      defaultCableType = 'power_ac';
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
          ? 'Alimentación $forcedExternalFeedName ➔ ${srcDev.isExternalFeed ? dev.code : srcDev.code}'
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
                          Icons.electrical_services,
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
  // GESTIÓN DE TOMAS ELÉCTRICAS EXTERIORES (ENCHUFES SCHUKO FUERA DEL RACK)
  // ===========================================================================
  Future<void> _showAddOrEditExternalOutletDialog({
    RackDeviceModel? existing,
  }) async {
    if (!_canEdit) return;
    final rack = _rack;
    if (rack == null) return;
    final messenger = ScaffoldMessenger.of(context);

    final extCount = _getExternalOutlets(rack).length;
    final nextLetter = String.fromCharCode(65 + extCount);
    const palette = [
      '#DC2626',
      '#2563EB',
      '#EA580C',
      '#16A34A',
      '#7C3AED',
      '#CA8A04',
      '#0F172A',
    ];

    final codeCtrl = TextEditingController(
      text: existing?.code ?? 'TOMA-$nextLetter',
    );
    final nameCtrl = TextEditingController(
      text: existing?.name ?? 'Línea $nextLetter (Cuadro Eléctrico Sala)',
    );
    final socketsCtrl = TextEditingController(
      text: '${existing?.socketCount ?? 4}',
    );
    String selectedColor =
        existing?.feedColorHex ?? palette[extCount % palette.length];

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => AlertDialog(
          title: Text(
            existing == null
                ? 'Añadir Toma Eléctrica Schuko Exterior'
                : 'Editar Toma Exterior (${existing.code})',
          ),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Las tomas exteriores representan enchufes Schuko o acometidas fuera del bastidor a las que puedes enchufar equipos por delante (Front) o por detrás (Back).',
                  style: TextStyle(fontSize: 11.5, color: Color(0xFF475569)),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: codeCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Código (ej. TOMA-A, TOMA-B)',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: socketsCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Nº Enchufes Schuko (1-12)',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Descripción de la Línea / Circuito Eléctrico',
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Color Estándar de la Línea Eléctrica (sus cables heredarán este color):',
                  style: TextStyle(
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
                            ? const Icon(
                                Icons.bolt,
                                size: 18,
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
              label: Text(existing == null ? 'Añadir Toma' : 'Guardar Cambios'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      try {
        final count =
            (int.tryParse(socketsCtrl.text.trim()) ?? 4).clamp(1, 12);
        if (existing == null) {
          await widget.api.createExternalOutlet(rack.id, {
            'code': codeCtrl.text.trim(),
            'name': nameCtrl.text.trim(),
            'color_hex': selectedColor,
            'socket_count': count,
          });
        } else {
          await widget.api.updateExternalOutlet(existing.id, {
            'code': codeCtrl.text.trim(),
            'name': nameCtrl.text.trim(),
            'color_hex': selectedColor,
            'socket_count': count,
          });
        }
        await _loadRack();
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              existing == null
                  ? 'Nueva toma exterior "${codeCtrl.text.trim()}" añadida.'
                  : 'Toma exterior "${codeCtrl.text.trim()}" actualizada (cables sincronizados al color $selectedColor).',
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

  Future<void> _showCreateCustomTemplateDialog() async {
    if (!_canEdit) return;
    String category = _selectedLibraryGroup == 'Power'
        ? 'pdu'
        : (_selectedLibraryGroup.startsWith('Host') ? 'server' : 'switch');
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
    final frontRj45Ctrl = TextEditingController(
      text: category == 'pdu' ? '0' : '24',
    );
    final frontFiberCtrl = TextEditingController(
      text: category == 'pdu' ? '0' : '4',
    );
    final frontSchukoCtrl = TextEditingController(
      text: category == 'pdu' ? '6' : '0',
    );
    final backPowerCtrl = TextEditingController(text: '2');
    bool isFullDepth = true;

    const presetGroups = [
      'Network',
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
          title: const Text('Crear Nuevo Equipo en Librería'),
          content: SizedBox(
            width: 460,
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
                              frontSchukoCtrl.text = '8';
                            } else if (g.startsWith('Host')) {
                              category = 'server';
                              frontRj45Ctrl.text = '4';
                              frontFiberCtrl.text = '2';
                              frontSchukoCtrl.text = '0';
                              isFullDepth = true;
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
                          'Nombre de Librería (ej. Network, Power, Host - HP)',
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
                        child: Text('Rack Tray (Bandeja)'),
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
                  const Divider(),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: frontRj45Ctrl,
                          decoration: const InputDecoration(
                            labelText: 'RJ45 (Front)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: frontFiberCtrl,
                          decoration: const InputDecoration(
                            labelText: 'SFP Fibra (Front)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: frontSchukoCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Schuko (Front)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: backPowerCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Tomas PSU (Back)',
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
      final rjCount = int.tryParse(frontRj45Ctrl.text.trim()) ?? 0;
      final sfpCount = int.tryParse(frontFiberCtrl.text.trim()) ?? 0;
      final schukoCount = int.tryParse(frontSchukoCtrl.text.trim()) ?? 0;
      final psuCount = int.tryParse(backPowerCtrl.text.trim()) ?? 0;

      final frontGroups = <Map<String, dynamic>>[];
      if (rjCount > 0) {
        frontGroups.add({
          'port_type': 'rj45',
          'prefix': '',
          'count': rjCount,
          'rows': rjCount >= 12 ? 2 : 1,
          'start_x': 0.22,
          'end_x': (sfpCount > 0 || schukoCount > 0) ? 0.68 : 0.90,
        });
      }
      if (sfpCount > 0) {
        frontGroups.add({
          'port_type': 'sfp_plus',
          'prefix': 'SFP',
          'count': sfpCount,
          'rows': sfpCount >= 4 ? 2 : 1,
          'start_x': 0.72,
          'end_x': 0.92,
        });
      }
      if (schukoCount > 0) {
        frontGroups.add({
          'port_type': 'power_schuko',
          'prefix': 'SCH',
          'count': schukoCount,
          'rows': 1,
          'start_x': rjCount > 0 ? 0.70 : 0.18,
          'end_x': 0.90,
        });
      }

      final backGroups = <Map<String, dynamic>>[];
      if (psuCount > 0) {
        backGroups.add({
          'port_type': 'power_c14',
          'prefix': 'PSU',
          'count': psuCount,
          'rows': 1,
          'start_x': 0.15,
          'end_x': 0.40,
        });
      }

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
    const outboundAnchor = Offset(_rackOuterLeft + _rackOuterWidth - 36, 22);

    final computedRoutes = CableGeometryBuilder.computeRoutes(
      connections: rack.connections,
      portPositionsOnActiveFace: portCoords,
      activeFace: _activeFace,
      currentRackId: rack.id,
      leftChannelBaseX: _rackInnerLeft - 24.0,
      rightChannelBaseX: _rackInnerLeft + _rackInnerWidth + 24.0,
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
    final occupiedUsOnFace = <int>{};
    for (final d in rack.devices) {
      if (d.id == draggingDevId) continue;
      if (d.isVisibleOnFace(_activeFace)) {
        for (int u = d.startU; u <= d.endU; u++) {
          occupiedUsOnFace.add(u);
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

              // Barra rápida cuando hay un equipo seleccionado: Subir 1U, Bajar 1U, Cambiar U, Borrar Equipo
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
                        '${selDev.code} (U${selDev.startU}): ',
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
                            ? 'Subir a siguiente posición con ${selDev.template.uHeight}U libres (U$nextFreeUpU)'
                            : 'No hay ${selDev.template.uHeight}U libres por encima',
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
                            ? 'Bajar a siguiente posición con ${selDev.template.uHeight}U libres (U$nextFreeDownU)'
                            : 'No hay ${selDev.template.uHeight}U libres por debajo',
                        visualDensity: VisualDensity.compact,
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
                          'Borrar Equipo',
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
                        'Tirando cable desde ${_pendingSourceDevice?.code}:${_pendingSourcePort?.portNumber} — Haz clic en la boca destino',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF1E3A8A),
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

        // 2. CUERPO CENTRAL EN 3 COLUMNAS: Catálogo Izquierdo | Lienzo Central 42U (Estilo Patchbox) + Tomas Exteriores | Panel Derecho
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // COLUMNA IZQUIERDA: Librería de Dispositivos
              DeviceCatalogPanel(
                templates: widget.templates,
                selectedTemplateForClickMount: _selectedTemplateForClick,
                onSelectTemplate: (tpl) {
                  setState(() => _selectedTemplateForClick = tpl);
                },
                onCreateCustomTemplate: _showCreateCustomTemplateDialog,
                selectedLibraryGroup: _selectedLibraryGroup,
                onSelectLibraryGroup: (group) {
                  setState(() => _selectedLibraryGroup = group);
                },
                onExportLibrary: _handleExportLibraryDialog,
                onImportLibrary: _handleImportLibraryDialog,
                canEdit: _canEdit,
              ),

              // COLUMNA CENTRAL: Lienzo interactivo del Rack con diseño técnico tipo Patchbox
              Expanded(
                child: Container(
                  color: const Color(0xFFF4F5F7),
                  child: Stack(
                    children: [
                      InteractiveViewer(
                        transformationController: _transformController,
                        minScale: 0.45,
                        maxScale: 2.8,
                        boundaryMargin: const EdgeInsets.all(260),
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
                              width: _canvasWidth,
                              height: totalCanvasHeight,
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  // A1. Cabezal superior del armario Rack (igual a la imagen de referencia)
                                  Positioned(
                                    left: _rackOuterLeft,
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

                                  // A2. Marco exterior de doble pared del Armario Rack (estilo CAD de la imagen)
                                  Positioned(
                                    left: _rackOuterLeft,
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
                                    left: _rackInnerLeft - _railWidth,
                                    top: _rackTopMargin,
                                    width: _railWidth,
                                    height: rack.totalUnits * _uHeightPx,
                                    child: _buildPerforated19InchRail(
                                      rack.totalUnits,
                                    ),
                                  ),
                                  Positioned(
                                    left: _rackInnerLeft + _rackInnerWidth,
                                    top: _rackTopMargin,
                                    width: _railWidth,
                                    height: rack.totalUnits * _uHeightPx,
                                    child: _buildPerforated19InchRail(
                                      rack.totalUnits,
                                    ),
                                  ),

                                  // A4. Línea vertical continua de la regla U a la izquierda del armario
                                  Positioned(
                                    left: _rackOuterLeft - 18,
                                    top: _rackTopMargin,
                                    width: 1.5,
                                    height: rack.totalUnits * _uHeightPx,
                                    child: Container(
                                      color: const Color(0xFF475569),
                                    ),
                                  ),

                                  // B. Regla numerada de Unidades U (42 .. 1) y Slots vacíos (DragTarget para Plantillas y para Mover Equipos)
                                  for (int u = rack.totalUnits; u >= 1; u--) ...[
                                    Positioned(
                                      left: _rackOuterLeft - 56,
                                      top: _rackTopMargin +
                                          (rack.totalUnits - u) * _uHeightPx,
                                      width: 44,
                                      height: _uHeightPx,
                                      child: Stack(
                                        clipBehavior: Clip.none,
                                        children: [
                                          // Marca horizontal superior de la regla U
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
                                              padding: const EdgeInsets.only(
                                                right: 10,
                                              ),
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

                                    // Slot U libre (acepta arrastrar un equipo nuevo O mover un equipo ya montado)
                                    if (!occupiedUsOnFace.contains(u))
                                      Positioned(
                                        left: _rackInnerLeft,
                                        top: _rackTopMargin +
                                            (rack.totalUnits - u) * _uHeightPx,
                                        width: _rackInnerWidth,
                                        height: _uHeightPx,
                                        child: DragTarget<Object>(
                                          onWillAcceptWithDetails: (details) {
                                            if (!_canEdit) return false;
                                            if (details.data
                                                    is! DeviceTemplateModel &&
                                                details.data
                                                    is! RackDeviceModel) {
                                              return false;
                                            }
                                            if (_hoveredDropU != u ||
                                                _draggingData != details.data) {
                                              WidgetsBinding.instance
                                                  .addPostFrameCallback((_) {
                                                if (mounted) {
                                                  setState(() {
                                                    _draggingData =
                                                        details.data;
                                                    _hoveredDropU = u;
                                                  });
                                                }
                                              });
                                            }
                                            return true;
                                          },
                                          onLeave: (_) {
                                            if (_hoveredDropU == u) {
                                              WidgetsBinding.instance
                                                  .addPostFrameCallback((_) {
                                                if (mounted &&
                                                    _hoveredDropU == u) {
                                                  setState(
                                                    () => _hoveredDropU = null,
                                                  );
                                                }
                                              });
                                            }
                                          },
                                          onAcceptWithDetails: (details) {
                                            _handleDropOnUSlot(
                                              details.data,
                                              u,
                                            );
                                          },
                                          builder: (ctx, candidate, _) {
                                            final isHovering =
                                                candidate.isNotEmpty;
                                            return InkWell(
                                              onTap: (_canEdit &&
                                                      _selectedTemplateForClick !=
                                                          null)
                                                  ? () =>
                                                      _handleDropOrMountTemplate(
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
                                                      color: const Color(
                                                        0xFFE2E8F0,
                                                      ).withValues(alpha: 0.55),
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
                                                            ? const Color(
                                                                0xFF2563EB,
                                                              )
                                                            : const Color(
                                                                0xFF64748B,
                                                              ),
                                                        width: 1.2,
                                                      ),
                                                    ),
                                                    child: Icon(
                                                      Icons.add,
                                                      size: 13,
                                                      color: isHovering
                                                          ? const Color(
                                                              0xFF2563EB,
                                                            )
                                                          : const Color(
                                                              0xFF64748B,
                                                            ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            );
                                          },
                                        ),
                                      ),
                                  ],

                                  // C. Dispositivos Montados (visibles en Front y autorrellenados en Back)
                                  for (final dev in rack.devices)
                                    if (dev.isVisibleOnFace(_activeFace))
                                      _buildMountedDeviceWidget(
                                        dev: dev,
                                        totalUnits: rack.totalUnits,
                                        connectedPortColors:
                                            connectedPortColors,
                                      ),

                                  // C1. Previsualización Multi-U en tiempo real al arrastrar un equipo (Verde = U libres suficientes, Rojo = Ocupado / No cabe)
                                  if (_hoveredDropU != null &&
                                      _draggingData != null)
                                    Builder(
                                      builder: (_) {
                                        final int uH =
                                            _draggingData is RackDeviceModel
                                                ? (_draggingData
                                                        as RackDeviceModel)
                                                    .template
                                                    .uHeight
                                                : (_draggingData
                                                        as DeviceTemplateModel)
                                                    .uHeight;
                                        final int? exId =
                                            _draggingData is RackDeviceModel
                                                ? (_draggingData
                                                        as RackDeviceModel)
                                                    .id
                                                : null;
                                        final int startU = _hoveredDropU!;
                                        final int endU = startU + uH - 1;
                                        final bool canFit = _canFitAtU(
                                          rack,
                                          startU,
                                          uH,
                                          excludeDeviceId: exId,
                                        );
                                        final int clampedEndU = endU.clamp(
                                          1,
                                          rack.totalUnits,
                                        );
                                        final double topPx = _rackTopMargin +
                                            (rack.totalUnits - clampedEndU) *
                                                _uHeightPx;
                                        final double boxH =
                                            (clampedEndU - startU + 1) *
                                                _uHeightPx;
                                        final String rangeTxt = uH > 1
                                            ? 'U$startU - U$endU ($uH U)'
                                            : 'U$startU (1U)';
                                        return Positioned(
                                          left: _rackInnerLeft,
                                          top: topPx,
                                          width: _rackInnerWidth,
                                          height: boxH,
                                          child: IgnorePointer(
                                            child: Container(
                                              decoration: BoxDecoration(
                                                color: (canFit
                                                        ? const Color(
                                                            0xFF16A34A,
                                                          )
                                                        : const Color(
                                                            0xFFDC2626,
                                                          ))
                                                    .withValues(alpha: 0.22),
                                                border: Border.all(
                                                  color: canFit
                                                      ? const Color(0xFF16A34A)
                                                      : const Color(0xFFDC2626),
                                                  width: 2.2,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              child: Center(
                                                child: Container(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                    horizontal: 10,
                                                    vertical: 3,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: canFit
                                                        ? const Color(
                                                            0xFF15803D,
                                                          )
                                                        : const Color(
                                                            0xFFB91C1C,
                                                          ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                      12,
                                                    ),
                                                  ),
                                                  child: Text(
                                                    canFit
                                                        ? '✓ Soltar en $rangeTxt (${uH}U libres)'
                                                        : '✕ No cabe en $rangeTxt (necesita ${uH}U libres)',
                                                    style: const TextStyle(
                                                      color: Colors.white,
                                                      fontSize: 10.5,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    ),

                                  // C2. TOMAS ELÉCTRICAS EXTERIORES (ENCHUFES SCHUKO FUERA DEL RACK)
                                  _buildExternalPowerOutletsZone(
                                    extOutlets: extOutlets,
                                    connectedPortColors: connectedPortColors,
                                  ),

                                  // D. Capa de Cables Ortogonales
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

                                  // E. Indicador superior derecho OUTBOUND
                                  if (outboundConnections.isNotEmpty)
                                    Positioned(
                                      left: outboundAnchor.dx - 55,
                                      top: 6,
                                      child: PopupMenuButton<ConnectionModel>(
                                        tooltip:
                                            'Conexiones hacia otros Racks de la Sala',
                                        onSelected: (conn) {
                                          final otherRackId =
                                              conn.sourceInfo.rackId != rack.id
                                                  ? conn.sourceInfo.rackId
                                                  : conn.targetInfo.rackId;
                                          widget.onSwitchRack(otherRackId);
                                        },
                                        itemBuilder: (ctx) =>
                                            outboundConnections.map((c) {
                                          final other =
                                              c.sourceInfo.rackId != rack.id
                                                  ? c.sourceInfo
                                                  : c.targetInfo;
                                          return PopupMenuItem(
                                            value: c,
                                            child: Text(
                                              'Ir a ${other.rackCode} (${other.deviceCode}:${other.portNumber}) — ${c.label}',
                                              style: const TextStyle(
                                                fontSize: 12,
                                              ),
                                            ),
                                          );
                                        }).toList(),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 5,
                                          ),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFF0F172A),
                                            borderRadius:
                                                BorderRadius.circular(16),
                                            border: Border.all(
                                              color: const Color(0xFF10B981),
                                              width: 1.5,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Container(
                                                width: 8,
                                                height: 8,
                                                decoration: const BoxDecoration(
                                                  color: Color(0xFF10B981),
                                                  shape: BoxShape.circle,
                                                ),
                                              ),
                                              const SizedBox(width: 6),
                                              const Text(
                                                'OUTBOUND',
                                                style: TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w800,
                                                  letterSpacing: 0.5,
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
                        ),
                      ),

                      // Controles Flotantes Superiores Izquierdos: [Front | Back] + Zoom + Filtro de Cables
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
                            const SizedBox(width: 12),

                            // Conmutador [Front | Back]
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
                                    onTap: () =>
                                        setState(() => _activeFace = 'front'),
                                  ),
                                  _FaceToggleButton(
                                    label: 'Back',
                                    active: _activeFace == 'back',
                                    onTap: () =>
                                        setState(() => _activeFace = 'back'),
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(width: 12),

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
                currentUser: widget.currentUser,
              ),
            ],
          ),
        ),
      ],
    );
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
  // WIDGET DE ZONA EXTERIOR DE TOMAS ELÉCTRICAS SCHUKO (FUERA DEL RACK)
  // ===========================================================================
  Widget _buildExternalPowerOutletsZone({
    required List<RackDeviceModel> extOutlets,
    required Map<int, Color> connectedPortColors,
  }) {
    final totalHeight =
        extOutlets.length * (_extCardHeight + _extCardGap) + 90.0;

    return Positioned(
      left: _extZoneLeft,
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
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'TOMAS ELÉCTRICAS EXTERIORES (SCHUKO)',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.4,
                          ),
                        ),
                        Text(
                          'Conecta equipos de Front o Back con color por línea',
                          style: TextStyle(
                            color: Color(0xFF94A3B8),
                            fontSize: 9.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_canEdit)
                    InkWell(
                      onTap: () => _showAddOrEditExternalOutletDialog(),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2563EB),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add, size: 13, color: Colors.white),
                            SizedBox(width: 2),
                            Text(
                              'Ampliar',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          for (int idx = 0; idx < extOutlets.length; idx++)
            _buildSingleExternalOutletCard(
              ext: extOutlets[idx],
              index: idx,
              canDelete: _canEdit && extOutlets.length > 1,
              connectedPortColors: connectedPortColors,
            ),
        ],
      ),
    );
  }

  Widget _buildSingleExternalOutletCard({
    required RackDeviceModel ext,
    required int index,
    required bool canDelete,
    required Map<int, Color> connectedPortColors,
  }) {
    final topInZone =
        (_extCardTopStart - (_rackTopMargin - 20)) +
            index * (_extCardHeight + _extCardGap);
    final feedColor = CableGeometryBuilder.parseHexColor(ext.feedColorHex);
    final count = ext.ports.length;

    return Positioned(
      left: 0,
      top: topInZone,
      width: _extZoneWidth,
      height: _extCardHeight,
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
                    const Icon(Icons.bolt, size: 16, color: Colors.white),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        '${ext.code} • ${ext.name}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
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
                        tooltip: 'Editar nombre, color o número de enchufes',
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
              top: 41,
              right: 10,
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: feedColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Enchufes Schuko 230V ($count tomas • Cable ${ext.feedColorHex})',
                    style: const TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF475569),
                    ),
                  ),
                ],
              ),
            ),
            for (int pIdx = 0; pIdx < count; pIdx++)
              _buildSchukoSocketWidget(
                ext: ext,
                port: ext.ports[pIdx],
                index: pIdx,
                totalCount: count,
                feedColor: feedColor,
                connectedColor: connectedPortColors[ext.ports[pIdx].id],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSchukoSocketWidget({
    required RackDeviceModel ext,
    required PortModel port,
    required int index,
    required int totalCount,
    required Color feedColor,
    required Color? connectedColor,
  }) {
    final isPending = _pendingSourcePort?.id == port.id;
    final isConnected = connectedColor != null;
    final rel = totalCount == 1
        ? 0.5
        : (0.14 + (0.72 * index / (totalCount - 1)));
    const socketSize = 36.0;
    final leftPx = rel * _extZoneWidth - socketSize / 2.0;
    const topPx = 82.0 - socketSize / 2.0;

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
  // CHASIS DE EQUIPO MONTADO EN RACK (ESTILO TÉCNICO PATCHBOX + ARRASTRAR DIRECTO A U LIBRE)
  // ===========================================================================
  Widget _buildMountedDeviceWidget({
    required RackDeviceModel dev,
    required int totalUnits,
    required Map<int, Color> connectedPortColors,
  }) {
    final topU = dev.endU;
    final topY = _rackTopMargin + (totalUnits - topU) * _uHeightPx;
    final heightPx = dev.template.uHeight * _uHeightPx;
    final isSelected = dev.id == _selectedDeviceId;
    final isHovered = dev.id == _hoveredDeviceId;
    final facePorts = dev.portsForFace(_activeFace);
    final isRearAutoView = dev.mountedFace != _activeFace;
    final rack = _rack;
    final nextUpU = rack != null ? _findNearestFreeU(rack, dev, 1) : null;
    final nextDownU = rack != null ? _findNearestFreeU(rack, dev, -1) : null;

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
          color: isDropTarget
              ? const Color(0xFFFEE2E2)
              : (isSelected
                  ? const Color(0xFFF8FAFF)
                  : (isRearAutoView
                      ? const Color(0xFFF8FAFC)
                      : Colors.white)),
          border: Border.symmetric(
            horizontal: BorderSide(
              color: isSelected
                  ? const Color(0xFF2563EB)
                  : const Color(0xFFCBD5E1),
              width: isSelected ? 1.6 : 0.9,
            ),
          ),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Orejetas laterales de anclaje sobre el raíl de 19" izquierdo y derecho
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: _railWidth,
              child: _buildDeviceMountingEar(dev.template.uHeight),
            ),
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: _railWidth,
              child: _buildDeviceMountingEar(dev.template.uHeight),
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

            // Información sutil cuando tiene pocas bocas en esta cara (ej. parte trasera con PSU o servidor)
            if (facePorts.length <= 12)
              Positioned(
                left: _railWidth + 28,
                top: 3,
                child: Text(
                  '${dev.name}${isRearAutoView ? ' • [Back U${dev.startU}]' : ''}${dev.ipAddress.isNotEmpty ? ' • ${dev.ipAddress}' : ''}${dev.monitoringEnabled ? ' • HB:${dev.monitorMethod.toUpperCase()}' : ''}',
                  style: const TextStyle(
                    fontSize: 8.5,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF64748B),
                  ),
                ),
              ),

            // Bocas / Puertos individuales (desplazados por _railWidth porque el chasis incluye las orejetas)
            for (final port in facePorts)
              _buildPortWidget(
                dev: dev,
                port: port,
                devHeight: heightPx,
                connectedColor: connectedPortColors[port.id],
              ),

            // Controles rápidos flotantes en el propio equipo (Arrastrar, Subir a U libre, Bajar a U libre, Borrar)
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
                                ? 'Subir a U$nextUpU (${dev.template.uHeight}U libres)'
                                : 'No hay ${dev.template.uHeight}U libres más arriba',
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
                                ? 'Bajar a U$nextDownU (${dev.template.uHeight}U libres)'
                                : 'No hay ${dev.template.uHeight}U libres más abajo',
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
                                horizontal: 4,
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
      left: _rackInnerLeft - _railWidth,
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
          _handleDropOnUSlot(details.data, dev.startU);
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
                setState(() {
                  _selectedDeviceId = dev.id;
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
                        'Moviendo ${dev.code} (${dev.name}) • Requiere ${dev.template.uHeight}U libres',
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
                    'Moviendo ${dev.code} (${dev.template.uHeight}U) — Suelta en una posición con ${dev.template.uHeight}U libres',
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
    final ry = _computeVisualRelY(dev, port);

    final jackW = isMalePlug
        ? 22.0
        : (isSchuko ? 16.0 : (isPower ? 15.0 : 10.5));
    final jackH = isMalePlug
        ? 15.0
        : (isSchuko ? 14.0 : (isPower ? 11.0 : 8.5));

    final centerX = _railWidth + rx * _rackInnerWidth;
    final centerY = ry * devHeight;

    final facePorts = dev.portsForFace(_activeFace);
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
