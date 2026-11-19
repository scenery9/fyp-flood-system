import 'dart:convert';

import '../data/supabase_api.dart' show HttpSend;
import '../errors.dart';
import '../models/forecast.dart';
import '../models/risk_level.dart';
import '../models/station.dart';
import '../models/station_status.dart';

/// Where forecast.json comes from.
abstract class ForecastSource {
  Future<String> fetch();
}

/// Downloads forecast.json from a URL (the public `forecasts` bucket in
/// Supabase Storage). Anything but a 2xx reply is an error.
class RemoteForecastSource implements ForecastSource {
  RemoteForecastSource(this.uri, this.send);
  final Uri uri;
  final HttpSend send;

  @override
  Future<String> fetch() async {
    final r = await send('GET', uri);
    if (!r.ok) throw StateError('Forecast download failed: HTTP ${r.status}');
    return r.body;
  }
}

/// Uses [primary] (the real model's file) when it is there, readable and
/// recent; otherwise [fallback] (the practice forecast). Chosen per file, so
/// real and practice forecasts are never mixed. Once the model job starts
/// uploading, the app switches over on its next refresh with no new release.
class FallbackForecastSource implements ForecastSource {
  FallbackForecastSource(this.primary, this.fallback,
      {DateTime Function()? clock, this.maxAge = const Duration(hours: 2)})
      : _clock = clock ?? DateTime.now;
  final ForecastSource primary;
  final ForecastSource fallback;
  final DateTime Function() _clock;

  /// Same limit as [ForecastService.maxAge]: an older real file is not used.
  final Duration maxAge;

  @override
  Future<String> fetch() async {
    try {
      final body = await primary.fetch();
      final file = parseForecast(body);
      final age = _clock().difference(file.generatedAt);
      if (age <= maxAge && age >= const Duration(minutes: -10)) return body;
    } catch (_) {
      // Not there yet, unreadable or offline: use the fallback.
    }
    return fallback.fetch();
  }
}

/// Reads forecast.json (schema 1). Throws [ForecastFormatException] if it is wrong.
ForecastFile parseForecast(String body) {
  try {
    final j = jsonDecode(body);
    if (j is! Map) throw ForecastFormatException('Not a JSON object');
    if (j['schema'] != 1) throw ForecastFormatException('Unsupported schema: ${j['schema']}');
    double num_(dynamic v, String name) {
      if (v is! num || v.isNaN || v.isInfinite) throw ForecastFormatException('Bad number: $name');
      return v.toDouble();
    }

    final horizon = j['horizon_hours'];
    if (horizon is! int || horizon < 1 || horizon > 24) {
      throw ForecastFormatException('Bad horizon_hours');
    }
    final stations = <String, RawStationForecast>{};
    for (final s in j['stations'] as List) {
      final m = s as Map;
      final id = m['station_id'] as String;
      final low = num_(m['low_m'], 'low_m');
      final high = num_(m['high_m'], 'high_m');
      final predicted = num_(m['predicted_level_m'], 'predicted_level_m');
      if (low > predicted || predicted > high) throw ForecastFormatException('Range does not contain the prediction: $id');
      stations[id] = RawStationForecast(
          stationId: id,
          basedOn: DateTime.parse(m['based_on'] as String).toUtc(),
          currentLevelM: num_(m['current_level_m'], 'current_level_m'),
          predictedLevelM: predicted,
          lowM: low,
          highM: high,
          factors: [
            for (final f in (m['factors'] as List?) ?? const [])
              ForecastFactor(
                  feature: (f as Map)['feature'] as String,
                  value: f['value'] is num ? (f['value'] as num).toDouble() : null,
                  impactM: num_(f['impact_m'], 'impact_m')),
          ]);
    }
    return ForecastFile(
        generatedAt: DateTime.parse(j['generated_at'] as String).toUtc(),
        horizonHours: horizon,
        modelName: '${(j['model'] as Map?)?['name'] ?? 'unknown'}',
        isPracticeData: j['is_practice_data'] != false, // anything but an explicit false counts as practice
        stations: stations);
  } on ForecastFormatException {
    rethrow;
  } catch (e) {
    throw ForecastFormatException('Could not read forecast file');
  }
}

