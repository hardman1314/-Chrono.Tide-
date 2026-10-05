import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/theme/animated_background_image.dart';
import 'package:chrono_tide/theme/background_image_config.dart';

/// v3.10 动态背景图（GIF）—— 模型派生 + provider 形态 + Widget 装配
///
/// 覆盖范围说明（诚实标注）：
/// - 本文件**只测确定性逻辑**：派生 getter、序列化零迁移守卫、
///   provider key 相等语义（决定是否共享解码器）、Widget 装配参数。
/// - **不测**真实解码 / 播放 / 内存回收 —— Phase 0 已证实 flutter_tester
///   的假 async 环境无法驱动 `ImageProvider.resolve` 与 `ImageCache` 计费
///   （`dev_probe/RESULTS.md` §7），那部分按项目惯例走真机走查。
void main() {
  final sep = Platform.pathSeparator;
  File gifFile() => File('${Directory.systemTemp.path}${sep}fake_bg.gif');
  File pngFile() => File('${Directory.systemTemp.path}${sep}fake_bg.png');

  group('isAnimated 派生（不落盘的身份判据）', () {
    test('file + .gif → true', () {
      const c = BackgroundImageConfig(
        source: BackgroundImageSource.file,
        filename: 'bgUuid-1.gif',
      );
      expect(c.isAnimated, isTrue);
    });

    test('扩展名大小写不敏感（.GIF）', () {
      const c = BackgroundImageConfig(
        source: BackgroundImageSource.file,
        filename: 'BG-2.GIF',
      );
      expect(c.isAnimated, isTrue);
    });

    test('静态格式 → false', () {
      for (final name in ['a.png', 'a.jpg', 'a.jpeg', 'a.webp', 'a.bmp']) {
        expect(
          BackgroundImageConfig(
            source: BackgroundImageSource.file,
            filename: name,
          ).isAnimated,
          isFalse,
          reason: name,
        );
      }
    });

    test('bundled 来源恒为静态（本期不引入动图内置资源）', () {
      const c = BackgroundImageConfig.bundled('assets/x/y.gif');
      expect(c.isAnimated, isFalse);
    });

    test('none / filename 缺失 → false', () {
      expect(const BackgroundImageConfig.none().isAnimated, isFalse);
      expect(
        const BackgroundImageConfig(source: BackgroundImageSource.file)
            .isAnimated,
        isFalse,
      );
    });
  });

  group('零迁移守卫：isAnimated 绝不进序列化', () {
    test('toJson 不含 isAnimated 键', () {
      const c = BackgroundImageConfig(
        source: BackgroundImageSource.file,
        filename: 'bgUuid-1.gif',
        fit: BackgroundImageFit.custom,
        scale: 1.4,
        offsetX: 0.2,
        offsetY: -0.1,
      );
      final json = c.toJson();
      expect(json.containsKey('isAnimated'), isFalse);
      expect(json.keys.toSet(), const {
        'source',
        'filename',
        'overlayOpacity',
        'blurSigma',
        'fit',
        'alignment',
        'scale',
        'offsetX',
        'offsetY',
      });
    });

    test('toJson → fromJson 往返后 == 原对象，且 isAnimated 一致', () {
      const c = BackgroundImageConfig(
        source: BackgroundImageSource.file,
        filename: 'bgUuid-2.gif',
        overlayOpacity: 0.25,
        blurSigma: 6.0,
        fit: BackgroundImageFit.custom,
        alignment: BackgroundImageAlignment.top,
        scale: 2.0,
        offsetX: 0.35,
        offsetY: -0.2,
      );
      final round = BackgroundImageConfig.fromJson(c.toJson());
      expect(round, c);
      expect(round.hashCode, c.hashCode);
      expect(round.isAnimated, isTrue);
    });

    test('老 JSON（无 v3.0 P7 字段）解析后 isAnimated 仍正确', () {
      final round = BackgroundImageConfig.fromJson({
        'source': 'file',
        'filename': 'legacy.gif',
      });
      expect(round.isAnimated, isTrue);
      expect(round.fit, BackgroundImageFit.cover);
      expect(round.scale, 1.0);
    });
  });

  group('provider 形态（全局单解码实例约定，方案 §4.2 / Phase 0 V4）', () {
    test('动图不降级 → 裸 FileImage，且与直接构造的 FileImage 相等', () {
      final f = gifFile();
      final p = AnimatedBackgroundImage.providerFor(f);
      expect(p, isA<FileImage>());
      expect(p, isNot(isA<FirstFrameFileImage>()));
      // 🔴 必须与解析自然尺寸时用的 FileImage 命中同一个 ImageCache key，
      // 否则三个渲染点各起一个解码器（同一张 GIF 被解码多份并各自播放）。
      expect(p, FileImage(f));
    });

    test('降级 → FirstFrameFileImage，且与播放态 key 不相等', () {
      final f = gifFile();
      final playing = AnimatedBackgroundImage.providerFor(f);
      final frozen =
          AnimatedBackgroundImage.providerFor(f, staticFrame: true);
      expect(frozen, isA<FirstFrameFileImage>());
      // FileImage.== 先比 runtimeType（image_provider.dart:1500），
      // 因此两种形态是两个独立缓存条目，不会互相覆盖。
      expect(frozen == playing, isFalse);
      // 而 hashCode 只由 path+scale 决定（image_provider.dart:1509），
      // 不含 runtimeType —— 两形态必然同 hash。同 hash 不等于相等：
      // ImageCache 的 HashMap 靠 == 判定，所以仍是两个独立条目。
      expect(frozen.hashCode, playing.hashCode);
    });

    test('两个 FirstFrameFileImage 同 path → 相等（互相共享解码器）', () {
      final f = gifFile();
      final a = AnimatedBackgroundImage.providerFor(f, staticFrame: true);
      final b = AnimatedBackgroundImage.providerFor(f, staticFrame: true);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('Provider 继承 FileImage 的 key 语义：path 不同即不相等', () {
      expect(
        AnimatedBackgroundImage.providerFor(gifFile()),
        isNot(AnimatedBackgroundImage.providerFor(pngFile())),
      );
      expect(
        AnimatedBackgroundImage.providerFor(gifFile(), staticFrame: true),
        isNot(
          AnimatedBackgroundImage.providerFor(pngFile(), staticFrame: true),
        ),
      );
    });

    test('scale 参与 key（与 FileImage 一致）', () {
      expect(
        FirstFrameFileImage(File('x'), scale: 1.0),
        isNot(FirstFrameFileImage(File('x'), scale: 2.0)),
      );
      expect(
        FirstFrameFileImage(File('x'), scale: 1.0),
        FirstFrameFileImage(File('x')),
      );
    });
  });

  group('AnimatedBackgroundImage 装配', () {
    // 文件刻意不存在：provider 解析会在 errorBuilder 兜底，不产生未处理异常，
    // 因此无需真解码即可断言 Widget 属性。
    Widget wrap(Widget child) => MaterialApp(home: child);

    testWidgets('动图 + 不降级：裸 FileImage / filterQuality low / gaplessPlayback',
        (tester) async {
      await tester.pumpWidget(wrap(AnimatedBackgroundImage(
        file: gifFile(),
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      )));
      final img = tester.widget<Image>(find.byType(Image));
      expect(img.image, isA<FileImage>());
      expect(img.image, isNot(isA<FirstFrameFileImage>()));
      expect(img.filterQuality, FilterQuality.low);
      expect(img.gaplessPlayback, isTrue);
    });

    testWidgets('动图 + 降级（R1 模糊 / R5 编辑器）：FirstFrameFileImage',
        (tester) async {
      await tester.pumpWidget(wrap(AnimatedBackgroundImage(
        file: gifFile(),
        degradeToStaticFrame: true,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      )));
      final img = tester.widget<Image>(find.byType(Image));
      expect(img.image, isA<FirstFrameFileImage>());
      expect(img.filterQuality, FilterQuality.low);
    });

    testWidgets('fit / alignment 透传（custom 模式用 BoxFit.fill）', (tester) async {
      await tester.pumpWidget(wrap(AnimatedBackgroundImage(
        file: gifFile(),
        fit: BoxFit.fill,
        alignment: Alignment.topCenter,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      )));
      final img = tester.widget<Image>(find.byType(Image));
      expect(img.fit, BoxFit.fill);
      expect(img.alignment, Alignment.topCenter);
    });
  });
}
