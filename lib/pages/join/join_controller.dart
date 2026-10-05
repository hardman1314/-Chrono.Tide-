import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../../services/local_game_registry.dart';
import '../../models/game_model.dart';
import '../../services/metadata_fetcher.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';
import '../../services/game_data_format.dart';
import '../../services/screenshot_fetch_service.dart';
import '../../services/cover_download_service.dart';
import '../../services/import_dedup_index.dart';
import '../../services/archive_inspector.dart';
import '../../services/global_install_center.dart';
import 'widgets/archive_plan_dialog.dart'
    show ArchivePlanConfirmation;
import '../../core/path_helper.dart';
import 'utils/game_folder_scanner.dart';

enum ScrapeSource { bangumi, vndb }

class JoinController extends ChangeNotifier {
  /// ★ 解压流水线（2026-10-05 流程语义修正）：解压完成待手动导入的预填
  /// 请求通道。安装中心确认窗收口解压流程后，main_container 设置此值并
  /// 切到添加页；JoinPage State 常驻（Offstage 保活，initState 只跑一次），
  /// 故用 Notifier 订阅而非构造参数传递——任意时刻触发都能被消费。
  /// 值 = 解压产物目录绝对路径；消费后置 null。
  static final ValueNotifier<String?> pendingExtractedDir =
      ValueNotifier<String?>(null);

  final TextEditingController nameController = TextEditingController();
  // 副标题输入（通常为日文原版标题，一键抓取后自动填充，用户可编辑）
  final TextEditingController subtitleController = TextEditingController();
  final TextEditingController tagsController = TextEditingController();
  final TextEditingController descController = TextEditingController();
  final TextEditingController developerController = TextEditingController();

  String? _coverFilePath;
  String? _selectedFilePath;
  String? _selectedFileName;
  // ★ 2026-10-04 智能解压 Phase 1（G2）：当前选中文件的魔数嗅探结果。
  // 仅文件分支填充（目录/exe 无需嗅探），isArchiveType 与 detectFileType
  // 据此把「改后缀伪装包」（.zip→.mp4 等）归入压缩包流程。
  ArchiveSniffResult? _lastSniff;
  bool _isDragging = false;
  bool _isSubmitting = false;
  bool _isScraping = false;
  String? _errorMessage;

  double _progressValue = 0;
  String _progressMessage = '';

  ScrapeSource? _selectedScrapeSource;
  bool _isBangumiSelected = true;
  String? _tempCoverPath;

  List<Map<String, dynamic>> _scrapeResults = [];
  Map<String, dynamic>? _selectedResult;
  List<String> _screenshotUrls = [];
  int _scrapeCoverVersion = 0; // 元数据选择时的封面下载版本号
  int _selectionGeneration = 0; // 元数据选择次数计数器，用于强制重建左侧UI

  // 双标题管理（业务规则：导入标题 > 抓取标题）：
  // - _originalTitle：导入时从文件夹/文件名提取（不可变）
  // - _metadataTitle：元数据抓取到的标准游戏名（抓取后赋值，仅作切换选项）
  // - _usingMetadataTitle：nameController 当前显示的是否为元数据标题
  //   抓取后主标题保持导入标题不变（仅主标题为空时才填入元数据标题）；
  //   用户可通过 UI 切换到元数据标题
  String _originalTitle = '';
  String? _metadataTitle;
  bool _usingMetadataTitle = false;

  // 字段锁定状态：锁定后切换抓取平台时不会覆盖该字段
  bool _coverLocked = false;
  bool _nameLocked = false;
  bool _tagsLocked = false;
  bool _descLocked = false;
  bool _developerLocked = false;
  bool _screenshotLocked = false;

  static const List<String> _archiveExts = [
    '.zip',
    '.rar',
    '.7z',
    '.tar',
    '.gz',
    '.bz2',
    '.xz',
    '.lz4',
    '.iso',
    '.cab',
    '.arj',
    '.zst',
    '.lzma',
    '.tar.gz',
    '.tar.bz2',
    '.tar.xz',
    '.tar.zst',
  ];

  VoidCallback? onGameAdded;
  Function(String)? onError;
  Function(String)? onSuccess;
  Function(String)? onWarning;
  Function(String)? onInfo;

  // ★ 2026-10-04 智能解压 Phase 3：UI 层注入的钩子（controller 不持
  //   BuildContext，弹窗由 join_page 注入）。
  /// 压缩包入库前获取解压计划：弹「解压计划确认窗口」，返回 null = 用户取消。
  /// （执行期决策弹窗与完成确认窗已随解压流水线迁至安装中心 +
  /// main_container 注入，不再由本 controller 承接。）
  Future<ArchivePlanConfirmation?> Function(String archivePath)?
      archivePlanProvider;

  JoinController({
    this.onGameAdded,
    this.onError,
    this.onSuccess,
    this.onWarning,
    this.onInfo,
  }) {
    // ★ WYSIWYG：监听标题输入框，用户手动编辑时同步 _originalTitle。
    // 仅在非元数据标题模式下更新，避免 selectScrapeResult / toggleTitlePreference
    // 等程序化赋值污染 _originalTitle。这样切回"原标题"时拿到的是用户手动编辑
    // 后的值，而非初始的文件夹名。
    nameController.addListener(_onNameChanged);
  }

  /// 标题输入框变化监听：用户手动编辑时同步 _originalTitle
  ///
  /// 设计要点：
  /// - 仅当 _usingMetadataTitle == false 时更新（即当前显示的不是元数据标题）
  ///   这样 selectScrapeResult（会先置 _usingMetadataTitle=true 再赋值）和
  ///   toggleTitlePreference 切到元数据标题时，不会污染 _originalTitle
  /// - toggleTitlePreference 切回原标题时（_usingMetadataTitle=false），赋值
  ///   _originalTitle 给 nameController，本监听器把它写回 _originalTitle，值不变
  void _onNameChanged() {
    if (!_usingMetadataTitle) {
      _originalTitle = nameController.text;
    }
  }

