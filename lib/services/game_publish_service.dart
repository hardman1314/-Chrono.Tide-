import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';

import '../core/pb_config.dart';
import '../models/game_model.dart';

/// 作品【发布】层：把一部**探索库中不存在**的作品发布到 PocketBase `games`
/// 集合（`pbc_879072730`）。
///
/// ## 与「资源投稿」的边界（方案 §8.7）
///
/// | 类型 | 前提 | 入口 | 写入 |
/// |---|---|---|---|
/// | **资源投稿** | 作品**已存在**于探索库 | 探索详情页 →【上传】 | 仅 `game_resources` |
/// | **作品发布** | 作品**不存在**于探索库 | 探索大厅 → 文档板块 →【发布】 | 先 `games`，再 `game_resources` |
///
/// 本服务**只负责前者之外的「作品」这一半**；资源那一半仍走
/// [GameResourceService.createCommunityResource]（发布第三步直接复用）。
///
/// ## 服务端规则（本文件所有写操作的行为边界）
///
/// ```
/// createRule = @request.auth.id != "" && @request.body.origin = "user"
///           && @request.body.owner = @request.auth.id && @request.body.review_status = "pending"
/// updateRule = owner = @request.auth.id && origin = "user" && review_status != "approved"
/// deleteRule = owner = @request.auth.id && origin = "user"
/// ```
///
/// ⚠️ 三条规则的共同特点：**不满足时 PB 返回 404 而不是 403**。
/// 因此调用前必须用 [GameModel.canEditAsOwner] / [canDeleteAsOwner] 预判，
/// 否则用户点了按钮才失败。
///
/// 🔴 **前置字段条件**：`games.downloadUrl` 当前为 `required: true`，而用户作品
/// 本就没有官方下载路径。在服务端把该字段改为**非必需**之前，[publishGame]
/// 必然被 400 拒绝（方案 §8.9-2）。
class GamePublishService {
  const GamePublishService._();

  static const String _collection = 'games';

  /// 别名（日语 / 英语 / 繁中）之外，客户端一律钉死的受控字段
  static const Map<String, dynamic> _controlledFields = {
    'origin': 'user',
    'review_status': 'pending',
    'has_official': false,
  };

  // ==================== 判重（第 1 步）====================

  /// 在第 1 步按游戏名模糊查询探索库，用于判断「是否已存在」。
  ///
  /// 使用 PB 的 `~` 包含匹配（不区分大小写）。**失败返回空列表**——
  /// 判重失败不应阻断发布流程，最坏情况是用户发布了重复作品，由管理员审核拦下。
  static Future<List<GameModel>> searchByTitle(
    String title, {
    int perPage = 10,
  }) async {
    final q = title.trim();
    if (q.isEmpty) return const [];
    try {
      final r = await PBConfig.pb.collection(_collection).getList(
            page: 1,
            perPage: perPage,
            filter: 'title ~ ${_quote(q)}',
          );
      return r.items.map(GameModel.fromPBRecord).toList();
    } catch (e) {
      debugPrint('[PUBLISH] ⚠️ 判重查询失败 (title="$q"): $e');
      return const [];
    }
  }

  // ==================== 发布（第 2 步）====================

