import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// BPM 游玩历史记录服务 (v3.3, 新增能力)
///
/// 桌面模式没有「启动历史/启动次数」数据源 ([LibraryGame] 仅有
/// playTime / firstOpenedAt / lastOpenedAt),本服务为 BPM 详情面板
/// 提供这两项数据的采集与读取:
///
/// - 每次从 BPM 成功启动游戏,追加一条启动记录到
///   `metaDataDir/bpm_play_history.json`(时间戳 + 启动模式)
/// - 详情面板读取该文件渲染「游玩历史」倒序列表与「启动次数」统计
///
/// 设计约束:
/// - 纯新增文件,不改桌面启动链路 (桌面启动暂不埋点)
/// - 记录上限 200 条,超出截断最旧,防止文件无限膨胀
/// - 所有 I/O 失败静默降级 (返回空列表/写失败仅 debugPrint),
///   绝不阻塞启动主流程
class BpmPlayHistoryEntry {
  /// 启动时间 (ISO8601 字符串,本地时区)
  final String startedAt;

  /// 启动模式: normal | locale | upscaling
  final String mode;

  const BpmPlayHistoryEntry({required this.startedAt, required this.mode});

  Map<String, dynamic> toJson() => {'started_at': startedAt, 'mode': mode};

  static BpmPlayHistoryEntry fromJson(Map<String, dynamic> j) =>
      BpmPlayHistoryEntry(
        startedAt: (j['started_at'] ?? '').toString(),
        mode: (j['mode'] ?? 'normal').toString(),
      );

  /// 展示用模式名
  String get modeLabel => switch (mode) {
        'upscaling' => '超分启动',
        'locale' => '转区启动',
        _ => '普通启动',
      };
}

class BpmPlayHistory {
  BpmPlayHistory._();

  static const String _fileName = 'bpm_play_history.json';
  static const int _maxEntries = 200;

  static String _filePath(String metaDataDir) => '$metaDataDir/$_fileName';

  /// 读取全部记录 (按时间倒序,最新在前);文件缺失/损坏返回空列表
  static List<BpmPlayHistoryEntry> load(String metaDataDir) {
    if (metaDataDir.isEmpty) return const [];
    try {
      final f = File(_filePath(metaDataDir));
      if (!f.existsSync()) return const [];
      final raw = jsonDecode(f.readAsStringSync());
      if (raw is! List) return const [];
      final entries = raw
          .whereType<Map>()
          .map((m) => BpmPlayHistoryEntry.fromJson(m.cast<String, dynamic>()))
          .toList();
      // 倒序 (最新在前)
      entries.sort((a, b) => b.startedAt.compareTo(a.startedAt));
      return entries;
    } catch (_) {
      return const [];
    }
  }

  /// 记录一次启动 (append + 截断);失败静默
  static Future<void> recordLaunch(
    String metaDataDir, {
    required String mode,
  }) async {
    if (metaDataDir.isEmpty) return;
    try {
      final f = File(_filePath(metaDataDir));
      final list = <Map<String, dynamic>>[];
      if (f.existsSync()) {
        final raw = jsonDecode(f.readAsStringSync());
        if (raw is List) {
          list.addAll(
            raw.whereType<Map>().map((m) => m.cast<String, dynamic>()),
          );
        }
      }
      list.add({
        'started_at': DateTime.now().toIso8601String(),
        'mode': mode,
      });
      // 上限截断 (保留最新)
      if (list.length > _maxEntries) {
        list.removeRange(0, list.length - _maxEntries);
      }
      const encoder = JsonEncoder();
      await f.writeAsString(encoder.convert(list), flush: true);
    } catch (e) {
      debugPrint('[BPM-HISTORY] ⚠️ 启动记录写入失败: $e');
    }
  }

  /// 启动次数 = 记录条数
  static int launchCount(String metaDataDir) => load(metaDataDir).length;
}
