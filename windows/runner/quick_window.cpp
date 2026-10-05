// quick_window.cpp
// 快捷自定义窗口引擎（借鉴 AltSnap 的交互模型，RamonUnch/AltSnap，GPL）
//
// 编译进 runner 可执行文件，Dart 侧通过 DynamicLibrary.process() 查找
// qw_* 导出符号，无需加载额外 DLL。
//
// 交互模型（仅作用于"被跟踪的游戏窗口"）：
// - 中键单击(<450ms)      → 弹出动作菜单（置顶/透明/静音/最大化…）
// - 中键长按(≥450ms)      → 快捷开关本功能（挂起/恢复，1200ms 完成）
// - Alt + 左键拖拽窗口内部  → 移动窗口
// - Alt + 左键拖拽窗口边缘  → 调整大小
// - Alt + 滚轮              → 调整窗口透明度
//
// 菜单关闭方式：菜单外任意点击 / 菜单内右键或中键 / Esc。
// 菜单是 WS_EX_NOACTIVATE 后台窗口（前台是游戏），SetCapture 拿不到
// 菜单外的事件，"点击外部关闭"由低层钩子完成（见 QuickMouseProc）。
//
// 线程模型（关键）：
// - WH_MOUSE_LL 钩子必须在有消息泵的线程安装，否则回调永不触发且会被
//   系统超时摘除。Dart FFI 调用运行在 Flutter UI 线程（无 Win32 消息泵），
//   因此本引擎内部创建**专用工作线程**：安装钩子、创建隐藏消息窗口
//   （菜单宿主）、跑 GetMessage 消息循环。所有手势与菜单逻辑都在该线程。
// - 共享状态（target/pids/labels/alpha/muted）用 SRWLOCK 保护，
//   钩子回调内锁区间极短（仅指针/整数读写），不会阻塞低层钩子。
//
// 其他设计要点：
// - Alt 键状态用 GetAsyncKeyState(VK_MENU) 实时读取，无需键盘钩子
// - 菜单弹出通过 PostMessage 到消息窗口，避免在钩子回调里阻塞
// - 菜单文字由 Dart 侧传入（qw_set_labels），原生代码不含 UI 文案，
//   避免源码编码问题，也便于未来国际化
// - "静音游戏"使用 WASAPI 音频会话 API 按进程静音（替代 AltSnap 的
//   全局 VK_VOLUME_MUTE），不影响系统其他声音

#include <windows.h>
#include <mmdeviceapi.h>
#include <audiopolicy.h>
#include <objbase.h>
#include <cstdlib>
#include <cstring>

// ═══════════════════════════════════════════════════════════════
// 常量
// ═══════════════════════════════════════════════════════════════

static const int   kEdgeMargin   = 8;     // 边缘判定像素（拖边调整大小）
static const int   kOpacityStep  = 16;    // 滚轮透明度步长
static const UINT  kMsgShowMenu  = WM_APP + 0x51;
static const UINT  kMsgQuit      = WM_APP + 0x52;

// 菜单命令 ID
enum QuickMenuId {
  QM_TOPMOST      = 1,
  QM_OPACITY_UP   = 2,
  QM_OPACITY_DOWN = 3,
  QM_OPACITY_FULL = 4,
  QM_MUTE         = 5,
  QM_MAXIMIZE     = 6,
  QM_MINIMIZE     = 7,
  QM_CENTER       = 8,
  QM_CLOSE        = 9,
};

// Dart 可调用的动作 ID（qw_perform 用）
enum QuickAction {
  QA_TOPMOST_TOGGLE = 1,
  QA_MINIMIZE       = 2,
  QA_MAXIMIZE_TOGGLE= 3,
  QA_CENTER         = 4,
  QA_CLOSE          = 5,
  QA_OPACITY_UP     = 6,
  QA_OPACITY_DOWN   = 7,
  QA_OPACITY_RESET  = 8,
  QA_MUTE_TOGGLE    = 9,
};

// 菜单标签索引（与 Dart 侧约定，顺序固定）
enum QuickLabelIdx {
  QL_TOPMOST_ON = 0,   // "窗口置顶"
  QL_TOPMOST_OFF,      // "取消置顶"
  QL_OPACITY_UP,       // "增加透明度"
  QL_OPACITY_DOWN,     // "降低透明度"
  QL_OPACITY_FULL,     // "恢复不透明"
  QL_MUTE_ON,          // "静音游戏"
  QL_MUTE_OFF,         // "取消静音"
  QL_MAXIMIZE,         // "最大化"
  QL_RESTORE,          // "还原窗口"
  QL_MINIMIZE,         // "最小化"
  QL_CENTER,           // "居中显示"
  QL_CLOSE,            // "关闭窗口"
  QL_HINT_CLOSING,     // "正在关闭快捷窗口控制"
  QL_HINT_OPENING,     // "正在开启快捷窗口控制"
  QL_HINT_SUB,         // "继续长按 · 松开取消"
  QL_HINT_CLOSED,      // "已关闭快捷窗口控制"
  QL_HINT_OPENED,      // "已开启快捷窗口控制"
  QL_COUNT
};

// ═══════════════════════════════════════════════════════════════
// 共享状态（SRWLOCK 保护）
// ═══════════════════════════════════════════════════════════════

static SRWLOCK g_lock = SRWLOCK_INIT;

static bool     g_enabled     = false;
static HWND     g_target      = NULL;    // 被跟踪的游戏窗口
static int      g_alpha       = 255;     // 当前透明度（255=不透明）
static bool     g_layeredByUs = false;   // WS_EX_LAYERED 是否由本引擎添加
static int      g_muted       = 0;

static unsigned long g_pids[64] = {};    // 目标进程 PID 集合（音频会话匹配）
static int      g_pidCount    = 0;

static wchar_t* g_labels[QL_COUNT] = {}; // 菜单标签（Dart 传入）

// 工作线程专属（仅工作线程读写，无需锁）
static HWND     g_msgWnd      = NULL;
static HHOOK    g_mouseHook   = NULL;
static bool     g_dragging    = false;
static int      g_dragEdge    = 0;       // 0=移动 1..8=八方向边缘
static POINT    g_startPt{};
static RECT     g_startRect{};
static bool     g_moved       = false;

// 线程管理
static HANDLE   g_thread      = NULL;
static HANDLE   g_readyEvent  = NULL;    // 钩子安装完成信号

// ═══════════════════════════════════════════════════════════════
// PID 快照（锁内拷贝，避免跨线程长期持锁）
// ═══════════════════════════════════════════════════════════════

struct PidSnapshot {
  unsigned long pids[64];
  int count;
  HWND target;
  int alpha;
  bool layeredByUs;
  int muted;
};

static PidSnapshot SnapshotLocked() {
  PidSnapshot s{};
  AcquireSRWLockShared(&g_lock);
  memcpy(s.pids, g_pids, sizeof(g_pids));
  s.count = g_pidCount;
  s.target = g_target;
  s.alpha = g_alpha;
  s.layeredByUs = g_layeredByUs;
  s.muted = g_muted;
  ReleaseSRWLockShared(&g_lock);
  return s;
}

// ═══════════════════════════════════════════════════════════════
// WASAPI：按进程静音（音量合成器同款机制）
// 线程安全：每次调用临时初始化 COM（稀有操作，开销可忽略）
// ═══════════════════════════════════════════════════════════════

