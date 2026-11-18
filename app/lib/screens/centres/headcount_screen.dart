import 'package:flood_core/flood_core.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../../security/household_lock_gate.dart';
import '../../theme/app_theme.dart';
import '../../widgets/choices.dart';
import '../../widgets/common.dart';
import '../prepare/household_setup_screen.dart' show HouseholdGroups;

/// "Tell this centre we're coming": how many people and what they need, so
/// relief staff can prepare. Filled in from the household details (behind the
/// household lock); only buttons, except an optional "Other" note.
class HeadcountScreen extends StatelessWidget {
  const HeadcountScreen({super.key, required this.centre});
  final EvacuationPoint centre;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(context.tr("We're coming", 'Kami akan datang', '我们正前往'))),
      body: SafeArea(
        top: false,
        child: HouseholdLockGate(lock: app.deps.lock, phone: app.deps.phone, child: _HeadcountBody(centre: centre)),
      ),
    );
  }
}

class _HeadcountBody extends StatefulWidget {
  const _HeadcountBody({required this.centre});
  final EvacuationPoint centre;

  @override
  State<_HeadcountBody> createState() => _HeadcountBodyState();
}

class _HeadcountBodyState extends State<_HeadcountBody> {
  /// Who is coming, in the same groups as the household details
  /// (people = everyone coming).
  HouseholdProfile _p = const HouseholdProfile(people: 1);

  /// Power and pets have their own rows now; staff still get them as needs.
  static const _chipNeeds = [SpecialNeed.wheelchair, SpecialNeed.babyFormula, SpecialNeed.diapers, SpecialNeed.coldMedicine, SpecialNeed.other];
  Set<SpecialNeed> _needs = {};
  final _other = TextEditingController();
  bool _ready = false;
  bool _sending = false;

