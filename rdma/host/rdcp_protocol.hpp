#ifndef RDCP_PROTOCOL_HPP
#define RDCP_PROTOCOL_HPP

#include <cstddef>
#include <cstdint>
#include <vector>

namespace rdcp {

inline constexpr std::uint32_t kMagic{0x52444350U};
inline constexpr std::uint8_t kVersion{1U};
inline constexpr std::uint16_t kControlPort{4792U};
inline constexpr std::uint32_t kLocalQpn{1U};
inline constexpr std::uint32_t kPmtuBytes{4096U};
inline constexpr std::size_t kHeaderBytes{20U};
inline constexpr std::size_t kConfigBytes{56U};
inline constexpr std::size_t kStatusBytes{64U};

enum class Opcode : std::uint8_t {
  hello = 1U,
  config = 2U,
  start = 3U,
  stop = 4U,
  abort = 5U,
  status = 6U,
};

enum class Result : std::uint16_t {
  ok = 0U,
  bad_version = 1U,
  bad_opcode = 2U,
  bad_length = 3U,
  bad_session = 4U,
  bad_source = 5U,
  old_transaction = 6U,
  busy = 7U,
  invalid_config = 8U,
  invalid_state = 9U,
  internal_fault = 10U,
};

enum class State : std::uint8_t {
  idle = 0U,
  configuring = 1U,
  ready = 2U,
  running = 3U,
  stopping = 4U,
  closed = 5U,
  fault_quiescing = 6U,
  faulted = 7U,
};

inline constexpr std::uint32_t kStatusConfigured{1U << 0U};
inline constexpr std::uint32_t kStatusActive{1U << 1U};
inline constexpr std::uint32_t kStatusDrained{1U << 2U};
inline constexpr std::uint32_t kStatusFault{1U << 3U};
inline constexpr std::uint32_t kStatusSafeToRelease{1U << 4U};
inline constexpr std::uint32_t kStatusFinalCommitAcked{1U << 5U};

inline constexpr std::uint32_t kCapabilityImmediate{1U << 0U};
inline constexpr std::uint32_t kCapabilityFiniteRing{1U << 1U};
inline constexpr std::uint32_t kCapabilityAbortQuiesce{1U << 2U};
inline constexpr std::uint32_t kCapabilitiesV1{
    kCapabilityImmediate | kCapabilityFiniteRing | kCapabilityAbortQuiesce};

struct Config {
  std::uint32_t remote_qpn{};
  std::uint32_t local_psn{};
  std::uint64_t remote_base{};
  std::uint32_t rkey{};
  std::uint32_t ring_size{};
  std::uint32_t wr_size{};
  std::uint32_t notify_interval{};
  std::uint64_t local_base{};
  std::uint64_t commit_address{};
  std::uint32_t flags{};
};

struct Status {
  Result result{Result::internal_fault};
  State state{State::idle};
  std::uint32_t reason{};
  std::uint32_t status_bits{};
  std::uint32_t local_qpn{};
  std::uint32_t current_psn{};
  std::uint32_t config_generation{};
  std::uint64_t issued_bytes{};
  std::uint64_t acked_bytes{};
  std::uint64_t published_bytes{};
  std::uint64_t producer_sequence{};
  std::uint32_t capabilities{};
  std::uint32_t pmtu_bytes{};
};

inline bool active_session_requires_abort(const Status &status) noexcept {
  const bool lifecycle_state = status.state == State::running ||
                               status.state == State::stopping ||
                               status.state == State::closed;
  return status.result != Result::ok || !lifecycle_state ||
         (status.status_bits & kStatusFault) != 0U;
}

inline std::uint16_t read_be16(const std::uint8_t *bytes) noexcept {
  return static_cast<std::uint16_t>(
      (static_cast<std::uint16_t>(bytes[0]) << 8U) |
      static_cast<std::uint16_t>(bytes[1]));
}

inline std::uint32_t read_be32(const std::uint8_t *bytes) noexcept {
  return (static_cast<std::uint32_t>(bytes[0]) << 24U) |
         (static_cast<std::uint32_t>(bytes[1]) << 16U) |
         (static_cast<std::uint32_t>(bytes[2]) << 8U) |
         static_cast<std::uint32_t>(bytes[3]);
}

inline std::uint64_t read_be64(const std::uint8_t *bytes) noexcept {
  return (static_cast<std::uint64_t>(read_be32(bytes)) << 32U) |
         read_be32(bytes + 4U);
}

inline void append_be16(std::vector<std::uint8_t> &bytes, std::uint16_t value) {
  bytes.push_back(static_cast<std::uint8_t>(value >> 8U));
  bytes.push_back(static_cast<std::uint8_t>(value));
}

inline void append_be32(std::vector<std::uint8_t> &bytes, std::uint32_t value) {
  bytes.push_back(static_cast<std::uint8_t>(value >> 24U));
  bytes.push_back(static_cast<std::uint8_t>(value >> 16U));
  bytes.push_back(static_cast<std::uint8_t>(value >> 8U));
  bytes.push_back(static_cast<std::uint8_t>(value));
}

inline void append_be64(std::vector<std::uint8_t> &bytes, std::uint64_t value) {
  append_be32(bytes, static_cast<std::uint32_t>(value >> 32U));
  append_be32(bytes, static_cast<std::uint32_t>(value));
}

inline std::uint8_t response_opcode(Opcode opcode) noexcept {
  return static_cast<std::uint8_t>(opcode) | 0x80U;
}

inline std::vector<std::uint8_t>
make_request(Opcode opcode, std::uint64_t session_id,
             std::uint32_t transaction_id,
             const std::vector<std::uint8_t> &payload = {}) {
  std::vector<std::uint8_t> bytes;
  bytes.reserve(kHeaderBytes + payload.size());
  append_be32(bytes, kMagic);
  bytes.push_back(kVersion);
  bytes.push_back(static_cast<std::uint8_t>(opcode));
  append_be16(bytes, static_cast<std::uint16_t>(payload.size()));
  append_be64(bytes, session_id);
  append_be32(bytes, transaction_id);
  bytes.insert(bytes.end(), payload.begin(), payload.end());
  return bytes;
}

inline std::vector<std::uint8_t> make_config_payload(const Config &config) {
  std::vector<std::uint8_t> payload;
  payload.reserve(kConfigBytes);
  append_be32(payload, config.remote_qpn);
  append_be32(payload, config.local_psn);
  append_be64(payload, config.remote_base);
  append_be32(payload, config.rkey);
  append_be32(payload, config.ring_size);
  append_be32(payload, config.wr_size);
  append_be32(payload, config.notify_interval);
  append_be64(payload, config.local_base);
  append_be64(payload, config.commit_address);
  append_be32(payload, config.flags);
  append_be32(payload, 0U);
  return payload;
}

inline std::vector<std::uint8_t>
make_config_request(std::uint64_t session_id, std::uint32_t transaction_id,
                    const Config &config) {
  auto payload = make_config_payload(config);
  return make_request(Opcode::config, session_id, transaction_id, payload);
}

inline bool decode_status_response(const std::uint8_t *bytes, std::size_t size,
                                   Opcode opcode, std::uint64_t session_id,
                                   std::uint32_t transaction_id,
                                   Status &status) noexcept {
  if (size != kHeaderBytes + kStatusBytes || read_be32(bytes) != kMagic ||
      bytes[4] != kVersion || bytes[5] != response_opcode(opcode) ||
      read_be16(bytes + 6U) != kStatusBytes ||
      read_be64(bytes + 8U) != session_id ||
      read_be32(bytes + 16U) != transaction_id) {
    return false;
  }
  status.result = static_cast<Result>(read_be16(bytes + 20U));
  status.state = static_cast<State>(bytes[22]);
  status.reason = read_be32(bytes + 24U);
  status.status_bits = read_be32(bytes + 28U);
  status.local_qpn = read_be32(bytes + 32U);
  status.current_psn = read_be32(bytes + 36U);
  status.config_generation = read_be32(bytes + 40U);
  status.issued_bytes = read_be64(bytes + 44U);
  status.acked_bytes = read_be64(bytes + 52U);
  status.published_bytes = read_be64(bytes + 60U);
  status.producer_sequence = read_be64(bytes + 68U);
  status.capabilities = read_be32(bytes + 76U);
  status.pmtu_bytes = read_be32(bytes + 80U);
  return true;
}

class Transaction {
public:
  Transaction(Opcode opcode, std::uint64_t session_id,
              std::uint32_t transaction_id,
              std::vector<std::uint8_t> payload = {})
      : opcode_(opcode), session_id_(session_id),
        transaction_id_(transaction_id),
        request_(make_request(opcode, session_id, transaction_id, payload)) {}

  const std::vector<std::uint8_t> &request() const noexcept { return request_; }

  bool accept(const std::vector<std::uint8_t> &response,
              Status &status) const noexcept {
    return decode_status_response(response.data(), response.size(), opcode_,
                                  session_id_, transaction_id_, status);
  }

private:
  Opcode opcode_;
  std::uint64_t session_id_;
  std::uint32_t transaction_id_;
  std::vector<std::uint8_t> request_;
};

class ReleaseGate {
public:
  void observe_final_commit() noexcept { final_commit_seen_ = true; }

  void observe_status(const Status &status) noexcept { status_ = status; }

  bool normal_release_ready() const noexcept {
    return final_commit_seen_ && status_.result == Result::ok &&
           status_.state == State::closed &&
           (status_.status_bits & kStatusSafeToRelease) != 0U;
  }

  bool fault_release_ready() const noexcept {
    return status_.result == Result::ok && status_.state == State::faulted &&
           (status_.status_bits & kStatusSafeToRelease) != 0U;
  }

private:
  bool final_commit_seen_{};
  Status status_{};
};

} // namespace rdcp

#endif
