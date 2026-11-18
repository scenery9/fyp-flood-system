import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../app/platform.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';

/// "Notify me from": lowest level that should send a notification.
class NotifyLevelScreen extends StatelessWidget {
  const NotifyLevelScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.settings;
    final options = [RiskLevel.alert, RiskLevel.warning, RiskLevel.danger];
    return SubPage(
      title: context.tr('Notify me from', 'Beritahu saya mulai'),
      children: [
        NoteText(context.tr('Choose the lowest level that should alert you for your saved areas.',
            'Pilih tahap paling rendah untuk memberi amaran bagi kawasan anda.')),
        const SizedBox(height: 12),
        GroupCard(children: [
          for (var i = 0; i < options.length; i++)
            Semantics(
              selected: s.notificationThreshold == options[i],
              inMutuallyExclusiveGroup: true,
              button: true,
              child: InkWell(
                key: ValueKey('notify-${options[i].name}'),
                onTap: () => app.updateSettings(s.copyWith(notificationThreshold: options[i])),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 64),
                  decoration: BoxDecoration(
                      border: i == options.length - 1 ? null : Border(bottom: BorderSide(color: context.colors.divider))),
                  child: Row(children: [
                    RiskBadge(options[i]),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        switch (options[i]) {
                          RiskLevel.alert => context.tr('Alert and above (earliest)', 'Waspada dan ke atas (paling awal)'),
                          RiskLevel.warning => context.tr('Warning and Danger only', 'Amaran dan Bahaya sahaja'),
                          _ => context.tr('Danger only', 'Bahaya sahaja'),
                        },
                        style: context.text.bodyLarge,
                      ),
                    ),
                    if (s.notificationThreshold == options[i]) Icon(Icons.check, color: context.colors.primary),
                  ]),
                ),
              ),
            ),
        ]),
        _PushStatusNote(app.pushStatus),
        if (app.pushStatus == PushStatus.needsPermission || app.pushStatus == PushStatus.failed)
          Padding(
            padding: const EdgeInsets.fromLTRB(kMargin, 4, kMargin, 0),
            child: FilledButton(
              key: const ValueKey('push-on'),
              onPressed: () => app.syncPush(ask: true),
              child: Text(app.pushStatus == PushStatus.failed
                  ? context.tr('Try again', 'Cuba lagi', '重试')
                  : context.tr('Turn on phone notifications', 'Hidupkan pemberitahuan telefon', '开启手机通知')),
            ),
          ),
      ],
    );
  }
}

/// What the user should know about phone notifications right now.
class _PushStatusNote extends StatelessWidget {
  const _PushStatusNote(this.status);
  final PushStatus status;

  @override
  Widget build(BuildContext context) => NoteText(switch (status) {
        PushStatus.on => context.tr(
            'Phone notifications are on for your saved areas and river-level alerts, even when the app is closed. Notifications can be late, so also follow JPS and NADMA.',
            'Pemberitahuan telefon dihidupkan untuk kawasan simpanan dan amaran paras sungai anda, walaupun aplikasi ditutup. Pemberitahuan boleh lewat, jadi ikut juga JPS dan NADMA.',
            '已为您保存的地区和河流水位警报开启手机通知，即使应用已关闭也会收到。通知可能会延迟，请同时留意JPS和NADMA的消息。'),
        PushStatus.needsPermission => context.tr(
            'Your choice is saved. Allow notifications so alerts reach you when the app is closed.',
            'Pilihan anda disimpan. Benarkan pemberitahuan supaya amaran sampai walaupun aplikasi ditutup.',
            '您的选择已保存。请允许通知，以便在应用关闭时也能收到警报。'),
        PushStatus.blocked => context.tr(
            'Notifications are blocked for this app. Turn them on in your phone settings to get alerts when the app is closed.',
            'Pemberitahuan disekat untuk aplikasi ini. Hidupkan dalam tetapan telefon untuk menerima amaran apabila aplikasi ditutup.',
            '此应用的通知已被屏蔽。请在手机设置中开启，以便在应用关闭时收到警报。'),
        PushStatus.failed => context.tr(
            'Your choice is saved, but the alert server could not be reached. Check your internet connection.',
            'Pilihan anda disimpan, tetapi pelayan amaran tidak dapat dihubungi. Semak sambungan internet anda.',
            '您的选择已保存，但无法连接警报服务器。请检查网络连接。'),
        PushStatus.notSetUp => context.tr(
            'Your choice is saved. Phone notifications are not set up in this version, so check the app during heavy rain.',
            'Pilihan anda disimpan. Pemberitahuan telefon belum disediakan dalam versi ini, jadi semak aplikasi semasa hujan lebat.',
            '您的选择已保存。此版本尚未设置手机通知，大雨时请查看本应用。'),
      });
}

