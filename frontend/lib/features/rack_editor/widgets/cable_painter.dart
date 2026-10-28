import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../models/datacenter_models.dart';

class ComputedCableRoute {
  final ConnectionModel connection;
  final Path path;
  final List<Offset> points;
  final Color color;
  final Offset? badgePosition;
  final String? badgeText;
  final bool isPassThrough;
  final bool isOutbound;

  ComputedCableRoute({
    required this.connection,
    required this.path,
    required this.points,
    required this.color,
    this.badgePosition,
    this.badgeText,
    required this.isPassThrough,
    required this.isOutbound,
  });
}

class CableGeometryBuilder {
  static Color parseHexColor(String hex, {Color fallback = const Color(0xFF2563EB)}) {
    final cleaned = hex.replaceAll('#', '').trim();
    if (cleaned.length == 6) {
      final val = int.tryParse('FF$cleaned', radix: 16);
      if (val != null) return Color(val);
    }
    return fallback;
  }

  /// Construye un Path con esquinas redondeadas a partir de una lista de puntos ortogonales.
  static Path buildRoundedOrthogonalPath(List<Offset> pts, {double radius = 6.0}) {
    final path = Path();
    if (pts.isEmpty) return path;
    path.moveTo(pts.first.dx, pts.first.dy);
    if (pts.length == 1) return path;
    if (pts.length == 2) {
      path.lineTo(pts.last.dx, pts.last.dy);
      return path;
    }

    for (int i = 1; i < pts.length - 1; i++) {
      final prev = pts[i - 1];
      final curr = pts[i];
      final next = pts[i + 1];

      final v1 = curr - prev;
      final v2 = next - curr;
      final len1 = v1.distance;
      final len2 = v2.distance;

      if (len1 < 0.5 || len2 < 0.5) {
        path.lineTo(curr.dx, curr.dy);
        continue;
      }

      final r = math.min(radius, math.min(len1 / 2.2, len2 / 2.2));
      final pStart = curr - (v1 / len1) * r;
      final pEnd = curr + (v2 / len2) * r;

      path.lineTo(pStart.dx, pStart.dy);
      path.quadraticBezierTo(curr.dx, curr.dy, pEnd.dx, pEnd.dy);
    }

    path.lineTo(pts.last.dx, pts.last.dy);
    return path;
  }

  /// Calcula la distancia mínima de un punto `p` a los segmentos de una polilínea `pts`.
  static double distanceToPolyline(Offset p, List<Offset> pts) {
    double minDist = double.infinity;
    for (int i = 0; i < pts.length - 1; i++) {
      final a = pts[i];
      final b = pts[i + 1];
      final ab = b - a;
      final lenSq = ab.dx * ab.dx + ab.dy * ab.dy;
      double t = 0.0;
      if (lenSq > 0.0001) {
        t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / lenSq;
        t = t.clamp(0.0, 1.0);
      }
      final proj = Offset(a.dx + t * ab.dx, a.dy + t * ab.dy);
      final d = (p - proj).distance;
      if (d < minDist) minDist = d;
    }
    return minDist;
  }

