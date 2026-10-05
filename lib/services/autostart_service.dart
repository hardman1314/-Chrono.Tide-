import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/path_helper.dart';
import '../utils/network_path.dart';

/// 开机自启服务
///
/// 通过 Windows 注册表实现开机自启动：
/// HKCU\Software\Microsoft\Windows\CurrentVersion\Run
///
/// 自启动时附加 --silent 参数，应用以静默模式运行（仅托盘，不显示窗口）
class AutoStartService {
  static final AutoStartService _instance = AutoStartService._internal();
  static AutoStartService get instance => _instance;

  AutoStartService._internal();

  static const String _prefKey = 'autostart_enabled';
  static const String _registryKeyPath =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const String _registryValueName = 'ChronoTide';

  /// 检查是否已启用开机自启
  Future<bool> isEnabled() async {
    try {
      final result = await Process.run('reg', [
        'query',
        _registryKeyPath,
        '/v',
        _registryValueName,
      ]);
      return result.exitCode == 0 &&
          result.stdout.toString().contains(_registryValueName);
    } catch (e) {
      debugPrint('[AUTOSTART] 检查状态异常: $e');
      return false;
    }
  }

  /// 启用开机自启
  Future<bool> enable() async {
    try {
      final exePath = Platform.resolvedExecutable;
      // ★ 2026-09-26 NAS 适配：软件装在映射网络驱动器（Z:）上时，注册表 Run 里
      // 记盘符路径会在开机时失败 —— 登录阶段盘符可能尚未映射、或服务器未就绪。
      // 此时改写为该共享的 **UNC 等价路径**（不依赖盘符映射关系）；
      // 解析不出来就沿用原盘符路径，本地磁盘行为完全不变。
      final autostartExePath = NetworkPath.isMappedDrive(exePath)
          ? NetworkPath.toUniversalPath(exePath)
          : exePath;
      if (autostartExePath != exePath) {
        debugPrint('[AUTOSTART] 🌐 映射盘安装，自启改记 UNC 路径: $autostartExePath');
      }
      // 附加 --silent 参数，开机自启时静默运行
      final value = '"$autostartExePath" --silent';

      final result = await Process.run('reg', [
        'add',
        _registryKeyPath,
        '/v',
        _registryValueName,
        '/t',
        'REG_SZ',
        '/d',
        value,
        '/f',
      ]);

      if (result.exitCode == 0) {
        // 保存偏好设置
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_prefKey, true);
        debugPrint('[AUTOSTART] ✅ 开机自启已启用');
        return true;
      } else {
        debugPrint('[AUTOSTART] ❌ 启用失败: ${result.stderr}');
        return false;
      }
    } catch (e) {
      debugPrint('[AUTOSTART] ❌ 启用异常: $e');
      return false;
    }
  }

  /// 禁用开机自启
  Future<bool> disable() async {
    try {
      final result = await Process.run('reg', [
        'delete',
        _registryKeyPath,
        '/v',
        _registryValueName,
        '/f',
      ]);

      // exitCode 1 可能是因为值不存在，这也算成功
      if (result.exitCode == 0 || result.exitCode == 1) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(_prefKey, false);
        debugPrint('[AUTOSTART] ✅ 开机自启已禁用');
        return true;
      } else {
        debugPrint('[AUTOSTART] ❌ 禁用失败: ${result.stderr}');
        return false;
      }
    } catch (e) {
      debugPrint('[AUTOSTART] ❌ 禁用异常: $e');
      return false;
    }
  }

  /// 切换开关
  Future<bool> toggle() async {
    final enabled = await isEnabled();
    if (enabled) {
      return disable();
    } else {
      return enable();
    }
  }
}
