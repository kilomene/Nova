import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../state/app_state.dart';
import '../utils/format.dart';
import '../widgets/gifts.dart';
import 'inbox.dart';
import 'profile.dart';

/// TikTok-style Following / Followers / Friends list.
///
/// Header: back button, username, add-friend (copies profile link).
/// Three tabs with live counts; Friends = mutual follows.
/// Rows: avatar (animated pink LIVE ring when streaming), display name +
/// @handle, "X new posts" badge, action button, "..." menu.
enum FollowListTab { following, followers, friends }

class FollowListScreen extends StatefulWidget {
  final String uidOrHandle;
  final String handle;
  final FollowListTab initialTab;
  const FollowListScreen({
    super.key,
    required this.uidOrHandle,
    required this.handle,
    this.initialTab = FollowListTab.followers,
  });

  @override
  State<FollowListScreen> createState() => _FollowListScreenState();
}

class _FollowListScreenState extends State<FollowListScreen>
    with SingleTickerProviderStateMixin {
  static const _pink = Color(0xFFFE2C55);

  late TabController _tab;
  final Map<FollowListTab, List<NovaUser>> _lists = {};
  final Map<FollowListTab, bool> _loading = {};
  int _followers = 0;
  int _following = 0;
  int _friends = 0;
  String _query = '';
  bool _isOwn = false;

  FollowListTab get _currentTab => FollowListTab.values[_tab.index];

  @override
  void initState() {
    super.initState();
    _tab = TabController(
        length: 3, vsync: this, initialIndex: widget.initialTab.index);
    _tab.addListener(_onTabChanged);
    final me = context.read<AppState>().me;
    _isOwn = me != null &&
        (widget.uidOrHandle == me.uid || widget.uidOrHandle == me.handle);
    _loadTab(_currentTab);
  }

  @override
  void dispose() {
    _tab.removeListener(_onTabChanged);
    _tab.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (_tab.indexIsChanging || !mounted) return;
    setState(() {});
    _loadTab(_currentTab);
  }

  Future<void> _loadTab(FollowListTab t, {bool force = false}) async {
    if (!force && (_lists.containsKey(t))) return;
    if (_loading[t] == true) return;
    setState(() => _loading[t] = true);
    final state = context.read<AppState>();
    final res = t == FollowListTab.followers
        ? await state.fetchFollowers(widget.uidOrHandle)
        : t == FollowListTab.following
            ? await state.fetchFollowing(widget.uidOrHandle)
            : await state.fetchFriends(widget.uidOrHandle);
    if (!mounted) return;
    setState(() {
      _lists[t] = res.users;
      _loading[t] = false;
      _followers = res.followers;
      _following = res.following;
      _friends = res.friends;
    });
  }

  Future<void> _refresh() => _loadTab(_currentTab, force: true);

  List<NovaUser> get _visible {
    final list = _lists[_currentTab] ?? const [];
    if (_query.isEmpty) return list;
    final q = _query.toLowerCase();
    return list
        .where((u) =>
            u.displayName.toLowerCase().contains(q) ||
            u.handle.toLowerCase().contains(q))
        .toList();
  }

  // ---------- follow / unfollow (optimistic, counts update instantly) ----------

  Future<bool> _confirmUnfollow(NovaUser u) async {
    final name =
        u.displayName.isNotEmpty ? u.displayName : '@${u.handle}';
    return await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: Text('Unfollow $name?'),
            content: Text(
                'You will no longer see their posts in your Following feed.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(c).pop(false),
                  child: const Text('Cancel')),
              TextButton(
                onPressed: () => Navigator.of(c).pop(true),
                child:
                    const Text('Unfollow', style: TextStyle(color: _pink)),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _toggleFollow(NovaUser u,
      {bool confirmUnfollow = false}) async {
    final state = context.read<AppState>();
    final wasFollowing = u.viewerFollows;
    if (wasFollowing && confirmUnfollow) {
      if (!await _confirmUnfollow(u)) return;
    }
    // Keep AppState.followingUids aligned so toggleFollow flips the right way.
    if (wasFollowing) {
      state.followingUids.add(u.uid);
    } else {
      state.followingUids.remove(u.uid);
    }
    setState(() {
      u.viewerFollows = !wasFollowing;
      if (_isOwn) {
        if (!wasFollowing) {
          _following++;
          // Became mutual -> appears in Friends.
          if (u.followsViewer) {
            final friends = _lists[FollowListTab.friends];
            if (friends != null &&
                !friends.any((x) => x.uid == u.uid)) {
              friends.insert(0, u);
              _friends++;
            }
          }
        } else {
          _following = (_following - 1).clamp(0, 1 << 30);
          final friends = _lists[FollowListTab.friends];
          if (friends != null &&
              friends.any((x) => x.uid == u.uid)) {
            friends.removeWhere((x) => x.uid == u.uid);
            _friends = (_friends - 1).clamp(0, 1 << 30);
          }
        }
      }
    });
    await state.toggleFollow(u.uid);
    if (mounted) setState(() {}); // re-resolve button labels
  }

  // ---------- navigation ----------

  void _openProfile(NovaUser u) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ProfileScreen(uid: u.uid, handle: u.handle)));
  }

  void _openChat(NovaUser u) {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ChatScreen(
              peerUid: u.uid,
              peerHandle: u.handle,
              peerName: u.displayName,
              peerAvatar: u.avatarUrl,
            )));
  }

  void _copyProfileLink(NovaUser u) {
    Clipboard.setData(
        ClipboardData(text: 'https://user.novamail.store/${u.handle}'));
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile link copied')));
  }

  void _copyOwnProfileLink() {
    Clipboard.setData(ClipboardData(
        text: 'https://user.novamail.store/${widget.handle}'));
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile link copied')));
  }

  void _showMenu(NovaUser u) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : Colors.black87;
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1a1a1a) : Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.person_outline, color: fg),
              title: Text('View profile', style: TextStyle(color: fg)),
              onTap: () {
                Navigator.of(c).pop();
                _openProfile(u);
              },
            ),
            ListTile(
              leading: Icon(Icons.message_outlined, color: fg),
              title: Text('Message', style: TextStyle(color: fg)),
              onTap: () {
                Navigator.of(c).pop();
                _openChat(u);
              },
            ),
            ListTile(
              leading: Icon(Icons.link_outlined, color: fg),
              title: Text('Copy profile link', style: TextStyle(color: fg)),
              onTap: () {
                Navigator.of(c).pop();
                _copyProfileLink(u);
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---------- buttons ----------

  Widget _pinkButton(String label, VoidCallback onTap) {
    return SizedBox(
      height: 36,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: _pink,
          foregroundColor: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
        onPressed: onTap,
        child: Text(label,
            style:
                const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
      ),
    );
  }

  Widget _grayButton(String label, bool isDark, VoidCallback onTap) {
    return SizedBox(
      height: 36,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor:
              isDark ? const Color(0xFF2E2E2E) : const Color(0xFFF1F1F2),
          foregroundColor: isDark ? Colors.white : Colors.black87,
          elevation: 0,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
        onPressed: onTap,
        child: Text(label,
            style:
                const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      ),
    );
  }

  /// Action button per tab + viewer relationship (TikTok rules).
  Widget _actionButton(NovaUser u, bool isDark) {
    if (_isOwn) {
      switch (_currentTab) {
        case FollowListTab.friends:
          return _grayButton('Message', isDark, () => _openChat(u));
        case FollowListTab.followers:
          // Everyone here follows me; mutual when I follow back.
          return u.viewerFollows
              ? _grayButton('Friends', isDark, () => _openChat(u))
              : _pinkButton('Follow back', () => _toggleFollow(u));
        case FollowListTab.following:
          return _grayButton('Following', isDark,
              () => _toggleFollow(u, confirmUnfollow: true));
      }
    }
    // Viewing someone else's list: buttons are relative to the viewer.
    return u.viewerFollows
        ? _grayButton('Following', isDark,
            () => _toggleFollow(u, confirmUnfollow: true))
        : _pinkButton('Follow', () => _toggleFollow(u));
  }

  // ---------- rows ----------

  String _newPostsLabel(int n) {
    if (n >= 10) return '10+ new posts';
    return n == 1 ? '1 new post' : '$n new posts';
  }

  Widget _avatar(NovaUser u, bool isDark) {
    if (u.isLive) return _LiveAvatar(user: u);
    return CircleAvatar(
      radius: 26,
      backgroundColor: isDark ? Colors.white12 : Colors.black12,
      backgroundImage: u.avatarUrl.isNotEmpty
          ? NetworkImage(u.avatarUrl)
          : null,
      child: u.avatarUrl.isEmpty
          ? Text(
              u.handle.isNotEmpty ? u.handle[0].toUpperCase() : '?',
              style: TextStyle(
                  color: isDark ? Colors.white : Colors.black87,
                  fontWeight: FontWeight.w700))
          : null,
    );
  }

  Widget _row(NovaUser u, bool isDark) {
    final fg = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white60 : Colors.black54;
    final name =
        u.displayName.isNotEmpty ? u.displayName : '@${u.handle}';
    return InkWell(
      onTap: () => _openProfile(u),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            _avatar(u, isDark),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(name,
                            style: TextStyle(
                                color: fg,
                                fontWeight: FontWeight.w700,
                                fontSize: 15),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      if (u.isVerified) ...[
                        const SizedBox(width: 4),
                        VerifiedBadge(
                            size: 14, type: u.verificationType),
                      ],
                    ],
                  ),
                  Text('@${u.handle}',
                      style: TextStyle(color: sub, fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  if (u.newPostCount > 0)
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF2E2E2E)
                            : const Color(0xFFF1F1F2),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(_newPostsLabel(u.newPostCount),
                          style: TextStyle(color: sub, fontSize: 12)),
                    ),
                ],
              ),
            ),
            _actionButton(u, isDark),
            IconButton(
              icon: Icon(Icons.more_horiz, color: sub),
              onPressed: () => _showMenu(u),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? Colors.black : Colors.white;
    final fg = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white60 : Colors.black54;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: fg),
          onPressed: () => Navigator.of(context).pop(),
        ),
        centerTitle: true,
        title: Text(widget.handle,
            style: TextStyle(color: fg, fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: Icon(Icons.person_add_outlined, color: fg),
            tooltip: 'Copy profile link',
            onPressed: _copyOwnProfileLink,
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          indicatorColor: fg,
          indicatorWeight: 2.5,
          labelColor: fg,
          unselectedLabelColor: sub,
          labelStyle:
              const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          unselectedLabelStyle:
              const TextStyle(fontWeight: FontWeight.w500, fontSize: 15),
          tabs: [
            Tab(text: 'Following ${formatCount(_following)}'),
            Tab(text: 'Followers ${formatCount(_followers)}'),
            Tab(text: 'Friends ${formatCount(_friends)}'),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: TextField(
              style: TextStyle(color: fg),
              decoration: InputDecoration(
                hintText: 'Search users',
                hintStyle: TextStyle(color: sub),
                prefixIcon: Icon(Icons.search, color: sub),
                filled: true,
                fillColor:
                    isDark ? const Color(0xFF1a1a1a) : const Color(0xFFF1F1F2),
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: _buildList(isDark, fg, sub),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(bool isDark, Color fg, Color sub) {
    if (_loading[_currentTab] == true && !_lists.containsKey(_currentTab)) {
      return const Center(child: CircularProgressIndicator());
    }
    final users = _visible;
    if (users.isEmpty) {
      final label = _currentTab == FollowListTab.followers
          ? 'followers'
          : _currentTab == FollowListTab.following
              ? 'following'
              : 'friends';
      return ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(48),
            child: Column(
              children: [
                Icon(Icons.group_outlined, size: 56, color: sub),
                const SizedBox(height: 12),
                Text(
                  _query.isNotEmpty
                      ? 'No users match "$_query".'
                      : '@${widget.handle} has no $label yet.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: sub, fontSize: 14),
                ),
              ],
            ),
          ),
        ],
      );
    }
    return ListView.separated(
      itemCount: users.length,
      separatorBuilder: (_, __) => Divider(
          height: 1,
          color: isDark ? const Color(0xFF1a1a1a) : Colors.black12),
      itemBuilder: (context, i) => _row(users[i], isDark),
    );
  }
}

/// Avatar with an animated pulsing pink ring + LIVE badge.
class _LiveAvatar extends StatefulWidget {
  final NovaUser user;
  const _LiveAvatar({required this.user});

  @override
  State<_LiveAvatar> createState() => _LiveAvatarState();
}

class _LiveAvatarState extends State<_LiveAvatar>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1600))
      ..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const pink = Color(0xFFFE2C55);
    const r = 26.0;
    return SizedBox(
      width: r * 2 + 14,
      height: r * 2 + 20,
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          AnimatedBuilder(
            animation: _c,
            builder: (_, __) {
              final t = _c.value;
              return Container(
                width: r * 2 + 8 + t * 6,
                height: r * 2 + 8 + t * 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: pink.withValues(
                          alpha: (1 - t * 0.75).clamp(0.0, 1.0)),
                      width: 2.5),
                ),
              );
            },
          ),
          Positioned(
            top: 4,
            child: CircleAvatar(
              radius: r,
              backgroundColor: Colors.white12,
              backgroundImage: widget.user.avatarUrl.isNotEmpty
                  ? NetworkImage(widget.user.avatarUrl)
                  : null,
              child: widget.user.avatarUrl.isEmpty
                  ? Text(
                      widget.user.handle.isNotEmpty
                          ? widget.user.handle[0].toUpperCase()
                          : '?',
                      style: const TextStyle(fontWeight: FontWeight.w700))
                  : null,
            ),
          ),
          Positioned(
            bottom: 0,
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                  color: pink, borderRadius: BorderRadius.circular(4)),
              child: const Text('LIVE',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w800)),
            ),
          ),
        ],
      ),
    );
  }
}
