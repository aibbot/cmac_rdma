# RoCEv2 HLS Admission Result

Date: 2026-09-08

HLS build status: **PASS WITH RISK**

HLS endpoint integration status: **NO-GO**

The HLS failure is resolved. The locked source is copied to `rdma/build`,
patched there, and never modified in place. The current Vitis 2025.2 build runs
the real `rocev2_top` boundary rather than the obsolete lower-level test, then
exports a 512-bit IP and passes a fresh Vivado OOC timing/route gate. The
matching generated OOC evidence is retained in `build/hls/ooc/reports/`.

A separate custom-SystemVerilog board-bring-up endpoint now uses persistent
`sources_rdma`/`rdma_synth_1`/`rdma_impl_1` runs and has a Linux
`libibverbs` host tool under `host/`. It is not an integration of this HLS IP
and does not change the HLS no-go decision below. The custom path is limited to
single-QP first-board debugging and must pass its own full-CMAC implementation
and E810-C interoperability gates.

## Locked Configuration

- Repository: `https://github.com/fpgasystems/fpga-network-stack.git`
- Branch: `coyote-TCP-RDMA`
- Commit: `3a4ec80770c926a1b0e7a967752c38bbf3785481`
- Toolchain: Vitis/Vivado 2025.2
- Part: `xczu47dr-fsvg1517-1-i`
- Data width: 512 bits
- Clock: 4.000 ns
- PMTU: 4096 bytes
- QPs: 256
- Retransmission: enabled

## Fresh Gate Results

| Gate | Result | Evidence |
|---|---:|---|
| Locked revision and source cleanliness | PASS | The build script verifies the exact commit and rejects a dirty dependency checkout. |
| Transitive source licensing | PASS | All compiled or included sources have BSD-3-Clause notices; see `THIRD_PARTY_NOTICES.md`. |
| Retry timer scaling | PASS | The build-copy patch derives the timer from `CLOCK_PERIOD_US`; the SystemVerilog regression passes 1/5/12/64 ms thresholds. |
| Top-level C-sim | PASS WITH RISK | Compatibility patch `0006` replaces the stale test ABI with a bounded `rocev2_top` launch smoke. It checks the 512-bit AXIS shape, IPv4/UDP/BTH/RETH fields, QPN, PSN, rkey, remote address, payload, and unexpected memory traffic. |
| HLS synth and IP export | PASS | Vitis 2025.2 exported `ethz.systems.fpga:hls:rocev2:0.82`; all required AXIS ports and widths match. |
| HLS estimate and schedule | WARN | HLS estimates 4.376 ns (228.52 MHz) against 4.000 ns and reports top-level dataflow II=2. This is an estimate, not the final routed result. |
| Fresh Vivado OOC route | PASS WITH RISK | `build/hls/ooc/reports/result.txt` records WNS +0.115 ns, WHS +0.008 ns, 0 DRC errors, 124284/124284 routable nets fully routed, and 0 routing errors. Supporting reports are `timing_summary.rpt`, `drc.rpt`, and `route_status.rpt` in the same directory. |
| Existing UDP/ARP/ICMP RTL regression | Not rerun in this HLS repair | The HLS patch does not touch the existing vendor or UDP RTL. Re-run it before a board-level change. |

## Resolved HLS Failure

The upstream `test_rocev2.cpp` was stale relative to the locked retransmission
interface: it duplicated `fakeDRAM` methods, called an obsolete 13-argument
`rocev2` signature, and referenced removed application symbols. Patch `0006`
keeps the source dependency clean and replaces only the build-copy test harness.
The mandatory build now completes C-sim, synthesis, and IP export without
`-SkipCsim`.

C-sim still reports leftover data in `rt_freeListFifo`. That is not a compile or
synthesis failure, but it is a co-simulation/deadlock risk that must be covered
by RTL simulation before using the core in a persistent packet path.

## Remaining No-Go Conditions

- The locked core defines `DISABLE_CRC_CALCULATION`. Its TX smoke frame carries
  the IPv4/UDP/RDMA headers and payload but omits the four ICRC bytes while its
  header lengths describe the ICRC-inclusive packet. This is not a valid
  RoCEv2 packet for E810-C interoperability.
- Enabling the upstream CRC macros alone is unsafe: TX ICRC insertion is
  incomplete, the active pseudo-header mask is IPv6-oriented while this flow is
  IPv4, and RX counts a CRC mismatch without dropping the packet.
- The launch smoke is not an IPv4 header-checksum or CRC receive oracle. It
  cannot qualify protocol correctness, ACK/NAK behavior, retransmission, or
  host interoperability.
- The HLS dataflow schedule is II=2, not the planned II=1. The routed OOC
  result proves local clock closure for this generated core only; it does not
  establish the required 100G payload rate.
- OOC meets the local 4.000 ns constraint, but its clock source is unspecified
  and it has no top-level I/O delay model. Only a full CMAC/RDMA implementation
  can sign off the board timing.

## Reproduction

```powershell
.\rdma\hls\build_rocev2_hls.ps1
.\rdma\tests\run_admission_tests.ps1
.\rdma\hls\build_rocev2_ooc.ps1
```

`-SkipCsim` is diagnostic-only and must not be used to claim HLS admission.
