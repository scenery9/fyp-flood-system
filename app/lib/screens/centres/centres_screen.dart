import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';
import '../../app/platform.dart';
import '../../widgets/app_map.dart';
import '../home/station_detail_screen.dart';
import 'route_screen.dart';

enum MapLayer { centres, rain, river }

/// Centres tab: relief centres near you with directions, plus rain and
/// river-forecast layers on the same map.
class CentresScreen extends StatefulWidget {
  const CentresScreen({super.key});

  @override
  State<CentresScreen> createState() => _CentresScreenState();
}

class _CentresScreenState extends State<CentresScreen> {
  /// Rain and river pins are shown within this distance; the lists below show all.
  static const double nearbyKm = 30;
  MapLayer _layer = MapLayer.centres;
  String? _selected;

  /// Road route for the selected centre, fetched in the background.
  String? _routeAskedFor;
  RoutePlan? _road;

  void _loadRoad(AppController app, EvacuationPoint p) {
    final key = '${p.id}@${app.userLocation.lat},${app.userLocation.lon}';
    if (_routeAskedFor == key) return;
    _routeAskedFor = key;
    _road = app.knownRoute(p);
    if (_road != null || app.deps.routes == null) return;
    app.routeTo(p).then((r) {
      if (mounted && _routeAskedFor == key) setState(() => _road = r.plan);
    });
  }

