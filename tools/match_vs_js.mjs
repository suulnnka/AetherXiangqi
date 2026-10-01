#!/usr/bin/env node
// Match: Zig NNUE engine (UCI) vs the original v0.1-js engine (in-process,
// extracted from git tag v0.1-js at runtime). Equal node budgets per move,
// colors alternated, fixed opening rotation.
//
// Usage: node tools/match_vs_js.mjs [zigPath] [games=60] [nodes=50000]
import { spawn, execSync } from 'node:child_process';
import readline from 'node:readline';
import fs from 'node:fs';

const zigPath = process.argv[2] || './zig-out/bin/aetherx';
const games = +(process.argv[3] || 60);
const nodes = +(process.argv[4] || 50000);

// ---- old JS engine from git tag
const JS_PATH = '/tmp/engine_v01_match.js';
if (!fs.existsSync(JS_PATH)) {
  execSync(`git show v0.1-js:src/engine.js > ${JS_PATH}`, { shell: '/bin/bash' });
}
const E = await import(JS_PATH);

// ---- zig engine over UCI
const Z = spawn(zigPath, [], { stdio: ['pipe', 'pipe', 'ignore'] });
const zrl = readline.createInterface({ input: Z.stdout, crlfDelay: Infinity });
const zq = [];
const zw = [];
zrl.on('line', l => (zw.length ? zw.shift()(l) : zq.push(l)));
const zUntil = async pred => {
  const test = typeof pred === 'string' ? l => l.startsWith(pred) : pred;
  while (true) {
    const l = zq.length ? zq.shift() : await new Promise(r => zw.push(r));
    if (test(l)) return l;
  }
};
Z.stdin.write('uci\n');
await zUntil('uciok');
const zigBest = async uciMoves => {
  Z.stdin.write(uciMoves.length ? `position startpos moves ${uciMoves.join(' ')}\n` : 'position startpos\n');
  Z.stdin.write(`go nodes ${nodes}\n`);
  return (await zUntil('bestmove')).split(' ')[1];
};

// ---- coordinate mapping: our sq = row*9+col (row 0 = red), js row 0 = black.
// Vertical flip is fixed; horizontal orientation is resolved by matching the
// startpos legal-move sets both ways.
const uciOf = (sq, mirror) => {
  const r = Math.floor(sq / 9), c = sq % 9;
  return String.fromCharCode('a'.charCodeAt(0) + (mirror ? 8 - c : c)) + (9 - r);
};
const jsOf = (sqStr, mirror) => {
  const c = sqStr.charCodeAt(0) - 97, r = +sqStr[1];
  const jc = mirror ? 8 - c : c;
  return (9 - r) * 9 + jc;
};
let mirror = false;
{
  const ours = new Set(((await (async () => {
    Z.stdin.write('position startpos\ndmoves\n');
    return zUntil(l => l.includes(' ')); // dmoves line starts with a space
  })())).trim().split(/\s+/).filter(Boolean));
  for (const cand of [false, true]) {
    const theirs = new Set(E.genLegal(E.newBoard(), 0).map(m => {
      const f = m >> 7, t = m & 127;
      return uciOf(f, cand) + uciOf(t, cand);
    }));
    let ok = theirs.size === ours.size;
    if (ok) for (const m of theirs) if (!ours.has(m)) { ok = false; break; }
    if (ok) { mirror = cand; break; }
  }
  if (mirror === null) throw new Error('coordinate mapping failed');
  console.log(`mapping: mirror=${mirror} (startpos sets match)`);
}

const openers = [['h2e2', 'b9c7'], ['b0c2', 'h9g7'], ['b2e2', 'h9g7'], ['g0e2', 'h9g7']];
let zWin = 0, jWin = 0, draw = 0;
const t0 = Date.now();
for (let g = 0; g < games; g++) {
  const zigIsRed = g % 2 === 0;
  const uciMoves = [...openers[g % openers.length]];
  const bd = E.newBoard();
  E.replayMoves(bd, uciMoves.map(m => (jsOf(m.slice(0, 2), mirror) << 7) | jsOf(m.slice(2), mirror)));
  let result = null;
  for (let ply = 0; ply < 240; ply++) {
    const side = uciMoves.length % 2; // 0 red
    let uci;
    if ((side === 0) === zigIsRed) {
      uci = await zigBest(uciMoves);
    } else {
      const r = E.searchBest(bd, side, { nodes });
      if (!r.move) { result = 'zig' === (side === 0 ? 'red' : 'black') ? null : null; }
      if (!r.move) { // no legal move: mover loses (mate or 困毙)
        result = (side === 0) === zigIsRed ? 'js' : 'zig';
        break;
      }
      uci = uciOf(r.move >> 7, mirror) + uciOf(r.move & 127, mirror);
    }
    if (!uci || uci === '(none)') {
      result = (side === 0) === zigIsRed ? 'js' : 'zig';
      break;
    }
    uciMoves.push(uci);
    if (side === 1 || (side === 0) !== zigIsRed || true) {
      // keep the js board in sync every move
      E.make(bd, (jsOf(uci.slice(0, 2), mirror) << 7) | jsOf(uci.slice(2), mirror));
    }
  }
  if (result === null) result = 'd';
  if (result === 'zig') zWin++;
  else if (result === 'js') jWin++;
  else draw++;
  if ((g + 1) % 10 === 0) console.log(`  ${g + 1}/${games}: zig ${zWin} - js ${jWin} - D ${draw} (${((Date.now() - t0) / 1000).toFixed(0)}s)`);
}
Z.kill();
const n = zWin + jWin + draw;
const score = (zWin + draw / 2) / n;
const elo = -400 * Math.log10(1 / Math.max(Math.min(score, 0.99), 0.01) - 1);
console.log(`FINAL: Zig(NNUE) ${zWin} - ${draw} - ${jWin} JS(v0.1)  score ${(score * 100).toFixed(1)}%  ~${elo.toFixed(0)} Elo (${n} games @ ${nodes} nodes, ${(Date.now() - t0) / 1000 | 0}s)`);
