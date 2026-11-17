import '../util/geo.dart';

/// A warehouse or store that holds relief supplies.
class ResourcePoint {
  ResourcePoint({required this.id, required this.name, required this.location});
  final String id;
  final String name;
  final GeoPoint location;
}

/// A standard supply (e.g. "Drinking water", unit "litre", 3 per person per day).
class CatalogueUnit {
  CatalogueUnit({required this.id, required this.name, required this.unit, required this.dailyNeedPerPerson});
  final String id;
  final String name;
  final String unit;
  final double dailyNeedPerPerson;
}

/// A stock line at one resource point. Unmapped until linked to a catalogue unit.
class InventoryItem {
  InventoryItem({
    required this.id,
    required this.resourcePointId,
    required this.name,
    required this.quantity,
    this.catalogueUnitId,
    this.expiryDate,
  });
  final String id;
  final String resourcePointId;
  final String name;
  final double quantity;
  final String? catalogueUnitId;
  final DateTime? expiryDate;

  bool isExpiredAt(DateTime now) => expiryDate != null && expiryDate!.isBefore(now);

  InventoryItem copyWith({double? quantity, String? catalogueUnitId, bool clearMapping = false}) =>
      InventoryItem(
          id: id, resourcePointId: resourcePointId, name: name, expiryDate: expiryDate,
          quantity: quantity ?? this.quantity,
          catalogueUnitId: clearMapping ? null : (catalogueUnitId ?? this.catalogueUnitId));
}

/// A supply that will run out soon at one resource point.
class SupplyAlert {
  SupplyAlert({required this.point, required this.unit, required this.quantity, required this.people, required this.daysLeft});
  final ResourcePoint point;
  final CatalogueUnit unit;
  final double quantity;
  final int people;
  final double daysLeft;
}
