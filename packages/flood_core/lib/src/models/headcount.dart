/// One household's head count. [babies], [elderly] and [reducedMobility]
/// are parts of [total], not extra people.
class HeadcountEntry {
  HeadcountEntry({
    required this.id,
    required this.householdId,
    required this.total,
    required this.babies,
    required this.elderly,
    required this.reducedMobility,
    required this.submittedAt,
    this.evacuationPointId,
  });
  final String id;
  final String householdId;
  final String? evacuationPointId;
  final int total;
  final int babies;
  final int elderly;
  final int reducedMobility;
  final DateTime submittedAt;
}

/// One row of the staff headcount summary.
class HeadcountRow {
  HeadcountRow(this.evacuationPointId, this.name);
  final String? evacuationPointId;
  final String name;
  int households = 0;
  int total = 0;
  int babies = 0;
  int elderly = 0;
  int reducedMobility = 0;
}

class HeadcountSummary {
  HeadcountSummary(this.rows, this.grandTotal);
  final List<HeadcountRow> rows;
  final HeadcountRow grandTotal;
}
