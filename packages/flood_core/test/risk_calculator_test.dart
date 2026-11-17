import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';
import 'helpers.dart';

void main() {
  // thresholds used: normal 10, alert 12, warning 14, danger 16
  group('TP3 Risk level', () {
    test('below alert is Normal, heading to Alert', () {
      final s = assess(st('A'), rd('A', river: 11));
      expect(s.level, RiskLevel.normal);
      expect(s.targetLevel, RiskLevel.alert);
      expect(s.percentToTarget, closeTo(50, 1e-9));
    });
    test('exactly on each threshold counts as that level', () {
      expect(assess(st('A'), rd('A', river: 12)).level, RiskLevel.alert);
      expect(assess(st('A'), rd('A', river: 14)).level, RiskLevel.warning);
      expect(assess(st('A'), rd('A', river: 16)).level, RiskLevel.danger);
    });
    test('just under a threshold stays at the lower level', () {
      expect(assess(st('A'), rd('A', river: 11.99)).level, RiskLevel.normal);
      expect(assess(st('A'), rd('A', river: 13.99)).level, RiskLevel.alert);
      expect(assess(st('A'), rd('A', river: 15.99)).level, RiskLevel.warning);
    });
    test('percent is measured from normal to the next level', () {
      final alert = assess(st('A'), rd('A', river: 13));
      expect(alert.targetLevel, RiskLevel.warning);
      expect(alert.percentToTarget, closeTo(75, 1e-9));
      final warning = assess(st('A'), rd('A', river: 15));
      expect(warning.targetLevel, RiskLevel.danger);
      expect(warning.percentToTarget, closeTo(83.333, 0.01));
    });
    test('percent never leaves 0-100', () {
      expect(assess(st('A'), rd('A', river: 5)).percentToTarget, 0.0);
      final d = assess(st('A'), rd('A', river: 99));
      expect(d.percentToTarget, 100.0);
      expect(d.targetLevel, RiskLevel.danger);
    });
  });

  group('TP4 Missing and old data', () {
    test('no reading at all gives unknown level', () {
      final s = assess(st('A'), null);
      expect(s.level, isNull);
      expect(s.age, isNull);
      expect(s.isStale, isFalse);
      expect(s.isActionable, isFalse);
      expect(s.mainCause, 'No readings received yet');
    });
    test('offline river sensor gives unknown level but keeps rainfall', () {
      final r = StationReading.fromRaw(stationId: 'A', time: kNow, rainfall: 2, riverLevel: -9999);
      final s = assess(st('A'), r);
      expect(s.level, isNull);
      expect(s.rainfall, 2.0);
      expect(s.mainCause, contains('no data'));
    });
    test('rainfall-only station has no level', () {
      final s = assess(st('A', thresholds: false), rd('A', rain: 65, river: 3));
      expect(s.level, isNull);
      expect(s.percentToTarget, isNull);
      expect(s.rainIntensity, RainIntensity.veryHeavy);
      expect(s.mainCause, contains('Rainfall-only'));
    });
    test('exactly 3 hours old is still fresh, one minute more is stale', () {
      expect(assess(st('A'), rd('A', minAgo: 180, river: 16)).isStale, isFalse);
      final old = assess(st('A'), rd('A', minAgo: 181, river: 16));
      expect(old.isStale, isTrue);
      expect(old.level, RiskLevel.danger); // level kept, but flagged
      expect(old.isActionable, isFalse);
      expect(old.mainCause, contains('old'));
    });
    test('reading from the future (clock skew) has age zero', () {
      final s = assess(st('A'), rd('A', minAgo: -5, river: 11));
      expect(s.age, Duration.zero);
      expect(s.isStale, isFalse);
    });
    test('stale limit can be changed', () {
      final c = const RiskCalculator(staleAfter: Duration(minutes: 30));
      expect(c.assess(st('A'), rd('A', minAgo: 31, river: 11), now: kNow).isStale, isTrue);
    });
  });

  group('TP5 Cause text and distance', () {
    test('danger and percent wording', () {
      expect(assess(st('A'), rd('A', river: 16.2)).mainCause, 'River level has reached Danger level');
      expect(assess(st('A'), rd('A', river: 13)).mainCause,
          'River level is 75% of the way to Warning level');
    });
    test('distance needs both user and station location', () {
      final user = GeoPoint(0, 100);
      expect(assess(st('A', loc: GeoPoint(0, 101)), rd('A', river: 11), user: user).distanceKm,
          closeTo(111.19, 0.05));
      expect(assess(st('A'), rd('A', river: 11), user: user).distanceKm, isNull);
      expect(assess(st('A', loc: GeoPoint(0, 101)), rd('A', river: 11)).distanceKm, isNull);
    });
  });
}
