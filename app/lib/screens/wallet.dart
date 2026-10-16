import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../services/api_client.dart';
import '../state/app_state.dart';
import 'earnings.dart';
import 'auth.dart';
import 'kyc.dart';

/// Wallet: per-user EVM + BTC addresses. Send/receive crypto ONLY —
/// no fiat deposits or on/off-ramp here (see SECURITY.md §9).
/// Creation requires verified KYC.
class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  String? _evmBal;
  String? _btcBal;
  bool _loadingBal = false;

  Future<void> _loadBalances() async {
    final w = context.read<AppState>().wallet;
    setState(() => _loadingBal = true);
    try {
      _evmBal = await w.evmBalance();
    } catch (_) {
      _evmBal = '—';
    }
    try {
      _btcBal = await w.btcBalance();
    } catch (_) {
      _btcBal = '—';
    }
    if (mounted) setState(() => _loadingBal = false);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final w = state.wallet;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Wallet')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: !w.hasWallet
            ? _lockedView(state)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(colors: [Color(0xFF2a2000), Color(0xFF1a1a1a)]),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0xFFFFC107).withValues(alpha: 0.4)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Total (testnet view)', style: TextStyle(color: Colors.white54, fontSize: 12)),
                        const SizedBox(height: 4),
                        _loadingBal
                            ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFFC107)))
                            : Text('${_evmBal ?? '—'} SepoliaETH', style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.bold)),
                        Text('${_btcBal ?? '—'} BTC', style: const TextStyle(color: Colors.white70, fontSize: 14)),
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: _loadBalances,
                          icon: const Icon(Icons.refresh, size: 16, color: Color(0xFFFFC107)),
                          label: const Text('Refresh balances', style: TextStyle(color: Color(0xFFFFC107))),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _AddressCard(label: 'Ethereum (ETH · USDT · USDC)', address: w.evmAddress!),
                  const SizedBox(height: 12),
                  _AddressCard(label: 'Bitcoin (BTC)', address: w.btcAddress!),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black),
                    icon: const Icon(Icons.send),
                    label: const Text('Send (Sepolia testnet)'),
                    onPressed: () => _sendDialog(state),
                  ),
                  const SizedBox(height: 12),
                  const _Note(
                    'TESTNET MODE — this wallet sends on Sepolia testnet only. '
                    'Mainnet is disabled in this build. Never share your PIN.',
                  ),
                  const SizedBox(height: 8),
                  const _Note('BTC sending is not in v1 (UTXO signing is phase 2). BTC balance is read-only.'),
                  const SizedBox(height: 8),
                  const _Note('This wallet is crypto send/receive only. To buy Nova Coins with USD, use the Nova Coins tab — the two money systems never mix.'),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.payments_outlined, color: Color(0xFF20D5EC)),
                    label: const Text('Creator earnings & payouts', style: TextStyle(color: Colors.white)),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EarningsScreen())),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _lockedView(AppState state) {
    final kycOk = state.kyc.canCreateWallet;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 32),
        const Icon(Icons.account_balance_wallet_outlined, size: 72, color: Color(0xFFFFC107)),
        const SizedBox(height: 16),
        const Text('Your Nova wallet', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text(
          'One wallet per account: Ethereum (ETH, USDT, USDC) + Bitcoin addresses, generated on this device. Keys are encrypted with your PIN — Nova servers only store the encrypted backup.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white60),
        ),
        const SizedBox(height: 24),
        if (!kycOk) ...[
          const _Note('KYC verification is required before a wallet can be created.'),
          const SizedBox(height: 12),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const KycScreen()));
              setState(() {});
            },
            child: Text(state.kyc.status == 'pending' ? 'Check KYC status' : 'Verify my identity (KYC)'),
          ),
        ] else
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black),
            onPressed: () async {
              final ok = await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PinSetupScreen()));
              if (ok == true) setState(() {});
            },
            child: const Text('Create my wallet'),
          ),
      ],
    );
  }

  Future<void> _sendDialog(AppState state) async {
    final to = TextEditingController();
    final amount = TextEditingController();
    final pin = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a1a1a),
        title: const Text('Send SepoliaETH', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('TESTNET — no real value moves.', style: TextStyle(color: Colors.amber, fontSize: 12)),
            TextField(controller: to, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'To address (0x…)', labelStyle: TextStyle(color: Colors.white54))),
            TextField(controller: amount, style: const TextStyle(color: Colors.white), keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Amount (ETH)', labelStyle: TextStyle(color: Colors.white54))),
            TextField(controller: pin, style: const TextStyle(color: Colors.white), obscureText: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Wallet PIN', labelStyle: TextStyle(color: Colors.white54))),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Review & send'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // Explicit confirmation screen (per SECURITY.md money-movement policy).
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a1a1a),
        title: const Text('Confirm send', style: TextStyle(color: Colors.white)),
        content: Text('Send ${amount.text} SepoliaETH\nto ${to.text}\n\nThis is a TESTNET transaction.',
            style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Broadcast'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      final hash = await state.wallet.sendEvm(pin: pin.text, to: to.text.trim(), amountEth: double.parse(amount.text), api: state.api);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Broadcast: $hash')));
        _loadBalances();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Send failed: ${e is ApiException ? e.message : e}')));
      }
    }
  }
}

class _AddressCard extends StatelessWidget {
  final String label;
  final String address;
  const _AddressCard({required this.label, required this.address});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: const Color(0xFF161616), borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: Text(address, style: const TextStyle(color: Colors.white, fontSize: 13))),
              IconButton(
                icon: const Icon(Icons.copy, size: 18, color: Color(0xFFFFC107)),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: address));
                  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Address copied')));
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  final String text;
  const _Note(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.amber.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
      child: Text(text, style: const TextStyle(color: Colors.amber, fontSize: 12)),
    );
  }
}
