import 'dart:convert';

import 'package:flood_app/app/app_controller.dart';
import 'package:flood_app/app/platform.dart';
import 'package:flood_app/app/sample_data.dart';
import 'package:flood_app/main.dart';
import 'package:flood_app/security/phone_lock.dart';
import 'package:flood_core/flood_core.dart';
import 'package:flutter_test/flutter_test.dart';
// Table also exists in Flutter; tests use flood_core's.
import 'package:material_ui/material_ui.dart' hide Table;

class FakePhoneLock implements PhoneLockChecker {
  FakePhoneLock({this.state = PhoneLock.ready, this.pass = true});
  PhoneLock state;
  bool pass;
  int prompts = 0;

  @override
  Future<PhoneLock> status() async => state;

  @override
  Future<bool> confirm(String reason) async {
    prompts++;
    return pass;
  }
}

/// Records every address the app tries to open (calls, SMS, maps).
class FakeOpener implements UrlOpener {
  final opened = <Uri>[];
  bool result = true;

  @override
  Future<bool> open(Uri uri) async {
    opened.add(uri);
    return result;
  }
}

class FakeSpeaker implements Speaker {
  final spoken = <(String, AppLanguage, bool)>[];
  int stops = 0;
  SpeakResult result = SpeakResult.spoken;

  @override
  Future<SpeakResult> speak(String text, AppLanguage language, {bool slow = false}) async {
    spoken.add((text, language, slow));
    return result;
  }

  @override
  Future<void> stop() async => stops++;
}

class FakeLocation implements LocationProvider {
  FakeLocation(this.fix);
  LocationFix fix;
  int asked = 0;

  @override
  GeoPoint get fallback => SampleData.userLocation;

  /// The phone allows location when the next answer would be the real position.
  @override
  Future<bool> allowed() async => fix.issue == null;
  int prompted = 0;
  int settingsOpened = 0;

  @override
  Future<LocationFix> current({bool ask = false}) async {
    asked++;
    if (ask) prompted++;
    return fix;
  }

  @override
  Future<void> openSettings() async => settingsOpened++;
}

class FakeRoutes implements RouteProvider {
  bool fail = false;

  /// Steps with openrouteservice step types (as the live server sends),
  /// so the app words them itself in each language.
  bool typed = false;
  int calls = 0;
  @override
  Future<RoutePlan> route(GeoPoint from, GeoPoint to) async {
    calls++;
    if (fail) throw RoutingException('offline');
    return RoutePlan(from: from, to: to, distanceM: 6200, durationS: 700, path: [from, to], steps: [
      RouteStep(instruction: 'Head north on Jalan Awat', distanceM: 450, durationS: 60,
          type: typed ? 11 : null, name: typed ? 'Jalan Awat' : null, wayPoint: 0),
      RouteStep(instruction: 'Turn left onto Jalan Buloh Kasap', distanceM: 5700, durationS: 620,
          type: typed ? 0 : null, name: typed ? 'Jalan Buloh Kasap' : null, wayPoint: 1),
      RouteStep(instruction: 'Arrive at SK Buloh Kasap', distanceM: 0, durationS: 0, type: typed ? 10 : null, wayPoint: 1),
    ]);
  }
}

class FakeContacts implements ContactPicker {
  String? number = '019-876 5432';
  int asked = 0;
  @override
  Future<String?> pickPhone() async {
    asked++;
    return number;
  }
}

/// A household with someone 60+, daily medicine and no own car.
const testProfile = HouseholdProfile(people: 4, olderAdult: true, dailyMedicine: true, transport: Transport.lift);

class TestApp {
  TestApp({
    HouseholdProfile? profile = testProfile,
    List<String> followed = const ['JHR-AWAT', 'JHR-BULOH', 'SGR-KAJANG'],
    HouseholdLockService? lock,
    FakePhoneLock? phone,
    Map<String, String> settings = const {},
    LocationFix? location,
    bool routesSetUp = true,
    this.pushTokens,
    this.push,
    bool pushAskedBefore = true,
    bool locationAskedBefore = true,
    Map<String, String>? flags,
    Table<EvacuationPoint>? centres,
    this.liveData = false,
    ForecastSource? forecastSource,
  })  : flagsStore = InMemorySettingsStore(flags ??
            {
              if (pushAskedBefore) 'pushAsked': 'true',
              // Most tests are not about the "Use your location?" screen.
              if (locationAskedBefore) 'locDontAsk': 'true',
            }), profileStore = InMemorySettingsStore(profile == null ? {} : {...profile.toMap(), 'saved': 'true'}),
        progressStore = InMemorySettingsStore(),
        settingsStore = InMemorySettingsStore(settings),
        contactStore = InMemorySettingsStore(),
        followedStore = InMemoryFollowedStore(followed),
        phone = phone ?? FakePhoneLock(),
        opener = FakeOpener(),
        speaker = FakeSpeaker(),
        voiceStore = InMemorySettingsStore(),
        routes = FakeRoutes(),
        location = FakeLocation(location ?? LocationFix(SampleData.userLocation)) {
    this.lock = lock ?? HouseholdLockService(InMemorySettingsStore());
    controller = AppController(AppDeps(
      repository: SampleStationRepository(),
      followedStore: followedStore,
      settingsStore: settingsStore,
      profileStore: profileStore,
      progressStore: progressStore,
      contactStore: contactStore,
      centres: centres ?? SampleData.centres(),
      forecastSource: forecastSource ?? SampleForecastSource(),
      liveData: liveData,
      lock: this.lock,
      phone: this.phone,
      opener: opener,
      location: this.location,
      speaker: speaker,
      voiceStore: voiceStore,
      routes: routesSetUp ? routes : null,
      showMapTiles: false,
      pushTokens: pushTokens,
      push: push,
      heights: HeightAlertStore(heightStore),
      flagsStore: flagsStore,
      routeStore: routeStore,
      reportsStore: reportsStore,
      contacts: contacts,
    ));
  }

