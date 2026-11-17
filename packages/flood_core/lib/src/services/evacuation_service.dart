import '../data/table.dart';
import '../errors.dart';
import '../models/evacuation_point.dart';
import '../models/staff.dart';
import '../util/geo.dart';
import 'access_control.dart';

class NearbyEvacuation {
  NearbyEvacuation(this.point, this.distanceKm);
  final EvacuationPoint point;
  final double distanceKm;
}

/// Relief centres: the public "Evacuation" screen and staff management.
class EvacuationService {
  EvacuationService({required this.points, required this.newId});
  final Table<EvacuationPoint> points;
  final IdGenerator newId;

  // ---------- public ----------

  /// Nearest centres first. By default only centres that are open and not full.
  /// Distance is a straight line, not road distance.
  Future<List<NearbyEvacuation>> nearest(GeoPoint user,
      {int limit = 3, bool includeUnavailable = false}) async {
    final list = [
      for (final p in await points.all())
        if (includeUnavailable || p.isAvailable) NearbyEvacuation(p, distanceKm(user, p.location)),
    ]..sort((a, b) {
        final c = a.distanceKm.compareTo(b.distanceKm);
        return c != 0 ? c : a.point.name.compareTo(b.point.name);
      });
    return list.take(limit < 0 ? 0 : limit).toList();
  }

  Future<List<EvacuationPoint>> listAll() => points.all();

  /// Link that opens turn-by-turn directions in Google Maps (free, no API key).
  String directionsUrl(GeoPoint to, {GeoPoint? from}) {
    final origin = from == null ? '' : '&origin=${from.lat},${from.lon}';
    return 'https://www.google.com/maps/dir/?api=1$origin&destination=${to.lat},${to.lon}&travelmode=driving';
  }

  // ---------- staff ----------

  Future<EvacuationPoint> add(
    StaffSession? session, {
    required String name,
    required GeoPoint location,
    required int capacity,
    String? resourcePointId,
  }) async {
    AccessControl.require(session, Permission.managePoints);
    final n = name.trim();
    if (n.isEmpty) throw ValidationException('Name is required');
    if (capacity <= 0) throw ValidationException('Capacity must be more than 0');
    if ((await points.all()).any((p) => p.name.toLowerCase() == n.toLowerCase())) {
      throw ConflictException('An evacuation point with this name already exists');
    }
    final p = EvacuationPoint(
        id: newId(), name: n, location: location, capacity: capacity, resourcePointId: resourcePointId);
    await points.put(p.id, p);
    return p;
  }

  /// Deletes a centre. Refused while people are still recorded there.
  Future<void> remove(StaffSession? session, String id) async {
    AccessControl.require(session, Permission.managePoints);
    final p = await _get(id);
    if (p.occupancy > 0) throw ConflictException('Centre still has ${p.occupancy} people recorded');
    await points.remove(id);
  }

  Future<EvacuationPoint> setOccupancy(StaffSession? session, String id, int occupancy) async {
    AccessControl.require(session, Permission.updateOccupancy);
    final p = await _get(id);
    if (occupancy < 0 || occupancy > p.capacity) {
      throw ValidationException('Occupancy must be between 0 and ${p.capacity}');
    }
    final updated = p.copyWith(occupancy: occupancy);
    await points.put(id, updated);
    return updated;
  }

  Future<EvacuationPoint> setOpen(StaffSession? session, String id, bool isOpen) async {
    AccessControl.require(session, Permission.updateOccupancy);
    final updated = (await _get(id)).copyWith(isOpen: isOpen);
    await points.put(id, updated);
    return updated;
  }

  Future<EvacuationPoint> _get(String id) async =>
      await points.byId(id) ?? (throw NotFoundException('evacuation point', id));
}
