#include "win32_window.h"

#include <dwmapi.h>
#include <flutter_windows.h>
#include <windowsx.h>

#include "resource.h"
#include "windows_shell_contract.h"

namespace {

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr const wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr const wchar_t kChildWindowProperty[] = L"FlutterWin32Window";
constexpr const wchar_t kGetPreferredBrightnessRegKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize";
constexpr const wchar_t kGetPreferredBrightnessRegValue[] = L"AppsUseLightTheme";

static int g_active_window_count = 0;
using EnableNonClientDpiScaling = BOOL __stdcall(HWND hwnd);

int Scale(int source, double scale_factor) {
  return static_cast<int>(source * scale_factor);
}

int CaptionButtonIdFromHit(WPARAM hit) {
  switch (hit) {
    case HTMINBUTTON:
      return 1;
    case HTMAXBUTTON:
      return 2;
    case HTCLOSE:
      return 3;
    default:
      return 0;
  }
}

LRESULT HitTestResizeBorder(HWND hwnd, LPARAM lparam) {
  if (!hwnd || IsZoomed(hwnd)) {
    return HTCLIENT;
  }

  POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
  RECT rect{};
  if (!GetWindowRect(hwnd, &rect)) {
    return HTCLIENT;
  }

  const double scale_factor = FlutterDesktopGetDpiForHWND(hwnd) / 96.0;
  const int border = Scale(windows_shell::kResizeBorderLogicalWidth, scale_factor);
  const bool left = point.x >= rect.left && point.x < rect.left + border;
  const bool right = point.x < rect.right && point.x >= rect.right - border;
  const bool top = point.y >= rect.top && point.y < rect.top + border;
  const bool bottom = point.y < rect.bottom && point.y >= rect.bottom - border;

  if (top && left) return HTTOPLEFT;
  if (top && right) return HTTOPRIGHT;
  if (bottom && left) return HTBOTTOMLEFT;
  if (bottom && right) return HTBOTTOMRIGHT;
  if (left) return HTLEFT;
  if (right) return HTRIGHT;
  if (top) return HTTOP;
  if (bottom) return HTBOTTOM;
  return HTCLIENT;
}

LRESULT HitTestWindowFrame(HWND hwnd, LPARAM lparam) {
  const LRESULT resize_hit = HitTestResizeBorder(hwnd, lparam);
  if (resize_hit != HTCLIENT) {
    return resize_hit;
  }

  POINT point = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
  ScreenToClient(hwnd, &point);
  const double scale_factor = FlutterDesktopGetDpiForHWND(hwnd) / 96.0;
  const int title_bar_height = Scale(windows_shell::kTitleBarLogicalHeight, scale_factor);
  if (point.y < 0 || point.y >= title_bar_height || point.x < 0) {
    return HTCLIENT;
  }

  RECT client_rect{};
  if (!GetClientRect(hwnd, &client_rect)) {
    return HTCLIENT;
  }
  const int button_width = Scale(windows_shell::kCaptionButtonLogicalWidth, scale_factor);
  const int caption_left =
      client_rect.right - button_width * windows_shell::kCaptionButtonCount;
  if (point.x >= caption_left && point.x < client_rect.right) {
    const int button_index = (point.x - caption_left) / button_width;
    if (button_index == 0) return HTMINBUTTON;
    if (button_index == 1) return HTMAXBUTTON;
    return HTCLOSE;
  }

  return HTCAPTION;
}

void ExtendTitleBarIntoClientArea(HWND hwnd) {
  const double scale_factor = FlutterDesktopGetDpiForHWND(hwnd) / 96.0;
  MARGINS margins = {0, 0, Scale(windows_shell::kTitleBarLogicalHeight, scale_factor), 0};
  DwmExtendFrameIntoClientArea(hwnd, &margins);
  SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
               SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_NOMOVE | SWP_NOSIZE |
                   SWP_FRAMECHANGED);
}

void ShowSystemMenu(HWND hwnd, LPARAM lparam) {
  HMENU menu = GetSystemMenu(hwnd, FALSE);
  if (!menu) return;
  const UINT command = TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, GET_X_LPARAM(lparam),
      GET_Y_LPARAM(lparam), 0, hwnd, nullptr);
  if (command != 0) {
    PostMessage(hwnd, WM_SYSCOMMAND, command, 0);
  }
}

