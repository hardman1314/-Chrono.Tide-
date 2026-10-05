#include "flutter_window.h"

#include <algorithm>
#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // ★ 2026-10-03 静默自启（--silent）：首帧回调里不要无脑 Show()。
  // 模板默认在此 Show()，但 Dart 侧在 runApp 之前就已经 hide() 过
  // （lib/main.dart 的 waitUntilReadyToShow 回调，静默分支），
  // Show() 晚于 hide() 执行 → 窗口被重新掀到桌面，真机表现为
  // 「开机自启时窗口停在桌面，鼠标点一下才退回托盘」。
  // window_manager README「Since flutter 3.7 new windows project」一节明确
  // 要求删除此处的 Show()；本仓 win32_window.cpp 的 CreateWindow 早已不带
  // WS_VISIBLE，故这里是唯一会显示窗口的地方。
  // 参数写法与 lib/main.dart 的 _parseSilentArg（--silent / -s）保持一致，
  // 两处改动必须同步。
  const std::vector<std::string> startup_args = GetCommandLineArguments();
  const bool silent_start =
      std::find(startup_args.begin(), startup_args.end(), "--silent") !=
          startup_args.end() ||
      std::find(startup_args.begin(), startup_args.end(), "-s") !=
          startup_args.end();

  flutter_controller_->engine()->SetNextFrameCallback([&, silent_start]() {
    if (!silent_start) {
      this->Show();
    }
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
