import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart';

import '../../services/game_data_format.dart';
import '../../theme/app_styles.dart';
import '../../widgets/nsfw/nsfw_image.dart';
import '../big_picture_theme.dart';
import 'bpm_interactive_wrapper.dart';
import 'bpm_smart_cover_image.dart';

/// 背景图裁剪参数 (v3.3 背景调整器数据模型)
///
/// 持久化于 game.json 自定义字段:
/// - `bpm_backdrop_x` / `bpm_backdrop_y`: 对齐偏移 (-1..1, 同 [Alignment])
/// - `bpm_backdrop_zoom`: 缩放 (1.0..2.5, 1.0 = 不缩放)
///
/// 任一字段存在即视为「手动模式」,[BpmSmartAlignedImage.manualAlign]
/// 优先于自动显著性裁剪;字段缺失时回退自动裁剪。
class BpmBackdropAdjustment {
  final double x;
  final double y;
  final double zoom;

  const BpmBackdropAdjustment({
    required this.x,
    required this.y,
    required this.zoom,
  });

  Alignment get alignment => Alignment(x, y);

  /// 从 game.json 原始 map 解析 (任一字段缺失返回 null → 自动模式)
  static BpmBackdropAdjustment? fromMap(Map<String, dynamic> m) {
    final x = m['bpm_backdrop_x'];
    final y = m['bpm_backdrop_y'];
    if (x == null || y == null) return null;
    return BpmBackdropAdjustment(
      x: (x as num).toDouble().clamp(-1.0, 1.0),
      y: (y as num).toDouble().clamp(-1.0, 1.0),
      zoom: m['bpm_backdrop_zoom'] == null
          ? 1.0
          : (m['bpm_backdrop_zoom'] as num).toDouble().clamp(1.0, 2.5),
    );
  }

  Map<String, double> toFields() => {
        'bpm_backdrop_x': x,
        'bpm_backdrop_y': y,
        'bpm_backdrop_zoom': zoom,
      };

  /// 读取 (metaDataDir/game.json);无手动参数返回 null
  static BpmBackdropAdjustment? read(String metaDataDir) {
    if (metaDataDir.isEmpty) return null;
    try {
      final f = File('$metaDataDir/${GameDataFormat.gameJsonFileName}');
      if (!f.existsSync()) return null;
      final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      return BpmBackdropAdjustment.fromMap(m);
    } catch (_) {
      return null;
    }
  }

  /// 保存 (updateGameJson merge 写入)
  static Future<bool> save(String metaDataDir, BpmBackdropAdjustment adj) {
    return GameDataFormat.updateGameJson(metaDataDir, adj.toFields());
  }

  /// 清除手动参数 → 回退自动显著性裁剪
  static Future<bool> reset(String metaDataDir) {
    return GameDataFormat.updateGameJson(metaDataDir, const {
      'bpm_backdrop_x': null,
      'bpm_backdrop_y': null,
      'bpm_backdrop_zoom': null,
    });
  }
}

/// 背景图调整器 (v3.3)
///
/// 解决「系统自动截取无法满足用户审美」: 拖动定位 + 缩放滑条 +
/// 实时预览,保存后全屏 backdrop 立即应用手动对齐。
///
/// 交互:
/// - 在预览区拖动 → 调整焦点位置 (x/y ∈ -1..1)
/// - 滑条 → 缩放 (放大后可拖动的范围更大,同 cover 语义)
/// - 「恢复自动」→ 清除手动参数,回退智能显著性裁剪
class BpmBackdropTuner extends StatefulWidget {
  final String title;
  final String? imagePath;

  /// 封面路径所在元数据目录 (game.json 读写)
  final String metaDataDir;

  /// 保存成功回调 (shell 重建 backdrop)
  final VoidCallback? onSaved;

  const BpmBackdropTuner({
    super.key,
    required this.title,
    required this.metaDataDir,
    this.imagePath,
    this.onSaved,
  });

  /// BPM 主题居中弹窗入口
  static Future<void> show(
    BuildContext context, {
    required String title,
    required String metaDataDir,
    String? imagePath,
    VoidCallback? onSaved,
  }) {
    return showDialog(
      context: context,
      barrierColor: BpmColors.deepBase.withOpacity(0.72),
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        child: BpmBackdropTuner(
          title: title,
          metaDataDir: metaDataDir,
          imagePath: imagePath,
          onSaved: onSaved,
        ),
      ),
    );
  }

  @override
  State<BpmBackdropTuner> createState() => _BpmBackdropTunerState();
}

class _BpmBackdropTunerState extends State<BpmBackdropTuner> {
  double _x = 0;
  double _y = 0;
  double _zoom = 1.0;

  /// 是否已有手动参数 (决定「恢复自动」按钮显隐)
  bool _hasManual = false;

  @override
  void initState() {
    super.initState();
    final saved = BpmBackdropAdjustment.read(widget.metaDataDir);
    if (saved != null) {
      _x = saved.x;
      _y = saved.y;
      _zoom = saved.zoom;
      _hasManual = true;
    }
  }

  void _onPan(DragUpdateDetails d, Size size) {
    setState(() {
      // 拖满整个预览宽度 = 对齐值变化 2.0 (-1 → 1)
      _x = (_x + d.delta.dx / size.width * 2.0).clamp(-1.0, 1.0);
      _y = (_y + d.delta.dy / size.height * 2.0).clamp(-1.0, 1.0);
      _hasManual = true;
    });
  }

