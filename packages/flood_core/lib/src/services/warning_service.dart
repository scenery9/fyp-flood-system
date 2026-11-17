import '../models/risk_level.dart';
import '../models/station_status.dart';

/// "Amaran": stations currently at Alert level or above.
/// Stale or unknown stations never appear, so old data cannot raise a warning.
class WarningService {
  const WarningService();

  List<StationStatus> active(
    List<StationStatus> all, {
    RiskLevel minLevel = RiskLevel.alert,
  }) {
    final result =
        all.where((s) => s.isActionable && s.level!.isAtLeast(minLevel)).toList();
    result.sort((a, b) {
      int c = b.level!.index.compareTo(a.level!.index); // highest level first
      if (c != 0) return c;
      c = b.reading!.time.compareTo(a.reading!.time); // then newest first
      return c != 0 ? c : a.station.name.compareTo(b.station.name);
    });
    return result;
  }
}
