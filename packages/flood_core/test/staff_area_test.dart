import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';
import 'helpers.dart';

/// Round 5: staff work only inside their own area.
/// Coordinator = one district; Field Officer = one resource point (and the
/// centres it supplies); Super Admin = everywhere. Mirrors
/// supabase/staff_districts.sql.
void main() {
  late World w;
  late ResourcePoint mine; // res-1, KLANG: the test officer's point
  late ResourcePoint other; // res-2, SEPANG
  setUp(() async {
    w = World();
    mine = await w.resources.addPoint(admin, district: kDistrict, name: 'Klang Depot', location: GeoPoint(3.04, 101.45));
    other = await w.resources.addPoint(admin, district: kOtherDistrict, name: 'Sepang Depot', location: GeoPoint(2.69, 101.75));
  });

  group('TP63 District names', () {
    test('the nine Selangor districts, in the JPS spelling', () {
      expect(selangorDistricts, hasLength(9));
      expect(normaliseDistrict('  hulu   langat '), 'HULU LANGAT');
      expect(normaliseDistrict('Segamat'), isNull);
      expect(normaliseDistrict(null), isNull);
    });
    test('a session knows its area', () {
      expect(admin.district, isNull);
      expect(coordinator.district, kDistrict);
      expect(officer.district, kDistrict);
      expect(admin.coversDistrict(null), isTrue);
      expect(coordinator.coversDistrict(null), isFalse);
      expect(coordinator.coversDistrict(kOtherDistrict), isFalse);
      // A coordinator with no district (old data) sees nothing rather than everything.
      expect(sess(StaffRole.coordinator).coversDistrict(null), isFalse);
    });
  });

  group('TP64 Resource points, stock and centres by area', () {
    test('coordinator: lists and adds only in their own district', () async {
      expect([for (final p in await w.resources.listPoints(coordinator)) p.name], ['Klang Depot']);
      final p = await w.resources.addPoint(coordinator, name: 'Klang Store', location: GeoPoint(3, 101.4));
      expect(p.district, kDistrict);
      await expectLater(
          w.resources.addPoint(coordinator, district: kOtherDistrict, name: 'X', location: GeoPoint(3, 101)),
          throwsA(isA<PermissionDeniedException>()));
      await expectLater(w.resources.removePoint(coordinator, other.id), throwsA(isA<PermissionDeniedException>()));
      expect(await w.resources.listPoints(admin), hasLength(3));
    });
    test('super admin must choose a known district', () async {
      await expectLater(w.resources.addPoint(admin, name: 'X', location: GeoPoint(3, 101)),
          throwsA(isA<ValidationException>()));
      await expectLater(w.resources.addPoint(admin, district: 'Atlantis', name: 'X', location: GeoPoint(3, 101)),
          throwsA(isA<ValidationException>()));
      expect((await w.resources.addPoint(admin, district: 'sepang', name: 'X', location: GeoPoint(3, 101))).district,
          'SEPANG');
    });
    test('field officer: stock only at their own point', () async {
      final a = await w.resources.addItem(officer, resourcePointId: mine.id, name: 'Rice', quantity: 5);
      await expectLater(w.resources.addItem(officer, resourcePointId: other.id, name: 'Rice', quantity: 5),
          throwsA(isA<PermissionDeniedException>()));
      final b = await w.resources.addItem(admin, resourcePointId: other.id, name: 'Water', quantity: 5);
      await expectLater(w.resources.setQuantity(officer, b.id, 1), throwsA(isA<PermissionDeniedException>()));
      expect([for (final i in await w.resources.listItems(officer)) i.id], [a.id]);
      expect(await w.resources.listItems(admin), hasLength(2));
    });
    test('coordinator cannot map stock in another district', () async {
      final b = await w.resources.addItem(admin, resourcePointId: other.id, name: 'Water', quantity: 5);
      await expectLater(w.resources.mapItem(coordinator, b.id, null), throwsA(isA<PermissionDeniedException>()));
    });
    test('expiry and supply alerts only cover the area', () async {
      final water = await w.resources.addCatalogueUnit(admin, name: 'Water', unit: 'l', dailyNeedPerPerson: 3);
      for (final p in [mine, other]) {
        final hall = await w.evacuation.add(admin, district: p.district, name: 'Hall ${p.name}',
            location: p.location, capacity: 10, resourcePointId: p.id);
        await w.evacuation.setOccupancy(admin, hall.id, 10);
        final i = await w.resources.addItem(admin, resourcePointId: p.id, name: 'Water', quantity: 1,
            expiryDate: kNow.add(const Duration(days: 2)));
        await w.resources.mapItem(admin, i.id, water.id);
      }
      expect(await w.resources.supplyAlerts(admin), hasLength(2));
      expect([for (final a in await w.resources.supplyAlerts(coordinator)) a.point.name], ['Klang Depot']);
      expect([for (final a in await w.resources.supplyAlerts(officer)) a.point.name], ['Klang Depot']);
      expect(await w.resources.expiringItems(coordinator), hasLength(1));
    });
    test('centres: coordinator by district, field officer by supplying point', () async {
      final k = await w.evacuation.add(coordinator, name: 'Dewan Klang', location: GeoPoint(3.04, 101.44), capacity: 50,
          resourcePointId: mine.id);
      expect(k.district, kDistrict);
      final s = await w.evacuation.add(admin, district: kOtherDistrict, name: 'Dewan Sepang', location: GeoPoint(2.7, 101.7),
          capacity: 50, resourcePointId: other.id);
      final k2 = await w.evacuation.add(coordinator, name: 'Dewan Klang 2', location: GeoPoint(3.05, 101.44), capacity: 50);
      await expectLater(
          w.evacuation.add(coordinator, district: kOtherDistrict, name: 'X', location: GeoPoint(2.7, 101.7), capacity: 5),
          throwsA(isA<PermissionDeniedException>()));
      await expectLater(w.evacuation.remove(coordinator, s.id), throwsA(isA<PermissionDeniedException>()));
      await expectLater(w.evacuation.setOccupancy(coordinator, s.id, 1), throwsA(isA<PermissionDeniedException>()));
      expect((await w.evacuation.setOccupancy(officer, k.id, 3)).occupancy, 3);
      // In the officer's district, but not supplied by their point.
      await expectLater(w.evacuation.setOpen(officer, k2.id, false), throwsA(isA<PermissionDeniedException>()));
      await expectLater(w.evacuation.setOccupancy(officer, s.id, 1), throwsA(isA<PermissionDeniedException>()));
      expect([for (final c in await w.evacuation.listForStaff(coordinator)) c.name]..sort(), ['Dewan Klang', 'Dewan Klang 2']);
      expect([for (final c in await w.evacuation.listForStaff(officer)) c.name], ['Dewan Klang']);
      expect(await w.evacuation.listForStaff(admin), hasLength(3));
      // The public list is never limited.
      expect(await w.evacuation.listAll(), hasLength(3));
    });
    test('operations map shows only the area', () async {
      await w.evacuation.add(admin, district: kDistrict, name: 'Dewan Klang', location: GeoPoint(3.04, 101.44), capacity: 5);
      await w.evacuation.add(admin, district: kOtherDistrict, name: 'Dewan Sepang', location: GeoPoint(2.7, 101.7), capacity: 5);
      final m = await w.map.operationsMap(coordinator);
      final names = [for (final x in m.markers) if (x.kind != MarkerKind.station) x.title]..sort();
      expect(names, ['Dewan Klang', 'Klang Depot']);
    });
  });

  group('TP65 Damage reports by area', () {
    test('district comes from the locator; staff see their district only', () async {
      final k = await w.report(by: 'a');
      w.reportDistrict = kOtherDistrict;
      final s = await w.report(by: 'b');
      w.reportDistrict = null;
      final none = await w.report(by: 'c');
      expect([k.district, s.district, none.district], [kDistrict, kOtherDistrict, null]);
      expect([for (final r in await w.reports.list(officer)) r.id], [k.id]);
      expect([for (final r in await w.reports.list(coordinator)) r.id], [k.id]);
      expect(await w.reports.list(admin), hasLength(3));
      expect((await w.reports.counts(coordinator))[ReportStatus.pending], 1);
    });
    test('field officers cannot review; coordinators only in their district', () async {
      final k = await w.report(by: 'a');
      w.reportDistrict = kOtherDistrict;
      final s = await w.report(by: 'b');
      await expectLater(w.reports.verify(officer, k.id), throwsA(isA<PermissionDeniedException>()));
      await expectLater(w.reports.verify(coordinator, s.id), throwsA(isA<PermissionDeniedException>()));
      await expectLater(w.reports.markDuplicate(coordinator, k.id, ofId: s.id),
          throwsA(isA<PermissionDeniedException>()));
      expect((await w.reports.verify(coordinator, k.id)).status, ReportStatus.verified);
      expect((await w.reports.verify(admin, s.id)).status, ReportStatus.verified);
    });
    test('the district survives a review', () async {
      final k = await w.report(by: 'a');
      expect((await w.reports.verify(coordinator, k.id)).district, kDistrict);
    });
    test('a failing locator does not block the report', () async {
      final reports = DamageReportService(
          reports: MemoryTable<DamageReport>(), newId: sequentialIds('r'), clock: fixedClock,
          locateDistrict: (_) async => throw StateError('offline'));
      final r = await reports.submit(reporterId: 'a', location: GeoPoint(3, 101.4), incidentDate: kNow,
          type: DamageType.house, severity: DamageSeverity.minor);
      expect(r.district, isNull);
    });
  });

  group('TP66 District from the nearest station', () {
    final repo = FakeRepository([
      st('K', district: 'Klang', state: 'Selangor', loc: GeoPoint(3.04, 101.45)),
      st('S', district: 'SEPANG', state: 'Selangor', loc: GeoPoint(2.69, 101.75)),
      st('J', district: 'Segamat', state: 'Johor', loc: GeoPoint(3.05, 101.46)), // not Selangor: ignored
      st('N', district: 'KLANG', state: 'Selangor'), // no position: ignored
    ], []);
    final locate = nearestStationDistrict(repo);
    test('nearest Selangor station within 25 km', () async {
      expect(await locate(GeoPoint(3.05, 101.46)), 'KLANG');
      expect(await locate(GeoPoint(2.70, 101.74)), 'SEPANG');
    });
    test('nothing within 25 km gives no district', () async {
      expect(await locate(GeoPoint(4.5, 101.0)), isNull);
    });
  });

  group('TP67 Staff overview by area', () {
    test('a coordinator sees warnings in their own district only', () async {
      final repo = FakeRepository([
        st('K', district: 'KLANG', state: 'Selangor', loc: GeoPoint(3.04, 101.45)),
        st('S', district: 'SEPANG', state: 'Selangor', loc: GeoPoint(2.69, 101.75)),
      ], [rd('K', river: 13), rd('S', river: 15)]);
      final x = World(repo: repo);
      expect([for (final s in (await x.overview.load(coordinator)).riskNearby) s.station.id], ['K']);
      expect((await x.overview.load(admin)).riskNearby, hasLength(2));
    });
  });
}
