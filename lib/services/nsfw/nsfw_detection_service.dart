/// NSFW 局部检测服务：worker isolate 池（v2.1.5 起 3 并行）+ ONNX Runtime
/// + 优先级队列。
///
/// 方案见 `docs/DEV/features/nsfw_filter_implementation_plan.md` §4.2。
///
/// **职责切分（重要）**
/// - 主 isolate：图片解码 + 拉伸 resize（走 `dart:ui`，由引擎在工作线程完成，不卡 UI）
/// - worker isolate：RGBA → NCHW float32（归一化到 [-1,1]）→ ONNX 推理 → 评分后处理
///
/// 之所以不把解码也放进 worker：`dart:ui` 的解码 API 依赖引擎，
/// 在裸 `Isolate.spawn` 出来的 isolate 里不可靠；而 `onnxruntime` 是纯 FFI
/// （`DynamicLibrary.open('onnxruntime.dll')`），在任何 isolate 都能跑。
/// 于是把「必须在主 isolate 做的」和「适合丢后台的」按能力边界切开。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:onnxruntime/onnxruntime.dart';

import '../../core/portable_image_cache_manager.dart';
import 'nsfw_box.dart';
import 'nsfw_detection_store.dart';
import 'nsfw_model_provider.dart';
import 'nsfw_rating_postprocess.dart';
import 'nsfw_settings.dart';

/// 单个待检测任务。
class _NsfwJob {
  _NsfwJob({
    required this.filePath,
    required this.key,
    required this.aliasKeys,
    required this.completer,
  });

  final String filePath;
  final String key;
  final List<String> aliasKeys;
  final Completer<NsfwDetection?> completer;
}

class NsfwDetectionService {
  /// 单张图片文件大小上限：超过就跳过，避免为一张 100MB 的图耗尽内存。
  static const int _maxFileBytes = 64 * 1024 * 1024;

  static NsfwDetectionService? _instance;
  static NsfwDetectionService get instance =>
      _instance ??= NsfwDetectionService._();
  NsfwDetectionService._();

  final NsfwSettings _settings = NsfwSettings.instance;
  final NsfwDetectionStore _store = NsfwDetectionStore.instance;

  /// 推理 worker 数量（v2.1.5）：此前单 isolate 串行（~1-2s/张），库页/
  /// 探索页几百张封面首次批量入队时积压 10 分钟以上——v2.1.4 把「未判定
  /// 封面」从原图直显改为模糊预览后，该吞吐瓶颈被直接暴露成「全屏模糊
  /// 迟迟不解除」（用户实测）。3 并发把首刷时间压缩到 1/3；响应按 jobId
  /// 路由（[_pending]），乱序返回天然安全。每个 worker 独立加载模型
  /// （16.8MB，v2.1.14 更新）+ 推理激活内存，2 个（由 3 降为 2，
  /// 见上方说明）在桌面端内存开销可接受。
  /// v2.1.14 由 3 降到 2：单张推理仅 16~30ms（dbrating mv3 @384，实测
  /// python 16ms / Dart 侧同量级），2 个 worker 单线程 ≈ 60~120 张/秒，
  /// 几百张库的首扫仍在数秒内完成；而 3 worker × intraOp 2 线程会让
  /// 6 个 CPU 线程常驻满载（用户实测「影响设备性能」），且每 worker 独立
  /// 加载 16.8MB 模型（3 份 ≈ 50MB 常驻内存 → 2 份 ≈ 33MB）。
  static const int _workerCount = 2;

  final List<Isolate> _isolates = <Isolate>[];
  final List<SendPort> _workerPorts = <SendPort>[];

  /// 轮询分发索引：把推理任务均匀打到各 worker。
  int _rr = 0;

  ReceivePort? _responsePort;
  Future<bool>? _initFuture;
  String? _initError;

  int _nextJobId = 1;
  final Map<int, Completer<List<NsfwBox>?>> _pending =
      <int, Completer<List<NsfwBox>?>>{};

  /// 双优先级队列：18+ 作品的图先扫（§6.2）。
  final Queue<_NsfwJob> _highQueue = Queue<_NsfwJob>();
  final Queue<_NsfwJob> _normalQueue = Queue<_NsfwJob>();

  /// 已入队/在处理的 key，防止同一张图重复入队。
  final Set<String> _inFlight = <String>{};

