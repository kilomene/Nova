import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../models/wallet_catalog.dart';
import '../services/api_client.dart';
import '../state/app_state.dart';
import 'earnings.dart';
import 'auth.dart';
import 'kyc.dart';
import 'p2p.dart';

/// Nova wallet — dark+gold premium skin.
/// Send | Receive | P2P action row; Binance-style receive flow
/// (coin → network → address+QR); guided send flow.
class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  String? _evmBal;
  String? _btcBal;
  bool _loadingBal = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadBalances());
  }

  Future<void> _loadBalances() async {
    final w = context.read<AppState>().wallet;
    if (!w.hasWallet) return;
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
    const gold = Color(0xFFFFC107);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Wallet',
            style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
            icon: const Icon(Icons.history, color: Colors.white70),
            tooltip: 'Transaction history',
            onPressed: () {},
          ),
        ],
      ),
      body: !w.hasWallet
          ? _lockedView(state)
          : RefreshIndicator(
              color: gold,
              backgroundColor: const Color(0xFF1a1a1a),
              onRefresh: _loadBalances,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Balance hero card.
                    Container(
                      padding: const EdgeInsets.all(22),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFF3a2c00), Color(0xFF1a1a1a)],
                        ),
                        borderRadius: BorderRadius.circular(18),
                        border:
                            Border.all(color: gold.withValues(alpha: 0.45)),
                        boxShadow: [
                          BoxShadow(
                            color: gold.withValues(alpha: 0.12),
                            blurRadius: 24,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Total balance',
                              style: TextStyle(
                                  color: Colors.white54, fontSize: 13)),
                          const SizedBox(height: 6),
                          _loadingBal
                              ? const SizedBox(
                                  height: 22,
                                  width: 22,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: gold))
                              : Text('${_evmBal ?? '—'} ETH',
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 30,
                                      fontWeight: FontWeight.w800)),
                          Text('${_btcBal ?? '—'} BTC',
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 15)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                    // Send | Receive | P2P action row.
                    Row(
                      children: [
                        Expanded(
                          child: _WalletAction(
                            icon: Icons.arrow_upward,
                            label: 'Send',
                            onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) =>
                                        const SendCoinScreen())),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _WalletAction(
                            icon: Icons.arrow_downward,
                            label: 'Receive',
                            onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) =>
                                        const ReceiveCoinScreen())),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _WalletAction(
                            icon: Icons.swap_horiz,
                            label: 'P2P',
                            onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) => const P2PScreen())),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    const Text('Coins',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    for (final coin in walletCoins)
                      _CoinRow(
                        coin: coin,
                        onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) =>
                                    ReceiveCoinScreen(initialCoin: coin))),
                      ),
                    const SizedBox(height: 16),
                    const _Note(
                      'TESTNET MODE — this wallet operates on Sepolia testnet. '
                      'Mainnet is disabled in this build. Never share your PIN.',
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.payments_outlined,
                          color: Color(0xFF20D5EC)),
                      label: const Text('Creator earnings & payouts',
                          style: TextStyle(color: Colors.white)),
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const EarningsScreen())),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _lockedView(AppState state) {
    final kycOk = state.kyc.canCreateWallet;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 32),
          const Icon(Icons.account_balance_wallet_outlined,
              size: 72, color: Color(0xFFFFC107)),
          const SizedBox(height: 16),
          const Text('Your Nova wallet',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
            'One wallet per account: Ethereum (ETH, USDT, USDC) + Bitcoin addresses, generated on this device. Keys are encrypted with your PIN — Nova servers only store the encrypted backup.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white60),
          ),
          const SizedBox(height: 24),
          if (!kycOk) ...[
            const _Note(
                'KYC verification is required before a wallet can be created.'),
            const SizedBox(height: 12),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFFC107),
                  foregroundColor: Colors.black),
              onPressed: () async {
                await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const KycScreen()));
                setState(() {});
              },
              child: Text(state.kyc.status == 'pending'
                  ? 'Check KYC status'
                  : 'Verify my identity (KYC)'),
            ),
          ] else
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFFC107),
                  foregroundColor: Colors.black),
              onPressed: () async {
                final ok = await Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const PinSetupScreen()));
                if (ok == true) setState(() {});
              },
              child: const Text('Create my wallet'),
            ),
        ],
      ),
    );
  }
}

/// Big gold action button: Send / Receive / P2P.
class _WalletAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _WalletAction(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
              colors: [Color(0xFFFFD54F), Color(0xFFFF8F00)]),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFFFC107).withValues(alpha: 0.3),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          children: [
            Icon(icon, color: Colors.black, size: 24),
            const SizedBox(height: 4),
            Text(label,
                style: const TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.w800,
                    fontSize: 14)),
          ],
        ),
      ),
    );
  }
}

