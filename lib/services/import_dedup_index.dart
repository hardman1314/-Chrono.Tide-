/// 多维排重索引
///
/// 参考 LunaBox `internal/service/import_index.go` 的 `importIndex`，实现三维排重：
/// - **byPath**：路径精确匹配 + 路径包含冲突（A⊂B 或 B⊂A）→ 硬跳过
/// - **bySource**：元数据源 ID（`source\x00id` 键）→ 硬跳过
/// - **byName**：标题同名 → 软警告（不跳过，仅提示）
///
/// 排重时序（批量导入两阶段）：
/// - 阶段 A（扫描时）：`check(path, title)` — 路径 + 标题
/// - 阶段 B（元数据抓取后）：`checkWithSource(source, id)` — 源 ID
library;

import '../utils/path_normalizer.dart';
import 'local_game_registry.dart';

/// 排重冲突类型（优先级从高到低）
enum DedupConflictKind {
  /// 路径包含冲突（A⊂B 或 B⊂A）— 硬跳过
  pathConflict,
  /// 元数据源 ID 冲突 — 硬跳过
  sourceConflict,
  /// 同名可能重复 — 软警告（不跳过）
  possibleDuplicate,
}

/// 排重判定结果
class DedupVerdict {
  /// true = 硬冲突（应跳过），false = 软警告或无冲突
  final bool isHardConflict;

  /// true = 软警告（可能重复，但不阻止导入）
  final bool hasWarning;

  /// 冲突类型（无冲突时为 null）
  final DedupConflictKind? kind;

  /// 冲突的已入库游戏名（用于提示用户）
  final String existingGameTitle;

  /// 人类可读原因
  final String reason;

  const DedupVerdict.noConflict()
      : isHardConflict = false,
        hasWarning = false,
        kind = null,
        existingGameTitle = '',
        reason = '';

  const DedupVerdict.hard(this.kind, this.existingGameTitle, this.reason)
      : isHardConflict = true,
        hasWarning = false;

  const DedupVerdict.warning(this.existingGameTitle, this.reason)
      : isHardConflict = false,
        hasWarning = true,
        kind = DedupConflictKind.possibleDuplicate;
}

/// 已入库游戏引用（轻量快照，避免持有 LibraryGame 引用）
class _ImportedRef {
  final String title;
  final String directoryPath;

  /// ★ P0-4（2026-09-16 稳定性审计）：构建索引时**预先规范化**路径。
  /// 旧实现在 `check()` 的循环里对每个 ref 现场调 `PathNormalizer.forCompare`
  /// （且 `_pathContains → isSubdirectory` 又各调 2 次），2000 候选 × 2000 库
  /// 时约 1200 万次字符串规范化，全在 UI isolate —— 扫描阶段的主 CPU 热点。
  final String normalizedPath;
  final String metadataSource;
  final String metadataSourceId;

  _ImportedRef(this.title, this.directoryPath, this.normalizedPath,
      this.metadataSource, this.metadataSourceId);
}

/// 多维排重索引
///
/// 从 [LocalGameRegistry.allGames] 一次性构建，提供统一的排重检查方法。
/// 构建 O(n)，路径包含查询 O(n)（库规模通常 < 1000，可接受），
/// 源 ID / 标题查询 O(1)。
class ImportDedupIndex {
  final List<_ImportedRef> _refs;
  final Map<String, _ImportedRef> _byPathExact;
  final Map<String, _ImportedRef> _bySource;
  final Map<String, _ImportedRef> _byName;

  ImportDedupIndex._(
      this._refs, this._byPathExact, this._bySource, this._byName);

  /// 从游戏列表构建索引（用于测试或自定义场景）
  factory ImportDedupIndex.fromGameList(List<LibraryGame> games) {
    final refs = <_ImportedRef>[];
    final byPathExact = <String, _ImportedRef>{};
    final bySource = <String, _ImportedRef>{};
    final byName = <String, _ImportedRef>{};

    for (final g in games) {
      final ref = _ImportedRef(
        g.title,
        g.directoryPath,
        PathNormalizer.forCompare(g.directoryPath),
        g.metadataSource,
        g.metadataSourceId,
      );
      refs.add(ref);
      final pathKey = PathNormalizer.forCompare(g.directoryPath);
      if (pathKey.isNotEmpty) byPathExact.putIfAbsent(pathKey, () => ref);
      final sourceKey = _sourceKey(g.metadataSource, g.metadataSourceId);
      if (sourceKey.isNotEmpty) bySource.putIfAbsent(sourceKey, () => ref);
      final nameKey = _normalizeName(g.title);
      if (nameKey.isNotEmpty) byName.putIfAbsent(nameKey, () => ref);
    }
    return ImportDedupIndex._(refs, byPathExact, bySource, byName);
  }

