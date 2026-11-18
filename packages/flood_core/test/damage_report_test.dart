import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';
import 'helpers.dart';

void main() {
  late World w;
  setUp(() => w = World());
  final loc = GeoPoint(2.5, 102.8);
  Future<DamageReport> submit({DateTime? date, double? depth, String desc = '', String by = 'user-1'}) =>
      w.reports.submit(reporterId: by, location: loc, incidentDate: date ?? kNow,
          type: DamageType.road, severity: DamageSeverity.severe, depthM: depth, description: desc);
  Future<void> invalid(Future<DamageReport> f) => expectLater(f, throwsA(isA<ValidationException>()));

  group('TP20 Report damage (public)', () {
    test('a new report is pending', () async {
      final r = await submit(depth: 0.5, desc: '  Road cut off  ');
      expect(r.status, ReportStatus.pending);
      expect(r.description, 'Road cut off');
      expect(r.createdAt, kNow);
      expect(r.reviewedBy, isNull);
    });
    test('depth can be left blank', () async {
      expect((await submit()).depthM, isNull);
    });
    test('date: today and 365 days ago accepted; future and older refused', () async {
      await submit(date: kNow);
      await submit(date: kNow.subtract(const Duration(days: 365)));
      await invalid(submit(date: kNow.add(const Duration(minutes: 1))));
      await invalid(submit(date: kNow.subtract(const Duration(days: 366))));
    });
    test('depth: 0 and 10 accepted; negative, above 10 and NaN refused', () async {
      await submit(depth: 0);
      await submit(depth: 10);
      await invalid(submit(depth: -0.1));
      await invalid(submit(depth: 10.1));
      await invalid(submit(depth: double.nan));
    });
    test('description limit is 500 characters', () async {
      await submit(desc: 'a' * 500);
      await invalid(submit(desc: 'a' * 501));
    });
    test('missing reporter id is refused', () async {
      await invalid(submit(by: ' '));
    });
    test('anti-spam: sixth unreviewed report is refused, freed after review', () async {
      for (var i = 0; i < 5; i++) {
        await submit();
      }
      await expectLater(submit(), throwsA(isA<ConflictException>()));
      await submit(by: 'user-2'); // other people are not affected
      await w.reports.verify(coordinator, 'rep-1');
      await submit(); // slot freed
    });
    test('"My reports" shows only my own', () async {
      await submit(by: 'user-1');
      await submit(by: 'user-2');
      await submit(by: 'user-1');
      expect(await w.reports.mine('user-1'), hasLength(2));
      expect(await w.reports.mine('nobody'), isEmpty);
    });
  });

  group('TP21 Review reports (staff)', () {
    setUp(() async {
      await submit(by: 'a');
      await submit(by: 'b');
      await submit(by: 'c');
    });
    test('public users cannot list or review', () async {
      await expectLater(w.reports.list(null), throwsA(isA<NotSignedInException>()));
      await expectLater(w.reports.verify(null, 'rep-1'), throwsA(isA<NotSignedInException>()));
      await expectLater(w.reports.reject(null, 'rep-1', note: ''), throwsA(isA<NotSignedInException>()));
    });
    test('verify records who and when', () async {
      final r = await w.reports.verify(coordinator, 'rep-1', note: ' Checked on site ');
      expect(r.status, ReportStatus.verified);
      expect(r.reviewedBy, 'coord');
      expect(r.reviewedAt, kNow);
      expect(r.staffNote, 'Checked on site');
    });
    test('reject needs a note, and the reporter can read it', () async {
      await expectLater(w.reports.reject(coordinator, 'rep-2', note: '  '), throwsA(isA<ValidationException>()));
      await w.reports.reject(coordinator, 'rep-2', note: 'Photo unclear');
      final mine = await w.reports.mine('b');
      expect(mine.single.status, ReportStatus.rejected);
      expect(mine.single.staffNote, 'Photo unclear');
    });
    test('duplicate must point to another valid report', () async {
      await expectLater(w.reports.markDuplicate(coordinator, 'rep-1', ofId: 'rep-1'), throwsA(isA<ValidationException>()));
      await expectLater(w.reports.markDuplicate(coordinator, 'rep-1', ofId: 'nope'), throwsA(isA<NotFoundException>()));
      await w.reports.reject(coordinator, 'rep-3', note: 'no');
      await expectLater(w.reports.markDuplicate(coordinator, 'rep-1', ofId: 'rep-3'), throwsA(isA<ConflictException>()));
      final d = await w.reports.markDuplicate(coordinator, 'rep-1', ofId: 'rep-2');
      expect(d.status, ReportStatus.duplicate);
      expect(d.duplicateOfId, 'rep-2');
    });
    test('a reviewed report cannot be reviewed again', () async {
      await w.reports.verify(coordinator, 'rep-1');
      await expectLater(w.reports.reject(admin, 'rep-1', note: 'x'), throwsA(isA<ConflictException>()));
      await expectLater(w.reports.verify(admin, 'rep-1'), throwsA(isA<ConflictException>()));
      expect((await w.reports.mine('a')).single.status, ReportStatus.verified);
    });
    test('unknown report id', () async {
      await expectLater(w.reports.verify(coordinator, 'nope'), throwsA(isA<NotFoundException>()));
    });
    test('tabs and counts', () async {
      await w.reports.verify(coordinator, 'rep-1');
      await w.reports.reject(coordinator, 'rep-2', note: 'no');
      expect(await w.reports.list(officer), hasLength(3));
      expect([for (final r in await w.reports.list(officer, status: ReportStatus.pending)) r.id], ['rep-3']);
      expect(await w.reports.list(officer, status: ReportStatus.duplicate), isEmpty);
      final c = await w.reports.counts(officer);
      expect(c[ReportStatus.pending], 1);
      expect(c[ReportStatus.verified], 1);
      expect(c[ReportStatus.rejected], 1);
      expect(c[ReportStatus.duplicate], 0);
    });
    test('storage failure is passed on and nothing is half-saved', () async {
      w.reportTable.fail = true;
      await expectLater(w.reports.verify(coordinator, 'rep-1'), throwsA(isA<StateError>()));
      w.reportTable.fail = false;
      expect((await w.reports.counts(officer))[ReportStatus.pending], 3);
    });
  });
}
