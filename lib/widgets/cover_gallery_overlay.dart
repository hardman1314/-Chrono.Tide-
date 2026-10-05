import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/game_data_format.dart';
import '../theme/app_colors.dart';
import 'nsfw/nsfw_image.dart';

/// 封面管理浮层（2026-10-04）——LunaBox 风格参照（开发者提供截图为基准）。
///
/// 交互：
/// - 全屏磨砂遮罩，图片直接浮在其上（无窗体面板）
/// - 顶栏「游戏名 - 封面管理」+ 右上角圆形关闭
/// - 底部胶囊工具条：浏览组（缩小/放大/上一张/恢复/下一张/上传）+
///   编辑组（设为竖屏封面/设为横幅封面/删除）
/// - **纯相册**：抓取入口已移除（2026-10-05 开发者要求），抓取在
///   详情窗编辑态完成
///
/// 与截图查看器（_ScreenshotLightbox）的差异：
/// ① 图片可自由拖拽（趣味性/观赏性，InteractiveViewer + 无边界 margin，
///    2026-10-05 起覆盖**全窗口**，无上下边框遮挡）
/// ② 缩放按钮仅预览用途（TransformationController，不动真实文件）
///
/// 数据来源：[GameDataFormat.listCoverGallery]（canonical cover/banner +
/// covers/ 自定义图）。所有写操作通过回调委托给宿主（详情窗口），
/// 本组件只负责展示与扫描刷新。
class CoverGalleryOverlay extends StatefulWidget {
  final String metaDataDir;
  final String gameTitle;

  /// 把某张图设为竖屏封面，返回是否成功
  final Future<bool> Function(String path) onSetVertical;

  /// 把某张图设为横幅封面，返回是否成功
  final Future<bool> Function(String path) onSetBanner;

  /// 上传自定义封面（file_picker 多选），返回成功添加数量
  final Future<int> Function() onUpload;

  /// 删除自定义封面（仅 covers/ 内文件），返回是否成功
  final Future<bool> Function(String path) onDelete;

  const CoverGalleryOverlay({
    super.key,
    required this.metaDataDir,
    required this.gameTitle,
    required this.onSetVertical,
    required this.onSetBanner,
    required this.onUpload,
    required this.onDelete,
  });

  @override
  State<CoverGalleryOverlay> createState() => _CoverGalleryOverlayState();
}

class _CoverGalleryOverlayState extends State<CoverGalleryOverlay> {
  static const double _minScale = 0.5;
  static const double _maxScale = 5.0;

  /// 图片默认显示尺寸 = 视口 × 此系数（2026-10-05 开发者要求：横幅封面
  /// 不要默认最大化占满全窗口，改为缩小居中、高度观感与竖版一致；
  /// 统一对竖图/横图生效，四周留磨砂背景。需要看大图用缩放按钮预览，
  /// 拖拽观赏不受影响。）
  static const double _contentScale = 0.7;

  final TransformationController _tc = TransformationController();
  List<CoverGalleryEntry> _entries = const [];
  int _index = 0;

