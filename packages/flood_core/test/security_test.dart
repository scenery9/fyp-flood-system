import 'dart:convert';
import 'dart:io';

import 'package:flood_core/flood_core.dart';
import 'package:test/test.dart';

// Fixtures in test/fixtures/signed were made by Node's own crypto (an
// independent Ed25519 implementation) from a fixed TEST key; the Python
// signer's tests check it makes the very same signature (ml/tests/test_sign.py).

class _Fixed implements ForecastSource {
  _Fixed(this.body, {this.fail = false});
  final String body;
  final bool fail;
  @override
  Future<String> fetch() async => fail ? throw StateError('no internet') : body;
}

List<int> hex(String h) => [for (var i = 0; i < h.length; i += 2) int.parse(h.substring(i, i + 2), radix: 16)];

void main() {
  final dir = 'test/fixtures/signed';
  final body = File('$dir/forecast.json').readAsStringSync();
  final sigFile = File('$dir/forecast.json.sig').readAsStringSync();
  final keys = (jsonDecode(File('$dir/keys.json').readAsStringSync()) as Map).cast<String, String>();
  final trusted = {keys['test_key_id']!: keys['test_public_key']!};
  String sig({String? alg, String? keyId, String? signature}) => jsonEncode({
        'alg': alg ?? 'Ed25519',
        'key_id': keyId ?? keys['test_key_id'],
        'signature': signature ?? (jsonDecode(sigFile) as Map)['signature'],
      });
  Matcher rejected(String why) =>
      throwsA(isA<ForecastSignatureException>().having((e) => e.message, 'message', contains(why)));

  group('TP97 forecast.json Ed25519 signature', () {
    test('a file signed by a trusted key is accepted', () async {
      await verifyForecastSignature(body, sigFile, trustedKeys: trusted);
    });
    test('one changed character in forecast.json is rejected', () async {
      final tampered = body.replaceFirst('"predicted_level_m": ', '"predicted_level_m": 9');
      expect(tampered, isNot(body));
      expect(verifyForecastSignature(tampered, sigFile, trustedKeys: trusted), rejected('does not match'));
    });
    test('an added space or line ending is rejected (exact bytes are signed)', () async {
      expect(verifyForecastSignature('$body ', sigFile, trustedKeys: trusted), rejected('does not match'));
      expect(verifyForecastSignature(body.replaceAll('\n', '\r\n'), sigFile, trustedKeys: trusted),
          rejected('does not match'));
    });
    test('a signature by an attacker key is rejected, even under the trusted key id', () async {
      expect(verifyForecastSignature(body, sig(signature: keys['attacker_signature']), trustedKeys: trusted),
          rejected('does not match'));
    });
    test('an attacker cannot add their own key id', () async {
      expect(verifyForecastSignature(body, sig(keyId: 'attacker', signature: keys['attacker_signature']),
          trustedKeys: trusted), rejected('Untrusted key id'));
    });
    test('a signature made without the FloodReady prefix is rejected (domain separation)', () async {
      expect(verifyForecastSignature(body, sig(signature: keys['signature_without_prefix']), trustedKeys: trusted),
          rejected('does not match'));
    });
    test('the app trusts no key until the real one is added: every file is rejected', () async {
      expect(trustedForecastKeys, isEmpty);
      expect(verifyForecastSignature(body, sigFile), rejected('Untrusted key id'));
    });
    test('malformed signature files are rejected', () async {
      for (final (file, why) in [
        ('', 'not JSON'),
        ('[]', 'not a JSON object'),
        (sig(alg: 'RSA'), 'Unsupported algorithm'),
        (sig(alg: 'none'), 'Unsupported algorithm'),
        (sig(signature: 'not base64!'), 'Bad base64'),
        (sig(signature: base64.encode(List.filled(63, 1))), 'Wrong length'),
        (jsonEncode({'alg': 'Ed25519', 'key_id': keys['test_key_id']}), 'Missing signature'),
      ]) {
        expect(verifyForecastSignature(body, file, trustedKeys: trusted), rejected(why), reason: file);
      }
    });
  });

  group('TP98 signed forecast falls back to the practice forecast', () {
    final practice = _Fixed('{"practice": true}');
    final clock = () => DateTime.utc(2026, 11, 17, 3, 30); // fixture made 03:00Z
    Future<String> via(String b, String s, {bool sigMissing = false}) => FallbackForecastSource(
          SignedForecastSource(_Fixed(b), _Fixed(s, fail: sigMissing), trustedKeys: trusted),
          practice,
          clock: clock,
        ).fetch();

    test('a correctly signed real forecast is shown', () async {
      expect(await via(body, sigFile), body);
    });
    test('tampered, unsigned or wrongly signed files show the practice forecast instead', () async {
      expect(await via(body.replaceFirst('"predicted_level_m": ', '"predicted_level_m": 9'), sigFile), practice.body);
      expect(await via(body, sigFile, sigMissing: true), practice.body);
      expect(await via(body, sig(signature: keys['attacker_signature'])), practice.body);
    });
  });

  group('TP99 AES-256-GCM helper', () {
    test('matches the published test vector (McGrew & Viega test case 14)', () async {
      final s = await AesGcmHelper.encrypt(List.filled(16, 0), List.filled(32, 0), iv: List.filled(12, 0));
      expect(s.ciphertextAndTag, hex('cea7403d4d606b6e074ec5d3baf39d18' 'd0d1c8a799996bf0265b98b5d48ab919'));
    });
    test('round trip with associated data', () async {
      final key = await AesGcmHelper.newKey();
      final s = await AesGcmHelper.encrypt(utf8.encode('hello'), key, aad: utf8.encode('ctx'));
      expect(utf8.decode(await AesGcmHelper.decrypt(s, key, aad: utf8.encode('ctx'))), 'hello');
    });
    test('new keys and IVs are random each time', () async {
      final key = await AesGcmHelper.newKey();
      expect(key, hasLength(32));
      expect(await AesGcmHelper.newKey(), isNot(key));
      final a = await AesGcmHelper.encrypt([1, 2, 3], key), b = await AesGcmHelper.encrypt([1, 2, 3], key);
      expect(a.iv, hasLength(12));
      expect(a.iv, isNot(b.iv));
      expect(a.ciphertextAndTag, isNot(b.ciphertextAndTag));
    });
    test('wrong key, wrong associated data, changed byte or short input all fail the same way', () async {
      final key = await AesGcmHelper.newKey();
      final s = await AesGcmHelper.encrypt([1, 2, 3], key, aad: [9]);
      final flipped = [...s.ciphertextAndTag]..[0] ^= 1;
      expect(AesGcmHelper.decrypt(s, await AesGcmHelper.newKey(), aad: [9]), throwsA(isA<DecryptionException>()));
      expect(AesGcmHelper.decrypt(s, key, aad: [8]), throwsA(isA<DecryptionException>()));
      expect(AesGcmHelper.decrypt(Sealed(s.iv, flipped), key, aad: [9]), throwsA(isA<DecryptionException>()));
      expect(AesGcmHelper.decrypt(Sealed(s.iv, [1, 2]), key), throwsA(isA<DecryptionException>()));
      expect(() => Sealed.fromBase64('!!', 'AA=='), throwsA(isA<DecryptionException>()));
    });
    test('keys and IVs of the wrong size are refused', () async {
      expect(AesGcmHelper.encrypt([1], List.filled(16, 0)), throwsArgumentError);
      expect(AesGcmHelper.encrypt([1], List.filled(32, 0), iv: List.filled(16, 0)), throwsArgumentError);
    });
  });

  group('TP100 family invite and end-to-end encrypted location', () {
    final fix = SharedLocation(lat: 3.0412, lon: 101.4458, batteryPct: 64, at: DateTime.utc(2026, 11, 27, 9, 15));
    const g = 'group-1', m = 'member-a';

    test('invite link keeps the key in the #fragment only, and reads back', () async {
      final key = await FamilyKey.generate(version: 2);
      final uri = FamilyInvite('ABCD1234efgh', key).toUri();
      expect(uri.toString(), startsWith('floodready://family/join?code=ABCD1234efgh&v=2#key='));
      expect(uri.query, isNot(contains(key.toBase64Url())));
      expect(uri.removeFragment().toString(), isNot(contains(key.toBase64Url())));
      final back = FamilyInvite.parse(Uri.parse(uri.toString()));
      expect(back.code, 'ABCD1234efgh');
      expect(back.key.version, 2);
      expect(back.key.bytes, key.bytes);
    });
    test('damaged or unsafe invite links are refused', () async {
      final k = (await FamilyKey.generate()).toBase64Url();
      for (final link in [
        'https://family/join?code=ABCD1234&v=1#key=$k',
        'floodready://family/join?code=AB&v=1#key=$k',
        'floodready://family/join?code=ABCD1234#key=$k',
        'floodready://family/join?code=ABCD1234&v=1',
        'floodready://family/join?code=ABCD1234&v=1#key=short',
        'floodready://family/join?code=ABCD1234&v=1&key=$k',
      ]) {
        expect(() => FamilyInvite.parse(Uri.parse(link)), throwsA(isA<ValidationException>()), reason: link);
      }
    });
    test('location round trip; the stored text reveals nothing readable', () async {
      final key = await FamilyKey.generate();
      final e = await FamilyLocationCrypto.encrypt(fix, key, groupId: g, memberId: m);
      expect(utf8.decode(base64.decode(e.ciphertext), allowMalformed: true), isNot(contains('101.4')));
      final back = await FamilyLocationCrypto.decrypt(e, key, groupId: g, memberId: m);
      expect([back.lat, back.lon, back.batteryPct, back.at], [fix.lat, fix.lon, 64, fix.at]);
    });
    test('a row copied to another member, another group or an old key version does not open', () async {
      final key = await FamilyKey.generate();
      final e = await FamilyLocationCrypto.encrypt(fix, key, groupId: g, memberId: m);
      Future<SharedLocation> open(EncryptedLocation x, FamilyKey k, {String group = g, String member = m}) =>
          FamilyLocationCrypto.decrypt(x, k, groupId: group, memberId: member);
      final fails = throwsA(isA<DecryptionException>());
      expect(open(e, key, member: 'member-b'), fails);
      expect(open(e, key, group: 'group-2'), fails);
      expect(open(e, FamilyKey(key.bytes, 2)), fails);
      expect(open(EncryptedLocation(ciphertext: e.ciphertext, iv: e.iv, keyVersion: 2), FamilyKey(key.bytes, 2)), fails);
      expect(open(e, await FamilyKey.generate()), fails);
    });
    test('bad locations are refused before encrypting', () {
      expect(() => SharedLocation(lat: 91, lon: 0, at: DateTime.now()), throwsA(isA<ValidationException>()));
      expect(() => SharedLocation(lat: 0, lon: 0, at: DateTime.now(), batteryPct: 101), throwsA(isA<ValidationException>()));
      expect(() => FamilyKey(List.filled(16, 0), 1), throwsA(isA<ValidationException>()));
    });
  });
}
