# Luna Metadata SDK - 数据源原理说明

> **目标读者**: 负责集成此 SDK 到主 Flutter 项目的开发人员（另一个 AI 任务）
>
> **用途**: 彻底理解每个数据源的抓取原理，以便完全替换/重构原有的元数据抓取模块

---

## 📌 重要提示（给下一个 AI 任务）

### ⚠️ 必须遵守的原则

1. **不要修改 SDK 内部代码**：`scrap/flutter_sdk/lib/` 下的代码已经过充分测试，直接使用即可
2. **只通过公开接口调用**：
   - `MetadataSourceService.fetchByName(String name)`
   - `MetadataServiceFactory.getService(SourceType type)`
   - `MetadataResult` / `Game` / `TagItem` 数据模型
3. **不要重新实现抓取逻辑**：所有数据源的具体实现都在 SDK 中完成
4. **你的任务**：将 SDK 集成到主项目 UI 和业务流程中

### 🎯 你的工作范围

```
✅ 应该做的：
- 在主项目中引入 luna_metadata_sdk 包
- 在游戏导入流程中调用 SDK 的 fetchByName()
- 显示返回的 Game 数据（封面、名称、评分等）
- 处理错误情况（超时、无结果等）
- 添加缓存逻辑（可选但推荐）

❌ 不应该做的：
- 重写任何数据源实现
- 修改 SDK 内部代码
- 直接调用 API（绕过 SDK）
- 自己解析 HTML/JSON 响应
```

---

## 🔬 各数据源技术原理详解

### 架构总览

```
┌─────────────────────────────────────────────┐
│              主 Flutter 项目                   │
│                                             │
│  ┌─────────┐    ┌──────────────────┐        │
│  │ 游戏列表 │───▶│ MetadataFetcher  │        │
│  └─────────┘    └────────┬─────────┘        │
│                         │                  │
│              ┌──────────▼──────────┐        │
│              │  luna_metadata_sdk   │        │
│              │  (纯 Dart 库)       │        │
│              └──────────┬──────────┘        │
│                         │                  │
│     ┌───────────────────┼──────────────┐   │
│     ▼         ▼         ▼          ▼      │
│  Bangumi   VNDB     Steam      DLsite    │
│  (JSON)  (GraphQL) (REST)    (HTML)     │
│     ...       ...       ...        ...    │
└─────────────────────────────────────────────┘
```

---

## 1️⃣ Bangumi（镜像站）- JSON API

### 技术栈
- **协议**: HTTP + JSON
- **认证方式**: 匿名访问（无需 Token）
- **请求方式**: POST（搜索）/ GET（详情）

### 核心原理

#### Step 1: 搜索接口

```http
POST https://api.bangumi.one/v0/search/subjects?limit=5&offset=0
Content-Type: application/json

{
  "keyword": "CLANNAD",
  "sort": "rank",
  "filter": {
    "type": [4],      // 4 = 游戏
    "nsfw": true      // 包含成人内容
  }
}
```

**响应结构**：
```json
{
  "code": 0,
  "data": [
    {
      "id": 13,
      "name": "CLANNAD",
      "name_cn": "CLANNAD",
      "type": 4,
      "images": {
        "large": "https://lain.bgm.tv/pic/cover/l/c5/1c/13_tQxwM.jpg",
        "common": "https://lain.bgm.tv/r/400/pic/cover/l/c5/1c/13_tQxwM.jpg"
      },
      "rating": {"score": 8.9, "rank": 12},
      "summary": "某个春天...",
      "tags": [
        {"name": "KEY", "count": 496},
        {"name": "CLANNAD", "count": 312}
      ],
      "infobox": [
        {"key": "开发商", "value": [{"v": "Key / VISUAL ARTS"}]}
      ]
    }
  ],
  "total": 5,
  "limit": 1,
  "offset": 0
}
```

#### Step 2: 图片 URL 处理（关键！）

**问题**：API 返回的图片 URL 使用的是原站域名 `lain.bgm.tv`，国内无法访问。

**解决方案**：根据 mirrox 镜像映射表进行域名替换：

