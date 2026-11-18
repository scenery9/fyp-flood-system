// TP88: asking for location when the app opens, and remembering the choice.
import 'package:flood_app/app/platform.dart';
import 'package:flood_app/app/sample_data.dart';
import 'package:flood_core/flood_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers.dart';

LocationFix refused() => LocationFix(SampleData.userLocation, issue: LocationIssue.denied);
LocationFix here() => LocationFix(GeoPoint(2.57, 102.80));

void main() {
  group('TP88 Location when the app opens', () {
    testWidgets('first time: FloodReady explains, then Allow shows the phone pop-up and remembers', (tester) async {
      final app = TestApp(locationAskedBefore: false, location: refused());
      await app.start(tester);
      expect(find.text('Use your location?'), findsOneWidget);
      expect(app.location.prompted, 0, reason: 'no phone pop-up before the user agrees');
      app.location.fix = here(); // the user taps "While using the app"
      await tapIt(tester, find.byKey(const ValueKey('loc-allow')));
      expect(app.location.prompted, 1);
      expect(find.byKey(const ValueKey('tab-Home')), findsOneWidget);
      expect(app.controller.userLocation.lat, 2.57);
      expect((await app.flagsStore.load())['locAuto'], 'true');
    });

    testWidgets('already allowed on the phone: nothing asked, used automatically', (tester) async {
      final app = TestApp(locationAskedBefore: false, location: here());
      await app.start(tester);
      expect(find.text('Use your location?'), findsNothing);
      expect(app.location.prompted, 0);
      expect(app.controller.locationChoice.automatic, isTrue);
    });

    testWidgets('"Not now": asked again next time; with "Don\'t ask me again": not asked', (tester) async {
      final first = TestApp(locationAskedBefore: false, location: refused());
      await first.start(tester);
      await tapIt(tester, find.byKey(const ValueKey('loc-not-now')));
      expect(find.byKey(const ValueKey('tab-Home')), findsOneWidget);
      expect(first.location.prompted, 0);

      final second = TestApp(flags: await first.flagsStore.load(), location: refused());
      await second.start(tester);
      expect(find.text('Use your location?'), findsOneWidget, reason: 'next launch asks again');
      await tapIt(tester, find.byKey(const ValueKey('loc-dont-ask')));
      await tapIt(tester, find.byKey(const ValueKey('loc-not-now')));

      final third = TestApp(flags: await second.flagsStore.load(), location: refused());
      await third.start(tester);
      expect(find.text('Use your location?'), findsNothing);
      expect(third.location.prompted, 0);
    });

    testWidgets('agreed before but "Only this time" ended: only the phone pop-up, at launch', (tester) async {
      final app = TestApp(flags: const {'locAuto': 'true'}, location: refused());
      await app.start(tester);
      expect(find.text('Use your location?'), findsNothing);
      expect(app.location.prompted, 1);
    });

    testWidgets('refreshing never shows the pop-up', (tester) async {
      final app = TestApp(flags: const {'locAuto': 'true'}, location: refused());
      await app.start(tester);
      await app.controller.refresh();
      await tester.pumpAndSettle();
      expect(app.location.prompted, 1, reason: 'only the one at launch');
    });

    testWidgets('blocked on the phone is remembered: no question; the button opens settings', (tester) async {
      final app = TestApp(flags: const {'locBlocked': 'true'}, location: refused());
      await app.start(tester);
      expect(find.text('Use your location?'), findsNothing);
      await openTab(tester, 'Centres');
      expect(find.textContaining('Location is blocked for this app.'), findsOneWidget);
      await tapIt(tester, find.byKey(const ValueKey('location-retry')));
      expect(app.location.settingsOpened, 1);
    });

    testWidgets('More switch: off stops using location; on asks again', (tester) async {
      final app = TestApp(location: here());
      await app.start(tester);
      await openTab(tester, 'More');
      final before = app.location.asked;
      await tapIt(tester, find.byKey(const ValueKey('location-switch')));
      expect(app.controller.locationIssue, LocationIssue.off);
      expect(app.location.asked, before, reason: 'GPS not used when switched off');
      expect(app.controller.nearest, isNull);
      await openTab(tester, 'Centres');
      expect(find.textContaining('You chose not to use your location.'), findsOneWidget);
      await openTab(tester, 'More');
      await tapIt(tester, find.byKey(const ValueKey('location-switch')));
      expect(app.location.prompted, 1);
      expect(app.controller.locationIssue, isNull);
    });

    testWidgets('switched on but blocked on the phone: a row opens the phone settings', (tester) async {
      final app = TestApp(location: LocationFix(SampleData.userLocation, issue: LocationIssue.deniedForever));
      await app.start(tester);
      await openTab(tester, 'More');
      await tapIt(tester, find.byKey(const ValueKey('location-switch')));
      expect(app.location.settingsOpened, 1, reason: 'turning it on opens settings when blocked');
      await tapIt(tester, find.byKey(const ValueKey('location-settings')));
      expect(app.location.settingsOpened, 2);
    });
  });
}
