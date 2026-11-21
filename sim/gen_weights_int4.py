#!/usr/bin/env python3
"""Generate INT4-quantized weights for the ResNet CNN.

Quantization scheme:
  - Conv weights: INT4 (-8 to +7) — packed 4 per 16-bit word
  - Conv bias:   INT4 (-8 to +7) — packed 4 per 16-bit word
  - FC weights:  INT4 (-8 to +7) — packed 4 per 16-bit word
  - FC bias:     INT8 (for wider dynamic range)
  - Activations: INT8 (input stays INT8 for image-like data)
  - Accumulator: INT32 (plenty of headroom)

INT4 packing (4 values per 16-bit word):
  bits [3:0]   = w0 (lowest)
  bits [7:4]   = w1
  bits [11:8]  = w2
  bits [15:12] = w3 (highest)

Packing orders (chosen for RTL parallelism):
  Conv: one word per KERNEL ROW → [kx0, kx1, kx2, pad0]
        word index = co*9 + ci*3 + ky   (72 words, 3 real MACs/cycle)
  FC:   4 consecutive fi inputs per word → word index = fo*128 + fi/4
        (512 words, 4 real MACs/cycle)

Speed advantage: 4 MACs per cycle (one packed weight word × one activation)
BRAM advantage: 4x fewer weight BRAM reads.
"""
import numpy as np
import os

np.random.seed(42)

# Dimensions (same as INT16 version)
IN_CH, IN_H, IN_W = 3, 16, 16
CONV_OUT_CH = 8
FC_IN = 8 * 8 * 8  # 512
FC_OUT = 4

# Quantization parameters
W_BITS = 4   # weight precision
W_MIN = -(2**(W_BITS-1))     # -8
W_MAX = 2**(W_BITS-1) - 1    # 7

def quantize_int4(arr, scale=1.0):
    """Quantize to INT4 range [-8, 7]."""
    q = np.clip(np.round(arr * scale), W_MIN, W_MAX).astype(np.int8)
    return q

def pack_int4(arr_flat):
    """Pack 4 INT4 values into one 16-bit word."""
    # Pad to multiple of 4
    n = len(arr_flat)
    pad = (4 - n % 4) % 4
    if pad:
        arr_flat = np.append(arr_flat, [0] * pad)
    words = []
    for i in range(0, len(arr_flat), 4):
        w0 = int(arr_flat[i])   & 0xF
        w1 = int(arr_flat[i+1]) & 0xF
        w2 = int(arr_flat[i+2]) & 0xF
        w3 = int(arr_flat[i+3]) & 0xF
        word = w0 | (w1 << 4) | (w2 << 8) | (w3 << 12)
        words.append(word)
    return words, n  # n = actual count (without padding)

def to_hex16(v):
    return f"{v & 0xFFFF:04x}"

def save_packed(filename, words, count):
    with open(filename, 'w') as f:
        for w in words:
            f.write(to_hex16(w) + '\n')
    print(f"  {filename}: {len(words)} words (packed from {count} values)")

# --- Generate data ---
input_data = np.random.randint(-16, 16, size=(IN_CH, IN_H, IN_W), dtype=np.int16)

conv_weight_raw = np.random.randn(CONV_OUT_CH, IN_CH, 3, 3) * 2
conv_weight = quantize_int4(conv_weight_raw, scale=1.5)
conv_bias = quantize_int4(np.random.randn(CONV_OUT_CH) * 1.5, scale=1.0)

fc_weight_raw = np.random.randn(FC_OUT, FC_IN) * 0.5
fc_weight = quantize_int4(fc_weight_raw, scale=2.0)
fc_bias = np.clip(np.random.randn(FC_OUT) * 2, -128, 127).astype(np.int16)

# --- Golden model (matching INT4 Verilog) ---
def conv3x3_relu(inp, w, b):
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
                out[co][y][x] = max(0, acc)
    return out

def maxpool2(inp):
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

# --- Save files ---
outdir = os.path.dirname(__file__) + '/hex_int4'
os.makedirs(outdir, exist_ok=True)

# Input: plain INT16 (activations stay wider for accuracy)
with open(f'{outdir}/input.hex', 'w') as f:
    for v in input_data.flatten():
        f.write(to_hex16(int(v)) + '\n')
print(f"  input.hex: {len(input_data.flatten())} words (INT16 activations)")

# Conv weights: packed INT4 — one 16-bit word per kernel row (ky):
#   [kx0, kx1, kx2, pad0] → word index = co*9 + ci*3 + ky
conv_words = []
for co in range(CONV_OUT_CH):
    for ci in range(IN_CH):
        for ky in range(3):
            vals = [int(conv_weight[co][ci][ky][kx]) & 0xF for kx in range(3)]
            conv_words.append(vals[0] | (vals[1] << 4) | (vals[2] << 8))
save_packed(f'{outdir}/conv_weight_packed.hex', conv_words, 216)

# Conv bias: plain INT4 (stored as INT16 for simplicity in BRAM)
with open(f'{outdir}/conv_bias.hex', 'w') as f:
    for v in conv_bias:
        f.write(to_hex16(int(v)) + '\n')
print(f"  conv_bias.hex: {len(conv_bias)} words (INT4 value in INT16)")

# FC weights: packed INT4
fc_w_flat = fc_weight.flatten()
words, n = pack_int4(fc_w_flat)
save_packed(f'{outdir}/fc_weight_packed.hex', words, n)

# FC bias: INT16
with open(f'{outdir}/fc_bias.hex', 'w') as f:
    for v in fc_bias:
        f.write(to_hex16(int(v)) + '\n')
print(f"  fc_bias.hex: {len(fc_bias)} words (INT8 value in INT16)")

# Golden output
with open(f'{outdir}/golden_output.hex', 'w') as f:
    for v in final_out:
        f.write(to_hex16(int(v)) + '\n')
print(f"  golden_output.hex: {len(final_out)} words")

print(f"\nGolden output: {final_out}")
print(f"Quantized conv_weight range: [{conv_weight.min()}, {conv_weight.max()}]")
print(f"Quantized fc_weight range: [{fc_weight.min()}, {fc_weight.max()}]")
print(f"\nFiles in {outdir}/")
print(f"\nBRAM: conv 72 words (vs 216) = {1-72/216:.0%} less | fc {len(words)} words (vs {n}) = {1-len(words)/n:.0%} less")
