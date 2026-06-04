// Ludusavi 兼容的存档清单解析器
// 数据来源: https://raw.githubusercontent.com/mtkennerly/ludusavi-manifest/master/data/manifest.yaml
// ============================================================================

/// 路径占位符常量，与 Ludusavi manifest placeholder 一一对应
class Placeholder {
  static const root = '<root>';
  static const game = '<game>';
  static const base = '<base>';
  static const home = '<home>';
  static const storeGameId = '<storeGameId>';
  static const storeUserId = '<storeUserId>';
  static const osUserName = '<osUserName>';
  static const winAppData = '<winAppData>';
  static const winLocalAppData = '<winLocalAppData>';
  static const winLocalAppDataLow = '<winLocalAppDataLow>';
  static const winDocuments = '<winDocuments>';
  static const winPublic = '<winPublic>';
  static const winProgramData = '<winProgramData>';
  static const winDir = '<winDir>';
  static const xdgData = '<xdgData>';
  static const xdgConfig = '<xdgConfig>';

  /// 所有占位符列表
  static const all = [
    root,
    game,
    base,
    home,
    storeGameId,
    storeUserId,
    osUserName,
    winAppData,
    winLocalAppData,
    winLocalAppDataLow,
    winDocuments,
    winPublic,
    winProgramData,
    winDir,
    xdgData,
    xdgConfig,
  ];
}

/// 操作系统枚举
enum ManifestOs {
  windows,
  linux,
  mac,
  other;

  static ManifestOs fromString(String value) {
    switch (value.toLowerCase()) {
      case 'windows':
        return ManifestOs.windows;
      case 'linux':
        return ManifestOs.linux;
      case 'mac':
      case 'macos':
        return ManifestOs.mac;
      default:
        return ManifestOs.other;
    }
  }
}

/// 商店/平台枚举
enum ManifestStore {
  ea,
  epic,
  gog,
  gogGalaxy,
  heroic,
  legendary,
  lutris,
  microsoft,
  origin,
  prime,
  steam,
  uplay,
  otherHome,
  otherWine,
  otherWindows,
  otherLinux,
  otherMac,
  other;

  static ManifestStore fromString(String value) {
    switch (value.toLowerCase()) {
      case 'ea':
        return ManifestStore.ea;
      case 'epic':
        return ManifestStore.epic;
      case 'gog':
        return ManifestStore.gog;
      case 'goggalaxy':
        return ManifestStore.gogGalaxy;
      case 'heroic':
        return ManifestStore.heroic;
      case 'legendary':
        return ManifestStore.legendary;
      case 'lutris':
        return ManifestStore.lutris;
      case 'microsoft':
        return ManifestStore.microsoft;
      case 'origin':
        return ManifestStore.origin;
      case 'prime':
        return ManifestStore.prime;
      case 'steam':
        return ManifestStore.steam;
      case 'uplay':
        return ManifestStore.uplay;
      case 'otherhome':
        return ManifestStore.otherHome;
      case 'otherwine':
        return ManifestStore.otherWine;
      case 'otherwindows':
        return ManifestStore.otherWindows;
      case 'otherlinux':
        return ManifestStore.otherLinux;
      case 'othermac':
        return ManifestStore.otherMac;
      default:
        return ManifestStore.other;
    }
  }
}

/// 文件标签：save / config / other
enum ManifestTag {
  save,
  config,
  other;

  static ManifestTag fromString(String value) {
    switch (value.toLowerCase()) {
      case 'save':
        return ManifestTag.save;
      case 'config':
        return ManifestTag.config;
      default:
        return ManifestTag.other;
    }
  }
}

/// 文件条件约束（when 子句）
class ManifestCondition {
  final ManifestOs? os;
  final ManifestStore? store;

  const ManifestCondition({this.os, this.store});

  /// 判断当前条件是否满足
  bool matches({ManifestOs? currentOs, ManifestStore? currentStore}) {
    if (os != null && currentOs != null && os != currentOs) {
      return false;
    }
    if (store != null && currentStore != null && store != currentStore) {
      return false;
    }
    return true;
  }

  @override
  String toString() => 'ManifestCondition(os: $os, store: $store)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ManifestCondition && os == other.os && store == other.store;

  @override
  int get hashCode => Object.hash(os, store);
}

/// 文件条目：包含标签和条件
class ManifestFileEntry {
  final Set<ManifestTag> tags;
  final List<ManifestCondition> when;

  const ManifestFileEntry({this.tags = const {}, this.when = const []});

