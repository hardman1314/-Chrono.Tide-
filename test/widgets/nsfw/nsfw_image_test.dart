/// `NsfwImage` 测试。
///
/// ## 这个文件存在的首要理由
///
/// 本组件的失败模式**不对称**：
/// - 多打了码 → 用户看着别扭，可恢复；
/// - 少打了码 → 未处理的裸露画面直接推到用户眼前，不可撤销。
///
/// 因此这里的核心用例不是「马赛克画得对不对」（那是
/// 原马赛克几何测试（已随打码模式删除）的职责），而是**渲染分支的判定是否正确**：
/// 该透传时必须逐字透传（R3 零影响），该接管时 [child] **必须不出现在树上**，
/// 以及每一条兜底分支（解码未就绪 / 解码失败 / 几何失效 / 约束无界）
/// 是否都落在整图模糊上，而不是漏出清晰原图。
///
/// 判定树见 `nsfw_image.dart` 顶部注释。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/nsfw/nsfw_box.dart';
import 'package:chrono_tide/services/nsfw/nsfw_detection_store.dart';
import 'package:chrono_tide/services/nsfw/nsfw_settings.dart';
import 'package:chrono_tide/widgets/nsfw/nsfw_image.dart';

const String _sig = 'censor_detect_v1.0_n/640/0.2';
const String _path = r'D:\Games\Demo\.metadata\cover.jpg';
const String _url = 'https://cdn.example.com/Cover/abc.jpg';

/// child 的标记：只要它出现在树上，就说明**原图渲染路径被走到了**。
const Key _childKey = Key('nsfw-test-child');

const NsfwBox _box = NsfwBox(
  x0: 100,
  y0: 100,
  x1: 200,
  y1: 200,
  label: 0,
  conf: 0.9,
);

NsfwDetection _det({
  int imgW = 400,
  int imgH = 400,
  List<NsfwBox> boxes = const <NsfwBox>[_box],
}) =>
    NsfwDetection(
      imgW: imgW,
      imgH: imgH,
      detectedAtMs: 1700000000000,
      boxes: boxes,
    );

/// 造一张 [w]×[h] 的实心图。
Future<ui.Image> _makeImage(int w, int h) async {
  final Uint8List rgba = Uint8List(w * h * 4);
  for (int i = 0; i < w * h; i++) {
    rgba[i * 4] = 200;
    rgba[i * 4 + 1] = 100;
    rgba[i * 4 + 2] = 50;
    rgba[i * 4 + 3] = 255;
  }
  final ui.ImmutableBuffer buffer =
      await ui.ImmutableBuffer.fromUint8List(rgba);
  final ui.ImageDescriptor desc = ui.ImageDescriptor.raw(
    buffer,
    width: w,
    height: h,
    pixelFormat: ui.PixelFormat.rgba8888,
  );
  final ui.Codec codec = await desc.instantiateCodec();
  final ui.FrameInfo frame = await codec.getNextFrame();
  return frame.image;
}

/// 同步就绪的假 provider，避免单测依赖真实磁盘文件与网络。
class _ReadyProvider extends ImageProvider<_ReadyProvider> {
  _ReadyProvider(this.image, this.tag);

  final ui.Image image;

  /// 参与相等性：换图时 ImageStream 的 key 必须变化，否则不会重新解码。
  final String tag;

  @override
  Future<_ReadyProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_ReadyProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _ReadyProvider key,
    ImageDecoderCallback decode,
  ) =>
      OneFrameImageStreamCompleter(
        SynchronousFuture<ImageInfo>(ImageInfo(image: image.clone())),
      );

  @override
  bool operator ==(Object other) =>
      other is _ReadyProvider && other.tag == tag;

  @override
  int get hashCode => tag.hashCode;
}

/// 永不完成的 provider：模拟「自有解码还没就绪」的那一帧。
class _PendingProvider extends ImageProvider<_PendingProvider> {
  @override
  Future<_PendingProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_PendingProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _PendingProvider key,
    ImageDecoderCallback decode,
  ) =>
      OneFrameImageStreamCompleter(Completer<ImageInfo>().future);

  @override
  bool operator ==(Object other) => other is _PendingProvider;

  @override
  int get hashCode => runtimeType.hashCode;
}

/// 立即报错的 provider：模拟解码失败。
class _FailingProvider extends ImageProvider<_FailingProvider> {
  @override
  Future<_FailingProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_FailingProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _FailingProvider key,
    ImageDecoderCallback decode,
  ) =>
      OneFrameImageStreamCompleter(
        Future<ImageInfo>.error(StateError('boom')),
      );

  @override
  bool operator ==(Object other) => other is _FailingProvider;

  @override
  int get hashCode => runtimeType.hashCode;
}

// ===========================================================================

Finder get _child => find.byKey(_childKey);

Finder get _blur => find.byType(ImageFiltered);

/// 左上角 NSFW 提示徽标（v2.1.2：敏感态替代旧黑底占位）。
Finder get _nsfwBadge => find.byKey(const Key('nsfw_nsfw_badge'));

/// 右下角揭示角标（v2.5：唯一的揭示入口，由纯指示变为按钮）。
Finder get _revealBadge => find.byKey(const Key('nsfw_reveal_badge'));

/// 包住 [_revealBadge] 的 [AnimatedOpacity] 当前不透明度
/// （工作模式角标按悬浮显隐，断言它是否「浮出」）。
double _badgeOpacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(find.ancestor(
      of: _revealBadge,
      matching: find.byType(AnimatedOpacity),
    ))
    .opacity;

