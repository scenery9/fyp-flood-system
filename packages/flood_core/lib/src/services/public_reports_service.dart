import 'dart:convert';

import '../data/supabase_api.dart';
import '../errors.dart';
import '../models/damage_report.dart';
import '../util/geo.dart';
import 'settings_service.dart';

// =====================================================================
// Public flood reports ("Flooding here now" or "Damage") and the
// household's "We're coming" headcount for a relief centre.
// Same rules as supabase/public_reports.sql, which is what counts live.
// =====================================================================

/// "Flooding here now" (a sighting) or damage that has happened.
enum ReportKind {
  floodingNow('sighting'),
  damage('damage');

  const ReportKind(this.code);

  /// Name used by the server.
  final String code;

  static ReportKind? fromCode(Object? v) {
    for (final k in values) {
      if (k.code == v) return k;
    }
    return null;
  }
}

/// Water depth by body height, so nobody has to measure or type centimetres.
enum DepthBand {
  ankle(0.15),
  knee(0.5),
  waist(1.0),
  chest(1.3),
  unsure(null);

  const DepthBand(this.metres);

  /// Rough depth sent to staff with the band (null = not sure).
  final double? metres;

  static DepthBand fromName(Object? v) {
    for (final d in values) {
      if (d.name == v) return d;
    }
    return unsure;
  }
}

/// What the user filled in on "Report flooding".
class FloodReportDraft {
  FloodReportDraft({
    required this.kind,
    required this.location,
    required this.occurredAt,
    required this.clientRef,
    this.depth = DepthBand.unsure,
    this.type,
    this.severity,
    this.description = '',
  });
  final ReportKind kind;
  final GeoPoint location;
  final DateTime occurredAt;

  /// Made once per form, so sending again after a network failure cannot
  /// create a second report.
  final String clientRef;
  final DepthBand depth;

  /// Damage reports only.
  final DamageType? type;
  final DamageSeverity? severity;
  final String description;

  Map<String, Object?> toJson() => {
        'kind': kind.code,
        'lat': location.lat,
        'lon': location.lon,
        'occurred_at': occurredAt.toUtc().toIso8601String(),
        'client_ref': clientRef,
        'depth_band': depth.name,
        'depth_m': depth.metres,
        if (kind == ReportKind.damage) 'type': type?.name,
        if (kind == ReportKind.damage) 'severity': severity?.name,
        'description': description.trim(),
      };
}

/// One of the user's own reports ("My reports").
class MyReport {
  MyReport({
    required this.id,
    required this.kind,
    required this.occurredAt,
    required this.status,
    this.type,
    this.severity,
    this.depth = DepthBand.unsure,
    this.staffNote,
  });
  final String id;
  final ReportKind kind;
  final DateTime occurredAt;
  final ReportStatus status;
  final DamageType? type;
  final DamageSeverity? severity;
  final DepthBand depth;

  /// Note from the officer (always given when a report is rejected).
  final String? staffNote;

  Map<String, Object?> toJson() => {
        'id': id,
        'kind': kind.code,
        'occurred_at': occurredAt.toUtc().toIso8601String(),
        'status': status.name,
        'type': type?.name,
        'severity': severity?.name,
        'depth_band': depth.name,
        'staff_note': staffNote,
      };

  /// Null for a row the app cannot read (skipped, never an error).
  static MyReport? fromJson(Object? j) {
    try {
      final m = j as Map;
      T? pick<T extends Enum>(List<T> values, Object? name) {
        for (final v in values) {
          if (v.name == name) return v;
        }
        return null;
      }

      final kind = ReportKind.fromCode(m['kind']) ?? ReportKind.damage;
      final note = m['staff_note'];
      return MyReport(
          id: '${m['id']}',
          kind: kind,
          occurredAt: DateTime.parse('${m['occurred_at']}').toLocal(),
          status: pick(ReportStatus.values, m['status']) ?? ReportStatus.pending,
          type: pick(DamageType.values, m['type']),
          severity: pick(DamageSeverity.values, m['severity']),
          depth: DepthBand.fromName(m['depth_band']),
          staffNote: note is String && note.trim().isNotEmpty ? note.trim() : null);
    } catch (_) {
      return null;
    }
  }
}

/// Where the household is on its way to the relief centre.
enum HeadcountStatus {
  onTheWay('on_the_way'),
  arrived('arrived'),
  left('left');

  const HeadcountStatus(this.code);
  final String code;

  static HeadcountStatus fromCode(Object? v) {
    for (final s in values) {
      if (s.code == v) return s;
    }
    return onTheWay;
  }
}

