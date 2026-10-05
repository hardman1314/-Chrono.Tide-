import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// GAL 游戏识别结果（带可解释性）
///
/// 提供置信度分数、判定结论与命中依据，便于 UI 展示与调试。
class GalDetectionResult {
  /// 0.0 ~ 1.0 置信度
  final double confidence;

  /// 是否判定为 GAL 游戏（confidence >= threshold）
  final bool isGame;

  /// 命中的强信号（引擎核心文件等）
  final List<String> strongSignals;

  /// 命中的中等信号（特征目录 / 脚本文件 / 数据包 / exe）
  final List<String> mediumSignals;

  /// 命中的弱信号（日中文目录名 / 图片音视频目录）
  final List<String> weakSignals;

  /// 命中的负信号（系统目录 / 无 exe / 通用名）
  final List<String> negativeSignals;

  /// 推断的引擎类型（kirikiri / siglus / rpgmaker / unknown 等）
  final String engineType;

  /// 识别到的非工具类 exe 文件名（取主启动程序）
  final String? mainExeName;

  // ===== 直接签名（depth 0 直接内容，用于区分真实游戏 vs 容器文件夹）=====
  //
  // 背景：原先 _collectEntries 扫描 2 层，容器文件夹（如 GAL/JRPG）会因
  // 伸进子目录收集到引擎核心文件而获得强信号 → 被误判为游戏。
  // 直接签名只看本文件夹自身内容，容器天然无直接签名 → 不被判定为游戏。
  //
  // 判定规则：isGame 要求至少一个直接签名成立（详见 detect 中 hasDirectSignature）。
  // mainExeName 仍可来自继承（子目录 exe），供"包装文件夹救援"使用。

  /// 引擎核心文件直接位于本文件夹（depth 0）
  final bool hasDirectStrongSignal;

  /// 非排除 exe 直接位于本文件夹（depth 0）
  final bool hasDirectExe;

  /// 数据包文件（.xp3/.arc/.dat/.rpa 等）直接位于本文件夹（depth 0）
  final bool hasDirectDataPack;

  /// 特征目录（data/sound/cg 等）直接是本文件夹的子目录（depth 0）
  final bool hasDirectFeatureDir;

  /// mainExeName 是否来自继承（子目录），用于"包装文件夹救援"判定
  final bool mainExeInherited;

  const GalDetectionResult({
    required this.confidence,
    required this.isGame,
    this.strongSignals = const [],
    this.mediumSignals = const [],
    this.weakSignals = const [],
    this.negativeSignals = const [],
    this.engineType = 'unknown',
    this.mainExeName,
    this.hasDirectStrongSignal = false,
    this.hasDirectExe = false,
    this.hasDirectDataPack = false,
    this.hasDirectFeatureDir = false,
    this.mainExeInherited = false,
  });

  /// 是否具备直接游戏签名（任一即可作为"真实游戏"的判定依据）
  bool get hasDirectSignature =>
      hasDirectStrongSignal ||
      hasDirectExe ||
      (hasDirectDataPack && hasDirectFeatureDir);

  /// 简要依据描述，用于 UI 展示
  String get reasonSummary {
    final all = <String>[
      ...strongSignals.map((s) => '强:$s'),
      ...mediumSignals.map((s) => '中:$s'),
      ...weakSignals.map((s) => '弱:$s'),
      if (negativeSignals.isNotEmpty) '负信号${negativeSignals.length}项',
    ];
    return all.isEmpty ? '无特征' : all.take(4).join(' · ');
  }
}

/// 文件夹分类（供容器判定与共享逻辑使用）
enum FolderClassification { game, container, unknown }

/// GAL 游戏识别器
///
/// 评分体系（0~100 分，默认阈值 30 分 → 0.30 置信度）：
/// - 强信号（任一即可直接判定，+35~+40）
/// - 中等信号（需组合，+8~+15 每个）
/// - 弱信号（需多个组合，+5 每个）
/// - 负信号（扣分，-20~-50）
///
/// 扫描深度：2 层（直接子项 + 二层子项），兼顾准确性与性能。
class GalGameDetector {
  GalGameDetector._();

