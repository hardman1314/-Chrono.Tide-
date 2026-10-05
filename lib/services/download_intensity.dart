import 'dart:async';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

/// 下载强度档位（2026-09-26 批D，用户批准方案）。
///
/// - [auto]：维持 4MB 探测分档（2–4 连接），档位结果记忆 24h 免重复探测；
/// - [light]：单连接 + 8MB 分片，跳过探测，默认限速 2MB/s——弱网/低配/挂后台；
/// - [full]：6 连接 × 64MB，跳过探测——大带宽 / 局域网网盘。
///   6 连接依据：OpenList 类网盘对单 IP 通常限 8 连接以内，留余量避免 429。
enum DownloadIntensity { auto, light, full }

extension DownloadIntensityX on DownloadIntensity {
  String get label => switch (this) {
        DownloadIntensity.auto => '自动',
        DownloadIntensity.light => '轻量',
        DownloadIntensity.full => '全速',
      };

  String get description => switch (this) {
        DownloadIntensity.auto =>
          '探测实际网速自动分档（2–4 连接，档位记忆 24 小时）',
        DownloadIntensity.light =>
          '单连接 + 8MB 分片，跳过探测；适合弱网、低配设备或挂后台',
        DownloadIntensity.full =>
          '6 连接 × 64MB 分片，跳过探测；适合大带宽 / 局域网网盘',
      };
}

/// 强度档位与全局限速的 prefs 读写（两键为单一事实源）。
///
/// 键名：`download_intensity`（String）、`download_speed_limit_mbps`（double，0=不限）。
class DownloadIntensityPrefs {
  DownloadIntensityPrefs._();

  static const String _kIntensity = 'download_intensity';
  static const String _kSpeedLimitMbps = 'download_speed_limit_mbps';

  /// 轻量档默认限速（MB/s）：保证「弱网不抢前台」开箱即得。
  static const double lightDefaultLimitMbps = 2.0;

  static Future<DownloadIntensity> load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_kIntensity);
    for (final v in DownloadIntensity.values) {
      if (v.name == s) return v;
    }
    return DownloadIntensity.auto;
  }

  static Future<void> save(DownloadIntensity v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kIntensity, v.name);
  }

  /// 全局限速（MB/s）。0 = 不限速。
  static Future<double> loadSpeedLimitMbps() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getDouble(_kSpeedLimitMbps) ?? 0;
  }

  static Future<void> saveSpeedLimitMbps(double mbps) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kSpeedLimitMbps, mbps);
  }

  /// 读取限速并立即生效到令牌桶（下载内核每任务开始时调用一次）。
  static Future<void> applySpeedLimitToThrottle() async {
    final mbps = await loadSpeedLimitMbps();
    DownloadThrottle.configure(mbps <= 0 ? 0 : mbps * 1024 * 1024);
  }
}

/// 全局令牌桶限速器：所有下载任务共享一个桶（对总速率负责）。
///
/// rate <= 0 时完全直通（零开销路径，不进入 async 等待）。
/// 桶容量 = max(2MB, rate)：允许短突发后进入稳态节流；
/// 每秒按 [bytesPerSecond] 补充令牌，`acquire` 在数据块写盘前按块大小取令牌。
class DownloadThrottle {
  DownloadThrottle._();

  static double _rate = 0; // bytes/s，0 = 不限
  static double _tokens = 0;
  static DateTime _last = DateTime.now();

  static void configure(double bytesPerSecond) {
    _rate = bytesPerSecond <= 0 ? 0 : bytesPerSecond;
    _tokens = 0;
    _last = DateTime.now();
  }

  static double get _burst => math.max(2 * 1024 * 1024.0, _rate);

  /// 在数据块写入前调用；限速启用时按需等待令牌攒够。
  ///
  /// 单次等待上限 500ms：极低速率下大块（64KB）分多轮等待，
  /// 避免单次 sleep 过长阻塞事件循环的进度发射。
  static Future<void> acquire(int bytes) async {
    if (_rate <= 0) return;
    while (true) {
      final now = DateTime.now();
      final elapsedSec = now.difference(_last).inMicroseconds / 1e6;
      _last = now;
      _tokens = math.min(_burst, _tokens + elapsedSec * _rate);
      if (_tokens >= bytes) {
        _tokens -= bytes;
        return;
      }
      final needSec = (bytes - _tokens) / _rate;
      final us = (needSec * 1e6).ceil().clamp(1000, 500000);
      await Future<void>.delayed(Duration(microseconds: us));
    }
  }
}
