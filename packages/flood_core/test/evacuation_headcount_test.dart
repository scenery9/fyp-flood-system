import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';
import 'helpers.dart';

void main() {
  late World w;
  final user = GeoPoint(0, 100);
  setUp(() async {
    w = World();
    await w.evacuation.add(admin, name: 'Far Hall', location: GeoPoint(0, 102), capacity: 100);
    await w.evacuation.add(admin, name: 'Near School', location: GeoPoint(0, 100.1), capacity: 50);
    await w.evacuation.add(admin, name: 'Mid Mosque', location: GeoPoint(0, 101), capacity: 10);
  });
  List<String> names(List<NearbyEvacuation> l) => [for (final n in l) n.point.name];

  group('TP17 Evacuation (public)', () {
    test('nearest first, with distance', () async {
      final n = await w.evacuation.nearest(user);
      expect(names(n), ['Near School', 'Mid Mosque', 'Far Hall']);
      expect(n.first.distanceKm, closeTo(11.12, 0.05));
    });
    test('limit', () async {
      expect(names(await w.evacuation.nearest(user, limit: 1)), ['Near School']);
      expect(await w.evacuation.nearest(user, limit: 0), isEmpty);
    });
    test('closed and full centres are skipped unless asked for', () async {
      await w.evacuation.setOpen(admin, 'evac-2', false); // Near School closed
      await w.evacuation.setOccupancy(admin, 'evac-3', 10); // Mid Mosque full
      expect(names(await w.evacuation.nearest(user)), ['Far Hall']);
      expect(await w.evacuation.nearest(user, includeUnavailable: true), hasLength(3));
    });
    test('no centres at all gives an empty list', () async {
      expect(await World().evacuation.nearest(user), isEmpty);
    });
    test('directions link', () {
      expect(w.evacuation.directionsUrl(GeoPoint(2.5, 102.8)),
          'https://www.google.com/maps/dir/?api=1&destination=2.5,102.8&travelmode=driving');
      expect(w.evacuation.directionsUrl(GeoPoint(2.5, 102.8), from: user), contains('&origin=0.0,100.0&'));
    });
  });

  group('TP18 Evacuation points (staff)', () {
    test('who may add and delete', () async {
      await w.evacuation.add(coordinator, name: 'New', location: user, capacity: 5);
      await expectLater(w.evacuation.add(officer, name: 'X', location: user, capacity: 5),
          throwsA(isA<PermissionDeniedException>()));
      await expectLater(w.evacuation.remove(officer, 'evac-1'), throwsA(isA<PermissionDeniedException>()));
      await expectLater(w.evacuation.add(null, name: 'X', location: user, capacity: 5),
          throwsA(isA<NotSignedInException>()));
      expect(await w.evacuation.listAll(), hasLength(4));
    });
    test('bad input and duplicate names', () async {
      await expectLater(w.evacuation.add(admin, name: ' ', location: user, capacity: 5), throwsA(isA<ValidationException>()));
      await expectLater(w.evacuation.add(admin, name: 'A', location: user, capacity: 0), throwsA(isA<ValidationException>()));
      await expectLater(w.evacuation.add(admin, name: 'far hall', location: user, capacity: 5), throwsA(isA<ConflictException>()));
    });
    test('field officer can update occupancy and open/close', () async {
      final p = await w.evacuation.setOccupancy(officer, 'evac-1', 100);
      expect(p.isFull, isTrue);
      expect((await w.evacuation.setOpen(officer, 'evac-1', false)).isAvailable, isFalse);
    });
    test('occupancy must be within 0 and capacity', () async {
      await expectLater(w.evacuation.setOccupancy(admin, 'evac-3', 11), throwsA(isA<ValidationException>()));
      await expectLater(w.evacuation.setOccupancy(admin, 'evac-3', -1), throwsA(isA<ValidationException>()));
      await expectLater(w.evacuation.setOccupancy(admin, 'nope', 1), throwsA(isA<NotFoundException>()));
    });
    test('delete is refused while people are recorded there', () async {
      await w.evacuation.setOccupancy(admin, 'evac-1', 3);
      await expectLater(w.evacuation.remove(admin, 'evac-1'), throwsA(isA<ConflictException>()));
      await w.evacuation.setOccupancy(admin, 'evac-1', 0);
      await w.evacuation.remove(admin, 'evac-1');
      expect(await w.evacuation.listAll(), hasLength(2));
    });
  });

  group('TP19 Headcount', () {
    test('submit and read back', () async {
      final e = await w.headcount.submit(householdId: 'h1', total: 5, babies: 1, elderly: 2, reducedMobility: 1, evacuationPointId: 'evac-1');
      expect(e.submittedAt, kNow);
      expect((await w.headcount.mine('h1'))!.total, 5);
      expect(await w.headcount.mine('h2'), isNull);
    });
    test('submitting again replaces, never double counts', () async {
      await w.headcount.submit(householdId: 'h1', total: 5);
      await w.headcount.submit(householdId: 'h1', total: 3);
      final s = await w.headcount.summary(admin);
      expect(s.grandTotal.households, 1);
      expect(s.grandTotal.total, 3);
    });
    test('invalid numbers are refused', () async {
      Future<void> bad(Future<HeadcountEntry> f) => expectLater(f, throwsA(isA<ValidationException>()));
      await bad(w.headcount.submit(householdId: 'h', total: 0));
      await bad(w.headcount.submit(householdId: 'h', total: 31));
      await bad(w.headcount.submit(householdId: 'h', total: 2, babies: -1));
      await bad(w.headcount.submit(householdId: 'h', total: 2, babies: 2, elderly: 1));
      await bad(w.headcount.submit(householdId: 'h', total: 2, reducedMobility: 3));
      await bad(w.headcount.submit(householdId: ' ', total: 2));
      expect((await w.headcount.summary(admin)).rows, isEmpty);
    });
    test('boundaries: 1 and 30 people are accepted', () async {
      await w.headcount.submit(householdId: 'a', total: 1, elderly: 1, reducedMobility: 1);
      await w.headcount.submit(householdId: 'b', total: 30);
      expect((await w.headcount.summary(admin)).grandTotal.total, 31);
    });
    test('unknown evacuation point is refused', () async {
      await expectLater(w.headcount.submit(householdId: 'h', total: 2, evacuationPointId: 'nope'),
          throwsA(isA<NotFoundException>()));
    });
    test('summary groups by centre, largest first, with grand total', () async {
      await w.headcount.submit(householdId: 'h1', total: 4, babies: 1, evacuationPointId: 'evac-1');
      await w.headcount.submit(householdId: 'h2', total: 6, elderly: 2, reducedMobility: 1, evacuationPointId: 'evac-2');
      await w.headcount.submit(householdId: 'h3', total: 3, evacuationPointId: 'evac-2');
      await w.headcount.submit(householdId: 'h4', total: 2);
      final s = await w.headcount.summary(officer);
      expect([for (final r in s.rows) r.name], ['Near School', 'Far Hall', 'Not at a centre']);
      expect(s.rows.first.total, 9);
      expect(s.rows.first.households, 2);
      expect(s.grandTotal.total, 15);
      expect(s.grandTotal.babies, 1);
      expect(s.grandTotal.elderly, 2);
      expect(s.grandTotal.reducedMobility, 1);
    });
    test('withdraw removes the household', () async {
      await w.headcount.submit(householdId: 'h1', total: 4);
      await w.headcount.withdraw('h1');
      await w.headcount.withdraw('never-submitted'); // no error
      expect((await w.headcount.summary(admin)).grandTotal.total, 0);
    });
    test('summary is staff only', () async {
      await expectLater(w.headcount.summary(null), throwsA(isA<NotSignedInException>()));
    });
  });
}
