import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

import '../core/path_helper.dart';
import '../models/kungal_calendar_game.dart';

/// 发售月历同步服务（探索大厅 · 板块①数据源）
///
/// 🔴 数据源沿革（2026-09-26 定稿）：KUNGAL 品牌迁移为 **NextMoe·未萌**，
/// 官方给开发者发了域名迁移通知（OAuth 域名 oauth.kungal.com →
/// account.nextmoe.com），旧 REST `/api/galgame/calendar*` 全部登录墙
/// （401/205）。官方随后提供 **开放 API v2**（`api.nextmoe.dev/v2`，
/// 自铸密钥、免费、117 端点），本项目已有生产密钥（见 luna SDK）。
///
/// 四桶全部由官方 calendar 端点表达（2026-09-26 实测）：
/// - 当月月历：`?month=YYYY-MM`
/// - 未发售：逐月合成（upcoming 沿用未来 [_upcomingMonths] 月过滤）
/// - 待定（仅知年份）：`?year=YYYY&precision=year`（官方文档注明即 v1 pending）
/// - 未定（TBA）：`?status=announced`
/// 字段与旧 KUNGAL API 高度对齐（content_limit / release_date_precision /
/// cover.url / display_name），适配层转成旧 API 兼容 JSON，
/// `KungalMonthData.fromApi` / `KungalCalendarGame.fromJson` 零改动。
///
/// 回落链：NextMoe 官方 → SSR 页面（仅 month，匿名兜底）→ 超期磁盘缓存。
///
/// 接入约束：
/// - 每数据键 24h 磁盘缓存（`data/cache/kungal_calendar/<key>.json`，原子写）
/// - 按需拉取 + cursor 翻页上限，失败静默回落，绝不重试风暴
/// - 限流 free 档 60 次/分 · 5 万次/日（本服务用量远低于此）
class KungalCalendarService extends ChangeNotifier {
  KungalCalendarService._()
      : _fetchOverride = null,
        _htmlOverride = null,
        _useDisk = true;

  static final KungalCalendarService _instance = KungalCalendarService._();
  static KungalCalendarService get instance => _instance;

  /// 仅供测试：独立实例，禁用磁盘缓存、注入抓取函数（零网络）
  @visibleForTesting
  KungalCalendarService.forTest({
    Future<Map<String, dynamic>?> Function(String url)? fetchOverride,
    String? Function(String url)? htmlOverride,
  })  : _fetchOverride = fetchOverride,
        _htmlOverride = htmlOverride,
        _useDisk = false;

  static const String host = 'https://www.kungal.com';
  static const String calendarPage = '$host/galgame-calendar';

  /// NextMoe 开放 API v2（官方渠道，2026-09-26 起月历首选数据源）
  ///
  /// 鉴权复用 luna_metadata_sdk 的应用密钥（[NextMoeService.apiKey]，
  /// scope catalog:read）——轮换只需改 SDK 常量，避免密钥分叉。
  static const String nextmoeApiBase = 'https://api.nextmoe.dev/v2';
  static const String _nmCalendarPath = '$nextmoeApiBase/catalog/calendar';

  /// include 块：会社 + 评分（月历卡片展示需要）
  static const String _nmInclude = 'companies,ratings';

  static const Duration _ttl = Duration(hours: 24);

  /// 未来月历合成窗口（upcoming 桶：从当前月起向后拉 N 个月）
  static const int _upcomingMonths = 6;

  final Future<Map<String, dynamic>?> Function(String url)? _fetchOverride;
  final String? Function(String url)? _htmlOverride;
  final bool _useDisk;

  // ---- 状态 ----

  final Map<String, KungalMonthData> _months = {}; // key: 'YYYY-MM'
  List<KungalCalendarGame> _upcoming = const [];
  String _pendingYear = '';
  List<KungalCalendarGame> _pending = const [];
  List<KungalCalendarGame> _tba = const [];

