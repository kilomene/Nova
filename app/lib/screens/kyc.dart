import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/api_client.dart';
import '../state/app_state.dart';

/// KYC flow: status → document upload → pending → verified.
/// v1 verification is manual review (clearly labeled); demo can simulate approval.
class KycScreen extends StatefulWidget {
  const KycScreen({super.key});

  @override
  State<KycScreen> createState() => _KycScreenState();
}

class _KycScreenState extends State<KycScreen> {
  String? _front;
  String? _back;
  String? _selfie;
  bool _busy = false;

  Future<void> _pick(void Function(String) set) async {
    final r = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (r?.path != null) setState(() => set(r!.path));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final status = state.kyc.status;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Identity verification')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StatusCard(status: status, note: state.kyc.reviewerNote),
            const SizedBox(height: 20),
            if (status == 'verified') ...[
              const Icon(Icons.verified_user, size: 64, color: Colors.greenAccent),
              const SizedBox(height: 12),
              const Text('Your identity is verified. Your wallet is unlocked.',
                  textAlign: TextAlign.center, style: TextStyle(color: Colors.white)),
            ] else if (status == 'pending') ...[
              const Icon(Icons.hourglass_empty, size: 64, color: Color(0xFFFFC107)),
              const SizedBox(height: 12),
              const Text('Your documents are under review.\nThis usually takes less than 24 hours.',
                  textAlign: TextAlign.center, style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 16),
              const Text('v1 note: verification is manual review by the Nova team.',
                  textAlign: TextAlign.center, style: TextStyle(color: Colors.white38, fontSize: 12)),
              if (state.isDemo) ...[
                const SizedBox(height: 16),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(foregroundColor: const Color(0xFFFFC107)),
                  onPressed: () => state.kyc.demoSimulateApproval(),
                  child: const Text('DEMO: simulate reviewer approval'),
                ),
              ],
            ] else ...[
              const Text('To unlock your wallet, verify your identity with a government ID.',
                  style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 16),
              _DocRow(label: 'ID front', path: _front, onPick: () => _pick((p) => _front = p),
                  onClear: _front == null ? null : () => setState(() => _front = null)),
              _DocRow(label: 'ID back', path: _back, onPick: () => _pick((p) => _back = p),
                  onClear: _back == null ? null : () => setState(() => _back = null)),
              _DocRow(label: 'Selfie', path: _selfie, onPick: () => _pick((p) => _selfie = p),
                  onClear: _selfie == null ? null : () => setState(() => _selfie = null)),
              if (status == 'rejected' && state.kyc.reviewerNote.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('Reviewer note: ${state.kyc.reviewerNote}', style: const TextStyle(color: Colors.redAccent)),
              ],
              const SizedBox(height: 20),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFC107), foregroundColor: Colors.black),
                onPressed: (_front == null || _back == null || _selfie == null || _busy)
                    ? null
                    : () async {
                        setState(() => _busy = true);
                        try {
                          await state.kyc.submit(api: state.api, frontPath: _front!, backPath: _back!, selfiePath: _selfie!);
                          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Submitted for review.')));
                        } catch (e) {
                          final msg = e is ApiException ? e.message : 'Submit failed. Please try again.';
                          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
                        } finally {
                          if (mounted) setState(() => _busy = false);
                        }
                      },
                child: Text(_busy ? 'Uploading…' : 'Submit for verification'),
              ),
              const SizedBox(height: 12),
              const Text(
                'Your documents are stored privately and never shown on your public profile. Only your verification status is visible.',
                style: TextStyle(color: Colors.white38, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final String status;
  final String note;
  const _StatusCard({required this.status, required this.note});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      'verified' => Colors.greenAccent,
      'pending' => const Color(0xFFFFC107),
      'rejected' => Colors.redAccent,
      _ => Colors.white38,
    };
    final label = switch (status) {
      'verified' => 'VERIFIED',
      'pending' => 'UNDER REVIEW',
      'rejected' => 'REJECTED',
      _ => 'NOT VERIFIED',
    };
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF161616),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(status == 'verified' ? Icons.verified_user : Icons.person_outline, color: color, size: 32),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
              const Text('Wallet requires verification', style: TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }
}

class _DocRow extends StatelessWidget {
  final String label;
  final String? path;
  final VoidCallback onPick;
  final VoidCallback? onClear;
  const _DocRow({required this.label, required this.path, required this.onPick, this.onClear});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFF161616), borderRadius: BorderRadius.circular(10)),
      child: Row(
        children: [
          const Icon(Icons.badge_outlined, color: Colors.white54),
          const SizedBox(width: 12),
          Expanded(
            child: Text(path == null ? label : path!.split('/').last,
                style: TextStyle(color: path == null ? Colors.white54 : Colors.white), overflow: TextOverflow.ellipsis),
          ),
          if (onClear != null) IconButton(icon: const Icon(Icons.close, color: Colors.white54), onPressed: onClear),
          TextButton(onPressed: onPick, child: Text(path == null ? 'Upload' : 'Change', style: const TextStyle(color: Color(0xFFFFC107)))),
        ],
      ),
    );
  }
}
