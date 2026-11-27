import 'dart:convert';

import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

/// A weather_outlook row (supabase/weather.sql) with the values you choose.
Map<String, dynamic> row({
  double? d1 = 2, double? d2 = 2, double? d3 = 2, double prob = 90,
  int? met1 = 1, int? met2 = 1, int? met3 = 1, int warning = 0, String? warningTitle,
  double? next3h,
}) =>
    {
      'station_code': 'A', 'updated_at': '2026-11-17T03:00:00Z', 'om_issued_at': '2026-11-17T03:00:00Z',
      'next_3h_mm': next3h, 'next_3h_prob': next3h == null ? null : prob,
      'day1_mm': d1, 'day1_prob': prob, 'day1_met_class': met1, 'day1_met_text': met1 == 0 ? 'Tiada Hujan' : 'Ribut petir di beberapa tempat',
      'day2_mm': d2, 'day2_prob': prob, 'day2_met_class': met2, 'day2_met_text': null,
      'day3_mm': d3, 'day3_prob': prob, 'day3_met_class': met3, 'day3_met_text': null,
      'rain_days_3d': [d1, d2, d3].where((v) => v != null && v >= 1).length,
      'total_3d_mm': (d1 ?? 0) + (d2 ?? 0) + (d3 ?? 0),
      'warning_level': warning, 'warning_title': warningTitle,
    };

RainOutlook ol(Map<String, dynamic> r) => RainOutlook.fromJson('A', r);

