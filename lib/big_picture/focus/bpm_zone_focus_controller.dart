import 'package:flutter/widgets.dart';

/// BPM 分层板块焦点系统 — 三级焦点状态机（2026-09-20 用户规范）
///
/// 板块层级：
/// - **一级（全局 3 块）**：左侧导航栏 [BpmZoneId.rail] / 顶部状态栏
///   [BpmZoneId.topBar] / 中间主内容区 [BpmZoneId.stage]
/// - **二级（页面内）**：主页 = 搜索栏 / 操作按钮 / 卡片列表；
///   库页 = 顶部筛选操作 / 卡片列表
///
/// 两种模式：
/// - [BpmFocusMode.zone]：焦点选中**整个板块**（方向键在层级内切换板块）；
/// - [BpmFocusMode.component]：进入板块内部，方向键切换**板块内组件**，
///   边缘停止、**不跨板块**（须先 B 退出组件模式）。
///
/// 设计分工（🔴 勿混）：
/// - **本文件只做状态与转移**，不碰 Flutter 焦点树 —— 纯逻辑，可脱离 widget 单测；
/// - 每个板块的「焦点域」（FocusScope + 遍历策略）由 `BpmFocusDomain` 注册进来，
///   本控制器只持有它们的引用；
/// - 板块高亮由 `BpmFocusZone` 读 [BpmZoneFocusScope] 绘制。
///
/// ⚠️ 手柄与鼠标/键盘的分工：**板块模式只在手柄侧生效**。鼠标/键盘一旦把焦点
/// 落到某个板块内的组件上，shell 的焦点监听会调 [focusIntoZone] 把状态切回
/// 组件模式（焦点环随之恢复），因此「保留原有鼠标操作」不受影响。
enum BpmFocusLevel {
  /// 一级：全局 3 块
  global,

  /// 二级：当前页面内的板块
  page,
}

/// 焦点模式
enum BpmFocusMode {
  /// 板块选择模式（高亮整个板块容器）
  zone,

  /// 组件操作模式（高亮单个 UI 组件）
  component,
}

/// 板块标识
enum BpmZoneId {
  // ── 一级 ──
  /// 左侧导航栏
  rail,

  /// 顶部状态栏
  topBar,

  /// 中间主内容区（进入后下钻为页面二级板块）
  stage,

  // ── 主页二级 ──
  /// 搜索栏板块（搜索胶囊 + 继续游戏 chips）
  homeSearch,

  /// 操作按钮板块（启动 / 详情）
  homeActions,

  /// 游戏卡片列表板块（底部 shelf）
  homeShelf,

  // ── 库页二级 ──
  /// 顶部筛选操作板块（搜索 / 排序 / 管理收藏夹 / 收藏夹 chips）
  libraryTools,

  /// 游戏卡片列表板块（海报墙）
  libraryWall,

  /// 详情面板（覆盖式，不属于任何层级；打开时独占焦点）
  panel,
}

/// 一级板块列表（顺序即空间邻接的语义顺序：左 → 上 → 中）
const List<BpmZoneId> kBpmGlobalZones = <BpmZoneId>[
  BpmZoneId.rail,
  BpmZoneId.topBar,
  BpmZoneId.stage,
];

/// 主页二级板块（**最后一个必须是卡片列表**：页面落点靠它）
const List<BpmZoneId> kBpmHomeZones = <BpmZoneId>[
  BpmZoneId.homeSearch,
  // v3.14: homeActions（操作按钮板块）已随「主页右侧按钮区移除」删除
  BpmZoneId.homeShelf,
];

/// 库页二级板块（**最后一个必须是卡片列表**）
const List<BpmZoneId> kBpmLibraryZones = <BpmZoneId>[
  BpmZoneId.libraryTools,
  BpmZoneId.libraryWall,
];

