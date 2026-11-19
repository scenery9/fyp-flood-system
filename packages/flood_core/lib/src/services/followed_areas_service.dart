import '../data/followed_store.dart';
import '../data/station_repository.dart';
import '../errors.dart';

/// "Urus Kawasan Saya": the areas (stations) a user follows, 5 at most.
class FollowedAreasService {
  FollowedAreasService({required this.store, required this.repository});

  static const int maxAreas = 5;
  final FollowedStore store;
  final StationRepository repository;

  /// Followed ids in the order they were added (duplicates/blanks removed).
  Future<List<String>> list() async {
    final seen = <String>{};
    return [
      for (final id in await store.load())
        if (id.trim().isNotEmpty && seen.add(id)) id,
    ].take(maxAreas).toList();
  }

  Future<bool> isFollowed(String stationId) async => (await list()).contains(stationId);

  /// Follows a station. Following it twice changes nothing.
  /// Throws [UnknownStationException] or [FollowLimitReachedException].
  Future<List<String>> follow(String stationId) async {
    final current = await list();
    if (current.contains(stationId)) return current;
    final stations = await repository.getStations();
    if (!stations.any((s) => s.id == stationId)) throw UnknownStationException(stationId);
    if (current.length >= maxAreas) throw FollowLimitReachedException(maxAreas);
    final updated = [...current, stationId];
    await store.save(updated);
    return updated;
  }

  /// Unfollows a station. Unfollowing one that is not followed changes nothing.
  Future<List<String>> unfollow(String stationId) async {
    final current = await list();
    if (!current.contains(stationId)) return current;
    final updated = current.where((id) => id != stationId).toList();
    await store.save(updated);
    return updated;
  }

  /// Saves the areas in the order the user arranged them. [ordered] must hold
  /// exactly the followed ids; anything else is ignored (returns the list unchanged).
  Future<List<String>> reorder(List<String> ordered) async {
    final current = await list();
    if (ordered.length != current.length || !current.every(ordered.contains)) return current;
    await store.save([...ordered]);
    return [...ordered];
  }

  /// Star button: returns true if the station is followed afterwards.
  Future<bool> toggle(String stationId) async {
    if (await isFollowed(stationId)) {
      await unfollow(stationId);
      return false;
    }
    await follow(stationId);
    return true;
  }
}
