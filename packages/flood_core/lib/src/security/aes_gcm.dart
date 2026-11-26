import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// A ciphertext could not be opened: wrong key, wrong associated data, or the
/// bytes were changed. Deliberately says nothing more.
class DecryptionException implements Exception {
  @override
  String toString() => 'DecryptionException: could not decrypt';
}

/// One AES-256-GCM sealed message: a fresh 96-bit IV and the ciphertext with
/// the 128-bit tag on the end (the layout WebCrypto and most libraries use).
class Sealed {
  const Sealed(this.iv, this.ciphertextAndTag);
  final List<int> iv;
  final List<int> ciphertextAndTag;

  String get ivBase64 => base64.encode(iv);
  String get ciphertextBase64 => base64.encode(ciphertextAndTag);

  /// From the two base64 columns stored in the database.
  static Sealed fromBase64(String iv, String ciphertext) {
    try {
      return Sealed(base64.decode(iv), base64.decode(ciphertext));
    } on FormatException {
      throw DecryptionException();
    }
  }
}

/// AES-256-GCM with a random 96-bit IV per message (NIST SP 800-38D).
///
/// Use a key for fewer than 2^32 messages (random IVs); a family key is
/// replaced long before that. [aad] is checked but not encrypted: bind each
/// message to where it belongs (group, member) so a ciphertext cannot be
/// moved to another row unnoticed.
class AesGcmHelper {
  AesGcmHelper._();

  static const keyLength = 32;
  static const ivLength = 12;
  static const tagLength = 16;
  static final _algorithm = AesGcm.with256bits();

  /// A new random 256-bit key (from the platform's secure random generator).
  static Future<Uint8List> newKey() async =>
      Uint8List.fromList(await (await _algorithm.newSecretKey()).extractBytes());

  static Future<Sealed> encrypt(List<int> plaintext, List<int> key,
      {List<int> aad = const [], List<int>? iv}) async {
    _checkKey(key);
    final nonce = iv ?? _algorithm.newNonce();
    if (nonce.length != ivLength) throw ArgumentError('IV must be $ivLength bytes');
    final box = await _algorithm.encrypt(plaintext, secretKey: SecretKey(key), nonce: nonce, aad: aad);
    return Sealed(nonce, [...box.cipherText, ...box.mac.bytes]);
  }

  /// The plaintext, or [DecryptionException] if anything does not match.
  static Future<List<int>> decrypt(Sealed sealed, List<int> key, {List<int> aad = const []}) async {
    _checkKey(key);
    final data = sealed.ciphertextAndTag;
    if (sealed.iv.length != ivLength || data.length < tagLength) throw DecryptionException();
    final box = SecretBox(data.sublist(0, data.length - tagLength),
        nonce: sealed.iv, mac: Mac(data.sublist(data.length - tagLength)));
    try {
      return await _algorithm.decrypt(box, secretKey: SecretKey(key), aad: aad);
    } on SecretBoxAuthenticationError {
      throw DecryptionException();
    }
  }

  static void _checkKey(List<int> key) {
    if (key.length != keyLength) throw ArgumentError('Key must be $keyLength bytes');
  }
}
