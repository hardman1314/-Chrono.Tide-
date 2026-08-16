/// 探索页筛选/排序状态
///
/// 阶段4.1：统一承载高级筛选弹窗的所有状态，支持跨页面持久化（静态变量缓存）。
///
/// 数据来源映射：
/// - 排序「最新发布」→ GameModel.created（PB 数据，始终可用）
/// - 排序「评分」「热度」→ DiscoverGameMetadata（需懒加载，缺失时回退到尾部）
/// - 排序「名称 A-Z」→ GameModel.title（PB 数据，始终可用）
/// - 排序「文件大小」→ FileSizeService（需懒加载，缺失时回退到尾部）
/// - 评分/年份筛选 → DiscoverGameMetadata（缺失数据的游戏被排除）
/// - 大小筛选 → FileSizeService（缺失数据的游戏被排除）
/// - 状态筛选 → LocalGameRegistry（始终可用）
library;

/// 排序方式（对应高级筛选弹窗的 5 个单选项）
enum DiscoverSortOption {
  /// 默认顺序（PB 返回顺序，未在 UI 中显示为独立选项）
  defaultOrder,

  /// 最新发布：按 GameModel.created 降序
  newestRelease,

  /// 评分：按元数据 rating 降序
  rating,

  /// 名称 A-Z：按 title 升序
  nameAsc,

  /// 文件大小：按文件体积降序
  fileSize,

  /// 热度：按元数据 voteCount 降序
  popularity,
}

/// 安装状态筛选
enum DiscoverInstallStatus {
  /// 全部（不过滤）
  any,

  /// 仅未入库
  notInstalled,

  /// 仅已入库
  installed,
}

/// 文件大小分桶（对应高级筛选弹窗的 4 个复选项）
enum DiscoverSizeBucket {
  /// < 500MB
  under500mb,

  /// 500MB - 2GB
  mb500to2gb,

  /// 2GB - 10GB
  gb2to10gb,

  /// > 10GB
  over10gb,
}

/// 文件大小分桶边界（字节）
extension DiscoverSizeBucketBounds on DiscoverSizeBucket {
  /// 下界（含），null 表示无下界
  int? get lowerBoundBytes {
    switch (this) {
      case DiscoverSizeBucket.under500mb:
        return null;
      case DiscoverSizeBucket.mb500to2gb:
        return 500 * 1024 * 1024;
      case DiscoverSizeBucket.gb2to10gb:
        return 2 * 1024 * 1024 * 1024;
      case DiscoverSizeBucket.over10gb:
        return 10 * 1024 * 1024 * 1024;
    }
  }

  /// 上界（不含），null 表示无上界
  int? get upperBoundBytes {
    switch (this) {
      case DiscoverSizeBucket.under500mb:
        return 500 * 1024 * 1024;
      case DiscoverSizeBucket.mb500to2gb:
        return 2 * 1024 * 1024 * 1024;
      case DiscoverSizeBucket.gb2to10gb:
        return 10 * 1024 * 1024 * 1024;
      case DiscoverSizeBucket.over10gb:
        return null;
    }
  }

  /// 显示文本
  String get displayLabel {
    switch (this) {
      case DiscoverSizeBucket.under500mb:
        return '<500MB';
      case DiscoverSizeBucket.mb500to2gb:
        return '500MB-2GB';
      case DiscoverSizeBucket.gb2to10gb:
        return '2GB-10GB';
      case DiscoverSizeBucket.over10gb:
        return '>10GB';
    }
  }

  /// 判断给定字节数是否落在该桶内
  bool contains(int bytes) {
    final lower = lowerBoundBytes;
    final upper = upperBoundBytes;
    if (lower != null && bytes < lower) return false;
    if (upper != null && bytes >= upper) return false;
    return true;
  }
}

/// 探索页筛选状态（不可变值对象）
class DiscoverFilterState {
  final DiscoverSortOption sortOption;
  final double minRating; // 0.0-10.0，0 表示不筛选
  final int? yearFrom; // null 表示无下界
  final int? yearTo; // null 表示无上界
  final Set<DiscoverSizeBucket> sizeBuckets; // 空集合表示不筛选大小
  final DiscoverInstallStatus installStatus;