  /// 是否包含指定标签
  bool hasTag(ManifestTag tag) => tags.contains(tag);

  /// 是否为存档文件
  bool get isSave => tags.contains(ManifestTag.save);

  /// 是否为配置文件
  bool get isConfig => tags.contains(ManifestTag.config);

  /// 判断条件是否满足
  bool matchesConditions({ManifestOs? os, ManifestStore? store}) {
    if (when.isEmpty) return true;
    return when.any((c) => c.matches(currentOs: os, currentStore: store));
  }

  @override
  String toString() => 'ManifestFileEntry(tags: $tags, when: $when)';
}

/// 注册表条目
class ManifestRegistryEntry {
  final Set<ManifestTag> tags;
  final List<ManifestCondition> when;

  const ManifestRegistryEntry({this.tags = const {}, this.when = const []});

  bool hasTag(ManifestTag tag) => tags.contains(tag);

  bool matchesConditions({ManifestStore? store}) {
    if (when.isEmpty) return true;
    return when.any((c) => c.matches(currentStore: store));
  }

  @override
  String toString() => 'ManifestRegistryEntry(tags: $tags, when: $when)';
}

/// Steam 元数据
class SteamMetadata {
  final int? id;

  const SteamMetadata({this.id});

  bool get isEmpty => id == null;
  bool get isNotEmpty => !isEmpty;

  @override
  String toString() => 'SteamMetadata(id: $id)';
}

/// GOG 元数据
class GogMetadata {
  final int? id;

  const GogMetadata({this.id});

  bool get isEmpty => id == null;
  bool get isNotEmpty => !isEmpty;

  @override
  String toString() => 'GogMetadata(id: $id)';
}

/// 额外 ID 元数据
class IdMetadata {
  final String? flatpak;
  final Set<int> gogExtra;
  final String? lutris;
  final Set<int> steamExtra;

  const IdMetadata({
    this.flatpak,
    this.gogExtra = const {},
    this.lutris,
    this.steamExtra = const {},
  });

  bool get isEmpty =>
      flatpak == null &&
      gogExtra.isEmpty &&
      lutris == null &&
      steamExtra.isEmpty;

  @override
  String toString() =>
      'IdMetadata(flatpak: $flatpak, gogExtra: $gogExtra, lutris: $lutris, steamExtra: $steamExtra)';
}

/// 云存档元数据
class CloudMetadata {
  final bool epic;
  final bool gog;
  final bool origin;
  final bool steam;
  final bool uplay;

  const CloudMetadata({
    this.epic = false,
    this.gog = false,
    this.origin = false,
    this.steam = false,
    this.uplay = false,
  });

  bool get isEmpty => !epic && !gog && !origin && !steam && !uplay;

  @override
  String toString() =>
      'CloudMetadata(epic: $epic, gog: $gog, origin: $origin, steam: $steam, uplay: $uplay)';
}

/// 清单中的单个游戏条目
class ManifestGame {
  /// 游戏名称（键名）
  final String name;

  /// 别名：指向另一个游戏条目，表示此名称是另一个游戏的别名
  final String? alias;

  /// 文件路径 -> 文件条目
  final Map<String, ManifestFileEntry> files;

  /// 注册表路径 -> 注册表条目
  final Map<String, ManifestRegistryEntry> registry;

  /// 安装目录映射
  final Map<String, Map<String, dynamic>> installDirs;

  /// Steam 元数据
  final SteamMetadata steam;

  /// GOG 元数据
  final GogMetadata gog;

  /// 额外 ID
  final IdMetadata id;

  /// 云存档支持
  final CloudMetadata cloud;

  /// 备注信息
  final List<String> notes;

  const ManifestGame({
    required this.name,
    this.alias,
    this.files = const {},
    this.registry = const {},
    this.installDirs = const {},
    this.steam = const SteamMetadata(),
    this.gog = const GogMetadata(),
    this.id = const IdMetadata(),
    this.cloud = const CloudMetadata(),
    this.notes = const [],
  });

  /// 是否为别名条目（alias 非空表示此条目指向另一个游戏）
  bool get isAlias => alias != null;

  /// 是否有可处理的存档数据
  bool get hasSaveData =>
      files.isNotEmpty ||
      registry.isNotEmpty ||
      steam.isNotEmpty ||
      gog.isNotEmpty ||
      !id.isEmpty;

  /// 获取所有 Steam ID（主 ID + 额外 ID）
  List<int> get allSteamIds {
    final ids = <int>[];
    if (steam.id != null) ids.add(steam.id!);
    ids.addAll(id.steamExtra);
    return ids;
  }

