import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import '../../../core/file_downloader.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/avisos.dart';

/// Nodo parseado de un diagrama `flowchart` / `graph` de Mermaid.
class MermaidGraphNode {
  final String id;
  String label;
  int rank;
  double x;
  double y;
  final double width;
  final double height;

  MermaidGraphNode({
    required this.id,
    required this.label,
    this.rank = 0,
    this.x = 0,
    this.y = 0,
    this.width = 216,
    this.height = 64,
  });
}

/// Arista parseada de un diagrama Mermaid (`-->`, `-.->`, `-->|"label"|`).
class MermaidGraphEdge {
  final String sourceId;
  final String targetId;
  final String label;
  final bool dashed;

  const MermaidGraphEdge({
    required this.sourceId,
    required this.targetId,
    this.label = '',
    this.dashed = false,
  });
}

/// Grafo Mermaid ya posicionado y listo para renderizar en 2D.
class MermaidParsedLayout {
  final String direction; // 'TD' | 'LR'
  final List<MermaidGraphNode> nodes;
  final List<MermaidGraphEdge> edges;
  final double canvasWidth;
  final double canvasHeight;

  const MermaidParsedLayout({
    required this.direction,
    required this.nodes,
    required this.edges,
    required this.canvasWidth,
    required this.canvasHeight,
  });
}

