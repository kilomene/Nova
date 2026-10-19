import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web3dart/web3dart.dart';

import 'api_client.dart';
import 'btc_tx.dart';
import 'kyc_service.dart';
import 'wallet_crypto.dart';

class WalletException implements Exception {
  final String code;
  WalletException(this.code);
}

/// Per-user wallet lifecycle.
///
/// - Creation requires verified KYC (checked here AND on the server).
/// - Private keys exist only in RAM during signing; the keystore backup is
///   ciphertext only (see wallet_crypto.dart + SECURITY.md).
/// - v1 sends: EVM on Sepolia testnet via a public RPC (no key needed).
///   Mainnet is compiled behind AppConfig.mainnetEnabled (false).
/// - BTC: real mainnet address + read-only balance via Blockstream;
///   BTC *sending* is a labeled TODO (UTXO construction, phase 2).
class WalletService {
  String? evmAddress;
  String? btcAddress;

  bool get hasWallet => evmAddress != null;

  static const _prefsKey = 'nova_keystore_bundle';
  static const sepoliaRpc = 'https://ethereum-sepolia-rpc.publicnode.com';

  Future<void> create({
    required String pin,
    required ApiClient api,
    required KycService kyc,
  }) async {
    if (!kyc.canCreateWallet) throw WalletException('kyc_required');
    KeystoreCrypto.validatePin(pin);
    final mnemonic = generateMnemonic();
    final w = deriveWallet(mnemonic);
    final bundle = await KeystoreCrypto.encrypt(
      mnemonic: mnemonic,
      pin: pin,
      evmAddress: w.evmAddress,
      btcAddress: w.btcAddress,
    );
    if (api.isDemo) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, _bundleToString(bundle));
    } else {
      await api.post('/api/keystore', {'bundle': bundle.toJson()});
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, _bundleToString(bundle));
    }
    evmAddress = w.evmAddress;
    btcAddress = w.btcAddress;
  }

  /// Load addresses from the stored bundle (server or local). No PIN needed
  /// — addresses are public.
  Future<void> load(ApiClient api) async {
    KeystoreBundle? bundle;
    if (api.isDemo) {
      bundle = await _localBundle();
    } else {
      try {
        final r = await api.get('/api/keystore');
        final b = r['bundle'];
        if (b is Map<String, dynamic>) bundle = KeystoreBundle.fromJson(b);
      } catch (_) {
        bundle = await _localBundle();
      }
    }
    if (bundle != null) {
      evmAddress = bundle.evmAddress;
      btcAddress = bundle.btcAddress;
    }
  }

  Future<KeystoreBundle?> _localBundle() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_prefsKey);
    if (s == null) return null;
    try {
      return KeystoreBundle.fromJson(_bundleFromString(s));
    } catch (_) {
      return null;
    }
  }

  /// Decrypt the mnemonic with the PIN and derive the EVM private key.
  /// The caller MUST clear the returned value after use.
  Future<String> _unlockEvmKey(String pin, ApiClient api) async {
    KeystoreBundle? bundle;
    if (api.isDemo) {
      bundle = await _localBundle();
    } else {
      final r = await api.get('/api/keystore');
      final b = r['bundle'];
      if (b is Map<String, dynamic>) bundle = KeystoreBundle.fromJson(b);
    }
    if (bundle == null) throw WalletException('no_wallet');
    final mnemonic = await KeystoreCrypto.decrypt(bundle: bundle, pin: pin);
    final w = deriveWallet(mnemonic);
    return w.evmPrivateKeyHex;
  }

  /// Returns true if [pin] correctly unlocks the keystore (i.e. the PIN is
  /// correct). Used to confirm sensitive actions (e.g. earnings payouts).
  Future<bool> verifyPin(String pin, ApiClient api) async {
    try {
      await _unlockEvmKey(pin, api);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Change the wallet PIN: verifies [oldPin], then re-encrypts the keystore
  /// with [newPin] and saves the new bundle (server + local).
  /// Throws [WalletException] on wrong old PIN or invalid new PIN.
  Future<void> changePin({
    required String oldPin,
    required String newPin,
    required ApiClient api,
  }) async {
    KeystoreCrypto.validatePin(newPin);
    // Decrypt with old PIN to get the mnemonic (throws if wrong).
    KeystoreBundle? bundle;
    if (api.isDemo) {
      bundle = await _localBundle();
    } else {
      final r = await api.get('/api/keystore');
      final b = r['bundle'];
      if (b is Map<String, dynamic>) bundle = KeystoreBundle.fromJson(b);
    }
    if (bundle == null) throw WalletException('no_wallet');
    String mnemonic;
    try {
      mnemonic = await KeystoreCrypto.decrypt(bundle: bundle, pin: oldPin);
    } catch (_) {
      throw WalletException('incorrect_pin');
    }
    // Re-encrypt with the new PIN (fresh salt/nonce).
    final newBundle = await KeystoreCrypto.encrypt(
      mnemonic: mnemonic,
      pin: newPin,
      evmAddress: bundle.evmAddress,
      btcAddress: bundle.btcAddress,
    );
    if (api.isDemo) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, _bundleToString(newBundle));
    } else {
      await api.post('/api/keystore', {'bundle': newBundle.toJson()});
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, _bundleToString(newBundle));
    }
  }

  /// EVM balance on Sepolia (testnet). Returns ETH as a decimal string.
  Future<String> evmBalance() async {
    if (evmAddress == null) throw WalletException('no_wallet');
    final client = Web3Client(sepoliaRpc, http.Client());
    try {
      final bal = await client.getBalance(EthereumAddress.fromHex(evmAddress!));
      return bal.getValueInUnit(EtherUnit.ether).toString();
    } finally {
      client.dispose();
    }
  }

  /// BTC mainnet balance in BTC (read-only via Blockstream; no key needed).
  Future<String> btcBalance() async {
    if (btcAddress == null) throw WalletException('no_wallet');
    final resp = await http.get(Uri.parse('https://blockstream.info/api/address/$btcAddress'));
    if (resp.statusCode != 200) throw WalletException('balance_unavailable');
    // Minimal parse without extra deps.
    final body = resp.body;
    final funded = _numAfter(body, '"funded_txo_sum":');
    final spent = _numAfter(body, '"spent_txo_sum":');
    return ((funded - spent) / 100000000).toString();
  }

  /// ERC-20 token balance (e.g. USDT, USDC) via balanceOf call.
  /// [contractAddress] is the token contract on the same chain.
  /// Returns the balance in token units (handles decimals automatically).
  Future<String> tokenBalance(String contractAddress) async {
    if (evmAddress == null) throw WalletException('no_wallet');
    final client = Web3Client(sepoliaRpc, http.Client());
    try {
      final contract = DeployedContract(
        ContractAbi.fromJson(
          '[{"constant":true,"inputs":[{"name":"_owner","type":"address"}],"name":"balanceOf","outputs":[{"name":"balance","type":"uint256"}],"type":"function"},'
          '{"constant":true,"inputs":[],"name":"decimals","outputs":[{"name":"","type":"uint8"}],"type":"function"}]',
          'ERC20',
        ),
        EthereumAddress.fromHex(contractAddress),
      );
      final balanceOf = contract.function('balanceOf');
      final decimalsFn = contract.function('decimals');
      final result = await client.call(
        contract: contract,
        function: balanceOf,
        params: [EthereumAddress.fromHex(evmAddress!)],
      );
      final decimalsResult = await client.call(
        contract: contract,
        function: decimalsFn,
        params: [],
      );
      final raw = result.first as BigInt;
      final decimals = (decimalsResult.first as BigInt).toInt();
      final divisor = BigInt.from(10).pow(decimals);
      final whole = raw ~/ divisor;
      final frac = raw % divisor;
      if (frac == BigInt.zero) return whole.toString();
      // Show up to 6 decimal places.
      var fracStr = frac.toString().padLeft(decimals, '0');
      fracStr = fracStr.substring(0, fracStr.length.clamp(0, 6)).replaceAll(RegExp(r'0+\$'), '');
      return fracStr.isEmpty ? whole.toString() : '$whole.$fracStr';
    } finally {
      client.dispose();
    }
  }

  /// USDT balance (contract address from backend config).
  Future<String> usdtBalance(String contractAddress) => tokenBalance(contractAddress);

  /// USDC balance (contract address from backend config).
  Future<String> usdcBalance(String contractAddress) => tokenBalance(contractAddress);

  /// ERC-20 token transfer.
  Future<String> sendToken({
    required String pin,
    required String contractAddress,
    required String to,
    required double amount,
    required ApiClient api,
  }) async {
    if (amount <= 0) throw WalletException('bad_amount');
    final privHex = await _unlockEvmKey(pin, api);
    final client = Web3Client(sepoliaRpc, http.Client());
    try {
      final contract = DeployedContract(
        ContractAbi.fromJson(
          '[{"constant":false,"inputs":[{"name":"_to","type":"address"},{"name":"_value","type":"uint256"}],"name":"transfer","outputs":[{"name":"","type":"bool"}],"type":"function"},'
          '{"constant":true,"inputs":[],"name":"decimals","outputs":[{"name":"","type":"uint8"}],"type":"function"}]',
          'ERC20',
        ),
        EthereumAddress.fromHex(contractAddress),
      );
      final decimalsResult = await client.call(
        contract: contract,
        function: contract.function('decimals'),
        params: [],
      );
      final decimals = (decimalsResult.first as BigInt).toInt();
      final rawAmount = BigInt.from((amount * BigInt.from(10).pow(decimals).toDouble()).round());
      final creds = EthPrivateKey.fromHex(privHex);
      final hash = await client.sendTransaction(
        creds,
        Transaction.callContract(
          contract: contract,
          function: contract.function('transfer'),
          parameters: [EthereumAddress.fromHex(to), rawAmount],
        ),
        chainId: 11155111, // Sepolia
      );
      return hash;
    } finally {
      client.dispose();
    }
  }

  /// BTC send: fetch UTXOs, build P2PKH transaction, sign, broadcast.
  /// Real mainnet transaction via Blockstream. Returns the txid.
  /// The caller MUST NOT log the private key.
  Future<String> sendBtc({
    required String pin,
    required String to,
    required double amountBtc,
    required ApiClient api,
  }) async {
    if (amountBtc <= 0) throw WalletException('bad_amount');
    if (btcAddress == null) throw WalletException('no_wallet');
    final privHex = await _unlockBtcKey(pin, api);
    try {
      final amountSat = (amountBtc * 100000000).round();
      return await sendBtcTx(
        fromAddress: btcAddress!,
        privHex: privHex,
        toAddress: to,
        amountSat: amountSat,
      );
    } on BtcTxException catch (e) {
      throw WalletException('btc_${e.code}');
    }
  }

  /// Decrypt the mnemonic with the PIN and derive the BTC private key
  /// (m/44'/0'/0'/0/0). The caller MUST clear the returned value after use.
  Future<String> _unlockBtcKey(String pin, ApiClient api) async {
    KeystoreBundle? bundle;
    if (api.isDemo) {
      bundle = await _localBundle();
    } else {
      final r = await api.get('/api/keystore');
      final b = r['bundle'];
      if (b is Map<String, dynamic>) bundle = KeystoreBundle.fromJson(b);
    }
    if (bundle == null) throw WalletException('no_wallet');
    final mnemonic = await KeystoreCrypto.decrypt(bundle: bundle, pin: pin);
    final w = deriveWallet(mnemonic);
    return w.btcPrivateKeyHex;
  }

  double _numAfter(String body, String key) {
    final i = body.indexOf(key);
    if (i < 0) return 0;
    final sub = body.substring(i + key.length).trimLeft();
    final m = RegExp(r'^-?\d+').firstMatch(sub);
    return m == null ? 0 : double.parse(m.group(0)!);
  }

  /// Send ETH on Sepolia. UI must confirm first; testnet banner required.
  Future<String> sendEvm({
    required String pin,
    required String to,
    required double amountEth,
    required ApiClient api,
  }) async {
    if (amountEth <= 0) throw WalletException('bad_amount');
    final privHex = await _unlockEvmKey(pin, api);
    final client = Web3Client(sepoliaRpc, http.Client());
    try {
      final creds = EthPrivateKey.fromHex(privHex);
      final hash = await client.sendTransaction(
        creds,
        Transaction(
          to: EthereumAddress.fromHex(to),
          value: EtherAmount.fromBigInt(EtherUnit.wei, BigInt.from((amountEth * 1e18).round())),
        ),
        chainId: 11155111,
      );
      return hash;
    } finally {
      client.dispose();
    }
  }

  Future<void> forgetLocal() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    evmAddress = null;
    btcAddress = null;
  }

  String _bundleToString(KeystoreBundle b) {
    final j = b.toJson();
    return j.entries.map((e) => '${e.key}=${e.value}').join('&');
  }

  Map<String, dynamic> _bundleFromString(String s) {
    final out = <String, dynamic>{};
    for (final part in s.split('&')) {
      final i = part.indexOf('=');
      if (i > 0) out[part.substring(0, i)] = part.substring(i + 1);
    }
    out['iterations'] = int.parse('${out['iterations']}');
    return out;
  }
}
