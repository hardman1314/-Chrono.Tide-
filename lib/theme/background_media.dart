import 'dart:io';
import 'dart:typed_data';

/// 背景图媒体校验与探测（v3.10 动态背景支持）
///
/// 职责：在**上传落盘前**判定一个文件到底是什么、多大、几张帧，
/// 并按门槛给出裁决。所有判定都基于**文件内容（魔数 + 块结构）**，
/// 不信任扩展名 —— 扩展名只用来交叉核对是否被伪装。
///
/// 设计要点（2026-09-17 Phase 0 实测结论驱动）：
/// - **不做 isolate**：实测块级扫描吞吐 >5GB/s（5.31MB / 0.98ms），
///   10MB 文件扫描约 2ms，配合 `File.readAsBytes` 的异步读盘，
///   整体不构成 UI 阻塞，无需 compute()。
/// - **动图与静态两套像素门槛**：Flutter 的 `cacheWidth`/`ResizeImage`
///   对**多帧图无效**（引擎层与真机双重实测），动图会按原始尺寸逐帧解码，
///   所以动图必须用更严的像素预算，否则单帧解码内存会失控。
///
/// 块级扫描算法已与引擎 `ui.Codec.frameCount` 交叉验证一致
/// （4 个样本，含 2 个真实世界 GIF：286 帧 / 214 帧）。
class BackgroundMediaInspector {
  BackgroundMediaInspector._();

  /// 体积上限：10 MB（沿用改造前既有门槛，不放松）
  static const int maxBytes = 10 * 1024 * 1024;

  /// 静态图分辨率上限：4096 x 4096（静态图 `cacheWidth` 生效，可安全限宽解码）
  static const int maxStaticPixels = 4096 * 4096;

  /// 动图单帧像素上限：1920 x 1080
  ///
  /// 🔴 这个值**不能**放宽到静态图的 4096²：动图逐帧全尺寸解码，
  /// 4096x4096 单帧 = 67MB，几帧就把内存打爆。详见 Phase 0 V2/V2b。
  static const int maxAnimatedPixels = 1920 * 1080;

  /// 动图帧数上限
  static const int maxAnimatedFrames = 600;

  /// 总时长超过此值给警告（不拒绝）
  static const int warnDurationMs = 60 * 1000;

  /// 平均帧率超过此值给警告（不拒绝）——零依赖方案无法限帧，
  /// 高帧率 GIF 会持续占用栅格线程
  static const double warnAverageFps = 30;

  /// 允许的扩展名。
  ///
  /// 🔴 这是**唯一来源**：`ThemeStorage.validateImageExtension` 直接引用本常量，
  /// 因此新增格式只需改这里（注意会连带影响 `.cttheme` 主题包导入白名单）。
  static const List<String> allowedExtensions = [
    'jpg',
    'jpeg',
    'png',
    'webp',
    'bmp',
    'gif',
  ];

