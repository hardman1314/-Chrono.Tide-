/// 手柄子系统日志（Phase 2）—— debugPrint + 落盘 `logs/gamepad_adaptation.log`
///
/// 为什么要落盘：适配会话的生命周期（确认/启停/设备增删/断连）发生在原生层，
/// release 构建的 debugPrint 不可见。真机排查「手柄断连」时，这份日志是
/// 唯一的时间线证据。
///
/// 约束：**绝不抛错、绝不阻塞**（写失败静默吞掉）；文件超过 1MB 自动重开
/// （会话级日志量极小，正常永远触发不到）。
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../core/path_helper.dart';

abstract final class GamepadLog {
  static const int _maxBytes = 1 << 20; // 1MB

  static void log(Object message) {
    debugPrint('[GAMEPAD] $message');
    try {
      final file = File(PathHelper.gamepadLogFilePath);
      final parent = file.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      if (file.existsSync() && file.lengthSync() > _maxBytes) {
        file.deleteSync(); // 超限重开（日志是会话级证据，丢了可接受）
      }
      final ts = DateTime.now().toIso8601String().substring(11, 23); // HH:mm:ss.mmm
      file.writeAsStringSync('[$ts] $message\n',
          mode: FileMode.append, flush: false);
    } catch (_) {
      // 日志绝不反向影响主流程
    }
  }
}
