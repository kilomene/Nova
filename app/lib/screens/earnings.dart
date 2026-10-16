import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_client.dart';
import '../state/app_state.dart';

/// Creator earnings wallet: gift revenue lands here (platform cut applied).
/// This is the payout/withdrawal path — separate from the Nova Coin purchase
/// wallet, which is spend-only and can never be withdrawn.
class EarningsScreen extends StatefulWidget {
  const EarningsScreen({super.key});

  @override
  State<EarningsScreen> createState() => _EarningsScreenState();
}

class _EarningsScreenState extends State<EarningsScreen> {
  List<Map<String, dynamic>> _ledger = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    await state.refreshEarnings();
    final l = await state.earningsLedger();
    if (mounted) setState(() => _ledger = l);
  }

  Future<void> _payout() async {
    final state = context.read<AppState>();
    final amount = TextEditingController();
    final dest = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a1a1a),
        title: const Text('Request payout', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Minimum 1,000 coins (\$10). 100 coins = \$1 USD.',
                style: TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(height: 8),
            TextField(controller: amount, style: const TextStyle(color: Colors.white), keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Coins', labelStyle: TextStyle(color: Colors.white54))),
            TextField(controller: dest, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'Payout destination (bank / mobile money)', labelStyle: TextStyle(color: Colors.white54))),
            const SizedBox(height: 8),
            const Text('v1: requests are recorded for manual processing.',
                style: TextStyle(color: Colors.amber, fontSize: 11)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Request'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final r = await state.requestPayout(amountCoins: int.parse(amount.text.trim()), destination: dest.text.trim());
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Payout requested: \$${(r['amountUsd'] as num).toStringAsFixed(2)} (${r['status']})')));
      _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Payout failed: ${e is ApiException ? e.message : e}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Creator earnings')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [Color(0xFF20D5EC), Color(0xFF0E7C8C)]),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  Text('${state.earningsBalance}', style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w900, color: Colors.white)),
                  Text('≈ \$${state.earningsUsd.toStringAsFixed(2)} USD', style: const TextStyle(color: Colors.white70)),
                  const SizedBox(height: 4),
                  Text('Lifetime earned: ${state.earningsLifetime} coins', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black),
              onPressed: state.isDemo ? null : _payout,
              child: const Text('Request payout'),
            ),
            if (state.isDemo)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Demo mode: connect the backend to request payouts.', style: TextStyle(color: Colors.white38, fontSize: 12), textAlign: TextAlign.center),
              ),
            const SizedBox(height: 16),
            const Text('Activity', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            if (_ledger.isEmpty)
              const Text('No earnings yet. Go live and receive gifts!', style: TextStyle(color: Colors.white38)),
            for (final e in _ledger)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon((e['delta'] as int) >= 0 ? Icons.arrow_downward : Icons.arrow_upward,
                    color: (e['delta'] as int) >= 0 ? Colors.greenAccent : Colors.redAccent),
                title: Text('${e['delta'] > 0 ? '+' : ''}${e['delta']} coins', style: const TextStyle(color: Colors.white)),
                subtitle: Text('${e['reason'] ?? ''}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ),
          ],
        ),
      ),
    );
  }
}
