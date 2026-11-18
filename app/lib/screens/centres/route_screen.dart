import 'package:flood_core/flood_core.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../app/route_text.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_map.dart';
import '../../widgets/common.dart';
import '../../widgets/read_aloud_button.dart';
import 'headcount_screen.dart';

/// Road route to a relief centre inside the app: map, distance, time, and
/// the steps in one list with one step highlighted (large print, in colour,
/// drawn stronger on the map); Next / Back or tapping a step moves it. The route is kept on the phone,
/// so it still shows without internet. Google Maps stays as a backup.
class RouteScreen extends StatefulWidget {
  const RouteScreen({super.key, required this.centre});
  final EvacuationPoint centre;

  @override
  State<RouteScreen> createState() => _RouteScreenState();
}

class _RouteScreenState extends State<RouteScreen> {
  RouteOutcome? _result;

  /// The highlighted step; a new one for each route found.
  StepFocus? _focus;
  RoutePlan? _focusPlan;
  final _map = MapController();

  bool _updating = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_result == null) _load();
  }

  Future<void> _load({bool fresh = false}) async {
    final app = AppScope.read(context);
    if (fresh) setState(() => _updating = true);
    if (fresh) await app.refresh(); // new position first
    if (!mounted) return;
    final r = await app.routeTo(widget.centre, fresh: fresh);
    if (mounted) {
      setState(() {
        _result = r;
        _updating = false;
        if (fresh) _focus = null; // "Update route": follow the phone again
      });
    }
  }

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  /// Moves the highlight with [change] (a tap, Next or Back); then moves the
  /// map to that step and reads it aloud (when Read aloud is on).
  void _move(RoutePlan plan, bool Function() change) {
    if (!change()) return;
    setState(() {});
    final line = stepPath(plan, _focus!.index);
    if (line != null) {
      try {
        _map.fitCamera(CameraFit.coordinates(
            coordinates: [for (final p in line) LatLng(p.lat, p.lon)],
            padding: const EdgeInsets.fromLTRB(40, 48, 40, 40),
            maxZoom: 17));
      } catch (_) {
        // The map is not on screen yet; the list still moves.
      }
    }
    _announce(plan);
  }

  /// Reads the highlighted step aloud, if Read aloud is on.
  void _announce(RoutePlan plan) {
    if (!mounted) return;
    final app = AppScope.read(context);
    final f = _focus;
    if (!app.readAloud || f == null || f.index >= plan.steps.length) return;
    final text = stepText(context, plan.steps[f.index]);
    final id = 'step-${widget.centre.id}';
    // speak() stops anything else first; for the same id it would stop instead.
    if (app.speakingId == id) {
      app.stopSpeaking().then((_) => app.speak(id, text));
    } else {
      app.speak(id, text);
    }
  }

  /// Centres this far away are worth a reminder that closer ones may open.
  static const farKm = 10.0;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final r = _result;
    final plan = r?.plan;
    final c = widget.centre;
    final straightKm = distanceKm(app.userLocation, c.location);
    final hazards = plan == null ? const <RouteHazard>[] : routeHazards(plan, app.statuses);
    final old = r?.savedAt != null && DateTime.now().difference(r!.savedAt!) > SavedRoute.oldAfter;
    final gpsStep = plan == null ? 0 : currentStepIndex(plan, app.userLocation);
    if (plan != null && (_focus == null || !identical(_focusPlan, plan))) {
      _focus = StepFocus(plan.steps.length, start: gpsStep);
      _focusPlan = plan;
    } else if (plan != null && _focus!.follow(gpsStep)) {
      // The phone moved on to another step: say it, like a tap would.
      WidgetsBinding.instance.addPostFrameCallback((_) => _announce(plan));
    }
    final step = _focus?.index ?? 0;
    final stepLine = plan == null ? null : stepPath(plan, step);
    final canTranslate = plan == null || plan.steps.every((s) => StepKind.fromOrs(s.type) != null);

    Widget googleButton() => OutlinedButton.icon(
          key: const ValueKey('route-google'),
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            final msg = context.tr('Could not open maps.', 'Peta tidak dapat dibuka.');
            if (!await app.deps.opener.open(app.directionsTo(c))) messenger.showSnackBar(SnackBar(content: Text(msg)));
          },
          icon: const Icon(Icons.open_in_new),
          label: Text(context.tr('Open in Google Maps', 'Buka dalam Google Maps', '在Google地图中打开')),
        );

    String savedLine() {
      final ago = savedAgo(context, r!.savedAt!);
      if (r.fromSaved) {
        return context.tr('No internet: showing the route saved $ago.', 'Tiada internet: menunjukkan laluan yang disimpan $ago.',
            '没有网络：显示 $ago 保存的路线。');
      }
      return context.tr('Route saved $ago. It works without internet.', 'Laluan disimpan $ago. Boleh digunakan tanpa internet.',
          '路线已于 $ago 保存，没有网络也能使用。');
    }

    return SubPage(
      title: context.tr('Route to centre', 'Laluan ke pusat', '前往疏散中心的路线'),
      children: [
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kMargin),
          child: AppMap(
            you: app.userLocation,
            youLabel: context.tr('You are here', 'Anda di sini'),
            pins: [
              if (c.locationChecked)
                MapPin(
                  id: c.id,
                  at: c.location,
                  color: const Color(0xFF176B3A),
                  icon: Icons.local_hospital,
                  selected: true,
                  semantics: c.name,
                ),
              for (final h in hazards)
                MapPin(
                  id: h.status.station.id,
                  at: h.status.station.location!,
                  color: RiskStyle.of(h.status.level).color,
                  icon: RiskStyle.of(h.status.level).icon,
                  semantics: '${h.status.station.name}, ${context.levelName(h.status.level)}',
                ),
            ],
            route: plan != null ? plan.path : (c.locationChecked ? [app.userLocation, c.location] : null),
            straightLine: plan == null,
            highlight: stepLine,
            controller: _map,
            height: 280,
          ),
        ),
        const SizedBox(height: kGap),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kMargin),
          child: AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(c.name, style: context.text.titleLarge),
              const SizedBox(height: 4),
              if (r == null)
                Row(children: [
                  const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5)),
                  const SizedBox(width: 12),
                  Text(context.tr('Finding the road route…', 'Mencari laluan jalan…', '正在寻找道路路线……'), style: context.text.bodyLarge),
                ])
              else if (plan != null) ...[
                Text(
                  context.tr('${plan.distanceKm.toStringAsFixed(1)} km · about ${plan.durationMin} min by car',
                      '${plan.distanceKm.toStringAsFixed(1)} km · kira-kira ${plan.durationMin} min dengan kereta',
                      '${plan.distanceKm.toStringAsFixed(1)} 公里 · 开车约 ${plan.durationMin} 分钟'),
                  style: context.text.titleMedium!.copyWith(fontFeatures: AppText.tabular),
                ),
                if (r.savedAt != null) ...[
                  const SizedBox(height: 4),
                  Text(savedLine(), key: const ValueKey('route-saved'), style: context.text.bodyMedium),
                ],
              ] else ...[
                Text(
                  switch (r.error) {
                    RouteError.notSetUp => context.tr('Road route inside the app is not set up yet.',
                        'Laluan jalan dalam aplikasi belum disediakan.', '应用内道路路线尚未设置。'),
                    RouteError.unchecked => context.tr(
                        "This centre's location has not been checked yet, so the app gives no route. Google Maps searches for it by name.",
                        'Lokasi pusat ini belum disemak, jadi aplikasi tidak memberi laluan. Google Maps mencarinya mengikut nama.',
                        '此中心的位置尚未核实，因此应用不提供路线。Google地图会按名称搜索。'),
                    _ => context.tr('Could not get the road route. Check your internet.',
                        'Tidak dapat mendapatkan laluan jalan. Semak internet anda.', '无法取得道路路线，请检查网络。'),
                  },
                  style: context.text.bodyLarge,
                ),
                if (r.error != RouteError.unchecked) ...[
                  const SizedBox(height: 4),
                  Text(
                    context.tr('${straightKm.toStringAsFixed(1)} km away in a straight line (dotted).',
                        '${straightKm.toStringAsFixed(1)} km dalam garis lurus (bertitik).', '直线距离 ${straightKm.toStringAsFixed(1)} 公里（虚线）。'),
                    style: context.text.bodyMedium!.copyWith(fontFeatures: AppText.tabular),
                  ),
                ],
              ],
              if (old) ...[
                const SizedBox(height: 8),
                Container(
                  key: const ValueKey('route-old'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: RiskStyle.of(RiskLevel.warning).tint, borderRadius: BorderRadius.circular(12)),
                  child: Text(
                      context.tr('This route is old. Update it before you travel.', 'Laluan ini sudah lama. Kemas kini sebelum bertolak.',
                          '此路线已过时，出发前请更新。'),
                      style: context.text.bodyLarge!.copyWith(color: RiskStyle.of(RiskLevel.warning).onTint)),
                ),
              ],
              const SizedBox(height: 16),
              if (r != null && r.error != RouteError.notSetUp && r.error != RouteError.unchecked) ...[
                FilledButton.icon(
                  key: ValueKey(plan == null ? 'route-retry' : 'route-update'),
                  onPressed: _updating ? null : () => _load(fresh: true),
                  icon: _updating
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5))
                      : const Icon(Icons.refresh),
                  label: Text(_updating
                      ? context.tr('Updating route…', 'Mengemas kini laluan…', '正在更新路线……')
                      : plan == null
                          ? context.tr('Try again', 'Cuba lagi', '重试')
                          : context.tr('Update route from where I am', 'Kemas kini laluan dari lokasi saya', '从我的位置更新路线')),
                ),
                const SizedBox(height: kGap),
              ],
              googleButton(),
            ]),
          ),
        ),
        if (hazards.isNotEmpty) ...[
          const SizedBox(height: kGap),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kMargin),
            child: Container(
              key: const ValueKey('route-hazards'),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: RiskStyle.of(hazards.first.status.level).tint, borderRadius: BorderRadius.circular(kCardRadius)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(context.tr('This route passes near high water', 'Laluan ini melalui kawasan air tinggi', '此路线经过高水位地区'),
                    style: context.text.titleMedium!.copyWith(color: RiskStyle.of(hazards.first.status.level).onTint)),
                const SizedBox(height: 4),
                for (final h in hazards.take(3))
                  Text(
                      '${h.status.station.name}: ${context.levelName(h.status.level)} · ${h.distanceKm < 0.1 ? context.tr('on the route', 'di laluan', '在路线上') : context.tr('${(h.distanceKm * 1000).round()} m from the route', '${(h.distanceKm * 1000).round()} m dari laluan', '距路线 ${(h.distanceKm * 1000).round()} 米')}',
                      style: context.text.bodyLarge!.copyWith(color: RiskStyle.of(h.status.level).onTint, fontFeatures: AppText.tabular)),
                const SizedBox(height: 4),
                Text(
                    context.tr('Roads there may be flooded. Choose another centre or ask the police or APM for a safe way.',
                        'Jalan di sana mungkin banjir. Pilih pusat lain atau minta laluan selamat daripada polis atau APM.',
                        '那里的道路可能已被淹。请选择其他中心，或向警方或民防部队询问安全路线。'),
                    style: context.text.bodyMedium!.copyWith(color: RiskStyle.of(hazards.first.status.level).onTint)),
              ]),
            ),
          ),
        ],
        if (straightKm > farKm)
          NoteText(context.tr(
              'This centre is ${straightKm.toStringAsFixed(1)} km away. Closer centres may open during a flood; follow official announcements.',
              'Pusat ini ${straightKm.toStringAsFixed(1)} km jauhnya. Pusat yang lebih dekat mungkin dibuka semasa banjir; ikut pengumuman rasmi.',
              '此中心距离 ${straightKm.toStringAsFixed(1)} 公里。水灾期间可能会开放更近的中心，请留意官方公告。')),
        if (plan != null && plan.steps.isNotEmpty) ...[
          SectionHeader(context.tr('Steps', 'Langkah', '步骤')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kMargin),
            child: AppCard(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (var i = 0; i < plan.steps.length; i++)
                  _StepRow(
                    step: plan.steps[i],
                    index: i,
                    count: plan.steps.length,
                    focused: i == step,
                    last: i == plan.steps.length - 1,
                    onTap: () => _move(plan, () => _focus!.select(i)),
                  ),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      key: const ValueKey('step-back'),
                      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 56)),
                      onPressed: _focus!.atFirst ? null : () => _move(plan, _focus!.back),
                      icon: const Icon(Icons.arrow_upward),
                      label: Text(context.tr('Back', 'Kembali', '上一步')),
                    ),
                  ),
                  const SizedBox(width: kGap),
                  Expanded(
                    child: FilledButton.icon(
                      key: const ValueKey('step-next'),
                      style: FilledButton.styleFrom(minimumSize: const Size(0, 56)),
                      onPressed: _focus!.atLast ? null : () => _move(plan, _focus!.next),
                      icon: const Icon(Icons.arrow_downward),
                      label: Text(context.tr('Next', 'Seterusnya', '下一步')),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: ReadAloudButton(
                      id: 'route-${c.id}',
                      text: () => [for (final s in plan.steps.skip(step)) stepText(context, s)].join('. ')),
                ),
              ]),
            ),
          ),
          if (!canTranslate)
            NoteText(context.tr('Update the route to see the steps in your language.', 'Kemas kini laluan untuk melihat langkah dalam bahasa anda.',
                '更新路线即可以您的语言显示步骤。')),
        ],
        const SizedBox(height: kGap),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kMargin),
          child: OutlinedButton.icon(
            key: const ValueKey('route-headcount'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => HeadcountScreen(centre: c))),
            icon: const Icon(Icons.groups_outlined),
            label: Text(context.tr("Tell this centre we're coming", 'Beritahu pusat ini kami akan datang', '告知此中心我们正前往')),
          ),
        ),
        NoteText(context.tr('Routes do not show if a road is flooded. Never drive or walk through flood water; follow police and APM directions.',
            'Laluan tidak menunjukkan sama ada jalan banjir. Jangan memandu atau berjalan meredah air banjir; ikut arahan polis dan APM.',
            '路线无法显示道路是否被淹。切勿驾车或步行涉水，请听从警方和民防部队的指示。')),
      ],
    );
  }
}

