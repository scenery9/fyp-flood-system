import '../models/risk_level.dart';
import '../models/station.dart';
import '../models/station_reading.dart';
import '../models/station_status.dart';
import '../util/geo.dart';

/// Turns a station and its latest reading into a [StationStatus].
/// Rule-based for now (river level vs thresholds). The AI prediction is a
/// separate, later feature and will not change this class.
class RiskCalculator {
  const RiskCalculator({this.staleAfter = const Duration(hours: 3)});

  /// Readings older than this are marked stale ("Lapuk").
  final Duration staleAfter;

  StationStatus assess(
    Station station,
    StationReading? reading, {
    required DateTime now,
    GeoPoint? userLocation,
  }) {
    Duration? age;
    if (reading != null) {
      final diff = now.difference(reading.time);
      age = diff.isNegative ? Duration.zero : diff; // clock skew: never negative
    }
    final isStale = age != null && age > staleAfter;

    final river = reading?.riverLevelM;
    final t = station.thresholds;
    RiskLevel? level;
    RiskLevel? target;
    double? percent;

    if (river != null && t != null) {
      double targetValue;
      if (river >= t.danger) {
        level = RiskLevel.danger;
        target = RiskLevel.danger;
        targetValue = t.danger;
      } else if (river >= t.warning) {
        level = RiskLevel.warning;
        target = RiskLevel.danger;
        targetValue = t.danger;
      } else if (river >= t.alert) {
        level = RiskLevel.alert;
        target = RiskLevel.warning;
        targetValue = t.warning;
      } else {
        level = RiskLevel.normal;
        target = RiskLevel.alert;
        targetValue = t.alert;
      }
      percent = ((river - t.normal) / (targetValue - t.normal) * 100).clamp(0, 100).toDouble();
    }

    final loc = station.location;
    return StationStatus(
      station: station,
      reading: reading,
      level: level,
      targetLevel: target,
      percentToTarget: percent,
      isStale: isStale,
      age: age,
      rainIntensity: RainIntensity.fromMm(reading?.rainfallMmPerHr),
      distanceKm: (userLocation != null && loc != null) ? distanceKm(userLocation, loc) : null,
      mainCause: _cause(reading, t, level, target, percent, isStale, age),
      dataIssue: issueOf(reading, t, isStale),
    );
  }

  /// Which plain message explains a missing or unusable river level. A JPS
  /// problem comes first: it says why no newer reading arrived.
  static DataIssue issueOf(StationReading? reading, Thresholds? t, bool isStale) {
    if (reading == null) return DataIssue.noReading;
    if (reading.problem != null) return DataIssue.jpsProblem;
    if (isStale) return DataIssue.stale;
    if (reading.riverLevelM == null) {
      return t == null && reading.rainfallMmPerHr != null ? DataIssue.rainOnly : DataIssue.noRiverReading;
    }
    if (t == null) return DataIssue.noThresholds;
    return DataIssue.none;
  }

  static String problemText(ReadingProblem p) => switch (p) {
        ReadingProblem.offline => 'JPS shows the river sensor as offline',
        ReadingProblem.estimated => 'JPS shows an estimated river level, not a measured one',
        ReadingProblem.noValue => 'JPS shows no river level',
        ReadingProblem.oldTime => 'JPS is still showing a river reading over a day old',
        ReadingProblem.badTime => 'JPS shows a river reading with a wrong time',
        ReadingProblem.glitch => 'JPS shows 0.00 m, which looks like an error',
      };

  String _cause(StationReading? reading, Thresholds? t, RiskLevel? level,
      RiskLevel? target, double? percent, bool isStale, Duration? age) {
    if (reading == null) return 'No readings received yet';
    if (reading.problem != null) {
      final last = reading.riverLevelM == null ? '' : '; last good reading ${_ago(age!)} ago';
      return '${problemText(reading.problem!)}$last';
    }
    if (isStale) return 'Data is old (last update ${_ago(age!)} ago)';
    if (t == null) return 'Rainfall-only station (no river thresholds)';
    if (level == null) return 'River level sensor has no data';
    if (level == RiskLevel.danger) return 'River level has reached Danger level';
    return 'River level is ${percent!.round()}% of the way to ${target!.labelEn} level';
  }

  String _ago(Duration d) {
    if (d.inDays >= 1) return '${d.inDays} day(s)';
    if (d.inHours >= 1) return '${d.inHours} hour(s)';
    return '${d.inMinutes} min';
  }
}
