#include <arpa/inet.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <limits>
#include <new>
#include <utility>

#include "rrdma/transport.hpp"
#include "unique_fd.hpp"

namespace rrdma {
namespace {

[[nodiscard]] Error SocketError(ErrorCode code, const char *operation) {
  // 在 errno 被其他系统调用覆盖前保存并格式化 socket 错误。
  const int error_number = errno;
  return MakeError(code,
                   std::string{operation} + ": " + std::strerror(error_number),
                   error_number);
}

} // namespace

Outcome<std::unique_ptr<UdpChannel>> UdpChannel::Create(const UdpChannelConfig &config) noexcept {
  // 控制面绑定指定 netdev，数据面仍由 verbs QP 承担；这里仅建立 RDCP
  // UDP/4792 通道，不在数据热路径执行阻塞操作。
  in_addr local{};
  in_addr remote{};
  if (::inet_pton(AF_INET, config.local_ipv4.c_str(), &local) != 1
      || ::inet_pton(AF_INET, config.remote_ipv4.c_str(), &remote) != 1) {
    return Failure<std::unique_ptr<UdpChannel>>(
      MakeError(ErrorCode::kInvalidConfiguration,
                "control channel IPv4 address is invalid"));
  }
  const auto max_netdev_length =
    static_cast<ByteCount>(std::numeric_limits<socklen_t>::max());
  if (config.netdev.size() >= max_netdev_length) {
    return Failure<std::unique_ptr<UdpChannel>>(MakeError(
      ErrorCode::kInvalidConfiguration, "control netdev name is too long"));
  }
  const auto netdev_length =
    static_cast<socklen_t>(config.netdev.size() + 1U);

  detail::UniqueFd socket_fd{
    ::socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0)};
  if (socket_fd.Get() < 0) {
    return Failure<std::unique_ptr<UdpChannel>>(
      SocketError(ErrorCode::kSystemError, "socket"));
  }
  if (::setsockopt(socket_fd.Get(), SOL_SOCKET, SO_BINDTODEVICE,
                   config.netdev.c_str(),
                   netdev_length)
      != 0) {
    return Failure<std::unique_ptr<UdpChannel>>(
      SocketError(ErrorCode::kSystemError, "SO_BINDTODEVICE"));
  }

  sockaddr_in local_address{};
  local_address.sin_family = AF_INET;
  local_address.sin_addr = local;
  if (::bind(socket_fd.Get(), reinterpret_cast<const sockaddr *>(&local_address),
             sizeof(local_address))
      != 0) {
    return Failure<std::unique_ptr<UdpChannel>>(
      SocketError(ErrorCode::kSystemError, "bind"));
  }

  sockaddr_in remote_address{};
  remote_address.sin_family = AF_INET;
  remote_address.sin_port = htons(config.remote_port);
  remote_address.sin_addr = remote;
  if (::connect(socket_fd.Get(), reinterpret_cast<const sockaddr *>(&remote_address),
                sizeof(remote_address))
      != 0) {
    return Failure<std::unique_ptr<UdpChannel>>(
      SocketError(ErrorCode::kSystemError, "connect"));
  }

  auto channel = std::unique_ptr<UdpChannel>(
    new (std::nothrow) UdpChannel(socket_fd.Get()));
  if (!channel) {
    return Failure<std::unique_ptr<UdpChannel>>(
      MakeError(ErrorCode::kAllocationFailed, "cannot allocate UDP channel"));
  }
  (void)socket_fd.Release();
  return channel;
}

UdpChannel::~UdpChannel() {
  // fd 所有权仅属于 UdpChannel，注入的 DatagramChannel 不经过这里。
  if (socket_fd_ >= 0) {
    (void)::close(socket_fd_);
  }
}

Outcome<ByteCount> UdpChannel::Send(std::span<const std::byte> bytes) noexcept {
  // UDP datagram 必须完整发送，短写按传输错误处理。
  constexpr auto kMaxSendBytes =
    static_cast<ByteCount>(std::numeric_limits<ssize_t>::max());
  if (bytes.size() > kMaxSendBytes) {
    return Failure<ByteCount>(MakeError(
      ErrorCode::kInvalidConfiguration,
      "control datagram is too large for the send ABI"));
  }
  const auto expected = static_cast<ssize_t>(bytes.size());
  const auto sent = ::send(socket_fd_, bytes.data(), bytes.size(), 0);
  if (sent == expected) {
    return static_cast<ByteCount>(sent);
  }
  if (sent < 0) {
    return Failure<ByteCount>(
      SocketError(ErrorCode::kTransportError, "send"));
  }
  return Failure<ByteCount>(
    MakeError(ErrorCode::kTransportError, "short control datagram send"));
}

Outcome<ByteCount> UdpChannel::Receive(std::span<std::byte> buffer,
                                       std::chrono::milliseconds timeout) noexcept {
  // 用 poll 实现有界等待，便于 HELLO/STATUS/恢复循环响应 stop 和超时。
  if (buffer.empty()) {
    return Failure<ByteCount>(
      MakeError(ErrorCode::kInvalidConfiguration, "empty receive buffer"));
  }
  constexpr auto kMaxReceiveBytes =
    static_cast<ByteCount>(std::numeric_limits<ssize_t>::max());
  if (buffer.size() > kMaxReceiveBytes) {
    return Failure<ByteCount>(MakeError(
      ErrorCode::kInvalidConfiguration,
      "control receive buffer is too large for the receive ABI"));
  }
  pollfd descriptor{};
  descriptor.fd = socket_fd_;
  descriptor.events = POLLIN;
  const auto bounded_timeout = std::clamp<std::int64_t>(
    timeout.count(), 0, std::numeric_limits<int>::max());
  const int poll_result =
    ::poll(&descriptor, 1, static_cast<int>(bounded_timeout));
  if (poll_result == 0) {
    return Failure<ByteCount>(
      MakeError(ErrorCode::kTimeout, "control receive timeout"));
  }
  if (poll_result < 0) {
    if (errno == EINTR) {
      return Failure<ByteCount>(
        MakeError(ErrorCode::kTimeout, "control receive interrupted"));
    }
    return Failure<ByteCount>(
      SocketError(ErrorCode::kTransportError, "poll"));
  }
  if ((descriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
    return Failure<ByteCount>(MakeError(ErrorCode::kTransportError,
                                        "control socket reported an error"));
  }
  if ((descriptor.revents & POLLIN) == 0) {
    return Failure<ByteCount>(MakeError(ErrorCode::kTransportError,
                                        "control socket is not readable"));
  }
  const auto received = ::recv(socket_fd_, buffer.data(), buffer.size(), 0);
  // connected UDP socket 只接收已配置 FPGA 地址/端口返回的数据报。
  if (received < 0) {
    if (errno == EINTR) {
      return Failure<ByteCount>(
        MakeError(ErrorCode::kTimeout, "control receive interrupted"));
    }
    return Failure<ByteCount>(
      SocketError(ErrorCode::kTransportError, "recv"));
  }
  if (received == 0) {
    return Failure<ByteCount>(
      MakeError(ErrorCode::kTransportError, "empty control datagram"));
  }
  return static_cast<ByteCount>(received);
}

} // namespace rrdma