```dart
// 原始 URL（不可访问）
"https://lain.bgm.tv/pic/cover/l/c5/1c/13_tQxwM.jpg"

// 替换规则（已在 SDK 中内置）
"lain.bgm.tv" → "lain.bangumi.one"
"bgm.tv" → "bangumi.one"

// 最终 URL（可访问）
"https://lain.bangumi.one/pic/cover/l/c5/1c/13_tQxwM.jpg"
```

**完整域名映射表**：

| 原站域名 | 镜像域名 |
|---------|---------|
| `bgm.tv` | `bangumi.one` |
| `api.bgm.tv` | `api.bangumi.one` |
| `lain.bgm.tv` | `lain.bangumi.one` |
| `fast.bgm.tv` | `fast.bangumi.one` |
| `next.bgm.tv` | `next.bangumi.one` |

#### Step 3: 多镜像自动切换

SDK 内置镜像列表：
```dart
static const List<String> _defaultMirrors = [
  'https://api.bangumi.one',  // 主镜像
  'https://api.bgm.tv',      // 原站备用
];
```

**切换逻辑**：
1. 尝试第一个镜像
2. 如果失败（网络错误/429限流），自动切换到下一个
3. 如果是 429 错误，停止尝试（避免被全面封禁）

#### Step 4: 数据提取与清洗

**字段优先级**：
1. 名称：`name_cn` > `name`
2. 封面：`images.large` > `images.common`
3. 标签：只保留 `count >= 3` 的标签（过滤噪音）
4. 开发商：从 `infobox` 数组中查找包含"开发商"/"开发"的条目

---

## 2️⃣ VNDB - GraphQL-like API

### 技术栈
- **协议**: HTTP + JSON（类 GraphQL）
- **认证方式**: 无需认证
- **请求方式**: POST

### 核心原理

#### Step 1: 构建查询

VNDB 使用自定义的查询语法（类似 GraphQL）：

```http
POST https://api.vndb.org/kana/vn
Content-Type: application/json

{
  "filters": ["search", "=", "Steins;Gate"],
  "fields": "id, title, titles{lang, title, latin, official, main}, image{url}, description, rating, released, developers{name}, tags{name, rating, spoiler}",
  "sort": "searchrank"
}
```

**关键字段说明**：

| 字段 | 说明 |
|------|------|
| `filters` | 过滤条件：`["search", "=", "关键词"]` |
| `fields` | 要返回的字段（支持嵌套对象） |
| `sort` | 排序方式：`searchrank` = 搜索相关度排序 |
| `titles` | 多语言标题数组（含语言标识、是否官方） |
| `tags` | 标签数组（带权重 rating 和剧透标记 spoiler） |

#### Step 2: 安全类型处理（重要！）

**问题**：VNDB API 返回的字段可能为 null，Dart 是强类型语言，直接转换会崩溃。

**解决方案**：SDK 内置 safe*() 工具函数：

```dart
// ❌ 危险做法（可能崩溃）
final name = json['title'] as String;  // 如果 title 为 null 会抛异常

// ✅ 安全做法（SDK 已封装）
String? name = safeString(json, 'title');  // null 时返回 null

// safeString 实现：
String? safeString(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is String) return value.isNotEmpty ? value : null;
  if (value is num) return value.toString();
  return value.toString();
}
```

**完整的 safe 函数族**：

| 函数名 | 用途 | 返回类型 |
|--------|------|---------|
| `safeString(map, key)` | 提取字符串 | `String?` |
| `safeDouble(map, key)` | 提取浮点数 | `double?` |
| `safeInt(map, key)` | 提取整数 | `int?` |
| `safeMap(map, key)` | 提取嵌套 Map | `Map<String, dynamic>?` |
| `safeList(map, key)` | 提取数组 | `List<dynamic>?` |
| `safeBool(map, key)` | 提取布尔值 | `bool?` |

#### Step 3: 标题多语言处理

VNDB 返回多个语言的标题：

```json
{
  "titles": [
    {"lang": "ja", "title": "シュタインズ・ゲート", "latin": "Steins;Gate", "official": true},
    {"lang": "en", "title": "Steins;Gate", "latin": "", "official": true},
    {"lang": "zh-Hans", "title": "命运石之门", "latin": "", "official": false},
    {"lang": "ko", "title": "슈타인즈 게이트", "latin": "", "official": false}
  ]
}
```