  /// 默认置信度阈值
  static const double defaultThreshold = 0.30;

  // ==================== 引擎特征表 ====================

  /// 引擎核心文件 / 已知引擎可执行文件（强信号）
  /// 每项格式：'文件名片段:引擎类型'
  static const Map<String, String> _engineIndicators = {
    // Kirikiri / KAG
    'data.xp3': 'kirikiri',
    'initial.ks': 'kirikiri',
    'startup.tjs': 'kirikiri',
    'krkr.exe': 'kirikiri',
    'kirikiri': 'kirikiri',
    'data.ks': 'kirikiri',
    'scenario.ks': 'kirikiri',
    'script.ks': 'kirikiri',
    'system.ks': 'kirikiri',
    'initialize.tjs': 'kirikiri',
    // NScripter
    'nss.npa': 'nscripter',
    'arc.nsa': 'nscripter',
    'onscripter': 'nscripter',
    'reallive': 'nscripter',
    'realLive': 'nscripter',
    // SiglusEngine
    'siglus': 'siglus',
    'siglusengine': 'siglus',
    // System4.x (AliceSoft)
    'system40': 'system4',
    'alice': 'system4',
    // BGI / Buriko
    'buriko': 'bgi',
    'monshiro': 'bgi',
    'bgi.exe': 'bgi',
    // KAG / Kikyo
    'kikyo.exe': 'kikyo',
    // RPGMaker / Tyrano / WOLF
    'rpgmaker': 'rpgmaker',
    'tyrano': 'tyrano',
    'tyranoscript': 'tyrano',
    'wolf.exe': 'wolf',
    'wolfeditor': 'wolf',
    // 其他常见引擎
    'malie': 'malie',
    'musica': 'musica',
    'ruggie': 'ruggie',
    'eagls': 'eagls',
    'cmvs': 'cmvs',
    'yuris': 'yuris',
    'fns': 'fns',
    'agi4': 'agi4',
    'artalk': 'artalk',
    'mages': 'mages',
    'nitroplus': 'nitroplus',
    'leaf': 'leaf',
    'cabbage': 'cabbage',
    'willplus': 'willplus',
    'runscript': 'willplus',
    'advhd': 'willplus',
    'anex86': 'anex86',
    // Ren'Py 引擎（强信号）
    'renpy': 'renpy',
    '.rpyc': 'renpy',
    'archive.rpa': 'renpy',
    'updates.json': 'renpy',
    // Unity 引擎（强信号）
    'unityplayer.dll': 'unity',
    'assembly-csharp.dll': 'unity',
    'globalgamemanagers': 'unity',
    'resources.assets': 'unity',
    // 轻小说引擎
    'light.vn': 'lightvn',
    'softpal': 'softpal',
    'wsd.exe': 'softpal',
    // 其他补充引擎
    'fcaps': 'fcaps',
    'oneway': 'oneway',
    'artemis': 'artemis',
    'novamic': 'novamic',
    'augusta': 'augusta',
    'walkure': 'walkure',
    't2u': 't2u',
    // 补充引擎特征（扩展识别覆盖面）
    'kagparser': 'kagparser',
    'ks_manager': 'kagparser',
    'emote': 'emote', // emote引擎
    'pages': 'pages', // Pages引擎
    'pagesystem': 'pages',
    'microsoft.xna': 'xna', // XNA框架
    'fna': 'fna', // FNA兼容层
    'monogame': 'monogame', // MonoGame框架
    'godot': 'godot', // Godot引擎
    'unrealengine': 'unreal', // UE引擎（罕见于GAL但补充）
    // 通用游戏标识
    'game.dat': 'generic',
    'game.exe': 'generic',
    'config.ini': 'generic',
    'game.ini': 'generic',
  };

  /// 游戏脚本 / 数据包文件扩展名（中等信号）
  static const List<String> _scriptExtensions = [
    '.ks', '.tjs', '.scp', '.rb', '.js',
    '.rpy', // Ren'Py
  ];

  static const List<String> _dataPackExtensions = [
    '.xp3', '.npa', '.pak', '.arc', '.dat',
    '.rpa', '.rpyc', // Ren'Py
  ];

