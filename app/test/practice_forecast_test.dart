import 'dart:convert';

import 'package:flood_app/app/sample_data.dart';
import 'package:flood_core/flood_core.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  group('Practice forecast for live stations', () {
    test('one entry per fresh river station, with real ids, marked practice', () async {
      final now = DateTime.now();
      final statuses = await MonitoringService(repository: SampleStationRepository()).loadStatuses();
      final body = await PracticeForecastSource(() => statuses).fetch();
      final j = jsonDecode(body) as Map<String, dynamic>;
      expect(j['is_practice_data'], isTrue);
      final ids = {for (final s in j['stations'] as List) (s as Map)['station_id']};
      final expected = {
        for (final s in statuses)
          if (s.riverLevel != null && s.station.thresholds != null && !s.isStale) s.station.id
      };
      expect(ids, expected);
      // The app reads it like any other forecast file, and keeps every station.
      final r = await ForecastService(source: PracticeForecastSource(() => statuses), clock: () => now).load(statuses);
      expect(r.forecasts.keys.toSet(), expected);
      expect(r.forecasts.values.every((f) => f.isPracticeData), isTrue);
    });

    test('heavy rain raises the forecast; no rain lets a high river drain', () async {
      final st = Station(id: 'X', name: 'X', district: 'D', state: 'Selangor', thresholds: Thresholds(normal: 10, alert: 12, warning: 14, danger: 16));
      final now = DateTime.now();
      StationStatus at(double level, double rain) => const RiskCalculator().assess(
          st, StationReading(stationId: 'X', time: now, riverLevelM: level, rainfallMmPerHr: rain),
          now: now);
      Future<double> change(StationStatus s) async {
        final m = ((jsonDecode(await PracticeForecastSource(() => [s]).fetch()) as Map)['stations'] as List).single as Map;
        return ((m['predicted_level_m'] as num) - (m['current_level_m'] as num)).toDouble();
      }

      expect(await change(at(11, 40)), greaterThan(0.3));
      expect(await change(at(13, 0)), lessThan(0));
      expect(await change(at(10, 0)), 0);
    });
  });

  group('Practice forecast is shown on the AI forecast card only', () {
    testWidgets('with live data it is not used for alerts or other screens', (tester) async {
      final app = TestApp(liveData: true);
      await app.start(tester);
      final c = app.controller;
      // JHR-BULOH's sample (practice) forecast rises to Warning.
      expect(c.cardForecastFor('JHR-BULOH'), isNotNull);
      expect(c.forecastFor('JHR-BULOH'), isNull);
      expect(c.alerts.expected, isEmpty);
    });

    testWidgets('with sample data the practice forecast still drives the demo', (tester) async {
      final app = TestApp();
      await app.start(tester);
      final c = app.controller;
      expect(c.forecastFor('JHR-BULOH'), isNotNull);
      expect(c.alerts.expected, isNotEmpty);
    });
  });
}