class _CoinRow extends StatelessWidget {
  final WalletCoin coin;
  final VoidCallback onTap;
  const _CoinRow({required this.coin, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF161616),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: coin.brand.withValues(alpha: 0.18),
                border: Border.all(
                    color: coin.brand.withValues(alpha: 0.5)),
              ),
              child: Center(
                child: Text(coin.iconGlyph,
                    style: TextStyle(
                        color: coin.brand,
                        fontSize: 22,
                        fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(coin.symbol,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 15)),
                  Text(coin.name,
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white38),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// RECEIVE FLOW
// ============================================================

/// Screen 1: "Select a coin to deposit".
class ReceiveCoinScreen extends StatelessWidget {
  final WalletCoin? initialCoin;
  const ReceiveCoinScreen({super.key, this.initialCoin});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Receive',
            style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Select a coin to deposit',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text(
            'Choose which coin you want to receive. USDT will ask which network next.',
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(height: 16),
          for (final coin in walletCoins)
            _CoinRow(
              coin: coin,
              onTap: () {
                if (coin.needsNetwork) {
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) =>
                          ReceiveNetworkScreen(coin: coin)));
                } else {
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => ReceiveAddressScreen(
                          coin: coin, network: coin.networks.first)));
                }
              },
            ),
        ],
      ),
    );
  }
}

/// Screen 2: "Choose network" with safety warning.
class ReceiveNetworkScreen extends StatelessWidget {
  final WalletCoin coin;
  const ReceiveNetworkScreen({super.key, required this.coin});

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFFFC107);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text('Receive ${coin.symbol}',
            style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Choose network',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.redAccent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: Colors.redAccent.withValues(alpha: 0.4)),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded,
                    color: Colors.redAccent, size: 22),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Ensure the network you select matches the withdrawal platform, or your assets may be lost.',
                    style: TextStyle(
                        color: Colors.redAccent,
                        fontSize: 13,
                        fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          for (final net in coin.networks)
            InkWell(
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) =>
                      ReceiveAddressScreen(coin: coin, network: net))),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF161616),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: gold.withValues(alpha: 0.12),
                        border:
                            Border.all(color: gold.withValues(alpha: 0.5)),
                      ),
                      child: Center(
                        child: Text(coin.iconGlyph,
                            style: const TextStyle(
                                color: gold,
                                fontSize: 22,
                                fontWeight: FontWeight.bold)),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(net.code,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                  fontSize: 16)),
                          Text(net.chain,
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 13)),
                          const SizedBox(height: 4),
                          Text(
                            '${net.confirmations} block confirmation(s) · Min deposit: ${net.minDeposit}',
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const Icon(Icons.chevron_right, color: Colors.white38),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Screen 3: deposit address + QR + copy.
class ReceiveAddressScreen extends StatelessWidget {
  final WalletCoin coin;
  final WalletNetwork network;
  const ReceiveAddressScreen(
      {super.key, required this.coin, required this.network});

  String _address(BuildContext context) {
    final w = context.read<AppState>().wallet;
    switch (network.addressKind) {
      case 'btc':
        return w.btcAddress ?? '';
      case 'tron':
        // Tron address not generated in v1 — show EVM with a note.
        return w.evmAddress ?? '';
      default:
        return w.evmAddress ?? '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final address = _address(context);
    const gold = Color(0xFFFFC107);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text('Receive ${coin.symbol} · ${network.code}',
            style: const TextStyle(
                fontWeight: FontWeight.w800, fontSize: 16)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // QR card.
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: gold.withValues(alpha: 0.25),
                    blurRadius: 24,
                  ),
                ],
              ),
              child: Column(
                children: [
                  if (address.isNotEmpty)
                    QrImageView(
                      data: address,
                      version: QrVersions.auto,
                      size: 200,
                      backgroundColor: Colors.white,
                    )
                  else
                    const SizedBox(
                      height: 200,
                      child: Center(child: Text('No address yet')),
                    ),
                  const SizedBox(height: 12),
                  Text(
                    '${coin.symbol} · ${network.code} (${network.chain})',
                    style: const TextStyle(
                        color: Colors.black87,
                        fontWeight: FontWeight.w700,
                        fontSize: 14),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            const Text('Deposit address',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 15)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF161616),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(address,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.copy, color: gold),
                    onPressed: () async {
                      await Clipboard.setData(
                          ClipboardData(text: address));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Address copied')));
                      }
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                'Send only ${coin.symbol} on ${network.code} (${network.chain}) to this address. '
                '${network.confirmations} block confirmation(s) required. '
                'Minimum deposit: ${network.minDeposit}.',
                style:
                    const TextStyle(color: Colors.amber, fontSize: 12),
              ),
            ),
            if (network.addressKind == 'tron') ...[
              const SizedBox(height: 8),
              const _Note(
                'TRON address generation is coming soon — this shows your EVM address for now. Do not send TRC20 assets here yet.',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ============================================================
// SEND FLOW
// ============================================================

/// Send step 1: pick a coin.
class SendCoinScreen extends StatelessWidget {
  const SendCoinScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Send',
            style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Select a coin to send',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          for (final coin in walletCoins)
            _CoinRow(
              coin: coin,
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => SendDetailsScreen(coin: coin))),
            ),
        ],
      ),
    );
  }
}

