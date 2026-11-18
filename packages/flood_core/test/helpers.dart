import 'dart:convert';

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

/// District used by the test staff. [kDistrict] is "theirs"; [kOtherDistrict] is not.
const kDistrict = 'KLANG';
const kOtherDistrict = 'SEPANG';

StaffSession sess(StaffRole role,
        {String id = 'staff-1', String? point, String? district, String? pointDistrict,
        bool active = true}) =>
    StaffSession(
        StaffAccount(
            id: id, fullName: 'Test Staff', username: id, role: role,
            assignedResourcePointId: point, assignedDistrict: district, active: active),
        resourcePointDistrict: pointDistrict);

final admin = sess(StaffRole.superAdmin, id: 'admin');

/// Coordinator for [kDistrict].
final coordinator = sess(StaffRole.coordinator, id: 'coord', district: kDistrict);

/// Field officer at resource point 'res-1' (the first point a test adds), in [kDistrict].
final officer = sess(StaffRole.fieldOfficer, id: 'officer', point: 'res-1', pointDistrict: kDistrict);

/// Everything wired together with empty in-memory storage and a fixed clock.
class World {
  World({StationRepository? repo}) : repo = repo ?? SampleStationRepository(clock: fixedClock) {
    monitoring = MonitoringService(repository: this.repo, clock: fixedClock);
    evacuation = EvacuationService(points: evacTable, newId: sequentialIds('evac'));
    headcount = HeadcountService(
        entries: headcountTable, evacuationPoints: evacTable, newId: sequentialIds('hc'), clock: fixedClock);
    reports = DamageReportService(
        reports: reportTable, newId: sequentialIds('rep'), clock: fixedClock,
        locateDistrict: (_) async => reportDistrict);
    resources = ResourceService(
        points: pointTable, items: itemTable, catalogue: catalogueTable,
        evacuationPoints: evacTable, newId: sequentialIds('res'), clock: fixedClock);
    staff = StaffAccountService(accounts: staffTable, resourcePoints: pointTable);
    alerts = AlertService(
        rules: ruleTable, firedState: firedTable, repository: this.repo, newId: sequentialIds('rule'),
        clock: () => clock);
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

  /// Clock for My Alerts; tests move it forward to check repeat timing.
  DateTime clock = kNow;

  /// District given to new damage reports (stands in for the nearest-station lookup).
  String? reportDistrict = kDistrict;
  final ruleTable = MemoryTable<AlertRule>();
  final firedTable = MemoryTable<AlertState>();
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

// ---------------- round 6 helpers: a fake Supabase server ----------------

class HttpCall {
  HttpCall(this.method, this.uri, this.headers, this.body);
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final String? body;
  Object? get json => body == null ? null : jsonDecode(body!);
}

/// Answers HTTP requests by path. Sign-in is answered automatically with
/// tokens access-1, access-2, ... unless the test sets its own reply.
class FakeHttp {
  final calls = <HttpCall>[];
  final _replies = <String, List<HttpReply>>{};
  bool offline = false;
  int signIns = 0;
  int refreshes = 0;

  /// Next replies for [path] (the last one repeats).
  void reply(String path, int status, String body) =>
      (_replies[path] ??= []).add(HttpReply(status, body));

  Future<HttpReply> send(String method, Uri uri, {Map<String, String> headers = const {}, String? body}) async {
    calls.add(HttpCall(method, uri, headers, body));
    if (offline) throw StateError('no internet');
    final queued = _replies[uri.path];
    if (queued != null && queued.isNotEmpty) {
      return queued.length > 1 ? queued.removeAt(0) : queued.first;
    }
    if (uri.path == '/auth/v1/signup') return _session(++signIns + refreshes, 'user-$signIns');
    if (uri.path == '/auth/v1/token') return _session(signIns + ++refreshes, 'user-$signIns');
    return const HttpReply(404, '{"message": "not found"}');
  }

  HttpReply _session(int n, String user) => HttpReply(200, jsonEncode({
        'access_token': 'access-$n',
        'refresh_token': 'refresh-$n',
        'expires_in': 3600,
        'user': {'id': user},
      }));

  final authStore = InMemorySettingsStore();
  DateTime now = kNow;

  SupabaseApi api({bool signedIn = true}) {
    const config = SupabaseConfig(url: 'https://demo.supabase.co', publishableKey: 'sb_publishable_test');
    return SupabaseApi(
        config: config, send: send,
        auth: signedIn ? SupabaseAuth(config: config, send: send, store: authStore, clock: () => now) : null);
  }
}