  /// 从 LocalGameRegistry 全量构建索引
  factory ImportDedupIndex.fromRegistry() {
    return ImportDedupIndex.fromGameList(LocalGameRegistry.instance.allGames);
  }

  /// 源键：`source\x00sourceId`（参考 LunaBox `importSourceKey`）
  /// source 和 sourceId 都 trim + lower，任一为空返回 ''
  static String _sourceKey(String source, String sourceId) {
    final s = source.trim().toLowerCase();
    final id = sourceId.trim().toLowerCase();
    if (s.isEmpty || id.isEmpty) return '';
    return '$s\x00$id';
  }

  /// 名称规范化：trim + lower（参考 LunaBox `normalizeImportName`）
  static String _normalizeName(String name) {
    return name.trim().toLowerCase();
  }

  /// 路径包含冲突检测（双向，A⊂B 或 B⊂A 都算冲突）
  ///
  /// ★ P0-4（2026-09-16 稳定性审计）：改为"已规范化路径的前缀比较"，零再规范化。
  /// 入参必须是 [PathNormalizer.forCompare] 的输出（小写、`\` 分隔、无尾斜杠）。
  static bool _coversNormalized(String a, String b) {
    if (a.isEmpty || b.isEmpty) return false;
    if (a == b) return true;
    if (b.startsWith('$a\\')) return true;
    if (a.startsWith('$b\\')) return true;
    return false;
  }

  /// 阶段 A 排重检查（扫描时调用，仅有路径和标题）
  ///
  /// 优先级：pathConflict（硬）> possibleDuplicate（软警告）
  /// 元数据源 ID 在元数据抓取后才能检查，见 [checkWithSource]
  DedupVerdict check(String path, {String? title}) {
    final pathKey = PathNormalizer.forCompare(path);

    // 1. 路径精确 + 包含冲突（硬）
    if (pathKey.isNotEmpty) {
      if (_byPathExact.containsKey(pathKey)) {
        return DedupVerdict.hard(
          DedupConflictKind.pathConflict,
          _byPathExact[pathKey]!.title,
          '路径已存在: ${_byPathExact[pathKey]!.title}',
        );
      }
      // 包含冲突：线性扫描已入库游戏（★ P0-4：用预规范化路径，零重算）
      for (final ref in _refs) {
        if (_coversNormalized(pathKey, ref.normalizedPath)) {
          return DedupVerdict.hard(
            DedupConflictKind.pathConflict,
            ref.title,
            '路径与已导入游戏重叠: ${ref.title}',
          );
        }
      }
    }

    // 2. 同名软警告（不硬跳过）
    if (title != null && title.isNotEmpty) {
      final nameKey = _normalizeName(title);
      if (nameKey.isNotEmpty && _byName.containsKey(nameKey)) {
        final ref = _byName[nameKey]!;
        // 排除路径已匹配的情况（已在上面返回）
        if (PathNormalizer.forCompare(ref.directoryPath) != pathKey) {
          return DedupVerdict.warning(
            ref.title,
            '存在同名游戏: ${ref.title}',
          );
        }
      }
    }

    return const DedupVerdict.noConflict();
  }

  /// 阶段 B 排重检查（元数据抓取后调用）
  ///
  /// 仅检查源 ID 维度。路径/名称已在扫描阶段处理。
  /// 返回 hard 表示源 ID 冲突（硬跳过）。
  DedupVerdict checkWithSource(String metadataSource, String metadataSourceId) {
    final sourceKey = _sourceKey(metadataSource, metadataSourceId);
    if (sourceKey.isEmpty) return const DedupVerdict.noConflict();
    if (_bySource.containsKey(sourceKey)) {
      return DedupVerdict.hard(
        DedupConflictKind.sourceConflict,
        _bySource[sourceKey]!.title,
        '元数据源已存在: ${_bySource[sourceKey]!.title}',
      );
    }
    return const DedupVerdict.noConflict();
  }

  /// 会话内排重：检查本批新增项之间是否路径包含重复
  /// 用于扫描结果合并时去重
  static bool sessionContains(List<String> existingPaths, String newPath) {
    final newKey = PathNormalizer.forCompare(newPath);
    if (newKey.isEmpty) return false;
    for (final p in existingPaths) {
      if (_coversNormalized(newKey, PathNormalizer.forCompare(p))) {
        return true;
      }
    }
    return false;
  }
}
