import '../models/station.dart';
import '../models/station_reading.dart';

/// Where station data comes from. The rest of the code only knows this
/// interface, so the sample data can be swapped for the live feed later
/// without touching any service.
abstract class StationRepository {
  Future<List<Station>> getStations();

  /// Latest reading per station id. Stations with no reading are left out.
  Future<Map<String, StationReading>> getLatestReadings();
}
