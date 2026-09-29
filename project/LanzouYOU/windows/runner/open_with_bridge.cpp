#include "open_with_bridge.h"

#include <flutter/standard_method_codec.h>
#include <shlobj_core.h>
#include <shobjidl_core.h>
#include <windows.h>

#include <filesystem>
#include <set>
#include <stdexcept>
#include <string>

#include "utils.h"

namespace {

constexpr char kChannelName[] = "app.standard/open_with";

std::wstring Utf16FromUtf8(const std::string& value) {
  if (value.empty()) return std::wstring();
  const int length = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
      nullptr, 0);
  if (length <= 0) {
    throw std::runtime_error("Invalid UTF-8 value");
  }
  std::wstring result(static_cast<size_t>(length), L'\0');
  const int converted = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(), static_cast<int>(value.size()),
      result.data(), length);
  if (converted != length) {
    throw std::runtime_error("UTF-8 to UTF-16 conversion failed");
  }
  return result;
}

const std::string& RequiredStringArgument(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    const char* key) {
  const auto* arguments =
      std::get_if<flutter::EncodableMap>(call.arguments());
  if (arguments == nullptr) {
    throw std::invalid_argument("Method arguments must be a map");
  }
  const auto iterator = arguments->find(flutter::EncodableValue(key));
  if (iterator == arguments->end()) {
    throw std::invalid_argument(std::string(key) + " is required");
  }
  const auto* value = std::get_if<std::string>(&iterator->second);
  if (value == nullptr || value->empty()) {
    throw std::invalid_argument(std::string(key) + " must be a non-empty string");
  }
  return *value;
}

std::wstring FileExtension(const std::wstring& path) {
  return std::filesystem::path(path).extension().wstring();
}

