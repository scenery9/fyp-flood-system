import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../app/forecast_text.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';
import '../../widgets/read_aloud_button.dart';
import '../../widgets/river_gauge.dart';
import '../../widgets/sos_button.dart';
import '../more/saved_areas_screen.dart';
import '../prepare/checklist_steps_screen.dart';
import '../report/report_screen.dart';
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
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const ScreenTitle('FloodReady'),
          const SizedBox(height: kGap),
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
                const SizedBox(height: kGap),
                OutlinedButton.icon(
                  key: const ValueKey('report-flooding'),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ReportScreen())),
                  icon: const Icon(Icons.add_location_alt_outlined),
                  label: Text(context.tr('Report flooding', 'Laporkan banjir', '报告水灾')),
                ),
              ],
            ),
          ),
          if (area != null) ...[
            const SizedBox(height: kGap),
            // The forecast is for the river shown on the area card (a rain gauge borrows a nearby river gauge).
            Padding(padding: const EdgeInsets.symmetric(horizontal: kMargin), child: ForecastCard(area: app.riverStatusFor(area))),
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
    final nearest = app.nearest;
    if (areas.isEmpty && nearest != null) {
      // No saved areas yet: show the river station nearest the user, so a
      // new user sees something useful without any setup.
      return Padding(
        padding: const EdgeInsets.only(bottom: kGap),
        child: AreaCard(status: nearest, nearestMode: true),
      );
    }
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
          child: AnimatedSwitcher(
            duration: MediaQuery.of(context).disableAnimations ? Duration.zero : const Duration(milliseconds: 250),
            child: AreaCard(key: ValueKey(areas[i].station.id), status: areas[i]),
          ),
        ),
        // Arrows sit beside the dots, under the card, so the card's text lines
        // up with the other Home cards instead of making room for them.
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (i > 0)
              _Arrow(icon: Icons.chevron_left, label: context.tr('Previous area', 'Kawasan sebelumnya'), onTap: () => app.selectArea(i - 1))
            else
              const SizedBox(width: _Arrow.width),
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
            if (i < areas.length - 1)
              _Arrow(icon: Icons.chevron_right, label: context.tr('Next area', 'Kawasan seterusnya'), onTap: () => app.selectArea(i + 1))
            else
              const SizedBox(width: _Arrow.width),
          ],
        ),
      ],
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow({required this.icon, required this.label, required this.onTap});

  /// A full 48 dp touch target.
  static const double width = 48;
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
          customBorder: const CircleBorder(),
          child: SizedBox(width: width, height: 48, child: Icon(icon, color: AppColors.chevron, size: 28)),
        ),
      );
}

/// JPS 1-hour rain band in words (null or 0 mm: no rain).
String rainWord(BuildContext context, RainIntensity? i) => switch (i) {
      RainIntensity.light => context.tr('Light rain', 'Hujan renyai', '小雨'),
      RainIntensity.moderate => context.tr('Moderate rain', 'Hujan sederhana', '中雨'),
      RainIntensity.heavy => context.tr('Heavy rain', 'Hujan lebat', '大雨'),
      RainIntensity.veryHeavy => context.tr('Very heavy rain', 'Hujan sangat lebat', '暴雨'),
      _ => context.tr('No rain now', 'Tiada hujan sekarang', '目前无雨'),
    };

/// One area's status: the risk word, the river reading and when it was read.
class AreaCard extends StatelessWidget {
  const AreaCard({super.key, required this.status, this.nearestMode = false});
  final StationStatus status;

