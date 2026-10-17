import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'config.dart';
import 'screens/auth.dart';
import 'services/api_client.dart';
import 'services/auth_service.dart';
import 'services/coin_service.dart';
import 'services/kyc_service.dart';
import 'services/push_service.dart';
import 'services/sync_service.dart';
import 'services/wallet_service.dart';
import 'state/app_state.dart';

/// Global navigator key: lets the API layer route to the login gate on a
/// 401 without needing a BuildContext.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final auth = AuthService();
  final api = ApiClient(
    baseUrl: AppConfig.apiBaseUrl,
    tokenProvider: () => auth.idToken(),
  );
  // Any 401 anywhere → clear the session and show the login gate with a
  // friendly message. Never a raw ApiException string in the UI.
  api.onUnauthorized = () {
    if (AuthScreen.gateOpen) return; // already on the gate: no stacking
    auth.signOut();
    navigatorKey.currentState?.pushAndRemoveUntil(
      MaterialPageRoute(
        builder: (_) => const AuthScreen(gate: true, notice: 'Please log in to continue'),
      ),
      (_) => false,
    );
  };
  final state = AppState(
    auth: auth,
    api: api,
    kyc: KycService(),
    wallet: WalletService(),
    coins: CoinService(),
    sync: SyncService(),
    push: PushService(),
  );

  runApp(
    ChangeNotifierProvider.value(
      value: state,
      child: const NovaApp(),
    ),
  );
}

class NovaApp extends StatelessWidget {
  const NovaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nova',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFFC107),
          secondary: Color(0xFF20D5EC),
          surface: Color(0xFF161616),
        ),
        appBarTheme: const AppBarTheme(backgroundColor: Colors.black, foregroundColor: Colors.white),
        inputDecorationTheme: const InputDecorationTheme(
          enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
          focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFFFFC107))),
        ),
      ),
      home: const SplashScreen(),
    );
  }
}