  /// 解码或推理失败过的 key，本次会话内不再重试（避免坏图无限循环）。
  final Set<String> _failed = <String>{};

  /// 正在 [_process] 中的任务数（worker 槽位占用）：[_pump] 据此决定
  /// 还能从队列取几个任务——此前整条流水线串行（取一个等完再取下一个），
  /// 多 worker 形同虚设；现在取到任务立即派发、不阻塞取后续任务。
  int _busyJobs = 0;

  bool _pumping = false;
  bool _disposed = false;

  /// 供测试读取当前 worker 槽位数（v2.1.14：[_workerCount] 是性能调参
  /// 常量，测试硬编码具体数值会在调参时假失败——让测试按实际槽位推导）。
  @visibleForTesting
  static int get workerSlotsForTest => _workerCount;

  bool get isReady => _workerPorts.isNotEmpty;
  String? get initError => _initError;
  int get pendingCount => _highQueue.length + _normalQueue.length;

  /// 轮询取下一个 worker 端口（调用方保证列表非空）。
  SendPort _nextPort() => _workerPorts[_rr++ % _workerPorts.length];

  /// 仅供单测注入可控的任务执行体（替代 [_process]，绕过真实模型/isolate），
  /// 用于验证槽位调度的并发行为。null = 走真实链路。
  @visibleForTesting
  static Future<NsfwDetection?> Function(String key, String filePath)?
      debugProcessOverride;

  // ===================== 初始化 =====================

  /// 幂等初始化：加载设置 → 加载缓存 → 释放模型 → 启动 worker。
  ///
  /// 返回 `false` 表示不可用（模型缺失 / DLL 加载失败等），调用方应静默降级为
  /// 「不打码」而不是弹错误 —— 这是个增强功能，不该阻塞主流程。
  Future<bool> ensureReady() => _initFuture ??= _init();

  Future<bool> _init() async {
    try {
      await _settings.load();
      final bool cacheInvalidated =
          await _store.load(_settings.modelSignature);
      if (cacheInvalidated) {
        // 检测参数变化导致缓存整表作废（v2.1.3）：重置全量扫描标记，
        // 让下一次触发点（设置页开关/补扫）重新补判全库；
        // 用户实际看到的图由组件级按需检测（NsfwImage）即时覆盖。
        await _settings.resetFullScanFlag();
      }

      final String? modelPath = await NsfwModelProvider.ensureExtracted();
      if (modelPath == null) {
        _initError = '模型文件释放失败';
        return false;
      }

      // v2.1.5：spawn [_workerCount] 个 worker 并行推理。所有 worker 共享
      // 同一个响应端口（消息按 jobId 路由到 [_pending]，与 worker 无关）。
      // 任一 worker 启动失败即整体失败并回滚已启动的实例——半可用状态
      // （如 1/3 worker）会让吞吐不可预期，不如走静默降级路径。
      final List<Isolate> spawned = <Isolate>[];
      final List<SendPort> ports = <SendPort>[];
      bool allSpawned = false;
      try {
        for (int i = 0; i < _workerCount; i++) {
          final ReceivePort init = ReceivePort();
          final Isolate iso = await Isolate.spawn<List<Object>>(
            _nsfwWorkerEntry,
            <Object>[init.sendPort, modelPath],
            debugName: 'nsfw-detect-$i',
            errorsAreFatal: false,
          );
          spawned.add(iso);

          final Object? first = await init.first;
          init.close();

          if (first is! SendPort) {
            _initError = first is String ? first : 'worker 启动失败: $first';
            debugPrint('[NSFW-DETECT] $_initError');
            return false;
          }
          ports.add(first);
        }
        allSpawned = true;
      } finally {
        if (allSpawned) {
          _isolates
            ..clear()
            ..addAll(spawned);
          _workerPorts
            ..clear()
            ..addAll(ports);
          _responsePort = ReceivePort()..listen(_onWorkerMessage);
          for (final SendPort port in _workerPorts) {
            port.send(<Object>['bind', _responsePort!.sendPort]);
          }
          debugPrint('[NSFW-DETECT] $_workerCount 个 worker 就绪，模型 $modelPath');
        } else {
          // spawn 抛异常（catch 尚未赋值 _initError）或握手失败——回滚
          // 已启动实例，保持「全有或全无」：半可用状态让吞吐不可预期。
          for (final Isolate iso in spawned) {
            iso.kill(priority: Isolate.immediate);
          }
        }
      }
      return _initError == null;
    } catch (e, st) {
      _initError = '$e';
      debugPrint('[NSFW-DETECT] 初始化失败: $e\n$st');
      return false;
    }
  }

