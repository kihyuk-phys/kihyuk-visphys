"""emulation.py – NumPy SW emulation of the Ising SA HLS core.

Mirrors the two-phase operation flow of ising_core.cpp exactly:

  Phase 1 – Annealing
    beta: 0 → beta_final  (n_anneal_steps 단계)
    매 sweep 마다 spin 상태를 sample_buffer 에 기록

  Phase 2 – Measurement
    beta = beta_final 고정
    매 sweep 마다 histogram 에 spin 상태 누적

이 모듈은 FPGA 없이도 알고리즘을 검증하고 시각화할 수 있도록 한다.
HLS 코드와 동일한 파라미터 이름을 사용한다.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Optional

import numpy as np


# ── Constants ──────────────────────────────────────────────────
N_SPINS   = 8
HIST_BINS = 1 << N_SPINS   # 256

# Metropolis LUT: threshold[i] = round(exp(-i/32) * 0xFFFFFFFF)
# Covers beta*dE in [0, 8.0), resolution 1/32
_LUT_RES   = 32
_LUT_SIZE  = 256
_METRO_LUT = np.array(
    [round(math.exp(-i / _LUT_RES) * 0xFFFFFFFF) for i in range(_LUT_SIZE)],
    dtype=np.uint64,
)


def _encode_beta(beta: float) -> int:
    """Encode beta as ap_ufixed<16,4> bit pattern (12 fractional bits)."""
    return int(beta * (1 << 12)) & 0xFFFF


def _decode_beta(raw: int) -> float:
    """Decode ap_ufixed<16,4> bit pattern back to float."""
    return (raw & 0xFFFF) / (1 << 12)


def _metropolis_threshold(beta_dE: float) -> int:
    """Return the 32-bit acceptance threshold for a given beta*dE value."""
    idx = int(beta_dE * _LUT_RES)
    if idx >= _LUT_SIZE:
        return 0
    return int(_METRO_LUT[idx])


def _compute_dE(spin_idx: int, spins: np.ndarray,
                J: np.ndarray, h: np.ndarray) -> int:
    """Compute delta-E when flipping spin at spin_idx.

    Hamiltonian: H = -sum_{i<j} J_{ij} s_i s_j - sum_i h_i s_i
    Spin encoding: 0 → -1, 1 → +1
    dE = 2 * s_i * (sum_j J_{ij} s_j + h_i)
    """
    s = spins.astype(np.int8) * 2 - 1   # {0,1} → {-1,+1}
    si = int(s[spin_idx])
    local_sum = int(h[spin_idx]) + int(np.dot(J[spin_idx], s))
    return 2 * si * local_sum


def _metropolis_sweep(spins: np.ndarray, beta: float,
                      J: np.ndarray, h: np.ndarray,
                      rng: np.random.Generator) -> np.ndarray:
    """One full Metropolis sweep over all N_SPINS spins (sequential)."""
    for i in range(N_SPINS):
        dE = _compute_dE(i, spins, J, h)
        if dE <= 0:
            spins[i] ^= 1
        else:
            beta_dE = beta * dE
            threshold = _metropolis_threshold(beta_dE)
            rand32 = int(rng.integers(0, 0x100000000, dtype=np.uint64))
            if rand32 < threshold:
                spins[i] ^= 1
    return spins


@dataclass
class IsingResult:
    """Results from a completed IsingEmulator run.

    Attributes
    ----------
    sample_buffer : np.ndarray, shape (n_anneal_sweeps,), dtype=uint8
        Spin state (bit-packed) recorded every sweep during annealing.
        Index 0 = first sweep, last = end of annealing.
    histogram : np.ndarray, shape (256,), dtype=uint32
        Occurrence count of each 8-bit spin configuration during measurement.
    beta_schedule : np.ndarray, shape (n_anneal_steps,), dtype=float
        Actual beta value at each annealing sub-step.
    """
    sample_buffer : np.ndarray
    histogram     : np.ndarray
    beta_schedule : np.ndarray

    # ── Convenience properties ──────────────────────────────────

    def energy_history(self, J: np.ndarray, h: np.ndarray) -> np.ndarray:
        """Compute Hamiltonian energy for every sample in sample_buffer.

        Parameters
        ----------
        J : (8,8) array – coupling matrix
        h : (8,)  array – external field
        Returns
        -------
        energies : (n_anneal_sweeps,) float array
        """
        energies = np.empty(len(self.sample_buffer), dtype=float)
        for k, byte in enumerate(self.sample_buffer):
            s = np.array([(byte >> i) & 1 for i in range(N_SPINS)],
                         dtype=np.int8) * 2 - 1   # {-1,+1}
            E = -0.5 * float(s @ J @ s) - float(h @ s)
            energies[k] = E
        return energies

    def ground_state_fraction(self) -> float:
        """Fraction of measurement sweeps spent in the two ground states
        (all-up 0xFF or all-down 0x00) for a ferromagnet."""
        return float(self.histogram[0x00] + self.histogram[0xFF]) \
               / self.histogram.sum()

    def most_probable_state(self) -> int:
        """8-bit spin pattern with the highest measurement count."""
        return int(np.argmax(self.histogram))


class IsingEmulator:
    """Software emulation of the Ising SA FPGA core.

    Matches the register interface of ising_core.cpp:

    Parameters
    ----------
    n_spins : int
        Number of Ising spins (must be 8 for FPGA compatibility).
    J : array_like, shape (n_spins, n_spins)
        Coupling matrix (symmetric, diagonal = 0).
        Integer values recommended (int8 range: −128..127).
    h : array_like, shape (n_spins,)
        External field per spin.  Integer values recommended.
    seed : int, optional
        NumPy RNG seed for reproducibility.

    Examples
    --------
    >>> import numpy as np
    >>> from pynq_prob_computing.python.emulation import IsingEmulator
    >>> J = np.ones((8, 8), dtype=np.int32) - np.eye(8, dtype=np.int32)
    >>> h = np.zeros(8, dtype=np.int32)
    >>> emu = IsingEmulator(J=J, h=h, seed=42)
    >>> result = emu.run(n_anneal_sweeps=500, n_meas_sweeps=1000,
    ...                  beta_final=2.0, n_anneal_steps=10)
    >>> print(result.ground_state_fraction())
    """

    def __init__(self,
                 J: np.ndarray,
                 h: np.ndarray,
                 n_spins: int = N_SPINS,
                 seed: Optional[int] = None):
        if n_spins != N_SPINS:
            raise ValueError(f"Only n_spins={N_SPINS} is supported "
                             f"(got {n_spins})")

        self.J     = np.asarray(J, dtype=np.int32).reshape(N_SPINS, N_SPINS)
        self.h     = np.asarray(h, dtype=np.int32).reshape(N_SPINS)
        self._rng  = np.random.default_rng(seed)

    # ── Register-level API (mirrors PYNQ driver) ────────────────

    @staticmethod
    def encode_beta(beta: float) -> int:
        """Encode a float beta as ap_ufixed<16,4> bit pattern."""
        return _encode_beta(beta)

    @staticmethod
    def decode_beta(raw: int) -> float:
        """Decode ap_ufixed<16,4> bit pattern to float."""
        return _decode_beta(raw)

    # ── High-level run method ───────────────────────────────────

    def run(self,
            n_anneal_sweeps: int,
            n_meas_sweeps: int,
            beta_final: float,
            n_anneal_steps: int,
            verbose: bool = False) -> IsingResult:
        """Execute the two-phase SA and return an IsingResult.

        Parameters
        ----------
        n_anneal_sweeps : int
            Total sweeps in the annealing phase.
        n_meas_sweeps : int
            Total sweeps in the measurement phase.
        beta_final : float
            Final inverse temperature.
        n_anneal_steps : int
            Number of linearly-spaced beta sub-steps (>= 1).
        verbose : bool
            If True, print progress.

        Returns
        -------
        IsingResult
        """
        # Encode then decode to match HLS fixed-point rounding
        beta_raw  = _encode_beta(beta_final)
        beta_fp   = _decode_beta(beta_raw)

        sweeps_per_step = max(1, n_anneal_sweeps // n_anneal_steps)
        beta_step       = beta_fp / n_anneal_steps

        # Initial random spin state
        spins = self._rng.integers(0, 2, size=N_SPINS, dtype=np.uint8)

        # ── Phase 1: Annealing ──────────────────────────────────
        sample_buffer = np.empty(n_anneal_sweeps, dtype=np.uint8)
        beta_schedule = np.zeros(n_anneal_steps, dtype=float)
        sample_idx    = 0

        if verbose:
            print(f"[Annealing] beta 0 → {beta_fp:.4f}  "
                  f"steps={n_anneal_steps}  sweeps/step={sweeps_per_step}")

        for step in range(n_anneal_steps):
            beta_cur = (step + 1) * beta_step
            beta_schedule[step] = beta_cur

            for _ in range(sweeps_per_step):
                if sample_idx >= n_anneal_sweeps:
                    break
                spins = _metropolis_sweep(spins, beta_cur,
                                          self.J, self.h, self._rng)
                # Pack spin bits into one byte
                byte_val = 0
                for bit in range(N_SPINS):
                    byte_val |= (int(spins[bit]) << bit)
                sample_buffer[sample_idx] = byte_val
                sample_idx += 1

        # Trim in case sweeps_per_step * n_anneal_steps > n_anneal_sweeps
        sample_buffer = sample_buffer[:sample_idx]

        # ── Phase 2: Measurement ────────────────────────────────
        histogram = np.zeros(HIST_BINS, dtype=np.uint32)

        if verbose:
            print(f"[Measurement] beta={beta_fp:.4f}  sweeps={n_meas_sweeps}")

        for _ in range(n_meas_sweeps):
            spins = _metropolis_sweep(spins, beta_fp,
                                      self.J, self.h, self._rng)
            byte_val = 0
            for bit in range(N_SPINS):
                byte_val |= (int(spins[bit]) << bit)
            histogram[byte_val] += 1

        if verbose:
            total = histogram.sum()
            peak  = int(np.argmax(histogram))
            print(f"[Result] peak_state=0b{peak:08b}  "
                  f"peak_count={histogram[peak]}  "
                  f"gs_frac={float(histogram[0]+histogram[255])/total:.3f}")

        return IsingResult(
            sample_buffer=sample_buffer,
            histogram=histogram,
            beta_schedule=beta_schedule,
        )

    # ── Convenience factory methods ─────────────────────────────

    @classmethod
    def ferromagnet(cls, J_val: int = 1, seed: Optional[int] = None
                    ) -> "IsingEmulator":
        """All-to-all ferromagnet: J_{ij} = J_val for i≠j, h=0.
        Ground state: all spins aligned (0x00 or 0xFF).
        """
        J = np.ones((N_SPINS, N_SPINS), dtype=np.int32) * J_val
        np.fill_diagonal(J, 0)
        h = np.zeros(N_SPINS, dtype=np.int32)
        return cls(J=J, h=h, seed=seed)

    @classmethod
    def antiferromagnet(cls, J_val: int = 1, seed: Optional[int] = None
                        ) -> "IsingEmulator":
        """All-to-all antiferromagnet: J_{ij} = -J_val for i≠j, h=0.
        Ground state: alternating spins (frustrated for odd N).
        """
        J = -np.ones((N_SPINS, N_SPINS), dtype=np.int32) * J_val
        np.fill_diagonal(J, 0)
        h = np.zeros(N_SPINS, dtype=np.int32)
        return cls(J=J, h=h, seed=seed)

    @classmethod
    def random_sk(cls, J_std: float = 1.0, seed: Optional[int] = None
                  ) -> "IsingEmulator":
        """Sherrington-Kirkpatrick (SK) spin glass.
        J_{ij} ~ N(0, J_std/sqrt(N)) (integer-rounded).
        """
        rng = np.random.default_rng(seed)
        scale = J_std / math.sqrt(N_SPINS)
        J = rng.normal(0, scale, (N_SPINS, N_SPINS))
        J = np.round(J).astype(np.int32)
        J = (J + J.T) // 2          # symmetrise
        np.fill_diagonal(J, 0)
        h = np.zeros(N_SPINS, dtype=np.int32)
        return cls(J=J, h=h, seed=seed)
