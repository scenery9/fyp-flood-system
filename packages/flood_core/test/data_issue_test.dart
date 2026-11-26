import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';
import 'helpers.dart';

void main() {
  Map<String, dynamic> row({Object? level = 2.5, String? levelAt = '2026-11-17T02:45:00Z', Object? rain,
          String? rainAt, String? problem, String? problemAt}) =>
      {
        'station_code': 'A', 'name': 'A', 'level_m': level, 'level_at': levelAt,
        'hourly_mm': rain, 'rain_at': rainAt, 'wl_problem': problem, 'wl_problem_at': problemAt,
      };

  group('TP102 Why there is no usable river level', () {
    test('each case gets its own reason', () {
      expect(assess(st('A'), null).dataIssue, DataIssue.noReading);
      expect(assess(st('A'), rd('A', river: 11)).dataIssue, DataIssue.none);
      expect(assess(st('A'), rd('A', river: 11, minAgo: 200)).dataIssue, DataIssue.stale);
      expect(assess(st('A', thresholds: false), rd('A', rain: 5)).dataIssue, DataIssue.rainOnly);
      expect(assess(st('A'), rd('A', rain: 5)).dataIssue, DataIssue.noRiverReading);
      expect(assess(st('A', thresholds: false), rd('A', river: 3)).dataIssue, DataIssue.noThresholds);
      final est = StationReading.fromRaw(stationId: 'A', time: kNow, riverLevel: -8888);
      expect(assess(st('A'), est).problem, ReadingProblem.estimated);
    });

    test('a level below 0 is a real reading, not a problem', () {
      final r = StationReading.fromRaw(stationId: 'A', time: kNow, riverLevel: -1.77);
      expect(r.problem, isNull);
      expect(r.riverLevelM, -1.77);
    });

    test('every problem the logger stores is understood; anything else is ignored', () {
      for (final (text, p) in [('offline', ReadingProblem.offline), ('estimated', ReadingProblem.estimated),
        ('no_value', ReadingProblem.noValue), ('old_time', ReadingProblem.oldTime),
        ('bad_time', ReadingProblem.badTime), ('glitch', ReadingProblem.glitch)]) {
        expect(ReadingProblem.parse(text), p);
      }
      expect(ReadingProblem.parse(null), isNull);
      expect(ReadingProblem.parse('something new'), isNull);
    });

    test('a problem seen after the last good level is shown with that level', () {
      final r = LiveStationRepository.readingFromRow(row(problem: 'offline', problemAt: '2026-11-17T03:00:00Z'))!;
      expect(r.problem, ReadingProblem.offline);
      expect(r.riverLevelM, 2.5);
      final s = assess(st('A'), r);
      expect(s.dataIssue, DataIssue.jpsProblem);
      expect(s.level, isNotNull); // the last good level is still fresh, so it still counts
      expect(s.mainCause, startsWith('JPS shows the river sensor as offline; last good reading'));
    });

    test('a problem older than the last good level is ignored (fixed since)', () {
      final r = LiveStationRepository.readingFromRow(row(problem: 'glitch', problemAt: '2026-11-17T02:00:00Z'))!;
      expect(r.problem, isNull);
      expect(assess(st('A'), r).dataIssue, DataIssue.none);
    });

    test('a station that never sent a good level still says what JPS shows', () {
      final r = LiveStationRepository.readingFromRow(
          row(level: null, levelAt: null, problem: 'no_value', problemAt: '2026-11-17T02:50:00Z'))!;
      expect(r.riverLevelM, isNull);
      final s = assess(st('A'), r);
      expect(s.dataIssue, DataIssue.jpsProblem);
      expect(s.isActionable, isFalse);
      expect(s.mainCause, 'JPS shows no river level');
    });

    test('rows from before reading_problems.sql (no problem columns) still work', () {
      final r = LiveStationRepository.readingFromRow({'station_code': 'A', 'level_m': 2.5, 'level_at': '2026-11-17T02:45:00Z'})!;
      expect(r.problem, isNull);
      expect(LiveStationRepository.readingFromRow({'station_code': 'A'}), isNull);
    });
  });
}