  void _onWorkerMessage(Object? msg) {
    if (msg is! List || msg.length < 3) return;
    final int jobId = msg[0] as int;
    final Completer<List<NsfwBox>?>? c = _pending.remove(jobId);
    if (c == null || c.isCompleted) return;
    final Object? error = msg[2];
    if (error != null) {
      debugPrint('[NSFW-DETECT] 推理失败(job $jobId): $error');
      c.complete(null);
      return;
    }
    final Object? raw = msg[1];
    if (raw is! List) {
      c.complete(const <NsfwBox>[]);
      return;
    }
    final List<NsfwBox> boxes = <NsfwBox>[];
    for (final Object? item in raw) {
      final NsfwBox? b = NsfwBox.fromJson(item);
      if (b != null && !b.isEmpty) boxes.add(b);
    }
    c.complete(boxes);
  }

  // ===================== 对外入口 =====================

  /// 立即检测一张本地图片并等待结果。
  ///
  /// [aliasUrl] 传来源 URL 时会做双键写入（§4.4），让网络图渲染路径也能命中。
  /// 已有结果直接返回缓存，除非 [force]。
  Future<NsfwDetection?> detectFile(
    String filePath, {
    String? aliasUrl,
    bool force = false,
    bool highPriority = false,
  }) {
    if (_disposed || filePath.isEmpty) return Future<NsfwDetection?>.value();
    final String key = NsfwDetectionStore.keyForFile(filePath);
    if (key.isEmpty) return Future<NsfwDetection?>.value();

    if (!force) {
      final NsfwDetection? cached = _store.detectionFor(key);
      if (cached != null) return Future<NsfwDetection?>.value(cached);
      if (_failed.contains(key)) return Future<NsfwDetection?>.value();
    }
    if (_inFlight.contains(key)) {
      // 已在队列中，找到那个 job 复用它的 completer
      final _NsfwJob? existing = _findQueued(key);
      if (existing != null) return existing.completer.future;
    }

    final _NsfwJob job = _NsfwJob(
      filePath: filePath,
      key: key,
      aliasKeys: <String>[
        if (aliasUrl != null && aliasUrl.trim().isNotEmpty)
          NsfwDetectionStore.keyForUrl(aliasUrl),
      ],
      completer: Completer<NsfwDetection?>(),
    );
    _inFlight.add(key);
    (highPriority ? _highQueue : _normalQueue).add(job);
    _pump();
    return job.completer.future;
  }

  /// 把一个**仍在低优先级队列排队**的任务提到高优先级队尾（v2.2）。
  ///
  /// 场景：库页/探索页一次滚过几百张封面，全部以低优先级入队；用户此刻
  /// 正在看的这张可能排在队尾，要等几分钟才轮到——期间 UI 一直停在
  /// 「检测中」模糊态（用户实测：正常图迟迟不清晰）。`NsfwImage` 的模糊
  /// 看门狗在等待超时后调用本方法，让**在屏**的图插到队首，先出结果。
  ///
  /// 只搬移「尚未开始处理」的任务：已经在推理中的任务无法转移，
  /// 强行重排只会多算一遍。
  void promoteToHighPriority(String filePath) {
    final String key = NsfwDetectionStore.keyForFile(filePath);
    if (key.isEmpty) return;
    _NsfwJob? target;
    for (final _NsfwJob job in _normalQueue) {
      if (job.key == key) {
        target = job;
        break;
      }
    }
    if (target == null) return; // 已在推理 / 已在高优先队列 / 已完成
    _normalQueue.remove(target);
    _highQueue.add(target);
    _pump();
  }

  /// 入队但不等结果（下载落盘后的即时触发用）。
  void enqueueFile(
    String filePath, {
    String? aliasUrl,
    bool highPriority = false,
    bool force = false,
  }) {
    detectFile(
      filePath,
      aliasUrl: aliasUrl,
      highPriority: highPriority,
      force: force,
    ).ignore();
  }

