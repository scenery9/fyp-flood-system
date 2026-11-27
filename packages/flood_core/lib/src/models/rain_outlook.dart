/// A station's rain outlook for the next 3 days, from two sources:
///  * Open-Meteo: rain in mm and the share of 8 weather models that expect rain
///  * MET Malaysia: the official forecast text per district and day, and warnings
///
/// Read from the Supabase table `weather_outlook` (logger/jps_logger/outlook.py)
/// or from the `rain_outlook` block in forecast.json (schema 2). Windows count from
/// the time the outlook was made: day 1 = the next 24 hours, day 2 = 24-48 h,
/// day 3 = 48-72 h.
library;

/// Daily rain thresholds (mm in 24 h), the ETCCDI climate indices (docs/references.md):
/// a rain day (R1mm), a heavy rain day (R10mm), a very heavy rain day (R20mm).
const double rainDayMm = 1.0;
const double heavyDayMm = 10.0;
const double veryHeavyDayMm = 20.0;

/// The daily band of an Open-Meteo rain amount.
enum DailyRainBand {
  dry('Dry', 'Kering'),
  rainDay('Rain', 'Hujan'),
  heavy('Heavy rain', 'Hujan lebat'),
  veryHeavy('Very heavy rain', 'Hujan sangat lebat');

  const DailyRainBand(this.labelEn, this.labelBm);
  final String labelEn;
  final String labelBm;

  static DailyRainBand? fromMm(double? mm) {
    if (mm == null) return null;
    if (mm >= veryHeavyDayMm) return veryHeavy;
    if (mm >= heavyDayMm) return heavy;
    if (mm >= rainDayMm) return rainDay;
    return dry;
  }
}

/// MET Malaysia's forecast, as a class (logger/jps_logger/metmalaysia.py).
enum MetRainClass {
  none('no rain', 'tiada hujan'),
  somePlaces('rain in some places', 'hujan di beberapa tempat'),
  rain('rain', 'hujan'),
  mostPlaces('rain in most places', 'hujan di kebanyakan tempat'),
  widespread('widespread rain', 'hujan menyeluruh');

  const MetRainClass(this.labelEn, this.labelBm);
  final String labelEn;
  final String labelBm;

  static MetRainClass? fromNumber(num? n) =>
      n == null || n < 0 || n > 4 ? null : MetRainClass.values[n.round()];
}

/// MET Malaysia warning tiers (continuous rain); thunderstorm warnings count as 1.
enum MetWarningLevel {
  none('None', 'Tiada'),
  waspada('Alert (Waspada)', 'Waspada'),
  buruk('Warning (Buruk)', 'Buruk'),
  bahaya('Danger (Bahaya)', 'Bahaya');

  const MetWarningLevel(this.labelEn, this.labelBm);
  final String labelEn;
  final String labelBm;

  static MetWarningLevel fromNumber(num? n) =>
      n == null || n < 0 ? none : MetWarningLevel.values[n.round().clamp(0, 3)];
}

class DayRain {
  const DayRain({
    required this.day,
    this.mm,
    this.chancePct,
    this.openMeteoChancePct,
    this.met,
    this.metText,
    this.metThunder,
  });

  /// 1, 2 or 3.
  final int day;

  /// Open-Meteo: mm in this 24-hour window (8-model mean).
  final double? mm;

  /// Open-Meteo: highest share of models (%) expecting a wet hour in the window.
  final double? chancePct;

  /// Open-Meteo's own probability of precipitation (live only).
  final double? openMeteoChancePct;
  final MetRainClass? met;

  /// MET Malaysia's own words, e.g. "Ribut petir di beberapa tempat".
  final String? metText;
  final bool? metThunder;

  DailyRainBand? get band => DailyRainBand.fromMm(mm);

  /// Do the two sources agree on rain / no rain? Null when one is missing.
  bool? get sourcesAgree => mm == null || met == null ? null : (mm! >= rainDayMm) == (met!.index >= 1);

  /// "the next 24 hours", "24-48 hours from now", "48-72 hours from now".
  String get windowEn => switch (day) {
        1 => 'the next 24 hours',
        2 => '24-48 hours from now',
        _ => '48-72 hours from now',
      };
}

class RainOutlook {
  RainOutlook({
    required this.stationId,
    required this.days,
    this.madeAt,
    this.next3hMm,
    this.next3hChancePct,
    this.rainDays3d,
    this.total3dMm,
    this.warning = MetWarningLevel.none,
    this.warningTitle,
    this.warningValidTo,
  });

  final String stationId;
  final DateTime? madeAt;
  final double? next3hMm;
  final double? next3hChancePct;

  /// Always 3 entries: day 1, 2 and 3.
  final List<DayRain> days;

  /// How many of the next 3 days are forecast rain days (>= 1 mm).
  final int? rainDays3d;
  final double? total3dMm;
  final MetWarningLevel warning;
  final String? warningTitle;
  final DateTime? warningValidTo;

  bool get hasOpenMeteo => days.any((d) => d.mm != null);
  bool get hasMet => days.any((d) => d.met != null) || warning != MetWarningLevel.none;

  static double? _d(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
  static DateTime? _t(Object? v) => v is String ? DateTime.tryParse(v)?.toUtc() : null;

  /// From a `weather_outlook` row or a forecast.json `rain_outlook` block
  /// (the same names; forecast.json has no MET text or times).
  factory RainOutlook.fromJson(String stationId, Map j) {
    return RainOutlook(
      stationId: stationId,
      madeAt: _t(j['om_issued_at']) ?? _t(j['updated_at']),
      next3hMm: _d(j['next_3h_mm']),
      next3hChancePct: _d(j['next_3h_prob']),
      days: [
        for (final d in const [1, 2, 3])
          DayRain(
            day: d,
            mm: _d(j['day${d}_mm']),
            chancePct: _d(j['day${d}_prob']),
            openMeteoChancePct: _d(j['day${d}_om_prob']),
            met: MetRainClass.fromNumber(_d(j['day${d}_met_class'])),
            metText: j['day${d}_met_text'] as String?,
            metThunder: _d(j['day${d}_met_thunder']) == null ? null : _d(j['day${d}_met_thunder'])! >= 1,
          ),
      ],
      rainDays3d: _d(j['rain_days_3d'])?.round(),
      total3dMm: _d(j['total_3d_mm']),
      warning: MetWarningLevel.fromNumber(_d(j['warning_level'])),
      warningTitle: j['warning_title'] as String?,
      warningValidTo: _t(j['warning_valid_to']),
    );
  }
}
