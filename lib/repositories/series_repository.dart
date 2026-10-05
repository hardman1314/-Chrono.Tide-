import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../core/pb_config.dart';
import '../models/series_model.dart';

/// 系列数据仓库：从 PocketBase 读取系列树
///
/// 双数据源（v2 优先，旧表兜底，零破坏过渡）：
/// - v2：series_meta / series_members / series_relations 三表
///   （地位与关系分离；仅消费 status=confirmed 的已发布数据）
/// - v1：series / series_entries 旧表（parent 树）
///
/// 能力探测：启动后首次访问探测 series_meta 是否存在（结果缓存），
/// 存在则 v2 优先；v2 无数据（草稿/未发布）自动回退旧表 ——
/// 每个系列发布后才替换旧表展示，过渡期玩家无感。
///
/// 查询流程（两步）：
/// 1. series_members?filter=game="{gameId}" → 所属系列
/// 2. series_members/series_relations?filter=series="{seriesId}"&expand=game
///    —— 拉全量成员与关系边，内存构建主轴/分支树
///
/// 失败静默返回 null（详情页系列区隐藏），不打断主流程。
class SeriesRepository {
  SeriesRepository._();

  static const int _perPage = 100;
  static const Duration _cacheTtl = Duration(minutes: 10);

  /// seriesId → 缓存条目（系列数据变更频率极低，10 分钟 TTL 足够）
  static final Map<String, _CacheEntry> _cache = {};

  /// gameId → 确认无系列的时间（负缓存，TTL 内不再查询）
  static final Map<String, DateTime> _noSeriesCache = {};

  // ---------------------------------------------------------- v2 能力探测

  /// null = 未探测；探测结果整个会话缓存（服务端中途加表需重启应用）
  static bool? _v2Available;

  /// 探测 series_meta 是否可匿名访问（存在即 v2 数据源可用）
  static Future<bool> _probeV2() async {
    final known = _v2Available;
    if (known != null) return known;
    try {
      await PBConfig.pb.collection('series_meta').getList(
            page: 1,
            perPage: 1,
          );
      _v2Available = true;
      debugPrint('[Series] ✅ v2 数据源可用（series_meta 探测通过）');
    } catch (e) {
      _v2Available = false;
      debugPrint('[Series] v2 不可用，回退旧表: $e');
    }
    return _v2Available!;
  }

  // ---------------------------------------------------------- 主入口

  /// 获取游戏所属系列（含完整树）
  ///
  /// 返回 null 表示：无系列 / 系列数据不完整（有效作品 < 2）/ 加载失败。
  static Future<SeriesData?> getSeriesForGame(String gameId) async {
    // 负缓存：30 秒内已确认无系列的游戏不再请求
    final noSeriesAt = _noSeriesCache[gameId];
    if (noSeriesAt != null &&
        DateTime.now().difference(noSeriesAt) < const Duration(seconds: 30)) {
      return null;
    }

    // v2 优先；v2 未命中（无成员/全部草稿）回退旧表
    if (await _probeV2()) {
      final v2 = await _getSeriesForGameV2(gameId);
      if (v2 != null) return v2;
    }
    return _getSeriesForGameLegacy(gameId);
  }

  // ---------------------------------------------------------- v2 数据源

  /// v2：查游戏所属系列（(series,game) 唯一，但同一游戏可属多个系列，
  /// 逐个尝试直到命中已发布系列）
  static Future<SeriesData?> _getSeriesForGameV2(String gameId) async {
    try {
      final lookup = await PBConfig.pb.collection('series_members').getList(
            page: 1,
            perPage: 10,
            filter: 'game = "$gameId"',
          );
      if (lookup.items.isEmpty) {
        debugPrint('[Series] 游戏 $gameId 不属于任何 v2 系列');
        return null;
      }
      for (final item in lookup.items) {
        final seriesId = _pbString(item, 'series');
        if (seriesId.isEmpty) continue;
        final data = await getSeriesDataById(seriesId);
        if (data != null) return data; // 草稿/删除的系列返回 null，试下一个
      }
      return null;
    } catch (e) {
      debugPrint('[Series] ❌ v2 成员查询失败: $e');
      return null;
    }
  }

  /// v2：拉取完整系列数据（meta + members + relations → 树）。
  ///
  /// 返回 null：系列不存在 / 未发布（draft）/ 有效作品 < 2 / 加载失败。
  static Future<SeriesData?> _loadV2Series(String seriesId) async {
    final metaRecord =
        await PBConfig.pb.collection('series_meta').getOne(seriesId);
    // 只消费已发布数据（草稿对玩家不可见）
    if (_pbString(metaRecord, 'status') != 'confirmed') {
      debugPrint('[Series] v2 系列 $seriesId 未发布（draft），跳过');
      return null;
    }

    final memberRecords = await _fetchAllV2(
      'series_members',
      'series = "$seriesId"',
      expand: 'game',
      sort: 'playOrder',
    );
    final relationRecords = await _fetchAllV2(
      'series_relations',
      'series = "$seriesId"',
    );

    return v2RecordsToSeriesData(
      SeriesModel.fromV2Record(metaRecord),
      memberRecords,
      relationRecords,
    );
  }

