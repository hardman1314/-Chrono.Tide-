/// 解压计划数据模型 —— 智能解压 Phase 2
/// （方案 docs/DEV/features/join_archive_smart_unpack_plan.md §4.2/§4.5/§4.6）
///
/// 核心语义：
/// - [ArchiveLayer] 描述「一层压缩包」：第 0 层 = 用户拖入的文件；
///   第 N 层（N>0）= 解压第 N-1 层后在产物中发现的嵌套压缩包
///   （[ArchiveLayer.sourceEntryPath] 为其在产物中的相对路径，
///   解压落定前该文件尚不存在——加密文件名包开始前摸不穿内容，
///   计划树按「内容未知」展示，执行期靠产物重扫续链，Phase 0 T2 实测依据）。
/// - [SuffixMapping] 是「后缀映射策略」：解压不依赖文件名（Phase 0 T14
///   实测 7z 后缀免疫），映射仅用于展示与魔数识别失败时的兜底判定，
///   不真实重命名盘上文件。
/// - 密码候选队列在执行期组装：层密码 → [UnpackPlan.passwordSequence]
///   按层预设 → 记忆库 → 内置表 → 手动输入（见 UnpackStore / ExtractManager）。
library;

class ArchiveLayer {
  const ArchiveLayer({
    required this.layerIndex,
    required this.realFormat,
    required this.declaredExt,
    this.disguised = false,
    this.needsPassword = false,
    this.passwordKnown = false,
    this.contentKnown = true,
    this.sourceEntryPath,
    this.sizeBytes,
  });

  /// 层序号：0 = 用户拖入的源文件；1+ = 嵌套层
  final int layerIndex;

  /// 真实格式（'zip'/'7z'/'rar'/'lz4'/'zst'/'gz'/'bz2'/'xz'/'cab'/'arj'/'iso'/'tar'）
  final String realFormat;

  /// 声明后缀（小写含点；多层如 '.zip.lz4' 原样）
  final String declaredExt;

  /// 是否伪装包（魔数与声明后缀不符）
  final bool disguised;

  /// 是否确定加密（探测期 7z l 报 "Cannot open encrypted archive"）
  final bool needsPassword;

  /// 探测期是否已知晓密码（记忆库命中/用户已填）
  final bool passwordKnown;

  /// 内容清单是否可列（加密文件名包 = false，Phase 0 T2）
  final bool contentKnown;

  /// 嵌套包在上一层产物中的相对路径（第 0 层为 null）
  final String? sourceEntryPath;

  /// 申报体积（7z l 汇总，zip 炸弹预检用；未知为 null）
  final int? sizeBytes;

  ArchiveLayer copyWith({
    bool? passwordKnown,
    bool? needsPassword,
    int? sizeBytes,
  }) {
    return ArchiveLayer(
      layerIndex: layerIndex,
      realFormat: realFormat,
      declaredExt: declaredExt,
      disguised: disguised,
      needsPassword: needsPassword ?? this.needsPassword,
      passwordKnown: passwordKnown ?? this.passwordKnown,
      contentKnown: contentKnown,
      sourceEntryPath: sourceEntryPath,
      sizeBytes: sizeBytes ?? this.sizeBytes,
    );
  }
}

/// 后缀映射策略：声明后缀 → 目标压缩格式（逻辑映射，不碰盘上文件名）
class SuffixMapping {
  const SuffixMapping({
    required this.fromExt,
    required this.toFormat,
    this.isDefault = false,
    this.layerIndex = -1,
  });

  final String fromExt; // '.mp4'
  final String toFormat; // 'zip'
  final bool isDefault; // 该后缀的默认目标格式

  /// -1 = 通用（所有层）；0 = 第 1 层；1 = 第 2 层……
  /// 分层语义（2026-10-04 真机反馈）：同一后缀在不同层可能要映射成
  /// 不同目标格式（第1层 .mp4→zip、第2层 .mp4→rar），通用映射会失效。
  final int layerIndex;

  Map<String, dynamic> toJson() => {
        'fromExt': fromExt,
        'toFormat': toFormat,
        'isDefault': isDefault,
        'layerIndex': layerIndex,
      };

  factory SuffixMapping.fromJson(Map<String, dynamic> json) => SuffixMapping(
        fromExt: (json['fromExt'] as String? ?? '').toLowerCase(),
        toFormat: (json['toFormat'] as String? ?? '').toLowerCase(),
        isDefault: json['isDefault'] as bool? ?? false,
        layerIndex: json['layerIndex'] as int? ?? -1,
      );
}