  static (String, Color, Color, IconData) centreStatus(BuildContext context, EvacuationPoint p) {
    if (!p.isOpen) return (context.tr('Not open', 'Belum dibuka'), const Color(0xFF4F5966), const Color(0xFFEEF0F2), Icons.block);
    if (p.isFull) return (context.tr('Full', 'Penuh'), const Color(0xFFA8221A), const Color(0xFFFBE3DF), Icons.group_off);
    return (context.tr('Open', 'Dibuka'), const Color(0xFF176B3A), const Color(0xFFE3F2E8), Icons.check_circle);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final centres = app.centres;
    final selectedId = _selected ?? app.nearestAvailable?.point.id ?? (centres.isEmpty ? null : centres.first.point.id);
    NearbyEvacuation? sel;
    for (final c in centres) {
      if (c.point.id == selectedId) sel = c;
    }

    if (sel != null) _loadRoad(app, sel.point);
    final road = sel != null && (_routeAskedFor?.startsWith('${sel.point.id}@') ?? false) ? _road : null;

    final pins = <MapPin>[];
    Widget? legend;
    switch (_layer) {
      case MapLayer.centres:
        for (final c in centres) {
          final st = centreStatus(context, c.point);
          pins.add(MapPin(
            id: c.point.id,
            at: c.point.location,
            color: st.$2,
            icon: Icons.local_hospital,
            selected: c.point.id == selectedId,
            semantics: '${c.point.name}, ${st.$1}, ${c.distanceKm.toStringAsFixed(1)} km',
          ));
        }
        legend = _Legend(title: context.tr('Relief centres', 'Pusat pemindahan'), rows: [
          (context.tr('Open', 'Dibuka'), const Color(0xFF176B3A), false),
          (context.tr('Full', 'Penuh'), const Color(0xFFA8221A), false),
          (context.tr('Not open', 'Belum dibuka'), const Color(0xFF4F5966), false),
        ]);
      case MapLayer.rain:
        for (final s in app.statuses) {
          if (s.station.location == null || s.rainfall == null || s.isStale) continue;
          if (distanceKm(app.userLocation, s.station.location!) > nearbyKm) continue;
          final heavy = (s.rainIntensity?.index ?? 0) >= RainIntensity.heavy.index;
          pins.add(MapPin(
            id: s.station.id,
            at: s.station.location!,
            color: _rainColor(s.rainIntensity),
            icon: Icons.water_drop,
            text: '${s.rainfall!.toStringAsFixed(0)} mm/h',
            selected: heavy,
            semantics: '${s.station.name}, ${s.rainfall!.toStringAsFixed(1)} mm/h, ${_rainName(context, s.rainIntensity)}',
          ));
        }
        legend = _Legend(title: context.tr('Rain now', 'Hujan kini'), rows: [
          (_rainName(context, RainIntensity.light), _rainColor(RainIntensity.light), true),
          (_rainName(context, RainIntensity.moderate), _rainColor(RainIntensity.moderate), true),
          (_rainName(context, RainIntensity.heavy), _rainColor(RainIntensity.heavy), true),
        ]);
      case MapLayer.river:
        for (final s in app.statuses) {
          if (s.station.location == null || s.station.thresholds == null) continue;
          if (distanceKm(app.userLocation, s.station.location!) > nearbyKm) continue;
          final f = app.forecastFor(s.station.id);
          final level = f?.predictedRisk ?? (s.isActionable ? s.level : null);
          pins.add(MapPin(
            id: s.station.id,
            at: s.station.location!,
            color: RiskStyle.of(level).color,
            icon: RiskStyle.of(level).icon,
            semantics: '${s.station.name}, ${context.levelName(level)} ${context.tr('in 3 hours', 'dalam 3 jam')}',
          ));
        }
        legend = _Legend(title: context.tr('In 3 hours', 'Dalam 3 jam'), rows: [
          for (final l in RiskLevel.values.reversed) (context.levelName(l), RiskStyle.of(l).color, false),
        ]);
    }

    return ListView(
      primary: false,
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        ScreenTitle(context.tr('Centres', 'Pusat'), subtitle: context.tr('Relief centres near you', 'Pusat pemindahan berdekatan anda')),
        if (app.locationIssue != null) ...[
          const SizedBox(height: kGap),
          const Padding(padding: EdgeInsets.symmetric(horizontal: kMargin), child: LocationNotice()),
        ],
        const SizedBox(height: kGap),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kMargin),
          child: PillSegments<MapLayer>(
            semanticsLabel: context.tr('Map layer', 'Lapisan peta'),
            values: MapLayer.values,
            selected: _layer,
            label: (l) => switch (l) {
              MapLayer.centres => context.tr('Centres', 'Pusat'),
              MapLayer.rain => context.tr('Rain', 'Hujan'),
              MapLayer.river => context.tr('River', 'Sungai'),
            },
            onChanged: (l) => setState(() => _layer = l),
          ),
        ),
        const SizedBox(height: kGap),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kMargin),
          child: AppMap(
            key: ValueKey(_layer),
            you: app.userLocation,
            pins: pins,
            // Solid road route when found; dotted straight line until then
            // (or when road routes are not set up / no internet).
            route: _layer == MapLayer.centres && sel != null ? (road?.path ?? [app.userLocation, sel.point.location]) : null,
            straightLine: road == null,
            youLabel: context.tr('You are here', 'Anda di sini'),
            legend: legend,
            onPinTap: (id) {
              if (_layer == MapLayer.centres) {
                setState(() => _selected = id);
              } else {
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => StationDetailScreen(stationId: id)));
              }
            },
          ),
        ),
        if (_layer == MapLayer.centres) ...[
          if (sel != null) ...[
            const SizedBox(height: kGap),
            Padding(padding: const EdgeInsets.symmetric(horizontal: kMargin), child: _SelectedCentre(item: sel)),
          ],
          const SizedBox(height: kGap),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kMargin),
            child: AppCard(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                CardLabel(context.tr('Nearest first', 'Paling dekat dahulu')),
                if (centres.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(context.tr('No relief centres listed.', 'Tiada pusat pemindahan disenaraikan.'), style: context.text.bodyLarge),
                  ),
                for (var i = 0; i < centres.length; i++)
                  _CentreRow(
                    item: centres[i],
                    selected: centres[i].point.id == selectedId,
                    last: i == centres.length - 1,
                    onTap: () => setState(() => _selected = centres[i].point.id),
                  ),
              ]),
            ),
          ),
        ],
        if (_layer == MapLayer.rain) ...[
          const SizedBox(height: kGap),
          Padding(padding: const EdgeInsets.symmetric(horizontal: kMargin), child: _RainList(statuses: app.statuses)),
        ],
        if (_layer == MapLayer.river) ...[
          const SizedBox(height: kGap),
          Padding(padding: const EdgeInsets.symmetric(horizontal: kMargin), child: _RiverList(statuses: app.statuses)),
        ],
        NoteText(context.tr(
            'Sample relief centres. Distances in the list are straight lines. A dotted line on the map means the road route is not loaded; Show route gives the road route and steps.',
            'Pusat pemindahan contoh. Jarak dalam senarai ialah garis lurus. Garis bertitik pada peta bermaksud laluan jalan belum dimuatkan; Tunjuk laluan memberi laluan jalan dan langkah.',
            '示例疏散中心。列表中的距离为直线距离。地图上的虚线表示道路路线尚未载入；“显示路线”会给出道路路线和步骤。')),
      ],
    );
  }

  static Color _rainColor(RainIntensity? r) => switch (r) {
        RainIntensity.veryHeavy => const Color(0xFF0B2E66),
        RainIntensity.heavy => const Color(0xFF1F4E9A),
        RainIntensity.moderate => const Color(0xFF3B7DD8),
        _ => const Color(0xFF5B8FC9),
      };

  static String _rainName(BuildContext context, RainIntensity? r) => switch (r) {
        RainIntensity.none => context.tr('No rain', 'Tiada hujan'),
        RainIntensity.light => context.tr('Light', 'Renyai'),
        RainIntensity.moderate => context.tr('Moderate', 'Sederhana'),
        RainIntensity.heavy => context.tr('Heavy', 'Lebat'),
        RainIntensity.veryHeavy => context.tr('Very heavy', 'Sangat lebat'),
        null => context.tr('No data', 'Tiada data'),
      };
}

