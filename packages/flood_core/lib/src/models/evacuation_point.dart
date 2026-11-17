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
  });
  final String id;
  final String name;
  final GeoPoint location;
  final int capacity;
  final int occupancy;
  final bool isOpen;

  /// The resource point (warehouse) that supplies this centre.
  final String? resourcePointId;

  bool get isFull => occupancy >= capacity;
  bool get isAvailable => isOpen && !isFull;

  EvacuationPoint copyWith({int? occupancy, bool? isOpen}) => EvacuationPoint(
      id: id, name: name, location: location, capacity: capacity,
      resourcePointId: resourcePointId,
      occupancy: occupancy ?? this.occupancy, isOpen: isOpen ?? this.isOpen);
}
