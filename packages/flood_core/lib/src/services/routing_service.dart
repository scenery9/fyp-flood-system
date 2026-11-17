import 'dart:convert';

import '../errors.dart';
import '../models/evacuation_point.dart';
import '../models/route.dart';
import '../util/geo.dart';
import 'evacuation_service.dart';

/// Anything that can work out a road route.
abstract class RouteProvider {
  Future<RoutePlan> route(GeoPoint from, GeoPoint to);
}

/// Downloads a web address and returns the body as text. The Flutter app
/// passes a small function built on the `http` package; tests pass a fake.
typedef HttpGet = Future<String> Function(Uri uri);

/// Road routes from openrouteservice (free key from openrouteservice.org).
/// Keep the key out of GitHub: pass it at build time, e.g.
///   flutter run --dart-define=ORS_KEY=your_key
class OrsRouteProvider implements RouteProvider {
  OrsRouteProvider({required this.apiKey, required this.get, this.profile = 'driving-car'});
  final String apiKey;
  final HttpGet get;
  final String profile;

  /// Note: openrouteservice wants longitude first.
  Uri buildUri(GeoPoint from, GeoPoint to) =>
      Uri.https('api.openrouteservice.org', '/v2/directions/$profile', {
        'api_key': apiKey,
        'start': '${from.lon},${from.lat}',
        'end': '${to.lon},${to.lat}',
      });

  @override
  Future<RoutePlan> route(GeoPoint from, GeoPoint to) async {
    if (apiKey.trim().isEmpty) throw RoutingException('Missing openrouteservice key');
    final String body;
    try {
      body = await get(buildUri(from, to));
    } catch (e) {
      throw RoutingException('Could not reach the routing service');
    }
    return parseOrsDirections(body, from: from, to: to);
  }
}

/// Reads an openrouteservice directions reply (GeoJSON).
RoutePlan parseOrsDirections(String body, {required GeoPoint from, required GeoPoint to}) {
  try {
    final j = jsonDecode(body);
    if (j is! Map) throw RoutingException('Unexpected reply');
    if (j['error'] != null) {
      final e = j['error'];
      throw RoutingException(e is Map ? '${e['message'] ?? 'Routing error'}' : '$e');
    }
    final features = j['features'];
    if (features is! List || features.isEmpty) throw RoutingException('No route found');
    final f = features.first as Map;
    final props = (f['properties'] as Map?) ?? const {};
    final summary = (props['summary'] as Map?) ?? const {};
    final steps = <RouteStep>[
      for (final seg in (props['segments'] as List?) ?? const [])
        for (final s in ((seg as Map)['steps'] as List?) ?? const [])
          RouteStep(
              instruction: '${(s as Map)['instruction'] ?? ''}'.trim(),
              distanceM: ((s['distance'] ?? 0) as num).toDouble(),
              durationS: ((s['duration'] ?? 0) as num).toDouble()),
    ].where((s) => s.instruction.isNotEmpty).toList();
    final coords = ((f['geometry'] as Map?)?['coordinates'] as List?) ?? const [];
    return RoutePlan(
        from: from,
        to: to,
        distanceM: ((summary['distance'] ?? 0) as num).toDouble(),
        durationS: ((summary['duration'] ?? 0) as num).toDouble(),
        steps: steps,
        path: [
          for (final c in coords)
            GeoPoint(((c as List)[1] as num).toDouble(), (c[0] as num).toDouble()),
        ]);
  } on RoutingException {
    rethrow;
  } catch (_) {
    throw RoutingException('Could not read the routing reply');
  }
}

/// Keeps the last route on the phone so it still shows without internet.
abstract class RouteStore {
  Future<String?> load();
  Future<void> save(String value);
}

class InMemoryRouteStore implements RouteStore {
  String? _v;
  @override
  Future<String?> load() async => _v;
  @override
  Future<void> save(String value) async => _v = value;
}

enum RouteSource { live, saved, none }

/// What the Evacuation screen shows.
class EvacuationRoute {
  EvacuationRoute({
    required this.centre,
    required this.straightLineKm,
    required this.source,
    required this.directionsUrl,
    this.plan,
    this.savedAt,
    this.notice,
  });
  final EvacuationPoint centre;
  final double straightLineKm;

  /// live = fresh from the internet; saved = last known route; none = no steps.
  final RouteSource source;
  final RoutePlan? plan;
  final DateTime? savedAt;

  /// Message for the user, e.g. "Route saved 1 min ago - showing last known route".
  final String? notice;

  /// Fallback: opens Google Maps.
  final String directionsUrl;
}

/// "Emergency Evacuation": route to the nearest open relief centre,
/// with the last route kept for offline use.
class EvacuationRouteService {
  EvacuationRouteService({
    required this.evacuation,
    required this.provider,
    required this.store,
    DateTime Function()? clock,
    this.reuseWithinKm = 1.0,
  }) : _clock = clock ?? DateTime.now;
  final EvacuationService evacuation;
  final RouteProvider provider;
  final RouteStore store;
  final DateTime Function() _clock;

  /// A saved route is only reused if the user is still this close to where it started.
  final double reuseWithinKm;

  /// Returns null when no relief centre is open with space.
  /// "Nearest" is by straight line; the route itself follows roads.
  Future<EvacuationRoute?> toNearest(GeoPoint user) async {
    final near = await evacuation.nearest(user, limit: 1);
    if (near.isEmpty) return null;
    final centre = near.first.point;
    final km = near.first.distanceKm;
    final url = evacuation.directionsUrl(centre.location, from: user);
    try {
      final plan = await provider.route(user, centre.location);
      final now = _clock();
      await _save(centre, plan, now);
      return EvacuationRoute(
          centre: centre, straightLineKm: km, source: RouteSource.live, plan: plan,
          savedAt: now, directionsUrl: url);
    } catch (_) {
      final saved = await _loadSaved(centre, user);
      if (saved != null) {
        final (plan, at) = saved;
        return EvacuationRoute(
            centre: centre, straightLineKm: km, source: RouteSource.saved, plan: plan,
            savedAt: at, directionsUrl: url,
            notice: 'Route saved ${_ago(_clock().difference(at))} ago - showing last known route');
      }
      return EvacuationRoute(
          centre: centre, straightLineKm: km, source: RouteSource.none, directionsUrl: url,
          notice: 'Step-by-step directions are not available right now');
    }
  }

  Future<void> _save(EvacuationPoint centre, RoutePlan plan, DateTime at) async {
    try {
      await store.save(jsonEncode(
          {'centreId': centre.id, 'savedAt': at.toUtc().toIso8601String(), 'plan': plan.toJson()}));
    } catch (_) {
      // Saving is a bonus; a full phone must not block the live route.
    }
  }

  Future<(RoutePlan, DateTime)?> _loadSaved(EvacuationPoint centre, GeoPoint user) async {
    try {
      final raw = await store.load();
      if (raw == null) return null;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j['centreId'] != centre.id) return null;
      final plan = RoutePlan.fromJson(j['plan'] as Map<String, dynamic>);
      if (distanceKm(user, plan.from) > reuseWithinKm) return null;
      return (plan, DateTime.parse(j['savedAt'] as String));
    } catch (_) {
      return null; // damaged saved route: behave as if there is none
    }
  }

  String _ago(Duration d) {
    if (d.isNegative) return '0 min';
    if (d.inDays >= 1) return '${d.inDays} day(s)';
    if (d.inHours >= 1) return '${d.inHours} hour(s)';
    return '${d.inMinutes} min';
  }
}
