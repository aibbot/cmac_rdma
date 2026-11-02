# cmac_rdma

面向 RFSoC 的 100G CMAC / RoCEv2 RDMA 工程，目标器件为 `xczu47dr-fsvg1517-1-i`。FPGA 通过 RoCEv2 WRITE 将数据写入 Linux 主机的环形缓冲区，通过 UDP 控制协议 RDCP v2 管理会话和归还消费 credit。

当前板级数据路径由 SystemVerilog 实现，配套独立的 Vivado 构建脚本、仿真回归、Linux `libibverbs` 接收器和可复用的 C++20 主机库。

## 功能与范围

- 单 QP RoCEv2 WRITE，支持 ACK/NAK、ICRC 校验及有界重传恢复。
- 默认使用 1 GiB 主机环形缓冲区、10 MiB 逻辑 WR 和 commit 间隔；主机消费后归还 credit，FPGA 在覆盖未读数据前暂停。
- RDCP 完成发现、配置、启动、停止、状态查询和消费确认；正常 STOP 等待最终 commit 和安全释放状态后再销毁 QP/MR。
- 板级集成保留 ARP/ICMP、全局 PAUSE / PFC 优先级 0，以及 ILA/VIO 调试功能。
- `rdma_transport_ip` 提供可复用的 512-bit AXI-Stream 接口，用于集成外部数据源。

本工程实现的是单 QP 发送端点，功能边界见 [RDMA 说明](rdma/README.md)。外部 payload 路径当前采用单槽 stop-and-wait：每帧固定 4096 字节，收到对应 ACK 后才能接收下一帧。持续吞吐测试使用内部生成 payload 的 benchmark 路径，不能据此推断外部数据输入的持续吞吐能力。

`rdma/hls` 是隔离的第三方 Vitis HLS 实验，普通板级 RDMA bitstream 构建不需要运行 HLS。

## 目录

| 路径 | 用途 |
| --- | --- |
| `cmac_usplus_0_ex.xpr` | Vivado 2025.2 原始 CMAC 示例工程 |
| `cmac_usplus_0_ex.srcs/` | 原始工程源文件及 CMAC、GT、时钟、VIO 等 IP 配置 |
| `imports/` | 板级 wrapper、辅助 RTL、约束及调试集成 |
| `rdma/rtl/` | RDMA / RDCP 自定义 SystemVerilog 源码和约束 |
| `rdma/scripts/` | 板级 bitstream 构建、可移植 IP 打包和检查脚本 |
| `rdma/tests/` | RDMA SystemVerilog 测试与回归入口 |
| `rdma/host/` | Linux 主机库、接收器、测试及 RoCE 诊断脚本 |
| `rdma/hls/` | 独立 HLS 实验流程 |
| `rdma/build/` | 自动生成的工程、报告、仿真和发布产物，不纳入 Git |
| `tests/`、`tools/` | 原有 CMAC / UDP 测试和主机工具 |
| `docs/` | 主机端 C++ 开发规范 |

## 构建 FPGA bitstream

以下 FPGA 构建和仿真命令在 Windows 的仓库根目录执行。安装 Vivado、目标器件支持及所需 IP，并将选定版本的 `vivado.bat` 加入 PATH；仿真命令还需要 PowerShell 7（`pwsh`）。

```sh
git clone https://github.com/aibbot/cmac_rdma.git
cd cmac_rdma
```

### Vivado 版本

| 入口 | 支持版本 | 输出目录 |
| --- | --- | --- |
| 根目录 `cmac_usplus_0_ex.xpr` | 2025.2 | 原始 CMAC 示例工程 |
| `rdma/scripts/build_rdma_bitstream.tcl` | 2025.2 | `rdma/build/` |
| `rdma/scripts/build_rdma_bitstream.tcl` | 2024.2 | `rdma/build/2024.2/` |

在只有 Vivado 2024.2 的电脑上，使用 RDMA 构建脚本。脚本读取源 XCI 配置，再通过本机 IP Catalog 重新生成兼容的 CMAC、GT、时钟和 VIO IP。不要直接用 2024.2 打开 2025.2 的 `.xpr`，也不要通过删除 XCI 的 `checksum` 字段来处理 JSON schema 报错。两个版本的构建产物分别存放。

