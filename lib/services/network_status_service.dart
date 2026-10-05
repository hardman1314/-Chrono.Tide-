import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../core/pb_config.dart';

/// 集中式网络可达性服务（singleton + ChangeNotifier）。
///
/// 通过探测 PocketBase 服务器的 `/api/health` 端点判断在线/离线状态，
/// 而非仅判断设备是否有任意网络（connectivity_plus 无法识别 captive portal
/// 或服务器宕机）。探针带 6s 超时。
///
/// ★ 2026-09-08 修复「网络正常却莫名断联」：
/// 旧实现只探 PB 单点（小型 VPS，慢响应常见）+ 3s 超时 + 连续 2 次失败即
/// 判离线 → 6~8 秒的服务抖动就会被当成断网，进而阻断探索页加载与登录。
/// 现改为：服务探不通时再探公共端点，只有「服务不通 且 公网也不通」才判离线。
///
/// ★ 滞回防抖（解决「瞬间离线后自动恢复」抖动）：
/// - 离线判定需连续 [ _offlineThreshold ] 次失败，单次抖动不切状态；
/// - 在线恢复仅需 1 次成功（快速恢复）；
/// - 在线态首次失败不切状态，改用 [ _uncertainInterval ] 快速确认间隔，
///   既能在真断网时 ~16s 内确认离线，又能让瞬时抖动静默自愈。
///
/// 乐观默认 `isOnline = true`，启动不阻塞：init() 立即返回，首次探针异步发起。
/// 自适应轮询：在线稳定 60s（低开销）/ 在线不确定 8s（快速确认）/ 离线 10s（快速恢复）。
///
/// 各页面/组件直接监听本服务（仿 BigPictureManager 模式），不做 props 透传。
class NetworkStatusService extends ChangeNotifier {
  NetworkStatusService._();
  static final NetworkStatusService instance = NetworkStatusService._();

  // 乐观默认：假定在线，启动不被探针阻塞。首次探针异步修正。
  bool _isOnline = true;
  DateTime? _lastCheckedAt;
  Timer? _timer;
  bool _isProbing = false;
  bool _initialized = false;

  // 滞回防抖：连续失败计数。仅当达到阈值才由在线切离线。
  int _consecutiveFailures = 0;
  // 当前定时器实际使用的间隔（用于判断是否需要重建定时器，避免无谓 cancel/recreate）
  Duration? _currentTimerInterval;

  /// 复用长连接客户端：旧实现每次探针都 http.get（内部新建再关闭 Client），
  /// 每轮都要重新 DNS + TCP + TLS 握手，既慢又容易在慢网下超时。
  http.Client? _client;
  http.Client get _http => _client ??= http.Client();

  static const Duration _probeTimeout = Duration(seconds: 6);
  static const Duration _onlineInterval = Duration(seconds: 60);
  static const Duration _offlineInterval = Duration(seconds: 10);
  // 在线但最近有失败：快速确认间隔（尽快确认是否真断网，避免等满 60s）
  static const Duration _uncertainInterval = Duration(seconds: 8);
  // checkNow 防抖：距上次探针不足此时长则直接返回当前值
  static const Duration _manualDebounce = Duration(seconds: 3);
  // 离线判定阈值：连续失败达到此次数才由在线切离线（核心防抖参数）
  static const int _offlineThreshold = 3;

  /// 公共连通性兜底端点：用于区分「本机断网」与「PB 服务器不可达」。
  ///
  /// 旧实现只探测 PocketBase 一个点，而它是一台小型 VPS（117.72.115.30:8090），
  /// 慢响应/短暂抖动非常常见 —— 结果设备明明联网，App 却判定离线并阻断
  /// 探索页加载与登录（discover_page / auth_service 均 gate 在 isOnline 上）。
  static const List<String> _publicProbeUrls = <String>[
    'https://www.gstatic.com/generate_204',
    'https://www.baidu.com/',
  ];

  /// 当前是否在线（乐观值，可能尚未完成首次探针）。
  bool get isOnline => _isOnline;

  /// 上次探针完成时间（用于调试/UI 展示）。
  DateTime? get lastCheckedAt => _lastCheckedAt;

  /// 是否已完成初始化（init 调用过）。
  bool get isInitialized => _initialized;

  /// 根据当前状态与失败计数决定轮询间隔。
  Duration _desiredInterval() {
    if (!_isOnline) return _offlineInterval; // 离线：快速恢复检测
    if (_consecutiveFailures > 0) return _uncertainInterval; // 在线但最近有失败：快速确认
    return _onlineInterval; // 在线稳定：低频
  }

