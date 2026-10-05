import 'dart:async';

import 'package:flutter/foundation.dart';

/// 系统提示的语义等级。
///
/// 决定气泡配色（实心底 + 白字，沿用旧底部提示条的色义）：
/// - [success] 绿、[warning] 黄、[error] 红、[info] 蓝。
enum NoticeLevel { success, warning, error, info }

/// 一条系统提示。
@immutable
class SystemNotice {
  const SystemNotice({
    required this.id,
    required this.level,
    required this.message,
    this.title,
    this.autoDismissAfter,
    required this.createdAt,
  });

  /// 进程内自增唯一 id。
  final int id;

  final NoticeLevel level;

  /// 正文文案。
  final String message;

  /// 可选小标题（气泡首行，如「操作成功」「出错了」）。
  final String? title;

  /// 自动收起时长；`null` = 常驻，需用户手动叉掉。
  final Duration? autoDismissAfter;

  final DateTime createdAt;
}

/// 全局系统提示总线。
///
/// 取代原先散落在各处的 `ScaffoldMessenger.showSnackBar` 底部提示条：
/// 所有提示统一进入本服务，由 `SystemNoticeLayer`（挂在应用最上层）
/// 在用户按钮一侧渲染成聊天气泡。
///
/// 设计要点：
/// - **单例 + [ChangeNotifier]**：与 `AppThemeManager` / `BigPictureManager`
///   同款模式，任意位置可 `SystemNoticeService.instance.push(...)`；
/// - **去重**：与当前可见提示「等级 + 文案」完全一致时不再入栈，
///   只重置其自动收起计时——避免后台任务高频报同一错误刷屏；
/// - **限量**：同屏最多 [maxVisible] 条，超出淘汰最旧一条。
class SystemNoticeService extends ChangeNotifier {
  SystemNoticeService._();

  static final SystemNoticeService instance = SystemNoticeService._();

  /// 同屏最多保留的提示条数，超出时淘汰最旧一条。
  static const int maxVisible = 4;

  final List<SystemNotice> _notices = <SystemNotice>[];
  final Map<int, Timer> _timers = <int, Timer>{};
  int _seq = 0;

  /// 当前待展示提示（**最旧在前，最新在后**）。
  ///
  /// 渲染层按锚点方位决定视觉顺序：桌面（气泡在头像上方、向上生长）
  /// 直接顺序渲染；BPM（气泡在顶栏按钮下方、向下生长）需反转。
  List<SystemNotice> get notices => List<SystemNotice>.unmodifiable(_notices);

  bool get isEmpty => _notices.isEmpty;

  /// 推送一条提示，返回其唯一 id。
  int push({
    required NoticeLevel level,
    required String message,
    String? title,
    Duration? autoDismissAfter,
  }) {
    final dupIndex = _indexOfDuplicate(level, message);
    if (dupIndex != null) {
      final existing = _notices[dupIndex];
      _timers.remove(existing.id)?.cancel();
      _scheduleAutoDismiss(existing);
      notifyListeners();
      return existing.id;
    }

    final notice = SystemNotice(
      id: ++_seq,
      level: level,
      message: message,
      title: title,
      autoDismissAfter: autoDismissAfter,
      createdAt: DateTime.now(),
    );
    _notices.add(notice);
    while (_notices.length > maxVisible) {
      _removeAt(0);
    }
    _scheduleAutoDismiss(notice);
    notifyListeners();
    return notice.id;
  }

  /// 关闭指定提示；已不存在时静默忽略。
  void dismiss(int id) {
    final index = _notices.indexWhere((n) => n.id == id);
    if (index < 0) return;
    _removeAt(index);
    notifyListeners();
  }

  /// 关闭全部提示。
  void clear() {
    if (_notices.isEmpty) return;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _notices.clear();
    notifyListeners();
  }

  int? _indexOfDuplicate(NoticeLevel level, String message) {
    for (var i = 0; i < _notices.length; i++) {
      final n = _notices[i];
      if (n.level == level && n.message == message) return i;
    }
    return null;
  }

  void _scheduleAutoDismiss(SystemNotice notice) {
    final delay = notice.autoDismissAfter;
    if (delay == null || delay <= Duration.zero) return;
    _timers[notice.id] = Timer(delay, () => dismiss(notice.id));
  }

  void _removeAt(int index) {
    final notice = _notices.removeAt(index);
    _timers.remove(notice.id)?.cancel();
  }
}