  static List<ComputedCableRoute> computeRoutes({
    required List<ConnectionModel> connections,
    required Map<int, Offset> portPositionsOnActiveFace,
    required String activeFace,
    required int currentRackId,
    required double leftChannelBaseX,
    required double rightChannelBaseX,
    double? backLeftChannelBaseX,
    double? backRightChannelBaseX,
    required Offset outboundAnchor,
    required String cableFilter,
  }) {
    final routes = <ComputedCableRoute>[];
    int leftLaneIdx = 0;
    int rightLaneIdx = 0;
    int centerBridgeLaneIdx = 0;
    int backLeftLaneIdx = 0;
    int backRightLaneIdx = 0;
    final usedFrontFlagYs = <double>[];
    final usedBackFlagYs = <double>[];

    final isDualView = activeFace == 'both' &&
        backLeftChannelBaseX != null &&
        backRightChannelBaseX != null;
    final dualSplitX = isDualView
        ? (rightChannelBaseX + backLeftChannelBaseX) / 2.0
        : double.infinity;

    for (int i = 0; i < connections.length; i++) {
      final conn = connections[i];
      if (cableFilter != 'all' && conn.categoryGroup != cableFilter) {
        continue;
      }

      final pSource = portPositionsOnActiveFace[conn.sourcePortId];
      final pTarget = portPositionsOnActiveFace[conn.targetPortId];

      // Si ni origen ni destino están en la cara activa del rack actual, no se dibuja en esta cara
      if (pSource == null && pTarget == null) {
        continue;
      }

      final color = parseHexColor(conn.colorHex);
      final frontCenterX = (leftChannelBaseX + rightChannelBaseX) / 2.0;

      // Caso 1: Ambos puertos visibles en el lienzo actual (ya sea en la misma cara o entre Front y Back en vista Dual)
      if (pSource != null && pTarget != null) {
        final dyDiff = (pTarget.dy - pSource.dy).abs();
        final dxDiff = (pTarget.dx - pSource.dx).abs();

        // Subcaso 1A (Vista Dual Front+Back): Cable que pasa de DELANTE (Front) a DETRÁS (Back) dentro del mismo Rack
        final srcInFront = isDualView && pSource.dx < dualSplitX;
        final tgtInFront = isDualView && pTarget.dx < dualSplitX;
        final isExternalEnd =
            conn.sourceInfo.face == 'external' || conn.targetInfo.face == 'external';

        if (isDualView && (srcInFront != tgtInFront) && !isExternalEnd) {
          final laneIdx = centerBridgeLaneIdx++;
          final bridgeX = dualSplitX + ((laneIdx % 7) - 3) * 4.2;
          final stub1 = ((i % 3) - 1) * 2.5 + 8.5;
          final stub2 = (((i + 1) % 3) - 1) * 2.5 + 8.5;
          final y1 = pSource.dy + (pTarget.dy >= pSource.dy ? stub1 : -stub1);
          final y2 = pTarget.dy + (pSource.dy >= pTarget.dy ? stub2 : -stub2);

          final pts = <Offset>[
            pSource,
            Offset(pSource.dx, y1),
            Offset(bridgeX, y1),
            Offset(bridgeX, y2),
            Offset(pTarget.dx, y2),
            pTarget,
          ];
          final midBridgeY = (y1 + y2) / 2.0;
          routes.add(
            ComputedCableRoute(
              connection: conn,
              path: buildRoundedOrthogonalPath(pts, radius: 6.0),
              points: pts,
              color: color,
              badgePosition: Offset(bridgeX - 24, midBridgeY),
              badgeText: '⇄ F↔B',
              isPassThrough: true,
              isOutbound: false,
            ),
          );
          continue;
        }

        // Si es un latiguillo corto entre unidades U adyacentes (como Patchbox/PatchPanel <-> Switch),
        // trazar puente directo vertical limpio igual que en la vista técnica de referencia.
        if (conn.routingChannel == 'auto' &&
            dyDiff <= 56.0 &&
            dxDiff <= 110.0) {
          final midY = (pSource.dy + pTarget.dy) / 2.0 + ((i % 3) - 1) * 2.2;
          final directPts = <Offset>[
            pSource,
            Offset(pSource.dx, midY),
            Offset(pTarget.dx, midY),
            pTarget,
          ];
          routes.add(
            ComputedCableRoute(
              connection: conn,
              path: buildRoundedOrthogonalPath(directPts, radius: 4.5),
              points: directPts,
              color: color,
              isPassThrough: false,
              isOutbound: false,
            ),
          );
          continue;
        }

        final bothOnBackInDual =
            isDualView && !srcInFront && !tgtInFront && !isExternalEnd;
        final activeLeftBase =
            bothOnBackInDual ? backLeftChannelBaseX : leftChannelBaseX;
        final activeRightBase =
            (bothOnBackInDual || (isDualView && isExternalEnd))
                ? backRightChannelBaseX
                : rightChannelBaseX;
        final activeCenterX = (activeLeftBase + activeRightBase) / 2.0;

        String side = conn.routingChannel;
        if (side != 'left' && side != 'right') {
          final avgX = (pSource.dx + pTarget.dx) / 2.0;
          side = (avgX <= activeCenterX) ? 'left' : 'right';
        }

        final int laneIndex;
        if (bothOnBackInDual) {
          laneIndex = (side == 'left') ? (backLeftLaneIdx++) : (backRightLaneIdx++);
        } else {
          laneIndex = (side == 'left') ? (leftLaneIdx++) : (rightLaneIdx++);
        }
        final laneOffset = (laneIndex % 7) * 3.2;
        final channelX = (side == 'left')
            ? (activeLeftBase - laneOffset)
            : (activeRightBase + laneOffset);

        final stub1 = ((i % 3) - 1) * 2.5 + 8.5;
        final stub2 = (((i + 1) % 3) - 1) * 2.5 + 8.5;
        final y1 = pSource.dy + (pTarget.dy >= pSource.dy ? stub1 : -stub1);
        final y2 = pTarget.dy + (pSource.dy >= pTarget.dy ? stub2 : -stub2);

        final pts = <Offset>[
          pSource,
          Offset(pSource.dx, y1),
          Offset(channelX, y1),
          Offset(channelX, y2),
          Offset(pTarget.dx, y2),
          pTarget,
        ];

        routes.add(
          ComputedCableRoute(
            connection: conn,
            path: buildRoundedOrthogonalPath(pts, radius: 6.0),
            points: pts,
            color: color,
            isPassThrough: false,
            isOutbound: false,
          ),
        );
        continue;
      }

      // Caso 2: Conexión OUTBOUND hacia otro rack distinto -> Banderola "Cross-Connect" lateral a la altura del equipo (Opción 3)
      final activePoint = pSource ?? pTarget!;
      final otherInfo = (pSource != null) ? conn.targetInfo : conn.sourceInfo;

      if (conn.isOutbound || otherInfo.rackId != currentRackId) {
        final onBackInDual = isDualView && activePoint.dx >= dualSplitX;
        final baseRight = onBackInDual ? backRightChannelBaseX : rightChannelBaseX;
        final laneIndex = rightLaneIdx++;
        final channelX = baseRight + 10.0 + (laneIndex % 4) * 3.5;
        final flagPinX = baseRight + 28.0;
        final yStub = activePoint.dy + 7.0;

        // Evitar solapamiento vertical si hay varias banderolas Cross-Connect en la misma U
        final usedYs = onBackInDual ? usedBackFlagYs : usedFrontFlagYs;
        double flagY = activePoint.dy;
        int attempt = 0;
        while (usedYs.any((y) => (y - flagY).abs() < 24.0) && attempt < 16) {
          attempt++;
          flagY = activePoint.dy +
              (attempt.isOdd ? 1 : -1) * ((attempt + 1) ~/ 2) * 25.0;
        }
        usedYs.add(flagY);

        final pts = <Offset>[
          activePoint,
          Offset(activePoint.dx, yStub),
          Offset(channelX, yStub),
          Offset(channelX, flagY),
          Offset(flagPinX, flagY),
        ];

        routes.add(
          ComputedCableRoute(
            connection: conn,
            path: buildRoundedOrthogonalPath(pts, radius: 5.5),
            points: pts,
            color: color,
            badgePosition: Offset(flagPinX, flagY),
            badgeText:
                '➔ ${otherInfo.rackCode} • U${otherInfo.startU} ${otherInfo.deviceCode}:${otherInfo.portNumber}',
            isPassThrough: false,
            isOutbound: true,
          ),
        );
        continue;
      }

      // Caso 3: Conexión PASS-THROUGH (cruza entre la cara FRONT y la cara BACK del mismo rack en vista simple)
      final useLeft = activePoint.dx <= frontCenterX;
      final laneIndex = useLeft ? (leftLaneIdx++) : (rightLaneIdx++);
      final channelX = useLeft
          ? (leftChannelBaseX - 8.0 - (laneIndex % 6) * 4.0)
          : (rightChannelBaseX + 8.0 + (laneIndex % 6) * 4.0);
      final passPoint = Offset(channelX, activePoint.dy + 12.0);

      final pts = <Offset>[
        activePoint,
        Offset(activePoint.dx, activePoint.dy + 12.0),
        passPoint,
      ];

      final targetFaceLabel = otherInfo.face.toUpperCase();
      routes.add(
        ComputedCableRoute(
          connection: conn,
          path: buildRoundedOrthogonalPath(pts, radius: 5.5),
          points: pts,
          color: color,
          badgePosition: passPoint,
          badgeText: '⇄ $targetFaceLabel (${otherInfo.deviceCode}:${otherInfo.portNumber})',
          isPassThrough: true,
          isOutbound: false,
        ),
      );
    }

    return routes;
  }
}