/// Extrae y calcula el layout jerárquico (Sugiyama ligero con ruptura de ciclos)
/// para cualquier bloque Mermaid `flowchart TD/TB/LR` o `graph TD/LR` 100% en local
/// (sin depender de CDNs externos, garantizando privacidad air-gapped en el CPD).
MermaidParsedLayout parseAndLayoutMermaid(
  String rawInput, {
  String? overrideDirection,
}) {
  String src = rawInput.trim();
  final fenceMatch = RegExp(
    r'```mermaid\s*([\s\S]*?)```',
    caseSensitive: false,
  ).firstMatch(src);
  if (fenceMatch != null) {
    src = (fenceMatch.group(1) ?? '').trim();
  }

  String dir = 'TD';
  final nodesById = <String, MermaidGraphNode>{};
  final edges = <MermaidGraphEdge>[];
  final seenEdgeKeys = <String>{};

  MermaidGraphNode upsertNode(String rawToken) {
    final token = rawToken.trim();
    // Soporta ID["Label"], ID[Label], ID("Label"), ID((Label)), ID{Label} o ID simple
    final m = RegExp(
      r'^([A-Za-z0-9_.\-]+)\s*(?:\[\s*"?([^"\]]*)"?\s*\]|\(\(\s*"?([^"\)]*)"?\s*\)\)|\(\s*"?([^"\)]*)"?\s*\)|\{\s*"?([^"\}]*)"?\s*\})?$',
    ).firstMatch(token);
    final id = (m?.group(1) ?? token).trim();
    final extractedLabel = (m?.group(2) ??
            m?.group(3) ??
            m?.group(4) ??
            m?.group(5) ??
            '')
        .trim();

    final existing = nodesById[id];
    if (existing != null) {
      if (extractedLabel.isNotEmpty && existing.label == existing.id) {
        existing.label = extractedLabel;
      }
      return existing;
    }
    final node = MermaidGraphNode(
      id: id,
      label: extractedLabel.isNotEmpty ? extractedLabel : id,
    );
    nodesById[id] = node;
    return node;
  }

  final edgeRegex = RegExp(
    r'^(.+?)\s*(-\.->|-\.-|==>|--+>|---)\s*(?:\|\s*"?([^"\|]*)"?\s*\|\s*)?(.+)$',
  );

  for (final rawLine in src.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty ||
        line.startsWith('%%') ||
        line.startsWith('classDef ') ||
        line.startsWith('class ') ||
        line.startsWith('style ') ||
        line == 'end') {
      continue;
    }
    final headerMatch = RegExp(
      r'^(?:flowchart|graph)\s+(TD|TB|LR|RL|BT)\b',
      caseSensitive: false,
    ).firstMatch(line);
    if (headerMatch != null) {
      final d = (headerMatch.group(1) ?? 'TD').toUpperCase();
      dir = (d == 'LR' || d == 'RL') ? 'LR' : 'TD';
      continue;
    }
    if (line.toLowerCase().startsWith('subgraph ')) {
      continue;
    }

    final em = edgeRegex.firstMatch(line);
    if (em != null) {
      final leftRaw = (em.group(1) ?? '').trim();
      final arrow = (em.group(2) ?? '-->').trim();
      final lbl = (em.group(3) ?? '').trim();
      final rightRaw = (em.group(4) ?? '').trim();
      if (leftRaw.isNotEmpty && rightRaw.isNotEmpty) {
        final sNode = upsertNode(leftRaw);
        final tNode = upsertNode(rightRaw);
        final dashed = arrow.contains('.');
        final eKey = '${sNode.id}|${tNode.id}|$lbl|$dashed';
        if (sNode.id != tNode.id && seenEdgeKeys.add(eKey)) {
          edges.add(
            MermaidGraphEdge(
              sourceId: sNode.id,
              targetId: tNode.id,
              label: lbl,
              dashed: dashed,
            ),
          );
        }
      }
      continue;
    }

    // Declaración aislada de nodo: N_01["Etiqueta"]
    if (RegExp(r'^[A-Za-z0-9_.\-]+\s*[\[\(\{]').hasMatch(line)) {
      upsertNode(line);
    }
  }

  final effectiveDir = overrideDirection ?? dir;
  final nodeList = nodesById.values.toList();
  if (nodeList.isEmpty) {
    return MermaidParsedLayout(
      direction: effectiveDir,
      nodes: const [],
      edges: const [],
      canvasWidth: 800,
      canvasHeight: 420,
    );
  }

  // Asignación jerárquica de niveles (ranks) tolerante a ciclos
  final inDegree = <String, int>{for (final n in nodeList) n.id: 0};
  final outgoing = <String, List<String>>{for (final n in nodeList) n.id: []};
  final incoming = <String, List<String>>{for (final n in nodeList) n.id: []};
  for (final e in edges) {
    outgoing[e.sourceId]?.add(e.targetId);
    incoming[e.targetId]?.add(e.sourceId);
    inDegree[e.targetId] = (inDegree[e.targetId] ?? 0) + 1;
  }

  final visited = <String>{};
  final queue = <String>[
    for (final n in nodeList)
      if ((inDegree[n.id] ?? 0) == 0) n.id,
  ];
  if (queue.isEmpty) {
    queue.add(nodeList.first.id);
  }

  while (queue.isNotEmpty) {
    final cur = queue.removeAt(0);
    visited.add(cur);
    final curRank = nodesById[cur]!.rank;
    for (final nxt in (outgoing[cur] ?? const <String>[])) {
      if (!visited.contains(nxt)) {
        final candRank = math.min(nodeList.length, curRank + 1);
        if (candRank > nodesById[nxt]!.rank) {
          nodesById[nxt]!.rank = candRank;
        }
        if (!queue.contains(nxt)) {
          queue.add(nxt);
        }
      }
    }
  }

  // Agrupar por nivel y ordenar por baricentro de padres para minimizar cruces
  final byRank = <int, List<MermaidGraphNode>>{};
  int maxRank = 0;
  for (final n in nodeList) {
    byRank.putIfAbsent(n.rank, () => []).add(n);
    if (n.rank > maxRank) maxRank = n.rank;
  }

  final orderIndex = <String, double>{};
  for (int r = 0; r <= maxRank; r++) {
    final row = byRank[r] ?? [];
    if (r > 0) {
      row.sort((a, b) {
        final pa = incoming[a.id] ?? const [];
        final pb = incoming[b.id] ?? const [];
        final ba = pa.isEmpty
            ? 999.0
            : pa.map((p) => orderIndex[p] ?? 0.0).reduce((x, y) => x + y) /
                pa.length;
        final bb = pb.isEmpty
            ? 999.0
            : pb.map((p) => orderIndex[p] ?? 0.0).reduce((x, y) => x + y) /
                pb.length;
        return ba.compareTo(bb);
      });
    }
    for (int i = 0; i < row.length; i++) {
      orderIndex[row[i].id] = i.toDouble();
    }
  }

  // Si un mismo nivel tiene demasiados nodos (ej. >6), partir en sub-filas limpias
  const int maxPerCrossAxis = 6;
  final visualBands = <List<MermaidGraphNode>>[];
  for (int r = 0; r <= maxRank; r++) {
    final row = byRank[r] ?? [];
    for (int i = 0; i < row.length; i += maxPerCrossAxis) {
      visualBands.add(
        row.sublist(i, math.min(row.length, i + maxPerCrossAxis)),
      );
    }
  }

  const double pad = 44.0;
  const double nodeW = 216.0;
  const double nodeH = 64.0;
  const double crossGap = 28.0;
  const double mainGap = 76.0;

  int widestCount = 1;
  for (final band in visualBands) {
    if (band.length > widestCount) widestCount = band.length;
  }

  if (effectiveDir == 'LR') {
    final double totalH =
        pad * 2 + widestCount * nodeH + (widestCount - 1) * crossGap;
    final double totalW =
        pad * 2 + visualBands.length * nodeW + (visualBands.length - 1) * mainGap;
    for (int b = 0; b < visualBands.length; b++) {
      final band = visualBands[b];
      final bandH = band.length * nodeH + (band.length - 1) * crossGap;
      final startY = (totalH - bandH) / 2.0;
      final x = pad + b * (nodeW + mainGap);
      for (int j = 0; j < band.length; j++) {
        band[j].x = x;
        band[j].y = startY + j * (nodeH + crossGap);
      }
    }
    return MermaidParsedLayout(
      direction: 'LR',
      nodes: nodeList,
      edges: edges,
      canvasWidth: math.max(820, totalW),
      canvasHeight: math.max(460, totalH),
    );
  } else {
    final double totalW =
        pad * 2 + widestCount * nodeW + (widestCount - 1) * crossGap;
    final double totalH =
        pad * 2 + visualBands.length * nodeH + (visualBands.length - 1) * mainGap;
    for (int b = 0; b < visualBands.length; b++) {
      final band = visualBands[b];
      final bandW = band.length * nodeW + (band.length - 1) * crossGap;
      final startX = (totalW - bandW) / 2.0;
      final y = pad + b * (nodeH + mainGap);
      for (int j = 0; j < band.length; j++) {
        band[j].x = startX + j * (nodeW + crossGap);
        band[j].y = y;
      }
    }
    return MermaidParsedLayout(
      direction: 'TD',
      nodes: nodeList,
      edges: edges,
      canvasWidth: math.max(860, totalW),
      canvasHeight: math.max(460, totalH),
    );
  }
}