  /// 仅在间隔变化时重建定时器，减少 cancel/recreate 抖动。
  void _ensureTimer() {
    final desired = _desiredInterval();
    if (desired == _currentTimerInterval &&
        _timer != null &&
        _timer!.isActive) {
      return;
    }
    _timer?.cancel();
    _currentTimerInterval = desired;
    _timer = Timer.periodic(desired, (_) => _probe());
  }

  /// 非阻塞初始化。设置乐观默认，启动自适应定时器，异步发首次探针。
  /// 调用方无需 await 探针结果。建议在 UserCacheService.init() 之后调用。
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    _ensureTimer(); // 以在线间隔启动（乐观）
    // fire-and-forget：首次探针不阻塞调用方
    _probe();
    debugPrint('[NET] NetworkStatusService 初始化完成（乐观在线，后台探测中）');
  }

  /// 立即触发一次探针（3s 防抖）。返回探针完成后的在线状态。
  /// 供 UI「重试连接」按钮、网络恢复后手动确认等场景调用。
  Future<bool> checkNow() async {
    if (_lastCheckedAt != null &&
        DateTime.now().difference(_lastCheckedAt!) < _manualDebounce) {
      return _isOnline; // 距上次探针太近，直接返回当前值
    }
    await _probe();
    return _isOnline;
  }

  Future<void> _probe() async {
    if (_isProbing) return;
    _isProbing = true;
    bool online;
    try {
      // ① 先探服务本身
      final serviceOk =
          await _check('${PBConfig.baseUrl}/api/health', require200: true);
      if (serviceOk) {
        online = true;
      } else {
        // ② 服务不可达 ≠ 设备离线。再探公共端点区分两者：
        //    只有「服务不可用 且 公网也不通」才判定离线。
        online = await _checkAnyPublic();
        debugPrint(
            '[NET] 服务探针失败，公共连通性=${online ? "通" : "不通"} → ${online ? "判定在线（服务不可达但设备联网）" : "判定离线"}');
      }
    } finally {
      _isProbing = false;
    }
    _lastCheckedAt = DateTime.now();
    _applyResult(online);
  }

  /// 单次可达性探测。
  /// [require200] 为真时要求严格 200（服务健康检查）；否则收到任何 HTTP 响应
  /// （含 3xx/4xx）都说明链路是通的。
  Future<bool> _check(String url, {required bool require200}) async {
    try {
      final resp = await _http.head(Uri.parse(url)).timeout(_probeTimeout);
      if (require200) return resp.statusCode == 200;
      return resp.statusCode < 500;
    } catch (e) {
      debugPrint('[NET] 探针失败 $url : $e');
      return false;
    }
  }

  /// 依次探测公共端点，任一可达即认为设备在线。
  Future<bool> _checkAnyPublic() async {
    for (final url in _publicProbeUrls) {
      if (await _check(url, require200: false)) return true;
    }
    return false;
  }

  /// 应用探针结果，带滞回防抖。
  /// - 成功：清零失败计数；离线→在线单次即恢复（快速恢复）。
  /// - 失败：累加失败计数；仅当连续失败达阈值才由在线切离线，
  ///   未达阈值时保持在线并加速确认（不通知 UI，避免抖动）。
  void _applyResult(bool online) {
    if (online) {
      _consecutiveFailures = 0;
      if (!_isOnline) {
        _isOnline = true;
        debugPrint('[NET] 网络状态变化: OFFLINE → ONLINE（已恢复）');
        _ensureTimer();
        notifyListeners();
      } else {
        // 已在线：可能从 uncertain 节奏回到稳定节奏
        _ensureTimer();
      }
      return;
    }

    // 失败
    _consecutiveFailures++;
    if (_isOnline) {
      if (_consecutiveFailures >= _offlineThreshold) {
        // 连续失败达阈值：确认离线
        _isOnline = false;
        debugPrint(
            '[NET] 网络状态变化: ONLINE → OFFLINE（连续 $_consecutiveFailures/$_offlineThreshold 次探针失败）');
        _ensureTimer();
        notifyListeners();
      } else {
        // 未达阈值：保持在线，加速确认（静默，不通知 UI）
        debugPrint(
            '[NET] 探针失败 $_consecutiveFailures/$_offlineThreshold，保持在线，加速确认中');
        _ensureTimer();
      }
    } else {
      // 已离线且继续失败：保持离线，仅维持定时器节奏
      _ensureTimer();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _client?.close();
    _client = null;
    super.dispose();
  }
}