  /// True while editing again after a headcount was sent.
  bool _editing = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    final app = AppScope.read(context);
    final h = app.headcount;
    if (h != null) {
      _p = HouseholdProfile(
          people: h.total,
          babies: h.babies,
          children: h.children,
          adults: h.adults,
          elderly: h.elderly,
          mobility: h.reducedMobility,
          pets: h.pets > 0 ? h.pets : (h.needs.contains(SpecialNeed.pet) ? 1 : 0),
          dailyMedicine: h.dailyMedicine,
          powerMachine: h.powerMachine || h.needs.contains(SpecialNeed.power));
      _needs = {...h.needs}..removeAll({SpecialNeed.power, SpecialNeed.pet});
      _other.text = h.otherNeed;
    } else if (app.profile != null) {
      // Starts from the household details, so both show the same numbers.
      final p = app.profile!;
      _p = HouseholdProfile(
          people: p.people.clamp(1, PublicReportsService.maxPeople),
          babies: p.babies,
          children: p.children,
          adults: p.adults,
          elderly: p.elderly,
          mobility: p.mobility,
          pets: p.pets,
          dailyMedicine: p.dailyMedicine,
          powerMachine: p.powerMachine);
      _needs = {if (p.mobility > 0) SpecialNeed.wheelchair};
    }
    _fit();
  }

  @override
  void dispose() {
    _other.dispose();
    super.dispose();
  }

  /// Keeps the four groups and wheelchair users within the total.
  void _fit() {
    _p = _p.copyWith(people: _p.people.clamp(1, PublicReportsService.maxPeople)).fitted();
  }

  Future<void> _send() async {
    final app = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    final sentText = context.tr('Sent. ${widget.centre.name} knows you are coming.', 'Dihantar. ${widget.centre.name} tahu anda akan datang.',
        '已发送。${widget.centre.name} 已知道您正前往。');
    final failText = context.tr('Could not send. Check your internet and try again.', 'Tidak dapat dihantar. Semak internet dan cuba lagi.',
        '无法发送，请检查网络后重试。');
    setState(() => _sending = true);
    try {
      await app.sendHeadcount(HeadcountDraft(
          total: _p.people,
          babies: _p.babies,
          children: _p.children,
          adults: _p.adults,
          elderly: _p.elderly,
          reducedMobility: _p.mobility,
          pets: _p.pets,
          dailyMedicine: _p.dailyMedicine,
          powerMachine: _p.powerMachine,
          needs: {..._needs, if (_p.powerMachine) SpecialNeed.power, if (_p.pets > 0) SpecialNeed.pet},
          otherNeed: _other.text,
          centreId: widget.centre.id,
          location: app.locationIssue == null ? app.userLocation : widget.centre.location,
          status: app.headcount?.status == HeadcountStatus.arrived ? HeadcountStatus.arrived : HeadcountStatus.onTheWay));
      messenger.showSnackBar(SnackBar(content: Text(sentText)));
      if (mounted) setState(() => _editing = false);
    } on ValidationException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      messenger.showSnackBar(SnackBar(content: Text(failText)));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _remove() async {
    final app = AppScope.read(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(context.tr('Remove your headcount?', 'Buang kiraan anda?', '移除您的人数登记？')),
        content: Text(context.tr('The centre will no longer count your household.', 'Pusat tidak lagi mengira isi rumah anda.',
            '中心将不再计算您的家庭人数。')),
        actions: [
          TextButton(onPressed: () => Navigator.of(d).pop(false), child: Text(context.tr('Cancel', 'Batal', '取消'))),
          TextButton(
              key: const ValueKey('headcount-remove-yes'),
              onPressed: () => Navigator.of(d).pop(true),
              child: Text(context.tr('Remove', 'Buang', '移除'))),
        ],
      ),
    );
    if (ok == true) await app.removeHeadcount();
  }

  String _needName(SpecialNeed n) => switch (n) {
        SpecialNeed.wheelchair => context.tr('Wheelchair access', 'Akses kerusi roda', '轮椅通道'),
        SpecialNeed.power => context.tr('Power for oxygen or a machine', 'Elektrik untuk oksigen atau mesin', '氧气机或医疗设备用电'),
        SpecialNeed.babyFormula => context.tr('Baby formula', 'Susu formula bayi', '婴儿奶粉'),
        SpecialNeed.diapers => context.tr('Diapers', 'Lampin', '尿布'),
        SpecialNeed.coldMedicine => context.tr('Medicine that needs a fridge', 'Ubat yang perlu disejukkan', '需冷藏的药物'),
        SpecialNeed.pet => context.tr('Pet', 'Haiwan peliharaan', '宠物'),
        SpecialNeed.other => context.tr('Other', 'Lain-lain', '其他'),
      };

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final h = app.headcount;
    final sent = h != null && !_editing;
    final here = h?.centreId == null || h?.centreId == widget.centre.id;
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(kMargin + 16, 16, kMargin + 16, 0),
          child: Text(widget.centre.name, style: context.text.headlineSmall),
        ),
        if (!app.reports.reachesStaff)
          NoteText(context.tr('Test version: this is kept on your phone only. Relief staff will not see it.',
              'Versi ujian: ini disimpan dalam telefon anda sahaja. Kakitangan bantuan tidak akan melihatnya.',
              '测试版本：仅保存在您的手机上，救援人员看不到。')),
        if (sent) ..._sentView(context, h, here) else ..._form(context, h != null),
      ],
    );
  }

  List<Widget> _sentView(BuildContext context, MyHeadcount h, bool here) {
    final c = context.colors;
    final people = context.tr('${h.total} ${h.total == 1 ? 'person' : 'people'}', '${h.total} orang', '${h.total} 人');
    final hoursLeft = h.expiresAt.difference(DateTime.now()).inHours.clamp(0, 72);
    return [
      const SizedBox(height: kGap),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: kMargin),
        child: AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            CardLabel(context.tr('Sent to', 'Dihantar kepada', '已发送至')),
            Text(h.centreName ?? widget.centre.name, key: const ValueKey('headcount-centre'), style: context.text.titleLarge),
            if (!here)
              Text(context.tr('This is a different centre from the one on this page.', 'Ini pusat yang berlainan daripada pusat di halaman ini.',
                  '这与本页的中心不同。'), style: context.text.bodyMedium),
            const SizedBox(height: 4),
            Text(
                [
                  people,
                  if (h.elderly > 0) context.tr('${h.elderly} aged 60+', '${h.elderly} berumur 60+', '${h.elderly} 名60岁以上'),
                  if (h.babies > 0) context.tr('${h.babies} baby or toddler', '${h.babies} bayi', '${h.babies} 名婴幼儿'),
                  if (h.children > 0) context.tr('${h.children} ${h.children == 1 ? 'child' : 'children'}', '${h.children} kanak-kanak', '${h.children} 名儿童'),
                  if (h.reducedMobility > 0) context.tr('${h.reducedMobility} with wheelchair or walking aid', '${h.reducedMobility} dengan kerusi roda atau alat bantu jalan',
                      '${h.reducedMobility} 人使用轮椅或助行器'),
                  if (h.dailyMedicine) context.tr('daily medicine', 'ubat harian', '每日服药'),
                  if (h.powerMachine || h.needs.contains(SpecialNeed.power)) context.tr('oxygen or machine', 'oksigen atau mesin', '氧气机或医疗设备'),
                  if (h.pets > 0) context.tr('${h.pets} ${h.pets == 1 ? 'pet' : 'pets'}', '${h.pets} haiwan peliharaan', '${h.pets} 只宠物'),
                ].join(' · '),
                style: context.text.bodyLarge!.copyWith(color: c.textMuted, fontFeatures: AppText.tabular)),
            if (h.needs.any(_chipNeeds.contains))
              Text([for (final n in _chipNeeds) if (h.needs.contains(n)) n == SpecialNeed.other && h.otherNeed.isNotEmpty ? h.otherNeed : _needName(n)].join(', '),
                  style: context.text.bodyMedium),
            const SizedBox(height: 16),
            CardLabel(context.tr('Where are you now?', 'Di mana anda sekarang?', '您现在在哪里？')),
            const SizedBox(height: 8),
            ChoiceBoxes<HeadcountStatus>(
              keyPrefix: 'headcount-status',
              values: HeadcountStatus.values,
              selected: {h.status},
              label: (s) => switch (s) {
                HeadcountStatus.onTheWay => context.tr('On the way', 'Dalam perjalanan', '在路上'),
                HeadcountStatus.arrived => context.tr('Arrived', 'Sudah tiba', '已到达'),
                HeadcountStatus.left => context.tr('Left the centre', 'Sudah keluar dari pusat', '已离开中心'),
              },
              onTap: (s) async {
                final messenger = ScaffoldMessenger.of(context);
                final fail = context.tr('Could not update. Check your internet.', 'Tidak dapat dikemas kini. Semak internet anda.', '无法更新，请检查网络。');
                try {
                  await AppScope.read(context).setHeadcountStatus(s);
                } catch (_) {
                  messenger.showSnackBar(SnackBar(content: Text(fail)));
                }
              },
            ),
            const SizedBox(height: 8),
            Text(
                h.status == HeadcountStatus.left
                    ? context.tr('You are no longer counted at this centre.', 'Anda tidak lagi dikira di pusat ini.', '您已不再计入此中心人数。')
                    : context.tr('Counted for $hoursLeft more hours. Send again to keep it longer.',
                        'Dikira untuk $hoursLeft jam lagi. Hantar semula untuk melanjutkannya.', '还会计入 $hoursLeft 小时，重新发送可延长。'),
                style: context.text.bodyMedium!.copyWith(fontFeatures: AppText.tabular)),
            const SizedBox(height: 16),
            FilledButton.tonal(
              key: const ValueKey('headcount-edit'),
              onPressed: () => setState(() => _editing = true),
              child: Text(context.tr('Change and send again', 'Ubah dan hantar semula', '修改并重新发送')),
            ),
            TextButton(
              key: const ValueKey('headcount-remove'),
              onPressed: _remove,
              child: Text(context.tr('Remove my headcount', 'Buang kiraan saya', '移除我的人数登记')),
            ),
          ]),
        ),
      ),
    ];
  }

  List<Widget> _form(BuildContext context, bool again) {
    final less = context.tr('Fewer', 'Kurang', '减少');
    final more = context.tr('More', 'Lebih', '增加');
    return [
      NoteText(context.tr('Relief staff use this to prepare beds, food and supplies like diapers or power for medical machines.',
          'Kakitangan bantuan menggunakan ini untuk menyediakan katil, makanan dan bekalan seperti lampin atau elektrik untuk mesin perubatan.',
          '救援人员会据此准备床位、食物和尿布、医疗设备用电等物资。')),
      const SizedBox(height: kGap),
      GroupCard(children: [
        CountStepper(
          keyPrefix: 'hc-total',
          label: context.tr('People coming', 'Bilangan orang', '前往人数'),
          value: _p.people,
          min: 1,
          max: PublicReportsService.maxPeople,
          lessLabel: less,
          moreLabel: more,
          onChanged: (v) => setState(() {
            _p = _p.copyWith(people: v);
            _fit();
          }),
        ),
      ]),
      SectionHeader(context.tr('Who is coming? (${_p.grouped} of ${_p.people} counted)', 'Siapa yang datang? (${_p.grouped} daripada ${_p.people} dikira)',
          '谁会前往？（已计 ${_p.grouped} / ${_p.people} 人）')),
      GroupCard(children: [
        ...HouseholdGroups.steppers(context, _p, (next) => setState(() => _p = next), keyPrefix: 'hc'),
        Divider(height: 1, color: context.colors.divider),
        CountStepper(
          keyPrefix: 'hc-mobility',
          label: context.tr('Use a wheelchair or walking aid', 'Menggunakan kerusi roda atau alat bantu jalan', '使用轮椅或助行器'),
          value: _p.mobility,
          min: 0,
          max: _p.people,
          lessLabel: less,
          moreLabel: more,
          onChanged: (v) => setState(() => _p = _p.copyWith(mobility: v)),
        ),
      ]),
      SectionHeader(context.tr('Pets and health', 'Haiwan peliharaan dan kesihatan', '宠物和健康')),
      GroupCard(children: [
        CountStepper(
          keyPrefix: 'hc-pets',
          label: context.tr('Pets', 'Haiwan peliharaan', '宠物'),
          value: _p.pets,
          min: 0,
          max: PublicReportsService.maxPets,
          lessLabel: less,
          moreLabel: more,
          onChanged: (v) => setState(() => _p = _p.copyWith(pets: v)),
        ),
        Divider(height: 1, color: context.colors.divider),
        SwitchRow(
          key: const ValueKey('hc-medicine'),
          label: context.tr('Someone needs daily medicine', 'Ada yang perlukan ubat harian', '有人需要每日服药'),
          value: _p.dailyMedicine,
          onChanged: (v) => setState(() => _p = _p.copyWith(dailyMedicine: v)),
        ),
        Divider(height: 1, color: context.colors.divider),
        SwitchRow(
          key: const ValueKey('hc-machine'),
          label: context.tr('Someone uses oxygen or a machine that needs power', 'Ada yang menggunakan oksigen atau mesin yang perlukan elektrik',
                  '有人使用需要供电的氧气机或医疗设备'),
          value: _p.powerMachine,
          onChanged: (v) => setState(() => _p = _p.copyWith(powerMachine: v)),
        ),
      ]),
      SectionHeader(context.tr('What will you need? (choose any)', 'Apa yang anda perlukan? (pilih mana-mana)', '您需要什么？（可多选）')),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: kMargin),
        child: ChoiceBoxes<SpecialNeed>(
          keyPrefix: 'need',
          multiple: true,
          values: _chipNeeds,
          selected: _needs,
          label: _needName,
          onTap: (n) => setState(() => _needs.contains(n) ? _needs.remove(n) : _needs.add(n)),
        ),
      ),
      if (_needs.contains(SpecialNeed.other))
        Padding(
          padding: const EdgeInsets.fromLTRB(kMargin, kGap, kMargin, 0),
          child: TextField(
            key: const ValueKey('need-other-text'),
            controller: _other,
            maxLength: PublicReportsService.maxOtherNeed,
            style: context.text.bodyLarge,
            decoration: InputDecoration(
              labelText: context.tr('Other need (optional)', 'Keperluan lain (pilihan)', '其他需要（可选）'),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
            ),
          ),
        ),
      const SizedBox(height: 16),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: kMargin),
        child: FilledButton(
          key: const ValueKey('headcount-send'),
          onPressed: _sending ? null : _send,
          child: Text(_sending
              ? context.tr('Sending…', 'Menghantar…', '正在发送……')
              : again
                  ? context.tr('Send again', 'Hantar semula', '重新发送')
                  : context.tr('Send to this centre', 'Hantar ke pusat ini', '发送给此中心')),
        ),
      ),
      if (again)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: kMargin),
          child: TextButton(onPressed: () => setState(() => _editing = false), child: Text(context.tr('Cancel', 'Batal', '取消'))),
        ),
      NoteText(context.tr('Only relief staff for this centre see it. Your location is used to choose a centre if needed, and is not stored. One headcount per phone; sending again replaces it.',
          'Hanya kakitangan bantuan pusat ini yang melihatnya. Lokasi anda digunakan untuk memilih pusat jika perlu dan tidak disimpan. Satu kiraan bagi setiap telefon; menghantar semula menggantikannya.',
          '只有此中心的救援人员能看到。必要时会用您的位置选择中心，但不会保存。每部手机只有一份登记，重新发送会替换旧的。')),
    ];
  }
}
