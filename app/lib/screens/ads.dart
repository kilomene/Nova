import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_client.dart';
import '../state/app_state.dart';

/// Nova Ads — TikTok-style in-feed video ads. An advertiser turns one of
/// their own public videos into an ad: it appears in the For You feed
/// labeled "Sponsored" with a call-to-action button. Impressions and
/// clicks are counted on the server (never from the advertiser's own
/// views).
class AdManagerScreen extends StatefulWidget {
  const AdManagerScreen({super.key});

  @override
  State<AdManagerScreen> createState() => _AdManagerScreenState();
}

class _AdManagerScreenState extends State<AdManagerScreen> {
  List<dynamic>? _ads;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<AppState>().api.get('/api/ads/mine');
      if (mounted) setState(() => _ads = (r['ads'] as List?) ?? []);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is ApiException ? e.message : 'Could not load your ads. Please try again.');
      }
    }
  }

  Future<void> _togglePause(Map<String, dynamic> ad) async {
    final pause = ad['status'] == 'active';
    try {
      await context.read<AppState>().api.post('/api/ads/${ad['id']}/${pause ? 'pause' : 'resume'}', {});
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e is ApiException ? e.message : 'Action failed. Please try again.')),
        );
      }
    }
  }

  Future<void> _delete(Map<String, dynamic> ad) async {
    final api = context.read<AppState>().api;
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this ad?'),
        content: const Text('The ad stops running immediately and its stats are removed. This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await api.delete('/api/ads/${ad['id']}');
      await _load();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e is ApiException ? e.message : 'Delete failed. Please try again.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final gold = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Your ads')),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: gold,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        icon: const Icon(Icons.campaign_outlined),
        label: const Text('Create ad'),
        onPressed: () async {
          await Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const CreateAdScreen()),
          );
          _load();
        },
      ),
      body: _ads == null && _error == null
          ? Center(child: CircularProgressIndicator(color: gold))
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Colors.redAccent)))
              : _ads!.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'No ads yet.\n\nCreate one from any of your public videos and it will appear in the For You feed labeled "Sponsored", with a button that opens your link.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.5),
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _ads!.length,
                        itemBuilder: (context, i) {
                          final ad = (_ads![i] as Map).cast<String, dynamic>();
                          final impressions = (ad['impressions'] ?? 0) as int;
                          final clicks = (ad['clicks'] ?? 0) as int;
                          final ctr = impressions > 0 ? (clicks * 100.0 / impressions).toStringAsFixed(1) : '0.0';
                          final active = ad['status'] == 'active';
                          return Card(
                            color: const Color(0xFF1A1A1A),
                            margin: const EdgeInsets.only(bottom: 12),
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          (ad['video_caption'] ?? '').toString().isEmpty
                                              ? '(no caption)'
                                              : ad['video_caption'].toString(),
                                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: active ? Colors.green.withValues(alpha: 0.2) : Colors.white12,
                                          borderRadius: BorderRadius.circular(4),
                                          border: Border.all(color: active ? Colors.green : Colors.white38, width: 1),
                                        ),
                                        child: Text(active ? 'Active' : 'Paused',
                                            style: TextStyle(color: active ? Colors.green : Colors.white70, fontSize: 11, fontWeight: FontWeight.bold)),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Text('Button: "${ad['cta_label']}" → ${ad['cta_url']}',
                                      style: const TextStyle(color: Colors.white54, fontSize: 12),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                  const SizedBox(height: 10),
                                  Row(
                                    children: [
                                      _Stat(label: 'Impressions', value: '$impressions'),
                                      const SizedBox(width: 20),
                                      _Stat(label: 'Clicks', value: '$clicks'),
                                      const SizedBox(width: 20),
                                      _Stat(label: 'CTR', value: '$ctr%'),
                                      const Spacer(),
                                      TextButton(
                                        onPressed: () => _togglePause(ad),
                                        child: Text(active ? 'Pause' : 'Resume'),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                                        onPressed: () => _delete(ad),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
      ],
    );
  }
}

class CreateAdScreen extends StatefulWidget {
  const CreateAdScreen({super.key});

  @override
  State<CreateAdScreen> createState() => _CreateAdScreenState();
}

class _CreateAdScreenState extends State<CreateAdScreen> {
  List<dynamic>? _videos;
  String? _selectedVideoId;
  final _labelCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<AppState>().api.get('/api/ads/my-videos');
      if (mounted) setState(() => _videos = (r['videos'] as List?) ?? []);
    } catch (e) {
      if (mounted) {
        setState(() => _error = e is ApiException ? e.message : 'Could not load your videos. Please try again.');
      }
    }
  }

  Future<void> _create() async {
    final label = _labelCtrl.text.trim();
    final url = _urlCtrl.text.trim();
    if (_selectedVideoId == null) {
      setState(() => _error = 'Pick the video to advertise.');
      return;
    }
    if (label.isEmpty) {
      setState(() => _error = 'Give the button a label, like "Shop Now".');
      return;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      setState(() => _error = 'The link must start with https://');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<AppState>().api.post('/api/ads', {
        'video_id': _selectedVideoId,
        'cta_label': label,
        'cta_url': url,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Your ad is live in the For You feed.')),
        );
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e is ApiException ? e.message : 'Could not create the ad. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final gold = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Create ad')),
      body: _videos == null && _error == null
          ? Center(child: CircularProgressIndicator(color: gold))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text('1. Pick one of your public videos',
                    style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                if (_videos != null && _videos!.isEmpty)
                  const Text('You have no public videos yet. Post a public video first, then come back.',
                      style: TextStyle(color: Colors.white70, fontSize: 13)),
                if (_videos != null)
                  for (final v in _videos!)
                    RadioListTile<String>(
                      value: (v as Map)['id'].toString(),
                      groupValue: _selectedVideoId,
                      onChanged: (val) => setState(() => _selectedVideoId = val),
                      activeColor: gold,
                      title: Text(
                        (v['caption'] ?? '').toString().isEmpty ? '(no caption)' : v['caption'].toString(),
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('${v['like_count'] ?? 0} likes',
                          style: const TextStyle(color: Colors.white38, fontSize: 11)),
                    ),
                const SizedBox(height: 16),
                const Text('2. The button under your ad',
                    style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                TextField(
                  controller: _labelCtrl,
                  maxLength: 24,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Button label',
                    hintText: 'Shop Now',
                    border: OutlineInputBorder(),
                  ),
                ),
                TextField(
                  controller: _urlCtrl,
                  keyboardType: TextInputType.url,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Link (where the button goes)',
                    hintText: 'https://yourstore.com/product',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Your ad shows in the For You feed labeled "Sponsored". People who tap the button land on your link. You can pause or delete the ad any time.',
                  style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.4),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
                ],
                const SizedBox(height: 20),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: gold,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: _busy ? null : _create,
                  child: Text(_busy ? 'Creating…' : 'Start ad'),
                ),
              ],
            ),
    );
  }
}
