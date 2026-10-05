/// 检测结果缓存：`图片 key → bbox 列表`，内存 Map + 去抖落盘。
///
/// 方案见 `docs/DEV/features/nsfw_filter_implementation_plan.md` §4.3 / §4.4。
///
/// ⚠️ **v1 的 P0 bug 就在这一层**：渲染侧用 URL 查、写入侧用本地路径写，
/// 两个 key 永不相等，于是线上数据永远查不到结果、打码完全失效。
/// v2 的纪律：**所有读写都必须走本类的 [keyForFile] / [keyForUrl]，
/// 任何地方都不允许自己拼 key。** 网络图在落盘时做双键写入（路径主键 + URL 别名）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/path_helper.dart';
import '../../utils/path_normalizer.dart';
import 'nsfw_box.dart';

class NsfwDetectionStore extends ChangeNotifier {
  static const String _kModelVerField = 'model_ver';
  static const String _kItemsField = 'items';

  /// 落盘去抖：扫描时高频写入，攒一批再写。
  static const Duration _flushDebounce = Duration(seconds: 3);

  /// UI 通知去抖（§6.2 节流）：全量扫描 7000 张不能触发 7000 次重建。
  static const Duration _notifyDebounce = Duration(milliseconds: 200);

  /// 缓存条目上限（P1-4）。
  ///
  /// 旧实现**无上限**：1000 游戏 × 6 张截图 ≈ 6000 条全部常驻内存、
  /// 整表落盘，删除游戏后其记录还是孤儿，文件只增不减。
  /// 5000 条约对应单文件 1~2MB —— 远低于"把被淘汰的图重扫一遍"的代价，
  /// 而"重扫"本身就是这条缓存要避免的事，所以上限必须留足余量。
  static const int maxItems = 5000;

  /// 判定结果有效期（P1-4）。超过即为过期，直接丢弃。
  ///
  /// 与 [load] 的 modelSignature 是**互补**的两件事：
  /// - modelSignature 管"算法/阈值变了" → 整表作废；
  /// - 本上限管"结果太旧" → 逐条淘汰。
  /// 只做前者的话，在算法长期不变的前提下文件仍会无限增长（旧实况）。
  static const Duration maxAge = Duration(days: 180);

  static NsfwDetectionStore? _instance;
  static NsfwDetectionStore get instance =>
      _instance ??= NsfwDetectionStore._();
  NsfwDetectionStore._();

  final Map<String, NsfwDetection> _items = <String, NsfwDetection>{};

  String _modelSignature = '';
  bool _loaded = false;
  bool _dirty = false;
  Timer? _flushTimer;
  Timer? _notifyTimer;
  Future<void>? _writing;

  bool get loaded => _loaded;
  int get count => _items.length;

  /// 最近一次淘汰删除的条目数（测试与设置页统计用）
  int lastPrunedCount = 0;

  /// 已检出敏感内容的图片数（用于设置页展示统计）。
  int get flaggedCount =>
      _items.values.where((NsfwDetection d) => d.hasNsfw).length;

  // ===================== key 规则（唯一入口） =====================

  /// 本地文件 key：统一分隔符 + 折叠冗余段 + 小写。
  ///
  /// 复用项目既有的 [PathNormalizer.forCompare]，与导入排重、封面查找同一套语义，
  /// 避免再造第四套路径规范化。
  static String keyForFile(String filePath) {
    if (filePath.isEmpty) return '';
    return PathNormalizer.forCompare(filePath);
  }

  /// 网络图 key：URL 原文（去首尾空白）。
  ///
  /// 不做小写化 —— URL 的 path 段是大小写敏感的。
  static String keyForUrl(String url) => url.trim();

  // ===================== 加载 / 失效 =====================

