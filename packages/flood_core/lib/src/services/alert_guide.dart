import '../models/forecast.dart';
import '../models/risk_level.dart';
import '../models/station.dart';
import '../models/station_status.dart';

/// One button on "Alert me at a river level": a JPS level of this station
/// and the height in metres where it starts. The user picks a level; they
/// never have to know or type a height.
class LevelChoice {
  const LevelChoice(this.level, this.metres);
  final RiskLevel level;
  final double metres;

  /// Warning is suggested: early enough to get ready, rare enough not to
  /// become noise.
  bool get recommended => level == RiskLevel.warning;
}

/// Alert, Warning and Danger heights of a station. Empty when the station has
/// no official thresholds (rain gauges), so no river-level alert is offered.
List<LevelChoice> levelChoicesFor(Thresholds? t) => t == null
    ? const []
    : [
        LevelChoice(RiskLevel.alert, t.alert),
        LevelChoice(RiskLevel.warning, t.warning),
        LevelChoice(RiskLevel.danger, t.danger),
      ];

/// The level whose height is [metres] (within half a centimetre), or null for
/// a height that is not one of the station's levels (e.g. typed in an older
/// version of the app).
RiskLevel? levelAtHeight(Thresholds? t, double? metres) {
  if (t == null || metres == null) return null;
  for (final c in levelChoicesFor(t)) {
    if ((c.metres - metres).abs() < 0.005) return c.level;
  }
  return null;
}

/// Why a station is on the user's alert list.
enum AlertWhy { saved, nearest, nearby }

/// One row of the in-app "Alerts" page.
class ActiveAlert {
  ActiveAlert({required this.status, required this.level, required this.why, this.forecast});
  final StationStatus status;

  /// The level now, or for an expected alert the level the AI expects.
  final RiskLevel level;
  final AlertWhy why;

  /// Set for "expected in 3 hours" alerts, and for "now" alerts that have a
  /// forecast (to show whether the river is rising).
  final StationForecast? forecast;
}

class ActiveAlerts {
  ActiveAlerts({required this.now, required this.expected});

  /// Stations at the alert level or above right now, worst first.
  final List<ActiveAlert> now;

  /// Stations the AI expects to move up to Warning or Danger within its
  /// horizon (3 hours), worst first. Not official warnings.
  final List<ActiveAlert> expected;

  bool get isEmpty => now.isEmpty && expected.isEmpty;

  /// The alert for the red banner on Home: the worst current alert at
  /// Warning or above, if any.
  ActiveAlert? get banner {
    for (final a in now) {
      if (a.level.isAtLeast(RiskLevel.warning)) return a;
    }
    return null;
  }
}

/// The user's alerts without any setup: saved areas, the station nearest to
/// them and any station within [nearbyKm], at [minLevel] or above. Only
/// fresh readings count. Each station appears once.
ActiveAlerts activeAlerts({
  required List<StationStatus> statuses,
  required Set<String> savedIds,
  String? nearestId,
  Map<String, StationForecast> forecasts = const {},
  RiskLevel minLevel = RiskLevel.alert,
  double nearbyKm = 10,
}) {
  final floor = minLevel == RiskLevel.normal ? RiskLevel.alert : minLevel;
  final now = <ActiveAlert>[];
  final expected = <ActiveAlert>[];
  for (final s in statuses) {
    final AlertWhy why;
    if (savedIds.contains(s.station.id)) {
      why = AlertWhy.saved;
    } else if (s.station.id == nearestId) {
      why = AlertWhy.nearest;
    } else if (s.distanceKm != null && s.distanceKm! <= nearbyKm) {
      why = AlertWhy.nearby;
    } else {
      continue;
    }
    final f = forecasts[s.station.id];
    if (s.isActionable && s.level!.isAtLeast(floor)) {
      now.add(ActiveAlert(status: s, level: s.level!, why: why, forecast: f));
      continue;
    }
    // Expected: the forecast reaches Warning or above (and the alert level)
    // and is higher than the level now.
    final p = f?.predictedRisk;
    final current = s.isActionable ? s.level! : RiskLevel.normal;
    if (p != null && p.isAtLeast(RiskLevel.warning) && p.isAtLeast(floor) && p.index > current.index) {
      expected.add(ActiveAlert(status: s, level: p, why: why, forecast: f));
    }
  }
  int order(ActiveAlert a, ActiveAlert b) {
    var c = b.level.index.compareTo(a.level.index);
    if (c != 0) return c;
    c = a.why.index.compareTo(b.why.index);
    if (c != 0) return c;
    c = (a.status.distanceKm ?? double.infinity).compareTo(b.status.distanceKm ?? double.infinity);
    return c != 0 ? c : a.status.station.name.compareTo(b.status.station.name);
  }

  return ActiveAlerts(now: now..sort(order), expected: expected..sort(order));
}

/// The station with a position nearest to the user that has a fresh river or
/// rain reading, or null when none has a distance.
StationStatus? nearestStation(List<StationStatus> statuses, {bool riverOnly = false}) {
  StationStatus? best;
  for (final s in statuses) {
    if (s.distanceKm == null || s.isStale || s.reading == null) continue;
    if (riverOnly && (s.station.thresholds == null || s.riverLevel == null)) continue;
    if (best == null || s.distanceKm! < best.distanceKm!) best = s;
  }
  return best;
}
