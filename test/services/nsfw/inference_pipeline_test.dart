import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chrono_tide/core/path_helper.dart';
import 'package:chrono_tide/services/nsfw/nsfw_detection_service.dart';
import 'package:chrono_tide/services/nsfw/nsfw_detection_store.dart';
import 'package:chrono_tide/services/nsfw/nsfw_settings.dart';

/// 真实 ONNX 推理链路集成测试（区别于 mock 的单元/组件测试）。
///
/// 跑通「DLL 加载 → 模型从 assets 释放 → worker isolate 就绪 → 真实推理 →
/// YOLO 后处理 → 判定落库」的完整链路，填补此前"真机模型推理未验证"的缺口。
///
/// 环境要求：
/// - `onnxruntime.dll` 需在进程搜索路径上（运行时给 PATH 加
///   `build/windows/x64/runner/Release`，或复制到 flutter_tester 同目录）；
/// - 模型从 pubspec 声明的 `assets/models/` 经 rootBundle 释放到临时目录，
///   不污染真实 `data/`。
///
/// 测试图用项目自带 benign 图标图（非敏感内容），期望判定为健康（无合成框）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpRoot;

  setUpAll(() async {
    tmpRoot = await Directory.systemTemp.createTemp('nsfw_infer_test');
    // 必须在任何 PathHelper 路径 getter 首次访问前设置（路径会缓存）
    PathHelper.exeDirOverride = tmpRoot.path;
    // 开启开关（绕过 SharedPreferences；load() 幂等不会覆盖）
    NsfwSettings.instance.seedForTest(enabled: true);
  });

  tearDownAll(() async {
    PathHelper.exeDirOverride = null;
    NsfwDetectionService.resetForTest();
    try {
      await tmpRoot.delete(recursive: true);
    } catch (_) {}
  });

  test(
    '全链路：DLL→模型释放→worker→推理→后处理（benign 图应零检出）',
    () async {
      final File img = File('assets/images/reward_default.png');
      expect(img.existsSync(), isTrue,
          reason: '测试用 benign 图片应存在于 assets');

      final det = await NsfwDetectionService.instance
          .detectFile(img.absolute.path, force: true);

      expect(det, isNotNull,
          reason: '推理链路应成功：DLL 加载→模型释放→worker 就绪→推理→后处理');
      expect(det!.imgW, greaterThan(0), reason: '应记录真实图片尺寸');
      expect(det.boxes, isEmpty,
          reason: '良性图标图在 0.648 阈值下不应判定敏感');

      // 判定应落库（渲染层按此键查询）
      final String key = NsfwDetectionStore.keyForFile(img.absolute.path);
      expect(NsfwDetectionStore.instance.detectionFor(key), isNotNull,
          reason: '检测结果应写入判定缓存');
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
