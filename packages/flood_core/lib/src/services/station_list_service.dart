import '../models/station_status.dart';

enum ListMode { rainfall, riverLevel }

enum SortBy { highestRisk, nearest }

/// Highest risk first. Stale or unknown stations always go to the bottom.
int compareByRisk(StationStatus a, StationStatus b) {
  int c = (a.isActionable ? 0 : 1).compareTo(b.isActionable ? 0 : 1);
  if (c != 0) return c;
  c = (b.level?.index ?? -1).compareTo(a.level?.index ?? -1);
  if (c != 0) return c;
  c = (b.percentToTarget ?? -1).compareTo(a.percentToTarget ?? -1);
  if (c != 0) return c;
  return a.station.name.compareTo(b.station.name);
}

/// Search, filter and sort for the Live Rainfall and Live River Level lists.
/// Pure functions: they never change the list passed in.
class StationListService {
  const StationListService();

  /// State names for the filter chips, A-Z.
  List<String> availableStates(List<StationStatus> all) =>
      ({for (final s in all) s.station.state}.toList()..sort());

  List<StationStatus> apply(
    List<StationStatus> all, {
    String query = '',
    String? state, // null = all states
    SortBy sortBy = SortBy.highestRisk,
    ListMode mode = ListMode.riverLevel,
    double? withinKm, // null = any distance; else only stations this close
  }) {
    final q = query.trim().toLowerCase();
    final result = all.where((s) {
      if (withinKm != null && (s.distanceKm == null || s.distanceKm! > withinKm)) return false;
      if (state != null && s.station.state.toLowerCase() != state.trim().toLowerCase()) {
        return false;
      }
      if (q.isEmpty) return true;
      return s.station.name.toLowerCase().contains(q) ||
          s.station.district.toLowerCase().contains(q) ||
          s.station.state.toLowerCase().contains(q);
    }).toList();

    final byMode = mode == ListMode.rainfall ? _compareByRainfall : compareByRisk;
    if (sortBy == SortBy.nearest) {
      result.sort((a, b) {
        final da = a.distanceKm, db = b.distanceKm;
        if (da == null && db == null) return byMode(a, b);
        if (da == null) return 1; // unknown distance goes last
        if (db == null) return -1;
        final c = da.compareTo(db);
        return c != 0 ? c : byMode(a, b);
      });
    } else {
      result.sort(byMode);
    }
    return result;
  }

  /// Heaviest rain first; stale or missing rainfall goes last.
  static int _compareByRainfall(StationStatus a, StationStatus b) {
    double key(StationStatus s) => (s.isStale || s.rainfall == null) ? -1 : s.rainfall!;
    final c = key(b).compareTo(key(a));
    return c != 0 ? c : a.station.name.compareTo(b.station.name);
  }
}
