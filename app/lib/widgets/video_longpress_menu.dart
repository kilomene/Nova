import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../state/app_state.dart';
import '../screens/promote.dart';
import '../screens/report.dart';

/// Long-press bottom sheet for a feed video — TikTok-style menu in Nova
/// dark+gold skin. Items in the exact order the user specified.
class VideoLongPressMenu extends StatefulWidget {
  final NovaVideo video;
  final double currentSpeed;
  final ValueChanged<double> onSpeedChanged;
  final VoidCallback onClearDisplay;
  final bool autoScroll;
  final ValueChanged<bool> onAutoScrollChanged;

  const VideoLongPressMenu({
    super.key,
    required this.video,
    required this.currentSpeed,
    required this.onSpeedChanged,
    required this.onClearDisplay,
    required this.autoScroll,
    required this.onAutoScrollChanged,
  });

  @override
  State<VideoLongPressMenu> createState() => _VideoLongPressMenuState();
}

class _VideoLongPressMenuState extends State<VideoLongPressMenu> {
  Color get _accent => Theme.of(context).colorScheme.primary;

  void _toast(String msg) {
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  void _comingSoon(String feature) => _toast('$feature — coming soon');

  Future<void> _repost() async {
    final state = context.read<AppState>();
    try {
      await state.repostVideo(widget.video);
      if (mounted) _toast('Reposted to your followers');
    } catch (_) {
      if (mounted) _toast('Repost failed — try again');
    }
  }

  Future<void> _download() async {
    final state = context.read<AppState>();
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Downloading video…')));
    try {
      await state.downloadVideo(widget.video);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Video saved')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Download failed — try again')));
      }
    }
  }

  void _notInterested() {
    context.read<AppState>().markNotInterested(widget.video);
    _toast('Got it — fewer posts like this');
  }

  void _share(String target) async {
    if (target == 'copy') {
      await Clipboard.setData(ClipboardData(
          text: 'https://user.novamail.store/v/${widget.video.id}'));
      if (mounted) _toast('Link copied');
      return;
    }
    _comingSoon('Share to $target');
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.video;
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (context, scroll) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF141414),
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: ListView(
          controller: scroll,
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            const SizedBox(height: 10),
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 14),
            // Top row: Repost | Add to Story | contacts
            SizedBox(
              height: 92,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  _TopAction(
                    label: 'Repost',
                    onTap: _repost,
                    child: Container(
                      width: 58,
                      height: 58,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Theme.of(context).colorScheme.primary,
                        boxShadow: [
                          BoxShadow(
                            color: _accent.withValues(alpha: 0.4),
                            blurRadius: 12,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: const Icon(Icons.repeat_rounded,
                          color: Colors.black, size: 28),
                    ),
                  ),
                  _TopAction(
                    label: 'Add to\nStory',
                    onTap: () => _comingSoon('Add to Story'),
                    child: Stack(
                      children: [
                        const CircleAvatar(
                          radius: 29,
                          backgroundColor: Colors.white12,
                          child: Icon(Icons.person,
                              color: Colors.white54, size: 30),
                        ),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            width: 22,
                            height: 22,
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.lightBlueAccent,
                            ),
                            child: const Icon(Icons.add,
                                color: Colors.white, size: 16),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // recent contacts (from following list if available)
                  ..._recentContacts(),
                ],
              ),
            ),
            const SizedBox(height: 6),
            // Share with row
            _SectionCard(
              child: Row(
                children: [
                  const Icon(Icons.reply_rounded,
                      color: Colors.white70, size: 22),
                  const SizedBox(width: 10),
                  const Text('Share with',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                  const Spacer(),
                  _ShareCircle(
                    color: Colors.blueAccent,
                    icon: Icons.link_rounded,
                    onTap: () => _share('copy'),
                  ),
                  const SizedBox(width: 10),
                  _ShareCircle(
                    color: const Color(0xFF1877F2),
                    label: 'f',
                    onTap: () => _share('Facebook'),
                  ),
                  const SizedBox(width: 10),
                  _ShareCircle(
                    color: Colors.black,
                    label: '𝕏',
                    border: true,
                    onTap: () => _share('X'),
                  ),
                ],
              ),
            ),
            _MenuItem(
              icon: Icons.download_rounded,
              label: 'Download',
              onTap: _download,
            ),
            _MenuItem(
              icon: Icons.heart_broken_outlined,
              label: 'Not interested',
              onTap: _notInterested,
            ),
            _MenuItem(
              icon: Icons.flag_outlined,
              label: 'Report',
              onTap: () {
                Navigator.of(context).pop();
                showReportDialog(context,
                    targetType: 'video', targetId: v.id);
              },
            ),
            // Speed selector
            _SectionCard(
              child: Row(
                children: [
                  const Icon(Icons.speed_rounded,
                      color: Colors.white70, size: 22),
                  const SizedBox(width: 10),
                  const Text('Speed',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                  const Spacer(),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white10,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [0.5, 1.0, 1.5, 2.0].map((s) {
                        final selected =
                            (widget.currentSpeed - s).abs() < 0.01;
                        return GestureDetector(
                          onTap: () {
                            widget.onSpeedChanged(s);
                            setState(() {});
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: selected
                                  ? Colors.white24
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text('${s}x',
                                style: TextStyle(
                                  color: selected
                                      ? Colors.white
                                      : Colors.white54,
                                  fontWeight: selected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                )),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ],
              ),
            ),
            _MenuItem(
              icon: Icons.fullscreen_rounded,
              label: 'Clear display',
              onTap: () {
                Navigator.of(context).pop();
                widget.onClearDisplay();
              },
            ),
            _ToggleItem(
              icon: Icons.vertical_align_top_rounded,
              label: 'Auto scroll',
              value: widget.autoScroll,
              onChanged: (b) {
                widget.onAutoScrollChanged(b);
                setState(() {});
              },
            ),
            _MenuItem(
              icon: Icons.closed_caption_outlined,
              label: 'Captions and translation',
              onTap: () => _comingSoon('Captions and translation'),
            ),
            _MenuItem(
              icon: Icons.picture_in_picture_alt_outlined,
              label: 'Picture-in-Picture',
              onTap: () => _comingSoon('Picture-in-Picture'),
            ),
            _MenuItem(
              icon: Icons.help_outline_rounded,
              label: 'Why this post',
              onTap: () => _comingSoon('Why this post'),
            ),
            _MenuItem(
              icon: Icons.local_fire_department_outlined,
              label: 'Promote',
              goldIcon: true,
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => PromoteScreen(videoId: v.id)));
              },
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _recentContacts() {
    // Placeholder avatars; replaced by real following list when available.
    return List.generate(
      4,
      (i) => _TopAction(
        label: 'User${i + 1}',
        onTap: () => _comingSoon('Share to User${i + 1}'),
        child: const CircleAvatar(
          radius: 29,
          backgroundColor: Colors.white12,
          child: Icon(Icons.person, color: Colors.white38, size: 30),
        ),
      ),
    );
  }
}

class _TopAction extends StatelessWidget {
  final String label;
  final Widget child;
  final VoidCallback onTap;
  const _TopAction(
      {required this.label, required this.child, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.only(right: 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            child,
            const SizedBox(height: 6),
            SizedBox(
              width: 64,
              child: Text(label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 11)),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShareCircle extends StatelessWidget {
  final Color color;
  final IconData? icon;
  final String? label;
  final bool border;
  final VoidCallback onTap;
  const _ShareCircle({
    required this.color,
    this.icon,
    this.label,
    this.border = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: border
              ? Border.all(color: Colors.white24, width: 1)
              : null,
        ),
        child: Center(
          child: icon != null
              ? Icon(icon, color: Colors.white, size: 22)
              : Text(label!,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final Widget child;
  const _SectionCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF1e1e1e),
        borderRadius: BorderRadius.circular(14),
      ),
      child: child,
    );
  }
}

class _MenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool goldIcon;
  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.goldIcon = false,
  });

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Row(
          children: [
            Icon(icon,
                color: goldIcon
                    ? Theme.of(context).colorScheme.primary
                    : Colors.white70,
                size: 24),
            const SizedBox(width: 12),
            Text(label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }
}

class _ToggleItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _ToggleItem({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      child: Row(
        children: [
          Icon(icon, color: Colors.white70, size: 24),
          const SizedBox(width: 12),
          Text(label,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w500)),
          Spacer(),
          Switch(
            value: value,
            activeThumbColor: Theme.of(context).colorScheme.primary,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
