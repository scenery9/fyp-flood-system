import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../app/forecast_text.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';

const _upColor = Color(0xFFA8221A);
const _downColor = Color(0xFF176B3A);

Color chanceBandColor(ChanceBand? b) => switch (b) {
      ChanceBand.veryHigh => const Color(0xFFA8221A),
      ChanceBand.high => const Color(0xFFB34700),
      ChanceBand.moderate => const Color(0xFF7A5B00),
      ChanceBand.low => const Color(0xFF176B3A),
      null => const Color(0xFFA8221A), // already at the level
    };

/// The flood chance in a few lines: headline (% and band), what "flood" means, the other
/// JPS levels, and up to 3 reasons for and 1 against. Used on Home and on the "why" screen.
class FloodChanceSummary extends StatelessWidget {
  const FloodChanceSummary({super.key, required this.chance, this.maxReasons = FloodExplainer.maxSupporting});
  final FloodChance chance;
  final int maxReasons;

  @override
  Widget build(BuildContext context) {
    final e = FloodExplainer.explain(chance);
    final others = otherLevelsLine(context, chance);
    Widget reason(FloodReason r) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(r.supports ? Icons.arrow_upward : Icons.arrow_downward,
                size: 18, color: r.supports ? _upColor : _downColor),
            const SizedBox(width: 6),
            Expanded(child: Text(floodReasonText(context, r), style: context.text.bodyLarge)),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(floodHeadline(context, e),
          key: const ValueKey('flood-headline'),
          style: context.text.titleLarge!.copyWith(color: chanceBandColor(e.band))),
      const SizedBox(height: 2),
      Text(floodMeaning(context, chance), style: context.text.bodyMedium),
      if (others.isNotEmpty) Text(others, style: context.text.bodyMedium!.copyWith(fontFeatures: AppText.tabular)),
      if (e.supporting.isNotEmpty || e.against.isNotEmpty) const SizedBox(height: 8),
      for (final r in e.supporting.take(maxReasons)) reason(r),
      for (final r in e.against) reason(r),
    ]);
  }
}

/// "Chance of flood in the next 24 hours", with its reasons and how well the stated
/// chances held up on the day the model was checked.
class FloodChanceCard extends StatelessWidget {
  const FloodChanceCard({super.key, required this.forecast});
  final StationForecast forecast;

  @override
  Widget build(BuildContext context) {
    final fc = forecast.floodChance;
    if (fc == null) return const SizedBox.shrink();
    final check = forecast.chanceCheck;
    final h = fc.horizonHours;
    final lv = context.levelName(fc.headlineLevel);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader(context.tr('Chance of flood in the next $h hours', 'Peluang banjir dalam $h jam akan datang',
          '未来 $h 小时内的水灾概率')),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: kMargin),
        child: AppCard(child: FloodChanceSummary(chance: fc)),
      ),
      NoteText(context.tr(
          'The % is how often similar past situations (rain, river height and trend, forecast) led to $lv within $h hours. '
              'Arrows: up raises the chance, down lowers it.',
          'Peratusan ialah kekerapan keadaan serupa yang lalu (hujan, paras dan arah sungai, ramalan) membawa kepada $lv dalam $h jam. '
              'Anak panah: atas menaikkan peluang, bawah menurunkannya.',
          '百分比表示过去类似情况（降雨、河流水位与趋势、预报）在 $h 小时内达到“$lv”的频率。箭头向上表示提高概率，向下表示降低。')),
      if (check != null)
        NoteText(check.reliable
            ? context.tr(
                'Checked on ${check.day}, a day the model did not learn from: ${check.events} rivers reached $lv. '
                    'The stated chances are rough; on wetter days than it has seen they can be too low.',
                'Disemak pada ${check.day}, hari yang tidak dipelajari model: ${check.events} sungai mencapai $lv. '
                    'Peluang yang dinyatakan adalah anggaran; pada hari lebih basah ia mungkin terlalu rendah.')
            : context.tr('Too few rivers reached $lv on the check day to trust this number yet.',
                'Terlalu sedikit sungai mencapai $lv pada hari semakan untuk mempercayai nombor ini.')),
    ]);
  }
}
