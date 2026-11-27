import 'dart:convert';

import '../data/supabase_api.dart' show HttpSend;
import '../errors.dart';
import '../models/forecast.dart';
import '../models/rain_outlook.dart';
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

/// Reads forecast.json (schema 1, or 2 = 1 plus each station's `rain_outlook` and the
/// file's `inputs`). Throws [ForecastFormatException] if it is wrong.
ForecastFile parseForecast(String body) {
  try {
    final j = jsonDecode(body);
    if (j is! Map) throw ForecastFormatException('Not a JSON object');
    if (j['schema'] != 1 && j['schema'] != 2) throw ForecastFormatException('Unsupported schema: ${j['schema']}');
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
          ],
          rainOutlook: m['rain_outlook'] is Map ? RainOutlook.fromJson(id, m['rain_outlook'] as Map) : null,
          floodChance: m['flood_chance'] is Map ? _chance(m['flood_chance'] as Map) : null);
    }
    return ForecastFile(
        generatedAt: DateTime.parse(j['generated_at'] as String).toUtc(),
        horizonHours: horizon,
        modelName: '${(j['model'] as Map?)?['name'] ?? 'unknown'}',
        isPracticeData: j['is_practice_data'] != false, // anything but an explicit false counts as practice
        stations: stations,
        weatherForecastUsed: (j['inputs'] as Map?)?['weather_forecast_used'] == true,
        chanceCheck: _check((j['chance_model'] as Map?)?['calibration']));
  } on ForecastFormatException {
    rethrow;
  } catch (e) {
    throw ForecastFormatException('Could not read forecast file');
  }
}

double? _prob(Object? c) {
  if (c == null) return null;
  if (c is! num || c < 0 || c > 1) throw ForecastFormatException('Bad chance');
  return c.toDouble();
}

const _levelNames = {'alert': RiskLevel.alert, 'warning': RiskLevel.warning, 'danger': RiskLevel.danger};

FloodChance _chance(Map m) {
  final levels = <RiskLevel, LevelChance>{};
  final rawLevels = m['levels'];
  if (rawLevels is Map) {
    for (final e in rawLevels.entries) {
      final lv = _levelNames[e.key];
      if (lv == null || e.value is! Map) continue;
      final v = e.value as Map;
      levels[lv] = LevelChance(already: v['already'] == true, chance: _prob(v['chance']));
    }
  }
  // schema-2 files before the three levels: one Alert chance with already_at_alert
  final old = !m.containsKey('headline_level');
  final head = old ? RiskLevel.alert : (_levelNames[m['headline_level']] ?? RiskLevel.warning);
  final already = old ? m['already_at_alert'] == true : m['already'] == true;
  final chance = _prob(m['chance']);
  if (old) levels[RiskLevel.alert] = LevelChance(already: already, chance: chance);
  final inputs = <String, double>{
    if (m['inputs_now'] is Map)
      for (final e in (m['inputs_now'] as Map).entries)
        if (e.value is num) '${e.key}': (e.value as num).toDouble(),
  };
  return FloodChance(
    horizonHours: m['horizon_hours'] is int ? m['horizon_hours'] as int : 24,
    headlineLevel: head,
    already: already,
    chance: chance,
    levels: levels,
    inputsNow: inputs,
    capped: m['capped'] == true,
    factors: [
      for (final f in (m['factors'] as List?) ?? const [])
        if ((f as Map)['impact_logodds'] is num)
          ForecastFactor(
              feature: f['feature'] as String,
              value: f['value'] is num ? (f['value'] as num).toDouble() : null,
              impactM: (f['impact_logodds'] as num).toDouble()),
    ],
  );
}

