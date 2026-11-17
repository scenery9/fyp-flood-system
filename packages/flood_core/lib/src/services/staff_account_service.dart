import '../data/table.dart';
import '../errors.dart';
import '../models/resources.dart';
import '../models/staff.dart';
import 'access_control.dart';

/// Staff profiles and roles. Passwords and login are handled by Supabase Auth;
/// after a successful login the app calls [sessionFor] with the Auth user id.
class StaffAccountService {
  StaffAccountService({required this.accounts, required this.resourcePoints});
  final Table<StaffAccount> accounts;
  final Table<ResourcePoint> resourcePoints;

  static final _usernamePattern = RegExp(r'^[a-z0-9._]{3,30}$');
  static final _phonePattern = RegExp(r'^\+?[0-9]{7,15}$');

  /// Turns a logged-in Auth user into a staff session. Throws
  /// [PermissionDeniedException] if the user is not staff or was deactivated.
  Future<StaffSession> sessionFor(String authUserId) async {
    final a = await accounts.byId(authUserId);
    if (a == null || !a.active) throw PermissionDeniedException('staff');
    return StaffSession(a);
  }

  Future<List<StaffAccount>> list(StaffSession? session) async {
    AccessControl.require(session, Permission.manageStaff);
    return accounts.all();
  }

  Future<StaffAccount> create(
    StaffSession? session, {
    required String authUserId,
    required String fullName,
    required String username,
    required StaffRole role,
    String? phone,
    String? assignedResourcePointId,
  }) async {
    AccessControl.require(session, Permission.manageStaff);
    final name = fullName.trim();
    final user = username.trim().toLowerCase();
    final tel = phone?.replaceAll(RegExp(r'[\s-]'), '');
    if (authUserId.trim().isEmpty) throw ValidationException('Missing login id');
    if (name.isEmpty) throw ValidationException('Full name is required');
    if (!_usernamePattern.hasMatch(user)) {
      throw ValidationException('Username: 3-30 characters, letters, numbers, dot or underscore');
    }
    if (tel != null && tel.isNotEmpty && !_phonePattern.hasMatch(tel)) {
      throw ValidationException('Phone number is not valid');
    }
    if (role == StaffRole.coordinator && assignedResourcePointId == null) {
      throw ValidationException('A coordinator needs an assigned resource point');
    }
    if (assignedResourcePointId != null &&
        await resourcePoints.byId(assignedResourcePointId) == null) {
      throw NotFoundException('resource point', assignedResourcePointId);
    }
    final existing = await accounts.all();
    if (existing.any((a) => a.id == authUserId)) throw ConflictException('Account already exists');
    if (existing.any((a) => a.username == user)) throw ConflictException('Username already taken');
    final account = StaffAccount(
        id: authUserId, fullName: name, username: user, role: role,
        phone: (tel == null || tel.isEmpty) ? null : tel,
        assignedResourcePointId: assignedResourcePointId);
    await accounts.put(account.id, account);
    return account;
  }

  /// Activates or deactivates an account. You cannot deactivate yourself
  /// or the last active Super Admin.
  Future<StaffAccount> setActive(StaffSession? session, String id, bool active) async {
    final me = AccessControl.require(session, Permission.manageStaff);
    final target = await _get(id);
    if (!active) {
      if (target.id == me.id) throw ConflictException('You cannot deactivate your own account');
      await _guardLastSuperAdmin(target);
    }
    final updated = target.copyWith(active: active);
    await accounts.put(id, updated);
    return updated;
  }

  /// Changes a role. The last active Super Admin cannot be demoted.
  Future<StaffAccount> changeRole(StaffSession? session, String id, StaffRole role) async {
    AccessControl.require(session, Permission.manageStaff);
    final target = await _get(id);
    if (role != StaffRole.superAdmin) await _guardLastSuperAdmin(target);
    if (role == StaffRole.coordinator && target.assignedResourcePointId == null) {
      throw ValidationException('A coordinator needs an assigned resource point');
    }
    final updated = target.copyWith(role: role);
    await accounts.put(id, updated);
    return updated;
  }

  Future<StaffAccount> _get(String id) async =>
      await accounts.byId(id) ?? (throw NotFoundException('staff account', id));

  Future<void> _guardLastSuperAdmin(StaffAccount target) async {
    if (target.role != StaffRole.superAdmin || !target.active) return;
    final admins = (await accounts.all()).where((a) => a.role == StaffRole.superAdmin && a.active);
    if (admins.length <= 1) throw ConflictException('At least one active Super Admin is required');
  }
}
