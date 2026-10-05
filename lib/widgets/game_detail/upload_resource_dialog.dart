import 'package:flutter/material.dart';

import '../../models/game_resource_model.dart';
import 'dark_surface.dart';

/// 提交结果（由调用方执行真正的 PB 写入）
typedef ResourceSubmitHandler = Future<void> Function(ResourceDraft draft);

/// 表单产出的草稿数据
class ResourceDraft {
  const ResourceDraft({
    required this.url,
    required this.title,
    required this.fileSize,
    required this.linkType,
    required this.netdiskProvider,
    this.version,
    this.extractCode,
    this.unzipCode,
    this.note,
    this.resourceTypes = const [],
    this.languages = const [],
    this.platforms = const [],
  });

  final String url;
  final String title;
  final String fileSize;
  final ResourceLinkType linkType;
  final String netdiskProvider;
  final String? version;
  final String? extractCode;
  final String? unzipCode;
  final String? note;
  final List<String> resourceTypes;
  final List<String> languages;
  final List<String> platforms;
}

/// 「发布资源」居中窗口（679dp 宽，内部滚动）。
///
/// 设计（`素材/新建文件夹 (2)/上传窗口.json` + `Form.png`）。
/// ⚠️ 设计稿高 1083dp > 应用默认窗口高 720dp，**必须内部滚动**，
/// 因此这里只约束宽度与最大高度，内容交给 [SingleChildScrollView]。
class UploadResourceDialog extends StatefulWidget {
  const UploadResourceDialog({
    super.key,
    required this.gameTitle,
    required this.onSubmit,
    this.onClose,
    this.maxHeight,
    this.embedded = false,
    this.initial,
    this.submitLabel = '发布资源',
  });

  final String gameTitle;
  final ResourceSubmitHandler onSubmit;
  final VoidCallback? onClose;
  final double? maxHeight;

  /// **内嵌模式**：由宿主（如「发布 Galgame」向导的同窗口分页）提供外壳与
  /// 底部操作条时置 true —— 此时本组件只输出「可滚动的字段区」，
  /// 不渲染自己的 `ConstrainedBox` / [DarkShell] / 头部 / 底部。
  /// 默认 false ⇒ 与既有「探索详情页【上传】」行为逐字节一致。
  final bool embedded;

  /// 预填草稿（编辑既有投稿 / 发布向导第 3 步）。
  /// 为空时所有字段保持既有初始值（语言 = 简体中文，平台 = Windows）。
  final ResourceDraft? initial;

  /// 主按钮文案（仅非内嵌模式下渲染自己的底部时用到）
  final String submitLabel;

  @override
  State<UploadResourceDialog> createState() => UploadResourceDialogState();
}

/// 公开 State：宿主可持 [GlobalKey] 调用 [submit]，
/// 把「提交」按钮放到自己的操作条上（发布向导分页需要）。
class UploadResourceDialogState extends State<UploadResourceDialog> {
  final _urlCtrl = TextEditingController();
  final _titleCtrl = TextEditingController();
  final _sizeCtrl = TextEditingController();
  final _extractCtrl = TextEditingController();
  final _unzipCtrl = TextEditingController();
  final _versionCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  final _editorFocus = FocusNode();

  bool _sizeUnitGb = true;
  bool _guideExpanded = false;
  bool _editorPreview = false;
  bool _submitting = false;
  String? _error;

  final Set<String> _resourceTypes = {};
  final Set<String> _languages = {'简体中文'};
  final Set<String> _platforms = {'Windows'};

  static const _resourceTypeOptions = [
    '游戏本体',
    '民间汉化',
    '官方中文',
    '全年龄补丁',
    '修正补丁',
    '特典',
    '音声 / 音乐',
    'CG / 素材',
    '攻略 / 手册',
    '其他',
  ];
  static const _languageOptions = [
    '简体中文',
    '繁體中文',
    '日本語',
    'English',
    '한국어',
    'Tiếng Việt',
    '其他',
  ];
  static const _platformOptions = [
    'Windows',
    'Android',
    'macOS',
    'Linux',
    'iOS',
    '其他',
  ];

  @override
  void initState() {
    super.initState();
    _noteCtrl.addListener(() => setState(() {}));
    _applyInitial(widget.initial);
  }

