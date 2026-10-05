import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';
import '../core/pb_config.dart';
import '../models/game_model.dart';
import '../utils/pb_filter.dart';

/// 单页游戏列表结果（含服务端权威分页信息）
///
/// [totalPages] 由服务端按"实际生效的 perPage"计算，是判断
/// 数据是否加载完整的可靠依据（免疫 perPage 被服务端钳制的情况）。
class GameListPageResult {
  final List<GameModel> items;
  final int totalItems;
  final int totalPages;

  const GameListPageResult({
    required this.items,
    required this.totalItems,
    required this.totalPages,
  });
}

/// 全量游戏加载结果
class AllGamesResult {
  final List<GameModel> games;
  final bool isComplete; // 是否成功取回全部页（个别页失败时为 false）
  final int totalItems;

  const AllGamesResult({
    required this.games,
    required this.isComplete,
    required this.totalItems,
  });
}

/// 元数据回传云端的结果
///
/// 仅用于日志与「是否继续尝试」的判定，全部失败都静默降级，不影响 UI。
enum GameMetadataUploadStatus {
  ok, // 写入成功
  empty, // 无有效值可写（抓取结果为空）
  unauthenticated, // 未登录（云端要求登录才能改记录）
  rejected, // 被服务端拒绝（400/404：字段不存在或无权改）——本次运行不再尝试
  failed, // 网络/未知错误
}

class GameRepository {
  static const int pageSize = 20;

  static Future<List<GameModel>> getGameList({
    int page = 1,
    int perPage = pageSize,
    String searchQuery = '',
  }) async {
    debugPrint('[PB] 开始请求PB games集合');
    debugPrint(
        '[PB]   请求地址: ${PBConfig.pb.baseUrl}/api/collections/games/records');
    debugPrint(
        '[PB]   参数: page=$page, perPage=$perPage${searchQuery.isNotEmpty ? ', 搜索: "$searchQuery"' : ''}');

    try {
      // ★ P1-1：用户输入必须先转义再拼进 filter，否则可构造布尔盲注条件
      // 探测集合中其他字段（含关联字段）的取值，或以反斜杠结尾破坏表达式。
      // 多字段 OR：标题/日文原名/英文名/繁中别名（别名检索，2026-10-05）
      final filter = PbFilter.nameSearchFilter(searchQuery);

      final result = await PBConfig.pb.collection('games').getList(
            page: page,
            perPage: perPage,
            sort: '-created',
            filter: filter,
            expand: '',
          );

      final games =
          result.items.map((record) => GameModel.fromPBRecord(record)).toList();

      debugPrint('[PB] ✅ 请求成功，返回条数: ${games.length}');
      if (games.isEmpty) {
        debugPrint('[PB] ⚠️ 请求成功，但games集合无数据');
      } else {
        // 性能优化: 全量加载时单次可达数百条，逐条打印会拖慢调试模式，
        // 仅打印前3条样本 + 总数摘要
        for (var i = 0; i < games.length && i < 3; i++) {
          final g = games[i];
          debugPrint(
              '[PB]   游戏[${i + 1}]: Title="${g.title}", coverURL=${g.coverUrl.isNotEmpty ? g.coverUrl : "(无)"}');
        }
        if (games.length > 3) debugPrint('[PB]   ...共 ${games.length} 条');
      }

      return games;
    } on ClientException catch (e) {
      if (_isNetworkError(e)) {
        debugPrint('[ERROR] ❌ PB网络异常 - getGameList: ${e.toString()}');
        throw Exception('网络连接失败，请检查网络后重试');
      }
      debugPrint(
          '[ERROR] ❌ PB请求失败 (${e.statusCode}) - getGameList: ${e.toString()}');
      throw Exception('获取游戏列表失败 (${e.statusCode})');
    } catch (e) {
      if (e is SocketException || e is IOException) {
        debugPrint('[ERROR] ❌ PB连接异常 - getGameList: $e');
        throw Exception('无法连接服务器，请检查网络连接');
      }
      debugPrint('[ERROR] ❌ PB未知错误 - getGameList: $e');
      throw Exception('获取游戏列表时发生未知错误');
    }
  }

