import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../app/platform.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';
import '../home/alerts_screen.dart';
import '../prepare/household_screen.dart';
import '../report/report_screen.dart';
import 'info_screens.dart';
import 'saved_areas_screen.dart';

/// More tab: household, privacy, reading, language, alerts and information.
/// Every row opens its own page or changes a saved setting.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  void _push(BuildContext context, Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.settings;
    final p = app.profile;
    return ListView(
      primary: false,
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        ScreenTitle(context.tr('More', 'Lagi')),
        SectionHeader(context.tr('Your household', 'Isi rumah anda')),
        GroupCard(children: [
          LinkRow(
            label: context.tr('Household and transport', 'Isi rumah dan kenderaan'),
            value: p == null ? context.tr('Not set', 'Belum diisi') : context.tr('${p.people} ${p.people == 1 ? 'person' : 'people'}', '${p.people} orang', '${p.people} 人'),
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const HouseholdScreen()));
              await app.refreshHouseholdVisibility();
            },
          ),
          LinkRow(
            label: context.tr('Saved areas', 'Kawasan disimpan'),
            value: '${app.areas.length}',
            onTap: () => _push(context, const SavedAreasScreen()),
          ),
          LinkRow(
            label: context.tr('Relief centres', 'Pusat pemindahan'),
            last: true,
            onTap: () => app.selectTab(AppTab.centres),
          ),
        ]),
        SectionHeader(context.tr('Location', 'Lokasi', '位置')),
        GroupCard(children: [
          _SwitchRow(
            key: const ValueKey('location-switch'),
            title: context.tr('Use my location automatically', 'Guna lokasi saya secara automatik', '自动使用我的位置'),
            subtitle: context.tr('Nearest station, relief centres and alerts near you', 'Stesen paling dekat, pusat pemindahan dan amaran berdekatan',
                '最近的测站、疏散中心和附近警报'),
            value: app.locationChoice.automatic == true,
            onChanged: (v) => app.setLocationAutomatic(v),
            last: !(app.locationChoice.automatic == true &&
                (app.locationIssue == LocationIssue.deniedForever || app.locationIssue == LocationIssue.serviceOff)),
          ),
          // Wanted, but the phone is blocking it: a way to fix that.
          if (app.locationChoice.automatic == true &&
              (app.locationIssue == LocationIssue.deniedForever || app.locationIssue == LocationIssue.serviceOff))
            LinkRow(
              key: const ValueKey('location-settings'),
              label: app.locationIssue == LocationIssue.serviceOff
                  ? context.tr('Location is off on this phone: turn it on', 'Lokasi dimatikan pada telefon: hidupkan', '手机定位已关闭：开启')
                  : context.tr('Blocked in phone settings: allow it', 'Disekat dalam tetapan telefon: benarkan', '已在手机设置中阻止：去允许'),
              last: true,
              onTap: app.deps.location.openSettings,
            ),
        ]),
        SectionHeader(context.tr('Privacy', 'Privasi')),
        const GroupCard(children: [LockSwitchRow()]),
        SectionHeader(context.tr('Easy to read', 'Mudah dibaca')),
        GroupCard(children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(context.tr('Text size', 'Saiz teks'), style: context.text.bodyLarge),
              const SizedBox(height: 8),
              Row(children: [
                for (final (size, name, px) in [
                  (TextSize.small, context.tr('Small', 'Kecil'), 15.0),
                  (TextSize.medium, context.tr('Standard', 'Biasa'), 19.0),
                  (TextSize.large, context.tr('Large', 'Besar'), 25.0),
                ]) ...[
                  if (size != TextSize.small) const SizedBox(width: 6),
                  Expanded(
                    child: _SizeChoice(
                      key: ValueKey('size-${size.name}'),
                      name: name,
                      px: px,
                      selected: s.textSize == size,
                      onTap: () => app.updateSettings(s.copyWith(textSize: size)),
                    ),
                  ),
                ],
              ]),
            ]),
          ),
          Divider(height: 1, color: context.colors.divider),
          _SwitchRow(
            key: const ValueKey('high-contrast'),
            title: context.tr('High contrast', 'Kontras tinggi'),
            subtitle: context.tr('Darker text and borders', 'Teks dan sempadan lebih gelap'),
            value: s.highContrast,
            onChanged: (v) => app.updateSettings(s.copyWith(highContrast: v)),
            last: true,
          ),
        ]),
        SectionHeader(context.tr('Read aloud', 'Baca kuat', '朗读')),
        GroupCard(children: [
          _SwitchRow(
            key: const ValueKey('read-aloud-switch'),
            title: context.tr('Read aloud', 'Baca kuat', '朗读'),
            subtitle: context.tr('Speaker button on AI forecasts', 'Butang pembesar suara pada ramalan AI', 'AI预测上显示朗读按钮'),
            value: app.readAloud,
            onChanged: (v) => app.setReadAloud(v),
          ),
          _SwitchRow(
            key: const ValueKey('slow-speech-switch'),
            title: context.tr('Slower speech', 'Pertuturan lebih perlahan', '放慢语速'),
            subtitle: context.tr('Easier to follow', 'Lebih mudah diikuti', '更容易听懂'),
            value: app.slowSpeech,
            onChanged: app.readAloud ? (v) => app.setSlowSpeech(v) : null,
            last: true,
          ),
        ]),
        SectionHeader(context.tr('Language', 'Bahasa')),
        GroupCard(children: [
          for (final (lang, name) in [
            (AppLanguage.en, 'English'),
            (AppLanguage.ms, 'Bahasa Melayu'),
            (AppLanguage.zh, '中文'),
          ])
            _RadioRow(
              key: ValueKey('lang-${lang.name}'),
              label: name,
              selected: s.language == lang,
              last: lang == AppLanguage.zh,
              onTap: () => app.updateSettings(s.copyWith(language: lang)),
            ),
        ]),
        if (s.language != AppLanguage.en)
          NoteText(context.tr('', 'Nama stesen dan arahan laluan kekal dalam bahasa asal.', '测站名称和路线步骤保留原文。')),
        SectionHeader(context.tr('Alerts', 'Amaran')),
        GroupCard(children: [
          LinkRow(
            key: const ValueKey('more-alerts'),
            label: context.tr('Alerts near you now', 'Amaran berdekatan anda sekarang', '您附近的当前警报'),
            value: '${app.alerts.now.length}',
            onTap: () => _push(context, const AlertsScreen()),
          ),
          LinkRow(
            label: context.tr('Notify me from', 'Beritahu saya mulai'),
            value: context.levelName(s.notificationThreshold),
            last: true,
            onTap: () => _push(context, const NotifyLevelScreen()),
          ),
        ]),
        SectionHeader(context.tr('Reports', 'Laporan', '报告')),
        GroupCard(children: [
          LinkRow(
            label: context.tr('Report flooding', 'Laporkan banjir', '报告水灾'),
            onTap: () => _push(context, const ReportScreen()),
          ),
          LinkRow(
            key: const ValueKey('more-my-reports'),
            label: context.tr('My reports', 'Laporan saya', '我的报告'),
            last: true,
            onTap: () => _push(context, const ReportScreen(startOnMine: true)),
          ),
        ]),
        SectionHeader(context.tr('Help and information', 'Bantuan dan maklumat')),
        GroupCard(children: [
          LinkRow(label: context.tr('How the prediction works', 'Cara ramalan berfungsi'), onTap: () => _push(context, const HowAiWorksScreen())),
          LinkRow(label: context.tr('Where the data comes from', 'Sumber data'), onTap: () => _push(context, const DataSourcesScreen())),
          LinkRow(label: context.tr('Emergency numbers', 'Nombor kecemasan'), onTap: () => _push(context, const EmergencyNumbersScreen())),
          LinkRow(label: context.tr('About this app', 'Tentang aplikasi ini'), last: true, onTap: () => _push(context, const AboutScreen())),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(kMargin + 16, 24, kMargin + 16, 0),
          child: Text(
              app.deps.liveData
                  ? context.tr('FYP prototype · JPS data, sample relief centres · version 1.0',
                      'Prototaip FYP · data JPS, pusat pemindahan contoh · versi 1.0', '毕业项目原型 · JPS数据，示例疏散中心 · 版本1.0')
                  : context.tr('FYP prototype · sample data · version 1.0', 'Prototaip FYP · data contoh · versi 1.0'),
              style: context.text.bodyMedium),
        ),
      ],
    );
  }
}

