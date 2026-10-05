import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_colors.dart';
import '../theme/app_styles.dart';
import '../services/archive_library_preference.dart';
import '../services/cloud_backup/cloud_backup_service.dart';
import '../services/cloud_backup/cloud_storage_provider.dart';
import '../services/game_archive_service.dart';
import '../services/game_storage_state_controller.dart';
import '../services/file_size_service.dart';
import '../services/local_game_registry.dart';
import '../services/save_manifest.dart';
import '../services/save_scanner.dart';
import 'app_snack_bar.dart';
import 'save_backup_panel.dart';

/// 「游戏数据」管理弹窗（方案 §7 Phase 2）。
///
/// ## 结构
///
/// - **Tab 1「游戏数据」**：当前存储状态卡片 + 封装 / 打包 / 解封 / 解包 +
///   归档列表（恢复 / 打开目录 / 删除）+ 归档保留份数。
/// - **Tab 2「存档备份」**：内嵌 [SaveBackupPanel]（原有「存档备份」功能原样保留）。
///
/// ## 一期边界（🔴 有意为之，非遗漏）
///
/// - **打包 / 解包** 不在此弹窗 —— 方案 §7 划归 Phase 3（涉及压缩 GB 级本体 +
///   删本体二次确认 + 回收站，破坏性最强）。本弹窗只做**只保存不删源**的封装/解封。
/// - **归档重命名** 未提供 —— 归档目录名即 id（`<时间戳>_<state>`），改名会让
///   `game.json.archive_dir` 指针失效，收益低风险高，方案 §7 列了但**建议不做**
///   （见 §16.6 记录）。
///
/// ## 与状态机的关系
///
/// 状态**只读** [GameStorageStateController.resolveVerified] 的结果（核实磁盘），
/// 不在卡片/列表中做磁盘探测。写状态一律走
/// [LocalGameRegistry.setStorageState]（原子写 + 失败回滚）。
class GameDataDialog extends StatefulWidget {
  final String gameName;
  final String installDir;
  final ManifestGame? manifestEntry;

  /// 🔴 稳定主键（2026-10-03 钥匙统一）：优先按它定位库条目（`_game`），
  /// 同名不同路径的条目只有它能唯一定位；空/缺省回退按 [gameName] 查。
  final String? gameId;

  const GameDataDialog({
    super.key,
    required this.gameName,
    required this.installDir,
    this.manifestEntry,
    this.gameId,
  });

  static void show(
    BuildContext context, {
    required String gameName,
    required String installDir,
    ManifestGame? manifestEntry,
    String? gameId,
  }) {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => GameDataDialog(
        gameName: gameName,
        installDir: installDir,
        manifestEntry: manifestEntry,
        gameId: gameId,
      ),
    );
  }

  @override
  State<GameDataDialog> createState() => _GameDataDialogState();
}