/// Visor Gráfico Interactivo Nativo para diagramas Mermaid en RackDoc:
/// soporta zoom/pan con ratón o trackpad, cambio en vivo `Vertical (TD)` ⇄ `Horizontal (LR)`,
/// resaltado de conexiones al pulsar un nodo, vista a pantalla completa y descarga PNG 2x.
class MermaidVisualViewer extends StatefulWidget {
  final String mermaidCode;
  final String title;
  final bool showExpandButton;

  const MermaidVisualViewer({
    super.key,
    required this.mermaidCode,
    this.title = 'Diagrama Mermaid',
    this.showExpandButton = true,
  });

  @override
  State<MermaidVisualViewer> createState() => _MermaidVisualViewerState();
}

class _MermaidVisualViewerState extends State<MermaidVisualViewer> {
  final GlobalKey _repaintKey = GlobalKey();
  final TransformationController _transformCtrl = TransformationController();
  String? _directionOverride;
  String? _selectedNodeId;
  bool _exportingPng = false;

  @override
  void dispose() {
    _transformCtrl.dispose();
    super.dispose();
  }

  void _zoomBy(double factor) {
    final current = _transformCtrl.value.clone();
    // ignore: deprecated_member_use
    current.scale(factor, factor);
    _transformCtrl.value = current;
  }

  Future<void> _exportPng() async {
    final messenger = ScaffoldMessenger.of(context);
    final ctx = _repaintKey.currentContext;
    if (ctx == null) return;
    setState(() => _exportingPng = true);
    try {
      final boundary = ctx.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;
      final img = await boundary.toImage(pixelRatio: 2.0);
      final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;
      final bytes = byteData.buffer.asUint8List();
      final safeName = widget.title
          .toLowerCase()
          .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
          .replaceAll(RegExp(r'^_+|_+$'), '');
      await downloadBytesAsFile(
        bytes: bytes,
        filename: '${safeName.isEmpty ? "mermaid_rackdoc" : safeName}.png',
        mimeType: 'image/png',
      );
      messenger.avisoExito('Diagrama Mermaid exportado en PNG (2x).');
    } catch (e) {
      messenger.avisoError(e);
    } finally {
      if (mounted) {
        setState(() => _exportingPng = false);
      }
    }
  }

