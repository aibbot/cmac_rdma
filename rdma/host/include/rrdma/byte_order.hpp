#ifndef RRDMA_INCLUDE_RRDMA_BYTE_ORDER_HPP_
#define RRDMA_INCLUDE_RRDMA_BYTE_ORDER_HPP_

#include <array>
#include <cstddef>
#include <cstdint>
#include <type_traits>

namespace rrdma::wire {

// Network fields are byte arrays so wire structs stay safe at any alignment.
template <typename T>
  requires(std::is_same_v<T, std::uint16_t>
           || std::is_same_v<T, std::uint32_t>
           || std::is_same_v<T, std::uint64_t>)
class BigEndian {
 public:
  using value_type = T;

  constexpr BigEndian() noexcept = default;
  constexpr BigEndian(T value) noexcept { *this = value; }

  constexpr BigEndian &operator=(T value) noexcept {
    for (std::size_t index{}; index < sizeof(T); ++index) {
      const auto shift = (sizeof(T) - index - 1U) * 8U;
      bytes_[index] = static_cast<std::byte>(value >> shift);
    }
    return *this;
  }

  [[nodiscard]] constexpr T value() const noexcept {
    T value{};
    for (const auto byte : bytes_) {
      value = static_cast<T>((value << 8U)
                             | std::to_integer<unsigned int>(byte));
    }
    return value;
  }

  [[nodiscard]] constexpr operator T() const noexcept { return value(); }

 private:
  std::array<std::byte, sizeof(T)> bytes_{};
};

using Be16 = BigEndian<std::uint16_t>;
using Be32 = BigEndian<std::uint32_t>;
using Be64 = BigEndian<std::uint64_t>;

static_assert(sizeof(Be16) == sizeof(std::uint16_t));
static_assert(sizeof(Be32) == sizeof(std::uint32_t));
static_assert(sizeof(Be64) == sizeof(std::uint64_t));
static_assert(alignof(Be16) == 1U);
static_assert(alignof(Be32) == 1U);
static_assert(alignof(Be64) == 1U);
static_assert(std::is_standard_layout_v<Be16>);
static_assert(std::is_standard_layout_v<Be32>);
static_assert(std::is_standard_layout_v<Be64>);
static_assert(std::is_trivially_copyable_v<Be16>);
static_assert(std::is_trivially_copyable_v<Be32>);
static_assert(std::is_trivially_copyable_v<Be64>);

}  // namespace rrdma::wire

#endif  // RRDMA_INCLUDE_RRDMA_BYTE_ORDER_HPP_