void RequireExistingFile(const std::wstring& path) {
  const DWORD attributes = ::GetFileAttributesW(path.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES ||
      (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
    throw std::invalid_argument("File does not exist");
  }
}

flutter::EncodableList QueryHandlers(const std::wstring& path) {
  RequireExistingFile(path);
  const std::wstring extension = FileExtension(path);
  if (extension.empty()) {
    throw std::invalid_argument(
        "Windows open-with enumeration requires a file extension");
  }

  IEnumAssocHandlers* enumerator = nullptr;
  HRESULT hr = ::SHAssocEnumHandlers(extension.c_str(), ASSOC_FILTER_NONE,
                                     &enumerator);
  if (FAILED(hr) || enumerator == nullptr) {
    throw std::runtime_error("SHAssocEnumHandlers failed");
  }

  flutter::EncodableList result;
  std::set<std::wstring> seen_ids;
  IAssocHandler* handler = nullptr;
  ULONG fetched = 0;
  while (enumerator->Next(1, &handler, &fetched) == S_OK) {
    LPWSTR raw_name = nullptr;
    LPWSTR raw_ui_name = nullptr;
    const HRESULT name_hr = handler->GetName(&raw_name);
    const HRESULT ui_name_hr = handler->GetUIName(&raw_ui_name);

    if (SUCCEEDED(name_hr) && raw_name != nullptr && raw_name[0] != L'\0') {
      const std::wstring id(raw_name);
      if (seen_ids.insert(id).second) {
        std::wstring label = id;
        if (SUCCEEDED(ui_name_hr) && raw_ui_name != nullptr &&
            raw_ui_name[0] != L'\0') {
          label.assign(raw_ui_name);
        }
        result.emplace_back(flutter::EncodableMap{
            {flutter::EncodableValue("id"),
             flutter::EncodableValue(Utf8FromUtf16(id.c_str()))},
            {flutter::EncodableValue("label"),
             flutter::EncodableValue(Utf8FromUtf16(label.c_str()))},
        });
      }
    }

    if (raw_name != nullptr) ::CoTaskMemFree(raw_name);
    if (raw_ui_name != nullptr) ::CoTaskMemFree(raw_ui_name);
    handler->Release();
    handler = nullptr;
    fetched = 0;
  }

  enumerator->Release();
  return result;
}

IDataObject* CreateFileDataObject(const std::wstring& path) {
  PIDLIST_ABSOLUTE absolute = nullptr;
  HRESULT hr = ::SHParseDisplayName(path.c_str(), nullptr, &absolute, 0, nullptr);
  if (FAILED(hr) || absolute == nullptr) {
    throw std::runtime_error("SHParseDisplayName failed");
  }

  PIDLIST_ABSOLUTE parent = ::ILClone(absolute);
  if (parent == nullptr || !::ILRemoveLastID(parent)) {
    if (parent != nullptr) ::ILFree(parent);
    ::ILFree(absolute);
    throw std::runtime_error("Failed to split shell item path");
  }

  PCUITEMID_CHILD child = ::ILFindLastID(absolute);
    PCUITEMID_CHILD children[] = {child};

  IDataObject* data_object = nullptr;
  hr = ::SHCreateDataObject(parent, 1, children, nullptr, IID_PPV_ARGS(&data_object));

  ::ILFree(parent);
  ::ILFree(absolute);

  if (FAILED(hr) || data_object == nullptr) {
    throw std::runtime_error("SHCreateDataObject failed");
  }
  return data_object;
}

void OpenWithHandler(const std::wstring& path, const std::wstring& handler_id) {
  RequireExistingFile(path);
  const std::wstring extension = FileExtension(path);
  if (extension.empty()) {
    throw std::invalid_argument(
        "Windows open-with invocation requires a file extension");
  }

  IEnumAssocHandlers* enumerator = nullptr;
  HRESULT hr = ::SHAssocEnumHandlers(extension.c_str(), ASSOC_FILTER_NONE,
                                     &enumerator);
  if (FAILED(hr) || enumerator == nullptr) {
    throw std::runtime_error("SHAssocEnumHandlers failed");
  }

  IDataObject* data_object = nullptr;
  IAssocHandler* handler = nullptr;
  ULONG fetched = 0;
  bool matched = false;
  HRESULT invoke_hr = E_FAIL;

  while (enumerator->Next(1, &handler, &fetched) == S_OK) {
    LPWSTR raw_name = nullptr;
    const HRESULT name_hr = handler->GetName(&raw_name);
    if (SUCCEEDED(name_hr) && raw_name != nullptr && handler_id == raw_name) {
      matched = true;
      data_object = CreateFileDataObject(path);
      invoke_hr = handler->Invoke(data_object);
      data_object->Release();
      data_object = nullptr;
    }
    if (raw_name != nullptr) ::CoTaskMemFree(raw_name);
    handler->Release();
    handler = nullptr;
    fetched = 0;
    if (matched) break;
  }

  enumerator->Release();

  if (!matched) {
    throw std::invalid_argument("Selected Windows handler is no longer available");
  }
  if (FAILED(invoke_hr)) {
    throw std::runtime_error("IAssocHandler::Invoke failed");
  }
}

}  // namespace

OpenWithBridge::OpenWithBridge(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        try {
          if (call.method_name() == "queryHandlers") {
            const std::wstring path = Utf16FromUtf8(RequiredStringArgument(call, "path"));
            result->Success(flutter::EncodableValue(QueryHandlers(path)));
            return;
          }
          if (call.method_name() == "openWith") {
            const std::wstring path = Utf16FromUtf8(RequiredStringArgument(call, "path"));
            const std::wstring handler_id =
                Utf16FromUtf8(RequiredStringArgument(call, "handlerId"));
            OpenWithHandler(path, handler_id);
            result->Success();
            return;
          }
          result->NotImplemented();
        } catch (const std::invalid_argument& error) {
          result->Error("INVALID_ARGUMENT", error.what());
        } catch (const std::exception& error) {
          result->Error("OPEN_WITH_FAILED", error.what());
        }
      });
}

OpenWithBridge::~OpenWithBridge() = default;