  final InMemorySettingsStore flagsStore;
  final routeStore = InMemorySettingsStore();
  final reportsStore = InMemorySettingsStore();
  final contacts = FakeContacts();

  final InMemorySettingsStore profileStore;
  final InMemorySettingsStore progressStore;
  final InMemorySettingsStore settingsStore;
  final InMemorySettingsStore contactStore;
  final InMemoryFollowedStore followedStore;
  final FakePhoneLock phone;
  final FakeOpener opener;
  final FakeSpeaker speaker;
  final InMemorySettingsStore voiceStore;
  final FakeRoutes routes;
  final FakeLocation location;
  final PushTokens? pushTokens;
  final PushAlertService? push;
  final heightStore = InMemorySettingsStore();
  late final HouseholdLockService lock;
  late final AppController controller;
  final bool liveData;

  /// Starts the app on a phone-sized screen and waits until it has loaded.
  Future<void> start(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532); // 390 x 844 at 3x
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(FloodApp(controller: controller));
    await tester.pumpAndSettle();
  }
}

/// Scrolls [f] into view. Long screens are lazy lists that only build what
/// is on or near the screen, so if [f] is not built yet this scrolls the
/// page down (then up) until it is. It moves the list directly rather than
/// dragging, because a drag that starts on the map would pan the map instead.
Future<void> reveal(WidgetTester tester, Finder f) async {
  if (f.evaluate().isEmpty) {
    final page = find.byWidgetPredicate((w) => w is Scrollable && axisDirectionToAxis(w.axisDirection) == Axis.vertical);
    if (page.evaluate().isNotEmpty) {
      final pos = tester.state<ScrollableState>(page.first).position;
      for (final step in const [300.0, -300.0]) {
        for (var i = 0; i < 60 && f.evaluate().isEmpty; i++) {
          final next = (pos.pixels + step).clamp(pos.minScrollExtent, pos.maxScrollExtent);
          if (next == pos.pixels) break;
          pos.jumpTo(next);
          await tester.pump();
        }
        if (f.evaluate().isNotEmpty) break;
      }
    }
  }
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
}

/// Scrolls [f] into view, then taps it.
Future<void> tapIt(WidgetTester tester, Finder f) async {
  await reveal(tester, f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> openTab(WidgetTester tester, String label) => tapIt(tester, find.byKey(ValueKey('tab-$label')));

/// Lets a SnackBar time out so no timer is left running at the end of a test.
Future<void> waitForSnackBar(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

/// The phone side of push: permission prompt and Firebase token.
class FakePushTokens implements PushTokens {
  FakePushTokens({this.state = PushPermission.notAsked, this.answer = PushPermission.granted});
  PushPermission state;

  /// What the user picks when asked.
  PushPermission answer;
  int asked = 0;

  @override
  String get platform => 'android';

  @override
  Future<PushPermission> permission() async => state;

  @override
  Future<PushPermission> ask() async {
    asked++;
    return state = answer;
  }

  @override
  Future<String?> token() async => 'fcm-test-token-0123456789';
}

/// A fake alert server: records each database function the app calls.
class FakePushServer {
  final calls = <(String, Map<String, dynamic>)>[];
  bool down = false;

  Future<HttpReply> send(String method, Uri uri, {Map<String, String> headers = const {}, String? body}) async {
    if (down) throw StateError('no internet');
    if (uri.path == '/auth/v1/signup') {
      return const HttpReply(200,
          '{"access_token":"a","refresh_token":"r","expires_in":3600,"user":{"id":"phone-1"}}');
    }
    final name = uri.pathSegments.last;
    calls.add((name, jsonDecode(body ?? '{}') as Map<String, dynamic>));
    return HttpReply(200, name == 'sync_alert_rules' ? '1' : '');
  }

  PushAlertService service() {
    const config = SupabaseConfig(url: 'https://demo.supabase.co', publishableKey: 'sb_publishable_test');
    return PushAlertService(SupabaseApi(
        config: config, send: send,
        auth: SupabaseAuth(config: config, send: send, store: InMemorySettingsStore())));
  }

  /// The rules sent in the last sync.
  List<dynamic> get lastRules =>
      calls.lastWhere((c) => c.$1 == 'sync_alert_rules').$2['p_rules'] as List<dynamic>;
}