/// 把鼠标移入 [target]（桌面端悬浮语义；`tester.tap` 用的是触摸指针不会触发）。
/// 必须在测试里 `addTearDown(gesture.removePointer)`，本函数已代为注册。
Future<void> _hoverOver(WidgetTester tester, Finder target) async {
  final TestGesture gesture =
      await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await tester.pump();
  await gesture.moveTo(tester.getCenter(target));
  await tester.pump();
}

Widget _child0() => Container(key: _childKey, color: const Color(0xFF00FF00));

/// 把被测组件包进定尺槽位。[slot] 为 null 时**不给宽高约束**（模拟无界场景）。
Widget _host(NsfwImage image, {Size? slot = const Size(200, 200)}) =>
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: slot == null
              ? UnconstrainedBox(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[image],
                  ),
                )
              : SizedBox(width: slot.width, height: slot.height, child: image),
        ),
      ),
    );

void main() {
  late ui.Image image400;
  late ui.Image image600x900;
  late Directory tmpRoot;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    image400 = await _makeImage(400, 400);
    // 竖版封面内在尺寸：模拟详情弹窗真实封面（600×900），用于模糊雾边界回归
    image600x900 = await _makeImage(600, 900);
  });

  setUp(() async {
    // store.put() 会触发去抖落盘，别写到项目目录里去
    tmpRoot = await Directory.systemTemp.createTemp('ct_nsfw_image_');
    PathHelper.exeDirOverride = tmpRoot.path;
    NsfwSettings.resetForTest();
    NsfwDetectionStore.resetForTest();
    NsfwImage.debugProviderFactory =
        (NsfwImage w) => _ReadyProvider(image400, 'ready');
    // 拦截按需检测入队：v2.1.1 起纯净模式内容图未判定会自动入队，
    // 真实入队会走推理 isolate，测试环境不可控。需要断言入队行为的
    // 用例自行覆盖此 override。
    NsfwImage.debugEnqueueOverride =
        (String path, {bool highPriority = false}) async => null;
  });

  tearDown(() async {
    NsfwImage.debugProviderFactory = null;
    NsfwImage.debugEnqueueOverride = null;
    NsfwSettings.resetForTest();
    NsfwDetectionStore.resetForTest();
    PathHelper.exeDirOverride = null;
    try {
      await tmpRoot.delete(recursive: true);
    } catch (_) {}
  });

  void enable({
    bool allowReveal = true,
    double expand = 0.0,
    // v2.1.15：mask（18+ 打码）模式已删除，默认统一为 clean。
    // v2.5：揭示入口改为右下角角标，封面类（cover）与内容图（image）
    // 敏感后都能揭示；两者的角标位置/伴随徽标不同，用例按需显式传
    // contentKind: NsfwContentKind.cover。
    NsfwDisplayMode mode = NsfwDisplayMode.clean,
  }) {
    NsfwSettings.instance.seedForTest(
      enabled: true,
      allowReveal: allowReveal,
      boxExpandRatio: expand,
      mode: mode,
    );
  }

  void seed(Map<String, NsfwDetection> items) {
    NsfwDetectionStore.instance.seedForTest(_sig, items);
  }

  // =========================================================================
  group('透传分支（R3：健康图零影响）', () {
    testWidgets('总开关关闭 → 原样返回 child，不接管渲染', (WidgetTester tester) async {
      NsfwSettings.instance.seedForTest(enabled: false);
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, child: _child0()),
      ));

      expect(_child, findsOneWidget);
      expect(_blur, findsNothing);
    });

    testWidgets('未判定（store 无记录）→ 模糊预览（v2.1.4 统一 fail-closed）',
        (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{});

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, child: _child0()),
      ));

      expect(_blur, findsOneWidget, reason: '未判定一律模糊预览，判定健康后清晰');
      expect(_child, findsOneWidget);
    });

    testWidgets('已判定为干净（空 box 列表）→ 原样返回 child',
        (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path):
            _det(boxes: const <NsfwBox>[]),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, child: _child0()),
      ));

      expect(_child, findsOneWidget);
    });

    testWidgets('manuallyBlurred（§4.5 手动标记优先）→ 透传，不叠加局部马赛克',
        (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, manuallyBlurred: true, child: _child0()),
      ));

      expect(_child, findsOneWidget);
      // 不叠加：本组件自己不加模糊，整图模糊由调用方原有代码负责
      expect(_blur, findsNothing);
    });
  });

  // =========================================================================
  group('接管分支：检出 bbox', () {
    testWidgets('走整图模糊，child 在树上但被模糊层包裹（无清晰闪出窗口）',
        (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, child: _child0()),
      ));

      expect(_blur, findsOneWidget);
      expect(_child, findsOneWidget);
      expect(find.ancestor(of: _child, matching: _blur), findsOneWidget,
          reason: 'child 必须在模糊层内部');
    });

    // v2.2：局部马赛克退役，「painter 收到外扩 box」「boxExpandRatio=0 不
    // 外扩」两个 painter 参数用例随能力一并移除——渲染只认「敏感即整图模糊」，
    // box 仅作敏感判据（isNotEmpty），不再参与绘制。

    testWidgets('检测结果后到（下载后才判定完）→ 自动从透传切到打码',
        (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{});

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, contentKind: NsfwContentKind.cover, child: _child0()),
      ));
      expect(_child, findsOneWidget, reason: 'child 在树上（模糊预览包裹）');
      expect(_blur, findsOneWidget, reason: '未判定先模糊预览');

      NsfwDetectionStore.instance
          .put(NsfwDetectionStore.keyForFile(_path), _det());
      // store 对 UI 通知有 200ms 去抖（§6.2 节流）
      await tester.pump(const Duration(milliseconds: 250));

      expect(_blur, findsOneWidget, reason: '判定后立即接管为整图模糊');
      expect(_nsfwBadge, findsNothing, reason: '封面类打码态用图标徽标，非 NSFW 徽标');
      expect(_child, findsOneWidget);

      // 清掉 store 的 3s 落盘去抖定时器，避免测试结束时 pending timer 报错。
      // flush 内部是真实文件 I/O，必须用 runAsync 逃出 widget 测试的假时钟区，
      // 否则 Future 永不完成（连 Future.timeout 的 Timer 也不会触发）。
      await tester.runAsync(NsfwDetectionStore.instance.flush);
    });
  });

  // =========================================================================
  group('兜底分支：一律整图模糊，绝不漏出清晰原图', () {
    testWidgets('自有解码未就绪 → 整图模糊（而非先画原图）',
        (WidgetTester tester) async {
      enable();
      NsfwImage.debugProviderFactory = (NsfwImage w) => _PendingProvider();
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, child: _child0()),
      ));

      expect(_blur, findsOneWidget);
      // child 在树上，但被 ImageFiltered 包着（模糊后的原图，安全）
      expect(_child, findsOneWidget);
      expect(
        find.ancestor(of: _child, matching: _blur),
        findsOneWidget,
        reason: 'child 必须在模糊层内部',
      );
    });

    testWidgets('解码失败 → 整图模糊', (WidgetTester tester) async {
      enable();
      NsfwImage.debugProviderFactory = (NsfwImage w) => _FailingProvider();
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, child: _child0()),
      ));
      await tester.pump();

      expect(find.ancestor(of: _child, matching: _blur), findsOneWidget);
    });

    testWidgets('几何失效（用户换了同名不同比例的封面）→ 整图模糊',
        (WidgetTester tester) async {
      enable();
      // 检测时是 400×400（1:1），现在解码出来的图是 400×400 但检测记录写的是
      // 800×200（4:1）→ 宽高比偏离，旧 bbox 会遮错地方
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(imgW: 800, imgH: 200),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, child: _child0()),
      ));

      expect(find.ancestor(of: _child, matching: _blur), findsOneWidget);
    });

    testWidgets('约束无界且未传 width/height → 整图模糊（不抛异常）',
        (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, child: _child0()),
        slot: null,
      ));

      expect(tester.takeException(), isNull);
      expect(find.ancestor(of: _child, matching: _blur), findsOneWidget);
    });

    testWidgets('约束无界但显式传了 width/height → 仍整图模糊',
        (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, width: 120, height: 180, child: _child0()),
        slot: null,
      ));

      expect(tester.takeException(), isNull);
      expect(_blur, findsOneWidget);
      expect(_child, findsOneWidget);
    });
  });

  // =========================================================================
  group('§5.4 揭示交互（v2.5：右下角角标是唯一入口）', () {
    testWidgets('点角标 → 揭示原图；再点 → 恢复打码', (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path,
            contentKind: NsfwContentKind.cover,
            enableReveal: true,
            child: _child0()),
      ));
      expect(_blur, findsOneWidget);
      expect(_child, findsOneWidget, reason: 'child 在模糊层内');
      expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);

      await tester.tap(_revealBadge);
      await tester.pump();
      expect(_child, findsOneWidget, reason: '揭示后应显示原图');
      expect(_blur, findsNothing, reason: '揭示是显示原图，不是模糊');
      expect(find.byIcon(Icons.visibility_outlined), findsOneWidget,
          reason: '角标换成亮眼，提示可再点恢复');

      await tester.tap(_revealBadge);
      await tester.pump();
      expect(_blur, findsOneWidget, reason: '再点应恢复模糊');
      expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
    });

    testWidgets('整图点击不再揭示（v2.5 移除整图手势，不再抢卡片点击）',
        (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path,
            contentKind: NsfwContentKind.cover,
            enableReveal: true,
            child: _child0()),
      ));

      await tester.tap(_blur);
      await tester.pump();
      expect(_blur, findsOneWidget,
          reason: '点图不揭示；揭示入口只剩右下角角标，卡片点击语义得以保留');
    });

    testWidgets('enableReveal=false（未开启的接入点）→ 角标仍作指示但不可点',
        (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path,
            contentKind: NsfwContentKind.cover, child: _child0()),
      ));

      expect(_revealBadge, findsOneWidget, reason: '角标仍是遮蔽指示');
      await tester.tap(_revealBadge, warnIfMissed: false);
      await tester.pump();
      expect(_blur, findsOneWidget, reason: '未开启揭示 → 保持模糊');
      expect(_child, findsOneWidget);
    });

    testWidgets('用户设置 allowReveal=false → 即使接入点开了也不揭示',
        (WidgetTester tester) async {
      enable(allowReveal: false);
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path,
            contentKind: NsfwContentKind.cover,
            enableReveal: true,
            child: _child0()),
      ));

      expect(find.byIcon(Icons.visibility_outlined), findsNothing,
          reason: '总闸关闭 → 角标只做指示，不出现亮眼态');
      await tester.tap(_revealBadge, warnIfMissed: false);
      await tester.pump();
      expect(_blur, findsOneWidget, reason: '揭示被拒，保持模糊');
      expect(_child, findsOneWidget);
    });

    testWidgets('揭示中途关闭总闸 → 立即回到遮蔽态（不留已揭示窗口）',
        (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path,
            contentKind: NsfwContentKind.cover,
            enableReveal: true,
            child: _child0()),
      ));
      await tester.tap(_revealBadge);
      await tester.pump();
      expect(_blur, findsNothing, reason: '已揭示');

      NsfwSettings.instance.seedForTest(enabled: true, allowReveal: false);
      await tester.pump();

      expect(_blur, findsOneWidget, reason: '关闸必须立刻恢复遮蔽');
      expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
    });
  });

  // =========================================================================
  group('§5.5 视觉提示', () {
    testWidgets('打码态显示 visibility_off 图标', (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, contentKind: NsfwContentKind.cover, child: _child0()),
      ));

      expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
    });

    testWidgets('揭示态换成 visibility 图标（提示可再点恢复）',
        (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, contentKind: NsfwContentKind.cover, enableReveal: true, child: _child0()),
      ));
      await tester.tap(_revealBadge);
      await tester.pump();

      expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
      expect(find.byIcon(Icons.visibility_off_outlined), findsNothing);
    });

    testWidgets('小缩略图（40×55）不显示图标，避免盖住整张图',
        (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, child: _child0()),
        slot: const Size(40, 55),
      ));

      expect(_blur, findsOneWidget, reason: '仍要模糊（v2.2 一律整图）');
      expect(find.byIcon(Icons.visibility_off_outlined), findsNothing);
    });

    testWidgets('showBadge=false → 不显示图标', (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, showBadge: false, child: _child0()),
      ));

      expect(find.byIcon(Icons.visibility_off_outlined), findsNothing);
    });
  });

  // =========================================================================
  group('§4.4 键规则（v1 P0-3 回归守卫）', () {
    test('file 入口用路径键', () {
      const NsfwImage w = NsfwImage.file(_path, child: SizedBox());
      expect(w.lookupKeys, <String>[NsfwDetectionStore.keyForFile(_path)]);
    });

    test('network 入口先试 URL 键，再试 localPath 路径键', () {
      const NsfwImage w = NsfwImage.network(
        _url,
        localPath: _path,
        child: SizedBox(),
      );
      expect(w.lookupKeys, <String>[
        NsfwDetectionStore.keyForUrl(_url),
        NsfwDetectionStore.keyForFile(_path),
      ]);
    });

    test('URL 键不做小写化（URL path 段大小写敏感）', () {
      const NsfwImage w = NsfwImage.network(_url, child: SizedBox());
      expect(w.lookupKeys.single, contains('Cover'));
    });

    test('空路径不产生空 key', () {
      const NsfwImage w = NsfwImage.file('', child: SizedBox());
      expect(w.lookupKeys, isEmpty);
    });

    testWidgets('network：URL 键命中即打码', (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForUrl(_url): _det(),
      });

      await tester.pumpWidget(_host(
        NsfwImage.network(_url, child: _child0()),
      ));

      expect(_blur, findsOneWidget);
      expect(_child, findsOneWidget);
    });

    testWidgets('network：URL 键未命中但 localPath 键命中 → 仍打码',
        (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(),
      });

      await tester.pumpWidget(_host(
        NsfwImage.network(_url, localPath: _path, child: _child0()),
      ));

      expect(_blur, findsOneWidget);
      expect(_child, findsOneWidget);
    });

    testWidgets('network：两个键都未命中 → 放行（未判定不误伤）',
        (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{});

      await tester.pumpWidget(_host(
        NsfwImage.network(_url, localPath: _path, child: _child0()),
      ));

      expect(_child, findsOneWidget);
    });
  });

  // =========================================================================
  group('设置变更响应', () {
    testWidgets('运行时关闭总开关 → 立即回到原图', (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, child: _child0()),
      ));
      expect(_blur, findsOneWidget);

      NsfwSettings.instance.seedForTest(enabled: false);
      await tester.pump();

      expect(_child, findsOneWidget);
      expect(_blur, findsNothing);
    });

    // v2.2：「运行时调大外扩比例 → box 随之变化」用例随局部马赛克退役
    // 移除——boxExpandRatio 只影响敏感判据（boxes 非空），不再参与绘制。

    testWidgets('切换图片路径 → 揭示状态复位（不跨图残留）',
        (WidgetTester tester) async {
      enable();
      const String other = r'D:\Games\Other\.metadata\cover.jpg';
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(),
        NsfwDetectionStore.keyForFile(other): _det(),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, enableReveal: true, child: _child0()),
      ));
      await tester.tap(_revealBadge);
      await tester.pump();
      expect(_child, findsOneWidget, reason: '已揭示');

      await tester.pumpWidget(_host(
        NsfwImage.file(other, enableReveal: true, child: _child0()),
      ));
      await tester.pump();

      expect(_blur, findsOneWidget, reason: '换图后必须回到模糊态');
      expect(_child, findsOneWidget);
    });
  });

  // =========================================================================
  group('v2.1 纯净模式：内容图（截图类，默认 contentKind）', () {
    testWidgets('未判定 → 模糊预览（细节不可辨但不黑屏，仍 fail-closed）',
        (WidgetTester tester) async {
      enable(mode: NsfwDisplayMode.clean);
      seed(<String, NsfwDetection>{});

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, child: _child0()),
      ));

      expect(_blur, findsOneWidget, reason: '未判定走高斯模糊预览（v2.1.14 起 sigma 14）');
      expect(_child, findsOneWidget, reason: 'child 在树上但被模糊包裹');
      expect(_nsfwBadge, findsNothing);
      expect(find.byIcon(Icons.hourglass_empty), findsOneWidget,
          reason: '200×200 槽位带「检测中」角标');
    });

    testWidgets('判定敏感 → 保持模糊 + 左上角 NSFW 徽标（弃用黑底占位）',
        (WidgetTester tester) async {
      enable(mode: NsfwDisplayMode.clean);
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, child: _child0()),
      ));

      expect(_blur, findsOneWidget, reason: '敏感态与检测中同为模糊观感');
      expect(_child, findsOneWidget, reason: 'child 在树上但被模糊包裹');
      expect(_nsfwBadge, findsOneWidget, reason: '右上角 NSFW 提示徽标');
      expect(find.text('NSFW'), findsOneWidget);
    });

    testWidgets('判定健康 → 正常显示 child', (WidgetTester tester) async {
      enable(mode: NsfwDisplayMode.clean);
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(boxes: const <NsfwBox>[]),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, child: _child0()),
      ));

      expect(_child, findsOneWidget);
      expect(_nsfwBadge, findsNothing);
    });

    testWidgets('检测中 → 判定敏感后自动切模糊+NSFW 角标（无黑屏跳变）',
        (WidgetTester tester) async {
      enable(mode: NsfwDisplayMode.clean);
      seed(<String, NsfwDetection>{});

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, child: _child0()),
      ));
      expect(_blur, findsOneWidget, reason: '检测中是模糊预览');
      expect(_nsfwBadge, findsNothing);

      NsfwDetectionStore.instance
          .put(NsfwDetectionStore.keyForFile(_path), _det());
      await tester.pump(const Duration(milliseconds: 250));

      expect(_blur, findsOneWidget, reason: '敏感 → 仍是模糊（观感连续）');
      expect(_nsfwBadge, findsOneWidget, reason: '叠加 NSFW 角标');
      expect(find.byIcon(Icons.hourglass_empty), findsNothing,
          reason: '检测中角标消失');
      await tester.runAsync(NsfwDetectionStore.instance.flush);
    });

    testWidgets('v2.5 内容图敏感 → 右下角角标可揭示（左上角 NSFW 徽标保留）',
        (WidgetTester tester) async {
      enable(mode: NsfwDisplayMode.clean);
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, enableReveal: true, child: _child0()),
      ));

      expect(_blur, findsOneWidget);
      expect(_nsfwBadge, findsOneWidget, reason: '左上角 NSFW 徽标仍在');
      expect(_revealBadge, findsOneWidget, reason: '右下角新增揭示角标');
      expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);

      // 点 NSFW 徽标不该有任何反应（它是纯说明，不是按钮）
      await tester.tap(_nsfwBadge, warnIfMissed: false);
      await tester.pump();
      expect(_blur, findsOneWidget, reason: 'NSFW 徽标不是揭示入口');

      await tester.tap(_revealBadge);
      await tester.pump();
      expect(_blur, findsNothing, reason: '点角标 → 显示原图');
      expect(_child, findsOneWidget);
      expect(_nsfwBadge, findsOneWidget, reason: 'NSFW 标记不随揭示消失');

      await tester.tap(_revealBadge);
      await tester.pump();
      expect(_blur, findsOneWidget, reason: '再点恢复遮蔽');
    });

    testWidgets('v2.5 内容图「检测中」模糊预览不可揭示（fail-closed 窗口）',
        (WidgetTester tester) async {
      enable(mode: NsfwDisplayMode.clean);
      seed(<String, NsfwDetection>{});

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, enableReveal: true, child: _child0()),
      ));

      expect(_blur, findsOneWidget);
      expect(find.byIcon(Icons.hourglass_empty), findsOneWidget,
          reason: '检测中只有沙漏角标');
      expect(_revealBadge, findsNothing,
          reason: '检测窗口不提供揭示入口——放行等于未判定就裸露');
      expect(find.byIcon(Icons.visibility_off_outlined), findsNothing);
    });

    testWidgets('未判定 → 自动入队按需检测（本地文件，判定后不再入队）',
        (WidgetTester tester) async {
      enable(mode: NsfwDisplayMode.clean);
      seed(<String, NsfwDetection>{});
      final List<String> enqueued = <String>[];
      NsfwImage.debugEnqueueOverride =
          (String path, {bool highPriority = false}) async {
        enqueued.add(path);
        return null;
      };

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, child: _child0()),
      ));
      await tester.pump();

      expect(enqueued, <String>[_path],
          reason: '纯净模式内容图未判定必须自动入队，否则永远卡在检测中');

      // 判定回写（健康）后不再重复入队
      NsfwDetectionStore.instance.put(
        NsfwDetectionStore.keyForFile(_path),
        _det(boxes: const <NsfwBox>[]),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(enqueued, hasLength(1), reason: '已有判定不再入队');
      await tester.runAsync(NsfwDetectionStore.instance.flush);
    });

    testWidgets('封面类未判定自动入队（低优先级，判定后打码生效）',
        (WidgetTester tester) async {
      enable(mode: NsfwDisplayMode.clean);
      seed(<String, NsfwDetection>{});
      final List<String> enqueued = <String>[];
      final List<bool> priorities = <bool>[];
      NsfwImage.debugEnqueueOverride =
          (String path, {bool highPriority = false}) async {
        enqueued.add(path);
        priorities.add(highPriority);
        return null;
      };

      await tester.pumpWidget(_host(
        NsfwImage.file(
          _path,
          contentKind: NsfwContentKind.cover,
          child: _child0(),
        ),
      ));
      await tester.pump();

      expect(enqueued, <String>[_path],
          reason: 'cover 未判定必须入队，否则库页封面永远不被检测（v2.1.3）');
      expect(priorities, <bool>[false],
          reason: '封面低优先级，网格滚动批量入队不抢占截图判定');
    });

    testWidgets('纯净模式未判定同样自动入队（打码语义依赖判定）',
        (WidgetTester tester) async {
      enable(mode: NsfwDisplayMode.clean);
      seed(<String, NsfwDetection>{});
      final List<String> enqueued = <String>[];
      final List<bool> priorities = <bool>[];
      NsfwImage.debugEnqueueOverride =
          (String path, {bool highPriority = false}) async {
        enqueued.add(path);
        priorities.add(highPriority);
        return null;
      };

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, child: _child0()),
      ));
      await tester.pump();

      expect(enqueued, <String>[_path],
          reason: 'mask 模式内容图未判定直显，必须入队让打码尽快生效');
      expect(priorities, <bool>[true], reason: '内容图高优先级');
    });
  });

  // =========================================================================
  group('v2.1 纯净模式：封面类（contentKind: cover）', () {
    testWidgets('检出 bbox → 整图模糊（v2.2 一律整图，与截图观感一致）',
        (WidgetTester tester) async {
      enable(mode: NsfwDisplayMode.clean);
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(
          _path,
          contentKind: NsfwContentKind.cover,
          child: _child0(),
        ),
      ));

      expect(_blur, findsOneWidget, reason: '封面敏感即整图模糊');
      expect(_child, findsOneWidget);
    });

    testWidgets('未判定 → 模糊预览 + 检测中角标（v2.1.4 统一 fail-closed，'
        '消除封面排队期裸露窗口）', (WidgetTester tester) async {
      enable(mode: NsfwDisplayMode.clean);
      seed(<String, NsfwDetection>{});

      await tester.pumpWidget(_host(
        NsfwImage.file(
          _path,
          contentKind: NsfwContentKind.cover,
          child: _child0(),
        ),
      ));

      expect(_blur, findsOneWidget, reason: '未判定封面模糊展示，不裸露原图');
      expect(_child, findsOneWidget, reason: 'child 在树上但被模糊包裹');
      expect(_nsfwBadge, findsNothing, reason: '检测中只有沙漏角标，无 NSFW 徽标');
    });
  });

  // =========================================================================
  group('v2.2 敏感一律整图模糊（无面积分档）', () {
    const NsfwBox nipple = NsfwBox(
        x0: 100, y0: 100, x1: 200, y1: 200, label: 0, conf: 0.9);

    testWidgets('检出 ≥2 种类别（乳头+下体）→ 整图模糊而非局部马赛克',
        (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(boxes: <NsfwBox>[
          nipple,
          const NsfwBox(
              x0: 300, y0: 300, x1: 350, y1: 350, label: 1, conf: 0.8),
        ]),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, child: _child0()),
      ));

      expect(_blur, findsOneWidget);
      expect(find.ancestor(of: _child, matching: _blur), findsOneWidget);
    });

    testWidgets('单类别小面积（6.25%）→ 同样整图模糊（无面积豁免）',
        (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(boxes: const <NsfwBox>[nipple]),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, child: _child0()),
      ));

      expect(_blur, findsOneWidget);
      expect(_child, findsOneWidget);
    });

    testWidgets('单类别大面积（≥30%，局部特写）→ 整图模糊',
        (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(boxes: const <NsfwBox>[
          NsfwBox(x0: 0, y0: 0, x1: 400, y1: 200, label: 2, conf: 0.9),
        ]),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, child: _child0()),
      ));

      expect(_blur, findsOneWidget);
    });

    testWidgets('v2.1.2 单框 ≥15%（18%，大部位特写）→ 整图模糊（封面自适应）',
        (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(boxes: const <NsfwBox>[
          // 240×120 = 28800 / 160000 = 18% ≥ 15%，单类别
          NsfwBox(x0: 50, y0: 50, x1: 290, y1: 170, label: 0, conf: 0.9),
        ]),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(
          _path,
          contentKind: NsfwContentKind.cover,
          child: _child0(),
        ),
      ));

      expect(_blur, findsOneWidget, reason: '整图模糊，与截图模糊预览观感一致');
    });

    testWidgets('v2.2 单框 <15%（14%）→ 同样整图模糊（无阈值可漏）',
        (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(boxes: const <NsfwBox>[
          // 100×224 = 22400 / 160000 = 14% < 15%，单类别，总面积亦 <30%
          NsfwBox(x0: 100, y0: 100, x1: 200, y1: 324, label: 0, conf: 0.9),
        ]),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(
          _path,
          contentKind: NsfwContentKind.cover,
          child: _child0(),
        ),
      ));

      expect(_blur, findsOneWidget, reason: '敏感即整图模糊，判定口径唯一');
      expect(_child, findsOneWidget);
    });
  });

  // =========================================================================
  group('v2.5 工作模式：占位图 + 悬浮角标揭示', () {
    testWidgets('默认不构建 child、不模糊；角标仅在悬浮时才浮出',
        (WidgetTester tester) async {
      enable(mode: NsfwDisplayMode.work);

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, enableReveal: true, child: _child0()),
      ));
      await tester.pump(const Duration(milliseconds: 200));

      expect(_child, findsNothing, reason: '工作模式不构建 child（不解码原图）');
      expect(_blur, findsNothing, reason: '占位图不叠加模糊');
      expect(_revealBadge, findsOneWidget);
      expect(_badgeOpacity(tester), 0.0, reason: '未悬浮 → 角标不透明度 0');

      await _hoverOver(tester, find.byType(NsfwImage));
      expect(_badgeOpacity(tester), 1.0, reason: '悬浮 → 角标浮出');
    });

    testWidgets('悬浮 → 点角标揭示真实图片 → 再点恢复占位图',
        (WidgetTester tester) async {
      enable(mode: NsfwDisplayMode.work);

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, enableReveal: true, child: _child0()),
      ));
      await tester.pump(const Duration(milliseconds: 200));
      await _hoverOver(tester, find.byType(NsfwImage));

      await tester.tap(_revealBadge);
      await tester.pump(const Duration(milliseconds: 200));
      expect(_child, findsOneWidget, reason: '揭示后显示真实图片');
      expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
      expect(_badgeOpacity(tester), 1.0,
          reason: '已揭示时角标常驻，鼠标移开也点得回遮蔽');

      await tester.tap(_revealBadge);
      await tester.pump(const Duration(milliseconds: 200));
      expect(_child, findsNothing, reason: '再点恢复占位图');
      expect(find.byIcon(Icons.visibility_off_outlined), findsOneWidget);
    });

    testWidgets('enableReveal=false → 不挂悬浮监听、无角标（保持零额外开销）',
        (WidgetTester tester) async {
      enable(mode: NsfwDisplayMode.work);

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, child: _child0()),
      ));
      await tester.pump(const Duration(milliseconds: 200));

      expect(_revealBadge, findsNothing);
      expect(
        find.descendant(
          of: find.byType(NsfwImage),
          matching: find.byType(MouseRegion),
        ),
        findsNothing,
        reason: '不可揭示时连 MouseRegion 都不挂，工作模式开销与未开启一致',
      );
      expect(_child, findsNothing);
    });

    testWidgets('用户总闸 allowReveal=false → 工作模式同样不可揭示',
        (WidgetTester tester) async {
      enable(mode: NsfwDisplayMode.work, allowReveal: false);

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, enableReveal: true, child: _child0()),
      ));
      await tester.pump(const Duration(milliseconds: 200));
      await _hoverOver(tester, find.byType(NsfwImage));

      expect(_revealBadge, findsNothing);
      expect(_child, findsNothing, reason: '总闸关闭 → 悬浮也不给入口');
    });

    testWidgets('工作模式全程不入队推理（含悬浮与揭示）',
        (WidgetTester tester) async {
      enable(mode: NsfwDisplayMode.work);
      final List<String> enqueued = <String>[];
      NsfwImage.debugEnqueueOverride =
          (String path, {bool highPriority = false}) async {
        enqueued.add(path);
        return null;
      };

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, enableReveal: true, child: _child0()),
      ));
      await tester.pump(const Duration(milliseconds: 200));
      await _hoverOver(tester, find.byType(NsfwImage));
      await tester.tap(_revealBadge);
      await tester.pump(const Duration(milliseconds: 200));

      expect(enqueued, isEmpty,
          reason: '工作模式是「最轻量」：不判定、不入队，揭示也不触发检测');
    });
  });

  // =========================================================================
  group('v2.1 设置默认值', () {
    test('总开关默认开启', () {
      expect(NsfwSettings.instance.enabled, isTrue);
    });

    test('显示模式默认纯净模式', () {
      expect(NsfwSettings.instance.mode, NsfwDisplayMode.clean);
    });

    test('推理档位固定精确 384（v2.4 分类器方形输入）', () {
      expect(NsfwSettings.instance.inferSize, NsfwInferSize.accurate);
    });
  });

  // =========================================================================
  group('v2.1.2 本地按需检测失败重试（修复模糊预览永久残留）', () {
    // 用 override 返回 null 模拟「服务端无声失败」（首启未就绪/首推超时/
    // worker 异常）——修复前组件一次性入队后永不重试，该图永久卡在模糊预览。
    testWidgets('检测失败 → 安排退避重试并推进', (WidgetTester tester) async {
      enable(mode: NsfwDisplayMode.clean);
      seed(<String, NsfwDetection>{});
      final List<String> enqueued = <String>[];
      NsfwImage.debugEnqueueOverride =
          (String path, {bool highPriority = false}) async {
        enqueued.add(path);
        return null; // 模拟检测失败
      };

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, child: _child0()),
      ));
      await tester.pump();

      expect(enqueued, hasLength(1), reason: '首次入队');
      final dynamic state = tester.state(find.byType(NsfwImage));
      expect(state.localRetriesForTest, 1, reason: '失败后安排第一次重试');

      await tester.pump(const Duration(seconds: 4)); // 3s 重试 Timer 触发
      await tester.pump();

      expect(enqueued, hasLength(2), reason: '重试重新入队（force 绕过失败表）');
      expect(state.localRetriesForTest, 2, reason: '重试仍失败 → 继续退避');
      await tester.runAsync(NsfwDetectionStore.instance.flush);
    });

    testWidgets('重试上限 3 次，不再增长', (WidgetTester tester) async {
      enable(mode: NsfwDisplayMode.clean);
      seed(<String, NsfwDetection>{});
      int calls = 0;
      NsfwImage.debugEnqueueOverride =
          (String path, {bool highPriority = false}) async {
        calls++;
        return null;
      };

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, child: _child0()),
      ));
      // 推进 3s/6s/9s 三轮重试 Timer 及各自失败链
      for (int i = 1; i <= 3; i++) {
        await tester.pump();
        await tester.pump(Duration(seconds: 3 * i + 1));
        await tester.pump();
      }

      final dynamic state = tester.state(find.byType(NsfwImage));
      expect(state.localRetriesForTest, 3, reason: '最多重试 3 次');
      expect(calls, 4, reason: '首次入队 + 3 次重试（3s/6s/9s），之后封顶');

      await tester.pump(const Duration(seconds: 30));
      expect(state.localRetriesForTest, 3, reason: '达上限后不再重试');
      expect(calls, 4);
      await tester.runAsync(NsfwDetectionStore.instance.flush);
    });

    testWidgets('重试耗尽仍无结果 → 放行原图（服务不可用兜底，不永久模糊）',
        (WidgetTester tester) async {
      enable(mode: NsfwDisplayMode.clean);
      seed(<String, NsfwDetection>{});
      NsfwImage.debugEnqueueOverride =
          (String path, {bool highPriority = false}) async => null;

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, child: _child0()),
      ));
      expect(_blur, findsOneWidget, reason: '初始为模糊预览');

      // 推进 3s/6s/9s 三轮重试 + 各自失败链 + 封顶后的放弃判定
      for (int i = 1; i <= 3; i++) {
        await tester.pump();
        await tester.pump(Duration(seconds: 3 * i + 1));
        await tester.pump();
      }
      await tester.pump(); // 触发第 4 次失败的 gaveUp setState
      await tester.pump(const Duration(milliseconds: 50));

      expect(_blur, findsNothing, reason: '放弃后不再模糊');
      expect(_child, findsOneWidget, reason: '服务整体不可用时放行原图直显');
      expect(_nsfwBadge, findsNothing);
      await tester.runAsync(NsfwDetectionStore.instance.flush);
    });
  });

  // =========================================================================
  group('v2.1.4 通知风暴差异化（性能）', () {
    testWidgets('无关图判定回写不触发本组件重建', (WidgetTester tester) async {
      enable(mode: NsfwDisplayMode.clean);
      seed(<String, NsfwDetection>{});
      NsfwImage.debugEnqueueOverride =
          (String path, {bool highPriority = false}) async => null;

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, child: _child0()),
      ));
      await tester.pump();

      final dynamic state = tester.state(find.byType(NsfwImage));

      // 无关 key 回写：广播会到达，但差异化检查应直接跳过
      NsfwDetectionStore.instance.put(
        NsfwDetectionStore.keyForFile(r'C:\other\image.jpg'),
        _det(boxes: const <NsfwBox>[]),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(state.externalRebuildsForTest, 0,
          reason: '无关图的判定回写不应触发本组件 setState（通知风暴优化核心）');

      // 本图回写：必须重建
      NsfwDetectionStore.instance.put(
        NsfwDetectionStore.keyForFile(_path),
        _det(boxes: const <NsfwBox>[]),
      );
      await tester.pump(const Duration(milliseconds: 250));
      expect(state.externalRebuildsForTest, 1, reason: '本图判定回写触发重建');
      await tester.runAsync(NsfwDetectionStore.instance.flush);
    });
  });

  // =========================================================================
  group('模糊雾边界（v2.1.10 回归：详情弹窗封面模糊溢出按钮区）', () {
    // 机制：`ImageFiltered` 合成层的绘制边界是 child 边界外扩约 3×sigma
    // （sigma 20 → 四周 ~60px）。`RenderStack.paint` 只在发生**布局溢出**
    // （_hasVisualOverflow）时才裁剪，模糊不改变布局尺寸永不触发它，
    // 于是雾溢出槽位、盖住详情弹窗封面区下方的按钮区。
    // 修复：`_blurred` 里用 `ClipRect`（无条件裁剪）包住 `ImageFiltered`。

    testWidgets('敏感态（详情弹窗同构布局）：ClipRect 包裹 ImageFiltered，'
        '裁剪边界与槽位重合', (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path): _det(),
      });

      // 与 game_detail_dialog._buildLeftPanel 同构：
      // 左面板 Container(280, Clip.hardEdge) > Column[
      //   Expanded > Stack > SizedBox.expand(NsfwImage), 按钮列 ]
      // child 用 RawImage（同步就绪，布局行为与解码成功的 Image.file 一致），
      // 内在尺寸取竖版封面 600×900。
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 960,
                height: 600,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Container(
                      width: 280,
                      clipBehavior: Clip.hardEdge,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Column(
                        children: <Widget>[
                          Expanded(
                            child: Stack(
                              children: <Widget>[
                                SizedBox.expand(
                                  child: NsfwImage.file(
                                    _path,
                                    contentKind: NsfwContentKind.cover,
                                    fit: BoxFit.cover,
                                    child: RawImage(
                                      image: image600x900,
                                      width: double.infinity,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Container(height: 40, color: Colors.blue),
                                const SizedBox(height: 10),
                                Container(height: 40, color: Colors.blue),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // ① ClipRect 存在于 NsfwImage 内（与 ImageFiltered 构成
      //    ClipRectLayer > ImageFilterLayer 的合成层级，雾被钉死）
      final Finder clipFinder = find.descendant(
        of: find.byType(NsfwImage),
        matching: find.byType(ClipRect),
      );
      expect(clipFinder, findsOneWidget, reason: '模糊必须被 ClipRect 包裹');

      // ② 裁剪边界 = NsfwImage 槽位：雾不再外扩进按钮区
      final RenderBox clipBox = tester.renderObject(clipFinder);
      final RenderBox nsfwBox = tester.renderObject(find.byType(NsfwImage));
      expect(clipBox.size, nsfwBox.size,
          reason: 'ClipRect 尺寸必须等于槽位');
      expect(clipBox.localToGlobal(Offset.zero),
          nsfwBox.localToGlobal(Offset.zero),
          reason: 'ClipRect 位置必须与槽位重合');
    });

    testWidgets('未判定模糊预览态：同样有 ClipRect 包裹', (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{});

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, child: _child0()),
      ));

      expect(_blur, findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(NsfwImage),
          matching: find.byType(ClipRect),
        ),
        findsOneWidget,
      );
    });

    testWidgets('健康透传态：不引入 ClipRect（零开销性质）', (WidgetTester tester) async {
      enable();
      seed(<String, NsfwDetection>{
        NsfwDetectionStore.keyForFile(_path):
            _det(boxes: const <NsfwBox>[]),
      });

      await tester.pumpWidget(_host(
        NsfwImage.file(_path, child: _child0()),
      ));

      expect(_child, findsOneWidget);
      expect(_blur, findsNothing);
      expect(find.byType(ClipRect), findsNothing);
    });
  });
}
