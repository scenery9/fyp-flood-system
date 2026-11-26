import 'package:flood_core/flood_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flood_app/widgets/common.dart';

void main() {
  group('TP101 Levels below 0 (tidal gates and coastal stations)', () {
    test('shown as they are, and never as -0.00', () {
      expect(metres(-1.11), '-1.11 m');
      expect(metres(-0.27), '-0.27 m');
      expect(metres(-0.004), '0.00 m');
      expect(metres(0), '0.00 m');
      expect(metres(2.5), '2.50 m');
    });

    test('a negative reading is a real reading, compared with the JPS lines as usual', () {
      final now = DateTime.utc(2026, 11, 20, 3);
      // e.g. Barrage Sungai Melaka D/S: JPS normal level -2.0 m
      final station = Station(id: 'X', name: 'Barrage', district: 'MELAKA TENGAH', state: 'Melaka',
          thresholds: Thresholds(normal: -2.0, alert: 1.0, warning: 1.5, danger: 2.0));
      final r = StationReading.fromRaw(stationId: 'X', time: now, riverLevel: -1.11);
      expect(r.riverLevelM, -1.11);
      final s = const RiskCalculator().assess(station, r, now: now);
      expect(s.level, RiskLevel.normal);
      expect(s.isActionable, isTrue);
      expect(s.percentToTarget, closeTo(29.7, 0.1)); // 0.89 of the 3.0 m from normal to Alert
      expect(StationReading.fromRaw(stationId: 'X', time: now, riverLevel: -9999).riverLevelM, isNull);
    });
  });
}