  /// 获取所有 GOG ID（主 ID + 额外 ID）
  List<int> get allGogIds {
    final ids = <int>[];
    if (gog.id != null) ids.add(gog.id!);
    ids.addAll(id.gogExtra);
    return ids;
  }

  @override
  String toString() => 'ManifestGame(name: $name, alias: $alias, '
      'files: ${files.length}, registry: ${registry.length})';
}

// ============================================================================
// 简易 YAML 解析器
// 专门处理 Ludusavi manifest.yaml 格式：
// - 顶层为游戏名 -> 游戏数据的映射
// - 游戏数据包含嵌套的 map 和 list
// - 键名可能包含特殊字符（引号包裹）
// ============================================================================

/// 简易 YAML 解析器，将 YAML 文本解析为 Dart 原生数据结构
/// 支持：嵌套 map、list、带引号的键/值、多行值
class _SimpleYamlParser {
  final String input;
  int _pos = 0;

  _SimpleYamlParser(this.input);

  /// 解析入口
  dynamic parse() {
    _skipBom();
    _skipDocumentStart();
    _skipBlankLinesAndComments();
    return _parseValue(0);
  }

  /// 跳过 BOM 标记
  void _skipBom() {
    if (_pos < input.length && input.codeUnitAt(_pos) == 0xFEFF) {
      _pos++;
    }
  }

  /// 跳过 --- 文档起始标记
  void _skipDocumentStart() {
    _skipWhitespace();
    if (_pos < input.length && input.substring(_pos).startsWith('---')) {
      _pos += 3;
      _skipToEndOfLine();
    }
  }

  /// 跳过空白行和注释
  void _skipBlankLinesAndComments() {
    while (_pos < input.length) {
      _skipWhitespace();
      if (_pos >= input.length) break;
      if (_ch == '\n') {
        _pos++;
        continue;
      }
      if (_ch == '#') {
        _skipToEndOfLine();
        continue;
      }
      break;
    }
  }

  /// 跳过当前行剩余内容
  void _skipToEndOfLine() {
    while (_pos < input.length && _ch != '\n') {
      _pos++;
    }
    if (_pos < input.length) _pos++; // 跳过换行符
  }

  /// 跳过行首空白（不含换行）
  void _skipWhitespace() {
    while (_pos < input.length && (_ch == ' ' || _ch == '\t')) {
      _pos++;
    }
  }

  /// 当前字符
  String get _ch => input[_pos];

  /// 查看下一个字符
  String? get _nextCh => (_pos + 1 < input.length) ? input[_pos + 1] : null;

  /// 计算当前行的缩进级别
  int _currentIndent() {
    int i = _pos;
    int indent = 0;
    while (i > 0 && input[i - 1] != '\n') {
      i--;
      if (input[i] == ' ') {
        indent++;
      } else if (input[i] == '\t') {
        indent += 2; // tab 视为 2 空格
      } else {
        indent = 0;
        break;
      }
    }
    if (i == 0) {
      // 文件开头，重新计算
      indent = 0;
      for (int j = 0; j < _pos; j++) {
        if (input[j] == ' ') {
          indent++;
        } else if (input[j] == '\t') {
          indent += 2;
        } else {
          break;
        }
      }
    }
    return indent;
  }

  /// 跳到下一行的起始位置
  void _advanceToNextLine() {
    while (_pos < input.length && _ch != '\n') {
      _pos++;
    }
    if (_pos < input.length) _pos++;
  }

  /// 判断当前位置是否在行首空白之后
  bool _isAtLineStart() {
    if (_pos == 0) return true;
    int i = _pos - 1;
    while (i >= 0 && input[i] != '\n') {
      if (input[i] != ' ' && input[i] != '\t') return false;
      i--;
    }
    return true;
  }

  /// 解析值（根据上下文缩进）
  dynamic _parseValue(int minIndent) {
    _skipBlankLinesAndComments();
    if (_pos >= input.length) return null;

    final indent = _currentIndent();
    if (indent < minIndent) return null;

    // 查看值类型
    _skipWhitespace();
    if (_pos >= input.length) return null;

    // 空对象 {}
    if (_pos < input.length - 1 && _ch == '{' && _nextCh == '}') {
      _pos += 2;
      return <String, dynamic>{};
    }

    // 空列表 []
    if (_pos < input.length - 1 && _ch == '[' && _nextCh == ']') {
      _pos += 2;
      return <dynamic>[];
    }

    // 列表项（以 - 开头）
    if (_ch == '-' && (_nextCh == ' ' || _nextCh == '\n' || _nextCh == null)) {
      return _parseList(indent);
    }

    // 尝试解析为 map（键: 值）
    if (_isAtLineStart()) {
      final saved = _pos;
      final key = _tryParseKey();
      if (key != null) {
        _pos = saved;
        return _parseMap(indent);
      }
    }

    // 纯量值
    return _parseScalar();
  }

