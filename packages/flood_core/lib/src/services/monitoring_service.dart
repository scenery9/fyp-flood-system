import '../data/station_repository.dart';
import '../errors.dart';
import '../models/station_status.dart';
import '../risk/risk_calculator.dart';
import '../util/geo.dart';

/// Loads stations + readings and works out the status of each station.
/// Every screen (Home, lists, warnings, detail) starts from this.
class MonitoringService {
  MonitoringService({
    required this.repository,
    this.calculator = const RiskCalculator(),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final StationRepository repository;
  final RiskCalculator calculator;
  final DateTime Function() _clock;

  DateTime now() => _clock();

  /// Status of every station. Pass [userLocation] to get distances.
  Future<List<StationStatus>> loadStatuses({GeoPoint? userLocation}) async {
    final stations = await repository.getStations();
    final readings = await repository.getLatestReadings();
    final now = _clock();
    return [
      for (final s in stations)
        calculator.assess(s, readings[s.id], now: now, userLocation: userLocation),
    ];
  }

  /// Status of one station (Station Detail sheet).
  Future<StationStatus> statusFor(String stationId, {GeoPoint? userLocation}) async {
    final all = await loadStatuses(userLocation: userLocation);
    for (final s in all) {
      if (s.station.id == stationId) return s;
    }
    throw UnknownStationException(stationId);
  }
}
