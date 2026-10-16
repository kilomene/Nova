import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../models.dart';
import '../services/api_client.dart';
import '../state/app_state.dart';

/// P2P trading: offer board, offer detail, escrow lifecycle.
class P2PScreen extends StatefulWidget {
  const P2PScreen({super.key});

  @override
  State<P2PScreen> createState() => _P2PScreenState();
}

class _P2PScreenState extends State<P2PScreen> {
  String? _asset;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<AppState>().loadOffers());
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final offers = _asset == null ? state.offers : state.offers.where((o) => o.asset == _asset).toList();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('P2P Trading')),
      floatingActionButton: FloatingActionButton(
        backgroundColor: const Color(0xFFFFC107),
        foregroundColor: Colors.black,
        child: const Icon(Icons.add),
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CreateOfferScreen())),
      ),
      body: Column(
        children: [
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                _FilterChip(label: 'All', selected: _asset == null, onTap: () => setState(() => _asset = null)),
                for (final a in AppConfig.supportedAssets)
                  _FilterChip(label: a, selected: _asset == a, onTap: () => setState(() => _asset = a)),
              ],
            ),
          ),
          Expanded(
            child: offers.isEmpty
                ? const Center(child: Text('No offers yet — create the first one.', style: TextStyle(color: Colors.white38)))
                : ListView.builder(
                    itemCount: offers.length,
                    itemBuilder: (context, i) {
                      final o = offers[i];
                      return Card(
                        color: const Color(0xFF161616),
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        child: ListTile(
                          title: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: o.side == 'sell' ? Colors.redAccent.withValues(alpha: 0.2) : Colors.green.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(o.side.toUpperCase(), style: TextStyle(color: o.side == 'sell' ? Colors.redAccent : Colors.greenAccent, fontSize: 11, fontWeight: FontWeight.bold)),
                              ),
                              const SizedBox(width: 8),
                              Text('${o.asset} · ${o.fiatCurrency}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                            ],
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 4),
                              Text('${o.price} ${o.fiatCurrency} per ${o.asset}', style: const TextStyle(color: Color(0xFFFFC107))),
                              Text('@${o.handle} · ★ ${o.traderScore.toStringAsFixed(0)} · ${o.tradesCompleted} trades',
                                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
                              Text('Limits: ${o.minAmount} – ${o.maxAmount} ${o.asset}', style: const TextStyle(color: Colors.white38, fontSize: 12)),
                            ],
                          ),
                          trailing: const Icon(Icons.chevron_right, color: Colors.white54),
                          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => OfferDetailScreen(offer: o))),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FilterChip({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        selectedColor: const Color(0xFFFFC107),
        backgroundColor: const Color(0xFF1a1a1a),
        labelStyle: TextStyle(color: selected ? Colors.black : Colors.white70),
        onSelected: (_) => onTap(),
      ),
    );
  }
}

class CreateOfferScreen extends StatefulWidget {
  const CreateOfferScreen({super.key});

  @override
  State<CreateOfferScreen> createState() => _CreateOfferScreenState();
}

