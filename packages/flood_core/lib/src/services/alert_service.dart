import '../data/station_repository.dart';
import '../data/table.dart';
import '../errors.dart';
import '../models/alert_rule.dart';
import '../models/risk_level.dart';
import '../models/station_status.dart';

/// "My Alerts": per-station rules, and deciding when a notification is due.
/// A rule notifies once when its condition becomes true, then stays quiet
/// until the condition has gone away and come back.
class AlertService {
  AlertService({
    required this.rules,
    required this.firedState,
    required this.repository,
    required this.newId,
  });
  final Table<AlertRule> rules;

  /// Remembers, per rule id, whether the rule is currently "on".
  final Table<bool> firedState;
  final StationRepository repository;
  final IdGenerator newId;

  static const int maxRules = 20;

  Future<List<AlertRule>> list() => rules.all();

  /// Alert me when [stationId] reaches [minLevel] (Alert or higher).
  Future<AlertRule> setRiskRule(String stationId, RiskLevel minLevel) async {
    if (minLevel == RiskLevel.normal) throw ValidationException('Choose Alert, Warning or Danger');
    return _set(AlertRule(id: '', stationId: stationId, type: AlertType.riskLevel, minLevel: minLevel));
  }

  /// Alert me when the river at [stationId] reaches [levelM] metres.
  Future<AlertRule> setWaterLevelRule(String stationId, double levelM) async {
    if (levelM.isNaN || levelM.isInfinite) throw ValidationException('Water level is not a valid number');
    return _set(AlertRule(id: '', stationId: stationId, type: AlertType.waterLevel, waterLevelM: levelM));
  }

  /// One rule per station and type: setting it again replaces the old one.
  Future<AlertRule> _set(AlertRule draft) async {
    final stations = await repository.getStations();
    if (!stations.any((s) => s.id == draft.stationId)) throw UnknownStationException(draft.stationId);
    final all = await rules.all();
    AlertRule? old;
    for (final r in all) {
      if (r.stationId == draft.stationId && r.type == draft.type) old = r;
    }
    if (old == null && all.length >= maxRules) throw ConflictException('Maximum $maxRules alerts');
    final rule = AlertRule(
        id: old?.id ?? newId(), stationId: draft.stationId, type: draft.type,
        minLevel: draft.minLevel, waterLevelM: draft.waterLevelM, enabled: true);
    await rules.put(rule.id, rule);
    await firedState.remove(rule.id); // a changed rule starts fresh
    return rule;
  }

  Future<void> remove(String ruleId) async {
    await rules.remove(ruleId);
    await firedState.remove(ruleId);
  }

  Future<AlertRule> setEnabled(String ruleId, bool enabled) async {
    final r = await rules.byId(ruleId) ?? (throw NotFoundException('alert', ruleId));
    final updated = r.copyWith(enabled: enabled);
    await rules.put(ruleId, updated);
    if (!enabled) await firedState.remove(ruleId);
    return updated;
  }

  /// Call after each data refresh. Returns the notifications to show now.
  /// [threshold] is the notification threshold from Settings; it applies to
  /// risk-level rules. Old or missing data never notifies.
  Future<List<AlertEvent>> evaluate(List<StationStatus> statuses,
      {RiskLevel threshold = RiskLevel.alert}) async {
    final byId = {for (final s in statuses) s.station.id: s};
    final events = <AlertEvent>[];
    for (final rule in await rules.all()) {
      if (!rule.enabled) continue;
      final s = byId[rule.stationId];
      if (s == null || s.reading == null || s.isStale) continue; // keep previous state
      bool on;
      String message;
      if (rule.type == AlertType.riskLevel) {
        if (s.level == null) continue;
        on = s.level!.isAtLeast(rule.minLevel!) && s.level!.isAtLeast(threshold);
        message = '${s.station.name}: ${s.level!.labelEn} level';
      } else {
        if (s.riverLevel == null) continue;
        on = s.riverLevel! >= rule.waterLevelM!;
        message = '${s.station.name}: river at ${s.riverLevel!.toStringAsFixed(2)} m '
            '(your alert: ${rule.waterLevelM!.toStringAsFixed(2)} m)';
      }
      final wasOn = await firedState.byId(rule.id) ?? false;
      if (on && !wasOn) events.add(AlertEvent(rule, s, message));
      if (on != wasOn) await firedState.put(rule.id, on);
    }
    return events;
  }
}
