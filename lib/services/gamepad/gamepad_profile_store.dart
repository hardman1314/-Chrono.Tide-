/// 游戏手柄适配 —— 每游戏映射配置的独立持久化存储（Phase 2）
///
/// 设计范式（原参照 watch_candidates_store，该存储 2026-10-03 已随
/// 候选队列内存化而移除）：
/// - **独立文件** `data/gamepad_profiles.json`：不触碰 game.json ⇒
///   不触发 `format_version` 迁移，零 schema 回归面；
/// - **原子写**：先写 `.tmp` 再 rename，崩溃不会截断；
/// - **异步写**：不阻塞 UI isolate；
/// - **写合并**：写入期间的后续保存只保留最后一份载荷（last-write-wins）；
/// - **容错**：文件缺失/损坏/`format_version` 不认 → 返回 null（调用方
///   降级为内置预设），**绝不抛错**。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../core/path_helper.dart';
import 'gamepad_profile.dart';

class GamepadProfileStore {
  GamepadProfileStore._();

  /// 测试可见的写盘计数（用于断言写合并生效）
  @visibleForTesting
  static int debugWriteCount = 0;

  /// 测试钩子：写盘前调用（可注入延迟，让「写入期间新载荷入队」可确定性复现）
  @visibleForTesting
  static Future<void> Function()? debugWriteHook;

  static File get _file => File(PathHelper.gamepadProfilesFilePath);

  static Map<String, dynamic>? _queuedPayload;
  static Future<void>? _pending;

  /// 读取原始 JSON。文件不存在/损坏/版本不认 → null（调用方降级为内置预设）。
  static Future<Map<String, dynamic>?> loadRaw() async {
    try {
      final file = _file;
      if (!file.existsSync()) return null;
      final content = await file.readAsString();
      if (content.trim().isEmpty) return null;
      final decoded = json.decode(content);
      if (decoded is! Map) {
        debugPrint('[GAMEPAD-STORE] 配置文件格式非法（非对象），忽略');
        return null;
      }
      final version = decoded['format_version'];
      if (version is! int || version != GamepadProfileFile.formatVersion) {
        debugPrint('[GAMEPAD-STORE] format_version 不认（$version），忽略');
        return null;
      }
      return Map<String, dynamic>.from(decoded);
    } catch (e) {
      debugPrint('[GAMEPAD-STORE] 读取手柄配置失败（降级为预设）: $e');
      return null;
    }
  }

  /// 读取类型化配置。任何异常 → 内置默认（generic_vn 预设），绝不抛错。
  static Future<GamepadProfileFile> load() async {
    final raw = await loadRaw();
    if (raw == null) return GamepadProfileFile();
    try {
      return GamepadProfileFile.fromJson(raw);
    } catch (e) {
      debugPrint('[GAMEPAD-STORE] 解析手柄配置失败（降级为预设）: $e');
      return GamepadProfileFile();
    }
  }

  /// 保存类型化配置（自动盖 updated_at；异步 + 原子 + 合并）。
  ///
  /// 返回的 Future 在"本次载荷确实落盘"后完成；若写入期间又有新载荷，
  /// 则先前的调用会在下一次写入开始时即返回（合并语义）。
  static Future<void> save(GamepadProfileFile file) {
    final payload = file
        .copyWith(updatedAt: DateTime.now().toUtc().toIso8601String())
        .toJson();
    return saveRaw(payload);
  }

  /// 保存原始 JSON（异步 + 原子 + 合并）
  static Future<void> saveRaw(Map<String, dynamic> payload) {
    _queuedPayload = payload;
    final pending = _pending;
    if (pending != null) return pending;
    final future = _drain();
    _pending = future;
    return future;
  }

  /// 顺序消费待写载荷（写入期间新来的载荷合并为最后一次）
  static Future<void> _drain() async {
    try {
      while (_queuedPayload != null) {
        final payload = _queuedPayload!;
        _queuedPayload = null;
        debugWriteCount++;
        try {
          final hook = debugWriteHook;
          if (hook != null) await hook();
          final encoded = json.encode(payload);
          final file = _file;
          final parent = file.parent;
          if (!parent.existsSync()) {
            await parent.create(recursive: true);
          }
          final tmp = File('${file.path}.tmp');
          await tmp.writeAsString(encoded, flush: true);
          await tmp.rename(file.path);
        } catch (e) {
          debugPrint('[GAMEPAD-STORE] 写入手柄配置失败: $e');
        }
      }
    } finally {
      _pending = null;
    }
  }

  /// 等待当前待写载荷落盘（应用退出/测试用）
  static Future<void> flush() async {
    final pending = _pending;
    if (pending != null) await pending;
  }

  /// 是否正在写入（诊断用）
  static bool get isWriting => _pending != null;
}
