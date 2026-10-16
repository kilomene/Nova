import 'package:firebase_messaging/firebase_messaging.dart';

import 'api_client.dart';

/// FCM: registers the device token with the backend; the Worker sends via
/// FCM HTTP v1 using the service-account secret (see docs/SETUP.md).
class PushService {
  bool _ready = false;

  Future<void> init(ApiClient api) async {
    if (_ready) return;
    try {
      final fcm = FirebaseMessaging.instance;
      await fcm.requestPermission();
      final token = await fcm.getToken();
      if (token != null && !api.isDemo) {
        await api.post('/api/push/register', {'token': token, 'platform': 'android'});
      }
      // Foreground messages: v1 surfaces a snackbar via AppState hook.
      FirebaseMessaging.onMessage.listen((_) {});
      _ready = true;
    } catch (_) {
      // Push is optional; the app works without it.
    }
  }
}