  /// 发布一部作品。
  ///
  /// [coverFilePath] / [screenshotPaths] 为本地文件绝对路径；非空时走 multipart
  /// （与 `game_detail_page` 回传截图的写法一致），否则走 SDK 的 JSON create。
  ///
  /// 成功返回创建后的 [GameModel]（其 `id` 即发布第三步要用到的 `game` 值）。
  /// 失败抛出带中文说明的 [Exception]，由调用方提示。
  static Future<GameModel> publishGame({
    required String title,
    String originalTitle = '',
    String englishTitle = '',
    String traditionalChineseTitle = '',
    String description = '',
    String developer = '',
    double? rating,
    int? voteCount,
    String releaseDate = '',
    List<String> tags = const [],
    String metaSource = '',
    String? coverFilePath,
    String? bannerFilePath,
    List<String> screenshotPaths = const [],
  }) async {
    final uid = currentUserId;
    if (uid.isEmpty) {
      throw Exception('请先登录后再发布作品');
    }
    if (title.trim().isEmpty) {
      throw Exception('游戏名称不能为空');
    }

    final body = <String, dynamic>{
      // 受控字段：必须与 createRule 完全一致
      ..._controlledFields,
      'owner': uid,
      // 业务字段
      'title': title.trim(),
      // 🔴 用户作品没有官方下载路径；该字段改为「非必需」后才可留空（§8.9-2）
      'downloadUrl': '',
      'creator_name': currentUserName,
    };
    if (originalTitle.trim().isNotEmpty) {
      body['originalTitle'] = originalTitle.trim();
    }
    if (englishTitle.trim().isNotEmpty) {
      body['englishTitle'] = englishTitle.trim();
    }
    if (traditionalChineseTitle.trim().isNotEmpty) {
      body['traditionalChineseTitle'] = traditionalChineseTitle.trim();
    }
    if (description.trim().isNotEmpty) {
      body['description'] = description.trim();
    }
    if (developer.trim().isNotEmpty) body['Developer'] = developer.trim();
    if (rating != null && rating > 0) body['rating'] = rating;
    if (voteCount != null && voteCount > 0) body['voteCount'] = voteCount;
    if (releaseDate.trim().isNotEmpty) {
      body['releaseDate'] = releaseDate.trim();
    }
    if (tags.isNotEmpty) body['tags'] = tags;
    if (metaSource.trim().isNotEmpty) body['metaSource'] = metaSource.trim();

    final hasFiles =
        (coverFilePath != null && coverFilePath.isNotEmpty) ||
            (bannerFilePath != null && bannerFilePath.isNotEmpty) ||
            screenshotPaths.isNotEmpty;

    try {
      final record = hasFiles
          ? await _createWithFiles(
              body: body,
              coverFilePath: coverFilePath,
              bannerFilePath: bannerFilePath,
              screenshotPaths: screenshotPaths,
            )
          : await PBConfig.pb.collection(_collection).create(body: body);
      debugPrint('[PUBLISH] ✅ 作品已提交待审: id=${record.id}');
      return GameModel.fromPBRecord(record);
    } on ClientException catch (e) {
      debugPrint('[PUBLISH] ❌ 作品提交失败 HTTP ${e.statusCode}: ${e.response}');
      throw Exception(_translate(e, action: '发布'));
    } catch (e) {
      debugPrint('[PUBLISH] ❌ 作品提交异常: $e');
      throw Exception('发布失败，请检查网络后重试');
    }
  }

  // ==================== 我的发布（【我的】页）====================

  /// 拉取当前用户发布的**全部作品**（含审核中 / 已驳回 / 已通过）。
  ///
  /// 未登录返回空列表。失败抛出带中文说明的异常（【我的】页需要明确报错，
  /// 与详情页「静默降级」的取向不同）。
  static Future<List<GameModel>> fetchMyGames({int perPage = 100}) async {
    final uid = currentUserId;
    if (uid.isEmpty) return const [];
    try {
      final r = await PBConfig.pb.collection(_collection).getList(
            page: 1,
            perPage: perPage,
            sort: '-created',
            filter: "owner='$uid' && origin='user'",
          );
      final list = r.items.map(GameModel.fromPBRecord).toList();
      debugPrint('[PUBLISH] ✅ 我发布的作品 ${list.length} 条');
      return list;
    } on ClientException catch (e) {
      debugPrint('[PUBLISH] ❌ 我的作品查询失败 HTTP ${e.statusCode}');
      throw Exception(_translate(e, action: '获取'));
    }
  }

