#!/usr/bin/env bash
###############################################################################
# Author: govind.ska@nutanix.com
# Version 1.0.0
# perf_metrics_collector.sh
#
# Standalone metrics collector using perf stat + turbostat.
# Auto-detects Intel or AMD and uses the appropriate approach:
#   - Modern Intel (SPR/EMR/GNR): Uses perf stat -M metric groups + symbolic
#     event names. TMA L1-L4 built into the kernel.
#   - Legacy Intel (SKX/CLX): Uses raw event codes.
#   - AMD Zen 4+. (Genoa/Turin): Uses raw event codes for core + l3 + df PMUs.
#
# Each category (core, uncore, TMA, power) runs as a separate perf stat
# invocation so that a failure in one does not kill the others.
#
# Usage:  sudo bash perf_metrics_collector.sh [-t seconds] [-i interval_ms] [-o outdir]
# Requirements: perf, root. turbostat optional.
###############################################################################
set -euo pipefail

ORIG_CMD="$0 $*"

DURATION=10
INTERVAL=5000
OUTDIR=""
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

usage() {
    echo "Usage: sudo $0 [-t duration_sec] [-i interval_ms] [-o output_dir] [-h]"
    echo "  -t  Collection duration in seconds (default: 10)"
    echo "  -i  Sampling interval in milliseconds (default: 5000)"
    echo "      Set to 0 to disable time-series and collect aggregate only"
    echo "  -o  Output directory (default: auto-generated)"
    exit 0
}
while getopts "t:i:o:h" opt; do
    case $opt in t) DURATION=$OPTARG;; i) INTERVAL=$OPTARG;; o) OUTDIR=$OPTARG;; h) usage;; *) usage;; esac
done

[[ "$(id -u)" -ne 0 ]] && { echo "ERROR: Run as root (sudo)."; exit 1; }
HOSTNAME_SHORT=$(hostname -s 2>/dev/null || hostname)
[[ -z "$OUTDIR" ]] && OUTDIR="./perf_metrics_${HOSTNAME_SHORT}_${TIMESTAMP}"
mkdir -p "$OUTDIR"

VENDOR=$(grep -m1 'vendor_id' /proc/cpuinfo | awk '{print $NF}')
MODEL_NAME=$(grep -m1 'model name' /proc/cpuinfo | sed 's/.*: //')
SOCKETS=$(lscpu | grep "Socket(s):" | awk '{print $NF}')
CORES_PER_SOCKET=$(lscpu | grep "Core(s) per socket:" | awk '{print $NF}')

INTERVAL_MSG="every ${INTERVAL}ms"
[[ "$INTERVAL" -eq 0 ]] && INTERVAL_MSG="aggregate only"

echo "============================================="
echo " Platform: $MODEL_NAME"
echo " Vendor:   $VENDOR | Sockets: $SOCKETS | Cores/Sock: $CORES_PER_SOCKET"
echo " Duration: ${DURATION}s | Interval: $INTERVAL_MSG | Output: $OUTDIR"
echo "============================================="

# Disable NMI watchdog
ORIG_NMI=$(cat /proc/sys/kernel/nmi_watchdog 2>/dev/null || echo "1")
echo 0 > /proc/sys/kernel/nmi_watchdog 2>/dev/null || true
cleanup() { echo "$ORIG_NMI" > /proc/sys/kernel/nmi_watchdog 2>/dev/null || true; }
trap cleanup EXIT

# Helper: run a perf stat and save output, tolerating failures
run_perf() {
    local label="$1"; shift
    local outfile="$OUTDIR/perf_${label}.txt"
    local interval_args=()
    [[ "$INTERVAL" -gt 0 ]] && interval_args=(-I "$INTERVAL")
    echo "  [$label] collecting..."
    if perf stat "${interval_args[@]}" "$@" -a sleep "$DURATION" 2>"$outfile"; then
        echo "  [$label] done -> $outfile"
    else
        echo "  [$label] WARNING: some events may have failed (see $outfile)"
    fi
}

###############################################################################
echo ""
echo "[$(date +%H:%M:%S)] Starting collection (${DURATION}s)..."

# Turbostat in background
TURBO_FILE="$OUTDIR/turbostat.txt"
TURBO_PID=""
if command -v turbostat &>/dev/null; then
    echo "  [turbostat] starting in background..."
    turbostat -i 5 -n $((DURATION / 5 + 1)) > "$TURBO_FILE" 2>&1 &
    TURBO_PID=$!
fi

