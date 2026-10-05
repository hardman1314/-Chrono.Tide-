import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'local_game_registry.dart';
import 'rar_lz4_unzip_service.dart';
import 'game_launcher_detector.dart';
import 'game_data_format.dart';
import 'install_path_preference.dart';
import 'seven_zip_progress.dart';
import 'archive_inspector.dart';
import 'enc/enc_decryptor.dart';
import 'unpack_plan.dart';
import 'unpack_store.dart';
import '../core/path_helper.dart';
import '../utils/fs_scan.dart';

enum ExtractStatus {
  idle,
  extracting,
  completed,
  failed,
}

class ExtractProgress {
  final double percent;
  final String currentFile;
  final int extractedFiles;
  final int totalFiles;
  final String message;

  const ExtractProgress({
    required this.percent,
    this.currentFile = '',
    this.extractedFiles = 0,
    this.totalFiles = 0,
    this.message = '',
  });
}

/// ★ Phase A（features/join_unpack_scenarios_v2.md §1.2）：执行期解压候选。
/// 产物重扫时发现的「可能是下一个待解压对象」的文件。格式判定来源两个：
/// [magicFormat]（魔数嗅探，高置信）与 [nameFormat]（文件名后缀推断，
/// 低置信，可被伪装欺骗）。两者皆空的双未命中文件不会进入候选
/// （未知后缀的纳入与自动尝试属 Phase B 候选链）。
class ExtractCandidate {
  final String path;
  final String? magicFormat;
  final String? nameFormat;

  /// 文件名末尾后缀（小写含点；仅供 UI 展示与歧义推荐，Phase D 用）
  final String? declaredExt;
  final int sizeBytes;

  const ExtractCandidate({
    required this.path,
    this.magicFormat,
    this.nameFormat,
    this.declaredExt,
    required this.sizeBytes,
  });

  /// 该候选的执行格式：魔数优先，文件名兜底（与层循环判定链一致）
  String? get resolvedFormat => magicFormat ?? nameFormat;
}

/// ★ Phase A（§1.4）：执行期统一决策请求。kind 区分四类异常通道：
/// `password`（补输密码）/ `strategy`（后缀映射未知）/ `ambiguity`
/// （多文件歧义，Phase D）/ `corrupt`（损坏分类，Phase F）。
/// 服务层不持 BuildContext，弹窗由页面层经 JoinController 注入。
class ExtractDecisionRequest {
  /// 'password' | 'strategy' | 'ambiguity' | 'corrupt'
  final String kind;

  /// 展示给用户的原因文案（已按层号/文件名组织好）
  final String message;

  /// 当前层输入包路径（strategy 场景 = 触发决策的嵌套文件）
  final String archiveFile;

  /// 当前层格式（strategy 场景 = 决策前的未定格式，兜底沿用值）
  final String format;
  final int layerIndex;

  /// password 场景：已试过的候选数
  final int triedCount;

  /// strategy/ambiguity 场景：候选列表（ambiguity 为 Phase D 预留）
  final List<ExtractCandidate> candidates;

  /// ★ Phase B：strategy 场景可自动尝试的候选格式链（空 = 不提供自动
  /// 尝试选项；enc 已按密码可用性过滤）。UI 据此决定是否展示「自动尝试」。
  final List<String> tryFormats;

  /// ★ Phase D：ambiguity 场景的推荐本体路径（null = 不推荐——数量接近
  /// 或无后缀区分度，见 §1.2 推荐引擎）。
  final String? recommendPath;

  const ExtractDecisionRequest({
    required this.kind,
    required this.message,
    required this.archiveFile,
    required this.format,
    required this.layerIndex,
    this.triedCount = 0,
    this.candidates = const [],
    this.tryFormats = const [],
    this.recommendPath,
  });
}

/// ★ Phase A：决策窗的用户响应，字段按 kind 取用：
/// - password → [password]；
/// - strategy → [proceed]=false 表示终止解压；proceed=true 时
///   [autoTry]=true 表示走自动尝试候选链（此时 [format] 为空），否则
///   [format] 为手动指定的格式；
/// - ambiguity（Phase D 预留）→ [chosenPath]。
/// 整体返回 null = 钩子未注入/用户放弃，调用方走既有失败路径。
class ExtractDecisionResult {
  final bool proceed;
  final bool autoTry;
  final String? format;
  final String? password;
  final String? chosenPath;

  const ExtractDecisionResult({
    this.proceed = true,
    this.autoTry = false,
    this.format,
    this.password,
    this.chosenPath,
  });
}

/// ★ Phase E（§1.3）：游戏本体识别结论。
enum _BodyResolution {
  /// 已确认到达本体（目录结构达标 / 用户确认）→ 正常收尾
  finished,

  /// 本体实为 SFX 自解压包 / 伪装压缩层 → 以该文件继续下一层
  continueAsArchive,

  /// 用户在「未找到本体」弹窗取消 → 走既有失败清理
  cancelled,
}

class ExtractManager {
  static final String _gamesBaseDir = PathHelper.gamesDir;
  static final String _logsDir = PathHelper.logsDir;
  static final String _downloadsDir = PathHelper.downloadsDir;
  static const String _defaultPassword = 'Bilibili_Slpeey';
  static final String _toolsDir = PathHelper.toolsDir;

  static int _activeTaskCount = 0;
  static bool get hasActiveTask => _activeTaskCount > 0;

  static final Set<String> _registeredGames = {};
  static int _registrationCount = 0;

  ExtractStatus _status = ExtractStatus.idle;
  ExtractProgress? _progress;
  String? _errorMessage;
  String? _currentArchivePath;
  /// ★ 2026-09-26 P1-4：云端来源主键（探索库云端记录 record.id），
  /// 由 [start] 传入，落库时写入 game.json 的 `cloud_game_id`。
  String? _cloudGameId;
  String? _targetGameDir;
  String? _actualGameDir;

  /// ★ 2026-10-04 智能解压（方案 §4.5）：`waiting_for_input` 暂停补输。
  ///
  /// plan 路径某层密码候选队列全败且错误为密码相关时触发（由 UI 层经
  /// JoinController 注入，服务层不持 BuildContext）。返回用户补输的密码；
  /// null/空 = 用户放弃，走既有失败路径。未注入（老路径/批量导入/智能导入）
  /// 时行为与此前完全一致——仅单文件导入的计划驱动解压会触发。
  Future<String?> Function({
    required String archiveFile,
    required String format,
    required int layerIndex,
    required int triedCount,
  })? onPasswordNeeded;

  /// ★ Phase A（join_unpack_scenarios_v2.md §1.2/§1.4）：执行期统一决策钩子。
  ///
  /// password/strategy（及后续 ambiguity/corrupt）四类执行期异常的统一
  /// 请求-响应通道：注入后所有决策经它走 UI 弹窗。未注入时 password 场景
  /// 回落 [onPasswordNeeded]（老路径/批量导入/智能导入兼容），其余维持
  /// 既有行为。dispose 时必须置 null（见 JoinController.dispose）。
  Future<ExtractDecisionResult?> Function(ExtractDecisionRequest request)?
      onExtractDecision;

  /// ★ 2026-10-05 需求 #6：系统操作日志钩子（安装中心日志面板实时展示）。
  ///
  /// 仅内存转发（面板不落盘），内容 = 用户可读的系统动作：改后缀试解、
  /// 调用解压工具、密码队列组装、系统判定等。未注入时为空操作。
  /// 注意：**不得**把密码明文写入（与 _log 同一安全纪律）。
  void Function(String message)? onOpLog;

  /// 操作日志发射器（轻量：无监听者时零成本）
  void _op(String message) {
    final sink = onOpLog;
    if (sink != null) sink(message);
  }

  /// ★ IMP-06（2026-09-12 导入审查）：本任务**自己创建**的中间压缩包路径集合。
  ///
  /// 失败回滚的"步骤3"原先会扫描目标目录并删除其中所有 `.rar/.zip/.7z/.tar`
  /// （仅排除当前压缩包），一旦目标目录与用户目录重叠就会删掉用户自己的压缩包。
  /// 现在改为只清理这里登记过的文件；集合为空则什么都不删（安全默认）。
  final Set<String> _taskOwnedTempArchives = {};
  Process? _currentProcess;
  bool _isCancelled = false;
  // 会话级日志时间戳:同一次解压任务内所有 _log() 调用复用同一时间戳,
  // 避免秒级时间戳生成多个 extract_*.txt 文件(修复日志爆炸问题)。
  String? _sessionLogTs;

  final List<void Function(ExtractStatus)> _statusListeners = [];
  final List<void Function(ExtractProgress)> _progressListeners = [];
  final List<void Function()> _successListeners = [];
  final List<void Function(String)> _failureListeners = [];

  ExtractStatus get status => _status;
  ExtractProgress? get progress => _progress;
  String? get errorMessage => _errorMessage;
  String? get targetGameDir => _targetGameDir;
  String? get actualGameDir => _actualGameDir;
  String get gamesBaseDir => _gamesBaseDir;

  /// 获取用于验证的首选目录：优先实际解压目录，其次元数据目录
  String? get preferredVerifyDir {
    if (_actualGameDir != null && _actualGameDir!.isNotEmpty) {
      return _actualGameDir;
    }
    return _targetGameDir;
  }

  void addStatusListener(void Function(ExtractStatus) listener) {
    _statusListeners.add(listener);
  }

  void addProgressListener(void Function(ExtractProgress) listener) {
    _progressListeners.add(listener);
  }

  void addSuccessListener(void Function() listener) {
    _successListeners.add(listener);
  }

  void addFailureListener(void Function(String) listener) {
    _failureListeners.add(listener);
  }

  void removeListeners() {
    _statusListeners.clear();
    _progressListeners.clear();
    _successListeners.clear();
    _failureListeners.clear();
  }

  void removeStatusListener(void Function(ExtractStatus) listener) {
    _statusListeners.remove(listener);
  }

  void removeProgressListener(void Function(ExtractProgress) listener) {
    _progressListeners.remove(listener);
  }

  void removeSuccessListener(void Function() listener) {
    _successListeners.remove(listener);
  }

  void removeFailureListener(void Function(String) listener) {
    _failureListeners.remove(listener);
  }

  void _emitStatus(ExtractStatus s) {
    _status = s;
    for (final l in _statusListeners) {
      l(s);
    }
  }

  void _emitProgress(ExtractProgress p) {
    _progress = p;
    for (final l in _progressListeners) {
      l(p);
    }
  }

  void _emitSuccess() {
    for (final l in _successListeners) {
      l();
    }
  }

  void _emitFailure(String msg) {
    for (final l in _failureListeners) {
      l(msg);
    }
  }

  Future<String> _getToolPath(String toolName) async {
    final toolDir = Directory(_toolsDir);
    if (!await toolDir.exists()) {
      await toolDir.create(recursive: true);
    }

    final destPath = '$_toolsDir/$toolName';
    final destFile = File(destPath);

    if (!await destFile.exists()) {
      _log('INFO', '从Flutter Assets提取工具: $toolName');
      final byteData = await rootBundle.load('assets/tools/$toolName');
      final bytes = byteData.buffer.asUint8List();
      await destFile.writeAsBytes(bytes);

      if (Platform.isWindows) {
        await Process.run('attrib', ['+h', destPath], runInShell: true);
      }
      _log('INFO',
          '工具提取完成: $destPath (${(bytes.length / 1024).toStringAsFixed(1)}KB)');
    }

    return destPath;
  }