/// Result of loading forecasts. When [forecasts] is empty, [unavailableReason] says why.
class ForecastResult {
  ForecastResult(this.forecasts, {this.unavailableReason, this.generatedAt});
  final Map<String, StationForecast> forecasts;
  final String? unavailableReason;
  final DateTime? generatedAt;
}

/// Turns the model's forecast file into what the app shows. It never
/// throws: if the forecast cannot be trusted, the app simply shows none.
class ForecastService {
  ForecastService({
    required this.source,
    DateTime Function()? clock,
    this.maxAge = const Duration(hours: 2),
    this.steadyBandM = 0.05,
    this.maxReasons = 3,
  }) : _clock = clock ?? DateTime.now;
  final ForecastSource source;
  final DateTime Function() _clock;

  /// A forecast older than this is not shown.
  final Duration maxAge;

  /// Changes smaller than this (metres) are called "steady".
  final double steadyBandM;
  final int maxReasons;

  Future<ForecastResult> load(List<StationStatus> statuses) async {
    final ForecastFile file;
    try {
      file = parseForecast(await source.fetch());
    } on ForecastFormatException {
      return ForecastResult({}, unavailableReason: 'Forecast file could not be read');
    } catch (_) {
      return ForecastResult({}, unavailableReason: 'Forecast could not be downloaded');
    }
    final now = _clock();
    if (now.difference(file.generatedAt) > maxAge) {
      return ForecastResult({}, unavailableReason: 'Forecast is out of date', generatedAt: file.generatedAt);
    }
    if (file.generatedAt.difference(now) > const Duration(minutes: 10)) {
      return ForecastResult({}, unavailableReason: 'Forecast has a wrong time', generatedAt: file.generatedAt);
    }
    final out = <String, StationForecast>{};
    for (final s in statuses) {
      final raw = file.stations[s.station.id];
      if (raw == null || now.difference(raw.basedOn) > maxAge) continue;
      if (!_plausible(raw, s.station.thresholds)) continue;
      out[s.station.id] = _build(raw, s, file);
    }
    return ForecastResult(out,
        generatedAt: file.generatedAt,
        unavailableReason: out.isEmpty ? 'No forecast for these stations' : null);
  }

  /// Rejects absurd values (a broken model must not scare or reassure anyone).
  bool _plausible(RawStationForecast r, Thresholds? t) {
    if ((r.predictedLevelM - r.currentLevelM).abs() > 5) return false;
    if (t == null) return true;
    final span = t.danger - t.normal;
    return r.predictedLevelM > t.normal - 3 * span && r.predictedLevelM < t.danger + 3 * span;
  }

  StationForecast _build(RawStationForecast raw, StationStatus s, ForecastFile file) {
    final t = s.station.thresholds;
    final change = raw.predictedLevelM - raw.currentLevelM;
    final trend = change >= steadyBandM
        ? Trend.rising
        : (change <= -steadyBandM ? Trend.falling : Trend.steady);
    final risk = t == null ? null : _risk(raw.predictedLevelM, t);
    final currentRisk = t == null ? null : _risk(raw.currentLevelM, t);
    final h = file.horizonHours;
    final String summary;
    if (risk == null) {
      summary = switch (trend) {
        Trend.rising => 'River expected to rise by ${change.toStringAsFixed(2)} m in about $h hours',
        Trend.falling => 'River expected to fall by ${(-change).toStringAsFixed(2)} m in about $h hours',
        Trend.steady => 'River expected to stay about the same for the next $h hours',
      };
    } else if (risk.index > currentRisk!.index) {
      summary = 'Expected to rise to ${risk.labelEn} level in about $h hours';
    } else if (risk.index < currentRisk.index) {
      summary = 'Expected to fall to ${risk.labelEn} level in about $h hours';
    } else {
      summary = 'Expected to stay at ${risk.labelEn} level for the next $h hours';
    }
    // A station without upstream readings gets no "upstream" reason: there is nothing to explain.
    final factors = [
      ...raw.factors.where((f) => f.impactM.abs() >= 0.01 && !(f.value == null && isUpstreamInput(f.feature)))
    ]
      ..sort((a, b) => b.impactM.abs().compareTo(a.impactM.abs()));
    return StationForecast(
        stationId: raw.stationId,
        horizonHours: h,
        validAt: raw.basedOn.add(Duration(hours: h)),
        predictedLevelM: raw.predictedLevelM,
        lowM: raw.lowM,
        highM: raw.highM,
        changeM: change,
        trend: trend,
        predictedRisk: risk,
        worstCaseRisk: t == null ? null : _risk(raw.highM, t),
        summary: summary,
        reasons: [for (final f in factors.take(maxReasons)) describeFactor(f)],
        isPracticeData: file.isPracticeData,
        currentRisk: currentRisk,
        factors: factors.take(maxReasons).toList());
  }

