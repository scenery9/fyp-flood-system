/// Saves the ids of followed stations. The Flutter app will provide a
/// version that writes to the phone; tests use the in-memory one.
abstract class FollowedStore {
  Future<List<String>> load();
  Future<void> save(List<String> stationIds);
}

class InMemoryFollowedStore implements FollowedStore {
  InMemoryFollowedStore([List<String> initial = const []]) : _ids = [...initial];
  List<String> _ids;

  @override
  Future<List<String>> load() async => [..._ids];

  @override
  Future<void> save(List<String> stationIds) async => _ids = [...stationIds];
}