class _Legend extends StatelessWidget {
  const _Legend({required this.title, required this.rows});
  final String title;
  final List<(String, Color, bool)> rows; // label, colour, round dot

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.2,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.95), borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: Color(0xFF111418))),
              for (final r in rows)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(width: 12, height: 12, decoration: BoxDecoration(color: r.$2, borderRadius: BorderRadius.circular(r.$3 ? 6 : 3))),
                    const SizedBox(width: 8),
                    Text(r.$1, style: const TextStyle(fontSize: 14, color: Color(0xFF111418))),
                  ]),
                ),
            ]),
          ),
        ),
      );
}

class _SelectedCentre extends StatelessWidget {
  const _SelectedCentre({required this.item});
  final NearbyEvacuation item;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = item.point;
    final st = _CentresScreenState.centreStatus(context, p);
    final space = !p.isOpen
        ? context.tr('Opens only if the district calls for it', 'Dibuka hanya jika diarahkan oleh daerah')
        : (p.isFull
            ? context.tr('No space left. Choose another centre.', 'Tiada ruang. Pilih pusat lain.')
            : context.tr('${p.occupancy} of ${p.capacity} spaces taken', '${p.occupancy} daripada ${p.capacity} tempat diisi', '已占用 ${p.occupancy} / ${p.capacity} 个位置'));
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.name, style: context.text.titleLarge),
              Text(context.tr('${item.distanceKm.toStringAsFixed(1)} km away (straight line)', '${item.distanceKm.toStringAsFixed(1)} km (garis lurus)', '距离 ${item.distanceKm.toStringAsFixed(1)} 公里（直线）'),
                  style: context.text.bodyLarge!.copyWith(color: context.colors.textMuted, fontFeatures: AppText.tabular)),
            ]),
          ),
          const SizedBox(width: 8),
          TagBadge(text: st.$1, color: st.$2, tint: st.$3, icon: st.$4),
        ]),
        const SizedBox(height: 4),
        Text(space, style: context.text.bodyLarge!.copyWith(color: context.colors.textMuted, fontFeatures: AppText.tabular)),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const ValueKey('centre-route'),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RouteScreen(centre: p))),
          icon: const Icon(Icons.directions),
          label: Text(context.tr('Show route', 'Tunjuk laluan', '显示路线')),
        ),
        const SizedBox(height: kGap),
        OutlinedButton.icon(
          key: const ValueKey('centre-directions'),
          onPressed: () async {
            final messenger = ScaffoldMessenger.of(context);
            final msg = context.tr('Could not open maps.', 'Peta tidak dapat dibuka.');
            final ok = await app.deps.opener.open(app.directionsTo(p));
            if (!ok) messenger.showSnackBar(SnackBar(content: Text(msg)));
          },
          icon: const Icon(Icons.open_in_new),
          label: Text(context.tr('Open in Google Maps', 'Buka dalam Google Maps', '在Google地图中打开')),
        ),
      ]),
    );
  }
}

class _CentreRow extends StatelessWidget {
  const _CentreRow({required this.item, required this.selected, required this.last, required this.onTap});
  final NearbyEvacuation item;
  final bool selected;
  final bool last;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final st = _CentresScreenState.centreStatus(context, item.point);
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: context.colors.divider))),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(item.point.name, style: context.text.titleMedium),
                Text('${item.distanceKm.toStringAsFixed(1)} km', style: context.text.bodyMedium!.copyWith(fontFeatures: AppText.tabular)),
              ]),
            ),
            TagBadge(text: st.$1, color: st.$2, tint: st.$3, icon: st.$4),
            if (selected) ...[const SizedBox(width: 4), Icon(Icons.radio_button_checked, color: context.colors.primary)],
          ]),
        ),
      ),
    );
  }
}

class _RainList extends StatelessWidget {
  const _RainList({required this.statuses});
  final List<StationStatus> statuses;

