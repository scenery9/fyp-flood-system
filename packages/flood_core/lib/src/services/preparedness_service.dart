import '../errors.dart';
import '../models/app_settings.dart';
import '../models/household_profile.dart';
import '../models/risk_level.dart';
import 'settings_service.dart';

/// One thing to do on the preparation checklist.
class PrepItem {
  const PrepItem({
    required this.id,
    required this.level,
    required this.title,
    required this.howTo,
    this.reason,
    this.advice = false,
    this.call,
    this.bring = const [],
  });

  /// Unique across all levels, e.g. "alert.charge".
  final String id;
  final RiskLevel level;
  final String title;

  /// One or two sentences on how to do it.
  final String howTo;

  /// Why this item is on the list for this household (null for everyone's items).
  final String? reason;

  /// Advice to remember, not a task to tick ("Do not walk through flood
  /// water"). Shown apart from the checklist and never counted as done.
  final bool advice;

  /// A number the item asks the user to call (one-tap call button).
  final String? call;

  /// "What to bring" for go-bag items, fitted to the household.
  final List<String> bring;
}

typedef _When = bool Function(HouseholdProfile p);

class _Def {
  const _Def(this.id, this.level, this.title, this.howTo, {this.when, this.reason, this.advice = false, this.call, this.bring = false});
  final String id;
  final RiskLevel level;
  final Map<AppLanguage, String> title;
  final Map<AppLanguage, String> howTo;
  final _When? when;
  final _Reason? reason;
  final bool advice;
  final String? call;

  /// Has the go-bag "What to bring" list.
  final bool bring;
}

enum _Reason { olderAdult, youngChild, mobilityAid, dailyMedicine, pet, noTransport, leaveEarly, powerMachine }

const _en = AppLanguage.en;
const _ms = AppLanguage.ms;
const _zh = AppLanguage.zh;

/// The personalised preparation checklist ("Prepare" tab).
///
/// DRAFT wording: review against official NADMA / APM advice before release.
/// Chinese (Simplified) is a draft: have a native speaker review it.
class PreparednessService {
  const PreparednessService();

  static bool _needsHelp(HouseholdProfile p) => p.needsHelpToLeave;

