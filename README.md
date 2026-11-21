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

---

## INT4 Branch (`int4`)

Quantized variant: weights INT4 (`-8..7`), activations INT16, INT32 accumulator.
Golden output `[-2379, 6426, 8291, 3433]` — identical Python model, quantized weights.

### Where the speedup actually comes from (not "shorter weights")

| Technique | Idea | Effect |
|---|---|---|
| Packed weights | 1 BRAM word = 1 conv kernel row `[kx0,kx1,kx2,pad]`; FC: 4 consecutive inputs | 3 (conv) / 4 (FC) MACs per cycle |
| Line buffer | 3×3×16 input window in registers (144×16b), sliding-window taps never touch BRAM | conv inner loop = pure register reads |
| Banked memories | conv_out split 4-way by (y,x) parity → pool reads a 2×2 window in 1 cycle; pool_out split by index mod 4 → FC reads 4 activations/cycle | no single-port BRAM bottleneck |

### Cycle count (measured in simulation)

| Stage | INT16 (main) | INT4 (this branch) |
|---|---|---|
| Conv | 55,296 (1 MAC/cyc) | 18,432 (3 MACs/cyc) + 2,304 line-buffer loads |
| Pool | 2,048 | 512 (banked 4-tap read) |
| FC | 2,048 (1 MAC/cyc) | 512 (4 MACs/cyc) |
| **Total** | **≈59,400 ≈ 1.2ms @ 50MHz** | **21,762 ≈ 0.44ms @ 50MHz (2.7×)** |

### INT4 files

```
rtl/resnet_top_int4.v      — INT4 core (line buffer + banking, 3~4 MACs/cycle)
rtl/resnet_board_int4.v    — PS7 + AXI3-adapted Lite slave wrapper
sim/gen_weights_int4.py    — INT4 quantization + packing + golden model
sim/tb_core_int4.v         — Testbench (PASS after 21,762 cycles)
sim/hex_int4/              — Packed weight / input / golden hex files
build/build_int4.tcl       — Vivado build (bitstream: build_fpga_int4/)
bench/board_test_int4.sh   — On-board end-to-end test (FCLK0 + devmem)
```

### Quick Start (INT4 simulation)

```bash
python3 sim/gen_weights_int4.py
iverilog -g2005 -o sim/tb.vvp rtl/resnet_top_int4.v sim/tb_core_int4.v
vvp sim/tb.vvp        # PASS: outputs match golden after 21762 cycles
```

### Debug war stories (bugs found & fixed in this branch)

1. **`{co,ci,ky}` concat ≠ `co*9+ci*3+ky`** — non-power-of-2 strides must use arithmetic; concat silently reads out-of-range → X everywhere.
2. **`wire cv_bank = {oy[0],ox[0]}`** — implicit 1-bit wire truncates the concat's MSB; two memory banks never written. Always declare widths.
3. **numpy `int8` shift overflow** — `12 << 8` wraps to 0 in fixed-width numpy ints; cast to Python `int()` before packing shifts.


## License

MIT
