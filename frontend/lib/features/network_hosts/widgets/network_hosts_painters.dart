part of '../network_hosts_view.dart';

/// Pintores `CustomPainter` de `4. Red & Host`: cuadrícula 2D del Stack,
/// flechas curvas de flujo entre nodos y gráficas vectoriales de Prometheus.
// =============================================================================
// CUADRÍCULA ARQUITECTÓNICA 2D LIBRE (COMO EN DATACENTER FLOOR VIEW)
// =============================================================================

class _StackArchitecturalGridPainter extends CustomPainter {
  final double scale;

  _StackArchitecturalGridPainter({required this.scale});

  @override
  void paint(Canvas canvas, Size size) {
    final step = (28.0 * scale).clamp(18.0, 56.0);
    final minorPaint = Paint()
      ..color = AppTheme.border.withValues(alpha: 0.22)
      ..strokeWidth = 0.7;
    final majorPaint = Paint()
      ..color = AppTheme.border.withValues(alpha: 0.45)
      ..strokeWidth = 1.0;

    int col = 0;
    for (double x = 0; x <= size.width; x += step) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        (col % 4 == 0) ? majorPaint : minorPaint,
      );
      col++;
    }
    int row = 0;
    for (double y = 0; y <= size.height; y += step) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        (row % 4 == 0) ? majorPaint : minorPaint,
      );
      row++;
    }
  }

  @override
  bool shouldRepaint(covariant _StackArchitecturalGridPainter oldDelegate) =>
      oldDelegate.scale != scale;
}

// =============================================================================
// CUSTOM PAINTER DE SERIES TEMPORALES DE PROMETHEUS AFINADO
// (CURVAS SUAVES BÉZIER, EJES Y/X, UMBRALES WARNING/CRITICAL Y PUNTOS EN VIVO)
// =============================================================================

class _PrometheusSeriesChartPainter extends CustomPainter {
  final List<Map<String, dynamic>> points;
  final String keyA;
  final Color colorA;
  final String? keyB;
  final Color? colorB;
  final String unit;
  final double? warnThreshold;
  final double? critThreshold;

