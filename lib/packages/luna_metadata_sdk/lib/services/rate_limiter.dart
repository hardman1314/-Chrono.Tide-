import 'package:flutter/foundation.dart';

import '../models/game.dart';

/// 速率限制器（P0.2）
///
/// 参考 LunaBox 的双层限流设计，为每个数据源维护独立的限流策略，
/// 避免并发批量抓取时触发远端 429（Too Many Requests）封禁。
///
/// 两层限流：
/// 1. **最小间隔**（minInterval）：相邻两次请求间的最小时间间隔。
/// 2. **滑动窗口**（maxInWindow / windowDuration）：窗口内允许的最大请求数。
///
/// 429 退避：收到 429 时调用 [reportRateLimit]，后续 [acquire] 会阻塞到
/// 退避截止时间。优先使用 `Retry-After` 响应头，否则指数退避（1s→2s→4s，上限 30s）。
///
/// 用法：
/// ```dart
/// await RateLimiter.forSource(SourceType.vndb).acquire();
/// final response = await dio.post(...);
/// if (response.statusCode == 429) {
///   RateLimiter.forSource(SourceType.vndb)
///       .reportRateLimit(retryAfter: parseRetryAfter(response));
///   // 重试一次
/// }
/// ```
class RateLimiter {
  static final Map<SourceType, RateLimiter> _registry = {};

  final Duration minInterval;
  final int maxInWindow;
  final Duration windowDuration;

  DateTime? _lastRequestAt;
  final List<DateTime> _window = [];
  DateTime? _rateLimitedUntil;
  int _consecutiveRateLimits = 0;

  RateLimiter({
    required this.minInterval,
    required this.maxInWindow,
    required this.windowDuration,
  });

  /// 获取指定数据源的限流器（每源独立单例）
  static RateLimiter forSource(SourceType source) {
    return _registry[source] ??= _createDefault(source);
  }

  static RateLimiter _createDefault(SourceType source) {
    switch (source) {
      case SourceType.vndb:
        return RateLimiter(
          minInterval: const Duration(milliseconds: 200),
          maxInWindow: 200,
          windowDuration: const Duration(seconds: 60),
        );
      case SourceType.bangumi:
        return RateLimiter(
          minInterval: const Duration(milliseconds: 1000),
          maxInWindow: 30,
          windowDuration: const Duration(seconds: 60),
        );
      case SourceType.steam:
        return RateLimiter(
          minInterval: const Duration(milliseconds: 500),
          maxInWindow: 100,
          windowDuration: const Duration(seconds: 60),
        );
      case SourceType.dlsite:
        return RateLimiter(
          minInterval: const Duration(milliseconds: 800),
          maxInWindow: 60,
          windowDuration: const Duration(seconds: 60),
        );
      case SourceType.erogamescape:
        return RateLimiter(
          minInterval: const Duration(milliseconds: 1000),
          maxInWindow: 30,
          windowDuration: const Duration(seconds: 60),
        );
      case SourceType.ymgal:
        return RateLimiter(
          minInterval: const Duration(milliseconds: 500),
          maxInWindow: 60,
          windowDuration: const Duration(seconds: 60),
        );
      case SourceType.touchgal:
        return RateLimiter(
          minInterval: const Duration(milliseconds: 500),
          maxInWindow: 60,
          windowDuration: const Duration(seconds: 60),
        );
      case SourceType.hikarinagi:
        return RateLimiter(
          minInterval: const Duration(milliseconds: 300),
          maxInWindow: 100,
          windowDuration: const Duration(seconds: 60),
        );
      case SourceType.kun:
        return RateLimiter(
          minInterval: const Duration(milliseconds: 400),
          maxInWindow: 60,
          windowDuration: const Duration(seconds: 60),
        );
      case SourceType.nextmoe:
        // NextMoe free 档官方限额 60 次/分（超限 429 + Retry-After）。
        // 每游戏消耗 2 次（搜索+详情），预留安全余量取 55/分
        return RateLimiter(
          minInterval: const Duration(milliseconds: 1100),
          maxInWindow: 55,
          windowDuration: const Duration(seconds: 60),
        );
      case SourceType.ct:
        // CT 探索库：自建 PocketBase（京东云），资源自有，限流宽松
        return RateLimiter(
          minInterval: const Duration(milliseconds: 200),
          maxInWindow: 100,
          windowDuration: const Duration(seconds: 60),
        );
      default:
        return RateLimiter(
          minInterval: const Duration(milliseconds: 500),
          maxInWindow: 60,
          windowDuration: const Duration(seconds: 60),
        );
    }
  }

  /// 阻塞至允许发起下一次请求
  ///
  /// 依次等待：429 退避 → 最小间隔 → 滑动窗口可用配额。
  Future<void> acquire() async {
    // 1. 429 退避
    final limitedUntil = _rateLimitedUntil;
    if (limitedUntil != null) {
      final remaining = limitedUntil.difference(DateTime.now());
      if (remaining > Duration.zero) {
        debugPrint('[RateLimiter] ⏳ 等待 429 退避: ${remaining.inMilliseconds}ms');
        await Future.delayed(remaining);
      }
      _rateLimitedUntil = null;
    }

    // 2. 最小间隔
    final last = _lastRequestAt;
    if (last != null) {
      final elapsed = DateTime.now().difference(last);
      final wait = minInterval - elapsed;
      if (wait > Duration.zero) {
        await Future.delayed(wait);
      }
    }

    // 3. 滑动窗口配额
    if (maxInWindow > 0) {
      final now = DateTime.now();
      _window.removeWhere((t) => now.difference(t) > windowDuration);
      if (_window.length >= maxInWindow) {
        final oldest = _window.first;
        final wait = windowDuration - now.difference(oldest);
        if (wait > Duration.zero) {
          await Future.delayed(wait);
        }
        _window.removeWhere((t) => DateTime.now().difference(t) > windowDuration);
      }
      _window.add(DateTime.now());
    }

    _lastRequestAt = DateTime.now();
  }

  /// 收到 429 时调用，记录退避时间
  ///
  /// [retryAfter] 优先使用响应头 `Retry-After`（秒数）；
  /// 未提供则指数退避：1s → 2s → 4s，上限 30s。
  void reportRateLimit({Duration? retryAfter}) {
    _consecutiveRateLimits++;
    Duration backoff;
    if (retryAfter != null && retryAfter > Duration.zero) {
      backoff = retryAfter;
    } else {
      final exp = 1 << (_consecutiveRateLimits - 1).clamp(0, 5); // 1,2,4,8,16,32
      backoff = Duration(seconds: exp.clamp(1, 30));
    }
    _rateLimitedUntil = DateTime.now().add(backoff);
    debugPrint(
        '[RateLimiter] 🚫 429 限流，退避 ${backoff.inSeconds}s (连续第 $_consecutiveRateLimits 次)');
  }

  /// 请求成功时重置连续限流计数
  void reportSuccess() {
    _consecutiveRateLimits = 0;
  }

  /// 重置所有限流状态（测试 / 代理变更后清理用）
  static void resetAll() {
    for (final limiter in _registry.values) {
      limiter._rateLimitedUntil = null;
      limiter._consecutiveRateLimits = 0;
      limiter._window.clear();
      limiter._lastRequestAt = null;
    }
  }
}
