import 'dart:async';

import 'package:flutter/material.dart';

import '../widgets/install_confirmation_dialog.dart';
import '../widgets/openlist/openlist_pair_dialog.dart';
import 'file_size_service.dart';
import 'global_install_center.dart';
import 'install_path_preference.dart';
import 'openlist_provision.dart';
import 'openlist_service.dart';

/// 提交结果（2026-09-26 安装审计 P1-3/P3-1）。
enum CloudInstallResult {
  /// 用户在确认弹窗取消了
  cancelled,

  /// 云端 downloadUrl 为空，或直链解析失败
  linkFailed,

  /// 已在安装/队列中（与 submitTask 内部判据一致的同步拒绝）
  duplicate,

  /// 已成功提交（忙碌时自动排队）
  submitted,
}

/// 探索库云端安装的**统一入口**。
///
/// ★ 2026-09-26 安装审计 P0-1 / P1-3 / P3-1：此前桌面详情页与 BPM 探索页
/// 各自实现了一套「确认 → 解析直链 → 组装任务 → 提交」，只有桌面那套接齐了
/// 必需步骤；BPM 复制实现漏了直链解析（`big_picture_discover.dart:582` 把
/// 网盘**路径**当直链提交 → 安装必失败）、urlResolver 与自定义安装位置三项，
/// 且两处 UI 各自复制 InstallTask 组装，新增字段必漏一处（本次 BPM 就漏了
/// 两处）。现收敛为本类，两个入口共用同一份前置流程。
///
/// UI 反馈（SnackBar 文案、弹窗关闭）刻意留在调用方：桌面与 BPM 的提示
/// 组件不同，收进这里会重新制造"双实现"。
class CloudInstallFlow {
  CloudInstallFlow._();

  /// 弹确认框（含体积/剩余空间预览）→ 预取体积 → 解析直链 → 提交。
  static Future<CloudInstallResult> submit({
    required BuildContext context,
    required String gameId,
    required String title,
    required String downloadPath,
    String? description,
    String? coverUrl,
    String? bannerUrl,
    List<String>? tags,
    String? developer,
    List<String>? screenshotUrls,
    String? subtitle,
  }) async {
    if (downloadPath.isEmpty) return CloudInstallResult.linkFailed;

    // ⓪ OpenList 半移植化（2026-10-02）：安装包不再内置 OpenList。
    //    已登录但未对接时先弹对接窗口（两入口共用），取消则中止整个安装。
    //    未登录/本地用户到不了这里（详情页 gate 已拦）。
    if (!await OpenListProvision.isPaired()) {
      final paired = await OpenListPairDialog.show(context);
      if (paired != OpenListPairResult.paired) {
        return CloudInstallResult.cancelled;
      }
    }

    // ① 确认弹窗：安装位置选择 + 完整路径预览 + 体积/剩余空间提示
    final confirm = await InstallConfirmationDialog.show(
      context: context,
      gameId: gameId,
      downloadPath: downloadPath,
      gameTitle: title,
      gameCoverUrl: coverUrl,
      gameDescription: description,
      gameTags: tags,
    );
    if (confirm != InstallConfirmationResult.confirmed) {
      return CloudInstallResult.cancelled;
    }

    // ② 下载包体积预取（best-effort；弹窗内大概率已命中缓存）。
    // 预取失败不阻断安装：空间门槛退化为仅校验磁盘可访问性。
    int? expectedSizeBytes;
    try {
      expectedSizeBytes = (await FileSizePrefetchService.instance
              .prefetchSize(gameId, downloadPath))
          ?.sizeBytes;
    } catch (_) {}

    // ③ 安装位置：上次使用 → 默认位置 → null（应用默认目录）
    String? customLocation =
        await InstallPathPreference.instance.getLastUsedLocation();
    if (customLocation == null || customLocation.isEmpty) {
      customLocation =
          await InstallPathPreference.instance.getDefaultGameLocation();
    }

    // ④ 直链解析。downloadPath 是网盘**路径**而非 URL，必须经 OpenList 换取
    // 会过期的签名直链（P0-1 根因）；urlResolver 供下载中途过期时重解析。
    final proxyUrl = await OpenListService.getGameDownloadUrl(downloadPath);
    if (proxyUrl == null || proxyUrl.isEmpty) {
      return CloudInstallResult.linkFailed;
    }

    final task = InstallTask(
      gameId: gameId,
      title: title,
      description: description,
      coverUrl: coverUrl,
      bannerUrl: bannerUrl,
      tags: tags,
      downloadUrl: proxyUrl,
      developer: developer,
      customGameLocation: customLocation,
      screenshotUrls: screenshotUrls,
      subtitle: subtitle,
      // ★ P0-4：云盘签名直链会过期，重试时用它重新解析直链
      urlResolver: () => OpenListService.getGameDownloadUrl(downloadPath),
      expectedSizeBytes: expectedSizeBytes,
    );

    // ⑤ 重复性同步判据（与 submitTask 内部一致；检查→提交之间无 await，
    //    单 isolate 无竞态）——把「已在队列」作为同步结果返回给调用方。
    if (GlobalInstallCenter.instance.isQueuedOrRunning(gameId)) {
      return CloudInstallResult.duplicate;
    }

    // fire-and-forget：submitTask 的 Future 在任务执行完毕才 resolve，
    // 旧实现 await 它会把 UI 阻塞到下载+解压全部结束（白屏卡死事故）。
    // 进度展示交给 FloatingTaskButton / 安装中心。
    unawaited(GlobalInstallCenter.instance.submitTask(task));
    return CloudInstallResult.submitted;
  }
}