  RiskLevel _risk(double level, Thresholds t) {
    if (level >= t.danger) return RiskLevel.danger;
    if (level >= t.warning) return RiskLevel.warning;
    if (level >= t.alert) return RiskLevel.alert;
    return RiskLevel.normal;
  }

  static const Map<String, String> _rainWindows = {
    'rain_sum_1h': 'the last hour',
    'rain_sum_3h': 'the last 3 hours',
    'rain_sum_6h': 'the last 6 hours',
    'rain_sum_24h': 'the last 24 hours',
  };
  static const Map<String, String> _changeWindows = {
    'level_change_1h': 'the last hour',
    'level_change_3h': 'the last 3 hours',
  };

  /// Inputs taken from the stations upstream of this one (averaged).
  static const Map<String, String> _upRainWindows = {
    'up_rain_sum_3h': 'the last 3 hours',
    'up_rain_sum_6h': 'the last 6 hours',
  };
  static const Map<String, String> _upChangeWindows = {
    'up_level_change_1h': 'the last hour',
    'up_level_change_3h': 'the last 3 hours',
  };

  static bool isUpstreamInput(String feature) =>
      _upRainWindows.containsKey(feature) || _upChangeWindows.containsKey(feature);

  /// One plain sentence: what was measured, and which way it moved the forecast.
  static String describeFactor(ForecastFactor f) {
    final effect = f.impactM > 0 ? 'raises the forecast' : 'lowers the forecast';
    final v = f.value;
    String what;
    if (isUpstreamInput(f.feature) && v == null) {
      what = 'No upstream river readings';
    } else if (_upRainWindows.containsKey(f.feature) && v != null) {
      what = v < 0.5
          ? 'Almost no rain upstream in ${_upRainWindows[f.feature]}'
          : '${v.round()} mm of rain upstream in ${_upRainWindows[f.feature]}';
    } else if (_upChangeWindows.containsKey(f.feature) && v != null) {
      what = v.abs() < 0.005
          ? 'Upstream river unchanged in ${_upChangeWindows[f.feature]}'
          : 'Upstream river ${v > 0 ? 'rose' : 'fell'} ${v.abs().toStringAsFixed(2)} m in ${_upChangeWindows[f.feature]}';
    } else if (_rainWindows.containsKey(f.feature) && v != null) {
      what = v < 0.5
          ? 'Almost no rain in ${_rainWindows[f.feature]}'
          : '${v.round()} mm of rain in ${_rainWindows[f.feature]}';
    } else if (_changeWindows.containsKey(f.feature) && v != null) {
      what = v.abs() < 0.005
          ? 'River level unchanged in ${_changeWindows[f.feature]}'
          : 'River ${v > 0 ? 'rose' : 'fell'} ${v.abs().toStringAsFixed(2)} m in ${_changeWindows[f.feature]}';
    } else if (f.feature == 'level_above_normal' && v != null) {
      what = 'River is ${v.abs().toStringAsFixed(2)} m ${v >= 0 ? 'above' : 'below'} its normal level';
    } else {
      what = 'Other readings';
    }
    return '$what ($effect)';
  }
}