  /// 游戏特征目录名（中等信号）
  static const List<String> _featureDirs = [
    'data',
    'sound',
    'bg',
    'cg',
    'graphic',
    'image',
    'movie',
    'music',
    'bgm',
    'se',
    'voice',
    'sav',
    'save',
    'script',
    'scenario',
    'background',
    'char',
    'character',
    'event',
    'still',
    'wall',
  ];

  /// 图片/音视频弱信号目录
  static const List<String> _mediaDirs = [
    'image',
    'imagefolder',
    'graphic',
    'picture',
    'pic',
    'movie',
    'video',
    'bgm',
    'music',
    'se',
    'voice',
  ];

  /// 系统目录 / 非游戏目录模式（强负信号）
  static const List<String> _systemPatterns = [
    'windows',
    'program files',
    'epic games',
    'origin',
    'uplay',
    'gog galaxy',
    'microsoft',
    'appdata',
    'system volume information',
    'documents and settings',
    '\$recycle.bin',
    '.git',
    '.svn',
    '.idea',
    'node_modules',
    '__pycache__',
    '.gradle',
    'build',
    'dist',
    'out',
    'bin',
    'obj',
  ];

  /// 开发项目标记文件（出现即强烈暗示非游戏，强负信号 -40）
  /// 用于拦截误识别：含这些文件的目录是开发项目而非游戏
  static const List<String> _projectMarkerFiles = [
    'package.json', // Node.js 项目
    'tsconfig.json', // TypeScript 项目
    'cargo.toml', // Rust 项目
    'pom.xml', // Maven 项目
    'build.gradle', // Gradle 项目
    'go.mod', // Go 项目
    'composer.json', // PHP 项目
    'pyproject.toml', // Python 项目
    'requirements.txt', // Python 项目
  ];

  /// 开发项目标记扩展名（需后缀匹配）
  static const List<String> _projectMarkerExtensions = [
    '.csproj', // .NET 项目
    '.sln', // VS 解决方案
  ];

  /// 通用目录名（弱负信号）
  ///
  /// 英文通用名：精确匹配（_englishGenericNames）
  /// CJK 关键词：子串匹配（_cjkGenericKeywords），覆盖组合名如
  ///   "AI补丁"、"补丁&存档"、"全CG存档"、"[白井木学园]...完整汉化补丁"
  ///
  /// CJK 子串匹配安全：游戏文件夹名通常是游戏标题（如"命运石之门"），
  /// 不会包含"补丁/存档/备份/汉化"等附属词汇作为子串。
  static const List<String> _englishGenericNames = [
    'data',
    'config',
    'system',
    'temp',
    'tmp',
    'cache',
    'update',
    'patch',
    'save',
    'saves',
    'backup',
    'new folder',
    'folder',
    'game',
    'games',
  ];

  /// CJK 附属文件夹关键词（子串匹配 → -30 弱负信号）
  /// 基础关键词覆盖所有组合形式：
  ///   "补丁" → AI补丁、补丁&存档、汉化补丁、更新补丁...
  ///   "存档" → 全CG存档、存档备份...
  ///   "备份" → 存档备份、备份文件夹...
  ///   "汉化" → 汉化补丁、汉化版...
  /// 扩展关键词覆盖更多附属内容：
  ///   "修正" → 修正补丁、修正版...
  ///   "更新" → 更新程序、更新补丁...
  ///   "追加" → 追加内容、追加包...
  ///   "特典" → 特典内容、予約特典...
  ///   "攻略" → 攻略集、攻略本...
  ///   "おまけ" → おまけ集、bonus...
  ///   "初回" → 初回限定、初回特典...
  ///   "限定" → 限定版、初回限定...
  static const List<String> _cjkGenericKeywords = [
    '补丁',
    '存档',
    '备份',
    '汉化',
    '修正',
    '追加',
    '特典',
    '攻略',
    'おまけ',
    '初回',
    '限定',
  ];

  /// 检查目录名是否为通用名（弱负信号）
  /// 英文：精确匹配；CJK：子串匹配
  static bool _isGenericFolderName(String folderName) {
    if (_englishGenericNames.contains(folderName)) return true;
    for (final kw in _cjkGenericKeywords) {
      if (folderName.contains(kw)) return true;
    }
    return false;
  }

