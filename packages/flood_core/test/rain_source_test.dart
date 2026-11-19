import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  // About 1.1 km per 0.01 degree of latitude.
  final here = GeoPoint(3.000, 101.500);
  final near = GeoPoint(3.020, 101.500); // ~2.2 km
  final nearer = GeoPoint(3.010, 101.500); // ~1.1 km
  final far = GeoPoint(3.200, 101.500); // ~22 km

  final river = assess(st('RIV', loc: here), rd('RIV', river: 11));
  StationStatus gauge(String id, GeoPoint loc, double? rain, {int minAgo = 10}) =>
      assess(st(id, loc: loc, thresholds: false), rd(id, rain: rain, minAgo: minAgo));
  RainSource? source(StationStatus s, List<StationStatus> all) => rainSourceFor(s, all, now: kNow);

  group('TP97 Rain for a river station', () {
    test('its own recent rain reading comes first', () {
      final own = assess(st('RIV', loc: here), rd('RIV', river: 11, rain: 4));
      final r = source(own, [own, gauge('G1', nearer, 50)])!;
      expect(r.isOwnGauge, isTrue);
      expect(r.mmPerHr, 4);
      expect(r.intensity, RainIntensity.light);
      expect(r.distanceKm, isNull);
    });

    test('no own gauge: the nearest recent gauge, with its distance', () {
      final r = source(river, [river, gauge('G-NEAR', near, 2), gauge('G-NEARER', nearer, 35), gauge('G-FAR', far, 80)])!;
      expect(r.isOwnGauge, isFalse);
      expect(r.gauge.station.id, 'G-NEARER');
      expect(r.distanceKm, closeTo(1.1, 0.05));
      expect(r.intensity, RainIntensity.heavy);
    });

    test('a silent own gauge or nearby gauge is skipped (over 3 hours old)', () {
      final staleOwn = assess(st('RIV', loc: here), StationReading(
          stationId: 'RIV', time: kNow, riverLevelM: 11, rainfallMmPerHr: 9,
          rainfallTime: kNow.subtract(const Duration(hours: 4))));
      final r = source(staleOwn, [staleOwn, gauge('OLD', nearer, 20, minAgo: 200), gauge('OK', near, 0)])!;
      expect(r.gauge.station.id, 'OK');
      expect(r.intensity, RainIntensity.none);
    });

    test('nothing within 10 km, or no position: no rain data', () {
      expect(source(river, [river, gauge('G-FAR', far, 10)]), isNull);
      final noLoc = assess(st('X'), rd('X', river: 11));
      expect(source(noLoc, [noLoc, gauge('G', here, 10)]), isNull);
      expect(source(river, [river, gauge('NO-RAIN-SENSOR', nearer, null)]), isNull);
    });

    test('JPS bands: 0 none, up to 10 light, 30 moderate, 60 heavy, above very heavy', () {
      RainIntensity band(double mm) => source(gauge('G', here, mm), const [])!.intensity;
      expect(band(0), RainIntensity.none);
      expect(band(10), RainIntensity.light);
      expect(band(30), RainIntensity.moderate);
      expect(band(60), RainIntensity.heavy);
      expect(band(60.5), RainIntensity.veryHeavy);
    });

    test('live rows keep the rain time apart from the river time', () {
      final r = LiveStationRepository.readingFromRow({
        'station_code': 'BKLG0002L', 'level_m': 1.32, 'level_at': '2026-11-17T02:50:00Z',
        'hourly_mm': 3.5, 'rain_at': '2026-11-16T22:00:00Z',
      })!;
      expect(r.time, DateTime.utc(2026, 11, 17, 2, 50));
      expect(r.rainfallTime, DateTime.utc(2026, 11, 16, 22));
      final s = assess(st('BKLG0002L', loc: here), r);
      expect(source(s, [s]), isNull); // rain 5 h old: not shown as current
    });
  });
}
