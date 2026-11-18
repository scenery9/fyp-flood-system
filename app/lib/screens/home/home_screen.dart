import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../app/forecast_text.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';
import '../../widgets/forecast_chart.dart';
import '../../widgets/read_aloud_button.dart';
import '../../widgets/sos_button.dart';
import '../more/saved_areas_screen.dart';
import '../prepare/checklist_steps_screen.dart';
import 'forecast_why_screen.dart';
import 'station_detail_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final area = app.currentArea;
    return RefreshIndicator(
      onRefresh: app.refresh,
      child: ListView(
        primary: false,
        padding: const EdgeInsets.only(top: 16, bottom: 24),
        children: [
          if (app.loadError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(kMargin, 0, kMargin, kGap),
              child: AppCard(child: Text(app.loadError!, style: context.text.bodyLarge)),
            ),
          const Padding(padding: EdgeInsets.symmetric(horizontal: kMargin), child: AreaCarousel()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kMargin),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton.icon(
                  key: const ValueKey('go-centre'),
                  onPressed: () => app.selectTab(AppTab.centres),
                  icon: const Icon(Icons.directions),
                  label: Text(context.tr('Go to relief centre', 'Pergi ke pusat pemindahan')),
                ),
                const SizedBox(height: kGap),
                const SosButton(),
              ],
            ),
          ),
          if (area != null) ...[
            const SizedBox(height: kGap),
            Padding(padding: const EdgeInsets.symmetric(horizontal: kMargin), child: ForecastCard(area: area)),
            const SizedBox(height: kGap),
            const Padding(padding: EdgeInsets.symmetric(horizontal: kMargin), child: ChecklistSummaryCard()),
          ],
          const SizedBox(height: kGap),
          const Padding(padding: EdgeInsets.symmetric(horizontal: kMargin), child: HighRiskCard()),
          NoteText(context.tr('AI forecast is a guide, not an official warning. Follow JPS and NADMA instructions.',
              'Ramalan AI hanya panduan, bukan amaran rasmi. Ikut arahan JPS dan NADMA.')),
        ],
      ),
    );
  }
}

