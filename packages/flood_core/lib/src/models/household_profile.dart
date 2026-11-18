/// How the household would leave if told to evacuate.
enum Transport { ownCar, motorcycle, lift, none }

/// Basic household needs, entered once by the user ("About your household").
/// Used to choose and explain the preparation checklist, and to fill in the
/// relief-centre headcount.
///
/// The four age groups ([babies], [children], [adults], [elderly]) together
/// are never more than [people]. People who need help moving are counted on
/// their own (they are also in one of the age groups).
class HouseholdProfile {
  /// The old yes/no answers ([olderAdult], [youngChild], [mobilityAid], [pet])
  /// still work: a "yes" with no number becomes 1.
  const HouseholdProfile({
    this.people = 1,
    int babies = 0,
    this.children = 0,
    this.adults = 0,
    int elderly = 0,
    int mobility = 0,
    int pets = 0,
    this.dailyMedicine = false,
    this.powerMachine = false,
    this.transport = Transport.ownCar,
    bool olderAdult = false,
    bool youngChild = false,
    bool mobilityAid = false,
    bool pet = false,
  })  : babies = youngChild && babies == 0 ? 1 : babies,
        elderly = olderAdult && elderly == 0 ? 1 : elderly,
        mobility = mobilityAid && mobility == 0 ? 1 : mobility,
        pets = pet && pets == 0 ? 1 : pets;

  static const int minPeople = 1;
  static const int maxPeople = 30;
  static const int maxPets = 20;

  final int people;

  /// Babies and toddlers (0-3).
  final int babies;

  /// Children (4-12).
  final int children;
  final int adults;

  /// Aged 60 or older.
  final int elderly;

  /// People who use a wheelchair or walking aid.
  final int mobility;
  final int pets;

  /// Someone needs daily medicine.
  final bool dailyMedicine;

  /// Someone uses oxygen or another machine that needs power.
  final bool powerMachine;
  final Transport transport;

  bool get olderAdult => elderly > 0;
  bool get youngChild => babies > 0;
  bool get mobilityAid => mobility > 0;
  bool get pet => pets > 0;

  /// People counted in the four age groups (never more than [people]).
  int get grouped => babies + children + adults + elderly;

  /// True when the household cannot drive itself out.
  bool get needsHelpToLeave => transport == Transport.lift || transport == Transport.none;

  /// The same household with every count kept within [people]: when the
  /// total goes down, adults are taken off first, then children, babies and
  /// older people.
  HouseholdProfile fitted() {
    var over = grouped - people;
    int take(int n) {
      final t = over <= 0 ? 0 : (n < over ? n : over);
      over -= t;
      return n - t;
    }

    final a = take(adults), c = take(children), b = take(babies), e = take(elderly);
    return HouseholdProfile(
        people: people, babies: b, children: c, adults: a, elderly: e,
        mobility: mobility > people ? people : mobility, pets: pets,
        dailyMedicine: dailyMedicine, powerMachine: powerMachine, transport: transport);
  }

  /// [olderAdult], [youngChild], [mobilityAid] and [pet] set a group to 1
  /// (yes) or 0 (no), for older code and tests.
  HouseholdProfile copyWith({
    int? people,
    int? babies,
    int? children,
    int? adults,
    int? elderly,
    int? mobility,
    int? pets,
    bool? dailyMedicine,
    bool? powerMachine,
    Transport? transport,
    bool? olderAdult,
    bool? youngChild,
    bool? mobilityAid,
    bool? pet,
  }) {
    int yes(bool? flag, int? n, int now) => n ?? (flag == null ? now : (flag ? (now > 0 ? now : 1) : 0));
    return HouseholdProfile(
      people: people ?? this.people,
      babies: yes(youngChild, babies, this.babies),
      children: children ?? this.children,
      adults: adults ?? this.adults,
      elderly: yes(olderAdult, elderly, this.elderly),
      mobility: yes(mobilityAid, mobility, this.mobility),
      pets: yes(pet, pets, this.pets),
      dailyMedicine: dailyMedicine ?? this.dailyMedicine,
      powerMachine: powerMachine ?? this.powerMachine,
      transport: transport ?? this.transport,
    );
  }

  Map<String, String> toMap() => {
        'people': '$people',
        'babies': '$babies',
        'children': '$children',
        'adults': '$adults',
        'elderly': '$elderly',
        'mobility': '$mobility',
        'pets': '$pets',
        'dailyMedicine': '$dailyMedicine',
        'powerMachine': '$powerMachine',
        'transport': transport.name,
      };

  /// Reads a saved profile. Missing or damaged values fall back to the
  /// defaults; profiles saved with the older yes/no answers still load.
  factory HouseholdProfile.fromMap(Map<String, String> m) {
    const d = HouseholdProfile();
    var transport = d.transport;
    for (final t in Transport.values) {
      if (t.name == m['transport']) transport = t;
    }
    final n = int.tryParse(m['people'] ?? '');
    final people = (n == null || n < minPeople || n > maxPeople) ? d.people : n;
    int count(String key, int max, {String? oldYes, String? oldCount}) {
      final v = int.tryParse(m[key] ?? '');
      if (v != null) return (v < 0 || v > max) ? 0 : v;
      if (oldYes != null && m[oldYes] == 'true') {
        final c = int.tryParse(m[oldCount ?? ''] ?? '');
        return (c == null || c < 1 || c > max) ? 1 : c;
      }
      return 0;
    }

    return HouseholdProfile(
      people: people,
      babies: count('babies', maxPeople, oldYes: 'youngChild', oldCount: 'childCount'),
      children: count('children', maxPeople),
      adults: count('adults', maxPeople),
      elderly: count('elderly', maxPeople, oldYes: 'olderAdult', oldCount: 'olderCount'),
      mobility: count('mobility', maxPeople, oldYes: 'mobilityAid', oldCount: 'mobilityCount'),
      pets: count('pets', maxPets, oldYes: 'pet'),
      dailyMedicine: m['dailyMedicine'] == 'true',
      powerMachine: m['powerMachine'] == 'true',
      transport: transport,
    ).fitted();
  }
}
