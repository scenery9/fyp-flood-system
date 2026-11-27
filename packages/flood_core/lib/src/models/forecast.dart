import 'rain_outlook.dart';
import 'risk_level.dart';

/// One input the model used, and how much it moved the forecast (SHAP value).
class ForecastFactor {
  ForecastFactor({required this.feature, required this.value, required this.impactM});
  final String feature;
  final double? value;

  /// Metres added to (+) or taken off (-) the predicted change in river level.
  final double impactM;
}

/// The chance of reaching one JPS level, or that the river is already there.
class LevelChance {
  const LevelChance({required this.already, this.chance});
  final bool already;

  /// 0-1; null when [already] or when there were too few past crossings to learn from.
  final double? chance;
}

/// Chance of a flood within [horizonHours] (ml/flood_ml/probability.py). "Flood" is the
/// river reaching [headlineLevel] (JPS Warning, Amaran); [levels] also holds Alert and
/// Danger. A higher level never has a higher chance than a lower one.
/// [factors] are the headline model's exact TreeSHAP values in log-odds: positive raises
/// the chance. [inputsNow] are the readings behind the reasons (rain hours, mm, ...).
class FloodChance {
  FloodChance({
    required this.horizonHours,
    this.headlineLevel = RiskLevel.warning,
    this.already = false,
    this.chance,
    this.levels = const {},
    this.factors = const [],
    this.inputsNow = const {},
    this.capped = false,
  });
  final int horizonHours;
  final RiskLevel headlineLevel;

  /// The river is at [headlineLevel] or above now.
  final bool already;

  /// 0-1 for [headlineLevel]; null when [already] or not known.
  final double? chance;
  final Map<RiskLevel, LevelChance> levels;

  /// Same shape as the level forecast's factors; impactM holds the log-odds impact.
  final List<ForecastFactor> factors;
  final Map<String, double> inputsNow;

  /// The headline chance was lowered to the Alert chance (a river must pass Alert first),
  /// so the factors add up to a little more than it.
  final bool capped;

  bool get alreadyAtAlert => levels[RiskLevel.alert]?.already ?? (headlineLevel == RiskLevel.alert && already);
}

/// How the chance model did on the day it was calibrated on (not trained on).
class ChanceCheck {
  ChanceCheck({required this.day, required this.events, required this.reliable, this.brier, this.brierClimatology});
  final String day;
  final int events;

  /// False when too few rivers reached Alert that day to trust the stated chances.
  final bool reliable;
  final double? brier;
  final double? brierClimatology;
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
    this.rainOutlook,
    this.floodChance,
  });
  final String stationId;
  final DateTime basedOn;
  final double currentLevelM;
  final double predictedLevelM;
  final double lowM;
  final double highM;
  final List<ForecastFactor> factors;

  /// Schema 2: the 3-day rain outlook the model saw (null in schema 1 or when none was logged).
  final RainOutlook? rainOutlook;
  final FloodChance? floodChance;
}

class ForecastFile {
  ForecastFile({
    required this.generatedAt,
    required this.horizonHours,
    required this.modelName,
    required this.isPracticeData,
    required this.stations,
    this.weatherForecastUsed = false,
    this.chanceCheck,
  });
  final DateTime generatedAt;
  final int horizonHours;
  final String modelName;

  /// True while the model is trained on generated practice data, not real readings.
  final bool isPracticeData;
  final Map<String, RawStationForecast> stations;

  /// Whether the model was trained with weather-forecast inputs (chosen on validation).
  final bool weatherForecastUsed;
  final ChanceCheck? chanceCheck;
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
    this.currentRisk,
    this.factors = const [],
    this.rainOutlook,
    this.floodChance,
    this.chanceCheck,
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

  /// Risk level of the current reading the forecast started from (null without thresholds).
  final RiskLevel? currentRisk;

  /// The inputs behind [reasons], in the same order, so the app can word
  /// them in other languages.
  final List<ForecastFactor> factors;

  /// The 3-day rain outlook the forecast was made with, if any.
  final RainOutlook? rainOutlook;

  /// Chance of reaching Alert within 24 hours, and how trustworthy it was on its check day.
  final FloodChance? floodChance;
  final ChanceCheck? chanceCheck;

  static const String disclaimer = 'This is a computer prediction, not an official warning.';
}
