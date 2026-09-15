#include "rdcp_client.hpp"
#include "rdcp_stop_signal.hpp"

#include <chrono>
#include <csignal>
#include <cstdint>
#include <iostream>
#include <utility>
#include <vector>

namespace {

void write_be16(std::vector<std::uint8_t> &bytes, std::size_t offset,
                std::uint16_t value) {
  bytes[offset] = static_cast<std::uint8_t>(value >> 8U);
  bytes[offset + 1U] = static_cast<std::uint8_t>(value);
}

void write_be32(std::vector<std::uint8_t> &bytes, std::size_t offset,
                std::uint32_t value) {
  bytes[offset] = static_cast<std::uint8_t>(value >> 24U);
  bytes[offset + 1U] = static_cast<std::uint8_t>(value >> 16U);
  bytes[offset + 2U] = static_cast<std::uint8_t>(value >> 8U);
  bytes[offset + 3U] = static_cast<std::uint8_t>(value);
}

void write_be64(std::vector<std::uint8_t> &bytes, std::size_t offset,
                std::uint64_t value) {
  write_be32(bytes, offset, static_cast<std::uint32_t>(value >> 32U));
  write_be32(bytes, offset + 4U, static_cast<std::uint32_t>(value));
}

std::vector<std::uint8_t> response_for(const std::vector<std::uint8_t> &request,
                                       rdcp::State state,
                                       std::uint32_t status_bits) {
  std::vector<std::uint8_t> response(rdcp::kHeaderBytes + rdcp::kStatusBytes,
                                     0U);
  write_be32(response, 0U, rdcp::kMagic);
  response[4] = rdcp::kVersion;
  response[5] = request[5] | 0x80U;
  write_be16(response, 6U, rdcp::kStatusBytes);
  write_be64(response, 8U, rdcp::read_be64(request.data() + 8U));
  write_be32(response, 16U, rdcp::read_be32(request.data() + 16U));
  write_be16(response, 20U, static_cast<std::uint16_t>(rdcp::Result::ok));
  response[22] = static_cast<std::uint8_t>(state);
  write_be32(response, 28U, status_bits);
  write_be32(response, 32U, rdcp::kLocalQpn);
  write_be32(response, 76U, rdcp::kCapabilitiesV1);
  write_be32(response, 80U, rdcp::kPmtuBytes);
  return response;
}

class MockTransport final : public rdcp::DatagramTransport {
public:
  bool send(const std::vector<std::uint8_t> &request) override {
    sent.push_back(request);
    send_times.push_back(std::chrono::steady_clock::now());
    return send_succeeds;
  }

  bool receive(std::vector<std::uint8_t> &response,
               std::chrono::milliseconds) override {
    if (scripted.empty()) {
      return false;
    }
    response = std::move(scripted.front());
    scripted.erase(scripted.begin());
    return !response.empty();
  }

  std::vector<std::vector<std::uint8_t>> sent;
  std::vector<std::chrono::steady_clock::time_point> send_times;
  std::vector<std::vector<std::uint8_t>> scripted;
  bool send_succeeds{true};
};

bool expect(bool condition, const char *message) {
  if (!condition) {
    std::cerr << message << '\n';
  }
  return condition;
}

} // namespace