  /// 在途抓取键：月份 'YYYY-MM' / 'upcoming' / 'pending:<year>' / 'tba'
  final Set<String> _fetching = {};
  final Set<String> _failed = {};

  // ---- 快照访问 ----

  KungalMonthData? monthData(String ym) => _months[ym];
  List<KungalCalendarGame> get upcomingGames => _upcoming;
  List<KungalCalendarGame> get pendingGames => _pending;
  List<KungalCalendarGame> get tbaGames => _tba;
  String get pendingLoadedYear => _pendingYear;

  bool isLoading(String key) => _fetching.contains(key);
  bool isFailed(String key) => _failed.contains(key);

  static String monthKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

  static String pendingKey(String year) => 'pending:$year';

  // ---- 对外入口 ----

  /// 确保某月月历可用（内存 → 24h 磁盘缓存 → SSR 页面 → 旧 API 回落 → 超期缓存）
  Future<void> ensureMonth(String ym, {bool force = false}) async {
    if (!force && _months.containsKey(ym)) return;
    await _ensure('month_$ym', () async {
      if (!force) {
        final cached = await _loadDiskCache('month_$ym');
        if (cached != null) {
          _months[ym] = KungalMonthData.fromApi(ym, cached);
          return true;
        }
      }
      // ① NextMoe 官方 API（首选：官方密钥 + 字段与旧 API 对齐）
      // precision=day：月历网格只挂 day 精度条目（实测 300 条混杂 → 98% day）
      var data =
          await _fetchNextmoeBucket(query: 'month=$ym&precision=day');
      // ② SSR 页面回落（官方不可用时仍能匿名取当月）
      data ??= await _fetchMonthViaSsr(ym);
      // ③ 全部失败：回落旧缓存（哪怕超期）——有旧数据好过空白
      data ??= await _loadDiskCache('month_$ym', ignoreTtl: true);
      if (data == null) return false;
      unawaited(_saveDiskCache('month_$ym', data));
      _months[ym] = KungalMonthData.fromApi(ym, data);
      return true;
    });
  }

  Future<void> ensureUpcoming({bool force = false}) async {
    if (!force && _upcoming.isNotEmpty) return;
    await _ensure('upcoming', () async {
      // SSR 无独立 upcoming 端点：合成未来 [_upcomingMonths] 个月的月历，
      // 过滤 release_date > 今天（month 数据复用各自的 24h 磁盘缓存）
      final today = DateTime.now();
      final todayStart = DateTime(today.year, today.month, today.day);
      final collected = <KungalCalendarGame>[];
      var anyOk = false;
      for (var i = 0; i < _upcomingMonths; i++) {
        final ym = monthKey(DateTime(today.year, today.month + i, 1));
        await ensureMonth(ym, force: force);
        final md = _months[ym];
        if (md == null) continue;
        anyOk = true;
        collected.addAll(md.items.where((g) {
          final d = g.exactDate;
          return d != null && d.isAfter(todayStart);
        }));
      }
      if (!anyOk) return false;
      collected.sort((a, b) =>
          (a.exactDate ?? DateTime(1970)).compareTo(b.exactDate ?? DateTime(1970)));
      _upcoming = collected;
      return true;
    });
  }

  Future<void> ensurePending(String year, {bool force = false}) async {
    final key = pendingKey(year);
    if (!force && _pendingYear == year && _pending.isNotEmpty) return;
    await _ensure(key, () async {
      if (!force) {
        final cached = await _loadDiskCache(key);
        if (cached != null) {
          _pending = _parseItems(cached['items']);
          _pendingYear = (cached['year'] as String?) ?? year;
          return true;
        }
      }
      // NextMoe 官方：year + precision=year 即「仅知年份」窗口
      // （官方文档注明该窗口等价于 v1 的 pending 桶）
      var data = await _fetchNextmoeBucket(
        query: 'year=$year&precision=year',
        limitPages: 5,
      );
      data ??= await _loadDiskCache(key, ignoreTtl: true);
      if (data == null) return false;
      unawaited(_saveDiskCache(key, data));
      _pending = _parseItems(data['items']);
      _pendingYear = (data['year'] as String?) ?? year;
      return true;
    });
  }

