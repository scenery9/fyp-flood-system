import 'package:flood_core/flood_core.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../app/forecast_text.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';
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

  /// "Alert me when the river reaches ... m": a number box, then save or remove.
  Future<void> _editHeight(StationStatus s) async {
    final app = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    final current = app.heights[s.station.id];
    final suggested = current ?? s.station.thresholds?.warning;
    // Result: a number to save, double.nan to remove, null to cancel.
    final result = await showDialog<double>(
      context: context,
      builder: (d) => _HeightDialog(initial: suggested, riverNow: s.riverLevel, canRemove: current != null),
    );
    if (result == null || !mounted) return;
    if (result.isNaN) {
      await app.removeHeightAlert(s.station.id);
      if (mounted) messenger.showSnackBar(SnackBar(content: Text(context.tr('Alert removed', 'Amaran dibuang', '已移除警报'))));
      return;
    }
    final error = await app.setHeightAlert(s.station.id, result);
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
        content: Text(switch (error) {
      null => context.tr('You will be alerted at ${metres(result)}', 'Anda akan diberitahu pada ${metres(result)}', '水位达到 ${metres(result)} 时将通知您'),
      HeightError.invalid => context.tr('Enter a river level in metres, for example 4.20', 'Masukkan paras sungai dalam meter, contohnya 4.20', '请输入以米为单位的水位，例如 4.20'),
      HeightError.limit => context.tr('You can set up to ${HeightAlertStore.maxHeights} river-level alerts. Remove one first.',
          'Anda boleh tetapkan sehingga ${HeightAlertStore.maxHeights} amaran paras sungai. Buang satu dahulu.',
          '最多可设置 ${HeightAlertStore.maxHeights} 个河流水位警报，请先移除一个。'),
    })));
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
                  label: known ? null : (s.isStale ? context.tr('Old data', 'Data lama') : context.tr('No river data', 'Tiada data sungai'))),
              const SizedBox(height: 12),
              _Line(context.tr('River level', 'Paras sungai'), s.riverLevel == null ? '—' : metres(s.riverLevel!)),
              if (s.percentToTarget != null && s.targetLevel != null)
                _Line(context.tr('Towards ${context.levelName(s.targetLevel)}', 'Menuju ${context.levelName(s.targetLevel)}', '接近${context.levelName(s.targetLevel)}'),
                    '${s.percentToTarget!.round()}%'),
              _Line(context.tr('Rainfall', 'Hujan'), s.rainfall == null ? '—' : '${s.rainfall!.toStringAsFixed(1)} mm/h'),
              _Line(context.tr('Updated', 'Dikemas kini'), formatAge(context, s.age)),
              const SizedBox(height: 8),
              Text(s.mainCause, style: context.text.bodyMedium),
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
              key: const ValueKey('copy-status'),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                final msg = context.tr('Copied. Paste it into WhatsApp or SMS.', 'Disalin. Tampal ke WhatsApp atau SMS.');
                await Clipboard.setData(ClipboardData(text: const ShareFormatter().statusText(s)));
                messenger.showSnackBar(SnackBar(content: Text(msg)));
              },
              icon: const Icon(Icons.copy),
              label: Text(context.tr('Copy status to share', 'Salin status untuk dikongsi')),
            ),
            if (s.station.thresholds != null || s.riverLevel != null) ...[
              const SizedBox(height: kGap),
              OutlinedButton.icon(
                key: const ValueKey('height-alert'),
                onPressed: () => _editHeight(s),
                icon: const Icon(Icons.notifications_none),
                label: Text(app.heights[s.station.id] == null
                    ? context.tr('Alert me at a river level', 'Beritahu saya pada paras sungai', '设定河流水位警报')
                    : context.tr('River-level alert: ${metres(app.heights[s.station.id]!)}',
                        'Amaran paras sungai: ${metres(app.heights[s.station.id]!)}',
                        '河流水位警报：${metres(app.heights[s.station.id]!)}')),
              ),
            ],
          ]),
        ),
        NoteText(app.deps.liveData
            ? context.tr('JPS Selangor data, logged every 15 minutes. Not an official warning.',
                'Data JPS Selangor, direkod setiap 15 minit. Bukan amaran rasmi.', 'JPS雪兰莪数据，每15分钟记录一次。不是官方警报。')
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

/// The river-level alert box. Owns its text field, so the field is only
/// thrown away after the dialog has fully closed.
class _HeightDialog extends StatefulWidget {
  const _HeightDialog({required this.initial, required this.riverNow, required this.canRemove});
  final double? initial;
  final double? riverNow;
  final bool canRemove;

  @override
  State<_HeightDialog> createState() => _HeightDialogState();
}

class _HeightDialogState extends State<_HeightDialog> {
  late final TextEditingController _field =
      TextEditingController(text: widget.initial?.toStringAsFixed(2) ?? '');

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(context.tr('River-level alert', 'Amaran paras sungai', '河流水位警报')),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(context.tr('Notify me when the river here reaches this level (metres).',
              'Beritahu saya apabila paras sungai di sini mencecah paras ini (meter).',
              '当此处河流水位达到以下高度（米）时通知我。')),
          if (widget.riverNow != null) ...[
            const SizedBox(height: 8),
            Text(context.tr('Now: ${metres(widget.riverNow!)}', 'Sekarang: ${metres(widget.riverNow!)}',
                '目前：${metres(widget.riverNow!)}')),
          ],
          TextField(
            key: const ValueKey('height-field'),
            controller: _field,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
            decoration: const InputDecoration(suffixText: 'm'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(context.tr('Cancel', 'Batal', '取消'))),
          if (widget.canRemove)
            TextButton(
                key: const ValueKey('height-remove'),
                onPressed: () => Navigator.of(context).pop(double.nan),
                child: Text(context.tr('Remove', 'Buang', '移除'))),
          TextButton(
            key: const ValueKey('height-save'),
            onPressed: () {
              final v = double.tryParse(_field.text.trim().replaceAll(',', '.'));
              // Not a number: infinity, which the app turns into "enter a river level".
              Navigator.of(context).pop(v ?? double.infinity);
            },
            child: Text(context.tr('Save', 'Simpan', '保存')),
          ),
        ],
      );
}
