#!/usr/bin/env python3
"""Px0 PGN -> FEN stream extractor for NNUE distillation.

The archive holds ~1.05M engine games (GBK-encoded PGNs, Chinese move
notation, custom DeepOpen opening FENs). This replays every game on a plain
Python board and emits sampled FENs (teacher relabels them later).

Chinese notation rules implemented (traditional + simplified accepted):
  [前/后/中]? piece file (action (平|进/退) (file|steps))
  - red files 一..九 = cols 8..0, black files 1..9 = cols 0..8
  - 平: horizontal, same row, arg = dest file
  - 进/退 for 車炮帅兵: arg = steps (vertical); for 馬相象仕士: arg = dest file
  - 前 = closest to the enemy among same-type pieces sharing a file

Usage: px0_extract.py <pgn_root_or_zip> <out_prefix> [--workers N]
       [--max N] [--per-game K] [--step S] [--skip P]
"""
import os
import re
import sys
import glob
import zipfile
import multiprocessing as mp

# ---------------------------------------------------------------- board utils
# board: list[90], piece letters uppercase=red lowercase=black, '' empty
# sq = row*9+col, row 0 = RED back rank (matches the engine's convention and
# the FEN layout: first FEN row = row 9).

def fen_to_board(fen):
    bd = [''] * 90
    toks = fen.split()
    row, col = 9, 0
    for ch in toks[0]:
        if ch.isdigit():
            col += int(ch)
        elif ch == '/':
            row -= 1
            col = 0
        else:
            if 0 <= row <= 9 and 0 <= col <= 8:
                bd[row * 9 + col] = ch
            col += 1
    return bd

def board_side(bd):
    return bd  # letters encode the side (case)

PIECE = {}
for tr, sm, p in [('車', '车', 'R'), ('馬', '马', 'N'), ('炮', '炮', 'C'), ('砲', '砲', 'C'),
                  ('兵', '兵', 'P'), ('卒', '卒', 'P'), ('相', '相', 'B'), ('象', '象', 'B'),
                  ('仕', '仕', 'A'), ('士', '士', 'A'), ('帥', '帅', 'K'), ('將', '将', 'K')]:
    PIECE[tr] = p
    PIECE[sm] = p
NUM_CN = {'一': 1, '二': 2, '三': 3, '四': 4, '五': 5, '六': 6, '七': 7, '八': 8, '九': 9}
ACT = {'平': 'P', '進': 'F', '进': 'F', '退': 'B'}
PREFIX = {'前': 'F', '后': 'B', '後': 'B', '中': 'M'}

move_re = re.compile(r'([前中后後]?)([車车马馬炮砲兵卒相象仕士帥帅将將])([一二三四五六七八九1-9]?)'
                     r'(平|進|进|退)([一二三四五六七八九1-9])')
iccs_re = re.compile(r'([A-Ia-i])([0-9])-([A-Ia-i])([0-9])')

def in_own_palace(stm, row, col):
    if not (3 <= col <= 5):
        return False
    return (0 <= row <= 2) if stm == 0 else (7 <= row <= 9)

def is_elephant_point(stm, row, col):
    # red points rows 0/2/4, black rows 9/7/5 (odd); cols always even
    own = row <= 4 if stm == 0 else row >= 5
    return own and col % 2 == 0 and row % 2 == (0 if stm == 0 else 1)

def sane_target(bd, stm, pty, frm, to):
    """Geometry-level sanity of the derived (frm,to) — no movegen needed."""
    if not (0 <= to < 90) or to == frm:
        return False
    t = bd[to]
    if t and (t.isupper() == (stm == 0)):
        return False  # own piece
    row, col = to // 9, to % 9
    frow = frm // 9
    if pty == 'A':
        return in_own_palace(stm, row, col) and in_own_palace(stm, frow, col)
    if pty == 'K':
        return in_own_palace(stm, row, col)
    if pty == 'B':
        return is_elephant_point(stm, row, col) and is_elephant_point(stm, frow, col)
    if pty == 'P':
        crossed = frow >= 5 if stm == 0 else frow <= 4
        if col != frm % 9:
            return crossed  # sideways needs river crossed
        return row == frow + (1 if stm == 0 else -1)
    return True

