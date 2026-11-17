import '../data/table.dart';
import '../errors.dart';
import '../models/evacuation_point.dart';
import '../models/resources.dart';
import '../models/staff.dart';
import '../util/geo.dart';
import 'access_control.dart';

/// Staff: resource points, stock, catalogue mapping, expiry and supply alerts.
class ResourceService {
  ResourceService({
    required this.points,
    required this.items,
    required this.catalogue,
    required this.evacuationPoints,
    required this.newId,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;
  final Table<ResourcePoint> points;
  final Table<InventoryItem> items;
  final Table<CatalogueUnit> catalogue;
  final Table<EvacuationPoint> evacuationPoints;
  final IdGenerator newId;
  final DateTime Function() _clock;

  // ---------- resource points ----------

  Future<List<ResourcePoint>> listPoints(StaffSession? session) async {
    AccessControl.require(session, Permission.viewOperations);
    return points.all();
  }

  Future<ResourcePoint> addPoint(StaffSession? session,
      {required String name, required GeoPoint location}) async {
    AccessControl.require(session, Permission.managePoints);
    final n = name.trim();
    if (n.isEmpty) throw ValidationException('Name is required');
    if ((await points.all()).any((p) => p.name.toLowerCase() == n.toLowerCase())) {
      throw ConflictException('A resource point with this name already exists');
    }
    final p = ResourcePoint(id: newId(), name: n, location: location);
    await points.put(p.id, p);
    return p;
  }

  /// Deletes a resource point. Refused while it holds stock or supplies a centre.
  Future<void> removePoint(StaffSession? session, String id) async {
    AccessControl.require(session, Permission.managePoints);
    await _point(id);
    if ((await items.all()).any((i) => i.resourcePointId == id)) {
      throw ConflictException('Resource point still has stock items');
    }
    if ((await evacuationPoints.all()).any((e) => e.resourcePointId == id)) {
      throw ConflictException('Resource point still supplies an evacuation point');
    }
    await points.remove(id);
  }

  // ---------- stock ----------

  Future<List<InventoryItem>> listItems(StaffSession? session, {String? resourcePointId}) async {
    AccessControl.require(session, Permission.viewOperations);
    return (await items.all())
        .where((i) => resourcePointId == null || i.resourcePointId == resourcePointId)
        .toList();
  }

  Future<InventoryItem> addItem(
    StaffSession? session, {
    required String resourcePointId,
    required String name,
    required double quantity,
    DateTime? expiryDate,
  }) async {
    AccessControl.require(session, Permission.updateStock);
    await _point(resourcePointId);
    if (name.trim().isEmpty) throw ValidationException('Item name is required');
    _checkQuantity(quantity);
    final i = InventoryItem(
        id: newId(), resourcePointId: resourcePointId, name: name.trim(),
        quantity: quantity, expiryDate: expiryDate);
    await items.put(i.id, i);
    return i;
  }

  Future<InventoryItem> setQuantity(StaffSession? session, String itemId, double quantity) async {
    AccessControl.require(session, Permission.updateStock);
    _checkQuantity(quantity);
    final updated = (await _item(itemId)).copyWith(quantity: quantity);
    await items.put(itemId, updated);
    return updated;
  }

  void _checkQuantity(double q) {
    if (q.isNaN || q.isInfinite || q < 0) throw ValidationException('Quantity cannot be negative');
  }

  // ---------- catalogue mapping ("Map Inventory") ----------

  Future<CatalogueUnit> addCatalogueUnit(
    StaffSession? session, {
    required String name,
    required String unit,
    required double dailyNeedPerPerson,
  }) async {
    AccessControl.require(session, Permission.mapInventory);
    if (name.trim().isEmpty || unit.trim().isEmpty) throw ValidationException('Name and unit are required');
    if (dailyNeedPerPerson.isNaN || dailyNeedPerPerson <= 0) {
      throw ValidationException('Daily need per person must be more than 0');
    }
    final c = CatalogueUnit(
        id: newId(), name: name.trim(), unit: unit.trim(), dailyNeedPerPerson: dailyNeedPerPerson);
    await catalogue.put(c.id, c);
    return c;
  }

  /// Links a stock item to a catalogue unit. Pass null to remove the link.
  Future<InventoryItem> mapItem(StaffSession? session, String itemId, String? catalogueUnitId) async {
    AccessControl.require(session, Permission.mapInventory);
    final item = await _item(itemId);
    if (catalogueUnitId != null && await catalogue.byId(catalogueUnitId) == null) {
      throw NotFoundException('catalogue unit', catalogueUnitId);
    }
    final updated = catalogueUnitId == null
        ? item.copyWith(clearMapping: true)
        : item.copyWith(catalogueUnitId: catalogueUnitId);
    await items.put(itemId, updated);
    return updated;
  }

  Future<List<InventoryItem>> unmappedItems(StaffSession? session) async =>
      (await listItems(session)).where((i) => i.catalogueUnitId == null).toList();

  // ---------- alerts ----------

  /// Stock that has expired or expires within [withinDays], soonest first.
  Future<List<InventoryItem>> expiringItems(StaffSession? session, {int withinDays = 30}) async {
    AccessControl.require(session, Permission.viewOperations);
    final limit = _clock().add(Duration(days: withinDays));
    return (await items.all())
        .where((i) => i.quantity > 0 && i.expiryDate != null && !i.expiryDate!.isAfter(limit))
        .toList()
      ..sort((a, b) => a.expiryDate!.compareTo(b.expiryDate!));
  }

  /// Supplies that will last fewer than [minDays] days, worst first.
  /// People served = occupancy of the open centres a resource point supplies.
  /// Expired and unmapped stock is not counted.
  Future<List<SupplyAlert>> supplyAlerts(StaffSession? session, {double minDays = 3}) async {
    AccessControl.require(session, Permission.viewOperations);
    final now = _clock();
    final allItems = await items.all();
    final units = await catalogue.all();
    final centres = await evacuationPoints.all();
    final alerts = <SupplyAlert>[];
    for (final p in await points.all()) {
      final people = centres
          .where((e) => e.resourcePointId == p.id && e.isOpen)
          .fold<int>(0, (sum, e) => sum + e.occupancy);
      if (people == 0) continue;
      for (final u in units) {
        final qty = allItems
            .where((i) => i.resourcePointId == p.id && i.catalogueUnitId == u.id && !i.isExpiredAt(now))
            .fold<double>(0, (sum, i) => sum + i.quantity);
        final days = qty / (u.dailyNeedPerPerson * people);
        if (days < minDays) {
          alerts.add(SupplyAlert(point: p, unit: u, quantity: qty, people: people, daysLeft: days));
        }
      }
    }
    return alerts..sort((a, b) => a.daysLeft.compareTo(b.daysLeft));
  }

  Future<ResourcePoint> _point(String id) async =>
      await points.byId(id) ?? (throw NotFoundException('resource point', id));
  Future<InventoryItem> _item(String id) async =>
      await items.byId(id) ?? (throw NotFoundException('stock item', id));
}
