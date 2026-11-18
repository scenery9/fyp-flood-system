// TP80-TP86: easier alerts, offline route guide, station lists by distance,
// household counts, public flood reports and the relief-centre headcount.
import 'dart:convert';

import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';

import 'helpers.dart';

StationForecast fc(String id, RiskLevel? predicted, {Trend trend = Trend.rising}) => StationForecast(
    stationId: id, horizonHours: 3, validAt: kNow.add(const Duration(hours: 3)), predictedLevelM: 14.5,
    lowM: 14, highM: 15, changeM: 0.5, trend: trend, predictedRisk: predicted, worstCaseRisk: predicted,
    summary: '', reasons: const [], isPracticeData: true);

RoutePlan plan(List<GeoPoint> path, {List<RouteStep>? steps}) => RoutePlan(
    from: path.first, to: path.last, distanceM: 3000, durationS: 400, path: path,
    steps: steps ??
        [
          RouteStep(instruction: 'Head east', distanceM: 1000, durationS: 100, type: 11, name: 'Jalan A', wayPoint: 0),
          RouteStep(instruction: 'Turn left', distanceM: 2000, durationS: 300, type: 0, name: 'Jalan B', wayPoint: 1),
          RouteStep(instruction: 'Arrive', distanceM: 0, durationS: 0, type: 10, wayPoint: 2),
        ]);

