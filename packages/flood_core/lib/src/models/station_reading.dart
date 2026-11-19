/// One reading from a station. A null value means "no usable data".
class StationReading {
  StationReading({
    required this.stationId,
    required this.time,
    this.rainfallMmPerHr,
    this.riverLevelM,
    DateTime? rainfallTime,
  }) : rainfallTime = rainfallTime ?? time;

  /// Builds a reading from raw feed values and removes sensor fault codes.
  /// JPS feeds use -9999 (sensor offline) and -8888 (estimated value);
  /// both are treated as missing. Negative rainfall is also invalid.
  factory StationReading.fromRaw({
    required String stationId,
    required DateTime time,
    double? rainfall,
    double? riverLevel,
    DateTime? rainfallTime,
  }) {
    bool bad(double? v) => v == null || v.isNaN || v.isInfinite || v <= -8888;
    return StationReading(
      stationId: stationId,
      time: time,
      rainfallMmPerHr: (bad(rainfall) || rainfall! < 0) ? null : rainfall,
      riverLevelM: bad(riverLevel) ? null : riverLevel,
      rainfallTime: rainfallTime,
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
}