  /// 获取单页游戏列表（带服务端分页元信息，供全量加载翻页使用）
  static Future<GameListPageResult> getGameListPage({
    int page = 1,
    int perPage = pageSize,
  }) async {
    try {
      final result = await PBConfig.pb.collection('games').getList(
            page: page,
            perPage: perPage,
            sort: '-created',
            filter: null,
            expand: '',
          );
      final games =
          result.items.map((record) => GameModel.fromPBRecord(record)).toList();
      debugPrint('[PB] ✅ getGameListPage: page=$page 返回${games.length}条 '
          '(总数=${result.totalItems}, 总页数=${result.totalPages})');
      return GameListPageResult(
        items: games,
        totalItems: result.totalItems,
        totalPages: result.totalPages,
      );
    } catch (e) {
      throw _translateListError(e);
    }
  }

  /// 一次拉取全部游戏（探索页搜索/标签筛选的完整数据集）
  ///
  /// 翻页由服务端返回的 [GameListPageResult.totalPages] 驱动，
  /// 不依赖"返回条数 == perPage"推断——后者在服务端钳制 perPage 时会
  /// 提前误判为加载完毕（历史上导致标签不全、底部游戏搜不到）。
  /// 首页之后的页分小批并发请求；个别页失败时跳过并标记 isComplete=false，
  /// 调用方可据此保留滚动加载兜底。
  static Future<AllGamesResult> getAllGames({
    int perPage = 100,
    int maxConcurrent = 3,
  }) async {
    final first = await getGameListPage(page: 1, perPage: perPage);
    final games = <GameModel>[...first.items];

    if (first.totalPages <= 1) {
      return AllGamesResult(
          games: games, isComplete: true, totalItems: first.totalItems);
    }

    var allPagesFetched = true;
    final remainingPages = [
      for (var p = 2; p <= first.totalPages; p++) p
    ];

    // 分批并发（每批 maxConcurrent 页），避免瞬时请求过多
    for (var i = 0; i < remainingPages.length; i += maxConcurrent) {
      final batch = remainingPages.skip(i).take(maxConcurrent).toList();
      final results = await Future.wait(batch.map((p) async {
        // v2.1.16：单页失败重试 1 次（2s 退避）再放弃。此前一次失败直接
        // 跳过 → isComplete=false → 调用方 15s 后整轮自愈重拉（60s 超时），
        // VPS 慢响应抖动常见，网络慢时反复循环表现为"加载时好时坏"。
        for (var attempt = 0; attempt < 2; attempt++) {
          if (attempt > 0) {
            await Future<void>.delayed(const Duration(seconds: 2));
          }
          try {
            return await getGameListPage(page: p, perPage: perPage);
          } catch (e) {
            if (attempt == 1) {
              debugPrint('[PB] ⚠️ getAllGames 第$p页重试后仍失败(跳过): $e');
            }
          }
        }
        return null;
      }));
      for (final r in results) {
        if (r == null) {
          allPagesFetched = false;
          continue;
        }
        games.addAll(r.items);
      }
    }

    // 并发完成顺序不定 + 分页边界可能重叠：按 id 去重，
    // 再按 created 降序恢复与服务端 -created 一致的排序
    final byId = <String, GameModel>{};
    for (final g in games) {
      byId[g.id] = g;
    }
    final all = byId.values.toList()
      ..sort((a, b) => b.created.compareTo(a.created));

    debugPrint('[PB] ✅ getAllGames: ${all.length}/${first.totalItems}条, '
        '完整=$allPagesFetched');
    return AllGamesResult(
      games: all,
      isComplete: allPagesFetched,
      totalItems: first.totalItems,
    );
  }

