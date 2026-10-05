import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:pocketbase/pocketbase.dart';

import '../core/pb_config.dart';
import '../models/game_model.dart';
import '../models/game_resource_model.dart';

/// 资源获取层：读写 PocketBase 集合 `game_resources`（`pbc_439050043`）。
///
/// 可见性由服务端规则决定（本层不重复过滤，只按语义组织查询）：
/// ```
/// listRule = kind = "official"
///         || (kind = "community" && status = "published")
///         || owner = @request.auth.id
/// createRule = @request.auth.id != "" && kind = "community"
///           && owner = @request.auth.id && status = "pending"
/// updateRule = owner = @request.auth.id && kind = "community" && status != "published"
/// ```
///
/// ⚠️ 计数类字段（`download_count` / `like_count` / `report_count`）被服务端
/// `lock_fields.pb.js` 锁定，客户端 **不能** 直接 PATCH 修改，只能经
/// `/api/ct/resource-stats/...` 自定义路由由服务端累加。
class GameResourceService {
  const GameResourceService._();

  static const String _collection = 'game_resources';
  static const int _defaultPerPage = 100;

  // ==================== 读取 ====================

  /// 拉取某作品下**当前登录用户可见的全部资源**
  ///
  /// 含：官方来源 + 已发布的用户分享 + 自己待审核的投稿。
  /// 未登录时自动去掉 `owner` 分支（服务端规则本也会拦，这里减少无效请求）。
  static Future<List<GameResourceModel>> fetchVisibleForGame(
    String gameId,
  ) async {
    if (gameId.isEmpty) return const [];
    final uid = _currentUserId;

    final parts = <String>[
      "kind='official'",
      "kind='community' && status='published'",
    ];
    if (uid.isNotEmpty) {
      parts.add("owner='$uid'");
    }
    final filter = "game='$gameId' && (${parts.join(' || ')})";
    return _query(filter, sort: 'kind,-created');
  }

  /// 仅官方来源（Chrono Tide 下载栏用），可安装的那一份排在前面
  static Future<List<GameResourceModel>> fetchOfficial(String gameId) {
    if (gameId.isEmpty) return Future.value(const []);
    return _query("game='$gameId' && kind='official'", sort: '-created');
  }

  /// 仅已发布的用户分享（资源分享栏用）
  static Future<List<GameResourceModel>> fetchCommunity(String gameId) {
    if (gameId.isEmpty) return Future.value(const []);
    return _query("game='$gameId' && kind='community' && status='published'",
        sort: '-created');
  }

  /// 仅本人投稿（含待审核 / 已驳回，供「我的投稿」展示）
  static Future<List<GameResourceModel>> fetchMine(String gameId) async {
    final uid = _currentUserId;
    if (gameId.isEmpty || uid.isEmpty) return const [];
    return _query("game='$gameId' && owner='$uid'", sort: '-created');
  }

  /// 某作品的「用户分享」数量（列表卡片角标用，只取 totalItems，不传数据）
  ///
  /// 失败返回 0（角标缺失优于报错）。
  static Future<int> communityCount(String gameId) async {
    if (gameId.isEmpty) return 0;
    try {
      final r = await PBConfig.pb.collection(_collection).getList(
            page: 1,
            perPage: 1,
            filter: "game='$gameId' && kind='community' && status='published'",
            fields: 'id',
          );
      return r.totalItems;
    } catch (e) {
      debugPrint('[RES] ⚠️ communityCount 失败 (game=$gameId): $e');
      return 0;
    }
  }

  /// 批量查询多个作品的用户分享数量，用于列表页一次性铺角标
  ///
  /// 返回 `{gameId: count}`；未出现在结果里的 gameId 视为 0。
  static Future<Map<String, int>> communityCountBatch(
    List<String> gameIds,
  ) async {
    final result = <String, int>{};
    if (gameIds.isEmpty) return result;

    // PB filter 单表达式长度有限，分批查询（每批 30 个 id）
    const batchSize = 30;
    for (var i = 0; i < gameIds.length; i += batchSize) {
      final batch = gameIds.skip(i).take(batchSize).toList();
      final idClause = batch.map((id) => "game='$id'").join(' || ');
      try {
        final r = await PBConfig.pb.collection(_collection).getList(
              page: 1,
              perPage: 500,
              filter: "($idClause) && kind='community' && status='published'",
              fields: 'id,game',
            );
        for (final item in r.items) {
          final gid = item.getStringValue('game');
          if (gid.isNotEmpty) result[gid] = (result[gid] ?? 0) + 1;
        }
      } catch (e) {
        debugPrint('[RES] ⚠️ communityCountBatch 第${i ~/ batchSize}批失败: $e');
      }
    }
    return result;
  }

