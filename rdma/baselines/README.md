# RDMA Baselines

`baseline_20260920_175959/rdma_utilization.rpt` is the frozen Vivado 2025.2
routed utilization report used by the implementation resource gate. It covers
the same `cmac_usplus_0_rdma_top` hierarchy and xczu47dr-fsvg1517-1-i device
as the current build. The build script records its SHA-256 in the artifact
manifest and compares the top and board-endpoint LUT/FF rows with a 5 percent
maximum increase.

Generated reports under `rdma/build` are disposable; this copy is the
versioned acceptance input.
