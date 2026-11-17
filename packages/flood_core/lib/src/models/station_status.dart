import 'risk_level.dart';
import 'station.dart';
import 'station_reading.dart';

/// Everything the UI needs to show about one station right now.
class StationStatus {
  StationStatus({
    required this.station,
    required this.reading,
    required this.level,
    required this.targetLevel,
    required this.percentToTarget,
    required this.isStale,
    required this.age,
    required this.rainIntensity,
    required this.distanceKm,
    required this.mainCause,
  });

  final Station station;
  final StationReading? reading;

  /// Null when the level cannot be worked out (no river data or thresholds).
  final RiskLevel? level;

  /// The next level the river is heading towards (Danger stays Danger).
  final RiskLevel? targetLevel;

  /// 0-100: how far the river has risen from normal towards [targetLevel].
  final double? percentToTarget;

  /// True when the latest reading is too old to trust.
  final bool isStale;

  /// Time since the latest reading (null when there is no reading).
  final Duration? age;
  final RainIntensity? rainIntensity;

  /// Distance from the user (null if user or station location is unknown).
  final double? distanceKm;

  /// One plain-English line saying why the station has this status.
  final String mainCause;

  double? get rainfall => reading?.rainfallMmPerHr;
  double? get riverLevel => reading?.riverLevelM;

  /// True when the status is fresh and known, so it may raise a warning.
  bool get isActionable => level != null && !isStale;
}
