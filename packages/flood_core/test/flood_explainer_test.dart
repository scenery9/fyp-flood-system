import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';

ForecastFactor f(String feature, double? value, double impact) =>
    ForecastFactor(feature: feature, value: value, impactM: impact);

FloodChance chance(double? p, List<ForecastFactor> factors,
        {Map<String, double> inputs = const {}, bool already = false}) =>
    FloodChance(horizonHours: 24, chance: p, already: already, factors: factors, inputsNow: inputs);

void main() {
  test('chance bands: low, moderate, high, very high', () {
    expect([0.0, 0.09, 0.1, 0.29, 0.3, 0.59, 0.6, 1.0].map(ChanceBand.fromChance).toList(), [
      ChanceBand.low, ChanceBand.low, ChanceBand.moderate, ChanceBand.moderate,
      ChanceBand.high, ChanceBand.high, ChanceBand.veryHigh, ChanceBand.veryHigh,
    ]);
  });

  test('hours of rain without a break become one "continuous rain" reason', () {
    final e = FloodExplainer.explain(chance(0.35, [
      f('consecutive_wet_hours', 7, 0.5),
      f('rain_sum_6h', 40, 0.3),
      f('rain_sum_24h', 48, 0.2),
      f('fill_to_target', 0.85, 0.6),
      f('level_change_3h', 0.4, 0.2),
      f('fc_rain_day1_mm', 2, -0.3),
    ], inputs: {'rain_sum_24h': 48}));
    expect(e.band, ChanceBand.high);
    final top = e.supporting.first;
    expect(top.kind, FloodReasonKind.continuousRain);
    expect((top.hours, top.mm, top.windowHours), (7, 48.0, 24));
    expect(top.weight, closeTo(1.0, 1e-9)); // 0.5 + 0.3 + 0.2: the group's summed impact
    expect(e.supporting.map((r) => r.kind), [
      FloodReasonKind.continuousRain, FloodReasonKind.riverHeight, FloodReasonKind.riverTrend,
    ]);
    expect(e.supporting[1].fraction, 0.85);
    expect(e.supporting[1].level, RiskLevel.warning);
    expect(e.against.single.kind, FloodReasonKind.forecastRain);
    expect(e.against.single.mm, 2.0);
  });

  test('short showers are "recent rain"; tiny impacts are left out', () {
    final e = FloodExplainer.explain(chance(0.05, [
      f('consecutive_wet_hours', 1, 0.1),
      f('rain_sum_24h', 12, 0.2),
      f('up_level_change_3h', 0.01, 0.01),
    ], inputs: {'wet_hours_24h': 4}));
    expect(e.band, ChanceBand.low);
    expect(e.supporting.single.kind, FloodReasonKind.recentRain);
    expect((e.supporting.single.mm, e.supporting.single.hours), (12.0, 4));
    expect(e.against, isEmpty);
  });

  test('a MET warning that raised the chance is named as such', () {
    final e = FloodExplainer.explain(chance(0.2, [
      f('met_warning_level', 2, 0.3),
      f('fc_rain_day1_mm', 35, 0.2),
    ], inputs: {'fc_rain_prob_day1': 88}));
    final r = e.supporting.single;
    expect((r.kind, r.metLevel, r.mm, r.percent), (FloodReasonKind.metWarning, 2, 35.0, 88.0));
  });

  test('already at the headline level: no band', () {
    final e = FloodExplainer.explain(chance(null, const [], already: true));
    expect(e.band, isNull);
    expect(e.supporting, isEmpty);
  });
}
