#ifndef RUNNER_OPEN_WITH_BRIDGE_H_
#define RUNNER_OPEN_WITH_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

class OpenWithBridge {
 public:
  explicit OpenWithBridge(flutter::BinaryMessenger* messenger);
  ~OpenWithBridge();

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_OPEN_WITH_BRIDGE_H_