  /// 统一的列表请求错误翻译（网络错误 → 中文提示）
  static Exception _translateListError(Object e) {
    if (e is ClientException) {
      if (_isNetworkError(e)) {
        debugPrint('[ERROR] ❌ PB网络异常 - getGameListPage: ${e.toString()}');
        return Exception('网络连接失败，请检查网络后重试');
      }
      debugPrint(
          '[ERROR] ❌ PB请求失败 (${e.statusCode}) - getGameListPage: ${e.toString()}');
      return Exception('获取游戏列表失败 (${e.statusCode})');
    }
    if (e is SocketException || e is IOException) {
      debugPrint('[ERROR] ❌ PB连接异常 - getGameListPage: $e');
      return Exception('无法连接服务器，请检查网络连接');
    }
    debugPrint('[ERROR] ❌ PB未知错误 - getGameListPage: $e');
    return Exception('获取游戏列表时发生未知错误');
  }

  static Future<GameModel?> getGameById(String gameId) async {
    debugPrint('[PB] 开始获取游戏详情 | gameId=$gameId');

    try {
      final record = await PBConfig.pb.collection('games').getOne(gameId);
      final game = GameModel.fromPBRecord(record);

      debugPrint(
          '[PB] ✅ 游戏详情加载成功 | Title="${game.title}" | coverURL=${game.coverUrl.isNotEmpty ? game.coverUrl : "(无)"} | Tags: ${game.tags.join(', ')}');

      return game;
    } on ClientException catch (e) {
      if (e.statusCode == 404) {
        debugPrint('[ERROR] ❌ 游戏不存在 ($gameId): ${e.toString()}');
        throw Exception('游戏不存在或已被删除');
      }
      if (_isNetworkError(e)) {
        debugPrint('[ERROR] ❌ PB网络异常 - getGameById: ${e.toString()}');
        throw Exception('网络连接失败，请检查网络后重试');
      }
      debugPrint(
          '[ERROR] ❌ PB请求失败 (${e.statusCode}) - getGameById: ${e.toString()}');
      throw Exception('获取游戏详情失败 (${e.statusCode})');
    } catch (e) {
      if (e is SocketException || e is IOException) {
        debugPrint('[ERROR] ❌ PB连接异常 - getGameById: $e');
        throw Exception('无法连接服务器，请检查网络连接');
      }
      debugPrint('[ERROR] ❌ PB未知错误 - getGameById: $e');
      throw Exception('获取游戏详情时发生未知错误');
    }
  }

  /// 获取游戏总数 (仅请求 totalItems, 不传输实际数据)
  ///
  /// 用于探索页加载完成即显示总数, 避免用户滚动后才看到准确数量。
  /// 失败时返回 -1, UI 层应将 -1 显示为"加载中..."或省略数字。
  static Future<int> getGameCount({String searchQuery = ''}) async {
    debugPrint('[PB] 开始获取游戏总数');
    if (searchQuery.isNotEmpty) {
      debugPrint('[PB]   搜索过滤: "$searchQuery"');
    }

    try {
      // ★ P1-1：与 getGameList 保持一致，走统一的多字段名称搜索
      final filter = PbFilter.nameSearchFilter(searchQuery);

      final result = await PBConfig.pb.collection('games').getList(
            page: 1,
            perPage: 1,
            sort: '-created',
            filter: filter,
            expand: '',
          );

      final total = result.totalItems;
      debugPrint('[PB] ✅ 游戏总数获取成功: $total');
      return total;
    } on ClientException catch (e) {
      if (_isNetworkError(e)) {
        debugPrint('[ERROR] ❌ PB网络异常 - getGameCount: ${e.toString()}');
        return -1;
      }
      debugPrint(
          '[ERROR] ❌ PB请求失败 (${e.statusCode}) - getGameCount: ${e.toString()}');
      return -1;
    } catch (e) {
      if (e is SocketException || e is IOException) {
        debugPrint('[ERROR] ❌ PB连接异常 - getGameCount: $e');
        return -1;
      }
      debugPrint('[ERROR] ❌ PB未知错误 - getGameCount: $e');
      return -1;
    }
  }

  // ==================== 元数据回传云端（v2.1.17）====================

