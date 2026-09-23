#ifndef RRDMA_INCLUDE_RRDMA_TRANSPORT_HPP_
#define RRDMA_INCLUDE_RRDMA_TRANSPORT_HPP_

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>
#include <string>

#include "rrdma/result.hpp"

// 控制面抽象：库只依赖 datagram 收发，便于注入测试通道或代理链路。
namespace rrdma {

class DatagramChannel {
 public:
  // 多态析构允许应用注入自有 UDP/代理实现。
  virtual ~DatagramChannel() = default;
  // 发送一份完整 RDCP datagram；返回实际字节数或结构化错误。
  virtual Outcome<std::size_t> Send(
      std::span<const std::byte> bytes) noexcept = 0;
  // 在给定超时时间内接收一份 datagram，超时不等同于协议错误。
  virtual Outcome<std::size_t> Receive(
      std::span<std::byte> buffer,
      std::chrono::milliseconds timeout) noexcept = 0;
};

struct UdpChannelConfig {
  // 默认实现绑定指定 netdev，避免控制包从错误的 RoCE 接口发出。
  // SO_BINDTODEVICE 使用的 Linux 接口名。
  std::string netdev;
  // bind 使用的 Host IPv4。
  std::string local_ipv4;
  // connect 使用的 FPGA IPv4 和 UDP 端口。
  std::string remote_ipv4;
  std::uint16_t remote_port{4792U};
};

class UdpChannel final : public DatagramChannel {
 public:
  // 创建并连接一个非阻塞等待可控的 UDP 控制通道。
  static Outcome<std::unique_ptr<UdpChannel>> Create(
      const UdpChannelConfig &config) noexcept;
  ~UdpChannel() override;

  UdpChannel(const UdpChannel &) = delete;
  UdpChannel &operator=(const UdpChannel &) = delete;

  // 将控制请求交给已连接 socket。
  Outcome<std::size_t> Send(std::span<const std::byte> bytes) noexcept override;
  // 使用 poll 有界等待控制响应。
  Outcome<std::size_t> Receive(
      std::span<std::byte> buffer,
      std::chrono::milliseconds timeout) noexcept override;

 private:
  explicit UdpChannel(int socket_fd) noexcept : socket_fd_(socket_fd) {}
  int socket_fd_{-1};
};

}  // namespace rrdma

#endif  // RRDMA_INCLUDE_RRDMA_TRANSPORT_HPP_
