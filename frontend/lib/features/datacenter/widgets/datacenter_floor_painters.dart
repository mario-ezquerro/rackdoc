part of '../datacenter_floor_view.dart';

/// Modelos auxiliares de catálogo/deshacer y `CustomPainter`s de conexiones
/// inter-rack y cuadrícula arquitectónica del plano de planta.
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
    this.pinColor = AppPalette.slate900,
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
  final List<Map<String, dynamic>> interRackLinks;
  final Map<int, Offset> devicePositions;
  final int? selectedDeviceId;
  final int? selectedLinkedRackId;
  final int? selectedLinkedOutletId;
  final Set<int> selectedRackIds;

  _FloorConnectionsPainter({
    required this.racks,
    required this.rackPositions,
    required this.rackSizes,
    required this.floorDevices,
    required this.interRackLinks,
    required this.devicePositions,
    required this.selectedDeviceId,
    required this.selectedLinkedRackId,
    required this.selectedLinkedOutletId,
    required this.selectedRackIds,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rackCenters = <int, Offset>{};
    final rackRects = <int, Rect>{};
    for (final rk in racks) {
      final norm = rackPositions[rk.id] ?? Offset(rk.posX, rk.posY);
      final sz = rackSizes[rk.id] ?? Size(rk.widthPx, rk.depthPx);
      final leftPx = (norm.dx * size.width)
          .clamp(8.0, (size.width - sz.width - 8.0).clamp(8.0, size.width));
      final topPx = (norm.dy * size.height)
          .clamp(8.0, (size.height - sz.height - 8.0).clamp(8.0, size.height));
      rackRects[rk.id] = Rect.fromLTWH(leftPx, topPx, sz.width, sz.height);
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

    // 0A. Acometidas Exteriores conectadas en cada Rack (Eléctrica ⚡, Fibra 🌐, Ethernet 🔌)
    for (final rk in racks) {
      final rRect = rackRects[rk.id];
      if (rRect == null) continue;
      final stubs = <({String label, Color color})>[
        if (rk.powerCablesCount > 0)
          (
            label: '⚡${rk.powerCablesCount}',
            color: AppPalette.orange600,
          ),
        if (rk.fiberCablesCount > 0)
          (
            label: '🌐${rk.fiberCablesCount}',
            color: AppPalette.cyan500,
          ),
        if (rk.ethCablesCount > 0)
          (
            label: '🔌${rk.ethCablesCount}',
            color: AppPalette.blue600,
          ),
      ];
      if (stubs.isEmpty) continue;

      final placeAbove = rRect.top > 36;
      final count = stubs.length;
      for (int i = 0; i < count; i++) {
        final st = stubs[i];
        final frac = (i + 1) / (count + 1);
        final anchorX = rRect.left + rRect.width * frac;
        final anchorY = placeAbove ? rRect.top : rRect.bottom;
        final outerY = placeAbove ? anchorY - 22.0 : anchorY + 22.0;

        final linePaint = Paint()
          ..color = st.color
          ..strokeWidth = 2.2
          ..style = PaintingStyle.stroke;
        canvas.drawLine(
          Offset(anchorX, outerY),
          Offset(anchorX, anchorY),
          linePaint,
        );

        final dotPaint = Paint()
          ..color = st.color
          ..style = PaintingStyle.fill;
        canvas.drawCircle(Offset(anchorX, outerY), 4.0, dotPaint);
        _drawLabelPill(
          canvas,
          Offset(anchorX, placeAbove ? outerY - 10 : outerY + 10),
          st.label,
          bgColor: const Color(0xEE0F172A),
          borderColor: st.color,
          textColor: Colors.white,
          fontSize: 8.5,
        );
      }
    }

    // 0B. Enlaces Inter-Rack (Fibras, Ethernet o Eléctricas entre dos Racks de la misma planta o hacia otra planta)
    final sameFloorGroups = <String, List<Map<String, dynamic>>>{};
    final crossFloorGroups = <String, List<Map<String, dynamic>>>{};
    for (final lnk in interRackLinks) {
      final r1 = (lnk['source_rack_id'] as num?)?.toInt();
      final r2 = (lnk['target_rack_id'] as num?)?.toInt();
      final mg = (lnk['media_group'] ?? 'fiber').toString();
      if (r1 == null || r2 == null) continue;
      if (rackCenters.containsKey(r1) && rackCenters.containsKey(r2)) {
        final a = r1 < r2 ? r1 : r2;
        final b = r1 < r2 ? r2 : r1;
        final key = '${a}_${b}_$mg';
        sameFloorGroups.putIfAbsent(key, () => []).add(lnk);
      } else {
        final localId = rackCenters.containsKey(r1) ? r1 : r2;
        final remoteCode = rackCenters.containsKey(r1)
            ? (lnk['target_rack_code'] ?? '').toString()
            : (lnk['source_rack_code'] ?? '').toString();
        final key = '${localId}_${remoteCode}_$mg';
        crossFloorGroups.putIfAbsent(key, () => []).add(lnk);
      }
    }

    int pairIndex = 0;
    for (final entry in sameFloorGroups.entries) {
      final items = entry.value;
      final first = items.first;
      final r1 = (first['source_rack_id'] as num).toInt();
      final r2 = (first['target_rack_id'] as num).toInt();
      final mg = (first['media_group'] ?? 'fiber').toString();
      final p1 = rackCenters[r1];
      final p2 = rackCenters[r2];
      if (p1 == null || p2 == null) continue;

      final dx = p2.dx - p1.dx;
      final dy = p2.dy - p1.dy;
      final dist = Offset(dx, dy).distance;
      if (dist <= 1.0) continue;
      final nx = -dy / dist;
      final ny = dx / dist;
      final offsetMag = (pairIndex % 3 - 1) * 8.0;
      pairIndex++;

      final sPt = Offset(p1.dx + nx * offsetMag, p1.dy + ny * offsetMag);
      final ePt = Offset(p2.dx + nx * offsetMag, p2.dy + ny * offsetMag);

      final Color lineColor = mg == 'fiber'
          ? AppPalette.cyan500
          : (mg == 'power'
              ? AppPalette.orange600
              : AppPalette.blue600);
      final isHighlighted =
          selectedRackIds.contains(r1) || selectedRackIds.contains(r2);

      // Halo exterior
      final haloPaint = Paint()
        ..color = lineColor.withValues(alpha: isHighlighted ? 0.35 : 0.20)
        ..strokeWidth = isHighlighted ? 7.0 : 5.0
        ..style = PaintingStyle.stroke;
      canvas.drawLine(sPt, ePt, haloPaint);

      // Línea principal Inter-Rack
      final mainPaint = Paint()
        ..color = lineColor
        ..strokeWidth = isHighlighted ? 3.2 : 2.4
        ..style = PaintingStyle.stroke;
      canvas.drawLine(sPt, ePt, mainPaint);

      // Píldora central con resumen del enlace Inter-Rack
      final mid = Offset((sPt.dx + ePt.dx) / 2, (sPt.dy + ePt.dy) / 2);
      final prefix = mg == 'fiber'
          ? '🌐 FIB'
          : (mg == 'power' ? '⚡ PWR' : '🔌 ETH');
      final portDetail = items.length == 1
          ? ' • ${first['source_device_code']}:${first['source_port_number']}↔${first['target_device_code']}:${first['target_port_number']}'
          : '';
      _drawLabelPill(
        canvas,
        mid,
        '$prefix x${items.length}$portDetail',
        bgColor: const Color(0xF20F172A),
        borderColor: lineColor,
        textColor: Colors.white,
        fontSize: 9.0,
      );
    }

    // Montantes / Bajantes hacia Racks de otra planta
    final perRackCrossOffset = <int, int>{};
    for (final entry in crossFloorGroups.entries) {
      final items = entry.value;
      final first = items.first;
      final r1 = (first['source_rack_id'] as num).toInt();
      final r2 = (first['target_rack_id'] as num).toInt();
      final localId = rackCenters.containsKey(r1) ? r1 : r2;
      final remoteCode = rackCenters.containsKey(r1)
          ? (first['target_rack_code'] ?? '').toString()
          : (first['source_rack_code'] ?? '').toString();
      final mg = (first['media_group'] ?? 'fiber').toString();
      final rRect = rackRects[localId];
      if (rRect == null) continue;

      final idx = perRackCrossOffset[localId] ?? 0;
      perRackCrossOffset[localId] = idx + 1;

      final Color lineColor = mg == 'fiber'
          ? AppPalette.cyan500
          : (mg == 'power'
              ? AppPalette.orange600
              : AppPalette.blue600);
      final startPt = Offset(rRect.right, rRect.top + 18.0 + idx * 18.0);
      final endPt = Offset(rRect.right + 28.0, rRect.top + 18.0 + idx * 18.0);

      final paint = Paint()
        ..color = lineColor
        ..strokeWidth = 2.2
        ..style = PaintingStyle.stroke;
      canvas.drawLine(startPt, endPt, paint);
      _drawLabelPill(
        canvas,
        Offset(endPt.dx + 34, endPt.dy),
        '↕ $remoteCode (${items.length}x ${mg == 'fiber' ? 'FIB' : mg.toUpperCase()})',
        bgColor: const Color(0xEE0F172A),
        borderColor: lineColor,
        textColor: Colors.white,
        fontSize: 8.5,
      );
    }

    // 1. Líneas naranjas discontinuas (Troncal: Rack -> Roseta Bi01 o Cámara/AP/Sensor directo)
    for (final d in floorDevices) {
      final isSel = selectedDeviceId == d.id;
      final rId = isSel ? selectedLinkedRackId : d.linkedRackId;
      final outId = isSel ? selectedLinkedOutletId : d.linkedOutletId;
      if (rId == null) continue;
      // Si el equipo ya va conectado a una roseta, el tramo al rack lo pinta la roseta
      if (outId != null && devCenters.containsKey(outId)) {
        continue;
      }
      final p1 = rackCenters[rId];
      final p2 = devCenters[d.id];
      if (p1 == null || p2 == null) continue;

      final isHighlighted = isSel || selectedRackIds.contains(rId);
      final paint = Paint()
        ..color = isHighlighted
            ? AppPalette.amber600
            : AppPalette.amber500.withValues(alpha: 0.78)
        ..strokeWidth = isHighlighted ? 2.4 : 1.5
        ..style = PaintingStyle.stroke;

      _drawDashedLine(canvas, p1, p2, paint, dashWidth: 6, dashSpace: 4);
    }

    // 2. Líneas azules continuas (Latiguillo de área de trabajo: Roseta Bi01 -> Desktop/Phone/Printer)
    for (final d in floorDevices) {
      final isSel = selectedDeviceId == d.id;
      final outId = isSel ? selectedLinkedOutletId : d.linkedOutletId;
      if (outId == null) continue;
      final p1 = devCenters[outId];
      final p2 = devCenters[d.id];
      if (p1 == null || p2 == null) continue;

      final isHighlighted = isSel || selectedDeviceId == outId;
      final paint = Paint()
        ..color = isHighlighted
            ? AppPalette.blue700
            : AppPalette.blue500.withValues(alpha: 0.85)
        ..strokeWidth = isHighlighted ? 2.5 : 1.7
        ..style = PaintingStyle.stroke;

      canvas.drawLine(p1, p2, paint);
    }
  }

  void _drawLabelPill(
    Canvas canvas,
    Offset center,
    String text, {
    required Color bgColor,
    required Color borderColor,
    required Color textColor,
    double fontSize = 8.5,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: textColor,
          fontSize: fontSize,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final rect = Rect.fromCenter(
      center: center,
      width: tp.width + 10,
      height: tp.height + 5,
    );
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(5));
    canvas.drawRRect(rrect, Paint()..color = bgColor);
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = borderColor
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke,
    );
    tp.paint(
      canvas,
      Offset(center.dx - tp.width / 2, center.dy - tp.height / 2),
    );
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
      ..color = AppPalette.slate100
      ..strokeWidth = 1.0;
    final majorPaint = Paint()
      ..color = AppPalette.slate200
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
