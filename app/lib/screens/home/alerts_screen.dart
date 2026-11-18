import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';
import '../more/info_screens.dart';
import 'station_detail_screen.dart';

/// Why a station is on the list, in words.
String alertWhy(BuildContext context, ActiveAlert a) {
  final km = a.status.distanceKm;
  return switch (a.why) {
    AlertWhy.saved => context.tr('Saved area', 'Kawasan disimpan', '已保存地区'),
    AlertWhy.nearest => context.tr('Nearest to you', 'Paling dekat dengan anda', '离您最近'),
    AlertWhy.nearby => km == null
        ? context.tr('Near you', 'Berdekatan anda', '在您附近')
        : context.tr('${km.toStringAsFixed(1)} km from you', '${km.toStringAsFixed(1)} km dari anda', '距您 ${km.toStringAsFixed(1)} 公里'),
  };
}

/// "Alerts": what needs attention now near the user, with no setup. One row
/// per station (not a log of every reading), worst first, then what the AI
/// expects in the next hours.
class AlertsScreen extends StatelessWidget {
  const AlertsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final a = app.alerts;
    final level = app.settings.notificationThreshold;
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('Alerts', 'Amaran', '警报'))),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: app.refresh,
          child: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              NoteText(context.tr(
                  'No setup needed. You get alerts for your saved areas, the station nearest you and stations within 10 km, from ${context.levelName(level)} level.',
                  'Tiada tetapan diperlukan. Anda menerima amaran untuk kawasan disimpan, stesen paling dekat dan stesen dalam 10 km, mulai tahap ${context.levelName(level)}.',
                  '无需设置。您会收到已保存地区、离您最近的测站及 10 公里内测站的警报（${context.levelName(level)}及以上）。')),
              if (app.locationIssue != null)
                NoteText(context.tr('Location is off, so only your saved areas are checked.',
                    'Lokasi dimatikan, jadi hanya kawasan disimpan anda disemak.', '定位已关闭，因此只检查已保存地区。')),
              SectionHeader(context.tr('Now', 'Sekarang', '目前')),
              if (a.now.isEmpty)
                GroupCard(children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(context.tr('No alerts right now.', 'Tiada amaran sekarang.', '目前没有警报。'), style: context.text.bodyLarge),
                  ),
                ])
              else
                GroupCard(children: [
                  for (var i = 0; i < a.now.length; i++) _AlertRow(alert: a.now[i], last: i == a.now.length - 1),
                ]),
              if (a.expected.isNotEmpty) ...[
                SectionHeader(context.tr('Expected in the next 3 hours · AI forecast', 'Dijangka dalam 3 jam · ramalan AI', '未来 3 小时预计 · AI预测')),
                GroupCard(children: [
                  for (var i = 0; i < a.expected.length; i++)
                    _AlertRow(alert: a.expected[i], expected: true, last: i == a.expected.length - 1),
                ]),
                NoteText(context.tr('This is a computer prediction, not an official warning.', 'Ini ramalan komputer, bukan amaran rasmi.',
                    '这是电脑预测，不是官方警报。')),
              ],
              SectionHeader(context.tr('Settings', 'Tetapan', '设置')),
              GroupCard(children: [
                LinkRow(
                  key: const ValueKey('alerts-notify-from'),
                  label: context.tr('Notify me from', 'Beritahu saya mulai'),
                  value: context.levelName(level),
                  last: true,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const NotifyLevelScreen())),
                ),
              ]),
              NoteText(app.deps.liveData
                  ? context.tr('JPS readings, checked every 15 minutes. Not an official warning; follow JPS and NADMA.',
                      'Bacaan JPS, disemak setiap 15 minit. Bukan amaran rasmi; ikut JPS dan NADMA.', 'JPS读数，每15分钟检查一次。不是官方警报，请听从JPS和NADMA。')
                  : context.tr('Sample data. Not an official warning.', 'Data contoh. Bukan amaran rasmi.')),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlertRow extends StatelessWidget {
  const _AlertRow({required this.alert, required this.last, this.expected = false});
  final ActiveAlert alert;
  final bool last;
  final bool expected;

  @override
  Widget build(BuildContext context) {
    final s = alert.status;
    final f = alert.forecast;
    final arrow = f == null
        ? ''
        : switch (f.trend) {
            Trend.rising => context.tr(' · rising', ' · meningkat', ' · 上涨中'),
            Trend.falling => context.tr(' · falling', ' · menurun', ' · 下降中'),
            Trend.steady => context.tr(' · steady', ' · stabil', ' · 平稳'),
          };
    final line = expected
        ? '${alertWhy(context, alert)} · ${context.tr('now ${context.levelName(s.isActionable ? s.level : null)}', 'kini ${context.levelName(s.isActionable ? s.level : null)}', '目前${context.levelName(s.isActionable ? s.level : null)}')}'
        : '${alertWhy(context, alert)} · ${formatAge(context, s.age)}$arrow';
    return Semantics(
      button: true,
      child: InkWell(
        key: ValueKey('alert-${s.station.id}'),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => StationDetailScreen(stationId: s.station.id))),
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: context.colors.divider))),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.station.name, style: context.text.titleMedium),
                Text(line, style: context.text.bodyMedium!.copyWith(fontFeatures: AppText.tabular)),
              ]),
            ),
            RiskBadge(alert.level,
                label: expected
                    ? context.tr('${context.levelName(alert.level)} expected', '${context.levelName(alert.level)} dijangka',
                        '预计${context.levelName(alert.level)}')
                    : null),
            const Chevron(),
          ]),
        ),
      ),
    );
  }
}