  /// 校验一个**已读入内存**的文件。纯 CPU，实测 10MB 约 2ms。
  static BackgroundMediaVerdict inspect(
    Uint8List bytes, {
    required String extension,
  }) {
    final ext = extension.toLowerCase();
    if (!allowedExtensions.contains(ext)) {
      return BackgroundMediaVerdict.reject(
        BackgroundMediaReject.unsupportedFormat,
        '不支持的格式 .$ext（支持 jpg/jpeg/png/webp/bmp/gif）',
        byteLength: bytes.length,
      );
    }

    final media = detect(bytes);
    if (media.kind == BackgroundMediaKind.unknown) {
      return BackgroundMediaVerdict.reject(
        BackgroundMediaReject.unreadable,
        '无法识别文件内容（可能已损坏或不是图片）',
        byteLength: bytes.length,
      );
    }

    // APNG / 动画 WebP：本期明确不启用，给明确原因而不是「格式不支持」
    if (media.isMultiFrame && media.kind != BackgroundMediaKind.gif) {
      return BackgroundMediaVerdict.reject(
        BackgroundMediaReject.unsupportedFormat,
        media.kind == BackgroundMediaKind.apng
            ? '暂不支持 APNG 动画背景（本期仅支持 GIF 动态背景）'
            : '暂不支持动画 WebP 背景（本期仅支持 GIF 动态背景）',
        info: media,
      );
    }

    // 魔数与扩展名交叉核对：防「改名伪装」
    final expected = _extensionMatches(ext, media.kind);
    if (!expected) {
      return BackgroundMediaVerdict.reject(
        BackgroundMediaReject.spoofedExtension,
        '文件内容与扩展名 .$ext 不符（实际是 ${media.kind.label}）',
        info: media,
      );
    }

    if (bytes.length > maxBytes) {
      return BackgroundMediaVerdict.reject(
        BackgroundMediaReject.tooLarge,
        '文件 ${_mb(bytes.length)} 超过上限 ${maxBytes ~/ (1024 * 1024)}MB',
        info: media,
      );
    }

    final pixelLimit =
        media.isAnimated ? maxAnimatedPixels : maxStaticPixels;
    final pixels = media.width * media.height;
    if (pixels > pixelLimit) {
      final limitText = media.isAnimated
          ? '1920x1080（动图按单帧像素计）'
          : '4096x4096';
      return BackgroundMediaVerdict.reject(
        BackgroundMediaReject.tooManyPixels,
        '分辨率 ${media.width}x${media.height} 超过上限 $limitText'
            '${media.isAnimated ? '——动图无法降采样解码，必须控制单帧尺寸' : ''}',
        info: media,
      );
    }

    if (media.isAnimated && media.frameCount > maxAnimatedFrames) {
      return BackgroundMediaVerdict.reject(
        BackgroundMediaReject.tooManyFrames,
        'GIF 帧数 ${media.frameCount} 超过上限 $maxAnimatedFrames'
            '（体积 ${_mb(bytes.length)} 合格 / 分辨率 '
            '${media.width}x${media.height} 合格）',
        info: media,
      );
    }

    final warnings = <String>[];
    if (media.isAnimated) {
      if (media.totalDelayMs > warnDurationMs) {
        warnings.add('总时长 ${(media.totalDelayMs / 1000).round()}s 较长，'
            '会持续占用解码资源');
      }
      if (media.averageFps > warnAverageFps) {
        warnings.add('平均帧率 ${media.averageFps.toStringAsFixed(0)}fps 较高，'
            '背景会持续高频重绘');
      }
    }

    return BackgroundMediaVerdict.ok(media, warnings: warnings);
  }

  /// 异步：读盘 + 校验。读盘是异步 IO，CPU 部分约 2ms，均在 UI isolate 可接受范围。
  static Future<BackgroundMediaVerdict> inspectFile(
    String path, {
    required String extension,
  }) async {
    final file = File(path);
    if (!file.existsSync()) {
      return BackgroundMediaVerdict.reject(
        BackgroundMediaReject.unreadable,
        '文件不存在: $path',
      );
    }
    final length = await file.length();
    if (length > maxBytes) {
      return BackgroundMediaVerdict.reject(
        BackgroundMediaReject.tooLarge,
        '文件 ${_mb(length)} 超过上限 ${maxBytes ~/ (1024 * 1024)}MB',
      );
    }
    final bytes = await file.readAsBytes();
    return inspect(bytes, extension: extension);
  }

  static String _mb(int bytes) =>
      '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';

  static bool _extensionMatches(String ext, BackgroundMediaKind kind) {
    switch (kind) {
      case BackgroundMediaKind.jpeg:
        return ext == 'jpg' || ext == 'jpeg';
      case BackgroundMediaKind.png:
      case BackgroundMediaKind.apng:
        return ext == 'png';
      case BackgroundMediaKind.webp:
      case BackgroundMediaKind.animatedWebp:
        return ext == 'webp';
      case BackgroundMediaKind.bmp:
        return ext == 'bmp';
      case BackgroundMediaKind.gif:
        return ext == 'gif';
      case BackgroundMediaKind.unknown:
        return false;
    }
  }