/// Send step 2: address + amount.
class SendDetailsScreen extends StatefulWidget {
  final WalletCoin coin;
  const SendDetailsScreen({super.key, required this.coin});

  @override
  State<SendDetailsScreen> createState() => _SendDetailsScreenState();
}

class _SendDetailsScreenState extends State<SendDetailsScreen> {
  final _to = TextEditingController();
  final _amount = TextEditingController();

  @override
  void dispose() {
    _to.dispose();
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFFFC107);
    final valid =
        _to.text.trim().isNotEmpty && _amount.text.trim().isNotEmpty;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text('Send ${widget.coin.symbol}',
            style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CoinRow(coin: widget.coin, onTap: () {}),
            const SizedBox(height: 16),
            const Text('Recipient address',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 14)),
            const SizedBox(height: 8),
            TextField(
              controller: _to,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: widget.coin.symbol == 'BTC'
                    ? 'bc1… or 1…/3…'
                    : '0x…',
                hintStyle: const TextStyle(color: Colors.white24),
                filled: true,
                fillColor: const Color(0xFF161616),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            const Text('Amount',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 14)),
            const SizedBox(height: 8),
            TextField(
              controller: _amount,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                hintText: '0.00',
                hintStyle: const TextStyle(color: Colors.white24),
                suffixText: widget.coin.symbol,
                suffixStyle:
                    const TextStyle(color: gold, fontWeight: FontWeight.w700),
                filled: true,
                fillColor: const Color(0xFF161616),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: gold,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: valid
                  ? () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => SendConfirmScreen(
                          coin: widget.coin,
                          to: _to.text.trim(),
                          amount: _amount.text.trim())))
                  : null,
              child: const Text('Continue',
                  style:
                      TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Send step 3: review + PIN + broadcast.
class SendConfirmScreen extends StatefulWidget {
  final WalletCoin coin;
  final String to;
  final String amount;
  const SendConfirmScreen(
      {super.key,
      required this.coin,
      required this.to,
      required this.amount});

  @override
  State<SendConfirmScreen> createState() => _SendConfirmScreenState();
}

class _SendConfirmScreenState extends State<SendConfirmScreen> {
  final _pin = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFFFC107);
    final state = context.read<AppState>();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Confirm send',
            style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF161616),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: gold.withValues(alpha: 0.4)),
              ),
              child: Column(
                children: [
                  Text('${widget.amount} ${widget.coin.symbol}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 32,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: 12),
                  _confirmRow('To', widget.to),
                  _confirmRow('Coin', widget.coin.symbol),
                  _confirmRow('Network', _defaultNetwork(widget.coin)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Text('Wallet PIN',
                style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 14)),
            const SizedBox(height: 8),
            TextField(
              controller: _pin,
              style: const TextStyle(color: Colors.white),
              obscureText: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                hintText: 'Enter your wallet PIN',
                hintStyle: const TextStyle(color: Colors.white24),
                filled: true,
                fillColor: const Color(0xFF161616),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _sending
                  ? null
                  : () async {
                      setState(() => _sending = true);
                      try {
                        final hash = await state.wallet.sendEvm(
                          pin: _pin.text,
                          to: widget.to,
                          amountEth: double.parse(widget.amount),
                          api: state.api,
                        );
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content: Text('Broadcast: $hash')));
                          Navigator.of(context)
                              .popUntil((r) => r.isFirst);
                        }
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content: Text(
                                      'Send failed: ${e is ApiException ? e.message : e}')));
                        }
                      } finally {
                        if (mounted) setState(() => _sending = false);
                      }
                    },
              child: _sending
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Broadcast',
                      style: TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 16)),
            ),
            const SizedBox(height: 12),
            const Text(
              'TESTNET — no real value moves. Double-check the address: crypto sends cannot be reversed.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  String _defaultNetwork(WalletCoin coin) {
    if (coin.symbol == 'BTC') return 'Bitcoin';
    if (coin.symbol == 'ETH') return 'Ethereum (ERC20)';
    return '${coin.networks.first.code} (${coin.networks.first.chain})';
  }

  Widget _confirmRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 80,
              child: Text(label,
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 13))),
          Expanded(
            child: Text(value,
                style:
                    const TextStyle(color: Colors.white, fontSize: 13),
                textAlign: TextAlign.right),
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
      decoration: BoxDecoration(
          color: Colors.amber.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8)),
      child: Text(text,
          style: const TextStyle(color: Colors.amber, fontSize: 12)),
    );
  }
}
