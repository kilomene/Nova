import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// Firebase Auth wrapper.
///
/// - Tries Firebase init; on failure (no google-services.json) the app
///   runs in demo mode with a stable local uid.
/// - Signs in anonymously so EVERY install has a uid: the backend requires
///   auth on all endpoints, and anonymous auth keeps logged-out browsing
///   working without friction.
/// - Email sign-up LINKS to the anonymous account, preserving the uid.
class AuthService extends ChangeNotifier {
  bool firebaseReady = false;
  User? _fbUser;
  String _demoUid = '';

  bool get isDemo => !firebaseReady;
  String get uid {
    if (_fbUser != null) return _fbUser!.uid;
    return _demoUid;
  }

  bool get isAnonymous => _fbUser?.isAnonymous ?? true;
  String? get email => _fbUser?.email;

  Future<void> init() async {
    try {
      await Firebase.initializeApp();
      firebaseReady = true;
      final auth = FirebaseAuth.instance;
      if (auth.currentUser == null) {
        await auth.signInAnonymously();
      }
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
    final cred = EmailAuthProvider.credential(email: email, password: password);
    try {
      // Preserve the anonymous uid by linking.
      await _fbUser?.linkWithCredential(cred);
    } on FirebaseAuthException catch (e) {
      if (e.code == 'email-already-in-use' || e.code == 'credential-already-in-use') {
        await FirebaseAuth.instance.signInWithCredential(cred);
      } else {
        rethrow;
      }
    }
    _fbUser = FirebaseAuth.instance.currentUser;
    notifyListeners();
  }

  Future<void> signInWithEmail(String email, String password) async {
    _needFirebase();
    await FirebaseAuth.instance.signInWithEmailAndPassword(email: email, password: password);
    _fbUser = FirebaseAuth.instance.currentUser;
    notifyListeners();
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

  Future<void> signOut() async {
    if (firebaseReady) {
      await FirebaseAuth.instance.signOut();
      await FirebaseAuth.instance.signInAnonymously();
      _fbUser = FirebaseAuth.instance.currentUser;
      notifyListeners();
    }
  }

  void _needFirebase() {
    if (!firebaseReady) throw StateError('Firebase not configured (demo mode)');
  }
}
