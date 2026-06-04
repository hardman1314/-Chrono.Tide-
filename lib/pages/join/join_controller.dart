import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:dio/dio.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import '../../services/local_game_registry.dart';
import '../../services/extract_manager.dart';
import '../../services/global_task_manager.dart';
import '../../services/metadata_fetcher.dart';
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';
import '../../services/game_data_format.dart';

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
  });

  // Getters
  String? get coverFilePath => _coverFilePath;
  String? get selectedFilePath => _selectedFilePath;
  String? get selectedFileName => _selectedFileName;
  bool get isDragging => _isDragging;
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
    nameController.dispose();
    tagsController.dispose();
    descController.dispose();
    developerController.dispose();
    final em = GlobalTaskManager.instance.dlCore.extractManager;
    em.removeListeners();
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

    _selectedResult = result;

    final gameName = result['game_name'];
    if (gameName != null && gameName.isNotEmpty) {
      nameController.text = gameName.toString();
      debugPrint('[SCRAPE] ✓ 已填入游戏名: $gameName');
    }

    final tags = result['tags'];
    if (tags != null && tags is List && tags.isNotEmpty) {
      tagsController.text =
          tags.map((t) => t.toString()).where((t) => t.isNotEmpty).join(', ');
      debugPrint('[SCRAPE] ✓ 已填入标签: ${tagsController.text}');
    }

    final summary = result['summary'];
    if (summary != null && summary.toString().isNotEmpty) {
      descController.text = summary.toString();
      debugPrint('[SCRAPE] ✓ 已填入简介 (${descController.text.length}字)');
    }

    final developer = result['developer'];
    if (developer != null && developer.toString().isNotEmpty) {
      developerController.text = developer.toString();
      debugPrint('[SCRAPE] ✓ 已填入会社: ${developerController.text}');
    }

    notifyListeners();

    final coverUrl = result['cover_url'];
    if (coverUrl != null && coverUrl.isNotEmpty) {
      debugPrint('[SCRAPE] 开始下载封面...');
      downloadAndSetCover(coverUrl.toString());
    } else {
      debugPrint('[SCRAPE] 无封面URL，跳过下载');
    }

    onSuccess?.call('已选择数据并填入表单');
  }

  Future<void> downloadAndSetCover(String url) async {
    try {
      debugPrint('[SCRAPE] 开始处理封面: $url');

      final tempDir = Directory.systemTemp;
      final ext = getImageExtensionFromUrl(url);
      final tempFile = File(
          '${tempDir.path}/scrape_cover_${DateTime.now().millisecondsSinceEpoch}.$ext');

      bool downloaded = false;

      try {
        debugPrint('[SCRAPE] 尝试从 CachedNetworkImage 缓存获取...');
        final cacheManager = DefaultCacheManager();
        final fileInfo = await cacheManager.getFileFromCache(url);

        if (fileInfo != null && fileInfo.file.existsSync()) {
          debugPrint('[SCRAPE] ✅ 找到缓存文件，直接复制: ${fileInfo.file.path}');
          await fileInfo.file.copy(tempFile.path);
          downloaded = true;
        } else {
          debugPrint('[SCRAPE] ⚠️ 缓存中未找到，开始网络下载...');
        }
      } catch (cacheError) {
        debugPrint('[SCRAPE] ⚠️ 缓存读取失败: $cacheError，改用网络下载');
      }

      if (!downloaded) {
        debugPrint('[SCRAPE] 使用 Dio 下载封面...');

        final dio = Dio();
        dio.options.connectTimeout = const Duration(seconds: 15);
        dio.options.receiveTimeout = const Duration(seconds: 30);
        dio.options.headers = {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
          'Referer': 'https://bgm.tv/',
        };

        final response = await dio.get<List<int>>(
          url,
          options: Options(responseType: ResponseType.bytes),
        );

        if (response.statusCode == 200 && response.data != null) {
          final bytes = response.data;

          if (bytes == null || bytes.isEmpty) {
            debugPrint('[SCRAPE] ⚠️ 封面数据为空');
            return;
          }

          await tempFile.writeAsBytes(bytes);
          downloaded = true;
          debugPrint('[SCRAPE] ✅ 封面下载成功: ${tempFile.path}');
        }
      }

      if (downloaded && tempFile.existsSync()) {
        _tempCoverPath = tempFile.path;
        _coverFilePath = tempFile.path;
        notifyListeners();
        debugPrint('[SCRAPE] ✅ 已更新UI显示封面');
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.connectionTimeout) {
        debugPrint('[SCRAPE] ❌ 封面下载超时 (${e.type})');
        onWarning?.call('封面图片加载超时，请稍后重试');
      } else {
        debugPrint('[SCRAPE] ❌ 封面下载失败: ${e.message}');
      }
    } catch (e, stackTrace) {
      debugPrint('[SCRAPE] ❌ 封面下载异常: $e');
      debugPrint('[SCRAPE] 堆栈: $stackTrace');
    }
  }

  String getImageExtensionFromUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri != null && uri.path.contains('.')) {
      final ext = uri.path.split('.').last.toLowerCase();
      if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'].contains(ext)) {
        return ext;
      }
    }
    return 'jpg';
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

  void handleExtractSuccess() {
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
        writeStandardGameInfo(
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

    // 注意：这里不再调用 onInfo 和 onGameAdded
    // 因为 handleExtractSuccess 通常是被 startCopyFlow 或其他流程调用的中间步骤
    // 最终的成功通知应该由调用者（如 startCopyFlow）统一发出
    // 避免重复提示
  }

  void writeStandardGameInfo({
    required String targetDirPath,
    required String gameName,
    required List<String> tags,
    String? sourceFilePath,
    required String source,
    String developer = '',
  }) {
    try {
      final targetDir = Directory(targetDirPath);
      if (!targetDir.existsSync()) {
        debugPrint('[ADD] ⚠️ 目标目录不存在: $targetDirPath');
        return;
      }

      final detectedLaunchPath = detectLaunchExe(targetDirPath);

      GameDataFormat.writeGameDir(
        targetDir: targetDirPath,
        title: gameName,
        description: descController.text.trim(),
        tags: tags,
        coverFilePath: sourceFilePath,
        launchPath: detectedLaunchPath,
        directoryPath: targetDirPath,
        source: 'local_import',
        developer: developer,
      );
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
      final parentFolderName = parentDir.split('\\').last;
      final safeParentName =
          parentFolderName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();

      launchPath = exeFileName;
      actualDirectoryPath = parentDir;
      effectiveGameName = safeParentName.isNotEmpty ? safeParentName : safeName;
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
    );

    updateProgress(1.0, '完成！');
    await Future.delayed(const Duration(milliseconds: 600));

    _isProgressSuccess = true;
    notifyListeners();

    await Future.delayed(const Duration(milliseconds: 500));

    onInfo?.call('《$effectiveGameName》已成功入库');
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
    );

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
