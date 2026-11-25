import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Vector brand mark matching `src/lib/Logo.svelte`:
/// an arch with a short vertical inner line inside `viewBox="12 12 40 40"`.
class NeoModernLogo extends StatelessWidget {
  const NeoModernLogo({
    super.key,
    this.size = 20,
    this.color = Colors.white,
  });

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _NeoModernLogoPainter(color: color),
      ),
    );
  }
}

class _NeoModernLogoPainter extends CustomPainter {
  const _NeoModernLogoPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = math.min(size.width, size.height) / 40.0;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7.5 * scale
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    Offset p(double x, double y) => Offset((x - 12.0) * scale, (y - 12.0) * scale);

    final path = Path()
      ..moveTo(p(18, 49).dx, p(18, 49).dy)
      ..lineTo(p(18, 30).dx, p(18, 30).dy)
      ..arcTo(
        Rect.fromCircle(center: p(32, 30), radius: 14.0 * scale),
        math.pi,
        math.pi,
        false,
      )
      ..lineTo(p(46, 49).dx, p(46, 49).dy)
      ..moveTo(p(32, 33).dx, p(32, 33).dy)
      ..lineTo(p(32, 46).dx, p(32, 46).dy);

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _NeoModernLogoPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