  /// exe 文件名排除关键词（非游戏主程序）
  ///
  /// contains 匹配：exe 文件名（小写）包含任一关键词则排除，不作为 mainExe。
  /// 英文关键词覆盖安装器/卸载器/补丁工具/运行时库；
  /// CJK 关键词覆盖汉化补丁/存档编辑器/备份工具等附属 exe，
  /// 防止附属文件夹因含此类 exe 被误判为游戏。
  static const List<String> _exeExcludeKeywords = [
    'uninstall',
    'setup',
    'installer',
    'patch',
    'update',
    'config',
    'tool',
    'editor',
    'crash',
    'report',
    'redist',
    'vc_redist',
    'dxsetup',
    'vcredist',
    // CJK exe 排除关键词（contains 匹配 → 不作为 mainExe）
    '汉化', // 汉化补丁.exe 等
    '补丁', // 补丁.exe 等
    '修正', // 修正补丁.exe 等
    '更新', // 更新程序.exe 等
    '存档', // 存档编辑器.exe 等
    '备份', // 备份工具.exe 等
  ];

  // ==================== 公开 API ====================

  /// 精确检测：返回带依据的结果
  static GalDetectionResult detect(String folderPath,
      {double threshold = defaultThreshold}) {
    try {
      final dir = Directory(folderPath);
      if (!dir.existsSync()) {
        return const GalDetectionResult(
          confidence: 0.0,
          isGame: false,
          negativeSignals: ['目录不存在'],
        );
      }

      final folderName = _basename(folderPath).toLowerCase();

      // 负信号：系统目录
      // ★ IMP-19（2026-09-12 导入审查）：按**路径分段精确匹配**。
      // 旧实现用整条路径 contains（'origin'/'windows'/'microsoft'…），
      // 会把 `D:\GAL\Original\…`、`D:\games\windows_no_naka\…` 这类合法游戏目录
      // 误记负信号扣分甚至漏识别。
      final negative = <String>[];
      final pathSegments = folderPath
          .split(RegExp(r'[\\/]+'))
          .map((s) => s.toLowerCase())
          .toList();
      for (final pattern in _systemPatterns) {
        if (pathSegments.contains(pattern.toLowerCase())) {
          negative.add('系统路径:$pattern');
        }
      }

      // 收集直接(depth0)与继承(depth1)内容，分别用于直接签名判定
      // 直接签名只看本文件夹自身内容，容器文件夹天然无直接签名 → 不被误判为游戏
      final directFiles = <File>[];
      final deepFiles = <File>[];
      final directSubDirs = <Directory>[];
      final deepSubDirs = <Directory>[];
      _collectEntriesSeparate(
          dir, directFiles, deepFiles, directSubDirs, deepSubDirs);

      // ==================== 信号检测 ====================
      final strong = <String>[];
      final medium = <String>[];
      final weak = <String>[];
      String engineType = 'unknown';
      String? mainExe;
      bool hasDirectStrongSignal = false;
      bool hasDirectExe = false;
      bool hasDirectDataPack = false;
      bool hasDirectFeatureDir = false;
      bool mainExeInherited = false;

      // 强信号：先扫直接文件（标记直接强信号），再扫继承文件（仅计入 strong 用于引擎类型推断）
      for (final file in directFiles) {
        final nameLower = p.basename(file.path).toLowerCase();
        for (final entry in _engineIndicators.entries) {
          if (nameLower.contains(entry.key.toLowerCase())) {
            if (engineType == 'unknown') engineType = entry.value;
            if (!strong.contains(entry.value)) strong.add(entry.value);
            hasDirectStrongSignal = true;
            break;
          }
        }
      }
      for (final file in deepFiles) {
        final nameLower = p.basename(file.path).toLowerCase();
        for (final entry in _engineIndicators.entries) {
          if (nameLower.contains(entry.key.toLowerCase())) {
            if (engineType == 'unknown') engineType = entry.value;
            if (!strong.contains(entry.value)) strong.add(entry.value);
            break;
          }
        }
      }

      // 中等信号：脚本/数据包/exe —— 直接文件优先，并标记直接签名
      for (final file in directFiles) {
        final nameLower = p.basename(file.path).toLowerCase();
        final ext = p.extension(nameLower).toLowerCase();

        if (_scriptExtensions.contains(ext)) {
          if (!medium.contains('脚本$ext')) medium.add('脚本$ext');
        }
        if (_dataPackExtensions.contains(ext)) {
          if (!medium.contains('数据包$ext')) medium.add('数据包$ext');
          hasDirectDataPack = true;
        }

        // 收集非工具 exe
        if (ext == '.exe') {
          bool excluded = false;
          for (final kw in _exeExcludeKeywords) {
            if (nameLower.contains(kw)) {
              excluded = true;
              break;
            }
          }
          if (!excluded) {
            if (!medium.contains('exe文件')) medium.add('exe文件');
            hasDirectExe = true;
            // 直接 exe 优先作为 mainExe
            mainExe ??= p.basename(file.path);
          }
        }
      }
      // 继承文件：计入中等信号，但 exe 仅在无直接 exe 时回退作 mainExe（供包装救援）
      for (final file in deepFiles) {
        final nameLower = p.basename(file.path).toLowerCase();
        final ext = p.extension(nameLower).toLowerCase();

        if (_scriptExtensions.contains(ext)) {
          if (!medium.contains('脚本$ext')) medium.add('脚本$ext');
        }
        if (_dataPackExtensions.contains(ext)) {
          if (!medium.contains('数据包$ext')) medium.add('数据包$ext');
        }

        if (ext == '.exe') {
          bool excluded = false;
          for (final kw in _exeExcludeKeywords) {
            if (nameLower.contains(kw)) {
              excluded = true;
              break;
            }
          }
          if (!excluded) {
            if (!medium.contains('exe文件')) medium.add('exe文件');
            // 无直接 exe 时回退取继承 exe，标记为 inherited
            if (mainExe == null) {
              mainExe = p.basename(file.path);
              mainExeInherited = true;
            }
          }
        }
      }

      // 特征目录（中等信号）+ 媒体目录（弱信号）—— 直接子目录标记直接签名
      for (final subDir in directSubDirs) {
        final dirName = _basename(subDir.path).toLowerCase();
        if (_featureDirs.contains(dirName)) {
          if (!medium.contains('目录:$dirName')) medium.add('目录:$dirName');
          hasDirectFeatureDir = true;
        }
        if (_mediaDirs.contains(dirName) && !weak.contains('媒体:$dirName')) {
          weak.add('媒体:$dirName');
        }
      }
      for (final subDir in deepSubDirs) {
        final dirName = _basename(subDir.path).toLowerCase();
        if (_featureDirs.contains(dirName) && !medium.contains('目录:$dirName')) {
          medium.add('目录:$dirName');
        }
        if (_mediaDirs.contains(dirName) && !weak.contains('媒体:$dirName')) {
          weak.add('媒体:$dirName');
        }
      }

      // 弱信号：目录名含日文/中文
      if (_containsCjk(folderName)) {
        weak.add('CJK目录名');
      }

      // 项目标记文件检测：仅看直接文件（开发项目根目录才有 package.json 等）
      for (final file in directFiles) {
        final nameLower = p.basename(file.path).toLowerCase();
        if (_projectMarkerFiles.any((m) => nameLower == m)) {
          if (!negative.contains('项目标记:$nameLower')) {
            negative.add('项目标记:$nameLower');
          }
        } else if (_projectMarkerExtensions
            .any((ext) => nameLower.endsWith(ext))) {
          if (!negative.contains('项目标记:$nameLower')) {
            negative.add('项目标记:$nameLower');
          }
        }
      }

      // ==================== 评分计算 ====================
      int score = 0;

      // 强信号：+40 每个（引擎核心文件直接强判定）
      score += strong.length * 40;

      // 中等信号：脚本/数据包 +15，特征目录 +8，exe +10
      for (final sig in medium) {
        if (sig.startsWith('脚本') || sig.startsWith('数据包')) {
          score += 15;
        } else if (sig.startsWith('目录:')) {
          score += 8;
        } else if (sig == 'exe文件') {
          score += 10;
        }
      }

      // 弱信号：+5 每个
      score += weak.length * 5;

      // 负信号：系统路径 -50，项目标记 -40，无 exe -15，通用名 -30
      for (final neg in negative) {
        if (neg.startsWith('系统路径')) {
          score -= 50;
        } else if (neg.startsWith('项目标记')) {
          score -= 40;
        }
      }

      // 无 exe 且无强信号 → 扣分（GAL 通常都有 exe 或解释器）
      final hasAnyExe = medium.any((s) => s == 'exe文件') || strong.isNotEmpty;
      if (!hasAnyExe && strong.isEmpty) {
        score -= 15;
        negative.add('无可执行文件');
      }

      // 通用目录名扣分（英文精确匹配 + CJK 子串匹配）
      if (_isGenericFolderName(folderName)) {
        score -= 30;
        negative.add('通用目录名');
      }

      // 强信号存在时，直接判定通过（即使其他信号弱）
      final bool hasStrongSignal = strong.isNotEmpty;

      // 救援规则1：覆盖 Ren'Py/Unity 新作（无传统引擎特征文件）
      // 这类游戏：CJK 目录名 + exe + 至少 1 个特征/媒体目录
      // 评分可能因无强信号不足 30，但实际是游戏
      final bool rescueCjk = !hasStrongSignal &&
          medium.any((s) => s == 'exe文件') &&
          weak.any((s) => s == 'CJK目录名') &&
          (medium.any((s) => s.startsWith('目录:')) ||
              weak.any((s) => s.startsWith('媒体:')));

      // 救援规则2：覆盖英文命名的便携式 GAL 游戏
      // 非 CJK 目录名但 exe + 多个特征目录/脚本/数据包
      // 例如 "Kanon" 文件夹含 game.exe + data/ + sound/ + script/
      final int mediumFeatureCount = medium
          .where((s) =>
              s.startsWith('目录:') || s.startsWith('脚本') || s.startsWith('数据包'))
          .length;
      final bool rescueNonCjk = !hasStrongSignal &&
          medium.any((s) => s == 'exe文件') &&
          mediumFeatureCount >= 2 &&
          !_isGenericFolderName(folderName);

      final bool rescue = rescueCjk || rescueNonCjk;

      final double confidence = (score / 100.0).clamp(0.0, 1.0);

      // ===== 直接签名前置门控（核心修复）=====
      // 无直接签名 → 不是游戏。阻断容器文件夹（GAL/JRPG）凭继承的引擎文件
      // 强信号被误判为游戏。容器由调用方（阶段三/智能导入）递归进入子目录发现真游戏。
      final bool hasDirectSignature = hasDirectStrongSignal ||
          hasDirectExe ||
          (hasDirectDataPack && hasDirectFeatureDir);

      if (!hasDirectSignature) {
        return GalDetectionResult(
          confidence: confidence,
          isGame: false,
          strongSignals: strong,
          mediumSignals: medium,
          weakSignals: weak,
          negativeSignals: [...negative, '无直接签名(容器)'],
          engineType: engineType,
          mainExeName: mainExe,
          hasDirectStrongSignal: hasDirectStrongSignal,
          hasDirectExe: hasDirectExe,
          hasDirectDataPack: hasDirectDataPack,
          hasDirectFeatureDir: hasDirectFeatureDir,
          mainExeInherited: mainExeInherited,
        );
      }

      final bool isGame = hasStrongSignal
          ? (score >= 30)
          : rescue
              ? true
              : (score >= 30 && medium.length + weak.length >= 2);

      return GalDetectionResult(
        confidence: confidence,
        isGame: isGame,
        strongSignals: strong,
        mediumSignals: medium,
        weakSignals: weak,
        negativeSignals: negative,
        engineType: engineType,
        mainExeName: mainExe,
        hasDirectStrongSignal: hasDirectStrongSignal,
        hasDirectExe: hasDirectExe,
        hasDirectDataPack: hasDirectDataPack,
        hasDirectFeatureDir: hasDirectFeatureDir,
        mainExeInherited: mainExeInherited,
      );
    } catch (e) {
      debugPrint('[GAL-DETECTOR] 检测异常: $e');
      return GalDetectionResult(
        confidence: 0.0,
        isGame: false,
        negativeSignals: ['异常:$e'],
      );
    }
  }