  /// 编辑我发布的作品。
  ///
  /// ⚠️ 只发送**用户可写**的字段；`origin` / `owner` / `has_official`
  /// **一律不传**——它们被 `lock_fields.pb.js` 锁定，传了也会被静默还原。
  ///
  /// [resubmit]（统一审核机制后）：编辑完成时一并重新提交审核。
  /// 服务端 `lock_fields` v6 白名单放行 owner 本人的
  /// `rejected→pending` 与 `editing→pending`；`pending` 记录本就在队列，
  /// 传 false 即可。🔴 修复历史 bug：此前 rejected 作品保存后重提信号丢失。
  ///
  /// 🔴 `pending_delete` 态记录 updateRule 仅允许撤回（→approved），
  /// 传字段会 404；`approved` 态需先经 [startGameEditing] 发起编辑。
  static Future<GameModel> updateMyGame(
    String gameId, {
    required String title,
    String originalTitle = '',
    String englishTitle = '',
    String traditionalChineseTitle = '',
    String description = '',
    String developer = '',
    double? rating,
    int? voteCount,
    String releaseDate = '',
    List<String> tags = const [],
    String metaSource = '',
    bool resubmit = false,
    String? bannerFilePath,
  }) async {
    final uid = currentUserId;
    if (uid.isEmpty) {
      throw Exception('请先登录后再编辑作品');
    }
    if (title.trim().isEmpty) {
      throw Exception('游戏名称不能为空');
    }

    final body = <String, dynamic>{
      'title': title.trim(),
      'originalTitle': originalTitle.trim(),
      'englishTitle': englishTitle.trim(),
      'traditionalChineseTitle': traditionalChineseTitle.trim(),
      'description': description.trim(),
      'Developer': developer.trim(),
      'releaseDate': releaseDate.trim(),
      'metaSource': metaSource.trim(),
      'tags': tags,
    };
    // 评分类可清空：显式写 0，避免「删不掉」
    body['rating'] = (rating != null && rating > 0) ? rating : 0;
    body['voteCount'] = (voteCount != null && voteCount > 0) ? voteCount : 0;
    if (resubmit) {
      // 服务端白名单放行 rejected→pending / editing→pending（owner 本人）
      body['review_status'] = 'pending';
    }

    try {
      final hasBanner = bannerFilePath != null && bannerFilePath.isNotEmpty;
      final record = hasBanner
          ? await _updateWithFiles(gameId, body: body,
              bannerFilePath: bannerFilePath)
          : await PBConfig.pb
              .collection(_collection)
              .update(gameId, body: body);
      debugPrint('[PUBLISH] ✅ 作品已更新: id=$gameId');
      return GameModel.fromPBRecord(record);
    } on ClientException catch (e) {
      debugPrint('[PUBLISH] ❌ 作品更新失败 HTTP ${e.statusCode}');
      throw Exception(_translate(e, action: '保存'));
    } catch (e) {
      debugPrint('[PUBLISH] ❌ 作品更新异常: $e');
      throw Exception('保存失败，请检查网络后重试');
    }
  }

  /// 发起编辑：已进库作品下架暂存（`approved → editing`）。
  ///
  /// 统一审核机制：下架期间数据全部保留；此后 [updateMyGame] 直接可改
  /// 字段，提交时带 `resubmit: true` 回到审核队列。仅 `approved` 可调用。
  static Future<void> startGameEditing(String gameId) async {
    if (currentUserId.isEmpty) {
      throw Exception('请先登录后再编辑作品');
    }
    try {
      await PBConfig.pb
          .collection(_collection)
          .update(gameId, body: {'review_status': 'editing'});
      debugPrint('[PUBLISH] ✅ 作品已转入编辑态（下架暂存）: id=$gameId');
    } on ClientException catch (e) {
      debugPrint('[PUBLISH] ❌ 发起编辑失败 HTTP ${e.statusCode}');
      throw Exception(_translate(e, action: '发起编辑'));
    } catch (e) {
      debugPrint('[PUBLISH] ❌ 发起编辑异常: $e');
      throw Exception('发起编辑失败，请检查网络后重试');
    }
  }

