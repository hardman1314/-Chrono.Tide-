# Chrono Tide

> 一款基于 Flutter 的 Windows 桌面端 Galgame / 视觉小说游戏库管理器

![Flutter](https://img.shields.io/badge/Flutter-3.24%2B-02569B?logo=flutter)
![Dart](https://img.shields.io/badge/Dart-3.5%2B-0175C2?logo=dart)
![Platform](https://img.shields.io/badge/Platform-Windows%2010%2F11-0078D6?logo=windows)
![License](https://img.shields.io/badge/License-GPL--3.0-blue)
![Version](https://img.shields.io/badge/Version-3.0.0-brightgreen)

Chrono Tide 是面向 GALGAME 玩家的本地游戏库管理工具：扫描并入库本地游戏、抓取元数据、
一键启动（含转区 / 超分）、管理存档、备份到云端，并提供一套沉浸式的大屏模式（BPM）。

本仓库是 **开源版本**，与正式版使用同一套源码。所有依赖私有后端的在线功能在后端未配置时
会自动降级为「本地模式」，本地功能（游戏库、导入、启动、存档、解压、大屏模式）完全可用。

---

## 目录

- [v3.0.0 亮点](#v300-亮点)
- [核心功能](#核心功能)
- [开源版本说明](#开源版本说明)
- [快速开始](#快速开始)
- [构建产物说明](#构建产物说明)
- [项目结构](#项目结构)
- [技术栈](#技术栈)
- [许可证与致谢](#许可证与致谢)

> 📌 想看完整版本历史（v3.0.0 / v2.5.0 / v2.0.0）请看 [CHANGELOG.md](./CHANGELOG.md)；
> 架构与技术说明请看 [项目介绍.md](./项目介绍.md)。

---

## v3.0.0 亮点

v3.0.0 是自 v2.5.0 以来的功能性大版本，新增了多个独立子系统，非补丁迭代可承载。

| 亮点 | 说明 |
|------|------|
| **软件级游戏内手柄适配** | 全新子系统：SDL3 输入层 + `SendInput` 注入，让原本只支持键鼠的 Galgame 也能用手柄玩；**每游戏独立按键映射**、进程级单例、目录级前台守卫、摇杆漂移免疫 |
| **单文件导入 · 智能解压** | 自动识别多层嵌套、改后缀伪装包（魔数嗅探）、逐层密码、分卷压缩、网盘过审壳；支持 `.enc` 程序化解密与包内密码提取 |
| **安装中心** | 统一任务中心承载本地压缩包解压，含 `awaitingConfirmation` 相位、解压取消与系统操作日志面板 |
| **游戏数据保存 / 云备份** | 存档「封装 / 解封」全链路；云备份一期 WebDAV + DPAPI 凭据加密，二期 S3 兼容源（R2 / OSS / COS / MinIO）+ 客户端加密 + 自动同步 |
| **大屏模式 BPM** | 三段式入场动画（幕布合拢 → 手柄轮廓描出 + 柔光 → 揭开落座，共 0.99 秒），全屏整页二级详情、自定义背景图与 OP 视频背景 |
| **CT 探索库作为元数据源** | 自有云端探索库接入一键抓取，优先级 NextMoe → CT → VNDB |
| **账号体系本地化** | 本地游客与在线账号双态身份；注册邮箱验证码、找回密码 OTP、记住登录（DPAPI 加密 + token 静默重登） |
| **受控标签词表九维** | 维度 8 → 9（新增 adult），概念 97 → 688、别名键 709 → 5253，探索页标签覆盖率 28.5% → 73.9% |
| **横幅封面 / 相册系统** | `banner_file` 第二封面系统，横幅优先用于大屏背景与桌面主页大图；封面管理浮层 + 相册浮层 |
| **系列体系** | 独立系列整理工具 `series_curator`（本地网页工具）、未收录雷达、系列封面自动补全、系列展示 UI 重构 |

---

## 核心功能

### 游戏库

- **扫描与入库** —— 手动入库、批量导入、智能导入（实时扫描监控目标文件夹，非持久化缓存）
- **元数据源** —— 内嵌 `luna_metadata_sdk`，支持 VNDB / Bangumi / Steam / Ymgal / DLsite / ErogameScape / NextMoe / 本地 CT 探索库
- **本地注册表** —— `local_game_registry.dart` 统一管理游戏数据读写
- **受控标签词表** —— 九维受控词表（含分类匣、会社墙与会社别名词典）

### 启动与游玩

- **启动收敛** —— 所有启动方式统一走 `game_launch_service.dart`（唯一事实源是 `game.json` 的 `launch_path`）
- **转区** —— Locale Emulator 集成，日文游戏一键转区启动
- **Magpie 超分** —— 超分启动集成，含预设档位
- **游玩时长** —— 启动即计时，经验值 / 游玩统计面板
- **游戏内手柄** —— SDL3 + `SendInput`，每游戏独立映射，内置编辑器 UI 与 SteamOS 通用预设

### 大屏模式 BPM

- 全屏无边框 + FFI 物理像素渲染
- 三段式入场动画、焦点分层板块系统、自绘虚拟键盘
- 二级整页详情、分类匣、自定义背景图与 OP 视频背景

### 解压与安装

- **万能解压引擎** —— ZIP / RAR / 7Z / LZ4 / TAR / ISO / CAB / ARJ 等十余种格式
- **智能解压** —— 五场景自动决策（嵌套 / 伪装 / 分卷 / 多文件歧义 / 游戏本体识别）+ 隐式候选链 + 歧义选择窗
- **密码组体系** —— 密码去层级化：本次输入 → 预设组 → 历史组 → 密码库；分组整体记忆
- **安装中心** —— 下载与本地解压的统一任务中心

### 存档与备份

- **存档封存四态** —— seal / pack / unseal / unpack，含压缩前存档清单确认、归档库、回收站
- **云备份** —— WebDAV / S3 兼容源 + 客户端加密 + 自动同步（启动 / 24h / 7d 窗口）

### 界面与主题

- 亮色 / 暗色 / 跟随系统，预设主题 + 自定义主题编辑器
- 窗口级圆角体系统一（小对话框 / 大型模态面板 / 菜单气泡 / BPM 大屏 四档）
- 系统提示聊天气泡（替代底部 SnackBar）

---

## 开源版本说明

本仓库为 Chrono Tide 的**开源版本**。以下功能依赖私有后端，**默认不可用**，需自行配置后端：

- 用户登录 / 注册 / 记住登录
- 发现页 / 探索大厅（在线游戏浏览）
- 在线一键下载安装
- 在线更新检查
- 会员 / 充值系统
- 云端资源检索与分享（CT 探索库）

**后端未配置时，软件会自动进入本地模式，上述功能静默隐藏，所有本地功能正常可用。**

---

## 快速开始

### 环境要求

| 项目 | 要求 |
|------|------|
| 操作系统 | Windows 10 / 11（64 位） |
| Flutter SDK | >= 3.24（Dart >= 3.5） |
| 手柄（可选） | DirectInput / XInput 兼容手柄 |

### 安装依赖

```bash
flutter pub get
```

### 运行（本地模式）

```bash
flutter run -d windows
```

无需任何后端配置即可运行，软件会自动进入本地模式。

### 构建发布

```bash
flutter build windows --release
```

产物位于 `build/windows/x64/release/windows/chrono_tide.exe`（名称取自 `pubspec.yaml` 的 `name`），
配套 Inno Setup 安装脚本见 `ChronoTide_Setup.iss`，输出到 `安装包输出/`。

### 配置后端（开发者）

> ⚠️ **请勿把你的后端地址、账号、密码直接提交到公开仓库。**

如果你希望启用在线功能，需要：

1. 自行搭建 [PocketBase](https://pocketbase.io/) 后端服务（默认 `http://127.0.0.1:8090`）
2. 自行搭建 [Alist/OpenList](https://alist.nn.ci/) 文件服务（v3.0.0 起为**应用内按需对接**，不再硬内置）
3. 在 `lib/core/backend_config.dart` 中填入你的服务配置：

```dart
static const String pbBaseUrl = 'http://your-server:8090';
static const String openlistConfigRecordId = 'your-record-id';
static const String openlistAdminUsername = 'your-username';
static const String openlistAdminPassword = 'your-password';
static const String defaultExtractionPassword = 'your-password';
```

4. 在 PocketBase 中创建以下集合：
   - `games` —— 游戏数据集合
   - `users` —— 用户集合（PocketBase 默认）
   - `openlist_configs` —— OpenList 配置集合
   - `game_resources` —— 云端口径的资源来源集合

配置完成后首次运行会检测 `$pbBaseUrl/api/health`，通过即启用在线功能。

### 运行测试

```bash
flutter test
```

---

## 构建产物说明

为便于使用者「开箱即用」，本仓库**跟踪了部分第三方Windows 二进制**（共 17 个），
均为项目运行必需的工具，非项目源码：

| 路径 | 用途 |
|------|------|
| `assets/tools/` | `rar_lz4_unzip.exe`、`UnRAR.exe`、`Rar.exe`、`bz.exe` 等解压工具；`ark.x64.dll` 系列 |
| `windows/runner/tools/` | `7z.exe` / `7za.dll` —— 解压内核 |
| `windows/runner/locale_emulator/` | Locale Emulator —— 日文游戏转区启动 |

> 📌 `.gitignore` 对 `*.exe` / `*.dll` / `*.so` / `*.dylib` 全局忽略，
> 但为白名单目录开了三条例外（`!assets/tools/`、`!windows/runner/tools/`、
> `!windows/runner/locale_emulator/`）。其他路径下的二进制 **不会**入库，
> 若确需跟踪，请在 `.gitignore` 中显式追加例外后 `git add -f`。

### ⚠️ 两个未入库的运行时二进制（clone 后需自行放置）

以下两者被 `.gitignore` 挡在仓库外，因此 **仅 clone 源码无法获得**，属已知缺口：

| 二进制 | 位置 | 影响的 v3.0.0 功能 | 缺失后果 |
|--------|------|------------------|----------|
| `SDL3.dll` | `windows/runner/sdl3/` | 大屏模式 BPM 手柄输入（首选后端） | 手柄回落到 XInput 后端，Xbox 系仍可用，PS / Switch / 国产手柄不可用 |
| `Magpie.exe` 及其依赖 | `windows/runner/magpie/` | 超分启动（大屏与详情页开关） | 超分启动不可用，普通启动不受影响 |

**想要完整能力，两条路：**

1. 下载 **v3.0.0 正式安装包**（内置上述全部二进制，开箱即用）；
2. 手动把这两个文件放进对应目录 —— 路径由 `PathHelper.sdl3DllPath`（`lib/core/path_helper.dart:45`）
   与 `MagpieService` 决定，从任意 v3.0.0 安装目录拷贝即可。

---

## 项目结构

```
lib/
├── main.dart                    # 应用入口：初始化、窗口配置、全局服务注册
├── main_container.dart          # 主容器：页面路由、侧边栏 / 标题栏骨架、全局浮层
├── app_log_helper.dart          # 日志辅助
├── big_picture/                 # 大屏模式 BPM（控制器 / 焦点 / 页面 / 服务 / 组件）
│   ├── big_picture_manager.dart # 大屏生命周期与三段式入场调度
│   ├── big_picture_shell.dart   # 大屏外壳（槽位结构不变量）
│   ├── focus/                   # 焦点分层板块系统
│   ├── pages/                   # 主页 / 库页 / 二级详情页
│   ├── services/                # 手柄后端、背景媒体、IME 桥接、播放历史
│   └── widgets/                 # 入场光效、交互包裹、按键帽、分类匣等
├── core/                        # 核心基础设施
│   ├── backend_config.dart      # 后端配置与可用性检测（留空 = 本地模式）
│   ├── pb_config.dart           # PocketBase 客户端
│   ├── path_helper.dart         # 路径管理（护栏用，删除清理必须过此校验）
│   ├── portable_*.dart          # 便携化：文件系统 / 图片缓存 / 偏好存储
├── models/                      # 数据模型（game_model / series_model / archive_manifest 等）
├── modules/auth/                # 认证模块（本地游客 + 在线账号双态）
├── packages/
│   └── luna_metadata_sdk/       # 内嵌元数据抓取 SDK（Dart 包）
├── pages/                       # 页面（home_page / library_page / discover_page / join / login / register）
├── repositories/                # 数据仓库
├── services/                    # 业务服务（约 100 文件，按职责域分组）
│   ├── local_game_registry.dart # 本地游戏注册表（数据读写核心）
│   ├── game_launch_service.dart # 启动总入口
│   ├── extract_manager.dart     # 解压引擎与进度
│   ├── game_data_format.dart    # 数据格式版本与迁移编排
│   ├── cloud_backup/            # 云备份（WebDAV / S3 / DPAPI）
│   ├── gamepad/                 # 游戏内手柄适配（SDL3 + 注入）
│   ├── enc/                     # 解包密码与程序化解密
│   ├── storage/                 # 存储迁移编排（存档四态）
│   ├── nsfw/                    # NSFW 图源模式
│   └── update/                  # 在线更新检查
├── theme/                       # 主题系统（注册表 / 元素注册表 / 背景图解析器）
├── utils/                       # 工具类（fs_scan / title_cleaner / game_key / path_normalizer）
└── widgets/                     # UI 组件（含 game_detail / library / settings / gamepad 子目录）
```

### 关键约定（改代码前请务必知道）

| 约定 | 位置 |
|------|------|
| 目录名清洗唯一实现 `GameKey.dirNameFromTitle` | `lib/utils/game_key.dart` |
| 游戏身份 = `game.json` 的 `game_id` | `lib/services/game_data_format.dart` |
| 启动 exe 唯一事实源 = `launch_path`，走 `GameLaunchService` | `lib/services/game_launch_service.dart` |
| 游戏数据格式版本：4 | `lib/services/game_data_format.dart` |
| 删除清理必须过 `PathHelper.isInsideAppStorage` | `lib/core/path_helper.dart` |
| 归属存疑的文件永远保留 | `lib/core/path_helper.dart`（ADR-007） |
| 确定性 = 回传路径的回调瞬间 | `lib/core/path_helper.dart`（ADR-008） |
| 批量导入候选中继内存化（不写 prefs），根治个人数据随安装包泄漏 | `lib/services/auto_import_pipeline.dart` |

---

## 技术栈

- **框架**：Flutter（Dart 3.5+），Windows 桌面端（`window_manager` 无边框全屏 + FFI 物理像素）
- **后端**：PocketBase（开源版留空，走本地模式）
- **文件服务**：Alist / OpenList（v3.0.0 起改为应用内按需对接）
- **元数据源**：VNDB、Bangumi、Steam、Ymgal、DLsite、ErogameScape、NextMoe、CT 探索库
- **原生集成**：FFI（`dart:ffi`）直调 Windows API；DLL 注入型手柄适配走 SDL3 + `SendInput`
- **加密**：`pointycastle`（AES / Serpent / Twofish / Blowfish / Skein / SHA3 / Argon2id / HKDF），Windows 凭据加密走 DPAPI
- **AI 超分**：Magpie（集成启动，非入库内容）

---

## 许可证与致谢

### 致谢

- [PocketBase](https://pocketbase.io/) —— 开源后端即服务
- [Alist](https://alist.nn.ci/) —— 文件列表程序
- [VNDB](https://vndb.org/) —— 视觉小说数据库
- [Bangumi](https://bangumi.tv/) —— 番组计划
- [KunGal](https://www.kungal.com/) —— 鲲Gal
- [hikarinagi](https://www.hikarinagi.org/) —— hikarinagi 元数据源
- [Locale Emulator](https://xupefei.github.io/Locale-Emulator/) —— 区域模拟器
- [ludusavi](https://github.com/mtkennerly/ludusavi) —— 游戏存档备份工具灵感
- [Magpie](https://github.com/bluelovers/Magpie) —— AI 超分

### 许可证

见 [LICENSE](./LICENSE)。
