import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../../services/local_game_registry.dart';
import '../../services/extract_manager.dart';
import '../../services/global_task_manager.dart';
import '../../services/metadata_fetcher.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';
import '../../services/game_data_format.dart';
import '../../services/screenshot_fetch_service.dart';
import '../../services/cover_download_service.dart';

enum ScrapeSource { bangumi, vndb }

class _PendingCoverData {
  final String? sourceFilePath;
  final String gameName;
  final List<String> tags;
  final String developer;

  _PendingCoverData({
    this.sourceFilePath,
    required this.gameName,
    required this.tags,
    this.developer = '',
  });
}

class JoinController extends ChangeNotifier {
  final TextEditingController nameController = TextEditingController();
  final TextEditingController tagsController = TextEditingController();
  final TextEditingController descController = TextEditingController();
  final TextEditingController developerController = TextEditingController();

  String? _coverFilePath;
  String? _selectedFilePath;
  String? _selectedFileName;
  bool _isDragging = false;
  bool _isSubmitting = false;
  bool _isScraping = false;
  String? _errorMessage;

  double _progressValue = 0;
  String _progressMessage = '';
  bool _isProgressSuccess = false;
  bool _isProgressFailed = false;
  bool _isCancelled = false;
  _PendingCoverData? _pendingCoverData;

  ScrapeSource? _selectedScrapeSource;
  bool _isBangumiSelected = true;
  String? _tempCoverPath;

  List<Map<String, dynamic>> _scrapeResults = [];
  Map<String, dynamic>? _selectedResult;
  List<String> _screenshotUrls = [];
  int _scrapeCoverVersion = 0; // 元数据选择时的封面下载版本号
  int _selectionGeneration = 0; // 元数据选择次数计数器，用于强制重建左侧UI

  // 双标题管理：
  // - _originalTitle：导入时从文件夹/文件名提取（不可变）
  // - _metadataTitle：元数据抓取到的标准游戏名（抓取后赋值）
  // - _usingMetadataTitle：nameController 当前显示的是否为元数据标题
  //   抓取后默认切 true（用户已确认）；用户可通过 UI 切换回原标题
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

  bool get isSubmitting => _isSubmitting;
  bool get isScraping => _isScraping;
  String? get errorMessage => _errorMessage;
  double get progressValue => _progressValue;
  String get progressMessage => _progressMessage;
  bool get isProgressSuccess => _isProgressSuccess;
  bool get isProgressFailed => _isProgressFailed;
  bool get isCancelled => _isCancelled;
  bool get isBangumiSelected => _isBangumiSelected;
  List<Map<String, dynamic>> get scrapeResults => _scrapeResults;
  Map<String, dynamic>? get selectedResult => _selectedResult;

  bool get canSubmit =>
      nameController.text.trim().isNotEmpty &&
      _selectedFilePath != null &&
      !_isSubmitting;

  bool get isArchiveType {
    if (_selectedFilePath == null) return false;
    final type = detectFileType(_selectedFilePath!);
    return ['zip', 'rar', '7z', 'tar', 'gz'].contains(type);
  }

  void initListeners() {
    final em = GlobalTaskManager.instance.dlCore.extractManager;
    em.addStatusListener(_onExtractStatusChanged);
    em.addProgressListener(_onExtractProgress);
    em.addSuccessListener(_onExtractSuccess);
    em.addFailureListener(_onExtractFailure);
  }

  void dispose() {
    nameController.removeListener(_onNameChanged);
    nameController.dispose();
    tagsController.dispose();
    descController.dispose();
    developerController.dispose();
    final em = GlobalTaskManager.instance.dlCore.extractManager;
    em.removeStatusListener(_onExtractStatusChanged);
    em.removeProgressListener(_onExtractProgress);
    em.removeSuccessListener(_onExtractSuccess);
    em.removeFailureListener(_onExtractFailure);
    super.dispose();
  }

  void _onExtractStatusChanged(ExtractStatus status) {
    if (status == ExtractStatus.completed || status == ExtractStatus.failed) {
      _isProgressSuccess = status == ExtractStatus.completed;
      _isProgressFailed = status == ExtractStatus.failed;
      notifyListeners();
    }
  }

  void _onExtractProgress(ExtractProgress progress) {
    _progressValue = progress.percent / 100;
    _progressMessage = progress.message;
    notifyListeners();
  }

  void _onExtractFailure(String error) {
    _isSubmitting = false;
    notifyListeners();
    Future.delayed(const Duration(milliseconds: 500), () {
      _errorMessage =
          error.length > 80 ? '${error.substring(0, 80)}...' : error;
      notifyListeners();
    });
  }

