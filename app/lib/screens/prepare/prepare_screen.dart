import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';
import '../../widgets/sos_button.dart';
import '../centres/route_screen.dart';
import 'checklist_steps_screen.dart';
import 'household_screen.dart';
import 'household_setup_screen.dart';

/// Prepare tab: household summary (details hidden until unlocked), level
/// picker, the personalised checklist and the way out.
class PrepareScreen extends StatefulWidget {
  const PrepareScreen({super.key});

  @override
  State<PrepareScreen> createState() => _PrepareScreenState();
}

class _PrepareScreenState extends State<PrepareScreen> {
  RiskLevel? _picked; // null = follow the area's current level

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final now = app.checklistLevel;
    final level = _picked ?? now;
    final items = app.checklist(level);
    final doneCount = items.where((i) => app.done.contains(i.id)).length;
    final area = app.currentArea;
    final areaName = area == null ? '' : (area.station.name.contains(' di ') ? area.station.name.split(' di ').last : area.station.name);

    return ListView(
      primary: false,
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        ScreenTitle(
          context.tr('Prepare', 'Bersedia'),
          subtitle: area == null
              ? context.tr('Save an area to match your checklist to it', 'Simpan kawasan untuk padankan senarai semak')
              : context.tr('For $areaName · now at ${context.levelName(now)}', 'Untuk $areaName · kini ${context.levelName(now)}', '$areaName · 目前为${context.levelName(now)}'),
        ),
        const SizedBox(height: kGap),
        const Padding(padding: EdgeInsets.symmetric(horizontal: kMargin), child: HouseholdSummaryCard()),
        const SizedBox(height: kGap),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kMargin),
          child: AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              CardLabel(context.tr('Show checklist for · river is now at ${context.levelName(now)}',
                  'Papar senarai semak untuk · sungai kini ${context.levelName(now)}', '显示清单级别 · 河流目前为${context.levelName(now)}')),
              const SizedBox(height: 12),
              PillSegments<RiskLevel>(
                semanticsLabel: context.tr('Risk level', 'Tahap risiko'),
                values: RiskLevel.values,
                selected: level,
                label: (l) => context.levelName(l),
                colorFor: (l) => RiskStyle.of(l).color,
                onChanged: (l) => setState(() => _picked = l),
              ),
            ]),
          ),
        ),
        const SizedBox(height: kGap),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kMargin),
          child: AppCard(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(context.tr('When river is at ${context.levelName(level)}', 'Apabila sungai pada tahap ${context.levelName(level)}', '当河流处于${context.levelName(level)}时'),
                  style: context.text.titleLarge),
              const SizedBox(height: 4),
              Text(context.tr('$doneCount of ${items.length} done', '$doneCount daripada ${items.length} selesai', '已完成 $doneCount / ${items.length}'),
                  style: context.text.bodyLarge!.copyWith(color: context.colors.textMuted, fontFeatures: AppText.tabular)),
              const SizedBox(height: 12),
              ProgressSegments(done: doneCount, total: items.length),
              const SizedBox(height: 4),
              for (var i = 0; i < items.length; i++)
                ChecklistRow(
                  item: items[i],
                  done: app.done.contains(items[i].id),
                  showReason: app.householdVisible,
                  last: i == items.length - 1,
                  onToggle: (v) => app.setDone(items[i].id, v),
                  onOpen: () => Navigator.of(context).push(MaterialPageRoute<void>(
                      builder: (_) => ChecklistStepsScreen(level: level, startAt: i))),
                ),
            ]),
          ),
        ),
        const SizedBox(height: kGap),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kMargin),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            FilledButton.icon(
              key: const ValueKey('start-steps'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ChecklistStepsScreen(level: level))),
              icon: const Icon(Icons.play_arrow),
              label: Text(context.tr('Go step by step', 'Ikut langkah demi langkah')),
            ),
            if (doneCount > 0) ...[
              const SizedBox(height: 4),
              TextButton(
                key: const ValueKey('reset-level'),
                onPressed: () => _confirmReset(context, level),
                child: Text(context.tr('Clear ticks for ${context.levelName(level)}', 'Kosongkan tanda untuk ${context.levelName(level)}', '清除${context.levelName(level)}的勾选')),
              ),
            ],
          ]),
        ),
        const SizedBox(height: kGap),
        const Padding(padding: EdgeInsets.symmetric(horizontal: kMargin), child: WayOutCard()),
        NoteText(context.tr('This checklist helps you prepare. It does not replace official warnings from JPS and NADMA.',
            'Senarai semak ini membantu anda bersedia. Ia tidak menggantikan amaran rasmi JPS dan NADMA.')),
      ],
    );
  }

  Future<void> _confirmReset(BuildContext context, RiskLevel level) async {
    final app = AppScope.read(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(d.tr('Clear all ticks?', 'Kosongkan semua tanda?')),
        content: Text(d.tr('Items for ${d.levelName(level)} will be unticked.', 'Item untuk ${d.levelName(level)} akan dinyahtanda.', '${d.levelName(level)}的项目将取消勾选。')),
        actions: [
          TextButton(onPressed: () => Navigator.of(d).pop(false), child: Text(d.tr('Cancel', 'Batal'))),
          TextButton(onPressed: () => Navigator.of(d).pop(true), child: Text(d.tr('Clear', 'Kosongkan'))),
        ],
      ),
    );
    if (ok == true) await app.resetLevel(level);
  }
}

