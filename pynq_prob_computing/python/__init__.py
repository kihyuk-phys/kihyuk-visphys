"""pynq_prob_computing – Ising SA core for PYNQ

Submodules
----------
emulation   : NumPy-based SW emulation (no FPGA needed)
pynq_driver : PYNQ hardware overlay driver (requires bitstream)
"""

from .emulation import IsingEmulator

__all__ = ["IsingEmulator"]
