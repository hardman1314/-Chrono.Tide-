import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/path_helper.dart';
import '../game_data_format.dart';
import '../local_game_registry.dart';
import 'nsfw_detection_service.dart';
import 'nsfw_detection_store.dart';
import 'nsfw_settings.dart';

/// NSFW 全量扫描服务。
///
/// 职责：把库里**已有**游戏的封面与截图补进检测队列。
/// 下载触发点（CoverDownloadService / ScreenshotFetchService 落盘后入队）
/// 只能覆盖"新下载"的图片，存量图片（导入即有 / 历史遗留）依赖本服务。
///
/// 触发时机：
/// 1. 用户在设置页**首次开启**总开关 → `startFullScan()`（仅跑一次，
///    由 `NsfwSettings.hasEverFullScanned` 持久化防重）
/// 2. 设置页「重新扫描」→ `startFullScan(force: true)`
///
/// 幂等性：store 已有判定记录的文件直接跳过；`detectFile` 内部还会对
/// 已失败文件去重。因此重复扫描的成本 ≈ 一次目录遍历。
class NsfwScanService extends ChangeNotifier {
  NsfwScanService._();
  static final NsfwScanService instance = NsfwScanService._();

  bool _scanning = false;
  bool get isScanning => _scanning;

  int _total = 0;
  int _enqueued = 0;
  int get total => _total;
  int get enqueued => _enqueued;

  /// 扫描全部游戏的封面 + 截图，把未判定的文件入检测队列。
  ///
  /// - [force] = false：仅当「从未全量扫描过」时执行（首次开启开关场景）；
  /// - [force] = true：无条件重扫（未判定文件才真正入队，已判定跳过）。
  ///
  /// 总开关关闭时直接返回：不扫、不写 `fullScanDoneAt`
  /// （这样关闭期间用户补了图，再开开关时仍会被扫到）。
  Future<void> startFullScan({bool force = false}) async {
    final NsfwSettings settings = NsfwSettings.instance;
    await settings.load();
    if (!settings.enabled) return;
    if (_scanning) return;
    if (!force && settings.hasEverFullScanned) return;

    _scanning = true;
    _total = 0;
    _enqueued = 0;
    notifyListeners();
    try {
      // 本轮已见过的 key：metaDataDir 与 gamesDir 可能指向同一目录，
      // registry 与 gamesDir 兜底两轮扫描必须去重，防止重复入队。
      final Set<String> seenKeys = <String>{};
      // 快照，避免扫描期间 registry 变动导致并发修改
      final List<LibraryGame> games =
          List<LibraryGame>.from(LocalGameRegistry.instance.allGames);
      for (final LibraryGame game in games) {
        final String dir = game.metaDataDir;
        if (dir.isEmpty) continue;
        _scanGameDir(dir, seenKeys);
      }
      // 兜底：手动导入游戏的 metaDataDir 指向游戏本体目录（无
      // game.json/cover/screenshots 元数据，扫不出任何文件），元数据实际
      // 存放在 gamesDir/<安全名>/ 下——全量遍历 gamesDir 补扫。
      // findCoverFile / findScreenshotFiles 对无元数据目录返回空，天然安全。
      final Directory gamesDir = Directory(PathHelper.gamesDir);
      if (gamesDir.existsSync()) {
        for (final FileSystemEntity entity
            in gamesDir.listSync(followLinks: false)) {
          if (entity is! Directory) continue;
          _scanGameDir(entity.path, seenKeys);
        }
      }
      // 等队列消化完再落"已完成"标记：队列是内存态，若不等就标记，
      // 用户中途关闭应用会丢失未推完的任务，且 hasEverFullScanned 已置位
      // 导致此后永不自动补扫。15 分钟上限防御个别图片推理卡死——
      // 超时放弃标记时，剩余未判定文件可由设置页「补扫」按钮兜底。
      final DateTime deadline =
          DateTime.now().add(const Duration(minutes: 15));
      while (NsfwDetectionService.instance.pendingCount > 0 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      // 扫完立即落盘一次判定缓存，防中途退出丢失
      await NsfwDetectionStore.instance.flush();
      // 队列归零才落「已完成」标记：超时（超大库/个别图卡死）时放弃标记，
      // hasEverFullScanned 保持 false，下次开启开关或「补扫」会再试；
      // 上面的 flush 已保住本轮已判定的结果，重扫成本 ≈ 一次目录遍历。
      if (NsfwDetectionService.instance.pendingCount == 0) {
        await settings.markFullScanDone();
      }
    } finally {
      _scanning = false;
      notifyListeners();
    }
  }

  /// 扫描单个游戏元数据目录的封面 + 截图，未判定的文件入检测队列。
  void _scanGameDir(String dir, Set<String> seenKeys) {
    final File? cover = GameDataFormat.findCoverFile(dir);
    if (cover != null) _scanOneFile(cover.path, seenKeys);
    for (final String path in GameDataFormat.findScreenshotFiles(dir)) {
      _scanOneFile(path, seenKeys);
    }
  }

  void _scanOneFile(String path, Set<String> seenKeys) {
    final String key = NsfwDetectionStore.keyForFile(path);
    if (key.isEmpty) return;
    if (!seenKeys.add(key)) return; // 本轮已处理过
    _total++;
    if (NsfwDetectionStore.instance.detectionFor(key) != null) return;
    NsfwDetectionService.instance.enqueueFile(path);
    _enqueued++;
  }
}