def parse_move(bd, stm, token):
    """token -> (frm, to) or None. stm: 0 red, 1 black."""
    if any('\uff10' <= c <= '\uff19' for c in token):
        token = token.translate({ord(c): ord(c) - 0xFEE0 for c in token if '\uff10' <= c <= '\uff19'})
    # ICCS coordinate form: G7-G2 / b0c2
    m2 = iccs_re.fullmatch(token)
    if m2:
        frm = int(m2.group(2)) * 9 + (ord(m2.group(1).upper()) - ord('A'))
        to = int(m2.group(4)) * 9 + (ord(m2.group(3).upper()) - ord('A'))
        return (frm, to) if 0 <= frm < 90 and 0 <= to < 90 else None
    m = move_re.fullmatch(token)
    if not m:
        return None
    pre, pch, fch, act, ach = m.groups()
    pty = PIECE[pch]
    up = pty if stm == 0 else pty.lower()

    def file_col(ch):
        v = NUM_CN.get(ch)
        if v is not None:
            return 9 - v  # red frame: 一 = col 8 (i) .. 九 = col 0 (a)
        return int(ch) - 1  # black frame: 1 = col 0 (a) .. 9 = col 8 (i)

    def steps_num(ch):
        return NUM_CN.get(ch) or int(ch)

    def derive(frm):
        """derive (frm,to) from the token's action, or None if not sane."""
        row = frm // 9
        col = frm % 9
        fwd = 1 if stm == 0 else -1
        a = ACT[act]
        if a == 'P':
            to = row * 9 + file_col(ach)
        else:
            sign = fwd if a == 'F' else -fwd
            if pty in ('N', 'B', 'A'):
                dcol = file_col(ach)
                dc = dcol - col
                if pty == 'B':
                    if abs(dc) != 2:
                        return None
                    dr = 2
                elif pty == 'N':
                    if abs(dc) not in (1, 2):
                        return None
                    dr = 2 if abs(dc) == 1 else 1
                else:
                    if abs(dc) != 1:
                        return None
                    dr = 1
                to = (row + sign * dr) * 9 + dcol
            else:
                st = steps_num(ach)
                if pty == 'P' and st != 1:
                    return None
                if pty == 'K' and st != 1:
                    return None
                to = (row + sign * st) * 9 + col
        return (frm, to) if sane_target(bd, stm, pty, frm, to) else None

    if pre:
        # pieces of this type sharing a file (standard 前/后 case) ...
        by_file = {}
        for sq in range(90):
            if bd[sq] == up:
                by_file.setdefault(sq % 9, []).append(sq)
        dup = [sqs for sqs in by_file.values() if len(sqs) >= 2]
        if len(dup) == 1:
            sqs = sorted(dup[0], reverse=(stm == 0))  # front first
        elif by_file:
            # degenerate: no same-file pair — fall back to global frontness
            allsq = sorted([sq for sqs in by_file.values() for sq in sqs], reverse=(stm == 0))
            sqs = allsq
        else:
            return None
        if pre in ('前',):
            cands = [sqs[0]]
        elif pre in ('后', '後'):
            cands = [sqs[-1]]
        else:  # 中: 3 pieces on one file
            if len(sqs) != 3:
                return None
            cands = [sqs[1]]
    else:
        col = file_col(fch)
        cands = [sq for sq in range(90) if bd[sq] == up and sq % 9 == col]
    # same-file advisor/elephant doubles disambiguate through 进/退 geometry:
    # keep the candidates whose derived target is sane, require exactly one
    good = [mv for sq in cands if (mv := derive(sq)) is not None]
    if len(good) == 1:
        return good[0]
    if not pre and len(cands) == 1:
        return derive(cands[0])  # unique piece but an insane target: report as-is (None)
    return None

def apply_move(bd, frm, to):
    bd[to] = bd[frm]
    bd[frm] = ''

def bd_to_fen_board(bd):
    rows = []
    for r in range(9, -1, -1):
        run = 0
        out = ''
        for c in range(9):
            p = bd[r * 9 + c]
            if p == '':
                run += 1
            else:
                if run:
                    out += str(run)
                    run = 0
                out += p
        if run:
            out += str(run)
        rows.append(out)
    return '/'.join(rows)

# ---------------------------------------------------------------- PGN parsing
hdr_fen = None

