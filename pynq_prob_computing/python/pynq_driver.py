"""pynq_driver.py – PYNQ hardware overlay driver for the Ising SA core.

이 드라이버는 Vivado HLS 로 합성한 비트스트림을 PYNQ 보드에 로드하고,
레지스터를 통해 두 단계 SA 를 실행한다.

운용 흐름
─────────
1. overlay = IsingOverlay("ising_sa.bit")
2. overlay.configure(J, h, beta_final, n_anneal_sweeps, ...)
3. result = overlay.run()          # blocks until done
4. result.histogram, result.sample_buffer

레지스터 맵 (AXI-lite ctrl bundle, 4-byte 단위)
─────────────────────────────────────────────────
  0x00  ap_ctrl      – bit0: start, bit1: done, bit2: idle, bit3: ready
  0x04  (reserved)
  0x10  n_anneal_sweeps
  0x18  n_meas_sweeps
  0x20  beta_final_raw  (ap_ufixed<16,4> bit pattern)
  0x28  n_anneal_steps
  0x30  lfsr_seed
  0x38  J_flat[0]   …
  0xD8  J_flat[63]
  0xDC  h_field[0]  …
  0xFC  h_field[7]
  0x100 sample_buf_addr   (물리 주소 하위 32-bit)
  0x108 hist_buf_addr     (물리 주소 하위 32-bit)

Note: 정확한 오프셋은 Vivado HLS synthesis report 의 AXI-lite 주소 맵을
      확인하고 맞춰야 한다. 아래 오프셋은 대부분의 경우에 맞지만
      HLS 버전이나 최적화 수준에 따라 달라질 수 있다.
"""

from __future__ import annotations

import time
from typing import Optional

import numpy as np

try:
    import pynq
    from pynq import Overlay, allocate
    _PYNQ_AVAILABLE = True
except ImportError:
    _PYNQ_AVAILABLE = False


# ── Register offsets (AXI-lite, byte addresses) ────────────────
# These match the default Vivado HLS s_axilite bundle layout.
# Verify against your synthesis report's "SW I/O Information" table.
class _Regs:
    AP_CTRL           = 0x00
    AP_GIE            = 0x04
    AP_IER            = 0x08
    AP_ISR            = 0x0C
    N_ANNEAL_SWEEPS   = 0x10
    N_MEAS_SWEEPS     = 0x18
    BETA_FINAL_RAW    = 0x20
    N_ANNEAL_STEPS    = 0x28
    LFSR_SEED         = 0x30
    J_FLAT_BASE       = 0x38   # J_flat[0..63] → 64 * 8 bytes = 0x200
    H_FIELD_BASE      = 0xD8 + 0x100  # after J_flat (adjust per report)
    SAMPLE_BUF_ADDR   = 0x200
    HIST_BUF_ADDR     = 0x208


# ── AP_CTRL bits ───────────────────────────────────────────────
_AP_START  = 0x01
_AP_DONE   = 0x02
_AP_IDLE   = 0x04
_AP_READY  = 0x08


def _encode_beta(beta: float) -> int:
    """ap_ufixed<16,4>: 12 fractional bits."""
    return int(beta * (1 << 12)) & 0xFFFF


class IsingResult:
    """Returned by IsingOverlay.run()."""
    def __init__(self, sample_buffer: np.ndarray, histogram: np.ndarray):
        self.sample_buffer = sample_buffer   # uint8 array
        self.histogram     = histogram       # uint32 array, size 256

    def ground_state_fraction(self) -> float:
        total = self.histogram.sum()
        return float(self.histogram[0] + self.histogram[255]) / max(total, 1)

    def most_probable_state(self) -> int:
        return int(np.argmax(self.histogram))


