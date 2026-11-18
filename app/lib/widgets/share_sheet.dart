import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:material_ui/material_ui.dart';

import '../app/app_controller.dart';
import '../app/platform.dart';
import '../theme/app_theme.dart';

/// "Share": WhatsApp, a text message or copy, as three big buttons. Opens
/// the other app with the text ready, so nothing has to be pasted by hand.
Future<void> showShareSheet(BuildContext context, String text) async {
  final app = AppScope.read(context);
  final messenger = ScaffoldMessenger.of(context);
  final noApp = context.tr('Could not open that app. The text is copied instead; paste it.',
      'Aplikasi itu tidak dapat dibuka. Teks telah disalin; tampal sahaja.', '无法打开该应用。文字已复制，请粘贴。');
  final copied = context.tr('Copied. Paste it into WhatsApp or SMS.', 'Disalin. Tampal ke WhatsApp atau SMS.');

  Future<void> open(Uri uri) async {
    if (!await app.deps.opener.open(uri)) {
      await Clipboard.setData(ClipboardData(text: text));
      messenger.showSnackBar(SnackBar(content: Text(noApp)));
    }
  }

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheet) {
      Widget button(String key, IconData icon, String label, Future<void> Function() onTap, {bool main = false}) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: SizedBox(
              height: 56,
              child: main
                  ? FilledButton.icon(
                      key: ValueKey(key),
                      onPressed: () async {
                        Navigator.of(sheet).pop();
                        await onTap();
                      },
                      icon: Icon(icon),
                      label: Text(label))
                  : OutlinedButton.icon(
                      key: ValueKey(key),
                      onPressed: () async {
                        Navigator.of(sheet).pop();
                        await onTap();
                      },
                      icon: Icon(icon),
                      label: Text(label)),
            ),
          );
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(context.tr('Share with family', 'Kongsi dengan keluarga', '分享给家人'), style: sheet.text.titleLarge),
            const SizedBox(height: 16),
            button('share-whatsapp', Icons.chat, 'WhatsApp', () => open(whatsAppUri(text)), main: true),
            button('share-sms', Icons.sms_outlined, context.tr('Text message', 'Mesej teks', '短信'), () => open(smsShareUri(text))),
            button('share-copy', Icons.copy, context.tr('Copy', 'Salin', '复制'), () async {
              await Clipboard.setData(ClipboardData(text: text));
              messenger.showSnackBar(SnackBar(content: Text(copied)));
            }),
          ]),
        ),
      );
    },
  );
}
