import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

class ApiException implements Exception {
  final int status;
  final String code;
  ApiException(this.status, this.code);

  @override
  String toString() => 'ApiException($status, $code)';

  /// Human-readable message for UI display. Never includes raw payloads.
  String get message {
    switch (code) {
      case 'kyc_required':
        return 'Complete KYC verification to unlock your wallet.';
      case 'insufficient_coins':
        return 'Not enough Nova Coins. Top up to continue.';
      case 'rate_limited':
        return 'Too many requests — please wait a moment.';
      case 'live_requires_1000_followers':
        return 'You need at least 1,000 followers to go live.';
      case 'follow_required_to_message':
        return 'Follow this user before messaging them.';
      case 'seller_verification_required':
        return 'Only verified sellers can list items. Apply in Settings → Sell on Nova.';
      case 'network_blocked':
        return 'This network is blocked (VPN/proxy/Tor detected). Disconnect to continue.';
      case 'account_suspended':
        return 'Your account is suspended. Check Settings → Strikes or contact support.';
      case 'account_banned':
        return 'Your account is banned. Contact support to appeal.';
      case 'spam_flagged_for_review':
        return 'Flagged as spam and sent for review. Slow down.';
      case 'device_restricted':
        return 'This device is restricted due to repeated violations.';
      case 'insufficient_earnings':
        return 'Not enough creator earnings for that payout.';
      case 'auth_not_configured':
        return 'Cloud backend not configured (demo mode).';
      default:
        return 'Something went wrong ($code).';
    }
  }
}

typedef TokenProvider = Future<String?> Function();

/// Thin HTTP wrapper. Adds the Firebase bearer token; throws ApiException
/// on 4xx/5xx with the server's stable error code (never raw internals).
class ApiClient {
  final String baseUrl;
  final TokenProvider tokenProvider;

  ApiClient({required this.baseUrl, required this.tokenProvider});

  bool get isDemo => baseUrl.isEmpty;

  Future<Map<String, dynamic>> get(String path, [Map<String, String>? query]) =>
      _send('GET', path, query: query);

  Future<Map<String, dynamic>> post(String path, [Map<String, dynamic>? body]) =>
      _send('POST', path, body: body);

  Future<Map<String, dynamic>> delete(String path) => _send('DELETE', path);

  /// Multipart file upload (video, KYC documents).
  Future<Map<String, dynamic>> upload(String path, String filePath, {String field = 'file'}) async {
    final token = await tokenProvider();
    final uri = Uri.parse('$baseUrl$path');
    final req = http.MultipartRequest('POST', uri);
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    req.files.add(await http.MultipartFile.fromPath(field, filePath,
        contentType: _guessContentType(filePath)));
    final streamed = await req.send();
    final resp = await http.Response.fromStream(streamed);
    return _decode(resp);
  }

  MediaType? _guessContentType(String p) {
    final ext = p.split('.').last.toLowerCase();
    switch (ext) {
      case 'mp4':
        return MediaType('video', 'mp4');
      case 'mov':
        return MediaType('video', 'quicktime');
      case 'jpg':
      case 'jpeg':
        return MediaType('image', 'jpeg');
      case 'png':
        return MediaType('image', 'png');
      case 'webp':
        return MediaType('image', 'webp');
      default:
        return null;
    }
  }

  Future<Map<String, dynamic>> _send(String method, String path,
      {Map<String, String>? query, Map<String, dynamic>? body}) async {
    if (isDemo) throw ApiException(501, 'auth_not_configured');
    final token = await tokenProvider();
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    final req = http.Request(method, uri);
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    http.Response resp;
    try {
      resp = await http.Response.fromStream(await req.send());
    } catch (_) {
      throw ApiException(0, 'network_error');
    }
    return _decode(resp);
  }

  Map<String, dynamic> _decode(http.Response resp) {
    dynamic decoded;
    try {
      decoded = resp.body.isEmpty ? {} : jsonDecode(resp.body);
    } catch (_) {
      decoded = {};
    }
    if (resp.statusCode >= 400) {
      final code = (decoded is Map && decoded['error'] is String) ? decoded['error'] as String : 'request_failed';
      throw ApiException(resp.statusCode, code);
    }
    return decoded is Map<String, dynamic> ? decoded : {'data': decoded};
  }
}