class IsingOverlay:
    """PYNQ driver for the Ising SA bitstream.

    Parameters
    ----------
    bitfile : str
        Path to the .bit file (must be accompanied by a .hwh file).
    ip_name : str
        Name of the HLS IP block in the block design.
        Default: "ising_core_0"
    """

    def __init__(self, bitfile: str, ip_name: str = "ising_core_0"):
        if not _PYNQ_AVAILABLE:
            raise RuntimeError(
                "pynq package not found. "
                "Install it on a PYNQ board or use IsingEmulator for SW emulation."
            )
        self._ol     = Overlay(bitfile)
        self._ip     = getattr(self._ol, ip_name)
        self._mmio   = self._ip.mmio
        self._sbuf   : Optional[pynq.buffer.PynqBuffer] = None
        self._hbuf   : Optional[pynq.buffer.PynqBuffer] = None

    def _write(self, offset: int, value: int) -> None:
        self._mmio.write(offset, value)

    def _read(self, offset: int) -> int:
        return self._mmio.read(offset)

    def configure(self,
                  J: np.ndarray,
                  h: np.ndarray,
                  beta_final: float,
                  n_anneal_sweeps: int,
                  n_meas_sweeps: int,
                  n_anneal_steps: int,
                  lfsr_seed: int = 0x12345678) -> None:
        """Write all parameters to AXI-lite registers.

        Parameters
        ----------
        J : (8,8) int32 array – coupling matrix
        h : (8,)  int32 array – external field
        beta_final : float    – final inverse temperature
        n_anneal_sweeps : int – sweeps in annealing phase
        n_meas_sweeps   : int – sweeps in measurement phase
        n_anneal_steps  : int – number of annealing sub-steps (>= 1)
        lfsr_seed : int       – LFSR seed (must be != 0)
        """
        J  = np.asarray(J, dtype=np.int32).reshape(8 * 8)
        h  = np.asarray(h, dtype=np.int32).reshape(8)

        # Allocate DMA-capable buffers
        if self._sbuf is not None:
            self._sbuf.freebuffer()
        if self._hbuf is not None:
            self._hbuf.freebuffer()

        self._sbuf = allocate(shape=(n_anneal_sweeps,), dtype=np.uint8)
        self._hbuf = allocate(shape=(256,),             dtype=np.uint32)
        self._hbuf[:] = 0

        # Scalar registers
        self._write(_Regs.N_ANNEAL_SWEEPS, n_anneal_sweeps)
        self._write(_Regs.N_MEAS_SWEEPS,   n_meas_sweeps)
        self._write(_Regs.BETA_FINAL_RAW,  _encode_beta(beta_final))
        self._write(_Regs.N_ANNEAL_STEPS,  n_anneal_steps)
        self._write(_Regs.LFSR_SEED,       lfsr_seed if lfsr_seed != 0 else 1)

        # J matrix (64 words)
        for i, val in enumerate(J):
            self._write(_Regs.J_FLAT_BASE + i * 8, int(val))

        # h field (8 words)
        for i, val in enumerate(h):
            self._write(_Regs.H_FIELD_BASE + i * 8, int(val))

        # Physical buffer addresses
        self._write(_Regs.SAMPLE_BUF_ADDR, self._sbuf.physical_address & 0xFFFFFFFF)
        self._write(_Regs.HIST_BUF_ADDR,   self._hbuf.physical_address & 0xFFFFFFFF)

        self._n_anneal_sweeps = n_anneal_sweeps
        self._n_meas_sweeps   = n_meas_sweeps

    def run(self, timeout: float = 60.0) -> IsingResult:
        """Start the core and block until done.

        Parameters
        ----------
        timeout : float
            Maximum wait time in seconds before raising RuntimeError.

        Returns
        -------
        IsingResult
        """
        if self._sbuf is None or self._hbuf is None:
            raise RuntimeError("Call configure() before run().")

        # Start the IP
        self._write(_Regs.AP_CTRL, _AP_START)

        # Poll AP_CTRL for done bit
        t0 = time.time()
        while True:
            ctrl = self._read(_Regs.AP_CTRL)
            if ctrl & _AP_DONE:
                break
            if time.time() - t0 > timeout:
                raise RuntimeError(
                    f"IsingCore timed out after {timeout:.0f}s. "
                    f"AP_CTRL=0x{ctrl:08X}"
                )
            time.sleep(0.01)

        # Flush cache and copy results
        self._sbuf.invalidate()
        self._hbuf.invalidate()

        sample_buf = np.array(self._sbuf[:self._n_anneal_sweeps], dtype=np.uint8)
        histogram  = np.array(self._hbuf[:256], dtype=np.uint32)

        return IsingResult(sample_buffer=sample_buf, histogram=histogram)

    def close(self) -> None:
        """Free allocated DMA buffers."""
        if self._sbuf is not None:
            self._sbuf.freebuffer()
            self._sbuf = None
        if self._hbuf is not None:
            self._hbuf.freebuffer()
            self._hbuf = None

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()
