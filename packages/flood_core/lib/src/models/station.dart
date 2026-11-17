import '../util/geo.dart';

/// River level thresholds for one station, in metres. Must be strictly rising.
class Thresholds {
  Thresholds({
    required this.normal,
    required this.alert,
    required this.warning,
    required this.danger,
  }) {
    if (!(normal < alert && alert < warning && warning < danger)) {
      throw ArgumentError('Thresholds must rise: $normal < $alert < $warning < $danger');
    }
  }
  final double normal;
  final double alert;
  final double warning;
  final double danger;
}

/// A monitoring station. [thresholds] is null for rainfall-only stations,
/// [location] is null when the source has no coordinates.
class Station {
  Station({
    required this.id,
    required this.name,
    required this.district,
    required this.state,
    this.location,
    this.thresholds,
  }) {
    if (id.trim().isEmpty) throw ArgumentError('Station id cannot be empty');
  }
  final String id;
  final String name;
  final String district;
  final String state;
  final GeoPoint? location;
  final Thresholds? thresholds;
}
