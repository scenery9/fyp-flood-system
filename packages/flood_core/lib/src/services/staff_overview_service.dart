import '../models/damage_report.dart';
import '../models/district.dart';
import '../models/resources.dart';
import '../models/staff.dart';
import '../models/station_status.dart';
import 'access_control.dart';
import 'damage_report_service.dart';
import 'evacuation_service.dart';
import 'monitoring_service.dart';
import 'resource_service.dart';
import 'station_list_service.dart';
import 'warning_service.dart';

class StaffOverview {
  StaffOverview({
    required this.pendingReports,
    required this.expiringItems,
    required this.supplyAlerts,
    required this.sheltersOpen,
    required this.sheltersFull,
    required this.riskNearby,
  });
  final int pendingReports;
  final List<InventoryItem> expiringItems;
  final List<SupplyAlert> supplyAlerts;
  final int sheltersOpen;
  final int sheltersFull;

  /// Active flood warnings near the staff member's resource point, or in a
  /// Coordinator's district (all active warnings for a Super Admin).
  final List<StationStatus> riskNearby;
}

/// The staff "Overview" screen, loaded in one call.
class StaffOverviewService {
  StaffOverviewService({
    required this.monitoring,
    required this.resources,
    required this.reports,
    required this.evacuation,
    this.nearbyKm = 50,
  });
  final MonitoringService monitoring;
  final ResourceService resources;
  final DamageReportService reports;
  final EvacuationService evacuation;
  final double nearbyKm;

  Future<StaffOverview> load(StaffSession? session) async {
    final me = AccessControl.require(session, Permission.viewOperations);
    final home = me.assignedResourcePointId == null
        ? null
        : await resources.points.byId(me.assignedResourcePointId!);
    final statuses = await monitoring.loadStatuses(userLocation: home?.location);
    var risk = const WarningService().active(statuses);
    if (me.role == StaffRole.coordinator) {
      risk = risk.where((s) => normaliseDistrict(s.station.district) == me.assignedDistrict).toList();
    } else if (home != null) {
      risk = risk.where((s) => s.distanceKm != null && s.distanceKm! <= nearbyKm).toList();
    }
    final centres = await evacuation.listForStaff(session);
    return StaffOverview(
        pendingReports: (await reports.counts(session))[ReportStatus.pending]!,
        expiringItems: await resources.expiringItems(session),
        supplyAlerts: await resources.supplyAlerts(session),
        sheltersOpen: centres.where((c) => c.isOpen).length,
        sheltersFull: centres.where((c) => c.isOpen && c.isFull).length,
        riskNearby: risk..sort(compareByRisk));
  }
}
