import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_client.dart';
import '../state/app_state.dart';

/// Strict seller onboarding (TikTok-Shop-style). Buyers need NO verification;
/// sellers must pass government ID + country identity number + contact details.
class SellerOnboardingScreen extends StatefulWidget {
  const SellerOnboardingScreen({super.key});

  @override
  State<SellerOnboardingScreen> createState() => _SellerOnboardingScreenState();
}

class _SellerOnboardingScreenState extends State<SellerOnboardingScreen> {
  final _name = TextEditingController();
  final _street = TextEditingController();
  final _apt = TextEditingController();
  final _city = TextEditingController();
  final _state = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _zip = TextEditingController();
  String _country = 'US';
  final _idNumber = TextEditingController();
  String _idType = 'ssn';
  String? _idDocPath;
  bool _busy = false;

  static const _idTypes = {
    'ssn': 'US SSN',
    'nin': 'Nigeria NIN',
    'passport': 'Passport',
    'drivers_license': "Driver's license",
    'national_id': 'National ID',
    'other': 'Other government ID',
  };

  /// ISO 3166-1 alpha-2 country picker (code → display name).
  static const _countries = {
    'US': 'United States',
    'NG': 'Nigeria',
    'GB': 'United Kingdom',
    'GH': 'Ghana',
    'KE': 'Kenya',
    'UG': 'Uganda',
    'ZA': 'South Africa',
    'CA': 'Canada',
    'AU': 'Australia',
    'DE': 'Germany',
    'FR': 'France',
    'NL': 'Netherlands',
    'ES': 'Spain',
    'IT': 'Italy',
    'IE': 'Ireland',
    'SE': 'Sweden',
    'NO': 'Norway',
    'DK': 'Denmark',
    'FI': 'Finland',
    'CH': 'Switzerland',
    'BE': 'Belgium',
    'AT': 'Austria',
    'PT': 'Portugal',
    'PL': 'Poland',
    'IN': 'India',
    'PK': 'Pakistan',
    'BD': 'Bangladesh',
    'PH': 'Philippines',
    'ID': 'Indonesia',
    'MY': 'Malaysia',
    'SG': 'Singapore',
    'AE': 'United Arab Emirates',
    'SA': 'Saudi Arabia',
    'QA': 'Qatar',
    'KW': 'Kuwait',
    'EG': 'Egypt',
    'ET': 'Ethiopia',
    'TZ': 'Tanzania',
    'RW': 'Rwanda',
    'CM': 'Cameroon',
    'SN': 'Senegal',
    'CI': 'Ivory Coast',
    'ML': 'Mali',
    'BF': 'Burkina Faso',
    'NE': 'Niger',
    'TG': 'Togo',
    'BJ': 'Benin',
    'LR': 'Liberia',
    'SL': 'Sierra Leone',
    'GM': 'Gambia',
    'GW': 'Guinea-Bissau',
    'GN': 'Guinea',
    'MR': 'Mauritania',
    'BR': 'Brazil',
    'MX': 'Mexico',
    'AR': 'Argentina',
    'CO': 'Colombia',
    'CL': 'Chile',
    'PE': 'Peru',
    'JP': 'Japan',
    'KR': 'South Korea',
    'CN': 'China',
    'HK': 'Hong Kong',
    'TW': 'Taiwan',
    'TH': 'Thailand',
    'VN': 'Vietnam',
    'NZ': 'New Zealand',
  };

  Future<void> _pick() async {
    final r = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (r?.path != null) setState(() => _idDocPath = r!.path);
  }

  String _composeAddress() {
    final parts = <String>[
      _street.text.trim(),
      if (_apt.text.trim().isNotEmpty) _apt.text.trim(),
      _city.text.trim(),
      _state.text.trim(),
    ];
    return parts.join(', ');
  }

