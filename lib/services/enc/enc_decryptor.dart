// S.S.E. File Encryptor v4（.enc）程序化解密器。
//
// 对应 PFTE（Paranoia Works Encryption Tools）SSE File Encryptor 1.8+ 的 v4 容器：
//   [0..7]    preamble 8B：'SSEFE' + version(=4) + algorithmCode + customParamsByte
//   [8..39]   salt 32B（明文，进 MAC 不进密钥派生之外的任何运算）
//   [40..71]  checkcode 32B（CTR 加密，明文为 a-z0-9 伪随机校验码）
//   [72..]    Zip64 容器密文
//   [末-31..] MAC 32B（Blake3 keyed；本实现跳过校验，完整性靠 zip CRC32 兜底）
//
// 密码链（v4，逐字节对齐 Encryptor.java）：
//   1. convertToCodePoints：ASCII 32-126 保留，其余字符 → 十进制码点数字串
//   2. UTF-8 编码
//   3. l0PWHashV3 = HKDF(HMAC-Skein1024/1024, ikm=pwb, salt='memorySalt', info='memoryInfo', 256B)
//   4. argonOutput = Argon2id(P=l0PWHashV3, salt, t=10·2^tm, m=10240·2^mm KiB, p=4, 256B)
//      （tm = customParamsByte 低 4 位，mm = 高 4 位；文件头默认 0x11 → t=20, m=20480）
//   5. encKey  = HKDF-SHA3-512(argonOutput, 'encKeySalt',  'encKeyInfo',  keyLen=32)
//      nonce   = HKDF-SHA3-512(argonOutput, 'nonceSalt',   'nonceInfo',   blkLen=16)
//      authKey = HKDF-SHA3-512(argonOutput, 'authKeySalt', 'authKeyInfo', 32)（解密侧不校验 MAC，不用）
//   6. CTR：计数器从 nonce 起、大端连续递增；checkcode 段占 keystream block 0-1，
//      zip 密文自 block 2 续接（CheckCodeParserInputStream 为透传流，无独立计数器重置）
//   7. checkcode 解密后必须全部 ∈ [a-z0-9]，否则判密码错误（官方快速密码验证逻辑）
//
// 一期算法支持：code 0 = AES-256（SSE File Encryptor 默认算法）。其余算法码
// （RC6/Serpent/Twofish/Blowfish/GOST/Threefish/SHACAL2/C4 复合）抛不支持异常。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'skein_threefish.dart';

/// .enc 格式/版本/算法异常（明文提示用户）。
class EncFormatException implements Exception {
  final String message;
  EncFormatException(this.message);
  @override
  String toString() => message;
}

/// 密码错误（checkcode 快速验证未通过）。
class EncWrongPasswordException implements Exception {
  final String message;
  EncWrongPasswordException([this.message = '解压密码不正确']);
  @override
  String toString() => message;
}

class EncDecryptor {
  static const int _headerSize = 8;
  static const int _saltSize = 32;
  static const int _checkCodeSize = 32;
  static const int _macSize = 32;

  /// 宽松识别：前 5 字节 == 'SSEFE'（v4 头固定前缀）。
  static bool looksLikeEnc(Uint8List head) {
    if (head.length < 5) return false;
    const prefix = [0x53, 0x53, 0x45, 0x46, 0x45]; // 'SSEFE'
    for (var i = 0; i < 5; i++) {
      if (head[i] != prefix[i]) return false;
    }
    return true;
  }

