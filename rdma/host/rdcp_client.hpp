#ifndef RDCP_CLIENT_HPP
#define RDCP_CLIENT_HPP

#include "rdcp_protocol.hpp"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <thread>
#include <vector>

namespace rdcp {

class DatagramTransport {
public:
  virtual ~DatagramTransport() = default;
  virtual bool send(const std::vector<std::uint8_t> &request) = 0;
  virtual bool receive(std::vector<std::uint8_t> &response,
                       std::chrono::milliseconds timeout) = 0;
};

class Client {
public:
  Client(DatagramTransport &transport, std::uint32_t first_transaction_id)
      : transport_(transport),
        next_transaction_id_(first_transaction_id & 0x7fffffffU) {
    if (next_transaction_id_ == 0U) {
      next_transaction_id_ = 1U;
    }
  }

  void set_session(std::uint64_t session_id) noexcept {
    session_id_ = session_id;
  }

  bool transact(Opcode opcode, std::chrono::milliseconds window, Status &status,
                const std::vector<std::uint8_t> &payload = {},
                bool *response_observed = nullptr) {
    const Transaction transaction{opcode, session_id_, next_transaction(),
                                  payload};
    const auto deadline = std::chrono::steady_clock::now() + window;

    do {
      const auto attempt_deadline =
          std::min(deadline, std::chrono::steady_clock::now() + kRetryInterval);
      if (transport_.send(transaction.request())) {
        do {
          std::vector<std::uint8_t> response;
          const auto now = std::chrono::steady_clock::now();
          if (now >= attempt_deadline) {
            break;
          }
          const auto wait =
              std::chrono::duration_cast<std::chrono::milliseconds>(
                  attempt_deadline - now);
          if (!transport_.receive(response, wait)) {
            break;
          }
          if (transaction.accept(response, status)) {
            if (response_observed != nullptr) {
              *response_observed = true;
            }
            return true;
          }
        } while (std::chrono::steady_clock::now() < attempt_deadline);
      }
      std::this_thread::sleep_until(attempt_deadline);
    } while (std::chrono::steady_clock::now() < deadline);
    return false;
  }

  bool configure(const Config &config, std::chrono::milliseconds window,
                 Status &status) {
    return transact(Opcode::config, window, status,
                    make_config_payload(config));
  }

  bool consume(std::uint64_t consumed_bytes, std::chrono::milliseconds window,
               Status &status, bool *response_observed = nullptr) {
    if (response_observed != nullptr) {
      *response_observed = false;
    }
    const auto payload = make_consume_payload(consumed_bytes);
    const auto deadline = std::chrono::steady_clock::now() + window;

    do {
      const auto now = std::chrono::steady_clock::now();
      if (now >= deadline ||
          !transact(Opcode::consume,
                    std::chrono::duration_cast<std::chrono::milliseconds>(
                        deadline - now),
                    status, payload, response_observed)) {
        return false;
      }
      if (status.result != Result::invalid_progress || status.reason != 2U) {
        return true;
      }

      // The host can observe the commit record just before its RDMA ACK reaches
      // the FPGA. Retry that one transient "ahead of published" rejection as a
      // new transaction; every other progress error is permanent.
      std::this_thread::sleep_for(kProgressRetryInterval);
    } while (std::chrono::steady_clock::now() < deadline);
    return false;
  }

  bool abort_and_check_safe(std::chrono::milliseconds abort_window,
                            std::chrono::milliseconds status_window) {
    ReleaseGate gate;
    Status status{};
    if (transact(Opcode::abort, abort_window, status)) {
      gate.observe_status(status);
    }
    if (!gate.fault_release_ready() &&
        transact(Opcode::status, status_window, status)) {
      gate.observe_status(status);
    }
    return gate.fault_release_ready();
  }

private:
  std::uint32_t next_transaction() noexcept {
    const std::uint32_t current = next_transaction_id_;
    ++next_transaction_id_;
    if (next_transaction_id_ == 0U) {
      next_transaction_id_ = 1U;
    }
    return current;
  }

  static constexpr std::chrono::milliseconds kRetryInterval{100};
  static constexpr std::chrono::microseconds kProgressRetryInterval{50};
  DatagramTransport &transport_;
  std::uint64_t session_id_{};
  std::uint32_t next_transaction_id_{};
};

} // namespace rdcp

#endif