###############################################################################
# INTEL
###############################################################################
if [[ "$VENDOR" == "GenuineIntel" ]]; then

    # --- TMA Top-Down L1 through L4 ---
    run_perf "tma_l1_l2" -M TopdownL1,TopdownL2 &
    run_perf "tma_l3_l4" -M TopdownL3,TopdownL4 &

    # --- Summary (IPC, utilization, frequency) ---
    run_perf "summary" -M Summary &

    # --- LLC (Last Level Cache) MPI + latency (uses CHA symbolic names) ---
    run_perf "llc" -M llc_data_read_mpi_demand_plus_prefetch,llc_code_read_mpi_demand_plus_prefetch,llc_demand_data_read_miss_latency,llc_demand_data_read_miss_latency_for_local_requests,llc_demand_data_read_miss_latency_for_remote_requests,llc_demand_data_read_miss_to_dram_latency &

    # --- NUMA local vs remote ---
    run_perf "numa" -M numa_reads_addressed_to_local_dram,numa_reads_addressed_to_remote_dram &

    # --- Cache MPI (L1D, L2, L2 code) ---
    run_perf "cache_mpi" -M l1d_mpi,l2_mpi,l2_demand_data_read_mpi,l2_demand_code_mpi &

    # --- TLB MPI ---
    run_perf "tlb" -M itlb_2nd_level_mpi,dtlb_2nd_level_load_mpi,dtlb_2nd_level_store_mpi &

    # --- Memory bandwidth (read/write/total) ---
    run_perf "memory_bw" -M memory_bandwidth_read,memory_bandwidth_write,memory_bandwidth_total &

    # --- LLC miss memory bandwidth (local/remote) ---
    run_perf "llc_miss_bw" -M llc_miss_local_memory_bandwidth_read,llc_miss_local_memory_bandwidth_write,llc_miss_remote_memory_bandwidth_read,llc_miss_remote_memory_bandwidth_write &

    # --- IO bandwidth (aggregate + local/remote) ---
    run_perf "io_bw" -M io_bandwidth_read,io_bandwidth_write,io_bandwidth_read_local,io_bandwidth_read_remote,io_bandwidth_write_local,io_bandwidth_write_remote &

    # --- IIO (per-root-port) bandwidth ---
    run_perf "iio_bw" -M iio_bandwidth_read,iio_bandwidth_write &

    # --- UPI inter-socket bandwidth (only on multi-socket with UPI links) ---
    if perf list pmu 2>/dev/null | grep -q 'uncore_upi'; then
        run_perf "upi_bw" -M upi_data_receive_bw,upi_data_transmit_bw &
    fi

    # --- Core events (raw: branch, locks, loads/stores, uop sources) ---
    run_perf "core" -e '{cpu/event=0xc5,umask=0x00,name=BR_MISP_RETIRED.ALL_BRANCHES/,cpu/event=0xd0,umask=0x21,cmask=0x01,name=MEM_INST_RETIRED.LOCK_LOADS/,cpu/event=0xd0,umask=0x82,name=MEM_INST_RETIRED.ALL_STORES/,cpu/event=0xd0,umask=0x81,name=MEM_INST_RETIRED.ALL_LOADS/,cpu-cycles,ref-cycles,instructions}' \
             -e '{cpu/event=0x79,umask=0x08,name=IDQ.DSB_UOPS/,cpu/event=0x79,umask=0x04,name=IDQ.MITE_UOPS/,cpu/event=0xa8,umask=0x01,name=LSD.UOPS/,cpu/event=0x79,umask=0x30,name=IDQ.MS_UOPS/,cpu-cycles,ref-cycles,instructions}' \
             -e '{cpu-cycles:k,ref-cycles:k,instructions:k}' &

    # --- C-states ---
    run_perf "cstates" -e cstate_core/c6-residency/,cstate_pkg/c6-residency/ &

    # --- Power (may not be available on all platforms) ---
    if perf list pmu 2>/dev/null | grep -q 'power/energy-pkg'; then
        run_perf "power" -e power/energy-pkg/,power/energy-ram/ &
    fi

