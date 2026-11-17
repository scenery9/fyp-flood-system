import 'dart:convert';
import 'dart:io';

import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';
import 'helpers.dart';

class FakeSource implements ForecastSource {
  FakeSource(this.body);
  String body;
  bool fail = false;
  @override
  Future<String> fetch() async => fail ? throw StateError('no internet') : body;
}

String iso(DateTime t) => t.toUtc().toIso8601String();

Map<String, dynamic> entry(String id, double current, double predicted,
        {double band = 0.2, int minAgo = 10, List<Map<String, dynamic>>? factors}) =>
    {
      'station_id': id, 'based_on': iso(kNow.subtract(Duration(minutes: minAgo))),
      'current_level_m': current, 'predicted_level_m': predicted,
      'low_m': predicted - band, 'high_m': predicted + band,
      'factors': factors ?? [{'feature': 'rain_sum_3h', 'value': 42.0, 'impact_m': 0.3}],
    };

String file(List<Map<String, dynamic>> stations, {int minAgo = 5, Map<String, dynamic> extra = const {}}) =>
    jsonEncode({
      'schema': 1, 'generated_at': iso(kNow.subtract(Duration(minutes: minAgo))),
      'horizon_hours': 3, 'model': {'name': 'xgboost'}, 'is_practice_data': false,
      'stations': stations, ...extra,
    });