  /// v2 成员/关系记录 → 系列树（纯函数，无网络）。
  ///
  /// 虚构 parent 链以复用 [SeriesData.build] 的树构建与防御逻辑：
  /// - 主轴（role=main_axis）按 playOrder 升序串链：第 1 部 = 根（main），
  ///   之后每部 parent = 前一部（sequel）
  /// - 分支/收录：沿 series_relations 边（toGame→fromGame）上溯锚定主轴成员，
  ///   角标取边 relation；上溯不到挂到主轴首部
  /// - anthology（平铺模式）由 series.mode 保证走 build 的合集分支
  @visibleForTesting
  static SeriesData? v2RecordsToSeriesData(
    SeriesModel series,
    List<dynamic> memberRecords,
    List<dynamic> relationRecords,
  ) {
    // 成员 → 展示模型（game 悬空的过滤，与旧表同口径）
    final mains = <dynamic>[];
    final branches = <dynamic>[];
    for (final record in memberRecords) {
      final gameRecord = _expandGame(record);
      if (gameRecord == null) continue;
      if (_pbString(record, 'role') == 'main_axis') {
        mains.add(record);
      } else {
        branches.add(record);
      }
    }
    // 主轴按 playOrder 升序（负数视为前置）
    mains.sort(
        (a, b) => _pbInt(a, 'playOrder').compareTo(_pbInt(b, 'playOrder')));

    // 关系边：toGame → (fromGame, relation)，同终点首条优先
    final anchorGameOf = <String, String>{};
    final edgeRelOf = <String, String>{};
    for (final r in relationRecords) {
      final from = _pbString(r, 'fromGame');
      final to = _pbString(r, 'toGame');
      if (from.isEmpty || to.isEmpty || from == to) continue;
      anchorGameOf.putIfAbsent(to, () => from);
      edgeRelOf.putIfAbsent(to, () => _pbString(r, 'relation'));
    }

    // 构建条目（虚构 parent 链）：
    // 主轴第 1 部 = 根（main），之后每部 parent = 前一部（sequel）
    final entries = <SeriesEntryModel>[];
    final entryIdByGame = <String, String>{}; // gameId → 主轴条目 id
    String? prevId;
    for (final record in mains) {
      final gameRecord = _expandGame(record);
      entries.add(SeriesEntryModel.fromV2Record(
        record,
        gameRecord,
        parentId: prevId,
        relationType: prevId == null
            ? SeriesRelationType.main
            : SeriesRelationType.sequel,
        playOrder: _pbInt(record, 'playOrder'),
        v2Role: _pbString(record, 'role'),
        releaseDate: _firstNonEmpty(
            _pbString(record, 'releaseDate'),
            _pbString(gameRecord, 'releaseDate')),
      ));
      entryIdByGame[gameRecord.id] = record.id;
      prevId = record.id;
    }

    // 分支/收录：沿关系边锚点上溯到主轴成员；上溯不到挂到主轴首部
    final rootEntryId = mains.isNotEmpty ? mains.first.id : null;
    for (final record in branches) {
      final gameRecord = _expandGame(record);
      final gameId = gameRecord.id;
      final anchor = _resolveMainEntryId(gameId, entryIdByGame, anchorGameOf) ??
          rootEntryId;
      final edgeRel = edgeRelOf[gameId];
      entries.add(SeriesEntryModel.fromV2Record(
        record,
        gameRecord,
        parentId: anchor,
        relationType: edgeRel == null
            ? SeriesRelationType.other
            : SeriesRelationType.fromV2(edgeRel),
        playOrder: 0,
        v2Role: _pbString(record, 'role'),
        v2Relation: edgeRel ?? '',
        releaseDate: _firstNonEmpty(
            _pbString(record, 'releaseDate'),
            _pbString(gameRecord, 'releaseDate')),
      ));
    }

    // 有效作品不足 2 部：无展示价值（与旧表同口径）
    if (entries.length < 2) {
      debugPrint('[Series] v2 系列有效作品仅 ${entries.length} 部，不展示');
      return null;
    }

    return SeriesData.build(series, entries);
  }

  /// 安全取 expand.game（key 缺失或空列表都返回 null；
  /// `?.first` 对空列表仍会取 first 抛 StateError，不能直接用）
  static dynamic _expandGame(dynamic record) {
    try {
      final list = record.expand['game'];
      if (list == null || list.isEmpty) return null;
      return list.first;
    } catch (_) {
      return null;
    }
  }

