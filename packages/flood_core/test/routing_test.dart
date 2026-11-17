import 'dart:convert';

import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';
import 'helpers.dart';

/// A cut-down openrouteservice reply (GeoJSON), in the documented shape.
String orsReply() => jsonEncode({
      'type': 'FeatureCollection',
      'features': [
        {
          'type': 'Feature',
          'properties': {
            'summary': {'distance': 15300.5, 'duration': 780.0},
            'segments': [
              {
                'steps': [
                  {'distance': 200.0, 'duration': 30.0, 'instruction': 'Head south', 'name': 'Jalan A'},
                  {'distance': 15000.0, 'duration': 720.0, 'instruction': 'Turn right onto Jalan B'},
                  {'distance': 0.0, 'duration': 0.0, 'instruction': 'Arrive at your destination'},
                ],
              },
            ],
          },
          'geometry': {
            'type': 'LineString',
            'coordinates': [[102.80, 2.50], [102.81, 2.51, 12.0], [102.82, 2.52]],
          },
        },
      ],
    });

class FakeProvider implements RouteProvider {
  bool fail = false;
  int calls = 0;
  @override
  Future<RoutePlan> route(GeoPoint from, GeoPoint to) async {
    calls++;
    if (fail) throw RoutingException('offline');
    return parseOrsDirections(orsReply(), from: from, to: to);
  }
}

class BrokenStore implements RouteStore {
  @override
  Future<String?> load() async => throw StateError('disk');
  @override
  Future<void> save(String value) async => throw StateError('disk full');
}

