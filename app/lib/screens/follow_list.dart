import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../state/app_state.dart';
import 'profile.dart';

/// Followers / Following list for a profile.
///
/// Each row: avatar, display name, @handle, Follow/Following button.
/// The list loads from GET /api/users/:id/followers (or /following);
/// the Follow button uses the existing POST/DELETE /api/users/:id/follow
/// endpoints via AppState.toggleFollow.
class FollowListScreen extends StatefulWidget {
  final String uidOrHandle;
  final String handle;
  final bool followers; // true = followers, false = following
  const FollowListScreen({
    super.key,
    required this.uidOrHandle,
    required this.handle,
    required this.followers,
  });

  @override
  State<FollowListScreen> createState() => _FollowListScreenState();
}

class _FollowListScreenState extends State<FollowListScreen> {
  List<NovaUser>? _users;
  bool _backendMissing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final users = widget.followers
        ? await state.fetchFollowers(widget.uidOrHandle)
        : await state.fetchFollowing(widget.uidOrHandle);
    if (!mounted) return;
    setState(() {
      _users = users;
      // The backend does not expose list endpoints yet: an empty result on
      // a profile that has followers means the endpoint is missing (the
      // AppState methods swallow the 404). Surface that honestly.
      _backendMissing = users.isEmpty && !state.isDemo;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? Colors.black : Colors.white;
    final fg = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white60 : Colors.black54;
    const gold = Color(0xFFFFC107);
    final state = context.watch<AppState>();

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        iconTheme: IconThemeData(color: fg),
        title: Text(widget.followers ? 'Followers' : 'Following',
            style: TextStyle(color: fg, fontWeight: FontWeight.w700)),
      ),
      body: _users == null
          ? const Center(child: CircularProgressIndicator(color: gold))
          : RefreshIndicator(
              color: gold,
              onRefresh: _load,
              child: _users!.isEmpty
                  ? ListView(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(40),
                          child: Column(
                            children: [
                              Icon(
                                  widget.followers
                                      ? Icons.group_outlined
                                      : Icons.person_add_outlined,
                                  size: 56,
                                  color: sub),
                              const SizedBox(height: 12),
                              Text(
                                _backendMissing
                                    ? 'Follow lists are not available yet — the server endpoint is still being added.'
                                    : (widget.followers
                                        ? '@${widget.handle} has no followers yet.'
                                        : '@${widget.handle} is not following anyone yet.'),
                                textAlign: TextAlign.center,
                                style: TextStyle(color: sub, fontSize: 14),
                              ),
                            ],
                          ),
                        ),
                      ],
                    )
                  : ListView.separated(
                      itemCount: _users!.length,
                      separatorBuilder: (_, __) => Divider(
                          height: 1,
                          color: isDark
                              ? const Color(0xFF1a1a1a)
                              : Colors.black12),
                      itemBuilder: (context, i) {
                        final u = _users![i];
                        final isSelf = u.uid == state.me?.uid;
                        final following =
                            state.followingUids.contains(u.uid);
                        return ListTile(
                          leading: CircleAvatar(
                            radius: 24,
                            backgroundColor: isDark
                                ? Colors.white12
                                : Colors.black12,
                            backgroundImage: u.avatarUrl.isNotEmpty
                                ? NetworkImage(u.avatarUrl)
                                : null,
                            child: u.avatarUrl.isEmpty
                                ? Text(
                                    u.handle.isNotEmpty
                                        ? u.handle[0].toUpperCase()
                                        : '?',
                                    style: TextStyle(color: fg))
                                : null,
                          ),
                          title: Text(
                            u.displayName.isNotEmpty
                                ? u.displayName
                                : '@${u.handle}',
                            style: TextStyle(
                                color: fg,
                                fontWeight: FontWeight.w700,
                                fontSize: 15),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text('@${u.handle}',
                              style: TextStyle(color: sub, fontSize: 13),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          trailing: isSelf
                              ? null
                              : SizedBox(
                                  width: 104,
                                  height: 34,
                                  child: following
                                      ? OutlinedButton(
                                          style: OutlinedButton.styleFrom(
                                            side: BorderSide(
                                                color: isDark
                                                    ? Colors.white24
                                                    : Colors.black26),
                                            shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(6)),
                                          ),
                                          onPressed: () {
                                            // Optimistic: toggleFollow updates
                                            // followingUids + notifyListeners()
                                            // synchronously; no await needed.
                                            state.toggleFollow(u.uid);
                                          },
                                          child: Text('Following',
                                              style: TextStyle(
                                                  color: fg,
                                                  fontSize: 13,
                                                  fontWeight:
                                                      FontWeight.w600)),
                                        )
                                      : ElevatedButton(
                                          style:
                                              ElevatedButton.styleFrom(
                                            backgroundColor: gold,
                                            foregroundColor: Colors.black,
                                            shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(6)),
                                          ),
                                          onPressed: () {
                                            // Optimistic: toggleFollow updates
                                            // followingUids + notifyListeners()
                                            // synchronously; no await needed.
                                            state.toggleFollow(u.uid);
                                          },
                                          child: const Text('Follow',
                                              style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight:
                                                      FontWeight.w700)),
                                        ),
                                ),
                          onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => ProfileScreen(
                                      uid: u.uid, handle: u.handle))),
                        );
                      },
                    ),
            ),
    );
  }
}
