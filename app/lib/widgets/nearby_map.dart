import 'dart:math' as math;

import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import '../theme/app_theme.dart';

class MapPin {
  const MapPin({required this.id, required this.at, required this.color, required this.icon, required this.semantics, this.selected = false, this.text});
  final String id;
  final GeoPoint at;
  final Color color;
  final IconData icon;
  final String semantics;
  final bool selected;

  /// Short text under the pin (e.g. "42 mm/h").
  final String? text;
}

/// A simple map of what is near you, drawn from real coordinates: you in
/// the middle, distance rings, and pins at their true direction and
/// distance. Works offline and needs no map key. Turn-by-turn directions
/// open in Google Maps.
class NearbyMap extends StatelessWidget {
  const NearbyMap({super.key, required this.center, required this.pins, this.routeToId, this.onPinTap, this.height = 320, required this.youLabel, this.legend});
  final GeoPoint center;
  final List<MapPin> pins;
  final String? routeToId;
  final ValueChanged<String>? onPinTap;
  final double height;
  final String youLabel;
  final Widget? legend;

  static const _nice = [0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0];

  /// East and north distance in km from [center].
  Offset _km(GeoPoint p) => Offset(
        (p.lon - center.lon) * 111.32 * math.cos(center.lat * math.pi / 180),
        (p.lat - center.lat) * 110.57,
      );

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ClipRRect(
      borderRadius: BorderRadius.circular(kCardRadius),
      child: SizedBox(
        height: height,
        child: LayoutBuilder(builder: (context, box) {
          final size = Size(box.maxWidth, height);
          final mid = Offset(size.width / 2, size.height / 2);
          var far = 0.5;
          for (final p in pins) {
            far = math.max(far, _km(p.at).distance);
          }
          final maxRing = _nice.firstWhere((n) => n >= far, orElse: () => far);
          final pxPerKm = (math.min(size.width, size.height) / 2 - 30) / maxRing;
          Offset pos(GeoPoint g) {
            final k = _km(g);
            return mid + Offset(k.dx * pxPerKm, -k.dy * pxPerKm);
          }

          final rings = [for (final n in _nice) if (n <= maxRing && n >= maxRing / 5) n];
          MapPin? target;
          for (final p in pins) {
            if (p.id == routeToId) target = p;
          }
          return Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _MapPainter(
                    mid: mid,
                    rings: [for (final r in rings) (r, r * pxPerKm)],
                    route: target == null ? null : pos(target.at),
                    routeColor: c.primary,
                    textColor: c.textMuted,
                  ),
                ),
              ),
              // You.
              Positioned(
                left: mid.dx - 12,
                top: mid.dy - 12,
                child: Semantics(
                  label: youLabel,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: c.primary,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: [BoxShadow(color: c.primary.withValues(alpha: 0.25), spreadRadius: 8)],
                    ),
                  ),
                ),
              ),
              for (final p in pins) _pin(context, p, pos(p.at)),
              if (legend != null) Positioned(right: 12, bottom: 12, child: legend!),
              Positioned(
                left: 12,
                top: 12,
                child: ExcludeSemantics(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(8)),
                    child: const Text('N ↑', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
            ],
          );
        }),
      ),
    );
  }

  Widget _pin(BuildContext context, MapPin p, Offset at) {
    final d = p.selected ? 40.0 : 32.0;
    return Positioned(
      left: at.dx - 24,
      top: at.dy - 24,
      child: Semantics(
        button: onPinTap != null,
        selected: p.selected,
        label: p.semantics,
        excludeSemantics: true,
        child: GestureDetector(
          key: ValueKey('pin-${p.id}'),
          behavior: HitTestBehavior.opaque,
          onTap: onPinTap == null ? null : () => onPinTap!(p.id),
          child: SizedBox(
            width: 48,
            height: p.text == null ? 48 : 66,
            child: Column(
              children: [
                SizedBox(
                  height: 48,
                  child: Center(
                    child: Container(
                      width: d,
                      height: d,
                      decoration: BoxDecoration(
                        color: p.color,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: p.selected ? const Color(0xFF111418) : Colors.white, width: 3),
                        boxShadow: const [BoxShadow(color: Color(0x40111418), blurRadius: 6, offset: Offset(0, 2))],
                      ),
                      child: Icon(p.icon, color: Colors.white, size: p.selected ? 22 : 18),
                    ),
                  ),
                ),
                if (p.text != null)
                  Text(p.text!,
                      maxLines: 1,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF111418), fontFeatures: AppText.tabular)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MapPainter extends CustomPainter {
  _MapPainter({required this.mid, required this.rings, required this.route, required this.routeColor, required this.textColor});
  final Offset mid;
  final List<(double, double)> rings; // (km, radius px)
  final Offset? route;
  final Color routeColor, textColor;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFFEEF2EA));
    final ring = Paint()
      ..color = const Color(0xFFCAD3C4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final (km, r) in rings) {
      canvas.drawCircle(mid, r, ring);
      final tp = TextPainter(
        text: TextSpan(
            text: km < 1 ? '${(km * 1000).round()} m' : '${km.round()} km',
            style: TextStyle(fontSize: 12, color: textColor, fontWeight: FontWeight.w600)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, mid + Offset(4, -r - 2));
    }
    if (route != null) {
      // Straight dotted line: direction only. Real roads come from Google Maps.
      final p = Paint()
        ..color = routeColor
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round;
      final total = (route! - mid).distance;
      if (total > 0) {
        final dir = (route! - mid) / total;
        for (var d = 14.0; d < total - 18; d += 12) {
          canvas.drawCircle(mid + dir * d, 2.5, p);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_MapPainter old) => old.route != route || old.rings.length != rings.length || old.mid != mid;
}