### 完整构建

在 PowerShell 中执行：

```powershell
$vivado = (Get-Command vivado.bat -ErrorAction Stop).Source
& $vivado -version

& $vivado -mode batch -nolog -nojournal `
    -source .\rdma\scripts\build_rdma_bitstream.tcl -tclargs impl
if ($LASTEXITCODE -ne 0) {
    throw "RDMA build failed: $LASTEXITCODE"
}
```

同时安装多个版本时，将 `$vivado` 设为所选版本的 `vivado.bat` 绝对路径。`impl` 一次完成工程创建、IP 生成、综合、实现、检查和 BIT/LTX 发布。脚本固定使用 `general.maxThreads=8` 和 run-level `-jobs 8`。

脚本也支持以下诊断阶段，将命令中的 `impl` 替换为相应值即可：

| 参数 | 执行范围 |
| --- | --- |
| `setup` | 创建隔离工程并生成 IP |
| `synth` | 创建工程并运行综合及综合后检查 |
| `impl` | 完整构建并发布 bitstream |

每次调用都会重新创建该版本对应的 RDMA 工程；这三个阶段不是增量接续。运行前关闭占用相同输出目录的 Vivado 任务。Tcl Shell 用法和从干净目录重建的步骤见 [快速开始](rdma/QUICK_START.md)。

### 产物与检查

成功构建后，在所选版本的输出目录中检查：

| 文件 | 用途 |
| --- | --- |
| `rdma_top.bit` | FPGA 配置文件 |
| `rdma_top.ltx` | 与 BIT 配对的调试探针文件 |
| `rdma_top.manifest.txt` | 构建标识、工具版本、Git 状态、源文件及产物 SHA-256 |
| `rdma_timing_summary.rpt` | Setup / hold 时序报告 |
| `rdma_utilization.rpt` | 当前构建资源使用报告 |
| `rdma_cdc.rpt`、`rdma_drc.rpt`、`rdma_route_status.rpt` | CDC、DRC 和路由检查报告 |

脚本在 setup/hold Slack 非负，并通过时钟覆盖、bus skew、CDC、DRC、路由和调试核心等检查后才发布产物。使用同一次构建的 BIT、LTX 和 manifest；板上 `rdma_vio/probe_in29` 的 build tag 应与 manifest 一致。需要指定构建标识时，在启动 Vivado 前设置八位十六进制的环境变量 `RDMA_BUILD_TAG`。

构建检查通过后，仍需按实际主机、链路和板卡完成会话与数据完整性验收。

## RTL 仿真

使用与构建一致的 Vivado 工具目录：

```powershell
$vivadoBin = Split-Path -Parent $vivado

pwsh -File .\rdma\tests\run_endpoint_tests.ps1 -VivadoBin $vivadoBin
if ($LASTEXITCODE -ne 0) { throw "Endpoint tests failed: $LASTEXITCODE" }

pwsh -File .\rdma\tests\run_admission_tests.ps1 -VivadoBin $vivadoBin
if ($LASTEXITCODE -ne 0) { throw "Admission tests failed: $LASTEXITCODE" }
```

入口支持 Vivado 2024.2 和 2025.2，仿真日志按版本保存在 `rdma/build/sim/` 下。Endpoint 回归覆盖 RDCP、配置检查、ACK/NAK、ICRC、外部 payload、重传、流量控制、AXI-Stream、CDC 和恢复等路径；admission 入口执行其独立的定时器缩放测试。

## Linux 主机接收

主机需要支持 RoCEv2 的 RDMA 网卡、Linux、C++20 编译器、CMake 3.20 或更新版本，以及 `libibverbs` 开发包。以下命令在 Linux 的仓库根目录执行。

### 编译与单元测试

以 Debian / Ubuntu 为例：

```sh
sudo apt install build-essential cmake pkg-config rdma-core libibverbs-dev

