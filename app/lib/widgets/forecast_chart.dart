import 'dart:math' as math;

import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/app_theme.dart';

/// River level now and the AI forecast for the next few hours: the most
/// likely level (dotted line), the likely range (shaded) and the warning
/// lines it is close to.
class ForecastChart extends StatelessWidget {
  const ForecastChart({super.key, required this.current, required this.forecast, required this.thresholds, required this.semanticLabel, required this.levelNames, this.nowLabel = 'Now'});
  final String nowLabel;
  final double current;
  final StationForecast forecast;
  final Thresholds? thresholds;
  final String semanticLabel;
  final String Function(RiskLevel) levelNames;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      label: semanticLabel,
      image: true,
      excludeSemantics: true,
      child: SizedBox(
        height: 180,
        width: double.infinity,
        child: CustomPaint(
          painter: _ChartPainter(
            current: current,
            f: forecast,
            t: thresholds,
            line: c.primary,
            grid: c.divider,
            label: c.textMuted,
            levelNames: levelNames,
            nowLabel: nowLabel,
          ),
        ),
      ),
    );
  }
}

class _ChartPainter extends CustomPainter {
  _ChartPainter({required this.current, required this.f, required this.t, required this.line, required this.grid, required this.label, required this.levelNames, required this.nowLabel});
  final String nowLabel;
  final double current;
  final StationForecast f;
  final Thresholds? t;
  final Color line, grid, label;
  final String Function(RiskLevel) levelNames;

  @override
  void paint(Canvas canvas, Size size) {
    const bottomPad = 24.0, leftPad = 8.0, rightPad = 8.0, topPad = 8.0;
    final plot = Rect.fromLTRB(leftPad, topPad, size.width - rightPad, size.height - bottomPad);

    final lines = <(RiskLevel, double)>[
      if (t != null) ...[(RiskLevel.alert, t!.alert), (RiskLevel.warning, t!.warning), (RiskLevel.danger, t!.danger)],
    ];
    var lo = math.min(current, f.lowM);
    var hi = math.max(current, f.highM);
    // Show the nearest warning line above, so people see how close it is.
    for (final (_, v) in lines) {
      if (v >= hi && v - hi < (hi - lo) + 0.6) hi = v;
    }
    final pad = math.max(0.1, (hi - lo) * 0.15);
    lo -= pad;
    hi += pad;
    double y(double v) => plot.bottom - (v - lo) / (hi - lo) * plot.height;

    // Axis.
    canvas.drawLine(Offset(plot.left, plot.bottom), Offset(plot.right, plot.bottom), Paint()..color = grid);

    // Warning lines (dashed) with their names.
    for (final (level, v) in lines) {
      if (v < lo || v > hi) continue;
      final p = Paint()
        ..color = RiskStyle.of(level).color
        ..strokeWidth = 1.5;
      for (var x = plot.left; x < plot.right; x += 9) {
        canvas.drawLine(Offset(x, y(v)), Offset(math.min(x + 5, plot.right), y(v)), p);
      }
      _text(canvas, '${levelNames(level)} ${v.toStringAsFixed(2)} m', Offset(plot.left + 2, y(v) - 18),
          RiskStyle.of(level).color, 13);
    }

    final x0 = plot.left + plot.width * 0.08;
    final x1 = plot.right - 4;
    // Likely range (shaded).
    final band = Path()
      ..moveTo(x0, y(current))
      ..lineTo(x1, y(f.highM))
      ..lineTo(x1, y(f.lowM))
      ..close();
    canvas.drawPath(band, Paint()..color = line.withValues(alpha: 0.14));

    // Most likely level (dotted).
    final dot = Paint()
      ..color = line
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    const steps = 18;
    for (var i = 0; i < steps; i += 2) {
      final a = i / steps, b = (i + 1) / steps;
      canvas.drawLine(
        Offset(x0 + (x1 - x0) * a, y(current + (f.predictedLevelM - current) * a)),
        Offset(x0 + (x1 - x0) * b, y(current + (f.predictedLevelM - current) * b)),
        dot,
      );
    }
    canvas.drawCircle(Offset(x1, y(f.predictedLevelM)), 4.5, Paint()..color = line);

    // "Now" point.
    canvas.drawCircle(Offset(x0, y(current)), 6, Paint()..color = Colors.white);
    canvas.drawCircle(Offset(x0, y(current)), 6, Paint()
      ..color = line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3);

    _text(canvas, nowLabel, Offset(x0 - 12, plot.bottom + 6), label, 13, bold: true);
    _text(canvas, '+${f.horizonHours} h', Offset(x1 - 26, plot.bottom + 6), label, 13);
  }

  void _text(Canvas c, String s, Offset at, Color color, double size, {bool bold = false}) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(color: color, fontSize: size, fontWeight: bold ? FontWeight.w700 : FontWeight.w500)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(c, at);
  }

  @override
  bool shouldRepaint(_ChartPainter old) => old.f != f || old.current != current || old.line != line;
}