  /// 网络图「等落盘 → 入队」的去重集合（v2.1.16）。
  ///
  /// 旧实现在 NsfwImage 组件内轮询 `getFileFromCache`（2 次/1.5s 窗口），
  /// 封面下载超过窗口时直接放弃且**从未入队**——判定缓存永远没有该图
  /// 记录，网格滚动回收重建后每次都重现「模糊预览 → 放弃」循环（用户实测：
  /// 已清晰的封面滚回来又模糊）。现将等待动作上移到服务级，组件销毁
  /// 不影响等待与入队，判定结果必然落库。
  final Set<String> _urlDetectionInFlight = <String>{};

  /// 等待网络图缓存落盘后入队检测（fire-and-forget）。
  ///
  /// - `getFileStream` 与 child `CachedNetworkImage` 走同一 CacheManager
  ///   单例，WebHelper 对同 URL 并发下载合并（`_memCache`），不产生第二次
  ///   网络请求；已落盘的 URL 立即返回 FileInfo；
  /// - 落盘后 [enqueueFile] 双键写入（文件路径主键 + URL 别名键），
  ///   渲染层滚动重建后按 URL 键查询秒命中；
  /// - 下载失败仅移除去重标记，组件下次重建（滚动回来）会自然重新发起，
  ///   循环有界；重复调用被 [_urlDetectionInFlight] 去重。
  void ensureUrlDetection(String url) {
    final String key = NsfwDetectionStore.keyForUrl(url);
    if (key.isEmpty || _urlDetectionInFlight.contains(key)) return;
    _urlDetectionInFlight.add(key);
    unawaited(_waitCacheAndEnqueue(url));
  }

  Future<void> _waitCacheAndEnqueue(String url) async {
    try {
      await for (final Object response
          in PortableImageCacheManager().getFileStream(url)) {
        if (response is FileInfo) {
          enqueueFile(response.file.path, aliasUrl: url, highPriority: true);
          return;
        }
      }
    } catch (e) {
      debugPrint('[NSFW-DETECT] 网络图等待落盘失败: $e');
    } finally {
      _urlDetectionInFlight.remove(NsfwDetectionStore.keyForUrl(url));
    }
  }

  _NsfwJob? _findQueued(String key) {
    for (final _NsfwJob j in _highQueue) {
      if (j.key == key) return j;
    }
    for (final _NsfwJob j in _normalQueue) {
      if (j.key == key) return j;
    }
    return null;
  }

  /// 清空队列（用户取消扫描）。已判定结果保留。
  void cancelPending() {
    for (final _NsfwJob j in <_NsfwJob>[..._highQueue, ..._normalQueue]) {
      if (!j.completer.isCompleted) j.completer.complete(null);
      _inFlight.remove(j.key);
    }
    _highQueue.clear();
    _normalQueue.clear();
  }

  // ===================== 槽位调度泵 =====================

  /// 任务泵（v2.1.5 重构）：以 worker 槽位并发取任务——取到任务立即派发
  /// （[_runJob] 不被 await），队列还能继续出队直到占满 [_workerCount] 个槽。
  /// 此前是「取一个 → await 推理完 → 再取下一个」的整链串行，多 worker
  /// 名存实亡；库页几百张封面的首次批量入队因此积压十分钟以上。
  ///
  /// 重入保护：[_pumping] 防止并发进入；[_runJob] 完成一个任务后回调
  /// [_pump] 补位空出的槽。
  void _pump() {
    if (_pumping) return;
    _pumping = true;
    try {
      while (!_disposed &&
          _busyJobs < _workerCount &&
          (_highQueue.isNotEmpty || _normalQueue.isNotEmpty)) {
        final _NsfwJob job =
            _highQueue.isNotEmpty ? _highQueue.removeFirst() : _normalQueue.removeFirst();
        _busyJobs++;
        unawaited(_runJob(job));
      }
    } finally {
      _pumping = false;
    }
  }