  static final List<_Def> _defs = [
    // ---------- Normal ----------
    _Def('normal.gobag', RiskLevel.normal, {
      _en: 'Pack a go-bag',
      _ms: 'Sediakan beg kecemasan',
      _zh: '准备紧急包',
    }, {
      _en: 'Pack it now and keep it by the door, so you can grab it and go. The list below is made for your household.',
      _ms: 'Sediakan sekarang dan letak dekat pintu supaya boleh terus dibawa. Senarai di bawah disesuaikan untuk isi rumah anda.',
      _zh: '现在就准备好并放在门边，以便随手带走。下面的清单是按您的家庭定制的。',
    }, bring: true),
    _Def('normal.centre', RiskLevel.normal, {
      _en: 'Know your nearest relief centre',
      _ms: 'Ketahui pusat pemindahan terdekat',
      _zh: '了解最近的疏散中心',
    }, {
      _en: 'Open the Centres tab and check the way there once while the roads are dry.',
      _ms: 'Buka tab Pusat dan semak jalan ke sana semasa jalan masih kering.',
      _zh: '打开“疏散中心”页面，趁道路还干时先走一趟熟悉路线。',
    }),
    _Def('normal.numbers', RiskLevel.normal, {
      _en: 'Save the emergency numbers',
      _ms: 'Simpan nombor kecemasan',
      _zh: '保存紧急电话',
    }, {
      _en: '999 for any emergency. 994 Bomba. 991 Civil Defence (APM).',
      _ms: '999 untuk semua kecemasan. 994 Bomba. 991 Angkatan Pertahanan Awam (APM).',
      _zh: '所有紧急情况拨999。消防局994。民防部队（APM）991。',
    }),
    _Def('normal.medicine', RiskLevel.normal, {
      _en: 'Keep 7 days of medicine in the go-bag',
      _ms: 'Simpan ubat untuk 7 hari dalam beg kecemasan',
      _zh: '在紧急包里放7天的药物',
    }, {
      _en: 'Add a copy of the prescription. Keep medicine that needs cold in a cool box.',
      _ms: 'Sertakan salinan preskripsi. Simpan ubat yang perlu sejuk dalam kotak sejuk.',
      _zh: '附上处方副本。需要冷藏的药物放进冷藏盒。',
    }, when: (p) => p.dailyMedicine, reason: _Reason.dailyMedicine),
    _Def('normal.driver', RiskLevel.normal, {
      _en: 'Agree who will drive you out',
      _ms: 'Tetapkan siapa yang akan membawa anda keluar',
      _zh: '约好谁载您撤离',
    }, {
      _en: 'Ask a neighbour or family member now and save their phone number.',
      _ms: 'Tanya jiran atau ahli keluarga sekarang dan simpan nombor telefon mereka.',
      _zh: '现在就询问邻居或家人，并保存他们的电话号码。',
    }, when: _needsHelp, reason: _Reason.noTransport),
    _Def('normal.baby', RiskLevel.normal, {
      _en: 'Pack baby items',
      _ms: 'Sediakan barang bayi',
      _zh: '准备婴儿用品',
    }, {
      _en: 'Milk, bottles, nappies and a change of clothes in a separate bag.',
      _ms: 'Susu, botol, lampin dan pakaian ganti dalam beg berasingan.',
      _zh: '把奶粉、奶瓶、尿布和替换衣物放进另一个袋子。',
    }, when: (p) => p.youngChild, reason: _Reason.youngChild),
    _Def('normal.pet', RiskLevel.normal, {
      _en: 'Prepare for your pet',
      _ms: 'Bersedia untuk haiwan peliharaan',
      _zh: '为宠物做好准备',
    }, {
      _en: 'A carrier or lead, food for 3 days and a water bowl.',
      _ms: 'Bekas bawa atau tali, makanan untuk 3 hari dan bekas air.',
      _zh: '准备宠物笼或牵绳、3天的食物和水碗。',
    }, when: (p) => p.pet, reason: _Reason.pet),

    // ---------- Alert ----------
    _Def('alert.charge', RiskLevel.alert, {
      _en: 'Charge phones and power bank',
      _ms: 'Cas telefon dan power bank',
      _zh: '为手机和充电宝充电',
    }, {
      _en: 'Keep them charged in case the electricity is cut.',
      _ms: 'Pastikan sentiasa dicas sekiranya bekalan elektrik terputus.',
      _zh: '保持电量充足，以防停电。',
    }),
    _Def('alert.valuables', RiskLevel.alert, {
      _en: 'Move valuables and documents up high',
      _ms: 'Alihkan barang berharga dan dokumen ke tempat tinggi',
      _zh: '把贵重物品和文件移到高处',
    }, {
      _en: 'Use a high shelf or the upper floor.',
      _ms: 'Gunakan rak tinggi atau tingkat atas.',
      _zh: '放在高架子上或楼上。',
    }),
    _Def('alert.driver', RiskLevel.alert, {
      _en: 'Ask your driver now if they can take you',
      _ms: 'Tanya pemandu anda sekarang sama ada boleh membawa anda',
      _zh: '现在就问载送者能否载您',
    }, {
      _en: 'If no one can, plan to call 999 early, not at the last minute.',
      _ms: 'Jika tiada sesiapa, rancang untuk menghubungi 999 awal, bukan pada saat akhir.',
      _zh: '如果没有人能载，请提早拨打999，不要等到最后一刻。',
    }, when: _needsHelp, reason: _Reason.noTransport),
    _Def('alert.medicine', RiskLevel.alert, {
      _en: 'Check the medicine is in the go-bag',
      _ms: 'Pastikan ubat ada dalam beg kecemasan',
      _zh: '确认药物已放进紧急包',
    }, {
      _en: 'Count the days left and refill now if it is low.',
      _ms: 'Kira baki hari dan dapatkan bekalan baharu jika hampir habis.',
      _zh: '数一数剩下几天的量，不足的话现在补充。',
    }, when: (p) => p.dailyMedicine, reason: _Reason.dailyMedicine),
    _Def('alert.aids', RiskLevel.alert, {
      _en: 'Pack walking aid, glasses and hearing aid',
      _ms: 'Sediakan alat bantu jalan, cermin mata dan alat bantu dengar',
      _zh: '准备助行器、眼镜和助听器',
    }, {
      _en: 'Keep them next to the go-bag so nothing is left behind.',
      _ms: 'Letakkan di sebelah beg kecemasan supaya tiada yang tertinggal.',
      _zh: '放在紧急包旁边，以免遗漏。',
    }, when: (p) => p.olderAdult, reason: _Reason.olderAdult),
    _Def('alert.mobility', RiskLevel.alert, {
      _en: 'Plan how to move the wheelchair or walking aid',
      _ms: 'Rancang cara membawa kerusi roda atau alat bantu jalan',
      _zh: '计划如何搬运轮椅或助行器',
    }, {
      _en: 'Check it fits in the car that will take you, and who will help lift it.',
      _ms: 'Pastikan ia muat dalam kereta yang akan membawa anda, dan siapa yang akan membantu mengangkatnya.',
      _zh: '确认能放进载您的车，并安排谁来帮忙抬。',
    }, when: (p) => p.mobilityAid, reason: _Reason.mobilityAid),
    _Def('alert.machine', RiskLevel.alert, {
      _en: 'Charge the spare battery for the oxygen or machine',
      _ms: 'Cas bateri simpanan untuk oksigen atau mesin',
      _zh: '为氧气机或医疗设备的备用电池充电',
    }, {
      _en: 'Power may be cut. Tell the relief centre you need power for it.',
      _ms: 'Bekalan elektrik mungkin terputus. Beritahu pusat pemindahan anda perlukan elektrik untuknya.',
      _zh: '可能会停电。告知疏散中心您需要为它供电。',
    }, when: (p) => p.powerMachine, reason: _Reason.powerMachine),
    _Def('alert.updates', RiskLevel.alert, {
      _en: 'Listen for official updates',
      _ms: 'Dengar maklumat rasmi',
      _zh: '留意官方消息',
    }, {
      _en: 'Radio, TV, or JPS and NADMA announcements.',
      _ms: 'Radio, TV, atau pengumuman JPS dan NADMA.',
      _zh: '收听电台、电视，或JPS和NADMA的公告。',
    }),
    _Def('alert.water', RiskLevel.alert, {
      _en: 'Fill water bottles',
      _ms: 'Isi botol air',
      _zh: '装满水瓶',
    }, {
      _en: 'Tap water may be cut or unsafe during a flood.',
      _ms: 'Bekalan air paip mungkin terputus atau tidak selamat semasa banjir.',
      _zh: '水灾期间自来水可能中断或不安全。',
    }),

    // ---------- Warning ----------
    _Def('warning.leave', RiskLevel.warning, {
      _en: 'Leave early. Do not wait for Danger',
      _ms: 'Keluar awal. Jangan tunggu tahap Bahaya',
      _zh: '提早撤离，不要等到“危险”级别',
    }, {
      _en: 'Roads can flood quickly. Go to the relief centre while it is still easy.',
      _ms: 'Jalan boleh dinaiki air dengan cepat. Pergi ke pusat pemindahan semasa masih mudah.',
      _zh: '道路可能很快被淹。趁还容易时前往疏散中心。',
    }, when: (p) => p.needsHelpToLeave || p.olderAdult || p.mobilityAid, reason: _Reason.leaveEarly),
    _Def('warning.power', RiskLevel.warning, {
      _en: 'Switch off electricity at the main switch',
      _ms: 'Tutup suis utama elektrik',
      _zh: '关闭总电源开关',
    }, {
      _en: 'Only if your hands and the floor are dry.',
      _ms: 'Hanya jika tangan dan lantai kering.',
      _zh: '只在双手和地面干燥时才操作。',
    }),
    _Def('warning.bag', RiskLevel.warning, {
      _en: 'Take your go-bag and documents',
      _ms: 'Bawa beg kecemasan dan dokumen',
      _zh: '带上紧急包和文件',
    }, {
      _en: 'Keep it with you, not in the boot of the car. Check it has everything below.',
      _ms: 'Simpan bersama anda, bukan di dalam but kereta. Pastikan semua barang di bawah ada.',
      _zh: '随身携带，不要放在车尾箱。检查下列物品是否齐全。',
    }, bring: true),
    _Def('warning.vehicle', RiskLevel.warning, {
      _en: 'Move your vehicle to higher ground',
      _ms: 'Alihkan kenderaan ke tempat tinggi',
      _zh: '把车辆移到高处',
    }, {
      _en: 'Park where the water is unlikely to reach.',
      _ms: 'Letak kenderaan di tempat yang tidak mungkin dinaiki air.',
      _zh: '停在不太可能被水淹到的地方。',
    }, when: (p) => !p.needsHelpToLeave),
    _Def('warning.pet', RiskLevel.warning, {
      _en: 'Bring your pet with you',
      _ms: 'Bawa haiwan peliharaan bersama anda',
      _zh: '带宠物一起走',
    }, {
      _en: 'Put it in the carrier or on a lead before you leave.',
      _ms: 'Masukkan ke dalam bekas bawa atau pasang tali sebelum keluar.',
      _zh: '出门前把宠物放进笼子或系上牵绳。',
    }, when: (p) => p.pet, reason: _Reason.pet),
    _Def('warning.tell', RiskLevel.warning, {
      _en: 'Tell family where you are going',
      _ms: 'Beritahu keluarga ke mana anda pergi',
      _zh: '告诉家人您要去哪里',
    }, {
      _en: 'Send one message with the name of the relief centre.',
      _ms: 'Hantar satu mesej dengan nama pusat pemindahan.',
      _zh: '发一条信息，写明疏散中心的名称。',
    }),

    // ---------- Danger ----------
    _Def('danger.leave', RiskLevel.danger, {
      _en: 'Leave now for the relief centre',
      _ms: 'Pergi ke pusat pemindahan sekarang',
      _zh: '立即前往疏散中心',
    }, {
      _en: 'Or go to higher ground if the road is cut.',
      _ms: 'Atau ke tempat tinggi jika jalan terputus.',
      _zh: '如果道路已断，就前往高处。',
    }),
    _Def('danger.help', RiskLevel.danger, {
      _en: 'Help the older or less mobile person out first',
      _ms: 'Bantu warga emas atau yang kurang upaya keluar dahulu',
      _zh: '先帮助长者或行动不便者撤离',
    }, {
      _en: 'They need the most time.',
      _ms: 'Mereka memerlukan masa paling lama.',
      _zh: '他们需要最多的时间。',
    }, when: (p) => p.olderAdult || p.mobilityAid, reason: _Reason.olderAdult),
    _Def('danger.call', RiskLevel.danger, {
      _en: 'If you cannot leave, call 999',
      _ms: 'Jika tidak dapat keluar, hubungi 999',
      _zh: '如果无法离开，请拨打999',
    }, {
      // The only advice card at Danger: the two flood-water cautions are part
      // of it, not separate banners.
      _en: 'Say your address, how many people, and who needs help. '
          'Do not walk or drive through flood water: fast water 15 cm deep can knock a person down. '
          'If you are trapped, go to the highest floor with your phone and wait for rescue. Do not go into a closed attic.',
      _ms: 'Beritahu alamat, bilangan orang, dan siapa yang perlukan bantuan. '
          'Jangan meredah air banjir: air deras sedalam 15 cm boleh menjatuhkan seseorang. '
          'Jika terperangkap, naik ke tingkat paling atas dengan telefon dan tunggu bantuan. Jangan masuk ke loteng tertutup.',
      _zh: '说明地址、人数以及谁需要帮助。'
          '切勿涉水步行或驾车：15厘米深的急流就能把人冲倒。'
          '如果被困，带上手机前往最高楼层等待救援。不要进入封闭的阁楼。',
    }, advice: true, call: '999'),
  ];

