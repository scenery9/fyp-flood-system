import '../errors.dart';
import '../models/staff.dart';

/// Role-based access control: which role may do what.
/// The same rules are enforced again in the database (supabase/schema.sql and
/// supabase/staff_districts.sql), so a modified app cannot bypass them.
///
/// What a role may do is decided here; WHERE (which district, resource point
/// or centre) is decided by [StaffSession.coversDistrict] and friends.
class AccessControl {
  static const Map<StaffRole, Set<Permission>> _matrix = {
    StaffRole.superAdmin: {
      Permission.viewOperations, Permission.viewReports, Permission.reviewReports,
      Permission.updateStock, Permission.updateOccupancy, Permission.managePoints,
      Permission.mapInventory, Permission.manageStaff,
    },
    StaffRole.coordinator: {
      Permission.viewOperations, Permission.viewReports, Permission.reviewReports,
      Permission.updateStock, Permission.updateOccupancy, Permission.managePoints,
      Permission.mapInventory,
    },
    // Field officers see damage reports in their area but do not review them.
    StaffRole.fieldOfficer: {
      Permission.viewOperations, Permission.viewReports, Permission.updateStock,
      Permission.updateOccupancy,
    },
  };

  static bool can(StaffRole role, Permission permission) => _matrix[role]!.contains(permission);

  /// Returns the staff account if the action is allowed, otherwise throws.
  static StaffAccount require(StaffSession? session, Permission permission) {
    if (session == null) throw NotSignedInException();
    final a = session.account;
    if (!a.active || !can(a.role, permission)) throw PermissionDeniedException(permission.name);
    return a;
  }

  /// Throws unless [inArea] is true. Use after [require].
  static void requireArea(bool inArea) {
    if (!inArea) throw PermissionDeniedException('outside your area');
  }
}
