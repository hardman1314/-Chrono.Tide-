import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/pb_config.dart';
import '../utils/pb_filter.dart';
import 'user_cache_service.dart';

/// 游戏安装统计服务
///
/// 负责：
/// 1. 安装成功后向 PocketBase 上报统计数据（install_records 集合）
/// 2. 累计 games 集合的 installCount 字段
/// 3. 防重复统计（本地防重 + 服务端查重双重保障）
///
/// PocketBase 数据结构要求：
/// - games 集合新增字段：installCount（number，默认 0）
/// - install_records 集合：gameId(text)、userName(text)、gameTitle(text)
///   建议配置唯一索引 UNIQUE(gameId, userName) 以杜绝并发重复计数
///
/// 数据使用规范：
/// - install_records 仅存储在 PocketBase 后端，不在前端展示
/// - 安装人数统计数据仅用于游戏活跃度分析和游戏排行整理
class InstallStatsService {
  InstallStatsService._();

  static final InstallStatsService instance = InstallStatsService._();

  /// 本地防重标记的 SharedPreferences 键（已上报过的 gameId 集合）
  static const String _prefsKey = 'reported_install_game_ids';

  /// PB 集合名
  static const String _recordsCollection = 'install_records';
  static const String _gamesCollection = 'games';

  /// 上报中/已上报的 gameId 集合（内存级，防同会话并发重复）
  final Set<String> _inFlight = <String>{};

  /// 安装成功后上报统计数据（fire-and-forget，不阻塞安装流程）
  ///
  /// 防重策略（三层）：
  /// 1. 内存级：同会话内同一 gameId 只上报一次
  /// 2. 本地持久化：已上报的 gameId 记录在 SharedPreferences
  /// 3. 服务端查重：install_records 中已存在 (gameId, userName) 记录则跳过计数
  ///
  /// 并发一致性：计数更新采用「读-改-写」，建议在 PocketBase 后台为
  /// install_records 配置 UNIQUE(gameId, userName) 唯一索引作为最终防线。
  Future<void> reportInstall({
    required String gameId,
    required String gameTitle,
  }) async {
    if (gameId.isEmpty) return;

    // 内存级防重
    if (_inFlight.contains(gameId)) {
      debugPrint('[INSTALL-STATS] ⏭️ 上报进行中，跳过重复上报: $gameId');
      return;
    }
    _inFlight.add(gameId);

    try {
      // 未登录或无用户名：无法归属安装用户，跳过统计
      final userName = UserCacheService.userName.trim();
      if (!PBConfig.isLoggedIn || userName.isEmpty) {
        debugPrint('[INSTALL-STATS] ⏭️ 未登录或无用户名，跳过统计上报');
        return;
      }

      // 本地持久化防重
      final alreadyReported = await _isReportedLocally(gameId);
      if (alreadyReported) {
        debugPrint('[INSTALL-STATS] ⏭️ 本地已上报过，跳过: $gameId');
        return;
      }

      // 服务端查重：该用户是否已安装过该游戏
      final existed = await _hasServerRecord(gameId, userName);
      if (existed) {
        debugPrint('[INSTALL-STATS] ⏭️ 服务端已有安装记录，仅补本地标记: $gameId');
        await _markReportedLocally(gameId);
        return;
      }

      // 创建安装用户记录
      await PBConfig.pb.collection(_recordsCollection).create(body: {
        'gameId': gameId,
        'userName': userName,
        'gameTitle': gameTitle,
      });
      debugPrint('[INSTALL-STATS] ✅ 安装记录已创建: $gameId / $userName');

      // 累计 games.installCount（读-改-写，窗口极小）
      await _incrementGameInstallCount(gameId);

      // 本地标记已上报
      await _markReportedLocally(gameId);
      debugPrint('[INSTALL-STATS] 🎉 统计上报完成: $gameId ($gameTitle)');
    } catch (e) {
      // 统计失败不影响安装主流程；移除内存标记允许后续重试
      debugPrint('[INSTALL-STATS] ⚠️ 统计上报失败（不影响安装）: $e');
      _inFlight.remove(gameId);
      return;
    }
  }

