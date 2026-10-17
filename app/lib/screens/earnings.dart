import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_client.dart';
import '../state/app_state.dart';

/// Creator earnings wallet: gift revenue lands here (platform cut applied).
/// Withdraw to a bank account via Flutterwave transfers (NG, GH, KE, US, GB...).
/// Separate from the Nova Coin purchase wallet, which is spend-only.
///
/// Fully theme-aware: follows the app Light/Dark/System theme.
class EarningsScreen extends StatefulWidget {
  const EarningsScreen({super.key});

  @override
  State<EarningsScreen> createState() => _EarningsScreenState();
}

const _payoutCountries = <Map<String, String>>[
  {'code': 'NG', 'name': 'Nigeria', 'flag': '🇳🇬'},
  {'code': 'GH', 'name': 'Ghana', 'flag': '🇬🇭'},
  {'code': 'KE', 'name': 'Kenya', 'flag': '🇰🇪'},
  {'code': 'UG', 'name': 'Uganda', 'flag': '🇺🇬'},
  {'code': 'ZA', 'name': 'South Africa', 'flag': '🇿🇦'},
  {'code': 'US', 'name': 'United States', 'flag': '🇺🇸'},
  {'code': 'GB', 'name': 'United Kingdom', 'flag': '🇬🇧'},
];

/// Destination currency per payout country (matches backend).
const _currencyByCountry = <String, String>{
  'NG': 'NGN',
  'GH': 'GHS',
  'KE': 'KES',
  'UG': 'UGX',
  'ZA': 'ZAR',
  'US': 'USD',
  'GB': 'GBP',
};

