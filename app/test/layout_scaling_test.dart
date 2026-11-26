// The redesigned Home saved-area card and Centres station cards at the largest
// text size (1.3x), in high contrast, in all three languages. Any overflow
// (clipped text) fails the test. Sample data; nothing is sent anywhere.
import 'package:flood_app/app/app_controller.dart';
import 'package:flood_app/screens/centres/centres_screen.dart' show StationTelemetryCard;
import 'package:flood_app/screens/home/home_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  const layers = {
    'en': ['River', 'Rain'],
    'ms': ['Sungai', 'Hujan'],
    'zh': ['河流', '降雨'],
  };
  for (final lang in layers.keys) {
    testWidgets('large text, high contrast, $lang: Home and Centres cards fit', (tester) async {
      // A stale area, a rain-only area and a river at Danger.
      final app = TestApp(
        followed: const ['SGR-RANTAU', 'MLK-DURIAN', 'JHR-AWAT'],
        settings: {'language': lang, 'textSize': 'large', 'highContrast': 'true'},
      );
      await app.start(tester);
      for (var i = 0; i < app.controller.areas.length; i++) {
        app.controller.selectArea(i);
        await tester.pumpAndSettle();
        expect(find.byType(AreaCard), findsOneWidget);
        expect(tester.takeException(), isNull);
      }

      app.controller.selectTab(AppTab.centres);
      await tester.pumpAndSettle();
      for (final layer in layers[lang]!) {
        await tapIt(tester, find.text(layer));
        expect(find.byType(StationTelemetryCard), findsWidgets);
        await reveal(tester, find.byType(StationTelemetryCard).first);
        expect(tester.takeException(), isNull);
      }
    });
  }
}