  // Getters
  String? get coverFilePath => _coverFilePath;
  String? get selectedFilePath => _selectedFilePath;
  String? get selectedFileName => _selectedFileName;
  bool get isDragging => _isDragging;
  List<String> get screenshotUrls => _screenshotUrls;
  int get selectionGeneration => _selectionGeneration;

  // 双标题 getter
  /// 原标题：导入时从文件夹/文件名提取（不可变）
  String get originalTitle => _originalTitle;

  /// 副标题（trim 后）：与主标题共同构成标题系统，通常为日文原版标题
  String get subtitle => subtitleController.text.trim();

  /// 元数据标题：抓取到的标准游戏名（未抓取时为 null）
  String? get metadataTitle => _metadataTitle;

  /// 当前 nameController 显示的是否为元数据标题
  bool get usingMetadataTitle => _usingMetadataTitle;

  /// 是否可在原标题与元数据标题间切换（有元数据标题且不同于原标题）
  bool get canToggleTitle =>
      _metadataTitle != null &&
      _metadataTitle!.isNotEmpty &&
      _metadataTitle != _originalTitle;

  /// 递增选择代次计数器，强制左侧UI完整重建
  /// 在选择元数据卡片、批量切换游戏、重置表单等场景中调用
  void bumpGeneration() {
    _selectionGeneration++;
  }

  // 字段锁定 getter
  bool get coverLocked => _coverLocked;
  bool get nameLocked => _nameLocked;
  bool get tagsLocked => _tagsLocked;
  bool get descLocked => _descLocked;
  bool get developerLocked => _developerLocked;
  bool get screenshotLocked => _screenshotLocked;

  // 字段锁定 setter
  void toggleCoverLock() {
    _coverLocked = !_coverLocked;
    notifyListeners();
  }

  void toggleNameLock() {
    _nameLocked = !_nameLocked;
    notifyListeners();
  }

  void toggleTagsLock() {
    _tagsLocked = !_tagsLocked;
    notifyListeners();
  }

  void toggleDescLock() {
    _descLocked = !_descLocked;
    notifyListeners();
  }

  void toggleDeveloperLock() {
    _developerLocked = !_developerLocked;
    notifyListeners();
  }

  void toggleScreenshotLock() {
    _screenshotLocked = !_screenshotLocked;
    notifyListeners();
  }

  // 一键解锁所有字段
  void unlockAllFields() {
    _coverLocked = false;
    _nameLocked = false;
    _tagsLocked = false;
    _descLocked = false;
    _developerLocked = false;
    _screenshotLocked = false;
    notifyListeners();
  }

  // ===== 双标题管理 =====

  /// 设置双标题数据（批量切换游戏或单文件导入时调用）
  ///
  /// - [original] 原标题（文件夹/文件名）
  /// - [metadata] 元数据标题（未抓取时传 null）
  /// - [useMetadata] 当前是否使用元数据标题
  void setTitles({
    required String original,
    String? metadata,
    bool useMetadata = false,
  }) {
    _originalTitle = original;
    _metadataTitle = metadata;
    _usingMetadataTitle =
        useMetadata && (metadata != null && metadata.isNotEmpty);
    notifyListeners();
  }

  /// 切换标题偏好（原标题 ↔ 元数据标题）
  ///
  /// 在 originalTitle 与 metadataTitle 间切换 nameController 的显示。
  /// 仅当 [canToggleTitle] 为 true 时有效。切换后强制重建左侧 UI
  /// （bumpGeneration）以更新 NameInput 右下角的小字提示。
  void toggleTitlePreference() {
    if (!canToggleTitle) return;
    _usingMetadataTitle = !_usingMetadataTitle;
    nameController.text =
        _usingMetadataTitle ? _metadataTitle! : _originalTitle;
    bumpGeneration();
    notifyListeners();
  }

  /// 判断文本是否含 CJK 字符（假名/汉字，用于排除纯英文标题）
  /// 与 SDK Bangumi 服务的 _containsCjk 逻辑保持一致
  static final RegExp _cjkRegExp =
      RegExp(r'[\u3040-\u30FF\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]');

  static bool _containsCjk(String text) => _cjkRegExp.hasMatch(text);

  bool get isSubmitting => _isSubmitting;
  bool get isScraping => _isScraping;
  String? get errorMessage => _errorMessage;
  double get progressValue => _progressValue;
  String get progressMessage => _progressMessage;
  bool get isBangumiSelected => _isBangumiSelected;
  List<Map<String, dynamic>> get scrapeResults => _scrapeResults;
  Map<String, dynamic>? get selectedResult => _selectedResult;

  bool get canSubmit =>
      nameController.text.trim().isNotEmpty &&
      _selectedFilePath != null &&
      !_isSubmitting &&
      !_isAwaitingPlanConfirmation;

  /// ★ 压缩包流程「计划窗确认中」（2026-10-04 真机反馈修复）：此间
  ///   canSubmit=false 防止重复点击再弹一个计划窗，且不置 _isSubmitting
  ///   （避免 JoinProgressDialog 抢先弹出叠成双模态）。
  bool _isAwaitingPlanConfirmation = false;

  /// 是否为压缩包类型（★ IMP-10：与 [isArchiveExt] 共用同一份白名单）
  ///
  /// 旧实现只认 zip/rar/7z/tar/gz 五种，而 [_archiveExts]（17 种，含 .iso/.xz/
  /// .bz2/.lz4/.zst/.cab/.arj/.lzma/.tar.* 等）驱动了"接受文件"与"提取游戏名"
  /// 两条逻辑，于是这些格式会被 UI 接受、点入库却抛"不支持的文件类型"。
  /// `ExtractManager._detectFormatsFromName` 实际支持全部 17 种，故此处直接对齐。
  /// 当前选中文件是否为压缩包（含魔数识别出的伪装包）。
  ///
  /// ★ 2026-10-04 智能解压 Phase 1（G2）：在原扩展名白名单之上叠加魔数
  /// 嗅探兜底——[ArchiveSniffResult.disguised] 为真（内容是压缩格式但
  /// 后缀不是常规压缩后缀）同样视为压缩包，走解压流程而非被拒。
  bool get isArchiveType {
    final path = _selectedFilePath;
    if (path == null) return false;
    if (isArchiveExt(path)) return true;
    final sniff = _lastSniff;
    return sniff != null && sniff.path == path && sniff.disguised;
  }

