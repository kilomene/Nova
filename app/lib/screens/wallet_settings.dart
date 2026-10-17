import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

import '../services/wallet_service.dart';
import '../state/app_state.dart';

/// Display currency preference + conversion helpers.
class DisplayCurrency {
  static const prefsKey = 'nova_display_currency';
  static const defaultCode = 'USD';

  static const List<Map<String, String>> options = [
    {'code': 'USD', 'name': 'US Dollar', 'symbol': '\$'},
    {'code': 'EUR', 'name': 'Euro', 'symbol': '€'},
    {'code': 'GBP', 'name': 'British Pound', 'symbol': '£'},
    {'code': 'NGN', 'name': 'Nigerian Naira', 'symbol': '₦'},
    {'code': 'GHS', 'name': 'Ghanaian Cedi', 'symbol': '₵'},
    {'code': 'KES', 'name': 'Kenyan Shilling', 'symbol': 'KSh '},
  ];

  /// Fallback USD→currency rates (used when the forex API is unreachable).
  static const Map<String, double> fallbackRates = {
    'USD': 1.0,
    'EUR': 0.92,
    'GBP': 0.79,
    'NGN': 1550.0,
    'GHS': 16.5,
    'KES': 129.0,
  };

  static String symbolFor(String code) {
    for (final o in options) {
      if (o['code'] == code) return o['symbol'] ?? code;
    }
    return code;
  }

  static Future<String> load() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(prefsKey) ?? defaultCode;
    return options.any((o) => o['code'] == code) ? code : defaultCode;
  }

  static Future<void> save(String code) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, code);
  }

  /// Convert a USD amount to [code] using live forex rates with fallback.
  static Future<double> convertFromUsd(double usd, String code) async {
    if (code == 'USD') return usd;
    final rate = await _rate(code);
    return usd * rate;
  }

  static double _cachedRate = 0;
  static String _cachedFor = '';
  static DateTime _cachedAt = DateTime.fromMillisecondsSinceEpoch(0);

  static Future<double> _rate(String code) async {
    // 15-minute in-memory cache.
    if (_cachedFor == code &&
        DateTime.now().difference(_cachedAt).inMinutes < 15 &&
        _cachedRate > 0) {
      return _cachedRate;
    }
    try {
      final resp = await http
          .get(Uri.parse('https://open.er-api.com/v6/latest/USD'))
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final rates = data['rates'];
        if (rates is Map && rates[code] is num) {
          _cachedRate = (rates[code] as num).toDouble();
          _cachedFor = code;
          _cachedAt = DateTime.now();
          return _cachedRate;
        }
      }
    } catch (_) {
      // Fall through to fallback.
    }
    return fallbackRates[code] ?? 1.0;
  }

  static String format(double amount, String code) {
    final symbol = symbolFor(code);
    if (code == 'NGN' || code == 'KES' || code == 'GHS') {
      return '$symbol${amount.toStringAsFixed(0)}';
    }
    return '$symbol${amount.toStringAsFixed(2)}';
  }
}

/// Wallet settings: change PIN + display currency. Fully theme-aware.
class WalletSettingsScreen extends StatefulWidget {
  const WalletSettingsScreen({super.key});

  @override
  State<WalletSettingsScreen> createState() => _WalletSettingsScreenState();
}

class _WalletSettingsScreenState extends State<WalletSettingsScreen> {
  final _oldPinCtrl = TextEditingController();
  final _newPinCtrl = TextEditingController();
  final _confirmPinCtrl = TextEditingController();
  bool _changing = false;
  String? _pinError;
  String? _pinSuccess;
  String _currency = DisplayCurrency.defaultCode;
  bool _loadingCurrency = true;

  @override
  void initState() {
    super.initState();
    _loadCurrency();
  }

  Future<void> _loadCurrency() async {
    final code = await DisplayCurrency.load();
    if (mounted) {
      setState(() {
        _currency = code;
        _loadingCurrency = false;
      });
    }
  }

  @override
  void dispose() {
    _oldPinCtrl.dispose();
    _newPinCtrl.dispose();
    _confirmPinCtrl.dispose();
    super.dispose();
  }

  bool _isValidPin(String pin) {
    return pin.length >= 4 && pin.length <= 6 && RegExp(r'^\d+$').hasMatch(pin);
  }

