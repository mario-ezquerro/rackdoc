part of '../rack_editor_view.dart';

/// Pintor técnico vectorial de bocas RJ45, jaulas SFP+, acopladores de fibra,
/// casetes PATCHBOX y modelos de deshacer (`_RackUndoAction`).
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
          color: active ? AppPalette.slate900 : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: active ? Colors.white : AppPalette.slate600,
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
            color: active ? Colors.white : AppPalette.slate600,
          ),
        ),
      ),
    );
  }
}

enum _TechPortKind {
  rj45,
  patchboxCassette,
  sfpCage,
  fiberCoupler,
}

class _TechnicalPortPainter extends CustomPainter {
  final _TechPortKind kind;
  final bool isConnected;
  final bool isPending;
  final Color color;
  final Color borderColor;
  final bool latchDown;
  final String? label;

  const _TechnicalPortPainter({
    required this.kind,
    required this.isConnected,
    required this.isPending,
    required this.color,
    required this.borderColor,
    this.latchDown = false,
    this.label,
  });

  @override
  void paint(Canvas canvas, Size size) {
    switch (kind) {
      case _TechPortKind.rj45:
        _paintRj45(canvas, Offset.zero & size);
        break;
      case _TechPortKind.patchboxCassette:
        _paintPatchboxCassette(canvas, size);
        break;
      case _TechPortKind.sfpCage:
        _paintSfpCage(canvas, Offset.zero & size);
        break;
      case _TechPortKind.fiberCoupler:
        _paintFiberCoupler(canvas, Offset.zero & size);
        break;
    }
  }

  /// Dibuja la silueta técnica escalonada 8P8C de una boca RJ45 ("ETS"):
  /// - Marco exterior metálico/plástico fino
  /// - Cavidad interior escalonada (T invertida) con muesca de pestaña
  /// - Si está libre: interior oscuro (`#0F172A`) con 2 puntos blancos superiores de contacto/guía
  /// - Si está conectado: relleno del color del latiguillo (`#2563EB`) con lengüeta interior clara (`#93C5FD`)
  void _paintRj45(Canvas canvas, Rect rect) {
    final outerRRect = RRect.fromRectAndRadius(
      rect,
      const Radius.circular(1.2),
    );
    // Collarín técnico exterior
    canvas.drawRRect(
      outerRRect,
      Paint()
        ..color = (isConnected || isPending)
            ? color.withValues(alpha: 0.14)
            : AppPalette.slate50
        ..style = PaintingStyle.fill,
    );
    canvas.drawRRect(
      outerRRect,
      Paint()
        ..color = (isConnected || isPending)
            ? borderColor
            : AppPalette.slate500
        ..style = PaintingStyle.stroke
        ..strokeWidth = (isConnected || isPending) ? 1.0 : 0.75,
    );

    // Silueta escalonada 8P8C dentro del collarín
    final left = rect.left + 1.2;
    final right = rect.right - 1.2;
    final top = rect.top + 1.0;
    final bottom = rect.bottom - 1.0;
    final w = right - left;
    final tabW = (w * 0.44).clamp(3.2, 5.0);
    final tabLeft = left + (w - tabW) / 2;
    final tabRight = tabLeft + tabW;
    const stepH = 1.65;

    final path = Path();
    if (!latchDown) {
      // Muesca de pestaña en la parte superior
      path.moveTo(left, top + stepH);
      path.lineTo(tabLeft, top + stepH);
      path.lineTo(tabLeft, top);
      path.lineTo(tabRight, top);
      path.lineTo(tabRight, top + stepH);
      path.lineTo(right, top + stepH);
      path.lineTo(right, bottom);
      path.lineTo(left, bottom);
      path.close();
    } else {
      // Muesca de pestaña en la parte inferior (segunda fila de switches)
      path.moveTo(left, top);
      path.lineTo(right, top);
      path.lineTo(right, bottom - stepH);
      path.lineTo(tabRight, bottom - stepH);
      path.lineTo(tabRight, bottom);
      path.lineTo(tabLeft, bottom);
      path.lineTo(tabLeft, bottom - stepH);
      path.lineTo(left, bottom - stepH);
      path.close();
    }

    canvas.drawPath(
      path,
      Paint()
        ..color = (isConnected || isPending) ? color : AppPalette.slate900
        ..style = PaintingStyle.fill,
    );

    if (isConnected || isPending) {
      // Reflejo claro del clip del conector macho RJ45 insertado
      final clipRect = Rect.fromLTWH(
        tabLeft + 0.5,
        latchDown ? (bottom - stepH - 1.8) : (top + 0.8),
        tabW - 1.0,
        2.2,
      );
      canvas.drawRect(
        clipRect,
        Paint()..color = Colors.white.withValues(alpha: 0.78),
      );
    } else {
      // Dos destellos blancos superiores en las esquinas de la cavidad 8P8C (como en la imagen de referencia)
      final dotPaint = Paint()..color = AppPalette.slate100;
      final dotY = latchDown ? (bottom - stepH - 1.8) : (top + stepH + 0.55);
      canvas.drawRect(Rect.fromLTWH(left + 0.8, dotY, 1.35, 1.35), dotPaint);
      canvas.drawRect(
        Rect.fromLTWH(right - 2.15, dotY, 1.35, 1.35),
        dotPaint,
      );
    }
  }

