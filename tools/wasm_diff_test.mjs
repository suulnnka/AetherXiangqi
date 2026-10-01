#!/usr/bin/env node
// WASM differential test: the wasm engine must agree with the native binary
// on every position of random games — legal-move sets (wire), board bytes,
// stm, and the NNUE eval (identical net + math ⇒ identical centipawns).
// Plus startpos perft through the wasm exports and a think smoke test.
//
// Usage: node tools/wasm_diff_test.mjs [games=40] [plies=120]
import { execSync } from 'node:child_process';
import fs from 'node:fs';
import readline from 'node:readline';
import { spawn } from 'node:child_process';

const wasmPath = new URL('../wasm/aetherx.wasm', import.meta.url);
const nativePath = new URL('../zig-out/bin/aetherx', import.meta.url).pathname;
const GAMES = +(process.argv[2] || 40);
const PLIES = +(process.argv[3] || 120);

const { instance } = await WebAssembly.instantiate(fs.readFileSync(wasmPath), {});
const W = instance.exports;

// uci sq string -> wire move, via engine coords; conv is an involution
const eng = (s) => (+(s[1])) * 9 + (s.charCodeAt(0) - 97);
const conv = (sq) => (9 - Math.floor(sq / 9)) * 9 + (sq % 9);
const toWire = (u) => (conv(eng(u.slice(0, 2))) << 7) | conv(eng(u.slice(2)));

const native = spawn(nativePath, [], { stdio: ['pipe', 'pipe', 'ignore'] });
const nrl = readline.createInterface({ input: native.stdout, crlfDelay: Infinity });
const nq = [], nw = [];
nrl.on('line', l => (nw.length ? nw.shift()(l) : nq.push(l)));
native.once('exit', (c) => { console.log('NATIVE EXITED code', c); process.exit(2); });
let lastCmd = '(none)';
const nUntil = async pred => {
  const test = typeof pred === 'string' ? l => l.startsWith(pred) : pred;
  while (true) {
    let l;
    if (nq.length) {
      l = nq.shift();
    } else {
      const p = new Promise(r => nw.push(r));
      let timer;
      const timeout = new Promise((_, rej) => { timer = setTimeout(() => rej(new Error('TIMEOUT waiting reply for: ' + lastCmd)), 15000); });
      timeout.catch(() => {}); // swallow the losing rejection of the race
      l = await Promise.race([p, timeout]);
      clearTimeout(timer);
    }
    if (test(l)) return l;
  }
};
native.stdin.write('uci\n');
await nUntil('uciok');
const ncmd = async c => { lastCmd = c.split('\n').pop(); native.stdin.write(c + '\n'); return nUntil(l => true); };
const nLine = async c => { native.stdin.write(c + '\n'); return nUntil(l => !l.startsWith('info') && !l.startsWith('id ') && !l.startsWith('option') && !l.startsWith('uciok')); };

// fen -> protocol board bytes (90, row0=black top)
const UI_TYPE = { p: 7, a: 2, b: 3, n: 4, r: 5, c: 6, k: 1 };
function fenBoard(fen) {
  // FEN rows run rank 9 -> 0; protocol array row 0 is the TOP (= rank 9)
  const bd = new Array(90).fill(0);
  let row = 9, col = 0;
  for (const ch of fen.split(/\s+/)[0]) {
    if (ch >= '1' && ch <= '9') col += +ch;
    else if (ch === '/') { row -= 1; col = 0; }
    else { bd[(9 - row) * 9 + col] = ((ch === ch.toLowerCase() ? 1 : 0) << 3) | UI_TYPE[ch.toLowerCase()]; col += 1; }
  }
  return bd;
}

let fails = 0;
const check = (name, cond, extra = '') => {
  if (!cond) { console.log(`FAIL ${name} ${extra}`); fails++; }
};

// ---- 1. perft through wasm ----
W.engineInit();
for (const [d, want] of [[1, 44], [2, 1920], [3, 79666], [4, 3290240]]) {
  const got = W.enginePerft(d) >>> 0;
  check(`perft(${d})`, got === want, `got ${got} want ${want}`);
}

