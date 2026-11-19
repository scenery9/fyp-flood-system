import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../app/forecast_text.dart';
import '../../widgets/read_aloud_button.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';
import '../more/info_screens.dart';

/// "Why does the AI say this?": the readings that moved the forecast most.
class ForecastWhyScreen extends StatelessWidget {
  const ForecastWhyScreen({super.key, required this.stationId});
  final String stationId;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final f = app.cardForecastFor(stationId);
    final s = app.statusOf(stationId);
    return SubPage(
      title: context.tr('Why the AI says this', 'Kenapa AI kata begini'),
      children: [
        const SizedBox(height: 8),
        if (f == null || s == null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kMargin),
            child: AppCard(
              child: Text(app.forecast?.unavailableReason ?? context.tr('No forecast for this area.', 'Tiada ramalan untuk kawasan ini.'),
                  style: context.text.bodyLarge),
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kMargin),
            child: AppCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                CardLabel(s.station.name),
                const SizedBox(height: 4),
                Text(forecastSummary(context, f), style: context.text.titleLarge),
                const SizedBox(height: 12),
                ReadAloudButton(id: 'why-${s.station.id}', text: () => forecastSpeech(context, s, f)),
                const SizedBox(height: 12),
                _Row(context.tr('Now', 'Kini'), s.riverLevel == null ? '—' : metres(s.riverLevel!)),
                _Row(context.tr('In ${f.horizonHours} hours (most likely)', 'Dalam ${f.horizonHours} jam (paling mungkin)', '${f.horizonHours} 小时后（最可能）'), metres(f.predictedLevelM)),
                _Row(context.tr('Likely range', 'Julat mungkin'), '${metres(f.lowM)} – ${metres(f.highM)}'),
                if (f.worstCaseRisk != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    // Wrap: the badge moves under the text when the line is too narrow.
                    child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      Text(context.tr('If it reaches the top of the range:', 'Jika sampai ke atas julat:'), style: context.text.bodyMedium),
                      RiskBadge(f.worstCaseRisk),
                    ]),
                  ),
              ]),
            ),
          ),
          SectionHeader(context.tr('Readings that mattered most', 'Bacaan paling mempengaruhi')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kMargin),
            child: AppCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(children: [
                if (f.factors.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(context.tr('No single reading stood out.', 'Tiada bacaan yang menonjol.'), style: context.text.bodyLarge),
                  ),
                for (var i = 0; i < f.factors.length; i++)
                  _Reason(factor: f.factors[i], last: i == f.factors.length - 1),
              ]),
            ),
          ),
          NoteText(context.tr(
              'The AI learned from past rainfall and river readings. It says which readings pushed this forecast up or down the most.',
              'AI belajar daripada bacaan hujan dan sungai yang lalu. Ia menunjukkan bacaan yang paling menaikkan atau menurunkan ramalan ini.')),
          if (f.isPracticeData)
            NoteText(context.tr('This model is still trained on practice data, so these are not real predictions yet.',
                'Model ini masih dilatih dengan data latihan, jadi ini belum ramalan sebenar.')),
          NoteText(context.tr('This is a computer prediction, not an official warning.', 'Ini ramalan komputer, bukan amaran rasmi.',
              '这是电脑预测，不是官方警报。')),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kMargin),
            child: OutlinedButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const HowAiWorksScreen())),
              child: Text(context.tr('How the prediction works', 'Cara ramalan berfungsi')),
            ),
          ),
        ],
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(child: Text(label, style: context.text.bodyLarge)),
          Text(value, style: context.text.bodyLarge!.copyWith(fontWeight: FontWeight.w600, fontFeatures: AppText.tabular)),
        ]),
      );
}

class _Reason extends StatelessWidget {
  const _Reason({required this.factor, required this.last});
  final ForecastFactor factor;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final r = forecastReason(context, factor);
    final color = r.raises ? const Color(0xFFA8221A) : const Color(0xFF176B3A);
    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: context.colors.divider))),
      child: Row(children: [
        Icon(r.raises ? Icons.arrow_upward : Icons.arrow_downward, color: color),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(r.text, style: context.text.bodyLarge),
            Text(
              r.raises
                  ? context.tr('Pushes the level up', 'Menaikkan paras')
                  : context.tr('Pulls the level down', 'Menurunkan paras'),
              style: context.text.bodyMedium!.copyWith(color: color, fontWeight: FontWeight.w600),
            ),
          ]),
        ),
      ]),
    );
  }
}