/// 预设中的一层：该层格式 + 该层密码。
///
/// [format] 允许「双嵌套」复合格式：'lz4+zip' / 'lz4+rar' / 'lz4+7z'
/// （用户视角的一层 = 执行器的两层：先剥 lz4 壳无密码，再解内层 X 用密码）。
class PresetLayer {
  const PresetLayer({required this.format, this.password = ''});

  final String format;
  final String password;

  Map<String, dynamic> toJson() => {'format': format, 'password': password};

  factory PresetLayer.fromJson(Map<String, dynamic> json) => PresetLayer(
        format: json['format'] as String? ?? 'zip',
        password: json['password'] as String? ?? '',
      );
}

/// 解压预设 —— 用户为「同一分享者」的一类资源保存的可复用解压设定
/// （分层密码 + 分层后缀映射 + 解压位置）。
///
/// [auto] = true 表示系统根据用户历史成功操作自动记录的「习惯记忆」，
/// 与手动保存的预设共用一个列表。
class UnpackPreset {
  const UnpackPreset({
    required this.name,
    required this.layers,
    this.mappings = const [],
    this.extractToSource = true,
    this.auto = false,
    this.lastUsedAt = 0,
  });

  final String name;
  final List<PresetLayer> layers;
  final List<SuffixMapping> mappings;
  final bool extractToSource;

  /// true = 习惯记忆（自动生成）；false = 用户手动保存的预设
  final bool auto;
  final int lastUsedAt;

  /// 习惯去重签名：层格式序列 + 映射 + 位置（不含密码——同一结构
  /// 换密码视为同一习惯，密码随最近一次成功操作更新）。
  String get signature {
    final layerPart = layers.map((l) => l.format).join('>');
    final mapPart = mappings
        .map((m) => '${m.layerIndex}:${m.fromExt}->${m.toFormat}')
        .join(',');
    return '$layerPart|$mapPart|$extractToSource';
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'auto': auto,
        'lastUsedAt': lastUsedAt,
        'extractToSource': extractToSource,
        'layers': layers.map((l) => l.toJson()).toList(),
        'mappings': mappings.map((m) => m.toJson()).toList(),
      };

  factory UnpackPreset.fromJson(Map<String, dynamic> json) => UnpackPreset(
        name: json['name'] as String? ?? '',
        auto: json['auto'] as bool? ?? false,
        lastUsedAt: json['lastUsedAt'] as int? ?? 0,
        extractToSource: json['extractToSource'] as bool? ?? true,
        layers: ((json['layers'] as List?) ?? [])
            .map((e) => PresetLayer.fromJson(e as Map<String, dynamic>))
            .toList(),
        mappings: ((json['mappings'] as List?) ?? [])
            .map((e) => SuffixMapping.fromJson(e as Map<String, dynamic>))
            .toList(),
      );

  /// 把预设层展开为「执行器逐层密码序列」（下标 = 执行器层序号）。
  ///
  /// 双嵌套层 'lz4+X' 展开为两格：lz4 壳层无密码（''）+ 内层 X 密码；
  /// 单格式层占一格。执行器按层序号取密码（extract_manager.dart
  /// passwordSequence[layerIdx]），探测层少于设定层时（加密文件名包
  /// 摸不穿）多余项由执行器动态续层时消费。
  static List<String> expandPasswordSequence(List<PresetLayer> layers) {
    final seq = <String>[];
    for (final l in layers) {
      if (l.format.startsWith('lz4+')) {
        seq.add(''); // lz4 壳层：无密码
        seq.add(l.password);
      } else {
        seq.add(l.password);
      }
    }
    return seq;
  }
}

/// 一次「拖入压缩包 → 一键解压」的完整计划
class UnpackPlan {
  const UnpackPlan({
    required this.sourcePath,
    required this.layers,
    this.suffixMappings = const [],
    this.passwordSequence = const [],
    this.warnings = const [],
    this.firstVolumePath,
  });

  /// 用户拖入的源压缩包绝对路径（第 0 层）
  final String sourcePath;

  /// ★ Phase C（join_unpack_scenarios_v2.md §1.1）：分卷组解压入口（首卷/
  /// 主卷）。null = 非分卷（解压入口即 [sourcePath]）；非空时执行期喂首卷，
  /// 7z 自行查找同目录其余卷（要求全组同目录，与默认解压位置一致）。
  final String? firstVolumePath;

  /// 层级树（按 layerIndex 升序）
  final List<ArchiveLayer> layers;

  /// 后缀映射预设（弹窗可编辑；来自 UnpackSettings）
  final List<SuffixMapping> suffixMappings;

  /// 用户按层预设的密码序列（下标 = 层序号）
  final List<String> passwordSequence;

  /// 探测期警告（加密摸不穿 / 映射表未命中 / 磁盘预算等），弹窗展示
  final List<String> warnings;
}