// ---- 2. startpos legal set vs native ----
const loadWire = (moves) => {
  const n = moves.length;
  new Int32Array(W.memory.buffer, W.engineMovesBuf(), n).set(moves);
  return W.engineLoad(n) === 1;
};
const wasmState = () => {
  W.engineState();
  return {
    legal: Array.from(new Int32Array(W.memory.buffer, W.engineLegalPtr(), W.engineLegalCount())),
    board: Array.from(new Int8Array(W.memory.buffer, W.engineBoardPtr(), 90)),
    stm: W.engineStm(),
    eval: W.engineEvalCp(),
  };
};
{
  loadWire([]);
  const a = wasmState();
  const nm = (await ncmd('position startpos\ndmoves')).trim().split(/\s+/).filter(Boolean).map(toWire);
  check('startpos legal set', a.legal.length === 44 && nm.length === 44 && nm.every(m => a.legal.includes(m)), `${a.legal.length} vs ${nm.length}`);
  const fenBd = fenBoard('rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w');
  check('startpos board bytes', JSON.stringify(a.board) === JSON.stringify(fenBd));
  const ne = +await ncmd('position startpos\ndeval');
  check('startpos eval', a.eval === ne, `${a.eval} vs ${ne}`);
}

// ---- 3. random-game differential ----
{
  const rng = (() => { let s = 0x20261001n; return () => { s ^= s >> 12n; s ^= s << 25n; s ^= s >> 27n; return Number((s * 0x2545F4914F6CDD1Dn) & 0xffffffffn) / 0x100000000; }; })();
  let positions = 0;
  for (let g = 0; g < GAMES; g++) {
    const uciMoves = [];
    const wireMoves = [];
    for (let ply = 0; ply < PLIES; ply++) {
      let dm;
      try {
        dm = (await ncmd(`position startpos${uciMoves.length ? ' moves ' + uciMoves.join(' ') : ''}\ndmoves`)).trim();
      } catch (e) {
        console.log('STALL at', g, ply, 'moves:', uciMoves.join(' '));
        throw e;
      }
      const nativeLegal = dm.split(/\s+/).filter(Boolean);
      if (!nativeLegal.length) break;
      check(`game ${g} ply ${ply} load`, loadWire(wireMoves));
      const ws = wasmState();
      const wl = nativeLegal.map(toWire);
      check(`game ${g} ply ${ply} legal set`,
        ws.legal.length === wl.length && wl.every(m => ws.legal.includes(m)),
        `${ws.legal.length} vs ${wl.length}`);
      const fen = await ncmd(`position startpos${uciMoves.length ? ' moves ' + uciMoves.join(' ') : ''}\ndfen`);
      check(`game ${g} ply ${ply} board`, JSON.stringify(ws.board) === JSON.stringify(fenBoard(fen)));
      const ev = +(await ncmd('deval'));
      check(`game ${g} ply ${ply} eval`, ws.eval === ev, `${ws.eval} vs ${ev}`);
      positions++;
      const pick = Math.floor(rng() * nativeLegal.length);
      uciMoves.push(nativeLegal[pick]);
      wireMoves.push(toWire(nativeLegal[pick]));
    }
    if ((g + 1) % 10 === 0) console.log(`  ... ${g + 1}/${GAMES} games, ${positions} positions OK`);
  }
}

// ---- 4. think smoke ----
{
  loadWire([]);
  const mv = W.engineThink(0, 30000);
  check('think returns legal move', mv !== 0 && W.engineState() && Array.from(new Int32Array(W.memory.buffer, W.engineLegalPtr(), W.engineLegalCount())).includes(mv));
  check('think nodes>0', (W.engineNodesLo() >>> 0) + (W.engineNodesHi() >>> 0) * 4294967296 > 0);
}

native.kill();
console.log(fails === 0 ? 'wasm diff: ALL OK' : `wasm diff: ${fails} FAILURES`);
process.exit(fails === 0 ? 0 : 1);
