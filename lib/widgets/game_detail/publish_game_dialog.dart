import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../models/game_model.dart';
import '../../services/game_publish_service.dart';
import '../../services/game_resource_service.dart';
import '../../services/metadata_fetcher.dart';
import '../app_snack_bar.dart';
import '../nsfw/nsfw_image.dart';
import 'dark_surface.dart';
import 'upload_resource_dialog.dart';

/// 「发布 Galgame」窗口 —— 发布三步中的**第 2 步（游戏资料）+ 第 3 步（上传资源）**，
/// 按开发者要求做成**同一窗口内分页**（方案 §8.10-决策 5）。
///
/// ## 与「上传」的关系（方案 §8.7①）
///
/// | 类型 | 前提 | 入口 | 写入 |
/// |---|---|---|---|
/// | 资源投稿 | 作品**已存在**于探索库 | 探索详情页 →【上传】 | 仅 `game_resources` |
/// | **作品发布** | 作品**不存在**于探索库 | 探索大厅 → 文档板块 →【发布】 | 先 `games`，再 `game_resources` |
///
/// 第 2 步的字段与「添加页」一致，可选**一键抓取元数据**回填；
/// 第 3 步直接复用 [UploadResourceDialog]（`embedded: true`），
/// 即「B 的第三步 = 探索详情页上传」这条需求原话的实现方式。
///
/// ## 提交顺序（方案 §8.7②）
///
/// ```
/// 1) POST games          origin=user / owner=<uid> / review_status=pending
/// 2) POST game_resources createCommunityResource(game: <上一步返回的 id>)
/// ```
/// ⚠️ 第 2 步失败**不回滚**作品 —— PB 无跨集合事务，且「作品在、资源待补」是
/// 合法状态（与官方作品可以有作品无资源同构），回滚反而会丢掉用户填好的整份资料。
class PublishGameDialog extends StatefulWidget {
  const PublishGameDialog({
    super.key,
    required this.initialTitle,
    this.onClose,
    this.editing,
  });

  /// 第 1 步（文档板块内联判重）传入的游戏名，作为 `title` 初值
  final String initialTitle;

  final VoidCallback? onClose;

  /// **编辑模式**：预填该作品的资料，底部改为「保存修改」，提交走
  /// [GamePublishService.updateMyGame]（服务端规则：`review_status != "approved"`
  /// 才可编辑，满足时 PB 返 **404**；调用方须先用 [GameModel.canEditAsOwner] 预判）。
  final GameModel? editing;

  /// 弹出窗口。返回 `true` 表示已成功提交（调用方据此刷新列表）。
  static Future<bool?> show({
    required BuildContext context,
    required String initialTitle,
  }) {
    return showDarkCenteredDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PublishGameDialog(
        initialTitle: initialTitle,
        onClose: () => Navigator.of(ctx).maybePop(),
      ),
    );
  }

  /// 编辑既有作品（【我的】→ 我发布的游戏 → 编辑资料）
  static Future<bool?> showEdit({
    required BuildContext context,
    required GameModel game,
  }) {
    return showDarkCenteredDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PublishGameDialog(
        initialTitle: game.title,
        editing: game,
        onClose: () => Navigator.of(ctx).maybePop(),
      ),
    );
  }

  @override
  State<PublishGameDialog> createState() => _PublishGameDialogState();
}

class _PublishGameDialogState extends State<PublishGameDialog> {
  final _resKey = GlobalKey<UploadResourceDialogState>();

  final _titleCtrl = TextEditingController();
  final _jpCtrl = TextEditingController();
  final _enCtrl = TextEditingController();
  final _tcCtrl = TextEditingController();
  final _devCtrl = TextEditingController();
  final _dateCtrl = TextEditingController();
  final _ratingCtrl = TextEditingController();
  final _voteCtrl = TextEditingController();
  final _descCtrl = TextEditingController();

  final Set<String> _tags = {};
  String? _coverPath;

  /// 横幅封面（可选，2026-10-05）：横向高清封面，用于大图场景
  /// （下载入库后作 BPM 背景/主页大图；探索库数据层 bannerUrl）
  String? _bannerPath;
  final List<String> _screenshots = [];
  String _metaSource = '';

  /// 0 = 游戏资料，1 = 上传资源
  int _step = 0;
  bool _fetching = false;
  bool _submitting = false;
  String? _error;

