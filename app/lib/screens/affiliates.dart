import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../widgets/gifts.dart';

/// X-style company affiliates screen.
/// - Anyone can view a company's public affiliates list.
/// - Only the company itself (gold badge, viewing its own profile) can
///   add/remove affiliates. Users can NEVER affiliate themselves — the
///   company grants it (scam prevention).
class AffiliatesScreen extends StatefulWidget {
  final String companyUid;
  final String companyHandle;
  final bool canManage;
  const AffiliatesScreen({
    super.key,
    required this.companyUid,
    required this.companyHandle,
    this.canManage = false,
  });

  @override
  State<AffiliatesScreen> createState() => _AffiliatesScreenState();
}

class _AffiliatesScreenState extends State<AffiliatesScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().api;
    try {
      final r = await api.get('/api/affiliations', {'company': widget.companyUid});
      if (!mounted) return;
      setState(() {
        _items = ((r['affiliates'] as List?) ?? []).cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addAffiliate() async {
    final ctrl = TextEditingController();
    final handle = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Add affiliate'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '@username',
            prefixIcon: Icon(Icons.person_add_outlined),
          ),
          onSubmitted: (_) => Navigator.of(c).pop(ctrl.text.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(c).pop(ctrl.text.trim()),
              child: const Text('Affiliate')),
        ],
      ),
    );
    if (handle == null || handle.isEmpty) return;
    final clean = handle.startsWith('@') ? handle.substring(1) : handle;
    try {
      await context.read<AppState>().api.post('/api/affiliations', {'handle': clean});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('@$clean is now affiliated.')));
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not affiliate: ${e.toString()}')));
    }
  }

  Future<void> _remove(String uid, String handle) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Remove affiliate?'),
        content: Text('@$handle will no longer show as affiliated.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(c).pop(true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await context.read<AppState>().api.delete('/api/affiliations/$uid');
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('@$handle removed.')));
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not remove: ${e.toString()}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final fg = isDark ? Colors.white : Colors.black;
    final sub = isDark ? Colors.white60 : Colors.black54;
    return Scaffold(
      appBar: AppBar(
        title: Text('@${widget.companyHandle} affiliates',
            style: TextStyle(color: fg)),
        backgroundColor: theme.scaffoldBackgroundColor,
        iconTheme: IconThemeData(color: fg),
        actions: [
          if (widget.canManage)
            IconButton(
              icon: const Icon(Icons.person_add_outlined),
              tooltip: 'Add affiliate',
              onPressed: _addAffiliate,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _items.isEmpty
              ? Center(
                  child: Text('No affiliates yet.',
                      style: TextStyle(color: sub)))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    itemCount: _items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (c, i) {
                      final a = _items[i];
                      final handle = '${a['handle'] ?? ''}';
                      final name = '${a['display_name'] ?? ''}';
                      final avatar = '${a['avatar_url'] ?? ''}';
                      final vtype = '${a['verification_type'] ?? ''}';
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundImage: avatar.isNotEmpty
                              ? NetworkImage(avatar)
                              : null,
                          child: avatar.isEmpty
                              ? const Icon(Icons.person_outline)
                              : null,
                        ),
                        title: Row(
                          children: [
                            Flexible(
                              child: Text(
                                  name.isNotEmpty ? name : '@$handle',
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: fg,
                                      fontWeight: FontWeight.w600)),
                            ),
                            const SizedBox(width: 4),
                            VerifiedBadge(
                                size: 14,
                                type: vtype.isNotEmpty ? vtype : 'personal'),
                          ],
                        ),
                        subtitle: Text('@$handle',
                            style: TextStyle(color: sub)),
                        trailing: widget.canManage
                            ? IconButton(
                                icon: const Icon(Icons.remove_circle_outline,
                                    color: Colors.redAccent),
                                tooltip: 'Remove',
                                onPressed: () => _remove(
                                    '${a['uid'] ?? ''}', handle),
                              )
                            : null,
                        onTap: () {
                          // Open the affiliate's profile.
                          Navigator.of(context).pop();
                        },
                      );
                    },
                  ),
                ),
    );
  }
}
