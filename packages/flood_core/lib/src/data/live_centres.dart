import 'dart:convert';

import '../models/evacuation_point.dart';
import '../services/settings_service.dart';
import '../util/geo.dart';
import 'supabase_api.dart';
import 'table.dart';

/// Relief centres from Supabase (public.evacuation_points), as uploaded from
/// places/centres.csv. Read-only in the public app: centres are changed in
/// that file (or later by staff), never from a phone.
///
/// The last list that loaded is kept on the phone ([store]), so the Centres
/// tab and the offline route guide still work without internet.
class LiveCentreTable implements Table<EvacuationPoint> {
  LiveCentreTable(this.api, {required this.store, DateTime Function()? clock, this.maxAge = const Duration(seconds: 60)})
      : _clock = clock ?? DateTime.now;
  final SupabaseApi api;
  final SettingsStore store;
  final Duration maxAge;
  final DateTime Function() _clock;

  ({DateTime at, List<EvacuationPoint> rows})? _cache;

  /// True when the last [all] came from the copy on the phone (no internet).
  bool fromPhone = false;

  @override
  Future<List<EvacuationPoint>> all() async {
    final c = _cache;
    if (c != null && _clock().difference(c.at) < maxAge) return c.rows;
    try {
      // '*' so the app keeps working before and after places.sql adds its columns.
      final raw = await api.select('evacuation_points', {'select': '*', 'order': 'name'});
      final rows = _parse(raw);
      _cache = (at: _clock(), rows: rows);
      fromPhone = false;
      await store.save({'rows': jsonEncode(raw)});
      return rows;
    } on SupabaseException {
      final saved = (await store.load())['rows'];
      Object? list;
      try {
        list = saved == null ? null : jsonDecode(saved);
      } on FormatException {
        list = null; // a damaged copy is ignored
      }
      if (list is! List) rethrow;
      fromPhone = true;
      return _parse([
        for (final r in list)
          if (r is Map<String, dynamic>) r,
      ]);
    }
  }

  @override
  Future<EvacuationPoint?> byId(String id) async {
    for (final p in await all()) {
      if (p.id == id) return p;
    }
    return null;
  }

  @override
  Future<void> put(String id, EvacuationPoint value) =>
      throw UnsupportedError('Relief centres are changed in places/centres.csv');

  @override
  Future<void> remove(String id) => throw UnsupportedError('Relief centres are changed in places/centres.csv');

  static List<EvacuationPoint> _parse(List<Map<String, dynamic>> raw) => [
        for (final r in raw) centreFromRow(r),
      ].whereType<EvacuationPoint>().toList();

  /// One centre, or null for a row without an id, a name or a valid position.
  static EvacuationPoint? centreFromRow(Map<String, dynamic> r) {
    final id = '${r['id'] ?? ''}'.trim(), name = '${r['name'] ?? ''}'.trim();
    final lat = _num(r['lat']), lon = _num(r['lon']);
    final capacity = _num(r['capacity'])?.round() ?? 0;
    if (id.isEmpty || name.isEmpty || lat == null || lon == null || !validCoordinates(lat, lon) || capacity <= 0) {
      return null;
    }
    final occupancy = (_num(r['occupancy'])?.round() ?? 0).clamp(0, capacity);
    final phone = '${r['phone'] ?? ''}'.trim();
    final district = '${r['district'] ?? ''}'.trim();
    return EvacuationPoint(
      id: id,
      name: name,
      location: GeoPoint(lat, lon),
      capacity: capacity,
      occupancy: occupancy,
      isOpen: r['is_open'] != false,
      resourcePointId: r['resource_point_id'] as String?,
      district: district.isEmpty ? null : district,
      phone: phone.isEmpty ? null : phone,
      locationChecked: r['location_checked'] != false,
      capacityEstimated: r['capacity_estimated'] == true,
    );
  }

  static double? _num(Object? v) {
    final d = v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
    return (d == null || !d.isFinite) ? null : d;
  }
}