/// The status card for each saved area. Swipe left/right, tap the grey
/// arrows, or tap a dot to change area.
class AreaCarousel extends StatelessWidget {
  const AreaCarousel({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final areas = app.areas;
    if (areas.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: kGap),
        child: AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(context.tr('No saved areas yet', 'Tiada kawasan disimpan'), style: context.text.titleLarge),
            const SizedBox(height: 8),
            Text(context.tr('Add the river station nearest your home to see its level here.',
                'Tambah stesen sungai paling dekat dengan rumah anda untuk melihat parasnya di sini.'), style: context.text.bodyLarge),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SavedAreasScreen())),
              child: Text(context.tr('Add an area', 'Tambah kawasan')),
            ),
          ]),
        ),
      );
    }
    final i = app.areaIndex;
    return Column(
      children: [
        GestureDetector(
          onHorizontalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            if (v < -200) app.selectArea(i + 1);
            if (v > 200) app.selectArea(i - 1);
          },
          child: Stack(
            children: [
              AnimatedSwitcher(
                duration: MediaQuery.of(context).disableAnimations ? Duration.zero : const Duration(milliseconds: 250),
                child: AreaCard(key: ValueKey(areas[i].station.id), status: areas[i]),
              ),
              if (i > 0)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _Arrow(
                      icon: Icons.chevron_left,
                      label: context.tr('Previous area', 'Kawasan sebelumnya'),
                      onTap: () => app.selectArea(i - 1),
                    ),
                  ),
                ),
              if (i < areas.length - 1)
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _Arrow(
                      icon: Icons.chevron_right,
                      label: context.tr('Next area', 'Kawasan seterusnya'),
                      onTap: () => app.selectArea(i + 1),
                    ),
                  ),
                ),
            ],
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var k = 0; k < areas.length; k++)
              Semantics(
                // Own node, so screen readers announce each dot separately.
                container: true,
                button: true,
                selected: k == i,
                label: context.tr('Show ${areas[k].station.name}, ${k + 1} of ${areas.length}',
                    'Papar ${areas[k].station.name}, ${k + 1} daripada ${areas.length}', '显示 ${areas[k].station.name}，第 ${k + 1} 个，共 ${areas.length} 个'),
                excludeSemantics: true,
                child: InkWell(
                  onTap: () => app.selectArea(k),
                  child: SizedBox(
                    width: 32,
                    height: 44,
                    child: Center(
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: k == i ? context.colors.primary : const Color(0xFF8A94A0),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        // Own node, so screen readers announce the arrow on its own
        // instead of merging its label into the card.
        container: true,
        button: true,
        label: label,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(width: 32, height: 64, child: Icon(icon, color: AppColors.chevron, size: 28)),
        ),
      );
}

/// One area's status: the risk word, the river reading and when it was read.
class AreaCard extends StatelessWidget {
  const AreaCard({super.key, required this.status});
  final StationStatus status;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = status;
    final c = context.colors;
    final known = s.level != null && !s.isStale;
    final style = RiskStyle.of(known ? s.level : null);
    final t = s.station.thresholds;
    String? nextLine;
    if (t != null && s.targetLevel != null && s.level != RiskLevel.danger) {
      final v = switch (s.targetLevel!) {
        RiskLevel.normal => t.normal,
        RiskLevel.alert => t.alert,
        RiskLevel.warning => t.warning,
        RiskLevel.danger => t.danger,
      };
      nextLine = context.tr('${context.levelName(s.targetLevel)} from ${metres(v)}', '${context.levelName(s.targetLevel)} dari ${metres(v)}', '${metres(v)} 起为${context.levelName(s.targetLevel)}');
    } else if (t != null && s.level == RiskLevel.danger) {
      nextLine = context.tr('Danger from ${metres(t.danger)}', 'Bahaya dari ${metres(t.danger)}', '${metres(t.danger)} 起为危险');
    }
    final distance = s.distanceKm == null ? '' : ' · ${s.distanceKm!.toStringAsFixed(1)} km';
    final word = known ? context.levelName(s.level) : context.tr('No recent data', 'Tiada data terkini');
    final other = known
        ? (app.language == AppLanguage.ms ? s.level!.labelEn : s.level!.labelBm)
        : (s.isStale ? context.tr('Last reading is too old to use', 'Bacaan terakhir terlalu lama') : context.tr('No river reading', 'Tiada bacaan sungai'));

    final value = s.riverLevel != null
        ? metres(s.riverLevel!)
        : (s.rainfall != null ? '${s.rainfall!.toStringAsFixed(1)} mm/h' : '—');
    // Every line has a fixed slot and is one line long, so all saved-area
    // cards are the same height and the carousel does not jump on change.
    Widget oneLine(String text, TextStyle style) => Text(text, style: style, maxLines: 1, overflow: TextOverflow.ellipsis);
    Widget fitLine(String text, TextStyle style) =>
        FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(text, style: style, maxLines: 1));

    return AppCard(
      // Less padding on the right so Change area sits closer to the edge.
      padding: const EdgeInsets.fromLTRB(28, 16, 14, 16),
      child: Semantics(
        container: true,
        label: '${s.station.name}. $word.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: oneLine(context.tr('Saved area$distance', 'Kawasan disimpan$distance', '已保存地区$distance'), context.text.bodyMedium!)),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  key: const ValueKey('change-area'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    shape: const StadiumBorder(),
                    backgroundColor: c.background == Colors.white ? c.primaryTint : const Color(0xFFEAF1F8),
                    foregroundColor: c.primary,
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                  ),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SavedAreasScreen())),
                  child: Text(context.tr('Change area', 'Tukar kawasan')),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  fitLine(s.station.name, context.text.titleMedium!),
                  oneLine('${s.station.district}, ${s.station.state}', context.text.bodyMedium!),
                  const SizedBox(height: 16),
                  fitLine(word, context.text.displayMedium!.copyWith(color: style.color)),
                  Row(children: [
                    Icon(style.icon, color: style.color, size: 22),
                    const SizedBox(width: 8),
                    Expanded(child: oneLine(other, context.text.titleLarge!.copyWith(color: c.textMuted, fontWeight: FontWeight.w400))),
                  ]),
                  const SizedBox(height: 20),
                  fitLine(value, context.text.headlineLarge!.copyWith(fontWeight: FontWeight.w600, fontFeatures: AppText.tabular)),
                  // Kept even when empty so every card has the same height.
                  oneLine(nextLine ?? ' ', context.text.bodyLarge!.copyWith(color: c.textMuted, fontFeatures: AppText.tabular)),
                  const SizedBox(height: 4),
                  oneLine(
                    AppScope.of(context).deps.liveData
                        ? context.tr('Updated ${formatAge(context, s.age)} · JPS data', 'Dikemas kini ${formatAge(context, s.age)} · data JPS', '更新于${formatAge(context, s.age)} · JPS数据')
                        : context.tr('Updated ${formatAge(context, s.age)} · sample data', 'Dikemas kini ${formatAge(context, s.age)} · data contoh', '更新于${formatAge(context, s.age)} · 示例数据'),
                    context.text.bodyMedium!,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Next 3 hours" with the chart and the link to the AI's reasons.
class ForecastCard extends StatelessWidget {
  const ForecastCard({super.key, required this.area});
  final StationStatus area;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final f = app.forecastFor(area.station.id);
    final short = area.station.name.contains(' di ') ? area.station.name.split(' di ').last : area.station.name;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CardLabel(context.tr('Next ${f?.horizonHours ?? 3} hours · AI forecast · $short',
              '${f?.horizonHours ?? 3} jam akan datang · Ramalan AI · $short', '未来 ${f?.horizonHours ?? 3} 小时 · AI预测 · $short')),
          const SizedBox(height: 8),
          if (f == null) ...[
            Text(context.tr('No forecast for this area right now', 'Tiada ramalan untuk kawasan ini sekarang'), style: context.text.titleLarge),
            const SizedBox(height: 4),
            Text(
                app.forecast == null
                    ? context.tr('Forecast not loaded', 'Ramalan belum dimuatkan')
                    : (app.forecast!.unavailableReason ?? context.tr('The AI has no forecast for this station.', 'AI tiada ramalan untuk stesen ini.')),
                style: context.text.bodyMedium),
          ] else ...[
            Text(forecastSummary(context, f), style: context.text.titleLarge),
            const SizedBox(height: 4),
            Text(
              context.tr('Likely between ${metres(f.lowM)} and ${metres(f.highM)}', 'Mungkin antara ${metres(f.lowM)} dan ${metres(f.highM)}', '可能介于 ${metres(f.lowM)} 至 ${metres(f.highM)}'),
              style: context.text.bodyMedium!.copyWith(fontFeatures: AppText.tabular),
            ),
            const SizedBox(height: 12),
            if (area.riverLevel != null)
              ForecastChart(
                current: area.riverLevel!,
                forecast: f,
                thresholds: area.station.thresholds,
                levelNames: (l) => context.levelName(l),
                nowLabel: context.tr('Now', 'Kini'),
                semanticLabel: context.tr(
                    'River level now ${metres(area.riverLevel!)}. Forecast in ${f.horizonHours} hours ${metres(f.predictedLevelM)}, likely between ${metres(f.lowM)} and ${metres(f.highM)}.',
                    'Paras sungai kini ${metres(area.riverLevel!)}. Ramalan dalam ${f.horizonHours} jam ${metres(f.predictedLevelM)}, mungkin antara ${metres(f.lowM)} dan ${metres(f.highM)}.', '目前河流水位 ${metres(area.riverLevel!)}。预测 ${f.horizonHours} 小时后为 ${metres(f.predictedLevelM)}，可能介于 ${metres(f.lowM)} 至 ${metres(f.highM)}。'),
              ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: ReadAloudButton(id: 'forecast-${area.station.id}', text: () => forecastSpeech(context, area, f)),
            ),
            if (f.isPracticeData)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(context.tr('Practice model: not real predictions yet', 'Model latihan: belum ramalan sebenar'),
                    style: context.text.labelSmall),
              ),
            const SizedBox(height: 8),
            Divider(height: 1, color: context.colors.divider),
            LinkRow(
              label: context.tr('Why does the AI say this?', 'Kenapa AI kata begini?'),
              last: true,
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ForecastWhyScreen(stationId: area.station.id))),
            ),
          ],
        ],
      ),
    );
  }
}

