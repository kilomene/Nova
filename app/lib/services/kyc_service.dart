import 'package:flutter/foundation.dart';

import 'api_client.dart';

/// KYC state machine: none -> pending -> verified|rejected.
/// The wallet unlocks ONLY at verified (enforced here AND server-side).
/// v1 verification is manual review; the demo can simulate approval.
class KycService extends ChangeNotifier {
  String status = 'none'; // none | pending | verified | rejected
  String reviewerNote = '';
  bool demoApproved = false;

  Future<void> refresh(ApiClient api) async {
    if (api.isDemo) return; // demo keeps local state
    try {
      final r = await api.get('/api/kyc/status');
      status = '${r['kyc_status'] ?? 'none'}';
      reviewerNote = '${(r['submission'] as Map?)?['reviewer_note'] ?? ''}';
      notifyListeners();
    } catch (_) {
      // keep last known state; cloud errors shouldn't wipe local UX
    }
  }

  /// Upload ID front/back + selfie, then submit for review.
  Future<void> submit({
    required ApiClient api,
    required String frontPath,
    required String backPath,
    required String selfiePath,
  }) async {
    if (api.isDemo) {
      status = 'pending';
      notifyListeners();
      return;
    }
    final f = await api.upload('/api/uploads', frontPath);
    final b = await api.upload('/api/uploads', backPath);
    final s = await api.upload('/api/uploads', selfiePath);
    final r = await api.post('/api/kyc/submit', {
      'docFrontKey': f['key'],
      'docBackKey': b['key'],
      'selfieKey': s['key'],
    });
    status = '${r['status'] ?? 'pending'}';
    notifyListeners();
  }

  /// Demo only: simulate a reviewer approving. Clearly labeled in UI.
  void demoSimulateApproval() {
    demoApproved = true;
    status = 'verified';
    notifyListeners();
  }

  bool get canCreateWallet => status == 'verified';
}
