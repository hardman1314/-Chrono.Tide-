import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/path_helper.dart';
import 'company_alias_store.dart';

/// 未命中会社原文的收集漏斗（`data/company_alias_pending.json`）。
///
/// 词典（`assets/data/company_aliases.json`）永远不可能穷尽所有会社写法：
/// [CompanyAliasStore.resolve] 未命中的原文落到这里（计数 + 首见时间 +
/// 样例游戏），作为人工归并入库的候补清单 —— 词典负责头部，长尾靠本漏斗。
///
/// 设计约束（与 `SmartGroupService` 的持久化纪律一致）：
/// - 内存为事实源，落盘做**合并式原子写**（temp + rename）；
/// - 读取失败**绝不覆写磁盘**（保留人工恢复机会），本次会话只记内存；
/// - 有容量上限（[maxEntries]），防止脏数据源把文件写爆；
/// - 写盘节流（[record] 只标脏，800ms 定时器合并刷盘），导入高峰期
///   不会产生每条一次的磁盘写。
class CompanyAliasPendingStore {
  CompanyAliasPendingStore._();

  static final CompanyAliasPendingStore instance = CompanyAliasPendingStore._();

  /// 容量上限：达到后不再收录新键（已有键的计数照常累加）。
  static const int maxEntries = 1000;

  /// 每条记录保留的样例游戏 id 上限（供人工归并时核对）。
  static const int maxSamplesPerEntry = 5;

  /// 测试专用路径覆盖（非空时替代真实 data 目录，避免单测触碰用户数据）
  @visibleForTesting
  static String? debugPathOverrideForTest;

  static String get _filePath =>
      debugPathOverrideForTest ??
      '${PathHelper.dataDir}${Platform.pathSeparator}company_alias_pending.json';

  /// 键 = [CompanyAliasStore.normalize] 后的原文
  final Map<String, _PendingEntry> _entries = {};
  bool _loaded = false;
  bool _loadFailed = false;
  Timer? _flushTimer;

  int get entryCount => _entries.length;

  /// 最近一次加载是否失败（失败时磁盘数据保留、未被覆写）
  bool get loadFailed => _loadFailed;

  /// 审阅 / 测试用快照（按计数降序）。
  List<Map<String, dynamic>> snapshot() {
    final list = _entries.values.toList()
      ..sort((a, b) => b.count.compareTo(a.count));
    return list.map((e) => e.toJson()).toList();
  }

  /// 记录一条未命中原文（幂等按键归并；同键只累加计数与样例）。
  ///
  /// [sampleGameId] 建议传稳定主键 `game_id`（目录名会变，id 终身不变）。
  Future<void> record(String raw, {String? sampleGameId}) async {
    final key = CompanyAliasStore.normalize(raw);
    if (key.isEmpty) return;
    await _ensureLoaded();
    final existing = _entries[key];
    if (existing == null && _entries.length >= maxEntries) {
      return; // 容量上限：不再收录新键（审阅清理后自然腾出空间）
    }
    final entry = existing ??
        _PendingEntry(
          raw: raw.trim(),
          firstSeen: DateTime.now().toIso8601String(),
        );
    entry.count += 1;
    final sid = (sampleGameId ?? '').trim();
    if (sid.isNotEmpty &&
        entry.sampleGameIds.length < maxSamplesPerEntry &&
        !entry.sampleGameIds.contains(sid)) {
      entry.sampleGameIds.add(sid);
    }
    _entries[key] = entry;
    _scheduleFlush();
  }

  /// 审阅后移除某键（人工已把它归并进词典 / 判定为无效）。
  Future<void> remove(String raw) async {
    final key = CompanyAliasStore.normalize(raw);
    if (key.isEmpty || !_entries.containsKey(key)) return;
    _entries.remove(key);
    _scheduleFlush();
  }

  /// 解析命中后的自动清理：company_id 非空才清对应键。
  ///
  /// 调用点：writeGameDir / setGameDeveloper / registerExtractionComplete /
  /// backfill / 详情页保存 —— 原文一旦解析成功就不该再留在待审漏斗里
  /// （否则词典扩批后旧 pending 条目永不消化，审阅列表只增不减）。
  Future<void> removeIfResolved(String raw, int? resolvedCompanyId) async {
    if (resolvedCompanyId == null) return;
    await remove(raw);
  }

  /// 清空（词典大版本重建时使用）。
  Future<void> clear() async {
    _entries.clear();
    _scheduleFlush();
  }

  // ==================== 持久化 ====================

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = File(_filePath);
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map<String, dynamic>) {
          final list = decoded['pending'];
          if (list is List) {
            for (final item in list) {
              if (item is! Map) continue;
              final m = Map<String, dynamic>.from(item);
              final key = (m['key'] as String?)?.trim() ?? '';
              final raw = (m['raw'] as String?)?.trim() ?? '';
              if (key.isEmpty || raw.isEmpty) continue;
              _entries[key] = _PendingEntry(
                raw: raw,
                firstSeen: (m['first_seen'] as String?) ?? '',
                count: (m['count'] as num?)?.toInt() ?? 0,
                sampleGameIds: (m['sample_game_ids'] as List?)
                        ?.map((e) => e.toString())
                        .toList() ??
                    const [],
              );
            }
          }
        }
      }
    } catch (e) {
      // 读取失败：磁盘数据保留、本次会话只记内存（不覆写，可人工恢复）
      _loadFailed = true;
      debugPrint('[COMPANY-PENDING] ⚠️ 加载失败（保留磁盘数据，本次不落盘）: $e');
    }
  }

  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 800), () {
      _flush();
    });
  }

  Future<void> _flush() async {
    if (_loadFailed) {
      debugPrint('[COMPANY-PENDING] ⛔ 跳过写盘：上次加载失败，避免覆写可恢复数据');
      return;
    }
    try {
      final file = File(_filePath);
      final dir = file.parent;
      if (!await dir.exists()) await dir.create(recursive: true);
      final data = {
        'format_version': 1,
        'updated_at': DateTime.now().toIso8601String(),
        'pending': _entries.values
            .map((e) => {'key': CompanyAliasStore.normalize(e.raw), ...e.toJson()})
            .toList(),
      };
      final tempPath =
          '$_filePath.${DateTime.now().microsecondsSinceEpoch}.tmp';
      final tempFile = File(tempPath);
      try {
        await tempFile.writeAsString(
            const JsonEncoder.withIndent('  ').convert(data),
            flush: true);
        await tempFile.rename(_filePath);
      } catch (e) {
        try {
          if (await tempFile.exists()) await tempFile.delete();
        } catch (_) {}
        rethrow;
      }
    } catch (e) {
      debugPrint('[COMPANY-PENDING] ⚠️ 保存失败: $e');
    }
  }

  /// 测试专用：立即刷盘（跳过 800ms 节流）。
  @visibleForTesting
  Future<void> flushNow() => _flush();

  /// 测试专用：清空内存态（不触碰磁盘）。
  @visibleForTesting
  void resetForTest() {
    _flushTimer?.cancel();
    _entries.clear();
    _loaded = false;
    _loadFailed = false;
  }
}

class _PendingEntry {
  _PendingEntry({
    required this.raw,
    required this.firstSeen,
    this.count = 0,
    List<String> sampleGameIds = const [],
  }) : sampleGameIds = List<String>.from(sampleGameIds);

  String raw;
  String firstSeen;
  int count;
  final List<String> sampleGameIds;

  Map<String, dynamic> toJson() => {
        'raw': raw,
        'first_seen': firstSeen,
        'count': count,
        'sample_game_ids': sampleGameIds,
      };
}
