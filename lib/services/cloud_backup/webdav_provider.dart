/// WebDAV Provider —— Phase 5 一期首选云备份通道（方案 §7）。
///
/// 选型理由：坚果云免费可用（国内 Galgame 用户可达性优先）；纯 HTTP
/// PUT/GET/PROPFIND/MKCOL/DELETE 即可，`dart:io HttpClient` 原生支持任意
/// 方法，**零第三方依赖**。
///
/// 兼容性目标：坚果云（https://dav.jianguoyun.com/dav/）、Nextcloud、
/// 群晖/威联通 NAS、Alist 挂载。实现保持「标准 WebDAV Class 1+2 子集」，
/// 不依赖扩展头。
///
/// 🔴 凭据不落本文件 —— 密码由 [CloudBackupService] 经 DPAPI 加密后保管，
/// 构造时注入。本文件**刻意不 import flutter**，dev_probe 可实测。
library;

import 'dart:convert';
import 'dart:io';

import 'cloud_storage_provider.dart';

class WebDavProvider implements CloudStorageProvider {
  /// 归一化的服务根（以 `/` 结尾），如 `https://dav.jianguoyun.com/dav/`。
  final String baseUrl;
  final String username;
  final String password; // 明文，仅内存；落盘走 DPAPI（见 CloudBackupService）

  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  /// 空闲超时（PROPFIND 大目录 / 弱网容忍）。
  static const Duration _requestTimeout = Duration(seconds: 60);

  WebDavProvider({
    required String baseUrl,
    required this.username,
    required this.password,
  }) : baseUrl = _normalizeBaseUrl(baseUrl);

  @override
  String get name => 'WebDAV';