  /// Go-bag contents for everyone, then for this household's needs.
  static List<String> _bring(HouseholdProfile? p, AppLanguage l) {
    String t(String en, String ms, String zh) => switch (l) { _en => en, _ms => ms, _zh => zh };
    return [
      t('IC (MyKad), birth certificates and other documents in a waterproof bag', 'IC (MyKad), sijil kelahiran dan dokumen lain dalam beg kalis air',
          '身份证（MyKad）、出生证明及其他文件，装在防水袋里'),
      t('Phone, charger and power bank', 'Telefon, pengecas dan power bank', '手机、充电器和充电宝'),
      t('Cash', 'Wang tunai', '现金'),
      t('Drinking water and food that needs no cooking', 'Air minuman dan makanan yang tidak perlu dimasak', '饮用水和无需烹煮的食物'),
      t('Torch with spare batteries', 'Lampu suluh dengan bateri ganti', '手电筒和备用电池'),
      t('Clothes for 3 days and a towel', 'Pakaian untuk 3 hari dan tuala', '3天的衣物和毛巾'),
      t('Toothbrush, soap and sanitary pads', 'Berus gigi, sabun dan tuala wanita', '牙刷、肥皂和卫生巾'),
      if (p != null && p.dailyMedicine)
        t('Medicine for 7 days and a copy of the prescription', 'Ubat untuk 7 hari dan salinan preskripsi', '7天的药物和处方副本'),
      if (p != null && p.powerMachine)
        t('Spare battery and charger for the oxygen or machine', 'Bateri simpanan dan pengecas untuk oksigen atau mesin', '氧气机或医疗设备的备用电池和充电器'),
      if (p != null && p.youngChild)
        t('Milk, bottles and nappies for the baby', 'Susu, botol dan lampin untuk bayi', '婴儿的奶粉、奶瓶和尿布'),
      if (p != null && p.olderAdult)
        t('Glasses, hearing aids and dentures', 'Cermin mata, alat bantu dengar dan gigi palsu', '眼镜、助听器和假牙'),
      if (p != null && p.mobilityAid) t('Wheelchair or walking aid', 'Kerusi roda atau alat bantu jalan', '轮椅或助行器'),
      if (p != null && p.pet) t('Pet food, water bowl and a lead or carrier', 'Makanan haiwan, bekas air dan tali atau bekas bawa', '宠物食物、水碗及牵绳或宠物笼'),
    ];
  }