  /// 申请删除：已进库作品下架等管理员裁决（`approved → pending_delete`）。
  ///
  /// ⚠️ 作品名下资源记录会保留（本操作不触发级联删除）；管理员通过 =
  /// 后台直接删除记录（届时级联删除名下资源）；拒绝 = 状态改回 `approved`。
  /// 审核期间作者可随时 [withdrawGameDelete] 撤回。
  static Future<void> requestGameDelete(String gameId) async {
    if (currentUserId.isEmpty) {
      throw Exception('请先登录后再删除作品');
    }
    try {
      await PBConfig.pb
          .collection(_collection)
          .update(gameId, body: {'review_status': 'pending_delete'});
      debugPrint('[PUBLISH] ✅ 删除申请已提交: id=$gameId');
    } on ClientException catch (e) {
      debugPrint('[PUBLISH] ❌ 申请删除失败 HTTP ${e.statusCode}');
      throw Exception(_translate(e, action: '申请删除'));
    } catch (e) {
      debugPrint('[PUBLISH] ❌ 申请删除异常: $e');
      throw Exception('申请删除失败，请检查网络后重试');
    }
  }

  /// 撤回删除申请（`pending_delete → approved`）：恢复审核过的原内容，
  /// 数据零丢失。
  static Future<void> withdrawGameDelete(String gameId) async {
    if (currentUserId.isEmpty) {
      throw Exception('请先登录后再操作');
    }
    try {
      await PBConfig.pb
          .collection(_collection)
          .update(gameId, body: {'review_status': 'approved'});
      debugPrint('[PUBLISH] ✅ 已撤回删除申请: id=$gameId');
    } on ClientException catch (e) {
      debugPrint('[PUBLISH] ❌ 撤回删除失败 HTTP ${e.statusCode}');
      throw Exception(_translate(e, action: '撤回删除申请'));
    } catch (e) {
      debugPrint('[PUBLISH] ❌ 撤回删除异常: $e');
      throw Exception('撤回失败，请检查网络后重试');
    }
  }

  /// 删除我发布的作品。
  ///
  /// 统一审核机制后 `deleteRule` 追加
  /// `review_status != "approved" && review_status != "pending_delete"`
  /// ⇒ **已进库作品不能直接删**（服务端 404），请走 [requestGameDelete]；
  /// 本方法仅适用未进库状态（pending / rejected / editing）。
  ///
  /// ⚠️ `games` 与 `game_resources` 之间是 `cascadeDelete` ⇒ 删除作品会
  /// **连带删除它名下的全部资源记录**，调用方必须二次确认。
  static Future<void> deleteMyGame(String gameId) async {
    if (currentUserId.isEmpty) {
      throw Exception('请先登录后再删除作品');
    }
    try {
      await PBConfig.pb.collection(_collection).delete(gameId);
      debugPrint('[PUBLISH] ✅ 作品已删除: id=$gameId');
    } on ClientException catch (e) {
      debugPrint('[PUBLISH] ❌ 作品删除失败 HTTP ${e.statusCode}');
      throw Exception(_translate(e, action: '删除'));
    } catch (e) {
      debugPrint('[PUBLISH] ❌ 作品删除异常: $e');
      throw Exception('删除失败，请检查网络后重试');
    }
  }

  // ==================== 当前用户 ====================

