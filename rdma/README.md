# 100G RoCEv2 Flow-Controlled Ring Endpoint

This directory contains the product RDMA path: a SystemVerilog single-QP
RoCEv2 WRITE endpoint, an in-PL UDP control plane, an isolated Vivado build,
and the Linux receiver. It does not modify vendor-generated Verilog. The older
third-party HLS experiment remains isolated from this board data path.

The product uses a 1 GiB host ring with explicit consumer credit. The FPGA
publishes committed ranges, pauses before overwriting unread data, and resumes
after RDCP `CONSUME` advances the host's cumulative consumed byte count. Ring
addresses wrap; counters remain cumulative. A normal STOP publishes a final
commit before the host releases its QP and MR.

## Product configuration

| Item | Value |
| --- | --- |
| FPGA MAC | `02:00:00:00:00:01` |
| FPGA IPv4 | `192.168.17.11` |
| Host IPv4 | `192.168.17.10/24` |
| RoCEv2 UDP port | `4791` |
| RDCP control UDP port | `4792` |
| FPGA QPN | `1` |
| PMTU | `4096` bytes |
| Ring | `0x40000000` bytes (1 GiB) |
| Logical WR | `0x00A00000` bytes (10 MiB) |
| Commit interval | `0x00A00000` bytes (10 MiB) |
| Local data base | `0` |
| Immediate | disabled by default |
| Ring wrap | enabled with host-consumption credit |

The MAC, FPGA address, QPN, PMTU, and buffer geometry are product constants.
Each receiver run creates a new RC QP and MR, chooses a nonzero random FPGA TX
PSN and session ID, and sends the host QPN, MR base, rkey, commit address, and
flags through RDCP. The FPGA learns the host MAC, IPv4 address, and UDP source
port from the accepted CONFIG frame.

`rdma_vio/probe_out0` controls retransmission and initializes to `1` (enabled).
Driving it low leaves the first transmission unchanged, but the next timeout,
RNR NAK, commit sequence NAK, or recoverable data sequence NAK faults the
session without starting replay. VIO cannot configure, start, stop, abort, or
clear a session. The existing ILA coverage remains available for diagnosis.

## Data and control paths

The registered RX classifier sends UDP/4791 ACK traffic to the RDMA endpoint,
UDP/4792 traffic to the RDCP parser, and drops all other traffic. The TX arbiter
selects only at AXI-Stream frame boundaries; control responses have priority
between RDMA frames and can never interleave with one.

### Portable IP integration

`rdma_transport_ip` is the stable integration boundary for an
external data producer. It is a single-clock, vendor-IP-free SystemVerilog
core with an active-low reset and three Vivado-recognized AXI-Stream
interfaces. `aresetn` may assert asynchronously; the wrapper releases its
internal reset only after four `aclk` rising edges. During reset, both slave
`tready` outputs, `cfg_ready`, and the master `tvalid` output are low.

| Interface | Direction | Contract |
| --- | --- | --- |
| `S_AXIS_PAYLOAD` | into the core | application bytes to transmit |
| `S_AXIS_RX` | into the core | received RoCEv2 ACK/NAK Ethernet frames |
| `M_AXIS_TX` | out of the core | complete RoCEv2 Ethernet frames |

All three interfaces are 512 bits wide. Packet byte 0 is `tdata[7:0]` and is
qualified by `tkeep[0]`. `tvalid` and every payload signal must remain stable
while `tready` is low. `tuser=1` marks the complete input frame erroneous.

The native configuration handshake exposes local/remote network identity,
QPN/PSN, remote address, rkey, ring size, logical WR size, notification
interval, commit address, Immediate enable, external-payload selection, and
cumulative consumed bytes. `cfg_valid` is accepted only with `cfg_ready`; the
result is returned by the one-cycle `cfg_done`/`cfg_accepted` event. START,
STOP, and ABORT are synchronous one-cycle request strobes. `tx_path_idle` must
describe the complete downstream transmit path, not only `M_AXIS_TX`, so
recovery and safe drain cannot overtake data buffered outside the core.

