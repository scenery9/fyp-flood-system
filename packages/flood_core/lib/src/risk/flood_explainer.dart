import '../models/forecast.dart';
import '../models/risk_level.dart';

/// How likely, in words, from the flood chance (0-1).
enum ChanceBand {
  low, // under 10%
  moderate, // 10-30%
  high, // 30-60%
  veryHigh; // 60% or more

  static ChanceBand fromChance(double p) {
    if (p < 0.10) return low;
    if (p < 0.30) return moderate;
    if (p < 0.60) return high;
    return veryHigh;
  }
}

/// What a group of model inputs says, as one plain reason.
enum FloodReasonKind {
  /// Rain without a break for [FloodReason.hours] hours, [FloodReason.mm] in the last
  /// [FloodReason.windowHours] hours ([FloodReason.intensity]: rate over that window).
  continuousRain,

  /// Rain in the last 24 hours: [FloodReason.mm], on [FloodReason.hours] separate wet hours.
  recentRain,

  /// Rain over the last 3 days ([FloodReason.mm]): the ground is already wet (or dry).
  wetGround,

  /// The river is [FloodReason.fraction] of the way from Normal to [FloodReason.level].
  riverHeight,

  /// The river changed by [FloodReason.metres] in the last 3 hours (+ rising, - falling).
  riverTrend,

  /// Upstream: river change [FloodReason.metres] in 3 hours, rain [FloodReason.mm] in 6 hours.
  upstream,

  /// Forecast: [FloodReason.mm] in the next 24 h, [FloodReason.percent] of weather models
  /// expect rain; [FloodReason.next3hMm] in the next 3 hours.
  forecastRain,

  /// A MET Malaysia warning is in force: level [FloodReason.metLevel] (1 Waspada, 2 Buruk, 3 Bahaya).
  metWarning,
}

/// One reason for (or against) a flood. [weight] is the summed model impact in log-odds.
class FloodReason {
  const FloodReason(this.kind,
      {required this.supports,
      required this.weight,
      this.hours,
      this.mm,
      this.windowHours,
      this.intensity,
      this.fraction,
      this.level,
      this.metres,
      this.percent,
      this.next3hMm,
      this.metLevel});
  final FloodReasonKind kind;

  /// True when it raises the chance.
  final bool supports;
  final double weight;
  final int? hours;
  final double? mm;
  final int? windowHours;
  final RainIntensity? intensity;
  final double? fraction;
  final RiskLevel? level;
  final double? metres;
  final double? percent;
  final double? next3hMm;
  final int? metLevel;
}

/// The flood chance with its band and its strongest reasons for and against.
class FloodExplanation {
  const FloodExplanation(
      {required this.chance, required this.supporting, required this.against, this.band});
  final FloodChance chance;

  /// Null when the river is already at the headline level or the chance is not known.
  final ChanceBand? band;

  /// Strongest first; at most [FloodExplainer.maxSupporting].
  final List<FloodReason> supporting;

  /// At most [FloodExplainer.maxAgainst].
  final List<FloodReason> against;
}

/// Groups the chance model's inputs (TreeSHAP, log-odds) into a few plain reasons, so the
/// app can say "Rain without a break for 7 hours (48 mm)" instead of listing 20 numbers.
/// Each group's weight is the sum of its inputs' impacts, so the reasons still come from
/// the model: a group is "for" when the model's inputs in it raised the chance.
class FloodExplainer {
  static const maxSupporting = 3;
  static const maxAgainst = 1;

  /// Impacts smaller than this (log-odds) are not worth a sentence.
  static const minWeight = 0.05;

  /// Rain without a break for at least this many hours counts as "continuous".
  static const continuousHours = 3;

