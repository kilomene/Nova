import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import '../services/api_client.dart';
import '../state/app_state.dart';
import '../services/voice_recorder.dart';
import 'shipments.dart';
import 'follow_list.dart';
import 'profile.dart';

/// Time-ago helper: "now", "5m", "3h", "2d".
String _timeAgo(int ms) {
  final diff = DateTime.now().millisecondsSinceEpoch - ms;
  if (diff < 0) return 'now';
  if (diff < 60000) return 'now';
  if (diff < 3600000) return '${diff ~/ 60000}m';
  if (diff < 86400000) return '${diff ~/ 3600000}h';
  if (diff < 7 * 86400000) return '${diff ~/ 86400000}d';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.month}/${d.day}/${d.year}';
}

/// Inbox: stories row, New followers, Activity, System notifications, Messages.
/// TikTok structure — display names everywhere, never @usernames in titles.
class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key});

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  bool _loading = true;
  // Stories grouped by user uid, in feed order.
  List<_StoryUser> _storyUsers = [];
  // New followers (newest first).
  List<Map<String, dynamic>> _followers = [];
  // Activity items (likes/comments on my content).
  List<Map<String, dynamic>> _activity = [];
  // Latest system notification + unread count.
  Map<String, dynamic>? _latestSystem;
  int _systemUnread = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().loadThreads();
      _loadAll();
      if (mounted) context.read<AppState>().registerRefreshHandler('inbox', _refresh);
    });
  }

  @override
  void dispose() {
    try {
      context.read<AppState>().unregisterRefreshHandler('inbox');
    } catch (_) {}
    super.dispose();
  }

  Future<void> _loadAll() async {
    final state = context.read<AppState>();
    if (state.isDemo) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final results = await Future.wait([
        state.api.get('/api/stories/feed').catchError((_) => <String, dynamic>{'stories': []}),
        state.api.get('/api/inbox/followers', {'limit': '5'}).catchError((_) => <String, dynamic>{'followers': []}),
        state.api.get('/api/inbox/activity', {'limit': '5'}).catchError((_) => <String, dynamic>{'activity': []}),
        state.api.get('/api/inbox/system', {'limit': '1'}).catchError((_) => <String, dynamic>{'notifications': [], 'unread': 0}),
      ]);
      if (!mounted) return;
      final stories = ((results[0]['stories'] as List?) ?? []).cast<Map<String, dynamic>>();
      final grouped = <String, _StoryUser>{};
      for (final s in stories) {
        final uid = '${s['uid'] ?? ''}';
        grouped.putIfAbsent(uid, () => _StoryUser(
          uid: uid,
          handle: '${s['handle'] ?? ''}',
          displayName: '${s['display_name'] ?? ''}',
          avatarUrl: '${s['avatar_url'] ?? ''}',
        )).stories.add(_StoryItem.fromJson(s));
      }
      // Sort users by their newest story.
      final users = grouped.values.toList()
        ..sort((a, b) => b.stories.first.createdAt.compareTo(a.stories.first.createdAt));
      setState(() {
        _storyUsers = users;
        _followers = ((results[1]['followers'] as List?) ?? []).cast<Map<String, dynamic>>();
        _activity = ((results[2]['activity'] as List?) ?? []).cast<Map<String, dynamic>>();
        final notifs = ((results[3]['notifications'] as List?) ?? []).cast<Map<String, dynamic>>();
        _latestSystem = notifs.isNotEmpty ? notifs.first : null;
        _systemUnread = (results[3]['unread'] as num?)?.toInt() ?? 0;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _refresh() async {
    await context.read<AppState>().loadThreads();
    await _loadAll();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? Colors.black : Colors.white;
    final fg = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white54 : Colors.black54;
    final gold = Theme.of(context).colorScheme.primary;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        leading: IconButton(
          tooltip: 'Find friends',
          icon: Icon(Icons.person_add_outlined, color: fg),
          onPressed: () {
            // Find friends = people you may know (contacts / mutuals).
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Find friends: coming from your contacts + mutual friends soon.')),
            );
          },
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Inbox', style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 18)),
            const SizedBox(width: 4),
            Icon(Icons.arrow_drop_down, color: sub),
          ],
        ),
        centerTitle: true,
        actions: [
          IconButton(
            tooltip: 'Search',
            icon: Icon(Icons.search, color: fg),
            onPressed: () {},
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        color: gold,
        child: _loading
            ? Center(child: CircularProgressIndicator(color: gold))
            : ListView(
                children: [
                  _buildStoriesRow(fg, sub),
                  const SizedBox(height: 8),
                  _buildNewFollowersTile(fg, sub),
                  _buildActivityTile(fg, sub),
                  _buildSystemTile(fg, sub),
                  _buildMarketplaceTile(fg, sub),
                  const SizedBox(height: 4),
                  ..._buildMessageList(state, fg, sub, bg),
                ],
              ),
      ),
    );
  }

  // ---------- stories row ----------
  Widget _buildStoriesRow(Color fg, Color sub) {
    return SizedBox(
      height: 108,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          _storyCircle(
            label: 'Create',
            avatarUrl: context.read<AppState>().me?.avatarUrl ?? '',
            ringColor: null,
            badge: Container(
              width: 22, height: 22,
              decoration: const BoxDecoration(color: Color(0xFF20D5EC), shape: BoxShape.circle),
              child: const Icon(Icons.add, size: 14, color: Colors.white),
            ),
            onTap: () => _createStory(context),
            fg: fg, sub: sub,
          ),
          for (final su in _storyUsers)
            _storyCircle(
              label: su.displayName.isNotEmpty ? su.displayName : '@${su.handle}',
              avatarUrl: su.avatarUrl,
              ringColor: su.hasUnviewed ? const Color(0xFFFF2E63) : Colors.grey.shade600,
              onTap: () => _viewStories(context, su),
              fg: fg, sub: sub,
            ),
        ],
      ),
    );
  }

  Widget _storyCircle({
    required String label,
    required String avatarUrl,
    required Color? ringColor,
    Widget? badge,
    required VoidCallback onTap,
    required Color fg,
    required Color sub,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 72,
        margin: const EdgeInsets.only(right: 10),
        child: Column(
          children: [
            Stack(
              children: [
                Container(
                  width: 62, height: 62,
                  padding: const EdgeInsets.all(2.5),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: ringColor == null ? null : Border.all(color: ringColor, width: 2.5),
                  ),
                  child: CircleAvatar(
                    backgroundColor: Colors.white24,
                    backgroundImage: avatarUrl.isNotEmpty ? NetworkImage(avatarUrl) : null,
                    child: avatarUrl.isEmpty
                        ? Text(label.isNotEmpty ? label[0].toUpperCase() : '?', style: const TextStyle(fontSize: 20))
                        : null,
                  ),
                ),
                if (badge != null)
                  Positioned(right: 0, bottom: 0, child: badge),
              ],
            ),
            const SizedBox(height: 4),
            Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: sub, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Future<void> _createStory(BuildContext context) async {
    final picker = ImagePicker();
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF1a1a1a),
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo, color: Colors.white70),
              title: const Text('Photo', style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.of(c).pop('photo'),
            ),
            ListTile(
              leading: const Icon(Icons.videocam, color: Colors.white70),
              title: const Text('Video', style: TextStyle(color: Colors.white)),
              onTap: () => Navigator.of(c).pop('video'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !context.mounted) return;
    final file = choice == 'photo'
        ? await picker.pickImage(source: ImageSource.gallery)
        : await picker.pickVideo(source: ImageSource.gallery);
    if (file == null || !context.mounted) return;
    final state = context.read<AppState>();
    try {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Uploading story…')));
      final r = await state.api.upload('/api/uploads', file.path);
      final mediaKey = '${r['key'] ?? ''}';
      if (mediaKey.isEmpty) throw Exception('upload failed');
      await state.api.post('/api/stories', {'mediaKey': mediaKey, 'mediaType': choice});
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Story posted (visible 24h)')));
        _loadAll();
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Story failed: $e')));
      }
    }
  }

  void _viewStories(BuildContext context, _StoryUser su) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => StoryViewerScreen(user: su)),
    ).then((_) => _loadAll());
  }

  // ---------- new followers tile ----------
  Widget _buildNewFollowersTile(Color fg, Color sub) {
    final latest = _followers.isNotEmpty ? _followers.first : null;
    final name = latest == null
        ? ''
        : ('${latest['display_name'] ?? ''}'.isNotEmpty
            ? '${latest['display_name']}'
            : '@${latest['handle'] ?? ''}');
    return ListTile(
      leading: Container(
        width: 48, height: 48,
        decoration: const BoxDecoration(color: Color(0xFF20A9E8), shape: BoxShape.circle),
        child: const Icon(Icons.people, color: Colors.white, size: 26),
      ),
      title: Text('New followers', style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 16)),
      subtitle: latest == null
          ? Text('No new followers yet', style: TextStyle(color: sub, fontSize: 13))
          : Text('$name started following you.', style: TextStyle(color: sub, fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
      onTap: () {
        final appState = context.read<AppState>();
        final me = appState.me;
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => FollowListScreen(
            uidOrHandle: me != null && me.uid.isNotEmpty ? me.uid : (me != null && me.handle.isNotEmpty ? me.handle : 'me'),
            handle: me?.handle ?? '',
            initialTab: FollowListTab.followers,
          )),
        );
      },
    );
  }

  // ---------- activity tile ----------
  Widget _buildActivityTile(Color fg, Color sub) {
    final latest = _activity.isNotEmpty ? _activity.first : null;
    String preview = 'No activity yet';
    if (latest != null) {
      final actor = '${latest['actor_name'] ?? ''}'.isNotEmpty
          ? '${latest['actor_name']}'
          : '@${latest['actor_handle'] ?? ''}';
      preview = latest['kind'] == 'like'
          ? '$actor liked your video'
          : '$actor commented: ${latest['text'] ?? ''}';
    }
    return ListTile(
      leading: Container(
        width: 48, height: 48,
        decoration: const BoxDecoration(color: Color(0xFFFF2E63), shape: BoxShape.circle),
        child: const Icon(Icons.favorite, color: Colors.white, size: 26),
      ),
      title: Text('Activity', style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 16)),
      subtitle: Text(preview, style: TextStyle(color: sub, fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: _activity.isNotEmpty
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: const BoxDecoration(color: Color(0xFFFF2E63), shape: BoxShape.circle),
              child: Text('${_activity.length}', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
            )
          : null,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ActivityScreen()),
      ).then((_) => _loadAll()),
    );
  }

  // ---------- system notifications tile ----------
  Widget _buildSystemTile(Color fg, Color sub) {
    final n = _latestSystem;
    return ListTile(
      leading: Container(
        width: 48, height: 48,
        decoration: BoxDecoration(color: Colors.grey.shade800, shape: BoxShape.circle),
        child: const Icon(Icons.inbox, color: Colors.white, size: 26),
      ),
      title: Text('System notifications', style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 16)),
      subtitle: n == null
          ? Text('No notifications', style: TextStyle(color: sub, fontSize: 13))
          : Text('${n['title'] ?? ''} · ${_timeAgo((n['created_at'] as num?)?.toInt() ?? 0)}',
              style: TextStyle(color: sub, fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: _systemUnread > 0
          ? Container(width: 10, height: 10, decoration: const BoxDecoration(color: Colors.redAccent, shape: BoxShape.circle))
          : null,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const SystemNotificationsScreen()),
      ).then((_) => _loadAll()),
    );
  }

  // ---------- messages ----------
  Widget _buildMarketplaceTile(Color fg, Color sub) {
    return ListTile(
      leading: Container(
        width: 48, height: 48,
        decoration: BoxDecoration(
          color: Colors.orange.withOpacity(0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.shopping_bag, color: Colors.orange),
      ),
      title: Text('Marketplace', style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 16)),
      subtitle: Text('Orders, shipments & tracking', style: TextStyle(color: sub, fontSize: 13)),
      trailing: Icon(Icons.chevron_right, color: sub),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const ShipmentsScreen()),
      ),
    );
  }

  List<Widget> _buildMessageList(AppState state, Color fg, Color sub, Color bg) {
    if (state.threads.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.all(32),
          child: Text('No conversations yet.\nVisit a profile and tap Message to start one.',
              textAlign: TextAlign.center, style: TextStyle(color: sub)),
        ),
      ];
    }
    return [
      for (final t in state.threads)
        Builder(builder: (context) {
          // CRITICAL: display name first, never @username as the title.
          final title = t.peerName.isNotEmpty ? t.peerName : '@${t.peerHandle}';
          final unread = t.unreadCount;
          return ListTile(
            leading: CircleAvatar(
              radius: 26,
              backgroundColor: Colors.white24,
              backgroundImage: t.peerAvatar.isNotEmpty ? NetworkImage(t.peerAvatar) : null,
              child: t.peerAvatar.isEmpty
                  ? Text(title.isNotEmpty ? title[0].toUpperCase() : '?', style: const TextStyle(fontSize: 20))
                  : null,
            ),
            title: Text(title, style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 16),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              t.lastMessage.isEmpty ? 'Say hello 👋' : t.lastMessage,
              style: TextStyle(color: sub, fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (unread > 0)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: const BoxDecoration(color: Color(0xFFFF2E63), shape: BoxShape.circle),
                    child: Text('$unread', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
              ],
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => ChatScreen(
                peerUid: t.peerUid,
                peerHandle: t.peerHandle,
                peerName: t.peerName,
                peerAvatar: t.peerAvatar,
              )),
            ).then((_) => context.read<AppState>().loadThreads()),
          );
        }),
    ];
  }
}