/// 板块所属层级（[BpmZoneId.panel] 不属于任何层级 → null）
BpmFocusLevel? bpmLevelOfZone(BpmZoneId zone) {
  switch (zone) {
    case BpmZoneId.rail:
    case BpmZoneId.topBar:
    case BpmZoneId.stage:
      return BpmFocusLevel.global;
    case BpmZoneId.panel:
      return null;
    case BpmZoneId.homeSearch:
    case BpmZoneId.homeActions:
    case BpmZoneId.homeShelf:
    case BpmZoneId.libraryTools:
    case BpmZoneId.libraryWall:
      return BpmFocusLevel.page;
  }
}

/// 一个板块的「焦点域」：独立 `FocusScopeNode` + 该域使用的遍历策略。
///
/// 🔴 **为什么必须是 FocusScope，而不是 `FocusTraversalGroup`**
///
/// Flutter 3.24.3 的方向遍历有两个入口，语义天差地别（源码实证）：
/// - `FocusTraversalPolicy.inDirection(node, dir)` —— **框架方向键走的就是这条**：
///   只在 `node.nearestScope.traversalDescendants` 里按几何筛选候选，
///   候选为空即返回 false（**不移动**＝边缘停）；还会优先留在同一个 Scrollable 内。
/// - `FocusTraversalPolicy.findFirstFocusInDirection(node, dir)` ——
///   **完全不做方向过滤**：把整个 scope 的可聚焦节点按前缘排序后返回第一个。
///   实测（3 个不同位置的节点）：从左侧节点按「下」得到的是**屏幕最上方**那个节点，
///   按「右」得到的是**最左边**那个节点（＝它自己）。
///
/// v3.8–v3.10 一直误用了后者 → 真机表现为「侧边栏永远选不中『我的库』」
/// （↓ 跳到顶部栏）、「主页卡片列表左右键换不了游戏」。
///
/// 而 `inDirection` 只认 `nearestScope`，因此要让「板块内移动、边界停、
/// 不跨板块」真正成立，每个板块必须有自己的 **FocusScope**。
class BpmZoneDomain {
  BpmZoneDomain({
    required this.zone,
    required this.scope,
    required this.policy,
  });

  /// 该域代表的板块
  final BpmZoneId zone;

  /// 板块自己的焦点域（本域内组件的 `nearestScope` 即它）
  final FocusScopeNode scope;

  /// 本域使用的遍历策略（每个域一个实例：策略内部有方向历史栈）
  final FocusTraversalPolicy policy;

  /// 域是否已挂载（未挂载时不能 requestFocus）
  bool get isMounted => scope.context != null;
}

/// 三级焦点状态机。
///
/// 所有转移方法都会在状态**确实变化**时 `notifyListeners()`；
/// 面板相关状态（`zone == panel`）由 [openPanel] / [closePanel] 维护，
/// 关面板后恢复到打开前的 (level, zone)。
class BpmZoneFocusController extends ChangeNotifier {
  BpmFocusLevel _level = BpmFocusLevel.global;
  BpmFocusMode _mode = BpmFocusMode.zone;
  BpmZoneId _zone = BpmZoneId.rail;
  int _page = 0;

  /// v3.19 焦点体系总开关 —— 默认**停用**。
  ///
  /// 用户规范（2026-09-29）：手柄是「有焦点」的焦点型操作，键鼠是
  /// 无焦点区域划分的大屏操作。因此进 BPM **不得**默认进入焦点模式
  /// （旧实现 `_mode` 初始即 zone → 板块高亮一进 BPM 就出现）。
  /// 只有「① 手柄已连接 ② 产生真实手柄输入」依次满足后才由 shell 调
  /// [enableFocusMode] 启用；键鼠介入 → [disableFocusMode]。
  bool _enabled = false;

  /// 各板块注册进来的焦点域
  final Map<BpmZoneId, BpmZoneDomain> _domains = <BpmZoneId, BpmZoneDomain>{};

  BpmFocusLevel? _panelPrevLevel;
  BpmZoneId? _panelPrevZone;

  // ============ 只读状态 ============

