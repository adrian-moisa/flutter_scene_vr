import 'dart:math' as math;

import 'package:flutter/widgets.dart';

class OpenXrPerformanceGraphPoint {
  const OpenXrPerformanceGraphPoint({
    required this.xrHz,
    required this.contentHz,
    required this.flutterHz,
    this.uiPaused = false,
  });

  final double xrHz;
  final double contentHz;
  final double flutterHz;
  final bool uiPaused;
}

/// Draws one bounded sample per second for the most recent 30 seconds.
class OpenXrPerformanceGraph extends StatelessWidget {
  const OpenXrPerformanceGraph({
    required this.points,
    this.refreshRateHz = 72,
    super.key,
  });

  final List<OpenXrPerformanceGraphPoint> points;
  final double refreshRateHz;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      height: 132,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _OpenXrPerformanceGraphPainter(
            points: points,
            refreshRateHz: refreshRateHz,
          ),
        ),
      ),
    );
  }
}

class _OpenXrPerformanceGraphPainter extends CustomPainter {
  const _OpenXrPerformanceGraphPainter({
    required this.points,
    required this.refreshRateHz,
  });

  static const _maximumPointCount = 30;
  static const _xrColor = Color(0xFF67E8F9);
  static const _textureColor = Color(0xFFFBBF24);
  static const _flutterColor = Color(0xFFC084FC);

  final List<OpenXrPerformanceGraphPoint> points;
  final double refreshRateHz;

  @override
  void paint(Canvas canvas, Size size) {
    const leftInset = 48.0;
    const bottomInset = 32.0;
    final graphRect = Rect.fromLTRB(
      leftInset,
      12,
      size.width,
      size.height - bottomInset,
    );
    if (graphRect.width <= 0 || graphRect.height <= 0) return;

    final largestSample = points.fold<double>(refreshRateHz, (largest, point) {
      return math.max(
        largest,
        math.max(point.xrHz, math.max(point.contentHz, point.flutterHz)),
      );
    });
    final ceilingHz = math
        .max(refreshRateHz, (largestSample / 12).ceil() * 12)
        .toDouble();

    final bandWidth = graphRect.width / (_maximumPointCount - 1);
    for (var i = 0; i < points.length; i++) {
      if (!points[i].uiPaused) continue;
      final x =
          graphRect.left + (_maximumPointCount - points.length + i) * bandWidth;
      canvas.drawRect(
        Rect.fromLTRB(
          math.max(graphRect.left, x - bandWidth / 2),
          graphRect.top,
          math.min(graphRect.right, x + bandWidth / 2),
          graphRect.bottom,
        ),
        Paint()..color = const Color(0x3067E8F9),
      );
    }

    final gridPaint = Paint()
      ..color = const Color(0x1FFFFFFF)
      ..strokeWidth = 1;
    for (final fraction in const [0.0, 0.5, 1.0]) {
      final y = graphRect.bottom - graphRect.height * fraction;
      canvas.drawLine(
        Offset(graphRect.left, y),
        Offset(graphRect.right, y),
        gridPaint,
      );
      _drawText(
        canvas,
        '${(ceilingHz * fraction).round()}',
        Offset(0, y - 9),
        const Color(0xFFC5D0DF),
        18,
      );
    }

    _drawText(
      canvas,
      '30s ago',
      Offset(graphRect.left, graphRect.bottom + 6),
      const Color(0xFFC5D0DF),
      18,
    );
    _drawRightAlignedText(
      canvas,
      'now',
      Offset(graphRect.right, graphRect.bottom + 6),
      const Color(0xFFC5D0DF),
      18,
    );

    _drawSeries(canvas, graphRect, ceilingHz, _xrColor, (point) => point.xrHz);
    _drawSeries(
      canvas,
      graphRect,
      ceilingHz,
      _textureColor,
      (point) => point.contentHz,
    );
    _drawSeries(
      canvas,
      graphRect,
      ceilingHz,
      _flutterColor,
      (point) => point.flutterHz,
    );
  }

  void _drawSeries(
    Canvas canvas,
    Rect graphRect,
    double ceilingHz,
    Color color,
    double Function(OpenXrPerformanceGraphPoint point) select,
  ) {
    if (points.isEmpty) return;

    final path = Path();
    for (var index = 0; index < points.length; index++) {
      final historyIndex = _maximumPointCount - points.length + index;
      final x =
          graphRect.left +
          graphRect.width * historyIndex / (_maximumPointCount - 1);
      final fractionOfCeiling = (select(points[index]) / ceilingHz).clamp(
        0.0,
        1.0,
      );
      final y = graphRect.bottom - graphRect.height * fractionOfCeiling;
      if (index == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );
  }

  void _drawText(
    Canvas canvas,
    String text,
    Offset offset,
    Color color,
    double fontSize,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  void _drawRightAlignedText(
    Canvas canvas,
    String text,
    Offset offset,
    Color color,
    double fontSize,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, Offset(offset.dx - painter.width, offset.dy));
  }

  @override
  bool shouldRepaint(_OpenXrPerformanceGraphPainter oldDelegate) {
    return oldDelegate.points != points ||
        oldDelegate.refreshRateHz != refreshRateHz;
  }
}
