// Threefish-1024 分组密码 + Skein-1024 纯哈希（S.S.E. File Encryptor v4 密码链专用）。
//
// 移植自 BouncyCastle 的 ThreefishEngine / SkeinEngine（Skein 1.3 / Threefish 1.3，
// 与 PFTE 内嵌的 sse.org.bouncycastle 版本逐行对应）。仅实现 UBI/加密所需路径：
// Threefish-1024 只做加密方向；Skein 只做无 key 纯哈希（HMAC 的 key 处理在
// pointycastle HMac 通用层完成，无需 Skein 自带 key 参数）。
//
// 数值语义：Dart VM int = 64 位有符号补码，加/减/乘/移位溢出行为与 Java long 一致；
// Java `x >>> -n`（负数位移 = 64-n）在 Dart 中非法，统一改写为显式 `x >>> (64 - n)`。
//
// 验证：dev_probe/enc_probe/ 探针跑 Skein-1024-512 空消息官方向量。
library;

import 'dart:typed_data';

import 'package:pointycastle/api.dart' show Digest;

/// Threefish-1024（仅加密方向，供 Skein UBI 使用）。
class Threefish1024Engine {
  static const int _rounds = 80; // Threefish-1024 = 80 轮
  static const int _c240 = 0x1BD11BDAA9FC1A22; // key schedule 奇偶常量

  // Skein 1.3 规范的 8 轮旋转常数（_rotation[d][j]：第 d 组、第 j 对）。
  static const List<List<int>> _rotation = [
    [24, 13, 8, 47, 8, 17, 22, 37],
    [38, 19, 10, 55, 49, 18, 23, 52],
    [33, 4, 51, 13, 34, 41, 59, 17],
    [5, 20, 48, 41, 47, 28, 16, 25],
    [41, 9, 37, 31, 12, 47, 44, 30],
    [16, 34, 56, 51, 4, 53, 42, 41],
    [31, 44, 47, 46, 19, 42, 44, 25],
    [9, 48, 35, 52, 23, 31, 37, 20],
  ];

  final Int64List _kw = Int64List(33); // 16 子密钥 + 扩展位 + 重复
  final Int64List _t = Int64List(5); // tweak 扩展 3 词 + 重复

  /// 设置密钥（16 词）并展开 key schedule。
  void setKey(Int64List key) {
    assert(key.length == 16);
    var knw = _c240;
    for (var i = 0; i < 16; i++) {
      _kw[i] = key[i];
      knw ^= _kw[i];
    }
    _kw[16] = knw;
    for (var i = 0; i < 16; i++) {
      _kw[17 + i] = _kw[i];
    }
  }

  /// 设置 tweak（2 词，128 bit）。
  void setTweak(Int64List tweak) {
    assert(tweak.length == 2);
    _t[0] = tweak[0];
    _t[1] = tweak[1];
    _t[2] = _t[0] ^ _t[1];
    _t[3] = _t[0];
    _t[4] = _t[1];
  }

