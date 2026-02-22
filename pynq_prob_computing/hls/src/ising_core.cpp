// ============================================================
//  ising_core.cpp  –  Ising SA HLS top function
//
//  두 단계 운용 흐름
//  ─────────────────────────────────────────────────────────────
//  1. Annealing  : beta 0 → beta_final (n_anneal_steps 단계)
//                  각 sweep 결과를 sample_buf 에 byte 단위 기록
//
//  2. Measurement: beta = beta_final 고정
//                  각 sweep 결과를 hist_buf[spin] 에 누적
//
//  HLS interface summary
//  ─────────────────────────────────────────────────────────────
//  s_axilite (bundle=ctrl) : 모든 scalar + J_flat + h_field + return
//  m_axi     (bundle=gmem0): sample_buf  (write-only, burst)
//  m_axi     (bundle=gmem1): hist_buf    (write-only, burst at end)
// ============================================================

#include "ising_core.h"
#include "lfsr.h"
#include "metropolis.h"

// ── Helper: compute delta-E when flipping spin i ──────────────
//
//  Hamiltonian: H = −Σ_{i<j} J_{ij} s_i s_j − Σ_i h_i s_i
//  Spin encoding: bit i = 0 → s = −1, bit i = 1 → s = +1
//
//  dE = 2 · s_i · ( Σ_j J_{ij} s_j + h_i )
static int32_t compute_dE(
    int        spin_idx,
    spin_t     spins,
    int32_t    J_flat[N_SPINS * N_SPINS],
    int32_t    h_field[N_SPINS])
{
#pragma HLS INLINE
    int si = spins[spin_idx] ? 1 : -1;

    int32_t local_sum = h_field[spin_idx];
COMPUTE_DEj:
    for (int j = 0; j < N_SPINS; j++) {
#pragma HLS UNROLL
        int sj = spins[j] ? 1 : -1;
        local_sum += J_flat[spin_idx * N_SPINS + j] * sj;
    }
    return 2 * si * local_sum;
}

// ── Helper: one full Metropolis sweep over all N_SPINS spins ──
static spin_t metropolis_sweep(
    spin_t      spins,
    beta_t      beta,
    int32_t     J_flat[N_SPINS * N_SPINS],
    int32_t     h_field[N_SPINS],
    ap_uint<32> &lfsr_a,     // spin-selection LFSR  (index mod N)
    ap_uint<32> &lfsr_b)     // acceptance LFSR       (rand32)
{
#pragma HLS INLINE
SWEEP_SPINS:
    for (int i = 0; i < N_SPINS; i++) {
        // Sequential dependency: state after flip(i) feeds flip(i+1)
        // → cannot fully pipeline this loop, but N_SPINS=8 is short
#pragma HLS PIPELINE II=8    // one spin per 8-cycle latency budget

        lfsr_step2(lfsr_a, lfsr_b);

        int32_t dE = compute_dE(i, spins, J_flat, h_field);

        bool accept;
        if (dE <= 0) {
            accept = true;
        } else {
            // beta * dE  (both non-negative)
            ap_ufixed<24, 12> beta_dE = beta * (ap_ufixed<12, 12>)(uint32_t)dE;
            accept = metropolis_accept(beta_dE, lfsr_b);
        }

        if (accept) {
            spins[i] = !spins[i];   // flip bit i
        }
    }
    return spins;
}

