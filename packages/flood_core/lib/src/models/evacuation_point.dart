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
  });
  final String id;
  final String name;
  final GeoPoint location;
  final int capacity;
  final int occupancy;
  final bool isOpen;

  /// The resource point (warehouse) that supplies this centre.
  final String? resourcePointId;

  /// One of [selangorDistricts]. Null only for rows made before districts existed.
  final String? district;

  bool get isFull => occupancy >= capacity;
  bool get isAvailable => isOpen && !isFull;

  EvacuationPoint copyWith({int? occupancy, bool? isOpen}) => EvacuationPoint(
      id: id, name: name, location: location, capacity: capacity,
      resourcePointId: resourcePointId, district: district,
      occupancy: occupancy ?? this.occupancy, isOpen: isOpen ?? this.isOpen);
}