/// Things the household will need at the centre (chips, no typing).
enum SpecialNeed {
  wheelchair('wheelchair'),
  power('power'),
  babyFormula('formula'),
  diapers('diapers'),
  coldMedicine('cold_medicine'),
  pet('pet'),
  other('other');

  const SpecialNeed(this.code);
  final String code;

  static SpecialNeed? fromCode(Object? v) {
    for (final s in values) {
      if (s.code == v) return s;
    }
    return null;
  }
}

/// "Tell this centre we're coming".
class HeadcountDraft {
  HeadcountDraft({
    required this.total,
    this.babies = 0,
    this.children = 0,
    this.adults = 0,
    this.elderly = 0,
    this.reducedMobility = 0,
    this.pets = 0,
    this.dailyMedicine = false,
    this.powerMachine = false,
    this.needs = const {},
    this.otherNeed = '',
    this.centreId,
    this.location,
    this.status = HeadcountStatus.onTheWay,
  });
  final int total;

  /// Babies or toddlers, children, adults and older people: together never
  /// more than [total].
  final int babies;
  final int children;
  final int adults;
  final int elderly;
  final int reducedMobility;
  final int pets;
  final bool dailyMedicine;

  /// Someone uses oxygen or a machine that needs power.
  final bool powerMachine;
  final Set<SpecialNeed> needs;

  /// Only sent when [SpecialNeed.other] is chosen.
  final String otherNeed;

  /// The centre the user chose. When it is not a centre the server knows
  /// (e.g. sample centres), the server picks the nearest open centre with
  /// space from [location]. The location itself is not stored.
  final String? centreId;
  final GeoPoint? location;
  final HeadcountStatus status;

  Map<String, Object?> toJson() => {
        'total': total,
        'babies': babies,
        'children': children,
        'adults': adults,
        'elderly': elderly,
        'reduced_mobility': reducedMobility,
        'pets': pets,
        'daily_medicine': dailyMedicine,
        'power_machine': powerMachine,
        'needs': [for (final n in SpecialNeed.values) if (needs.contains(n)) n.code],
        'other_need': needs.contains(SpecialNeed.other) ? otherNeed.trim() : '',
        'centre_id': centreId,
        if (location != null) 'lat': location!.lat,
        if (location != null) 'lon': location!.lon,
        'status': status.code,
      };
}

/// The household's headcount as the centre sees it.
class MyHeadcount {
  MyHeadcount({
    required this.total,
    required this.babies,
    required this.elderly,
    required this.reducedMobility,
    required this.needs,
    this.children = 0,
    this.adults = 0,
    this.pets = 0,
    this.dailyMedicine = false,
    this.powerMachine = false,
    required this.status,
    required this.updatedAt,
    required this.expiresAt,
    this.otherNeed = '',
    this.centreId,
    this.centreName,
  });
  final int total;
  final int babies;
  final int elderly;
  final int reducedMobility;
  final int children;
  final int adults;
  final int pets;
  final bool dailyMedicine;
  final bool powerMachine;
  final Set<SpecialNeed> needs;
  final String otherNeed;
  final HeadcountStatus status;
  final DateTime updatedAt;

  /// After this the count is no longer included in the centre's numbers,
  /// so people who forget to tap "Left" are not counted for ever.
  final DateTime expiresAt;
  final String? centreId;
  final String? centreName;

  bool isCurrent(DateTime now) => status != HeadcountStatus.left && now.isBefore(expiresAt);

  Map<String, Object?> toJson() => {
        'total': total,
        'babies': babies,
        'elderly': elderly,
        'reduced_mobility': reducedMobility,
        'children': children,
        'adults': adults,
        'pets': pets,
        'daily_medicine': dailyMedicine,
        'power_machine': powerMachine,
        'needs': [for (final n in needs) n.code],
        'other_need': otherNeed,
        'status': status.code,
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'expires_at': expiresAt.toUtc().toIso8601String(),
        'centre_id': centreId,
        'centre_name': centreName,
      };

  /// Null for a reply the app cannot read.
  static MyHeadcount? fromJson(Object? j) {
    try {
      final m = j as Map;
      int n(String k) => (m[k] as num).toInt();
      int opt(String k) => m[k] is num ? (m[k] as num).toInt() : 0;
      final centre = m['centre_id'] ?? m['evacuation_point_id'];
      final name = m['centre_name'];
      return MyHeadcount(
          total: n('total'),
          babies: n('babies'),
          elderly: n('elderly'),
          reducedMobility: n('reduced_mobility'),
          children: opt('children'),
          adults: opt('adults'),
          pets: opt('pets'),
          dailyMedicine: m['daily_medicine'] == true,
          powerMachine: m['power_machine'] == true,
          needs: {
            for (final c in (m['needs'] as List?) ?? const [])
              if (SpecialNeed.fromCode(c) != null) SpecialNeed.fromCode(c)!,
          },
          otherNeed: '${m['other_need'] ?? ''}',
          status: HeadcountStatus.fromCode(m['status']),
          updatedAt: DateTime.parse('${m['updated_at']}').toLocal(),
          expiresAt: DateTime.parse('${m['expires_at']}').toLocal(),
          centreId: centre == null ? null : '$centre',
          centreName: name is String && name.isNotEmpty ? name : null);
    } catch (_) {
      return null;
    }
  }
}

