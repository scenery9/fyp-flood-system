import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';
import '../home/station_detail_screen.dart';

/// Saved areas (up to 5): tap one to show it on Home, remove it, or add a station.
class SavedAreasScreen extends StatelessWidget {
  const SavedAreasScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final areas = app.areas;
    return SubPage(
      title: context.tr('Saved areas', 'Kawasan disimpan'),
      children: [
        NoteText(context.tr('Tap an area to show it on Home. You can save up to ${FollowedAreasService.maxAreas}.',
            'Ketik kawasan untuk dipaparkan di Utama. Anda boleh simpan sehingga ${FollowedAreasService.maxAreas}.', '点按地区即可在首页显示。最多可保存 ${FollowedAreasService.maxAreas} 个。')),
        const SizedBox(height: 12),
        if (areas.isEmpty)
          NoteText(context.tr('No saved areas yet.', 'Tiada kawasan disimpan.'))
        else
          GroupCard(children: [
            for (var i = 0; i < areas.length; i++)
              _AreaRow(
                status: areas[i],
                selected: i == app.areaIndex,
                last: i == areas.length - 1,
                onTap: () {
                  app.selectArea(i);
                  app.selectTab(AppTab.home);
                  Navigator.of(context).popUntil((r) => r.isFirst);
                },
                onRemove: () => app.unfollow(areas[i].station.id),
              ),
          ]),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kMargin),
          child: FilledButton.icon(
            key: const ValueKey('add-area'),
            onPressed: areas.length >= FollowedAreasService.maxAreas
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AddAreaScreen())),
            icon: const Icon(Icons.add),
            label: Text(context.tr('Add an area', 'Tambah kawasan')),
          ),
        ),
      ],
    );
  }
}

class _AreaRow extends StatelessWidget {
  const _AreaRow({required this.status, required this.selected, required this.last, required this.onTap, required this.onRemove});
  final StationStatus status;
  final bool selected;
  final bool last;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: c.divider))),
      child: Row(children: [
        Expanded(
          child: Semantics(
            button: true,
            selected: selected,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(children: [
                  if (selected) Padding(padding: const EdgeInsets.only(right: 8), child: Icon(Icons.check, color: c.primary)),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(status.station.name, style: context.text.titleMedium),
                      Text('${status.station.district}, ${status.station.state}', style: context.text.bodyMedium),
                    ]),
                  ),
                  RiskBadge(status.isActionable ? status.level : null),
                ]),
              ),
            ),
          ),
        ),
        IconButton(
          key: ValueKey('remove-${status.station.id}'),
          tooltip: context.tr('Remove ${status.station.name}', 'Buang ${status.station.name}', '移除 ${status.station.name}'),
          onPressed: onRemove,
          icon: const Icon(Icons.remove_circle_outline),
          color: const Color(0xFFA8221A),
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        ),
      ]),
    );
  }
}

/// Pick a station to save, with search by name, district or state.
class AddAreaScreen extends StatefulWidget {
  const AddAreaScreen({super.key});

  @override
  State<AddAreaScreen> createState() => _AddAreaScreenState();
}

class _AddAreaScreenState extends State<AddAreaScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final saved = {for (final a in app.areas) a.station.id};
    final q = _query.trim().toLowerCase();
    final list = [
      for (final s in app.statuses)
        if (!saved.contains(s.station.id) &&
            (q.isEmpty ||
                s.station.name.toLowerCase().contains(q) ||
                s.station.district.toLowerCase().contains(q) ||
                s.station.state.toLowerCase().contains(q)))
          s,
    ];
    return SubPage(
      title: context.tr('Add an area', 'Tambah kawasan'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(kMargin, 8, kMargin, 12),
          child: TextField(
            key: const ValueKey('area-search'),
            onChanged: (v) => setState(() => _query = v),
            style: context.text.bodyLarge,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: context.tr('Search by place, district or state', 'Cari mengikut tempat, daerah atau negeri'),
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
            ),
          ),
        ),
        if (list.isEmpty)
          NoteText(context.tr('No stations match.', 'Tiada stesen sepadan.'))
        else
          GroupCard(children: [
            for (var i = 0; i < list.length; i++)
              Container(
                constraints: const BoxConstraints(minHeight: 64),
                decoration: BoxDecoration(
                    border: i == list.length - 1 ? null : Border(bottom: BorderSide(color: context.colors.divider))),
                child: Row(children: [
                  Expanded(
                    child: InkWell(
                      onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(builder: (_) => StationDetailScreen(stationId: list[i].station.id))),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(list[i].station.name, style: context.text.titleMedium),
                          Text('${list[i].station.district}, ${list[i].station.state}', style: context.text.bodyMedium),
                        ]),
                      ),
                    ),
                  ),
                  TextButton(
                    key: ValueKey('add-${list[i].station.id}'),
                    onPressed: () async {
                      final nav = Navigator.of(context);
                      final messenger = ScaffoldMessenger.of(context);
                      final limit = context.tr('You can save up to ${FollowedAreasService.maxAreas} areas. Remove one first.',
                          'Anda boleh simpan sehingga ${FollowedAreasService.maxAreas} kawasan. Buang satu dahulu.',
                          '最多只能保存 ${FollowedAreasService.maxAreas} 个地区，请先移除一个。');
                      final error = await app.follow(list[i].station.id);
                      if (error != null) {
                        messenger.showSnackBar(SnackBar(content: Text(limit)));
                      } else {
                        nav.pop();
                      }
                    },
                    child: Text(context.tr('Add', 'Tambah')),
                  ),
                ]),
              ),
          ]),
      ],
    );
  }
}
