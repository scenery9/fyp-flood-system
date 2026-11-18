import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import 'app_controller.dart';

/// Turn-by-turn wording in the app's language, built from the step type,
/// so a route saved in English reads in Malay or Chinese without internet.
/// Steps without a type (routes saved by an older version) keep the
/// server's English text.
String stepText(BuildContext context, RouteStep s) {
  final kind = StepKind.fromOrs(s.type);
  if (kind == null) return s.instruction;
  final n = s.name;
  String on(String en, String ms, String zh) => n == null
      ? context.tr(en, ms, zh)
      : context.tr('$en onto $n', '$ms ke $n', '$zh，进入$n');
  return switch (kind) {
    StepKind.depart => n == null
        ? context.tr('Start', 'Mula', '出发')
        : context.tr('Start on $n', 'Mula di $n', '从$n出发'),
    StepKind.left => on('Turn left', 'Belok kiri', '左转'),
    StepKind.right => on('Turn right', 'Belok kanan', '右转'),
    StepKind.sharpLeft => on('Turn sharp left', 'Belok tajam ke kiri', '向左急转'),
    StepKind.sharpRight => on('Turn sharp right', 'Belok tajam ke kanan', '向右急转'),
    StepKind.slightLeft => on('Bear left', 'Condong ke kiri', '稍向左转'),
    StepKind.slightRight => on('Bear right', 'Condong ke kanan', '稍向右转'),
    StepKind.straight => n == null
        ? context.tr('Continue straight', 'Terus lurus', '直行')
        : context.tr('Continue straight on $n', 'Terus lurus di $n', '沿$n直行'),
    StepKind.enterRoundabout => s.exitNumber == null
        ? on('Enter the roundabout', 'Masuk bulatan', '进入环岛')
        : on('At the roundabout, take exit ${s.exitNumber}', 'Di bulatan, ambil susur keluar ${s.exitNumber}',
            '在环岛走第 ${s.exitNumber} 个出口'),
    StepKind.exitRoundabout => on('Leave the roundabout', 'Keluar dari bulatan', '驶出环岛'),
    StepKind.uTurn => context.tr('Make a U-turn', 'Buat pusingan U', '掉头'),
    StepKind.arrive => context.tr('Arrive at the relief centre', 'Tiba di pusat pemindahan', '到达疏散中心'),
    StepKind.keepLeft => on('Keep left', 'Ikut kiri', '靠左行驶'),
    StepKind.keepRight => on('Keep right', 'Ikut kanan', '靠右行驶'),
  };
}

IconData stepIcon(RouteStep s) => switch (StepKind.fromOrs(s.type)) {
      StepKind.left => Icons.turn_left,
      StepKind.right => Icons.turn_right,
      StepKind.sharpLeft => Icons.turn_sharp_left,
      StepKind.sharpRight => Icons.turn_sharp_right,
      StepKind.slightLeft => Icons.turn_slight_left,
      StepKind.slightRight => Icons.turn_slight_right,
      StepKind.straight => Icons.straight,
      StepKind.enterRoundabout => Icons.roundabout_left,
      StepKind.exitRoundabout => Icons.roundabout_right,
      StepKind.uTurn => Icons.u_turn_left,
      StepKind.arrive => Icons.flag,
      StepKind.depart => Icons.trip_origin,
      StepKind.keepLeft => Icons.fork_left,
      StepKind.keepRight => Icons.fork_right,
      null => Icons.navigation_outlined,
    };

String distanceText(double m) => m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} km' : '${m.round()} m';

/// "just now", "20 min ago", "3 h ago", "2 days ago".
String savedAgo(BuildContext context, DateTime at) {
  final d = DateTime.now().difference(at);
  if (d.inMinutes < 1) return context.tr('just now', 'sebentar tadi', '刚刚');
  if (d.inHours < 1) return context.tr('${d.inMinutes} min ago', '${d.inMinutes} min lalu', '${d.inMinutes} 分钟前');
  if (d.inDays < 1) return context.tr('${d.inHours} h ago', '${d.inHours} jam lalu', '${d.inHours} 小时前');
  return context.tr('${d.inDays} days ago', '${d.inDays} hari lalu', '${d.inDays} 天前');
}
