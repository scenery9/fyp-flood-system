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
    SettingsStore? flagsStore,
    SettingsStore? routeStore,
    SettingsStore? reportsStore,
    this.reports,
    this.contacts,
    this.refreshEvery,
  })  : heights = heights ?? HeightAlertStore(InMemorySettingsStore()),
        flagsStore = flagsStore ?? InMemorySettingsStore(),
        routeStore = routeStore ?? InMemorySettingsStore(),
        reportsStore = reportsStore ?? InMemorySettingsStore();

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

  /// One-off things the app remembers (e.g. that it asked about notifications).
  final SettingsStore flagsStore;

  /// Road routes kept on the phone for use without internet.
  final SettingsStore routeStore;

  /// Reports and headcount kept on the phone when [reports] is null.
  final SettingsStore reportsStore;

  /// Where flood reports and headcounts go (Supabase). Null: kept on the
  /// phone only, and the app says staff will not see them.
  final PublicReportsBackend? reports;

  /// The phone's contact picker. Null when not available (tests, web).
  final ContactPicker? contacts;

  /// Reload station data this often while the app is open. Null in tests,
  /// so no timer is left running.
  final Duration? refreshEvery;
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

enum RouteError {
  notSetUp,
  failed,

  /// The centre's position has not been checked yet, so no route is given.
  unchecked,

  /// The centre is over [maxRouteKm] away in a straight line; the route
  /// server refuses those (supabase/functions/_shared/route.ts).
  tooFar,
}

/// Same limit as the route server. Further centres get no in-app route.
const maxRouteKm = 150.0;

class RouteOutcome {
  const RouteOutcome({this.plan, this.error, this.savedAt, this.fromSaved = false});
  final RoutePlan? plan;
  final RouteError? error;

  /// When [plan] was fetched.
  final DateTime? savedAt;