  // ==================== 写入 ====================

  /// 提交一条用户分享资源（`kind=community` / `status=pending` / `owner=自己`）
  ///
  /// 这三个受控字段由服务端规则强制校验，若客户端漏传会被 400 拒。
  /// 返回创建成功的记录；失败抛出带中文说明的异常，由调用方提示。
  static Future<GameResourceModel> createCommunityResource({
    required String gameId,
    required String url,
    required String title,
    required String fileSize,
    String? version,
    ResourceLinkType? linkType,
    String? netdiskProvider,
    String? extractCode,
    String? unzipCode,
    String? note,
    List<String> resourceTypes = const [],
    List<String> languages = const [],
    List<String> platforms = const [],
  }) async {
    final uid = _currentUserId;
    if (uid.isEmpty) {
      throw Exception('请先登录后再发布资源');
    }
    if (url.trim().isEmpty) {
      throw Exception('资源链接不能为空');
    }
    if (title.trim().isEmpty) {
      throw Exception('资源标题不能为空');
    }

    final body = <String, dynamic>{
      // 受控字段：必须与 createRule 完全一致
      'game': gameId,
      'kind': 'community',
      'owner': uid,
      'status': 'pending',
      // 业务字段
      'title': title.trim(),
      'url': url.trim(),
      'file_size': fileSize.trim(),
    };
    if (version != null && version.trim().isNotEmpty) {
      body['version'] = version.trim();
    }
    if (linkType != null) body['link_type'] = linkType.wire;
    if (netdiskProvider != null && netdiskProvider.isNotEmpty) {
      body['netdisk_provider'] = netdiskProvider;
    }
    if (extractCode != null && extractCode.trim().isNotEmpty) {
      body['extract_code'] = extractCode.trim();
    }
    if (unzipCode != null && unzipCode.trim().isNotEmpty) {
      body['unzip_code'] = unzipCode.trim();
    }
    if (note != null && note.trim().isNotEmpty) {
      body['note'] = note.trim();
    }
    if (resourceTypes.isNotEmpty) body['resource_type'] = resourceTypes;
    if (languages.isNotEmpty) body['languages'] = languages;
    if (platforms.isNotEmpty) body['platforms'] = platforms;

    // 署名快照（发布时定格；服务端 hook 也会对空值兜底回填）
    final ownerName = _currentUserField('name');
    final ownerAvatar = _currentUserField('avatar');
    if (ownerName.isNotEmpty) body['owner_name'] = ownerName;
    if (ownerAvatar.isNotEmpty) body['owner_avatar'] = ownerAvatar;

    try {
      final record =
          await PBConfig.pb.collection(_collection).create(body: body);
      debugPrint('[RES] ✅ 资源已提交待审: id=${record.id}');
      return GameResourceModel.fromPBRecord(record);
    } on ClientException catch (e) {
      debugPrint('[RES] ❌ 资源提交失败 HTTP ${e.statusCode}: ${e.response}');
      throw Exception(_translateSubmitError(e));
    } catch (e) {
      debugPrint('[RES] ❌ 资源提交异常: $e');
      throw Exception('发布失败，请检查网络后重试');
    }
  }

  // ==================== 我的（跨作品，供【我的】管理页）====================

