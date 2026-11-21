#!/usr/bin/env python3
"""Benchmark: same minimal ResNet CNN on FPGA vs GPU vs CPU.

FPGA: Zynq XC7Z020 @ 50MHz, 220 DSPs (sequential MAC, 1 DSP active)
GPU:  NVIDIA RTX 5080 Laptop (16GB, ~2.6GHz, 7680 CUDA cores)
CPU:  (system CPU)

Network: Input(3×16×16) → Conv3×3(3→8)+ReLU → MaxPool2×2 → FC(512→4)
FPGA cycles: 57,858 @ 50MHz = 1.157ms (from iverilog simulation)
"""
import time
import numpy as np

# ============================================================
# Part 1: FPGA results (from simulation, not measured on board)
# ============================================================
FPGA_CYCLES = 57858
FPGA_CLK_MHZ = 50.0
FPGA_TIME_MS = FPGA_CYCLES / (FPGA_CLK_MHZ * 1000)  # ms

# ============================================================
# Part 2: PyTorch benchmark
# ============================================================
import torch
import torch.nn as nn

class MiniResNet(nn.Module):
    """Same architecture as our Verilog implementation."""
    def __init__(self):
        super().__init__()
        self.conv = nn.Conv2d(3, 8, kernel_size=3, padding=1)
        self.relu = nn.ReLU()
        self.pool = nn.MaxPool2d(2, 2)
        self.fc = nn.Linear(8 * 8 * 8, 4)

    def forward(self, x):
        x = self.pool(self.relu(self.conv(x)))
        x = x.view(x.size(0), -1)
        return self.fc(x)

def benchmark_model(model, input_tensor, device, n_warmup=50, n_iter=1000):
    """Benchmark inference latency."""
    model = model.to(device)
    input_tensor = input_tensor.to(device)
    model.eval()

    with torch.no_grad():
        # Warmup
        for _ in range(n_warmup):
            _ = model(input_tensor)

        if device.type == 'cuda':
            torch.cuda.synchronize()

        # Timed runs
        start = time.perf_counter()
        for _ in range(n_iter):
            _ = model(input_tensor)

        if device.type == 'cuda':
            torch.cuda.synchronize()

        elapsed = time.perf_counter() - start

    return elapsed / n_iter * 1000  # ms per inference

def main():
    print("=" * 60)
    print("  Mini ResNet CNN Benchmark: FPGA vs GPU vs CPU")
    print("=" * 60)
    print()
    print(f"  Network: 3×16×16 → Conv3×3(3→8)+ReLU → Pool → FC(512→4)")
    print()

    # FPGA (from simulation)
    print(f"  [FPGA] Zynq XC7Z020 @ {FPGA_CLK_MHZ:.0f} MHz, sequential MAC")
    print(f"         Cycles: {FPGA_CYCLES:,} → {FPGA_TIME_MS:.3f} ms/inference")
    print()

    # PyTorch model
    model = MiniResNet()
    input_tensor = torch.randn(1, 3, 16, 16)

    # CPU
    cpu = torch.device('cpu')
    cpu_ms = benchmark_model(model, input_tensor, cpu)
    print(f"  [CPU]  {torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'Host CPU'}")
    print(f"         {cpu_ms:.3f} ms/inference")

    # GPU
    if torch.cuda.is_available():
        gpu = torch.device('cuda')
        gpu_ms = benchmark_model(model, input_tensor, gpu)
        print(f"  [GPU]  {torch.cuda.get_device_name(0)}")
        print(f"         {gpu_ms:.3f} ms/inference")
    else:
        gpu_ms = None
        print(f"  [GPU]  Not available")

    # Summary
    print()
    print("=" * 60)
    print("  Summary (lower is better)")
    print("=" * 60)
    print(f"  {'Device':<25} {'Latency (ms)':<15} {'vs FPGA':<10}")
    print(f"  {'-'*50}")
    print(f"  {'FPGA (XC7Z020 @50MHz)':<25} {FPGA_TIME_MS:<15.3f} {'1.0x':<10}")
    print(f"  {'CPU':<25} {cpu_ms:<15.3f} {FPGA_TIME_MS/cpu_ms:<10.1f}x faster")
    if gpu_ms:
        print(f"  {'GPU (RTX 5080)':<25} {gpu_ms:<15.3f} {FPGA_TIME_MS/gpu_ms:<10.1f}x faster")

    # Larger input comparison (GPU only, FPGA can't fit)
    print()
    print("=" * 60)
    print("  Standard ResNet-18 (224×224) — GPU only (FPGA BRAM too small)")
    print("=" * 60)
    import torchvision.models as models
    resnet18 = models.resnet18(pretrained=False)
    big_input = torch.randn(1, 3, 224, 224)
    big_ms = benchmark_model(resnet18, big_input, cpu, n_warmup=5, n_iter=20)
    print(f"  CPU:  {big_ms:.2f} ms/inference")
    if torch.cuda.is_available():
        big_gpu_ms = benchmark_model(resnet18, big_input, gpu, n_warmup=10, n_iter=100)
        print(f"  GPU:  {big_gpu_ms:.2f} ms/inference")

    print()
    print("  Note: FPGA implementation is sequential (1 MAC/cycle).")
    print("  A fully parallel FPGA design would be ~100x faster but")
    print("  requires significantly more resources (all 220 DSPs).")

if __name__ == '__main__':
    main()
