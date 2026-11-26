import 'dart:convert';
import 'dart:typed_data';

import '../errors.dart';
import 'aes_gcm.dart';

/// The family's shared AES-256 key. Made on the phone that creates the
/// family and passed on only inside the invite link's #fragment (or its QR
/// code), so Supabase never sees it. [version] matches
/// family_groups.key_version and goes up each time the invite is renewed.
class FamilyKey {
  FamilyKey(List<int> bytes, this.version) : bytes = Uint8List.fromList(bytes) {
    if (bytes.length != AesGcmHelper.keyLength) throw ValidationException('Family key must be 32 bytes');
    if (version < 1) throw ValidationException('Key version must be 1 or more');
  }
  final Uint8List bytes;
  final int version;

  static Future<FamilyKey> generate({int version = 1}) async => FamilyKey(await AesGcmHelper.newKey(), version);

  /// URL-safe base64 without padding (43 characters), for the link fragment.
  String toBase64Url() => base64Url.encode(bytes).replaceAll('=', '');

  static FamilyKey fromBase64Url(String text, int version) {
    try {
      return FamilyKey(base64Url.decode(base64Url.normalize(text)), version);
    } on FormatException {
      throw ValidationException('The invite key is damaged');
    }
  }
}

/// `floodready://family/join?code=ABC123&v=1#key=<base64url>`.
///
/// The key is in the fragment (after `#`): a fragment is never sent in an
/// HTTP request, so if the link is opened in a browser or previewed by a chat
/// app, the server still only learns the invite code.
class FamilyInvite {
  FamilyInvite(this.code, this.key);
  final String code;
  final FamilyKey key;

  static final _code = RegExp(r'^[A-Za-z0-9_-]{8,32}$');

  Uri toUri() => Uri(
        scheme: 'floodready',
        host: 'family',
        path: '/join',
        queryParameters: {'code': code, 'v': '${key.version}'},
        fragment: 'key=${key.toBase64Url()}',
      );

  /// Reads an invite link. Throws [ValidationException] if any part is missing
  /// or if the key was put in the query (where servers would see it).
  static FamilyInvite parse(Uri uri) {
    if (uri.scheme != 'floodready' || uri.host != 'family' || uri.path != '/join') {
      throw ValidationException('Not a FloodReady family invite');
    }
    if (uri.queryParameters.containsKey('key')) {
      throw ValidationException('Unsafe invite: the key must not be in the link query');
    }
    final code = uri.queryParameters['code'] ?? '';
    if (!_code.hasMatch(code)) throw ValidationException('The invite code is missing or damaged');
    final version = int.tryParse(uri.queryParameters['v'] ?? '');
    if (version == null || version < 1) throw ValidationException('The invite version is missing');
    final fragment = Uri.splitQueryString(uri.fragment);
    final key = fragment['key'];
    if (key == null || key.isEmpty) throw ValidationException('The invite key is missing');
    return FamilyInvite(code, FamilyKey.fromBase64Url(key, version));
  }
}

/// What a phone shares: where it is, battery and when.
class SharedLocation {
  SharedLocation({required this.lat, required this.lon, required this.at, this.batteryPct}) {
    if (!(lat >= -90 && lat <= 90) || !(lon >= -180 && lon <= 180)) {
      throw ValidationException('Location out of range');
    }
    if (batteryPct != null && (batteryPct! < 0 || batteryPct! > 100)) {
      throw ValidationException('Battery must be 0 to 100');
    }
  }
  final double lat;
  final double lon;
  final int? batteryPct;
  final DateTime at;

  Map<String, Object?> toJson() =>
      {'lat': lat, 'lon': lon, 'battery_pct': batteryPct, 'at': at.toUtc().toIso8601String()};

  static SharedLocation fromJson(Map<String, Object?> j) {
    final lat = j['lat'], lon = j['lon'], bat = j['battery_pct'], at = j['at'];
    if (lat is! num || lon is! num || at is! String || (bat != null && bat is! int)) {
      throw ValidationException('Bad location data');
    }
    final when = DateTime.tryParse(at);
    if (when == null) throw ValidationException('Bad location time');
    return SharedLocation(lat: lat.toDouble(), lon: lon.toDouble(), at: when, batteryPct: bat as int?);
  }
}

/// A family member's location as stored in family_locations: only base64
/// ciphertext and IV, which Supabase cannot read.
class EncryptedLocation {
  const EncryptedLocation({required this.ciphertext, required this.iv, required this.keyVersion});
  final String ciphertext;
  final String iv;
  final int keyVersion;
}

/// Encrypts locations end to end with the family key (AES-256-GCM).
///
/// The associated data binds each ciphertext to its group, member and key
/// version: a database admin who copies one member's row onto another
/// member, or replays it under a renewed key, makes decryption fail instead
/// of showing a false pin.
class FamilyLocationCrypto {
  FamilyLocationCrypto._();

  static List<int> _aad(String groupId, String memberId, int keyVersion) =>
      utf8.encode('FloodReady family location v1|$groupId|$memberId|$keyVersion');

  static Future<EncryptedLocation> encrypt(SharedLocation fix, FamilyKey key,
      {required String groupId, required String memberId}) async {
    final sealed = await AesGcmHelper.encrypt(utf8.encode(jsonEncode(fix.toJson())), key.bytes,
        aad: _aad(groupId, memberId, key.version));
    return EncryptedLocation(
        ciphertext: sealed.ciphertextBase64, iv: sealed.ivBase64, keyVersion: key.version);
  }

  /// The location, or [DecryptionException] for a wrong key, a row moved to
  /// another member, an old key version or any changed byte.
  static Future<SharedLocation> decrypt(EncryptedLocation e, FamilyKey key,
      {required String groupId, required String memberId}) async {
    if (e.keyVersion != key.version) throw DecryptionException();
    final plain = await AesGcmHelper.decrypt(Sealed.fromBase64(e.iv, e.ciphertext), key.bytes,
        aad: _aad(groupId, memberId, e.keyVersion));
    try {
      return SharedLocation.fromJson((jsonDecode(utf8.decode(plain)) as Map).cast<String, Object?>());
    } on Object {
      throw DecryptionException();
    }
  }
}