  void _onExtractSuccess() {
    // 这个方法会在主页面中通过handleExtractSuccess处理
    _isProgressSuccess = true;
    notifyListeners();
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
      final fileType = detectFileType(path);

      _selectedFilePath = path;
      _selectedFileName = fileName;
      _errorMessage = null;
      notifyListeners();

      String gameName = '';
      if (fileType == 'exe') {
        final parentDir = File(path).parent.path;
        gameName = parentDir.split('/').last.split('\\').last;
        debugPrint('[ADD] 选择EXE文件: $fileName → 使用父目录名作为游戏名: $gameName');
      } else if (isArchiveExt(path)) {
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
    notifyListeners();
  }

  String? detectFileType(String path) {
    if (Directory(path).existsSync()) return 'folder';
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
        // 用户已确认：选择元数据后默认显示元数据标题
        _usingMetadataTitle = true;
        nameController.text = gameName.toString();
        debugPrint('[SCRAPE] ✓ 已填入游戏名（元数据标题）: $gameName');
      } else {
        debugPrint('[SCRAPE] 🔒 游戏名已锁定，跳过覆盖（但已记录 metadataTitle）');
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
    final tempDir = Directory.systemTemp;
    final ext = CoverDownloadService.detectExtension(url);
    final fileName =
        'scrape_cover_${DateTime.now().millisecondsSinceEpoch}.$ext';

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

    _isSubmitting = true;
    _errorMessage = null;
    _isCancelled = false;
    notifyListeners();

    try {
      if (isArchiveType) {
        await startExtractFlow(gameName, filePath, tags);
      } else {
        await startCopyFlow(gameName, filePath, tags);
      }
    } catch (e) {
      _isSubmitting = false;
      _errorMessage = extractErrorMessage(e.toString());
      notifyListeners();
    }
  }

  Future<void> startExtractFlow(
      String gameName, String archivePath, List<String> tags) async {
    debugPrint('[ADD] ════════════════════════════════');
    debugPrint('[ADD] 压缩包解压入库模式');

    GlobalTaskManager.instance.dlCore.extractManager.start(
      archivePath: archivePath,
      gameTitle: gameName,
      gameDescription: descController.text.trim(),
      gameCoverUrl: '',
      gameTags: tags,
    );

    if (_coverFilePath != null && File(_coverFilePath!).existsSync()) {
      _pendingCoverData = _PendingCoverData(
        sourceFilePath: _coverFilePath,
        gameName: gameName,
        tags: tags,
        developer: developerController.text.trim(),
      );
    } else {
      _pendingCoverData = _PendingCoverData(
        gameName: gameName,
        tags: tags,
        developer: developerController.text.trim(),
      );
    }
  }

  Future<void> handleExtractSuccess() async {
    if (_pendingCoverData != null) {
      final pending = _pendingCoverData!;
      final safeName =
          pending.gameName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
      final candidate = '${LocalGameRegistry.gamesBaseDir}/$safeName';

      String? targetDir;
      if (Directory(candidate).existsSync()) {
        targetDir = candidate;
      } else {
        for (int i = 1; i < 100; i++) {
          final alt = '${LocalGameRegistry.gamesBaseDir}/${safeName}_$i';
          if (Directory(alt).existsSync()) {
            targetDir = alt;
            break;
          }
        }
      }

      if (targetDir != null) {
        await writeStandardGameInfo(
          targetDirPath: targetDir!,
          gameName: pending.gameName,
          tags: pending.tags,
          sourceFilePath: pending.sourceFilePath,
          source: 'local_import',
          developer: pending.developer,
        );
      }
      _pendingCoverData = null;
    }

    onGameAdded?.call();

    // 注意：这里不再调用 onInfo
    // 因为 handleExtractSuccess 通常是被 startCopyFlow 或其他流程调用的中间步骤
    // 最终的成功通知应该由调用者（如 startCopyFlow）统一发出
    // 避免重复提示
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
      tags: tags,
      launchPath: launchPath,
      developer: developerController.text.trim(),
      metadataSource: _selectedResult?['platform']?.toString() ?? '',
      metadataSourceId: _selectedResult?['platform_id']?.toString() ?? '',
    );

    updateProgress(1.0, '完成！');
    await Future.delayed(const Duration(milliseconds: 600));

    _isProgressSuccess = true;
    notifyListeners();

    await Future.delayed(const Duration(milliseconds: 500));

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

  String detectLaunchExe(String targetDirPath) {
    try {
      final dir = Directory(targetDirPath);
      if (!dir.existsSync()) return '';
      final exeFiles = <MapEntry<File, int>>[];
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity is File) {
          final name = entity.path.toLowerCase();
          if (name.endsWith('.exe') &&
              !name.contains('uninstall') &&
              !name.contains('setup') &&
              !name.contains('installer')) {
            try {
              exeFiles.add(MapEntry(entity, entity.lengthSync()));
            } catch (_) {}
          }
        }
      }
      if (exeFiles.isEmpty) return '';

      for (final entry in exeFiles) {
        final name = entry.key.path;
        if (name.toLowerCase().contains('chs') ||
            name.toLowerCase().contains('_cn') ||
            name.toLowerCase().contains('_zh') ||
            name.contains('汉化') ||
            name.contains('中文') ||
            name.contains('简中')) {
          final relPath = entry.key.path
              .replaceFirst('$targetDirPath\\', '')
              .replaceFirst('$targetDirPath/', '');
          return relPath;
        }
      }

      exeFiles.sort((a, b) => b.value.compareTo(a.value));
      final allMax = exeFiles.first;
      final relPathAll = allMax.key.path
          .replaceFirst('$targetDirPath\\', '')
          .replaceFirst('$targetDirPath/', '');
      return relPathAll;
    } catch (e) {
      debugPrint('[ADD] detectLaunchExe异常: $e');
      return '';
    }
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

  void resetProgress() {
    _progressValue = 0;
    _progressMessage = '';
    _isProgressSuccess = false;
    _isProgressFailed = false;
    _isSubmitting = false;
    notifyListeners();
  }

  void cancelOperation() {
    _isCancelled = true;
    if (isArchiveType) {
      GlobalTaskManager.instance.dlCore.extractManager.cancel();
    }
    resetForm();
  }
}