/// Plain explanation of the AI model.
class HowAiWorksScreen extends StatelessWidget {
  const HowAiWorksScreen({super.key});

  @override
  Widget build(BuildContext context) {
    Widget step(IconData icon, String title, String body) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, color: context.colors.primary, size: 28),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: context.text.titleMedium),
                const SizedBox(height: 4),
                Text(body, style: context.text.bodyLarge),
              ]),
            ),
          ]),
        );
    return SubPage(
      title: context.tr('How the prediction works', 'Cara ramalan berfungsi'),
      children: [
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kMargin),
          child: AppCard(
            child: Column(children: [
              step(Icons.history, context.tr('1. Learns from the past', '1. Belajar daripada masa lalu'),
                  context.tr('The AI studied past rainfall, river levels and floods in the study area.',
                      'AI mempelajari hujan, paras sungai dan banjir yang lalu di kawasan kajian.')),
              step(Icons.compare_arrows, context.tr('2. Compares methods', '2. Membandingkan kaedah'),
                  context.tr('Several prediction methods were tested, including one that combines them. The best one is used.',
                      'Beberapa kaedah ramalan diuji, termasuk satu yang menggabungkannya. Kaedah terbaik digunakan.')),
              step(Icons.timeline, context.tr('3. Predicts the next hours', '3. Meramal beberapa jam akan datang'),
                  context.tr('Each hour it estimates the river level 3 hours ahead, with a likely range.',
                      'Setiap jam ia menganggar paras sungai 3 jam akan datang, dengan julat yang mungkin.')),
              step(Icons.lightbulb_outline, context.tr('4. Explains itself', '4. Menerangkan sebabnya'),
                  context.tr('It shows the readings that pushed the forecast up or down the most, such as recent rain or the river upstream.',
                      'Ia menunjukkan bacaan yang paling menaikkan atau menurunkan ramalan, seperti hujan terkini atau sungai di hulu.')),
            ]),
          ),
        ),
        NoteText(context.tr('A forecast older than 2 hours, or with values that do not make sense, is not shown.',
            'Ramalan yang lebih lama daripada 2 jam, atau dengan nilai yang tidak munasabah, tidak dipaparkan.')),
        NoteText(context.tr('This is a computer prediction, not an official warning.', 'Ini ramalan komputer, bukan amaran rasmi.',
            '这是电脑预测，不是官方警报。')),
      ],
    );
  }
}

/// Where each number in the app comes from.
class DataSourcesScreen extends StatelessWidget {
  const DataSourcesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    Widget row(String title, String body, {bool last = false}) => Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: context.colors.divider))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: context.text.titleMedium),
            const SizedBox(height: 4),
            Text(body, style: context.text.bodyLarge),
          ]),
        );
    return SubPage(
      title: context.tr('Where the data comes from', 'Sumber data'),
      children: [
        const SizedBox(height: 8),
        GroupCard(children: [
          row(context.tr('River levels and rainfall', 'Paras sungai dan hujan'),
              context.tr('JPS (Department of Irrigation and Drainage) station readings.', 'Bacaan stesen JPS (Jabatan Pengairan dan Saliran).')),
          row(context.tr('AI forecast', 'Ramalan AI'),
              context.tr('This project\'s model, trained on logged JPS readings.', 'Model projek ini, dilatih dengan bacaan JPS yang direkod.')),
          row(context.tr('Relief centres', 'Pusat pemindahan'),
              context.tr('To be linked to official NADMA and JKM lists.', 'Akan dipautkan kepada senarai rasmi NADMA dan JKM.')),
          row(context.tr('Directions', 'Arah'),
              context.tr('Google Maps, opened from the app.', 'Google Maps, dibuka dari aplikasi.'), last: true),
        ]),
        NoteText(context.tr('This version uses SAMPLE data for testing. Do not use it for real decisions. Official river levels: publicinfobanjir.water.gov.my',
            'Versi ini menggunakan data CONTOH untuk ujian. Jangan gunakan untuk keputusan sebenar. Paras sungai rasmi: publicinfobanjir.water.gov.my')),
      ],
    );
  }
}

/// Emergency numbers with call buttons, and the family contact used by SOS.
class EmergencyNumbersScreen extends StatefulWidget {
  const EmergencyNumbersScreen({super.key});

  @override
  State<EmergencyNumbersScreen> createState() => _EmergencyNumbersScreenState();
}