  /// 加密一个 16 词块（block 与 out 不可为同一对象）。
  void processBlock(Int64List block, Int64List out) {
    final kw = _kw;
    final t = _t;

    var b0 = block[0], b1 = block[1], b2 = block[2], b3 = block[3];
    var b4 = block[4], b5 = block[5], b6 = block[6], b7 = block[7];
    var b8 = block[8], b9 = block[9], b10 = block[10], b11 = block[11];
    var b12 = block[12], b13 = block[13], b14 = block[14], b15 = block[15];

    // 首次子密钥注入。
    b0 += kw[0];
    b1 += kw[1];
    b2 += kw[2];
    b3 += kw[3];
    b4 += kw[4];
    b5 += kw[5];
    b6 += kw[6];
    b7 += kw[7];
    b8 += kw[8];
    b9 += kw[9];
    b10 += kw[10];
    b11 += kw[11];
    b12 += kw[12];
    b13 += kw[13] + t[0];
    b14 += kw[14] + t[1];
    b15 += kw[15];

    // 80 轮 = 10 × 8 轮展开（d 从 1 起每 4 轮注入一次子密钥）。
    for (var d = 1; d < _rounds ~/ 4; d += 2) {
      final dm17 = d % 17;
      final dm3 = d % 3;
      final r0 = _rotation[0], r1 = _rotation[1];
      final r2 = _rotation[2], r3 = _rotation[3];
      final r4 = _rotation[4], r5 = _rotation[5];
      final r6 = _rotation[6], r7 = _rotation[7];

      // 4 轮 mix + permute（permute 周期 4 轮，直接内联）。
      b1 = _rotlXor(b1, r0[0], b0 += b1);
      b3 = _rotlXor(b3, r0[1], b2 += b3);
      b5 = _rotlXor(b5, r0[2], b4 += b5);
      b7 = _rotlXor(b7, r0[3], b6 += b7);
      b9 = _rotlXor(b9, r0[4], b8 += b9);
      b11 = _rotlXor(b11, r0[5], b10 += b11);
      b13 = _rotlXor(b13, r0[6], b12 += b13);
      b15 = _rotlXor(b15, r0[7], b14 += b15);

      b9 = _rotlXor(b9, r1[0], b0 += b9);
      b13 = _rotlXor(b13, r1[1], b2 += b13);
      b11 = _rotlXor(b11, r1[2], b6 += b11);
      b15 = _rotlXor(b15, r1[3], b4 += b15);
      b7 = _rotlXor(b7, r1[4], b10 += b7);
      b3 = _rotlXor(b3, r1[5], b12 += b3);
      b5 = _rotlXor(b5, r1[6], b14 += b5);
      b1 = _rotlXor(b1, r1[7], b8 += b1);

      b7 = _rotlXor(b7, r2[0], b0 += b7);
      b5 = _rotlXor(b5, r2[1], b2 += b5);
      b3 = _rotlXor(b3, r2[2], b4 += b3);
      b1 = _rotlXor(b1, r2[3], b6 += b1);
      b15 = _rotlXor(b15, r2[4], b12 += b15);
      b13 = _rotlXor(b13, r2[5], b14 += b13);
      b11 = _rotlXor(b11, r2[6], b8 += b11);
      b9 = _rotlXor(b9, r2[7], b10 += b9);

      b15 = _rotlXor(b15, r3[0], b0 += b15);
      b11 = _rotlXor(b11, r3[1], b2 += b11);
      b13 = _rotlXor(b13, r3[2], b6 += b13);
      b9 = _rotlXor(b9, r3[3], b4 += b9);
      b1 = _rotlXor(b1, r3[4], b14 += b1);
      b5 = _rotlXor(b5, r3[5], b8 += b5);
      b3 = _rotlXor(b3, r3[6], b10 += b3);
      b7 = _rotlXor(b7, r3[7], b12 += b7);

      // 子密钥注入（4 轮后）。
      b0 += kw[dm17];
      b1 += kw[dm17 + 1];
      b2 += kw[dm17 + 2];
      b3 += kw[dm17 + 3];
      b4 += kw[dm17 + 4];
      b5 += kw[dm17 + 5];
      b6 += kw[dm17 + 6];
      b7 += kw[dm17 + 7];
      b8 += kw[dm17 + 8];
      b9 += kw[dm17 + 9];
      b10 += kw[dm17 + 10];
      b11 += kw[dm17 + 11];
      b12 += kw[dm17 + 12];
      b13 += kw[dm17 + 13] + t[dm3];
      b14 += kw[dm17 + 14] + t[dm3 + 1];
      b15 += kw[dm17 + 15] + d;

      // 4 轮 mix + permute。
      b1 = _rotlXor(b1, r4[0], b0 += b1);
      b3 = _rotlXor(b3, r4[1], b2 += b3);
      b5 = _rotlXor(b5, r4[2], b4 += b5);
      b7 = _rotlXor(b7, r4[3], b6 += b7);
      b9 = _rotlXor(b9, r4[4], b8 += b9);
      b11 = _rotlXor(b11, r4[5], b10 += b11);
      b13 = _rotlXor(b13, r4[6], b12 += b13);
      b15 = _rotlXor(b15, r4[7], b14 += b15);

      b9 = _rotlXor(b9, r5[0], b0 += b9);
      b13 = _rotlXor(b13, r5[1], b2 += b13);
      b11 = _rotlXor(b11, r5[2], b6 += b11);
      b15 = _rotlXor(b15, r5[3], b4 += b15);
      b7 = _rotlXor(b7, r5[4], b10 += b7);
      b3 = _rotlXor(b3, r5[5], b12 += b3);
      b5 = _rotlXor(b5, r5[6], b14 += b5);
      b1 = _rotlXor(b1, r5[7], b8 += b1);

      b7 = _rotlXor(b7, r6[0], b0 += b7);
      b5 = _rotlXor(b5, r6[1], b2 += b5);
      b3 = _rotlXor(b3, r6[2], b4 += b3);
      b1 = _rotlXor(b1, r6[3], b6 += b1);
      b15 = _rotlXor(b15, r6[4], b12 += b15);
      b13 = _rotlXor(b13, r6[5], b14 += b13);
      b11 = _rotlXor(b11, r6[6], b8 += b11);
      b9 = _rotlXor(b9, r6[7], b10 += b9);

      b15 = _rotlXor(b15, r7[0], b0 += b15);
      b11 = _rotlXor(b11, r7[1], b2 += b11);
      b13 = _rotlXor(b13, r7[2], b6 += b13);
      b9 = _rotlXor(b9, r7[3], b4 += b9);
      b1 = _rotlXor(b1, r7[4], b14 += b1);
      b5 = _rotlXor(b5, r7[5], b8 += b5);
      b3 = _rotlXor(b3, r7[6], b10 += b3);
      b7 = _rotlXor(b7, r7[7], b12 += b7);

      // 子密钥注入（8 轮后）。
      b0 += kw[dm17 + 1];
      b1 += kw[dm17 + 2];
      b2 += kw[dm17 + 3];
      b3 += kw[dm17 + 4];
      b4 += kw[dm17 + 5];
      b5 += kw[dm17 + 6];
      b6 += kw[dm17 + 7];
      b7 += kw[dm17 + 8];
      b8 += kw[dm17 + 9];
      b9 += kw[dm17 + 10];
      b10 += kw[dm17 + 11];
      b11 += kw[dm17 + 12];
      b12 += kw[dm17 + 13];
      b13 += kw[dm17 + 14] + t[dm3 + 1];
      b14 += kw[dm17 + 15] + t[dm3 + 2];
      b15 += kw[dm17 + 16] + d + 1;
    }

    out[0] = b0;
    out[1] = b1;
    out[2] = b2;
    out[3] = b3;
    out[4] = b4;
    out[5] = b5;
    out[6] = b6;
    out[7] = b7;
    out[8] = b8;
    out[9] = b9;
    out[10] = b10;
    out[11] = b11;
    out[12] = b12;
    out[13] = b13;
    out[14] = b14;
    out[15] = b15;
  }

