/// 云备份服务 —— Phase 5 编排层（方案 §7 / LunaBox 模式 Flutter 版）。
///
/// 职责：
/// - 配置持久化：**所有秘密（云服务密码 / S3 SecretKey / 客户端备份密码）
///   必须经 DPAPI 加密**后落 SharedPreferences（Q10 红线，⛔ 明文 JSON 是
///   LunaBox 反面教材）；其余配置明文（无敏感性）。
/// - 上传归档：本地 `<归档库根>/<gameId>/<归档id>/` → 云端
///   `<备份根>/<gameId>/<归档id>/`（与本地同构；meta.json 一并上传）。
///   客户端加密开启时（二期），先打成加密 7z 再上传（单对象 enc_backup.7z）。
/// - 云端归档列表 / 删除 / 下载（拉回本地归档库，加密物自动解密）。
/// - 云端保留份数清理（上传成功后触发）。
/// - 自动同步（二期）：启动/每天/每周窗口到期时，对比云端缺失归档补传。
///
/// Provider：WebDAV（一期）+ S3 兼容（二期，SigV4 已官方向量锁定）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../archive_library_preference.dart';
import '../../core/path_helper.dart';
import 'archive_cryptor.dart';
import 'cloud_storage_provider.dart';
import 'dpapi_helper.dart';
import 's3_provider.dart';
import 'webdav_provider.dart';

// ---------------------------------------------------------------------------
// 配置
// ---------------------------------------------------------------------------

enum CloudProviderType { webdav, s3 }

extension CloudProviderTypeX on CloudProviderType {
  String get wire => name;
  String get label => this == CloudProviderType.webdav ? 'WebDAV' : 'S3 兼容';

  static CloudProviderType fromWire(String v) => v == 's3'
      ? CloudProviderType.s3
      : CloudProviderType.webdav; // 缺省/未知回 webdav
}

/// 自动同步频率。
enum CloudAutoSyncEvery { startup, daily, weekly }

extension CloudAutoSyncEveryX on CloudAutoSyncEvery {
  String get wire => name;
  String get label => switch (this) {
        CloudAutoSyncEvery.startup => '每天启动时',
        CloudAutoSyncEvery.daily => '每 24 小时',
        CloudAutoSyncEvery.weekly => '每 7 天',
      };

  static CloudAutoSyncEvery fromWire(String v) =>
      v == 'daily'
          ? CloudAutoSyncEvery.daily
          : v == 'weekly'
              ? CloudAutoSyncEvery.weekly
              : CloudAutoSyncEvery.startup;
}

class CloudBackupConfig {
  final bool enabled;
  final CloudProviderType providerType;

  // ---- WebDAV ----
  final String baseUrl;
  final String username;
  final String encryptedPasswordB64; // DPAPI 密文 base64；空 = 未设置

  // ---- S3 兼容（二期）----
  final String s3Endpoint; // 如 https://s3.us-east-1.amazonaws.com
  final String s3Region; // 如 us-east-1（R2 用 auto）
  final String s3Bucket;
  final String s3AccessKey;
  final String s3SecretEnc; // DPAPI 密文 base64

  // ---- 通用 ----
  final String backupRoot; // 云端备份根目录名，如 'ChronoTide'
  final int keepCount; // 云端每游戏保留份数（1..50）

  // ---- 客户端加密（二期）：上传前打加密 7z ----
  final bool encryptEnabled;
  final String encryptPasswordEnc; // DPAPI 密文 base64

  // ---- 自动同步（二期）----
  final bool autoSync;
  final CloudAutoSyncEvery autoSyncEvery;
  final String lastAutoSyncAt; // ISO8601；空 = 从未

  const CloudBackupConfig({
    this.enabled = false,
    this.providerType = CloudProviderType.webdav,
    this.baseUrl = '',
    this.username = '',
    this.encryptedPasswordB64 = '',
    this.s3Endpoint = '',
    this.s3Region = '',
    this.s3Bucket = '',
    this.s3AccessKey = '',
    this.s3SecretEnc = '',
    this.backupRoot = 'ChronoTide',
    this.keepCount = 10,
    this.encryptEnabled = false,
    this.encryptPasswordEnc = '',
    this.autoSync = false,
    this.autoSyncEvery = CloudAutoSyncEvery.startup,
    this.lastAutoSyncAt = '',
  });

