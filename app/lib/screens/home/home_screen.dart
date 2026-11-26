import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../app/forecast_text.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';
import '../../widgets/read_aloud_button.dart';
import '../../widgets/river_gauge.dart';
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
                // SOS lives in the Danger checklist on Prepare (project scope), not on Home.
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

/// One word for a rain band, for the small pill on the Rainfall tile.
String rainShort(BuildContext context, RainIntensity? i) => switch (i) {
      RainIntensity.light => context.tr('Light', 'Renyai', '小雨'),
      RainIntensity.moderate => context.tr('Moderate', 'Sederhana', '中雨'),
      RainIntensity.heavy => context.tr('Heavy', 'Lebat', '大雨'),
      RainIntensity.veryHeavy => context.tr('Very heavy', 'Sangat lebat', '暴雨'),
      _ => context.tr('No rain', 'Tiada hujan', '无雨'),
    };

/// One area at a glance: name, an amber notice only when the reading is late,
/// River level and Rainfall side by side, then when JPS last updated.
/// Tap anywhere (outside Change / Save) for the full station details.
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
    final stale = g.freshness == Freshness.stale;
    final t = g.station.thresholds;
    final noRiverGauge = river == null && s.station.thresholds == null && s.riverLevel == null;

    // River tile footer: the next JPS line ("Alert at 2.50 m").
    String riverFoot;
    if (noRiverGauge) {
      riverFoot = context.tr('No river gauge nearby', 'Tiada tolok sungai berdekatan', '附近没有河水位站');
    } else if (t == null) {
      riverFoot = context.tr('No risk level given', 'Tiada tahap risiko', '无风险级别');
    } else {
      final next = g.level == RiskLevel.danger || g.targetLevel == null ? RiskLevel.danger : g.targetLevel!;
      riverFoot = context.tr('${context.levelName(next)} at ${lineHeight(g, next)}', '${context.levelName(next)} pada ${lineHeight(g, next)}',
          '${lineHeight(g, next)} 为${context.levelName(next)}');
    }
    final riverValue = noRiverGauge
        ? context.tr('No gauge', 'Tiada tolok', '无测站')
        : (g.riverLevel != null ? metres(g.riverLevel!) : '—');

    // Rain: this station's own gauge, else the nearest one reporting.
    final rain = app.rainFor(s);
    final rainAgo = rain != null && rain.age >= StationStatus.delayedAfter ? ' (${formatAge(context, rain.age)})' : '';
    final rainFoot = rain == null
        ? context.tr('None within 10 km', 'Tiada dalam 10 km', '10 公里内没有')
        : rain.isOwnGauge
            ? context.tr('At this station$rainAgo', 'Di stesen ini$rainAgo', '本站$rainAgo')
            : context.tr('Gauge ${rain.distanceKm!.toStringAsFixed(1)} km away$rainAgo', 'Tolok ${rain.distanceKm!.toStringAsFixed(1)} km$rainAgo',
                '雨量站 ${rain.distanceKm!.toStringAsFixed(1)} 公里$rainAgo');
    final rainHeavy = rain != null && rain.intensity.index >= RainIntensity.heavy.index;

    // One amber line only when something is wrong. A JPS problem says the
    // most (what JPS shows, and the last good reading), then an outdated
    // reading, then a late one. Hidden when the reading is live and fine.
    final notice = noRiverGauge
        ? null
        : switch (g.dataIssue) {
            DataIssue.stale => freshnessNotice(context, g),
            DataIssue.none || DataIssue.rainOnly => freshnessNotice(context, g),
            _ => dataIssueText(context, g),
          };
    // No usable level, but not simply old: a grey pill says why ("Invalid reading").
    final issuePill = known || noRiverGauge || g.dataIssue == DataIssue.stale ? null : dataIssueLabel(context, g);

    final distance = s.distanceKm == null ? '' : ' (${s.distanceKm!.toStringAsFixed(1)} km)';
    final source = app.deps.liveData ? context.tr('JPS data', 'Data JPS', 'JPS数据') : context.tr('Sample data', 'Data contoh', '示例数据');
    final riverWord = known ? context.levelName(g.level) : (dataIssueLabel(context, g) ?? '');
    final label = [
      '${s.station.name}$distance',
      context.tr('River level $riverValue', 'Paras sungai $riverValue', '河水位 $riverValue'),
      if (riverWord.isNotEmpty) riverWord,
      if (borrowed) context.tr('from ${g.station.name}', 'dari ${g.station.name}', '来自${g.station.name}'),
      rain == null
          ? context.tr('No rain gauge within 10 km', 'Tiada tolok hujan dalam 10 km', '10 公里内无雨量站')
          : context.tr('Rainfall ${rain.mmPerHr.toStringAsFixed(1)} mm/h, ${rainShort(context, rain.intensity)}',
              'Hujan ${rain.mmPerHr.toStringAsFixed(1)} mm/j, ${rainShort(context, rain.intensity)}',
              '雨量 ${rain.mmPerHr.toStringAsFixed(1)} 毫米/时，${rainShort(context, rain.intensity)}'),
      ?notice,
      updatedSince(context, g),
    ].join('. ');

    final pillStyle = FilledButton.styleFrom(
      minimumSize: const Size(48, 44),
      shape: const StadiumBorder(),
      backgroundColor: c.primaryTint,
      foregroundColor: c.primary,
      padding: const EdgeInsets.symmetric(horizontal: 18),
    );

    return AppCard(
      key: ValueKey('area-card-${s.station.id}'),
      onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => StationDetailScreen(stationId: g.station.id))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Top row: what this card is, and Change / Save.
        Row(children: [
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(color: c.primaryTint, borderRadius: BorderRadius.circular(12)),
              child: Text(
                nearestMode ? context.tr('Nearest to you', 'Paling dekat dengan anda', '离您最近') : context.tr('Saved area', 'Kawasan disimpan', '已保存地区'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: c.primary),
              ),
            ),
          ),
          const Spacer(),
          if (nearestMode)
            FilledButton.tonal(
              key: const ValueKey('save-nearest'),
              style: pillStyle,
              onPressed: () => app.follow(s.station.id),
              child: Text(context.tr('Save area', 'Simpan kawasan', '保存地区')),
            )
          else
            FilledButton.tonal(
              key: const ValueKey('change-area'),
              style: pillStyle,
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SavedAreasScreen())),
              child: Text(context.tr('Change', 'Tukar', '更改')),
            ),
        ]),
        const SizedBox(height: 8),
        Semantics(
          container: true,
          label: label,
          hint: context.tr('Open station details', 'Buka butiran stesen', '打开测站详情'),
          excludeSemantics: true,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Name with distance beside it, then district and state.
            Text('${s.station.name}$distance',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 18, height: 1.25, fontWeight: FontWeight.w700, color: c.text, fontFeatures: AppText.tabular)),
            const SizedBox(height: 2),
            Text('${s.station.district}, ${s.station.state}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: c.textMuted)),
            if (borrowed) ...[
              const SizedBox(height: 2),
              Text(
                context.tr('River gauge ${river.distanceKm!.toStringAsFixed(1)} km: ${g.station.name}',
                    'Tolok sungai ${river.distanceKm!.toStringAsFixed(1)} km: ${g.station.name}',
                    '河水位站（${river.distanceKm!.toStringAsFixed(1)} 公里）：${g.station.name}'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: c.textMuted, fontFeatures: AppText.tabular),
              ),
            ],
            if (notice != null) ...[const SizedBox(height: 12), AmberBanner(notice)],
            const SizedBox(height: 12),
            IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Expanded(
                  child: MetricTile(
                    key: const ValueKey('tile-river'),
                    title: context.tr('River level', 'Paras sungai', '河水位'),
                    pill: known
                        ? StatusPill.risk(context, g.level)
                        : (issuePill == null ? null : StatusPill(text: issuePill, color: RiskStyle.of(null).onTint, tint: RiskStyle.of(null).tint)),
                    value: riverValue,
                    valueMuted: noRiverGauge || stale || g.riverLevel == null,
                    footer: riverFoot,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: MetricTile(
                    key: const ValueKey('tile-rain'),
                    title: context.tr('Rainfall', 'Hujan', '雨量'),
                    pill: rain == null
                        ? null
                        : StatusPill(
                            text: rainShort(context, rain.intensity),
                            color: rainHeavy ? RiskStyle.of(RiskLevel.warning).onTint : c.primary,
                            tint: rainHeavy ? RiskStyle.of(RiskLevel.warning).tint : c.primaryTint,
                          ),
                    value: rain == null
                        ? context.tr('No gauge', 'Tiada tolok', '无测站')
                        : context.tr('${rain.mmPerHr.toStringAsFixed(1)} mm/h', '${rain.mmPerHr.toStringAsFixed(1)} mm/j',
                            '${rain.mmPerHr.toStringAsFixed(1)} 毫米/时'),
                    valueMuted: rain == null,
                    footer: rainFoot,
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: UpdatedLine(g, maxLines: 2)),
              const SizedBox(width: 8),
              Text(source, style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
            ]),
          ]),
        ),
      ]),
    );
  }
}

/// One half of the River level | Rainfall pair: title and pill, the big
/// reading, then one quiet line under it.
class MetricTile extends StatelessWidget {
  const MetricTile({super.key, required this.title, required this.value, required this.footer, this.pill, this.valueMuted = false});
  final String title;
  final Widget? pill;
  final String value;
  final bool valueMuted;
  final String footer;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final noValue = valueMuted && !RegExp(r'\d').hasMatch(value); // "No gauge", "—"
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(12),
        border: c.cardBorder == null ? null : Border.all(color: c.divider),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Title and pill wrap onto two lines at large text sizes.
        Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: c.textMuted)),
          ?pill,
        ]),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            style: noValue
                ? TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.textMuted)
                : TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    fontFeatures: AppText.tabular,
                    color: valueMuted ? const Color(0xFF475569) : c.text,
                  ),
          ),
        ),
        const SizedBox(height: 4),
        Text(footer,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: c.textMuted, fontFeatures: AppText.tabular)),
      ]),
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
