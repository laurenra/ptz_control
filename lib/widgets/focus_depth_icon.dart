import 'package:material_ui/material_ui.dart';

/// Side-view eye with identical leading depth marks for near and far focus.
class FocusDepthIcon extends StatelessWidget {
  const FocusDepthIcon({super.key, required this.far});

  final bool far;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(44, 28),
    painter: _FocusDepthPainter(
      far: far,
      color: IconTheme.of(context).color ?? Colors.white,
    ),
  );
}

class _FocusDepthPainter extends CustomPainter {
  const _FocusDepthPainter({required this.far, required this.color});

  final bool far;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 44, size.height / 28);
    final pen = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final eye = Path()
      ..moveTo(2, 4)
      ..cubicTo(8, 5, 13, 9, 17, 14)
      ..cubicTo(13, 19, 8, 23, 2, 24);
    final iris = Path()
      ..moveTo(10, 8)
      ..quadraticBezierTo(5, 14, 10, 20);
    canvas.drawPath(eye, pen);
    canvas.drawPath(iris, pen);
    canvas.drawCircle(const Offset(11, 14), 1.4, Paint()..color = color);
    for (var i = 0; i < (far ? 5 : 3); i++) {
      final x = 21.0 + i * 5;
      final height = 5.0 + i * 4;
      canvas.drawLine(
        Offset(x, 14 - height / 2),
        Offset(x, 14 + height / 2),
        pen,
      );
    }
  }

  @override
  bool shouldRepaint(_FocusDepthPainter oldDelegate) =>
      far != oldDelegate.far || color != oldDelegate.color;
}
