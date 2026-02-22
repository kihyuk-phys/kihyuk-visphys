#!/usr/bin/env python3
"""gen_lut.py – Regenerate METROPOLIS_LUT[] in metropolis.h

Run this if you change LUT parameters (resolution, range).
Output goes to stdout; redirect to metropolis.h or copy manually.

Usage:
    python3 gen_lut.py
"""
import math

LUT_SIZE   = 256
RESOLUTION = 32      # entries per unit of beta*dE
UINT32_MAX = 0xFFFFFFFF

print(f"// LUT size={LUT_SIZE}, resolution=1/{RESOLUTION}")
print(f"// index i → exp(-i/{RESOLUTION}) * {hex(UINT32_MAX)}")
print(f"// Covers beta*dE ∈ [0, {LUT_SIZE//RESOLUTION:.1f})")
print()
print("static const uint32_t METROPOLIS_LUT[256] = {")

vals = []
for i in range(LUT_SIZE):
    x = i / RESOLUTION
    v = int(round(math.exp(-x) * UINT32_MAX))
    v = min(v, UINT32_MAX)
    vals.append(f"{v}u")

for row in range(LUT_SIZE // 8):
    chunk = vals[row * 8:(row + 1) * 8]
    print("    " + ", ".join(f"{c:>13}" for c in chunk) + ",")

print("};")
print()
print("// Verification:")
for i in [0, 32, 64, 128, 255]:
    x = i / RESOLUTION
    print(f"// lut[{i:3d}] = exp(-{x:.4f}) = {math.exp(-x):.6f}")