  /// 单任务执行体：跑完释放槽位并补位。异常走 [_failed] 表（与旧逻辑一致）。
  Future<void> _runJob(_NsfwJob job) async {
    NsfwDetection? result;
    try {
      final Future<NsfwDetection?> Function(String, String)? override =
          debugProcessOverride;
      result = override != null
          ? await override(job.key, job.filePath)
          : await _process(job);
    } catch (e) {
      debugPrint('[NSFW-DETECT] 处理 ${job.filePath} 异常: $e');
      _failed.add(job.key);
    } finally {
      _inFlight.remove(job.key);
      _busyJobs--;
    }
    if (!job.completer.isCompleted) job.completer.complete(result);
    if (!_disposed) _pump(); // 槽位空出，补位
  }

  Future<NsfwDetection?> _process(_NsfwJob job) async {
    // 开关裁决必须在 ensureReady 之前：关闭状态下连 12MB 模型都不加载。
    // load() 幂等；且接入点只管入队，真正的开关判断放这里，
    // 覆盖"上个会话开了开关、本会话尚未打开设置面板"的读默认值漏检时序。
    // 注意：此处直接 return，不经过 _failed —— 开关关闭不是检测失败，
    // 否则之后再开启开关会被 _failed 挡住永远不重检。
    await _settings.load();
    if (!_settings.enabled) return null;
    if (!await ensureReady()) return null;
    // 轮询分发：多个任务并行在飞时均匀打到各 worker（响应按 jobId 路由，
    // 与哪个 worker 处理无关）。
    final SendPort? port = _workerPorts.isNotEmpty ? _nextPort() : null;
    if (port == null) return null;

    final int inferSize = _settings.inferSize.pixels;

    final File file = File(job.filePath);
    if (!await file.exists()) {
      _failed.add(job.key);
      return null;
    }
    final int len = await file.length();
    if (len <= 0 || len > _maxFileBytes) {
      debugPrint('[NSFW-DETECT] 跳过异常大小文件($len 字节): ${job.filePath}');
      _failed.add(job.key);
      return null;
    }

    final _DecodedInput? input =
        await _decodeForInference(await file.readAsBytes(), inferSize);
    if (input == null) {
      _failed.add(job.key);
      return null;
    }

    final int jobId = _nextJobId++;
    final Completer<List<NsfwBox>?> c = Completer<List<NsfwBox>?>();
    _pending[jobId] = c;
    port.send(<Object>[
      'infer',
      jobId,
      input.rgba,
      input.inferW, // 实际送入模型的张量宽（v2.4 拉伸成正方形，恒等于 inferSize）
      input.inferH,
      input.origW,
      input.origH,
      _settings.confThreshold,
    ]);

    final List<NsfwBox>? boxes = await c.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {
        _pending.remove(jobId);
        debugPrint('[NSFW-DETECT] 推理超时: ${job.filePath}');
        return null;
      },
    );
    if (boxes == null) {
      _failed.add(job.key);
      return null;
    }