  static const _groups = <FloodReasonKind, List<String>>{
    FloodReasonKind.recentRain: [
      'rain_sum_1h', 'rain_sum_3h', 'rain_sum_6h', 'rain_sum_24h', 'wet_hours_24h', 'consecutive_wet_hours'
    ],
    FloodReasonKind.wetGround: ['rain_sum_72h', 'api_7d', 'wet_days_3d'],
    FloodReasonKind.riverHeight: ['fill_to_target', 'level_above_normal'],
    FloodReasonKind.riverTrend: [
      'level_change_1h', 'level_change_2h', 'level_change_3h', 'same_time_12h_ago', 'same_time_25h_ago'
    ],
  };

  static FloodReasonKind? _groupOf(String feature) {
    if (feature.startsWith('up_')) return FloodReasonKind.upstream;
    if (feature.startsWith('fc_') || feature.startsWith('met_')) return FloodReasonKind.forecastRain;
    for (final e in _groups.entries) {
      if (e.value.contains(feature)) return e.key;
    }
    return null;
  }

  static FloodExplanation explain(FloodChance fc) {
    final weights = <FloodReasonKind, double>{};
    final values = <String, double>{...fc.inputsNow};
    for (final f in fc.factors) {
      if (f.value != null) values[f.feature] = f.value!;
      final g = _groupOf(f.feature);
      if (g != null) weights[g] = (weights[g] ?? 0) + f.impactM;
    }
    final reasons = <FloodReason>[
      for (final e in weights.entries)
        if (e.value.abs() >= minWeight) _reason(e.key, e.value, values, fc.headlineLevel),
    ];
    final up = reasons.where((r) => r.supports).toList()..sort((a, b) => b.weight.compareTo(a.weight));
    final down = reasons.where((r) => !r.supports).toList()..sort((a, b) => a.weight.compareTo(b.weight));
    final p = fc.chance;
    return FloodExplanation(
      chance: fc,
      band: fc.already || p == null ? null : ChanceBand.fromChance(p),
      supporting: up.take(maxSupporting).toList(),
      against: down.take(maxAgainst).toList(),
    );
  }

  static FloodReason _reason(FloodReasonKind kind, double w, Map<String, double> v, RiskLevel level) {
    final s = w > 0;
    switch (kind) {
      case FloodReasonKind.recentRain:
        final run = (v['consecutive_wet_hours'] ?? 0).round();
        if (s && run >= continuousHours) {
          // the rain window that best covers the run (its total is exact for runs of 3 or 6 h)
          final window = run <= 3 ? 3 : (run <= 6 ? 6 : 24);
          final mm = v['rain_sum_${window}h'];
          return FloodReason(FloodReasonKind.continuousRain,
              supports: s,
              weight: w,
              hours: run,
              mm: mm,
              windowHours: window,
              intensity: mm == null ? null : RainIntensity.fromMm(mm / (run < window ? run : window)));
        }
        return FloodReason(kind,
            supports: s, weight: w, mm: v['rain_sum_24h'], hours: v['wet_hours_24h']?.round(), windowHours: 24);
      case FloodReasonKind.wetGround:
        return FloodReason(kind, supports: s, weight: w, mm: v['rain_sum_72h'], windowHours: 72);
      case FloodReasonKind.riverHeight:
        return FloodReason(kind, supports: s, weight: w, fraction: v['fill_to_target'], level: level);
      case FloodReasonKind.riverTrend:
        return FloodReason(kind, supports: s, weight: w, metres: v['level_change_3h'] ?? v['level_change_1h']);
      case FloodReasonKind.upstream:
        return FloodReason(kind,
            supports: s, weight: w, metres: v['up_level_change_3h'], mm: v['up_rain_sum_6h']);
      case FloodReasonKind.forecastRain:
      case FloodReasonKind.metWarning:
        final met = (v['met_warning_level'] ?? 0).round();
        return FloodReason(s && met >= 1 ? FloodReasonKind.metWarning : FloodReasonKind.forecastRain,
            supports: s,
            weight: w,
            mm: v['fc_rain_day1_mm'],
            percent: v['fc_rain_prob_day1'],
            next3hMm: v['fc_rain_next_3h'],
            metLevel: met);
      case FloodReasonKind.continuousRain:
        return FloodReason(kind, supports: s, weight: w);
    }
  }
}
