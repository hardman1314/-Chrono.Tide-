import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/path_helper.dart';
import 'unpack_plan.dart';

/// 智能解压本地存储 —— 智能解压 Phase 2
/// （方案 docs/DEV/features/join_archive_smart_unpack_plan.md §4.4/§4.6/§5）
///
/// 管理两个独立 JSON（均不进 game.json、不升 format_version，ADR-012 例外
/// 已在方案文档说明）：
/// - `data/unpack_passwords.json`：密码记忆库（用户手动输入成功的密码，
///   按「规范化文件名 + 格式」召回，LRU 上限 100 条）
/// - `data/unpack_settings.json`：后缀映射预设表
///
/// 🔴 隐私约定：密码不落明文日志（沿用 extract_manager.dart:1076-1079）；
/// 记忆库为本地明文文件，风险已在方案 §10 评估为可接受（本地单机场景）。
class UnpackStore {
  UnpackStore._();
  static final UnpackStore instance = UnpackStore._();

  static const String _passwordsFileName = 'unpack_passwords.json';
  static const String _settingsFileName = 'unpack_settings.json';
  static const int _maxEntries = 100;

  /// 内置社区默认密码表（按命中顺序轮询）。
  /// 收录口径（方案 §13）：公开教程中广泛出现的通用默认密码，不收录
  /// 需特定资源帖才能获得的密码。首项与既有硬编码默认一致（向后兼容）。
  static const List<String> builtInPasswords = [
    'Bilibili_Slpeey', // 项目既有默认密码（extract_manager 原 _defaultPassword）
    '0721', // 社区高频（多站通用教程可见）
  ];

  // ---------- 密码记忆库 ----------

  final Map<String, _PasswordEntry> _passwords = {};
  bool _passwordsLoaded = false;

  /// 记忆库键：规范化文件名（去扩展名、小写）+ 格式
  static String passwordKey(String archivePath, String format) {
    final name =
        archivePath.split('/').last.split('\\').last.toLowerCase();
    final dot = name.indexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    return '$base|$format';
  }

  /// 召回：同源包的历史成功密码（可能为空）
  String? recallPassword(String archivePath, String format) {
    _ensurePasswordsLoaded();
    return _passwords[passwordKey(archivePath, format)]?.password;
  }

