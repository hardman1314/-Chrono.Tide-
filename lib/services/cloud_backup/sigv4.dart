/// AWS Signature Version 4 —— S3 兼容源签名工具（纯 Dart，零外部依赖）。
///
/// HMAC-SHA256 来自 [sha256Bytes]/[hmacSha256]（NIST/RFC 4231 向量已锁）。
/// 本文件只负责 SigV4 流程本身：
///   canonical request → string to sign → signing key → Authorization 头。
///
/// 签名正确性由 `dev_probe/phase5_s3sig_probe.dart` 用 **AWS 官方文档
/// PUT Object 测试向量**（AKIAIOSFODNN7EXAMPLE / examplebucket /
/// 20130524T000000Z）逐字节锁定。
///
/// 决策：
/// - `x-amz-content-sha256` 恒发 `UNSIGNED-PAYLOAD`（HTTPS 传输层已有完整
///   性保护；GB 级归档流式上传时逐字节算 SHA-256 不可行）。
/// - header 值按规范 trim + 连续空格折叠，**不做 URI 编码**（boto3 等主流
///   SDK 行为；官方 GET+range 示例的编码写法存在争议，不采纳）。
/// - path-style：`{endpoint}/{bucket}/{key}`（对 MinIO / R2 / OSS 兼容层
///   最友好；virtual-hosted 风格需要通配符证书，自建场景反而添乱）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'sha256_hmac.dart';

/// RFC 3986 unreserved：A-Z a-z 0-9 `-` `.` `_` `~`。
bool _isUnreserved(int c) =>
    (c >= 0x41 && c <= 0x5a) ||
    (c >= 0x61 && c <= 0x7a) ||
    (c >= 0x30 && c <= 0x39) ||
    c == 0x2d || c == 0x2e || c == 0x5f || c == 0x7e;

/// AWS URI 编码（大写 %XX）。[encodeSlash]：query 值需要编码 `/`，path 段不需要。
String awsUriEncode(String s, {bool encodeSlash = false}) {
  final sb = StringBuffer();
  for (final code in utf8.encode(s)) {
    if (_isUnreserved(code)) {
      sb.writeCharCode(code);
    } else if (code == 0x2f && !encodeSlash) {
      sb.writeCharCode(code);
    } else {
      sb
        ..write('%')
        ..write(code.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
  }
  return sb.toString();
}

/// SigV4 签名核心（纯函数，便于探针）。
class SigV4 {
  SigV4._();

  /// 构造 Authorization 头。
  ///
  /// [canonicalQuery]：已按参数名排序、`k=awsUriEncode(v, encodeSlash:true)`
  /// 用 `&` 连接的字符串（可为空）。
  /// [headers]：参与签名的头（name 小写 → value 原文）。调用方必须已含
  /// `x-amz-date`；返回的 map 会补 `Authorization`。
  static String authorizationHeader({
    required String method,
    required String canonicalUri, // 已编码的路径，以 / 开头
    required String canonicalQuery,
    required Map<String, String> headers,
    required String payloadHash,
    required String accessKey,
    required String secretKey,
    required String region,
    required String service,
    required String amzDate, // yyyyMMdd'T'HHmmss'Z'
  }) {
    final dateStamp = amzDate.substring(0, 8);

    // 1. canonical headers：按名字排序，值 trim + 连续空格折叠
    final names = headers.keys.map((k) => k.toLowerCase()).toList()..sort();
    final canonHeaders = StringBuffer();
    for (final n in names) {
      final v = headers.entries
          .firstWhere((e) => e.key.toLowerCase() == n)
          .value
          .trim()
          .replaceAll(RegExp(r'\s+'), ' ');
      canonHeaders
        ..write(n)
        ..write(':')
        ..write(v)
        ..write('\n');
    }
    final signedHeaders = names.join(';');

    // 2. canonical request
    final canonicalRequest = [
      method,
      canonicalUri,
      canonicalQuery,
      canonHeaders.toString(),
      signedHeaders,
      payloadHash,
    ].join('\n');
    final crHash = bytesToHex(sha256Bytes(utf8.encode(canonicalRequest)));

    // 3. string to sign
    final scope = '$dateStamp/$region/$service/aws4_request';
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      scope,
      crHash,
    ].join('\n');

    // 4. signing key
    final kDate =
        hmacSha256(utf8.encode('AWS4$secretKey'), utf8.encode(dateStamp));
    final kRegion = hmacSha256(kDate, utf8.encode(region));
    final kService = hmacSha256(kRegion, utf8.encode(service));
    final kSigning = hmacSha256(kService, utf8.encode('aws4_request'));
    final signature =
        bytesToHex(hmacSha256(kSigning, utf8.encode(stringToSign)));

    return 'AWS4-HMAC-SHA256 Credential=$accessKey/$scope, '
        'SignedHeaders=$signedHeaders, Signature=$signature';
  }

  /// 便捷封装：签出一个 S3 请求的完整头集合（含 x-amz-date/content-sha256）。
  static Map<String, String> signedHeaders({
    required String method,
    required String bucket,
    required String key, // '' = bucket 根
    required Map<String, String> query, // 参数（自动排序编码）
    required String endpoint,
    required String accessKey,
    required String secretKey,
    required String region,
    required DateTime now,
    Map<String, String> extraHeaders = const {},
  }) {
    final amzDate = _amzDate(now);
    final uri = key.isEmpty ? '/$bucket' : '/$bucket/${_encodeKeyPath(key)}';
    final qParts = query.entries
        .map((e) =>
            '${awsUriEncode(e.key, encodeSlash: true)}=${awsUriEncode(e.value, encodeSlash: true)}')
        .toList()
      ..sort();
    final q = query.isEmpty ? '' : qParts.join('&');
    final headers = <String, String>{
      'host': Uri.parse(endpoint).host,
      'x-amz-date': amzDate,
      'x-amz-content-sha256': 'UNSIGNED-PAYLOAD',
      ...extraHeaders,
    };
    final auth = authorizationHeader(
      method: method,
      canonicalUri: uri,
      canonicalQuery: q,
      headers: headers,
      payloadHash: 'UNSIGNED-PAYLOAD',
      accessKey: accessKey,
      secretKey: secretKey,
      region: region,
      service: 's3',
      amzDate: amzDate,
    );
    return {
      ...headers,
      'Authorization': auth,
    };
  }

  static String _amzDate(DateTime utc) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${utc.year}${two(utc.month)}${two(utc.day)}'
        'T${two(utc.hour)}${two(utc.minute)}${two(utc.second)}Z';
  }

  /// S3 key 路径编码：逐段编码，`/` 保留。
  static String _encodeKeyPath(String key) => key
      .split('/')
      .map((seg) => awsUriEncode(seg))
      .join('/');
}
