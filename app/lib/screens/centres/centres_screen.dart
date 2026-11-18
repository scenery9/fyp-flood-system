import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';
import '../../app/platform.dart';
import '../../widgets/app_map.dart';
import '../../widgets/choices.dart';
import '../home/station_detail_screen.dart';
import 'headcount_screen.dart';
import 'route_screen.dart';

enum MapLayer { centres, rain, river }

/// How the rain and river lists are sorted.
enum ListSort { nearMe, highestRisk }

/// Centres tab: relief centres near you with directions, plus rain and
/// river-forecast layers on the same map.
class CentresScreen extends StatefulWidget {
  const CentresScreen({super.key});

  @override
  State<CentresScreen> createState() => _CentresScreenState();
}

class _CentresScreenState extends State<CentresScreen> {
  /// Rain and river pins and lists: stations within this many km (5, 10 or 30).
  static const radii = [5.0, 10.0, 30.0];
  double _radiusKm = 10;
  ListSort? _sort; // null until chosen: "Near me" when location works
  bool _openOnly = false;
  MapLayer _layer = MapLayer.centres;
  String? _selected;

  /// Road route for the selected centre, fetched in the background.
  String? _routeAskedFor;
  RoutePlan? _road;

  void _loadRoad(AppController app, EvacuationPoint p) {
    if (!p.locationChecked) return; // no route to a position nobody has checked
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
    final centres = [for (final c in app.centres) if (!_openOnly || c.point.isAvailable) c];
    final hasLocation = app.locationIssue == null;
    final sort = _sort ?? (hasLocation ? ListSort.nearMe : ListSort.highestRisk);
    final nearbyKm = hasLocation ? _radiusKm : double.infinity;
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
          if (!c.point.locationChecked) continue; // listed below, but no pin
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
            text: '${s.rainfall!.toStringAsFixed(1)} mm/h',
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
            route: _layer == MapLayer.centres && sel != null && sel.point.locationChecked
                ? (road?.path ?? [app.userLocation, sel.point.location])
                : null,
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
        if (_layer != MapLayer.centres) ...[
          const SizedBox(height: kGap),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kMargin),
            child: PillSegments<ListSort>(
              semanticsLabel: context.tr('Sort the list', 'Susun senarai', '列表排序'),
              values: ListSort.values,
              selected: sort,
              label: (v) => switch (v) {
                ListSort.nearMe => context.tr('Near me', 'Dekat saya', '离我最近'),
                ListSort.highestRisk => context.tr('Highest risk', 'Risiko tertinggi', '风险最高'),
              },
              onChanged: (v) => setState(() => _sort = v),
            ),
          ),
          if (hasLocation) ...[
            const SizedBox(height: kGap),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: kMargin),
              child: Row(children: [
                Text(context.tr('Within', 'Dalam', '范围'), style: context.text.bodyLarge),
                const SizedBox(width: 12),
                Expanded(
                  child: ChoiceBoxes<double>(
                    keyPrefix: 'radius',
                    values: radii,
                    selected: {_radiusKm},
                    label: (v) => '${v.toStringAsFixed(0)} km',
                    onTap: (v) => setState(() => _radiusKm = v),
                  ),
                ),
              ]),
            ),
          ],
        ],
        if (_layer == MapLayer.centres) ...[
          const SizedBox(height: kGap),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kMargin),
            child: ChoiceBoxes<bool>(
              keyPrefix: 'open-only',
              multiple: true,
              values: const [true],
              selected: {if (_openOnly) true},
              label: (_) => context.tr('Open with space only', 'Dibuka dan ada ruang sahaja', '仅显示开放且有空位'),
              onTap: (_) => setState(() {
                _openOnly = !_openOnly;
                _selected = null;
              }),
            ),
          ),
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
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: kMargin),
              child: _RainList(statuses: app.statuses, sort: sort, withinKm: hasLocation ? _radiusKm : null)),
        ],
        if (_layer == MapLayer.river) ...[
          const SizedBox(height: kGap),
          Padding(
              padding: const EdgeInsets.symmetric(horizontal: kMargin),
              child: _RiverList(statuses: app.statuses, sort: sort, withinKm: hasLocation ? _radiusKm : null)),
        ],
        NoteText(app.deps.liveData
            ? context.tr(
                'Relief centres from the FloodReady list; a centre opens only when the district calls for it, and capacities marked as estimates are guesses. Distances are straight lines until the drive time is known. A dotted line on the map means the road route is not loaded; Show route gives the road route and steps.',
                'Pusat pemindahan daripada senarai FloodReady; pusat dibuka hanya apabila diarahkan oleh daerah, dan kapasiti bertanda anggaran ialah tekaan. Jarak ialah garis lurus sehingga masa memandu diketahui. Garis bertitik pada peta bermaksud laluan jalan belum dimuatkan; Tunjuk laluan memberi laluan jalan dan langkah.',
                '疏散中心来自FloodReady名单；中心只在县府宣布时开放，标为估计的容量只是推测。在得知车程前，距离为直线距离。地图上的虚线表示道路路线尚未载入；“显示路线”会给出道路路线和步骤。')
            : context.tr(
                'Sample relief centres. Distances are straight lines until the drive time is known. A dotted line on the map means the road route is not loaded; Show route gives the road route and steps.',
                'Pusat pemindahan contoh. Jarak ialah garis lurus sehingga masa memandu diketahui. Garis bertitik pada peta bermaksud laluan jalan belum dimuatkan; Tunjuk laluan memberi laluan jalan dan langkah.',
                '示例疏散中心。在得知车程前，距离为直线距离。地图上的虚线表示道路路线尚未载入；“显示路线”会给出道路路线和步骤。')),
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
            : p.capacityEstimated
                ? context.tr('${p.occupancy} of about ${p.capacity} spaces taken (estimate)',
                    '${p.occupancy} daripada kira-kira ${p.capacity} tempat diisi (anggaran)', '已占用 ${p.occupancy} / 约 ${p.capacity} 个位置（估计）')
                : context.tr('${p.occupancy} of ${p.capacity} spaces taken', '${p.occupancy} daripada ${p.capacity} tempat diisi', '已占用 ${p.occupancy} / ${p.capacity} 个位置'));
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.name, style: context.text.titleLarge),
              Text(centreDistance(context, app, item, long: true),
                  style: context.text.bodyLarge!.copyWith(color: context.colors.textMuted, fontFeatures: AppText.tabular)),
            ]),
          ),
          const SizedBox(width: 8),
          TagBadge(text: st.$1, color: st.$2, tint: st.$3, icon: st.$4),
        ]),
        const SizedBox(height: 4),
        Text(space, style: context.text.bodyLarge!.copyWith(color: context.colors.textMuted, fontFeatures: AppText.tabular)),
        if (!p.locationChecked) ...[
          const SizedBox(height: 8),
          Text(
            context.tr(
                'Location not checked yet, so it is not on the map and the app gives no route. Google Maps searches for it by name.',
                'Lokasi belum disemak, jadi ia tiada pada peta dan aplikasi tidak memberi laluan. Google Maps mencarinya mengikut nama.',
                '位置尚未核实，因此不在地图上，应用也不提供路线。Google地图会按名称搜索。'),
            key: const ValueKey('centre-unchecked'),
            style: context.text.bodyLarge,
          ),
        ],
        const SizedBox(height: 16),
        if (p.locationChecked) ...[
          FilledButton.icon(
            key: const ValueKey('centre-route'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RouteScreen(centre: p))),
            icon: const Icon(Icons.directions),
            label: Text(context.tr('Show route', 'Tunjuk laluan', '显示路线')),
          ),
          const SizedBox(height: kGap),
        ],
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
        const SizedBox(height: kGap),
        OutlinedButton.icon(
          key: const ValueKey('centre-headcount'),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => HeadcountScreen(centre: p))),
          icon: const Icon(Icons.groups_outlined),
          label: Text(app.headcount?.centreId == p.id && app.headcount!.isCurrent(DateTime.now())
              ? context.tr('Your headcount: ${app.headcount!.total} people', 'Kiraan anda: ${app.headcount!.total} orang',
                  '您的登记：${app.headcount!.total} 人')
              : context.tr("Tell this centre we're coming", 'Beritahu pusat ini kami akan datang', '告知此中心我们正前往')),
        ),
        if (p.phone != null) ...[
          const SizedBox(height: kGap),
          OutlinedButton.icon(
            key: const ValueKey('centre-call'),
            onPressed: () => app.deps.opener.open(phoneUri(p.phone!)),
            icon: const Icon(Icons.call),
            label: Text(context.tr('Call the centre', 'Hubungi pusat', '致电中心')),
          ),
        ],
      ]),
    );
  }
}