  /// 拉取当前用户的**全部投稿**（跨作品），按提交时间倒序。
  ///
  /// `expand: 'game'` 用于带出作品名——`game_resources.game` 是 relation(maxSelect:1)，
  /// 不 expand 时只有一个 id，列表无法展示「《XX》」。
  /// ⚠️ PB 的 expand 需要 `games` 的 **View** 规则放行该记录；现规则为
  /// `@request.auth.id != "" || review_status = "approved"`，本页要求登录 ⇒ 恒满足。
  /// 万一取不到（老数据 / 规则收紧），`gameTitle` 留空、UI 回退显示短 id，**不报错**。
  ///
  /// 未登录返回空列表。失败抛出带中文说明的异常（【我的】页需要明确报错）。
  static Future<List<GameResourceModel>> fetchAllMine({
    int perPage = 200,
  }) async {
    final uid = _currentUserId;
    if (uid.isEmpty) return const [];
    return _query(
      "owner='$uid'",
      sort: '-created',
      perPage: perPage,
      expand: 'game',
    );
  }

  /// 编辑一条自己的投稿。
  ///
  /// 只发送 [GameResourceModel.toSubmitBody] 产出的字段——它**刻意排除**
  /// `kind` / `status` / `owner` / 三个计数字段（都被 `lock_fields.pb.js` 锁定，
  /// 传了也会被静默还原）。
  ///
  /// [resubmit] 语义（统一审核机制后）：编辑完成时**一并重新提交审核**。
  /// 服务端 `lock_fields` v6 白名单放行 owner 本人的 `rejected→pending` 与
  /// `editing→pending` 两种转换；`pending` 记录本就在队列中，传 false 即可。
  static Future<GameResourceModel> updateMine(
    String resourceId,
    GameResourceModel model, {
    bool resubmit = false,
  }) async {
    if (_currentUserId.isEmpty) {
      throw Exception('请先登录后再编辑资源');
    }
    if (model.title.trim().isEmpty || model.url.trim().isEmpty) {
      throw Exception('资源标题与链接不能为空');
    }
    final body = model.toSubmitBody();
    if (resubmit) {
      // 重新提交：置回「待审」，让管理员重新看到这条投稿。
      // 服务端白名单放行 rejected→pending / editing→pending（owner 本人）。
      // ⚠️ `toSubmitBody()` 本身不含 status，必须在这里显式补上。
      body['status'] = 'pending';
    }
    try {
      final record = await PBConfig.pb
          .collection(_collection)
          .update(resourceId, body: body);
      debugPrint('[RES] ✅ 资源已更新: id=$resourceId');
      return GameResourceModel.fromPBRecord(record);
    } on ClientException catch (e) {
      debugPrint('[RES] ❌ 资源更新失败 HTTP ${e.statusCode}: ${e.response}');
      throw Exception(_translateMineError(e, action: '保存'));
    } catch (e) {
      debugPrint('[RES] ❌ 资源更新异常: $e');
      throw Exception('保存失败，请检查网络后重试');
    }
  }

  /// 发起编辑：已发布投稿下架暂存（`published → editing`）。
  ///
  /// 统一审核机制：下架期间数据与统计全部保留；此后 [updateMine] 直接可改
  /// 字段（`editing` 态不在 updateRule 排除列表内），提交时带
  /// `resubmit: true` 回到审核队列。仅 `published` 记录可调用。
  static Future<void> startEditing(String resourceId) async {
    if (_currentUserId.isEmpty) {
      throw Exception('请先登录后再编辑资源');
    }
    try {
      await PBConfig.pb
          .collection(_collection)
          .update(resourceId, body: {'status': 'editing'});
      debugPrint('[RES] ✅ 资源已转入编辑态（下架暂存）: id=$resourceId');
    } on ClientException catch (e) {
      debugPrint('[RES] ❌ 发起编辑失败 HTTP ${e.statusCode}');
      throw Exception(_translateMineError(e, action: '发起编辑'));
    } catch (e) {
      debugPrint('[RES] ❌ 发起编辑异常: $e');
      throw Exception('发起编辑失败，请检查网络后重试');
    }
  }

  /// 申请删除：已进库投稿下架等管理员裁决（`published → pending_delete`）。
  ///
  /// 管理员通过 = 后台直接删除记录；拒绝 = 状态改回 `published`。
  /// 审核期间作者可随时 [withdrawDelete] 撤回，数据零丢失。
  static Future<void> requestDelete(String resourceId) async {
    if (_currentUserId.isEmpty) {
      throw Exception('请先登录后再删除资源');
    }
    try {
      await PBConfig.pb
          .collection(_collection)
          .update(resourceId, body: {'status': 'pending_delete'});
      debugPrint('[RES] ✅ 删除申请已提交: id=$resourceId');
    } on ClientException catch (e) {
      debugPrint('[RES] ❌ 申请删除失败 HTTP ${e.statusCode}');
      throw Exception(_translateMineError(e, action: '申请删除'));
    } catch (e) {
      debugPrint('[RES] ❌ 申请删除异常: $e');
      throw Exception('申请删除失败，请检查网络后重试');
    }
  }

