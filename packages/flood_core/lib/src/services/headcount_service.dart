import '../data/table.dart';
import '../errors.dart';
import '../models/evacuation_point.dart';
import '../models/headcount.dart';
import '../models/staff.dart';
import 'access_control.dart';

/// Household head count (public) and the staff summary.
class HeadcountService {
  HeadcountService({
    required this.entries,
    required this.evacuationPoints,
    required this.newId,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;
  final Table<HeadcountEntry> entries;
  final Table<EvacuationPoint> evacuationPoints;
  final IdGenerator newId;
  final DateTime Function() _clock;

  static const int maxHousehold = 30;

  /// Saves a household's count. Submitting again replaces the earlier one,
  /// so one household is never counted twice.
  Future<HeadcountEntry> submit({
    required String householdId,
    required int total,
    int babies = 0,
    int elderly = 0,
    int reducedMobility = 0,
    String? evacuationPointId,
  }) async {
    if (householdId.trim().isEmpty) throw ValidationException('Missing household id');
    if (total < 1 || total > maxHousehold) {
      throw ValidationException('Total people must be between 1 and $maxHousehold');
    }
    if (babies < 0 || elderly < 0 || reducedMobility < 0) {
      throw ValidationException('Numbers cannot be negative');
    }
    if (babies + elderly > total) {
      throw ValidationException('Babies and elderly cannot be more than the total');
    }
    if (reducedMobility > total) {
      throw ValidationException('People with reduced mobility cannot be more than the total');
    }
    if (evacuationPointId != null && await evacuationPoints.byId(evacuationPointId) == null) {
      throw NotFoundException('evacuation point', evacuationPointId);
    }
    final old = await mine(householdId);
    final entry = HeadcountEntry(
        id: old?.id ?? newId(), householdId: householdId, total: total, babies: babies,
        elderly: elderly, reducedMobility: reducedMobility,
        evacuationPointId: evacuationPointId, submittedAt: _clock());
    await entries.put(entry.id, entry);
    return entry;
  }

  Future<HeadcountEntry?> mine(String householdId) async {
    for (final e in await entries.all()) {
      if (e.householdId == householdId) return e;
    }
    return null;
  }

  /// Removes a household's count (e.g. they went home).
  Future<void> withdraw(String householdId) async {
    final e = await mine(householdId);
    if (e != null) await entries.remove(e.id);
  }

  /// Staff: totals per evacuation point, plus a grand total, for the centres
  /// in the staff member's area. Households not at a centre (or at a removed
  /// centre) are counted for Super Admins only.
  Future<HeadcountSummary> summary(StaffSession? session) async {
    AccessControl.require(session, Permission.viewOperations);
    final centres = {for (final p in await evacuationPoints.all()) p.id: p};
    final names = {for (final p in centres.values) p.id: p.name};
    final admin = session!.account.role == StaffRole.superAdmin;
    final rows = <String?, HeadcountRow>{};
    final grand = HeadcountRow(null, 'Total');
    for (final e in await entries.all()) {
      final centre = centres[e.evacuationPointId];
      if (!admin && (centre == null || !session.coversCentre(centre))) continue;
      final key = e.evacuationPointId;
      final row = rows.putIfAbsent(
          key,
          () => HeadcountRow(
              key, key == null ? 'Not at a centre' : (names[key] ?? 'Removed centre')));
      for (final r in [row, grand]) {
        r.households += 1;
        r.total += e.total;
        r.babies += e.babies;
        r.elderly += e.elderly;
        r.reducedMobility += e.reducedMobility;
      }
    }
    final list = rows.values.toList()..sort((a, b) => b.total.compareTo(a.total));
    return HeadcountSummary(list, grand);
  }
}
