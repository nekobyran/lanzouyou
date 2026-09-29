#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  constexpr unsigned int kDefaultWindowWidth = 1301;
  constexpr unsigned int kDefaultWindowHeight = 855;
  RECT work_area{};
  const bool has_work_area =
      ::SystemParametersInfo(SPI_GETWORKAREA, 0, &work_area, 0) != FALSE;
  const unsigned int system_dpi = ::GetDpiForSystem();
  const double scale_factor = system_dpi == 0 ? 1.0 : system_dpi / 96.0;
  const unsigned int available_width = has_work_area
                                           ? static_cast<unsigned int>(
                                                 (work_area.right - work_area.left) /
                                                 scale_factor)
                                           : kDefaultWindowWidth;
  const unsigned int available_height = has_work_area
                                            ? static_cast<unsigned int>(
                                                  (work_area.bottom - work_area.top) /
                                                  scale_factor)
                                            : kDefaultWindowHeight;
  const unsigned int width =
      kDefaultWindowWidth < available_width ? kDefaultWindowWidth
                                            : available_width;
  const unsigned int height =
      kDefaultWindowHeight < available_height ? kDefaultWindowHeight
                                              : available_height;

  FlutterWindow window(project);
  // Keep aligned with AppUiTokens: centered and clamped 1301x855dp desktop default.
  Win32Window::Point origin((available_width - width) / 2,
                            (available_height - height) / 2);
  Win32Window::Size size(width, height);
  if (!window.Create(L"LanzouYOU", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}

