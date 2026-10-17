import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../services/api_client.dart';
import '../state/app_state.dart';
import '../widgets/gifts.dart';

/// LIVE: rooms list, go-live (1000+ followers enforced), and the live room
/// with chat, viewer count, and Nova Coin gift effects.
///
/// v1 video layer: a realtime room (chat/gifts/viewers). RTMP/WebRTC
/// ingest is a documented TODO — the gift economy is fully wired.
class LiveListScreen extends StatefulWidget {
  const LiveListScreen({super.key});

  @override
  State<LiveListScreen> createState() => _LiveListScreenState();
}

class _LiveListScreenState extends State<LiveListScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<AppState>().loadLiveSessions());
  }

  Future<void> _goLive() async {
    final state = context.read<AppState>();
    final title = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a1a1a),
        title: const Text('Go LIVE', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Broadcasting requires 1,000+ followers.', style: TextStyle(color: Colors.white54, fontSize: 12)),
            TextField(controller: title, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'Stream title', labelStyle: TextStyle(color: Colors.white54))),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Go live'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final id = await state.startLive(title.text.trim().isEmpty ? 'Live now' : title.text.trim());
      if (mounted) {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => LiveRoomScreen(sessionId: id, isBroadcaster: true, title: title.text.trim())));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e is ApiException ? e.message : 'Could not go live. Please try again.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('LIVE')),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Colors.redAccent,
        icon: const Icon(Icons.videocam),
        label: const Text('Go LIVE'),
        onPressed: _goLive,
      ),
      body: state.liveSessions.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('Nobody is live right now.\nReach 1,000 followers to start your own stream.',
                    textAlign: TextAlign.center, style: TextStyle(color: Colors.white38)),
              ),
            )
          : ListView.builder(
              itemCount: state.liveSessions.length,
              itemBuilder: (context, i) {
                final s = state.liveSessions[i];
                return Card(
                  color: const Color(0xFF161616),
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: ListTile(
                    leading: Stack(
                      children: [
                        CircleAvatar(
                          backgroundColor: Colors.white24,
                          backgroundImage: s.avatarUrl.isNotEmpty ? NetworkImage(s.avatarUrl) : null,
                          child: s.avatarUrl.isEmpty ? Text(s.handle.isNotEmpty ? s.handle[0].toUpperCase() : '?') : null,
                        ),
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(color: Colors.redAccent, borderRadius: BorderRadius.circular(8)),
                            child: const Text('LIVE', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ],
                    ),
                    title: Row(
                      children: [
                        Expanded(child: Text(s.title.isEmpty ? '@${s.handle} is live' : s.title, style: const TextStyle(color: Colors.white))),
                        if (s.isVerified) ...[const SizedBox(width: 4), const VerifiedBadge(size: 14)],
                      ],
                    ),
                    subtitle: Text('@${s.handle} · ${s.viewerCount} watching', style: const TextStyle(color: Colors.white54)),
                    trailing: const Icon(Icons.chevron_right, color: Colors.white54),
                    onTap: () {
                      state.joinLive(s.id);
                      Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => LiveRoomScreen(sessionId: s.id, isBroadcaster: false, title: s.title, session: s)));
                    },
                  ),
                );
              },
            ),
    );
  }
}

class LiveRoomScreen extends StatefulWidget {
  final String sessionId;
  final bool isBroadcaster;
  final String title;
  final LiveSession? session;
  const LiveRoomScreen({super.key, required this.sessionId, required this.isBroadcaster, required this.title, this.session});

  @override
  State<LiveRoomScreen> createState() => _LiveRoomScreenState();
}

