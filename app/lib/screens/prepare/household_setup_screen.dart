import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';

/// "About your household": number of people, needs and transport.
/// Shown on first launch (with "Skip for now") and from Edit.
class HouseholdSetupScreen extends StatefulWidget {
  const HouseholdSetupScreen({super.key, this.firstLaunch = false});
  final bool firstLaunch;

  @override
  State<HouseholdSetupScreen> createState() => _HouseholdSetupScreenState();
}

class _HouseholdSetupScreenState extends State<HouseholdSetupScreen> {
  HouseholdProfile? _p;
  bool _saving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _p ??= AppScope.read(context).profile ?? const HouseholdProfile();
  }

  Future<void> _save() async {
    final app = AppScope.read(context);
    final nav = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      await app.saveProfile(_p!);
      if (!widget.firstLaunch && nav.canPop()) nav.pop();
    } on ValidationException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _p!;
    final c = context.colors;
    final needs = <(String, bool, HouseholdProfile Function(bool))>[
      (context.tr('Is 60 or older', 'Berumur 60 tahun ke atas'), p.olderAdult, (v) => p.copyWith(olderAdult: v)),
      (context.tr('Is a baby or young child', 'Bayi atau kanak-kanak kecil'), p.youngChild, (v) => p.copyWith(youngChild: v)),
      (context.tr('Uses a wheelchair or walking aid', 'Menggunakan kerusi roda atau alat bantu jalan'), p.mobilityAid, (v) => p.copyWith(mobilityAid: v)),
      (context.tr('Needs daily medicine or a machine (e.g. oxygen)', 'Perlukan ubat harian atau mesin (cth. oksigen)'), p.dailyMedicine, (v) => p.copyWith(dailyMedicine: v)),
      (context.tr('Has a pet', 'Ada haiwan peliharaan'), p.pet, (v) => p.copyWith(pet: v)),
    ];
    final ways = <(Transport, String)>[
      (Transport.ownCar, context.tr('Own car', 'Kereta sendiri')),
      (Transport.motorcycle, context.tr('Motorcycle', 'Motosikal')),
      (Transport.lift, context.tr('Lift from family or neighbour', 'Tumpang keluarga atau jiran')),
      (Transport.none, context.tr('No transport', 'Tiada kenderaan')),
    ];

    final body = ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(kMargin, 16, kMargin, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (widget.firstLaunch)
              Text(context.tr('Set up · takes 1 minute', 'Persediaan · ambil 1 minit'), style: context.text.labelMedium),
            const SizedBox(height: 8),
            Semantics(header: true, child: Text(context.tr('About your household', 'Tentang isi rumah anda'), style: context.text.headlineSmall)),
            const SizedBox(height: 8),
            Text(context.tr('This lets the app give you a checklist that fits your home. You can change it later.',
                'Ini membolehkan aplikasi memberi senarai semak yang sesuai dengan rumah anda. Anda boleh ubah kemudian.'),
                style: context.text.bodyLarge!.copyWith(color: c.textMuted)),
          ]),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kMargin),
          child: AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(context.tr('How many people live with you?', 'Berapa orang tinggal bersama anda?'), style: context.text.titleMedium),
              const SizedBox(height: 12),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                _RoundButton(
                  key: const ValueKey('people-minus'),
                  icon: Icons.remove,
                  label: context.tr('Fewer people', 'Kurang orang'),
                  onTap: p.people <= HouseholdProfile.minPeople ? null : () => setState(() => _p = p.copyWith(people: p.people - 1)),
                ),
                Semantics(
                  liveRegion: true,
                  child: Text('${p.people}', style: context.text.headlineLarge!.copyWith(fontFeatures: AppText.tabular)),
                ),
                _RoundButton(
                  key: const ValueKey('people-plus'),
                  icon: Icons.add,
                  label: context.tr('More people', 'Lebih orang'),
                  onTap: p.people >= HouseholdProfile.maxPeople ? null : () => setState(() => _p = p.copyWith(people: p.people + 1)),
                ),
              ]),
            ]),
          ),
        ),
        const SizedBox(height: kGap),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kMargin),
          child: AppCard(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(context.tr('Does anyone at home…', 'Adakah sesiapa di rumah…'), style: context.text.titleMedium),
              Text(context.tr('Choose all that apply', 'Pilih semua yang berkenaan'), style: context.text.bodyMedium),
              for (var i = 0; i < needs.length; i++)
                _ChoiceRow(
                  label: needs[i].$1,
                  selected: needs[i].$2,
                  radio: false,
                  last: i == needs.length - 1,
                  onTap: () => setState(() => _p = needs[i].$3(!needs[i].$2)),
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
              Text(context.tr('If you need to leave, how would you go?', 'Jika perlu keluar, bagaimana anda akan pergi?'), style: context.text.titleMedium),
              for (var i = 0; i < ways.length; i++)
                _ChoiceRow(
                  label: ways[i].$2,
                  selected: p.transport == ways[i].$1,
                  radio: true,
                  last: i == ways.length - 1,
                  onTap: () => setState(() => _p = p.copyWith(transport: ways[i].$1)),
                ),
            ]),
          ),
        ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kMargin),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            FilledButton(
              key: const ValueKey('household-save'),
              onPressed: _saving ? null : _save,
              child: Text(widget.firstLaunch
                  ? context.tr('Save and continue', 'Simpan dan teruskan')
                  : context.tr('Save', 'Simpan')),
            ),
            if (widget.firstLaunch) ...[
              const SizedBox(height: 4),
              TextButton(
                key: const ValueKey('household-skip'),
                onPressed: () => AppScope.read(context).skipSetup(),
                child: Text(context.tr('Skip for now', 'Langkau dahulu')),
              ),
            ],
          ]),
        ),
        NoteText(context.tr('Your answers stay on this phone.', 'Jawapan anda disimpan dalam telefon ini sahaja.')),
      ],
    );

    return Scaffold(
      appBar: widget.firstLaunch ? null : AppBar(title: Text(context.tr('Household and transport', 'Isi rumah dan kenderaan'))),
      body: SafeArea(child: body),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({super.key, required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        enabled: onTap != null,
        label: label,
        excludeSemantics: true,
        child: IconButton.filledTonal(
          onPressed: onTap,
          iconSize: 28,
          style: IconButton.styleFrom(minimumSize: const Size(56, 56)),
          icon: Icon(icon),
        ),
      );
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({required this.label, required this.selected, required this.radio, required this.last, required this.onTap});
  final String label;
  final bool selected;
  final bool radio;
  final bool last;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final mark = radio
        ? Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: selected ? c.primary : const Color(0xFF8A94A0), width: 2)),
            child: selected
                ? Center(child: Container(width: 14, height: 14, decoration: BoxDecoration(shape: BoxShape.circle, color: c.primary)))
                : null,
          )
        : Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: selected ? c.primary : Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: selected ? null : Border.all(color: const Color(0xFF8A94A0), width: 2),
            ),
            child: selected ? const Icon(Icons.check, color: Colors.white, size: 20) : null,
          );
    return Semantics(
      checked: radio ? null : selected,
      selected: radio ? selected : null,
      inMutuallyExclusiveGroup: radio ? true : null,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: c.divider))),
          child: Row(children: [
            mark,
            const SizedBox(width: 14),
            Expanded(child: Text(label, style: context.text.bodyLarge)),
          ]),
        ),
      ),
    );
  }
}
