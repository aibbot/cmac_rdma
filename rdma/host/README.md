# Linux Ring Receiver

`rdma_ring_receiver` is a C++17 implementation of the host half of the single
RC QP for the FPGA bring-up endpoint. It allocates one registered MR containing
a ring followed by a separate 64-byte commit record, selects the RoCEv2 GID
attached to the specified RoCE netdev, and prints JSON that maps directly to
the RDMA VIO fields.

Each 4096-byte RDMA data packet begins with the same 24-byte `RFSO` benchmark
header as the UDP generator: magic at offset 0 and a big-endian 32-bit sequence
at offset 4. The receiver scans only those headers after each commit publishes
the corresponding memory range. The expected sequence is derived from the
absolute 4096-byte ring position (modulo 2^32), so a wrapped or overwritten
slot cannot be mistaken for a continuous stream. It reports MiB/s, decimal
Gbps, packet rate, commit rate, sequence discontinuities, and invalid headers
once per second. The first nonzero commit establishes the timing and counter
baseline, so data completed before the host can observe that commit is not
credited to the measured rate.

Build on the E810-C Linux host after installing `rdma-core` and
`libibverbs-dev`:

```sh
cmake -S rdma/host -B rdma/host/build
cmake --build rdma/host/build --parallel
```

For a 1 MiB polling interval:

```sh
ulimit -l unlimited
numactl --cpunodebind=1 --membind=1 \
  ./rdma/host/build/rdma_ring_receiver \
  --device rocep131s0 --netdev ens8np0 --fpga-ip 192.168.17.11 \
  --fpga-mac 02:00:00:00:00:01 --notify-interval 1M
```

For a finite maximum-rate benchmark, use 10 MiB writes/commits and a 1 GiB
ring. This yields frequent publication points for one-second reporting while
adding only one commit for every 2560 data packets. With wrap disabled, the
FPGA publishes a final commit and stops at 1 GiB:

```sh
./rdma/host/build/rdma_ring_receiver \
  --device rocep131s0 --netdev ens8np0 --fpga-ip 192.168.17.11 \
  --fpga-mac 02:00:00:00:00:01 \
  --ring-size 1G --wr-size 10M --notify-interval 10M \
  --seconds 10 --verify-on-exit
```

For a sustained 10-second diagnostic, add `--allow-ring-wrap`. When the host
prints the duration reminder, pulse FPGA `stop` and wait for `drained`. This
mode has no consumer-credit protocol; accept the run only when the final host
statistics report `overruns=0`, `discontinuities=0`, and `invalid=0`.

For 10 MiB commits with CQE wake-ups, add `--notify-interval 10M --immediate`.
The tool posts and replenishes receive WQEs only in Immediate mode and checks
for `IBV_WC_RECV_RDMA_WITH_IMM`. In either mode it reads the release sequence
at byte offset 40 of the commit record, then applies an acquire barrier before
using the associated ring metadata.

The emitted VIO JSON defaults `cfg_allow_ring_wrap` to `0`. In this finite
bring-up mode the FPGA stops at the end of the allocated ring and publishes a
final commit before byte zero can be overwritten. The tool exits only after it
observes that final commit, so it does not release the QP or MR while the FPGA
may still write. `--allow-ring-wrap` is available only for controlled
diagnostics; it permits overwrites and does not substitute for a host consumer
credit protocol.

Copy the emitted `vio` object into `rdma_vio`, pulse `apply` while the FPGA is
stopped and `drained`, then pulse `start`. To validate a stopped transfer,
pulse FPGA `stop`, wait for `drained`, and terminate the tool with
`--verify-on-exit`; it rescans the latest published ring's `RFSO` headers.
`--seconds` only prints a stop reminder after the
requested duration; pulse FPGA `stop` and wait for the final commit before
teardown. Do not release the registered MR while the FPGA is still active.
Use `--verbose-commits` only when individual commit lines are needed;
suppressing them is the default benchmark behavior.