  /// 忙碌标记：'' | 'upload' | 'setv' | 'setb' | 'delete' | 'fetch'
  String _busy = '';
  String? _toast;
  Timer? _toastTimer;
  Size _viewSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _tc.dispose();
    super.dispose();
  }

  CoverGalleryEntry? get _current =>
      _entries.isEmpty ? null : _entries[_index.clamp(0, _entries.length - 1)];

  String _kindLabel(CoverGalleryEntry e) =>
      e.isVertical ? '竖屏封面' : (e.isBanner ? '横幅封面' : '自定义图');

  bool _canDelete(CoverGalleryEntry e) {
    final norm = e.path.replaceAll('\\', '/');
    final prefix =
        '${widget.metaDataDir.replaceAll('\\', '/')}/${GameDataFormat.coversDirName}/';
    return norm.startsWith(prefix);
  }

  void _scan() {
    try {
      final list = GameDataFormat.listCoverGallery(widget.metaDataDir);
      if (!mounted) return;
      setState(() {
        _entries = list;
        if (_index >= _entries.length) _index = 0;
      });
    } catch (e) {
      debugPrint('[COVER-GALLERY] 扫描封面失败: $e');
    }
  }

  void _close() => Navigator.of(context).pop();

  void _next() {
    if (_entries.length < 2) return;
    setState(() {
      _index = (_index + 1) % _entries.length;
      _tc.value = Matrix4.identity();
    });
  }

  void _prev() {
    if (_entries.length < 2) return;
    setState(() {
      _index = (_index - 1 + _entries.length) % _entries.length;
      _tc.value = Matrix4.identity();
    });
  }

  /// 恢复：回初始居中状态（清除拖拽/缩放，不换图）——2026-10-05 新增，
  /// 第三按钮从「下一张」改为「恢复」
  void _resetView() {
    _tc.value = Matrix4.identity();
    setState(() {});
  }

  void _resetTransform() => _resetView();

  /// 以视口中心为锚点缩放（仅预览）
  void _zoom(double factor) {
    final current = _tc.value;
    final scale = current.getMaxScaleOnAxis();
    if (scale <= 0) return;
    final newScale = (scale * factor).clamp(_minScale, _maxScale);
    final eff = newScale / scale;
    final cx = _viewSize.width / 2;
    final cy = _viewSize.height / 2;
    final anchor = Matrix4.identity()
      ..translate(cx, cy)
      ..scale(eff)
      ..translate(-cx, -cy);
    _tc.value = anchor.multiplied(current);
  }

  void _showToast(String msg) {
    _toastTimer?.cancel();
    setState(() => _toast = msg);
    _toastTimer = Timer(const Duration(milliseconds: 1800), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  Future<void> _handleUpload() async {
    if (_busy.isNotEmpty) return;
    setState(() => _busy = 'upload');
    try {
      final n = await widget.onUpload();
      if (n > 0) {
        _scan();
        _showToast('已添加 $n 张自定义封面');
      }
    } finally {
      if (mounted) setState(() => _busy = '');
    }
  }

  Future<void> _handleSet({required bool isBanner}) async {
    if (_busy.isNotEmpty) return;
    final cur = _current;
    if (cur == null) return;
    setState(() => _busy = isBanner ? 'setb' : 'setv');
    try {
      final ok = isBanner
          ? await widget.onSetBanner(cur.path)
          : await widget.onSetVertical(cur.path);
      if (ok) {
        _scan();
        _showToast(isBanner ? '已设为横幅封面' : '已设为竖屏封面');
      } else {
        _showToast('设置失败，详见日志');
      }
    } finally {
      if (mounted) setState(() => _busy = '');
    }
  }

  Future<void> _handleDelete() async {
    if (_busy.isNotEmpty) return;
    final cur = _current;
    if (cur == null || !_canDelete(cur)) return;
    setState(() => _busy = 'delete');
    try {
      final ok = await widget.onDelete(cur.path);
      if (ok) {
        _scan();
        _showToast('已删除');
      } else {
        _showToast('删除失败，详见日志');
      }
    } finally {
      if (mounted) setState(() => _busy = '');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = AppColors.isDark;
    return Material(
      type: MaterialType.transparency,
      child: Focus(
        autofocus: true,
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): _close,
            if (_entries.length >= 2) ...{
              const SingleActivator(LogicalKeyboardKey.arrowLeft): _prev,
              const SingleActivator(LogicalKeyboardKey.arrowRight): _next,
            },
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 磨砂遮罩：单击空白关闭
              GestureDetector(
                onTap: _close,
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    color: isDark
                        ? Colors.black.withOpacity(0.50)
                        : Colors.black.withOpacity(0.35),
                  ),
                ),
              ),
              // 图片区：**全窗口**自由拖拽 + 缩放预览（2026-10-05 按开发者
              // 要求取消上下边框遮挡，顶栏/工具条浮于图片之上）
              // 🔴 必须排在顶栏/工具条**之前**（2026-10-05 修复）：原先排在
              //    顶栏之后，InteractiveViewer 全窗口吞掉指针事件，右上角
              //    关闭按钮永远点不到 → 用户无法退出相册
              Positioned.fill(child: _buildViewer()),
              // 顶栏：标题 + 圆形关闭（LunaBox 同款布局）
              Positioned(
                top: 16,
                left: 20,
                right: 16,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${widget.gameTitle} - 封面管理',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: _close,
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withOpacity(0.9),
                          ),
                          child: const Icon(Icons.close_rounded,
                              size: 18, color: Colors.black87),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // 底部胶囊工具条
              Positioned(left: 0, right: 0, bottom: 24, child: _buildToolbar()),
              // 轻量 toast（磨砂层之上，避免用被浮层遮住的 AppSnackBar）
              if (_toast != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 80,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.65),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        _toast!,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildViewer() {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewSize = Size(constraints.maxWidth, constraints.maxHeight);
        final cur = _current;
        return Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                transformationController: _tc,
                boundaryMargin: const EdgeInsets.all(double.infinity),
                minScale: _minScale,
                maxScale: _maxScale,
                panEnabled: true,
                child: Center(
                  child: cur == null
                      ? const Text(
                          '暂无封面图片\n点下方按钮上传或抓取',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Colors.white54,
                              fontSize: 14,
                              height: 1.6),
                        )
                      // 2026-10-05：ConstrainedBox 把图片默认显示框压到
                      // 视口 × _contentScale，横幅不再贴满全窗口（居中 +
                      // 四周磨砂留白）；NsfwImage 不再显式传全窗口宽高。
                      : ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: constraints.maxWidth * _contentScale,
                            maxHeight: constraints.maxHeight * _contentScale,
                          ),
                          child: GestureDetector(
                              onDoubleTap: _resetTransform,
                              child: NsfwImage.file(
                                cur.path,
                                contentKind: NsfwContentKind.cover,
                                fit: BoxFit.contain,
                                decodeWidth: 1600,
                                enableReveal: true,
                                child: Image.file(
                                  File(cur.path),
                                  fit: BoxFit.contain,
                                  cacheWidth: 1600,
                                  errorBuilder: (_, __, ___) => const Icon(
                                    Icons.broken_image_outlined,
                                    size: 48,
                                    color: Colors.white38,
                                  ),
                                ),
                              ),
                            ),
                        ),
                ),
              ),
            ),
            // 身份 + 计数 chip（2026-10-05 下移避让顶栏标题：图片层已改到
            // 顶栏之下，chip 原位置 top:10 会与「游戏名 - 封面管理」重叠）
            if (cur != null)
              Positioned(
                top: 56,
                left: 12,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.55),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    '${_kindLabel(cur)} · ${_index + 1}/${_entries.length}',
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildToolbar() {
    final cur = _current;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.55),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: Colors.white24, width: 1),
          ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── 浏览组（2026-10-05：第三按钮改为「恢复」，新增上一张/下一张）──
            _toolButton(
                icon: Icons.zoom_out_rounded,
                tip: '缩小预览',
                onTap: () => _zoom(1 / 1.25)),
            _toolButton(
                icon: Icons.zoom_in_rounded,
                tip: '放大预览',
                onTap: () => _zoom(1.25)),
            _toolButton(
              icon: Icons.chevron_left_rounded,
              tip: '上一张',
              onTap: _entries.length >= 2 ? _prev : null,
            ),
            _toolButton(
                icon: Icons.center_focus_strong_rounded,
                tip: '恢复初始居中（清除拖拽/缩放）',
                onTap: _resetView),
            _toolButton(
              icon: Icons.chevron_right_rounded,
              tip: '下一张',
              onTap: _entries.length >= 2 ? _next : null,
            ),
            _toolButton(
              icon: Icons.add_photo_alternate_outlined,
              tip: '上传自定义封面',
              busy: _busy == 'upload',
              onTap: _handleUpload,
            ),
            const SizedBox(width: 4),
            Container(width: 1, height: 20, color: Colors.white24),
            const SizedBox(width: 4),
            // ── 编辑组 ──
            _toolButton(
              icon: Icons.crop_portrait_rounded,
              tip: cur == null ? '设为竖屏封面（无选中图）' : '把当前图设为竖屏封面',
              busy: _busy == 'setv',
              onTap: cur == null ? null : () => _handleSet(isBanner: false),
            ),
            _toolButton(
              icon: Icons.crop_landscape_rounded,
              tip: cur == null ? '设为横幅封面（无选中图）' : '把当前图设为横幅封面',
              busy: _busy == 'setb',
              onTap: cur == null ? null : () => _handleSet(isBanner: true),
            ),
            _toolButton(
              icon: Icons.delete_outline_rounded,
              tip: cur == null
                  ? '删除（无选中图）'
                  : (_canDelete(cur)
                      ? '删除这张自定义封面'
                      : '标准封面不可删除（可被替换）'),
              busy: _busy == 'delete',
              onTap: (cur != null && _canDelete(cur)) ? _handleDelete : null,
            ),
          ],
        ),
        ),
      ],
    );
  }

  Widget _toolButton({
    required IconData icon,
    required String tip,
    VoidCallback? onTap,
    bool busy = false,
  }) {
    final enabled = onTap != null && _busy.isEmpty;
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: enabled ? onTap : null,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : Icon(icon,
                    size: 20,
                    color: enabled ? Colors.white : Colors.white30),
          ),
        ),
      ),
    );
  }
}