ChanceCheck? _check(Object? c) {
  if (c is! Map) return null;
  double? d(Object? v) => v is num ? v.toDouble() : null;
  return ChanceCheck(
      day: '${c['day'] ?? ''}',
      events: c['events'] is int ? c['events'] as int : 0,
      reliable: c['reliable'] == true,
      brier: d(c['brier']),
      brierClimatology: d(c['brier_climatology']));
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
      ...raw.factors.where((f) => f.impactM.abs() >= 0.01 && !(f.value == null && (isUpstreamInput(f.feature) || isWeatherForecastInput(f.feature))))
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
        factors: factors.take(maxReasons).toList(),
        rainOutlook: raw.rainOutlook,
        floodChance: raw.floodChance,
        chanceCheck: file.chanceCheck);
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
    'rain_sum_72h': 'the last 3 days',
  };

  /// Weather-forecast inputs (Open-Meteo, MET Malaysia): the window they are about.
  static const Map<String, String> _forecastWindows = {
    'fc_rain_next_3h': 'the next 3 hours',
    'fc_rain_prob_next_3h': 'the next 3 hours',
    'fc_rain_day1_mm': 'the next 24 hours',
    'fc_rain_prob_day1': 'the next 24 hours',
    'met_rain_class_day1': 'the next 24 hours',
    'fc_rain_day2_mm': '24-48 hours from now',
    'fc_rain_prob_day2': '24-48 hours from now',
    'met_rain_class_day2': '24-48 hours from now',
    'fc_rain_day3_mm': '48-72 hours from now',
    'fc_rain_prob_day3': '48-72 hours from now',
    'met_rain_class_day3': '48-72 hours from now',
  };

  /// True for the inputs that come from a weather forecast rather than a reading.
  static bool isWeatherForecastInput(String feature) =>
      feature.startsWith('fc_') || feature.startsWith('met_') || feature == 'sources_agree_days_3d';

  /// Rain-history inputs (observed at the station): how long and how much it has been raining.
  static String? describeRainHistory(String feature, double? v) {
    if (v == null) return null;
    final n = v.round();
    return switch (feature) {
      'wet_hours_24h' => 'Rain fell in $n of the last 24 hours',
      'consecutive_wet_hours' => n == 0 ? 'Not raining at the station now' : 'Raining without a break for $n hour(s)',
      'wet_days_3d' => '$n of the last 3 days were rain days (1 mm or more)',
      'api_7d' => 'Ground wetness from the last 7 days of rain: $n mm (older rain counts less)',
      'fc_rain_day1_x_fill' => 'Forecast rain for the next 24 hours, weighted by how close the river is to Alert',
      _ => null,
    };
  }

  static String? _describeForecast(String feature, double? v) {
    if (feature == 'fc_rain_day1_x_fill') return null;
    if (!isWeatherForecastInput(feature)) return null;
    if (v == null) return 'No weather forecast logged';
    final w = _forecastWindows[feature];
    if (feature == 'fc_rain_next_3h' || (feature.startsWith('fc_rain_day') && feature.endsWith('_mm'))) {
      return v < 0.5 ? 'Forecast: almost no rain in $w' : 'Forecast: ${v.round()} mm of rain in $w';
    }
    if (feature.startsWith('fc_rain_prob')) return 'Forecast: ${v.round()}% of weather models expect rain in $w';
    if (feature.startsWith('met_rain_class_day')) {
      return 'MET Malaysia forecast: ${MetRainClass.fromNumber(v)?.labelEn ?? 'unknown'} in $w';
    }
    return switch (feature) {
      'fc_rain_days_3d' => 'Rain forecast on ${v.round()} of the next 3 days',
      'fc_rain_total_3d' => 'Forecast: ${v.round()} mm of rain over the next 3 days',
      'met_thunder_days_3d' => 'MET Malaysia: thunderstorms forecast on ${v.round()} of the next 3 days',
      'met_warning_level' => v < 0.5
          ? 'No MET Malaysia rain warning'
          : 'MET Malaysia warning in force: ${MetWarningLevel.fromNumber(v).labelEn}',
      'sources_agree_days_3d' => 'Open-Meteo and MET Malaysia agree on ${v.round()} of the next 3 days',
      _ => null,
    };
  }
  static const Map<String, String> _changeWindows = {
    'level_change_1h': 'the last hour',
    'level_change_2h': 'the last 2 hours',
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

  /// What the river did in the 3 hours after the same moment one cycle ago
  /// (12 h: about one tide; 25 h: about one day).
  static const Map<String, int> _cycleHours = {
    'same_time_12h_ago': 12,
    'same_time_25h_ago': 25,
  };

  static bool isUpstreamInput(String feature) =>
      _upRainWindows.containsKey(feature) || _upChangeWindows.containsKey(feature);

  /// One plain sentence: what was measured, and which way it moved the forecast.
  static String describeFactor(ForecastFactor f) {
    final effect = f.impactM > 0 ? 'raises the forecast' : 'lowers the forecast';
    final v = f.value;
    String what;
    final forecast = _describeForecast(f.feature, v) ?? describeRainHistory(f.feature, v);
    if (forecast != null) {
      what = forecast;
    } else if (isUpstreamInput(f.feature) && v == null) {
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
    } else if (_cycleHours.containsKey(f.feature) && v != null) {
      final h = _cycleHours[f.feature];
      what = v.abs() < 0.005
          ? '$h hours ago, the river stayed the same over the next 3 hours'
          : '$h hours ago, the river ${v > 0 ? 'rose' : 'fell'} ${v.abs().toStringAsFixed(2)} m over the next 3 hours';
    } else if (f.feature == 'level_above_normal' && v != null) {
      what = 'River is ${v.abs().toStringAsFixed(2)} m ${v >= 0 ? 'above' : 'below'} its normal level';
    } else {
      what = 'Other readings';
    }
    return '$what ($effect)';
  }
}