  /// 尝试解析键名，失败返回 null
  /// 注意：此方法会消费输入，调用者需在调用前保存位置
  String? _tryParseKey() {
    try {
      final key = _parseKey();
      // 确认后面跟着冒号
      _skipWhitespace();
      if (_pos < input.length && _ch == ':') {
        return key;
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      // 不恢复位置，由调用者处理
    }
  }

  /// 解析键名
  String _parseKey() {
    _skipWhitespace();
    if (_pos >= input.length) {
      throw const FormatException('Unexpected end parsing key');
    }

    // 带引号的键
    if (_ch == '"' || _ch == "'") {
      return _parseQuotedString();
    }

    // 无引号的键（到冒号或换行为止）
    final start = _pos;
    while (_pos < input.length && _ch != ':' && _ch != '\n') {
      _pos++;
    }
    return input.substring(start, _pos).trimRight();
  }

  /// 解析带引号的字符串
  String _parseQuotedString() {
    final quote = _ch;
    _pos++; // 跳过开头引号
    final buf = StringBuffer();
    while (_pos < input.length && _ch != quote) {
      if (_ch == '\\' && _pos + 1 < input.length) {
        _pos++;
        switch (_ch) {
          case 'n':
            buf.write('\n');
          case 't':
            buf.write('\t');
          case '\\':
            buf.write('\\');
          case '"':
            buf.write('"');
          case "'":
            buf.write("'");
          default:
            buf.write('\\');
            buf.write(_ch);
        }
      } else {
        buf.write(_ch);
      }
      _pos++;
    }
    if (_pos < input.length) _pos++; // 跳过结尾引号
    return buf.toString();
  }

  /// 解析纯量值
  dynamic _parseScalar() {
    _skipWhitespace();
    if (_pos >= input.length) return null;

    // 带引号的字符串
    if (_ch == '"' || _ch == "'") {
      return _parseQuotedString();
    }

    // 读取到行尾
    final start = _pos;
    while (_pos < input.length && _ch != '\n' && _ch != '#') {
      _pos++;
    }
    final raw = input.substring(start, _pos).trimRight();

    // 布尔值
    if (raw == 'true' || raw == 'True' || raw == 'TRUE') return true;
    if (raw == 'false' || raw == 'False' || raw == 'FALSE') return false;

    // null
    if (raw == 'null' || raw == '~' || raw.isEmpty) return null;

    // 整数
    final asInt = int.tryParse(raw);
    if (asInt != null) return asInt;

    // 浮点数
    final asDouble = double.tryParse(raw);
    if (asDouble != null) return asDouble;

    return raw;
  }

  /// 解析映射表
  Map<String, dynamic> _parseMap(int baseIndent) {
    final result = <String, dynamic>{};

    while (_pos < input.length) {
      _skipBlankLinesAndComments();
      if (_pos >= input.length) break;

      final indent = _currentIndent();
      if (indent != baseIndent) break;

      // 解析键
      final key = _parseKey();
      _skipWhitespace();

      // 期望冒号
      if (_pos >= input.length || _ch != ':') break;
      _pos++; // 跳过冒号
      _skipWhitespace();

      // 判断值类型
      if (_pos >= input.length || _ch == '\n') {
        // 值在下一行（嵌套结构）
        _advanceToNextLine();
        _skipBlankLinesAndComments();
        if (_pos >= input.length) {
          result[key] = null;
          break;
        }
        final nextIndent = _currentIndent();
        if (nextIndent > baseIndent) {
          result[key] = _parseValue(nextIndent);
        } else {
          result[key] = null;
        }
      } else if (_ch == '{' && _nextCh == '}') {
        // 空对象
        _pos += 2;
        result[key] = <String, dynamic>{};
      } else if (_ch == '[' && _nextCh == ']') {
        // 空列表
        _pos += 2;
        result[key] = <dynamic>[];
      } else {
        // 行内纯量值
        result[key] = _parseScalar();
        _advanceToNextLine();
      }
    }

    return result;
  }

  /// 解析列表
  List<dynamic> _parseList(int baseIndent) {
    final result = <dynamic>[];

    while (_pos < input.length) {
      _skipBlankLinesAndComments();
      if (_pos >= input.length) break;

      final indent = _currentIndent();
      if (indent != baseIndent) break;

      _skipWhitespace();
      if (_pos >= input.length || _ch != '-') break;
      _pos++; // 跳过 -
      _skipWhitespace();

      if (_pos >= input.length || _ch == '\n') {
        // 列表项的值在下一行
        _advanceToNextLine();
        _skipBlankLinesAndComments();
        if (_pos >= input.length) {
          result.add(null);
          break;
        }
        final nextIndent = _currentIndent();
        if (nextIndent > baseIndent) {
          result.add(_parseValue(nextIndent));
        } else {
          result.add(null);
        }
      } else if (_ch == '{' && _nextCh == '}') {
        _pos += 2;
        result.add(<String, dynamic>{});
      } else if (_ch == '[' && _nextCh == ']') {
        _pos += 2;
        result.add(<dynamic>[]);
      } else {
        // 行内纯量
        result.add(_parseScalar());
        _advanceToNextLine();
      }
    }

    return result;
  }
}

// ============================================================================
// 存档清单主类
// ============================================================================

/// Ludusavi 存档清单解析器
class SaveManifest {
  /// 游戏名 -> 游戏条目
  final Map<String, ManifestGame> games;