  /// 撤回删除申请（`pending_delete → published`）：恢复审核过的原内容，
  /// 数据与统计零丢失。
  static Future<void> withdrawDelete(String resourceId) async {
    if (_currentUserId.isEmpty) {
      throw Exception('请先登录后再操作');
    }
    try {
      await PBConfig.pb
          .collection(_collection)
          .update(resourceId, body: {'status': 'published'});
      debugPrint('[RES] ✅ 已撤回删除申请: id=$resourceId');
    } on ClientException catch (e) {
      debugPrint('[RES] ❌ 撤回删除失败 HTTP ${e.statusCode}');
      throw Exception(_translateMineError(e, action: '撤回删除申请'));
    } catch (e) {
      debugPrint('[RES] ❌ 撤回删除异常: $e');
      throw Exception('撤回失败，请检查网络后重试');
    }
  }

  /// 删除一条自己的投稿。
  ///
  /// 统一审核机制后 `deleteRule` 追加
  /// `status != "published" && status != "pending_delete"` ⇒ **已进库内容
  /// 不能直接删**（服务端 404），请走 [requestDelete] 申请删除；
  /// 本方法仅适用未进库状态（pending / rejected / editing / hidden）。
  static Future<void> deleteMine(String resourceId) async {
    if (_currentUserId.isEmpty) {
      throw Exception('请先登录后再删除资源');
    }
    try {
      await PBConfig.pb.collection(_collection).delete(resourceId);
      debugPrint('[RES] ✅ 资源已删除: id=$resourceId');
    } on ClientException catch (e) {
      debugPrint('[RES] ❌ 资源删除失败 HTTP ${e.statusCode}');
      throw Exception(_translateMineError(e, action: '删除'));
    } catch (e) {
      debugPrint('[RES] ❌ 资源删除异常: $e');
      throw Exception('删除失败，请检查网络后重试');
    }
  }

  static String _translateMineError(ClientException e, {required String action}) {
    if (_isNetworkError(e)) return '网络连接失败，请检查网络后重试';
    switch (e.statusCode) {
      case 400:
        return '$action被拒绝：请确认资源标题与链接已填写';
      case 401:
      case 403:
        return '登录状态已失效，请重新登录后再试';
      case 404:
        // 规则不满足时 PB 返回 404 而非 403
        return '该资源已发布或不属于你，无法$action';
      default:
        return '$action失败 (${e.statusCode})，请稍后重试';
    }
  }

  // ==================== 计数（服务端累加）====================

  /// 登记一次下载：调 `/api/ct/resource-stats/download?id=<id>`
  ///
  /// 计数字段被 Hook 锁定，客户端只能走自定义路由。
  /// **路由未部署时静默返回 false**，不抛异常——UI 不应因统计失败而中断下载。
  /// 🔴 v5 起路由为**无路径参数**形态（id 走 query）——服务端 goja 桥接的
  /// `e.request.pathValue` 存在 panic 穿透风险，已改用 requestInfo().query。
  static Future<bool> registerDownload(String resourceId) =>
      _postStatRoute('/api/ct/resource-stats/download?id=$resourceId');

  /// 点赞 / 取消点赞：调 `/api/ct/resource-stats/like?id=<id>` 或 `.../unlike?id=<id>`
  ///
  /// 同上，未部署时静默失败。点赞的**真实态由服务端按用户去重**，
  /// 客户端只做乐观更新（本地先变，失败再回滚）。
  static Future<bool> setLike(String resourceId, bool liked) => _postStatRoute(
        '/api/ct/resource-stats/${liked ? 'like' : 'unlike'}?id=$resourceId',
      );

  /// 举报资源：调 `/api/ct/resource-report?id=<id>`
  ///
  /// 服务端按（用户, 资源）唯一去重：重复举报幂等返回 `true`，不重复计数。
  /// 未登录 / 路由未部署时返回 `false`（静默，不抛异常）。
  static Future<bool> reportResource(String resourceId) =>
      _postStatRoute('/api/ct/resource-report?id=$resourceId');

