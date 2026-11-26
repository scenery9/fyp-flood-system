/// What JPS showed instead of a usable river level (supabase/reading_problems.sql).
enum ReadingProblem {
  /// -9999: the sensor is offline.
  offline,

  /// -8888: an estimated value, not a measurement.
  estimated,

  /// No level at all.
  noValue,

  /// JPS still shows a reading over a day old.
  oldTime,

  /// The reading's time is in the future.
  badTime,

  /// 0.00 m, far from the reading before it.
  glitch;

  /// The value stored by the logger ("offline", "no_value", ...), or null.
  static ReadingProblem? parse(Object? v) => switch ('${v ?? ''}'.trim()) {
        'offline' => offline,
        'estimated' => estimated,
        'no_value' => noValue,
        'old_time' => oldTime,
        'bad_time' => badTime,
        'glitch' => glitch,
        _ => null,
      };
}

/// One reading from a station. A null value means "no usable data".
class StationReading {
  StationReading({
    required this.stationId,
    required this.time,
    this.rainfallMmPerHr,
    this.riverLevelM,
    DateTime? rainfallTime,
    this.problem,
    this.problemAt,
  }) : rainfallTime = rainfallTime ?? time;

  /// Builds a reading from raw feed values and removes sensor fault codes.
  /// JPS feeds use -9999 (sensor offline) and -8888 (estimated value);
  /// both are treated as missing, and remembered as [problem] so the app can
  /// say why. Negative rainfall is also invalid. River levels below 0 are real
  /// (tide gates and river mouths) and are kept.
  factory StationReading.fromRaw({
    required String stationId,
    required DateTime time,
    double? rainfall,
    double? riverLevel,
    DateTime? rainfallTime,
    ReadingProblem? problem,
    DateTime? problemAt,
  }) {
    bool bad(double? v) => v == null || v.isNaN || v.isInfinite || v <= -8888;
    final fault = riverLevel == null || riverLevel.isNaN || riverLevel.isInfinite
        ? null
        : riverLevel <= -9000
            ? ReadingProblem.offline
            : riverLevel <= -8888
                ? ReadingProblem.estimated
                : null;
    return StationReading(
      stationId: stationId,
      time: time,
      rainfallMmPerHr: (bad(rainfall) || rainfall! < 0) ? null : rainfall,
      riverLevelM: bad(riverLevel) ? null : riverLevel,
      rainfallTime: rainfallTime,
      problem: problem ?? fault,
      problemAt: problem != null ? problemAt : (fault != null ? time : null),
    );
  }

  final String stationId;

  /// When the river level was read (or the rain, for a rain-only station).
  final DateTime time;

  /// When the rain was read. JPS logs river and rain separately, so this can
  /// differ from [time]; it is the same as [time] when not given.
  final DateTime rainfallTime;
  final double? rainfallMmPerHr;
  final double? riverLevelM;

  /// What JPS shows now instead of a usable river level, when that is newer
  /// than [riverLevelM] (null when the latest JPS value was fine).
  final ReadingProblem? problem;

  /// When [problem] was seen.
  final DateTime? problemAt;
}
