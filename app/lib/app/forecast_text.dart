import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import '../widgets/river_gauge.dart';
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
  if (feature.endsWith('_72h')) return c.tr('the last 3 days', '3 hari lalu', '过去3天');
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
  final weather = weatherInputText(c, f.feature, v) ?? rainHistoryText(c, f.feature, v);
  if (weather != null) {
    text = weather;
  } else if (up && v == null) {
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
  } else if (f.feature.startsWith('same_time_') && v != null) {
    // what the river did in the 3 hours after the same moment one tide (12 h) or one day (25 h) ago
    final h = f.feature == 'same_time_12h_ago' ? 12 : 25;
    final m = v.abs().toStringAsFixed(2);
    if (v.abs() < 0.005) {
      text = c.tr('$h hours ago, the river stayed the same over the next 3 hours',
          '$h jam lalu, sungai kekal sama dalam 3 jam berikutnya', '$h 小时前，河流在随后3小时保持不变');
    } else if (v > 0) {
      text = c.tr('$h hours ago, the river rose $m m over the next 3 hours',
          '$h jam lalu, sungai naik $m m dalam 3 jam berikutnya', '$h 小时前，河流在随后3小时上升 $m 米');
    } else {
      text = c.tr('$h hours ago, the river fell $m m over the next 3 hours',
          '$h jam lalu, sungai turun $m m dalam 3 jam berikutnya', '$h 小时前，河流在随后3小时下降 $m 米');
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
    if (s.riverLevel != null)
      c.tr('Now ${m(s.riverLevel!)}. By ${forecastTime(c, f)}, about ${m(f.predictedLevelM)}.',
          'Kini ${m(s.riverLevel!)}. Menjelang ${forecastTime(c, f)}, kira-kira ${m(f.predictedLevelM)}.',
          '目前 ${m(s.riverLevel!)}。到 ${forecastTime(c, f)}，约 ${m(f.predictedLevelM)}。'),
    if (s.riverLevel != null) '${changeLine(c, s, f)}.',
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

/// The window a weather-forecast input is about (0 = the next 3 hours).
String forecastWindow(BuildContext c, int day) => switch (day) {
      0 => c.tr('the next 3 hours', '3 jam akan datang', '未来3小时'),
      1 => c.tr('the next 24 hours', '24 jam akan datang', '未来24小时'),
      2 => c.tr('24-48 hours from now', '24-48 jam dari sekarang', '24至48小时后'),
      _ => c.tr('48-72 hours from now', '48-72 jam dari sekarang', '48至72小时后'),
    };

int _forecastDay(String feature) {
  if (feature.contains('next_3h')) return 0;
  for (final d in const [1, 2, 3]) {
    if (feature.contains('day$d')) return d;
  }
  return 3;
}

/// Open-Meteo and MET Malaysia inputs of the model, in the app's language; null for other inputs.
String? weatherInputText(BuildContext c, String feature, double? v) {
  if (!ForecastService.isWeatherForecastInput(feature)) return null;
  if (v == null) return c.tr('No weather forecast logged', 'Tiada ramalan cuaca direkodkan', '没有记录天气预报');
  final w = forecastWindow(c, _forecastDay(feature));
  final n = v.round();
  if (feature == 'fc_rain_next_3h' || (feature.startsWith('fc_rain_day') && feature.endsWith('_mm'))) {
    return v < 0.5
        ? c.tr('Forecast: almost no rain in $w', 'Ramalan: hampir tiada hujan dalam $w', '预报：$w几乎无雨')
        : c.tr('Forecast: $n mm of rain in $w', 'Ramalan: $n mm hujan dalam $w', '预报：$w降雨 $n 毫米');
  }
  if (feature.startsWith('fc_rain_prob')) {
    return c.tr('Forecast: $n% of weather models expect rain in $w', 'Ramalan: $n% model cuaca menjangka hujan dalam $w',
        '预报：$n% 的天气模型预计$w有雨');
  }
  if (feature.startsWith('met_rain_class_day')) {
    final k = MetRainClass.fromNumber(v);
    return c.tr('MET Malaysia forecast: ${k?.labelEn ?? 'unknown'} in $w',
        'Ramalan MET Malaysia: ${k?.labelBm ?? 'tidak diketahui'} dalam $w');
  }
  return switch (feature) {
    'fc_rain_days_3d' => c.tr('Rain forecast on $n of the next 3 days', 'Hujan diramal pada $n daripada 3 hari akan datang',
        '未来3天中有 $n 天预报有雨'),
    'fc_rain_total_3d' => c.tr('Forecast: $n mm of rain over the next 3 days', 'Ramalan: $n mm hujan dalam 3 hari akan datang',
        '预报：未来3天降雨 $n 毫米'),
    'met_thunder_days_3d' => c.tr('MET Malaysia: thunderstorms forecast on $n of the next 3 days',
        'MET Malaysia: ribut petir diramal pada $n daripada 3 hari akan datang'),
    'met_warning_level' => v < 0.5
        ? c.tr('No MET Malaysia rain warning', 'Tiada amaran hujan MET Malaysia')
        : c.tr('MET Malaysia warning in force: ${MetWarningLevel.fromNumber(v).labelEn}',
            'Amaran MET Malaysia berkuat kuasa: ${MetWarningLevel.fromNumber(v).labelBm}'),
    'sources_agree_days_3d' => c.tr('Open-Meteo and MET Malaysia agree on $n of the next 3 days',
        'Open-Meteo dan MET Malaysia sependapat pada $n daripada 3 hari akan datang'),
    _ => null,
  };
}

/// Rain-history inputs (observed at the station), in the app's language; null for other inputs.
String? rainHistoryText(BuildContext c, String feature, double? v) {
  if (v == null) return null;
  final n = v.round();
  return switch (feature) {
    'wet_hours_24h' => c.tr('Rain fell in $n of the last 24 hours', 'Hujan turun dalam $n daripada 24 jam lalu',
        '过去24小时中有 $n 小时下雨'),
    'consecutive_wet_hours' => n == 0
        ? c.tr('Not raining at the station now', 'Tidak hujan di stesen sekarang', '测站目前没有下雨')
        : c.tr('Raining without a break for $n hour(s)', 'Hujan tanpa henti selama $n jam', '已连续下雨 $n 小时'),
    'wet_days_3d' => c.tr('$n of the last 3 days were rain days (1 mm or more)',
        '$n daripada 3 hari lalu ialah hari hujan (1 mm atau lebih)', '过去3天中有 $n 天是雨日（≥1毫米）'),
    'api_7d' => c.tr('Ground wetness from the last 7 days of rain: $n mm (older rain counts less)',
        'Kebasahan tanah daripada hujan 7 hari lalu: $n mm (hujan lebih lama dikira kurang)',
        '过去7天降雨造成的土壤湿度：$n 毫米（越早的雨权重越小）'),
    'fc_rain_day1_x_fill' => c.tr('Forecast rain for the next 24 hours, weighted by how close the river is to Alert',
        'Ramalan hujan 24 jam akan datang, ditimbang mengikut betapa dekat sungai dengan tahap Waspada'),
    _ => null,
  };
}

// ---------- Flood chance (river reaching JPS Warning within 24 hours) ----------

String chanceBandName(BuildContext c, ChanceBand b) => switch (b) {
      ChanceBand.low => c.tr('Low', 'Rendah', '低'),
      ChanceBand.moderate => c.tr('Moderate', 'Sederhana', '中等'),
      ChanceBand.high => c.tr('High', 'Tinggi', '高'),
      ChanceBand.veryHigh => c.tr('Very high', 'Sangat tinggi', '很高'),
    };

String _pct(double p) => p > 0 && p < 0.01 ? '<1%' : '${(p * 100).round()}%';

/// "High chance of flood in the next 24 hours: 35%", or that the river is already there.
String floodHeadline(BuildContext c, FloodExplanation e) {
  final fc = e.chance;
  final h = fc.horizonHours;
  if (fc.already) {
    // name the highest level reached (Danger, if the river is past Warning too)
    final top = fc.levels[RiskLevel.danger]?.already == true ? RiskLevel.danger : fc.headlineLevel;
    final lv = c.levelName(top);
    return c.tr('River is at $lv level now: flooding is possible', 'Sungai kini di tahap $lv: banjir mungkin berlaku',
        '河流目前处于“$lv”级别：可能发生水灾');
  }
  if (fc.chance == null || e.band == null) {
    return c.tr('Flood chance not known yet', 'Peluang banjir belum diketahui', '水灾概率尚未知');
  }
  final b = chanceBandName(c, e.band!);
  final p = _pct(fc.chance!);
  return c.tr('$b chance of flood in the next $h hours: $p', 'Peluang banjir ${b.toLowerCase()} dalam $h jam akan datang: $p',
      '未来 $h 小时内水灾概率$b：$p');
}

/// What "flood" means in the headline: "(river reaching JPS Warning level)".
String floodMeaning(BuildContext c, FloodChance fc) {
  final lv = c.levelName(fc.headlineLevel);
  return c.tr('Flood here means the river reaching the JPS $lv level',
      'Banjir di sini bermaksud sungai mencapai tahap $lv JPS', '此处的水灾指河流达到 JPS “$lv”级别');
}

/// "Alert 62% · Danger 8%": the other levels, smaller.
String otherLevelsLine(BuildContext c, FloodChance fc) {
  final parts = <String>[];
  for (final lv in const [RiskLevel.alert, RiskLevel.warning, RiskLevel.danger]) {
    if (lv == fc.headlineLevel) continue;
    final l = fc.levels[lv];
    if (l == null) continue;
    final name = c.levelName(lv);
    if (l.already) {
      parts.add(c.tr('$name: reached', '$name: sudah dicapai', '$name：已达到'));
    } else if (l.chance != null) {
      parts.add('$name ${_pct(l.chance!)}');
    }
  }
  return parts.join(' · ');
}

String _mm(double? v) => '${(v ?? 0).round()} mm';

String _intensity(BuildContext c, RainIntensity? i) => switch (i) {
      RainIntensity.veryHeavy => c.tr('very heavy ', 'sangat lebat ', '特大'),
      RainIntensity.heavy => c.tr('heavy ', 'lebat ', '大'),
      RainIntensity.moderate => c.tr('moderate ', 'sederhana ', '中'),
      _ => '',
    };

/// One plain reason for or against a flood, e.g. "Heavy rain without a break for 7 hours (48 mm in the last 24 hours)".
String floodReasonText(BuildContext c, FloodReason r) {
  final s = r.supports;
  switch (r.kind) {
    case FloodReasonKind.continuousRain:
      final i = _intensity(c, r.intensity);
      final w = r.windowHours ?? 24;
      final rain = c.tr('${i}rain', 'hujan $i'.trim(), '$i雨');
      return c.tr(
          '${rain[0].toUpperCase()}${rain.substring(1)} without a break for ${r.hours} hours (${_mm(r.mm)} in the last $w hours)',
          '${rain[0].toUpperCase()}${rain.substring(1)} tanpa henti selama ${r.hours} jam (${_mm(r.mm)} dalam $w jam lalu)',
          '已连续下$rain ${r.hours} 小时（过去 $w 小时 ${_mm(r.mm)}）');
    case FloodReasonKind.recentRain:
      return s
          ? c.tr('${_mm(r.mm)} of rain in the last 24 hours, on and off for ${r.hours ?? 0} hours',
              '${_mm(r.mm)} hujan dalam 24 jam lalu, berselang-seli selama ${r.hours ?? 0} jam',
              '过去24小时降雨 ${_mm(r.mm)}，断续下了 ${r.hours ?? 0} 小时')
          : c.tr('Little rain in the last 24 hours (${_mm(r.mm)})', 'Sedikit hujan dalam 24 jam lalu (${_mm(r.mm)})',
              '过去24小时雨量少（${_mm(r.mm)}）');
    case FloodReasonKind.wetGround:
      return s
          ? c.tr('Ground already wet: ${_mm(r.mm)} of rain in the last 3 days',
              'Tanah sudah basah: ${_mm(r.mm)} hujan dalam 3 hari lalu', '土壤已湿：过去3天降雨 ${_mm(r.mm)}')
          : c.tr('Ground fairly dry: ${_mm(r.mm)} of rain in the last 3 days',
              'Tanah agak kering: ${_mm(r.mm)} hujan dalam 3 hari lalu', '土壤较干：过去3天降雨 ${_mm(r.mm)}');
    case FloodReasonKind.riverHeight:
      final lv = c.levelName(r.level ?? RiskLevel.warning);
      final p = ((r.fraction ?? 0).clamp(0, 1) * 100).round();
      return s
          ? c.tr('River is $p% of the way to $lv', 'Sungai sudah $p% menuju tahap $lv', '河流已达“$lv”级别的 $p%')
          : c.tr('River is only $p% of the way to $lv', 'Sungai baru $p% menuju tahap $lv', '河流仅达“$lv”级别的 $p%');
    case FloodReasonKind.riverTrend:
      final m = r.metres ?? 0;
      final d = m.abs().toStringAsFixed(2);
      if (m.abs() < 0.005) return c.tr('River level steady', 'Paras sungai stabil', '河流水位平稳');
      // Near the coast a fall now often comes before a rise (the tide turns), and the
      // model learnt that from each station's past: say so instead of a contradiction.
      if (s && m < 0) {
        return c.tr('River fell $d m in 3 hours; here that is usually followed by a rise (tide)',
            'Sungai turun $d m dalam 3 jam; di sini biasanya diikuti kenaikan (pasang surut)',
            '河流3小时内下降 $d 米；此处之后通常会回升（潮汐）');
      }
      if (!s && m > 0) {
        return c.tr('River rose $d m in 3 hours; here that is usually followed by a fall (tide)',
            'Sungai naik $d m dalam 3 jam; di sini biasanya diikuti penurunan (pasang surut)',
            '河流3小时内上升 $d 米；此处之后通常会回落（潮汐）');
      }
      return m > 0
          ? c.tr('River rose $d m in the last 3 hours', 'Sungai naik $d m dalam 3 jam lalu', '过去3小时河流上升 $d 米')
          : c.tr('River fell $d m in the last 3 hours', 'Sungai turun $d m dalam 3 jam lalu', '过去3小时河流下降 $d 米');
    case FloodReasonKind.upstream:
      final m = r.metres;
      if (m == null && r.mm == null) {
        return c.tr('Upstream readings', 'Bacaan di hulu', '上游读数');
      }
      if (s) {
        return (m != null && m > 0.005)
            ? c.tr('Upstream river rose ${m.toStringAsFixed(2)} m in 3 hours', 'Sungai di hulu naik ${m.toStringAsFixed(2)} m dalam 3 jam',
                '上游河流3小时内上升 ${m.toStringAsFixed(2)} 米')
            : c.tr('${_mm(r.mm)} of rain upstream in 6 hours', '${_mm(r.mm)} hujan di hulu dalam 6 jam', '上游6小时降雨 ${_mm(r.mm)}');
      }
      return c.tr('Upstream river steady or falling', 'Sungai di hulu stabil atau turun', '上游河流平稳或下降');
    case FloodReasonKind.metWarning:
      final w = MetWarningLevel.fromNumber((r.metLevel ?? 1).toDouble());
      return c.tr('MET Malaysia rain warning in force (${w.labelEn})', 'Amaran hujan MET Malaysia berkuat kuasa (${w.labelBm})',
          '大马气象局降雨警告生效中（${w.labelEn}）');
    case FloodReasonKind.forecastRain:
      final pr = r.percent == null ? '' : c.tr(', ${r.percent!.round()}% of weather models agree',
          ', ${r.percent!.round()}% model cuaca sependapat', '，${r.percent!.round()}% 天气模型一致');
      return s
          ? c.tr('Forecast: ${_mm(r.mm)} of rain in the next 24 hours$pr', 'Ramalan: ${_mm(r.mm)} hujan dalam 24 jam akan datang$pr',
              '预报：未来24小时降雨 ${_mm(r.mm)}$pr')
          : c.tr('Little rain forecast for the next 24 hours (${_mm(r.mm)})',
              'Sedikit hujan diramal untuk 24 jam akan datang (${_mm(r.mm)})', '预报未来24小时雨量少（${_mm(r.mm)}）');
  }
}
