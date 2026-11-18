import '../data/station_repository.dart';
import '../data/table.dart';
import '../errors.dart';
import '../models/alert_rule.dart';
import '../models/risk_level.dart';
import '../models/station_status.dart';

/// When a rule notifies. The same rules run on the server for push alerts
/// (supabase/alerts.sql, public.alerts_tick); keep the two in step.
///
/// - Notify when a rule first becomes true.
/// - Notify again whenever the river moves up a level (Alert -> Warning -> Danger).
/// - At Danger, repeat every [dangerRepeat] while it stays there.
/// - Once the rule is no longer true, wait [resetAfter] before it can start
///   again from the beginning, so a river hovering at a line does not cause a
///   string of alerts. A height alert also has a [heightBuffer]: after it has
///   fired, the river must drop that far below the height to count as gone.
/// - Old (stale) or missing readings change nothing.
class AlertRules {
  static const dangerRepeat = Duration(minutes: 45);
  static const resetAfter = Duration(minutes: 60);
  static const heightBuffer = 0.10;
}

/// The result of checking one rule against one reading.
class AlertDecision {
  const AlertDecision(this.state, this.reason);

  /// State to remember after this check.
  final AlertState state;

  /// Non-null when a notification is due now.
  final AlertReason? reason;
}

/// Checks one rule. [level] is the station's risk level now (null when the
/// station has no thresholds) and [riverM] its river level. Call only with a
/// fresh reading. [minLevel] is the lowest level a risk rule fires at.
AlertDecision decideAlert({
  required AlertRule rule,
  required RiskLevel? level,
  required double? riverM,
  required AlertState state,
  required DateTime now,
  RiskLevel? minLevel,
}) {
  final bool on;
  if (rule.type == AlertType.riskLevel) {
    if (level == null) return AlertDecision(state, null);
    on = level.isAtLeast(minLevel ?? rule.minLevel!);
  } else {
    if (riverM == null) return AlertDecision(state, null);
    final line = rule.waterLevelM! - (state.notified ? AlertRules.heightBuffer : 0);
    on = riverM >= line - 1e-9;
  }
  if (!on) {
    if (!state.notified) return AlertDecision(state, null);
    final since = state.belowSince ?? now;
    if (now.difference(since) >= AlertRules.resetAfter) return const AlertDecision(AlertState(), null);
    return AlertDecision(
        AlertState(lastLevel: state.lastLevel, lastNotifiedAt: state.lastNotifiedAt, belowSince: since), null);
  }
  final current = level ?? RiskLevel.normal;
  AlertReason? reason;
  if (!state.notified) {
    reason = AlertReason.first;
  } else if (current.index > (state.lastLevel ?? RiskLevel.normal).index) {
    reason = AlertReason.escalated;
  } else if (current == RiskLevel.danger && now.difference(state.lastNotifiedAt!) >= AlertRules.dangerRepeat) {
    reason = AlertReason.dangerRepeat;
  }
  if (reason == null) {
    // Still true: forget any "gone since" time, keep what was sent.
    return AlertDecision(AlertState(lastLevel: state.lastLevel, lastNotifiedAt: state.lastNotifiedAt), null);
  }
  return AlertDecision(AlertState(lastLevel: current, lastNotifiedAt: now), reason);
}

/// "My Alerts": per-station rules, and deciding when a notification is due
/// (see [AlertRules]).
class AlertService {
  AlertService({
    required this.rules,
    required this.firedState,
    required this.repository,
    required this.newId,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;
  final Table<AlertRule> rules;

  /// Remembers, per rule id, what has been sent.
  final Table<AlertState> firedState;
  final StationRepository repository;
  final IdGenerator newId;
  final DateTime Function() _clock;

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
    if (levelM <= -100 || levelM >= 1000) throw ValidationException('Water level is out of range');
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
    final now = _clock();
    final byId = {for (final s in statuses) s.station.id: s};
    final events = <AlertEvent>[];
    for (final rule in await rules.all()) {
      if (!rule.enabled) continue;
      final s = byId[rule.stationId];
      if (s == null || s.reading == null || s.isStale) continue; // keep previous state
      final before = await firedState.byId(rule.id) ?? const AlertState();
      final min = rule.minLevel == null
          ? null
          : (rule.minLevel!.isAtLeast(threshold) ? rule.minLevel! : threshold);
      final d = decideAlert(
          rule: rule, level: s.level, riverM: s.riverLevel, state: before, now: now, minLevel: min);
      if (d.reason != null) events.add(AlertEvent(rule, s, _message(rule, s, d.reason!), reason: d.reason!));
      if (d.state.lastLevel != before.lastLevel ||
          d.state.lastNotifiedAt != before.lastNotifiedAt ||
          d.state.belowSince != before.belowSince) {
        if (d.state.notified) {
          await firedState.put(rule.id, d.state);
        } else {
          await firedState.remove(rule.id);
        }
      }
    }
    return events;
  }

  String _message(AlertRule rule, StationStatus s, AlertReason reason) {
    final still = reason == AlertReason.dangerRepeat ? 'still at ' : '';
    if (rule.type == AlertType.riskLevel) {
      return '${s.station.name}: $still${s.level!.labelEn} level';
    }
    return '${s.station.name}: river at ${s.riverLevel!.toStringAsFixed(2)} m '
        '(your alert: ${rule.waterLevelM!.toStringAsFixed(2)} m)';
  }
}
