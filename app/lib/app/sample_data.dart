import 'dart:convert';

import 'package:flood_core/flood_core.dart';

/// SAMPLE DATA ONLY, for building and testing the screens.
/// Relief centre names, places and numbers are made up. The forecast is in
/// the same format the Python model writes (forecast.json, schema 1) and is
/// marked as practice data, so the app labels it as such.
class SampleData {
  /// Used when the phone's location is off or refused (about 1 km from Kg. Awat, Segamat).
  static final GeoPoint userLocation = GeoPoint(2.566, 102.810);

  /// Areas shown on Home the first time the app opens.
  static const defaultFollowed = ['JHR-AWAT', 'JHR-BULOH', 'SGR-KAJANG'];

  static Table<EvacuationPoint> centres() {
    final t = MemoryTable<EvacuationPoint>();
    for (final p in [
      EvacuationPoint(id: 'PPS-AWAT', name: 'Dewan Kg. Awat', location: GeoPoint(2.578, 102.823), capacity: 150, occupancy: 150),
      EvacuationPoint(id: 'PPS-BULOH', name: 'SK Buloh Kasap', location: GeoPoint(2.556, 102.770), capacity: 400, occupancy: 120),
      EvacuationPoint(id: 'PPS-SEGAMAT', name: 'SMK Seri Segamat', location: GeoPoint(2.508, 102.818), capacity: 300, occupancy: 60),
      EvacuationPoint(id: 'PPS-JEMENTAH', name: 'Dewan Jementah', location: GeoPoint(2.450, 102.690), capacity: 250, isOpen: false),
    ]) {
      t.put(p.id, p);
    }
    return t;
  }
}

/// PRACTICE forecast for the live JPS stations, used until the real model's
/// forecast.json is published (see [FallbackForecastSource]). It is a simple
/// rule, not the AI: rain in the last hour pushes the river up, and a river
/// above its normal level slowly drains back. Every file is marked
/// `is_practice_data`, so the app labels it and keeps it out of alerts.
class PracticeForecastSource implements ForecastSource {
  PracticeForecastSource(this.statuses, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  /// The statuses just loaded (read on each fetch, so always current).
  final List<StationStatus> Function() statuses;
  final DateTime Function() _clock;

  static const horizonHours = 3;
  static const bandM = 0.15;

  @override
  Future<String> fetch() async {
    final now = _clock().toUtc();
    final stations = <Map<String, Object>>[];
    for (final s in statuses()) {
      final r = s.reading;
      final t = s.station.thresholds;
      final level = r?.riverLevelM;
      if (r == null || t == null || level == null || s.isStale) continue;
      final rain = r.rainfallMmPerHr ?? 0;
      final above = level - t.normal;
      final rainPart = (0.012 * rain).clamp(0.0, 0.5);
      final drainPart = -(0.05 * above).clamp(0.0, 0.15);
      final pred = level + rainPart + drainPart;
      double round(double v) => (v * 1000).roundToDouble() / 1000;
      stations.add({
        'station_id': s.station.id,
        'based_on': r.time.toUtc().toIso8601String(),
        'current_level_m': round(level),
        'predicted_level_m': round(pred),
        'low_m': round(pred - bandM),
        'high_m': round(pred + bandM),
        'factors': [
          {'feature': 'rain_sum_1h', 'value': rain, 'impact_m': round(rainPart)},
          {'feature': 'level_above_normal', 'value': round(above), 'impact_m': round(drainPart)},
        ],
      });
    }
    return jsonEncode({
      'schema': 1,
      'generated_at': now.toIso8601String(),
      'horizon_hours': horizonHours,
      'model': {'name': 'practice-rule'},
      'is_practice_data': true,
      'stations': stations,
    });
  }
}

/// Serves a forecast.json made relative to "now", so it is never out of date.
class SampleForecastSource implements ForecastSource {
  SampleForecastSource({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;

  @override
  Future<String> fetch() async {
    final now = _clock().toUtc();
    final based = now.subtract(const Duration(minutes: 10)).toIso8601String();
    Map<String, Object> station(String id, double cur, double pred, double low, double high, List<List<Object>> f) => {
          'station_id': id,
          'based_on': based,
          'current_level_m': cur,
          'predicted_level_m': pred,
          'low_m': low,
          'high_m': high,
          'factors': [for (final x in f) {'feature': x[0], 'value': x[1], 'impact_m': x[2]}],
        };
    return jsonEncode({
      'schema': 1,
      'generated_at': now.subtract(const Duration(minutes: 8)).toIso8601String(),
      'horizon_hours': 3,
      'model': {'name': 'XGBoost'},
      'is_practice_data': true,
      'stations': [
        station('JHR-AWAT', 19.97, 20.04, 19.90, 20.18, [
          ['rain_sum_3h', 42.0, 0.05],
          ['level_change_1h', 0.07, 0.03],
          ['up_level_change_3h', 0.35, 0.02],
        ]),
        station('JHR-BULOH', 8.00, 8.52, 8.30, 8.71, [
          ['rain_sum_3h', 85.0, 0.30],
          ['up_level_change_3h', 0.41, 0.15],
          ['level_change_1h', 0.12, 0.08],
        ]),
        station('JHR-SEGKECIL', 8.10, 8.35, 8.15, 8.55, [
          ['rain_sum_6h', 60.0, 0.15],
          ['level_change_3h', 0.30, 0.08],
        ]),
        station('JHR-CHAAH', 3.40, 3.42, 3.30, 3.55, [
          ['rain_sum_3h', 4.0, 0.01],
          ['level_above_normal', 0.40, 0.01],
        ]),
        station('SGR-KAJANG', 21.30, 21.28, 21.15, 21.40, [
          ['rain_sum_24h', 0.0, -0.03],
          ['level_change_3h', -0.04, -0.01],
        ]),
      ],
    });
  }
}
