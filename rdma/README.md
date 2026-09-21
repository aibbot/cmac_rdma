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

`rdma_vio` has status inputs only. It cannot configure, start, stop, abort, or
clear a session. The existing ILA coverage remains available for diagnosis.

## Data and control paths

The registered RX classifier sends UDP/4791 ACK traffic to the RDMA endpoint,
UDP/4792 traffic to the RDCP parser, and drops all other traffic. The TX arbiter
selects only at AXI-Stream frame boundaries; control responses have priority
between RDMA frames and can never interleave with one.

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

Use Vivado 2025.2. The RDMA flow is isolated under `rdma/build`, fixes both
`general.maxThreads` and run-level jobs to 8, and limits only the helper
processes created by this build. Other open Vivado GUI instances are ignored.

```powershell
& 'D:\Xilinx\2025.2\Vivado\bin\vivado.bat' -mode batch `
  -source rdma/scripts/build_rdma_bitstream.tcl -tclargs setup

& 'D:\Xilinx\2025.2\Vivado\bin\vivado.bat' -mode batch `
  -source rdma/scripts/build_rdma_bitstream.tcl -tclargs synth

& 'D:\Xilinx\2025.2\Vivado\bin\vivado.bat' -mode batch `
  -source rdma/scripts/build_rdma_bitstream.tcl -tclargs impl
```

`impl` checks setup and hold slack, clock coverage, bus skew, DRC, route
completeness, debug cores, and required CDC structures before publishing the
`.bit` and `.ltx` pair.

Run the complete SystemVerilog regression with:

```powershell
pwsh -File rdma/tests/run_endpoint_tests.ps1
```

Sequence recovery limits session failure from an isolated Ethernet loss, but it
is intentionally bounded and does not replace PAUSE/PFC on a lossy 100G path.
Repeated loss can still fault a session, and a real-time upstream source may
still have an acquisition gap while old data is replayed.

Board acceptance starts from a power cycle with Hardware Manager closed. Run
at least 100 automatic sessions, including sessions long enough to cross
multiple 1 GiB boundaries, and require a final commit, safe release,
`discontinuities=0`, `invalid=0`, and `overruns=0` on every successful run.

See `host/README.md` for host setup and the operational command.
