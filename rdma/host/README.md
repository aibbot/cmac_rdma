# Linux RDMA 环形会话

`rdma_ring_receiver` 负责一个带流量控制的 RDMA 采集会话的完整生命周期。
它通过 RDCP 发现 FPGA，创建并注册主机资源，配置并启动 FPGA，在需要时请求正常停止，
等待最终 commit 和安全释放状态，最后才销毁 QP 和 MR。
产品流程不包含 VIO 操作，也不复制参数块。

## 库集成

已安装的 `rrdma::core` target 提供只能使用一次的 `Session`。调用线程是会话协调线程；
生产者和消费者工作在线程库拥有的独立线程中运行，因此应用处理不会执行在
commit/CQ 轮询循环内：

```cpp
auto receiver = rrdma::Session::Create(config);
auto report = receiver.Value()->Run(
    stop_source.get_token(),
    rrdma::CommitCallback::Bind(consumer), dependencies);
```

`CommitBatch` 包含稳定的 `CommitMetadata` 快照，以及唯一一个不拥有数据的 `data` span。
库将同一组环形页映射两次到连续的虚拟地址范围，因此跨越物理环边界的 batch
对应用仍然是连续的。span 只在 `OnCommit` 期间有效；回调返回即允许库发送累计的
`CONSUME`，并最终允许 FPGA 重用该范围。需要延长数据所有权的应用，必须在返回前将数据
复制或移动到自己的存储中。

每个工作线程内部都会调用 `Dependencies::thread_start`，并传入
`ThreadRole::kProducer` 或 `ThreadRole::kConsumer`。应用可以使用这个不拥有对象、
`noexcept` 的钩子分别设置 CPU 亲和性、调度策略、NUMA 策略或线程名。协调线程就是调用
`Run` 的线程，因此其位置仍由应用控制。钩子对象、消费者、事件接收器、注入的数据报通道，
以及应用提供的后备文件描述符，都必须持续有效到 `Run` 返回。

库接受可选的本地 IPv4、掩码要求、显式 GID 索引、替代的时序和轮询策略，以及用于 NUMA
放置的应用所有共享文件后备。裸外部指针无法支持所需的零拷贝双重映射，因此
`MemoryConfig` 改为接受文件描述符和页对齐偏移。

默认的 `MemoryPageMode::kHugeTlb` 创建一个私有的 2 MiB `MFD_HUGETLB` memfd。
它不会回退到透明大页或普通页：hugetlb 池缺失或容量不足时返回分配错误。
应用提供的描述符必须指向使用配置页大小的 hugetlbfs，并且从配置偏移开始覆盖
`AlignUp(ring_bytes + 64, huge_page_bytes)` 字节。`MemoryPageMode::kRegular` 是明确的
开发/测试选项，不会设置透明大页提示。

协议几何仍按 4096 字节对齐；hugetlb 模式还要求环和后备偏移按 `huge_page_bytes` 对齐。
如果省略本地 IPv4 或掩码，将从选定的 netdev 发现匹配值。示例 CLI 明确提供产品默认值
`192.168.17.10` 和 `255.255.255.0`；这些值不是可复用库的硬编码要求。

## 主机准备

使用专用的点到点 RoCE 端口。启动接收器前配置 IPv4 地址和 MTU：

```sh
sudo ip link set dev ens8np0 down
sudo ip address flush dev ens8np0
sudo ip address add 192.168.17.10/24 dev ens8np0
sudo ip link set dev ens8np0 mtu 9000 up
```

除非选定的 netdev 已启动、地址为 `192.168.17.10/24` 且 MTU 不小于 9000，否则示例 CLI
会拒绝它。进程启动时链路载波可能仍在建立；10 秒的 HELLO 窗口会等待链路就绪。
创建 QP 前，匹配的 libibverbs 端口必须处于 active 状态，为该 netdev 提供 IPv4 映射的
RoCEv2 GID，并支持 PMTU 4096。