  bool get hasPassword => encryptedPasswordB64.isNotEmpty;
  bool get hasS3Secret => s3SecretEnc.isNotEmpty;
  bool get hasEncryptPassword => encryptPasswordEnc.isNotEmpty;

  CloudBackupConfig copyWith({
    bool? enabled,
    CloudProviderType? providerType,
    String? baseUrl,
    String? username,
    String? encryptedPasswordB64,
    String? s3Endpoint,
    String? s3Region,
    String? s3Bucket,
    String? s3AccessKey,
    String? s3SecretEnc,
    String? backupRoot,
    int? keepCount,
    bool? encryptEnabled,
    String? encryptPasswordEnc,
    bool? autoSync,
    CloudAutoSyncEvery? autoSyncEvery,
    String? lastAutoSyncAt,
  }) =>
      CloudBackupConfig(
        enabled: enabled ?? this.enabled,
        providerType: providerType ?? this.providerType,
        baseUrl: baseUrl ?? this.baseUrl,
        username: username ?? this.username,
        encryptedPasswordB64:
            encryptedPasswordB64 ?? this.encryptedPasswordB64,
        s3Endpoint: s3Endpoint ?? this.s3Endpoint,
        s3Region: s3Region ?? this.s3Region,
        s3Bucket: s3Bucket ?? this.s3Bucket,
        s3AccessKey: s3AccessKey ?? this.s3AccessKey,
        s3SecretEnc: s3SecretEnc ?? this.s3SecretEnc,
        backupRoot: backupRoot ?? this.backupRoot,
        keepCount: keepCount ?? this.keepCount,
        encryptEnabled: encryptEnabled ?? this.encryptEnabled,
        encryptPasswordEnc: encryptPasswordEnc ?? this.encryptPasswordEnc,
        autoSync: autoSync ?? this.autoSync,
        autoSyncEvery: autoSyncEvery ?? this.autoSyncEvery,
        lastAutoSyncAt: lastAutoSyncAt ?? this.lastAutoSyncAt,
      );

  Map<String, dynamic> toWire() => {
        'enabled': enabled,
        'providerType': providerType.wire,
        'baseUrl': baseUrl,
        'username': username,
        'password_enc': encryptedPasswordB64, // 🔴 恒为 DPAPI 密文
        's3Endpoint': s3Endpoint,
        's3Region': s3Region,
        's3Bucket': s3Bucket,
        's3AccessKey': s3AccessKey,
        's3Secret_enc': s3SecretEnc, // 🔴 恒为 DPAPI 密文
        'backupRoot': backupRoot,
        'keepCount': keepCount,
        'encryptEnabled': encryptEnabled,
        'encryptPassword_enc': encryptPasswordEnc, // 🔴 恒为 DPAPI 密文
        'autoSync': autoSync,
        'autoSyncEvery': autoSyncEvery.wire,
        'lastAutoSyncAt': lastAutoSyncAt,
      };

  static CloudBackupConfig fromWire(Map<String, dynamic> j) =>
      CloudBackupConfig(
        enabled: j['enabled'] == true,
        providerType:
            CloudProviderTypeX.fromWire(j['providerType'] as String? ?? ''),
        baseUrl: j['baseUrl'] as String? ?? '',
        username: j['username'] as String? ?? '',
        encryptedPasswordB64: j['password_enc'] as String? ?? '',
        s3Endpoint: j['s3Endpoint'] as String? ?? '',
        s3Region: j['s3Region'] as String? ?? '',
        s3Bucket: j['s3Bucket'] as String? ?? '',
        s3AccessKey: j['s3AccessKey'] as String? ?? '',
        s3SecretEnc: j['s3Secret_enc'] as String? ?? '',
        backupRoot: j['backupRoot'] as String? ?? 'ChronoTide',
        keepCount: (j['keepCount'] as int?) ?? 10,
        encryptEnabled: j['encryptEnabled'] == true,
        encryptPasswordEnc: j['encryptPassword_enc'] as String? ?? '',
        autoSync: j['autoSync'] == true,
        autoSyncEvery: CloudAutoSyncEveryX.fromWire(
            j['autoSyncEvery'] as String? ?? ''),
        lastAutoSyncAt: j['lastAutoSyncAt'] as String? ?? '',
      );
}

