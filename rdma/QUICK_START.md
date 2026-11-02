# RDMA Quick Start

本文档说明如何在删除 `rdma/build` 后重新生成板级 RDMA bitstream、验证可移植 IP、构建 Linux 主机程序，以及在确实需要时重建独立的 HLS 实验。

## 先看结论

- `rdma/build` 是纯生成物目录。删除它不会删除权威 RTL、约束、测试或根目录厂商 IP 源文件。
- 当前板级数据路径是自定义 SystemVerilog。板级 bitstream 构建不读取 `rdma/hls`，因此普通板级重构和重新烧写不需要先构建 HLS。
- `rdma/hls` 是独立的 Vitis HLS/OOC 流程。只有需要重新生成 `rocev2` HLS 导出、复核 HLS OOC 时序，或明确要研究该独立 IP 时才运行它。它不是当前板级 `rdma_top` 的输入。
- `rdma/build` 删除后，HLS 导出、IP package、仿真日志、Vivado 工程、报告、BIT/LTX 和 manifest 都会消失；需要的那一类流程要重新生成对应产物。
- 新 BIT/LTX 必须与同一次构建的 manifest 和 VIO `BUILD_TAG` 配对。不能用旧 `.bit` 配新 `.ltx`，也不能只看文件时间判断板上版本。

## 目录职责

| 路径                                            | 是否必需       | 作用                                                                               |
| ----------------------------------------------- | -------------- | ---------------------------------------------------------------------------------- |
| `rdma/rtl`                                      | 是             | 自定义 SystemVerilog 权威源文件                                                    |
| `imports`                                       | 是             | 板级集成使用的 vendor example wrapper、约束和自定义辅助 RTL；不改 vendor 生成 `.v` |
| `rdma/scripts/build_rdma_bitstream.tcl`         | 是             | 创建隔离 Vivado 工程并完成 setup/synthesis/implementation                          |
| `rdma/scripts/package_rdma_transport_ip.tcl`    | IP 集成时      | 打包可移植 `rdma_transport_ip`                                                     |
| `rdma/tests`                                    | 验证时         | Vivado 2024.2/2025.2 SystemVerilog 回归和结构门禁                                  |
| `cmac_usplus_0_ex.xpr`、`cmac_usplus_0_ex.srcs` | 是             | 根目录 vendor 工程及 CMAC/GT/clock/VIO `.xci` 输入                                 |
| `rdma/build`                                    | 否，自动生成   | Vivado 工程、仿真、报告、IP package、HLS/OOC 结果和发布物                          |
| `rdma/hls`                                      | 板级路径不需要 | HLS 脚本、锁定依赖清单和 patch                                                     |
| `rdma/third_party/fpga-network-stack`           | 仅 HLS 需要    | 按 `fpga_network_stack.lock.json` 锁定的 HLS 依赖；缺失时脚本会 clone              |
| `rdma/host`                                     | 主机运行时需要 | Linux `libibverbs` 接收器和诊断脚本                                                |

## 1. 环境准备

以下命令在仓库根目录的 **PowerShell** 中执行。先确认当前位置：

```powershell
Get-Location
Test-Path .\cmac_usplus_0_ex.xpr
Test-Path .\cmac_usplus_0_ex.srcs\sources_1\ip\cmac_usplus_0\cmac_usplus_0.xci
Test-Path .\cmac_usplus_0_ex.srcs\sources_1\ip\cmac_usplus_0_gt\cmac_usplus_0_gt.xci
Test-Path .\cmac_usplus_0_ex.srcs\sources_1\ip\clk_wiz_0\clk_wiz_0.xci
Test-Path .\cmac_usplus_0_ex.srcs\sources_1\ip\vio_0\vio_0.xci
```

RDMA 板级构建脚本支持 Vivado **2025.2** 或 **2024.2**，目标器件为 `xczu47dr-fsvg1517-1-i`。根目录原始 `.xpr` 由 2025.2 保存，不能直接在 2024.2 中打开。将 `vivado.bat` 加入 PATH，或将下面的 `$vivado` 改为实际安装路径：

```powershell
$vivado = (Get-Command vivado.bat -ErrorAction Stop).Source
& $vivado -version
```