class _EmergencyNumbersScreenState extends State<EmergencyNumbersScreen> {
  final _contact = TextEditingController();
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _contact.text = AppScope.read(context).emergencyContact ?? '';
      _loaded = true;
    }
  }

  @override
  void dispose() {
    _contact.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final numbers = [
      ('999', context.tr('Any emergency: police, ambulance, fire, rescue', 'Semua kecemasan: polis, ambulans, bomba, penyelamat')),
      ('994', context.tr('Bomba (Fire and Rescue)', 'Bomba dan Penyelamat')),
      ('991', context.tr('Civil Defence (APM)', 'Angkatan Pertahanan Awam (APM)')),
      ('112', context.tr('From a mobile phone, also works without credit', 'Dari telefon bimbit, berfungsi tanpa kredit')),
    ];
    return SubPage(
      title: context.tr('Emergency numbers', 'Nombor kecemasan'),
      children: [
        const SizedBox(height: 8),
        GroupCard(children: [
          for (var i = 0; i < numbers.length; i++)
            Container(
              constraints: const BoxConstraints(minHeight: 64),
              decoration: BoxDecoration(
                  border: i == numbers.length - 1 ? null : Border(bottom: BorderSide(color: context.colors.divider))),
              child: Row(children: [
                Text(numbers[i].$1, style: context.text.headlineSmall!.copyWith(fontFeatures: AppText.tabular)),
                const SizedBox(width: 16),
                Expanded(child: Text(numbers[i].$2, style: context.text.bodyLarge)),
                IconButton.filledTonal(
                  key: ValueKey('call-${numbers[i].$1}'),
                  tooltip: context.tr('Call ${numbers[i].$1}', 'Hubungi ${numbers[i].$1}', '拨打 ${numbers[i].$1}'),
                  onPressed: () => app.deps.opener.open(phoneUri(numbers[i].$1)),
                  icon: const Icon(Icons.call),
                  style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
                ),
              ]),
            ),
        ]),
        SectionHeader(context.tr('My emergency contact', 'Kenalan kecemasan saya')),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kMargin),
          child: AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(context.tr('After an SOS call, the app can text your location to this number.',
                  'Selepas panggilan SOS, aplikasi boleh menghantar lokasi anda ke nombor ini.'), style: context.text.bodyLarge),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('contact-field'),
                controller: _contact,
                keyboardType: TextInputType.phone,
                style: context.text.bodyLarge,
                decoration: InputDecoration(
                  labelText: context.tr('Phone number', 'Nombor telefon'),
                  hintText: '012-345 6789',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                key: const ValueKey('contact-save'),
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final v = _contact.text.trim();
                  final ok = v.isEmpty || RegExp(r'^\+?[0-9 \-]{7,15}$').hasMatch(v);
                  if (!ok) {
                    messenger.showSnackBar(SnackBar(content: Text(context.tr('Enter a phone number with 7 to 15 digits.', 'Masukkan nombor telefon 7 hingga 15 digit.'))));
                    return;
                  }
                  final msg = v.isEmpty ? context.tr('Contact removed', 'Kenalan dibuang') : context.tr('Contact saved', 'Kenalan disimpan');
                  await app.setEmergencyContact(v);
                  messenger.showSnackBar(SnackBar(content: Text(msg)));
                },
                child: Text(context.tr('Save contact', 'Simpan kenalan')),
              ),
            ]),
          ),
        ),
        NoteText(context.tr('The number stays on this phone.', 'Nombor ini disimpan dalam telefon ini sahaja.')),
      ],
    );
  }
}

/// Version, purpose and limits of the app.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) => SubPage(
        title: context.tr('About this app', 'Tentang aplikasi ini'),
        children: [
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: kMargin),
            child: AppCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(context.tr('Explainable AI-Based Flood Prediction System', 'Sistem Ramalan Banjir Berasaskan AI Boleh Dijelaskan'),
                    style: context.text.titleLarge),
                const SizedBox(height: 8),
                Text(context.tr('Final year project prototype, version 1.0.', 'Prototaip projek tahun akhir, versi 1.0.'), style: context.text.bodyLarge),
                const SizedBox(height: 12),
                Text(
                    context.tr('It brings flood predictions, the reasons behind them and a preparation checklist for your household into one app.',
                        'Ia menggabungkan ramalan banjir, sebab di sebaliknya dan senarai semak persediaan untuk isi rumah anda dalam satu aplikasi.'),
                    style: context.text.bodyLarge),
              ]),
            ),
          ),
          NoteText(context.tr('Not an official warning service. Always follow JPS, NADMA and local authority instructions.',
              'Bukan perkhidmatan amaran rasmi. Sentiasa ikut arahan JPS, NADMA dan pihak berkuasa tempatan.')),
        ],
      );
}
