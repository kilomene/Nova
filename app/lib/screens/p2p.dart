import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../models.dart';
import '../services/api_client.dart';
import '../state/app_state.dart';
import '../utils/format.dart';

/// P2P trading — Bybit/Bitget style.
/// Buy/Sell tabs, coin + fiat + payment filters, advertiser cards,
/// order flow with escrow, post-ad creation.
class P2PScreen extends StatefulWidget {
  const P2PScreen({super.key});

  @override
  State<P2PScreen> createState() => _P2PScreenState();
}

class _P2PScreenState extends State<P2PScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  String _coin = 'USDT';
  String _fiat = 'NGN';
  String? _payMethod;

  static const coins = ['USDT', 'BTC', 'ETH'];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _tabs.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => context.read<AppState>().loadOffers());
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    // side: 'sell' offer = user wants to BUY crypto from maker.
    final wantSide = _tabs.index == 0 ? 'sell' : 'buy';
    var offers = state.offers
        .where((o) => o.side == wantSide && o.asset == _coin)
        .toList();
    if (_fiat.isNotEmpty) {
      offers = offers.where((o) => o.fiatCurrency == _fiat).toList();
    }
    if (_payMethod != null) {
      offers = offers
          .where((o) => o.paymentMethods.contains(_payMethod))
          .toList();
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: TabBar(
          controller: _tabs,
          indicatorColor: Theme.of(context).colorScheme.primary,
          indicatorWeight: 3,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white54,
          labelStyle:
              const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          tabs: [Tab(text: 'Buy'), Tab(text: 'Sell')],
        ),
        actions: [
          IconButton(
            tooltip: 'Post ad',
            icon: Icon(Icons.add_circle_outline, color: Theme.of(context).colorScheme.primary),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const CreateOfferScreen())),
          ),
        ],
      ),
      body: Column(
        children: [
          // Filters: coin | fiat | payment
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Row(
              children: [
                Expanded(
                    child: _FilterDrop(
                        value: _coin,
                        items: coins,
                        onChanged: (v) => setState(() => _coin = v!))),
                const SizedBox(width: 8),
                Expanded(
                    child: _FilterDrop(
                        value: _fiat,
                        items: AppConfig.fiatCurrencies,
                        onChanged: (v) => setState(() => _fiat = v!))),
                const SizedBox(width: 8),
                Expanded(
                    child: _FilterDrop(
                        value: _payMethod ?? 'All payments',
                        items: [
                          'All payments',
                          ..._allPayMethods(state.offers)
                        ],
                        onChanged: (v) => setState(() =>
                            _payMethod = v == 'All payments' ? null : v))),
              ],
            ),
          ),
          Divider(color: Colors.white10, height: 1),
          Expanded(
            child: RefreshIndicator(
              color: Theme.of(context).colorScheme.primary,
              onRefresh: () => state.loadOffers(),
              child: offers.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 80),
                        Center(
                            child: Text(
                                'No ads match — try another coin or be the first to post.',
                                style:
                                    TextStyle(color: Colors.white38))),
                      ],
                    )
                  : ListView.separated(
                      itemCount: offers.length,
                      separatorBuilder: (_, __) =>
                          const Divider(color: Colors.white10, height: 1),
                      itemBuilder: (context, i) =>
                          _AdvertiserCard(offer: offers[i]),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  List<String> _allPayMethods(List<P2POffer> offers) {
    final s = <String>{};
    for (final o in offers) {
      s.addAll(o.paymentMethods);
    }
    return s.toList()..sort();
  }
}

class _FilterDrop extends StatelessWidget {
  final String value;
  final List<String> items;
  final void Function(String?) onChanged;
  const _FilterDrop(
      {required this.value, required this.items, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: items.contains(value) ? value : null,
          dropdownColor: const Color(0xFF1a1a1a),
          style: const TextStyle(color: Colors.white, fontSize: 13),
          isDense: true,
          items: items
              .map((e) => DropdownMenuItem(value: e, child: Text(e)))
              .toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }
}

/// Bybit-style advertiser row.
class _AdvertiserCard extends StatelessWidget {
  final P2POffer offer;
  const _AdvertiserCard({required this.offer});


