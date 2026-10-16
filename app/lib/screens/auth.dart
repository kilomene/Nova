import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../services/api_client.dart';
import '../state/app_state.dart';
import 'shell.dart';

/// Splash: boots services, then enters the app.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final state = context.read<AppState>();
    try {
      await state.init();
    } catch (_) {}
    if (!mounted) return;
    // Strict anti-VPN: full-screen block until the network is clean.
    // Client layer (tunnel interfaces) + server layer (egress-IP blacklist).
    if (state.vpnDetected || state.networkBlocked) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const NetworkBlockedScreen()));
      return;
    }
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const MainShell()));
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _NovaMark(size: 84),
            SizedBox(height: 16),
            Text('Nova', style: TextStyle(fontSize: 40, fontWeight: FontWeight.w800, color: Colors.white)),
            SizedBox(height: 24),
            CircularProgressIndicator(color: Color(0xFFFFC107)),
          ],
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
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const MainShell()));
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
              const SizedBox(height: 24),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black),
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

/// Original Nova mark: a gold "N" burst. Not affiliated with any other brand.
class _NovaMark extends StatelessWidget {
  final double size;
  const _NovaMark({required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFFFFD54F), Color(0xFFFF8F00)]),
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      child: Center(
        child: Text('N', style: TextStyle(fontSize: size * 0.55, fontWeight: FontWeight.w900, color: Colors.black87)),
      ),
    );
  }
}

/// Email auth. Anonymous browsing works without this screen; it appears
/// from Settings/Profile when the user wants a permanent account.
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _identifier = TextEditingController();
  final _pass = TextEditingController();
  final _totp = TextEditingController();
  bool _signup = true;
  bool _busy = false;
  bool _needTotp = false;
  String? _error;

  Future<void> _doTotpChallenge(AppState state) async {
    // After Firebase sign-in, check if TOTP is required.
    try {
      final r = await state.api.post('/api/auth/resolve', {'identifier': _identifier.text.trim()});
      if ((r['totpRequired'] as bool?) == true) {
        setState(() => _needTotp = true);
        return;
      }
    } catch (_) {}
    await state.init();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Account')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _NovaMark(size: 64),
            const SizedBox(height: 16),
            Text(_signup ? 'Create your Nova account' : 'Welcome back',
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
            const SizedBox(height: 8),
            const Text('Your anonymous session upgrades in place — your wallet and content stay yours.',
                style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 24),
            if (!_needTotp) ...[
              TextField(
                controller: _identifier,
                keyboardType: TextInputType.emailAddress,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                    labelText: 'Username or email', labelStyle: TextStyle(color: Colors.white54)),
              ),
              TextField(
                controller: _pass,
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(labelText: 'Password', labelStyle: TextStyle(color: Colors.white54)),
              ),
            ] else ...[
              const Text('Two-factor authentication',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 8),
              const Text('Enter the 6-digit code from your authenticator app.',
                  style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 12),
              TextField(
                controller: _totp,
                keyboardType: TextInputType.number,
                maxLength: 6,
                style: const TextStyle(color: Colors.white, fontSize: 24, letterSpacing: 8),
                decoration: const InputDecoration(labelText: '6-digit code', labelStyle: TextStyle(color: Colors.white54)),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ],
            const SizedBox(height: 24),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black),
              onPressed: _busy
                  ? null
                  : () async {
                      setState(() {
                        _busy = true;
                        _error = null;
                      });
                      try {
                        if (_needTotp) {
                          final r = await state.api.post('/api/auth/totp/challenge',
                              {'uid': state.auth.uid, 'code': _totp.text.trim()});
                          if ((r['ok'] as bool?) != true) throw ApiException(400, 'invalid_code');
                          await state.init();
                          if (mounted) Navigator.of(context).pop();
                        } else if (_signup) {
                          await state.auth.signUpWithEmail(_identifier.text.trim(), _pass.text);
                          await state.init();
                          if (mounted) Navigator.of(context).pop();
                        } else {
                          await state.auth.signInWithIdentifier(_identifier.text.trim(), _pass.text, state.api);
                          await _doTotpChallenge(state);
                        }
                      } catch (e) {
                        setState(() => _error = e is ApiException ? e.message : 'Sign-in failed: $e');
                      } finally {
                        if (mounted) setState(() => _busy = false);
                      }
                    },
              child: Text(_busy
                  ? 'Please wait…'
                  : _needTotp
                      ? 'Verify'
                      : (_signup ? 'Create account' : 'Sign in')),
            ),
            if (!_needTotp)
              TextButton(
                onPressed: () => setState(() => _signup = !_signup),
                child: Text(_signup ? 'Already have an account? Sign in' : 'New here? Create an account',
                    style: const TextStyle(color: Color(0xFFFFC107))),
              ),
            if (AppConfig.demoMode)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: Text('Demo mode: Firebase is not configured — this screen is unavailable.',
                    style: TextStyle(color: Colors.white38)),
              ),
          ],
        ),
      ),
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
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Icon(Icons.lock_outline, size: 56, color: Color(0xFFFFC107)),
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
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ],
            const SizedBox(height: 24),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black),
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
                        setState(() => _error = e is ApiException ? e.message : 'Wallet creation failed: $e');
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