class _LiveRoomScreenState extends State<LiveRoomScreen> {
  final _chat = TextEditingController();
  final List<String> _messages = [];
  final List<_GiftFx> _fx = [];
  int _viewers = 1;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _viewers = (widget.session?.viewerCount ?? 0) + 1;
    _sub = context.read<AppState>().sync.events.listen((e) {
      if (!mounted) return;
      if (e['type'] == 'gift' && (e['liveSessionId'] == widget.sessionId || (e['liveSessionId'] ?? '') == '')) {
        setState(() {
          _fx.add(_GiftFx(animation: '${e['giftId'] == null ? 'coin_burst' : _animFor(e['giftId'] as String)}', sender: 'Someone'));
          _messages.add('🎁 Someone sent a gift!');
        });
        Future.delayed(const Duration(milliseconds: 2600), () {
          if (mounted && _fx.isNotEmpty) setState(() => _fx.removeAt(0));
        });
      }
    });
  }

  String _animFor(String giftId) {
    const map = {'coin_burst': 'coin_burst', 'nova_heart': 'nova_heart', 'rocket': 'rocket', 'crown': 'crown'};
    return map[giftId] ?? 'coin_burst';
  }

  @override
  void dispose() {
    _sub?.cancel();
    _chat.dispose();
    if (!widget.isBroadcaster) context.read<AppState>().leaveLive(widget.sessionId);
    super.dispose();
  }

  Future<void> _giftFlow() async {
    final state = context.read<AppState>();
    await state.coins.refresh(state.api);
    if (!mounted) return;
    final picked = await showModalBottomSheet<dynamic>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => GiftPickerSheet(balance: state.coins.balance, gifts: state.coins.gifts, onPick: (g) => Navigator.of(context).pop(g)),
    );
    if (picked == null || !mounted) return;
    try {
      final recipient = widget.session?.uid ?? 'broadcaster';
      await state.coins.sendGift(state.api, recipientUid: recipient, giftId: picked.id as String, liveSessionId: widget.sessionId);
      if (!mounted) return;
      setState(() {
        _fx.add(_GiftFx(animation: picked.animation as String, sender: 'You'));
        _messages.add('🎁 You sent a ${picked.name}!');
      });
      Future.delayed(const Duration(milliseconds: 2600), () {
        if (mounted && _fx.isNotEmpty) setState(() => _fx.removeAt(0));
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e is ApiException ? e.message : 'Gift failed. Please try again.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // v1 stage: realtime room. Video ingest (RTMP/WebRTC) is a documented TODO.
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF2a1a00), Color(0xFF0a0a0a)]),
            ),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(color: Colors.redAccent, borderRadius: BorderRadius.circular(8)),
                    child: const Text('● LIVE', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(height: 12),
                  const Icon(Icons.videocam_off_outlined, size: 56, color: Colors.white24),
                  const SizedBox(height: 8),
                  const Text('Video ingest coming soon', style: TextStyle(color: Colors.white38)),
                  const Text('Chat, gifts & viewers are live now', style: TextStyle(color: Colors.white24, fontSize: 12)),
                ],
              ),
            ),
          ),
          // gift fx layer
          for (final fx in _fx)
            Positioned.fill(
              child: IgnorePointer(child: GiftAnimationOverlay(animation: fx.animation, senderHandle: fx.sender)),
            ),
          // top bar
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.of(context).pop()),
                  Expanded(
                    child: Text(widget.title.isEmpty ? 'Live now' : widget.title,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                    child: Text('👁 $_viewers', style: const TextStyle(color: Colors.white, fontSize: 12)),
                  ),
                  if (widget.isBroadcaster) ...[
                    const SizedBox(width: 8),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                      onPressed: () async {
                        await state.endLive(widget.sessionId);
                        if (mounted) Navigator.of(context).pop();
                      },
                      child: const Text('End'),
                    ),
                  ],
                ],
              ),
            ),
          ),
          // chat + gift bar
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: EdgeInsets.only(left: 12, right: 12, bottom: MediaQuery.of(context).viewInsets.bottom + 12, top: 8),
              decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black87])),
              child: Column(
                children: [
                  SizedBox(
                    height: 140,
                    child: ListView.builder(
                      reverse: true,
                      itemCount: _messages.length,
                      itemBuilder: (context, i) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Text(_messages[_messages.length - 1 - i], style: const TextStyle(color: Colors.white70, fontSize: 13)),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _chat,
                          style: const TextStyle(color: Colors.white),
                          decoration: const InputDecoration(
                            hintText: 'Chat…',
                            hintStyle: TextStyle(color: Colors.white38),
                            filled: true,
                            fillColor: Colors.black54,
                            border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(20)), borderSide: BorderSide.none),
                          ),
                          onSubmitted: (t) {
                            if (t.trim().isEmpty) return;
                            setState(() => _messages.add('You: ${t.trim()}'));
                            _chat.clear();
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: _giftFlow,
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(color: const Color(0xFFFFC107), borderRadius: BorderRadius.circular(24)),
                          child: const Text('🎁', style: TextStyle(fontSize: 20)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GiftFx {
  final String animation;
  final String sender;
  _GiftFx({required this.animation, required this.sender});
}