/// One checklist line: tick box (tap to tick) and the text (tap to open its page).
class ChecklistRow extends StatelessWidget {
  const ChecklistRow({super.key, required this.item, required this.done, required this.showReason, required this.last, required this.onToggle, required this.onOpen});
  final PrepItem item;
  final bool done;
  final bool showReason;
  final bool last;
  final ValueChanged<bool> onToggle;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: c.divider))),
      child: Row(children: [
        Semantics(
          checked: done,
          label: item.title,
          excludeSemantics: true,
          child: InkWell(
            key: ValueKey('tick-${item.id}'),
            onTap: () => onToggle(!done),
            child: SizedBox(
              width: 48,
              height: 64,
              child: Center(
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: done ? c.primary : Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: done ? null : Border.all(color: const Color(0xFF8A94A0), width: 2),
                  ),
                  child: done ? const Icon(Icons.check, color: Colors.white, size: 20) : null,
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: Semantics(
            button: true,
            hint: context.tr('Open step', 'Buka langkah'),
            child: InkWell(
              onTap: onOpen,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(item.title,
                          style: context.text.bodyLarge!.copyWith(
                            color: done ? c.textMuted : c.text,
                            decoration: done ? TextDecoration.lineThrough : null,
                          )),
                      if (showReason && item.reason != null)
                        Text(item.reason!, style: context.text.bodyMedium!.copyWith(color: c.primary)),
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

/// Household summary. Details show only when the lock allows it this session.
class HouseholdSummaryCard extends StatelessWidget {
  const HouseholdSummaryCard({super.key});

  String _transport(BuildContext context, Transport t) => switch (t) {
        Transport.ownCar => context.tr('Own car', 'Kereta sendiri'),
        Transport.motorcycle => context.tr('Motorcycle', 'Motosikal'),
        Transport.lift => context.tr('Lift from family or neighbour', 'Tumpang keluarga atau jiran'),
        Transport.none => context.tr('No transport', 'Tiada kenderaan'),
      };

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = app.profile;
    final pill = FilledButton.styleFrom(
      minimumSize: const Size(48, 48),
      shape: const StadiumBorder(),
      backgroundColor: const Color(0xFFEAF1F8),
      foregroundColor: context.colors.primary,
      padding: const EdgeInsets.symmetric(horizontal: 18),
    );
    Future<void> openLocked() async {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const HouseholdScreen()));
      await app.refreshHouseholdVisibility();
    }

    if (p == null) {
      return AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          CardLabel(context.tr('Your household', 'Isi rumah anda')),
          const SizedBox(height: 4),
          Text(context.tr('Not set up yet', 'Belum diisi'), style: context.text.titleMedium),
          Text(context.tr('Add your household to get a checklist made for you.', 'Isi maklumat isi rumah untuk senarai semak khas anda.'),
              style: context.text.bodyMedium),
          const SizedBox(height: 12),
          FilledButton.tonal(
            key: const ValueKey('setup-household'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const HouseholdSetupScreen())),
            child: Text(context.tr('Set up household', 'Isi maklumat isi rumah')),
          ),
        ]),
      );
    }
    final needs = [
      if (p.olderAdult) context.tr('Someone 60+', 'Warga emas 60+'),
      if (p.youngChild) context.tr('young child', 'kanak-kanak kecil'),
      if (p.mobilityAid) context.tr('wheelchair or walking aid', 'kerusi roda atau alat bantu jalan'),
      if (p.dailyMedicine) context.tr('daily medicine', 'ubat harian'),
      if (p.pet) context.tr('pet', 'haiwan peliharaan'),
    ];
    return AppCard(
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CardLabel(context.tr('Your household', 'Isi rumah anda')),
            const SizedBox(height: 4),
            Text(context.tr('${p.people} ${p.people == 1 ? 'person' : 'people'}', '${p.people} orang', '${p.people} 人'),
                style: context.text.titleMedium!.copyWith(fontFeatures: AppText.tabular)),
            if (app.householdVisible) ...[
              Text(needs.isEmpty ? context.tr('No special needs', 'Tiada keperluan khas') : needs.join(' · '),
                  style: context.text.bodyLarge!.copyWith(color: context.colors.textMuted)),
              Text(_transport(context, p.transport), style: context.text.bodyLarge!.copyWith(color: context.colors.textMuted)),
            ] else
              Text(context.tr('Details hidden for privacy', 'Butiran disembunyikan untuk privasi'),
                  style: context.text.bodyLarge!.copyWith(color: context.colors.textMuted)),
          ]),
        ),
        const SizedBox(width: 12),
        if (app.householdVisible)
          FilledButton(
            key: const ValueKey('edit-household'),
            style: pill,
            onPressed: openLocked,
            child: Text(context.tr('Edit', 'Ubah')),
          )
        else
          FilledButton.icon(
            key: const ValueKey('show-household'),
            style: pill,
            onPressed: openLocked,
            icon: const Icon(Icons.lock, size: 18),
            label: Text(context.tr('Show', 'Papar')),
          ),
      ]),
    );
  }
}

