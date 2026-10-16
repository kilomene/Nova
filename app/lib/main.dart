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

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final auth = AuthService();
  final api = ApiClient(
    baseUrl: AppConfig.apiBaseUrl,
    tokenProvider: () => auth.idToken(),
  );
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