  /// rotate-left 后与 xor 项异或：((x << n) | (x >>> (64-n))) ^ xor。
  static int _rotlXor(int x, int n, int xor) =>
      ((x << n) | (x >>> (64 - n))) ^ xor;

  /// 64 bit word 读取（LSB first）。
  static int bytesToWord(Uint8List bytes, int off) {
    var word = 0;
    for (var i = 7; i >= 0; i--) {
      word = (word << 8) | (bytes[off + i] & 0xff);
    }
    return word;
  }

  /// 64 bit word 写出（LSB first）。
  static void wordToBytes(int word, Uint8List bytes, int off) {
    for (var i = 0; i < 8; i++) {
      bytes[off + i] = (word >> (8 * i)) & 0xff;
    }
  }
}

/// Skein-1024 纯哈希（无 key、无个性化参数），输出任意 ≤128 字节。
///
/// 链路：空初始态 → UBI(CFG)（配置块 32B：'SHA3' + v1 + 输出位长）→ UBI(MSG) →
/// 输出变换 UBI(OUT, 计数器)。Skein-1024 没有预计算初始态表项（BC 仅预计算
/// 256/512 变体），因此永远走「空态 + 配置块」路径。
class Skein1024Digest implements Digest {
  static const int _blockSize = 128; // 1024 bit = 128 字节
  static const int _paramTypeConfig = 4;
  static const int _paramTypeMessage = 48;
  static const int _paramTypeOutput = 63;

  // UBI tweak 常量（bit 126 = first，bit 127 = final，均位于 tweak[1]）。
  static const int _t1First = 1 << 62;
  static const int _t1Final = 1 << 63;

  final Threefish1024Engine _threefish = Threefish1024Engine();
  final int outputSizeBytes;

  final Int64List _chain = Int64List(16); // 链值
  late final Int64List _initialState; // 重置基准（配置块处理完后的链值）

  // UBI 消息缓冲。
  final Uint8List _currentBlock = Uint8List(_blockSize);
  int _currentOffset = 0;
  final Int64List _message = Int64List(16);
  final Int64List _tweak = Int64List(2);

  Skein1024Digest({this.outputSizeBytes = 128}) {
    assert(outputSizeBytes > 0 && outputSizeBytes <= _blockSize);
    _processConfigBlock();
    _initialState = Int64List.fromList(_chain);
    _ubiInitMessage();
  }

  int get digestSize => outputSizeBytes;
  int get byteLength => _blockSize;
  String get algorithmName => 'Skein-1024/$outputSizeBytes';