  /// 识别文件内容（魔数优先，再读尺寸/帧信息）
  static BackgroundMediaInfo detect(Uint8List d) {
    if (d.length < 12) {
      return const BackgroundMediaInfo.unknown();
    }
    // GIF: 47 49 46 38 ('GIF8')
    if (d[0] == 0x47 && d[1] == 0x49 && d[2] == 0x46 && d[3] == 0x38) {
      final r = _scanGif(d, maxFrames: maxAnimatedFrames + 1);
      return BackgroundMediaInfo(
        kind: BackgroundMediaKind.gif,
        width: r.width,
        height: r.height,
        frameCount: r.frameCount,
        totalDelayCs: r.totalDelayCs,
        byteLength: d.length,
      );
    }
    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if (d[0] == 0x89 && d[1] == 0x50 && d[2] == 0x4E && d[3] == 0x47) {
      final w = _be32(d, 16);
      final h = _be32(d, 20);
      final isApng = _pngHasActl(d);
      return BackgroundMediaInfo(
        kind: isApng ? BackgroundMediaKind.apng : BackgroundMediaKind.png,
        width: w,
        height: h,
        frameCount: 1,
        totalDelayCs: 0,
        byteLength: d.length,
      );
    }
    // JPEG: FF D8 FF
    if (d[0] == 0xFF && d[1] == 0xD8 && d[2] == 0xFF) {
      final size = _jpegSize(d);
      return BackgroundMediaInfo(
        kind: BackgroundMediaKind.jpeg,
        width: size.$1,
        height: size.$2,
        frameCount: 1,
        totalDelayCs: 0,
        byteLength: d.length,
      );
    }
    // WebP: 'RIFF' .... 'WEBP'
    if (d[0] == 0x52 &&
        d[1] == 0x49 &&
        d[2] == 0x46 &&
        d[3] == 0x46 &&
        d[8] == 0x57 &&
        d[9] == 0x45 &&
        d[10] == 0x42 &&
        d[11] == 0x50) {
      final info = _webpInfo(d);
      return BackgroundMediaInfo(
        kind: info.animated
            ? BackgroundMediaKind.animatedWebp
            : BackgroundMediaKind.webp,
        width: info.width,
        height: info.height,
        frameCount: 1,
        totalDelayCs: 0,
        byteLength: d.length,
      );
    }
    // BMP: 'BM'
    if (d[0] == 0x42 && d[1] == 0x4D) {
      final w = _le32s(d, 18);
      final h = _le32s(d, 22).abs();
      return BackgroundMediaInfo(
        kind: BackgroundMediaKind.bmp,
        width: w,
        height: h,
        frameCount: 1,
        totalDelayCs: 0,
        byteLength: d.length,
      );
    }
    return BackgroundMediaInfo(
      kind: BackgroundMediaKind.unknown,
      byteLength: d.length,
    );
  }

  // ── 各格式尺寸解析 ───────────────────────────────────────────────

  static int _be32(Uint8List d, int i) =>
      (d[i] << 24) | (d[i + 1] << 16) | (d[i + 2] << 8) | d[i + 3];

  static int _le32s(Uint8List d, int i) {
    final v = d[i] | (d[i + 1] << 8) | (d[i + 2] << 16) | (d[i + 3] << 24);
    return v > 0x7FFFFFFF ? v - 0x100000000 : v;
  }

  /// PNG 是否含 acTL 块（APNG 标志）。只扫到 IDAT 之前的块。
  static bool _pngHasActl(Uint8List d) {
    var pos = 8;
    while (pos + 8 <= d.length) {
      final len = _be32(d, pos);
      if (len < 0 || pos + 12 + len > d.length) return false;
      final t0 = d[pos + 4], t1 = d[pos + 5], t2 = d[pos + 6], t3 = d[pos + 7];
      // 'acTL'
      if (t0 == 0x61 && t1 == 0x63 && t2 == 0x54 && t3 == 0x4C) return true;
      // 'IDAT' 之后不可能再有 acTL
      if (t0 == 0x49 && t1 == 0x44 && t2 == 0x41 && t3 == 0x54) return false;
      pos += 12 + len;
    }
    return false;
  }

  /// JPEG 尺寸：扫 SOF 段（0xFFC0-0xFFCF，排除 C4/C8/CC）
  static (int, int) _jpegSize(Uint8List d) {
    var pos = 2;
    while (pos + 9 < d.length) {
      if (d[pos] != 0xFF) {
        pos++;
        continue;
      }
      final marker = d[pos + 1];
      if (marker == 0xD8 || marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
        pos += 2;
        continue;
      }
      final segLen = (d[pos + 2] << 8) | d[pos + 3];
      final isSof = marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (isSof) {
        final h = (d[pos + 5] << 8) | d[pos + 6];
        final w = (d[pos + 7] << 8) | d[pos + 8];
        return (w, h);
      }
      pos += 2 + segLen;
    }
    return (0, 0);
  }