/// One step in the list. The highlighted one is large and in colour; the
/// others are greyed out and can be tapped to highlight them.
class _StepRow extends StatelessWidget {
  const _StepRow(
      {required this.step, required this.index, required this.count, required this.focused, required this.last, required this.onTap});
  final RouteStep step;
  final int index;
  final int count;
  final bool focused;
  final bool last;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final muted = context.colors.textMuted;
    final text = stepText(context, step);
    final row = Container(
      key: ValueKey('step-$index'),
      constraints: BoxConstraints(minHeight: focused ? 96 : 56),
      padding: EdgeInsets.symmetric(vertical: focused ? 16 : 10),
      decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: context.colors.divider))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (focused)
          Icon(stepIcon(step), size: 48, color: context.colors.primary)
        else
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: context.colors.divider, shape: BoxShape.circle),
            child: Icon(stepIcon(step), size: 18, color: muted),
          ),
        SizedBox(width: focused ? 16 : 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(text,
                key: focused ? const ValueKey('next-step') : null,
                style: focused ? context.text.headlineSmall : context.text.bodyLarge!.copyWith(color: muted)),
            if (step.distanceM >= 1)
              Text(
                  focused
                      ? context.tr('then ${distanceText(step.distanceM)}', 'kemudian ${distanceText(step.distanceM)}',
                          '然后 ${distanceText(step.distanceM)}')
                      : distanceText(step.distanceM),
                  style: (focused ? context.text.bodyLarge! : context.text.bodyMedium!.copyWith(color: muted))
                      .copyWith(fontFeatures: AppText.tabular)),
            if (focused)
              Text(context.tr('Step ${index + 1} of $count', 'Langkah ${index + 1} daripada $count', '第 ${index + 1} 步，共 $count 步'),
                  style: context.text.bodyMedium),
          ]),
        ),
      ]),
    );
    if (focused) return Semantics(selected: true, child: row);
    return Semantics(
      button: true,
      label: context.tr('Step ${index + 1}: $text', 'Langkah ${index + 1}: $text', '第 ${index + 1} 步：$text'),
      excludeSemantics: true,
      child: InkWell(onTap: onTap, child: row),
    );
  }
}
