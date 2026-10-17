import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../services/api_client.dart';
import '../state/app_state.dart';
import 'auth.dart';
import 'earnings.dart';
import 'kyc.dart';
import 'monetization.dart';
import 'seller.dart';
import 'totp.dart';
import '../services/biometric_service.dart';
import 'support.dart';

/// Settings: account, KYC, verification, money, trust & safety, support.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? Colors.black : Colors.white;
    final fg = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white54 : Colors.black54;
    final faint2 = isDark ? Colors.white24 : Colors.black26;
    final faint12 = isDark ? Colors.white12 : Colors.black12;
    final dialogBg = isDark ? const Color(0xFF1a1a1a) : Colors.white;
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(backgroundColor: bg, title: Text('Settings', style: TextStyle(color: fg))),
      body: ListView(
        children: [
          if (state.isDemo)
            Container(
              margin: EdgeInsets.all(12),
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
              child: Text(
                'DEMO MODE — no cloud backend configured. Everything runs locally. See docs/SETUP.md to wire Firebase + Cloudflare + Flutterwave.',
                style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 12),
              ),
            ),
          if (!state.isDemo && state.accountStatus != 'active')
            Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.redAccent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
              child: Text(
                state.accountStatus == 'banned'
                    ? 'Your account is BANNED. Contact support to appeal.'
                    : 'Your account is SUSPENDED (${state.strikes.length}/3 strikes). Contact support to appeal.',
                style: const TextStyle(color: Colors.redAccent, fontSize: 12),
              ),
            ),
          _Row(
            icon: Icons.person_outline,
            title: state.auth.isAnonymous ? 'Browsing anonymously' : (state.auth.email ?? 'Account'),
            subtitle: state.auth.isAnonymous ? 'Create an account to keep your identity across devices' : 'Signed in',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AuthScreen())),
          ),
          if (!state.isDemo && !state.auth.isAnonymous)
            _Row(
              icon: Icons.badge_outlined,
              title: 'Username',
              subtitle: (state.me?.username.isNotEmpty ?? false)
                  ? '@${state.me!.username} (login with username or email)'
                  : 'Set a username to sign in with',
              onTap: () => _setUsername(context, state),
            ),
          _Row(
            icon: Icons.phonelink_lock_outlined,
            title: 'Two-factor authentication',
            subtitle: state.isDemo ? 'Requires cloud backend' : 'TOTP via authenticator app',
            onTap: state.isDemo
                ? null
                : () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const TotpSetupScreen())),
          ),
          _Row(
            icon: Icons.fingerprint_outlined,
            title: 'Biometric unlock',
            subtitle: 'Use fingerprint/face to unlock the wallet',
            onTap: () => _biometricPrompt(context),
          ),
          _Row(
            icon: Icons.verified_user_outlined,
            title: 'Identity verification (KYC)',
            subtitle: 'Status: ${state.kyc.status}',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const KycScreen())),
          ),
          _Row(
            icon: Icons.verified_outlined,
            title: 'Verification badge',
            subtitle: state.verificationActive ? 'You\'re verified' : '\$25/month — get the blue tick',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const VerificationScreen())),
          ),
          _Row(
            icon: Icons.palette_outlined,
            title: 'Theme',
            subtitle: _themeLabel(state.themePreference),
            onTap: () => _pickTheme(context, state),
          ),
          Divider(color: faint12),
          const _Header('Money'),
          _Row(
            icon: Icons.monetization_on_outlined,
            title: 'Nova Coins',
            subtitle: 'Balance: ${state.coins.balance} 🪙 · spend-only, never withdrawable',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CoinsScreen())),
          ),
          _Row(
            icon: Icons.payments_outlined,
            title: 'Creator earnings',
            subtitle: state.isDemo ? 'Gift revenue & payouts' : '${state.earningsBalance} coins ≈ \$${state.earningsUsd.toStringAsFixed(2)}',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EarningsScreen())),
          ),
          _Row(
            icon: Icons.store_outlined,
            title: 'Sell on Nova',
            subtitle: 'Seller status: ${state.sellerProfile.status}',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SellerOnboardingScreen())),
          ),
          Divider(color: faint12),
          const _Header('Trust & safety'),
          _Row(
            icon: Icons.gavel_outlined,
            title: 'Strikes & account status',
            subtitle: state.isDemo ? 'No strikes in demo' : '${state.strikes.length}/3 strikes · ${state.accountStatus}',
            onTap: () => _showStrikes(context, state),
          ),
          _Row(
            icon: Icons.support_agent_outlined,
            title: 'Support',
            subtitle: 'Help center & tickets',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SupportScreen())),
          ),
          Divider(color: faint12),
          const _Header('Network & security'),
          _Row(
            icon: Icons.cloud_outlined,
            title: 'Network',
            subtitle: state.vpnDetected
                ? 'VPN/proxy interface detected — disconnect to use Nova'
                : 'Testnet (Sepolia) — mainnet disabled in this build',
          ),
          _Row(
            icon: Icons.security_outlined,
            title: 'Security model',
            subtitle: 'How your keys and money are protected',
            onTap: () => showDialog(
              context: context,
              builder: (context) => AlertDialog(
                backgroundColor: dialogBg,
                title: Text('Security', style: TextStyle(color: fg)),
                content: SingleChildScrollView(
                  child: Text(
                    '• Your wallet keys are encrypted on this device with your PIN (AES-256-GCM, PBKDF2 210k).\n'
                    '• Nova servers store only the encrypted backup — never your PIN or keys.\n'
                    '• Three wallets, strictly separated:\n'
                    '  1. Nova Coins — bought with USD, spent on gifts/tips ONLY. Never withdrawable.\n'
                    '  2. Creator earnings — gift revenue lands here; this is the payout path.\n'
                    '  3. Crypto wallet — on-chain BTC/ETH/USDT/USDC send/receive only. No fiat.\n'
                    '• VPN/proxy/Tor are blocked (client interface check + server egress blacklist).\n'
                    '• Full threat model: SECURITY.md in the repo.',
                    style: TextStyle(color: sub),
                  ),
                ),
              ),
            ),
          ),
          Divider(color: faint12),
          const _Header('About'),
          _Row(icon: Icons.info_outline, title: 'Nova', subtitle: 'v0.1.0 · clean-room TikTok-style build'),
          _Row(
            icon: Icons.logout,
            title: 'Sign out',
            onTap: () async {
              await state.auth.signOut();
              if (context.mounted) {
                // v1.1: sign-in is mandatory — return to the login gate.
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const AuthScreen(gate: true)),
                  (_) => false,
                );
              }
            },
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Backend: ${AppConfig.demoMode ? 'demo (local)' : AppConfig.apiBaseUrl}',
                style: TextStyle(color: faint2, fontSize: 11), textAlign: TextAlign.center),
          ),
        ],
      ),
    );
  }

  void _setUsername(BuildContext context, AppState state) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dialogBg = isDark ? const Color(0xFF1a1a1a) : Colors.white;
    final fg = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white54 : Colors.black54;
    final c = TextEditingController(text: state.me?.username ?? '');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: dialogBg,
        title: Text('Set username', style: TextStyle(color: fg)),
        content: TextField(
          controller: c,
          style: TextStyle(color: fg),
          decoration: InputDecoration(
              labelText: 'Username (for login)', labelStyle: TextStyle(color: sub)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.primary, foregroundColor: Colors.black),
            onPressed: () async {
              final u = c.text.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '');
              if (u.isEmpty) return;
              try {
                await state.api.post('/api/users/sync', {'username': u});
                await state.init();
                if (context.mounted) Navigator.of(context).pop();
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text('Failed: ${e is ApiException ? e.code : e}')));
                }
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _biometricPrompt(BuildContext context) async {
    final bio = BiometricService();
    // The service now reports granular failures (not enrolled, locked out,
    // user canceled, …) so the user gets an actionable message instead of a
    // generic "failed".
    final result = await bio.authenticate(
        reason: 'Verify it\'s you to manage biometric unlock');
    if (!context.mounted) return;
    if (result.ok) {
      // Persist the preference so "enabled" is real, not just a snackbar.
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('nova_biometric_unlock', true);
      } catch (_) {}
    }
    final msg =
        result.ok ? 'Biometric verified — wallet unlock enabled.' : result.message;
    // userCanceled yields a null message: stay silent when dismissed.
    if (msg != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  String _themeLabel(String pref) {
    switch (pref) {
      case 'light':
        return 'Light theme';
      case 'dark':
        return 'Dark theme';
      default:
        return 'System theme';
    }
  }

  void _pickTheme(BuildContext context, AppState state) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dialogBg = isDark ? const Color(0xFF1a1a1a) : Colors.white;
    final fg = isDark ? Colors.white : Colors.black87;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: dialogBg,
        title: Text('Theme', style: TextStyle(color: fg)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _themeOption(context, state, 'system', 'System theme', 'Follow device setting'),
            _themeOption(context, state, 'light', 'Light theme', null),
            _themeOption(context, state, 'dark', 'Dark theme', null),
          ],
        ),
      ),
    );
  }

  Widget _themeOption(BuildContext context, AppState state, String value, String title, String? subtitle) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white54 : Colors.black54;
    final selected = state.themePreference == value;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: TextStyle(color: fg)),
      subtitle: subtitle != null ? Text(subtitle, style: TextStyle(color: sub, fontSize: 12)) : null,
      trailing: selected ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary) : null,
      onTap: () {
        state.setThemePreference(value);
        Navigator.of(context).pop();
      },
    );
  }

  void _showStrikes(BuildContext context, AppState state) {    if (state.isDemo) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('No strikes in demo mode.')));
      return;
    }
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final dialogBg = isDark ? const Color(0xFF1a1a1a) : Colors.white;
    final fg = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white54 : Colors.black54;
    state.loadStrikes().then((_) {
      if (!context.mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: dialogBg,
          title: Text('Strikes', style: TextStyle(color: fg)),
          content: SizedBox(
            width: double.maxFinite,
            child: state.strikes.isEmpty
                ? Text('Clean record. Zero-tolerance: nudity = instant strike; 3 strikes = suspension; nudity on LIVE = instant ban.',
                    style: TextStyle(color: sub, fontSize: 13))
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${state.strikes.length}/3 strikes', style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      for (final s in state.strikes)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(s.reason, style: TextStyle(color: fg, fontSize: 14)),
                          subtitle: Text(s.details, style: TextStyle(color: sub, fontSize: 12)),
                        ),
                    ],
                  ),
          ),
          actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close'))],
        ),
      );
    });
  }
}

class _Header extends StatelessWidget {
  final String text;
  _Header(this.text);

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(text, style: TextStyle(color: isDark ? Colors.white38 : Colors.black38, fontSize: 12, fontWeight: FontWeight.bold)),
    );
  }
}

class _Row extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  _Row({required this.icon, required this.title, this.subtitle, this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white54 : Colors.black54;
    final chev = isDark ? Colors.white38 : Colors.black38;
    return ListTile(
      leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
      title: Text(title, style: TextStyle(color: fg)),
      subtitle: subtitle == null ? null : Text(subtitle!, style: TextStyle(color: sub, fontSize: 12)),
      trailing: onTap == null ? null : Icon(Icons.chevron_right, color: chev),
      onTap: onTap,
    );
  }
}