  Future<void> ensureTba({bool force = false}) async {
    if (!force && _tba.isNotEmpty) return;
    await _ensure('tba', () async {
      if (!force) {
        final cached = await _loadDiskCache('tba');
        if (cached != null) {
          _tba = _parseItems(cached['items']);
          return true;
        }
      }
      // NextMoe 官方：status=announced 即「日期未定（TBA）」语义
      var data = await _fetchNextmoeBucket(
          query: 'status=announced', limitPages: 5);
      data ??= await _loadDiskCache('tba', ignoreTtl: true);
      if (data == null) return false;
      unawaited(_saveDiskCache('tba', data));
      _tba = _parseItems(data['items']);
      return true;
    });
  }

  // ---- 通用执行（在途/失败状态机 + 通知） ----

  Future<void> _ensure(String key, Future<bool> Function() task) async {
    if (_fetching.contains(key)) return;
    _fetching.add(key);
    _failed.remove(key);
    notifyListeners();
    try {
      final ok = await task();
      if (!ok && !_hasData(key)) _failed.add(key);
    } finally {
      _fetching.remove(key);
      notifyListeners();
    }
  }

  /// 各键「已有可用数据」判断（失败但内存仍有旧数据时不标失败）
  bool _hasData(String key) {
    if (key.startsWith('month_')) return _months.containsKey(key.substring(6));
    switch (key) {
      case 'upcoming':
        return _upcoming.isNotEmpty;
      case 'tba':
        return _tba.isNotEmpty;
      default:
        if (key.startsWith('pending:')) {
          final y = key.substring(8);
          return _pendingYear == y && _pending.isNotEmpty;
        }
        return false;
    }
  }

  List<KungalCalendarGame> _parseItems(Object? raw) =>
      (raw as List?)
          ?.whereType<Map>()
          .map((m) => KungalCalendarGame.fromJson(Map<String, dynamic>.from(m)))
          .toList() ??
      const <KungalCalendarGame>[];

  // ---- HTTP（dart:io，零新依赖；UA 标识 + 15s 连接 / 20s 总超时） ----