class _GameDataDialogState extends State<GameDataDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // ---- 状态 / 归档 ----
  bool _loading = true;
  GameStorageResolution? _resolution;
  List<ArchiveRecord> _archives = [];

  // ---- 长任务 ----
  bool _busy = false;
  String _busyLabel = '';
  String _phaseLabel = '';
  int _progress = 0;

  // ---- 提示 ----
  String? _statusMessage;
  bool _statusSuccess = false;

  // ---- 云端归档（Phase 5 二期：下载恢复入口）----
  List<CloudObject>? _cloudArchives;
  bool _cloudLoading = false;
  String? _cloudError;
  bool _cloudExpanded = false;

  /// 🔴 钥匙（2026-10-03 对齐 `20e1671`）：优先按 `game_id`（稳定主键）定位
  /// 库条目 —— 同名不同路径是合法场景，裸 title 无法唯一定位；无 id（历史
  /// 调用方 / 脏数据）才回退按 title 查。
  LibraryGame? get _game {
    final id = widget.gameId?.trim() ?? '';
    if (id.isNotEmpty) {
      final byId = LocalGameRegistry.instance.getGameById(id);
      if (byId != null) return byId;
    }
    return LocalGameRegistry.instance.getGameByTitle(widget.gameName);
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _bootstrap();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    // 归档库偏好：首帧前 load（幂等），避免先按默认值渲染再跳变
    await ArchiveLibraryPreference.instance.load();
    await _reload();
  }

  // ============================================================
  // 数据加载
  // ============================================================

  Future<void> _reload() async {
    final game = _game;
    if (game == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _resolution = null;
        _archives = const [];
      });
      return;
    }

    if (mounted) setState(() => _loading = true);

    GameStorageResolution? res;
    List<ArchiveRecord> list = const [];
    try {
      res = await GameStorageStateController.resolveVerified(
        storedStorageState: game.storageState,
        directoryPath: game.directoryPath,
        archiveDir: game.archiveDir,
      );
      list = await GameArchiveService.instance.listArchives(game);
    } catch (e) {
      debugPrint('[GAME-DATA] 加载失败: $e');
    }

    if (!mounted) return;
    setState(() {
      _resolution = res;
      _archives = list;
      _loading = false;
    });
  }

  // ============================================================
  // 主操作：封装 / 解封
  // ============================================================

  Future<void> _seal() async {
    final game = _game;
    if (game == null) {
      _snack('未找到该游戏的库记录', level: _Lvl.error);
      return;
    }

    final ok = await _confirm(
      title: '封装',
      message: '封装 = 把「游戏数据」压缩存入归档库，包括：\n'
          '· 软件侧游戏数据（元数据目录内的 appdata）\n'
          '· 已提取的游戏存档\n\n'
          '🔒 不会删除或改动游戏本体，也不会动元数据目录里的 .ctgame 标记；'
          '封装后可随时解封还原。\n\n'
          '点击「开始封装」后，会让你确认要打包哪些存档。',
      confirmLabel: '开始封装',
    );
    if (ok != true) return;

    // Q14 存档确认：自动检测可能扫错/漏扫，压缩前让用户过目勾选
    final savePaths = await _confirmSaveSelection();
    if (savePaths == null) return;

    _startBusy('正在封装');
    try {
      final result = await GameArchiveService.instance.seal(
        game: game,
        savePaths: savePaths,
        onProgress: _onProgress,
      );
      if (!mounted) return;

      if (!result.ok) {
        _finishBusy();
        _snack(
          result.cancelled ? '已取消' : '封装失败：${result.error ?? '未知错误'}',
          level: result.cancelled ? _Lvl.warning : _Lvl.error,
        );
        return;
      }

      final rec = result.record;
      if (rec != null) {
        await LocalGameRegistry.instance.setStorageState(
          game,
          storageState: rec.state,
          archiveDir: rec.archiveDir,
          archiveAt:
              rec.createdAt?.toIso8601String() ?? DateTime.now().toIso8601String(),
        );
      }

      // 按保留份数清理旧归档（归档库在应用目录之外时会被服务端护栏拒绝）
      await _pruneIfNeeded(game.title);

      if (!mounted) return;
      _finishBusy();
      final warn = result.warnings.isEmpty ? '' : '\n⚠️ ${result.warnings.join('\n⚠️ ')}';
      _snack('已封装，游戏数据已存入归档库$warn', level: _Lvl.success);
      await _reload();
    } catch (e) {
      if (!mounted) return;
      _finishBusy();
      _snack('封装失败：$e', level: _Lvl.error);
    }
  }

  Future<void> _unseal() async {
    final game = _game;
    if (game == null) {
      _snack('未找到该游戏的库记录', level: _Lvl.error);
      return;
    }

    // 🔴 解封 = 「重新定位本体 + 还原数据」（方案 §1.4）。本体不在就先别往下走，
    //    否则还原完把状态写成 normal，而本体仍缺失 —— 状态立刻自相矛盾。
    if (_resolution?.bodyExists != true) {
      _snack(
        '本体目录不存在，请先在详情窗口「更换游戏目录」重新定位游戏本体，再解封',
        level: _Lvl.warning,
      );
      return;
    }

    final rec = _activeRecord();
    if (rec == null) {
      _snack('未找到可用的归档（归档可能已被删除）', level: _Lvl.error);
      return;
    }

    final ok = await _confirm(
      title: '解封',
      message: '将把归档「${rec.id}」里的游戏数据与存档还原回原位，'
          '并把存储状态改回「正常」。',
      confirmLabel: '确认解封',
    );
    if (ok != true) return;

    // 🔴 Q13：目标位置已有存档时询问替换（旧档先进回收站），不再静默覆盖
    final replaceOld = await _resolveRestoreConflicts(rec);
    if (replaceOld == null) return;

    _startBusy('正在解封');
    try {
      final r1 = await GameArchiveService.instance.restoreAppData(
        record: rec,
        targetDir: game.metaDataDir,
        onProgress: (pct) => _onProgress(
          ArchiveProgress(phase: ArchivePhase.restore, percent: pct),
        ),
      );
      if (!mounted) return;
      if (!r1.ok) {
        _finishBusy();
        _snack('解封失败：${r1.error ?? '未知错误'}', level: _Lvl.error);
        return;
      }

      final r2 = await GameArchiveService.instance.restoreSaves(
        record: rec,
        replaceOld: replaceOld,
      );

      await LocalGameRegistry.instance.setStorageState(
        game,
        storageState: 'normal',
        archiveDir: '',
        archiveAt: '',
      );

      if (!mounted) return;
      _finishBusy();
      final warns = <String>[...r1.warnings, ...r2.warnings];
      if (!r2.ok) {
        warns.add('存档还原未完全成功：${r2.error ?? '未知错误'}');
      }
      warns.addAll(r2.failures.map((f) => '存档恢复失败：$f'));
      _snack(
        warns.isEmpty ? '已解封，状态回到「正常」' : '已解封\n⚠️ ${warns.join('\n⚠️ ')}',
        level: warns.isEmpty ? _Lvl.success : _Lvl.warning,
      );
      await _reload();
    } catch (e) {
      if (!mounted) return;
      _finishBusy();
      _snack('解封失败：$e', level: _Lvl.error);
    }
  }

  // ============================================================
  // 主操作：打包 / 解包（Phase 3）
  // ============================================================

  /// 打包 = 归档游戏数据 + 压缩本体；可选把本体移入回收站（Q3 复选框默认不选）。
  Future<void> _pack() async {
    final game = _game;
    if (game == null) {
      _snack('未找到该游戏的库记录', level: _Lvl.error);
      return;
    }
    final bodyDir = game.directoryPath;
    if (bodyDir.isEmpty) {
      _snack('本体目录为空，无法打包', level: _Lvl.error);
      return;
    }

    // null = 取消；true = 打包并删本体；false = 仅打包（本体保留）
    final removeBody = await _confirmPack(bodyDir: bodyDir);
    if (removeBody == null) return;

    // Q14 存档确认：压缩 GB 级本体之前先让用户确认存档清单
    final savePaths = await _confirmSaveSelection();
    if (savePaths == null) return;

    _startBusy(removeBody ? '正在打包（完成后移本体入回收站）' : '正在打包');
    try {
      final result = await GameArchiveService.instance.pack(
        game: game,
        removeBody: removeBody,
        savePaths: savePaths,
        onProgress: _onProgress,
      );
      if (!mounted) return;
      if (!result.ok) {
        _finishBusy();
        _snack(
          result.cancelled ? '已取消' : '打包失败：${result.error ?? '未知错误'}',
          level: result.cancelled ? _Lvl.warning : _Lvl.error,
        );
        return;
      }

      final rec = result.record;
      if (rec != null) {
        await LocalGameRegistry.instance.setStorageState(
          game,
          storageState: rec.state,
          archiveDir: rec.archiveDir,
          archiveAt:
              rec.createdAt?.toIso8601String() ?? DateTime.now().toIso8601String(),
        );
      }

      // 按保留份数清理旧归档（外部归档库会被护栏拒绝，_pruneIfNeeded 内有提示）
      await _pruneIfNeeded(game.title);

      if (!mounted) return;
      _finishBusy();
      final warns = <String>[...result.warnings];
      String msg;
      if (removeBody && !result.bodyRemoved) {
        msg = '已打包，但本体删除未成功（本体仍在原位）';
      } else if (removeBody) {
        msg = '已打包，本体已移入回收站';
      } else {
        msg = '已打包（本体保留在原位）';
      }
      _snack(
        warns.isEmpty ? msg : '$msg\n⚠️ ${warns.join('\n⚠️ ')}',
        level: warns.isEmpty ? _Lvl.success : _Lvl.warning,
      );
      await _reload();
    } catch (e) {
      if (!mounted) return;
      _finishBusy();
      _snack('打包失败：$e', level: _Lvl.error);
    }
  }

  // ============================================================
  // Q14 存档确认（方案 §23.1）
  // ============================================================

  /// 扫描该游戏的候选存档（自动检测；自定义路径由 [_loadPanelCustomPaths]
  /// 读取后由调用方合并，与存档备份面板行为一致）。
  List<DetectedSaveFile> _scanSaveCandidates() {
    try {
      return SaveScanner()
          .detectSavePaths(widget.gameName, widget.installDir);
    } catch (_) {
      return const [];
    }
  }

  /// 读取存档备份面板保存的自定义路径（prefs 键与面板一致）。
  Future<List<String>> _loadPanelCustomPaths() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList('save_custom_paths_${widget.gameName}') ??
          const [];
    } catch (_) {
      return const [];
    }
  }

  /// 存档确认框（封装/打包压缩前调用）。
  ///
  /// 返回：`null` = 取消；`List<String>` = 确认的路径清单（可为空 = 明确不含存档）。
  /// 默认全选（保持「检测到就压」的现状语义），用户可勾选/添加/删除。
  Future<List<String>?> _confirmSaveSelection() async {
    final detected = _scanSaveCandidates();
    final customPaths = await _loadPanelCustomPaths();
    if (customPaths.isNotEmpty) {
      try {
        final extra = SaveScanner()
            .scanCustomPaths(customPaths, widget.installDir);
        final known = detected.map((f) => f.filePath).toSet();
        for (final f in extra) {
          if (!known.contains(f.filePath)) detected.add(f);
        }
      } catch (_) {}
    }

    final selected = detected.map((f) => f.filePath).toSet();
    final addController = TextEditingController();

    return showDialog<List<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          backgroundColor: AppColors.background,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: AppColors.border, width: 2),
          ),
          title: Text('确认存档',
              style: TextStyle(
                  fontSize: 20, letterSpacing: 1.2, color: AppColors.border)),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '以下是从常见位置自动检测到的存档，请确认是否是你要备份的存档。'
                  '可以勾选 / 取消，或手动添加真实存档路径。',
                  style: TextStyle(
                      fontSize: 13, color: AppColors.primaryText, height: 1.5),
                ),
                const SizedBox(height: 8),
                Container(
                  constraints: const BoxConstraints(maxHeight: 280),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.border),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: detected.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            '未自动检测到存档。如果你的游戏存档在特殊位置，'
                            '请在下方手动添加路径。',
                            style: TextStyle(
                                fontSize: 12,
                                color: AppColors.secondaryText,
                                height: 1.5),
                          ),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: detected.length,
                          itemBuilder: (ctx, i) {
                            final f = detected[i];
                            final checked = selected.contains(f.filePath);
                            final badge = f.tag == 'save'
                                ? '存档'
                                : f.tag == 'user'
                                    ? '手动'
                                    : '配置';
                            return CheckboxListTile(
                              dense: true,
                              value: checked,
                              controlAffinity:
                                  ListTileControlAffinity.leading,
                              title: Text(
                                f.filePath,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: AppColors.primaryText,
                                  fontFamily: 'monospace',
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                '$badge · ${f.isDirectory ? "目录" : FileSizePrefetchService.formatBytes(f.size)}',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: AppColors.secondaryText),
                              ),
                              onChanged: (v) => setDlg(() => v == true
                                  ? selected.add(f.filePath)
                                  : selected.remove(f.filePath)),
                            );
                          },
                        ),
                ),
                if (selected.isEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    '未勾选任何条目 = 本次归档将不包含存档。',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.dangerRed, height: 1.4),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: addController,
                        style: TextStyle(
                            fontSize: 12, color: AppColors.primaryText),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: '添加存档文件或目录的完整路径',
                          hintStyle: TextStyle(
                              fontSize: 11.5,
                              color: AppColors.secondaryText),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(6)),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () {
                        final t = addController.text.trim();
                        if (t.isEmpty) return;
                        final tType = FileSystemEntity.typeSync(t);
                        if (tType == FileSystemEntityType.notFound) {
                          _snack('路径不存在：$t', level: _Lvl.warning);
                          return;
                        }
                        if (detected.any((f) => f.filePath == t)) {
                          _snack('该路径已在列表中', level: _Lvl.info);
                          return;
                        }
                        setDlg(() {
                          selected.add(t);
                          detected.add(DetectedSaveFile(
                            filePath: t,
                            size: 0,
                            lastModified: DateTime.now(),
                            isDirectory: tType ==
                                FileSystemEntityType.directory,
                            tag: 'user',
                          ));
                          addController.clear();
                        });
                      },
                      child: const Text('添加'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('取消'),
            ),
            ElevatedButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(selected.toList()),
              child: Text(
                '确认并继续（已选 ${selected.length} 项）',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 打包确认框。返回：`null` = 取消；`true` = 打包并移本体入回收站；`false` = 仅打包。
  ///
  /// 🔴 Q3 决策：「移入回收站」复选框**默认不预选**，强制主动勾选；
  /// 勾选后确认按钮变警示色，并展开明示绝对路径的后果说明。
  Future<bool?> _confirmPack({required String bodyDir}) {
    var removeBody = false;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          backgroundColor: AppColors.background,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: AppColors.border, width: 2),
          ),
          title: Text('打包',
              style: TextStyle(
                  fontSize: 20, letterSpacing: 1.2, color: AppColors.border)),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '将把「游戏数据 + 存档 + 游戏本体」压缩归档到归档库。'
                  'GB 级本体压缩较慢（约 5–20 MB/s），请耐心等待。',
                  style: TextStyle(
                      fontSize: 14, color: AppColors.primaryText, height: 1.6),
                ),
                const SizedBox(height: 10),
                Text('本体目录：',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.secondaryText)),
                Text(
                  bodyDir,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.primaryText,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 10),
                InkWell(
                  onTap: () => setDlg(() => removeBody = !removeBody),
                  borderRadius: BorderRadius.circular(4),
                  child: Row(
                    children: [
                      Checkbox(
                        value: removeBody,
                        onChanged: (v) => setDlg(() => removeBody = v ?? false),
                      ),
                      Expanded(
                        child: Text(
                          '打包完成后把本体目录移入回收站（可还原）',
                          style: TextStyle(
                              fontSize: 13, color: AppColors.primaryText),
                        ),
                      ),
                    ],
                  ),
                ),
                if (removeBody) ...[
                  const SizedBox(height: 4),
                  Text(
                    '⚠️ 归档校验通过后，才会把上面明示的目录整个移入回收站；'
                    '移入失败时本体保留在原位，不影响归档结果。',
                    style: TextStyle(
                        fontSize: 12, color: AppColors.dangerRed, height: 1.5),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: Text('取消',
                  style: TextStyle(
                      color: AppColors.secondaryText,
                      fontWeight: FontWeight.w600)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(removeBody),
              child: Text('开始打包',
                  style: TextStyle(
                      color: removeBody
                          ? AppColors.dangerRed
                          : AppColors.selectedAccent,
                      fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
  }

  /// 解包 = 从打包态归档把本体解回原目录（Q4：一期只解回 original_dir）。
  Future<void> _unpack() async {
    final game = _game;
    if (game == null) {
      _snack('未找到该游戏的库记录', level: _Lvl.error);
      return;
    }
    final rec = _activeRecord();
    if (rec == null) {
      _snack('未找到可用的归档（归档可能已被删除）', level: _Lvl.error);
      return;
    }
    final body = rec.manifest.body;
    if (body == null || body.originalDir.isEmpty) {
      _snack('该归档未记录原始本体目录，无法解包', level: _Lvl.error);
      return;
    }

    // 🔴 ADR-007：确认框明示解压目标的真实绝对路径与空间需求
    final ok = await _confirm(
      title: '解包',
      message: '将把本体从归档解压回原目录（目标已存在时会被拒绝，不覆盖）：\n\n'
          '${body.originalDir}\n\n'
          '需要约 ${_formatSize(body.unpackedBytes)} 磁盘空间，'
          '完成后存储状态回到「正常」。',
      confirmLabel: '确认解包',
    );
    if (ok != true) return;

    _startBusy('正在解包');
    try {
      final result = await GameArchiveService.instance.unpack(
        record: rec,
        onProgress: (pct) => _onProgress(
          ArchiveProgress(phase: ArchivePhase.restore, percent: pct),
        ),
      );
      if (!mounted) return;
      if (!result.ok) {
        _finishBusy();
        _snack(
          result.cancelled ? '已取消' : '解包失败：${result.error ?? '未知错误'}',
          level: result.cancelled ? _Lvl.warning : _Lvl.error,
        );
        return;
      }

      await LocalGameRegistry.instance.setStorageState(
        game,
        storageState: 'normal',
        archiveDir: '',
        archiveAt: '',
      );

      if (!mounted) return;
      _finishBusy();
      final warns = result.warnings;
      _snack(
        warns.isEmpty ? '已解包，状态回到「正常」' : '已解包\n⚠️ ${warns.join('\n⚠️ ')}',
        level: warns.isEmpty ? _Lvl.success : _Lvl.warning,
      );
      await _reload();
    } catch (e) {
      if (!mounted) return;
      _finishBusy();
      _snack('解包失败：$e', level: _Lvl.error);
    }
  }

  // ============================================================
  // Phase 5 云备份：上传（方案 §7，手动触发）
  // ============================================================

  /// 把归档上传到云端（WebDAV，手动触发）。
  ///
  /// 上传是加法操作（不动本地），无确认框；未配置云备份时引导去设置页。
  /// 复用弹窗全局 busy + 进度条（phase 用 preparing，message 注明云端）。
  Future<void> _uploadToCloud(ArchiveRecord rec) async {
    final game = _game;
    if (game == null) return;

    final cfg = await CloudBackupService.instance.loadConfig();
    if (!mounted) return;
    if (!cfg.enabled) {
      _snack('请先在「设置 → 云备份」中启用并配置 WebDAV', level: _Lvl.warning);
      return;
    }
    final gameId = game.gameId.trim();
    if (gameId.isEmpty) {
      _snack('该条目缺少稳定主键（game_id），无法上传云端', level: _Lvl.error);
      return;
    }

    _startBusy('正在上传云端');
    try {
      final result = await CloudBackupService.instance.uploadArchive(
        gameId: gameId,
        archiveDir: rec.archiveDir,
        config: cfg,
        onProgress: (pct) => _onProgress(ArchiveProgress(
            phase: ArchivePhase.preparing, percent: pct, message: '正在上传云端')),
      );
      if (!mounted) return;
      _finishBusy();
      if (!result.ok) {
        _snack('上传失败：${result.error ?? '未知错误'}', level: _Lvl.error);
        return;
      }
      final warn = result.warnings.isEmpty
          ? ''
          : '\n⚠️ ${result.warnings.join('\n⚠️ ')}';
      _snack('已上传云端$warn', level: _Lvl.success);
    } catch (e) {
      if (!mounted) return;
      _finishBusy();
      _snack('上传异常：$e', level: _Lvl.error);
    }
  }

  // ============================================================
  // 云端归档（Phase 5 二期：下载恢复入口，落点拍板 = 游戏数据弹窗）
  // ============================================================

  /// 云端钥匙与本地归档库同构 = game_id（Q12 口径）。
  String? get _cloudGameId {
    final id = _game?.gameId.trim() ?? '';
    return id.isEmpty ? null : id;
  }

  Future<void> _loadCloudArchives() async {
    final gameId = _cloudGameId;
    if (gameId == null) return;
    setState(() {
      _cloudLoading = true;
      _cloudError = null;
    });
    try {
      final config = await CloudBackupService.instance.loadConfig();
      if (!config.enabled) {
        if (!mounted) return;
        setState(() {
          _cloudLoading = false;
          _cloudError = null;
          _cloudArchives = null;
        });
        return;
      }
      final list = await CloudBackupService.instance
          .listCloudArchives(config, gameId);
      if (!mounted) return;
      setState(() {
        _cloudArchives = list;
        _cloudLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _cloudLoading = false;
        _cloudError = '$e';
      });
    }
  }

  Future<void> _downloadCloudArchive(CloudObject dir) async {
    final game = _game;
    final gameId = _cloudGameId;
    if (game == null || gameId == null || _busy) return;

    _startBusy('正在从云端恢复');
    _onProgress(ArchiveProgress(
      phase: ArchivePhase.preparing,
      percent: 0,
      message: '正在从云端下载',
    ));
    try {
      final config = await CloudBackupService.instance.loadConfig();
      final r = await CloudBackupService.instance.downloadArchive(
        gameId: gameId,
        archiveId: dir.name,
        config: config,
        onProgress: (p) => _onProgress(ArchiveProgress(
          phase: ArchivePhase.restore,
          percent: p,
          message: '正在从云端恢复归档',
        )),
      );
      if (!mounted) return;
      _finishBusy();
      if (r.ok) {
        _snack('已从云端恢复到本地归档库', level: _Lvl.success);
        await _reload();
        await _loadCloudArchives();
      } else {
        _snack('恢复失败：${r.error ?? '未知错误'}', level: _Lvl.error);
      }
    } catch (e) {
      if (!mounted) return;
      _finishBusy();
      _snack('恢复异常：$e', level: _Lvl.error);
    }
  }

  Future<void> _deleteCloudArchive(CloudObject dir) async {
    final gameId = _cloudGameId;
    if (gameId == null || _busy) return;
    final ok = await _confirm(
      title: '删除云端归档',
      message: '将删除云端「${dir.name}」。\n\n'
          '⚠️ 本地归档不受影响，但删除后无法从云端找回。',
      confirmLabel: '删除',
    );
    if (ok != true) return;
    _startBusy('正在删除云端归档');
    try {
      final config = await CloudBackupService.instance.loadConfig();
      await CloudBackupService.instance.deleteCloudArchive(
          config, gameId, dir.name);
      if (!mounted) return;
      _finishBusy();
      _snack('云端归档已删除', level: _Lvl.success);
      await _loadCloudArchives();
    } catch (e) {
      if (!mounted) return;
      _finishBusy();
      _snack('删除失败：$e', level: _Lvl.error);
    }
  }

  /// 云端归档时间可读化：id 前缀 `游戏名_yyyy-MM-dd_HH-mm-ss_state` → 日期段。
  String _cloudArchiveTimeLabel(String name) {
    final m = RegExp(r'(\d{4}-\d{2}-\d{2})_(\d{2}-\d{2}-\d{2})_(\w+)$')
        .firstMatch(name);
    if (m == null) return name;
    final state = m.group(3)!;
    final stateLabel = switch (state) {
      'sealed' => '封装',
      'packed' => '打包',
      _ => state,
    };
    return '${m.group(1)} ${m.group(2)!.replaceAll('-', ':')} · $stateLabel';
  }

  Widget _buildCloudSection() {
    final gameId = _cloudGameId;
    return _card(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(bottom: 8),
          initiallyExpanded: false,
          onExpansionChanged: (v) {
            setState(() => _cloudExpanded = v);
            if (v && _cloudArchives == null && !_cloudLoading) {
              _loadCloudArchives();
            }
          },
          iconColor: AppColors.secondaryText,
          collapsedIconColor: AppColors.secondaryText,
          title: Text(
            '云端归档',
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: AppColors.primaryText,
            ),
          ),
          subtitle: Text(
            gameId == null
                ? '该游戏缺少稳定标识（game_id），无法使用云端备份'
                : '从云备份下载归档到本地（需先在设置中启用云备份）',
            style: TextStyle(fontSize: 11.5, color: AppColors.secondaryText),
          ),
          children: _buildCloudChildren(gameId),
        ),
      ),
    );
  }

  List<Widget> _buildCloudChildren(String? gameId) {
    if (gameId == null) {
      return [
        Text('该游戏缺少 game_id，无法定位云端归档。',
            style: TextStyle(fontSize: 12.5, color: AppColors.secondaryText)),
      ];
    }
    if (_cloudLoading) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      ];
    }
    if (_cloudError != null) {
      return [
        Text('云端不可达：$_cloudError',
            style: TextStyle(fontSize: 12.5, color: AppColors.dangerRed)),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _loadCloudArchives,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('重试'),
          ),
        ),
      ];
    }
    if (_cloudArchives == null) {
      return [
        Text('展开时自动加载…',
            style: TextStyle(fontSize: 12.5, color: AppColors.secondaryText)),
      ];
    }
    final dirs = _cloudArchives!.where((o) => o.isDir).toList()
      ..sort((a, b) => b.name.compareTo(a.name)); // 新→旧
    if (dirs.isEmpty) {
      return [
        Text('云端暂无该游戏的归档。可在下方归档列表点「上传云端」。',
            style: TextStyle(fontSize: 12.5, color: AppColors.secondaryText)),
      ];
    }
    return [
      for (final d in dirs)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _cloudArchiveTimeLabel(d.name),
                      style: TextStyle(
                          fontSize: 12.5, color: AppColors.primaryText),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      d.name,
                      style: TextStyle(
                          fontSize: 11, color: AppColors.secondaryText),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              _smallAction(
                icon: Icons.download,
                label: '下载',
                onTap: _busy ? null : () => _downloadCloudArchive(d),
              ),
              const SizedBox(width: 4),
              _smallAction(
                icon: Icons.delete_outline,
                label: '删除',
                onTap: _busy ? null : () => _deleteCloudArchive(d),
              ),
            ],
          ),
        ),
    ];
  }

  /// 从指定归档恢复「游戏数据 + 存档」（不改变存储状态，仅供取回数据）。
  Future<void> _restoreFrom(ArchiveRecord rec) async {
    final game = _game;
    if (game == null) return;

    final ok = await _confirm(
      title: '从归档恢复',
      message: '将把归档「${rec.id}」里的游戏数据与存档还原回原位。\n\n'
          '还原目标已有同名文件时会先询问是否替换（存储状态不变）。',
      confirmLabel: '确认恢复',
    );
    if (ok != true) return;

    // 🔴 Q13：目标位置已有存档时询问替换（旧档先进回收站），不再静默覆盖
    final replaceOld = await _resolveRestoreConflicts(rec);
    if (replaceOld == null) return;

    _startBusy('正在恢复');
    try {
      final r1 = await GameArchiveService.instance.restoreAppData(
        record: rec,
        targetDir: game.metaDataDir,
      );
      if (!mounted) return;
      if (!r1.ok) {
        _finishBusy();
        _snack('恢复失败：${r1.error ?? '未知错误'}', level: _Lvl.error);
        return;
      }
      final r2 = await GameArchiveService.instance.restoreSaves(
        record: rec,
        replaceOld: replaceOld,
      );
      if (!mounted) return;
      _finishBusy();
      final warns = <String>[...r1.warnings, ...r2.warnings, ...r2.failures];
      _snack(
        warns.isEmpty ? '已从归档恢复' : '已恢复\n⚠️ ${warns.join('\n⚠️ ')}',
        level: warns.isEmpty ? _Lvl.success : _Lvl.warning,
      );
    } catch (e) {
      if (!mounted) return;
      _finishBusy();
      _snack('恢复失败：$e', level: _Lvl.error);
    }
  }

  Future<void> _deleteArchive(ArchiveRecord rec) async {
    // 🔴 ADR-007：确认框必须明示**真实绝对路径**
    final ok = await _confirm(
      title: '删除归档',
      message: '将永久删除以下归档目录（含其全部 .7z 分片）：\n\n'
          '${rec.archiveDir}\n\n'
          '⚠️ 此操作不可撤销（不会进回收站）。游戏本体与元数据目录不受影响。',
      confirmLabel: '删除',
      danger: true,
    );
    if (ok != true) return;

    final done = await GameArchiveService.instance.deleteArchive(
      rec,
      // 用户在确认框里已明示同意删除该绝对路径
      allowOutsideAppStorage: true,
    );
    if (!mounted) return;
    if (done) {
      _snack('已删除归档', level: _Lvl.success);
      await _reload();
    } else {
      _snack('删除失败（可能路径越界或文件被占用）', level: _Lvl.error);
    }
  }

  Future<void> _pruneIfNeeded(String title) async {
    final game = _game;
    if (game == null) return; // 无库记录无法按身份定位归档根
    final keep = ArchiveLibraryPreference.instance.retention;
    try {
      final before = await GameArchiveService.instance.listArchives(game);
      if (before.length <= keep) return;
      final removed =
          await GameArchiveService.instance.pruneArchives(game, keep: keep);
      if (!mounted) return;
      if (removed == 0) {
        // 归档库位于应用目录之外 → 服务端护栏拒绝自动清理
        _snack(
          '归档已达 ${before.length} 份，但归档库在应用目录之外，已跳过自动清理'
          '（可在归档列表中手动删除）',
          level: _Lvl.warning,
        );
      } else {
        _snack('已按保留份数清理 $removed 份旧归档', level: _Lvl.info);
      }
    } catch (e) {
      debugPrint('[GAME-DATA] 清理旧归档失败: $e');
    }
  }

  // ============================================================
  // 长任务状态
  // ============================================================

  void _startBusy(String label) {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _busyLabel = label;
      _phaseLabel = '';
      _progress = 0;
      _statusMessage = null;
    });
  }

  void _onProgress(ArchiveProgress p) {
    if (!mounted) return;
    setState(() {
      _phaseLabel = p.message.isEmpty ? p.phase.label : p.message;
      _progress = p.percent;
    });
  }

  void _finishBusy() {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _busyLabel = '';
      _phaseLabel = '';
      _progress = 0;
    });
  }

  /// 当前生效的归档：优先 `game.json.archive_dir`，否则用最新一份。
  ArchiveRecord? _activeRecord() {
    final game = _game;
    if (game != null && game.archiveDir.isNotEmpty) {
      for (final r in _archives) {
        if (r.archiveDir == game.archiveDir) return r;
      }
    }
    return _archives.isEmpty ? null : _archives.first;
  }

  // ============================================================
  // 工具
  // ============================================================

  void _snack(String msg, {_Lvl level = _Lvl.info}) {
    if (!mounted) return;
    switch (level) {
      case _Lvl.success:
        AppSnackBar.success(context, msg);
        break;
      case _Lvl.warning:
        AppSnackBar.warning(context, msg);
        break;
      case _Lvl.error:
        AppSnackBar.error(context, msg);
        break;
      case _Lvl.info:
        AppSnackBar.info(context, msg);
        break;
    }
    setState(() {
      _statusMessage = msg;
      _statusSuccess = level == _Lvl.success;
    });
  }

  /// 🔴 Q13：解封/恢复前的存档冲突预检。
  ///
  /// 返回 `null` = 用户取消（中止操作）；`true` = 有冲突且用户确认「替换」
  /// （旧档先移入回收站）；`false` = 无冲突，直接还原。
  Future<bool?> _resolveRestoreConflicts(ArchiveRecord rec) async {
    final conflicts =
        await GameArchiveService.instance.checkRestoreConflicts(record: rec);
    if (conflicts.isEmpty) return false;
    final preview = conflicts.take(5).join('\n');
    final more = conflicts.length > 5 ? '\n…等共 ${conflicts.length} 处' : '';
    final ok = await _confirm(
      title: '发现现有存档',
      message: '还原目标位置已有 ${conflicts.length} 处现有文件：\n\n'
          '$preview$more\n\n'
          '用归档中的存档替换它们？旧文件会先移入回收站（可找回）。\n'
          '选择「取消」则不执行本次操作。',
      confirmLabel: '替换并继续',
      danger: true,
    );
    if (ok != true) return null;
    return true;
  }

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    bool danger = false,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.background,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: AppColors.border, width: 2),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontSize: 20,
            letterSpacing: 1.2,
            color: AppColors.border,
          ),
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Text(
            message,
            style: TextStyle(
              fontSize: 14,
              color: AppColors.primaryText,
              height: 1.6,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text('取消',
                style: TextStyle(
                    color: AppColors.secondaryText,
                    fontWeight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(confirmLabel,
                style: TextStyle(
                    color:
                        danger ? AppColors.dangerRed : AppColors.selectedAccent,
                    fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1073741824) {
      return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  }

  String _formatDate(DateTime? dt) {
    if (dt == null) return '—';
    final y = dt.year.toString();
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min';
  }

  Future<void> _openFolder(String path) async {
    if (path.isEmpty) return;
    try {
      if (!await Directory(path).exists()) {
        if (!mounted) return;
        _snack('目录不存在：$path', level: _Lvl.warning);
        return;
      }
      await Process.start('explorer', [path]);
    } catch (e) {
      if (!mounted) return;
      _snack('打开目录失败：$e', level: _Lvl.error);
    }
  }

  // ============================================================
  // 构建
  // ============================================================

  @override
  Widget build(BuildContext context) {
    // 窄窗口（960×540）安全：尺寸随可用空间收缩，绝不溢出（方案 §11.1 #12）
    final screen = MediaQuery.of(context).size;
    final w = (screen.width - 48).clamp(360.0, 640.0);
    final h = (screen.height - 48).clamp(360.0, 680.0);

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: AppColors.background,
            borderRadius: BorderRadius.circular(AppRadius.xl),
            border: Border.all(color: AppColors.border, width: 2),
            boxShadow: [
              BoxShadow(
                color: AppColors.shadowColor,
                offset: const Offset(4, 5),
                blurRadius: 0,
              ),
            ],
          ),
          clipBehavior: Clip.hardEdge,
          child: Column(
            children: [
              _buildHeader(),
              _buildTabBar(),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildGameDataTab(),
                    SaveBackupPanel(
                      gameName: widget.gameName,
                      installDir: widget.installDir,
                      manifestEntry: widget.manifestEntry,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      height: 56,
      decoration: BoxDecoration(
        color: AppColors.background,
        border: Border(
          bottom: BorderSide(color: AppColors.border, width: 1.6),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          Icon(Icons.inventory_2_outlined, size: 22, color: AppColors.border),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '游戏数据 — ${widget.gameName}',
              style: TextStyle(
                fontSize: 22,
                letterSpacing: 1.5,
                color: AppColors.primaryText,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  border: Border.all(
                      color: AppColors.border.withOpacity(0.6), width: 1.4),
                  borderRadius: BorderRadius.circular(5),
                ),
                alignment: Alignment.center,
                child:
                    Icon(Icons.close, size: 15, color: AppColors.secondaryText),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      width: double.infinity,
      height: 44,
      color: AppColors.sidebarBackground,
      child: TabBar(
        controller: _tabController,
        labelColor: AppColors.primaryText,
        unselectedLabelColor: AppColors.secondaryText,
        labelStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        unselectedLabelStyle:
            const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
        indicatorColor: AppColors.selectedAccent,
        indicatorWeight: 2.4,
        indicatorSize: TabBarIndicatorSize.tab,
        dividerColor: AppColors.borderLight,
        tabs: const [
          Tab(text: '游戏数据'),
          Tab(text: '存档备份'),
        ],
      ),
    );
  }

  // ============================================================
  // Tab 1 · 游戏数据
  // ============================================================

  // ============================================================
  // Q16 使用说明（可展开，默认收起）
  // ============================================================

  Widget _buildGuideSection() {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Theme(
        data: Theme.of(context)
            .copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: false,
          tilePadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          childrenPadding:
              const EdgeInsets.fromLTRB(14, 0, 14, 12),
          iconColor: AppColors.secondaryText,
          collapsedIconColor: AppColors.secondaryText,
          title: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.help_outline,
                  size: 17, color: AppColors.border),
              const SizedBox(width: 6),
              Text(
                '使用说明（第一次用先看这里）',
                style: TextStyle(
                    fontSize: 13.5,
                    letterSpacing: 0.5,
                    color: AppColors.primaryText),
              ),
            ],
          ),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _guideTitle('这套功能是干什么的'),
                  _guideText(
                    '这里管理游戏的「存储状态」，共四种：'
                    '正常 / 封装 / 打包 / 仅展示。',
                  ),
                  _guideBullet('封装',
                      '把「游戏数据」（软件侧数据 + 提取的存档）压缩进'
                      '归档库，本体不动。适合暂时不玩、想给硬盘减负，'
                      '之后可能回来接着玩。'),
                  _guideBullet('打包',
                      '在封装基础上连游戏本体也一起压缩，可选把原本体'
                      '目录移入回收站。适合长期不玩或搬迁游戏。'),
                  _guideBullet('解封 / 解包',
                      '把归档还原回原位，游戏回到封装/打包前的状态。'
                      '解封还原存档时，若目标位置已有新档会先询问是否'
                      '替换（旧档先进回收站，可找回）。'),
                  _guideBullet('归档列表',
                      '管理已生成的归档（恢复 / 打开目录 / 删除），'
                      '并按下方「保留份数」自动清理最旧的。'),
                  const SizedBox(height: 8),
                  _guideTitle('存档确认'),
                  _guideText(
                    '封装/打包压缩前会弹出「确认存档」：列表来自自动'
                    '检测 + 你在「存档备份 → 存档路径」里添加的自定义'
                    '路径。请核对是不是你要的存档，可勾选 / 取消 / 手动'
                    '添加真实路径；全部不勾 = 本次归档不含存档。',
                  ),
                  const SizedBox(height: 8),
                  _guideTitle('和「存档备份」的区别'),
                  _guideText(
                    '「存档备份」（第二个标签页）只备份存档，随时可手动'
                    '做、不改存储状态；「封装/打包」是整体收纳（游戏数据'
                    ' + 存档 + 可选本体）并改变存储状态。',
                  ),
                  const SizedBox(height: 8),
                  _guideTitle('建议'),
                  _guideText(
                    '第一次使用先「封装」走一遍全流程（封装 → 解封），'
                    '确认存档被正确识别后再用「打包」。',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _guideTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          '· $text',
          style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600,
              color: AppColors.primaryText),
        ),
      );

  Widget _guideText(String text) => Text(
        text,
        style: TextStyle(
            fontSize: 12.5,
            height: 1.55,
            color: AppColors.secondaryText),
      );

  Widget _guideBullet(String term, String desc) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text.rich(
          TextSpan(
            style: TextStyle(
                fontSize: 12.5,
                height: 1.55,
                color: AppColors.secondaryText),
            children: [
              TextSpan(
                text: '$term：',
                style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppColors.primaryText),
              ),
              TextSpan(text: desc),
            ],
          ),
        ),
      );

  Widget _buildGameDataTab() {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                valueColor: AlwaysStoppedAnimation<Color>(AppColors.border),
              ),
            ),
            const SizedBox(height: 10),
            Text('加载中...',
                style: TextStyle(fontSize: 14, color: AppColors.secondaryText)),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildGuideSection(),
        const SizedBox(height: 12),
        _buildStateCard(),
        const SizedBox(height: 12),
        _buildActionRow(),
        if (_busy) ...[
          const SizedBox(height: 12),
          _buildProgressBar(),
        ],
        if (_statusMessage != null) ...[
          const SizedBox(height: 12),
          _buildStatusBanner(),
        ],
        const SizedBox(height: 16),
        _buildArchiveSection(),
        const SizedBox(height: 16),
        _buildCloudSection(),
        const SizedBox(height: 16),
        _buildRetentionRow(),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildStateCard() {
    final res = _resolution;
    final game = _game;

    if (res == null) {
      return _card(
        child: Text(
          '未找到该游戏的库记录，无法管理存储状态。',
          style: TextStyle(fontSize: 13, color: AppColors.secondaryText),
        ),
      );
    }

    final totalBytes =
        _archives.fold<int>(0, (sum, r) => sum + r.totalBytes);
    final latest = _archives.isEmpty ? null : _archives.first;

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('存储状态',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.secondaryText)),
              const SizedBox(width: 10),
              _stateBadge(res.state),
              const Spacer(),
              Text(
                '${DateTime.now().year}',
                style: TextStyle(fontSize: 11, color: AppColors.placeholderText),
              ),
            ],
          ),
          if (res.degraded) ...[
            const SizedBox(height: 8),
            _inlineWarn('归档状态已降级：${res.reason}'),
          ],
          const SizedBox(height: 10),
          _kv('归档份数', '${_archives.length} 份'),
          _kv('归档体积', _archives.isEmpty ? '—' : _formatSize(totalBytes)),
          _kv('最近归档', _formatDate(latest?.createdAt)),
          _kv('归档目录', ArchiveLibraryPreference.instance.rootPath, mono: true),
          _kv(
            '本体目录',
            (game?.directoryPath.isNotEmpty ?? false)
                ? game!.directoryPath
                : widget.installDir,
            mono: true,
          ),
          if (game != null && game.archiveAt.isNotEmpty)
            _kv('状态写入时间', game.archiveAt),
        ],
      ),
    );
  }

  Widget _buildActionRow() {
    final res = _resolution;
    if (res == null) return const SizedBox.shrink();

    final declared = res.declared;
    final isNormal = res.state == GameStorageState.normal;
    final canSeal = !_busy && isNormal;
    final canPack = !_busy && isNormal && res.bodyExists == true;
    final canUnseal = !_busy && declared == GameStorageState.sealed;
    final canUnpack = !_busy && declared == GameStorageState.packed;

    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: [
        _actionButton(
          icon: Icons.save_outlined,
          label: '封装',
          onTap: canSeal ? _seal : null,
          primary: true,
        ),
        if (isNormal)
          _actionButton(
            icon: Icons.inventory_2_outlined,
            label: '打包',
            onTap: canPack ? _pack : null,
          ),
        if (declared == GameStorageState.sealed)
          _actionButton(
            icon: Icons.lock_open_outlined,
            label: '解封',
            onTap: canUnseal ? _unseal : null,
          ),
        if (declared == GameStorageState.packed)
          _actionButton(
            icon: Icons.unarchive_outlined,
            label: '解包',
            onTap: canUnpack ? _unpack : null,
          ),
      ],
    );
  }

  Widget _buildProgressBar() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(AppColors.selectedAccent),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _busyLabel,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primaryText),
                ),
              ),
              Text('$_progress%',
                  style: TextStyle(
                      fontSize: 12, color: AppColors.secondaryText)),
            ],
          ),
          if (_phaseLabel.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(_phaseLabel,
                style:
                    TextStyle(fontSize: 12, color: AppColors.secondaryText)),
          ],
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: _progress <= 0 ? null : _progress / 100.0,
              minHeight: 6,
              backgroundColor: AppColors.borderLight,
              valueColor:
                  AlwaysStoppedAnimation<Color>(AppColors.selectedAccent),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBanner() {
    final ok = _statusSuccess;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: ok ? AppColors.successBg : AppColors.errorBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: ok ? AppColors.successGreen : AppColors.dangerRed,
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(ok ? Icons.check_circle_outline : Icons.error_outline,
              size: 15,
              color: ok ? AppColors.successGreen : AppColors.dangerRed),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _statusMessage!,
              style: TextStyle(
                fontSize: 12,
                color: ok ? AppColors.successGreen : AppColors.dangerRed,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildArchiveSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('归档列表',
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.border)),
        const SizedBox(height: 8),
        if (_archives.isEmpty)
          _card(
            child: Text('暂无归档。点击「封装」创建第一份。',
                style:
                    TextStyle(fontSize: 13, color: AppColors.secondaryText)),
          )
        else
          ..._archives.map(_buildArchiveItem),
      ],
    );
  }

  Widget _buildArchiveItem(ArchiveRecord rec) {
    final active = _game?.archiveDir == rec.archiveDir;
    final fileCount = rec.manifest.declaredFileCount;
    return _card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                rec.state == 'packed'
                    ? Icons.archive_outlined
                    : Icons.inventory_2_outlined,
                size: 16,
                color: AppColors.border,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  rec.id,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primaryText,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (active)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.selectedAccent.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text('当前',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: AppColors.selectedAccent)),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${_formatDate(rec.createdAt)} · ${_formatSize(rec.totalBytes)}'
            '${fileCount > 0 ? ' · $fileCount 个文件' : ''}',
            style: TextStyle(fontSize: 12, color: AppColors.secondaryText),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 4,
            children: [
              _smallAction(
                icon: Icons.restore,
                label: '恢复',
                onTap: _busy ? null : () => _restoreFrom(rec),
              ),
              _smallAction(
                icon: Icons.cloud_upload_outlined,
                label: '上传云端',
                onTap: _busy ? null : () => _uploadToCloud(rec),
              ),
              _smallAction(
                icon: Icons.folder_open,
                label: '打开目录',
                onTap: () => _openFolder(rec.archiveDir),
              ),
              _smallAction(
                icon: Icons.delete_outline,
                label: '删除',
                danger: true,
                onTap: _busy ? null : () => _deleteArchive(rec),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRetentionRow() {
    final pref = ArchiveLibraryPreference.instance;
    return _card(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('归档保留份数',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.primaryText)),
                const SizedBox(height: 2),
                Text('归档超过该份数时，自动清理最旧的归档',
                    style: TextStyle(
                        fontSize: 11, color: AppColors.secondaryText)),
              ],
            ),
          ),
          _stepperButton(Icons.remove, () async {
            final v = pref.retention - 1;
            await pref.setRetention(v);
            if (mounted) setState(() {});
          }),
          Container(
            width: 42,
            alignment: Alignment.center,
            child: Text('${pref.retention}',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primaryText)),
          ),
          _stepperButton(Icons.add, () async {
            final v = pref.retention + 1;
            await pref.setRetention(v);
            if (mounted) setState(() {});
          }),
        ],
      ),
    );
  }

  // ============================================================
  // 小组件
  // ============================================================

  Widget _card({required Widget child, EdgeInsetsGeometry? margin}) {
    return Container(
      width: double.infinity,
      margin: margin,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.sidebarBackground,
        border: Border.all(color: AppColors.border, width: 1.4),
        borderRadius: BorderRadius.circular(6),
      ),
      child: child,
    );
  }

  Widget _stateBadge(GameStorageState state) {
    final color = switch (state) {
      GameStorageState.normal => AppColors.successGreen,
      GameStorageState.sealed => AppColors.brandBlue,
      GameStorageState.packed => AppColors.selectedAccent,
      GameStorageState.displayOnly => AppColors.secondaryText,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.5), width: 1),
      ),
      child: Text(
        state.label,
        style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  Widget _inlineWarn(String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.warning_amber_rounded,
            size: 15, color: AppColors.warningAmber),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text,
              style: TextStyle(
                  fontSize: 12, color: AppColors.warningAmber, height: 1.4)),
        ),
      ],
    );
  }

  Widget _kv(String key, String value, {bool mono = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(key,
                style: TextStyle(
                    fontSize: 12, color: AppColors.secondaryText)),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style: TextStyle(
                fontSize: 12,
                color: AppColors.primaryText,
                fontFamily: mono ? 'monospace' : null,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool primary = false,
  }) {
    final enabled = onTap != null;
    final bg = primary && enabled
        ? AppColors.selectedAccent
        : AppColors.buttonBackground;
    final fg = primary && enabled ? Colors.white : AppColors.border;
    return MouseRegion(
      cursor:
          enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: onTap,
        child: Opacity(
          opacity: enabled ? 1 : 0.5,
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 18),
            decoration: BoxDecoration(
              color: bg,
              border: Border.all(
                  color: primary && enabled
                      ? Colors.black.withOpacity(0.1)
                      : AppColors.border,
                  width: 1.4),
              borderRadius: BorderRadius.circular(4),
              boxShadow: [
                BoxShadow(
                  color: AppColors.border.withOpacity(0.3),
                  offset: const Offset(2, 2),
                  blurRadius: 0,
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 17, color: fg),
                const SizedBox(width: 6),
                Text(label,
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: fg)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _smallAction({
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool danger = false,
  }) {
    final color = danger ? AppColors.dangerRed : AppColors.secondaryText;
    return MouseRegion(
      cursor: onTap != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: onTap,
        child: Opacity(
          opacity: onTap != null ? 1 : 0.5,
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.borderLight, width: 1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 4),
                Text(label,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: color)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _stepperButton(IconData icon, VoidCallback onTap) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.border, width: 1.4),
            borderRadius: BorderRadius.circular(4),
          ),
          alignment: Alignment.center,
          child: Icon(icon, size: 16, color: AppColors.border),
        ),
      ),
    );
  }
}

enum _Lvl { success, warning, error, info }
