/// S3 兼容源 Provider —— Phase 5 二期（方案 §7）。
///
/// 覆盖：AWS S3 / Cloudflare R2 / Backblaze B2 / 阿里云 OSS / 腾讯云 COS /
/// MinIO / 群晖 NAS 等，全部走 **path-style + SigV4**（签名核心见 [SigV4]，
/// 已用 AWS 官方向量锁定）。
///
/// S3 语义差异（相对 WebDAV）：
/// - 「目录」= key 前缀，无实体 → [ensureDir] 为 no-op（PUT 自动建路径）；
/// - 目录列表用 ListObjectsV2 `delimiter=/`（CommonPrefixes 为子目录）；
/// - 递归删除 = 列全前缀逐个 DELETE（S3 无递归删除单请求）。
///
/// ⛔ 零 flutter 依赖（探针可实测）；分块收发，GB 级归档内存安全。
library;

import 'dart:convert';
import 'dart:io';

import 'cloud_storage_provider.dart';
import 'sigv4.dart';

class S3Provider implements CloudStorageProvider {
  S3Provider({
    required this.endpoint,
    required this.region,
    required this.bucket,
    required this.accessKey,
    required this.secretKey,
  }) {
    var ep = endpoint.trim();
    if (ep.isEmpty) {
      throw CloudStorageException('S3 endpoint 未配置');
    }
    if (!ep.startsWith('http')) ep = 'https://$ep';
    _ep = Uri.parse(ep.endsWith('/') ? ep.substring(0, ep.length - 1) : ep);
    if (bucket.trim().isEmpty) {
      throw CloudStorageException('S3 bucket 未配置');
    }
  }

  final String endpoint; // 原始 endpoint（UI 回显用）
  final String region;
  final String bucket;
  final String accessKey;
  final String secretKey;

  late final Uri _ep;

  @override
  String get name => 'S3 兼容';

  // ---------------------------------------------------------------------------
  // HTTP 基座
  // ---------------------------------------------------------------------------

  Future<HttpClientResponse> _send(
    String method,
    String key,
    Map<String, String> query, {
    Map<String, String> extraHeaders = const {},
    Stream<List<int>>? body,
    void Function(int sent, int total)? onProgress,
    int totalForProgress = 0,
  }) async {
    final headers = SigV4.signedHeaders(
      method: method,
      bucket: bucket,
      key: key,
      query: query,
      endpoint: _ep.toString(),
      accessKey: accessKey,
      secretKey: secretKey,
      region: region,
      now: DateTime.now().toUtc(),
      extraHeaders: extraHeaders,
    );

    final path = key.isEmpty ? '/$bucket' : '/$bucket/${_encPath(key)}';
    final qParts = query.entries
        .map((e) =>
            '${awsUriEncode(e.key, encodeSlash: true)}=${awsUriEncode(e.value, encodeSlash: true)}')
        .toList()
      ..sort();
    final qs = query.isEmpty ? '' : qParts.join('&');
    final uri = Uri.parse('$_ep$path${qs.isEmpty ? '' : '?$qs'}');

    final client = HttpClient();
    try {
      final req = await client.openUrl(method, uri);
      headers.forEach(req.headers.set);
      if (body != null) {
        final total = totalForProgress > 0 ? totalForProgress : 0;
        var sent = 0;
        await for (final chunk in body) {
          req.add(chunk);
          sent += chunk.length;
          if (total > 0) onProgress?.call(sent, total);
          await req.flush();
        }
      }
      final res = await req.close();
      return res;
    } on SocketException catch (e) {
      throw CloudStorageException('无法连接 S3 服务（$_ep）：$e');
    } finally {
      // response 消费完由调用方 detach；client 关闭交给 destroy —— 这里
      // 不能在返回前关，改由 _send 完成后调用方读取完再 client.destroy?
      // HttpClient 无 per-request 关闭；用一个共享惰性 client 更好，但
      // Provider 是短生命周期对象（每次 makeProvider 新建），直接不复用。
      client.close(force: false);
    }
  }

  String _encPath(String key) =>
      key.split('/').map(awsUriEncode).join('/');

  Future<String> _readBody(HttpClientResponse res) =>
      res.transform(utf8.decoder).join();

