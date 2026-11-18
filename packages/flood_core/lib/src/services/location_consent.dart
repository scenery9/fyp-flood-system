import 'settings_service.dart';

/// What the app does about location when it opens.
enum LocationStart {
  /// Allowed on the phone and wanted: use GPS, ask nothing.
  useGps,

  /// The user agreed in FloodReady before, but the phone no longer allows it
  /// (Android "Only this time" ended, or it was turned off in settings):
  /// show only the phone's own pop-up, not FloodReady's explanation again.
  askPhone,

  /// Never decided: show FloodReady's short explanation first, then the
  /// phone's pop-up if they tap Allow.
  explainFirst,

  /// Do not ask and do not use GPS (turned off in More, "Don't ask again",
  /// or blocked on the phone). Saved areas still work.
  dontUse,
}

/// The user's location choices, kept on the phone.
class LocationChoice {
  const LocationChoice({this.automatic, this.dontAsk = false, this.blocked = false});

  /// True: use location every time the app opens. False: switched off in
  /// More. Null: not decided yet.
  final bool? automatic;

  /// "Don't ask me again" was ticked on the explanation screen.
  final bool dontAsk;

  /// The phone refused for good ("Don't allow" twice on Android). Android's
  /// plain check cannot tell this apart from "not asked yet", so it is
  /// remembered here until location is allowed again.
  final bool blocked;
}

/// When to ask for location, and remembering the answers, the way most
/// apps do it: explain once, ask the phone only after the user agrees, never
/// nag after "Don't ask again", and let the user change it in settings.
class LocationConsentService {
  LocationConsentService(this.store);

  /// Shared with other one-off flags, so every save keeps the other keys.
  final SettingsStore store;

  static const _auto = 'locAuto', _dontAsk = 'locDontAsk', _blocked = 'locBlocked';

  Future<LocationChoice> load() async {
    final m = await store.load();
    final a = m[_auto];
    return LocationChoice(
        automatic: a == 'true' ? true : (a == 'false' ? false : null),
        dontAsk: m[_dontAsk] == 'true',
        blocked: m[_blocked] == 'true');
  }

  Future<void> _put(Map<String, String?> changes) async {
    final m = await store.load();
    for (final e in changes.entries) {
      if (e.value == null) {
        m.remove(e.key);
      } else {
        m[e.key] = e.value!;
      }
    }
    await store.save(m);
  }

  /// What to do when the app opens. [allowed] is whether the phone already
  /// allows location for this app (checked without showing a pop-up).
  static LocationStart atLaunch(LocationChoice c, {required bool allowed}) {
    if (c.automatic == false) return LocationStart.dontUse;
    if (allowed) return LocationStart.useGps;
    if (c.automatic == true) return LocationStart.askPhone;
    if (c.blocked || c.dontAsk) return LocationStart.dontUse;
    return LocationStart.explainFirst;
  }

  /// After the phone was checked or asked. Allowed (including "Only this
  /// time") means the user wants location: use it automatically from now on.
  Future<void> phoneAnswered({required bool allowed, required bool blocked}) async {
    if (allowed) {
      await _put({_auto: 'true', _dontAsk: null, _blocked: null});
    } else if (blocked) {
      await _put({_blocked: 'true'});
    }
  }

  /// "Not now" on the explanation screen. Without "Don't ask me again" the
  /// screen comes back next time the app opens.
  Future<void> notNow({required bool dontAskAgain}) async {
    if (dontAskAgain) await _put({_dontAsk: 'true'});
  }

  /// The "Use my location automatically" switch in More (and the "Use my
  /// location" buttons). Off: GPS is not used and nothing is asked.
  Future<void> setAutomatic(bool on) =>
      _put(on ? {_auto: 'true', _dontAsk: null} : {_auto: 'false'});
}