**选择逻辑**（已内置在 SDK）：
1. 优先选择 `main == true` 或中文/日文标题
2. 如果没有匹配的，使用原始 `title` 字段
3. 最终输出最合适的本地化名称

#### Step 4: 标签权重计算

VNDB 标签带有 `rating` 字段（-3 到 +3），表示相关性：

```json
{
  "tags": [
    {"name": "Sci-Fi", "rating": 2.5, "spoiler": false},
    {"name": "Time Travel", "rating": 2.0, "spoiler": true},
    {"name": "Protagonist", "rating": 1.8, "spoiler": false}
  ]
}
```

**处理逻辑**：
1. 只保留 `rating >= 1.5` 的标签（过滤低相关性标签）
2. 按 rating 降序排序
3. 取前 10 个标签
4. 将 VNDB rating (-3~+3) 转换为 weight (0.1~10.0)

---

## 3️⃣ Steam - REST API（两阶段）

### 技术栈
- **协议**: HTTP REST API
- **认证方式**: 无需认证
- **特点**: 两阶段设计（搜索 → 详情）

### 核心原理

#### 阶段 1: 搜索获取 AppID

```http
GET https://store.steampowered.com/api/storesearch/?term=Steins;Gate&l=schinese&cc=CN
```

**响应**：
```json
{
  "items": [
    {
      "id": 41400,
      "name": "Steins;Gate",
      "type": "game",
      "price": {...}
    },
    {
      "id": 214010,
      "name": "Steins;Gate Elite",
      "type": "game",
      "price": {...}
    }
  ]
}
```

#### 阶段 2: 根据 AppID 获取详情

```http
GET https://store.steampowered.com/api/appdetails?appids=41400&l=schinese&cc=CN
```

**响应**（注意：key 是 appID 字符串！）：
```json
{
  "41400": {
    "success": true,
    "data": {
      "type": "game",
      "name": "Steins;Gate",
      "short_description": "在 AKA 实验室...",
      "header_image": "https://cdn.akamai.steamstatic.com/steam/apps/41400/header.jpg",
      "developers": ["MAGES.", "5pb."],
      "publishers": ["Spike Chunsoft"],
      "genres": [
        {"id": "73", "description": "Violent"},
        {"id": "74", "description": "Gore"}
      ],
      "metacritic": {"score": 88, "url": "..."},
      "release_date": {
        "date": "Sep 9, 2016",
        "coming_soon": false
      },
      "platforms": {
        "windows": true,
        "mac": false,
        "linux": false
      }
    }
  }
}
```

#### 智能匹配算法

当搜索返回多个结果时，如何选择最佳匹配？

```dart
Map<String, dynamic> _pickBestMatch(List<Map<String, dynamic>> items, String query) {
  final queryLower = query.toLowerCase().replaceAll(specialChars, ' ');
  
  Map<String, dynamic> best = items[0];
  int bestScore = -1;

  for (final item in items) {
    final itemName = (item['name'] ?? '').toLowerCase();
    int score = 0;
    
    if (itemName == queryLower) score += 100;  // 完全匹配
    if (itemName.startsWith(queryLower)) score += 40;  // 前缀匹配
    if (itemName.contains(queryLower)) score += 20;  // 包含匹配
    
    if (score > bestScore && item['id'] != null) {
      bestScore = score;
      best = item;
    }
  }

  return best;
}
```

#### 评分转换

Steam 返回 Metacritic 评分（0-100），转换为 10 分制：

```dart
double metacriticScore = 88;
double rating = metacriticScore / 10.0;  // → 8.8
```

---

## 4️⃣ DLsite - HTML 爬虫

### 技术栈
- **协议**: HTTP + HTML 解析
- **库**: `html` package（CSS 选择器）
- **认证方式**: Cookie 绕过年龄验证

### 核心原理

#### Step 1: 特殊 Headers（关键！）

DLsite 对爬虫有严格检测，必须模拟浏览器：

```dart
headers: {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36',
  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'Accept-Language': 'ja,en;q=0.8',
  'Cookie': 'adultchecked=1; locale=ja',  // ← 关键！绕过年龄验证
}
```

