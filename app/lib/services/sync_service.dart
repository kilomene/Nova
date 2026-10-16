import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// Realtime sync via the Cloudflare Durable Object (SyncHub).
/// Best-effort: D1 is the source of truth; the socket is a live hint.
/// Reconnects with backoff; no-op in demo mode.
class SyncService {
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _events.stream;

  WebSocketChannel? _ch;
  Timer? _ping;
  Timer? _backoff;
  bool _wantConnection = false;
  String _wsBase = '';
  Future<String?> Function()? _token;

  void Function()? onGift; // UI hook for gift animations

  Future<void> connect({required String wsBase, required Future<String?> Function() tokenProvider}) async {
    _wsBase = wsBase;
    _token = tokenProvider;
    _wantConnection = true;
    await _open();
  }

  Future<void> _open() async {
    if (!_wantConnection) return;
    try {
      final token = await _token?.call();
      if (token == null) {
        _scheduleReconnect();
        return;
      }
      final uri = Uri.parse('$_wsBase/api/sync/ws?token=$token');
      _ch = WebSocketChannel.connect(uri);
      _ping?.cancel();
      _ping = Timer.periodic(const Duration(seconds: 25), (_) {
        try {
          _ch?.sink.add('ping');
        } catch (_) {}
      });
      _ch!.stream.listen(
        (raw) {
          if (raw == 'pong') return;
          try {
            final m = jsonDecode('$raw') as Map<String, dynamic>;
            _events.add(m);
            if (m['type'] == 'gift') onGift?.call();
          } catch (_) {}
        },
        onDone: _scheduleReconnect,
        onError: (_) => _scheduleReconnect(),
        cancelOnError: true,
      );
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    _ping?.cancel();
    _backoff?.cancel();
    if (!_wantConnection) return;
    _backoff = Timer(const Duration(seconds: 5), _open);
  }

  void disconnect() {
    _wantConnection = false;
    _ping?.cancel();
    _backoff?.cancel();
    try {
      _ch?.sink.close();
    } catch (_) {}
    _ch = null;
  }

  void dispose() {
    disconnect();
    _events.close();
  }
}
