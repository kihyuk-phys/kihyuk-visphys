"""pynq_driver.py – PYNQ hardware overlay driver for the P-bit Ising core.

이 드라이버는 Vivado RTL 합성한 비트스트림을 PYNQ 보드에 로드하고,
레지스터를 통해 P-bit 어닐링 SA 를 실행한다.

운용 흐름
─────────
1. overlay = IsingOverlay("ising_sa.bit")
2. overlay.configure(J, h, T_final, n_anneal_sweeps, ...)
3. result = overlay.run()          # blocks until done
4. result.histogram, result.sample_buffer

레지스터 맵 (AXI4-Lite ctrl, 4-byte 단위 – rtl/axi4l_slave.v 기준)
──────────────────────────────────────────────────────────────────
  0x000  ap_ctrl         bit0: start(W), bit1: done(R), bit2: idle(R)
  0x004  status          [1:0] RO  0=idle 1=anneal 2=meas 3=done
  0x008  n_anneal_sweeps uint32
  0x00C  n_meas_sweeps   uint32
  0x010  T_final_raw     [15:0]  T_gain × 2^12
  0x014  n_anneal_steps  uint32  (현재 미사용, 예약)
  0x018  lfsr_seed       uint32
  0x01C  T_step_raw      uint32  T_step × 2^32  (드라이버가 계산)
  0x020–0x11C  J_flat[64]  int32 × 64  (4바이트 간격)
  0x120–0x13C  h_field[8]  int32 × 8   (4바이트 간격)
  0x140  sample_buf_addr uint32  (물리 주소 하위 32-bit)
  0x144  hist_buf_addr   uint32  (물리 주소 하위 32-bit)
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


# ── Register offsets (AXI4-Lite, byte addresses) ───────────────
# rtl/axi4l_slave.v 와 동일한 레지스터 맵
class _Regs:
    AP_CTRL          = 0x000
    STATUS           = 0x004
    N_ANNEAL_SWEEPS  = 0x008
    N_MEAS_SWEEPS    = 0x00C
    T_FINAL_RAW      = 0x010   # T_gain × 2^12  (하위 16-bit)
    N_ANNEAL_STEPS   = 0x014   # 예약 (현재 RTL 미사용)
    LFSR_SEED        = 0x018
    T_STEP_RAW       = 0x01C   # T_step × 2^32  (드라이버 계산)
    J_FLAT_BASE      = 0x020   # J_flat[0..63] → 64 × 4 bytes
    H_FIELD_BASE     = 0x120   # h_field[0..7]  →  8 × 4 bytes
    SAMPLE_BUF_ADDR  = 0x140
    HIST_BUF_ADDR    = 0x144


# ── AP_CTRL 비트 ────────────────────────────────────────────────
_AP_START = 0x01   # W: 시작 펄스
_AP_DONE  = 0x02   # R: 완료 플래그
_AP_IDLE  = 0x04   # R: 유휴 상태


def _encode_T(T_gain: float) -> int:
    """T_final_raw = T_gain × 2^12 (16-bit unsigned)."""
    v = int(T_gain * (1 << 12)) & 0xFFFF
    return max(v, 0)


def _encode_T_step(T_final: float, n_anneal_sweeps: int) -> int:
    """T_step_raw = T_step × 2^32
    T_step = T_final / n_anneal_sweeps  (0 에서 T_final 까지 선형 증가)
    """
    if n_anneal_sweeps <= 0:
        return 0
    step = T_final / n_anneal_sweeps
    return int(step * (1 << 32)) & 0xFFFFFFFF


class IsingResult:
    """IsingOverlay.run() 이 반환하는 결과 객체."""

    def __init__(self, sample_buffer: np.ndarray, histogram: np.ndarray):
        self.sample_buffer = sample_buffer   # uint8 array – 각 sweep 의 스핀 상태
        self.histogram     = histogram       # uint32 array, 256 bin

    def most_probable_state(self) -> int:
        """히스토그램에서 가장 빈도가 높은 스핀 패턴 (0–255) 반환."""
        return int(np.argmax(self.histogram))

    def spins_from_byte(self, byte_val: int) -> np.ndarray:
        """스핀 바이트 → ±1 배열 (MSB = spin[7]).
        RTL 에서 spin[7:0] 이 wstrb=4'b0001 로 1 바이트 기록된다.
        """
        bits = np.array([(byte_val >> i) & 1 for i in range(8)], dtype=np.int8)
        return np.where(bits == 1, 1, -1)

    def tendency(self, unique_rand: np.ndarray) -> np.ndarray:
        """수 분할 문제(number partitioning)의 tendency 계산.

        tendency_k = Σ_j  m_j × unique_rand[j]

        각 sweep 의 스핀 바이트로부터 tendency 를 계산해 배열로 반환한다.
        tendency → 0 이 되면 수렴 (완벽한 분할).

        Parameters
        ----------
        unique_rand : (8,) array – 분할할 숫자 목록

        Returns
        -------
        (n_anneal_sweeps,) float array
        """
        u = np.asarray(unique_rand, dtype=float)
        results = []
        for byte_val in self.sample_buffer:
            spins = self.spins_from_byte(int(byte_val))
            results.append(float(np.dot(spins, u)))
        return np.array(results)


class IsingOverlay:
    """PYNQ driver for the P-bit Ising SA bitstream.

    Parameters
    ----------
    bitfile : str
        Path to the .bit file (.hwh 파일이 같은 디렉터리에 있어야 함).
    ip_name : str
        Block Design 내 ising_core 인스턴스 이름. Default: "ising_core_0"
    """

    def __init__(self, bitfile: str, ip_name: str = "ising_core_0"):
        if not _PYNQ_AVAILABLE:
            raise RuntimeError(
                "pynq package not found. "
                "Install it on a PYNQ board or use IsingEmulator for SW emulation."
            )
        self._ol   = Overlay(bitfile)
        self._ip   = getattr(self._ol, ip_name)
        self._mmio = self._ip.mmio
        self._sbuf : Optional[pynq.buffer.PynqBuffer] = None
        self._hbuf : Optional[pynq.buffer.PynqBuffer] = None

    # ── 저수준 레지스터 접근 ─────────────────────────────────────
    def _write(self, offset: int, value: int) -> None:
        self._mmio.write(offset, int(value) & 0xFFFFFFFF)

    def _read(self, offset: int) -> int:
        return self._mmio.read(offset)

    # ── 구성 ─────────────────────────────────────────────────────
    def configure(self,
                  J: np.ndarray,
                  h: np.ndarray,
                  T_final: float,
                  n_anneal_sweeps: int,
                  n_meas_sweeps: int,
                  lfsr_seed: int = 0x12345678) -> None:
        """파라미터를 AXI4-Lite 레지스터에 기록한다.

        Parameters
        ----------
        J : (8,8) int32 array – 커플링 행렬
            수 분할 문제: J[i][j] = -unique_rand[i] * unique_rand[j]
            (make_J_number_partition 클래스 메서드로 생성 가능)
        h : (8,)  int32 array – 외부 필드 (보통 0)
        T_final : float        – 어닐링 최종 게인 T
        n_anneal_sweeps : int  – 어닐링 단계 sweep 수
        n_meas_sweeps   : int  – 측정 단계 sweep 수
        lfsr_seed : int        – LFSR 초기값 (0 금지)
        """
        J = np.asarray(J, dtype=np.int32).reshape(8 * 8)
        h = np.asarray(h, dtype=np.int32).reshape(8)

        # DMA 버퍼 재할당
        if self._sbuf is not None:
            self._sbuf.freebuffer()
        if self._hbuf is not None:
            self._hbuf.freebuffer()

        self._sbuf = allocate(shape=(n_anneal_sweeps,), dtype=np.uint8)
        self._hbuf = allocate(shape=(256,),             dtype=np.uint32)
        self._hbuf[:] = 0

        # 스칼라 레지스터
        self._write(_Regs.N_ANNEAL_SWEEPS, n_anneal_sweeps)
        self._write(_Regs.N_MEAS_SWEEPS,   n_meas_sweeps)
        self._write(_Regs.T_FINAL_RAW,     _encode_T(T_final))
        self._write(_Regs.N_ANNEAL_STEPS,  0)   # 예약 (RTL 미사용)
        self._write(_Regs.LFSR_SEED,       lfsr_seed if lfsr_seed != 0 else 1)
        self._write(_Regs.T_STEP_RAW,      _encode_T_step(T_final, n_anneal_sweeps))

        # J 행렬 (64 word, 4-byte 간격)
        for i, val in enumerate(J):
            self._write(_Regs.J_FLAT_BASE + i * 4, int(val))

        # h 필드 (8 word, 4-byte 간격)
        for i, val in enumerate(h):
            self._write(_Regs.H_FIELD_BASE + i * 4, int(val))

        # DMA 버퍼 물리 주소
        self._write(_Regs.SAMPLE_BUF_ADDR, self._sbuf.physical_address & 0xFFFFFFFF)
        self._write(_Regs.HIST_BUF_ADDR,   self._hbuf.physical_address & 0xFFFFFFFF)

        self._n_anneal_sweeps = n_anneal_sweeps
        self._n_meas_sweeps   = n_meas_sweeps

    # ── 실행 ─────────────────────────────────────────────────────
    def run(self, timeout: float = 120.0) -> IsingResult:
        """코어를 시작하고 완료까지 블로킹.

        Returns
        -------
        IsingResult
        """
        if self._sbuf is None or self._hbuf is None:
            raise RuntimeError("configure() 를 먼저 호출하세요.")

        self._write(_Regs.AP_CTRL, _AP_START)

        t0 = time.time()
        while True:
            ctrl = self._read(_Regs.AP_CTRL)
            if ctrl & _AP_DONE:
                break
            if time.time() - t0 > timeout:
                raise RuntimeError(
                    f"IsingCore timeout ({timeout:.0f}s). "
                    f"AP_CTRL=0x{ctrl:08X}"
                )
            time.sleep(0.005)

        # 캐시 무효화 후 결과 복사
        self._sbuf.invalidate()
        self._hbuf.invalidate()

        sample_buf = np.array(self._sbuf[:self._n_anneal_sweeps], dtype=np.uint8)
        histogram  = np.array(self._hbuf[:256], dtype=np.uint32)

        return IsingResult(sample_buffer=sample_buf, histogram=histogram)

    def status(self) -> str:
        """현재 상태 문자열 반환."""
        s = self._read(_Regs.STATUS) & 0x3
        return ["idle", "anneal", "meas", "done"][s]

    # ── 자원 해제 ─────────────────────────────────────────────────
    def close(self) -> None:
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

    # ── 유틸리티 ─────────────────────────────────────────────────
    @staticmethod
    def make_J_number_partition(unique_rand: np.ndarray,
                                scale: int = 1) -> np.ndarray:
        """수 분할 문제용 커플링 행렬 생성.

        J[i][j] = -unique_rand[i] * unique_rand[j]   (i ≠ j)
        J[i][i] = 0

        Parameters
        ----------
        unique_rand : (8,) array  – 분할할 정수 목록
        scale : int               – 정수 표현 스케일 (기본값 1)

        Returns
        -------
        J : (8,8) int32 ndarray
        """
        u = np.asarray(unique_rand, dtype=np.int64) * scale
        J = -np.outer(u, u).astype(np.int32)
        np.fill_diagonal(J, 0)
        return J
