#!/usr/bin/env python3
"""Differential rules test: AetherXiangqi (zig) vs a reference engine.

Plays random legal games with the aetherx movegen; at every ply both engines
receive the same `position startpos moves ...` and we compare the FULL legal
move sets (aetherx `dmoves` vs reference `go perft 1` per-move breakdown).
Any mismatch pinpoints a movegen bug.

Usage:
  python3 tools/diff_vs_pikafish.py [games] [max_plies] [--dump N]
    --dump N  additionally print N positions (FEN + move list) sampled from
              the games, for bench building.
"""
import os
import random
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AETHERX = os.path.join(ROOT, "zig-out", "bin", "aetherx")
PIKA = "/home/a/cchess/Pikafish.2026-09-06/Pikafish-Linux-x86-64-universal"


class Engine:
    def __init__(self, path, errfile=None):
        self.path = path
        self.errfile = errfile
        self.p = self.spawn()

    def spawn(self):
        return subprocess.Popen(
            [self.path], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=open(self.errfile, "ab") if self.errfile else subprocess.DEVNULL,
            text=True, bufsize=1)

    def restart(self):
        print(f"  (restarting {os.path.basename(self.path)})", flush=True)
        self.p = self.spawn()
        self.cmd("uci")
        self.read_until("uciok")

    def cmd(self, *words):
        self.p.stdin.write(" ".join(words) + "\n")
        self.p.stdin.flush()

    def read_until(self, marker):
        lines = []
        while True:
            line = self.p.stdout.readline()
            if not line:
                raise RuntimeError("engine died")
            line = line.strip()
            if line.startswith(marker):
                return lines, line
            lines.append(line)

    def one_line(self):
        line = self.p.stdout.readline()
        if not line:
            raise RuntimeError("engine died")
        return line.strip()


class Aetherx(Engine):
    def moves(self, moves_list):
        self.cmd("position", "startpos", "moves", *moves_list) if moves_list else self.cmd("position", "startpos")
        self.cmd("dmoves")
        return self.one_line().split()

    def fen(self, moves_list):
        self.cmd("position", "startpos", "moves", *moves_list) if moves_list else self.cmd("position", "startpos")
        self.cmd("dfen")
        return self.one_line()

    def halfmove(self, moves_list):
        # halfmove clock of the position AFTER the move list; the trailing
        # move's ply count is what we need, so re-send the full list
        self.cmd("position", "startpos", "moves", *moves_list) if moves_list else self.cmd("position", "startpos")
        self.cmd("dhm")
        return int(self.one_line())


class Pika(Engine):
    def perft1_moves(self, moves_list):
        self.cmd("position", "startpos", "moves", *moves_list) if moves_list else self.cmd("position", "startpos")
        self.cmd("go", "perft", "1")
        lines, _ = self.read_until("Nodes searched")
        return {m for m in re.findall(r"^([a-i][0-9][a-i][0-9]):", "\n".join(lines), re.M)}


def main():
    games = int(sys.argv[1]) if len(sys.argv) > 1 else 100
    max_plies = int(sys.argv[2]) if len(sys.argv) > 2 else 160
    dump_n = 0
    if "--dump" in sys.argv:
        dump_n = int(sys.argv[sys.argv.index("--dump") + 1])
    rng = random.Random(20260930)

    ax = Aetherx(AETHERX)
    pika = Pika(PIKA, errfile="/tmp/pikafish_stderr.log")
    ax.cmd("uci")
    ax.read_until("uciok")
    pika.cmd("uci")
    pika.read_until("uciok")

    total_plies = 0
    dump = []
    for g in range(games):
        moves = []
        for ply in range(max_plies):
            ours = set(ax.moves(moves))
            if not ours:
                break
            try:
                theirs = pika.perft1_moves(moves)
            except RuntimeError:
                # intermittent pikafish death: save the exact command, restart, retry
                with open("/tmp/pika_fail_cmd.txt", "w") as f:
                    f.write("position startpos moves " + " ".join(moves) + "\ngo perft 1\nquit\n")
                print(f"  (pikafish died game {g} ply {ply}; cmd saved; restarting)", flush=True)
                pika.restart()
                theirs = pika.perft1_moves(moves)
            if ours != theirs:
                print(f"MISMATCH game {g} ply {ply}")
                print(f"  moves so far: {' '.join(moves)}")
                print(f"  fen: {ax.fen(moves)}")
                print(f"  only-ours: {sorted(ours - theirs)}")
                print(f"  only-theirs: {sorted(theirs - ours)}")
                sys.exit(1)
            if dump_n and len(dump) < dump_n and rng.random() < 0.02:
                dump.append((ax.fen(moves), sorted(ours)))
            moves.append(rng.choice(sorted(ours)))
            total_plies += 1
            # 60-move natural draw: past ~118 halfmoves without a capture the
            # game is over (and pikafish refuses out-of-range Rule60 counters)
            if len(moves) >= 2 and ax.halfmove(moves) >= 118:
                break
        if g % 10 == 9:
            print(f"  ... {g + 1}/{games} games, {total_plies} plies OK", flush=True)

    print(f"ALL OK: {games} games, {total_plies} positions, move sets identical")
    if dump_n:
        for i, (fen, mv) in enumerate(dump[:dump_n]):
            print(f"BENCH {i}: {fen}  # {len(mv)} moves")


if __name__ == "__main__":
    main()
