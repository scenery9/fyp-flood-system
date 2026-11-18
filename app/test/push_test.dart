// TP72-TP73: phone notifications (push alerts) and river-level alerts.
// The alert server is a fake; nothing is sent anywhere.
import 'package:flood_app/app/app_controller.dart';
import 'package:flood_app/app/platform.dart';
import 'package:flood_app/app/sample_data.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers.dart';

const buloh = 'Sg. Muar di Buloh Kasap';

void main() {
  group('TP72 Phone notifications', () {
    testWidgets('a build without Supabase/Firebase says so and offers no button', (tester) async {
      final app = TestApp();
      await app.start(tester);
      await openTab(tester, 'More');
      await tapIt(tester, find.text('Notify me from'));
      expect(find.textContaining('not set up in this version'), findsOneWidget);
      expect(find.byKey(const ValueKey('push-on')), findsNothing);
      expect(app.controller.pushStatus, PushStatus.notSetUp);
    });

    testWidgets('turning on asks the phone, then sends saved areas at the chosen level', (tester) async {
      final server = FakePushServer();
      final tokens = FakePushTokens();
      final app = TestApp(followed: const ['JHR-AWAT', 'JHR-BULOH'], pushTokens: tokens, push: server.service());
      await app.start(tester);
      expect(app.controller.pushStatus, PushStatus.needsPermission);
      expect(server.calls, isEmpty, reason: 'nothing is sent before the user allows notifications');

      await openTab(tester, 'More');
      await tapIt(tester, find.text('Notify me from'));
      await tapIt(tester, find.byKey(const ValueKey('push-on')));
      expect(tokens.asked, 1);
      expect(app.controller.pushStatus, PushStatus.on);
      expect(find.textContaining('even when the app is closed'), findsOneWidget);
      expect(server.calls.first.$1, 'register_device');
      expect(server.calls.first.$2['p_token'], 'fcm-test-token-0123456789');
      // Warning by default; the nearest station (Kg. Awat) is already a saved area.
      expect(server.lastRules, [
        {'station_code': 'JHR-AWAT', 'kind': 'risk', 'min_level': 'warning'},
        {'station_code': 'JHR-BULOH', 'kind': 'risk', 'min_level': 'warning'},
      ]);

      await tapIt(tester, find.byKey(const ValueKey('notify-danger')));
      await tester.pumpAndSettle();
      expect(server.lastRules.first, {'station_code': 'JHR-AWAT', 'kind': 'risk', 'min_level': 'danger'});
    });

    testWidgets('saying no shows how to turn it on later', (tester) async {
      final tokens = FakePushTokens(answer: PushPermission.denied);
      final app = TestApp(pushTokens: tokens, push: FakePushServer().service());
      await app.start(tester);
      await openTab(tester, 'More');
      await tapIt(tester, find.text('Notify me from'));
      await tapIt(tester, find.byKey(const ValueKey('push-on')));
      expect(app.controller.pushStatus, PushStatus.blocked);
      expect(find.textContaining('phone settings'), findsOneWidget);
    });

    testWidgets('server not reachable: the choice is kept and Try again works', (tester) async {
      final server = FakePushServer()..down = true;
      final app = TestApp(pushTokens: FakePushTokens(state: PushPermission.granted), push: server.service());
      await app.start(tester);
      await openTab(tester, 'More');
      await tapIt(tester, find.text('Notify me from'));
      expect(app.controller.pushStatus, PushStatus.failed);
      server.down = false;
      await tapIt(tester, find.byKey(const ValueKey('push-on')));
      expect(app.controller.pushStatus, PushStatus.on);
    });
  });

  group('TP73 River-level alert', () {
    testWidgets('pick a level (no typing), change it, remove it', (tester) async {
      final server = FakePushServer();
      final app = TestApp(
          followed: const ['JHR-AWAT'],
          pushTokens: FakePushTokens(state: PushPermission.granted),
          push: server.service());
      await app.start(tester);
      await tapIt(tester, find.text(buloh));
      await tapIt(tester, find.byKey(const ValueKey('height-alert')));
      expect(find.text('From 8.20 m · suggested'), findsOneWidget);
      expect(find.byKey(const ValueKey('height-field')), findsNothing, reason: 'nothing to type');
      await tapIt(tester, find.byKey(const ValueKey('level-warning')));
      expect(app.controller.heights, {'JHR-BULOH': 8.2});
      expect(find.text('River-level alert: Warning (8.20 m)'), findsOneWidget);
      await waitForSnackBar(tester);
      expect(server.lastRules.last, {'station_code': 'JHR-BULOH', 'kind': 'level', 'level_m': 8.2});

      await tapIt(tester, find.byKey(const ValueKey('height-alert')));
      await tapIt(tester, find.byKey(const ValueKey('level-danger')));
      expect(app.controller.heights, {'JHR-BULOH': 8.84});
      await waitForSnackBar(tester);

      await tapIt(tester, find.byKey(const ValueKey('height-alert')));
      await tapIt(tester, find.byKey(const ValueKey('height-remove')));
      expect(app.controller.heights, isEmpty);
      expect(await app.heightStore.load(), isEmpty);
      expect(find.text('Alert me at a river level'), findsOneWidget);
      await waitForSnackBar(tester);
    });
  });

  group('TP74 Alerts on without setup', () {
    testWidgets('first launch asks for notifications once and sends saved areas plus the nearest station', (tester) async {
      final server = FakePushServer();
      final tokens = FakePushTokens();
      final app = TestApp(followed: const ['JHR-BULOH'], pushTokens: tokens, push: server.service(), pushAskedBefore: false);
      await app.start(tester);
      expect(tokens.asked, 1);
      expect(app.controller.pushStatus, PushStatus.on);
      expect(await app.flagsStore.load(), containsPair('pushAsked', 'true'));
      expect(server.lastRules, [
        {'station_code': 'JHR-BULOH', 'kind': 'risk', 'min_level': 'warning'},
        {'station_code': 'JHR-AWAT', 'kind': 'risk', 'min_level': 'warning'}, // nearest to the user
      ]);
    });

    testWidgets('location refused: the nearest station is not guessed from the sample point', (tester) async {
      final server = FakePushServer();
      final app = TestApp(
          followed: const ['JHR-BULOH'],
          pushTokens: FakePushTokens(state: PushPermission.granted),
          push: server.service(),
          location: LocationFix(SampleData.userLocation, issue: LocationIssue.denied));
      await app.start(tester);
      expect(server.lastRules, [
        {'station_code': 'JHR-BULOH', 'kind': 'risk', 'min_level': 'warning'},
      ]);
    });
  });
}
