import '../util/geo.dart';

enum DamageType { house, vehicle, road, utilities, crops, other }

enum DamageSeverity { minor, moderate, severe }

enum ReportStatus { pending, verified, rejected, duplicate }

class DamageReport {
  DamageReport({
    required this.id,
    required this.reporterId,
    required this.location,
    required this.incidentDate,
    required this.type,
    required this.severity,
    required this.createdAt,
    this.depthM,
    this.description = '',
    this.status = ReportStatus.pending,
    this.staffNote,
    this.reviewedBy,
    this.reviewedAt,
    this.duplicateOfId,
  });
  final String id;
  final String reporterId;
  final GeoPoint location;
  final DateTime incidentDate;
  final DamageType type;
  final DamageSeverity severity;
  final double? depthM;
  final String description;
  final DateTime createdAt;
  final ReportStatus status;

  /// Note from staff to the reporter (required when rejected).
  final String? staffNote;
  final String? reviewedBy;
  final DateTime? reviewedAt;
  final String? duplicateOfId;

  DamageReport reviewed({
    required ReportStatus status,
    required String by,
    required DateTime at,
    String? note,
    String? duplicateOfId,
  }) =>
      DamageReport(
          id: id, reporterId: reporterId, location: location, incidentDate: incidentDate,
          type: type, severity: severity, createdAt: createdAt, depthM: depthM,
          description: description, status: status, staffNote: note, reviewedBy: by,
          reviewedAt: at, duplicateOfId: duplicateOfId);
}
