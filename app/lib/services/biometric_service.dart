import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// Platform biometrics (passkey-style device unlock).
/// Uses the OS biometric prompt (fingerprint/face) to gate sensitive actions
/// like revealing the wallet. This is device-bound authentication — not a
/// synced WebAuthn passkey (phase 2).
class BiometricService {
  final LocalAuthentication _auth = LocalAuthentication();

  Future<bool> get isAvailable async {
    try {
      return await _auth.canCheckBiometrics && await _auth.isDeviceSupported();
    } on PlatformException {
      return false;
    }
  }

  Future<List<BiometricType>> get availableTypes async {
    try {
      return await _auth.getAvailableBiometrics();
    } on PlatformException {
      return [];
    }
  }

  /// Prompt the OS biometric dialog. Returns true if authenticated.
  Future<bool> authenticate({String reason = 'Unlock Nova'}) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(biometricOnly: true, stickyAuth: true),
      );
    } on PlatformException {
      return false;
    }
  }
}
