import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../services/game_data_format.dart';
import '../../services/local_game_registry.dart';
import '../../theme/app_styles.dart';
import '../../widgets/nsfw/nsfw_image.dart';
import '../big_picture_theme.dart';
import '../services/bpm_backdrop_media.dart';
import 'bpm_interactive_wrapper.dart';
import '../../widgets/app_snack_bar.dart';

/// BPM 游戏信息编辑窗口 (v3.3)
///
/// 对应用户规范「编辑按钮 → 弹出可编辑数据窗口: 封面图、游戏标题、
/// 游戏标签、简介和截图」,UI 完全适配 PBM (Cinema) 主题。
///
/// 保存链路与桌面模式**代码级同源**:
/// - 标题: [LocalGameRegistry.updateGameTitle] (含 metaDataDir 迁移)
/// - 标签/简介: [GameDataFormat.updateGameJson]
/// - 封面: 复制新图到 metaDataDir → `cover_file` 字段 → registry 同步
/// - 截图: 复制到 `screenshots/` 子目录 → `screenshot_files` 字段
class BpmGameEditDialog extends StatefulWidget {
  final LibraryGame game;

  /// 保存成功回调 (shell 刷新面板与页面)
  final VoidCallback? onSaved;

  const BpmGameEditDialog({
    super.key,
    required this.game,
    this.onSaved,
  });

  /// BPM 主题居中弹窗入口;返回 true 表示有保存动作
  static Future<bool> show(
    BuildContext context, {
    required LibraryGame game,
    VoidCallback? onSaved,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierColor: BpmColors.deepBase.withOpacity(0.72),
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        child: BpmGameEditDialog(game: game, onSaved: onSaved),
      ),
    );
    return result ?? false;
  }

  @override
  State<BpmGameEditDialog> createState() => _BpmGameEditDialogState();
}

