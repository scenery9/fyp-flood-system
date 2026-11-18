import 'package:material_ui/material_ui.dart';

import '../app/app_controller.dart';
import '../app/platform.dart';

/// Speaker button: reads [text] aloud; tap again to stop. Hidden when Read
/// aloud is turned off in More.
class ReadAloudButton extends StatelessWidget {
  const ReadAloudButton({super.key, required this.id, required this.text});
  final String id;
  final String Function() text;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    if (!app.readAloud) return const SizedBox.shrink();
    final speaking = app.speakingId == id;
    return FilledButton.tonalIcon(
      key: ValueKey('read-$id'),
      style: FilledButton.styleFrom(minimumSize: const Size(48, 48), shape: const StadiumBorder(), padding: const EdgeInsets.symmetric(horizontal: 16)),
      onPressed: () async {
        final messenger = ScaffoldMessenger.of(context);
        final noVoice = context.tr(
            'No voice for this language on your phone. Add one in Settings › Text-to-speech.',
            'Tiada suara untuk bahasa ini dalam telefon anda. Tambah di Tetapan › Teks-ke-pertuturan.',
            '您的手机没有这种语言的语音。请在“设置 › 文字转语音”中添加。');
        final failed = context.tr('Could not read aloud.', 'Tidak dapat membaca dengan kuat.', '无法朗读。');
        final r = await app.speak(id, text());
        if (r == SpeakResult.noVoice) messenger.showSnackBar(SnackBar(content: Text(noVoice)));
        if (r == SpeakResult.failed) messenger.showSnackBar(SnackBar(content: Text(failed)));
      },
      icon: Icon(speaking ? Icons.stop : Icons.volume_up),
      label: Text(speaking ? context.tr('Stop', 'Henti', '停止') : context.tr('Read aloud', 'Baca kuat', '朗读')),
    );
  }
}
