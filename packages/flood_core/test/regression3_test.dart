import 'dart:io';

import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';
import 'helpers.dart';
import 'forecast_test.dart' show FakeSource;
import 'routing_test.dart' show FakeProvider;

/// Round 3 whole-flow tests: forecast, map and routing next to everything else.
void main() {
  late World w;
  setUp(() => w = World());
  List<String> ids(List<StationStatus> l) => [for (final s in l) s.station.id];

  group('TP40 Regression: forecast, map and routing with the rest', () {
    test('loading forecasts never changes current statuses, warnings or Home', () async {
      final followed = FollowedAreasService(store: InMemoryFollowedStore(), repository: w.repo);
      final home = HomeService(monitoring: w.monitoring, followed: followed);
      final before = await w.monitoring.loadStatuses();
      final warnBefore = ids(const WarningService().active(before));
      final homeBefore = ids((await home.load()).highRisk);

      final body = File('test/fixtures/forecast_practice.json').readAsStringSync();
      final r = await ForecastService(source: FakeSource(body), clock: fixedClock).load(before);
      expect(r.forecasts, isNotEmpty);

      final after = await w.monitoring.loadStatuses();
      expect([for (final s in after) s.level], [for (final s in before) s.level]);
      expect(ids(const WarningService().active(after)), warnBefore);
      expect(ids((await home.load()).highRisk), homeBefore);
    });
    test('a broken forecast leaves the rest of the app working', () async {
      final r = await ForecastService(source: FakeSource('<<broken>>'), clock: fixedClock)
          .load(await w.monitoring.loadStatuses());
      expect(r.forecasts, isEmpty);
      expect(await w.monitoring.loadStatuses(), hasLength(8));
      expect((await w.assistant.ask('status segamat')).intent, AssistantIntent.stationStatus);
    });
    test('map risk markers match the Warnings list', () async {
      final warned = ids(const WarningService().active(await w.monitoring.loadStatuses())).toSet();
      final map = await w.map.liveMap(showEvacuation: false);
      final risky = {
        for (final m in map.markers)
          if ({MarkerStyle.stationAlert, MarkerStyle.stationWarning, MarkerStyle.stationDanger}.contains(m.style)) m.id,
      };
      expect(risky, hasLength(3));
      expect(risky.difference(warned), isEmpty);
    });
    test('staff changes show up on the map, the route and the assistant together', () async {
      final here = GeoPoint(2.50, 102.80);
      final routes = EvacuationRouteService(
          evacuation: w.evacuation, provider: FakeProvider(), store: InMemoryRouteStore(), clock: fixedClock);
      expect(await routes.toNearest(here), isNull);

      final hall = await w.evacuation.add(coordinator, name: 'Dewan A', location: GeoPoint(2.52, 102.82), capacity: 2);
      expect((await routes.toNearest(here))!.centre.name, 'Dewan A');
      expect((await w.map.liveMap(showStations: false)).markers.single.style, MarkerStyle.shelterOpen);
      expect((await w.assistant.ask('nearest shelter', userLocation: here)).text, contains('Dewan A'));

      await w.evacuation.setOccupancy(officer, hall.id, 2); // now full
      expect(await routes.toNearest(here), isNull);
      expect((await w.map.liveMap(showStations: false)).markers.single.style, MarkerStyle.shelterFull);
      expect((await w.assistant.ask('nearest shelter', userLocation: here)).text, contains('No relief centre'));
    });
    test('operations map and staff overview agree on shelters', () async {
      await w.evacuation.add(admin, name: 'A', location: GeoPoint(2.5, 102.8), capacity: 5);
      final b = await w.evacuation.add(admin, name: 'B', location: GeoPoint(2.6, 102.9), capacity: 5);
      await w.evacuation.setOpen(admin, b.id, false);
      final o = await w.overview.load(admin);
      final m = await w.map.operationsMap(admin);
      expect(o.sheltersOpen, m.markers.where((x) => x.style == MarkerStyle.shelterOpen).length);
      expect(m.markers.where((x) => x.style == MarkerStyle.shelterClosed), hasLength(1));
    });
  });
}
