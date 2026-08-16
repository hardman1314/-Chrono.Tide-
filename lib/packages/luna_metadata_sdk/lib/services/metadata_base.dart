import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

import '../models/game.dart';
import '../models/tags.dart';
import 'rate_limiter.dart';

String? safeString(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is String) return value.isNotEmpty ? value : null;
  if (value is num) return value.toString();
  return value.toString();
}

double? safeDouble(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is double) return value;
  if (value is int) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

int? safeInt(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is int) return value;
  if (value is double) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

Map<String, dynamic>? safeMap(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return null;
}

List<dynamic>? safeList(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is List) return value;
  return null;
}

bool? safeBool(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is bool) return value;
  if (value is String) return value.toLowerCase() == 'true' || value == '1';
  if (value is num) return value != 0;
  return null;
}

/// 从源 Dio 复制代理配置到目标 Dio
///
/// **关键**：不共享 adapter 对象本身，而是创建目标 Dio 自己的
/// `DefaultHttpClientAdapter` 并复制 `onHttpClientCreate` 回调。
/// 这样每个服务拥有独立的 adapter（避免共享 HttpClient 内部状态），
/// 但代理配置一致。
///
/// **[source] 可为 null**：直连平台（VNDB/Steam/月幕GAL/KunGal/Hikarinagi）
/// 在 [MetadataFetcher._instantiateService] 中以 `dio: null` 实例化。
/// 此时必须显式设置 `client.findProxy = (uri) => 'DIRECT'`，否则 Dart
/// `HttpClient()` 在 Windows 上会默认读取系统代理设置（WinINET/注册表），
/// 当用户关闭 VPN 但注册表残留代理配置时，所有请求尝试连接死代理 → 全部失败。
///
/// 同样地，当 [source] 非 null 但其 `onHttpClientCreate` 回调为 null
/// （未配置代理）时，也走 DIRECT 分支，保证直连平台绝不读取系统代理。
void applyProxyConfig(Dio? source, Dio target) {
  final targetAdapter = target.httpClientAdapter;
  if (targetAdapter is! DefaultHttpClientAdapter) return;

  // 优先：从源 Dio 复制 onHttpClientCreate 回调（含代理设置）
  if (source != null) {
    final sourceAdapter = source.httpClientAdapter;
    if (sourceAdapter is DefaultHttpClientAdapter) {
      final callback = sourceAdapter.onHttpClientCreate;
      if (callback != null) {
        targetAdapter.onHttpClientCreate = callback;
        return;
      }
    }
  }

  // 兜底：无源 Dio 或无回调 → 显式 DIRECT，绝不让 HttpClient 读注册表
  targetAdapter.onHttpClientCreate = (client) {
    client.findProxy = (uri) => 'DIRECT';
    return client;
  };
}

// ==================== 抓取日志（运行时诊断）====================

String? _fetchLogPath;

/// 设置抓取日志文件路径（由 MetadataFetcher.init 调用）
///
/// 设置后，[fetchLog] 会将日志同时写入该文件（追加模式），
/// 便于 release 模式下诊断抓取失败原因（debugPrint 在 GUI release 不输出）。
void setFetchLogPath(String path) {
  _fetchLogPath = path;
}

/// 抓取日志：同时输出到 debugPrint 和文件（追加模式）
///
/// 用于在 release 构建中捕获各服务的实际错误信息，
/// 定位"抓不到数据"的根因（网络超时 / 解析失败 / 空结果 / 鉴权失败等）。
void fetchLog(String message) {
  debugPrint(message);
  final path = _fetchLogPath;
  if (path == null) return;
  try {
    final file = File(path);
    final dir = Directory(file.parent.path);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    file.writeAsStringSync(
      '${DateTime.now().toIso8601String()} | $message\n',
      mode: FileMode.append,
    );
  } catch (_) {
    // 日志写入失败不影响主流程
  }
}

/// 统一评分归一化（P1.3）
///
/// 将各数据源不同评分制归一化到 [0, 10] 区间：
/// - 100 分制（如 Metacritic 85）→ ÷10 = 8.5
/// - 已在 0–10 内 → 保持
/// - 超过 10 的值统一 ÷10 后 clamp
double normalizeRating(double raw) {
  if (raw <= 0) return 0.0;
  if (raw > 10) raw = raw / 10.0;
  return raw.clamp(0.0, 10.0);
}

/// 执行速率受限的 HTTP 请求，自动处理 429 退避与单次重试（P0.2）
///
/// 在请求前通过 [RateLimiter.acquire] 获取限流令牌；若返回 429，
/// 解析 `Retry-After` 响应头（优先）或指数退避，退避后重试一次。
Future<Response<T>> executeRateLimited<T>(
  SourceType source,
  Future<Response<T>> Function() request,
) async {
  final limiter = RateLimiter.forSource(source);
  await limiter.acquire();
  Response<T> response = await request();
  if (response.statusCode == 429) {
    Duration? retryAfter;
    final retryAfterStr = response.headers.value('retry-after');
    if (retryAfterStr != null) {
      final secs = int.tryParse(retryAfterStr);
      if (secs != null && secs > 0) {
        retryAfter = Duration(seconds: secs);
      }
    }
    limiter.reportRateLimit(retryAfter: retryAfter);
    debugPrint('[RateLimiter] [$source] 收到 429，退避后重试一次');
    await limiter.acquire();
    response = await request();
    if (response.statusCode != 429) {
      limiter.reportSuccess();
    }
  } else {
    limiter.reportSuccess();
  }
  return response;
}

abstract class MetadataSourceService {
  Future<MetadataResult> fetchByName(String name);

  /// 按 ID 批量查询（P1.1 前瞻接口）
  ///
  /// 默认未实现，抛 [UnimplementedError]。VNDB 等支持批量查询的源
  /// 覆盖此方法以单次请求获取多个游戏详情（如 VNDB 100 IDs/批）。
  /// 批量导入按名搜索无 ID，暂不消费此方法，主要为未来跨源补全铺路。
  Future<List<MetadataResult>> fetchByIds(List<String> ids) {
    throw UnimplementedError('$runtimeType.fetchByIds 未实现');
  }

  Future<bool> testConnection();
  SourceType get sourceType;
  String get sourceName;
}