The external-payload mode currently accepts exactly one 4096-byte frame: 64
full-width beats, all `tkeep` bits set, and `tlast` on beat 64. An early/late
`tlast`, sparse `tkeep`, or `tuser` discards that frame and increments
`payload_error_count`. A beat-level builder copies the payload into the replay
packet RAM, calculates ICRC through registered stages, and presents the first
TX beat within 96 `aclk` cycles. Timeout and RNR retries read that frozen packet
image and are byte-identical even though the payload RAM is a separate block.
The payload slot remains occupied until the corresponding data ACK, so a second
payload is not accepted while the first is outstanding. This single-slot
stop-and-wait path is a functional integration path, not yet a sustained
97 Gbps application ingress. The original generated-payload benchmark remains
the throughput path.

`payload_accepted_count` and `payload_error_count` are saturating lifetime
counters. They reset only with `aresetn`, not on CONFIG, START, STOP, or ABORT.
A normal STOP drains a complete or partially accepted payload before the final
commit. ABORT may discard the current payload; such a discard increments
`payload_error_count` exactly once.

`BUILD_TAG` is a 32-bit IP parameter exposed unchanged on the read-only
`build_tag` output. Integrators should assign it from their build identifier
and record it with the bitstream and probes file. The board build also exposes
its build tag as `rdma_vio/probe_in29`; set `RDMA_BUILD_TAG` to eight hexadecimal
digits to override the default Unix-time tag for a reproducible release build.

Vivado rejects invalid build-time timer, retry, recovery, and local-QPN values
in the customization UI; the RTL repeats those checks during elaboration so a
scripted instantiation cannot bypass the Catalog constraints. All cycle-count
parameters are measured on `aclk`. `ACLK_FREQ_HZ` also drives the IP-XACT clock
metadata. Changing it in the customization UI refreshes the editable defaults
for `ACK_TIMEOUT_CYCLES` (1 ms) and `RNR_TIMER_10US_CYCLES` (10 us); either
cycle count may then be overridden for a specific deployment. Set the clock
frequency first and timer overrides second. The board-qualified setting is
250 MHz; another frequency requires fresh timing closure.

The surrounding hierarchy stays intentionally separate:

- `rdma_transport_core`: native config, payload buffering, RoCEv2
  packetization, ACK/NAK handling, replay, credit, commit, and counters.
- `rdma_config_manager`: atomic config capture, validation,
  accepted-field ownership, and reject diagnostics.
- `rdma_ack_receiver`: RoCEv2 ACK/NAK frame capture, header and
  ICRC validation, and parsed response events.
- `rdma_network_core`: raw Ethernet classifier, RDCP v2 control,
  the transport core, and frame-boundary control/data arbitration.
- `rdma_board_endpoint`: board clocks, reset synchronization,
  async FIFOs, drain tracking, ARP/ICMP sharing, VIO, and ILA only.

The packaged `debug_state` output is a stable lifecycle code rather than an
internal packetizer FSM value:

| Code | Meaning |
| ---: | --- |
| `0` | reset |
| `1` | unconfigured |
| `2` | configured and ready |
| `3` | running |
| `4` | stopping |
| `5` | fault |

`fault_reason` is zero when no endpoint fault is latched. Defined nonzero
values are `0x00000002` retry budget exhausted after RNR or commit sequence
NAK, `0x00000003` fatal or unsupported NAK, `0x00000004` ACK-timeout retry
budget exhausted, `0x00000005` retransmission disabled when retry was needed,
`0x00000101` sequence NAK outside the recoverable message,
`0x00000102` sequence-recovery budget exhausted, `0x00000103` fatal/unknown
NAK during message recovery, `0x00000201` missing or wrong-size external
payload, and `0x80000001` explicit ABORT.

