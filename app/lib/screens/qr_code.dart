import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../state/app_state.dart';

/// Profile QR code — tap background to change style.
class QrCodeScreen extends StatefulWidget {
  final String handle;
  final String displayName;
  final String avatarUrl;
  const QrCodeScreen({super.key, required this.handle, required this.displayName, required this.avatarUrl});

  @override
  State<QrCodeScreen> createState() => _QrCodeScreenState();
}

class _QrCodeScreenState extends State<QrCodeScreen> {
  int _style = 0;
  final _styles = [
    {'bg': Colors.white, 'fg': Colors.black},
    {'bg': Colors.black, 'fg': Colors.white},
    {'bg': Color(0xFFFE2C55), 'fg': Colors.white},
    {'bg': Color(0xFFD4AF37), 'fg': Colors.black},
  ];

  String get _link => 'https://user.novamail.store/${widget.handle}';

  @override
  Widget build(BuildContext context) {
    final style = _styles[_style];
    return Scaffold(
      appBar: AppBar(title: const Text('My QR Code')),
      body: GestureDetector(
        onTap: () => setState(() => _style = (_style + 1) % _styles.length),
        child: Container(
          width: double.infinity,
          color: style['bg'] as Color,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircleAvatar(
                radius: 36,
                backgroundImage: widget.avatarUrl.isNotEmpty ? NetworkImage(widget.avatarUrl) : null,
                child: widget.avatarUrl.isEmpty
                    ? Text(widget.handle.isNotEmpty ? widget.handle[0].toUpperCase() : '?',
                        style: const TextStyle(fontSize: 28))
                    : null,
              ),
              const SizedBox(height: 12),
              Text(widget.displayName,
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: style['fg'] as Color)),
              Text('@${widget.handle}',
                  style: TextStyle(fontSize: 14, color: (style['fg'] as Color).withOpacity(0.7))),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: QrImageView(
                  data: _link,
                  version: QrVersions.auto,
                  size: 220,
                  backgroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: 16),
              Text('Tap background to change style',
                  style: TextStyle(fontSize: 12, color: (style['fg'] as Color).withOpacity(0.6))),
              const SizedBox(height: 32),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ElevatedButton.icon(
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copy link'),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: _link));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied')));
                      }
                    },
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.share, size: 18),
                    label: const Text('Share link'),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: _link));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link ready to share')));
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
