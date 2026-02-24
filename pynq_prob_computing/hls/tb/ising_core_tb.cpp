// ============================================================
//  ising_core_tb.cpp  –  C-simulation testbench for ising_core
//
//  컴파일 & 실행 (Vivado HLS 없이 순수 g++ 로 확인):
//    g++ -std=c++11 -I../src ../src/ising_core.cpp ising_core_tb.cpp -o tb && ./tb
//
//  Vivado HLS C-sim:
//    vitis_hls -f ../scripts/run_csim.tcl
// ============================================================

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <cassert>

// ── Stub types for g++ (not needed when compiled under Vivado HLS) ─
#ifndef __VIVADO_HLS__
#include <stdint.h>
// Minimal stubs so ising_core.h & friends compile under plain g++
struct ap_ufixed_stub { double v; };
#define AP_RND  0
#define AP_SAT  0
// Provide thin stubs only if the real ap_* headers are absent
#ifndef AP_INT_H
#  include "ap_stub.h"   // see note below – or just run under Vivado HLS
#endif
#endif

// When running under Vivado HLS, ap_int.h / ap_fixed.h are available.
// For plain g++ we rely on the real headers being in the include path
// (supplied by Vitis HLS installation).
#include "ising_core.h"

// ── Test parameters ────────────────────────────────────────────
#define N_ANNEAL_SWEEPS  1000u
#define N_MEAS_SWEEPS    2000u
#define N_ANNEAL_STEPS   10u
#define LFSR_SEED        0x12345678u

// Simple 8-spin ferromagnet: all J_{ij} = +1 (i != j), h_i = 0
// Ground state: all spins aligned (0b00000000 or 0b11111111)
static void make_ferromagnet(int32_t J[N_SPINS * N_SPINS], int32_t h[N_SPINS])
{
    for (int i = 0; i < N_SPINS; i++) {
        h[i] = 0;
        for (int j = 0; j < N_SPINS; j++) {
            J[i * N_SPINS + j] = (i != j) ? 1 : 0;
        }
    }
}

// Encode beta_final = 2.0 as ap_ufixed<16,4> bit pattern
// ap_ufixed<16,4>: 4 integer bits + 12 fractional bits
// 2.0 = 0010.000000000000b = 0x2000
static uint32_t encode_beta(double beta)
{
    // Scale: 2^12 = 4096
    return (uint32_t)(beta * 4096.0 + 0.5);
}

// ── Verify sample buffer (basic sanity) ────────────────────────
static bool check_samples(uint8_t *buf, uint32_t n)
{
    // All entries must be in [0, 255] – trivially true for uint8_t.
    // Check that the buffer is not all-zero (which would suggest a bug).
    uint64_t sum = 0;
    for (uint32_t i = 0; i < n; i++) sum += buf[i];
    printf("[sample_buf] n=%u  sum=%llu  mean=%.3f\n",
           n, (unsigned long long)sum, (double)sum / n);
    return (sum > 0);
}

// ── Verify histogram (basic sanity) ────────────────────────────
static bool check_histogram(uint32_t *hist, uint32_t n_meas)
{
    uint64_t total = 0;
    uint32_t max_cnt = 0;
    int      max_idx = 0;
    for (int k = 0; k < HIST_BINS; k++) {
        total += hist[k];
        if (hist[k] > max_cnt) { max_cnt = hist[k]; max_idx = k; }
    }
    printf("[histogram]  total=%llu (expected %u)  peak_state=0x%02X  peak_cnt=%u\n",
           (unsigned long long)total, n_meas, max_idx, max_cnt);

    // For ferromagnet at high beta (2.0), ground states (0x00 / 0xFF) dominate
    uint32_t gs_cnt = hist[0x00] + hist[0xFF];
    double   frac   = (double)gs_cnt / total;
    printf("[histogram]  gs_fraction=%.3f (hist[0x00]=%u  hist[0xFF]=%u)\n",
           frac, hist[0x00], hist[0xFF]);

    // Sanity: total == n_meas_sweeps
    if (total != n_meas) {
        printf("FAIL: histogram total mismatch (%llu != %u)\n",
               (unsigned long long)total, n_meas);
        return false;
    }
    // At beta=2.0 ferromagnet we expect gs_fraction > 0.1 at minimum
    if (frac < 0.1) {
        printf("WARN: gs_fraction very low – simulation may not have converged\n");
    }
    return true;
}

int main()
{
    printf("=== Ising SA Core Testbench ===\n");
    printf("N_SPINS=%d  N_ANNEAL_SWEEPS=%u  N_MEAS_SWEEPS=%u\n",
           N_SPINS, N_ANNEAL_SWEEPS, N_MEAS_SWEEPS);

    // ── Allocate buffers ───────────────────────────────────────
    static uint8_t  sample_buf[N_ANNEAL_SWEEPS];
    static uint32_t hist_buf[HIST_BINS];
    static int32_t  J_flat[N_SPINS * N_SPINS];
    static int32_t  h_field[N_SPINS];

    memset(sample_buf, 0, sizeof(sample_buf));
    memset(hist_buf,   0, sizeof(hist_buf));

    make_ferromagnet(J_flat, h_field);

    uint32_t beta_raw = encode_beta(2.0);
    printf("beta_final=2.0  encoded=0x%04X\n", beta_raw);

    // ── Run HLS function ───────────────────────────────────────
    ising_core(
        N_ANNEAL_SWEEPS,
        N_MEAS_SWEEPS,
        beta_raw,
        N_ANNEAL_STEPS,
        LFSR_SEED,
        J_flat,
        h_field,
        sample_buf,
        hist_buf
    );

    // ── Validate results ───────────────────────────────────────
    bool ok = true;
    ok &= check_samples(sample_buf, N_ANNEAL_SWEEPS);
    ok &= check_histogram(hist_buf,  N_MEAS_SWEEPS);

    printf("\n%s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
