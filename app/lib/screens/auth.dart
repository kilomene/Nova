import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../services/api_client.dart';
import '../state/app_state.dart';
import 'legal.dart';
import 'shell.dart';

/// Splash: boots services, then enters the app.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _fade;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _opacity = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _fade, curve: Curves.easeOut),
    );
    _fade.forward();
    _boot();
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    final state = context.read<AppState>();
    // Minimum splash display for premium feel (not a loading spinner).
    final minDisplay = Future.delayed(const Duration(milliseconds: 900));
    try {
      // Phase 1 only: Firebase + device + client VPN check (no auth needed).
      // Timeout so a slow network never hangs the splash.
      await state.boot().timeout(const Duration(seconds: 8));
    } catch (_) {}
    await minDisplay;
    if (!mounted) return;
    // Strict anti-VPN: full-screen block until the network is clean.
    // Client layer (tunnel interfaces) + server layer (egress-IP blacklist).
    if (state.vpnDetected) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const NetworkBlockedScreen()));
      return;
    }
    // MANDATORY auth gate (v1.1): on first launch with no Firebase user,
    // show login/signup before ANY other screen. No wandering into
    // Upload/Wallet/etc. unauthenticated.
    if (!state.auth.isSignedIn && state.auth.firebaseReady) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const AuthScreen(gate: true)),
      );
      return;
    }
    // Signed in (or demo mode): full init, then enter.
    try {
      await state.init().timeout(const Duration(seconds: 10));
    } catch (_) {}
    if (!mounted) return;
    if (state.vpnDetected || state.networkBlocked) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const NetworkBlockedScreen()));
      return;
    }
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const MainShell()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: FadeTransition(
        opacity: _opacity,
        child: const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              NovaLogo(size: 120),
              SizedBox(height: 16),
              Text('Nova', style: TextStyle(fontSize: 40, fontWeight: FontWeight.w800, color: Colors.white)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Full-screen block shown when a VPN/proxy/Tor network is detected.
/// The app does not function until the network is clean.
class NetworkBlockedScreen extends StatefulWidget {
  const NetworkBlockedScreen({super.key});

  @override
  State<NetworkBlockedScreen> createState() => _NetworkBlockedScreenState();
}

class _NetworkBlockedScreenState extends State<NetworkBlockedScreen> {
  bool _checking = false;

  Future<void> _retry() async {
    setState(() => _checking = true);
    final state = context.read<AppState>();
    await state.checkVpnInterface();
    if (!state.isDemo) {
      try {
        await state.api.get('/api/security/network-check');
        state.networkBlocked = false;
      } on ApiException catch (e) {
        if (e.status == 403) state.networkBlocked = true;
      } catch (_) {}
    } else {
      state.networkBlocked = false;
    }
    if (!mounted) return;
    setState(() => _checking = false);
    if (!state.vpnDetected && !state.networkBlocked) {
      // Re-run the full boot decision (auth gate included).
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const SplashScreen()));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Still blocked — disconnect the VPN/proxy and try again.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.vpn_lock, size: 72, color: Colors.redAccent),
              const SizedBox(height: 16),
              const Text('Network blocked', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              const Text(
                'Nova detected a VPN, proxy, or Tor connection. For the safety of the marketplace and P2P trading, Nova only works on a direct connection.\n\nDisconnect the VPN/proxy and tap retry.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70),
              ),
              SizedBox(height: 24),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.primary, foregroundColor: Colors.black),
                onPressed: _checking ? null : _retry,
                child: Text(_checking ? 'Checking…' : 'Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Animated Nova logo: the white glitch-ℕ on black (assets/nova-logo.png).
///
/// A 5-second real-time loop (AnimationController.repeat — not one-shot):
/// scale breathes 1.00 → 1.05 → 1.00, the mark wobbles ±0.04 rad, glitch
/// bursts fire twice per loop (fast horizontal jitter + a displaced
/// horizontal slice), and a lemon-green/pink glow pulses behind it.
/// It feels alive like a video loop rather than a static splash image.
class NovaLogo extends StatefulWidget {
  final double size;
  const NovaLogo({super.key, required this.size});

  @override
  State<NovaLogo> createState() => _NovaLogoState();
}

class _NovaLogoState extends State<NovaLogo> with SingleTickerProviderStateMixin {
  late final AnimationController _loop;

  // The logo's own glitch-shadow colors: lemon-green + pink.
  static const _lemon = Color(0xFFBFFF3C);
  static const _pink = Color(0xFFFF5C8A);

  @override
  void initState() {
    super.initState();
    _loop = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 5),
    )..repeat();
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final logo = Image.asset(
      'assets/nova-logo.png',
      width: widget.size,
      height: widget.size,
      fit: BoxFit.contain,
    );
    return AnimatedBuilder(
      animation: _loop,
      builder: (context, _) {
        final t = _loop.value; // 0..1 across the 5s loop
        final a = t * 2 * pi;
        // 1) breathing scale: 1.00 → 1.05 → 1.00 (smooth cosine).
        final scale = 1.0 + 0.025 * (1 - cos(a));
        // 2) gentle rotation wobble, two full cycles per loop.
        final wobble = 0.04 * sin(2 * a + 0.6);
        // 3) glitch bursts: envelope peaks twice per loop; fast jitter inside.
        final env = pow(max(0.0, sin(2 * a)), 6).toDouble();
        final jitter = 7.0 * env * sin(t * 120 * pi);
        // 4) glow pulses lemon-green → pink across the loop.
        final glowColor = Color.lerp(_lemon, _pink, 0.5 + 0.5 * sin(a))!;
        final glowBlur = 26 + 18 * env + 8 * sin(a);
        // 5) displaced horizontal slice during strong bursts.
        final slice = env > 0.5;
        final sliceY = (((t * 7.3) % 0.7) * 2 - 1).clamp(-0.82, 0.82);
        return Transform.scale(
          scale: scale,
          child: Transform.rotate(
            angle: wobble,
            child: Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: glowColor.withValues(alpha: 0.35),
                    blurRadius: glowBlur,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  logo,
                  // Jittered ghost copy during bursts (double-image glitch).
                  if (env > 0.02)
                    Transform.translate(
                      offset: Offset(jitter * 0.6, 0),
                      child: logo,
                    ),
                  // Displaced horizontal slice during strong bursts.
                  if (slice)
                    ClipRect(
                      child: Align(
                        alignment: Alignment(0, sliceY),
                        heightFactor: 0.16,
                        child: Transform.translate(
                          offset: Offset(jitter, 0),
                          child: SizedBox(
                            width: widget.size,
                            height: widget.size,
                            child: logo,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Email auth (username or email + password).
///
/// v1.1: this is the MANDATORY first-launch gate. With [gate]=true the
/// screen cannot be dismissed and a successful sign-in routes into the app
/// (instead of popping). [notice] shows a friendly message above the form
/// (e.g. "Please log in to continue" after a 401).
class AuthScreen extends StatefulWidget {
  final bool gate;
  final String? notice;
  const AuthScreen({super.key, this.gate = false, this.notice});

  /// True while a gate-mode AuthScreen is on screen. The global 401
  /// handler checks this so gates never stack.
  static bool gateOpen = false;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  _AuthStep _step = _AuthStep.method;
  bool _signup = true;
  bool _useUsername = false;
  final _identifier = TextEditingController();
  final _email = TextEditingController();
  final _pass = TextEditingController();
  final _totp = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.gate) AuthScreen.gateOpen = true;
  }

  @override
  void dispose() {
    if (widget.gate) AuthScreen.gateOpen = false;
    _identifier.dispose();
    _email.dispose();
    _pass.dispose();
    _totp.dispose();
    super.dispose();
  }

  /// After a successful sign-in: full state init, then enter the app
  /// (gate mode) or return to the previous screen.
  Future<void> _finish(AppState state) async {
    await state.init();
    if (!mounted) return;
    if (widget.gate) {
      if (state.vpnDetected || state.networkBlocked) {
        Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const NetworkBlockedScreen()));
      } else {
        Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const MainShell()));
      }
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _doTotpChallenge(AppState state, String identifier) async {
    // After Firebase sign-in, check if TOTP is required.
    // Fail CLOSED: if we cannot determine the 2FA status, do not silently
    // skip the challenge — that would let an attacker with a stolen password
    // bypass 2FA by blocking this one request.
    try {
      final r = await state.api.post('/api/auth/resolve', {'identifier': identifier});
      if ((r['totpRequired'] as bool?) == true) {
        setState(() => _step = _AuthStep.totp);
        return;
      }
    } catch (e) {
      setState(() => _error = e is ApiException
          ? e.message
          : 'Could not verify two-factor status. Check your connection and try again.');
      return;
    }
    await _finish(state);
  }

  /// Google Sign-In → Firebase credential. The Firebase ID token then flows
  /// through the normal bearer-token path untouched. No Apple/Facebook
  /// buttons exist anywhere in the app (user's spec).
  static bool _gsiInitialized = false;

  Future<void> _signInWithGoogle(AppState state) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!_gsiInitialized) {
        // Timeout after 10s — initialize() can hang silently on misconfiguration
        await GoogleSignIn.instance.initialize().timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw Exception('Google Sign-In timed out. Please check your internet connection and try again.'),
        );
        _gsiInitialized = true;
      }
      final account = await GoogleSignIn.instance.authenticate().timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw Exception('Google Sign-In timed out. Please try again.'),
      );
      final credential = GoogleAuthProvider.credential(
        idToken: account.authentication.idToken,
      );
      await FirebaseAuth.instance.signInWithCredential(credential);
      await state.auth.refreshUser();
      await _doTotpChallenge(state, account.email);
    } on GoogleSignInException catch (e) {
      // User dismissed the account picker: not an error.
      if (e.code == GoogleSignInExceptionCode.canceled) return;
      setState(() => _error = _googleSetupMessage(e.code));
    } on FirebaseAuthException catch (e) {
      setState(() => _error = _googleErrorMessage(e.code));
    } catch (e) {
      setState(() => _error =
          e is ApiException ? e.message : 'Google sign-in failed. Please try again or use email.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _googleSetupMessage(GoogleSignInExceptionCode code) {
    switch (code) {
      case GoogleSignInExceptionCode.clientConfigurationError:
      case GoogleSignInExceptionCode.providerConfigurationError:
        return 'Google sign-in is being set up, please use email for now.';
      default:
        return 'Google sign-in failed. Please try again or use email.';
    }
  }

  String _googleErrorMessage(String code) {
    switch (code) {
      case 'operation-not-allowed':
        return 'Google sign-in is being set up, please use email for now.';
      case 'account-exists-with-different-credential':
        return 'This email is already registered. Log in with email instead.';
      case 'invalid-credential':
        return 'Google sign-in failed. Please try again or use email.';
      case 'user-disabled':
        return 'This account has been disabled. Contact support.';
      default:
        return 'Google sign-in failed. Please try again or use email.';
    }
  }

  Future<void> _submit(AppState state) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_signup) {
        final email = _useUsername ? _email.text.trim() : _identifier.text.trim();
        if (!email.contains('@')) throw ApiException(400, 'invalid_email');
        if (_pass.text.length < 6) throw ApiException(400, 'weak_password');
        await state.auth.signUpWithEmail(email, _pass.text);
        // Claim the chosen username/handle right away (best effort).
        if (_useUsername && _identifier.text.trim().isNotEmpty) {
          try {
            await state.api.post('/api/users/sync', {
              'username': _identifier.text.trim().toLowerCase(),
              'handle': _identifier.text.trim().toLowerCase(),
            });
          } catch (_) {}
        }
        await _finish(state);
      } else {
        if (_useUsername) {
          await state.auth.signInWithIdentifier(_identifier.text.trim(), _pass.text, state.api);
        } else {
          await state.auth.signInWithEmail(_identifier.text.trim(), _pass.text);
        }
        await _doTotpChallenge(state, _identifier.text.trim());
      }
    } catch (e) {
      setState(() => _error =
          e is ApiException ? e.message : 'Something went wrong. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verifyTotp(AppState state) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await state.api
          .post('/api/auth/totp/challenge', {'uid': state.auth.uid, 'code': _totp.text.trim()});
      if ((r['ok'] as bool?) != true) throw ApiException(400, 'invalid_code');
      await _finish(state);
    } catch (e) {
      setState(() => _error =
          e is ApiException ? e.message : 'Verification failed. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _openLegal(int tab) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => LegalScreen(initialTab: tab)));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    Widget body;
    switch (_step) {
      case _AuthStep.method:
        body = _buildMethodStep(state);
        break;
      case _AuthStep.credentials:
        body = _buildCredentialsStep(state);
        break;
      case _AuthStep.totp:
        body = _buildTotpStep(state);
        break;
    }
    final page = Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: body,
        ),
      ),
      bottomNavigationBar: _step == _AuthStep.method ? _footerToggle() : null,
    );
    // Gate mode: the back button must not escape the login requirement.
    if (widget.gate) return PopScope(canPop: false, child: page);
    return page;
  }

  // ---------------- step 1: choose a method (TikTok structure) ----------------

  Widget _buildMethodStep(AppState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 36),
        const NovaLogo(size: 72),
        const SizedBox(height: 28),
        Text(
          _signup ? 'Sign up for Nova' : 'Log in to Nova',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: Colors.white),
        ),
        if (widget.notice != null) ...[
          SizedBox(height: 10),
          Text(
            widget.notice!,
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600),
          ),
        ],
        const SizedBox(height: 10),
        const Text(
          'Short video, marketplace, wallet and P2P — one account for it all.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white60, fontSize: 14),
        ),
        const SizedBox(height: 36),
        _goldButton(
          'Continue with email',
          _busy
              ? null
              : () => setState(() {
                    _useUsername = false;
                    _step = _AuthStep.credentials;
                    _error = null;
                  }),
        ),
        const SizedBox(height: 18),
        const _OrDivider(),
        const SizedBox(height: 18),
        _optionRow(
          icon: const _GoogleGIcon(),
          label: 'Continue with Google',
          onTap: _busy ? null : () => _signInWithGoogle(state),
        ),
        SizedBox(height: 12),
        _optionRow(
          icon: Icon(Icons.person_outline, color: Theme.of(context).colorScheme.primary),
          label: 'Continue with username',
          onTap: () => setState(() {
            _useUsername = true;
            _step = _AuthStep.credentials;
            _error = null;
          }),
        ),
        if (AppConfig.demoMode)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: Text(
              'Demo mode: Firebase is not configured — this screen is unavailable.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38),
            ),
          ),
        const Spacer(),
        _legalSmallPrint(),
        const SizedBox(height: 8),
      ],
    );
  }

  // ---------------- step 2: credentials ----------------

  Widget _buildCredentialsStep(AppState state) {
    final idLabel = _useUsername ? 'Username' : 'Email';
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: _busy
                  ? null
                  : () => setState(() {
                        _step = _AuthStep.method;
                        _error = null;
                      }),
            ),
          ),
          Text(
            _signup ? 'Sign up for Nova' : 'Log in to Nova',
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: Colors.white),
          ),
          const SizedBox(height: 6),
          Text(
            _useUsername
                ? (_signup ? 'Pick a username for your Nova account.' : 'Enter your username and password.')
                : 'Enter your email and password.',
            style: const TextStyle(color: Colors.white60, fontSize: 14),
          ),
          const SizedBox(height: 28),
          TextField(
            controller: _identifier,
            keyboardType: _useUsername ? TextInputType.text : TextInputType.emailAddress,
            autocorrect: false,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
                labelText: idLabel, labelStyle: const TextStyle(color: Colors.white54)),
          ),
          if (_signup && _useUsername)
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                  labelText: 'Email', labelStyle: TextStyle(color: Colors.white54)),
            ),
          TextField(
            controller: _pass,
            obscureText: true,
            style: const TextStyle(color: Colors.white),
            decoration: const InputDecoration(
                labelText: 'Password (min 6)', labelStyle: TextStyle(color: Colors.white54)),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ],
          const SizedBox(height: 28),
          _goldButton(_busy ? 'Please wait…' : (_signup ? 'Create account' : 'Log in'),
              _busy ? null : () => _submit(state)),
        ],
      ),
    );
  }

  // ---------------- step 3: TOTP ----------------

  Widget _buildTotpStep(AppState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 36),
        const NovaLogo(size: 64),
        const SizedBox(height: 24),
        const Text('Two-factor authentication',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white)),
        const SizedBox(height: 8),
        const Text('Enter the 6-digit code from your authenticator app.',
            textAlign: TextAlign.center, style: TextStyle(color: Colors.white60)),
        const SizedBox(height: 24),
        TextField(
          controller: _totp,
          keyboardType: TextInputType.number,
          maxLength: 6,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 28, letterSpacing: 10),
          decoration: const InputDecoration(
              labelText: '6-digit code', labelStyle: TextStyle(color: Colors.white54)),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.redAccent)),
        ],
        const SizedBox(height: 24),
        _goldButton(_busy ? 'Please wait…' : 'Verify', _busy ? null : () => _verifyTotp(state)),
      ],
    );
  }

  // ---------------- shared pieces ----------------

  Widget _goldButton(String label, VoidCallback? onTap) {
    return SizedBox(
      height: 52,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.primary,
          foregroundColor: Colors.black,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        onPressed: onTap,
        child: Text(label),
      ),
    );
  }

  Widget _optionRow({required Widget icon, required String label, required VoidCallback? onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: const Color(0xFF161616),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          children: [
            SizedBox(width: 24, height: 24, child: Center(child: icon)),
            const SizedBox(width: 14),
            // Flexible (not Expanded) + ellipsis: the label can never push
            // the chevron out or overlap it on narrow screens.
            Flexible(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, color: Colors.white38),
          ],
        ),
      ),
    );
  }

  Widget _legalSmallPrint() {
    final gold = Theme.of(context).colorScheme.primary;
    return RichText(
      textAlign: TextAlign.center,
      text: TextSpan(
        style: const TextStyle(color: Colors.white38, fontSize: 12, height: 1.5),
        children: [
          const TextSpan(text: 'By continuing, you agree to our '),
          TextSpan(
            text: 'Terms of Service',
            style: TextStyle(color: gold, decoration: TextDecoration.underline),
            recognizer: TapGestureRecognizer()..onTap = () => _openLegal(0),
          ),
          const TextSpan(text: ' and acknowledge our '),
          TextSpan(
            text: 'Privacy Policy',
            style: TextStyle(color: gold, decoration: TextDecoration.underline),
            recognizer: TapGestureRecognizer()..onTap = () => _openLegal(1),
          ),
          const TextSpan(text: '.'),
        ],
      ),
    );
  }

  Widget _footerToggle() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 18, top: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _signup ? 'Already have an account? ' : "Don't have an account? ",
              style: const TextStyle(color: Colors.white60, fontSize: 14),
            ),
            GestureDetector(
              onTap: () => setState(() {
                _signup = !_signup;
                _step = _AuthStep.method;
                _error = null;
              }),
              child: Text(
                _signup ? 'Log in' : 'Sign up',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.primary, fontSize: 14, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Auth flow steps.
enum _AuthStep { method, credentials, totp }

/// The "or" divider between primary and secondary auth options.
class _OrDivider extends StatelessWidget {
  const _OrDivider();

  @override
  Widget build(BuildContext context) {
    return const Row(
      children: [
        Expanded(child: Divider(color: Colors.white12)),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 12),
          child: Text('or', style: TextStyle(color: Colors.white38, fontSize: 13)),
        ),
        Expanded(child: Divider(color: Colors.white12)),
      ],
    );
  }
}