/// "6.2 km · 12 min drive" once the road route is known, else the
/// straight-line distance.
String centreDistance(BuildContext context, AppController app, NearbyEvacuation item, {bool long = false}) {
  if (!item.point.locationChecked) {
    return context.tr('Location not checked yet', 'Lokasi belum disemak', '位置尚未核实');
  }
  final road = app.knownRoute(item.point);
  if (road != null) {
    return context.tr('${road.distanceKm.toStringAsFixed(1)} km · ${road.durationMin} min drive',
        '${road.distanceKm.toStringAsFixed(1)} km · ${road.durationMin} min memandu', '${road.distanceKm.toStringAsFixed(1)} 公里 · 车程 ${road.durationMin} 分钟');
  }
  final km = item.distanceKm.toStringAsFixed(1);
  return long
      ? context.tr('$km km away (straight line)', '$km km (garis lurus)', '距离 $km 公里（直线）')
      : context.tr('$km km (straight line)', '$km km (garis lurus)', '$km 公里（直线）');
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
                Text(centreDistance(context, AppScope.of(context), item), style: context.text.bodyMedium!.copyWith(fontFeatures: AppText.tabular)),
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

/// Sorted and filtered by the chosen distance; stations with no distance
/// (location off) are all shown.
List<StationStatus> _pick(List<StationStatus> all, ListSort sort, double? withinKm, ListMode mode) =>
    const StationListService().apply(all,
        mode: mode, sortBy: sort == ListSort.nearMe ? SortBy.nearest : SortBy.highestRisk, withinKm: withinKm);

/// "3.9 km · 2 min ago" (distance only when known).
String _where(BuildContext context, StationStatus s) =>
    [if (s.distanceKm != null) '${s.distanceKm!.toStringAsFixed(1)} km', formatAge(context, s.age)].join(' · ');

class _RainList extends StatelessWidget {
  const _RainList({required this.statuses, required this.sort, required this.withinKm});
  final List<StationStatus> statuses;
  final ListSort sort;
  final double? withinKm;

  @override
  Widget build(BuildContext context) {
    final list = _pick([for (final s in statuses) if (s.rainfall != null) s], sort, withinKm, ListMode.rainfall);
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        CardLabel(sort == ListSort.nearMe
            ? context.tr('Rain gauges · nearest first', 'Tolok hujan · paling dekat dahulu', '雨量站 · 由近到远')
            : context.tr('Rain gauges · heaviest first', 'Tolok hujan · paling lebat dahulu')),
        if (list.isEmpty) _NoneNear(withinKm: withinKm),
        for (var i = 0; i < list.length; i++)
          _StationRow(
            status: list[i],
            badge: Icon(Icons.water_drop, color: _CentresScreenState._rainColor(list[i].rainIntensity)),
            value: '${list[i].rainfall!.toStringAsFixed(1)} mm/h · ${_CentresScreenState._rainName(context, list[i].rainIntensity)}'
                '${list[i].isStale ? ' · ${context.tr('old data', 'data lama')}' : ''}',
            detail: _where(context, list[i]),
            last: i == list.length - 1,
          ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(context.tr('Latest gauge readings. Tap a gauge for more. MET Malaysia rain forecasts are not connected yet.',
              'Bacaan tolok terkini. Ketik tolok untuk maklumat lanjut. Ramalan hujan MET Malaysia belum disambungkan.'), style: context.text.bodyMedium),
        ),
      ]),
    );
  }
}