  /// 兼容旧 API：是否可能是 GAL 游戏
  static bool isLikelyGalGame(String folderPath) {
    return detect(folderPath).isGame;
  }

  /// 兼容旧 API：置信度评分
  static double getConfidenceScore(String folderPath) {
    return detect(folderPath).confidence;
  }

  /// 兼容旧 API：批量过滤
  static Future<List<String>> filterGalFolders(List<String> folders) async {
    return folders.where((f) => isLikelyGalGame(f)).toList();
  }

  /// 文件夹分类：game / container / unknown
  ///
  /// 供批量导入阶段三与智能导入共享的容器判定。基于直接签名：
  /// - game：有直接签名（真实游戏本体）
  /// - container：无直接签名，但有继承的引擎/exe 信号（说明子目录有游戏）
  /// - unknown：无直接签名且无继承信号（空目录/无关目录）
  ///
  /// 注意：此方法仅做单文件夹分类，是否为"多游戏容器"需调用方结合兄弟目录判断。
  static FolderClassification classify(String folderPath) {
    final d = detect(folderPath);
    if (d.isGame) return FolderClassification.game;
    // 无直接签名但有继承信号（strong 非空或 mainExeName 来自继承）→ 容器
    final hasInheritedSignal =
        d.strongSignals.isNotEmpty || (d.mainExeInherited && d.mainExeName != null);
    if (hasInheritedSignal) return FolderClassification.container;
    return FolderClassification.unknown;
  }

