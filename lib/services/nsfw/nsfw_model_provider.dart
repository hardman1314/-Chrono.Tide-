/// 模型文件提供者：把随包的 ONNX 模型从 assets 释放到 `data/models/`。
///
/// **为什么必须落盘再读，而不是直接把 asset 字节喂给 ORT：**
/// 推理跑在 worker isolate 里，而 `rootBundle` 只能在主 isolate 用。
/// 落盘后跨 isolate 只需传一个路径字符串，避免把 12MB 字节数组塞进 isolate 消息。
///
/// ⚠️ **不要改用 `OrtSession.fromFile`**：`onnxruntime` 1.4.1 的实现是
/// `modelFile.path.toNativeUtf8()`（`char*`），但 ORT 在 Windows 上的
/// `CreateSession` 签名是 `const ORTCHAR_T*`（即 `wchar_t*`），
/// UTF-8 字节会被当宽字符解析 → 路径乱码 → 建会话失败。
/// worker 侧必须自己 `readAsBytes()` 后走 `OrtSession.fromBuffer`。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import '../../core/path_helper.dart';

class NsfwModelProvider {
  NsfwModelProvider._();

  /// v2.4 起替换为 `deepghs/anime_dbrating` 的 `mobilenetv3_large_100_v0_ls0.2`
  /// （16.8MB，OpenRAIL）：四级评分分类器（general/sensitive/questionable/
  /// explicit），判定走「整图评分 + 阈值」而不是部位框检测。选型依据见
  /// `docs/DEV/features/nsfw_filter_implementation_plan.md` §15（v2.4）：
  /// 用户 69 张参考集误报 1→0、召回 22→25，且抓到旧模型完全漏检的明确
  /// R18 封面；同场实测的 caformer_s36（149.6MB）质量更高但体积超预算，
  /// int8/fp16 压缩在本机 CPU 上慢 5-7 倍（无 int8 VNNI / fp16 算子），
  /// 均否决。换模型时必须同步更新（连同 [NsfwSettings.modelId]）。
  static const String assetPath = 'assets/models/anime_dbrating_mv3_v0.onnx';
  static const String fileName = 'anime_dbrating_mv3_v0.onnx';

  /// 期望字节数，用于判断已释放的文件是否完整/是否需要覆盖。
  static const int expectedBytes = 16832684;

  static String? _cachedPath;

  /// 确保模型已释放到磁盘，返回其绝对路径。失败返回 `null`。
  static Future<String?> ensureExtracted() async {
    if (_cachedPath != null) return _cachedPath;
    try {
      final Directory dir = Directory(PathHelper.modelsDir);
      if (!await dir.exists()) await dir.create(recursive: true);
      final File target = File(p.join(dir.path, fileName));

      if (await target.exists() && await target.length() == expectedBytes) {
        _cachedPath = target.path;
        return _cachedPath;
      }

      final data = await rootBundle.load(assetPath);
      final bytes = data.buffer
          .asUint8List(data.offsetInBytes, data.lengthInBytes);
      // 先写临时文件再改名，避免上次写一半的残档被当成完整模型
      final File tmp = File('${target.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);

      debugPrint('[NSFW-MODEL] 已释放模型到 ${target.path}（${bytes.length} 字节）');
      _cachedPath = target.path;
      return _cachedPath;
    } catch (e) {
      debugPrint('[NSFW-MODEL] 释放模型失败: $e');
      return null;
    }
  }

  @visibleForTesting
  static void resetForTest() => _cachedPath = null;
}