  /// 全量召回：给候选队列兜底用（按 lastUsedAt 降序）
  List<String> recallAllPasswords() {
    _ensurePasswordsLoaded();
    final entries = _passwords.values.toList()
      ..sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));
    return entries.map((e) => e.password).toList();
  }

  /// 记录一次成功使用的密码（存在则更新时间戳，否则新增并做 LRU 淘汰）
  void rememberPassword(String archivePath, String format, String password) {
    _ensurePasswordsLoaded();
    final key = passwordKey(archivePath, format);
    _passwords[key] = _PasswordEntry(
      password: password,
      lastUsedAt: DateTime.now().millisecondsSinceEpoch,
    );
    while (_passwords.length > _maxEntries) {
      final oldest = _passwords.entries.reduce(
          (a, b) => a.value.lastUsedAt <= b.value.lastUsedAt ? a : b);
      _passwords.remove(oldest.key);
    }
    _savePasswords();
  }

  // ---------- 后缀映射预设表 ----------

  List<SuffixMapping> _mappings = [];
  bool _settingsLoaded = false;

  List<SuffixMapping> get mappings {
    _ensureSettingsLoaded();
    return List.unmodifiable(_mappings);
  }

  void saveMappings(List<SuffixMapping> mappings) {
    _mappings = List.of(mappings);
    _saveSettings();
  }

  /// 查映射：声明后缀 → 目标格式（精确匹配优先默认项，其次任意命中）
  SuffixMapping? lookupMapping(String declaredExt) {
    _ensureSettingsLoaded();
    final ext = declaredExt.toLowerCase();
    final hits = _mappings.where((m) => m.fromExt == ext).toList();
    if (hits.isEmpty) return null;
    return hits.firstWhere((m) => m.isDefault, orElse: () => hits.first);
  }

  // ---------- 解压预设 + 习惯记忆（2026-10-04 真机反馈） ----------
  //
  // 与 mappings 同文件（unpack_settings.json 的 'presets' 键）：
  // - 手动预设：用户为同一分享者的一类资源保存的完整解压设定
  // - 习惯记忆：解压成功后自动记录（auto=true），按 signature 去重、
  //   LRU 上限 10 条；打开计划窗时按首层格式匹配预填

  static const int _maxHabits = 10;

  List<UnpackPreset> _presets = [];

  /// 手动预设在前（按 lastUsedAt 降序），习惯记忆在后
  List<UnpackPreset> get presets {
    _ensureSettingsLoaded();
    final manual = _presets.where((p) => !p.auto).toList()
      ..sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));
    final habits = _presets.where((p) => p.auto).toList()
      ..sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));
    return [...manual, ...habits];
  }

  /// 保存/更新预设（按名称 upsert）
  void savePreset(UnpackPreset preset) {
    _ensureSettingsLoaded();
    _presets.removeWhere((p) => p.name == preset.name);
    _presets.add(preset);
    _saveSettings();
  }

  void deletePreset(String name) {
    _ensureSettingsLoaded();
    _presets.removeWhere((p) => p.name == name);
    _saveSettings();
  }

  /// 记录一次成功解压的习惯（按 signature 去重更新，LRU 上限 10）
  void recordHabit(UnpackPreset habit) {
    _ensureSettingsLoaded();
    final existing = _presets
        .where((p) => p.auto && p.signature == habit.signature)
        .toList();
    if (existing.isNotEmpty) {
      _presets.remove(existing.first);
    }
    _presets.add(habit);
    // LRU 淘汰最旧的习惯（只淘汰 auto，不动用户手动预设）
    final habits =
        _presets.where((p) => p.auto).toList()
          ..sort((a, b) => a.lastUsedAt.compareTo(b.lastUsedAt));
    while (habits.length > _maxHabits) {
      _presets.remove(habits.removeAt(0));
    }
    _saveSettings();
  }

  /// 习惯建议：与首层格式匹配的最近习惯（无则 null）。
  /// 首层格式比对兼容双嵌套：探测 'lz4' 匹配设定 'lz4+X' 的壳层。
  UnpackPreset? suggestHabit(String firstLayerRealFormat) {
    _ensureSettingsLoaded();
    UnpackPreset? best;
    for (final p in _presets.where((p) => p.auto && p.layers.isNotEmpty)) {
      final f = p.layers.first.format;
      final matches = f == firstLayerRealFormat ||
          (f.startsWith('lz4+') && firstLayerRealFormat == 'lz4');
      if (matches && (best == null || p.lastUsedAt > best.lastUsedAt)) {
        best = p;
      }
    }
    return best;
  }

  // ---------- 密码组（2026-10-05 需求：去层级化 + 记忆策略） ----------
  //
  // 与 mappings 同文件（unpack_settings.json 的 'password_groups' 键）。
  // 密码以「组」为单位管理，组内密码的关联性整体保留、不可拆散盲试：
  // - 预设组（auto=false）：用户手动保存的常用密码组（如某分享者的全套密码）
  // - 历史组（auto=true）：解压成功后自动记录，按签名去重、LRU 上限 10
  // - 密码库 = 预设组 ∪ 历史组 ∪ 本包记忆 ∪ 内置表（去重汇总，保底兜底）

  static const int _maxHistoryGroups = 10;

  List<PasswordGroup> _passwordGroups = [];

  /// 预设组在前（按 lastUsedAt 降序），历史组在后
  List<PasswordGroup> get passwordGroups {
    _ensureSettingsLoaded();
    final manual = _passwordGroups.where((g) => !g.auto).toList()
      ..sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));
    final history = _passwordGroups.where((g) => g.auto).toList()
      ..sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));
    return [...manual, ...history];
  }

  /// 保存/更新预设密码组（按名称 upsert）
  void savePasswordGroup(PasswordGroup group) {
    _ensureSettingsLoaded();
    _passwordGroups.removeWhere((g) => g.name == group.name);
    _passwordGroups.add(group);
    _saveSettings();
  }

  /// 删除密码组（预设/历史均可删，按名称）
  void deletePasswordGroup(String name) {
    _ensureSettingsLoaded();
    _passwordGroups.removeWhere((g) => g.name == name);
    _saveSettings();
  }

  /// 记录一次成功解压的密码组（历史组，按签名去重更新，LRU 上限 10）。
  /// 空组忽略；签名只与历史组比对（用户手动预设不参与去重）。
  void recordPasswordGroupHistory(List<String> passwords) {
    final valid = passwords.where((p) => p.isNotEmpty).toList();
    if (valid.isEmpty) return;
    _ensureSettingsLoaded();
    final group = PasswordGroup(
      name: '历史 ${DateTime.now().toIso8601String().substring(0, 10)}',
      passwords: valid,
      auto: true,
      lastUsedAt: DateTime.now().millisecondsSinceEpoch,
    );
    final existing = _passwordGroups
        .where((g) => g.auto && g.signature == group.signature)
        .toList();
    if (existing.isNotEmpty) {
      _passwordGroups.remove(existing.first);
    }
    _passwordGroups.add(group);
    final history = _passwordGroups.where((g) => g.auto).toList()
      ..sort((a, b) => a.lastUsedAt.compareTo(b.lastUsedAt));
    while (history.length > _maxHistoryGroups) {
      _passwordGroups.remove(history.removeAt(0));
    }
    _saveSettings();
  }

  /// 密码库：全部密码组（预设+历史）+ 本包记忆库 + 内置表，去重保序汇总。
  /// 候选队列最后一级保底（strategy：本次输入 → 预设组 → 历史组 → 密码库）。
  List<String> get passwordLibrary {
    final lib = <String>[];
    for (final g in passwordGroups) {
      lib.addAll(g.passwords);
    }
    lib.addAll(recallAllPasswords());
    lib.addAll(builtInPasswords);
    final seen = <String>{};
    return [for (final p in lib) if (p.isNotEmpty && seen.add(p)) p];
  }

  // ---------- 持久化 ----------

  String get _passwordsPath =>
      '${PathHelper.dataDir}/$_passwordsFileName';
  String get _settingsPath => '${PathHelper.dataDir}/$_settingsFileName';

  void _ensurePasswordsLoaded() {
    if (_passwordsLoaded) return;
    _passwordsLoaded = true;
    try {
      final f = File(_passwordsPath);
      if (!f.existsSync()) return;
      final data = jsonDecode(f.readAsStringSync());
      final list = data['entries'] as List? ?? [];
      for (final e in list) {
        final password = e['password'] as String?;
        final key = e['key'] as String?;
        if (password == null || password.isEmpty || key == null) continue;
        _passwords[key] = _PasswordEntry(
          password: password,
          lastUsedAt: e['lastUsedAt'] as int? ?? 0,
        );
      }
    } catch (e) {
      debugPrint('[UNPACK-STORE] 密码库读取失败（按空处理）: $e');
    }
  }

  void _savePasswords() {
    try {
      final dir = Directory(PathHelper.dataDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final json = {
        'version': 1,
        'entries': _passwords.entries
            .map((e) => {
                  'key': e.key,
                  'password': e.value.password,
                  'lastUsedAt': e.value.lastUsedAt,
                })
            .toList(),
      };
      File(_passwordsPath).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(json),
      );
    } catch (e) {
      debugPrint('[UNPACK-STORE] 密码库写入失败: $e');
    }
  }

  void _ensureSettingsLoaded() {
    if (_settingsLoaded) return;
    _settingsLoaded = true;
    try {
      final f = File(_settingsPath);
      if (!f.existsSync()) return;
      final data = jsonDecode(f.readAsStringSync());
      final list = data['mappings'] as List? ?? [];
      _mappings = list
          .map((e) => SuffixMapping.fromJson(e as Map<String, dynamic>))
          .toList();
      final presetList = data['presets'] as List? ?? [];
      _presets = presetList
          .map((e) => UnpackPreset.fromJson(e as Map<String, dynamic>))
          .where((p) => p.name.isNotEmpty)
          .toList();
      final chains = data['auto_try_chains'] as Map<String, dynamic>?;
      _autoTryChains = chains?.map((k, v) => MapEntry(
          k.toLowerCase(),
          (v as List).map((e) => e.toString()).toList()));
      final groupList = data['password_groups'] as List? ?? [];
      _passwordGroups = groupList
          .map((e) => PasswordGroup.fromJson(e as Map<String, dynamic>))
          .toList();
      final ruleList = data['ambiguity_rules'] as List?;
      _ambiguityRules = ruleList
          ?.map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      final body = data['body_rules'] as Map<String, dynamic>?;
      if (body != null) _bodyRules = BodyRules.fromJson(body);
    } catch (e) {
      debugPrint('[UNPACK-STORE] 映射表读取失败（按空处理）: $e');
    }
  }

  void _saveSettings() {
    try {
      final dir = Directory(PathHelper.dataDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final json = {
        'version': 1,
        'mappings': _mappings.map((m) => m.toJson()).toList(),
        'presets': _presets.map((p) => p.toJson()).toList(),
        'password_groups':
            _passwordGroups.map((g) => g.toJson()).toList(),
        if (_autoTryChains != null) 'auto_try_chains': _autoTryChains,
        if (_ambiguityRules != null) 'ambiguity_rules': _ambiguityRules,
        if (_bodyRules != null) 'body_rules': _bodyRules!.toJson(),
      };
      File(_settingsPath).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(json),
      );
    } catch (e) {
      debugPrint('[UNPACK-STORE] 映射表写入失败: $e');
    }
  }

  // ---------- 未知后缀自动尝试候选链（Phase B / scenarios_v2 §1.4） ----------

  /// 默认候选链表（2026-10-05 需求对齐：常见伪装后缀的自动改名链，顺序
  /// = 优先级，从左到右依次试解）。空后缀 '' 一并内置。表外后缀不自动
  /// 尝试（保守默认，防把真实游戏资源当包硬解）。
  /// 用户自定义覆盖：unpack_settings.json 的 'auto_try_chains' 键
  /// （UI 入口 = 解压计划窗「后缀」板块）。
  static const Map<String, List<String>> _defaultAutoTryChains = {
    // 视频（需求方给定顺序）
    '.mp4': ['zip', 'rar', '7z', 'enc'],
    '.mov': ['enc', 'zip', 'rar', '7z'],
    '.mkv': ['zip', 'rar', '7z'],
    '.avi': ['zip', 'rar', '7z'],
    '.flv': ['zip', 'rar', '7z'],
    '.wmv': ['zip', 'rar', '7z'],
    // 音频
    '.mp3': ['zip', 'rar', '7z'],
    '.wav': ['zip', 'rar', '7z'],
    '.flac': ['zip', 'rar', '7z'],
    // 文本/图片（伪装高频形态）
    '.txt': ['rar', 'zip', 'enc', '7z'],
    '.png': ['zip', 'rar'],
    '.jpg': ['zip', 'rar'],
    '.jpeg': ['zip', 'rar'],
    // 程序/数据
    '.exe': ['rar', 'zip', 'enc', '7z'],
    '.dat': ['zip', 'rar', '7z'],
    // 空后缀文件（需求方指定）
    '': ['zip', 'rar', '7z', 'enc'],
  };

  /// 内置链只读视图（计划窗「后缀」板块展示用）
  static Map<String, List<String>> get defaultAutoTryChains =>
      Map.unmodifiable(_defaultAutoTryChains);

  Map<String, List<String>>? _autoTryChains;

  /// 用户自定义覆盖链只读视图（null = 尚无任何自定义；空表项 = 已恢复默认）
  Map<String, List<String>>? get customAutoTryChains =>
      _autoTryChains == null
          ? null
          : Map.unmodifiable(_autoTryChains!);

  /// 查后缀的自动尝试候选链（用户配置优先，默认表兜底；表外 → 空表）。
  /// 注意：返回的链可能含 'enc'——是否可试（有无密码源）由调用方过滤。
  List<String> autoTryChainFor(String declaredExt) {
    _ensureSettingsLoaded();
    final ext = declaredExt.toLowerCase();
    final custom = _autoTryChains?[ext];
    if (custom != null && custom.isNotEmpty) return List.of(custom);
    return List.of(_defaultAutoTryChains[ext] ?? const []);
  }

  /// 覆盖某后缀的候选链（持久化；传空表 = 删除覆盖、恢复默认）
  void setAutoTryChain(String declaredExt, List<String> chain) {
    _ensureSettingsLoaded();
    final ext = declaredExt.toLowerCase();
    final map = _autoTryChains ??= {};
    if (chain.isEmpty) {
      map.remove(ext);
    } else {
      map[ext] = List.of(chain);
    }
    _saveSettings();
  }

  // ---------- 多文件歧义推荐规则（Phase D / scenarios_v2 §1.2） ----------

  /// 内置推荐规则 id：多数同后缀 + 唯一异类（matcher 实现随 id 硬编码
  /// 在 extract_manager._recommendCandidate；本表只管启停/优先级，UI
  /// 编辑器预留 P2）。
  static const String majorityOutlierRuleId = 'majority_outlier';

  List<Map<String, dynamic>>? _ambiguityRules;

  /// 查歧义推荐规则是否启用（未持久化过 = 内置规则默认启用）
  bool isAmbiguityRuleEnabled(String id) {
    _ensureSettingsLoaded();
    final rules = _ambiguityRules;
    if (rules == null) return true;
    for (final r in rules) {
      if (r['id'] == id) return r['enabled'] == true;
    }
    return true;
  }

  /// 启停某条歧义推荐规则（持久化）
  void setAmbiguityRuleEnabled(String id, bool enabled) {
    _ensureSettingsLoaded();
    final rules = _ambiguityRules ??= [];
    final i = rules.indexWhere((r) => r['id'] == id);
    if (i >= 0) {
      rules[i] = {...rules[i], 'enabled': enabled};
    } else {
      rules.add({'id': id, 'enabled': enabled});
    }
    _saveSettings();
  }

  // ---------- 游戏本体识别规则（Phase E / scenarios_v2 §1.3） ----------

  /// 默认本体判定阈值：顶层子目录 ≥1 或 非说明散文件 ≥2 即视为已到达本体
  /// （说明文件按 readmeExts 排除，不参与计数）。用户可在 unpack_settings.json
  /// 的 'body_rules' 键覆盖。
  static const BodyRules _defaultBodyRules = BodyRules();

  BodyRules? _bodyRules;

  BodyRules get bodyRules {
    _ensureSettingsLoaded();
    return _bodyRules ?? _defaultBodyRules;
  }

  /// 覆盖本体识别规则（持久化）
  void setBodyRules(BodyRules rules) {
    _ensureSettingsLoaded();
    _bodyRules = rules;
    _saveSettings();
  }
}

