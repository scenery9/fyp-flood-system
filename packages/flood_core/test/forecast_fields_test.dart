// TP60 Forecast fields used by the app to word the forecast in Malay and Chinese.
import 'dart:convert';

import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';

class _Source implements ForecastSource {
  _Source(this.body);
  final String body;
  @override
  Future<String> fetch() async => body;
}

void main() {
  final now = DateTime.utc(2026, 11, 17, 12);
  final station = Station(
      id: 'S1', name: 'Test', district: 'D', state: 'S',
      thresholds: Thresholds(normal: 1, alert: 2, warning: 3, danger: 4));

  StationStatus status() => StationStatus(
      station: station, reading: null, level: RiskLevel.alert, targetLevel: RiskLevel.warning,
      percentToTarget: 50, isStale: false, age: Duration.zero, rainIntensity: null, distanceKm: null, mainCause: '');

  String file(List<Map<String, Object?>> factors) => jsonEncode({
        'schema': 1,
        'generated_at': now.toIso8601String(),
        'horizon_hours': 3,
        'is_practice_data': true,
        'stations': [
          {
            'station_id': 'S1',
            'based_on': now.toIso8601String(),
            'current_level_m': 2.5,
            'predicted_level_m': 3.2,
            'low_m': 3.0,
            'high_m': 3.5,
            'factors': factors,
          }
        ],
      });

  test('current level and the kept factors are given, in the same order as the reasons', () async {
    final svc = ForecastService(
        source: _Source(file([
          {'feature': 'rain_sum_3h', 'value': 40.0, 'impact_m': 0.3},
          {'feature': 'level_change_1h', 'value': 0.1, 'impact_m': -0.5},
          {'feature': 'rain_sum_24h', 'value': 2.0, 'impact_m': 0.005}, // too small: dropped
        ])),
        clock: () => now);
    final f = (await svc.load([status()])).forecasts['S1']!;
    expect(f.currentRisk, RiskLevel.alert);
    expect(f.predictedRisk, RiskLevel.warning);
    expect([for (final x in f.factors) x.feature], ['level_change_1h', 'rain_sum_3h']);
    expect(f.reasons.length, f.factors.length);
    expect(f.reasons.first, startsWith('River rose 0.10 m'));
  });

  test('no factors: empty list, not null', () async {
    final svc = ForecastService(source: _Source(file([])), clock: () => now);
    final f = (await svc.load([status()])).forecasts['S1']!;
    expect(f.factors, isEmpty);
  });
}
