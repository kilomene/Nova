import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

/// TikTok Promote-style post promotion.
/// Packages from $7/day -> ~1,000 mixed engagements/day (followers/likes/views).
/// Paid via Flutterwave. Reach is ESTIMATED, never guaranteed. Promoted
/// videos get real ranking amplification and are labeled "Promoted".
class PromoteScreen extends StatefulWidget {
  final String videoId;
  const PromoteScreen({super.key, required this.videoId});

  @override
  State<PromoteScreen> createState() => _PromoteScreenState();
}

class _PromoteScreenState extends State<PromoteScreen> {
  Map<String, dynamic>? _packages;
  String _selected = 'starter';
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<AppState>().api.get('/api/promotions/packages');
      if (mounted) setState(() => _packages = (r['packages'] as Map).cast<String, dynamic>());
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load packages: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final pkgs = _packages;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Promote video')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Boost this video in the For You feed.',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            const Text('Estimated reach — not guaranteed. Promoted videos are labeled "Promoted".',
                style: TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 16),
            if (pkgs == null && _error == null)
              const Center(child: CircularProgressIndicator(color: Color(0xFFFFC107))),
            if (_error != null) Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            if (pkgs != null)
              for (final id in pkgs.keys)
                _PackageCard(
                  id: id,
                  spec: (pkgs[id] as Map).cast<String, dynamic>(),
                  selected: _selected == id,
                  onTap: () => setState(() => _selected = id),
                ),
            const Spacer(),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black),
              onPressed: (_busy || pkgs == null)
                  ? null
                  : () async {
                      setState(() {
                        _busy = true;
                        _error = null;
                      });
                      try {
                        final r = await context.read<AppState>().api.post('/api/promotions', {
                          'videoId': widget.videoId,
                          'package': _selected,
                        });
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(
                                  'Payment started (${r['amount']} USD). Promotion activates after payment confirmation.')));
                          Navigator.of(context).pop();
                        }
                      } catch (e) {
                        setState(() => _error = 'Failed: $e');
                      } finally {
                        if (mounted) setState(() => _busy = false);
                      }
                    },
              child: Text(_busy ? 'Starting…' : 'Promote'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PackageCard extends StatelessWidget {
  final String id;
  final Map<String, dynamic> spec;
  final bool selected;
  final VoidCallback onTap;
  const _PackageCard({required this.id, required this.spec, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF161616),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? const Color(0xFFFFC107) : Colors.white12, width: 2),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(id.toUpperCase(),
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 4),
                  Text('${spec['days']} day(s) · ~${spec['estReach']} engagements',
                      style: const TextStyle(color: Colors.white70, fontSize: 13)),
                ],
              ),
            ),
            Text('\$${spec['amount']}', style: const TextStyle(color: Color(0xFFFFC107), fontSize: 20, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}

/// Promotion metrics dashboard (views/likes/follows attributed to the boost).
class PromotionMetricsScreen extends StatefulWidget {
  final String promotionId;
  const PromotionMetricsScreen({super.key, required this.promotionId});

  @override
  State<PromotionMetricsScreen> createState() => _PromotionMetricsScreenState();
}

class _PromotionMetricsScreenState extends State<PromotionMetricsScreen> {
  Map<String, dynamic>? _data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<AppState>().api.get('/api/promotions/${widget.promotionId}/metrics');
      if (mounted) setState(() => _data = r.cast<String, dynamic>());
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final totals = (_data?['totals'] as Map?)?.cast<String, dynamic>();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Promotion metrics')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: _data == null
            ? const Center(child: CircularProgressIndicator(color: Color(0xFFFFC107)))
            : Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _Stat('Views', '${totals?['views'] ?? 0}'),
                      _Stat('Likes', '${totals?['likes'] ?? 0}'),
                      _Stat('Follows', '${totals?['follows'] ?? 0}'),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text('Estimated reach is not guaranteed. Metrics update daily.',
                      style: TextStyle(color: Colors.white38, fontSize: 12)),
                ],
              ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(value, style: const TextStyle(color: Color(0xFFFFC107), fontSize: 28, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(color: Colors.white54)),
      ],
    );
  }
}