启动接收器前预留显式的 2 MiB hugetlb 页。默认 1 GiB 环使用 512 页，固定的 64 字节
commit 记录从下一页开始，因此一个接收器至少需要 513 个空闲页（1026 MiB）。两个
虚拟环别名引用同样的 512 个数据页，不会使物理分配翻倍。NUMA 绑定部署还要同时检查
选定节点和全局的空闲数量：

```sh
grep -E 'HugePages_(Total|Free|Rsvd)|Hugepagesize' /proc/meminfo
cat /sys/devices/system/node/node1/hugepages/hugepages-2048kB/free_hugepages
```

通过主机的启动/内核策略配置页池；在专用测试主机上也可以执行
`sudo sysctl -w vm.nr_hugepages=513`。为每个并发接收器及其他 hugetlb 用户额外预留页。

诊断丢包和 PFC 时，应在同一 Linux 主机上采集运行前及运行期间的 NIC/DCB/verbs 计数器。
采样器不会修改设备配置：

```sh
bash rdma/host/collect_roce_snapshot.sh --netdev ens8np0 --device rocep131s0 \
  --samples 120 --interval 5 > roce-diagnostics.txt 2>&1
```

要在同一时间窗口内简洁检查 E810 流量控制活动，可在接收器旁运行以下命令，并观察
VIO 探针 10 至 15：

```sh
set -o pipefail
bash rdma/host/watch_roce_flow_control.sh --netdev ens8np0 \
  --interval 1 --samples 120 2>&1 | tee roce-flow-control.txt
```

每行包含绝对计数值；第一条样本后标记为 `baseline`，后续为相对上一条样本的增量，
计数值减少后则标记为 `reset`。`link_xoff_tx.nic` 是全局 PAUSE/XOFF 发送计数器；
`tx_priority_0_xoff.nic` 是 PFC 优先级 0 发送计数器。不要将这些增量与其他 bitstream
或其他时间窗口的 VIO 快照比较。

每条样本包含时间戳、完整的 `ethtool -S` 输出、驱动、FEC、NIC 环和暂停设置、DCB
PFC/应用/ETS 映射、内核 netdev 统计，以及两个 RDMA 计数器区段。
当 `nak_count` 上升时采集 VIO 快照，并与前后主机样本比较。重点查看入口丢弃、PFC TX、
FEC 不可纠正错误和 QP 重试；缺少工具或不支持的计数器区段会明确报告，不会静默解释为零。
只有端口 1 的 GID 与选定 netdev 关联时，才采集端口 1 的 RDMA 计数器。仅凭序列 NAK
无法确定数据包在哪一侧丢失。应比较同一时间戳区间内的计数器*增量*，不要比较无关运行的
绝对值。修改 PFC 设置前先确认优先级映射；当前 FPGA 数据包未打标签，IPv4 DSCP 为零。
启用流量控制后再次运行采样器，确认暂停帧确实发生交换。

### 直连 PAUSE 与 PFC 启动

先烧录匹配的 `.bit` 和 `.ltx`。FPGA 中 `cmac_flow_control_vio` 的
`probe_out0` 选择接收流量控制类别：

| `probe_out0` | 模式 | 启用/请求/ACK 位 |
| --- | --- | --- |
| `0`（上电默认值） | IEEE 802.3x 全局 PAUSE | bit 8 |
| `1` | IEEE 802.1Qbb PFC 优先级 0 | bit 0 |

更改该输出前停止接收器和流量，并等待 `probe_in4`（`pause_active`）与
`probe_in7`（`pause_pending`）都变为零。其余输入为 request `[8:0]`、valid `[8:0]`、
enable `[8:0]`、ACK `[8:0]`、current-frame-active，以及原有的 selected-valid 事件计数。
在原有 8 个探针之后新增的诊断输入如下：

