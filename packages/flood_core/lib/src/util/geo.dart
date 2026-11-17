import 'dart:math' as math;

/// A latitude/longitude pair in decimal degrees.
class GeoPoint {
  GeoPoint(this.lat, this.lon) {
    if (lat.isNaN || lon.isNaN || lat < -90 || lat > 90 || lon < -180 || lon > 180) {
      throw ArgumentError('Invalid coordinates: $lat, $lon');
    }
  }
  final double lat;
  final double lon;
}

/// Straight-line distance in kilometres (haversine formula).
double distanceKm(GeoPoint a, GeoPoint b) {
  const earthRadiusKm = 6371.0;
  double rad(double deg) => deg * math.pi / 180;
  final dLat = rad(b.lat - a.lat);
  final dLon = rad(b.lon - a.lon);
  final h = math.pow(math.sin(dLat / 2), 2) +
      math.cos(rad(a.lat)) * math.cos(rad(b.lat)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * earthRadiusKm * math.asin(math.min(1.0, math.sqrt(h)));
}