  static const Map<_Reason, Map<AppLanguage, String>> _reasons = {
    _Reason.olderAdult: {_en: 'Because someone is 60 or older', _ms: 'Kerana ada yang berumur 60 tahun ke atas', _zh: '因为家中有60岁或以上的人'},
    _Reason.youngChild: {_en: 'Because there is a baby or young child', _ms: 'Kerana ada bayi atau kanak-kanak kecil', _zh: '因为家中有婴儿或幼儿'},
    _Reason.mobilityAid: {_en: 'Because someone uses a wheelchair or walking aid', _ms: 'Kerana ada yang menggunakan kerusi roda atau alat bantu jalan', _zh: '因为家中有人使用轮椅或助行器'},
    _Reason.dailyMedicine: {_en: 'Because someone needs daily medicine', _ms: 'Kerana ada yang perlukan ubat harian', _zh: '因为家中有人需要每日用药'},
    _Reason.pet: {_en: 'Because you have a pet', _ms: 'Kerana anda ada haiwan peliharaan', _zh: '因为您有宠物'},
    _Reason.noTransport: {_en: 'Because you have no own transport', _ms: 'Kerana anda tiada kenderaan sendiri', _zh: '因为您没有自己的交通工具'},
    _Reason.leaveEarly: {_en: 'Because your household needs more time to leave', _ms: 'Kerana isi rumah anda perlukan lebih masa untuk keluar', _zh: '因为您的家庭需要更多时间撤离'},
    _Reason.powerMachine: {_en: 'Because someone uses oxygen or a machine that needs power', _ms: 'Kerana ada yang menggunakan oksigen atau mesin yang perlukan elektrik', _zh: '因为家中有人使用需要供电的氧气机或医疗设备'},
  };

