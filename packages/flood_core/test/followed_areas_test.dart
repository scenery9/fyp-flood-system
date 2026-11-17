import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';
import 'helpers.dart';

void main() {
  late FakeRepository repo;
  late InMemoryFollowedStore store;
  late FollowedAreasService svc;

  setUp(() {
    repo = FakeRepository([for (final id in ['A', 'B', 'C', 'D', 'E', 'F']) st(id)], []);
    store = InMemoryFollowedStore();
    svc = FollowedAreasService(store: store, repository: repo);
  });

  group('TP6 Followed areas', () {
    test('starts empty', () async {
      expect(await svc.list(), isEmpty);
      expect(await svc.isFollowed('A'), isFalse);
    });
    test('follow adds in order', () async {
      await svc.follow('B');
      await svc.follow('A');
      expect(await svc.list(), ['B', 'A']);
      expect(await svc.isFollowed('A'), isTrue);
    });
    test('following twice does not duplicate', () async {
      await svc.follow('A');
      await svc.follow('A');
      expect(await svc.list(), ['A']);
    });
    test('sixth area is refused and the first five are kept', () async {
      for (final id in ['A', 'B', 'C', 'D', 'E']) {
        await svc.follow(id);
      }
      await expectLater(svc.follow('F'), throwsA(isA<FollowLimitReachedException>()));
      expect(await svc.list(), ['A', 'B', 'C', 'D', 'E']);
    });
    test('at the limit, re-following an existing area is fine', () async {
      for (final id in ['A', 'B', 'C', 'D', 'E']) {
        await svc.follow(id);
      }
      expect(await svc.follow('C'), hasLength(5));
    });
    test('unknown station is refused', () async {
      await expectLater(svc.follow('ZZZ'), throwsA(isA<UnknownStationException>()));
      expect(await svc.list(), isEmpty);
    });
    test('unfollow removes only that area, and frees a slot', () async {
      for (final id in ['A', 'B', 'C', 'D', 'E']) {
        await svc.follow(id);
      }
      await svc.unfollow('C');
      expect(await svc.list(), ['A', 'B', 'D', 'E']);
      await svc.follow('F');
      expect(await svc.list(), ['A', 'B', 'D', 'E', 'F']);
    });
    test('unfollowing something not followed changes nothing', () async {
      await svc.follow('A');
      expect(await svc.unfollow('B'), ['A']);
    });
    test('toggle switches on and off', () async {
      expect(await svc.toggle('A'), isTrue);
      expect(await svc.toggle('A'), isFalse);
      expect(await svc.list(), isEmpty);
    });
    test('saved areas survive an app restart (new service, same store)', () async {
      await svc.follow('A');
      await svc.follow('D');
      final again = FollowedAreasService(store: store, repository: repo);
      expect(await again.list(), ['A', 'D']);
    });
    test('damaged saved data is cleaned (duplicates, blanks, more than 5)', () async {
      final bad = InMemoryFollowedStore(['A', 'A', '', 'B', 'C', 'D', 'E', 'F']);
      final s = FollowedAreasService(store: bad, repository: repo);
      expect(await s.list(), ['A', 'B', 'C', 'D', 'E']);
    });
    test('a failed follow (no internet) leaves saved areas untouched', () async {
      await svc.follow('A');
      repo.fail = true;
      await expectLater(svc.follow('B'), throwsA(isA<StateError>()));
      repo.fail = false;
      expect(await svc.list(), ['A']);
    });
  });
}
