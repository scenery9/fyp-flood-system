enum StaffRole { superAdmin, coordinator, fieldOfficer }

/// What a staff member may do. Checked by [AccessControl].
enum Permission {
  viewOperations, // overview, lists, headcount summary, supply alerts
  reviewReports, // verify / reject / mark duplicate
  updateStock, // add stock items, change quantities
  updateOccupancy, // shelter head count, open / close
  managePoints, // add / delete resource and evacuation points
  mapInventory, // catalogue units and item mapping
  manageStaff, // staff accounts
}

/// A staff profile. The password is NOT stored here: Supabase Auth keeps it.
/// [id] is the Supabase Auth user id.
class StaffAccount {
  StaffAccount({
    required this.id,
    required this.fullName,
    required this.username,
    required this.role,
    this.phone,
    this.assignedResourcePointId,
    this.active = true,
  });
  final String id;
  final String fullName;
  final String username;
  final StaffRole role;
  final String? phone;
  final String? assignedResourcePointId;
  final bool active;

  StaffAccount copyWith({StaffRole? role, bool? active}) => StaffAccount(
      id: id, fullName: fullName, username: username, phone: phone,
      assignedResourcePointId: assignedResourcePointId,
      role: role ?? this.role, active: active ?? this.active);
}

/// Proof that a staff member is signed in. Created by StaffAccountService.sessionFor.
class StaffSession {
  StaffSession(this.account);
  final StaffAccount account;
}