`config_reject_reason` is a bit mask captured with a rejected CONFIG. Bits
`0..19` mean: endpoint not drained, zero remote MAC, reserved, reserved, zero
remote QPN, zero remote IP, zero ring size, zero WR size, unaligned ring size,
unaligned WR size, WR larger than ring, unaligned local base, zero notification
interval, unaligned notification interval, notification interval larger than
ring, zero commit address, unaligned commit address, remote range overflow,
commit range overflow, and commit/ring overlap. Higher bits are reserved.

RDCP accepts only complete, error-free, untagged Ethernet frames containing
IPv4 with IHL 5, no fragmentation, the fixed local destination address, valid
IPv4 and UDP checksums, and UDP destination port 4792. A CMAC `tuser` error,
including one asserted only with `tlast`, discards the whole frame.

### RDCP v2

Every field is in network byte order. The 20-byte request header is:

| Offset | Bytes | Field |
| ---: | ---: | --- |
| 0 | 4 | magic `0x52444350` (`RDCP`) |
| 4 | 1 | version `2` |
| 5 | 1 | opcode |
| 6 | 2 | payload length |
| 8 | 8 | session ID |
| 16 | 4 | transaction ID |

Opcodes are `HELLO=1`, `CONFIG=2`, `START=3`, `STOP=4`, `ABORT=5`,
`STATUS=6`, and `CONSUME=7`. A response sets bit 7 of the request opcode.
`CONSUME` has an 8-byte payload containing the cumulative consumed byte count.
It must be monotonic, 4096-byte aligned, and no greater than the FPGA's
published byte count.

CONFIG has a fixed 56-byte payload: remote QPN, FPGA TX PSN, remote MR base,
rkey, ring size, WR size, notification interval, local base, commit address,
flags, and reserved. Flag bit 0 enables Immediate. Flag bit 1 and every
reserved bit must be zero.

Every response has a fixed 64-byte status payload containing result, state,
reason, status bits, local QPN, current PSN, configuration generation,
issued/acked/published/consumed byte counters, capabilities, and PMTU. The
status bits also report a credit stall. Result codes distinguish malformed
input, wrong source/session, old transactions, busy state, invalid
configuration, invalid state, and invalid consumption progress. Capability bit
3 advertises bounded sequence-error recovery; the host rejects an older image
that does not provide it.

The first valid CONFIG binds its source MAC/IPv4/UDP port and session ID.
Retransmitting the latest transaction returns the cached response without
executing it again. Older transactions, another source, or another session are
rejected explicitly.

## Session lifecycle

The normal state path is:

```text
IDLE -> CONFIGURING -> READY -> RUNNING -> STOPPING -> CLOSED
```

The fault path is:

```text
READY/RUNNING/STOPPING -> FAULT_QUIESCING -> FAULTED
```

On CONFIG acceptance the endpoint atomically loads a registered configuration,
clears every per-session counter and scheduler state, and grants one ring of
initial credit. START is accepted only in READY. Each data packet reserves
credit before entering the TX pipeline. A reliable commit closes every physical
RDMA message and makes its data visible. It is normally 10 MiB, but can be a
shorter 4 KiB-aligned range at a ring or credit boundary. After the host
validates that range, `CONSUME` returns the corresponding credit. At zero credit
the endpoint remains RUNNING but sends no more data. A normal STOP finishes the
current logical WR, publishes a possibly short final commit, waits for its ACK,
invalidates the configuration, and enters CLOSED only after the RDMA TX path is
empty.

The streaming data path handles up to 12 AETH sequence-error NAKs (`0x60`) per
physical message. The NAK PSN is treated as the responder's next expected PSN;
the scheduler first stops at an AXI frame boundary and waits for the board TX
FIFO and CMAC pipeline to drain. A short response-quiet window coalesces
duplicate NAKs caused by packets that were already buffered beyond the gap.
The scheduler then rewinds its registered message checkpoint and regenerates
that packet through the end of the message without charging ring credit or byte
counters twice. The following commit is an ACK barrier, so the checkpoint also
covers loss of the last packet before a ring wrap. A sequence NAK for the commit
PSN replays the already buffered commit. Recovery outside the current message,
exhausting the bounded data-recovery budget, and fatal/unknown NAKs quiesce with
fault reasons `0x101`, `0x102`, and `0x103`, respectively.

