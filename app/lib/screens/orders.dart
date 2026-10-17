import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../services/api_client.dart';
import '../state/app_state.dart';

/// TikTok Shop-grade order detail: itemized receipt + shipping/tracking timeline.
class OrderDetailScreen extends StatefulWidget {
  final String orderId;
  final bool isSeller;
  const OrderDetailScreen({super.key, required this.orderId, this.isSeller = false});

  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  OrderDetail? _detail;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await context.read<AppState>().orderDetail(widget.orderId);
      if (mounted) setState(() { _detail = d; _loading = false; });
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: ${e is ApiException ? e.message : e}')));
      }
    }
  }

  Future<void> _advance(String status) async {
    final tracking = TextEditingController();
    final carrier = TextEditingController();
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a1a1a),
        title: Text('Mark as $status', style: const TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (status == 'shipped') ...[
              TextField(controller: carrier, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'Carrier', labelStyle: TextStyle(color: Colors.white54))),
              TextField(controller: tracking, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'Tracking number', labelStyle: TextStyle(color: Colors.white54))),
            ],
            TextField(controller: note, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'Note (optional)', labelStyle: TextStyle(color: Colors.white54))),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.primary, foregroundColor: Theme.of(context).colorScheme.onPrimary),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Update'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<AppState>().trackOrder(
        orderId: widget.orderId,
        status: status,
        note: note.text.trim(),
        trackingNumber: tracking.text.trim(),
        carrier: carrier.text.trim(),
      );
      _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: ${e is ApiException ? e.message : e}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Order')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : d == null
              ? const Center(child: Text('Order not found', style: TextStyle(color: Colors.white54)))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _Card('Receipt', [
                      Text('Order ${d.receipt.orderId}', style: const TextStyle(color: Colors.white38, fontSize: 12)),
                      const SizedBox(height: 8),
                      for (final item in d.receipt.items)
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(child: Text('${item['title']}', style: const TextStyle(color: Colors.white))),
                            Text('\$${(item['priceUsd'] as num).toStringAsFixed(2)}', style: const TextStyle(color: Colors.white)),
                          ],
                        ),
                      const Divider(color: Colors.white12),
                      _Row('Shipping', d.receipt.shippingUsd),
                      _Row('Tax', d.receipt.taxUsd),
                      _Row('Total', d.receipt.totalUsd, bold: true),
                      SizedBox(height: 8),
                      Text('Paid with: ${d.receipt.paymentMethod}', style: TextStyle(color: Colors.white54, fontSize: 12)),
                      Text('Status: ${(d.order['status'] ?? '')}', style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 12)),
                      if (d.receipt.trackingNumber.isNotEmpty)
                        Text('Tracking: ${d.receipt.carrier} ${d.receipt.trackingNumber}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                    ]),
                    const SizedBox(height: 12),
                    _Card('Tracking timeline', [
                      for (final e in d.timeline)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.local_shipping, color: Color(0xFF20D5EC)),
                          title: Text(e.status, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                          subtitle: e.note.isEmpty ? null : Text(e.note, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                          trailing: Text(_ago(e.createdAt), style: const TextStyle(color: Colors.white38, fontSize: 11)),
                        ),
                    ]),
                    if (widget.isSeller) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final s in ['paid', 'shipped', 'completed', 'cancelled'])
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(backgroundColor: Color(0xFF1a1a1a), foregroundColor: Theme.of(context).colorScheme.primary),
                              onPressed: () => _advance(s),
                              child: Text(s),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
    );
  }

  Widget _Row(String label, double v, {bool bold = false}) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(color: Colors.white70, fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
          Text('\$${v.toStringAsFixed(2)}', style: TextStyle(color: Colors.white, fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
        ],
      );

  String _ago(int ms) {
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inDays > 0) return '${d.inDays}d ago';
    if (d.inHours > 0) return '${d.inHours}h ago';
    return '${d.inMinutes}m ago';
  }
}

class _Card extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Card(this.title, this.children);
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: const Color(0xFF161616), borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}