  /// 抓取任意 URL 的响应体（HTTP 200 才返回，否则 null）
  ///
  /// ⚠️ 任一测试注入存在即禁用真实网络（fetchOverride = 旧 API 注入模式，
  /// 此时 SSR 通道视为不可用 → 回落旧 API 数据，旧测试零改动零网络）。
  Future<String?> _fetchBody(String url) async {
    final htmlOverride = _htmlOverride;
    if (htmlOverride != null) return htmlOverride(url);
    if (_fetchOverride != null) return null;
    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 15);
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader,
          'ChronoTide-Desktop (galgame calendar sync; low-frequency)');
      final resp =
          await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        debugPrint('[KungalCalendar] ⚠️ HTTP ${resp.statusCode}: $url');
        await resp.drain<void>().catchError((_) {});
        return null;
      }
      return await resp.transform(utf8.decoder).join();
    } catch (e) {
      debugPrint('[KungalCalendar] ❌ 请求失败: $url → $e');
      return null;
    } finally {
      client?.close();
    }
  }

  // ---- SSR 页面数据源（2026-09-13 起：REST 登录墙，SSR 公开渲染） ----

  static final RegExp _nuxtDataRe =
      RegExp(r'<script[^>]*id="__NUXT_DATA__"[^>]*>([\s\S]*?)</script>');

  /// 抓 SSR 月历页并解析出目标月的作品，输出**旧 API 兼容 JSON**
  /// （{month, items:[...]}），喂给 KungalMonthData.fromApi——模型层零改动。
  ///
  /// 页面有效但该月 0 部作品 → 返回空 items（合法空月）；
  /// 页面无 Nuxt 数据 / 网络失败 → 返回 null（调用方回落）。
  Future<Map<String, dynamic>?> _fetchMonthViaSsr(String ym) async {
    final html = await _fetchBody('$calendarPage?month=$ym');
    if (html == null) return null;
    final items = parseNuxtCalendarItems(html, ym);
    if (items == null) {
      debugPrint('[KungalCalendar] ⚠️ SSR 页面无 Nuxt 数据: $ym');
      return null;
    }
    debugPrint('[KungalCalendar] ✅ SSR 解析 $ym：${items.length} 部');
    return <String, dynamic>{'month': ym, 'items': items};
  }

  /// 从月历页 HTML 提取目标月的作品列表（旧 API item 形状）。
  ///
  /// 返回 null 表示页面不含 `__NUXT_DATA__`（非 Nuxt 页/抓取异常）；
  /// 空列表表示页面有效但当月无作品。
  ///
  /// Nuxt3 payload 是 devalue 扁平数组（实测编码，2026-09-13）：
  /// - 字符串直接内联；布尔/数字等以**裸 int 索引**指向数组元素；
  /// - 对象/数组内联，其字段值可能是指向其它元素的索引；
  /// - 另有 `[idx]` 单元素数组引用形式（防御性同支持）。
  /// 因此读取字段一律经 [KungalSsrReader] 按目标类型解引用。
  @visibleForTesting
  static List<Map<String, dynamic>>? parseNuxtCalendarItems(
    String html,
    String ym,
  ) {
    final m = _nuxtDataRe.firstMatch(html);
    if (m == null) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(m.group(1)!);
    } catch (_) {
      return null;
    }
    if (decoded is! List) return null;

    final r = KungalSsrReader(decoded);
    final items = <Map<String, dynamic>>[];
    for (final node in decoded) {
      if (node is! Map) continue;
      if (r.str(node['object']) != 'work') continue;
      final releaseDate = r.str(node['release_date']);
      if (releaseDate == null || !releaseDate.startsWith(ym)) continue;

      final loc = r.map(node['localized']);
      final name = (loc != null ? r.str(loc['zh-Hans']) : null) ??
          r.str(node['display_name']) ??
          '';
      final nameOriginal =
          (loc != null ? r.str(loc['ja']) : null) ?? name;
      final maker = r.map(node['maker']);
      final cover = r.map(node['cover']);

      items.add(<String, dynamic>{
        'id': int.tryParse(r.str(node['id']) ?? '') ?? 0,
        'name': name,
        'name_original': nameOriginal,
        'company': maker != null ? (r.str(maker['display_name']) ?? '') : '',
        'release_date': releaseDate,
        'release_precision': r.str(node['release_date_precision']) ?? 'day',
        'content_limit': r.boolOf(node['is_nsfw']) ? 'nsfw' : 'sfw',
        'effective_portrait_url': cover != null ? (r.str(cover['url']) ?? '') : '',
        'rating': r.numOf(node['rating_score'])?.toDouble(),
        'rating_count': r.numOf(node['rating_count'])?.toInt(),
      });
    }
    return items;
  }

  // ---- NextMoe 官方 API v2（2026-09-26 起：月历首选数据源） ----

  /// 拉取 NextMoe calendar 的一个查询窗口，输出**旧 API 兼容 JSON**
  ///
  /// [query] 为窗口条件（如 `month=2026-09` / `year=2026&precision=year` /
  /// `status=announced`）；通用参数（limit/nsfw/include/密钥/UA）由此补齐；
  /// 按 `next_cursor` 循环翻页，[limitPages] 为页数上限（防失控）。
  /// 首页即失败返回 null（调用方回落）；翻页中途失败用已取得的部分。
  Future<Map<String, dynamic>?> _fetchNextmoeBucket({
    required String query,
    int limitPages = 3,
  }) async {
    final items = <Map<String, dynamic>>[];
    String? cursor;
    for (var page = 0; page < limitPages; page++) {
      final url = '$_nmCalendarPath?$query&limit=100&nsfw=true'
          '&include=$_nmInclude'
          '${cursor == null ? '' : '&cursor=$cursor'}';
      final resp = await _getNextmoe(url);
      if (resp == null) {
        if (page == 0) return null;
        break;
      }
      for (final r in (resp['items'] as List?) ?? const []) {
        final item = nextmoeToItem(r);
        if (item != null) items.add(item);
      }
      final next = resp['next_cursor'];
      if (next is! String || next.isEmpty) break;
      cursor = next;
    }
    return <String, dynamic>{'items': items};
  }

  /// NextMoe work 条目 → 旧 API item JSON（非 Map 输入返回 null）
  ///
  /// 映射要点（2026-09-26 实测字段）：
  /// - `display_name` 已是官方按 zh-Hans → … → 原文裁定的主显示名，直接用
  /// - 原名：`localized.ja.value` → `latin` → display_name
  /// - 会社：`companies[]` 取 `attribution_role=developer`，多社 ` / ` 连接
  /// - 评分：`ratings[]` 优先 vndb（与 luna SDK 权威链一致），
  ///   erogamescape 100 分制经 /10 归一
  /// - 站内 id：NextMoe catalog id 与 KUNGAL 站内 id 不一定同源，仅在
  ///   `claim.site == 'kungal'` 时取 `claim.site_work_id`（保证详情外跳
  ///   正确）；否则置 0（detailUrl 为空，UI 不展示外跳）
  @visibleForTesting
  static Map<String, dynamic>? nextmoeToItem(Object? r) {
    if (r is! Map) return null;
    final display = r['display_name']?.toString() ?? '';

    String? locJa;
    final localized = r['localized'];
    if (localized is Map) {
      final ja = localized['ja'];
      if (ja is Map) {
        final v = ja['value'];
        if (v is String && v.isNotEmpty) locJa = v;
      }
    }
    final nameOriginal = locJa ?? r['latin']?.toString() ?? display;

    var company = '';
    final companies = r['companies'];
    if (companies is List) {
      final all = companies.whereType<Map>().toList();
      final dev =
          all.where((c) => c['attribution_role'] == 'developer').toList();
      company = (dev.isNotEmpty ? dev : all)
          .map((c) => c['display_name'])
          .whereType<String>()
          .join(' / ');
    }

    double? rating;
    int? ratingCount;
    final ratings = r['ratings'];
    if (ratings is List) {
      final list = ratings.whereType<Map>().toList();
      Map? chosen;
      for (final src in const ['vndb', 'bangumi', 'erogamescape']) {
        for (final x in list) {
          if (x['source'] == src) {
            chosen = x;
            break;
          }
        }
        if (chosen != null) break;
      }
      chosen ??= list.isEmpty ? null : list.first;
      if (chosen != null) {
        final raw =
            (chosen['score'] ?? chosen['value'] ?? chosen['rating']) as num?;
        if (raw != null) {
          final v = raw.toDouble();
          final src = chosen['source']?.toString() ?? '';
          rating = (src == 'erogamescape' || v > 10) ? v / 10 : v;
          final cnt = (chosen['vote_count'] ?? chosen['votes']) as num?;
          ratingCount = cnt?.toInt();
        }
      }
    }

    var workId = 0;
    final claim = r['claim'];
    if (claim is Map && claim['site'] == 'kungal') {
      workId = int.tryParse(claim['site_work_id']?.toString() ?? '') ?? 0;
    }

    final cover = r['cover'];
    return <String, dynamic>{
      'id': workId,
      'name': display,
      'name_original': nameOriginal,
      'company': company,
      'release_date': r['release_date']?.toString() ?? '',
      'release_precision':
          r['release_date_precision']?.toString() ?? 'unknown',
      'content_limit': r['content_limit']?.toString() ?? 'sfw',
      'effective_portrait_url':
          cover is Map ? (cover['url']?.toString() ?? '') : '',
      'rating': rating,
      'rating_count': ratingCount,
    };
  }

  /// NextMoe API GET（Bearer 应用密钥）；测试注入存在时走 [_fetchOverride]
  Future<Map<String, dynamic>?> _getNextmoe(String url) async {
    final override = _fetchOverride;
    if (override != null) return override(url);
    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 15);
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(
          HttpHeaders.authorizationHeader, 'Bearer ${NextMoeService.apiKey}');
      req.headers.set(HttpHeaders.userAgentHeader,
          'ChronoTide-Desktop (galgame calendar sync; low-frequency)');
      final resp = await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        debugPrint('[KungalCalendar] ⚠️ NextMoe HTTP ${resp.statusCode}: $url');
        await resp.drain<void>().catchError((_) {});
        return null;
      }
      final decoded = jsonDecode(await resp.transform(utf8.decoder).join());
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (e) {
      debugPrint('[KungalCalendar] ❌ NextMoe 请求失败: $url → $e');
      return null;
    } finally {
      client?.close();
    }
  }

  // ---- 磁盘缓存（每键 24h TTL；原子写 tmp→rename） ----

  File? _cacheFile(String key) {
    if (!_useDisk) return null;
    return File(p.join(
      PathHelper.dataDir,
      'cache',
      'kungal_calendar',
      '$key.json',
    ));
  }

  Future<Map<String, dynamic>?> _loadDiskCache(
    String key, {
    bool ignoreTtl = false,
  }) async {
    final file = _cacheFile(key);
    if (file == null) return null;
    try {
      if (!await file.exists()) return null;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return null;
      final ts = (raw['fetched_at'] as num?)?.toInt() ?? 0;
      if (!ignoreTtl &&
          DateTime.now().millisecondsSinceEpoch - ts > _ttl.inMilliseconds) {
        return null;
      }
      final data = raw['data'];
      return data is Map ? Map<String, dynamic>.from(data) : null;
    } catch (e) {
      debugPrint('[KungalCalendar] ⚠️ 读缓存失败 [$key]: $e');
      return null;
    }
  }

  Future<void> _saveDiskCache(String key, Map<String, dynamic> data) async {
    final file = _cacheFile(key);
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode({
        'fetched_at': DateTime.now().millisecondsSinceEpoch,
        'data': data,
      }));
      await tmp.rename(file.path);
    } catch (e) {
      debugPrint('[KungalCalendar] ⚠️ 写缓存失败 [$key]: $e');
    }
  }
}

