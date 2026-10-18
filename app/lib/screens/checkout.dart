import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

/// Checkout — subtotal + shipping + country tax, paid via Flutterwave escrow.
class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({super.key});

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  String _carrier = 'easyship';
  String _service = 'standard';
  String _country = 'US';
  bool _isIntl = false;
  bool _loading = false;
  Map<String, dynamic>? _quote;

  final _carriers = [
    {'id': 'easyship', 'name': 'Easyship (550+ couriers)'},
    {'id': 'fedex', 'name': 'FedEx'},
    {'id': 'ups', 'name': 'UPS'},
  ];

  final _services = [
    {'id': 'economy', 'name': 'Economy'},
    {'id': 'standard', 'name': 'Standard'},
    {'id': 'express', 'name': 'Express'},
  ];

  final _countries = ['US', 'NG', 'GB', 'DE', 'FR', 'CA', 'AU', 'GH', 'KE', 'ZA'];

  Future<void> _getQuote() async {
    final state = context.read<AppState>();
    setState(() => _loading = true);
    try {
      final res = await state.api.post('/api/market/checkout', {
        'carrier': _carrier,
        'service': _service,
        'country': _country,
        'is_international': _isIntl,
      });
      if (mounted) setState(() {
        _quote = res;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Checkout failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Checkout')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Carrier', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ..._carriers.map((c) => RadioListTile<String>(
              title: Text('${c['name']}'),
              value: c['id'] as String,
              groupValue: _carrier,
              onChanged: (v) => setState(() {
                _carrier = v!;
                _quote = null;
              }),
            )),
            const SizedBox(height: 8),
            const Text('Service level', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            ..._services.map((s) => RadioListTile<String>(
              title: Text('${s['name']}'),
              value: s['id'] as String,
              groupValue: _service,
              onChanged: (v) => setState(() {
                _service = v!;
                _quote = null;
              }),
            )),
            const SizedBox(height: 8),
            Row(
              children: [
                const Text('Country: ', style: TextStyle(fontWeight: FontWeight.bold)),
                DropdownButton<String>(
                  value: _country,
                  items: _countries.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                  onChanged: (v) => setState(() {
                    _country = v!;
                    _quote = null;
                  }),
                ),
                const SizedBox(width: 16),
                Checkbox(
                  value: _isIntl,
                  onChanged: (v) => setState(() {
                    _isIntl = v ?? false;
                    _quote = null;
                  }),
                ),
                const Text('International'),
              ],
            ),
            const SizedBox(height: 16),
            if (_quote != null) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      _row('Subtotal', '\$${(_quote!['subtotal'] as num).toStringAsFixed(2)}'),
                      _row('Shipping (${_quote!['carrier']})', '\$${(_quote!['shipping'] as num).toStringAsFixed(2)}'),
                      _row('Tax', '\$${(_quote!['tax'] as num).toStringAsFixed(2)}'),
                      const Divider(),
                      _row('Total (USD)', '\$${(_quote!['total'] as num).toStringAsFixed(2)}', bold: true),
                      const SizedBox(height: 8),
                      const Text(
                        'Payment held in escrow. Released to seller on delivery.',
                        style: TextStyle(fontSize: 12, color: Colors.grey),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _loading ? null : () {
                    // TODO: Integrate Flutterwave payment with order_id
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Payment integration coming — order created')),
                    );
                    Navigator.of(context).pop();
                  },
                  child: Text('Pay \$${(_quote!['total'] as num).toStringAsFixed(2)}'),
                ),
              ),
            ] else ...[
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _loading ? null : _getQuote,
                  child: _loading
                      ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Calculate Total'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
          Text(value, style: TextStyle(fontWeight: bold ? FontWeight.bold : FontWeight.normal, fontSize: bold ? 18 : 14)),
        ],
      ),
    );
  }
}
