#pragma once
// ============================================================
//  lfsr.h  –  32-bit Fibonacci LFSR for Vivado HLS
//
//  Primitive polynomial:  x^32 + x^22 + x^2 + x + 1
//  Taps (1-indexed):      32, 22, 2, 1
//  Period:                2^32 − 1  (all nonzero 32-bit values)
//
//  Usage:
//    ap_uint<32> state = seed;   // seed != 0
//    state = lfsr_step(state);   // advance one step
//    uint32_t rnd = (uint32_t)state;
// ============================================================

#include <ap_int.h>

// Advance the LFSR by one step and return the new state.
// Fully inlined → synthesised as combinational logic.
inline ap_uint<32> lfsr_step(ap_uint<32> s)
{
#pragma HLS INLINE
    // New feedback bit = XOR of taps 31, 21, 1, 0  (0-indexed)
    ap_uint<1> bit = s[31] ^ s[21] ^ s[1] ^ s[0];
    return (s << 1) | ap_uint<1>(bit);
}

// Two independent LFSRs in one call (for spin-index + acceptance rand)
// Uses bit-splitting: state_a drives even taps, state_b drives odd taps.
// Caller keeps two separate state variables.
inline void lfsr_step2(ap_uint<32> &sa, ap_uint<32> &sb)
{
#pragma HLS INLINE
    sa = lfsr_step(sa);
    sb = lfsr_step(sb);
}
