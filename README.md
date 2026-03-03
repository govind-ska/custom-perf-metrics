# perf_metrics_collector.sh

Standalone system-wide performance metrics collector using `perf stat` and `turbostat`. Auto-detects Intel or AMD and collects the appropriate events - no compilation or external dependencies beyond `perf` and root access.

## Quick Start

```bash
sudo bash perf_metrics_collector.sh -t 30 -i 5000
```

Output is written to `./perf_metrics_<hostname>_<timestamp>/`.

## Usage

```
sudo bash perf_metrics_collector.sh [-t duration_sec] [-i interval_ms] [-m] [-w] [-p mlc_path] [-o output_dir] [-h]
```

| Flag | Default | Description |
|------|---------|-------------|
| `-t` | `30` | Collection duration in seconds |
| `-i` | `5000` | Time-series sampling interval in milliseconds. Set to `0` for aggregate-only (single summary per collection) |
| `-m` | off | Run MLC standalone benchmark (idle latency, peak BW, bandwidth matrix, latency matrix, loaded latency) |
| `-w` | off | Run `perf stat` with MLC as the workload (profile system-wide counters while MLC stresses memory) |
| `-p` | auto | Path to `mlc` binary. Auto-searches: `PATH`, `./tools/x86_64/mlc`, `/usr/local/bin/mlc` |
| `-o` | auto | Output directory. Default: `./perf_metrics_<hostname>_<YYYYMMDD_HHMMSS>` |
| `-h` | | Print usage and exit |

### Examples

```bash
# 60-second collection, 1-second time-series granularity
sudo bash perf_metrics_collector.sh -t 60 -i 1000

# 30-second aggregate-only (no time-series)
sudo bash perf_metrics_collector.sh -t 30 -i 0

# Include MLC standalone benchmark
sudo bash perf_metrics_collector.sh -t 30 -m

# Include MLC as profiled workload (perf stat wrapping MLC)
sudo bash perf_metrics_collector.sh -t 30 -w

# Both MLC modes with explicit binary path
sudo bash perf_metrics_collector.sh -t 30 -m -w -p /opt/mlc/mlc

# Custom output directory
sudo bash perf_metrics_collector.sh -t 10 -o /tmp/my_run
```

## Requirements

- **perf** (linux-tools / perf-tools package)
- **root** (sudo) - required for system-wide collection and NMI watchdog control
- **turbostat** (optional) - frequency, C-states, temperature, power via MSRs
- **mlc** (optional) - Intel's Memory Latency Checker for memory bandwidth/latency benchmarking. Download from [Intel MLC](https://www.intel.com/content/www/us/en/download/736633/). Required only when using `-m` or `-w` flags

## How It Works

Each metric category runs as a **separate background `perf stat` process**. This isolates failures - if one event group is unsupported on the platform, all other collectors still succeed. Results are combined into a single `METRICS_REPORT.txt` at the end.

The NMI watchdog is temporarily disabled during collection (frees a hardware counter) and restored on exit.

## Platform Support

### Intel (SPR / EMR / GNR and newer)

Uses `perf stat -M` built-in metric groups with symbolic uncore event names. No raw event codes needed - the kernel resolves the correct encodings for the platform.

| Collector | Metric Groups | What It Measures |
|-----------|--------------|------------------|
| `tma_l1_l2` | TopdownL1, TopdownL2 | TMA: Frontend Bound, Bad Speculation, Backend Bound, Retiring + L2 breakdown |
| `tma_l3_l4` | TopdownL3, TopdownL4 | TMA: L3 Bound, DRAM Bound, Data Sharing, Contested Accesses, etc. |
| `summary` | Summary | IPC, CPU utilization, operating frequency |
| `llc` | llc_data_read_mpi, llc_code_read_mpi, llc_demand_data_read_miss_latency (overall, local, remote, DRAM) | LLC misses per instruction + miss latency in nanoseconds |
| `numa` | numa_reads_addressed_to_local/remote_dram | % of reads served by local vs remote DRAM |
| `cache_mpi` | l1d_mpi, l2_mpi, l2_demand_data_read_mpi, l2_demand_code_mpi | Cache misses per instruction at each level |
| `tlb` | itlb_2nd_level_mpi, dtlb_2nd_level_load/store_mpi | TLB miss rates per instruction |
| `memory_bw` | memory_bandwidth_read/write/total | DRAM bandwidth (MB/s) via IMC counters |
| `llc_miss_bw` | llc_miss_local/remote_memory_bandwidth_read/write | DRAM bandwidth broken down by LLC misses, local vs remote |
| `io_bw` | io_bandwidth_read/write + local/remote variants | CHA-based IO bandwidth |
| `iio_bw` | iio_bandwidth_read/write | Per-root-port IIO bandwidth |
| `upi_bw` | upi_data_receive/transmit_bw | UPI inter-socket bandwidth (multi-socket only; skipped if no UPI PMU) |
| `core` | Raw events | Branch mispredictions, lock loads, load/store counts, uop source breakdown (DSB/MITE/LSD/MS), kernel-mode cycles |
| `cstates` | Raw events | Core C6 and Package C6 residency |
| `power` | Raw events | Package and DRAM energy (conditional on PMU availability) |

### AMD (Zen 4: Genoa / Bergamo / Turin)

