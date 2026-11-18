import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import 'app_controller.dart';

/// The AI forecast in the app's language. English matches flood_core's
/// own wording; Malay and Chinese are built from the same numbers.

String forecastSummary(BuildContext c, StationForecast f) {
  final h = f.horizonHours;
  final p = f.predictedRisk;
  final now = f.currentRisk;
  if (p == null || now == null) {
    final d = f.changeM.abs().toStringAsFixed(2);
    return switch (f.trend) {
      Trend.rising => c.tr('River expected to rise by $d m in about $h hours', 'Sungai dijangka naik $d m dalam kira-kira $h jam',
          '预计河流在约 $h 小时内上升 $d 米'),
      Trend.falling => c.tr('River expected to fall by $d m in about $h hours', 'Sungai dijangka turun $d m dalam kira-kira $h jam',
          '预计河流在约 $h 小时内下降 $d 米'),
      Trend.steady => c.tr('River expected to stay about the same for the next $h hours',
          'Sungai dijangka kekal hampir sama untuk $h jam akan datang', '预计未来 $h 小时河流水位大致不变'),
    };
  }
  final name = c.levelName(p);
  if (p.index > now.index) {
    return c.tr('Expected to rise to $name level in about $h hours', 'Dijangka naik ke tahap $name dalam kira-kira $h jam',
        '预计约 $h 小时内升至“$name”级别');
  }
  if (p.index < now.index) {
    return c.tr('Expected to fall to $name level in about $h hours', 'Dijangka turun ke tahap $name dalam kira-kira $h jam',
        '预计约 $h 小时内降至“$name”级别');
  }
  return c.tr('Expected to stay at $name level for the next $h hours', 'Dijangka kekal pada tahap $name untuk $h jam akan datang',
      '预计未来 $h 小时保持在“$name”级别');
}

String _window(BuildContext c, String feature) {
  if (feature.endsWith('_1h')) return c.tr('the last hour', 'sejam lalu', '过去1小时');
  if (feature.endsWith('_3h')) return c.tr('the last 3 hours', '3 jam lalu', '过去3小时');
  if (feature.endsWith('_6h')) return c.tr('the last 6 hours', '6 jam lalu', '过去6小时');
  return c.tr('the last 24 hours', '24 jam lalu', '过去24小时');
}

/// One reason, without the "(raises the forecast)" part. [raises] says which way it pushed.
({String text, bool raises}) forecastReason(BuildContext c, ForecastFactor f) {
  final v = f.value;
  final w = _window(c, f.feature);
  final up = f.feature.startsWith('up_');
  final rain = f.feature.contains('rain_sum');
  final change = f.feature.contains('level_change');
  String text;
  if (up && v == null) {
    text = c.tr('No upstream river readings', 'Tiada bacaan sungai di hulu', '没有上游河流读数');
  } else if (rain && v != null) {
    final mm = v.round();
    if (v < 0.5) {
      text = up
          ? c.tr('Almost no rain upstream in $w', 'Hampir tiada hujan di hulu dalam $w', '$w上游几乎没有下雨')
          : c.tr('Almost no rain in $w', 'Hampir tiada hujan dalam $w', '$w几乎没有下雨');
    } else {
      text = up
          ? c.tr('$mm mm of rain upstream in $w', '$mm mm hujan di hulu dalam $w', '$w上游降雨 $mm 毫米')
          : c.tr('$mm mm of rain in $w', '$mm mm hujan dalam $w', '$w降雨 $mm 毫米');
    }
  } else if (change && v != null) {
    final m = v.abs().toStringAsFixed(2);
    if (v.abs() < 0.005) {
      text = up
          ? c.tr('Upstream river unchanged in $w', 'Sungai di hulu tidak berubah dalam $w', '$w上游河流没有变化')
          : c.tr('River level unchanged in $w', 'Paras sungai tidak berubah dalam $w', '$w河流水位没有变化');
    } else if (v > 0) {
      text = up
          ? c.tr('Upstream river rose $m m in $w', 'Sungai di hulu naik $m m dalam $w', '$w上游河流上升 $m 米')
          : c.tr('River rose $m m in $w', 'Sungai naik $m m dalam $w', '$w河流上升 $m 米');
    } else {
      text = up
          ? c.tr('Upstream river fell $m m in $w', 'Sungai di hulu turun $m m dalam $w', '$w上游河流下降 $m 米')
          : c.tr('River fell $m m in $w', 'Sungai turun $m m dalam $w', '$w河流下降 $m 米');
    }
  } else if (f.feature == 'level_above_normal' && v != null) {
    final m = v.abs().toStringAsFixed(2);
    text = v >= 0
        ? c.tr('River is $m m above its normal level', 'Sungai $m m di atas paras biasa', '河流比正常水位高 $m 米')
        : c.tr('River is $m m below its normal level', 'Sungai $m m di bawah paras biasa', '河流比正常水位低 $m 米');
  } else {
    text = c.tr('Other readings', 'Bacaan lain', '其他读数');
  }
  return (text: text, raises: f.impactM > 0);
}

/// What "Read aloud" says for one area's forecast.
String forecastSpeech(BuildContext c, StationStatus s, StationForecast f) {
  String m(double v) => c.tr('${v.toStringAsFixed(2)} metres', '${v.toStringAsFixed(2)} meter', '${v.toStringAsFixed(2)} 米');
  final parts = <String>[
    s.station.name,
    forecastSummary(c, f),
    c.tr('Likely between ${m(f.lowM)} and ${m(f.highM)}.', 'Mungkin antara ${m(f.lowM)} dan ${m(f.highM)}.',
        '可能介于 ${m(f.lowM)} 至 ${m(f.highM)}。'),
  ];
  if (f.factors.isNotEmpty) {
    parts.add(c.tr('Main reasons:', 'Sebab utama:', '主要原因：'));
    for (final x in f.factors) {
      final r = forecastReason(c, x);
      parts.add('${r.text}, ${r.raises ? c.tr('which pushes the level up', 'yang menaikkan paras', '使水位上升') : c.tr('which pulls the level down', 'yang menurunkan paras', '使水位下降')}.');
    }
  }
  parts.add(c.tr('This is a computer prediction, not an official warning.', 'Ini ramalan komputer, bukan amaran rasmi.',
      '这是电脑预测，不是官方警报。'));
  return parts.join(' ');
}
