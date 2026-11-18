import '../data/supabase_api.dart';
import '../errors.dart';
import '../models/app_settings.dart';
import '../models/risk_level.dart';
import 'settings_service.dart';

/// One alert rule as the server stores it (supabase/alerts.sql, alert_rules).
class ServerAlertRule {
  const ServerAlertRule.risk(this.stationCode, RiskLevel this.minLevel) : levelM = null;
  const ServerAlertRule.height(this.stationCode, double this.levelM) : minLevel = null;
  final String stationCode;
  final RiskLevel? minLevel;
  final double? levelM;

  Map<String, Object?> toJson() => minLevel != null
      ? {'station_code': stationCode, 'kind': 'risk', 'min_level': minLevel!.name}
      : {'station_code': stationCode, 'kind': 'level', 'level_m': levelM};
}

/// The phone's push rules: every saved area at the "Notify me from" level,
/// the station nearest the user ([nearestStationId], so a new user is covered
/// without any setup), plus any river heights the user set. At most 20 rules
/// (the server limit); each station has one risk rule.
List<ServerAlertRule> pushRulesFor({
  required List<String> followedStationIds,
  required RiskLevel threshold,
  Map<String, double> heights = const {},
  String? nearestStationId,
}) {
  final min = threshold == RiskLevel.normal ? RiskLevel.alert : threshold;
  final riskIds = <String>{...followedStationIds, if (nearestStationId != null) nearestStationId};
  return [
    for (final id in riskIds) ServerAlertRule.risk(id, min),
    for (final e in heights.entries) ServerAlertRule.height(e.key, e.value),
  ].take(PushAlertService.maxRules).toList();
}

/// Talks to the server about this phone's push alerts. Errors are thrown as
/// [SupabaseException]; the app treats push as a bonus and carries on.
class PushAlertService {
  PushAlertService(this.api);
  final SupabaseApi api;

  static const int maxRules = 20;

  static String languageCode(AppLanguage l) => l.name; // en / ms / zh

  /// Saves this phone's Firebase token (and the language for the messages).
  Future<void> register({required String token, required String platform, required AppLanguage language}) async {
    await api.rpc('register_device', {'p_token': token, 'p_platform': platform, 'p_language': languageCode(language)});
  }

  /// Replaces this phone's rules on the server. Returns how many were saved
  /// (stations the server does not know are skipped).
  Future<int> syncRules(List<ServerAlertRule> rules) async {
    final r = await api.rpc('sync_alert_rules', {'p_rules': [for (final x in rules.take(maxRules)) x.toJson()]});
    return r is num ? r.toInt() : 0;
  }

  /// Stops all push alerts for this phone.
  Future<void> unregister() async {
    await api.rpc('unregister_device', {});
  }
}

/// River heights the user asked to be alerted at, one per station, kept on
/// the phone ("Alert me when the river reaches 4.20 m").
class HeightAlertStore {
  HeightAlertStore(this.store);
  final SettingsStore store;

  /// Saved areas take up to 5 of the 20 server rules.
  static const int maxHeights = 15;

  Future<Map<String, double>> load() async {
    final out = <String, double>{};
    for (final e in (await store.load()).entries) {
      final v = double.tryParse(e.value);
      if (e.key.trim().isNotEmpty && v != null && v.isFinite && v > -100 && v < 1000) out[e.key] = v;
    }
    return out;
  }

  /// Sets or replaces the height for [stationId].
  Future<Map<String, double>> set(String stationId, double levelM) async {
    if (!levelM.isFinite || levelM <= -100 || levelM >= 1000) {
      throw ValidationException('Enter a river level in metres');
    }
    final all = await load();
    if (!all.containsKey(stationId) && all.length >= maxHeights) {
      throw ConflictException('Maximum $maxHeights river-level alerts');
    }
    all[stationId] = double.parse(levelM.toStringAsFixed(2));
    await _save(all);
    return all;
  }

  Future<Map<String, double>> remove(String stationId) async {
    final all = await load()..remove(stationId);
    await _save(all);
    return all;
  }

  Future<void> _save(Map<String, double> all) =>
      store.save({for (final e in all.entries) e.key: e.value.toStringAsFixed(2)});
}
