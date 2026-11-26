// TP75-TP79: alerts page (from More), route kept on the phone, flood
// reports, the relief-centre headcount, and the smaller button-only changes.
// Sample data; nothing is sent anywhere.
import 'package:flood_app/app/platform.dart';
import 'package:flood_app/app/sample_data.dart';
import 'package:flood_core/flood_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers.dart';

const awat = 'Sg. Muar di Kg. Awat';

void main() {
  group('TP75 Alerts without setup', () {
    testWidgets('Home shows the app name, no banner; Alerts page (from More) lists now and expected', (tester) async {
      await TestApp().start(tester);
      expect(find.text('FloodReady'), findsOneWidget);
      expect(find.text('Danger at $awat'), findsNothing);
      await openTab(tester, 'More');
      await tapIt(tester, find.byKey(const ValueKey('more-alerts')));
      // Now: Kg. Awat (Danger, saved) and Segamat Kecil (Warning, about 6 km away).
      expect(find.byKey(const ValueKey('alert-JHR-AWAT')), findsOneWidget);
      expect(find.byKey(const ValueKey('alert-JHR-SEGKECIL')), findsOneWidget);
      // Buloh Kasap is at Alert (below Warning) but the AI expects Warning.
      expect(find.text('Warning expected'), findsOneWidget);
      await tapIt(tester, find.byKey(const ValueKey('alert-JHR-SEGKECIL')));
      expect(find.text('River level'), findsOneWidget);
    });

    testWidgets('"Notify me from Danger": only Danger is listed', (tester) async {
      final app = TestApp(settings: const {'notificationThreshold': 'danger'});
      await app.start(tester);
      expect(app.controller.alerts.now.map((a) => a.status.station.id), ['JHR-AWAT']);
      expect(app.controller.alerts.expected, isEmpty);
    });

    testWidgets('More shows how many alerts there are now', (tester) async {
      await TestApp().start(tester);
      await openTab(tester, 'More');
      await tapIt(tester, find.byKey(const ValueKey('more-alerts')));
      expect(find.text('Now'), findsOneWidget);
    });
  });

  group('TP76 Route kept on the phone', () {
    testWidgets('the nearest open centre\'s route is saved in the background and used without internet', (tester) async {
      final app = TestApp();
      await app.start(tester);
      expect((await app.routeStore.load()).keys, ['PPS-BULOH'], reason: 'saved after Home loaded');
      app.routes.fail = true;
      await openTab(tester, 'Centres');
      await tapIt(tester, find.byKey(const ValueKey('centre-route')));
      await tapIt(tester, find.byKey(const ValueKey('route-update')));
      expect(find.textContaining('No internet: showing the route saved'), findsOneWidget);
      expect(find.text('6.2 km · about 12 min by car'), findsOneWidget);
    });

    testWidgets('steps are worded in the app language; next step in large print with Read aloud', (tester) async {
      final app = TestApp(settings: const {'language': 'ms'});
      app.routes.typed = true;
      await app.start(tester);
      await openTab(tester, 'Pusat'); // tab keys use the shown (Malay) label
      await tapIt(tester, find.byKey(const ValueKey('centre-route')));
      expect(tester.widget<Text>(find.byKey(const ValueKey('next-step'))).data, 'Mula di Jalan Awat');
      await reveal(tester, find.text('Belok kiri ke Jalan Buloh Kasap'));
      expect(find.text('Tiba di pusat pemindahan'), findsOneWidget);
      await tapIt(tester, find.byKey(const ValueKey('read-route-PPS-BULOH')));
      expect(app.speaker.spoken.last.$1, startsWith('Mula di Jalan Awat. Belok kiri'));
    });

    testWidgets('Centres list shows the drive time once the road route is known', (tester) async {
      await TestApp().start(tester);
      await openTab(tester, 'Centres');
      expect(find.text('6.2 km · 12 min drive'), findsWidgets);
    });

    testWidgets('"Open with space only" hides full and closed centres', (tester) async {
      await TestApp().start(tester);
      await openTab(tester, 'Centres');
      await reveal(tester, find.text('Dewan Jementah'));
      expect(find.text('Dewan Jementah'), findsOneWidget);
      await tapIt(tester, find.byKey(const ValueKey('open-only-true')));
      expect(find.text('Dewan Jementah'), findsNothing);
      expect(find.text('Dewan Kg. Awat'), findsNothing);
    });
  });

  group('TP77 Report flooding', () {
    testWidgets('flooding here now: buttons only; appears under My reports', (tester) async {
      final app = TestApp();
      await app.start(tester);
      await tapIt(tester, find.byKey(const ValueKey('report-flooding')));
      expect(find.textContaining('Near '), findsOneWidget); // place from the phone's location
      await tapIt(tester, find.byKey(const ValueKey('depth-knee')));
      await tapIt(tester, find.byKey(const ValueKey('report-send')));
      expect(find.text('Report saved on this phone (test version).'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.text('Flooding seen'), findsOneWidget);
      expect(find.text('Being checked'), findsOneWidget);
      final mine = await app.controller.myReports();
      expect(mine.single.depth, DepthBand.knee);
      await waitForSnackBar(tester);
    });

    testWidgets('damage: Send stays off until what and how bad are chosen', (tester) async {
      final app = TestApp();
      await app.start(tester);
      await tapIt(tester, find.byKey(const ValueKey('report-flooding')));
      await tapIt(tester, find.byKey(const ValueKey('kind-damage')));
      FilledButton send() => tester.widget<FilledButton>(find.byKey(const ValueKey('report-send')));
      await reveal(tester, find.byKey(const ValueKey('report-send')));
      expect(send().onPressed, isNull);
      await tapIt(tester, find.byKey(const ValueKey('type-road')));
      await tapIt(tester, find.byKey(const ValueKey('severity-severe')));
      await tapIt(tester, find.byKey(const ValueKey('when-hourAgo')));
      await reveal(tester, find.byKey(const ValueKey('report-send')));
      expect(send().onPressed, isNotNull);
      await tapIt(tester, find.byKey(const ValueKey('report-send')));
      final r = (await app.controller.myReports()).single;
      expect(r.kind, ReportKind.damage);
      expect(r.type, DamageType.road);
      expect(DateTime.now().difference(r.occurredAt).inMinutes, closeTo(60, 2));
      await waitForSnackBar(tester);
    });

    testWidgets('location off: the report needs a place picked on the map', (tester) async {
      await TestApp(location: LocationFix(SampleData.userLocation, issue: LocationIssue.denied)).start(tester);
      await tapIt(tester, find.byKey(const ValueKey('report-flooding')));
      await tapIt(tester, find.byKey(const ValueKey('report-send')));
      expect(find.textContaining('pick the place on the map'), findsWidgets);
      await waitForSnackBar(tester);
    });
  });

  group('TP78 Headcount for a relief centre', () {
    testWidgets('filled from the household; send, arrive, remove', (tester) async {
      final app = TestApp();
      await app.start(tester);
      await openTab(tester, 'Centres');
      await tapIt(tester, find.byKey(const ValueKey('centre-headcount')));
      await tapIt(tester, find.text('Not now')); // household lock question
      // testProfile: 4 people, one aged 60+, daily medicine.
      expect(find.text('4'), findsOneWidget);
      expect(find.text('Who is coming? (1 of 4 counted)'), findsOneWidget);
      await tapIt(tester, find.byKey(const ValueKey('hc-adults-plus')));
      await tapIt(tester, find.byKey(const ValueKey('hc-machine')));
      await tapIt(tester, find.byKey(const ValueKey('headcount-send')));
      final h = app.controller.headcount!;
      expect([h.total, h.elderly, h.adults], [4, 1, 1]);
      expect([h.dailyMedicine, h.powerMachine], [true, true]);
      expect(h.needs, {SpecialNeed.power}, reason: 'staff still see power as a need');
      expect(tester.widget<Text>(find.byKey(const ValueKey('headcount-centre'))).data, 'SK Buloh Kasap');
      await waitForSnackBar(tester);

      await tapIt(tester, find.byKey(const ValueKey('headcount-status-arrived')));
      expect(app.controller.headcount!.status, HeadcountStatus.arrived);

      await tapIt(tester, find.byKey(const ValueKey('headcount-remove')));
      await tapIt(tester, find.byKey(const ValueKey('headcount-remove-yes')));
      expect(app.controller.headcount, isNull);
      await reveal(tester, find.byKey(const ValueKey('headcount-send')));
      expect(find.byKey(const ValueKey('headcount-send')), findsOneWidget);
    });

    testWidgets('steppers keep the four groups within the total', (tester) async {
      final app = TestApp(profile: const HouseholdProfile(people: 2));
      await app.start(tester);
      await openTab(tester, 'Centres');
      await tapIt(tester, find.byKey(const ValueKey('centre-headcount')));
      await tapIt(tester, find.text('Not now'));
      await tapIt(tester, find.byKey(const ValueKey('hc-elderly-plus')));
      await tapIt(tester, find.byKey(const ValueKey('hc-babies-plus')));
      for (final g in ['babies', 'children', 'adults', 'elderly']) {
        final plus = tester.widget<IconButton>(find.byKey(ValueKey('hc-$g-plus')));
        expect(plus.onPressed, isNull, reason: '1 older person + 1 baby = the total of 2');
      }
      // Lowering the total takes people off the groups too.
      await tapIt(tester, find.byKey(const ValueKey('hc-total-minus')));
      expect(find.text('Who is coming? (1 of 1 counted)'), findsOneWidget);
    });
  });

  group('TP79 Fewer things to type', () {
    testWidgets('household form: − / + for each group, never more than the people at home', (tester) async {
      final app = TestApp(profile: null);
      await app.start(tester);
      await tapIt(tester, find.byKey(const ValueKey('people-plus'))); // 2 people
      await tapIt(tester, find.byKey(const ValueKey('grp-adults-plus')));
      await tapIt(tester, find.byKey(const ValueKey('grp-babies-plus')));
      expect(tester.widget<Text>(find.byKey(const ValueKey('groups-counted'))).data, '2 of 2 counted');
      expect(tester.widget<IconButton>(find.byKey(const ValueKey('grp-children-plus'))).onPressed, isNull);
      await tapIt(tester, find.byKey(const ValueKey('pets-plus')));
      await tapIt(tester, find.byKey(const ValueKey('hh-machine')));
      await tapIt(tester, find.byKey(const ValueKey('household-save')));
      final p = (await app.controller.household.loadProfile())!;
      expect([p.people, p.babies, p.adults, p.pets], [2, 1, 1, 1]);
      expect(p.powerMachine, isTrue);
    });

    testWidgets('Danger: one safety card (cautions in its text), not ticks; Call 999 opens the phone app in one tap', (tester) async {
      final app = TestApp();
      await app.start(tester);
      await openTab(tester, 'Prepare');
      await reveal(tester, find.byKey(const ValueKey('advice-danger.call')));
      expect(find.byKey(const ValueKey('tick-danger.call')), findsNothing);
      expect(find.byKey(const ValueKey('advice-danger.water')), findsNothing);
      expect(find.byKey(const ValueKey('advice-danger.high')), findsNothing);
      expect(find.descendant(of: find.byKey(const ValueKey('advice-danger.call')), matching: find.textContaining('Do not walk or drive through flood water')),
          findsOneWidget);
      await tapIt(tester, find.byKey(const ValueKey('advice-call-999')));
      expect(app.opener.opened.first.toString(), 'tel:999');
    });

    testWidgets('Normal: the go-bag item uses the same "What to bring" list', (tester) async {
      await TestApp().start(tester);
      await openTab(tester, 'Prepare');
      await tapIt(tester, find.text('Normal').last);
      await reveal(tester, find.byKey(const ValueKey('bring-normal.gobag')));
      expect(find.text('What to bring'), findsOneWidget);
    });

    testWidgets('Warning: the go-bag item lists what to bring', (tester) async {
      await TestApp().start(tester);
      await openTab(tester, 'Prepare');
      await tapIt(tester, find.text('Warning').last);
      await reveal(tester, find.byKey(const ValueKey('bring-warning.bag')));
      expect(find.text('What to bring'), findsOneWidget);
      expect(find.text('Medicine for 7 days and a copy of the prescription'), findsOneWidget);
    });

    testWidgets('emergency contact from the phone\'s contacts', (tester) async {
      final app = TestApp();
      await app.start(tester);
      await openTab(tester, 'More');
      await tapIt(tester, find.text('Emergency numbers'));
      await tapIt(tester, find.byKey(const ValueKey('contact-pick')));
      expect(app.contacts.asked, 1);
      expect(app.controller.emergencyContact, '019-876 5432');
      await waitForSnackBar(tester);
    });

    testWidgets('add an area: nearest stations first, star to save from the river list', (tester) async {
      final app = TestApp(followed: const ['JHR-AWAT']);
      await app.start(tester);
      await tapIt(tester, find.byKey(const ValueKey('change-area')));
      await tapIt(tester, find.byKey(const ValueKey('add-area')));
      expect(find.textContaining('Segamat, Johor · '), findsWidgets); // distance shown
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await openTab(tester, 'Centres');
      await tapIt(tester, find.text('River'));
      await tapIt(tester, find.byKey(const ValueKey('star-JHR-BULOH')));
      expect(await app.followedStore.load(), ['JHR-AWAT', 'JHR-BULOH']);
    });

    testWidgets('drag a station card right: Save / Remove on the left edge', (tester) async {
      final app = TestApp(followed: const ['JHR-AWAT']);
      await app.start(tester);
      await openTab(tester, 'Centres');
      await tapIt(tester, find.text('River'));
      final card = find.byKey(const ValueKey('station-card-JHR-BULOH'));
      await reveal(tester, card);
      final width = tester.getSize(card).width;

      // Past 45% of the width: saved at once, and the card slides back.
      await tester.drag(card, Offset(width * 0.6, 0));
      await tester.pumpAndSettle();
      expect(await app.followedStore.load(), ['JHR-AWAT', 'JHR-BULOH']);
      expect(find.byKey(const ValueKey('swipe-action-JHR-BULOH')), findsNothing);

      // A short drag leaves the drawer open: "Remove" (white text, no icon), star hidden.
      await tester.drag(card, const Offset(80, 0));
      await tester.pumpAndSettle();
      final drawer = find.byKey(const ValueKey('swipe-action-JHR-BULOH'));
      expect(find.descendant(of: drawer, matching: find.text('Remove')), findsOneWidget);
      expect(find.descendant(of: drawer, matching: find.byType(Icon)), findsNothing);
      expect(tester.widget<Text>(find.descendant(of: drawer, matching: find.text('Remove'))).style!.color, Colors.white);
      expect(tester.widget<IgnorePointer>(find.ancestor(of: find.byKey(const ValueKey('star-JHR-BULOH')), matching: find.byType(IgnorePointer)).first).ignoring,
          isTrue);
      // Tapping the card body only closes the drawer (does not open the station).
      await tester.tap(find.descendant(of: card, matching: find.text('Sg. Muar di Buloh Kasap')));
      await tester.pumpAndSettle();
      expect(drawer, findsNothing);
      expect(find.text('River levels now'), findsOneWidget); // still on Centres

      // Open again and tap Remove.
      await tester.drag(card, const Offset(80, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.descendant(of: drawer, matching: find.text('Remove')));
      await tester.pumpAndSettle();
      expect(await app.followedStore.load(), ['JHR-AWAT']);
    });
  });

  group('TP89 Forecast as now and later', () {
    testWidgets('Now and By-time boxes and the change in words; read aloud includes them', (tester) async {
      final app = TestApp();
      await app.start(tester);
      await reveal(tester, find.byKey(const ValueKey('now-later-JHR-AWAT')));
      expect(find.byKey(const ValueKey('gauge-now')), findsOneWidget);
      expect(find.byKey(const ValueKey('gauge-later')), findsOneWidget);
      expect(find.text('20.04 m'), findsOneWidget);
      // 19.97 -> 20.04 m; Danger starts at 19.95 m.
      expect(tester.widget<Text>(find.byKey(const ValueKey('gauge-change'))).data, 'Rising slowly (+7 cm)');
      expect(tester.widget<Text>(find.byKey(const ValueKey('gauge-line'))).data, '2 cm above the Danger line');
      await tapIt(tester, find.byKey(const ValueKey('read-forecast-JHR-AWAT')));
      expect(app.speaker.spoken.single.$1, contains('Now 19.97 metres. By '));
      expect(app.speaker.spoken.single.$1, contains('2 cm above the Danger line'));
    });
  });
}
