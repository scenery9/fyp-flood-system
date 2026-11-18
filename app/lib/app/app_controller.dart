import 'dart:async';

import 'package:flood_core/flood_core.dart';
// Table also exists in Flutter; this app uses flood_core's.
import 'package:material_ui/material_ui.dart' hide Table;

import '../security/phone_lock.dart';
import 'platform.dart';
import 'zh.dart';

/// Everything the app needs from outside. main.dart passes the real phone
/// versions; tests pass in-memory ones.
class AppDeps {
  AppDeps({
    required this.repository,
    required this.followedStore,
    required this.settingsStore,
    required this.profileStore,
    required this.progressStore,
    required this.contactStore,
    required this.centres,
    required this.forecastSource,
    required this.lock,
    required this.phone,
    required this.opener,
    required this.location,
    required this.speaker,
    required this.voiceStore,
    required this.routes,
    this.showMapTiles = true,
    this.push,
    this.pushTokens,
    HeightAlertStore? heights,
    this.liveData = false,
  }) : heights = heights ?? HeightAlertStore(InMemorySettingsStore());

  final StationRepository repository;
  final FollowedStore followedStore;
  final SettingsStore settingsStore;
  final SettingsStore profileStore;
  final SettingsStore progressStore;
  final SettingsStore contactStore;
  final Table<EvacuationPoint> centres;
  final ForecastSource forecastSource;
  final HouseholdLockService lock;
  final PhoneLockChecker phone;
  final UrlOpener opener;
  final LocationProvider location;
  final Speaker speaker;
  final SettingsStore voiceStore;

  /// Null when no openrouteservice key is set: routes then open in Google Maps.
  final RouteProvider? routes;

  /// False in tests so no map tiles are downloaded.
  final bool showMapTiles;

  /// Push alerts on the server. Null when Supabase is not set up.
  final PushAlertService? push;

  /// The phone's push token and permission. Null when Firebase is not set up.
  final PushTokens? pushTokens;

  /// River heights the user wants an alert at, kept on the phone.
  final HeightAlertStore heights;

  /// True when station data comes from the live JPS logger (Supabase),
  /// false for the built-in sample data.
  final bool liveData;
}

/// Where phone notifications stand, for the "Notify me from" page.
enum PushStatus {
  /// This build has no Supabase or Firebase settings.
  notSetUp,

  /// The phone has not been asked yet (Android 13+, iPhone).
  needsPermission,

  /// The user said no; only the phone's settings can change it.
  blocked,

  /// Registered: alerts arrive even when the app is closed.
  on,

  /// Could not reach the server; tried again on the next refresh.
  failed,
}

enum HeightError { invalid, limit }

enum FollowError { limit, unknown }

enum RouteError { notSetUp, failed }

class RouteOutcome {
  const RouteOutcome({this.plan, this.error});
  final RoutePlan? plan;
  final RouteError? error;
}

/// Tabs of the bottom menu.
enum AppTab { home, prepare, centres, more }

/// App state shared by every screen. Screens read it through [AppScope].
class AppController extends ChangeNotifier {
  AppController(this.deps)
      : monitoring = MonitoringService(repository: deps.repository),
        followed = FollowedAreasService(store: deps.followedStore, repository: deps.repository),
        evacuation = EvacuationService(points: deps.centres, newId: sequentialIds('pps')),
        settingsService = SettingsService(deps.settingsStore),
        household = HouseholdService(profileStore: deps.profileStore, progressStore: deps.progressStore),
        forecastService = ForecastService(source: deps.forecastSource) {
    home = HomeService(monitoring: monitoring, followed: followed);
  }

  final AppDeps deps;
  final MonitoringService monitoring;
  final FollowedAreasService followed;
  final EvacuationService evacuation;
  final SettingsService settingsService;
  final HouseholdService household;
  final ForecastService forecastService;
  late final HomeService home;
  final PreparednessService preparedness = const PreparednessService();

