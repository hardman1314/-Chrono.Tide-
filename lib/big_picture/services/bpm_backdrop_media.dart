import 'dart:convert';
import 'dart:io';

import '../../services/bpm_op_video_preference.dart';
import '../../services/game_data_format.dart';

/// 背景图素材：`metaDataDir` 内的相对文件名 + 展示名。
class BpmBackdropImageAsset {
  const BpmBackdropImageAsset({required this.file, required this.name});

  final String file;

  /// 展示名（用户可改，如「立绘」「场景」；空串显示时回退序号）。
  final String name;
}

/// 背景视频素材：`metaDataDir` 内的相对文件名 + 展示名（如「游戏OP」「游戏ED」）。
class BpmBackdropVideoAsset {
  const BpmBackdropVideoAsset({required this.file, required this.name});

  final String file;
  final String name;
}

/// BPM 背景媒体数据层（**多素材版**，v3.11.1）。
///
/// ## 字段（全部相对 `metaDataDir`，仍走 `updateGameJson` merge、零迁移）
///
/// | 字段 | 类型 | 语义 |
/// |---|---|---|
/// | `bpm_backdrop_images` | `[{file,name}]` | 可选背景图池（不含封面，封面固定可选） |
/// | `bpm_backdrop_selected_image` | `String` | 当前背景图；**空串 = 使用封面** |
/// | `bpm_backdrop_videos` | `[{file,name}]` | 可选背景视频池（游戏OP / 动画OP / ED…） |
/// | `bpm_backdrop_selected_video` | `String` | 当前背景视频；**空串 = 不自动播放** |
///
/// ## 兼容（v3.11.0 单素材字段）
///
/// 旧字段 `bpm_custom_backdrop` / `bpm_op_video` **只读兼容**：新列表为空时回退读取；
/// 任何写操作都会顺带把旧字段置 null（值已并入新列表），完成一次性迁移。
/// 🔴 新旧字段同样**不进 `_overwritableFields`、不升 schema**（ADR-015）。
///
/// ⚠️ 本文件**不依赖 video_player**（纯路径/校验逻辑）。
class BpmBackdropMedia {
  const BpmBackdropMedia._();

  // ===== 新字段（多素材） =====
  static const String kBackdropImages = 'bpm_backdrop_images';
  static const String kSelectedImage = 'bpm_backdrop_selected_image';
  static const String kBackdropVideos = 'bpm_backdrop_videos';
  static const String kSelectedVideo = 'bpm_backdrop_selected_video';

  // ===== 旧字段（v3.11.0，只读兼容 + 写时清除） =====
  static const String kLegacyCustomBackdrop = 'bpm_custom_backdrop';
  static const String kLegacyOpVideo = 'bpm_op_video';

  /// 视频允许的扩展名（小写、无点）。
  static const List<String> videoExtensions = <String>['mp4', 'm4v'];

  /// 背景图允许的扩展名（与封面白名单一致）。
  static const List<String> imageExtensions = <String>[
    'jpg',
    'jpeg',
    'png',
    'webp',
  ];

  /// 视频体积上限（500MB，用户 2026-09-26 确认）。
  static const int maxVideoBytes = 500 * 1024 * 1024;

  static const int recommendedMaxWidth = 1920;
  static const int recommendedMaxHeight = 1080;

  // ============ 读取 ============