  /// 构造配置块并做 UBI(CFG)：'SHA3' ASCII + LSB 版本(1,0) + LSB 输出位长。
  void _processConfigBlock() {
    final config = Uint8List(32);
    config[0] = 0x53; // 'S'
    config[1] = 0x48; // 'H'
    config[2] = 0x41; // 'A'
    config[3] = 0x33; // '3'
    config[4] = 1; // version LSB
    config[5] = 0; // version MSB
    Threefish1024Engine.wordToBytes(outputSizeBytes * 8, config, 8);

    // 链值初始为全 0，直接跑一次完整 UBI（type=4 配置块）。
    _ubiStart(_paramTypeConfig);
    _ubiUpdate(config, 0, config.length);
    _ubiFinish();
  }

  void _ubiInitMessage() {
    _ubiStart(_paramTypeMessage);
  }

  /// 重置 tweak：type 写入 bits 120..125（tweak[1] 的 56..61），first 标志置位。
  void _ubiStart(int type) {
    _tweak[0] = 0;
    _tweak[1] = _t1First | ((type & 0x3f) << 56);
    _currentOffset = 0;
  }

  void _advancePosition(int advance) {
    _tweak[0] += advance; // 64 bit 位置（≥2^64 场景不会出现在本项目数据量内）
  }

  /// 处理一个已填满的块：out = E(chain, tweak) ^ message。
  void _processBlock(Int64List out) {
    _threefish.setKey(_chain);
    _threefish.setTweak(_tweak);
    for (var i = 0; i < 16; i++) {
      _message[i] = Threefish1024Engine.bytesToWord(_currentBlock, i * 8);
    }
    _threefish.processBlock(_message, out);
    for (var i = 0; i < 16; i++) {
      out[i] ^= _message[i];
    }
  }

  void _ubiUpdate(Uint8List value, int offset, int len) {
    var copied = 0;
    while (len > copied) {
      if (_currentOffset == _blockSize) {
        _processBlock(_chain);
        _tweak[1] &= ~_t1First; // first 块处理完毕
        _currentOffset = 0;
      }
      final toCopy =
          (len - copied) < (_blockSize - _currentOffset)
              ? (len - copied)
              : (_blockSize - _currentOffset);
      _currentBlock.setRange(_currentOffset, _currentOffset + toCopy,
          value, offset + copied);
      copied += toCopy;
      _currentOffset += toCopy;
      _advancePosition(toCopy);
    }
  }

  /// 终结当前 UBI：补零 + final 标志 + 处理最后一块。
  void _ubiFinish() {
    for (var i = _currentOffset; i < _blockSize; i++) {
      _currentBlock[i] = 0;
    }
    _tweak[1] |= _t1Final;
    _processBlock(_chain);
  }

  void update(Uint8List inp, int inpOff, int len) {
    _ubiUpdate(inp, inpOff, len);
  }

  @override
  void updateByte(int inp) {
    _ubiUpdate(Uint8List.fromList([inp & 0xff]), 0, 1);
  }

  @override
  Uint8List process(Uint8List data) {
    final out = Uint8List(outputSizeBytes);
    update(data, 0, data.length);
    doFinal(out, 0);
    return out;
  }

  /// 输出哈希并复位到初始状态。
  int doFinal(Uint8List out, int outOff) {
    // 终结消息 UBI（final=true）。
    for (var i = _currentOffset; i < _blockSize; i++) {
      _currentBlock[i] = 0;
    }
    _tweak[1] |= _t1Final;
    _processBlock(_chain);

    // 输出变换：UBI(OUTPUT, counter) 使用并保留 pre-output 链值。
    final outputWords = Int64List(16);
    final counterBytes = Uint8List(8); // 128B 输出 ≤ 1 块，counter = 0
    _ubiStart(_paramTypeOutput);
    _ubiUpdate(counterBytes, 0, counterBytes.length);
    for (var i = _currentOffset; i < _blockSize; i++) {
      _currentBlock[i] = 0;
    }
    _tweak[1] |= _t1Final;
    _processBlock(outputWords);

    Threefish1024Engine.wordToBytes(outputWords[0], out, outOff);
    var toWrite = outputSizeBytes < 8 ? outputSizeBytes : 8;
    for (var i = 1; i * 8 < outputSizeBytes; i++) {
      final w = outputWords[i];
      final remain = outputSizeBytes - i * 8;
      toWrite = remain < 8 ? remain : 8;
      for (var j = 0; j < toWrite; j++) {
        out[outOff + i * 8 + j] = (w >> (8 * j)) & 0xff;
      }
    }

    // 复位到初始态（配置块后的链值）。
    _chain.setAll(0, _initialState);
    _ubiInitMessage();
    return outputSizeBytes;
  }

  void reset() {
    _chain.setAll(0, _initialState);
    _ubiInitMessage();
  }
}
