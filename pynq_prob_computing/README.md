# Probabilistic Computing on PYNQ — Ising SA Core

8-spin Ising 모델을 Simulated Annealing(SA)으로 풀기 위한
Vivado HLS IP + Vivado Block Design + PYNQ Python 드라이버 패키지.

---

## 두 단계 운용 흐름

```
[Annealing]                             [Measurement]
beta: 0 → beta_final                    beta = beta_final (고정)
n_anneal_steps 단계로 선형 증가          n_meas_sweeps 회 반복
매 sweep → sample_buffer (시계열)       매 sweep → histogram (분포)
```

---

## 파일 구조

```
pynq_prob_computing/
├── hls/
│   ├── src/
│   │   ├── ising_core.h       ← 타입 정의, 레지스터 맵
│   │   ├── ising_core.cpp     ← HLS 탑 함수 (합성 대상)
│   │   ├── lfsr.h             ← 32-bit Fibonacci LFSR
│   │   └── metropolis.h       ← Metropolis 수용 판정 LUT
│   ├── tb/
│   │   └── ising_core_tb.cpp  ← C-simulation 테스트벤치
│   └── scripts/
│       ├── create_project.tcl ← HLS 합성 + IP export
│       ├── run_csim.tcl       ← C-sim 단독 실행
│       └── gen_lut.py         ← Metropolis LUT 재생성
├── vivado/
│   └── create_bd.tcl          ← Vivado Block Design + 비트스트림
├── python/
│   ├── emulation.py           ← NumPy SW 에뮬레이션 (FPGA 없이 검증)
│   └── pynq_driver.py         ← PYNQ 하드웨어 드라이버
├── notebooks/
│   └── demo.ipynb             ← 데모 노트북
└── pynq_output/               ← 생성됨: ising_sa.bit / ising_sa.hwh
```

---

## 전체 워크플로 (Vivado)

### Step 1 — SW 에뮬레이션으로 알고리즘 검증

FPGA 없이 알고리즘이 맞는지 먼저 확인한다.

```bash
cd kihyuk-visphys
python3 -c "
from pynq_prob_computing.python.emulation import IsingEmulator
emu = IsingEmulator.ferromagnet(J_val=1, seed=42)
r = emu.run(n_anneal_sweeps=2000, n_meas_sweeps=5000,
            beta_final=3.0, n_anneal_steps=20, verbose=True)
print('gs_fraction:', r.ground_state_fraction())
"
```

예상 출력: `gs_fraction: 1.0` (강자성체 beta=3에서 기저 상태 100%)

---

### Step 2 — HLS 합성 (Vivado HLS / Vitis HLS)

```bash
# Vivado HLS (2018.x – 2019.x)
vivado_hls -f pynq_prob_computing/hls/scripts/create_project.tcl

# Vitis HLS (2020.x+, Vivado 설치 시 함께 제공)
vitis_hls  -f pynq_prob_computing/hls/scripts/create_project.tcl
```

완료 후 생성 경로:
```
pynq_prob_computing/hls/ising_sa_proj/solution1/impl/ip/
```

C-simulation만 빠르게 확인하려면:
```bash
vivado_hls -f pynq_prob_computing/hls/scripts/run_csim.tcl
```

---

### Step 3 — Vivado Block Design + 비트스트림

```bash
# 프로젝트 루트에서 실행
vivado -mode batch -source pynq_prob_computing/vivado/create_bd.tcl
```

또는 Vivado Tcl Console에서:
```tcl
source {C:/path/to/pynq_prob_computing/vivado/create_bd.tcl}
```

스크립트가 자동으로 수행하는 작업:

| 순서 | 작업 |
|------|------|
| ① | Vivado 프로젝트 생성 (`vivado/ising_sa_vivado/`) |
| ② | HLS IP를 IP Catalog에 등록 |
| ③ | Block Design 생성 |
| ④ | Zynq PS7 인스턴스 + 보드 프리셋 |
| ⑤ | HP0 / HP1 활성화 |
| ⑥ | ising_core_0, AXI Interconnect, SmartConnect 인스턴스 |
| ⑦ | 클럭 / 리셋 / AXI 연결 |
| ⑧ | 주소 할당 (ctrl → 0x43C00000) |
| ⑨ | 합성 → P&R → 비트스트림 |
| ⑩ | `pynq_output/` 에 `.bit`, `.hwh` 복사 |

