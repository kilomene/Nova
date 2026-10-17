import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models.dart';
import 'api_client.dart';

/// Nova Coin: in-app virtual currency (NOT crypto).
/// Bought with USD via Flutterwave (server-side charge); spent on LIVE
/// gifts and tips. Never touches the crypto wallet.
class CoinService extends ChangeNotifier {
  int balance = 0;
  List<CoinPackage> packages = CoinPackage.demoPackages();
  List<GiftItem> gifts = GiftItem.demoCatalog();

  static const _prefsBalance = 'nova_coin_balance_demo';

  Future<void> refresh(ApiClient api) async {
    if (api.isDemo) {
      final prefs = await SharedPreferences.getInstance();
      balance = prefs.getInt(_prefsBalance) ?? 0;
    } else {
      try {
        final r = await api.get('/api/coins/balance');
        balance = (r['balance'] ?? 0) as int;
        final p = await api.get('/api/coins/packages');
        packages = ((p['packages'] as List?) ?? []).map((e) => CoinPackage.fromJson(e as Map<String, dynamic>)).toList();
        final g = await api.get('/api/gifts/catalog');
        gifts = ((g['gifts'] as List?) ?? []).map((e) => GiftItem.fromJson(e as Map<String, dynamic>)).toList();
      } catch (_) {
        // keep last known; cloud errors shouldn't zero the UI
      }
    }
    notifyListeners();
  }

  /// Start a Flutterwave checkout for a coin package.
  /// Returns true if a checkout page was opened.
  ///
  /// The checkout link is extracted defensively: the backend currently
  /// returns { flutterwave: <raw Flutterwave charge response>, package },
  /// and the raw response nests the link at flutterwave.data.link — but
  /// several other shapes (link / checkoutUrl / checkout_url at the top
  /// level, or directly under flutterwave) are accepted too, so a backend
  /// response-format change doesn't surface as "checkout unavailable".
  Future<bool> buyPackage(ApiClient api, CoinPackage pkg, String email) async {
    if (api.isDemo) {
      // Labeled demo simulation: no real payment.
      final prefs = await SharedPreferences.getInstance();
      balance += pkg.coins;
      await prefs.setInt(_prefsBalance, balance);
      notifyListeners();
      return true;
    }
    final cleanEmail = email.trim();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(cleanEmail)) {
      throw ApiException(400, 'invalid_email');
    }
    final r = await api.post('/api/coins/buy', {'packageId': pkg.id, 'email': cleanEmail});
    final link = _extractCheckoutLink(r);
    if (link == null) throw ApiException(502, 'checkout_unavailable');
    final uri = Uri.parse(link);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return true;
    }
    throw ApiException(502, 'checkout_unavailable');
  }

  /// Hunt for a checkout URL across the known backend response shapes.
  static String? _extractCheckoutLink(Map<String, dynamic> r) {
    const keys = ['link', 'checkoutUrl', 'checkout_url', 'paymentLink', 'payment_link', 'url'];
    final fw = r['flutterwave'];
    if (fw is Map) {
      final data = fw['data'];
      if (data is Map) {
        for (final k in keys) {
          final v = data[k];
          if (v is String && v.startsWith('http')) return v;
        }
      }
      for (final k in keys) {
        final v = fw[k];
        if (v is String && v.startsWith('http')) return v;
      }
    }
    for (final k in keys) {
      final v = r[k];
      if (v is String && v.startsWith('http')) return v;
    }
    return null;
  }

  /// Send a gift: deducts Nova Coin, credits the creator. Works in demo
  /// against the local balance (clearly labeled in UI).
  Future<void> sendGift(
    ApiClient api, {
    required String recipientUid,
    required String giftId,
    String liveSessionId = '',
  }) async {
    final gift = gifts.firstWhere((g) => g.id == giftId, orElse: () => throw ApiException(404, 'gift_not_found'));
    if (api.isDemo) {
      if (balance < gift.coinPrice) throw ApiException(402, 'insufficient_coins');
      final prefs = await SharedPreferences.getInstance();
      balance -= gift.coinPrice;
      await prefs.setInt(_prefsBalance, balance);
      notifyListeners();
      return;
    }
    await api.post('/api/gifts/send', {
      'recipientUid': recipientUid,
      'giftId': giftId,
      'liveSessionId': liveSessionId,
    });
    await refresh(api);
  }
}