class _EarningsScreenState extends State<EarningsScreen> {
  List<Map<String, dynamic>> _ledger = [];
  List<Map<String, dynamic>> _payouts = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final state = context.read<AppState>();
    await state.refreshEarnings();
    final l = await state.earningsLedger();
    final p = await state.earningsPayouts();
    if (mounted) {
      setState(() {
        _ledger = l;
        _payouts = p;
        _loading = false;
      });
    }
  }

  // ---------------- withdraw flow ----------------

  Future<void> _withdraw() async {
    final state = context.read<AppState>();
    if (state.isDemo) return;
    // Payouts are confirmed with the wallet PIN, so a wallet must exist.
    // Same gate as the in-DM crypto send.
    if (!state.wallet.hasWallet) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Create your wallet first (Wallet tab, KYC required) to withdraw earnings.')));
      return;
    }

    // Step 1: country.
    final country = await _pickCountry();
    if (country == null || !mounted) return;

    // Step 2: bank + account number.
    final bankDetails = await _pickBank(country);
    if (bankDetails == null || !mounted) return;
    final bank = bankDetails['bank'] as Map<String, dynamic>;
    final accountNumber = bankDetails['accountNumber'] as String;

    // Step 3: amount + PIN (PIN verified for real against the keystore).
    final confirm = await _confirmAmountAndPin(
      country: country,
      bankName: '${bank['name']}',
      accountNumber: accountNumber,
    );
    if (confirm == null || !mounted) return;

    try {
      final r = await state.sendPayout(
        amountCoins: confirm['amountCoins'] as int,
        country: country,
        bankCode: '${bank['code']}',
        bankName: '${bank['name']}',
        accountNumber: accountNumber,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Payout sent: \$${(r['amountUsd'] as num).toStringAsFixed(2)} (${r['status']})')));
      }
      _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content:
                Text('Payout failed: ${e is ApiException ? e.message : e}')));
      }
    }
  }

  Future<String?> _pickCountry() {
    final theme = Theme.of(context);
    return showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Select country',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: _payoutCountries
                    .map((c) => ListTile(
                          leading: Text(c['flag']!,
                              style: const TextStyle(fontSize: 24)),
                          title: Text(c['name']!),
                          trailing: Text(
                              '${c['code']} · ${_currencyByCountry[c['code']] ?? ''}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurface
                                      .withValues(alpha: 0.5))),
                          onTap: () =>
                              Navigator.of(context).pop(c['code']),
                        ))
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<Map<String, dynamic>?> _pickBank(String country) async {
    final state = context.read<AppState>();
    List<Map<String, dynamic>> banks = [];
    try {
      banks = await state.earningsBanks(country);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Could not load banks: ${e is ApiException ? e.message : e}')));
      }
      return null;
    }
    if (banks.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No banks available for this country right now.')));
      }
      return null;
    }
    if (!mounted) return null;

    final theme = Theme.of(context);
    Map<String, dynamic>? bank;
    final acctCtrl = TextEditingController();
    String? bankError;
    final picked = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setD) => AlertDialog(
          title: const Text('Bank details'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<Map<String, dynamic>>(
                  decoration:
                      const InputDecoration(labelText: 'Bank'),
                  isExpanded: true,
                  items: banks
                      .map((b) => DropdownMenuItem(
                            value: b,
                            child: Text('${b['name']}',
                                overflow: TextOverflow.ellipsis),
                          ))
                      .toList(),
                  onChanged: (v) => setD(() => bank = v),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: acctCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'Account number'),
                ),
                if (bankError != null) ...[
                  const SizedBox(height: 8),
                  Text(bankError!,
                      style: TextStyle(
                          color: theme.colorScheme.error, fontSize: 12)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary),
              onPressed: () {
                if (bank == null) {
                  setD(() => bankError = 'Select your bank.');
                  return;
                }
                if (acctCtrl.text.trim().length < 4) {
                  setD(() => bankError = 'Enter a valid account number.');
                  return;
                }
                Navigator.of(context).pop(true);
              },
              child: const Text('Continue',
                  style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ],
        ),
      ),
    );
    if (picked != true) return null;
    return {'bank': bank!, 'accountNumber': acctCtrl.text.trim()};
  }

  /// Amount entry + wallet PIN. The PIN is verified for real against the
  /// encrypted keystore before anything is submitted.
  Future<Map<String, dynamic>?> _confirmAmountAndPin({
    required String country,
    required String bankName,
    required String accountNumber,
  }) async {
    final state = context.read<AppState>();
    final theme = Theme.of(context);
    final amountCtrl = TextEditingController();
    final pinCtrl = TextEditingController();
    String? error;
    bool verifying = false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setD) => AlertDialog(
          title: const Text('Confirm withdrawal'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('To: $bankName • $accountNumber',
                    style: theme.textTheme.bodyMedium),
                Text(
                    'Available: ${state.earningsBalance} coins (≈ \$${state.earningsUsd.toStringAsFixed(2)})',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.6))),
                const SizedBox(height: 4),
                Text(
                    'Minimum 1,000 coins (\$10). 100 coins = \$1 USD. Paid out in ${_currencyByCountry[country] ?? ''}.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
                        fontSize: 11)),
                const SizedBox(height: 8),
                TextField(
                  controller: amountCtrl,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'Coins to withdraw'),
                  onChanged: (_) => setD(() {}),
                ),
                if (amountCtrl.text.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '≈ \$${((double.tryParse(amountCtrl.text.trim()) ?? 0) / 100).toStringAsFixed(2)} USD',
                      style: TextStyle(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                const SizedBox(height: 8),
                TextField(
                  controller: pinCtrl,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  decoration:
                      const InputDecoration(labelText: 'Wallet PIN'),
                  onChanged: (_) {
                    if (error != null) setD(() => error = null);
                  },
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!,
                      style: TextStyle(
                          color: theme.colorScheme.error, fontSize: 12)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed:
                    verifying ? null : () => Navigator.of(context).pop(false),
                child: const Text('Cancel')),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary),
              onPressed: verifying
                  ? null
                  : () async {
                      final coins =
                          int.tryParse(amountCtrl.text.trim()) ?? 0;
                      if (coins < 1000) {
                        setD(() => error = 'Minimum 1,000 coins (\$10).');
                        return;
                      }
                      if (coins > state.earningsBalance) {
                        setD(() => error = 'Insufficient balance.');
                        return;
                      }
                      if (pinCtrl.text.isEmpty) {
                        setD(() => error = 'Enter your wallet PIN.');
                        return;
                      }
                      setD(() {
                        verifying = true;
                        error = null;
                      });
                      final ok = await state.wallet
                          .verifyPin(pinCtrl.text, state.api);
                      if (!context.mounted) return;
                      if (!ok) {
                        setD(() {
                          verifying = false;
                          error = 'Incorrect PIN. Try again.';
                        });
                        return;
                      }
                      if (context.mounted) {
                        Navigator.of(context).pop(true);
                      }
                    },
              child: verifying
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Withdraw',
                      style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return null;
    return {'amountCoins': int.parse(amountCtrl.text.trim())};
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final gold = theme.colorScheme.primary;
    final onSurface = theme.colorScheme.onSurface;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Creator earnings'),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Balance hero.
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                    colors: [gold, gold.withValues(alpha: 0.65)]),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  Text('\$${state.earningsUsd.toStringAsFixed(2)}',
                      style: const TextStyle(
                          fontSize: 40,
                          fontWeight: FontWeight.w900,
                          color: Colors.black)),
                  Text('${state.earningsBalance} coins',
                      style: const TextStyle(color: Colors.black54)),
                  const SizedBox(height: 4),
                  Text(
                      'Lifetime earned: ${state.earningsLifetime} coins',
                      style: const TextStyle(
                          color: Colors.black45, fontSize: 12)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                    backgroundColor: gold,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                    padding: const EdgeInsets.symmetric(vertical: 14)),
                onPressed:
                    state.isDemo || _loading ? null : _withdraw,
                icon: const Icon(Icons.account_balance),
                label: const Text('Withdraw to bank',
                    style:
                        TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
              ),
            ),
            if (state.isDemo)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                    'Demo mode: connect the backend to withdraw.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: onSurface.withValues(alpha: 0.5)),
                    textAlign: TextAlign.center),
              ),
            if (!state.isDemo && !state.wallet.hasWallet)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                    'Withdrawals are confirmed with your wallet PIN — create your wallet in the Wallet tab first (KYC required).',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: onSurface.withValues(alpha: 0.5)),
                    textAlign: TextAlign.center),
              ),
            const SizedBox(height: 24),
            // Payout history.
            Text('Payout history',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (_payouts.isEmpty && !_loading)
              Text('No payouts yet.',
                  style: theme.textTheme.bodySmall?.copyWith(
                      color: onSurface.withValues(alpha: 0.5))),
            for (final p in _payouts)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: (p['status'] == 'processing' ||
                            p['status'] == 'completed')
                        ? Colors.green.withValues(alpha: 0.15)
                        : Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    (p['status'] == 'processing' ||
                            p['status'] == 'completed')
                        ? Icons.check_circle
                        : Icons.hourglass_empty,
                    color: (p['status'] == 'processing' ||
                            p['status'] == 'completed')
                        ? Colors.green
                        : Theme.of(context).colorScheme.primary,
                  ),
                ),
                title: Text(
                    '\$${(p['amount_usd'] as num).toStringAsFixed(2)} ${p['currency'] ?? ''}',
                    style: theme.textTheme.bodyLarge
                        ?.copyWith(fontWeight: FontWeight.bold)),
                subtitle: Text(
                    '${p['bank_name'] ?? ''} • ${p['account_number'] ?? ''} • ${p['status'] ?? ''}',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: onSurface.withValues(alpha: 0.6))),
                trailing: Text(_fmtTs(p['created_at']),
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: onSurface.withValues(alpha: 0.45), fontSize: 11)),
              ),
            const SizedBox(height: 16),
            // Earnings activity.
            Text('Earnings activity',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (_ledger.isEmpty && !_loading)
              Text('No earnings yet. Go live and receive gifts!',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: onSurface.withValues(alpha: 0.5))),
            for (final e in _ledger)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                    (e['delta'] as int) >= 0
                        ? Icons.arrow_downward
                        : Icons.arrow_upward,
                    color: (e['delta'] as int) >= 0
                        ? Colors.green
                        : theme.colorScheme.error),
                title: Text(
                    '${(e['delta'] as int) > 0 ? '+' : ''}${e['delta']} coins',
                    style: theme.textTheme.bodyMedium),
                subtitle: Text('${e['reason'] ?? ''}',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: onSurface.withValues(alpha: 0.6))),
                trailing: Text(_fmtTs(e['created_at']),
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: onSurface.withValues(alpha: 0.45), fontSize: 11)),
              ),
          ],
        ),
      ),
    );
  }

  String _fmtTs(dynamic ts) {
    if (ts == null) return '';
    final millis = (ts as num).toInt();
    // Backend now() = Date.now() → milliseconds.
    final dt =
        DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true).toLocal();
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}