**为什么需要 Cookie？**
- DLsite 有成人内容年龄验证页面
- `adultchecked=1` 表示用户已确认成年
- 没有 Cookie 会被重定向到验证页

#### Step 2: 搜索页 HTML 解析

**URL 格式**：
```
https://www.dlsite.com/maniax/fsr/=/language/jp/keyword/{encoded_keyword}/
```

**关键词编码**：
```dart
// 特殊字符处理
final encoded = Uri.encodeComponent(keyword).replaceAll('%20', '+');
// 例如："命运石之门" → "%E5%91%BD%E8%BF%90%E7%9F%B3%E4%B9%8B%E9%97%A8"
```

**CSS 选择器定位商品**：

```html
<!-- 目标 HTML 结构 -->
<div class="search_result_img_box_inner" data-list_item_product_id="RJ01194151">
  <a class="work_thumb_inner" href="/maniax/work/=/product_id/RJ01194151.html">
    <img data-src="/pics/product/RJ01194151_img_main.jpg">
  </a>
</div>
<div class="work_name">
  <a href="..." title="游戏名称">游戏名称</a>
</div>
```

**解析代码**：
```dart
document.querySelectorAll('.search_result_img_box_inner').forEach((element) {
  // 提取商品 ID
  String? id = element.attributes['data-list_item_product_id'];
  if (id == null || id.isEmpty) {
    // 备用方案：从链接中用正则提取 RJ号
    final link = element.querySelector('a.work_thumb_inner');
    final href = link?.attributes['href'];
    id = RegExp(r'(RJ|RE|VJ)\d{4,}').firstMatch(href)?.group(0);
  }
  
  // 提取名称
  final nameLink = element.querySelector('.work_name a');
  String name = nameLink?.attributes['title'] ?? '';
});
```

#### Step 3: 详情页 HTML 解析

**URL 格式**：
```
https://www.dlsite.com/{prefix}/work/=/product_id/{id}.html
# prefix: maniax (成人向) / pro (全年龄视频)
```

**CSS 选择器**：

| 元素 | 选择器 | 提取方法 |
|------|--------|---------|
| 标题 | `#work_name` | `.text.trim()` |
| 封面图 | `img[data-src]`, `source[srcset]`, `img[src]` | `.attributes['data-src']` 等 |
| 开发商 | `.maker_name a` | `.text.trim()` |
| 简介 | `[itemprop="description"]` | `.text.trim()` |
| 发行日期 | `th:contains('販売日') + td` | 下一兄弟节点文本 |
| 标签 | `.main_genre a` | 循环提取 |

**封面图优先级**：
1. `_img_main` （大图）
2. `_img_smp` （缩略图）
3. 其他图片

**URL 规范化**：
```dart
String _normalizeURL(String raw) {
  // 相对路径补全
  if (raw.startsWith('//')) return 'https:$raw';
  if (raw.startsWith('/')) return 'https://www.dlsite.com$raw';
  return raw;
}
```

**日期格式转换**：
```dart
// 输入："2004年04月28日" 或 "2004.04.28" 或 "2004/04/28"
// 输出："2004-04-28"

String _normalizeJapaneseDate(String raw) {
  var text = raw.replaceAll(RegExp(r'\s+'), '');
  var replaced = text
      .replaceAll('年', '-')
      .replaceAll('月', '-')
      .replaceAll('日', '')
      .replaceAll('.', '-');
  // 解析并格式化...
}
```

---

## 5️⃣ ErogameScape - HTML 爬虫

### 技术栈
- **协议**: HTTP + HTML 解析
- **库**: `html` package
- **特殊要求**: Referer Header

### 核心原理

#### Step 1: Referer Header（关键！）

ErogameScape 会检查请求来源，必须设置正确的 Referer：

```dart
headers: {
  'Referer': 'https://erogamescape.org/~ap2/ero/toukei_kaiseki',
}
```

**为什么需要 Referer？**
- 防止跨站请求伪造（CSRF）
- 没有 Referer 可能返回空页面或 403

#### Step 2: 搜索页解析

**URL**：
```
https://erogamescape.org/~ap2/ero/toukei_kaiseki/kensaku.php?category=game&word_category=name&mode=normal&word={keyword}
```

