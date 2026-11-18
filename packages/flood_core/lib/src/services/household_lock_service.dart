import '../errors.dart';
import 'settings_service.dart';

/// Whether this phone can show its own fingerprint / PIN prompt.
enum PhoneLock {
  /// A fingerprint, face, PIN, pattern or password is set up on the phone.
  ready,

  /// The phone could do it, but no screen lock is set up yet.
  notSetUp,

  /// This device cannot do it at all (e.g. the web preview).
  unsupported,
}

/// What the household details screen should do next.
enum LockStep {
  /// Show the household details.
  open,

  /// Ask "Lock your household details?" with a "Don't ask me again" box.
  askPermission,

  /// Show the phone's own prompt (fingerprint, or the phone's PIN instead).
  checkIdentity,

  /// The lock is on but the phone has no screen lock: explain how to set
  /// one up, with a "Skip for now" choice.
  setUpPhoneLock,
}

enum _Choice { notAsked, on, declined, off }

/// Rules for the fingerprint / PIN lock on the public user's household details.
///
/// - First visit: ask permission. "Don't ask me again" stops further asking.
/// - Said no without ticking the box: asked again the next time.
/// - Once agreed: never asked again; the phone's prompt is shown instead.
/// - One successful check unlocks the details until the app is closed
///   (a new service is created each time the app starts).
/// - The Settings switch turns the lock on or off. Turning it off needs a
///   fingerprint / PIN check first when the phone can do one.
///
/// Give this service its own [SettingsStore], separate from [SettingsService],
/// because a store's save replaces everything in it.
class HouseholdLockService {
  HouseholdLockService(this.store);
  final SettingsStore store;

  static const _choiceKey = 'householdLock';
  static const _dontAskKey = 'householdLockDontAsk';

  bool _unlockedThisSession = false;

  /// True after a successful check (or "Skip for now") until the app closes.
  bool get unlockedThisSession => _unlockedThisSession;

  Future<_Choice> _choice() async {
    final saved = (await store.load())[_choiceKey];
    for (final c in _Choice.values) {
      if (c.name == saved) return c;
    }
    return _Choice.notAsked;
  }

  Future<bool> _dontAsk() async => (await store.load())[_dontAskKey] == 'true';

  Future<void> _save(_Choice choice, {bool dontAsk = false}) =>
      store.save({_choiceKey: choice.name, if (dontAsk) _dontAskKey: 'true'});

  /// Call each time the household details screen is opened.
  Future<LockStep> nextStep(PhoneLock phone) async {
    if (_unlockedThisSession) return LockStep.open;
    final choice = await _choice();
    final dontAsk = await _dontAsk();
    final canAsk = phone != PhoneLock.unsupported;
    return switch (choice) {
      _Choice.off => LockStep.open,
      _Choice.notAsked => canAsk ? LockStep.askPermission : LockStep.open,
      _Choice.declined => (canAsk && !dontAsk) ? LockStep.askPermission : LockStep.open,
      _Choice.on => switch (phone) {
          PhoneLock.ready => LockStep.checkIdentity,
          PhoneLock.notSetUp => LockStep.setUpPhoneLock,
          PhoneLock.unsupported => LockStep.open,
        },
    };
  }

  /// The user's answer to the first-time question.
  Future<void> answerPermission({required bool turnOn, bool dontAskAgain = false}) async {
    if (turnOn) {
      _unlockedThisSession = false;
      await _save(_Choice.on);
    } else {
      await _save(_Choice.declined, dontAsk: dontAskAgain);
    }
  }

  /// The result of the phone's fingerprint / PIN prompt.
  void identityChecked({required bool success}) {
    if (success) _unlockedThisSession = true;
  }

  /// "Skip for now" on the set-up-a-phone-lock message: opens the details
  /// this time only. The message comes back after the app is restarted.
  void skipPhoneLockSetup() => _unlockedThisSession = true;

  /// For the Settings switch.
  Future<bool> isOn() async => await _choice() == _Choice.on;

  /// Settings switch turned on. The details lock again straight away.
  Future<void> turnOn() async {
    _unlockedThisSession = false;
    await _save(_Choice.on);
  }

  /// Settings switch turned off. When the lock is on and the phone can check,
  /// [identityConfirmed] must be true (the user just passed the phone's prompt).
  Future<void> turnOff({required PhoneLock phone, required bool identityConfirmed}) async {
    if (await _choice() == _Choice.on && phone == PhoneLock.ready && !identityConfirmed) {
      throw ValidationException('Confirm with your fingerprint or PIN to turn the lock off');
    }
    await _save(_Choice.off);
  }
}
