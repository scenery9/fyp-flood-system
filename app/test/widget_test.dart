// TP43 Household lock screens (runs without a real phone).
// Reached the way users reach it: More > Household and transport.
import 'package:flood_core/flood_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers.dart';

const details = 'Aged 60 or older';

Future<void> openHousehold(WidgetTester tester) async {
  await openTab(tester, 'More');
  await tapIt(tester, find.text('Household and transport'));
}

Future<void> goBack(WidgetTester tester) async {
  await tester.pageBack();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('first visit asks; "Not now" shows the details', (tester) async {
    final app = TestApp();
    await app.start(tester);
    await openHousehold(tester);
    expect(find.text('Lock your household details?'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(find.text(details), findsOneWidget);
    expect(app.phone.prompts, 0);
  });

  testWidgets('"Turn on" shows the phone prompt, then the details; no second prompt', (tester) async {
    final app = TestApp();
    await app.start(tester);
    await openHousehold(tester);
    await tester.tap(find.text('Turn on'));
    await tester.pumpAndSettle();
    expect(find.text(details), findsOneWidget);
    expect(app.phone.prompts, 1);

    await goBack(tester);
    await tapIt(tester, find.text('Household and transport'));
    expect(find.text(details), findsOneWidget);
    expect(app.phone.prompts, 1);
  });

  testWidgets('failed prompt keeps it locked; Unlock tries again', (tester) async {
    final app = TestApp(phone: FakePhoneLock(pass: false));
    await app.lock.answerPermission(turnOn: true);
    await app.start(tester);
    await openHousehold(tester);
    expect(find.text('Household details are locked'), findsOneWidget);
    expect(find.text(details), findsNothing);

    app.phone.pass = true;
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    expect(find.text(details), findsOneWidget);
  });

  testWidgets('"Don\'t ask me again" ticked: never asked again', (tester) async {
    final store = InMemorySettingsStore();
    final app = TestApp(lock: HouseholdLockService(store));
    await app.start(tester);
    await openHousehold(tester);
    await tester.tap(find.text("Don't ask me again"));
    await tester.pump();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    final again = TestApp(lock: HouseholdLockService(store)); // app restarted
    await again.start(tester);
    await openHousehold(tester);
    expect(find.text(details), findsOneWidget);
  });

  testWidgets('no phone screen lock: set-up message, "Skip for now" opens', (tester) async {
    final app = TestApp(phone: FakePhoneLock(state: PhoneLock.notSetUp));
    await app.lock.answerPermission(turnOn: true);
    await app.start(tester);
    await openHousehold(tester);
    expect(find.text('Set up a phone lock first'), findsOneWidget);
    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();
    expect(find.text(details), findsOneWidget);
  });

  testWidgets('Settings switch: turning off needs the phone prompt', (tester) async {
    final app = TestApp(phone: FakePhoneLock(pass: false));
    await app.lock.answerPermission(turnOn: true);
    await app.start(tester);
    await openTab(tester, 'More');
    final lockSwitch = find.byKey(const ValueKey('lock-switch'));

    await tapIt(tester, lockSwitch);
    expect(await app.lock.isOn(), isTrue);
    expect(find.text('Confirm with your fingerprint or PIN to turn the lock off'), findsOneWidget);
    await waitForSnackBar(tester);

    app.phone.pass = true;
    await tapIt(tester, lockSwitch);
    expect(await app.lock.isOn(), isFalse);

    await tapIt(tester, lockSwitch);
    expect(await app.lock.isOn(), isTrue);
  });
}
