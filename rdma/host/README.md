# Linux RDMA Ring Receiver

`rdma_ring_receiver` owns the complete lifecycle of one flow-controlled RDMA
capture.
It discovers the FPGA over RDCP, creates and registers the host resources,
configures and starts the FPGA, requests a normal stop when needed, waits for
the final commit and safe-release state, and only then destroys the QP and MR.
No VIO operation or copied parameter block is part of the product workflow.

## Host preparation

Use a dedicated point-to-point RoCE port. Configure its IPv4 address and MTU
before starting the receiver:

```sh
sudo ip link set dev ens8np0 down
sudo ip address flush dev ens8np0
sudo ip address add 192.168.17.10/24 dev ens8np0
sudo ip link set dev ens8np0 mtu 9000 up
```

The program rejects a selected netdev unless it is up, `192.168.17.10/24`, and
has MTU 9000 or greater. Carrier may still be coming up when the process starts;
the 10-second HELLO window performs that link wait. Before creating the QP, the
matching libibverbs port must be active, expose an IPv4-mapped RoCEv2 GID for
that netdev, and support PMTU 4096.

For loss and PFC diagnosis, capture NIC/DCB/verbs counters before and during a
run from the same Linux host. The sampler does not alter device configuration:

```sh
bash rdma/host/collect_roce_snapshot.sh --netdev ens8np0 --device rocep131s0 \
  --samples 120 --interval 5 > roce-diagnostics.txt 2>&1
```

For a compact same-window check of E810 flow-control activity, run this beside
the receiver while watching VIO probes 10 through 15:

```sh
set -o pipefail
bash rdma/host/watch_roce_flow_control.sh --netdev ens8np0 \
  --interval 1 --samples 120 2>&1 | tee roce-flow-control.txt
```

Each line contains the absolute counter followed by `baseline` for the first
sample, its delta from the previous sample, or `reset` after a counter decrease.
`link_xoff_tx.nic` is the global PAUSE/XOFF transmit counter;
`tx_priority_0_xoff.nic` is the PFC priority-0 transmit counter. Do not compare
these deltas with a VIO snapshot from another bitstream or another time window.

Each sample contains a timestamp, the complete `ethtool -S` output, driver,
FEC, NIC ring and pause settings, DCB PFC/application/ETS mappings, kernel
netdev statistics, and both RDMA counter sections.
Take a VIO snapshot when `nak_count` rises and compare it to the surrounding
host samples. Look for ingress discards, PFC TX, FEC uncorrectable errors, and
QP retries; missing tool or unsupported counter sections are reported instead
of silently interpreted as zero. Port 1 RDMA counters are skipped unless its
GID netdev association matches the selected netdev. A sequence NAK alone does
not identify which side lost the packet. Compare counter *deltas* across the same timestamped
interval, not absolute values from unrelated runs. Confirm the priority mapping
before changing PFC settings; the present FPGA packets are untagged and have
IPv4 DSCP zero. Run the sampler again after enabling flow control to check
that pause frames are actually exchanged.

### Direct-link PAUSE and PFC bring-up

Program the matching `.bit` and `.ltx` first. The `cmac_flow_control_vio`
output `probe_out0` selects the receive flow-control class at the FPGA:

| `probe_out0` | Mode | Enabled/request/ACK bit |
| --- | --- | --- |
| `0` (power-up default) | IEEE 802.3x global PAUSE | bit 8 |
| `1` | IEEE 802.1Qbb PFC priority 0 | bit 0 |

Stop the receiver and traffic before changing this output, and wait until
`probe_in4` (`pause_active`) and `probe_in7` (`pause_pending`) are both zero.
The remaining inputs are request `[8:0]`, valid `[8:0]`, enable `[8:0]`, ACK
`[8:0]`, current-frame-active, and the original selected-valid event count.
The diagnostic inputs added after the original eight probes are:

| Probe | Signal | Meaning |
| ---: | --- | --- |
| 8 | `stat_rx_pause` | Raw CMAC PAUSE indication |
| 9 | `stat_rx_pause_quanta8[15:0]` | Current global PAUSE quanta |
| 10 | `pause_frame_count[31:0]` | Saturating raw PAUSE indication count |
| 11 | `pause_valid8_count[31:0]` | Saturating global `valid[8]` count |
| 12 | `pause_req8_rise_count[31:0]` | Saturating global request rising-edge count |
| 13 | `pause_seen_sticky` | Raw PAUSE has been observed since TX reset |
| 14 | `pause_req8_seen_sticky` | Global request has been observed since TX reset |
| 15 | `last_pause_quanta8[15:0]` | Quanta retained from the last global `valid[8]` indication |
| 16 | `rx_multicast_count[31:0]` | Saturating CMAC multicast-frame count |
| 17 | `rx_packet_64_count[31:0]` | Saturating CMAC 64-byte-frame count |
| 18 | `rx_total_packet_count[31:0]` | Saturating sum of CMAC total-packet increments |
| 19 | `rx_user_pause_count[31:0]` | Saturating CMAC priority-based PAUSE (PFC) indication count |