  static Future<bool> _postStatRoute(String path) async {
    if (!PBConfig.isLoggedIn) return false;
    try {
      await PBConfig.pb.send(path, method: 'POST');
      return true;
    } catch (e) {
      // 404 = 路由未部署；其余为网络/服务端问题。都属于「统计失败」，
      // 不影响主流程，故只记日志。
      debugPrint('[RES] ⚠️ 统计路由失败 $path: $e');
      return false;
    }
  }

  /// 查询「我赞过哪些资源」——用于下载浮层回显点赞态。
  ///
  /// `resource_likes` 的 list/view 规则是 `user = @request.auth.id`，
  /// 因此这里**只能**查到自己的点赞记录。未登录 / 集合不存在时返回空集，
  /// 不抛异常（点赞回显属锦上添花，失败不影响主流程）。
  static Future<Set<String>> fetchMyLikedResourceIds(
    List<String> resourceIds,
  ) async {
    if (resourceIds.isEmpty || !PBConfig.isLoggedIn) return const {};
    final filter = resourceIds.map((id) => "resource='$id'").join(' || ');
    try {
      final list = await PBConfig.pb
          .collection('resource_likes')
          .getFullList(filter: filter);
      return list.map((e) => e.getStringValue('resource')).toSet();
    } catch (e) {
      debugPrint('[RES] ⚠️ 查询我的点赞失败: $e');
      return const {};
    }
  }

  /// 点赞 / 取消点赞（**作品级**）：调 `/api/ct/game-stats/like?id=<games id>`
  /// 或 `.../unlike?id=<id>`（主线补完 §14.2-P2）。
  ///
  /// 形态对齐资源级 [setLike]：未登录 / 路由未部署时返回 `false`（静默，
  /// 不抛异常）；点赞的真实态由服务端按 (user, game) 去重，客户端只做
  /// 乐观更新（失败回滚）。计数由服务端原子维护，客户端不直改。
  static Future<bool> setGameLike(String gameId, bool liked) => _postStatRoute(
        '/api/ct/game-stats/${liked ? 'like' : 'unlike'}?id=$gameId',
      );

  /// 查询「我赞过哪些作品」——用于详情页「喜欢」回显点亮态。
  ///
  /// `game_likes` 的 list/view 规则是 `user = @request.auth.id`，
  /// 因此这里**只能**查到自己的点赞记录。未登录 / 集合不存在时返回空集，
  /// 不抛异常（回显属锦上添花，失败不影响主流程）。
  static Future<Set<String>> fetchMyLikedGameIds(List<String> gameIds) async {
    if (gameIds.isEmpty || !PBConfig.isLoggedIn) return const {};
    final filter = gameIds.map((id) => "game='$id'").join(' || ');
    try {
      final list = await PBConfig.pb
          .collection('game_likes')
          .getFullList(filter: filter);
      return list.map((e) => e.getStringValue('game')).toSet();
    } catch (e) {
      debugPrint('[RES] ⚠️ 查询我的作品点赞失败: $e');
      return const {};
    }
  }

  /// 我的喜欢（作品级）——「我的喜欢」分段列表（my_likes_section.md §2-P1）。
  ///
  /// `game_likes` 的 listRule 是 `user = @request.auth.id`（本人可见），
  /// 因此无需 user filter，直接 getFullList 即只返回自己的点赞记录；
  /// `game` 是 relation → games，`expand=game` 一跳拿全，无需二次请求。
  /// expand 缺失的项跳过（作品已删 / 审核不可见时 PB 直接丢弃关联记录）。
  /// 未登录 / 失败返回空列表不抛异常（与 fetchMyLikedGameIds 容错一致）。
  static Future<List<({GameModel game, DateTime likedAt})>>
      fetchMyLikedGames() async {
    if (!PBConfig.isLoggedIn) return const [];
    try {
      final list = await PBConfig.pb
          .collection('game_likes')
          .getFullList(sort: '-created', expand: 'game');
      final result = <({GameModel game, DateTime likedAt})>[];
      for (final e in list) {
        final expand = e.expand['game'];
        if (expand == null || expand.isEmpty) continue;
        final likedAt = DateTime.tryParse(e.getStringValue('created'));
        result.add((
          game: GameModel.fromPBRecord(expand.first),
          likedAt: likedAt ?? DateTime.now(),
        ));
      }
      return result;
    } catch (e) {
      debugPrint('[RES] ⚠️ 查询我的喜欢（作品）失败: $e');
      return const [];
    }
  }

