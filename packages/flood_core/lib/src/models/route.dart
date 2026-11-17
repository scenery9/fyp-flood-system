import '../util/geo.dart';

/// One turn-by-turn instruction.
class RouteStep {
  RouteStep({required this.instruction, required this.distanceM, required this.durationS});
  final String instruction;
  final double distanceM;
  final double durationS;
}

/// A road route with steps and the line to draw on the map.
class RoutePlan {
  RoutePlan({
    required this.from,
    required this.to,
    required this.distanceM,
    required this.durationS,
    required this.steps,
    required this.path,
  });
  final GeoPoint from;
  final GeoPoint to;
  final double distanceM;
  final double durationS;
  final List<RouteStep> steps;
  final List<GeoPoint> path;

  double get distanceKm => distanceM / 1000;
  int get durationMin => (durationS / 60).ceil();

  Map<String, dynamic> toJson() => {
        'from': [from.lat, from.lon],
        'to': [to.lat, to.lon],
        'distanceM': distanceM,
        'durationS': durationS,
        'steps': [
          for (final s in steps) {'i': s.instruction, 'd': s.distanceM, 't': s.durationS},
        ],
        'path': [for (final p in path) [p.lat, p.lon]],
      };

  /// Throws if the saved data is damaged.
  factory RoutePlan.fromJson(Map<String, dynamic> j) {
    GeoPoint pt(dynamic v) => GeoPoint((v[0] as num).toDouble(), (v[1] as num).toDouble());
    return RoutePlan(
        from: pt(j['from']),
        to: pt(j['to']),
        distanceM: (j['distanceM'] as num).toDouble(),
        durationS: (j['durationS'] as num).toDouble(),
        steps: [
          for (final s in j['steps'] as List)
            RouteStep(
                instruction: s['i'] as String,
                distanceM: (s['d'] as num).toDouble(),
                durationS: (s['t'] as num).toDouble()),
        ],
        path: [for (final p in j['path'] as List) pt(p)]);
  }
}
