/// NSFW 局部打码的统一渲染入口。方案见
/// `docs/DEV/features/nsfw_filter_implementation_plan.md`
/// §4.4（键规则）/ §4.5（与手动模糊的优先级）/ §5.1–5.5（渲染层）。
///
/// ## 为什么是「装饰器」而不是「Image 替代品」
///
/// 32 个接入点（§7）的图片渲染写法各不相同：`cacheWidth` / `memCacheWidth` /
/// `frameBuilder` 淡入 / 各自的 placeholder 与 errorWidget / 圆角与 Stack 层叠。
/// 若把 [NsfwImage] 做成「参数齐全的 Image 替代品」，等于要在 32 个点各自复刻一遍
/// 这些细节 —— 那是 v1 覆盖率只做到 9/32 的直接原因之一，也违背最小变更原则。
///
/// 因此本组件是**装饰器**：接入时把原有渲染代码整块塞进 [child] 即可。
///
/// | 状态 | 渲染 |
/// | --- | --- |
/// | 总开关关闭 / [manuallyBlurred] | 原样返回 [child]，**零额外开销**（R3） |
/// | 工作模式 | 占位图（不构建 [child]、不解码、不入队）；悬浮/已揭示时右下角浮出角标按钮 |
/// | 未判定 | 模糊预览（sigma 14，细节不可辨）+ 右下角沙漏角标 + 自动入队检测，失败自动退避重试；**不可揭示** |
/// | 纯净模式 + 内容图（[NsfwContentKind.image]）判定敏感 | 模糊（sigma 14）+ **左上角** NSFW 徽标 + 右下角角标按钮 |
/// | 纯净模式 + 封面类（[NsfwContentKind.cover]）判定敏感 | 模糊（sigma 14）+ 右下角角标按钮 |
/// | 该图已判定且干净（空 box 列表） | 原样返回 [child] |
///
/// 「总开关关闭」「判定干净」两态覆盖了绝大多数图片，它们的渲染与接入前
/// **逐像素一致**，因为走的就是原来那棵 widget 子树。
///
/// ## 右下角角标＝唯一的揭示入口（v2.5）
///
/// 点一次显示原图（角标换亮眼）、再点恢复遮蔽。可点性由「接入点
/// [enableReveal] + 用户总闸 [NsfwSettings.allowReveal]」共同决定；
/// 未开启时角标退回纯指示，不抢点击。
///
/// 之所以从「整图点击」改成「角标按钮」：整图 `GestureDetector` 会吃掉
/// 网格卡片自身的单击/双击/长按，逼得库页/探索页卡片长期不敢开
/// `enableReveal`（揭示功能因此覆盖不全）。角标是独立按钮，两者不再互抢。
///
/// ⚠️「未判定」的模糊预览**永不**可揭示 —— 那是 fail-closed 的检测窗口，
/// 放行等于未判定就把 R18 原图直出。
///
/// ## 关键安全性质：不存在「未打码闪出」窗口
///
/// 一旦判定有 bbox，[child] 只在 `ClipRect` + `ImageFiltered` 的模糊层内绘制。
/// 几何失效、解码失败、约束无界这三种兜底路径同样落在整图模糊上 ——
/// 本组件任何一条分支都不会输出未处理的原图（除用户经右下角角标主动揭示）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/portable_image_cache_manager.dart';
import '../../services/nsfw/nsfw_box.dart';
import '../../services/nsfw/nsfw_detection_service.dart';
import '../../services/nsfw/nsfw_detection_store.dart';
import '../../services/nsfw/nsfw_settings.dart';

/// 内容类型：决定纯净模式（[NsfwDisplayMode.clean]）下的渲染策略。
enum NsfwContentKind {
  /// 封面类（列表缩略图、详情封面、网格卡片等）：
  /// 两种模式下均为局部打码——隐藏封面会破坏列表/详情版式。
  cover,

  /// 内容图（截图、CG、大图查看器等）：纯净模式下未判定或判定敏感
  /// 均显示占位符，强制脱离 R18+ 内容。
  image,
}

class NsfwImage extends StatefulWidget {
  /// 本地文件入口。
  ///
  /// [child] 传该处**原有**的图片渲染代码；[fit] / [alignment] 必须与 [child]
  /// 内部保持一致，否则 bbox 换算会偏移。
  /// [decodeWidth] / [decodeHeight] 应与 [child] 里 `Image.file` 的
  /// `cacheWidth` / `cacheHeight` 传相同值 —— 这样两边的 ImageProvider 缓存键
  /// 相同，同一张图只解码一次。
  const NsfwImage.file(
    String path, {
    super.key,
    required this.child,
    this.contentKind = NsfwContentKind.image,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.width,
    this.height,
    this.decodeWidth,
    this.decodeHeight,
    this.enableReveal = false,
    this.manuallyBlurred = false,
    this.showBadge = true,
    this.blockScale = 1.0,
    this.fallbackBlurSigma = 10.0,
  })  : filePath = path,
        imageUrl = null,
        localPath = null,
        diskCacheWidth = null,
        diskCacheHeight = null,
        detectOnDemand = false;

