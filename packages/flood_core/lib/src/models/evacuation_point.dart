import '../util/geo.dart';

/// A relief centre (PPS).
class EvacuationPoint {
  EvacuationPoint({
    required this.id,
    required this.name,
    required this.location,
    required this.capacity,
    this.occupancy = 0,
    this.isOpen = true,
    this.resourcePointId,
    this.district,
    this.phone,
    this.locationChecked = true,
    this.capacityEstimated = false,
  });
  final String id;
  final String name;
  final GeoPoint location;
  final int capacity;
  final int occupancy;
  final bool isOpen;

  /// The resource point (warehouse) that supplies this centre.
  final String? resourcePointId;

  /// One of [allDistricts] (Selangor or Melaka). Null only for rows made before districts existed.
  final String? district;

  /// The centre's phone number, when known (shows a Call button).
  final String? phone;

  /// False when nobody has checked the map position yet (places/centres.csv):
  /// the app lists the centre but gives no pin, no road route and never
  /// suggests it as the nearest centre.
  final bool locationChecked;

  /// True when [capacity] is a guess, not an official figure.
  final bool capacityEstimated;

  bool get isFull => occupancy >= capacity;
  bool get isAvailable => isOpen && !isFull;

  EvacuationPoint copyWith({int? occupancy, bool? isOpen}) => EvacuationPoint(
      id: id, name: name, location: location, capacity: capacity,
      resourcePointId: resourcePointId, district: district, phone: phone,
      locationChecked: locationChecked, capacityEstimated: capacityEstimated,
      occupancy: occupancy ?? this.occupancy, isOpen: isOpen ?? this.isOpen);
}