**HTML 结构分析**：

```html
<table id="result">
  <tr>
    <th>...</th>  <!-- 表头行 -->
  </tr>
  <tr>
    <td><a href="?game=3454">WHITE ALBUM</a></td>  <!-- 第 N 列（列号由表头决定）-->
    <td><span>(leaf)</span></td>
    <!-- ... 其他列 ... -->
  </tr>
</table>
```

**动态列号检测**：
```dart
int nameCol = 0;
document.querySelectorAll('#result tr').asMap().forEach((index, row) {
  if (index == 0) {  // 表头行
    row.querySelectorAll('th').asMap().forEach((colIdx, cell) {
      if (cell.text.trim() == 'ゲーム名') {
        nameCol = colIdx;  // 记录"游戏名"列的位置
      }
    });
    return;
  }
  
  // 数据行
  final cells = row.querySelectorAll('td');
  final nameCell = cells[nameCol];  // 使用记录的列号
  final link = nameCell.querySelector('a');
  final gameID = RegExp(r'[?&#/]game=(\d+)').firstMatch(link.attributes['href'])?.group(1);
});
```

#### Step 3: 详情页解析

**URL**：
```
https://erogamescape.org/~ap2/ero/toukei_kaiseki/game.php?game={id}
```

**CSS 选择器**：

| 元素 | 选择器 | 说明 |
|------|--------|------|
| 标题 | `#soft-title span.bold` | 主标题 |
| 封面 | `#main_image img` | `.attributes['src']` |
| 品牌 | `#brand td` | 开发商/品牌 |
| 日期 | `#sellday td` | 发售日 |
| 评分 | `#median td` 或 `#average td` | 中位数/平均分 |
| 类型标志 | `#erogame td` | 18禁/非18禁等 |
| 标签 | `#att_pov_table tr` | 分类标签 |

**标签分类表头**（白名单）：

```dart
final allowedHeaders = {
  '公式ジャンル': true,   // 官方类型
  'ジャンル': true,       // 类型
  'タグ': true,            // 标签
  'シチュエーション': true, // 场景
  'エロシーン': true,      // H场景
};
```

**只提取这些表头下的 `<a>` 标签**，忽略其他信息。

**评分提取**：
```dart
// 从文本中提取数字
final ratingText = el.text.trim();  // 例："82.34"
final match = RegExp(r'(\d+(?:\.\d+)?)').firstMatch(ratingText);
double rating = double.tryParse(match.group(1) ?? '') ?? 0.0;
if (rating > 10) rating /= 10.0;  // 超过10则归一化
```

---

## 6️⃣ 月幕GAL - OAuth2 API

### 技术栈
- **协议**: HTTP + OAuth2
- **认证方式**: Client Credentials Flow（客户端凭证）
- **Token 管理**: 自动缓存 + 定期刷新

### 核心原理（⚠️ 最关键的数据源！）

#### ❌ 常见错误（不要这样做！）

```dart
// 错误方式 1：POST body 发送参数（会返回 401）
_dio.post(
  'https://www.ymgal.games/oauth/token',
  data: FormData.fromMap({
    'grant_type': 'client_credentials',
    'client_id': 'ymgal',
    'client_secret': 'luna0327',
    'scope': 'public',
  }),
);

// 错误方式 2：JSON body（也会返回 401）
_dio.post(
  'https://www.ymgal.games/oauth/token',
  data: {
    'grant_type': 'client_credentials',
    ...
  },
);
```

#### ✅ 正确方式（必须这样做！）

**关键点：使用 GET 方法 + URL Query Parameters**

```dart
// 正确方式：GET 请求，参数放在 URL 中
final response = await _dio.get(
  'https://www.ymgal.games/oauth/token',
  queryParameters: {  // ← 注意：是 queryParameters，不是 data！
    'grant_type': 'client_credentials',
    'client_id': 'ymgal',
    'client_secret': 'luna0327',
    'scope': 'public',
  },
);
```

**OAuth2 Client Credentials Flow 原理**：

