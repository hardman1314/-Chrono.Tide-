import 'package:flutter/material.dart';

/// BPM 二维网格焦点导航策略
///
/// 为 [BigPictureLibraryPage] 的 GridView 等二维布局提供上下左右键盘导航。
/// 基于 [Rect] 几何距离算法,而非线性索引,适配动态列数
/// (SliverGridDelegateWithMaxCrossAxisExtent)。
///
/// 继承 [ReadingOrderTraversalPolicy] 以复用 Tab / Shift+Tab 的线性阅读顺序
/// (用于 group 进入时的首个焦点定位),仅覆盖 [findFirstFocusInDirection]
/// 实现方向键的二维几何导航。
///
/// 算法:
/// 1. 收集同一 [FocusScope] 内所有可聚焦节点 (排除当前节点)
/// 2. 获取当前节点与候选节点的屏幕坐标 [Rect]
/// 3. 按方向过滤候选 (如 up: 候选中心点 y < 当前中心点 y)
/// 4. 在剩余候选中取主轴距离 + 交叉轴偏移 (权重 0.5) 之和最小者
///
/// 不循环: 到达边缘时返回 null,焦点不移动 (与桌面 ListView 行为一致)。
///
/// 使用方式:
/// ```dart
/// FocusTraversalGroup(
///   policy: FocusGridPolicy(),
///   child: GridView.builder(...),
/// )
/// ```
class FocusGridPolicy extends ReadingOrderTraversalPolicy {
  FocusGridPolicy();

  @override
  FocusNode? findFirstFocusInDirection(
    FocusNode currentNode,
    TraversalDirection direction,
  ) {
    final candidates = _collectFocusableNodes(currentNode);
    if (candidates.isEmpty) return null;

    final currentRect = _globalRect(currentNode);
    if (currentRect == null) return null;

    FocusNode? bestNode;
    double bestScore = double.infinity;

    for (final candidate in candidates) {
      final candidateRect = _globalRect(candidate);
      if (candidateRect == null) continue;
      final score = _scoreCandidate(currentRect, candidateRect, direction);
      if (score != null && score < bestScore) {
        bestScore = score;
        bestNode = candidate;
      }
    }

    return bestNode;
  }

  /// 收集同一 [FocusScope] 内所有可聚焦节点 (排除当前节点)
  List<FocusNode> _collectFocusableNodes(FocusNode currentNode) {
    final scope = currentNode.enclosingScope;
    if (scope == null) return [];
    final nodes = <FocusNode>[];
    for (final descendant in scope.descendants) {
      if (descendant.canRequestFocus && descendant != currentNode) {
        nodes.add(descendant);
      }
    }
    return nodes;
  }

  /// 获取节点的全局 [Rect],节点未挂载或无尺寸时返回 null
  Rect? _globalRect(FocusNode node) {
    final context = node.context;
    if (context == null) return null;
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox) return null;
    if (!renderObject.hasSize) return null;
    final topLeft = renderObject.localToGlobal(Offset.zero);
    return topLeft & renderObject.size;
  }

  /// 计算候选节点在指定方向的得分 (越低越优)
  /// 返回 null 表示候选不在该方向上
  double? _scoreCandidate(
    Rect current,
    Rect candidate,
    TraversalDirection direction,
  ) {
    final cc = current.center;
    final nc = candidate.center;

    switch (direction) {
      case TraversalDirection.up:
        if (nc.dy >= cc.dy) return null;
        final dy = cc.dy - nc.dy;
        final dx = (nc.dx - cc.dx).abs();
        return dy + dx * 0.5;
      case TraversalDirection.down:
        if (nc.dy <= cc.dy) return null;
        final dy = nc.dy - cc.dy;
        final dx = (nc.dx - cc.dx).abs();
        return dy + dx * 0.5;
      case TraversalDirection.left:
        if (nc.dx >= cc.dx) return null;
        final dx = cc.dx - nc.dx;
        final dy = (nc.dy - cc.dy).abs();
        return dx + dy * 0.5;
      case TraversalDirection.right:
        if (nc.dx <= cc.dx) return null;
        final dx = nc.dx - cc.dx;
        final dy = (nc.dy - cc.dy).abs();
        return dx + dy * 0.5;
    }
  }
}