// 对快照 pids 内所有音频会话执行 SetMute；outMuted 非 NULL 时先读当前状态
static bool SetSessionsMuteLockedState(bool mute, int* outMuted) {
  PidSnapshot snap = SnapshotLocked();
  if (snap.count == 0) return false;

  HRESULT hrInit = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
  if (FAILED(hrInit) && hrInit != RPC_E_CHANGED_MODE) return false;
  bool doUninit = SUCCEEDED(hrInit);

  IMMDeviceEnumerator* enumerator = NULL;
  IMMDevice* device = NULL;
  IAudioSessionManager2* mgr = NULL;
  IAudioSessionEnumerator* sessions = NULL;
  bool hit = false;

  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), NULL, CLSCTX_ALL,
                              __uuidof(IMMDeviceEnumerator),
                              (void**)&enumerator))) {
    if (doUninit) CoUninitialize();
    return false;
  }

  do {
    if (FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device)))
      break;
    if (FAILED(device->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL,
                                NULL, (void**)&mgr)))
      break;
    if (FAILED(mgr->GetSessionEnumerator(&sessions)))
      break;

    int count = 0;
    sessions->GetCount(&count);
    DWORD selfPid = GetCurrentProcessId();

    for (int i = 0; i < count; i++) {
      IAudioSessionControl* ctrl = NULL;
      if (FAILED(sessions->GetSession(i, &ctrl))) continue;

      IAudioSessionControl2* ctrl2 = NULL;
      if (SUCCEEDED(ctrl->QueryInterface(__uuidof(IAudioSessionControl2),
                                         (void**)&ctrl2))) {
        DWORD pid = 0;
        if (SUCCEEDED(ctrl2->GetProcessId(&pid)) && pid != selfPid) {
          for (int p = 0; p < snap.count; p++) {
            if (snap.pids[p] == (unsigned long)pid) {
              ISimpleAudioVolume* vol = NULL;
              if (SUCCEEDED(ctrl2->QueryInterface(
                      __uuidof(ISimpleAudioVolume), (void**)&vol))) {
                if (outMuted) {
                  BOOL m = FALSE;
                  if (SUCCEEDED(vol->GetMute(&m))) {
                    AcquireSRWLockExclusive(&g_lock);
                    g_muted = m ? 1 : 0;
                    ReleaseSRWLockExclusive(&g_lock);
                    outMuted = NULL;  // 首个会话读出状态即可
                  }
                }
                vol->SetMute(mute ? TRUE : FALSE, NULL);
                hit = true;
                vol->Release();
              }
              break;
            }
          }
        }
      }
      if (ctrl2) ctrl2->Release();
      ctrl->Release();
    }
  } while (false);

  if (sessions) sessions->Release();
  if (mgr) mgr->Release();
  if (device) device->Release();
  if (enumerator) enumerator->Release();
  if (doUninit) CoUninitialize();
  return hit;
}

// 只读查询静音状态（刷新 g_muted）
static bool QuerySessionsMute() {
  PidSnapshot snap = SnapshotLocked();
  if (snap.count == 0) return false;

  HRESULT hrInit = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
  if (FAILED(hrInit) && hrInit != RPC_E_CHANGED_MODE) return false;
  bool doUninit = SUCCEEDED(hrInit);

  IMMDeviceEnumerator* enumerator = NULL;
  IMMDevice* device = NULL;
  IAudioSessionManager2* mgr = NULL;
  IAudioSessionEnumerator* sessions = NULL;
  bool found = false;

  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), NULL, CLSCTX_ALL,
                              __uuidof(IMMDeviceEnumerator),
                              (void**)&enumerator))) {
    if (doUninit) CoUninitialize();
    return false;
  }

  do {
    if (FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device)))
      break;
    if (FAILED(device->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL,
                                NULL, (void**)&mgr)))
      break;
    if (FAILED(mgr->GetSessionEnumerator(&sessions)))
      break;

    int count = 0;
    sessions->GetCount(&count);
    DWORD selfPid = GetCurrentProcessId();

    for (int i = 0; i < count && !found; i++) {
      IAudioSessionControl* ctrl = NULL;
      if (FAILED(sessions->GetSession(i, &ctrl))) continue;
      IAudioSessionControl2* ctrl2 = NULL;
      if (SUCCEEDED(ctrl->QueryInterface(__uuidof(IAudioSessionControl2),
                                         (void**)&ctrl2))) {
        DWORD pid = 0;
        if (SUCCEEDED(ctrl2->GetProcessId(&pid)) && pid != selfPid) {
          for (int p = 0; p < snap.count; p++) {
            if (snap.pids[p] == (unsigned long)pid) {
              ISimpleAudioVolume* vol = NULL;
              if (SUCCEEDED(ctrl2->QueryInterface(
                      __uuidof(ISimpleAudioVolume), (void**)&vol))) {
                BOOL m = FALSE;
                if (SUCCEEDED(vol->GetMute(&m))) {
                  AcquireSRWLockExclusive(&g_lock);
                  g_muted = m ? 1 : 0;
                  ReleaseSRWLockExclusive(&g_lock);
                  found = true;
                }
                vol->Release();
              }
              break;
            }
          }
        }
      }
      if (ctrl2) ctrl2->Release();
      ctrl->Release();
    }
  } while (false);

  if (sessions) sessions->Release();
  if (mgr) mgr->Release();
  if (device) device->Release();
  if (enumerator) enumerator->Release();
  if (doUninit) CoUninitialize();
  return found;
}

// ═══════════════════════════════════════════════════════════════
// 窗口动作（AltSnap 同款 Win32 调用；SetWindowPos 线程安全）
// ═══════════════════════════════════════════════════════════════

static const UINT kSwpBase =
    SWP_ASYNCWINDOWPOS | SWP_NOACTIVATE | SWP_NOOWNERZORDER;

