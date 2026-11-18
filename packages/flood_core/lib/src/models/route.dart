import '../util/geo.dart';

/// One turn-by-turn instruction.
class RouteStep {
  RouteStep({
    required this.instruction,
    required this.distanceM,
    required this.durationS,
    this.type,
    this.name,
    this.exitNumber,
    this.wayPoint,
  });

  /// openrouteservice's own wording (one language only). The app builds its
  /// own words from [type], [name] and [exitNumber] when [type] is known.
  final String instruction;
  final double distanceM;
  final double durationS;

  /// openrouteservice step type (0 = turn left ... 10 = arrive, 11 = depart,
  /// 12 = keep left, 13 = keep right). Null on routes saved before it was kept.
  final int? type;

  /// Street name, or null when the road has no name ("-" in the reply).
  final String? name;

  /// Roundabout exit to take.
  final int? exitNumber;

  /// Index in [RoutePlan.path] where this step starts.
  final int? wayPoint;
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
          for (final s in steps)
            {
              'i': s.instruction,
              'd': s.distanceM,
              't': s.durationS,
              if (s.type != null) 'k': s.type,
              if (s.name != null) 'n': s.name,
              if (s.exitNumber != null) 'x': s.exitNumber,
              if (s.wayPoint != null) 'w': s.wayPoint,
            },
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
                durationS: (s['t'] as num).toDouble(),
                type: (s['k'] as num?)?.toInt(),
                name: s['n'] as String?,
                exitNumber: (s['x'] as num?)?.toInt(),
                wayPoint: (s['w'] as num?)?.toInt()),
        ],
        path: [for (final p in j['path'] as List) pt(p)]);
  }
}
