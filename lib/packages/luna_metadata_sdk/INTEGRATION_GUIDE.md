# Luna Metadata SDK - 对接文档

> **版本**: 1.0.0  
> **最后更新**: 2026-05-31  
> **状态**: ✅ 可用于生产环境

---

## 📋 目录

1. [SDK 概述](#sdk-概述)
2. [安装与配置](#安装与配置)
3. [核心 API 接口](#核心-api-接口)
4. [数据模型定义](#数据模型定义)
5. [快速开始示例](#快速开始示例)
6. [各数据源详细说明](#各数据源详细说明)
7. [错误处理机制](#错误处理机制)
8. [性能优化建议](#性能优化建议)
9. [常见问题 FAQ](#常见问题-faq)

---

## 📚 SDK 概述

### 什么是 Luna Metadata SDK？

Luna Metadata SDK 是一个**纯 Dart/Flutter 元数据抓取库**，专门为游戏管理器设计。它支持从 **7 个主流游戏数据库** 自动抓取游戏元数据（封面、评分、标签、开发商等）。

### 支持的数据源

| 数据源 | 类型 | 是否需要认证 | 国内可访问 | 适用场景 |
|--------|------|-------------|-----------|---------|
| **Bangumi** | JSON API | ❌ 匿名访问 | ✅ 使用镜像站 | 日系视觉小说/GAL |
| **VNDB** | GraphQL-like JSON | ❌ 无需认证 | ✅ 可直接访问 | 视觉小说数据库 |
| **Steam** | REST API | ❌ 无需认证 | ✅ 有国内节点 | Steam 平台游戏 |
| **DLsite** | HTML 爬虫 | ❌ 无需认证 | ⚠️ 需要稳定网络 | 日本同人/商业游戏 |
| **ErogameScape** | HTML 爬虫 | ❌ 无需认证 | ⚠️ 需要稳定网络 | GALGAME 评分站 |
| **月幕GAL** | OAuth2 API | ✅ 自动获取 Token | ✅ 国内服务器 | 中文 GAL 资讯站 |

### 核心特性

- ✅ **零配置使用**：开箱即用，无需 API Key
- ✅ **智能镜像切换**：Bangumi 支持多镜像自动切换
- ✅ **安全类型处理**：所有 API 响应都经过 null-safe 处理
- ✅ **自动 Token 管理**：月幕GAL OAuth2 Token 自动获取和缓存
- ✅ **超时保护**：所有请求都有合理的超时设置
- ✅ **统一接口**：所有数据源实现相同的 `MetadataSourceService` 接口

---

## 🔧 安装与配置

### 方式一：直接引用（推荐用于开发）

将 `scrap/flutter_sdk/` 目录复制到你的项目中：

```
your_flutter_project/
├── lib/
│   └── packages/
│       └── luna_metadata_sdk/    ← 复制到这里
│           ├── lib/
│           │   ├── models/
│           │   └── services/
│           └── pubspec.yaml
├── pubspec.yaml
```

在 `pubspec.yaml` 中添加依赖：

```yaml
dependencies:
  luna_metadata_sdk:
    path: ./lib/packages/luna_metadata_sdk
```

### 方式二：发布到 pub.dev（推荐用于生产）

```bash
cd scrap/flutter_sdk
dart pub publish --dry-run   # 先测试
dart pub publish            # 正式发布
```

然后在主项目的 `pubspec.yaml` 中添加：

```yaml
dependencies:
  luna_metadata_sdk: ^1.0.0
```

### 必要的依赖

SDK 依赖以下包（会自动安装）：

```yaml
dependencies:
  dio: ^5.4.0              # HTTP 客户端
  html: ^0.15.4            # HTML 解析（DLsite/ErogameScape）
  flutter:
    sdk: flutter
```

---

## 🎯 核心 API 接口

### MetadataSourceService（抽象接口）

所有数据源都必须实现此接口：

```dart
abstract class MetadataSourceService {
  /// 根据名称搜索并抓取元数据
  Future<MetadataResult> fetchByName(String name);

  /// 测试连接是否可用
  Future<bool> testConnection();

  /// 数据源类型标识
  SourceType get sourceType;

  /// 数据源显示名称
  String get sourceName;
}
```

#### 方法详解

##### `fetchByName(String name)`

**功能**：根据游戏名称搜索并返回最匹配的元数据。

**参数**：
- `name`: 游戏名称（支持中文、英文、日文、罗马音）

**返回值**：`MetadataResult`
- `result.isValid == true` 表示成功获取到数据
- `result.isValid == false` 表示未找到或出错

**异常情况**：
- 抛出 `Exception` 当网络错误或 API 返回错误时
- 返回空结果（`isValid == false`）当搜索无结果时

**示例**：
```dart
final service = MetadataServiceFactory.getService(SourceType.bangumi);
final result = await service.fetchByName('CLANNAD');

if (result.isValid) {
  print('找到游戏: ${result.game.name}');
  print('封面: ${result.game.coverUrl}');
} else {
  print('未找到匹配的游戏');
}
```

##### `testConnection()`

**功能**：测试当前数据源的连通性（不抓取数据）。

**返回值**：`bool`
- `true`: 连接正常
- `false`: 无法连接

**用途**：UI 中显示数据源状态指示器

### MetadataServiceFactory（工厂类）

用于创建对应数据源的服务实例：

```dart
class MetadataServiceFactory {
  /// 根据类型获取服务实例
  static MetadataSourceService getService(SourceType sourceType);
}
```

**使用示例**：
```dart
// 创建 Bangumi 服务
final bangumi = MetadataServiceFactory.getService(SourceType.bangumi);

// 创建 VNDB 服务
final vndb = MetadataServiceFactory.getService(SourceType/vndb);

// 创建 Steam 服务
final steam = MetadataServiceFactory.getService(SourceType.steam);
```

---

## 📦 数据模型定义

### Game（游戏信息）

```dart
class Game {
  final String id;              // 唯一标识符（各平台不同格式）
  final String name;            // 游戏名称
  final String? coverUrl;       // 封面图片 URL
  final String? company;        // 开发商/发行商
  final String? summary;        // 游戏简介
  final double rating;          // 评分 (0.0 - 10.0)
  final String? releaseDate;    // 发行日期 (YYYY-MM-DD)
  final SourceType sourceType;  // 数据来源
  final String? sourceId;       // 在来源平台的 ID
  final DateTime cachedAt;      // 缓存时间
  
  // ... 构造函数、工厂方法、序列化方法
}
```

**字段说明**：

| 字段 | 类型 | 说明 | 示例 |
|------|------|------|------|
| `id` | `String` | 内部唯一 ID（可为空） | `"13"` |
| `name` | `String` | 游戏显示名称 | `"CLANNAD"` |
| `coverUrl` | `String?` | 封面图完整URL | `"https://lain.bangumi.one/pic/cover/..."` |
| `company` | `String?` | 开发商 | `"Key / VISUAL ARTS"` |
| `summary` | `String?` | 游戏简介（可能很长） | `"某个春天..."` |
| `rating` | `double` | 评分（0-10分制） | `8.9` |
| `releaseDate` | `String?` | 发行日期 | `"2004-04-28"` |
| `sourceType` | `SourceType` | 数据来源枚举 | `SourceType.bangumi` |
| `sourceId` | `String?` | 来源平台ID | `"13"` |

### TagItem（标签项）

```dart
class TagItem {
  final String name;        // 标签名称
  final String source;      // 标签来源平台
  final double weight;      // 权重 (0.0 - 10.0，越高越相关)
  final bool isSpoiler;     // 是否为剧透标签
}
```

**使用场景**：
```dart
for (final tag in result.tags) {
  print('${tag.name} (权重: ${tag.weight.toStringAsFixed(1)})');
}
// 输出：
// KEY (权重: 10.0)
// CLANNAD (权重: 8.2)
// Galgame (权重: 5.9)
// ADV (权重: 4.7)
```

### MetadataResult（抓取结果）

```dart
class MetadataResult {
  final Game game;              // 游戏核心信息
  final List<TagItem> tags;      // 标签列表
  
  bool get isValid;              // 是否有效（id 和 name 都非空）
}
```

### SourceType（数据源枚举）

```dart
enum SourceType {
  local,         // 本地导入
  bangumi,       // Bangumi 镜像站
  vndb,          // VNDB
  ymgal,         // 月幕GAL
  steam,         // Steam
  dlsite,        // DLsite
  erogamescape;  // ErogameScape
  
  String get displayName;  // 显示名称
}
```

---

## 🚀 快速开始示例

### 示例 1：基础抓取

```dart
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

Future<void> main() async {
  // 1. 创建 Bangumi 服务
  final service = MetadataServiceFactory.getService(SourceType.bangumi);
  
  // 2. 测试连接
  bool isConnected = await service.testConnection();
  print('Bangumi 连接状态: $isConnected');
  
  // 3. 抓取元数据
  try {
    final result = await service.fetchByName('命运石之门');
    
    if (result.isValid) {
      print('✅ 成功获取数据:');
      print('   名称: ${result.game.name}');
      print('   开发商: ${result.game.company ?? "未知"}');
      print('   评分: ${result.game.rating}');
      print('   封面: ${result.game.coverUrl ?? "无"}');
      print('   标签数量: ${result.tags.length}');
    } else {
      print('❌ 未找到匹配的游戏');
    }
  } catch (e) {
    print('❌ 抓取失败: $e');
  }
}
```

### 示例 2：多源并行抓取

```dart
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

Future<void> searchGame(String keyword) async {
  // 定义要查询的数据源
  final sources = [
    SourceType.bangumi,
    SourceType.vndb,
    SourceType.steam,
    SourceType.ymgal,
  ];
  
  // 并行抓取所有数据源
  final futures = sources.map((type) async {
    final service = MetadataServiceFactory.getService(type);
    try {
      return await service.fetchByName(keyword);
    } catch (e) {
      return MetadataResult(
        game: Game(id: '', name: '', sourceType: type),
      );
    }
  });
  
  final results = await Future.wait(futures);
  
  // 输出结果
  for (final result in results) {
    if (result.isValid) {
      print('[${result.game.sourceType.displayName}] ${result.game.name}');
    }
  }
}
```

### 示例 3：批量测试所有数据源

```dart
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';

Future<void> testAllSources() async {
  final allTypes = SourceType.values.where((s) => s != SourceType.local);
  
  for (final type in allTypes) {
    final service = MetadataServiceFactory.getService(type);
    final connected = await service.testConnection();
    
    print('${service.sourceName}: ${connected ? "✅" : "❌"}');
    
    if (connected) {
      try {
        final result = await service.fetchByName('CLANNAD');
        print('  → 找到: ${result.isValid ? result.game.name : "无结果"}');
      } catch (e) {
        print('  → 错误: $e');
      }
    }
  }
}
```

### 示例 4：自定义 Bangumi 镜像站

```dart
import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';
import 'package:dio/dio.dart';

void main() {
  // 自定义 Dio 配置（如代理）
  final dio = Dio(BaseOptions(
    proxy: 'http://127.0.0.1:7890',  // 本地代理
  ));
  
  // 自定义镜像站列表
  final customMirrors = [
    'https://api.bangumi.one',
    'https://api.bgm.tv',
    'https://fast.bangumi.one',  // 新增备用镜像
  ];
  
  // 创建带自定义配置的服务
  final service = BangumiMirrorService(
    dio: dio,
    mirrorURLs: customMirrors,
  );
  
  // 使用...
}
```

---

## 📖 各数据源详细说明

### 1. Bangumi（镜像站）

**API 端点**：
- 主镜像：`https://api.bangumi.one/v0/search/subjects`
- 详情：`https://api.bangumi.one/v0/subjects/{id}`

**特点**：
- ✅ 匿名访问，无需 Token
- ✅ 支持多镜像自动切换
- ✅ 图片 URL 自动替换为镜像域名
- ⚠️ 搜索只返回前 5 条结果（按 rank 排序）

**适用关键词**：
- 中文：`CLANNAD`, `命运石之门`
- 英文：`Steins;Gate`, `Clannad`
- 日文：`クラナド`

**特殊处理**：
```dart
// 图片域名替换规则（已内置）：
// lain.bgm.tv → lain.bangumi.one
// bgm.tv → bangumi.one
```

**返回字段**：
- `name_cn`: 中文名称（优先使用）
- `name`: 原始名称
- `images.large/common`: 封面图
- `rating.score`: 评分（10分制）
- `tags[]`: 标签列表（count >= 3 的才会保留）

---

### 2. VNDB

**API 端点**：`https://api.vndb.org/kana/vn`

**请求方式**：POST JSON

**请求体结构**：
```json
{
  "filters": ["search", "=", "Steins;Gate"],
  "fields": "id, title, titles{lang, title, latin}, image{url}, description, rating, released, developers{name}, tags{name, rating}",
  "sort": "searchrank"
}
```

**响应结构**：
```json
{
  "results": [{
    "id": "7",
    "title": "Steins;Gate",
    "image": {"url": "https://..."},
    "rating": 8.67,
    "tags": [{"name": "Sci-Fi", "rating": 2.5}]
  }],
  "more": false,
  "count": 1
}
```

**特点**：
- ✅ GraphQL-like 查询语法
- ✅ 支持标题多语言（优先中日英）
- ✅ 标签带权重（rating），可用于排序
- ⚠️ 字段可能为 null（已做安全处理）

**适用关键词**：
- 英文：`Steins;Gate`, `Clannad`
- 罗马音：`Suteinzu Gēto`

---

### 3. Steam

**两阶段查询**：

**阶段 1 - 搜索**：
```
GET https://store.steampowered.com/api/storesearch/?term={keyword}&l=schinese&cc=CN
```
返回：`{items: [{id: 41400, name: "Steins;Gate", ...}]}`

**阶段 2 - 详情**：
```
GET https://store.steampowered.com/api/appdetails?appids=41400&l=schinese&cc=CN
```
返回：`{"41400": {success: true, data: {...}}}`

**特点**：
- ✅ 两阶段设计（先搜索ID，再查详情）
- ✅ 智能匹配算法（精确 > 前缀 > 包含）
- ✅ 支持 Metacritic 评分转换
- ⚠️ 可能被墙（建议用代理）

**返回字段**：
- `name`: 名称
- `header_image`: 封面图
- `short_description`: 简介
- `metacritic.score`: 评分（转换为10分制）
- `developers[]`: 开发商列表
- `genres[]`: 游戏类型标签
- `release_date.date`: 发行日期

---

### 4. DLsite

**技术方案**：HTML 解析 + CSS 选择器

**搜索页**：
```
GET https://www.dlsite.com/maniax/fsr/=/language/jp/keyword/{keyword}/
```

**详情页**：
```
GET https://www.dlsite.com/maniax/work/=/product_id/{RJ号}.html
```

**Headers 要求**：
```dart
headers: {
  'User-Agent': 'Mozilla/5.0 ...',
  'Accept': 'text/html,...',
  'Cookie': 'adultchecked=1; locale=ja',  // 绕过年龄验证
}
```

**CSS 选择器**：
- 商品列表：`.search_result_img_box_inner`
- 标题：`#work_name`
- 封面：`img[src*="_img_main"]` 或 `img[src*="_img_smp"]`
- 开发商：`.maker_name a`
- 标签：`.main_genre a`

**商品编号格式**：
- RJxxxxx：成人向
- RExxxx：全年龄
- VJxxxxx：视频

**特点**：
- ✅ 支持商品编号直接搜索
- ✅ HTML 解析，无需 API Key
- ⚠️ 需要较长的超时时间（25-30秒）
- ⚠️ 国内网络可能不稳定

---

### 5. ErogameScape

**技术方案**：HTML 解析

**搜索页**：
```
GET https://erogamescape.org/~ap2/ero/toukei_kaiseki/kensaku.php?category=game&word={word}
```

**详情页**：
```
GET https://erogamescape.org/~ap2/ero/toukei_kaiseki/game.php?game={id}
```

**Headers 要求**：
```dart
headers: {
  'Referer': 'https://erogamescape.org/~ap2/ero/toukei_kaiseki',
}
```

**CSS 选择器**：
- 搜索结果：`#result tr td a`（提取 game 参数）
- 标题：`#soft-title span.bold`
- 封面：`#main_image img`
- 开发商：`#brand td`
- 日期：`#sellday td`
- 评分：`#median td` 或 `#average td`
- 标签：`#att_pov_table tr td a`（筛选特定表头）

**特点**：
- ✅ 专注于 GALGAME 评分
- ✅ 包含详细的标签分类（公式ジャンル、シチュエーション等）
- ⚠️ 页面结构复杂，解析逻辑较多
- ⚠️ 国内网络不稳定

---

### 6. 月幕GAL

**OAuth2 认证流程**：

**Token 获取**（GET 请求，参数在 URL 中）：
```
GET https://www.ymgal.games/oauth/token?
  grant_type=client_credentials&
  client_id=ymgal&
  client_secret=luna0327&
  scope=public
```

**⚠️ 关键**：必须使用 GET 方法 + query parameters，不能 POST body！

**数据查询**：
```
GET https://www.ymgal.games/open/archive/search-game?
  mode=accurate&
  keyword={关键词}&
  similarity=70
```

**Headers**：
```dart
headers: {
  'Authorization': 'Bearer {token}',
  'version': '1',
  'Accept': 'application/json;charset=utf-8',
}
```

**特点**：
- ✅ 自动 Token 管理（缓存 1 小时）
- ✅ 国内服务器，速度快
- ✅ 支持中文名称精确搜索
- ⚠️ Token 有有效期，需要定期刷新

**返回字段**：
- `chineseName`: 中文名称（优先）
- `name`: 原始名称
- `mainImg`: 封面图
- `brand_name`: 品牌/开发商
- `introduction`: 简介
- `score`: 评分
- `tags[]`: 标签列表

---

## ⚠️ 错误处理机制

### 异常类型

```dart
try {
  final result = await service.fetchByName('xxx');
} on Exception catch (e) {
  // 1. 网络错误
  if (e.toString().contains('timeout')) {
    // 处理超时
  }
  
  // 2. API 错误
  if (e.toString().contains('401')) {
    // 处理认证失败
  }
  
  // 3. 限流错误
  if (e.toString().contains('429')) {
    // 延迟重试
  }
}
```

### 空结果处理

```dart
final result = await service.fetchByName('不存在');

if (!result.isValid) {
  // 情况 1：搜索无结果
  // 情况 2：API 返回了但数据无效
  // 建议：尝试其他数据源或提示用户手动输入
}
```

### 推荐的重试策略

```dart
Future<MetadataResult> fetchWithRetry(
  MetadataSourceService service,
  String name, {
  int maxRetries = 3,
  Duration delay = const Duration(seconds: 2),
}) async {
  for (int i = 0; i < maxRetries; i++) {
    try {
      final result = await service.fetchByName(name);
      if (result.isValid) return result;
      
      // 如果是空结果，不再重试
      break;
    } catch (e) {
      if (i == maxRetries - 1) rethrow;
      await Future.delayed(delay * (i + 1)); // 指数退避
    }
  }
  
  return MetadataResult(game: Game(id: '', name: '', sourceType: service.sourceType));
}
```

---

## ⚡ 性能优化建议

### 1. 并行请求

```dart
// ❌ 串行请求（慢）
final r1 = await bangumi.fetch(name);
final r2 = await vndb.fetch(name);
final r3 = await steam.fetch(name);

// ✅ 并行请求（快 3 倍）
final results = await Future.wait([
  bangumi.fetch(name),
  vndb.fetch(name),
  steam.fetch(name),
]);
```

### 2. 缓存策略

```dart
class MetadataCache {
  final Map<String, MetadataResult> _cache = {};
  final Duration _ttl = const Duration(hours: 24);

  Future<MetadataResult> getOrFetch(
    String key,
    Future<MetadataResult> Function() fetcher,
  ) async {
    if (_cache.containsKey(key)) {
      final cached = _cache[key]!;
      if (DateTime.now().difference(cached.game.cachedAt) < _ttl) {
        return cached;
      }
      _cache.remove(key);
    }

    final result = await fetcher();
    if (result.isValid) {
      _cache[key] = result;
    }
    return result;
  }
}
```

### 3. 超时配置

```dart
// 为不同网络环境调整超时
final dio = Dio(BaseOptions(
  connectTimeout: const Duration(seconds: 20),  // 国内网络建议 20s+
  receiveTimeout: const Duration(seconds: 25),  // 接收超时 25s+
));
```

### 4. 取消请求

```dart
final cancelToken = CancelToken();

// 用户取消搜索时
cancelToken.cancel('用户取消了搜索');

// 使用 cancelToken
await _dio.get(url, cancelToken: cancelToken);
```

---

## ❓ 常见问题 FAQ

### Q1: Bangumi 图片加载不出来？

**A**: 已内置图片域名替换逻辑。如果仍有问题：
1. 检查镜像站是否可用：`https://lain.bangumi.one`
2. 尝试切换到其他镜像：`service.setCustomMirrors(['https://fast.bangumi.one'])`
3. 检查是否有代理干扰

### Q2: DLsite/ErogameScape 总是超时？

**A**: 这两个站点在日本，国内访问慢。解决方案：
1. 增加超时时间（默认 25-30 秒）
2. 使用日本节点代理加速
3. 避免高峰期使用

### Q3: 月幕GAL 返回 401 错误？

**A**: 这是 OAuth2 认证问题。SDK 已自动处理：
- 确保 GET 请求（不是 POST）
- Token 会自动缓存 1 小时
- 如果仍然失败，检查网络是否能访问 `ymgal.games`

### Q4: 如何添加新的数据源？

**A**: 步骤如下：
1. 实现 `MetadataSourceService` 接口
2. 在 `SourceType` 枚举中添加新类型
3. 在 `MetadataServiceFactory.getService()` 中注册
4. 参考现有实现的代码风格

### Q5: 如何在生产环境中使用？

**A**: 建议做法：
1. 将 SDK 作为独立 package 引入
2. 在 Service 层封装调用逻辑
3. 添加缓存层避免重复请求
4. 监控成功率并记录日志
5. 对失败请求进行降级处理

---

## 📞 技术支持

如有问题，请参考：
- 原项目代码：`scrap/metadata/*.go`（Go 版本实现）
- 测试平台：`scrap/test_platform/`（可视化测试工具）
- 对接文档：本文档

---

## 📝 更新日志

### v1.0.0 (2026-05-31)

**初始版本发布**
- ✅ 支持 6 个数据源（Bangumi/VNDB/Steam/DLsite/ErogameScape/月幕GAL）
- ✅ 统一的 MetadataSourceService 接口
- ✅ 安全的 null 类型处理
- ✅ Bangumi 镜像站自动切换和图片域名替换
- ✅ 月幕GAL OAuth2 自动 Token 管理
- ✅ DLsite/ErogameScape HTML 解析
- ✅ Steam 两阶段查询
- ✅ 完整的错误处理机制

---

**文档结束**