/// Fingerprint / PIN lock for the household details. Turning it off needs
/// the phone's check first (rules in HouseholdLockService).
class LockSwitchRow extends StatefulWidget {
  const LockSwitchRow({super.key});

  @override
  State<LockSwitchRow> createState() => _LockSwitchRowState();
}

class _LockSwitchRowState extends State<LockSwitchRow> {
  bool? _on;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_on == null) {
      AppScope.read(context).deps.lock.isOn().then((v) {
        if (mounted) setState(() => _on = v);
      });
    }
  }

  Future<void> _change(bool turnOn) async {
    final app = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    final reason = context.tr('Confirm it is you to turn off the lock', 'Sahkan diri anda untuk mematikan kunci');
    final lock = app.deps.lock;
    if (turnOn) {
      await lock.turnOn();
    } else {
      final phone = await app.deps.phone.status();
      final confirmed = phone == PhoneLock.ready && await app.deps.phone.confirm(reason);
      try {
        await lock.turnOff(phone: phone, identityConfirmed: confirmed);
      } on ValidationException catch (e) {
        messenger.showSnackBar(SnackBar(content: Text(e.message)));
      }
    }
    final on = await lock.isOn();
    if (mounted) setState(() => _on = on);
    await app.refreshHouseholdVisibility();
  }

  @override
  Widget build(BuildContext context) => _SwitchRow(
        key: const ValueKey('lock-switch'),
        title: context.tr('Lock my household details', 'Kunci butiran isi rumah saya'),
        subtitle: context.tr('Use fingerprint or phone PIN', 'Guna cap jari atau PIN telefon'),
        value: _on ?? false,
        onChanged: _on == null ? null : _change,
        last: true,
      );
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({super.key, required this.title, required this.subtitle, required this.value, required this.onChanged, this.last = false});
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool last;

  @override
  Widget build(BuildContext context) => MergeSemantics(
        child: InkWell(
          onTap: onChanged == null ? null : () => onChanged!(!value),
          child: Container(
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: context.colors.divider))),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: context.text.bodyLarge),
                  Text(subtitle, style: context.text.bodyMedium),
                ]),
              ),
              Switch(value: value, onChanged: onChanged),
            ]),
          ),
        ),
      );
}

