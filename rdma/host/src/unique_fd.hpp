#ifndef RRDMA_SRC_UNIQUE_FD_HPP_
#define RRDMA_SRC_UNIQUE_FD_HPP_

#include <unistd.h>

#include <utility>

namespace rrdma::detail {

class UniqueFd {
 public:
  explicit UniqueFd(int value = -1) noexcept : value_(value) {}
  ~UniqueFd() {
    if (value_ >= 0) {
      (void)::close(value_);
    }
  }

  UniqueFd(const UniqueFd &) = delete;
  UniqueFd &operator=(const UniqueFd &) = delete;

  UniqueFd(UniqueFd &&other) noexcept
      : value_(std::exchange(other.value_, -1)) {}

  UniqueFd &operator=(UniqueFd &&other) noexcept {
    if (this != &other) {
      Reset();
      value_ = std::exchange(other.value_, -1);
    }
    return *this;
  }

  [[nodiscard]] int Get() const noexcept { return value_; }
  [[nodiscard]] int Release() noexcept { return std::exchange(value_, -1); }

  void Reset(int value = -1) noexcept {
    if (value_ >= 0) {
      (void)::close(value_);
    }
    value_ = value;
  }

 private:
  int value_;
};

}  // namespace rrdma::detail

#endif  // RRDMA_SRC_UNIQUE_FD_HPP_
