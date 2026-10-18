import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../state/app_state.dart';
import '../utils/format.dart';
import '../widgets/ai_badge.dart';
import '../widgets/gifts.dart';
import 'affiliates.dart';
import 'feed.dart';
import 'follow_list.dart';
import 'qr_code.dart';
import 'profile_views.dart';
import 'inbox.dart';
import 'edit_profile.dart';
import 'monetization.dart';
import 'profile_menu.dart';
import 'wallet.dart';

/// TikTok-style profile in Nova's dark+gold premium skin.
/// Supports both dark and light themes.
class ProfileScreen extends StatefulWidget {
  final bool self;
  final String? uid;
  final String? handle;
  const ProfileScreen({super.key, this.self = false, this.uid, this.handle});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen>
    with SingleTickerProviderStateMixin {
  NovaUser? _user;
  int _followers = 0;
  int _following = 0;
  int _likes = 0;
  bool _loading = true;
  bool _isFollowing = false;
  late TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppState>().registerRefreshHandler('profile', refresh);
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    try {
      context.read<AppState>().unregisterRefreshHandler('profile');
    } catch (_) {}
    super.dispose();
  }

  /// Public refresh entry: pull-to-refresh + bottom-nav re-tap.
  Future<void> refresh() async {
    await _load();
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    try {
      if (widget.self) {
        _user = state.me;
        _followers = state.myFollowerCount;
      } else {
        _user = await state.fetchUser(widget.uid ?? widget.handle ?? '');
        _isFollowing = state.followingUids.contains(_user?.uid);
        if (state.isDemo) {
          _followers = 1200;
          _following = 340;
          _likes = 8600;
        } else if (_user != null) {
          try {
            final r = await state.api.get('/api/users/${_user!.uid}');
            final counts = r['counts'] as Map?;
            _followers = (counts?['followers'] ?? 0) as int;
            _following = (counts?['following'] ?? 0) as int;
            _likes = (counts?['likes'] ?? 0) as int;
          } catch (_) {}
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? Colors.black : Colors.white;
    final fg = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white60 : Colors.black54;
    final faint = isDark ? Colors.white38 : Colors.black38;
    final gold = Theme.of(context).colorScheme.primary;

    if (_loading) {
      return Scaffold(
        backgroundColor: bg,
        body: Center(child: CircularProgressIndicator(color: gold)),
      );
    }
    final state = context.watch<AppState>();
    final u = _user ?? state.me;
    if (u == null) {
      return Scaffold(
        backgroundColor: bg,
        body: Center(child: Text('User not found', style: TextStyle(color: sub))),
      );
    }
    final myVideos = state.feed.where((v) => v.uid == u.uid).toList();
    final likedVideos = state.feed.where((v) => v.likedByMe).toList();

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        leading: widget.self
            ? IconButton(
                icon: Icon(Icons.person_add_outlined, color: fg),
                tooltip: 'Find friends',
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Find friends — coming soon')));
                },
              )
            : IconButton(
                icon: Icon(Icons.arrow_back, color: fg),
                onPressed: () => Navigator.of(context).pop(),
              ),
        centerTitle: true,
        title: null,
        actions: [
          if (widget.self) ...[
            IconButton(
              icon: CustomPaint(size: const Size(24, 24), painter: _FootprintPainter(color: fg)),
              tooltip: 'Profile views',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ProfileViewsScreen()),
                );
              },
            ),
            IconButton(
              icon: Icon(Icons.share_outlined, color: fg),
              tooltip: 'Share profile',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => QrCodeScreen(
                      handle: u.handle,
                      displayName: u.displayName,
                      avatarUrl: u.avatarUrl,
                    ),
                  ),
                );
                }
              },
            ),
            IconButton(
              icon: Icon(Icons.menu, color: fg),
              tooltip: 'Menu',
              onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ProfileMenuScreen())),
            ),
          ],
          if (!widget.self) ...[
            IconButton(
              icon: Icon(Icons.notifications_outlined, color: fg),
              tooltip: 'Notifications',
              onPressed: () {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Notifications — coming soon')));
              },
            ),
            IconButton(
              icon: Icon(Icons.share_outlined, color: fg),
              tooltip: 'Share profile',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(
                    text: 'https://user.novamail.store/${u.handle}'));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Profile link copied')));
                }
              },
            ),
          ],
        ],
      ),
      body: RefreshIndicator(
        color: Theme.of(context).colorScheme.primary,
        onRefresh: refresh,
        child: NestedScrollView(
        headerSliverBuilder: (context, _) => [
          SliverToBoxAdapter(
            child: Column(
              children: [
                const SizedBox(height: 8),
                // Centered avatar with follow badge.
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      padding: EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(
                          colors: [Theme.of(context).colorScheme.primary, Theme.of(context).colorScheme.primary],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: gold.withValues(alpha: 0.35),
                            blurRadius: 16,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                      child: CircleAvatar(
                        radius: 46,
                        backgroundColor: isDark ? Colors.white12 : Colors.black12,
                        backgroundImage: u.avatarUrl.isNotEmpty
                            ? NetworkImage(u.avatarUrl)
                            : null,
                        child: u.avatarUrl.isEmpty
                            ? Text(
                                u.handle.isNotEmpty
                                    ? u.handle[0].toUpperCase()
                                    : '?',
                                style: TextStyle(fontSize: 34, color: fg))
                            : null,
                      ),
                    ),
                    if (!widget.self && !_isFollowing)
                      Positioned(
                        bottom: 0,
                        child: GestureDetector(
                          onTap: () {
                            // Optimistic UI: update immediately, sync in background.
                            setState(() => _isFollowing = true);
                            state.toggleFollow(u.uid);
                          },
                          child: Container(
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            child: const Icon(Icons.add,
                                size: 18, color: Colors.black),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                // Name + handle.
                if (u.displayName.isNotEmpty)
                  Text(u.displayName,
                      style: TextStyle(
                          color: fg,
                          fontSize: 19,
                          fontWeight: FontWeight.w800)),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text('@${u.handle}',
                        style: TextStyle(color: fg, fontSize: 15)),
                    // Verification badge: blue = personal, pink = business
                    if (u.isVerified) ...[
                      const SizedBox(width: 4),
                      VerifiedBadge(size: 18, type: u.verificationType),
                    ],
                    // X-style affiliation: company logo square next to the badge.
                    if (u.affiliatedWith != null) ...[
                      const SizedBox(width: 4),
                      Tooltip(
                        message:
                            'Affiliated with @${u.affiliatedWith!.handle}',
                        child: AffiliateBadge(
                            avatarUrl: u.affiliatedWith!.avatarUrl, size: 18),
                      ),
                    ],
                    if (u.isOfficial) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                            color: gold,
                            borderRadius: BorderRadius.circular(4)),
                        child: const Text('OFFICIAL',
                            style: TextStyle(
                                color: Colors.black,
                                fontSize: 10,
                                fontWeight: FontWeight.bold)),
                      ),
                    ],
                    if (u.isBot) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                            color: isDark ? Colors.white12 : Colors.black12,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                                color: isDark
                                    ? Colors.white24
                                    : Colors.black12)),
                        child: Text('BOT',
                            style: TextStyle(
                                color: sub,
                                fontSize: 10,
                                fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 10),
                // Following / Followers / Likes — TikTok compact counts.
                // Following & Followers open the user list screen.
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _Stat(
                        n: formatCount(_following),
                        label: 'Following',
                        fg: fg,
                        sub: sub,
                        onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => FollowListScreen(
                                    uidOrHandle: u.uid.isNotEmpty
                                        ? u.uid
                                        : u.handle,
                                    handle: u.handle,
                                    initialTab:
                                        FollowListTab.following)))),
                    _Stat(
                        n: formatCount(_followers),
                        label: 'Followers',
                        fg: fg,
                        sub: sub,
                        onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => FollowListScreen(
                                    uidOrHandle: u.uid.isNotEmpty
                                        ? u.uid
                                        : u.handle,
                                    handle: u.handle,
                                    initialTab:
                                        FollowListTab.followers)))),
                    _Stat(
                        n: formatCount(_likes), label: 'Likes', fg: fg, sub: sub),
                  ],
                ),
                if (u.traderScore > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                        'Trader score: ${u.traderScore.toStringAsFixed(0)} ★',
                        style: TextStyle(
                            color: gold, fontWeight: FontWeight.w600, fontSize: 13)),
                  ),
                const SizedBox(height: 10),
                // Quick actions.
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: widget.self
                      ? Row(
                          children: [
                            Expanded(
                                child: _GoldButton(
                                    label: 'Edit profile',
                                    onTap: () => Navigator.of(context).push(
                                        MaterialPageRoute(
                                            builder: (_) =>
                                                const EditProfileScreen())))),
                            const SizedBox(width: 10),
                            Expanded(
                                child: _OutlineButton(
                                    label: 'Share profile',
                                    isDark: isDark,
                                    onTap: () {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(const SnackBar(
                                              content: Text(
                                                  'Profile link copied.')));
                                    })),
                          ],
                        )
                      : Row(
                          children: [
                            Expanded(
                                child: _isFollowing
                                    ? _OutlineButton(
                                        label: 'Following',
                                        isDark: isDark,
                                        onTap: () {
                                          // Optimistic UI: update immediately.
                                          setState(
                                              () => _isFollowing = false);
                                          state.toggleFollow(u.uid);
                                        })
                                    : _GoldButton(
                                        label: 'Follow',
                                        onTap: () {
                                          // Optimistic UI: update immediately.
                                          setState(
                                              () => _isFollowing = true);
                                          state.toggleFollow(u.uid);
                                        })),
                            const SizedBox(width: 10),
                            Expanded(
                                child: _OutlineButton(
                                    label: 'Message',
                                    isDark: isDark,
                                    onTap: () => Navigator.of(context).push(
                                        MaterialPageRoute(
                                            builder: (_) => ChatScreen(
                                                peerUid: u.uid,
                                                peerHandle: u.handle,
                                                peerName: u.displayName,
                                                peerAvatar: u.avatarUrl))))),
                          ],
                        ),
                ),
                if (widget.self) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      _ActionChip(
                          icon: Icons.account_balance_wallet_outlined,
                          label: 'Wallet',
                          isDark: isDark,
                          onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const WalletScreen()))),
                      _ActionChip(
                          icon: Icons.monetization_on_outlined,
                          label: 'Nova Coins',
                          isDark: isDark,
                          onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const CoinsScreen()))),
                    ],
                  ),
                ],
                // Bio below buttons (TikTok layout).
                if (u.bio.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 40, vertical: 8),
                    child: Text(u.bio,
                        style: TextStyle(color: sub, fontSize: 13),
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis),
                  ),
                // X-style affiliates: only gold-badge companies have affiliates.
                if (u.verificationType == 'company')
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 24, vertical: 4),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => AffiliatesScreen(
                            companyUid: u.uid,
                            companyHandle: u.handle,
                            canManage: widget.self,
                          ),
                        ),
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: isDark ? Colors.white10 : Colors.black12,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.business_outlined, size: 20),
                            const SizedBox(width: 10),
                            Text('Affiliates',
                                style: TextStyle(
                                    color: fg,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600)),
                            const Spacer(),
                            if (widget.self)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? Colors.white24
                                      : Colors.black26,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text('Manage',
                                    style: TextStyle(
                                        color: fg, fontSize: 12)),
                              ),
                            const SizedBox(width: 6),
                            Icon(Icons.chevron_right,
                                color: sub, size: 20),
                          ],
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ],
        body: Column(
          children: [
            TabBar(
              controller: _tabs,
              indicatorColor: gold,
              indicatorWeight: 2.5,
              labelColor: fg,
              unselectedLabelColor: faint,
              tabs: const [
                Tab(icon: Icon(Icons.grid_view, size: 22)),
                Tab(icon: Icon(Icons.favorite_border, size: 22)),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  _videoGrid(myVideos, isDark, sub,
                      empty: 'No videos yet'),
                  _videoGrid(likedVideos, isDark, sub,
                      empty: 'No liked videos yet'),
                ],
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }

  Widget _videoGrid(List<NovaVideo> videos, bool isDark, Color sub,
      {required String empty}) {
    if (videos.isEmpty) {
      return Center(child: Text(empty, style: TextStyle(color: sub)));
    }
    return GridView.builder(
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.75,
        crossAxisSpacing: 1,
        mainAxisSpacing: 1,
      ),
      itemCount: videos.length,
      itemBuilder: (context, i) {
        final v = videos[i];
        return GestureDetector(
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => _ProfileVideoViewer(videos: videos, initialIndex: i),
              ),
            );
          },
          child: Container(
          color: isDark ? const Color(0xFF161616) : Colors.black12,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (v.mediaUrl.isNotEmpty)
                Image.network(v.mediaUrl, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox())
              else
                const Icon(Icons.play_arrow,
                    color: Colors.white54, size: 36),
              // AI badge on grid thumbnails.
              if (v.isAiGenerated)
                const Positioned(top: 4, left: 4, child: AiBadge(compact: true)),
              Positioned(
                bottom: 4,
                left: 4,
                child: Row(
                  children: [
                    const Icon(Icons.play_arrow,
                        color: Colors.white, size: 14),
                    const SizedBox(width: 2),
                    Text(formatCount(v.viewCount),
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            shadows: [
                              Shadow(blurRadius: 4, color: Colors.black)
                            ])),
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
}

class _Stat extends StatelessWidget {
  final String n;
  final String label;
  final Color fg;
  final Color sub;
  final VoidCallback? onTap;
  const _Stat(
      {required this.n,
      required this.label,
      required this.fg,
      required this.sub,
      this.onTap});

  @override
  Widget build(BuildContext context) {
    final body = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          Text(n,
              style: TextStyle(
                  color: fg, fontWeight: FontWeight.w800, fontSize: 17)),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(color: sub, fontSize: 12)),
        ],
      ),
    );
    if (onTap == null) return body;
    return GestureDetector(onTap: onTap, behavior: HitTestBehavior.opaque, child: body);
  }
}