class _PasswordEntry {
  const _PasswordEntry({required this.password, required this.lastUsedAt});
  final String password;
  final int lastUsedAt;
}

/// ★ Phase E（scenarios_v2 §1.3）：游戏本体识别规则
/// （unpack_settings.json 'body_rules' 键，缺省值走常量默认）。
class BodyRules {
  /// 顶层子目录数达标阈值
  final int minSubdirs;

  /// 顶层非说明散文件数达标阈值
  final int minLooseFiles;

  /// 说明类文件后缀（小写含点）——不计入散文件数（防止 exe+说明txt
  /// 组合被误判为本体目录结构）
  final List<String> readmeExts;

  const BodyRules({
    this.minSubdirs = 1,
    this.minLooseFiles = 2,
    this.readmeExts = const [
      '.txt',
      '.url',
      '.chm',
      '.html',
      '.htm',
      '.pdf',
      '.ini',
      '.jpg',
      '.png',
      '.gif',
    ],
  });

  factory BodyRules.fromJson(Map<String, dynamic> json) => BodyRules(
        minSubdirs: json['minSubdirs'] as int? ?? 1,
        minLooseFiles: json['minLooseFiles'] as int? ?? 2,
        readmeExts: (json['readmeExts'] as List?)
                ?.map((e) => e.toString().toLowerCase())
                .toList() ??
            const [
              '.txt',
              '.url',
              '.chm',
              '.html',
              '.htm',
              '.pdf',
              '.ini',
              '.jpg',
              '.png',
              '.gif',
            ],
      );