  /// 别名映射（别名 -> 目标游戏名）
  final Map<String, String> _aliasMap;

  /// 小写游戏名 -> 原始游戏名（用于模糊查找）
  final Map<String, String> _lowerNameMap;

  SaveManifest._(this.games, this._aliasMap, this._lowerNameMap);

  /// 从 YAML 字符串加载清单
  static SaveManifest fromYaml(String yaml) {
    final parser = _SimpleYamlParser(yaml);
    final parsed = parser.parse();

    final games = <String, ManifestGame>{};
    final aliasMap = <String, String>{};
    final lowerNameMap = <String, String>{};

    if (parsed is Map<String, dynamic>) {
      for (final entry in parsed.entries) {
        final name = entry.key;
        final data = entry.value;

        if (data is! Map<String, dynamic>) {
          games[name] = ManifestGame(name: name);
          lowerNameMap[name.toLowerCase()] = name;
          continue;
        }

        final game = _parseGame(name, data);
        games[name] = game;
        lowerNameMap[name.toLowerCase()] = name;

        // 构建别名映射
        if (game.alias != null) {
          aliasMap[name] = game.alias!;
        }
      }
    }

    // 解析别名链（别名可能指向另一个别名）
    final resolvedAliasMap = <String, String>{};
    for (final alias in aliasMap.keys) {
      final target = _resolveAlias(alias, aliasMap, {});
      if (target != null) {
        resolvedAliasMap[alias] = target;
      }
    }

    return SaveManifest._(games, resolvedAliasMap, lowerNameMap);
  }

  /// 解析别名链，返回最终目标游戏名
  static String? _resolveAlias(
      String name, Map<String, String> aliasMap, Set<String> visited) {
    if (visited.contains(name)) return null; // 防止循环
    visited.add(name);
    final target = aliasMap[name];
    if (target == null) return name;
    return _resolveAlias(target, aliasMap, visited);
  }

