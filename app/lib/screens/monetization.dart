import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_client.dart';
import '../state/app_state.dart';

/// Nova Coin: buy with USD via Flutterwave, spend on gifts/tips.
/// NOT crypto — never touches the wallet.
class CoinsScreen extends StatefulWidget {
  const CoinsScreen({super.key});

  @override
  State<CoinsScreen> createState() => _CoinsScreenState();
}

class _CoinsScreenState extends State<CoinsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<AppState>().coins.refresh(context.read<AppState>().api));
  }

  Future<void> _buy(dynamic pkg) async {
    final state = context.read<AppState>();
    final email = TextEditingController(text: state.auth.email ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a1a1a),
        title: Text('Buy ${pkg.coins} Nova Coins', style: const TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('\$${pkg.usd} USD via Flutterwave (secure checkout).', style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 8),
            TextField(controller: email, style: const TextStyle(color: Colors.white), keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email for receipt', labelStyle: TextStyle(color: Colors.white54))),
            if (state.isDemo)
              const Padding(padding: EdgeInsets.only(top: 8), child: Text('DEMO: no real payment — coins are credited instantly.', style: TextStyle(color: Colors.amber, fontSize: 12))),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final opened = await state.coins.buyPackage(state.api, pkg, email.text.trim());
      if (!mounted) return;
      if (state.isDemo) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Demo credit: +${pkg.coins} coins')));
      } else if (opened) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Checkout opened — coins credit automatically after payment.')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Purchase failed: ${e is ApiException ? e.message : e}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final coins = state.coins;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Nova Coins 🪙')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [Color(0xFFFFD54F), Color(0xFFFF8F00)]),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  const Text('🪙', style: TextStyle(fontSize: 48)),
                  Text('${coins.balance}', style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w900, color: Colors.black87)),
                  const Text('Nova Coins', style: TextStyle(color: Colors.black54, fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Text('Top up', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            for (final p in coins.packages)
              Card(
                color: const Color(0xFF161616),
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: const Text('🪙', style: TextStyle(fontSize: 32)),
                  title: Text('${p.coins} coins', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  subtitle: const Text('Spend on LIVE gifts & tips', style: TextStyle(color: Colors.white54, fontSize: 12)),
                  trailing: ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black),
                    onPressed: () => _buy(p),
                    child: Text('\$${p.usd}'),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            const Text(
              'Nova Coins are in-app only: they are not cryptocurrency and cannot be withdrawn to the crypto wallet. Purchases are processed by Flutterwave; coins credit automatically once payment confirms.',
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// Verification badge: $25/month via the Flutterwave backend flow.
class VerificationScreen extends StatefulWidget {
  const VerificationScreen({super.key});

  @override
  State<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends State<VerificationScreen> {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Verification')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 16),
            const Icon(Icons.verified, size: 72, color: Color(0xFF20D5EC)),
            const SizedBox(height: 16),
            Text(
              state.verificationActive ? 'You are verified ✓' : 'Get the blue tick',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'A blue tick on your profile and comments. Builds trust for P2P trades and marketplace sales.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white60),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: const Color(0xFF161616), borderRadius: BorderRadius.circular(12)),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Verification', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  Text('\$25 / month', style: TextStyle(color: Color(0xFFFFC107), fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            const SizedBox(height: 20),
            if (!state.verificationActive)
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black),
                onPressed: () async {
                  final email = TextEditingController(text: state.auth.email ?? '');
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      backgroundColor: const Color(0xFF1a1a1a),
                      title: const Text('Subscribe — \$25/month', style: TextStyle(color: Colors.white)),
                      content: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('Secure checkout via Flutterwave.', style: TextStyle(color: Colors.white70)),
                          TextField(controller: email, style: const TextStyle(color: Colors.white), keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email for receipt', labelStyle: TextStyle(color: Colors.white54))),
                          if (state.isDemo) const Padding(padding: EdgeInsets.only(top: 8), child: Text('DEMO: no real payment — badge activates instantly.', style: TextStyle(color: Colors.amber, fontSize: 12))),
                        ],
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
                        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black), onPressed: () => Navigator.of(context).pop(true), child: const Text('Continue')),
                      ],
                    ),
                  );
                  if (ok != true || !mounted) return;
                  try {
                    await state.subscribeVerification(email.text.trim());
                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Checkout opened — badge activates once payment confirms.')));
                  } catch (e) {
                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: ${e is ApiException ? e.message : e}')));
                  }
                },
                child: const Text('Subscribe — \$25/month'),
              )
            else
              const Text('Active subscription. Renew monthly to keep the tick.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white54)),
            const SizedBox(height: 12),
            const Text('v1 note: subscriptions renew manually each month (auto-renewal via Flutterwave recurring billing is phase 2).',
                textAlign: TextAlign.center, style: TextStyle(color: Colors.white38, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
