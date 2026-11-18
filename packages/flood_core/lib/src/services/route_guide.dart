import 'dart:convert';
import 'dart:math' as math;

import '../models/risk_level.dart';
import '../models/route.dart';
import '../models/station_status.dart';
import '../util/geo.dart';
import 'settings_service.dart';

/// What one turn-by-turn step asks the driver to do. Same order as
/// openrouteservice's step "type" numbers, so the app can word every step
/// in its own language instead of using the English text from the server.
enum StepKind {
  left, // 0
  right, // 1
  sharpLeft, // 2
  sharpRight, // 3
  slightLeft, // 4
  slightRight, // 5
  straight, // 6
  enterRoundabout, // 7
  exitRoundabout, // 8
  uTurn, // 9
  arrive, // 10
  depart, // 11
  keepLeft, // 12
  keepRight; // 13

  /// Null for a missing or unknown type (old saved routes, new server types).
  static StepKind? fromOrs(int? type) =>
      (type == null || type < 0 || type >= values.length) ? null : values[type];
}

/// A road route kept on the phone, so it still shows without internet.
class SavedRoute {
  SavedRoute({required this.centreId, required this.savedAt, required this.plan});
  final String centreId;
  final DateTime savedAt;
  final RoutePlan plan;

  /// A route older than this is shown with "This route is old, update it".
  static const oldAfter = Duration(hours: 1);

  /// A route that started further than this from the user is not used for them.
  static const sameStartKm = 1.0;

  bool isOld(DateTime now) => now.difference(savedAt) > oldAfter;

  /// True when the route started close to [user], so it fits where they are now.
  bool startsNear(GeoPoint user) => distanceKm(user, plan.from) <= sameStartKm;

  /// Every step has a type, so the app can word all of them in any language.
  bool get canTranslate => plan.steps.every((s) => StepKind.fromOrs(s.type) != null);
}

/// The last road route to each of a few relief centres, kept on the phone.
/// Damaged saved data is ignored, never an error.
class RouteCache {
  RouteCache(this.store, {this.keep = 3});
  final SettingsStore store;

  /// How many centres' routes are kept (newest first).
  final int keep;

  Future<SavedRoute?> load(String centreId) async {
    try {
      final raw = (await store.load())[centreId];
      if (raw == null) return null;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return SavedRoute(
          centreId: centreId,
          savedAt: DateTime.parse(j['savedAt'] as String),
          plan: RoutePlan.fromJson(j['plan'] as Map<String, dynamic>));
    } catch (_) {
      return null;
    }
  }

  /// Saves [plan] for [centreId] and drops the oldest routes beyond [keep].
  /// A full phone must not stop the live route, so failures are ignored.
  Future<SavedRoute> save(String centreId, RoutePlan plan, DateTime at) async {
    final saved = SavedRoute(centreId: centreId, savedAt: at, plan: plan);
    try {
      final all = await store.load();
      all[centreId] = jsonEncode({'savedAt': at.toUtc().toIso8601String(), 'plan': plan.toJson()});
      DateTime when(String v) {
        try {
          return DateTime.parse((jsonDecode(v) as Map)['savedAt'] as String);
        } catch (_) {
          return DateTime.fromMillisecondsSinceEpoch(0);
        }
      }

      final newest = all.entries.toList()..sort((a, b) => when(b.value).compareTo(when(a.value)));
      await store.save({for (final e in newest.take(keep)) e.key: e.value});
    } catch (_) {}
    return saved;
  }
}

/// A river station at [RouteHazard.status] level close to the road route.
class RouteHazard {
  RouteHazard(this.status, this.distanceKm);
  final StationStatus status;

  /// Straight-line distance from the station to the nearest part of the route.
  final double distanceKm;
}

/// River stations at [minLevel] or above within [withinKm] of the route line,
/// worst first, then nearest. Old or unknown readings are left out.
List<RouteHazard> routeHazards(RoutePlan plan, List<StationStatus> statuses,
    {double withinKm = 1.0, RiskLevel minLevel = RiskLevel.warning}) {
  final line = plan.path.length >= 2 ? plan.path : [plan.from, plan.to];
  final out = <RouteHazard>[];
  for (final s in statuses) {
    final at = s.station.location;
    if (at == null || !s.isActionable || !s.level!.isAtLeast(minLevel)) continue;
    final d = distanceToLineKm(at, line);
    if (d <= withinKm) out.add(RouteHazard(s, d));
  }
  out.sort((a, b) {
    final c = b.status.level!.index.compareTo(a.status.level!.index);
    return c != 0 ? c : a.distanceKm.compareTo(b.distanceKm);
  });
  return out;
}