class _CreateOfferScreenState extends State<CreateOfferScreen> {
  String _side = 'sell';
  String _asset = 'USDT';
  String _fiat = 'NGN';
  final _price = TextEditingController();
  final _min = TextEditingController();
  final _max = TextEditingController();
  final _methods = TextEditingController();
  final _terms = TextEditingController();
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Create offer')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<String>(
              segments: const [ButtonSegment(value: 'sell', label: Text('Sell crypto')), ButtonSegment(value: 'buy', label: Text('Buy crypto'))],
              selected: {_side},
              onSelectionChanged: (s) => setState(() => _side = s.first),
              style: ButtonStyle(foregroundColor: WidgetStateProperty.all(Colors.white)),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _Drop(label: 'Asset', value: _asset, items: AppConfig.supportedAssets, onChanged: (v) => setState(() => _asset = v!))),
                const SizedBox(width: 12),
                Expanded(child: _Drop(label: 'Fiat', value: _fiat, items: AppConfig.fiatCurrencies, onChanged: (v) => setState(() => _fiat = v!))),
              ],
            ),
            _Field(controller: _price, label: 'Price (fiat per 1 asset)', numeric: true),
            Row(
              children: [
                Expanded(child: _Field(controller: _min, label: 'Min amount', numeric: true)),
                const SizedBox(width: 12),
                Expanded(child: _Field(controller: _max, label: 'Max amount', numeric: true)),
              ],
            ),
            _Field(controller: _methods, label: 'Payment methods (comma separated)'),
            _Field(controller: _terms, label: 'Terms (optional)'),
            const SizedBox(height: 16),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black),
              onPressed: _busy
                  ? null
                  : () async {
                      setState(() => _busy = true);
                      try {
                        await context.read<AppState>().createOffer({
                          'side': _side,
                          'asset': _asset,
                          'fiatCurrency': _fiat,
                          'price': double.parse(_price.text),
                          'minAmount': double.parse(_min.text),
                          'maxAmount': double.parse(_max.text),
                          'paymentMethods': _methods.text.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList(),
                          'terms': _terms.text.trim(),
                        });
                        if (mounted) Navigator.of(context).pop();
                      } catch (e) {
                        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: ${e is ApiException ? e.message : e}')));
                      } finally {
                        if (mounted) setState(() => _busy = false);
                      }
                    },
              child: Text(_busy ? 'Publishing…' : 'Publish offer'),
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
  const _Drop({required this.label, required this.value, required this.items, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      dropdownColor: const Color(0xFF1a1a1a),
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(labelText: label, labelStyle: const TextStyle(color: Colors.white54)),
      items: items.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
      onChanged: onChanged,
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final bool numeric;
  const _Field({required this.controller, required this.label, this.numeric = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextField(
        controller: controller,
        keyboardType: numeric ? TextInputType.number : TextInputType.text,
        style: const TextStyle(color: Colors.white),
        decoration: InputDecoration(labelText: label, labelStyle: const TextStyle(color: Colors.white54)),
      ),
    );
  }
}

/// Offer detail → open escrow → trade lifecycle.
class OfferDetailScreen extends StatefulWidget {
  final P2POffer offer;
  const OfferDetailScreen({super.key, required this.offer});

  @override
  State<OfferDetailScreen> createState() => _OfferDetailScreenState();
}

class _OfferDetailScreenState extends State<OfferDetailScreen> {
  final _amount = TextEditingController();
  Escrow? _escrow;
  bool _busy = false;

  bool get _isBuyer => _escrow != null && _escrow!.buyerUid == context.read<AppState>().auth.uid;
  bool get _isSeller => _escrow != null && _escrow!.sellerUid == context.read<AppState>().auth.uid;

  Future<void> _action(String action, String label) async {
    setState(() => _busy = true);
    try {
      final status = await context.read<AppState>().escrowAction(_escrow!.id, action);
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
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$label: $status')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: ${e is ApiException ? e.message : e}')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.offer;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: Text('${o.side.toUpperCase()} ${o.asset}')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('${o.price} ${o.fiatCurrency}', style: const TextStyle(color: Color(0xFFFFC107), fontSize: 28, fontWeight: FontWeight.bold)),
                Text(' / ${o.asset}', style: const TextStyle(color: Colors.white54)),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text('@${o.handle}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                Text('★ ${o.traderScore.toStringAsFixed(0)} · ${o.tradesCompleted} trades', style: const TextStyle(color: Colors.white54)),
              ],
            ),
            const SizedBox(height: 8),
            Text('Limits: ${o.minAmount} – ${o.maxAmount} ${o.asset}', style: const TextStyle(color: Colors.white70)),
            Text('Pay via: ${o.paymentMethods.join(', ')}', style: const TextStyle(color: Colors.white70)),
            if (o.terms.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Terms: ${o.terms}', style: const TextStyle(color: Colors.white60)),
            ],
            const Divider(color: Colors.white12, height: 32),
            if (_escrow == null) ...[
              TextField(
                controller: _amount,
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Amount in ${o.asset} (${o.minAmount} – ${o.maxAmount})',
                  labelStyle: const TextStyle(color: Colors.white54),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black),
                  onPressed: _busy
                      ? null
                      : () async {
                          setState(() => _busy = true);
                          try {
                            final e = await context.read<AppState>().openEscrow(o.id, double.parse(_amount.text));
                            setState(() => _escrow = e);
                          } catch (err) {
                            if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: ${err is ApiException ? err.message : err}')));
                          } finally {
                            if (mounted) setState(() => _busy = false);
                          }
                        },
                  child: Text(_busy ? 'Opening…' : 'Start trade (escrow)'),
                ),
              ),
              const SizedBox(height: 8),
              const Text('v1 escrow is an API-enforced state record (see SECURITY.md). On-chain HTLC escrow is phase 2.',
                  style: TextStyle(color: Colors.white38, fontSize: 12)),
            ] else ...[
              _EscrowStatusCard(escrow: _escrow!),
              const SizedBox(height: 12),
              if (_isBuyer && _escrow!.status == 'awaiting_payment')
                SizedBox(width: double.infinity, child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black), onPressed: _busy ? null : () => _action('mark-paid', 'Marked paid'), child: const Text('I have paid'))),
              if (_isSeller && _escrow!.status == 'paid')
                SizedBox(width: double.infinity, child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.green), onPressed: _busy ? null : () => _action('release', 'Released'), child: const Text('Release crypto'))),
              if ((_isBuyer || _isSeller) && (_escrow!.status == 'awaiting_payment' || _escrow!.status == 'paid')) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: OutlinedButton(style: OutlinedButton.styleFrom(foregroundColor: Colors.orangeAccent), onPressed: _busy ? null : () => _action('dispute', 'Disputed'), child: const Text('Dispute'))),
                    if (_escrow!.status == 'awaiting_payment') ...[
                      const SizedBox(width: 8),
                      Expanded(child: OutlinedButton(style: OutlinedButton.styleFrom(foregroundColor: Colors.white54), onPressed: _busy ? null : () => _action('cancel', 'Cancelled'), child: const Text('Cancel'))),
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

class _EscrowStatusCard extends StatelessWidget {
  final Escrow escrow;
  const _EscrowStatusCard({required this.escrow});

  @override
  Widget build(BuildContext context) {
    final steps = ['awaiting_payment', 'paid', 'released'];
    final idx = steps.indexOf(escrow.status);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: const Color(0xFF161616), borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Escrow ${escrow.id.substring(0, 8)}…', style: const TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 6),
          Text('${escrow.cryptoAmount} ${escrow.asset} ≈ ${escrow.fiatAmount.toStringAsFixed(2)} ${escrow.fiatCurrency}',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 10),
          Row(
            children: [
              for (var i = 0; i < steps.length; i++) ...[
                _StepDot(done: idx >= i, label: _stepLabel(steps[i])),
                if (i < steps.length - 1) Expanded(child: Container(height: 2, color: idx > i ? const Color(0xFFFFC107) : Colors.white12)),
              ],
            ],
          ),
          if (escrow.status == 'disputed')
            const Padding(padding: EdgeInsets.only(top: 8), child: Text('DISPUTED — a reviewer will resolve this trade.', style: TextStyle(color: Colors.orangeAccent, fontWeight: FontWeight.bold))),
          if (escrow.status == 'cancelled')
            const Padding(padding: EdgeInsets.only(top: 8), child: Text('Cancelled.', style: TextStyle(color: Colors.white54))),
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
          decoration: BoxDecoration(shape: BoxShape.circle, color: done ? const Color(0xFFFFC107) : Colors.white12),
          child: done ? const Icon(Icons.check, size: 14, color: Colors.black) : null,
        ),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 10)),
      ],
    );
  }
}
