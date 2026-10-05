/// 游戏身份工具的**唯一实现**（P0-1，2026-09-19 游戏数据结构审查批 2）。
///
/// ## 存在的理由
///
/// 项目里曾有多处各自手写的「标题 → 文件名」清洗规则：
/// - `LocalGameRegistry.registerExtractionComplete`
/// - `LocalGameRegistry.updateGameTitle`
/// - `LocalGameRegistry.getGameByTitle` 的 safeName 回退分支
/// - `GameConfigManager._sanitizeGameId`
///
/// 前四处正则相同，唯独 `GameConfigManager` 会把**空白替换成 `_`**。
/// 同一个游戏在两条路径上会算出不同的 key —— 一个走 `_games[safeName]`、
/// 一个走 scan 产出的目录名，两者可以同时存在，于是一张卡片变两张、
/// 游玩时长重复计入。这类 bug 只在"标题里带空格 + 改过标题"时才触发，
/// 极难复现。
///
/// 🔴 纪律：任何「把标题变成键/文件名」的地方都必须调用 [dirNameFromTitle]，
/// 禁止再自写正则；UUID 生成也必须走 [generateId]。
library;

import 'dart:math' as math;

import 'title_cleaner.dart';

class GameKey {
  GameKey._();

  /// 标题 → 可作为目录名/文件名的安全串。
  ///
  /// 规则：Windows 非法字符 `\ / : * ? " < > |` → `_`，再 trim。
  /// **不**动空白字符（与 `GameConfigManager` 的历史行为不同，见文件头注释）。
  static String dirNameFromTitle(String title) =>
      title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();

  /// 比较用标题归一化（全角折叠 + 去空白标点 + 小写）。
  ///
  /// 直接委托 [TitleCleaner.normalizeForCompare]：排重、标题索引、
  /// 智能归纳都复用同一套归一化语义，不在这里另起炉灶。
  static String normalizeTitle(String title) =>
      TitleCleaner.normalizeForCompare(title);

  /// 生成 UUID v4 字符串（不依赖第三方库）。
  ///
  /// 格式：`xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`（y ∈ {8,9,a,b}）。
  /// 用于游戏稳定主键 `game_id` 与会话 ID —— 两者共用同一实现，
  /// 全项目只保留这一处随机 ID 生成逻辑。
  static String generateId() {
    final rng = math.Random();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    bytes[6] = (bytes[6] & 0x0F) | 0x40; // version 4
    bytes[8] = (bytes[8] & 0x3F) | 0x80; // variant 10xxxxxx
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }
}