  /// 当前登录用户 id；未登录返回空串
  static String get currentUserId {
    try {
      return PBConfig.pb.authStore.record?.id ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 当前登录用户昵称（写入 `creator_name` 冗余字段）；取不到返回空串
  static String get currentUserName {
    try {
      final rec = PBConfig.pb.authStore.record;
      if (rec == null) return '';
      final name = rec.getStringValue('name');
      return name.isEmpty ? '' : name;
    } catch (_) {
      return '';
    }
  }

  // ==================== 内部 ====================

  /// 带文件的创建：multipart POST（写法对齐 `game_detail_page` 的截图回传）
  static Future<RecordModel> _createWithFiles({
    required Map<String, dynamic> body,
    String? coverFilePath,
    String? bannerFilePath,
    List<String> screenshotPaths = const [],
  }) async {
    final uri = Uri.parse('${PBConfig.pb.baseURL}/api/collections/$_collection/records');
    final request = http.MultipartRequest('POST', uri);
    request.headers['Authorization'] = 'Bearer ${PBConfig.token}';

    // PB multipart 的字段值一律按字符串传；bool / number / list 需自行序列化
    body.forEach((key, value) {
      if (value == null) return;
      if (value is List) {
        for (final item in value) {
          request.fields['$key[]'] = item.toString();
        }
      } else {
        request.fields[key] = value.toString();
      }
    });

    if (coverFilePath != null && coverFilePath.isNotEmpty) {
      final f = File(coverFilePath);
      if (await f.exists()) {
        request.files.add(
          await http.MultipartFile.fromPath('coverUrl', coverFilePath),
        );
      }
    }
    // 横幅封面（PB bannerUrl file 字段，2026-10-05 与本地 banner_file 对齐）
    if (bannerFilePath != null && bannerFilePath.isNotEmpty) {
      final f = File(bannerFilePath);
      if (await f.exists()) {
        request.files.add(
          await http.MultipartFile.fromPath('bannerUrl', bannerFilePath),
        );
      }
    }
    for (final path in screenshotPaths) {
      final f = File(path);
      if (await f.exists()) {
        request.files.add(
          await http.MultipartFile.fromPath('screenshots', path),
        );
      }
    }

    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode != 200 && response.statusCode != 201) {
      // ClientException 是**命名参数**构造（`client_exception.dart:18`），
      // 且 response 必须是 Map —— 直接传原始字符串会编译不过。
      throw ClientException(
        url: uri,
        statusCode: response.statusCode,
        response: _asErrorMap(response.body),
        originalError: response.body,
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return RecordModel.fromJson(json);
  }

  /// 带文件的更新：multipart PATCH（横幅封面替换；写法对齐 [_createWithFiles]）
  static Future<RecordModel> _updateWithFiles(
    String gameId, {
    required Map<String, dynamic> body,
    String? bannerFilePath,
  }) async {
    final uri = Uri.parse(
        '${PBConfig.pb.baseURL}/api/collections/$_collection/records/$gameId');
    final request = http.MultipartRequest('PATCH', uri);
    request.headers['Authorization'] = 'Bearer ${PBConfig.token}';

    body.forEach((key, value) {
      if (value == null) return;
      if (value is List) {
        for (final item in value) {
          request.fields['$key[]'] = item.toString();
        }
      } else {
        request.fields[key] = value.toString();
      }
    });

    if (bannerFilePath != null && bannerFilePath.isNotEmpty) {
      final f = File(bannerFilePath);
      if (await f.exists()) {
        request.files.add(
          await http.MultipartFile.fromPath('bannerUrl', bannerFilePath),
        );
      }
    }

    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw ClientException(
        url: uri,
        statusCode: response.statusCode,
        response: _asErrorMap(response.body),
        originalError: response.body,
      );
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return RecordModel.fromJson(json);
  }

  /// 把 PB 的错误响应体转成 Map（非 JSON 时包一层，避免构造 ClientException 失败）
  static Map<String, dynamic> _asErrorMap(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      return {'message': decoded.toString()};
    } catch (_) {
      return {'message': body};
    }
  }

  /// PB filter 字符串字面量转义（防注入 / 防解析错）
  static String _quote(String raw) {
    final escaped = raw.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
    return '"$escaped"';
  }

  static String _translate(ClientException e, {required String action}) {
    switch (e.statusCode) {
      case 400:
        return '$action被拒绝：请确认必填内容已填写且符合发布规范';
      case 401:
      case 403:
        return '登录状态已失效，请重新登录后再试';
      case 404:
        // 规则不满足时 PB 返回 404 而非 403 —— 这里必须说清真实原因
        return '该作品已通过审核或不属于你，无法$action';
      default:
        return '$action失败 (${e.statusCode})，请稍后重试';
    }
  }
}