int main() {
  MockTransport transport;
  rdcp::Client client{transport, 17U};
  client.set_session(0x0102030405060708ULL);

  // A timeout causes the exact same transaction bytes to be resent.
  transport.scripted.push_back({});
  const auto expected_start =
      rdcp::make_request(rdcp::Opcode::start, 0x0102030405060708ULL, 17U);
  transport.scripted.push_back(
      response_for(expected_start, rdcp::State::running,
                   rdcp::kStatusConfigured | rdcp::kStatusActive));
  rdcp::Status status{};
  if (!expect(client.transact(rdcp::Opcode::start,
                              std::chrono::milliseconds{250}, status),
              "START retry did not receive the mock response") ||
      !expect(transport.sent.size() == 2U &&
                  transport.sent[0] == transport.sent[1],
              "START retry changed the transaction bytes") ||
      !expect(transport.send_times[1] - transport.send_times[0] >=
                  std::chrono::milliseconds{90},
              "START retry did not honor the 100 ms retry cadence")) {
    return 1;
  }

  // A duplicate response for the previous transaction must be ignored.
  const auto expected_stop =
      rdcp::make_request(rdcp::Opcode::stop, 0x0102030405060708ULL, 18U);
  transport.scripted.push_back(
      response_for(expected_start, rdcp::State::running,
                   rdcp::kStatusConfigured | rdcp::kStatusActive));
  transport.scripted.push_back(
      response_for(expected_stop, rdcp::State::stopping, 0U));
  rdcp::clear_stop_signal();
  if (!expect(rdcp::install_stop_signal_handlers(),
              "failed to install production signal handlers") ||
      !expect(std::raise(SIGINT) == 0 && rdcp::stop_signal_requested(),
              "SIGINT did not latch a stop request") ||
      !expect(rdcp::stop_signal_requested() &&
                  client.transact(rdcp::Opcode::stop,
                                  std::chrono::milliseconds{10}, status),
              "signal-driven STOP did not complete") ||
      !expect(status.state == rdcp::State::stopping,
              "duplicate response was accepted as the STOP response")) {
    return 1;
  }
  rdcp::clear_stop_signal();

  // A local send failure must still honor the 100 ms retry cadence instead
  // of spinning until the transaction window expires.
  transport.send_succeeds = false;
  const std::size_t sends_before_failure = transport.sent.size();
  if (!expect(!client.transact(rdcp::Opcode::status,
                               std::chrono::milliseconds{20}, status),
              "failed send unexpectedly completed a transaction") ||
      !expect(transport.sent.size() == sends_before_failure + 1U,
              "failed send was retried without pacing")) {
    return 1;
  }
  transport.send_succeeds = true;

  // A lost CONFIG response must not let a stale HELLO state bypass ABORT.
  MockTransport recovery_transport;
  rdcp::Client recovery_client{recovery_transport, 91U};
  constexpr std::uint64_t recovery_session = 0x1112131415161718ULL;
  recovery_client.set_session(recovery_session);
  rdcp::Status stale_status{};
  stale_status.result = rdcp::Result::ok;
  stale_status.state = rdcp::State::faulted;
  stale_status.status_bits = rdcp::kStatusSafeToRelease;
  recovery_transport.scripted.push_back({});
  if (!expect(!recovery_client.transact(rdcp::Opcode::config,
                                        std::chrono::milliseconds{1},
                                        stale_status),
              "mock CONFIG unexpectedly received a response")) {
    return 1;
  }
  const auto expected_abort =
      rdcp::make_request(rdcp::Opcode::abort, recovery_session, 92U);
  recovery_transport.scripted.push_back(response_for(
      expected_abort, rdcp::State::faulted, rdcp::kStatusSafeToRelease));
  if (!expect(
          recovery_client.abort_and_check_safe(std::chrono::milliseconds{10},
                                               std::chrono::milliseconds{10}),
          "ABORT did not confirm safe release after lost CONFIG response") ||
      !expect(recovery_transport.sent.size() == 2U &&
                  recovery_transport.sent[1] == expected_abort,
              "stale HELLO state bypassed the ABORT request")) {
    return 1;
  }

  // A random seed in the upper half must leave room for this finite session
  // instead of wrapping behind the FPGA transaction watermark.
  MockTransport boundary_transport;
  boundary_transport.send_succeeds = false;
  rdcp::Client boundary_client{boundary_transport, 0xffffffffU};
  rdcp::Status boundary_status{};
  if (!expect(!boundary_client.transact(rdcp::Opcode::hello,
                                        std::chrono::milliseconds{1},
                                        boundary_status),
              "boundary transaction unexpectedly received a response") ||
      !expect(boundary_transport.sent.size() == 1U &&
                  rdcp::read_be32(boundary_transport.sent[0].data() + 16U) ==
                      0x7fffffffU,
              "initial transaction ID did not reserve wrap-free headroom")) {
    return 1;
  }

  rdcp::ReleaseGate release_gate;
  status.state = rdcp::State::closed;
  status.status_bits = rdcp::kStatusSafeToRelease;
  release_gate.observe_status(status);
  if (!expect(!release_gate.normal_release_ready(),
              "CLOSED/safe released the MR before the final commit")) {
    return 1;
  }
  release_gate.observe_final_commit();
  if (!expect(release_gate.normal_release_ready(),
              "final commit plus CLOSED/safe did not release the MR")) {
    return 1;
  }

  rdcp::ReleaseGate fault_gate;
  status.state = rdcp::State::faulted;
  status.status_bits = 0U;
  fault_gate.observe_status(status);
  if (!expect(!fault_gate.fault_release_ready(),
              "FAULTED released the MR without safe_to_release")) {
    return 1;
  }
  status.status_bits = rdcp::kStatusSafeToRelease;
  fault_gate.observe_status(status);
  if (!expect(fault_gate.fault_release_ready(),
              "FAULTED + safe_to_release did not release the MR")) {
    return 1;
  }

  std::cout << "rdcp_client_test PASS\n";
  return 0;
}