  /// 读 game.json 原始 map；不存在 / 损坏返回 null。
  static Map<String, dynamic>? _readJson(String metaDataDir) {
    if (metaDataDir.isEmpty) return null;
    try {
      final File f = File('$metaDataDir/${GameDataFormat.gameJsonFileName}');
      if (!f.existsSync()) return null;
      return jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// 「新键存在即用新键（含空串=明确未选）；否则回退旧键」的读取语义。
  static String _readSelected(
    Map<String, dynamic>? m,
    String newKey,
    String legacyKey,
  ) {
    if (m == null) return '';
    if (m.containsKey(newKey)) {
      return (m[newKey] as String?)?.trim() ?? '';
    }
    return (m[legacyKey] as String?)?.trim() ?? '';
  }

  static List<Map<String, dynamic>> _assetList(
    Map<String, dynamic>? m,
    String key,
  ) {
    final Object? raw = m?[key];
    if (raw is! List) return const <Map<String, dynamic>>[];
    return <Map<String, dynamic>>[
      for (final Object? e in raw)
        if (e is Map<String, dynamic>) e,
    ];
  }

  /// 背景图池（**不含封面**；旧单值字段会以「背景图 1」的名义并入）。
  static List<BpmBackdropImageAsset> readImages(String metaDataDir) {
    final Map<String, dynamic>? m = _readJson(metaDataDir);
    final List<BpmBackdropImageAsset> list = <BpmBackdropImageAsset>[
      for (final Map<String, dynamic> e in _assetList(m, kBackdropImages))
        BpmBackdropImageAsset(
          file: (e['file'] as String?)?.trim() ?? '',
          name: (e['name'] as String?)?.trim() ?? '',
        ),
    ].where((BpmBackdropImageAsset a) => a.file.isNotEmpty).toList();
    if (list.isNotEmpty) return list;

    // 兼容 v3.11.0：单值字段 → 单元素列表
    final String legacy = (m?[kLegacyCustomBackdrop] as String?)?.trim() ?? '';
    if (legacy.isNotEmpty) {
      return <BpmBackdropImageAsset>[
        BpmBackdropImageAsset(file: legacy, name: '背景图 1'),
      ];
    }
    return const <BpmBackdropImageAsset>[];
  }

  /// 背景视频池（旧单值字段会以「OP」的名义并入）。
  static List<BpmBackdropVideoAsset> readVideos(String metaDataDir) {
    final Map<String, dynamic>? m = _readJson(metaDataDir);
    final List<BpmBackdropVideoAsset> list = <BpmBackdropVideoAsset>[
      for (final Map<String, dynamic> e in _assetList(m, kBackdropVideos))
        BpmBackdropVideoAsset(
          file: (e['file'] as String?)?.trim() ?? '',
          name: (e['name'] as String?)?.trim() ?? '',
        ),
    ].where((BpmBackdropVideoAsset a) => a.file.isNotEmpty).toList();
    if (list.isNotEmpty) return list;

    final String legacy = (m?[kLegacyOpVideo] as String?)?.trim() ?? '';
    if (legacy.isNotEmpty) {
      return <BpmBackdropVideoAsset>[
        BpmBackdropVideoAsset(file: legacy, name: 'OP'),
      ];
    }
    return const <BpmBackdropVideoAsset>[];
  }

  /// 当前背景图绝对路径；空 / 使用封面 / 文件缺失 → null（调用方回退封面）。
  static String? resolveSelectedImage(String metaDataDir) {
    final String rel = _readSelected(
        _readJson(metaDataDir), kSelectedImage, kLegacyCustomBackdrop);
    if (rel.isEmpty) return null;
    final String abs = '$metaDataDir/$rel';
    return File(abs).existsSync() ? abs : null;
  }

  /// 当前背景视频绝对路径；未选 / 文件缺失 → null（不自动播放）。
  static String? resolveSelectedVideo(String metaDataDir) {
    final String rel =
        _readSelected(_readJson(metaDataDir), kSelectedVideo, kLegacyOpVideo);
    if (rel.isEmpty) return null;
    final String abs = '$metaDataDir/$rel';
    return File(abs).existsSync() ? abs : null;
  }

  /// 当前选中背景图的**相对名**（'' = 使用封面）。供 UI 高亮选中项。
  static String selectedImageRaw(String metaDataDir) => _readSelected(
      _readJson(metaDataDir), kSelectedImage, kLegacyCustomBackdrop);

  /// 当前选中背景视频的**相对名**（'' = 不自动播放）。供 UI 高亮选中项。
  static String selectedVideoRaw(String metaDataDir) =>
      _readSelected(_readJson(metaDataDir), kSelectedVideo, kLegacyOpVideo);

  // ============ 每游戏背景声音开关（v3.14，二级详情「声音」按钮） ============

  /// game.json 键：该游戏的背景视频是否静音（零迁移 merge 写入，ADR-015 同款）。
  static const String kGameMuted = 'bpm_op_video_muted';

  /// 该游戏的背景视频是否静音。
  ///
  /// 🔴 v3.18 优先级修正：
  ///   ① 该游戏在详情页显式拨过开关（`bpm_op_video_muted` 有值）→ **它说了算**；
  ///   ② 从未单独设置过 → 跟随设置页全局开关的**默认**值
  ///      （`soundEnabled=true` → 默认出声；`false` → 默认静音）。
  /// 旧实现（恒 `raw == true`，再由全局 volume=0 兜底）等于「全局静音时
  /// 详情页开关怎么拨都不出声」，与用户拍板的语义相反。
  static bool isGameMuted(String metaDataDir) {
    final Object? raw = _readJson(metaDataDir)?[kGameMuted];
    if (raw is bool) return raw;
    return !BpmOpVideoPreference.instance.soundEnabled;
  }

  /// 写入每游戏静音标记（走 `updateGameJson` merge，不升 format_version）。
  static Future<bool> setGameMuted(String metaDataDir, bool muted) {
    return GameDataFormat.updateGameJson(metaDataDir, {kGameMuted: muted});
  }

  // ============ 写入（全部顺带清空旧字段，完成一次性迁移） ============

  static List<Map<String, dynamic>> _imagesToJson(
          List<BpmBackdropImageAsset> l) =>
      <Map<String, dynamic>>[
        for (final BpmBackdropImageAsset a in l)
          <String, dynamic>{'file': a.file, 'name': a.name},
      ];

  static List<Map<String, dynamic>> _videosToJson(
          List<BpmBackdropVideoAsset> l) =>
      <Map<String, dynamic>>[
        for (final BpmBackdropVideoAsset a in l)
          <String, dynamic>{'file': a.file, 'name': a.name},
      ];

  /// 新增背景图（自动把**最后一张**设为当前背景，让用户立刻看到效果）。
  static Future<bool> addImages(
    String metaDataDir,
    List<BpmBackdropImageAsset> assets,
  ) {
    if (assets.isEmpty) return Future<bool>.value(false);
    final List<BpmBackdropImageAsset> list = <BpmBackdropImageAsset>[
      ...readImages(metaDataDir),
      ...assets,
    ];
    return GameDataFormat.updateGameJson(metaDataDir, <String, dynamic>{
      kBackdropImages: _imagesToJson(list),
      kSelectedImage: assets.last.file,
      kLegacyCustomBackdrop: null,
    });
  }

  /// 删除背景图（仅改清单；文件由调用方删除）。
  /// 若删的是当前选中项 → 回退使用封面。
  static Future<bool> removeImage(String metaDataDir, String file) {
    final List<BpmBackdropImageAsset> list = readImages(metaDataDir)
        .where((BpmBackdropImageAsset a) => a.file != file)
        .toList();
    final String selected = _readSelected(
        _readJson(metaDataDir), kSelectedImage, kLegacyCustomBackdrop);
    return GameDataFormat.updateGameJson(metaDataDir, <String, dynamic>{
      kBackdropImages: _imagesToJson(list),
      if (selected == file) kSelectedImage: '',
      kLegacyCustomBackdrop: null,
    });
  }

  static Future<bool> renameImage(
      String metaDataDir, String file, String name) {
    final List<BpmBackdropImageAsset> list = <BpmBackdropImageAsset>[
      for (final BpmBackdropImageAsset a in readImages(metaDataDir))
        a.file == file ? BpmBackdropImageAsset(file: a.file, name: name) : a,
    ];
    return GameDataFormat.updateGameJson(metaDataDir, <String, dynamic>{
      kBackdropImages: _imagesToJson(list),
      kLegacyCustomBackdrop: null,
    });
  }

  /// 选择背景图；[file] 传空串 = 使用封面。
  static Future<bool> selectImage(String metaDataDir, String file) {
    return GameDataFormat.updateGameJson(metaDataDir, <String, dynamic>{
      kSelectedImage: file,
      kLegacyCustomBackdrop: null,
    });
  }

  /// 新增背景视频（自动把**最后一个**设为当前视频）。
  static Future<bool> addVideos(
      String metaDataDir, List<BpmBackdropVideoAsset> assets) {
    if (assets.isEmpty) return Future<bool>.value(false);
    final List<BpmBackdropVideoAsset> list = <BpmBackdropVideoAsset>[
      ...readVideos(metaDataDir),
      ...assets,
    ];
    return GameDataFormat.updateGameJson(metaDataDir, <String, dynamic>{
      kBackdropVideos: _videosToJson(list),
      kSelectedVideo: assets.last.file,
      kLegacyOpVideo: null,
    });
  }

  /// 删除背景视频（仅改清单；文件由调用方删除）。
  /// 若删的是当前选中项 → 停止自动播放（selected 置空）。
  static Future<bool> removeVideo(String metaDataDir, String file) {
    final List<BpmBackdropVideoAsset> list = readVideos(metaDataDir)
        .where((BpmBackdropVideoAsset a) => a.file != file)
        .toList();
    final String selected =
        _readSelected(_readJson(metaDataDir), kSelectedVideo, kLegacyOpVideo);
    return GameDataFormat.updateGameJson(metaDataDir, <String, dynamic>{
      kBackdropVideos: _videosToJson(list),
      if (selected == file) kSelectedVideo: '',
      kLegacyOpVideo: null,
    });
  }

  static Future<bool> renameVideo(
      String metaDataDir, String file, String name) {
    final List<BpmBackdropVideoAsset> list = <BpmBackdropVideoAsset>[
      for (final BpmBackdropVideoAsset a in readVideos(metaDataDir))
        a.file == file ? BpmBackdropVideoAsset(file: a.file, name: name) : a,
    ];
    return GameDataFormat.updateGameJson(metaDataDir, <String, dynamic>{
      kBackdropVideos: _videosToJson(list),
      kLegacyOpVideo: null,
    });
  }

  /// 选择背景视频；[file] 传空串 = 不自动播放。
  static Future<bool> selectVideo(String metaDataDir, String file) {
    return GameDataFormat.updateGameJson(metaDataDir, <String, dynamic>{
      kSelectedVideo: file,
      kLegacyOpVideo: null,
    });
  }

  // ============ 校验 ============

  /// 轻量 mp4 文件头校验：第 4..8 字节应为 `ftyp` box 类型（防改名伪装）。
  static bool looksLikeMp4(String path) {
    RandomAccessFile? raf;
    try {
      raf = File(path).openSync();
      final List<int> head = raf.readSync(12);
      if (head.length < 12) return false;
      final String box = String.fromCharCodes(head.sublist(4, 8));
      return box == 'ftyp';
    } catch (_) {
      return false;
    } finally {
      try {
        raf?.closeSync();
      } catch (_) {}
    }
  }
}
