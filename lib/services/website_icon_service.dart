import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/path_helper.dart';

/// 站点图标服务（探索大厅 · 板块④网站管理）
///
/// 两种图标来源：
/// 1. **自动识别**：从网址解析 host，依次尝试
///    `首页 HTML 的 <link rel="icon">` → `https://host/favicon.ico` →
///    DuckDuckGo 图标服务（PNG 兜底），下载后缓存到本地；
/// 2. **用户上传**：[pickAndSaveLocalIcon] 用 file_picker 选图后复制到图标目录。
///
/// ⚠️ 只落盘 Flutter `Image` 能解码的格式：favicon 常见是 .ico，
/// 而 Flutter 标准 codec 不支持 ICO（也不支持 SVG），
/// 因此 [isDecodableImage] 按魔数直接拒绝，否则面板会显示空白占位。
/// 识别失败时由 UI 回落首字母渐变徽章（HallLetterAvatar）。
class WebsiteIconService {
  WebsiteIconService._();

  static final WebsiteIconService instance = WebsiteIconService._();

  static const Duration _timeout = Duration(seconds: 6);
  static const String _userAgent = 'ChronoTide/1.0 (site icon fetch)';

  /// 单个图标大小上限（2MB，防异常站点返回巨型文件）
  static const int _maxBytes = 2 * 1024 * 1024;

  /// 会话内已失败的 host：避免面板每次重建都反复打网络
  final Set<String> _failedHosts = <String>{};

  /// 自动识别的图标缓存目录（data/cache/site_icons）
  static String get _cacheDir =>
      p.join(PathHelper.dataDir, 'cache', 'site_icons');

  /// 用户上传的图标目录（data/site_icons，不随缓存清理）
  static String get _uploadDir => p.join(PathHelper.dataDir, 'site_icons');

  Dio get _dio => Dio(
        BaseOptions(
          connectTimeout: _timeout,
          receiveTimeout: _timeout,
          headers: <String, String>{'User-Agent': _userAgent},
        ),
      );

  /// 自动识别站点图标并缓存；成功返回本地文件路径，失败返回 null
  Future<String?> fetchSiteIcon(String url) async {
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.isEmpty) return null;
    if (_failedHosts.contains(host)) return null;

    final cached = findCachedIcon(host);
    if (cached != null) return cached;

    final candidates = <String>['https://$host/favicon.ico'];
    // 首页 link[rel~=icon] 优先：很多站点图标不在根目录
    final fromHtml = await _extractIconUrlFromHomepage(host);
    if (fromHtml != null) candidates.insert(0, fromHtml);
    // PNG 兜底服务
    candidates.add('https://icons.duckduckgo.com/ip3/$host.png');

    for (final candidate in candidates) {
      final bytes = await _downloadBytes(candidate);
      if (bytes == null) continue;
      // favicon 常见是 ICO：优先原样可用，否则尝试提取内嵌图
      final usable = isDecodableImage(bytes) ? bytes : decodeIco(bytes);
      if (usable == null || !isDecodableImage(usable)) continue;
      final saved = await _saveToCache(host, usable);
      if (saved != null) return saved;
    }

