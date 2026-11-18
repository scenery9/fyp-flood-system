// TP96: a saved rain-only station leads with the rain on Home.
// TP95: a centre over 150 km away gets a clear "too far" note, not a route.
// TP94: Add an area by State, then District.
// TP91: relief centres from places/centres.csv on screen: a centre whose
// position was not checked, and capacity that is only an estimate.
// Sample data; nothing is sent anywhere.
import 'package:flood_app/app/app_controller.dart';
import 'package:flood_app/app/sample_data.dart';
import 'package:flood_app/screens/home/home_screen.dart';
import 'package:flood_core/flood_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' hide Table;

import 'helpers.dart';

/// The sample centres, plus one very close to the user whose position nobody
/// has checked, and an estimated capacity on SK Buloh Kasap.
Future<Table<EvacuationPoint>> centresWithUnchecked() async {
  final t = SampleData.centres() as MemoryTable<EvacuationPoint>;
  final buloh = (await t.byId('PPS-BULOH'))!;
  await t.put(
      buloh.id,
      EvacuationPoint(
          id: buloh.id, name: buloh.name, location: buloh.location, capacity: buloh.capacity,
          occupancy: buloh.occupancy, capacityEstimated: true));
  await t.put(
      'PPS-NEW',
      EvacuationPoint(
          id: 'PPS-NEW', name: 'Dewan Belum Disemak', location: GeoPoint(2.567, 102.811), capacity: 100,
          locationChecked: false));
  return t;
}