class _RadioRow extends StatelessWidget {
  const _RadioRow({super.key, required this.label, required this.selected, required this.onTap, this.last = false});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final bool last;

  @override
  Widget build(BuildContext context) => Semantics(
        selected: selected,
        inMutuallyExclusiveGroup: true,
        button: true,
        label: label,
        excludeSemantics: true,
        child: InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 56),
            decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: context.colors.divider))),
            child: Row(children: [
              Expanded(child: Text(label, style: context.text.bodyLarge)),
              if (selected) Icon(Icons.check, color: context.colors.primary),
            ]),
          ),
        ),
      );
}

class _SizeChoice extends StatelessWidget {
  const _SizeChoice({super.key, required this.name, required this.px, required this.selected, required this.onTap});
  final String name;
  final double px;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      button: true,
      label: name,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: MediaQuery.withNoTextScaling(
          child: Container(
            height: 64,
            decoration: BoxDecoration(
              color: selected ? const Color(0xFFEAF1F8) : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: selected ? c.primary : c.divider, width: 2),
            ),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text('A', style: TextStyle(fontSize: px, height: 1, fontWeight: FontWeight.w700, color: selected ? c.primary : c.textMuted)),
              const SizedBox(height: 4),
              Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, height: 1, color: selected ? c.primary : c.textMuted)),
            ]),
          ),
        ),
      ),
    );
  }
}