class RackCablePainter extends CustomPainter {
  final List<ComputedCableRoute> routes;
  final int? selectedConnectionId;
  final int? hoveredConnectionId;
  final Offset? activeSourcePortOffset;
  final Offset? cursorPosition;

  RackCablePainter({
    required this.routes,
    this.selectedConnectionId,
    this.hoveredConnectionId,
    this.activeSourcePortOffset,
    this.cursorPosition,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final hasFocus = selectedConnectionId != null || hoveredConnectionId != null;

    for (final route in routes) {
      final isSelected = route.connection.id == selectedConnectionId;
      final isHovered = route.connection.id == hoveredConnectionId;
      final isHighlighted = isSelected || isHovered;

      double opacity = 0.88;
      if (hasFocus && !isHighlighted) {
        opacity = 0.22;
      } else if (isHighlighted) {
        opacity = 1.0;
      }

      double strokeWidth = 2.2;
      if (route.connection.categoryGroup == 'power') {
        strokeWidth = 2.8;
      }
      if (isHighlighted) {
        strokeWidth += 1.6;
      }

      if (isHighlighted) {
        final glowPaint = Paint()
          ..color = route.color.withValues(alpha: 0.28)
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth + 5.0
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
        canvas.drawPath(route.path, glowPaint);
      }

      final paint = Paint()
        ..color = route.color.withValues(alpha: opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;

      canvas.drawPath(route.path, paint);

      // Puntos de anclaje en los extremos del cable
      final capPaint = Paint()
        ..color = route.color.withValues(alpha: opacity)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(route.points.first, isHighlighted ? 4.2 : 3.0, capPaint);
      canvas.drawCircle(route.points.last, isHighlighted ? 4.2 : 3.0, capPaint);

      // Etiqueta visual si es PASS-THROUGH (cruza a la otra cara Front/Back)
      if (route.isPassThrough && route.badgePosition != null && route.badgeText != null) {
        _drawBadge(
          canvas,
          route.badgePosition!,
          route.badgeText!,
          route.color.withValues(alpha: math.max(opacity, 0.75)),
          isHighlighted,
        );
      }
    }

    // Línea interactiva mientras el usuario está tirando un nuevo cable de puerto a puerto
    if (activeSourcePortOffset != null && cursorPosition != null) {
      final p1 = activeSourcePortOffset!;
      final p2 = cursorPosition!;
      final previewPts = <Offset>[
        p1,
        Offset(p1.dx, p1.dy + 12),
        Offset(p2.dx, p1.dy + 12),
        p2,
      ];
      final previewPath = CableGeometryBuilder.buildRoundedOrthogonalPath(
        previewPts,
        radius: 6.0,
      );
      final previewPaint = Paint()
        ..color = const Color(0xFF2563EB)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(previewPath, previewPaint);
      canvas.drawCircle(p1, 4.5, Paint()..color = const Color(0xFF2563EB));
      canvas.drawCircle(p2, 4.5, Paint()..color = const Color(0xFF10B981));
    }
  }

  void _drawBadge(
    Canvas canvas,
    Offset pos,
    String text,
    Color bgColor,
    bool isHighlighted,
  ) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.white,
          fontSize: isHighlighted ? 10.0 : 8.5,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final rect = Rect.fromCenter(
      center: pos,
      width: textPainter.width + 10,
      height: textPainter.height + 5,
    );
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(4));
    canvas.drawRRect(rrect, Paint()..color = bgColor);
    textPainter.paint(
      canvas,
      Offset(rect.left + 5, rect.top + 2.5),
    );
  }

  @override
  bool shouldRepaint(covariant RackCablePainter oldDelegate) {
    return true;
  }
}