  /// 网络图入口。
  ///
  /// [localPath] 是该 URL 对应的本地副本路径（若调用方知道的话）。
  /// 传了它就能在 URL 键未命中时用路径键兜底命中，见 §4.4。
  ///
  /// [detectOnDemand] 见该字段文档：用于「只走网络、永远不会落进游戏目录」的
  /// 刮削候选图（§7.1 风险 🟠4）。
  ///
  /// [diskCacheWidth] / [diskCacheHeight] 应与 [child] 里 `CachedNetworkImage`
  /// 的 `maxWidthDiskCache` / `maxHeightDiskCache` 一致，
  /// [decodeWidth] / [decodeHeight] 与其 `memCacheWidth` / `memCacheHeight` 一致，
  /// 理由同 [NsfwImage.file]（缓存键对齐，避免二次解码）。
  const NsfwImage.network(
    String url, {
    super.key,
    required this.child,
    this.contentKind = NsfwContentKind.image,
    this.localPath,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.width,
    this.height,
    this.decodeWidth,
    this.decodeHeight,
    this.diskCacheWidth,
    this.diskCacheHeight,
    this.enableReveal = false,
    this.manuallyBlurred = false,
    this.showBadge = true,
    this.blockScale = 1.0,
    this.fallbackBlurSigma = 10.0,
    this.detectOnDemand = false,
  })  : imageUrl = url,
        filePath = null;

  /// 该处原有的图片渲染代码。健康图/未判定图直接返回它。
  final Widget child;

  /// 内容类型（封面/内容图），决定纯净模式下的渲染策略，见 [NsfwContentKind]。
  final NsfwContentKind contentKind;

  /// 本地文件路径（[NsfwImage.file]）。
  final String? filePath;

  /// 网络图 URL（[NsfwImage.network]）。
  final String? imageUrl;

  /// 网络图的本地副本路径，用于键兜底（§4.4）。
  final String? localPath;

  final BoxFit fit;
  final Alignment alignment;

  /// 显式槽位尺寸。**仅当接入点的图片尺寸由原图内在尺寸决定（约束无界）时才需要传**。
  ///
  /// 约束有界时留空即可，组件会用 `LayoutBuilder` 拿到的约束。
  /// 两者都拿不到时退化为整图模糊（安全兜底，不会抛异常）。
  final double? width;
  final double? height;

  final int? decodeWidth;
  final int? decodeHeight;
  final int? diskCacheWidth;
  final int? diskCacheHeight;

  /// 是否允许右下角角标充当**揭示按钮**（显示原图 / 恢复遮蔽）。
  ///
  /// v2.5 起语义变更：揭示手势由「整图点击」改为「点右下角角标」，
  /// 因此它与调用方自身的单击/双击/长按**不再互相抢占**，网格卡片也可以开启。
  ///
  /// 还需用户设置 [NsfwSettings.allowReveal] 同时为真才生效；
  /// 揭示状态只存在于组件实例，不持久化，换图 / 关总闸 / 换模式即复位。
  final bool enableReveal;

  /// 调用方已经在做整图模糊（`game.isBlurred`）。
  ///
  /// 为真时本组件直接透传 [child]，**不叠加**局部马赛克 —— 手动标记优先，见 §4.5。
  final bool manuallyBlurred;

  /// 打码态右下角是否显示 `visibility_off` 提示（§5.5）。
  /// 槽位小于 48×48 时自动不显示（缩略图上会盖住整张图）。
  final bool showBadge;

  /// 马赛克块大小倍率，`> 1` 更粗糙。对应风险 R-2。
  final double blockScale;

  /// 兜底整图模糊的 sigma（v2.1.14 由 12 下调到 10）。
  /// 高斯模糊的光栅化成本与 sigma 正相关，列表里同屏多张卡片同时模糊时
  /// 尤其明显；10 仍远超「R18 细节可辨认」的阈值（该判定由 sigma 14 的
  /// [_fullBlurSigma] 承担，本值只用于调用方未走打码路径时的兜底）。
  final double fallbackBlurSigma;

  /// 未判定的网络图是否在其缓存文件落盘后补一次检测。
  ///
  /// 针对 §7.1 风险 🟠4：刮削/搜索候选封面只经过 `CachedNetworkImage` 的磁盘缓存，
  /// 既不会被下载服务写入、也不在全量扫描范围（§6.2 只扫 coverPath + 截图），
  /// 因此**永远拿不到检测记录**，靠触发点补不上。
  ///
  /// 默认 `false`：这是本组件唯一会主动发起推理的路径，需要按接入点显式开启，
  /// 避免网格滚动时对几十张缩略图批量排队。
  final bool detectOnDemand;

  bool get isNetwork => imageUrl != null;

  /// 查询检测结果时依次尝试的 key。**必须**走 [NsfwDetectionStore] 的
  /// `keyForFile` / `keyForUrl`，不允许自己拼 —— v1 的 P0-3 就死在这里。
  List<String> get lookupKeys {
    if (imageUrl != null) {
      final String url = imageUrl!;
      return <String>[
        if (url.trim().isNotEmpty) NsfwDetectionStore.keyForUrl(url),
        if (localPath != null && localPath!.isNotEmpty)
          NsfwDetectionStore.keyForFile(localPath!),
      ];
    }
    final String path = filePath ?? '';
    if (path.isEmpty) return const <String>[];
    return <String>[NsfwDetectionStore.keyForFile(path)];
  }

  /// 仅供单测注入可控 ImageProvider（真实解码路径依赖磁盘文件/网络，不便在单测构造）。
  @visibleForTesting
  static ImageProvider Function(NsfwImage widget)? debugProviderFactory;

  /// 仅供单测拦截「按需检测入队」：真实入队会走 [NsfwDetectionService] 的
  /// isolate 推理链路，测试环境不可控。返回的 Future 模拟检测结果
  /// （null = 失败，会驱动组件的重试链）。置为 null 恢复真实入队。
  @visibleForTesting
  static Future<NsfwDetection?> Function(String path, {bool highPriority})?
      debugEnqueueOverride;

  @override
  State<NsfwImage> createState() => _NsfwImageState();
}

class _NsfwImageState extends State<NsfwImage> {
  /// 小于这个边长的槽位不显示 §5.5 提示图标（40×55 的缩略图会被图标盖住）。
  static const double _minBadgeSlot = 48.0;

