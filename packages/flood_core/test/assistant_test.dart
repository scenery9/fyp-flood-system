import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';
import 'helpers.dart';

void main() {
  late World w;
  setUp(() async {
    w = World();
    await w.evacuation.add(admin, name: 'Dewan Segamat', location: GeoPoint(2.51, 102.81), capacity: 100);
    await w.evacuation.add(admin, name: 'SK Kajang', location: GeoPoint(2.99, 101.79), capacity: 100);
  });
  Future<AssistantAnswer> ask(String q, {GeoPoint? at}) => w.assistant.ask(q, userLocation: at);

  group('TP29 Flood Assistant', () {
    test('emergency words always win', () async {
      final a = await ask('Tolong! Air naik di Kajang, where is the shelter?');
      expect(a.intent, AssistantIntent.emergency);
      expect(a.text, contains('999'));
    });
    test('nearest relief centre with location', () async {
      final a = await ask('Where is the nearest shelter?', at: GeoPoint(2.99, 101.78));
      expect(a.intent, AssistantIntent.evacuation);
      expect(a.text, contains('SK Kajang'));
      expect(a.sources, isNotEmpty);
    });
    test('relief centres without location lists open ones', () async {
      final a = await ask('pusat pemindahan?');
      expect(a.text, contains('Dewan Segamat'));
      expect(a.text, contains('Turn on location'));
    });
    test('no open centre', () async {
      await w.evacuation.setOpen(admin, 'evac-1', false);
      await w.evacuation.setOpen(admin, 'evac-2', false);
      expect((await ask('shelter', at: GeoPoint(2.99, 101.78))).text, contains('No relief centre'));
      expect((await ask('shelter')).text, contains('No relief centre'));
    });
    test('station status by name, any letter case', () async {
      final a = await ask('How is KAJANG now?');
      expect(a.intent, AssistantIntent.stationStatus);
      expect(a.text, contains('Sg. Langat di Kajang: Normal'));
      expect(a.sources.single, contains('updated 5 min ago'));
    });
    test('district question answers with the riskiest station there', () async {
      final a = await ask('status segamat');
      expect(a.text, contains('Sg. Muar di Kg. Awat: Danger'));
    });
    test('old data and offline sensors are said plainly', () async {
      expect((await ask('rantau panjang')).text, contains('(old data)'));
      expect((await ask('batu hampar')).text, contains('status unknown'));
    });
    test('what to do uses the station level and cites both sources', () async {
      final a = await ask('What should I do, I live near Buloh Kasap');
      expect(a.intent, AssistantIntent.whatToDo);
      expect(a.text, contains('At Alert level'));
      expect(a.sources, hasLength(2));
    });
    test('what to do with a level word, and with nothing else', () async {
      expect((await ask('apa perlu buat masa bahaya')).text, contains('At Danger level'));
      expect((await ask('how to prepare')).text, contains('At Alert level'));
    });
    test('current warnings', () async {
      final a = await ask('Which area is high risk?');
      expect(a.intent, AssistantIntent.warnings);
      expect(a.text, contains('Sg. Muar di Kg. Awat: Danger'));
      expect(a.text.contains('Rantau Panjang'), isFalse); // stale never listed
      expect(a.sources, hasLength(3));
    });
    test('no warnings', () async {
      final calm = World(repo: FakeRepository([st('A', name: 'Sg. Tenang')], [rd('A', river: 11)]));
      expect((await calm.assistant.ask('any amaran?')).text, contains('No station'));
    });
    test('how to report damage', () async {
      expect((await ask('macam mana nak lapor kerosakan')).intent, AssistantIntent.reportDamage);
    });
    test('unknown, empty and very long questions do not crash', () async {
      expect((await ask('tell me a joke')).intent, AssistantIntent.unknown);
      expect((await ask('   ')).intent, AssistantIntent.unknown);
      expect((await ask('x' * 5000)).intent, AssistantIntent.unknown);
      expect((await ask('tell me a joke')).sources, isEmpty);
    });
  });
}