  Future<void> _save() async {
    final ok = await BpmBackdropAdjustment.save(
      widget.metaDataDir,
      BpmBackdropAdjustment(x: _x, y: _y, zoom: _zoom),
    );
    if (!mounted) return;
    if (ok) {
      BpmSmartAlignedImage.evictAlignmentCache(widget.imagePath ?? '');
      widget.onSaved?.call();
      Navigator.of(context).pop();
    }
  }

  Future<void> _resetAuto() async {
    final ok = await BpmBackdropAdjustment.reset(widget.metaDataDir);
    if (!mounted) return;
    if (ok) {
      BpmSmartAlignedImage.evictAlignmentCache(widget.imagePath ?? '');
      widget.onSaved?.call();
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 760,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: BpmColors.deepPanel,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: BpmColors.micaBorder, width: 1),
        boxShadow: [
          BoxShadow(
            color: BpmColors.deepBase.withOpacity(0.6),
            blurRadius: 48,
            offset: const Offset(0, 24),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题行
          Row(
            children: [
              Icon(Icons.tune_rounded,
                  size: 20, color: BpmColors.mistBlue),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '调整背景图 — $widget.title',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: AppStyles.zhDecorativeFont,
                    fontSize: 19,
                    color: BpmColors.textPrimary,
                  ),
                ),
              ),
              _iconBtn(Icons.close_rounded, '关闭', () => Navigator.pop(context)),
            ],
          ),
          const SizedBox(height: 16),
          // 预览区 (16:9,拖动调整焦点)
          LayoutBuilder(builder: (context, box) {
            final h = box.maxWidth * 9 / 16;
            return GestureDetector(
              onPanUpdate: (d) => _onPan(d, Size(box.maxWidth, h)),
              child: MouseRegion(
                cursor: SystemMouseCursors.move,
                child: Container(
                  width: double.infinity,
                  height: h,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border:
                        Border.all(color: BpmColors.micaBorder, width: 1),
                  ),
                  child: widget.imagePath != null &&
                          widget.imagePath!.isNotEmpty
                      ? Transform.scale(
                          scale: _zoom,
                          child: Image.file(
                            File(widget.imagePath!),
                            fit: BoxFit.cover,
                            alignment: Alignment(_x, _y),
                            cacheWidth: 1600,
                            errorBuilder: (_, __, ___) =>
                                _previewFallback(),
                          ),
                        )
                      : _previewFallback(),
                ),
              ),
            );
          }),
          const SizedBox(height: 10),
          // 提示行
          Row(
            children: [
              Icon(Icons.info_outline_rounded,
                  size: 13, color: BpmColors.textMuted),
              const SizedBox(width: 6),
              Text(
                '拖动预览图调整焦点位置 · 放大后可拖动范围更大',
                style: TextStyle(
                  fontFamily: AppStyles.uiFontFamily,
                  fontSize: 12,
                  color: BpmColors.textMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // 缩放滑条
          Row(
            children: [
              SizedBox(
                width: 64,
                child: Text(
                  '缩放',
                  style: TextStyle(
                    fontFamily: AppStyles.uiFontFamily,
                    fontSize: 13.5,
                    color: BpmColors.textSecondary,
                  ),
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(
                    activeTrackColor: BpmColors.cherryRose,
                    inactiveTrackColor: BpmColors.micaBorder,
                    thumbColor: BpmColors.cherryRose,
                    overlayColor:
                        BpmColors.cherryRose.withOpacity(0.18),
                    trackHeight: 3,
                  ),
                  child: Slider(
                    value: _zoom,
                    min: 1.0,
                    max: 2.5,
                    onChanged: (v) => setState(() {
                      _zoom = v;
                      _hasManual = true;
                    }),
                  ),
                ),
              ),
              SizedBox(
                width: 52,
                child: Text(
                  '${_zoom.toStringAsFixed(2)}×',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontFamily: AppStyles.uiFontFamily,
                    fontSize: 12.5,
                    color: BpmColors.mistBlue,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          // 操作行
          Row(
            children: [
              // 恢复自动 (仅已有手动参数时显示)
              if (_hasManual)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: BpmInteractiveWrapper(
                    onTap: _resetAuto,
                    semanticsLabel: '恢复自动裁剪',
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      height: 42,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                            color: BpmColors.mistBlueBorder, width: 1),
                      ),
                      child: Center(
                        child: Text(
                          '恢复自动',
                          style: TextStyle(
                            fontFamily: AppStyles.uiFontFamily,
                            fontSize: 13.5,
                            color: BpmColors.mistBlue,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              const Spacer(),
              // 保存
              BpmInteractiveWrapper(
                onTap: _save,
                semanticsLabel: '保存背景调整',
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  height: 42,
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  decoration: BoxDecoration(
                    gradient: BpmColors.playButtonGradient,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(
                    child: Text(
                      '保存',
                      style: TextStyle(
                        fontFamily: AppStyles.uiFontFamily,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: BpmColors.playButtonForeground,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _previewFallback() {
    return Container(
      color: BpmColors.deepBase,
      child: Center(
        child: Text(
          '暂无背景图',
          style: TextStyle(
            fontFamily: AppStyles.uiFontFamily,
            fontSize: 13,
            color: BpmColors.textMuted,
          ),
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, String label, VoidCallback onTap) {
    return BpmInteractiveWrapper(
      onTap: onTap,
      semanticsLabel: label,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: BpmColors.micaBorder, width: 1),
        ),
        child: Icon(icon, size: 17, color: BpmColors.textSecondary),
      ),
    );
  }
}
