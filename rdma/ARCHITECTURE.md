# RDMA RTL Architecture

## Stable boundaries

The custom RTL is split into three integration levels. Only the first two are
portable; the board layer owns vendor IP and clock-domain crossings.

```text
external producer
      |
      v
rdma_transport_ip       reusable packaged-IP boundary
      |
      v
rdma_transport_core     native control + RoCEv2 transport

raw Ethernet RX/TX
      |
      v
rdma_network_core       RDCP + classifier + transport + arbiter
      |
      v
rdma_board_endpoint     clocks + CDC + board/debug integration
```

`rdma_transport_ip` is the public boundary for native control
and an application payload source. Its flat ports deliberately follow Vivado
IP Packager conventions. Internal module boundaries may change without
requiring an external design to change.

## Clock domains

| Domain | Owner | Contents |
| --- | --- | --- |
| `aclk` / `rdma_clk` | portable core | config, payload RAM, scheduler, packet builder, ACK/NAK, replay, counters |
| `cmac_clk` | board adapter | CMAC-side RX admission, ARP/ICMP response, final TX arbitration |

The portable core contains no CDC. `rdma_board_endpoint` owns the
asynchronous RX/TX FIFOs, synchronized resets, Gray-coded overflow counter,
and synchronized drain observations. No multi-bit payload or configuration bus
crosses a domain without a FIFO or an atomic registered snapshot.

At the packaged boundary, `aresetn` is asynchronous-assert and synchronous-
release. A four-stage synchronizer releases the core on `aclk`; every AXI
handshake output is held inactive until that release completes. Consumers do
not need to synchronize deassertion before connecting the IP.

## Transaction ownership

| State or transaction | Single owner |
| --- | --- |
| Configuration snapshot, validation, active fields, reject diagnostics | `rdma_config_manager` |
| ACK/NAK frame capture, header/ICRC validation, ICRC counter | `rdma_ack_receiver` |
| Session lifecycle, PSN, scheduling, recovery | `rdma_endpoint` |
| RDCP session, endpoint commands, transaction replay cache | `rdcp_session_engine` |
| External payload slot and validity | `rdma_payload_buffer` |
| Packet/retry replay image | `rdma_replay_buffer` |
| Ethernet RX classification | `rdma_rx_classifier` |
| RDCP-versus-RDMA TX frame ownership | `rdma_tx_frame_arbiter` |
| CMAC-versus-ARP/ICMP TX ownership | `rdma_tx_packet_arbiter` |
| Complete downstream drain decision | `rdma_tx_drain_tracker` |

Every configuration is captured only on `cfg_valid && cfg_ready`, validated
from that snapshot, then applied atomically through one `apply_valid` event.
The endpoint sees only the accepted packed configuration; it cannot alter the
manager's active fields or reject diagnostics. ACK/NAK parsing similarly emits
only a validated `{PSN, syndrome}` event to the scheduler. The application payload slot is
released only after the corresponding reliable write is ACKed or the session
is flushed. Retransmission reads the preserved packet image and cannot observe
new application data.

## External payload contract

- Width is fixed at 512 bits with `tkeep[63:0]`, `tlast`, and one error bit in
  `tuser`.
- Byte 0 maps to `tdata[7:0]` and `tkeep[0]`.
- One payload frame is exactly 4096 bytes: 64 full beats and `tlast` on the
  final beat.
- The source must hold all signals stable while `tvalid && !tready`.
- Invalid shape or `tuser` drops the complete frame and increments the error
  counter.
- The beat-level builder completes packet construction within 96 `aclk` cycles
  and writes the immutable frame image into replay RAM.
- Timeout and RNR retransmission reads replay RAM, not live application data.
- The payload slot remains occupied until the matching data ACK because the
  current scheduler has no descriptor queue for a second outstanding frame.
- A normal STOP drains an accepted full or partial frame. Only ABORT discards
  payload data, and the discard is counted once.

This is intentionally a one-slot stop-and-wait implementation. It minimizes
replay ownership and BRAM/control complexity but creates an ACK-latency
throughput limit. It is not a 97 Gbps external-ingress implementation.
Sustained line-rate external payload requires a future multi-slot descriptor
and payload queue with explicit replay ownership; that work must not weaken
replay identity or credit accounting.

## Configuration surface