Use global PAUSE as the first control experiment on the isolated direct link.
Disable PFC and enable only host TX PAUSE because congestion is at the host RX
side and the FPGA is the sender:

```sh
sudo dcb pfc set dev ens8np0 \
  prio-pfc 0:off 1:off 2:off 3:off 4:off 5:off 6:off 7:off
sudo ethtool -A ens8np0 autoneg off rx off tx on
ethtool -a ens8np0
```

Leave `probe_out0=0`, start the sampler, then run the receiver. A working
closed loop has increasing host `link_xoff_tx.nic`/`link_xon_tx.nic`, FPGA
request/ACK bit 8 activity, an increasing FPGA event count, and a flat
`rx_dropped.nic`. Global PAUSE also stops RDCP, ARP, and ICMP while active, so
use it only as this direct-link baseline.

After the global test, stop traffic and change to PFC priority 0. The current
FPGA frames are untagged with DSCP zero, and the observed ETS mapping sends all
priorities to TC0; priority 3 from generic vendor examples is therefore not
applicable:

```sh
sudo ethtool -A ens8np0 autoneg off rx off tx off
sudo dcb pfc set dev ens8np0 \
  prio-pfc 0:on 1:off 2:off 3:off 4:off 5:off 6:off 7:off
dcb pfc show dev ens8np0
dcb ets show dev ens8np0
```

Set `probe_out0=1` while idle, then repeat the same test. This time require
host `tx_priority_0_xoff.nic`/`tx_priority_0_xon.nic` and FPGA bit 0 activity.
Keep sequence replay enabled and also compare `nak_count`; PFC prevents the
known ingress-buffer drops, while replay remains bounded recovery for residual
loss.

### Headroom budget

At 100 Gbit/s, the link consumes 12.5 bytes/ns. Size the NIC's lossless receive
headroom from the measured threshold-to-stop latency, not from `ethtool -g`:

```text
headroom >= 12.5 bytes/ns * (NIC PFC generation + cable + CMAC decode/gating)
            + 9600 bytes for the frame already in progress
            + safety margin
```

The FPGA adds at most one current 9600-byte CMAC frame (768 ns) before ACKing
and stopping new frames. The following planning table uses a 2x margin on the
calculated in-flight bytes; replace the fixed response budget with a measured
worst case from NIC and FPGA counters:

| Fixed response budget | In-flight bytes including one frame | 2x headroom |
| ---: | ---: | ---: |
| 1 us | 22,100 B | 44,200 B (43.2 KiB) |
| 2 us | 34,600 B | 69,200 B (67.6 KiB) |
| 4 us | 59,600 B | 119,200 B (116.4 KiB) |

The observed 2048 RX descriptors describe the host DMA ring, not the NIC's
per-priority port-buffer headroom. Likewise, `dcb pfc ... delay 1949` is a DCB
link-delay parameter, not 1949 bytes of available buffer. Obtain the ICE/NVM
per-TC buffer thresholds or measure the pause threshold and response latency
before treating any row as the final setting.

Install `rdma-core`, `libibverbs-dev`, CMake, and a C++17 compiler. The process
also needs `CAP_NET_RAW` (or root) for `SO_BINDTODEVICE`, plus permission to
lock 1 GiB and the 64-byte commit record:

```sh
ulimit -l unlimited
cmake -S rdma/host -B rdma/host/build -DCMAKE_BUILD_TYPE=Release
cmake --build rdma/host/build --parallel
ctest --test-dir rdma/host/build --output-on-failure
```

## Start a capture

Only the RDMA device and matching netdev are required:

```sh
./rdma/host/build/rdma_ring_receiver \
  --device irdma0 \
  --netdev ens8np0
```

For the validated host names shown in the example deployment, a timed run is:

```sh
numactl --cpunodebind=1 --membind=1 \
  ./rdma/host/build/rdma_ring_receiver \
  --device rocep131s0 \
  --netdev ens8np0 \
  --fpga-ip 192.168.17.11 \
  --verify-on-exit \
  --seconds 10000
```