  /// `games.tags` 的合法取值（PB select 字段，传值必须在此列表内，否则 400）。
  /// 取自线上集合定义 `.workbuddy/pb_backup/…/games.json`。
  static const List<String> _tagOptions = [
    '恋爱', '后宫', '纯爱', '拔作', '悬疑', '日常', '校园', 'key社', 'yuzi社',
    '废萌', '推理', '科幻', '催泪', '视觉小说', '轮回', '致郁', '猎奇', '胃痛',
    'NTR', '燃作', '鬼畜', '策略', '电波', '哲学', '艺术', '粉丝向', '人生',
    '恐怖', '惊悚', '末日', '虚无', '悲剧', '囚禁', '独立游戏', '模拟经营',
    '暴力', '奇幻', '黑色幽默', '黑暗', '乐队', '解密', '冒险', '十二神器',
    '伪娘', '重口味', 'Meta', '女仆', '高甜度', '竞技', '萌拔', '师生', '泣系',
    '都市', '青春', '萝莉', 'R18', '乡村', 'RPG', 'ACT', 'SLG', '像素', '医院',
    '家庭', '百合', '西式', '童话', '王道', '十二魔器', '友情', '同居', '血腥',
    '全年龄', '古典', '强奸', '中二', '剧情', '兄妹', '古代', '三国题材',
    '日本战国题材', '狂气', '治愈', '救赎', '民俗', '宿命', '甜恋', '妹系',
    '三角', '抉择', '伦理', '旅行', '修罗场', '青梅',
  ];

  static const int _maxScreenshots = 6;

  bool get _isEditing => widget.editing != null;

