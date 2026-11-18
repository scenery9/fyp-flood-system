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

/// Pick a station to save: the nearest stations first, a State then District
/// dropdown, and search as a last resort (no typing needed).
class AddAreaScreen extends StatefulWidget {
  const AddAreaScreen({super.key});

  @override
  State<AddAreaScreen> createState() => _AddAreaScreenState();
}

class _AddAreaScreenState extends State<AddAreaScreen> {
  String _query = '';
  String? _state; // null = all states
  String? _district; // null = all districts in [_state]
  bool _startChosen = false;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final saved = {for (final a in app.areas) a.station.id};
    final q = _query.trim().toLowerCase();
    final states = {for (final s in app.statuses) s.station.state}.toList()..sort();
    if (!_startChosen) {
      // Start on the state of the nearest station when the phone's location is known.
      _startChosen = true;
      _state = app.nearest?.station.state;
    }
    final state = states.contains(_state) ? _state : null;
    final districts = {
      for (final s in app.statuses)
        if (state == null || s.station.state == state) s.station.district
    }.toList()
      ..sort();
    final district = districts.contains(_district) ? _district : null;
    final list = [
      for (final s in app.statuses)
        if (!saved.contains(s.station.id) &&
            (state == null || s.station.state == state) &&
            (district == null || s.station.district == district) &&
            (q.isEmpty ||
                s.station.name.toLowerCase().contains(q) ||
                s.station.district.toLowerCase().contains(q) ||
                s.station.state.toLowerCase().contains(q)))
          s,
    ]
      // Nearest first when the phone's location is known.
      ..sort((a, b) {
        final da = app.locationIssue == null ? a.distanceKm : null, db = app.locationIssue == null ? b.distanceKm : null;
        if (da != null && db != null) return da.compareTo(db);
        if (da != null) return -1;
        if (db != null) return 1;
        return a.station.name.compareTo(b.station.name);
      });
    return SubPage(
      title: context.tr('Add an area', 'Tambah kawasan'),
      children: [
        NoteText(app.locationIssue == null
            ? context.tr('Nearest stations first. Tap Add on the one closest to your home.',
                'Stesen paling dekat dahulu. Tekan Tambah pada stesen paling dekat dengan rumah anda.', '最近的测站在最前面。点击离您家最近测站的“添加”。')
            : context.tr('Choose your state and district, then tap Add.', 'Pilih negeri dan daerah anda, kemudian tekan Tambah.', '选择您的州和县区，然后点击“添加”。')),
        Padding(
          padding: const EdgeInsets.fromLTRB(kMargin, 12, kMargin, 0),
          child: _Dropdown(
            key: const ValueKey('state-menu'),
            label: context.tr('State', 'Negeri', '州'),
            value: state,
            values: states,
            allLabel: context.tr('All states', 'Semua negeri', '所有州'),
            onChanged: (v) => setState(() {
              _state = v;
              _district = null;
            }),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(kMargin, 12, kMargin, 0),
          child: _Dropdown(
            key: const ValueKey('district-menu'),
            label: context.tr('District', 'Daerah', '县区'),
            value: district,
            values: districts,
            allLabel: context.tr('All districts', 'Semua daerah', '所有县区'),
            onChanged: (v) => setState(() => _district = v),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(kMargin, 12, kMargin, 12),
          child: TextField(
            key: const ValueKey('area-search'),
            onChanged: (v) => setState(() => _query = v),
            style: context.text.bodyLarge,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: context.tr('Or search by name', 'Atau cari mengikut nama', '或按名称搜索'),
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
                          Text(
                              [
                                '${list[i].station.district}, ${list[i].station.state}',
                                if (app.locationIssue == null && list[i].distanceKm != null) '${list[i].distanceKm!.toStringAsFixed(1)} km',
                              ].join(' · '),
                              style: context.text.bodyMedium!.copyWith(fontFeatures: AppText.tabular)),
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

/// A labelled dropdown with an "All" choice first (value null).
class _Dropdown extends StatelessWidget {
  const _Dropdown({super.key, required this.label, required this.value, required this.values, required this.allLabel, required this.onChanged});
  final String label;
  final String? value;
  final List<String> values;
  final String allLabel;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          value: value,
          isExpanded: true,
          style: context.text.bodyLarge,
          items: [
            DropdownMenuItem<String?>(value: null, child: Text(allLabel)),
            for (final v in values) DropdownMenuItem<String?>(key: ValueKey('menu-$v'), value: v, child: Text(v)),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}