  /// 返回第一个非空字符串（都空返回 ''）；发售日期 member 优先回落 game 用
  static String _firstNonEmpty(String a, String b) => a.isNotEmpty ? a : b;

  /// 沿关系边锚点上溯，找到分支所属的主轴条目 id（防环）。
  /// 返回 null = 上溯不到任何主轴成员（交给调用方兜底）。
  static String? _resolveMainEntryId(
    String gameId,
    Map<String, String> entryIdByGame,
    Map<String, String> anchorGameOf,
  ) {
    var current = gameId;
    final seen = <String>{};
    while (!seen.contains(current)) {
      seen.add(current);
      final direct = entryIdByGame[current];
      if (direct != null) return direct;
      final next = anchorGameOf[current];
      if (next == null || next.isEmpty) return null;
      current = next;
    }
    return null; // 环
  }

  /// v2 集合通用分页拉取
  static Future<List<dynamic>> _fetchAllV2(
    String collection,
    String filter, {
    String? expand,
    String? sort,
  }) async {
    final records = <dynamic>[];
    var page = 1;
    while (page <= 10) {
      final result = await PBConfig.pb.collection(collection).getList(
            page: page,
            perPage: _perPage,
            filter: filter,
            expand: expand,
            sort: sort,
          );
      records.addAll(result.items);
      if (records.length >= result.totalItems) break;
      page++;
    }
    return records;
  }

  // ---------------------------------------------------------- 旧表数据源（v1）

  /// 旧表：查游戏所属系列（game 字段 UNIQUE，0 或 1 条）
  static Future<SeriesData?> _getSeriesForGameLegacy(String gameId) async {
    try {
      // 第一步：查该游戏的系列条目
      final lookup = await PBConfig.pb.collection('series_entries').getList(
            page: 1,
            perPage: 1,
            filter: 'game = "$gameId"',
            expand: 'series',
          );
      if (lookup.items.isEmpty) {
        debugPrint('[Series] 游戏 $gameId 不属于任何系列');
        _noSeriesCache[gameId] = DateTime.now();
        return null;
      }

      final lookupRecord = lookup.items.first;
      final seriesRecord = lookupRecord.expand['series']?.first;
      final seriesId =
          seriesRecord?.id ?? lookupRecord.getStringValue('series');
      if (seriesId.isEmpty) {
        debugPrint('[Series] ⚠️ 条目 ${lookupRecord.id} 缺少系列信息');
        return null;
      }

      // 第二步：命中缓存直接返回
      final cached = _cache[seriesId];
      if (cached != null && !cached.isExpired) {
        debugPrint('[Series] ✅ 命中缓存: ${cached.data.series.title}');
        return cached.data;
      }

      // 第三步：拉取系列元数据（expand 缺失时兜底单独请求）
      final SeriesModel series;
      if (seriesRecord != null) {
        series = SeriesModel.fromPBRecord(seriesRecord);
      } else {
        series =
            SeriesModel.fromPBRecord(await _fetchSeriesRecord(seriesId));
      }

      // 第四步：拉全量条目（分页保险，系列通常 < 20 条）
      final records = await _fetchAllEntries(seriesId);
      final entries = <SeriesEntryModel>[];
      for (final record in records) {
        final gameRecord = record.expand['game']?.first;
        if (gameRecord == null) {
          // game 关系悬空（游戏被删）→ 过滤该条目
          debugPrint('[Series] ⚠️ 条目 ${record.id} 的 game 关系悬空，已过滤');
          continue;
        }
        entries.add(SeriesEntryModel.fromPBRecord(record, gameRecord));
      }

      // 有效作品不足 2 部：无展示价值，按无系列处理
      if (entries.length < 2) {
        debugPrint(
            '[Series] 系列 "$seriesId" 有效作品仅 ${entries.length} 部，不展示');
        _noSeriesCache[gameId] = DateTime.now();
        return null;
      }

      final data = SeriesData.build(series, entries);
      _cache[seriesId] = _CacheEntry(data, DateTime.now());
      debugPrint('[Series] ✅ 系列加载成功: ${series.title} '
          '(${entries.length} 部作品)');
      return data;
    } catch (e) {
      // 静默失败：详情页系列区隐藏，不影响主流程
      debugPrint('[Series] ❌ 加载系列数据失败: $e');
      return null;
    }
  }

  static Future<dynamic> _fetchSeriesRecord(String seriesId) async {
    return PBConfig.pb.collection('series').getOne(seriesId);
  }