  @override
  Widget build(BuildContext context) {
    final list = [for (final s in statuses) if (s.rainfall != null) s]
      ..sort((a, b) => b.rainfall!.compareTo(a.rainfall!));
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        CardLabel(context.tr('Rain gauges · heaviest first', 'Tolok hujan · paling lebat dahulu')),
        for (var i = 0; i < list.length; i++)
          _StationRow(
            status: list[i],
            title: list[i].station.name,
            subtitle: '${list[i].rainfall!.toStringAsFixed(1)} mm/h · ${_CentresScreenState._rainName(context, list[i].rainIntensity)}'
                '${list[i].isStale ? ' · ${context.tr('old data', 'data lama')}' : ''}',
            trailing: Icon(Icons.water_drop, color: _CentresScreenState._rainColor(list[i].rainIntensity)),
            last: i == list.length - 1,
          ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(context.tr('Latest gauge readings. MET Malaysia rain forecasts are not connected yet.',
              'Bacaan tolok terkini. Ramalan hujan MET Malaysia belum disambungkan.'), style: context.text.bodyMedium),
        ),
      ]),
    );
  }
}

class _RiverList extends StatelessWidget {
  const _RiverList({required this.statuses});
  final List<StationStatus> statuses;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final list = [for (final s in statuses) if (s.station.thresholds != null) s]..sort(compareByRisk);
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        CardLabel(context.tr('River level now → in 3 hours (AI forecast)', 'Paras sungai kini → dalam 3 jam (ramalan AI)')),
        for (var i = 0; i < list.length; i++)
          Builder(builder: (context) {
            final s = list[i];
            final f = app.forecastFor(s.station.id);
            final now = s.riverLevel == null ? '—' : metres(s.riverLevel!);
            final later = f == null ? context.tr('no forecast', 'tiada ramalan') : metres(f.predictedLevelM);
            final arrow = f == null ? '' : switch (f.trend) { Trend.rising => ' ↑', Trend.falling => ' ↓', Trend.steady => ' →' };
            return _StationRow(
              status: s,
              title: s.station.name,
              subtitle: '$now → $later$arrow',
              trailing: RiskBadge(f?.predictedRisk ?? (s.isActionable ? s.level : null)),
              last: i == list.length - 1,
            );
          }),
      ]),
    );
  }
}

class _StationRow extends StatelessWidget {
  const _StationRow({required this.status, required this.title, required this.subtitle, required this.trailing, required this.last});
  final StationStatus status;
  final String title;
  final String subtitle;
  final Widget trailing;
  final bool last;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        child: InkWell(
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => StationDetailScreen(stationId: status.station.id))),
          child: Container(
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: context.colors.divider))),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: context.text.titleMedium),
                  Text(subtitle, style: context.text.bodyMedium!.copyWith(fontFeatures: AppText.tabular)),
                ]),
              ),
              trailing,
              const Chevron(),
            ]),
          ),
        ),
      );
}

/// Shown when the phone's location is not available, so people know the
/// distances are from a sample point.
class LocationNotice extends StatelessWidget {
  const LocationNotice({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final why = switch (app.locationIssue) {
      LocationIssue.serviceOff => context.tr('Location is turned off on this phone.', 'Lokasi dimatikan pada telefon ini.', '此手机的定位已关闭。'),
      LocationIssue.denied => context.tr('Location permission was not given.', 'Kebenaran lokasi tidak diberi.', '未授予定位权限。'),
      LocationIssue.deniedForever => context.tr('Location is blocked for this app.', 'Lokasi disekat untuk aplikasi ini.', '此应用的定位已被阻止。'),
      _ => context.tr('Your location could not be found.', 'Lokasi anda tidak dapat dikesan.', '无法取得您的位置。'),
    };
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.location_off, color: context.colors.textMuted),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '$why ${context.tr('Distances use a sample point in Segamat.', 'Jarak menggunakan titik contoh di Segamat.', '距离以昔加末的示例地点计算。')}',
              style: context.text.bodyLarge,
            ),
          ),
        ]),
        const SizedBox(height: 12),
        FilledButton.tonal(
          key: const ValueKey('location-retry'),
          // Blocked: open the app's permission page. Switch off: open the
          // phone's Location page. Either way the app checks again on return.
          onPressed: switch (app.locationIssue) {
            LocationIssue.deniedForever || LocationIssue.serviceOff => app.deps.location.openSettings,
            _ => app.retryLocation,
          },
          child: Text(switch (app.locationIssue) {
            LocationIssue.deniedForever => context.tr('Open settings', 'Buka tetapan', '打开设置'),
            LocationIssue.serviceOff => context.tr('Turn on location', 'Hidupkan lokasi', '开启定位'),
            _ => context.tr('Use my location', 'Guna lokasi saya', '使用我的位置'),
          }),
        ),
      ]),
    );
  }
}