class _GoldButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _GoldButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: EdgeInsets.symmetric(vertical: 11),
        decoration: BoxDecoration(
          gradient: LinearGradient(
              colors: [Theme.of(context).colorScheme.primary, Theme.of(context).colorScheme.primary]),
          borderRadius: BorderRadius.circular(4),
          boxShadow: [
            BoxShadow(
                color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.35),
                blurRadius: 8,
                offset: const Offset(0, 2)),
          ],
        ),
        child: Text(label,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Theme.of(context).colorScheme.onPrimary,
                fontWeight: FontWeight.w800,
                fontSize: 14)),
      ),
    );
  }
}

class _OutlineButton extends StatelessWidget {
  final String label;
  final bool isDark;
  final VoidCallback onTap;
  const _OutlineButton(
      {required this.label, required this.isDark, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
              color: isDark ? Colors.white24 : Colors.black26, width: 1.2),
        ),
        child: Text(label,
            textAlign: TextAlign.center,
            style: TextStyle(
                color: isDark ? Colors.white : Colors.black87,
                fontWeight: FontWeight.w700,
                fontSize: 14)),
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isDark;
  final VoidCallback onTap;
  const _ActionChip(
      {required this.icon,
      required this.label,
      required this.isDark,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
            border: Border.all(
                color: isDark ? Colors.white24 : Colors.black26),
            borderRadius: BorderRadius.circular(20)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon,
                size: 16,
                color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    color: isDark ? Colors.white : Colors.black87,
                    fontSize: 13)),
          ],
        ),
      ),
    );
  }
}


