import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../state/app_state.dart';
import 'monetization.dart';
import 'promote.dart';
import 'settings.dart';
import 'wallet.dart';

/// Profile hamburger menu — TikTok structure in Nova dark+gold skin.
///
/// Sections (exact per user spec):
///   Assets: Balance, Wallet (crypto)
///   Personal tools: Activity center, Your QR code, Your Music, Promote
///   Then: Settings and privacy
class ProfileMenuScreen extends StatelessWidget {
  const ProfileMenuScreen({super.key});

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
        iconTheme: IconThemeData(color: fg),
        title: Text('Menu', style: TextStyle(color: fg, fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _SectionHeader('Assets', sub),
          _MenuRow(
            icon: Icons.account_balance_wallet_outlined,
            label: 'Balance',
            fg: fg,
            sub: sub,
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const CoinsScreen())),
          ),
          _MenuRow(
            icon: Icons.currency_bitcoin,
            label: 'Wallet',
            subtitle: 'Crypto wallet',
            fg: fg,
            sub: sub,
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const WalletScreen())),
          ),
          _SectionHeader('Personal tools', sub),
          _MenuRow(
            icon: Icons.history_outlined,
            label: 'Activity center',
            fg: fg,
            sub: sub,
            onTap: () => _comingSoon(context, 'Activity center'),
          ),
          _MenuRow(
            icon: Icons.qr_code_2_outlined,
            label: 'Your QR code',
            fg: fg,
            sub: sub,
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MyQrScreen())),
          ),
          _MenuRow(
            icon: Icons.music_note_outlined,
            label: 'Your Music',
            fg: fg,
            sub: sub,
            onTap: () => _comingSoon(context, 'Your Music'),
          ),
          _MenuRow(
            icon: Icons.local_fire_department_outlined,
            label: 'Promote',
            fg: fg,
            sub: sub,
            goldIcon: true,
            onTap: () {
              final state = context.read<AppState>();
              final firstVideo = state.feed.isNotEmpty ? state.feed.first : null;
              if (firstVideo != null && context.mounted) {
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => PromoteScreen(videoId: firstVideo.id)));
              } else if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Post a video first to promote it')));
              }
            },
          ),
          const SizedBox(height: 8),
          _MenuRow(
            icon: Icons.settings_outlined,
            label: 'Settings and privacy',
            fg: fg,
            sub: sub,
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
    );
  }

  void _comingSoon(BuildContext context, String feature) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$feature — coming soon')));
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  final Color sub;
  const _SectionHeader(this.title, this.sub);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(title,
          style: TextStyle(
              color: sub, fontSize: 13, fontWeight: FontWeight.w600)),
    );
  }
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final Color fg;
  final Color sub;
  final bool goldIcon;
  final VoidCallback onTap;
  const _MenuRow({
    required this.icon,
    required this.label,
    required this.fg,
    required this.sub,
    required this.onTap,
    this.subtitle,
    this.goldIcon = false,
  });

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFFFC107);
    return ListTile(
      leading: Icon(icon, color: goldIcon ? gold : fg, size: 24),
      title: Text(label,
          style: TextStyle(color: fg, fontSize: 15, fontWeight: FontWeight.w500)),
      subtitle: subtitle != null
          ? Text(subtitle!, style: TextStyle(color: sub, fontSize: 12))
          : null,
      trailing: Icon(Icons.chevron_right, color: sub),
      onTap: onTap,
    );
  }
}

/// "Your QR code" — scannable profile QR in Nova gold.
class MyQrScreen extends StatelessWidget {
  const MyQrScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final u = state.me;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? Colors.black : Colors.white;
    final fg = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white60 : Colors.black54;
    const gold = Color(0xFFFFC107);
    final profileUrl = 'https://nova.app/@${u?.handle ?? 'nova'}';

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        iconTheme: IconThemeData(color: fg),
        title: Text('Your QR code', style: TextStyle(color: fg, fontWeight: FontWeight.w700)),
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                      color: gold.withValues(alpha: 0.3),
                      blurRadius: 24,
                      spreadRadius: 2),
                ],
              ),
              child: QrImageView(
                data: profileUrl,
                version: QrVersions.auto,
                size: 220,
                eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square, color: Colors.black),
                dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: Colors.black),
              ),
            ),
            const SizedBox(height: 20),
            Text('@${u?.handle ?? 'nova'}',
                style: TextStyle(
                    color: fg, fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('Scan to visit my Nova profile',
                style: TextStyle(color: sub, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