  /// WebP 尺寸与是否含动画（VP8X 的 Animation 标志位）
  static ({int width, int height, bool animated}) _webpInfo(Uint8List d) {
    var pos = 12;
    var width = 0;
    var height = 0;
    var animated = false;
    while (pos + 8 <= d.length) {
      final fourcc = String.fromCharCodes(d.sublist(pos, pos + 4));
      final size = d[pos + 4] |
          (d[pos + 5] << 8) |
          (d[pos + 6] << 16) |
          (d[pos + 7] << 24);
      final payload = pos + 8;
      if (fourcc == 'VP8X' && payload + 10 <= d.length) {
        animated = (d[payload] & 0x02) != 0; // ANIMATION flag
        width = 1 +
            (d[payload + 4] | (d[payload + 5] << 8) | (d[payload + 6] << 16));
        height = 1 +
            (d[payload + 7] | (d[payload + 8] << 8) | (d[payload + 9] << 16));
        return (width: width, height: height, animated: animated);
      }
      if (fourcc == 'VP8 ' && payload + 10 <= d.length) {
        // 3 字节 frame tag + 3 字节起始码 9D 01 2A
        final w = (d[payload + 6] | (d[payload + 7] << 8)) & 0x3FFF;
        final h = (d[payload + 8] | (d[payload + 9] << 8)) & 0x3FFF;
        return (width: w, height: h, animated: false);
      }
      if (fourcc == 'VP8L' && payload + 5 <= d.length) {
        // 1 字节签名 0x2F + 14bit 宽 + 14bit 高（LSB 位流）
        final b0 = d[payload + 1];
        final b1 = d[payload + 2];
        final b2 = d[payload + 3];
        final b3 = d[payload + 4];
        final bits = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
        return (
          width: (bits & 0x3FFF) + 1,
          height: ((bits >> 14) & 0x3FFF) + 1,
          animated: false,
        );
      }
      if (size <= 0 || payload + size > d.length) break;
      pos = payload + size + (size.isOdd ? 1 : 0); // RIFF 块 2 字节对齐
    }
    return (width: width, height: height, animated: animated);
  }

  // ── GIF 块级扫描（已与引擎 frameCount 交叉验证）────────────────────

  static int _u16(Uint8List d, int i) => d[i] | (d[i + 1] << 8);

  static int _skipSubBlocks(Uint8List d, int p) {
    while (p < d.length) {
      final n = d[p];
      if (n == 0) return p + 1;
      p += 1 + n;
    }
    return p;
  }

  /// 只按块结构跳跃、不解压像素：成本与体积近似线性，
  /// 且触达 [maxFrames] 时可提前终止（超过门槛无需数清总数）。
  static GifScanResult _scanGif(Uint8List d, {required int maxFrames}) {
    final width = _u16(d, 6);
    final height = _u16(d, 8);
    final packed = d[10];
    var pos = 13;
    if ((packed & 0x80) != 0) {
      pos += 3 * (1 << ((packed & 0x07) + 1)); // 跳过全局调色板
    }

    var frames = 0;
    var delayCs = 0;
    var truncated = false;

    while (pos < d.length) {
      final block = d[pos];
      if (block == 0x3B) break; // trailer

      if (block == 0x21) {
        if (pos + 2 >= d.length) break;
        final label = d[pos + 1];
        if (label == 0xF9 && pos + 6 < d.length) {
          delayCs += _u16(d, pos + 4); // Graphic Control Extension 的 delay
        }
        pos = _skipSubBlocks(d, pos + 2);
        continue;
      }

      if (block == 0x2C) {
        if (pos + 10 > d.length) break;
        frames++;
        if (frames >= maxFrames) {
          truncated = true;
          break;
        }
        final imgPacked = d[pos + 9];
        var p = pos + 10;
        if ((imgPacked & 0x80) != 0) {
          p += 3 * (1 << ((imgPacked & 0x07) + 1)); // 局部调色板
        }
        p += 1; // LZW min code size
        pos = _skipSubBlocks(d, p);
        continue;
      }

      break; // 未知块：结构已损坏
    }

    return GifScanResult(
      width: width,
      height: height,
      frameCount: frames,
      totalDelayCs: delayCs,
      truncated: truncated,
    );
  }
}

/// GIF 块级扫描结果（内部使用，也便于测试断言）
class GifScanResult {
  const GifScanResult({
    required this.width,
    required this.height,
    required this.frameCount,
    required this.totalDelayCs,
    required this.truncated,
  });

  final int width;
  final int height;
  final int frameCount;

  /// 累计帧延迟，单位 1/100 秒（GIF GCE 的 delay 字段单位）
  final int totalDelayCs;

  /// 是否因触达 maxFrames 上限而提前终止
  final bool truncated;

  @override
  String toString() => 'GifScan(${width}x$height, frames=$frameCount, '
      'delay=${totalDelayCs}cs, truncated=$truncated)';
}

/// 背景图媒体类型
enum BackgroundMediaKind {
  jpeg,
  png,

  /// 动画 PNG（本期不支持，仅用于给出准确拒绝原因）
  apng,
  webp,

  /// 动画 WebP（本期不支持，仅用于给出准确拒绝原因）
  animatedWebp,
  bmp,
  gif,
  unknown;

