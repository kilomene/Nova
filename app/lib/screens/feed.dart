import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:video_player/video_player.dart';

import '../models.dart';
import '../state/app_state.dart';
import '../utils/format.dart';
import '../widgets/ai_badge.dart';
import '../widgets/gifts.dart';
import '../widgets/nova_icons.dart';
import '../widgets/video_longpress_menu.dart';
import 'discover.dart';
import 'hashtag.dart';
import 'profile.dart';
import 'promote.dart';
import 'report.dart';
import 'shell.dart';

/// TikTok-style vertical feed: Following | For You tabs, full-screen
/// swipeable videos, right action rail, double-tap to like.
class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final ValueNotifier<int> _currentIndex = ValueNotifier(0);
  bool _following = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this, initialIndex: 3);
    _tabs.addListener(() {
      // Index 2 = Following, 3 = For You. Others are placeholders for now.
      final f = _tabs.index == 2;
      if (f != _following && _tabs.index >= 2) {
        setState(() {
          _following = f;
          _currentIndex.value = 0;
        });
        context.read<AppState>().loadFeed(following: f);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppState>().registerRefreshHandler('home', refresh);
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    _currentIndex.dispose();
    try {
      context.read<AppState>().unregisterRefreshHandler('home');
    } catch (_) {}
    super.dispose();
  }

  /// Public refresh entry: pull-to-refresh + bottom-nav re-tap.
  /// Reloads the currently active feed tab (FYP/Following/Local/Community).
  Future<void> refresh() async {
    final tabIndex = _tabs.index;
    final state = context.read<AppState>();
    if (tabIndex == 2) {
      await state.loadFeed(following: true);
    } else if (tabIndex == 3) {
      await state.loadFeed(following: false);
    } else {
      // Community (0) / Local (1): reload general feed for now.
      await state.loadFeed(following: false);
    }
    if (mounted) {
      _currentIndex.value = 0;
      setState(() {});
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
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: const LiveEntryButton(),
        leadingWidth: 72,
        centerTitle: true,
        title: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabAlignment: TabAlignment.center,
          indicatorColor: Theme.of(context).colorScheme.primary,
          indicatorWeight: 3,
          labelColor: fg,
          unselectedLabelColor: sub,
          labelStyle:
              const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          unselectedLabelStyle:
              const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          tabs: const [
            Tab(text: 'Community'),
            Tab(text: 'Local'),
            Tab(text: 'Following'),
            Tab(text: 'For You'),
          ],
        ),
        actions: [
          IconButton(
            icon: const NovaIcon.search(size: 24),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const DiscoverScreen())),
          ),
        ],
      ),
      body: Consumer<AppState>(
        builder: (context, state, _) {
          if (state.feedLoading && state.feed.isEmpty) {
            return Center(child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary));
          }
          if (state.feed.isEmpty) {
            return Center(
              child: Text('No videos yet — be the first to upload.', style: TextStyle(color: sub)),
            );
          }
          return RefreshIndicator(
            color: Theme.of(context).colorScheme.primary,
            onRefresh: refresh,
            child: PageView.builder(
              scrollDirection: Axis.vertical,
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: state.feed.length,
              onPageChanged: (i) {
                _currentIndex.value = i;
                state.recordView(state.feed[i]);
              },
              itemBuilder: (context, i) => VideoCard(video: state.feed[i], currentIndex: _currentIndex, index: i),
            ),
          );
        },
      ),
    );
  }
}

class VideoCard extends StatefulWidget {
  final NovaVideo video;
  final ValueNotifier<int> currentIndex;
  final int index;
  const VideoCard({super.key, required this.video, required this.currentIndex, required this.index});

  @override
  State<VideoCard> createState() => _VideoCardState();
}

class _VideoCardState extends State<VideoCard> with TickerProviderStateMixin {
  VideoPlayerController? _c;
  bool _showHeart = false;
  late AnimationController _heartController;
  late Animation<double> _heartScale;
  late Animation<double> _heartOpacity;
  bool _saved = false;
  String? _error;
  double _speed = 1.0;
  bool _clearDisplay = false;
  bool _autoScroll = false;