  /// 加载缓存。[modelSignature] 不匹配时**整表作废**（阈值或分辨率变了，旧结果无意义）。
  ///
  /// 返回值：缓存是否因签名不匹配而作废（v2.1.3）。调用方据此重置全量
  /// 扫描标记——签名失效意味着库里所有图都需要重判，而全量扫描只在
  /// 「首次手动开启开关」时自动跑一次，不重置的话存量图永远不会被补判
  /// （组件级按需只覆盖用户实际看到的图）。
  Future<bool> load(String modelSignature) async {
    if (_loaded && _modelSignature == modelSignature) return false;

    _items.clear();
    _modelSignature = modelSignature;
    _loaded = true;

    try {
      final File file = File(PathHelper.nsfwDetectionsFilePath);
      if (!await file.exists()) {
        debugPrint('[NSFW-STORE] 无缓存文件，从空表开始');
        _notify();
        return false;
      }
      final String raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        _notify();
        return false;
      }
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) {
        debugPrint('[NSFW-STORE] 缓存格式异常，丢弃');
        _notify();
        return false;
      }
      final Object? ver = decoded[_kModelVerField];
      if (ver != modelSignature) {
        debugPrint('[NSFW-STORE] 签名不匹配（缓存 $ver / 当前 $modelSignature），整表作废');
        _dirty = true; // 让下次 flush 覆盖掉旧文件
        _notify();
        return true; // 通知调用方：需要重新全量补判
      }
      final Object? items = decoded[_kItemsField];
      if (items is Map) {
        items.forEach((Object? k, Object? v) {
          if (k is! String || k.isEmpty) return;
          final NsfwDetection? d = NsfwDetection.fromJson(v);
          if (d != null) _items[k] = d;
        });
      }
      // ★ P1-4：加载后立刻淘汰一次。放在这里而不是构造/启动流程里，
      //   是为了让"淘汰"与"数据刚到齐"发生在同一处，不依赖调用方记得调。
      if (_prune()) _dirty = true;
      debugPrint('[NSFW-STORE] 已加载 ${_items.length} 条检测结果'
          '（其中 $flaggedCount 条含敏感内容）');
    } catch (e) {
      debugPrint('[NSFW-STORE] 加载失败，从空表开始: $e');
      _items.clear();
    }
    _notify();
    return false;
  }

  // ===================== 查询 =====================

  bool has(String key) => key.isNotEmpty && _items.containsKey(key);

  NsfwDetection? detectionFor(String key) =>
      key.isEmpty ? null : _items[key];

  /// 返回该图的 bbox 列表；无记录返回 `null`（区别于「已判定且干净」的空列表）。
  ///
  /// 调用方语义：
  /// - `null` → 尚未判定，按放行渲染（避免误伤未扫描的图）
  /// - `[]`   → 已判定为干净，走零开销原图路径
  /// - 非空   → 走局部马赛克路径
  List<NsfwBox>? boxesFor(String key) => detectionFor(key)?.boxes;

  /// 依次尝试多个 key，返回第一个命中的结果。
  ///
  /// 网络图渲染时用：先试 URL key，再试推导出的本地缓存路径 key（§4.4）。
  NsfwDetection? detectionForAny(Iterable<String> keys) {
    for (final String k in keys) {
      final NsfwDetection? d = detectionFor(k);
      if (d != null) return d;
    }
    return null;
  }

  // ===================== 写入 =====================

  /// 写入一条结果。[aliasKeys] 用于双键写入（如网络图的来源 URL）。
  void put(String key, NsfwDetection detection,
      {Iterable<String> aliasKeys = const <String>[]}) {
    if (key.isEmpty) return;
    _items[key] = detection;
    for (final String alias in aliasKeys) {
      if (alias.isNotEmpty && alias != key) _items[alias] = detection;
    }
    _dirty = true;
    _scheduleFlush();
    _notify();
  }

  void remove(String key) {
    if (_items.remove(key) != null) {
      _dirty = true;
      _scheduleFlush();
      _notify();
    }
  }

  /// 删除某个**游戏目录**下的全部判定记录（P1-4）。
  ///
  /// 用途：删游戏时同步清缓存。不做的话，键（归一化后的文件路径）会变成
  /// 永久孤儿 —— 游戏都没了，再没有任何代码会去查/写这些键，
  /// 只能等容量或过期淘汰兜底。
  ///
  /// 只处理本地路径键（[keyForFile] 归一化后必然带该目录前缀）；
  /// 网络图 URL 键没有目录归属，不在此处处理，由容量/过期淘汰兜底。
  /// 返回实际删除的条目数。
  int removeUnderDirectory(String dirPath) {
    if (dirPath.isEmpty) return 0;
    final String prefix = PathNormalizer.forCompare(dirPath);
    if (prefix.isEmpty) return 0;
    final int before = _items.length;
    // 🔴 前缀必须落在**路径分隔符边界**上：否则 "c:\games\a" 会误伤
    //   "c:\games\ab\cover.png"（同级目录名有共同前缀）。
    _items.removeWhere((String key, NsfwDetection _) =>
        key.startsWith(prefix) &&
        (key.length == prefix.length ||
            key[prefix.length] == '\\' ||
            key[prefix.length] == '/'));
    final int removed = before - _items.length;
    if (removed > 0) {
      _dirty = true;
      _scheduleFlush();
      _notify();
      debugPrint('[NSFW-STORE] 🗑️ 已清理目录下 $removed 条判定记录: $dirPath');
    }
    return removed;
  }

  /// 淘汰过期 / 超量条目（P1-4）。返回是否真的删掉了东西。
  ///
  /// 规则：
  /// - **过期**：`detectedAtMs` 早于 `now - maxAge` 的条目直接删除。
  ///   时间戳为 0（老数据没写）视为"不可判定"，不参与过期判断，
  ///   只参与容量淘汰 —— 否则老数据会在升级后第一秒被整批误删。
  /// - **超量**：按 `detectedAtMs` 升序淘汰最旧的，直到降到 [maxItems]。
  ///   这是"最旧优先"而非严格 LRU：NsfwDetection 里只有判定时间、
  ///   没有访问时间，为它加一个访问序字段意味着多一份落盘格式与迁移，
  ///   而"旧结果优先丢弃"在效果上足够接近（被淘汰的图重扫一次即可）。
  bool _prune() {
    if (_items.isEmpty) {
      lastPrunedCount = 0;
      return false;
    }
    final int before = _items.length;
    final int expireBefore =
        DateTime.now().millisecondsSinceEpoch - maxAge.inMilliseconds;

    _items.removeWhere((String _, NsfwDetection d) =>
        d.detectedAtMs > 0 && d.detectedAtMs < expireBefore);

    if (_items.length > maxItems) {
      final List<MapEntry<String, NsfwDetection>> entries = _items.entries
          .toList()
        ..sort((MapEntry<String, NsfwDetection> a,
                MapEntry<String, NsfwDetection> b) =>
            a.value.detectedAtMs.compareTo(b.value.detectedAtMs));
      final int dropCount = _items.length - maxItems;
      for (int i = 0; i < dropCount; i++) {
        _items.remove(entries[i].key);
      }
    }

    final int removed = before - _items.length;
    lastPrunedCount = removed;
    if (removed > 0) {
      debugPrint('[NSFW-STORE] 🧹 淘汰 $removed 条'
          '（上限 $maxItems / 有效期 ${maxAge.inDays} 天），剩余 ${_items.length} 条');
    }
    return removed > 0;
  }

  /// 清空全部结果并立即落盘（设置页「重新扫描」用）。
  Future<void> clear() async {
    _items.clear();
    _dirty = true;
    await flush();
    _notify(immediate: true);
  }

  // ===================== 落盘 =====================

  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(_flushDebounce, () {
      flush();
    });
  }

  /// 立即落盘（应用退出、扫描结束时调用）。
  Future<void> flush() async {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (!_dirty) return;
    // 串行化，避免并发写同一文件
    final Future<void> prev = _writing ?? Future<void>.value();
    final Completer<void> gate = Completer<void>();
    _writing = gate.future;
    try {
      await prev;
      // ★ P1-4：落盘前再淘汰一次。只有 load 时淘汰的话，长时间不重启的
      //   会话里容量会一直涨；这里是"文件大小有上界"的最后一道闸。
      _prune();
      _dirty = false;
      final Map<String, dynamic> payload = <String, dynamic>{
        _kModelVerField: _modelSignature,
        _kItemsField: <String, dynamic>{
          for (final MapEntry<String, NsfwDetection> e in _items.entries)
            e.key: e.value.toJson(),
        },
      };
      final File file = File(PathHelper.nsfwDetectionsFilePath);
      final Directory dir = Directory(p.dirname(file.path));
      if (!await dir.exists()) await dir.create(recursive: true);
      // 先写临时文件再改名：避免断电/崩溃留下半截 json
      final File tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(payload), flush: true);
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
    } catch (e) {
      _dirty = true; // 写失败保留脏标记，下次重试
      debugPrint('[NSFW-STORE] 落盘失败: $e');
    } finally {
      gate.complete();
    }
  }

  // ===================== 通知去抖 =====================

  void _notify({bool immediate = false}) {
    if (immediate) {
      _notifyTimer?.cancel();
      _notifyTimer = null;
      notifyListeners();
      return;
    }
    if (_notifyTimer != null) return;
    _notifyTimer = Timer(_notifyDebounce, () {
      _notifyTimer = null;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    _notifyTimer?.cancel();
    super.dispose();
  }

  // ===================== 测试支持 =====================

  @visibleForTesting
  static void resetForTest() {
    _instance?._flushTimer?.cancel();
    _instance?._notifyTimer?.cancel();
    _instance = null;
  }

  @visibleForTesting
  Map<String, NsfwDetection> get itemsForTest => Map<String, NsfwDetection>.unmodifiable(_items);

  @visibleForTesting
  void seedForTest(String modelSignature, Map<String, NsfwDetection> items) {
    _modelSignature = modelSignature;
    _loaded = true;
    _items
      ..clear()
      ..addAll(items);
  }
}
