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
  final _address = TextEditingController();
  final _phone = TextEditingController();
  final _email = TextEditingController();
  final _zip = TextEditingController();
  final _country = TextEditingController(text: 'US');
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

  Future<void> _pick() async {
    final r = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (r?.path != null) setState(() => _idDocPath = r!.path);
  }

  Future<void> _submit() async {
    final state = context.read<AppState>();
    if (_name.text.trim().isEmpty || _address.text.trim().isEmpty || _phone.text.trim().isEmpty ||
        _email.text.trim().isEmpty || _zip.text.trim().isEmpty || _idNumber.text.trim().isEmpty || _idDocPath == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Fill every field and attach your ID scan.')));
      return;
    }
    setState(() => _busy = true);
    try {
      final idDocKey = await state.uploadIdDocument(_idDocPath!);
      await state.applySeller({
        'fullName': _name.text.trim(),
        'address': _address.text.trim(),
        'phone': _phone.text.trim(),
        'email': _email.text.trim(),
        'zip': _zip.text.trim(),
        'country': _country.text.trim(),
        'idType': _idType,
        'idNumber': _idNumber.text.trim(),
        'idDocKey': idDocKey,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Application submitted for review.')));
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed: ${e is ApiException ? e.message : e}')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final status = state.sellerProfile.status;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Become a seller')),
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
              const Text('Government ID + identity number + contact details are required to sell. Buyers never need this.',
                  style: TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 12),
              _F(_name, 'Full legal name'),
              _F(_address, 'Address'),
              Row(children: [
                Expanded(child: _F(_phone, 'Phone')),
                const SizedBox(width: 12),
                Expanded(child: _F(_email, 'Email')),
              ]),
              Row(children: [
                Expanded(child: _F(_zip, 'ZIP / postal code')),
                const SizedBox(width: 12),
                Expanded(child: _F(_country, 'Country code (US, NG, …)')),
              ]),
              DropdownButtonFormField<String>(
                initialValue: _idType,
                dropdownColor: const Color(0xFF1a1a1a),
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(labelText: 'ID type', labelStyle: TextStyle(color: Colors.white54)),
                items: _idTypes.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
                onChanged: (v) => setState(() => _idType = v!),
              ),
              _F(_idNumber, 'Identity number (SSN / NIN / …)'),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _pick,
                icon: const Icon(Icons.upload_file, color: Color(0xFFFFC107)),
                label: Text(_idDocPath == null ? 'Attach government ID scan' : 'ID attached ✓',
                    style: const TextStyle(color: Colors.white)),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black),
                onPressed: _busy || status == 'pending' ? null : _submit,
                child: Text(_busy ? 'Submitting…' : (status == 'rejected' ? 'Re-apply' : 'Submit application')),
              ),
              const SizedBox(height: 8),
              const Text('Your ID is used for verification only and is never shown publicly.',
                  style: TextStyle(color: Colors.white38, fontSize: 12), textAlign: TextAlign.center),
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
  const _F(this.c, this.label);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(controller: c, style: const TextStyle(color: Colors.white), decoration: InputDecoration(labelText: label, labelStyle: const TextStyle(color: Colors.white54))),
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
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
      child: Text(text, style: TextStyle(color: color, fontSize: 13)),
    );
  }
}