ABORT or an endpoint fault stops at the current AXI-Stream frame boundary,
discards pending work, drains the TX path, invalidates the configuration, and
enters FAULTED. This path does not promise a final commit. `safe_to_release` is
asserted only in CLOSED or FAULTED, so a new session always requires a new
QP/MR and session ID. A nonzero safety ABORT may replace an inactive binding in
IDLE, CLOSED, or FAULTED; this lets an ambiguous lost CONFIG response converge
without allowing a stale command to affect a running session.

The host treats an unexpected active-session STATUS of IDLE, CONFIGURING, or
READY, or any asserted fault bit, as a failed session and starts ABORT recovery.
A requested STOP starts a 15-second deadline for final commit plus CLOSED/safe
convergence.

## Commit record

The FPGA writes a 64-byte little-endian commit record outside the ring:

| Offset | Field |
| ---: | --- |
| 0 | cumulative `published_bytes` (64 bit) |
| 8 | ring end offset (32 bit) |
| 12 | interval bytes (32 bit) |
| 16 | final flag (32 bit) |
| 20 | magic `0x52444D41` (32 bit) |
| 40 | release `producer_sequence` (64 bit) |

The release sequence is authoritative. The host reads it with acquire
semantics before consuming metadata or ring data. WRITE_WITH_IMM is an optional
wake-up only; it does not replace the commit record. The read-only VIO exposes
the last NAK syndrome and PSN, cumulative sequence recovery count, and current
replay-active state in addition to the existing session counters.

The isolated RDMA build enables CMAC RX flow control while leaving CMAC TX flow
control disabled. A final-frame-boundary gate responds to either global PAUSE
(default, CMAC request bit 8) or PFC priority 0 (request bit 0), completes an
already-started frame, blocks every transmit source before the next frame, and
then acknowledges the CMAC request. `cmac_flow_control_vio` selects the mode and
exposes request, valid, enable, ACK, active/pending/frame state, and a saturating
event count. Additional saturating counters retain raw `stat_rx_pause`, global
`valid[8]`, and global `req[8]` rising-edge activity; sticky flags and the last
global PAUSE quanta distinguish a received MAC control frame from a request that
reached the transmit gate. Additional multicast, 64-byte, total-packet, and
priority-based PAUSE (PFC) counters distinguish a rejected MAC-control frame
from one that did not reach the CMAC. Existing sequence replay remains enabled
above this link-level backpressure.

## Build and test

The complete from-clean procedure, including the distinction between the
board-level SystemVerilog path and the optional HLS experiment, is documented
in [`QUICK_START.md`](QUICK_START.md). In particular, deleting `rdma/build` is
safe; the normal board build does **not** require `rdma/hls`.

For the board bitstream, use Vivado 2025.2 or 2024.2 and run the implementation
stage once from the repository root. Point `$vivado` to the selected version's
`vivado.bat`:

```powershell
$vivado = (Get-Command vivado.bat -ErrorAction Stop).Source
& $vivado -mode batch -nolog -nojournal `
  -source rdma/scripts/build_rdma_bitstream.tcl -tclargs impl