  @override
  void initState() {
    super.initState();
    final g = widget.editing;
    if (g == null) {
      _titleCtrl.text = widget.initialTitle;
      return;
    }
    _titleCtrl.text = g.title;
    _jpCtrl.text = g.originalTitle;
    _enCtrl.text = g.englishTitle;
    _tcCtrl.text = g.traditionalChineseTitle;
    _devCtrl.text = g.developer;
    _dateCtrl.text = g.releaseDate;
    _descCtrl.text = g.description;
    _metaSource = g.metaSource;
    if (g.rating != null && g.rating! > 0) {
      _ratingCtrl.text = g.rating!.toStringAsFixed(1);
    }
    if (g.voteCount != null && g.voteCount! > 0) {
      _voteCtrl.text = g.voteCount!.toString();
    }
    // 只回填 PB 的合法取值（历史数据可能含已从 values 移除的标签）
    _tags.addAll(g.tags.where(_tagOptions.contains).take(14));
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _jpCtrl.dispose();
    _enCtrl.dispose();
    _tcCtrl.dispose();
    _devCtrl.dispose();
    _dateCtrl.dispose();
    _ratingCtrl.dispose();
    _voteCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  // ==================== 骨架 ====================

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.of(context).size.height - 96;
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: DarkPalette.uploadWidth,
        maxHeight: height.clamp(320.0, 2400.0),
      ),
      child: DarkShell(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(),
            Flexible(
              child: _step == 0
                  ? SingleChildScrollView(
                      clipBehavior: Clip.hardEdge,
                      padding: const EdgeInsets.fromLTRB(22, 0, 22, 0),
                      child: _buildGameForm(),
                    )
                  : SingleChildScrollView(
                      clipBehavior: Clip.hardEdge,
                      padding: const EdgeInsets.fromLTRB(22, 0, 22, 0),
                      child: UploadResourceDialog(
                        key: _resKey,
                        embedded: true,
                        gameTitle: _titleCtrl.text.trim(),
                        onSubmit: _doPublish,
                      ),
                    ),
            ),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 20, 18, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _isEditing ? '编辑作品资料' : '发布 Galgame',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFE2E2E7),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _isEditing
                      ? '修改后重新进入审核队列。已通过审核的作品不能再修改。'
                      : '探索库中还没有这部作品，提交后将连同资源一起送审，通过后进入探索库。',
                  style: const TextStyle(
                    fontSize: 12,
                    color: DarkPalette.textMuted,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                if (!_isEditing)
                  Row(
                    children: [
                      _stepPill(0, '① 游戏资料'),
                      const SizedBox(width: 6),
                      const Icon(Icons.chevron_right_rounded,
                          size: 15, color: DarkPalette.textDim),
                      const SizedBox(width: 6),
                      _stepPill(1, '② 上传资源'),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          DarkCloseButton(onTap: _handleClose, size: 26),
        ],
      ),
    );
  }

  Widget _stepPill(int index, String label) {
    final active = _step == index;
    final done = _step > index;
    final color = active
        ? DarkPalette.primaryBlue
        : (done ? DarkPalette.green : DarkPalette.textDim);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(active ? 0.16 : 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withOpacity(active ? 0.5 : 0.22)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: active ? FontWeight.w700 : FontWeight.w500,
          color: color,
        ),
      ),
    );
  }

  Widget _buildFooter() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 18),
      child: Row(
        children: [
          DarkGhostButton(
            label: '取消',
            onTap: _submitting ? null : _handleClose,
            foreground: const Color(0xFFD5D5DC),
            fontSize: 13,
          ),
          const Spacer(),
          if (_isEditing)
            DarkPrimaryButton(
              label: '保存修改',
              busy: _submitting,
              onTap: _saveEdit,
              background: DarkPalette.primaryBlue,
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
              radius: 11,
              fontSize: 13,
            )
          else if (_step == 0) ...[
            DarkPrimaryButton(
              label: '下一步',
              onTap: _handleNext,
              background: DarkPalette.primaryBlue,
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
              radius: 11,
              fontSize: 13,
            ),
          ] else ...[
            DarkGhostButton(
              label: '上一步',
              onTap: _submitting ? null : () => setState(() => _step = 0),
              foreground: const Color(0xFFD5D5DC),
              fontSize: 13,
            ),
            const SizedBox(width: 6),
            DarkGhostButton(
              label: '仅提交作品',
              onTap: _submitting ? null : _publishGameOnly,
              foreground: DarkPalette.textMuted,
              fontSize: 12,
            ),
            const SizedBox(width: 6),
            DarkPrimaryButton(
              label: '提交发布',
              busy: _submitting,
              onTap: _submitResource,
              background: DarkPalette.primaryBlue,
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
              radius: 11,
              fontSize: 13,
            ),
          ],
        ],
      ),
    );
  }

  // ==================== 第 2 步：游戏资料 ====================

  Widget _buildGameForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 18),
        _metaBar(),
        const SizedBox(height: 18),
        // 2026-10-02 UI 优化（二次调整，用户拍板）：左侧封面 + 右侧「游戏名
        // 输入区」整体 —— 主名 / 日语原名 / 英语名 / 繁中名同属游戏名，归组
        // 为一个竖排输入区（原日/英/繁散在封面下方两行，视觉割裂）；封面
        // 高度随输入区撑满，加大预览面积。点击卡片选图 → 直接预览 → 右上角
        // 删除；封面**必选**（新建模式；编辑模式不强制、未重选则保留原封面）。
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _coverPickerCard(),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  children: [
                    DarkField(
                      label: '游戏名称',
                      required: true,
                      helper: '即探索库卡片上的中文标题',
                      child: DarkTextInput(controller: _titleCtrl, hint: '例如 千恋＊万花'),
                    ),
                    const SizedBox(height: 12),
                    DarkField(
                      label: '日语原名（可选）',
                      child: DarkTextInput(controller: _jpCtrl, hint: '千恋＊万花'),
                    ),
                    const SizedBox(height: 12),
                    DarkField(
                      label: '英语名（可选）',
                      child: DarkTextInput(controller: _enCtrl, hint: 'Senren * Banka'),
                    ),
                    const SizedBox(height: 12),
                    DarkField(
                      label: '繁中名（可选）',
                      child: DarkTextInput(controller: _tcCtrl, hint: '千戀＊萬花'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // 横幅封面（可选，2026-10-05）：横向高清封面，下载入库后用于
        // BPM 背景 / 主页大图等横版场景；缺失时那些场景自动回退竖封面。
        _bannerPickerCard(),
        const SizedBox(height: 18),
        DarkField(
          label: '游戏简介（可选）',
          helper: '支持 Markdown',
          child: DarkTextInput(controller: _descCtrl, hint: '', maxLines: 4),
        ),
        const SizedBox(height: 18),
        DarkField(
          label: '会社（可选）',
          child: DarkTextInput(controller: _devCtrl, hint: '例如 YUZUSOFT'),
        ),
        const SizedBox(height: 18),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: DarkField(
                label: '评分（可选）',
                helper: '0 – 10',
                child: DarkTextInput(controller: _ratingCtrl, hint: '8.6'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DarkField(
                label: '评分人数（可选）',
                child: DarkTextInput(controller: _voteCtrl, hint: '1234'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        DarkField(
          label: '发售日期（可选）',
          helper: '格式 YYYY-MM-DD，例如 2016-07-29',
          child: DarkTextInput(controller: _dateCtrl, hint: '2016-07-29'),
        ),
        const SizedBox(height: 18),
        DarkMultiSelectField(
          label: '标签（可选，最多 14 个）',
          options: _tagOptions,
          selected: _tags,
          onChanged: (v) => setState(() {
            _tags
              ..clear()
              ..addAll(v.length > 14 ? v.take(14) : v);
          }),
        ),
        const SizedBox(height: 18),
        // 封面的「选择文件」行已由上方预览卡取代（点击卡片即选图）；
        // 截图保留在最底部，选中后立即缩略图预览（与「添加」页一致）。
        _filePicker(
          label: '游戏截图（可选）',
          helper: '最多 $_maxScreenshots 张',
          value: _screenshots.isEmpty ? '未选择' : '已选 ${_screenshots.length} 张',
          onTap: _pickScreenshots,
          onClear: _screenshots.isEmpty
              ? null
              : () => setState(_screenshots.clear),
        ),
        if (_screenshots.isNotEmpty) ...[
          const SizedBox(height: 10),
          _screenshotPreviewStrip(),
        ],
        if (_error != null) ...[
          const SizedBox(height: 18),
          _errorBox(),
        ],
        const SizedBox(height: 20),
      ],
    );
  }

  /// 封面预览卡（宽 148，高度随右侧名字输入区撑满 —— 2026-10-02 用户拍板
  /// 加大预览面积；配色适配本窗口的深色面 base）：未选图 = 「添加封面（必选）」
  /// 占位；已选 = NsfwImage 直接预览 + 右上角删除按钮。
  Widget _coverPickerCard() {
    final has = _coverPath != null;
    return GestureDetector(
      onTap: _pickCover,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          width: 148,
          decoration: BoxDecoration(
            color: const Color(0xFF23232A),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: DarkPalette.fieldBorder, width: 0.8),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (has)
                // NsfwImage 与添加页同款：封面语义 + fit/decodeWidth 对齐
                NsfwImage.file(
                  _coverPath!,
                  contentKind: NsfwContentKind.cover,
                  fit: BoxFit.cover,
                  decodeWidth: 320,
                  child: Image.file(
                    File(_coverPath!),
                    width: double.infinity,
                    height: double.infinity,
                    fit: BoxFit.cover,
                    cacheWidth: 320,
                  ),
                )
              else
                Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add_photo_alternate_outlined,
                          size: 22, color: DarkPalette.textDim),
                      const SizedBox(height: 6),
                      Text(
                        '添加封面',
                        style: const TextStyle(
                          fontSize: 11,
                          color: DarkPalette.textDim,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '（必选）',
                        style: TextStyle(
                          fontSize: 9.5,
                          color: DarkPalette.yellow.withOpacity(0.85),
                        ),
                      ),
                    ],
                  ),
                ),
              if (has)
                Positioned(
                  top: 4,
                  right: 4,
                  child: GestureDetector(
                    onTap: () => setState(() => _coverPath = null),
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: const Icon(Icons.close_rounded,
                          size: 13, color: Colors.white),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 横幅封面选择卡（2026-10-05）：全宽横版卡（高 88，约 2.2:1），
  /// 交互语言与 [_coverPickerCard] 一致——点击选图、已选直接预览、
  /// 右上角删除。可选字段，不填则下载入库后大图场景回退竖封面。
  Widget _bannerPickerCard() {
    final has = _bannerPath != null;
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: GestureDetector(
        onTap: _pickBanner,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            height: 88,
            decoration: BoxDecoration(
              color: const Color(0xFF23232A),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: DarkPalette.fieldBorder, width: 0.8),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (has)
                  NsfwImage.file(
                    _bannerPath!,
                    contentKind: NsfwContentKind.cover,
                    fit: BoxFit.cover,
                    decodeWidth: 640,
                    child: Image.file(
                      File(_bannerPath!),
                      width: double.infinity,
                      height: double.infinity,
                      fit: BoxFit.cover,
                      cacheWidth: 640,
                    ),
                  )
                else
                  Center(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.panorama_wide_angle_outlined,
                            size: 20, color: DarkPalette.textDim),
                        const SizedBox(width: 8),
                        Text(
                          '添加横幅封面（可选）',
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: DarkPalette.textDim,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '横版大图，用于 BPM 背景 / 主页大图',
                          style: TextStyle(
                            fontSize: 9.5,
                            color: DarkPalette.textDim.withOpacity(0.8),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (has)
                  Positioned(
                    top: 4,
                    right: 4,
                    child: GestureDetector(
                      onTap: () => setState(() => _bannerPath = null),
                      child: Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: const Icon(Icons.close_rounded,
                            size: 13, color: Colors.white),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 截图缩略图预览条：每张 96×54（16:9），右上角单张删除
  Widget _screenshotPreviewStrip() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (var i = 0; i < _screenshots.length; i++)
          _screenshotThumb(i),
      ],
    );
  }

  Widget _screenshotThumb(int index) {
    final path = _screenshots[index];
    return Container(
      width: 96,
      height: 54,
      decoration: BoxDecoration(
        color: const Color(0xFF23232A),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: DarkPalette.fieldBorder, width: 0.8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          NsfwImage.file(
            path,
            contentKind: NsfwContentKind.image,
            fit: BoxFit.cover,
            decodeWidth: 192,
            child: Image.file(
              File(path),
              width: double.infinity,
              height: double.infinity,
              fit: BoxFit.cover,
              cacheWidth: 192,
            ),
          ),
          Positioned(
            top: 2,
            right: 2,
            child: GestureDetector(
              onTap: () => setState(() => _screenshots.removeAt(index)),
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.close_rounded,
                    size: 11, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _metaBar() {
    return Row(
      children: [
        Expanded(
          child: Text(
            '可先一键抓取元数据，再按需修正。抓取结果仅作填充，不会自动提交。',
            style: TextStyle(
              fontSize: 11.5,
              color: DarkPalette.textDim.withOpacity(0.95),
              height: 1.4,
            ),
          ),
        ),
        const SizedBox(width: 10),
        DarkPrimaryButton(
          label: _fetching ? '抓取中…' : '自动填充元数据',
          busy: _fetching,
          onTap: _fetchMetadata,
          background: const Color(0xFF23232A),
          foreground: DarkPalette.textSecondary,
          icon: const Icon(Icons.auto_awesome_rounded),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          radius: 9,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ],
    );
  }

  Widget _filePicker({
    required String label,
    required String helper,
    required String value,
    required VoidCallback onTap,
    VoidCallback? onClear,
  }) {
    return DarkField(
      label: label,
      helper: helper,
      trailing: onClear == null
          ? null
          : GestureDetector(
              onTap: onClear,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.close_rounded,
                    size: 13, color: DarkPalette.textDim),
              ),
            ),
      child: GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(DarkPalette.radiusField),
              border: Border.all(color: DarkPalette.fieldBorder, width: 0.8),
            ),
            child: Row(
              children: [
                const Icon(Icons.folder_open_rounded,
                    size: 14, color: DarkPalette.textDim),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: value == '未选择'
                          ? DarkPalette.placeholder
                          : DarkPalette.textPrimary,
                    ),
                  ),
                ),
                const Text(
                  '选择文件',
                  style: TextStyle(fontSize: 11, color: DarkPalette.textDim),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _errorBox() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: DarkPalette.tipCardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DarkPalette.tipCardBorder, width: 0.8),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded,
              size: 14, color: DarkPalette.tipCardBorder),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _error!,
              style: const TextStyle(
                fontSize: 11.5,
                color: Color(0xFFFFB3C8),
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 交互 ====================

  void _handleClose() => widget.onClose?.call();

  /// 编辑模式：保存修改（`updateMyGame` 只发用户可写字段，
  /// `origin` / `owner` / `has_official` 一律不传）。
  /// 「编辑中/已驳回」状态保存时一并重新提交审核（服务端 v6 白名单放行）。
  Future<void> _saveEdit() async {
    final g = widget.editing;
    if (g == null || _submitting) return;
    final err = _validateGameForm();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await GamePublishService.updateMyGame(
        g.id,
        title: _titleCtrl.text,
        originalTitle: _jpCtrl.text,
        englishTitle: _enCtrl.text,
        traditionalChineseTitle: _tcCtrl.text,
        description: _descCtrl.text,
        developer: _devCtrl.text,
        rating: double.tryParse(_ratingCtrl.text.trim()),
        voteCount: int.tryParse(_voteCtrl.text.trim()),
        releaseDate: _dateCtrl.text,
        tags: _tags.toList(),
        metaSource: _metaSource,
        resubmit: g.isReviewEditing || g.isReviewRejected,
        // 编辑模式：重选了横幅才传（不传即保留线上原横幅，同封面的语义）
        bannerFilePath: _bannerPath,
      );
      if (!mounted) return;
      Navigator.of(context).maybePop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  String? _validateGameForm() {
    if (_titleCtrl.text.trim().isEmpty) return '请填写游戏名称';
    // 封面必选（2026-10-02）：仅新建发布强制；编辑模式未重选封面时
    // 保留线上原封面（updateMyGame 不传 coverFilePath 即不改）。
    if (!_isEditing && _coverPath == null) return '请上传封面图';
    final d = _dateCtrl.text.trim();
    if (d.isNotEmpty && !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(d)) {
      return '发售日期格式应为 YYYY-MM-DD';
    }
    final r = _ratingCtrl.text.trim();
    if (r.isNotEmpty) {
      final v = double.tryParse(r);
      if (v == null || v < 0 || v > 10) return '评分需为 0 – 10 之间的数字';
    }
    final n = _voteCtrl.text.trim();
    if (n.isNotEmpty && int.tryParse(n) == null) return '评分人数需为整数';
    return null;
  }

  void _handleNext() {
    final err = _validateGameForm();
    if (err != null) {
      setState(() => _error = err);
      return;
    }
    setState(() {
      _error = null;
      _step = 1;
    });
  }

  Future<void> _pickCover() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      final p = res?.files.isNotEmpty == true ? res!.files.first.path : null;
      if (p != null && mounted) setState(() => _coverPath = p);
    } catch (e) {
      if (mounted) setState(() => _error = '选择封面失败：$e');
    }
  }

  Future<void> _pickBanner() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      final p = res?.files.isNotEmpty == true ? res!.files.first.path : null;
      if (p != null && mounted) setState(() => _bannerPath = p);
    } catch (e) {
      if (mounted) setState(() => _error = '选择横幅封面失败：$e');
    }
  }

  Future<void> _pickScreenshots() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
      );
      if (res == null || !mounted) return;
      setState(() {
        for (final f in res.files) {
          if (f.path == null) continue;
          if (_screenshots.length >= _maxScreenshots) break;
          if (!_screenshots.contains(f.path)) _screenshots.add(f.path!);
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = '选择截图失败：$e');
    }
  }

  /// 一键抓取元数据（复用「添加页」同一入口 [MetadataFetcher.fetchGame]）
  Future<void> _fetchMetadata() async {
    final name = _titleCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请先填写游戏名称，再抓取元数据');
      return;
    }
    setState(() {
      _fetching = true;
      _error = null;
    });
    try {
      final list = await MetadataFetcher.fetchGame(name);
      if (!mounted) return;
      if (list.isEmpty) {
        setState(() {
          _fetching = false;
          _error = '未找到匹配的元数据，可手动填写';
        });
        return;
      }
      _applyMetadata(list.first);
      if (mounted) AppSnackBar.success(context, '元数据已填充，请核对后继续');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _fetching = false;
        _error = '元数据抓取失败：$e';
      });
    }
  }

  void _applyMetadata(Map<String, dynamic> m) {
    setState(() {
      _fetching = false;
      _metaSource = (m['platform'] as String?) ?? _metaSource;

      final jp = (m['original_title'] as String?)?.trim() ?? '';
      if (jp.isNotEmpty) _jpCtrl.text = jp;

      final summary = (m['summary'] as String?)?.trim() ?? '';
      if (summary.isNotEmpty) _descCtrl.text = summary;

      final dev = (m['developer'] as String?)?.trim() ?? '';
      if (dev.isNotEmpty) _devCtrl.text = dev;

      final rd = (m['release_date'] as String?)?.trim() ?? '';
      final norm = _normalizeDate(rd);
      if (norm.isNotEmpty) _dateCtrl.text = norm;

      final rating = m['rating'];
      if (rating is num && rating > 0) {
        _ratingCtrl.text = rating.toDouble().toStringAsFixed(1);
      }
      final votes = m['vote_count'];
      if (votes is num && votes > 0) {
        _voteCtrl.text = votes.toInt().toString();
      }

      final rawTags = m['tags'];
      if (rawTags is List) {
        for (final t in rawTags) {
          if (_tags.length >= 14) break;
          final s = t.toString().trim();
          // PB 的 tags 是 select：只接受集合定义里的取值，其余丢弃
          if (_tagOptions.contains(s)) _tags.add(s);
        }
      }
    });
  }

  /// 各数据源的日期格式不统一，统一成 `YYYY-MM-DD`（PB 字段是 text）
  static String _normalizeDate(String raw) {
    if (raw.isEmpty) return '';
    final m = RegExp(r'(\d{4})\D?(\d{1,2})?\D?(\d{1,2})?').firstMatch(raw);
    if (m == null) return '';
    final y = m.group(1)!;
    final mo = m.group(2);
    final d = m.group(3);
    if (mo == null) return y;
    final mm = mo.padLeft(2, '0');
    if (d == null) return '$y-$mm';
    return '$y-$mm-${d.padLeft(2, '0')}';
  }

  // ==================== 提交 ====================

  /// 第 3 步「提交发布」：先校验第 2 步，再把控制权交给资源表单
  /// （由它的 [UploadResourceDialogState.submit] 走统一校验与错误展示）
  Future<void> _submitResource() async {
    if (_submitting) return;
    final err = _validateGameForm();
    if (err != null) {
      setState(() {
        _step = 0;
        _error = err;
      });
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await _resKey.currentState?.submit();
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 「仅提交作品」：作品先入库，资源稍后在【我的】补传（合法状态）
  Future<void> _publishGameOnly() async {
    if (_submitting) return;
    final err = _validateGameForm();
    if (err != null) {
      setState(() {
        _step = 0;
        _error = err;
      });
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await _createGame();
      if (!mounted) return;
      final nav = Navigator.of(context);
      nav.maybePop(true);
      AppSnackBar.success(context, '作品已提交，可在【我的】中继续补传资源');
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  /// 真正落库：`games` → `game_resources`
  Future<void> _doPublish(ResourceDraft draft) async {
    final game = await _createGame();

    try {
      await GameResourceService.createCommunityResource(
        gameId: game.id,
        url: draft.url,
        title: draft.title,
        fileSize: draft.fileSize,
        version: draft.version,
        linkType: draft.linkType,
        netdiskProvider: draft.netdiskProvider,
        extractCode: draft.extractCode,
        unzipCode: draft.unzipCode,
        note: draft.note,
        resourceTypes: draft.resourceTypes,
        languages: draft.languages,
        platforms: draft.platforms,
      );
    } catch (e) {
      // 不回滚作品：与官方作品「有作品无资源」同构，属合法状态
      if (!mounted) return;
      final nav = Navigator.of(context);
      nav.maybePop(true);
      AppSnackBar.warning(context, '作品已提交，但资源上传失败，可在【我的】中补传');
      return;
    }

    if (!mounted) return;
    final nav = Navigator.of(context);
    nav.maybePop(true);
    AppSnackBar.success(context, '发布成功，审核通过后将进入探索库');
  }

  Future<GameModel> _createGame() {
    return GamePublishService.publishGame(
      title: _titleCtrl.text,
      originalTitle: _jpCtrl.text,
      englishTitle: _enCtrl.text,
      traditionalChineseTitle: _tcCtrl.text,
      description: _descCtrl.text,
      developer: _devCtrl.text,
      rating: double.tryParse(_ratingCtrl.text.trim()),
      voteCount: int.tryParse(_voteCtrl.text.trim()),
      releaseDate: _dateCtrl.text,
      tags: _tags.toList(),
      metaSource: _metaSource,
      coverFilePath: _coverPath,
      bannerFilePath: _bannerPath,
      screenshotPaths: List<String>.from(_screenshots),
    );
  }
}
