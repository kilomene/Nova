// Wallet crypto tests. Run with: flutter test
// The BIP32 vectors below are from the official BIP32 specification
// (BSD-2-Clause licensed): https://github.com/bitcoin/bips (bip-0032).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova/services/wallet_crypto.dart';

Uint8List hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

void main() {
  const h = 0x80000000;

  group('BIP32 official test vectors', () {
    test('vector 1: chain m', () {
      final xprv = xprvForTestVector(hex('000102030405060708090a0b0c0d0e0f'), []);
      expect(xprv, 'xprv9s21ZrQH143K3QTDL4LXw2F7HEK3wJUD2nW2nRk4stbPy6cq3jPPqjiChkVvvNKmPGJxWUtg6LnF5kejMRNNU3TGtRBeJgk33yuGBxrMPHi');
    });

    test('vector 1: chain m/0H', () {
      final xprv = xprvForTestVector(hex('000102030405060708090a0b0c0d0e0f'), [h + 0]);
      expect(xprv, 'xprv9uHRZZhk6KAJC1avXpDAp4MDc3sQKNxDiPvvkX8Br5ngLNv1TxvUxt4cV1rGL5hj6KCesnDYUhd7oWgT11eZG7XnxHrnYeSvkzY7d2bhkJ7');
    });

    test('vector 1: chain m/0H/1/2H/2/1000000000', () {
      final xprv = xprvForTestVector(hex('000102030405060708090a0b0c0d0e0f'), [h + 0, 1, h + 2, 2, 1000000000]);
      expect(xprv, 'xprvA41z7zogVVwxVSgdKUHDy1SKmdb533PjDz7J6N6mV6uS3ze1ai8FHa8kmHScGpWmj4WggLyQjgPie1rFSruoUihUZREPSL39UNdE3BBDu76');
    });

    test('vector 2: chain m/0/2147483647H/1', () {
      final xprv = xprvForTestVector(
        hex('fffcf9f6f3f0edeae7e4e1dedbd8d5d2cfccc9c6c3c0bdbab7b4b1aeaba8a5a29f9c999693908d8a8784817e7b7875726f6c696663605d5a5754514e4b484542'),
        [0, h + 2147483647, 1],
      );
      expect(xprv, 'xprv9zFnWC6h2cLgpmSA46vutJzBcfJ8yaJGg8cX1e5StJh45BBciYTRXSd25UEPVuesF9yog62tGAQtHjXajPPdbRCHuWS6T8XA2ECKADdw4Ef');
    });

    test('vector 3 (leading zeros): chain m/0H', () {
      final xprv = xprvForTestVector(
        hex('4b381541583be4423346c643850da4b320e46a87ae3d2a4e6da11eba819cd4acba45d239319ac14f863b8d5ab5a0d0c64d2e8a1e7d1457df2e5a3c51c73235be'),
        [h + 0],
      );
      expect(xprv, 'xprv9uPDJpEQgRQfDcW7BkF7eTya6RPxXeJCqCJGHuCJ4GiRVLzkTXBAJMu2qaMWPrS7AANYqdq6vcBcBUdJCVVFceUvJFjaPdGZ2y9WACViL4L');
    });
  });

  group('wallet derivation', () {
    test('is deterministic per mnemonic', () {
      const mnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      final a = deriveWallet(mnemonic);
      final b = deriveWallet(mnemonic);
      expect(a.evmAddress, b.evmAddress);
      expect(a.btcAddress, b.btcAddress);
      expect(a.evmPrivateKeyHex, b.evmPrivateKeyHex);
    });

    test('address formats are valid', () {
      final w = deriveWallet(generateMnemonic());
      expect(w.evmAddress, matches(RegExp(r'^0x[0-9a-fA-F]{40}$')));
      expect(w.btcAddress, matches(RegExp(r'^[13][a-km-zA-HJ-NP-Z1-9]{25,34}$')));
      expect(w.evmPrivateKeyHex, matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('rejects invalid mnemonic', () {
      expect(() => deriveWallet('not a real mnemonic phrase'), throwsArgumentError);
    });
  });

  group('keystore', () {
    test('encrypt/decrypt round-trip', () async {
      const mnemonic = 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about';
      final bundle = await KeystoreCrypto.encrypt(
        mnemonic: mnemonic,
        pin: '123456',
        evmAddress: '0x0',
        btcAddress: '1abc',
      );
      // Ciphertext must not contain the mnemonic or look like a raw key.
      final raw = bundle.toJson().toString();
      expect(raw.contains('abandon'), isFalse);
      final clear = await KeystoreCrypto.decrypt(bundle: bundle, pin: '123456');
      expect(clear, mnemonic);
    });

    test('wrong PIN fails', () async {
      final bundle = await KeystoreCrypto.encrypt(
        mnemonic: 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about',
        pin: '123456',
        evmAddress: '0x0',
        btcAddress: '1abc',
      );
      expect(() => KeystoreCrypto.decrypt(bundle: bundle, pin: 'wrong!'), throwsA(anything));
    });

    test('PIN policy enforced', () {
      expect(() => KeystoreCrypto.validatePin('123'), throwsArgumentError);
    });
  });
}