/// Nuxt3 devalue 扁平数组的按类型解引用读取器
///
/// 实测编码（KUNGAL 月历页，2026-09-13）：字符串内联；布尔/数字等以裸
/// int 索引指向数组元素；对象/数组内联但字段值可能是指向其它元素的索引；
/// 另有 `[idx]` 单元素数组引用形式（防御性支持）。读取时必须按目标类型
/// 解引用——直接比较 `node['object'] == 'work'` 永远为 false（值是索引）。
@visibleForTesting
class KungalSsrReader {
  final List<Object?> payload;

  const KungalSsrReader(this.payload);

  dynamic _resolve(Object? v) {
    // 🔴 devalue 规范：对象字段值**一律是索引**（含字符串/布尔/null/数字，
    // 实测 release_date: 60 → "2026-09-01"、is_nsfw: 7 → false），
    // 裸 int 必须解引用到 payload 元素；[idx] 单元素数组形式防御性同支持。
    if (v is int && v >= 0 && v < payload.length) return payload[v];
    if (v is List && v.length == 1 && v.first is int) {
      final i = v.first as int;
      if (i >= 0 && i < payload.length) return _resolve(payload[i]);
    }
    return v;
  }

  String? str(Object? v) {
    var r = _resolve(v);
    // 本地化名称包装形态：{value: idx, is_machine: idx}
    if (r is Map && r['value'] is int) r = _resolve(r['value']);
    return r is String ? r : null;
  }

  bool boolOf(Object? v) => _resolve(v) == true;

  num? numOf(Object? v) {
    final r = _resolve(v);
    return r is num ? r : null;
  }

  Map? map(Object? v) {
    final r = _resolve(v);
    return r is Map ? r : null;
  }
}
