import '../models/risk_level.dart';
import '../models/station_status.dart';
import '../util/geo.dart';

/// The rain reading to show with a station: its own gauge, or the nearest
/// gauge with a recent reading when it has none (or its gauge is silent).
class RainSource {
  RainSource({required this.gauge, required this.mmPerHr, required this.age, this.distanceKm});

  /// The station the rain was measured at (the station itself when [isOwnGauge]).
  final StationStatus gauge;

  /// JPS 1-hour rainfall (rolling 60-minute total), mm.
  final double mmPerHr;
  final Duration age;

  /// Distance to the gauge; null when it is the station's own gauge.
  final double? distanceKm;

  bool get isOwnGauge => distanceKm == null;
  RainIntensity get intensity => RainIntensity.fromMm(mmPerHr)!;
}

/// Rain for [station]: its own reading when recent, otherwise the nearest
/// other station within [maxKm] whose rain reading is recent. Null when
/// neither exists ("no rain data now"). A reading older than [maxAge] is not
/// used, the same limit as a stale river reading.
RainSource? rainSourceFor(
  StationStatus station,
  Iterable<StationStatus> all, {
  required DateTime now,
  double maxKm = 10,
  Duration maxAge = const Duration(hours: 3),
}) {
  Duration? freshAge(StationStatus s) {
    final r = s.reading;
    if (r?.rainfallMmPerHr == null) return null;
    final age = now.difference(r!.rainfallTime);
    // A little clock skew is fine; far-future readings are not trusted.
    if (age > maxAge || age < const Duration(minutes: -10)) return null;
    return age.isNegative ? Duration.zero : age;
  }

  final own = freshAge(station);
  if (own != null) return RainSource(gauge: station, mmPerHr: station.reading!.rainfallMmPerHr!, age: own);

  final here = station.station.location;
  if (here == null) return null;
  RainSource? best;
  for (final s in all) {
    if (s.station.id == station.station.id) continue;
    final there = s.station.location;
    final age = freshAge(s);
    if (there == null || age == null) continue;
    final d = distanceKm(here, there);
    if (d > maxKm) continue;
    if (best == null || d < best.distanceKm!) {
      best = RainSource(gauge: s, mmPerHr: s.reading!.rainfallMmPerHr!, age: age, distanceKm: d);
    }
  }
  return best;
}
