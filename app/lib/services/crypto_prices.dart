import 'dart:convert';
import 'package:http/http.dart' as http;

/// Real-time crypto prices via CoinGecko free API.
class CryptoPrices {
  static double? _btcUsd;
  static double? _ethUsd;
  static DateTime _fetchedAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Get BTC and ETH prices in USD. Cached for 5 minutes.
  static Future<Map<String, double>> getPrices() async {
    // 5-minute cache
    if (_btcUsd != null && _ethUsd != null &&
        DateTime.now().difference(_fetchedAt).inMinutes < 5) {
      return {'BTC': _btcUsd!, 'ETH': _ethUsd!};
    }

    try {
      final resp = await http.get(
        Uri.parse('https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum&vs_currencies=usd'),
      ).timeout(const Duration(seconds: 10));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        _btcUsd = (data['bitcoin']?['usd'] as num?)?.toDouble();
        _ethUsd = (data['ethereum']?['usd'] as num?)?.toDouble();
        if (_btcUsd != null && _ethUsd != null) {
          _fetchedAt = DateTime.now();
          return {'BTC': _btcUsd!, 'ETH': _ethUsd!};
        }
      }
    } catch (_) {}

    // Fallback to last known or reasonable defaults
    return {
      'BTC': _btcUsd ?? 95000.0,
      'ETH': _ethUsd ?? 3500.0,
    };
  }

  /// Get USDT price (always ~$1).
  static double get usdtUsd => 1.0;
}