void main() {
  final a = GeoPoint(2.500, 102.800), b = GeoPoint(2.500, 102.810), c = GeoPoint(2.510, 102.810);

  group('TP80 Route steps in any language', () {
    test('step type, street name, exit and position are read from openrouteservice', () {
      final body = jsonEncode({
        'features': [
          {
            'properties': {
              'summary': {'distance': 1200, 'duration': 120},
              'segments': [
                {
                  'steps': [
                    {'distance': 100, 'duration': 10, 'type': 11, 'instruction': 'Head east on Jalan A', 'name': 'Jalan A', 'way_points': [0, 1]},
                    {'distance': 1100, 'duration': 110, 'type': 7, 'exit_number': 2, 'instruction': 'Enter the roundabout', 'name': '-', 'way_points': [1, 2]},
                    {'distance': 0, 'duration': 0, 'type': 10, 'instruction': '', 'way_points': [2, 2]},
                  ],
                },
              ],
            },
            'geometry': {'coordinates': [[102.8, 2.5], [102.81, 2.5], [102.81, 2.51]]},
          },
        ],
      });
      final p = parseOrsDirections(body, from: a, to: c);
      expect(p.steps, hasLength(3), reason: 'a step with a type is kept even without English text');
      expect([for (final s in p.steps) StepKind.fromOrs(s.type)], [StepKind.depart, StepKind.enterRoundabout, StepKind.arrive]);
      expect(p.steps[0].name, 'Jalan A');
      expect(p.steps[1].name, isNull, reason: '"-" means the road has no name');
      expect(p.steps[1].exitNumber, 2);
      expect([for (final s in p.steps) s.wayPoint], [0, 1, 2]);
    });

    test('saved routes keep the new fields; routes saved by the old version still load', () {
      final p = plan([a, b, c]);
      final back = RoutePlan.fromJson(jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(back.steps[1].type, 0);
      expect(back.steps[1].name, 'Jalan B');
      expect(back.steps[2].wayPoint, 2);
      final old = RoutePlan.fromJson({
        'from': [2.5, 102.8], 'to': [2.51, 102.81], 'distanceM': 10, 'durationS': 5,
        'steps': [{'i': 'Head east', 'd': 10, 't': 5}], 'path': [[2.5, 102.8]],
      });
      expect(old.steps.single.type, isNull);
      expect(SavedRoute(centreId: 'x', savedAt: kNow, plan: old).canTranslate, isFalse);
      expect(SavedRoute(centreId: 'x', savedAt: kNow, plan: p).canTranslate, isTrue);
    });

    test('unknown step types are null, not a crash', () {
      expect(StepKind.fromOrs(-1), isNull);
      expect(StepKind.fromOrs(14), isNull);
      expect(StepKind.fromOrs(null), isNull);
      expect(StepKind.fromOrs(13), StepKind.keepRight);
    });
  });

  group('TP81 Route kept on the phone', () {
    test('saved per centre, loaded back, only the newest 3 kept', () async {
      final cache = RouteCache(InMemorySettingsStore());
      for (var i = 0; i < 4; i++) {
        await cache.save('C$i', plan([a, b, c]), kNow.add(Duration(minutes: i)));
      }
      expect(await cache.load('C0'), isNull, reason: 'oldest dropped');
      final r = await cache.load('C3');
      expect(r!.savedAt, kNow.add(const Duration(minutes: 3)));
      expect(r.plan.steps, hasLength(3));
    });

    test('old after 1 hour; only used near where it started; damaged data ignored', () async {
      final r = SavedRoute(centreId: 'C', savedAt: kNow, plan: plan([a, b, c]));
      expect(r.isOld(kNow.add(const Duration(minutes: 59))), isFalse);
      expect(r.isOld(kNow.add(const Duration(minutes: 61))), isTrue);
      expect(r.startsNear(GeoPoint(2.505, 102.800)), isTrue); // about 0.6 km
      expect(r.startsNear(GeoPoint(2.520, 102.800)), isFalse); // about 2.2 km
      final cache = RouteCache(InMemorySettingsStore({'C': 'not json'}));
      expect(await cache.load('C'), isNull);
    });
  });

  group('TP82 River stations near the route', () {
    test('distance to the route line, not just its corners', () {
      // Halfway along a 1.1 km east-west segment, 0.5 km north of it.
      final mid = GeoPoint(2.5045, 102.805);
      expect(distanceToLineKm(mid, [a, b]), closeTo(0.5, 0.02));
      expect(distanceToLineKm(mid, [a]), greaterThan(0.6));
    });

    test('Warning and Danger stations within 1 km, worst first; old or far ones left out', () {
      final p = plan([a, b, c]);
      final near = GeoPoint(2.502, 102.805); // 0.2 km from the line
      final statuses = [
        assess(st('W', loc: near), rd('W', river: 14.5)), // Warning
        assess(st('D', loc: GeoPoint(2.505, 102.812)), rd('D', river: 16.5)), // Danger, 0.2 km
        assess(st('A', loc: near), rd('A', river: 12.5)), // Alert: below the bar
        assess(st('OLD', loc: near), rd('OLD', river: 16.5, minAgo: 600)), // stale
        assess(st('FAR', loc: GeoPoint(2.60, 102.80)), rd('FAR', river: 16.5)), // 11 km away
      ];
      final h = routeHazards(p, statuses);
      expect([for (final x in h) x.status.station.id], ['D', 'W']);
    });
  });

  group('TP83 Which step the user is on', () {
    test('nearest point on the route decides the step; off the route = first step', () {
      final p = plan([a, b, c]);
      expect(currentStepIndex(p, a), 0);
      expect(currentStepIndex(p, GeoPoint(2.5001, 102.8099)), 1);
      expect(currentStepIndex(p, c), 2);
      expect(currentStepIndex(p, GeoPoint(2.6, 102.9)), 0);
    });
  });

  group('TP84 Alerts without typing a height', () {
    test('choices are the station\'s own Alert, Warning and Danger heights; Warning recommended', () {
      final ch = levelChoicesFor(th());
      expect([for (final x in ch) x.level], [RiskLevel.alert, RiskLevel.warning, RiskLevel.danger]);
      expect([for (final x in ch) x.metres], [12, 14, 16]);
      expect([for (final x in ch) if (x.recommended) x.level], [RiskLevel.warning]);
      expect(levelChoicesFor(null), isEmpty, reason: 'rain gauges have no river heights');
      expect(levelAtHeight(th(), 14.0), RiskLevel.warning);
      expect(levelAtHeight(th(), 13.3), isNull, reason: 'a height typed in the old version');
    });

    test('active alerts: saved, nearest and nearby stations; worst first; one row each', () {
      final user = GeoPoint(2.5, 102.8);
      final statuses = [
        assess(st('SAVED', loc: GeoPoint(3.5, 101.5)), rd('SAVED', river: 14.5), user: user), // Warning, far
        assess(st('NEAR', loc: GeoPoint(2.52, 102.8)), rd('NEAR', river: 16.2), user: user), // Danger, 2 km
        assess(st('ALERT', loc: GeoPoint(2.51, 102.8)), rd('ALERT', river: 12.5), user: user), // Alert, 1 km
        assess(st('FARD', loc: GeoPoint(4.0, 101.0)), rd('FARD', river: 17), user: user), // Danger, far, not saved
        assess(st('RISE', loc: GeoPoint(2.53, 102.8)), rd('RISE', river: 11), user: user), // Normal, forecast Warning
        assess(st('OLD', loc: GeoPoint(2.50, 102.81)), rd('OLD', river: 17, minAgo: 600), user: user), // stale
      ];
      final r = activeAlerts(
          statuses: statuses, savedIds: {'SAVED'}, nearestId: 'ALERT',
          forecasts: {'RISE': fc('RISE', RiskLevel.warning), 'NEAR': fc('NEAR', RiskLevel.danger)});
      expect([for (final x in r.now) x.status.station.id], ['NEAR', 'SAVED', 'ALERT']);
      expect(r.now.last.why, AlertWhy.nearest);
      expect([for (final x in r.expected) x.status.station.id], ['RISE']);
      expect(r.expected.single.level, RiskLevel.warning);
      expect(r.banner!.status.station.id, 'NEAR');
    });

    test('"Notify me from Danger" hides Alert and Warning; no banner below Warning', () {
      final user = GeoPoint(2.5, 102.8);
      final statuses = [
        assess(st('W', loc: GeoPoint(2.51, 102.8)), rd('W', river: 14.5), user: user),
        assess(st('A', loc: GeoPoint(2.51, 102.8)), rd('A', river: 12.5), user: user),
      ];
      expect(activeAlerts(statuses: statuses, savedIds: {}, minLevel: RiskLevel.danger).isEmpty, isTrue);
      final low = activeAlerts(statuses: [statuses[1]], savedIds: {});
      expect(low.now, hasLength(1));
      expect(low.banner, isNull);
    });

    test('nearest station: fresh readings only', () {
      final user = GeoPoint(2.5, 102.8);
      final statuses = [
        assess(st('OLD', loc: GeoPoint(2.501, 102.8)), rd('OLD', river: 11, minAgo: 600), user: user),
        assess(st('RAIN', loc: GeoPoint(2.502, 102.8), thresholds: false), rd('RAIN', rain: 3), user: user),
        assess(st('RIVER', loc: GeoPoint(2.51, 102.8)), rd('RIVER', river: 11), user: user),
        assess(st('NOLOC'), rd('NOLOC', river: 11), user: user),
      ];
      expect(nearestStation(statuses)!.station.id, 'RAIN');
      expect(nearestStation(statuses, riverOnly: true)!.station.id, 'RIVER');
      expect(nearestStation(const []), isNull);
    });
  });

  group('TP85 Lists by distance', () {
    test('withinKm keeps only stations that close; unknown distance left out', () {
      final user = GeoPoint(2.5, 102.8);
      final statuses = [
        assess(st('A', loc: GeoPoint(2.52, 102.8)), rd('A', river: 11), user: user), // 2.2 km
        assess(st('B', loc: GeoPoint(2.58, 102.8)), rd('B', river: 15), user: user), // 8.9 km
        assess(st('C'), rd('C', river: 16), user: user),
      ];
      const l = StationListService();
      expect([for (final s in l.apply(statuses, withinKm: 5, sortBy: SortBy.nearest)) s.station.id], ['A']);
      expect([for (final s in l.apply(statuses, withinKm: 10)) s.station.id], ['B', 'A']);
      expect(l.apply(statuses), hasLength(3));
    });

    test('household groups: never more than the total; old yes/no profiles still load', () {
      const p = HouseholdProfile(people: 3, babies: 1, children: 1, adults: 1, elderly: 2, mobility: 5, pets: 2);
      final f = p.fitted();
      expect([f.babies, f.children, f.adults, f.elderly], [1, 0, 0, 2], reason: 'adults taken off first, then children, babies, older people');
      expect(f.grouped, 3);
      expect(f.mobility, 3);
      final back = HouseholdProfile.fromMap(f.copyWith(powerMachine: true).toMap());
      expect([back.babies, back.children, back.elderly, back.pets], [1, 0, 2, 2]);
      expect(back.powerMachine, isTrue);
      final old = HouseholdProfile.fromMap({'people': '2', 'olderAdult': 'true', 'olderCount': 'x', 'pet': 'true'});
      expect(old.elderly, 1);
      expect(old.pets, 1);
      expect(const HouseholdProfile(olderAdult: true).elderly, 1);
      expect(const HouseholdProfile(people: 4, elderly: 2).copyWith(olderAdult: true).elderly, 2, reason: '"yes" keeps the number');
      expect(const HouseholdProfile(elderly: 2).copyWith(olderAdult: false).elderly, 0);
    });

    test('saving refuses groups that add up to more than the total', () async {
      final h = HouseholdService(profileStore: InMemorySettingsStore(), progressStore: InMemorySettingsStore());
      await expectLater(h.saveProfile(const HouseholdProfile(people: 2, adults: 2, babies: 1)), throwsA(isA<ValidationException>()));
      await h.saveProfile(const HouseholdProfile(people: 2, adults: 1, babies: 1, pets: 3));
      expect((await h.loadProfile())!.pets, 3);
    });

    test('advice is apart from the checklist; 999 has a call; Warning go-bag lists what to bring', () {
      const prep = PreparednessService();
      final danger = prep.checklist(RiskLevel.danger, null);
      expect(danger.any((i) => i.advice), isFalse);
      final advice = prep.advice(RiskLevel.danger, null);
      expect([for (final a in advice) a.id], ['danger.call', 'danger.water', 'danger.high']);
      expect(advice.first.call, '999');
      final bag = prep.checklist(RiskLevel.warning, const HouseholdProfile(people: 3, babies: 1, powerMachine: true, pets: 1))
          .firstWhere((i) => i.id == 'warning.bag');
      expect(bag.bring, contains('Milk, bottles and nappies for the baby'));
      expect(bag.bring, contains('Spare battery and charger for the oxygen or machine'));
      expect(bag.bring, contains('Pet food, water bowl and a lead or carrier'));
      expect(prep.checklist(RiskLevel.warning, null).firstWhere((i) => i.id == 'warning.bag').bring, hasLength(7));
    });
  });

  group('TP86 Flood reports and headcount', () {
    FloodReportDraft draft({ReportKind kind = ReportKind.damage, DateTime? at, DamageType? type = DamageType.road,
            DamageSeverity? severity = DamageSeverity.severe, String text = '', String ref = 'ref-1'}) =>
        FloodReportDraft(
            kind: kind, location: a, occurredAt: at ?? kNow.subtract(const Duration(hours: 1)), clientRef: ref,
            depth: DepthBand.knee, type: type, severity: severity, description: text);

    test('report checks: no future time, at most 60 days old, damage needs type and severity', () {
      final s = PublicReportsService(LocalReportsBackend(InMemorySettingsStore()), clock: fixedClock);
      expect(() => s.checkReport(draft(at: kNow.add(const Duration(hours: 1)))), throwsA(isA<ValidationException>()));
      expect(() => s.checkReport(draft(at: kNow.subtract(const Duration(days: 61)))), throwsA(isA<ValidationException>()));
      expect(() => s.checkReport(draft(type: null)), throwsA(isA<ValidationException>()));
      expect(() => s.checkReport(draft(text: 'x' * 501)), throwsA(isA<ValidationException>()));
      s.checkReport(draft(kind: ReportKind.floodingNow, type: null, severity: null)); // no damage questions
    });

    test('what is sent: body-height depth with a rough metre value; damage fields only for damage', () {
      final j = draft(kind: ReportKind.floodingNow).toJson();
      expect(j['kind'], 'sighting');
      expect(j['depth_band'], 'knee');
      expect(j['depth_m'], 0.5);
      expect(j.containsKey('type'), isFalse);
      expect(draft().toJson()['severity'], 'severe');
    });

    test('phone-only version: a retry with the same reference is not added twice; newest first', () async {
      final store = InMemorySettingsStore();
      final s = PublicReportsService(LocalReportsBackend(store, clock: fixedClock), clock: fixedClock);
      expect(s.reachesStaff, isFalse);
      await s.submitReport(draft());
      await s.submitReport(draft());
      await s.submitReport(draft(kind: ReportKind.floodingNow, type: null, severity: null, ref: 'ref-2'));
      final mine = await s.myReports();
      expect([for (final r in mine) r.kind], [ReportKind.floodingNow, ReportKind.damage]);
      expect(mine.last.status, ReportStatus.pending);
    });

    test('headcount checks match the server', () {
      final s = PublicReportsService(LocalReportsBackend(InMemorySettingsStore()), clock: fixedClock);
      expect(() => s.checkHeadcount(HeadcountDraft(total: 0)), throwsA(isA<ValidationException>()));
      expect(() => s.checkHeadcount(HeadcountDraft(total: 31)), throwsA(isA<ValidationException>()));
      expect(() => s.checkHeadcount(HeadcountDraft(total: 2, babies: 2, elderly: 1)), throwsA(isA<ValidationException>()));
      expect(() => s.checkHeadcount(HeadcountDraft(total: 2, reducedMobility: 3)), throwsA(isA<ValidationException>()));
      s.checkHeadcount(HeadcountDraft(total: 2, babies: 1, elderly: 1, reducedMobility: 2));
      expect(() => s.checkHeadcount(HeadcountDraft(total: 3, babies: 1, children: 1, adults: 1, elderly: 1)), throwsA(isA<ValidationException>()));
      expect(() => s.checkHeadcount(HeadcountDraft(total: 1, adults: 1, pets: 21)), throwsA(isA<ValidationException>()));
      s.checkHeadcount(HeadcountDraft(total: 4, babies: 1, children: 1, adults: 1, elderly: 1, pets: 2));
    });

    test('headcount on the phone: send, arrive, leave (stops counting), remove', () async {
      final s = PublicReportsService(
          LocalReportsBackend(InMemorySettingsStore(), clock: fixedClock, centreName: (id) => 'Hall $id'),
          clock: fixedClock);
      final h = await s.submitHeadcount(HeadcountDraft(
          total: 4, elderly: 1, adults: 2, children: 1, pets: 1, powerMachine: true,
          needs: {SpecialNeed.power, SpecialNeed.other}, otherNeed: ' halal food ', centreId: 'C1'));
      expect([h.adults, h.children, h.pets, h.powerMachine], [2, 1, 1, true]);
      expect(h.centreName, 'Hall C1');
      expect(h.otherNeed, 'halal food');
      expect(h.expiresAt, kNow.add(const Duration(hours: 72)));
      expect(h.isCurrent(kNow), isTrue);
      expect((await s.setHeadcountStatus(HeadcountStatus.arrived)).status, HeadcountStatus.arrived);
      final left = await s.setHeadcountStatus(HeadcountStatus.left);
      expect(left.isCurrent(kNow), isFalse);
      expect((await s.myHeadcount())!.needs, {SpecialNeed.power, SpecialNeed.other});
      expect((await s.myHeadcount())!.adults, 2, reason: 'kept on the phone');
      await s.removeHeadcount();
      expect(await s.myHeadcount(), isNull);
    });

    test('Supabase: the right database functions, as the signed-in phone', () async {
      final http = FakeHttp()
        ..reply('/rest/v1/rpc/submit_flood_report', 200, '"00000000-0000-0000-0000-000000000001"')
        ..reply('/rest/v1/rpc/my_flood_reports', 200, jsonEncode([
          {'id': 'r1', 'kind': 'sighting', 'occurred_at': '2026-11-17T02:00:00Z', 'status': 'verified', 'depth_band': 'waist'},
          {'id': 'bad'}, // unreadable rows are skipped
        ]))
        ..reply('/rest/v1/rpc/submit_headcount', 200, jsonEncode({
          'total': 3, 'babies': 1, 'elderly': 0, 'reduced_mobility': 0, 'needs': ['formula', 'unknown'],
          'other_need': '', 'status': 'on_the_way', 'updated_at': '2026-11-17T03:00:00Z',
          'expires_at': '2026-11-20T03:00:00Z', 'centre_id': 'uuid-1', 'centre_name': 'Dewan A',
        }))
        ..reply('/rest/v1/rpc/my_headcount', 200, 'null');
      final s = PublicReportsService(SupabaseReportsBackend(http.api()), clock: fixedClock);
      expect(s.reachesStaff, isTrue);
      await s.submitReport(draft());
      final sent = jsonDecode(http.calls.last.body!) as Map;
      expect((sent['p'] as Map)['client_ref'], 'ref-1');
      expect(http.calls.last.headers['Authorization'], startsWith('Bearer '));
      final mine = await s.myReports();
      expect(mine.single.status, ReportStatus.verified);
      expect(mine.single.depth, DepthBand.waist);
      final h = await s.submitHeadcount(HeadcountDraft(total: 3, babies: 1, needs: {SpecialNeed.babyFormula}));
      expect(h.needs, {SpecialNeed.babyFormula});
      expect(h.centreName, 'Dewan A');
      expect(await s.myHeadcount(), isNull);
    });
  });
}