class _RiverList extends StatelessWidget {
  const _RiverList({required this.statuses, required this.sort, required this.withinKm});
  final List<StationStatus> statuses;
  final ListSort sort;
  final double? withinKm;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final list = _pick([for (final s in statuses) if (s.station.thresholds != null) s], sort, withinKm, ListMode.riverLevel);
    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        CardLabel(sort == ListSort.nearMe
            ? context.tr('River levels now · nearest first', 'Paras sungai kini · paling dekat dahulu', '当前河流水位 · 由近到远')
            : context.tr('River levels now · highest risk first', 'Paras sungai kini · risiko tertinggi dahulu', '当前河流水位 · 风险最高优先')),
        if (list.isEmpty) _NoneNear(withinKm: withinKm),
        for (var i = 0; i < list.length; i++)
          Builder(builder: (context) {
            final s = list[i];
            final f = app.forecastFor(s.station.id);
            // Arrow from the AI forecast, kept on the same line as the number.
            final arrow = switch (f?.trend) { Trend.rising => '\u00A0↑', Trend.falling => '\u00A0↓', _ => '' };
            return _StationRow(
              status: s,
              badge: RiskBadge(s.isActionable ? s.level : null),
              value: s.riverLevel == null ? '—' : '${metres(s.riverLevel!).replaceAll(' ', '\u00A0')}$arrow',
              detail: _where(context, s),
              towards: s.isActionable ? towardsText(context, s) : null,
              percent: s.isActionable ? (s.level == RiskLevel.danger ? 100 : s.percentToTarget) : null,
              last: i == list.length - 1,
            );
          }),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Text(
              context.tr('↑ rising, ↓ falling in the next 3 hours (AI forecast). Tap a station for the forecast and more.',
                  '↑ naik, ↓ turun dalam 3 jam akan datang (ramalan AI). Ketik stesen untuk ramalan dan maklumat lanjut.',
                  '↑ 上涨，↓ 下降（未来3小时AI预测）。点击测站查看预测和更多信息。'),
              style: context.text.bodyMedium),
        ),
      ]),
    );
  }
}