  Future<void> _submit() async {
    final state = context.read<AppState>();
    final address = _composeAddress();
    if (_name.text.trim().isEmpty ||
        _street.text.trim().isEmpty ||
        _city.text.trim().isEmpty ||
        _state.text.trim().isEmpty ||
        _phone.text.trim().isEmpty ||
        _email.text.trim().isEmpty ||
        _zip.text.trim().isEmpty ||
        _idNumber.text.trim().isEmpty ||
        _idDocPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Fill every required field and attach your ID scan.')));
      return;
    }
    setState(() => _busy = true);
    try {
      final idDocKey = await state.uploadIdDocument(_idDocPath!);
      await state.applySeller({
        'fullName': _name.text.trim(),
        'address': address,
        'phone': _phone.text.trim(),
        'email': _email.text.trim(),
        'zip': _zip.text.trim(),
        'country': _country,
        'idType': _idType,
        'idNumber': _idNumber.text.trim(),
        'idDocKey': idDocKey,
      });
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Application submitted for review.')));
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: ${e is ApiException ? e.message : e}')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final status = state.sellerProfile.status;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? Colors.black : Colors.white;
    final fg = isDark ? Colors.white : Colors.black87;
    final sub = isDark ? Colors.white70 : Colors.black54;
    final faint = isDark ? Colors.white38 : Colors.black38;
    final ddBg = isDark ? const Color(0xFF1a1a1a) : const Color(0xFFF5F5F5);
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(backgroundColor: bg, title: Text('Become a seller', style: TextStyle(color: fg))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (status == 'pending')
              const _Banner('Application under review. You will be notified.', Colors.amber)
            else if (status == 'verified')
              const _Banner('You are a verified seller ✓', Colors.greenAccent)
            else if (status == 'rejected')
              _Banner('Rejected: ${state.sellerProfile.reviewerNote}. You may re-apply.', Colors.redAccent),
            if (status != 'verified') ...[
              Text(
                  'Government ID + identity number + contact details are required to sell. Buyers never need this.',
                  style: TextStyle(color: sub, fontSize: 13)),
              const SizedBox(height: 12),
              _F(_name, 'Full legal name', fg, sub),
              const SizedBox(height: 4),
              Text('Address', style: TextStyle(color: fg, fontSize: 14, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              _F(_street, 'Street address', fg, sub),
              _F(_apt, 'Apartment, unit, etc. (optional)', fg, sub, optional: true),
              Row(children: [
                Expanded(child: _F(_city, 'City', fg, sub)),
                const SizedBox(width: 12),
                Expanded(child: _F(_state, 'State / Province', fg, sub)),
              ]),
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _country,
                    dropdownColor: ddBg,
                    style: TextStyle(color: fg),
                    decoration: InputDecoration(
                        labelText: 'Country', labelStyle: TextStyle(color: sub)),
                    items: _countries.entries
                        .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                        .toList(),
                    onChanged: (v) => setState(() => _country = v!),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: _F(_zip, 'ZIP / Postal code', fg, sub)),
              ]),
              const SizedBox(height: 4),
              Row(children: [
                Expanded(child: _F(_phone, 'Phone', fg, sub)),
                const SizedBox(width: 12),
                Expanded(child: _F(_email, 'Email', fg, sub)),
              ]),
              DropdownButtonFormField<String>(
                initialValue: _idType,
                dropdownColor: ddBg,
                style: TextStyle(color: fg),
                decoration:
                    InputDecoration(labelText: 'ID type', labelStyle: TextStyle(color: sub)),
                items: _idTypes.entries
                    .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                    .toList(),
                onChanged: (v) => setState(() => _idType = v!),
              ),
              _F(_idNumber, 'Identity number (SSN / NIN / …)', fg, sub),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _pick,
                icon: const Icon(Icons.upload_file, color: Color(0xFFFFC107)),
                label: Text(_idDocPath == null ? 'Attach government ID scan' : 'ID attached ✓',
                    style: TextStyle(color: fg)),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black),
                onPressed: _busy || status == 'pending' ? null : _submit,
                child: Text(_busy
                    ? 'Submitting…'
                    : (status == 'rejected' ? 'Re-apply' : 'Submit application')),
              ),
              const SizedBox(height: 8),
              Text('Your ID is used for verification only and is never shown publicly.',
                  style: TextStyle(color: faint, fontSize: 12), textAlign: TextAlign.center),
            ],
          ],
        ),
      ),
    );
  }
}

class _F extends StatelessWidget {
  final TextEditingController c;
  final String label;
  final Color fg;
  final Color sub;
  final bool optional;
  const _F(this.c, this.label, this.fg, this.sub, {this.optional = false});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
          controller: c,
          style: TextStyle(color: fg),
          decoration: InputDecoration(labelText: label, labelStyle: TextStyle(color: sub))),
    );
  }
}

class _Banner extends StatelessWidget {
  final String text;
  final Color color;
  const _Banner(this.text, this.color);
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration:
          BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
      child: Text(text, style: TextStyle(color: color, fontSize: 13)),
    );
  }
}