완료 후:
```
pynq_prob_computing/pynq_output/
├── ising_sa.bit
└── ising_sa.hwh
```

---

### Step 4 — PYNQ 보드 배포

```bash
# 보드 IP 예: 192.168.2.99
scp pynq_prob_computing/pynq_output/ising_sa.bit xilinx@192.168.2.99:/home/xilinx/
scp pynq_prob_computing/pynq_output/ising_sa.hwh xilinx@192.168.2.99:/home/xilinx/
scp pynq_prob_computing/notebooks/demo.ipynb     xilinx@192.168.2.99:/home/xilinx/jupyter_notebooks/
```

---

### Step 5 — PYNQ 보드에서 실행

보드의 Jupyter Lab에서 `demo.ipynb` 실행.
또는 Python 직접 실행:

```python
from pynq_prob_computing.python.pynq_driver import IsingOverlay
import numpy as np

J = np.ones((8,8), dtype=np.int32) - np.eye(8, dtype=np.int32)
h = np.zeros(8, dtype=np.int32)

with IsingOverlay('/home/xilinx/ising_sa.bit') as hw:
    hw.configure(
        J=J, h=h,
        beta_final=3.0,
        n_anneal_sweeps=10_000,
        n_meas_sweeps=50_000,
        n_anneal_steps=20,
    )
    result = hw.run()

print(f"gs_fraction : {result.ground_state_fraction():.4f}")
print(f"peak_state  : 0b{result.most_probable_state():08b}")
```

---

## 블록 다이어그램 요약

```
Zynq PS7
┌───────────────────────────────────────────────────────────────┐
│  M_AXI_GP0 ──→ [AXI Interconnect] ──→ ising_core_0 s_axi_ctrl│  ← 레지스터 설정
│                                                               │
│  S_AXI_HP0 ←── [AXI SmartConnect] ←── ising_core_0 m_axi_gmem0 │  ← sample_buf
│  S_AXI_HP1 ←── [AXI SmartConnect] ←── ising_core_0 m_axi_gmem1 │  ← hist_buf
└───────────────────────────────────────────────────────────────┘
                    FCLK_CLK0 = 100 MHz (단일 클럭 도메인)
```

---

## 레지스터 맵 (s_axi_ctrl, 베이스: 0x43C00000)

| 이름              | 오프셋 | 역할                                      |
|-------------------|--------|-------------------------------------------|
| `ap_ctrl`         | 0x00   | bit0=start, bit1=done, bit2=idle          |
| `n_anneal_sweeps` | 0x10   | 어닐링 총 sweep 수 → sample_buffer 크기   |
| `n_meas_sweeps`   | 0x18   | 측정 총 sweep 수 → histogram 누적 수      |
| `beta_final_raw`  | 0x20   | beta (ap_ufixed<16,4>, 12비트 소수부)     |
| `n_anneal_steps`  | 0x28   | beta 증가 단계 수                         |
| `lfsr_seed`       | 0x30   | LFSR 시드 (0 금지)                        |
| `J_flat[0..63]`   | 0x38 ~ | 커플링 행렬 (int32, i×8+j)               |
| `h_field[0..7]`   | ~      | 외부 자기장 (int32)                       |
| `sample_buf_addr` | ~      | pynq.allocate() 물리 주소                 |
| `hist_buf_addr`   | ~      | pynq.allocate() 물리 주소                 |

> 정확한 오프셋은 HLS 합성 후 `solution1/impl/ip/` 의
> `component.xml` → SW I/O Information 에서 확인.

---

## 알고리즘 세부

| 항목 | 내용 |
|------|------|
| 스핀 수 | N=8 (ising_core.h 에서 변경 후 재합성) |
| 난수 | 32-bit Fibonacci LFSR 2개 (독립) |
| Metropolis LUT | 256 엔트리, exp(−i/32)×2³², beta×dE ∈ [0, 8) |
| 어닐링 스케줄 | beta_k = k × (beta_final / n_anneal_steps) |
| 클럭 | 100 MHz (create_project.tcl CLK_PERIOD=10 으로 변경 가능) |
| 대상 보드 | PYNQ-Z2 (xc7z020clg400-1) |
