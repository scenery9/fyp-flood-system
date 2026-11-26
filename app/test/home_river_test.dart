// TP99: a saved rain gauge (like Melaka's Kg. Sg. Putat RF) shows the nearest
// river gauge's reading on Home, and its AI forecast; the card opens details.
// Sample data; nothing is sent anywhere.
import 'package:flood_app/screens/home/home_screen.dart';
import 'package:flood_app/screens/home/station_detail_screen.dart';
import 'package:flood_core/flood_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers.dart';

/// The sample stations, plus Kg. Sg. Putat: a rain gauge and, at the same
/// place, a river gauge at Warning; and Stor Bukit Baru, a rain gauge ~4.8 km away.
class PutatRepository implements StationRepository {
  final _sample = SampleStationRepository();
  static final _putat = GeoPoint(2.25697, 102.272);

  @override
  Future<List<Station>> getStations() async => [
        ...await _sample.getStations(),
        Station(id: '0290491RF', name: 'Kg. Sg. Putat', district: 'MELAKA TENGAH', state: 'Melaka', location: _putat),
        Station(id: '0290491WL', name: 'Sg. Putat di Kg. Sg. Putat', district: 'MELAKA TENGAH', state: 'Melaka',
            location: _putat, thresholds: Thresholds(normal: 1.0, alert: 3.0, warning: 4.0, danger: 5.0)),
        Station(id: '0290361RF', name: 'Stor Bukit Baru', district: 'MELAKA TENGAH', state: 'Melaka',
            location: GeoPoint(2.21367, 102.27)),
      ];

  @override
  Future<Map<String, StationReading>> getLatestReadings() async {
    final now = DateTime.now().subtract(const Duration(minutes: 10));
    return {
      ...await _sample.getLatestReadings(),
      '0290491RF': StationReading.fromRaw(stationId: '0290491RF', time: now, rainfall: 0.5),
      '0290491WL': StationReading.fromRaw(stationId: '0290491WL', time: now, riverLevel: 4.2),
      '0290361RF': StationReading.fromRaw(stationId: '0290361RF', time: now, rainfall: 0.0),
    };
  }
}

