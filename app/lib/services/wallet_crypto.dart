// Wallet cryptography for Nova.
//
// - BIP39 mnemonic generation (256-bit entropy, platform CSPRNG).
// - BIP32 HD derivation (secp256k1) for m/44'/60'/0'/0/0 (EVM) and
//   m/44'/0'/0'/0/0 (BTC P2PKH). Verified against the official BIP32 test
//   vectors in test/wallet_crypto_test.dart.
// - AES-256-GCM keystore: mnemonic encrypted with a PIN-derived key
//   (PBKDF2-HMAC-SHA512, 210k iterations, random salt). Only the
//   ciphertext bundle leaves the device.
//
// Plaintext keys exist ONLY in Dart RAM during an active session and are
// never logged, never persisted unencrypted, never sent to the server.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:bip39/bip39.dart' as bip39;
import 'package:bs58/bs58.dart';
import 'package:cryptography/cryptography.dart';
import 'package:pointycastle/api.dart' hide Mac;
import 'package:pointycastle/digests/ripemd160.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/digests/sha512.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:web3dart/web3dart.dart';

class DerivedWallet {
  final String mnemonic;
  final String evmPrivateKeyHex;
  final String evmAddress; // EIP-55 checksummed
  final String btcAddress; // P2PKH

  DerivedWallet({
    required this.mnemonic,
    required this.evmPrivateKeyHex,
    required this.evmAddress,
    required this.btcAddress,
  });
}

// ---------------- low-level helpers ----------------

Uint8List _randomBytes(int n) {
  final r = Random.secure();
  return Uint8List.fromList(List<int>.generate(n, (_) => r.nextInt(256)));
}

Uint8List _hmacSha512(Uint8List key, Uint8List data) {
  final h = HMac(SHA512Digest(), 128);
  h.init(KeyParameter(key));
  return h.process(data);
}

BigInt _bytesToBigInt(Uint8List b) {
  var v = BigInt.zero;
  for (final byte in b) {
    v = (v << 8) | BigInt.from(byte);
  }
  return v;
}

Uint8List _bigIntTo32(BigInt v) {
  final out = Uint8List(32);
  for (var i = 31; i >= 0; i--) {
    out[i] = (v & BigInt.from(0xff)).toInt();
    v >>= 8;
  }
  return out;
}

Uint8List _ser32(int i) {
  final b = ByteData(4)..setUint32(0, i);
  return b.buffer.asUint8List();
}

String _hex(Uint8List b) => b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

// ---------------- BIP32 ----------------

final ECDomainParameters _secp = ECCurve_secp256k1();
final BigInt _n = _secp.n;

class _Node {
  final Uint8List priv; // 32 bytes
  final Uint8List chainCode; // 32 bytes
  _Node(this.priv, this.chainCode);
}

_Node _masterNode(Uint8List seed) {
  final i = _hmacSha512(Uint8List.fromList(utf8.encode('Bitcoin seed')), seed);
  return _Node(i.sublist(0, 32), i.sublist(32, 64));
}

Uint8List _compressedPub(Uint8List priv) {
  final p = (_secp.G * _bytesToBigInt(priv))!;
  final x = _bigIntTo32(p.x!.toBigInteger()!);
  final prefix = p.y!.toBigInteger()!.isEven ? 0x02 : 0x03;
  return Uint8List.fromList([prefix, ...x]);
}

_Node _ckd(_Node parent, int index) {
  final hardened = index >= 0x80000000;
  final data = BytesBuilder();
  if (hardened) {
    data.add([0x00]);
    data.add(parent.priv);
  } else {
    data.add(_compressedPub(parent.priv));
  }
  data.add(_ser32(index));
  final i = _hmacSha512(parent.chainCode, data.toBytes());
  final il = _bytesToBigInt(i.sublist(0, 32));
  if (il >= _n) throw StateError('bip32: invalid derived key (IL >= n)');
  final child = (il + _bytesToBigInt(parent.priv)) % _n;
  if (child == BigInt.zero) throw StateError('bip32: invalid derived key (zero)');
  return _Node(_bigIntTo32(child), i.sublist(32, 64));
}

_Node _derivePath(_Node master, List<int> path) {
  var node = master;
  for (final index in path) {
    node = _ckd(node, index);
  }
  return node;
}

String _p2pkhAddress(Uint8List compressedPub) {
  final h160 = _hash160(compressedPub);
  final payload = Uint8List.fromList([0x00, ...h160]);
  final checksum = SHA256Digest().process(SHA256Digest().process(payload)).sublist(0, 4);
  return base58.encode(Uint8List.fromList([...payload, ...checksum]));
}

Uint8List _hash160(Uint8List data) {
  return RIPEMD160Digest().process(SHA256Digest().process(data));
}