/// PIN setup: gates wallet creation. Shown only after KYC is verified.
class PinSetupScreen extends StatefulWidget {
  const PinSetupScreen({super.key});

  @override
  State<PinSetupScreen> createState() => _PinSetupScreenState();
}

class _PinSetupScreenState extends State<PinSetupScreen> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Create wallet PIN')),
      body: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.lock_outline, size: 56, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            const Text('Your wallet PIN encrypts your keys on this device.',
                style: TextStyle(color: Colors.white, fontSize: 16)),
            const SizedBox(height: 8),
            const Text(
              'Nova servers only ever store the encrypted backup — never your PIN or your keys. If you forget the PIN, the wallet cannot be recovered.',
              style: TextStyle(color: Colors.white60),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _pin,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 12,
              style: const TextStyle(color: Colors.white, fontSize: 24, letterSpacing: 8),
              decoration: const InputDecoration(labelText: 'New PIN (min 4)', labelStyle: TextStyle(color: Colors.white54)),
            ),
            TextField(
              controller: _confirm,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: 12,
              style: const TextStyle(color: Colors.white, fontSize: 24, letterSpacing: 8),
              decoration: const InputDecoration(labelText: 'Confirm PIN', labelStyle: TextStyle(color: Colors.white54)),
            ),
            if (_error != null) ...[
              SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: Colors.redAccent)),
            ],
            SizedBox(height: 24),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.primary, foregroundColor: Colors.black),
              onPressed: _busy
                  ? null
                  : () async {
                      if (_pin.text != _confirm.text) {
                        setState(() => _error = 'PINs do not match.');
                        return;
                      }
                      setState(() {
                        _busy = true;
                        _error = null;
                      });
                      try {
                        await state.wallet.create(pin: _pin.text, api: state.api, kyc: state.kyc);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Wallet created. Keys encrypted on this device.')),
                          );
                          Navigator.of(context).pop(true);
                        }
                      } catch (e) {
                        setState(() => _error = e is ApiException ? e.message : 'Wallet creation failed. Please try again.');
                      } finally {
                        if (mounted) setState(() => _busy = false);
                      }
                    },
              child: Text(_busy ? 'Generating…' : 'Generate my wallet'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Google "G" mark drawn in code (no brand assets bundled). Used only for
/// the "Continue with Google" sign-in row, per Google's sign-in branding.
class _GoogleGIcon extends StatelessWidget {
  const _GoogleGIcon();

  @override
  Widget build(BuildContext context) {
    return const CustomPaint(size: Size(22, 22), painter: _GPainter());
  }
}

class _GPainter extends CustomPainter {
  const _GPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = size.width / 2 * 0.92;
    const red = Color(0xFFEA4335);
    const blue = Color(0xFF4285F4);
    const yellow = Color(0xFFFBBC05);
    const green = Color(0xFF34A853);
    const d = 0.0174533; // deg -> rad

    void arc(double startDeg, double sweepDeg, Color color) {
      canvas.drawArc(
        Rect.fromCircle(center: Offset(cx, cy), radius: r),
        startDeg * d,
        sweepDeg * d,
        false,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = r * 0.52,
      );
    }

    arc(-150, 120, red); // top
    arc(-30, 40, blue); // upper right
    arc(10, 110, green); // bottom
    arc(120, 90, yellow); // lower left
    // The horizontal bar of the G.
    canvas.drawRect(
      Rect.fromLTRB(cx - r * 0.1, cy - r * 0.26, cx + r * 1.05, cy + r * 0.26),
      Paint()..color = blue,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