###############################################################################
# AMD
###############################################################################
elif [[ "$VENDOR" == "AuthenticAMD" ]]; then

    # Auto-detect PMU names (newer kernels use amd_df/amd_l3, older use df/l3)
    if [[ -d /sys/devices/amd_df ]]; then
        DF_PMU="amd_df"
    elif [[ -d /sys/devices/df ]]; then
        DF_PMU="df"
    else
        DF_PMU=""
    fi

    if [[ -d /sys/devices/amd_l3 ]]; then
        L3_PMU="amd_l3"
    elif [[ -d /sys/devices/l3 ]]; then
        L3_PMU="l3"
    else
        L3_PMU=""
    fi

    echo "  PMU names: DF=${DF_PMU:-NONE} L3=${L3_PMU:-NONE}"
    [[ -z "$DF_PMU" ]] && echo "  WARNING: No Data Fabric PMU found -- DRAM/IO/socket bandwidth collectors will be skipped."
    [[ -z "$L3_PMU" ]] && echo "  WARNING: No L3 PMU found -- L3 cache collectors will be skipped."

    # Set AMD-optimal mux interval
    for f in $(find /sys/devices -type f -name perf_event_mux_interval_ms 2>/dev/null); do
        echo 16 > "$f" 2>/dev/null || true
    done

    # --- Core events ---
    run_perf "core1" \
        -e '{cpu/event=0x120,umask=0x1,name=ls_not_halted_p0_cyc/,cpu/event=0xc3,name=ex_ret_brn_misp/,cpu/event=0xc2,name=ex_ret_brn/,cpu-cycles,instructions}' \
        -e '{cpu/event=0x120,umask=0x1,name=ls_not_halted_p0_cyc_k/k,cpu-cycles:k,instructions:k}' \
        -e '{cpu/event=0x29,umask=0x7,name=ls_dispatch.any/,cpu/event=0x60,umask=0x10,name=l2_request_g1.cacheable_ic_read/,cpu/event=0x60,umask=0xe8,name=l2_request_g1.all_dc/,instructions}' &

    run_perf "core2" \
        -e '{cpu/event=0x60,umask=0xf9,name=l2_request_g1.all_no_prefetch/,cpu/event=0x70,umask=0x1f,name=l2_pf_hit_l2.all/,cpu/event=0x71,umask=0x1f,name=l2_pf_miss_l2_hit_l3.all/,cpu/event=0x72,umask=0x1f,name=l2_pf_miss_l2_l3.all/,instructions}' \
        -e '{cpu/event=0x64,umask=0x9,name=l2_cache_req_stat.ic_dc_miss_in_l2/,cpu/event=0x64,umask=0x1,name=l2_cache_req_stat.ic_fill_miss/,cpu/event=0x64,umask=0x8,name=l2_cache_req_stat.ls_rd_blk_c/,instructions}' \
        -e '{cpu/event=0x64,umask=0xf6,name=l2_cache_req_stat.ic_dc_hit_in_l2/,cpu/event=0x70,umask=0x1f,name=l2_pf_hit_l2.all_g6/,cpu/event=0x64,umask=0x06,name=l2_cache_req_stat.ic_hit_in_l2/,cpu/event=0x64,umask=0xf0,name=l2_cache_req_stat.dc_hit_in_l2/,instructions}' &

    run_perf "core3" \
        -e '{cpu/event=0x44,umask=0x48,name=ls_any_fills_from_sys.dram_io_all/,cpu/event=0x44,umask=0x50,name=ls_any_fills_from_sys.far_all/,cpu/event=0x44,umask=0x3,name=ls_any_fills_from_sys.local_all/,cpu/event=0x44,umask=0x14,name=ls_any_fills_from_sys.remote_cache/,cpu/event=0x44,umask=0x5f,name=ls_any_fills_from_sys.all/,instructions}' \
        -e '{cpu/event=0x43,umask=0x1,name=ls_dmnd_fills_from_sys.local_l2/,cpu/event=0x43,umask=0x2,name=ls_dmnd_fills_from_sys.local_ccx/,cpu/event=0x43,umask=0x4,name=ls_dmnd_fills_from_sys.near_cache/,cpu/event=0x43,umask=0x8,name=ls_dmnd_fills_from_sys.dram_io_near/,instructions}' \
        -e '{cpu/event=0x43,umask=0x10,name=ls_dmnd_fills_from_sys.far_cache/,cpu/event=0x43,umask=0x40,name=ls_dmnd_fills_from_sys.dram_io_far/,cpu/event=0x44,umask=0x40,name=ls_any_fills_from_sys.dram_io_far/,cpu/event=0x44,umask=0xff,name=ls_any_fills_from_sys.all1/,instructions}' &

    run_perf "core4" \
        -e '{cpu/event=0x28f,umask=0x4,name=op_cache_hit_miss.miss/,cpu/event=0x28f,umask=0x7,name=op_cache_hit_miss.all/,cpu/event=0x18e,umask=0x18,name=ic_tag_hit_miss.miss/,cpu/event=0x18e,umask=0x1f,name=ic_tag_hit_miss.all/,instructions}' \
        -e '{cpu/event=0x84,name=bp_l1_tlb_miss_l2_tlb_hit/,cpu/event=0x85,umask=0x7,name=bp_l1_tlb_miss_l2_tlb_miss.all/,instructions}' \
        -e '{cpu/event=0x45,umask=0xff,name=ls_l1_d_tlb_miss.all/,cpu/event=0x45,umask=0x33,name=ls_l2_d_tlb_4k_activity.all/,cpu/event=0x45,umask=0xf0,name=ls_l1_d_tlb_miss.all_l2_miss/,cpu/event=0x78,umask=0xff,name=ls_tlb_flush.all/,instructions}' \
        -e '{cpu/event=0x45,umask=0x0f,name=ls_l2_d_tlb_hit.all/,cpu/event=0x45,umask=0x01,name=ls_l2_d_tlb_hit.4k/,cpu/event=0x45,umask=0x02,name=ls_l2_d_tlb_hit.coalesced/,cpu/event=0x45,umask=0x04,name=ls_l2_d_tlb_hit.2M/,instructions}' \
        -e '{cpu/event=0x45,umask=0xf0,name=ls_l2_d_tlb_miss.all/,cpu/event=0x45,umask=0x10,name=ls_l2_d_tlb_miss.4k/,cpu/event=0x45,umask=0x20,name=ls_l2_d_tlb_miss.coalesced/,cpu/event=0x45,umask=0x40,name=ls_l2_d_tlb_miss.2M/,instructions}' &

    run_perf "core5" \
        -e '{cpu/event=0xaa,umask=0x7,name=de_src_op_disp.all/,cpu/event=0xe,umask=0xe,name=fp_disp_faults.sse_avx_all/,cpu/event=0xc1,name=ex_ret_ops0/,cpu-cycles,instructions}' &

    # --- L3 (uncore) ---
    if [[ -n "$L3_PMU" ]]; then
    run_perf "l3" \
        -e "{${L3_PMU}/event=0x4,umask=0xff,enallcores=0x1,enallslices=0x1,threadmask=0x3,name=l3_lookup_state.all_coherent_accesses_to_l3/,${L3_PMU}/event=0x4,umask=0x1,enallcores=0x1,enallslices=0x1,threadmask=0x3,name=l3_lookup_state.l3_miss/,${L3_PMU}/event=0x4,umask=0xfe,enallcores=0x1,enallslices=0x1,threadmask=0x3,name=l3_lookup_state.l3_hit/}" \
        -e "{${L3_PMU}/event=0xac,umask=0x3f,enallcores=0x1,enallslices=0x1,sliceid=0x3,threadmask=0x3,name=l3_xi_sampled_latency.all/,${L3_PMU}/event=0xad,umask=0x3f,enallcores=0x1,enallslices=0x1,sliceid=0x3,threadmask=0x3,name=l3_xi_sampled_latency_requests.all/}" &
    fi

    if [[ -n "$DF_PMU" ]]; then

    # --- DRAM bandwidth (DF, 12 channels) ---
    run_perf "dram_bw_local_rd" \
        -e "{${DF_PMU}/event=0x1f,umask=0x7fe,name=local_read_cs0/,${DF_PMU}/event=0x5f,umask=0x7fe,name=local_read_cs1/,${DF_PMU}/event=0x9f,umask=0x7fe,name=local_read_cs2/,${DF_PMU}/event=0xdf,umask=0x7fe,name=local_read_cs3/,${DF_PMU}/event=0x11f,umask=0x7fe,name=local_read_cs4/,${DF_PMU}/event=0x15f,umask=0x7fe,name=local_read_cs5/,${DF_PMU}/event=0x19f,umask=0x7fe,name=local_read_cs6/,${DF_PMU}/event=0x1df,umask=0x7fe,name=local_read_cs7/,${DF_PMU}/event=0x21f,umask=0x7fe,name=local_read_cs8/,${DF_PMU}/event=0x25f,umask=0x7fe,name=local_read_cs9/,${DF_PMU}/event=0x29f,umask=0x7fe,name=local_read_cs10/,${DF_PMU}/event=0x2df,umask=0x7fe,name=local_read_cs11/}" &

    run_perf "dram_bw_local_wr" \
        -e "{${DF_PMU}/event=0x1f,umask=0x7ff,name=local_write_cs0/,${DF_PMU}/event=0x5f,umask=0x7ff,name=local_write_cs1/,${DF_PMU}/event=0x9f,umask=0x7ff,name=local_write_cs2/,${DF_PMU}/event=0xdf,umask=0x7ff,name=local_write_cs3/,${DF_PMU}/event=0x11f,umask=0x7ff,name=local_write_cs4/,${DF_PMU}/event=0x15f,umask=0x7ff,name=local_write_cs5/,${DF_PMU}/event=0x19f,umask=0x7ff,name=local_write_cs6/,${DF_PMU}/event=0x1df,umask=0x7ff,name=local_write_cs7/,${DF_PMU}/event=0x21f,umask=0x7ff,name=local_write_cs8/,${DF_PMU}/event=0x25f,umask=0x7ff,name=local_write_cs9/,${DF_PMU}/event=0x29f,umask=0x7ff,name=local_write_cs10/,${DF_PMU}/event=0x2df,umask=0x7ff,name=local_write_cs11/}" &

    run_perf "dram_bw_remote_rd" \
        -e "{${DF_PMU}/event=0x1f,umask=0xbfe,name=remote_read_cs0/,${DF_PMU}/event=0x5f,umask=0xbfe,name=remote_read_cs1/,${DF_PMU}/event=0x9f,umask=0xbfe,name=remote_read_cs2/,${DF_PMU}/event=0xdf,umask=0xbfe,name=remote_read_cs3/,${DF_PMU}/event=0x11f,umask=0xbfe,name=remote_read_cs4/,${DF_PMU}/event=0x15f,umask=0xbfe,name=remote_read_cs5/,${DF_PMU}/event=0x19f,umask=0xbfe,name=remote_read_cs6/,${DF_PMU}/event=0x1df,umask=0xbfe,name=remote_read_cs7/,${DF_PMU}/event=0x21f,umask=0xbfe,name=remote_read_cs8/,${DF_PMU}/event=0x25f,umask=0xbfe,name=remote_read_cs9/,${DF_PMU}/event=0x29f,umask=0xbfe,name=remote_read_cs10/,${DF_PMU}/event=0x2df,umask=0xbfe,name=remote_read_cs11/}" &

    run_perf "dram_bw_remote_wr" \
        -e "{${DF_PMU}/event=0x1f,umask=0xbff,name=remote_write_cs0/,${DF_PMU}/event=0x5f,umask=0xbff,name=remote_write_cs1/,${DF_PMU}/event=0x9f,umask=0xbff,name=remote_write_cs2/,${DF_PMU}/event=0xdf,umask=0xbff,name=remote_write_cs3/,${DF_PMU}/event=0x11f,umask=0xbff,name=remote_write_cs4/,${DF_PMU}/event=0x15f,umask=0xbff,name=remote_write_cs5/,${DF_PMU}/event=0x19f,umask=0xbff,name=remote_write_cs6/,${DF_PMU}/event=0x1df,umask=0xbff,name=remote_write_cs7/,${DF_PMU}/event=0x21f,umask=0xbff,name=remote_write_cs8/,${DF_PMU}/event=0x25f,umask=0xbff,name=remote_write_cs9/,${DF_PMU}/event=0x29f,umask=0xbff,name=remote_write_cs10/,${DF_PMU}/event=0x2df,umask=0xbff,name=remote_write_cs11/}" &

    # --- DMA IO bandwidth (upstream read/write, 4 IOMs, local + remote) ---
    run_perf "dma_io_local" \
        -e "{${DF_PMU}/event=0x81f,umask=0x7fe,name=local_socket_upstream_read_beats_iom0/,${DF_PMU}/event=0x85f,umask=0x7fe,name=local_socket_upstream_read_beats_iom1/,${DF_PMU}/event=0x89f,umask=0x7fe,name=local_socket_upstream_read_beats_iom2/,${DF_PMU}/event=0x8df,umask=0x7fe,name=local_socket_upstream_read_beats_iom3/}" \
        -e "{${DF_PMU}/event=0x81f,umask=0x7ff,name=local_socket_upstream_write_beats_iom0/,${DF_PMU}/event=0x85f,umask=0x7ff,name=local_socket_upstream_write_beats_iom1/,${DF_PMU}/event=0x89f,umask=0x7ff,name=local_socket_upstream_write_beats_iom2/,${DF_PMU}/event=0x8df,umask=0x7ff,name=local_socket_upstream_write_beats_iom3/}" &

    run_perf "dma_io_remote" \
        -e "{${DF_PMU}/event=0x81f,umask=0xbfe,name=remote_socket_upstream_read_beats_iom0/,${DF_PMU}/event=0x85f,umask=0xbfe,name=remote_socket_upstream_read_beats_iom1/,${DF_PMU}/event=0x89f,umask=0xbfe,name=remote_socket_upstream_read_beats_iom2/,${DF_PMU}/event=0x8df,umask=0xbfe,name=remote_socket_upstream_read_beats_iom3/}" \
        -e "{${DF_PMU}/event=0x81f,umask=0xbff,name=remote_socket_upstream_write_beats_iom0/,${DF_PMU}/event=0x85f,umask=0xbff,name=remote_socket_upstream_write_beats_iom1/,${DF_PMU}/event=0x89f,umask=0xbff,name=remote_socket_upstream_write_beats_iom2/,${DF_PMU}/event=0x8df,umask=0xbff,name=remote_socket_upstream_write_beats_iom3/}" &

    # --- Socket inbound/outbound data beats (xGMI/Infinity Fabric inter-socket BW) ---
    run_perf "socket_bw_local_in" \
        -e "{${DF_PMU}/event=0x41e,umask=0x7fe,name=local_socket_inf0_inbound_data_beats_ccm0/,${DF_PMU}/event=0x45e,umask=0x7fe,name=local_socket_inf0_inbound_data_beats_ccm1/,${DF_PMU}/event=0x49e,umask=0x7fe,name=local_socket_inf0_inbound_data_beats_ccm2/,${DF_PMU}/event=0x4de,umask=0x7fe,name=local_socket_inf0_inbound_data_beats_ccm3/,${DF_PMU}/event=0x51e,umask=0x7fe,name=local_socket_inf0_inbound_data_beats_ccm4/,${DF_PMU}/event=0x55e,umask=0x7fe,name=local_socket_inf0_inbound_data_beats_ccm5/,${DF_PMU}/event=0x59e,umask=0x7fe,name=local_socket_inf0_inbound_data_beats_ccm6/,${DF_PMU}/event=0x5de,umask=0x7fe,name=local_socket_inf0_inbound_data_beats_ccm7/}" \
        -e "{${DF_PMU}/event=0x41f,umask=0x7fe,name=local_socket_inf1_inbound_data_beats_ccm0/,${DF_PMU}/event=0x45f,umask=0x7fe,name=local_socket_inf1_inbound_data_beats_ccm1/,${DF_PMU}/event=0x49f,umask=0x7fe,name=local_socket_inf1_inbound_data_beats_ccm2/,${DF_PMU}/event=0x4df,umask=0x7fe,name=local_socket_inf1_inbound_data_beats_ccm3/,${DF_PMU}/event=0x51f,umask=0x7fe,name=local_socket_inf1_inbound_data_beats_ccm4/,${DF_PMU}/event=0x55f,umask=0x7fe,name=local_socket_inf1_inbound_data_beats_ccm5/,${DF_PMU}/event=0x59f,umask=0x7fe,name=local_socket_inf1_inbound_data_beats_ccm6/,${DF_PMU}/event=0x5df,umask=0x7fe,name=local_socket_inf1_inbound_data_beats_ccm7/}" &

    run_perf "socket_bw_local_out" \
        -e "{${DF_PMU}/event=0x41e,umask=0x7ff,name=local_socket_inf0_outbound_data_beats_ccm0/,${DF_PMU}/event=0x45e,umask=0x7ff,name=local_socket_inf0_outbound_data_beats_ccm1/,${DF_PMU}/event=0x49e,umask=0x7ff,name=local_socket_inf0_outbound_data_beats_ccm2/,${DF_PMU}/event=0x4de,umask=0x7ff,name=local_socket_inf0_outbound_data_beats_ccm3/,${DF_PMU}/event=0x51e,umask=0x7ff,name=local_socket_inf0_outbound_data_beats_ccm4/,${DF_PMU}/event=0x55e,umask=0x7ff,name=local_socket_inf0_outbound_data_beats_ccm5/,${DF_PMU}/event=0x59e,umask=0x7ff,name=local_socket_inf0_outbound_data_beats_ccm6/,${DF_PMU}/event=0x5de,umask=0x7ff,name=local_socket_inf0_outbound_data_beats_ccm7/}" \
        -e "{${DF_PMU}/event=0x41f,umask=0x7ff,name=local_socket_inf1_outbound_data_beats_ccm0/,${DF_PMU}/event=0x45f,umask=0x7ff,name=local_socket_inf1_outbound_data_beats_ccm1/,${DF_PMU}/event=0x49f,umask=0x7ff,name=local_socket_inf1_outbound_data_beats_ccm2/,${DF_PMU}/event=0x4df,umask=0x7ff,name=local_socket_inf1_outbound_data_beats_ccm3/,${DF_PMU}/event=0x51f,umask=0x7ff,name=local_socket_inf1_outbound_data_beats_ccm4/,${DF_PMU}/event=0x55f,umask=0x7ff,name=local_socket_inf1_outbound_data_beats_ccm5/,${DF_PMU}/event=0x59f,umask=0x7ff,name=local_socket_inf1_outbound_data_beats_ccm6/,${DF_PMU}/event=0x5df,umask=0x7ff,name=local_socket_inf1_outbound_data_beats_ccm7/}" &

    run_perf "socket_bw_remote_in" \
        -e "{${DF_PMU}/event=0x41e,umask=0xbfe,name=remote_socket_inf0_inbound_data_beats_ccm0/,${DF_PMU}/event=0x45e,umask=0xbfe,name=remote_socket_inf0_inbound_data_beats_ccm1/,${DF_PMU}/event=0x49e,umask=0xbfe,name=remote_socket_inf0_inbound_data_beats_ccm2/,${DF_PMU}/event=0x4de,umask=0xbfe,name=remote_socket_inf0_inbound_data_beats_ccm3/,${DF_PMU}/event=0x51e,umask=0xbfe,name=remote_socket_inf0_inbound_data_beats_ccm4/,${DF_PMU}/event=0x55e,umask=0xbfe,name=remote_socket_inf0_inbound_data_beats_ccm5/,${DF_PMU}/event=0x59e,umask=0xbfe,name=remote_socket_inf0_inbound_data_beats_ccm6/,${DF_PMU}/event=0x5de,umask=0xbfe,name=remote_socket_inf0_inbound_data_beats_ccm7/}" \
        -e "{${DF_PMU}/event=0x41f,umask=0xbfe,name=remote_socket_inf1_inbound_data_beats_ccm0/,${DF_PMU}/event=0x45f,umask=0xbfe,name=remote_socket_inf1_inbound_data_beats_ccm1/,${DF_PMU}/event=0x49f,umask=0xbfe,name=remote_socket_inf1_inbound_data_beats_ccm2/,${DF_PMU}/event=0x4df,umask=0xbfe,name=remote_socket_inf1_inbound_data_beats_ccm3/,${DF_PMU}/event=0x51f,umask=0xbfe,name=remote_socket_inf1_inbound_data_beats_ccm4/,${DF_PMU}/event=0x55f,umask=0xbfe,name=remote_socket_inf1_inbound_data_beats_ccm5/,${DF_PMU}/event=0x59f,umask=0xbfe,name=remote_socket_inf1_inbound_data_beats_ccm6/,${DF_PMU}/event=0x5df,umask=0xbfe,name=remote_socket_inf1_inbound_data_beats_ccm7/}" &

    run_perf "socket_bw_remote_out" \
        -e "{${DF_PMU}/event=0x41e,umask=0xbff,name=remote_socket_inf0_outbound_data_beats_ccm0/,${DF_PMU}/event=0x45e,umask=0xbff,name=remote_socket_inf0_outbound_data_beats_ccm1/,${DF_PMU}/event=0x49e,umask=0xbff,name=remote_socket_inf0_outbound_data_beats_ccm2/,${DF_PMU}/event=0x4de,umask=0xbff,name=remote_socket_inf0_outbound_data_beats_ccm3/,${DF_PMU}/event=0x51e,umask=0xbff,name=remote_socket_inf0_outbound_data_beats_ccm4/,${DF_PMU}/event=0x55e,umask=0xbff,name=remote_socket_inf0_outbound_data_beats_ccm5/,${DF_PMU}/event=0x59e,umask=0xbff,name=remote_socket_inf0_outbound_data_beats_ccm6/,${DF_PMU}/event=0x5de,umask=0xbff,name=remote_socket_inf0_outbound_data_beats_ccm7/}" \
        -e "{${DF_PMU}/event=0x41f,umask=0xbff,name=remote_socket_inf1_outbound_data_beats_ccm0/,${DF_PMU}/event=0x45f,umask=0xbff,name=remote_socket_inf1_outbound_data_beats_ccm1/,${DF_PMU}/event=0x49f,umask=0xbff,name=remote_socket_inf1_outbound_data_beats_ccm2/,${DF_PMU}/event=0x4df,umask=0xbff,name=remote_socket_inf1_outbound_data_beats_ccm3/,${DF_PMU}/event=0x51f,umask=0xbff,name=remote_socket_inf1_outbound_data_beats_ccm4/,${DF_PMU}/event=0x55f,umask=0xbff,name=remote_socket_inf1_outbound_data_beats_ccm5/,${DF_PMU}/event=0x59f,umask=0xbff,name=remote_socket_inf1_outbound_data_beats_ccm6/,${DF_PMU}/event=0x5df,umask=0xbff,name=remote_socket_inf1_outbound_data_beats_ccm7/}" &

    # --- Outbound link bandwidth (all 8 links) ---
    run_perf "link_bw" \
        -e "{${DF_PMU}/event=0xb5f,umask=0xf3e,name=local_socket_outbound_data_beats_link0/,${DF_PMU}/event=0xb9f,umask=0xf3e,name=local_socket_outbound_data_beats_link1/,${DF_PMU}/event=0xbdf,umask=0xf3e,name=local_socket_outbound_data_beats_link2/,${DF_PMU}/event=0xc1f,umask=0xf3e,name=local_socket_outbound_data_beats_link3/,${DF_PMU}/event=0xc5f,umask=0xf3e,name=local_socket_outbound_data_beats_link4/,${DF_PMU}/event=0xc9f,umask=0xf3e,name=local_socket_outbound_data_beats_link5/,${DF_PMU}/event=0xcdf,umask=0xf3e,name=local_socket_outbound_data_beats_link6/,${DF_PMU}/event=0xd1f,umask=0xf3e,name=local_socket_outbound_data_beats_link7/}" &

    fi # end DF_PMU guard

    # --- Pipeline Top-Down ---
    run_perf "pipeline" \
        -e '{cpu/event=0x1a0,umask=0x1,name=de_no_dispatch_per_slot.no_ops_from_frontend/,cpu/event=0x1a0,umask=0x1,cmask=0x6,name=de_no_dispatch_per_cycle.no_ops_from_frontend/,cpu/event=0x1a0,umask=0x60,name=de_no_dispatch_per_slot.smt_contention/,cpu/event=0x1a2,umask=0x30,name=de_no_dispatch_per_slot.above_ldq_or_intsched_lmt/,cpu/event=0x76,name=ls_not_halted_cyc0/}' \
        -e '{cpu/event=0xaa,umask=0x7,name=de_src_op_disp.all_g33/,cpu/event=0xc1,name=ex_ret_ops1/,cpu/event=0xc3,name=ex_ret_brn_misp_g33/,cpu/event=0x96,name=resyncs_or_nc_redirects/,cpu/event=0x76,name=ls_not_halted_cyc1/}' \
        -e '{cpu/event=0x1a0,umask=0x1e,name=de_no_dispatch_per_slot.backend_stalls/,cpu/event=0xd6,umask=0xa2,name=ex_no_retire.load_not_complete/,cpu/event=0xd6,umask=0x2,name=ex_no_retire.not_complete/,cpu/event=0x76,name=ls_not_halted_cyc2/}' \
        -e '{cpu/event=0xc1,name=ex_ret_ops2/,cpu/event=0x1c2,name=ex_ret_ucode_ops/,cpu/event=0x76,name=ls_not_halted_cyc3/}' &

    # --- Power ---
    run_perf "power" -e power/energy-pkg/ &

