import 'dart:convert';

import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';
import 'helpers.dart';

/// Round 6: the phone's connection to Supabase (anonymous sign-in, live
/// stations) and push alert registration. Uses a fake server (FakeHttp).
void main() {
  group('TP68 Anonymous sign-in', () {
    test('first use signs in once and keeps the session on the phone', () async {
      final http = FakeHttp();
      final api = http.api();
      final results = await Future.wait([api.auth!.accessToken(), api.auth!.accessToken()]);
      expect(results, ['access-1', 'access-1']); // two calls at once share one sign-in
      expect(http.signIns, 1);
      expect(api.auth!.userId, 'user-1');
      final saved = await http.authStore.load();
      expect(saved['refresh'], 'refresh-1');
      final signup = http.calls.single;
      expect(signup.uri.path, '/auth/v1/signup');
      expect(signup.headers['apikey'], 'sb_publishable_test');
    });
    test('after a restart the saved session is used, then refreshed near expiry', () async {
      final http = FakeHttp();
      await http.api().auth!.accessToken();
      final again = http.api(); // new app start, same phone storage
      expect(await again.auth!.accessToken(), 'access-1');
      expect(http.calls, hasLength(1));
      http.now = kNow.add(const Duration(minutes: 59, seconds: 30)); // within a minute of expiry
      expect(await again.auth!.accessToken(), 'access-2');
      expect(http.refreshes, 1);
      expect(http.calls.last.uri.queryParameters['grant_type'], 'refresh_token');
      expect(http.calls.last.json, {'refresh_token': 'refresh-1'});
    });
    test('a refresh token the server no longer accepts leads to a new sign-in', () async {
      final http = FakeHttp();
      await http.api().auth!.accessToken();
      http.reply('/auth/v1/token', 400, '{"error_description": "Invalid Refresh Token"}');
      http.now = kNow.add(const Duration(hours: 2));
      final api = http.api();
      expect(await api.auth!.accessToken(), 'access-2');
      expect(http.signIns, 2);
      expect(api.auth!.userId, 'user-2');
    });
    test('no internet or a refused sign-in is reported, not hidden', () async {
      final down = FakeHttp()..offline = true;
      await expectLater(down.api().auth!.accessToken(), throwsA(isA<SupabaseException>()));
      final off = FakeHttp()..reply('/auth/v1/signup', 422, '{"msg": "Anonymous sign-ins are disabled"}');
      await expectLater(
          off.api().auth!.accessToken(),
          throwsA(isA<SupabaseException>()
              .having((e) => e.message, 'message', 'Anonymous sign-ins are disabled')));
    });
    test('damaged saved session is ignored', () async {
      final http = FakeHttp();
      await http.authStore.save({'user': 'x', 'access': 'y'}); // refresh and expiry missing
      expect(await http.api().auth!.accessToken(), 'access-1');
    });
  });

  group('TP69 Live stations from Supabase', () {
    Map<String, Object?> row(String code,
            {Object? level = 2.5, Object? levelAt = '2026-11-17T02:45:00+00:00', Object? rain = 4.0,
            Object? rainAt = '2026-11-17T02:50:00+00:00', List<Object?> th = const [1, 2, 3, 4],
            Object? lat = 3.03, Object? lon = 101.45}) =>
        {
          'station_code': code, 'name': 'Sg. $code', 'district': 'KLANG', 'lat': lat, 'lon': lon,
          'wl_normal': th[0], 'wl_alert': th[1], 'wl_warning': th[2], 'wl_danger': th[3],
          'level_m': level, 'level_at': levelAt, 'hourly_mm': rain, 'rain_at': rainAt,
        };

    test('stations and readings come from one download of jps_latest', () async {
      final http = FakeHttp()..reply('/rest/v1/jps_latest', 200, jsonEncode([row('BKLG0002L')]));
      final repo = LiveStationRepository(http.api(signedIn: false), clock: fixedClock);
      final m = MonitoringService(repository: repo, clock: fixedClock);
      final s = (await m.loadStatuses()).single;
      expect(s.station.id, 'BKLG0002L');
      expect(s.station.state, 'Selangor');
      expect(s.level, RiskLevel.alert);
      expect(s.reading!.rainfallMmPerHr, 4.0);
      expect(s.reading!.time, DateTime.utc(2026, 11, 17, 2, 45)); // the river reading's time
      expect(http.calls, hasLength(1)); // getStations + getLatestReadings: one download
      expect(http.calls.single.headers.containsKey('Authorization'), isFalse); // public data, no sign-in
      expect(http.calls.single.uri.queryParameters['select'], contains('level_m'));
    });
    test('the download is reused for a minute, then refreshed', () async {
      final http = FakeHttp()..reply('/rest/v1/jps_latest', 200, jsonEncode([row('A')]));
      var now = kNow;
      final repo = LiveStationRepository(http.api(signedIn: false), clock: () => now);
      await repo.getStations();
      now = now.add(const Duration(seconds: 59));
      await repo.getLatestReadings();
      expect(http.calls, hasLength(1));
      now = now.add(const Duration(seconds: 2));
      await repo.getStations();
      expect(http.calls, hasLength(2));
    });
    test('odd JPS data is handled without guessing', () async {
      final http = FakeHttp()
        ..reply('/rest/v1/jps_latest', 200, jsonEncode([
          row('RAINONLY', level: null, levelAt: null, th: [null, null, null, null]),
          row('BADTH', th: [5, 4, 3, 2]), // warning levels that do not rise
          row('NOPOS', lat: null),
          row('ZERO', lat: 0, lon: 0),
          row('SILENT', level: null, levelAt: null, rain: null, rainAt: null),
          {'station_code': '', 'name': 'no code'},
        ]));
      final repo = LiveStationRepository(http.api(signedIn: false), clock: fixedClock);
      final ids = [for (final s in await repo.getStations()) s.id];
      expect(ids, ['RAINONLY', 'BADTH', 'NOPOS', 'ZERO', 'SILENT']);
      final byId = {for (final s in await repo.getStations()) s.id: s};
      expect(byId['BADTH']!.thresholds, isNull);
      expect(byId['NOPOS']!.location, isNull);
      expect(byId['ZERO']!.location, isNull);
      final r = await repo.getLatestReadings();
      expect(r['RAINONLY']!.riverLevelM, isNull);
      expect(r['RAINONLY']!.time, DateTime.utc(2026, 11, 17, 2, 50)); // rain time when no river reading
      expect(r.containsKey('SILENT'), isFalse);
    });
    test('a server error is passed on', () async {
      final http = FakeHttp()..reply('/rest/v1/jps_latest', 503, '{"message": "paused"}');
      final repo = LiveStationRepository(http.api(signedIn: false), clock: fixedClock);
      await expectLater(repo.getStations(), throwsA(isA<SupabaseException>()));
    });
  });

  group('TP70 Push alert registration', () {
    test('rules: saved areas at the chosen level plus river heights, at most 20', () {
      final rules = pushRulesFor(
          followedStationIds: ['A', 'B'], threshold: RiskLevel.warning, heights: {'C': 4.2});
      expect([for (final r in rules) r.toJson()], [
        {'station_code': 'A', 'kind': 'risk', 'min_level': 'warning'},
        {'station_code': 'B', 'kind': 'risk', 'min_level': 'warning'},
        {'station_code': 'C', 'kind': 'level', 'level_m': 4.2},
      ]);
      final many = pushRulesFor(
          followedStationIds: [for (var i = 0; i < 5; i++) 'F$i'], threshold: RiskLevel.normal,
          heights: {for (var i = 0; i < 18; i++) 'H$i': 1.0});
      expect(many, hasLength(20));
      expect(many.first.minLevel, RiskLevel.alert); // Normal is never a notification level
    });
    test('register and sync call the database functions as the signed-in phone', () async {
      final http = FakeHttp()
        ..reply('/rest/v1/rpc/register_device', 204, '')
        ..reply('/rest/v1/rpc/sync_alert_rules', 200, '2');
      final push = PushAlertService(http.api());
      await push.register(token: 'fcm-token-1234567890', platform: 'android', language: AppLanguage.ms);
      final reg = http.calls.last;
      expect(reg.headers['Authorization'], 'Bearer access-1');
      expect(reg.json, {'p_token': 'fcm-token-1234567890', 'p_platform': 'android', 'p_language': 'ms'});
      final n = await push.syncRules([const ServerAlertRule.risk('A', RiskLevel.alert)]);
      expect(n, 2);
      expect(http.calls.last.json, {
        'p_rules': [
          {'station_code': 'A', 'kind': 'risk', 'min_level': 'alert'},
        ],
      });
      expect(http.signIns, 1);
    });
    test('an expired session is replaced once and the call retried', () async {
      final http = FakeHttp()
        ..reply('/rest/v1/rpc/unregister_device', 401, '{"message": "JWT expired"}')
        ..reply('/rest/v1/rpc/unregister_device', 204, '');
      await PushAlertService(http.api()).unregister();
      expect(http.signIns, 2);
      expect(http.calls.last.headers['Authorization'], 'Bearer access-2');
    });
    test('a server refusal is reported', () async {
      final http = FakeHttp()..reply('/rest/v1/rpc/sync_alert_rules', 400, '{"message": "Maximum 20 alerts"}');
      await expectLater(PushAlertService(http.api()).syncRules([]),
          throwsA(isA<SupabaseException>().having((e) => e.message, 'message', 'Maximum 20 alerts')));
    });
  });

  group('TP71 River-height alerts on the phone', () {
    test('set, replace, remove and keep two decimals', () async {
      final store = HeightAlertStore(InMemorySettingsStore());
      await store.set('A', 4.256);
      await store.set('A', 4.3);
      await store.set('B', 2);
      expect(await store.load(), {'A': 4.3, 'B': 2.0});
      expect(await store.remove('A'), {'B': 2.0});
      expect((await store.set('C', 1.234))['C'], 1.23);
    });
    test('bad numbers and too many heights are refused; damaged saves are skipped', () async {
      final mem = InMemorySettingsStore({'X': 'abc', 'Y': '2000', 'Z': '1.5'});
      final store = HeightAlertStore(mem);
      expect(await store.load(), {'Z': 1.5});
      await expectLater(store.set('A', double.nan), throwsA(isA<ValidationException>()));
      await expectLater(store.set('A', 1000), throwsA(isA<ValidationException>()));
      for (var i = 0; i < HeightAlertStore.maxHeights - 1; i++) {
        await store.set('S$i', 1);
      }
      await expectLater(store.set('ONE-TOO-MANY', 1), throwsA(isA<ConflictException>()));
      await store.set('Z', 2); // replacing is still fine
    });
    test('alert rules can be saved and read back; damaged ones are skipped', () {
      final r = AlertRule(id: 'r1', stationId: 'A', type: AlertType.waterLevel, waterLevelM: 4.2, enabled: false);
      final back = AlertRule.fromMap(r.toMap())!;
      expect([back.id, back.stationId, back.type, back.waterLevelM, back.enabled],
          ['r1', 'A', AlertType.waterLevel, 4.2, false]);
      expect(AlertRule.fromMap({'id': 'x', 'station': 'A', 'type': 'riskLevel', 'min': 'normal'}), isNull);
      expect(AlertRule.fromMap({'id': 'x', 'station': 'A', 'type': 'nope'}), isNull);
      expect(AlertRule.fromMap({'id': 'x', 'station': 'A', 'type': 'waterLevel', 'level': 'abc'}), isNull);
    });
  });
}
