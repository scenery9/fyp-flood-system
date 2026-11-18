import 'package:material_ui/material_ui.dart';

import '../app/app_controller.dart';
import '../theme/app_theme.dart';

/// "Use your location?": FloodReady explains why before the phone's own
/// pop-up appears. Shown when the app opens until the user allows location
/// or ticks "Don't ask me again" (answers kept by LocationConsentService).
class LocationQuestionScreen extends StatefulWidget {
  const LocationQuestionScreen({super.key});

  @override
  State<LocationQuestionScreen> createState() => _LocationQuestionScreenState();
}

class _LocationQuestionScreenState extends State<LocationQuestionScreen> {
  bool _dontAsk = false;
  bool _busy = false;

  Future<void> _answer(bool allow) async {
    setState(() => _busy = true);
    await AppScope.read(context).answerLocationQuestion(allow: allow, dontAskAgain: _dontAsk);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget reason(IconData icon, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, color: c.primary, size: 28),
            const SizedBox(width: 14),
            Expanded(child: Text(text, style: context.text.bodyLarge)),
          ]),
        );
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
          children: [
            Icon(Icons.location_on, size: 56, color: c.primary),
            const SizedBox(height: 16),
            Semantics(
              header: true,
              child: Text(context.tr('Use your location?', 'Guna lokasi anda?', '使用您的位置？'), style: context.text.headlineSmall),
            ),
            const SizedBox(height: 16),
            reason(Icons.water, context.tr('See the river station nearest you, with no setup.', 'Lihat stesen sungai paling dekat dengan anda, tanpa tetapan.',
                '无需设置，即可查看离您最近的河流测站。')),
            reason(Icons.notifications_active_outlined, context.tr('Get alerts for stations near you.', 'Terima amaran untuk stesen berdekatan anda.',
                '接收您附近测站的警报。')),
            reason(Icons.directions, context.tr('Find the closest open relief centre and the road there.', 'Cari pusat pemindahan terbuka paling dekat dan jalan ke sana.',
                '找到最近的开放疏散中心及路线。')),
            const SizedBox(height: 4),
            Text(
                context.tr('Your location is used on this phone. It is only sent when you ask for a route or send a report or headcount.',
                    'Lokasi anda digunakan dalam telefon ini. Ia hanya dihantar apabila anda meminta laluan atau menghantar laporan atau kiraan.',
                    '您的位置只在此手机上使用，仅在您查询路线或发送报告、人数登记时才会发送。'),
                style: context.text.bodyMedium),
            const SizedBox(height: 24),
            FilledButton(
              key: const ValueKey('loc-allow'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
              onPressed: _busy ? null : () => _answer(true),
              child: Text(context.tr('Allow location', 'Benarkan lokasi', '允许定位')),
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const ValueKey('loc-not-now'),
              style: TextButton.styleFrom(minimumSize: const Size.fromHeight(52)),
              onPressed: _busy ? null : () => _answer(false),
              child: Text(context.tr('Not now', 'Bukan sekarang', '暂不')),
            ),
            CheckboxListTile(
              key: const ValueKey('loc-dont-ask'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(context.tr("Don't ask me again", 'Jangan tanya lagi', '不再询问')),
              value: _dontAsk,
              onChanged: _busy ? null : (v) => setState(() => _dontAsk = v ?? false),
            ),
            Text(context.tr('You can change this any time in More.', 'Anda boleh ubah ini bila-bila masa dalam Lagi.', '您可以随时在“更多”中更改。'),
                style: context.text.bodyMedium),
          ],
        ),
      ),
    );
  }
}
