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
  if (request[5] == static_cast<std::uint8_t>(rdcp::Opcode::consume)) {
    write_be64(response, 68U, rdcp::read_be64(request.data() + 20U));
  }
  write_be32(response, 76U, rdcp::kCapabilitiesV2);
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

  constexpr std::uint64_t consumed_bytes{10ULL * 1024ULL * 1024ULL};
  const auto expected_consume =
      rdcp::make_consume_request(0x0102030405060708ULL, 18U, consumed_bytes);
  transport.scripted.push_back(
      response_for(expected_consume, rdcp::State::running,
                   rdcp::kStatusConfigured | rdcp::kStatusActive));
  if (!expect(
          client.consume(consumed_bytes, std::chrono::milliseconds{10}, status),
          "CONSUME did not complete") ||
      !expect(transport.sent.back() == expected_consume,
              "CONSUME request bytes are wrong") ||
      !expect(status.consumed_bytes == consumed_bytes,
              "CONSUME response did not acknowledge progress")) {
    return 1;
  }

  // The commit record can become CPU-visible just before its RDMA ACK updates
  // the FPGA's published counter. Only that transient rejection is retried,
  // and the retry must use a fresh transaction ID.
  const auto first_consume = rdcp::make_consume_request(
      0x0102030405060708ULL, 19U, consumed_bytes * 2U);
  const auto second_consume = rdcp::make_consume_request(
      0x0102030405060708ULL, 20U, consumed_bytes * 2U);
  auto not_published = response_for(first_consume, rdcp::State::running, 0U);
  write_be16(not_published, 20U,
             static_cast<std::uint16_t>(rdcp::Result::invalid_progress));
  write_be32(not_published, 24U, 2U);
  auto consumed = response_for(second_consume, rdcp::State::running, 0U);
  write_be64(consumed, 68U, consumed_bytes * 2U);
  transport.scripted.push_back({not_published});
  transport.scripted.push_back({consumed});
  if (!expect(client.consume(consumed_bytes * 2U, std::chrono::milliseconds{10},
                             status),
              "transient CONSUME rejection did not recover") ||
      !expect(transport.sent.size() >= 2U &&
                  transport.sent[transport.sent.size() - 2U] == first_consume &&
                  transport.sent.back() == second_consume,
              "CONSUME recovery did not use a fresh transaction") ||
      !expect(status.result == rdcp::Result::ok &&
                  status.consumed_bytes == consumed_bytes * 2U,
              "CONSUME recovery returned the wrong status")) {
    return 1;
  }

  const auto permanent_consume =
      rdcp::make_consume_request(0x0102030405060708ULL, 21U, consumed_bytes);
  auto moved_backwards =
      response_for(permanent_consume, rdcp::State::running, 0U);
  write_be16(moved_backwards, 20U,
             static_cast<std::uint16_t>(rdcp::Result::invalid_progress));
  write_be32(moved_backwards, 24U, 1U);
  transport.scripted.push_back({moved_backwards});
  const auto sends_before_permanent_error = transport.sent.size();
  if (!expect(
          client.consume(consumed_bytes, std::chrono::milliseconds{10}, status),
          "permanent CONSUME rejection response was lost") ||
      !expect(status.result == rdcp::Result::invalid_progress &&
                  status.reason == 1U,
              "permanent CONSUME rejection was not returned") ||
      !expect(transport.sent.size() == sends_before_permanent_error + 1U,
              "permanent CONSUME rejection was retried")) {
    return 1;
  }

  // A failed command must distinguish a missing reply from an accepted
  // transient progress rejection that exhausted the overall window.
  MockTransport no_reply_transport;
  rdcp::Client no_reply_client{no_reply_transport, 31U};
  no_reply_client.set_session(0x0102030405060708ULL);
  rdcp::Status no_reply_status{};
  bool response_observed = true;
  if (!expect(!no_reply_client.consume(
                  consumed_bytes, std::chrono::milliseconds{1},
                  no_reply_status, &response_observed) && !response_observed,
              "CONSUME timeout incorrectly recorded a verified response")) {
    return 1;
  }

  MockTransport transient_transport;
  rdcp::Client transient_client{transient_transport, 41U};
  transient_client.set_session(0x0102030405060708ULL);
  const auto transient_request = rdcp::make_consume_request(
      0x0102030405060708ULL, 41U, consumed_bytes);
  auto transient_reply =
      response_for(transient_request, rdcp::State::running, 0U);
  write_be16(transient_reply, 20U,
             static_cast<std::uint16_t>(rdcp::Result::invalid_progress));
  write_be32(transient_reply, 24U, 2U);
  transient_transport.scripted.push_back({transient_reply});
  rdcp::Status transient_status{};
  response_observed = false;
  if (!expect(!transient_client.consume(
                  consumed_bytes, std::chrono::milliseconds{10},
                  transient_status, &response_observed) && response_observed &&
                  transient_status.result == rdcp::Result::invalid_progress &&
                  transient_status.reason == 2U,
              "CONSUME transient timeout lost its verified reply")) {
    return 1;
  }

  // A duplicate response for the previous transaction must be ignored.
  const auto expected_stop =
      rdcp::make_request(rdcp::Opcode::stop, 0x0102030405060708ULL, 22U);
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

  // A random seed in the upper half must leave substantial room before the
  // transaction counter can wrap behind the FPGA watermark.
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