  /// 解析单个游戏条目
  static ManifestGame _parseGame(String name, Map<String, dynamic> data) {
    // 解析文件条目
    final files = <String, ManifestFileEntry>{};
    final filesData = data['files'];
    if (filesData is Map<String, dynamic>) {
      for (final entry in filesData.entries) {
        files[entry.key] = _parseFileEntry(entry.value);
      }
    }

    // 解析注册表条目
    final registry = <String, ManifestRegistryEntry>{};
    final registryData = data['registry'];
    if (registryData is Map<String, dynamic>) {
      for (final entry in registryData.entries) {
        registry[entry.key] = _parseRegistryEntry(entry.value);
      }
    }

    // 解析安装目录
    final installDirs = <String, Map<String, dynamic>>{};
    final installDirData = data['installDir'];
    if (installDirData is Map<String, dynamic>) {
      for (final entry in installDirData.entries) {
        final val = entry.value;
        if (val is Map<String, dynamic>) {
          installDirs[entry.key] = val;
        } else {
          installDirs[entry.key] = {};
        }
      }
    }

    // 解析 Steam 元数据
    final steamData = data['steam'];
    SteamMetadata steamMeta = const SteamMetadata();
    if (steamData is Map<String, dynamic>) {
      final steamId = steamData['id'];
      steamMeta = SteamMetadata(
        id: steamId is int ? steamId : null,
      );
    }

    // 解析 GOG 元数据
    final gogData = data['gog'];
    GogMetadata gogMeta = const GogMetadata();
    if (gogData is Map<String, dynamic>) {
      final gogId = gogData['id'];
      gogMeta = GogMetadata(
        id: gogId is int ? gogId : null,
      );
    }

    // 解析额外 ID
    final idData = data['id'];
    IdMetadata idMeta = const IdMetadata();
    if (idData is Map<String, dynamic>) {
      idMeta = IdMetadata(
        flatpak: idData['flatpak']?.toString(),
        gogExtra: _parseIntSet(idData['gogExtra']),
        lutris: idData['lutris']?.toString(),
        steamExtra: _parseIntSet(idData['steamExtra']),
      );
    }

    // 解析云存档
    final cloudData = data['cloud'];
    CloudMetadata cloudMeta = const CloudMetadata();
    if (cloudData is Map<String, dynamic>) {
      cloudMeta = CloudMetadata(
        epic: cloudData['epic'] == true,
        gog: cloudData['gog'] == true,
        origin: cloudData['origin'] == true,
        steam: cloudData['steam'] == true,
        uplay: cloudData['uplay'] == true,
      );
    }

    // 解析备注
    final notesData = data['notes'];
    List<String> notes = const [];
    if (notesData is List) {
      notes = notesData.map((n) => n?.toString() ?? '').toList();
    }

    return ManifestGame(
      name: name,
      alias: data['alias']?.toString(),
      files: files,
      registry: registry,
      installDirs: installDirs,
      steam: steamMeta,
      gog: gogMeta,
      id: idMeta,
      cloud: cloudMeta,
      notes: notes,
    );
  }

  /// 解析文件条目
  static ManifestFileEntry _parseFileEntry(dynamic data) {
    if (data is! Map<String, dynamic>) {
      return const ManifestFileEntry();
    }

    // 解析标签
    final tags = <ManifestTag>{};
    final tagsData = data['tags'];
    if (tagsData is List) {
      for (final tag in tagsData) {
        tags.add(ManifestTag.fromString(tag?.toString() ?? ''));
      }
    }

    // 解析条件
    final whenList = <ManifestCondition>[];
    final whenData = data['when'];
    if (whenData is List) {
      for (final item in whenData) {
        if (item is Map<String, dynamic>) {
          whenList.add(_parseCondition(item));
        }
      }
    }

    return ManifestFileEntry(tags: tags, when: whenList);
  }

  /// 解析注册表条目
  static ManifestRegistryEntry _parseRegistryEntry(dynamic data) {
    if (data is! Map<String, dynamic>) {
      return const ManifestRegistryEntry();
    }

    final tags = <ManifestTag>{};
    final tagsData = data['tags'];
    if (tagsData is List) {
      for (final tag in tagsData) {
        tags.add(ManifestTag.fromString(tag?.toString() ?? ''));
      }
    }

    final whenList = <ManifestCondition>[];
    final whenData = data['when'];
    if (whenData is List) {
      for (final item in whenData) {
        if (item is Map<String, dynamic>) {
          whenList.add(_parseRegistryCondition(item));
        }
      }
    }

    return ManifestRegistryEntry(tags: tags, when: whenList);
  }

  /// 解析文件条件
  static ManifestCondition _parseCondition(Map<String, dynamic> data) {
    ManifestOs? os;
    ManifestStore? store;

    final osData = data['os'];
    if (osData is String) {
      os = ManifestOs.fromString(osData);
    }

    final storeData = data['store'];
    if (storeData is String) {
      store = ManifestStore.fromString(storeData);
    }

    return ManifestCondition(os: os, store: store);
  }

  /// 解析注册表条件（不含 os 字段）
  static ManifestCondition _parseRegistryCondition(Map<String, dynamic> data) {
    ManifestStore? store;

    final storeData = data['store'];
    if (storeData is String) {
      store = ManifestStore.fromString(storeData);
    }

    return ManifestCondition(store: store);
  }

  /// 解析整数集合
  static Set<int> _parseIntSet(dynamic data) {
    if (data is List) {
      return data.whereType<int>().toSet();
    }
    return {};
  }

  // ========================================================================
  // 查找方法
  // ========================================================================

