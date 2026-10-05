import 'package:chrono_tide/widgets/cover_preview_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chrono_tide/theme/theme_registry.dart';

/// 添加页封面预览浮层回归（2026-10-05）。
///
/// 背景：与封面管理浮层（cover_gallery_overlay）同样的 Stack 顺序 bug——
/// 全窗口 InteractiveViewer 图片层排在顶栏之后吞掉指针事件 → 右上角
/// 关闭按钮点不到（开发者真机截图反馈，探索/添加页「封面预览」）。
/// 修复 = Stack 顺序改为 磨砂 → 图片 → 顶栏 → 工具条。
void main() {
  setUp(() {
    // AppColors 底层读 AppThemeManager.colors，未注册内置主题会抛 null check
    ThemeRegistry.registerBuiltinThemes();
  });

  Future<void> pumpHost(WidgetTester tester, void Function() onClosed) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  Navigator.of(ctx)
                      .push<void>(MaterialPageRoute(
                    builder: (_) => Scaffold(
                      // 空 items：走「暂无封面图」分支，测试环境无网络
                      body: const CoverPreviewOverlay(
                        gameTitle: '回归测试游戏',
                        items: [],
                      ),
                    ),
                  ))
                      .then((_) => onClosed());
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
  }

  testWidgets('右上角关闭按钮可点击退出封面预览', (tester) async {
    var closed = false;
    await pumpHost(tester, () => closed = true);

    // 修复前：InteractiveViewer 全窗口吞指针事件，此 tap 无法命中关闭按钮
    await tester.tap(find.byIcon(Icons.close_rounded), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(closed, isTrue, reason: '点右上角关闭按钮必须能退出封面预览');
  });

  testWidgets('点击图片区不退出（只能按钮/Esc 关）', (tester) async {
    var closed = false;
    await pumpHost(tester, () => closed = false);

    final size = tester.getSize(find.byType(CoverPreviewOverlay));
    await tester.tapAt(Offset(size.width / 2, size.height / 2));
    await tester.pumpAndSettle();

    expect(closed, isFalse);
  });
}