  /// 获取指定游戏的总安装人数（详情页展示用）
  ///
  /// 返回 null 表示获取失败或字段缺失（UI 可选择不展示）
  Future<int?> fetchInstallCount(String gameId) async {
    if (gameId.isEmpty) return null;
    try {
      final record = await PBConfig.pb
          .collection(_gamesCollection)
          .getOne(gameId, fields: 'id,installCount');
      final value = record.data['installCount'];
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value);
      return null;
    } catch (e) {
      debugPrint('[INSTALL-STATS] ⚠️ 获取安装人数失败: $e');
      return null;
    }
  }

  /// 服务端查重：install_records 中是否已存在 (gameId, userName) 记录
  Future<bool> _hasServerRecord(String gameId, String userName) async {
    try {
      // ★ P1-1：gameId / userName 均经统一转义（先反斜杠、再单引号 + 截断 + 空串短路）
      // _escape 现委托给 PbFilter.escapeLiteral，调用点保持不变。
      final filter =
          "gameId='${PbFilter.escapeLiteral(gameId)}' && userName='${_escape(userName)}'";
      final result = await PBConfig.pb
          .collection(_recordsCollection)
          .getFirstListItem(filter);
      return result.id.isNotEmpty;
    } on ClientException {
      // PocketBase 404（无匹配记录）会抛 ClientException
      return false;
    }
  }

  /// 累计 games.installCount：读取当前值后 +1 写回
  Future<void> _incrementGameInstallCount(String gameId) async {
    try {
      final record = await PBConfig.pb
          .collection(_gamesCollection)
          .getOne(gameId, fields: 'id,installCount');
      final current = record.data['installCount'];
      final currentValue = current is num ? current.toInt() : 0;
      await PBConfig.pb.collection(_gamesCollection).update(gameId, body: {
        'installCount': currentValue + 1,
      });
      debugPrint(
          '[INSTALL-STATS] ✅ installCount 已更新: $currentValue → ${currentValue + 1}');
    } catch (e) {
      debugPrint('[INSTALL-STATS] ⚠️ installCount 更新失败: $e');
      rethrow;
    }
  }

  /// 本地防重：gameId 是否已上报过
  Future<bool> _isReportedLocally(String gameId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ids = prefs.getStringList(_prefsKey) ?? [];
      return ids.contains(gameId);
    } catch (_) {
      return false;
    }
  }

  /// 本地防重：标记 gameId 已上报
  Future<void> _markReportedLocally(String gameId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ids = prefs.getStringList(_prefsKey) ?? [];
      if (!ids.contains(gameId)) {
        ids.add(gameId);
        await prefs.setStringList(_prefsKey, ids);
      }
    } catch (e) {
      debugPrint('[INSTALL-STATS] ⚠️ 本地标记写入失败: $e');
    }
  }

  /// PB filter 字符串转义
  ///
  /// ★ P1-1：旧实现只转义单引号，输入以 `\` 结尾时会转义掉闭合单引号，
  /// 导致整个 filter 解析失败（查重永远返回 false → 重复计数）。
  /// 统一委托给 [PbFilter.escapeLiteral]：先转义反斜杠、再转义单引号，
  /// 外加控制字符清理、长度截断与空串短路。调用点保持不变。
  static String _escape(String value) => PbFilter.escapeLiteral(value);

  /// 安装人数格式化（轻量展示用）：1234 → "1,234"
  static String formatCount(int count) {
    if (count >= 10000) {
      final w = count / 10000;
      return '${w >= 10 ? w.toStringAsFixed(0) : w.toStringAsFixed(1)} 万';
    }
    return count.toString();
  }
}
