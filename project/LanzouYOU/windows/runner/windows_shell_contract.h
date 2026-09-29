#pragma once

#include <dwmapi.h>
#include <windows.h>

#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
#define DWMWA_WINDOW_CORNER_PREFERENCE 33
#endif

namespace windows_shell {

// Keep these logical-pixel constants aligned with AppUiTokens in Dart.
inline constexpr int kMinimumWindowLogicalWidth = 720;
inline constexpr int kMinimumWindowLogicalHeight = 560;
inline constexpr int kResizeBorderLogicalWidth = 8;
inline constexpr int kTitleBarLogicalHeight = 32;
inline constexpr int kCaptionButtonLogicalWidth = 46;
inline constexpr int kCaptionButtonCount = 3;
inline constexpr char kCaptionVisualChannel[] = "app/windows_caption_visuals";

enum DwmWindowCornerPreference {
  kDwmWindowCornerPreferenceDoNotRound = 1,
  kDwmWindowCornerPreferenceRound = 2,
};

inline void UpdateRoundedCornerPreference(HWND hwnd) {
  const DwmWindowCornerPreference preference =
      IsZoomed(hwnd) ? kDwmWindowCornerPreferenceDoNotRound
                     : kDwmWindowCornerPreferenceRound;
  DwmSetWindowAttribute(hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &preference,
                        sizeof(preference));
}

}  // namespace windows_shell