2024.2 下脚本会读取原始 XCI 配置、用本机 IP Catalog 重建 CMAC/GT/clock/VIO IP，并写入 `rdma/build/2024.2`；2025.2 仍写入 `rdma/build`。不需要修改源 XCI 或复用另一版本生成的 IP 输出。`rdma/hls/build_rocev2_hls.ps1` 和 `rdma/hls/build_rocev2_ooc.ps1` 仍使用 2025.2 安装路径，这项兼容仅适用于 RDMA bitstream 脚本。

关闭正在使用同一输出目录的 Vivado Hardware Manager/批处理任务。脚本会创建独立的 RDMA 工程，不会修改根目录的 UDP vendor 工程；2024.2 与 2025.2 的输出目录互不覆盖。

## 2. 删除 build 并重建板级 bitstream

### 2.1 安全清理

只删除明确的生成目录，不要删除 `rdma/rtl`、`rdma/scripts`、`rdma/tests` 或根目录 `cmac_usplus_0_ex.srcs`：

```powershell
$buildDirectory = (Resolve-Path .\rdma).Path + '\build'
if (Test-Path -LiteralPath $buildDirectory) {
    Remove-Item -LiteralPath $buildDirectory -Recurse -Force
}
Test-Path -LiteralPath $buildDirectory
```

最后一条应输出 `False`。清理不会影响根目录 vendor IP；脚本后续会从这些 `.xci` 重新导入并执行 `generate_target`。

### 2.2 一条命令完成 setup、综合、实现和发布

对正常的完整构建，直接运行 `impl`：

```powershell
& $vivado -mode batch -nolog -nojournal `
    -source .\rdma\scripts\build_rdma_bitstream.tcl -tclargs impl
if ($LASTEXITCODE -ne 0) {
    throw "RDMA implementation failed with exit code $LASTEXITCODE"
}
```

### 2.3 在 Vivado Tcl Shell 中运行

如果已经打开 **Vivado 2024.2 或 2025.2 Tcl Shell**，不能直接输入
`build_rdma_bitstream.tcl` 或 `./build_rdma_bitstream.tcl`；这会被当作操作系统命令。使用 `source` 加载脚本，并通过 `::argv` 传入 stage：

```tcl
cd F:/work/rfsoc/fpga/hw/cmac_usplus
set ::argv [list impl]
source {F:/work/rfsoc/fpga/hw/cmac_usplus/rdma/scripts/build_rdma_bitstream.tcl}
```

上面命令会完成 setup、综合、实现并生成 BIT/LTX/manifest。Windows 路径建议在 Tcl 中使用正斜杠 `/`，并用 `{}` 包住路径，避免反斜杠被 Tcl 当作转义字符。

分阶段运行时，每次使用新的 Tcl Shell：

```tcl
set ::argv [list setup]
source {F:/work/rfsoc/fpga/hw/cmac_usplus/rdma/scripts/build_rdma_bitstream.tcl}
```

```tcl
set ::argv [list synth]
source {F:/work/rfsoc/fpga/hw/cmac_usplus/rdma/scripts/build_rdma_bitstream.tcl}
```

```tcl
set ::argv [list impl]
source {F:/work/rfsoc/fpga/hw/cmac_usplus/rdma/scripts/build_rdma_bitstream.tcl}
```

脚本的 `setup` 和 `synth` 分支结束时会调用 `exit`；正常生成 bitstream 时直接在一个 Tcl Shell 中运行一次 `impl` 即可。

`impl` 会在一次 Vivado 会话中完成以下步骤：

1. 新建隔离工程：2025.2 使用 `rdma/build/vivado_rdma`，2024.2 使用 `rdma/build/2024.2/vivado_rdma`。
2. 导入 `imports`、`rdma/rtl`、根目录 CMAC/GT/clock/VIO `.xci` 和 `rdma/rtl/rdma_project.xdc`。
3. 固定 `general.maxThreads=8`、综合 worker=1、debug helper=1、run-level `-jobs=8`。
4. 运行 `rdma_synth_1`，检查自定义 CDC、Gray counter、reset synchronizer、build-tag probe 和 in-context IP 配置。
5. 运行 opt/place/phys-opt/route，应用 17 条逐路径 legacy debug CDC waiver，并执行时序、bus skew、CDC、DRC、route、high-fanout、control-set、logic-level、methodology 和资源基线门禁。
6. 只有全部门禁通过后，才发布 BIT/LTX 和 manifest。

### 2.4 分阶段调试

脚本支持 `setup`、`synth`、`impl` 三个 stage：

```powershell
& $vivado -mode batch -nolog -nojournal `
    -source .\rdma\scripts\build_rdma_bitstream.tcl -tclargs setup

& $vivado -mode batch -nolog -nojournal `
    -source .\rdma\scripts\build_rdma_bitstream.tcl -tclargs synth

