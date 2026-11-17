import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';
import 'helpers.dart';

/// Whole-flow tests on the sample data: they check that one function
/// does not break another.
void main() {
  late SampleStationRepository repo;
  late MonitoringService monitoring;
  late FollowedAreasService followed;
  late HomeService home;
  const lists = StationListService();
  const warnings = WarningService();
  List<String> ids(List<StationStatus> l) => [for (final s in l) s.station.id];

  setUp(() {
    repo = SampleStationRepository(clock: fixedClock);
    monitoring = MonitoringService(repository: repo, clock: fixedClock);
    followed = FollowedAreasService(store: InMemoryFollowedStore(), repository: repo);
    home = HomeService(monitoring: monitoring, followed: followed);
  });

  group('TP13 Sample data', () {
    test('8 stations with unique ids, each reading matches a station', () async {
      final stations = await repo.getStations();
      final readings = await repo.getLatestReadings();
      expect(stations, hasLength(8));
      expect({for (final s in stations) s.id}, hasLength(8));
      for (final id in readings.keys) {
        expect(stations.any((s) => s.id == id), isTrue);
      }
    });
    test('sample covers every case the UI must handle', () async {
      final by = {for (final s in await monitoring.loadStatuses()) s.station.id: s};
      expect(by['JHR-AWAT']!.level, RiskLevel.danger);
      expect(by['JHR-SEGKECIL']!.level, RiskLevel.warning);
      expect(by['JHR-BULOH']!.level, RiskLevel.alert);
      expect(by['SGR-KAJANG']!.level, RiskLevel.normal);
      expect(by['SGR-RANTAU']!.isStale, isTrue);
      expect(by['MLK-HAMPAR']!.level, isNull); // offline sensor
      expect(by['MLK-DURIAN']!.rainIntensity, RainIntensity.veryHeavy);
      expect(by['JHR-CHAAH']!.station.location, isNull);
    });
  });

  group('TP14 Regression: functions working together', () {
    test('open app -> follow from list -> Home updates -> unfollow -> Home updates', () async {
      expect((await home.load()).areaCards, isEmpty);

      final river = lists.apply(await monitoring.loadStatuses());
      expect(river.first.station.id, 'JHR-AWAT');
      await followed.toggle(river.first.station.id);
      await followed.toggle('SGR-KAJANG');
      expect(ids((await home.load()).areaCards), ['JHR-AWAT', 'SGR-KAJANG']);

      await followed.toggle('JHR-AWAT');
      expect(ids((await home.load()).areaCards), ['SGR-KAJANG']);
    });
    test('following does not change lists, warnings or the high-risk list', () async {
      final before = await monitoring.loadStatuses();
      final listBefore = ids(lists.apply(before));
      final warnBefore = ids(warnings.active(before));
      final riskBefore = ids((await home.load()).highRisk);

      await followed.follow('SGR-RANTAU');
      await followed.follow('MLK-DURIAN');

      final after = await monitoring.loadStatuses();
      expect(ids(lists.apply(after)), listBefore);
      expect(ids(warnings.active(after)), warnBefore);
      expect(ids((await home.load()).highRisk), riskBefore);
    });
    test('Home high-risk list and Warnings agree', () async {
      final all = await monitoring.loadStatuses();
      expect(ids((await home.load()).highRisk), ['JHR-AWAT', 'JHR-SEGKECIL', 'JHR-BULOH']);
      expect(ids(warnings.active(all)), ['JHR-AWAT', 'JHR-SEGKECIL', 'JHR-BULOH']);
    });
    test('detail, list and Home show the same values for one station', () async {
      await followed.follow('JHR-BULOH');
      final detail = await monitoring.statusFor('JHR-BULOH');
      final card = (await home.load()).areaCards.single;
      final row = lists.apply(await monitoring.loadStatuses(), query: 'buloh').single;
      for (final s in [card, row]) {
        expect(s.level, detail.level);
        expect(s.percentToTarget, detail.percentToTarget);
        expect(s.mainCause, detail.mainCause);
      }
    });
    test('filtering one list does not affect the next call', () async {
      final all = await monitoring.loadStatuses();
      expect(lists.apply(all, state: 'Melaka'), hasLength(2));
      expect(lists.apply(all, mode: ListMode.rainfall).first.station.id, 'MLK-DURIAN');
      expect(lists.apply(all), hasLength(8));
    });
    test('follow limit holds across the whole flow', () async {
      for (final id in ['JHR-AWAT', 'JHR-BULOH', 'JHR-SEGKECIL', 'JHR-CHAAH', 'SGR-KAJANG']) {
        await followed.follow(id);
      }
      await expectLater(followed.toggle('MLK-DURIAN'), throwsA(isA<FollowLimitReachedException>()));
      expect((await home.load()).areaCards, hasLength(5));
    });
    test('share text works for every sample station', () async {
      for (final s in await monitoring.loadStatuses()) {
        expect(const ShareFormatter().statusText(s), contains(s.station.name));
      }
    });
  });
}
