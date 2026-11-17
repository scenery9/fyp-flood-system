import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';
import 'helpers.dart';

/// Round 2 whole-flow tests: public and staff functions working together,
/// and round 1 results staying the same.
void main() {
  late World w;
  setUp(() => w = World());

  group('TP30 Regression: public and staff together', () {
    test('report: public submits -> staff rejects with note -> public sees it', () async {
      final r = await w.report(by: 'me');
      expect((await w.reports.list(officer, status: ReportStatus.pending)).single.id, r.id);
      await w.reports.reject(officer, r.id, note: 'Wrong location');
      final mine = (await w.reports.mine('me')).single;
      expect(mine.status, ReportStatus.rejected);
      expect(mine.staffNote, 'Wrong location');
      expect((await w.overview.load(officer)).pendingReports, 0);
    });
    test('relief flow: point -> centre -> headcount -> occupancy -> shortage -> restock', () async {
      final depot = await w.resources.addPoint(admin, name: 'Depot', location: GeoPoint(2.51, 102.81));
      final hall = await w.evacuation.add(coordinator, name: 'Hall', location: GeoPoint(2.52, 102.82), capacity: 20, resourcePointId: depot.id);
      final water = await w.resources.addCatalogueUnit(coordinator, name: 'Water', unit: 'l', dailyNeedPerPerson: 3);
      final item = await w.resources.addItem(officer, resourcePointId: depot.id, name: 'Water', quantity: 30);
      await w.resources.mapItem(coordinator, item.id, water.id);

      final near = await w.evacuation.nearest(GeoPoint(2.5, 102.8), limit: 1);
      await w.headcount.submit(householdId: 'h1', total: 6, elderly: 2, evacuationPointId: near.single.point.id);
      expect((await w.headcount.summary(officer)).rows.single.name, 'Hall');

      await w.evacuation.setOccupancy(officer, hall.id, 6); // 18 litres a day -> 1.67 days
      expect((await w.overview.load(coordinator)).supplyAlerts, hasLength(1));
      await w.resources.setQuantity(officer, item.id, 90);
      expect((await w.overview.load(coordinator)).supplyAlerts, isEmpty);
    });
    test('staff login to action: created officer can review, deactivated one cannot log in', () async {
      await w.staffTable.put('root', StaffAccount(id: 'root', fullName: 'Root', username: 'root', role: StaffRole.superAdmin));
      final root = await w.staff.sessionFor('root');
      await w.staff.create(root, authUserId: 'u1', fullName: 'Ali', username: 'ali', role: StaffRole.fieldOfficer);
      final ali = await w.staff.sessionFor('u1');
      final r = await w.report();
      expect((await w.reports.verify(ali, r.id)).reviewedBy, 'u1');
      await expectLater(w.staff.list(ali), throwsA(isA<PermissionDeniedException>()));
      await w.staff.setActive(root, 'u1', false);
      await expectLater(w.staff.sessionFor('u1'), throwsA(isA<PermissionDeniedException>()));
    });
    test('every staff function refuses a caller who is not signed in', () async {
      final loc = GeoPoint(2, 102);
      final calls = <Future<Object?> Function()>[
        () => w.reports.list(null),
        () => w.reports.counts(null),
        () => w.reports.verify(null, 'x'),
        () => w.reports.markDuplicate(null, 'x', ofId: 'y'),
        () => w.headcount.summary(null),
        () => w.evacuation.add(null, name: 'a', location: loc, capacity: 1),
        () => w.evacuation.remove(null, 'x'),
        () => w.evacuation.setOccupancy(null, 'x', 1),
        () => w.evacuation.setOpen(null, 'x', true),
        () => w.resources.listPoints(null),
        () => w.resources.addPoint(null, name: 'a', location: loc),
        () => w.resources.removePoint(null, 'x'),
        () => w.resources.listItems(null),
        () => w.resources.addItem(null, resourcePointId: 'x', name: 'a', quantity: 1),
        () => w.resources.setQuantity(null, 'x', 1),
        () => w.resources.addCatalogueUnit(null, name: 'a', unit: 'b', dailyNeedPerPerson: 1),
        () => w.resources.mapItem(null, 'x', null),
        () => w.resources.unmappedItems(null),
        () => w.resources.expiringItems(null),
        () => w.resources.supplyAlerts(null),
        () => w.staff.list(null),
        () => w.staff.create(null, authUserId: 'a', fullName: 'a', username: 'abc', role: StaffRole.fieldOfficer),
        () => w.staff.setActive(null, 'x', false),
        () => w.staff.changeRole(null, 'x', StaffRole.fieldOfficer),
        () => w.overview.load(null),
      ];
      for (final call in calls) {
        await expectLater(call(), throwsA(isA<NotSignedInException>()));
      }
    });
    test('round 1 results are unchanged by round 2 activity', () async {
      final followed = FollowedAreasService(store: InMemoryFollowedStore(), repository: w.repo);
      final home = HomeService(monitoring: w.monitoring, followed: followed);
      List<String> ids(List<StationStatus> l) => [for (final s in l) s.station.id];
      final before = ids((await home.load()).highRisk);

      await w.report();
      await w.headcount.submit(householdId: 'h', total: 3);
      await w.alerts.setRiskRule('JHR-AWAT', RiskLevel.danger);
      final fired = await w.alerts.evaluate(await w.monitoring.loadStatuses());
      await w.assistant.ask('status segamat');
      await followed.follow('JHR-AWAT');

      expect(fired.single.rule.stationId, 'JHR-AWAT');
      final after = await home.load();
      expect(ids(after.highRisk), before);
      expect(ids(after.areaCards), ['JHR-AWAT']);
    });
    test('settings threshold feeds alerts', () async {
      final settings = SettingsService(InMemorySettingsStore());
      await settings.save(const AppSettings(notificationThreshold: RiskLevel.danger));
      await w.alerts.setRiskRule('JHR-BULOH', RiskLevel.alert); // station is at Alert
      await w.alerts.setRiskRule('JHR-AWAT', RiskLevel.alert); // station is at Danger
      final events = await w.alerts.evaluate(await w.monitoring.loadStatuses(),
          threshold: (await settings.load()).notificationThreshold);
      expect([for (final e in events) e.rule.stationId], ['JHR-AWAT']);
    });
  });
}
