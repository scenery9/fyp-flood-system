import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';
import 'helpers.dart';

void main() {
  group('TP15 Roles and permissions', () {
    test('Super Admin may do everything', () {
      for (final p in Permission.values) {
        expect(AccessControl.can(StaffRole.superAdmin, p), isTrue);
      }
    });
    test('Coordinator: everything except staff accounts', () {
      expect(AccessControl.can(StaffRole.coordinator, Permission.manageStaff), isFalse);
      expect(AccessControl.can(StaffRole.coordinator, Permission.managePoints), isTrue);
      expect(AccessControl.can(StaffRole.coordinator, Permission.mapInventory), isTrue);
    });
    test('Field Officer: day-to-day work only (sees reports, does not review them)', () {
      expect(AccessControl.can(StaffRole.fieldOfficer, Permission.viewReports), isTrue);
      expect(AccessControl.can(StaffRole.fieldOfficer, Permission.reviewReports), isFalse);
      expect(AccessControl.can(StaffRole.fieldOfficer, Permission.updateStock), isTrue);
      expect(AccessControl.can(StaffRole.fieldOfficer, Permission.managePoints), isFalse);
      expect(AccessControl.can(StaffRole.fieldOfficer, Permission.mapInventory), isFalse);
      expect(AccessControl.can(StaffRole.fieldOfficer, Permission.manageStaff), isFalse);
    });
    test('no session is refused as not signed in', () {
      expect(() => AccessControl.require(null, Permission.viewOperations),
          throwsA(isA<NotSignedInException>()));
    });
    test('wrong role is refused', () {
      expect(() => AccessControl.require(officer, Permission.manageStaff),
          throwsA(isA<PermissionDeniedException>()));
    });
    test('deactivated account is refused even with the right role', () {
      final off = sess(StaffRole.superAdmin, active: false);
      expect(() => AccessControl.require(off, Permission.viewOperations),
          throwsA(isA<PermissionDeniedException>()));
    });
    test('allowed action returns the account', () {
      expect(AccessControl.require(admin, Permission.manageStaff).id, 'admin');
    });
  });

  group('TP16 Staff accounts', () {
    late World w;
    late StaffSession root;
    setUp(() async {
      w = World();
      await w.staffTable.put('root', StaffAccount(id: 'root', fullName: 'Root', username: 'root', role: StaffRole.superAdmin));
      await w.pointTable.put('rp1', ResourcePoint(id: 'rp1', name: 'Depot', location: GeoPoint(2.5, 102.8), district: kDistrict));
      root = await w.staff.sessionFor('root');
    });
    // Field officers get resource point rp1 unless the test says otherwise.
    Future<StaffAccount> make(String id, StaffRole role,
            {String? user, String? point, String? district, String? phone, StaffSession? as}) =>
        w.staff.create(as ?? root, authUserId: id, fullName: 'Name $id', username: user ?? 'user.$id',
            role: role, phone: phone, assignedDistrict: district,
            assignedResourcePointId: point ?? (role == StaffRole.fieldOfficer ? 'rp1' : null));

    test('login: staff gets a session, others are refused', () async {
      expect(root.account.role, StaffRole.superAdmin);
      await expectLater(w.staff.sessionFor('stranger'), throwsA(isA<PermissionDeniedException>()));
    });
    test('create cleans the username and phone', () async {
      final a = await make('u1', StaffRole.fieldOfficer, user: '  Ali.Bakar ', phone: '+60 12-345 6789');
      expect(a.username, 'ali.bakar');
      expect(a.phone, '+60123456789');
      expect(a.active, isTrue);
    });
    test('only Super Admin can create or list', () async {
      await expectLater(make('u1', StaffRole.fieldOfficer, as: coordinator), throwsA(isA<PermissionDeniedException>()));
      await expectLater(w.staff.list(officer), throwsA(isA<PermissionDeniedException>()));
      await expectLater(w.staff.list(null), throwsA(isA<NotSignedInException>()));
      expect(await w.staff.list(root), hasLength(1));
    });
    test('bad input is refused', () async {
      await expectLater(make('u1', StaffRole.fieldOfficer, user: 'ab'), throwsA(isA<ValidationException>()));
      await expectLater(make('u1', StaffRole.fieldOfficer, user: 'has space'), throwsA(isA<ValidationException>()));
      await expectLater(make('u1', StaffRole.fieldOfficer, phone: '12ab'), throwsA(isA<ValidationException>()));
      await expectLater(
          w.staff.create(root, authUserId: 'u1', fullName: '  ', username: 'okname', role: StaffRole.fieldOfficer),
          throwsA(isA<ValidationException>()));
      expect(await w.staff.list(root), hasLength(1));
    });
    test('duplicate username or id is refused', () async {
      await make('u1', StaffRole.fieldOfficer, user: 'ali');
      await expectLater(make('u2', StaffRole.fieldOfficer, user: 'ALI'), throwsA(isA<ConflictException>()));
      await expectLater(make('u1', StaffRole.fieldOfficer, user: 'other'), throwsA(isA<ConflictException>()));
    });
    test('coordinator needs a known district', () async {
      await expectLater(make('u1', StaffRole.coordinator), throwsA(isA<ValidationException>()));
      await expectLater(make('u1', StaffRole.coordinator, district: 'Atlantis'), throwsA(isA<ValidationException>()));
      expect((await make('u1', StaffRole.coordinator, district: ' kuala  selangor ')).assignedDistrict,
          'KUALA SELANGOR');
    });
    test('field officer needs an existing resource point', () async {
      await expectLater(
          w.staff.create(root, authUserId: 'u1', fullName: 'N', username: 'nopoint', role: StaffRole.fieldOfficer),
          throwsA(isA<ValidationException>()));
      await expectLater(make('u1', StaffRole.fieldOfficer, point: 'nope'), throwsA(isA<NotFoundException>()));
      expect((await make('u1', StaffRole.fieldOfficer)).assignedResourcePointId, 'rp1');
    });
    test("a field officer's session knows their resource point's district", () async {
      await make('u1', StaffRole.fieldOfficer);
      expect((await w.staff.sessionFor('u1')).district, kDistrict);
      await make('u2', StaffRole.coordinator, district: kOtherDistrict);
      expect((await w.staff.sessionFor('u2')).district, kOtherDistrict);
      expect(root.district, isNull);
    });
    test('assign changes the area; the role rules still apply', () async {
      await make('u1', StaffRole.coordinator, district: kDistrict);
      expect((await w.staff.assign(root, 'u1', district: kOtherDistrict)).assignedDistrict, kOtherDistrict);
      await expectLater(w.staff.assign(root, 'u1'), throwsA(isA<ValidationException>()));
      await expectLater(w.staff.assign(coordinator, 'u1', district: kDistrict),
          throwsA(isA<PermissionDeniedException>()));
    });
    test('deactivated staff cannot log in again', () async {
      await make('u1', StaffRole.fieldOfficer);
      await w.staff.setActive(root, 'u1', false);
      await expectLater(w.staff.sessionFor('u1'), throwsA(isA<PermissionDeniedException>()));
      await w.staff.setActive(root, 'u1', true);
      expect((await w.staff.sessionFor('u1')).account.active, isTrue);
    });
    test('cannot deactivate yourself', () async {
      await make('u2', StaffRole.superAdmin);
      await expectLater(w.staff.setActive(root, 'root', false), throwsA(isA<ConflictException>()));
    });
    test('the last active Super Admin cannot be removed or demoted', () async {
      await expectLater(w.staff.changeRole(root, 'root', StaffRole.fieldOfficer), throwsA(isA<ConflictException>()));
      await make('u2', StaffRole.superAdmin);
      final second = await w.staff.sessionFor('u2');
      await w.staff.setActive(second, 'root', false); // allowed: u2 remains
      await expectLater(w.staff.changeRole(second, 'u2', StaffRole.fieldOfficer), throwsA(isA<ConflictException>()));
    });
    test('change role, and unknown id', () async {
      await make('u1', StaffRole.fieldOfficer);
      expect((await w.staff.changeRole(root, 'u1', StaffRole.superAdmin)).role, StaffRole.superAdmin);
      // A coordinator needs a district, which u1 does not have.
      await expectLater(w.staff.changeRole(root, 'u1', StaffRole.coordinator), throwsA(isA<ValidationException>()));
      await expectLater(w.staff.changeRole(root, 'zzz', StaffRole.fieldOfficer), throwsA(isA<NotFoundException>()));
    });
  });
}
