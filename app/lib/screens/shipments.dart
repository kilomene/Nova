import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

/// Marketplace shipments — tracking numbers and receipts.
class ShipmentsScreen extends StatefulWidget {
  const ShipmentsScreen({super.key});

  @override
  State<ShipmentsScreen> createState() => _ShipmentsScreenState();
}

class _ShipmentsScreenState extends State<ShipmentsScreen> {
  List<dynamic> _shipments = [];
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
      final res = await state.api.get('/api/market/shipments');
      if (mounted) setState(() {
        _shipments = (res['shipments'] as List?) ?? [];
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Shipments')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _shipments.isEmpty
              ? const Center(child: Text('No shipments yet'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    itemCount: _shipments.length,
                    itemBuilder: (context, i) {
                      final s = _shipments[i];
                      return Card(
                        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        child: ListTile(
                          leading: const Icon(Icons.local_shipping, size: 36),
                          title: Text('${s['product_title'] ?? 'Order'}'),
                          subtitle: Text(
                              '${s['carrier'] ?? ''} • ${s['service'] ?? ''}\nTracking: ${s['tracking_number'] ?? '—'}\nStatus: ${s['status'] ?? 'label_created'}'),
                        ),
                      );
                    },
                  ),
                ),
    );
  }
}
