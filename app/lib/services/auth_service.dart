import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// Firebase Auth wrapper.
///
/// - Initializes Firebase (real google-services.json required; without it
///   the app runs in demo mode and auth screens are unavailable).
/// - v1.1: sign-in is MANDATORY. There is no anonymous session — on first
///   launch with no Firebase user, the app shows the auth gate (login /
///   signup) before any other screen. Every backend call carries the
///   Firebase ID token; a 401 anywhere redirects to the gate.
class AuthService extends ChangeNotifier {
  bool firebaseReady = false;
  User? _fbUser;
  String _demoUid = '';

  bool get isDemo => !firebaseReady;

  /// True when a real Firebase user is signed in. The app gate requires this.
  bool get isSignedIn => _fbUser != null;

  String get uid {
    if (_fbUser != null) return _fbUser!.uid;
    return _demoUid;
  }

  bool get isAnonymous => _fbUser?.isAnonymous ?? true;
  String? get email => _fbUser?.email;

  Future<void> init() async {
    try {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: 'AIzaSyCt0aYGuQPmVrRGT-_jGSmCAXCqn092GkE',
          appId: '1:571086184276:android:5daa09a87000154b44f2c1',
          messagingSenderId: '571086184276',
          projectId: 'nova-dc139',
          storageBucket: 'nova-dc139.firebasestorage.app',
        ),
      );
      firebaseReady = true;
      final auth = FirebaseAuth.instance;
      // No anonymous fallback: the auth gate requires an explicit account.
      _fbUser = auth.currentUser;
      auth.authStateChanges().listen((u) {
        _fbUser = u;
        notifyListeners();
      });
    } catch (_) {
      // Demo mode: no Firebase config. Stable pseudo-uid for the session.
      firebaseReady = false;
      _demoUid = 'demo_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
    }
    notifyListeners();
  }

  Future<String?> idToken() async {
    if (!firebaseReady) return null;
    try {
      return await _fbUser?.getIdToken();
    } catch (_) {
      return null;
    }
  }

  Future<void> signUpWithEmail(String email, String password) async {
    _needFirebase();
    final auth = FirebaseAuth.instance;
    if (_fbUser == null) {
      // Fresh account (auth gate): create directly.
      await auth.createUserWithEmailAndPassword(email: email, password: password);
    } else {
      final cred = EmailAuthProvider.credential(email: email, password: password);
      try {
        // Preserve the existing uid by linking.
        await _fbUser!.linkWithCredential(cred);
      } on FirebaseAuthException catch (e) {
        if (e.code == 'email-already-in-use' || e.code == 'credential-already-in-use') {
          await auth.signInWithCredential(cred);
        } else {
          rethrow;
        }
      }
    }
    _fbUser = auth.currentUser;
    notifyListeners();
  }

  Future<void> signInWithEmail(String email, String password) async {
    _needFirebase();
    await FirebaseAuth.instance.signInWithEmailAndPassword(email: email, password: password);
    _fbUser = FirebaseAuth.instance.currentUser;
    notifyListeners();
  }

  /// Refresh the cached Firebase user (e.g. after an external sign-in
  /// flow like Google Sign-In performed outside this service).
  Future<void> refreshUser() async {
    if (firebaseReady) {
      _fbUser = FirebaseAuth.instance.currentUser;
      notifyListeners();
    }
  }

  /// Sign in with username OR email. Usernames resolve to the Firebase email
  /// via the backend (POST /api/auth/resolve).
  Future<(String, bool)> resolveIdentifier(String identifier, ApiClient api) async {
    final r = await api.post('/api/auth/resolve', {'identifier': identifier.trim()});
    return (r['email'] as String, (r['totpRequired'] as bool?) ?? false);
  }

  Future<void> signInWithIdentifier(String identifier, String password, ApiClient api) async {
    _needFirebase();
    String email = identifier.trim();
    if (!email.contains('@')) {
      final resolved = await resolveIdentifier(email, api);
      email = resolved.$1;
    }
    await signInWithEmail(email, password);
  }

  /// Sign out fully. Callers route to the auth gate afterwards — there is
  /// no anonymous fallback session in v1.1.
  Future<void> signOut() async {
    if (firebaseReady) {
      await FirebaseAuth.instance.signOut();
      _fbUser = null;
      notifyListeners();
    }
  }

  void _needFirebase() {
    if (!firebaseReady) throw StateError('Firebase not configured (demo mode)');
  }
}