  /// Shown as "Nearest to you" with a Save button (no saved areas yet).
  final bool nearestMode;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = status;
    final c = context.colors;
    // River: this station's own gauge, else the nearest river gauge reporting
    // (a rain gauge such as Kg. Sg. Putat RF has no river level of its own).
    final river = app.riverFor(s);
    final g = river?.gauge ?? s;
    final borrowed = river != null && !river.isOwnGauge;
    final known = g.level != null && !g.isStale;
    final style = RiskStyle.of(known ? g.level : null);
    final t = g.station.thresholds;
    String? nextLine;
    if (t != null && g.targetLevel != null && g.level != RiskLevel.danger) {
      final v = switch (g.targetLevel!) {
        RiskLevel.normal => t.normal,
        RiskLevel.alert => t.alert,
        RiskLevel.warning => t.warning,
        RiskLevel.danger => t.danger,
      };
      nextLine = context.tr('${context.levelName(g.targetLevel)} from ${metres(v)}', '${context.levelName(g.targetLevel)} dari ${metres(v)}', '${metres(v)} 起为${context.levelName(g.targetLevel)}');
    } else if (t != null && g.level == RiskLevel.danger) {
      nextLine = context.tr('Danger from ${metres(t.danger)}', 'Bahaya dari ${metres(t.danger)}', '${metres(t.danger)} 起为危险');
    }
    final distance = s.distanceKm == null ? '' : ' · ${s.distanceKm!.toStringAsFixed(1)} km';
    // A rain gauge with no river gauge: lead with the rain, not "No recent data".
    final rainOnly = !known && t == null && s.riverLevel == null && s.rainfall != null && !s.isStale;
    final heavyRain = rainOnly && (s.rainIntensity?.index ?? 0) >= RainIntensity.heavy.index;
    final word = known
        ? context.levelName(g.level)
        : rainOnly
            ? rainWord(context, s.rainIntensity)
            : context.tr('No recent data', 'Tiada data terkini');
    final other = borrowed
        ? context.tr('River gauge ${river.distanceKm!.toStringAsFixed(1)} km: ${g.station.name}',
            'Tolok sungai ${river.distanceKm!.toStringAsFixed(1)} km: ${g.station.name}',
            '河水位站（${river.distanceKm!.toStringAsFixed(1)} 公里）：${g.station.name}')
        : known
        ? (app.language == AppLanguage.ms ? g.level!.labelEn : g.level!.labelBm)
        : rainOnly
            ? context.tr('Rain gauge only, no river reading', 'Tolok hujan sahaja, tiada bacaan sungai', '仅雨量站，无河水位读数')
            : (s.isStale ? context.tr('Last reading is too old to use', 'Bacaan terakhir terlalu lama') : context.tr('No river reading', 'Tiada bacaan sungai'));
    final wordColor = !rainOnly ? style.color : (heavyRain ? RiskStyle.of(RiskLevel.warning).color : c.primary);
    final icon = rainOnly ? Icons.water_drop : style.icon;

