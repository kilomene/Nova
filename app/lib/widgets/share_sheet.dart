import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../screens/report.dart';
import '../state/app_state.dart';
import 'gifts.dart';

/// TikTok-style share menu. No Duet. "Not interested" actually filters the FYP.
class ShareSheet extends StatelessWidget {
  final NovaVideo video;
  const ShareSheet({super.key, required this.video});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF161616) : Colors.white;
    final fg = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white70 : Colors.black54;

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 40, height: 4,
              decoration: BoxDecoration(color: sub.withOpacity(0.3), borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 12),
          Text('Share', style: TextStyle(color: fg, fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 12),
          // Send to row
          SizedBox(
            height: 84,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                _sendTo(context, 'Repost', Icons.repeat, Colors.green, () => _repost(context)),
                _sendTo(context, 'WhatsApp', Icons.chat, const Color(0xFF25D366), () => _shareExternal(context, 'whatsapp')),
                _sendTo(context, 'Copy link', Icons.link, fg, () => _copyLink(context)),
                _sendTo(context, 'Facebook', Icons.facebook, const Color(0xFF1877F2), () => _shareExternal(context, 'facebook')),
                _sendTo(context, 'X', Icons.close, fg, () => _shareExternal(context, 'x')),
                _sendTo(context, 'SMS', Icons.sms, Colors.blue, () => _shareExternal(context, 'sms')),
                _sendTo(context, 'Email', Icons.email, Colors.red, () => _shareExternal(context, 'email')),
              ],
            ),
          ),
          const Divider(),
          // Actions grid
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Wrap(
              spacing: 8, runSpacing: 8,
              children: [
                _action(context, 'Report', Icons.flag_outlined, () {
                  Navigator.pop(context);
                  showReportDialog(context, targetType: 'video', targetId: video.id);
                }),
                _action(context, 'Not interested', Icons.visibility_off_outlined, () => _notInterested(context)),
                _action(context, 'Download', Icons.download_outlined, () => _download(context)),
                _action(context, 'Add to Story', Icons.add_circle_outline, () {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Added to story')));
                }),
                _action(context, 'Promote', Icons.rocket_launch_outlined, () {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Promote coming soon')));
                }),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _sendTo(BuildContext context, String label, IconData icon, Color color, VoidCallback onTap) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 68,
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          children: [
            Container(
              width: 48, height: 48,
              decoration: BoxDecoration(
                color: isDark ? Colors.white12 : Colors.black.withOpacity(0.06),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 11, color: isDark ? Colors.white70 : Colors.black54),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }

  Widget _action(BuildContext context, String label, IconData icon, VoidCallback onTap) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : Colors.black87;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 100,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: isDark ? Colors.white10 : Colors.black.withOpacity(0.05),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(icon, color: fg, size: 22),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 11, color: fg), textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }

  Future<void> _copyLink(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: 'https://user.novamail.store/v/${video.id}'));
    if (context.mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
    }
  }

  Future<void> _repost(BuildContext context) async {
    final state = context.read<AppState>();
    try {
      await state.api.post('/api/videos/${video.id}/repost', {});
      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Reposted')));
      }
    } catch (_) {
      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Repost failed')));
      }
    }
  }

  Future<void> _notInterested(BuildContext context) async {
    final state = context.read<AppState>();
    try {
      await state.api.post('/api/videos/${video.id}/not-interested', {});
      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("Got it — you'll see fewer videos like this")));
      }
    } catch (_) {
      if (context.mounted) Navigator.pop(context);
    }
  }

  void _shareExternal(BuildContext context, String platform) {
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Sharing via $platform')));
  }

  void _download(BuildContext context) {
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Downloading...')));
  }
}
