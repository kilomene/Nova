import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_client.dart';
import '../state/app_state.dart';

/// TOTP 2FA setup: shows the secret + otpauth URI (user scans with
/// Google Authenticator / iOS Passwords), then verifies a code to enable.
class TotpSetupScreen extends StatefulWidget {
  const TotpSetupScreen({super.key});

  @override
  State<TotpSetupScreen> createState() => _TotpSetupScreenState();
}

class _TotpSetupScreenState extends State<TotpSetupScreen> {
  final _code = TextEditingController();
  String? _secret;
  String? _uri;
  bool _busy = false;
  String? _error;
  bool _enabled = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() => _busy = true);
    try {
      final r = await context.read<AppState>().api.post('/api/auth/totp/setup', {});
      final secret = r['secret'] as String?;
      if (secret == null || secret.isEmpty) {
        throw ApiException(500, 'totp_setup_empty');
      }
      setState(() {
        _secret = secret;
        _uri = r['otpauthUri'] as String?;
      });
    } catch (e) {
      setState(() => _error = e is ApiException ? e.message : 'Setup failed. Check your connection and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Two-factor authentication')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: _enabled
            ? const Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(Icons.check_circle, color: Colors.greenAccent, size: 64),
                  SizedBox(height: 16),
                  Text('2FA is enabled.', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                  SizedBox(height: 8),
                  Text('You will be asked for a code from your authenticator app on every sign-in.',
                      style: TextStyle(color: Colors.white70), textAlign: TextAlign.center),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('1. Open Google Authenticator (or iOS Passwords) and add this secret:',
                      style: TextStyle(color: Colors.white)),
                  const SizedBox(height: 12),
                  if (_busy) Center(child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary)),
                  if (_secret != null) ...[
                    SelectableText(_secret!,
                        style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 18, letterSpacing: 2)),
                    if (_uri != null) ...[
                      const SizedBox(height: 8),
                      const Text('Or paste this URI into your authenticator app:',
                          style: TextStyle(color: Colors.white54, fontSize: 12)),
                      SelectableText(_uri!, style: const TextStyle(color: Colors.white38, fontSize: 10)),
                    ],
                  ],
                  const SizedBox(height: 16),
                  const Text('2. Enter the 6-digit code to verify and enable:',
                      style: TextStyle(color: Colors.white)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _code,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    style: const TextStyle(color: Colors.white, fontSize: 24, letterSpacing: 8),
                    decoration: const InputDecoration(labelText: '6-digit code', labelStyle: TextStyle(color: Colors.white54)),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!, style: const TextStyle(color: Colors.redAccent)),
                  ],
                  const SizedBox(height: 16),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.primary, foregroundColor: Colors.black),
                    onPressed: _busy
                        ? null
                        : () async {
                            setState(() {
                              _busy = true;
                              _error = null;
                            });
                            try {
                              await context
                                  .read<AppState>()
                                  .api
                                  .post('/api/auth/totp/verify', {'code': _code.text.trim()});
                              setState(() => _enabled = true);
                            } catch (e) {
                              // Surface the real backend reason (invalid_code,
                              // totp_not_set_up, rate_limited, …) instead of
                              // blaming the code for every failure.
                              setState(() => _error = e is ApiException
                                  ? e.message
                                  : 'Verification failed. Check your connection and try again.');
                            } finally {
                              if (mounted) setState(() => _busy = false);
                            }
                          },
                    child: Text(_busy ? 'Verifying…' : 'Verify & enable'),
                  ),
                ],
              ),
      ),
    );
  }
}