& $vivado -mode batch -nolog -nojournal `
    -source .\rdma\scripts\build_rdma_bitstream.tcl -tclargs impl
```

注意：每次调用都会重新创建当前 Vivado 版本对应的 RDMA 工程，所以这三条命令不是增量接续；它们适合定位 setup 或 synthesis 问题。要获得 BIT/LTX，最终仍需执行 `impl`，而且通常只执行一次 `impl` 即可。

如需可重复的 build tag，在启动 Vivado 前设置八位十六进制值：

```powershell
$env:RDMA_BUILD_TAG = '6AB48E1B'
& $vivado -mode batch -nolog -nojournal `
    -source .\rdma\scripts\build_rdma_bitstream.tcl -tclargs impl
Remove-Item Env:RDMA_BUILD_TAG -ErrorAction SilentlyContinue
```

不设置时，脚本使用构建启动时的 Unix 时间生成 tag。

## 3. 构建完成后的检查

以下路径对应 2025.2；使用 2024.2 时，将 `rdma/build` 换成 `rdma/build/2024.2`。两版的 BIT/LTX/manifest 不能混用。

成功发布后应至少存在：

```powershell
Get-ChildItem .\rdma\build\rdma_top.*
Get-ChildItem .\rdma\build\rdma_*.rpt
```

关键文件：

- `rdma/build/rdma_top.bit`
- `rdma/build/rdma_top.ltx`
- `rdma/build/rdma_top.manifest.txt`
- `rdma/build/rdma_timing_summary.rpt`
- `rdma/build/rdma_cdc.rpt`
- `rdma/build/rdma_drc.rpt`
- `rdma/build/rdma_route_status.rpt`
- `rdma/build/rdma_utilization.rpt`
- `rdma/build/rdma_high_fanout.rpt`

manifest 会记录 build tag、Vivado 版本、Git 状态、源文件哈希、BIT/LTX 大小和 SHA-256、报告哈希及 CDC waiver 哈希。核对摘要：

```powershell
$manifest = '.\rdma\build\rdma_top.manifest.txt'
Select-String -Path $manifest -Pattern '^(build_tag|vivado_version|git_dirty|bit\.sha256|ltx\.sha256)='

Get-FileHash .\rdma\build\rdma_top.bit -Algorithm SHA256
Get-FileHash .\rdma\build\rdma_top.ltx -Algorithm SHA256
```

不要只凭 `WNS` 或 bit 文件时间发布。应同时确认 manifest 与 BIT/LTX 的哈希一致，并在硬件 VIO `rdma_vio/probe_in29` 读取同一个 `build_tag`。

## 4. RTL 回归和可移植 IP 验证

板级实现前后都可以运行完整 SystemVerilog 回归；脚本会自己重建 `rdma/build/sim` 下的仿真目录：

```powershell
$vivadoBin = Split-Path -Parent $vivado
pwsh -File .\rdma\tests\run_endpoint_tests.ps1 -VivadoBin $vivadoBin
if ($LASTEXITCODE -ne 0) {
    throw 'RDMA endpoint regression failed'
}
```

该入口包含 transport IP 参数检查，以及 RDCP、ACK/NAK、ICRC、payload lifecycle、ring、replay、PAUSE、AXI backpressure、CDC helper、arbiter 和 recovery 测试。单独运行 timer/admission 检查：

```powershell
pwsh -File .\rdma\tests\run_admission_tests.ps1 -VivadoBin $vivadoBin
```

构建可移植 Vivado IP package，并在干净 consumer project 中检查参数和源文件哈希：

```powershell
& $vivado -mode batch -nolog -nojournal `
    -source .\rdma\scripts\package_rdma_transport_ip.tcl
if ($LASTEXITCODE -ne 0) {
    throw 'RDMA IP packaging failed'
}

& $vivado -mode batch -nolog -nojournal `
    -source .\rdma\scripts\check_rdma_transport_ip_package.tcl
