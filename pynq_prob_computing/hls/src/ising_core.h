#pragma once
// ============================================================
//  ising_core.h  –  Ising SA core for PYNQ / Vivado HLS
//
//  두 단계 운용 흐름
//  ─────────────────────────────────────────────────────────────
//  [Annealing]  beta: 0 → beta_final  (N_ANNEAL_STEPS 단계)
//               매 sweep마다 spin 상태를 sample_buf 에 기록
//
//  [Measurement] beta = beta_final 고정
//               매 sweep마다 spin 상태의 빈도를 hist_buf 에 누적
//
//  레지스터 맵 (AXI-lite, 4-byte aligned)
//  ─────────────────────────────────────────────────────────────
//  0x00  control        – bit0: start (write 1 to launch)
//  0x04  status         – 0:idle / 1:annealing / 2:measuring / 3:done
//  0x08  n_anneal_sweeps
//  0x0C  n_meas_sweeps
//  0x10  beta_final_raw  – ap_ufixed<16,4> bit pattern
//  0x14  n_anneal_steps
//  0x18  lfsr_seed       – must be non-zero
//  0x20..0x9C  J_flat[64]  (int32, i*8+j)
//  0xA0..0xBC  h_field[8]  (int32)
//  0xC0  sample_buf_addr (lower 32-bit of physical address)
//  0xC4  hist_buf_addr   (lower 32-bit of physical address)
// ============================================================

#include <ap_int.h>
#include <ap_fixed.h>
#include <stdint.h>

// ── System parameters ──────────────────────────────────────────
#define N_SPINS         8
#define HIST_BINS       (1 << N_SPINS)   // 256

// ── Fixed-point types ──────────────────────────────────────────
// beta: 0 .. 15.9999  (4 integer bits, 12 fractional)
typedef ap_ufixed<16, 4, AP_RND, AP_SAT>  beta_t;

// Spin state: bit i = 0 → s_i = –1, bit i = 1 → s_i = +1
typedef ap_uint<N_SPINS>  spin_t;

// ── Status codes ───────────────────────────────────────────────
#define STATUS_IDLE       0u
#define STATUS_ANNEALING  1u
#define STATUS_MEASURING  2u
#define STATUS_DONE       3u

// ── Top-level HLS function ─────────────────────────────────────
//  Interfaces (see ising_core.cpp for #pragma HLS INTERFACE directives):
//    s_axilite : all scalar args + J_flat + h_field + return (ctrl bundle)
//    m_axi     : sample_buf  (bundle gmem0)
//    m_axi     : hist_buf    (bundle gmem1)
void ising_core(
    // ── AXI-lite scalar inputs ──
    uint32_t  n_anneal_sweeps,   // total sweeps in annealing phase
    uint32_t  n_meas_sweeps,     // total sweeps in measurement phase
    uint32_t  beta_final_raw,    // beta as ap_ufixed<16,4> bit pattern
    uint32_t  n_anneal_steps,    // number of annealing steps (>=1)
    uint32_t  lfsr_seed,         // LFSR seed (must be != 0)

    // ── AXI-lite array inputs ──
    // J_{ij}: symmetric coupling matrix, diagonal = 0
    // packed as int32; actual values are int8 range (−128..127)
    int32_t   J_flat[N_SPINS * N_SPINS],
    int32_t   h_field[N_SPINS],           // external field per spin

    // ── AXI4 master outputs (physical addresses from host) ──
    // sample_buf : uint8 array, size >= n_anneal_sweeps
    //              each byte = spin_t bit-pattern of one sweep
    uint8_t  *sample_buf,

    // hist_buf : uint32 array, size = HIST_BINS (256)
    //            hist_buf[spin_pattern]++ per measurement sweep
    uint32_t *hist_buf
);