void main() {
  Finder inCard(String text) => find.descendant(of: find.byType(AreaCard), matching: find.text(text));
  // The name has its distance beside it: "Kg. Sg. Putat (40.1 km)".
  Finder nameInCard(String name) => find.descendant(
      of: find.byType(AreaCard), matching: find.byWidgetPredicate((w) => w is Text && (w.data ?? '').startsWith('$name (') && (w.data ?? '').endsWith(' km)')));

  group('TP99 A saved rain gauge shows the nearest river', () {
    testWidgets('Kg. Sg. Putat RF shows the river gauge at the same place', (tester) async {
      await TestApp(followed: const ['0290491RF'], repository: PutatRepository()).start(tester);
      expect(nameInCard('Kg. Sg. Putat'), findsOneWidget); // still the saved area's name
      expect(inCard('Warning'), findsOneWidget);
      expect(inCard('4.20 m'), findsOneWidget);
      expect(inCard('River gauge 0.0 km: Sg. Putat di Kg. Sg. Putat'), findsOneWidget);
      expect(inCard('No recent data'), findsNothing);
      expect(inCard('Rain gauge only, no river reading'), findsNothing);
    });

    testWidgets('Stor Bukit Baru RF shows the nearest river gauge, with its distance', (tester) async {
      final app = TestApp(followed: const ['0290361RF'], repository: PutatRepository());
      await app.start(tester);
      expect(nameInCard('Stor Bukit Baru'), findsOneWidget);
      expect(inCard('4.20 m'), findsOneWidget);
      expect(inCard('River gauge 4.8 km: Sg. Putat di Kg. Sg. Putat'), findsOneWidget);
      // the checklist and alerts follow the river shown, not "unknown"
      expect(app.controller.checklistLevel, RiskLevel.warning);
      expect(app.controller.alerts.now.any((a) => a.status.station.id == '0290491WL'), isTrue);
      // the AI forecast card is about that river
      expect(find.textContaining('AI forecast · Kg. Sg. Putat'), findsOneWidget);
    });

  });

  group('TP100 Order of the saved areas', () {
    List<String> order(TestApp app) => [for (final a in app.controller.areas) a.station.id];

    testWidgets('the area nearest the phone is shown first', (tester) async {
      // saved far one first; the phone is near Segamat (Kg. Awat ~1 km, Kajang ~200 km)
      final app = TestApp(followed: const ['SGR-KAJANG', 'JHR-AWAT']);
      await app.start(tester);
      expect(order(app), ['JHR-AWAT', 'SGR-KAJANG']);
      expect(nameInCard('Sg. Muar di Kg. Awat'), findsOneWidget);
    });

    testWidgets('the user can arrange them; that order is kept, and can be undone', (tester) async {
      final app = TestApp(followed: const ['SGR-KAJANG', 'JHR-AWAT', 'JHR-BULOH']);
      await app.start(tester);
      expect(order(app), ['JHR-AWAT', 'JHR-BULOH', 'SGR-KAJANG']);
      await tapIt(tester, find.byKey(const ValueKey('change-area')));
      expect(find.textContaining('nearest to you first'), findsOneWidget);
      // drag Kajang's handle from the bottom row to the top, like moving a card
      final handle = find.byKey(const ValueKey('drag-SGR-KAJANG'));
      await reveal(tester, handle);
      final g = await tester.startGesture(tester.getCenter(handle));
      for (var k = 0; k < 40; k++) {
        await g.moveBy(const Offset(0, -10));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pumpAndSettle();
      expect(order(app), ['SGR-KAJANG', 'JHR-AWAT', 'JHR-BULOH']);
      expect(app.controller.areasArranged, isTrue);
      // kept after a refresh, and saved for next time
      await app.controller.refresh();
      expect(order(app), ['SGR-KAJANG', 'JHR-AWAT', 'JHR-BULOH']);
      expect(await app.followedStore.load(), ['SGR-KAJANG', 'JHR-AWAT', 'JHR-BULOH']);
      // dropping between two rows works too (and the arrow-free path in the controller)
      await app.controller.reorderArea(0, 1);
      expect(order(app), ['JHR-AWAT', 'SGR-KAJANG', 'JHR-BULOH']);
      await tester.pumpAndSettle();

      await tapIt(tester, find.byKey(const ValueKey('sort-nearest')));
      expect(order(app), ['JHR-AWAT', 'JHR-BULOH', 'SGR-KAJANG']);
      await app.controller.refresh();
      expect(order(app), ['JHR-AWAT', 'JHR-BULOH', 'SGR-KAJANG']);
    });
  });

  group('TP99 The area card opens the station details', () {
    testWidgets('tapping the card opens the details of the river shown', (tester) async {
      await TestApp(followed: const ['0290491RF'], repository: PutatRepository()).start(tester);
      await tapIt(tester, find.byKey(const ValueKey('area-card-0290491RF')));
      final detail = tester.widget<StationDetailScreen>(find.byType(StationDetailScreen));
      expect(detail.stationId, '0290491WL');
    });

    testWidgets('a river station opens its own details; "Change area" still works', (tester) async {
      await TestApp(followed: const ['JHR-AWAT']).start(tester);
      expect(find.descendant(of: find.byType(AreaCard), matching: find.byIcon(Icons.chevron_right)), findsNothing); // whole card is the link
      await tapIt(tester, find.byKey(const ValueKey('area-card-JHR-AWAT')));
      expect(tester.widget<StationDetailScreen>(find.byType(StationDetailScreen)).stationId, 'JHR-AWAT');
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tapIt(tester, find.byKey(const ValueKey('change-area')));
      expect(find.byType(StationDetailScreen), findsNothing);
      expect(find.text('Saved areas'), findsOneWidget);
    });
  });
}
