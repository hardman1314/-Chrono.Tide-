/// SHA-256（FIPS 180-4）与 HMAC-SHA256（RFC 2104）—— 纯 Dart 实现。
///
/// 🔴 为什么自实现：S3 SigV4 签名需要 HMAC-SHA256，但 pubspec 没有 crypto
/// 包；为避免为一个签名算法引入依赖（pubspec 变更 → pub get 风险），在
/// cloud_backup 内部自带实现。dev_probe 用 NIST / RFC 4231 官方测试向量
/// 逐字节验证（`dev_probe/phase5_sha_probe.dart`）。
///
/// ⛔ 本文件必须零外部依赖（dart:typed_data 即可），与 cloud_backup 目录
/// 「无 flutter 依赖、探针可实测」的约定一致。
///
/// 用途边界：SigV4 的 canonical request / signing key 全是短字符串与
/// 32 字节链式 HMAC，性能足够。⛔ 不要拿它给大文件算哈希（用
/// `x-amz-content-sha256: UNSIGNED-PAYLOAD` 规避）。
library;

import 'dart:typed_data';

// ---------------------------------------------------------------------------
// SHA-256
// ---------------------------------------------------------------------------

const List<int> _k = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, //
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, //
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, //
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, //
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, //
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, //
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, //
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, //
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, //
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, //
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, //
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, //
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, //
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, //
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, //
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2, //
];

const List<int> _h0 = [
  0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19, //
];

int _rotr(int x, int n) => ((x >>> n) | (x << (32 - n))) & 0xffffffff;

/// SHA-256 摘要（32 字节）。
Uint8List sha256Bytes(List<int> data) {
  final bitLen = data.length * 8;
  // 填充后总长 = 向上取整到 64 的倍数（至少多一个 block 放 0x80 和长度）
  final paddedLen = ((data.length + 9) + 63) & ~63;
  final buf = Uint8List(paddedLen);
  buf.setRange(0, data.length, data);
  buf[data.length] = 0x80;
  final bd = ByteData.view(buf.buffer);
  bd.setUint64(paddedLen - 8, bitLen, Endian.big);

  final h = Uint32List.fromList(_h0);
  final w = Uint32List(64);

  for (var off = 0; off < paddedLen; off += 64) {
    for (var t = 0; t < 16; t++) {
      w[t] = bd.getUint32(off + t * 4, Endian.big);
    }
    for (var t = 16; t < 64; t++) {
      final s0 =
          _rotr(w[t - 15], 7) ^ _rotr(w[t - 15], 18) ^ (w[t - 15] >>> 3);
      final s1 = _rotr(w[t - 2], 17) ^ _rotr(w[t - 2], 19) ^ (w[t - 2] >>> 10);
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) & 0xffffffff;
    }

    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];

    for (var t = 0; t < 64; t++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final t1 = (hh + s1 + ch + _k[t] + w[t]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xffffffff;

      hh = g;
      g = f;
      f = e;
      e = (d + t1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xffffffff;
    }

    h[0] = (h[0] + a) & 0xffffffff;
    h[1] = (h[1] + b) & 0xffffffff;
    h[2] = (h[2] + c) & 0xffffffff;
    h[3] = (h[3] + d) & 0xffffffff;
    h[4] = (h[4] + e) & 0xffffffff;
    h[5] = (h[5] + f) & 0xffffffff;
    h[6] = (h[6] + g) & 0xffffffff;
    h[7] = (h[7] + hh) & 0xffffffff;
  }

  final out = Uint8List(32);
  final obd = ByteData.view(out.buffer);
  for (var i = 0; i < 8; i++) {
    obd.setUint32(i * 4, h[i], Endian.big);
  }
  return out;
}

/// SHA-256 的十六进制摘要（小写，64 字符）。
String sha256Hex(String text) => bytesToHex(sha256Bytes(text.codeUnits));

// ---------------------------------------------------------------------------
// HMAC-SHA256
// ---------------------------------------------------------------------------

/// HMAC-SHA256（RFC 2104）。key 任意长度（>64 字节先 hash，标准行为）。
Uint8List hmacSha256(List<int> key, List<int> msg) {
  var k = Uint8List.fromList(key);
  if (k.length > 64) k = sha256Bytes(k);

  final ipad = Uint8List(64);
  final opad = Uint8List(64);
  for (var i = 0; i < 64; i++) {
    final b = i < k.length ? k[i] : 0;
    ipad[i] = b ^ 0x36;
    opad[i] = b ^ 0x5c;
  }
  final innerInput = Uint8List(64 + msg.length);
  innerInput.setRange(0, 64, ipad);
  innerInput.setRange(64, 64 + msg.length, msg);
  final inner = sha256Bytes(innerInput);

  final outerInput = Uint8List(64 + 32);
  outerInput.setRange(0, 64, opad);
  outerInput.setRange(64, 96, inner);
  return sha256Bytes(outerInput);
}

// ---------------------------------------------------------------------------
// 辅助
// ---------------------------------------------------------------------------

String bytesToHex(Uint8List bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