  static String _pick(Map<AppLanguage, String> m, AppLanguage l) => m[l] ?? m[_en]!;

  /// Tasks to tick for [level]. With no [profile] (setup skipped) only the
  /// items for every household are given. Advice is not included; see [advice].
  List<PrepItem> checklist(RiskLevel level, HouseholdProfile? profile,
          {AppLanguage language = AppLanguage.en}) =>
      _items(level, profile, language, advice: false);

  /// Things to remember at [level] ("Do not walk through flood water"),
  /// shown apart from the checklist and never ticked.
  List<PrepItem> advice(RiskLevel level, HouseholdProfile? profile, {AppLanguage language = AppLanguage.en}) =>
      _items(level, profile, language, advice: true);

  List<PrepItem> _items(RiskLevel level, HouseholdProfile? profile, AppLanguage language, {required bool advice}) => [
        for (final d in _defs)
          if (d.level == level && d.advice == advice && (d.when == null || (profile != null && d.when!(profile))))
            PrepItem(
              id: d.id,
              level: d.level,
              title: _pick(d.title, language),
              howTo: _pick(d.howTo, language),
              reason: d.reason == null ? null : _pick(_reasons[d.reason]!, language),
              advice: d.advice,
              call: d.call,
              bring: d.bring ? _bring(profile, language) : const [],
            ),
      ];

