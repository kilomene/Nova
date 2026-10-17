import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../state/app_state.dart';
import '../utils/format.dart';
import 'hashtag.dart';
import 'profile.dart';

/// TikTok-style search with category tabs:
/// Ask | Top | Users | Videos | Shop | Sounds | LIVE | Places | Photos | Hashtags
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> with SingleTickerProviderStateMixin {
  final _q = TextEditingController();
  String _query = '';
  late TabController _tabs;
  String _activeFilter = 'Latest';

  static const _tabLabels = [
    'Ask', 'Top', 'Users', 'Videos', 'Shop', 'Sounds', 'LIVE', 'Places', 'Photos', 'Hashtags',
  ];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: _tabLabels.length, vsync: this, initialIndex: 1);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _q.dispose();
    super.dispose();
  }

  void _submit(String v) {
    final q = v.trim();
    if (q.startsWith('#') && q.length > 1) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => HashtagScreen(tag: q.substring(1).toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '')),
      ));
      return;
    }
    setState(() => _query = q);
  }

  List<NovaVideo> _matchedVideos(AppState state) {
    final q = _query.toLowerCase();
    if (q.isEmpty) return [];
    return state.feed
        .where((v) =>
            v.caption.toLowerCase().contains(q) ||
            v.handle.toLowerCase().contains(q) ||
            v.hashtags.any((h) => h.toLowerCase().contains(q)) ||
            v.soundLabel.toLowerCase().contains(q))
        .toList();
  }

  List<NovaVideo> _matchedUsers(List<NovaVideo> videos) {
    final seen = <String>{};
    final out = <NovaVideo>[];
    for (final v in videos) {
      if (seen.add(v.uid)) out.add(v);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final videos = _matchedVideos(state);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 4),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _q,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Search',
                        hintStyle: const TextStyle(color: Colors.white38),
                        prefixIcon: const Icon(Icons.search, color: Colors.white54, size: 20),
                        suffixIcon: _q.text.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close, color: Colors.white54, size: 18),
                                onPressed: () {
                                  _q.clear();
                                  setState(() => _query = '');
                                },
                              ),
                        filled: true,
                        fillColor: const Color(0xFF161616),
                        contentPadding: const EdgeInsets.symmetric(vertical: 10),
                        border: const OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(10)),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      onSubmitted: _submit,
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.more_horiz, color: Colors.white),
                    onPressed: () {},
                  ),
                ],
              ),
            ),
            TabBar(
              controller: _tabs,
              isScrollable: true,
              indicatorColor: Theme.of(context).colorScheme.primary,
              indicatorWeight: 3,
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white54,
              labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              tabs: _tabLabels.map((t) => Tab(text: t)).toList(),
            ),
            const Divider(height: 1, color: Color(0xFF222222)),
            Expanded(
              child: _query.isEmpty
                  ? _buildEmptyState(state)
                  : TabBarView(
                      controller: _tabs,
                      children: [
                        _buildAskTab(),
                        _buildTopTab(state, videos),
                        _buildUsersTab(state, videos),
                        _buildVideosTab(videos),
                        _buildShopTab(),
                        _buildSoundsTab(videos),
                        _buildLiveTab(state),
                        _buildPlacesTab(),
                        _buildPhotosTab(videos),
                        _buildHashtagsTab(state),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(AppState state) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: state.trendingHashtags(),
      builder: (context, snap) {
        final trending = snap.data ?? [];
        if (trending.isEmpty) {
          return const Center(
            child: Text('Search videos, users, sounds and more', style: TextStyle(color: Colors.white38)),
          );
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('Trending hashtags', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 12),
            ...trending.map((t) {
              final tag = '${t['tag']}';
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(color: Color(0xFF1a1a1a), borderRadius: BorderRadius.circular(8)),
                  child: Center(child: Text('#', style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 20, fontWeight: FontWeight.bold))),
                ),
                title: Text('#$tag', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                subtitle: Text('${t['uses'] ?? 0} videos', style: const TextStyle(color: Colors.white38, fontSize: 12)),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => HashtagScreen(tag: tag))),
              );
            }),
          ],
        );
      },
    );
  }

  Widget _buildAskTab() {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome, color: Theme.of(context).colorScheme.primary, size: 48),
            const SizedBox(height: 16),
            Text('Ask about "$_query"', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            const Text('AI-powered answers are coming soon.', style: TextStyle(color: Colors.white38)),
          ],
        ),
      ),
    );
  }

  Widget _buildTopTab(AppState state, List<NovaVideo> videos) {
    final chips = ['Latest', ..._query.split(' ').where((w) => w.length > 2).take(3), 'Sound', 'Price'];
    return Column(
      children: [
        SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            itemCount: chips.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final c = chips[i];
              final active = c == _activeFilter;
              return GestureDetector(
                onTap: () => setState(() => _activeFilter = c),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: active ? Colors.white : const Color(0xFF1c1c1c),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(c, style: TextStyle(color: active ? Colors.black : Colors.white70, fontSize: 13, fontWeight: FontWeight.w500)),
                ),
              );
            },
          ),
        ),
        Expanded(child: _videoGrid2Col(videos)),
      ],
    );
  }

  Widget _videoGrid2Col(List<NovaVideo> videos) {
    if (videos.isEmpty) return const Center(child: Text('No results', style: TextStyle(color: Colors.white38)));
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2, crossAxisSpacing: 8, mainAxisSpacing: 12, childAspectRatio: 0.62,
      ),
      itemCount: videos.length,
      itemBuilder: (context, i) => _videoCard(videos[i], videos, i),
    );
  }

  Widget _videoCard(NovaVideo v, List<NovaVideo> list, int index) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VideoViewerScreen(videos: List.from(list), initialIndex: index),
      )),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(color: const Color(0xFF1a1a1a), borderRadius: BorderRadius.circular(8)),
              child: v.mediaUrl.isEmpty
                  ? const Center(child: Icon(Icons.play_arrow, color: Colors.white30, size: 36))
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(v.mediaUrl, fit: BoxFit.cover, width: double.infinity,
                        errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.play_arrow, color: Colors.white30, size: 36))),
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(v.caption.isEmpty ? '@${v.handle}' : v.caption,
              style: const TextStyle(color: Colors.white, fontSize: 12), maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                _avatar(v.avatarUrl, 18),
                const SizedBox(width: 4),
                Expanded(child: Text(v.handle, style: const TextStyle(color: Colors.white54, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis)),
                const Icon(Icons.favorite, color: Colors.white38, size: 12),
                const SizedBox(width: 2),
                Text(formatCount(v.likeCount), style: const TextStyle(color: Colors.white38, fontSize: 11)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUsersTab(AppState state, List<NovaVideo> videos) {
    final users = _matchedUsers(videos);
    if (users.isEmpty) return const Center(child: Text('No users found', style: TextStyle(color: Colors.white38)));
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: users.length,
      separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFF1a1a1a)),
      itemBuilder: (context, i) {
        final u = users[i];
        final following = state.followingUids.contains(u.uid);
        return ListTile(
          leading: _avatar(u.avatarUrl, 48),
          title: Text('@${u.handle}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
          subtitle: Text(
            '${u.displayName.isEmpty ? u.handle : u.displayName}\n${formatCount(u.viewCount)} followers · ${formatCount(u.likeCount)} likes',
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
          isThreeLine: true,
          trailing: ElevatedButton(
            onPressed: () => state.toggleFollow(u.uid),
            style: ElevatedButton.styleFrom(
              backgroundColor: following ? Color(0xFF1c1c1c) : Theme.of(context).colorScheme.primary,
              foregroundColor: following ? Colors.white : Colors.black,
              minimumSize: const Size(90, 34),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            child: Text(following ? 'Following' : 'Follow', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProfileScreen(handle: u.handle))),
        );
      },
    );
  }

  Widget _buildVideosTab(List<NovaVideo> videos) {
    if (videos.isEmpty) return const Center(child: Text('No videos found', style: TextStyle(color: Colors.white38)));
    return GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3, crossAxisSpacing: 2, mainAxisSpacing: 2, childAspectRatio: 0.75,
      ),
      itemCount: videos.length,
      itemBuilder: (context, i) {
        final v = videos[i];
        return GestureDetector(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => VideoViewerScreen(videos: List.from(videos), initialIndex: i),
          )),
          child: Container(
            color: const Color(0xFF141414),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (v.mediaUrl.isNotEmpty)
                  Image.network(v.mediaUrl, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.play_arrow, color: Colors.white30))),
                if (v.mediaUrl.isEmpty) const Center(child: Icon(Icons.play_arrow, color: Colors.white30)),
                Positioned(
                  bottom: 4, left: 4,
                  child: Row(
                    children: [
                      const Icon(Icons.play_arrow, color: Colors.white, size: 12),
                      Text(formatCount(v.viewCount), style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildShopTab() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Text('Shop results for your search will appear here.', style: TextStyle(color: Colors.white38), textAlign: TextAlign.center),
      ),
    );
  }

  Widget _buildSoundsTab(List<NovaVideo> videos) {
    final seen = <String>{};
    final sounds = <NovaVideo>[];
    for (final v in videos) {
      if (v.soundLabel.isNotEmpty && seen.add(v.soundLabel)) sounds.add(v);
    }
    if (sounds.isEmpty) return const Center(child: Text('No sounds found', style: TextStyle(color: Colors.white38)));
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: sounds.length,
      separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFF1a1a1a)),
      itemBuilder: (context, i) {
        final s = sounds[i];
        final useCount = videos.where((v) => v.soundLabel == s.soundLabel).length;
        return ListTile(
          leading: Container(
            width: 48, height: 48,
            decoration: BoxDecoration(color: const Color(0xFF1a1a1a), borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.play_arrow, color: Colors.white),
          ),
          title: Text(s.soundLabel, style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14), maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text('Contains music from: ${s.handle}\n0:30 · $useCount videos', style: TextStyle(color: Colors.white54, fontSize: 12)),
          isThreeLine: true,
          trailing: Container(
            width: 40, height: 40,
            decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, borderRadius: BorderRadius.circular(8)),
            child: const Icon(Icons.videocam, color: Colors.black, size: 20),
          ),
          onTap: () {},
        );
      },
    );
  }

  Widget _buildLiveTab(AppState state) {
    final q = _query.toLowerCase();
    final lives = state.liveSessions
        .where((l) => l.title.toLowerCase().contains(q) || l.handle.toLowerCase().contains(q))
        .toList();
    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        if (lives.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: Text('No LIVE streams found', style: TextStyle(color: Colors.white38))),
          )
        else
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2, crossAxisSpacing: 8, mainAxisSpacing: 12, childAspectRatio: 0.7,
            ),
            itemCount: lives.length,
            itemBuilder: (context, i) => _liveCard(lives[i]),
          ),
        const Padding(
          padding: EdgeInsets.fromLTRB(8, 16, 8, 8),
          child: Text('Trending', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
        ),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2, crossAxisSpacing: 8, mainAxisSpacing: 12, childAspectRatio: 0.7,
          ),
          itemCount: state.liveSessions.length,
          itemBuilder: (context, i) => _liveCard(state.liveSessions[i]),
        ),
      ],
    );
  }

  Widget _liveCard(LiveSession l) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(color: const Color(0xFF1a1a1a), borderRadius: BorderRadius.circular(8)),
            child: Stack(
              children: [
                const Center(child: Icon(Icons.live_tv, color: Colors.white24, size: 36)),
                Positioned(
                  top: 6, left: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: const Color(0xFFFF2D55), borderRadius: BorderRadius.circular(4)),
                    child: Text('LIVE · ${formatCount(l.viewerCount)}', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(l.title.isEmpty ? 'Live stream' : l.title,
            style: const TextStyle(color: Colors.white, fontSize: 12), maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(
            children: [
              _avatar(l.avatarUrl, 16),
              const SizedBox(width: 4),
              Expanded(child: Text(l.handle, style: const TextStyle(color: Colors.white54, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPlacesTab() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Text('Places near your search will appear here.', style: TextStyle(color: Colors.white38), textAlign: TextAlign.center),
      ),
    );
  }

  Widget _buildPhotosTab(List<NovaVideo> videos) {
    return _buildVideosTab(videos);
  }

  Widget _buildHashtagsTab(AppState state) {
    final q = _query.toLowerCase().replaceAll('#', '');
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: state.trendingHashtags(),
      builder: (context, snap) {
        final all = snap.data ?? [];
        final tags = q.isEmpty ? all : all.where((t) => '${t['tag']}'.toLowerCase().contains(q)).toList();
        if (tags.isEmpty) return const Center(child: Text('No hashtags found', style: TextStyle(color: Colors.white38)));
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: tags.length,
          separatorBuilder: (_, __) => const Divider(height: 1, color: Color(0xFF1a1a1a)),
          itemBuilder: (context, i) {
            final tag = '${tags[i]['tag']}';
            return ListTile(
              leading: Container(
                width: 44, height: 44,
                decoration: BoxDecoration(color: Color(0xFF1a1a1a), borderRadius: BorderRadius.circular(8)),
                child: Center(child: Text('#', style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 20, fontWeight: FontWeight.bold))),
              ),
              title: Text('#$tag', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              subtitle: Text('${tags[i]['uses'] ?? 0} videos', style: const TextStyle(color: Colors.white54, fontSize: 12)),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => HashtagScreen(tag: tag))),
            );
          },
        );
      },
    );
  }

  Widget _avatar(String url, double size) {
    return ClipOval(
      child: Container(
        width: size, height: size, color: const Color(0xFF2a2a2a),
        child: url.isEmpty
            ? Icon(Icons.person, color: Colors.white38, size: size * 0.6)
            : Image.network(url, fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Icon(Icons.person, color: Colors.white38, size: size * 0.6)),
      ),
    );
  }
}
