import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flood_core/flood_core.dart';
import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens phone calls, text messages and map links in other apps.
/// Tests use a fake that only records the addresses.
abstract class UrlOpener {
  /// False when no app could open it.
  Future<bool> open(Uri uri);
}

class DeviceUrlOpener implements UrlOpener {
  @override
  Future<bool> open(Uri uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}

Uri phoneUri(String number) => Uri(scheme: 'tel', path: number);

/// Text message with a body. Built by hand because some SMS apps show "+"
/// for spaces when the body is form-encoded.
Uri smsUri(String number, String body) => Uri.parse('sms:$number?body=${Uri.encodeComponent(body)}');

/// Saves followed area ids on the phone. Before the first save it returns
/// [defaults], so a new user sees some areas on Home straight away.
class PhoneFollowedStore implements FollowedStore {
  PhoneFollowedStore(this.key, {this.defaults = const [], SharedPreferencesAsync? prefs})
      : _prefs = prefs ?? SharedPreferencesAsync();
  final String key;
  final List<String> defaults;
  final SharedPreferencesAsync _prefs;

  @override
  Future<List<String>> load() async => await _prefs.getStringList(key) ?? [...defaults];

  @override
  Future<void> save(List<String> stationIds) => _prefs.setStringList(key, stationIds);
}

// ---------------------------------------------------------------- read aloud

enum SpeakResult { spoken, stopped, noVoice, failed }

/// Reads text aloud with the phone's own text-to-speech voices.
abstract class Speaker {
  /// Returns when speaking has finished or was stopped.
  Future<SpeakResult> speak(String text, AppLanguage language, {bool slow = false});
  Future<void> stop();
}

class DeviceSpeaker implements Speaker {
  final FlutterTts _tts = FlutterTts();
  bool _stopped = false;

  static String _code(AppLanguage l) => switch (l) {
        AppLanguage.en => 'en-GB',
        AppLanguage.ms => 'ms-MY',
        AppLanguage.zh => 'zh-CN',
      };

  @override
  Future<SpeakResult> speak(String text, AppLanguage language, {bool slow = false}) async {
    try {
      final code = _code(language);
      if (await _tts.isLanguageAvailable(code) != true) return SpeakResult.noVoice;
      await _tts.awaitSpeakCompletion(true);
      await _tts.setLanguage(code);
      // Android: 0.5 is normal speed.
      await _tts.setSpeechRate(slow ? 0.35 : 0.5);
      _stopped = false;
      await _tts.speak(text);
      return _stopped ? SpeakResult.stopped : SpeakResult.spoken;
    } catch (_) {
      return SpeakResult.failed;
    }
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    try {
      await _tts.stop();
    } catch (_) {}
  }
}

// ---------------------------------------------------------------- location

/// Why the sample location is used instead of the phone's.
enum LocationIssue { serviceOff, denied, deniedForever, failed }

class LocationFix {
  const LocationFix(this.point, {this.issue});
  final GeoPoint point;

  /// Null when [point] is the phone's real position.
  final LocationIssue? issue;
  bool get isSample => issue != null;
}

abstract class LocationProvider {
  /// The phone's position, or the sample point with the reason.
  /// Shows the permission pop-up only when [ask] is true (the Centres
  /// button); otherwise it just checks what was already allowed.
  Future<LocationFix> current({bool ask = false});

  /// Opens the phone's Location page (switch off) or this app's
  /// permission page (blocked), so the user can allow location.
  Future<void> openSettings();
}

class DeviceLocationProvider implements LocationProvider {
  DeviceLocationProvider({
    required this.fallback,
    Future<LocationPermission> Function()? checkPermission,
    Future<LocationPermission> Function()? requestPermission,
    Future<bool> Function()? serviceEnabled,
  })  : _check = checkPermission ?? Geolocator.checkPermission,
        _request = requestPermission ?? Geolocator.requestPermission,
        _serviceOn = serviceEnabled ?? Geolocator.isLocationServiceEnabled;
  final GeoPoint fallback;
  final Future<LocationPermission> Function() _check;
  final Future<LocationPermission> Function() _request;
  final Future<bool> Function() _serviceOn;

  /// Android blocked the pop-up. Its plain check still says "denied" in
  /// that case, so remember it until location is allowed in settings.
  bool _blocked = false;

