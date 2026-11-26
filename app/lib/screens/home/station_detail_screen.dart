import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../app/forecast_text.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';
import '../../widgets/share_sheet.dart';
import 'forecast_why_screen.dart';

/// One station: level, reading, rain, forecast, save and copy.
class StationDetailScreen extends StatefulWidget {
  const StationDetailScreen({super.key, required this.stationId});
  final String stationId;

  @override
  State<StationDetailScreen> createState() => _StationDetailScreenState();
}

class _StationDetailScreenState extends State<StationDetailScreen> {
  bool? _followed;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_followed == null) {
      AppScope.read(context).isFollowed(widget.stationId).then((v) {
        if (mounted) setState(() => _followed = v);
      });
    }
  }

  Future<void> _toggle() async {
    final app = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    final saved = context.tr('Saved to your areas', 'Disimpan ke kawasan anda');
    final removed = context.tr('Removed from your areas', 'Dibuang daripada kawasan anda');
    if (_followed == true) {
      await app.unfollow(widget.stationId);
      if (mounted) setState(() => _followed = false);
      messenger.showSnackBar(SnackBar(content: Text(removed)));
    } else {
      final limit = context.tr('You can save up to ${FollowedAreasService.maxAreas} areas. Remove one first.',
          'Anda boleh simpan sehingga ${FollowedAreasService.maxAreas} kawasan. Buang satu dahulu.',
          '最多只能保存 ${FollowedAreasService.maxAreas} 个地区，请先移除一个。');
      final gone = context.tr('This station no longer exists.', 'Stesen ini tiada lagi.', '此测站已不存在。');
      final error = await app.follow(widget.stationId);
      if (mounted) setState(() => _followed = error == null);
      messenger.showSnackBar(SnackBar(content: Text(switch (error) {
        null => saved,
        FollowError.limit => limit,
        FollowError.unknown => gone,
      })));
    }
  }

  /// "Alert me at a river level": the station's own Alert, Warning and
  /// Danger heights as buttons. Nothing to type or guess.
  Future<void> _chooseLevel(StationStatus s) async {
    final app = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    final current = app.heights[s.station.id];
    final choice = await showModalBottomSheet<_LevelPick>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _LevelSheet(status: s, currentM: current),
    );
    if (choice == null || !mounted) return;
    if (choice.remove) {
      await app.removeHeightAlert(s.station.id);
      if (mounted) messenger.showSnackBar(SnackBar(content: Text(context.tr('Alert removed', 'Amaran dibuang', '已移除警报'))));
      return;
    }
    final error = await app.setLevelAlert(s.station.id, choice.level!);
    if (!mounted) return;
    final m = app.heights[s.station.id] ?? 0;
    messenger.showSnackBar(SnackBar(
        content: Text(switch (error) {
      null => context.tr('You will be alerted at ${context.levelName(choice.level)} (${metres(m)})',
          'Anda akan diberitahu pada tahap ${context.levelName(choice.level)} (${metres(m)})',
          '水位达到${context.levelName(choice.level)}（${metres(m)}）时将通知您'),
      HeightError.invalid => context.tr('This station has no river levels to choose from.', 'Stesen ini tiada paras sungai untuk dipilih.',
          '此测站没有可选的河流水位。'),
      HeightError.limit => context.tr('You can set up to ${HeightAlertStore.maxHeights} river-level alerts. Remove one first.',
          'Anda boleh tetapkan sehingga ${HeightAlertStore.maxHeights} amaran paras sungai. Buang satu dahulu.',
          '最多可设置 ${HeightAlertStore.maxHeights} 个河流水位警报，请先移除一个。'),
    })));
  }

  /// Button text: "River-level alert: Warning (8.20 m)", or the height alone
  /// for one typed in an older version.
  String _alertLabel(BuildContext context, StationStatus s, double m) {
    final level = levelAtHeight(s.station.thresholds, m);
    return level == null
        ? context.tr('River-level alert: ${metres(m)}', 'Amaran paras sungai: ${metres(m)}', '河流水位警报：${metres(m)}')
        : context.tr('River-level alert: ${context.levelName(level)} (${metres(m)})',
            'Amaran paras sungai: ${context.levelName(level)} (${metres(m)})', '河流水位警报：${context.levelName(level)}（${metres(m)}）');
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.statusOf(widget.stationId);
    if (s == null) {
      return SubPage(title: context.tr('Station', 'Stesen'), children: [
        NoteText(context.tr('This station is no longer in the data.', 'Stesen ini tiada lagi dalam data.')),
      ]);
    }
    final f = app.forecastFor(s.station.id);
    final known = s.isActionable;
    return SubPage(
      title: s.station.name,
      children: [
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kMargin),
          child: AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${s.station.district}, ${s.station.state}', style: context.text.bodyMedium),
              const SizedBox(height: 12),
              RiskBadge(known ? s.level : null,
                  label: known ? null : (dataIssueLabel(context, s) ?? context.tr('No river data', 'Tiada data sungai', '没有河流数据'))),
              const SizedBox(height: 12),
              _Line(context.tr('River level', 'Paras sungai'), s.riverLevel == null ? '—' : metres(s.riverLevel!)),
              if (s.percentToTarget != null && s.targetLevel != null && s.level != RiskLevel.danger)
                _Line(context.tr('Towards ${context.levelName(s.targetLevel)}', 'Menuju ${context.levelName(s.targetLevel)}', '接近${context.levelName(s.targetLevel)}'),
                    // Same height in brackets as the River list: "91% (8.20 m)".
                    '${s.percentToTarget!.round()}%${lineHeight(s, s.targetLevel) == null ? '' : ' (${lineHeight(s, s.targetLevel)})'}'),
              _Line(context.tr('Rainfall', 'Hujan'), s.rainfall == null ? '—' : '${s.rainfall!.toStringAsFixed(1)} mm/h'),
              _Line(context.tr('Updated', 'Dikemas kini'), formatAge(context, s.age)),
              const SizedBox(height: 8),
              Text(dataIssueText(context, s) ?? s.mainCause, key: const ValueKey('station-cause'), style: context.text.bodyMedium),
            ]),
          ),
        ),
        if (f != null) ...[
          const SizedBox(height: kGap),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kMargin),
            child: AppCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                CardLabel(context.tr('AI forecast', 'Ramalan AI')),
                const SizedBox(height: 4),
                Text(forecastSummary(context, f), style: context.text.titleLarge),
                LinkRow(
                  label: context.tr('Why does the AI say this?', 'Kenapa AI kata begini?'),
                  last: true,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ForecastWhyScreen(stationId: s.station.id))),
                ),
              ]),
            ),
          ),
        ],
        const SizedBox(height: kGap),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kMargin),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            FilledButton.icon(
              key: const ValueKey('follow'),
              onPressed: _followed == null ? null : _toggle,
              icon: Icon(_followed == true ? Icons.star : Icons.star_border),
              label: Text(_followed == true ? context.tr('Remove from my areas', 'Buang dari kawasan saya') : context.tr('Save to my areas', 'Simpan ke kawasan saya')),
            ),
            const SizedBox(height: kGap),
            OutlinedButton.icon(
              key: const ValueKey('share-status'),
              onPressed: () => showShareSheet(context, const ShareFormatter().statusText(s)),
              icon: const Icon(Icons.share),
              label: Text(context.tr('Share status', 'Kongsi status', '分享状态')),
            ),
            // Only stations with official levels: the user picks a level, never types a height.
            if (s.station.thresholds != null) ...[
              const SizedBox(height: kGap),
              OutlinedButton.icon(
                key: const ValueKey('height-alert'),
                onPressed: () => _chooseLevel(s),
                icon: const Icon(Icons.notifications_none),
                label: Text(app.heights[s.station.id] == null
                    ? context.tr('Alert me at a river level', 'Beritahu saya pada paras sungai', '设定河流水位警报')
                    : _alertLabel(context, s, app.heights[s.station.id]!)),
              ),
            ],
          ]),
        ),
        NoteText(app.deps.liveData
            ? (s.station.state == 'Melaka'
                ? context.tr('JPS Melaka data, logged every 15 minutes (JPS updates it about once an hour). Not an official warning.',
                    'Data JPS Melaka, direkod setiap 15 minit (JPS mengemas kininya kira-kira sejam sekali). Bukan amaran rasmi.',
                    'JPS马六甲数据，每15分钟记录一次（JPS约每小时更新一次）。不是官方警报。')
                : context.tr('JPS Selangor data, logged every 15 minutes. Not an official warning.',
                    'Data JPS Selangor, direkod setiap 15 minit. Bukan amaran rasmi.', 'JPS雪兰莪数据，每15分钟记录一次。不是官方警报。'))
            : context.tr('Sample data. Not an official warning.', 'Data contoh. Bukan amaran rasmi.')),
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value);
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Expanded(child: Text(label, style: context.text.bodyLarge)),
          Text(value, style: context.text.bodyLarge!.copyWith(fontWeight: FontWeight.w600, fontFeatures: AppText.tabular)),
        ]),
      );
}

