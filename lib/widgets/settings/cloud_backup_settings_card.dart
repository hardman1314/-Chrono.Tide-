/// 设置页「云备份」卡片 —— Phase 5（方案 §7 / LunaBox 骨架 Flutter 版）。
///
/// 🔴 与 [ArchiveLibrarySettingsCard] 同款原则：字段改后显式「保存」，
/// 测试连接用**当前表单值**（不要求先保存）。所有密码框留空 = 保留已存
/// 密文（密码恒 DPAPI 密文落盘，本卡片永不持有明文副本过生命周期）。
///
/// 二期新增：通道双选（WebDAV / S3 兼容）、客户端加密（备份密码）、
/// 自动同步（开关 + 频率 + 立即同步）。
import 'package:flutter/material.dart';

import '../../services/cloud_backup/cloud_backup_service.dart';
import '../../services/cloud_backup/cloud_storage_provider.dart';
import '../../services/cloud_backup/s3_provider.dart';
import '../../services/cloud_backup/webdav_provider.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_style.dart';

class CloudBackupSettingsCard extends StatefulWidget {
  const CloudBackupSettingsCard({super.key});

  @override
  State<CloudBackupSettingsCard> createState() =>
      _CloudBackupSettingsCardState();
}

class _CloudBackupSettingsCardState extends State<CloudBackupSettingsCard> {
  // WebDAV
  final _baseUrl = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  // S3
  final _s3Endpoint = TextEditingController();
  final _s3Region = TextEditingController();
  final _s3Bucket = TextEditingController();
  final _s3AccessKey = TextEditingController();
  final _s3Secret = TextEditingController();
  // 通用 / 加密
  final _root = TextEditingController();
  final _encryptPassword = TextEditingController();