```

The script creates the isolated `rdma/build/vivado_rdma` project with 2025.2,
or `rdma/build/2024.2/vivado_rdma` with 2024.2. It recreates 2024.2-compatible
vendor IP from the source XCI configurations; do not open the 2025.2 project
file directly in 2024.2. The script runs setup,
synthesis, implementation, and all signoff gates in that invocation. The
`setup` and `synth` stages remain available for diagnosis; each invocation
recreates the isolated project, so they are not incremental continuations.

`impl` checks setup and hold slack, clock coverage, bus skew, DRC, route
completeness, debug cores, and required CDC structures before publishing the
`.bit` and `.ltx` pair. It also writes
`rdma/build/rdma_top.manifest.txt` (under `rdma/build/2024.2` for 2024.2), which records the VIO build
tag, Vivado version, Git state, source hashes, final BIT/LTX SHA-256 digests,
and hashes for the generated signoff reports. Resource utilization is retained
as the current-build `rdma_utilization.rpt`; no checked-in baseline or resource
comparison gate is required. Program only a BIT/LTX pair whose manifest and
VIO tag agree.

Run the complete SystemVerilog regression with:

```powershell
pwsh -File rdma/tests/run_endpoint_tests.ps1
```

Package the portable core for Vivado's IP Catalog with:

```powershell
& 'D:\Xilinx\2025.2\Vivado\bin\vivado.bat' -mode batch -nolog -nojournal `
  -source rdma/scripts/package_rdma_transport_ip.tcl

& 'D:\Xilinx\2025.2\Vivado\bin\vivado.bat' -mode batch -nolog -nojournal `
  -source rdma/scripts/check_rdma_transport_ip_package.tcl
```

The generated repository root is
`rdma/build/ip_repo/rdma_transport_ip_1_0`; add its parent
directory to `ip_repo_paths` in the consuming project. Generated packaging
output is disposable. The authoritative sources remain under `rdma/rtl`. The
package includes this README as its Product Guide, the architecture note, and
a deterministic customization UI with grouped identity, timing/recovery, and
implementation parameters. The package check imports the generated repository
into a clean consumer project, requires SHA-256 identity between all ten
packaged RTL files and their authoritative `rdma/rtl` sources, verifies
frequency-derived timer defaults, manual timer overrides, and benchmark-mode
customization, and generates an instantiation template.

Run the standalone 250 MHz out-of-context implementation check with:

```powershell
& 'D:\Xilinx\2025.2\Vivado\bin\vivado.bat' -mode batch -nolog -nojournal `
  -source rdma/scripts/check_rdma_transport_ip_ooc.tcl
```

Reports are written under `rdma/build/transport_ip_ooc/reports`. This check
forces `FAST_BENCHMARK_MODE=1` to match the deployed board instance and
requires nonnegative setup and hold slack on every internal synchronous path,
rejects missing clocks and unconstrained internal endpoints, and emits
hierarchical utilization, high-fanout, control-set, logic-level, methodology,
route, and DRC reports. Only package-pin I/O checks `NSTD-1`, `UCIO-1`, and
`RTSTAT-1` are waived for the intentionally pinless OOC boundary.
The OOC timing model uses the target device's `BUFGCE_X0Y168` clock source.
The route gate requires its single explicit gap to belong only to the
hierarchical `aclk` network and records the gap owner, clock source, timing,
constraint counts, routing counts, and DRC blocker count in
`rdma/build/transport_ip_ooc/reports/ooc_pass.txt`.
Top-level input and output paths are explicitly left to integration signoff:
without final `HD.PARTPIN_LOCS`, assigning synthetic I/O delays produces
placement-dependent results that do not describe a reusable RTL core. A
consuming design must constrain and close every boundary path on its actual
clocking and floorplan.

Sequence recovery limits session failure from an isolated Ethernet loss, but it
is intentionally bounded and does not replace PAUSE/PFC on a lossy 100G path.
Repeated loss can still fault a session, and a real-time upstream source may
still have an acquisition gap while old data is replayed.

Board acceptance starts from a power cycle with Hardware Manager closed. Run
at least 100 automatic sessions, including sessions long enough to cross
multiple 1 GiB boundaries, and require a final commit, safe release,
`discontinuities=0`, `invalid=0`, and `overruns=0` on every successful run.

See `host/README.md` for host setup and the operational command.
