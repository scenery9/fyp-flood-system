import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';
import 'helpers.dart';

void main() {
  const svc = StationListService();
  final user = GeoPoint(0, 100);
  late List<StationStatus> all;
  List<String> ids(List<StationStatus> l) => [for (final s in l) s.station.id];

  setUp(() {
    all = [
      assess(st('NORM', name: 'Sg. Langat di Kajang', district: 'Hulu Langat', state: 'Selangor', loc: GeoPoint(0, 100.1)),
          rd('NORM', river: 11, rain: 0), user: user),
      assess(st('DANG', name: 'Sg. Muar di Kg. Awat', district: 'Segamat', loc: GeoPoint(0, 103)),
          rd('DANG', river: 17, rain: 12), user: user),
      assess(st('WARN', name: 'Sg. Segamat', district: 'Segamat', loc: GeoPoint(0, 102)),
          rd('WARN', river: 15, rain: 40), user: user),
      assess(st('STALE', name: 'Sg. Selangor', district: 'Kuala Selangor', state: 'Selangor', loc: GeoPoint(0, 100.5)),
          rd('STALE', minAgo: 3000, river: 17, rain: 90), user: user),
      assess(st('NOLOC', name: 'Sg. Lenik', district: 'Segamat'), rd('NOLOC', river: 13, rain: 5), user: user),
      assess(st('RAIN', name: 'Stesen Hujan', district: 'Alor Gajah', state: 'Melaka', loc: GeoPoint(0, 101), thresholds: false),
          rd('RAIN', rain: 65), user: user),
    ];
  });

  group('TP7 Search and filter', () {
    test('empty search returns every station', () {
      expect(svc.apply(all), hasLength(6));
      expect(svc.apply(all, query: '   '), hasLength(6));
    });
    test('search ignores upper/lower case and extra spaces', () {
      expect(ids(svc.apply(all, query: '  KAJANG ')), ['NORM']);
    });
    test('search matches district and state too', () {
      expect(svc.apply(all, query: 'segamat'), hasLength(3));
      expect(ids(svc.apply(all, query: 'melaka')), ['RAIN']);
    });
    test('search with no match returns an empty list', () {
      expect(svc.apply(all, query: 'xyz'), isEmpty);
    });
    test('state filter, alone and with search', () {
      expect(svc.apply(all, state: 'Selangor'), hasLength(2));
      expect(svc.apply(all, state: 'selangor'), hasLength(2));
      expect(ids(svc.apply(all, state: 'Selangor', query: 'langat')), ['NORM']);
      expect(svc.apply(all, state: 'Perak'), isEmpty);
    });
    test('state chips are unique and sorted', () {
      expect(svc.availableStates(all), ['Johor', 'Melaka', 'Selangor']);
      expect(svc.availableStates([]), isEmpty);
    });
  });

  group('TP8 Sorting', () {
    test('highest risk first; stale then unknown at the bottom', () {
      expect(ids(svc.apply(all)), ['DANG', 'WARN', 'NOLOC', 'NORM', 'STALE', 'RAIN']);
    });
    test('same level is ordered by percent', () {
      final two = [
        assess(st('LOW'), rd('LOW', river: 12.2)),
        assess(st('HIGH'), rd('HIGH', river: 13.8)),
      ];
      expect(ids(svc.apply(two)), ['HIGH', 'LOW']);
    });
    test('nearest first; unknown distance last', () {
      expect(ids(svc.apply(all, sortBy: SortBy.nearest)),
          ['NORM', 'STALE', 'RAIN', 'WARN', 'DANG', 'NOLOC']);
    });
    test('nearest without user location falls back to risk order', () {
      final noUser = [for (final s in all) assess(s.station, s.reading)];
      expect(ids(svc.apply(noUser, sortBy: SortBy.nearest)), ids(svc.apply(noUser)));
    });
    test('rainfall mode: heaviest rain first, stale last', () {
      expect(ids(svc.apply(all, mode: ListMode.rainfall)),
          ['RAIN', 'WARN', 'DANG', 'NOLOC', 'NORM', 'STALE']);
    });
    test('the original list is never changed', () {
      final before = ids(all);
      svc.apply(all, sortBy: SortBy.nearest, query: 'sg');
      expect(ids(all), before);
    });
  });
}
