/// A simple "table" of records keyed by id. Services only know this interface.
/// Tests use [MemoryTable]; a Supabase version can be added later per table
/// without changing any service.
abstract class Table<T> {
  Future<List<T>> all();
  Future<T?> byId(String id);
  Future<void> put(String id, T value);
  Future<void> remove(String id);
}

class MemoryTable<T> implements Table<T> {
  final Map<String, T> _rows = {};

  /// Set to true in tests to simulate storage being unreachable.
  bool fail = false;
  void _check() {
    if (fail) throw StateError('storage unavailable');
  }

  @override
  Future<List<T>> all() async {
    _check();
    return _rows.values.toList();
  }

  @override
  Future<T?> byId(String id) async {
    _check();
    return _rows[id];
  }

  @override
  Future<void> put(String id, T value) async {
    _check();
    _rows[id] = value;
  }

  @override
  Future<void> remove(String id) async {
    _check();
    _rows.remove(id);
  }
}

/// Makes new record ids. Supabase will generate real ids later.
typedef IdGenerator = String Function();

IdGenerator sequentialIds([String prefix = 'id']) {
  var n = 0;
  return () => '$prefix-${++n}';
}