static bool IsTargetTopmost() {
  AcquireSRWLockShared(&g_lock);
  HWND t = g_target;
  ReleaseSRWLockShared(&g_lock);
  if (!t) return false;
  return (GetWindowLongPtrW(t, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0;
}

// 置顶切换（AltSnap TogglesAlwaysOnTop 同款：读 EXSTYLE → SetWindowPos）
static int ToggleTopmost() {
  AcquireSRWLockShared(&g_lock);
  HWND t = g_target;
  ReleaseSRWLockShared(&g_lock);
  if (!t || !IsWindow(t)) return -1;
  HWND after = (GetWindowLongPtrW(t, GWL_EXSTYLE) & WS_EX_TOPMOST)
                   ? HWND_NOTOPMOST : HWND_TOPMOST;
  SetWindowPos(t, after, 0, 0, 0, 0, kSwpBase | SWP_NOMOVE | SWP_NOSIZE);
  return IsTargetTopmost() ? 1 : 0;
}

// 透明度（AltSnap SetWindowTrans 同款：WS_EX_LAYERED + LWA_ALPHA）
static int SetTargetOpacity(int alpha) {
  AcquireSRWLockShared(&g_lock);
  HWND t = g_target;
  int curAlpha = g_alpha;
  bool byUs = g_layeredByUs;
  ReleaseSRWLockShared(&g_lock);
  if (!t || !IsWindow(t)) return -1;
  if (alpha < 32) alpha = 32;    // 下限保护，避免窗口完全消失不可操作
  if (alpha > 255) alpha = 255;

  LONG_PTR ex = GetWindowLongPtrW(t, GWL_EXSTYLE);
  if (alpha >= 255) {
    // 恢复不透明：若 LAYERED 位由本引擎添加则摘除，还原系统行为
    if (byUs) {
      SetWindowLongPtrW(t, GWL_EXSTYLE, ex & ~WS_EX_LAYERED);
      AcquireSRWLockExclusive(&g_lock);
      if (g_target == t) g_layeredByUs = false;
      ReleaseSRWLockExclusive(&g_lock);
    } else {
      SetLayeredWindowAttributes(t, 0, 255, LWA_ALPHA);
    }
  } else {
    if (!(ex & WS_EX_LAYERED)) {
      SetWindowLongPtrW(t, GWL_EXSTYLE, ex | WS_EX_LAYERED);
      AcquireSRWLockExclusive(&g_lock);
      if (g_target == t) g_layeredByUs = true;
      ReleaseSRWLockExclusive(&g_lock);
    }
    SetLayeredWindowAttributes(t, 0, (BYTE)alpha, LWA_ALPHA);
  }
  AcquireSRWLockExclusive(&g_lock);
  if (g_target == t) g_alpha = alpha;
  ReleaseSRWLockExclusive(&g_lock);
  (void)curAlpha;
  return alpha;
}

static void MaximizeToggle() {
  AcquireSRWLockShared(&g_lock);
  HWND t = g_target;
  ReleaseSRWLockShared(&g_lock);
  if (!t || !IsWindow(t)) return;
  WINDOWPLACEMENT wp{};
  wp.length = sizeof(wp);
  GetWindowPlacement(t, &wp);
  if (wp.showCmd == SW_SHOWMAXIMIZED) {
    ShowWindow(t, SW_RESTORE);
  } else {
    ShowWindow(t, SW_MAXIMIZE);
  }
}

static void CenterWindow() {
  AcquireSRWLockShared(&g_lock);
  HWND t = g_target;
  ReleaseSRWLockShared(&g_lock);
  if (!t || !IsWindow(t)) return;
  RECT wr{};
  if (!GetWindowRect(t, &wr)) return;
  int w = wr.right - wr.left;
  int h = wr.bottom - wr.top;
  HMONITOR mon = MonitorFromWindow(t, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi{};
  mi.cbSize = sizeof(mi);
  if (!GetMonitorInfoW(mon, &mi)) return;
  int x = mi.rcWork.left + ((mi.rcWork.right - mi.rcWork.left) - w) / 2;
  int y = mi.rcWork.top + ((mi.rcWork.bottom - mi.rcWork.top) - h) / 2;
  SetWindowPos(t, NULL, x, y, 0, 0, kSwpBase | SWP_NOSIZE | SWP_NOZORDER);
}

// 恢复目标窗口被本引擎修改的属性（透明度），置顶/静音由用户意图保留
// 静音在游戏退出后随音频会话消失自然失效，无需还原
static void RestoreTargetState() {
  AcquireSRWLockShared(&g_lock);
  HWND t = g_target;
  int alpha = g_alpha;
  bool byUs = g_layeredByUs;
  ReleaseSRWLockShared(&g_lock);

  if (t && IsWindow(t) && (alpha != 255 || byUs)) {
    SetTargetOpacity(255);
  }
  AcquireSRWLockExclusive(&g_lock);
  g_alpha = 255;
  g_layeredByUs = false;
  g_muted = 0;
  ReleaseSRWLockExclusive(&g_lock);
}

// ═══════════════════════════════════════════════════════════════
// 动作菜单（自绘主题化弹出菜单：紧凑尺寸、圆角、悬停高亮）
// 不用系统 TrackPopupMenu（样式尖锐、依赖前台焦点会自动消失），
// 改为自绘 WS_POPUP 窗口 + SetCapture：不抢游戏焦点、不会无故消失，
// 选择/点击外部/右键/中键/Esc 才关闭。
// ═══════════════════════════════════════════════════════════════

// 主题调色板（菜单与提示窗口共用；跟随应用亮/暗主题，Dart 侧
// qw_set_theme 切换）。暗色 = ChronoTide 暗色系 + 紫强调 #7C6CF0；
// 亮色 = 浅底 + 深字，保证明亮主题下文字对比度。
struct MenuPalette {
  COLORREF bg;
  COLORREF border;
  COLORREF text;
  COLORREF textDim;
  COLORREF hover;
  COLORREF accent;
  COLORREF sep;
};

static const MenuPalette kPaletteDark = {
    RGB(40, 40, 47),    // bg
    RGB(82, 82, 95),    // border
    RGB(235, 235, 240), // text
    RGB(140, 140, 152), // textDim
    RGB(78, 72, 118),   // hover
    RGB(124, 108, 240), // accent
    RGB(58, 58, 67),    // sep
};

static const MenuPalette kPaletteLight = {
    RGB(252, 252, 254), // bg
    RGB(206, 206, 218), // border
    RGB(28, 28, 40),    // text（深色文字，明亮主题下对比充足）
    RGB(116, 116, 130), // textDim
    RGB(233, 230, 252), // hover（浅紫高亮）
    RGB(108, 92, 220),  // accent（亮底上加深的紫强调）
    RGB(226, 226, 235), // sep
};

// 当前调色板（qw_set_theme 写、绘制线程读；用 g_lock 保护拷贝）
static MenuPalette g_palette = kPaletteDark;

static const int kMenuRadius   = 8;   // 圆角半径
static const int kMenuPadX     = 10;  // 左右内边距
static const int kMenuPadV     = 5;   // 上下内边距
static const int kMenuItemH    = 28;  // 菜单项高度（轻量紧凑）
static const int kMenuSepH     = 9;   // 分隔线高度
static const int kMenuCheckCol = 22;  // 勾选列宽

struct QMenuItem {
  wchar_t text[64];
  int cmd;
  bool checked;
  bool grayed;
  bool sep;
  RECT rc;  // 窗口客户区坐标
};

// 菜单状态（仅工作线程访问，模态期间单实例）
static QMenuItem g_items[16];
static int   g_itemCount  = 0;
static int   g_hover      = -1;
static int   g_menuResult = -1;
static bool  g_menuDone   = false;
static HWND  g_menuWnd    = NULL;
static HFONT g_menuFont   = NULL;
static bool  g_menuClassRegistered = false;

static void MenuAdd(const wchar_t* text, int cmd, bool checked, bool grayed) {
  if (g_itemCount >= 16) return;
  QMenuItem& it = g_items[g_itemCount++];
  if (text && text[0]) {
    int n = 0;
    while (n < 63 && text[n]) {
      it.text[n] = text[n];
      n++;
    }
    it.text[n] = 0;
  } else {
    it.text[0] = 0;
  }
  it.cmd = cmd;
  it.checked = checked;
  it.grayed = grayed;
  it.sep = false;
}

static void MenuAddSep() {
  if (g_itemCount >= 16) return;
  QMenuItem& it = g_items[g_itemCount++];
  it.text[0] = 0;
  it.cmd = 0;
  it.checked = false;
  it.grayed = false;
  it.sep = true;
}

static void MenuPaint(HWND hwnd) {
  PAINTSTRUCT ps;
  HDC hdc = BeginPaint(hwnd, &ps);
  RECT rc;
  GetClientRect(hwnd, &rc);
  int w = rc.right;
  int h = rc.bottom;

  AcquireSRWLockShared(&g_lock);
  MenuPalette pal = g_palette;
  ReleaseSRWLockShared(&g_lock);

  // 双缓冲防闪烁
  HDC mem = CreateCompatibleDC(hdc);
  HBITMAP bmp = CreateCompatibleBitmap(hdc, w, h);
  HGDIOBJ oldBmp = SelectObject(mem, bmp);

  RECT all = {0, 0, w, h};
  HBRUSH bg = CreateSolidBrush(pal.bg);
  FillRect(mem, &all, bg);
  DeleteObject(bg);

  // 圆角边框（窗口 Region 已裁圆角，描边同半径）
  HPEN pen = CreatePen(PS_SOLID, 1, pal.border);
  HGDIOBJ oldPen = SelectObject(mem, pen);
  RoundRect(mem, 0, 0, w - 1, h - 1, kMenuRadius * 2, kMenuRadius * 2);

  SelectObject(mem, g_menuFont);
  SetBkMode(mem, TRANSPARENT);

  for (int i = 0; i < g_itemCount; i++) {
    QMenuItem& it = g_items[i];
    if (it.sep) {
      HPEN sp = CreatePen(PS_SOLID, 1, pal.sep);
      HGDIOBJ op = SelectObject(mem, sp);
      MoveToEx(mem, it.rc.left, it.rc.top + kMenuSepH / 2, NULL);
      LineTo(mem, it.rc.right, it.rc.top + kMenuSepH / 2);
      SelectObject(mem, op);
      DeleteObject(sp);
      continue;
    }

    if (i == g_hover && !it.grayed) {
      HBRUSH hb = CreateSolidBrush(pal.hover);
      FillRect(mem, &it.rc, hb);
      DeleteObject(hb);
    }

    // 勾选标记（强调色 ✓）
    if (it.checked) {
      HPEN cp = CreatePen(PS_SOLID, 2, pal.accent);
      HGDIOBJ op = SelectObject(mem, cp);
      int cy = (it.rc.top + it.rc.bottom) / 2;
      int cx = kMenuPadX + 8;
      MoveToEx(mem, cx - 5, cy, NULL);
      LineTo(mem, cx - 1, cy + 4);
      LineTo(mem, cx + 6, cy - 4);
      SelectObject(mem, op);
      DeleteObject(cp);
    }

    SetTextColor(mem, it.grayed ? pal.textDim : pal.text);
    RECT tr = it.rc;
    tr.left += kMenuPadX + kMenuCheckCol;
    tr.right -= kMenuPadX;
    DrawTextW(mem, it.text, -1, &tr,
              DT_SINGLELINE | DT_VCENTER | DT_LEFT | DT_END_ELLIPSIS);
  }

  SelectObject(mem, oldPen);
  DeleteObject(pen);

  BitBlt(hdc, 0, 0, w, h, mem, 0, 0, SRCCOPY);
  SelectObject(mem, oldBmp);
  DeleteObject(bmp);
  DeleteDC(mem);
  EndPaint(hwnd, &ps);
}

static LRESULT CALLBACK MenuWndProc(HWND hwnd, UINT msg, WPARAM wParam,
                                    LPARAM lParam) {
  switch (msg) {
    case WM_PAINT:
      MenuPaint(hwnd);
      return 0;
    case WM_ERASEBKGND:
      return 1;  // 全部交给 WM_PAINT 双缓冲
    case WM_MOUSEMOVE: {
      POINT pt;
      pt.x = (int)(short)LOWORD(lParam);
      pt.y = (int)(short)HIWORD(lParam);
      int hover = -1;
      for (int i = 0; i < g_itemCount; i++) {
        if (!g_items[i].sep && !g_items[i].grayed &&
            PtInRect(&g_items[i].rc, pt) != 0) {
          hover = i;
          break;
        }
      }
      if (hover != g_hover) {
        g_hover = hover;
        InvalidateRect(hwnd, NULL, FALSE);
      }
      return 0;
    }
    case WM_LBUTTONUP: {
      POINT pt;
      pt.x = (int)(short)LOWORD(lParam);
      pt.y = (int)(short)HIWORD(lParam);
      for (int i = 0; i < g_itemCount; i++) {
        if (!g_items[i].sep && !g_items[i].grayed &&
            PtInRect(&g_items[i].rc, pt) != 0) {
          g_menuResult = g_items[i].cmd;
          break;
        }
      }
      g_menuDone = true;  // 点击外部也关闭（结果保持 -1）
      return 0;
    }
    case WM_RBUTTONUP:
    case WM_MBUTTONUP:
      g_menuDone = true;
      return 0;
    case WM_TIMER:
      // Esc 关闭
      if (GetAsyncKeyState(VK_ESCAPE) & 0x8000) g_menuDone = true;
      return 0;
    case WM_CAPTURECHANGED:
      g_menuDone = true;
      return 0;
    case WM_DESTROY:
      g_menuWnd = NULL;
      return 0;
  }
  return DefWindowProcW(hwnd, msg, wParam, lParam);
}

// 弹出模态菜单，返回选中的命令 ID（未选择/取消返回 -1）
static int RunActionMenu(int x, int y) {
  if (!g_menuFont) {
    g_menuFont = CreateFontW(-15, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
                             OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                             CLEARTYPE_QUALITY,
                             DEFAULT_PITCH | FF_DONTCARE, L"Microsoft YaHei UI");
  }

  // 度量文本宽度 → 菜单宽度自适应
  HDC sc = GetDC(NULL);
  HGDIOBJ oldFont = SelectObject(sc, g_menuFont);
  int maxW = 0;
  for (int i = 0; i < g_itemCount; i++) {
    if (g_items[i].sep) continue;
    SIZE sz{};
    if (GetTextExtentPoint32W(sc, g_items[i].text,
                              (int)wcslen(g_items[i].text), &sz)) {
      if (sz.cx > maxW) maxW = sz.cx;
    }
  }
  SelectObject(sc, oldFont);
  ReleaseDC(NULL, sc);

  int width = kMenuPadX + kMenuCheckCol + maxW + kMenuPadX;
  if (width < 150) width = 150;
  if (width > 300) width = 300;

  // 布局各项矩形
  int yCur = kMenuPadV;
  for (int i = 0; i < g_itemCount; i++) {
    QMenuItem& it = g_items[i];
    if (it.sep) {
      SetRect(&it.rc, 12, yCur, width - 12, yCur + kMenuSepH);
      yCur += kMenuSepH;
    } else {
      SetRect(&it.rc, 4, yCur, width - 4, yCur + kMenuItemH);
      yCur += kMenuItemH;
    }
  }
  int height = yCur + kMenuPadV;

  // 限制在显示器工作区内
  POINT mp = {x, y};
  HMONITOR mon = MonitorFromPoint(mp, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi{};
  mi.cbSize = sizeof(mi);
  if (GetMonitorInfoW(mon, &mi)) {
    if (x + width > mi.rcWork.right) x = mi.rcWork.right - width;
    if (y + height > mi.rcWork.bottom) y = mi.rcWork.bottom - height;
    if (x < mi.rcWork.left) x = mi.rcWork.left;
    if (y < mi.rcWork.top) y = mi.rcWork.top;
  }

  if (!g_menuClassRegistered) {
    WNDCLASSW wc{};
    wc.lpfnWndProc = MenuWndProc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"ChronoTideQuickMenu";
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    RegisterClassW(&wc);
    g_menuClassRegistered = true;
  }

  g_menuWnd = CreateWindowExW(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
      L"ChronoTideQuickMenu", L"", WS_POPUP, x, y, width, height, NULL, NULL,
      GetModuleHandleW(NULL), NULL);
  if (!g_menuWnd) return -1;

  // 圆角裁剪
  HRGN rgn =
      CreateRoundRectRgn(0, 0, width + 1, height + 1, kMenuRadius, kMenuRadius);
  SetWindowRgn(g_menuWnd, rgn, TRUE);

  g_hover = -1;
  g_menuResult = -1;
  g_menuDone = false;

  ShowWindow(g_menuWnd, SW_SHOWNOACTIVATE);
  UpdateWindow(g_menuWnd);
  SetCapture(g_menuWnd);
  SetTimer(g_menuWnd, 1, 60, NULL);

  // 模态循环：选择 / 点击外部 / 右键 / 中键 / Esc / 失去捕获 → 结束
  MSG msg;
  while (!g_menuDone && GetMessageW(&msg, NULL, 0, 0) > 0) {
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }

  if (GetCapture() == g_menuWnd) ReleaseCapture();
  KillTimer(g_menuWnd, 1);
  if (g_menuWnd && IsWindow(g_menuWnd)) DestroyWindow(g_menuWnd);
  g_menuWnd = NULL;
  return g_menuResult;
}

static void ShowActionMenu(int x, int y) {
  if (g_menuWnd) return;  // 已打开，防重入

  AcquireSRWLockShared(&g_lock);
  HWND t = g_target;
  ReleaseSRWLockShared(&g_lock);
  if (!t || !IsWindow(t)) return;

  // 弹菜单前同步最新置顶/静音状态
  QuerySessionsMute();
  AcquireSRWLockShared(&g_lock);
  int alpha = g_alpha;
  int muted = g_muted;
  wchar_t* L[QL_COUNT];
  memcpy(L, g_labels, sizeof(L));
  ReleaseSRWLockShared(&g_lock);

  bool topmost = IsTargetTopmost();
  WINDOWPLACEMENT wp{};
  wp.length = sizeof(wp);
  GetWindowPlacement(t, &wp);
  bool maximized = (wp.showCmd == SW_SHOWMAXIMIZED);

  g_itemCount = 0;
  // 文案 = 即将执行的动作：未置顶 → "窗口置顶"；已置顶 → "取消置顶"
  MenuAdd(topmost ? (L[QL_TOPMOST_OFF] ? L[QL_TOPMOST_OFF] : L"Unpin")
                  : (L[QL_TOPMOST_ON] ? L[QL_TOPMOST_ON] : L"Pin"),
          QM_TOPMOST, topmost, false);
  MenuAddSep();
  MenuAdd(L[QL_OPACITY_UP] ? L[QL_OPACITY_UP] : L"Opacity+", QM_OPACITY_UP,
          false, false);
  MenuAdd(L[QL_OPACITY_DOWN] ? L[QL_OPACITY_DOWN] : L"Opacity-",
          QM_OPACITY_DOWN, false, false);
  MenuAdd(L[QL_OPACITY_FULL] ? L[QL_OPACITY_FULL] : L"Opaque", QM_OPACITY_FULL,
          false, alpha >= 255);
  MenuAddSep();
  MenuAdd(muted ? (L[QL_MUTE_OFF] ? L[QL_MUTE_OFF] : L"Unmute")
                : (L[QL_MUTE_ON] ? L[QL_MUTE_ON] : L"Mute"),
          QM_MUTE, muted, false);
  MenuAddSep();
  MenuAdd(maximized ? (L[QL_RESTORE] ? L[QL_RESTORE] : L"Restore")
                    : (L[QL_MAXIMIZE] ? L[QL_MAXIMIZE] : L"Maximize"),
          QM_MAXIMIZE, maximized, false);
  MenuAdd(L[QL_MINIMIZE] ? L[QL_MINIMIZE] : L"Minimize", QM_MINIMIZE, false,
          false);
  MenuAdd(L[QL_CENTER] ? L[QL_CENTER] : L"Center", QM_CENTER, false, false);
  MenuAddSep();
  MenuAdd(L[QL_CLOSE] ? L[QL_CLOSE] : L"Close", QM_CLOSE, false, false);

  int cmd = RunActionMenu(x, y);

  switch (cmd) {
    case QM_TOPMOST:      ToggleTopmost(); break;
    case QM_OPACITY_UP:   SetTargetOpacity(alpha + kOpacityStep); break;
    case QM_OPACITY_DOWN: SetTargetOpacity(alpha - kOpacityStep); break;
    case QM_OPACITY_FULL: SetTargetOpacity(255); break;
    case QM_MUTE: {
      int newMuted = muted ? 0 : 1;
      AcquireSRWLockExclusive(&g_lock);
      g_muted = newMuted;
      ReleaseSRWLockExclusive(&g_lock);
      SetSessionsMuteLockedState(newMuted != 0, NULL);
      break;
    }
    case QM_MAXIMIZE:     MaximizeToggle(); break;
    case QM_MINIMIZE:
      AcquireSRWLockShared(&g_lock);
      t = g_target;
      ReleaseSRWLockShared(&g_lock);
      if (t && IsWindow(t)) ShowWindow(t, SW_MINIMIZE);
      break;
    case QM_CENTER:       CenterWindow(); break;
    case QM_CLOSE:
      AcquireSRWLockShared(&g_lock);
      t = g_target;
      ReleaseSRWLockShared(&g_lock);
      if (t && IsWindow(t)) PostMessageW(t, WM_CLOSE, 0, 0);
      break;
    default: break;
  }
}

// ═══════════════════════════════════════════════════════════════
// 长按中键快捷开关 + 鼠标旁小提示
// 单击中键(<450ms)=弹菜单；长按(≥450ms)=确认中(鼠标旁显示进度提示，
// 松开取消)；按满 1200ms=切换功能开关(挂起/恢复，钩子常驻)。
// ═══════════════════════════════════════════════════════════════

static const UINT kMsgMidDown = WM_APP + 0x53;
static const UINT kMsgMidUp   = WM_APP + 0x54;
static const UINT_PTR TID_HOLD = 2;
static const UINT_PTR TID_HINT_HIDE = 3;
static const ULONGLONG kClickMs = 450;   // 单击阈值
static const ULONGLONG kTotalMs = 1200;  // 长按完成阈值

// 长按状态（仅工作线程）
static bool       g_holdActive  = false;
static bool       g_holdConfirm = false;
static ULONGLONG  g_holdStart   = 0;
static POINT      g_holdPt{};
// async 键状态曾报告"按下中"（兜底检测用；被钩子吞掉的事件
// GetAsyncKeyState 可能不更新，因此松开判定以钩子 WM_MBUTTONUP 为主）
static bool       g_holdSawAsyncDown = false;

// 提示窗口（仅工作线程）
static HWND  g_hintWnd = NULL;
static bool  g_hintClassOk = false;
static HFONT g_hintFontMain = NULL;
static HFONT g_hintFontSub = NULL;
static bool  g_hintClosing = true;   // true=正在关闭 false=正在开启
static bool  g_hintResult = false;   // false=进度态 true=结果态
static int   g_hintProgress = 0;     // 0..100
static int   g_hintW = 0;
static int   g_hintH = 0;

static void HintEnsureFonts() {
  if (!g_hintFontMain) {
    g_hintFontMain = CreateFontW(-15, 0, 0, 0, FW_SEMIBOLD, 0, 0, 0,
                                 DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                                 CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                                 DEFAULT_PITCH | FF_DONTCARE,
                                 L"Microsoft YaHei UI");
  }
  if (!g_hintFontSub) {
    g_hintFontSub = CreateFontW(-12, 0, 0, 0, FW_NORMAL, 0, 0, 0,
                                DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                                CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                                DEFAULT_PITCH | FF_DONTCARE,
                                L"Microsoft YaHei UI");
  }
}

static void HintPaint(HWND hwnd) {
  PAINTSTRUCT ps;
  HDC hdc = BeginPaint(hwnd, &ps);
  RECT rc;
  GetClientRect(hwnd, &rc);
  int w = rc.right;
  int h = rc.bottom;

  AcquireSRWLockShared(&g_lock);
  MenuPalette pal = g_palette;
  ReleaseSRWLockShared(&g_lock);

  HDC mem = CreateCompatibleDC(hdc);
  HBITMAP bmp = CreateCompatibleBitmap(hdc, w, h);
  HGDIOBJ oldBmp = SelectObject(mem, bmp);

  RECT all = {0, 0, w, h};
  HBRUSH bg = CreateSolidBrush(pal.bg);
  FillRect(mem, &all, bg);
  DeleteObject(bg);

  HPEN pen = CreatePen(PS_SOLID, 1, pal.border);
  HGDIOBJ oldPen = SelectObject(mem, pen);
  RoundRect(mem, 0, 0, w - 1, h - 1, kMenuRadius * 2, kMenuRadius * 2);

  SetBkMode(mem, TRANSPARENT);

  // 主行
  wchar_t* L[QL_COUNT];
  AcquireSRWLockShared(&g_lock);
  memcpy(L, g_labels, sizeof(L));
  ReleaseSRWLockShared(&g_lock);

  const wchar_t* mainText;
  if (g_hintResult) {
    mainText = g_hintClosing ? (L[QL_HINT_CLOSED] ? L[QL_HINT_CLOSED]
                                                  : L"Closed")
                             : (L[QL_HINT_OPENED] ? L[QL_HINT_OPENED]
                                                  : L"Opened");
  } else {
    mainText = g_hintClosing ? (L[QL_HINT_CLOSING] ? L[QL_HINT_CLOSING]
                                                   : L"Closing")
                             : (L[QL_HINT_OPENING] ? L[QL_HINT_OPENING]
                                                   : L"Opening");
  }

  SelectObject(mem, g_hintFontMain);
  SetTextColor(mem, pal.text);
  RECT tr = {kMenuPadX, 7, w - kMenuPadX, 7 + 20};
  DrawTextW(mem, mainText, -1, &tr,
            DT_SINGLELINE | DT_VCENTER | DT_LEFT | DT_END_ELLIPSIS);

  if (!g_hintResult) {
    // 副行
    const wchar_t* subText =
        L[QL_HINT_SUB] ? L[QL_HINT_SUB] : L"Keep holding";
    SelectObject(mem, g_hintFontSub);
    SetTextColor(mem, pal.textDim);
    RECT sr = {kMenuPadX, 29, w - kMenuPadX, 29 + 16};
    DrawTextW(mem, subText, -1, &sr,
              DT_SINGLELINE | DT_VCENTER | DT_LEFT | DT_END_ELLIPSIS);

    // 底部进度条
    int barY = h - 10;
    int barX0 = kMenuPadX;
    int barX1 = w - kMenuPadX;
    RECT track = {barX0, barY, barX1, barY + 4};
    HBRUSH tb = CreateSolidBrush(pal.sep);
    FillRect(mem, &track, tb);
    DeleteObject(tb);
    int fill = barX0 + ((barX1 - barX0) * g_hintProgress) / 100;
    if (fill > barX0) {
      RECT prog = {barX0, barY, fill, barY + 4};
      HBRUSH pb = CreateSolidBrush(pal.accent);
      FillRect(mem, &prog, pb);
      DeleteObject(pb);
    }
  }

  SelectObject(mem, oldPen);
  DeleteObject(pen);

  BitBlt(hdc, 0, 0, w, h, mem, 0, 0, SRCCOPY);
  SelectObject(mem, oldBmp);
  DeleteObject(bmp);
  DeleteDC(mem);
  EndPaint(hwnd, &ps);
}

static LRESULT CALLBACK HintWndProc(HWND hwnd, UINT msg, WPARAM wParam,
                                    LPARAM lParam) {
  if (msg == WM_PAINT) {
    HintPaint(hwnd);
    return 0;
  }
  if (msg == WM_ERASEBKGND) return 1;
  if (msg == WM_DESTROY) {
    g_hintWnd = NULL;
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wParam, lParam);
}

// 计算提示位置并移动（鼠标右下偏移，屏幕内夹紧）
static void HintMove() {
  POINT cp;
  GetCursorPos(&cp);
  int x = cp.x + 18;
  int y = cp.y + 20;
  HMONITOR mon = MonitorFromPoint(cp, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi{};
  mi.cbSize = sizeof(mi);
  if (GetMonitorInfoW(mon, &mi)) {
    if (x + g_hintW > mi.rcWork.right) x = cp.x - g_hintW - 18;
    if (y + g_hintH > mi.rcWork.bottom) y = cp.y - g_hintH - 20;
    if (x < mi.rcWork.left) x = mi.rcWork.left;
    if (y < mi.rcWork.top) y = mi.rcWork.top;
  }
  SetWindowPos(g_hintWnd, NULL, x, y, 0, 0,
               SWP_NOACTIVATE | SWP_NOSIZE | SWP_NOZORDER);
}

// 显示提示：closing=将执行的动作；result=直接显示结果态
static void HintShow(bool closing, bool result) {
  HintEnsureFonts();

  wchar_t* L[QL_COUNT];
  AcquireSRWLockShared(&g_lock);
  memcpy(L, g_labels, sizeof(L));
  ReleaseSRWLockShared(&g_lock);

  const wchar_t* mainText = result
      ? (closing ? L[QL_HINT_CLOSED] : L[QL_HINT_OPENED])
      : (closing ? L[QL_HINT_CLOSING] : L[QL_HINT_OPENING]);
  const wchar_t* subText = L[QL_HINT_SUB];

  // 文本测量 → 尺寸自适应
  HDC sc = GetDC(NULL);
  int maxW = 0;
  HGDIOBJ of = SelectObject(sc, g_hintFontMain);
  SIZE sz{};
  if (mainText &&
      GetTextExtentPoint32W(sc, mainText, (int)wcslen(mainText), &sz)) {
    maxW = sz.cx;
  }
  SelectObject(sc, g_hintFontSub);
  if (!result && subText &&
      GetTextExtentPoint32W(sc, subText, (int)wcslen(subText), &sz)) {
    if (sz.cx > maxW) maxW = sz.cx;
  }
  SelectObject(sc, of);
  ReleaseDC(NULL, sc);

  g_hintClosing = closing;
  g_hintResult = result;
  g_hintW = maxW + kMenuPadX * 2;
  if (g_hintW < 160) g_hintW = 160;
  g_hintH = result ? 34 : 52;

  if (!g_hintClassOk) {
    WNDCLASSW wc{};
    wc.lpfnWndProc = HintWndProc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"ChronoTideQuickHint";
    RegisterClassW(&wc);
    g_hintClassOk = true;
  }
  if (!g_hintWnd || !IsWindow(g_hintWnd)) {
    g_hintWnd = CreateWindowExW(
        WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        L"ChronoTideQuickHint", L"", WS_POPUP, 0, 0, g_hintW, g_hintH, NULL,
        NULL, GetModuleHandleW(NULL), NULL);
    if (!g_hintWnd) return;
    HRGN rgn = CreateRoundRectRgn(0, 0, g_hintW + 1, g_hintH + 1,
                                  kMenuRadius, kMenuRadius);
    SetWindowRgn(g_hintWnd, rgn, TRUE);
  } else {
    SetWindowPos(g_hintWnd, NULL, 0, 0, g_hintW, g_hintH,
                 SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOZORDER);
  }

  HintMove();
  ShowWindow(g_hintWnd, SW_SHOWNOACTIVATE);
  InvalidateRect(g_hintWnd, NULL, FALSE);
}

static void HintHide() {
  if (g_hintWnd && IsWindow(g_hintWnd)) {
    ShowWindow(g_hintWnd, SW_HIDE);
  }
}

// 长按判定主循环（30ms tick）
// 松开判定以钩子投递的 kMsgMidUp 为主（GetAsyncKeyState 对被钩子
// 吞掉的按下事件可能不更新键状态，直接轮询会在首个 tick 误判为
// "已松开"导致长按永远失效）。async 轮询仅作补漏兜底：只有当它
// 曾亲眼见过"按下"之后又变回"松开"才认为是真的松开了。
static void OnHoldTimer() {
  if (!g_holdActive) return;
  ULONGLONG held = GetTickCount64() - g_holdStart;

  bool pressed = (GetAsyncKeyState(VK_MBUTTON) & 0x8000) != 0;
  if (pressed) {
    g_holdSawAsyncDown = true;
  } else if (g_holdSawAsyncDown) {
    // 异常路径：未收到 kMsgMidUp 但 async 确认已松开 → 按松开处理
    KillTimer(g_msgWnd, TID_HOLD);
    g_holdActive = false;
    if (g_holdConfirm) {
      HintHide();  // 确认中途松开：取消，不执行切换
    } else {
      AcquireSRWLockShared(&g_lock);
      bool enabled = g_enabled;
      ReleaseSRWLockShared(&g_lock);
      if (enabled) ShowActionMenu(g_holdPt.x, g_holdPt.y);
    }
    return;
  }

  AcquireSRWLockShared(&g_lock);
  bool enabled = g_enabled;
  ReleaseSRWLockShared(&g_lock);

  if (!g_holdConfirm && held >= kClickMs) {
    g_holdConfirm = true;
    HintShow(enabled, false);  // enabled=将关闭；挂起=将开启
  }

  if (g_holdConfirm) {
    // 提示跟随鼠标 + 刷新进度
    g_hintProgress =
        (int)((held - kClickMs) * 100 / (kTotalMs - kClickMs));
    if (g_hintProgress < 0) g_hintProgress = 0;
    if (g_hintProgress > 100) g_hintProgress = 100;
    HintMove();
    InvalidateRect(g_hintWnd, NULL, FALSE);

    if (held >= kTotalMs) {
      // 长按完成：切换功能开关（钩子常驻，g_enabled 仅切标志位）
      // 这是会话级切换，不持久化——Dart 侧 _qwIsEnabled() 轮询即可同步
      bool newEnabled = !enabled;
      if (!newEnabled) {
        // 挂起：还原目标窗口被修改的属性，清空跟踪
        RestoreTargetState();
        AcquireSRWLockExclusive(&g_lock);
        g_target = NULL;
        g_pidCount = 0;
        ReleaseSRWLockExclusive(&g_lock);
      }
      AcquireSRWLockExclusive(&g_lock);
      g_enabled = newEnabled;
      ReleaseSRWLockExclusive(&g_lock);

      KillTimer(g_msgWnd, TID_HOLD);
      g_holdActive = false;
      HintShow(newEnabled == false, true);  // 结果态：显示已关闭/已开启
      SetTimer(g_msgWnd, TID_HINT_HIDE, 900, NULL);
    }
  }
}

static LRESULT CALLBACK QuickWndProc(HWND hwnd, UINT msg, WPARAM wParam,
                                     LPARAM lParam) {
  if (msg == kMsgShowMenu) {
    ShowActionMenu((int)(short)LOWORD(lParam), (int)(short)HIWORD(lParam));
    return 0;
  }
  if (msg == kMsgMidDown) {
    // 中键按下：启动单击/长按判定（松开由钩子投递 kMsgMidUp 驱动）
    g_holdActive = true;
    g_holdConfirm = false;
    g_holdStart = GetTickCount64();
    g_holdPt.x = (int)(short)LOWORD(lParam);
    g_holdPt.y = (int)(short)HIWORD(lParam);
    g_holdSawAsyncDown = (GetAsyncKeyState(VK_MBUTTON) & 0x8000) != 0;
    SetTimer(hwnd, TID_HOLD, 30, NULL);
    return 0;
  }
  if (msg == kMsgMidUp) {
    // 中键松开（钩子投递）：单击(<450ms)弹菜单 / 确认中途松开=取消
    if (g_holdActive) {
      KillTimer(hwnd, TID_HOLD);
      g_holdActive = false;
      if (g_holdConfirm) {
        HintHide();  // 确认中途松开：取消，不执行切换
      } else {
        AcquireSRWLockShared(&g_lock);
        bool enabled = g_enabled;
        ReleaseSRWLockShared(&g_lock);
        // 单击：功能启用时在按下位置弹动作菜单（挂起态直通不弹）
        if (enabled) ShowActionMenu(g_holdPt.x, g_holdPt.y);
      }
    }
    return 0;
  }
  if (msg == WM_TIMER) {
    if (wParam == TID_HOLD) {
      OnHoldTimer();
      return 0;
    }
    if (wParam == TID_HINT_HIDE) {
      KillTimer(hwnd, TID_HINT_HIDE);
      HintHide();
      return 0;
    }
    return 0;
  }
  if (msg == kMsgQuit) {
    DestroyWindow(hwnd);
    return 0;
  }
  if (msg == WM_DESTROY) {
    g_msgWnd = NULL;
    PostQuitMessage(0);
    return 0;
  }
  return DefWindowProcW(hwnd, msg, wParam, lParam);
}

// ═══════════════════════════════════════════════════════════════
// 低层鼠标钩子（手势引擎核心；仅工作线程回调）
// ═══════════════════════════════════════════════════════════════

// 计算命中边缘：0=内部(移动) 1=左 2=右 3=上 4=下 5=左上 6=右上 7=左下 8=右下
static int HitEdge(const RECT& r, const POINT& pt) {
  bool left   = pt.x - r.left   < kEdgeMargin;
  bool right  = r.right  - pt.x < kEdgeMargin;
  bool top    = pt.y - r.top    < kEdgeMargin;
  bool bottom = r.bottom - pt.y < kEdgeMargin;
  if (top && left)     return 5;
  if (top && right)    return 6;
  if (bottom && left)  return 7;
  if (bottom && right) return 8;
  if (left)  return 1;
  if (right) return 2;
  if (top)   return 3;
  if (bottom) return 4;
  return 0;
}

static void ApplyDrag(HWND t, const POINT& pt) {
  int dx = pt.x - g_startPt.x;
  int dy = pt.y - g_startPt.y;
  if (!g_moved && (dx != 0 || dy != 0)) g_moved = true;

  const RECT& r = g_startRect;
  int x = r.left, y = r.top, w = r.right - r.left, h = r.bottom - r.top;

  switch (g_dragEdge) {
    case 0:  // 移动
      x = r.left + dx;
      y = r.top + dy;
      break;
    case 1:  x = r.left + dx; w = (r.right - r.left) - dx; break;  // 左
    case 2:  w = (r.right - r.left) + dx; break;                    // 右
    case 3:  y = r.top + dy; h = (r.bottom - r.top) - dy; break;   // 上
    case 4:  h = (r.bottom - r.top) + dy; break;                    // 下
    case 5:  x = r.left + dx; w = (r.right - r.left) - dx;          // 左上
             y = r.top + dy;  h = (r.bottom - r.top) - dy; break;
    case 6:  w = (r.right - r.left) + dx;                           // 右上
             y = r.top + dy;  h = (r.bottom - r.top) - dy; break;
    case 7:  x = r.left + dx; w = (r.right - r.left) - dx;          // 左下
             h = (r.bottom - r.top) + dy; break;
    case 8:  w = (r.right - r.left) + dx;                           // 右下
             h = (r.bottom - r.top) + dy; break;
  }

  // 尺寸下限保护
  if (g_dragEdge != 0) {
    if (w < 200) w = 200;
    if (h < 120) h = 120;
  }

  SetWindowPos(t, NULL, x, y, w, h, kSwpBase | SWP_NOZORDER);
}

static LRESULT CALLBACK QuickMouseProc(int nCode, WPARAM wParam,
                                       LPARAM lParam) {
  if (nCode >= 0) {
    // 菜单打开期间：菜单窗口内的输入直通由菜单自处理；
    // 菜单外的点击负责关闭菜单。注意：菜单是 WS_EX_NOACTIVATE 的
    // 后台窗口（前台是游戏），SetCapture 对后台窗口只在光标位于菜单
    // 可见区域内才生效，菜单外的事件永远不会送到菜单窗口——因此
    // "点击外部关闭"必须在钩子里做。钩子回调与菜单模态循环同属
    // 工作线程，可直接置 g_menuDone。
    if (g_menuWnd) {
      UINT mmsg = (UINT)wParam;
      if (mmsg == WM_LBUTTONDOWN || mmsg == WM_RBUTTONDOWN ||
          mmsg == WM_MBUTTONDOWN || mmsg == WM_XBUTTONDOWN) {
        MSLLHOOKSTRUCT* m = (MSLLHOOKSTRUCT*)lParam;
        RECT rc{};
        if (GetWindowRect(g_menuWnd, &rc) && !PtInRect(&rc, m->pt)) {
          g_menuDone = true;  // 菜单外按下 → 关闭菜单
          return 1;           // 消费掉这次关闭点击，避免误触游戏
        }
      }
      return CallNextHookEx(NULL, nCode, wParam, lParam);
    }

    AcquireSRWLockShared(&g_lock);
    bool enabled = g_enabled;
    HWND target = g_target;
    ReleaseSRWLockShared(&g_lock);

    if (!enabled) {
      // 挂起态：只检测"长按中键恢复"（事件直通，游戏正常使用中键）
      if (((UINT)wParam) == WM_MBUTTONDOWN && !g_dragging) {
        MSLLHOOKSTRUCT* m = (MSLLHOOKSTRUCT*)lParam;
        PostMessageW(g_msgWnd, kMsgMidDown, 0,
                     MAKELPARAM(m->pt.x, m->pt.y));
      } else if (((UINT)wParam) == WM_MBUTTONUP && g_holdActive) {
        MSLLHOOKSTRUCT* m = (MSLLHOOKSTRUCT*)lParam;
        PostMessageW(g_msgWnd, kMsgMidUp, 0, MAKELPARAM(m->pt.x, m->pt.y));
      }
      return CallNextHookEx(NULL, nCode, wParam, lParam);
    }

    if (target && IsWindow(target)) {
      MSLLHOOKSTRUCT* m = (MSLLHOOKSTRUCT*)lParam;
      bool alt = (GetAsyncKeyState(VK_MENU) & 0x8000) != 0;
      UINT msg = (UINT)wParam;
      POINT pt = m->pt;

      RECT wr{};
      bool overTarget =
          GetWindowRect(target, &wr) && PtInRect(&wr, pt) != 0;

      // ★ 中键：进入单击/长按判定（单击弹菜单 / 长按挂起功能）
      if (msg == WM_MBUTTONDOWN && overTarget && !g_dragging) {
        PostMessageW(g_msgWnd, kMsgMidDown, 0, MAKELPARAM(pt.x, pt.y));
        return 1;  // 吞掉按下，判定结果由消息窗口 timer 决定
      }
      if (msg == WM_MBUTTONUP && g_holdActive) {
        PostMessageW(g_msgWnd, kMsgMidUp, 0, MAKELPARAM(pt.x, pt.y));
        return 1;  // 与被吞的按下配对，游戏不收到孤立释放
      }

      if (!alt) {
        // Alt 松开：终止任何拖拽
        if (g_dragging) {
          g_dragging = false;
          // 已产生位移则吞掉本次释放，避免游戏误触发点击
          if (g_moved) return 1;
        }
      } else {
        switch (msg) {
          case WM_LBUTTONDOWN: {
            if (overTarget && !g_dragging) {
              // 最大化状态下不支持拖拽（还原尺寸语义复杂），放行
              WINDOWPLACEMENT wp{};
              wp.length = sizeof(wp);
              GetWindowPlacement(target, &wp);
              if (wp.showCmd == SW_SHOWMAXIMIZED) break;
              g_dragging = true;
              g_moved = false;
              g_dragEdge = HitEdge(wr, pt);
              g_startPt = pt;
              g_startRect = wr;
              return 1;  // 吞掉按下，游戏不收到 Alt+Click
            }
            break;
          }
          case WM_MOUSEMOVE: {
            if (g_dragging) {
              ApplyDrag(target, pt);
              return 1;
            }
            break;
          }
          case WM_LBUTTONUP: {
            if (g_dragging) {
              g_dragging = false;
              return 1;
            }
            break;
          }
          case WM_MOUSEWHEEL: {
            if (overTarget) {
              AcquireSRWLockShared(&g_lock);
              int alpha = g_alpha;
              ReleaseSRWLockShared(&g_lock);
              int delta = (short)HIWORD(m->mouseData);
              SetTargetOpacity(
                  alpha + (delta > 0 ? kOpacityStep : -kOpacityStep));
              return 1;
            }
            break;
          }
          default:
            break;
        }
      }
    } else if (g_dragging) {
      g_dragging = false;
    }
  }
  return CallNextHookEx(NULL, nCode, wParam, lParam);
}

// ═══════════════════════════════════════════════════════════════
// 工作线程：安装钩子 + 消息泵（低层钩子回调依赖本线程消息循环）
// ═══════════════════════════════════════════════════════════════

static DWORD WINAPI QuickWorkerThread(LPVOID) {
  // 菜单线程需要 STA（TrackPopupMenu + 剪贴板等 shell 交互惯例）
  HRESULT hrInit = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
  bool comOk = SUCCEEDED(hrInit);

  WNDCLASSW wc{};
  wc.lpfnWndProc = QuickWndProc;
  wc.hInstance = GetModuleHandleW(NULL);
  wc.lpszClassName = L"ChronoTideQuickWindow";
  RegisterClassW(&wc);
  g_msgWnd = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                             wc.lpszClassName, L"", WS_POPUP, 0, 0, 0, 0, NULL,
                             NULL, wc.hInstance, NULL);

  if (g_msgWnd) {
    g_mouseHook = SetWindowsHookExW(WH_MOUSE_LL, QuickMouseProc,
                                    GetModuleHandleW(NULL), 0);
  }

  // 通知启动方就绪（即使失败也置位，让调用方检查状态）
  SetEvent(g_readyEvent);

  if (g_msgWnd && g_mouseHook) {
    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
      TranslateMessage(&msg);
      DispatchMessageW(&msg);
    }
  }

  if (g_mouseHook) {
    UnhookWindowsHookEx(g_mouseHook);
    g_mouseHook = NULL;
  }
  if (g_msgWnd && IsWindow(g_msgWnd)) {
    DestroyWindow(g_msgWnd);
    g_msgWnd = NULL;
  }
  if (comOk) CoUninitialize();
  return 0;
}

// ═══════════════════════════════════════════════════════════════
// PID → 主窗口查找（EnumWindows，供 WindowTracker 用；任意线程可调）
// ═══════════════════════════════════════════════════════════════

struct FindCtx {
  unsigned long const* pids;
  int pidCount;
  HWND best;
  LONG_PTR bestArea;
};

static BOOL CALLBACK FindWndProc(HWND hwnd, LPARAM lp) {
  FindCtx* ctx = (FindCtx*)lp;
  if (!IsWindowVisible(hwnd)) return TRUE;

  LONG_PTR ex = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
  if (ex & WS_EX_TOOLWINDOW) return TRUE;      // 跳过工具窗口
  if (GetWindowLongPtrW(hwnd, GWL_STYLE) & WS_CHILD) return TRUE;

  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  if (pid == GetCurrentProcessId()) return TRUE;

  for (int i = 0; i < ctx->pidCount; i++) {
    if (ctx->pids[i] == (unsigned long)pid) {
      RECT r{};
      if (GetWindowRect(hwnd, &r)) {
        LONG_PTR area = (LONG_PTR)(r.right - r.left) * (r.bottom - r.top);
        // 选面积最大的可见窗口作为游戏主窗口
        if (area > ctx->bestArea) {
          ctx->bestArea = area;
          ctx->best = hwnd;
        }
      }
      break;
    }
  }
  return TRUE;
}

// ═══════════════════════════════════════════════════════════════
// 导出接口（Dart FFI 调用；均线程安全）
// ═══════════════════════════════════════════════════════════════

extern "C" {

// 返回：1=成功 -1=消息窗口创建失败 -2=钩子安装失败 0=无操作
// 注意：钩子常驻！enabled=0 时只切 g_enabled 标志，不销毁工作线程，
// 让长按中键在任何状态下（开启/挂起）都能切换功能。
__declspec(dllexport) int qw_enable(int enabled) {
  bool wantEnabled = (enabled != 0);

  if (g_thread) {
    // 工作线程已存在：仅切 g_enabled
    AcquireSRWLockExclusive(&g_lock);
    g_enabled = wantEnabled;
    ReleaseSRWLockExclusive(&g_lock);
    return 1;
  }

  // 首次启用：创建工作线程
  if (!g_readyEvent) {
    g_readyEvent = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!g_readyEvent) return -1;
  } else {
    ResetEvent(g_readyEvent);
  }

  g_thread = CreateThread(NULL, 0, QuickWorkerThread, NULL, 0, NULL);
  if (!g_thread) return -1;

  // 等工作线程就绪（最多 3 秒）
  WaitForSingleObject(g_readyEvent, 3000);
  if (!g_mouseHook || !g_msgWnd) {
    // 启动失败：等待线程退出后清理
    WaitForSingleObject(g_thread, 3000);
    CloseHandle(g_thread);
    g_thread = NULL;
    return -2;
  }

  AcquireSRWLockExclusive(&g_lock);
  g_enabled = wantEnabled;
  ReleaseSRWLockExclusive(&g_lock);
  return 1;
}

__declspec(dllexport) int qw_is_enabled() {
  AcquireSRWLockShared(&g_lock);
  bool e = g_enabled;
  ReleaseSRWLockShared(&g_lock);
  return e ? 1 : 0;
}

// labels 为指向 wchar_t* 的指针数组（count ≤ 12），原生侧自行复制
__declspec(dllexport) void qw_set_labels(const wchar_t* const* labels,
                                         int count) {
  if (count < 0) return;
  if (count > QL_COUNT) count = QL_COUNT;
  AcquireSRWLockExclusive(&g_lock);
  for (int i = 0; i < count; i++) {
    if (g_labels[i]) free(g_labels[i]);
    g_labels[i] = _wcsdup(labels[i] ? labels[i] : L"");
  }
  ReleaseSRWLockExclusive(&g_lock);
}

// 菜单/提示窗口主题：dark=1 暗色调色板，dark=0 亮色调色板
// （Dart 侧跟随应用主题切换，亮色模式为浅底深字保证可读性）
__declspec(dllexport) void qw_set_theme(int dark) {
  AcquireSRWLockExclusive(&g_lock);
  g_palette = dark ? kPaletteDark : kPaletteLight;
  ReleaseSRWLockExclusive(&g_lock);
}

__declspec(dllexport) void qw_set_target(void* hwnd) {
  HWND h = (HWND)hwnd;
  AcquireSRWLockExclusive(&g_lock);
  HWND old = g_target;
  if (old && old != h) {
    // 切换目标：还原旧目标透明度
    ReleaseSRWLockExclusive(&g_lock);
    if (old && IsWindow(old)) {
      AcquireSRWLockExclusive(&g_lock);
      int alpha = g_alpha;
      bool byUs = g_layeredByUs;
      ReleaseSRWLockExclusive(&g_lock);
      if (alpha != 255 || byUs) {
        SetTargetOpacity(255);
      }
    }
    AcquireSRWLockExclusive(&g_lock);
  }
  g_target = h;
  g_alpha = 255;
  g_layeredByUs = false;
  g_muted = 0;
  ReleaseSRWLockExclusive(&g_lock);
}

__declspec(dllexport) void* qw_get_target() {
  AcquireSRWLockShared(&g_lock);
  HWND t = g_target;
  ReleaseSRWLockShared(&g_lock);
  return (void*)t;
}

__declspec(dllexport) int qw_set_pids(const unsigned long* pids, int count) {
  if (count < 0) count = 0;
  if (count > 64) count = 64;
  AcquireSRWLockExclusive(&g_lock);
  for (int i = 0; i < count; i++) g_pids[i] = pids[i];
  g_pidCount = count;
  g_muted = 0;
  ReleaseSRWLockExclusive(&g_lock);
  return count;
}

// 在 pids 集合中查找游戏主窗口；找不到返回 NULL
__declspec(dllexport) void* qw_find_window() {
  PidSnapshot snap = SnapshotLocked();
  if (snap.count == 0) return NULL;
  FindCtx ctx{};
  ctx.pids = snap.pids;
  ctx.pidCount = snap.count;
  EnumWindows(FindWndProc, (LPARAM)&ctx);
  return (void*)ctx.best;
}

// 窗口属性查询
__declspec(dllexport) int qw_is_topmost() { return IsTargetTopmost() ? 1 : 0; }
__declspec(dllexport) int qw_get_opacity() {
  AcquireSRWLockShared(&g_lock);
  int a = g_alpha;
  ReleaseSRWLockShared(&g_lock);
  return a;
}
__declspec(dllexport) int qw_get_muted() {
  AcquireSRWLockShared(&g_lock);
  int m = g_muted;
  ReleaseSRWLockShared(&g_lock);
  return m;
}

// Dart 侧动作分发（未来 UI 按钮直接调用；与菜单动作同实现）
__declspec(dllexport) int qw_perform(int action) {
  switch (action) {
    case QA_TOPMOST_TOGGLE: return ToggleTopmost();
    case QA_MINIMIZE: {
      AcquireSRWLockShared(&g_lock);
      HWND t = g_target;
      ReleaseSRWLockShared(&g_lock);
      if (t && IsWindow(t)) ShowWindow(t, SW_MINIMIZE);
      return 0;
    }
    case QA_MAXIMIZE_TOGGLE: MaximizeToggle(); return 0;
    case QA_CENTER:          CenterWindow(); return 0;
    case QA_CLOSE: {
      AcquireSRWLockShared(&g_lock);
      HWND t = g_target;
      ReleaseSRWLockShared(&g_lock);
      if (t && IsWindow(t)) PostMessageW(t, WM_CLOSE, 0, 0);
      return 0;
    }
    case QA_OPACITY_UP: {
      AcquireSRWLockShared(&g_lock);
      int a = g_alpha;
      ReleaseSRWLockShared(&g_lock);
      return SetTargetOpacity(a + kOpacityStep);
    }
    case QA_OPACITY_DOWN: {
      AcquireSRWLockShared(&g_lock);
      int a = g_alpha;
      ReleaseSRWLockShared(&g_lock);
      return SetTargetOpacity(a - kOpacityStep);
    }
    case QA_OPACITY_RESET: return SetTargetOpacity(255);
    case QA_MUTE_TOGGLE: {
      QuerySessionsMute();
      AcquireSRWLockShared(&g_lock);
      int m = g_muted;
      ReleaseSRWLockShared(&g_lock);
      int newMuted = m ? 0 : 1;
      AcquireSRWLockExclusive(&g_lock);
      g_muted = newMuted;
      ReleaseSRWLockExclusive(&g_lock);
      return SetSessionsMuteLockedState(newMuted != 0, NULL) ? newMuted : -1;
    }
    default: return -1;
  }
}

}  // extern "C"