  NsfwSettings get _settings => NsfwSettings.instance;
  NsfwDetectionStore get _store => NsfwDetectionStore.instance;

  NsfwDetection? _detection;
  List<NsfwBox> _boxes = const <NsfwBox>[];

  ImageStream? _stream;
  ImageStreamListener? _streamListener;
  ImageInfo? _imageInfo;
  bool _decodeFailed = false;

  bool _revealed = false;

  /// 鼠标是否悬停在本组件上。仅工作模式消费（角标按钮按需浮出，见
  /// [_buildWorkPlaceholder]）；纯净模式的角标是遮蔽指示，恒常显示。
  bool _hovered = false;

  Timer? _onDemandRetry;

  /// 本地文件按需检测已入队标志：同一路径只入队一次，
  /// 避免 store 通知风暴下重复排队（服务端也有去重，这里省 IPC 开销）。
  bool _localEnqueued = false;

  /// 本地文件按需检测**失败后的重试次数**（含已发起的）。
  ///
  /// v2.1.2 修复：入队不再是一次性 fire-and-forget —— 服务端存在多种
  /// 「无声失败」（首次初始化未就绪、首推超时、worker 异常），
  /// 任一发生时该图会永远卡在模糊预览（用户实测：第一张截图残留模糊，
  /// 换页返回才解除）。现在检测 Future 返回 null 即安排退避重试。
  int _localRetries = 0;

  /// 按需检测放弃标志（v2.1.4）：重试 3 次仍无结果（典型场景：模型缺失/
  /// worker 起不来，服务整体不可用）→ 放行原图直显。打码功能整体不可用时
  /// 全库图片永久模糊比裸露更糟——这是「模糊预览」策略的 fail-open 兜底，
  /// 仅在服务不可用时触发；服务正常时判定在重试窗口内必然回写。
  bool _detectionGaveUp = false;

  /// 模糊看门狗（v2.2）：覆盖「任务排队中」这个此前完全没有兜底的空档。
  ///
  /// 原兜底只覆盖**失败**：`detectFile` 的 Future 返回 null 才走重试链。
  /// 但库页几百张封面的场景下任务只是**排着队**（3 worker 串行消化），
  /// Future 长期 pending —— 不失败、也不返回，于是 UI 永久停在模糊预览
  /// （用户实测：正常图长时间不清晰，换页/刷新才恢复）。看门狗分两段：
  /// ① [_blurPromoteDelay] 后仍无结果 → 把本图提到高优先级队列（在屏的图
  ///    先判，解决"排在几百张封面后面"）；
  /// ② 累计 [_blurGiveUpDelay] 仍无结果 → 置 [_detectionGaveUp] 放行原图
  ///    （服务不可用的等价处理）。后续若检测结果回写，store 通知仍会把
  ///    敏感图切回整图模糊（见 [_onExternalChange]）。
  ///
  /// v2.3：`_blurPromoteDelay` 5s → **800ms**。实证依据：24 张非敏感真实
  /// 照片在该模型下最高分仅 0.07~0.17（**零误报**），所以用户看到的
  /// 「风景/动物/健全图被处理」几乎全是**未判定模糊态**，不是判定错误——
  /// 模糊停留时间越长，越像"被处理了"。在屏图片 800ms 后即插队优先判定，
  /// 使模糊态压缩到亚秒级（观感 = 图片加载中），同时保留 R18 保护。
  /// 800ms 而非 0：留出滚动去抖，快速滑过的卡片不必抢占推理槽位。
  static const Duration _blurPromoteDelay = Duration(milliseconds: 800);
  static const Duration _blurGiveUpDelay = Duration(seconds: 30);
  Timer? _blurWatchdog;
  bool _watchdogArmed = false;

  /// 渲染相关设置快照（v2.1.4）：store/设置每次 notify 都会广播到**所有**
  /// 存活的 NsfwImage（库页滚动后几十个实例很常见）。用快照做差异化——
  /// 检测数据与渲染设置都没变的组件直接跳过重建。批量判定期间（每 200ms
  /// 一波通知）这把「全组件 × setState + 重订图像流」风暴降为只重建真正
  /// 变化的那几张图，是滚动流畅度的关键优化。
  bool _renderEnabled = true;
  NsfwDisplayMode _renderMode = NsfwDisplayMode.clean;
  bool _renderAllowReveal = true;

  /// 仅供单测断言重试状态（Dart 私有成员不能跨库 dynamic 访问）。
  @visibleForTesting
  int get localRetriesForTest => _localRetries;

  /// 单测计数器：收到多少次外部广播 / 其中多少次通过差异化检查触发重建。
  /// 用于验证通知风暴优化（无关组件不重建）。
  @visibleForTesting
  int externalNotificationsForTest = 0;
  @visibleForTesting
  int externalRebuildsForTest = 0;

  /// 需要自有解码（走局部马赛克路径）。
  ///
  /// 注意**不包含** `_revealed` 判断：揭示只是暂时显示原图，
  /// 保留已解码的 image 可让再次隐藏时无需重新解码。
  /// v2.2：局部马赛克退役后，本组件不再需要自有解码——敏感图一律整图模糊
  /// （[ImageFiltered] 直接作用于 [child]，不需要自己的位图副本），
  /// 因此恒为 false：省掉每张敏感图的一次额外解码 + 一份位图内存。
  /// 解码管线（[_updateImageStream] / [_onImageFrame] 等）保留 intact，
  /// 未来若恢复局部打码只需把这里的条件改回去。
  bool get _needsOwnImage => false;

  /// 纯净模式下的内容图（截图类）：未判定/敏感都不渲染原图，
  /// 因此不需要自有解码；封面类照常走打码路径。
  bool get _isHiddenMode =>
      _settings.mode == NsfwDisplayMode.clean &&
      widget.contentKind == NsfwContentKind.image;