  /// 探索大厅系列合集板块：整表分页拉取全部系列元数据（不含条目）。
  ///
  /// v2 可用且有已发布系列 → 返回 v2 列表；否则回退旧表。
  /// 失败静默返回空表（大厅板块显示空态，不打断页面）。
  static Future<List<SeriesModel>> fetchAllSeries() async {
    try {
      if (await _probeV2()) {
        final v2 = await _fetchAllSeriesV2();
        if (v2.isNotEmpty) {
          debugPrint('[Series] ✅ v2 已发布系列 ${v2.length} 个');
          return v2;
        }
        debugPrint('[Series] v2 暂无已发布系列，回退旧表列表');
      }
      return _fetchAllSeriesLegacy();
    } catch (e) {
      debugPrint('[Series] ❌ 整表拉取系列失败: $e');
      return const [];
    }
  }

  /// v2：整表拉取已发布系列元数据
  static Future<List<SeriesModel>> _fetchAllSeriesV2() async {
    final result = <SeriesModel>[];
    var page = 1;
    while (page <= 50) {
      final res = await PBConfig.pb.collection('series_meta').getList(
            page: page,
            perPage: _perPage,
            filter: 'status = "confirmed"',
          );
      result
          .addAll(res.items.map((r) => SeriesModel.fromV2Record(r)).toList());
      if (result.length >= res.totalItems) break;
      page++;
    }
    return result;
  }

  /// 旧表：整表拉取全部系列元数据
  static Future<List<SeriesModel>> _fetchAllSeriesLegacy() async {
    final result = <SeriesModel>[];
    var page = 1;
    // 分页保险：与 _fetchAllEntries 同款上限防御
    while (page <= 50) {
      final res = await PBConfig.pb
          .collection('series')
          .getList(page: page, perPage: _perPage);
      result.addAll(
          res.items.map((r) => SeriesModel.fromPBRecord(r)).toList());
      if (result.length >= res.totalItems) break;
      page++;
    }
    debugPrint('[Series] ✅ 整表拉取系列 ${result.length} 个');
    return result;
  }

  /// 按 seriesId 获取完整系列数据（探索大厅成员弹层用）。
  ///
  /// v2 优先（草稿/不存在自动回退旧表）；共用缓存与构建逻辑；失败静默返回 null。
  static Future<SeriesData?> getSeriesDataById(String seriesId) async {
    final cached = _cache[seriesId];
    if (cached != null && !cached.isExpired) return cached.data;
    if (await _probeV2()) {
      try {
        final data = await _loadV2Series(seriesId);
        if (data != null) {
          _cache[seriesId] = _CacheEntry(data, DateTime.now());
          debugPrint('[Series] ✅ v2 系列加载成功: ${data.series.title}');
          return data;
        }
      } catch (e) {
        debugPrint('[Series] v2 加载失败，回退旧表: $e');
      }
    }
    try {
      final seriesRecord = await _fetchSeriesRecord(seriesId);
      final records = await _fetchAllEntries(seriesId);
      final entries = <SeriesEntryModel>[];
      for (final record in records) {
        final gameRecord = record.expand['game']?.first;
        if (gameRecord == null) continue; // game 关系悬空 → 过滤
        entries.add(SeriesEntryModel.fromPBRecord(record, gameRecord));
      }
      // 有效作品不足 2 部：无展示价值（与 getSeriesForGame 同一口径）
      if (entries.length < 2) return null;
      final data = SeriesData.build(
          SeriesModel.fromPBRecord(seriesRecord), entries);
      _cache[seriesId] = _CacheEntry(data, DateTime.now());
      return data;
    } catch (e) {
      debugPrint('[Series] ❌ 按 ID 加载系列数据失败: $e');
      return null;
    }
  }

  /// 拉取某系列的全部条目记录（带 game expand，按 sortOrder 排序）
  static Future<List<dynamic>> _fetchAllEntries(String seriesId) async {
    final records = <dynamic>[];
    var page = 1;
    // 分页保险：正常一两页拉完；上限防御异常超大系列
    while (page <= 10) {
      final result = await PBConfig.pb.collection('series_entries').getList(
            page: page,
            perPage: _perPage,
            filter: 'series = "$seriesId"',
            expand: 'game',
            sort: 'sortOrder',
          );
      records.addAll(result.items);
      if (records.length >= result.totalItems) break;
      page++;
    }
    return records;
  }

  // ---------------------------------------------------------- PB record 安全读取

  static String _pbString(dynamic record, String field) {
    try {
      return record.getStringValue(field);
    } catch (_) {
      return '';
    }
  }

  static int _pbInt(dynamic record, String field) {
    try {
      final value = record.data[field];
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value) ?? 0;
      return 0;
    } catch (_) {
      return 0;
    }
  }
}

class _CacheEntry {
  final SeriesData data;
  final DateTime cachedAt;

  const _CacheEntry(this.data, this.cachedAt);

  bool get isExpired =>
      DateTime.now().difference(cachedAt) > SeriesRepository._cacheTtl;
}
