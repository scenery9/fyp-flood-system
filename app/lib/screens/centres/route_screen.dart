import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_map.dart';
import '../../widgets/common.dart';

/// Road route to a relief centre inside the app: map, distance, time and
/// turn-by-turn steps (openrouteservice). Google Maps stays as a backup.
class RouteScreen extends StatefulWidget {
  const RouteScreen({super.key, required this.centre});
  final EvacuationPoint centre;

  @override
  State<RouteScreen> createState() => _RouteScreenState();
}

class _RouteScreenState extends State<RouteScreen> {
  RouteOutcome? _result;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_result == null) _load();
  }

  Future<void> _load() async {
    final r = await AppScope.read(context).routeTo(widget.centre);
    if (mounted) setState(() => _result = r);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final r = _result;
    final plan = r?.plan;
    final c = widget.centre;
    final straightKm = distanceKm(app.userLocation, c.location);

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
              MapPin(
                id: c.id,
                at: c.location,
                color: const Color(0xFF176B3A),
                icon: Icons.local_hospital,
                selected: true,
                semantics: c.name,
              ),
            ],
            route: plan != null ? plan.path : [app.userLocation, c.location],
            straightLine: plan == null,
            height: 300,
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
              else if (plan != null)
                Text(
                  context.tr('${plan.distanceKm.toStringAsFixed(1)} km · about ${plan.durationMin} min by car',
                      '${plan.distanceKm.toStringAsFixed(1)} km · kira-kira ${plan.durationMin} min dengan kereta',
                      '${plan.distanceKm.toStringAsFixed(1)} 公里 · 开车约 ${plan.durationMin} 分钟'),
                  style: context.text.titleMedium!.copyWith(fontFeatures: AppText.tabular),
                )
              else ...[
                Text(
                  r.error == RouteError.notSetUp
                      ? context.tr('Road route inside the app is not set up yet.', 'Laluan jalan dalam aplikasi belum disediakan.',
                          '应用内道路路线尚未设置。')
                      : context.tr('Could not get the road route. Check your internet.', 'Tidak dapat mendapatkan laluan jalan. Semak internet anda.',
                          '无法取得道路路线，请检查网络。'),
                  style: context.text.bodyLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  context.tr('${straightKm.toStringAsFixed(1)} km away in a straight line (dotted).',
                      '${straightKm.toStringAsFixed(1)} km dalam garis lurus (bertitik).', '直线距离 ${straightKm.toStringAsFixed(1)} 公里（虚线）。'),
                  style: context.text.bodyMedium!.copyWith(fontFeatures: AppText.tabular),
                ),
              ],
              const SizedBox(height: 16),
              if (r != null && plan == null && r.error == RouteError.failed) ...[
                FilledButton.icon(
                  key: const ValueKey('route-retry'),
                  onPressed: () {
                    setState(() => _result = null);
                    _load();
                  },
                  icon: const Icon(Icons.refresh),
                  label: Text(context.tr('Try again', 'Cuba lagi', '重试')),
                ),
                const SizedBox(height: kGap),
              ],
              googleButton(),
            ]),
          ),
        ),
        if (plan != null && plan.steps.isNotEmpty) ...[
          SectionHeader(context.tr('Turn by turn', 'Arah demi arah', '逐步导航')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kMargin),
            child: AppCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(children: [
                for (var i = 0; i < plan.steps.length; i++)
                  Container(
                    constraints: const BoxConstraints(minHeight: 56),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    decoration: BoxDecoration(
                        border: i == plan.steps.length - 1 ? null : Border(bottom: BorderSide(color: context.colors.divider))),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Container(
                        width: 28,
                        height: 28,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: context.colors.primaryTint, shape: BoxShape.circle),
                        child: Text('${i + 1}',
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: context.colors.primary, fontFeatures: AppText.tabular)),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(plan.steps[i].instruction, style: context.text.bodyLarge),
                          if (plan.steps[i].distanceM >= 1)
                            Text(_distance(plan.steps[i].distanceM), style: context.text.bodyMedium!.copyWith(fontFeatures: AppText.tabular)),
                        ]),
                      ),
                    ]),
                  ),
              ]),
            ),
          ),
          NoteText(context.tr('Step wording comes from openrouteservice in English.', 'Arahan langkah daripada openrouteservice dalam bahasa Inggeris.',
              '步骤说明来自openrouteservice，仅有英文。')),
        ],
        NoteText(context.tr('Do not drive through flood water. Roads may close quickly; follow police and APM directions.',
            'Jangan memandu meredah air banjir. Jalan mungkin ditutup dengan cepat; ikut arahan polis dan APM.',
            '切勿驾车涉水。道路可能很快封闭，请听从警方和民防部队的指示。')),
      ],
    );
  }

  static String _distance(double m) => m >= 1000 ? '${(m / 1000).toStringAsFixed(1)} km' : '${m.round()} m';
}