/// Where reports and headcounts go.
abstract class PublicReportsBackend {
  /// True when relief staff will see what is sent (Supabase). False for the
  /// phone-only version used without Supabase, so the app can say so.
  bool get reachesStaff;

  Future<void> submitReport(FloodReportDraft draft);
  Future<List<MyReport>> myReports();
  Future<MyHeadcount> submitHeadcount(HeadcountDraft draft);
  Future<MyHeadcount?> myHeadcount();
  Future<MyHeadcount> setHeadcountStatus(HeadcountStatus status);
  Future<void> removeHeadcount();
}

/// Checks the forms before anything is sent. Throws [ValidationException]
/// with a message the app can show.
class PublicReportsService {
  PublicReportsService(this.backend, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final PublicReportsBackend backend;
  final DateTime Function() _clock;

  static const maxDescription = 500;
  static const maxOtherNeed = 200;
  static const maxPeople = 30;
  static const maxPets = 20;

  /// Reports older than this are refused (match the server).
  static const oldestReport = Duration(days: 60);

  /// A headcount stops counting this long after it was last sent.
  static const headcountLasts = Duration(hours: 72);

  bool get reachesStaff => backend.reachesStaff;

  void checkReport(FloodReportDraft d) {
    final now = _clock();
    if (d.occurredAt.isAfter(now.add(const Duration(minutes: 5)))) {
      throw ValidationException('The time cannot be in the future');
    }
    if (d.occurredAt.isBefore(now.subtract(oldestReport))) {
      throw ValidationException('Reports can be up to 60 days old');
    }
    if (d.kind == ReportKind.damage && (d.type == null || d.severity == null)) {
      throw ValidationException('Choose what was damaged and how bad it is');
    }
    if (d.description.trim().length > maxDescription) {
      throw ValidationException('Description is too long (max $maxDescription characters)');
    }
    if (d.clientRef.trim().isEmpty) throw ValidationException('Missing report reference');
  }

  void checkHeadcount(HeadcountDraft d) {
    if (d.total < 1 || d.total > maxPeople) {
      throw ValidationException('Number of people must be 1 to $maxPeople');
    }
    if (d.babies < 0 || d.children < 0 || d.adults < 0 || d.elderly < 0 || d.reducedMobility < 0 || d.pets < 0) {
      throw ValidationException('Numbers cannot be negative');
    }
    if (d.babies + d.children + d.adults + d.elderly > d.total) {
      throw ValidationException('Babies, children, adults and older people cannot be more than the total');
    }
    if (d.pets > maxPets) throw ValidationException('At most $maxPets pets');
    if (d.reducedMobility > d.total) {
      throw ValidationException('People who need help moving cannot be more than the total');
    }
    if (d.otherNeed.trim().length > maxOtherNeed) {
      throw ValidationException('Other need is too long (max $maxOtherNeed characters)');
    }
  }

  Future<void> submitReport(FloodReportDraft d) async {
    checkReport(d);
    await backend.submitReport(d);
  }

  Future<List<MyReport>> myReports() => backend.myReports();

  Future<MyHeadcount> submitHeadcount(HeadcountDraft d) async {
    checkHeadcount(d);
    return backend.submitHeadcount(d);
  }

  Future<MyHeadcount?> myHeadcount() => backend.myHeadcount();
  Future<MyHeadcount> setHeadcountStatus(HeadcountStatus s) => backend.setHeadcountStatus(s);
  Future<void> removeHeadcount() => backend.removeHeadcount();
}

/// Sends to Supabase (supabase/public_reports.sql) as this phone's anonymous
/// user. Errors come back as [SupabaseException].
class SupabaseReportsBackend implements PublicReportsBackend {
  SupabaseReportsBackend(this.api);
  final SupabaseApi api;

  @override
  bool get reachesStaff => true;

  @override
  Future<void> submitReport(FloodReportDraft d) async {
    await api.rpc('submit_flood_report', {'p': d.toJson()});
  }

  @override
  Future<List<MyReport>> myReports() async {
    final r = await api.rpc('my_flood_reports', {});
    return [
      for (final row in (r is List ? r : const []))
        if (MyReport.fromJson(row) != null) MyReport.fromJson(row)!,
    ];
  }

