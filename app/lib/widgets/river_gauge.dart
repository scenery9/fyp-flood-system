import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import '../app/app_controller.dart';
import '../theme/app_theme.dart';
import 'common.dart';

/// The AI forecast as "Now → By 1:30 pm": two boxes with the level and
/// its JPS word, then the change in plain words. Read aloud says the same.
class ForecastGauge extends StatelessWidget {
  const ForecastGauge({super.key, required this.status, required this.forecast});
  final StationStatus status;
  final StationForecast forecast;

  @override
  Widget build(BuildContext context) {
    final now = status.riverLevel!;
    final f = forecast;
    final time = forecastTime(context, f);
    final nowLevel = status.isActionable ? status.level : null;
    final semantics = context.tr(
        'River level now ${metres(now)}. By $time about ${metres(f.predictedLevelM)}, likely between ${metres(f.lowM)} and ${metres(f.highM)}.',
        'Paras sungai kini ${metres(now)}. Menjelang $time kira-kira ${metres(f.predictedLevelM)}, mungkin antara ${metres(f.lowM)} dan ${metres(f.highM)}.',
        '目前河流水位 ${metres(now)}。到 $time 约 ${metres(f.predictedLevelM)}，可能介于 ${metres(f.lowM)} 至 ${metres(f.highM)}。');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Semantics(
        key: ValueKey('now-later-${status.station.id}'),
        label: semantics,
        container: true,
        excludeSemantics: true,
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Expanded(child: _LevelBox(label: context.tr('Now', 'Kini', '目前'), metresText: metres(now), level: nowLevel, keyName: 'gauge-now')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Icon(Icons.arrow_forward, color: context.colors.textMuted),
          ),
          Expanded(
            child: _LevelBox(
                label: context.tr('By $time', 'Menjelang $time', '到 $time'),
                metresText: metres(f.predictedLevelM),
                level: f.predictedRisk,
                keyName: 'gauge-later'),
          ),
        ]),
      ),
      const SizedBox(height: 8),
      Text(changeParts(context, status, f).$1, key: const ValueKey('gauge-change'),
          style: context.text.bodyLarge!.copyWith(fontFeatures: AppText.tabular)),
      // Distance to the next line: smaller, on its own line.
      if (changeParts(context, status, f).$2 case final line?)
        Text(line, key: const ValueKey('gauge-line'),
            style: context.text.bodyMedium!.copyWith(color: context.colors.textMuted, fontFeatures: AppText.tabular)),
    ]);
  }
}

/// Clock time the forecast is for, e.g. "1:30 PM" (phone's 12/24-hour style).
String forecastTime(BuildContext context, StationForecast f) {
  final t = f.validAt.toLocal();
  return MaterialLocalizations.of(context)
      .formatTimeOfDay(TimeOfDay.fromDateTime(t), alwaysUse24HourFormat: MediaQuery.of(context).alwaysUse24HourFormat);
}

/// "Rising slowly (+7 cm) · 2 cm above the Danger line" (read aloud).
String changeLine(BuildContext context, StationStatus s, StationForecast f) {
  final (change, line) = changeParts(context, s, f);
  return line == null ? change : '$change · $line';
}

/// The change ("Rising slowly (+7 cm)") and, when the station has JPS
/// lines, how far it is from the next one ("2 cm above the Danger line").
(String, String?) changeParts(BuildContext context, StationStatus s, StationForecast f) {
  final now = s.riverLevel!;
  final cm = ((f.predictedLevelM - now) * 100).round();
  final change = cm.abs() < 2
      ? context.tr('Staying about the same', 'Kekal hampir sama', '大致不变')
      : cm > 0
          ? (cm < 20
              ? context.tr('Rising slowly (+$cm cm)', 'Naik perlahan (+$cm cm)', '缓慢上涨（+$cm 厘米）')
              : context.tr('Rising (+$cm cm)', 'Naik (+$cm cm)', '上涨（+$cm 厘米）'))
          : context.tr('Falling ($cm cm)', 'Turun ($cm cm)', '下降（$cm 厘米）');
  final t = s.station.thresholds;
  if (t == null) return (change, null);
  String? line;
  if (now >= t.danger) {
    final d = ((now - t.danger) * 100).round();
    line = context.tr('$d cm above the Danger line', '$d cm di atas garis Bahaya', '高于危险线 $d 厘米');
  } else {
    final (level, at) = now >= t.warning
        ? (RiskLevel.danger, t.danger)
        : now >= t.alert
            ? (RiskLevel.warning, t.warning)
            : (RiskLevel.alert, t.alert);
    final d = ((at - now) * 100).round();
    line = context.tr('$d cm below the ${context.levelName(level)} line', '$d cm di bawah garis ${context.levelName(level)}',
        '低于${context.levelName(level)}线 $d 厘米');
  }
  return (change, line);
}

class _LevelBox extends StatelessWidget {
  const _LevelBox({required this.label, required this.metresText, required this.level, required this.keyName});
  final String label;
  final String metresText;
  final RiskLevel? level;
  final String keyName;

  @override
  Widget build(BuildContext context) {
    final s = RiskStyle.of(level);
    return Container(
      key: ValueKey(keyName),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: s.tint, borderRadius: BorderRadius.circular(14)),
      child: MergeSemantics(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: context.text.bodyMedium!.copyWith(color: s.onTint)),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(metresText,
                maxLines: 1,
                style: context.text.headlineSmall!.copyWith(color: s.onTint, fontWeight: FontWeight.w600, fontFeatures: AppText.tabular)),
          ),
          Text(context.levelName(level), style: context.text.bodyMedium!.copyWith(color: s.onTint, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }
}
