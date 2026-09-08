#if defined(_WIN32)
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#else
#include <arpa/inet.h>
#include <cerrno>
#include <csignal>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
#endif

#include <array>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string>

namespace {

constexpr std::uint16_t kDefaultPort = 5001;
constexpr std::size_t kHeaderLength = 24;
constexpr std::size_t kMagicOffset = 0;
constexpr std::size_t kSequenceOffset = 4;
constexpr std::uint64_t kMaxReportedDiscontinuities = 10;
constexpr int kRequestedReceiveBufferBytes = 16 * 1024 * 1024;
constexpr std::chrono::milliseconds kReceiveTimeout{250};
constexpr std::chrono::seconds kRateReportInterval{1};
constexpr double kBytesPerMiB = 1024.0 * 1024.0;
constexpr std::array<std::uint8_t, 4> kMagic{'R', 'F', 'S', 'O'};

#if defined(_WIN32)
using socket_type = SOCKET;
using receive_result_type = int;
using socket_option_length_type = int;

constexpr socket_type kInvalidSocket = INVALID_SOCKET;
constexpr int kSocketError = SOCKET_ERROR;
constexpr receive_result_type kReceiveError = SOCKET_ERROR;

std::atomic_bool stop_requested{false};

BOOL WINAPI stop_handler(DWORD event) {
    if (event == CTRL_C_EVENT || event == CTRL_BREAK_EVENT ||
        event == CTRL_CLOSE_EVENT) {
        stop_requested.store(true, std::memory_order_relaxed);
        return TRUE;
    }
    return FALSE;
}
#else
using socket_type = int;
using receive_result_type = ssize_t;
using socket_option_length_type = socklen_t;

constexpr socket_type kInvalidSocket = -1;
constexpr int kSocketError = -1;
constexpr receive_result_type kReceiveError = -1;

volatile std::sig_atomic_t stop_requested = 0;

void stop_handler(int) { stop_requested = 1; }
#endif

[[nodiscard]] int last_socket_error() noexcept {
#if defined(_WIN32)
    return WSAGetLastError();
#else
    return errno;
#endif
}

[[nodiscard]] bool is_receive_retry_error(int error) noexcept {
#if defined(_WIN32)
    return error == WSAETIMEDOUT || error == WSAEWOULDBLOCK ||
           error == WSAEINTR;
#else
    return error == EAGAIN || error == EWOULDBLOCK || error == EINTR;
#endif
}

[[nodiscard]] bool stop_is_requested() noexcept {
#if defined(_WIN32)
    return stop_requested.load(std::memory_order_relaxed);
#else
    return stop_requested != 0;
#endif
}

void install_stop_handler() {
#if defined(_WIN32)
    if (!SetConsoleCtrlHandler(stop_handler, TRUE)) {
        throw std::runtime_error("SetConsoleCtrlHandler failed");
    }
#else
    struct sigaction action {};
    action.sa_handler = stop_handler;
    sigemptyset(&action.sa_mask);

    if (sigaction(SIGINT, &action, nullptr) == -1 ||
        sigaction(SIGTERM, &action, nullptr) == -1) {
        throw std::runtime_error("sigaction failed: " +
                                 std::to_string(last_socket_error()));
    }
#endif
}

class SocketPlatformSession {
public:
    SocketPlatformSession() {
#if defined(_WIN32)
        WSADATA data{};
        const int error = WSAStartup(MAKEWORD(2, 2), &data);
        if (error != 0) {
            throw std::runtime_error("WSAStartup failed: " +
                                     std::to_string(error));
        }
#endif
    }

    ~SocketPlatformSession() {
#if defined(_WIN32)
        WSACleanup();
#endif
    }

    SocketPlatformSession(const SocketPlatformSession&) = delete;
    SocketPlatformSession& operator=(const SocketPlatformSession&) = delete;
};

class SocketHandle {
public:
    explicit SocketHandle(socket_type socket) : socket_(socket) {}
    ~SocketHandle() {
        if (socket_ != kInvalidSocket) {
#if defined(_WIN32)
            closesocket(socket_);
#else
            close(socket_);
#endif
        }
    }

    SocketHandle(const SocketHandle&) = delete;
    SocketHandle& operator=(const SocketHandle&) = delete;

