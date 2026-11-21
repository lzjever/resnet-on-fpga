#!/usr/bin/env python3
"""Randomized cross-check for the INT4 ResNet core.

For each seed: regenerate weights/inputs/golden (bit-exact Python model),
run the RTL in iverilog, require a PASS. A single fixed vector cannot prove
index/packing correctness; 10+ independent vectors make an indexing bug
essentially impossible to miss. Optionally add an adversarial wide-input
run (INPUT_RANGE >> 16) to exercise the 16-bit truncation paths.
"""
import os, subprocess, sys

repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

def run_case(seed, in_range):
    env = dict(os.environ, SEED=str(seed), INPUT_RANGE=str(in_range))
    gen = subprocess.run([sys.executable, f'{repo}/sim/gen_weights_int4.py'],
                         env=env, capture_output=True, text=True)
    if gen.returncode:
        return f'GEN FAIL', gen.stderr[-500:]
    golden = next((l for l in gen.stdout.splitlines() if 'Golden output' in l), '?')

    cmp_ = subprocess.run(['iverilog', '-g2012', '-o', '/tmp/rand_t.vvp',
                           f'{repo}/rtl/resnet_top_int4.v', f'{repo}/sim/tb_core_int4.v'],
                          capture_output=True, text=True)
    if cmp_.returncode:
        return 'COMPILE FAIL', cmp_.stderr[-500:]
    sim = subprocess.run(['vvp', '/tmp/rand_t.vvp'], capture_output=True, text=True)
    ok = ('PASS:' in sim.stdout)
    return ('PASS' if ok else 'SIM FAIL'), (golden if ok else sim.stdout[-500:])

if __name__ == '__main__':
    cases = [(s, 16) for s in range(1, 11)]          # 10 normal vectors
    cases.append((101, 3000))                         # adversarial: forces conv >16-bit wrap
    cases.append((102, 30000))                        # adversarial: near full INT16 scale

    fails = 0
    for seed, rng in cases:
        tag = f'seed={seed:>3} range=±{rng:<5}'
        st, info = run_case(seed, rng)
        print(f'{tag} {st}  {info if st != "PASS" else ""}')
        if st != 'PASS':
            print(info)
            fails += 1

    # restore canonical seed-42 data (hex files must match the bitstream)
    subprocess.run([sys.executable, f'{repo}/sim/gen_weights_int4.py'],
                   env=dict(os.environ, SEED='42'), capture_output=True)

    print(f'\n{"ALL PASS" if fails == 0 else f"{fails} FAILURES"}')
    sys.exit(1 if fails else 0)