void main() {
  group('TP91 Centres from the list', () {
    testWidgets('an unchecked centre is listed, but never suggested and gets no route', (tester) async {
      final app = TestApp(centres: await centresWithUnchecked());
      await app.start(tester);
      // the background route goes to the nearest checked, open centre with space
      expect((await app.routeStore.load()).keys, ['PPS-BULOH']);
      expect(app.controller.nearestAvailable!.point.id, 'PPS-BULOH');
      await openTab(tester, 'Centres');
      final callsBefore = app.routes.calls;
      await tapIt(tester, find.text('Dewan Belum Disemak'));
      expect(find.byKey(const ValueKey('centre-unchecked')), findsOneWidget);
      expect(find.byKey(const ValueKey('centre-route')), findsNothing);
      expect(find.text('Location not checked yet'), findsWidgets); // instead of a distance
      await tapIt(tester, find.byKey(const ValueKey('centre-directions')));
      final uri = app.opener.opened.last;
      expect(uri.path, '/maps/search/');
      expect(uri.queryParameters['query'], 'Dewan Belum Disemak');
      expect(app.routes.calls, callsBefore, reason: 'no route was asked for the unchecked centre');
    });

    testWidgets('the route page refuses an unchecked centre without asking the server', (tester) async {
      final app = TestApp(centres: await centresWithUnchecked());
      await app.start(tester);
      final p = (await app.controller.evacuation.listAll()).firstWhere((c) => c.id == 'PPS-NEW');
      final r = await app.controller.routeTo(p);
      expect(r.plan, isNull);
      expect(r.error, RouteError.unchecked);
    });

    testWidgets('an estimated capacity says so', (tester) async {
      final app = TestApp(centres: await centresWithUnchecked());
      await app.start(tester);
      await openTab(tester, 'Centres'); // SK Buloh Kasap is chosen first (nearest open)
      await reveal(tester, find.textContaining('of about 400 spaces taken (estimate)'));
      expect(find.textContaining('of about 400 spaces taken (estimate)'), findsOneWidget);
      expect(find.byKey(const ValueKey('centre-route')), findsOneWidget);
    });
  });

  group('TP93 Route guide: one highlighted step', () {
    Future<TestApp> openRoute(WidgetTester tester) async {
      final app = TestApp();
      await app.start(tester);
      await openTab(tester, 'Centres');
      await tapIt(tester, find.byKey(const ValueKey('centre-route')));
      return app;
    }

    String highlighted(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('next-step'))).data!;

    testWidgets('Next and Back move the highlight and read the step aloud', (tester) async {
      final app = await openRoute(tester);
      expect(highlighted(tester), 'Head north on Jalan Awat');
      expect(find.text('Step 1 of 3'), findsOneWidget);
      await tapIt(tester, find.byKey(const ValueKey('step-next')));
      expect(highlighted(tester), 'Turn left onto Jalan Buloh Kasap');
      expect(find.text('Step 2 of 3'), findsOneWidget);
      expect(app.speaker.spoken.last.$1, 'Turn left onto Jalan Buloh Kasap');
      await tapIt(tester, find.byKey(const ValueKey('step-back')));
      expect(highlighted(tester), 'Head north on Jalan Awat');
      expect(tester.widget<OutlinedButton>(find.byKey(const ValueKey('step-back'))).onPressed, isNull);
    });

    testWidgets('tapping a greyed-out step highlights it; Next stops at the last step', (tester) async {
      await openRoute(tester);
      await tapIt(tester, find.byKey(const ValueKey('step-2')));
      expect(highlighted(tester), 'Arrive at SK Buloh Kasap');
      expect(tester.widget<FilledButton>(find.byKey(const ValueKey('step-next'))).onPressed, isNull);
      // each step is shown once, in one list
      expect(find.text('Head north on Jalan Awat'), findsOneWidget);
    });

    testWidgets('with Read aloud off, moving the highlight is silent', (tester) async {
      final app = TestApp();
      await app.voiceStore.save({'readAloud': 'false'});
      await app.start(tester);
      await openTab(tester, 'Centres');
      await tapIt(tester, find.byKey(const ValueKey('centre-route')));
      await tapIt(tester, find.byKey(const ValueKey('step-next')));
      expect(app.speaker.spoken, isEmpty);
    });
  });
  group('TP94 Add an area by state, then district', () {
    testWidgets('starts on the nearest state; the district list follows the state', (tester) async {
      await TestApp().start(tester);
      await tapIt(tester, find.byKey(const ValueKey('change-area')));
      await tapIt(tester, find.byKey(const ValueKey('add-area')));
      // the sample phone is near Segamat, so Johor is chosen first
      expect(find.descendant(of: find.byKey(const ValueKey('state-menu')), matching: find.text('Johor')), findsOneWidget);

      await tapIt(tester, find.byKey(const ValueKey('state-menu')));
      await tapIt(tester, find.byKey(const ValueKey('menu-Melaka')).last);
      expect(find.text('Sg. Muar di Kg. Awat'), findsNothing);
      expect(find.text('Sg. Melaka di Batu Hampar'), findsOneWidget);

      await tapIt(tester, find.byKey(const ValueKey('district-menu')));
      expect(find.byKey(const ValueKey('menu-Segamat')), findsNothing); // only Melaka's districts
      await tapIt(tester, find.byKey(const ValueKey('menu-Alor Gajah')).last);
      expect(find.text('Stesen Hujan Durian Tunggal'), findsOneWidget);
      expect(find.text('Sg. Melaka di Batu Hampar'), findsNothing);

      // a new state clears the district
      await tapIt(tester, find.byKey(const ValueKey('state-menu')));
      await tapIt(tester, find.text('All states').last);
      expect(find.descendant(of: find.byKey(const ValueKey('district-menu')), matching: find.text('All districts')), findsOneWidget);
    });
  });

  group('TP95 A centre too far for a route', () {
    testWidgets('says it is too far and does not ask the route server', (tester) async {
      final t = SampleData.centres() as MemoryTable<EvacuationPoint>;
      // Georgetown, Penang: about 400 km from the sample phone near Segamat
      await t.put('PPS-FAR', EvacuationPoint(id: 'PPS-FAR', name: 'Dewan Jauh', location: GeoPoint(5.414, 100.329), capacity: 100));
      final app = TestApp(centres: t);
      await app.start(tester);
      final callsBefore = app.routes.calls;
      final p = (await app.controller.evacuation.listAll()).firstWhere((c) => c.id == 'PPS-FAR');
      final r = await app.controller.routeTo(p);
      expect(r.plan, isNull);
      expect(r.error, RouteError.tooFar);
      expect(app.routes.calls, callsBefore, reason: 'the server refuses it anyway');
    });
  });

  group('TP96 Home card for a rain gauge', () {
    testWidgets('a rain-only station shows the rain, not "No recent data"', (tester) async {
      await TestApp(followed: const ['MLK-DURIAN']).start(tester); // 65 mm/h, no river gauge
      Finder inCard(String text) => find.descendant(of: find.byType(AreaCard), matching: find.text(text));
      expect(inCard('Very heavy rain'), findsOneWidget);
      expect(inCard('Rain gauge only, no river reading'), findsOneWidget);
      expect(inCard('65.0 mm/h'), findsOneWidget);
      expect(inCard('No recent data'), findsNothing);
    });
  });
}