    // 判定口径只有一条：管线阈值（用户参考集校准值 0.648，v2.4）之上即
    // 敏感 —— worker 返回的全图合成框非空就是敏感信号。v2.3 删除了
    // v2.2.1 的 applyR18Gate（实测该门只砍召回）；v2.4 的评分分类器
    // 同理不再加任何复核门。
    final NsfwDetection detection = NsfwDetection(
      imgW: input.origW,
      imgH: input.origH,
      detectedAtMs: DateTime.now().millisecondsSinceEpoch,
      boxes: boxes,
    );
    _store.put(job.key, detection, aliasKeys: job.aliasKeys);
    return detection;
  }

  // ===================== 主 isolate 侧解码 =====================

  /// 解码 + **拉伸** resize 成 `inferSize × inferSize` 正方形。
  ///
  /// v2.4 模型替换（YOLO 部位检测 → anime_dbrating 四级评分分类器）后，
  /// 预处理回到**正方形拉伸**——timm 系分类器的训练/推理管线就是
  /// PIL `img.resize((384, 384))`（非等比，形变由模型在训练时适应）。
  /// 此前 v2.3 的「等比缩放 + ceil32」是 YOLO letterbox 语义，对
  /// 分类器不再适用（实测等比 + 填充会显著改变评分分布）。
  ///
  /// 另一个关键点：`instantiateCodec` 在**同时**给出 targetWidth 与
  /// targetHeight 时**不保持宽高比**（SDK 文档：只给一个才按比例推另一个），
  /// 这里两个都给，因为我们自己算好了目标尺寸。
  /// 解码顺带 resize，由引擎原生完成，比先解全尺寸再缩放快得多，
  /// 也避免为一张 4K 图分配 30MB+ 的位图。
  static Future<_DecodedInput?> _decodeForInference(
      Uint8List fileBytes, int inferSize) async {
    ui.ImmutableBuffer? buffer;
    ui.Codec? codec;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(fileBytes);
      final ui.ImageDescriptor descriptor =
          await ui.ImageDescriptor.encoded(buffer);
      final int origW = descriptor.width;
      final int origH = descriptor.height;
      if (origW <= 0 || origH <= 0) return null;

      final int targetW = inferSize;
      final int targetH = inferSize;

      codec = await descriptor.instantiateCodec(
        targetWidth: targetW,
        targetHeight: targetH,
      );
      final ui.FrameInfo frame = await codec.getNextFrame();
      final ui.Image image = frame.image;
      try {
        // rawStraightRgba：非预乘 alpha，语义更接近 PIL 的 convert('RGB')
        final ByteData? bytes = await image.toByteData(
          format: ui.ImageByteFormat.rawStraightRgba,
        );
        if (bytes == null) return null;
        final int expected = targetW * targetH * 4;
        if (bytes.lengthInBytes < expected) {
          debugPrint('[NSFW-DETECT] 像素数据不足: ${bytes.lengthInBytes}/$expected');
          return null;
        }
        return _DecodedInput(
          rgba: Uint8List.fromList(
              bytes.buffer.asUint8List(bytes.offsetInBytes, expected)),
          origW: origW,
          origH: origH,
          inferW: targetW,
          inferH: targetH,
        );
      } finally {
        image.dispose();
      }
    } catch (e) {
      debugPrint('[NSFW-DETECT] 解码失败: $e');
      return null;
    } finally {
      codec?.dispose();
      buffer?.dispose();
    }
  }

  // ===================== 收尾 =====================

  Future<void> shutdown() async {
    _disposed = true;
    cancelPending();
    for (final SendPort port in _workerPorts) {
      try {
        port.send(<Object>['shutdown']);
      } catch (_) {}
    }
    _responsePort?.close();
    _responsePort = null;
    _workerPorts.clear();
    for (final Isolate iso in _isolates) {
      iso.kill(priority: Isolate.beforeNextEvent);
    }
    _isolates.clear();
    _initFuture = null;
    await _store.flush();
  }

  @visibleForTesting
  static void resetForTest() => _instance = null;
}

class _DecodedInput {
  _DecodedInput({
    required this.rgba,
    required this.origW,
    required this.origH,
    required this.inferW,
    required this.inferH,
  });

  /// `inferW × inferH × 4` 的 RGBA 字节。
  final Uint8List rgba;

  /// 原图尺寸，用于把 bbox 映射回原图坐标系。
  final int origW;
  final int origH;

  /// 实际送入模型的张量宽高（v2.4 起恒等于 inferSize 正方形）。
  final int inferW;
  final int inferH;
}

// ===========================================================================
// worker isolate
// ===========================================================================