Build-time parameters cover local MAC/QPN, ACK and RNR timers, retry/recovery
budgets, recovery quiet time, benchmark mode, and a read-only build tag.
The packaged parameter contract rejects QPN zero, zero-length timers, retry
budgets outside the four-bit retry counter, and negative recovery budgets at
elaboration and in the Vivado customization UI.
Run-time configuration covers local/remote IPv4, remote MAC/QPN, initial PSN,
remote base/rkey, ring and WR sizes, local base, notification interval, commit
address, Immediate mode, external-payload mode, and consumed-byte credit.
The board wrapper additionally drives the internal retransmission policy from
`rdma_vio/probe_out0`, whose generated-IP reset value is enabled. The packaged
transport IP keeps retransmission enabled so its public port contract remains
stable.

The timer parameters are cycle counts. `ACLK_FREQ_HZ` drives the packaged
clock metadata. Changing it in XGUI refreshes the 1-ms ACK and 10-us RNR timer
defaults, after which either cycle count remains explicitly editable. This
ordering avoids silently retaining 250-MHz cycle counts at a different clock
while preserving deployment-specific overrides. The validated board target
remains 250 MHz. Any other frequency requires fresh out-of-context timing
sign-off.

## Stable status ABI

The packaged `debug_state` is independent of the endpoint packetizer FSM:
`0=RESET`, `1=UNCONFIGURED`, `2=READY`, `3=RUNNING`, `4=STOPPING`, and
`5=FAULT`. Internal state encodings are not part of the public boundary.

`fault_reason` codes are `0x00000002` retry exhaustion after RNR or commit
sequence NAK, `0x00000003` fatal/unsupported NAK, `0x00000004` ACK-timeout
retry exhaustion, `0x00000005` retransmission disabled when retry was needed,
`0x00000101` sequence recovery outside the current message,
`0x00000102` exhausted sequence-recovery budget, `0x00000103` fatal/unknown
NAK during recovery, `0x00000201` unavailable or wrong-size external payload,
and `0x80000001` explicit ABORT.

`config_reject_reason[19:0]` is a stable bit mask. In order, its bits report:
not drained, zero remote MAC, two reserved bits, zero remote QPN, zero remote
IP, zero ring size, zero WR size, ring misalignment, WR misalignment, WR larger
than ring, local-base misalignment, zero notification interval, notification
misalignment, notification larger than ring, zero commit address, commit
misalignment, remote-range overflow, commit-range overflow, and commit/ring
overlap. Bits `31:20` are reserved.

Payload accepted/error counters are saturating lifetime counters and reset only
with the IP reset. Session CONFIG does not clear them. Session traffic, retry,
commit, and byte counters retain their existing per-session semantics.

The packaged IP exposes `BUILD_TAG` directly. The board composition exposes
the same 32-bit identity on `rdma_vio/probe_in29`; the isolated implementation
flow embeds the selected tag and publishes a manifest containing every source
digest plus the matching BIT and LTX SHA-256 values.

## Protocol invariants

Ethernet, IPv4, UDP, RDCP v2, RoCEv2, commit, and ICRC byte order is unchanged.
The PMTU remains 4096 bytes. IPv4 and UDP fields are network order; commit data
written to host memory retains its documented little-endian layout. ICRC masks
the RoCEv2 invariant fields and is serialized least-significant byte first.

## Failure and observability

Malformed payloads, invalid config, ICRC/PSN errors, NAKs, retransmissions,
retry exhaustion, overflow, underflow, sequence recovery, replay activity,
credit stall, commit progress, and byte progress remain visible through
saturating counters and status outputs. A false `tx_path_idle` indication is a
single integration failure point: it can allow replay or release before an
external pipeline drains. The board adapter mitigates it with explicit FIFO,
register, and CMAC-pipeline tracking; a portable integrator must provide an
equivalent signal.

## Verification boundary

The standalone IP regression checks configuration, reset release, parameter
ranges, application byte mapping, the 96-cycle construction budget, fixed ICRC,
TX backpressure stability, timeout replay identity, payload lifecycle, and
build-tag visibility. The full RTL suite additionally checks RDCP,
ring/credit/commit, recovery, AXI stability, CDC helpers, PAUSE diagnostics,
and arbitration. Synthesis, implementation, fresh BIT/LTX hashes, and board
soak results are separate evidence and must not be inferred from simulation.

`check_rdma_transport_ip_ooc.tcl` is the portable-core implementation gate. It
routes the IP at 250 MHz and records timing, constraints, internal DRC,
hierarchical utilization, high fanout, control sets, logic levels, and
methodology. Pin-only DRCs are explicitly excluded because the reusable core
does not own package pins. `BUFGCE_X0Y168` models the target device clock
source, while top-level input and output paths are explicitly reserved for
integration signoff because the reusable RTL has no final partition-pin
locations. The board implementation remains the final signoff for the actual
clock tree, placement, and every path across the IP boundary.
