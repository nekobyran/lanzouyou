#ifndef RUNNER_WIN32_WINDOW_H_
#define RUNNER_WIN32_WINDOW_H_

#include <windows.h>

#include <string>

// High-DPI Win32 host with a Flutter-painted title bar and native window
// semantics. Resize borders, caption buttons, Snap, the system menu and
// double-click maximize remain owned by Windows.
class Win32Window {
 public:
  struct Point {
    unsigned int x;
    unsigned int y;
    Point(unsigned int x, unsigned int y) : x(x), y(y) {}
  };

  struct Size {
    unsigned int width;
    unsigned int height;
    Size(unsigned int width, unsigned int height)
        : width(width), height(height) {}
  };

  Win32Window();
  virtual ~Win32Window();

  bool Create(const std::wstring& title, const Point& origin, const Size& size);
  bool Show();
  void Destroy();
  void SetChildContent(HWND content);
  HWND GetHandle();
  void SetQuitOnClose(bool quit_on_close);
  RECT GetClientArea();

 protected:
  virtual LRESULT MessageHandler(HWND window, UINT const message,
                                 WPARAM const wparam,
                                 LPARAM const lparam) noexcept;
  virtual bool OnCreate();
  virtual void OnDestroy();
  virtual void OnCaptionButtonVisualState(int hovered_button,
                                          int pressed_button);

 private:
  friend class WindowClassRegistrar;

  static LRESULT CALLBACK WndProc(HWND const window, UINT const message,
                                  WPARAM const wparam,
                                  LPARAM const lparam) noexcept;
  static LRESULT CALLBACK ChildWndProc(HWND const window, UINT const message,
                                       WPARAM const wparam,
                                       LPARAM const lparam) noexcept;
  LRESULT ChildMessageHandler(HWND window, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept;

  static Win32Window* GetThisFromHandle(HWND const window) noexcept;
  static void UpdateTheme(HWND const window);

  void DetachChildContent();
  void NotifyDestroyedOnce();
  void SetCaptionButtonVisualState(int hovered_button, int pressed_button,
                                   bool force = false);

  bool quit_on_close_ = false;
  bool destroy_notified_ = true;
  int caption_hovered_button_ = 0;
  int caption_pressed_button_ = 0;
  HWND window_handle_ = nullptr;
  HWND child_content_ = nullptr;
  WNDPROC original_child_wndproc_ = nullptr;
};

#endif  // RUNNER_WIN32_WINDOW_H_
