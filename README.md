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
iverilog -g2012 -o sim/tb.vvp rtl/resnet_top_int4.v sim/tb_core_int4.v
vvp sim/tb.vvp        # PASS: outputs match golden after 21762 cycles
```

### Building a bitstream

Hex data files are **generated artifacts** (not committed) — always run the
generator first, from the repo root:

```bash
python3 sim/gen_weights_int4.py            # or gen_weights.py for INT16
vivado -mode batch -source build/build_int4.tcl   # → build_fpga_int4/*.bit
```

The build scripts inject absolute hex paths via `verilog_define` (project-mode
synth runs in its own CWD; relative paths silently zero-fill — Synth 8-4445).

### Board Verification (real XC7Z020, 2026-11-21)

Register map @ 0x40000000 (GP0):

| Offset | Read | Write |
|---|---|---|
| 0x00 | `{30'0, done, busy}` (sticky done, cleared by next start) | `bit0=1` start (needs 0→1 edge for each run) |
| 0x04 | SPEED echo | SPEED (unused) |
| 0x08 | `{out1, out0}` | ignored (full decode, read-only) |
| 0x0C | `{out3, out2}` | ignored (full decode, read-only) |

Writes to 0x08/0x0C are safely ignored (verified on hardware: writing 0x08
does not trigger a run). An earlier revision decoded only `awaddr[2]` and
would alias such writes into CTRL — fixed with full `awaddr[3:2]` decode.

### Known limitations (deliberate, unreachable from the Linux /dev/mem flow)

- **AXI bursts unsupported** (single-beat only): a multi-beat GP0 write
  would wedge the slave (WLAST=0 first beat never completes), and a
  multi-beat read returns one beat only. CPU accesses to Device memory are
  architecturally single-beat, so devmem//dev/mem can never trigger this.
  A DMA master would need an AXI3-to-Lite bridge.
- **WSTRB ignored**: byte-lane strobes are not wired (writes are 4-byte).
  Linux 32-bit device writes always assert WSTRB=1111.
- **Start while busy is silently ignored** (returns OKAY). Drivers must
  wait for done, then write 0 followed by 1.
- **Status is captured at AR handshake** (standard AXI-Lite): a read
  queued on the exact edge of a new start can deliver the pre-start
  value. Polling twice resolves any ambiguity.
- **FCLK0 setting assumes IO PLL = 1000 MHz** (our boot config); a
  different PLL rate changes the actual FCLK0 and timing margin.
- **One weight generator at a time**: gen_weights_int4.py writes a shared
  hex dir; concurrent runs can interleave files.

```
JTAG program → FCLK0 50MHz → LVL_SHFTR_EN → write 0x40000000=1
poll status: done seen on FIRST read (sticky flag) 
0x08 = 191af6b5  MATCH  (out0=-2379, out1=6426)
0x0C = 0d692063  MATCH  (out2=8291,  out3=3433)
```

Resource comparison (post-route):

| | INT16 (main) | INT4 (this) |
|---|---|---|
| Slice LUTs | 4893 (9.2%) | **2085 (3.9%)** |
| DSPs | 3 | 7 (narrower mults → more parallel) |
| WNS @50MHz | — | +3.79ns (≈62MHz capable) |

### Debug war stories (bugs found & fixed in this branch)

1. **`{co,ci,ky}` concat ≠ `co*9+ci*3+ky`** — non-power-of-2 strides must use arithmetic; concat silently reads out-of-range → X everywhere.
2. **`wire cv_bank = {oy[0],ox[0]}`** — implicit 1-bit wire truncates the concat's MSB; two memory banks never written. Always declare widths.
3. **numpy `int8` shift overflow** — `12 << 8` wraps to 0 in fixed-width numpy ints; cast to Python `int()` before packing shifts.
4. **1-cycle done pulse** — a 20ns status pulse can never be caught by PS polling (~8ms/read). Status flags crossing speed domains must be sticky (set on completion, clear only on next start).
5. **`$readmemh` relative path + Vivado project mode** — synth runs in its own CWD, so repo-relative hex paths fail with only a CRITICAL WARNING (Synth 8-4445) and memories are **silently zero-filled**: simulation passes, hardware outputs all-zero with done still firing. Fix: `verilog_define` injects absolute paths at build time (RTL defaults stay relative for iverilog). Always grep the synth log for 8-4445 after touching init paths.


## License

MIT