  /// 预填草稿（编辑既有投稿 / 发布向导第 3 步）。
  /// 空集合不覆盖默认的「简体中文 / Windows」，避免编辑时把默认选择清空。
  void _applyInitial(ResourceDraft? init) {
    if (init == null) return;
    _urlCtrl.text = init.url;
    _titleCtrl.text = init.title;
    _sizeCtrl.text = init.fileSize;
    _extractCtrl.text = init.extractCode ?? '';
    _unzipCtrl.text = init.unzipCode ?? '';
    _versionCtrl.text = init.version ?? '';
    _noteCtrl.text = init.note ?? '';
    _resourceTypes
      ..clear()
      ..addAll(init.resourceTypes);
    if (init.languages.isNotEmpty) {
      _languages
        ..clear()
        ..addAll(init.languages);
    }
    if (init.platforms.isNotEmpty) {
      _platforms
        ..clear()
        ..addAll(init.platforms);
    }
    // 体积单位跟随预填值，避免 "500MB" 被当成 GB 提交
    if (init.fileSize.toLowerCase().contains('mb')) _sizeUnitGb = false;
  }

  /// 供宿主触发的提交入口（内嵌模式下「提交」按钮在宿主的操作条上）
  Future<void> submit() => _handleSubmit();

  @override
  void dispose() {
    _urlCtrl.dispose();
    _titleCtrl.dispose();
    _sizeCtrl.dispose();
    _extractCtrl.dispose();
    _unzipCtrl.dispose();
    _versionCtrl.dispose();
    _noteCtrl.dispose();
    _editorFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 🔴 embedded=true（发布向导同窗口分页）：不渲染自己的外壳 / 头部 / 底部，
    // 只输出可滚动的字段区，由宿主提供 DarkShell 与操作条。
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!widget.embedded) _buildHeader(),
        Flexible(
          child: SingleChildScrollView(
            // 🔴 必须显式裁切：DarkShell 的圆角裁剪（clipBehavior）只作用于
            // **它的直接子级 layer**，而滚动内容是在 Column/Flexible 之下
            // 单独合成的 layer，滚动时会画到 shell 圆角边框之外 ——
            // 表现为窗口底部/两侧浮出一条「设计里没有的标线」。
            clipBehavior: Clip.hardEdge,
            padding: const EdgeInsets.fromLTRB(22, 0, 22, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 18),
                _buildGuideBar(),
                const SizedBox(height: 18),
                _buildUrlField(),
                const SizedBox(height: 18),
                _buildTitleField(),
                const SizedBox(height: 18),
                _buildSizeField(),
                const SizedBox(height: 18),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _buildText(
                        ctrl: _extractCtrl,
                        label: '提取码（可选）',
                        hint: '如 ab12',
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _buildText(
                        ctrl: _unzipCtrl,
                        label: '解压码（可选）',
                        hint: '多个用逗号分隔',
                        helper: '多个最好按解压顺序用逗号分隔',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: DarkMultiSelectField(
                        label: '资源类型',
                        options: _resourceTypeOptions,
                        selected: _resourceTypes,
                        onChanged: (v) => setState(() => _resourceTypes
                          ..clear()
                          ..addAll(v)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _buildText(
                        ctrl: _versionCtrl,
                        label: '版本信息（可选）',
                        hint: '例如 v1.02 汉化版',
                        clearable: true,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: DarkMultiSelectField(
                        label: '语言（可多选）',
                        options: _languageOptions,
                        selected: _languages,
                        onChanged: (v) => setState(() => _languages
                          ..clear()
                          ..addAll(v)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: DarkMultiSelectField(
                        label: '平台（可多选）',
                        options: _platformOptions,
                        selected: _platforms,
                        onChanged: (v) => setState(() => _platforms
                          ..clear()
                          ..addAll(v)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                _buildNoteField(),
                const SizedBox(height: 12),
                _buildToolbar(),
                const SizedBox(height: 8),
                _buildEditor(),
                const SizedBox(height: 14),
                if (_error != null) _buildError(),
              ],
            ),
          ),
        ),
        if (!widget.embedded) _buildFooter(),
      ],
    );
    if (widget.embedded) return body;
    final height =
        widget.maxHeight ?? (MediaQuery.of(context).size.height - 96);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: DarkPalette.uploadWidth,
        maxHeight: height.clamp(300.0, 2400.0),
      ),
      child: DarkShell(child: body),
    );
  }

  // ---------- 头部 ----------
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
                const Text(
                  '发布 Galgame 资源',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFFE2E2E7),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '为《${widget.gameTitle}》提交一份新的资源链接，提交后经审核对所有用户可见。',
                  style: const TextStyle(
                    fontSize: 12,
                    color: DarkPalette.textMuted,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          DarkCloseButton(onTap: widget.onClose ?? () {}, size: 26),
        ],
      ),
    );
  }

  // ---------- 折叠须知 ----------
  Widget _buildGuideBar() {
    return Column(
      children: [
        GestureDetector(
          onTap: () => setState(() => _guideExpanded = !_guideExpanded),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: DarkPalette.fieldBorder, width: 0.8),
            ),
            child: Row(
              children: [
                const Icon(Icons.tips_and_updates_outlined,
                    size: 15, color: DarkPalette.yellow),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '首次发布资源必看！',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: DarkPalette.textSecondary,
                    ),
                  ),
                ),
                AnimatedRotation(
                  turns: _guideExpanded ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: const Icon(Icons.keyboard_arrow_down_rounded,
                      size: 18, color: DarkPalette.textDim),
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 180),
          crossFadeState: _guideExpanded
              ? CrossFadeState.showFirst
              : CrossFadeState.showSecond,
          firstChild: Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: DarkPalette.shareNoteBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Text(
              '1. 请确认资源链接长期有效，失效资源会被下架。\n'
              '2. 请勿上传含 R18 内容的图片；隐藏文本语法 ||文本|| 仅用于折叠说明。\n'
              '3. 资源备注支持 Markdown 与图片，便于写清解压方式与注意事项。\n'
              '4. 提交后需经审核，通过后对所有用户可见；你可在「我的投稿」查看状态。',
              style: TextStyle(
                fontSize: 11.5,
                color: DarkPalette.textBody,
                height: 1.7,
              ),
            ),
          ),
          secondChild: const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  // ---------- 各字段 ----------
  Widget _buildUrlField() {
    return DarkField(
      label: '资源链接',
      required: true,
      helper: '网盘 / 磁链 / 网址。可直接粘贴分享文本，多链接用逗号分隔',
      child: DarkTextInput(
        controller: _urlCtrl,
        hint: 'https://...',
        maxLines: 3,
      ),
    );
  }

  Widget _buildTitleField() {
    return DarkField(
      label: '资源标题（可选）',
      helper: '显示在资源卡片上，用来区分同一类型的多份资源',
      child: DarkTextInput(
        controller: _titleCtrl,
        hint: '例如 全年龄补丁 / PC+安卓直装',
      ),
    );
  }

  Widget _buildSizeField() {
    return DarkField(
      label: '资源体积',
      required: true,
      helper: '可直接输入 500MB / 3.8GB，单位会跟着变',
      child: Row(
        children: [
          Expanded(
            child: DarkTextInput(
              controller: _sizeCtrl,
              hint: _sizeUnitGb ? '3.8' : '500',
            ),
          ),
          const SizedBox(width: 8),
          _buildUnitButton('MB', !_sizeUnitGb, () {
            setState(() => _sizeUnitGb = false);
          }),
          const SizedBox(width: 8),
          _buildUnitButton('GB', _sizeUnitGb, () {
            setState(() => _sizeUnitGb = true);
          }),
        ],
      ),
    );
  }

  Widget _buildUnitButton(String label, bool active, VoidCallback onTap) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 44,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? DarkPalette.primaryBlue : const Color(0xFF29292F),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: active ? Colors.white : DarkPalette.textLabel,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildText({
    required TextEditingController ctrl,
    required String label,
    String? hint,
    String? helper,
    bool clearable = false,
  }) {
    return DarkField(
      label: label,
      helper: helper,
      trailing: clearable
          ? GestureDetector(
              onTap: () => setState(() => ctrl.clear()),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 4),
                child: Icon(Icons.close_rounded,
                    size: 13, color: DarkPalette.textDim),
              ),
            )
          : null,
      child: DarkTextInput(controller: ctrl, hint: hint),
    );
  }

  Widget _buildNoteField() {
    return const DarkField(
      label: '资源备注（可选）',
      helper: '注意事项 / 介绍 / 作者信息，支持 Markdown 与图片',
      child: SizedBox.shrink(),
    );
  }

  // ---------- 工具条 ----------
  Widget _buildToolbar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _tabButton('预览', _editorPreview, () {
              setState(() => _editorPreview = true);
            }),
            const SizedBox(width: 4),
            _tabButton('Markdown', !_editorPreview, () {
              setState(() => _editorPreview = false);
            }),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 3,
          runSpacing: 3,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _toolButton('文本大小', Icons.format_size_rounded,
                () => _wrap('**', '**'), compact: true),
            _toolButton('☺', null, () => _insert('😊')),
            _toolButton('B', null, () => _wrap('**', '**'),
                bold: true),
            _toolButton('I', null, () => _wrap('*', '*'), italic: true),
            _toolButton('S', null, () => _wrap('~~', '~~'),
                decoration: TextDecoration.lineThrough),
            _toolButton('‹ ›', null, () => _wrap('`', '`'), mono: true),
            _toolButton('链接', Icons.link_rounded,
                () => _wrap('[', '](https://)')),
            _toolButton('☰', Icons.format_list_bulleted_rounded,
                () => _insertLine('- ')),
            _toolButton('≡', Icons.format_list_numbered_rounded,
                () => _insertLine('1. ')),
            _toolButton('❝', Icons.format_quote_rounded,
                () => _insertLine('> ')),
            _toolButton('▣', Icons.data_object_rounded,
                () => _wrap('\n```\n', '\n```\n')),
            _toolButton('—', Icons.horizontal_rule_rounded,
                () => _insertLine('\n---\n')),
            _toolButton('隐藏文本', Icons.visibility_off_outlined,
                () => _wrap('||', '||')),
            _toolButton('插入图片', Icons.image_outlined,
                () => _insert('![](https://)')),
          ],
        ),
        const SizedBox(height: 10),
        // 「Markdown 支持」胶囊（设计稿位置：工具栏下方、编辑器上方）
        const Align(
          alignment: Alignment.centerLeft,
          child: _MdSupportPill(),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _tabButton(String label, bool active, VoidCallback onTap) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: active ? DarkPalette.toolbarActive : Colors.transparent,
              width: 1,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              color:
                  active ? DarkPalette.toolbarActive : DarkPalette.textMuted,
            ),
          ),
        ),
      ),
    );
  }

  Widget _toolButton(
    String label,
    IconData? icon,
    VoidCallback onTap, {
    bool bold = false,
    bool italic = false,
    bool mono = false,
    bool compact = false,
    TextDecoration? decoration,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        // ⚠️ 不能写 `alignment: Alignment.center` —— Container 一旦设了
        // alignment，在 Wrap（传入 maxWidth 的松约束）里会**撑满整行**，
        // 14 个工具按钮会各占一行竖排。用 Center(widthFactor: 1.0) 让按钮
        // 按自身内容定宽。（同 game_detail_header 操作按钮行的坑）
        child: Container(
          height: 22,
          padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFF3A3A44), width: 0.7),
          ),
          child: Center(
            widthFactor: 1.0,
            child: icon != null
                ? Icon(icon, size: 13, color: DarkPalette.toolbarIdle)
                : Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      color: DarkPalette.toolbarIdle,
                      fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                      fontStyle: italic ? FontStyle.italic : FontStyle.normal,
                      fontFamily: mono ? 'monospace' : null,
                      decoration: decoration,
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  // ---------- 编辑器 ----------
  Widget _buildEditor() {
    if (_editorPreview) {
      return Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 134),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: DarkPalette.editorBorder, width: 0.8),
        ),
        child: Text(
          _noteCtrl.text.isEmpty ? '（暂无内容）' : _noteCtrl.text,
          style: const TextStyle(
            fontSize: 12.5,
            color: DarkPalette.textBody,
            height: 1.6,
          ),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: DarkPalette.editorBorder, width: 0.8),
      ),
      child: TextField(
        controller: _noteCtrl,
        focusNode: _editorFocus,
        maxLines: 6,
        minLines: 6,
        style: const TextStyle(
          fontSize: 12.5,
          color: DarkPalette.textPrimary,
          height: 1.5,
        ),
        cursorColor: DarkPalette.primaryBlue,
        decoration: darkInputDecoration(
          hint: '写点什么…（支持 Markdown）',
          padding: const EdgeInsets.all(12),
          multiline: true,
        ).copyWith(
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
        ),
      ),
    );
  }

  Widget _buildError() {
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

  // ---------- 底部 ----------
  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.fromLTRB(22, 14, 22, 18),
      child: Row(
        children: [
          DarkGhostButton(
            label: '取消',
            onTap: _submitting ? null : (widget.onClose ?? () {}),
            foreground: const Color(0xFFD5D5DC),
            fontSize: 13,
          ),
          const Spacer(),
          DarkPrimaryButton(
            label: widget.submitLabel,
            busy: _submitting,
            onTap: _handleSubmit,
            background: DarkPalette.primaryBlue,
            padding:
                const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
            radius: 11,
            fontSize: 13,
          ),
        ],
      ),
    );
  }

  // ---------- 提交 ----------
  Future<void> _handleSubmit() async {
    if (_submitting) return;

    final url = _urlCtrl.text.trim();
    final sizeRaw = _sizeCtrl.text.trim();
    if (url.isEmpty) {
      setState(() => _error = '请填写资源链接');
      return;
    }
    if (sizeRaw.isEmpty) {
      setState(() => _error = '请填写资源体积');
      return;
    }

    // 体积归一化成「数字 + 单位」；输入里已带单位则沿用，避免出现 "3.8GBGB"
    final hasUnit =
        RegExp(r'(mb|gb|kb|tb)$', caseSensitive: false).hasMatch(sizeRaw);
    final unit = _sizeUnitGb ? 'GB' : 'MB';
    final fileSize = hasUnit ? sizeRaw : '$sizeRaw $unit';

    final title = _titleCtrl.text.trim().isNotEmpty
        ? _titleCtrl.text.trim()
        : _resourceTypes.isNotEmpty
            ? _resourceTypes.first
            : '用户分享资源';

    setState(() {
      _submitting = true;
      _error = null;
    });

    try {
      await widget.onSubmit(ResourceDraft(
        url: url,
        title: title,
        fileSize: fileSize,
        linkType: _inferLinkType(url),
        netdiskProvider: _inferProvider(url),
        version: _versionCtrl.text.trim().isEmpty
            ? null
            : _versionCtrl.text.trim(),
        extractCode:
            _extractCtrl.text.trim().isEmpty ? null : _extractCtrl.text.trim(),
        unzipCode:
            _unzipCtrl.text.trim().isEmpty ? null : _unzipCtrl.text.trim(),
        note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
        resourceTypes: _resourceTypes.toList(),
        languages: _languages.toList(),
        platforms: _platforms.toList(),
      ));
    } catch (e) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  /// 按链接特征推断外链类型（PB `link_type` Values 内的值）
  static ResourceLinkType _inferLinkType(String url) {
    final u = url.toLowerCase();
    if (u.startsWith('magnet:')) return ResourceLinkType.other;
    if (u.startsWith('http')) {
      const netdisks = [
        'pan.baidu.com',
        'pan.quark.cn',
        'aliyundrive.com',
        'alipan.com',
        'cloud.189.cn',
        '115.com',
        'pan.xunlei.com',
        'mega.nz',
        'drive.google.com',
        '1drv.ms',
        'onedrive.live.com',
      ];
      if (netdisks.any(u.contains)) return ResourceLinkType.netdisk;
      return ResourceLinkType.direct;
    }
    return ResourceLinkType.other;
  }

  /// 按链接特征推断网盘（PB `netdisk_provider` Values 内的值）
  static String _inferProvider(String url) {
    final u = url.toLowerCase();
    if (u.contains('pan.baidu.com')) return 'baidu';
    if (u.contains('pan.quark.cn') || u.contains('quark')) return 'quark';
    if (u.contains('aliyundrive.com') || u.contains('alipan.com')) {
      return 'aliyun';
    }
    if (u.contains('xunlei.com')) return 'xunlei';
    if (u.contains('115.com')) return '115';
    if (u.contains('onedrive') || u.contains('1drv.ms')) return 'onedrive';
    if (u.contains('mega.nz')) return 'mega';
    if (u.contains('drive.google.com')) return 'google_drive';
    return 'other';
  }

  // ---------- 编辑器语法插入 ----------
  void _wrap(String before, String after) {
    final sel = _noteCtrl.selection;
    final text = _noteCtrl.text;
    final start = sel.isValid ? sel.start : text.length;
    final end = sel.isValid ? sel.end : text.length;
    final selected = text.substring(start, end);
    final replaced = '$before$selected$after';
    _noteCtrl.value = TextEditingValue(
      text: text.replaceRange(start, end, replaced),
      selection: TextSelection(
        baseOffset: start + before.length,
        extentOffset: start + before.length + selected.length,
      ),
    );
    _editorFocus.requestFocus();
  }

  void _insert(String text) {
    final sel = _noteCtrl.selection;
    final raw = _noteCtrl.text;
    final start = sel.isValid ? sel.start : raw.length;
    final end = sel.isValid ? sel.end : raw.length;
    _noteCtrl.value = TextEditingValue(
      text: raw.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    _editorFocus.requestFocus();
  }

  void _insertLine(String prefix) {
    final sel = _noteCtrl.selection;
    final raw = _noteCtrl.text;
    final at = sel.isValid ? sel.start : raw.length;
    final needsNewline = at > 0 && raw[at - 1] != '\n';
    final text = '${needsNewline ? '\n' : ''}$prefix';
    _noteCtrl.value = TextEditingValue(
      text: raw.replaceRange(at, at, text),
      selection: TextSelection.collapsed(offset: at + text.length),
    );
    _editorFocus.requestFocus();
  }
}

/// 深色多选字段：点击展开/收起选项 chip 面板。
///
/// 设计稿画的是下拉框；这里用「就地展开 chip」实现——鼠标操作更直接，
/// 且不引入额外的 Overlay 层级（避免与浮层路由的焦点/层级冲突）。
class DarkMultiSelectField extends StatefulWidget {
  const DarkMultiSelectField({
    required this.label,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final String label;
  final List<String> options;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  @override
  State<DarkMultiSelectField> createState() => _DarkMultiSelectFieldState();
}

class _DarkMultiSelectFieldState extends State<DarkMultiSelectField> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final display = selected.isEmpty ? '未选择' : selected.join('、');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: DarkPalette.textLabel,
          ),
        ),
        const SizedBox(height: 6),
        GestureDetector(
          onTap: () => setState(() => _open = !_open),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(DarkPalette.radiusField),
              border: Border.all(
                color: _open
                    ? DarkPalette.primaryBlue
                    : DarkPalette.fieldBorder,
                width: 0.8,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    display,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: selected.isEmpty
                          ? DarkPalette.placeholder
                          : DarkPalette.textPrimary,
                    ),
                  ),
                ),
                AnimatedRotation(
                  turns: _open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: const Icon(Icons.keyboard_arrow_down_rounded,
                      size: 17, color: DarkPalette.textDim),
                ),
              ],
            ),
          ),
        ),
        if (_open) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFF202024),
              borderRadius: BorderRadius.circular(DarkPalette.radiusField),
              border: Border.all(color: DarkPalette.fieldBorder, width: 0.8),
            ),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final opt in widget.options)
                  _chip(opt, selected.contains(opt)),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _chip(String label, bool active) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () {
          final next = Set<String>.from(widget.selected);
          if (active) {
            next.remove(label);
          } else {
            next.add(label);
          }
          widget.onChanged(next);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: active ? DarkPalette.badgeBlueBg : const Color(0xFF29292F),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: active ? DarkPalette.lightBlue : Colors.transparent,
              width: 0.8,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              color:
                  active ? DarkPalette.lightBlue : DarkPalette.textLabel,
            ),
          ),
        ),
      ),
    );
  }
}

/// 「Markdown 支持」胶囊（工具栏下方，提示编辑器语法可用）
class _MdSupportPill extends StatelessWidget {
  const _MdSupportPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: DarkPalette.mdPillBg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Text(
        'Markdown 支持',
        style: TextStyle(
          fontSize: 10.5,
          color: DarkPalette.mdPillText,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
