import 'risk_level.dart';
import 'station.dart';
import 'station_reading.dart';

/// Why a station has no usable river level right now, so the app can say it
/// plainly (one message each). [none] when the river level is fresh and known.
enum DataIssue {
  /// Fine: a fresh river level compared with the JPS lines.
  none,

  /// Nothing received from this station yet.
  noReading,

  /// JPS shows something unusable now (offline, estimated, empty, wrong time,
  /// 0.00 m glitch): see [StationReading.problem]. The last good level, if
  /// still fresh, is shown with it.
  jpsProblem,

  /// The latest reading is over 3 hours old: JPS has not updated it.
  stale,

  /// A rain gauge only: this station measures no river level.
  rainOnly,

  /// A river gauge with no recent river level (only rain came in).
  noRiverReading,

  /// JPS has not set (or has not set in order) the warning levels, so the
  /// level is shown but no risk level can be given.
  noThresholds,
}

/// How recent the latest reading is, in three tiers shown on every card.
/// JPS normally updates every 15 minutes.
enum Freshness {
  /// Under 45 minutes old.
  live,

  /// 45 minutes to 3 hours old: the JPS portal is late, the latest reading
  /// is still shown and still used.
  delayed,

  /// Over 3 hours old (or no reading): not used for risk or alerts.
  stale,
}

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
    this.dataIssue = DataIssue.none,
  });

  /// Why there is no usable river level (none when there is one).
  final DataIssue dataIssue;

  /// What JPS shows instead of a usable level (with [DataIssue.jpsProblem]).
  ReadingProblem? get problem => reading?.problem;

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

  /// Readings at least this old are [Freshness.delayed].
  static const delayedAfter = Duration(minutes: 45);

  /// Live, delayed or stale. Stale uses the calculator's cutoff ([isStale]),
  /// so the tier always agrees with whether alerts are paused.
  Freshness get freshness {
    if (age == null || isStale) return Freshness.stale;
    return age! >= delayedAfter ? Freshness.delayed : Freshness.live;
  }

  /// True when the status is fresh and known, so it may raise a warning.
  bool get isActionable => level != null && !isStale;
}
