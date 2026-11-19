import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  // About 1.1 km per 0.01 degree of latitude.
  final here = GeoPoint(3.000, 101.500);
  final same = GeoPoint(3.000, 101.500);
  final near = GeoPoint(3.040, 101.500); // ~4.4 km
  final nearer = GeoPoint(3.020, 101.500); // ~2.2 km
  final far = GeoPoint(3.200, 101.500); // ~22 km

  // A rain gauge (no thresholds), like Melaka's "...RF" stations.
  final rainGauge = assess(st('0290491RF', loc: here, thresholds: false), rd('0290491RF', rain: 2));
  StationStatus river(String id, GeoPoint? loc, {int minAgo = 10, double level = 11}) =>
      assess(st(id, loc: loc), rd(id, river: level, minAgo: minAgo));

  group('TP98 River for a saved area', () {
    test('a river gauge with a recent reading uses its own reading', () {
      final own = river('RIV', here);
      final r = riverSourceFor(own, [own, river('OTHER', nearer)])!;
      expect(r.isOwnGauge, isTrue);
      expect(r.gauge.station.id, 'RIV');
    });

    test('a rain gauge borrows the river gauge at the same place', () {
      final r = riverSourceFor(rainGauge, [rainGauge, river('0290491WL', same), river('B', nearer)])!;
      expect(r.gauge.station.id, '0290491WL');
      expect(r.distanceKm, closeTo(0, 0.01));
      expect(r.isOwnGauge, isFalse);
    });

    test('otherwise the nearest usable river gauge within 10 km', () {
      final r = riverSourceFor(rainGauge, [rainGauge, river('NEAR', near), river('NEARER', nearer), river('FAR', far)])!;
      expect(r.gauge.station.id, 'NEARER');
      expect(r.distanceKm, closeTo(2.2, 0.05));
    });

    test('old, unplaced or threshold-less gauges are skipped', () {
      final noThresholds = assess(st('NT', loc: nearer, thresholds: false), rd('NT', river: 3));
      final r = riverSourceFor(rainGauge,
          [rainGauge, river('OLD', nearer, minAgo: 300), river('NOWHERE', null), noThresholds, river('OK', near)])!;
      expect(r.gauge.station.id, 'OK');
    });

    test('a river gauge that went quiet borrows a nearby one', () {
      final quiet = river('QUIET', here, minAgo: 300);
      expect(riverSourceFor(quiet, [quiet, river('OK', nearer)])!.gauge.station.id, 'OK');
    });

    test('nothing within 10 km, or no position: null', () {
      expect(riverSourceFor(rainGauge, [rainGauge, river('FAR', far)]), isNull);
      final unplaced = assess(st('X', thresholds: false), rd('X', rain: 1));
      expect(riverSourceFor(unplaced, [unplaced, river('OK', nearer)]), isNull);
    });
  });
}
