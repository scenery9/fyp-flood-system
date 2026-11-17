import 'package:flood_core/flood_core.dart';

/// Fixed "now" so every test gives the same result on any day.
final DateTime kNow = DateTime.utc(2026, 11, 17, 3, 0);
DateTime fixedClock() => kNow;

Thresholds th() => Thresholds(normal: 10, alert: 12, warning: 14, danger: 16);

Station st(String id,
        {String? name, String district = 'D1', String state = 'Johor',
        GeoPoint? loc, bool thresholds = true}) =>
    Station(id: id, name: name ?? id, district: district, state: state,
        location: loc, thresholds: thresholds ? th() : null);

StationReading rd(String id, {int minAgo = 10, double? rain, double? river}) =>
    StationReading(stationId: id, time: kNow.subtract(Duration(minutes: minAgo)),
        rainfallMmPerHr: rain, riverLevelM: river);

/// Test repository with data you choose. Set [fail] to simulate no internet.
class FakeRepository implements StationRepository {
  FakeRepository(this.stations, List<StationReading> readings)
      : readings = {for (final r in readings) r.stationId: r};
  List<Station> stations;
  Map<String, StationReading> readings;
  bool fail = false;

  @override
  Future<List<Station>> getStations() async {
    if (fail) throw StateError('network down');
    return stations;
  }

  @override
  Future<Map<String, StationReading>> getLatestReadings() async {
    if (fail) throw StateError('network down');
    return readings;
  }
}

StationStatus assess(Station s, StationReading? r, {GeoPoint? user}) =>
    const RiskCalculator().assess(s, r, now: kNow, userLocation: user);

// ---------------- round 2 helpers ----------------

StaffSession sess(StaffRole role, {String id = 'staff-1', String? point, bool active = true}) =>
    StaffSession(StaffAccount(
        id: id, fullName: 'Test Staff', username: id, role: role,
        assignedResourcePointId: point, active: active));

final admin = sess(StaffRole.superAdmin, id: 'admin');
final coordinator = sess(StaffRole.coordinator, id: 'coord');
final officer = sess(StaffRole.fieldOfficer, id: 'officer');

/// Everything wired together with empty in-memory storage and a fixed clock.
class World {
  World({StationRepository? repo}) : repo = repo ?? SampleStationRepository(clock: fixedClock) {
    monitoring = MonitoringService(repository: this.repo, clock: fixedClock);
    evacuation = EvacuationService(points: evacTable, newId: sequentialIds('evac'));
    headcount = HeadcountService(
        entries: headcountTable, evacuationPoints: evacTable, newId: sequentialIds('hc'), clock: fixedClock);
    reports = DamageReportService(reports: reportTable, newId: sequentialIds('rep'), clock: fixedClock);
    resources = ResourceService(
        points: pointTable, items: itemTable, catalogue: catalogueTable,
        evacuationPoints: evacTable, newId: sequentialIds('res'), clock: fixedClock);
    staff = StaffAccountService(accounts: staffTable, resourcePoints: pointTable);
    alerts = AlertService(
        rules: ruleTable, firedState: firedTable, repository: this.repo, newId: sequentialIds('rule'));
    overview = StaffOverviewService(
        monitoring: monitoring, resources: resources, reports: reports, evacuation: evacuation);
    assistant = AssistantService(monitoring: monitoring, evacuation: evacuation);
    map = MapService(monitoring: monitoring, evacuation: evacuation, resources: resources);
  }
  final StationRepository repo;
  final evacTable = MemoryTable<EvacuationPoint>();
  final headcountTable = MemoryTable<HeadcountEntry>();
  final reportTable = MemoryTable<DamageReport>();
  final pointTable = MemoryTable<ResourcePoint>();
  final itemTable = MemoryTable<InventoryItem>();
  final catalogueTable = MemoryTable<CatalogueUnit>();
  final staffTable = MemoryTable<StaffAccount>();
  final ruleTable = MemoryTable<AlertRule>();
  final firedTable = MemoryTable<bool>();
  late final MonitoringService monitoring;
  late final EvacuationService evacuation;
  late final HeadcountService headcount;
  late final DamageReportService reports;
  late final ResourceService resources;
  late final StaffAccountService staff;
  late final AlertService alerts;
  late final StaffOverviewService overview;
  late final AssistantService assistant;
  late final MapService map;

  Future<DamageReport> report({String by = 'user-1', int daysAgo = 0}) => reports.submit(
      reporterId: by, location: GeoPoint(2.5, 102.8),
      incidentDate: kNow.subtract(Duration(days: daysAgo)),
      type: DamageType.house, severity: DamageSeverity.moderate);
}