  @override
  void initState() {
    super.initState();
    _heartController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );
    _heartScale = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _heartController, curve: Curves.elasticOut),
    );
    _heartOpacity = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _heartController,
        curve: const Interval(0.5, 1.0, curve: Curves.easeOut),
      ),
    );
    _init();
    widget.currentIndex.addListener(_onIndex);
  }

  void _onIndex() {
    final active = widget.currentIndex.value == widget.index;
    if (_c == null || !_c!.value.isInitialized) return;
    if (active) {
      _c!.play();
    } else {
      _c!.pause();
    }
  }

  Future<void> _init() async {
    try {
      final url = widget.video.mediaUrl;
      _c = url.startsWith('http') ? VideoPlayerController.networkUrl(Uri.parse(url)) : VideoPlayerController.file(File(url));
      await _c!.initialize();
      _c!.setLooping(true);
      if (widget.currentIndex.value == widget.index && mounted) _c!.play();
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => _error = 'Video unavailable');
    }
  }

  @override
  void dispose() {
    _heartController.dispose();
    widget.currentIndex.removeListener(_onIndex);
    _c?.dispose();
    super.dispose();
  }

  void _doubleTapLike() {
    final state = context.read<AppState>();
    if (!widget.video.likedByMe) state.toggleLike(widget.video);
    setState(() => _showHeart = true);
    _heartController.forward(from: 0.0);
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _showHeart = false);
    });
  }

  void _openLongPressMenu() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => VideoLongPressMenu(
        video: widget.video,
        currentSpeed: _speed,
        onSpeedChanged: (s) {
          setState(() => _speed = s);
          _c?.setPlaybackSpeed(s);
        },
        onClearDisplay: () => setState(() => _clearDisplay = true),
        autoScroll: _autoScroll,
        onAutoScrollChanged: (b) => setState(() => _autoScroll = b),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final v = widget.video;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final phBg = isDark ? const Color(0xFF111111) : const Color(0xFFF0F0F0);
    final phFg = isDark ? Colors.white54 : Colors.black54;
    return GestureDetector(
      onDoubleTap: _doubleTapLike,
      onLongPress: _openLongPressMenu,
      onTap: () {
        if (_clearDisplay) {
          setState(() => _clearDisplay = false);
          return;
        }
        if (_c != null && _c!.value.isInitialized) {
          setState(() => _c!.value.isPlaying ? _c!.pause() : _c!.play());
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_c != null && _c!.value.isInitialized)
            FittedBox(fit: BoxFit.cover, child: SizedBox(width: _c!.value.size.width, height: _c!.value.size.height, child: VideoPlayer(_c!)))
          else
            Container(
              color: phBg,
              child: Center(
                child: _error != null
                    ? Text(_error!, style: TextStyle(color: phFg))
                    : CircularProgressIndicator(color: Theme.of(context).colorScheme.primary),
              ),
            ),
          if (_showHeart)
            Center(
              child: AnimatedBuilder(
                animation: _heartController,
                builder: (context, child) => Opacity(
                  opacity: _heartOpacity.value,
                  child: Transform.scale(
                    scale: _heartScale.value,
                    child: const Icon(Icons.favorite, size: 120, color: Colors.redAccent),
                  ),
                ),
              ),
            ),
          if (!_clearDisplay)
          // right action rail
          Positioned(
            right: 8,
            bottom: 90,
            child: Column(
              children: [
                GestureDetector(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => ProfileScreen(uid: v.uid, handle: v.handle)),
                  ),
                  child: CircleAvatar(
                    radius: 24,
                    backgroundColor: Colors.white24,
                    backgroundImage: v.avatarUrl.isNotEmpty ? NetworkImage(v.avatarUrl) : null,
                    child: v.avatarUrl.isEmpty ? Text(v.handle.isNotEmpty ? v.handle[0].toUpperCase() : '?') : null,
                  ),
                ),
                const SizedBox(height: 14),
                _RailButton(
                  iconWidget: NovaIcon.heart(
                      active: v.likedByMe,
                      size: 36,
                      color: v.likedByMe ? Colors.redAccent : Colors.white),
                  label: _fmt(v.likeCount),
                  onTap: () => state.toggleLike(v),
                ),
                _RailButton(
                  iconWidget: const NovaIcon.comment(size: 36),
                  label: _fmt(v.commentCount),
                  onTap: () => showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    backgroundColor: Colors.transparent,
                    builder: (_) => CommentsSheet(video: v),
                  ),
                ),
                _RailButton(
                  icon: _saved ? Icons.bookmark : Icons.bookmark_border,
                  color: _saved ? Theme.of(context).colorScheme.primary : Colors.white,
                  label: 'Save',
                  onTap: () => setState(() => _saved = !_saved),
                ),
                _RailButton(
                  iconWidget: NovaIcon.share(size: 30),
                  label: _fmt(v.shareCount),
                  onTap: () async {
                    await Clipboard.setData(ClipboardData(text: 'https://user.novamail.store/v/${v.id}'));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
                    }
                  },
                ),
                _RailButton(
                  icon: Icons.more_vert,
                  label: 'More',
                  onTap: () => showModalBottomSheet(
                    context: context,
                    backgroundColor: (Theme.of(context).brightness == Brightness.dark) ? Color(0xFF1a1a1a) : Colors.white,
                    builder: (_) => Builder(builder: (sheetCtx) {
                      final sheetDark = Theme.of(sheetCtx).brightness == Brightness.dark;
                      final sheetFg = sheetDark ? Colors.white : Colors.black87;
                      final sheetSub = sheetDark ? Colors.white54 : Colors.black54;
                      return SafeArea(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ListTile(
                            leading: const Icon(Icons.flag_outlined, color: Colors.redAccent),
                            title: Text('Report video', style: TextStyle(color: sheetFg)),
                            onTap: () {
                              Navigator.of(context).pop();
                              showReportDialog(context, targetType: 'video', targetId: v.id);
                            },
                          ),
                          if (v.uid == state.me?.uid)
                            ListTile(
                              leading: Icon(Icons.rocket_launch_outlined, color: Theme.of(context).colorScheme.primary),
                              title: Text('Promote video', style: TextStyle(color: sheetFg)),
                              subtitle: Text('Boost in For You · from \$7/day',
                                  style: TextStyle(color: sheetSub, fontSize: 12)),
                              onTap: () {
                                Navigator.of(context).pop();
                                Navigator.of(context).push(MaterialPageRoute(
                                    builder: (_) => PromoteScreen(videoId: v.id)));
                              },
                            ),
                        ],
                      ),
                    );
                    }),
                  ),
                ),
              ],
            ),
          ),
          // bottom caption block
          if (!_clearDisplay)
          Positioned(
            left: 12,
            right: 80,
            bottom: 24,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => ProfileScreen(uid: v.uid, handle: v.handle)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(v.displayName.isNotEmpty ? v.displayName : '@${v.handle}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                      if (v.isVerified) ...[
                        const SizedBox(width: 4),
                        VerifiedBadge(size: 16, type: v.verificationType),
                      ],
                      if (v.affiliatedWith != null) ...[
                        const SizedBox(width: 4),
                        AffiliateBadge(avatarUrl: v.affiliatedWith!.avatarUrl, size: 16),
                      ],
                      if (v.promoted) ...[
                        SizedBox(width: 8),
                        Container(
                          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: Theme.of(context).colorScheme.primary, width: 1),
                          ),
                          child: Text('Promoted',
                              style: TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 11, fontWeight: FontWeight.bold)),
                        ),
                      ],
                      if (v.isAiGenerated) ...[
                        const SizedBox(width: 8),
                        const AiBadge(compact: true),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                if (v.caption.isNotEmpty) HashtagText(v.caption, maxLines: 2),
                if (v.hashtags.isNotEmpty)
                  Wrap(
                    spacing: 6,
                    children: [for (final h in v.hashtags) HashtagChip(tag: h)],
                  ),
                if (v.soundLabel.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(Icons.music_note, size: 14, color: Colors.white70),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(v.soundLabel, style: const TextStyle(color: Colors.white70, fontSize: 12), overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(int n) => formatCount(n);
}

class _RailButton extends StatelessWidget {
  final IconData? icon;
  final Widget? iconWidget;
  final String label;
  final VoidCallback onTap;
  final Color color;
  const _RailButton(
      {this.icon,
      this.iconWidget,
      required this.label,
      required this.onTap,
      this.color = Colors.white});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            iconWidget ?? Icon(icon, color: color, size: 30),
            const SizedBox(height: 2),
            Text(label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

/// Comments bottom sheet.
class CommentsSheet extends StatefulWidget {
  final NovaVideo video;
  const CommentsSheet({super.key, required this.video});

  @override
  State<CommentsSheet> createState() => _CommentsSheetState();
}

class _CommentsSheetState extends State<CommentsSheet> {
  final _ctrl = TextEditingController();
  List<VideoComment> _comments = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _comments = await context.read<AppState>().fetchComments(widget.video.id);
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sheetBg = isDark ? const Color(0xFF161616) : Colors.white;
    final fg = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white70 : Colors.black54;
    final faint = isDark ? Colors.white38 : Colors.black38;
    final fieldFill = isDark ? const Color(0xFF242424) : const Color(0xFFF0F0F0);
    final avatarBg = isDark ? Colors.white24 : Colors.black12;
    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scroll) => Container(
        decoration: BoxDecoration(
          color: sheetBg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(width: 40, height: 4, decoration: BoxDecoration(color: avatarBg, borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: EdgeInsets.all(12),
              child: Text('${widget.video.commentCount} comments', style: TextStyle(color: fg, fontWeight: FontWeight.bold)),
            ),
            Expanded(
              child: _loading
                  ? Center(child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary))
                  : ListView.builder(
                      controller: scroll,
                      itemCount: _comments.length,
                      itemBuilder: (context, i) {
                        final c = _comments[i];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: avatarBg,
                            backgroundImage: c.avatarUrl.isNotEmpty ? NetworkImage(c.avatarUrl) : null,
                            child: c.avatarUrl.isEmpty ? Text(c.handle.isNotEmpty ? c.handle[0].toUpperCase() : '?') : null,
                          ),
                          title: Row(
                            children: [
                              Text(c.handle, style: TextStyle(color: fg, fontWeight: FontWeight.bold, fontSize: 13)),
                              if (c.isVerified) ...[const SizedBox(width: 4), VerifiedBadge(size: 13, type: c.verificationType)],
                              if (c.affiliatedWith != null) ...[const SizedBox(width: 4), AffiliateBadge(avatarUrl: c.affiliatedWith!.avatarUrl, size: 13)],
                            ],
                          ),
                          subtitle: Text(c.text, style: TextStyle(color: sub)),
                          trailing: IconButton(
                            icon: Icon(Icons.flag_outlined, size: 16, color: faint),
                            onPressed: () => showReportDialog(context, targetType: 'comment', targetId: c.id),
                          ),
                        );
                      },
                    ),
            ),
            Padding(
              padding: EdgeInsets.only(left: 12, right: 12, bottom: MediaQuery.of(context).viewInsets.bottom + 12, top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      style: TextStyle(color: fg),
                      decoration: InputDecoration(
                        hintText: 'Add a comment…',
                        hintStyle: TextStyle(color: faint),
                        filled: true,
                        fillColor: fieldFill,
                        border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(20)), borderSide: BorderSide.none),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.send, color: Theme.of(context).colorScheme.primary),
                    onPressed: () async {
                      final t = _ctrl.text.trim();
                      if (t.isEmpty) return;
                      _ctrl.clear();
                      await context.read<AppState>().addComment(widget.video, t);
                      _load();
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
