import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../state/app_state.dart';
import '../widgets/gifts.dart';
import 'inbox.dart';
import 'monetization.dart';
import 'p2p.dart';
import 'market.dart';
import 'report.dart';
import 'settings.dart';
import 'wallet.dart';

/// Profile page with Videos + Store tabs. Self view includes wallet, P2P,
/// Nova Coin, verification, and settings shortcuts.
class ProfileScreen extends StatefulWidget {
  final bool self;
  final String? uid;
  final String? handle;
  const ProfileScreen({super.key, this.self = false, this.uid, this.handle});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  NovaUser? _user;
  int _followers = 0;
  int _following = 0;
  int _videos = 0;
  bool _loading = true;
  bool _isFollowing = false;

  @override
  void initState() {
    super.initState();
    _load();
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
          _followers = 1200; // demo placeholder
        } else if (_user != null) {
          try {
            final r = await state.api.get('/api/users/${_user!.uid}');
            final counts = r['counts'] as Map?;
            _followers = (counts?['followers'] ?? 0) as int;
            _following = (counts?['following'] ?? 0) as int;
          } catch (_) {}
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (_loading) {
      return const Scaffold(backgroundColor: Colors.black, body: Center(child: CircularProgressIndicator(color: Color(0xFFFFC107))));
    }
    final u = _user ?? state.me;
    if (u == null) {
      return const Scaffold(backgroundColor: Colors.black, body: Center(child: Text('User not found', style: TextStyle(color: Colors.white54))));
    }
    final myVideos = state.feed.where((v) => v.uid == u.uid).toList();
    final myListings = state.listings.where((l) => l.uid == u.uid).toList();
    _videos = myVideos.length;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text('@${u.handle}'),
        actions: [
          if (!widget.self)
            IconButton(
              icon: const Icon(Icons.flag_outlined),
              onPressed: () => showReportDialog(context, targetType: 'user', targetId: u.uid),
            ),
          if (!widget.self)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              color: const Color(0xFF1a1a1a),
              onSelected: (v) async {
                final state = context.read<AppState>();
                if (v == 'block') {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      backgroundColor: const Color(0xFF1a1a1a),
                      title: Text('Block @${u.handle}?', style: const TextStyle(color: Colors.white)),
                      content: const Text('They will not be able to see your content, profile, or messages until you unblock them.',
                          style: TextStyle(color: Colors.white70)),
                      actions: [
                        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('Block'),
                        ),
                      ],
                    ),
                  );
                  if (ok == true && context.mounted) {
                    await state.blockUser(u.uid);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('@${u.handle} blocked.')));
                      Navigator.of(context).pop();
                    }
                  }
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'block', child: Text('Block user', style: TextStyle(color: Colors.redAccent))),
              ],
            ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 16),
            CircleAvatar(
              radius: 44,
              backgroundColor: Colors.white24,
              backgroundImage: u.avatarUrl.isNotEmpty ? NetworkImage(u.avatarUrl) : null,
              child: u.avatarUrl.isEmpty ? Text(u.handle.isNotEmpty ? u.handle[0].toUpperCase() : '?', style: const TextStyle(fontSize: 32)) : null,
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('@${u.handle}', style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                if (u.isVerified) ...[const SizedBox(width: 6), const VerifiedBadge(size: 18)],
                if (u.isOfficial) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: const Color(0xFFFFC107), borderRadius: BorderRadius.circular(4)),
                    child: const Text('OFFICIAL', style: TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.bold)),
                  ),
                ],
                if (u.isBot) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                        color: Colors.white12, borderRadius: BorderRadius.circular(4), border: Border.all(color: Colors.white24)),
                    child: const Text('BOT', style: TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.bold)),
                  ),
                ],
              ],
            ),
            if (u.displayName.isNotEmpty) Text(u.displayName, style: const TextStyle(color: Colors.white70)),
            if (u.bio.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 4),
                child: Text(u.bio, style: const TextStyle(color: Colors.white60), textAlign: TextAlign.center),
              ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _Stat(n: _videos, label: 'Videos'),
                _Stat(n: _followers, label: 'Followers'),
                _Stat(n: _following, label: 'Following'),
                _Stat(n: u.tradesCompleted, label: 'Trades'),
              ],
            ),
            if (u.traderScore > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Trader score: ${u.traderScore.toStringAsFixed(0)} ★',
                    style: const TextStyle(color: Color(0xFFFFC107), fontWeight: FontWeight.w600)),
              ),
            const SizedBox(height: 12),
            if (widget.self)
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  _ActionChip(icon: Icons.account_balance_wallet_outlined, label: 'Wallet', onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const WalletScreen()))),
                  _ActionChip(icon: Icons.swap_horiz, label: 'P2P', onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const P2PScreen()))),
                  _ActionChip(icon: Icons.monetization_on_outlined, label: 'Nova Coins', onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CoinsScreen()))),
                  _ActionChip(icon: Icons.storefront_outlined, label: 'Market', onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MarketplaceScreen()))),
                  _ActionChip(icon: Icons.verified_outlined, label: state.verificationActive ? 'Verified ✓' : 'Get verified', onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const VerificationScreen()))),
                  _ActionChip(icon: Icons.settings_outlined, label: 'Settings', onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen()))),
                ],
              )
            else
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black),
                    onPressed: () async {
                      await state.toggleFollow(u.uid);
                      setState(() => _isFollowing = !_isFollowing);
                    },
                    child: Text(_isFollowing ? 'Following' : 'Follow'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                    onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(peerUid: u.uid, peerHandle: u.handle))),
                    child: const Text('Message'),
                  ),
                ],
              ),
            const SizedBox(height: 8),
            DefaultTabController(
              length: 2,
              child: Column(
                children: [
                  const TabBar(
                    indicatorColor: Color(0xFFFFC107),
                    labelColor: Colors.white,
                    unselectedLabelColor: Colors.white54,
                    tabs: [Tab(icon: Icon(Icons.grid_view)), Tab(icon: Icon(Icons.storefront_outlined))],
                  ),
                  SizedBox(
                    height: 420,
                    child: TabBarView(
                      children: [
                        myVideos.isEmpty
                            ? const Center(child: Text('No videos yet', style: TextStyle(color: Colors.white38)))
                            : GridView.builder(
                                physics: const NeverScrollableScrollPhysics(),
                                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, childAspectRatio: 0.7),
                                itemCount: myVideos.length,
                                itemBuilder: (context, i) {
                                  final v = myVideos[i];
                                  return Container(
                                    margin: const EdgeInsets.all(1),
                                    color: const Color(0xFF1a1a1a),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        const Icon(Icons.play_arrow, color: Colors.white54, size: 36),
                                        Positioned(
                                          bottom: 4,
                                          left: 4,
                                          right: 4,
                                          child: Text(v.caption, style: const TextStyle(color: Colors.white70, fontSize: 10), maxLines: 2, overflow: TextOverflow.ellipsis),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                        myListings.isEmpty
                            ? const Center(child: Text('No products yet', style: TextStyle(color: Colors.white38)))
                            : ListView.builder(
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: myListings.length,
                                itemBuilder: (context, i) {
                                  final l = myListings[i];
                                  return ListTile(
                                    title: Text(l.title, style: const TextStyle(color: Colors.white)),
                                    subtitle: Text('\$${l.priceUsd.toStringAsFixed(2)} · ${l.asset}', style: const TextStyle(color: Color(0xFFFFC107))),
                                    trailing: const Icon(Icons.chevron_right, color: Colors.white54),
                                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ProductDetailScreen(listing: l))),
                                  );
                                },
                              ),
                      ],
                    ),
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

class _Stat extends StatelessWidget {
  final int n;
  final String label;
  const _Stat({required this.n, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Column(
        children: [
          Text('$n', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
          Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
        ],
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _ActionChip({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(border: Border.all(color: Colors.white24), borderRadius: BorderRadius.circular(20)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: const Color(0xFFFFC107)),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
