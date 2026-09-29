#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "open_with_bridge.h"
#include "win32_window.h"


class FlutterWindow : public Win32Window {
 public:
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  bool OnCreate() override;
  void OnDestroy() override;
  void OnCaptionButtonVisualState(int hovered_button,
                                  int pressed_button) override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  flutter::DartProject project_;
    std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<OpenWithBridge> open_with_bridge_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      caption_visual_channel_;

};

#endif  // RUNNER_FLUTTER_WINDOW_H_
