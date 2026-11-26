// TP103: when a station has no usable river level, the app says why in plain
// words: not updated by JPS, an invalid JPS reading, no JPS warning levels.
// Sample data; nothing is sent anywhere.
import 'package:flood_app/screens/home/home_screen.dart';
import 'package:flood_app/widgets/common.dart';
import 'package:flood_core/flood_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers.dart';

/// The sample stations, plus one river gauge for each extra case.
class IssueRepository implements StationRepository {
  final _sample = SampleStationRepository();
  static Thresholds get _t => Thresholds(normal: 1.0, alert: 3.0, warning: 4.0, danger: 5.0);
  static final _here = GeoPoint(2.25, 102.27);

  @override
  Future<List<Station>> getStations() async => [
        ...await _sample.getStations(),
        Station(id: 'GLITCH', name: 'Glitch station', district: 'MELAKA TENGAH', state: 'Melaka', location: _here, thresholds: _t),
        // far from every other gauge, so the Home card does not borrow a nearby river instead
        Station(id: 'NOLINES', name: 'No lines station', district: 'MELAKA TENGAH', state: 'Melaka',
            location: GeoPoint(4.6, 103.4)),
        Station(id: 'NEVER', name: 'Never station', district: 'MELAKA TENGAH', state: 'Melaka',
            location: GeoPoint(5.2, 103.1), thresholds: _t),
      ];

  @override
  Future<Map<String, StationReading>> getLatestReadings() async {
    final now = DateTime.now();
    return {
      ...await _sample.getLatestReadings(),
      // last good level 2 hours ago, then JPS showed a 0.00 m glitch
      'GLITCH': StationReading.fromRaw(stationId: 'GLITCH', time: now.subtract(const Duration(hours: 2)),
          riverLevel: 1.4, problem: ReadingProblem.glitch, problemAt: now.subtract(const Duration(minutes: 5))),
      'NOLINES': StationReading.fromRaw(stationId: 'NOLINES', time: now.subtract(const Duration(minutes: 10)), riverLevel: 6.2),
    };
  }
}

void main() {
  Finder inCard(String text) => find.descendant(of: find.byType(AreaCard), matching: find.text(text));
  Finder inCardStarting(String start) => find.descendant(
      of: find.byType(AreaCard), matching: find.byWidgetPredicate((w) => w is Text && (w.data ?? '').startsWith(start)));

  group('TP103 Saying why there is no usable river level', () {
    testWidgets('not updated by JPS: one amber notice, and says since when', (tester) async {
      await TestApp(followed: const ['SGR-RANTAU']).start(tester); // last reading 2 days ago
      expect(inCard('Outdated reading (>3h) — paused for alerts'), findsOneWidget);
      expect(inCard('No recent data'), findsNothing);
      expect(inCard('Normal'), findsNothing); // no level pill on an old reading
      final since = inCardStarting('Updated since ');
      expect(since, findsOneWidget);
      expect(tester.widget<Text>(since).data, endsWith('(2 days ago)'));
      expect(tester.widget<Text>(since).style!.color, kStaleText); // amber when stale
    });

    testWidgets('sensor offline in JPS (-9999)', (tester) async {
      await TestApp(followed: const ['MLK-HAMPAR']).start(tester);
      expect(inCard('Invalid reading'), findsOneWidget);
      expect(inCard('JPS shows the river sensor as offline'), findsOneWidget);
    });

    testWidgets('a 0.00 m glitch: still says the last good reading and when', (tester) async {
      await TestApp(followed: const ['GLITCH'], repository: IssueRepository()).start(tester);
      expect(inCard('Normal'), findsOneWidget); // the last good level is 2 h old: still counts
      expect(inCardStarting('JPS shows 0.00 m, which looks like an error. Last good reading: '), findsOneWidget);
    });

    testWidgets('no JPS warning levels: the level is shown, with the reason there is no risk level', (tester) async {
      await TestApp(followed: const ['NOLINES'], repository: IssueRepository()).start(tester);
      expect(inCard('No JPS levels'), findsOneWidget);
      expect(inCardStarting('JPS has not set warning levels for this station'), findsOneWidget);
    });

    testWidgets('a station never heard from', (tester) async {
      await TestApp(followed: const ['NEVER'], repository: IssueRepository()).start(tester);
      expect(inCard('No data yet'), findsOneWidget);
      expect(inCard('No reading from JPS yet'), findsOneWidget);
    });
  });
}
