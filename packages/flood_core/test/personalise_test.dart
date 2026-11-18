import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';
import 'helpers.dart';

void main() {
  group('TP22 What To Do', () {
    const g = GuidanceService();
    test('every level has steps in English and Malay', () {
      for (final l in RiskLevel.values) {
        expect(g.steps(l), isNotEmpty);
        expect(g.steps(l, language: AppLanguage.ms), hasLength(g.steps(l).length));
      }
    });
    test('danger tells people to move and to call 999', () {
      expect(g.steps(RiskLevel.danger).join(' '), contains('999'));
      expect(g.steps(RiskLevel.danger, language: AppLanguage.ms).join(' '), contains('999'));
    });
    test('Chinese falls back to English for now', () {
      expect(g.steps(RiskLevel.alert, language: AppLanguage.zh), g.steps(RiskLevel.alert));
    });
    test('station with a fresh level gets that level; unknown or old data gets Alert steps', () {
      expect(g.forStatus(assess(st('A'), rd('A', river: 17))), g.steps(RiskLevel.danger));
      expect(g.forStatus(assess(st('A'), null)), g.steps(RiskLevel.alert));
      expect(g.forStatus(assess(st('A'), rd('A', river: 11, minAgo: 999))), g.steps(RiskLevel.alert));
    });
    test('the returned list cannot be changed by the caller', () {
      expect(() => g.steps(RiskLevel.normal).add('x'), throwsA(isA<UnsupportedError>()));
    });
  });

  group('TP23 Settings', () {
    test('defaults on first run', () async {
      final s = await SettingsService(InMemorySettingsStore()).load();
      expect(s.language, AppLanguage.en);
      expect(s.textSize, TextSize.medium);
      expect(s.highContrast, isFalse);
      expect(s.region, isNull);
      expect(s.notificationThreshold, RiskLevel.alert);
    });
    test('saved settings come back after restart', () async {
      final store = InMemorySettingsStore();
      await SettingsService(store).save(const AppSettings().copyWith(
          language: AppLanguage.ms, textSize: TextSize.large, highContrast: true,
          region: 'Johor', notificationThreshold: RiskLevel.warning));
      final s = await SettingsService(store).load();
      expect(s.language, AppLanguage.ms);
      expect(s.textSize, TextSize.large);
      expect(s.highContrast, isTrue);
      expect(s.region, 'Johor');
      expect(s.notificationThreshold, RiskLevel.warning);
    });
    test('region can be cleared', () async {
      final svc = SettingsService(InMemorySettingsStore({'region': 'Johor'}));
      await svc.save((await svc.load()).copyWith(clearRegion: true));
      expect((await svc.load()).region, isNull);
    });
    test('damaged saved values fall back to defaults', () async {
      final s = await SettingsService(InMemorySettingsStore({
        'language': 'klingon', 'textSize': '', 'highContrast': 'yes',
        'region': '  ', 'notificationThreshold': 'normal',
      })).load();
      expect(s.language, AppLanguage.en);
      expect(s.textSize, TextSize.medium);
      expect(s.highContrast, isFalse);
      expect(s.region, isNull);
      expect(s.notificationThreshold, RiskLevel.alert);
    });
    test('threshold "Normal" is refused', () async {
      final svc = SettingsService(InMemorySettingsStore());
      await expectLater(svc.save(const AppSettings(notificationThreshold: RiskLevel.normal)),
          throwsA(isA<ValidationException>()));
    });
  });

  group('TP24 My Alerts', () {
    late FakeRepository repo;
    late World w;
    setUp(() {
      repo = FakeRepository([st('A'), st('B')], [rd('A', river: 11), rd('B', river: 11)]);
      w = World(repo: repo);
    });
    Future<List<String>> run({RiskLevel threshold = RiskLevel.alert}) async =>
        [for (final e in await w.alerts.evaluate(await w.monitoring.loadStatuses(), threshold: threshold)) e.rule.stationId];
    void river(String id, double v, {int minAgo = 10}) => repo.readings[id] = rd(id, river: v, minAgo: minAgo);

    test('rules: add, replace, list, remove', () async {
      await w.alerts.setRiskRule('A', RiskLevel.warning);
      await w.alerts.setRiskRule('A', RiskLevel.danger); // replaces
      await w.alerts.setWaterLevelRule('A', 13.5); // different type: kept
      final rules = await w.alerts.list();
      expect(rules, hasLength(2));
      expect(rules.first.minLevel, RiskLevel.danger);
      await w.alerts.remove(rules.first.id);
      expect(await w.alerts.list(), hasLength(1));
    });
    test('bad rules are refused', () async {
      await expectLater(w.alerts.setRiskRule('A', RiskLevel.normal), throwsA(isA<ValidationException>()));
      await expectLater(w.alerts.setWaterLevelRule('A', double.nan), throwsA(isA<ValidationException>()));
      await expectLater(w.alerts.setRiskRule('ZZZ', RiskLevel.alert), throwsA(isA<UnknownStationException>()));
      await expectLater(w.alerts.setEnabled('nope', false), throwsA(isA<NotFoundException>()));
    });
    test('nothing fires while the river is normal', () async {
      await w.alerts.setRiskRule('A', RiskLevel.alert);
      expect(await run(), isEmpty);
    });
    void after(int minutes) => w.clock = w.clock.add(Duration(minutes: minutes));

    test('fires once when the level is reached, not again on the next refresh', () async {
      await w.alerts.setRiskRule('A', RiskLevel.warning);
      river('A', 14.5);
      expect(await run(), ['A']);
      expect(await run(), isEmpty);
    });
    test('fires again when the river moves up a level', () async {
      await w.alerts.setRiskRule('A', RiskLevel.alert);
      river('A', 12.5); // Alert
      expect(await run(), ['A']);
      river('A', 14.5); // Warning
      final e = await w.alerts.evaluate(await w.monitoring.loadStatuses());
      expect(e.single.reason, AlertReason.escalated);
      expect(e.single.message, contains('Warning'));
      river('A', 13); // back down to Alert: no alert for going down
      expect(await run(), isEmpty);
    });
    test('repeats every 45 minutes while at Danger', () async {
      await w.alerts.setRiskRule('A', RiskLevel.warning);
      river('A', 16.5);
      expect(await run(), ['A']);
      after(44);
      expect(await run(), isEmpty);
      after(1);
      final e = await w.alerts.evaluate(await w.monitoring.loadStatuses());
      expect(e.single.reason, AlertReason.dangerRepeat);
      expect(e.single.message, contains('still at Danger'));
      after(10);
      expect(await run(), isEmpty);
    });
    test('Warning does not repeat', () async {
      await w.alerts.setRiskRule('A', RiskLevel.warning);
      river('A', 14.5);
      await run();
      after(300);
      expect(await run(), isEmpty);
    });
    test('a river hovering at the line does not cause a string of alerts', () async {
      await w.alerts.setRiskRule('A', RiskLevel.warning);
      river('A', 14.1);
      expect(await run(), ['A']);
      river('A', 13.9);
      after(15);
      expect(await run(), isEmpty);
      river('A', 14.1);
      after(15);
      expect(await run(), isEmpty); // back within 60 minutes: still the same event
      river('A', 13.9);
      after(15);
      expect(await run(), isEmpty);
      after(30);
      expect(await run(), isEmpty);
      river('A', 14.1);
      after(1);
      expect(await run(), isEmpty); // back after 31 minutes below: still the same event
      river('A', 13.9);
      after(4);
      expect(await run(), isEmpty);
      after(59);
      expect(await run(), isEmpty); // 59 minutes below
      after(1);
      expect(await run(), isEmpty); // 60 minutes below: rule starts again
      river('A', 14.1);
      expect(await run(), ['A']);
    });
    test('height alert: 0.10 m buffer after it has fired', () async {
      await w.alerts.setWaterLevelRule('B', 13.5);
      river('B', 13.5);
      expect(await run(), ['B']);
      river('B', 13.41); // within 0.10 m: still counts as reached
      expect(await run(), isEmpty);
      after(69);
      expect(await run(), isEmpty);
      river('B', 13.5);
      after(1);
      expect(await run(), isEmpty); // not reset, so no repeat
      river('B', 13.39); // more than 0.10 m below: gone
      expect(await run(), isEmpty);
      after(60);
      expect(await run(), isEmpty);
      river('B', 13.45); // must reach 13.50 again, the buffer only applies after firing
      expect(await run(), isEmpty);
      river('B', 13.5);
      expect(await run(), ['B']);
    });
    test('fires again after the river drops for an hour and rises again', () async {
      await w.alerts.setRiskRule('A', RiskLevel.warning);
      river('A', 14.5);
      await run();
      river('A', 11);
      expect(await run(), isEmpty);
      after(60);
      expect(await run(), isEmpty);
      river('A', 14.5);
      expect(await run(), ['A']);
    });
    test('water-level rule uses the exact number', () async {
      await w.alerts.setWaterLevelRule('B', 13.5);
      river('B', 13.49);
      expect(await run(), isEmpty);
      river('B', 13.5);
      final events = await w.alerts.evaluate(await w.monitoring.loadStatuses());
      expect(events.single.message, contains('13.50 m'));
    });
    test('notification threshold from Settings limits risk rules only', () async {
      await w.alerts.setRiskRule('A', RiskLevel.alert);
      await w.alerts.setWaterLevelRule('B', 12);
      river('A', 12.5); // Alert
      river('B', 12.5);
      expect(await run(threshold: RiskLevel.warning), ['B']);
      expect(await run(threshold: RiskLevel.alert), ['A']);
    });
    test('old or missing data never fires, and does not reset the rule', () async {
      await w.alerts.setRiskRule('A', RiskLevel.warning);
      river('A', 16.5, minAgo: 999);
      expect(await run(), isEmpty);
      river('A', 16.5);
      expect(await run(), ['A']);
      repo.readings.remove('A');
      expect(await run(), isEmpty);
      river('A', 16.5); // data back, still high: no repeat
      expect(await run(), isEmpty);
    });
    test('disabled rule is silent; enabling starts fresh', () async {
      final r = await w.alerts.setRiskRule('A', RiskLevel.warning);
      await w.alerts.setEnabled(r.id, false);
      river('A', 14.5);
      expect(await run(), isEmpty);
      await w.alerts.setEnabled(r.id, true);
      expect(await run(), ['A']);
    });
    test('limit of 20 rules', () async {
      repo.stations = [for (var i = 0; i < 21; i++) st('S$i')];
      for (var i = 0; i < 20; i++) {
        await w.alerts.setRiskRule('S$i', RiskLevel.alert);
      }
      await expectLater(w.alerts.setRiskRule('S20', RiskLevel.alert), throwsA(isA<ConflictException>()));
      await w.alerts.setRiskRule('S0', RiskLevel.danger); // replacing is still fine
    });
  });
}