else
    echo "ERROR: Unsupported vendor: $VENDOR"; exit 1
fi

###############################################################################
# Wait for all background perf commands
###############################################################################
echo ""
echo "[$(date +%H:%M:%S)] Waiting for all collectors to finish..."
wait
echo "[$(date +%H:%M:%S)] All done."

###############################################################################
# Combine all outputs into a single report
###############################################################################
REPORT="$OUTDIR/METRICS_REPORT.txt"
{
    echo "========================================================================"
    echo "  COMPREHENSIVE METRICS REPORT"
    echo "  Command run:  sudo bash $ORIG_CMD"
    echo "  Platform: $MODEL_NAME"
    echo "  Vendor:   $VENDOR | Sockets: $SOCKETS | Cores/Socket: $CORES_PER_SOCKET"
    echo "  Duration: ${DURATION}s | Interval: $INTERVAL_MSG | Collected: $(date)"
    echo "========================================================================"
    echo ""

    for f in "$OUTDIR"/perf_*.txt; do
        label=$(basename "$f" .txt | sed 's/^perf_//')
        echo "------------------------------------------------------------------------"
        echo "  [$label]"
        echo "------------------------------------------------------------------------"
        grep -v '^WARNING' "$f" | grep -v '^$'
        echo ""
    done

    if [[ -f "$TURBO_FILE" ]] && [[ -s "$TURBO_FILE" ]]; then
        echo "------------------------------------------------------------------------"
        echo "  [turbostat]"
        echo "------------------------------------------------------------------------"
        head -40 "$TURBO_FILE"
        echo "  ... (see $TURBO_FILE for full output)"
    fi

    echo ""
    echo "========================================================================"
    echo "  END OF REPORT"
    echo "========================================================================"
} > "$REPORT"

echo ""
echo "============================================="
echo " Output Files"
echo "============================================="
echo "  Combined report:  $REPORT"
ls -1 "$OUTDIR"/perf_*.txt 2>/dev/null | while read f; do
    echo "  $(basename "$f")"
done
[[ -n "${TURBO_PID:-}" ]] && echo "  turbostat.txt"
echo "============================================="
echo ""
echo "View report:  cat $REPORT"