  /// 非 2xx → 抛带语义的异常。
  void _check(HttpClientResponse res, String what) {
    if (res.statusCode >= 200 && res.statusCode < 300) return;
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw CloudStorageException('S3 鉴权失败（AccessKey / SecretKey / region 不匹配？）',
          res.statusCode);
    }
    if (res.statusCode == 404) {
      throw CloudStorageException('S3 bucket 不存在（或 key 不存在）：$bucket',
          res.statusCode);
    }
    throw CloudStorageException('S3 $what 失败：HTTP ${res.statusCode}',
        res.statusCode);
  }

  // ---------------------------------------------------------------------------
  // CloudStorageProvider
  // ---------------------------------------------------------------------------

  @override
  Future<void> testConnection() async {
    // 列 bucket 根 1 个对象：bucket 存在 + 凭据正确 即通。
    final res = await _send('GET', '', {
      'list-type': '2',
      'max-keys': '1',
    });
    _check(res, '连接测试');
    await res.drain<void>();
  }

  @override
  Future<void> ensureDir(String remoteDir) async {
    // S3：前缀即目录，PUT 自动创建路径 —— no-op。
  }

  @override
  Future<void> uploadFile(
    String remotePath,
    File localFile, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final total = await localFile.length();
    final res = await _send(
      'PUT',
      remotePath,
      const {},
      body: localFile.openRead(),
      onProgress: onProgress,
      totalForProgress: total,
    );
    _check(res, '上传 ${localFile.path}');
    await res.drain<void>();
  }

  @override
  Future<void> downloadFile(
    String remotePath,
    File localFile, {
    void Function(int received, int total)? onProgress,
  }) async {
    final res = await _send('GET', remotePath, const {});
    _check(res, '下载 $remotePath');
    final total = res.contentLength > 0 ? res.contentLength : 0;
    await localFile.parent.create(recursive: true);
    final sink = localFile.openWrite();
    var done = 0;
    try {
      await for (final chunk in res) {
        sink.add(chunk);
        done += chunk.length;
        if (total > 0) onProgress?.call(done, total);
      }
      await sink.flush();
      await sink.close();
    } catch (_) {
      await sink.close();
      rethrow;
    }
  }

  @override
  Future<List<CloudObject>> list(String remoteDir) async {
    final prefix = remoteDir.endsWith('/') ? remoteDir : '$remoteDir/';
    final out = <CloudObject>[];
    String? token;

    // 分页循环（每页 1000；100 页保护 ≈ 10 万对象，远超归档场景）
    for (var page = 0; page < 100; page++) {
      final query = <String, String>{
        'list-type': '2',
        'prefix': prefix,
        'delimiter': '/',
        'max-keys': '1000',
        if (token != null) 'continuation-token': token,
      };
      final res = await _send('GET', '', query);
      _check(res, '列表 $remoteDir');
      final xml = await _readBody(res);
      out.addAll(_parseListV2(xml, prefix));
      token = _firstTag(xml, 'NextContinuationToken');
      final truncated = _firstTag(xml, 'IsTruncated') == 'true';
      if (!truncated || token == null || token.isEmpty) break;
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  @override
  Future<void> deleteObject(String remotePath) async {
    // 目录语义：先列全前缀逐个删；无子对象再删单 key（幂等，覆盖文件情形）。
    final children = await _listAllFlat('$remotePath/');
    if (children.isNotEmpty) {
      for (final key in children) {
        final res = await _send('DELETE', key, const {});
        if (res.statusCode >= 200 && res.statusCode < 300) {
          await res.drain<void>();
          continue;
        }
        // 删除中途失败：抛出，调用方重试幂等
        _check(res, '删除 $key');
      }
      return;
    }
    final res = await _send('DELETE', remotePath, const {});
    _check(res, '删除 $remotePath');
    await res.drain<void>();
  }

  Future<List<String>> _listAllFlat(String prefix) async {
    final keys = <String>[];
    String? token;
    for (var page = 0; page < 100; page++) {
      final query = <String, String>{
        'list-type': '2',
        'prefix': prefix,
        'max-keys': '1000',
        if (token != null) 'continuation-token': token,
      };
      final res = await _send('GET', '', query);
      _check(res, '列表 $prefix');
      final xml = await _readBody(res);
      keys.addAll(_allKeys(xml));
      token = _firstTag(xml, 'NextContinuationToken');
      final truncated = _firstTag(xml, 'IsTruncated') == 'true';
      if (!truncated || token == null || token.isEmpty) break;
    }
    return keys;
  }

  // ---------------------------------------------------------------------------
  // ListObjectsV2 XML 轻量解析（正则；key 实体解码）
  // ---------------------------------------------------------------------------

  static List<CloudObject> _parseListV2(String xml, String prefix) {
    final out = <CloudObject>[];
    for (final m in _prefixRe.allMatches(xml)) {
      final p = _decode(_inner(m.group(1)!));
      // 🔴 真实 S3 的 CommonPrefixes 恒带尾 '/'（如 '2026-10-03_sealed/'），
      // 与目录 path 约定（不带尾斜杠）不一致，必须剥掉。
      final trimmed = p.endsWith('/') ? p.substring(0, p.length - 1) : p;
      if (trimmed == prefix || trimmed.isEmpty) continue; // 目录自身
      if (!trimmed.startsWith(prefix)) continue;
      out.add(CloudObject(
        path: trimmed.substring(prefix.length),
        isDir: true,
      ));
    }
    for (final m in _contentsRe.allMatches(xml)) {
      final block = m.group(1)!;
      final key = _decode(_firstTagIn(block, 'Key') ?? '');
      if (key.isEmpty || key == prefix) continue;
      if (!key.startsWith(prefix)) continue;
      final size = int.tryParse(_firstTagIn(block, 'Size') ?? '0') ?? 0;
      out.add(CloudObject(
        path: key.substring(prefix.length),
        isDir: false,
        size: size,
      ));
    }
    return out;
  }

  static List<String> _allKeys(String xml) {
    final out = <String>[];
    for (final m in _contentsRe.allMatches(xml)) {
      final key = _decode(_firstTagIn(m.group(1)!, 'Key') ?? '');
      if (key.isNotEmpty) out.add(key);
    }
    return out;
  }

  static final RegExp _prefixRe =
      RegExp(r'<\w*:?(?:CommonPrefixes)>\s*<\w*:?(?:Prefix)>(.*?)</', dotAll: true);
  static final RegExp _contentsRe =
      RegExp(r'<\w*:?(?:Contents)>(.*?)</\w*:?(?:Contents)>', dotAll: true);

  static String? _firstTag(String xml, String tag) =>
      _firstTagIn(xml, tag);

  static String? _firstTagIn(String xml, String tag) {
    final m = RegExp('<(?:\\w+:)?$tag>(.*?)</(?:\\w+:)?$tag>',
            dotAll: true)
        .firstMatch(xml);
    return m?.group(1);
  }

  static String _inner(String s) => s.trim();

  static String _decode(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
}
