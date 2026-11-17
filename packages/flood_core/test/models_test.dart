import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';
import 'helpers.dart';

void main() {
  group('TP1 Models', () {
    test('RiskLevel order and labels', () {
      expect(RiskLevel.danger.isAtLeast(RiskLevel.warning), isTrue);
      expect(RiskLevel.alert.isAtLeast(RiskLevel.alert), isTrue);
      expect(RiskLevel.normal.isAtLeast(RiskLevel.alert), isFalse);
      expect(RiskLevel.alert.labelBm, 'Waspada');
      expect(RiskLevel.danger.labelBm, 'Bahaya');
    });
    test('Thresholds must be strictly rising', () {
      expect(() => Thresholds(normal: 5, alert: 5, warning: 6, danger: 7), throwsArgumentError);
      expect(() => Thresholds(normal: 5, alert: 6, warning: 8, danger: 7), throwsArgumentError);
      expect(th().danger, 16);
    });
    test('Station id cannot be blank', () {
      expect(() => Station(id: ' ', name: 'x', district: 'd', state: 's'), throwsArgumentError);
    });
    test('fromRaw removes fault codes -9999 and -8888', () {
      final a = StationReading.fromRaw(stationId: 'A', time: kNow, rainfall: -9999, riverLevel: -9999);
      expect(a.rainfallMmPerHr, isNull);
      expect(a.riverLevelM, isNull);
      final b = StationReading.fromRaw(stationId: 'A', time: kNow, rainfall: 3, riverLevel: -8888);
      expect(b.rainfallMmPerHr, 3.0);
      expect(b.riverLevelM, isNull);
    });
    test('fromRaw rejects negative rain and NaN, keeps valid values', () {
      final a = StationReading.fromRaw(stationId: 'A', time: kNow, rainfall: -1, riverLevel: double.nan);
      expect(a.rainfallMmPerHr, isNull);
      expect(a.riverLevelM, isNull);
      final b = StationReading.fromRaw(stationId: 'A', time: kNow, rainfall: 0, riverLevel: -0.3);
      expect(b.rainfallMmPerHr, 0.0);
      expect(b.riverLevelM, -0.3); // slightly negative river level is valid near the coast
    });
    test('RainIntensity boundaries', () {
      expect(RainIntensity.fromMm(null), isNull);
      expect(RainIntensity.fromMm(0), RainIntensity.none);
      expect(RainIntensity.fromMm(0.1), RainIntensity.light);
      expect(RainIntensity.fromMm(10), RainIntensity.light);
      expect(RainIntensity.fromMm(10.1), RainIntensity.moderate);
      expect(RainIntensity.fromMm(30), RainIntensity.moderate);
      expect(RainIntensity.fromMm(60), RainIntensity.heavy);
      expect(RainIntensity.fromMm(60.1), RainIntensity.veryHeavy);
    });
  });

  group('TP2 Distance', () {
    test('same point is 0 km', () {
      expect(distanceKm(GeoPoint(2.5, 102.8), GeoPoint(2.5, 102.8)), closeTo(0, 1e-9));
    });
    test('1 degree of longitude on the equator is about 111.19 km', () {
      expect(distanceKm(GeoPoint(0, 100), GeoPoint(0, 101)), closeTo(111.19, 0.05));
    });
    test('distance is the same in both directions', () {
      final a = GeoPoint(2.573, 102.818), b = GeoPoint(3.403, 101.443);
      expect(distanceKm(a, b), closeTo(distanceKm(b, a), 1e-9));
      expect(distanceKm(a, b), greaterThan(150));
      expect(distanceKm(a, b), lessThan(200));
    });
    test('invalid coordinates are rejected', () {
      expect(() => GeoPoint(91, 0), throwsArgumentError);
      expect(() => GeoPoint(0, 181), throwsArgumentError);
    });
  });
}
