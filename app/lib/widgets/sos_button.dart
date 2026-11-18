import 'package:material_ui/material_ui.dart';

import '../app/app_controller.dart';
import '../app/platform.dart';
import '../screens/more/info_screens.dart';
import '../theme/app_theme.dart';

/// SOS: hold for 2 seconds to call 999. A plain tap opens a sheet with a
/// "Call 999 now" button, for people who cannot hold a press.
class SosButton extends StatefulWidget {
  const SosButton({super.key, this.holdTime = const Duration(seconds: 2)});
  final Duration holdTime;

  @override
  State<SosButton> createState() => _SosButtonState();
}

class _SosButtonState extends State<SosButton> with SingleTickerProviderStateMixin {
  late final AnimationController _hold = AnimationController(vsync: this, duration: widget.holdTime)
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        _hold.reset();
        callEmergency(context);
      }
    });

  @override
  void dispose() {
    _hold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = context.tr('SOS · Hold to call 999', 'SOS · Tekan lama untuk hubungi 999');
    return Semantics(
      button: true,
      label: context.tr('SOS, call 999. Double tap for options.', 'SOS, hubungi 999. Ketik dua kali untuk pilihan.'),
      excludeSemantics: true,
      child: GestureDetector(
        key: const ValueKey('sos'),
        onTap: () => showSosSheet(context),
        onLongPressStart: (_) => _hold.forward(from: 0),
        onLongPressEnd: (_) {
          if (_hold.status != AnimationStatus.completed) _hold.reset();
        },
        onLongPressCancel: () => _hold.reset(),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(kButtonRadius),
          child: SizedBox(
            height: 56,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: AppColors.sos),
                AnimatedBuilder(
                  animation: _hold,
                  builder: (context, _) => FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: _hold.value,
                    child: const ColoredBox(color: Color(0xFF7F1A14)),
                  ),
                ),
                Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.sos, color: Colors.white),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white, fontSize: 17, height: 1, fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the phone dialer with 999, then offers to text the location.
Future<void> callEmergency(BuildContext context) async {
  final app = AppScope.read(context);
  final ok = await app.deps.opener.open(phoneUri('999'));
  if (!context.mounted) return;
  if (!ok) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(context.tr('Could not open the phone app. Dial 999 yourself.',
            'Aplikasi telefon tidak dapat dibuka. Dail 999 sendiri.'))));
  }
  await _showAfterCall(context);
}

Future<void> showSosSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(sheet.tr('Emergency', 'Kecemasan'), style: sheet.text.headlineSmall),
              const SizedBox(height: 8),
              Text(
                  sheet.tr('Call 999 if you are trapped, hurt or in danger.',
                      'Hubungi 999 jika anda terperangkap, cedera atau dalam bahaya.'),
                  style: sheet.text.bodyLarge),
              const SizedBox(height: 24),
              FilledButton.icon(
                key: const ValueKey('sos-call-now'),
                style: FilledButton.styleFrom(backgroundColor: AppColors.sos, foregroundColor: Colors.white),
                onPressed: () {
                  Navigator.of(sheet).pop();
                  callEmergency(context);
                },
                icon: const Icon(Icons.call),
                label: Text(sheet.tr('Call 999 now', 'Hubungi 999 sekarang')),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(sheet).pop(),
                child: Text(sheet.tr('Cancel', 'Batal')),
              ),
            ],
          ),
        ),
      ),
    );

Future<void> _showAfterCall(BuildContext context) {
  final app = AppScope.read(context);
  final contact = app.emergencyContact;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(sheet.tr('Tell your family', 'Beritahu keluarga'), style: sheet.text.headlineSmall),
            const SizedBox(height: 8),
            Text(
              contact == null
                  ? sheet.tr('Add an emergency contact so you can text them your location in one tap.',
                      'Tambah kenalan kecemasan supaya anda boleh hantar lokasi dengan satu ketikan.')
                  : sheet.tr('Send your location to $contact.', 'Hantar lokasi anda kepada $contact.', '将您的位置发送给 $contact。'),
              style: sheet.text.bodyLarge,
            ),
            const SizedBox(height: 24),
            if (contact != null)
              FilledButton.icon(
                key: const ValueKey('sos-sms'),
                onPressed: () async {
                  final p = app.userLocation;
                  final text = sheet.tr(
                      'I need help. My location: https://maps.google.com/?q=${p.lat},${p.lon}',
                      'Saya perlukan bantuan. Lokasi saya: https://maps.google.com/?q=${p.lat},${p.lon}', '我需要帮助。我的位置：https://maps.google.com/?q=${p.lat},${p.lon}');
                  Navigator.of(sheet).pop();
                  await app.deps.opener.open(smsUri(contact, text));
                },
                icon: const Icon(Icons.sms),
                label: Text(sheet.tr('Text my location', 'Hantar lokasi saya')),
              )
            else
              FilledButton.tonal(
                onPressed: () {
                  Navigator.of(sheet).pop();
                  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const EmergencyNumbersScreen()));
                },
                child: Text(sheet.tr('Add emergency contact', 'Tambah kenalan kecemasan')),
              ),
            const SizedBox(height: 8),
            TextButton(onPressed: () => Navigator.of(sheet).pop(), child: Text(sheet.tr('Close', 'Tutup'))),
          ],
        ),
      ),
    ),
  );
}