  void _openFullScreenModal() {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog.fullscreen(
        child: Scaffold(
          backgroundColor: AppPalette.slate50,
          appBar: AppBar(
            backgroundColor: AppPalette.slate900,
            foregroundColor: Colors.white,
            title: Text(
              'Visor Mermaid — ${widget.title}',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
            ),
            actions: [
              TextButton.icon(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: widget.mermaidCode));
                  ScaffoldMessenger.of(ctx).avisoExito(
                    'Código fuente Mermaid copiado.',
                  );
                },
                icon: const Icon(
                  Icons.copy_rounded,
                  size: 16,
                  color: Colors.white,
                ),
                label: const Text(
                  'Copiar Código',
                  style: TextStyle(color: Colors.white),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ],
          ),
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: MermaidVisualViewer(
              mermaidCode: widget.mermaidCode,
              title: widget.title,
              showExpandButton: false,
            ),
          ),
        ),
      ),
    );
  }

  (Color bg, Color border, IconData icon) _styleForNode(MermaidGraphNode n) {
    if (n.id == 'ROOT') {
      return (AppPalette.slate900, AppPalette.slate900, Icons.hub_rounded);
    }
    if (n.id.startsWith('R_')) {
      return (
        AppPalette.blue50,
        AppPalette.blue600,
        Icons.developer_board_rounded,
      );
    }
    if (n.id.startsWith('D_')) {
      return (AppPalette.sky50, AppPalette.sky600, Icons.dns_rounded);
    }
    if (n.id.startsWith('N_')) {
      return (
        AppPalette.indigo100,
        AppPalette.indigo600,
        Icons.layers_outlined,
      );
    }
    return (Colors.white, AppPalette.teal600, Icons.memory_rounded);
  }

  @override
  Widget build(BuildContext context) {
    final layout = parseAndLayoutMermaid(
      widget.mermaidCode,
      overrideDirection: _directionOverride,
    );

    if (layout.nodes.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: AppPalette.slate50,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppPalette.slate200),
        ),
        child: const Center(
          child: Text(
            'Este documento no contiene nodos Mermaid renderizables.',
            style: TextStyle(fontSize: 12, color: AppPalette.slate500),
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: AppPalette.slate50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppPalette.slate300),
      ),
      child: Column(
        children: [
          // BARRA DE HERRAMIENTAS DEL VISOR MERMAID
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
              border: Border(bottom: BorderSide(color: AppPalette.slate200)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.account_tree_rounded,
                  size: 16,
                  color: AppPalette.indigo600,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Visor Mermaid Interactivo (${layout.nodes.length} nodos · ${layout.edges.length} enlaces)',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: AppPalette.slate800,
                    ),
                  ),
                ),
                SegmentedButton<String>(
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(value: 'TD', label: Text('Vertical')),
                    ButtonSegment(value: 'LR', label: Text('Horizontal')),
                  ],
                  selected: {layout.direction},
                  onSelectionChanged: (s) => setState(() {
                    _directionOverride = s.first;
                    _transformCtrl.value = Matrix4.identity();
                  }),
                ),
                const SizedBox(width: 6),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Acercar (+)',
                  onPressed: () => _zoomBy(1.2),
                  icon: const Icon(Icons.zoom_in_rounded, size: 18),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Alejar (-)',
                  onPressed: () => _zoomBy(0.84),
                  icon: const Icon(Icons.zoom_out_rounded, size: 18),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Restablecer vista',
                  onPressed: () => _transformCtrl.value = Matrix4.identity(),
                  icon: const Icon(Icons.center_focus_strong_rounded, size: 17),
                ),
                OutlinedButton.icon(
                  onPressed: _exportingPng ? null : _exportPng,
                  icon: const Icon(Icons.image_outlined, size: 14),
                  label: const Text(
                    'PNG',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
                if (widget.showExpandButton) ...[
                  const SizedBox(width: 6),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Abrir a pantalla completa',
                    onPressed: _openFullScreenModal,
                    icon: const Icon(Icons.open_in_full_rounded, size: 17),
                  ),
                ],
              ],
            ),
          ),

          // LIENZO GRÁFICO 2D CON ZOOM / PAN
          Expanded(
            child: SelectionContainer.disabled(
              child: InteractiveViewer(
                transformationController: _transformCtrl,
                constrained: false,
                boundaryMargin: const EdgeInsets.all(200),
                minScale: 0.3,
                maxScale: 2.6,
                child: RepaintBoundary(
                  key: _repaintKey,
                  child: Container(
                    width: layout.canvasWidth,
                    height: layout.canvasHeight,
                    color: AppPalette.slate50,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _MermaidEdgesPainter(
                              layout: layout,
                              selectedNodeId: _selectedNodeId,
                            ),
                          ),
                        ),
                        for (final n in layout.nodes) _buildMermaidNodeBox(n),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMermaidNodeBox(MermaidGraphNode n) {
    final (bgCol, borderCol, iconData) = _styleForNode(n);
    final isRoot = n.id == 'ROOT';
    final isSelected = n.id == _selectedNodeId;

    return Positioned(
      left: n.x,
      top: n.y,
      width: n.width,
      height: n.height,
      child: GestureDetector(
        onTap: () => setState(
          () => _selectedNodeId = isSelected ? null : n.id,
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: bgCol,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected ? AppPalette.amber500 : borderCol,
              width: isSelected ? 2.6 : 1.7,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: isSelected ? 0.14 : 0.05),
                blurRadius: isSelected ? 10 : 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(
                iconData,
                size: 16,
                color: isRoot ? AppPalette.sky400 : borderCol,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  n.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.25,
                    fontWeight: FontWeight.w700,
                    color: isRoot ? Colors.white : AppPalette.slate900,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MermaidEdgesPainter extends CustomPainter {
  final MermaidParsedLayout layout;
  final String? selectedNodeId;

  _MermaidEdgesPainter({
    required this.layout,
    required this.selectedNodeId,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final map = {for (final n in layout.nodes) n.id: n};
    final isLR = layout.direction == 'LR';

    for (final e in layout.edges) {
      final s = map[e.sourceId];
      final t = map[e.targetId];
      if (s == null || t == null) continue;

      final Offset p1 = isLR
          ? Offset(s.x + s.width, s.y + s.height / 2)
          : Offset(s.x + s.width / 2, s.y + s.height);
      final Offset p2 = isLR
          ? Offset(t.x, t.y + t.height / 2)
          : Offset(t.x + t.width / 2, t.y);

      final highlighted = selectedNodeId != null &&
          (e.sourceId == selectedNodeId || e.targetId == selectedNodeId);
      final lineCol = highlighted
          ? AppPalette.amber600
          : (e.dashed ? AppPalette.sky600 : AppPalette.slate500);

      final paint = Paint()
        ..color = lineCol
        ..style = PaintingStyle.stroke
        ..strokeWidth = highlighted ? 2.6 : 1.7;

      final ctrl1 = isLR
          ? Offset((p1.dx + p2.dx) / 2, p1.dy)
          : Offset(p1.dx, (p1.dy + p2.dy) / 2);
      final ctrl2 = isLR
          ? Offset((p1.dx + p2.dx) / 2, p2.dy)
          : Offset(p2.dx, (p1.dy + p2.dy) / 2);

      final path = Path()
        ..moveTo(p1.dx, p1.dy)
        ..cubicTo(ctrl1.dx, ctrl1.dy, ctrl2.dx, ctrl2.dy, p2.dx, p2.dy);

      if (e.dashed) {
        for (final m in path.computeMetrics()) {
          double d = 0.0;
          while (d < m.length) {
            canvas.drawPath(m.extractPath(d, math.min(d + 6.0, m.length)), paint);
            d += 11.0;
          }
        }
      } else {
        canvas.drawPath(path, paint);
      }

      // Punta de flecha en p2
      final angle = math.atan2(p2.dy - ctrl2.dy, p2.dx - ctrl2.dx);
      const arrowLen = 8.0;
      final a1 = Offset(
        p2.dx - arrowLen * math.cos(angle - 0.45),
        p2.dy - arrowLen * math.sin(angle - 0.45),
      );
      final a2 = Offset(
        p2.dx - arrowLen * math.cos(angle + 0.45),
        p2.dy - arrowLen * math.sin(angle + 0.45),
      );
      final arrowPath = Path()
        ..moveTo(p2.dx, p2.dy)
        ..lineTo(a1.dx, a1.dy)
        ..lineTo(a2.dx, a2.dy)
        ..close();
      canvas.drawPath(arrowPath, Paint()..color = lineCol);

      if (e.label.isNotEmpty) {
        final mid = Offset((p1.dx + p2.dx) / 2, (p1.dy + p2.dy) / 2);
        final tp = TextPainter(
          text: TextSpan(
            text: e.label,
            style: const TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              color: AppPalette.slate800,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final pill = RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: mid,
            width: tp.width + 10,
            height: tp.height + 4,
          ),
          const Radius.circular(4),
        );
        canvas.drawRRect(pill, Paint()..color = Colors.white);
        canvas.drawRRect(
          pill,
          Paint()
            ..color = lineCol.withValues(alpha: 0.6)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.0,
        );
        tp.paint(canvas, Offset(mid.dx - tp.width / 2, mid.dy - tp.height / 2));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _MermaidEdgesPainter oldDelegate) {
    return oldDelegate.layout != layout ||
        oldDelegate.selectedNodeId != selectedNodeId;
  }
}