The FPGA address defaults to `192.168.17.11`. Product geometry is fixed at a
1 GiB ring, 10 MiB logical WR, 10 MiB commit interval, local base zero, QPN 1,
and cumulative host-consumption flow control. Immediate is disabled by default.
The FPGA pauses before it could overwrite unread data, then resumes after the
receiver validates the committed range and sends RDCP `CONSUME`.

Useful optional arguments are:

| Option | Effect |
| --- | --- |
| `--fpga-ip IPv4` | Override the default FPGA address |
| `--seconds N` | Request a normal STOP after N seconds |
| `--immediate` | Use WRITE_WITH_IMM commit wake-ups |
| `--recv-depth N` | Set posted receive depth for Immediate mode; default 1024 |
| `--verify-on-exit` | Rescan published `RFSO` headers before success |
| `--verbose-commits` | Print every commit instead of the final commit only |

At line rate 1 GiB is produced in about 86 ms. The buffer is therefore not a
10,000-second store: the receiver must continuously validate and release data
at the incoming rate. If it falls behind, the FPGA stalls at the 1 GiB credit
limit instead of overwriting unread data. `--seconds 10000` now requests a
normal STOP after 10,000 seconds rather than ending at the first ring boundary.

## Automatic lifecycle

1. The receiver binds UDP control traffic to the selected netdev and sends
   HELLO every 100 ms for up to 10 seconds.
2. It checks RDCP v2, FPGA QPN 1, PMTU 4096, required capabilities, and a state
   that permits a new configuration.
3. It allocates 1 GiB + 64 bytes, registers one writable MR, creates the CQ and
   RC QP, chooses fresh nonzero PSNs, and moves the QP to RTS.
4. It chooses a fresh nonzero session ID and sends CONFIG. CONFIG and START
   retry the same transaction for up to 3 seconds.
5. After READY it sends START. Statistics begin at the first nonzero commit,
   which establishes the measurement baseline.
6. For every new commit, including a short physical-message barrier at a ring
   or credit boundary, it validates all newly published `RFSO` headers and
   sends the cumulative scanned byte count in `CONSUME`. The FPGA uses that
   progress as credit and wraps the remote ring address without overwriting
   unread data.
7. `SIGINT`, `SIGTERM`, or `--seconds` sends STOP. The FPGA finishes the current
   logical WR and publishes a final commit; shutdown has a 15-second normal
   convergence window.
8. Normal teardown requires both the final commit and RDCP
   `CLOSED + safe_to_release`. Missing either is a failed session.
9. On a control, RDMA, commit, or endpoint fault, or if STATUS unexpectedly
   returns to `IDLE`, `CONFIGURING`, or `READY`, the receiver sends ABORT and
   waits for `FAULTED + safe_to_release`. The fault path is never reported as a
   successful capture and does not require a final commit. If the FPGA is
   unreachable, the process keeps the QP/MR alive, retries ABORT and STATUS,
   and prints a warning every 15 seconds; it never performs an unconfirmed
   teardown.

A timed-out CONFIG is treated as ambiguous because the FPGA may have accepted
it while its response was lost. The receiver therefore sends ABORT before
allowing the local QP/MR scope to end. In `IDLE`, `CLOSED`, or `FAULTED`, this
safety ABORT may replace an inactive old session binding so recovery always
converges. Every new process run creates a new QP/MR and session ID; stale START
or STOP datagrams cannot control it.

## Successful result

Each 4096-byte data packet begins with a 24-byte `RFSO` header. The receiver
validates newly published headers at commit boundaries and prints per-second
MiB/s, decimal Gbit/s, packet rate, commit rate, discontinuities, and invalid
headers. A successful final line must include:

```text
discontinuities=0 invalid=0 overruns=0
```

Success also requires at least one valid data packet, a final commit, and
`CLOSED + safe_to_release`. `--verify-on-exit` performs an additional scan of
the newest ring-sized published range after the FPGA has stopped.

This workflow assumes a trusted untagged point-to-point link. VLANs, shared
network authentication, multiple QPs, and unbounded packet-loss recovery are
outside this version. The FPGA can rewind up to 12 sequence-error NAKs inside
each physical message and can replay a NAKed commit. PAUSE/PFC is still
recommended: exhausting the recovery budget faults the session, and sustained lossless
acquisition requires the host's scan and downstream processing to keep up with
the source. Ring credit prevents memory corruption but may pause acquisition
when the host is slower.
