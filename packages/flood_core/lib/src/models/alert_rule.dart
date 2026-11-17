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
}

/// A notification that should be shown now.
class AlertEvent {
  AlertEvent(this.rule, this.status, this.message);
  final AlertRule rule;
  final StationStatus status;
  final String message;
}