/// What was picked on the level sheet.
class _LevelPick {
  const _LevelPick.level(RiskLevel this.level) : remove = false;
  const _LevelPick.remove()
      : level = null,
        remove = true;
  final RiskLevel? level;
  final bool remove;
}

/// "Alert me when the river here reaches…": one big button per level,
/// with the height it starts at. Warning is marked as the suggested choice.
class _LevelSheet extends StatelessWidget {
  const _LevelSheet({required this.status, required this.currentM});
  final StationStatus status;
  final double? currentM;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = status.station.thresholds;
    final chosen = levelAtHeight(t, currentM);
    String meaning(RiskLevel l) => switch (l) {
          RiskLevel.alert => context.tr('Earliest notice. May come often in the rainy season.',
              'Notis paling awal. Mungkin kerap pada musim hujan.', '最早提醒，雨季可能较频繁。'),
          RiskLevel.warning => context.tr('Time to get ready to leave.', 'Masa untuk bersedia keluar.', '该准备撤离了。'),
          _ => context.tr('Only when you should leave now.', 'Hanya apabila anda patut keluar sekarang.', '仅在需要立即撤离时。'),
        };
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text(context.tr('Alert me when the river here reaches…', 'Beritahu saya apabila sungai di sini mencapai…', '当此处河流达到以下水位时提醒我…'),
              style: context.text.titleLarge),
          if (status.riverLevel != null) ...[
            const SizedBox(height: 4),
            Text(context.tr('Now: ${metres(status.riverLevel!)}', 'Sekarang: ${metres(status.riverLevel!)}', '目前：${metres(status.riverLevel!)}'),
                style: context.text.bodyLarge!.copyWith(color: c.textMuted, fontFeatures: AppText.tabular)),
          ],
          if (currentM != null && chosen == null) ...[
            const SizedBox(height: 4),
            Text(context.tr('Your alert now: ${metres(currentM!)} (set earlier)', 'Amaran anda kini: ${metres(currentM!)} (ditetapkan sebelum ini)',
                '您目前的警报：${metres(currentM!)}（之前设定）'),
                style: context.text.bodyMedium),
          ],
          const SizedBox(height: 16),
          for (final ch in levelChoicesFor(t))
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Semantics(
                button: true,
                selected: chosen == ch.level,
                child: InkWell(
                  key: ValueKey('level-${ch.level.name}'),
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => Navigator.of(context).pop(_LevelPick.level(ch.level)),
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 72),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: chosen == ch.level ? const Color(0xFFEAF1F8) : Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: chosen == ch.level ? c.primary : c.divider, width: 2),
                    ),
                    child: Row(children: [
                      RiskBadge(ch.level),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(
                              ch.recommended
                                  ? context.tr('From ${metres(ch.metres)} · suggested', 'Dari ${metres(ch.metres)} · dicadangkan', '${metres(ch.metres)} 起 · 建议')
                                  : context.tr('From ${metres(ch.metres)}', 'Dari ${metres(ch.metres)}', '${metres(ch.metres)} 起'),
                              style: context.text.titleMedium!.copyWith(fontFeatures: AppText.tabular)),
                          Text(meaning(ch.level), style: context.text.bodyMedium),
                        ]),
                      ),
                      if (chosen == ch.level) Icon(Icons.check, color: c.primary),
                    ]),
                  ),
                ),
              ),
            ),
          if (currentM != null)
            TextButton(
              key: const ValueKey('height-remove'),
              onPressed: () => Navigator.of(context).pop(const _LevelPick.remove()),
              child: Text(context.tr('Remove this alert', 'Buang amaran ini', '移除此警报')),
            ),
          Text(context.tr('Heights are this station\'s official JPS levels.', 'Paras ialah tahap rasmi JPS bagi stesen ini.',
              '水位为此测站的JPS官方等级。'), style: context.text.bodyMedium),
        ]),
      ),
    );
  }
}