  /// True when the live route failed and [plan] is the copy kept on the
  /// phone ([error] then says why the live one failed).
  final bool fromSaved;
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
        forecastService = ForecastService(source: deps.forecastSource),
        routeCache = RouteCache(deps.routeStore),
        locationConsent = LocationConsentService(deps.flagsStore) {
    home = HomeService(monitoring: monitoring, followed: followed);
    reports = PublicReportsService(deps.reports ??
        LocalReportsBackend(deps.reportsStore, centreName: (id) {
          for (final c in centres) {
            if (c.point.id == id) return c.point.name;
          }
          return null;
        }));
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
  final RouteCache routeCache;
  late final PublicReportsService reports;
  final LocationConsentService locationConsent;

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

  /// The river station nearest the user (only from the phone's real location).
  StationStatus? nearest;

  /// The user's location choices (automatic, "don't ask again", blocked).
  LocationChoice locationChoice = const LocationChoice();

  /// Show FloodReady's "Use your location?" screen (first launches only).
  bool askLocationNow = false;

  /// This phone's "We're coming" headcount, if one was sent.
  MyHeadcount? headcount;

  /// Road routes kept on the phone, by centre id.
  final Map<String, SavedRoute> savedRoutes = {};
  DateTime? _lastRefresh;
  Timer? _timer;

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
      await _locate(launch: true);
      await _loadData();
      await refreshHouseholdVisibility(notify: false);
      loadError = null;
    } catch (e) {
      loadError = 'Could not load data. Pull down to try again.';
    }
    loading = false;
    notifyListeners();
    unawaited(_loadHeadcount());
    // Alerts are on by default: the first time the app opens it asks for
    // notification permission once (the "Notify me from" page can ask again).
    final flags = await deps.flagsStore.load();
    final askNow = flags['pushAsked'] != 'true' && deps.push != null && deps.pushTokens != null;
    if (askNow) await deps.flagsStore.save({...flags, 'pushAsked': 'true'});
    unawaited(syncPush(ask: askNow));
    _prefetchRoute();
    final every = deps.refreshEvery;
    if (every != null) _timer ??= Timer.periodic(every, (_) => refresh());
  }

  Future<void> refresh({bool askLocation = false}) async {
    _lastRefresh = DateTime.now();
    try {
      await _locate(ask: askLocation);
      await _loadData();
      loadError = null;
    } catch (_) {
      loadError = 'Could not load data. Pull down to try again.';
    }
    notifyListeners();
    if (pushStatus == PushStatus.failed) unawaited(syncPush());
    _prefetchRoute();
  }

  Future<void> _loadData() async {
    homeData = await home.load(userLocation: userLocation);
    statuses = await monitoring.loadStatuses(userLocation: userLocation);
    forecast = await forecastService.load(statuses);
    centres = await evacuation.nearest(userLocation, limit: 20, includeUnavailable: true);
    // Distances from the sample point would be wrong, so no "nearest" then.
    nearest = locationIssue == null ? nearestStation(statuses, riverOnly: true) : null;
    final n = homeData!.areaCards.length;
    if (areaIndex >= n) areaIndex = n == 0 ? 0 : n - 1;
    _lastRefresh = DateTime.now();
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

  /// Saved areas, the nearest station and stations within 10 km, at the
  /// "Notify me from" level or above (no setup needed).
  ActiveAlerts get alerts => activeAlerts(
        statuses: statuses,
        savedIds: {for (final a in areas) a.station.id},
        nearestId: nearest?.station.id,
        forecasts: forecast?.forecasts ?? const {},
        minLevel: settings.notificationThreshold,
        nearbyKm: locationIssue == null ? 10.0 : -1.0,
      );

  bool isSaved(String stationId) => areas.any((a) => a.station.id == stationId);

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
          heights: heights,
          nearestStationId: nearest?.station.id));
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

  /// "Alert me at Warning (3.60 m)": the station's own height for [level].
  Future<HeightError?> setLevelAlert(String stationId, RiskLevel level) async {
    final t = statusOf(stationId)?.station.thresholds;
    for (final c in levelChoicesFor(t)) {
      if (c.level == level) return setHeightAlert(stationId, c.metres);
    }
    return HeightError.invalid;
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

  /// Safety advice for [level] (not ticked, not counted).
  List<PrepItem> advice(RiskLevel level) => preparedness.advice(level, profile, language: language);

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

  /// Nearest centre that is open, has space and whose position was checked.
  NearbyEvacuation? get nearestAvailable {
    for (final c in centres) {
      if (c.point.isAvailable && c.point.locationChecked) return c;
    }
    return null;
  }

  /// Google Maps directions. A centre whose position was not checked is
  /// searched by its name instead, so a wrong pin never sends anyone astray.
  Uri directionsTo(EvacuationPoint p) => p.locationChecked
      ? Uri.parse(evacuation.directionsUrl(p.location, from: userLocation))
      : Uri.https('www.google.com', '/maps/search/', {'api': '1', 'query': p.name});

  /// Road route from the user to [p] with turn-by-turn steps. Every route
  /// found is kept on the phone; without internet the kept one is used if it
  /// started near where the user is now. [fresh] asks again even when this
  /// trip was already found in this session ("Update route").
  Future<RouteOutcome> routeTo(EvacuationPoint p, {bool fresh = false}) async {
    // No road route to a position nobody has checked (places/centres.csv).
    if (!p.locationChecked) return const RouteOutcome(error: RouteError.unchecked);
    // The server would refuse it anyway; say so instead of "check your internet".
    if (distanceKm(userLocation, p.location) > maxRouteKm) return const RouteOutcome(error: RouteError.tooFar);
    final provider = deps.routes;
    final saved = await savedRouteFor(p);
    if (provider == null) {
      return saved == null
          ? const RouteOutcome(error: RouteError.notSetUp)
          : RouteOutcome(plan: saved.plan, savedAt: saved.savedAt, fromSaved: true, error: RouteError.notSetUp);
    }
    final key = _routeKey(p);
    final known = _routes[key];
    if (known != null && !fresh) return RouteOutcome(plan: known.plan, savedAt: known.savedAt);
    try {
      final plan = await provider.route(userLocation, p.location);
      final kept = await routeCache.save(p.id, plan, DateTime.now());
      _routes[key] = kept;
      savedRoutes[p.id] = kept;
      return RouteOutcome(plan: plan, savedAt: kept.savedAt);
    } catch (_) {
      if (saved != null) {
        return RouteOutcome(plan: saved.plan, savedAt: saved.savedAt, fromSaved: true, error: RouteError.failed);
      }
      return const RouteOutcome(error: RouteError.failed);
    }
  }

  /// The route kept on the phone for [p], if it started near the user.
  Future<SavedRoute?> savedRouteFor(EvacuationPoint p) async {
    final r = savedRoutes[p.id] ?? await routeCache.load(p.id);
    if (r == null) return null;
    savedRoutes[p.id] = r;
    return r.startsNear(userLocation) ? r : null;
  }

  /// Keeps a route to the nearest open centre on the phone in the
  /// background, so it is there if the internet goes down. Only asks again
  /// when the kept one is missing, older than 30 minutes or from elsewhere.
  bool _prefetching = false;
  void _prefetchRoute() {
    final c = nearestAvailable;
    if (c == null || deps.routes == null || _prefetching) return;
    _prefetching = true;
    unawaited(() async {
      try {
        final saved = await savedRouteFor(c.point);
        final stale = saved == null || DateTime.now().difference(saved.savedAt) > const Duration(minutes: 30);
        if (stale) await routeTo(c.point, fresh: true);
      } catch (_) {
        // A bonus: never disturbs the screens.
      } finally {
        _prefetching = false;
      }
    }());
  }

  // ---------- location ----------
  /// Works out where the user is, following their choices
  /// (LocationConsentService): at [launch] it may show the phone's pop-up
  /// (they agreed before) or ask for FloodReady's explanation screen first;
  /// [ask] (a button the user pressed) always may show the pop-up. Pull to
  /// refresh, the timer and coming back to the app never show a pop-up.
  Future<void> _locate({bool launch = false, bool ask = false}) async {
    final c = locationChoice = await locationConsent.load();
    if (c.automatic == false && !ask) {
      location = LocationFix(deps.location.fallback, issue: LocationIssue.off);
      return;
    }
    final allowed = await deps.location.allowed();
    final start = ask
        ? LocationStart.askPhone
        : launch
            ? LocationConsentService.atLaunch(c, allowed: allowed)
            : (allowed ? LocationStart.useGps : LocationStart.dontUse);
    if (start == LocationStart.explainFirst) askLocationNow = true;
    var fix = await deps.location.current(ask: start == LocationStart.askPhone);
    if (fix.issue == null) {
      if (c.automatic != true || c.blocked) await locationConsent.phoneAnswered(allowed: true, blocked: false);
    } else if (fix.issue == LocationIssue.deniedForever) {
      if (!c.blocked) await locationConsent.phoneAnswered(allowed: false, blocked: true);
    } else if (fix.issue == LocationIssue.denied && c.blocked) {
      // Android's plain check says "denied" even when blocked for good.
      fix = LocationFix(fix.point, issue: LocationIssue.deniedForever);
    }
    location = fix;
    locationChoice = await locationConsent.load();
  }

  /// Answer on the "Use your location?" screen.
  Future<void> answerLocationQuestion({required bool allow, bool dontAskAgain = false}) async {
    askLocationNow = false;
    if (allow) {
      await refresh(askLocation: true);
    } else {
      await locationConsent.notNow(dontAskAgain: dontAskAgain);
      locationChoice = await locationConsent.load();
      notifyListeners();
    }
    unawaited(syncPush());
  }

  /// "Use my location automatically" in More. On: asks the phone if needed,
  /// or opens the phone's settings when it is blocked or switched off there.
  Future<void> setLocationAutomatic(bool on) async {
    await locationConsent.setAutomatic(on);
    await refresh(askLocation: on);
    if (on && (locationIssue == LocationIssue.deniedForever || locationIssue == LocationIssue.serviceOff)) {
      await deps.location.openSettings();
    }
    unawaited(syncPush());
  }

  /// "Use my location" buttons (Centres, reports): the user wants location now.
  Future<void> retryLocation() async {
    await locationConsent.setAutomatic(true);
    await refresh(askLocation: true);
    unawaited(syncPush());
  }

  /// Coming back to the app: reload when the data is over 2 minutes old,
  /// or when location was off (the user may have just allowed it).
  AppLifecycleListener? _life;
  void _watchResume() {
    _life ??= AppLifecycleListener(onResume: () {
      final last = _lastRefresh;
      if (locationIssue != null || last == null || DateTime.now().difference(last) > const Duration(minutes: 2)) {
        refresh();
      }
    });
  }

  @override
  void dispose() {
    _life?.dispose();
    _timer?.cancel();
    super.dispose();
  }

  // ---------- flood reports and headcount ----------
  Future<void> _loadHeadcount() async {
    try {
      headcount = await reports.myHeadcount();
      notifyListeners();
    } catch (_) {
      // Shown as "not sent" until the next try; the form still works.
    }
  }

  Future<void> submitReport(FloodReportDraft d) => reports.submitReport(d);

  Future<List<MyReport>> myReports() => reports.myReports();

  Future<MyHeadcount> sendHeadcount(HeadcountDraft d) async {
    headcount = await reports.submitHeadcount(d);
    notifyListeners();
    return headcount!;
  }

  Future<void> setHeadcountStatus(HeadcountStatus s) async {
    headcount = await reports.setHeadcountStatus(s);
    notifyListeners();
  }

  Future<void> removeHeadcount() async {
    await reports.removeHeadcount();
    headcount = null;
    notifyListeners();
  }

  /// A rough place name for a point, from the nearest station with a
  /// position: "Near Kg. Awat, Segamat". Null when no station is within 25 km.
  String? placeNear(GeoPoint p) {
    Station? best;
    var bestKm = double.infinity;
    for (final s in statuses) {
      final at = s.station.location;
      if (at == null) continue;
      final d = distanceKm(p, at);
      if (d < bestKm) {
        bestKm = d;
        best = s.station;
      }
    }
    if (best == null || bestKm > 25) return null;
    final short = best.name.contains(' di ') ? best.name.split(' di ').last : best.name;
    return '$short, ${best.district}';
  }

  // ---------- road routes ----------
  /// Road routes already found, so the map and the route page do not ask
  /// openrouteservice twice for the same trip. Failures are not kept.
  final Map<String, SavedRoute> _routes = {};
  String _routeKey(EvacuationPoint p) =>
      '${p.id}@${userLocation.lat.toStringAsFixed(3)},${userLocation.lon.toStringAsFixed(3)}';

  /// The road route if it was already found, else null.
  RoutePlan? knownRoute(EvacuationPoint p) => _routes[_routeKey(p)]?.plan;

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
