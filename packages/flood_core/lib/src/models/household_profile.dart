/// How the household would leave if told to evacuate.
enum Transport { ownCar, motorcycle, lift, none }

/// Basic household needs, entered once by the user ("About your household").
/// Used only to choose and explain the preparation checklist.
class HouseholdProfile {
  const HouseholdProfile({
    this.people = 1,
    this.olderAdult = false,
    this.youngChild = false,
    this.mobilityAid = false,
    this.dailyMedicine = false,
    this.pet = false,
    this.transport = Transport.ownCar,
  });

  static const int minPeople = 1;
  static const int maxPeople = 30;

  final int people;

  /// Someone aged 60 or older.
  final bool olderAdult;

  /// A baby or young child.
  final bool youngChild;

  /// Someone using a wheelchair or walking aid.
  final bool mobilityAid;

  /// Someone needing daily medicine or a machine (e.g. oxygen).
  final bool dailyMedicine;
  final bool pet;
  final Transport transport;

  /// True when the household cannot drive itself out.
  bool get needsHelpToLeave => transport == Transport.lift || transport == Transport.none;

  HouseholdProfile copyWith({
    int? people,
    bool? olderAdult,
    bool? youngChild,
    bool? mobilityAid,
    bool? dailyMedicine,
    bool? pet,
    Transport? transport,
  }) =>
      HouseholdProfile(
        people: people ?? this.people,
        olderAdult: olderAdult ?? this.olderAdult,
        youngChild: youngChild ?? this.youngChild,
        mobilityAid: mobilityAid ?? this.mobilityAid,
        dailyMedicine: dailyMedicine ?? this.dailyMedicine,
        pet: pet ?? this.pet,
        transport: transport ?? this.transport,
      );

  Map<String, String> toMap() => {
        'people': '$people',
        'olderAdult': '$olderAdult',
        'youngChild': '$youngChild',
        'mobilityAid': '$mobilityAid',
        'dailyMedicine': '$dailyMedicine',
        'pet': '$pet',
        'transport': transport.name,
      };

  /// Reads a saved profile. Missing or damaged values fall back to the defaults.
  factory HouseholdProfile.fromMap(Map<String, String> m) {
    const d = HouseholdProfile();
    var transport = d.transport;
    for (final t in Transport.values) {
      if (t.name == m['transport']) transport = t;
    }
    final n = int.tryParse(m['people'] ?? '');
    return HouseholdProfile(
      people: (n == null || n < minPeople || n > maxPeople) ? d.people : n,
      olderAdult: m['olderAdult'] == 'true',
      youngChild: m['youngChild'] == 'true',
      mobilityAid: m['mobilityAid'] == 'true',
      dailyMedicine: m['dailyMedicine'] == 'true',
      pet: m['pet'] == 'true',
      transport: transport,
    );
  }
}