  String get label {
    switch (this) {
      case BackgroundMediaKind.jpeg:
        return 'JPEG';
      case BackgroundMediaKind.png:
        return 'PNG';
      case BackgroundMediaKind.apng:
        return 'APNG';
      case BackgroundMediaKind.webp:
        return 'WebP';
      case BackgroundMediaKind.animatedWebp:
        return '动画 WebP';
      case BackgroundMediaKind.bmp:
        return 'BMP';
      case BackgroundMediaKind.gif:
        return 'GIF';
      case BackgroundMediaKind.unknown:
        return '未知格式';
    }
  }
}

/// 探测结果
class BackgroundMediaInfo {
  const BackgroundMediaInfo({
    required this.kind,
    required this.byteLength,
    this.width = 0,
    this.height = 0,
    this.frameCount = 1,
    this.totalDelayCs = 0,
  });

  const BackgroundMediaInfo.unknown()
      : kind = BackgroundMediaKind.unknown,
        width = 0,
        height = 0,
        frameCount = 0,
        totalDelayCs = 0,
        byteLength = 0;

  final BackgroundMediaKind kind;
  final int width;
  final int height;
  final int frameCount;
  final int totalDelayCs;
  final int byteLength;

  /// 本期的「动图」= GIF（APNG / 动画 WebP 会在校验阶段被拒）
  bool get isAnimated => kind == BackgroundMediaKind.gif;

  /// 是否为引擎层面意义上的多帧图（含本期不支持的格式）
  bool get isMultiFrame =>
      kind == BackgroundMediaKind.gif ||
      kind == BackgroundMediaKind.apng ||
      kind == BackgroundMediaKind.animatedWebp;

  int get pixelCount => width * height;

  int get totalDelayMs => totalDelayCs * 10;

  double get averageFps =>
      totalDelayCs <= 0 ? 0 : frameCount * 100 / totalDelayCs;

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'width': width,
        'height': height,
        'frameCount': frameCount,
        'totalDelayMs': totalDelayMs,
        'byteLength': byteLength,
      };

  @override
  String toString() =>
      '${kind.label} ${width}x$height frames=$frameCount '
      '${byteLength ~/ 1024}KB';
}

/// 拒绝原因（用于测试与 UI 分支）
enum BackgroundMediaReject {
  none,

  /// 扩展名不在白名单
  unsupportedFormat,

  /// 内容与扩展名不符（伪装）
  spoofedExtension,

  /// 体积超限
  tooLarge,

  /// 像素超限
  tooManyPixels,

  /// 动图帧数超限
  tooManyFrames,

  /// 无法识别 / 损坏
  unreadable,
}

/// 校验裁决
class BackgroundMediaVerdict {
  const BackgroundMediaVerdict._({
    required this.reject,
    required this.message,
    this.info,
    this.warnings = const [],
  });

  factory BackgroundMediaVerdict.ok(
    BackgroundMediaInfo info, {
    List<String> warnings = const [],
  }) =>
      BackgroundMediaVerdict._(
        reject: BackgroundMediaReject.none,
        message: null,
        info: info,
        warnings: warnings,
      );

  factory BackgroundMediaVerdict.reject(
    BackgroundMediaReject reject,
    String message, {
    BackgroundMediaInfo? info,
    int? byteLength,
  }) =>
      BackgroundMediaVerdict._(
        reject: reject,
        message: message,
        info: info ??
            (byteLength == null
                ? null
                : BackgroundMediaInfo(
                    kind: BackgroundMediaKind.unknown,
                    width: 0,
                    height: 0,
                    frameCount: 0,
                    totalDelayCs: 0,
                    byteLength: byteLength,
                  )),
      );

  final BackgroundMediaReject reject;
  final String? message;
  final BackgroundMediaInfo? info;

  /// 不阻断上传、但需要提示用户的项（时长过长 / 帧率过高）
  final List<String> warnings;

  bool get ok => reject == BackgroundMediaReject.none;

  @override
  String toString() =>
      ok ? 'OK($info)${warnings.isEmpty ? '' : ' warn=$warnings'}' : message!;
}

/// 背景文件被拒绝（格式不支持 / 内容与扩展名不符 / 体积·分辨率·帧数越限）。
///
/// [toString] 只返回可读文案，让既有的 `catch (e) => '…$e'` 调用点也能直接
/// 显示干净信息；需要精确到维度的文案时用 [message]。
class BackgroundMediaRejectedException implements Exception {
  const BackgroundMediaRejectedException(this.verdict);

  final BackgroundMediaVerdict verdict;

  String get message => verdict.message ?? '背景文件不符合要求';

  @override
  String toString() => message;
}
