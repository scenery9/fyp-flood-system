import 'risk_level.dart';

/// One input the model used, and how much it moved the forecast (SHAP value).
class ForecastFactor {
  ForecastFactor({required this.feature, required this.value, required this.impactM});
  final String feature;
  final double? value;

  /// Metres added to (+) or taken off (-) the predicted change in river level.
  final double impactM;
}

/// One station's entry in forecast.json, exactly as the model wrote it.
class RawStationForecast {
  RawStationForecast({
    required this.stationId,
    required this.basedOn,
    required this.currentLevelM,
    required this.predictedLevelM,
    required this.lowM,
    required this.highM,
    required this.factors,
  });
  final String stationId;
  final DateTime basedOn;
  final double currentLevelM;
  final double predictedLevelM;
  final double lowM;
  final double highM;
  final List<ForecastFactor> factors;
}

class ForecastFile {
  ForecastFile({
    required this.generatedAt,
    required this.horizonHours,
    required this.modelName,
    required this.isPracticeData,
    required this.stations,
  });
  final DateTime generatedAt;
  final int horizonHours;
  final String modelName;

  /// True while the model is trained on generated practice data, not real readings.
  final bool isPracticeData;
  final Map<String, RawStationForecast> stations;
}

enum Trend { rising, steady, falling }

/// What the UI shows for one station: the forecast line and the "Why?" reasons.
class StationForecast {
  StationForecast({
    required this.stationId,
    required this.horizonHours,
    required this.validAt,
    required this.predictedLevelM,
    required this.lowM,
    required this.highM,
    required this.changeM,
    required this.trend,
    required this.predictedRisk,
    required this.worstCaseRisk,
    required this.summary,
    required this.reasons,
    required this.isPracticeData,
  });
  final String stationId;
  final int horizonHours;

  /// The time the forecast is for.
  final DateTime validAt;
  final double predictedLevelM;
  final double lowM;
  final double highM;
  final double changeM;
  final Trend trend;

  /// Null for stations without thresholds.
  final RiskLevel? predictedRisk;

  /// Risk level if the river reaches the top of the likely range.
  final RiskLevel? worstCaseRisk;

  /// One line, e.g. "Expected to rise to Warning level in about 3 hours".
  final String summary;

  /// Up to three plain-language reasons ("Kenapa?").
  final List<String> reasons;
  final bool isPracticeData;

  static const String disclaimer = 'This is a computer prediction, not an official warning.';
}