  // ---------- state ----------
  bool loading = true;
  String? loadError;
  AppSettings settings = const AppSettings();
  HomeData? homeData;
  List<StationStatus> statuses = const [];
  ForecastResult? forecast;
  List<NearbyEvacuation> centres = const [];
  HouseholdProfile? profile;
  bool setupSkipped = false;
  Set<String> done = {};
  bool householdVisible = false;
  String? emergencyContact;
  AppTab tab = AppTab.home;
  int areaIndex = 0;
  LocationFix? location;
  bool readAloud = true;
  bool slowSpeech = false;
  PushStatus pushStatus = PushStatus.notSetUp;

  /// River-height alerts by station id.
  Map<String, double> heights = const {};

  /// Id of the text being read aloud now (null when silent).
  String? speakingId;

  GeoPoint get userLocation => location!.point;
  LocationIssue? get locationIssue => location?.issue;
  AppLanguage get language => settings.language;

  /// True on first launch until the household form is saved or skipped.
  bool get needsSetup => !loading && profile == null && !setupSkipped;

  Future<void> init() async {
    _watchResume();
    loading = true;
    notifyListeners();
    try {
      settings = await settingsService.load();
      profile = await household.loadProfile();
      setupSkipped = await household.setupSkipped();
      done = await household.doneItems();
      emergencyContact = (await deps.contactStore.load())['phone'];
      final voice = await deps.voiceStore.load();
      readAloud = voice['readAloud'] != 'false';
      slowSpeech = voice['slow'] == 'true';
      heights = await deps.heights.load();
      location = await deps.location.current();
      await _loadData();
      await refreshHouseholdVisibility(notify: false);
      loadError = null;
    } catch (e) {
      loadError = 'Could not load data. Pull down to try again.';
    }
    loading = false;
    notifyListeners();
    unawaited(syncPush());
  }

  Future<void> refresh({bool askLocation = false}) async {
    try {
      location = await deps.location.current(ask: askLocation);
      await _loadData();
      loadError = null;
    } catch (_) {
      loadError = 'Could not load data. Pull down to try again.';
    }
    notifyListeners();
    if (pushStatus == PushStatus.failed) unawaited(syncPush());
  }

  Future<void> _loadData() async {
    homeData = await home.load(userLocation: userLocation);
    statuses = await monitoring.loadStatuses(userLocation: userLocation);
    forecast = await forecastService.load(statuses);
    centres = await evacuation.nearest(userLocation, limit: 20, includeUnavailable: true);
    final n = homeData!.areaCards.length;
    if (areaIndex >= n) areaIndex = n == 0 ? 0 : n - 1;
  }

  // ---------- navigation ----------
  void selectTab(AppTab t) {
    if (tab == t) return;
    tab = t;
    notifyListeners();
  }

  void selectArea(int i) {
    final n = homeData?.areaCards.length ?? 0;
    if (n == 0) return;
    final next = i.clamp(0, n - 1);
    if (next == areaIndex) return;
    areaIndex = next;
    notifyListeners();
  }

  // ---------- areas ----------
  List<StationStatus> get areas => homeData?.areaCards ?? const [];
  StationStatus? get currentArea => areas.isEmpty ? null : areas[areaIndex];

  /// Level used for the checklist: the area's level, or Alert when the
  /// level is unknown or old (stay on the safe side, like GuidanceService).
  RiskLevel get checklistLevel {
    final a = currentArea;
    if (a == null) return RiskLevel.normal;
    return a.isActionable ? a.level! : RiskLevel.alert;
  }

  StationForecast? forecastFor(String stationId) => forecast?.forecasts[stationId];

  StationStatus? statusOf(String stationId) {
    for (final s in statuses) {
      if (s.station.id == stationId) return s;
    }
    return null;
  }

  Future<bool> isFollowed(String id) => followed.isFollowed(id);

  /// Returns null when it worked.
  Future<FollowError?> follow(String id) async {
    try {
      await followed.follow(id);
    } on FollowLimitReachedException {
      return FollowError.limit;
    } on UnknownStationException {
      return FollowError.unknown;
    }
    await refresh();
    unawaited(syncPush());
    return null;
  }