  @override
  Future<LocationFix> current({bool ask = false}) async {
    try {
      // Check the app permission first: the phone shows the pop-up even
      // when its Location switch is off, so the user is never stuck.
      var p = await _check();
      if (p == LocationPermission.denied && _blocked) p = LocationPermission.deniedForever;
      if (p == LocationPermission.denied && ask) p = await _request();
      _blocked = p == LocationPermission.deniedForever;
      if (p == LocationPermission.denied) return LocationFix(fallback, issue: LocationIssue.denied);
      if (p == LocationPermission.deniedForever) return LocationFix(fallback, issue: LocationIssue.deniedForever);
      if (!await _serviceOn()) {
        return LocationFix(fallback, issue: LocationIssue.serviceOff);
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 15)),
      );
      return LocationFix(GeoPoint(pos.latitude, pos.longitude));
    } catch (_) {
      return LocationFix(fallback, issue: LocationIssue.failed);
    }
  }

  @override
  Future<void> openSettings() async {
    try {
      // Location switch off: open the phone's Location page.
      // Otherwise the app was blocked: open this app's permission page.
      if (!await Geolocator.isLocationServiceEnabled()) {
        await Geolocator.openLocationSettings();
      } else {
        await Geolocator.openAppSettings();
      }
    } catch (_) {}
  }
}

// ---------------------------------------------------------------- Supabase

/// Supabase project, given when building the app (see secrets.json):
///   flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_PUBLISHABLE_KEY=sb_publishable_...
/// Only the publishable key goes into the app. Without these the app uses
/// the sample data, and routes and push alerts are off.
const supabaseConfig = SupabaseConfig(
  url: String.fromEnvironment('SUPABASE_URL'),
  publishableKey: String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY'),
);

final http.Client _client = http.Client();

/// Sends one request for flood_core's Supabase client.
Future<HttpReply> deviceHttp(String method, Uri uri, {Map<String, String> headers = const {}, String? body}) async {
  final req = http.Request(method, uri)..headers.addAll(headers);
  if (body != null) req.body = body;
  final res = await http.Response.fromStream(await _client.send(req).timeout(const Duration(seconds: 20)));
  // Station names can contain any character: always read the reply as UTF-8.
  return HttpReply(res.statusCode, utf8.decode(res.bodyBytes, allowMalformed: true));
}

/// Defaults when live JPS data is used (Klang river, the forecast target).
class LiveDefaults {
  /// Taman Sri Muda, Puchong Drop and USJ 1 (ml/stations_klang.json).
  static const followed = ['BKLG0002L', 'BPTL0004L', 'BPTL0061L'];

  /// Used when the phone's location is off or refused (Taman Sri Muda, Shah Alam).
  static final GeoPoint userLocation = GeoPoint(3.0185, 101.5310);
}

// ---------------------------------------------------------------- push

enum PushPermission { granted, denied, notAsked }

/// The phone's push notification token and permission (Firebase).
/// Tests use a fake.
abstract class PushTokens {
  String get platform;
  Future<PushPermission> permission();

  /// Shows the phone's "Allow notifications?" prompt (Android 13+, iPhone).
  Future<PushPermission> ask();

  /// Null when Firebase could not give a token (no internet, no Play services).
  Future<String?> token();
}

class FirebasePushTokens implements PushTokens {
  FirebasePushTokens._();

  /// Starts Firebase. Returns null (push off) when the app was built without
  /// a google-services.json, or Firebase cannot start on this phone.
  /// [onMessage] gets alerts that arrive while the app is open (the phone
  /// itself only shows them when the app is closed or in the background).
  static Future<FirebasePushTokens?> start({void Function(String title, String body)? onMessage}) async {
    try {
      await Firebase.initializeApp().timeout(const Duration(seconds: 10));
      if (onMessage != null) {
        FirebaseMessaging.onMessage.listen((m) {
          final n = m.notification;
          if (n != null) onMessage(n.title ?? '', n.body ?? '');
        });
      }
      return FirebasePushTokens._();
    } catch (_) {
      return null;
    }
  }

  @override
  String get platform => defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';

  static PushPermission _map(AuthorizationStatus s) {
    if (s == AuthorizationStatus.authorized || s == AuthorizationStatus.provisional) return PushPermission.granted;
    if (s == AuthorizationStatus.notDetermined) return PushPermission.notAsked;
    return PushPermission.denied;
  }

  @override
  Future<PushPermission> permission() async {
    try {
      return _map((await FirebaseMessaging.instance.getNotificationSettings()).authorizationStatus);
    } catch (_) {
      return PushPermission.denied;
    }
  }

  @override
  Future<PushPermission> ask() async {
    try {
      return _map((await FirebaseMessaging.instance.requestPermission()).authorizationStatus);
    } catch (_) {
      return PushPermission.denied;
    }
  }

  /// The phone's Firebase Installation ID (FID), which the server sends
  /// alerts to. Firebase replaced the old registration tokens (getToken) with
  /// FIDs; the AndroidManifest turns FID mode on. Listens first, then
  /// registers, so the id cannot be missed.
  @override
  Future<String?> token() async {
    try {
      final fid = FirebaseMessaging.instance.onRegistered.first.timeout(const Duration(seconds: 20));
      await FirebaseMessaging.instance.register();
      return await fid;
    } catch (_) {
      return null;
    }
  }
}
