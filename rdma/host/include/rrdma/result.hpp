#ifndef RRDMA_INCLUDE_RRDMA_RESULT_HPP_
#define RRDMA_INCLUDE_RRDMA_RESULT_HPP_

#include <cstdint>
#include <optional>
#include <string>
#include <type_traits>
#include <utility>
#include <variant>

#include "rrdma/types.hpp"

// 公共 API 统一通过 Outcome 返回错误，避免异常穿过应用可见的 session 边界。
namespace rrdma {

enum class ErrorCode : std::uint8_t {
  // 错误类别保持稳定；具体系统、verbs 和远端信息放在 Error 中。
  kInvalidConfiguration,
  kAllocationFailed,
  kSystemError,
  kVerbsError,
  kTransportError,
  kProtocolError,
  kTimeout,
  kRemoteRejected,
  kSessionFault,
  kCallbackRejected,
  kStopped,
  kAlreadyRunning,
  kInternalError,
};

struct Error {
  // 本地分类和底层错误码。
  ErrorCode code{ErrorCode::kInternalError};
  // 系统调用失败时保存的 errno。
  int system_errno{};
  // verbs API 返回码或异步事件类型。
  int verbs_status{};
  // FPGA RDCP result/state/reason 原值，非远端错误时保持零。
  std::uint16_t remote_result{};
  std::uint8_t remote_state{};
  std::uint32_t remote_reason{};
  // 面向日志和诊断的人类可读文本。
  std::string message;
  // 检测到未释放数据被覆盖时的累计次数。
  HostCount overrun_count{};
};

template <typename T>
class Outcome {
 public:
  // 成功值和错误值均按值保存，调用者可安全地移动大对象所有权。
  Outcome(T value) : value_(std::move(value)) {}
  Outcome(Error error) : value_(std::move(error)) {}

  [[nodiscard]] bool HasValue() const noexcept {
    // 不抛异常地判断当前变体是否保存 T。
    return std::holds_alternative<T>(value_);
  }
  [[nodiscard]] explicit operator bool() const noexcept { return HasValue(); }

  [[nodiscard]] T &Value() & { return std::get<T>(value_); }
  [[nodiscard]] const T &Value() const & { return std::get<T>(value_); }
  [[nodiscard]] T &&Value() && { return std::get<T>(std::move(value_)); }
  [[nodiscard]] Error &GetError() & { return std::get<Error>(value_); }
  [[nodiscard]] const Error &GetError() const & {
    return std::get<Error>(value_);
  }

 private:
  std::variant<T, Error> value_;
};

template <>
class Outcome<void> {
 public:
  // void 成功态用无 error 表示，保持与 Outcome<T> 相同的布尔接口。
  Outcome() noexcept = default;
  Outcome(Error error) : error_(std::move(error)) {}

  [[nodiscard]] bool HasValue() const noexcept { return !error_.has_value(); }
  [[nodiscard]] explicit operator bool() const noexcept { return HasValue(); }
  [[nodiscard]] const Error &GetError() const & { return *error_; }
  [[nodiscard]] Error &GetError() & { return *error_; }

 private:
  std::optional<Error> error_;
};

template <typename T>
[[nodiscard]] Outcome<T> Failure(Error error) {
  // 便捷构造失败结果，保证错误对象被移动而不是复制。
  return Outcome<T>{std::move(error)};
}

[[nodiscard]] inline Error MakeError(ErrorCode code, std::string message,
                                     int system_errno = 0) {
  // 创建带可读诊断文本的基础错误；verbs/远端字段由调用层补充。
  Error error{};
  error.code = code;
  error.system_errno = system_errno;
  error.message = std::move(message);
  return error;
}

}  // namespace rrdma

#endif  // RRDMA_INCLUDE_RRDMA_RESULT_HPP_