/// Nearest open centre and what to do with the household's transport.
class WayOutCard extends StatelessWidget {
  const WayOutCard({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final near = app.nearestAvailable;
    final p = app.profile;
    final advice = p == null
        ? context.tr('Add your household to get advice for your transport.', 'Isi maklumat isi rumah untuk nasihat mengikut kenderaan anda.')
        : (p.needsHelpToLeave
            ? context.tr('You have no own transport, so ask your driver early. If no one can take you, call 999.',
                'Anda tiada kenderaan sendiri, jadi minta pemandu anda awal. Jika tiada sesiapa, hubungi 999.')
            : context.tr('Leave early by your own transport. Avoid roads that are already flooded.',
                'Keluar awal dengan kenderaan sendiri. Elak jalan yang sudah dinaiki air.'));
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        CardLabel(context.tr('Your way out', 'Jalan keluar anda')),
        const SizedBox(height: 4),
        if (near == null)
          Text(context.tr('No relief centre with space found nearby.', 'Tiada pusat pemindahan dengan ruang berdekatan.'), style: context.text.titleMedium)
        else ...[
          Text(near.point.name, style: context.text.titleMedium),
          Text(context.tr('${near.distanceKm.toStringAsFixed(1)} km away (straight line)', '${near.distanceKm.toStringAsFixed(1)} km (garis lurus)', '距离 ${near.distanceKm.toStringAsFixed(1)} 公里（直线）'),
              style: context.text.bodyLarge!.copyWith(color: context.colors.textMuted, fontFeatures: AppText.tabular)),
        ],
        const SizedBox(height: 8),
        Text(advice, style: context.text.bodyLarge),
        const SizedBox(height: 16),
        if (near != null) ...[
          FilledButton.icon(
            key: const ValueKey('wayout-directions'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => RouteScreen(centre: near.point))),
            icon: const Icon(Icons.directions),
            label: Text(context.tr('Show route', 'Tunjuk laluan', '显示路线')),
          ),
          const SizedBox(height: kGap),
        ],
        const SosButton(),
      ]),
    );
  }
}
