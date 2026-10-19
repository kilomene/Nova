import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// In-app secure browser for checkout (Flutterwave).
/// Uses Chrome Custom Tabs / in-app WebView — never leaves Nova.
class CheckoutBrowser {
  /// Open [url] in the in-app browser. Returns true if opened.
  static Future<bool> open(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    try {
      // In-app WebView (Chrome Custom Tabs on Android).
      // This keeps the user inside Nova — no external browser.
      final opened = await launchUrl(
        uri,
        mode: LaunchMode.inAppWebView,
        webViewConfiguration: const WebViewConfiguration(
          enableJavaScript: true,
          enableDomStorage: true,
        ),
      );
      if (!opened && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open checkout')),
        );
      }
      return opened;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Checkout failed: $e')),
        );
      }
      return false;
    }
  }
}
