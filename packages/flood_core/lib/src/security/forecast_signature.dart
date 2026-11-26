import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../services/forecast_service.dart' show ForecastSource;

/// Public keys the app trusts for forecast.json, by key id (base64, 32 bytes).
///
/// Empty until the signing key is made (docs/forecast-switch-plan.md, step 2b). With no trusted key every real forecast is rejected and the
/// app keeps the practice forecast, which is the safe default.
///
/// To rotate: add the new key here, release the app, then switch the GitHub
/// secret to the new private key; remove the old id one release later.
const Map<String, String> trustedForecastKeys = {};

/// Signed messages start with this, so a signature made by the forecast key
/// can never be reused for anything other than forecast.json (domain
/// separation). The Python signer (ml/flood_ml/sign.py) uses the same bytes.
const forecastSignaturePrefix = 'FloodReady forecast.json v1\n';

/// The forecast.json bytes do not match a trusted signature.
class ForecastSignatureException implements Exception {
  ForecastSignatureException(this.message);
  final String message;
  @override
  String toString() => 'ForecastSignatureException: $message';
}

/// Checks [body] (forecast.json exactly as downloaded) against [signatureFile]
/// (forecast.json.sig: `{"alg": "Ed25519", "key_id": "...", "signature": "<base64>"}`).
///
/// Throws [ForecastSignatureException] when the file is malformed, the key id
/// is not in [trustedKeys], or the signature does not verify. Returns normally
/// only for a valid signature by a trusted key.
Future<void> verifyForecastSignature(String body, String signatureFile,
    {Map<String, String> trustedKeys = trustedForecastKeys}) async {
  final Object? j;
  try {
    j = jsonDecode(signatureFile);
  } on FormatException {
    throw ForecastSignatureException('Signature file is not JSON');
  }
  if (j is! Map) throw ForecastSignatureException('Signature file is not a JSON object');
  if (j['alg'] != 'Ed25519') throw ForecastSignatureException('Unsupported algorithm: ${j['alg']}');
  final keyId = j['key_id'];
  final key = keyId is String ? trustedKeys[keyId] : null;
  if (key == null) throw ForecastSignatureException('Untrusted key id: $keyId');
  final sig = _base64(j['signature'], 64, 'signature');
  final publicKey = _base64(key, 32, 'public key $keyId');

  final message = utf8.encode(forecastSignaturePrefix + body);
  final ok = await Ed25519().verify(
    message,
    signature: Signature(sig, publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519)),
  );
  if (!ok) throw ForecastSignatureException('Signature does not match forecast.json');
}

List<int> _base64(Object? v, int length, String what) {
  if (v is! String) throw ForecastSignatureException('Missing $what');
  final List<int> bytes;
  try {
    bytes = base64.decode(v);
  } on FormatException {
    throw ForecastSignatureException('Bad base64 in $what');
  }
  if (bytes.length != length) throw ForecastSignatureException('Wrong length for $what');
  return bytes;
}

/// forecast.json from [body], returned only when [signature] (forecast.json.sig)
/// proves it was made by the forecast job. Anything else throws, so a
/// [FallbackForecastSource] around it falls back to the practice forecast
/// instead of showing a tampered or spoofed warning.
///
/// The two files are uploaded one after the other, so for a moment they can
/// disagree; the app then shows the fallback until its next refresh.
class SignedForecastSource implements ForecastSource {
  SignedForecastSource(this.body, this.signature, {this.trustedKeys = trustedForecastKeys});
  final ForecastSource body;
  final ForecastSource signature;
  final Map<String, String> trustedKeys;

  @override
  Future<String> fetch() async {
    final results = await Future.wait([body.fetch(), signature.fetch()]);
    await verifyForecastSignature(results[0], results[1], trustedKeys: trustedKeys);
    return results[0];
  }
}
