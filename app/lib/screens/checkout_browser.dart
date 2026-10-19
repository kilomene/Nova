import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// In-app browser for secure checkout (Flutterwave).
/// Keeps the user inside Nova instead of opening the phone browser.
class CheckoutBrowserScreen extends StatefulWidget {
  final String url;
  final String title;
  const CheckoutBrowserScreen({
    super.key,
    required this.url,
    this.title = 'Secure Checkout',
  });

  @override
  State<CheckoutBrowserScreen> createState() => _CheckoutBrowserScreenState();
}

class _CheckoutBrowserScreenState extends State<CheckoutBrowserScreen> {
  late final WebViewController _controller;
  bool _loading = true;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => _progress = p / 100);
          },
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (url) {
            if (mounted) setState(() => _loading = false);
            // Detect successful payment return.
            if (url.contains('success') || url.contains('completed')) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Payment completed')),
                );
              }
            }
          },
          onWebResourceError: (err) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Error: ${err.description}')),
              );
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.lock, size: 16, color: Colors.green),
            const SizedBox(width: 6),
            Text(widget.title,
                style: const TextStyle(fontSize: 16)),
          ],
        ),
        backgroundColor: isDark ? Colors.black : Colors.white,
        foregroundColor: isDark ? Colors.white : Colors.black87,
        bottom: _loading
            ? PreferredSize(
                preferredSize: const Size.fromHeight(3),
                child: LinearProgressIndicator(
                  value: _progress > 0 ? _progress : null,
                  backgroundColor: Colors.transparent,
                ),
              )
            : null,
      ),
      body: WebViewWidget(controller: _controller),
    );
  }
}
