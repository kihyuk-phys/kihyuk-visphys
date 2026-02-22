# Probabilistic Computing on PYNQ — Ising SA Core

8-spin Ising 모델을 Simulated Annealing(SA)으로 풀기 위한
Vivado HLS IP + PYNQ Python 드라이버 + SW 에뮬레이션 패키지.

---

## 두 단계 운용 흐름

```
[Annealing]                         [Measurement]
beta: 0 → beta_final                beta = beta_final (고정)
n_anneal_steps 단계                  n_meas_sweeps sweep
매 sweep → sample_buffer (시계열)   매 sweep → histogram (분포)
```

### 레지스터 맵

| 이름              | 역할                               | 기존 이름       |
|-------------------|------------------------------------|-----------------|
| `n_anneal_sweeps` | 어닐링 총 sweep 수                  | (N_SWEEPS 분리) |
| `n_meas_sweeps`   | 측정 총 sweep 수                    | (N_SWEEPS 분리) |
| `beta_final`      | 최종 역온도 (고정소수점 ap_ufixed<16,4>) | BETA_STEP 대체 |
| `n_anneal_steps`  | beta 증가 단계 수                   | (신규)          |
| `status`          | idle/annealing/measuring/done      | (4-상태)        |

---

## 파일 구조

```
pynq_prob_computing/
├── hls/
│   ├── src/
│   │   ├── ising_core.h       ← 타입 정의, 레지스터 맵
│   │   ├── ising_core.cpp     ← HLS 탑 함수 (합성 대상)
│   │   ├── lfsr.h             ← 32-bit Fibonacci LFSR
│   │   └── metropolis.h       ← Metropolis 판정 LUT
│   ├── tb/
│   │   └── ising_core_tb.cpp  ← C-simulation 테스트벤치
│   └── scripts/
│       ├── create_project.tcl ← Vivado HLS 프로젝트 생성 + 합성
│       ├── run_csim.tcl       ← C-sim 단독 실행
│       └── gen_lut.py         ← Metropolis LUT 재생성 도구
├── python/
│   ├── __init__.py
│   ├── emulation.py           ← NumPy SW 에뮬레이션 (FPGA 불필요)
│   └── pynq_driver.py         ← PYNQ 하드웨어 오버레이 드라이버
└── notebooks/
    └── demo.ipynb             ← 데모 노트북 (SW 에뮬 + HW 실행)
```

---

## 빠른 시작

### 1. SW 에뮬레이션 (PYNQ 불필요)

```python
from pynq_prob_computing.python.emulation import IsingEmulator

# 강자성체: 기저 상태 = 모두 +1 (0xFF) 또는 모두 -1 (0x00)
emu    = IsingEmulator.ferromagnet(J_val=1, seed=42)
result = emu.run(
    n_anneal_sweeps=2000,
    n_meas_sweeps=5000,
    beta_final=3.0,
    n_anneal_steps=20,
    verbose=True,
)

print(f"기저 상태 분율: {result.ground_state_fraction():.4f}")
print(f"최빈 상태:      0b{result.most_probable_state():08b}")
```

### 2. HLS 합성 (Vivado HLS / Vitis HLS 필요)

```bash
cd pynq_prob_computing
# C-simulation만 실행 (빠름)
vitis_hls -f hls/scripts/run_csim.tcl

# 전체 합성 + IP export
vitis_hls -f hls/scripts/create_project.tcl
```

합성 후 `ising_sa_proj/solution1/impl/ip/` 에 IP Catalog 파일이 생성됨.
Vivado Block Design 에서 불러와 Zynq PS 와 연결 → 비트스트림 생성.

### 3. PYNQ 보드에서 HW 실행

```python
from pynq_prob_computing.python.pynq_driver import IsingOverlay
import numpy as np

J = np.ones((8,8), dtype=np.int32) - np.eye(8, dtype=np.int32)
h = np.zeros(8, dtype=np.int32)

with IsingOverlay('/home/xilinx/ising_sa.bit') as hw:
    hw.configure(J=J, h=h, beta_final=3.0,
                 n_anneal_sweeps=10_000,
                 n_meas_sweeps=50_000,
                 n_anneal_steps=20)
    result = hw.run()

print(result.ground_state_fraction())
```

---

## 알고리즘 세부 사항

### Metropolis 판정 (LUT 방식)

- 32-bit Fibonacci LFSR 두 개 (독립 난수원)
- 수용 임계값 LUT: `threshold[i] = round(exp(−i/32) × 0xFFFFFFFF)`
- 커버 범위: beta×dE ∈ [0, 8.0), 해상도 1/32
- beta×dE ≥ 8.0 이면 거부 (exp(−8) ≈ 3.4×10⁻⁴, 무시 가능)

### 어닐링 스케줄

- `beta_step = beta_final / n_anneal_steps`
- 단계 k (1-indexed): `beta_k = k × beta_step`
- 각 단계마다 `n_anneal_sweeps / n_anneal_steps` sweep 수행

### HLS 인터페이스

| 포트           | 타입         | 설명                          |
|----------------|--------------|-------------------------------|
| 모든 스칼라    | `s_axilite`  | AXI-lite 슬레이브 (ctrl 번들) |
| `sample_buf`   | `m_axi`      | DDR 쓰기 (gmem0 번들)         |
| `hist_buf`     | `m_axi`      | DDR 쓰기 (gmem1 번들)         |

---

## 참고

- 대상 보드: PYNQ-Z2 (`xc7z020clg400-1`)
- 클럭: 100 MHz (`create_project.tcl` 에서 변경 가능)
- N_SPINS = 8 고정 (`ising_core.h` 에서 재정의 후 재합성 필요)