  /// 是否具备回写条件（云端要求登录用户才能改记录）
  static bool get canUploadMetadata => PBConfig.isLoggedIn;

  /// 构造回传 body（纯函数，便于单测）
  ///
  /// 只写有效值：0 / 空串一律不写，避免用空值覆盖云端已有数据
  /// （PB number 字段默认值就是 0，「无数据」与「0 分」不可混淆）。
  static Map<String, dynamic> buildMetadataBody({
    double? rating,
    int? voteCount,
    String? releaseDate,
    String? metaSource,
    int? estimatedMinutes,
  }) {
    final body = <String, dynamic>{};
    if (rating != null && rating > 0) body['rating'] = rating;
    if (voteCount != null && voteCount > 0) body['voteCount'] = voteCount;
    final trimmedDate = releaseDate?.trim() ?? '';
    if (trimmedDate.isNotEmpty) body['releaseDate'] = trimmedDate;
    final trimmedSource = metaSource?.trim() ?? '';
    if (trimmedSource.isNotEmpty) body['metaSource'] = trimmedSource;
    if (estimatedMinutes != null && estimatedMinutes > 0) {
      body['estimatedMinutes'] = estimatedMinutes;
    }
    return body;
  }

  /// 把抓取到的元数据回写到云端 games 记录，供全部用户复用
  ///
  /// 机制与详情页截图回传（`_uploadScreenshotsToPB`）一致：
  /// 云端无该数据 → 本地抓取 → 后台回写；失败静默，不阻塞 UI、不影响展示。
  ///
  /// 字段需在 PB 后台 games 集合中预先建立：
  /// `rating`(number) / `voteCount`(number) / `releaseDate`(text) /
  /// `metaSource`(text) / `estimatedMinutes`(number，多用户平均游玩时长分钟)。
  static Future<GameMetadataUploadStatus> updateGameMetadata(
    String gameId, {
    double? rating,
    int? voteCount,
    String? releaseDate,
    String? metaSource,
    int? estimatedMinutes,
  }) async {
    final body = buildMetadataBody(
      rating: rating,
      voteCount: voteCount,
      releaseDate: releaseDate,
      metaSource: metaSource,
      estimatedMinutes: estimatedMinutes,
    );
    if (body.isEmpty) return GameMetadataUploadStatus.empty;
    if (!canUploadMetadata) {
      debugPrint('[PB] ⏭️ 未登录，跳过元数据回传 (gameId=$gameId)');
      return GameMetadataUploadStatus.unauthenticated;
    }

    try {
      await PBConfig.pb.collection('games').update(gameId, body: body);
      debugPrint('[PB] ✅ 元数据回传成功 (gameId=$gameId, ${body.keys.join('/')})');
      return GameMetadataUploadStatus.ok;
    } on ClientException catch (e) {
      final code = e.statusCode;
      // 400/403/404 属服务端结构性问题（字段缺失/规则收紧），
      // 重试无意义，交由调用方熔断本次运行。
      if (code == 400 || code == 403 || code == 404) {
        debugPrint(
            '[PB] ⚠️ 元数据回传被拒 (HTTP $code, gameId=$gameId)：'
            '请确认 games 集合已建 rating/voteCount/releaseDate/metaSource/'
            'estimatedMinutes 字段且当前角色有改权限');
        return GameMetadataUploadStatus.rejected;
      }
      debugPrint('[PB] ⚠️ 元数据回传失败 (HTTP $code, gameId=$gameId)');
      return GameMetadataUploadStatus.failed;
    } catch (e) {
      debugPrint('[PB] ⚠️ 元数据回传异常 (gameId=$gameId): $e');
      return GameMetadataUploadStatus.failed;
    }
  }

  static bool _isNetworkError(ClientException e) {
    final originalError = e.originalError;
    if (originalError is SocketException) return true;
    if (originalError is IOException) return true;
    final msg = e.toString().toLowerCase();
    return msg.contains('connection') ||
        msg.contains('timeout') ||
        msg.contains('socket') ||
        msg.contains('failed to connect');
  }
}