/// Full-screen vertical video viewer for profile grid taps.
/// Shows the user's videos in a TikTok-style PageView starting at the tapped index.
class _ProfileVideoViewer extends StatefulWidget {
  final List<NovaVideo> videos;
  final int initialIndex;
  const _ProfileVideoViewer({required this.videos, required this.initialIndex});

  @override
  State<_ProfileVideoViewer> createState() => _ProfileVideoViewerState();
}

class _ProfileVideoViewerState extends State<_ProfileVideoViewer> {
  late PageController _pc;
  late ValueNotifier<int> _currentIndex;

  @override
  void initState() {
    super.initState();
    _pc = PageController(initialPage: widget.initialIndex);
    _currentIndex = ValueNotifier<int>(widget.initialIndex);
  }

  @override
  void dispose() {
    _pc.dispose();
    _currentIndex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            controller: _pc,
            scrollDirection: Axis.vertical,
            itemCount: widget.videos.length,
            onPageChanged: (i) => _currentIndex.value = i,
            itemBuilder: (context, i) {
              final v = widget.videos[i];
              return VideoCard(video: v, currentIndex: _currentIndex, index: i);
            },
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 8,
            child: IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }
}


/// Custom footprint icon painter (two footprints like TikTok's profile views icon).
class _FootprintPainter extends CustomPainter {
  final Color color;
  _FootprintPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final s = size.width / 24;
    // Left footprint
    _drawFoot(canvas, paint, s, 7, 12, -0.15);
    // Right footprint
    _drawFoot(canvas, paint, s, 16, 12, 0.15);
  }

  void _drawFoot(Canvas canvas, Paint paint, double s, double cx, double cy, double angle) {
    canvas.save();
    canvas.translate(cx * s, cy * s);
    canvas.rotate(angle);
    // Sole
    canvas.drawOval(Rect.fromCenter(center: Offset(0, 3 * s), width: 6 * s, height: 9 * s), paint);
    // Toes
    for (int i = 0; i < 4; i++) {
      final tx = (-2.2 + i * 1.5) * s;
      final ty = (-3.5 - (i == 1 || i == 2 ? 0.8 : 0)) * s;
      canvas.drawCircle(Offset(tx, ty), 1.1 * s, paint);
    }
    // Big toe
    canvas.drawCircle(Offset(2.8 * s, -3.2 * s), 1.4 * s, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
