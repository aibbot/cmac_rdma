# Linux RDMA Ring Receiver

`rdma_ring_receiver` owns the complete lifecycle of one finite RDMA capture.
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

The FPGA address defaults to `192.168.17.11`. Product geometry is fixed at a
1 GiB ring, 10 MiB logical WR, 10 MiB commit interval, local base zero, QPN 1,
and no ring wrap. Immediate is disabled by default.

Useful optional arguments are:

| Option | Effect |
| --- | --- |
| `--fpga-ip IPv4` | Override the default FPGA address |
| `--seconds N` | Request a normal STOP after N seconds |
| `--immediate` | Use WRITE_WITH_IMM commit wake-ups |
| `--recv-depth N` | Set posted receive depth for Immediate mode; default 1024 |
| `--verify-on-exit` | Rescan published `RFSO` headers before success |
| `--verbose-commits` | Print every commit instead of the final commit only |

At line rate the 1 GiB ring fills in about 86 ms, so ring-full will normally
stop the session before a multi-second `--seconds` limit.

## Automatic lifecycle

1. The receiver binds UDP control traffic to the selected netdev and sends
   HELLO every 100 ms for up to 10 seconds.
2. It checks RDCP v1, FPGA QPN 1, PMTU 4096, required capabilities, and a state
   that permits a new configuration.
3. It allocates 1 GiB + 64 bytes, registers one writable MR, creates the CQ and
   RC QP, chooses fresh nonzero PSNs, and moves the QP to RTS.
4. It chooses a fresh nonzero session ID and sends CONFIG. CONFIG and START
   retry the same transaction for up to 3 seconds.
5. After READY it sends START. Statistics begin at the first nonzero commit,
   which establishes the measurement baseline.
6. Ring-full stops automatically. Observing `STOPPING` starts the same 15-second
   convergence window used after `SIGINT`, `SIGTERM`, or `--seconds` sends STOP.
7. Normal teardown requires both the final commit and RDCP
   `CLOSED + safe_to_release`. Missing either is a failed session.
8. On a control, RDMA, commit, or endpoint fault, or if STATUS unexpectedly
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
`CLOSED + safe_to_release`. `--verify-on-exit` performs an additional full
scan of the final published range.

This workflow assumes a trusted untagged point-to-point link. VLANs, shared
network authentication, multiple QPs, data replay after loss, and continuous
lossless operation are outside this version.
