import '../errors.dart';
import '../models/app_settings.dart';
import '../models/risk_level.dart';

/// Saves settings as simple text pairs. The Flutter app will provide a
/// version that writes to the phone.
abstract class SettingsStore {
  Future<Map<String, String>> load();
  Future<void> save(Map<String, String> values);
}

class InMemorySettingsStore implements SettingsStore {
  InMemorySettingsStore([Map<String, String> initial = const {}]) : _v = {...initial};
  Map<String, String> _v;
  @override
  Future<Map<String, String>> load() async => {..._v};
  @override
  Future<void> save(Map<String, String> values) async => _v = {...values};
}

class SettingsService {
  SettingsService(this.store);
  final SettingsStore store;

  Future<AppSettings> load() async => AppSettings.fromMap(await store.load());

  Future<AppSettings> save(AppSettings settings) async {
    if (settings.notificationThreshold == RiskLevel.normal) {
      throw ValidationException('Notification threshold must be Alert or higher');
    }
    await store.save(settings.toMap());
    return settings;
  }
}
