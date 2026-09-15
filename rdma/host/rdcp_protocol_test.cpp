#include "rdcp_protocol.hpp"

#include <cstdint>
#include <iostream>
#include <vector>

namespace {

bool expect(bool condition, const char* message) {
    if (!condition) {
        std::cerr << message << '\n';
    }
    return condition;
}

void write_be16(std::vector<std::uint8_t>& bytes, std::size_t offset,
                std::uint16_t value) {
    bytes[offset] = static_cast<std::uint8_t>(value >> 8U);
    bytes[offset + 1U] = static_cast<std::uint8_t>(value);
}

void write_be32(std::vector<std::uint8_t>& bytes, std::size_t offset,
                std::uint32_t value) {
    bytes[offset] = static_cast<std::uint8_t>(value >> 24U);
    bytes[offset + 1U] = static_cast<std::uint8_t>(value >> 16U);
    bytes[offset + 2U] = static_cast<std::uint8_t>(value >> 8U);
    bytes[offset + 3U] = static_cast<std::uint8_t>(value);
}

void write_be64(std::vector<std::uint8_t>& bytes, std::size_t offset,
                std::uint64_t value) {
    write_be32(bytes, offset, static_cast<std::uint32_t>(value >> 32U));
    write_be32(bytes, offset + 4U, static_cast<std::uint32_t>(value));
}

std::vector<std::uint8_t> make_status_response(rdcp::Opcode opcode,
                                                std::uint64_t session_id,
                                                std::uint32_t transaction_id) {
    std::vector<std::uint8_t> bytes(rdcp::kHeaderBytes + rdcp::kStatusBytes);
    write_be32(bytes, 0U, rdcp::kMagic);
    bytes[4] = rdcp::kVersion;
    bytes[5] = rdcp::response_opcode(opcode);
    write_be16(bytes, 6U, rdcp::kStatusBytes);
    write_be64(bytes, 8U, session_id);
    write_be32(bytes, 16U, transaction_id);

    write_be16(bytes, 20U, static_cast<std::uint16_t>(rdcp::Result::ok));
    bytes[22] = static_cast<std::uint8_t>(rdcp::State::running);
    write_be32(bytes, 24U, 0x01020304U);
    write_be32(bytes, 28U, rdcp::kStatusConfigured | rdcp::kStatusActive);
    write_be32(bytes, 32U, rdcp::kLocalQpn);
    write_be32(bytes, 36U, 0x00abc123U);
    write_be32(bytes, 40U, 7U);
    write_be64(bytes, 44U, 0x1112131415161718ULL);
    write_be64(bytes, 52U, 0x2122232425262728ULL);
    write_be64(bytes, 60U, 0x3132333435363738ULL);
    write_be64(bytes, 68U, 0x4142434445464748ULL);
    write_be32(bytes, 76U, rdcp::kCapabilitiesV1);
    write_be32(bytes, 80U, rdcp::kPmtuBytes);
    return bytes;
}

}  // namespace

