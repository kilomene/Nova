import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../models.dart';

/// Sound page — shows videos using a specific sound.
class SoundPage extends StatefulWidget {
  final String soundLabel;
  final String soundKey;
  const SoundPage({super.key, required this.soundLabel, this.soundKey = ''});

  @override
  State<SoundPage> createState() => _SoundPageState();
}

class _SoundPageState extends State<SoundPage> {
  List<NovaVideo> _videos = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    try {
      // Filter feed by sound label
      final all = state.feed;
      final filtered = all.where((v) => v.soundLabel == widget.soundLabel).toList();
      if (mounted) setState(() {
        _videos = filtered;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white70 : Colors.black54;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.share_outlined),
            onPressed: () {},
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: Theme.of(context).colorScheme.primary, width: 2),
                          ),
                          child: const Icon(Icons.music_note, size: 36),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Original Sound',
                                  style: TextStyle(color: fg, fontWeight: FontWeight.bold, fontSize: 18)),
                              Text(widget.soundLabel.isNotEmpty ? widget.soundLabel : 'Unknown artist',
                                  style: TextStyle(color: fg, fontSize: 15)),
                              Text('${_videos.length} posts',
                                  style: TextStyle(color: sub, fontSize: 13)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.bookmark_border, size: 18),
                            label: const Text('Save'),
                            onPressed: () {},
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.videocam_outlined, size: 18),
                            label: const Text('Use sound'),
                            onPressed: () {
                              Navigator.pop(context);
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
                SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 2,
                    mainAxisSpacing: 2,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (context, i) {
                      final v = _videos[i];
                      return Container(
                        color: isDark ? Colors.white10 : Colors.black12,
                        child: const Center(child: Icon(Icons.play_arrow, color: Colors.white54)),
                      );
                    },
                    childCount: _videos.length,
                  ),
                ),
              ],
            ),
    );
  }
}
