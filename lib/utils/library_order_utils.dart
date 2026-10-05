/// 库页显示顺序的纯函数工具（不含 Widget / IO 依赖，便于单元测试）。
///
/// ## 存在的理由
///
/// 库页原先的实现把「起拖索引」和「落点索引」用在了不同的列表上：
/// 索引取自**筛选后的渲染网格**（`library_page.dart` 卡片位置），
/// 收尾却套用**全量列表 `_games`**（`_endDrag`）并立即落盘 prefs。
/// 后果：在收藏夹 / 搜索 / 会社筛选视图下拖拽，会把全局手动顺序静默写乱。
///
/// 本文件把重排与「该写哪一层顺序」的判定固化为纯函数，
/// 使「渲染列表 = 操作列表」与「视图隔离」两条语义可以被单测锁死，
/// 而不是靠调用点自觉。方案文档：
/// `docs/DEV/features/library_page_experience_overhaul_plan.md` §4.1。
library;

/// 重排模式
enum DisplayReorderMode {
  /// 交换两个位置（拖到目标卡上并停留确认）
  swap,

  /// 插入式（移除源项后插入到目标位置）
  insert,
}

/// 拖拽结果应写入哪一层顺序（门控矩阵的取值域）
enum ReorderTarget {
  /// 不响应拖拽
  none,

  /// 全局手动顺序（库页「全部游戏」视图）
  globalOrder,

  /// 收藏夹内独立顺序（收藏夹视图）
  collectionOrder,
}

/// 判定当前视图下拖拽的归属层（唯一判定入口）。
///
/// 规则：
/// - 非手动排序 → [ReorderTarget.none]：自动排序下顺序由排序规则决定，
///   手工调整无持久语义；
/// - 搜索 / 会社筛选激活 → [ReorderTarget.none]：此时可见集合是全量列表的
///   残缺子集，在子集内调整顺序既无稳定语义，也正是历史上写乱全局顺序的场景；
/// - 收藏夹视图 → [ReorderTarget.collectionOrder]（该能力未启用时为 `none`）；
/// - 其余情况 → [ReorderTarget.globalOrder]。
///
/// [collectionReorderEnabled] 供分阶段落地使用：收藏夹内独立排序能力上线前
/// 传 `false`，收藏夹视图与筛选视图一样禁拖。
ReorderTarget resolveReorderTarget({
  required bool manualSort,
  required bool hasSearch,
  required bool hasDeveloperFilter,
  required bool inCollection,
  bool collectionReorderEnabled = true,
}) {
  if (!manualSort) return ReorderTarget.none;
  if (hasSearch || hasDeveloperFilter) return ReorderTarget.none;
  if (inCollection) {
    return collectionReorderEnabled
        ? ReorderTarget.collectionOrder
        : ReorderTarget.none;
  }
  return ReorderTarget.globalOrder;
}

/// 交换 [from] 与 [to] 位置上的元素，返回**新列表**（绝不改动 [source]）。
///
/// 索引越界或两者相同 → 返回 [source] 的等值副本。
List<T> swapDisplayItems<T>(List<T> source, int from, int to) {
  final list = List<T>.from(source);
  if (from == to) return list;
  if (from < 0 || from >= list.length) return list;
  if (to < 0 || to >= list.length) return list;
  final temp = list[from];
  list[from] = list[to];
  list[to] = temp;
  return list;
}

/// 插入式重排：把 [from] 处元素移动到 [to] 位置，返回**新列表**。
///
/// 语义与库页原实现保持一致：先移除源项，`from < to` 时目标索引需左移一位
/// （移除后其后元素整体前移），再 clamp 到 `[0, length]`。
/// [to] 允许等于原列表长度（移动到末尾）。
List<T> insertDisplayItem<T>(List<T> source, int from, int to) {
  final list = List<T>.from(source);
  if (list.isEmpty) return list;
  if (from < 0 || from >= list.length) return list;

  var target = to;
  if (target < 0) target = 0;
  if (target > list.length) target = list.length;

  final item = list.removeAt(from);
  if (from < target) target--;
  target = target.clamp(0, list.length);
  list.insert(target, item);
  return list;
}

/// 统一入口：按 [mode] 重排显示列表，返回**新列表**。
List<T> reorderDisplayList<T>(
  List<T> source,
  int from,
  int to, {
  DisplayReorderMode mode = DisplayReorderMode.insert,
}) {
  switch (mode) {
    case DisplayReorderMode.swap:
      return swapDisplayItems(source, from, to);
    case DisplayReorderMode.insert:
      return insertDisplayItem(source, from, to);
  }
}

/// 依据路由目标计算「新的全局顺序列表」——**全局顺序的唯一写入门**。
///
/// - [ReorderTarget.globalOrder]：显示列表即全量列表（仅此一种情况允许拖拽），
///   直接采用 [reorderedDisplay]；
/// - 其余目标（`none` / `collectionOrder`）：全局顺序**不得**被改动，
///   原样返回 [globalList]。
///
/// 把守卫放进 API 而不是调用点，是为了让「在收藏夹/筛选视图拖拽写乱全局顺序」
/// 这个 P0 在构造上不可能再发生。
List<T> resolveGlobalOrderAfterDrag<T>({
  required List<T> globalList,
  required List<T> reorderedDisplay,
  required ReorderTarget target,
}) {
  if (target == ReorderTarget.globalOrder) return reorderedDisplay;
  return globalList;
}

/// 按收藏夹内自定义顺序 [order] 重排成员列表 [members]，返回新列表。
///
/// 语义（与全局手动顺序刻意相反，因为收藏夹顺序是"局部覆盖"）：
/// - 已登记成员按 [order] 排；
/// - **未登记者排在已登记者之后**（全局手动顺序里新游是顶置，这里不顶置——
///   新加入收藏夹的成员不应打乱用户已排好的收藏夹内部次序）；
/// - 未登记者之间保持 [members] 传入时的相对次序（往往是全局顺序），
///   用显式兜底键实现，不依赖 `List.sort` 的稳定性；
/// - [order] 中的未知/重复键被忽略与去重（保留首次位置）。
List<T> applyCollectionOrder<T>(
  List<T> members,
  List<String> order, {
  required String Function(T) keyOf,
}) {
  if (order.isEmpty || members.length < 2) return List<T>.from(members);

  final orderIndex = <String, int>{};
  for (var i = 0; i < order.length; i++) {
    orderIndex.putIfAbsent(order[i], () => i);
  }
  final baseIndex = <String, int>{};
  for (var i = 0; i < members.length; i++) {
    baseIndex[keyOf(members[i])] = i;
  }

  final result = List<T>.from(members);
  result.sort((a, b) {
    final ia = orderIndex[keyOf(a)];
    final ib = orderIndex[keyOf(b)];
    if (ia != null && ib != null) return ia.compareTo(ib);
    if (ia != null) return -1; // 已登记的在前
    if (ib != null) return 1;
    return (baseIndex[keyOf(a)] ?? 0).compareTo(baseIndex[keyOf(b)] ?? 0);
  });
  return result;
}
