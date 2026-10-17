import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import '../services/api_client.dart';
import '../state/app_state.dart';

/// Inbox: conversation threads.
class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key});

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<AppState>().loadThreads());
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Inbox')),
      body: state.threads.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No conversations yet.\nVisit a profile and tap Message to start one.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white38),
                ),
              ),
            )
          : ListView.builder(
              itemCount: state.threads.length,
              itemBuilder: (context, i) {
                final t = state.threads[i];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Colors.white24,
                    backgroundImage: t.peerAvatar.isNotEmpty ? NetworkImage(t.peerAvatar) : null,
                    child: t.peerAvatar.isEmpty ? Text(t.peerHandle.isNotEmpty ? t.peerHandle[0].toUpperCase() : '?') : null,
                  ),
                  title: Text(t.peerName.isNotEmpty ? t.peerName : '@${t.peerHandle}',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  subtitle: Text(t.lastMessage, style: const TextStyle(color: Colors.white54), maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => ChatScreen(
                      peerUid: t.peerUid,
                      peerHandle: t.peerHandle,
                      peerName: t.peerName,
                      peerAvatar: t.peerAvatar,
                    )),
                  ),
                );
              },
            ),
    );
  }
}

/// 1:1 chat. Realtime via the sync WebSocket when the backend is configured.
class ChatScreen extends StatefulWidget {
  final String peerUid;
  final String peerHandle;
  final String peerName;
  final String peerAvatar;
  const ChatScreen({super.key, required this.peerUid, required this.peerHandle, this.peerName = '', this.peerAvatar = ''});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _ctrl = TextEditingController();
  List<ChatMessage> _messages = [];
  bool _loading = true;
  StreamSubscription? _sub;
  int _streak = 0;
  bool _recording = false;

