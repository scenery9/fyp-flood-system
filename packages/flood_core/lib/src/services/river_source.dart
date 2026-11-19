import '../models/station_status.dart';
import '../util/geo.dart';

/// The river reading to show for a saved area: its own river gauge, or the
/// nearest river gauge with a recent reading when it has none (a rain gauge,
/// such as most Melaka "RF" stations) or its own gauge has gone quiet.
class RiverSource {
  RiverSource({required this.gauge, this.distanceKm});

  /// The station whose river level, risk level and thresholds are shown.
  final StationStatus gauge;

  /// Distance to [gauge]; null when it is the area's own gauge.
  final double? distanceKm;

  bool get isOwnGauge => distanceKm == null;
}

/// True when [s] has a river reading that can set a risk level now.
bool hasUsableRiver(StationStatus s) =>
    s.station.thresholds != null && s.riverLevel != null && s.level != null && !s.isStale;

/// River for [station]: its own gauge when usable, otherwise the nearest
/// other usable river gauge within [maxKm]. Null when neither exists.
RiverSource? riverSourceFor(StationStatus station, Iterable<StationStatus> all, {double maxKm = 10}) {
  if (hasUsableRiver(station)) return RiverSource(gauge: station);
  final here = station.station.location;
  if (here == null) return null;
  RiverSource? best;
  for (final s in all) {
    if (s.station.id == station.station.id || !hasUsableRiver(s)) continue;
    final there = s.station.location;
    if (there == null) continue;
    final d = distanceKm(here, there);
    if (d > maxKm) continue;
    if (best == null || d < best.distanceKm!) best = RiverSource(gauge: s, distanceKm: d);
  }
  return best;
}
