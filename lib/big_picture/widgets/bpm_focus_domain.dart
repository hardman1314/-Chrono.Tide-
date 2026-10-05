import 'package:flutter/widgets.dart';

import '../focus/bpm_zone_focus_controller.dart';

/// BPM 板块焦点域容器（v3.10.1）
///
/// 给一个板块装上**独立的 `FocusScopeNode` + 独立遍历策略**。
///
/// 🔴 这是「板块内移动、边界停、不跨板块」能成立的前提：
/// Flutter 的方向遍历（`FocusTraversalPolicy.inDirection`，框架方向键走的就是它）
/// 只在 `currentNode.nearestScope.traversalDescendants` 里找候选 —— 只有把板块
/// 包成独立 FocusScope，候选集合才恰好等于「本板块内的组件」，
/// 找不到候选时 `inDirection` 返回 false ＝ **边缘停**。
/// 详细对比见 [BpmZoneDomain] 的文档。
///
/// 用法：把板块内容包一层即可，**不需要传任何 FocusNode / GlobalKey** ——
/// 进入板块时的落点由控制器用 `policy.findFirstFocus(scope)` 现算：
/// 优先域内 `focusedChild`（框架维护，天然就是「上次落点」的位置记忆），
/// 否则域内第一个可聚焦组件。
///
/// ⚠️ 已知副作用（可接受）：`FocusScope` 会把 Tab 遍历限制在板块内。
/// BPM 是 10-foot UI，键盘用户主要靠鼠标与 Ctrl+F，域内 Tab 循环反而更符合预期。
class BpmFocusDomain extends StatefulWidget {
  /// 本容器代表的板块
  final BpmZoneId zone;

  /// 板块内容
  final Widget child;

  const BpmFocusDomain({
    super.key,
    required this.zone,
    required this.child,
  });

  @override
  State<BpmFocusDomain> createState() => _BpmFocusDomainState();
}

class _BpmFocusDomainState extends State<BpmFocusDomain> {
  /// 本板块的焦点域（自持 → 可直接交给控制器，无需 GlobalKey 反查）
  late final FocusScopeNode _scope =
      FocusScopeNode(debugLabel: 'BPM:${widget.zone.name}');

  /// 本域使用的遍历策略。
  ///
  /// 每个域一个实例：策略内部维护方向历史栈（用于「反方向回到上一个位置」），
  /// 共享实例会让不同板块互相污染历史。
  late final FocusTraversalPolicy _policy = ReadingOrderTraversalPolicy();

  BpmZoneFocusController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncRegistration();
  }

  @override
  void didUpdateWidget(covariant BpmFocusDomain oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.zone != widget.zone) _syncRegistration();
  }

  void _syncRegistration() {
    final controller = BpmZoneFocusScope.maybeOf(context);
    if (identical(controller, _controller)) return;
    _controller?.unregisterDomain(widget.zone, _scope);
    _controller = controller;
    controller?.registerDomain(
      BpmZoneDomain(zone: widget.zone, scope: _scope, policy: _policy),
    );
  }

  @override
  void dispose() {
    _controller?.unregisterDomain(widget.zone, _scope);
    _controller = null;
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FocusScope(
      node: _scope,
      child: FocusTraversalGroup(policy: _policy, child: widget.child),
    );
  }
}
