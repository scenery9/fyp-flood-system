import '../models/risk_level.dart';
import '../models/station_status.dart';
import '../risk/joint_risk.dart';
import '../util/geo.dart';
import 'followed_areas_service.dart';
import 'monitoring_service.dart';
import 'rain_outlook_source.dart';
import 'station_list_service.dart';
import 'warning_service.dart';

/// Everything the Home screen shows, loaded in one call.
class HomeData {
  HomeData({required this.areaCards, required this.highRisk, required this.generatedAt, this.joint = const {}});

  /// One card per followed station, in the order the user followed them.
  /// Stale ones are included (the UI greys them out via `isStale`).
  final List<StationStatus> areaCards;

  /// "High-risk areas now": fresh stations at Alert or above, worst first; then
  /// stations whose rain OUTLOOK is Alert or above (river plus forecast rain,
  /// [JointAssessment.raised]), which the UI marks as a forecast.
  final List<StationStatus> highRisk;
  final DateTime generatedAt;

  /// River level joined with the 3-day rain outlook, per station id (empty without a source).
  final Map<String, JointAssessment> joint;

  bool isForecastOnly(String stationId) {
    final j = joint[stationId];
    return j != null && j.raised && !(j.measured?.isAtLeast(RiskLevel.alert) ?? false);
  }
}

class HomeService {
  HomeService({
    required this.monitoring,
    required this.followed,
    this.highRiskLimit = 5,
    this.jointRisk,
  });

  final MonitoringService monitoring;
  final FollowedAreasService followed;
  final int highRiskLimit;

  /// Optional: joins each station with its 3-day rain outlook (Open-Meteo + MET Malaysia).
  final JointRiskService? jointRisk;

  Future<HomeData> load({GeoPoint? userLocation}) async {
    final all = await monitoring.loadStatuses(userLocation: userLocation);
    final byId = {for (final s in all) s.station.id: s};
    final ids = await followed.list();
    final warnings = const WarningService().active(all)..sort(compareByRisk);
    final joint = jointRisk == null ? const <String, JointAssessment>{} : await jointRisk!.assessAll(all);
    final shown = {for (final w in warnings) w.station.id};
    final byOutlook = [
      for (final s in all)
        if (!shown.contains(s.station.id) &&
            (joint[s.station.id]?.raised ?? false) &&
            joint[s.station.id]!.outlook!.isAtLeast(RiskLevel.alert))
          s
    ]..sort((a, b) => joint[b.station.id]!.outlook!.index.compareTo(joint[a.station.id]!.outlook!.index));
    return HomeData(
      // A followed id that no longer exists in the feed is skipped, not an error.
      areaCards: [for (final id in ids) if (byId[id] != null) byId[id]!],
      highRisk: [...warnings, ...byOutlook].take(highRiskLimit).toList(),
      generatedAt: monitoring.now(),
      joint: joint,
    );
  }
}
