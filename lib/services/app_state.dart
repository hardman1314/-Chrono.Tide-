/// 全局应用状态标志
///
/// 用于在 main.dart、TrayService、CustomTitleBar 之间共享窗口状态

/// 静默模式：true 表示窗口不应可见（快捷启动 / 开机自启）
/// 当用户通过托盘主动打开窗口时，此标志被设为 false
bool isSilentMode = false;

/// 用户是否主动请求显示窗口（通过托盘菜单等）
/// 用于区分"用户主动显示"和"Windows 焦点窃取"
bool userRequestedWindow = false;