if ($LASTEXITCODE -ne 0) {
    throw 'RDMA IP package check failed'
}
```

package 输出位于 `rdma/build/ip_repo/rdma_transport_ip_1_0`，其父目录可加入消费工程的 `ip_repo_paths`。它是生成物；权威源仍是 `rdma/rtl`。

运行 250 MHz OOC 实现门禁：

```powershell
& $vivado -mode batch -nolog -nojournal `
    -source .\rdma\scripts\check_rdma_transport_ip_ooc.tcl
if ($LASTEXITCODE -ne 0) {
    throw 'RDMA transport IP OOC gate failed'
}
```

OOC 报告在 `rdma/build/transport_ip_ooc/reports`。它验证可移植核心内部的时序、约束覆盖、利用率、high-fanout、control-set、logic-level、methodology、route 和 DRC；真实板级时钟树和边界路径仍以完整 bitstream implementation 为准。

## 5. HLS 是否需要，以及何时运行

### 板级 bitstream：不需要

`build_rdma_bitstream.tcl` 的 source list 是 `imports/*.v|*.sv`、`rdma/rtl/*.sv`、根目录 `.xci` 和 RDMA XDC；其中没有 `rdma/hls` 或 `rdma/third_party/fpga-network-stack`。因此：

- 删除 `rdma/build` 后重建当前板级 bitstream，不必先运行 HLS。
- HLS 生成的 `component.xml`、Verilog export 和 OOC DCP 不会被当前 `rdma_top` 自动接入。
- `rdma/ADMISSION_RESULT.md` 中的 HLS 结论是独立实验结论，不能替代板级 RTL/CMAC implementation 验收；当前 HLS 路径仍标注为独立、带风险且未作为板级集成路径。

### 独立 HLS 流程：需要时运行

`rdma/hls/build_rocev2_hls.ps1` 会：

1. 校验 Vitis 2025.2 和 `rdma/fpga_network_stack.lock.json`。
2. 使用锁定 commit；缺少 `rdma/third_party/fpga-network-stack` 时自动 clone。
3. 将依赖复制到 `rdma/build/hls/fpga-network-stack`，只在副本上应用 patch。
4. 运行 C-sim、HLS synthesis 和 IP export，并验证端口宽度及 4.00 ns 目标。

从删除 `rdma/build` 后重建 HLS：

```powershell
pwsh -File .\rdma\hls\build_rocev2_hls.ps1
if ($LASTEXITCODE -ne 0) {
    throw 'RoCEv2 HLS build failed'
}

pwsh -File .\rdma\tests\run_admission_tests.ps1 -VivadoBin $vivadoBin
if ($LASTEXITCODE -ne 0) {
    throw 'HLS admission/timer regression failed'
}

pwsh -File .\rdma\hls\build_rocev2_ooc.ps1
if ($LASTEXITCODE -ne 0) {
    throw 'RoCEv2 HLS OOC gate failed'
}
```

HLS 输出在 `rdma/build/hls`，OOC 输出在 `rdma/build/hls/ooc/reports`。`-SkipCsim` 只用于诊断，不能用来声称 HLS admission 通过。

如果只是重建板级 bitstream，不要因为 `rdma/build/hls` 不存在而先运行 HLS；这会增加不必要的构建时间和独立依赖。

## 6. Linux 主机程序

主机程序与 Vivado/HLS 分开，在 Linux 或 WSL 中构建。需要 C++20、CMake、`pkg-config`、`libibverbs`/`rdma-core` 和 `libibverbs-dev`：

```sh
ulimit -l unlimited
cmake -S rdma/host -B rdma/host/build -DCMAKE_BUILD_TYPE=Release
cmake --build rdma/host/build --parallel
ctest --test-dir rdma/host/build --output-on-failure
```

示例点到点配置和接收命令：

