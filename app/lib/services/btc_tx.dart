import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';

/// Errors from BTC transaction building / broadcasting.
class BtcTxException implements Exception {
  final String code;
  final String? detail;
  BtcTxException(this.code, [this.detail]);
  @override
  String toString() => 'BtcTxException($code${detail != null ? ': $detail' : ''})';
}

/// Digest that returns its input unchanged, so ECDSASigner signs the
/// 32-byte sighash directly (Bitcoin signs the hash, it must NOT be hashed again).
class _NullDigest implements Digest {
  @override
  String get algorithmName => 'NULL';
  @override
  int get digestSize => 32;
  @override
  int get byteLength => 64;
  @override
  void reset() {}
  @override
  Uint8List process(Uint8List data) => data;
  @override
  void update(Uint8List inp, int inpOff, int len) {}
  @override
  void updateByte(int inp) {}
  @override
  int doFinal(Uint8List out, int outOff) => 0;
}

/// A spendable UTXO (P2PKH).
class BtcUtxo {
  final String txid; // big-endian display hex
  final int vout;
  final int value; // satoshis
  final Uint8List scriptPubKey;
  BtcUtxo({required this.txid, required this.vout, required this.value, required this.scriptPubKey});
}

Uint8List _sha256(Uint8List d) => SHA256Digest().process(d);
Uint8List _dsha256(Uint8List d) => _sha256(_sha256(d));

String _hexOf(Uint8List b) => b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

const _b58alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

/// Base58 decode (correct leading-zero handling). Throws BtcTxException on bad char.
Uint8List _base58Decode(String s) {
  var num = BigInt.zero;
  for (final ch in s.split('')) {
    final idx = _b58alphabet.indexOf(ch);
    if (idx < 0) throw BtcTxException('bad_address', 'bad char');
    num = num * BigInt.from(58) + BigInt.from(idx);
  }
  var hex = num.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  final body = _hexToBytes(hex);
  var leading = 0;
  for (final ch in s.split('')) {
    if (ch == '1') {
      leading++;
    } else {
      break;
    }
  }
  // BigInt(0) -> hex '00' -> 1 zero byte; drop it when we have leading ones.
  final stripped = (num == BigInt.zero && body.length == 1 && body[0] == 0)
      ? Uint8List(0)
      : body;
  return Uint8List.fromList([...List.filled(leading, 0), ...stripped]);
}

/// Minimal DER encode of an ECDSA (r, s) pair.
Uint8List _derEncode(BigInt r, BigInt s) {
  Uint8List intBytes(BigInt v) {
    var hex = v.toRadixString(16);
    if (hex.length.isOdd) hex = '0$hex';
    var b = _hexToBytes(hex);
    var i = 0;
    while (i < b.length - 1 && b[i] == 0) {
      i++;
    }
    b = b.sublist(i);
    if (b[0] & 0x80 != 0) b = Uint8List.fromList([0, ...b]);
    return b;
  }

  final rb = intBytes(r);
  final sb = intBytes(s);
  final body = BytesBuilder()
    ..addByte(0x02)
    ..addByte(rb.length)
    ..add(rb)
    ..addByte(0x02)
    ..addByte(sb.length)
    ..add(sb);
  final bb = body.toBytes();
  return Uint8List.fromList([0x30, bb.length, ...bb]);
}

/// Bitcoin varint encoding.
Uint8List _varInt(int v) {
  final b = BytesBuilder();
  if (v < 0xfd) {
    b.addByte(v);
  } else if (v <= 0xffff) {
    b.addByte(0xfd);
    b.add(_u16le(v));
  } else if (v <= 0xffffffff) {
    b.addByte(0xfe);
    b.add(_u32le(v));
  } else {
    b.addByte(0xff);
    b.add(_u64le(v));
  }
  return b.toBytes();
}