class _NoneNear extends StatelessWidget {
  const _NoneNear({required this.withinKm});
  final double? withinKm;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
            withinKm == null
                ? context.tr('No stations.', 'Tiada stesen.', '没有测站。')
                : context.tr('No stations within ${withinKm!.toStringAsFixed(0)} km. Choose a bigger distance.',
                    'Tiada stesen dalam ${withinKm!.toStringAsFixed(0)} km. Pilih jarak yang lebih jauh.',
                    '${withinKm!.toStringAsFixed(0)} 公里内没有测站，请选择更大的范围。'),
            style: context.text.bodyLarge),
      );
}

/// One station in the River or Rain list, kept short: name on its own line,
/// then status and reading, then distance and age, and (rivers) how close it
/// is to the next JPS line. Everything else is on the station page.
class _StationRow extends StatelessWidget {
  const _StationRow({
    required this.status,
    required this.badge,
    required this.value,
    required this.last,
    this.detail,
    this.towards,
    this.percent,
  });
  final StationStatus status;
  final Widget badge;

  /// "19.97 m ↑" or "35.0 mm/h · Heavy".
  final String value;
  final bool last;

  /// "3.9 km · 2 min ago".
  final String? detail;

  /// "91% to Warning (8.20 m)", with a bar from [percent] (0-100).
  final String? towards;
  final double? percent;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final saved = app.isSaved(status.station.id);
    final small = context.text.bodyMedium!.copyWith(fontFeatures: AppText.tabular);
    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: context.colors.divider))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Save / unsave without opening the station.
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Semantics(
            button: true,
            selected: saved,
            label: saved
                ? context.tr('Remove ${status.station.name} from my areas', 'Buang ${status.station.name} dari kawasan saya',
                    '从我的地区移除${status.station.name}')
                : context.tr('Save ${status.station.name} to my areas', 'Simpan ${status.station.name} ke kawasan saya',
                    '将${status.station.name}保存到我的地区'),
            excludeSemantics: true,
            child: IconButton(
              key: ValueKey('star-${status.station.id}'),
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: () async {
                final messenger = ScaffoldMessenger.of(context);
                final limit = context.tr('You can save up to ${FollowedAreasService.maxAreas} areas. Remove one first.',
                    'Anda boleh simpan sehingga ${FollowedAreasService.maxAreas} kawasan. Buang satu dahulu.',
                    '最多只能保存 ${FollowedAreasService.maxAreas} 个地区，请先移除一个。');
                if (saved) {
                  await app.unfollow(status.station.id);
                } else if (await app.follow(status.station.id) == FollowError.limit) {
                  messenger.showSnackBar(SnackBar(content: Text(limit)));
                }
              },
              icon: Icon(saved ? Icons.star : Icons.star_border, color: saved ? const Color(0xFFB07A00) : context.colors.textMuted),
            ),
          ),
        ),
        Expanded(
          child: Semantics(
            button: true,
            child: InkWell(
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => StationDetailScreen(stationId: status.station.id))),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      // Full width: wraps only when the name is too long.
                      Text(status.station.name, style: context.text.titleMedium),
                      const SizedBox(height: 6),
                      Row(children: [
                        badge,
                        const SizedBox(width: 10),
                        Flexible(child: Text(value, style: context.text.bodyLarge!.copyWith(fontWeight: FontWeight.w600, fontFeatures: AppText.tabular))),
                      ]),
                      if (detail != null) ...[
                        const SizedBox(height: 4),
                        Text(detail!, style: small.copyWith(color: context.colors.textMuted)),
                      ],
                      if (towards != null) ...[
                        const SizedBox(height: 6),
                        Text(towards!, style: small),
                        if (percent != null) ...[
                          const SizedBox(height: 4),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: (percent! / 100).clamp(0.0, 1.0),
                              minHeight: 6,
                              backgroundColor: context.colors.divider,
                              color: RiskStyle.of(status.level).color,
                            ),
                          ),
                        ],
                      ],
                    ]),
                  ),
                  const Chevron(),
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
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
      LocationIssue.off => context.tr('You chose not to use your location.', 'Anda memilih untuk tidak menggunakan lokasi.', '您选择不使用位置。'),
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
