import 'dart:math';

import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../theme/app_theme.dart';
import '../../widgets/choices.dart';
import '../../widgets/common.dart';
import 'location_picker_screen.dart';

enum _Tab { report, mine }

/// Quick time choices; [pick] opens the date and time pickers.
enum _When { now, hourAgo, threeHoursAgo, yesterday, pick }

/// "Report flooding": flooding seen now, or damage, with buttons for every
/// answer. Only the optional description is typed.
class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key, this.startOnMine = false});
  final bool startOnMine;

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  late _Tab _tab = widget.startOnMine ? _Tab.mine : _Tab.report;
  ReportKind _kind = ReportKind.floodingNow;
  GeoPoint? _place; // null = where I am now
  _When _when = _When.now;
  DateTime? _picked;
  DepthBand _depth = DepthBand.unsure;
  DamageType? _type;
  DamageSeverity? _severity;
  final _text = TextEditingController();
  String _ref = _newRef();
  bool _sending = false;
  Future<List<MyReport>>? _mine;

  /// A new reference for each form, so a retry is not counted twice.
  static String _newRef() {
    final r = Random();
    return '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${r.nextInt(1 << 32).toRadixString(36)}';
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  DateTime _occurredAt() {
    final now = DateTime.now();
    return switch (_when) {
      _When.now => now,
      _When.hourAgo => now.subtract(const Duration(hours: 1)),
      _When.threeHoursAgo => now.subtract(const Duration(hours: 3)),
      _When.yesterday => now.subtract(const Duration(days: 1)),
      _When.pick => _picked ?? now,
    };
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final day = await showDatePicker(
      context: context,
      firstDate: now.subtract(PublicReportsService.oldestReport),
      lastDate: now,
      initialDate: _picked ?? now,
      helpText: context.tr('When did it happen?', 'Bila ia berlaku?', '何时发生？'),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(_picked ?? now));
    if (!mounted) return;
    var at = DateTime(day.year, day.month, day.day, time?.hour ?? 12, time?.minute ?? 0);
    if (at.isAfter(now)) at = now;
    setState(() {
      _picked = at;
      _when = _When.pick;
    });
  }

  Future<void> _pickPlace() async {
    final app = AppScope.read(context);
    final p = await Navigator.of(context).push<GeoPoint>(
        MaterialPageRoute(builder: (_) => LocationPickerScreen(start: _place ?? app.userLocation)));
    if (p != null && mounted) setState(() => _place = p);
  }

  Future<void> _submit() async {
    final app = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    final noPlace = context.tr('Your location is off. Tap "Somewhere else" and pick the place on the map.',
        'Lokasi anda dimatikan. Tekan "Tempat lain" dan pilih tempat pada peta.', '您的定位已关闭。请点“其他地方”，在地图上选择地点。');
    final done = app.reports.reachesStaff
        ? context.tr('Report sent. An officer will check it.', 'Laporan dihantar. Pegawai akan menyemaknya.', '报告已发送，官员会进行核查。')
        : context.tr('Report saved on this phone (test version).', 'Laporan disimpan dalam telefon ini (versi ujian).', '报告已保存在此手机（测试版本）。');
    final failed = context.tr('Could not send. Check your internet and try again; it will not be sent twice.',
        'Tidak dapat dihantar. Semak internet dan cuba lagi; ia tidak akan dihantar dua kali.', '无法发送，请检查网络后重试；不会重复发送。');
    final place = _place ?? (app.locationIssue == null ? app.userLocation : null);
    if (place == null) {
      messenger.showSnackBar(SnackBar(content: Text(noPlace)));
      return;
    }
    setState(() => _sending = true);
    try {
      await app.submitReport(FloodReportDraft(
          kind: _kind,
          location: place,
          occurredAt: _occurredAt(),
          clientRef: _ref,
          depth: _depth,
          type: _type,
          severity: _severity,
          description: _text.text));
      messenger.showSnackBar(SnackBar(content: Text(done)));
      if (!mounted) return;
      setState(() {
        _ref = _newRef();
        _kind = ReportKind.floodingNow;
        _place = null;
        _when = _When.now;
        _picked = null;
        _depth = DepthBand.unsure;
        _type = null;
        _severity = null;
        _text.clear();
        _tab = _Tab.mine;
        _mine = null;
      });
    } on ValidationException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(failed)));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('Report flooding', 'Laporkan banjir', '报告水灾'))),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: kMargin),
              child: PillSegments<_Tab>(
                values: _Tab.values,
                selected: _tab,
                label: (t) => switch (t) {
                  _Tab.report => context.tr('New report', 'Laporan baharu', '新报告'),
                  _Tab.mine => context.tr('My reports', 'Laporan saya', '我的报告'),
                },
                onChanged: (t) => setState(() => _tab = t),
              ),
            ),
            if (_tab == _Tab.report) ..._form(context) else _MyReports(future: _mine ??= AppScope.read(context).myReports()),
          ],
        ),
      ),
    );
  }

  List<Widget> _form(BuildContext context) {
    final app = AppScope.of(context);
    final c = context.colors;
    final here = app.locationIssue == null;
    final place = _place ?? (here ? app.userLocation : null);
    final placeName = place == null ? null : app.placeNear(place);
    String whenLabel(_When w) => switch (w) {
          _When.now => context.tr('Now', 'Sekarang', '现在'),
          _When.hourAgo => context.tr('1 hour ago', '1 jam lalu', '1 小时前'),
          _When.threeHoursAgo => context.tr('3 hours ago', '3 jam lalu', '3 小时前'),
          _When.yesterday => context.tr('Yesterday', 'Semalam', '昨天'),
          _When.pick => _picked == null
              ? context.tr('Pick a date', 'Pilih tarikh', '选择日期')
              : '${_picked!.day}/${_picked!.month} ${_picked!.hour.toString().padLeft(2, '0')}:${_picked!.minute.toString().padLeft(2, '0')}',
        };
    return [
      SectionHeader(context.tr('What are you reporting?', 'Apa yang anda laporkan?', '您要报告什么？')),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: kMargin),
        child: ChoiceBoxes<ReportKind>(
          keyPrefix: 'kind',
          values: ReportKind.values,
          selected: {_kind},
          icon: (k) => k == ReportKind.floodingNow ? Icons.water : Icons.home_repair_service_outlined,
          label: (k) => switch (k) {
            ReportKind.floodingNow => context.tr('Flooding here now', 'Banjir di sini sekarang', '此处正在淹水'),
            ReportKind.damage => context.tr('Damage', 'Kerosakan', '损失'),
          },
          onTap: (k) => setState(() => _kind = k),
        ),
      ),
      SectionHeader(context.tr('Where?', 'Di mana?', '在哪里？')),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: kMargin),
        child: ChoiceBoxes<bool>(
          keyPrefix: 'where',
          values: const [true, false],
          selected: {_place == null && here},
          icon: (v) => v ? Icons.my_location : Icons.map_outlined,
          label: (v) => v ? context.tr("I'm here now", 'Saya di sini sekarang', '我现在就在这里') : context.tr('Somewhere else', 'Tempat lain', '其他地方'),
          onTap: (v) => v
              ? (here ? setState(() => _place = null) : app.retryLocation())
              : _pickPlace(),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(kMargin + 16, 8, kMargin + 16, 0),
        child: Text(
            place == null
                ? context.tr('Location is off. Tap "I\'m here now" to allow it, or pick the place on the map.',
                    'Lokasi dimatikan. Tekan "Saya di sini sekarang" untuk membenarkannya, atau pilih tempat pada peta.',
                    '定位已关闭。点“我现在就在这里”以允许定位，或在地图上选择地点。')
                : placeName == null
                    ? context.tr('Place chosen on the map', 'Tempat dipilih pada peta', '已在地图上选择地点')
                    : context.tr('Near $placeName', 'Berhampiran $placeName', '靠近$placeName'),
            key: const ValueKey('report-place'),
            style: context.text.bodyLarge!.copyWith(color: c.textMuted)),
      ),
      SectionHeader(context.tr('When?', 'Bila?', '何时？')),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: kMargin),
        child: ChoiceBoxes<_When>(
          keyPrefix: 'when',
          values: _When.values,
          selected: {_when},
          label: whenLabel,
          onTap: (w) => w == _When.pick ? _pickDate() : setState(() => _when = w),
        ),
      ),
      SectionHeader(context.tr('How deep is the water?', 'Berapa dalam air?', '水有多深？')),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: kMargin),
        child: ChoiceBoxes<DepthBand>(
          keyPrefix: 'depth',
          values: DepthBand.values,
          selected: {_depth},
          label: (d) => switch (d) {
            DepthBand.ankle => context.tr('Ankle', 'Buku lali', '脚踝'),
            DepthBand.knee => context.tr('Knee', 'Lutut', '膝盖'),
            DepthBand.waist => context.tr('Waist', 'Pinggang', '腰部'),
            DepthBand.chest => context.tr('Chest or higher', 'Dada atau lebih', '胸口或更高'),
            DepthBand.unsure => context.tr('Not sure', 'Tidak pasti', '不确定'),
          },
          onTap: (d) => setState(() => _depth = d),
        ),
      ),
      if (_kind == ReportKind.damage) ...[
        SectionHeader(context.tr('What was damaged?', 'Apa yang rosak?', '什么受损？')),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kMargin),
          child: ChoiceBoxes<DamageType>(
            keyPrefix: 'type',
            values: DamageType.values,
            selected: {?_type},
            label: (t) => switch (t) {
              DamageType.house => context.tr('Home', 'Rumah', '住家'),
              DamageType.vehicle => context.tr('Vehicle', 'Kenderaan', '车辆'),
              DamageType.road => context.tr('Road or bridge', 'Jalan atau jambatan', '道路或桥梁'),
              DamageType.utilities => context.tr('Power, water or phone lines', 'Elektrik, air atau talian telefon', '电力、供水或电话线'),
              DamageType.crops => context.tr('Crops or animals', 'Tanaman atau ternakan', '农作物或牲畜'),
              DamageType.other => context.tr('Other', 'Lain-lain', '其他'),
            },
            onTap: (t) => setState(() => _type = t),
          ),
        ),
        SectionHeader(context.tr('How bad?', 'Seteruk mana?', '有多严重？')),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kMargin),
          child: ChoiceBoxes<DamageSeverity>(
            keyPrefix: 'severity',
            values: DamageSeverity.values,
            selected: {?_severity},
            label: (v) => switch (v) {
              DamageSeverity.minor => context.tr('Minor: can still be used', 'Kecil: masih boleh digunakan', '轻微：仍可使用'),
              DamageSeverity.moderate => context.tr('Moderate: needs repair', 'Sederhana: perlu dibaiki', '中等：需要维修'),
              DamageSeverity.severe => context.tr('Severe: cannot be used', 'Teruk: tidak boleh digunakan', '严重：无法使用'),
            },
            onTap: (v) => setState(() => _severity = v),
          ),
        ),
      ],
      SectionHeader(context.tr('Anything else? (optional)', 'Apa-apa lagi? (pilihan)', '还有其他吗？（可选）')),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: kMargin),
        child: TextField(
          key: const ValueKey('report-text'),
          controller: _text,
          maxLines: 3,
          maxLength: PublicReportsService.maxDescription,
          style: context.text.bodyLarge,
          decoration: InputDecoration(
            hintText: context.tr('e.g. road closed near the school', 'cth. jalan ditutup berhampiran sekolah', '例如：学校附近道路封闭'),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
          ),
        ),
      ),
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: kMargin),
        child: FilledButton(
          key: const ValueKey('report-send'),
          onPressed: _sending || (_kind == ReportKind.damage && (_type == null || _severity == null)) ? null : _submit,
          child: Text(_sending ? context.tr('Sending…', 'Menghantar…', '正在发送……') : context.tr('Send report', 'Hantar laporan', '发送报告')),
        ),
      ),
      if (_kind == ReportKind.damage && (_type == null || _severity == null))
        NoteText(context.tr('Choose what was damaged and how bad it is.', 'Pilih apa yang rosak dan seteruk mana.', '请选择受损项目和严重程度。')),
      NoteText(app.reports.reachesStaff
          ? context.tr('Only officers checking reports see the exact place. Every report is checked by a person.',
              'Hanya pegawai yang menyemak laporan melihat lokasi tepat. Setiap laporan disemak oleh manusia.', '只有核查报告的官员能看到确切地点。每份报告都由人工核查。')
          : context.tr('Test version: reports are kept on this phone only. Relief staff will not see them.',
              'Versi ujian: laporan disimpan dalam telefon ini sahaja. Kakitangan bantuan tidak akan melihatnya.', '测试版本：报告只保存在此手机，救援人员看不到。')),
    ];
  }
}