  Future<Process> _startSilentProcess(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    return await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      mode: ProcessStartMode.normal,
      includeParentEnvironment: true,
    );
  }

  Future<void> start({
    required String archivePath,
    required String gameTitle,
    String? gameDescription,
    String? gameCoverUrl,
    String? gameBannerUrl,
    List<String>? gameTags,
    String? gameDeveloper,
    String? customGameLocation,
    List<String>? screenshotUrls,
    String? gameSubtitle,
    String? cloudGameId,
    UnpackPlan? unpackPlan,
  }) async {
    if (_status == ExtractStatus.extracting) {
      _log('WARN', '已有解压任务在执行，忽略重复请求');
      return;
    }

    _currentArchivePath = archivePath;
    _cloudGameId = cloudGameId;
    _errorMessage = null;
    _isCancelled = false;
    _sessionLogTs = null; // 重置会话时间戳,新任务生成新日志文件
    _taskOwnedTempArchives.clear(); // ★ IMP-06: 新任务重置自建中间包登记

    _log('INFO', '========== 开始解压任务 ==========');
    _log('INFO', '压缩包路径: $archivePath');
    _log('INFO', '游戏标题: $gameTitle');

    final archiveFile = File(archivePath);
    if (!await archiveFile.exists()) {
      final msg = '压缩包文件不存在: $archivePath';
      _log('ERROR', msg);
      _handleError(msg);
      return;
    }

    for (final dirPath in [
      PathHelper.downloadsDir,
      PathHelper.toolsDir,
      PathHelper.gamesDir
    ]) {
      final dir = Directory(dirPath);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
        _log('INFO', '创建目录: $dirPath');
      }
    }

    final formats = _detectFormats(archivePath);

    // ★ 2026-10-04 智能解压 Phase 1（G2）：文件名链认不出 → 魔数嗅探兜底。
    // 伪装包（.zip 改名 .mp4/.mov 等）在 join_controller 已被嗅探放行，
    // 此处用内容魔数还原真实格式（Phase 0 T14 实测 7z 对后缀免疫，
    // 嗅探结果可直接解压）。解压器不依赖文件名，故无需真实改名。
    if (formats.isEmpty) {
      final sniff = ArchiveInspector.sniffSync(archivePath);
      if (sniff.format != null) {
        formats.add('.${sniff.format}');
        _log('INFO',
            '🎭 扩展名未命中格式表，魔数嗅探兜底: 真实格式=${sniff.format}'
            ' 声明后缀=${sniff.declaredExt}（伪装包，按内容处理）');
      }
    }

    if (formats.isEmpty) {
      final msg = '无法识别的压缩格式: $archivePath';
      _log('ERROR', msg);
      _handleError(msg);
      return;
    }

    _log('INFO',
        '检测到格式: ${formats.join(" → ")} ${formats.length > 1 ? "(双层/多层压缩)" : ""}');

    _targetGameDir = await _resolveGameDir(gameTitle);
    _log('INFO', '📋 元数据目录(固定): $_targetGameDir');

    late String extractionTargetDir;
    final effectiveLocation =
        await _resolveEffectiveLocation(customGameLocation);
    extractionTargetDir = await _determineExtractionTarget(
      effectiveLocation: effectiveLocation,
      gameTitle: gameTitle,
    );
    _actualGameDir = extractionTargetDir;

    _log('INFO', '✅ 安装方案确定:');
    _log('INFO', '   游戏本体 → $extractionTargetDir');
    _log('INFO', '   元数据   → $_targetGameDir');

    try {
      _emitStatus(ExtractStatus.extracting);
      _activeTaskCount++;

      if (!await Directory(extractionTargetDir).exists()) {
        await Directory(extractionTargetDir).create(recursive: true);
        _log('INFO', '已创建解压目标目录: $extractionTargetDir');
      }

      final isRarLz4Format = archivePath.toLowerCase().endsWith('.rar.lz4');

      if (unpackPlan != null) {
        // ★ 2026-10-04 智能解压 Phase 3：计划驱动执行（方案 §4.1/§4.5）。
        // 层级动态发现：每层解压后重扫产物，发现嵌套压缩包继续；
        // 密码走候选队列（用户按层预设→记忆库→内置表）。.rar.lz4 也在
        // plan 路径内自然覆盖（lz4 层解出 rar 后续链），故置于此特判之前。
        _log('INFO', '');
        _log('INFO', '【计划驱动解压】用户已确认解压计划（${unpackPlan.layers.length} 层预设）');
        _log('INFO', '');

        await _executePlanExtract(
          plan: unpackPlan,
          archivePath: archivePath,
          extractionTargetDir: extractionTargetDir,
        );

        _log('INFO', '✅ 【计划驱动解压】全部层完成');
      } else if (isRarLz4Format) {
        _log('INFO', '');
        _log('INFO', '【.rar.lz4 格式检测】使用 Dart 原生 bz.exe + UnRAR.exe 方案处理');
        _log('INFO', '🔹 bz.exe(Bandizip) 解 LZ4 外层 → UnRAR.exe 解 RAR 内层（密码内置）');
        _log('INFO', '');

        _emitProgress(
            const ExtractProgress(percent: 5, message: '正在初始化解压工具...'));

        await _extractRarLz4(
          archivePath: archivePath,
          outputDir: extractionTargetDir,
        );

        _log('INFO', '✅ 【.rar.lz4】专用解压完成');
      } else {
        var currentPath = archivePath;
        for (int i = 0; i < formats.length; i++) {
          final fmt = formats[i];
          final isLast = i == formats.length - 1;
          final outputDir = isLast
              ? extractionTargetDir
              : '$extractionTargetDir._temp_layer_$i';

          _log('INFO', '--- 第${i + 1}层解压: $fmt ---');

          double layerStartPercent;
          double layerEndPercent;

          if (formats.length == 2 && formats[0] == '.lz4') {
            layerStartPercent = 0.0;
            layerEndPercent = 50.0;
          } else if (formats.length == 2 && formats[1] == '.lz4') {
            layerStartPercent = (i == 0) ? 0.0 : 50.0;
            layerEndPercent = (i == 0) ? 50.0 : 100.0;
          } else {
            layerStartPercent = (i / formats.length) * 100;
            layerEndPercent = ((i + 1) / formats.length) * 100;
          }

          _emitProgress(ExtractProgress(
            percent: layerStartPercent,
            message: '正在解压($fmt)...',
          ));

          final isFromLz4Layer = i > 0 && formats[i - 1] == '.lz4';

          currentPath = await _extractSingleFormat(
            currentPath,
            fmt,
            outputDir,
            startPercent: layerStartPercent,
            endPercent: layerEndPercent,
            isFromLz4: isFromLz4Layer,
          );
          _log('INFO', '第${i + 1}层($fmt)解压完成');

          _emitProgress(ExtractProgress(
            percent: layerEndPercent,
            message: '第${i + 1}/${formats.length}层完成',
          ));

          if (!isLast && i < formats.length - 1) {
            _log('INFO', '准备下一层解压...');
          }
        }
      }

      _log('INFO', '全部解压完成，开始最终校验...');

      await Future.delayed(const Duration(milliseconds: 500));

      final targetDirCheck = Directory(extractionTargetDir);
      int finalFileCount = 0;
      List<String> foundExes = [];

      if (await targetDirCheck.exists()) {
        // ★ P0-7：流式统计（旧实现 list(recursive:true).toList() 在这类大目录上
        // 会一次性物化百万级条目 → OOM 崩溃路径）
        finalFileCount = (await FsScan.countRecursive(targetDirCheck)).files;

        final exePaths = await FsScan.collectFilePaths(
          targetDirCheck,
          test: (p) => p.endsWith('.exe'),
        );
        for (final exePath in exePaths) {
          foundExes.add(exePath.split(RegExp(r'[/\\]')).last);
        }

        _log(
            'INFO', '最终校验 | 总文件数: $finalFileCount | EXE数: ${foundExes.length}');
        if (foundExes.isNotEmpty) {
          for (final e in foundExes) {
            _log('INFO', '   ✓ $e');
          }
        } else {
          _log('WARN', '   ⚠️ 未找到任何.exe文件！');
          _log('WARN', '   这可能导致游戏无法启动，请检查压缩包是否完整');
        }

        if (finalFileCount <= 3) {
          _log('ERROR', '   ❌ 文件数量异常少($finalFileCount)，解压可能不完整');
        }
      } else {
        _log('ERROR', '❌ 解压目标目录不存在: $extractionTargetDir');
      }

      _emitProgress(const ExtractProgress(percent: 96, message: '清理临时文件...'));

      // ★ 2026-10-04 智能解压 Phase 3（v3 决策 §4.7b）：计划驱动路径保留
      // 源压缩包（完成后由 UI 弹窗确认是否删除，默认保留）；老路径维持
      // 现状（解压成功即删）。
      if (unpackPlan == null && await archiveFile.exists()) {
        await archiveFile.delete();
        _log('INFO', '已删除原压缩包: $archivePath');
      }

      for (int i = 0; i < formats.length - 1; i++) {
        final tempDir = Directory('$extractionTargetDir._temp_layer_$i');
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
          _log('INFO', '已清理临时目录: $extractionTargetDir._temp_layer_$i');
        }
      }

      // ★ 2026-10-04 P0 修复（解压-入库解耦第二轮）：计划驱动路径**不写
      //   任何元数据**——_writeGameInfo 把 game.json 落到 Games/<title>，
      //   LocalGameRegistry.scan() 发现有 game.json 的目录即视为已入库
      //   → 用户没点「确认入库」游戏就出现在库页（真机实测复现）。
      //   元数据延后到 JoinController._finalizeAdoptedExtraction：
      //   用户点「确认入库」时才创建元数据目录并写入。
      if (unpackPlan == null) {
        _emitProgress(const ExtractProgress(percent: 98, message: '写入游戏元数据...'));

        if (!_targetGameDir!.startsWith(extractionTargetDir)) {
          if (!await Directory(_targetGameDir!).exists()) {
            await Directory(_targetGameDir!).create(recursive: true);
            _log('INFO', '已创建元数据目录: $_targetGameDir');
          }
        }

        await _writeGameInfo(
          targetDir: _targetGameDir!,
          title: gameTitle,
          description: gameDescription,
          coverUrl: gameCoverUrl,
          bannerUrl: gameBannerUrl,
          tags: gameTags,
          developer: gameDeveloper,
          overrideDirectoryPath: extractionTargetDir,
          screenshotUrls: screenshotUrls,
          subtitle: gameSubtitle,
          cloudGameId: _cloudGameId,
        );

        await _embedCoverBase64(
          targetDir: _targetGameDir!,
          coverUrl: gameCoverUrl,
        );
      } else {
        _log('INFO', '📦 计划驱动路径：元数据延后（用户点「确认入库」时写入）');
        _emitProgress(const ExtractProgress(percent: 98, message: '准备最终结果...'));
      }

      _log('SUCCESS', '========== 解压任务完成 ==========');
      _log('SUCCESS', '✅ 游戏本体已安装到: $extractionTargetDir');
      _log('SUCCESS', '✅ 游戏元数据已写入: $_targetGameDir');

      _emitProgress(const ExtractProgress(percent: 100, message: '解压完成'));
      _emitStatus(ExtractStatus.completed);
      if (_activeTaskCount > 0) _activeTaskCount--;

      // directoryPath 应使用游戏本体实际解压目录，而非元数据目录
      // 这样"打开目录"才能打开游戏启动程序所在的目录
      final gamePath = extractionTargetDir.isNotEmpty
          ? extractionTargetDir
          : (_targetGameDir ?? '');
      final gameId = _currentArchivePath ?? '';

      if (_registeredGames.contains(gamePath)) {
        _log('WARN', '⚠️ 游戏已入库，跳过重复注册');
        _log('INFO', '   游戏ID: $gameId');
        _log('INFO', '   游戏路径: $gamePath');
        _log('INFO', '   当前已入库游戏数: ${_registeredGames.length}');
      } else if (unpackPlan != null) {
        // ★ 2026-10-04 真机反馈（解压-入库解耦）：计划驱动路径**不在此处
        // 入库**。单文件导入的流程语义 = 解压完成后表单接管解压产物，
        // 用户继续完善资料，点「确认入库」时才注册（JoinController
        // _finalizeAdoptedExtraction）。此时尚未入库，避免表单还没确认
        // 库里就多出一条。
        _log('INFO', '📦 计划驱动路径：暂不入库（等待用户确认入库）');
      } else {
        _registrationCount++;
        _log('INFO', '');
        _log('INFO', '📦 ========== 执行入库逻辑 ==========');
        _log('INFO', '   入库次数: #$_registrationCount');
        _log('INFO', '   游戏ID: $gameId');
        _log('INFO', '   游戏路径: $gamePath');
        _log('INFO',
            '   当前已入库游戏数: ${_registeredGames.length} → ${_registeredGames.length + 1}');

        LocalGameRegistry.instance.registerExtractionComplete(
          gameTitle: gameTitle,
          directoryPath: gamePath,
          developer: gameDeveloper,
          subtitle: gameSubtitle,
        );

        _registeredGames.add(gamePath);

        _log('INFO', '✅ 入库完成 | 累计已入库: ${_registeredGames.length} 个游戏');
        _log('INFO', '========================================');
        _log('INFO', '');
      }

      _emitSuccess();
    } catch (e, st) {
      // 如果是用户主动取消，不做失败处理
      if (_isCancelled) {
        _log('INFO', '用户已取消解压，跳过错误处理');
        return;
      }

      _log('ERROR', '解压过程捕获异常: $e');
      _log('ERROR', '堆栈: $st');

      if (_currentProcess != null) {
        _log('WARN', '终止残留进程...');
        _currentProcess?.kill();
        _currentProcess = null;
      }

      _log('INFO', '');
      _log('INFO', '⏳ 等待文件系统同步（1秒）...');
      await Future.delayed(const Duration(seconds: 1));

      _log('INFO', '');
      _log('INFO', '========== 最终结果校验 ==========');

      bool extractionActuallySucceeded = false;

      // 优先检查实际解压目录（_actualGameDir），这是游戏文件所在的位置
      // 之前的 bug：只检查 _targetGameDir（元数据目录），自定义路径下该目录可能为空
      final dirsToCheck = <String>[
        if (_actualGameDir != null && _actualGameDir!.isNotEmpty) _actualGameDir!,
        if (_targetGameDir != null && _targetGameDir!.isNotEmpty) _targetGameDir!,
      ];

      for (int retry = 0; retry < 3 && !extractionActuallySucceeded; retry++) {
        if (retry > 0) {
          _log('INFO', '⏳ 等待后重试校验 (${retry + 1}/3)...');
          await Future.delayed(Duration(milliseconds: 500 * retry));
        }

        for (final dirPath in dirsToCheck) {
          if (extractionActuallySucceeded) break;
          try {
            final dirCheck = Directory(dirPath);
            if (await dirCheck.exists()) {
              final entities = await dirCheck.list().toList();
              _log('INFO',
                  '   目录检查 (尝试${retry + 1}): $dirPath | 条目数=${entities.length}');

              if (entities.isNotEmpty) {
                // 递归查找是否有 .exe 文件（游戏本体的关键标志）
                // ★ P0-7：流式存在性检查（找到即中断，不物化）
                final hasExe = await FsScan.containsFile(
                  dirCheck,
                  (path) => path.endsWith('.exe'),
                );

                final gameJsonFile =
                    File('$dirPath/${GameDataFormat.gameJsonFileName}');
                final ctgameFile =
                    File('$dirPath/${GameDataFormat.ctgameFileName}');
                final hasMetadata =
                    await gameJsonFile.exists() || await ctgameFile.exists();

                if (hasExe || hasMetadata) {
                  extractionActuallySucceeded = true;
                  _log('SUCCESS', '✅ 最终校验通过: $dirPath (EXE=$hasExe, 元数据=$hasMetadata)');
                  break;
                } else if (entities.length >= 1) {
                  // 宽松校验：目录非空，可能是游戏文件在子目录中
                  extractionActuallySucceeded = true;
                  _log('SUCCESS', '✅ 宽松校验通过: $dirPath 非空(${entities.length}项)');
                  break;
                }
              } else {
                _log('WARN', '   ⚠️ 目录为空: $dirPath');
              }
            } else {
              _log('WARN', '   ⚠️ 目录不存在: $dirPath');
            }
          } catch (verifyErr) {
            _log('WARN', '   校验过程异常 ($dirPath): $verifyErr');
          }
        }
      }

      if (!extractionActuallySucceeded) {
        _log('INFO', '');
        _log('INFO', '========== 注册表交叉验证 ==========');
        try {
          final registry = LocalGameRegistry.instance;

          List<LibraryGame?> candidates = [];
          final exactMatch = registry.getGameByTitle(gameTitle);
          if (exactMatch != null) candidates.add(exactMatch);

          final allGames = registry.allGames;
          for (final game in allGames) {
            if (game.title.toLowerCase().contains(gameTitle.toLowerCase()) ||
                gameTitle.toLowerCase().contains(game.title.toLowerCase())) {
              if (!candidates.contains(game)) {
                candidates.add(game);
              }
            }

            // 同时检查 _targetGameDir 和 _actualGameDir 的路径匹配
            final checkDirs = [
              _targetGameDir,
              _actualGameDir,
            ];
            for (final checkDir in checkDirs) {
              if (checkDir == null || checkDir.isEmpty) continue;
              if (game.directoryPath
                      .toLowerCase()
                      .contains(checkDir.toLowerCase()) ||
                  checkDir
                      .toLowerCase()
                      .contains(game.directoryPath.toLowerCase())) {
                if (!candidates.contains(game)) {
                  candidates.add(game);
                }
              }
            }
          }

          for (final candidate in candidates) {
            if (candidate == null) continue;

            try {
              final regDir = Directory(candidate.directoryPath);
              if (await regDir.exists()) {
                final regEntities = await regDir.list().toList();
                if (regEntities.isNotEmpty) {
                  extractionActuallySucceeded = true;
                  _log('SUCCESS', '✅✅✅ 注册表交叉验证通过！');
                  _log('SUCCESS', '   游戏已在注册表中: ${candidate.title}');
                  _log('SUCCESS', '   目录路径: ${candidate.directoryPath}');
                  _log('SUCCESS', '   文件数量: ${regEntities.length}');
                  _log('SUCCESS', '   结论：游戏确实已成功安装');
                  break;
                }
              }
            } catch (_) {}
          }

          if (!extractionActuallySucceeded && candidates.isEmpty) {
            _log('WARN', '   注册表中未找到匹配的游戏记录');
            _log('WARN', '   搜索标题: "$gameTitle"');
            _log('WARN', '   实际目录: "$_actualGameDir"');
            _log('WARN', '   元数据目录: "$_targetGameDir"');
          } else if (!extractionActuallySucceeded) {
            _log('WARN', '   找到${candidates.length}个候选记录，但目录均无效');
          }
        } catch (regErr) {
          _log('WARN', '注册表验证异常: $regErr');
        }
      }

      if (extractionActuallySucceeded) {
        _log('SUCCESS', '');
        _log('SUCCESS', '========== 以最终结果为准：解压成功 ==========');
        _log('SUCCESS', '中间步骤虽有异常，但最终文件已正确生成');

        // ★ 同上：计划驱动路径不写元数据（避免 scan 自动入库），延后到
        //   用户点「确认入库」时由 JoinController 写入。
        if (unpackPlan != null) {
          _log('INFO', '📦 计划驱动路径：元数据延后（用户点「确认入库」时写入）');
          _emitProgress(const ExtractProgress(percent: 98, message: '准备最终结果...'));
        } else {
          _emitProgress(const ExtractProgress(percent: 98, message: '写入游戏信息...'));

          await _writeGameInfo(
            targetDir: _targetGameDir!,
            title: gameTitle,
            description: gameDescription,
            coverUrl: gameCoverUrl,
            bannerUrl: gameBannerUrl,
            tags: gameTags,
            developer: gameDeveloper,
            overrideDirectoryPath: extractionTargetDir,
            screenshotUrls: screenshotUrls,
            subtitle: gameSubtitle,
            cloudGameId: _cloudGameId,
          );

          await _embedCoverBase64(
            targetDir: _targetGameDir!,
            coverUrl: gameCoverUrl,
          );
        }

        _log('SUCCESS', '========== 解压任务完成（最终结果） ==========');
        _log('SUCCESS', '✅ 游戏本体已安装到: $extractionTargetDir');
        _log('SUCCESS', '✅ 游戏元数据已写入: $_targetGameDir');

        _emitProgress(const ExtractProgress(percent: 100, message: '解压完成'));
        _emitStatus(ExtractStatus.completed);
        if (_activeTaskCount > 0) _activeTaskCount--;

        // directoryPath 应使用游戏本体实际解压目录，而非元数据目录
        final gamePath = extractionTargetDir.isNotEmpty
            ? extractionTargetDir
            : (_targetGameDir ?? '');
        final gameId = _currentArchivePath ?? '';

        if (_registeredGames.contains(gamePath)) {
          _log('WARN', '⚠️ 游戏已入库，跳过重复注册');
        } else if (unpackPlan != null) {
          // ★ 同上：计划驱动路径暂不入库，等用户在导入表单确认
          _log('INFO', '📦 计划驱动路径：暂不入库（等待用户确认入库）');
        } else {
          _registrationCount++;
          _log('INFO', '📦 执行入库逻辑（最终结果路径）');
          LocalGameRegistry.instance.registerExtractionComplete(
            gameTitle: gameTitle,
            directoryPath: gamePath,
            developer: gameDeveloper,
            subtitle: gameSubtitle,
          );
          _registeredGames.add(gamePath);
          _log('INFO', '✅ 入库完成');
        }

        _emitSuccess();
        return;
      }

      _log('ERROR', '❌ 最终校验失败: 目标目录无效或空，判定为安装失败');
      _cleanupOnFailure(_targetGameDir!, _actualGameDir);
      _handleError(e.toString());
      _emitFailure(e.toString());
    }
  }

  List<String> _detectFormats(String filePath) {
    final fileName = filePath.split('/').last.split('\\').last.toLowerCase();
    final formats = <String>[];
    final knownExtensions = [
      '.rar.lz4',
      '.zip.lz4',
      '.7z.lz4',
      '.tar.lz4',
      '.zip.7z',
      '.rar.7z',
      '.tar.7z',
      '.tar.gz',
      '.tar.bz2',
      '.tar.xz',
      '.zip.gz',
      '.rar.gz',
      '.7z.gz',
    ];

    for (final ext in knownExtensions) {
      if (fileName.endsWith(ext)) {
        final parts = ext.split('.').where((s) => s.isNotEmpty).toList();
        if (parts.length >= 2) {
          if (parts[0] == 'tar' &&
              (parts[1] == 'gz' || parts[1] == 'bz2' || parts[1] == 'xz')) {
            formats.add('.${parts[0]}.${parts[1]}');
          } else {
            formats.add('.${parts.last}');
            formats.add('.${parts[parts.length - 2]}');
          }
          final remaining = fileName.substring(0, fileName.length - ext.length);
          return [..._detectFormatsFromName(remaining), ...formats.reversed];
        }
      }
    }

    return _detectFormatsFromName(fileName);
  }

  List<String> _detectFormatsFromName(String name) {
    final singleExts = [
      '.zip',
      '.rar',
      '.7z',
      '.lz4',
      '.tar',
      '.gz',
      '.bz2',
      '.xz',
      '.iso',
      '.cab',
      '.arj',
      '.zst',
      '.lzma',
      '.tar.bz2',
      '.tar.gz',
      '.tar.xz',
      '.tar.zst',
    ];

    for (final ext in singleExts) {
      if (name.endsWith(ext)) {
        if (ext.startsWith('.tar.')) {
          return [ext];
        }
        return [ext];
      }
    }

    final volumePatterns = [
      RegExp(r'\.part(\d+)\.rar$'),
      RegExp(r'\.r(\d{2,3})$'),
      RegExp(r'\.rar$'),
    ];

    for (final pattern in volumePatterns) {
      if (pattern.hasMatch(name)) {
        return ['.rar'];
      }
    }

    return [];
  }

  Future<String> _resolveEffectiveLocation(String? customGameLocation) async {
    if (customGameLocation != null && customGameLocation.isNotEmpty) {
      _log('INFO', '📍 使用用户手动选择的路径: $customGameLocation');
      return customGameLocation;
    }

    final userDefaultLocation =
        await InstallPathPreference.instance.getDefaultGameLocation();

    if (userDefaultLocation != null && userDefaultLocation.isNotEmpty) {
      _log('INFO', '📍 使用用户设置的默认安装路径: $userDefaultLocation');
      return userDefaultLocation;
    }

    _log('INFO', '📍 未找到有效路径，将回退到元数据目录: $_gamesBaseDir');
    return _gamesBaseDir;
  }

  bool _isWithinGamesBaseDirectory(String locationPath) {
    final normalizedLocation = Directory(locationPath).absolute.path;
    final normalizedGamesBase = Directory(_gamesBaseDir).absolute.path;

    final isSameOrSubdir = normalizedLocation == normalizedGamesBase ||
        normalizedLocation.startsWith('$normalizedGamesBase\\') ||
        normalizedLocation.startsWith('$normalizedGamesBase/');

    if (isSameOrSubdir) {
      _log('INFO', '   ✅ 路径关联检测: "$locationPath" 在 Games 基础目录范围内');
    } else {
      _log('INFO', '   ❌ 路径关联检测: "$locationPath" 是独立的外部路径');
    }

    return isSameOrSubdir;
  }

  Future<String> _determineExtractionTarget({
    required String effectiveLocation,
    required String gameTitle,
  }) async {
    if (_isWithinGamesBaseDirectory(effectiveLocation)) {
      // 使用 path.join 统一路径分隔符
      final targetDir = path.join(_targetGameDir!, _safeDirectoryName(gameTitle));
      _log('INFO', '🎯 解压方案(本体在元数据子目录): $targetDir');
      return targetDir;
    } else {
      final targetDir = await _resolveCustomGameDir(
        customBaseDir: effectiveLocation,
        gameTitle: gameTitle,
      );
      _log('INFO', '🎯 解压方案(本体在外部路径): $targetDir');
      return targetDir;
    }
  }

  String _safeDirectoryName(String title) {
    var dirName = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    return dirName.isEmpty ? 'UnknownGame' : dirName;
  }

  Future<String> _resolveGameDir(String title) async {
    final baseDir = Directory(_gamesBaseDir);
    if (!await baseDir.exists()) {
      await baseDir.create(recursive: true);
    }

    var dirName = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (dirName.isEmpty) dirName = 'UnknownGame';

    // 使用 path.join 统一路径分隔符，避免混合 / 和 \
    var candidate = path.join(_gamesBaseDir, dirName);
    int idx = 1;
    while (await Directory(candidate).exists()) {
      candidate = path.join(_gamesBaseDir, '${dirName}_$idx');
      idx++;
    }
    return candidate;
  }

  Future<String> _resolveCustomGameDir({
    required String customBaseDir,
    required String gameTitle,
  }) async {
    final baseDir = Directory(customBaseDir);
    if (!await baseDir.exists()) {
      try {
        await baseDir.create(recursive: true);
        _log('INFO', '自动创建自定义基础目录: $customBaseDir');
      } catch (e) {
        _log('ERROR', '无法创建自定义基础目录: $customBaseDir ($e)');
        rethrow;
      }
    }

    var safeName = gameTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (safeName.isEmpty) safeName = 'UnknownGame';

    // 使用 path.join 统一路径分隔符
    var candidate = path.join(customBaseDir, safeName);
    int idx = 1;
    while (await Directory(candidate).exists()) {
      candidate = path.join(customBaseDir, '${safeName}_$idx');
      idx++;
    }

    return candidate;
  }

  /// 单格式解压（支持密码候选队列）。
  ///
  /// ★ 2026-10-04 智能解压 Phase 3：新增 [passwordCandidates] 队列。
  /// - 传 null（老路径）：[null, _defaultPassword]，与原「无密码→默认密码
  ///   重试」行为完全一致；
  /// - 传队列（plan 路径）：逐个尝试，首个成功即用——覆盖用户按层预设 /
  ///   记忆库 / 内置密码表的轮换回退（方案 §4.4）。
  /// - 顺带修复存量 bug：原实现 .zip/.7z 分支未把 password 形参传给
  ///   解压函数（仅 .rar 传了），导致显式密码对 zip/7z 从不生效。
  /// 计划驱动解压主循环（方案 §4.1/§4.5）。
  ///
  /// 与老路径（文件名链预知层数）的区别：层级**动态发现**——每层解压到
  /// `_temp_layer_N` 临时层，重扫产物；发现嵌套压缩包 → 续链下一层；
  /// 无 → 将临时层内容搬入最终目录收尾。混合产物（散文件+嵌套包）时
  /// 散文件先搬走、嵌套包继续解（方案 §4.3）。
  ///
  /// 密码：每层候选队列 = [无密码, 用户按层预设, 记忆库(仅第0层),
  /// 内置密码表]（方案 §4.4；Phase 0 T6-T8 实测错密码明确报
  /// Wrong password，队列轮换判定可靠）。
  ///
  /// ✅ Phase 3.5（2026-10-04）：`waiting_for_input` 已落地——队列全败且
  ///   UI 注入了 [onPasswordNeeded] 时暂停补输（弹窗由页面层提供），拿到
  ///   新密码清空本层垃圾后重试；未注入时维持既有失败路径。
  Future<void> _executePlanExtract({
    required UnpackPlan plan,
    required String archivePath,
    required String extractionTargetDir,
  }) async {
    const int maxDepth = 6; // 方案 §4.8：社区实测最深 4 层，6 为安全余量
    var currentPath = archivePath;
    var currentFormat = plan.layers.isNotEmpty
        ? plan.layers.first.realFormat
        : (ArchiveInspector.sniffSync(archivePath).format ?? 'zip');
    var estimatedLayers = plan.layers.length.clamp(1, maxDepth);
    final usedTempDirs = <String>[];
    final isFromLz4Tracker = <bool>[];
    // ★ waiting_for_input：补输成功的密码 → 该层格式（全部层完成后写记忆库）
    final acceptedManual = <String, String>{};
    // ★ Phase B：同任务决策记忆——后缀 → 已确认格式（同后缀不再打断）
    final taskFormatByExt = <String, String>{};
    // ★ Phase B：自动尝试已穷尽的后缀（本任务内不再提供自动尝试选项）
    final chainExhaustedExts = <String>{};
    // ★ Phase B/E：尾部已实证判定的「下一层格式」标记——探针层猜测
    // （plan.layers.realFormat，按后缀兜底猜的）不得覆盖实证结果
    // （魔数/自动尝试/用户指定）。仅第 0 层（无前置尾部）走探针预设。
    var nextLayerFormatLocked = false;

    for (var layerIdx = 0; layerIdx < maxDepth; layerIdx++) {
      if (_isCancelled) {
        _log('INFO', '计划解压被用户取消（第${layerIdx + 1}层前）');
        throw Exception('解压已取消');
      }

      final outputDir = '$extractionTargetDir._temp_layer_$layerIdx';
      usedTempDirs.add(outputDir);
      if (!await Directory(outputDir).exists()) {
        await Directory(outputDir).create(recursive: true);
      }

      // ---- 本层格式：plan 预设优先，魔数兜底 ----
      // ★ Phase B/E：上层尾部已实证判定本层格式时不覆盖（探针猜测让位）
      final planned = _planLayerOf(plan, layerIdx);
      if (planned != null && !nextLayerFormatLocked) {
        currentFormat = planned.realFormat;
      }
      nextLayerFormatLocked = false;
      final fmt = '.$currentFormat';
      _log('INFO', '--- 计划层${layerIdx + 1}: $fmt ---');
      _op('▶ 开始解压第 ${layerIdx + 1} 层（格式 $fmt）');

      // ---- 密码候选队列（2026-10-05 需求：去层级化 + 记忆策略）----
      // 密码不再按层设置。顺序：① 用户本次输入的密码组（plan.passwordSequence
      // 已改为扁平组语义）→ ② 预设密码组（手动保存，整组按序）→
      // ③ 历史密码组（自动记录，整组按序，保留组内关联性）→
      // ④ 本包记忆 + 包内密码提取（首层）→ ⑤ 密码库保底（汇总去重，
      // 含内置表）。seen 去重保序在下方统一处理。
      final candidates = <String?>[null];
      for (final pw in plan.passwordSequence) {
        if (pw.isNotEmpty) candidates.add(pw);
      }
      if (plan.passwordSequence.any((p) => p.isNotEmpty)) {
        _log('INFO',
            '已加入用户本次输入的密码组（${plan.passwordSequence.where((p) => p.isNotEmpty).length} 个，内容不落日志）');
      }
      final pwGroups = UnpackStore.instance.passwordGroups;
      for (final g in pwGroups.where((g) => !g.auto)) {
        candidates.addAll(g.passwords);
      }
      for (final g in pwGroups.where((g) => g.auto)) {
        candidates.addAll(g.passwords);
      }
      if (layerIdx == 0) {
        final remembered =
            UnpackStore.instance.recallPassword(archivePath, currentFormat);
        if (remembered != null) candidates.add(remembered);
        // ★ Phase F（scenarios_v2 §3 #2）：包内密码自动提取——rar 注释 +
        // 同目录密码.txt，命中候选加入队列（优先于内置表；无命中静默）。
        candidates.addAll(await _harvestPasswords(archivePath));
      }
      candidates.addAll(UnpackStore.instance.passwordLibrary);
      // 操作日志：候选队列构成（密码内容不落日志/不进面板）
      _op('密码候选队列已组装：本次输入'
          ' ${plan.passwordSequence.where((p) => p.isNotEmpty).length} 个'
          ' + 预设组 ${pwGroups.where((g) => !g.auto).length} 组'
          ' + 历史组 ${pwGroups.where((g) => g.auto).length} 组'
          ' + 密码库保底');
      final seen = <String?>{};

      final est = estimatedLayers = estimatedLayers > layerIdx + 1
          ? estimatedLayers
          : layerIdx + 2; // 动态续层时预估层数 +1
      final layerStart = (layerIdx / est) * 100;
      final layerEnd = ((layerIdx + 1) / est) * 100;

      _emitProgress(ExtractProgress(
        percent: layerStart.clamp(0, 100),
        message: '正在解压第${layerIdx + 1}层($fmt)...',
      ));

      final isFromLz4 = isFromLz4Tracker.isNotEmpty && isFromLz4Tracker.last;
      // 🔴 闭包快照（MEMORY §4 教训）：闭包捕获变量引用而非值——
      //   currentPath/currentFormat 在循环内会被重新赋值，弹窗回调读取的
      //   必须是本层调用时刻的值，先快照。
      final layerInput = currentPath;
      final layerFormat = currentFormat;

      // ---- ★ S.S.E. File Encryptor (.enc) 层：Dart 原生解密（Phase 4）----
      // 7z 不识别 .enc 容器；解密产物 zip 落临时层后直接续链下一层
      // （解密 zip 与普通嵌套包同权，密码候选队列/补输逻辑同构）。
      if (currentFormat == 'enc') {
        final outZip = await _decryptEncLayer(
          encPath: layerInput,
          outputDir: outputDir,
          startPercent: layerStart,
          endPercent: layerEnd,
          layerIndex: layerIdx,
          passwordCandidates:
              candidates.where((pw) => seen.add(pw)).toList(),
          onManualPassword:
              onExtractDecision == null && onPasswordNeeded == null
                  ? null
                  : (triedCount) async {
                      return _promptForPassword(
                        archiveFile: layerInput,
                        format: layerFormat,
                        layerIndex: layerIdx,
                        triedCount: triedCount,
                      );
                    },
        );
        _taskOwnedTempArchives.add(outZip); // 登记自建中间包（IMP-06）
        currentPath = outZip;
        currentFormat = 'zip'; // 解密产物恒为 zip 容器
        isFromLz4Tracker.add(false);
        nextLayerFormatLocked = true; // ★ 实证格式（解密产物），探针不得覆盖
        continue; // 下一层解压 zip（层上限内自然受控）
      }

      // ★ Phase F（§1.5）：corrupt 决策窗——解压失败分类报因（缺卷/CRC/
      // 不支持/通用），「继续重试」（如补齐缺卷后）/「取消解压」。密码相关
      // 错误由 waiting_for_input 通道处理过，corrupt 不重复介入。
      // ⚠️ 密码队列去重必须在重试循环外完成：seen 是复用集合，重试时再跑
      // 同一表达式会因元素已存在而返回空表（Phase B 同款坑）。
      final layerPwQueue = candidates.where((pw) => seen.add(pw)).toList();
      while (true) {
        try {
          currentPath = await _extractSingleFormat(
            layerInput,
            fmt,
            outputDir,
            startPercent: layerStart,
            endPercent: layerEnd,
            isFromLz4: isFromLz4,
            passwordCandidates: layerPwQueue,
            onCandidatesExhausted:
                onExtractDecision == null && onPasswordNeeded == null
                    ? null
                    : (triedCount) async {
                        return _promptForPassword(
                          archiveFile: layerInput,
                          format: layerFormat,
                          layerIndex: layerIdx,
                          triedCount: triedCount,
                        );
                      },
            onManualPasswordAccepted: (pw) =>
                acceptedManual[pw] = layerFormat,
          );
          break;
        } on Exception catch (e) {
          if ('${'$e'}'.contains('解压已取消')) rethrow;
          final msg = _corruptMessage(e);
          if (msg == null) rethrow; // 密码通道已弹过补输窗，直接失败
          _log('ERROR', '❌ 第${layerIdx + 1}层解压失败: $msg');
          final decision = await _requestDecision(ExtractDecisionRequest(
            kind: 'corrupt',
            message: '第${layerIdx + 1}层解压失败：$msg\n'
                '若已补齐/修复源包，可选择重试。',
            archiveFile: layerInput,
            format: layerFormat,
            layerIndex: layerIdx,
          ));
          if (decision == null || !decision.proceed) {
            _log('INFO', '用户在损坏弹窗选择取消解压');
            throw Exception('解压已取消'); // 走既有失败清理（与取消路径同构）
          }
          _log('INFO', '🔁 用户选择重试第${layerIdx + 1}层');
          await _clearDirectory(outputDir);
        }
      }
      isFromLz4Tracker.add(currentFormat == 'lz4');

      // ---- 产物重扫：找嵌套压缩包候选（方案 §4.5 动态计划 / §1.2 Phase A）----
      // ⚠️ 变量名不可叫 candidates——与本层密码候选队列（上方 List<String?>）
      // 同名冲突，此处用 nestedCandidates。
      // ★ Phase B §1.4：伪装链上下文——本层输入本身是「伪装/映射」档案
      //（plan 声明层标记 disguised）时，产物中的未知后缀文件可能是链条
      // 下一环 → 允许按自动尝试候选链纳入扫描；普通层不纳入（防真实
      // 游戏目录里的视频/图片等资源被误当候选）。
      final chainMode = planned != null && planned.disguised;
      var nestedCandidates = await _scanForCandidates(
        outputDir,
        includeChainExts: chainMode,
      );
      // ★ 2026-10-05 实机反馈（情景三）：常规候选为空时，复查顶层散文件
      //   中的伪装压缩容器（.mov 实为 enc 等）——有则作为嵌套候选续层，
      //   防止本体判定把「诱饵 + 待解资源」误收为游戏本体提前收尾。
      if (nestedCandidates.isEmpty) {
        nestedCandidates = await _sniffDisguisedFiles(outputDir);
      }
      if (nestedCandidates.isEmpty) {
        // ★ Phase E（§1.3）：本体识别——解压结果无嵌套压缩包时，先判断
        //   是否已到达游戏本体（防「解出来还是一层壳」误报完成）。
        final body = await _resolveGameBody(
          outputDir: outputDir,
          plan: plan,
          archivePath: archivePath,
          passwordQueue: candidates,
          acceptedManual: acceptedManual,
          taskFormatByExt: taskFormatByExt,
          chainExhaustedExts: chainExhaustedExts,
          layerIdx: layerIdx,
          currentFormat: currentFormat,
          startPercent: layerStart,
          endPercent: layerEnd,
          scratchDir: '$extractionTargetDir._temp_try_$layerIdx',
        );
        if (body.resolution == _BodyResolution.continueAsArchive) {
          _log('INFO',
              '🧩 本体实为自解压/伪装层，继续下一层: ${body.path!.split('/').last.split('\\').last}');
          _taskOwnedTempArchives.add(body.path!); // ★ IMP-06：登记自建中间包
          currentPath = body.path!;
          currentFormat = body.format!;
          isFromLz4Tracker.add(false);
          nextLayerFormatLocked = true; // 实证格式（SFX/决策确定），探针不得覆盖
          continue;
        }
        if (body.resolution == _BodyResolution.cancelled) {
          _log('INFO', '用户在「未找到本体」弹窗取消解压');
          throw Exception('解压已取消'); // 走既有失败清理（与取消路径同构）
        }
        // ---- 完成：临时层内容搬入最终目录 ----
        _log('INFO', '✅ 第${layerIdx + 1}层无嵌套压缩包，计划解压完成');
        _op('✅ 各层解压完成，正在整理产物…');
        // ★ waiting_for_input 补输成功的密码写入记忆库（方案 §4.4：手动
        //   兜底输入过的密码存 LRU；key = 源包路径 + 该层格式）。
        //   放在全部层成功之后：失败不记忆，避免污染记忆库。
        for (final entry in acceptedManual.entries) {
          UnpackStore.instance
              .rememberPassword(archivePath, entry.value, entry.key);
        }
        // ★ 去层级化（2026-10-05）：补输成功 = 用户本次输入的密码组有效，
        //   整组记入历史密码组（签名去重 + LRU，保留组内关联性），
        //   下次同类资源自动按组轮换。失败不记录，避免污染。
        UnpackStore.instance.recordPasswordGroupHistory(
            plan.passwordSequence.where((p) => p.isNotEmpty).toList());
        await _moveDirContents(outputDir, extractionTargetDir);
        for (final dir in usedTempDirs) {
          final d = Directory(dir);
          if (await d.exists()) {
            await d.delete(recursive: true);
            _log('INFO', '已清理计划临时层: $dir');
          }
        }
        return;
      }

      // ★ Phase D §1.2：多候选（≥2）→ 挂起「目标文件选择框」（交互对齐
      //   密码弹窗，可恢复）；推荐引擎给出建议本体（不推荐 = 用户自选）。
      //   其余候选视为诱饵——留在本层临时目录，收尾/取消时随层清理删除
      //   （临时层机制天然覆盖，无需额外清理逻辑）。
      ExtractCandidate chosen = nestedCandidates.first;
      if (nestedCandidates.length > 1) {
        final rec = UnpackStore.instance
                .isAmbiguityRuleEnabled(UnpackStore.majorityOutlierRuleId)
            ? _recommendCandidate(nestedCandidates)
            : null;
        if (rec != null) {
          _log('INFO',
              '💡 歧义推荐: ${rec.candidate.path.split('/').last.split('\\').last}（${rec.reason}）');
        }
        final decision = await _requestDecision(ExtractDecisionRequest(
          kind: 'ambiguity',
          message:
              '发现 ${nestedCandidates.length} 个嵌套候选，请指定游戏本体；其余视为诱饵，随临时层自动清理',
          archiveFile: nestedCandidates.first.path,
          format: currentFormat,
          layerIndex: layerIdx,
          candidates: nestedCandidates,
          recommendPath: rec?.candidate.path,
        ));
        if (decision == null ||
            !decision.proceed ||
            (decision.chosenPath ?? '').isEmpty) {
          _log('INFO', '用户在歧义选择框取消解压');
          throw Exception('解压已取消'); // 走既有失败清理（与取消路径同构）
        }
        chosen = nestedCandidates.firstWhere(
          (c) => c.path == decision.chosenPath,
          orElse: () => nestedCandidates.first,
        );
      }
      final nested = chosen;
      _log('INFO',
          '🔍 发现嵌套压缩包: ${nested.path.split('/').last.split('\\').last}');
      _op('🔍 发现嵌套压缩包：'
          '${nested.path.split('/').last.split('\\').last}，继续下一层');
      _taskOwnedTempArchives.add(nested.path); // ★ IMP-06：登记自建中间包
      currentPath = nested.path;

      // ---- 下一层格式判定链（Phase A/B §1.4）：魔数 → 文件名 → 决策链 ----
      if (nested.magicFormat != null) {
        currentFormat = nested.magicFormat!;
      } else if (nested.nameFormat != null) {
        currentFormat = nested.nameFormat!;
      } else {
        // ★ waiting_for_strategy（双未命中 = 链候选，Phase B §1.4）：
        // 同任务记忆 → 持久化映射表 → 决策窗（手动/自动尝试/终止）。
        // ★ Phase E：判定链抽为 [_resolveUnknownFormat]（孤 exe 场景复用）。
        currentFormat = await _resolveUnknownFormat(
          plan: plan,
          candidate: nested,
          ext: (nested.declaredExt ?? '').toLowerCase(),
          candidates: nestedCandidates,
          layerIdx: layerIdx,
          fallbackFormat: currentFormat,
          passwordQueue: candidates,
          acceptedManual: acceptedManual,
          applyMemory: true,
          taskFormatByExt: taskFormatByExt,
          chainExhaustedExts: chainExhaustedExts,
          startPercent: layerStart,
          endPercent: layerEnd,
          scratchDir: '$extractionTargetDir._temp_try_$layerIdx',
          archivePath: archivePath,
        );
      }
      // ★ Phase E：本层尾部已实证/决策确定「下一层格式」——下一轮循环顶
      // 的探针层猜测（plan.realFormat）不得覆盖（魔数/自动尝试/用户指定）。
      nextLayerFormatLocked = true;
    }
    throw Exception('嵌套压缩层数超过上限($maxDepth 层)，已中止以防异常包');
  }

  /// plan 中 layerIndex 对应的层（可能为 null：执行期新发现的层）
  ArchiveLayer? _planLayerOf(UnpackPlan plan, int layerIdx) {
    for (final l in plan.layers) {
      if (l.layerIndex == layerIdx) return l;
    }
    return null;
  }

  /// ★ Phase A（§1.4）：统一决策请求。注入 [onExtractDecision] 时经它走
  /// UI 弹窗；未注入且 kind == password 时回落 [onPasswordNeeded]（老路径
  /// 兼容）；其余 kind 未注入 → null（维持既有行为，不额外打断）。
  Future<ExtractDecisionResult?> _requestDecision(
      ExtractDecisionRequest request) async {
    final hook = onExtractDecision;
    if (hook != null) return hook(request);
    if (request.kind == 'password') {
      final pw = await onPasswordNeeded?.call(
        archiveFile: request.archiveFile,
        format: request.format,
        layerIndex: request.layerIndex,
        triedCount: request.triedCount,
      );
      if (pw == null) return null;
      return ExtractDecisionResult(password: pw);
    }
    return null;
  }

  /// ★ Phase A：waiting_for_input 补输的统一入口（enc 层与通用层共用，
  /// 收敛原两处重复闭包）。返回 null = 用户放弃/已取消。
  Future<String?> _promptForPassword({
    required String archiveFile,
    required String format,
    required int layerIndex,
    required int triedCount,
  }) async {
    if (_isCancelled) return null;
    final r = await _requestDecision(ExtractDecisionRequest(
      kind: 'password',
      message: '第${layerIndex + 1}层($format)密码候选全部失效（已试 $triedCount 个），请补输密码',
      archiveFile: archiveFile,
      format: format,
      layerIndex: layerIndex,
      triedCount: triedCount,
    ));
    return r?.password;
  }

  /// ★ Phase E：未知格式判定链（原层循环尾部内联①②③④抽出，供「孤 exe
  /// 本体识别」复用）——①同任务决策记忆 → ②持久化映射表 → ③决策窗
  /// （手动指定 / 自动尝试候选链 / 终止）→ ④决策记忆回写。
  ///
  /// [applyMemory] = false 时跳过决策记忆的读与写（.exe 本体场景——真实
  /// 游戏主程序几乎都是 .exe，回写映射表会误伤后续导入的同后缀文件）。
  /// [forceChain] = 显式候选链（孤 exe 场景去掉 '7z'——SFX 试解已试过）；
  /// null = 按后缀查 [UnpackStore.autoTryChainFor]。
  /// [ext] 已含点（'.exe'），与 declaredExt 全链路约定一致。
  Future<String> _resolveUnknownFormat({
    required UnpackPlan plan,
    required ExtractCandidate candidate,
    required String ext,
    required List<ExtractCandidate> candidates,
    required int layerIdx,
    required String fallbackFormat,
    required List<String?> passwordQueue,
    required Map<String, String> acceptedManual,
    required bool applyMemory,
    required Map<String, String> taskFormatByExt,
    required Set<String> chainExhaustedExts,
    required double startPercent,
    required double endPercent,
    required String scratchDir,
    required String archivePath,
    List<String>? forceChain,
  }) async {
    // ① 同任务决策记忆：同后缀本任务已确认过格式 → 直接复用不打断
    if (applyMemory && taskFormatByExt[ext] != null) {
      final remembered = taskFormatByExt[ext]!;
      _log('INFO', '↩️ 同任务决策记忆: $ext → $remembered（不再次打断）');
      return remembered;
    }
    // ② 持久化映射表命中（历史手动指定/自动尝试的回写）→ 免打断
    if (applyMemory && ext.isNotEmpty) {
      final mapping = UnpackStore.instance.lookupMapping(ext);
      if (mapping != null && mapping.toFormat.isNotEmpty) {
        _log('INFO',
            '↩️ 映射表命中: $ext → ${mapping.toFormat}（历史决策记忆）');
        return mapping.toFormat;
      }
    }
    // ③ 决策窗：手动指定 / 自动尝试（候选链）/ 终止
    final seenPw = <String?>{};
    final pwQueue = passwordQueue.where((pw) => seenPw.add(pw)).toList();
    final chain = (forceChain ??
            (ext.isEmpty
                ? const <String>[]
                : UnpackStore.instance.autoTryChainFor(ext)))
        .where((f) =>
            f != 'enc' ||
            _encTryAllowed(plan, layerIdx + 1, acceptedManual, archivePath))
        .toList();
    final canAutoTry = chain.isNotEmpty && !chainExhaustedExts.contains(ext);
    final decision = await _requestDecision(ExtractDecisionRequest(
      kind: 'strategy',
      message: canAutoTry
          ? '无法识别嵌套文件的格式（$ext），可自动尝试 ${chain.length} 种候选格式'
          : '无法识别嵌套文件的格式: ${candidate.path.split('/').last.split('\\').last}',
      archiveFile: candidate.path,
      format: fallbackFormat,
      layerIndex: layerIdx,
      candidates: candidates,
      tryFormats: canAutoTry ? chain : const [],
    ));
    if (decision == null || !decision.proceed) {
      _log('INFO', '用户在格式决策窗选择终止（或放弃）');
      throw Exception('解压已取消'); // 走既有失败清理（与取消路径同构）
    }
    String resolved;
    if (decision.autoTry && decision.format == null) {
      // ★ Phase B：自动尝试候选链（每候选失败清层；耗尽回落决策窗）
      resolved = await _autoTryFormats(
        candidate: candidate,
        ext: ext,
        chain: chain,
        scratchDir: scratchDir,
        passwordQueue: pwQueue,
        passwordLayerIndex: layerIdx + 1,
        acceptedManual: acceptedManual,
        startPercent: startPercent,
        endPercent: endPercent,
        onChainExhausted: chainExhaustedExts.add,
      );
    } else {
      final picked = decision.format;
      if (picked == null || picked.isEmpty) {
        throw Exception('解压已取消');
      }
      resolved = picked;
    }
    // ④ 决策记忆回写：同任务复用 + 持久化映射表（下次同类后缀免打断）
    if (applyMemory && ext.isNotEmpty) {
      taskFormatByExt[ext] = resolved;
      _rememberDecisionMapping(ext, resolved);
    }
    return resolved;
  }

  /// ★ Phase F（scenarios_v2 §3 #2）：包内密码自动提取——
  /// ① rar 注释（`7z l -slt` 的 Comment 字段，社区高频藏密码处）；
  /// ② 源包同目录「密码.txt / 说明.txt」等文本抽「密码/Password」行。
  /// 提取结果加入第 0 层候选队列（优先于内置表）。纯增强项：任何
  /// 异常/无命中都静默返回空表，绝不阻断解压流程。
  Future<List<String>> _harvestPasswords(String archivePath) async {
    final out = <String>{};
    // 行内密码抽取：密码:xxx / 密码：xxx / Password: xxx（值取到行尾）
    final pwLine = RegExp(r'(?:密码|password)\s*[:：=]\s*(.+)',
        caseSensitive: false);
    String? validPw(String? raw) {
      if (raw == null) return null;
      var v = raw.trim();
      // 去常见包裹符
      if (v.length >= 2 &&
          ((v.startsWith('"') && v.endsWith('"')) ||
              (v.startsWith('「') && v.endsWith('」')))) {
        v = v.substring(1, v.length - 1).trim();
      }
      if (v.isEmpty || v.length > 64) return null;
      return v;
    }

    // ② 同目录说明文本（只认常见文件名，不泛扫——控制成本）
    try {
      final dir = File(archivePath).parent;
      for (final n in const [
        '密码.txt',
        '说明.txt',
        '使用说明.txt',
        '解压密码.txt',
        'password.txt',
        'pass.txt',
      ]) {
        final f = File('${dir.path}\\$n');
        if (!await f.exists()) continue;
        final bytes = await f.readAsBytes();
        final text = utf8.decode(bytes, allowMalformed: true);
        for (final line in text.split(RegExp(r'[\r\n]+'))) {
          final m = pwLine.firstMatch(line);
          final pw = validPw(m?.group(1));
          if (pw != null) out.add(pw);
        }
      }
    } catch (e) {
      _log('WARN', '同目录密码文本提取失败（忽略）: $e');
    }
    // ① rar 注释（7z l -slt 输出 `Comment = ...`）
    try {
      final r = await Process.run(
        await _getBundled7zPath(),
        ['l', '-slt', '-p', '-sccUTF-8', archivePath],
      );
      if (r.exitCode == 0) {
        final text = r.stdout.toString();
        for (final line in text.split(RegExp(r'[\r\n]+'))) {
          if (!line.startsWith('Comment')) continue;
          final eq = line.indexOf('=');
          if (eq < 0) continue;
          final comment = line.substring(eq + 1).trim();
          if (comment.isEmpty) continue;
          final m = pwLine.firstMatch(comment);
          final pw = validPw(m?.group(1)) ??
              // 无关键词但整体像密码（短且无空白）→ 直接入候选（无害）
              (comment.length <= 32 && !comment.contains(RegExp(r'\s'))
                  ? comment
                  : null);
          if (pw != null) out.add(pw);
        }
      }
    } catch (e) {
      _log('WARN', 'rar 注释密码提取失败（忽略）: $e');
    }
    if (out.isNotEmpty) {
      _log('INFO', '🔑 包内密码提取命中 ${out.length} 个候选（不落日志）');
    }
    return out.toList();
  }

  /// ★ Phase F（§1.5）：解压错误分类 → 用户文案。
  /// 返回 null = 密码相关错误（补输弹窗通道已处理过，corrupt 不重复
  /// 打断，直接走既有失败路径）。分类序：密码排除 → 不支持 → 缺卷 →
  /// CRC/损坏 → 通用兜底（宁可兜底也不漏报）。
  String? _corruptMessage(Object error) {
    final t = error.toString().toLowerCase();
    if (t.contains('密码候选均无效') ||
        t.contains('wrong password') ||
        t.contains('password') ||
        t.contains('encrypted') ||
        // ★ 2026-10-05 实机反馈：RAR5 加密文件名容器无密码时的报错形态
        //   （见 _unpackCore 分类器注释）——按密码通道处理，不误报损坏。
        t.contains('cannot open the file as')) {
      return null;
    }
    if (t.contains('不支持的压缩格式') ||
        t.contains('unsupported') ||
        t.contains('not supported') ||
        t.contains('unknown algorithm') ||
        t.contains('method unsupported')) {
      return '暂不支持该压缩格式或算法，无法解压';
    }
    if (t.contains('missing volume') ||
        t.contains('分卷') ||
        t.contains('.7z.') && t.contains('cannot') ||
        t.contains('.part') && t.contains('cannot') ||
        t.contains('volume') && t.contains('cannot')) {
      return '分卷压缩包不完整（缺失分卷），请补齐后重试';
    }
    if (t.contains('crc') ||
        t.contains('checksum') ||
        t.contains('data error') ||
        t.contains('unexpected end') ||
        t.contains('headers error') ||
        t.contains('corrupt') ||
        t.contains('解压后目录为空')) {
      return '压缩包数据损坏（CRC 校验失败或数据不完整），建议重新下载源包';
    }
    return '解压失败：压缩包可能已损坏或存在其他问题';
  }

  /// ★ Phase E（§1.3）：`7z t` 试解判断 exe 是否 SFX 自解压包。
  /// 7z 能读懂该 exe（exitCode==0）→ 视为压缩层；读不懂 → 普通程序。
  /// 只测不解（t = test），不动产物。
  Future<bool> _probeSfx(String exePath) async {
    try {
      final result = await Process.run(
        await _getBundled7zPath(),
        ['t', '-sccUTF-8', '-p', exePath],
      );
      return result.exitCode == 0;
    } catch (e) {
      _log('WARN', 'SFX 试解失败（按非 SFX 处理）: $e');
      return false;
    }
  }

  /// ★ Phase E（§1.3）：游戏本体识别——计划层解完且无嵌套压缩包候选时，
  /// 判断解压结果是否已到达游戏本体（防「解出来还是一层壳」误报完成）。
  ///
  /// 判定序（轻量，不递归）：
  /// ① 顶层扫描：子目录数 / 非说明散文件数（说明文件按 [BodyRules.readmeExts]
  ///   排除）达标 → 本体命中（finished）；
  /// ② 孤 exe：先全体静默 `7z t` 试解（SFX 命中 → continueAsArchive/7z），
  ///   全败再对第一个 exe 走格式决策窗（applyMemory=false 防误伤真实主程序；
  ///   forceChain 去掉 '7z'——SFX 试解已试过）；
  /// ③ 无 exe 或全败 → 「未找到本体」弹窗（proceed=true = 仍以此收尾）。
  Future<({_BodyResolution resolution, String? path, String? format})>
      _resolveGameBody({
    required String outputDir,
    required UnpackPlan plan,
    required String archivePath,
    required List<String?> passwordQueue,
    required Map<String, String> acceptedManual,
    required Map<String, String> taskFormatByExt,
    required Set<String> chainExhaustedExts,
    required int layerIdx,
    required String currentFormat,
    required double startPercent,
    required double endPercent,
    required String scratchDir,
  }) async {
    final rules = UnpackStore.instance.bodyRules;
    final exes = <String>[];
    var subdirs = 0;
    var looseFiles = 0;
    try {
      await for (final entity in Directory(outputDir).list(followLinks: false)) {
        if (entity is Directory) {
          subdirs++;
        } else if (entity is File) {
          final lower = entity.path.toLowerCase();
          if (lower.endsWith('.exe')) {
            exes.add(entity.path);
          } else if (!rules.readmeExts.any((e) => lower.endsWith(e))) {
            looseFiles++;
          }
        }
      }
    } catch (e) {
      _log('WARN', '本体识别顶层扫描失败（按无本体处理）: $e');
    }
    _log('INFO',
        '🧭 本体识别: 子目录=$subdirs 非说明散文件=$looseFiles exe=${exes.length}');
    // ① 本体命中：目录结构像游戏本体（子目录/散文件达标）
    if (subdirs >= rules.minSubdirs || looseFiles >= rules.minLooseFiles) {
      return const (
        resolution: _BodyResolution.finished,
        path: null,
        format: null,
      );
    }
    // ② 孤 exe：第一轮全体静默 SFX 试解（多 exe 不反复打断）
    for (final exe in exes) {
      if (await _probeSfx(exe)) {
        _log('INFO', '🧩 SFX 试解命中，作为压缩层继续: $exe');
        return (
          resolution: _BodyResolution.continueAsArchive,
          path: exe,
          format: '7z',
        );
      }
    }
    // 第二轮：第一个 exe 走格式决策窗（手动指定；.exe 不读不写决策记忆）
    if (exes.isNotEmpty) {
      final exe = exes.first;
      try {
        final fmt = await _resolveUnknownFormat(
          plan: plan,
          candidate: ExtractCandidate(
            path: exe,
            declaredExt: '.exe',
            sizeBytes: 0,
          ),
          ext: '.exe',
          candidates: const [],
          layerIdx: layerIdx,
          fallbackFormat: currentFormat,
          passwordQueue: passwordQueue,
          acceptedManual: acceptedManual,
          applyMemory: false,
          taskFormatByExt: taskFormatByExt,
          chainExhaustedExts: chainExhaustedExts,
          startPercent: startPercent,
          endPercent: endPercent,
          scratchDir: scratchDir,
          archivePath: archivePath,
          forceChain: UnpackStore.instance
              .autoTryChainFor('.exe')
              .where((f) => f != '7z')
              .toList(),
        );
        return (
          resolution: _BodyResolution.continueAsArchive,
          path: exe,
          format: fmt,
        );
      } on Exception catch (e) {
        if ('$e'.contains('解压已取消')) rethrow;
        // 其余异常（试解现场问题）→ 落到「未找到本体」弹窗
      }
    }
    // ③ 无 exe 或全败 → 「未找到本体」弹窗：仍以此收尾 / 取消解压
    final decision = await _requestDecision(ExtractDecisionRequest(
      kind: 'body',
      message: '解压完成但未找到游戏本体（无目录结构，也无可用压缩层），请确认处理方式',
      archiveFile: archivePath,
      format: currentFormat,
      layerIndex: layerIdx,
    ));
    if (decision != null && decision.proceed) {
      return const (
        resolution: _BodyResolution.finished,
        path: null,
        format: null,
      );
    }
    return const (
      resolution: _BodyResolution.cancelled,
      path: null,
      format: null,
    );
  }

  /// ★ Phase B（§1.4）：enc 纳入自动尝试的前提——本任务存在可用的密码源。
  /// 无密码源的 enc 试解 100% 失败且白耗 ~2s KDF（Argon2id），直接跳过。
  /// ★ 去层级化（2026-10-05）：plan.passwordSequence 已是扁平密码组，
  ///   任意非空项均可作为 enc 密码源；预设/历史密码组同理。
  bool _encTryAllowed(UnpackPlan plan, int nextLayerIdx,
      Map<String, String> acceptedManual, String archivePath) {
    if (plan.passwordSequence.any((p) => p.isNotEmpty)) return true;
    if (acceptedManual.values.any((p) => p.isNotEmpty)) return true;
    if (UnpackStore.instance.passwordGroups.isNotEmpty) return true;
    return UnpackStore.instance.recallPassword(archivePath, 'enc') != null;
  }

  /// ★ Phase B（§1.4）：自动尝试候选链——依次用链中格式把 [candidate]
  /// 试解到 [scratchDir]（每次尝试前清空 scratch，防错格式落垃圾——
  /// Phase 0 T3 实测教训）。命中即返回该格式；正式解压由主循环按确认
  /// 格式重做（scratch 仅作试解探针，双写成本换核心循环零改动——
  /// 稳定性优先）。链耗尽 → 标记 [onChainExhausted] 后回落格式决策窗
  /// （手动指定/终止）；终止 → 抛「解压已取消」走既有失败清理。
  /// enc 特殊：走 [_decryptEncLayer]（7z 不识别 .enc 容器），补输弹窗
  /// 与 waiting_for_input 同构。
  Future<String> _autoTryFormats({
    required ExtractCandidate candidate,
    required String ext,
    required List<String> chain,
    required String scratchDir,
    required List<String?> passwordQueue,
    required int passwordLayerIndex,
    required Map<String, String> acceptedManual,
    required double startPercent,
    required double endPercent,
    required void Function(String ext) onChainExhausted,
  }) async {
    final scratch = Directory(scratchDir);
    if (!await scratch.exists()) await scratch.create(recursive: true);
    String fmtLabel(String f) => f == 'enc' ? 'enc' : '.$f';
    try {
      for (var i = 0; i < chain.length; i++) {
        final fmt = chain[i];
        if (_isCancelled) throw Exception('解压已取消');
        final attemptStart = startPercent +
            (endPercent - startPercent) * (i / (chain.length + 1));
        final attemptEnd = startPercent +
            (endPercent - startPercent) * ((i + 1) / (chain.length + 1));
        _emitProgress(ExtractProgress(
          percent: attemptStart.clamp(0, 100),
          message: '自动尝试 ${fmtLabel(fmt)}（${i + 1}/${chain.length}）...',
        ));
        _log('INFO', '🧪 自动尝试 ${fmtLabel(fmt)}: ${candidate.path}');
        _op('🧪 按改名链试解「${candidate.path.split('/').last.split('\\').last}」'
            ' → ${fmtLabel(fmt)}（${i + 1}/${chain.length}）');
        await _clearDirectory(scratchDir);
        try {
          if (fmt == 'enc') {
            await _decryptEncLayer(
              encPath: candidate.path,
              outputDir: scratchDir,
              startPercent: attemptStart,
              endPercent: attemptEnd,
              layerIndex: passwordLayerIndex,
              passwordCandidates: passwordQueue,
              onManualPassword: (triedCount) => _promptForPassword(
                archiveFile: candidate.path,
                format: 'enc',
                layerIndex: passwordLayerIndex,
                triedCount: triedCount,
              ),
            );
          } else {
            await _extractSingleFormat(
              candidate.path,
              fmtLabel(fmt),
              scratchDir,
              startPercent: attemptStart,
              endPercent: attemptEnd,
              passwordCandidates: passwordQueue,
              onCandidatesExhausted: (triedCount) => _promptForPassword(
                archiveFile: candidate.path,
                format: fmt,
                layerIndex: passwordLayerIndex,
                triedCount: triedCount,
              ),
              onManualPasswordAccepted: (pw) => acceptedManual[pw] = fmt,
            );
          }
          _log('INFO', '✅ 自动尝试命中: ${fmtLabel(fmt)}');
          return fmt;
        } catch (e) {
          _log('WARN', '⚠️ 自动尝试 ${fmtLabel(fmt)} 失败: $e');
        }
      }
      _log('ERROR', '❌ 自动尝试候选链全部失败（${chain.length} 种，.$ext）');
      onChainExhausted(ext);
      // 回落决策窗：仅手动指定/终止（同链再自动尝试无意义）
      final fallback = await _requestDecision(ExtractDecisionRequest(
        kind: 'strategy',
        message: '自动尝试已穷尽 ${chain.length} 种格式仍无法解出（.$ext），'
            '可手动指定格式，或终止解压',
        archiveFile: candidate.path,
        format: '',
        layerIndex: passwordLayerIndex - 1,
        candidates: [candidate],
      ));
      final f = fallback;
      final picked = (f != null && f.proceed && !f.autoTry)
          ? (f.format ?? '')
          : '';
      if (picked.isEmpty) {
        _log('INFO', '用户在自动尝试耗尽后的决策窗选择终止（或放弃）');
        throw Exception('解压已取消');
      }
      return picked;
    } finally {
      // 试解现场清干净（产物弃用；失败垃圾一并清除）
      await _clearDirectory(scratchDir);
      try {
        if (await scratch.exists()) await scratch.delete(recursive: true);
      } catch (e) {
        _log('WARN', '清理自动尝试 scratch 目录失败（忽略）: $scratchDir ($e)');
      }
    }
  }

  /// ★ Phase B（§1.4）：决策记忆回写映射表——手动指定/自动尝试命中的
  /// 后缀映射持久化（isDefault=true、通用层），下次同类后缀经
  /// lookupMapping 免打断。只替换同后缀的通用默认项，不碰分层映射。
  void _rememberDecisionMapping(String declaredExt, String format) {
    if (declaredExt.isEmpty || format.isEmpty) return;
    final ext = declaredExt.toLowerCase();
    final maps = List.of(UnpackStore.instance.mappings)
      ..removeWhere((m) =>
          m.fromExt == ext && m.isDefault && m.layerIndex < 0);
    maps.add(SuffixMapping(
      fromExt: ext,
      toFormat: format,
      isDefault: true,
      layerIndex: -1, // 通用层
    ));
    UnpackStore.instance.saveMappings(maps);
    _log('INFO', '已回写决策记忆: $ext → $format');
  }

  /// ★ Phase D（§1.2）：多候选推荐引擎——内置规则「多数同后缀 + 唯一异类」：
  /// ≥3 候选、后缀恰两类、异类仅 1 个、且异类比 < 1/3 → 推荐异类
  /// （如 4×.mp4 + 1×.mov → 推荐 .mov）。数量接近（异类比 ≥ 1/3）、
  /// 全同后缀、多异类、不足 3 个 → 不推荐（返回 null，用户自选）。
  /// 可选增强（体积/魔数维度）留 P2。
  ({ExtractCandidate candidate, String reason})? _recommendCandidate(
      List<ExtractCandidate> candidates) {
    if (candidates.length < 3) return null;
    final counts = <String, int>{};
    for (final c in candidates) {
      final e = (c.declaredExt ?? '').toLowerCase();
      counts[e] = (counts[e] ?? 0) + 1;
    }
    if (counts.length != 2) return null; // 全同后缀 / 多异类 → 不推荐
    String minorityExt = '';
    var minorityCount = -1;
    counts.forEach((e, n) {
      if (minorityCount < 0 || n < minorityCount) {
        minorityExt = e;
        minorityCount = n;
      }
    });
    if (minorityCount != 1) return null; // 异类不唯一 → 不推荐
    if (minorityCount / candidates.length >= 1 / 3) return null;
    final hit = candidates.firstWhere(
      (c) => (c.declaredExt ?? '').toLowerCase() == minorityExt,
    );
    final majorityExt =
        counts.keys.firstWhere((e) => e != minorityExt);
    return (
      candidate: hit,
      reason:
          '${counts[majorityExt]} 个 ${majorityExt.isEmpty ? '(无后缀)' : majorityExt} 中的唯一 '
              '${minorityExt.isEmpty ? '(无后缀)' : minorityExt}（多数同后缀 + 唯一异类）'
    );
  }

  /// ★ Phase 4：S.S.E. File Encryptor（.enc）层解密（方案 features/
  /// join_enc_decryptor.md）。密码候选队列与 [._extractSingleFormat] 同构：
  /// 队列轮换 → 耗尽走补输弹窗（waiting_for_input）→ 仍失败抛错收尾。
  /// 返回解密产物 zip 绝对路径（位于 [outputDir] 内，随临时层一并清理）。
  Future<String> _decryptEncLayer({
    required String encPath,
    required String outputDir,
    required double startPercent,
    required double endPercent,
    required int layerIndex,
    required List<String?> passwordCandidates,
    required Future<String?> Function(int triedCount)? onManualPassword,
  }) async {
    final outZip = path.join(
        outputDir,
        '${path.basename(encPath)}'
        '.decrypted.zip');
    final queue = <String>[
      ...passwordCandidates.whereType<String>().where((s) => s.isNotEmpty)
    ];
    final triedSet = <String>{};
    var triedCount = 0;

    _emitProgress(ExtractProgress(
      percent: startPercent.clamp(0, 100),
      message: '正在解密第${layerIndex + 1}层（S.S.E. 加密容器）...',
    ));

    while (true) {
      while (triedCount < queue.length) {
        if (_isCancelled) throw Exception('解压已取消');
        final pw = queue[triedCount];
        triedCount++;
        if (!triedSet.add(pw)) continue;
        try {
          _log('INFO', '🔓 .enc 解密（密码候选 #$triedCount，KDF 约 1-2s）');
          final sw = Stopwatch()..start();
          await EncDecryptor.decrypt(
            encPath: encPath,
            outputZipPath: outZip,
            password: pw,
            onProgress: (p) => _emitProgress(ExtractProgress(
              percent: (startPercent +
                      (endPercent - startPercent) * p)
                  .clamp(0, 100),
              message: '正在解密第${layerIndex + 1}层（S.S.E. 加密容器）...',
            )),
          );
          sw.stop();
          _log('INFO',
              '✅ .enc 解密完成（${sw.elapsedMilliseconds}ms）→ zip 续链');
          return outZip;
        } on EncWrongPasswordException {
          _log('INFO', '❌ .enc 密码候选 #$triedCount 不正确，轮换下一个');
        }
        // EncFormatException：格式/算法不支持，无解，直接抛给上层收尾。
      }

      // 队列耗尽 → 补输（同 Phase 3.5 waiting_for_input 语义）
      if (onManualPassword == null) {
        throw Exception('.enc 解压密码不正确（已尝试 $triedCount 个候选密码）');
      }
      final manual = await onManualPassword(triedCount);
      if (_isCancelled || manual == null || manual.isEmpty) {
        throw Exception('.enc 解压已取消（需要正确密码）');
      }
      queue.add(manual);
    }
  }

  /// 从文件名推断格式（魔数未命中时的兜底，对齐 _detectFormatsFromName 单层）
  String? _planFormatFromName(String path) {
    final name = path.split('/').last.split('\\').last.toLowerCase();
    for (final ext in [
      '.rar.lz4', '.zip.lz4', '.7z.lz4', '.tar.lz4',
      '.zip', '.rar', '.7z', '.lz4', '.tar', '.gz', '.bz2', '.xz',
      '.iso', '.cab', '.arj', '.zst', '.lzma', '.enc',
    ]) {
      if (name.endsWith(ext)) {
        if (ext.endsWith('.lz4')) return 'lz4';
        if (ext.startsWith('.tar')) return 'tar';
        return ext.substring(1);
      }
    }
    return null;
  }

  /// ★ Phase A（§1.2）：产物重扫 → 嵌套压缩包候选列表（替代原
  /// `_scanForNestedArchive` 单文件版）。修复两点存量缺陷：
  /// ① 旧版只看顶层（`entity is! File continue`），解出「folder/game.zip」
  ///    结构时发现不了子目录里的嵌套包 → 误判「解压完成」；
  /// ② 旧版 `dir.list()` 枚举序不保证，多候选时取哪个随文件系统漂移。
  /// 范围 = 顶层文件 + 各子目录一层内的文件；按路径排序保证确定性。
  /// 候选判定 = 魔数嗅探命中，或文件名可映射已知格式（伪装/头损坏兜底）；
  /// 或（[includeChainExts] = 伪装链上下文，Phase B §1.4）后缀在自动尝试
  /// 候选链表内的未知文件——链候选排序恒在魔数/名字候选之后。
  /// ★ 2026-10-05 实机反馈（情景三）：本体判定前的散文件魔数复查。
  /// `_scanForCandidates` 只认「已知压缩扩展名 / 链候选后缀」的文件——
  /// 伪装成视频/音频等资源样式的压缩容器（如 .mov 实为 S.S.E. enc 容器）
  /// 会被漏掉，导致 `_resolveGameBody` 把「3 诱饵视频 + 1 待解密资源」
  /// 误判为游戏本体提前收尾。此处在常规候选为空时对顶层散文件再跑一轮
  /// 嗅探，只收「魔数命中压缩格式且扩展名不吻合」（disguised）的文件。
  /// 注：能走到该分支说明已无任何常规压缩包候选，不会与本体自带的
  /// patch.zip 之类正常资源冲突（那些在前一步就已被收为候选）。
  Future<List<ExtractCandidate>> _sniffDisguisedFiles(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return const [];
    final candidates = <ExtractCandidate>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue; // 只查顶层散文件（子目录归本体判定）
      final sniff = ArchiveInspector.sniffSync(entity.path);
      if (!sniff.disguised) continue;
      int size = 0;
      try {
        size = entity.lengthSync();
      } catch (_) {
        // 扫描间隙消失（极少见竞态）：体积仅用于展示，置 0 继续
      }
      final name = entity.path.split('/').last.split('\\').last.toLowerCase();
      final dot = name.lastIndexOf('.');
      candidates.add(ExtractCandidate(
        path: entity.path,
        magicFormat: sniff.format,
        nameFormat: null,
        declaredExt: dot >= 0 ? name.substring(dot) : null,
        sizeBytes: size,
      ));
    }
    for (final c in candidates) {
      _log('INFO',
          '🧩 伪装容器复查命中: ${c.path.split('/').last.split('\\').last} → ${c.magicFormat}');
    }
    return candidates;
  }

  Future<List<ExtractCandidate>> _scanForCandidates(String dirPath,
      {bool includeChainExts = false}) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return const [];
    final candidates = <ExtractCandidate>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File) {
        final c = _candidateOfFile(entity, includeChainExts: includeChainExts);
        if (c != null) candidates.add(c);
      } else if (entity is Directory) {
        await for (final inner in entity.list(followLinks: false)) {
          if (inner is! File) continue;
          final c =
              _candidateOfFile(inner, includeChainExts: includeChainExts);
          if (c != null) candidates.add(c);
        }
      }
    }
    // 排序：魔数/名字候选优先（rank 0），链候选殿后（rank 1）；
    // 同级按路径（确定性）
    int rank(ExtractCandidate c) =>
        (c.magicFormat == null && c.nameFormat == null) ? 1 : 0;
    candidates.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      return a.path.toLowerCase().compareTo(b.path.toLowerCase());
    });
    for (final c in candidates) {
      _log('INFO',
          '🔍 候选: ${c.path.split('/').last.split('\\').last} → 魔数=${c.magicFormat ?? '无'} 名字=${c.nameFormat ?? '无'}');
    }
    return candidates;
  }

  /// 单文件候选判定（Phase A/B）：魔数命中 或 文件名可映射已知格式；
  /// 或 [includeChainExts] 时后缀在自动尝试候选链表内的未知文件。
  ExtractCandidate? _candidateOfFile(File f, {required bool includeChainExts}) {
    final sniff = ArchiveInspector.sniffSync(f.path);
    final nameFormat = _planFormatFromName(f.path);
    final name = f.path.split('/').last.split('\\').last.toLowerCase();
    final dot = name.lastIndexOf('.');
    final ext = dot >= 0 ? name.substring(dot) : '';
    if (!sniff.isArchive && nameFormat == null) {
      if (!includeChainExts ||
          ext.isEmpty ||
          UnpackStore.instance.autoTryChainFor(ext).isEmpty) {
        return null;
      }
      // 链候选：魔数/名字皆未命中，但后缀可自动尝试（Phase B）
    }
    int size = 0;
    try {
      size = f.lengthSync();
    } catch (_) {
      // 文件在扫描间隙消失（极少见竞态）：体积仅用于展示，置 0 继续
    }
    return ExtractCandidate(
      path: f.path,
      magicFormat: sniff.format,
      nameFormat: nameFormat,
      declaredExt: ext.isEmpty ? null : ext,
      sizeBytes: size,
    );
  }

  /// 将 src 目录的全部顶层条目搬入 dst（同盘 rename，O(1)/条目）。
  /// dst 同名条目自动加 _1 后缀避让。
  Future<void> _moveDirContents(String src, String dst) async {
    final srcDir = Directory(src);
    final dstDir = Directory(dst);
    if (!await dstDir.exists()) {
      await dstDir.create(recursive: true);
    }
    await for (final entity in srcDir.list(followLinks: false)) {
      final name = entity.path.split('/').last.split('\\').last;
      var target = '$dst/$name';
      if (FileSystemEntity.typeSync(target) != FileSystemEntityType.notFound) {
        final dot = name.lastIndexOf('.');
        final base = dot > 0 ? name.substring(0, dot) : name;
        final ext = dot > 0 ? name.substring(dot) : '';
        var i = 1;
        while (FileSystemEntity.typeSync('$dst/$base$i$ext') !=
            FileSystemEntityType.notFound) {
          i++;
        }
        target = '$dst/$base$i$ext';
      }
      try {
        await entity.rename(target);
      } catch (e) {
        // rename 失败（极少见：权限/占用）→ 抛出走既有失败清理
        _log('ERROR', '搬移失败: ${entity.path} → $target ($e)');
        rethrow;
      }
    }
    _log('INFO', '已将 $src 内容搬移到 $dst');
  }

  /// 清空目录内容（保留目录本身）。仅用于 waiting_for_input 补输重试前
  /// 清除错密码落盘的垃圾文件——plan 路径的 outputDir 恒为 `_temp_layer_N`
  /// 临时层（最终产物在收尾时才搬入），清空安全。
  Future<void> _clearDirectory(String dirPath) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
      try {
        await entity.delete(recursive: true);
      } catch (e) {
        _log('WARN', '清理垃圾文件失败（忽略，继续重试）: ${entity.path} ($e)');
      }
    }
  }

  Future<String> _extractSingleFormat(
    String inputPath,
    String format,
    String outputDir, {
    required double startPercent,
    required double endPercent,
    bool isFromLz4 = false,
    String? password,
    List<String?>? passwordCandidates,
    /// ★ waiting_for_input（方案 §4.5）：候选队列全败且错误为密码相关时
    ///   触发，返回用户补输的密码（追加进队列重试）；null = 放弃。
    Future<String?> Function(int triedCount)? onCandidatesExhausted,
    /// 补输密码最终使本层解压成功时回调（供上层写入密码记忆库）。
    void Function(String password)? onManualPasswordAccepted,
  }) async {
    _log('INFO', '========== 开始解压: $format ==========');
    _log('INFO', '输入: $inputPath');
    _log('INFO', '输出: $outputDir');
    _log('INFO',
        '进度范围: ${startPercent.toStringAsFixed(1)}% - ${endPercent.toStringAsFixed(1)}%');

    if (isFromLz4) {
      _log('INFO', '⚠️ 此文件来自LZ4双层解压，将使用特殊密码策略');
    }

    final isPasswordSupportedFormat =
        (format == '.rar' || format == '.zip' || format == '.7z');

    // 密码候选队列：null（无密码）= 先试明文
    final List<String?> queue;
    if (passwordCandidates != null) {
      queue = passwordCandidates;
    } else if (password != null && isPasswordSupportedFormat) {
      queue = [null, password];
    } else {
      queue = [null, _defaultPassword];
    }
    // 去重（保序）：同一密码不试两次
    final seen = <String?>{};
    final candidates = queue
        .where((pw) => !isPasswordSupportedFormat
            ? pw == null || pw.isEmpty
            : seen.add(pw))
        .toList();

    Object? lastError;
    var attempt = 0;
    // ★ waiting_for_input：来自补输弹窗的密码（成功后经
    //   onManualPasswordAccepted 写入记忆库，方案 §4.4）
    final manualTried = <String>{};
    var idx = 0;
    while (idx < candidates.length) {
      final pw = candidates[idx];
      idx++;
      attempt++;
      if (!isPasswordSupportedFormat && attempt > 1) break;

      _log('INFO',
          '--- 第$attempt次尝试: ${pw == null || pw.isEmpty ? '无密码' : '带密码（候选 #$attempt）'} ---');
      _op('调用解压工具试解 $format（第 $attempt 次'
          '${pw == null || pw.isEmpty ? '，无密码' : '，候选 #$attempt'}）');
      final adjustedStart = startPercent +
          ((endPercent - startPercent) * ((attempt - 1) / candidates.length));
      final adjustedEnd =
          startPercent + ((endPercent - startPercent) * (attempt / candidates.length));

      try {
        String result;
        switch (format) {
          case '.zip':
            result = await _extractZip(inputPath, outputDir,
                password: pw,
                startPercent: adjustedStart,
                endPercent: adjustedEnd);
            break;
          case '.rar':
            result = await _extractRar(inputPath, outputDir,
                password: pw,
                startPercent: adjustedStart,
                endPercent: adjustedEnd);
            break;
          case '.7z':
            result = await _extract7z(inputPath, outputDir,
                password: pw,
                startPercent: adjustedStart,
                endPercent: adjustedEnd);
            break;
          case '.lz4':
            result = await _extractLz4(inputPath, outputDir,
                startPercent: adjustedStart, endPercent: adjustedEnd);
            break;
          case '.tar':
          case '.tar.gz':
          case '.tar.bz2':
          case '.tar.xz':
          case '.tar.zst':
            result = await _extractTarBased(inputPath, outputDir, format,
                startPercent: adjustedStart, endPercent: adjustedEnd);
            break;
          case '.gz':
          case '.bz2':
          case '.xz':
          case '.zst':
          case '.lzma':
            result = await _extractSingleCompression(inputPath, outputDir, format,
                startPercent: adjustedStart, endPercent: adjustedEnd);
            break;
          case '.iso':
            result = await _extractIso(inputPath, outputDir,
                startPercent: adjustedStart, endPercent: adjustedEnd);
            break;
          case '.cab':
            result = await _extractCab(inputPath, outputDir,
                startPercent: adjustedStart, endPercent: adjustedEnd);
            break;
          case '.arj':
            result = await _extractArj(inputPath, outputDir,
                startPercent: adjustedStart, endPercent: adjustedEnd);
            break;
          default:
            throw Exception('不支持的压缩格式: $format');
        }

        _log('INFO',
            '✅ 第$attempt次尝试成功（${pw == null || pw.isEmpty ? '无密码' : '候选密码 #$attempt'}）');
        // 补输密码最终生效 → 回调上层写记忆库（方案 §4.4）
        if (pw != null && pw.isNotEmpty && manualTried.contains(pw)) {
          onManualPasswordAccepted?.call(pw);
        }
        return result;
      } catch (e) {
        lastError = e;
        _log('WARN', '⚠️ 第$attempt次尝试失败: $e');

        if (!isPasswordSupportedFormat) {
          _log('ERROR', '$format 格式不支持密码重试，直接抛出异常');
          rethrow;
        }

        final errStr = e.toString().toLowerCase();
        // ★ 2026-10-05 实机反馈：RAR5「加密文件名」容器在无密码/错密码时
        //   7z 报「Cannot open the file as archive」（连容器头都解不开，
        //   不同于内容加密的 Wrong password）——原分类器不含此关键词，
        //   误判为非密码错误 → 直接走「损坏」弹窗，用户永远没有补输密码的
        //   机会（Bandizip/WinRAR 手动解压正常，误报「压缩包已损坏」）。
        //   归入密码相关后走候选轮换 → 耗尽弹补输密码框。
        final isPasswordRelatedError = errStr.contains('password') ||
            errStr.contains('wrong') ||
            errStr.contains('incorrect') ||
            errStr.contains('加密') ||
            errStr.contains('need password') ||
            errStr.contains('corrupt') ||
            errStr.contains('checksum') ||
            errStr.contains('bad password') ||
            errStr.contains('wrong password') ||
            errStr.contains('password required') ||
            errStr.contains('encrypted') ||
            errStr.contains('cannot open the file as');

        if (!isPasswordRelatedError) {
          _log('ERROR', '错误类型不是密码相关，不进行密码轮换');
          rethrow;
        }
        // ★ waiting_for_input（方案 §4.5）：候选队列全败 → 暂停等待用户
        //   补输密码。拿到新密码则清空错密码落盘的垃圾文件（Phase 0 实测
        //   错密码解压会产出乱码文件）后重试；放弃/重复密码 → 走既有失败路径。
        if (idx >= candidates.length && onCandidatesExhausted != null) {
          _op('⏸ 密码候选全部无效（$attempt 次），等待输入密码…');
          final manual = await onCandidatesExhausted(attempt);
          if (manual != null && manual.isNotEmpty && seen.add(manual)) {
            candidates.add(manual);
            manualTried.add(manual);
            _log('INFO', '⏸ 用户已补输密码，清理本层垃圾文件后重试');
            await _clearDirectory(outputDir);
            continue;
          }
          _log('INFO', '用户放弃补输（或密码与已试候选重复），按失败处理');
        }
        // 密码相关失败 → 继续下一个候选
      }
    }

    _log('ERROR', '❌ 所有密码候选均失败（共 $attempt 次尝试）');
    throw Exception('解压失败（密码候选均无效）:\n'
        '格式: $format\n'
        '文件: $inputPath\n'
        '----------------------------------------\n'
        '[最后错误] $lastError\n'
        '----------------------------------------');
  }

  Future<String> _extractZip(
    String inputPath,
    String outputDir, {
    String? password,
    required double startPercent,
    required double endPercent,
  }) async {
    final exePath = await _getBundled7zPath();
    _log('INFO', '使用内置7-Zip解压ZIP${password != null ? " (带密码)" : ""}');
    return await _extractWith7z(inputPath, outputDir, 'zip',
        password: password, startPercent: startPercent, endPercent: endPercent);
  }

  Future<String> _extractRar(
    String inputPath,
    String outputDir, {
    String? password,
    bool forceDefaultPassword = false,
    required double startPercent,
    required double endPercent,
  }) async {
    final effectivePassword =
        forceDefaultPassword ? _defaultPassword : password;

    _log('INFO', '═══════════════════════════════════════');
    _log('INFO', '【RAR解压】使用7-Zip解压');
    _log('INFO', '输入文件: $inputPath');
    _log('INFO', '输出目录: $outputDir');
    // 安全：解压密码属敏感信息，日志会落盘到 logs/extract_*.txt，
    // 只记录“有/无”，不输出密码明文。
    _log('INFO',
        '密码: ${effectivePassword != null && effectivePassword.isNotEmpty ? "有密码" : "无密码"}');
    _log('INFO', '═══════════════════════════════════════');

    final inputFile = File(inputPath);
    if (!await inputFile.exists()) {
      throw Exception('RAR输入文件不存在: $inputPath');
    }

    final inputSize = await inputFile.length();
    if (inputSize == 0) {
      throw Exception('RAR输入文件为空: $inputPath');
    }

    _log('INFO', '输入文件大小: ${(inputSize / 1024 / 1024).toStringAsFixed(2)}MB');

    final outDir = Directory(outputDir);
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
      _log('INFO', '创建输出目录: $outputDir');
    }

    _emitProgress(ExtractProgress(
      percent: startPercent,
      message: password != null ? '正在解压RAR(带密码)...' : '正在解压RAR...',
    ));

    return await _extractRarWith7z(
      inputPath: inputPath,
      outputDir: outputDir,
      password: effectivePassword,
      startPercent: startPercent,
      endPercent: endPercent,
    );
  }

  Future<String> _extractRarWith7z({
    required String inputPath,
    required String outputDir,
    required String? password,
    required double startPercent,
    required double endPercent,
  }) async {
    final exePath = await _getBundled7zPath();

    final outDir = Directory(outputDir);
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }

    // 使用 -y 模式（自动确认覆盖），避免残留文件干扰解压
    // 之前的 -aos（跳过已存在文件）可能导致上次失败的残留文件不被覆盖
    // 使用 -bsp1 让 7z 输出进度到 stdout
    //
    // ★ 2026-10-02 M1（游戏数据保存 Phase 1）：补 `-sccUTF-8`。
    //   中文 Windows 上 7z 的控制台输出默认是 **GBK** 字节，而下游用的是
    //   `utf8.decoder` —— 一旦进度行里带上中文/日文文件名（GAL 游戏几乎必然），
    //   解码器会抛 FormatException 并**整条中止 stdout 流**，进度与日志双双停摆。
    //   实测（dev_probe/phase1_progress_parser_probe.dart 同批）：
    //   不加时输出 `\xd6\xd0\xce\xc4`（GBK），加了之后是真 UTF-8。
    final args = <String>[
      'x',
      inputPath,
      '-o$outputDir',
      '-y',
      '-bsp1',
      '-sccUTF-8',
    ];

    if (password != null && password.isNotEmpty) {
      args.add('-p$password');
    } else {
      args.add('-p');
    }

    // 使用 Process.start 替代 Process.run，避免阻塞主 Isolate
    final process = await Process.start(
      exePath,
      args,
      workingDirectory: outputDir,
    );
    _currentProcess = process;

    final stderrLines = <String>[];
    int lastPercent = 0;

    final stdoutSub = process.stdout
        // ★ 2026-10-02 M1：解码器兜底 allowMalformed —— 即便某条输出没吃上
        //   `-sccUTF-8`（如内嵌的 Windows API 错误串），也绝不允许它掀翻整条流。
        //   进度行本身是纯 ASCII，不受影响。
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
      final parsed = _parse7zLine(line);
      if (parsed != null && parsed > lastPercent) {
        lastPercent = parsed;
        final adjusted =
            startPercent + (parsed / 100.0) * (endPercent - startPercent);
        _emitProgress(ExtractProgress(
          percent: adjusted,
          message: '解压中 $parsed%',
        ));
      }
    });

    final stderrSub = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
      stderrLines.add(line);
    });

    final exitCode = await process.exitCode;
    await stdoutSub.cancel();
    await stderrSub.cancel();
    _currentProcess = null;

    if (exitCode != 0) {
      _log('ERROR', '7-Zip解压RAR失败 (exitCode=$exitCode)');
      for (final line in stderrLines) {
        final lower = line.toLowerCase();
        if (lower.contains('error') ||
            lower.contains('cannot') ||
            lower.contains('wrong password')) {
          _log('ERROR', '  $line'.trim());
        }
      }
      // ★ Phase F（§1.5）：stderr 摘要随异常上抛——corrupt 分类器靠它
      // 区分缺卷/CRC/不支持（裸 exitCode 无从分类）。
      final errSummary = stderrLines
          .where((l) =>
              l.toLowerCase().contains('error') ||
              l.toLowerCase().contains('cannot') ||
              l.toLowerCase().contains('wrong password'))
          .take(3)
          .join(' | ');
      throw Exception('解压失败(exitCode=$exitCode)'
          '${errSummary.isEmpty ? '' : ': $errSummary'}');
    }

    await Future.delayed(const Duration(milliseconds: 200));
    return outputDir;
  }

  Future<String> _extract7z(
    String inputPath,
    String outputDir, {
    String? password,
    required double startPercent,
    required double endPercent,
  }) async {
    final exePath = await _getBundled7zPath();

    _log('INFO', '使用内置7-Zip解压ZIP/7Z（流式非阻塞）');

    final outDir = Directory(outputDir);
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }

    // 使用 -y 模式（自动确认覆盖），避免残留文件干扰解压
    // 使用 -bsp1 让 7z 输出进度到 stdout
    // ★ 2026-10-02 M1：补 `-sccUTF-8`，否则中文/日文文件名会把
    //   utf8.decoder 打挂并中止整个 stdout 流（同上文说明）
    final args = <String>[
      'x',
      inputPath,
      '-o$outputDir',
      '-y',
      '-bsp1',
      '-sccUTF-8',
    ];

    if (password != null && password.isNotEmpty) {
      args.add('-p$password');
    } else {
      args.add('-p');
    }

    // 使用 Process.start 替代 Process.run，避免阻塞主 Isolate
    final process = await Process.start(
      exePath,
      args,
      workingDirectory: outputDir,
    );
    _currentProcess = process;

    final stdoutLines = <String>[];
    final stderrLines = <String>[];
    int lastPercent = 0;

    // 监听 stdout 流，实时解析进度
    final stdoutSub = process.stdout
        // ★ 2026-10-02 M1：解码器兜底 allowMalformed —— 即便某条输出没吃上
        //   `-sccUTF-8`（如内嵌的 Windows API 错误串），也绝不允许它掀翻整条流。
        //   进度行本身是纯 ASCII，不受影响。
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
      stdoutLines.add(line);
      final parsed = _parse7zLine(line);
      if (parsed != null && parsed > lastPercent) {
        lastPercent = parsed;
        final adjusted =
            startPercent + (parsed / 100.0) * (endPercent - startPercent);
        _emitProgress(ExtractProgress(
          percent: adjusted,
          message: '解压中 $parsed%',
        ));
      }
    });

    // 监听 stderr 流
    final stderrSub = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
      stderrLines.add(line);
    });

    final exitCode = await process.exitCode;
    await stdoutSub.cancel();
    await stderrSub.cancel();
    _currentProcess = null;

    // ★ 2026-10-05 实机反馈：7z 退出码语义 0=OK / 1=非致命警告 / 2+=致命。
    //   网盘过审壳「视频数据+尾部拼接 zip」解压必带警告「There are data
    //   after the end of archive」→ exitCode=1，原先 != 0 把解压成功当
    //   失败。放宽为 >1：警告放行（记 INFO 供追溯），CRC 损坏/缺卷等
    //   致命错误（2+）仍走失败分支。
    if (exitCode == 1) {
      final warnLines = stdoutLines
          .where((l) => l.contains('WARNING'))
          .take(3)
          .join(' | ');
      _log('INFO', '7-Zip解压完成（非致命警告 exitCode=1）'
          '${warnLines.isEmpty ? '' : ': $warnLines'}');
    } else if (exitCode > 1) {
      _log('ERROR', '7-Zip解压失败 (exitCode=$exitCode)');
      for (final line in stderrLines) {
        final lower = line.toLowerCase();
        if (lower.contains('error') ||
            lower.contains('cannot') ||
            lower.contains('wrong password')) {
          _log('ERROR', '  $line'.trim());
        }
      }
      // ★ Phase F（§1.5）：stderr 摘要随异常上抛——corrupt 分类器靠它
      // 区分缺卷/CRC/不支持（裸 exitCode 无从分类）。
      final errSummary = stderrLines
          .where((l) =>
              l.toLowerCase().contains('error') ||
              l.toLowerCase().contains('cannot') ||
              l.toLowerCase().contains('wrong password'))
          .take(3)
          .join(' | ');
      throw Exception('解压失败(exitCode=$exitCode)'
          '${errSummary.isEmpty ? '' : ': $errSummary'}');
    }

    // 验证结果
    await Future.delayed(const Duration(milliseconds: 200));
    // ★ P0-7：流式统计，不物化
    final fileCount = (await FsScan.countRecursive(outDir)).files;

    if (fileCount == 0) {
      throw Exception('解压后目录为空');
    }

    _log('INFO', '解压完成 ($fileCount 个文件)');
    return outputDir;
  }

  /// 解析 7z 的 `-bsp1` 进度行。
  ///
  /// ★ 2026-10-02 M1：**原实现的正则是 `^\s*(\d+)\s`** —— 它要求数字后面跟
  /// **空白**，而 7z 的实际输出是 `\r 94% 31 - src\file`（`%` 紧跟数字）。
  /// Phase 0 实测（`dev_probe/phase0_extract_result.json`）：
  /// 真实 stdout 按 LineSplitter 切出 37 段，旧正则**只命中 1 段**，
  /// 且那 1 段还是把 `1 file, 135716363 bytes` 这种信息行误读成了 1%。
  ///
  /// ⇒ **本项目的解压进度条从来没有被真实百分比驱动过**，一直在骨架值之间跳。
  ///
  /// 现在统一委托 [SevenZipProgressParser]（压缩/解压共用一份实现），
  /// 正则改为 `^\s*(\d{1,3})\s*%`，同一份实测数据下命中 4/37。
  /// 压缩侧（`ArchiveCompressor`）复用同一实现，两边不会再各自漂移。
  int? _parse7zLine(String line) => SevenZipProgressParser.parse(line);

  Future<void> _extractRarLz4({
    required String archivePath,
    required String outputDir,
  }) async {
    _log('INFO', '==========================================');
    _log('INFO', '【.rar.lz4 格式检测】使用 Dart 原生 bz.exe + UnRAR.exe 方案');
    _log('INFO', '==========================================');
    _log('INFO', '压缩包: $archivePath');
    _log('INFO', '输出目录: $outputDir');

    final archiveFile = File(archivePath);
    if (!await archiveFile.exists()) {
      throw Exception('.rar.lz4 压缩包不存在: $archivePath');
    }

    _emitProgress(const ExtractProgress(
        percent: 5, message: '正在初始化 bz.exe + UnRAR.exe...'));

    try {
      final service = RarLz4UnzipService();

      _emitProgress(const ExtractProgress(
          percent: 10, message: '正在解压 .rar.lz4 (bz.exe + UnRAR.exe)...'));

      final success = await service.unzip(archivePath, outputDir);

      if (!success) {
        _log('ERROR', '❌ bz.exe + UnRAR.exe 解压返回失败');
        throw Exception('[.rar.lz4 解压失败] 工具返回非 SUCCESS');
      }

      _emitProgress(const ExtractProgress(
        percent: 92,
        message: '解压成功，正在验证...',
      ));

      final targetDir = Directory(outputDir);
      if (!await targetDir.exists()) {
        throw Exception('解压完成但目标目录不存在: $outputDir');
      }

      final entities = await targetDir.list().toList();
      if (entities.isEmpty) {
        throw Exception('解压完成但目标目录为空: $outputDir');
      }

      _log('INFO', '✅ 验证通过 | 目标目录包含 ${entities.length} 个条目');

      final fileCount = entities.whereType<File>().length;
      final dirCount = entities.whereType<Directory>().length;
      _log('INFO', '   - 文件数: $fileCount');
      _log('INFO', '   - 目录数: $dirCount');

      _emitProgress(const ExtractProgress(
        percent: 96,
        message: '验证通过，准备写入游戏信息...',
      ));

      _emitProgress(const ExtractProgress(
        percent: 100,
        message: '解压完成',
      ));

      _log('INFO', '==========================================');
      _log('INFO', '✅ 【bz.exe + UnRAR.exe】解压成功完成');
      _log('INFO', '==========================================');
      _log('INFO', '');
    } catch (e) {
      _log('ERROR', '');
      _log('ERROR', '【bz.exe + UnRAR.exe】异常: $e');
      _log('ERROR', '');
      rethrow;
    }
  }

  Future<String> _extractLz4(
    String inputPath,
    String outputDir, {
    required double startPercent,
    required double endPercent,
  }) async {
    // ★ 2026-10-04 智能解压 Phase 1（G5 修复）：改用内置 Bandizip CLI 解 LZ4。
    // 原实现走 assets/tools/lz4.exe，但该文件从未存在于 assets（打包缺件），
    // 独立 .lz4 路径运行时必炸；Phase 0 探针实测 bz.exe 对 .lz4 / .zip.lz4
    // 解压 rc=0 全通过，且 7z 23.01 不支持 lz4（T15），故收敛到 bz.exe。
    // 产物名规则与原实现一致：输入文件名去掉 .lz4 后缀（Phase 0 T11 实测）。
    final bzPath = await _getToolPath('bz.exe');

    _log('INFO', '');
    _log('INFO', '【LZ4 解压开始】');
    _log('INFO', '========== LZ4外层解压 ==========');
    _log('INFO', '工具路径: $bzPath (Bandizip CLI)');
    _log('INFO', '输入文件: $inputPath');

    final inputFile = File(inputPath);
    if (!await inputFile.exists()) {
      throw Exception('LZ4输入文件不存在: $inputPath');
    }

    final inputSize = await inputFile.length();
    if (inputSize == 0) {
      throw Exception('LZ4输入文件为空: $inputPath');
    }

    _log('INFO', '输入文件大小: ${(inputSize / 1024 / 1024).toStringAsFixed(2)}MB');

    final outDir = Directory(outputDir);
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
      _log('INFO', '创建输出目录: $outputDir');
    }

    final fileName = inputPath.split('/').last.split('\\').last;
    var outName = fileName;

    if (outName.endsWith('.lz4')) {
      outName = outName.substring(0, outName.length - 4);
    }

    if (outName.isEmpty) {
      outName = 'temp_archive';
    }

    final outputPath = path.join(outputDir, outName);

    // ★ IMP-06: 登记本任务自建的中间压缩包，失败回滚只清理登记项
    _taskOwnedTempArchives.add(outputPath);

    _log('INFO', '输出文件: $outputPath');

    _emitProgress(ExtractProgress(
      percent: startPercent,
      message: '正在解压LZ4外层...',
    ));

    try {
      // 命令: bz.exe x -y <lz4_file> <out_dir>\ —— 照抄 rar_lz4_unzip_service.dart:126
      // 已验证范式（输出目录参数带尾部 '\' 以区分"解压到目录"与"解压为文件"）
      _log('INFO', 'LZ4完整命令: $bzPath x -y "$inputPath" "$outputDir\\"');

      // 使用 Process.start 替代 Process.run，避免阻塞主 Isolate
      final process = await Process.start(
        bzPath,
        ['x', '-y', inputPath, '$outputDir\\'],
        workingDirectory: outputDir,
      );
      _currentProcess = process;

      final stderrLines = <String>[];
      final stderrSub = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        stderrLines.add(line);
      });

      final exitCode = await process.exitCode;
      await stderrSub.cancel();
      _currentProcess = null;

      _log('INFO', 'Bandizip(LZ4)进程退出码: $exitCode');
      if (stderrLines.isNotEmpty) {
        _log('INFO', 'Bandizip(LZ4) stderr: ${stderrLines.take(5).join(' | ')}');
      }

      if (exitCode != 0) {
        throw Exception('LZ4解压失败(exitCode=$exitCode)');
      }

      final outputFile = File(outputPath);
      if (!await outputFile.exists()) {
        throw Exception('LZ4解压完成但输出文件不存在: $outputPath');
      }

      final outputSize = await outputFile.length();
      if (outputSize == 0) {
        throw Exception('LZ4解压完成但输出文件为空: $outputPath');
      }

      _log('INFO',
          '✅ LZ4解压成功 | 输出大小: ${(outputSize / 1024 / 1024).toStringAsFixed(2)}MB | 路径: $outputPath');
      _log('INFO', '【LZ4 解压完成，生成临时 .rar 文件】');
      _log('INFO', '========== LZ4外层解压结束 ==========');
      _log('INFO', '');

      _emitProgress(ExtractProgress(
        percent: endPercent,
        message: 'LZ4外层解压完成',
      ));

      return outputPath;
    } catch (e) {
      _log('ERROR', 'LZ4解压异常: $e');

      final badFile = File(outputPath);
      if (await badFile.exists()) {
        try {
          await badFile.delete();
          _log('INFO', '已清理失败的LZ4输出: $outputPath');
        } catch (_) {}
      }

      rethrow;
    }
  }

  Future<String> _extractTarBased(
    String inputPath,
    String outputDir,
    String format, {
    required double startPercent,
    required double endPercent,
  }) async {
    final exePath = await _getBundled7zPath();
    _log('INFO', '使用7-Zip解压TAR系列格式($format)');
    return await _extractWith7z(
        inputPath, outputDir, format.replaceAll('.', ''),
        startPercent: startPercent, endPercent: endPercent);

    _log('INFO', '尝试使用tar命令解压($format)');
    final outDir = Directory(outputDir);
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }

    String flag;
    switch (format) {
      case '.tar.gz':
      case '.gz':
        flag = 'xzf';
        break;
      case '.tar.bz2':
      case '.bz2':
        flag = 'xjf';
        break;
      case '.tar.xz':
        flag = 'xJf';
        break;
      default:
        flag = 'xf';
    }

    final result = await Process.run(
      'tar',
      [flag, inputPath, '-C', outputDir],
    );

    final exitCode = result.exitCode;

    if (exitCode != 0) {
      throw Exception('TAR解压失败(exitCode=$exitCode)');
    }

    _emitProgress(ExtractProgress(
      percent: endPercent,
      message: 'TAR解压完成',
    ));
    return outputDir;
  }

  Future<String> _extractWith7z(
    String inputPath,
    String outputDir,
    String formatType, {
    String? password,
    required double startPercent,
    required double endPercent,
  }) async {
    return await _extract7z(inputPath, outputDir,
        password: password, startPercent: startPercent, endPercent: endPercent);
  }

  Future<String> _extractSingleCompression(
    String inputPath,
    String outputDir,
    String format, {
    required double startPercent,
    required double endPercent,
  }) async {
    _log('INFO', '【单文件压缩格式解压】$format');

    final exePath = await _getBundled7zPath();
    _log('INFO', '使用7-Zip解压单文件压缩格式: $format');
    return await _extractWith7z(
        inputPath, outputDir, format.replaceAll('.', ''),
        startPercent: startPercent, endPercent: endPercent);
  }

  Future<String> _extractIso(
    String inputPath,
    String outputDir, {
    required double startPercent,
    required double endPercent,
  }) async {
    _log('INFO', '【ISO格式解压】');

    final exePath = await _getBundled7zPath();
    _log('INFO', '使用7-Zip解压ISO');
    return await _extractWith7z(inputPath, outputDir, 'iso',
        startPercent: startPercent, endPercent: endPercent);
  }

  Future<String> _extractCab(
    String inputPath,
    String outputDir, {
    required double startPercent,
    required double endPercent,
  }) async {
    _log('INFO', '【CAB格式解压】');

    final exePath = await _getBundled7zPath();
    _log('INFO', '使用7-Zip解压CAB');
    return await _extractWith7z(inputPath, outputDir, 'cab',
        startPercent: startPercent, endPercent: endPercent);

    _log('INFO', '尝试使用Windows内置expand工具解压CAB...');
    final outDir = Directory(outputDir);
    if (!await outDir.exists()) {
      await outDir.create(recursive: true);
    }

    final result = await Process.run(
      'expand',
      [inputPath, '-F:\\*', outputDir],
    );

    if (result.exitCode != 0) {
      throw Exception('CAB解压失败(exitCode=${result.exitCode})');
    }

    _emitProgress(ExtractProgress(
      percent: endPercent,
      message: 'CAB解压完成',
    ));
    return outputDir;
  }

  Future<String> _extractArj(
    String inputPath,
    String outputDir, {
    required double startPercent,
    required double endPercent,
  }) async {
    _log('INFO', '【ARJ格式解压】');

    final exePath = await _getBundled7zPath();
    _log('INFO', '使用7-Zip解压ARJ');
    return await _extractWith7z(inputPath, outputDir, 'arj',
        startPercent: startPercent, endPercent: endPercent);
  }

  Future<String> _getBundled7zPath() async {
    final bundled = '${PathHelper.toolsDir}/7z.exe';
    final f = File(bundled);
    if (await f.exists()) return f.absolute.path;
    throw Exception('内置 7z.exe 不存在: $bundled');
  }

  Future<void> _writeGameInfo({
    required String targetDir,
    required String title,
    String? description,
    String? coverUrl,
    String? bannerUrl,
    List<String>? tags,
    String? developer,
    String? overrideDirectoryPath,
    List<String>? screenshotUrls,
    String? subtitle,
    String? cloudGameId,
  }) async {
    _log('INFO', '🔍 开始智能识别启动 EXE...');

    final detectionDir = overrideDirectoryPath ?? targetDir;
    final detection = await GameLauncherDetector.detect(detectionDir);

    String launcherPath = '';
    if (detection.success && detection.launcherPath != null) {
      launcherPath = detection.launcherPath!;
      _log('INFO',
          '✅ 识别成功 | 优先级#${detection.priority} | ${detection.exeFileName}');
    } else {
      _log('WARN', '⚠️ 自动识别失败，launch_path留空（用户可手动选择）');
    }

    await GameDataFormat.writeGameDir(
      targetDir: targetDir,
      title: title,
      description: description ?? '',
      tags: tags ?? [],
      coverUrl: coverUrl,
      bannerUrl: bannerUrl,
      launchPath: launcherPath,
      directoryPath: overrideDirectoryPath ?? targetDir,
      source: 'download',
      developer: developer ?? '',
      screenshotUrls: screenshotUrls,
      subtitle: subtitle,
      cloudGameId: cloudGameId,
    );

    final effectiveDir = overrideDirectoryPath ?? targetDir;
    _log('INFO', '已写入 .ctgame + game.json: $targetDir');
    _log('INFO', '   directory_path: $effectiveDir');

    if (launcherPath.isNotEmpty) {
      _log('INFO', '   launch_path: $launcherPath');
    }

    final writtenData = await GameDataFormat.readGameJson(targetDir);
    if (writtenData != null) {
      if (writtenData.directoryPath != effectiveDir) {
        _log('WARN', '⚠️ game.json中的directory_path不一致!');
        _log('WARN', '   期望: $effectiveDir');
        _log('WARN', '   实际: ${writtenData.directoryPath}');
        _log('WARN', '   正在修正...');
        await GameDataFormat.updateGameJson(targetDir, {
          'directory_path': effectiveDir,
        });
        _log('INFO', '✅ directory_path已修正');
      } else {
        _log('INFO', '✅ directory_path一致性检查通过');
      }
    } else {
      _log('WARN', '⚠️ 无法读取刚写入的game.json进行验证');
    }
  }

  Future<void> _embedCoverBase64({
    required String targetDir,
    String? coverUrl,
  }) async {
    return;
  }

  Future<void> _cleanupOnFailure(String targetDir,
      [String? extractionTargetDir]) async {
    _log('WARN', '');
    _log('WARN', '========================================');
    _log('WARN', '开始失败回滚清理...');
    _log('WARN', '========================================');

    if (_currentProcess != null) {
      try {
        _log('INFO', '步骤1: 终止残留解压进程...');
        _currentProcess?.kill(ProcessSignal.sigterm);

        await Future.delayed(const Duration(milliseconds: 500));

        if (_currentProcess != null) {
          _currentProcess?.kill(ProcessSignal.sigkill);
          await Future.delayed(const Duration(milliseconds: 200));
        }

        _currentProcess = null;
        _log('INFO', '✅ 步骤1完成: 进程已终止');
      } catch (e) {
        _log('WARN', '⚠️ 步骤1警告: 终止进程时异常: $e');
        _currentProcess = null;
      }
    } else {
      _log('INFO', '步骤1: 无残留进程，跳过');
    }

    _log('INFO', '步骤2: 扫描并清理所有临时目录...');

    for (int i = 0; i < 10; i++) {
      final tempDirPattern = [
        '$targetDir._temp_layer_$i',
        '${targetDir}_temp_layer_$i',
      ];

      for (final pattern in tempDirPattern) {
        final tempDir = Directory(pattern);
        if (await tempDir.exists()) {
          try {
            final filesBefore = await tempDir.list().toList();
            await tempDir.delete(recursive: true);

            if (!await tempDir.exists()) {
              _log('INFO', '  ✅ 已清理: $pattern (${filesBefore.length}个条目)');
            } else {
              _log('WARN', '  ⚠️ 清理后仍存在: $pattern');
            }
          } catch (e) {
            _log('ERROR', '  ❌ 清理失败: $pattern | 错误: $e');
            try {
              await Future.delayed(const Duration(milliseconds: 300));
              await tempDir.delete(recursive: true);
              _log('INFO', '  ✅ 重试成功: $pattern');
            } catch (retryErr) {
              _log('ERROR', '  ❌ 重试也失败: $pattern | $retryErr');
            }
          }
        }
      }
    }
    _log('INFO', '✅ 步骤2完成: 临时目录清理结束');

    _log('INFO', '步骤3: 清理本任务自建的中间压缩包...');

    // ★ IMP-06（2026-09-12 导入审查）：只删除本任务登记过的中间压缩包。
    // 旧实现对目标目录顶层做"除当前压缩包外全删"，一旦该目录与用户目录重叠
    // （例如元数据目录恰好是用户的游戏文件夹），会连带删掉用户自己的压缩包。
    // 无法确认来源的一律保留（安全默认）。
    if (_taskOwnedTempArchives.isEmpty) {
      _log('INFO', '  ℹ️ 本任务无自建中间压缩包，跳过删除');
    } else {
      for (final archivePath in _taskOwnedTempArchives.toList()) {
        // 双保险：当前正在使用的源压缩包永不删除
        if (archivePath == _currentArchivePath) continue;
        final f = File(archivePath);
        if (!await f.exists()) continue;
        try {
          await f.delete();
          _log('INFO', '  ✅ 已删除本任务中间压缩包: $archivePath');
        } catch (delErr) {
          _log('WARN', '  ⚠️ 删除中间压缩包失败: $archivePath | $delErr');
        }
      }
      _taskOwnedTempArchives.clear();
    }
    _log('INFO', '✅ 步骤3完成: 中间压缩包清理结束');

    _log('INFO', '步骤4: 检查目标目录状态...');

    final target = Directory(targetDir);
    if (await target.exists()) {
      try {
        final entities = await target.list().toList();

        if (entities.isEmpty) {
          try {
            await target.delete();
            _log('INFO', '  ✅ 目标目录为空，已删除: $targetDir');
          } catch (delErr) {
            _log('WARN', '  ⚠️ 删除空目录失败: $targetDir | $delErr');
          }
        } else {
          final fileCount = entities.where((e) => e is File).length;
          final dirCount = entities.where((e) => e is Directory).length;
          _log('INFO', '  ℹ️ 目标目录非空，保留已解压内容: $targetDir');
          _log('INFO', '     包含: $fileCount 个文件, $dirCount 个子目录');

          final testFiles = entities.whereType<File>().take(3).toList();
          for (final f in testFiles) {
            _log('INFO', '     - ${f.path.split('\\').last}');
          }
          if (entities.length > 3) {
            _log('INFO', '     ... 还有 ${entities.length - 3} 个条目');
          }
        }
      } catch (checkErr) {
        _log('ERROR', '  ❌ 检查目标目录异常: $checkErr');
      }
    } else {
      _log('INFO', '  ℹ️ 目标目录不存在，无需清理');
    }
    _log('INFO', '✅ 步骤4完成: 目标目录检查结束');

    _log('INFO', '步骤5: 保留原始压缩包（失败回滚不删除）...');

    if (_currentArchivePath != null && _currentArchivePath!.isNotEmpty) {
      final archiveFile = File(_currentArchivePath!);
      if (await archiveFile.exists()) {
        final size = await archiveFile.length();
        _log('INFO',
            '  ℹ️ 保留原压缩包: $_currentArchivePath (${(size / 1024 / 1024).toStringAsFixed(2)}MB)');
        _log('INFO', '  ℹ️ 用户可手动删除或重新尝试安装');
      } else {
        _log('INFO', '  ℹ️ 原压缩包不存在: $_currentArchivePath');
      }
    } else {
      _log('INFO', '  ℹ️ 无原压缩包路径信息');
    }
    _log('INFO', '✅ 步骤5完成: 原始压缩包已保留');

    if (extractionTargetDir != null &&
        extractionTargetDir!.isNotEmpty &&
        extractionTargetDir != targetDir) {
      _log('INFO', '步骤6: 检查解压目标目录(自定义路径)...');

      final extractDir = Directory(extractionTargetDir!);
      if (await extractDir.exists()) {
        try {
          final entities = await extractDir.list().toList();

          if (entities.isEmpty) {
            try {
              await extractDir.delete();
              _log('INFO', '  ✅ 解压目录为空，已删除: $extractionTargetDir');
            } catch (delErr) {
              _log('WARN', '  ⚠️ 删除空解压目录失败: $extractionTargetDir | $delErr');
            }
          } else {
            // 递归检查目录中是否含有游戏数据文件
            // 之前的 bug：只检查顶层文件，不检查子目录，导致含子目录结构的游戏被误删
            bool hasGameData = false;
            try {
              // ★ P0-7：流式存在性检查（找到即中断，不物化全部条目）
              hasGameData = await FsScan.containsFile(
                extractDir,
                (name) =>
                    name.endsWith('.exe') ||
                    name.endsWith('.ctgame') ||
                    name.endsWith('.json') ||
                    name.endsWith('.dat') ||
                    name.endsWith('.xp3') ||
                    name.endsWith('.ks') ||
                    name.endsWith('.ald') ||
                    name.endsWith('.arc') ||
                    name.endsWith('.pna'),
              );
            } catch (scanErr) {
              _log('WARN', '  ⚠️ 递归扫描异常，保守保留: $scanErr');
              hasGameData = true; // 扫描失败时保守处理，不删除
            }

            final fileCount = entities.where((e) => e is File).length;
            final dirCount = entities.where((e) => e is Directory).length;
            _log('INFO', '  ℹ️ 解压目录非空: $extractionTargetDir');
            _log('INFO', '     顶层: $fileCount 个文件, $dirCount 个子目录');
            _log('INFO', '     含游戏数据: $hasGameData');

            // 只有完全空目录才删除；非空目录一律保留，避免误删已解压的游戏文件
            if (!hasGameData && entities.isEmpty) {
              try {
                await extractDir.delete(recursive: true);
                _log('INFO', '  ✅ 已清理空目录: $extractionTargetDir');
              } catch (delErr) {
                _log('WARN', '  ⚠️ 清理失败: $extractionTargetDir | $delErr');
              }
            } else {
              _log('INFO', '  ℹ️ 保留解压目录（含游戏数据或非空）: $extractionTargetDir');
            }
          }
        } catch (checkErr) {
          _log('ERROR', '  ❌ 检查解压目录异常: $extractionTargetDir | $checkErr');
        }
      }
      _log('INFO', '✅ 步骤6完成: 解压目录检查结束');
    }

    _log('INFO', '');
    _log('INFO', '========================================');
    _log('INFO', '✅ 失败回滚清理全部完成');
    _log('INFO', '========================================');
    _log('INFO', '');
  }

  void _handleError(String rawMsg) {
    if (_activeTaskCount > 0) _activeTaskCount--;
    _errorMessage = rawMsg;
    _emitStatus(ExtractStatus.failed);
  }

  void _log(String level, String message) {
    final timestamp = DateTime.now().toString().substring(0, 19);
    final logLine = '[$timestamp] [$level] [EXTRACT] $message';
    debugPrint(logLine);

    _persistLog(logLine);
  }

  Future<void> _persistLog(String line) async {
    try {
      final logDir = Directory(_logsDir);
      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }
      // 使用会话级时间戳:同一次解压任务内所有日志写入同一个文件,
      // 避免秒级时间戳生成多个 extract_*.txt 文件。
      _sessionLogTs ??= DateTime.now()
          .toIso8601String()
          .replaceAll(':', '-')
          .replaceAll('.', '-')
          .substring(0, 19);
      final logFile = File('$_logsDir/extract_$_sessionLogTs.txt');
      if (!await logFile.exists()) {
        await logFile.writeAsString('');
      }
      await logFile.writeAsString('$line\n', mode: FileMode.append);
    } catch (_) {}
  }

  void cancel() {
    if (_status == ExtractStatus.extracting) {
      _isCancelled = true;
      if (_activeTaskCount > 0) _activeTaskCount--;

      if (_currentProcess != null) {
        _currentProcess?.kill();
        _currentProcess = null;
      }

      // 修复:cancel 时调用 _cleanupOnFailure 清理残留文件。
      // 异步执行不阻塞 cancel(),_cleanupOnFailure 内部只调 _log() 不改状态,无竞态。
      if (_targetGameDir != null && _targetGameDir!.isNotEmpty) {
        _cleanupOnFailure(_targetGameDir!, _actualGameDir).catchError((e) {
          debugPrint('[EXTRACT] cancel 清理异常: $e');
        });
      }

      // 修复：取消后必须发出终态 failed，不能发 idle。
      // join_controller 的 _onExtractStatusChanged 只收敛 completed/failed，
      // join_page 的遮罩移除条件同样是 isProgressSuccess || isProgressFailed。
      // 发 idle 会让进度浮层永远等不到移除条件 → 添加页被黑遮罩永久锁死。
      // 不新增 cancelled 枚举值：global_task_manager 等处把 idle 当“可复用”状态判断，
      // 新增值会被多处分支误判。此处复用既有的 failed 分支自然收敛。
      _errorMessage = '已取消入库';
      _emitStatus(ExtractStatus.failed);
    }
  }

  void reset() {
    _status = ExtractStatus.idle;
    _progress = null;
    _errorMessage = null;
    _currentArchivePath = null;
    _targetGameDir = null;
    _actualGameDir = null;
    _currentProcess = null;
    _sessionLogTs = null;
  }
}