  /// 我的喜欢（资源级）——「我的喜欢」子胶囊（my_likes_section.md §2-P2）。
  ///
  /// 🔴 依赖 v12 部署（1790991000_updated_resource_likes_rules.js）：
  /// resource_likes 的 list/view 规则开放本人可见。**部署前**规则 null =
  /// 仅超管可读，普通用户查询返回空集——本方法静默空列表不报错，部署后自动生效。
  /// `resource` 是 relation → game_resources，expand 一跳拿全；expand 缺失项跳过。
  static Future<List<({GameResourceModel resource, DateTime likedAt})>>
      fetchMyLikedResources() async {
    if (!PBConfig.isLoggedIn) return const [];
    try {
      final list = await PBConfig.pb
          .collection('resource_likes')
          .getFullList(sort: '-created', expand: 'resource');
      final result = <({GameResourceModel resource, DateTime likedAt})>[];
      for (final e in list) {
        final expand = e.expand['resource'];
        if (expand == null || expand.isEmpty) continue;
        final likedAt = DateTime.tryParse(e.getStringValue('created'));
        result.add((
          resource: GameResourceModel.fromPBRecord(expand.first),
          likedAt: likedAt ?? DateTime.now(),
        ));
      }
      return result;
    } catch (e) {
      debugPrint('[RES] ⚠️ 查询我的喜欢（资源）失败: $e');
      return const [];
    }
  }

  // ==================== 内部 ====================

  static Future<List<GameResourceModel>> _query(
    String filter, {
    String sort = '-created',
    int perPage = _defaultPerPage,
    String expand = '',
  }) async {
    try {
      final r = await PBConfig.pb.collection(_collection).getList(
            page: 1,
            perPage: perPage,
            sort: sort,
            filter: filter,
            expand: expand.isEmpty ? null : expand,
          );
      final list = r.items
          .map((rec) => GameResourceModel.fromPBRecord(rec))
          .toList();
      debugPrint('[RES] ✅ 资源查询 ${list.length} 条 | filter=$filter');
      return list;
    } on ClientException catch (e) {
      if (_isNetworkError(e)) {
        throw Exception('网络连接失败，请检查网络后重试');
      }
      debugPrint('[RES] ❌ 资源查询失败 HTTP ${e.statusCode}: $filter');
      throw Exception('获取资源失败 (${e.statusCode})');
    } catch (e) {
      if (e is SocketException) {
        throw Exception('无法连接服务器，请检查网络连接');
      }
      debugPrint('[RES] ❌ 资源查询异常: $e');
      throw Exception('获取资源时发生未知错误');
    }
  }

  static String get _currentUserId {
    try {
      return PBConfig.pb.authStore.record?.id ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 当前登录用户的某个资料字段（name / avatar），未登录或缺失返回空串
  static String _currentUserField(String field) {
    try {
      final v = PBConfig.pb.authStore.record?.get(field);
      return v is String ? v : '';
    } catch (_) {
      return '';
    }
  }

  static String _translateSubmitError(ClientException e) {
    if (_isNetworkError(e)) return '网络连接失败，请检查网络后重试';
    switch (e.statusCode) {
      case 400:
        return '提交被拒绝：请确认资源链接与标题已填写，且内容符合发布规范';
      case 401:
      case 403:
        return '登录状态已失效，请重新登录后再发布';
      default:
        return '发布失败 (${e.statusCode})，请稍后重试';
    }
  }

  static bool _isNetworkError(ClientException e) {
    final original = e.originalError;
    if (original is SocketException) return true;
    if (original is IOException) return true;
    final msg = e.toString().toLowerCase();
    return msg.contains('connection') ||
        msg.contains('timeout') ||
        msg.contains('socket') ||
        msg.contains('failed to connect');
  }
}
