import '../data/supabase_api.dart';
import '../models/rain_outlook.dart';
import '../models/station_status.dart';
import '../risk/joint_risk.dart';

/// Where each station's 3-day rain outlook comes from.
abstract class RainOutlookSource {
  /// {station id: outlook}. Stations with no outlook are left out.
  Future<Map<String, RainOutlook>> load();
}

/// The Supabase table `weather_outlook` (supabase/weather.sql), updated every 6 hours
/// by logger/jps_logger/weather.py from Open-Meteo and MET Malaysia.
class LiveRainOutlookSource implements RainOutlookSource {
  LiveRainOutlookSource(this.api);
  final SupabaseApi api;

  @override
  Future<Map<String, RainOutlook>> load() async {
    final rows = await api.select('weather_outlook', {'select': '*'});
    return {
      for (final r in rows)
        if ('${r['station_code'] ?? ''}'.isNotEmpty)
          '${r['station_code']}': RainOutlook.fromJson('${r['station_code']}', r),
    };
  }
}

/// Fixed outlooks (sample mode and tests).
class FixedRainOutlookSource implements RainOutlookSource {
  FixedRainOutlookSource(this.outlooks);
  final Map<String, RainOutlook> outlooks;

  @override
  Future<Map<String, RainOutlook>> load() async => outlooks;
}

/// The measured status of each station joined with its rain outlook. Never throws:
/// without an outlook (offline, table not set up yet) every station keeps its
/// measured level and simply has no forecast reasons.
class JointRiskService {
  JointRiskService(this.source, {this.calculator = const JointRiskCalculator()});
  final RainOutlookSource source;
  final JointRiskCalculator calculator;

  Future<Map<String, JointAssessment>> assessAll(List<StationStatus> statuses) async {
    Map<String, RainOutlook> outlooks;
    try {
      outlooks = await source.load();
    } catch (_) {
      outlooks = const {};
    }
    return {for (final s in statuses) s.station.id: calculator.assess(s, outlooks[s.station.id])};
  }
}