    _failedHosts.add(host);
    debugPrint('[WebsiteIcon] ⚠️ 图标识别失败: $host');
    return null;
  }

  /// 清除失败标记（用户手动点「自动获取」重试时用）
  void clearFailure(String url) =>
      _failedHosts.remove(Uri.tryParse(url)?.host ?? '');

  /// 清除失败标记（用户手动点「自动获取」重试时用）
  /// ICO 转可解码图片：返回 PNG 字节（图标内嵌 PNG 时直接切片）或
  /// 标准 BMP 字节（DIB 帧补写 BITMAPFILEHEADER）；无法解析返回 null。
  ///
  /// 背景（2026-09-12 实测）：`favicon.ico` 绝大多数是 ICO，
  /// 其中 KunGal / VNDB 等是 DIB 位图、少数现代站点内嵌 PNG；
  /// 而 Flutter 原生 `Image` 不支持 ICO，不转换则「自动识别」形同虚设。
  @visibleForTesting
  static List<int>? decodeIco(List<int> bytes) {
    // ICONDIR: reserved(2)=0, type(2)=1, count(2)
    if (bytes.length < 22) return null;
    if (bytes[0] != 0x00 ||
        bytes[1] != 0x00 ||
        bytes[2] != 0x01 ||
        bytes[3] != 0x00) {
      return null;
    }
    final count = _u16(bytes, 4);
    if (count <= 0) return null;

    // 选一帧：优先内嵌 PNG，其次面积最大的 DIB
    var bestIndex = -1;
    var bestScore = -1;
    for (var i = 0; i < count; i++) {
      final off = 6 + i * 16;
      if (off + 16 > bytes.length) break;
      final w = bytes[off] == 0 ? 256 : bytes[off];
      final h = bytes[off + 1] == 0 ? 256 : bytes[off + 1];
      final size = _u32(bytes, off + 8);
      final imgOff = _u32(bytes, off + 12);
      if (size <= 0 || imgOff + 8 > bytes.length) continue;
      final embeddedPng = bytes[imgOff] == 0x89 &&
          bytes[imgOff + 1] == 0x50 &&
          bytes[imgOff + 2] == 0x4E &&
          bytes[imgOff + 3] == 0x47;
      final score = w * h + (embeddedPng ? 1 << 20 : 0);
      if (score > bestScore) {
        bestScore = score;
        bestIndex = i;
      }
    }
    if (bestIndex < 0) return null;

    final off = 6 + bestIndex * 16;
    final w = bytes[off] == 0 ? 256 : bytes[off];
    final h = bytes[off + 1] == 0 ? 256 : bytes[off + 1];
    final bpp = _u16(bytes, off + 6);
    final size = _u32(bytes, off + 8);
    final imgOff = _u32(bytes, off + 12);
    final end = (imgOff + size).clamp(0, bytes.length);

    // ① 内嵌 PNG：直接切片
    if (bytes[imgOff] == 0x89 &&
        bytes[imgOff + 1] == 0x50 &&
        bytes[imgOff + 2] == 0x4E &&
        bytes[imgOff + 3] == 0x47) {
      return bytes.sublist(imgOff, end);
    }
    // ② DIB：补写 14 字节 BITMAPFILEHEADER 成为标准 BMP
    return _wrapDibAsBmp(bytes, imgOff, w, h, bpp);
  }

  /// 把 ICO 内的 DIB 帧包装为标准 BMP（Flutter 可解码）
  ///
  /// ICO 的 DIB `biHeight` 是图标高度的 2 倍（含 AND mask），这里改写为
  /// 实际高度并只取像素部分，避免解码出下半张掩码噪声。
  static List<int>? _wrapDibAsBmp(
      List<int> src, int imgOff, int w, int h, int bpp) {
    if (imgOff + 40 > src.length) return null;
    // 仅支持有调色板(<=8bpp)与 16/24/32bpp 的 BI_RGB 帧
    if (bpp != 1 && bpp != 4 && bpp != 8 && bpp != 16 && bpp != 24 && bpp != 32) {
      return null;
    }
    final stride = ((w * bpp + 31) ~/ 32) * 4;
    final pixelBytes = stride * h;
    final paletteBytes = bpp <= 8 ? (1 << bpp) * 4 : 0;
    final dataStart = imgOff + 40 + paletteBytes;
    if (dataStart + pixelBytes > src.length) return null;

    final out = <int>[];
    // BITMAPFILEHEADER
    final headerSize = 14 + 40 + paletteBytes;
    out
      ..addAll(<int>[0x42, 0x4D])
      ..addAll(_u32Bytes(headerSize + pixelBytes))
      ..addAll(<int>[0, 0, 0, 0])
      ..addAll(_u32Bytes(headerSize));
    // BITMAPINFOHEADER 布局：biSize(0) biWidth(4) biHeight(8) biPlanes(12)
    // biBitCount(14)… ⚠️ 高度在偏移 8，写错会破坏 planes/bitCount
    final dib = List<int>.from(src.sublist(imgOff, imgOff + 40));
    dib[8] = h & 0xFF;
    dib[9] = (h >> 8) & 0xFF;
    dib[10] = (h >> 16) & 0xFF;
    dib[11] = (h >> 24) & 0xFF;
    out.addAll(dib);
    if (paletteBytes > 0) {
      out.addAll(src.sublist(imgOff + 40, imgOff + 40 + paletteBytes));
    }
    out.addAll(src.sublist(dataStart, dataStart + pixelBytes));
    return out;
  }

  static int _u16(List<int> b, int off) => b[off] | (b[off + 1] << 8);

  static int _u32(List<int> b, int off) =>
      b[off] |
      (b[off + 1] << 8) |
      (b[off + 2] << 16) |
      ((b[off + 3] & 0x7F) << 24);

  static List<int> _u32Bytes(int v) =>
      <int>[v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF];

  /// 查找已缓存的图标（扩展名不定，按 host 前缀匹配）
  static String? findCachedIcon(String host) {
    final safe = _safeName(host);
    if (safe.isEmpty) return null;
    final dir = Directory(_cacheDir);
    if (!dir.existsSync()) return null;
    try {
      for (final f in dir.listSync()) {
        if (f is! File) continue;
        final name = p.basename(f.path);
        if (name.startsWith('$safe.')) return f.path;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// 用户上传图标：打开文件选择 → 复制到 data/site_icons
  /// 返回本地路径；用户取消或无权限返回 null
  Future<String?> pickAndSaveLocalIcon() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
        withData: false,
      );
      final path = result?.files.single.path;
      if (path == null || path.isEmpty) return null;
      final source = File(path);
      if (!source.existsSync()) return null;

      final dir = Directory(_uploadDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final ext = p.extension(path).toLowerCase().isEmpty
          ? '.png'
          : p.extension(path).toLowerCase();
      final target =
          p.join(_uploadDir, 'icon_${DateTime.now().millisecondsSinceEpoch}$ext');
      await source.copy(target);
      return target;
    } catch (e) {
      debugPrint('[WebsiteIcon] ⚠️ 上传图标失败: $e');
      return null;
    }
  }

  // ---------- 内部实现 ----------

  static String _safeName(String host) =>
      host.replaceAll(RegExp(r'[^a-zA-Z0-9.\-]'), '_');

  Future<List<int>?> _downloadBytes(String url) async {
    try {
      final resp = await _dio.get<List<int>>(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          validateStatus: (s) => s != null && s >= 200 && s < 400,
        ),
      );
      final data = resp.data;
      if (data == null || data.isEmpty || data.length > _maxBytes) return null;
      return data;
    } catch (_) {
      return null;
    }
  }

  /// 抓首页 HTML，解析 <link rel="icon|shortcut icon|apple-touch-icon">
  Future<String?> _extractIconUrlFromHomepage(String host) async {
    try {
      final resp = await _dio.get<String>(
        'https://$host/',
        options: Options(
          responseType: ResponseType.plain,
          validateStatus: (s) => s != null && s >= 200 && s < 400,
          // 首页可能很大，交给 receiveTimeout 兜底
        ),
      );
      final html = resp.data;
      if (html == null || html.isEmpty) return null;
      // 注意：正则同时含单双引号，不能用 r'' / r"" raw 字符串定界，
      // 这里用普通字符串（\s 需写成 \\s）
      final re = RegExp(
        '<link[^>]+rel\\s*=\\s*["\']?[^"\'>]*icon[^"\'>]*["\']?[^>]*href\\s*=\\s*["\']([^"\']+)["\']',
        caseSensitive: false,
      );
      // 同时兼容 href 写在 rel 之前的写法
      final re2 = RegExp(
        '<link[^>]+href\\s*=\\s*["\']([^"\']+)["\'][^>]*rel\\s*=\\s*["\']?[^"\'>]*icon',
        caseSensitive: false,
      );
      final m = re.firstMatch(html) ?? re2.firstMatch(html);
      final href = m?.group(1);
      if (href == null || href.isEmpty) return null;
      if (href.startsWith('data:')) return null;
      final uri = Uri.tryParse('https://$host/');
      if (uri == null) return null;
      return uri.resolve(href).toString();
    } catch (_) {
      return null;
    }
  }

  Future<String?> _saveToCache(String host, List<int> bytes) async {
    try {
      final dir = Directory(_cacheDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final ext = _extensionOf(bytes);
      final file = File(p.join(_cacheDir, '${_safeName(host)}.$ext'));
      await file.writeAsBytes(bytes);
      return file.path;
    } catch (e) {
      debugPrint('[WebsiteIcon] ⚠️ 图标落盘失败: $e');
      return null;
    }
  }

  /// 按魔数判定落盘扩展名（PNG / JPEG / GIF / WEBP / BMP）
  static String _extensionOf(List<int> bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'jpg';
    }
    if (bytes.length >= 6 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      return 'gif';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'webp';
    }
    if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
      return 'bmp';
    }
    return 'png';
  }

  /// 是否为 Flutter Image 可解码的图片格式（按魔数判断）
  ///
  /// 支持：PNG / JPEG / GIF / WEBP / BMP；
  /// 拒绝：ICO（favicon 常见，但 Flutter 不支持）、SVG（需 flutter_svg）、
  /// HTML/文本（站点返回错误页时常见）。
  @visibleForTesting
  static bool isDecodableImage(List<int> bytes) {
    if (bytes.length < 8) return false;
    // PNG
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return true;
    }
    // JPEG
    if (bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF) return true;
    // GIF87a / GIF89a
    if (bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        (bytes[3] == 0x38) &&
        (bytes[4] == 0x37 || bytes[4] == 0x39) &&
        bytes[5] == 0x61) {
      return true;
    }
    // WEBP: 'RIFF'....'WEBP'
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes.length > 12 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true;
    }
    // BMP
    if (bytes[0] == 0x42 && bytes[1] == 0x4D) return true;
    return false;
  }
}
