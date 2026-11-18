// TP44 Household profile, TP45 Personalised checklist, TP46 Checklist progress.
import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';

void main() {
  const svc = PreparednessService();
  List<String> ids(RiskLevel l, HouseholdProfile? p) => [for (final i in svc.checklist(l, p)) i.id];

  group('TP44 Household profile', () {
    test('defaults: 1 person, own car, no needs', () {
      const p = HouseholdProfile();
      expect(p.people, 1);
      expect(p.transport, Transport.ownCar);
      expect(p.needsHelpToLeave, isFalse);
    });

    test('save and read back gives the same values', () {
      const p = HouseholdProfile(
          people: 4, olderAdult: true, dailyMedicine: true, pet: true, transport: Transport.lift);
      final back = HouseholdProfile.fromMap(p.toMap());
      expect(back.people, 4);
      expect(back.olderAdult, isTrue);
      expect(back.dailyMedicine, isTrue);
      expect(back.pet, isTrue);
      expect(back.youngChild, isFalse);
      expect(back.transport, Transport.lift);
    });

    test('damaged values fall back to defaults', () {
      final p = HouseholdProfile.fromMap({'people': 'abc', 'transport': 'boat', 'pet': 'yes'});
      expect(p.people, 1);
      expect(p.transport, Transport.ownCar);
      expect(p.pet, isFalse);
    });

    test('people out of range falls back to 1', () {
      expect(HouseholdProfile.fromMap({'people': '0'}).people, 1);
      expect(HouseholdProfile.fromMap({'people': '31'}).people, 1);
      expect(HouseholdProfile.fromMap({'people': '30'}).people, 30);
    });

    test('lift and no transport need help to leave; car and motorcycle do not', () {
      expect(const HouseholdProfile(transport: Transport.lift).needsHelpToLeave, isTrue);
      expect(const HouseholdProfile(transport: Transport.none).needsHelpToLeave, isTrue);
      expect(const HouseholdProfile(transport: Transport.motorcycle).needsHelpToLeave, isFalse);
    });
  });

  group('TP45 Personalised checklist', () {
    test('every level has items for every household', () {
      for (final l in RiskLevel.values) {
        expect(svc.checklist(l, null), isNotEmpty, reason: l.name);
      }
    });

    test('ids are unique and carry their level as prefix', () {
      final all = PreparednessService.allIds;
      const everyone = HouseholdProfile(
          people: 5, olderAdult: true, youngChild: true, mobilityAid: true,
          dailyMedicine: true, pet: true, transport: Transport.none);
      final listed = [for (final l in RiskLevel.values) ...ids(l, everyone)];
      expect(listed.toSet().length, listed.length);
      for (final l in RiskLevel.values) {
        for (final i in svc.checklist(l, everyone)) {
          expect(i.id.startsWith('${l.name}.'), isTrue, reason: i.id);
        }
      }
      expect(all.containsAll(listed), isTrue);
    });

    test('no profile: no personal items and no reasons', () {
      for (final l in RiskLevel.values) {
        expect(svc.checklist(l, null).every((i) => i.reason == null), isTrue);
      }
      expect(ids(RiskLevel.normal, null), isNot(contains('normal.medicine')));
    });

    test('daily medicine adds medicine items with a reason', () {
      const p = HouseholdProfile(dailyMedicine: true);
      final item = svc.checklist(RiskLevel.normal, p).firstWhere((i) => i.id == 'normal.medicine');
      expect(item.reason, 'Because someone needs daily medicine');
      expect(ids(RiskLevel.alert, p), contains('alert.medicine'));
    });

    test('no own transport: driver items and leave early; no "move vehicle"', () {
      const p = HouseholdProfile(transport: Transport.none);
      expect(ids(RiskLevel.normal, p), contains('normal.driver'));
      expect(ids(RiskLevel.alert, p), contains('alert.driver'));
      expect(ids(RiskLevel.warning, p), contains('warning.leave'));
      expect(ids(RiskLevel.warning, p), isNot(contains('warning.vehicle')));
    });

    test('own car: move vehicle, no driver items', () {
      const p = HouseholdProfile(transport: Transport.ownCar);
      expect(ids(RiskLevel.warning, p), contains('warning.vehicle'));
      expect(ids(RiskLevel.normal, p), isNot(contains('normal.driver')));
      expect(ids(RiskLevel.warning, p), isNot(contains('warning.leave')));
    });

    test('older adult, child, mobility aid and pet each add their items', () {
      expect(ids(RiskLevel.alert, const HouseholdProfile(olderAdult: true)), contains('alert.aids'));
      expect(ids(RiskLevel.normal, const HouseholdProfile(youngChild: true)), contains('normal.baby'));
      expect(ids(RiskLevel.alert, const HouseholdProfile(mobilityAid: true)), contains('alert.mobility'));
      expect(ids(RiskLevel.warning, const HouseholdProfile(pet: true)), contains('warning.pet'));
      expect(ids(RiskLevel.danger, const HouseholdProfile(mobilityAid: true)), contains('danger.help'));
    });

    test('Malay and Chinese text are given for every item and reason', () {
      const everyone = HouseholdProfile(
          olderAdult: true, youngChild: true, mobilityAid: true, dailyMedicine: true, pet: true, transport: Transport.none);
      for (final l in RiskLevel.values) {
        final en = svc.checklist(l, everyone);
        final ms = svc.checklist(l, everyone, language: AppLanguage.ms);
        final zh = svc.checklist(l, everyone, language: AppLanguage.zh);
        for (var i = 0; i < en.length; i++) {
          expect(ms[i].title, isNot(en[i].title), reason: en[i].id);
          expect(zh[i].title, isNot(en[i].title), reason: en[i].id);
          expect(zh[i].howTo, isNot(en[i].howTo), reason: en[i].id);
          if (en[i].reason != null) expect(zh[i].reason, isNot(en[i].reason), reason: en[i].id);
        }
      }
      expect(svc.checklist(RiskLevel.danger, null, language: AppLanguage.zh).first.title, '立即前往疏散中心');
    });
  });

  group('TP46 Checklist progress and saving', () {
    late InMemorySettingsStore profileStore;
    late InMemorySettingsStore progressStore;
    late HouseholdService hh;
    setUp(() {
      profileStore = InMemorySettingsStore();
      progressStore = InMemorySettingsStore();
      hh = HouseholdService(profileStore: profileStore, progressStore: progressStore);
    });

    test('no profile before the form is saved', () async {
      expect(await hh.loadProfile(), isNull);
      expect(await hh.setupSkipped(), isFalse);
    });

    test('save then load; survives a restart (new service, same stores)', () async {
      await hh.saveProfile(const HouseholdProfile(people: 3, pet: true));
      final again = HouseholdService(profileStore: profileStore, progressStore: progressStore);
      final p = await again.loadProfile();
      expect(p!.people, 3);
      expect(p.pet, isTrue);
    });

    test('people limits: 0 and 31 refused, 1 and 30 accepted', () async {
      expect(() => hh.saveProfile(const HouseholdProfile(people: 0)), throwsA(isA<ValidationException>()));
      expect(() => hh.saveProfile(const HouseholdProfile(people: 31)), throwsA(isA<ValidationException>()));
      await hh.saveProfile(const HouseholdProfile(people: 1));
      await hh.saveProfile(const HouseholdProfile(people: 30));
      expect((await hh.loadProfile())!.people, 30);
    });

    test('skip: remembered until a profile is saved', () async {
      await hh.skipSetup();
      expect(await hh.setupSkipped(), isTrue);
      await hh.saveProfile(const HouseholdProfile(people: 2));
      expect(await hh.setupSkipped(), isFalse);
      await hh.skipSetup(); // does nothing once saved
      expect(await hh.loadProfile(), isNotNull);
    });

    test('tick, untick, and progress survives a restart', () async {
      await hh.setDone('alert.charge', true);
      await hh.setDone('alert.water', true);
      await hh.setDone('alert.water', false);
      final again = HouseholdService(profileStore: profileStore, progressStore: progressStore);
      expect(await again.doneItems(), {'alert.charge'});
    });

    test('unknown item id refused', () async {
      expect(() => hh.setDone('alert.fly', true), throwsA(isA<ValidationException>()));
    });

    test('damaged or old saved ids are ignored', () async {
      await progressStore.save({'done': 'alert.charge,,nonsense, danger.call'});
      expect(await hh.doneItems(), {'alert.charge', 'danger.call'});
    });

    test('start again clears one level only', () async {
      await hh.setDone('alert.charge', true);
      await hh.setDone('danger.call', true);
      expect(await hh.resetLevel(RiskLevel.alert), {'danger.call'});
    });
  });
}