// ---------------------------------------------------------------------------
// 结果模型
// ---------------------------------------------------------------------------

class CloudUploadResult {
  final bool ok;
  final String? error;
  final List<String> warnings;
  final String? remoteDir; // 成功时：云端归档目录（相对路径）

  const CloudUploadResult._(this.ok,
      {this.error, this.warnings = const [], this.remoteDir});

  factory CloudUploadResult.fail(String msg) => CloudUploadResult._(false, error: msg);
  factory CloudUploadResult.success(String remoteDir, {List<String> warnings = const []}) =>
      CloudUploadResult._(true, remoteDir: remoteDir, warnings: warnings);
}

/// 自动同步结果（UI 展示 / 日志用）。
class AutoSyncReport {
  final bool ran; // 是否真的跑了（false = 因窗口/配置跳过）
  final String? reason; // ran=false 的原因
  final bool isDryRun; // 试运行（只统计不真传）
  int uploaded = 0;
  int failed = 0;
  int pending = 0; // isDryRun 时的待传数
  final List<String> messages = [];

  AutoSyncReport({required this.ran, this.reason, this.isDryRun = false});

  String get summary {
    if (!ran) return reason ?? '已跳过';
    if (isDryRun) return '发现 $pending 个归档待上传';
    return '上传 $uploaded 个${failed > 0 ? '，失败 $failed 个' : ''}';
  }
}

// ---------------------------------------------------------------------------
// 服务
// ---------------------------------------------------------------------------

class CloudBackupService {
  CloudBackupService._();
  static final CloudBackupService instance = CloudBackupService._();

  /// 客户端加密用的 7z 封装（bundled 7z，惰性构造）。
  ArchiveCryptor get _cryptor =>
      ArchiveCryptor(sevenZipPath: PathHelper.bundled7zPath);

  static const String _prefsKey = 'cloud_backup_config_v1';

  /// 最近一次测试连接结果（UI 状态展示用，不持久化）。
  String? lastTestMessage;

  // ==================== 配置存取 ====================