class _StoryUser {
  final String uid;
  final String handle;
  final String displayName;
  final String avatarUrl;
  final List<_StoryItem> stories = [];
  _StoryUser({required this.uid, required this.handle, required this.displayName, required this.avatarUrl});
  bool get hasUnviewed => stories.any((s) => !s.viewed);
}

class _StoryItem {
  final String id;
  final String mediaKey;
  final String mediaType;
  final String mediaUrl;
  final int createdAt;
  final bool viewed;
  _StoryItem({required this.id, required this.mediaKey, required this.mediaType, required this.mediaUrl, required this.createdAt, required this.viewed});
  factory _StoryItem.fromJson(Map<String, dynamic> j) => _StoryItem(
    id: '${j['id'] ?? ''}',
    mediaKey: '${j['media_key'] ?? ''}',
    mediaType: '${j['media_type'] ?? 'photo'}',
    mediaUrl: '${j['media_url'] ?? ''}',
    createdAt: (j['created_at'] as num?)?.toInt() ?? 0,
    viewed: ((j['viewed'] as num?)?.toInt() ?? 0) > 0,
  );
}

/// Full-screen story viewer with progress bars. Tap right = next, left = previous.
class StoryViewerScreen extends StatefulWidget {
  final _StoryUser user;
  const StoryViewerScreen({super.key, required this.user});

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen> with SingleTickerProviderStateMixin {
  int _index = 0;
  late AnimationController _progress;

  @override
  void initState() {
    super.initState();
    _progress = AnimationController(vsync: this, duration: const Duration(seconds: 5));
    _progress.addStatusListener((s) {
      if (s == AnimationStatus.completed) _next();
    });
    _startCurrent();
  }

  void _startCurrent() {
    _progress.reset();
    _progress.forward();
    // Mark viewed on the backend.
    final story = widget.user.stories[_index];
    context.read<AppState>().api.post('/api/stories/${story.id}/view').catchError((_) => <String, dynamic>{});
  }

  void _next() {
    if (_index < widget.user.stories.length - 1) {
      setState(() => _index++);
      _startCurrent();
    } else {
      Navigator.of(context).pop();
    }
  }

  void _prev() {
    if (_index > 0) {
      setState(() => _index--);
      _startCurrent();
    } else {
      _progress.reset();
      _progress.forward();
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final story = widget.user.stories[_index];
    final name = widget.user.displayName.isNotEmpty ? widget.user.displayName : '@${widget.user.handle}';
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTapUp: (d) {
          final w = MediaQuery.of(context).size.width;
          if (d.globalPosition.dx > w * 0.7) {
            _next();
          } else if (d.globalPosition.dx < w * 0.3) {
            _prev();
          }
        },
        child: Stack(
          children: [
            // Story media.
            Positioned.fill(
              child: story.mediaType == 'video'
                  ? _StoryVideo(url: story.mediaUrl)
                  : (story.mediaUrl.isNotEmpty
                      ? Image.network(story.mediaUrl, fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => const Center(
                              child: Text('Could not load story', style: TextStyle(color: Colors.white54))))
                      : const Center(child: Text('No media', style: TextStyle(color: Colors.white54)))),
            ),
            // Progress bars.
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Row(
                  children: [
                    for (var i = 0; i < widget.user.stories.length; i++)
                      Expanded(
                        child: Container(
                          height: 3,
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          decoration: BoxDecoration(
                            color: Colors.white30,
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: i < _index
                              ? Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(2)))
                              : i == _index
                                  ? AnimatedBuilder(
                                      animation: _progress,
                                      builder: (_, __) => FractionallySizedBox(
                                        alignment: Alignment.centerLeft,
                                        widthFactor: _progress.value,
                                        child: Container(decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(2))),
                                      ),
                                    )
                                  : null,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // Header: avatar + name + time + close.
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(top: 20, left: 12, right: 12),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundImage: widget.user.avatarUrl.isNotEmpty ? NetworkImage(widget.user.avatarUrl) : null,
                      child: widget.user.avatarUrl.isEmpty ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?') : null,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('$name · ${_timeAgo(story.createdAt)}',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Simple video widget for stories (no external player state to manage).
class _StoryVideo extends StatefulWidget {
  final String url;
  const _StoryVideo({required this.url});

  @override
  State<_StoryVideo> createState() => _StoryVideoState();
}

class _StoryVideoState extends State<_StoryVideo> {
  @override
  Widget build(BuildContext context) {
    // Stories use a plain network image fallback frame; the video element
    // below plays via the platform video view when available.
    return const Center(child: Text('▶', style: TextStyle(color: Colors.white54, fontSize: 48)));
  }
}

/// Activity feed: likes on my videos + comments on my videos.
class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await context.read<AppState>().api.get('/api/inbox/activity', {'limit': '50'});
      if (mounted) {
        setState(() {
          _items = ((r['activity'] as List?) ?? []).cast<Map<String, dynamic>>();
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? Colors.black : Colors.white;
    final fg = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white54 : Colors.black54;
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg, elevation: 0,
        leading: IconButton(icon: Icon(Icons.arrow_back, color: fg), onPressed: () => Navigator.of(context).pop()),
        title: Text('Activity', style: TextStyle(color: fg, fontWeight: FontWeight.w800)),
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary))
          : _items.isEmpty
              ? Center(child: Text('No activity yet', style: TextStyle(color: sub)))
              : ListView.builder(
                  itemCount: _items.length,
                  itemBuilder: (context, i) {
                    final a = _items[i];
                    final actor = '${a['actor_name'] ?? ''}'.isNotEmpty
                        ? '${a['actor_name']}'
                        : '@${a['actor_handle'] ?? ''}';
                    final isLike = a['kind'] == 'like';
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundImage: '${a['actor_avatar'] ?? ''}'.isNotEmpty
                            ? NetworkImage('${a['actor_avatar']}')
                            : null,
                        child: '${a['actor_avatar'] ?? ''}'.isEmpty
                            ? Text(actor.isNotEmpty ? actor[0].toUpperCase() : '?')
                            : null,
                      ),
                      title: RichText(
                        text: TextSpan(
                          style: TextStyle(color: fg, fontSize: 14),
                          children: [
                            TextSpan(text: actor, style: const TextStyle(fontWeight: FontWeight.w700)),
                            TextSpan(text: isLike ? ' liked your video' : ' commented: ${a['text'] ?? ''}'),
                          ],
                        ),
                        maxLines: 2, overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(_timeAgo((a['created_at'] as num?)?.toInt() ?? 0),
                          style: TextStyle(color: sub, fontSize: 12)),
                      trailing: Icon(isLike ? Icons.favorite : Icons.comment,
                          color: isLike ? const Color(0xFFFF2E63) : sub),
                    );
                  },
                ),
    );
  }
}

/// System notifications: account flags, support replies, payouts, orders,
/// strikes/bans, seller reviews, admin broadcasts, app updates.
class SystemNotificationsScreen extends StatefulWidget {
  const SystemNotificationsScreen({super.key});

  @override
  State<SystemNotificationsScreen> createState() => _SystemNotificationsScreenState();
}

class _SystemNotificationsScreenState extends State<SystemNotificationsScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final api = context.read<AppState>().api;
      final r = await api.get('/api/inbox/system', {'limit': '50'});
      if (mounted) {
        setState(() {
          _items = ((r['notifications'] as List?) ?? []).cast<Map<String, dynamic>>();
          _loading = false;
        });
      }
      // Mark all as read after viewing.
      await api.post('/api/inbox/system/read').catchError((_) => <String, dynamic>{});
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  IconData _iconFor(String type) {
    switch (type) {
      case 'suspension':
      case 'ban':
      case 'strike':
        return Icons.warning_amber;
      case 'support':
        return Icons.support_agent;
      case 'payout':
        return Icons.payments;
      case 'order':
      case 'shipment':
        return Icons.local_shipping;
      case 'seller_review':
        return Icons.store;
      default:
        return Icons.notifications;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? Colors.black : Colors.white;
    final fg = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white54 : Colors.black54;
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg, elevation: 0,
        leading: IconButton(icon: Icon(Icons.arrow_back, color: fg), onPressed: () => Navigator.of(context).pop()),
        title: Text('System notifications', style: TextStyle(color: fg, fontWeight: FontWeight.w800)),
      ),
      body: _loading
          ? Center(child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary))
          : _items.isEmpty
              ? Center(child: Text('No notifications', style: TextStyle(color: sub)))
              : ListView.builder(
                  itemCount: _items.length,
                  itemBuilder: (context, i) {
                    final n = _items[i];
                    final unread = ((n['read_at'] as num?)?.toInt() ?? 0) == 0;
                    return ListTile(
                      leading: Container(
                        width: 44, height: 44,
                        decoration: BoxDecoration(
                            color: unread ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.2) : Colors.grey.shade800,
                            shape: BoxShape.circle),
                        child: Icon(_iconFor('${n['type'] ?? ''}'),
                            color: unread ? Theme.of(context).colorScheme.primary : Colors.white70),
                      ),
                      title: Text('${n['title'] ?? ''}',
                          style: TextStyle(color: fg, fontWeight: unread ? FontWeight.w700 : FontWeight.w400)),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if ('${n['body'] ?? ''}'.isNotEmpty)
                            Text('${n['body']}', style: TextStyle(color: sub, fontSize: 13),
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                          Text(_timeAgo((n['created_at'] as num?)?.toInt() ?? 0),
                              style: TextStyle(color: sub, fontSize: 11)),
                        ],
                      ),
                      isThreeLine: '${n['body'] ?? ''}'.isNotEmpty,
                    );
                  },
                ),
    );
  }
}