// ── Top-level function ─────────────────────────────────────────
void ising_core(
    uint32_t  n_anneal_sweeps,
    uint32_t  n_meas_sweeps,
    uint32_t  beta_final_raw,
    uint32_t  n_anneal_steps,
    uint32_t  lfsr_seed,
    int32_t   J_flat[N_SPINS * N_SPINS],
    int32_t   h_field[N_SPINS],
    uint8_t  *sample_buf,
    uint32_t *hist_buf)
{
    // ── AXI-lite slave interface ────────────────────────────────
#pragma HLS INTERFACE s_axilite port=return        bundle=ctrl
#pragma HLS INTERFACE s_axilite port=n_anneal_sweeps bundle=ctrl
#pragma HLS INTERFACE s_axilite port=n_meas_sweeps   bundle=ctrl
#pragma HLS INTERFACE s_axilite port=beta_final_raw  bundle=ctrl
#pragma HLS INTERFACE s_axilite port=n_anneal_steps  bundle=ctrl
#pragma HLS INTERFACE s_axilite port=lfsr_seed       bundle=ctrl
#pragma HLS INTERFACE s_axilite port=J_flat          bundle=ctrl
#pragma HLS INTERFACE s_axilite port=h_field         bundle=ctrl

    // ── AXI4 master interfaces for bulk data ───────────────────
#pragma HLS INTERFACE m_axi port=sample_buf depth=1048576 bundle=gmem0 \
    latency=64 num_write_outstanding=8 max_write_burst_length=256
#pragma HLS INTERFACE m_axi port=hist_buf   depth=256     bundle=gmem1 \
    latency=64 num_write_outstanding=2 max_write_burst_length=256

    // ── Array partitioning for parallel access ─────────────────
#pragma HLS ARRAY_PARTITION variable=J_flat  cyclic factor=8 dim=1
#pragma HLS ARRAY_PARTITION variable=h_field complete

    // ── Local histogram (BRAM, written to DDR at the end) ──────
    uint32_t local_hist[HIST_BINS];
#pragma HLS ARRAY_PARTITION variable=local_hist cyclic factor=4 dim=1
HIST_INIT:
    for (int k = 0; k < HIST_BINS; k++) {
#pragma HLS PIPELINE II=1
        local_hist[k] = 0;
    }

    // ── Decode beta_final from bit pattern ─────────────────────
    beta_t beta_final;
    beta_final.range(15, 0) = beta_final_raw & 0xFFFFu;

    // ── LFSR initialisation ────────────────────────────────────
    ap_uint<32> lfsr_a = (lfsr_seed != 0) ? (ap_uint<32>)lfsr_seed
                                           : (ap_uint<32>)0xDEADBEEFu;
    // Derive independent second state by advancing 16 steps
    ap_uint<32> lfsr_b = lfsr_a;
LFSR_WARM:
    for (int k = 0; k < 16; k++) {
#pragma HLS UNROLL
        lfsr_b = lfsr_step(lfsr_b);
    }

    // ── Initial random spin configuration ──────────────────────
    lfsr_a = lfsr_step(lfsr_a);
    spin_t spins = (spin_t)(lfsr_a.range(N_SPINS - 1, 0));

    // ── Annealing phase ────────────────────────────────────────
    // beta increases linearly from beta_step to beta_final
    // n_anneal_steps sub-phases, each with sweeps_per_step sweeps
    uint32_t sweeps_per_step = (n_anneal_steps > 0)
                               ? (n_anneal_sweeps / n_anneal_steps)
                               : n_anneal_sweeps;
    if (sweeps_per_step == 0) sweeps_per_step = 1;

    // beta_step = beta_final / n_anneal_steps (in fixed-point)
    beta_t beta_step = (n_anneal_steps > 0)
                       ? (beta_t)(beta_final / (beta_t)(uint32_t)n_anneal_steps)
                       : beta_final;

    uint32_t sample_idx = 0;
    beta_t   beta_cur   = beta_step;   // start at first step, not 0

ANNEAL_STEPS:
    for (uint32_t step = 0; step < n_anneal_steps; step++) {
        // Recompute beta for this step (avoids accumulated fixed-point error)
        beta_cur = (beta_t)((beta_t)(uint32_t)(step + 1) * beta_step);

ANNEAL_SWEEPS:
        for (uint32_t sw = 0; sw < sweeps_per_step; sw++) {
#pragma HLS PIPELINE off   // outer sweep loop: no false trip-count assumption
            spins = metropolis_sweep(spins, beta_cur, J_flat, h_field,
                                     lfsr_a, lfsr_b);
            // Record spin state
            sample_buf[sample_idx] = (uint8_t)(uint32_t)spins;
            sample_idx++;
        }
    }

    // ── Measurement phase ──────────────────────────────────────
MEAS_SWEEPS:
    for (uint32_t sw = 0; sw < n_meas_sweeps; sw++) {
        spins = metropolis_sweep(spins, beta_final, J_flat, h_field,
                                 lfsr_a, lfsr_b);
        // Accumulate histogram
        uint8_t idx = (uint8_t)(uint32_t)spins;
        local_hist[idx]++;
    }

    // ── Flush histogram to DDR ─────────────────────────────────
HIST_FLUSH:
    for (int k = 0; k < HIST_BINS; k++) {
#pragma HLS PIPELINE II=1
        hist_buf[k] = local_hist[k];
    }
}
