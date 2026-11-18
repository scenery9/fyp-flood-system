import 'package:flood_core/flood_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:material_ui/material_ui.dart';

import 'app/app_controller.dart';
import 'app/platform.dart';
import 'app/sample_data.dart';
import 'screens/app_shell.dart';
import 'security/phone_lock.dart';
import 'security/phone_settings_store.dart';
import 'theme/app_theme.dart';

/// Shows alerts that arrive while the app is open (the phone shows them
/// itself only when the app is closed or in the background).
final messengerKey = GlobalKey<ScaffoldMessengerState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Live JPS data, routes and push alerts need the Supabase settings
  // (secrets.json, see README "Round 6"). Without them: sample data only.
  final live = supabaseConfig.isSet;
  final api = live
      ? SupabaseApi(
          config: supabaseConfig,
          send: deviceHttp,
          auth: SupabaseAuth(config: supabaseConfig, send: deviceHttp, store: PhoneSettingsStore('supabase_session')))
      : null;

  late final AppController controller;
  // Needs android/app/google-services.json from your Firebase project; else push stays off.
  final pushTokens = live
      ? await FirebasePushTokens.start(onMessage: (title, body) {
          messengerKey.currentState?.showSnackBar(SnackBar(content: Text(body.isEmpty ? title : '$title\n$body')));
          controller.refresh();
        })
      : null;

  controller = AppController(AppDeps(
    repository: api == null ? SampleStationRepository() : LiveStationRepository(api),
    // Live and sample station ids differ, so each keeps its own saved areas.
    followedStore: live
        ? PhoneFollowedStore('followed_areas_live', defaults: LiveDefaults.followed)
        : PhoneFollowedStore('followed_areas', defaults: SampleData.defaultFollowed),
    // Each store has its own key: a store's save replaces everything in it.
    settingsStore: PhoneSettingsStore('app_settings'),
    profileStore: PhoneSettingsStore('household_profile'),
    progressStore: PhoneSettingsStore('checklist_progress'),
    contactStore: PhoneSettingsStore('emergency_contact'),
    // Relief centres from places/centres.csv (uploaded to Supabase); the last
    // list is kept on the phone for use without internet. Sample ones otherwise.
    centres: api == null ? SampleData.centres() : LiveCentreTable(api, store: PhoneSettingsStore('centres_live')),
    forecastSource: SampleForecastSource(),
    // Created once per app start, so an unlock lasts until the app is closed.
    lock: HouseholdLockService(PhoneSettingsStore('household_lock')),
    phone: DevicePhoneLockChecker(),
    opener: DeviceUrlOpener(),
    // Phone GPS; a sample point is used if location is off or refused.
    location: DeviceLocationProvider(fallback: live ? LiveDefaults.userLocation : SampleData.userLocation),
    speaker: DeviceSpeaker(),
    voiceStore: PhoneSettingsStore('read_aloud'),
    // Through our Edge Function: the openrouteservice key is never in the app.
    // Without Supabase, routes open in Google Maps.
    routes: api == null ? null : EdgeRouteProvider(api),
    push: api == null ? null : PushAlertService(api),
    pushTokens: pushTokens,
    heights: HeightAlertStore(PhoneSettingsStore(live ? 'height_alerts_live' : 'height_alerts')),
    liveData: live,
    flagsStore: PhoneSettingsStore('app_flags'),
    // Routes to relief centres, kept for use without internet.
    routeStore: PhoneSettingsStore(live ? 'saved_routes_live' : 'saved_routes'),
    // Without Supabase, reports and the headcount stay on the phone (and the app says so).
    reports: api == null ? null : SupabaseReportsBackend(api),
    reportsStore: PhoneSettingsStore('reports_on_phone'),
    contacts: kIsWeb ? null : DeviceContactPicker(),
    // JPS data is logged every 15 minutes; reload as often while the app is open.
    refreshEvery: const Duration(minutes: 15),
  ));
  runApp(FloodApp(controller: controller));
}

class FloodApp extends StatefulWidget {
  const FloodApp({super.key, required this.controller});
  final AppController controller;

  @override
  State<FloodApp> createState() => _FloodAppState();
}

class _FloodAppState extends State<FloodApp> {
  @override
  void initState() {
    super.initState();
    widget.controller.init();
  }

  static double _scale(TextSize s) => switch (s) {
        TextSize.small => 0.9,
        TextSize.medium => 1.0,
        TextSize.large => 1.3,
      };

  @override
  Widget build(BuildContext context) {
    return AppScope(
      controller: widget.controller,
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final s = widget.controller.settings;
          return MaterialApp(
            title: 'FloodReady',
            scaffoldMessengerKey: messengerKey,
            debugShowCheckedModeBanner: false,
            theme: buildTheme(highContrast: s.highContrast),
            builder: (context, child) {
              final mq = MediaQuery.of(context);
              // The user's own phone text size is kept, then multiplied by the app setting.
              final phone = mq.textScaler.scale(1);
              return MediaQuery(
                data: mq.copyWith(textScaler: TextScaler.linear((phone * _scale(s.textSize)).clamp(0.9, 2.0))),
                child: child!,
              );
            },
            home: const AppShell(),
          );
        },
      ),
    );
  }
}
