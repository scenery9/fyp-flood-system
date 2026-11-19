// TP47-TP59: screens, navigation and every setting (sample data, no real phone).
import 'package:flood_app/app/app_controller.dart';
import 'package:flood_app/app/platform.dart';
import 'package:flood_app/app/sample_data.dart';
import 'package:flood_app/screens/home/home_screen.dart';
import 'package:flood_app/widgets/app_map.dart';
import 'package:flood_core/flood_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart' show LocationPermission;
import 'package:material_ui/material_ui.dart';

import 'helpers.dart';

const awat = 'Sg. Muar di Kg. Awat';

/// A reading on the saved-area card (the forecast card shows the same number too).
Finder inAreaCard(String text) => find.descendant(of: find.byType(AreaCard), matching: find.text(text));
const buloh = 'Sg. Muar di Buloh Kasap';

void main() {
  group('TP47 First launch', () {
    testWidgets('no household saved: the form shows instead of the tabs', (tester) async {
      await TestApp(profile: null).start(tester);
      expect(find.text('About your household'), findsOneWidget);
      expect(find.byKey(const ValueKey('tab-Home')), findsNothing);
    });

    testWidgets('Save and continue saves the form and opens Home', (tester) async {
      final app = TestApp(profile: null);
      await app.start(tester);
      await tapIt(tester, find.byKey(const ValueKey('household-save')));
      expect(find.byKey(const ValueKey('tab-Home')), findsOneWidget);
      expect(app.profileStore.load(), completion(containsPair('saved', 'true')));
    });

    testWidgets('Skip for now opens Home and is remembered after a restart', (tester) async {
      final app = TestApp(profile: null);
      await app.start(tester);
      await tapIt(tester, find.byKey(const ValueKey('household-skip')));
      expect(find.byKey(const ValueKey('tab-Home')), findsOneWidget);
      expect(await app.controller.household.setupSkipped(), isTrue);
    });
  });

  group('TP48 Bottom menu', () {
    testWidgets('each tab opens its screen and is marked selected', (tester) async {
      await TestApp().start(tester);
      expect(find.text('Go to relief centre'), findsOneWidget);
      await openTab(tester, 'Prepare');
      expect(find.text('Show checklist for · river is now at Danger'), findsOneWidget);
      await openTab(tester, 'Centres');
      expect(find.text('Relief centres near you'), findsOneWidget);
      await openTab(tester, 'More');
      expect(find.text('Easy to read'), findsOneWidget);
      await openTab(tester, 'Home');
      expect(find.text('Go to relief centre'), findsOneWidget);
    });

    testWidgets('every tab target is at least 48 x 48', (tester) async {
      await TestApp().start(tester);
      for (final t in ['Home', 'Prepare', 'Centres', 'More']) {
        final size = tester.getSize(find.byKey(ValueKey('tab-$t')));
        expect(size.width, greaterThanOrEqualTo(48), reason: t);
        expect(size.height, greaterThanOrEqualTo(48), reason: t);
      }
    });

    testWidgets('"Go to relief centre" and More > Relief centres open the Centres tab', (tester) async {
      final app = TestApp();
      await app.start(tester);
      await tapIt(tester, find.byKey(const ValueKey('go-centre')));
      expect(app.controller.tab, AppTab.centres);
      await openTab(tester, 'More');
      await tapIt(tester, find.text('Relief centres'));
      expect(app.controller.tab, AppTab.centres);
    });
  });

  group('TP49 Home area card', () {
    testWidgets('shows the first saved area with its level word and reading', (tester) async {
      await TestApp().start(tester);
      expect(find.text('Danger'), findsWidgets);
      expect(inAreaCard('19.97 m'), findsOneWidget);
      expect(find.text('Danger from 19.95 m'), findsOneWidget);
    });

    testWidgets('next arrow, previous arrow and dots change the area', (tester) async {
      final app = TestApp();
      await app.start(tester);
      await tapIt(tester, find.bySemanticsLabel('Next area'));
      expect(app.controller.areaIndex, 1);
      expect(inAreaCard('8.00 m'), findsOneWidget);
      await tapIt(tester, find.bySemanticsLabel('Previous area'));
      expect(app.controller.areaIndex, 0);
      await tapIt(tester, find.bySemanticsLabel(RegExp('3 of 3')));
      expect(app.controller.areaIndex, 2);
      expect(find.bySemanticsLabel('Next area'), findsNothing); // last area: no next arrow
    });

    testWidgets('swiping left shows the next area', (tester) async {
      final app = TestApp();
      await app.start(tester);
      await tester.fling(inAreaCard('19.97 m'), const Offset(-300, 0), 1000);
      await tester.pumpAndSettle();
      expect(app.controller.areaIndex, 1);
    });

    testWidgets('no saved areas: shows the station nearest the user, with Save', (tester) async {
      final app = TestApp(followed: const []);
      await app.start(tester);
      expect(find.text('Nearest to you · 1.2 km'), findsOneWidget); // the card (the alert banner also says it)
      expect(find.text(awat), findsWidgets);
      await tapIt(tester, find.byKey(const ValueKey('save-nearest')));
      expect(await app.followedStore.load(), ['JHR-AWAT']);
      expect(find.textContaining('Saved area'), findsOneWidget);
    });

    testWidgets('no saved areas and no location: invites the user to add one', (tester) async {
      await TestApp(followed: const [], location: LocationFix(SampleData.userLocation, issue: LocationIssue.denied)).start(tester);
      expect(find.text('No saved areas yet'), findsOneWidget);
      await tapIt(tester, find.text('Add an area'));
      expect(find.text('Saved areas'), findsOneWidget);
    });
  });

  group('TP50 Saved areas', () {
    testWidgets('Change area: tapping an area shows it on Home', (tester) async {
      final app = TestApp();
      await app.start(tester);
      await tapIt(tester, find.byKey(const ValueKey('change-area')));
      await tapIt(tester, find.text(buloh));
      expect(app.controller.areaIndex, 1);
      expect(inAreaCard('8.00 m'), findsOneWidget);
    });

    testWidgets('remove an area', (tester) async {
      final app = TestApp();
      await app.start(tester);
      await tapIt(tester, find.byKey(const ValueKey('change-area')));
      await tapIt(tester, find.byKey(const ValueKey('remove-SGR-KAJANG')));
      expect(await app.followedStore.load(), ['JHR-AWAT', 'JHR-BULOH']);
    });

    testWidgets('add an area by searching', (tester) async {
      final app = TestApp();
      await app.start(tester);
      await tapIt(tester, find.byKey(const ValueKey('change-area')));
      await tapIt(tester, find.byKey(const ValueKey('add-area')));
      await tester.enterText(find.byKey(const ValueKey('area-search')), 'segamat kecil');
      await tester.pumpAndSettle();
      expect(find.text('Sg. Lenik di Ladang Chaah'), findsNothing);
      await tapIt(tester, find.byKey(const ValueKey('add-JHR-SEGKECIL')));
      expect(await app.followedStore.load(), contains('JHR-SEGKECIL'));
    });

    testWidgets('Add is turned off at 5 saved areas', (tester) async {
      await TestApp(followed: const ['JHR-AWAT', 'JHR-BULOH', 'JHR-SEGKECIL', 'JHR-CHAAH', 'SGR-KAJANG']).start(tester);
      await tapIt(tester, find.byKey(const ValueKey('change-area')));
      await reveal(tester, find.text('Add an area'));
      final add = tester.widget<FilledButton>(find.ancestor(of: find.text('Add an area'), matching: find.byWidgetPredicate((w) => w is FilledButton)));
      expect(add.onPressed, isNull);
    });
  });

  group('TP51 Forecast and explanation', () {
    testWidgets('forecast card shows the summary, range and practice label', (tester) async {
      await TestApp().start(tester);
      await reveal(tester, find.text('Expected to stay at Danger level for the next 3 hours'));
      expect(find.text('Likely between 19.90 m and 20.18 m'), findsOneWidget);
      expect(find.text('Practice forecast'), findsOneWidget);
      expect(find.text('Not real predictions yet'), findsOneWidget);
    });

    testWidgets('"Why does the AI say this?" lists the readings with their direction', (tester) async {
      await TestApp().start(tester);
      await tapIt(tester, find.text('Why does the AI say this?').first);
      expect(find.text('42 mm of rain in the last 3 hours'), findsOneWidget);
      expect(find.text('Pushes the level up'), findsWidgets);
      await tapIt(tester, find.text('How the prediction works'));
      expect(find.text('1. Learns from the past'), findsOneWidget);
    });

    testWidgets('area with no forecast says so', (tester) async {
      await TestApp(followed: const ['SGR-RANTAU']).start(tester);
      expect(find.text('No recent data'), findsOneWidget); // area card at the top
      await reveal(tester, find.text('No forecast for this area right now'));
    });
  });

  group('TP52 Station detail', () {
    testWidgets('open from High risk now; save and copy', (tester) async {
      final app = TestApp(followed: const ['JHR-AWAT']);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await app.start(tester);
      await tapIt(tester, find.text(buloh));
      expect(find.text('35.0 mm/h'), findsOneWidget);

      await tapIt(tester, find.byKey(const ValueKey('follow')));
      expect(await app.followedStore.load(), contains('JHR-BULOH'));
      await waitForSnackBar(tester);

      await tapIt(tester, find.byKey(const ValueKey('share-status')));
      await tapIt(tester, find.byKey(const ValueKey('share-copy')));
      expect(copied, contains('Status: Alert (Waspada)'));
      await waitForSnackBar(tester);

      await tapIt(tester, find.byKey(const ValueKey('share-status')));
      await tapIt(tester, find.byKey(const ValueKey('share-whatsapp')));
      expect(app.opener.opened.last.toString(), startsWith('https://wa.me/?text='));
      expect(Uri.decodeComponent(app.opener.opened.last.toString()), contains('Sg. Muar di Buloh Kasap'));
    });
  });

  group('TP53 Prepare checklist', () {
    testWidgets('opens on the area\'s level with the household\'s items', (tester) async {
      await TestApp().start(tester);
      await openTab(tester, 'Prepare');
      // The safety cards come first at Danger, so scroll to the checklist.
      await reveal(tester, find.text('When river is at Danger'));
      expect(find.text('When river is at Danger'), findsOneWidget);
      // Danger: 2 tasks to tick; the 3 safety tips are cards, not counted.
      expect(find.text('0 of 2 done'), findsOneWidget);
      await reveal(tester, find.text('Help the older or less mobile person out first'));
      expect(find.text('Help the older or less mobile person out first'), findsOneWidget);
    });

    testWidgets('level buttons switch the list', (tester) async {
      await TestApp().start(tester);
      await openTab(tester, 'Prepare');
      await tapIt(tester, find.text('Alert').last);
      expect(find.text('When river is at Alert'), findsOneWidget);
      expect(find.text('0 of 7 done'), findsOneWidget);
      expect(find.text('Ask your driver now if they can take you'), findsOneWidget);
    });

    testWidgets('tick and untick are saved; Clear ticks asks first', (tester) async {
      final app = TestApp();
      await app.start(tester);
      await openTab(tester, 'Prepare');
      await tapIt(tester, find.byKey(const ValueKey('tick-danger.leave')));
      expect(find.text('1 of 2 done'), findsOneWidget);
      expect((await app.progressStore.load())['done'], 'danger.leave');

      await tapIt(tester, find.byKey(const ValueKey('reset-level')));
      expect(find.text('Clear all ticks?'), findsOneWidget);
      await tapIt(tester, find.text('Clear'));
      expect(find.text('0 of 2 done'), findsOneWidget);
    });

    testWidgets('Home checklist card shows the same progress', (tester) async {
      final app = TestApp();
      await app.controller.household.setDone('danger.leave', true);
      await app.start(tester);
      await reveal(tester, find.text('Your checklist · Danger'));
      expect(find.text('1 of 2 done · made for your household'), findsOneWidget);
      await tapIt(tester, find.text('Open checklist'));
      expect(app.controller.tab, AppTab.prepare);
    });
  });

  group('TP54 Step by step', () {
    testWidgets('starts at the first item not done; Mark as done moves on', (tester) async {
      final app = TestApp();
      await app.controller.household.setDone('danger.leave', true);
      await app.start(tester);
      await openTab(tester, 'Prepare');
      await tapIt(tester, find.byKey(const ValueKey('start-steps')));
      expect(find.text('Step 2 of 2'), findsOneWidget);
      await tapIt(tester, find.byKey(const ValueKey('step-done')));
      expect(find.text('Checklist summary'), findsOneWidget);
      expect(app.controller.done, containsAll(['danger.leave', 'danger.help']));
    });

    testWidgets('Skip and Back; finish page lists what is left', (tester) async {
      await TestApp().start(tester);
      await openTab(tester, 'Prepare');
      await tapIt(tester, find.byKey(const ValueKey('start-steps')));
      expect(find.text('Step 1 of 2'), findsOneWidget);
      await tapIt(tester, find.byKey(const ValueKey('step-next')));
      expect(find.text('Step 2 of 2'), findsOneWidget);
      await tapIt(tester, find.byKey(const ValueKey('step-back')));
      expect(find.text('Step 1 of 2'), findsOneWidget);
      for (var i = 0; i < 2; i++) {
        await tapIt(tester, find.byKey(const ValueKey('step-next')));
      }
      expect(find.text('Checklist summary'), findsOneWidget);
      expect(find.text('2 still to do'), findsOneWidget);
      await tapIt(tester, find.byKey(const ValueKey('steps-finish')));
      expect(find.text('When river is at Danger'), findsOneWidget);
    });

    testWidgets('tapping an item in the list opens its own step page', (tester) async {
      await TestApp().start(tester);
      await openTab(tester, 'Prepare');
      await tapIt(tester, find.text('Help the older or less mobile person out first'));
      expect(find.text('Step 2 of 2'), findsOneWidget);
    });
  });

  group('TP55 Household privacy on Prepare', () {
    testWidgets('locked: only the number of people; reasons hidden', (tester) async {
      await TestApp().start(tester);
      await openTab(tester, 'Prepare');
      expect(find.text('4 people'), findsOneWidget);
      expect(find.text('Details hidden for privacy'), findsOneWidget);
      expect(find.text('Because someone is 60 or older'), findsNothing);
    });

    testWidgets('Show > unlock with the phone > details and reasons appear', (tester) async {
      final app = TestApp();
      await app.lock.answerPermission(turnOn: true);
      await app.start(tester);
      await openTab(tester, 'Prepare');
      await tapIt(tester, find.byKey(const ValueKey('show-household')));
      expect(app.phone.prompts, 1);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Details hidden for privacy'), findsNothing);
      expect(find.text('Lift from family or neighbour'), findsOneWidget);
      await reveal(tester, find.text('Because someone is 60 or older'));
      expect(find.text('Because someone is 60 or older'), findsOneWidget);
    });

    testWidgets('lock turned off: details show without asking', (tester) async {
      final app = TestApp();
      await app.lock.turnOff(phone: PhoneLock.ready, identityConfirmed: true);
      await app.start(tester);
      await openTab(tester, 'Prepare');
      expect(find.text('Details hidden for privacy'), findsNothing);
      expect(app.phone.prompts, 0);
    });
  });

  group('TP56 Household form', () {
    testWidgets('people: minus stops at 1, plus at 30', (tester) async {
      await TestApp(profile: null).start(tester);
      final minus = find.byKey(const ValueKey('people-minus'));
      final plus = find.byKey(const ValueKey('people-plus'));
      expect(tester.widget<IconButton>(find.descendant(of: minus, matching: find.byType(IconButton))).onPressed, isNull);
      for (var i = 0; i < 29; i++) {
        await tester.tap(plus);
        await tester.pump();
      }
      expect(find.text('30'), findsOneWidget);
      expect(tester.widget<IconButton>(find.descendant(of: plus, matching: find.byType(IconButton))).onPressed, isNull);
    });

    testWidgets('choices change the checklist (pet adds pet items)', (tester) async {
      final app = TestApp(profile: null);
      await app.start(tester);
      await tapIt(tester, find.byKey(const ValueKey('pets-plus')));
      await tapIt(tester, find.text('No transport'));
      await tapIt(tester, find.byKey(const ValueKey('household-save')));
      final p = await app.controller.household.loadProfile();
      expect(p!.pet, isTrue);
      expect(p.transport, Transport.none);
      expect([for (final i in app.controller.checklist(RiskLevel.warning)) i.id], contains('warning.pet'));
    });
  });

  group('TP57 Centres', () {
    testWidgets('nearest open centre is selected; Directions opens Google Maps', (tester) async {
      final app = TestApp();
      await app.start(tester);
      await openTab(tester, 'Centres');
      expect(find.text('SK Buloh Kasap'), findsWidgets);
      await tapIt(tester, find.byKey(const ValueKey('centre-directions')));
      expect(app.opener.opened.single.toString(), contains('destination=2.556,102.77'));
    });

    testWidgets('choosing a centre in the list or on the map updates the card', (tester) async {
      await TestApp().start(tester);
      await openTab(tester, 'Centres');
      await tapIt(tester, find.text('Dewan Jementah'));
      expect(find.text('Opens only if the district calls for it'), findsOneWidget);
      // The map only builds pins inside its current view, and at test screen
      // size this one is outside it (a user would pan), so use the map's pin action.
      await reveal(tester, find.byType(AppMap));
      tester.widget<AppMap>(find.byType(AppMap)).onPinTap!('PPS-AWAT');
      await tester.pumpAndSettle();
      expect(find.text('No space left. Choose another centre.'), findsOneWidget);
    });

    testWidgets('Rain layer: nearest first within 10 km; Highest risk and 30 km change the list; River shows the forecast', (tester) async {
      await TestApp().start(tester);
      await openTab(tester, 'Centres');
      await tapIt(tester, find.text('Rain'));
      expect(find.text('Rain gauges · nearest first'), findsOneWidget);
      // List row (the map pin shows the same 35.0 mm/h).
      expect(find.textContaining('35.0 mm/h · '), findsOneWidget); // Buloh Kasap, about 5 km
      expect(find.textContaining('65.0 mm/h'), findsNothing, reason: 'Durian Tunggal is about 60 km away');
      await tapIt(tester, find.text('Highest risk'));
      expect(find.text('Rain gauges · heaviest first'), findsOneWidget);
      await tapIt(tester, find.byKey(const ValueKey('radius-30.0')));
      expect(find.textContaining('65.0 mm/h'), findsNothing);
      await tapIt(tester, find.text('River'));
      // Level now with the AI arrow, kept together on one line.
      expect(find.text('8.00\u00A0m\u00A0↑'), findsOneWidget);
      expect(find.textContaining(RegExp(r'% to Warning \(\d+\.\d\d m\)')), findsWidgets);
      expect(find.textContaining('Above the Danger line ('), findsWidgets); // Kg. Awat
      // At test screen size this pin sits outside the visible part of the map
      // (a user would pan to it), so call its tap action directly.
      tester.widget<GestureDetector>(find.byKey(const ValueKey('pin-JHR-AWAT'))).onTap!();
      await tester.pumpAndSettle();
      expect(find.text('River level'), findsOneWidget); // station page
    });
  });

  group('TP58 SOS', () {
    testWidgets('tap opens the sheet; Call 999 now dials 999', (tester) async {
      final app = TestApp();
      await app.start(tester);
      await tapIt(tester, find.byKey(const ValueKey('sos')).first);
      await tapIt(tester, find.byKey(const ValueKey('sos-call-now')));
      expect(app.opener.opened.first.toString(), 'tel:999');
      expect(find.text('Add emergency contact'), findsOneWidget);
    });

    testWidgets('holding for 2 seconds calls 999 without the sheet', (tester) async {
      final app = TestApp();
      await app.start(tester);
      final sos = find.byKey(const ValueKey('sos')).first;
      await tester.ensureVisible(sos);
      await tester.pumpAndSettle();
      final g = await tester.startGesture(tester.getCenter(sos));
      await tester.pump(const Duration(milliseconds: 600)); // long press recognised
      // Just over 2 seconds: the hold only counts as finished once it has run past 2 s.
      await tester.pump(const Duration(milliseconds: 2100)); // hold completes
      await g.up();
      await tester.pumpAndSettle();
      expect(app.opener.opened.first.toString(), 'tel:999');
    });

    testWidgets('releasing early does not call', (tester) async {
      final app = TestApp();
      await app.start(tester);
      final sos = find.byKey(const ValueKey('sos')).first;
      final g = await tester.startGesture(tester.getCenter(sos));
      await tester.pump(const Duration(milliseconds: 900));
      await g.up();
      await tester.pumpAndSettle();
      expect(app.opener.opened, isEmpty);
    });

    testWidgets('with a saved contact: Text my location sends an SMS with a map link', (tester) async {
      final app = TestApp();
      await app.contactStore.save({'phone': '0123456789'});
      await app.start(tester);
      await tapIt(tester, find.byKey(const ValueKey('sos')).first);
      await tapIt(tester, find.byKey(const ValueKey('sos-call-now')));
      await tapIt(tester, find.byKey(const ValueKey('sos-sms')));
      final sms = app.opener.opened.last.toString();
      expect(sms, startsWith('sms:0123456789?body='));
      expect(sms, contains('maps.google.com'));
    });

    testWidgets('phone app cannot open: tells the user to dial 999 themselves', (tester) async {
      final app = TestApp();
      app.opener.result = false;
      await app.start(tester);
      await tapIt(tester, find.byKey(const ValueKey('sos')).first);
      await tapIt(tester, find.byKey(const ValueKey('sos-call-now')));
      expect(find.text('Could not open the phone app. Dial 999 yourself.'), findsOneWidget);
      await tester.tapAt(const Offset(20, 20)); // close the sheet
      await waitForSnackBar(tester);
    });
  });

  group('TP59 More and settings', () {
    testWidgets('text size changes the text scale and is saved', (tester) async {
      final app = TestApp();
      await app.start(tester);
      await openTab(tester, 'More');
      await tapIt(tester, find.byKey(const ValueKey('size-large')));
      expect(app.controller.settings.textSize, TextSize.large);
      await reveal(tester, find.text('Easy to read'));
      final ctx = tester.element(find.text('Easy to read'));
      expect(MediaQuery.of(ctx).textScaler.scale(10), closeTo(13, 0.01));
      expect((await app.settingsStore.load())['textSize'], 'large');
    });

    testWidgets('high contrast switches to the white high-contrast theme', (tester) async {
      final app = TestApp();
      await app.start(tester);
      await openTab(tester, 'More');
      await tapIt(tester, find.byKey(const ValueKey('high-contrast')));
      expect(app.controller.settings.highContrast, isTrue);
      await reveal(tester, find.text('Easy to read'));
      final ctx = tester.element(find.text('Easy to read'));
      expect(Theme.of(ctx).scaffoldBackgroundColor, const Color(0xFFFFFFFF));
    });

    testWidgets('English by default; Bahasa Melayu and 中文 change the menu, checklist and AI text', (tester) async {
      final app = TestApp();
      await app.start(tester);
      expect(app.controller.settings.language, AppLanguage.en);
      await openTab(tester, 'More');
      await tapIt(tester, find.byKey(const ValueKey('lang-ms')));
      expect(find.byKey(const ValueKey('tab-Utama')), findsOneWidget);
      expect(app.controller.settings.language, AppLanguage.ms);

      await tapIt(tester, find.byKey(const ValueKey('lang-zh')));
      expect(find.byKey(const ValueKey('tab-首页')), findsOneWidget);
      await openTab(tester, '首页');
      await reveal(tester, find.text('预计未来 3 小时保持在“危险”级别'));
      await openTab(tester, '准备');
      expect(find.text('立即前往疏散中心'), findsWidgets);
    });

    testWidgets('Notify me from: choosing Danger is saved', (tester) async {
      final app = TestApp();
      await app.start(tester);
      await openTab(tester, 'More');
      await tapIt(tester, find.text('Notify me from'));
      await tapIt(tester, find.byKey(const ValueKey('notify-danger')));
      expect(app.controller.settings.notificationThreshold, RiskLevel.danger);
    });

    testWidgets('Emergency numbers: call buttons, and contact saved with checking', (tester) async {
      final app = TestApp();
      await app.start(tester);
      await openTab(tester, 'More');
      await tapIt(tester, find.text('Emergency numbers'));
      await tapIt(tester, find.byKey(const ValueKey('call-994')));
      expect(app.opener.opened.last.toString(), 'tel:994');

      await tester.enterText(find.byKey(const ValueKey('contact-field')), 'abc');
      await tapIt(tester, find.byKey(const ValueKey('contact-save')));
      expect(find.text('Enter a phone number with 7 to 15 digits.'), findsOneWidget);
      await waitForSnackBar(tester);

      await tester.enterText(find.byKey(const ValueKey('contact-field')), '012-345 6789');
      await tapIt(tester, find.byKey(const ValueKey('contact-save')));
      expect(app.controller.emergencyContact, '012-345 6789');
      await waitForSnackBar(tester);
    });

    testWidgets('every information page opens', (tester) async {
      await TestApp().start(tester);
      await openTab(tester, 'More');
      for (final (row, heading) in [
        ('How the prediction works', '1. Learns from the past'),
        ('Where the data comes from', 'River levels and rainfall'),
        ('About this app', 'Explainable AI-Based Flood Prediction System'),
        ('Saved areas', 'Add an area'),
      ]) {
        await tapIt(tester, find.text(row));
        expect(find.text(heading), findsOneWidget, reason: row);
        await tester.pageBack();
        await tester.pumpAndSettle();
      }
    });
  });

  group('TP57b Route inside the app', () {
    testWidgets('Show route: distance, time and numbered steps; Google Maps backup', (tester) async {
      final app = TestApp();
      await app.start(tester);
      await openTab(tester, 'Centres');
      await tapIt(tester, find.byKey(const ValueKey('centre-route')));
      expect(find.text('6.2 km · about 12 min by car'), findsOneWidget);
      await reveal(tester, find.text('Turn left onto Jalan Buloh Kasap'));
      expect(find.text('5.7 km'), findsOneWidget);
      await tapIt(tester, find.byKey(const ValueKey('route-google')));
      expect(app.opener.opened.last.toString(), contains('google.com/maps/dir'));
    });

    testWidgets('no internet: message, Try again works', (tester) async {
      final app = TestApp();
      app.routes.fail = true;
      await app.start(tester);
      await openTab(tester, 'Centres');
      await tapIt(tester, find.byKey(const ValueKey('centre-route')));
      expect(find.text('Could not get the road route. Check your internet.'), findsOneWidget);
      app.routes.fail = false;
      await tapIt(tester, find.byKey(const ValueKey('route-retry')));
      expect(find.text('6.2 km · about 12 min by car'), findsOneWidget);
    });

    testWidgets('no route key: says it is not set up and offers Google Maps', (tester) async {
      await TestApp(routesSetUp: false).start(tester);
      await openTab(tester, 'Prepare');
      await tapIt(tester, find.byKey(const ValueKey('wayout-directions')));
      expect(find.text('Road route inside the app is not set up yet.'), findsOneWidget);
      expect(find.byKey(const ValueKey('route-google')), findsOneWidget);
    });
  });

  group('TP61 Read aloud', () {
    testWidgets('speaker button reads the forecast, its reasons and the disclaimer', (tester) async {
      final app = TestApp();
      await app.start(tester);
      await tapIt(tester, find.byKey(const ValueKey('read-forecast-JHR-AWAT')));
      final said = app.speaker.spoken.single;
      expect(said.$1, contains('Expected to stay at Danger level for the next 3 hours'));
      expect(said.$1, contains('42 mm of rain in the last 3 hours'));
      expect(said.$2, AppLanguage.en);
    });

    testWidgets('Why page also has the button; slower speech is passed on', (tester) async {
      final app = TestApp();
      await app.start(tester);
      await openTab(tester, 'More');
      await tapIt(tester, find.byKey(const ValueKey('slow-speech-switch')));
      await openTab(tester, 'Home');
      await tapIt(tester, find.text('Why does the AI say this?').first);
      await tapIt(tester, find.byKey(const ValueKey('read-why-JHR-AWAT')));
      expect(app.speaker.spoken.single.$3, isTrue);
      expect((await app.voiceStore.load())['slow'], 'true');
    });

    testWidgets('turned off in More: no speaker buttons', (tester) async {
      final app = TestApp();
      await app.start(tester);
      await openTab(tester, 'More');
      await tapIt(tester, find.byKey(const ValueKey('read-aloud-switch')));
      await openTab(tester, 'Home');
      expect(find.byKey(const ValueKey('read-forecast-JHR-AWAT')), findsNothing);
      expect((await app.voiceStore.load())['readAloud'], 'false');
    });

    testWidgets('no voice for the language: tells the user how to add one', (tester) async {
      final app = TestApp();
      app.speaker.result = SpeakResult.noVoice;
      await app.start(tester);
      await tapIt(tester, find.byKey(const ValueKey('read-forecast-JHR-AWAT')));
      expect(find.textContaining('No voice for this language'), findsOneWidget);
      await waitForSnackBar(tester);
    });
  });

  group('TP62 Location', () {
    testWidgets('phone location used: no notice', (tester) async {
      final app = TestApp(location: LocationFix(GeoPoint(2.57, 102.80)));
      await app.start(tester);
      await openTab(tester, 'Centres');
      expect(find.byKey(const ValueKey('location-retry')), findsNothing);
      expect(app.controller.userLocation.lat, 2.57);
    });

    testWidgets('permission refused: sample point with notice; Use my location asks again', (tester) async {
      final app = TestApp(location: LocationFix(GeoPoint(2.566, 102.810), issue: LocationIssue.denied));
      await app.start(tester);
      await openTab(tester, 'Centres');
      expect(find.textContaining('Location permission was not given.'), findsOneWidget);
      expect(app.location.prompted, 0); // no pop-up until the button is pressed
      final before = app.location.asked;
      app.location.fix = LocationFix(GeoPoint(2.57, 102.80));
      await tapIt(tester, find.byKey(const ValueKey('location-retry')));
      expect(app.location.asked, greaterThan(before));
      expect(app.location.prompted, 1);
      expect(find.byKey(const ValueKey('location-retry')), findsNothing);
    });

    test('blocked by Android: stays blocked until allowed in settings', () async {
      // Android: the plain check says "denied" even when the pop-up is blocked.
      var check = LocationPermission.denied;
      var requests = 0;
      final p = DeviceLocationProvider(
        fallback: GeoPoint(2.566, 102.810),
        checkPermission: () async => check,
        requestPermission: () async {
          requests++;
          return LocationPermission.deniedForever;
        },
        serviceEnabled: () async => false,
      );
      expect((await p.current()).issue, LocationIssue.denied); // app start: no pop-up
      expect(requests, 0);
      expect((await p.current(ask: true)).issue, LocationIssue.deniedForever); // button
      expect((await p.current()).issue, LocationIssue.deniedForever); // app resumes
      expect((await p.current(ask: true)).issue, LocationIssue.deniedForever);
      expect(requests, 1); // not asked again while blocked
      check = LocationPermission.whileInUse; // allowed in settings
      expect((await p.current()).issue, LocationIssue.serviceOff); // past the permission step
      check = LocationPermission.denied;
      expect((await p.current()).issue, LocationIssue.denied); // block forgotten
    });

    testWidgets('blocked for the app: button opens the phone settings', (tester) async {
      final app = TestApp(location: LocationFix(GeoPoint(2.566, 102.810), issue: LocationIssue.deniedForever));
      await app.start(tester);
      await openTab(tester, 'Centres');
      await tapIt(tester, find.byKey(const ValueKey('location-retry')));
      expect(app.location.settingsOpened, 1);
    });
  });
}
