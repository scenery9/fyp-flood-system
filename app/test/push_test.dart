// TP72-TP73: phone notifications (push alerts) and river-level alerts.
// The alert server is a fake; nothing is sent anywhere.
import 'package:flood_app/app/app_controller.dart';
import 'package:flood_app/app/platform.dart';
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
      expect(server.lastRules, [
        {'station_code': 'JHR-AWAT', 'kind': 'risk', 'min_level': 'alert'},
        {'station_code': 'JHR-BULOH', 'kind': 'risk', 'min_level': 'alert'},
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
    testWidgets('set, show, change and remove a river height for a station', (tester) async {
      final server = FakePushServer();
      final app = TestApp(
          followed: const ['JHR-AWAT'],
          pushTokens: FakePushTokens(state: PushPermission.granted),
          push: server.service());
      await app.start(tester);
      await tapIt(tester, find.text(buloh));
      await tapIt(tester, find.byKey(const ValueKey('height-alert')));
      await tester.enterText(find.byKey(const ValueKey('height-field')), '8,1');
      await tapIt(tester, find.byKey(const ValueKey('height-save')));
      expect(app.controller.heights, {'JHR-BULOH': 8.1});
      expect(find.text('River-level alert: 8.10 m'), findsOneWidget);
      await waitForSnackBar(tester);
      expect(server.lastRules.last, {'station_code': 'JHR-BULOH', 'kind': 'level', 'level_m': 8.1});

      await tapIt(tester, find.byKey(const ValueKey('height-alert')));
      await tester.enterText(find.byKey(const ValueKey('height-field')), 'abc');
      await tapIt(tester, find.byKey(const ValueKey('height-save')));
      expect(find.textContaining('Enter a river level in metres'), findsOneWidget);
      expect(app.controller.heights, {'JHR-BULOH': 8.1});
      await waitForSnackBar(tester);

      await tapIt(tester, find.byKey(const ValueKey('height-alert')));
      await tapIt(tester, find.byKey(const ValueKey('height-remove')));
      expect(app.controller.heights, isEmpty);
      expect(await app.heightStore.load(), isEmpty);
      expect(find.text('Alert me at a river level'), findsOneWidget);
      await waitForSnackBar(tester);
    });
  });
}
