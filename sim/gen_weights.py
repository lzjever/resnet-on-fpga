#!/usr/bin/env python3
"""Generate random weights and input, save as .hex for Verilog $readmemh.
Also compute the expected output (golden model) for testbench verification.

Architecture (minimal ResNet-style CNN):
  Input:  3 × 16 × 16
  Conv:   3→8 channels, 3×3 kernel, pad=1, stride=1 → 8 × 16 × 16
  ReLU:   inline
  Pool:   2×2 max, stride 2 → 8 × 8 × 8
  FC:     512 → 4 classes

All arithmetic is 16-bit signed integer (Q0 format).
"""
import numpy as np
import os

np.random.seed(42)  # reproducible

# --- Dimensions ---
IN_CH, IN_H, IN_W = 3, 16, 16
CONV_OUT_CH, K_H, K_W = 8, 3, 3
POOL_OUT_H, POOL_OUT_W = IN_H // 2, IN_W // 2
FC_IN = CONV_OUT_CH * POOL_OUT_H * POOL_OUT_W  # 8*8*8 = 512
FC_OUT = 4

# --- Generate data ---
input_data = np.random.randint(-1, 2, size=(IN_CH, IN_H, IN_W), dtype=np.int16)
conv_weight = np.random.randint(-1, 2, size=(CONV_OUT_CH, IN_CH, K_H, K_W), dtype=np.int16)
conv_bias = np.random.randint(-2, 3, size=(CONV_OUT_CH,), dtype=np.int16)
fc_weight = np.random.randint(-1, 2, size=(FC_OUT, FC_IN), dtype=np.int16)
fc_bias = np.random.randint(-4, 5, size=(FC_OUT,), dtype=np.int16)

# --- Golden model ---
def conv3x3_relu(inp, w, b):
    """Conv 3×3 pad=1 + ReLU. inp[C_in][H][W], w[C_out][C_in][3][3], b[C_out]"""
    c_in, h, wd = inp.shape
    c_out = w.shape[0]
    padded = np.pad(inp, ((0,0),(1,1),(1,1)), mode='constant')
    out = np.zeros((c_out, h, wd), dtype=np.int32)
    for co in range(c_out):
        for y in range(h):
            for x in range(wd):
                acc = int(b[co])
                for ci in range(c_in):
                    for ky in range(3):
                        for kx in range(3):
                            acc += int(padded[ci][y+ky][x+kx]) * int(w[co][ci][ky][kx])
                out[co][y][x] = max(0, acc)  # ReLU
    return out

def maxpool2(inp):
    """Proper 2×2 max pooling with stride 2."""
    c, h, w = inp.shape
    out = np.zeros((c, h//2, w//2), dtype=np.int32)
    for ci in range(c):
        for y in range(h//2):
            for x in range(w//2):
                out[ci][y][x] = max(int(inp[ci][2*y][2*x]),
                                     int(inp[ci][2*y][2*x+1]),
                                     int(inp[ci][2*y+1][2*x]),
                                     int(inp[ci][2*y+1][2*x+1]))
    return out

def fc(inp_flat, w, b):
    out_dim = w.shape[0]
    out = np.zeros(out_dim, dtype=np.int32)
    for i in range(out_dim):
        acc = int(b[i])
        for j in range(len(inp_flat)):
            acc += int(inp_flat[j]) * int(w[i][j])
        out[i] = acc
    return out

conv_out = conv3x3_relu(input_data, conv_weight, conv_bias)
pool_out = maxpool2(conv_out)
flat = pool_out.flatten()
final_out = fc(flat, fc_weight, fc_bias)

# --- Save as .hex (16-bit words, 2's complement) ---
def to_hex_line(value):
    return f"{value & 0xFFFF:04x}"

def save_hex(filename, arr):
    flat = arr.flatten()
    with open(filename, 'w') as f:
        for v in flat:
            f.write(to_hex_line(int(v)) + '\n')
    print(f"  {filename}: {len(flat)} words")

outdir = os.path.dirname(__file__) + '/hex'
os.makedirs(outdir, exist_ok=True)

save_hex(f'{outdir}/input.hex', input_data)
save_hex(f'{outdir}/conv_weight.hex', conv_weight)
save_hex(f'{outdir}/conv_bias.hex', conv_bias)
save_hex(f'{outdir}/fc_weight.hex', fc_weight)
save_hex(f'{outdir}/fc_bias.hex', fc_bias)
save_hex(f'{outdir}/golden_output.hex', final_out)

print(f"\nGolden output: {final_out}")
print(f"Files in {outdir}/")
