import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';
import 'helpers.dart';

void main() {
  late World w;
  late ResourcePoint depot;
  setUp(() async {
    w = World();
    depot = await w.resources.addPoint(admin, name: 'Segamat Depot', location: GeoPoint(2.51, 102.81));
  });
  DateTime inDays(int d) => kNow.add(Duration(days: d));

  group('TP25 Resource points and stock', () {
    test('who may add points', () async {
      await w.resources.addPoint(coordinator, name: 'Second', location: GeoPoint(2, 102));
      await expectLater(w.resources.addPoint(officer, name: 'Third', location: GeoPoint(2, 102)),
          throwsA(isA<PermissionDeniedException>()));
      await expectLater(w.resources.listPoints(null), throwsA(isA<NotSignedInException>()));
      expect(await w.resources.listPoints(officer), hasLength(2));
    });
    test('blank and duplicate names are refused', () async {
      await expectLater(w.resources.addPoint(admin, name: '', location: GeoPoint(2, 102)), throwsA(isA<ValidationException>()));
      await expectLater(w.resources.addPoint(admin, name: 'segamat depot', location: GeoPoint(2, 102)), throwsA(isA<ConflictException>()));
    });
    test('field officer can add stock and change quantity', () async {
      final i = await w.resources.addItem(officer, resourcePointId: depot.id, name: ' Rice 10kg ', quantity: 40);
      expect(i.name, 'Rice 10kg');
      expect((await w.resources.setQuantity(officer, i.id, 0)).quantity, 0.0);
    });
    test('bad stock input is refused', () async {
      await expectLater(w.resources.addItem(admin, resourcePointId: 'nope', name: 'x', quantity: 1), throwsA(isA<NotFoundException>()));
      await expectLater(w.resources.addItem(admin, resourcePointId: depot.id, name: ' ', quantity: 1), throwsA(isA<ValidationException>()));
      await expectLater(w.resources.addItem(admin, resourcePointId: depot.id, name: 'x', quantity: -1), throwsA(isA<ValidationException>()));
      await expectLater(w.resources.setQuantity(admin, 'nope', 1), throwsA(isA<NotFoundException>()));
      expect(await w.resources.listItems(admin), isEmpty);
    });
    test('a point with stock or a linked centre cannot be deleted', () async {
      final i = await w.resources.addItem(admin, resourcePointId: depot.id, name: 'Water', quantity: 1);
      await expectLater(w.resources.removePoint(admin, depot.id), throwsA(isA<ConflictException>()));
      await w.itemTable.remove(i.id);
      final e = await w.evacuation.add(admin, name: 'Hall', location: GeoPoint(2.5, 102.8), capacity: 10, resourcePointId: depot.id);
      await expectLater(w.resources.removePoint(admin, depot.id), throwsA(isA<ConflictException>()));
      await w.evacuation.remove(admin, e.id);
      await w.resources.removePoint(admin, depot.id);
      expect(await w.resources.listPoints(admin), isEmpty);
    });
    test('list stock for one point', () async {
      final other = await w.resources.addPoint(admin, name: 'Other', location: GeoPoint(2, 102));
      await w.resources.addItem(admin, resourcePointId: depot.id, name: 'A', quantity: 1);
      await w.resources.addItem(admin, resourcePointId: other.id, name: 'B', quantity: 1);
      expect(await w.resources.listItems(admin), hasLength(2));
      expect((await w.resources.listItems(admin, resourcePointId: other.id)).single.name, 'B');
    });
  });

  group('TP26 Map inventory to catalogue', () {
    test('map, unmap and the unmapped list', () async {
      final water = await w.resources.addCatalogueUnit(coordinator, name: 'Drinking water', unit: 'litre', dailyNeedPerPerson: 3);
      final i = await w.resources.addItem(admin, resourcePointId: depot.id, name: 'Water 1.5L', quantity: 10);
      expect(await w.resources.unmappedItems(admin), hasLength(1));
      expect((await w.resources.mapItem(coordinator, i.id, water.id)).catalogueUnitId, water.id);
      expect(await w.resources.unmappedItems(admin), isEmpty);
      expect((await w.resources.mapItem(coordinator, i.id, null)).catalogueUnitId, isNull);
    });
    test('field officer cannot map or add catalogue units', () async {
      final i = await w.resources.addItem(admin, resourcePointId: depot.id, name: 'x', quantity: 1);
      await expectLater(w.resources.mapItem(officer, i.id, null), throwsA(isA<PermissionDeniedException>()));
      await expectLater(w.resources.addCatalogueUnit(officer, name: 'a', unit: 'b', dailyNeedPerPerson: 1),
          throwsA(isA<PermissionDeniedException>()));
    });
    test('bad catalogue input and unknown ids', () async {
      await expectLater(w.resources.addCatalogueUnit(admin, name: 'a', unit: ' ', dailyNeedPerPerson: 1), throwsA(isA<ValidationException>()));
      await expectLater(w.resources.addCatalogueUnit(admin, name: 'a', unit: 'b', dailyNeedPerPerson: 0), throwsA(isA<ValidationException>()));
      final i = await w.resources.addItem(admin, resourcePointId: depot.id, name: 'x', quantity: 1);
      await expectLater(w.resources.mapItem(admin, i.id, 'nope'), throwsA(isA<NotFoundException>()));
      await expectLater(w.resources.mapItem(admin, 'nope', null), throwsA(isA<NotFoundException>()));
    });
  });

  group('TP27 Expiry and supply alerts', () {
    late CatalogueUnit water;
    late EvacuationPoint hall;
    setUp(() async {
      water = await w.resources.addCatalogueUnit(admin, name: 'Drinking water', unit: 'litre', dailyNeedPerPerson: 3);
      hall = await w.evacuation.add(admin, name: 'Hall', location: GeoPoint(2.5, 102.8), capacity: 100, resourcePointId: depot.id);
    });
    Future<InventoryItem> stock(double qty, {DateTime? expiry, bool mapped = true}) async {
      final i = await w.resources.addItem(admin, resourcePointId: depot.id, name: 'Water', quantity: qty, expiryDate: expiry);
      return mapped ? w.resources.mapItem(admin, i.id, water.id) : i;
    }

    test('expiring list: within 30 days or already expired, soonest first, empty stock ignored', () async {
      await stock(5, expiry: inDays(30));
      await stock(5, expiry: inDays(31));
      await stock(5, expiry: inDays(-2));
      await stock(0, expiry: inDays(1));
      await stock(5);
      final e = await w.resources.expiringItems(officer);
      expect([for (final i in e) i.expiryDate], [inDays(-2), inDays(30)]);
      expect(e.first.isExpiredAt(kNow), isTrue);
      expect(await w.resources.expiringItems(officer, withinDays: 60), hasLength(3));
    });
    test('no people in the centre means no supply alert', () async {
      expect(await w.resources.supplyAlerts(admin), isEmpty);
    });
    test('days left = stock / (need per person x people)', () async {
      await w.evacuation.setOccupancy(admin, hall.id, 10); // needs 30 litres a day
      await stock(60); // 2 days
      final a = (await w.resources.supplyAlerts(admin)).single;
      expect(a.daysLeft, closeTo(2, 1e-9));
      expect(a.people, 10);
      expect(a.unit.name, 'Drinking water');
    });
    test('exactly 3 days is enough; just under is a shortage', () async {
      await w.evacuation.setOccupancy(admin, hall.id, 10);
      final i = await stock(90);
      expect(await w.resources.supplyAlerts(admin), isEmpty);
      await w.resources.setQuantity(admin, i.id, 89);
      expect(await w.resources.supplyAlerts(admin), hasLength(1));
    });
    test('expired and unmapped stock is not counted; no stock at all is 0 days', () async {
      await w.evacuation.setOccupancy(admin, hall.id, 10);
      await stock(500, expiry: inDays(-1));
      await stock(500, mapped: false);
      expect((await w.resources.supplyAlerts(admin)).single.daysLeft, 0.0);
    });
    test('closed centre is not counted as people to feed', () async {
      await w.evacuation.setOccupancy(admin, hall.id, 10);
      await w.evacuation.setOpen(admin, hall.id, false);
      expect(await w.resources.supplyAlerts(admin), isEmpty);
    });
    test('worst shortage first', () async {
      final rice = await w.resources.addCatalogueUnit(admin, name: 'Rice', unit: 'kg', dailyNeedPerPerson: 0.5);
      await w.evacuation.setOccupancy(admin, hall.id, 10);
      await stock(60); // water 2 days
      final r = await w.resources.addItem(admin, resourcePointId: depot.id, name: 'Rice', quantity: 5);
      await w.resources.mapItem(admin, r.id, rice.id); // rice 1 day
      expect([for (final a in await w.resources.supplyAlerts(admin)) a.unit.name], ['Rice', 'Drinking water']);
    });
  });

  group('TP28 Staff overview', () {
    test('requires staff', () async {
      await expectLater(w.overview.load(null), throwsA(isA<NotSignedInException>()));
    });
    test('counts reports, shelters, expiry and shortages together', () async {
      final water = await w.resources.addCatalogueUnit(admin, name: 'Water', unit: 'l', dailyNeedPerPerson: 3);
      final a = await w.evacuation.add(admin, name: 'A', location: GeoPoint(2.5, 102.8), capacity: 10, resourcePointId: depot.id);
      final b = await w.evacuation.add(admin, name: 'B', location: GeoPoint(2.5, 102.8), capacity: 10);
      await w.evacuation.add(admin, name: 'C', location: GeoPoint(2.5, 102.8), capacity: 10);
      await w.evacuation.setOccupancy(admin, a.id, 10);
      await w.evacuation.setOpen(admin, b.id, false);
      final i = await w.resources.addItem(admin, resourcePointId: depot.id, name: 'Water', quantity: 30, expiryDate: inDays(5));
      await w.resources.mapItem(admin, i.id, water.id);
      await w.report();
      await w.report(by: 'user-2');
      await w.reports.verify(admin, 'rep-1');

      final o = await w.overview.load(officer);
      expect(o.pendingReports, 1);
      expect(o.sheltersOpen, 2);
      expect(o.sheltersFull, 1);
      expect(o.expiringItems, hasLength(1));
      expect(o.supplyAlerts.single.daysLeft, closeTo(1, 1e-9));
    });
    test('staff without an assigned point see all active warnings', () async {
      final o = await w.overview.load(admin);
      expect([for (final s in o.riskNearby) s.station.id], ['JHR-AWAT', 'JHR-SEGKECIL', 'JHR-BULOH']);
    });
    test('staff with an assigned point see only warnings within 50 km', () async {
      final far = await w.resources.addPoint(admin, name: 'KL Depot', location: GeoPoint(3.14, 101.69));
      expect((await w.overview.load(sess(StaffRole.coordinator, point: far.id))).riskNearby, isEmpty);
      expect((await w.overview.load(sess(StaffRole.coordinator, point: depot.id))).riskNearby, hasLength(3));
    });
  });
}
