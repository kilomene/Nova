import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

/// TikTok-style suggested accounts carousel.
class SuggestedAccounts extends StatefulWidget {
  final String userId;
  const SuggestedAccounts({super.key, required this.userId});

  @override
  State<SuggestedAccounts> createState() => _SuggestedAccountsState();
}

class _SuggestedAccountsState extends State<SuggestedAccounts> {
  List<dynamic> _suggested = [];
  bool _loading = true;
  bool _expanded = true;
  final Set<String> _dismissed = {};
  final Set<String> _followed = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    try {
      final res = await state.api.get('/api/users/${widget.userId}/suggested');
      if (mounted) setState(() {
        _suggested = (res['suggested'] as List?) ?? [];
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    final visible = _suggested.where((s) => !_dismissed.contains('${s['uid']}')).toList();
    if (visible.isEmpty) return const SizedBox.shrink();

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white70 : Colors.black54;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Text('Suggested accounts', style: TextStyle(color: fg, fontWeight: FontWeight.bold, fontSize: 15)),
              const Spacer(),
              GestureDetector(
                onTap: () => setState(() => _expanded = !_expanded),
                child: Icon(_expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, color: sub),
              ),
            ],
          ),
        ),
        if (_expanded)
          SizedBox(
            height: 190,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: visible.length,
              itemBuilder: (context, i) {
                final s = visible[i];
                final uid = '${s['uid']}';
                final isFollowed = _followed.contains(uid);
                return Container(
                  width: 140,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isDark ? Colors.white10 : Colors.black.withOpacity(0.04),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          GestureDetector(
                            onTap: () => setState(() => _dismissed.add(uid)),
                            child: Icon(Icons.close, size: 16, color: sub),
                          ),
                        ],
                      ),
                      CircleAvatar(
                        radius: 28,
                        backgroundImage: (s['avatar_url'] as String?)?.isNotEmpty == true
                            ? NetworkImage(s['avatar_url'])
                            : null,
                        child: (s['avatar_url'] as String?)?.isEmpty != false
                            ? Text((s['handle'] as String? ?? '?')[0].toUpperCase())
                            : null,
                      ),
                      const SizedBox(height: 8),
                      Text('${s['display_name'] ?? s['handle']}',
                          style: TextStyle(color: fg, fontWeight: FontWeight.w600, fontSize: 13),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text('@${s['handle'] ?? ''}',
                          style: TextStyle(color: sub, fontSize: 11),
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      const Spacer(),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: isFollowed ? null : () async {
                            final state = context.read<AppState>();
                            try {
                              await state.api.post('/api/users/$uid/follow', {});
                              if (mounted) setState(() => _followed.add(uid));
                            } catch (_) {}
                          },
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            minimumSize: Size.zero,
                          ),
                          child: Text(isFollowed ? 'Following' : 'Follow', style: const TextStyle(fontSize: 12)),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}