  /// Every item id that exists, for checking saved progress.
  static Set<String> get allIds => {for (final d in _defs) d.id};
}

/// Saves the household profile and checklist progress on the phone.
/// Give it two separate [SettingsStore]s (a store's save replaces everything in it).
class HouseholdService {
  HouseholdService({required this.profileStore, required this.progressStore});
  final SettingsStore profileStore;
  final SettingsStore progressStore;

  static const _savedKey = 'saved';
  static const _skippedKey = 'skipped';
  static const _doneKey = 'done';

  /// Null until the user has saved the household form once.
  Future<HouseholdProfile?> loadProfile() async {
    final m = await profileStore.load();
    if (m[_savedKey] != 'true') return null;
    return HouseholdProfile.fromMap(m);
  }

  /// True when the first-launch form was skipped and never saved.
  Future<bool> setupSkipped() async {
    final m = await profileStore.load();
    return m[_savedKey] != 'true' && m[_skippedKey] == 'true';
  }

  /// Throws [ValidationException] when the number of people is out of range.
  Future<HouseholdProfile> saveProfile(HouseholdProfile p) async {
    if (p.people < HouseholdProfile.minPeople || p.people > HouseholdProfile.maxPeople) {
      throw ValidationException(
          'Number of people must be ${HouseholdProfile.minPeople} to ${HouseholdProfile.maxPeople}');
    }
    if (p.babies < 0 || p.children < 0 || p.adults < 0 || p.elderly < 0 || p.mobility < 0 || p.pets < 0) {
      throw ValidationException('Numbers cannot be negative');
    }
    if (p.grouped > p.people) {
      throw ValidationException('Babies, children, adults and older people add up to more than ${p.people}');
    }
    if (p.mobility > p.people) throw ValidationException('People who need help moving cannot be more than ${p.people}');
    if (p.pets > HouseholdProfile.maxPets) throw ValidationException('At most ${HouseholdProfile.maxPets} pets');
    await profileStore.save({...p.toMap(), _savedKey: 'true'});
    return p;
  }

  /// "Skip for now" on the first-launch form. Does nothing once a profile is saved.
  Future<void> skipSetup() async {
    if (await loadProfile() != null) return;
    await profileStore.save({_skippedKey: 'true'});
  }

  /// Ids of ticked checklist items. Unknown ids from older versions are dropped.
  Future<Set<String>> doneItems() async {
    final raw = (await progressStore.load())[_doneKey] ?? '';
    final known = PreparednessService.allIds;
    return {
      for (final id in raw.split(','))
        if (known.contains(id.trim())) id.trim(),
    };
  }

  /// Ticks or unticks one item. Returns the new set.
  Future<Set<String>> setDone(String id, bool done) async {
    if (!PreparednessService.allIds.contains(id)) throw ValidationException('Unknown checklist item');
    final items = await doneItems();
    if (done) {
      items.add(id);
    } else {
      items.remove(id);
    }
    await progressStore.save({_doneKey: (items.toList()..sort()).join(',')});
    return items;
  }

  /// Clears the ticks for one level ("Start again").
  Future<Set<String>> resetLevel(RiskLevel level) async {
    final items = (await doneItems())..removeWhere((id) => id.startsWith('${level.name}.'));
    await progressStore.save({_doneKey: (items.toList()..sort()).join(',')});
    return items;
  }
}