def parse_game(text):
    """-> (start_fen, [move tokens]) or None"""
    fen = None
    moves = []
    # strip comments {..} and parens, split headers
    body = re.sub(r'\{[^}]*\}', ' ', text)
    for line in body.splitlines():
        line = line.strip()
        if line.startswith('['):
            mm = re.match(r'\[FEN\s+"([^"]+)"\]', line)
            if mm:
                fen = mm.group(1)
            continue
        for tok in line.split():
            if tok in ('*', '1-0', '0-1', '1/2-1/2', '+', '-') or tok[0] == '$':
                continue
            tok2 = re.sub(r'^\d+\.+', '', tok)
            if not tok2:
                continue
            if tok2 in ('*', '1-0', '0-1', '1/2-1/2'):
                continue
            moves.append(tok2)
    if fen is None:
        return None
    return fen, moves

def replay_game(fen, tokens):
    """-> list of FENs (positions before each sampled ply) or None on error"""
    bd = fen_to_board(fen)
    stm = 0 if fen.split()[1] == 'w' else 1
    out = []
    for ply, tok in enumerate(tokens):
        mv = parse_move(bd, stm, tok)
        if mv is None:
            return out, True  # emit what we have, flag truncation
        frm, to = mv
        if ply >= CFG['skip'] and (ply - CFG['skip']) % CFG['step'] == 0 and len(out) < CFG['per_game']:
            out.append(bd_to_fen_board(bd) + (' b ' if stm == 0 else ' w ') + '- - 0 1')
        apply_move(bd, frm, to)
        stm ^= 1
    return out, False

CFG = {}

def set_cfg(cfg):
    global CFG
    CFG = cfg

def worker(args):
    idx, files = args
    out_path = f"{CFG['out']}.{idx:03d}"
    n_games = n_pos = n_trunc = 0
    with open(out_path, 'w') as f:
        for path in files:
            try:
                raw = open(path, 'rb').read()
                text = raw.decode('gbk', errors='replace')
            except OSError:
                continue
            g = parse_game(text)
            if g is None:
                continue
            fens, trunc = replay_game(*g)
            n_games += 1
            n_trunc += trunc
            for fen in fens:
                f.write(fen + '\n')
                n_pos += 1
    return n_games, n_pos, n_trunc

def iter_zip_files(zpath, tmp_root):
    """Extract the zip once (cached), then yield real file paths."""
    marker = os.path.join(tmp_root, '.extracted')
    if not os.path.exists(marker):
        with zipfile.ZipFile(zpath) as z:
            z.extractall(tmp_root)
        open(marker, 'w').write('ok')
    files = []
    for root, _, names in os.walk(tmp_root):
        for n in names:
            if n.endswith('.pgn'):
                files.append(os.path.join(root, n))
    files.sort()
    return files

def main():
    global CFG
    src = sys.argv[1]
    out = sys.argv[2]
    CFG = {'out': out, 'workers': 12, 'max': 5_000_000, 'per_game': 30, 'step': 2, 'skip': 0}
    argv = sys.argv[3:]
    for i in range(0, len(argv) - 1, 2):
        k = argv[i].lstrip('-')
        if k in ('workers', 'max', 'per_game', 'step', 'skip'):
            CFG[k] = int(argv[i + 1])
    print(f"cfg: {CFG}", flush=True)

    tmp_root = os.path.join(os.path.dirname(out) or '.', '_px0_pgns')
    if src.endswith('.zip'):
        print('extracting zip (cached)...', flush=True)
        files = iter_zip_files(src, tmp_root)
    else:
        files = sorted(glob.glob(os.path.join(src, '**', '*.pgn'), recursive=True))
    print(f'{len(files)} pgn files', flush=True)

    # shard files across workers (CFG travels via initializer: py3.14 default
    # start method is forkserver, which does not inherit main()'s globals)
    per = (len(files) + CFG['workers'] - 1) // CFG['workers']
    shards = [(i, files[i * per:(i + 1) * per]) for i in range(CFG['workers'])]
    with mp.Pool(CFG['workers'], initializer=set_cfg, initargs=(CFG,)) as pool:
        stats = pool.map(worker, shards)
    tg = sum(s[0] for s in stats)
    tp = sum(s[1] for s in stats)
    tt = sum(s[2] for s in stats)
    print(f'games parsed: {tg}, truncated: {tt} ({100 * tt / max(tg, 1):.2f}%), positions: {tp}')

if __name__ == '__main__':
    main()
