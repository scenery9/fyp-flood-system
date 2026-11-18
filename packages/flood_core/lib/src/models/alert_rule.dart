import 'risk_level.dart';
import 'station_status.dart';

enum AlertType { riskLevel, waterLevel }

/// "My Alerts": notify me about one station, by risk level or by water level.
class AlertRule {
  AlertRule({
    required this.id,
    required this.stationId,
    required this.type,
    this.minLevel,
    this.waterLevelM,
    this.enabled = true,
  });
  final String id;
  final String stationId;
  final AlertType type;
  final RiskLevel? minLevel; // for AlertType.riskLevel
  final double? waterLevelM; // for AlertType.waterLevel
  final bool enabled;

  AlertRule copyWith({bool? enabled}) => AlertRule(
      id: id, stationId: stationId, type: type, minLevel: minLevel,
      waterLevelM: waterLevelM, enabled: enabled ?? this.enabled);

  Map<String, String> toMap() => {
        'id': id,
        'station': stationId,
        'type': type.name,
        if (minLevel != null) 'min': minLevel!.name,
        if (waterLevelM != null) 'level': '$waterLevelM',
        'enabled': '$enabled',
      };

  /// Returns null for damaged saved data.
  static AlertRule? fromMap(Map<String, dynamic> m) {
    try {
      final type = AlertType.values.byName('${m['type']}');
      final min = m['min'] == null ? null : RiskLevel.values.byName('${m['min']}');
      final level = m['level'] == null ? null : double.parse('${m['level']}');
      if (type == AlertType.riskLevel && (min == null || min == RiskLevel.normal)) return null;
      if (type == AlertType.waterLevel && (level == null || !level.isFinite)) return null;
      final id = '${m['id'] ?? ''}', station = '${m['station'] ?? ''}';
      if (id.isEmpty || station.isEmpty) return null;
      return AlertRule(
          id: id, stationId: station, type: type,
          minLevel: type == AlertType.riskLevel ? min : null,
          waterLevelM: type == AlertType.waterLevel ? level : null,
          enabled: m['enabled'] != 'false');
    } catch (_) {
      return null;
    }
  }
}

/// What has been sent for one rule. Nothing sent yet = all null.
class AlertState {
  const AlertState({this.lastLevel, this.lastNotifiedAt, this.belowSince});

  /// The station's risk level when the last notification went out.
  final RiskLevel? lastLevel;
  final DateTime? lastNotifiedAt;

  /// When the condition was first seen gone after a notification.
  final DateTime? belowSince;

  bool get notified => lastNotifiedAt != null;
}

/// Why a notification is due.
enum AlertReason {
  /// The rule became true.
  first,

  /// The river moved up a level (e.g. Warning to Danger).
  escalated,

  /// Still at Danger: repeated every [AlertRules.dangerRepeat].
  dangerRepeat,
}

/// A notification that should be shown now.
class AlertEvent {
  AlertEvent(this.rule, this.status, this.message, {this.reason = AlertReason.first});
  final AlertRule rule;
  final StationStatus status;
  final String message;
  final AlertReason reason;
}
