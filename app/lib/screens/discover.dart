import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import 'hashtag.dart';

/// Discovery: search videos/users/hashtags + trending tags.
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  final _q = TextEditingController();
  String _query = '';
  List<Map<String, dynamic>> _trending = [];

  @override
  void initState() {
    super.initState();
    _loadTrending();
  }

  Future<void> _loadTrending() async {
    final t = await context.read<AppState>().trendingHashtags();
    if (mounted) setState(() => _trending = t);
  }

  void _submit(String v) {
    final q = v.trim();
    // #tag search goes straight to the hashtag page.
    if (q.startsWith('#') && q.length > 1) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => HashtagScreen(tag: q.substring(1).toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '')),
      ));
      return;
    }
    setState(() => _query = q);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final q = _query.toLowerCase();
    final videos = q.isEmpty
        ? <dynamic>[]
        : state.feed
            .where((v) =>
                v.caption.toLowerCase().contains(q) ||
                v.handle.toLowerCase().contains(q) ||
                v.hashtags.any((h) => h.toLowerCase().contains(q)))
            .toList();

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Discover')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _q,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Search videos, creators, #hashtags',
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon: const Icon(Icons.search, color: Colors.white54),
                filled: true,
                fillColor: const Color(0xFF161616),
                border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(12)), borderSide: BorderSide.none),
              ),
              onSubmitted: _submit,
            ),
          ),
          if (q.isEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Align(alignment: Alignment.centerLeft, child: Text('Trending hashtags', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16))),
            ),
            Expanded(
              child: _trending.isEmpty
                  ? const Center(child: Text('No trending tags yet — be the first to post.', style: TextStyle(color: Colors.white38)))
                  : GridView.builder(
                      padding: const EdgeInsets.all(12),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, childAspectRatio: 1.6, crossAxisSpacing: 8, mainAxisSpacing: 8),
                      itemCount: _trending.length,
                      itemBuilder: (context, i) {
                        final tag = '${_trending[i]['tag']}';
                        final uses = _trending[i]['uses'];
                        return GestureDetector(
                          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => HashtagScreen(tag: tag))),
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(colors: [Color(0xFF2a2a2a), Color(0xFF1a1a1a)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text('#$tag', style: const TextStyle(color: Color(0xFFFFC107), fontWeight: FontWeight.bold, fontSize: 16)),
                                  if (uses != null) Text('$uses videos', style: const TextStyle(color: Colors.white38, fontSize: 11)),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ] else
            Expanded(
              child: videos.isEmpty
                  ? const Center(child: Text('No results', style: TextStyle(color: Colors.white38)))
                  : ListView.builder(
                      itemCount: videos.length,
                      itemBuilder: (context, i) {
                        final v = videos[i];
                        return ListTile(
                          leading: Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(color: const Color(0xFF1a1a1a), borderRadius: BorderRadius.circular(8)),
                            child: const Icon(Icons.play_arrow, color: Colors.white54),
                          ),
                          title: Text(v.caption.isEmpty ? '@${v.handle}' : v.caption, style: const TextStyle(color: Colors.white), maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text('@${v.handle}', style: const TextStyle(color: Colors.white54)),
                          onTap: () => Navigator.of(context).push(MaterialPageRoute(
                            builder: (_) => VideoViewerScreen(videos: List.from(videos), initialIndex: i),
                          )),
                        );
                      },
                    ),
            ),
        ],
      ),
    );
  }
}