```
┌──────────┐     GET /oauth/token?...      ┌──────────────┐
│  SDK     │ ─────────────────────────────▶  │  月幕GAL服务器  │
│          │                                   │              │
│          │ ◀─── {access_token, expires_in} ─│              │
│          │                                   │              │
│ 缓存Token│                                   │              │
│ (1小时有效)│                                  │              │
└──────────┘                                   └──────────────┘
```

#### Token 响应示例

```json
{
  "access_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "token_type": "bearer",
  "expires_in": 3600,
  "scope": "public"
}
```

#### Token 缓存策略

```dart
class YmgalService {
  String? _cachedToken;
  DateTime? _tokenExpiresAt;

  Future<String?> _getToken() async {
    // 1. 检查缓存是否存在且未过期
    if (_cachedToken != null &&
        _tokenExpiresAt != null &&
        DateTime.now().isBefore(_tokenExpiresAt!)) {
      return _cachedToken;  // 直接返回缓存的 Token
    }

    // 2. Token 不存在或已过期，重新获取
    try {
      final response = await _dio.get(
        'https://www.ymgal.games/oauth/token',
        queryParameters: {...},
      );

      final accessToken = response.data['access_token'];
      final expiresIn = response.data['expires_in'];

      // 3. 更新缓存
      _cachedToken = accessToken;
      _tokenExpiresAt = DateTime.now()
          .add(Duration(seconds: expiresIn))
          .subtract(const Duration(seconds: 60));  // 提前60秒过期

      return accessToken;
    } catch (e) {
      return null;  // 获取失败
    }
  }
}
```

#### 数据查询

**URL**：
```
GET https://www.ymgal.games/open/archive/search-game?mode=accurate&keyword={关键词}&similarity=70
```

**Headers**：
```dart
headers: {
  'Authorization': 'Bearer ${await _getToken()}',  // 使用缓存的 Token
  'version': '1',
  'Accept': 'application/json;charset=utf-8',
}
```

**响应结构**：
```json
{
  "success": true,
  "data": {
    "game": {
      "gid": 12345,
      "chineseName": "命运石之门",
      "name": "Steins;Gate",
      "mainImg": "https://www.ymgal.games/img/xxx.jpg",
      "brand_name": "5pb.",
      "introduction": "故事简介...",
      "score": 8.9,
      "release_date": "2009-10-15",
      "tags": [
        {"name": "科幻"},
        {"name": "时间旅行"}
      ]
    }
  }
}
```

**字段优先级**：
- 名称：`chineseName` > `name`
- 封面：`mainImg` > `cover_url` > `image`
- 开发商：`brand_name` > `company` > `developer_name`
- 简介：`introduction` > `summary`
- 日期：`release_date` > `publish_date`

---

## 🛠️ 集成检查清单

给下一个 AI 任务的 Check List：

### ✅ 必须完成的任务

- [ ] 在主项目 `pubspec.yaml` 中添加依赖：
  ```yaml
  dependencies:
    luna_metadata_sdk:
      path: ../scrap/flutter_sdk
  ```

- [ ] 运行 `flutter pub get` 安装依赖

- [ ] 创建 MetadataFetcher 服务类：
  ```dart
  import 'package:luna_metadata_sdk/luna_metadata_sdk.dart';
  
  class GameMetadataFetcher {
    Future<MetadataResult?> fetchGame(String name, SourceType source) async {
      final service = MetadataServiceFactory.getService(source);
      
      try {
        final result = await service.fetchByName(name);
        return result.isValid ? result : null;
      } catch (e) {
        print('抓取失败 [$source]: $e');
        return null;
      }
    }
    
    Future<Map<SourceType, MetadataResult>> fetchAllSources(String name) async {
      final sources = SourceType.values.where((s) => s != SourceType.local);
      
      final futures = sources.map((source) async {
        final service = MetadataServiceFactory.getService(source);
        try {
          final result = await service.fetchByName(name);
          return MapEntry(source, result);
        } catch (e) {
          return MapEntry(source, MetadataResult(
            game: Game(id: '', name: '', sourceType: source),
          ));
        }
      });
      
      final results = await Future.wait(futures);
      return Map.fromEntries(results);
    }
  }
  ```

