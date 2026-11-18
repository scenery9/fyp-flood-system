import 'package:flood_core/flood_core.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:local_auth/local_auth.dart';

/// Talks to the phone's own lock (fingerprint, face, PIN, pattern).
/// Tests use a fake version, so they never need a real phone.
abstract class PhoneLockChecker {
  Future<PhoneLock> status();

  /// Shows the phone's prompt. True only if the user passed it.
  Future<bool> confirm(String reason);
}

class DevicePhoneLockChecker implements PhoneLockChecker {
  DevicePhoneLockChecker([LocalAuthentication? auth]) : _auth = auth ?? LocalAuthentication();
  final LocalAuthentication _auth;

  @override
  Future<PhoneLock> status() async {
    if (kIsWeb) return PhoneLock.unsupported;
    try {
      // True when the phone has a fingerprint/face enrolled or a PIN,
      // pattern or password set as its screen lock.
      return await _auth.isDeviceSupported() ? PhoneLock.ready : PhoneLock.notSetUp;
    } catch (_) {
      // No plugin for this platform (e.g. Linux preview) or the phone refused.
      return PhoneLock.unsupported;
    }
  }

  @override
  Future<bool> confirm(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        // false = the phone also offers its PIN/pattern, not only fingerprint.
        biometricOnly: false,
        // Keeps the prompt if the user briefly leaves the app.
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      // Cancelled, too many tries, no screen lock, etc. Stay locked.
      return false;
    }
  }
}
