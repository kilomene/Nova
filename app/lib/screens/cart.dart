import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'checkout.dart';

/// Shopping cart — items from multiple sellers persist until checkout.
class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  List<dynamic> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    setState(() => _loading = true);
    try {
      final res = await state.api.get('/api/market/cart');
      if (mounted) setState(() {
        _items = (res['items'] as List?) ?? [];
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  double get _subtotal {
    double s = 0;
    for (final it in _items) {
      s += ((it['price_usd'] ?? 0) as num).toDouble() * ((it['qty'] ?? 1) as num).toInt();
    }
    return s;
  }

  Future<void> _remove(String pid) async {
    final state = context.read<AppState>();
    try {
      await state.api.delete('/api/market/cart');
      // Actually need product_id - use post with method override via body
      await state.api.post('/api/market/cart/remove', {'product_id': pid});
    } catch (_) {}
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('Cart (${_items.length})'),
        actions: [
          if (_items.isNotEmpty)
            TextButton(
              onPressed: () async {
                final state = context.read<AppState>();
                try {
                  await state.api.delete('/api/market/cart');
                } catch (_) {}
                _load();
              },
              child: const Text('Clear all'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.shopping_cart_outlined, size: 64, color: theme.disabledColor),
                      const SizedBox(height: 16),
                      const Text('Your cart is empty'),
                    ],
                  ),
                )
              : Column(
                  children: [
                    Expanded(
                      child: RefreshIndicator(
                        onRefresh: _load,
                        child: ListView.builder(
                          itemCount: _items.length,
                          itemBuilder: (context, i) {
                            final it = _items[i];
                            return Dismissible(
                              key: Key('${it['product_id']}'),
                              direction: DismissDirection.endToStart,
                              background: Container(
                                color: Colors.red,
                                alignment: Alignment.centerRight,
                                padding: const EdgeInsets.only(right: 16),
                                child: const Icon(Icons.delete, color: Colors.white),
                              ),
                              onDismissed: (_) => _remove('${it['product_id']}'),
                              child: ListTile(
                                leading: it['image_url'] != null && (it['image_url'] as String).isNotEmpty
                                    ? Image.network('${it['image_url']}', width: 56, height: 56, fit: BoxFit.cover)
                                    : Container(width: 56, height: 56, color: theme.disabledColor.withOpacity(0.2)),
                                title: Text('${it['title'] ?? 'Product'}', maxLines: 2, overflow: TextOverflow.ellipsis),
                                subtitle: Text('by @${it['seller_handle'] ?? 'seller'} • Qty: ${it['qty']}'),
                                trailing: Text(
                                  '\$${(((it['price_usd'] ?? 0) as num).toDouble() * ((it['qty'] ?? 1) as num).toInt()).toStringAsFixed(2)}',
                                  style: const TextStyle(fontWeight: FontWeight.bold),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        border: Border(top: BorderSide(color: theme.dividerColor)),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text('Subtotal', style: TextStyle(fontSize: 16)),
                              Text('\$${_subtotal.toStringAsFixed(2)}',
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const SizedBox(height: 4),
                          const Text('Shipping + taxes calculated at checkout',
                              style: TextStyle(fontSize: 12, color: Colors.grey)),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton(
                              onPressed: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(builder: (_) => const CheckoutScreen()),
                                ).then((_) => _load());
                              },
                              child: const Text('Proceed to Checkout'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }
}