void EnableFullDpiSupportIfAvailable(HWND hwnd) {
  HMODULE user32_module = LoadLibraryA("User32.dll");
  if (!user32_module) return;
  auto enable_non_client_dpi_scaling =
      reinterpret_cast<EnableNonClientDpiScaling*>(
          GetProcAddress(user32_module, "EnableNonClientDpiScaling"));
  if (enable_non_client_dpi_scaling) {
    enable_non_client_dpi_scaling(hwnd);
  }
  FreeLibrary(user32_module);
}

}  // namespace

class WindowClassRegistrar {
 public:
  static WindowClassRegistrar* GetInstance() {
    if (!instance_) instance_ = new WindowClassRegistrar();
    return instance_;
  }

  const wchar_t* GetWindowClass() {
    if (!class_registered_) {
      WNDCLASS window_class{};
      window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
      window_class.lpszClassName = kWindowClassName;
      window_class.style = CS_HREDRAW | CS_VREDRAW;
      window_class.hInstance = GetModuleHandle(nullptr);
      window_class.hIcon =
          LoadIcon(window_class.hInstance, MAKEINTRESOURCE(IDI_APP_ICON));
      window_class.hbrBackground = nullptr;
      window_class.lpfnWndProc = Win32Window::WndProc;
      RegisterClass(&window_class);
      class_registered_ = true;
    }
    return kWindowClassName;
  }

  void UnregisterWindowClass() {
    UnregisterClass(kWindowClassName, nullptr);
    class_registered_ = false;
  }

 private:
  WindowClassRegistrar() = default;
  static WindowClassRegistrar* instance_;
  bool class_registered_ = false;
};

WindowClassRegistrar* WindowClassRegistrar::instance_ = nullptr;

Win32Window::Win32Window() { ++g_active_window_count; }

Win32Window::~Win32Window() {
  --g_active_window_count;
  Destroy();
}

bool Win32Window::Create(const std::wstring& title, const Point& origin,
                         const Size& size) {
  Destroy();
  destroy_notified_ = false;

  const POINT target_point = {static_cast<LONG>(origin.x),
                              static_cast<LONG>(origin.y)};
  HMONITOR monitor = MonitorFromPoint(target_point, MONITOR_DEFAULTTONEAREST);
  const double scale_factor = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
  HWND window = CreateWindow(
      WindowClassRegistrar::GetInstance()->GetWindowClass(), title.c_str(),
      WS_OVERLAPPEDWINDOW, Scale(origin.x, scale_factor),
      Scale(origin.y, scale_factor), Scale(size.width, scale_factor),
      Scale(size.height, scale_factor), nullptr, nullptr,
      GetModuleHandle(nullptr), this);
  if (!window) {
    Destroy();
    return false;
  }

  UpdateTheme(window);
  ExtendTitleBarIntoClientArea(window);
  if (!OnCreate()) {
    Destroy();
    return false;
  }
  return true;
}

bool Win32Window::Show() { return ShowWindow(window_handle_, SW_SHOWNORMAL); }