  Future<void> unfollow(String id) async {
    await followed.unfollow(id);
    await refresh();
    unawaited(syncPush());
  }

  // ---------- settings ----------
  Future<void> updateSettings(AppSettings s) async {
    final before = settings;
    settings = await settingsService.save(s);
    notifyListeners();
    if (before.notificationThreshold != settings.notificationThreshold || before.language != settings.language) {
      unawaited(syncPush());
    }
  }

  // ---------- push alerts ----------
  Future<void> _pushQueue = Future.value();

  /// Sends this phone's alert rules to the server: every saved area at the
  /// "Notify me from" level, plus the river heights. [ask] shows the phone's
  /// permission prompt (only when the user taps the button). Runs one at a
  /// time; failures only change [pushStatus].
  Future<void> syncPush({bool ask = false}) =>
      _pushQueue = _pushQueue.then((_) => _syncPush(ask)).catchError((Object _) {});

  Future<void> _syncPush(bool ask) async {
    final service = deps.push, tokens = deps.pushTokens;
    if (service == null || tokens == null) {
      _setPush(PushStatus.notSetUp);
      return;
    }
    try {
      var p = await tokens.permission();
      if (p != PushPermission.granted && ask) p = await tokens.ask();
      if (p != PushPermission.granted) {
        _setPush(p == PushPermission.denied ? PushStatus.blocked : PushStatus.needsPermission);
        return;
      }
      final token = await tokens.token();
      if (token == null) {
        _setPush(PushStatus.failed);
        return;
      }
      await service.register(token: token, platform: tokens.platform, language: language);
      await service.syncRules(pushRulesFor(
          followedStationIds: await followed.list(),
          threshold: settings.notificationThreshold,
          heights: heights));
      _setPush(PushStatus.on);
    } catch (_) {
      _setPush(PushStatus.failed);
    }
  }

  void _setPush(PushStatus s) {
    if (pushStatus == s) return;
    pushStatus = s;
    notifyListeners();
  }

  /// "Alert me when the river reaches ... m" for one station.
  Future<HeightError?> setHeightAlert(String stationId, double levelM) async {
    try {
      heights = await deps.heights.set(stationId, levelM);
    } on ValidationException {
      return HeightError.invalid;
    } on ConflictException {
      return HeightError.limit;
    }
    notifyListeners();
    unawaited(syncPush());
    return null;
  }

  Future<void> removeHeightAlert(String stationId) async {
    heights = await deps.heights.remove(stationId);
    notifyListeners();
    unawaited(syncPush());
  }

  Future<void> setEmergencyContact(String? phone) async {
    final v = phone?.trim();
    emergencyContact = (v == null || v.isEmpty) ? null : v;
    await deps.contactStore.save(emergencyContact == null ? {} : {'phone': emergencyContact!});
    notifyListeners();
  }

  // ---------- household ----------
  Future<void> saveProfile(HouseholdProfile p) async {
    profile = await household.saveProfile(p);
    setupSkipped = false;
    notifyListeners();
  }

  Future<void> skipSetup() async {
    await household.skipSetup();
    setupSkipped = await household.setupSkipped();
    notifyListeners();
  }

  List<PrepItem> checklist(RiskLevel level) => preparedness.checklist(level, profile, language: language);

  Future<void> setDone(String id, bool value) async {
    done = await household.setDone(id, value);
    notifyListeners();
  }

  Future<void> resetLevel(RiskLevel level) async {
    done = await household.resetLevel(level);
    notifyListeners();
  }

  /// Household details are shown on Prepare only when the lock allows it
  /// without asking (lock off, or already unlocked this session).
  Future<void> refreshHouseholdVisibility({bool notify = true}) async {
    try {
      householdVisible = await deps.lock.nextStep(await deps.phone.status()) == LockStep.open;
    } catch (_) {
      householdVisible = false;
    }
    if (notify) notifyListeners();
  }

  /// Nearest centre that is open and has space.
  NearbyEvacuation? get nearestAvailable {
    for (final c in centres) {
      if (c.point.isAvailable) return c;
    }
    return null;
  }

