import 'dart:convert';

import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';
import 'helpers.dart';

/// Round 8: relief centres from Supabase (uploaded from places/centres.csv),
/// unchecked positions, estimated capacity, and Melaka.
void main() {
  Map<String, Object?> centre(String id,
          {String name = 'Hall', Object? lat = 3.135347, Object? lon = 101.380869, Object? capacity = 250,
          Object? occupancy = 0, Object? isOpen = true, Object? checked = true, Object? estimated = true,
          String district = 'KLANG'}) =>
      {
        'id': id, 'code': 'PPS-$id', 'name': '$name $id', 'lat': lat, 'lon': lon, 'capacity': capacity,
        'occupancy': occupancy, 'is_open': isOpen, 'district': district, 'resource_point_id': null,
        'location_checked': checked, 'capacity_estimated': estimated,
      };

  group('TP89 Relief centres from Supabase', () {
    test('centres load with checked position and estimated capacity', () async {
      final http = FakeHttp()
        ..reply('/rest/v1/evacuation_points', 200, jsonEncode([centre('A'), centre('B', checked: false, estimated: false)]));
      final table = LiveCentreTable(http.api(signedIn: false), store: InMemorySettingsStore(), clock: fixedClock);
      final rows = {for (final p in await table.all()) p.id: p};
      expect([rows['A']!.location.lat, rows['A']!.location.lon], [3.135347, 101.380869]);
      expect(rows['A']!.capacityEstimated, isTrue);
      expect(rows['A']!.locationChecked, isTrue);
      expect(rows['B']!.locationChecked, isFalse);
      expect(rows['B']!.capacityEstimated, isFalse);
      expect(http.calls.single.uri.queryParameters['select'], '*');
      expect(http.calls.single.headers.containsKey('Authorization'), isFalse); // public, no sign-in needed
    });
    test('rows from before places.sql (no new columns) count as checked, not estimated', () async {
      final old = {'id': 'X', 'name': 'Old Hall', 'lat': 3.0, 'lon': 101.5, 'capacity': 100, 'occupancy': 10, 'is_open': true};
      final p = LiveCentreTable.centreFromRow(old)!;
      expect(p.locationChecked, isTrue);
      expect(p.capacityEstimated, isFalse);
      expect(p.occupancy, 10);
    });
    test('broken rows are left out, not guessed', () {
      expect(LiveCentreTable.centreFromRow(centre('A', lat: null)), isNull);
      expect(LiveCentreTable.centreFromRow(centre('A', lat: 95)), isNull);
      expect(LiveCentreTable.centreFromRow(centre('A', capacity: 0)), isNull);
      expect(LiveCentreTable.centreFromRow({'id': '', 'name': 'x', 'lat': 3, 'lon': 101, 'capacity': 5}), isNull);
      expect(LiveCentreTable.centreFromRow(centre('A', occupancy: 999))!.occupancy, 250); // never above capacity
    });
    test('without internet the last list kept on the phone is used', () async {
      final store = InMemorySettingsStore();
      final http = FakeHttp()..reply('/rest/v1/evacuation_points', 200, jsonEncode([centre('A')]));
      var now = kNow;
      final table = LiveCentreTable(http.api(signedIn: false), store: store, clock: () => now);
      await table.all();
      expect(table.fromPhone, isFalse);
      http.offline = true;
      now = now.add(const Duration(minutes: 5));
      final rows = await table.all();
      expect(rows.single.id, 'A');
      expect(table.fromPhone, isTrue);
    });
    test('no internet and nothing kept: the error is passed on', () async {
      final http = FakeHttp()..offline = true;
      final table = LiveCentreTable(http.api(signedIn: false), store: InMemorySettingsStore({'rows': 'not json'}));
      await expectLater(table.all(), throwsA(isA<SupabaseException>()));
    });
    test('the list is reused for a minute', () async {
      final http = FakeHttp()..reply('/rest/v1/evacuation_points', 200, jsonEncode([centre('A')]));
      var now = kNow;
      final table = LiveCentreTable(http.api(signedIn: false), store: InMemorySettingsStore(), clock: () => now);
      await table.all();
      await table.byId('A');
      expect(http.calls, hasLength(1));
      now = now.add(const Duration(seconds: 61));
      await table.all();
      expect(http.calls, hasLength(2));
    });
    test('the public app cannot change centres', () async {
      final table = LiveCentreTable(FakeHttp().api(signedIn: false), store: InMemorySettingsStore());
      expect(() => table.remove('A'), throwsUnsupportedError);
      final p = EvacuationPoint(id: 'A', name: 'A', location: GeoPoint(3, 101.5), capacity: 10);
      expect(() => table.put('A', p), throwsUnsupportedError);
    });
    test('nearest centres work on the live list', () async {
      final http = FakeHttp()
        ..reply('/rest/v1/evacuation_points', 200,
            jsonEncode([centre('FAR', lat: 3.5, lon: 101.1), centre('NEAR', lat: 3.01, lon: 101.41)]));
      final service = EvacuationService(
          points: LiveCentreTable(http.api(signedIn: false), store: InMemorySettingsStore(), clock: fixedClock),
          newId: sequentialIds());
      final list = await service.nearest(GeoPoint(3.0, 101.4), limit: 5, includeUnavailable: true);
      expect([for (final n in list) n.point.id], ['NEAR', 'FAR']);
    });
    test('copyWith keeps the new fields', () {
      final p = EvacuationPoint(
          id: 'A', name: 'A', location: GeoPoint(3, 101.5), capacity: 10, locationChecked: false, capacityEstimated: true);
      final q = p.copyWith(occupancy: 3);
      expect(q.locationChecked, isFalse);
      expect(q.capacityEstimated, isTrue);
    });
  });

  group('TP90 Melaka', () {
    test('Melaka districts are known, Selangor stays nine', () {
      expect(selangorDistricts, hasLength(9));
      expect(melakaDistricts, ['ALOR GAJAH', 'JASIN', 'MELAKA TENGAH']);
      expect(normaliseDistrict(' melaka  tengah'), 'MELAKA TENGAH');
      expect(stateOfDistrict('Jasin'), 'Melaka');
      expect(stateOfDistrict('KLANG'), 'Selangor');
      expect(stateOfDistrict('Segamat'), isNull);
    });
    test('live stations say which state they are in', () async {
      final http = FakeHttp()
        ..reply('/rest/v1/jps_latest', 200, jsonEncode([
          {'station_code': '0290211WL', 'name': 'Sg. Melaka di Melaka Pindah', 'district': 'ALOR GAJAH',
           'lat': 2.37349, 'lon': 102.22111, 'state': 'Melaka'},
          {'station_code': 'BKLG0002L', 'name': 'Taman Sri Muda', 'district': 'KLANG', 'lat': 3.04, 'lon': 101.53},
        ]));
      final repo = LiveStationRepository(http.api(signedIn: false), clock: fixedClock);
      final byId = {for (final s in await repo.getStations()) s.id: s};
      expect(byId['0290211WL']!.state, 'Melaka');
      expect(byId['BKLG0002L']!.state, 'Selangor'); // logged before Melaka was added
    });
    test('a Super Admin can place a resource point in a Melaka district', () {
      final admin = StaffSession(StaffAccount(
          id: 'a', fullName: 'A', username: 'admin', role: StaffRole.superAdmin));
      expect(ResourceService.pickDistrict(admin, 'jasin'), 'JASIN');
    });
  });

  group('TP92 Route guide: one highlighted step', () {
    RoutePlan plan({bool withPositions = true}) {
      final path = [for (var i = 0; i < 6; i++) GeoPoint(2.5 + i * 0.01, 102.8)];
      RouteStep st(String t, int w) => RouteStep(instruction: t, distanceM: 100, durationS: 10, wayPoint: withPositions ? w : null);
      return RoutePlan(from: path.first, to: path.last, distanceM: 300, durationS: 30, path: path,
          steps: [st('Head north', 0), st('Turn left', 2), st('Arrive', 5)]);
    }

    test('each step has its own stretch of road', () {
      final p = plan();
      expect(stepPath(p, 0), p.path.sublist(0, 3));
      expect(stepPath(p, 1), p.path.sublist(2, 6));
      expect(stepPath(p, 2), isNull); // "Arrive" is a point, not a stretch
      expect(stepPath(p, 5), isNull);
      expect(stepPath(plan(withPositions: false), 0), isNull); // old saved routes
    });

    test('follows the phone until the user chooses a step', () {
      final f = StepFocus(3);
      expect(f.index, 0);
      expect(f.follow(1), isTrue);
      expect(f.index, 1);
      expect(f.next(), isTrue);
      expect(f.index, 2);
      expect(f.manual, isTrue);
      expect(f.follow(0), isFalse); // the user's choice stays
      expect(f.index, 2);
    });

    test('Next and Back stop at the ends; tapping a step jumps to it', () {
      final f = StepFocus(3, start: 1);
      expect(f.back(), isTrue);
      expect(f.atFirst, isTrue);
      expect(f.back(), isFalse);
      expect(f.select(2), isTrue);
      expect(f.atLast, isTrue);
      expect(f.next(), isFalse);
      expect(f.select(7), isFalse);
      expect(f.index, 2);
    });

    test('a route with no steps does not break', () {
      final f = StepFocus(0);
      expect(f.next(), isFalse);
      expect(f.follow(3), isFalse);
      expect(f.index, 0);
    });
  });
}