  // ==================== 内部辅助 ====================

  /// 分别收集直接(depth0)与继承(depth1)的文件与子目录
  ///
  /// 直接内容用于"直接签名"判定（区分真实游戏 vs 容器文件夹）；
  /// 继承内容仍参与评分与引擎类型推断，但不再让容器凭继承信号成为游戏。
  /// 保留 2000/500 安全上限避免超大目录耗尽内存。
  static void _collectEntriesSeparate(
    Directory dir,
    List<File> directFiles,
    List<File> deepFiles,
    List<Directory> directSubDirs,
    List<Directory> deepSubDirs,
  ) {
    try {
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is File) {
          directFiles.add(entity);
        } else if (entity is Directory) {
          directSubDirs.add(entity);
          // 二层目录内的文件/子目录也算（用于检测 game/data.xp3 这种结构）
          try {
            for (final subEntity in entity.listSync(followLinks: false)) {
              if (subEntity is File) {
                deepFiles.add(subEntity);
              } else if (subEntity is Directory) {
                deepSubDirs.add(subEntity);
              }
              // 安全上限
              if (deepFiles.length > 2000) {
                deepFiles.removeRange(2000, deepFiles.length);
                break;
              }
              if (deepSubDirs.length > 500) {
                deepSubDirs.removeRange(500, deepSubDirs.length);
                break;
              }
            }
          } catch (_) {
            // 子目录权限不足，忽略
          }
        }
        // 安全上限：避免超大目录耗尽内存
        if (directFiles.length > 2000) {
          directFiles.removeRange(2000, directFiles.length);
          break;
        }
        if (directSubDirs.length > 500) {
          directSubDirs.removeRange(500, directSubDirs.length);
          break;
        }
      }
    } catch (_) {
      // 忽略权限错误
    }
  }

  static String _basename(String path) {
    return path.split('/').last.split('\\').last;
  }

  /// 检测是否包含 CJK 字符（中日韩）
  static bool _containsCjk(String text) {
    for (final codeUnit in text.runes) {
      if ((codeUnit >= 0x4E00 && codeUnit <= 0x9FFF) || // CJK 统一表意
          (codeUnit >= 0x3040 && codeUnit <= 0x30FF) || // 平假名/片假名
          (codeUnit >= 0xAC00 && codeUnit <= 0xD7AF)) {
        // 韩文音节
        return true;
      }
    }
    return false;
  }
}
