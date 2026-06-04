# Chrono Tide - 开源版本

> 一款基于 Flutter 的 Windows 桌面端游戏库管理平台

## 项目简介

Chrono Tide 是一个功能丰富的本地游戏库管理工具，专为 GALGAME 玩家设计。开源版本包含以下核心功能：

- **本地游戏库管理** - 扫描、启动、删除、标记已安装的游戏
- **手动入库** - 支持拖拽添加本地游戏，自动从 VNDB/Bangumi/Steam 等平台抓取元数据
- **万能解压引擎** - 支持 ZIP/RAR/7Z/LZ4/TAR/ISO/CAB/ARJ 等十余种格式
- **多线程下载器** - 4线程分片并行下载，支持断点续传
- **存档备份系统** - 自动/手动备份游戏存档，支持恢复
- **Locale Emulator 转区** - 日文游戏一键转区启动
- **主题系统** - 亮色/暗色/自定义背景图切换
- **元数据聚合** - 内嵌 LunaMetadataSDK，支持 VNDB/Bangumi/Steam/Ymgal/DLsite/ErogameScape 六大数据源

## 开源版本说明

本仓库为 Chrono Tide 的**开源版本**。与正式版相比，以下在线功能需要自行配置后端才能使用：

- 发现页（在线游戏浏览）
- 用户登录/注册
- 一键下载安装
- 在线更新检查
- 会员/充值系统

当后端未配置时，软件会自动进入**本地模式**，所有本地功能均可正常使用。

## 快速开始

### 环境要求

- Flutter SDK >= 3.0
- Dart >= 3.0
- Windows 10/11

### 安装依赖

```bash
flutter pub get
```

### 运行（本地模式）

```bash
flutter run -d windows
```

无需任何后端配置即可运行，软件会自动进入本地模式。

### 配置后端（开发者）

如果你希望启用在线功能，需要：

1. 自行搭建 [PocketBase](https://pocketbase.io/) 后端服务
2. 自行搭建 [Alist/OpenList](https://alist.nn.ci/) 文件服务
3. 在 `lib/core/backend_config.dart` 中填入你的服务配置：

```dart
static const String pbBaseUrl = 'http://your-server:8090';
static const String openlistConfigRecordId = 'your-record-id';
static const String openlistAdminUsername = 'your-username';
static const String openlistAdminPassword = 'your-password';
static const String defaultExtractionPassword = 'your-password';
```

4. 在 PocketBase 中创建以下集合：
   - `games` - 游戏数据集合（字段：title, description, coverUrl, tags, downloadUrl, status, Developer）
   - `users` - 用户集合（PocketBase 默认）
   - `openlist_configs` - OpenList 配置集合

### 打包发布

```bash
flutter build windows
```

## 项目结构

```
lib/
├── core/                    # 核心基础设施
│   ├── backend_config.dart  # 后端配置与可用性检测
│   ├── pb_config.dart       # PocketBase 客户端
│   └── path_helper.dart     # 路径管理
├── models/                  # 数据模型
├── modules/auth/            # 认证模块
├── packages/                # 内嵌 SDK
│   └── luna_metadata_sdk/   # 元数据抓取 SDK
├── pages/                   # 页面
├── repositories/            # 数据仓库
├── services/                # 业务服务
├── theme/                   # 主题系统
├── utils/                   # 工具类
└── widgets/                 # UI 组件
```

## 技术栈

- **框架**: Flutter (Dart)
- **后端**: PocketBase (需自建)
- **文件服务**: Alist/OpenList (需自建)
- **元数据源**: VNDB, Bangumi, Steam, Ymgal, DLsite, ErogameScape

## 许可证

请参阅 LICENSE 文件。

## 致谢

- [PocketBase](https://pocketbase.io/) - 开源后端即服务
- [Alist](https://alist.nn.ci/) - 文件列表程序
- [VNDB](https://vndb.org/) - 视觉小说数据库
- [Bangumi](https://bangumi.tv/) - 番组计划
- [Locale Emulator](https://xupefei.github.io/Locale-Emulator/) - 区域模拟器
- [ludusavi](https://github.com/mtkennerly/ludusavi) - 游戏存档备份工具