/// Shortest distance in km from [p] to the line through [line]'s points.
/// Uses a flat map around [p], which is accurate to well under 1% at the
/// distances that matter here (a few km).
double distanceToLineKm(GeoPoint p, List<GeoPoint> line) {
  if (line.isEmpty) return double.infinity;
  if (line.length == 1) return distanceKm(p, line.first);
  const kmPerDeg = 111.32;
  final cosLat = math.cos(p.lat * math.pi / 180);
  (double, double) xy(GeoPoint q) => ((q.lon - p.lon) * kmPerDeg * cosLat, (q.lat - p.lat) * kmPerDeg);
  var best = double.infinity;
  for (var i = 0; i < line.length - 1; i++) {
    final (ax, ay) = xy(line[i]);
    final (bx, by) = xy(line[i + 1]);
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    // Where the closest point lies along the segment (0 = start, 1 = end).
    final t = len2 == 0 ? 0.0 : ((-ax * dx - ay * dy) / len2).clamp(0.0, 1.0);
    final cx = ax + t * dx, cy = ay + t * dy;
    best = math.min(best, math.sqrt(cx * cx + cy * cy));
  }
  return best;
}

/// Which step the user is on now, from where they are. 0 (the first step)
/// when they are not near the route yet or the steps have no positions.
int currentStepIndex(RoutePlan plan, GeoPoint user, {double onRouteKm = 0.3}) {
  if (plan.steps.isEmpty || plan.path.isEmpty) return 0;
  var nearest = 0;
  var bestKm = double.infinity;
  for (var i = 0; i < plan.path.length; i++) {
    final d = distanceKm(user, plan.path[i]);
    if (d < bestKm) {
      bestKm = d;
      nearest = i;
    }
  }
  if (bestKm > onRouteKm) return 0;
  var step = 0;
  for (var i = 0; i < plan.steps.length; i++) {
    final w = plan.steps[i].wayPoint;
    if (w != null && w <= nearest) step = i;
  }
  return step;
}

/// The stretch of road for step [i] (from where it starts to where the next
/// step starts), to draw over the route. Null when the step's position is
/// not known (routes saved before positions were kept).
List<GeoPoint>? stepPath(RoutePlan plan, int i) {
  if (i < 0 || i >= plan.steps.length || plan.path.length < 2) return null;
  final start = plan.steps[i].wayPoint;
  if (start == null || start < 0 || start >= plan.path.length) return null;
  var end = plan.path.length - 1;
  for (var j = i + 1; j < plan.steps.length; j++) {
    final w = plan.steps[j].wayPoint;
    if (w != null) {
      end = w;
      break;
    }
  }
  if (end <= start) end = math.min(start + 1, plan.path.length - 1);
  if (end <= start) return null;
  return plan.path.sublist(start, end + 1);
}

/// Which step is highlighted on the route page. It follows the phone's
/// position until the user picks a step themselves (tap a step, Next or
/// Back); from then on their choice stays until the route is updated.
class StepFocus {
  StepFocus(this.count, {int start = 0}) : index = count == 0 ? 0 : start.clamp(0, count - 1);
  final int count;
  int index;

  /// True once the user has chosen a step.
  bool manual = false;

  bool get atFirst => index <= 0;
  bool get atLast => index >= count - 1;

  /// The step for the phone's position. Ignored after a manual choice.
  /// Returns true when the highlight moved.
  bool follow(int gpsIndex) => manual ? false : _set(gpsIndex);

  bool next() => _choose(index + 1);
  bool back() => _choose(index - 1);
  bool select(int i) => _choose(i);

  bool _choose(int i) {
    if (count == 0 || i < 0 || i >= count) return false;
    manual = true;
    return _set(i);
  }

  bool _set(int i) {
    if (count == 0) return false;
    final n = i.clamp(0, count - 1);
    if (n == index) return false;
    index = n;
    return true;
  }
}