void main() {
  // thresholds: normal 10, alert 12, warning 14, danger 16
  const calc = JointRiskCalculator();

  group('Rain outlook model', () {
    test('reads a weather_outlook row: 3 days, bands, MET classes, agreement', () {
      final o = ol(row(d1: 25, d2: 12, d3: 0.2, met1: 3, met2: 0, met3: 0));
      expect(o.days.map((d) => d.band), [DailyRainBand.veryHeavy, DailyRainBand.heavy, DailyRainBand.dry]);
      expect(o.days.first.met, MetRainClass.mostPlaces);
      expect(o.days.map((d) => d.sourcesAgree), [true, false, true]);
      expect(o.rainDays3d, 2);
      expect(o.hasOpenMeteo && o.hasMet, isTrue);
    });
    test('band thresholds are the ETCCDI 1 / 10 / 20 mm', () {
      expect([0.9, 1.0, 9.9, 10.0, 19.9, 20.0].map(DailyRainBand.fromMm), [
        DailyRainBand.dry, DailyRainBand.rainDay, DailyRainBand.rainDay,
        DailyRainBand.heavy, DailyRainBand.heavy, DailyRainBand.veryHeavy,
      ]);
    });
    test('missing values stay missing', () {
      final o = ol(row(d1: null, met1: null));
      expect(o.days.first.mm, isNull);
      expect(o.days.first.sourcesAgree, isNull);
    });
  });

  group('Joint rule: river level + 3-day rain forecast', () {
    test('no outlook: measured level only, river reason only', () {
      final j = calc.assess(assess(st('A'), rd('A', river: 12.5)), null);
      expect(j.measured, RiskLevel.alert);
      expect(j.outlook, RiskLevel.alert);
      expect(j.raised, isFalse);
      expect(j.reasons.single.factor, 'river_level');
    });
    test('very heavy rain + MET agrees + river at Alert: outlook raised one level', () {
      final j = calc.assess(assess(st('A'), rd('A', river: 12.5)), ol(row(d1: 45, met1: 2)));
      expect(j.signal, RainSignal.likely);
      expect(j.signalDay, 1);
      expect((j.measured, j.outlook), (RiskLevel.alert, RiskLevel.warning));
      expect(j.reasons.map((r) => r.factor), containsAll(['river_level', 'forecast_day1', 'met_day1', 'outlook']));
      expect(j.reasons.last.text, contains('Outlook raised to Warning'));
    });
    test('the measured level is never lowered or changed by a forecast', () {
      final j = calc.assess(assess(st('A'), rd('A', river: 15)), ol(row(d1: 0, d2: 0, d3: 0, met1: 0, met2: 0, met3: 0)));
      expect(j.measured, RiskLevel.warning);
      expect(j.outlook, RiskLevel.warning);
    });
    test('only one source sees heavy rain: "possible", not raised', () {
      final j = calc.assess(assess(st('A'), rd('A', river: 12.5)), ol(row(d1: 45, met1: 0)));
      expect(j.signal, RainSignal.possible);
      expect(j.raised, isFalse);
      expect(j.reasons.map((r) => r.factor), containsAll(['sources_disagree_day1', 'outlook_possible']));
    });
    test('a low chance of rain does not raise the outlook', () {
      final j = calc.assess(assess(st('A'), rd('A', river: 12.5)), ol(row(d1: 45, prob: 40, met1: 2)));
      expect(j.signal, RainSignal.none);
      expect(j.raised, isFalse);
    });
    test('day 3 rain counts too, and says when', () {
      final j = calc.assess(assess(st('A'), rd('A', river: 12.5)), ol(row(d3: 30, met3: 3)));
      expect(j.signalDay, 3);
      expect(j.raised, isTrue);
      expect(j.reasons.last.text, contains('within 72 hours'));
    });
    test('river near Alert (>= 80%) is raised to Alert; far below is not', () {
      final near = calc.assess(assess(st('A'), rd('A', river: 11.7)), ol(row(d1: 45, met1: 2)));
      expect((near.measured, near.outlook), (RiskLevel.normal, RiskLevel.alert));
      final far = calc.assess(assess(st('A'), rd('A', river: 10.5)), ol(row(d1: 45, met1: 2)));
      expect(far.raised, isFalse);
    });
    test('MET Buruk warning raises the outlook by itself (official)', () {
      final j = calc.assess(assess(st('A'), rd('A', river: 12.5)),
          ol(row(warning: 2, warningTitle: 'Amaran Hujan Berterusan')));
      expect(j.signal, RainSignal.official);
      expect(j.outlook, RiskLevel.warning);
      expect(j.reasons.map((r) => r.factor), contains('met_warning'));
    });
    test('Danger stays Danger', () {
      final j = calc.assess(assess(st('A'), rd('A', river: 16.5)), ol(row(d1: 60, met1: 4)));
      expect(j.outlook, RiskLevel.danger);
    });
    test('stale reading: no measured level, nothing raised', () {
      final j = calc.assess(assess(st('A'), rd('A', minAgo: 300, river: 12.5)), ol(row(d1: 45, met1: 2)));
      expect(j.measured, isNull);
      expect(j.raised, isFalse);
    });
    test('every forecast reason that uses a threshold names its source', () {
      final j = calc.assess(assess(st('A'), rd('A', river: 12.5)),
          ol(row(d1: 45, met1: 2, warning: 1, warningTitle: 'Amaran Ribut Petir', next3h: 6)));
      for (final r in j.reasons.where((r) => r.factor.startsWith('forecast') || r.factor == 'met_warning')) {
        expect(r.source, isNotNull, reason: r.factor);
      }
    });
  });

  group('Joint risk on the Home screen', () {
    test('a station raised by the forecast is listed as forecast-only high risk', () async {
      final stations = [st('A'), st('B')];
      final repo = FakeRepository(stations, [rd('A', river: 11.7), rd('B', river: 10.2)]);
      final monitoring = MonitoringService(repository: repo, clock: fixedClock);
      final home = HomeService(
        monitoring: monitoring,
        followed: FollowedAreasService(store: InMemoryFollowedStore(), repository: repo),
        jointRisk: JointRiskService(FixedRainOutlookSource({'A': ol(row(d1: 45, met1: 2))})),
      );
      final data = await home.load();
      expect(data.highRisk.map((s) => s.station.id), ['A']);
      expect(data.isForecastOnly('A'), isTrue);
      expect(data.joint['B']!.raised, isFalse);
    });
    test('outlook source failing: Home still loads, nothing raised', () async {
      final repo = FakeRepository([st('A')], [rd('A', river: 11.7)]);
      final home = HomeService(
        monitoring: MonitoringService(repository: repo, clock: fixedClock),
        followed: FollowedAreasService(store: InMemoryFollowedStore(), repository: repo),
        jointRisk: JointRiskService(_Failing()),
      );
      final data = await home.load();
      expect(data.highRisk, isEmpty);
      expect(data.joint['A']!.raised, isFalse);
    });
  });

  group('forecast.json schema 2', () {
    String file(Map<String, dynamic>? outlook, {bool used = true}) => jsonEncode({
          'schema': 2, 'generated_at': '2026-11-17T02:55:00Z', 'horizon_hours': 3,
          'model': {'name': 'tree-ensemble'}, 'is_practice_data': false,
          'inputs': {'set': 'observed + 3-day forecast', 'weather_forecast_used': used},
          'stations': [
            {
              'station_id': 'A', 'based_on': '2026-11-17T02:45:00Z', 'current_level_m': 11.5,
              'predicted_level_m': 11.9, 'low_m': 11.7, 'high_m': 12.1, 'base_change_m': 0.0,
              'factors': [
                {'feature': 'fc_rain_day1_mm', 'value': 45.0, 'impact_m': 0.25},
                {'feature': 'met_warning_level', 'value': 2.0, 'impact_m': 0.1},
                {'feature': 'fc_rain_day3_mm', 'value': null, 'impact_m': 0.05},
              ],
              'rain_outlook': outlook,
            }
          ],
        });

    test('rain_outlook and inputs are read', () {
      final f = parseForecast(file({'day1_mm': 45.0, 'day1_prob': 88.0, 'rain_days_3d': 3.0, 'total_3d_mm': 60.0}));
      expect(f.weatherForecastUsed, isTrue);
      final o = f.stations['A']!.rainOutlook!;
      expect(o.days.first.band, DailyRainBand.veryHeavy);
      expect(o.rainDays3d, 3);
      expect(parseForecast(file(null, used: false)).stations['A']!.rainOutlook, isNull);
    });
    test('24-hour chance of reaching Alert is read, with its check day', () async {
      final j = jsonDecode(file(null)) as Map<String, dynamic>;
      (j['stations'] as List).first['flood_chance'] = {
        'horizon_hours': 24, 'already_at_alert': false, 'chance': 0.23, 'base_logodds': -2.0,
        'factors': [
          {'feature': 'rain_sum_24h', 'value': 60.0, 'impact_logodds': 0.9},
          {'feature': 'level_above_normal', 'value': 1.2, 'impact_logodds': -0.1},
        ],
      };
      j['chance_model'] = {
        'calibration': {'day': '2026-11-24', 'events': 90, 'reliable': true, 'brier': 0.08, 'brier_climatology': 0.1}
      };
      final f = parseForecast(jsonEncode(j));
      final c = f.stations['A']!.floodChance!;
      expect((c.chance, c.alreadyAtAlert, c.factors.first.feature), (0.23, false, 'rain_sum_24h'));
      expect(f.chanceCheck!.reliable, isTrue);
      final r = await ForecastService(source: _Body(jsonEncode(j)), clock: fixedClock)
          .load([assess(st('A'), rd('A', river: 11.5))]);
      expect(r.forecasts['A']!.floodChance!.chance, 0.23);
      expect(r.forecasts['A']!.chanceCheck!.events, 90);
      (j['stations'] as List).first['flood_chance']['chance'] = 1.5;
      expect(() => parseForecast(jsonEncode(j)), throwsA(isA<ForecastFormatException>()));
    });
    test('flood chance at three JPS levels is read, with Warning as the headline', () {
      final j = jsonDecode(file(null)) as Map<String, dynamic>;
      (j['stations'] as List).first['flood_chance'] = {
        'horizon_hours': 24, 'headline_level': 'warning', 'already': false, 'chance': 0.35, 'capped': false,
        'levels': {
          'alert': {'already': true, 'chance': null},
          'warning': {'already': false, 'chance': 0.35},
          'danger': {'already': false, 'chance': 0.08},
        },
        'base_logodds': -2.5,
        'factors': [
          {'feature': 'consecutive_wet_hours', 'value': 7.0, 'impact_logodds': 0.8},
          {'feature': 'fill_to_target', 'value': 0.85, 'impact_logodds': 0.6},
        ],
        'inputs_now': {'consecutive_wet_hours': 7.0, 'rain_sum_24h': 48.0, 'fc_rain_day1_mm': null},
      };
      final c = parseForecast(jsonEncode(j)).stations['A']!.floodChance!;
      expect((c.headlineLevel, c.chance, c.already, c.alreadyAtAlert), (RiskLevel.warning, 0.35, false, true));
      expect(c.levels[RiskLevel.danger]!.chance, 0.08);
      expect(c.inputsNow, {'consecutive_wet_hours': 7.0, 'rain_sum_24h': 48.0});
      (j['stations'] as List).first['flood_chance']['levels']['danger']['chance'] = -0.1;
      expect(() => parseForecast(jsonEncode(j)), throwsA(isA<ForecastFormatException>()));
    });
    test('forecast inputs are explained in plain words; empty ones are hidden', () async {
      final service = ForecastService(source: _Body(file(null)), clock: fixedClock);
      final r = await service.load([assess(st('A'), rd('A', river: 11.5))]);
      final reasons = r.forecasts['A']!.reasons;
      expect(reasons.first, 'Forecast: 45 mm of rain in the next 24 hours (raises the forecast)');
      expect(reasons[1], 'MET Malaysia warning in force: Warning (Buruk) (raises the forecast)');
      expect(reasons.length, 2); // fc_rain_day3_mm has no value: not shown
    });
    test('every forecast input has its own wording', () {
      const inputs = {
        'fc_rain_next_3h': 3.0, 'fc_rain_prob_next_3h': 75.0, 'fc_rain_day2_mm': 12.0,
        'fc_rain_prob_day3': 60.0, 'fc_rain_days_3d': 3.0, 'fc_rain_total_3d': 37.0,
        'met_rain_class_day1': 3.0, 'met_thunder_days_3d': 2.0, 'met_warning_level': 0.0,
        'sources_agree_days_3d': 2.0, 'rain_sum_72h': 80.0, 'wet_hours_24h': 9.0,
        'consecutive_wet_hours': 4.0, 'wet_days_3d': 3.0, 'api_7d': 55.0, 'fc_rain_day1_x_fill': 20.0,
      };
      for (final e in inputs.entries) {
        final text = ForecastService.describeFactor(ForecastFactor(feature: e.key, value: e.value, impactM: 0.1));
        expect(text, isNot(startsWith('Other readings')), reason: e.key);
      }
      expect(ForecastService.describeFactor(ForecastFactor(feature: 'met_rain_class_day1', value: 3, impactM: 0.1)),
          'MET Malaysia forecast: rain in most places in the next 24 hours (raises the forecast)');
    });
  });
}

class _Failing implements RainOutlookSource {
  @override
  Future<Map<String, RainOutlook>> load() async => throw StateError('offline');
}

class _Body implements ForecastSource {
  _Body(this.body);
  final String body;
  @override
  Future<String> fetch() async => body;
}