  /// Dibuja un módulo casete vertical completo de `PATCHBOX` (`PBX01..03`):
  /// - Carcasa vertical blanca con borde gris/azul
  /// - Pestaña/clip superior coloreado
  /// - Número de casete (`1..24`) en la mitad superior
  /// - Boca RJ45 8P8C escalonada en la mitad inferior
  void _paintPatchboxCassette(Canvas canvas, Size size) {
    final outerRect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      outerRect,
      const Radius.circular(1.5),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = (isConnected || isPending)
            ? borderColor
            : AppPalette.slate400
        ..style = PaintingStyle.stroke
        ..strokeWidth = (isConnected || isPending) ? 1.15 : 0.8,
    );

    // Clip / liberador superior del casete PATCHBOX
    final clipRect = Rect.fromLTWH(2.2, 1.6, size.width - 4.4, 3.0);
    canvas.drawRRect(
      RRect.fromRectAndRadius(clipRect, const Radius.circular(0.8)),
      Paint()
        ..color = (isConnected || isPending)
            ? color
            : AppPalette.slate600,
    );

    // Número del casete (1..24) en el centro
    if (label != null && label!.isNotEmpty) {
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            fontSize: 6.2,
            height: 1.0,
            fontWeight: FontWeight.w800,
            color: (isConnected || isPending) ? color : AppPalette.slate900,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width);
      tp.paint(
        canvas,
        Offset((size.width - tp.width) / 2, 6.4),
      );
    }

    // Boca RJ45 escalonada en la parte inferior del casete
    const jackW = 11.4;
    const jackH = 9.2;
    final jackRect = Rect.fromLTWH(
      (size.width - jackW) / 2,
      size.height - jackH - 2.2,
      jackW,
      jackH,
    );
    _paintRj45(canvas, jackRect);
  }

  /// Dibuja una jaula óptica SFP / SFP+ (`RT01` 9..12, `SW01..03` 1..4):
  /// - Marco rectangular blanco con borde oscuro o azul
  /// - Doble ranura horizontal interna de transceptor (`[=]`)
  void _paintSfpCage(Canvas canvas, Rect rect) {
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(1.0));
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );
    final strokeColor = (isConnected || isPending)
        ? borderColor
        : AppPalette.slate700;
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = strokeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = (isConnected || isPending) ? 1.3 : 1.0,
    );

    // Dos ranuras horizontales internas de guía óptica [=]
    final innerColor = (isConnected || isPending)
        ? color
        : AppPalette.slate600;
    final slotW = rect.width - 4.4;
    final topSlot = Rect.fromLTWH(rect.left + 2.2, rect.top + 2.1, slotW, 1.4);
    final bottomSlot = Rect.fromLTWH(
      rect.left + 2.2,
      rect.bottom - 3.5,
      slotW,
      1.4,
    );
    canvas.drawRect(topSlot, Paint()..color = innerColor);
    canvas.drawRect(bottomSlot, Paint()..color = innerColor);
  }

  /// Dibuja un acoplador de fibra óptica LC/SC en bandejas de fibra (`FI-01`):
  /// - Libre: cuadrado blanco hueco con borde técnico oscuro (`#334155`)
  /// - Conectado (como boca 23 de `FI-01`): cuadrado blanco con marco exterior azul y núcleo dúplex azul interior (`[▣]`)
  void _paintFiberCoupler(Canvas canvas, Rect rect) {
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(1.0));
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );
    final strokeColor = (isConnected || isPending)
        ? borderColor
        : AppPalette.slate700;
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = strokeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = (isConnected || isPending) ? 1.35 : 1.1,
    );

    if (isConnected || isPending) {
      // Núcleo óptico interior azul [▣]
      final coreRect = rect.deflate(2.35);
      canvas.drawRect(
        coreRect,
        Paint()
          ..color = color
          ..style = PaintingStyle.fill,
      );
      // División central fina dúplex LC
      canvas.drawLine(
        Offset(coreRect.center.dx, coreRect.top + 0.5),
        Offset(coreRect.center.dx, coreRect.bottom - 0.5),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.85)
          ..strokeWidth = 0.7,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TechnicalPortPainter oldDelegate) {
    return oldDelegate.kind != kind ||
        oldDelegate.isConnected != isConnected ||
        oldDelegate.isPending != isPending ||
        oldDelegate.color != color ||
        oldDelegate.borderColor != borderColor ||
        oldDelegate.latchDown != latchDown ||
        oldDelegate.label != label;
  }
}

class _RackUndoAction {
  final int deviceId;
  final String deviceCode;
  final int previousStartU;
  final int newStartU;

  const _RackUndoAction({
    required this.deviceId,
    required this.deviceCode,
    required this.previousStartU,
    required this.newStartU,
  });
}
