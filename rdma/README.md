# 100G RoCEv2 Module

This directory contains two isolated paths for the planned 100G RoCEv2 RDMA WRITE endpoint. The third-party HLS source is locked by `fpga_network_stack.lock.json`, copied into `build`, patched there, and never modified in place. Its admission is **PASS WITH RISK**, but it remains **NO-GO** as the board data path because it does not yet produce or validate standards-compliant IPv4 RoCEv2 ICRC traffic and its schedule is II=2 rather than II=1. `ADMISSION_RESULT.md` records that decision and its evidence.

The board path is the independent SystemVerilog endpoint in `rtl/`, its dedicated `sources_rdma`/`rdma_synth_1`/`rdma_impl_1` flow, and the Linux receiver in `host/`. It reuses the AMD CMAC IP but does not modify vendor-generated Verilog or the original UDP build. Each 4096-byte RDMA data packet starts with the UDP benchmark's 24-byte `RFSO` header and big-endian sequence, allowing the host to validate continuity at commit publication boundaries and print per-second throughput statistics.

The endpoint keeps two compile-time modes. The default mode is the deterministic first-board-debug implementation: it builds a replay image and permits one unacknowledged packet at a time. The board endpoint enables `FAST_BENCHMARK_MODE`: it constructs one 512-bit beat per 250 MHz cycle, computes ICRC across the accepted beat, and sends all data packets in one publication interval without waiting between packets. Data packets clear BTH `AckReq`; the following commit packet sets `AckReq` and its matching ACK is the ordered completion barrier for the interval. A data-phase NAK is latched and faults the run after the current AXIS frame completes. A commit timeout retransmits only the commit packet and faults after `MAX_RETRIES` is exhausted. This controlled benchmark mode detects an incomplete interval but does not replay missing data packets.

## Vivado build

Build this design with Vivado 2025.2. The RDMA flow fixes
`general.maxThreads` and synthesis run `-jobs` to 8, while keeping
`synth.maxThreads` and `chipscope.maxJobs` at 1.
Implementation runs directly in the controller process, keeping the Windows
Vivado process count at or below three even while dynamic debug cores are
synthesized by `opt_design`. The flow requires all eight debug cores to be
present with no remaining black boxes before placement. `RDMA_BUILD_JOBS` may
be unset or set to `8`; every other value is rejected. The script also aborts if
another `vivado.exe` is already running before setup, synthesis, or
implementation. Do not open another Vivado GUI or batch process while this
build is active.

```powershell
$env:RDMA_BUILD_JOBS = '8'
& 'D:\Xilinx\2025.2\Vivado\bin\vivado.bat' -mode batch `
  -source rdma/scripts/build_rdma_bitstream.tcl -tclargs impl
```

## Ring notification and Immediate

The RTL endpoint publishes a 64-byte commit record after each configured amount
of acknowledged ring data. `cfg_notify_interval_bytes` is the amount in bytes:
it must be nonzero, 4096-byte aligned, and no larger than `cfg_ring_size`.
The RDMA VIO default is `0x00100000` (1 MiB); use `0x00A00000` for 10 MiB.
The value is sampled only when `apply` is asserted while the endpoint is
drained, so changing a VIO field cannot split an active session unexpectedly.

`cfg_enable_immediate=0` sends the commit with `RDMA_WRITE_ONLY`, which lets
Linux poll the commit record. `cfg_enable_immediate=1` sends the same ordered
commit with `RDMA_WRITE_ONLY_WITH_IMM`; the Immediate Data is the low 32 bits
of `producer_sequence`. The host must post and replenish receive WQEs before
enabling this mode and consume `IBV_WC_RECV_RDMA_WITH_IMM` completions. In both
modes Linux treats the 64-bit release sequence at commit-record offset 40 as
authoritative, then performs an acquire/read barrier before consuming the
published ring range. The event is a wake-up, not the ownership record.

The little-endian commit record is: `published_bytes` at offset 0,
`ring_end_offset` at 8, `interval_bytes` at 12, `final` at 16, magic
`0x52444D41` at 20, and the release `producer_sequence` at 40. The sequence
is after all metadata in wire order so the polling path has an explicit
publication marker.

`cfg_commit_remote_addr` is the non-overlapping, 64-byte-aligned location of
that record in the same writable MR as the ring. It must not be zero or overlap
`[cfg_remote_base, cfg_remote_base + cfg_ring_size)`. A 1 GiB ring therefore
needs an MR with a separate 64-byte commit area, commonly immediately after the
ring allocation.

The RDMA VIO retains its existing probe numbering and appends the new fields:

| VIO direction | Probe | Meaning |
| --- | ---: | --- |
| output | 16 | `cfg_enable_immediate` |
| output | 17 | `cfg_notify_interval_bytes` (`0x00100000` = 1 MiB, `0x00A00000` = 10 MiB) |
| output | 18 | `cfg_commit_remote_addr[47:0]` |
| output | 19 | `cfg_allow_ring_wrap` (default `0`) |
| input | 18 | `commit_count` |
| input | 19 | `immediate_count` |
| input | 20 | `published_bytes` |
| input | 21 | `producer_sequence` |
| input | 22 | `config_reject_reason` (latched Apply validation bitmask) |

`config_reject_reason` bits are latched when an Apply is rejected and cleared by
`clear_stats` or a subsequent successful Apply:

| Bit | Meaning |
| ---: | --- |
| 0 | endpoint was not drained when Apply was asserted |
| 1 | forced remote MAC is zero (or learned MAC is unavailable when force is off) |
| 2 | local QPN is zero |
| 3 | local QPN is greater than 255 |
| 4 | remote QPN is zero |
| 5 | both configured and learned remote IP are zero |
| 6 | ring size is zero |
| 7 | WR size is zero |
| 8 | ring size is not 4096-byte aligned |
| 9 | WR size is not 4096-byte aligned |
| 10 | WR size is larger than ring size |
| 11 | local base is not 8-byte aligned |
| 12 | notification interval is zero |
| 13 | notification interval is not 4096-byte aligned |
| 14 | notification interval is larger than ring size |
| 15 | commit address is zero |
| 16 | commit address is not 64-byte aligned |
| 17 | ring end address overflows the 48-bit address space |
| 18 | commit record end address overflows the 48-bit address space |
| 19 | commit record overlaps the ring range |

At a notification boundary the endpoint terminates the current physical RDMA
message, then sends the commit on the same RC QP before starting the next
range. The bring-up mode waits for each preceding data ACK. The fast benchmark
mode relies on RC ordering and waits for the commit ACK, which cumulatively
confirms the preceding interval. This makes 1 MiB and 10 MiB exact publication
boundaries even when a logical WR would otherwise cross one.

`cfg_allow_ring_wrap=0` is the default first-board-debug mode. On reaching the
last byte of the ring, the endpoint stops submitting data, writes one final
commit, and drains before it can overwrite byte zero. This makes a 1 GiB ring
safe for finite capture and verification. Setting `cfg_allow_ring_wrap=1`
restores circular overwrites, but is only appropriate for controlled
diagnostics: the current single-QP endpoint has no host-to-FPGA consumer-credit
channel, so it cannot prove that overwritten data was consumed. A continuous
lossless ring requires such a credit/cursor protocol before it can be claimed
as a production mode.

`host/rdma_ring_receiver` creates the E810-C-side RC QP, registered ring MR,
and separate commit area. Its JSON output maps the host QPN, PSNs, rkey,
remote address, interval, and Immediate option directly to the VIO fields.
It rejects ring, WR, and notification lengths that do not fit the FPGA's
32-bit VIO fields.
