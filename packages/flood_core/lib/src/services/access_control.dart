import '../errors.dart';
import '../models/staff.dart';

/// Role-based access control: which role may do what.
/// The same rules are enforced again in the database (supabase/schema.sql),
/// so a modified app cannot bypass them.
class AccessControl {
  static const Map<StaffRole, Set<Permission>> _matrix = {
    StaffRole.superAdmin: {
      Permission.viewOperations, Permission.reviewReports, Permission.updateStock,
      Permission.updateOccupancy, Permission.managePoints, Permission.mapInventory,
      Permission.manageStaff,
    },
    StaffRole.coordinator: {
      Permission.viewOperations, Permission.reviewReports, Permission.updateStock,
      Permission.updateOccupancy, Permission.managePoints, Permission.mapInventory,
    },
    StaffRole.fieldOfficer: {
      Permission.viewOperations, Permission.reviewReports, Permission.updateStock,
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
}