  Future<void> _changePin() async {
    final oldPin = _oldPinCtrl.text.trim();
    final newPin = _newPinCtrl.text.trim();
    final confirm = _confirmPinCtrl.text.trim();

    setState(() {
      _pinError = null;
      _pinSuccess = null;
    });

    if (oldPin.isEmpty || newPin.isEmpty || confirm.isEmpty) {
      setState(() => _pinError = 'Please fill in all PIN fields.');
      return;
    }
    if (!_isValidPin(newPin)) {
      setState(() => _pinError = 'New PIN must be 4–6 digits.');
      return;
    }
    if (newPin != confirm) {
      setState(() => _pinError = 'New PINs do not match.');
      return;
    }
    if (oldPin == newPin) {
      setState(() => _pinError = 'New PIN must be different from old PIN.');
      return;
    }

    setState(() => _changing = true);
    try {
      final state = context.read<AppState>();
      await state.wallet.changePin(
        oldPin: oldPin,
        newPin: newPin,
        api: state.api,
      );
      if (!mounted) return;
      setState(() {
        _pinSuccess = 'PIN changed successfully.';
        _oldPinCtrl.clear();
        _newPinCtrl.clear();
        _confirmPinCtrl.clear();
      });
    } on WalletException catch (e) {
      if (!mounted) return;
      setState(() {
        _pinError = e.code == 'incorrect_pin'
            ? 'Old PIN is incorrect. Try again.'
            : 'Failed to change PIN (${e.code}).';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _pinError = 'Failed to change PIN. Try again.');
    } finally {
      if (mounted) setState(() => _changing = false);
    }
  }

  Future<void> _selectCurrency(String code) async {
    await DisplayCurrency.save(code);
    if (mounted) setState(() => _currency = code);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(
                'Display currency set to $code. Balances will show in $code.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gold = const Color(0xFFFFC107);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: theme.appBarTheme.backgroundColor,
        title: Text('Wallet Settings',
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w800)),
        iconTheme: theme.iconTheme,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ---------- Change PIN ----------
          Text('Change PIN',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          _pinField(
            theme: theme,
            controller: _oldPinCtrl,
            label: 'Old PIN',
          ),
          const SizedBox(height: 10),
          _pinField(
            theme: theme,
            controller: _newPinCtrl,
            label: 'New PIN (4–6 digits)',
          ),
          const SizedBox(height: 10),
          _pinField(
            theme: theme,
            controller: _confirmPinCtrl,
            label: 'Confirm new PIN',
          ),
          if (_pinError != null) ...[
            const SizedBox(height: 8),
            Text(_pinError!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 13)),
          ],
          if (_pinSuccess != null) ...[
            const SizedBox(height: 8),
            Text(_pinSuccess!,
                style: const TextStyle(color: Colors.green, fontSize: 13)),
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _changing ? null : _changePin,
              style: ElevatedButton.styleFrom(
                backgroundColor: gold,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: _changing
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.black))
                  : const Text('Change PIN',
                      style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),

          const SizedBox(height: 28),
          // ---------- Display currency ----------
          Text('Display Currency',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('Balances are shown in this currency.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.hintColor)),
          const SizedBox(height: 12),
          if (_loadingCurrency)
            const Center(child: CircularProgressIndicator())
          else
            ...DisplayCurrency.options.map((o) {
              final code = o['code']!;
              final selected = code == _currency;
              return Card(
                color: selected
                    ? gold.withValues(alpha: 0.15)
                    : theme.cardColor,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(
                    color: selected ? gold : theme.dividerColor,
                    width: selected ? 2 : 1,
                  ),
                ),
                child: ListTile(
                  leading: Text(o['symbol']!,
                      style: theme.textTheme.titleLarge),
                  title: Text(code,
                      style: theme.textTheme.bodyLarge
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  subtitle: Text(o['name']!,
                      style: theme.textTheme.bodySmall),
                  trailing: selected
                      ? Icon(Icons.check_circle, color: gold)
                      : null,
                  onTap: () => _selectCurrency(code),
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _pinField({
    required ThemeData theme,
    required TextEditingController controller,
    required String label,
  }) {
    return TextField(
      controller: controller,
      obscureText: true,
      keyboardType: TextInputType.number,
      maxLength: 6,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      style: theme.textTheme.bodyLarge,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: theme.hintColor),
        counterText: '',
        filled: true,
        fillColor: theme.inputDecorationTheme.fillColor,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}
