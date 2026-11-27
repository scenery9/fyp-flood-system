import '../models/rain_outlook.dart';
import '../models/risk_level.dart';
import '../models/station_status.dart';

/// How strongly the weather forecast points to heavy rain.
enum RainSignal {
  /// Nothing heavy forecast.
  none,

  /// Only one source sees heavy rain (shown, but the outlook is not raised).
  possible,

  /// Open-Meteo forecasts very heavy rain with a high chance AND MET Malaysia
  /// also expects rain (or has a warning out).
  likely,

  /// MET Malaysia has a Buruk or Bahaya warning in force for the district.
  official,
}

/// One reason in the "why" list: what was measured or forecast, in plain words.
/// [source] names the entry in docs/references.md that backs the threshold used.
class RiskReason {
  const RiskReason(this.factor, this.text, {this.source});

  /// Stable key, so the app can word it in other languages, e.g. "river_level",
  /// "forecast_day1", "met_warning".
  final String factor;
  final String text;
  final String? source;
}

class JointAssessment {
  JointAssessment({
    required this.measured,
    required this.outlook,
    required this.signal,
    required this.reasons,
    this.signalDay,
    this.rainOutlook,
  });

  /// From the river reading alone (RiskCalculator): never changed by a forecast.
  final RiskLevel? measured;

  /// Measured level, raised by one when heavy rain is [RainSignal.likely] or
  /// [RainSignal.official] and the river is already high.
  final RiskLevel? outlook;
  final RainSignal signal;

  /// Which day (1-3) the strongest rain signal is for.
  final int? signalDay;

  /// Plain reasons, the river first, then the forecast, then the conclusion.
  final List<RiskReason> reasons;

  /// The outlook this was worked out from (null: none for this station).
  final RainOutlook? rainOutlook;

  bool get raised => measured != null && outlook != null && outlook!.index > measured!.index;
}

/// Joins the measured river level with the 3-day rain outlook (Open-Meteo and
/// MET Malaysia). Rule, in order:
///  1. The measured level is kept as it is.
///  2. Per day: very heavy rain (>= [veryHeavyDayMm] mm, ETCCDI R20mm) from Open-Meteo
///     with >= [minChancePct]% of models expecting rain is "likely" when MET Malaysia
///     also forecasts rain or has any warning out, and only "possible" otherwise.
///     A MET Buruk/Bahaya warning is "official" by itself.
///  3. If the signal is likely or official and the river is at Alert or above, or at
///     least [nearAlertPercent]% of the way to Alert, the outlook is one level higher.
/// Thresholds come from docs/rain-forecast-evidence.md and docs/references.md.
class JointRiskCalculator {
  const JointRiskCalculator({this.minChancePct = 70, this.nearAlertPercent = 80});

  final double minChancePct;
  final double nearAlertPercent;