Uint8List _u16le(int v) => Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little);
Uint8List _u32le(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
Uint8List _u64le(int v) => Uint8List(8)..buffer.asByteData().setUint64(0, v, Endian.little);

/// Push-data encoding for scripts.
Uint8List _push(Uint8List data) {
  final b = BytesBuilder();
  if (data.length < 0x4c) {
    b.addByte(data.length);
  } else if (data.length <= 0xff) {
    b.addByte(0x4c);
    b.addByte(data.length);
  } else {
    b.addByte(0x4d);
    b.add(_u16le(data.length));
  }
  b.add(data);
  return b.toBytes();
}

/// P2PKH scriptPubKey for a base58check address.
Uint8List p2pkhScript(String address) {
  final decoded = _base58Decode(address);
  if (decoded.length != 25) throw BtcTxException('bad_address', 'length ${decoded.length}');
  // Verify checksum.
  final body = decoded.sublist(0, 21);
  final check = decoded.sublist(21);
  final calc = _dsha256(body).sublist(0, 4);
  for (var i = 0; i < 4; i++) {
    if (check[i] != calc[i]) throw BtcTxException('bad_address', 'checksum');
  }
  final pubKeyHash = decoded.sublist(1, 21);
  final b = BytesBuilder();
  b.addByte(0x76); // OP_DUP
  b.addByte(0xa9); // OP_HASH160
  b.add(_push(pubKeyHash));
  b.addByte(0x88); // OP_EQUALVERIFY
  b.addByte(0xac); // OP_CHECKSIG
  return b.toBytes();
}

/// Fetch confirmed+unconfirmed UTXOs for an address from Blockstream.
Future<List<BtcUtxo>> fetchUtxos(String address) async {
  final resp = await http.get(Uri.parse('https://blockstream.info/api/address/$address/utxo'));
  if (resp.statusCode != 200) throw BtcTxException('utxo_unavailable', '${resp.statusCode}');
  final list = jsonDecode(resp.body) as List;
  final script = p2pkhScript(address);
  return list.map((e) {
    final m = e as Map<String, dynamic>;
    return BtcUtxo(
      txid: m['txid'] as String,
      vout: (m['vout'] as num).toInt(),
      value: (m['value'] as num).toInt(),
      scriptPubKey: script,
    );
  }).toList();
}

/// Fee rate estimate in sat/vB (6-block target, fallback 10).
Future<int> feeRateSatVb() async {
  try {
    final resp = await http.get(Uri.parse('https://blockstream.info/api/fee-estimates'))
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode == 200) {
      final m = jsonDecode(resp.body) as Map<String, dynamic>;
      final r = (m['6'] as num?)?.toDouble() ?? 10;
      return r.ceil().clamp(1, 500);
    }
  } catch (_) {}
  return 10;
}

/// Serialize one input for sighash (script = prevout scriptPubKey or empty).
Uint8List _serInput(BtcUtxo u, Uint8List script, int sequence) {
  final b = BytesBuilder();
  // txid little-endian on the wire
  final txidBytes = _hexToBytes(u.txid);
  b.add(txidBytes.reversed.toList());
  b.add(_u32le(u.vout));
  b.add(_varInt(script.length));
  b.add(script);
  b.add(_u32le(sequence));
  return b.toBytes();
}

Uint8List _serOutput(int valueSat, Uint8List scriptPubKey) {
  final b = BytesBuilder();
  b.add(_u64le(valueSat));
  b.add(_varInt(scriptPubKey.length));
  b.add(scriptPubKey);
  return b.toBytes();
}