LRESULT CALLBACK Win32Window::WndProc(HWND const window, UINT const message,
                                      WPARAM const wparam,
                                      LPARAM const lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto create_struct = reinterpret_cast<CREATESTRUCT*>(lparam);
    auto that = static_cast<Win32Window*>(create_struct->lpCreateParams);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(that));
    EnableFullDpiSupportIfAvailable(window);
    that->window_handle_ = window;
  } else if (Win32Window* that = GetThisFromHandle(window)) {
    return that->MessageHandler(window, message, wparam, lparam);
  }
  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT CALLBACK Win32Window::ChildWndProc(HWND const window,
                                           UINT const message,
                                           WPARAM const wparam,
                                           LPARAM const lparam) noexcept {
  auto that = reinterpret_cast<Win32Window*>(
      GetProp(window, kChildWindowProperty));
  if (that) {
    return that->ChildMessageHandler(window, message, wparam, lparam);
  }
  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT Win32Window::ChildMessageHandler(HWND window, UINT const message,
                                         WPARAM const wparam,
                                         LPARAM const lparam) noexcept {
  if (window_handle_ && message == WM_NCHITTEST &&
      HitTestWindowFrame(window_handle_, lparam) != HTCLIENT) {
    return HTTRANSPARENT;
  }
  return original_child_wndproc_
             ? CallWindowProc(original_child_wndproc_, window, message, wparam,
                              lparam)
             : DefWindowProc(window, message, wparam, lparam);
}

LRESULT Win32Window::MessageHandler(HWND hwnd, UINT const message,
                                    WPARAM const wparam,
                                    LPARAM const lparam) noexcept {
  if (message == WM_NCHITTEST) {
    return HitTestWindowFrame(hwnd, lparam);
  }

  const int caption_button = CaptionButtonIdFromHit(wparam);
  switch (message) {
    case WM_NCMOUSEMOVE:
    case WM_NCMOUSEHOVER: {
      TRACKMOUSEEVENT tracking{sizeof(TRACKMOUSEEVENT), TME_NONCLIENT | TME_LEAVE,
                               hwnd, HOVER_DEFAULT};
      TrackMouseEvent(&tracking);
      SetCaptionButtonVisualState(caption_button, caption_pressed_button_);
      break;
    }
    case WM_NCLBUTTONDOWN:
      if (caption_button != 0) {
        SetCaptionButtonVisualState(caption_button, caption_button);
      }
      break;
    case WM_NCLBUTTONUP:
      SetCaptionButtonVisualState(caption_button, 0);
      break;
    case WM_NCMOUSELEAVE:
      SetCaptionButtonVisualState(0, 0);
      break;
    case WM_NCRBUTTONUP:
      if (wparam == HTCAPTION) {
        ShowSystemMenu(hwnd, lparam);
        return 0;
      }
      break;
  }

  LRESULT dwm_result = 0;
  if (DwmDefWindowProc(hwnd, message, wparam, lparam, &dwm_result)) {
    return dwm_result;
  }

  switch (message) {
    case WM_NCCALCSIZE:
      return 0;
    case WM_ERASEBKGND:
      return 1;
    case WM_GETMINMAXINFO: {
      auto info = reinterpret_cast<MINMAXINFO*>(lparam);
      const double scale_factor = FlutterDesktopGetDpiForHWND(hwnd) / 96.0;
      info->ptMinTrackSize.x = Scale(windows_shell::kMinimumWindowLogicalWidth, scale_factor);
      info->ptMinTrackSize.y = Scale(windows_shell::kMinimumWindowLogicalHeight, scale_factor);

      MONITORINFO monitor_info{sizeof(MONITORINFO)};
      HMONITOR monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      if (GetMonitorInfo(monitor, &monitor_info)) {
        info->ptMaxPosition.x =
            monitor_info.rcWork.left - monitor_info.rcMonitor.left;
        info->ptMaxPosition.y =
            monitor_info.rcWork.top - monitor_info.rcMonitor.top;
        info->ptMaxSize.x = monitor_info.rcWork.right - monitor_info.rcWork.left;
        info->ptMaxSize.y = monitor_info.rcWork.bottom - monitor_info.rcWork.top;
      }
      return 0;
    }
    case WM_DESTROY:
      DetachChildContent();
      window_handle_ = nullptr;
      NotifyDestroyedOnce();
      if (quit_on_close_) PostQuitMessage(0);
      return 0;
    case WM_DPICHANGED: {
      auto rect = reinterpret_cast<RECT*>(lparam);
      SetWindowPos(hwnd, nullptr, rect->left, rect->top,
                   rect->right - rect->left, rect->bottom - rect->top,
                   SWP_NOZORDER | SWP_NOACTIVATE);
      ExtendTitleBarIntoClientArea(hwnd);
      return 0;
    }
    case WM_SIZE: {
      const RECT rect = GetClientArea();
      if (child_content_) {
        MoveWindow(child_content_, rect.left, rect.top, rect.right - rect.left,
                   rect.bottom - rect.top, TRUE);
      }
      windows_shell::UpdateRoundedCornerPreference(hwnd);
      SetCaptionButtonVisualState(caption_hovered_button_,
                                  caption_pressed_button_, true);
      return 0;
    }
    case WM_ACTIVATE:
      if (child_content_) SetFocus(child_content_);
      return 0;
    case WM_DWMCOLORIZATIONCOLORCHANGED:
      UpdateTheme(hwnd);
      ExtendTitleBarIntoClientArea(hwnd);
      return 0;
    case WM_DWMCOMPOSITIONCHANGED:
      ExtendTitleBarIntoClientArea(hwnd);
      return 0;
  }

  return DefWindowProc(hwnd, message, wparam, lparam);
}

void Win32Window::Destroy() {
  DetachChildContent();
  const HWND window = window_handle_;
  if (window && IsWindow(window)) DestroyWindow(window);
  window_handle_ = nullptr;
  NotifyDestroyedOnce();
  if (g_active_window_count == 0) {
    WindowClassRegistrar::GetInstance()->UnregisterWindowClass();
  }
}

void Win32Window::DetachChildContent() {
  if (child_content_ && original_child_wndproc_ && IsWindow(child_content_)) {
    SetWindowLongPtr(child_content_, GWLP_WNDPROC,
                     reinterpret_cast<LONG_PTR>(original_child_wndproc_));
    RemoveProp(child_content_, kChildWindowProperty);
  }
  original_child_wndproc_ = nullptr;
  child_content_ = nullptr;
}

void Win32Window::NotifyDestroyedOnce() {
  if (destroy_notified_) return;
  destroy_notified_ = true;
  OnDestroy();
}

Win32Window* Win32Window::GetThisFromHandle(HWND const window) noexcept {
  return reinterpret_cast<Win32Window*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
}

void Win32Window::SetChildContent(HWND content) {
  DetachChildContent();
  child_content_ = content;
  SetParent(content, window_handle_);
  SetProp(content, kChildWindowProperty, this);
  original_child_wndproc_ = reinterpret_cast<WNDPROC>(
      SetWindowLongPtr(content, GWLP_WNDPROC,
                       reinterpret_cast<LONG_PTR>(Win32Window::ChildWndProc)));
  const RECT frame = GetClientArea();
  MoveWindow(content, frame.left, frame.top, frame.right - frame.left,
             frame.bottom - frame.top, TRUE);
  SetFocus(child_content_);
}

RECT Win32Window::GetClientArea() {
  RECT frame{};
  GetClientRect(window_handle_, &frame);
  return frame;
}

HWND Win32Window::GetHandle() { return window_handle_; }

void Win32Window::SetQuitOnClose(bool quit_on_close) {
  quit_on_close_ = quit_on_close;
}

bool Win32Window::OnCreate() { return true; }

void Win32Window::OnDestroy() {}

void Win32Window::OnCaptionButtonVisualState(int hovered_button,
                                             int pressed_button) {}

void Win32Window::SetCaptionButtonVisualState(int hovered_button,
                                              int pressed_button, bool force) {
  if (!force && caption_hovered_button_ == hovered_button &&
      caption_pressed_button_ == pressed_button) {
    return;
  }
  caption_hovered_button_ = hovered_button;
  caption_pressed_button_ = pressed_button;
  OnCaptionButtonVisualState(hovered_button, pressed_button);
}

void Win32Window::UpdateTheme(HWND const window) {
  windows_shell::UpdateRoundedCornerPreference(window);
  DWORD light_mode = 1;
  DWORD light_mode_size = sizeof(light_mode);
  if (RegGetValue(HKEY_CURRENT_USER, kGetPreferredBrightnessRegKey,
                  kGetPreferredBrightnessRegValue, RRF_RT_REG_DWORD, nullptr,
                  &light_mode, &light_mode_size) == ERROR_SUCCESS) {
    BOOL enable_dark_mode = light_mode == 0;
    DwmSetWindowAttribute(window, DWMWA_USE_IMMERSIVE_DARK_MODE,
                          &enable_dark_mode, sizeof(enable_dark_mode));
  }
}
