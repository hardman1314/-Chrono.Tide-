import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/services/system_notice_service.dart';

/// 系统提示总线 —— 入栈 / 去重 / 限量 / 关闭 / 自动收起
///
/// 覆盖范围说明（诚实标注）：
/// - 本文件只测**总线语义**（纯 Dart，无 UI）。
/// - **不测**渲染层 `SystemNoticeLayer` 的锚点、动画与视觉——那需要真实窗口与
///   真机走查（见 `docs/DEV/features/system_notice_bubble.md` §7）。
void main() {
  final svc = SystemNoticeService.instance;

  setUp(svc.clear);
  tearDown(svc.clear);

  test('push 入栈，字段可读', () {
    final id = svc.push(level: NoticeLevel.success, message: 'ok');
    expect(svc.notices.length, 1);
    expect(svc.notices.single.id, id);
    expect(svc.notices.single.level, NoticeLevel.success);
    expect(svc.notices.single.message, 'ok');
    expect(svc.notices.single.autoDismissAfter, isNull);
  });

  test('push / dismiss 会通知监听者', () {
    var count = 0;
    void listener() => count++;
    svc.addListener(listener);

    final id = svc.push(level: NoticeLevel.info, message: 'a');
    expect(count, 1);
    svc.dismiss(id);
    expect(count, 2);

    svc.removeListener(listener);
    svc.push(level: NoticeLevel.info, message: 'b');
    expect(count, 2, reason: '移除监听后不应再收到通知');
  });

  test('同等级 + 同文案不重复入栈（仅重置计时）', () {
    final a = svc.push(level: NoticeLevel.error, message: 'x');
    final b = svc.push(level: NoticeLevel.error, message: 'x');
    expect(svc.notices.length, 1);
    expect(a, b);

    // 等级不同 → 视为不同提示
    svc.push(level: NoticeLevel.warning, message: 'x');
    expect(svc.notices.length, 2);
  });

  test('超出 maxVisible 时淘汰最旧一条', () {
    for (var i = 0; i < SystemNoticeService.maxVisible + 2; i++) {
      svc.push(level: NoticeLevel.info, message: 'm$i');
    }
    expect(svc.notices.length, SystemNoticeService.maxVisible);
    expect(svc.notices.first.message, 'm2');
    expect(svc.notices.last.message, 'm5');
  });

  test('dismiss 按 id 关闭；未知 id 静默忽略；最旧在前', () {
    final a = svc.push(level: NoticeLevel.info, message: 'a');
    final b = svc.push(level: NoticeLevel.info, message: 'b');
    expect(svc.notices.map((e) => e.id).toList(), <int>[a, b]);

    svc.dismiss(a);
    expect(svc.notices.map((e) => e.id).toList(), <int>[b]);

    svc.dismiss(999999);
    expect(svc.notices.length, 1);
  });

  test('clear 清空全部', () {
    svc.push(level: NoticeLevel.info, message: 'a');
    svc.push(level: NoticeLevel.error, message: 'b');
    svc.clear();
    expect(svc.isEmpty, isTrue);
  });

  test('autoDismissAfter 到期自动收起；null 则常驻', () async {
    svc.push(
      level: NoticeLevel.success,
      message: 's',
      autoDismissAfter: const Duration(milliseconds: 30),
    );
    svc.push(level: NoticeLevel.error, message: 'e');

    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(svc.notices.length, 1);
    expect(svc.notices.single.message, 'e', reason: '错误档无 duration 应常驻');
  });
}
