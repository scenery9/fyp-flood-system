import '../data/table.dart';
import '../errors.dart';
import '../models/damage_report.dart';
import '../models/staff.dart';
import '../util/geo.dart';
import 'access_control.dart';

/// Flood damage reports: public submit + tracking, staff review.
class DamageReportService {
  DamageReportService({required this.reports, required this.newId, DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;
  final Table<DamageReport> reports;
  final IdGenerator newId;
  final DateTime Function() _clock;

  /// Anti-spam: one reporter may have at most this many unreviewed reports.
  static const int maxPendingPerReporter = 5;
  static const int maxDescriptionLength = 500;
  static const double maxDepthM = 10;

  // ---------- public ----------

  Future<DamageReport> submit({
    required String reporterId,
    required GeoPoint location,
    required DateTime incidentDate,
    required DamageType type,
    required DamageSeverity severity,
    double? depthM, // leave null if unsure
    String description = '',
  }) async {
    final now = _clock();
    final text = description.trim();
    if (reporterId.trim().isEmpty) throw ValidationException('Missing reporter id');
    if (incidentDate.isAfter(now)) throw ValidationException('Date cannot be in the future');
    if (incidentDate.isBefore(now.subtract(const Duration(days: 365)))) {
      throw ValidationException('Date cannot be more than a year ago');
    }
    if (depthM != null && (depthM.isNaN || depthM < 0 || depthM > maxDepthM)) {
      throw ValidationException('Water depth must be between 0 and $maxDepthM m');
    }
    if (text.length > maxDescriptionLength) {
      throw ValidationException('Description is too long (max $maxDescriptionLength characters)');
    }
    final pending = (await reports.all())
        .where((r) => r.reporterId == reporterId && r.status == ReportStatus.pending)
        .length;
    if (pending >= maxPendingPerReporter) {
      throw ConflictException('You have $pending reports waiting for review. Please wait.');
    }
    final r = DamageReport(
        id: newId(), reporterId: reporterId, location: location, incidentDate: incidentDate,
        type: type, severity: severity, depthM: depthM, description: text, createdAt: now);
    await reports.put(r.id, r);
    return r;
  }

  /// "My reports": the reporter's own reports, newest first.
  Future<List<DamageReport>> mine(String reporterId) async =>
      (await reports.all()).where((r) => r.reporterId == reporterId).toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

  // ---------- staff ----------

  /// All reports, or one status. Pending: oldest first (a queue). Others: newest first.
  Future<List<DamageReport>> list(StaffSession? session, {ReportStatus? status}) async {
    AccessControl.require(session, Permission.reviewReports);
    final l = (await reports.all()).where((r) => status == null || r.status == status).toList();
    if (status == ReportStatus.pending) {
      l.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    } else {
      l.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    return l;
  }

  Future<Map<ReportStatus, int>> counts(StaffSession? session) async {
    AccessControl.require(session, Permission.reviewReports);
    final m = {for (final s in ReportStatus.values) s: 0};
    for (final r in await reports.all()) {
      m[r.status] = m[r.status]! + 1;
    }
    return m;
  }

  Future<DamageReport> verify(StaffSession? session, String id, {String? note}) =>
      _review(session, id, ReportStatus.verified, note: note);

  /// Rejecting needs a note, so the reporter knows why.
  Future<DamageReport> reject(StaffSession? session, String id, {required String note}) async {
    if (note.trim().isEmpty) {
      AccessControl.require(session, Permission.reviewReports);
      throw ValidationException('A note to the reporter is required when rejecting');
    }
    return _review(session, id, ReportStatus.rejected, note: note);
  }

  Future<DamageReport> markDuplicate(StaffSession? session, String id, {required String ofId}) async {
    AccessControl.require(session, Permission.reviewReports);
    if (ofId == id) throw ValidationException('A report cannot be a duplicate of itself');
    final original = await reports.byId(ofId) ?? (throw NotFoundException('report', ofId));
    if (original.status == ReportStatus.duplicate || original.status == ReportStatus.rejected) {
      throw ConflictException('The original report is itself ${original.status.name}');
    }
    return _review(session, id, ReportStatus.duplicate, duplicateOfId: ofId);
  }

  Future<DamageReport> _review(StaffSession? session, String id, ReportStatus status,
      {String? note, String? duplicateOfId}) async {
    final me = AccessControl.require(session, Permission.reviewReports);
    final r = await reports.byId(id) ?? (throw NotFoundException('report', id));
    if (r.status != ReportStatus.pending) {
      throw ConflictException('Report was already ${r.status.name}');
    }
    final n = note?.trim();
    final updated = r.reviewed(
        status: status, by: me.id, at: _clock(),
        note: (n == null || n.isEmpty) ? null : n, duplicateOfId: duplicateOfId);
    await reports.put(id, updated);
    return updated;
  }
}
