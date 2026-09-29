#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"
#include "windows_shell_contract.h"

#ifndef WM_NCUAHDRAWCAPTION
#define WM_NCUAHDRAWCAPTION 0x00AE
#endif

#ifndef WM_NCUAHDRAWFRAME
#define WM_NCUAHDRAWFRAME 0x00AF
#endif

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() { Destroy(); }

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) return false;

  RECT frame = GetClientArea();
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }

    RegisterPlugins(flutter_controller_->engine());
  open_with_bridge_ = std::make_unique<OpenWithBridge>(
      flutter_controller_->engine()->messenger());
  caption_visual_channel_ =

      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          windows_shell::kCaptionVisualChannel,
          &flutter::StandardMethodCodec::GetInstance());

  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  flutter_controller_->engine()->SetNextFrameCallback([this]() { Show(); });
  flutter_controller_->ForceRedraw();
  return true;
}

void FlutterWindow::OnDestroy() {
  caption_visual_channel_ = nullptr;
  open_with_bridge_ = nullptr;
  flutter_controller_ = nullptr;

  Win32Window::OnDestroy();
}

void FlutterWindow::OnCaptionButtonVisualState(int hovered_button,
                                               int pressed_button) {
  if (!caption_visual_channel_) return;
  auto state = std::make_unique<flutter::EncodableValue>(
      flutter::EncodableMap{
          {flutter::EncodableValue("hovered"),
           flutter::EncodableValue(hovered_button)},
          {flutter::EncodableValue("pressed"),
           flutter::EncodableValue(pressed_button)},
          {flutter::EncodableValue("maximized"),
           flutter::EncodableValue(IsZoomed(GetHandle()) != FALSE)},
      });
  caption_visual_channel_->InvokeMethod("update", std::move(state));
}

LRESULT FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  switch (message) {
    case WM_NCCALCSIZE:
    case WM_NCACTIVATE:
    case WM_NCPAINT:
    case WM_NCUAHDRAWCAPTION:
    case WM_NCUAHDRAWFRAME:
    case WM_GETMINMAXINFO:
    case WM_NCHITTEST:
    case WM_NCLBUTTONDOWN:
    case WM_NCLBUTTONUP:
    case WM_NCLBUTTONDBLCLK:
    case WM_NCRBUTTONUP:
    case WM_NCMOUSEMOVE:
    case WM_NCMOUSELEAVE:
    case WM_NCMOUSEHOVER:
      return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  }

  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) return *result;
  }

  if (message == WM_FONTCHANGE && flutter_controller_) {
    flutter_controller_->engine()->ReloadSystemFonts();
  }
  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