  @override
  Widget build(BuildContext context) {
    final o = offer;
    // Completion rate derived from trader score (0-100 scale).
    final completion =
        o.traderScore > 0 ? o.traderScore.clamp(0, 100) : 98.0;
    return InkWell(
      onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => P2POrderScreen(offer: o))),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: const Color(0xFF2a2a2a),
                  child: Text(
                    o.handle.isNotEmpty
                        ? o.handle[0].toUpperCase()
                        : '?',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text('@${o.handle}',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 14)),
                          SizedBox(width: 6),
                          Icon(Icons.verified,
                              size: 14, color: Theme.of(context).colorScheme.primary),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${completion.toStringAsFixed(1)}% completion · ${formatCount(o.tradesCompleted)} orders',
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${o.price.toStringAsFixed(2)} ${o.fiatCurrency}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16),
                    ),
                    Text(
                      'per ${o.asset}',
                      style: const TextStyle(
                          color: Colors.white38, fontSize: 11),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Available  ${o.maxAmount} ${o.asset}',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Limit  ${o.minAmount} – ${o.maxAmount} ${o.asset}',
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 12),
                      ),
                      if (o.paymentMethods.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          children: [
                            for (final m in o.paymentMethods.take(3))
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.08),
                                  borderRadius:
                                      BorderRadius.circular(6),
                                  border: Border.all(
                                      color: Colors.white12),
                                ),
                                child: Text(m,
                                    style: const TextStyle(
                                        color: Colors.white60,
                                        fontSize: 11)),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                SizedBox(width: 12),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 26, vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) =>
                              P2POrderScreen(offer: o))),
                  child: const Text('Buy',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Order screen: amount → payment details → escrow → chat → release.
class P2POrderScreen extends StatefulWidget {
  final P2POffer offer;
  const P2POrderScreen({super.key, required this.offer});

  @override
  State<P2POrderScreen> createState() => _P2POrderScreenState();
}

class _P2POrderScreenState extends State<P2POrderScreen> {
  final _amountCtrl = TextEditingController();
  final _chatCtrl = TextEditingController();
  String _selectedMethod = '';
  Escrow? _escrow;
  bool _busy = false;
  final List<String> _chat = [];

  @override
  void initState() {
    super.initState();
    if (widget.offer.paymentMethods.isNotEmpty) {
      _selectedMethod = widget.offer.paymentMethods.first;
    }
  }

  bool get _isBuyer =>
      _escrow != null &&
      _escrow!.buyerUid == context.read<AppState>().auth.uid;
  bool get _isSeller =>
      _escrow != null &&
      _escrow!.sellerUid == context.read<AppState>().auth.uid;

  Future<void> _openEscrow() async {
    final amt = double.tryParse(_amountCtrl.text.trim());
    final o = widget.offer;
    if (amt == null || amt < o.minAmount || amt > o.maxAmount) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Enter an amount between ${o.minAmount} and ${o.maxAmount} ${o.asset}')));
      return;
    }
    setState(() => _busy = true);
    try {
      final e = await context.read<AppState>().openEscrow(o.id, amt);
      setState(() => _escrow = e);
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Failed: ${err is ApiException ? err.message : err}')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _escrowAction(String action, String label) async {
    setState(() => _busy = true);
    try {
      final status =
          await context.read<AppState>().escrowAction(_escrow!.id, action);
      setState(() => _escrow = Escrow(
            id: _escrow!.id,
            offerId: _escrow!.offerId,
            buyerUid: _escrow!.buyerUid,
            sellerUid: _escrow!.sellerUid,
            asset: _escrow!.asset,
            cryptoAmount: _escrow!.cryptoAmount,
            fiatAmount: _escrow!.fiatAmount,
            fiatCurrency: _escrow!.fiatCurrency,
            status: status,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          ));
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$label: $status')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Failed: ${e is ApiException ? e.message : e}')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.offer;
    final isBuyFlow = o.side == 'sell'; // maker sells → taker buys
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(
            '${isBuyFlow ? 'Buy' : 'Sell'} ${o.asset} with ${o.fiatCurrency}'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Advertiser header
            Row(
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: const Color(0xFF2a2a2a),
                  child: Text(
                      o.handle.isNotEmpty
                          ? o.handle[0].toUpperCase()
                          : '?',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.bold,
                          fontSize: 18)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text('@${o.handle}',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16)),
                          SizedBox(width: 6),
                          Icon(Icons.verified,
                              size: 15, color: Theme.of(context).colorScheme.primary),
                        ],
                      ),
                      Text(
                          '${formatCount(o.tradesCompleted)} orders · ★ ${o.traderScore.toStringAsFixed(0)}',
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12)),
                    ],
                  ),
                ),
                Text('${o.price.toStringAsFixed(2)}\n${o.fiatCurrency}',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
              ],
            ),
            const Divider(color: Colors.white10, height: 28),
            if (_escrow == null) ...[
              const Text('Amount',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15)),
              const SizedBox(height: 8),
              TextField(
                controller: _amountCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                style: const TextStyle(color: Colors.white, fontSize: 18),
                decoration: InputDecoration(
                  hintText: '0.00',
                  hintStyle:
                      const TextStyle(color: Colors.white24),
                  suffixText: o.asset,
                  suffixStyle:
                      const TextStyle(color: Colors.white54),
                  filled: true,
                  fillColor: const Color(0xFF161616),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                  'Limit: ${o.minAmount} – ${o.maxAmount} ${o.asset} · Available: ${o.maxAmount} ${o.asset}',
                  style:
                      const TextStyle(color: Colors.white38, fontSize: 12)),
              const SizedBox(height: 16),
              const Text('Payment method',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final m in o.paymentMethods)
                    ChoiceChip(
                      label: Text(m),
                      selected: _selectedMethod == m,
                      selectedColor: Theme.of(context).colorScheme.primary,
                      backgroundColor: const Color(0xFF161616),
                      labelStyle: TextStyle(
                          color: _selectedMethod == m
                              ? Colors.black
                              : Colors.white70),
                      onSelected: (_) =>
                          setState(() => _selectedMethod = m),
                    ),
                ],
              ),
              if (o.terms.isNotEmpty) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: const Color(0xFF161616),
                      borderRadius: BorderRadius.circular(12)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Advertiser terms',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 13)),
                      const SizedBox(height: 4),
                      Text(o.terms,
                          style: const TextStyle(
                              color: Colors.white60, fontSize: 13)),
                    ],
                  ),
                ),
              ],
              SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                    padding:
                        const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: _busy ? null : _openEscrow,
                  child: Text(
                      _busy
                          ? 'Placing order…'
                          : '${isBuyFlow ? 'Buy' : 'Sell'} ${o.asset} (escrow protected)',
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                  'Crypto is locked in Nova escrow until you confirm payment.',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: Colors.white38, fontSize: 12)),
            ] else ...[
              _EscrowProgress(escrow: _escrow!),
              const SizedBox(height: 16),
              // Payment details
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                    color: const Color(0xFF161616),
                    borderRadius: BorderRadius.circular(12)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Payment details',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text('Pay ${_escrow!.fiatAmount.toStringAsFixed(2)} ${_escrow!.fiatCurrency} via $_selectedMethod',
                        style: TextStyle(
                            color: Colors.white70)),
                    SizedBox(height: 4),
                    Text('You receive ${_escrow!.cryptoAmount} ${_escrow!.asset}',
                        style: TextStyle(color: Theme.of(context).colorScheme.primary)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              // Chat
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                    color: const Color(0xFF161616),
                    borderRadius: BorderRadius.circular(12)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Trade chat',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    if (_chat.isEmpty)
                      const Text('No messages yet — say hello.',
                          style: TextStyle(
                              color: Colors.white38, fontSize: 13)),
                    for (final m in _chat)
                      Padding(
                        padding:
                            const EdgeInsets.symmetric(vertical: 3),
                        child: Text(m,
                            style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 13)),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _chatCtrl,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 13),
                            decoration: const InputDecoration(
                              hintText: 'Message…',
                              hintStyle: TextStyle(
                                  color: Colors.white30),
                              isDense: true,
                              filled: true,
                              fillColor: Color(0xFF222222),
                              border: OutlineInputBorder(
                                  borderRadius: BorderRadius.all(
                                      Radius.circular(18)),
                                  borderSide: BorderSide.none),
                            ),
                          ),
                        ),
                        IconButton(
                          icon: Icon(Icons.send,
                              color: Theme.of(context).colorScheme.primary, size: 20),
                          onPressed: () {
                            final t = _chatCtrl.text.trim();
                            if (t.isEmpty) return;
                            setState(() {
                              _chat.add('You: $t');
                              _chatCtrl.clear();
                            });
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (_isBuyer && _escrow!.status == 'awaiting_payment')
                SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Theme.of(context).colorScheme.primary,
                            foregroundColor: Theme.of(context).colorScheme.onPrimary,
                            padding: const EdgeInsets.symmetric(
                                vertical: 14)),
                        onPressed: _busy
                            ? null
                            : () => _escrowAction(
                                'mark-paid', 'Marked paid'),
                        child: const Text('I have paid',
                            style: TextStyle(
                                fontWeight: FontWeight.bold)))),
              if (_isSeller && _escrow!.status == 'paid')
                SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            padding: const EdgeInsets.symmetric(
                                vertical: 14)),
                        onPressed: _busy
                            ? null
                            : () => _escrowAction(
                                'release', 'Released'),
                        child: const Text('Confirm receipt — release crypto',
                            style: TextStyle(
                                fontWeight: FontWeight.bold)))),
              if ((_isBuyer || _isSeller) &&
                  (_escrow!.status == 'awaiting_payment' ||
                      _escrow!.status == 'paid')) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                        child: OutlinedButton(
                            style: OutlinedButton.styleFrom(
                                foregroundColor:
                                    Colors.orangeAccent),
                            onPressed: _busy
                                ? null
                                : () => _escrowAction(
                                    'dispute', 'Disputed'),
                            child: const Text('Dispute'))),
                    if (_escrow!.status == 'awaiting_payment') ...[
                      const SizedBox(width: 8),
                      Expanded(
                          child: OutlinedButton(
                              style: OutlinedButton.styleFrom(
                                  foregroundColor:
                                      Colors.white54),
                              onPressed: _busy
                                  ? null
                                  : () => _escrowAction(
                                      'cancel', 'Cancelled'),
                              child: const Text('Cancel'))),
                    ],
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _EscrowProgress extends StatelessWidget {
  final Escrow escrow;
  const _EscrowProgress({required this.escrow});


  @override
  Widget build(BuildContext context) {
    const steps = ['awaiting_payment', 'paid', 'released'];
    final idx = steps.indexOf(escrow.status);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: const Color(0xFF161616),
          borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lock_outline,
                  color: Theme.of(context).colorScheme.primary, size: 16),
              const SizedBox(width: 6),
              Text('Escrow ${escrow.id.length > 8 ? escrow.id.substring(0, 8) : escrow.id}…',
                  style: const TextStyle(
                      color: Colors.white54, fontSize: 12)),
              Spacer(),
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20)),
                child: Text(escrow.status.replaceAll('_', ' ').toUpperCase(),
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.primary,
                        fontSize: 11,
                        fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (var i = 0; i < steps.length; i++) ...[
                _StepDot(
                    done: idx >= i,
                    label: _stepLabel(steps[i])),
                if (i < steps.length - 1)
                  Expanded(
                      child: Container(
                          height: 2,
                          color: idx > i ? Theme.of(context).colorScheme.primary : Colors.white12)),
              ],
            ],
          ),
          if (escrow.status == 'disputed')
            const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                    'DISPUTED — a reviewer will resolve this trade.',
                    style: TextStyle(
                        color: Colors.orangeAccent,
                        fontWeight: FontWeight.bold))),
          if (escrow.status == 'cancelled')
            const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Cancelled.',
                    style: TextStyle(color: Colors.white54))),
        ],
      ),
    );
  }

  String _stepLabel(String s) => switch (s) {
        'awaiting_payment' => 'Escrowed',
        'paid' => 'Paid',
        'released' => 'Released',
        _ => s,
      };
}