  bool get _revealEnabled => widget.enableReveal && _settings.allowReveal;

  /// 当前是否真的处于「已揭示」显示态。
  ///
  /// 与 [_revealed] 的区别：用户总闸 [NsfwSettings.allowReveal] 或接入点
  /// [NsfwImage.enableReveal] 任一为假时，即使 [_revealed] 残留 true 也不再
  /// 输出原图 —— 保证「关掉开关立刻回到遮蔽态」，不留已揭示的窗口。
  bool get _showingRevealed => _revealed && _revealEnabled;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onExternalChange);
    _settings.addListener(_onExternalChange);
    _renderEnabled = _settings.enabled;
    _renderMode = _settings.mode;
    _renderAllowReveal = _settings.allowReveal;
    _readStore(notify: false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _updateImageStream();
    _maybeRequestOnDemand();
  }

  @override
  void didUpdateWidget(NsfwImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool sourceChanged = oldWidget.filePath != widget.filePath ||
        oldWidget.imageUrl != widget.imageUrl ||
        oldWidget.localPath != widget.localPath;
    if (sourceChanged) {
      _revealed = false;
      _localEnqueued = false;
      _localRetries = 0;
      _detectionGaveUp = false;
      _onDemandRetry?.cancel();
      _onDemandRetry = null;
      // 换图 = 换等待对象：旧看门狗必须收掉，否则会用新图的定时器
      // 去提升旧图优先级 / 把新图误判为超时放行。
      _cancelBlurWatchdog();
    }
    if (sourceChanged ||
        oldWidget.manuallyBlurred != widget.manuallyBlurred) {
      _readStore(notify: false);
    }
    if (sourceChanged ||
        oldWidget.decodeWidth != widget.decodeWidth ||
        oldWidget.decodeHeight != widget.decodeHeight ||
        oldWidget.diskCacheWidth != widget.diskCacheWidth ||
        oldWidget.diskCacheHeight != widget.diskCacheHeight) {
      _updateImageStream();
    }
    _maybeRequestOnDemand();
  }

  @override
  void dispose() {
    _store.removeListener(_onExternalChange);
    _settings.removeListener(_onExternalChange);
    _onDemandRetry?.cancel();
    _blurWatchdog?.cancel();
    _blurWatchdog = null;
    _detachStream();
    _imageInfo?.dispose();
    _imageInfo = null;
    super.dispose();
  }

  // ===================== 检测结果同步 =====================

  void _onExternalChange() {
    if (!mounted) return;
    externalNotificationsForTest++;
    // 差异化检查（v2.1.4）：批量判定/设置变更会广播到所有存活的 NsfwImage，
    // 只有本图数据或渲染设置真正变化的实例才 setState——无关实例直接跳过
    // （旧行为是无条件 setState + 重订图像流，一张图判定回写 = 全部可见
    // 图片重建一轮，滚动列表里即性能风暴）。
    final NsfwDetection? next = _store.detectionForAny(widget.lookupKeys);
    final List<NsfwBox> nextBoxes = _expand(next);
    final bool detectionChanged =
        next != _detection || !listEquals(nextBoxes, _boxes);
    // boxExpandRatio 的变化会体现在 nextBoxes 外扩结果里，无需单列
    final bool settingsChanged = _settings.enabled != _renderEnabled ||
        _settings.mode != _renderMode ||
        _settings.allowReveal != _renderAllowReveal;
    if (!detectionChanged && !settingsChanged) return;
    externalRebuildsForTest++;

    final NsfwDisplayMode prevMode = _renderMode;
    _renderEnabled = _settings.enabled;
    _renderMode = _settings.mode;
    _renderAllowReveal = _settings.allowReveal;
    // 揭示态复位：总闸关闭、或显示模式切换时立刻回到遮蔽态。
    // 不做复位的话会留下「开关已关、原图仍亮着」的窗口。
    if (!_revealEnabled || _settings.mode != prevMode) _revealed = false;
    _detection = next;
    _boxes = nextBoxes;
    setState(() {});
    if (detectionChanged) _updateImageStream();
    _maybeRequestOnDemand();
  }

  /// 从 store 取当前生效的 bbox 列表（已按设置外扩）。
  void _readStore({required bool notify}) {
    final NsfwDetection? detection =
        _store.detectionForAny(widget.lookupKeys);
    final List<NsfwBox> boxes = _expand(detection);

    if (detection != null) _cancelBlurWatchdog();

    final bool changed =
        detection != _detection || !listEquals(boxes, _boxes);
    if (!changed) return;

    if (notify) {
      setState(() {
        _detection = detection;
        _boxes = boxes;
      });
    } else {
      _detection = detection;
      _boxes = boxes;
    }
  }

  /// 按 `boxExpandRatio` 外扩（风险 R-2）。外扩以**检测时的原图尺寸**为界。
  List<NsfwBox> _expand(NsfwDetection? detection) {
    if (detection == null || detection.boxes.isEmpty) {
      return const <NsfwBox>[];
    }
    final double ratio = _settings.boxExpandRatio;
    final List<NsfwBox> out = <NsfwBox>[];
    for (final NsfwBox box in detection.boxes) {
      final NsfwBox b = ratio > 0
          ? box.expanded(ratio, imgW: detection.imgW, imgH: detection.imgH)
          : box;
      if (!b.isEmpty) out.add(b);
    }
    return out;
  }

  // ===================== 自有解码 =====================

  ImageProvider _buildProvider() {
    final ImageProvider Function(NsfwImage)? factory =
        NsfwImage.debugProviderFactory;
    if (factory != null) return factory(widget);

    if (widget.isNetwork) {
      return ResizeImage.resizeIfNeeded(
        widget.decodeWidth,
        widget.decodeHeight,
        CachedNetworkImageProvider(
          widget.imageUrl!,
          cacheManager: PortableImageCacheManager(),
          maxWidth: widget.diskCacheWidth,
          maxHeight: widget.diskCacheHeight,
        ),
      );
    }
    return ResizeImage.resizeIfNeeded(
      widget.decodeWidth,
      widget.decodeHeight,
      FileImage(File(widget.filePath!)),
    );
  }

  void _updateImageStream() {
    if (!_needsOwnImage) {
      _detachStream();
      if (_imageInfo != null || _decodeFailed) {
        final ImageInfo? old = _imageInfo;
        _imageInfo = null;
        _decodeFailed = false;
        old?.dispose();
      }
      return;
    }

    final ImageStream stream =
        _buildProvider().resolve(createLocalImageConfiguration(context));
    if (_stream != null && stream.key == _stream!.key) return;

    _detachStream();
    _stream = stream;
    _streamListener =
        ImageStreamListener(_onImageFrame, onError: _onImageError);
    stream.addListener(_streamListener!);
  }

  void _detachStream() {
    if (_stream != null && _streamListener != null) {
      _stream!.removeListener(_streamListener!);
    }
    _stream = null;
    _streamListener = null;
  }

  void _onImageFrame(ImageInfo info, bool synchronousCall) {
    if (!mounted) {
      info.dispose();
      return;
    }
    final ImageInfo? old = _imageInfo;
    setState(() {
      _imageInfo = info;
      _decodeFailed = false;
    });
    old?.dispose();
  }

  void _onImageError(Object error, StackTrace? stackTrace) {
    debugPrint('[NSFW-IMAGE] 解码失败，退回整图模糊: $error');
    if (!mounted) return;
    setState(() => _decodeFailed = true);
  }

  // ===================== 按需检测（§7.1 风险 4） =====================

  Future<void> _maybeRequestOnDemand({bool force = false}) async {
    if (!_settings.enabled) return;
    // 工作模式：不做任何判定，直接放弃按需检测（不入队、不挂看门狗、
    // 不重试）。这是「最轻量」的关键——不产生任何推理请求。
    if (_settings.mode == NsfwDisplayMode.work) return;
    if (_detection != null) return;
    // 进入「等待判定」状态：挂上看门狗，覆盖任务长期排队这个空档
    // （见 [_startBlurWatchdog]）。放在所有提前 return 之前，
    // 保证无论是新入队、还是复用别处已在飞的任务，都有兜底。
    _startBlurWatchdog();

    // 触发条件：
    // ① 网络图 —— 仅显式开启 [detectOnDemand]（§7.1 风险 4，防海量请求）；
    // ② 本地文件图 —— 一律自动入队（v2.1.3）。
    //    全量扫描只在「首次手动开启开关」时跑一次，且签名失效清空缓存后
    //    不会自动重跑；v2.1 默认开启后「首次开启」事件不再发生，封面类
    //    （cover）没有任何入队触发点 → 永远未判定 → 原图直显，NSFW 在
    //    库页等封面场景形同虚设（用户实测）。组件级按需 = 只处理实际
    //    显示的图，天然增量，且覆盖手动换封面等任意路径。
    if (!widget.detectOnDemand && widget.isNetwork) return;

    if (widget.isNetwork) {
      final String url = widget.imageUrl ?? '';
      if (!url.startsWith('http')) return;

      // v2.1.16：等待落盘的链路上移到服务级（NsfwDetectionService
      // .ensureUrlDetection）。旧组件内「查缓存 2 次/1.5s 窗口」在封面
      // 下载超过窗口时直接放弃且从未入队——判定缓存永远没有该图记录，
      // 滚动回收重建后每次重现「模糊预览 → 放弃」循环（已清晰的封面
      // 滚回来又模糊的根因）。fire-and-forget：组件销毁不影响等待与
      // 入队；判定以 URL 别名键写 store，重建后 _readStore 秒命中。
      // 服务不可用时的兜底仍由模糊看门狗（[_blurGiveUpDelay] 放行）承担。
      NsfwDetectionService.instance.ensureUrlDetection(url);
      return;
    }

    // 本地文件：文件就在磁盘上，直接入队（v2.1.3 起不限内容图，封面同样
    // 入队——低优先级）。detectFile 内部有缓存命中/在飞/失败三重去重；
    // 组件侧再以 [_localEnqueued] 保证同一路径只入队一次，省去重复排队开销。
    //
    // v2.1.2：不再 fire-and-forget。服务端存在多种「无声失败」——
    // 首次初始化未就绪（模型释放 + isolate spawn 秒级窗口）、首推超时、
    // worker 异常返回 null —— 任一发生时若不重试，该图会**永远**卡在
    // 模糊预览（用户实测：第一张截图残留模糊，换页返回才解除）。
    // 因此监听检测 Future：拿到结果 → store 通知驱动刷新；null → 退避重试。
    if (_localEnqueued) return;
    final String path = widget.filePath ?? '';
    if (path.isEmpty) return;
    _localEnqueued = true;

    // 内容图（截图类）高优先级——隐藏语义紧迫；封面类低优先级排队：
    // 库页网格滚动会批量入队几十张封面，不能抢占截图判定。
    final bool highPriority = widget.contentKind != NsfwContentKind.cover;

    final Future<NsfwDetection?> Function(String, {bool highPriority})?
        enqueue = NsfwImage.debugEnqueueOverride;
    if (enqueue != null) {
      // 测试注入口：受控 Future（不发真实请求）。失败同样走重试链，
      // 保证 override 路径与真实入队行为一致。
      enqueue(path, highPriority: highPriority)
          .then((NsfwDetection? result) {
        if (!mounted || result != null) return;
        _scheduleLocalRetry();
      });
      return;
    }

    NsfwDetectionService.instance
        .detectFile(path, highPriority: highPriority, force: force)
        .then((NsfwDetection? result) {
      if (!mounted || result != null) return;
      _scheduleLocalRetry();
    });
  }

  /// 本地按需检测失败后的退避重试（v2.1.2）。
  ///
  /// 间隔 3s/6s/9s，最多 3 次；重试前先查 store（可能全量扫描等其他
  /// 触发点已写入结果），仍无结果才以 [force] 重新入队 —— force 用于
  /// 绕过服务端的失败去重表（`_failed`），否则重试会被静默吞掉。
  void _scheduleLocalRetry() {
    if (_localRetries >= 3) {
      // 重试窗口耗尽仍无结果 → 服务大概率不可用，放行原图（兜底见
      // [_detectionGaveUp] 文档）。store 若稍后有结果（其他触发点写入），
      // _onExternalChange 仍会驱动 UI 回到打码/角标态。
      if (!_detectionGaveUp) {
        _detectionGaveUp = true;
        _cancelBlurWatchdog();
        setState(() {});
      }
      return;
    }
    _localRetries++;
    _onDemandRetry?.cancel();
    _onDemandRetry = Timer(Duration(seconds: 3 * _localRetries), () {
      if (!mounted) return;
      final String key = NsfwDetectionStore.keyForFile(widget.filePath ?? '');
      if (_store.detectionFor(key) != null) return; // 已有结果，无需重试
      _localEnqueued = false;
      _maybeRequestOnDemand(force: true); // force 绕过服务端失败去重表
    });
  }

  // ===================== 模糊看门狗（v2.2） =====================

  /// 本图是否存在自动检测路径：本地文件图总是有；网络图仅显式开启
  /// [detectOnDemand] 时有（否则没有入队来源，模糊会永久化）。
  bool get _hasAutoDetectPath => !widget.isNetwork || widget.detectOnDemand;

  /// 启动看门狗（幂等）：详情页/网格里的图在等待判定期间都挂着一个，
  /// 判定到达后由 [_cancelBlurWatchdog] 收掉。
  void _startBlurWatchdog() {
    if (_watchdogArmed) return;
    if (_detection != null || _detectionGaveUp) return;
    if (!_hasAutoDetectPath) return;
    _watchdogArmed = true;
    _blurWatchdog?.cancel();
    _blurWatchdog = Timer(_blurPromoteDelay, () {
      if (!mounted || _detection != null || _detectionGaveUp) return;
      // 阶段①：本图大概率正在屏幕上 → 插到高优先级队首先判
      // （网络图入队时已是 highPriority，无需提升）
      final String path = widget.filePath ?? '';
      if (!widget.isNetwork && path.isNotEmpty) {
        NsfwDetectionService.instance.promoteToHighPriority(path);
      }
      _blurWatchdog = Timer(_blurGiveUpDelay - _blurPromoteDelay, () {
        if (!mounted || _detection != null || _detectionGaveUp) return;
        // 阶段②：等待窗口耗尽 → 与「服务不可用」同等处理，放行原图。
        // 若之后结果回写，store 通知仍会把敏感图切回整图模糊。
        _detectionGaveUp = true;
        setState(() {});
      });
    });
  }

  void _cancelBlurWatchdog() {
    _watchdogArmed = false;
    _blurWatchdog?.cancel();
    _blurWatchdog = null;
  }

  // ===================== 渲染 =====================

  void _toggleReveal() {
    if (!_revealEnabled) return;
    setState(() => _revealed = !_revealed);
  }

  @override
  Widget build(BuildContext context) {
    // 1. 总开关关闭 / 手动模糊优先（§4.5）→ 原样透传，零额外开销
    if (!_settings.enabled || widget.manuallyBlurred) return widget.child;

    // 工作模式（v2.1.15）：**不做任何内容判定**，全部图片统一替换为占位图。
    // 必须排在检测 / 模糊预览 / 看门狗之前 —— 本分支不解码游戏图、不入队
    // 推理、不加 ImageFiltered，开销与未开启 NSFW 时几乎一致。
    if (_settings.mode == NsfwDisplayMode.work) return _buildWorkPlaceholder();

    // 2. 未判定 → 模糊预览 + 自动入队检测（v2.1.4 统一 fail-closed）：
    //    不再区分模式与内容类型——封面/截图在判定完成前都先以模糊态展示，
    //    消除「排队期间 R18 原图裸露」的 fail-open 窗口（v2.1.3 后封面
    //    低优先级排队 5-10s，裸露窗口被显著放大，用户感知即"该打码的
    //    迟迟不打码"）。模糊观感即"图片加载中"，判定健康 → 清晰、
    //    敏感 → 打码/角标，全程无闪现。
    //    前提：本图存在自动检测路径——本地文件图总是有；网络图仅显式
    //    开启 [detectOnDemand] 时有（否则没有入队来源，模糊会永久化，
    //    维持旧行为透传）。服务不可用时由 [_detectionGaveUp] 兜底放行。
    if (_detection == null && !_detectionGaveUp && _hasAutoDetectPath) {
      return _buildBlurredPreview(sensitive: false);
    }

    // 3. 纯净模式的内容图（截图类）判定敏感 → 保持模糊 + 左上角 NSFW 徽标
    //    + 右下角可点角标按钮（v2.5 起可揭示；已判定健康/干净则继续往下走
    //    打码或透传分支）。
    if (_isHiddenMode && _boxes.isNotEmpty) {
      return _buildBlurredPreview(sensitive: true);
    }

    // 4. 已判定为干净（空列表）或检测放弃兜底 → 原样透传
    if (_boxes.isEmpty) return widget.child;

    // 5. 检出 bbox（判定为敏感）→ 接管渲染：v2.2 起**一律整图模糊**，
    //    不再做局部马赛克（详见 [_buildCensored] 的策略说明）。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double? slotW = widget.width ??
            (constraints.hasBoundedWidth ? constraints.maxWidth : null);
        final double? slotH = widget.height ??
            (constraints.hasBoundedHeight ? constraints.maxHeight : null);

        final Widget core = _showingRevealed
            ? widget.child
            : _buildCensored(slotW: slotW, slotH: slotH);

        return _decorate(core, slotW: slotW, slotH: slotH);
      },
    );
  }

  /// 工作模式占位图（v2.1.15）。
  ///
  /// 资源固定为 `assets/images/nsfw_work_placeholder.png`（由
  /// `研究图片/工作模式占位图.png` 复制而来，随包发布；`assets/images/`
  /// 已整目录注册，无需改 pubspec）。
  ///
  /// [_workPlaceholderCacheWidth] 限制解码尺寸：原图 1597×898，若不限，
  /// 40×56 的缩略图槽位也会按全尺寸解码再缩放，白白吃掉内存与 CPU。
  /// 限定后由 Flutter 图片缓存全进程复用一次解码结果。
  static const String _workPlaceholder =
      'assets/images/nsfw_work_placeholder.png';
  static const int _workPlaceholderCacheWidth = 480;

  /// 工作模式渲染体（v2.5 起支持悬浮揭示）。
  ///
  /// 默认只画占位图，**不触碰 [child]** —— 这是工作模式「最轻量」的关键：
  /// 不解码游戏图、不发起任何检测。
  ///
  /// v2.5 新增：鼠标悬停本组件（[_hovered]）或已揭示（[_showingRevealed]）时，
  /// 右下角浮出角标按钮，点一次显示真实图片、再点恢复占位图。
  /// 揭示只影响本实例这一帧的渲染，仍不解码检测、不写任何缓存；鼠标移开后
  /// 未揭示则角标淡出。
  ///
  /// 角标取 [_minBadgeSlot] 阈值判断 —— 40×56 的缩略图放不下按钮，
  /// 硬塞会盖住整张占位图（与纯净模式同口径）。
  Widget _buildWorkPlaceholder() {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 优先用调用方显式槽位，其次用布局约束；都拿不到时给稳定默认值
        // —— 否则 Image.asset 会按 1597×898 的内在尺寸撑爆布局。
        final double? slotW = widget.width ??
            (constraints.hasBoundedWidth ? constraints.maxWidth : null);
        final double? slotH = widget.height ??
            (constraints.hasBoundedHeight ? constraints.maxHeight : null);
        final double w = slotW ?? 300;
        final double h = slotH ?? 200;

        final Widget core = _showingRevealed
            ? widget.child
            : Image.asset(
                _workPlaceholder,
                width: w,
                height: h,
                fit: widget.fit,
                alignment: widget.alignment,
                cacheWidth: _workPlaceholderCacheWidth,
                gaplessPlayback: true,
              );
        final bool bigEnough =
            (slotW ?? 0) >= _minBadgeSlot && (slotH ?? 0) >= _minBadgeSlot;
        // 不可揭示（接入点未开 / 用户总闸关闭）或槽位太小 → 保持零额外开销，
        // 连悬浮监听都不挂。
        if (!_revealEnabled || !widget.showBadge || !bigEnough) {
          return SizedBox(width: w, height: h, child: core);
        }

        return MouseRegion(
          onEnter: (_) {
            if (!_hovered) setState(() => _hovered = true);
          },
          onExit: (_) {
            if (_hovered) setState(() => _hovered = false);
          },
          child: SizedBox(
            width: w,
            height: h,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                core,
                Positioned(
                  right: 4,
                  bottom: 4,
                  // 已揭示时角标必须常驻，否则鼠标一移开就再也点不回遮蔽。
                  child: AnimatedOpacity(
                    opacity: (_hovered || _showingRevealed) ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 150),
                    child: _revealBadge(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 纯净模式内容图的模糊态（v2.1.2 统一方案）：
  ///
  /// - [sensitive] = false：「检测中」——[child] 高斯模糊 + 右下角沙漏角标。
  /// - [sensitive] = true：已判定敏感——同样的模糊 + **左上角 NSFW 徽标**
  ///   + 右下角角标按钮（v2.5 起可揭示，见 [_revealBadge]）。
  ///   v2.1.2 弃用旧「黑底 + 提示文字」占位：模糊态构图轮廓可见、观感连续
  ///   （判定前后无跳变），安全性质不变——sigma 下任何 R18 细节不可辨认，
  ///   仍是 fail-closed。
  ///
  /// sigma 14（v2.1.4 从 30 下调到 20；v2.1.14 再下调到 14）：滚动列表里
  /// 几十张卡片同时模糊时，光栅化成本与 sigma 正相关；14/20/30 在
  /// 「任何细节不可辨」上无感知差异（都远超可辨认阈值），每降一档
  /// GPU/CPU 合成成本约降 1/4~1/3。合成层外扩也从 3×20=60px 收到
  /// 3×14=42px（v2.1.10 溢出事故的外扩量同源）。
  static const double _fullBlurSigma = 14.0;

  Widget _buildBlurredPreview({required bool sensitive}) {
    // 揭示只对「已判定敏感」生效；「检测中」是可揭示=false 的检测窗口，
    // 放行等于未判定就直出原图（fail-open）。
    final Widget core = (sensitive && _showingRevealed)
        ? widget.child
        : _blurred(widget.child, sigma: _fullBlurSigma);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool bigEnough = constraints.maxWidth.isFinite &&
            constraints.maxHeight.isFinite &&
            constraints.maxWidth >= _minBadgeSlot &&
            constraints.maxHeight >= _minBadgeSlot;
        if (!bigEnough || !widget.showBadge) return core;
        return Stack(
          fit: StackFit.passthrough,
          children: <Widget>[
            core,
            if (sensitive)
              // 左上角 NSFW 提示徽标（需求 v2.1.2：替代黑底占位；
              // v2.1.14 由右上角移到左上角——卡片右上角普遍被自身元素
              // （评分/徽章/更多菜单）占用，左上角在库页/探索页卡片里更空）
              Positioned(
                left: 4,
                top: 4,
                child: IgnorePointer(
                  child: Container(
                    key: const ValueKey<String>('nsfw_nsfw_badge'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xCCB3261E),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'NSFW',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                        letterSpacing: 0.5,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            if (sensitive)
              // 右下角角标＝揭示入口（v2.5）。与左上角 NSFW 徽标分工：
              // 徽标说明"这是被过滤的内容"，角标负责"要不要看原图"。
              Positioned(right: 4, bottom: 4, child: _revealBadge())
            else
              Positioned(
                right: 4,
                bottom: 4,
                child: IgnorePointer(
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.45),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Icon(
                      Icons.hourglass_empty,
                      size: 14,
                      color: Colors.white.withOpacity(0.85),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// 打码态主体。任何一条不满足条件的分支都落到整图模糊，**不会输出清晰原图**。
  ///
  /// **v2.2 策略变更：局部马赛克整体退役，敏感即整图模糊。**
  /// 用户实测：全裸 / 大部位特写 / 多类别暴露的图片只打局部马赛克，
  /// 「遮了个寂寞」——打码块之外仍有大面积裸露、轮廓与肤色完全可辨，
  /// 遮敏形同虚设。原先用「大面积暴露判定」只在面积够大时才升级为
  /// 整图模糊，但该阈值本身就是漏网之鱼的来源（阈值两侧观感断崖、
  /// 且检测器对局部特写容易只出一个小框）。
  /// 现在只要判定为敏感（bbox 非空）就整图模糊，判定口径唯一、无阈值可漏。
  /// 代价是敏感图的构图信息也一并丢失——这正是遮敏想要的，且揭示手势
  /// （[_revealEnabled]）仍可让用户主动查看原图。
  ///
  /// v2.2 前这里按 [_boxes] 面积分档：够大 → 整图模糊，否则 → 局部马赛克。
  /// 分档逻辑已随策略退役一并移除，只保留「敏感即整图模糊」一条路径。
  Widget _buildCensored({double? slotW, double? slotH}) {
    return _blurred(widget.child, sigma: _fullBlurSigma);
  }

  /// 高斯模糊包装。**必须**用 [ClipRect] 包住 [ImageFiltered]。
  ///
  /// 原因：`ImageFiltered` 的合成层（`ImageFilterLayer`）绘制边界是 child
  /// 边界**外扩约 3×sigma**（sigma 14 → 四周外扩约 42px）。而下游容器
  /// （如详情弹窗封面区的 `Stack`）只有在发生**布局溢出**
  /// （`RenderStack._hasVisualOverflow`）时才 push clip——模糊不改变布局
  /// 尺寸，永远不会触发它，于是模糊雾会直接画进槽位之外的相邻区域
  /// （用户实测 v2.1.9：详情弹窗封面模糊底部溢出盖住「启动游戏」按钮区）。
  /// [ClipRect] 的 `RenderClipRect.paint` 是**无条件**裁剪，把雾钉死在
  /// child 布局边界内。零布局影响（RenderProxyBox，size = child.size）。
  Widget _blurred(Widget child, {double? sigma}) => ClipRect(
        child: ImageFiltered(
          imageFilter: ui.ImageFilter.blur(
            sigmaX: sigma ?? widget.fallbackBlurSigma,
            sigmaY: sigma ?? widget.fallbackBlurSigma,
          ),
          child: child,
        ),
      );

  /// 叠加右下角角标（§5.5 视觉提示 + §5.4 揭示入口）。
  ///
  /// v2.5：**不再**给整图包揭示手势 —— 那个 `GestureDetector` 会吃掉调用方
  /// 自身的单击/双击/长按（网格卡片因此长期被迫不开 `enableReveal`）。
  /// 揭示改由右下角角标承担，两者互不抢占。
  Widget _decorate(Widget core, {double? slotW, double? slotH}) {
    final bool bigEnough =
        (slotW ?? 0) >= _minBadgeSlot && (slotH ?? 0) >= _minBadgeSlot;
    if (!widget.showBadge || !bigEnough) return core;
    return Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        core,
        Positioned(right: 4, bottom: 4, child: _revealBadge()),
      ],
    );
  }

  /// 右下角角标（v2.5 起由纯指示变为**揭示按钮**）。
  ///
  /// - 遮蔽态：`visibility_off`（眼睛 + 斜杠）；
  /// - 揭示态：`visibility`（亮眼，提示再点一次恢复遮蔽）；
  /// - 可点性：仅当 [_revealEnabled]（接入点 `enableReveal` × 用户总闸
  ///   `allowReveal`）为真。为假时退回 `IgnorePointer`——角标仍是遮蔽指示，
  ///   但绝不抢走它下方区域的点击。
  Widget _revealBadge() {
    final bool revealed = _showingRevealed;
    final Widget box = Container(
      key: const ValueKey<String>('nsfw_reveal_badge'),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.45),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Icon(
        revealed ? Icons.visibility_outlined : Icons.visibility_off_outlined,
        size: 14,
        color: Colors.white.withOpacity(0.85),
      ),
    );
    if (!_revealEnabled) return IgnorePointer(child: box);
    return Semantics(
      button: true,
      label: revealed ? '恢复遮蔽' : '显示原图',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _toggleReveal,
          child: box,
        ),
      ),
    );
  }
}