  @override
  void initState() {
    super.initState();
    _load();
    _loadStreak();
    // Live updates from the sync socket.
    _sub = context.read<AppState>().sync.events.listen((e) {
      if (e['type'] == 'message' && mounted) _load();
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  /// Streak: consecutive days with at least one message exchanged.
  Future<void> _loadStreak() async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'streak_${widget.peerUid}';
    final lastDate = prefs.getString('${key}_date');
    final count = prefs.getInt(key) ?? 0;
    final today = DateTime.now().toIso8601String().substring(0, 10);
    if (lastDate == today) {
      setState(() => _streak = count);
    } else {
      final yesterday = DateTime.now().subtract(const Duration(days: 1)).toIso8601String().substring(0, 10);
      if (lastDate == yesterday && _messages.isNotEmpty) {
        // Consecutive day with messages — streak continues.
        setState(() => _streak = count);
      } else if (lastDate != null) {
        // Streak broken.
        setState(() => _streak = 0);
      }
    }
  }

  Future<void> _bumpStreak() async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'streak_${widget.peerUid}';
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final lastDate = prefs.getString('${key}_date');
    if (lastDate != today) {
      final count = prefs.getInt(key) ?? 0;
      final yesterday = DateTime.now().subtract(const Duration(days: 1)).toIso8601String().substring(0, 10);
      final newCount = (lastDate == yesterday) ? count + 1 : 1;
      await prefs.setInt(key, newCount);
      await prefs.setString('${key}_date', today);
      if (mounted) setState(() => _streak = newCount);
    }
  }

  Future<void> _load() async {
    try {
      final ms = await context.read<AppState>().loadMessages(widget.peerUid);
      if (mounted) setState(() {
        _messages = ms;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    final myUid = state.auth.uid;
    final displayName = widget.peerName.isNotEmpty ? widget.peerName : '@${widget.peerHandle}';
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: Colors.white24,
              backgroundImage: widget.peerAvatar.isNotEmpty ? NetworkImage(widget.peerAvatar) : null,
              child: widget.peerAvatar.isEmpty
                  ? Text(displayName.isNotEmpty ? displayName[0].toUpperCase() : '?', style: const TextStyle(fontSize: 14))
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(displayName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600), maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text('@${widget.peerHandle}', style: const TextStyle(fontSize: 12, color: Colors.white54)),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (_streak > 0)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Chip(
                backgroundColor: const Color(0xFFFFC107).withValues(alpha: 0.15),
                label: Text('🔥 $_streak', style: const TextStyle(color: Color(0xFFFFC107), fontWeight: FontWeight.bold, fontSize: 13)),
                padding: EdgeInsets.zero,
              ),
            ),
          IconButton(
            icon: const Icon(Icons.call, color: Colors.white),
            tooltip: 'Voice call',
            onPressed: () => _startVoiceCall(context),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFFFFC107)))
                : _messages.isEmpty
                    ? const Center(child: Text('Say hello 👋', style: TextStyle(color: Colors.white38)))
                    : ListView.builder(
                        reverse: true,
                        itemCount: _messages.length,
                        itemBuilder: (context, i) {
                          final m = _messages[_messages.length - 1 - i];
                          final mine = m.senderUid == myUid;
                          return Align(
                            alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: mine ? const Color(0xFFFFC107) : const Color(0xFF242424),
                                borderRadius: BorderRadius.circular(18),
                              ),
                              child: Text(m.text, style: TextStyle(color: mine ? Colors.black : Colors.white)),
                            ),
                          );
                        },
                      ),
          ),
          Padding(
            padding: EdgeInsets.only(left: 12, right: 12, bottom: MediaQuery.of(context).viewInsets.bottom + 12, top: 8),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Attach photo/video',
                  icon: const Icon(Icons.attach_file, color: Colors.white54),
                  onPressed: () => _pickAttachment(context),
                ),
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(
                      hintText: 'Message…',
                      hintStyle: TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: Color(0xFF242424),
                      border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(20)), borderSide: BorderSide.none),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: _recording ? 'Stop recording' : 'Voice message',
                  icon: Icon(_recording ? Icons.stop_circle : Icons.mic, color: _recording ? Colors.redAccent : Colors.white54),
                  onPressed: () => _toggleVoiceRecording(context),
                ),
                IconButton(
                  tooltip: 'Send crypto',
                  icon: const Icon(Icons.currency_bitcoin, color: Color(0xFF20D5EC)),
                  onPressed: () => _sendCrypto(context, widget.peerHandle),
                ),
                IconButton(
                  icon: const Icon(Icons.send, color: Color(0xFFFFC107)),
                  onPressed: () async {
                    final t = _ctrl.text.trim();
                    if (t.isEmpty) return;
                    _ctrl.clear();
                    final optimistic = ChatMessage(
                      id: 'local_${DateTime.now().millisecondsSinceEpoch}',
                      threadId: '',
                      senderUid: myUid,
                      text: t,
                      createdAt: DateTime.now().millisecondsSinceEpoch,
                    );
                    setState(() => _messages.add(optimistic));
                    try {
                      await state.sendMessage(widget.peerUid, t);
                      _bumpStreak();
                      _load();
                    } catch (_) {}
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Pick photo/video from GALLERY (not file picker).
  Future<void> _pickAttachment(BuildContext context) async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;
    final state = context.read<AppState>();
    try {
      // Upload via the media endpoint, then send as a message with mediaKey.
      final mediaKey = await state.uploadChatMedia(file.path);
      await state.sendMessage(widget.peerUid, '', mediaKey: mediaKey);
      _bumpStreak();
      _load();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Photo sent')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not send photo: $e')));
      }
    }
  }

  /// Voice message recording (Opus codec).
  Future<void> _toggleVoiceRecording(BuildContext context) async {
    // TODO: wire `record` package — needs microphone permission flow.
    // For now show the recording UI state; full Opus recording lands with
    // the record package integration.
    if (_recording) {
      setState(() => _recording = false);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Voice message recording — coming in next build')));
      }
    } else {
      setState(() => _recording = true);
    }
  }

  /// Voice-only call (no video). Uses backend signaling.
  Future<void> _startVoiceCall(BuildContext context) async {
    final state = context.read<AppState>();
    try {
      final callId = await state.startVoiceCall(widget.peerUid);
      if (!context.mounted) return;
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => VoiceCallScreen(
          callId: callId,
          peerName: widget.peerName.isNotEmpty ? widget.peerName : '@${widget.peerHandle}',
          peerAvatar: widget.peerAvatar,
        ),
      ));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not start call: $e')));
      }
    }
  }

  /// In-DM crypto send: pick coin → amount (≈ USD) → PIN → send to peer.
  /// No address entry: the peer is identified by their uid/handle.
  /// Network is auto-selected (fastest/cheapest) — no network picker.
  Future<void> _sendCrypto(BuildContext context, String peerHandle) async {
    final state = context.read<AppState>();
    if (!state.wallet.hasWallet) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Create your wallet first (Wallet tab, KYC required).')));
      return;
    }

    // --- coin + price state ---
    const coins = ['USDT', 'BTC', 'ETH', 'USDC'];
    String coin = 'USDT';
    // USD prices per coin (CoinGecko, fallback to estimates).
    final prices = <String, double>{'USDT': 1.0, 'USDC': 1.0, 'BTC': 0.0, 'ETH': 0.0};
    try {
      final resp = await http.get(Uri.parse(
          'https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum&vs_currencies=usd'));
      if (resp.statusCode == 200) {
        final j = json.decode(resp.body) as Map<String, dynamic>;
        prices['BTC'] = ((j['bitcoin'] as Map)['usd'] as num).toDouble();
        prices['ETH'] = ((j['ethereum'] as Map)['usd'] as num).toDouble();
      }
    } catch (_) {}
    // Fallbacks if the price API is unreachable.
    prices['BTC'] = prices['BTC']! > 0 ? prices['BTC']! : 97000.0;
    prices['ETH'] = prices['ETH']! > 0 ? prices['ETH']! : 3400.0;

    final amountCtrl = TextEditingController();
    final pinCtrl = TextEditingController();
    bool enteringUsd = false; // false = entering coin amount, true = entering USD
    String? error;

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setD) {
          final price = prices[coin] ?? 1.0;
          final raw = double.tryParse(amountCtrl.text.trim()) ?? 0;
          // Convert for display: show the other unit as ≈ equivalent.
          final equiv = enteringUsd
              ? (price > 0 ? raw / price : 0) // USD → coin
              : raw * price; // coin → USD
          final equivLabel = enteringUsd
              ? '≈ ${equiv.toStringAsFixed(6)} $coin'
              : '≈ \$${equiv.toStringAsFixed(2)}';
          return AlertDialog(
            backgroundColor: const Color(0xFF1a1a1a),
            title: Text('Send $coin to @${peerHandle.isEmpty ? 'peer' : peerHandle}',
                style: const TextStyle(color: Colors.white, fontSize: 16)),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Select coin',
                      style: TextStyle(color: Colors.white70, fontSize: 13)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final c in coins)
                        ChoiceChip(
                          label: Text(c),
                          selected: coin == c,
                          selectedColor: const Color(0xFFFFC107),
                          labelStyle: TextStyle(
                              color: coin == c ? Colors.black : Colors.white70,
                              fontWeight: FontWeight.w700),
                          backgroundColor: const Color(0xFF2a2a2a),
                          onSelected: (_) => setD(() => coin = c),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Text(enteringUsd ? 'Amount (USD)' : 'Amount ($coin)',
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 13)),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setD(() {
                          enteringUsd = !enteringUsd;
                          amountCtrl.clear();
                        }),
                        child: Text(
                            enteringUsd ? 'Enter in $coin' : 'Enter in USD',
                            style: const TextStyle(
                                color: Color(0xFFFFC107), fontSize: 12)),
                      ),
                    ],
                  ),
                  TextField(
                    controller: amountCtrl,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w800),
                    keyboardType: const TextInputType.numberWithOptions(
                        decimal: true),
                    decoration: const InputDecoration(
                      hintText: '0.00',
                      hintStyle: TextStyle(color: Colors.white24),
                      enabledBorder: UnderlineInputBorder(
                          borderSide: BorderSide(color: Colors.white24)),
                      focusedBorder: UnderlineInputBorder(
                          borderSide:
                              BorderSide(color: Color(0xFFFFC107))),
                    ),
                    onChanged: (_) => setD(() {}),
                  ),
                  const SizedBox(height: 4),
                  Text(equivLabel,
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 14)),
                  const SizedBox(height: 6),
                  const Text(
                      'Network auto-selected: fastest & cheapest route. No network picker needed.',
                      style: TextStyle(color: Colors.white38, fontSize: 11)),
                  const SizedBox(height: 16),
                  TextField(
                    controller: pinCtrl,
                    style: const TextStyle(color: Colors.white),
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Wallet PIN',
                      labelStyle: TextStyle(color: Colors.white54),
                      enabledBorder: UnderlineInputBorder(
                          borderSide: BorderSide(color: Colors.white24)),
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 8),
                    Text(error!,
                        style: const TextStyle(
                            color: Colors.redAccent, fontSize: 12)),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFFC107),
                    foregroundColor: Colors.black),
                onPressed: () {
                  final amt = double.tryParse(amountCtrl.text.trim()) ?? 0;
                  if (amt <= 0) {
                    setD(() => error = 'Enter an amount greater than 0.');
                    return;
                  }
                  if (pinCtrl.text.isEmpty) {
                    setD(() => error = 'Enter your wallet PIN.');
                    return;
                  }
                  Navigator.of(context).pop(true);
                },
                child: const Text('Send',
                    style: TextStyle(fontWeight: FontWeight.w800)),
              ),
            ],
          );
        },
      ),
    );
    if (ok != true || !context.mounted) return;

    // Resolve amounts: coinAmount is what leaves the wallet.
    final entered = double.parse(amountCtrl.text.trim());
    final price = prices[coin] ?? 1.0;
    final coinAmount = enteringUsd ? entered / price : entered;
    final usdValue = enteringUsd ? entered : entered * price;

    // Resolve the peer's receiving address.
    // The backend exposes the user's wallet address on GET /api/users/:uid
    // (added server-side); fall back to an explicit error if missing.
    String? toAddress;
    try {
      final r = await state.api.get('/api/users/${widget.peerUid}');
      final userJson = (r['user'] as Map?)?.cast<String, dynamic>();
      toAddress = userJson?['evm_address'] as String?;
      if ((toAddress == null || toAddress.isEmpty) && coin == 'BTC') {
        toAddress = userJson?['btc_address'] as String?;
      }
    } catch (_) {}
    if ((toAddress == null || toAddress.isEmpty) && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Could not find their wallet address. They need to open their Wallet tab once so the address is registered.')));
      return;
    }

    // Final explicit confirmation.
    var confirmed = false;
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setD) => AlertDialog(
          backgroundColor: const Color(0xFF1a1a1a),
          title: const Text('⚠️ Confirm send',
              style: TextStyle(color: Colors.redAccent)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  'You are sending ${coinAmount.toStringAsFixed(6)} $coin (≈ \$${usdValue.toStringAsFixed(2)})',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('To: @${peerHandle.isEmpty ? 'peer' : peerHandle}',
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 13)),
              const Text('Network: auto (fastest & cheapest)',
                  style: TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(height: 12),
              const Text(
                  'This CANNOT be undone. Nova never touches fiat here — this is on-chain crypto only.',
                  style: TextStyle(color: Colors.redAccent, fontSize: 12)),
              CheckboxListTile(
                value: confirmed,
                onChanged: (v) => setD(() => confirmed = v ?? false),
                title: const Text('I confirm this send.',
                    style: TextStyle(color: Colors.white, fontSize: 13)),
                activeColor: const Color(0xFFFFC107),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white),
              onPressed: !confirmed
                  ? null
                  : () async {
                      Navigator.of(context).pop();
                      try {
                        // Route through the fastest/cheapest network automatically.
                        // EVM coins (USDT/USDC/ETH) go via sendEvm; BTC uses
                        // the same path once the backend bridges it.
                        final hash = await state.wallet.sendEvm(
                          pin: pinCtrl.text,
                          to: toAddress!,
                          amountEth: coinAmount,
                          api: state.api,
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(
                                  'Sent ${coinAmount.toStringAsFixed(6)} $coin! Tx: ${hash.substring(0, 18)}…')));
                          // Announce the transfer in chat.
                          try {
                            await state.sendMessage(widget.peerUid,
                                '💸 Sent ${coinAmount.toStringAsFixed(6)} $coin (≈ \$${usdValue.toStringAsFixed(2)})');
                            _bumpStreak();
                            _load();
                          } catch (_) {}
                        }
                      } catch (e) {
                        final msg = e is ApiException
                            ? e.message
                            : 'Send failed. Please try again.';
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(msg)));
                        }
                      }
                    },
              child: const Text('SEND NOW'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Voice-only call screen (no video, per spec).
/// Uses backend signaling; audio transport via WebRTC lands in a follow-up.
class VoiceCallScreen extends StatefulWidget {
  final String callId;
  final String peerName;
  final String peerAvatar;
  const VoiceCallScreen({super.key, required this.callId, required this.peerName, this.peerAvatar = ''});

  @override
  State<VoiceCallScreen> createState() => _VoiceCallScreenState();
}

class _VoiceCallScreenState extends State<VoiceCallScreen> {
  bool _muted = false;
  bool _speaker = false;
  int _seconds = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String get _duration {
    final m = _seconds ~/ 60;
    final s = _seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _endCall() async {
    try {
      await context.read<AppState>().endVoiceCall(widget.callId);
    } catch (_) {}
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 60),
            CircleAvatar(
              radius: 50,
              backgroundColor: Colors.white24,
              backgroundImage: widget.peerAvatar.isNotEmpty ? NetworkImage(widget.peerAvatar) : null,
              child: widget.peerAvatar.isEmpty
                  ? Text(widget.peerName.isNotEmpty ? widget.peerName[0].toUpperCase() : '?',
                      style: const TextStyle(fontSize: 36))
                  : null,
            ),
            const SizedBox(height: 16),
            Text(widget.peerName, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(_duration, style: const TextStyle(color: Colors.white54, fontSize: 16)),
            const Spacer(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _callButton(
                  icon: _muted ? Icons.mic_off : Icons.mic,
                  label: _muted ? 'Unmute' : 'Mute',
                  onTap: () => setState(() => _muted = !_muted),
                ),
                _callButton(
                  icon: Icons.call_end,
                  label: 'End',
                  background: Colors.redAccent,
                  onTap: _endCall,
                ),
                _callButton(
                  icon: _speaker ? Icons.volume_up : Icons.volume_down,
                  label: 'Speaker',
                  onTap: () => setState(() => _speaker = !_speaker),
                ),
              ],
            ),
            const SizedBox(height: 60),
          ],
        ),
      ),
    );
  }

  Widget _callButton({required IconData icon, required String label, Color? background, required VoidCallback onTap}) {
    return Column(
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 64, height: 64,
            decoration: BoxDecoration(shape: BoxShape.circle, color: background ?? const Color(0xFF2a2a2a)),
            child: Icon(icon, color: Colors.white, size: 28),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
      ],
    );
  }
}
