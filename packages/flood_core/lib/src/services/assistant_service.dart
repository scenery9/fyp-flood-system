import '../models/app_settings.dart';
import '../models/risk_level.dart';
import '../models/station_status.dart';
import '../util/geo.dart';
import 'evacuation_service.dart';
import 'guidance_service.dart';
import 'monitoring_service.dart';
import 'station_list_service.dart';
import 'warning_service.dart';

enum AssistantIntent { emergency, evacuation, reportDamage, whatToDo, stationStatus, warnings, unknown }

class AssistantAnswer {
  AssistantAnswer(this.intent, this.text, this.sources);
  final AssistantIntent intent;
  final String text;

  /// Where the answer came from ("View details / Sources" in the UI).
  final List<String> sources;
  static const String disclaimer = 'This is not an official warning.';
}

/// "Ask the Assistant": a free, rule-based helper. It does not use a paid AI
/// service; it recognises keywords (English and Malay) and answers only from
/// the app's own data, always listing its sources.
class AssistantService {
  AssistantService({required this.monitoring, required this.evacuation});
  final MonitoringService monitoring;
  final EvacuationService evacuation;
  static const _guidance = GuidanceService();
  static const int maxQuestionLength = 300;

  static const _emergency = ['emergency', 'kecemasan', '999', 'trapped', 'terperangkap', 'tolong', 'sos'];
  static const _evacuation = ['evacuat', 'shelter', 'relief', 'pps', 'pemindahan', 'where to go', 'pusat'];
  static const _report = ['report', 'lapor', 'damage', 'kerosakan'];
  static const _whatToDo = ['what to do', 'what should', 'prepare', 'safe', 'apa perlu', 'nak buat', 'selamat', 'sedia'];
  static const _warnings = ['warning', 'amaran', 'high risk', 'berisiko', 'which area', 'kawasan mana', 'flood now'];
  static const _ignore = {'sungai', 'stesen', 'hujan', 'ladang', 'kampung', 'station', 'river'};

  Future<AssistantAnswer> ask(String question, {GeoPoint? userLocation}) async {
    var q = question.trim().toLowerCase();
    if (q.length > maxQuestionLength) q = q.substring(0, maxQuestionLength);
    bool has(List<String> words) => words.any(q.contains);

    if (q.isEmpty) return _unknown();
    if (has(_emergency)) {
      return AssistantAnswer(AssistantIntent.emergency,
          'If you are in danger, call 999 now. Move to higher ground if you can do so safely.',
          ['Emergency number 999']);
    }
    if (has(_evacuation)) return _evacuationAnswer(userLocation);
    if (has(_report)) {
      return AssistantAnswer(AssistantIntent.reportDamage,
          'Open "Report Flood Damage", pick the place on the map, then choose the date, damage type '
          'and severity. Leave water depth blank if you are unsure. Track it under "My reports".',
          ['App guide: Report Flood Damage']);
    }

    final statuses = await monitoring.loadStatuses(userLocation: userLocation);
    final station = _matchStation(q, statuses);

    if (has(_whatToDo)) {
      final level = station != null && station.isActionable
          ? station.level!
          : _levelWord(q) ?? RiskLevel.alert;
      final steps = _guidance.steps(level, language: AppLanguage.en);
      final where = station == null ? '' : ' (${station.station.name} is at ${_levelText(station)})';
      return AssistantAnswer(AssistantIntent.whatToDo,
          'At ${level.labelEn} level$where:\n${[for (final s in steps) '- $s'].join('\n')}',
          ['What To Do guide: ${level.labelEn}', if (station != null) _source(station)]);
    }
    if (station != null) {
      return AssistantAnswer(AssistantIntent.stationStatus,
          '${station.station.name}: ${_levelText(station)}. ${station.mainCause}.', [_source(station)]);
    }
    if (has(_warnings)) {
      final active = const WarningService().active(statuses);
      if (active.isEmpty) {
        return AssistantAnswer(AssistantIntent.warnings,
            'No station is at Alert level or above right now.', ['Station readings (${statuses.length} stations)']);
      }
      return AssistantAnswer(AssistantIntent.warnings,
          'Stations at Alert level or above:\n'
          '${[for (final s in active) '- ${s.station.name}: ${s.level!.labelEn}'].join('\n')}',
          [for (final s in active) _source(s)]);
    }
    return _unknown();
  }

  Future<AssistantAnswer> _evacuationAnswer(GeoPoint? user) async {
    if (user == null) {
      final open = (await evacuation.listAll()).where((p) => p.isAvailable).toList();
      if (open.isEmpty) {
        return AssistantAnswer(AssistantIntent.evacuation,
            'No relief centre is listed as open right now. Call 999 if you need help.', ['Evacuation points list']);
      }
      return AssistantAnswer(AssistantIntent.evacuation,
          'Open relief centres: ${open.map((p) => p.name).join(', ')}. '
          'Turn on location to find the nearest one.', ['Evacuation points list']);
    }
    final near = await evacuation.nearest(user, limit: 1);
    if (near.isEmpty) {
      return AssistantAnswer(AssistantIntent.evacuation,
          'No relief centre is listed as open right now. Call 999 if you need help.', ['Evacuation points list']);
    }
    final n = near.first;
    return AssistantAnswer(AssistantIntent.evacuation,
        'Nearest open relief centre: ${n.point.name}, about ${n.distanceKm.toStringAsFixed(1)} km away '
        '(straight line). Open "Evacuation" for directions.', ['Evacuation points list']);
  }

  AssistantAnswer _unknown() => AssistantAnswer(AssistantIntent.unknown,
      'I can help with: a station\'s status (e.g. "Kajang"), current warnings, the nearest relief '
      'centre, what to do, and how to report damage.', const []);

  /// Finds the station the question is about, by words from its name or
  /// district. If several match equally (e.g. a district), the riskiest wins.
  StationStatus? _matchStation(String q, List<StationStatus> statuses) {
    var best = 0;
    final hits = <StationStatus>[];
    for (final s in statuses) {
      final words = '${s.station.name} ${s.station.district}'
          .toLowerCase()
          .split(RegExp(r'[^a-z0-9]+'))
          .where((w) => w.length >= 4 && !_ignore.contains(w))
          .toSet();
      final score = words.where(q.contains).length;
      if (score == 0 || score < best) continue;
      if (score > best) {
        best = score;
        hits.clear();
      }
      hits.add(s);
    }
    if (hits.isEmpty) return null;
    return (hits..sort(compareByRisk)).first;
  }

  RiskLevel? _levelWord(String q) {
    for (final l in RiskLevel.values.reversed) {
      if (q.contains(l.labelEn.toLowerCase()) || q.contains(l.labelBm.toLowerCase())) return l;
    }
    return null;
  }

  String _levelText(StationStatus s) {
    if (s.level == null) return 'status unknown';
    return s.isStale ? '${s.level!.labelEn} (old data)' : s.level!.labelEn;
  }

  String _source(StationStatus s) {
    final age = s.age == null ? 'no reading' : 'updated ${s.age!.inMinutes} min ago';
    return 'Station reading: ${s.station.name}, $age';
  }
}
