import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../services/api_client.dart';
import '../state/app_state.dart';

/// In-app customer support desk: help center + tickets.
/// The agent (me) answers via the admin console (/api/admin/support).
class SupportScreen extends StatefulWidget {
  const SupportScreen({super.key});

  @override
  State<SupportScreen> createState() => _SupportScreenState();
}

class _SupportScreenState extends State<SupportScreen> {
  List<SupportTicket> _tickets = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final t = await context.read<AppState>().supportTickets();
    if (mounted) setState(() { _tickets = t; _loading = false; });
  }

  Future<void> _new() async {
    final subject = TextEditingController();
    final message = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1a1a1a),
        title: const Text('New support ticket', style: TextStyle(color: Colors.white)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: subject, style: const TextStyle(color: Colors.white), decoration: const InputDecoration(labelText: 'Subject', labelStyle: TextStyle(color: Colors.white54))),
            TextField(controller: message, style: const TextStyle(color: Colors.white), maxLines: 4, decoration: const InputDecoration(labelText: 'Describe the issue', labelStyle: TextStyle(color: Colors.white54))),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Submit'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await context.read<AppState>().createSupportTicket(subject: subject.text.trim(), message: message.text.trim());
      _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: ${e is ApiException ? e.message : e}')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Support')),
      floatingActionButton: state.isDemo
          ? null
          : FloatingActionButton(
              backgroundColor: const Color(0xFFFFC107),
              foregroundColor: Colors.black,
              onPressed: _new,
              child: const Icon(Icons.add),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _tickets.isEmpty
              ? const Center(child: Text('No tickets yet.\nTap + to ask for help.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white54)))
              : ListView.builder(
                  itemCount: _tickets.length,
                  itemBuilder: (context, i) {
                    final t = _tickets[i];
                    return ListTile(
                      leading: Icon(
                        t.status == 'open' ? Icons.mark_unread_chat_alt : Icons.mark_chat_read,
                        color: const Color(0xFFFFC107),
                      ),
                      title: Text(t.subject, style: const TextStyle(color: Colors.white)),
                      subtitle: Text(t.status, style: const TextStyle(color: Colors.white54, fontSize: 12)),
                      trailing: const Icon(Icons.chevron_right, color: Colors.white38),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TicketDetailScreen(ticket: t))).then((_) => _load()),
                    );
                  },
                ),
    );
  }
}

class TicketDetailScreen extends StatefulWidget {
  final SupportTicket ticket;
  const TicketDetailScreen({super.key, required this.ticket});

  @override
  State<TicketDetailScreen> createState() => _TicketDetailScreenState();
}

class _TicketDetailScreenState extends State<TicketDetailScreen> {
  List<SupportReply> _replies = [];
  final _ctrl = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await context.read<AppState>().supportTicketDetail(widget.ticket.id);
    if (mounted) {
      setState(() {
        _replies = (r['replies'] as List? ?? []).map((e) => SupportReply.fromJson((e as Map).cast<String, dynamic>())).toList();
      });
    }
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _busy = true);
    try {
      await context.read<AppState>().replySupportTicket(ticketId: widget.ticket.id, message: text);
      _ctrl.clear();
      _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: ${e is ApiException ? e.message : e}')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: Text(widget.ticket.subject, overflow: TextOverflow.ellipsis)),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _replies.length,
              itemBuilder: (context, i) {
                final r = _replies[i];
                final mine = r.author == 'user';
                return Align(
                  alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.all(12),
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
                    decoration: BoxDecoration(
                      color: mine ? const Color(0xFFFFC107) : const Color(0xFF1a1a1a),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!mine) const Text('Nova Support', style: TextStyle(color: Color(0xFF20D5EC), fontSize: 11, fontWeight: FontWeight.bold)),
                        Text(r.message, style: TextStyle(color: mine ? Colors.black : Colors.white)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: const InputDecoration(hintText: 'Write a reply…', hintStyle: TextStyle(color: Colors.white38)),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send, color: Color(0xFFFFC107)),
                  onPressed: _busy ? null : _send,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