  Future<CloudBackupConfig> loadConfig() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return const CloudBackupConfig();
      return CloudBackupConfig.fromWire(
          jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const CloudBackupConfig();
    }
  }

  /// 保存配置。三个明文密码参数非 null 时重新加密；null = 保留原密文。
  Future<void> saveConfig(
    CloudBackupConfig config, {
    String? plainPassword,
    String? plainS3Secret,
    String? plainBackupPassword,
  }) async {
    var c = config;
    if (plainPassword != null && plainPassword.isNotEmpty) {
      c = c.copyWith(
          encryptedPasswordB64: DpapiHelper.protectToBase64(plainPassword));
    }
    if (plainS3Secret != null && plainS3Secret.isNotEmpty) {
      c = c.copyWith(
          s3SecretEnc: DpapiHelper.protectToBase64(plainS3Secret));
    }
    if (plainBackupPassword != null && plainBackupPassword.isNotEmpty) {
      c = c.copyWith(
          encryptPasswordEnc:
              DpapiHelper.protectToBase64(plainBackupPassword));
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, jsonEncode(c.toWire()));
  }

  /// 解出明文密码（仅在需要建立连接时调用；解不开抛异常，UI 引导重填）。
  Future<String> decryptPassword(CloudBackupConfig config) async {
    if (!config.hasPassword) {
      throw CloudStorageException('尚未设置密码');
    }
    return _decryptField(config.encryptedPasswordB64, '云服务密码');
  }

  /// 解出 S3 SecretKey。
  Future<String> decryptS3Secret(CloudBackupConfig config) async {
    if (!config.hasS3Secret) {
      throw CloudStorageException('尚未设置 SecretKey');
    }
    return _decryptField(config.s3SecretEnc, 'SecretKey');
  }

  /// 解出客户端备份密码（加密打包用）。
  Future<String> decryptBackupPassword(CloudBackupConfig config) async {
    if (!config.hasEncryptPassword) {
      throw CloudStorageException('尚未设置备份密码');
    }
    return _decryptField(config.encryptPasswordEnc, '备份密码');
  }

  Future<String> _decryptField(String encB64, String what) async {
    try {
      return DpapiHelper.unprotectFromBase64(encB64);
    } catch (_) {
      throw CloudStorageException(
          '$what 解密失败（换了 Windows 用户或重装系统后需重新填写）');
    }
  }

  /// 按配置构造 Provider。
  Future<CloudStorageProvider> makeProvider(CloudBackupConfig config) async {
    switch (config.providerType) {
      case CloudProviderType.webdav:
        if (config.baseUrl.isEmpty) {
          throw CloudStorageException('尚未配置 WebDAV 服务地址');
        }
        return WebDavProvider(
          baseUrl: config.baseUrl,
          username: config.username,
          password: await decryptPassword(config),
        );
      case CloudProviderType.s3:
        if (config.s3Endpoint.isEmpty || config.s3Bucket.isEmpty) {
          throw CloudStorageException('尚未配置 S3 endpoint / bucket');
        }
        return S3Provider(
          endpoint: config.s3Endpoint,
          region: config.s3Region.isEmpty ? 'us-east-1' : config.s3Region,
          bucket: config.s3Bucket,
          accessKey: config.s3AccessKey,
          secretKey: await decryptS3Secret(config),
        );
    }
  }

  /// 是否开启客户端加密（加密打包上传）。
  Future<bool> isEncryptionOn(CloudBackupConfig config) async =>
      config.encryptEnabled && config.hasEncryptPassword;

  // ==================== 云端路径约定 ====================

  /// 云端结构：`<备份根>/<gameId>/<归档id>/<文件>`（与本地归档库同构）。
  String remoteArchiveDir(CloudBackupConfig config, String gameId, String archiveId) {
    final root = config.backupRoot.trim().replaceAll('/', '_');
    return '${root.isEmpty ? 'ChronoTide' : root}/$gameId/$archiveId';
  }

  // ==================== 上传 ====================

  /// 上传一个本地归档目录到云端。
  ///
  /// [archiveDir] 必须是**已转正**的归档目录（不含 .partial）。
  /// 同 id 已存在时按 [overwrite] 决定（默认跳过 —— 归档 id 含秒级时间戳，
  /// 正常不会撞；撞 = 用户主动重传或异常，明示跳过）。
  Future<CloudUploadResult> uploadArchive({
    required String gameId,
    required String archiveDir,
    required CloudBackupConfig config,
    bool overwrite = false,
    void Function(int percent)? onProgress,
  }) async {
    final dir = Directory(archiveDir);
    if (!await dir.exists()) {
      return CloudUploadResult.fail('本地归档目录不存在：$archiveDir');
    }
    final archiveId =
        archiveDir.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last;
    if (archiveId.endsWith('.partial')) {
      return CloudUploadResult.fail('归档尚未完成（.partial），不能上传');
    }

    final provider = await makeProvider(config);
    final remoteDir = remoteArchiveDir(config, gameId, archiveId);

    try {
      // 同 id 已存在？默认跳过（幂等防呆）
      if (!overwrite) {
        final existing = await provider.list(remoteDir);
        if (existing.isNotEmpty) {
          return CloudUploadResult.fail('云端已存在同名归档（如需重传请在设置中开启覆盖）');
        }
      }

      await provider.ensureDir(remoteDir);

      // ---------- 客户端加密模式（二期）----------
      if (await isEncryptionOn(config)) {
        final password = await decryptBackupPassword(config);
        final tempDir =
            await Directory.systemTemp.createTemp('ct_cloud_enc_');
        try {
          final encFile = File('${tempDir.path}/enc_backup.7z');
          final packed = await _cryptor.packEncrypted(
            sourceDir: archiveDir,
            outputArchive: encFile.path,
            password: password,
            onProgress: (p) {
              // 加密阶段映射 0~30%
              onProgress?.call((p * 30 ~/ 100).clamp(0, 30));
            },
          );
          if (!packed.ok) {
            return CloudUploadResult.fail(
                '加密打包失败：${packed.error ?? '未知错误'}');
          }
          await provider.uploadFile('$remoteDir/enc_backup.7z', encFile,
              onProgress: (s, t) {
            // 上传阶段映射 30~100%
            final up = t == 0 ? 100 : (s * 100 ~/ t);
            onProgress?.call(30 + up * 70 ~/ 100);
          });
          onProgress?.call(100);
          return await _finishUpload(config, gameId, remoteDir);
        } finally {
          await _deleteTempQuietly(tempDir);
        }
      }

      // ---------- 明文模式（一期行为）----------
      final files = await dir
          .list()
          .where((e) => e is File)
          .cast<File>()
          .toList();
      if (files.isEmpty) {
        return CloudUploadResult.fail('归档目录为空：$archiveDir');
      }

      // 总字节 → 汇总进度
      final totalBytes = <File, int>{};
      var sum = 0;
      for (final f in files) {
        final sz = await f.length();
        totalBytes[f] = sz;
        sum += sz;
      }

      var sent = 0;
      final warnings = <String>[];
      for (final f in files) {
        final name =
            f.path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last;
        final remote = '$remoteDir/$name';
        try {
          await provider.uploadFile(remote, f, onProgress: (s, t) {
            onProgress?.call(((sent + s) * 100 ~/ (sum == 0 ? 1 : sum)).clamp(0, 100));
          });
        } catch (e) {
          // meta.json 很小：重试一次；其余文件失败直接中止（归档必须完整）
          if (name == 'meta.json') {
            try {
              await provider.uploadFile(remote, f, onProgress: (_, __) {});
            } catch (e2) {
              return CloudUploadResult.fail('上传 $name 失败：$e2');
            }
          } else {
            return CloudUploadResult.fail('上传「$name」失败：$e');
          }
        }
        sent += totalBytes[f]!;
        onProgress?.call((sent * 100 ~/ (sum == 0 ? 1 : sum)).clamp(0, 100));
      }

      // 云端保留份数清理（失败仅警告，不影响上传结果）
      try {
        await _pruneCloud(config, gameId, config.keepCount);
      } catch (e) {
        warnings.add('云端清理旧归档失败（不影响本次上传）：$e');
      }

      return CloudUploadResult.success(remoteDir, warnings: warnings);
    } on CloudStorageException catch (e) {
      return CloudUploadResult.fail(e.message);
    } catch (e) {
      return CloudUploadResult.fail('上传异常：$e');
    }
  }

  /// 加密上传的收尾：保留份数清理（与明文模式一致）。
  Future<CloudUploadResult> _finishUpload(
      CloudBackupConfig config, String gameId, String remoteDir) async {
    final warnings = <String>[];
    try {
      await _pruneCloud(config, gameId, config.keepCount);
    } catch (e) {
      warnings.add('云端清理旧归档失败（不影响本次上传）：$e');
    }
    return CloudUploadResult.success(remoteDir, warnings: warnings);
  }

  /// 静默删除临时目录（尽力而为）。
  Future<void> _deleteTempQuietly(Directory dir) async {
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  // ==================== 云端归档管理 ====================

  /// 列出某游戏在云端的归档目录（CloudObject.name = 归档 id）。
  Future<List<CloudObject>> listCloudArchives(
      CloudBackupConfig config, String gameId) async {
    final provider = await makeProvider(config);
    final root = config.backupRoot.trim().replaceAll('/', '_');
    return provider.list('$root/$gameId');
  }

  /// 删除云端归档目录（幂等）。
  Future<void> deleteCloudArchive(
      CloudBackupConfig config, String gameId, String archiveId) async {
    final provider = await makeProvider(config);
    await provider.deleteObject(remoteArchiveDir(config, gameId, archiveId));
  }

  /// 下载云端归档到本地归档库 `<root>/<gameId>/<archiveId>/`。
  /// 目标已存在 = 拒绝（本地已有一份，无意义覆盖）。
  /// 云端是加密物（enc_backup.7z）时自动解密还原（密码错误清空半成品并明示）。
  Future<CloudUploadResult> downloadArchive({
    required String gameId,
    required String archiveId,
    required CloudBackupConfig config,
    void Function(int percent)? onProgress,
  }) async {
    final provider = await makeProvider(config);
    final remoteDir = remoteArchiveDir(config, gameId, archiveId);
    final remoteObjs = await provider.list(remoteDir);
    if (remoteObjs.isEmpty) {
      return CloudUploadResult.fail('云端归档不存在或为空：$remoteDir');
    }
    final localRoot = ArchiveLibraryPreference.instance.rootPath;
    if (localRoot.isEmpty) {
      return CloudUploadResult.fail('请先在设置中配置归档库位置');
    }
    final localDir = Directory('$localRoot/$gameId/$archiveId');
    if (await localDir.exists()) {
      return CloudUploadResult.fail('本地已存在该归档：${localDir.path}');
    }
    await localDir.create(recursive: true);

    try {
      // ---------- 加密物：单对象 enc_backup.7z → 下载 → 解密 ----------
      final encrypted =
          remoteObjs.any((o) => !o.isDir && o.name == 'enc_backup.7z');
      if (encrypted) {
        final password = await decryptBackupPassword(config);
        final tempDir =
            await Directory.systemTemp.createTemp('ct_cloud_dec_');
        try {
          final encFile = File('${tempDir.path}/enc_backup.7z');
          await provider.downloadFile('$remoteDir/enc_backup.7z', encFile,
              onProgress: (r, t) {
            final p = t == 0 ? 0 : (r * 70 ~/ t); // 下载 0~70%
            onProgress?.call(p.clamp(0, 70));
          });
          final unpacked = await _cryptor.unpackDecrypted(
            archive: encFile.path,
            targetDir: localDir.path,
            password: password,
            onProgress: (p) =>
                onProgress?.call((70 + p * 30 ~/ 100).clamp(0, 100)),
          );
          if (!unpacked.ok) {
            // 半成品不留：密码错/归档损坏都不允许脏目录存在
            await _deleteTempQuietly(localDir);
            return CloudUploadResult.fail(
                unpacked.wrongPassword ? '备份密码错误' : '解密失败：${unpacked.error}');
          }
          onProgress?.call(100);
          return CloudUploadResult.success(localDir.path);
        } finally {
          await _deleteTempQuietly(tempDir);
        }
      }

      // ---------- 明文物：逐文件下载（一期行为）----------
      final total = remoteObjs.fold<int>(0, (a, o) => a + o.size);
      var done = 0;
      for (final o in remoteObjs) {
        if (o.isDir) continue;
        final local = File('${localDir.path}/${o.name}');
        await provider.downloadFile('$remoteDir/${o.name}', local,
            onProgress: (r, t) {
          onProgress?.call(((done + r) * 100 ~/ (total == 0 ? 1 : total)).clamp(0, 100));
        });
        done += o.size;
        onProgress?.call((done * 100 ~/ (total == 0 ? 1 : total)).clamp(0, 100));
      }
      return CloudUploadResult.success(localDir.path);
    } on CloudStorageException catch (e) {
      await _deleteTempQuietly(localDir);
      return CloudUploadResult.fail(e.message);
    } catch (e) {
      await _deleteTempQuietly(localDir);
      return CloudUploadResult.fail('下载异常：$e');
    }
  }

  // ==================== 自动同步（二期） ====================

  /// 判断自动同步窗口是否到期（[force]=跳过窗口检查）。
  bool isAutoSyncDue(CloudBackupConfig config) {
    if (config.lastAutoSyncAt.isEmpty) return true;
    final last = DateTime.tryParse(config.lastAutoSyncAt);
    if (last == null) return true;
    final now = DateTime.now();
    return switch (config.autoSyncEvery) {
      CloudAutoSyncEvery.startup =>
        !(last.year == now.year &&
            last.month == now.month &&
            last.day == now.day), // 每天最多一次
      CloudAutoSyncEvery.daily =>
        now.difference(last) >= const Duration(hours: 24),
      CloudAutoSyncEvery.weekly =>
        now.difference(last) >= const Duration(days: 7),
    };
  }

  /// 自动同步：对比本地归档库与云端，把缺失的归档逐个补传（每游戏最新
  /// keepCount 份内）。触发点（非稳定区）由 UI 层决定（库页 initState /
  /// 「立即同步」按钮）。**只增不删**（云端清理交给每游戏 keepCount 策略）。
  Future<AutoSyncReport> autoSyncIfDue({
    bool force = false,
    bool dryRun = false,
  }) async {
    final config = await loadConfig();
    if (!config.enabled) {
      return AutoSyncReport(ran: false, reason: '云备份未启用');
    }
    if (!config.autoSync && !force) {
      return AutoSyncReport(ran: false, reason: '自动同步未开启');
    }
    if (!force && !isAutoSyncDue(config)) {
      return AutoSyncReport(ran: false, reason: '同步窗口未到期');
    }
    final root = ArchiveLibraryPreference.instance.rootPath;
    if (root.isEmpty) {
      return AutoSyncReport(ran: false, reason: '未配置归档库位置');
    }

    final report = AutoSyncReport(ran: true, isDryRun: dryRun);
    final rootDir = Directory(root);
    if (!await rootDir.exists()) {
      return AutoSyncReport(ran: false, reason: '归档库目录不存在');
    }

    try {
      await for (final entry in rootDir.list()) {
        if (entry is! Directory) continue;
        final gameId =
            entry.path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last;
        // 本地该游戏归档目录（新→旧，排除 .partial），取 keepCount 内
        final localArchives = <String>[];
        await for (final e in entry.list()) {
          if (e is! Directory) continue;
          final name =
              e.path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last;
          if (name.endsWith('.partial')) continue;
          localArchives.add(name);
        }
        if (localArchives.isEmpty) continue;
        localArchives.sort((a, b) => b.compareTo(a)); // 新→旧
        final want = localArchives.take(config.keepCount).toList();

        // 云端已有
        final remote = <String>{};
        try {
          for (final o in await listCloudArchives(config, gameId)) {
            if (o.isDir) remote.add(o.name);
          }
        } on CloudStorageException catch (e) {
          report.failed++;
          report.messages.add('「$gameId」云端列表失败：${e.message}');
          continue;
        }

        // 差集补传
        for (final archiveId in want) {
          if (remote.contains(archiveId)) continue;
          if (dryRun) {
            report.pending++;
            continue;
          }
          final r = await uploadArchive(
            gameId: gameId,
            archiveDir: '${entry.path}/$archiveId',
            config: config,
          );
          if (r.ok) {
            report.uploaded++;
            report.messages.add('已上传「$gameId / $archiveId」');
          } else {
            report.failed++;
            report.messages.add('「$gameId / $archiveId」失败：${r.error}');
          }
        }
      }

      // 回写同步时间（跑了就记，含全部失败 —— 避免每次启动重打失败的网络）
      if (!dryRun) {
        final updated =
            config.copyWith(lastAutoSyncAt: DateTime.now().toIso8601String());
        await saveConfig(updated);
      }
      return report;
    } catch (e) {
      report.messages.add('同步异常：$e');
      return report;
    }
  }

  // ==================== 云端保留份数 ====================

  /// 清理云端某游戏超出 [keepCount] 的最旧归档。
  /// 归档 id 以 `yyyy-MM-dd_HH-mm-ss` 开头（Q15 后带游戏名前缀但时间戳段
  /// 仍在），倒序取前 keepCount，其余删除。
  Future<void> _pruneCloud(
      CloudBackupConfig config, String gameId, int keepCount) async {
    if (keepCount >= 50) return; // 上限值 = 不清理（与本地 Slider 语义一致）
    final provider = await makeProvider(config);
    final root = config.backupRoot.trim().replaceAll('/', '_');
    final dirs =
        (await provider.list('$root/$gameId')).where((o) => o.isDir).toList()
          ..sort((a, b) => b.name.compareTo(a.name)); // 新→旧
    if (dirs.length <= keepCount) return;
    for (final o in dirs.skip(keepCount)) {
      await provider.deleteObject('${o.path}');
    }
  }
}