  /// 精确查找游戏（按名称）
  ManifestGame? lookup(String name) {
    final game = games[name];
    if (game == null) return null;

    // 如果是别名，解析到目标游戏
    if (game.isAlias) {
      final targetName = _aliasMap[name];
      if (targetName != null) {
        return games[targetName];
      }
    }
    return game;
  }

  /// 模糊查找游戏（不区分大小写）
  List<ManifestGame> fuzzyLookup(String query) {
    final results = <ManifestGame>[];
    final lowerQuery = query.toLowerCase();

    // 1. 精确匹配（不区分大小写）
    final exactMatch = _lowerNameMap[lowerQuery];
    if (exactMatch != null) {
      final game = lookup(exactMatch);
      if (game != null) results.add(game);
    }

    // 2. 前缀匹配
    for (final entry in _lowerNameMap.entries) {
      if (entry.key.startsWith(lowerQuery)) {
        final game = lookup(entry.value);
        if (game != null && !results.any((g) => g.name == game.name)) {
          results.add(game);
        }
      }
    }

    // 3. 包含匹配
    for (final entry in _lowerNameMap.entries) {
      if (entry.key.contains(lowerQuery)) {
        final game = lookup(entry.value);
        if (game != null && !results.any((g) => g.name == game.name)) {
          results.add(game);
        }
      }
    }

    return results;
  }

  /// 通过 Steam ID 查找游戏
  ManifestGame? lookupBySteamId(int steamId) {
    for (final game in games.values) {
      if (game.allSteamIds.contains(steamId)) {
        // 如果是别名条目，返回目标游戏
        if (game.isAlias) {
          final targetName = _aliasMap[game.name];
          if (targetName != null) return games[targetName];
        }
        return game;
      }
    }
    return null;
  }

  /// 通过 GOG ID 查找游戏
  ManifestGame? lookupByGogId(int gogId) {
    for (final game in games.values) {
      if (game.allGogIds.contains(gogId)) {
        if (game.isAlias) {
          final targetName = _aliasMap[game.name];
          if (targetName != null) return games[targetName];
        }
        return game;
      }
    }
    return null;
  }

  /// 获取所有可处理的游戏（非别名且有实际数据）
  Iterable<ManifestGame> get processableGames =>
      games.values.where((g) => !g.isAlias && g.hasSaveData);

  /// 获取所有游戏名
  Iterable<String> get allNames => games.keys;

  /// 游戏总数
  int get count => games.length;

  /// 可处理游戏数
  int get processableCount => processableGames.length;

  // ========================================================================
  // 路径占位符解析
  // ========================================================================

  /// 解析路径中的占位符，返回实际路径
  /// [path] 包含占位符的路径
  /// [context] 占位符替换上下文
  static String resolvePlaceholders(
    String path,
    PlaceholderContext context,
  ) {
    var result = path;

    // Windows 路径占位符
    result = result.replaceAll(Placeholder.winAppData, context.winAppData);
    result =
        result.replaceAll(Placeholder.winLocalAppData, context.winLocalAppData);
    result = result.replaceAll(
        Placeholder.winLocalAppDataLow, context.winLocalAppDataLow);
    result = result.replaceAll(Placeholder.winDocuments, context.winDocuments);
    result = result.replaceAll(Placeholder.winPublic, context.winPublic);
    result =
        result.replaceAll(Placeholder.winProgramData, context.winProgramData);
    result = result.replaceAll(Placeholder.winDir, context.winDir);

    // XDG 路径占位符
    result = result.replaceAll(Placeholder.xdgData, context.xdgData);
    result = result.replaceAll(Placeholder.xdgConfig, context.xdgConfig);

    // 通用占位符
    result = result.replaceAll(Placeholder.home, context.home);
    result = result.replaceAll(Placeholder.osUserName, context.osUserName);

    // 动态占位符（需要运行时信息）
    result = result.replaceAll(Placeholder.root, context.root);
    result = result.replaceAll(Placeholder.game, context.game);
    result = result.replaceAll(Placeholder.base, context.base);
    result = result.replaceAll(Placeholder.storeGameId, context.storeGameId);
    result = result.replaceAll(Placeholder.storeUserId, context.storeUserId);

    return result;
  }

