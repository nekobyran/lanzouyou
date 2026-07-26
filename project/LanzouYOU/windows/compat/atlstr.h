#pragma once

// flutter_secure_storage_windows only needs ATL's narrow/wide conversion
// helpers. Keep those two tiny helpers in-tree so the Windows application can
// be built with the standard Desktop C++ workload without the optional ATL
// component.

#include <windows.h>

#include <string>

namespace lanzouyou_windows_compat {

inline std::wstring narrow_to_wide(const char* value) {
  if (value == nullptr || *value == '\0') {
    return {};
  }

  UINT code_page = CP_UTF8;
  DWORD flags = MB_ERR_INVALID_CHARS;
  int size = MultiByteToWideChar(code_page, flags, value, -1, nullptr, 0);
  if (size == 0) {
    code_page = CP_ACP;
    flags = 0;
    size = MultiByteToWideChar(code_page, flags, value, -1, nullptr, 0);
  }
  if (size <= 1) {
    return {};
  }

  std::wstring result(static_cast<size_t>(size), L'\0');
  MultiByteToWideChar(code_page, flags, value, -1, result.data(), size);
  result.resize(static_cast<size_t>(size - 1));
  return result;
}

inline std::string wide_to_narrow(const wchar_t* value) {
  if (value == nullptr || *value == L'\0') {
    return {};
  }

  const int size = WideCharToMultiByte(
      CP_UTF8, 0, value, -1, nullptr, 0, nullptr, nullptr);
  if (size <= 1) {
    return {};
  }

  std::string result(static_cast<size_t>(size), '\0');
  WideCharToMultiByte(
      CP_UTF8, 0, value, -1, result.data(), size, nullptr, nullptr);
  result.resize(static_cast<size_t>(size - 1));
  return result;
}

}  // namespace lanzouyou_windows_compat

class CA2W {
 private:
  std::wstring storage_;

 public:
  explicit CA2W(const char* value)
      : storage_(lanzouyou_windows_compat::narrow_to_wide(value)),
        m_psz(storage_.data()) {}

  CA2W(const CA2W&) = delete;
  CA2W& operator=(const CA2W&) = delete;

  wchar_t* m_psz;
};

class CW2A {
 private:
  std::string storage_;

 public:
  explicit CW2A(const wchar_t* value)
      : storage_(lanzouyou_windows_compat::wide_to_narrow(value)),
        m_psz(storage_.data()) {}

  CW2A(const CW2A&) = delete;
  CW2A& operator=(const CW2A&) = delete;

  operator const char*() const { return m_psz; }
  operator std::string() const { return storage_; }

  char* m_psz;
};