  /// 解密 .enc → 标准 zip 文件（后续走项目既有 zip 解压链）。
  ///
  /// [onProgress] 进度 0.0-1.0（仅按 KDF 完成 + 数据段位置粗粒度回调）。
  static Future<void> decrypt({
    required String encPath,
    required String outputZipPath,
    required String password,
    void Function(double progress)? onProgress,
  }) async {
    final f = File(encPath);
    if (!f.existsSync()) {
      throw EncFormatException('.enc 文件不存在：$encPath');
    }
    final raf = await f.open();
    try {
      final fileSize = await f.length();
      if (fileSize < _headerSize + _saltSize + _checkCodeSize + _macSize) {
        throw EncFormatException('.enc 文件过小，不是有效的 v4 加密文件');
      }

      // ---- 头解析 ----
      final preamble = Uint8List.sublistView(
          await raf.read(_headerSize));
      if (!looksLikeEnc(preamble)) {
        throw EncFormatException('文件头不是 SSEFE（非 .enc 加密文件）');
      }
      final version = preamble[5];
      if (version != 4) {
        throw EncFormatException(
            '暂不支持 .enc 格式版本 $version（当前支持 v4，SSE 1.8+ 默认）');
      }
      final algorithmCode = preamble[6];
      if (algorithmCode != 0) {
        throw EncFormatException(
            '暂不支持加密算法代码 $algorithmCode（当前仅支持 AES-256，即 SSE 默认算法）');
      }
      final customParamsByte = preamble[7];
      final salt = Uint8List.fromList(await raf.read(_saltSize));

      // ---- 密码链 ----
      onProgress?.call(0.02);
      final (encKey, nonce) = _deriveKeys(
          password, salt, customParamsByte);

      // ---- CTR 流式解密 ----
      // 密文区 = [40, fileSize - 32)：checkcode 段 32B + zip 段；尾部 32B MAC 原样丢弃。
      final cipherLen = fileSize - _headerSize - _saltSize - _macSize;
      final counter = Uint8List.fromList(nonce); // 连续大端计数器
      final aes = AESEngine()..init(true, KeyParameter(encKey));
      final keystream = Uint8List(16);
      final out = File(outputZipPath).openSync(mode: FileMode.write);
      try {
        // 段 1：checkcode（快速密码验证，失败即中断，不写盘）。
        final ccCipher = Uint8List.fromList(await raf.read(_checkCodeSize));
        final checkCode = _ctrXor(aes, ccCipher, counter, keystream);
        for (final c in checkCode) {
          final isOk = (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39);
          if (!isOk) {
            throw EncWrongPasswordException();
          }
        }

        // 段 2：zip 密文，64KB 缓冲流式解密落盘。
        const bufSize = 65536;
        final buf = Uint8List(bufSize);
        var remaining = cipherLen - _checkCodeSize;
        var done = 0;
        while (remaining > 0) {
          final want = remaining < bufSize ? remaining : bufSize;
          final got = await raf.readInto(buf, 0, want);
          if (got <= 0) {
            throw EncFormatException('.enc 文件提前截断（数据段不完整）');
          }
          final plain = _ctrXor(
              aes, Uint8List.sublistView(buf, 0, got), counter, keystream);
          out.writeFromSync(plain, 0, got);
          remaining -= got;
          done += got;
          onProgress?.call(0.05 + 0.95 * done / (cipherLen - _checkCodeSize));
        }
      } finally {
        out.flushSync();
        out.closeSync();
      }
      onProgress?.call(1.0);
    } finally {
      await raf.close();
    }
  }

  /// 单次 AES-CTR 异或：就地解密 [data]，按 16B 块推进 [counter]（大端 +1）。
  static Uint8List _ctrXor(AESEngine aes, Uint8List data,
      Uint8List counter, Uint8List keystream) {
    final out = Uint8List(data.length);
    var off = 0;
    while (off < data.length) {
      aes.processBlock(counter, 0, keystream, 0);
      final n =
          (data.length - off) < 16 ? (data.length - off) : 16;
      for (var i = 0; i < n; i++) {
        out[off + i] = data[off + i] ^ keystream[i];
      }
      off += n;
      // 大端 +1（进位链）。
      for (var i = counter.length - 1; i >= 0; i--) {
        final v = (counter[i] + 1) & 0xff;
        counter[i] = v;
        if (v != 0) break;
      }
    }
    return out;
  }