int main() {
    constexpr std::uint64_t session_id{0x0102030405060708ULL};
    constexpr std::uint32_t transaction_id{0x11223344U};
    rdcp::Config config{};
    config.remote_qpn = 0x00abcdefU;
    config.local_psn = 0x00123456U;
    config.remote_base = 0x0000123456789000ULL;
    config.rkey = 0x89abcdefU;
    config.ring_size = 0x40000000U;
    config.wr_size = 0x00a00000U;
    config.notify_interval = 0x00a00000U;
    config.local_base = 0U;
    config.commit_address = 0x0000123496789000ULL;

    const auto request = rdcp::make_config_request(
        session_id, transaction_id, config);
    const std::vector<std::uint8_t> config_golden{
        0x52, 0x44, 0x43, 0x50, 0x01, 0x02, 0x00, 0x38,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x11, 0x22, 0x33, 0x44, 0x00, 0xab, 0xcd, 0xef,
        0x00, 0x12, 0x34, 0x56, 0x00, 0x00, 0x12, 0x34,
        0x56, 0x78, 0x90, 0x00, 0x89, 0xab, 0xcd, 0xef,
        0x40, 0x00, 0x00, 0x00, 0x00, 0xa0, 0x00, 0x00,
        0x00, 0xa0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x12, 0x34,
        0x96, 0x78, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    if (!expect(request == config_golden,
                "CONFIG request does not match the RDCP v1 golden vector") ||
        !expect(request.size() == 76U, "CONFIG request length is not 76 bytes") ||
        !expect(rdcp::read_be32(request.data()) == rdcp::kMagic,
                "CONFIG magic is not network order") ||
        !expect(request[4] == 1U && request[5] == 2U,
                "CONFIG version or opcode is wrong") ||
        !expect(rdcp::read_be16(request.data() + 6U) == 56U,
                "CONFIG payload length is wrong") ||
        !expect(rdcp::read_be64(request.data() + 8U) == session_id,
                "CONFIG session is wrong") ||
        !expect(rdcp::read_be32(request.data() + 16U) == transaction_id,
                "CONFIG transaction is wrong") ||
        !expect(rdcp::read_be32(request.data() + 20U) == config.remote_qpn,
                "CONFIG remote QPN is wrong") ||
        !expect(rdcp::read_be64(request.data() + 28U) == config.remote_base,
                "CONFIG remote base is wrong") ||
        !expect(rdcp::read_be32(request.data() + 72U) == 0U,
                "CONFIG reserved field is not zero")) {
        return 1;
    }

    rdcp::Transaction transaction{rdcp::Opcode::start, session_id, 9U};
    const auto first_wire_request = transaction.request();
    const auto retry_wire_request = transaction.request();
    if (!expect(first_wire_request == retry_wire_request,
                "retry changed the transaction bytes")) {
        return 1;
    }

    auto wrong_response = make_status_response(rdcp::Opcode::start,
                                               session_id, 10U);
    rdcp::Status status{};
    if (!expect(!transaction.accept(wrong_response, status),
                "transaction accepted a response with the wrong id")) {
        return 1;
    }
    const auto response = make_status_response(rdcp::Opcode::start,
                                               session_id, 9U);
    const std::vector<std::uint8_t> status_golden{
        0x52, 0x44, 0x43, 0x50, 0x01, 0x83, 0x00, 0x40,
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x03, 0x00,
        0x01, 0x02, 0x03, 0x04, 0x00, 0x00, 0x00, 0x03,
        0x00, 0x00, 0x00, 0x01, 0x00, 0xab, 0xc1, 0x23,
        0x00, 0x00, 0x00, 0x07, 0x11, 0x12, 0x13, 0x14,
        0x15, 0x16, 0x17, 0x18, 0x21, 0x22, 0x23, 0x24,
        0x25, 0x26, 0x27, 0x28, 0x31, 0x32, 0x33, 0x34,
        0x35, 0x36, 0x37, 0x38, 0x41, 0x42, 0x43, 0x44,
        0x45, 0x46, 0x47, 0x48, 0x00, 0x00, 0x00, 0x07,
        0x00, 0x00, 0x10, 0x00,
    };
    if (!expect(response == status_golden,
                "STATUS response does not match the RDCP v1 golden vector") ||
        !expect(transaction.accept(response, status),
                "transaction rejected its response") ||
        !expect(status.result == rdcp::Result::ok &&
                    status.state == rdcp::State::running,
                "status result or state was decoded incorrectly") ||
        !expect(status.current_psn == 0x00abc123U &&
                    status.issued_bytes == 0x1112131415161718ULL &&
                    status.producer_sequence == 0x4142434445464748ULL,
                "status counters were decoded incorrectly") ||
        !expect(status.capabilities == rdcp::kCapabilitiesV1,
                "status capabilities were decoded incorrectly") ||
        !expect(status.pmtu_bytes == rdcp::kPmtuBytes,
                "status PMTU was decoded incorrectly")) {
        return 1;
    }

    if (!expect(!rdcp::active_session_requires_abort(status),
                "valid RUNNING status requested ABORT")) {
        return 1;
    }
    status.state = rdcp::State::ready;
    if (!expect(rdcp::active_session_requires_abort(status),
                "unexpected READY status did not request ABORT")) {
        return 1;
    }
    status.state = rdcp::State::running;
    status.status_bits |= rdcp::kStatusFault;
    if (!expect(rdcp::active_session_requires_abort(status),
                "fault status bit did not request ABORT")) {
        return 1;
    }
    status.status_bits &= ~rdcp::kStatusFault;

    rdcp::ReleaseGate release_gate;
    release_gate.observe_status(status);
    release_gate.observe_final_commit();
    if (!expect(!release_gate.normal_release_ready(),
                "RUNNING status released the MR")) {
        return 1;
    }
    status.state = rdcp::State::closed;
    status.status_bits = rdcp::kStatusSafeToRelease;
    status.result = rdcp::Result::bad_session;
    release_gate.observe_status(status);
    if (!expect(!release_gate.normal_release_ready(),
                "an error response released the MR")) {
        return 1;
    }
    status.result = rdcp::Result::ok;
    release_gate.observe_status(status);
    if (!expect(release_gate.normal_release_ready(),
                "final commit plus CLOSED/safe did not release the MR")) {
        return 1;
    }

    rdcp::ReleaseGate fault_gate;
    status.state = rdcp::State::faulted;
    status.status_bits = rdcp::kStatusFault | rdcp::kStatusSafeToRelease;
    fault_gate.observe_status(status);
    if (!expect(fault_gate.fault_release_ready() &&
                    !fault_gate.normal_release_ready(),
                "FAULTED/safe teardown semantics are wrong")) {
        return 1;
    }

    std::cout << "rdcp_protocol_test PASS\n";
    return 0;
}