  JointAssessment assess(StationStatus status, RainOutlook? outlook) {
    final measured = status.isStale ? null : status.level;
    final reasons = <RiskReason>[..._riverReasons(status)];
    var signal = RainSignal.none;
    int? signalDay;

    void raise(RainSignal s, int day) {
      if (s.index > signal.index) {
        signal = s;
        signalDay = day;
      }
    }

    if (outlook != null) {
      if (outlook.next3hMm != null && outlook.next3hMm! >= rainDayMm) {
        reasons.add(RiskReason('forecast_next_3h',
            'Open-Meteo: ${_mm(outlook.next3hMm!)} of rain forecast in the next 3 hours'
            '${outlook.next3hChancePct == null ? '' : ' (${outlook.next3hChancePct!.round()}% of weather models)'}',
            source: 'open-meteo'));
      }
      for (final d in outlook.days) {
        final mm = d.mm;
        final veryHeavy = mm != null && mm >= veryHeavyDayMm && (d.chancePct ?? 0) >= minChancePct;
        final metWet = d.met != null && d.met!.index >= 1;
        final warned = d.day == 1 && outlook.warning != MetWarningLevel.none;
        if (veryHeavy) raise(metWet || warned ? RainSignal.likely : RainSignal.possible, d.day);
        if (d.met != null && d.met!.index >= MetRainClass.mostPlaces.index && !veryHeavy) {
          raise(RainSignal.possible, d.day);
        }
        if (mm != null && mm >= heavyDayMm) {
          reasons.add(RiskReason('forecast_day${d.day}',
              'Open-Meteo: ${_mm(mm)} of rain forecast for ${d.windowEn} '
              '(${d.band!.labelEn.toLowerCase()}'
              '${d.chancePct == null ? '' : ', ${d.chancePct!.round()}% of weather models expect rain'})',
              source: 'etccdi'));
        }
        if (d.met != null && (d.met!.index >= 1 || (mm != null && mm >= heavyDayMm))) {
          reasons.add(RiskReason('met_day${d.day}',
              'MET Malaysia: ${d.metText ?? d.met!.labelEn} (${d.windowEn})',
              source: 'met-malaysia'));
        }
        if (d.sourcesAgree == false && ((mm ?? 0) >= heavyDayMm || (d.met?.index ?? 0) >= 2)) {
          reasons.add(RiskReason('sources_disagree_day${d.day}',
              'The two forecasts disagree for ${d.windowEn}: Open-Meteo ${_mm(mm!)}, '
              'MET Malaysia "${d.metText ?? d.met!.labelEn}"'));
        }
      }
      if (outlook.warning.index >= MetWarningLevel.buruk.index) raise(RainSignal.official, 1);
      if (outlook.warning != MetWarningLevel.none) {
        reasons.add(RiskReason('met_warning',
            'MET Malaysia warning in force: ${outlook.warningTitle ?? 'rain warning'} '
            '(${outlook.warning.labelEn})',
            source: 'met-warnings'));
      }
      if ((outlook.rainDays3d ?? 0) >= 2 && outlook.total3dMm != null) {
        reasons.add(RiskReason('rain_days_3d',
            'Rain forecast on ${outlook.rainDays3d} of the next 3 days (${_mm(outlook.total3dMm!)} in total)',
            source: 'evidence'));
      }
    }

    var result = measured;
    final high = measured != null &&
        (measured.isAtLeast(RiskLevel.alert) ||
            (status.percentToTarget != null && status.percentToTarget! >= nearAlertPercent));
    if (measured != null && high && (signal == RainSignal.likely || signal == RainSignal.official)) {
      result = RiskLevel.values[(measured.index + 1).clamp(0, RiskLevel.values.length - 1)];
    }
    if (result != null && measured != null && result.index > measured.index) {
      final when = signalDay == 1 ? 'in the next 24 hours' : 'within ${signalDay! * 24} hours';
      final why = signal == RainSignal.official
          ? 'MET Malaysia has a ${outlook!.warning.labelEn} warning out'
          : 'very heavy rain is forecast $when and both forecasts expect rain';
      reasons.add(RiskReason('outlook',
          'Outlook raised to ${result.labelEn}: $why while the river is '
          '${measured == RiskLevel.normal ? 'close to Alert' : 'already at ${measured.labelEn}'}',
          source: 'evidence'));
    } else if (signal == RainSignal.possible) {
      reasons.add(const RiskReason('outlook_possible',
          'Possible heavy rain (only one forecast sees it): outlook not raised'));
    }
    return JointAssessment(
        measured: measured, outlook: result, signal: signal, signalDay: signalDay, reasons: reasons,
        rainOutlook: outlook);
  }

  List<RiskReason> _riverReasons(StationStatus s) {
    final level = s.reading?.riverLevelM;
    final t = s.station.thresholds;
    if (s.isStale || level == null || t == null || s.level == null) return const [];
    final m = level.toStringAsFixed(2);
    if (s.level == RiskLevel.normal) {
      return [
        RiskReason('river_level',
            'River at $m m, ${s.percentToTarget?.round() ?? 0}% of the way to Alert (${t.alert.toStringAsFixed(2)} m)',
            source: 'jps-thresholds')
      ];
    }
    final line = switch (s.level!) {
      RiskLevel.danger => t.danger,
      RiskLevel.warning => t.warning,
      _ => t.alert,
    };
    return [
      RiskReason('river_level', 'River at $m m, above ${s.level!.labelEn} (${line.toStringAsFixed(2)} m)',
          source: 'jps-thresholds')
    ];
  }

  static String _mm(double v) => v < 0.5 ? 'almost no rain' : '${v.round()} mm';
}