class _MyReports extends StatelessWidget {
  const _MyReports({required this.future});
  final Future<List<MyReport>> future;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<MyReport>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator()));
        }
        if (snap.hasError) {
          return NoteText(context.tr('Could not load your reports. Check your internet.', 'Laporan anda tidak dapat dimuatkan. Semak internet anda.',
              '无法载入您的报告，请检查网络。'));
        }
        final list = snap.data ?? const <MyReport>[];
        if (list.isEmpty) {
          return NoteText(context.tr('You have not sent any reports yet.', 'Anda belum menghantar sebarang laporan.', '您还没有发送任何报告。'));
        }
        return Padding(
          padding: const EdgeInsets.only(top: kGap),
          child: GroupCard(children: [
            for (var i = 0; i < list.length; i++) _ReportRow(r: list[i], last: i == list.length - 1),
          ]),
        );
      },
    );
  }
}

class _ReportRow extends StatelessWidget {
  const _ReportRow({required this.r, required this.last});
  final MyReport r;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final (text, color, tint, icon) = switch (r.status) {
      ReportStatus.pending => (context.tr('Being checked', 'Sedang disemak', '核查中'), const Color(0xFF4F5966), const Color(0xFFEEF0F2), Icons.hourglass_top),
      ReportStatus.verified => (context.tr('Confirmed', 'Disahkan', '已确认'), const Color(0xFF176B3A), const Color(0xFFE3F2E8), Icons.check_circle),
      ReportStatus.rejected => (context.tr('Not accepted', 'Tidak diterima', '未被接受'), const Color(0xFFA8221A), const Color(0xFFFBE3DF), Icons.cancel),
      ReportStatus.duplicate => (context.tr('Already reported', 'Sudah dilaporkan', '已有人报告'), const Color(0xFF4F5966), const Color(0xFFEEF0F2), Icons.copy_all),
    };
    final what = r.kind == ReportKind.floodingNow
        ? context.tr('Flooding seen', 'Banjir dilihat', '目击淹水')
        : context.tr('Damage', 'Kerosakan', '损失');
    final d = r.occurredAt;
    final date = '${d.day}/${d.month}/${d.year} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(border: last ? null : Border(bottom: BorderSide(color: context.colors.divider))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(what, style: context.text.titleMedium),
            Text(date, style: context.text.bodyMedium!.copyWith(fontFeatures: AppText.tabular)),
            if (r.staffNote != null) Text(context.tr('Officer: ${r.staffNote}', 'Pegawai: ${r.staffNote}', '官员：${r.staffNote}'), style: context.text.bodyMedium),
          ]),
        ),
        TagBadge(text: text, color: color, tint: tint, icon: icon),
      ]),
    );
  }
}
