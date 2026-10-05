import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../services/local_game_registry.dart';
import '../../theme/app_styles.dart';
import '../big_picture_theme.dart';
import '../services/bpm_backdrop_media.dart';
import 'bpm_backdrop_tuner.dart';
import 'bpm_interactive_wrapper.dart';
import '../../widgets/app_snack_bar.dart';

/// 背景管理窗口（v3.11.1）—— 详情面板「背景」按钮的新归宿。
///
/// 左右两个板块（用户 2026-09-27 规范）：
/// - **背景图**：游戏封面 + 已上传的背景展示图（可多张），单击即设为主页背景；
/// - **背景视频**：已上传的视频池（游戏OP / 动画OP / ED…，支持命名），
///   单击设为主页背景视频，「不使用」卡可回到纯静态背景；
///   板块区的「调整背景图位置」入口复用既有 [BpmBackdropTuner]。
///
/// 交互约定：
/// - **所有变更即时落盘、即时生效**（背景在弹窗后面直接变，无需保存）；
///   每次变更通过 [BpmBackgroundManagerDialog.onChanged] 通知 shell 刷新；
/// - 上传 / 删除 / 改名走 [BpmBackdropMedia] 的写 API；
///   删除素材时同时删除 `metaDataDir` 内的文件（应用自有目录，安全）；
/// - 上传新素材会**自动选中**它（用户立刻看到效果）。
class BpmBackgroundManagerDialog extends StatefulWidget {
  final LibraryGame game;

  /// 任一变更（选择 / 上传 / 删除 / 改名 / 调位置保存）后的刷新回调。
  final VoidCallback? onChanged;

  const BpmBackgroundManagerDialog({
    super.key,
    required this.game,
    this.onChanged,
  });

  /// BPM 主题居中弹窗入口。
  static Future<void> show(
    BuildContext context, {
    required LibraryGame game,
    VoidCallback? onChanged,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: BpmColors.deepBase.withOpacity(0.72),
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        child: BpmBackgroundManagerDialog(game: game, onChanged: onChanged),
      ),
    );
  }

  @override
  State<BpmBackgroundManagerDialog> createState() =>
      _BpmBackgroundManagerDialogState();
}