    [[nodiscard]] socket_type get() const { return socket_; }

private:
    socket_type socket_ = kInvalidSocket;
};

std::uint16_t parse_port(const char* text) {
    char* end = nullptr;
    const unsigned long value = std::strtoul(text, &end, 10);
    if (end == text || *end != '\0' || value == 0 ||
        value > std::numeric_limits<std::uint16_t>::max()) {
        throw std::runtime_error("invalid UDP port: " + std::string(text));
    }
    return static_cast<std::uint16_t>(value);
}

std::uint32_t read_be32(const std::uint8_t* data) {
    return (static_cast<std::uint32_t>(data[0]) << 24U) |
           (static_cast<std::uint32_t>(data[1]) << 16U) |
           (static_cast<std::uint32_t>(data[2]) << 8U) |
           static_cast<std::uint32_t>(data[3]);
}

bool has_benchmark_magic(const std::uint8_t* data) {
    for (std::size_t index = 0; index < kMagic.size(); ++index) {
        if (data[kMagicOffset + index] != kMagic[index]) {
            std::printf("not found magic\n");
            return false;
        }
    }
    return true;
}

int configure_receive_buffer(socket_type socket_handle) {
    int receive_buffer_bytes = kRequestedReceiveBufferBytes;
#if defined(_WIN32)
    if (setsockopt(socket_handle, SOL_SOCKET, SO_RCVBUF,
                   reinterpret_cast<const char*>(&receive_buffer_bytes),
                   static_cast<int>(sizeof(receive_buffer_bytes))) ==
        kSocketError) {
#else
    if (setsockopt(socket_handle, SOL_SOCKET, SO_RCVBUF,
                   &receive_buffer_bytes,
                   static_cast<socklen_t>(sizeof(receive_buffer_bytes))) ==
        kSocketError) {
#endif
        throw std::runtime_error("setsockopt(SO_RCVBUF) failed: " +
                                 std::to_string(last_socket_error()));
    }

    socket_option_length_type option_length =
        static_cast<socket_option_length_type>(sizeof(receive_buffer_bytes));
#if defined(_WIN32)
    if (getsockopt(socket_handle, SOL_SOCKET, SO_RCVBUF,
                   reinterpret_cast<char*>(&receive_buffer_bytes),
                   &option_length) == kSocketError) {
#else
    if (getsockopt(socket_handle, SOL_SOCKET, SO_RCVBUF,
                   &receive_buffer_bytes, &option_length) == kSocketError) {
#endif
        throw std::runtime_error("getsockopt(SO_RCVBUF) failed: " +
                                 std::to_string(last_socket_error()));
    }
    return receive_buffer_bytes;
}

void configure_receive_timeout(socket_type socket_handle) {
#if defined(_WIN32)
    const DWORD receive_timeout_ms =
        static_cast<DWORD>(kReceiveTimeout.count());
    if (setsockopt(socket_handle, SOL_SOCKET, SO_RCVTIMEO,
                   reinterpret_cast<const char*>(&receive_timeout_ms),
                   static_cast<int>(sizeof(receive_timeout_ms))) ==
        kSocketError) {
#else
    const auto timeout_seconds =
        std::chrono::duration_cast<std::chrono::seconds>(kReceiveTimeout);
    timeval receive_timeout {};
    receive_timeout.tv_sec =
        static_cast<decltype(receive_timeout.tv_sec)>(timeout_seconds.count());
    receive_timeout.tv_usec = static_cast<decltype(receive_timeout.tv_usec)>(
        std::chrono::duration_cast<std::chrono::microseconds>(
            kReceiveTimeout - timeout_seconds)
            .count());
    if (setsockopt(socket_handle, SOL_SOCKET, SO_RCVTIMEO, &receive_timeout,
                   static_cast<socklen_t>(sizeof(receive_timeout))) ==
        kSocketError) {
#endif
        throw std::runtime_error("setsockopt(SO_RCVTIMEO) failed: " +
                                 std::to_string(last_socket_error()));
    }
}

receive_result_type receive_datagram(socket_type socket_handle,
                                     std::uint8_t* buffer,
                                     std::size_t buffer_size) {
#if defined(_WIN32)
    return recvfrom(socket_handle, reinterpret_cast<char*>(buffer),
                    static_cast<int>(buffer_size), 0, nullptr, nullptr);
#else
    return recvfrom(socket_handle, buffer, buffer_size, 0, nullptr, nullptr);
#endif
}

void report_discontinuity(std::uint64_t discontinuities,
                          std::uint32_t expected,
                          std::uint32_t actual) {
    if (discontinuities <= kMaxReportedDiscontinuities) {
        std::cerr << "Sequence discontinuity: expected=0x" << std::hex
                  << std::setw(8) << std::setfill('0') << expected
                  << " actual=0x" << std::setw(8) << actual << std::dec
                  << '\n';
    } else if (discontinuities == kMaxReportedDiscontinuities + 1) {
        std::cerr << "Further discontinuity details suppressed; counting "
                     "continues\n";
    }
}

}  // namespace

int main(int argc, char** argv) {
    if (argc > 3) {
        std::cerr << "Usage: " << argv[0] << " [bind_ipv4] [port]\n";
        return 2;
    }

    const std::string bind_ip = argc >= 2 ? argv[1] : "0.0.0.0";

    try {
        const std::uint16_t port =
            argc >= 3 ? parse_port(argv[2]) : kDefaultPort;
        SocketPlatformSession socket_platform;
        SocketHandle socket_handle(
            socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP));
        if (socket_handle.get() == kInvalidSocket) {
            throw std::runtime_error("socket failed: " +
                                     std::to_string(last_socket_error()));
        }

        const int receive_buffer_bytes =
            configure_receive_buffer(socket_handle.get());
        configure_receive_timeout(socket_handle.get());

        sockaddr_in local_address{};
        local_address.sin_family = AF_INET;
        local_address.sin_port = htons(port);
        if (inet_pton(AF_INET, bind_ip.c_str(), &local_address.sin_addr) != 1) {
            throw std::runtime_error("invalid bind IPv4 address: " + bind_ip);
        }
        if (bind(socket_handle.get(),
                 reinterpret_cast<const sockaddr*>(&local_address),
                 sizeof(local_address)) == kSocketError) {
            throw std::runtime_error("bind failed: " +
                                     std::to_string(last_socket_error()));
        }
        install_stop_handler();

        std::cout << "Listening on " << bind_ip << ':' << port
                  << "; receive buffer=" << receive_buffer_bytes
                  << " bytes; press Ctrl+C to stop\n";

        std::array<std::uint8_t, 65535> buffer{};
        std::optional<std::uint32_t> previous_sequence;
        std::uint64_t received_packets = 0;
        std::uint64_t received_bytes = 0;
        std::uint64_t discontinuities = 0;
        std::uint64_t ignored_packets = 0;
        const auto receive_started = std::chrono::steady_clock::now();
        auto last_rate_report = receive_started;
        std::uint64_t reported_bytes = 0;
        std::uint64_t reported_packets = 0;
        std::uint64_t reported_discontinuities = 0;

        while (!stop_is_requested()) {
            const auto now = std::chrono::steady_clock::now();
            const auto report_elapsed = now - last_rate_report;
            if (report_elapsed >= kRateReportInterval) {
                const double report_seconds =
                    std::chrono::duration<double>(report_elapsed).count();
                const std::uint64_t interval_bytes =
                    received_bytes - reported_bytes;
                const std::uint64_t interval_packets =
                    received_packets - reported_packets;
                const std::uint64_t interval_discontinuities =
                    discontinuities - reported_discontinuities;
                const double interval_mib_per_second =
                    static_cast<double>(interval_bytes) / kBytesPerMiB /
                    report_seconds;
                const double interval_packets_per_second =
                    static_cast<double>(interval_packets) / report_seconds;

                std::cout << "Rate=" << std::fixed << std::setprecision(2)
                          << interval_mib_per_second << " MiB/s packets="
                          << interval_packets_per_second
                          << "/s discontinuities=" << discontinuities
                          << " (+" << interval_discontinuities << ")\n"
                          << std::flush;
                last_rate_report = now;
                reported_bytes = received_bytes;
                reported_packets = received_packets;
                reported_discontinuities = discontinuities;
            }

            const receive_result_type received = receive_datagram(
                socket_handle.get(), buffer.data(), buffer.size());

            if (received == kReceiveError) {
                const int error = last_socket_error();
                if (is_receive_retry_error(error)) {
                    continue;
                }
                throw std::runtime_error("recvfrom failed: " +
                                         std::to_string(error));
            }

            if (received < static_cast<receive_result_type>(kHeaderLength) ||
                !has_benchmark_magic(buffer.data())) {
                ++ignored_packets;
                continue;
            }

            const std::uint32_t sequence =
                read_be32(buffer.data() + kSequenceOffset);
            ++received_packets;
            received_bytes += static_cast<std::uint64_t>(received);

            if (previous_sequence.has_value()) {
                const std::uint32_t expected = *previous_sequence + 1U;
                if (sequence != expected) {
                    ++discontinuities;
                    report_discontinuity(discontinuities, expected, sequence);
                }
            }
            previous_sequence = sequence;
        }

        const auto elapsed = std::chrono::steady_clock::now() - receive_started;
        const double elapsed_seconds =
            std::chrono::duration<double>(elapsed).count();
        const double receive_mib_per_second = elapsed_seconds > 0.0
            ? static_cast<double>(received_bytes) / kBytesPerMiB /
                  elapsed_seconds
            : 0.0;
        std::cout << "Received=" << received_packets
                  << " bytes=" << received_bytes
                  << " discontinuities=" << discontinuities
                  << " ignored=" << ignored_packets
                  << " rate=" << std::fixed << std::setprecision(2)
                  << receive_mib_per_second << " MiB/s\n";
        return discontinuities == 0 ? 0 : 1;
    } catch (const std::exception& error) {
        std::cerr << "Error: " << error.what() << '\n';
        return 2;
    }
}