| 探针 | 信号 | 含义 |
| ---: | --- | --- |
| 8 | `stat_rx_pause` | 原始 CMAC PAUSE 指示 |
| 9 | `stat_rx_pause_quanta8[15:0]` | 当前全局 PAUSE 量 |
| 10 | `pause_frame_count[31:0]` | 饱和原始 PAUSE 指示计数 |
| 11 | `pause_valid8_count[31:0]` | 饱和全局 `valid[8]` 计数 |
| 12 | `pause_req8_rise_count[31:0]` | 饱和全局请求上升沿计数 |
| 13 | `pause_seen_sticky` | TX 复位后是否观察到原始 PAUSE |
| 14 | `pause_req8_seen_sticky` | TX 复位后是否观察到全局请求 |
| 15 | `last_pause_quanta8[15:0]` | 保留最近一次全局 `valid[8]` 指示中的量 |
| 16 | `rx_multicast_count[31:0]` | 饱和 CMAC 组播帧计数 |
| 17 | `rx_packet_64_count[31:0]` | 饱和 CMAC 64 字节帧计数 |
| 18 | `rx_total_packet_count[31:0]` | CMAC 总包增量的饱和累加计数 |
| 19 | `rx_user_pause_count[31:0]` | 饱和 CMAC 基于优先级的 PAUSE（PFC）指示计数 |

在隔离的直连链路上，先使用全局 PAUSE 做控制实验。由于拥塞位于主机 RX 侧且 FPGA
是发送方，先禁用 PFC，只启用主机 TX PAUSE：

```sh
sudo dcb pfc set dev ens8np0 \
  prio-pfc 0:off 1:off 2:off 3:off 4:off 5:off 6:off 7:off
sudo ethtool -A ens8np0 autoneg off rx off tx on
ethtool -a ens8np0
```

保持 `probe_out0=0`，启动采样器，再运行接收器。正常闭环应表现为主机
`link_xoff_tx.nic`/`link_xon_tx.nic` 增长、FPGA 请求/ACK 位 8 有活动、FPGA 事件计数
增长，且 `rx_dropped.nic` 保持不变。全局 PAUSE 生效时也会停止 RDCP、ARP 和 ICMP，
因此这里只将其作为直连基线。

完成全局测试后停止流量，切换到 PFC 优先级 0。当前 FPGA 帧未打标签且 DSCP 为零，
观察到的 ETS 映射将所有优先级发送到 TC0，因此通用厂商示例中的优先级 3 不适用：

```sh
sudo ethtool -A ens8np0 autoneg off rx off tx off
sudo dcb pfc set dev ens8np0 \
  prio-pfc 0:on 1:off 2:off 3:off 4:off 5:off 6:off 7:off
dcb pfc show dev ens8np0
dcb ets show dev ens8np0
```

空闲时将 `probe_out0=1`，然后重复同样的测试。这次应观察主机
`tx_priority_0_xoff.nic`/`tx_priority_0_xon.nic` 和 FPGA 位 0 的活动。保持序列重放启用，
同时比较 `nak_count`；PFC 可避免已知的入口缓冲丢包，重放则作为残余丢包的有界恢复机制。

### 余量预算

在 100 Gbit/s 下，链路每纳秒消耗 12.5 字节。应根据实测的“达到阈值到停止”的延迟
配置 NIC 无损接收余量，不要依据 `ethtool -g`：

```text
headroom >= 12.5 bytes/ns * (NIC PFC generation + cable + CMAC decode/gating)
            + 9600 bytes for the frame already in progress
            + safety margin
```

FPGA 在发送 ACK 并停止新帧之前，最多还会增加一个当前的 9600 字节 CMAC 帧（768 ns）。
下面的规划表按计算出的在途字节数增加 2 倍余量；应使用 NIC 和 FPGA 计数器测得的最坏
情况替换固定响应预算：

| 固定响应预算 | 包含一个帧的在途字节数 | 2 倍余量 |
| ---: | ---: | ---: |
| 1 us | 22,100 B | 44,200 B (43.2 KiB) |
| 2 us | 34,600 B | 69,200 B (67.6 KiB) |
| 4 us | 59,600 B | 119,200 B (116.4 KiB) |

观察到的 2048 个 RX descriptor 描述的是主机 DMA 环，不是 NIC 按优先级划分的端口缓冲
余量。同样，`dcb pfc ... delay 1949` 是 DCB 链路延迟参数，不是 1949 字节可用缓冲。
在将表中任一行作为最终设置前，应取得 ICE/NVM 的每 TC 缓冲阈值，或测量暂停阈值和响应
延迟。

