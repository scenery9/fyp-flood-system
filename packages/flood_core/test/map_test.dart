import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';
import 'helpers.dart';

void main() {
  late World w;
  setUp(() async {
    w = World();
    await w.evacuation.add(admin, name: 'Open Hall', location: GeoPoint(2.52, 102.82), capacity: 10);
    await w.evacuation.add(admin, name: 'Full Hall', location: GeoPoint(2.53, 102.83), capacity: 5);
    await w.evacuation.add(admin, name: 'Closed Hall', location: GeoPoint(2.54, 102.84), capacity: 5);
    await w.evacuation.setOccupancy(admin, 'evac-2', 5);
    await w.evacuation.setOpen(admin, 'evac-3', false);
    await w.resources.addPoint(admin, name: 'Depot', location: GeoPoint(2.51, 102.81));
  });
  Map<String, MapMarker> byId(MapData d) => {for (final m in d.markers) m.id: m};

  group('TP33 Live map (public)', () {
    test('stations are styled by risk; one without coordinates is counted, not drawn', () async {
      final d = await w.map.liveMap();
      final m = byId(d);
      expect(m['JHR-AWAT']!.style, MarkerStyle.stationDanger);
      expect(m['JHR-SEGKECIL']!.style, MarkerStyle.stationWarning);
      expect(m['JHR-BULOH']!.style, MarkerStyle.stationAlert);
      expect(m['SGR-KAJANG']!.style, MarkerStyle.stationNormal);
      expect(m['JHR-CHAAH'], isNull);
      expect(d.hiddenWithoutLocation, 1);
      expect(m['JHR-AWAT']!.subtitle, 'Danger - 19.97 m - 10 min ago');
    });
    test('old data and offline sensors are shown as unknown, never as a risk colour', () async {
      final m = byId(await w.map.liveMap());
      expect(m['SGR-RANTAU']!.style, MarkerStyle.stationUnknown);
      expect(m['SGR-RANTAU']!.subtitle, 'Old data');
      expect(m['MLK-HAMPAR']!.style, MarkerStyle.stationUnknown);
      expect(m['MLK-DURIAN']!.subtitle, 'No river data');
    });
    test('open and full centres are shown, closed ones are hidden', () async {
      final m = byId(await w.map.liveMap());
      expect(m['evac-1']!.style, MarkerStyle.shelterOpen);
      expect(m['evac-1']!.subtitle, 'Open - 10 places left');
      expect(m['evac-2']!.style, MarkerStyle.shelterFull);
      expect(m['evac-3'], isNull);
      expect(m['res-1'], isNull); // warehouses are staff-only
    });
    test('layer switches and state filter', () async {
      expect((await w.map.liveMap(showEvacuation: false)).markers, hasLength(7));
      expect((await w.map.liveMap(showStations: false)).markers, hasLength(2));
      expect((await w.map.liveMap(state: 'melaka', showEvacuation: false)).markers, hasLength(2));
      expect((await w.map.liveMap(state: 'Perak', showEvacuation: false)).markers, isEmpty);
    });
    test('user marker is added when location is known', () async {
      final d = await w.map.liveMap(user: GeoPoint(1.5, 103.7));
      expect(byId(d)['user']!.style, MarkerStyle.user);
      expect(d.bounds!.contains(GeoPoint(1.5, 103.7)), isTrue);
    });
    test('bounds contain every marker with a margin; nothing to show gives no bounds', () async {
      final d = await w.map.liveMap();
      for (final m in d.markers) {
        expect(d.bounds!.contains(m.position), isTrue);
      }
      expect(d.bounds!.south, lessThan(2.233));
      expect((await w.map.liveMap(showStations: false, showEvacuation: false)).bounds, isNull);
    });
    test('a single marker still gets a usable area', () async {
      final one = World(repo: FakeRepository([st('A', loc: GeoPoint(2, 102))], [rd('A', river: 11)]));
      final b = (await one.map.liveMap()).bounds!;
      expect(b.north - b.south, closeTo(0.02, 1e-9));
      expect(b.center.lat, closeTo(2, 1e-9));
    });
    test('markers at the edge of the world do not produce invalid bounds', () async {
      final edge = World(repo: FakeRepository([st('A', loc: GeoPoint(90, 180))], [rd('A', river: 11)]));
      final b = (await edge.map.liveMap()).bounds!;
      expect(b.north, 90.0);
      expect(b.east, 180.0);
    });
  });

  group('TP34 Operations map (staff)', () {
    test('staff only', () async {
      await expectLater(w.map.operationsMap(null), throwsA(isA<NotSignedInException>()));
    });
    test('all shelters with status, warehouses, and only stations at Alert or above', () async {
      final d = await w.map.operationsMap(officer);
      final m = byId(d);
      expect(m['evac-1']!.style, MarkerStyle.shelterOpen);
      expect(m['evac-2']!.style, MarkerStyle.shelterFull);
      expect(m['evac-3']!.style, MarkerStyle.shelterClosed);
      expect(m['evac-2']!.subtitle, 'Open - 5/5 people');
      expect(m['res-1']!.style, MarkerStyle.warehouse);
      expect([for (final x in d.markers) if (x.kind == MarkerKind.station) x.id],
          ['JHR-AWAT', 'JHR-BULOH', 'JHR-SEGKECIL']);
      expect(m['SGR-KAJANG'], isNull);
      expect(m['SGR-RANTAU'], isNull);
    });
  });
}