  /// 获取游戏的所有存档文件路径（已解析占位符）
  /// [gameName] 游戏名
  /// [context] 占位符上下文
  /// [os] 过滤操作系统条件
  /// [store] 过滤商店条件
  List<ResolvedSavePath> getResolvedSavePaths(
    String gameName,
    PlaceholderContext context, {
    ManifestOs? os,
    ManifestStore? store,
  }) {
    final game = lookup(gameName);
    if (game == null) return [];

    final results = <ResolvedSavePath>[];

    for (final entry in game.files.entries) {
      final filePath = entry.key;
      final fileEntry = entry.value;

      // 检查条件是否匹配
      if (!fileEntry.matchesConditions(os: os, store: store)) continue;

      final resolved = resolvePlaceholders(filePath, context);
      results.add(ResolvedSavePath(
        rawPath: filePath,
        resolvedPath: resolved,
        tags: fileEntry.tags,
        conditions: fileEntry.when,
        type: SavePathType.file,
      ));
    }

    for (final entry in game.registry.entries) {
      final regPath = entry.key;
      final regEntry = entry.value;

      if (!regEntry.matchesConditions(store: store)) continue;

      results.add(ResolvedSavePath(
        rawPath: regPath,
        resolvedPath: regPath,
        tags: regEntry.tags,
        conditions: regEntry.when,
        type: SavePathType.registry,
      ));
    }

    return results;
  }
}

/// 占位符替换上下文
class PlaceholderContext {
  /// Windows 系统路径
  final String winAppData;
  final String winLocalAppData;
  final String winLocalAppDataLow;
  final String winDocuments;
  final String winPublic;
  final String winProgramData;
  final String winDir;

  /// XDG 路径（Linux/macOS）
  final String xdgData;
  final String xdgConfig;

  /// 通用路径
  final String home;
  final String osUserName;

  /// 动态路径（需要运行时信息）
  final String root;
  final String game;
  final String base;
  final String storeGameId;
  final String storeUserId;

  const PlaceholderContext({
    this.winAppData = '',
    this.winLocalAppData = '',
    this.winLocalAppDataLow = '',
    this.winDocuments = '',
    this.winPublic = '',
    this.winProgramData = 'C:/ProgramData',
    this.winDir = 'C:/Windows',
    this.xdgData = '',
    this.xdgConfig = '',
    this.home = '',
    this.osUserName = '',
    this.root = '',
    this.game = '',
    this.base = '',
    this.storeGameId = '',
    this.storeUserId = '',
  });

  /// 创建 Windows 平台的默认上下文
  factory PlaceholderContext.windows({
    String? appData,
    String? localAppData,
    String? localAppDataLow,
    String? documents,
    String? public,
    String? userName,
    String? root,
    String? game,
    String? base,
    String? storeGameId,
    String? storeUserId,
  }) {
    final user = userName ?? '';
    final homePath = appData != null
        ? appData.replaceAll('\\Roaming', '')
        : 'C:/Users/$user';
    return PlaceholderContext(
      winAppData: appData ?? 'C:/Users/$user/AppData/Roaming',
      winLocalAppData: localAppData ?? 'C:/Users/$user/AppData/Local',
      winLocalAppDataLow: localAppDataLow ?? 'C:/Users/$user/AppData/LocalLow',
      winDocuments: documents ?? 'C:/Users/$user/Documents',
      winPublic: public ?? 'C:/Users/Public',
      winProgramData: 'C:/ProgramData',
      winDir: 'C:/Windows',
      xdgData: '',
      xdgConfig: '',
      home: homePath,
      osUserName: user,
      root: root ?? '',
      game: game ?? '',
      base: base ?? '',
      storeGameId: storeGameId ?? '',
      storeUserId: storeUserId ?? '',
    );
  }
}

/// 已解析的存档路径
class ResolvedSavePath {
  /// 原始路径（含占位符）
  final String rawPath;

  /// 解析后的实际路径
  final String resolvedPath;

  /// 标签集合
  final Set<ManifestTag> tags;

  /// 条件列表
  final List<ManifestCondition> conditions;

  /// 路径类型（文件或注册表）
  final SavePathType type;

  const ResolvedSavePath({
    required this.rawPath,
    required this.resolvedPath,
    required this.tags,
    required this.conditions,
    required this.type,
  });

  bool get isSave => tags.contains(ManifestTag.save);
  bool get isConfig => tags.contains(ManifestTag.config);
  bool get isFile => type == SavePathType.file;
  bool get isRegistry => type == SavePathType.registry;

  @override
  String toString() =>
      'ResolvedSavePath($resolvedPath, tags: $tags, type: $type)';
}

/// 存档路径类型
enum SavePathType {
  file,
  registry,
}