  _PrometheusSeriesChartPainter({
    required this.points,
    required this.keyA,
    required this.colorA,
    this.keyB,
    this.colorB,
    this.unit = '',
    this.warnThreshold,
    this.critThreshold,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;

    const leftPad = 34.0;
    const bottomPad = 15.0;
    const topPad = 6.0;
    final chartW = math.max(20.0, size.width - leftPad - 4.0);
    final chartH = math.max(20.0, size.height - bottomPad - topPad);

    double maxVal = unit == '%' ? 100.0 : 1.0;
    for (final p in points) {
      final va = (p[keyA] as num?)?.toDouble() ?? 0.0;
      if (va > maxVal) maxVal = va;
      if (keyB != null) {
        final vb = (p[keyB] as num?)?.toDouble() ?? 0.0;
        if (vb > maxVal) maxVal = vb;
      }
    }
    if (unit != '%') {
      maxVal = math.max(maxVal * 1.18, 5.0);
    }

    final gridPaint = Paint()
      ..color = AppTheme.border.withValues(alpha: 0.38)
      ..strokeWidth = 0.8;

    // Líneas guía horizontales + etiquetas de escala en el eje Y
    for (int i = 0; i <= 3; i++) {
      final frac = i / 3.0;
      final y = topPad + chartH * frac;
      canvas.drawLine(
        Offset(leftPad, y),
        Offset(leftPad + chartW, y),
        gridPaint,
      );
      final val = maxVal * (1.0 - frac);
      final lbl = val >= 10
          ? '${val.toStringAsFixed(0)}$unit'
          : '${val.toStringAsFixed(1)}$unit';
      final tp = TextPainter(
        text: TextSpan(
          text: lbl,
          style: const TextStyle(
            fontSize: 8.2,
            fontFamily: 'monospace',
            color: AppTheme.textMuted,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(math.max(0, leftPad - tp.width - 4), y - 5));
    }

    // Líneas de umbral Warning / Critical si aplican
    if (warnThreshold != null && warnThreshold! <= maxVal) {
      final wy = topPad + chartH * (1.0 - (warnThreshold! / maxVal));
      canvas.drawLine(
        Offset(leftPad, wy),
        Offset(leftPad + chartW, wy),
        Paint()
          ..color = AppTheme.warning.withValues(alpha: 0.45)
          ..strokeWidth = 1.0,
      );
    }
    if (critThreshold != null && critThreshold! <= maxVal) {
      final cy = topPad + chartH * (1.0 - (critThreshold! / maxVal));
      canvas.drawLine(
        Offset(leftPad, cy),
        Offset(leftPad + chartW, cy),
        Paint()
          ..color = AppTheme.error.withValues(alpha: 0.45)
          ..strokeWidth = 1.0,
      );
    }

    // Etiquetas de tiempo en el eje X (inicio, medio, ahora)
    final xIndices = [0, points.length ~/ 2, points.length - 1];
    for (final idx in xIndices) {
      String shortTs =
          points[idx]['time_label']?.toString() ??
          points[idx]['label']?.toString() ??
          '';
      if (shortTs.isEmpty && points[idx]['timestamp'] != null) {
        final tsVal = points[idx]['timestamp'];
        if (tsVal is num) {
          final dt = DateTime.fromMillisecondsSinceEpoch(tsVal.toInt() * 1000);
          shortTs =
              '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
        } else {
          final rawStr = tsVal.toString();
          shortTs = rawStr.length >= 16 ? rawStr.substring(11, 16) : rawStr;
        }
      }
      if (shortTs.isEmpty && idx == points.length - 1) {
        shortTs = 'Ahora';
      }
      if (shortTs.isEmpty) continue;
      final x = leftPad + (idx / (points.length - 1)) * chartW;
      final tp = TextPainter(
        text: TextSpan(
          text: shortTs,
          style: const TextStyle(
            fontSize: 8.0,
            fontFamily: 'monospace',
            color: AppTheme.textMuted,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(
          (x - tp.width / 2).clamp(leftPad, leftPad + chartW - tp.width),
          topPad + chartH + 2,
        ),
      );
    }

    final chartRect = Rect.fromLTWH(leftPad, topPad, chartW, chartH);
    _drawSmoothSeries(canvas, chartRect, keyA, colorA, maxVal);
    if (keyB != null && colorB != null) {
      _drawSmoothSeries(canvas, chartRect, keyB!, colorB!, maxVal);
    }
  }

  void _drawSmoothSeries(
    Canvas canvas,
    Rect rect,
    String key,
    Color color,
    double maxVal,
  ) {
    final coords = <Offset>[];
    for (int i = 0; i < points.length; i++) {
      final v = (points[i][key] as num?)?.toDouble() ?? 0.0;
      final x = rect.left + (i / (points.length - 1)) * rect.width;
      final y =
          rect.bottom - ((v / maxVal).clamp(0.0, 1.0) * rect.height);
      coords.add(Offset(x, y));
    }
    if (coords.length < 2) return;

    final path = Path()..moveTo(coords.first.dx, coords.first.dy);
    for (int i = 0; i < coords.length - 1; i++) {
      final p0 = coords[i];
      final p1 = coords[i + 1];
      final midX = (p0.dx + p1.dx) / 2;
      path.cubicTo(midX, p0.dy, midX, p1.dy, p1.dx, p1.dy);
    }

    final fillPath = Path.from(path)
      ..lineTo(coords.last.dx, rect.bottom)
      ..lineTo(coords.first.dx, rect.bottom)
      ..close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: 0.34),
          color.withValues(alpha: 0.08),
          color.withValues(alpha: 0.01),
        ],
      ).createShader(rect);
    canvas.drawPath(fillPath, fillPaint);

    final strokePaint = Paint()
      ..color = color
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawPath(path, strokePaint);

    // Punto brillante en el valor actual (última muestra)
    final lastPt = coords.last;
    canvas.drawCircle(
      lastPt,
      4.5,
      Paint()..color = color.withValues(alpha: 0.28),
    );
    canvas.drawCircle(lastPt, 2.5, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _PrometheusSeriesChartPainter oldDelegate) =>
      true;
}

class _TechStackEdgesPainter extends CustomPainter {
  final List<Map<String, dynamic>> nodes;
  final List<Map<String, dynamic>> edges;
  final Map<int, Offset> nodePositions;
  final Map<int, Size> nodeSizes;
  final Size canvasSize;
  final int? liveSourceNodeId;
  final String? liveSourceSide;
  final Offset? liveMousePos;
  final int? hoveredTargetNodeId;
  final String? hoveredTargetSide;

  _TechStackEdgesPainter({
    required this.nodes,
    required this.edges,
    this.nodePositions = const {},
    this.nodeSizes = const {},
    required this.canvasSize,
    this.liveSourceNodeId,
    this.liveSourceSide,
    this.liveMousePos,
    this.hoveredTargetNodeId,
    this.hoveredTargetSide,
  });

  Offset _sidePoint(Rect r, String? side) {
    switch (side) {
      case 'top':
        return r.topCenter;
      case 'bottom':
        return r.bottomCenter;
      case 'left':
        return r.centerLeft;
      case 'right':
        return r.centerRight;
      default:
        return r.centerRight;
    }
  }

  void _drawCurvedArrow(
    Canvas canvas,
    Offset start,
    Offset end,
    Color color, {
    double strokeWidth = 2.3,
  }) {
    final path = Path()..moveTo(start.dx, start.dy);
    final dx = end.dx - start.dx;
    final dy = end.dy - start.dy;
    if (dx.abs() >= dy.abs()) {
      path.cubicTo(
        start.dx + dx * 0.45,
        start.dy,
        start.dx + dx * 0.55,
        end.dy,
        end.dx,
        end.dy,
      );
    } else {
      path.cubicTo(
        start.dx,
        start.dy + dy * 0.45,
        end.dx,
        start.dy + dy * 0.55,
        end.dx,
        end.dy,
      );
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = strokeWidth
        ..style = PaintingStyle.stroke,
    );

    final angle = math.atan2(dy, dx);
    const arrowLen = 9.5;
    const arrowAng = 0.48;
    final p1 = Offset(
      end.dx - arrowLen * math.cos(angle - arrowAng),
      end.dy - arrowLen * math.sin(angle - arrowAng),
    );
    final p2 = Offset(
      end.dx - arrowLen * math.cos(angle + arrowAng),
      end.dy - arrowLen * math.sin(angle + arrowAng),
    );
    final arrowPath = Path()
      ..moveTo(end.dx, end.dy)
      ..lineTo(p1.dx, p1.dy)
      ..lineTo(p2.dx, p2.dy)
      ..close();
    canvas.drawPath(
      arrowPath,
      Paint()
        ..color = color
        ..style = PaintingStyle.fill,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final nodesById = <int, Map<String, dynamic>>{};
    for (final n in nodes) {
      nodesById[n['id'] as int] = n;
    }

    for (final e in edges) {
      final src = nodesById[e['source_node_id'] as int];
      final dst = nodesById[e['target_node_id'] as int];
      if (src == null || dst == null) continue;

      final srcId = src['id'] as int;
      final dstId = dst['id'] as int;
      final sPos =
          nodePositions[srcId] ??
          Offset(
            ((src['pos_x'] as num?)?.toDouble() ?? 0.2),
            ((src['pos_y'] as num?)?.toDouble() ?? 0.3),
          );
      final dPos =
          nodePositions[dstId] ??
          Offset(
            ((dst['pos_x'] as num?)?.toDouble() ?? 0.5),
            ((dst['pos_y'] as num?)?.toDouble() ?? 0.3),
          );
      final sSize =
          nodeSizes[srcId] ??
          Size(
            (src['width_px'] as num?)?.toDouble() ?? 220.0,
            (src['height_px'] as num?)?.toDouble() ?? 124.0,
          );
      final dSize =
          nodeSizes[dstId] ??
          Size(
            (dst['width_px'] as num?)?.toDouble() ?? 220.0,
            (dst['height_px'] as num?)?.toDouble() ?? 124.0,
          );

      final sRect = Rect.fromLTWH(
        sPos.dx * canvasSize.width,
        sPos.dy * canvasSize.height,
        sSize.width,
        sSize.height,
      );
      final dRect = Rect.fromLTWH(
        dPos.dx * canvasSize.width,
        dPos.dy * canvasSize.height,
        dSize.width,
        dSize.height,
      );

      Offset start = sRect.centerRight;
      Offset end = dRect.centerLeft;
      final edgeNotes = (e['notes'] as String?) ?? '';
      if (edgeNotes.startsWith('side:') && edgeNotes.contains('->')) {
        final parts = edgeNotes.substring(5).split('->');
        if (parts.length == 2) {
          start = _sidePoint(sRect, parts[0].trim());
          end = _sidePoint(dRect, parts[1].trim());
        }
      } else {
        final sCandidates = [
          sRect.centerRight,
          sRect.centerLeft,
          sRect.bottomCenter,
          sRect.topCenter,
        ];
        final dCandidates = [
          dRect.centerLeft,
          dRect.centerRight,
          dRect.topCenter,
          dRect.bottomCenter,
        ];

        double bestDist = double.infinity;
        for (final sc in sCandidates) {
          for (final dc in dCandidates) {
            final dist = (sc - dc).distanceSquared;
            if (dist < bestDist) {
              bestDist = dist;
              start = sc;
              end = dc;
            }
          }
        }
      }

      final isDown = (e['status'] as String?) == 'DOWN';
      final color = isDown ? AppTheme.error : AppTheme.accentCyan;
      _drawCurvedArrow(canvas, start, end, color);
    }

    // Si hay un cuadrado lateral seleccionado, dibujamos la flecha de unión en vivo hacia el ratón
    if (liveSourceNodeId != null && liveMousePos != null) {
      final src = nodesById[liveSourceNodeId!];
      if (src != null) {
        final sPos =
            nodePositions[liveSourceNodeId!] ??
            Offset(
              ((src['pos_x'] as num?)?.toDouble() ?? 0.2),
              ((src['pos_y'] as num?)?.toDouble() ?? 0.3),
            );
        final sSize =
            nodeSizes[liveSourceNodeId!] ??
            Size(
              (src['width_px'] as num?)?.toDouble() ?? 220.0,
              (src['height_px'] as num?)?.toDouble() ?? 124.0,
            );
        final sRect = Rect.fromLTWH(
          sPos.dx * canvasSize.width,
          sPos.dy * canvasSize.height,
          sSize.width,
          sSize.height,
        );
        final start = _sidePoint(sRect, liveSourceSide);
        Offset end = liveMousePos!;
        if (hoveredTargetNodeId != null &&
            hoveredTargetNodeId != liveSourceNodeId &&
            hoveredTargetSide != null) {
          final dst = nodesById[hoveredTargetNodeId!];
          if (dst != null) {
            final dPos =
                nodePositions[hoveredTargetNodeId!] ??
                Offset(
                  ((dst['pos_x'] as num?)?.toDouble() ?? 0.5),
                  ((dst['pos_y'] as num?)?.toDouble() ?? 0.3),
                );
            final dSize =
                nodeSizes[hoveredTargetNodeId!] ??
                Size(
                  (dst['width_px'] as num?)?.toDouble() ?? 220.0,
                  (dst['height_px'] as num?)?.toDouble() ?? 124.0,
                );
            final dRect = Rect.fromLTWH(
              dPos.dx * canvasSize.width,
              dPos.dy * canvasSize.height,
              dSize.width,
              dSize.height,
            );
            end = _sidePoint(dRect, hoveredTargetSide);
          }
        }
        _drawCurvedArrow(
          canvas,
          start,
          end,
          AppTheme.warning,
          strokeWidth: 2.6,
        );
        canvas.drawCircle(
          start,
          4.5,
          Paint()..color = AppTheme.warning,
        );
        canvas.drawCircle(
          end,
          3.5,
          Paint()..color = AppTheme.warning,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TechStackEdgesPainter oldDelegate) => true;
}

class _MiniSparklinePainter extends CustomPainter {
  final List<double> values;
  final Color color;

  _MiniSparklinePainter({required this.values, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    double maxV = 1.0;
    for (final v in values) {
      if (v > maxV) maxV = v;
    }
    maxV = math.max(maxV * 1.15, 10.0);

    final pts = <Offset>[];
    for (int i = 0; i < values.length; i++) {
      final x = (i / (values.length - 1)) * size.width;
      final y =
          size.height - ((values[i] / maxV).clamp(0.0, 1.0) * size.height);
      pts.add(Offset(x, y));
    }

    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (int i = 0; i < pts.length - 1; i++) {
      final midX = (pts[i].dx + pts[i + 1].dx) / 2;
      path.cubicTo(midX, pts[i].dy, midX, pts[i + 1].dy, pts[i + 1].dx, pts[i + 1].dy);
    }

    final fillPath = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();

    canvas.drawPath(
      fillPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: 0.28),
            color.withValues(alpha: 0.02),
          ],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 1.8
        ..style = PaintingStyle.stroke,
    );
    canvas.drawCircle(pts.last, 2.2, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _MiniSparklinePainter oldDelegate) => true;
}