  BpmFocusLevel get level => _level;

  BpmFocusMode get mode => _mode;

  BpmZoneId get zone => _zone;

  /// 0 = 主页，1 = 我的库
  int get page => _page;

  /// 焦点体系是否启用（仅手柄模式下为 true；键鼠模式下板块划分不出现）
  bool get enabled => _enabled;

  /// 手柄首次真实输入 → 启用焦点体系并回到板块模式。
  ///
  /// 已启用且已在板块模式时为幂等空操作（不重复广播）。
  void enableFocusMode() {
    if (_enabled && _mode == BpmFocusMode.zone) return;
    _enabled = true;
    _mode = BpmFocusMode.zone;
    notifyListeners();
  }

  /// 键鼠介入 / 手柄断开 → 停用焦点体系：板块高亮消失、组件焦点环
  /// 恢复常规显示（Flutter 焦点本身不动，Tab/Enter 行为不变）。
  void disableFocusMode() {
    if (!_enabled) return;
    _enabled = false;
    _mode = BpmFocusMode.zone;
    notifyListeners();
  }

  bool get isZoneMode => _enabled && _mode == BpmFocusMode.zone;

  bool get isComponentMode => _enabled && _mode == BpmFocusMode.component;

  bool get isPanelOpen => _zone == BpmZoneId.panel;

  /// 当前页面的二级板块
  List<BpmZoneId> get pageZones =>
      _page == 0 ? kBpmHomeZones : kBpmLibraryZones;

  /// 当前层级下的板块列表（一级 = 3 块，二级 = 页内板块）
  List<BpmZoneId> get currentZones =>
      _level == BpmFocusLevel.global ? kBpmGlobalZones : pageZones;

  /// 卡片列表板块（页面落点，即 [pageZones] 最后一项）
  BpmZoneId get cardListZone => pageZones.last;

  // ============ 焦点域注册与查询 ============

  /// `BpmFocusDomain` 挂载时登记（同一板块重复登记以最后一次为准）
  void registerDomain(BpmZoneDomain domain) {
    _domains[domain.zone] = domain;
  }

  /// `BpmFocusDomain` 卸载时注销。
  ///
  /// 🔴 必须比对 scope 身份：页面切换时新旧板块可能短暂同时挂载
  /// （`AnimatedSwitcher` 过渡期内两页共存），若直接按 zone 删除，
  /// 新页刚登记的域会被旧页的 dispose 误删。
  void unregisterDomain(BpmZoneId zone, FocusScopeNode scope) {
    if (identical(_domains[zone]?.scope, scope)) _domains.remove(zone);
  }

  BpmZoneDomain? domainOf(BpmZoneId zone) => _domains[zone];

  /// 焦点节点所属板块（由 `nearestScope` 反查）。
  ///
  /// 对话框 / 动作表等模态路由有各自的 FocusScope，不在本表内 → 返回 null，
  /// 于是「模态打开时不改板块状态」天然成立。
  BpmZoneId? zoneOfScope(FocusScopeNode? scope) {
    if (scope == null) return null;
    for (final entry in _domains.entries) {
      if (identical(entry.value.scope, scope)) return entry.key;
    }
    return null;
  }

  /// 进入某板块时的焦点目标。
  ///
  /// 优先该域的 `focusedChild`（**由框架维护＝天然"上次落点"位置记忆**），
  /// 否则域内第一个可聚焦组件；域未挂载或域内无组件 → null。
  FocusNode? entryFocusOf(BpmZoneId zone) {
    final domain = _domains[zone];
    if (domain == null || !domain.isMounted) return null;
    final node = domain.policy.findFirstFocus(domain.scope);
    if (node == null || identical(node, domain.scope)) return null;
    return node;
  }