/// Test-only: serialize the xprv at [path] for comparison against the
/// official BIP32 test vectors. Not used by the app.
String xprvForTestVector(Uint8List seed, List<int> path) {
  var node = _masterNode(seed);
  var depth = 0;
  var parentFp = Uint8List.fromList([0, 0, 0, 0]);
  var childNum = 0;
  for (final index in path) {
    parentFp = _hash160(_compressedPub(node.priv)).sublist(0, 4);
    childNum = index;
    depth += 1;
    node = _ckd(node, index);
  }
  final payload = BytesBuilder()
    ..add([0x04, 0x88, 0xAD, 0xE4])
    ..add([depth])
    ..add(parentFp)
    ..add(_ser32(childNum))
    ..add(node.chainCode)
    ..add([0x00])
    ..add(node.priv);
  final bytes = payload.toBytes();
  final chk = SHA256Digest().process(SHA256Digest().process(bytes)).sublist(0, 4);
  return base58.encode(Uint8List.fromList([...bytes, ...chk]));
}

/// Derive EVM + BTC credentials from a BIP39 mnemonic.
DerivedWallet deriveWallet(String mnemonic) {
  if (!bip39.validateMnemonic(mnemonic)) {
    throw ArgumentError('invalid mnemonic');
  }
  final seed = bip39.mnemonicToSeed(mnemonic);
  final master = _masterNode(seed);

  const h = 0x80000000;
  final ethNode = _derivePath(master, [h + 44, h + 60, h + 0, 0, 0]);
  final btcNode = _derivePath(master, [h + 44, h + 0, h + 0, 0, 0]);

  final ethPrivHex = _hex(ethNode.priv);
  final ethAddress = EthPrivateKey.fromHex(ethPrivHex).address.hexEip55;
  final btcAddress = _p2pkhAddress(_compressedPub(btcNode.priv));

  return DerivedWallet(
    mnemonic: mnemonic,
    evmPrivateKeyHex: ethPrivHex,
    evmAddress: ethAddress,
    btcAddress: btcAddress,
  );
}

String generateMnemonic() => bip39.generateMnemonic(strength: 256);

// ---------------- Keystore (PIN-encrypted) ----------------

class KeystoreBundle {
  final String kdf;
  final int iterations;
  final String saltB64;
  final String nonceB64;
  final String ciphertextB64;
  final String macB64;
  final String evmAddress;
  final String btcAddress;
  final String createdAt;

  KeystoreBundle({
    required this.kdf,
    required this.iterations,
    required this.saltB64,
    required this.nonceB64,
    required this.ciphertextB64,
    required this.macB64,
    required this.evmAddress,
    required this.btcAddress,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'kdf': kdf,
        'iterations': iterations,
        'salt': saltB64,
        'nonce': nonceB64,
        'ciphertext': ciphertextB64,
        'mac': macB64,
        'evmAddress': evmAddress,
        'btcAddress': btcAddress,
        'createdAt': createdAt,
      };

  factory KeystoreBundle.fromJson(Map<String, dynamic> j) => KeystoreBundle(
        kdf: '${j['kdf']}',
        iterations: (j['iterations'] as num).toInt(),
        saltB64: '${j['salt']}',
        nonceB64: '${j['nonce']}',
        ciphertextB64: '${j['ciphertext']}',
        macB64: '${j['mac']}',
        evmAddress: '${j['evmAddress']}',
        btcAddress: '${j['btcAddress']}',
        createdAt: '${j['createdAt']}',
      );
}

class KeystoreCrypto {
  static const int iterations = 210000;

  static void validatePin(String pin) {
    if (pin.length < 4) throw ArgumentError('PIN must be at least 4 characters');
    if (pin.length > 64) throw ArgumentError('PIN too long');
  }

  static Future<SecretKey> _deriveKey(String pin, Uint8List salt) {
    final pbkdf2 = Pbkdf2(macAlgorithm: Hmac.sha512(), iterations: iterations, bits: 256);
    return pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode('nova-wallet-v1:$pin')),
      nonce: salt,
    );
  }

  /// Encrypt the mnemonic. Returns the bundle safe to upload (ciphertext only).
  static Future<KeystoreBundle> encrypt({
    required String mnemonic,
    required String pin,
    required String evmAddress,
    required String btcAddress,
  }) async {
    validatePin(pin);
    final salt = _randomBytes(16);
    final key = await _deriveKey(pin, salt);
    final nonce = _randomBytes(12);
    final box = await AesGcm.with256bits().encrypt(
      utf8.encode(mnemonic),
      secretKey: key,
      nonce: nonce,
    );
    return KeystoreBundle(
      kdf: 'pbkdf2-sha512',
      iterations: iterations,
      saltB64: base64Encode(salt),
      nonceB64: base64Encode(nonce),
      ciphertextB64: base64Encode(box.cipherText),
      macB64: base64Encode(box.mac.bytes),
      evmAddress: evmAddress,
      btcAddress: btcAddress,
      createdAt: DateTime.now().toUtc().toIso8601String(),
    );
  }

  /// Decrypt. Throws on wrong PIN (MAC mismatch) — indistinguishable by design.
  static Future<String> decrypt({required KeystoreBundle bundle, required String pin}) async {
    validatePin(pin);
    final salt = base64Decode(bundle.saltB64);
    final key = await _deriveKey(pin, salt);
    final box = SecretBox(
      base64Decode(bundle.ciphertextB64),
      nonce: base64Decode(bundle.nonceB64),
      mac: Mac(base64Decode(bundle.macB64)),
    );
    final clear = await AesGcm.with256bits().decrypt(box, secretKey: key);
    return utf8.decode(clear);
  }
}
