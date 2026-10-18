import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

/// Profile views — list of people who viewed your profile (30 days).
class ProfileViewsScreen extends StatefulWidget {
  const ProfileViewsScreen({super.key});

  @override
  State<ProfileViewsScreen> createState() => _ProfileViewsScreenState();
}

class _ProfileViewsScreenState extends State<ProfileViewsScreen> {
  List<dynamic> _views = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    setState(() => _loading = true);
    try {
      final res = await state.api.get('/api/users/me/profile-views');
      if (mounted) setState(() {
        _views = (res['views'] as List?) ?? [];
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white70 : Colors.black54;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile views'),
        subtitle: Text('${_views.length} in the last 30 days', style: TextStyle(fontSize: 12, color: sub)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _views.isEmpty
              ? Center(child: Text('No profile views yet', style: TextStyle(color: sub)))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    itemCount: _views.length,
                    itemBuilder: (context, i) {
                      final v = _views[i];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundImage: (v['avatar_url'] as String?)?.isNotEmpty == true
                              ? NetworkImage(v['avatar_url'])
                              : null,
                          child: (v['avatar_url'] as String?)?.isEmpty != false
                              ? Text((v['handle'] as String? ?? '?')[0].toUpperCase())
                              : null,
                        ),
                        title: Text('${v['display_name'] ?? v['handle'] ?? 'User'}',
                            style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
                        subtitle: Text('@${v['handle'] ?? ''}', style: TextStyle(color: sub, fontSize: 13)),
                        trailing: (v['is_following'] == true)
                            ? Text('Following', style: TextStyle(color: sub, fontSize: 13))
                            : ElevatedButton(
                                onPressed: () async {
                                  final state = context.read<AppState>();
                                  try {
                                    await state.api.post('/api/users/${v['uid']}/follow', {});
                                    if (mounted) setState(() => v['is_following'] = true);
                                  } catch (_) {}
                                },
                                style: ElevatedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                ),
                                child: const Text('Follow', style: TextStyle(fontSize: 13)),
                              ),
                      );
                    },
                  ),
                ),
    );
  }
}