  /// 密码 → (encKey, nonce)。完整 KDF 链，见文件头注释。
  static (Uint8List, Uint8List) _deriveKeys(
      String password, Uint8List salt, int customParamsByte) {
    // 1-2. 码点转换 + UTF-8。
    final pwb = utf8.encode(_convertToCodePoints(password));

    // 3. l0PWHashV3 = HKDF(Skein1024 HMAC)：256B 主密钥。
    final l0 = _hkdf(
      digest: Skein1024Digest(outputSizeBytes: 128),
      hmacBlockLength: 128,
      ikm: Uint8List.fromList(pwb),
      salt: Uint8List.fromList(utf8.encode('memorySalt')),
      info: Uint8List.fromList(utf8.encode('memoryInfo')),
      outLen: 256,
    );

    // 4. Argon2id：t = 10·2^tm（低 4 位），m = 10240·2^mm KiB（高 4 位），p=4，256B 输出。
    final tm = customParamsByte & 0x0f;
    final mm = (customParamsByte >> 4) & 0x0f;
    final argon = Argon2BytesGenerator()
      ..init(Argon2Parameters(
        Argon2Parameters.ARGON2_id,
        salt,
        desiredKeyLength: 256,
        iterations: 10 * (1 << tm),
        memory: 10240 * (1 << mm),
        lanes: 4,
        version: Argon2Parameters.ARGON2_VERSION_13,
      ));
    final argonOutput = Uint8List(256);
    argon.deriveKey(l0, 0, argonOutput, 0);

    // 5. HKDF-SHA3-512 三段切分（authKey 不需要——解密侧跳过 Blake3 MAC）。
    final encKey = _hkdf(
      digest: SHA3Digest(512),
      hmacBlockLength: 72,
      ikm: argonOutput,
      salt: Uint8List.fromList(utf8.encode('encKeySalt')),
      info: Uint8List.fromList(utf8.encode('encKeyInfo')),
      outLen: 32,
    );
    final nonce = _hkdf(
      digest: SHA3Digest(512),
      hmacBlockLength: 72,
      ikm: argonOutput,
      salt: Uint8List.fromList(utf8.encode('nonceSalt')),
      info: Uint8List.fromList(utf8.encode('nonceInfo')),
      outLen: 16,
    );
    return (encKey, nonce);
  }

  /// RFC 5869 HKDF（extract + expand），与 BC HKDFBytesGenerator 语义一致。
  ///
  /// 手写实现：pointycastle 的 HKDFKeyDerivator 按算法名查块长表，
  /// Skein-1024 不在表内会直接崩，故自带。
  static Uint8List _hkdf({
    required Digest digest,
    required int hmacBlockLength,
    required Uint8List ikm,
    required Uint8List salt,
    required Uint8List info,
    required int outLen,
  }) {
    final hmac = HMac(digest, hmacBlockLength);

    // extract：PRK = HMAC(salt 或 hashLen 个 0, IKM)。
    hmac.init(
        KeyParameter(salt.isEmpty ? Uint8List(hmac.macSize) : salt));
    hmac.update(ikm, 0, ikm.length);
    final prk = Uint8List(hmac.macSize);
    hmac.doFinal(prk, 0);

    // expand：T(i) = HMAC(PRK, T(i-1) || info || i)。
    final out = Uint8List(outLen);
    var t = Uint8List(0);
    var pos = 0;
    var counter = 1;
    while (pos < outLen) {
      final input = Uint8List(t.length + info.length + 1);
      input.setRange(0, t.length, t);
      input.setRange(t.length, t.length + info.length, info);
      input[input.length - 1] = counter & 0xff;
      hmac.init(KeyParameter(prk));
      hmac.update(input, 0, input.length);
      t = Uint8List(hmac.macSize);
      hmac.doFinal(t, 0);
      final n = (outLen - pos) < t.length ? (outLen - pos) : t.length;
      out.setRange(pos, pos + n, t);
      pos += n;
      counter++;
    }
    return out;
  }

  /// 密码 → 码点串：ASCII 32-126 保留，其余字符 → 十进制码点数字（无分隔符）。
  /// 对应 Encryptor.convertToCodePoints（'contraseña' → 'contrase241a'）。
  static String _convertToCodePoints(String text) {
    final sb = StringBuffer();
    for (final rune in text.runes) {
      if (rune > 126 || rune < 32) {
        sb.write(rune); // 十进制码点
      } else {
        sb.writeCharCode(rune);
      }
    }
    return sb.toString();
  }

  // ---- 探针调试钩子（dev_probe/enc_probe 往返验证复用同一份实现，防双份漂移）----

  static String debugToCodePoints(String text) => _convertToCodePoints(text);

  static Uint8List debugHkdfSkein(Uint8List ikm) => _hkdf(
        digest: Skein1024Digest(outputSizeBytes: 128),
        hmacBlockLength: 128,
        ikm: ikm,
        salt: Uint8List.fromList(utf8.encode('memorySalt')),
        info: Uint8List.fromList(utf8.encode('memoryInfo')),
        outLen: 256,
      );

  static Uint8List debugHkdfSha3(
          Uint8List ikm, String salt, String info, int outLen) =>
      _hkdf(
        digest: SHA3Digest(512),
        hmacBlockLength: 72,
        ikm: ikm,
        salt: Uint8List.fromList(utf8.encode(salt)),
        info: Uint8List.fromList(utf8.encode(info)),
        outLen: outLen,
      );
}
