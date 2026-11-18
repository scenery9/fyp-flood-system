import 'dart:convert';

import 'package:flood_core/flood_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Saves a [SettingsStore]'s values on the phone, under one key.
/// Use a different [key] for each store so they never overwrite each other.
class PhoneSettingsStore implements SettingsStore {
  PhoneSettingsStore(this.key, [SharedPreferencesAsync? prefs])
      : _prefs = prefs ?? SharedPreferencesAsync();
  final String key;
  final SharedPreferencesAsync _prefs;

  @override
  Future<Map<String, String>> load() async {
    final saved = await _prefs.getString(key);
    if (saved == null) return {};
    try {
      final decoded = jsonDecode(saved);
      if (decoded is! Map) return {};
      return {
        for (final e in decoded.entries)
          if (e.value is String) '${e.key}': e.value as String,
      };
    } on FormatException {
      return {}; // damaged save: start again from the defaults
    }
  }

  @override
  Future<void> save(Map<String, String> values) => _prefs.setString(key, jsonEncode(values));
}