/// worker 入口。[args] = `[SendPort initPort, String modelPath]`。
///
/// 建会话失败时把错误字符串发回 initPort，主 isolate 据此静默降级。
void _nsfwWorkerEntry(List<Object> args) {
  final SendPort initPort = args[0] as SendPort;
  final String modelPath = args[1] as String;

  OrtSession? session;
  OrtSessionOptions? sessionOptions;
  try {
    OrtEnv.instance.init(level: OrtLoggingLevel.error);
    // ⚠️ 必须 fromBuffer：见 nsfw_model_provider.dart 顶部关于 fromFile 在
    // Windows 上传 char* 而 ORT 要 wchar_t* 的说明。
    final Uint8List modelBytes = File(modelPath).readAsBytesSync();
    sessionOptions = OrtSessionOptions()
      // v2.1.14 由 2 降到 1：单张图串行推理，多线程对 16.8MB 的小模型
      // 收益极小（算子并行度有限），却让 CPU 占用翻倍并与 UI 抢核。
      // 吞吐缺口由 worker 并发补（见 [_workerCount]）。
      ..setIntraOpNumThreads(1)
      ..setInterOpNumThreads(1)
      ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);
    session = OrtSession.fromBuffer(modelBytes, sessionOptions);
  } catch (e) {
    initPort.send('ONNX 会话创建失败: $e');
    return;
  }

  final String inputName =
      session.inputNames.isNotEmpty ? session.inputNames.first : 'images';
  final String outputName =
      session.outputNames.isNotEmpty ? session.outputNames.first : 'output0';

  final ReceivePort rx = ReceivePort();
  SendPort? replyPort;

  rx.listen((Object? msg) {
    if (msg is! List || msg.isEmpty) return;
    switch (msg[0]) {
      case 'bind':
        replyPort = msg[1] as SendPort;
        return;
      case 'shutdown':
        try {
          session?.release();
          sessionOptions?.release();
          OrtEnv.instance.release();
        } catch (_) {}
        rx.close();
        return;
      case 'infer':
        final int jobId = msg[1] as int;
        final SendPort? reply = replyPort;
        if (reply == null) return;
        try {
          final Uint8List rgba = msg[2] as Uint8List;
          final int inferW = msg[3] as int;
          final int inferH = msg[4] as int;
          final int imgW = msg[5] as int;
          final int imgH = msg[6] as int;
          final double threshold = msg[7] as double;
          final List<NsfwBox> boxes = _runInference(
            session: session!,
            inputName: inputName,
            outputName: outputName,
            rgba: rgba,
            inferW: inferW,
            inferH: inferH,
            imgW: imgW,
            imgH: imgH,
            threshold: threshold,
          );
          reply.send(<Object?>[
            jobId,
            boxes.map((NsfwBox b) => b.toJson()).toList(growable: false),
            null,
          ]);
        } catch (e, st) {
          reply.send(<Object?>[jobId, null, '$e\n$st']);
        }
        return;
    }
  });

  initPort.send(rx.sendPort);
}

List<NsfwBox> _runInference({
  required OrtSession session,
  required String inputName,
  required String outputName,
  required Uint8List rgba,
  required int inferW,
  required int inferH,
  required int imgW,
  required int imgH,
  required double threshold,
}) {
  final Float32List nchw = _rgbaToNormNchw(rgba, inferW, inferH);

  OrtValueTensor? inputTensor;
  OrtRunOptions? runOptions;
  List<OrtValue?>? outputs;
  try {
    // 张量是 NCHW：[1, 3, H, W]。v2.4 分类器为正方形输入（H = W = 384）。
    inputTensor = OrtValueTensor.createTensorWithDataList(
      nchw,
      <int>[1, 3, inferH, inferW],
    );
    runOptions = OrtRunOptions();
    outputs = session.run(
      runOptions,
      <String, OrtValue>{inputName: inputTensor},
      <String>[outputName],
    );
    if (outputs.isEmpty || outputs.first == null) return const <NsfwBox>[];

    // `OrtValueTensor.value` 对 [1, 1, 4] 的 float 张量返回
    // 嵌套 List，不是 Float32List —— 别想当然。
    return NsfwRatingPostprocess.decodeFromOrtValue(
      outputs.first!.value,
      threshold: threshold,
      imgW: imgW,
      imgH: imgH,
    );
  } finally {
    for (final OrtValue? o in outputs ?? const <OrtValue?>[]) {
      try {
        o?.release();
      } catch (_) {}
    }
    try {
      inputTensor?.release();
    } catch (_) {}
    try {
      runOptions?.release();
    } catch (_) {}
  }
}

/// RGBA(8bit) → NCHW float32，逐通道归一化到 [-1, 1]。
///
/// 对齐评测管线的 `(x / 255 - 0.5) / 0.5`（timm 分类器训练口径）。
/// alpha 通道丢弃（与 PIL `convert('RGB')` 一致）。
/// [w]/[h] 是张量宽高（v2.4 分类器为相等正方形）。
Float32List _rgbaToNormNchw(Uint8List rgba, int w, int h) {
  final int plane = w * h;
  final Float32List out = Float32List(plane * 3);
  const double inv = 2.0 / 255.0;
  int si = 0;
  for (int i = 0; i < plane; i++) {
    out[i] = rgba[si] * inv - 1.0;
    out[plane + i] = rgba[si + 1] * inv - 1.0;
    out[plane * 2 + i] = rgba[si + 2] * inv - 1.0;
    si += 4;
  }
  return out;
}
