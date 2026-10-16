import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
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
                  title: Text(t.peerHandle, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  subtitle: Text(t.lastMessage, style: const TextStyle(color: Colors.white54), maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => ChatScreen(peerUid: t.peerUid, peerHandle: t.peerHandle)),
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
  const ChatScreen({super.key, required this.peerUid, required this.peerHandle});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _ctrl = TextEditingController();
  List<ChatMessage> _messages = [];
  bool _loading = true;
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _load();
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
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: Text('@${widget.peerHandle}')),
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

  /// In-DM crypto send with a VERY explicit confirmation screen.
  /// The recipient's address must be shared in chat first (v1).
  Future<void> _sendCrypto(BuildContext context, String peerHandle) async {
    final state = context.read<AppState>();
    if (!state.wallet.hasWallet) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Create your wallet first (Wallet tab, KYC required).')));
      return;
    }
    final amount = TextEditingController();
    final to = TextEditingController();
    final pin = TextEditingController();
    final first = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a1a1a),
        title: const Text('Send crypto', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('To @${peerHandle.isEmpty ? 'peer' : peerHandle} — ask them for their wallet address in chat first.',
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(height: 8),
            TextField(controller: to, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'Recipient EVM address (0x…)', labelStyle: TextStyle(color: Colors.white54))),
            TextField(controller: amount, style: const TextStyle(color: Colors.white), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Amount (ETH, Sepolia testnet)', labelStyle: TextStyle(color: Colors.white54))),
            TextField(controller: pin, style: const TextStyle(color: Colors.white), obscureText: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Wallet PIN', labelStyle: TextStyle(color: Colors.white54))),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Review'),
          ),
        ],
      ),
    );
    if (first != true || !context.mounted) return;
    // Explicit confirmation screen: nothing is sent until this is confirmed.
    var confirmed = false;
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setD) => AlertDialog(
          backgroundColor: const Color(0xFF1a1a1a),
          title: const Text('⚠️ Confirm send', style: TextStyle(color: Colors.redAccent)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('You are sending ${amount.text.trim()} ETH', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text('To: ${to.text.trim()}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
              const Text('Network: Sepolia testnet', style: TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(height: 12),
              const Text('This CANNOT be undone. Sending to the wrong address loses the funds forever. Nova never touches fiat here — this is on-chain crypto only.',
                  style: TextStyle(color: Colors.redAccent, fontSize: 12)),
              CheckboxListTile(
                value: confirmed,
                onChanged: (v) => setD(() => confirmed = v ?? false),
                title: const Text('I checked the address character by character.', style: TextStyle(color: Colors.white, fontSize: 13)),
                activeColor: const Color(0xFFFFC107),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
              onPressed: !confirmed
                  ? null
                  : () async {
                      Navigator.of(context).pop();
                      try {
                        final hash = await state.wallet.sendEvm(
                          pin: pin.text,
                          to: to.text.trim(),
                          amountEth: double.parse(amount.text.trim()),
                          api: state.api,
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Sent! Tx: ${hash.substring(0, 18)}…')));
                        }
                      } catch (e) {
                        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Send failed: $e')));
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