cmake -S rdma/host -B rdma/host/build -DCMAKE_BUILD_TYPE=Release
cmake --build rdma/host/build --parallel

# 主机库 C++ 单元测试
ctest --test-dir rdma/host/build --output-on-failure -R '^rrdma_tests$'
```

构建生成 `rrdma` 静态库和 `rdma_ring_receiver`。应用也可以使用导出的 `rrdma::core` CMake target 集成会话库。

### 运行前准备

- 将专用 RoCE netdev 配置为 `192.168.17.10/24`、MTU 至少 9000，并确认对应 RDMA 端口 active、具有匹配的 IPv4 RoCEv2 GID、支持 PMTU 4096。
- 默认使用显式 2 MiB hugetlb 页。一个接收器需要至少 513 个空闲页（1026 MiB），包含 1 GiB 数据环和独立 commit 记录；默认不会回退到普通页。
- 为进程配置足够的锁页额度以注册 1 GiB + 64 字节 MR，并提供绑定 netdev 所需的权限（`CAP_NET_RAW` 或 root）。
- 烧录同次构建的 BIT/LTX，按链路部署配置 PAUSE/PFC。主机准备、NUMA 和诊断命令见 [主机端说明](rdma/host/README.md)。

### 启动接收器

将 `irdma0` 和 `ens8np0` 替换为本机对应的 RDMA 设备和 netdev：

```sh
./rdma/host/build/rdma_ring_receiver \
    --device irdma0 \
    --netdev ens8np0 \
    --fpga-ip 192.168.17.11 \
    --seconds 60 \
    --verify-on-exit
```

接收器自动完成 RDCP 配置和启动，消费已提交的数据并归还 credit。`--seconds 60` 在 60 秒后请求正常 STOP；也可通过 `Ctrl+C` 请求停止。`--verify-on-exit` 在正常安全关闭后复扫最新的环形窗口。

板级验收应检查最终 commit、安全释放状态，以及 `discontinuities=0`、`invalid=0`、`overruns=0`，并运行足够长的会话以覆盖多次环回绕。详细验收要求见 [RDMA 说明](rdma/README.md)。

## 默认网络与会话参数

| 项目 | 默认值 |
| --- | --- |
| FPGA MAC | `02:00:00:00:00:01` |
| FPGA IPv4 | `192.168.17.11` |
| 主机 IPv4 | `192.168.17.10/24` |
| RoCEv2 UDP 端口 | `4791` |
| RDCP UDP 端口 | `4792` |
| FPGA QPN | `1` |
| RDMA PMTU | `4096` 字节 |
| 主机环大小 | `1 GiB` |
| 逻辑 WR / commit 间隔 | `10 MiB` / `10 MiB` |
| Immediate | 默认关闭 |

这些是当前板级产品配置；主机 QPN、MR 地址和 rkey 等资源由每次会话动态创建，通过 RDCP 下发。

## 文档与开发

| 文档 | 内容 |
| --- | --- |
| [快速开始](rdma/QUICK_START.md) | 完整重建、Tcl Shell、发布物检查及可选 HLS 流程 |
| [RDMA 说明](rdma/README.md) | 协议、会话、commit、恢复机制和可移植 IP 接口 |
| [架构说明](rdma/ARCHITECTURE.md) | 模块边界与数据路径 |
| [主机端说明](rdma/host/README.md) | 主机库集成、部署、接收器参数和链路诊断 |
| [第三方说明](rdma/THIRD_PARTY_NOTICES.md) | 第三方依赖及许可说明 |
| [工程约定](AGENTS.md) | RTL 时序规则和代码修改要求 |

复用传输 IP 时，通过 `rdma/scripts/package_rdma_transport_ip.tcl` 打包，再运行 `check_rdma_transport_ip_package.tcl` 和 `check_rdma_transport_ip_ooc.tcl` 检查；具体命令和集成边界见上述文档。

新增或改造的自定义 RTL 与测试使用 SystemVerilog（`.sv`），保留供应商生成的 Verilog 文件。提交前运行受影响的测试、检查 diff，并保留无关修改。