/// Build, sign (SIGHASH_ALL) and serialize a P2PKH transaction.
/// Returns the raw transaction hex.
String buildSignedP2pkh({
  required List<BtcUtxo> inputs,
  required List<MapEntry<int, Uint8List>> outputs, // value sat -> scriptPubKey
  required String privHex,
  int locktime = 0,
}) {
  final domain = ECDomainParameters('secp256k1');
  final privInt = BigInt.parse(privHex, radix: 16);
  if (privInt <= BigInt.zero || privInt >= domain.n) {
    throw BtcTxException('bad_key');
  }
  final pubPoint = domain.G * privInt;
  final pubCompressed = pubPoint!.getEncoded(true);

  const sequence = 0xffffffff;
  const hashType = 1; // SIGHASH_ALL

  // Sign each input.
  final scriptSigs = <Uint8List>[];
  for (var i = 0; i < inputs.length; i++) {
    final b = BytesBuilder();
    b.add(_u32le(2)); // version
    b.add(_varInt(inputs.length));
    for (var j = 0; j < inputs.length; j++) {
      b.add(_serInput(inputs[j], j == i ? inputs[j].scriptPubKey : Uint8List(0), sequence));
    }
    b.add(_varInt(outputs.length));
    for (final o in outputs) {
      b.add(_serOutput(o.key, o.value));
    }
    b.add(_u32le(locktime));
    b.add(_u32le(hashType));
    final hash = _dsha256(b.toBytes());

    // RFC 6979 deterministic ECDSA over the raw sighash (no extra hashing).
    final signer = ECDSASigner(_NullDigest(), HMac(SHA256Digest(), 64));
    signer.init(true, PrivateKeyParameter(ECPrivateKey(privInt, domain)));
    final sig = signer.generateSignature(hash) as ECSignature;
    // Low-S normalization (BIP 62).
    final n = domain.n;
    final s = sig.s > (n >> 1) ? n - sig.s : sig.s;
    final der = _derEncode(sig.r, s);
    final sigWithType = Uint8List.fromList([...der, hashType]);

    final sb = BytesBuilder();
    sb.add(_push(sigWithType));
    sb.add(_push(pubCompressed));
    scriptSigs.add(sb.toBytes());
  }

  // Final serialization.
  final b = BytesBuilder();
  b.add(_u32le(2));
  b.add(_varInt(inputs.length));
  for (var i = 0; i < inputs.length; i++) {
    final u = inputs[i];
    final txidBytes = _hexToBytes(u.txid);
    b.add(txidBytes.reversed.toList());
    b.add(_u32le(u.vout));
    b.add(_varInt(scriptSigs[i].length));
    b.add(scriptSigs[i]);
    b.add(_u32le(sequence));
  }
  b.add(_varInt(outputs.length));
  for (final o in outputs) {
    b.add(_serOutput(o.key, o.value));
  }
  b.add(_u32le(locktime));
  return _hexOf(b.toBytes());
}

/// Broadcast a raw tx hex via Blockstream. Returns the txid.
Future<String> broadcastTx(String rawHex) async {
  final resp = await http.post(
    Uri.parse('https://blockstream.info/api/tx'),
    headers: {'Content-Type': 'text/plain'},
    body: rawHex,
  );
  if (resp.statusCode != 200) {
    throw BtcTxException('broadcast_failed', resp.body.substring(0, resp.body.length.clamp(0, 200)));
  }
  return resp.body.trim();
}

/// High-level BTC send: select UTXOs, build, sign, broadcast. Returns txid.
Future<String> sendBtcTx({
  required String fromAddress,
  required String privHex,
  required String toAddress,
  required int amountSat,
  int? feeRateSatVbOverride,
}) async {
  if (amountSat <= 0) throw BtcTxException('bad_amount');
  // Validate destination.
  final toScript = p2pkhScript(toAddress);

  final utxos = await fetchUtxos(fromAddress);
  if (utxos.isEmpty) throw BtcTxException('no_utxos');

  final rate = feeRateSatVbOverride ?? await feeRateSatVb();

  // Greedy coin selection (largest first).
  final sorted = [...utxos]..sort((a, b) => b.value.compareTo(a.value));
  final selected = <BtcUtxo>[];
  var total = 0;
  // Estimate: 148 vB/input, 34 vB/output (2 outputs: payment + change), +10 overhead.
  for (final u in sorted) {
    selected.add(u);
    total += u.value;
    final vsize = 10 + selected.length * 148 + 2 * 34;
    final fee = vsize * rate;
    if (total >= amountSat + fee) break;
  }
  final vsize = 10 + selected.length * 148 + 2 * 34;
  final fee = vsize * rate;
  if (total < amountSat + fee) throw BtcTxException('insufficient_funds');

  const dust = 546;
  final change = total - amountSat - fee;
  final outputs = <MapEntry<int, Uint8List>>[
    MapEntry(amountSat, toScript),
  ];
  if (change >= dust) {
    outputs.add(MapEntry(change, p2pkhScript(fromAddress)));
  }
  // else: change below dust is added to the fee.

  final rawHex = buildSignedP2pkh(
    inputs: selected,
    outputs: outputs,
    privHex: privHex,
  );
  return broadcastTx(rawHex);
}
