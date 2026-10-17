import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/app_state.dart';
import '../widgets/gifts.dart';

/// Verification purchase screen — three tiers with subscription periods.
/// Personal (blue, $15/mo) | Business (pink, $65/mo) | Company (gold, $100/mo)
/// Periods: 3, 6, 12 months. 12mo = 10x monthly (2 months free).
class VerificationScreen extends StatefulWidget {
  const VerificationScreen({super.key});

  @override
  State<VerificationScreen> createState() => _VerificationScreenState();
}

class _VerificationScreenState extends State<VerificationScreen> {
  Map<String, dynamic>? _pricing;
  String _selectedTier = 'personal';
  int _selectedMonths = 12;
  bool _loading = true;
  bool _buying = false;
  String? _error;
  String _email = '';

  @override
  void initState() {
    super.initState();
    _loadPricing();
  }

  Future<void> _loadPricing() async {
    try {
      final api = context.read<AppState>().api;
      final r = await api.get('/api/verification/pricing');
      if (mounted) {
        setState(() {
          _pricing = (r['tiers'] as Map?)?.cast<String, dynamic>();
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() { _loading = false; _error = 'Could not load pricing.'; });
    }
  }

  double _priceFor(String tier, int months) {
    final t = _pricing?[tier];
    if (t == null) return 0;
    final periods = (t['periods'] as Map?)?.cast<String, dynamic>() ?? {};
    return (periods['$months'] as num?)?.toDouble() ?? 0;
  }

  Future<void> _buy() async {
    if (_email.trim().isEmpty || !_email.contains('@')) {
      setState(() => _error = 'Enter a valid email for the payment receipt.');
      return;
    }
    setState(() { _buying = true; _error = null; });
    try {
      final api = context.read<AppState>().api;
      final r = await api.post('/api/verification/purchase', {
        'type': _selectedTier,
        'months': _selectedMonths,
        'email': _email.trim(),
      });
      final url = r['checkoutUrl'] as String?;
      if (url == null || !url.startsWith('http')) {
        throw Exception('No checkout URL returned.');
      }
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      } else {
        throw Exception('Could not open checkout.');
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Purchase failed: ${e.toString().replaceFirst('Exception: ', '')}');
    } finally {
      if (mounted) setState(() => _buying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = theme.textTheme.bodyLarge?.color ?? Colors.white;
    final sub = theme.textTheme.bodySmall?.color ?? Colors.grey;

    return Scaffold(
      appBar: AppBar(title: const Text('Get Verified')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  'Choose your verification tier',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: fg),
                ),
                const SizedBox(height: 4),
                Text(
                  'Verified accounts get priority in search, a badge on their profile, and creator trust.',
                  style: TextStyle(fontSize: 13, color: sub),
                ),
                const SizedBox(height: 16),
                // Tier cards
                for (final tier in ['personal', 'business', 'company'])
                  _tierCard(tier, fg, sub, theme),
                const SizedBox(height: 16),
                // Period selector
                Text('Subscription period', style: TextStyle(fontWeight: FontWeight.w700, color: fg)),
                const SizedBox(height: 8),
                Row(
                  children: [3, 6, 12].map((m) {
                    final selected = _selectedMonths == m;
                    final price = _priceFor(_selectedTier, m);
                    return Expanded(
                      child: GestureDetector(
                        onTap: () => setState(() => _selectedMonths = m),
                        child: Container(
                          margin: const EdgeInsets.only(right: 8),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: selected ? const Color(0xFFFFC107) : theme.cardColor,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: selected ? const Color(0xFFFFC107) : theme.dividerColor,
                            ),
                          ),
                          child: Column(
                            children: [
                              Text('$m months',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: selected ? Colors.black : fg,
                                  )),
                              Text('\$${price.toStringAsFixed(price % 1 == 0 ? 0 : 2)}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: selected ? Colors.black87 : sub,
                                  )),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 16),
                // Email
                TextField(
                  onChanged: (v) => _email = v,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    labelText: 'Email for receipt',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                const SizedBox(height: 16),
                if (_error != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.error.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                  ),
                // Buy button
                SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _buying ? null : _buy,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFFC107),
                      foregroundColor: Theme.of(context).colorScheme.onPrimary,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: _buying
                        ? const SizedBox(
                            height: 22, width: 22,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                          )
                        : Text(
                            'Buy ${_tierLabel(_selectedTier)} — \$${_priceFor(_selectedTier, _selectedMonths).toStringAsFixed(2)}',
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                          ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Subscription auto-renews. Cancel anytime from Settings.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: sub),
                ),
              ],
            ),
    );
  }

  String _tierLabel(String tier) {
    switch (tier) {
      case 'business': return 'Business';
      case 'company': return 'Company';
      default: return 'Personal';
    }
  }

  Widget _tierCard(String tier, Color fg, Color sub, ThemeData theme) {
    final selected = _selectedTier == tier;
    final t = _pricing?[tier];
    final monthly = (t?['monthly_usd'] as num?)?.toDouble() ?? 0;
    return GestureDetector(
      onTap: () => setState(() => _selectedTier = tier),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? const Color(0xFFFFC107) : theme.dividerColor,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            VerifiedBadge(size: 32, type: tier),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_tierLabel(tier),
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: fg)),
                  Text(_tierDescription(tier),
                      style: TextStyle(fontSize: 12, color: sub)),
                ],
              ),
            ),
            Text('\$$monthly/mo',
                style: TextStyle(fontWeight: FontWeight.w700, color: fg)),
          ],
        ),
      ),
    );
  }

  String _tierDescription(String tier) {
    switch (tier) {
      case 'business':
        return 'For brands & creators. Pink badge, priority support.';
      case 'company':
        return 'For companies. Gold badge, top search placement.';
      default:
        return 'For individuals. Blue badge, verified identity.';
    }
  }
}
