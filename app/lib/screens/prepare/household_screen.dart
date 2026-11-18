import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../security/household_lock_gate.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';
import 'household_setup_screen.dart';

/// "My household": the saved details, behind the fingerprint / PIN lock.
class HouseholdScreen extends StatelessWidget {
  const HouseholdScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('My household', 'Isi rumah saya'))),
      body: SafeArea(
        top: false,
        child: HouseholdLockGate(
          lock: app.deps.lock,
          phone: app.deps.phone,
          child: const HouseholdDetails(),
        ),
      ),
    );
  }
}

class HouseholdDetails extends StatelessWidget {
  const HouseholdDetails({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final p = app.profile;
    String yes(bool v) => v ? context.tr('Yes', 'Ya') : context.tr('No', 'Tidak');
    final transport = switch (p?.transport) {
      Transport.ownCar => context.tr('Own car', 'Kereta sendiri'),
      Transport.motorcycle => context.tr('Motorcycle', 'Motosikal'),
      Transport.lift => context.tr('Lift from family or neighbour', 'Tumpang keluarga atau jiran'),
      Transport.none => context.tr('No transport', 'Tiada kenderaan'),
      null => '—',
    };
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 32),
      children: [
        if (p == null)
          NoteText(context.tr('You have not added your household yet.', 'Anda belum mengisi maklumat isi rumah.'))
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kMargin),
            child: AppCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(children: [
                _Item(context.tr('People', 'Bilangan orang'), '${p.people}'),
                _Item(context.tr('Babies or toddlers (0-3)', 'Bayi atau kanak-kanak kecil (0-3)', '婴幼儿（0-3岁）'), '${p.babies}'),
                _Item(context.tr('Children (4-12)', 'Kanak-kanak (4-12)', '儿童（4-12岁）'), '${p.children}'),
                _Item(context.tr('Adults', 'Dewasa', '成人'), '${p.adults}'),
                _Item(context.tr('Aged 60 or older', 'Berumur 60 tahun ke atas', '60岁或以上'), '${p.elderly}'),
                _Item(context.tr('Use a wheelchair or walking aid', 'Menggunakan kerusi roda atau alat bantu jalan', '使用轮椅或助行器'), '${p.mobility}'),
                _Item(context.tr('Pets', 'Haiwan peliharaan', '宠物'), '${p.pets}'),
                _Item(context.tr('Daily medicine', 'Ubat harian', '每日服药'), yes(p.dailyMedicine)),
                _Item(context.tr('Oxygen or a machine that needs power', 'Oksigen atau mesin yang perlukan elektrik', '需要供电的氧气机或医疗设备'), yes(p.powerMachine)),
                _Item(context.tr('Transport', 'Kenderaan'), transport, last: true),
              ]),
            ),
          ),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kMargin),
          child: FilledButton(
            key: const ValueKey('household-edit'),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const HouseholdSetupScreen())),
            child: Text(p == null ? context.tr('Set up household', 'Isi maklumat isi rumah') : context.tr('Edit', 'Ubah')),
          ),
        ),
        NoteText(context.tr('Your answers stay on this phone.', 'Jawapan anda disimpan dalam telefon ini sahaja.')),
      ],
    );
  }
}

class _Item extends StatelessWidget {
  const _Item(this.label, this.value, {this.last = false});
  final String label;
  final String value;
  final bool last;
  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minHeight: 56),
        decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: context.colors.divider))),
        child: Row(children: [
          Expanded(child: Text(label, style: context.text.bodyLarge)),
          const SizedBox(width: 12),
          // Long answers wrap instead of running off the screen (large text sizes).
          Flexible(
            child: Text(value,
                textAlign: TextAlign.end,
                style: context.text.bodyLarge!.copyWith(fontWeight: FontWeight.w600, fontFeatures: AppText.tabular)),
          ),
        ]),
      );
}
