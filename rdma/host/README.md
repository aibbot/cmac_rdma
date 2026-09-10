# Linux Ring Receiver

`rdma_ring_receiver` is a C++17 implementation of the host half of the single
RC QP for the FPGA bring-up endpoint. It allocates one registered MR containing
a ring followed by a separate 64-byte commit record, selects the RoCEv2 GID
attached to the specified RoCE netdev, and prints JSON that maps directly to
the RDMA VIO fields.

Build on the E810-C Linux host after installing `rdma-core` and
`libibverbs-dev`:

```sh
cmake -S rdma/host -B rdma/host/build
cmake --build rdma/host/build --parallel
```

For a 1 MiB polling interval:

```sh
ulimit -l unlimited
./rdma/host/build/rdma_ring_receiver \
  --device rocep131s0 --netdev ens8np0 --fpga-ip 192.168.17.11 \
  --fpga-mac 02:00:00:00:00:01 --notify-interval 1M
```

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
`--verify-on-exit`; it scans the latest published ring range against the FPGA
local-address data pattern. `--seconds` only prints a stop reminder after the
requested duration; pulse FPGA `stop` and wait for the final commit before
teardown. Do not release the registered MR while the FPGA is still active.
