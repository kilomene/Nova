import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../state/app_state.dart';
import 'gifts.dart';

/// TikTok-style comment tile with likes and expandable replies.
class CommentTile extends StatefulWidget {
  final VideoComment comment;
  final String videoId;
  final int depth;
  const CommentTile({super.key, required this.comment, required this.videoId, this.depth = 0});

  @override
  State<CommentTile> createState() => _CommentTileState();
}

class _CommentTileState extends State<CommentTile> {
  bool _showReplies = false;
  List<VideoComment> _replies = [];
  bool _loadingReplies = false;
  final _replyCtrl = TextEditingController();
  bool _showReplyField = false;

  Future<void> _toggleLike() async {
    final state = context.read<AppState>();
    final c = widget.comment;
    final newVal = !c.likedByMe;
    setState(() {
      c.likedByMe = newVal;
      c.likeCount += newVal ? 1 : -1;
    });
    try {
      if (newVal) {
        await state.api.post('/api/videos/${widget.videoId}/comments/${c.id}/like', {});
      } else {
        await state.api.delete('/api/videos/${widget.videoId}/comments/${c.id}/like');
      }
    } catch (_) {
      if (mounted) setState(() {
        c.likedByMe = !newVal;
        c.likeCount += newVal ? -1 : 1;
      });
    }
  }

  Future<void> _loadReplies() async {
    if (_showReplies) {
      setState(() => _showReplies = false);
      return;
    }
    final state = context.read<AppState>();
    setState(() => _loadingReplies = true);
    try {
      final res = await state.api.get('/api/videos/${widget.videoId}/comments/${widget.comment.id}/replies');
      if (mounted) setState(() {
        _replies = ((res['replies'] as List?) ?? []).map((j) => VideoComment.fromJson(j)).toList();
        _showReplies = true;
        _loadingReplies = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingReplies = false);
    }
  }

  Future<void> _postReply() async {
    final t = _replyCtrl.text.trim();
    if (t.isEmpty) return;
    final state = context.read<AppState>();
    _replyCtrl.clear();
    setState(() => _showReplyField = false);
    try {
      await state.api.post('/api/videos/${widget.videoId}/comments/${widget.comment.id}/replies', {'text': t});
      if (mounted) {
        setState(() {
          widget.comment.replyCount++;
          _showReplies = false; // force reload
        });
        _loadReplies();
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white70 : Colors.black54;
    final faint = isDark ? Colors.white38 : Colors.black38;
    final c = widget.comment;

    return Padding(
      padding: EdgeInsets.only(left: widget.depth * 36.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: isDark ? Colors.white24 : Colors.black12,
                backgroundImage: c.avatarUrl.isNotEmpty ? NetworkImage(c.avatarUrl) : null,
                child: c.avatarUrl.isEmpty
                    ? Text(c.handle.isNotEmpty ? c.handle[0].toUpperCase() : '?', style: const TextStyle(fontSize: 14))
                    : null,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(c.displayName.isNotEmpty ? c.displayName : c.handle,
                            style: TextStyle(color: fg, fontWeight: FontWeight.bold, fontSize: 13)),
                        if (c.isVerified) ...[
                          const SizedBox(width: 4),
                          VerifiedBadge(size: 13, type: c.verificationType),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(c.text, style: TextStyle(color: fg, fontSize: 14)),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text(_timeAgo(c.createdAt), style: TextStyle(color: faint, fontSize: 12)),
                        const SizedBox(width: 16),
                        GestureDetector(
                          onTap: () => setState(() => _showReplyField = !_showReplyField),
                          child: Text('Reply', style: TextStyle(color: sub, fontSize: 12, fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                    if (_showReplyField) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _replyCtrl,
                              autofocus: true,
                              style: TextStyle(color: fg, fontSize: 13),
                              decoration: InputDecoration(
                                hintText: 'Reply to ${c.handle}...',
                                hintStyle: TextStyle(color: faint, fontSize: 13),
                                isDense: true,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              ),
                              onSubmitted: (_) => _postReply(),
                            ),
                          ),
                          IconButton(
                            icon: Icon(Icons.send, size: 18, color: Theme.of(context).colorScheme.primary),
                            onPressed: _postReply,
                          ),
                        ],
                      ),
                    ],
                    if (c.replyCount > 0) ...[
                      const SizedBox(height: 4),
                      GestureDetector(
                        onTap: _loadingReplies ? null : _loadReplies,
                        child: Row(
                          children: [
                            Container(width: 24, height: 1, color: faint),
                            const SizedBox(width: 6),
                            Text(
                              _loadingReplies
                                  ? 'Loading...'
                                  : _showReplies
                                      ? 'Hide replies'
                                      : 'View ${c.replyCount} ${c.replyCount == 1 ? 'reply' : 'replies'}',
                              style: TextStyle(color: sub, fontSize: 12, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Column(
                children: [
                  GestureDetector(
                    onTap: _toggleLike,
                    child: Icon(
                      c.likedByMe ? Icons.favorite : Icons.favorite_border,
                      size: 20,
                      color: c.likedByMe ? Colors.redAccent : faint,
                    ),
                  ),
                  if (c.likeCount > 0)
                    Text('${c.likeCount}', style: TextStyle(color: faint, fontSize: 11)),
                ],
              ),
            ],
          ),
          if (_showReplies)
            ..._replies.map((r) => Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: CommentTile(comment: r, videoId: widget.videoId, depth: widget.depth + 1),
                )),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  String _timeAgo(int ts) {
    final diff = DateTime.now().millisecondsSinceEpoch - ts;
    final m = diff ~/ 60000;
    if (m < 1) return 'now';
    if (m < 60) return '${m}m';
    final h = m ~/ 60;
    if (h < 24) return '${h}h';
    final d = h ~/ 24;
    if (d < 7) return '${d}d';
    return '${d ~/ 7}w';
  }

  @override
  void dispose() {
    _replyCtrl.dispose();
    super.dispose();
  }
}
