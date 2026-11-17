import '../models/station_status.dart';
import '../util/geo.dart';
import 'followed_areas_service.dart';
import 'monitoring_service.dart';
import 'station_list_service.dart';
import 'warning_service.dart';

/// Everything the Home screen shows, loaded in one call.
class HomeData {
  HomeData({required this.areaCards, required this.highRisk, required this.generatedAt});

  /// One card per followed station, in the order the user followed them.
  /// Stale ones are included (the UI greys them out via `isStale`).
  final List<StationStatus> areaCards;

  /// "High-risk areas now": fresh stations at Alert or above, worst first.
  final List<StationStatus> highRisk;
  final DateTime generatedAt;
}

class HomeService {
  HomeService({
    required this.monitoring,
    required this.followed,
    this.highRiskLimit = 5,
  });

  final MonitoringService monitoring;
  final FollowedAreasService followed;
  final int highRiskLimit;

  Future<HomeData> load({GeoPoint? userLocation}) async {
    final all = await monitoring.loadStatuses(userLocation: userLocation);
    final byId = {for (final s in all) s.station.id: s};
    final ids = await followed.list();
    final warnings = const WarningService().active(all)..sort(compareByRisk);
    return HomeData(
      // A followed id that no longer exists in the feed is skipped, not an error.
      areaCards: [for (final id in ids) if (byId[id] != null) byId[id]!],
      highRisk: warnings.take(highRiskLimit).toList(),
      generatedAt: monitoring.now(),
    );
  }
}
