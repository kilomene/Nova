import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Settings')),
      body: ListView(
        children: [
          if (state.isDemo)
            Container(
              margin: const EdgeInsets.all(12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.amber.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
              child: const Text(
                'DEMO MODE — no cloud backend configured. Everything runs locally. See docs/SETUP.md to wire Firebase + Cloudflare + Flutterwave.',
                style: TextStyle(color: Colors.amber, fontSize: 12),
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
            subtitle: state.verificationActive ? 'Active ✓' : '\$25/month — get the blue tick',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const VerificationScreen())),
          ),
          const Divider(color: Colors.white12),
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
          const Divider(color: Colors.white12),
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
          const Divider(color: Colors.white12),
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
              builder: (context) => const AlertDialog(
                backgroundColor: Color(0xFF1a1a1a),
                title: Text('Security', style: TextStyle(color: Colors.white)),
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
                    style: TextStyle(color: Colors.white70),
                  ),
                ),
              ),
            ),
          ),
          const Divider(color: Colors.white12),
          const _Header('About'),
          _Row(icon: Icons.info_outline, title: 'Nova', subtitle: 'v0.1.0 · clean-room TikTok-style build'),
          _Row(
            icon: Icons.logout,
            title: 'Sign out',
            onTap: () async {
              await state.auth.signOut();
              await state.init();
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Signed out (fresh anonymous session).')));
            },
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('Backend: ${AppConfig.demoMode ? 'demo (local)' : AppConfig.apiBaseUrl}',
                style: const TextStyle(color: Colors.white24, fontSize: 11), textAlign: TextAlign.center),
          ),
        ],
      ),
    );
  }

  void _setUsername(BuildContext context, AppState state) {
    final c = TextEditingController(text: state.me?.username ?? '');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a1a1a),
        title: const Text('Set username', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: c,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
              labelText: 'Username (for login)', labelStyle: TextStyle(color: Colors.white54)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black),
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
    if (!await bio.isAvailable) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Biometrics not available on this device.')));
      }
      return;
    }
    final ok = await bio.authenticate(reason: 'Verify it\'s you to manage biometric unlock');
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ok ? 'Biometric verified — wallet unlock enabled.' : 'Biometric failed.')));
    }
  }

  void _showStrikes(BuildContext context, AppState state) {
    if (state.isDemo) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No strikes in demo mode.')));
      return;
    }
    state.loadStrikes().then((_) {
      if (!context.mounted) return;
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF1a1a1a),
          title: const Text('Strikes', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: double.maxFinite,
            child: state.strikes.isEmpty
                ? const Text('Clean record. Zero-tolerance: nudity = instant strike; 3 strikes = suspension; nudity on LIVE = instant ban.',
                    style: TextStyle(color: Colors.white70, fontSize: 13))
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${state.strikes.length}/3 strikes', style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      for (final s in state.strikes)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(s.reason, style: const TextStyle(color: Colors.white, fontSize: 14)),
                          subtitle: Text(s.details, style: const TextStyle(color: Colors.white54, fontSize: 12)),
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
  const _Header(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(text, style: const TextStyle(color: Colors.white38, fontSize: 12, fontWeight: FontWeight.bold)),
    );
  }
}

class _Row extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  const _Row({required this.icon, required this.title, this.subtitle, this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFFFFC107)),
      title: Text(title, style: const TextStyle(color: Colors.white)),
      subtitle: subtitle == null ? null : Text(subtitle!, style: const TextStyle(color: Colors.white54, fontSize: 12)),
      trailing: onTap == null ? null : const Icon(Icons.chevron_right, color: Colors.white38),
      onTap: onTap,
    );
  }
}