  /// 把焦点送进某板块。
  ///
  /// 经 `policy.requestFocusCallback` 落焦 —— 与框架 Tab / 方向键同源，
  /// 因此**自带滚动到可见**（`Scrollable.ensureVisible`），不会把焦点丢到
  /// 视口外的卡片上。返回是否成功落焦。
  bool focusEntryOf(BpmZoneId zone) {
    final domain = _domains[zone];
    final node = entryFocusOf(zone);
    if (domain == null || node == null) return false;
    domain.policy.requestFocusCallback(node);
    return true;
  }

  // ============ 状态转移 ============

  /// A 键（板块模式）。返回**需要把焦点交给哪个板块**（null = 无需动焦点）。
  ///
  /// - 一级 rail / topBar → 进入组件模式，焦点交给该板块；
  /// - 一级 stage → 下钻到二级板块层，高亮该页第一个二级板块（仍为板块模式）；
  /// - 二级板块 → 进入组件模式，焦点交给该板块。
  BpmZoneId? confirm() {
    if (_mode == BpmFocusMode.component) return null; // 组件模式由 shell 激活
    if (_level == BpmFocusLevel.global) {
      if (_zone == BpmZoneId.stage) {
        _level = BpmFocusLevel.page;
        _zone = pageZones.first;
        notifyListeners();
        return null;
      }
      _mode = BpmFocusMode.component;
      notifyListeners();
      return _zone;
    }
    _mode = BpmFocusMode.component;
    notifyListeners();
    return _zone;
  }

  /// B 键。返回是否消费了本次回退（false = shell 可继续处理，如关面板/关模态）。
  ///
  /// - 组件模式 → 板块模式（层级不变，板块不变）
  /// - 二级板块模式 → 一级板块模式（高亮回到 rail）
  /// - 一级板块模式 → 不消费（保持「B 不误退大屏」的既有约定）
  bool back() {
    if (_mode == BpmFocusMode.component) {
      if (_zone == BpmZoneId.panel) return false; // 面板由 shell 处理
      _mode = BpmFocusMode.zone;
      notifyListeners();
      return true;
    }
    if (_level == BpmFocusLevel.page) {
      _level = BpmFocusLevel.global;
      _zone = BpmZoneId.rail;
      notifyListeners();
      return true;
    }
    return false;
  }

  /// 方向键（仅板块模式有效）。返回是否发生了切换。
  ///
  /// - 一级：按空间邻接在 rail / topBar / stage 间切换，无邻接 → 停（不跨级）
  /// - 二级：↑/↓ 在页内板块间切换，首/尾 → 停（不跨级）；←/→ 无操作
  bool moveZone(TraversalDirection dir) {
    if (_mode != BpmFocusMode.zone) return false;
    if (_level == BpmFocusLevel.global) {
      final next = _nextGlobalZone(_zone, dir);
      if (next == null || next == _zone) return false;
      _zone = next;
      notifyListeners();
      return true;
    }
    final zones = pageZones;
    final index = zones.indexOf(_zone);
    if (index < 0) return false;
    var next = index;
    if (dir == TraversalDirection.up) next = index - 1;
    if (dir == TraversalDirection.down) next = index + 1;
    if (next == index || next < 0 || next >= zones.length) return false;
    _zone = zones[next];
    notifyListeners();
    return true;
  }

  /// 一级板块的空间邻接表（rail 在左 / topBar 在上 / stage 在右下方）
  static BpmZoneId? _nextGlobalZone(BpmZoneId from, TraversalDirection dir) {
    switch (from) {
      case BpmZoneId.rail:
        if (dir == TraversalDirection.up) return BpmZoneId.topBar;
        if (dir == TraversalDirection.right) return BpmZoneId.stage;
        return null;
      case BpmZoneId.topBar:
        if (dir == TraversalDirection.down) return BpmZoneId.stage;
        if (dir == TraversalDirection.left) return BpmZoneId.rail;
        return null;
      case BpmZoneId.stage:
        if (dir == TraversalDirection.up) return BpmZoneId.topBar;
        if (dir == TraversalDirection.left) return BpmZoneId.rail;
        return null;
      default:
        return null;
    }
  }