  bool _loading = true;
  bool _enabled = false;
  CloudProviderType _providerType = CloudProviderType.webdav;
  bool _encryptEnabled = false;
  bool _autoSync = false;
  CloudAutoSyncEvery _autoSyncEvery = CloudAutoSyncEvery.startup;
  String _lastSyncAt = '';
  double _keepCount = 10;
  bool _busy = false;
  bool _syncing = false;
  String? _message;
  bool _messageOk = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _baseUrl.dispose();
    _username.dispose();
    _password.dispose();
    _s3Endpoint.dispose();
    _s3Region.dispose();
    _s3Bucket.dispose();
    _s3AccessKey.dispose();
    _s3Secret.dispose();
    _root.dispose();
    _encryptPassword.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final c = await CloudBackupService.instance.loadConfig();
    if (!mounted) return;
    setState(() {
      _enabled = c.enabled;
      _providerType = c.providerType;
      _baseUrl.text = c.baseUrl;
      _username.text = c.username;
      _s3Endpoint.text = c.s3Endpoint;
      _s3Region.text = c.s3Region;
      _s3Bucket.text = c.s3Bucket;
      _s3AccessKey.text = c.s3AccessKey;
      _root.text = c.backupRoot;
      _encryptEnabled = c.encryptEnabled;
      _autoSync = c.autoSync;
      _autoSyncEvery = c.autoSyncEvery;
      _lastSyncAt = c.lastAutoSyncAt;
      _keepCount = c.keepCount.toDouble();
      _loading = false;
    });
  }

  void _showMessage(String msg, {required bool ok}) {
    if (!mounted) return;
    setState(() {
      _message = msg;
      _messageOk = ok;
    });
  }

  /// 用当前表单值构造配置（各密码留空 = 保留已存密文）。
  CloudBackupConfig _configFromForm() => CloudBackupConfig(
        enabled: _enabled,
        providerType: _providerType,
        baseUrl: _baseUrl.text.trim(),
        username: _username.text.trim(),
        encryptedPasswordB64: '',
        s3Endpoint: _s3Endpoint.text.trim(),
        s3Region: _s3Region.text.trim(),
        s3Bucket: _s3Bucket.text.trim(),
        s3AccessKey: _s3AccessKey.text.trim(),
        s3SecretEnc: '',
        backupRoot: _root.text.trim().isEmpty
            ? 'ChronoTide'
            : _root.text.trim(),
        keepCount: _keepCount.round(),
        encryptEnabled: _encryptEnabled,
        encryptPasswordEnc: '',
        autoSync: _autoSync,
        autoSyncEvery: _autoSyncEvery,
        lastAutoSyncAt: _lastSyncAt,
      );

  /// 保存：把留空的密码字段还原为已存密文；非空则重新 DPAPI 加密。
  Future<void> _save() async {
    if (_busy) return;
    final cfg = _configFromForm();
    final saved = await CloudBackupService.instance.loadConfig();
    // 未填的新密文沿用旧值（通道切换后各自独立）
    final cfgMerged = cfg.copyWith(
      encryptedPasswordB64:
          _password.text.isEmpty ? saved.encryptedPasswordB64 : null,
      s3SecretEnc: _s3Secret.text.isEmpty ? saved.s3SecretEnc : null,
      encryptPasswordEnc:
          _encryptPassword.text.isEmpty ? saved.encryptPasswordEnc : null,
    );
    setState(() => _busy = true);
    try {
      await CloudBackupService.instance.saveConfig(
        cfgMerged,
        plainPassword: _password.text.isEmpty ? null : _password.text,
        plainS3Secret: _s3Secret.text.isEmpty ? null : _s3Secret.text,
        plainBackupPassword:
            _encryptPassword.text.isEmpty ? null : _encryptPassword.text,
      );
      await _load();
      _showMessage('云备份配置已保存。', ok: true);
      if (mounted) {
        setState(() {
          _password.clear();
          _s3Secret.clear();
          _encryptPassword.clear();
        });
      }
    } catch (e) {
      _showMessage('保存失败：$e', ok: false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testConnection() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final saved = await CloudBackupService.instance.loadConfig();
      if (_providerType == CloudProviderType.webdav) {
        if (_baseUrl.text.trim().isEmpty) {
          _showMessage('请先填写 WebDAV 服务地址', ok: false);
          return;
        }
        final pw = _password.text.isNotEmpty
            ? _password.text
            : (saved.hasPassword
                ? await CloudBackupService.instance.decryptPassword(saved)
                : '');
        final provider = WebDavProvider(
          baseUrl: _baseUrl.text.trim(),
          username: _username.text.trim(),
          password: pw,
        );
        await provider.testConnection();
        _showMessage('连接成功 ✅ WebDAV 服务可达。', ok: true);
      } else {
        if (_s3Endpoint.text.trim().isEmpty || _s3Bucket.text.trim().isEmpty) {
          _showMessage('请先填写 S3 endpoint 与 bucket', ok: false);
          return;
        }
        final secret = _s3Secret.text.isNotEmpty
            ? _s3Secret.text
            : (saved.hasS3Secret
                ? await CloudBackupService.instance.decryptS3Secret(saved)
                : '');
        final provider = S3Provider(
          endpoint: _s3Endpoint.text.trim(),
          region: _s3Region.text.trim().isEmpty
              ? 'us-east-1'
              : _s3Region.text.trim(),
          bucket: _s3Bucket.text.trim(),
          accessKey: _s3AccessKey.text.trim(),
          secretKey: secret,
        );
        await provider.testConnection();
        _showMessage('连接成功 ✅ S3 服务可达。', ok: true);
      }
    } on CloudStorageException catch (e) {
      _showMessage(e.message, ok: false);
    } catch (e) {
      _showMessage('连接失败：$e', ok: false);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() async {
    if (_syncing) return;
    setState(() {
      _syncing = true;
      _message = null;
    });
    try {
      final r = await CloudBackupService.instance.autoSyncIfDue(force: true);
      _showMessage('立即同步完成：${r.summary}'
          '${r.messages.isEmpty ? '' : '\n${r.messages.take(3).join('\n')}'}',
          ok: r.failed == 0);
      if (mounted) setState(() => _lastSyncAt = DateTime.now().toIso8601String());
    } catch (e) {
      _showMessage('同步失败：$e', ok: false);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppStyle.isModern
            ? AppColors.buttonBackground
            : AppColors.sidebarBackground,
        border: AppStyle.isModern
            ? Border.all(
                color: AppColors.borderLight, width: AppStyle.wHairline)
            : Border.all(color: AppColors.border, width: 1.6),
        boxShadow: AppStyle.isModern
            ? AppStyle.e1
            : [
                BoxShadow(
                  color: AppColors.borderLight,
                  offset: const Offset(2, 2),
                  blurRadius: 0,
                ),
              ],
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ---- 标题 + 启用开关 ----
          Row(
            children: [
              Expanded(
                child: Text(
                  '云备份',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    height: 24 / 16,
                    color: AppColors.primaryText,
                  ),
                ),
              ),
              Switch(
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '把游戏归档上传到你自己的网盘（WebDAV 或 S3 兼容源）。'
            '密码经 Windows DPAPI 加密存储，仅本机当前用户可解密。',
            style: TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: 13,
              height: 18 / 13,
              color: AppColors.secondaryText,
            ),
          ),
          const SizedBox(height: 12),

          // ---- 通道双选 ----
          _sectionLabel('通道'),
          const SizedBox(height: 6),
          Row(
            children: [
              _channelChip(CloudProviderType.webdav, 'WebDAV', '坚果云 / Nextcloud / NAS'),
              const SizedBox(width: 8),
              _channelChip(CloudProviderType.s3, 'S3 兼容', 'AWS / R2 / OSS / MinIO'),
            ],
          ),
          const SizedBox(height: 10),

          // ---- 通道表单 ----
          if (_providerType == CloudProviderType.webdav) ...[
            _field(
              controller: _baseUrl,
              label: 'WebDAV 服务地址',
              hint: 'https://dav.jianguoyun.com/dav/',
            ),
            const SizedBox(height: 8),
            _field(controller: _username, label: '账号', hint: '登录邮箱 / 用户名'),
            const SizedBox(height: 8),
            _field(
              controller: _password,
              label: '密码（留空 = 保留已存密码）',
              hint: '坚果云请使用「应用密码」',
              obscure: true,
            ),
          ] else ...[
            _field(
              controller: _s3Endpoint,
              label: 'S3 Endpoint',
              hint: 'https://s3.us-east-1.amazonaws.com',
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _field(controller: _s3Region, label: 'Region', hint: 'us-east-1'),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _field(controller: _s3Bucket, label: 'Bucket', hint: 'my-backup'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _field(controller: _s3AccessKey, label: 'AccessKey', hint: 'AKIA…'),
            const SizedBox(height: 8),
            _field(
              controller: _s3Secret,
              label: 'SecretKey（留空 = 保留已存）',
              hint: '',
              obscure: true,
            ),
          ],
          const SizedBox(height: 8),
          _field(controller: _root, label: '云端备份根目录', hint: 'ChronoTide'),
          const SizedBox(height: 10),

          // ---- 保留份数 ----
          Text(
            '云端每游戏保留份数：${_keepCount.round()}（50 = 不自动清理）',
            style: TextStyle(fontSize: 12.5, color: AppColors.primaryText),
          ),
          Slider(
            value: _keepCount,
            min: 1,
            max: 50,
            divisions: 49,
            onChanged: (v) => setState(() => _keepCount = v),
          ),

          // ---- 客户端加密 ----
          _expansion(
            title: '客户端加密（推荐开启）',
            subtitle: '上传前用备份密码再打一层加密 7z，云端看不到明文',
            initiallyExpanded: false,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '开启后云端只存加密包（标准 7z，忘掉本应用也能用密码解开）',
                      style: TextStyle(
                          fontSize: 12, color: AppColors.secondaryText),
                    ),
                  ),
                  Switch(
                    value: _encryptEnabled,
                    onChanged: (v) => setState(() => _encryptEnabled = v),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              _field(
                controller: _encryptPassword,
                label: '备份密码（留空 = 保留已存）',
                hint: '建议与云服务密码不同；避免使用英文双引号',
                obscure: true,
              ),
              const SizedBox(height: 4),
              Text(
                '⚠️ 备份密码遗失 = 云端备份无法解密（没有找回手段）',
                style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: AppColors.warningAmber),
              ),
            ],
          ),
          const SizedBox(height: 6),

          // ---- 自动同步 ----
          _expansion(
            title: '自动同步',
            subtitle: '到期后自动把本地新增归档补传云端（只增不删）',
            initiallyExpanded: false,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('开启自动同步',
                        style: TextStyle(
                            fontSize: 12.5, color: AppColors.primaryText)),
                  ),
                  Switch(
                    value: _autoSync,
                    onChanged: (v) => setState(() => _autoSync = v),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text('频率',
                      style: TextStyle(
                          fontSize: 12.5, color: AppColors.secondaryText)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButton<CloudAutoSyncEvery>(
                      value: _autoSyncEvery,
                      isExpanded: true,
                      items: [
                        for (final e in CloudAutoSyncEvery.values)
                          DropdownMenuItem(
                            value: e,
                            child: Text(e.label,
                                style: TextStyle(
                                    fontSize: 12.5,
                                    color: AppColors.primaryText)),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) {
                          setState(() => _autoSyncEvery = v);
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton(
                    onPressed: _syncing ? null : _syncNow,
                    child: Text(_syncing ? '同步中…' : '立即同步全部'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _lastSyncAt.isEmpty
                          ? '从未同步'
                          : '上次：${_lastSyncAt.substring(0, 19).replaceAll('T', ' ')}',
                      style: TextStyle(
                          fontSize: 12, color: AppColors.secondaryText),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),

          // ---- 动作区 ----
          Row(
            children: [
              OutlinedButton(
                onPressed: _busy ? null : _testConnection,
                child: const Text('测试连接'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _busy ? null : _save,
                child: const Text('保存配置'),
              ),
            ],
          ),
          if (_message != null) ...[
            const SizedBox(height: 8),
            Text(
              _message!,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: _messageOk
                    ? AppColors.successGreen
                    : AppColors.dangerRed,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 小部件
  // ---------------------------------------------------------------------------

  Widget _sectionLabel(String text) => Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          color: AppColors.secondaryText,
        ),
      );

  Widget _channelChip(CloudProviderType type, String title, String desc) {
    final selected = _providerType == type;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _providerType = type),
        borderRadius: BorderRadius.circular(6),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: selected ? AppColors.selectedAccent : AppColors.background,
            border: Border.all(
              color: selected ? AppColors.selectedAccent : AppColors.border,
              width: 1.4,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: selected
                      ? Colors.white
                      : AppColors.primaryText,
                ),
              ),
              Text(
                desc,
                style: TextStyle(
                  fontSize: 11,
                  color: selected
                      ? Colors.white.withOpacity(0.85)
                      : AppColors.secondaryText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _expansion({
    required String title,
    required String subtitle,
    required bool initiallyExpanded,
    required List<Widget> children,
  }) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        initiallyExpanded: initiallyExpanded,
        iconColor: AppColors.secondaryText,
        collapsedIconColor: AppColors.secondaryText,
        title: Text(
          title,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: AppColors.primaryText,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(fontSize: 11.5, color: AppColors.secondaryText),
        ),
        children: children,
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String hint,
    bool obscure = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(fontSize: 12.5, color: AppColors.secondaryText)),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          obscureText: obscure,
          style: TextStyle(fontSize: 13, color: AppColors.primaryText),
          decoration: InputDecoration(
            isDense: true,
            hintText: hint,
            hintStyle:
                TextStyle(fontSize: 12, color: AppColors.secondaryText),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
          ),
        ),
      ],
    );
  }
}
