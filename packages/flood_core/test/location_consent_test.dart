// TP87: when to ask for location and remembering the answers.
import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';

void main() {
  group('TP87 Location choice', () {
    LocationStart start(LocationChoice c, bool allowed) => LocationConsentService.atLaunch(c, allowed: allowed);

    test('first launch, not allowed yet: explain first; already allowed: just use it', () {
      expect(start(const LocationChoice(), false), LocationStart.explainFirst);
      expect(start(const LocationChoice(), true), LocationStart.useGps);
    });

    test('agreed before but the phone no longer allows it ("Only this time"): phone pop-up only', () {
      expect(start(const LocationChoice(automatic: true), false), LocationStart.askPhone);
      expect(start(const LocationChoice(automatic: true), true), LocationStart.useGps);
    });

    test('switched off in More: never used or asked, even if the phone allows it', () {
      expect(start(const LocationChoice(automatic: false), true), LocationStart.dontUse);
      expect(start(const LocationChoice(automatic: false), false), LocationStart.dontUse);
    });

    test('"Don\'t ask again" or blocked on the phone: not asked', () {
      expect(start(const LocationChoice(dontAsk: true), false), LocationStart.dontUse);
      expect(start(const LocationChoice(blocked: true), false), LocationStart.dontUse);
      expect(start(const LocationChoice(dontAsk: true), true), LocationStart.useGps, reason: 'allowed later in settings');
    });

    test('answers are remembered; other flags in the same store are kept', () async {
      final store = InMemorySettingsStore({'pushAsked': 'true'});
      final s = LocationConsentService(store);
      await s.notNow(dontAskAgain: false);
      expect((await s.load()).dontAsk, isFalse, reason: 'asked again next launch');
      await s.notNow(dontAskAgain: true);
      expect((await s.load()).dontAsk, isTrue);
      await s.phoneAnswered(allowed: false, blocked: true);
      expect((await s.load()).blocked, isTrue);
      await s.phoneAnswered(allowed: true, blocked: false);
      final c = await s.load();
      expect(c.automatic, isTrue);
      expect(c.dontAsk, isFalse);
      expect(c.blocked, isFalse);
      await s.setAutomatic(false);
      expect((await s.load()).automatic, isFalse);
      await s.setAutomatic(true);
      expect((await s.load()).automatic, isTrue);
      expect(await store.load(), containsPair('pushAsked', 'true'));
    });

    test('a refused pop-up (not blocked) changes nothing, so the explanation comes back', () async {
      final s = LocationConsentService(InMemorySettingsStore());
      await s.phoneAnswered(allowed: false, blocked: false);
      expect(start(await s.load(), false), LocationStart.explainFirst);
    });
  });
}