  static String _normalizeBaseUrl(String url) {
    var u = url.trim();
    if (u.isEmpty) throw CloudStorageException('WebDAV 服务地址为空');
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      u = 'https://$u';
    }
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return '$u/';
  }

  // ---------------------------------------------------------------------------
  // 路径与鉴权
  // ---------------------------------------------------------------------------

  /// 把相对路径（`a/b/c.ext`）编码进 URL（逐段 encode，保留 `/`）。
  Uri _url(String remotePath) {
    final segs = remotePath
        .split('/')
        .where((s) => s.isNotEmpty)
        .map((s) => Uri.encodeComponent(s))
        .toList();
    return Uri.parse('$baseUrl${segs.join('/')}');
  }

  String get _authHeader =>
      'Basic ${base64Encode(utf8.encode('$username:$password'))}';

  /// 统一请求：超时 + 401 语义化。
  Future<HttpClientResponse> _send(
    String method,
    Uri url, {
    Map<String, String>? headers,
    Stream<List<int>>? body,
  }) async {
    final req = await _client.openUrl(method, url);
    req.headers.set(HttpHeaders.authorizationHeader, _authHeader);
    headers?.forEach(req.headers.set);
    req.headers.set(HttpHeaders.userAgentHeader, 'ChronoTide-CloudBackup/1');

    if (body != null) {
      await req.addStream(body);
    }
    await req.flush();

    final res = await req.close().timeout(_requestTimeout);
    if (res.statusCode == 401) {
      await res.drain<void>();
      throw CloudStorageException('鉴权失败：用户名或密码（或应用密码）不正确',
          401);
    }
    return res;
  }

  // ---------------------------------------------------------------------------
  // 接口实现
  // ---------------------------------------------------------------------------

  @override
  Future<void> testConnection() async {
    // PROPFIND 备份根（Depth:0 只看自身）：207 = 通。
    final res = await _send('PROPFIND', _url(''),
        headers: {'Depth': '0'});
    await res.drain<void>();
    // 207 Multi-Status 为正常；部分服务器对根可能回 200
    if (res.statusCode == 207 || res.statusCode == 200) return;
    throw CloudStorageException(
        '服务响应异常：HTTP ${res.statusCode}（PROPFIND 根目录）', res.statusCode);
  }

  @override
  Future<void> ensureDir(String remoteDir) async {
    // 逐段 MKCOL；405（已存在）与 301（部分服务器对已有目录返回重定向）容忍。
    final segs =
        remoteDir.split('/').where((s) => s.isNotEmpty).toList();
    var cur = '';
    for (final seg in segs) {
      cur = cur.isEmpty ? seg : '$cur/$seg';
      final res = await _send('MKCOL', _url(cur));
      await res.drain<void>();
      final code = res.statusCode;
      if (code == 201 || code == 405 || code == 301 || code == 200) continue;
      throw CloudStorageException('创建云端目录失败：$cur → HTTP $code', code);
    }
  }

  @override
  Future<void> uploadFile(
    String remotePath,
    File localFile, {
    void Function(int sent, int total)? onProgress,
  }) async {
    if (!await localFile.exists()) {
      throw CloudStorageException('本地文件不存在：${localFile.path}');
    }
    final total = await localFile.length();
    final res = await _send('PUT', _url(remotePath),
        headers: {HttpHeaders.contentLengthHeader: '$total'},
        body: _chunkedReader(localFile, total, onProgress));
    await res.drain<void>();
    // 200/201/204 均视为成功
    if (res.statusCode >= 200 && res.statusCode < 300) return;
    throw CloudStorageException(
        '上传失败：$remotePath → HTTP ${res.statusCode}', res.statusCode);
  }

  /// 分块读文件并发送（边发边回报进度）。
  Stream<List<int>> _chunkedReader(
      File file, int total, void Function(int, int)? onProgress) async* {
    final raf = await file.open();
    var sent = 0;
    const chunkSize = 256 * 1024;
    try {
      while (true) {
        final chunk = await raf.read(chunkSize);
        if (chunk.isEmpty) break;
        sent += chunk.length;
        yield chunk;
        onProgress?.call(sent, total);
      }
    } finally {
      await raf.close();
    }
  }

  @override
  Future<void> downloadFile(
    String remotePath,
    File localFile, {
    void Function(int received, int total)? onProgress,
  }) async {
    final res = await _send('GET', _url(remotePath));
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw CloudStorageException(
          '下载失败：$remotePath → HTTP ${res.statusCode}', res.statusCode);
    }
    final total = res.contentLength; // 可能为 -1（未知）
    await localFile.parent.create(recursive: true);
    final sink = localFile.openWrite();
    var received = 0;
    try {
      await for (final chunk in res) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total < 0 ? received : total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
  }

  @override
  Future<List<CloudObject>> list(String remoteDir) async {
    final res = await _send('PROPFIND', _url(remoteDir),
        headers: {'Depth': '1'});
    if (res.statusCode == 404) {
      await res.drain<void>();
      return const []; // 目录不存在 = 空
    }
    if (res.statusCode != 207 && res.statusCode != 200) {
      await res.drain<void>();
      throw CloudStorageException(
          '列目录失败：$remoteDir → HTTP ${res.statusCode}', res.statusCode);
    }
    final xml = await utf8.decodeStream(res);
    return _parsePropfind(xml, remoteDir);
  }

  @override
  Future<void> deleteObject(String remotePath) async {
    final res = await _send('DELETE', _url(remotePath));
    await res.drain<void>();
    final code = res.statusCode;
    // 204/200 = 删了；404 = 本就不存在（幂等）；其余报错
    if (code == 204 || code == 200 || code == 404) return;
    throw CloudStorageException('删除失败：$remotePath → HTTP $code', code);
  }

  // ---------------------------------------------------------------------------
  // PROPFIND 轻量解析（⛔ 不引入 XML 库；命名空间前缀宽松匹配）
  // ---------------------------------------------------------------------------

  /// 从 multistatus XML 抽 (href, isCollection, contentLength)。
  /// 兼容 `<D:response>` / `<d:response>` / `<response>` 各种前缀。
  ///
  /// 🔴 href 含 **baseUrl 的路径段**（如坚果云 `/dav/`、Nextcloud
  /// `/remote.php/webdav/`），不能假设 href 直接以 remoteDir 开头 ——
  /// 需在段序列中**定位 remoteDir 的对齐位置**（回环探针抓出的生产 bug）。
  static List<CloudObject> _parsePropfind(String xml, String remoteDir) {
    final dirSegs =
        remoteDir.split('/').where((s) => s.isNotEmpty).toList();
    final out = <CloudObject>[];

    final responseRe = RegExp(r'<(?:\w+:)?response>(.*?)</(?:\w+:)?response>',
        dotAll: true);
    final hrefRe = RegExp(r'<(?:\w+:)?href>(.*?)</(?:\w+:)?href>', dotAll: true);
    final lenRe = RegExp(r'<(?:\w+:)?getcontentlength>(\d+)</', dotAll: true);
    final collectionRe = RegExp(r'<(?:\w+:)?collection\s*/?>');

    for (final m in responseRe.allMatches(xml)) {
      final block = m.group(1)!;
      final hrefM = hrefRe.firstMatch(block);
      if (hrefM == null) continue;
      final href = _decodeHref(hrefM.group(1)!);
      final isCollection = collectionRe.hasMatch(block);
      final len = int.tryParse(lenRe.firstMatch(block)?.group(1) ?? '0') ?? 0;

      final segs = href
          .split('/')
          .where((s) => s.isNotEmpty)
          .map(Uri.decodeComponent)
          .toList();
      if (segs.length <= dirSegs.length) continue;

      // 在 segs 中找 dirSegs 的对齐位置（href 可能带任意服务前缀段）
      final aligned = _alignFrom(segs, dirSegs);
      if (aligned == null) continue; // 不是本目录树的内容
      final rel = segs.skip(aligned + dirSegs.length).toList();
      if (rel.isEmpty) continue; // 目录自身
      out.add(CloudObject(
        path: rel.join('/'),
        isDir: isCollection,
        size: isCollection ? 0 : len,
      ));
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  /// 返回 dirSegs 在 segs 中的起始下标（从后往前找，尾部对齐更快）；找不到返回 null。
  static int? _alignFrom(List<String> segs, List<String> dirSegs) {
    final last = dirSegs.last;
    for (var i = segs.length - dirSegs.length; i >= 0; i--) {
      if (segs[i + dirSegs.length - 1] != last) continue;
      var ok = true;
      for (var j = 0; j < dirSegs.length; j++) {
        if (segs[i + j] != dirSegs[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return i;
    }
    return null;
  }

  static String _decodeHref(String href) {
    var h = href.trim();
    // href 可能是完整 URL 或绝对路径；统一取 path 部分
    if (h.startsWith('http')) {
      final u = Uri.tryParse(h);
      if (u != null) h = u.path;
    }
    return h;
  }
}