  /// 页面切换 / 进入页面后的落点：**选中卡片列表二级板块 + 组件模式**。
  ///
  /// 对应规范第 2 条「左侧导航栏按 A 进入页面后，自动选中游戏卡片列表
  /// 二级板块，自动进入组件模式」。
  BpmZoneId landOnCardList({required int page}) {
    _page = page;
    _level = BpmFocusLevel.page;
    _zone = cardListZone;
    _mode = BpmFocusMode.component;
    notifyListeners();
    return _zone;
  }

  /// 鼠标/键盘把焦点落进某板块 → 切到组件模式（板块高亮随之取消，
  /// 组件焦点环恢复）。这是「手柄板块模式」与「鼠标/键盘」的边界。
  void focusIntoZone(BpmZoneId id) {
    if (id == BpmZoneId.panel) return; // 面板自有生命周期
    final targetLevel = bpmLevelOfZone(id);
    var changed = false;
    if (id != _zone) {
      _zone = id;
      changed = true;
    }
    if (targetLevel != null && targetLevel != _level) {
      _level = targetLevel;
      changed = true;
    }
    if (_mode != BpmFocusMode.component) {
      _mode = BpmFocusMode.component;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  /// 退出板块选择模式（**保留**当前层级与板块）。
  ///
  /// 用于鼠标 / 键盘介入：此时不再绘制板块高亮，回到改动前「只高亮单个组件」
  /// 的观感。与 [back] 的区别是不做层级回退。
  void exitZoneMode() {
    if (_mode == BpmFocusMode.component) return;
    _mode = BpmFocusMode.component;
    notifyListeners();
  }

  /// 详情面板打开：独占焦点（组件模式 + zone=panel），并快照上一层状态
  void openPanel() {
    _panelPrevLevel = _level;
    _panelPrevZone = _zone;
    _zone = BpmZoneId.panel;
    _mode = BpmFocusMode.component;
    notifyListeners();
  }

  /// 详情面板关闭：恢复到打开前的 (level, zone)，模式统一回组件模式
  void closePanel() {
    final lv = _panelPrevLevel;
    final zn = _panelPrevZone;
    _panelPrevLevel = null;
    _panelPrevZone = null;
    _level = lv ?? _level;
    _zone = zn ?? _zone;
    _mode = BpmFocusMode.component;
    notifyListeners();
  }

  /// 测试/外部强制复位（不触发已注册焦点域变更）
  @visibleForTesting
  void resetForTest({
    BpmFocusLevel level = BpmFocusLevel.global,
    BpmFocusMode mode = BpmFocusMode.zone,
    BpmZoneId zone = BpmZoneId.rail,
    int page = 0,
  }) {
    _level = level;
    _mode = mode;
    _zone = zone;
    _page = page;
    notifyListeners();
  }
}

/// 把焦点状态机注入 BPM 子树。
///
/// `FocusGlow` 据此在**板块模式**下抑制组件焦点环与焦点缩放 ——
/// 否则会同时出现「板块整体高亮」和「单个组件高亮」，违反规范第 6 条。
/// `BpmFocusDomain` 也从这里取控制器完成焦点域注册。
///
/// 🔴 `maybeOf` 返回 null（即不在 BPM 子树内）时，`FocusGlow` 必须与改动前
/// 行为**逐位一致**，以保证既有测试与桌面模式零回归。
class BpmZoneFocusScope extends InheritedNotifier<BpmZoneFocusController> {
  const BpmZoneFocusScope({
    super.key,
    required BpmZoneFocusController controller,
    required super.child,
  }) : super(notifier: controller);

  static BpmZoneFocusController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<BpmZoneFocusScope>()
      ?.notifier;

  /// 当前是否处于板块选择模式；无 scope 时返回 null（不干预）
  static bool? maybeZoneMode(BuildContext context) {
    final controller = maybeOf(context);
    return controller?.isZoneMode;
  }
}