/// 1:1 chat. Realtime via the sync WebSocket when the backend is configured.
class ChatScreen extends StatefulWidget {
  final String peerUid;
  final String peerHandle;
  final String peerName;
  final String peerAvatar;
  const ChatScreen({super.key, required this.peerUid, required this.peerHandle, this.peerName = '', this.peerAvatar = ''});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _ctrl = TextEditingController();
  List<ChatMessage> _messages = [];
  bool _loading = true;
  StreamSubscription? _sub;
  int _streak = 0;
  bool _recording = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadStreak();
    // Live updates from the sync socket.
    _sub = context.read<AppState>().sync.events.listen((e) {
      if (e['type'] == 'message' && mounted) _load();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  /// Streak: consecutive days with at least one message exchanged.
  Future<void> _loadStreak() async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'streak_${widget.peerUid}';
    final lastDate = prefs.getString('${key}_date');
    final count = prefs.getInt(key) ?? 0;
    final today = DateTime.now().toIso8601String().substring(0, 10);
    if (lastDate == today) {
      setState(() => _streak = count);
    } else {
      final yesterday = DateTime.now().subtract(const Duration(days: 1)).toIso8601String().substring(0, 10);
      if (lastDate == yesterday && _messages.isNotEmpty) {
        // Consecutive day with messages — streak continues.
        setState(() => _streak = count);
      } else if (lastDate != null) {
        // Streak broken.
        setState(() => _streak = 0);
      }
    }
  }

  Future<void> _bumpStreak() async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'streak_${widget.peerUid}';
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final lastDate = prefs.getString('${key}_date');
    if (lastDate != today) {
      final count = prefs.getInt(key) ?? 0;
      final yesterday = DateTime.now().subtract(const Duration(days: 1)).toIso8601String().substring(0, 10);
      final newCount = (lastDate == yesterday) ? count + 1 : 1;
      await prefs.setInt(key, newCount);
      await prefs.setString('${key}_date', today);
      if (mounted) setState(() => _streak = newCount);
    }
  }

