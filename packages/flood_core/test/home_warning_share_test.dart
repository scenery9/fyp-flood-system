import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';
import 'helpers.dart';

void main() {
  late FakeRepository repo;
  late FollowedAreasService followed;
  late MonitoringService monitoring;
  late HomeService home;
  List<String> ids(List<StationStatus> l) => [for (final s in l) s.station.id];

  setUp(() {
    repo = FakeRepository([
      st('NORM'), st('ALERT'), st('WARN'), st('DANG'), st('STALE'), st('NODATA'),
    ], [
      rd('NORM', river: 11),
      rd('ALERT', river: 13, minAgo: 5),
      rd('WARN', river: 15),
      rd('DANG', river: 17, rain: 12),
      rd('STALE', river: 17, minAgo: 3000),
    ]);
    followed = FollowedAreasService(store: InMemoryFollowedStore(), repository: repo);
    monitoring = MonitoringService(repository: repo, clock: fixedClock);
    home = HomeService(monitoring: monitoring, followed: followed);
  });

  group('TP9 Monitoring and station detail', () {
    test('one status per station', () async {
      expect(await monitoring.loadStatuses(), hasLength(6));
    });
    test('detail for one station', () async {
      final s = await monitoring.statusFor('DANG');
      expect(s.level, RiskLevel.danger);
      expect(s.age, const Duration(minutes: 10));
    });
    test('detail for unknown station throws', () async {
      await expectLater(monitoring.statusFor('ZZZ'), throwsA(isA<UnknownStationException>()));
    });
    test('data source failure is passed on, not hidden', () async {
      repo.fail = true;
      await expectLater(monitoring.loadStatuses(), throwsA(isA<StateError>()));
    });
    test('no stations gives an empty list', () async {
      repo.stations = [];
      expect(await monitoring.loadStatuses(), isEmpty);
    });
  });

  group('TP10 Home', () {
    test('nothing followed: no cards, high-risk list still shown', () async {
      final h = await home.load();
      expect(h.areaCards, isEmpty);
      expect(ids(h.highRisk), ['DANG', 'WARN', 'ALERT']);
      expect(h.generatedAt, kNow);
    });
    test('cards follow the order the user followed', () async {
      await followed.follow('WARN');
      await followed.follow('NORM');
      await followed.follow('STALE');
      final h = await home.load();
      expect(ids(h.areaCards), ['WARN', 'NORM', 'STALE']);
      expect(h.areaCards.last.isStale, isTrue); // shown, greyed out by the UI
    });
    test('high-risk list leaves out normal, stale and no-data stations', () async {
      final h = await home.load();
      expect(ids(h.highRisk).contains('STALE'), isFalse);
      expect(ids(h.highRisk).contains('NORM'), isFalse);
      expect(ids(h.highRisk).contains('NODATA'), isFalse);
    });
    test('high-risk list respects its limit', () async {
      final small = HomeService(monitoring: monitoring, followed: followed, highRiskLimit: 2);
      expect(ids((await small.load()).highRisk), ['DANG', 'WARN']);
    });
    test('a followed station removed from the feed is skipped', () async {
      await followed.follow('NORM');
      await followed.follow('DANG');
      repo.stations = repo.stations.where((s) => s.id != 'NORM').toList();
      expect(ids((await home.load()).areaCards), ['DANG']);
    });
  });

  group('TP11 Warnings', () {
    const svc = WarningService();
    test('alert and above, highest first', () async {
      expect(ids(svc.active(await monitoring.loadStatuses())), ['DANG', 'WARN', 'ALERT']);
    });
    test('minimum level filter', () async {
      final all = await monitoring.loadStatuses();
      expect(ids(svc.active(all, minLevel: RiskLevel.warning)), ['DANG', 'WARN']);
      expect(ids(svc.active(all, minLevel: RiskLevel.danger)), ['DANG']);
    });
    test('same level: newest reading first', () async {
      repo.readings['WARN'] = rd('WARN', river: 13, minAgo: 20); // now also Alert
      expect(ids(svc.active(await monitoring.loadStatuses())), ['DANG', 'ALERT', 'WARN']);
    });
    test('all normal gives no warnings', () {
      expect(svc.active([assess(st('A'), rd('A', river: 11))]), isEmpty);
      expect(svc.active([]), isEmpty);
    });
  });

  group('TP12 Share text', () {
    const fmt = ShareFormatter();
    test('full status', () async {
      final text = fmt.statusText(await monitoring.statusFor('DANG'));
      expect(text, contains('DANG (D1, Johor)'));
      expect(text, contains('Status: Danger (Bahaya)'));
      expect(text, contains('River level: 17.00 m (100% to Danger level)'));
      expect(text, contains('Rainfall: 12.0 mm/hr'));
      expect(text, contains('Updated: 2026-11-17 10:50 MYT')); // 02:50 UTC + 8 h
      expect(text, contains('Not an official warning'));
    });
    test('stale data is labelled', () async {
      expect(fmt.statusText(await monitoring.statusFor('STALE')), contains('(old data)'));
    });
    test('no reading', () async {
      final text = fmt.statusText(await monitoring.statusFor('NODATA'));
      expect(text, contains('Status: Unknown'));
      expect(text, contains('No readings yet'));
      expect(text.contains('River level'), isFalse);
    });
  });
}
