#!/usr/bin/env python3
"""Benchmark that works NOW (NumPy) and optionally PyTorch (GPU)."""
import time
import numpy as np

# Network params (same as FPGA)
IN_CH, IN_H, IN_W = 3, 16, 16
OUT_CH = 8
FC_IN = 512
FC_OUT = 4

# Generate same data as FPGA test
np.random.seed(42)
inp = np.random.randn(1, IN_CH, IN_H, IN_W).astype(np.float32)
conv_w = np.random.randn(OUT_CH, IN_CH, 3, 3).astype(np.float32) * 0.1
conv_b = np.random.randn(OUT_CH).astype(np.float32) * 0.1
fc_w = np.random.randn(FC_OUT, FC_IN).astype(np.float32) * 0.1
fc_b = np.random.randn(FC_OUT).astype(np.float32) * 0.1

def conv3x3_relu_pool_fc(x):
    """Same computation as our Verilog, in NumPy."""
    # Conv3×3 with pad=1
    batch, c_in, h, w = x.shape
    padded = np.pad(x, ((0,0),(0,0),(1,1),(1,1)))
    conv_out = np.zeros((batch, OUT_CH, h, w), dtype=np.float32)
    for co in range(OUT_CH):
        for ci in range(c_in):
            for ky in range(3):
                for kx in range(3):
                    conv_out[:, co] += padded[:, ci, ky:ky+h, kx:kx+w] * conv_w[co, ci, ky, kx]
    conv_out += conv_b.reshape(1, -1, 1, 1)
    conv_out = np.maximum(conv_out, 0)  # ReLU

    # MaxPool 2×2
    pooled = conv_out[:, :, ::2, ::2]

    # FC
    flat = pooled.reshape(batch, -1)
    return flat @ fc_w.T + fc_b

# --- NumPy benchmark ---
N_ITER = 1000
# Warmup
for _ in range(10):
    _ = conv3x3_relu_pool_fc(inp)

start = time.perf_counter()
for _ in range(N_ITER):
    _ = conv3x3_relu_pool_fc(inp)
numpy_ms = (time.perf_counter() - start) / N_ITER * 1000

print("=" * 65)
print("  Mini ResNet CNN Benchmark (3×16×16, ~1.16 MFLOPs)")
print("=" * 65)

FPGA_MS = 57858 / 50000.0  # 57,858 cycles @ 50MHz

print(f"\n  {'Device':<30} {'Latency':<12} {'vs FPGA':<12}")
print(f"  {'-'*55}")
print(f"  {'FPGA XC7Z020 @ 50MHz':<30} {FPGA_MS:>8.3f} ms   {'1.0x':>8}")
print(f"  {'CPU (NumPy)':<30} {numpy_ms:>8.3f} ms   {FPGA_MS/numpy_ms:>7.1f}x faster")

# --- PyTorch benchmark (if available) ---
try:
    import torch
    import torch.nn as nn

    class MiniResNet(nn.Module):
        def __init__(self):
            super().__init__()
            self.conv = nn.Conv2d(IN_CH, OUT_CH, 3, padding=1)
            self.pool = nn.MaxPool2d(2, 2)
            self.fc = nn.Linear(FC_IN, FC_OUT)
        def forward(self, x):
            x = self.pool(torch.relu(self.conv(x)))
            return self.fc(x.view(x.size(0), -1))

    model = MiniResNet()
    x_t = torch.randn(1, IN_CH, IN_H, IN_W)
    model.eval()

    with torch.no_grad():
        # CPU
        for _ in range(50): _ = model(x_t)
        start = time.perf_counter()
        for _ in range(N_ITER): _ = model(x_t)
        torch_cpu_ms = (time.perf_counter() - start) / N_ITER * 1000
        print(f"  {'CPU (PyTorch)':<30} {torch_cpu_ms:>8.3f} ms   {FPGA_MS/torch_cpu_ms:>7.1f}x faster")

        # GPU
        if torch.cuda.is_available():
            device = torch.device('cuda')
            model_gpu = model.to(device)
            x_gpu = x_t.to(device)
            for _ in range(50): _ = model_gpu(x_gpu)
            torch.cuda.synchronize()
            start = time.perf_counter()
            for _ in range(N_ITER): _ = model_gpu(x_gpu)
            torch.cuda.synchronize()
            torch_gpu_ms = (time.perf_counter() - start) / N_ITER * 1000
            print(f"  {'GPU {torch.cuda.get_device_name(0)}':<30} {torch_gpu_ms:>8.3f} ms   {FPGA_MS/torch_gpu_ms:>7.1f}x faster")

            # Standard ResNet-18 (224×224, GPU only)
            print(f"\n  {'Standard ResNet-18 (224×224)':<30}")
            import torchvision.models as tvm
            r18 = tvm.resnet18(pretrained=False).to(device).eval()
            x_big = torch.randn(1, 3, 224, 224, device=device)
            with torch.no_grad():
                for _ in range(10): _ = r18(x_big)
                torch.cuda.synchronize()
                start = time.perf_counter()
                for _ in range(100): _ = r18(x_big)
                torch.cuda.synchronize()
                r18_ms = (time.perf_counter() - start) / 100 * 1000
            print(f"  {'GPU ResNet-18':<30} {r18_ms:>8.3f} ms")
            print(f"  (FPGA cannot fit ResNet-18: needs 11.7MB weights, has 630KB BRAM)")

except ImportError:
    print(f"\n  [PyTorch not yet installed — GPU benchmark pending]")

print(f"\n{'='*65}")
print(f"  FPGA implementation is SEQUENTIAL (1 MAC/cycle).")
print(f"  A fully parallel FPGA (220 DSPs) would be ~220x faster")
print(f"  but requires 220x more resources.")
print(f"{'='*65}")