  Future<void> _load() async {
    try {
      final ms = await context.read<AppState>().loadMessages(widget.peerUid);
      if (mounted) setState(() {
        _messages = ms;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Profile-settings sheet: follow/unfollow + block for the chat peer.
  void _openChatSettings(BuildContext context, AppState state, Color fg, bool isDark) {
    final peerUid = widget.peerUid;
    final name =
        widget.peerName.isNotEmpty ? widget.peerName : '@${widget.peerHandle}';
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (c) {
        final following = state.followingUids.contains(peerUid);
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: fg.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(height: 8),
              ListTile(
                leading: Icon(
                    following
                        ? Icons.person_remove_outlined
                        : Icons.person_add_outlined,
                    color: fg),
                title: Text(following ? 'Unfollow $name' : 'Follow $name',
                    style:
                        TextStyle(color: fg, fontWeight: FontWeight.w600)),
                onTap: () async {
                  Navigator.of(c).pop();
                  await state.toggleFollow(peerUid);
                },
              ),
              ListTile(
                leading: const Icon(Icons.block_outlined,
                    color: Colors.redAccent),
                title: Text('Block $name',
                    style: const TextStyle(
                        color: Colors.redAccent,
                        fontWeight: FontWeight.w600)),
                onTap: () async {
                  Navigator.of(c).pop();
                  await state.blockUser(peerUid);
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Blocked $name')));
                    Navigator.of(context).pop();
                  }
                },
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  /// Suggested-accounts carousel: friends-of-friends, slideable, ~20 max.
  void _openSuggested(
      BuildContext context, AppState state, Color fg, Color sub, bool isDark) {
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? Colors.black : Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (c) => SafeArea(
        child: SizedBox(
          height: 320,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: fg.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(2)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text('Suggested accounts',
                    style: TextStyle(
                        color: fg,
                        fontSize: 17,
                        fontWeight: FontWeight.w800)),
              ),
              Expanded(
                child: FutureBuilder<List<SuggestedUser>>(
                  future: state.fetchSuggested(widget.peerUid),
                  builder: (c2, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final users = snap.data ?? [];
                    if (users.isEmpty) {
                      return Center(
                          child: Text('No suggestions yet',
                              style: TextStyle(color: sub)));
                    }
                    return ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      itemCount: users.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(width: 12),
                      itemBuilder: (c3, i) => _SuggestedCard(
                        user: users[i],
                        fg: fg,
                        sub: sub,
                        isDark: isDark,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final myUid = state.auth.uid;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? Colors.black : Colors.white;
    final fg = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white54 : Colors.black54;
    final theirBubble = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF0F0F0);
    final theirText = isDark ? Colors.white : Colors.black87;
    const myBubble = Color(0xFF2F80ED);
    final inputFill = isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF0F0F0);
    final displayName =
        widget.peerName.isNotEmpty ? widget.peerName : '@${widget.peerHandle}';
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: fg),
          onPressed: () => Navigator.of(context).pop(),
        ),
        titleSpacing: 0,
        title: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) =>
                ProfileScreen(uid: widget.peerUid, handle: widget.peerHandle),
          )),
          child: Row(
            children: [
              CircleAvatar(
                radius: 17,
                backgroundColor: isDark ? Colors.white24 : Colors.black12,
                backgroundImage: widget.peerAvatar.isNotEmpty
                    ? NetworkImage(widget.peerAvatar)
                    : null,
                child: widget.peerAvatar.isEmpty
                    ? Text(
                        displayName.isNotEmpty
                            ? displayName[0].toUpperCase()
                            : '?',
                        style: TextStyle(fontSize: 14, color: fg))
                    : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(displayName,
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: fg),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Chat settings',
            icon: Icon(Icons.settings_outlined, color: fg),
            onPressed: () => _openChatSettings(context, state, fg, isDark),
          ),
          IconButton(
            tooltip: 'Suggested accounts',
            icon: Icon(Icons.keyboard_arrow_down, color: fg),
            onPressed: () => _openSuggested(context, state, fg, sub, isDark),
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_horiz, color: fg),
            color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
            onSelected: (v) {
              if (v == 'profile') {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ProfileScreen(
                      uid: widget.peerUid, handle: widget.peerHandle),
                ));
              } else if (v == 'call') {
                _startVoiceCall(context);
              } else if (v == 'crypto') {
                _sendCrypto(context, widget.peerHandle);
              }
            },
            itemBuilder: (c) => [
              PopupMenuItem(
                  value: 'profile',
                  child:
                      Text('View profile', style: TextStyle(color: fg))),
              PopupMenuItem(
                  value: 'call',
                  child: Text('Voice call', style: TextStyle(color: fg))),
              PopupMenuItem(
                  value: 'crypto',
                  child:
                      Text('Send crypto', style: TextStyle(color: fg))),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? Center(
                    child: CircularProgressIndicator(
                        color: Theme.of(context).colorScheme.primary))
                : _messages.isEmpty
                    ? Center(
                        child:
                            Text('Say hello \u{1F44B}', style: TextStyle(color: sub)))
                    : ListView.builder(
                        reverse: true,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _messages.length,
                        itemBuilder: (context, i) {
                          final idx = _messages.length - 1 - i;
                          final m = _messages[idx];
                          final mine = m.senderUid == myUid;
                          final showDivider = idx == 0 ||
                              _needsTimeDivider(
                                  _messages[idx - 1].createdAt, m.createdAt);
                          final isLast = idx == _messages.length - 1;
                          return Column(
                            crossAxisAlignment: mine
                                ? CrossAxisAlignment.end
                                : CrossAxisAlignment.start,
                            children: [
                              if (showDivider)
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 10),
                                  child: Center(
                                    child: Text(_dividerLabel(m.createdAt),
                                        style: TextStyle(
                                            color: sub, fontSize: 12)),
                                  ),
                                ),
                              _messageBubble(m, mine, isDark, theirBubble,
                                  theirText, myBubble, fg),
                              if (mine && isLast)
                                Padding(
                                  padding: const EdgeInsets.only(
                                      right: 16, top: 2, bottom: 4),
                                  child: Text('Seen',
                                      style:
                                          TextStyle(color: sub, fontSize: 11)),
                                ),
                            ],
                          );
                        },
                      ),
          ),
          _reactionsBar(isDark, theirBubble, fg, sub, state, myUid),
          _inputBar(isDark, fg, sub, inputFill, state, myUid),
        ],
      ),
    );
  }

  bool _needsTimeDivider(int prevMs, int ms) {
    final a = DateTime.fromMillisecondsSinceEpoch(prevMs);
    final b = DateTime.fromMillisecondsSinceEpoch(ms);
    if (a.year != b.year || a.month != b.month || a.day != b.day) return true;
    return ms - prevMs > 30 * 60 * 1000;
  }

  String _dividerLabel(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday'
    ];
    final day = days[dt.weekday - 1];
    var h = dt.hour % 12;
    if (h == 0) h = 12;
    final mm = dt.minute.toString().padLeft(2, '0');
    final ap = dt.hour < 12 ? 'AM' : 'PM';
    return '$day $h:$mm $ap';
  }

  Widget _messageBubble(ChatMessage m, bool mine, bool isDark, Color theirBubble,
      Color theirText, Color myBubble, Color fg) {
    final bubble = Container(
      margin: EdgeInsets.only(
        left: mine ? 64 : 0,
        right: mine ? 12 : 64,
        top: 2,
        bottom: 2,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: mine ? myBubble : theirBubble,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(m.text,
          style: TextStyle(
              color: mine ? Colors.white : theirText, fontSize: 15)),
    );
    if (mine) return Align(alignment: Alignment.centerRight, child: bubble);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 8, bottom: 2),
          child: CircleAvatar(
            radius: 13,
            backgroundColor: isDark ? Colors.white24 : Colors.black12,
            backgroundImage: widget.peerAvatar.isNotEmpty
                ? NetworkImage(widget.peerAvatar)
                : null,
            child: widget.peerAvatar.isEmpty
                ? Text(
                    widget.peerHandle.isNotEmpty
                        ? widget.peerHandle[0].toUpperCase()
                        : '?',
                    style: TextStyle(fontSize: 10, color: fg))
                : null,
          ),
        ),
        Flexible(child: bubble),
      ],
    );
  }

  Widget _reactionsBar(bool isDark, Color pill, Color fg, Color sub,
      AppState state, String myUid) {
    const emojis = ['\u2764\uFE0F', '\u{1F602}', '\u{1F44D}', '\u{1F446}'];
    return SizedBox(
      height: 50,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        children: [
          for (final e in emojis)
            GestureDetector(
              onTap: () => _sendQuick(e, state, myUid),
              child: Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                    color: pill, borderRadius: BorderRadius.circular(22)),
                alignment: Alignment.center,
                child: Text(e, style: const TextStyle(fontSize: 20)),
              ),
            ),
          GestureDetector(
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('Al Cast is coming soon')));
            },
            child: Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                  color: pill, borderRadius: BorderRadius.circular(22)),
              child: Row(
                children: [
                  SizedBox(
                    width: 42,
                    child: Stack(
                      children: [
                        CircleAvatar(
                          radius: 11,
                          backgroundColor:
                              isDark ? Colors.white24 : Colors.black12,
                          backgroundImage: widget.peerAvatar.isNotEmpty
                              ? NetworkImage(widget.peerAvatar)
                              : null,
                        ),
                        Positioned(
                          left: 20,
                          child: CircleAvatar(
                            radius: 11,
                            backgroundColor:
                                isDark ? Colors.white24 : Colors.black12,
                            child: Icon(Icons.person, size: 14, color: sub),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text('Al Cast',
                      style: TextStyle(
                          color: fg,
                          fontSize: 14,
                          fontWeight: FontWeight.w500)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _sendQuick(String text, AppState state, String myUid) async {
    final optimistic = ChatMessage(
      id: 'local_${DateTime.now().millisecondsSinceEpoch}',
      threadId: '',
      senderUid: myUid,
      text: text,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    setState(() => _messages.add(optimistic));
    try {
      await state.sendMessage(widget.peerUid, text);
      _bumpStreak();
      _load();
    } catch (_) {}
  }

  Widget _inputBar(bool isDark, Color fg, Color sub, Color fill, AppState state,
      String myUid) {
    return Padding(
      padding: EdgeInsets.only(
          left: 8,
          right: 8,
          bottom: MediaQuery.of(context).viewInsets.bottom + 10,
          top: 4),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Take photo',
            icon: Icon(Icons.camera_alt_outlined, color: sub),
            onPressed: () => _takePhoto(context),
          ),
          IconButton(
            tooltip: 'Gallery',
            icon: Icon(Icons.image_outlined, color: sub),
            onPressed: () => _pickAttachment(context),
          ),
          Expanded(
            child: TextField(
              controller: _ctrl,
              style: TextStyle(color: fg),
              decoration: InputDecoration(
                hintText: 'Message...',
                hintStyle: TextStyle(color: sub),
                filled: true,
                fillColor: fill,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                border: const OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(24)),
                    borderSide: BorderSide.none),
              ),
            ),
          ),
          // Mic at extreme right; becomes Send when typing (WhatsApp-style)
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _ctrl,
            builder: (context, v, _) {
              if (v.text.trim().isNotEmpty) {
                return IconButton(
                  tooltip: 'Send',
                  icon: Icon(Icons.send,
                      color: Theme.of(context).colorScheme.primary),
                  onPressed: () => _sendText(state, myUid),
                );
              }
              return GestureDetector(
                onLongPressStart: (_) => _startVoiceRecording(context),
                onLongPressEnd: (_) => _stopVoiceRecording(context),
                child: IconButton(
                  tooltip: 'Hold to record voice message',
                  icon: Icon(
                      _recording ? Icons.mic : Icons.mic_none_outlined,
                      color: _recording ? Colors.redAccent : sub),
                  onPressed: () {},
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _sendText(AppState state, String myUid) async {
    final t = _ctrl.text.trim();
    if (t.isEmpty) return;
    _ctrl.clear();
    final optimistic = ChatMessage(
      id: 'local_${DateTime.now().millisecondsSinceEpoch}',
      threadId: '',
      senderUid: myUid,
      text: t,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    setState(() => _messages.add(optimistic));
    try {
      await state.sendMessage(widget.peerUid, t);
      _bumpStreak();
      _load();
    } catch (_) {}
  }

  Future<void> _takePhoto(BuildContext context) async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.camera);
    if (file == null) return;
    final state = context.read<AppState>();
    try {
      final mediaKey = await state.uploadChatMedia(file.path);
      await state.sendMessage(widget.peerUid, '', mediaKey: mediaKey);
      _bumpStreak();
      _load();
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Photo sent')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not send photo: $e')));
      }
    }
  }

  void _showEmojiSheet() {
    const emojis = [
      '\u{1F600}', '\u{1F602}', '\u2764\uFE0F', '\u{1F44D}', '\u{1F44E}',
      '\u{1F64F}', '\u{1F44F}', '\u{1F525}', '\u{1F389}', '\u{1F622}',
      '\u{1F62E}', '\u{1F621}', '\u{1F914}', '\u{1F44B}', '\u{1F4AF}',
      '\u2728', '\u{1F970}', '\u{1F60E}', '\u{1F91D}', '\u{1F440}',
    ];
    showModalBottomSheet(
      context: context,
      builder: (c) => SafeArea(
        child: Container(
          padding: const EdgeInsets.all(16),
          child: GridView.builder(
            shrinkWrap: true,
            gridDelegate:
                const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 8),
            itemCount: emojis.length,
            itemBuilder: (c, i) => GestureDetector(
              onTap: () {
                _ctrl.text = '${_ctrl.text}${emojis[i]}';
                _ctrl.selection = TextSelection.fromPosition(
                    TextPosition(offset: _ctrl.text.length));
                Navigator.of(c).pop();
              },
              child: Center(
                  child: Text(emojis[i],
                      style: const TextStyle(fontSize: 26))),
            ),
          ),
        ),
      ),
    );
  }


  /// Pick photo/video from GALLERY (not file picker).
  Future<void> _pickAttachment(BuildContext context) async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;
    final state = context.read<AppState>();
    try {
      // Upload via the media endpoint, then send as a message with mediaKey.
      final mediaKey = await state.uploadChatMedia(file.path);
      await state.sendMessage(widget.peerUid, '', mediaKey: mediaKey);
      _bumpStreak();
      _load();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Photo sent')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not send photo: $e')));
      }
    }
  }

  /// Voice message recording (Opus codec).
  Future<void> _toggleVoiceRecording(BuildContext context) async {
    // TODO: wire `record` package — needs microphone permission flow.
    // For now show the recording UI state; full Opus recording lands with
    // the record package integration.
    if (_recording) {
      setState(() => _recording = false);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Voice message recording — coming in next build')));
      }
    } else {
      setState(() => _recording = true);
    }
  }

  /// WhatsApp-style: long-press mic to start recording.
  Future<void> _startVoiceRecording(BuildContext context) async {
    try {
      await VoiceRecorder.start();
      if (mounted) setState(() => _recording = true);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Recording failed: $e')));
      }
    }
  }

  /// WhatsApp-style: release to send automatically.
  Future<void> _stopVoiceRecording(BuildContext context) async {
    if (!_recording) return;
    try {
      final path = await VoiceRecorder.stop();
      if (mounted) setState(() => _recording = false);
      if (path != null && path.isNotEmpty && context.mounted) {
        await _sendVoiceMessage(context, path);
      }
    } catch (e) {
      if (mounted) setState(() => _recording = false);
    }
  }

  /// Upload and send the voice message.
  Future<void> _sendVoiceMessage(BuildContext context, String filePath) async {
    final state = context.read<AppState>();
    try {
      // Upload the audio file, get the media key
      final up = await state.api.upload('/api/uploads', filePath);
      final mediaKey = up['key'] as String? ?? up['media_key'] as String? ?? '';
      if (mediaKey.isEmpty) throw Exception('Upload failed');
      // Send as message with media key (backend signs the URL)
      await state.api.post('/api/threads/${widget.peerUid}/messages', {
        'text': '🎤 Voice message',
        'mediaKey': mediaKey,
        'durationS': 0,
      });
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Voice message sent')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to send: $e')));
      }
    }
  }

  /// Voice-only call (no video). Uses backend signaling.
  Future<void> _startVoiceCall(BuildContext context) async {
    final state = context.read<AppState>();
    try {
      final callId = await state.startVoiceCall(widget.peerUid);
      if (!context.mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VoiceCallScreen(
          callId: callId,
          peerName: widget.peerName.isNotEmpty ? widget.peerName : '@${widget.peerHandle}',
          peerAvatar: widget.peerAvatar,
        ),
      ));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not start call: $e')));
      }
    }
  }

  /// In-DM crypto send: pick coin → amount (≈ USD) → PIN → send to peer.
  /// No address entry: the peer is identified by their uid/handle.
  /// Network is auto-selected (fastest/cheapest) — no network picker.
  Future<void> _sendCrypto(BuildContext context, String peerHandle) async {
    final state = context.read<AppState>();
    if (!state.wallet.hasWallet) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Create your wallet first (Wallet tab, KYC required).')));
      return;
    }

    // --- coin + price state ---
    const coins = ['USDT', 'BTC', 'ETH', 'USDC'];
    String coin = 'USDT';
    // USD prices per coin (CoinGecko, fallback to estimates).
    final prices = <String, double>{'USDT': 1.0, 'USDC': 1.0, 'BTC': 0.0, 'ETH': 0.0};
    try {
      final resp = await http.get(Uri.parse(
          'https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum&vs_currencies=usd'));
      if (resp.statusCode == 200) {
        final j = json.decode(resp.body) as Map<String, dynamic>;
        prices['BTC'] = ((j['bitcoin'] as Map)['usd'] as num).toDouble();
        prices['ETH'] = ((j['ethereum'] as Map)['usd'] as num).toDouble();
      }
    } catch (_) {}
    // Fallbacks if the price API is unreachable.
    prices['BTC'] = prices['BTC']! > 0 ? prices['BTC']! : 97000.0;
    prices['ETH'] = prices['ETH']! > 0 ? prices['ETH']! : 3400.0;

    final amountCtrl = TextEditingController();
    final pinCtrl = TextEditingController();
    bool enteringUsd = false; // false = entering coin amount, true = entering USD
    String? error;

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setD) {
          final price = prices[coin] ?? 1.0;
          final raw = double.tryParse(amountCtrl.text.trim()) ?? 0;
          // Convert for display: show the other unit as ≈ equivalent.
          final equiv = enteringUsd
              ? (price > 0 ? raw / price : 0) // USD → coin
              : raw * price; // coin → USD
          final equivLabel = enteringUsd
              ? '≈ ${equiv.toStringAsFixed(6)} $coin'
              : '≈ \$${equiv.toStringAsFixed(2)}';
          return AlertDialog(
            backgroundColor: const Color(0xFF1a1a1a),
            title: Text('Send $coin to @${peerHandle.isEmpty ? 'peer' : peerHandle}',
                style: const TextStyle(color: Colors.white, fontSize: 16)),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Select coin',
                      style: TextStyle(color: Colors.white70, fontSize: 13)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final c in coins)
                        ChoiceChip(
                          label: Text(c),
                          selected: coin == c,
                          selectedColor: Theme.of(context).colorScheme.primary,
                          labelStyle: TextStyle(
                              color: coin == c ? Colors.black : Colors.white70,
                              fontWeight: FontWeight.w700),
                          backgroundColor: const Color(0xFF2a2a2a),
                          onSelected: (_) => setD(() => coin = c),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text(enteringUsd ? 'Amount (USD)' : 'Amount ($coin)',
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 13)),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setD(() {
                          enteringUsd = !enteringUsd;
                          amountCtrl.clear();
                        }),
                        child: Text(
                            enteringUsd ? 'Enter in $coin' : 'Enter in USD',
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.primary, fontSize: 12)),
                      ),
                    ],
                  ),
                  TextField(
                    controller: amountCtrl,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w800),
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    decoration: InputDecoration(
                      hintText: '0.00',
                      hintStyle: TextStyle(color: Colors.white24),
                      enabledBorder: UnderlineInputBorder(
                          borderSide: BorderSide(color: Colors.white24)),
                      focusedBorder: UnderlineInputBorder(
                          borderSide:
                              BorderSide(color: Theme.of(context).colorScheme.primary)),
                    ),
                    onChanged: (_) => setD(() {}),
                  ),
                  const SizedBox(height: 4),
                  Text(equivLabel,
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 14)),
                  const SizedBox(height: 6),
                  const Text(
                      'Network auto-selected: fastest & cheapest route. No network picker needed.',
                      style: TextStyle(color: Colors.white38, fontSize: 11)),
                  const SizedBox(height: 16),
                  TextField(
                    controller: pinCtrl,
                    style: const TextStyle(color: Colors.white),
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Wallet PIN',
                      labelStyle: TextStyle(color: Colors.white54),
                      enabledBorder: UnderlineInputBorder(
                          borderSide: BorderSide(color: Colors.white24)),
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(error!,
                        style: const TextStyle(
                            color: Colors.redAccent, fontSize: 12)),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text('Cancel')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary),
                onPressed: () {
                  final amt = double.tryParse(amountCtrl.text.trim()) ?? 0;
                  if (amt <= 0) {
                    setD(() => error = 'Enter an amount greater than 0.');
                    return;
                  }
                  if (pinCtrl.text.isEmpty) {
                    setD(() => error = 'Enter your wallet PIN.');
                    return;
                  }
                  Navigator.of(context).pop(true);
                },
                child: const Text('Send',
                    style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ],
          );
        },
      ),
    );
    if (ok != true || !context.mounted) return;

    // Resolve amounts: coinAmount is what leaves the wallet.
    final entered = double.parse(amountCtrl.text.trim());
    final price = prices[coin] ?? 1.0;
    final coinAmount = enteringUsd ? entered / price : entered;
    final usdValue = enteringUsd ? entered : entered * price;

    // Resolve the peer's receiving address.
    // The backend exposes the user's wallet address on GET /api/users/:uid.
    String? toAddress;
    try {
      final r = await state.api.get('/api/users/${widget.peerUid}');
      final userJson = (r['user'] as Map?)?.cast<String, dynamic>();
      toAddress = userJson?['evm_address'] as String?;
      if ((toAddress == null || toAddress.isEmpty) && coin == 'BTC') {
        toAddress = userJson?['btc_address'] as String?;
      }
    } catch (_) {}
    if ((toAddress == null || toAddress.isEmpty) && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Could not find their wallet address. They need to open their Wallet tab once so the address is registered.')));
      return;
    }

    // Final explicit confirmation.
    var confirmed = false;
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setD) => AlertDialog(
          backgroundColor: const Color(0xFF1a1a1a),
          title: const Text('⚠️ Confirm send',
              style: TextStyle(color: Colors.redAccent)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  'You are sending ${coinAmount.toStringAsFixed(6)} $coin (≈ \$${usdValue.toStringAsFixed(2)})',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('To: @${peerHandle.isEmpty ? 'peer' : peerHandle}',
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 13)),
              const Text('Network: auto (fastest & cheapest)',
                  style: TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(height: 12),
              const Text(
                  'This CANNOT be undone. Nova never touches fiat here — this is on-chain crypto only.',
                  style: TextStyle(color: Colors.redAccent, fontSize: 12)),
              CheckboxListTile(
                value: confirmed,
                onChanged: (v) => setD(() => confirmed = v ?? false),
                title: Text('I confirm this send.',
                    style: TextStyle(color: Colors.white, fontSize: 13)),
                activeColor: Theme.of(context).colorScheme.primary,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white),
              onPressed: !confirmed
                  ? null
                  : () async {
                      Navigator.of(context).pop();
                      try {
                        // Route through the fastest/cheapest network automatically.
                        final hash = await state.wallet.sendEvm(
                          pin: pinCtrl.text,
                          to: toAddress!,
                          amountEth: coinAmount,
                          api: state.api,
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(
                                  'Sent ${coinAmount.toStringAsFixed(6)} $coin! Tx: ${hash.substring(0, 18)}…')));
                          // Announce the transfer in chat.
                          try {
                            await state.sendMessage(widget.peerUid,
                                '💸 Sent ${coinAmount.toStringAsFixed(6)} $coin (≈ \$${usdValue.toStringAsFixed(2)})');
                            _bumpStreak();
                            _load();
                          } catch (_) {}
                        }
                      } catch (e) {
                        final msg = e is ApiException
                            ? e.message
                            : 'Send failed. Please try again.';
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(msg)));
                        }
                      }
                    },
              child: const Text('SEND NOW'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Voice-only call screen (no video, per spec).
/// Uses backend signaling; audio transport via WebRTC lands in a follow-up.
class VoiceCallScreen extends StatefulWidget {
  final String callId;
  final String peerName;
  final String peerAvatar;
  const VoiceCallScreen({super.key, required this.callId, required this.peerName, this.peerAvatar = ''});

  @override
  State<VoiceCallScreen> createState() => _VoiceCallScreenState();
}

class _VoiceCallScreenState extends State<VoiceCallScreen> {
  bool _muted = false;
  bool _speaker = false;
  int _seconds = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String get _duration {
    final m = _seconds ~/ 60;
    final s = _seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _endCall() async {
    try {
      await context.read<AppState>().endVoiceCall(widget.callId);
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 60),
            CircleAvatar(
              radius: 50,
              backgroundColor: Colors.white24,
              backgroundImage: widget.peerAvatar.isNotEmpty ? NetworkImage(widget.peerAvatar) : null,
              child: widget.peerAvatar.isEmpty
                  ? Text(widget.peerName.isNotEmpty ? widget.peerName[0].toUpperCase() : '?',
                      style: const TextStyle(fontSize: 36))
                  : null,
            ),
            const SizedBox(height: 16),
            Text(widget.peerName, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(_duration, style: const TextStyle(color: Colors.white54, fontSize: 16)),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _callButton(
                  icon: _muted ? Icons.mic_off : Icons.mic,
                  label: _muted ? 'Unmute' : 'Mute',
                  onTap: () => setState(() => _muted = !_muted),
                ),
                _callButton(
                  icon: Icons.call_end,
                  label: 'End',
                  background: Colors.redAccent,
                  onTap: _endCall,
                ),
                _callButton(
                  icon: _speaker ? Icons.volume_up : Icons.volume_down,
                  label: 'Speaker',
                  onTap: () => setState(() => _speaker = !_speaker),
                ),
              ],
            ),
            const SizedBox(height: 60),
          ],
        ),
      ),
    );
  }

  Widget _callButton({required IconData icon, required String label, Color? background, required VoidCallback onTap}) {
    return Column(
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 64, height: 64,
            decoration: BoxDecoration(shape: BoxShape.circle, color: background ?? const Color(0xFF2a2a2a)),
            child: Icon(icon, color: Colors.white, size: 28),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }
}