安装 `rdma-core`、`libibverbs-dev`、CMake 和 C++20 编译器。进程还需要通过
`CAP_NET_RAW`（或 root）使用 `SO_BINDTODEVICE`，至少 513 个空闲的 2 MiB hugetlb 页，
以及锁定 1 GiB + 64 字节 MR 的权限：

```sh
ulimit -l unlimited
cmake -S rdma/host -B rdma/host/build -DCMAKE_BUILD_TYPE=Release
cmake --build rdma/host/build --parallel
ctest --test-dir rdma/host/build --output-on-failure
```

## 启动采集

只需指定 RDMA 设备和匹配的 netdev：

```sh
./rdma/host/build/rdma_ring_receiver \
  --device irdma0 \
  --netdev ens8np0
```

对于示例部署中已验证的主机名称，可使用以下定时运行方式：

```sh
numactl --cpunodebind=1 --membind=1 \
  ./rdma/host/build/rdma_ring_receiver \
  --device rocep131s0 \
  --netdev ens8np0 \
  --fpga-ip 192.168.17.11 \
  --verify-on-exit \
  --seconds 10000
```

FPGA 地址默认为 `192.168.17.11`。产品几何参数固定为 1 GiB 环、10 MiB 逻辑 WR、
10 MiB commit 间隔、本地基址为零、QPN 1，以及累计主机消费流量控制。Immediate 默认关闭。
FPGA 会在可能覆盖未读数据之前暂停，接收器验证已提交范围并发送 RDCP `CONSUME` 后再恢复。

常用可选参数如下：

| 选项 | 作用 |
| --- | --- |
| `--fpga-ip IPv4` | 覆盖默认 FPGA 地址 |
| `--seconds N` | N 秒后请求正常 STOP |
| `--immediate` | 使用 WRITE_WITH_IMM commit 唤醒 |
| `--recv-depth N` | 设置 Immediate 模式的 posted receive 深度；默认为 1024 |
| `--verify-on-exit` | 成功前重新扫描已发布的 `RFSO` 头 |
| `--verbose-commits` | 打印每个 commit，而不是只打印最终 commit |

按线速生成 1 GiB 数据约需 86 ms。因此该缓冲区不是可存放 10,000 秒数据的存储器：
接收器必须以输入速率持续验证并释放数据。若接收器落后，FPGA 会在 1 GiB credit 限制处
停顿，而不是覆盖未读数据。`--seconds 10000` 现在表示 10,000 秒后请求正常 STOP，
而不是在第一次环边界处结束。

## 自动生命周期

1. 接收器将 UDP 控制流绑定到选定的 netdev，每 100 ms 发送一次 HELLO，持续最多 10 秒。
2. 检查 RDCP v2、FPGA QPN 1、PMTU 4096、所需能力，以及是否处于允许新配置的状态。
3. 为 1 GiB 环和 64 字节 commit 预留 513 个显式 2 MiB 页，仅注册协议可见的
   1 GiB + 64 字节可写 MR，创建 CQ 和 RC QP，选择新的非零 PSN，并将 QP 切换到 RTS。
4. 选择新的非零会话 ID 并发送 CONFIG。CONFIG 和 START 会对同一事务重试最多 3 秒。
5. 收到 READY 后发送 START。统计从第一个非零 commit 开始，以此建立测量基线。
6. 对每个新 commit（包括环或 credit 边界处短的物理消息屏障），验证所有新发布的
   `RFSO` 头，并在 `CONSUME` 中发送累计扫描字节数。FPGA 将该进度作为 credit，
   在不覆盖未读数据的情况下回绕远端环地址。
7. `SIGINT`、`SIGTERM` 或 `--seconds` 会发送 STOP。FPGA 完成当前逻辑 WR 并发布最终
   commit；关闭流程有 15 秒的正常收敛窗口。
8. 正常拆除必须同时满足最终 commit 和 RDCP `CLOSED + safe_to_release`。缺少任一项都
   表示会话失败。
