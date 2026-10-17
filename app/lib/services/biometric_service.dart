import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

/// Platform biometrics (device unlock).
/// Uses the OS biometric prompt (fingerprint/face) to gate sensitive actions
/// like revealing the wallet. This is device-bound authentication.

/// Granular biometric failure reasons so the UI can explain what went wrong
/// instead of showing a generic "failed".
enum BiometricFailure {
  /// No biometric hardware, or the OS reports biometrics unavailable.
  notAvailable,

  /// Hardware exists but the user has not enrolled any fingerprint/face.
  /// This is the most common reason a prompt "fails" on a new device.
  notEnrolled,

  /// Too many failed attempts — the OS temporarily locked biometrics.
  lockedOut,

  /// Lockout that only clears after a device PIN/pattern/password unlock.
  permanentlyLockedOut,

  /// The user dismissed the prompt. Not an error — the UI should stay silent.
  userCanceled,

  /// Sensor error or anything else unexpected.
  unknown,
}

class BiometricAuthResult {
  final bool ok;
  final BiometricFailure? failure;
  final String? detail;

  const BiometricAuthResult._(this.ok, this.failure, this.detail);
  const BiometricAuthResult.success() : this._(true, null, null);
  const BiometricAuthResult.failed(BiometricFailure f, [String? d])
      : this._(false, f, d);

  /// User-facing message, or null when nothing should be shown (cancel).
  String? get message {
    switch (failure) {
      case null:
        return null;
      case BiometricFailure.notAvailable:
        return 'Biometrics are not available on this device.';
      case BiometricFailure.notEnrolled:
        return 'No fingerprint or face is enrolled. Add one in Settings → Security, then try again.';
      case BiometricFailure.lockedOut:
        return 'Too many attempts — biometrics are temporarily locked. Try again in 30 seconds.';
      case BiometricFailure.permanentlyLockedOut:
        return 'Biometrics are locked. Unlock your phone with your PIN or pattern first, then try again.';
      case BiometricFailure.userCanceled:
        return null;
      case BiometricFailure.unknown:
        return (detail != null && detail!.isNotEmpty)
            ? 'Biometric authentication failed ($detail). Please try again.'
            : 'Biometric authentication failed. Please try again.';
    }
  }
}

class BiometricService {
  final LocalAuthentication _auth = LocalAuthentication();

  /// Hardware + OS support check. Does NOT imply the user enrolled anything.
  Future<bool> get isAvailable async {
    try {
      return await _auth.canCheckBiometrics && await _auth.isDeviceSupported();
    } on PlatformException {
      return false;
    }
  }

  /// True when at least one fingerprint/face is actually enrolled.
  /// [LocalAuthentication.getAvailableBiometrics] returns the enrolled set.
  Future<bool> get isEnrolled async {
    try {
      final types = await _auth.getAvailableBiometrics();
      return types.isNotEmpty;
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

  /// Prompt the OS biometric dialog, with granular failure reporting.
  /// Never throws — every failure is encoded in the returned result.
  Future<BiometricAuthResult> authenticate(
      {String reason = 'Unlock Nova'}) async {
    // Check hardware first so the message is accurate on devices without it.
    if (!await isAvailable) {
      return const BiometricAuthResult.failed(BiometricFailure.notAvailable);
    }
    // Enrollment check BEFORE prompting: without it, biometricOnly prompts
    // throw NotEnrolled and the user only ever sees a generic failure.
    if (!await isEnrolled) {
      return const BiometricAuthResult.failed(BiometricFailure.notEnrolled);
    }
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
            biometricOnly: true, stickyAuth: true),
      );
      if (ok) return const BiometricAuthResult.success();
      // `false` without an exception = the user dismissed the prompt.
      return const BiometricAuthResult.failed(BiometricFailure.userCanceled);
    } on PlatformException catch (e) {
      return BiometricAuthResult.failed(_mapCode(e.code), e.code);
    } catch (e) {
      return BiometricAuthResult.failed(
          BiometricFailure.unknown, e.toString());
    }
  }

  BiometricFailure _mapCode(String code) {
    switch (code) {
      case 'NotEnrolled':
        return BiometricFailure.notEnrolled;
      case 'LockedOut':
        return BiometricFailure.lockedOut;
      case 'PermanentlyLockedOut':
        return BiometricFailure.permanentlyLockedOut;
      default:
        return BiometricFailure.unknown;
    }
  }
}