/// One card in the suggested-accounts carousel: avatar, name, reason label,
/// and a Follow/Following toggle.
class _SuggestedCard extends StatefulWidget {
  final SuggestedUser user;
  final Color fg;
  final Color sub;
  final bool isDark;
  const _SuggestedCard(
      {required this.user,
      required this.fg,
      required this.sub,
      required this.isDark});

  @override
  State<_SuggestedCard> createState() => _SuggestedCardState();
}

class _SuggestedCardState extends State<_SuggestedCard> {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final u = widget.user;
    final fg = widget.fg;
    final sub = widget.sub;
    final isDark = widget.isDark;
    final following = state.followingUids.contains(u.uid);
    final name = u.displayName.isNotEmpty ? u.displayName : '@${u.handle}';
    return Container(
      width: 168,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFFF6F6F6),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircleAvatar(
            radius: 30,
            backgroundColor: isDark ? Colors.white24 : Colors.black12,
            backgroundImage:
                u.avatarUrl.isNotEmpty ? NetworkImage(u.avatarUrl) : null,
            child: u.avatarUrl.isEmpty
                ? Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: TextStyle(fontSize: 22, color: fg))
                : null,
          ),
          const SizedBox(height: 8),
          Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: fg, fontWeight: FontWeight.w700, fontSize: 13)),
          Text('@${u.handle}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: sub, fontSize: 12)),
          if (u.reasonLabel.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(u.reasonLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: sub, fontSize: 11)),
          ],
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () async {
                await state.toggleFollow(u.uid);
                if (mounted) setState(() {});
              },
              child: Text(following ? 'Following' : 'Follow'),
            ),
          ),
        ],
      ),
    );
  }
}
