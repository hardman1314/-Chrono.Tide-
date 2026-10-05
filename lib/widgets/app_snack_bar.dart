import 'package:flutter/material.dart';

import '../services/system_notice_service.dart';

export '../services/system_notice_service.dart' show NoticeLevel;

/// 统一提示工具（全项目唯一入口）。
///
/// **实现已迁移**：早先本类把提示转成 `ScaffoldMessenger.showSnackBar`
/// ——即底部那条红/黄/绿浮动提示条，会遮挡底部操作区。现在改为推送到
/// [SystemNoticeService]，由 `SystemNoticeLayer`（挂在 `MaterialApp.builder`
/// 最顶层）在右下角用户按钮一侧渲染成聊天气泡。
///
/// 4 个方法**签名保持不变**，因此既有 125 处调用点无需任何改动即自动切换。
///
/// 用法：
/// ```dart
/// AppSnackBar.success(context, '操作成功');
/// AppSnackBar.error(context, '操作失败');
/// AppSnackBar.warning(context, '请注意...');
/// AppSnackBar.info(context, '提示信息');
/// ```
class AppSnackBar {
  AppSnackBar._();

  /// 成功 / 提示：短驻留后自动收起。
  static const Duration _shortLived = Duration(milliseconds: 2500);

  /// 警告：停留久一点，但会自行收起（不长期占位）。
  static const Duration _warningLived = Duration(milliseconds: 8000);

  /// 错误：需要用户看清，但不再常驻 —— 15 秒自动收起（带倒计时条）。
  /// （2026-10-03 开发者拍板：错误类不再常驻；30s 体感偏长，改 15s。）
  static const Duration _errorLived = Duration(seconds: 15);

  static void success(BuildContext context, String message,
      {Duration? duration}) {
    _push(NoticeLevel.success, message, duration ?? _shortLived);
  }

  static void error(BuildContext context, String message,
      {Duration? duration}) {
    // 错误默认驻留 15s 后自动收起（带进度条）；传 duration 可覆盖时长。
    _push(NoticeLevel.error, message, duration ?? _errorLived);
  }

  static void warning(BuildContext context, String message,
      {Duration? duration}) {
    _push(NoticeLevel.warning, message, duration ?? _warningLived);
  }

  static void info(BuildContext context, String message,
      {Duration? duration}) {
    _push(NoticeLevel.info, message, duration ?? _shortLived);
  }

  /// 按等级派发（供需要动态等级的封装器复用，避免各自重写默认时长）。
  static void show(
    BuildContext context,
    NoticeLevel level,
    String message, {
    Duration? duration,
  }) {
    switch (level) {
      case NoticeLevel.success:
        success(context, message, duration: duration);
        return;
      case NoticeLevel.warning:
        warning(context, message, duration: duration);
        return;
      case NoticeLevel.error:
        error(context, message, duration: duration);
        return;
      case NoticeLevel.info:
        info(context, message, duration: duration);
        return;
    }
  }

  static void _push(NoticeLevel level, String message, Duration? duration) {
    SystemNoticeService.instance.push(
      level: level,
      message: message,
      autoDismissAfter: duration,
    );
  }
}
