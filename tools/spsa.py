#!/usr/bin/env python3
"""SPSA tuner for AetherXiangqi search constants (A3X_SEARCH_PARAMS hook).

Ported from AetherChess3's tools/spsa_stack.py machinery; the match backend
is this repo's tools/match.mjs (UCI pairing runner with movetime support)
instead of the unpublished AetherChess2 match.py.

Chunked and resumable: state (iteration k + theta) is checkpointed after
EVERY iteration (atomic tmp+rename). Stop any time; rerun with the same
--state to resume or raise --iters to extend the schedule.

Per iteration k: perturb all params +/-c_i, play 2*pairs games (+arm vs
-arm, colors paired by the match runner), then
    theta_i += a_k * (Y+ - Y-) / (2 c_i delta_i)
Fishtest-style calibration:
    c_i = c_ratio * (hi_i - lo_i)          (floored at 1)
    a_i = r0 * (hi_i - lo_i) * 2 c_i
    a_k = a_i / (1 + k/K)^alpha,  K = iters/10, alpha = 0.602 (Spall)

Parallelism: --workers concurrent match.mjs processes (each 2 engine
processes), games split evenly across them.

Usage:
  python3 tools/spsa.py --state /tmp/ax_spsa/state.json --iters 60 \
      --pairs 8 --movetime 100 --workers 8
"""
import argparse
import json
import os
import random
import re
import subprocess
import sys
import time

# (name, default, lo, hi) — ORDER MUST MATCH src/tunables.zig defs.
PARAMS = [
    ("rfp_margin", 71, 30, 140),
    ("rfp_max_depth", 8, 2, 12),
    ("razoring", 238, 100, 450),
    ("qs_delta", 50, 0, 120),
    ("ffp_margin", 105, 40, 220),
    ("ffp_max_depth", 8, 3, 12),
    ("nmp_base", 4, 0, 7),
    ("nmp_div", 5, 3, 8),
    ("nmp_eval_div", 196, 80, 400),
    ("nmp_cap", 3, 1, 6),
    ("lmr_move_div", 13, 8, 22),
    ("lmr_depth_div", 14, 4, 24),
    ("hist_gravity", 512, 256, 1024),
    ("lmp_base", 1, 0, 4),
    ("asp_base", 28, 10, 80),
]
NAMES = [p[0] for p in PARAMS]
DEFS = [float(p[1]) for p in PARAMS]
LO = [float(p[2]) for p in PARAMS]
HI = [float(p[3]) for p in PARAMS]

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENV = 'A3X_SEARCH_PARAMS'


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def fmt_params(theta):
    return ','.join(str(int(round(clamp(t, l, h)))) for t, l, h in zip(theta, LO, HI))


def engine_cmd(engine, workdir, vec, tag):
    wrapper = os.path.join(workdir, f'eng_{tag}.sh')
    with open(wrapper, 'w') as f:
        f.write('#!/bin/sh\nexec env %s="%s" %s "$@"\n'
                % (ENV, fmt_params(vec), os.path.abspath(engine)))
    os.chmod(wrapper, 0o755)
    return wrapper


def save_state(path, k, theta, meta):
    tmp = path + '.tmp'
    with open(tmp, 'w') as f:
        json.dump({'k': k, 'theta': theta, 'meta': meta}, f)
    os.replace(tmp, path)


def load_state(path):
    with open(path) as f:
        st = json.load(f)
    return st['k'], st['theta'], st.get('meta', {})


FINAL_RE = re.compile(r'FINAL: A\(\S+\) (\d+) - (\d+) - (\d+) B')


