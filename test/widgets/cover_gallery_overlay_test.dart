import 'dart:io';

import 'package:chrono_tide/theme/theme_registry.dart';
import 'package:chrono_tide/widgets/cover_gallery_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 封面管理浮层回归（2026-10-05）。
///
/// 背景：图片层（InteractiveViewer，全窗口 Positioned.fill）曾被排在
/// 顶栏之后，吞掉整个窗口的指针事件 → 右上角关闭按钮点不到，
/// 用户无法退出相册（真机反馈）。修复 = Stack 顺序改为
/// 磨砂 → 图片 → 顶栏 → 工具条 → toast。
void main() {
  setUp(() {
    // AppColors 底层读 AppThemeManager.colors，未注册内置主题会抛 null check
    ThemeRegistry.registerBuiltinThemes();
  });

  CoverGalleryOverlay buildOverlay() {
    return CoverGalleryOverlay(
      metaDataDir: Directory.systemTemp.createTempSync('ct_gal_test').path,
      gameTitle: '回归测试游戏',
      onSetVertical: (_) async => true,
      onSetBanner: (_) async => true,
      onUpload: () async => 0,
      onDelete: (_) async => true,
    );
  }

  testWidgets('右上角关闭按钮可点击退出相册', (tester) async {
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  Navigator.of(ctx)
                      .push<void>(MaterialPageRoute(
                    builder: (_) => Scaffold(body: buildOverlay()),
                  ))
                      .then((_) => closed = true);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 修复前：InteractiveViewer 全窗口吞指针事件，此 tap 无法命中关闭按钮
    await tester.tap(find.byIcon(Icons.close_rounded),
        warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(closed, isTrue, reason: '点右上角关闭按钮必须能退出相册');
  });

  testWidgets('点击图片区不退出（拖拽观赏优先，只能按钮/Esc 关）', (tester) async {
    var closed = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  Navigator.of(ctx)
                      .push<void>(MaterialPageRoute(
                    builder: (_) => Scaffold(body: buildOverlay()),
                  ))
                      .then((_) => closed = true);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 图片区中央（InteractiveViewer 区域）单击不应关闭浮层
    final size = tester.getSize(find.byType(CoverGalleryOverlay));
    await tester.tapAt(Offset(size.width / 2, size.height / 2));
    await tester.pumpAndSettle();

    expect(closed, isFalse);
  });
}