  MyHeadcount _one(Object? r) =>
      MyHeadcount.fromJson(r) ?? (throw SupabaseException('Unexpected reply from the server'));

  @override
  Future<MyHeadcount> submitHeadcount(HeadcountDraft d) async =>
      _one(await api.rpc('submit_headcount', {'p': d.toJson()}));

  @override
  Future<MyHeadcount?> myHeadcount() async {
    final r = await api.rpc('my_headcount', {});
    return r == null ? null : MyHeadcount.fromJson(r);
  }

  @override
  Future<MyHeadcount> setHeadcountStatus(HeadcountStatus s) async =>
      _one(await api.rpc('set_headcount_status', {'p_status': s.code}));

  @override
  Future<void> removeHeadcount() async {
    await api.rpc('remove_headcount', {});
  }
}

/// Keeps reports and the headcount on this phone only. Used when the app
/// is built without Supabase (sample data) and in tests; nothing reaches staff.
class LocalReportsBackend implements PublicReportsBackend {
  LocalReportsBackend(this.store, {DateTime Function()? clock, this.centreName}) : _clock = clock ?? DateTime.now;
  final SettingsStore store;
  final DateTime Function() _clock;

  /// Looks up a centre's name for "My headcount".
  final String? Function(String centreId)? centreName;

  @override
  bool get reachesStaff => false;

  Future<Map<String, String>> _all() => store.load();

  @override
  Future<void> submitReport(FloodReportDraft d) async {
    final all = await _all();
    final list = (jsonDecode(all['reports'] ?? '[]') as List).cast<Object?>();
    // Same reference again (a retry): nothing new is added.
    if (list.any((r) => r is Map && r['client_ref'] == d.clientRef)) return;
    final r = MyReport(
        id: 'local-${list.length + 1}',
        kind: d.kind,
        occurredAt: d.occurredAt,
        status: ReportStatus.pending,
        type: d.type,
        severity: d.severity,
        depth: d.depth);
    list.add({...r.toJson(), 'client_ref': d.clientRef, 'created_at': _clock().toUtc().toIso8601String()});
    all['reports'] = jsonEncode(list);
    await store.save(all);
  }

  @override
  Future<List<MyReport>> myReports() async {
    final list = jsonDecode((await _all())['reports'] ?? '[]') as List;
    return [
      for (final r in list.reversed)
        if (MyReport.fromJson(r) != null) MyReport.fromJson(r)!,
    ];
  }

  @override
  Future<MyHeadcount> submitHeadcount(HeadcountDraft d) async {
    final now = _clock();
    final h = MyHeadcount(
        total: d.total,
        babies: d.babies,
        elderly: d.elderly,
        reducedMobility: d.reducedMobility,
        children: d.children,
        adults: d.adults,
        pets: d.pets,
        dailyMedicine: d.dailyMedicine,
        powerMachine: d.powerMachine,
        needs: d.needs,
        otherNeed: d.needs.contains(SpecialNeed.other) ? d.otherNeed.trim() : '',
        status: d.status,
        updatedAt: now,
        expiresAt: now.add(PublicReportsService.headcountLasts),
        centreId: d.centreId,
        centreName: d.centreId == null ? null : centreName?.call(d.centreId!));
    await _keep(h);
    return h;
  }

  Future<void> _keep(MyHeadcount h) async {
    final all = await _all();
    all['headcount'] = jsonEncode(h.toJson());
    await store.save(all);
  }

  @override
  Future<MyHeadcount?> myHeadcount() async {
    final raw = (await _all())['headcount'];
    return raw == null ? null : MyHeadcount.fromJson(jsonDecode(raw));
  }

  @override
  Future<MyHeadcount> setHeadcountStatus(HeadcountStatus s) async {
    final h = await myHeadcount() ?? (throw NotFoundException('headcount', 'this phone'));
    final now = _clock();
    final updated = MyHeadcount(
        total: h.total,
        babies: h.babies,
        elderly: h.elderly,
        reducedMobility: h.reducedMobility,
        children: h.children,
        adults: h.adults,
        pets: h.pets,
        dailyMedicine: h.dailyMedicine,
        powerMachine: h.powerMachine,
        needs: h.needs,
        otherNeed: h.otherNeed,
        status: s,
        updatedAt: now,
        expiresAt: now.add(PublicReportsService.headcountLasts),
        centreId: h.centreId,
        centreName: h.centreName);
    await _keep(updated);
    return updated;
  }

  @override
  Future<void> removeHeadcount() async {
    final all = await _all()..remove('headcount');
    await store.save(all);
  }
}