```sh
sudo ip link set dev ens8np0 down
sudo ip address flush dev ens8np0
sudo ip address add 192.168.17.10/24 dev ens8np0
sudo ip link set dev ens8np0 mtu 9000 up

./rdma/host/build/rdma_ring_receiver \
  --device rocep131s0 \
  --netdev ens8np0 \
  --fpga-ip 192.168.17.11 \
  --verify-on-exit \
  --seconds 10000
```

接收器默认启用 FPGA 重传路径；板上 `rdma_vio/probe_out0=1` 也表示 retransmission enabled。只有在专门做故障注入或对比实验时才置零，置零后 timeout、RNR 或可恢复 sequence NAK 会直接使会话失败而不启动 replay。

## 7. 烧写前后检查

烧写前：

1. 停止正在运行的接收器和流量。
2. 记录 manifest 的 `build_tag`、BIT/LTX SHA-256 和构建时间。
3. 只使用同一 `rdma/build` 目录中由同一次 `impl` 发布的 `.bit` 与 `.ltx`。
4. 保留上一份已知良好 BIT/LTX 作为回退，不覆盖它。

烧写后先在 Hardware Manager/VIO 核对：

- `rdma_vio/probe_in29` 等于 manifest 的 `build_tag`；
- `rdma_vio/probe_out0=1`，确认默认开启重传；
- `configured/session_state/fault/fault_reason` 处于可接受的空闲状态。

再启动主机接收器。通信异常时优先确认 BIT/LTX/tag 是否一致；不要把旧 bit 的 sticky fault、旧 LTX 探针或旧 host 进程状态归因于新 RTL。PAUSE/PFC 根因检查应在版本匹配且 CONFIG/START 正常后进行，并同时记录 host 的 XOFF/XON 和 FPGA 的 PAUSE 计数器。

## 8. 常见错误

| 现象                                                   | 首先检查                                                                                         |
| ------------------------------------------------------ | ------------------------------------------------------------------------------------------------ |
| `IP_Flow 19-8166` / `checksum`                           | 2024.2 正在读取 2025.2 XCI；从仓库根目录运行 RDMA 构建脚本，不要直接打开根目录 `.xpr`             |
| `Vendor IP source is missing`                          | 根目录 `cmac_usplus_0_ex.srcs/sources_1/ip/*/*.xci` 是否存在；不要把它们和 `rdma/build` 一起清掉 |
| HLS OOC 报 `Exported HLS Verilog directory is missing` | 先完成 `build_rocev2_hls.ps1`，再运行 `build_rocev2_ooc.ps1`                                     |
| `FPGA CONFIG rejected`                                 | 先读 manifest/VIO build tag，再检查是否仍烧着旧 BIT/LTX；确认上一会话是否留下 sticky fault       |
| VIO 出现 `<const>` 或探针错位                          | BIT 与 LTX 必须来自同一次 impl；重新下载匹配的 `.ltx`，不要复用旧 probes 文件                    |
| 删除 build 后想继续旧 Vivado run                       | 不能继续；`rdma/build/vivado_rdma` 已被删除，重新执行 `impl`                                     |

## 9. 最短可复制流程

只需要重建当前板级 bitstream 时，使用下面的最短流程：

```powershell
$vivado = (Get-Command vivado.bat -ErrorAction Stop).Source

& $vivado -mode batch -nolog -nojournal `
    -source .\rdma\scripts\build_rdma_bitstream.tcl -tclargs impl
if ($LASTEXITCODE -ne 0) {
    throw "RDMA bitstream build failed: $LASTEXITCODE"
}

$vivadoBin = Split-Path -Parent $vivado
pwsh -File .\rdma\tests\run_endpoint_tests.ps1 -VivadoBin $vivadoBin
if ($LASTEXITCODE -ne 0) {
    throw 'RTL regression failed'
}

Get-Content .\rdma\build\rdma_top.manifest.txt  # 2024.2: .\rdma\build\2024.2\rdma_top.manifest.txt
```

完成上述流程只说明新产物通过脚本定义的仿真/实现门禁；它不等于板卡已经烧写，也不等于 host/CMAC 实测或 PAUSE/PFC 丢包根因已经消除。板级结论必须在匹配 tag 的 BIT/LTX 烧写后重新取得。
