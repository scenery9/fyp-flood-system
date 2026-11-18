import 'evacuation_point.dart';
import 'resources.dart';

enum StaffRole { superAdmin, coordinator, fieldOfficer }

/// What a staff member may do. Checked by [AccessControl].
enum Permission {
  viewOperations, // overview, lists, headcount summary, supply alerts
  viewReports, // see damage reports (within the staff member's area)
  reviewReports, // verify / reject / mark duplicate
  updateStock, // add stock items, change quantities
  updateOccupancy, // shelter head count, open / close
  managePoints, // add / delete resource and evacuation points
  mapInventory, // catalogue units and item mapping
  manageStaff, // staff accounts
}

/// A staff profile. The password is NOT stored here: Supabase Auth keeps it.
/// [id] is the Supabase Auth user id.
///
/// Area limits (same as supabase/staff_districts.sql):
/// - Super Admin: every district.
/// - Coordinator: one district ([assignedDistrict], required).
/// - Field Officer: one resource point ([assignedResourcePointId], required)
///   and the centres it supplies; sees damage reports in that point's district.
class StaffAccount {
  StaffAccount({
    required this.id,
    required this.fullName,
    required this.username,
    required this.role,
    this.phone,
    this.assignedResourcePointId,
    this.assignedDistrict,
    this.active = true,
  });
  final String id;
  final String fullName;
  final String username;
  final StaffRole role;
  final String? phone;
  final String? assignedResourcePointId;
  final String? assignedDistrict;
  final bool active;

  StaffAccount copyWith({
    StaffRole? role,
    bool? active,
    String? assignedDistrict,
    String? assignedResourcePointId,
    bool clearDistrict = false,
    bool clearResourcePoint = false,
  }) =>
      StaffAccount(
          id: id, fullName: fullName, username: username, phone: phone,
          assignedResourcePointId:
              clearResourcePoint ? null : (assignedResourcePointId ?? this.assignedResourcePointId),
          assignedDistrict: clearDistrict ? null : (assignedDistrict ?? this.assignedDistrict),
          role: role ?? this.role, active: active ?? this.active);
}

/// Proof that a staff member is signed in. Created by StaffAccountService.sessionFor.
class StaffSession {
  StaffSession(this.account, {this.resourcePointDistrict});
  final StaffAccount account;

  /// District of a Field Officer's resource point, looked up at sign-in.
  final String? resourcePointDistrict;

  bool get _admin => account.role == StaffRole.superAdmin;

  /// The one district this person works in; null for a Super Admin
  /// (all districts) or when no area has been assigned yet.
  String? get district => switch (account.role) {
        StaffRole.superAdmin => null,
        StaffRole.coordinator => account.assignedDistrict,
        StaffRole.fieldOfficer => resourcePointDistrict,
      };

  /// True if a record in [district] is inside this person's area.
  /// Records with no district are visible to Super Admins only.
  bool coversDistrict(String? district) =>
      _admin || (district != null && district == this.district);

  /// Resource points: Coordinators by district, Field Officers only their own.
  bool coversResourcePoint(ResourcePoint p) => switch (account.role) {
        StaffRole.superAdmin => true,
        StaffRole.coordinator => p.district != null && p.district == account.assignedDistrict,
        StaffRole.fieldOfficer =>
          account.assignedResourcePointId != null && p.id == account.assignedResourcePointId,
      };

  /// Relief centres: Coordinators by district, Field Officers the centres
  /// their resource point supplies.
  bool coversCentre(EvacuationPoint c) => switch (account.role) {
        StaffRole.superAdmin => true,
        StaffRole.coordinator => c.district != null && c.district == account.assignedDistrict,
        StaffRole.fieldOfficer =>
          account.assignedResourcePointId != null && c.resourcePointId == account.assignedResourcePointId,
      };
}