    // The big reading says what it is: river water (or rain, for a rain gauge).
    final valueLabel = rainOnly ? context.tr('Rain: ', 'Hujan: ', '雨量：') : context.tr('River water: ', 'Air sungai: ', '河水位：');
    final value = rainOnly ? '${s.rainfall!.toStringAsFixed(1)} mm/h' : (g.riverLevel != null ? metres(g.riverLevel!) : '—');
    void openDetails() =>
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => StationDetailScreen(stationId: g.station.id)));

    // Rain: this station's own gauge, else the nearest one reporting (named, with distance).
    final rain = app.rainFor(s);
    final rainHeavy = rain != null && rain.intensity.index >= RainIntensity.heavy.index;
    final rainColor = rain == null ? c.textMuted : (rainHeavy ? RiskStyle.of(RiskLevel.warning).color : c.primary);
    final rainLine = rain == null
        ? context.tr('Rain: no rain data now', 'Hujan: tiada data hujan sekarang', '雨量：目前无雨量数据')
        : context.tr('Rain: ${rainWord(context, rain.intensity)} · ${rain.mmPerHr.toStringAsFixed(1)} mm/h',
            'Hujan: ${rainWord(context, rain.intensity)} · ${rain.mmPerHr.toStringAsFixed(1)} mm/j',
            '雨量：${rainWord(context, rain.intensity)} · ${rain.mmPerHr.toStringAsFixed(1)} 毫米/时');
    final rainAge = rain != null && rain.age > const Duration(minutes: 75) ? ' · ${formatAge(context, rain.age)}' : '';
    final rainWhere = rain == null
        ? context.tr('No rain gauge reporting within 10 km', 'Tiada tolok hujan melapor dalam 10 km', '10 公里内无雨量站报告')
        : rain.isOwnGauge
            ? context.tr('Rain gauge at this station$rainAge', 'Tolok hujan di stesen ini$rainAge', '本站雨量计$rainAge')
            : context.tr('Nearest rain gauge (${rain.distanceKm!.toStringAsFixed(1)} km): ${rain.gauge.station.name}$rainAge',
                'Tolok hujan terdekat (${rain.distanceKm!.toStringAsFixed(1)} km): ${rain.gauge.station.name}$rainAge',
                '最近雨量站（${rain.distanceKm!.toStringAsFixed(1)} 公里）：${rain.gauge.station.name}$rainAge');
    // Every line has a fixed slot and is one line long, so all saved-area
    // cards are the same height and the carousel does not jump on change.
    Widget oneLine(String text, TextStyle style) => Text(text, style: style, maxLines: 1, overflow: TextOverflow.ellipsis);
    Widget fitLine(String text, TextStyle style) =>
        FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(text, style: style, maxLines: 1));

    // Same padding (16) and small top label as the other Home cards, so the
    // text lines up with the AI forecast and checklist cards below.
    // Tap anywhere on the card for the full station details (like the high-risk list).
    return AppCard(
      key: ValueKey('area-card-${s.station.id}'),
      onTap: openDetails,
      child: Semantics(
        container: true,
        button: true,
        hint: context.tr('Open station details', 'Buka butiran stesen', '打开测站详情'),
        label: '${s.station.name}. $word. ${borrowed ? '$other. ' : ''}$rainLine. $rainWhere.',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                    child: oneLine(
                        nearestMode
                            ? context.tr('Nearest to you$distance', 'Paling dekat dengan anda$distance', '离您最近$distance')
                            : context.tr('Saved area$distance', 'Kawasan disimpan$distance', '已保存地区$distance'),
                        context.text.labelMedium!)),
                const SizedBox(width: 8),
                if (nearestMode)
                  FilledButton.tonal(
                    key: const ValueKey('save-nearest'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      shape: const StadiumBorder(),
                      backgroundColor: c.background == Colors.white ? c.primaryTint : const Color(0xFFEAF1F8),
                      foregroundColor: c.primary,
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                    ),
                    onPressed: () => app.follow(s.station.id),
                    child: Text(context.tr('Save area', 'Simpan kawasan', '保存地区')),
                  )
                else
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
            const SizedBox(height: 4),
            Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  fitLine(s.station.name, context.text.titleMedium!),
                  oneLine('${s.station.district}, ${s.station.state}', context.text.bodyMedium!),
                  const SizedBox(height: 16),
                  fitLine(word, context.text.displayMedium!.copyWith(color: wordColor)),
                  Row(children: [
                    Icon(icon, color: wordColor, size: 22),
                    const SizedBox(width: 8),
                    Expanded(child: oneLine(other, context.text.titleLarge!.copyWith(color: c.textMuted, fontWeight: FontWeight.w400))),
                  ]),
                  const SizedBox(height: 20),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(valueLabel, style: context.text.titleMedium!.copyWith(color: c.textMuted, fontWeight: FontWeight.w400)),
                      Flexible(child: fitLine(value, context.text.headlineLarge!.copyWith(fontWeight: FontWeight.w600, fontFeatures: AppText.tabular))),
                    ],
                  ),
                  // Kept even when empty so every card has the same height.
                  oneLine(nextLine ?? ' ', context.text.bodyLarge!.copyWith(color: c.textMuted, fontFeatures: AppText.tabular)),
                  const SizedBox(height: 12),
                  Row(children: [
                    Icon(Icons.water_drop, color: rainColor, size: 20),
                    const SizedBox(width: 6),
                    Expanded(
                        child: oneLine(rainLine, context.text.bodyLarge!.copyWith(
                            color: rain == null ? c.textMuted : null, fontWeight: rainHeavy ? FontWeight.w600 : null))),
                  ]),
                  Padding(
                    padding: const EdgeInsets.only(left: 26),
                    child: oneLine(rainWhere, context.text.bodyMedium!.copyWith(color: c.textMuted)),
                  ),
                  const SizedBox(height: 8),
                  Row(children: [
                    Expanded(
                      child: oneLine(
                        AppScope.of(context).deps.liveData
                            ? context.tr('Updated ${formatAge(context, g.age)} · JPS data', 'Dikemas kini ${formatAge(context, g.age)} · data JPS', '更新于${formatAge(context, g.age)} · JPS数据')
                            : context.tr('Updated ${formatAge(context, g.age)} · sample data', 'Dikemas kini ${formatAge(context, g.age)} · data contoh', '更新于${formatAge(context, g.age)} · 示例数据'),
                        context.text.bodyMedium!,
                      ),
                    ),
                    Text(context.tr('Details', 'Butiran', '详情'), style: context.text.bodyMedium!.copyWith(color: c.primary)),
                    const Chevron(),
                  ]),
                ],
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
    final f = app.cardForecastFor(area.station.id);
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
            if (area.riverLevel != null) ForecastGauge(status: area, forecast: f),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: ReadAloudButton(id: 'forecast-${area.station.id}', text: () => forecastSpeech(context, area, f)),
            ),
            if (f.isPracticeData)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  TagBadge(
                    key: const ValueKey('practice-forecast'),
                    text: context.tr('Practice forecast', 'Ramalan latihan', '练习预测'),
                    color: const Color(0xFF7A4A00),
                    tint: const Color(0xFFFFF1D6),
                    icon: Icons.science_outlined,
                  ),
                  Text(context.tr('Not real predictions yet', 'Belum ramalan sebenar', '尚非真实预测'), style: context.text.bodyMedium),
                ]),
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