class _StepDot extends StatelessWidget {
  final bool done;
  final String label;
  const _StepDot({required this.done, required this.label});


  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: done ? Theme.of(context).colorScheme.primary : Colors.white12),
          child: done
              ? const Icon(Icons.check, size: 14, color: Colors.black)
              : null,
        ),
        const SizedBox(height: 4),
        Text(label,
            style:
                const TextStyle(color: Colors.white54, fontSize: 10)),
      ],
    );
  }
}

/// Post ad — create a buy/sell ad (Bybit style).
class CreateOfferScreen extends StatefulWidget {
  const CreateOfferScreen({super.key});

  @override
  State<CreateOfferScreen> createState() => _CreateOfferScreenState();
}

class _CreateOfferScreenState extends State<CreateOfferScreen> {
  String _side = 'sell'; // maker sells → buyers come
  String _asset = 'USDT';
  String _fiat = 'NGN';
  final _price = TextEditingController();
  final _available = TextEditingController();
  final _min = TextEditingController();
  final _max = TextEditingController();
  final _methods = TextEditingController();
  final _terms = TextEditingController();
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
          backgroundColor: Colors.black, title: const Text('Post ad')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                    value: 'sell', label: Text('I want to sell')),
                ButtonSegment(
                    value: 'buy', label: Text('I want to buy')),
              ],
              selected: {_side},
              onSelectionChanged: (s) =>
                  setState(() => _side = s.first),
              style: ButtonStyle(
                  backgroundColor:
                      WidgetStateProperty.resolveWith((states) =>
                          states.contains(WidgetState.selected)
                              ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.2)
                              : null),
                  foregroundColor:
                      WidgetStateProperty.all(Colors.white)),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                    child: _Drop(
                        label: 'Crypto',
                        value: _asset,
                        items: const ['USDT', 'BTC', 'ETH'],
                        onChanged: (v) =>
                            setState(() => _asset = v!))),
                const SizedBox(width: 12),
                Expanded(
                    child: _Drop(
                        label: 'Fiat',
                        value: _fiat,
                        items: AppConfig.fiatCurrencies,
                        onChanged: (v) =>
                            setState(() => _fiat = v!))),
              ],
            ),
            _Field(
                controller: _price,
                label: 'Price ($_fiat per 1 $_asset)',
                numeric: true),
            _Field(
                controller: _available,
                label: 'Available amount ($_asset)',
                numeric: true),
            Row(
              children: [
                Expanded(
                    child: _Field(
                        controller: _min,
                        label: 'Min order',
                        numeric: true)),
                const SizedBox(width: 12),
                Expanded(
                    child: _Field(
                        controller: _max,
                        label: 'Max order',
                        numeric: true)),
              ],
            ),
            _Field(
                controller: _methods,
                label: 'Payment methods (comma separated)'),
            _Field(controller: _terms, label: 'Terms (optional)'),
            SizedBox(height: 16),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  padding:
                      const EdgeInsets.symmetric(vertical: 14)),
              onPressed: _busy
                  ? null
                  : () async {
                      setState(() => _busy = true);
                      try {
                        await context.read<AppState>().createOffer({
                          'side': _side,
                          'asset': _asset,
                          'fiatCurrency': _fiat,
                          'price':
                              double.parse(_price.text),
                          'minAmount':
                              double.parse(_min.text),
                          'maxAmount':
                              double.parse(_max.text),
                          'paymentMethods': _methods.text
                              .split(',')
                              .map((e) => e.trim())
                              .where((e) => e.isNotEmpty)
                              .toList(),
                          'terms': _terms.text.trim(),
                        });
                        if (mounted) {
                          Navigator.of(context).pop();
                        }
                      } catch (e) {
                        if (mounted) {
                          ScaffoldMessenger.of(context)
                              .showSnackBar(SnackBar(
                                  content: Text(
                                      'Failed: ${e is ApiException ? e.message : e}')));
                        }
                      } finally {
                        if (mounted) {
                          setState(() => _busy = false);
                        }
                      }
                    },
              child: Text(_busy ? 'Posting…' : 'Post ad',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Drop extends StatelessWidget {
  final String label;
  final String value;
  final List<String> items;
  final void Function(String?) onChanged;
  const _Drop(
      {required this.label,
      required this.value,
      required this.items,
      required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: items.contains(value) ? value : items.first,
      dropdownColor: const Color(0xFF1a1a1a),
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: Colors.white54)),
      items: items
          .map((e) => DropdownMenuItem(value: e, child: Text(e)))
          .toList(),
      onChanged: onChanged,
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool numeric;
  const _Field(
      {required this.controller,
      required this.label,
      this.numeric = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextField(
        controller: controller,
        keyboardType: numeric
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.text,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(
            labelText: label,
            labelStyle: const TextStyle(color: Colors.white54)),
      ),
    );
  }
}