  @override
  void dispose() {
    nameController.removeListener(_onNameChanged);
    nameController.dispose();
    subtitleController.dispose();
    tagsController.dispose();
    descController.dispose();
    developerController.dispose();
    super.dispose();
  }

  // File Operations
  Future<void> pickCover() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        dialogTitle: '选择游戏封面',
      );
      if (result != null && result.files.single.path != null) {
        _coverFilePath = result.files.single.path;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('[ADD] 封面选择失败: $e');
    }
  }

  void removeCover() {
    _coverFilePath = null;
    notifyListeners();
  }

  void setCoverFilePath(String? path) {
    _coverFilePath = path;
    notifyListeners();
  }

  /// ★ 解压流水线（2026-10-05 流程语义修正）：接收安装中心交接的解压产物
  /// 目录，预填进表单（等价于用户手动拖入该文件夹）——路径选中、标题
  /// 预填目录名，其余字段留空由用户自行填写，入库由用户点按钮触发。
  void receiveExtractedDirectory(String dir) {
    debugPrint('[ADD] 📦 接收解压产物预填: $dir');
    handleFileSelected(dir);
  }

  Future<void> pickFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        dialogTitle: '选择游戏文件或文件夹',
        allowMultiple: false,
      );
      if (result != null && result.files.single.path != null) {
        handleFileSelected(result.files.single.path!);
      }
    } catch (e) {
      debugPrint('[ADD] 文件选择失败: $e');
    }
  }

  void handleFileSelected(String path) {
    final file = File(path);
    final dir = Directory(path);

    if (dir.existsSync()) {
      final folderName = path.split('/').last.split('\\').last;
      _selectedFilePath = path;
      _selectedFileName = folderName;
      _errorMessage = null;
      // 双标题：选新文件时更新原标题，清除旧元数据标题
      _originalTitle = folderName;
      _metadataTitle = null;
      _usingMetadataTitle = false;
      notifyListeners();

      if (nameController.text.trim().isEmpty) {
        nameController.text = folderName;
      }
      debugPrint('[ADD] 选择文件夹: $folderName → 路径: $path');
    } else if (file.existsSync()) {
      final fileName = path.split('/').last.split('\\').last;
      // ★ 2026-10-04 智能解压 Phase 1（G2）：魔数嗅探——识别改后缀伪装包。
      // 扩展名判定只看文件名，.zip 改名 .mp4 后会被当普通文件拒绝；
      // 嗅探读前 16 字节（O(1)），命中压缩魔数即按压缩包处理。
      _lastSniff = ArchiveInspector.sniffSync(path);
      if (_lastSniff!.disguised) {
        debugPrint('[ADD] 🎭 伪装压缩包: $fileName 声明后缀=${_lastSniff!.declaredExt} '
            '真实格式=${_lastSniff!.format} → 按压缩包处理');
      }
      final fileType = detectFileType(path);

      // ★ 2026-10-04 真机反馈（P0）：普通文件在选择阶段直接拒绝——此前
      //   .mp4 等杂文件一路放行到「确认入库」→ startCopyFlow 才 throw
      //   （进度窗已弹出且无人置失败态 → 窗口永久卡死）。
      //   伪装包不受影响：嗅探命中真实压缩格式时 detectFileType 返回
      //   该格式而非 'file'，仍走解压链路。
      if (fileType == 'file') {
        final ext = fileName.contains('.')
            ? fileName.substring(fileName.lastIndexOf('.'))
            : '';
        _lastSniff = null;
        _errorMessage = '仅支持压缩包、游戏文件夹或游戏 EXE，'
            '不支持导入普通文件${ext.isEmpty ? '' : '（$ext）'}';
        notifyListeners();
        return;
      }

      _selectedFilePath = path;
      _selectedFileName = fileName;
      _errorMessage = null;
      notifyListeners();

      String gameName = '';
      if (fileType == 'exe') {
        final parentDir = File(path).parent.path;
        gameName = parentDir.split('/').last.split('\\').last;
        debugPrint('[ADD] 选择EXE文件: $fileName → 使用父目录名作为游戏名: $gameName');
      } else if (isArchiveType) {
        gameName = fileName.contains('.')
            ? fileName.substring(0, fileName.lastIndexOf('.'))
            : fileName;
        debugPrint('[ADD] 选择压缩包: $fileName → 游戏名: $gameName');
      } else {
        gameName = fileName.contains('.')
            ? fileName.substring(0, fileName.lastIndexOf('.'))
            : fileName;
        debugPrint('[ADD] 选择其他文件: $fileName → 游戏名: $gameName');
      }

      // 双标题：选新文件时更新原标题，清除旧元数据标题
      if (gameName.isNotEmpty) {
        _originalTitle = gameName;
        _metadataTitle = null;
        _usingMetadataTitle = false;
      }

      if (nameController.text.trim().isEmpty && gameName.isNotEmpty) {
        nameController.text = gameName;
      }
    }
  }

  bool isArchiveExt(String path) {
    final ext = path.toLowerCase();
    return _archiveExts.any((e) => ext.endsWith(e));
  }

  void clearFileSelection() {
    _selectedFilePath = null;
    _selectedFileName = null;
    _lastSniff = null;
    notifyListeners();
  }

  String? detectFileType(String path) {
    if (Directory(path).existsSync()) return 'folder';
    // ★ 2026-10-04 智能解压 Phase 1（G2）：扩展名未命中时回退魔数嗅探
    // 结果（仅当嗅探对象就是当前文件），让伪装包在 UI 上显示真实格式。
    // ★ 2026-10-05 实机反馈（情景三）：嗅探上移到 exe/扩展名判定之前——
    // 伪装成 .exe 的压缩容器（实为 rar/zip，社区分发常见形态）必须按
    // 魔数实证格式走解压链，不能按可执行文件直接导入（用户来不及解压）。
    // 真 exe 不受影响：PE 头（MZ）不在压缩魔数表，嗅探 format=null
    // 自然落到下方 exe 判定。
    final sniff = _lastSniff;
    if (sniff != null && sniff.path == path && sniff.format != null) {
      return sniff.format;
    }
    final ext = path.toLowerCase();
    if (ext.endsWith('.exe')) return 'exe';
    for (final e in _archiveExts) {
      if (ext.endsWith(e)) return e.replaceFirst('.', '');
    }
    return 'file';
  }

  IconData getFileIcon(String? fileType) {
    switch (fileType) {
      case 'folder':
        return Icons.folder_rounded;
      case 'exe':
        return Icons.play_circle_outline_rounded;
      case 'zip':
      case 'rar':
      case '7z':
        return Icons.archive_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  String getFileLabel(String? fileType) {
    // ★ 2026-10-04 真机反馈（P1）：伪装包用复合文案——「伪压缩包 / .mp4
    //   文件」。明示该文件双属性（内容是压缩包、后缀是别的），避免不懂的
    //   用户据此时会形成「.mp4 = 压缩包」的错误认知。
    final sniff = _lastSniff;
    if (sniff != null &&
        sniff.disguised &&
        sniff.path == selectedFilePath) {
      return '伪压缩包 / ${sniff.declaredExt} 文件';
    }
    switch (fileType) {
      case 'folder':
        return '文件夹';
      case 'exe':
        return '可执行文件';
      case 'zip':
      case 'rar':
      case '7z':
        return '压缩包';
      default:
        return '文件';
    }
  }

  void setDragging(bool value) {
    _isDragging = value;
    notifyListeners();
  }

  // Metadata Operations
  void selectScrapeSource(ScrapeSource source) {
    _selectedScrapeSource = source;
    _isBangumiSelected = source == ScrapeSource.bangumi;
    notifyListeners();
  }

  Future<void> fetchScrapeData() async {
    final gameName = nameController.text.trim();

    if (gameName.isEmpty) {
      onError?.call('请先输入游戏名称');
      return;
    }

    if (_isScraping) return;

    _isScraping = true;
    _scrapeResults = [];
    _selectedResult = null;
    _errorMessage = null;
    notifyListeners();

    try {
      final results = await MetadataFetcher.fetchGame(gameName);

      if (results.isNotEmpty) {
        _scrapeResults = results;
        notifyListeners();

        final platforms = results.map((r) => r['platform']).toSet().toList();
        onSuccess
            ?.call('✨ 从 ${platforms.join(" / ")} 找到 ${results.length} 条结果');
      } else {
        onWarning?.call('未找到对应游戏信息');
      }
    } catch (e) {
      debugPrint('[SCRAPE] 抓取异常: $e');
      onError?.call('元数据抓取失败：${extractErrorMessage(e.toString())}');
    } finally {
      _isScraping = false;
      notifyListeners();
    }
  }

  Future<List<Map<String, dynamic>>> callScraperTool(
      String gameName, dynamic source) async {
    try {
      debugPrint('[SCRAPE] 🚀 使用新SDK查询: $gameName');

      SourceType newSource;
      if (source == null || source == ScrapeSource.bangumi) {
        newSource = SourceType.bangumi;
      } else if (source == ScrapeSource.vndb) {
        newSource = SourceType.vndb;
      } else {
        newSource = SourceType.bangumi;
      }

      final results = await MetadataFetcher.fetchGame(
        gameName,
        preferredSource: newSource,
      );

      debugPrint('[SCRAPE] ✅ 新SDK查询成功: ${results.length} 条记录');

      if (results.isNotEmpty) {
        final first = results.first;
        debugPrint(
            '[SCRAPE]    首条结果: ${first['game_name']} (${first['platform']})');
        return results;
      } else {
        throw Exception('未找到相关游戏信息');
      }
    } catch (e) {
      debugPrint('[SCRAPE] ❌ 新SDK查询失败: $e');
      rethrow;
    }
  }

  /// 从 CT 探索库导入作品（2026-10-05：CT 探索库选择弹窗回调）
  ///
  /// 将云端作品记录（GameModel）转换为与一键抓取结果同构的 legacy map
  /// （对齐 [MetadataFetcher] `_convertToLegacyFormat` 字段名），
  /// 再复用 [selectScrapeResult] 的完整导入管线——标题/副标题/标签/简介/
  /// 会社/截图/封面下载与字段锁定语义完全一致；入库时
  /// `metadataSource='CT'`、`metadataSourceId=云端作品 id` 自动持久化。
  void importFromCtLibrary(GameModel game) {
    debugPrint('[SCRAPE] CT 探索库导入: ${game.title} (id=${game.id})');
    selectScrapeResult({
      'game_name': game.title,
      'original_title':
          game.originalTitle.isNotEmpty ? game.originalTitle : null,
      'platform': 'CT',
      'platform_id': game.id,
      'tags': List<String>.of(game.tags),
      'tags_meta': [
        for (final t in game.tags)
          {'name': t, 'weight': 1.0, 'is_spoiler': false, 'source': 'ct'},
      ],
      'rating': game.rating ?? 0.0,
      'vote_count': game.voteCount,
      'summary': game.description,
      'cover_url': game.coverUrl,
      'banner_url': game.bannerUrl,
      'release_date': game.releaseDate,
      'developer': game.developer,
      'screenshot_urls': List<String>.of(game.screenshotUrls),
    });
  }

  void selectScrapeResult(Map<String, dynamic> result) {
    debugPrint('[SCRAPE] ========== 选择元数据 ==========');

    // 递增选择计数器，强制左侧UI完整重建，防止快速点击时Element复用错乱
    bumpGeneration();

    _selectedResult = result;

    // 根据锁定状态决定是否覆盖各字段
    final gameName = result['game_name'];
    if (gameName != null && gameName.toString().isNotEmpty) {
      // 双标题：记录元数据标题（无论是否锁定都记录，供用户后续切换）
      _metadataTitle = gameName.toString();
      if (!_nameLocked) {
        if (nameController.text.trim().isEmpty &&
            _originalTitle.trim().isEmpty) {
          // 主标题为空：直接填入元数据标题
          _usingMetadataTitle = true;
          nameController.text = gameName.toString();
          debugPrint('[SCRAPE] ✓ 主标题为空，已填入元数据标题: $gameName');
        } else {
          // 业务规则：导入标题 > 抓取标题，保持用户设置的主标题不变
          // 元数据标题仅作为切换选项（NameInput 右下角），不直接替换主标题
          if (_usingMetadataTitle && _originalTitle.trim().isNotEmpty) {
            // 之前处于元数据标题模式：恢复显示导入标题
            nameController.text = _originalTitle;
          }
          _usingMetadataTitle = false;
          debugPrint(
              '[SCRAPE] ✓ 保持主标题不变，元数据标题已记录为切换选项: $gameName');
        }
      } else {
        debugPrint('[SCRAPE] 🔒 游戏名已锁定，跳过覆盖（但已记录 metadataTitle）');
      }
    }

    // 副标题：自动填充日文原版标题（不导入英文标题）
    // original_title 由 MetadataFetcher 从各数据源多语言标题中提取（优先日文）
    final originalTitle = result['original_title'];
    if (originalTitle != null && originalTitle.toString().isNotEmpty) {
      final subTitle = originalTitle.toString().trim();
      // 仅含 CJK 字符的原版标题（排除纯英文）且与主标题不同时填充
      if (_containsCjk(subTitle) && subTitle != nameController.text.trim()) {
        subtitleController.text = subTitle;
        debugPrint('[SCRAPE] ✓ 已填入副标题（日文原版标题）: $subTitle');
      }
    }

    final tags = result['tags'];
    if (tags != null && tags is List && tags.isNotEmpty && !_tagsLocked) {
      tagsController.text =
          tags.map((t) => t.toString()).where((t) => t.isNotEmpty).join(', ');
      debugPrint('[SCRAPE] ✓ 已填入标签: ${tagsController.text}');
    } else if (_tagsLocked) {
      debugPrint('[SCRAPE] 🔒 标签已锁定，跳过覆盖');
    }

    final summary = result['summary'];
    if (summary != null && summary.toString().isNotEmpty && !_descLocked) {
      descController.text = summary.toString();
      debugPrint('[SCRAPE] ✓ 已填入简介 (${descController.text.length}字)');
    } else if (_descLocked) {
      debugPrint('[SCRAPE] 🔒 简介已锁定，跳过覆盖');
    }

    final developer = result['developer'];
    if (developer != null &&
        developer.toString().isNotEmpty &&
        !_developerLocked) {
      developerController.text = developer.toString();
      debugPrint('[SCRAPE] ✓ 已填入会社: ${developerController.text}');
    } else if (_developerLocked) {
      debugPrint('[SCRAPE] 🔒 会社已锁定，跳过覆盖');
    }

    // 提取截图URL列表
    if (!_screenshotLocked) {
      final screenshotUrls = result['screenshot_urls'];
      if (screenshotUrls != null &&
          screenshotUrls is List &&
          screenshotUrls.isNotEmpty) {
        _screenshotUrls = screenshotUrls
            .map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList();
        debugPrint('[SCRAPE] ✓ 已提取截图URL: ${_screenshotUrls.length}张');
      } else {
        _screenshotUrls = [];
        debugPrint('[SCRAPE] 无截图数据');
      }
    } else {
      debugPrint('[SCRAPE] 🔒 截图已锁定，跳过覆盖');
    }

    // 所有字段设置完毕后统一通知UI更新（避免中间状态渲染）
    notifyListeners();

    final coverUrl = result['cover_url'];
    if (coverUrl != null && coverUrl.toString().isNotEmpty && !_coverLocked) {
      debugPrint('[SCRAPE] 开始下载封面...');
      // 递增版本号，使之前并发的封面下载结果失效
      _scrapeCoverVersion++;
      final currentVersion = _scrapeCoverVersion;
      downloadAndSetCover(coverUrl.toString(), validVersion: currentVersion);
    } else if (_coverLocked) {
      debugPrint('[SCRAPE] 🔒 封面已锁定，跳过下载');
    } else {
      debugPrint('[SCRAPE] 无封面URL，跳过下载');
    }

    // 统计跳过的字段
    final lockedFields = <String>[
      if (_nameLocked) '标题',
      if (_tagsLocked) '标签',
      if (_descLocked) '简介',
      if (_developerLocked) '会社',
      if (_coverLocked) '封面',
    ];

    if (lockedFields.isNotEmpty) {
      onSuccess?.call('已填入数据（${lockedFields.join("、")}已锁定保留）');
    } else {
      onSuccess?.call('已选择数据并填入表单');
    }
  }

  Future<void> downloadAndSetCover(String url, {int? validVersion}) async {
    // Phase 3.1: 委托给统一的 CoverDownloadService（含缓存优先 + 重试 + UA/Referer）
    // 保留并发版本守卫，防止旧下载覆盖用户最新选择
    // 修复 2026-08：移除文件命名中的 DateTime.now().millisecondsSinceEpoch，
    // 改由 CoverDownloadService 自动追加进程内单调递增的 nonce 保证唯一性。
    final tempDir = Directory(PathHelper.portableTmpDir);
    final ext = CoverDownloadService.detectExtension(url);
    final fileName = 'scrape_cover.$ext';

    final savedName = await CoverDownloadService.instance.downloadCover(
      targetDir: tempDir.path,
      coverUrl: url,
      fileName: fileName,
    );

    // 写入状态前检查版本号，防止并发下载覆盖最新选择的结果
    if (validVersion != null && validVersion != _scrapeCoverVersion) {
      debugPrint('[SCRAPE] 封面下载版本不匹配，丢弃结果');
      return;
    }

    if (savedName != null) {
      final tempFilePath = '${tempDir.path}/$savedName';
      if (File(tempFilePath).existsSync()) {
        _tempCoverPath = tempFilePath;
        _coverFilePath = tempFilePath;
        notifyListeners();
        debugPrint('[SCRAPE] ✅ 已更新UI显示封面');
      }
    } else {
      debugPrint('[SCRAPE] ❌ 封面下载失败: $url');
      onWarning?.call('封面图片加载失败，请稍后重试');
    }
  }

  // Submit Logic
  Future<void> submitAddGame() async {
    final gameName = nameController.text.trim();
    if (gameName.isEmpty) {
      _errorMessage = '请输入游戏名称';
      notifyListeners();
      return;
    }
    if (_selectedFilePath == null) {
      _errorMessage = '请选择游戏文件或文件夹';
      notifyListeners();
      return;
    }
    final filePath = _selectedFilePath!;
    if (!File(filePath).existsSync() && !Directory(filePath).existsSync()) {
      _errorMessage = '选择的路径无效，文件不存在';
      notifyListeners();
      return;
    }
    final tagsStr = tagsController.text.trim();
    final tags = tagsStr.isNotEmpty
        ? tagsStr
            .split(RegExp(r'[,\s，、]+'))
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList()
        : <String>[];

    // ★ 排重护栏（2026-10-03）：手动导入此前零排重，同一本体目录重复导入
    //   会产生第二个条目（标题可能因目录名清洗差异而不同），且两条目
    //   directory_path 相同 → 库页卡片 GlobalKey 冲突、Duplicate key
    //   报错丢渲染（实锤案例：ATRI 重复导入，库页"共 2 部"只渲染 1 张卡）。
    //   只拦硬冲突（路径已入库 / 路径包含重叠）；同名不同路径是合法场景，
    //   不拦（与批量导入的软警告语义一致）。
    //   目录推导与 startCopyFlow 的口径一致：文件夹 = 本身，exe = 父目录。
    //   压缩包不检查：解压产物是新目录，路径排重不适用。
    if (!isArchiveType) {
      final importDir = filePath.toLowerCase().endsWith('.exe')
          ? File(filePath).parent.path
          : filePath;
      final verdict = ImportDedupIndex.fromRegistry().check(importDir);
      if (verdict.isHardConflict) {
        _errorMessage = verdict.reason;
        notifyListeners();
        return;
      }
    }

    // ★ 修复（2026-10-04 真机反馈 P0）：压缩包流程不提前置 _isSubmitting。
    //   原实现在弹计划窗前置位 → JoinProgressDialog（「正在入库」）抢先
    //   弹出叠在计划窗上方，构成双模态死锁（进度窗在上、计划窗点不到，
    //   取消与关窗全部失灵）。压缩包改为：计划窗确认后才进入提交态。
    if (!isArchiveType) {
      _isSubmitting = true;
      _errorMessage = null;
      notifyListeners();
    }

    try {
      if (isArchiveType) {
        // ★ 2026-10-04 智能解压 Phase 3：压缩包先弹「解压计划确认窗口」
        // （层级树 + 按层密码 + 后缀映射 + 解压位置），用户确认后才开解。
        // 钩子未注入（理论上不会发生）时退回老流程直接解压。
        _isAwaitingPlanConfirmation = true;
        _errorMessage = null;
        notifyListeners();
        // ★ Phase C（join_unpack_scenarios_v2.md §1.1）：分卷缺卷直接失败
        //（用户拍板 2026-10-04：不挂起、不弹计划窗，明确报因）
        final vg = ArchiveInspector.detectVolumeGroup(filePath);
        if (vg != null && vg.missingNumbers.isNotEmpty) {
          _isAwaitingPlanConfirmation = false;
          _errorMessage = '分卷压缩包不完整（已发现 ${vg.volumes.length} 段）：'
              '缺少 ${vg.missingFilenames.join('、')}，'
              '请补齐缺失分卷后重新导入';
          notifyListeners();
          return;
        }
        ArchivePlanConfirmation? confirmation;
        if (archivePlanProvider != null) {
          confirmation = await archivePlanProvider!(filePath);
          _isAwaitingPlanConfirmation = false;
          if (confirmation == null) {
            // 用户取消计划窗：提交态从未置位，无状态需复位
            notifyListeners();
            return;
          }
          // （解压流水线 C3：计划转存与习惯记忆已随任务迁移到安装中心）
        }
        // 计划已确认 → 现在才进入提交态（此刻出现的进度窗 = 正在解压）
        _isSubmitting = true;
        notifyListeners();
        // ★ Phase C（§1.1）：执行期喂首卷（非分卷 = 原路径）；
        //   7z 自行查找同目录其余卷。
        await startExtractFlow(
          gameName,
          confirmation?.plan.firstVolumePath ?? filePath,
          tags,
          planConfirmation: confirmation,
        );
      } else {
        // （解压流水线 C4：旧「解压-入库解耦」的表单接管分支已随
        //   handleExtractSuccess/_adoptExtractedDir 一并移除——压缩包流程
        //   改走安装中心确认窗一步收口；此处仅剩文件夹/exe 拷贝流程。）
        await startCopyFlow(gameName, filePath, tags);
      }
    } catch (e) {
      _isSubmitting = false;
      _isAwaitingPlanConfirmation = false;
      _errorMessage = extractErrorMessage(e.toString());
      notifyListeners();
    }
  }

  Future<void> startExtractFlow(
      String gameName, String archivePath, List<String> tags,
      {ArchivePlanConfirmation? planConfirmation}) async {
    debugPrint('[ADD] ════════════════════════════════');
    debugPrint('[ADD] 压缩包解压入库模式 → 安装中心队列（解压流水线 §C3）');

    // ★ 解压流水线：压缩包解压提交进安装中心串行队列，不再直接驱动
    //   GlobalTaskManager 的共享 ExtractManager（旧双轨是进度窗冻结与
    //   取消链路脆弱的根因）。执行期决策弹窗与确认入库窗由 main_container
    //   注入的钩子弹出；入库完成后库页刷新由 registry._notifyStructural
    //   自动收口，toast 由安装中心回调发出。表单数据在构造任务时全部
    //   快照（resetForm 均为重新赋值，不清空快照引用）。
    final coverPath = _coverFilePath;
    final hasCover = coverPath != null &&
        coverPath.isNotEmpty &&
        File(coverPath).existsSync();
    final screenshots = _screenshotUrls;
    final selected = _selectedResult;

    final task = InstallTask(
      gameId: 'local_${DateTime.now().millisecondsSinceEpoch}',
      title: gameName,
      description: descController.text.trim(),
      tags: tags,
      kind: InstallTaskKind.localArchive,
      localArchivePath: planConfirmation?.plan.firstVolumePath ?? archivePath,
      unpackPlan: planConfirmation?.plan,
      localCoverFilePath: hasCover ? coverPath : null,
      originalTitle: _originalTitle.isNotEmpty ? _originalTitle : gameName,
      metadataTitle: _metadataTitle,
      subtitle: subtitle,
      metadataSource: selected?['platform']?.toString() ?? '',
      metadataSourceId: selected?['platform_id']?.toString() ?? '',
      screenshotUrls:
          screenshots.isNotEmpty ? List<String>.of(screenshots) : null,
      developer: developerController.text.trim(),
      customGameLocation: planConfirmation?.extractLocation,
    );
    GlobalInstallCenter.instance.submitTask(task);

    onInfo?.call('《$gameName》已加入安装队列，解压完成后请确认入库');
    resetForm();
  }


  Future<void> writeStandardGameInfo({
    required String targetDirPath,
    required String gameName,
    required List<String> tags,
    String? sourceFilePath,
    required String source,
    String developer = '',
  }) async {
    try {
      final targetDir = Directory(targetDirPath);
      if (!targetDir.existsSync()) {
        debugPrint('[ADD] ⚠️ 目标目录不存在: $targetDirPath');
        return;
      }

      final detectedLaunchPath = detectLaunchExe(targetDirPath);

      await GameDataFormat.writeGameDir(
        targetDir: targetDirPath,
        title: gameName,
        description: descController.text.trim(),
        tags: tags,
        coverFilePath: sourceFilePath,
        launchPath: detectedLaunchPath,
        directoryPath: targetDirPath,
        source: 'local_import',
        developer: developer,
        screenshotUrls: _screenshotUrls.isNotEmpty ? _screenshotUrls : null,
        // 双标题持久化：_originalTitle 为空时用 gameName 兜底
        originalTitle: _originalTitle.isNotEmpty ? _originalTitle : gameName,
        subtitle: subtitle,
        metadataTitle: _metadataTitle,
        metadataSource: _selectedResult?['platform']?.toString() ?? '',
        metadataSourceId: _selectedResult?['platform_id']?.toString() ?? '',
      );

      // 通知截图后台抓取服务（入库完成后异步下载截图）
      if (_screenshotUrls.isNotEmpty) {
        ScreenshotFetchService.instance
            .enqueue(gameName, targetDirPath, _screenshotUrls);
      }
    } catch (e) {
      debugPrint('[ADD] ✗ 写入解压游戏元数据失败: $e');
    }
  }

  Future<void> startCopyFlow(
      String gameName, String sourcePath, List<String> tags) async {
    updateProgress(0.1, '分析文件结构...');
    await Future.delayed(const Duration(milliseconds: 300));

    final safeName = gameName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    String launchPath = '';
    String actualDirectoryPath = sourcePath;
    String effectiveGameName = safeName;

    if (Directory(sourcePath).existsSync()) {
      updateProgress(0.3, '检测启动程序...');
      await Future.delayed(const Duration(milliseconds: 200));
      launchPath = detectLaunchExe(sourcePath);
      actualDirectoryPath = sourcePath;
      effectiveGameName = safeName;
    } else if (File(sourcePath).existsSync() &&
        sourcePath.toLowerCase().endsWith('.exe')) {
      updateProgress(0.3, '确认可执行文件...');
      await Future.delayed(const Duration(milliseconds: 200));

      final exeFileName = sourcePath.split('\\').last;
      final parentDir = File(sourcePath).parent.path;

      launchPath = exeFileName;
      actualDirectoryPath = parentDir;
      // ★ WYSIWYG：始终使用用户在标题输入框中填写/切换后的名称（safeName），
      // 不再用父文件夹名覆盖。actualDirectoryPath 仍指向 EXE 所在的真实游戏目录。
      // 旧实现 effectiveGameName = safeParentName 会无条件丢弃用户编辑的标题，
      // 导致入库后标题变回文件夹名。
      effectiveGameName = safeName;
    } else {
      throw Exception('不支持的文件类型，请选择游戏文件夹或 EXE 文件');
    }

    updateProgress(0.5, '创建游戏数据目录...');
    await Future.delayed(const Duration(milliseconds: 200));

    await createStandardGameDirectory(
      gameName: effectiveGameName,
      originalPath: sourcePath,
      directoryPath: actualDirectoryPath,
      launchPath: launchPath,
      tags: tags,
      source: 'local_import',
      developer: developerController.text.trim(),
    );

    updateProgress(0.9, '注册到游戏库...');
    await Future.delayed(const Duration(milliseconds: 200));

    LocalGameRegistry.instance.registerExtractionComplete(
      gameTitle: effectiveGameName,
      directoryPath: actualDirectoryPath,
      // ★ v3.19: 内存对象的简介必须同源写入 —— 此前漏传，game.json 里有
      //   简介（writeGameDir 写过）但注册进内存的 LocalGame 是空串，
      //   库页/详情页显示空白，直到下次 scan()/重启才恢复（视图-模型脱节，
      //   用户感知「添加导入后简介丢失」）。
      description: descController.text.trim(),
      tags: tags,
      launchPath: launchPath,
      developer: developerController.text.trim(),
      subtitle: subtitle,
      metadataSource: _selectedResult?['platform']?.toString() ?? '',
      metadataSourceId: _selectedResult?['platform_id']?.toString() ?? '',
    );

    updateProgress(1.0, '完成！');
    await Future.delayed(const Duration(milliseconds: 600));

    onInfo?.call(_screenshotUrls.isNotEmpty
        ? '《$effectiveGameName》已成功入库，截图将在后台自动获取'
        : '《$effectiveGameName》已成功入库');
    onGameAdded?.call();
    resetForm();
  }

  Future<String> createStandardGameDirectory({
    required String gameName,
    required String originalPath,
    required String directoryPath,
    required String launchPath,
    required List<String> tags,
    required String source,
    String developer = '',
  }) async {
    final targetDir = Directory('${LocalGameRegistry.gamesBaseDir}/$gameName');
    if (!targetDir.existsSync()) {
      targetDir.createSync(recursive: true);
    }

    await GameDataFormat.writeGameDir(
      targetDir: targetDir.path,
      title: gameName,
      description: descController.text.trim(),
      tags: tags,
      coverFilePath: _coverFilePath,
      launchPath: launchPath,
      directoryPath: directoryPath,
      source: 'local_import',
      developer: developer,
      screenshotUrls: _screenshotUrls.isNotEmpty ? _screenshotUrls : null,
      // 双标题持久化：_originalTitle 为空时用 gameName 兜底
      originalTitle: _originalTitle.isNotEmpty ? _originalTitle : gameName,
      subtitle: subtitle,
      metadataTitle: _metadataTitle,
      metadataSource: _selectedResult?['platform']?.toString() ?? '',
      metadataSourceId: _selectedResult?['platform_id']?.toString() ?? '',
    );

    // 通知截图后台抓取服务（入库完成后异步下载截图）
    if (_screenshotUrls.isNotEmpty) {
      ScreenshotFetchService.instance
          .enqueue(gameName, targetDir.path, _screenshotUrls);
    }

    return targetDir.path;
  }

  /// 检测目录的启动程序（返回相对目录的路径，如 `Game.exe` / `bin/Game.exe`）
  ///
  /// ★ 2026-09-26 NAS 映射网络驱动器适配：改为委托
  /// [GameFolderScanner.detectLaunchExe]（批量导入 / 智能导入共用的**有界**
  /// 规范实现）。旧实现有两处问题：
  /// ① `listSync(recursive: true)` **无条数 / 深度 / 时间上限**，映射网络盘
  ///    或超大目录下会长时间冻结 UI isolate（「软件未响应」）；
  /// ② 排除关键字对**整条路径**做 `contains`，目录名含 "Install Patch" 时
  ///    会把该目录下**所有** exe 误判为安装程序而滤光（"0 个程序"，2026-09-13
  ///    已在其他四处实锤修复，此处是漏网的一处）。
  /// 委托后单文件导入与批量导入的启动程序判定口径完全一致。
  String detectLaunchExe(String targetDirPath) {
    return GameFolderScanner.detectLaunchExe(targetDirPath) ?? '';
  }

  String extractErrorMessage(dynamic e) {
    final msg = e.toString();
    if (msg.contains('FileSystemException')) return '文件操作失败';
    if (msg.contains('Permission')) return '权限不足';
    if (msg.contains('already exists')) return '同名游戏已存在';
    if (msg.contains('磁盘空间') || msg.contains('disk') || msg.contains('space'))
      return '磁盘空间不足';
    return msg.length > 60 ? msg.substring(0, 60) + '...' : msg;
  }

  void resetForm() {
    bumpGeneration(); // 强制重建左侧UI，防止残留旧Element
    nameController.clear();
    subtitleController.clear();
    tagsController.clear();
    descController.clear();
    developerController.clear();
    _coverFilePath = null;
    _tempCoverPath = null;
    _selectedFilePath = null;
    _selectedFileName = null;
    _errorMessage = null;
    _isSubmitting = false;
    _isScraping = false;
    _isBangumiSelected = true;
    _selectedScrapeSource = ScrapeSource.bangumi;
    _scrapeResults = [];
    _selectedResult = null;
    _screenshotUrls = [];
    // 清除双标题状态
    _originalTitle = '';
    _metadataTitle = null;
    _usingMetadataTitle = false;
    notifyListeners();
  }

  /// 清理元数据抓取结果（切换游戏时调用，避免残留）
  void clearScrapeResults() {
    _scrapeResults = [];
    _selectedResult = null;
    _screenshotUrls = [];
    notifyListeners();
  }

  /// 恢复截图URL数据（批量模式切换游戏时使用）
  void restoreScreenshotUrls(List<String> urls) {
    _screenshotUrls = urls;
    notifyListeners();
  }

  void cancelAndReset() {
    clearFileSelection();
    resetForm();
  }

  // Progress Management
  void updateProgress(double value, String message) {
    _progressValue = value.clamp(0.0, 1.0);
    _progressMessage = message;
    notifyListeners();
  }
}
