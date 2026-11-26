import 'package:flood_core/flood_core.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';

import '../app/app_controller.dart';
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

LatLng _ll(GeoPoint p) => LatLng(p.lat, p.lon);

/// Street map (OpenStreetMap) with you, pins and an optional route line.
/// Pins are at least 48 x 48 to tap. Rotation is off so north stays up.
class AppMap extends StatelessWidget {
  const AppMap({
    super.key,
    required this.you,
    required this.pins,
    required this.youLabel,
    this.route,
    this.straightLine = false,
    this.onPinTap,
    this.legend,
    this.height = 320,
    this.onMapTap,
    this.highlight,
    this.controller,
  });
  final GeoPoint you;
  final List<MapPin> pins;
  final String youLabel;

  /// Points of the line to draw (a road route, or [you] and a centre).
  final List<GeoPoint>? route;

  /// Draw [route] dotted, meaning "direction only, not the road".
  final bool straightLine;
  final ValueChanged<String>? onPinTap;
  final Widget? legend;
  final double height;

  /// Tapping the map itself (not a pin), e.g. to drop a pin for a report.
  final ValueChanged<GeoPoint>? onMapTap;

  /// Part of [route] drawn stronger (the highlighted step on the route page).
  final List<GeoPoint>? highlight;

  /// Lets a screen move the map (e.g. to the highlighted step).
  final MapController? controller;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final c = context.colors;
    final points = [_ll(you), for (final p in pins) _ll(p.at), if (route != null) for (final p in route!) _ll(p)];
    return ClipRRect(
      borderRadius: BorderRadius.circular(kCardRadius),
      child: SizedBox(
        height: height,
        child: Stack(children: [
          FlutterMap(
            mapController: controller,
            options: MapOptions(
              initialCenter: _ll(you),
              initialZoom: 13,
              initialCameraFit: points.length > 1
                  ? CameraFit.coordinates(coordinates: points, padding: const EdgeInsets.fromLTRB(40, 48, 40, 40), maxZoom: 16)
                  : null,
              backgroundColor: const Color(0xFFEEF2EA),
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
              onTap: onMapTap == null ? null : (_, ll) => onMapTap!(GeoPoint(ll.latitude, ll.longitude)),
            ),
            children: [
              if (app.deps.showMapTiles)
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  // OpenStreetMap blocks requests without a real app name.
                  userAgentPackageName: 'my.fyp.floodprepare',
                ),
              if (route != null && route!.length > 1)
                PolylineLayer(polylines: [
                  Polyline(
                    points: [for (final p in route!) _ll(p)],
                    strokeWidth: straightLine ? 4 : 6,
                    // Lighter when one step is drawn over it.
                    color: highlight != null && highlight!.length > 1 ? c.primary.withValues(alpha: 0.4) : c.primary,
                    pattern: straightLine ? StrokePattern.dotted() : const StrokePattern.solid(),
                  ),
                  if (highlight != null && highlight!.length > 1)
                    Polyline(
                      points: [for (final p in highlight!) _ll(p)],
                      strokeWidth: 9,
                      color: c.primary,
                      borderStrokeWidth: 2,
                      borderColor: Colors.white,
                    ),
                ]),
              MarkerLayer(markers: [
                Marker(
                  point: _ll(you),
                  width: 48,
                  height: 48,
                  child: Semantics(
                    label: youLabel,
                    child: Center(
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
                ),
                for (final p in pins)
                  Marker(
                    point: _ll(p.at),
                    width: 56,
                    height: p.text == null ? 56 : 72,
                    child: _Pin(pin: p, onTap: onPinTap == null ? null : () => onPinTap!(p.id)),
                  ),
              ]),
            ],
          ),
          if (legend != null) Positioned(right: 12, top: 12, child: legend!),
          // Required credit for OpenStreetMap; tap opens the copyright page.
          Positioned(
            left: 8,
            bottom: 8,
            child: GestureDetector(
              onTap: () => app.deps.opener.open(Uri.parse('https://www.openstreetmap.org/copyright')),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(6)),
                child: const Text('© OpenStreetMap contributors', style: TextStyle(fontSize: 12, color: Color(0xFF111418))),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class _Pin extends StatelessWidget {
  const _Pin({required this.pin, required this.onTap});
  final MapPin pin;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final d = pin.selected ? 40.0 : 32.0;
    return Semantics(
      button: onTap != null,
      selected: pin.selected,
      label: pin.semantics,
      excludeSemantics: true,
      child: GestureDetector(
        key: ValueKey('pin-${pin.id}'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            height: 56,
            child: Center(
              child: Container(
                width: d,
                height: d,
                decoration: BoxDecoration(
                  color: pin.color,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: pin.selected ? const Color(0xFF111418) : Colors.white, width: 3),
                  boxShadow: const [BoxShadow(color: Color(0x40111418), blurRadius: 6, offset: Offset(0, 2))],
                ),
                child: Icon(pin.icon, color: Colors.white, size: pin.selected ? 22 : 18),
              ),
            ),
          ),
          if (pin.text != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.9), borderRadius: BorderRadius.circular(4)),
              child: Text(pin.text!,
                  maxLines: 1,
                  // Fixed size: the marker box is fixed (screen readers get the full label).
                  textScaler: TextScaler.noScaling,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF111418), fontFeatures: AppText.tabular)),
            ),
        ]),
      ),
    );
  }
}