  const DiscoverFilterState({
    this.sortOption = DiscoverSortOption.defaultOrder,
    this.minRating = 0.0,
    this.yearFrom,
    this.yearTo,
    this.sizeBuckets = const {},
    this.installStatus = DiscoverInstallStatus.any,
  });

  /// 默认状态（无任何筛选）
  static const DiscoverFilterState defaultState = DiscoverFilterState();

  /// 是否有任意激活的筛选/排序（用于工具栏徽标提示）
  bool get hasActiveFilters =>
      sortOption != DiscoverSortOption.defaultOrder ||
      minRating > 0 ||
      yearFrom != null ||
      yearTo != null ||
      sizeBuckets.isNotEmpty ||
      installStatus != DiscoverInstallStatus.any;

  /// 是否激活了需要元数据的筛选（评分/年份）
  /// 用于决定是否触发全量元数据后台抓取
  bool get needsMetadata =>
      sortOption == DiscoverSortOption.rating ||
      sortOption == DiscoverSortOption.popularity ||
      minRating > 0 ||
      yearFrom != null ||
      yearTo != null;

  /// 是否激活了需要文件大小的筛选/排序
  bool get needsFileSize =>
      sortOption == DiscoverSortOption.fileSize ||
      sizeBuckets.isNotEmpty;

  /// 生成已激活筛选的文字摘要（用于弹窗底部「已激活: ...」提示）
  String get activeSummary {
    final parts = <String>[];

    if (minRating > 0) {
      parts.add('评分≥${minRating.toStringAsFixed(1)}');
    }
    if (yearFrom != null || yearTo != null) {
      final from = yearFrom ?? '?';
      final to = yearTo ?? '?';
      parts.add('$from-$to');
    }
    if (sizeBuckets.isNotEmpty) {
      final labels = sizeBuckets.map((b) => b.displayLabel).join('/');
      parts.add('大小:$labels');
    }
    if (installStatus != DiscoverInstallStatus.any) {
      parts.add(installStatus == DiscoverInstallStatus.installed ? '已入库' : '未入库');
    }
    switch (sortOption) {
      case DiscoverSortOption.rating:
        parts.add('按评分排序');
        break;
      case DiscoverSortOption.popularity:
        parts.add('按热度排序');
        break;
      case DiscoverSortOption.fileSize:
        parts.add('按大小排序');
        break;
      case DiscoverSortOption.newestRelease:
        parts.add('按发布排序');
        break;
      case DiscoverSortOption.nameAsc:
        parts.add('按名称排序');
        break;
      case DiscoverSortOption.defaultOrder:
        break;
    }

    return parts.join('，');
  }

  DiscoverFilterState copyWith({
    DiscoverSortOption? sortOption,
    double? minRating,
    int? yearFrom,
    int? yearTo,
    Set<DiscoverSizeBucket>? sizeBuckets,
    DiscoverInstallStatus? installStatus,
    bool clearYearFrom = false,
    bool clearYearTo = false,
  }) {
    return DiscoverFilterState(
      sortOption: sortOption ?? this.sortOption,
      minRating: minRating ?? this.minRating,
      yearFrom: clearYearFrom ? null : (yearFrom ?? this.yearFrom),
      yearTo: clearYearTo ? null : (yearTo ?? this.yearTo),
      sizeBuckets: sizeBuckets ?? this.sizeBuckets,
      installStatus: installStatus ?? this.installStatus,
    );
  }

  /// 重置为默认状态
  DiscoverFilterState reset() => const DiscoverFilterState();

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! DiscoverFilterState) return false;
    // Set 比较用 setEquals 语义
    if (sizeBuckets.length != other.sizeBuckets.length) return false;
    if (!sizeBuckets.containsAll(other.sizeBuckets)) return false;
    return sortOption == other.sortOption &&
        minRating == other.minRating &&
        yearFrom == other.yearFrom &&
        yearTo == other.yearTo &&
        installStatus == other.installStatus;
  }

  @override
  int get hashCode => Object.hash(
        sortOption,
        minRating,
        yearFrom,
        yearTo,
        installStatus,
        Object.hashAll(sizeBuckets),
      );
}
