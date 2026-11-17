import '../models/station.dart';
import '../models/station_reading.dart';
import '../util/geo.dart';
import 'station_repository.dart';

/// SAMPLE DATA ONLY. Station names are real places, but the thresholds,
/// coordinates and readings are made up for development. Do not present
/// them as JPS values. Readings are generated relative to "now" so the
/// sample always has fresh, stale, offline and rainfall-only cases.
class SampleStationRepository implements StationRepository {
  SampleStationRepository({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;

  static Thresholds _t(double n, double a, double w, double d) =>
      Thresholds(normal: n, alert: a, warning: w, danger: d);

  static final List<Station> _stations = [
    Station(id: 'JHR-AWAT', name: 'Sg. Muar di Kg. Awat', district: 'Segamat', state: 'Johor',
        location: GeoPoint(2.573, 102.818), thresholds: _t(16.50, 18.00, 19.00, 19.95)),
    Station(id: 'JHR-BULOH', name: 'Sg. Muar di Buloh Kasap', district: 'Segamat', state: 'Johor',
        location: GeoPoint(2.553, 102.764), thresholds: _t(6.00, 7.50, 8.20, 8.84)),
    Station(id: 'JHR-SEGKECIL', name: 'Sg. Segamat di Segamat Kecil', district: 'Segamat', state: 'Johor',
        location: GeoPoint(2.515, 102.815), thresholds: _t(5.50, 7.00, 8.00, 9.00)),
    Station(id: 'JHR-CHAAH', name: 'Sg. Lenik di Ladang Chaah', district: 'Segamat', state: 'Johor',
        thresholds: _t(3.00, 4.50, 5.20, 6.00)), // no location on purpose
    Station(id: 'SGR-KAJANG', name: 'Sg. Langat di Kajang', district: 'Hulu Langat', state: 'Selangor',
        location: GeoPoint(2.993, 101.787), thresholds: _t(21.00, 23.00, 24.00, 25.00)),
    Station(id: 'SGR-RANTAU', name: 'Sg. Selangor di Rantau Panjang', district: 'Kuala Selangor', state: 'Selangor',
        location: GeoPoint(3.403, 101.443), thresholds: _t(4.00, 5.50, 6.50, 7.50)),
    Station(id: 'MLK-HAMPAR', name: 'Sg. Melaka di Batu Hampar', district: 'Melaka Tengah', state: 'Melaka',
        location: GeoPoint(2.233, 102.250), thresholds: _t(1.50, 2.50, 3.00, 3.50)),
    Station(id: 'MLK-DURIAN', name: 'Stesen Hujan Durian Tunggal', district: 'Alor Gajah', state: 'Melaka',
        location: GeoPoint(2.312, 102.280)), // rainfall only
  ];

  @override
  Future<List<Station>> getStations() async => List.unmodifiable(_stations);

  @override
  Future<Map<String, StationReading>> getLatestReadings() async {
    final now = _clock();
    StationReading r(String id, Duration ago, double? rain, double? river) => StationReading.fromRaw(
        stationId: id, time: now.subtract(ago), rainfall: rain, riverLevel: river);
    final list = [
      r('JHR-AWAT', const Duration(minutes: 10), 12.0, 19.97), // Danger
      r('JHR-BULOH', const Duration(minutes: 21), 35.0, 8.00), // Alert
      r('JHR-SEGKECIL', const Duration(minutes: 15), 8.5, 8.10), // Warning
      r('JHR-CHAAH', const Duration(minutes: 30), 1.0, 3.40), // Normal
      r('SGR-KAJANG', const Duration(minutes: 5), 0.0, 21.30), // Normal
      r('SGR-RANTAU', const Duration(days: 2), 4.0, 5.80), // stale
      r('MLK-HAMPAR', const Duration(minutes: 12), 2.0, -9999), // sensor offline
      r('MLK-DURIAN', const Duration(minutes: 8), 65.0, null), // rainfall only
    ];
    return {for (final x in list) x.stationId: x};
  }
}