void main() {
  // thresholds: normal 10, alert 12, warning 14, danger 16
  final statusA = assess(st('A'), rd('A', river: 11.5));
  Future<ForecastResult> load(String body, {List<StationStatus>? statuses}) =>
      ForecastService(source: FakeSource(body), clock: fixedClock).load(statuses ?? [statusA]);
  Future<StationForecast> one(double current, double predicted, {double band = 0.2}) async =>
      (await load(file([entry('A', current, predicted, band: band)]))).forecasts['A']!;

  group('TP35 Reading forecast.json', () {
    test('a valid file is read', () {
      final f = parseForecast(file([entry('A', 11.5, 12.3)]));
      expect(f.horizonHours, 3);
      expect(f.modelName, 'xgboost');
      expect(f.isPracticeData, isFalse);
      expect(f.stations['A']!.predictedLevelM, 12.3);
      expect(f.stations['A']!.factors.single.impactM, 0.3);
    });
    test('practice flag: only an explicit false counts as real data', () {
      expect(parseForecast(file([], extra: {'is_practice_data': true})).isPracticeData, isTrue);
      expect(parseForecast(file([], extra: {'is_practice_data': null})).isPracticeData, isTrue);
      expect(parseForecast(file([], extra: {'is_practice_data': 'false'})).isPracticeData, isTrue);
    });
    test('wrong or damaged files are refused', () {
      final bad = <String>[
        'not json', '[]', '{}',
        file([], extra: {'schema': 2}),
        file([], extra: {'horizon_hours': 0}),
        file([], extra: {'horizon_hours': 99}),
        file([], extra: {'generated_at': 'yesterday'}),
        file([{'station_id': 'A'}]),
        file([entry('A', 11.5, 12.3)..['predicted_level_m'] = 'high']),
        file([entry('A', 11.5, 12.3)..['low_m'] = 13.0]), // range does not contain prediction
        file([entry('A', 11.5, 12.3, factors: [{'feature': 'x', 'impact_m': null}])]),
      ];
      for (final b in bad) {
        expect(() => parseForecast(b), throwsA(isA<ForecastFormatException>()));
      }
    });
  });

  group('TP36 Forecast line', () {
    test('rise to a higher level', () async {
      final f = await one(11.5, 12.3);
      expect(f.predictedRisk, RiskLevel.alert);
      expect(f.trend, Trend.rising);
      expect(f.summary, 'Expected to rise to Alert level in about 3 hours');
      expect(f.changeM, closeTo(0.8, 1e-9));
      expect(f.validAt, kNow.subtract(const Duration(minutes: 10)).add(const Duration(hours: 3)));
    });
    test('stay at the same level, and fall to a lower one', () async {
      expect((await one(12.5, 13.0)).summary, 'Expected to stay at Alert level for the next 3 hours');
      expect((await one(14.2, 13.0)).summary, 'Expected to fall to Alert level in about 3 hours');
    });
    test('exactly on a threshold counts as that level', () async {
      expect((await one(15.5, 16.0)).predictedRisk, RiskLevel.danger);
      expect((await one(15.5, 15.99)).predictedRisk, RiskLevel.warning);
    });
    test('worst case uses the top of the likely range', () async {
      final f = await one(13.0, 13.9, band: 0.2);
      expect(f.predictedRisk, RiskLevel.alert);
      expect(f.worstCaseRisk, RiskLevel.warning);
    });
    test('small changes are called steady', () async {
      expect((await one(11.5, 11.54)).trend, Trend.steady);
      expect((await one(11.5, 11.55)).trend, Trend.rising);
      expect((await one(11.5, 11.45)).trend, Trend.falling);
    });
    test('station without thresholds gets metres instead of a level', () async {
      final s = assess(st('A', thresholds: false), rd('A', river: 3));
      final r = await load(file([entry('A', 3.0, 3.4)]), statuses: [s]);
      expect(r.forecasts['A']!.predictedRisk, isNull);
      expect(r.forecasts['A']!.summary, 'River expected to rise by 0.40 m in about 3 hours');
    });
  });

  group('TP37 When a forecast must not be shown', () {
    test('file older than 2 hours is refused; exactly 2 hours is accepted', () async {
      final old = await load(file([entry('A', 11.5, 12.3)], minAgo: 121));
      expect(old.forecasts, isEmpty);
      expect(old.unavailableReason, 'Forecast is out of date');
      expect((await load(file([entry('A', 11.5, 12.3)], minAgo: 120))).forecasts, hasLength(1));
    });
    test('file dated in the future is refused', () async {
      expect((await load(file([entry('A', 11.5, 12.3)], minAgo: -11))).unavailableReason, 'Forecast has a wrong time');
      expect((await load(file([entry('A', 11.5, 12.3)], minAgo: -5))).forecasts, hasLength(1));
    });
    test('download failure and damaged file give a reason, never a crash', () async {
      final src = FakeSource('')..fail = true;
      final svc = ForecastService(source: src, clock: fixedClock);
      expect((await svc.load([statusA])).unavailableReason, 'Forecast could not be downloaded');
      expect((await load('garbage')).unavailableReason, 'Forecast file could not be read');
    });
    test('a station whose forecast is based on old readings is skipped', () async {
      final r = await load(file([entry('A', 11.5, 12.3, minAgo: 130)]));
      expect(r.forecasts, isEmpty);
      expect(r.unavailableReason, 'No forecast for these stations');
    });
    test('absurd predictions are dropped', () async {
      expect((await load(file([entry('A', 11.5, 17.0)]))).forecasts, isEmpty); // +5.5 m in 3 h
      expect((await load(file([entry('A', 40.0, 41.0)]))).forecasts, isEmpty); // far outside thresholds
    });
    test('stations not in the app, or not in the file, are ignored', () async {
      final b = assess(st('B'), rd('B', river: 11));
      final r = await load(file([entry('A', 11.5, 12.3), entry('ZZZ', 1, 1.1)]), statuses: [statusA, b]);
      expect(r.forecasts.keys.toList(), ['A']);
      expect(r.unavailableReason, isNull);
    });
  });

  group('TP38 "Kenapa?" reasons', () {
    ForecastFactor f(String feature, double? value, double impact) =>
        ForecastFactor(feature: feature, value: value, impactM: impact);
    test('rain wording', () {
      expect(ForecastService.describeFactor(f('rain_sum_3h', 42.4, 0.3)),
          '42 mm of rain in the last 3 hours (raises the forecast)');
      expect(ForecastService.describeFactor(f('rain_sum_24h', 0.0, -0.1)),
          'Almost no rain in the last 24 hours (lowers the forecast)');
    });
    test('river change wording', () {
      expect(ForecastService.describeFactor(f('level_change_1h', 0.2, 0.15)),
          'River rose 0.20 m in the last hour (raises the forecast)');
      expect(ForecastService.describeFactor(f('level_change_3h', -0.35, -0.1)),
          'River fell 0.35 m in the last 3 hours (lowers the forecast)');
      expect(ForecastService.describeFactor(f('level_change_1h', 0.0, -0.02)),
          'River level unchanged in the last hour (lowers the forecast)');
    });
    test('level wording, and unknown or missing inputs', () {
      expect(ForecastService.describeFactor(f('level_above_normal', 1.87, -0.26)),
          'River is 1.87 m above its normal level (lowers the forecast)');
      expect(ForecastService.describeFactor(f('level_above_normal', -0.2, 0.05)),
          'River is 0.20 m below its normal level (raises the forecast)');
      expect(ForecastService.describeFactor(f('new_feature', 1, 0.2)), 'Other readings (raises the forecast)');
      expect(ForecastService.describeFactor(f('rain_sum_3h', null, 0.2)), 'Other readings (raises the forecast)');
    });
    test('upstream wording', () {
      expect(ForecastService.describeFactor(f('up_rain_sum_3h', 35.4, 0.25)),
          '35 mm of rain upstream in the last 3 hours (raises the forecast)');
      expect(ForecastService.describeFactor(f('up_rain_sum_6h', 0.2, -0.05)),
          'Almost no rain upstream in the last 6 hours (lowers the forecast)');
      expect(ForecastService.describeFactor(f('up_level_change_1h', 0.32, 0.2)),
          'Upstream river rose 0.32 m in the last hour (raises the forecast)');
      expect(ForecastService.describeFactor(f('up_level_change_3h', -0.1, -0.03)),
          'Upstream river fell 0.10 m in the last 3 hours (lowers the forecast)');
      expect(ForecastService.describeFactor(f('up_level_change_1h', 0.001, 0.02)),
          'Upstream river unchanged in the last hour (raises the forecast)');
      expect(ForecastService.describeFactor(f('up_rain_sum_3h', null, -0.02)),
          'No upstream river readings (lowers the forecast)');
    });
    test('missing upstream readings are never given as a reason', () async {
      final r = await load(file([
        entry('A', 11.5, 11.2, factors: [
          {'feature': 'up_rain_sum_3h', 'value': null, 'impact_m': -0.2},
          {'feature': 'level_change_1h', 'value': -0.1, 'impact_m': -0.1},
        ]),
      ]));
      expect(r.forecasts['A']!.reasons, ['River fell 0.10 m in the last hour (lowers the forecast)']);
    });
    test('top three by size of impact; tiny impacts are left out', () async {
      final r = await load(file([
        entry('A', 11.5, 12.3, factors: [
          {'feature': 'rain_sum_1h', 'value': 5.0, 'impact_m': 0.05},
          {'feature': 'level_change_1h', 'value': 0.3, 'impact_m': 0.4},
          {'feature': 'rain_sum_3h', 'value': 40.0, 'impact_m': -0.2},
          {'feature': 'rain_sum_6h', 'value': 60.0, 'impact_m': 0.1},
          {'feature': 'rain_sum_24h', 'value': 80.0, 'impact_m': 0.004},
        ]),
      ]));
      final reasons = r.forecasts['A']!.reasons;
      expect(reasons, hasLength(3));
      expect(reasons[0], contains('River rose 0.30 m'));
      expect(reasons[1], contains('40 mm of rain in the last 3 hours (lowers'));
      expect(reasons[2], contains('60 mm'));
    });
    test('no meaningful factor gives no reasons rather than noise', () async {
      final r = await load(file([entry('A', 11.5, 11.5, factors: [{'feature': 'rain_sum_1h', 'value': 0.0, 'impact_m': 0.001}])]));
      expect(r.forecasts['A']!.reasons, isEmpty);
    });
  });

  group('TP39 Contract with the Python pipeline', () {
    // This file was written by ml/flood_ml (practice data) for 2026-11-17 03:00 UTC.
    final body = File('test/fixtures/forecast_practice.json').readAsStringSync();
    test('the app can read the file the model writes', () {
      final f = parseForecast(body);
      expect(f.generatedAt, kNow);
      expect(f.horizonHours, 3);
      expect(f.isPracticeData, isTrue);
      expect(f.stations, hasLength(7));
    });
    test('the file includes upstream inputs, with values where a station has upstream stations', () {
      final awat = parseForecast(body).stations['JHR-AWAT']!;
      final up = awat.factors.where((x) => x.feature.startsWith('up_')).toList();
      expect(up, hasLength(4));
      expect(up.every((x) => x.value != null), isTrue);
    });
    test('every station and feature the model uses is known to the app', () async {
      final ids = {for (final s in await SampleStationRepository(clock: fixedClock).getStations()) s.id};
      for (final s in parseForecast(body).stations.values) {
        expect(ids.contains(s.stationId), isTrue);
        for (final factor in s.factors) {
          expect(ForecastService.describeFactor(factor).startsWith('Other readings'), isFalse);
        }
      }
    });
    test('forecasts, levels and reasons come out for every station', () async {
      final statuses = await World().monitoring.loadStatuses();
      final r = await ForecastService(source: FakeSource(body), clock: fixedClock).load(statuses);
      expect(r.forecasts, hasLength(7));
      for (final f in r.forecasts.values) {
        expect(f.predictedRisk, isNotNull);
        expect(f.summary, isNotEmpty);
        expect(f.reasons.length <= 3, isTrue);
        expect(f.isPracticeData, isTrue);
        expect(f.lowM <= f.predictedLevelM && f.predictedLevelM <= f.highM, isTrue);
      }
    });
  });
}
