import 'package:flutter/material.dart';

/// UX-13: 从 library_page.dart 抽取的通用 hover 状态构建器。
///
/// 包裹子节点并提供 `isHovered` 状态，常用于管理面板子项的悬停高亮。
class PanelHoverBuilder extends StatefulWidget {
  final Widget Function(bool isHovered) builder;
  const PanelHoverBuilder({super.key, required this.builder});

  @override
  State<PanelHoverBuilder> createState() => _PanelHoverBuilderState();
}

class _PanelHoverBuilderState extends State<PanelHoverBuilder> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: widget.builder(_isHovered),
    );
  }
}