class _BpmBackgroundManagerDialogState
    extends State<BpmBackgroundManagerDialog> {
  List<BpmBackdropImageAsset> _images = const <BpmBackdropImageAsset>[];
  List<BpmBackdropVideoAsset> _videos = const <BpmBackdropVideoAsset>[];
  String _selectedImage = '';
  String _selectedVideo = '';
  bool _busy = false;

  String get _dir => widget.game.metaDataDir;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _images = BpmBackdropMedia.readImages(_dir);
    _videos = BpmBackdropMedia.readVideos(_dir);
    _selectedImage = BpmBackdropMedia.selectedImageRaw(_dir);
    _selectedVideo = BpmBackdropMedia.selectedVideoRaw(_dir);
  }

  // ============ 通用 ============

  /// 执行一个「写 game.json」的操作：成功则重载本地态 + 通知 shell。
  Future<void> _commit(Future<bool> op, {String? okMsg}) async {
    final bool ok = await op;
    if (!mounted) return;
    if (!ok) {
      _toast('保存失败，请重试', level: NoticeLevel.error);
      return;
    }
    setState(_reload);
    widget.onChanged?.call();
    if (okMsg != null && okMsg.isNotEmpty) _toast(okMsg, level: NoticeLevel.success);
  }

  void _toast(String msg, {NoticeLevel level = NoticeLevel.info}) =>
      AppSnackBar.show(context, level, msg);

  Future<bool> _confirm(String msg) async {
    final bool? sure = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: BpmColors.deepPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(BigPictureTheme.containerRadius),
        ),
        title: Text('确认删除',
            style: TextStyle(
                fontFamily: AppStyles.zhDecorativeFont,
                fontSize: 16,
                color: BpmColors.textPrimary)),
        content: Text(msg,
            style: TextStyle(
                fontFamily: AppStyles.uiFontFamily,
                fontSize: 13,
                color: BpmColors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text('取消',
                style: TextStyle(
                    fontFamily: AppStyles.uiFontFamily,
                    color: BpmColors.textMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('删除',
                style: TextStyle(
                    fontFamily: AppStyles.uiFontFamily,
                    color: BpmColors.dangerAccent)),
          ),
        ],
      ),
    );
    return sure ?? false;
  }

  Future<String?> _promptName({
    String? initial,
    required String title,
  }) {
    final TextEditingController ctrl =
        TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: BpmColors.deepPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(BigPictureTheme.containerRadius),
        ),
        title: Text(title,
            style: TextStyle(
                fontFamily: AppStyles.zhDecorativeFont,
                fontSize: 16,
                color: BpmColors.textPrimary)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(
              fontFamily: AppStyles.uiFontFamily,
              fontSize: 14,
              color: BpmColors.textPrimary),
          decoration: InputDecoration(
            hintText: '例如：游戏OP / 动画OP / 游戏ED',
            hintStyle: TextStyle(
                fontFamily: AppStyles.uiFontFamily,
                fontSize: 12,
                color: BpmColors.textMuted),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('取消',
                style: TextStyle(
                    fontFamily: AppStyles.uiFontFamily,
                    color: BpmColors.textMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, ctrl.text.trim()),
            child: Text('确定',
                style: TextStyle(
                    fontFamily: AppStyles.uiFontFamily,
                    color: BpmColors.mistBlue)),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteFileRel(String rel) async {
    if (rel.isEmpty || _dir.isEmpty) return;
    try {
      final File f = File('$_dir/$rel');
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }

  // ============ 上传 ============

  Future<void> _pickImages() async {
    if (_busy) return;
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: BpmBackdropMedia.imageExtensions,
      allowMultiple: true,
    );
    if (res == null || res.files.isEmpty || !mounted) return;
    setState(() => _busy = true);
    final List<BpmBackdropImageAsset> added = <BpmBackdropImageAsset>[];
    final int stamp = DateTime.now().millisecondsSinceEpoch;
    for (int i = 0; i < res.files.length; i++) {
      final String? src = res.files[i].path;
      if (src == null) continue;
      final String ext = res.files[i].extension?.toLowerCase() ?? 'png';
      final String safeExt = BpmBackdropMedia.imageExtensions.contains(ext)
          ? ext
          : 'png';
      final String rel = 'backdrop_user_${stamp}_$i.$safeExt';
      try {
        await File(src).copy('$_dir/$rel');
      } catch (_) {
        continue;
      }
      added.add(BpmBackdropImageAsset(
        file: rel,
        name: '背景图 ${_images.length + added.length + 1}',
      ));
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (added.isEmpty) {
      _toast('没有可导入的图片', level: NoticeLevel.warning);
      return;
    }
    await _commit(BpmBackdropMedia.addImages(_dir, added),
        okMsg: '已添加 ${added.length} 张背景图');
  }

  Future<void> _pickVideos() async {
    if (_busy) return;
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: BpmBackdropMedia.videoExtensions,
      allowMultiple: true,
    );
    if (res == null || res.files.isEmpty || !mounted) return;
    setState(() => _busy = true);
    final List<BpmBackdropVideoAsset> added = <BpmBackdropVideoAsset>[];
    int skipped = 0;
    final int stamp = DateTime.now().millisecondsSinceEpoch;
    for (int i = 0; i < res.files.length; i++) {
      final String? src = res.files[i].path;
      if (src == null) continue;

      // 门槛：体积 + 文件头（不合格直接跳过，最后汇总提示）
      try {
        if (File(src).lengthSync() > BpmBackdropMedia.maxVideoBytes) {
          skipped++;
          continue;
        }
      } catch (_) {}
      if (!BpmBackdropMedia.looksLikeMp4(src)) {
        skipped++;
        continue;
      }

      final String rel = 'video_user_${stamp}_$i.mp4';
      try {
        await File(src).copy('$_dir/$rel');
      } catch (_) {
        continue;
      }
      added.add(BpmBackdropVideoAsset(
        file: rel,
        name: '视频 ${_videos.length + added.length + 1}',
      ));
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (added.isEmpty) {
      _toast(
          skipped > 0
              ? '已跳过 $skipped 个不合格文件（需 MP4 且 ≤500MB）'
              : '没有可导入的视频',
          level: NoticeLevel.warning);
      return;
    }
    await _commit(BpmBackdropMedia.addVideos(_dir, added),
        okMsg: skipped > 0
            ? '已添加 ${added.length} 个视频（跳过 $skipped 个不合格）'
            : '已添加 ${added.length} 个视频');
  }

  // ============ 素材操作 ============

  Future<void> _deleteImage(BpmBackdropImageAsset a) async {
    final bool sure = await _confirm(
        '删除背景图「${a.name.isEmpty ? a.file : a.name}」？文件将一并删除。');
    if (!sure || !mounted) return;
    final bool ok = await BpmBackdropMedia.removeImage(_dir, a.file);
    if (!ok) {
      _toast('删除失败，请重试', level: NoticeLevel.error);
      return;
    }
    await _deleteFileRel(a.file);
    if (!mounted) return;
    setState(_reload);
    widget.onChanged?.call();
    _toast('已删除', level: NoticeLevel.success);
  }

  Future<void> _deleteVideo(BpmBackdropVideoAsset v) async {
    final bool sure = await _confirm(
        '删除视频「${v.name.isEmpty ? v.file : v.name}」？文件将一并删除。');
    if (!sure || !mounted) return;
    final bool ok = await BpmBackdropMedia.removeVideo(_dir, v.file);
    if (!ok) {
      _toast('删除失败，请重试', level: NoticeLevel.error);
      return;
    }
    await _deleteFileRel(v.file);
    if (!mounted) return;
    setState(_reload);
    widget.onChanged?.call();
    _toast('已删除', level: NoticeLevel.success);
  }

  Future<void> _renameImage(BpmBackdropImageAsset a) async {
    final String? name = await _promptName(
        initial: a.name, title: '重命名背景图');
    if (name == null || name.isEmpty || name == a.name || !mounted) return;
    await _commit(BpmBackdropMedia.renameImage(_dir, a.file, name));
  }

  Future<void> _renameVideo(BpmBackdropVideoAsset v) async {
    final String? name =
        await _promptName(initial: v.name, title: '重命名视频');
    if (name == null || name.isEmpty || name == v.name || !mounted) return;
    await _commit(BpmBackdropMedia.renameVideo(_dir, v.file, name));
  }

  Future<void> _openPositionTuner() async {
    await BpmBackdropTuner.show(
      context,
      title: widget.game.title,
      metaDataDir: _dir,
      // 预览图用「当前所选背景图」（无则封面）—— 与主页 backdrop 一致
      imagePath: BpmBackdropMedia.resolveSelectedImage(_dir) ??
          widget.game.coverUrl,
      onSaved: () => widget.onChanged?.call(),
    );
    if (mounted) setState(() {});
  }

  // ============ UI ============

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1020,
      height: 640,
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(),
          const SizedBox(height: 14),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _imageSection()),
                const SizedBox(width: 24),
                Expanded(child: _videoSection()),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _footer(),
        ],
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        Icon(Icons.wallpaper_rounded, size: 22, color: BpmColors.cherryRose),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            '背景管理 · ${widget.game.title}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: AppStyles.zhDecorativeFont,
              fontSize: 18,
              color: BpmColors.textPrimary,
            ),
          ),
        ),
        _miniBtn(Icons.close_rounded, () => Navigator.pop(context),
            size: 16),
      ],
    );
  }

  Widget _sectionHeader(
      {required IconData icon,
      required String title,
      required String hint,
      required VoidCallback onUpload,
      required String uploadLabel}) {
    return Row(
      children: [
        Icon(icon, size: 16, color: BpmColors.mistBlue),
        const SizedBox(width: 6),
        Text(title,
            style: TextStyle(
                fontFamily: AppStyles.zhDecorativeFont,
                fontSize: 14,
                color: BpmColors.textPrimary)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(hint,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontFamily: AppStyles.uiFontFamily,
                  fontSize: 10.5,
                  color: BpmColors.textMuted)),
        ),
        BpmInteractiveWrapper(
          onTap: onUpload,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: BpmColors.micaBorder, width: 1),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.add_rounded, size: 13, color: BpmColors.mistBlue),
              const SizedBox(width: 3),
              Text(uploadLabel,
                  style: TextStyle(
                      fontFamily: AppStyles.uiFontFamily,
                      fontSize: 11,
                      color: BpmColors.mistBlue)),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _imageSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          icon: Icons.wallpaper_rounded,
          title: '背景图',
          hint: '单击选择 · 当前：${_selectedImage.isEmpty ? '游戏封面' : _selectedImageName}',
          onUpload: _pickImages,
          uploadLabel: '上传图片',
        ),
        const SizedBox(height: 10),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _coverCard(),
                for (final BpmBackdropImageAsset a in _images)
                  _imageCard(a),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _videoSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(
          icon: Icons.movie_creation_outlined,
          title: '背景视频',
          hint:
              '单击选择 · 当前：${_selectedVideo.isEmpty ? '不使用' : _selectedVideoName}',
          onUpload: _pickVideos,
          uploadLabel: '上传视频',
        ),
        const SizedBox(height: 10),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _noVideoCard(),
                for (final BpmBackdropVideoAsset v in _videos)
                  _videoCard(v),
              ],
            ),
          ),
        ),
      ],
    );
  }

  String get _selectedImageName {
    for (final BpmBackdropImageAsset a in _images) {
      if (a.file == _selectedImage) {
        return a.name.isEmpty ? a.file : a.name;
      }
    }
    return _selectedImage;
  }

  String get _selectedVideoName {
    for (final BpmBackdropVideoAsset v in _videos) {
      if (v.file == _selectedVideo) {
        return v.name.isEmpty ? v.file : v.name;
      }
    }
    return _selectedVideo;
  }

  // ---- 卡片 ----

  Widget _coverCard() {
    final String cover = widget.game.coverUrl;
    final bool hasCover = cover.isNotEmpty && File(cover).existsSync();
    return _selectableCard(
      selected: _selectedImage.isEmpty,
      onTap: () => _commit(BpmBackdropMedia.selectImage(_dir, '')),
      width: 108,
      height: 150,
      label: '封面',
      child: hasCover
          ? Image.file(File(cover), fit: BoxFit.cover, cacheWidth: 240)
          : Center(
              child: Icon(Icons.image_outlined,
                  size: 30, color: BpmColors.textMuted)),
    );
  }

  Widget _imageCard(BpmBackdropImageAsset a) {
    final String path = '$_dir/${a.file}';
    return _selectableCard(
      selected: _selectedImage == a.file,
      onTap: () => _commit(BpmBackdropMedia.selectImage(_dir, a.file)),
      width: 108,
      height: 150,
      label: a.name.isEmpty ? '背景图' : a.name,
      onDelete: () => _deleteImage(a),
      onRename: () => _renameImage(a),
      child: File(path).existsSync()
          ? Image.file(File(path), fit: BoxFit.cover, cacheWidth: 240)
          : Center(
              child: Icon(Icons.broken_image_outlined,
                  size: 26, color: BpmColors.textMuted)),
    );
  }

  Widget _noVideoCard() {
    return _selectableCard(
      selected: _selectedVideo.isEmpty,
      onTap: () => _commit(BpmBackdropMedia.selectVideo(_dir, '')),
      width: 128,
      height: 128,
      label: '不使用',
      child: Center(
        child: Icon(Icons.videocam_off_outlined,
            size: 30, color: BpmColors.textMuted),
      ),
    );
  }

  Widget _videoCard(BpmBackdropVideoAsset v) {
    final String path = '$_dir/${v.file}';
    String sizeText = '';
    try {
      final int bytes = File(path).lengthSync();
      sizeText = bytes >= 1024 * 1024
          ? '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB'
          : '${(bytes / 1024).toStringAsFixed(0)} KB';
    } catch (_) {}

    return _selectableCard(
      selected: _selectedVideo == v.file,
      onTap: () => _commit(BpmBackdropMedia.selectVideo(_dir, v.file)),
      width: 128,
      height: 128,
      label: v.name.isEmpty ? v.file : v.name,
      subLabel: sizeText,
      onDelete: () => _deleteVideo(v),
      onRename: () => _renameVideo(v),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.play_circle_outline_rounded,
                size: 34,
                color: _selectedVideo == v.file
                    ? BpmColors.cherryRose
                    : BpmColors.textMuted),
            const SizedBox(height: 6),
            Text(sizeText,
                style: TextStyle(
                    fontFamily: AppStyles.uiFontFamily,
                    fontSize: 10,
                    color: BpmColors.textMuted)),
          ],
        ),
      ),
    );
  }

  Widget _selectableCard({
    required bool selected,
    required VoidCallback onTap,
    required double width,
    required double height,
    required Widget child,
    required String label,
    String? subLabel,
    VoidCallback? onDelete,
    VoidCallback? onRename,
  }) {
    return Container(
      width: width,
      margin: const EdgeInsets.only(right: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BpmInteractiveWrapper(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              height: height,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  width: selected ? 2 : 1,
                  color: selected
                      ? BpmColors.cherryRose
                      : BpmColors.micaBorder,
                ),
                color: BpmColors.micaSection,
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  child,
                  if (onDelete != null || onRename != null)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Row(
                        children: [
                          if (onRename != null)
                            _miniBtn(Icons.edit_outlined, onRename),
                          if (onDelete != null) ...[
                            const SizedBox(width: 4),
                            _miniBtn(Icons.delete_outline_rounded,
                                onDelete,
                                color: BpmColors.dangerAccent),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: AppStyles.uiFontFamily,
              fontSize: 10.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
              color: selected ? BpmColors.cherryRose : BpmColors.textMuted,
            ),
          ),
          if (subLabel != null && subLabel.isNotEmpty)
            Text(
              subLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: AppStyles.uiFontFamily,
                fontSize: 9.5,
                color: BpmColors.textMuted,
              ),
            ),
        ],
      ),
    );
  }

  Widget _miniBtn(IconData icon, VoidCallback onTap,
      {double size = 12, Color? color}) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: BpmColors.deepBase.withOpacity(0.85),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(icon, size: size, color: color ?? BpmColors.textSecondary),
      ),
    );
  }

  Widget _footer() {
    return Row(
      children: [
        BpmInteractiveWrapper(
          onTap: _openPositionTuner,
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: BpmColors.micaBorder, width: 1),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.tune_rounded, size: 15, color: BpmColors.mistBlue),
              const SizedBox(width: 6),
              Text('调整背景图位置',
                  style: TextStyle(
                      fontFamily: AppStyles.uiFontFamily,
                      fontSize: 12,
                      color: BpmColors.mistBlue)),
            ]),
          ),
        ),
        if (_busy) ...[
          const SizedBox(width: 14),
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ],
        const Spacer(),
        BpmInteractiveWrapper(
          onTap: () => Navigator.pop(context),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 22, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              gradient: BpmColors.playButtonGradient,
            ),
            child: Text('完成',
                style: TextStyle(
                    fontFamily: AppStyles.uiFontFamily,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: BpmColors.playButtonForeground)),
          ),
        ),
      ],
    );
  }
}