Uses raw event codes from PerfSpect's event definitions across three PMU types: **cpu**, **l3** (uncore), and **df** (Data Fabric uncore).

**PMU auto-detection:** The script probes `/sys/devices/` for both naming conventions - `amd_df`/`amd_l3` (newer kernels) vs `df`/`l3` (older kernels). If a PMU is not found, its collectors are skipped with a warning.

| Collector | PMU | What It Measures |
|-----------|-----|------------------|
| `core1` | cpu | CPU frequency, utilization, IPC/CPI, branch misprediction, L1D/L2 access rates |
| `core2` | cpu | L2 cache hit/miss/prefetch breakdown (instruction + data cache origins) |
| `core3` | cpu | NUMA fill locality - L1D fills by source: local L2, local CCX, near/far cache, near/far DRAM |
| `core4` | cpu | Op cache + instruction cache miss ratios, full ITLB/DTLB hierarchy (L1/L2 hits/misses by page size: 4K, coalesced, 2M) |
| `core5` | cpu | Macro-ops dispatched/retired, SSE/AVX mixed stalls |
| `l3` | l3 / amd_l3 | L3 cache accesses, hits, misses + average L3 read miss latency (sampled, in ns) |
| `dram_bw_local_rd/wr` | df / amd_df | Local DRAM read/write bandwidth (12 channels) |
| `dram_bw_remote_rd/wr` | df / amd_df | Remote DRAM read/write bandwidth (12 channels) |
| `dma_io_local` | df / amd_df | Local socket upstream DMA read/write bandwidth (4 IOMs) |
| `dma_io_remote` | df / amd_df | Remote socket upstream DMA read/write bandwidth (4 IOMs) |
| `socket_bw_local_in/out` | df / amd_df | Local socket inbound/outbound data beats via Infinity Fabric (8 CCMs x 2 interfaces) |
| `socket_bw_remote_in/out` | df / amd_df | Remote socket inbound/outbound data beats via xGMI (8 CCMs x 2 interfaces) |
| `link_bw` | df / amd_df | Outbound bandwidth from all 8 inter-socket links |
| `pipeline` | cpu | Top-Down pipeline utilization: Frontend Bound (latency + bandwidth), Bad Speculation (mispredicts + restarts), Backend Bound (memory + CPU), SMT Contention, Retiring (fastpath + microcode) |
| `power` | power | Package energy consumption |

### turbostat (both platforms)

Runs in the background when available. Captures per-core frequency, C-state residency, temperature, and power readings via MSRs.

### MLC Integration (optional, both platforms)

Two modes are available when MLC is present:

| Mode | Flag | What It Does |
|------|------|-------------|
| **Standalone** (`-m`) | `-m` | Runs MLC benchmarks sequentially: idle latency, peak injection bandwidth, bandwidth matrix (NUMA node pairs), latency matrix, and loaded latency (BW vs latency curve). Output is pure MLC text. |
| **Profiled workload** (`-w`) | `-w` | Runs `perf stat` system-wide **while** MLC's `--peak_injection_bandwidth` test is the workload. On Intel, collects memory BW metric groups + Summary + LLC events. On AMD, collects core cycles/instructions + memory fill events. Lets you see hardware counter behavior under peak memory stress. |

Both modes run in parallel with the regular perf collectors and turbostat. MLC output is included in the combined `METRICS_REPORT.txt`.

## Output Structure (example)

```
perf_metrics_sequoia06-4_20260227_064926/
  METRICS_REPORT.txt          # Combined report (all sections)
  perf_tma_l1_l2.txt          # Raw perf stat output per collector
  perf_tma_l3_l4.txt
  perf_summary.txt
  perf_llc.txt
  perf_numa.txt
  perf_cache_mpi.txt
  perf_tlb.txt
  perf_memory_bw.txt
  perf_llc_miss_bw.txt
  perf_io_bw.txt
  perf_iio_bw.txt
  perf_core.txt
  perf_cstates.txt
  turbostat.txt
  mlc_standalone.txt            # (only with -m) Full MLC benchmark output
  perf_mlc_workload.txt         # (only with -w) perf stat counters during MLC run
  mlc_workload_raw.txt          # (only with -w) MLC stdout during profiled run
```

Each `perf_*.txt` file contains raw `perf stat` output. When time-series mode is enabled (`-i > 0`), each file contains timestamped rows at the specified interval:

```
#           time             counts unit events
     2.001675667            5542034      UNC_M_CAS_COUNT_SCH0.RD   #  323.3 MB/s  memory_bandwidth_read
     4.003529226            7641408      UNC_M_CAS_COUNT_SCH0.RD   #  459.2 MB/s  memory_bandwidth_read
     ...
```

## Relationship to PerfSpect

This script collects the same raw `perf stat` events that PerfSpect's `metrics` command uses internally. The key differences:

- **PerfSpect** collects events via `perf stat -j` (JSON), then applies metric formulas (from its `*_metrics.json` files) to compute derived values, and renders an HTML report.
- **This script** outputs raw `perf stat` text directly. For Intel, `perf stat -M` computes derived metrics inline (e.g., `52.1 ns llc_demand_data_read_miss_latency`). For AMD, the raw counter values are reported as-is.

Event definitions for AMD were sourced from PerfSpect's `cmd/metrics/resources/legacy/events/x86_64/AuthenticAMD/genoa.txt`. Every event group in that file is covered by this script.
