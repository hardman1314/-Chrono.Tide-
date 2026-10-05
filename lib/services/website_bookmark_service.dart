import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/path_helper.dart';
import '../models/website_entry.dart';
import 'website_icon_service.dart';

/// 网址收藏服务（探索大厅 · 板块④网站管理）
///
/// - 持久化：`data/websites.json`，与 collections.json 同款
///   「先写 .tmp 再 rename」原子写模式（Windows rename 会覆盖目标）
/// - 外链打开：零依赖系统调用 `cmd /c start "" <url>` 拉起系统默认浏览器
///   （Phase 0-V2 已真机验证），仅放行 http/https scheme
class WebsiteBookmarkService extends ChangeNotifier {
  WebsiteBookmarkService._();

  static final WebsiteBookmarkService _instance = WebsiteBookmarkService._();
  static WebsiteBookmarkService get instance => _instance;

  String get _filePath => p.join(PathHelper.dataDir, 'websites.json');

  final List<WebsiteEntry> _entries = [];
  bool _loaded = false;

  List<WebsiteEntry> get entries => List.unmodifiable(_entries);
  bool get isLoaded => _loaded;

  /// 加载磁盘数据（幂等；文件不存在时保持空表）
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = File(_filePath);
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString());
        if (data is List) {
          _entries
            ..clear()
            ..addAll([
              for (final e in data)
                if (e is Map) WebsiteEntry.fromJson(Map<String, dynamic>.from(e)),
            ]);
        }
      }
    } catch (e) {
      debugPrint('[WebsiteBookmark] ⚠️ 加载失败: $e');
    }
    notifyListeners();
  }

  /// 从网址智能推断站点名（用户未填标题时的兜底）
  ///
  /// 过滤网址相关的前缀与公共后缀：
  /// - 前缀：www / m / wap / mobile / forum / bbs
  /// - 后缀：常规 TLD（com/cn/net/org/io/…），含 .com.cn / .co.jp 这类
  ///   双段后缀（倒数第二段是 com/co/net/org/gov/edu/ac 且还剩多段时连删）
  /// - 例：www.kungal.com → kungal；m.example.com.cn → example；
  ///   bgm.tv → bgm；forum.example.org → example
  /// 解析失败或删空时回落原 host（宁多勿空）。
  static String deriveTitle(String url) {
    final uri = Uri.tryParse(normalizeUrl(url) ?? url);
    var host = uri?.host ?? '';
    if (host.isEmpty) host = url.trim();

    var parts = host.toLowerCase().split('.').where((s) => s.isNotEmpty).toList();
    const prefixes = {'www', 'm', 'wap', 'mobile', 'forum', 'bbs'};
    while (parts.length > 1 && prefixes.contains(parts.first)) {
      parts.removeAt(0);
    }
    const secondLevel = {'com', 'co', 'net', 'org', 'gov', 'edu', 'ac'};
    if (parts.length > 1) parts.removeLast(); // 顶层后缀
    if (parts.length > 1 && secondLevel.contains(parts.last)) {
      parts.removeLast(); // 双段后缀（com.cn / co.jp …）
    }
    final name = parts.isEmpty ? host : parts.last;
    return name.isEmpty ? host : name;
  }

  /// 新增站点（title 为空时用 [deriveTitle] 智能推断）；url 非法时静默忽略
  Future<void> add({
    required String title,
    required String url,
    String note = '',
    String iconPath = '',
  }) async {
    final normalized = normalizeUrl(url);
    if (normalized == null) return;
    final entry = WebsiteEntry(
      id:
          '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(99999)}',
      title: title.trim().isEmpty
          ? deriveTitle(normalized)
          : title.trim(),
      url: normalized,
      note: note.trim(),
      iconPath: iconPath,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    _entries.add(entry);
    notifyListeners();
    await _persist();
  }

  /// 编辑站点信息；url 非法时忽略 url 修改
  Future<void> update(
    WebsiteEntry entry, {
    String? title,
    String? url,
    String? note,
    String? iconPath,
  }) async {
    if (url != null) {
      final normalized = normalizeUrl(url);
      if (normalized != null) entry.url = normalized;
    }
    if (title != null && title.trim().isNotEmpty) entry.title = title.trim();
    if (note != null) entry.note = note.trim();
    if (iconPath != null) entry.iconPath = iconPath;
    notifyListeners();
    await _persist();
  }

  // ---------- 站点图标（板块④增强） ----------

  /// 自动识别某条目的站点图标并落库；返回新路径（失败返回 null）
  ///
  /// [force] 为 true 时忽略服务内的"本会话已失败"标记，用于用户手动重试。
  Future<String?> refreshIcon(WebsiteEntry entry, {bool force = false}) async {
    if (force) WebsiteIconService.instance.clearFailure(entry.url);
    final path = await WebsiteIconService.instance.fetchSiteIcon(entry.url);
    if (path == null) return null;
    await update(entry, iconPath: path);
    return path;
  }

  /// 为所有缺图标的条目补齐图标（后台；面板 initState 调用）
  ///
  /// 串行 + 每步判存活，避免并发打爆站点；识别失败的 host 在本会话内
  /// 不再重试。条目为空（如测试环境）时不会发起任何网络请求。
  Future<void> ensureIcons() async {
    final pending = _entries
        .where((e) => e.iconPath.isEmpty || !File(e.iconPath).existsSync())
        .toList();
    for (final e in pending) {
      await refreshIcon(e);
      if (_entries.isEmpty) return; // 面板已卸载/清空
    }
  }

  Future<void> remove(String id) async {
    _entries.removeWhere((e) => e.id == id);
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final file = File(_filePath);
      await file.parent.create(recursive: true);
      final tmp = File('$_filePath.tmp');
      await tmp.writeAsString(
          const JsonEncoder.withIndent('  ').convert(_entries));
      await tmp.rename(_filePath);
    } catch (e) {
      debugPrint('[WebsiteBookmark] ⚠️ 持久化失败: $e');
    }
  }

  /// URL 归一化与白名单校验：无 scheme 自动补 https://；仅放行 http/https。
  /// 返回 null 表示非法（空串 / 非 http(s) scheme / 无 host）。
  static String? normalizeUrl(String raw) {
    var v = raw.trim();
    if (v.isEmpty) return null;
    if (!v.contains('://')) v = 'https://$v';
    final uri = Uri.tryParse(v);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return null;
    }
    if (uri.host.isEmpty) return null;
    return uri.toString();
  }

  /// 用系统默认浏览器打开外链（零依赖系统调用，detached 拉起）。
  /// 返回 false 表示被白名单拦截或进程启动失败。
  static Future<bool> openExternal(String url) async {
    final normalized = normalizeUrl(url);
    if (normalized == null) return false;
    try {
      await Process.start(
        'cmd',
        ['/c', 'start', '', normalized],
        runInShell: false,
        mode: ProcessStartMode.detached,
      );
      return true;
    } catch (e) {
      debugPrint('[WebsiteBookmark] ❌ 打开浏览器失败: $e');
      return false;
    }
  }
}