/// Small card on Home that links the area's level to the household checklist.
class ChecklistSummaryCard extends StatelessWidget {
  const ChecklistSummaryCard({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final level = app.checklistLevel;
    final items = app.checklist(level);
    final done = items.where((i) => app.done.contains(i.id)).length;
    final head = switch (level) {
      RiskLevel.normal => context.tr('Keep your go-bag ready', 'Pastikan beg kecemasan sedia'),
      RiskLevel.alert => context.tr('Get ready to leave', 'Bersedia untuk keluar'),
      RiskLevel.warning => context.tr('Be ready to leave now', 'Bersedia untuk keluar sekarang'),
      RiskLevel.danger => context.tr('Leave now for the relief centre', 'Pergi ke pusat pemindahan sekarang'),
    };
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CardLabel(context.tr('Your checklist · ${context.levelName(level)}', 'Senarai semak anda · ${context.levelName(level)}', '您的清单 · ${context.levelName(level)}')),
          const SizedBox(height: 4),
          Text(head, style: context.text.titleLarge),
          Text(
            context.tr('$done of ${items.length} done${app.profile != null ? ' · made for your household' : ''}',
                '$done daripada ${items.length} selesai${app.profile != null ? ' · untuk isi rumah anda' : ''}',
                '已完成 $done / ${items.length}${app.profile != null ? ' · 为您的家庭定制' : ''}'),
            style: context.text.bodyLarge!.copyWith(color: context.colors.textMuted, fontFeatures: AppText.tabular),
          ),
          const SizedBox(height: 12),
          ProgressSegments(done: done, total: items.length),
          const SizedBox(height: 12),
          Divider(height: 1, color: context.colors.divider),
          LinkRow(
            label: context.tr('Open checklist', 'Buka senarai semak'),
            onTap: () => app.selectTab(AppTab.prepare),
          ),
          LinkRow(
            label: context.tr('Go step by step', 'Ikut langkah demi langkah'),
            last: true,
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChecklistStepsScreen(level: level))),
          ),
        ],
      ),
    );
  }
}

/// Stations at Alert or above right now, worst first. Tap one for details.
class HighRiskCard extends StatelessWidget {
  const HighRiskCard({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final list = app.homeData?.highRisk ?? const <StationStatus>[];
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CardLabel(context.tr('High risk now', 'Risiko tinggi sekarang')),
          if (list.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Text(context.tr('No stations at Alert or above.', 'Tiada stesen pada tahap Waspada atau lebih.'), style: context.text.bodyLarge),
            ),
          for (var k = 0; k < list.length; k++)
            Semantics(
              button: true,
              child: InkWell(
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => StationDetailScreen(stationId: list[k].station.id))),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 56),
                  decoration: BoxDecoration(
                      border: k == list.length - 1 ? null : Border(bottom: BorderSide(color: context.colors.divider))),
                  child: Row(children: [
                    Expanded(child: Text(list[k].station.name, style: context.text.bodyLarge)),
                    RiskBadge(list[k].level),
                    const SizedBox(width: 4),
                    const Chevron(),
                  ]),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