def run_matches(cmd_p, cmd_m, games, movetime, workers, seed):
    """2*workers parallel match.mjs runs, games split evenly. Returns summed
    (wPlus, draw, lPlus)."""
    per = games // workers
    if per < 2:
        per, workers = 2, games // 2
    procs = []
    for i in range(workers):
        # opener rotation offset via env? match.mjs rotates by game index; add
        # seed diversity through the games count only — good enough for tuning
        p = subprocess.Popen(
            ['node', os.path.join(ROOT, 'tools', 'match.mjs'),
             cmd_p, cmd_m, str(per), '1', str(movetime)],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        procs.append(p)
    w = d = l = 0
    for p in procs:
        out = p.communicate()[0]
        m = FINAL_RE.search(out)
        if not m:
            raise RuntimeError('match failed: ' + (out or '')[-200:])
        w += int(m.group(1))
        d += int(m.group(2))
        l += int(m.group(3))
    return w, d, l


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--engine', default=os.path.join(ROOT, 'zig-out', 'bin', 'aetherx'))
    ap.add_argument('--state', default='/tmp/ax_spsa/state.json')
    ap.add_argument('--iters', type=int, default=60)
    ap.add_argument('--chunk', type=int, default=10)
    ap.add_argument('--pairs', type=int, default=8, help='paired comparisons per iteration')
    ap.add_argument('--movetime', type=int, default=100)
    ap.add_argument('--workers', type=int, default=8)
    ap.add_argument('--seed', type=int, default=4242)
    ap.add_argument('--c-ratio', type=float, default=0.15)
    ap.add_argument('--r0', type=float, default=0.002)
    ap.add_argument('--alpha', type=float, default=0.602)
    args = ap.parse_args()

    workdir = os.path.dirname(os.path.abspath(args.state))
    os.makedirs(workdir, exist_ok=True)
    C = [max(1.0, args.c_ratio * (h - l)) for l, h in zip(LO, HI)]
    A = [args.r0 * (h - l) * 2.0 * c for l, h, c in zip(LO, HI, C)]
    K = max(1.0, args.iters / 10.0)
    log = os.path.join(workdir, 'tune.log')

    k, theta, meta = 0, list(DEFS), {}
    if os.path.exists(args.state):
        k, theta, meta = load_state(args.state)
        print(f'resumed from {args.state}: k={k}', flush=True)
    if len(theta) != len(PARAMS):
        print('state theta size mismatch — refusing to run', file=sys.stderr)
        sys.exit(1)
    if k >= args.iters:
        print(f'k={k} >= --iters {args.iters}; current params:')
        print(ENV + '=' + fmt_params(theta))
        return

    print(f'SPSA {len(PARAMS)} params, iters {k}->{args.iters}, '
          f'pairs={args.pairs} movetime={args.movetime}ms workers={args.workers} '
          f'c_ratio={args.c_ratio} r0={args.r0} alpha={args.alpha} K={K:.0f}', flush=True)
    t0 = time.time()
    chunk_start, chunk_sig = k, []
    while k < args.iters:
        rng = random.Random(args.seed * 1_000_003 + k)  # deterministic per k
        deltas = [1 if rng.random() < 0.5 else -1 for _ in PARAMS]
        vp = [clamp(t + ci * d, l, h) for t, ci, d, l, h in zip(theta, C, deltas, LO, HI)]
        vm = [clamp(t - ci * d, l, h) for t, ci, d, l, h in zip(theta, C, deltas, LO, HI)]

        cmd_p = engine_cmd(args.engine, workdir, vp, 'p')
        cmd_m = engine_cmd(args.engine, workdir, vm, 'm')
        w, d, l = run_matches(cmd_p, cmd_m, 2 * args.pairs, args.movetime,
                              args.workers, args.seed * 1_000_003 + k)
        n = w + l + d
        yp = (w + 0.5 * d) / n
        dy = yp - (1.0 - yp)

        decay = (1.0 + k / K) ** args.alpha
        for i in range(len(PARAMS)):
            step = (A[i] / decay) * dy / (2.0 * C[i] * deltas[i])
            theta[i] = clamp(theta[i] + clamp(step, -C[i], C[i]), LO[i], HI[i])
        k += 1
        chunk_sig.append(dy)
        save_state(args.state, k, theta,
                   {'seed': args.seed, 'movetime': args.movetime, 'pairs': args.pairs,
                    'engine': args.engine, 'c_ratio': args.c_ratio, 'r0': args.r0,
                    'alpha': args.alpha})

        if k % args.chunk == 0 or k == args.iters:
            el = time.time() - t0
            msg = (f'[chunk {chunk_start}->{k}] {el/60:.1f}min '
                   f'signal={sum(chunk_sig)/len(chunk_sig):+.3f} '
                   f'theta: ' +
                   ' '.join(f'{n_}={int(round(t))}' for n_, t in zip(NAMES, theta)))
            print(msg, flush=True)
            with open(log, 'a') as f:
                f.write(msg + '\n')
            chunk_start, chunk_sig = k, []

    print(ENV + '=' + fmt_params(theta))
    print('verify: timed gate vs current defaults before adopting', flush=True)


if __name__ == '__main__':
    main()