  Uri directionsTo(EvacuationPoint p) => Uri.parse(evacuation.directionsUrl(p.location, from: userLocation));

  /// Road route from the user to [p] with turn-by-turn steps.
  Future<RouteOutcome> routeTo(EvacuationPoint p) async {
    final provider = deps.routes;
    if (provider == null) return const RouteOutcome(error: RouteError.notSetUp);
    final key = _routeKey(p);
    final known = _routes[key];
    if (known != null) return RouteOutcome(plan: known);
    try {
      final plan = await provider.route(userLocation, p.location);
      _routes[key] = plan;
      return RouteOutcome(plan: plan);
    } catch (_) {
      return const RouteOutcome(error: RouteError.failed);
    }
  }

  // ---------- location ----------
  /// The only place the permission pop-up is shown (Centres button).
  Future<void> retryLocation() => refresh(askLocation: true);

  /// Asks again when the user comes back from the phone's settings.
  AppLifecycleListener? _life;
  void _watchResume() {
    _life ??= AppLifecycleListener(onResume: () {
      if (locationIssue != null) refresh();
    });
  }

  @override
  void dispose() {
    _life?.dispose();
    super.dispose();
  }

  // ---------- road routes ----------
  /// Road routes already found, so the map and the route page do not ask
  /// openrouteservice twice for the same trip. Failures are not kept.
  final Map<String, RoutePlan> _routes = {};
  String _routeKey(EvacuationPoint p) =>
      '${p.id}@${userLocation.lat.toStringAsFixed(3)},${userLocation.lon.toStringAsFixed(3)}';

  /// The road route if it was already found, else null.
  RoutePlan? knownRoute(EvacuationPoint p) => _routes[_routeKey(p)];

  // ---------- read aloud ----------
  Future<void> _saveVoice() =>
      deps.voiceStore.save({'readAloud': '$readAloud', 'slow': '$slowSpeech'});

  Future<void> setReadAloud(bool on) async {
    readAloud = on;
    if (!on) await stopSpeaking();
    await _saveVoice();
    notifyListeners();
  }

  Future<void> setSlowSpeech(bool on) async {
    slowSpeech = on;
    await _saveVoice();
    notifyListeners();
  }

  /// Reads [text] aloud. Pressing again for the same [id] stops it.
  Future<SpeakResult> speak(String id, String text) async {
    if (speakingId == id) {
      await stopSpeaking();
      return SpeakResult.stopped;
    }
    if (speakingId != null) await deps.speaker.stop();
    speakingId = id;
    notifyListeners();
    final r = await deps.speaker.speak(text, language, slow: slowSpeech);
    if (speakingId == id) {
      speakingId = null;
      notifyListeners();
    }
    return r;
  }

  Future<void> stopSpeaking() async {
    await deps.speaker.stop();
    speakingId = null;
    notifyListeners();
  }
}

/// Gives every screen access to the [AppController] and rebuilds them when it changes.
class AppScope extends InheritedNotifier<AppController> {
  const AppScope({super.key, required AppController controller, required super.child})
      : super(notifier: controller);

  static AppController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// Read without rebuilding (for button handlers).
  static AppController read(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

/// App text in the chosen language. English is the default. Chinese comes
/// from [zh] when given, else from the zhText table, else English.
extension Tr on BuildContext {
  String tr(String en, String ms, [String? zh]) => switch (AppScope.of(this).language) {
        AppLanguage.en => en,
        AppLanguage.ms => ms,
        AppLanguage.zh => zh ?? zhText[en] ?? en,
      };

  String levelName(RiskLevel? l) {
    if (l == null) return tr('Unknown', 'Tidak diketahui');
    return switch (AppScope.of(this).language) {
      AppLanguage.en => l.labelEn,
      AppLanguage.ms => l.labelBm,
      AppLanguage.zh => const {
          RiskLevel.normal: '正常',
          RiskLevel.alert: '警戒',
          RiskLevel.warning: '警告',
          RiskLevel.danger: '危险',
        }[l]!,
    };
  }
}
