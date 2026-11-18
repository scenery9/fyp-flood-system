import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';

void main() {
  group('TP41 Household details lock', () {
    test('first visit on a phone with a screen lock asks permission', () async {
      final lock = HouseholdLockService(InMemorySettingsStore());
      expect(await lock.nextStep(PhoneLock.ready), LockStep.askPermission);
    });

    test('after agreeing: phone prompt, then open until the app closes', () async {
      final lock = HouseholdLockService(InMemorySettingsStore());
      await lock.answerPermission(turnOn: true);
      expect(await lock.nextStep(PhoneLock.ready), LockStep.checkIdentity);
      lock.identityChecked(success: true);
      expect(await lock.nextStep(PhoneLock.ready), LockStep.open);
      expect(await lock.nextStep(PhoneLock.ready), LockStep.open);
    });

    test('a failed or cancelled check keeps the details locked', () async {
      final lock = HouseholdLockService(InMemorySettingsStore());
      await lock.answerPermission(turnOn: true);
      lock.identityChecked(success: false);
      expect(lock.unlockedThisSession, isFalse);
      expect(await lock.nextStep(PhoneLock.ready), LockStep.checkIdentity);
    });

    test('after a restart: checked again, but permission is never asked again', () async {
      final store = InMemorySettingsStore();
      final first = HouseholdLockService(store);
      await first.answerPermission(turnOn: true);
      first.identityChecked(success: true);
      final afterRestart = HouseholdLockService(store);
      expect(await afterRestart.nextStep(PhoneLock.ready), LockStep.checkIdentity);
    });

    test('said no without ticking the box: asked again next time', () async {
      final store = InMemorySettingsStore();
      final lock = HouseholdLockService(store);
      await lock.answerPermission(turnOn: false);
      expect(await lock.nextStep(PhoneLock.ready), LockStep.askPermission);
      expect(await HouseholdLockService(store).nextStep(PhoneLock.ready), LockStep.askPermission);
    });

    test('said no and ticked "Don\'t ask me again": opens and never asks', () async {
      final store = InMemorySettingsStore();
      final lock = HouseholdLockService(store);
      await lock.answerPermission(turnOn: false, dontAskAgain: true);
      expect(await lock.nextStep(PhoneLock.ready), LockStep.open);
      expect(await HouseholdLockService(store).nextStep(PhoneLock.ready), LockStep.open);
    });

    test('lock on but no phone screen lock: set-up message; skip opens this time only', () async {
      final store = InMemorySettingsStore();
      final lock = HouseholdLockService(store);
      await lock.answerPermission(turnOn: true);
      expect(await lock.nextStep(PhoneLock.notSetUp), LockStep.setUpPhoneLock);
      lock.skipPhoneLockSetup();
      expect(await lock.nextStep(PhoneLock.notSetUp), LockStep.open);
      expect(await HouseholdLockService(store).nextStep(PhoneLock.notSetUp), LockStep.setUpPhoneLock);
    });

    test('once a phone lock is set up, the normal prompt is used', () async {
      final lock = HouseholdLockService(InMemorySettingsStore());
      await lock.answerPermission(turnOn: true);
      expect(await lock.nextStep(PhoneLock.notSetUp), LockStep.setUpPhoneLock);
      expect(await lock.nextStep(PhoneLock.ready), LockStep.checkIdentity);
    });

    test('device that cannot check (e.g. web preview): opens without asking', () async {
      final lock = HouseholdLockService(InMemorySettingsStore());
      expect(await lock.nextStep(PhoneLock.unsupported), LockStep.open);
      await lock.answerPermission(turnOn: true);
      expect(await lock.nextStep(PhoneLock.unsupported), LockStep.open);
    });

    test('damaged saved values count as "not asked yet"', () async {
      final lock = HouseholdLockService(
          InMemorySettingsStore({'householdLock': 'maybe', 'householdLockDontAsk': 'yes'}));
      expect(await lock.nextStep(PhoneLock.ready), LockStep.askPermission);
      expect(await lock.isOn(), isFalse);
    });
  });

  group('TP42 Household lock Settings switch', () {
    test('switch is off before the user agrees, on after', () async {
      final lock = HouseholdLockService(InMemorySettingsStore());
      expect(await lock.isOn(), isFalse);
      await lock.answerPermission(turnOn: true);
      expect(await lock.isOn(), isTrue);
    });

    test('turning on in Settings after saying no (even with the box ticked)', () async {
      final lock = HouseholdLockService(InMemorySettingsStore());
      await lock.answerPermission(turnOn: false, dontAskAgain: true);
      await lock.turnOn();
      expect(await lock.isOn(), isTrue);
      expect(await lock.nextStep(PhoneLock.ready), LockStep.checkIdentity);
    });

    test('turning on locks straight away, even if unlocked earlier', () async {
      final lock = HouseholdLockService(InMemorySettingsStore());
      await lock.answerPermission(turnOn: true);
      lock.identityChecked(success: true);
      await lock.turnOff(phone: PhoneLock.ready, identityConfirmed: true);
      await lock.turnOn();
      expect(await lock.nextStep(PhoneLock.ready), LockStep.checkIdentity);
    });

    test('turning off needs a fingerprint / PIN check first', () async {
      final lock = HouseholdLockService(InMemorySettingsStore());
      await lock.answerPermission(turnOn: true);
      await expectLater(lock.turnOff(phone: PhoneLock.ready, identityConfirmed: false),
          throwsA(isA<ValidationException>()));
      expect(await lock.isOn(), isTrue);
      await lock.turnOff(phone: PhoneLock.ready, identityConfirmed: true);
      expect(await lock.isOn(), isFalse);
    });

    test('turned off in Settings: opens and is never asked again', () async {
      final store = InMemorySettingsStore();
      final lock = HouseholdLockService(store);
      await lock.answerPermission(turnOn: true);
      await lock.turnOff(phone: PhoneLock.ready, identityConfirmed: true);
      expect(await lock.nextStep(PhoneLock.ready), LockStep.open);
      expect(await HouseholdLockService(store).nextStep(PhoneLock.ready), LockStep.open);
    });

    test('can be turned off without a check when the phone cannot do one', () async {
      for (final phone in [PhoneLock.notSetUp, PhoneLock.unsupported]) {
        final lock = HouseholdLockService(InMemorySettingsStore());
        await lock.answerPermission(turnOn: true);
        await lock.turnOff(phone: phone, identityConfirmed: false);
        expect(await lock.isOn(), isFalse);
      }
    });
  });
}