9. 发生控制、RDMA、commit 或端点故障，或 STATUS 意外返回 `IDLE`、`CONFIGURING`、
   `READY` 时，接收器发送 ABORT 并等待 `FAULTED + safe_to_release`。故障路径绝不报告
   为成功采集，也不要求最终 commit。若 FPGA 不可达，进程会保持 QP/MR 存活，重试 ABORT
   和 STATUS，并每 15 秒打印一次警告；不会执行未经确认的拆除。

### 生产者/消费者执行模型

库使用三个角色，确保应用工作不会运行在 RDMA 轮询循环中：

- 生产者线程负责 commit/seqlock 轮询和 Immediate 模式的 CQ 轮询。它创建不拥有数据的
  `CommitBatch` 视图，并只将固定大小的 descriptor 发布到预分配的有界 SPSC 无锁队列。
- 消费者线程调用应用回调，验证或转换单个连续的环形 span，并仅在回调成功后发送累计的
  `CONSUME`。即使回调请求 `stop_after_consume`，它仍会持续排空直到最终 commit，确保
  FPGA 能安全到达 `CLOSED`。
- 协调线程负责 RDCP STATUS/STOP/ABORT 以及资源生命周期。

当已提交 batch 等待 `CONSUME` 时，周期性 STATUS 不会获取控制通道互斥锁；每个 CONSUME
响应已经携带完整的状态块。这样可以让 credit 返回优先于低频监控，避免缓慢的 STATUS
超时反复饿死消费者。

队列修改使用位于不同缓存行的无锁 64 位单调游标。队列为空时，消费者使用 C++20 atomic
wait 休眠，不需要互斥锁或条件变量。队列饱和会在 FPGA 环 credit 耗尽前向生产者施加
背压。队列中不复制任何 payload 字节，每个 span 仅在其回调调用期间有效；需要保留数据
的应用必须复制数据，或在返回前完成处理。

超时的 CONFIG 被视为结果不明确，因为 FPGA 可能已经接受配置但响应丢失。因此接收器在
结束本地 QP/MR 作用域前发送 ABORT。在 `IDLE`、`CLOSED` 或 `FAULTED` 状态下，这个安全
ABORT 可以替换未活动的旧会话绑定，确保恢复最终收敛。每次进程运行都会创建新的 QP/MR
和会话 ID；过期的 START 或 STOP 数据报无法控制它。

在轮询模式下，正确性依赖于 FPGA 在同一个 RC QP 上先写入环数据，再写入 64 字节 commit。
RC 顺序保证 release sequence 只有在之前的 payload 写入完成后才可见。主机先以 acquire
load 忙轮询对齐的 sequence，只有 sequence 变化后才读取其余 commit 字段，然后再次读取
sequence 两次确认后发布 batch。同一 sequence 下的元数据变化被视为正在进行的 commit
写入，而不是可发布的进度。WRITE_WITH_IMM 使用相同的 commit 检查，并额外将 CQ 完成
作为唤醒事件，同时批量重新投递 RQE。

## 成功结果

每个 4096 字节数据包以 24 字节 `RFSO` 头开始。接收器在 commit 边界验证新发布的头，
并打印每秒 MiB/s、十进制 Gbit/s、包速率、commit 速率、不连续次数和无效头数量。
成功时的最终输出行必须包含：

```text
discontinuities=0 invalid=0 overruns=0
```

成功需要最终 commit 和 `CLOSED + safe_to_release`。零长度最终 commit 也是有效的协议进度，
包括它跟在一个没有推进 `published_bytes` 的早期数据 commit 后面这种情况。RFSO CLI 仍然
要求至少有一个已发布的基准数据包；`--verify-on-exit` 还会在 FPGA 停止后扫描最新的、
大小等于环容量的已发布范围。

此流程假设使用可信的、未打标签的点到点链路。VLAN、共享网络认证、多个 QP 以及无界的
丢包恢复不在当前版本范围内。FPGA 可在每个物理消息内回退最多 12 个序列错误 NAK，
并重放收到 NAK 的 commit。仍建议启用 PAUSE/PFC：恢复预算耗尽会使会话进入故障，
而要持续无损采集，主机扫描和下游处理必须跟上数据源。环 credit 可防止内存损坏，
但主机较慢时可能暂停采集。