  Map<String, dynamic> toJson() => {
        'minSubdirs': minSubdirs,
        'minLooseFiles': minLooseFiles,
        'readmeExts': readmeExts,
      };
}

/// 密码组 —— 以「组」为整体管理的密码集合（2026-10-05 需求）。
///
/// 组内密码的关联性必须整体保留（同一分享者的全套密码按序尝试），
/// 不可拆散成单个密码盲试。[auto] = true 表示系统历史记录组。
class PasswordGroup {
  const PasswordGroup({
    required this.name,
    required this.passwords,
    this.auto = false,
    this.lastUsedAt = 0,
  });

  final String name;
  final List<String> passwords;

  /// true = 历史记录组（自动生成）；false = 用户手动预设
  final bool auto;
  final int lastUsedAt;

  /// 去重签名：组内密码序列（与顺序相关）
  String get signature => passwords.join('\u0000');

  Map<String, dynamic> toJson() => {
        'name': name,
        'auto': auto,
        'lastUsedAt': lastUsedAt,
        'passwords': passwords,
      };

  factory PasswordGroup.fromJson(Map<String, dynamic> json) => PasswordGroup(
        name: json['name'] as String? ?? '',
        auto: json['auto'] as bool? ?? false,
        lastUsedAt: json['lastUsedAt'] as int? ?? 0,
        passwords: ((json['passwords'] as List?) ?? [])
            .map((e) => e.toString())
            .where((p) => p.isNotEmpty)
            .toList(),
      );
}
