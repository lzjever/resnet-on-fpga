# ResNet on FPGA (Zynq XC7Z020)

Minimal ResNet-style CNN accelerator for the MicroPhase Z7-Nano board.

## Architecture

```
Input (3×16×16) → Conv3×3 (3→8ch, pad=1) + ReLU
                → MaxPool 2×2 (→ 8×8×8)
                → Flatten (512)
                → FC (512→4 classes)
                → Output (4 values)
```

## Verified Operators

| Operator | Status | Resource |
|---|---|---|
| Conv3×3 + ReLU | ✅ Simulation PASS | Sequential MAC (1 DSP) |
| MaxPool 2×2 | ✅ Simulation PASS | Combinational max |
| Fully Connected | ✅ Simulation PASS | Sequential MAC |
| End-to-end | ✅ ALL PASS vs Python golden model | 57,858 cycles @ 50MHz ≈ 1.2ms |

## Repository Structure

```
rtl/resnet_top.v      — Complete CNN (AXI-Lite + compute FSM)
sim/gen_weights.py    — Weight generation + Python golden model
sim/tb_core.v         — Testbench (direct FSM control)
sim/tb_resnet.v       — Testbench (AXI interface, WIP)
build/build.tcl       — Vivado build script
```

## Quick Start (Simulation)

```bash
python3 sim/gen_weights.py     # Generate weights + golden output
iverilog -g2012 -o sim/tb.vvp rtl/resnet_top.v sim/tb_core.v
vvp sim/tb.vvp                 # Should print "ALL PASS"
```

## License

MIT