- [ ] 在游戏导入界面调用：
  ```dart
  final fetcher = GameMetadataFetcher();
  
  // 单源抓取
  final bangumiResult = await fetcher.fetchGame('CLANNAD', SourceType.bangumi);
  if (bangumiResult != null) {
    // 更新 UI 显示封面、名称等
  }
  
  // 多源并行抓取
  final allResults = await fetcher.fetchAllSources('CLANNAD');
  allResults.forEach((source, result) {
    if (result.isValid) {
      print('[${source.displayName}] ${result.game.name}');
    }
  });
  ```

- [ ] 图片加载（使用 CachedNetworkImage 或 Image.network）：
  ```dart
  Image.network(
    result.game.coverUrl ?? '',
    errorBuilder: (_, __, ___ => Icon(Icons.error),
    loadingBuilder: (_, __, ___ => CircularProgressIndicator(),
  )
  ```

- [ ] 错误处理和降级：
  ```dart
  try {
    final result = await service.fetchByName(name);
    if (!result.isValid) {
      // 显示"未找到"提示
      showSnackBar(content: Text('未找到匹配的游戏'));
    }
  } on Exception catch (e) {
    if (e.toString().contains('timeout')) {
      showSnackBar(content: Text('连接超时，请检查网络'));
    } else {
      showSnackBar(content: Text('抓取失败: $e'));
    }
  }
  ```

### 🎨 可选优化项

- [ ] 添加缓存层（避免重复请求同一游戏）
- [ ] 添加进度指示器（显示当前正在查询哪个数据源）
- [ ] 支持手动选择数据源（下拉菜单）
- [ ] 批量导入时并发控制（限制同时请求数量）
- [ ] 添加代理设置选项（用于加速国外站点）
- [ ] 记录日志（成功/失败率统计）

---

## 📚 参考资料

### 文件位置

```
scrap/
├── flutter_sdk/                    # SDK 包（你要集成的）
│   ├── lib/
│   │   ├── luna_metadata_sdk.dart # 入口文件
│   │   ├── models/
│   │   │   ├── game.dart         # Game, SourceType
│   │   │   └── tags.dart          # TagItem, MetadataResult
│   │   └── services/
│   │       ├── metadata_base.dart        # 抽象接口定义
│   │       ├── bangumi_service.dart      # Bangumi 实现
│   │       └── metadata_services.dart    # 其他5个数据源
│   ├── pubspec.yaml                # 依赖配置
│   └── INTEGRATION_GUIDE.md       # 本文档
│
├── test_platform/                 # 测试工具（可删除）
│   └── build/windows/x64/runner/Release/test_platform.exe
│
└── metadata/                      # Go 版本参考实现
    ├── metadata_bangumi_mirror.go
    ├── metadata_vndb.go
    ├── metadata_steam.go
    ├── metadata_dlsite.go
    ├── metadata_erogamescape.go
    └── metadata_ymgal.go
```

### 相关文档

- **Go 版本实现**：`scrap/metadata/*.go`（原始参考）
- **测试平台**：`scrap/test_platform/`（可视化测试工具）
- **Flutter 迁移指南**：`scrap/docs/FLUTTER_MIGRATION_GUIDE.md`
- **交付清单**：`scrap/DELIVERY_CHECKLIST.md`

---

## ✅ 总结

### 给下一个 AI 任务的最终指令

```
你现在的任务是：
1. 将 scrap/flutter_sdk/ 作为 package 引入主 Flutter 项目
2. 不要修改 SDK 内部任何代码
3. 通过 MetadataSourceService 接口调用抓取功能
4. 将返回的 Game/TagItem 数据绑定到 UI 上
5. 处理好错误情况和用户体验
6. 测试确保所有 6 个数据源都能正常工作

关键技术要点：
- Bangumi 图片域名已自动替换为镜像站
- 所有 API 响应都经过 null-safe 处理
- 月幕GAL OAuth2 使用 GET + query parameters
- DLsite/ErogameScape 需要 Cookie 和 Referer Headers
- Steam 是两阶段查询（先搜 ID 再查详情）

遇到问题时：
- 先查看 INTEGRATION_GUIDE.md
- 参考 test_platform/ 中的使用示例
- 对比 metadata/*.go 的 Go 版本实现
```

---

**文档结束**

祝集成顺利！如有问题请参考上述文档或查看源码注释。
