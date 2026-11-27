import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../app/forecast_text.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';

/// The 3-day rain forecast for one station (Open-Meteo and MET Malaysia) and the
/// plain reasons why the area is, or may become, high risk (JointRiskCalculator).
class RainOutlookSection extends StatelessWidget {
  const RainOutlookSection({super.key, required this.stationId});
  final String stationId;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final j = app.jointFor(stationId);
    final o = j?.rainOutlook ?? app.cardForecastFor(stationId)?.rainOutlook;
    if (j == null && o == null) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (o != null) ...[
        SectionHeader(context.tr('Rain forecast, next 3 days', 'Ramalan hujan, 3 hari akan datang', '未来3天降雨预报')),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kMargin),
          child: AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final d in o.days) _DayRow(day: d),
              if (o.warning != MetWarningLevel.none)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                      context.tr('MET Malaysia warning: ${o.warningTitle ?? ''} (${o.warning.labelEn})',
                          'Amaran MET Malaysia: ${o.warningTitle ?? ''} (${o.warning.labelBm})'),
                      style: context.text.bodyLarge!.copyWith(fontWeight: FontWeight.w600)),
                ),
            ]),
          ),
        ),
      ],
      if (j != null && j.reasons.isNotEmpty) ...[
        SectionHeader(context.tr('Why this area is at risk', 'Kenapa kawasan ini berisiko', '为什么该地区有风险')),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kMargin),
          child: AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text(context.tr('River now:', 'Sungai kini:', '目前河流：'), style: context.text.bodyLarge),
                RiskBadge(j.measured),
                if (j.raised) ...[
                  Text(context.tr('With forecast rain:', 'Dengan ramalan hujan:', '加上预报降雨：'), style: context.text.bodyLarge),
                  RiskBadge(j.outlook),
                ],
              ]),
              const SizedBox(height: 8),
              for (final r in j.reasons)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Padding(padding: EdgeInsets.only(top: 2), child: Icon(Icons.chevron_right, size: 18)),
                    const SizedBox(width: 6),
                    Expanded(child: Text(jointReasonText(context, r, j), style: context.text.bodyLarge)),
                  ]),
                ),
            ]),
          ),
        ),
      ],
      NoteText(context.tr(
          'Why these inputs: daily rain bands are the WMO/ETCCDI climate indices (1, 10 and 20 mm a day). '
              'MET Malaysia is the official forecaster; Open-Meteo combines 8 global weather models. '
              'Checked against the JPS rain gauges and river readings in docs/rain-forecast-evidence.md.',
          'Kenapa input ini: jalur hujan harian ialah indeks iklim WMO/ETCCDI (1, 10 dan 20 mm sehari). '
              'MET Malaysia ialah peramal rasmi; Open-Meteo menggabungkan 8 model cuaca global. '
              'Disemak dengan tolok hujan dan bacaan sungai JPS dalam docs/rain-forecast-evidence.md.')),
      NoteText(context.tr('A forecast can be wrong. The river level now is always shown as measured.',
          'Ramalan boleh silap. Paras sungai kini sentiasa ditunjukkan seperti yang diukur.')),
    ]);
  }
}

class _DayRow extends StatelessWidget {
  const _DayRow({required this.day});
  final DayRain day;

  @override
  Widget build(BuildContext context) {
    final mm = day.mm;
    final band = day.band;
    final om = mm == null
        ? context.tr('Open-Meteo: no forecast', 'Open-Meteo: tiada ramalan')
        : context.tr(
            'Open-Meteo: ${mm.round()} mm (${band!.labelEn.toLowerCase()})'
                '${day.chancePct == null ? '' : ', ${day.chancePct!.round()}% of models'}',
            'Open-Meteo: ${mm.round()} mm (${band.labelBm.toLowerCase()})'
                '${day.chancePct == null ? '' : ', ${day.chancePct!.round()}% model'}');
    final met = day.metText ?? (day.met == null ? null : metClassText(context, day.met!));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(forecastWindow(context, day.day), style: context.text.bodyMedium!.copyWith(fontWeight: FontWeight.w600)),
        Text(om, style: context.text.bodyLarge),
        if (met != null) Text('MET Malaysia: $met', style: context.text.bodyLarge),
        if (day.sourcesAgree == false)
          Text(context.tr('The two forecasts disagree', 'Dua ramalan tidak sependapat'),
              style: context.text.bodyMedium!.copyWith(fontStyle: FontStyle.italic)),
      ]),
    );
  }
}

String metClassText(BuildContext c, MetRainClass k) => c.tr(k.labelEn, k.labelBm);

/// A [RiskReason] in the app's language. English is flood_core's own sentence;
/// Malay is built from the same numbers.
String jointReasonText(BuildContext c, RiskReason r, JointAssessment j) {
  if (AppScope.of(c).language != AppLanguage.ms) return r.text;
  final o = j.rainOutlook;
  final f = r.factor;
  DayRain? dayOf(String key) {
    final d = int.tryParse(key.substring(key.length - 1));
    return o == null || d == null || d < 1 || d > 3 ? null : o.days[d - 1];
  }

  if (f.startsWith('forecast_day')) {
    final d = dayOf(f)!;
    return 'Open-Meteo: ${d.mm!.round()} mm hujan diramal untuk ${forecastWindow(c, d.day)} '
        '(${d.band!.labelBm.toLowerCase()}${d.chancePct == null ? '' : ', ${d.chancePct!.round()}% model cuaca menjangka hujan'})';
  }
  if (f.startsWith('met_day')) {
    final d = dayOf(f)!;
    return 'MET Malaysia: ${d.metText ?? d.met!.labelBm} (${forecastWindow(c, d.day)})';
  }
  if (f.startsWith('sources_disagree_day')) {
    final d = dayOf(f)!;
    return 'Dua ramalan tidak sependapat untuk ${forecastWindow(c, d.day)}: Open-Meteo ${d.mm!.round()} mm, '
        'MET Malaysia "${d.metText ?? d.met!.labelBm}"';
  }
  return switch (f) {
    'forecast_next_3h' => 'Open-Meteo: ${o!.next3hMm!.round()} mm hujan diramal dalam 3 jam akan datang',
    'met_warning' => 'Amaran MET Malaysia berkuat kuasa: ${o!.warningTitle ?? 'amaran hujan'} (${o.warning.labelBm})',
    'rain_days_3d' => 'Hujan diramal pada ${o!.rainDays3d} daripada 3 hari akan datang (${o.total3dMm!.round()} mm semuanya)',
    'outlook' => 'Tinjauan dinaikkan ke ${j.outlook!.labelBm}: hujan sangat lebat diramal sementara sungai '
        '${j.measured == RiskLevel.normal ? 'hampir ke tahap Waspada' : 'sudah pada tahap ${j.measured!.labelBm}'}',
    'outlook_possible' => 'Mungkin hujan lebat (hanya satu ramalan menjangkanya): tinjauan tidak dinaikkan',
    _ => r.text,
  };
}