void main() {
  final from = GeoPoint(2.50, 102.80), to = GeoPoint(2.52, 102.82);

  group('TP31 openrouteservice', () {
    test('request address puts longitude first and carries the key', () {
      final uri = OrsRouteProvider(apiKey: 'KEY', get: (_) async => '').buildUri(from, to);
      expect(uri.host, 'api.openrouteservice.org');
      expect(uri.path, '/v2/directions/driving-car');
      expect(uri.queryParameters['start'], '102.8,2.5');
      expect(uri.queryParameters['end'], '102.82,2.52');
      expect(uri.queryParameters['api_key'], 'KEY');
    });
    test('reply is turned into distance, time, steps and a path', () {
      final p = parseOrsDirections(orsReply(), from: from, to: to);
      expect(p.distanceKm, closeTo(15.3, 0.01));
      expect(p.durationMin, 13);
      expect([for (final s in p.steps) s.instruction],
          ['Head south', 'Turn right onto Jalan B', 'Arrive at your destination']);
      expect(p.path, hasLength(3));
      expect(p.path.first.lat, 2.50); // converted back to latitude first
      expect(p.path.first.lon, 102.80);
    });
    test('provider fetches and parses', () async {
      Uri? seen;
      final provider = OrsRouteProvider(apiKey: 'KEY', get: (u) async {
        seen = u;
        return orsReply();
      });
      expect((await provider.route(from, to)).steps, hasLength(3));
      expect(seen!.queryParameters['start'], '102.8,2.5');
    });
    test('network failure, missing key and error replies become RoutingException', () async {
      final down = OrsRouteProvider(apiKey: 'KEY', get: (_) async => throw StateError('no internet'));
      await expectLater(down.route(from, to), throwsA(isA<RoutingException>()));
      final noKey = OrsRouteProvider(apiKey: ' ', get: (_) async => orsReply());
      await expectLater(noKey.route(from, to), throwsA(isA<RoutingException>()));
      for (final bad in [
        'not json', '[]', '{}', '{"features": []}',
        '{"error": {"code": 2010, "message": "Could not find routable point"}}',
        '{"error": "Daily quota reached"}',
        '{"features": [{"geometry": {"coordinates": [["x", "y"]]}}]}',
      ]) {
        expect(() => parseOrsDirections(bad, from: from, to: to), throwsA(isA<RoutingException>()));
      }
    });
    test('a saved route survives being written and read back', () {
      final p = parseOrsDirections(orsReply(), from: from, to: to);
      final back = RoutePlan.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(back.distanceM, p.distanceM);
      expect(back.steps.last.instruction, 'Arrive at your destination');
      expect(back.path.last.lon, 102.82);
      expect(back.from.lat, 2.50);
    });
  });

  group('TP32 Evacuation route (live, saved, none)', () {
    late World w;
    late FakeProvider provider;
    late InMemoryRouteStore store;
    late EvacuationRouteService svc;
    var now = kNow;
    setUp(() async {
      now = kNow;
      w = World();
      provider = FakeProvider();
      store = InMemoryRouteStore();
      svc = EvacuationRouteService(
          evacuation: w.evacuation, provider: provider, store: store, clock: () => now);
      await w.evacuation.add(admin, name: 'Near Hall', location: to, capacity: 10);
      await w.evacuation.add(admin, name: 'Far Hall', location: GeoPoint(3.5, 103.5), capacity: 10);
    });

    test('online: live route to the nearest centre', () async {
      final r = (await svc.toNearest(from))!;
      expect(r.source, RouteSource.live);
      expect(r.centre.name, 'Near Hall');
      expect(r.plan!.steps, hasLength(3));
      expect(r.notice, isNull);
      expect(r.straightLineKm, closeTo(3.14, 0.05));
      expect(r.directionsUrl, contains('destination=2.52,102.82'));
    });
    test('offline after a live route: last known route with its age', () async {
      await svc.toNearest(from);
      provider.fail = true;
      now = kNow.add(const Duration(minutes: 1));
      final r = (await svc.toNearest(from))!;
      expect(r.source, RouteSource.saved);
      expect(r.plan!.steps, hasLength(3));
      expect(r.notice, 'Route saved 1 min ago - showing last known route');
      expect(r.savedAt, kNow);
    });
    test('offline with nothing saved: no steps, Google Maps link still given', () async {
      provider.fail = true;
      final r = (await svc.toNearest(from))!;
      expect(r.source, RouteSource.none);
      expect(r.plan, isNull);
      expect(r.directionsUrl, contains('google.com/maps'));
      expect(r.notice, isNotNull);
    });
    test('saved route is not reused after the user has moved far away', () async {
      await svc.toNearest(from);
      provider.fail = true;
      expect((await svc.toNearest(GeoPoint(2.50, 102.805)))!.source, RouteSource.saved); // ~0.5 km
      expect((await svc.toNearest(GeoPoint(2.50, 102.78)))!.source, RouteSource.none); // ~2 km
    });
    test('saved route is not reused when the nearest centre changes', () async {
      await svc.toNearest(from);
      await w.evacuation.setOpen(admin, 'evac-1', false); // Near Hall closes
      provider.fail = true;
      final r = (await svc.toNearest(from))!;
      expect(r.centre.name, 'Far Hall');
      expect(r.source, RouteSource.none);
    });
    test('no open centre gives null and does not call the routing service', () async {
      await w.evacuation.setOpen(admin, 'evac-1', false);
      await w.evacuation.setOpen(admin, 'evac-2', false);
      expect(await svc.toNearest(from), isNull);
      expect(provider.calls, 0);
    });
    test('damaged saved route is ignored', () async {
      await store.save('{"centreId": "evac-1", "plan": "garbage"}');
      provider.fail = true;
      expect((await svc.toNearest(from))!.source, RouteSource.none);
    });
    test('a storage failure does not block the live route', () async {
      final s = EvacuationRouteService(
          evacuation: w.evacuation, provider: provider, store: BrokenStore(), clock: () => now);
      expect((await s.toNearest(from))!.source, RouteSource.live);
      provider.fail = true;
      expect((await s.toNearest(from))!.source, RouteSource.none);
    });
  });
}
