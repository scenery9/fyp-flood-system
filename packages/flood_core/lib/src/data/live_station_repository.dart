import '../models/station.dart';
import '../models/station_reading.dart';
import '../util/geo.dart';
import 'station_repository.dart';
import 'supabase_api.dart';

/// Real JPS Selangor and Melaka stations and their latest readings, as logged every
/// 15 minutes by logger/ into Supabase (view public.jps_latest in
/// supabase/alerts.sql). Station ids are the JPS station codes.
///
/// One download serves both [getStations] and [getLatestReadings]; it is
/// reused for [maxAge] so a screen refresh does not download twice.
class LiveStationRepository implements StationRepository {
  LiveStationRepository(this.api, {DateTime Function()? clock, this.maxAge = const Duration(seconds: 60)})
      : _clock = clock ?? DateTime.now;
  final SupabaseApi api;
  final Duration maxAge;
  final DateTime Function() _clock;

  ({DateTime at, List<Station> stations, Map<String, StationReading> readings})? _cache;
  Future<void>? _loading;

  @override
  Future<List<Station>> getStations() async => (await _load()).stations;

  @override
  Future<Map<String, StationReading>> getLatestReadings() async => (await _load()).readings;

  /// Downloads again on the next call.
  void clearCache() => _cache = null;

  Future<({DateTime at, List<Station> stations, Map<String, StationReading> readings})> _load() async {
    final c = _cache;
    if (c != null && _clock().difference(c.at) < maxAge) return c;
    await (_loading ??= _download().whenComplete(() => _loading = null));
    return _cache!;
  }

  Future<void> _download() async {
    // '*' so the app keeps working before and after supabase/places.sql adds "state".
    final rows = await api.select('jps_latest', {'select': '*', 'order': 'name'});
    final stations = <Station>[];
    final readings = <String, StationReading>{};
    for (final r in rows) {
      final s = stationFromRow(r);
      if (s == null) continue;
      stations.add(s);
      final reading = readingFromRow(r);
      if (reading != null) readings[s.id] = reading;
    }
    _cache = (at: _clock(), stations: stations, readings: readings);
  }

  /// Null for a row without a station code.
  static Station? stationFromRow(Map<String, dynamic> r) {
    final code = '${r['station_code'] ?? ''}'.trim();
    if (code.isEmpty) return null;
    final lat = _num(r['lat']), lon = _num(r['lon']);
    return Station(
      id: code,
      name: '${r['name'] ?? code}',
      district: '${r['district'] ?? ''}',
      state: _state(r['state']),
      location: (lat != null && lon != null && validCoordinates(lat, lon) && !(lat == 0 && lon == 0))
          ? GeoPoint(lat, lon)
          : null,
      thresholds: _thresholds(r),
    );
  }

  /// The latest reading, or null when the station has none. The time is the
  /// river reading's time when there is one (it decides the risk level),
  /// otherwise the rainfall time. A problem the logger saw after the last good
  /// river reading (wl_problem, supabase/reading_problems.sql) comes with it, so
  /// the app can say why there is no new level; an older problem is ignored.
  static StationReading? readingFromRow(Map<String, dynamic> r) {
    final code = '${r['station_code'] ?? ''}'.trim();
    final levelAt = DateTime.tryParse('${r['level_at'] ?? ''}');
    final rainAt = DateTime.tryParse('${r['rain_at'] ?? ''}');
    final level = _num(r['level_m']), rain = _num(r['hourly_mm']);
    final hasLevel = levelAt != null && level != null;
    final hasRain = rainAt != null && rain != null;
    var problem = ReadingProblem.parse(r['wl_problem']);
    final problemAt = DateTime.tryParse('${r['wl_problem_at'] ?? ''}')?.toUtc();
    if (problem != null && (problemAt == null || (hasLevel && !problemAt.isAfter(levelAt.toUtc())))) {
      problem = null; // fixed since: a good reading came after it
    }
    if (code.isEmpty || (!hasLevel && !hasRain && problem == null)) return null;
    return StationReading.fromRaw(
      stationId: code,
      // No reading at all yet, only a problem: its time says how fresh that news is.
      time: (hasLevel ? levelAt : (hasRain ? rainAt : problemAt))!.toUtc(),
      riverLevel: hasLevel ? level : null,
      rainfall: hasRain ? rain : null,
      rainfallTime: hasRain ? rainAt.toUtc() : null,
      problem: problem,
      problemAt: problem == null ? null : problemAt,
    );
  }

  /// JPS sometimes lists warning levels that do not rise (or leaves some
  /// out). Such a station is treated as having no thresholds rather than
  /// guessing a level.
  static Thresholds? _thresholds(Map<String, dynamic> r) {
    final n = _num(r['wl_normal']), a = _num(r['wl_alert']), w = _num(r['wl_warning']), d = _num(r['wl_danger']);
    if (n == null || a == null || w == null || d == null) return null;
    if (!(n < a && a < w && w < d)) return null;
    return Thresholds(normal: n, alert: a, warning: w, danger: d);
  }

  /// "Selangor" or "Melaka" (rows logged before Melaka was added have no state).
  static String _state(Object? v) {
    final s = '${v ?? ''}'.trim();
    return s.isEmpty ? 'Selangor' : s;
  }

  static double? _num(Object? v) {
    final d = v is num ? v.toDouble() : double.tryParse('${v ?? ''}');
    return (d == null || !d.isFinite) ? null : d;
  }
}
