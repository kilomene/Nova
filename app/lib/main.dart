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
      value: state..loadThemePreference(),
      child: const NovaApp(),
    ),
  );
}

class NovaApp extends StatelessWidget {
  const NovaApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeMode = context.watch<AppState>().themeMode;
    return MaterialApp(
      title: 'Nova',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      theme: ThemeData.light(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: Colors.white,
        colorScheme: const ColorScheme.light(
          primary: Color(0xFFB8860B),
          onPrimary: Colors.white,
          secondary: Color(0xFF20D5EC),
          surface: Color(0xFFF5F5F5),
        ),
        appBarTheme: const AppBarTheme(backgroundColor: Colors.white, foregroundColor: Colors.black87),
        inputDecorationTheme: const InputDecorationTheme(
          enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.black12)),
          focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFFB8860B))),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFB8860B), foregroundColor: Colors.white),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFFB8860B), foregroundColor: Colors.white),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: Colors.black),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(foregroundColor: Colors.black),
        ),
      ),
      darkTheme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFD4AF37),
          onPrimary: Colors.black,
          secondary: Color(0xFF20D5EC),
          surface: Color(0xFF1A1A1A),
        ),
        appBarTheme: const AppBarTheme(backgroundColor: Colors.black, foregroundColor: Colors.white),
        inputDecorationTheme: const InputDecorationTheme(
          enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
          focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFFD4AF37))),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD4AF37), foregroundColor: Colors.black),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(backgroundColor: const Color(0xFFD4AF37), foregroundColor: Colors.black),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: Colors.white),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
        ),
      ),
      themeMode: themeMode,
      home: const SplashScreen(),
    );
  }
}
