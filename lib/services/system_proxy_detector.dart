import 'dart:io';

import 'package:flutter/foundation.dart';

/// Windows 系统代理检测器
///
/// 参考 LunaBox 的 `internal/utils/proxyutils/net_proxy.go` 实现：
/// 读取 Windows IE 代理设置（注册表
/// `HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings`），
/// 解析 `ProxyEnable` (REG_DWORD) 和 `ProxyServer` (REG_SZ)。
///
/// 背景：Dart 的 `HttpClient.findProxyFromEnvironment` 仅读取
/// `HTTP_PROXY` / `HTTPS_PROXY` 环境变量，**不读取** Windows 系统代理设置。
/// 而 Clash / V2Ray 等工具的"系统代理"模式会把代理写入 Windows IE 代理
/// （注册表），浏览器正是通过 IE 代理设置的 WinINet/WinHTTP API 读取的。
/// 因此本检测器通过 `reg query` 命令补齐该能力，让本软件也能像 LunaBox
/// 和浏览器一样自动使用系统代理。
class SystemProxyDetector {
  static String? _cachedProxy;
  static DateTime? _cachedAt;
  static const Duration _cacheTtl = Duration(seconds: 60);

  /// 注册表路径
  static const String _regPath =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings';

  /// 读取 Windows IE 代理设置
  ///
  /// 返回代理地址（如 `127.0.0.1:7890`，不带 scheme），无代理或非
  /// Windows 平台时返回 null。
  ///
  /// 解析优先级（参考 LunaBox `parseWindowsProxyServer`）：
  /// `https=...;http=...;socks=...` 格式时 HTTPS > HTTP > SOCKS；
  /// `127.0.0.1:7890` 格式时直接返回。
  ///
  /// [forceRefresh] 为 true 时强制刷新缓存（忽略 60s TTL）。
  static Future<String?> detectProxy({bool forceRefresh = false}) async {
    // 非Windows平台不支持
    if (!Platform.isWindows) return null;

    // 检查缓存
    if (!forceRefresh &&
        _cachedProxy != null &&
        _cachedAt != null &&
        DateTime.now().difference(_cachedAt!) < _cacheTtl) {
      return _cachedProxy;
    }

    try {
      // 1. 读取 ProxyEnable（REG_DWORD，1=启用代理）
      final enableResult = await Process.run(
        'reg',
        ['query', _regPath, '/v', 'ProxyEnable'],
      );
      if (enableResult.exitCode != 0) {
        _updateCache(null);
        return null;
      }
      final enableText = enableResult.stdout as String;
      final proxyEnabled = _parseRegDword(enableText, 'ProxyEnable');
      if (proxyEnabled != 1) {
        debugPrint('[SystemProxyDetector] 系统代理未启用 (ProxyEnable=0)');
        _updateCache(null);
        return null;
      }

      // 2. 读取 ProxyServer（REG_SZ）
      final serverResult = await Process.run(
        'reg',
        ['query', _regPath, '/v', 'ProxyServer'],
      );
      if (serverResult.exitCode != 0) {
        debugPrint('[SystemProxyDetector] ProxyServer 不存在');
        _updateCache(null);
        return null;
      }
      final serverText = serverResult.stdout as String;
      final proxyServer = _parseRegSz(serverText, 'ProxyServer');
      if (proxyServer == null || proxyServer.isEmpty) {
        _updateCache(null);
        return null;
      }

      // 3. 解析 ProxyServer，选择优先级最高的代理
      final proxy = _selectBestProxy(proxyServer);
      if (proxy != null) {
        debugPrint('[SystemProxyDetector] ✅ 检测到系统代理: $proxy');
      }
      _updateCache(proxy);
      return proxy;
    } catch (e) {
      debugPrint('[SystemProxyDetector] ⚠️ 读取系统代理失败: $e');
      _updateCache(null);
      return null;
    }
  }

  static void _updateCache(String? proxy) {
    _cachedProxy = proxy;
    _cachedAt = DateTime.now();
  }

  /// 从 `reg query` 输出解析 REG_DWORD 值
  ///
  /// 输出示例（4空格缩进）：
  /// ```
  /// HKEY_CURRENT_USER\...\Internet Settings
  ///     ProxyEnable    REG_DWORD    0x1
  /// ```
  static int? _parseRegDword(String output, String valueName) {
    for (final line in output.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.contains(valueName) && trimmed.contains('REG_DWORD')) {
        final match = RegExp(r'0x([0-9a-fA-F]+)').firstMatch(trimmed);
        if (match != null) {
          return int.tryParse(match.group(1)!, radix: 16);
        }
      }
    }
    return null;
  }

  /// 从 `reg query` 输出解析 REG_SZ 值
  ///
  /// 输出示例：
  /// ```
  /// HKEY_CURRENT_USER\...\Internet Settings
  ///     ProxyServer    REG_SZ    127.0.0.1:7890
  /// ```
  static String? _parseRegSz(String output, String valueName) {
    for (final line in output.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.contains(valueName) && trimmed.contains('REG_SZ')) {
        final idx = trimmed.indexOf('REG_SZ');
        if (idx >= 0) {
          final value = trimmed.substring(idx + 'REG_SZ'.length).trim();
          return value.isEmpty ? null : value;
        }
      }
    }
    return null;
  }

  /// 从 ProxyServer 值中选择优先级最高的代理
  ///
  /// ProxyServer 可能的格式：
  /// 1. `127.0.0.1:7890` — 通用代理（所有协议共用）
  /// 2. `http=127.0.0.1:7890;https=127.0.0.1:7890;socks=127.0.0.1:7891`
  ///
  /// 优先级：HTTPS > HTTP > SOCKS > 通用项
  /// 返回 `host:port` 格式（不带 scheme），适配 Dio 的 `PROXY host:port` 语法。
  static String? _selectBestProxy(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return null;

    // 格式1：不含 '='，整体作为代理地址
    if (!value.contains('=')) {
      return _stripScheme(value);
    }

    // 格式2：含 '='，按协议分项
    String? httpsProxy;
    String? httpProxy;
    String? socksProxy;
    String? genericProxy;

    for (final entry in value.split(';')) {
      final parts = entry.trim().split('=');
      if (parts.length != 2) continue;
      final key = parts[0].trim().toLowerCase();
      final val = parts[1].trim();
      if (val.isEmpty) continue;
      final cleaned = _stripScheme(val);

      switch (key) {
        case 'https':
          httpsProxy ??= cleaned;
          break;
        case 'http':
          httpProxy ??= cleaned;
          break;
        case 'socks':
        case 'socks5':
          socksProxy ??= cleaned;
          break;
        default:
          genericProxy ??= cleaned;
      }
    }

    return httpsProxy ?? httpProxy ?? socksProxy ?? genericProxy;
  }

  /// 去掉代理地址的 scheme 前缀（http://, https://, socks5://）
  static String _stripScheme(String proxy) {
    var p = proxy.trim();
    for (final scheme in ['http://', 'https://', 'socks5://', 'socks://']) {
      if (p.toLowerCase().startsWith(scheme)) {
        p = p.substring(scheme.length);
        break;
      }
    }
    return p.trim();
  }
}