class _BpmGameEditDialogState extends State<BpmGameEditDialog> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _tagsCtrl;
  late final TextEditingController _descCtrl;

  /// 当前封面绝对路径
  late String? _coverPath;

  /// 当前截图相对路径列表 (screenshot_files 语义)
  late List<String> _screenshotFiles;

  /// 背景板块当前所选背景图绝对路径（null = 使用封面）。只读展示，管理在「背景」窗口
  String? _selectedBackdropPath;

  /// 背景板块当前所选背景视频（相对名 + 展示名）。只读展示
  String _selectedVideoFile = '';
  String _selectedVideoName = '';

  bool _saving = false;

  String get _metaDataDir => widget.game.metaDataDir;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.game.title);
    _tagsCtrl = TextEditingController(text: widget.game.tags.join('、'));
    _descCtrl = TextEditingController(text: widget.game.description);
    _coverPath = widget.game.coverUrl.isNotEmpty
        ? widget.game.coverUrl
        : null;
    _screenshotFiles = List<String>.from(widget.game.screenshotFiles);
    // v3.11.1：编辑窗口只展示背景板块当前所选（上传/选择/删除在详情面板「背景」窗口）
    _selectedBackdropPath =
        BpmBackdropMedia.resolveSelectedImage(widget.game.metaDataDir);
    _selectedVideoFile =
        BpmBackdropMedia.selectedVideoRaw(widget.game.metaDataDir);
    for (final v in BpmBackdropMedia.readVideos(widget.game.metaDataDir)) {
      if (v.file == _selectedVideoFile) {
        _selectedVideoName = v.name;
        break;
      }
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _tagsCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  // ============ 封面替换 ============

  Future<void> _pickCover() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    if (res == null || res.files.isEmpty || !mounted) return;
    final picked = res.files.single;
    if (picked.path == null) return;

    final ext = picked.extension?.toLowerCase() ?? 'png';
    final safeExt = (ext == 'jpg' || ext == 'jpeg' || ext == 'webp')
        ? ext
        : 'png';
    final newName = 'cover_user_${DateTime.now().millisecondsSinceEpoch}.$safeExt';
    final target = '$_metaDataDir/$newName';

    try {
      await File(picked.path!).copy(target);
    } catch (e) {
      if (mounted) _toast('封面复制失败: $e', level: NoticeLevel.error);
      return;
    }

    final ok = await GameDataFormat.updateGameJson(
        _metaDataDir, {'cover_file': newName});
    if (!mounted) return;
    if (!ok) {
      _toast('封面写入失败，请重试', level: NoticeLevel.error);
      return;
    }
    // registry 内存同步 (与桌面 _saveCoverFile 同款语义)
    widget.game.coverUrl = '$_metaDataDir/$newName';
    LocalGameRegistry.instance.notifyDataChanged();
    setState(() => _coverPath = target);
    _toast('封面已更新', level: NoticeLevel.success);
  }

  // ============ 截图管理 ============

  Future<void> _addScreenshots() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: true,
    );
    if (res == null || res.files.isEmpty || !mounted) return;

    final dir = Directory('$_metaDataDir/screenshots');
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final added = <String>[];
    final stamp = DateTime.now().millisecondsSinceEpoch;
    for (var i = 0; i < res.files.length; i++) {
      final f = res.files[i];
      if (f.path == null) continue;
      final ext = (f.extension?.toLowerCase() ?? 'png');
      final safeExt =
          (ext == 'jpg' || ext == 'jpeg' || ext == 'webp') ? ext : 'png';
      final rel = 'screenshots/user_${stamp}_$i.$safeExt';
      try {
        await File(f.path!).copy('$_metaDataDir/$rel');
        added.add(rel);
      } catch (_) {}
    }
    if (added.isEmpty || !mounted) return;

    final next = [..._screenshotFiles, ...added];
    final ok = await GameDataFormat.updateGameJson(
        _metaDataDir, {'screenshot_files': next});
    if (!mounted) return;
    if (!ok) {
      _toast('截图写入失败，请重试', level: NoticeLevel.error);
      return;
    }
    LocalGameRegistry.instance.notifyDataChanged();
    // ★ v3.19: 内存同步（updateGameJson 只写文件；不同步则详情页不刷新）
    widget.game.screenshotFiles = next;
    setState(() => _screenshotFiles = next);
    _toast('已添加 ${added.length} 张截图', level: NoticeLevel.success);
  }

  Future<void> _deleteScreenshot(String relPath) async {
    try {
      final f = File('$_metaDataDir/$relPath');
      if (f.existsSync()) await f.delete();
    } catch (_) {}
    final next = List<String>.from(_screenshotFiles)..remove(relPath);
    final ok = await GameDataFormat.updateGameJson(
        _metaDataDir, {'screenshot_files': next});
    if (!mounted) return;
    if (ok) {
      LocalGameRegistry.instance.notifyDataChanged();
      widget.game.screenshotFiles = next; // ★ v3.19: 内存同步
      setState(() => _screenshotFiles = next);
    }
  }

  // ============ 保存 ============

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);

    final newTitle = _titleCtrl.text.trim();
    final newTags = _tagsCtrl.text
        .split(RegExp(r'[、,，;；\s]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final newDesc = _descCtrl.text.trim();

    var allOk = true;

    // 1. 标题变更 → 走桌面同款迁移链路
    if (newTitle.isNotEmpty && newTitle != widget.game.title) {
      final renamed = await LocalGameRegistry.instance
          .updateGameTitle(widget.game.title, newTitle);
      if (!renamed) {
        allOk = false;
        if (mounted) _toast('标题保存失败 (可能与现有游戏重名)', level: NoticeLevel.error);
      }
    }

    // 2. 标签/简介 (标题迁移后 metaDataDir 可能已变,重新查)
    final current = newTitle != widget.game.title
        ? (LocalGameRegistry.instance.getGameByTitle(newTitle) ??
            widget.game)
        : widget.game;
    final fieldsOk = await GameDataFormat.updateGameJson(
      current.metaDataDir,
      {'tags': newTags, 'description': newDesc},
    );
    if (!fieldsOk) allOk = false;

    // ★ v3.19 响应式：同步 LocalGameRegistry 内存对象并广播。
    //   updateGameJson 只写文件不动内存 —— 不补这一步，详情页/库页/主页
    //   在下次 scan() 或重启前持续显示旧简介/旧标签（视图-模型脱节），
    //   用户感知「保存了却没变化」。与桌面 game_detail_dialog 同款语义。
    if (fieldsOk) {
      final regGame =
          LocalGameRegistry.instance.getGameByTitle(current.title);
      if (regGame != null) {
        regGame.description = newDesc;
        regGame.tags = newTags;
      }
    }

    if (!mounted) return;
    setState(() => _saving = false);
    if (allOk) {
      LocalGameRegistry.instance.notifyDataChanged();
      widget.onSaved?.call();
      Navigator.of(context).pop(true);
    } else {
      _toast('部分字段保存失败，请重试', level: NoticeLevel.error);
    }
  }

  void _toast(String msg, {NoticeLevel level = NoticeLevel.info}) =>
      AppSnackBar.show(context, level, msg);

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 860,
      constraints: const BoxConstraints(maxHeight: 640),
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
              Icon(Icons.edit_note_rounded,
                  size: 22, color: BpmColors.cherryRose),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '编辑游戏信息',
                  style: TextStyle(
                    fontFamily: AppStyles.zhDecorativeFont,
                    fontSize: 19,
                    color: BpmColors.textPrimary,
                  ),
                ),
              ),
              _iconBtn(
                  Icons.close_rounded, '关闭', () => Navigator.pop(context)),
            ],
          ),
          const SizedBox(height: 18),
          // 双栏内容
          Flexible(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 左列: 封面 + 截图管理
                SizedBox(
                  width: 280,
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _sectionLabel('封面图'),
                        const SizedBox(height: 8),
                        _coverPicker(),
                        const SizedBox(height: 16),
                        _sectionLabel('背景展示图'),
                        const SizedBox(height: 8),
                        _selectedBackdropPreview(),
                        const SizedBox(height: 16),
                        _sectionLabel('背景视频'),
                        const SizedBox(height: 8),
                        _selectedVideoPreview(),
                        const SizedBox(height: 16),
                        _sectionLabel('截图'),
                        const SizedBox(height: 8),
                        _screenshotManager(),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 20),
                // 右列: 表单
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _sectionLabel('游戏标题'),
                        const SizedBox(height: 8),
                        _textField(_titleCtrl, '标题', maxLines: 1,
                            // 🔴 v3.17 手柄适配: 弹窗打开即把焦点带进模态
                            // (shell 的 _ensureModalFocus 依赖「焦点在模态内」,
                            // 标题框不落焦则手柄方向/A 仍作用于弹窗背后的页面)
                            autofocus: true),
                        const SizedBox(height: 16),
                        _sectionLabel('游戏标签'),
                        const SizedBox(height: 8),
                        _textField(_tagsCtrl, '多个标签用、分隔', maxLines: 2),
                        const SizedBox(height: 16),
                        _sectionLabel('简介'),
                        const SizedBox(height: 8),
                        _textField(_descCtrl, '游戏简介', maxLines: 9,
                            minLines: 6),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // 底部操作行
          Row(
            children: [
              const Spacer(),
              BpmInteractiveWrapper(
                onTap: () => Navigator.pop(context),
                semanticsLabel: '取消编辑',
                borderRadius: BorderRadius.circular(10),
                child: Container(
                  height: 42,
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border:
                        Border.all(color: BpmColors.micaBorder, width: 1),
                  ),
                  child: Center(
                    child: Text('取消',
                        style: TextStyle(
                            fontFamily: AppStyles.uiFontFamily,
                            fontSize: 14,
                            color: BpmColors.textSecondary)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              BpmInteractiveWrapper(
                onTap: _saving ? null : _save,
                semanticsLabel: '保存修改',
                borderRadius: BorderRadius.circular(10),
                child: Opacity(
                  opacity: _saving ? 0.55 : 1,
                  child: Container(
                    height: 42,
                    padding: const EdgeInsets.symmetric(horizontal: 26),
                    decoration: BoxDecoration(
                      gradient: BpmColors.playButtonGradient,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Center(
                      child: Text('保存',
                          style: TextStyle(
                              fontFamily: AppStyles.uiFontFamily,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: BpmColors.playButtonForeground)),
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

  // ============ 子组件 ============

  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: TextStyle(
        fontFamily: AppStyles.uiFontFamily,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 3,
        color: BpmColors.mistBlue,
      ),
    );
  }

  Widget _textField(
    TextEditingController ctrl,
    String hint, {
    int maxLines = 1,
    int? minLines,
    bool autofocus = false,
  }) {
    return TextField(
      controller: ctrl,
      autofocus: autofocus,
      maxLines: maxLines,
      minLines: minLines,
      style: TextStyle(
          fontFamily: AppStyles.uiFontFamily,
          fontSize: 14,
          color: BpmColors.textPrimary),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(
            fontFamily: AppStyles.uiFontFamily,
            fontSize: 13,
            color: BpmColors.textMuted),
        filled: true,
        fillColor: BpmColors.micaSection,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: BpmColors.micaBorder, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide:
              BorderSide(color: BpmColors.cherryRose.withOpacity(0.6), width: 1.2),
        ),
      ),
    );
  }

  Widget _coverPicker() {
    return BpmInteractiveWrapper(
      onTap: _pickCover,
      semanticsLabel: '更换封面图',
      borderRadius: BorderRadius.circular(14),
      child: Container(
        height: 200,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BpmColors.micaBorder, width: 1),
          color: BpmColors.micaSection,
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_coverPath != null && _coverPath!.isNotEmpty)
              // NSFW 铁律: 封面类 contentKind: cover
              NsfwImage.file(
                _coverPath!,
                contentKind: NsfwContentKind.cover,
                fit: BoxFit.cover,
                decodeWidth: 560,
                child: Image.file(
                  File(_coverPath!),
                  fit: BoxFit.cover,
                  cacheWidth: 560,
                ),
              )
            else
              Center(
                child: Icon(Icons.image_outlined,
                    size: 40, color: BpmColors.textMuted),
              ),
            // 底部"点击更换"提示条
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 7),
                color: BpmColors.deepBase.withOpacity(0.72),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.swap_horiz_rounded,
                        size: 14, color: BpmColors.mistBlue),
                    const SizedBox(width: 6),
                    Text('点击更换封面',
                        style: TextStyle(
                            fontFamily: AppStyles.uiFontFamily,
                            fontSize: 12,
                            color: BpmColors.mistBlue)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 背景图当前所选（只读展示；上传 / 选择 / 删除在详情面板「背景」窗口）。
  Widget _selectedBackdropPreview() {
    final String? path = _selectedBackdropPath;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 140,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: BpmColors.micaBorder, width: 1),
            color: BpmColors.micaSection,
          ),
          child: path != null && path.isNotEmpty
              ? Image.file(File(path), fit: BoxFit.cover, cacheWidth: 560)
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.image_outlined,
                          size: 30, color: BpmColors.textMuted),
                      const SizedBox(height: 6),
                      Text('当前使用游戏封面作为背景',
                          style: TextStyle(
                              fontFamily: AppStyles.uiFontFamily,
                              fontSize: 11,
                              color: BpmColors.textMuted)),
                    ],
                  ),
                ),
        ),
        const SizedBox(height: 6),
        Text('上传 / 选择 / 删除请在详情面板「背景」窗口操作',
            style: TextStyle(
                fontFamily: AppStyles.uiFontFamily,
                fontSize: 10.5,
                color: BpmColors.textMuted)),
      ],
    );
  }

  /// 背景视频当前所选（只读展示）。
  Widget _selectedVideoPreview() {
    final bool has = _selectedVideoFile.isNotEmpty;
    final String title = has
        ? (_selectedVideoName.isEmpty ? _selectedVideoFile : _selectedVideoName)
        : '未设置背景视频';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BpmColors.micaBorder, width: 1),
        color: BpmColors.micaSection,
      ),
      child: Row(
        children: [
          Icon(Icons.movie_creation_outlined,
              size: 24,
              color: has ? BpmColors.cherryRose : BpmColors.textMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontFamily: AppStyles.uiFontFamily,
                        fontSize: 12.5,
                        color: has
                            ? BpmColors.textPrimary
                            : BpmColors.textMuted)),
                const SizedBox(height: 3),
                Text(
                    has
                        ? '选中该游戏停留 3 秒后自动播放'
                        : '上传 / 选择请在详情面板「背景」窗口',
                    style: TextStyle(
                        fontFamily: AppStyles.uiFontFamily,
                        fontSize: 10.5,
                        color: BpmColors.textMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _screenshotManager() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 220,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: BpmColors.micaBorder, width: 1),
            color: BpmColors.micaSection,
          ),
          child: _screenshotFiles.isEmpty
              ? Center(
                  child: Text('暂无截图',
                      style: TextStyle(
                          fontFamily: AppStyles.uiFontFamily,
                          fontSize: 12.5,
                          color: BpmColors.textMuted)))
              : GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 16 / 9,
                  ),
                  itemCount: _screenshotFiles.length,
                  itemBuilder: (context, i) {
                    final rel = _screenshotFiles[i];
                    return Stack(
                      fit: StackFit.expand,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          // NSFW 铁律: 截图属内容图 contentKind: image
                          child: NsfwImage.file(
                            '$_metaDataDir/$rel',
                            contentKind: NsfwContentKind.image,
                            fit: BoxFit.cover,
                            decodeWidth: 420,
                            child: Image.file(
                              File('$_metaDataDir/$rel'),
                              fit: BoxFit.cover,
                              cacheWidth: 420,
                            ),
                          ),
                        ),
                        // 删除角标（v3.17: BpmInteractiveWrapper 进焦点树 ——
                        // 裸 InkWell 不在 Flutter 焦点树里，手柄看不见它）
                        Positioned(
                          top: 4,
                          right: 4,
                          child: BpmInteractiveWrapper(
                            onTap: () => _deleteScreenshot(rel),
                            semanticsLabel: '删除该截图',
                            borderRadius: BorderRadius.circular(13),
                            child: Container(
                              width: 26,
                              height: 26,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: BpmColors.deepBase.withOpacity(0.78),
                              ),
                              child: const Icon(
                                Icons.delete_outline_rounded,
                                size: 15,
                                color: Color(0xFFE89AA8),
                              ),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
        ),
        const SizedBox(height: 10),
        BpmInteractiveWrapper(
          onTap: _addScreenshots,
          semanticsLabel: '添加截图',
          borderRadius: BorderRadius.circular(10),
          child: Container(
            height: 38,
            width: double.infinity,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: BpmColors.mistBlueBorder, width: 1),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.add_photo_alternate_outlined,
                    size: 16, color: BpmColors.mistBlue),
                const SizedBox(width: 7),
                Text('添加截图',
                    style: TextStyle(
                        fontFamily: AppStyles.uiFontFamily,
                        fontSize: 13,
                        color: BpmColors.mistBlue)),
              ],
            ),
          ),
        ),
      ],
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
