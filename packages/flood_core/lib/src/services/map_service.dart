import '../models/risk_level.dart';
import '../models/staff.dart';
import '../models/station_status.dart';
import '../util/geo.dart';
import 'access_control.dart';
import 'evacuation_service.dart';
import 'monitoring_service.dart';
import 'resource_service.dart';

enum MarkerKind { station, evacuation, resourcePoint, user }

/// How a marker should look. The UI maps each style to a colour and icon.
enum MarkerStyle {
  stationNormal, stationAlert, stationWarning, stationDanger, stationUnknown,
  shelterOpen, shelterFull, shelterClosed, warehouse, user,
}

class MapMarker {
  MapMarker({
    required this.id,
    required this.kind,
    required this.style,
    required this.position,
    required this.title,
    required this.subtitle,
  });
  final String id;
  final MarkerKind kind;
  final MarkerStyle style;
  final GeoPoint position;
  final String title;
  final String subtitle;
}

/// The rectangle the map should zoom to.
class MapBounds {
  MapBounds(this.south, this.west, this.north, this.east);
  final double south, west, north, east;
  GeoPoint get center => GeoPoint((south + north) / 2, (west + east) / 2);
  bool contains(GeoPoint p) =>
      p.lat >= south && p.lat <= north && p.lon >= west && p.lon <= east;
}

class MapData {
  MapData(this.markers, this.bounds, this.hiddenWithoutLocation);
  final List<MapMarker> markers;

  /// Null when there is nothing to show.
  final MapBounds? bounds;

  /// Stations left off the map because the source has no coordinates for them.
  final int hiddenWithoutLocation;
}

/// Data for the Live Map (public) and the Operations Map (staff).
/// Drawing the map itself is the UI's job.
class MapService {
  MapService({required this.monitoring, required this.evacuation, required this.resources});
  final MonitoringService monitoring;
  final EvacuationService evacuation;
  final ResourceService resources;

  /// Public Live Map: stations by risk, plus relief centres that are open.
  Future<MapData> liveMap({
    GeoPoint? user,
    String? state, // null = all states
    bool showStations = true,
    bool showEvacuation = true,
  }) async {
    final markers = <MapMarker>[];
    var hidden = 0;
    if (showStations) {
      for (final s in await monitoring.loadStatuses()) {
        if (state != null && s.station.state.toLowerCase() != state.trim().toLowerCase()) continue;
        if (s.station.location == null) {
          hidden++;
          continue;
        }
        markers.add(_station(s));
      }
    }
    if (showEvacuation) {
      for (final p in await evacuation.listAll()) {
        if (!p.isOpen) continue;
        markers.add(MapMarker(
            id: p.id, kind: MarkerKind.evacuation, position: p.location, title: p.name,
            style: p.isFull ? MarkerStyle.shelterFull : MarkerStyle.shelterOpen,
            subtitle: p.isFull ? 'Full' : 'Open - ${p.capacity - p.occupancy} places left'));
      }
    }
    if (user != null) {
      markers.add(MapMarker(
          id: 'user', kind: MarkerKind.user, style: MarkerStyle.user, position: user,
          title: 'You are here', subtitle: ''));
    }
    return MapData(markers, _bounds(markers), hidden);
  }

  /// Staff Operations Map: every shelter (open, full, closed), warehouses,
  /// and only the stations that are at Alert or above.
  Future<MapData> operationsMap(StaffSession? session) async {
    AccessControl.require(session, Permission.viewOperations);
    final markers = <MapMarker>[];
    var hidden = 0;
    for (final p in await evacuation.listAll()) {
      markers.add(MapMarker(
          id: p.id, kind: MarkerKind.evacuation, position: p.location, title: p.name,
          style: !p.isOpen
              ? MarkerStyle.shelterClosed
              : (p.isFull ? MarkerStyle.shelterFull : MarkerStyle.shelterOpen),
          subtitle: '${p.isOpen ? 'Open' : 'Closed'} - ${p.occupancy}/${p.capacity} people'));
    }
    for (final r in await resources.listPoints(session)) {
      markers.add(MapMarker(
          id: r.id, kind: MarkerKind.resourcePoint, style: MarkerStyle.warehouse,
          position: r.location, title: r.name, subtitle: 'Resource point'));
    }
    for (final s in await monitoring.loadStatuses()) {
      if (!s.isActionable || !s.level!.isAtLeast(RiskLevel.alert)) continue;
      if (s.station.location == null) {
        hidden++;
        continue;
      }
      markers.add(_station(s));
    }
    return MapData(markers, _bounds(markers), hidden);
  }

  MapMarker _station(StationStatus s) {
    final MarkerStyle style;
    final String subtitle;
    if (!s.isActionable) {
      style = MarkerStyle.stationUnknown;
      subtitle = s.isStale ? 'Old data' : 'No river data';
    } else {
      style = const {
        RiskLevel.normal: MarkerStyle.stationNormal,
        RiskLevel.alert: MarkerStyle.stationAlert,
        RiskLevel.warning: MarkerStyle.stationWarning,
        RiskLevel.danger: MarkerStyle.stationDanger,
      }[s.level]!;
      subtitle = '${s.level!.labelEn} - ${s.riverLevel!.toStringAsFixed(2)} m - '
          '${s.age!.inMinutes} min ago';
    }
    return MapMarker(
        id: s.station.id, kind: MarkerKind.station, style: style,
        position: s.station.location!, title: s.station.name, subtitle: subtitle);
  }

  /// Smallest rectangle around all markers, with a margin so pins are not on the edge.
  MapBounds? _bounds(List<MapMarker> markers) {
    if (markers.isEmpty) return null;
    var s = 90.0, w = 180.0, n = -90.0, e = -180.0;
    for (final m in markers) {
      final p = m.position;
      if (p.lat < s) s = p.lat;
      if (p.lat > n) n = p.lat;
      if (p.lon < w) w = p.lon;
      if (p.lon > e) e = p.lon;
    }
    final padLat = ((n - s) * 0.1).clamp(0.01, 5.0);
    final padLon = ((e - w) * 0.1).clamp(0.01, 5.0);
    return MapBounds((s - padLat).clamp(-90.0, 90.0), (w - padLon).clamp(-180.0, 180.0),
        (n + padLat).clamp(-90.0, 90.0), (e + padLon).clamp(-180.0, 180.0));
  }
}
