#!/usr/bin/env node
// Static-eval labeling: relabel FEN streams with a reference engine's
// static NNUE eval (UCI `eval` — zero search) into .aex2 records.
//
// Record layout (96 B, little-endian):
//   [0..89]  board[90]  mailbox byte = color*7+type (0 red / 1 black), 0xFF empty
//   [90]     stm
//   [91]     reserved 0
//   [92..93] score i16 (engine units, STM POV, clamped ±30000)
//   [94]     result u8 (1 = draw sentinel; score-only fit ignores it)
//   [95]     padding 0
//
// Each worker owns one engine process and one output shard; shards are
// merged at the end. A wedged/dead engine requeues its chunk.
//
// Usage: node tools/teacher_label.mjs <out.aex2> <fen files...> [--pika PATH] [--workers N]
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import readline from 'node:readline';

const args = process.argv.slice(2);
const outPath = args.shift();
const files = [];
let pika = '/home/a/cchess/Pikafish.2026-09-06/Pikafish-Linux-x86-64-universal';
let workers = 14;
while (args.length) {
  const a = args.shift();
  if (a === '--pika') pika = args.shift();
  else if (a === '--workers') workers = +args.shift();
  else files.push(a);
}
if (!outPath || files.length === 0) {
  console.error('usage: node tools/teacher_label.mjs <out.aex2> <fen files...> [--pika PATH] [--workers N]');
  process.exit(1);
}

// ---- FEN -> 90 mailbox bytes (engine encoding: letters "pabnrck", upper = red)
const TYPE = { p: 0, a: 1, b: 2, n: 3, r: 4, c: 5, k: 6 };
function fenToRecord(fen, score) {
  const rec = Buffer.alloc(96, 0);
  rec.fill(0xFF, 0, 90);
  const fields = fen.trim().split(/\s+/);
  let row = 9, col = 0;
  for (const ch of fields[0]) {
    if (ch >= '1' && ch <= '9') col += +ch;
    else if (ch === '/') { row -= 1; col = 0; }
    else {
      const lower = ch.toLowerCase();
      const t = TYPE[lower];
      if (t !== undefined && row >= 0 && col <= 8) rec[row * 9 + col] = (ch === lower ? 1 : 0) * 7 + t;
      col += 1;
    }
  }
  rec[90] = fields[1] === 'b' ? 1 : 0;
  rec.writeInt16LE(Math.max(-30000, Math.min(30000, score)), 92);
  rec[94] = 1;
  return rec;
}

// ---- load FENs
let fens = [];
for (const f of files) {
  const lines = fs.readFileSync(f, 'utf8').split('\n');
  for (let i = 0; i < lines.length; i++)
    if (lines[i].includes('/')) fens.push(lines[i]);
}
console.log(`loaded ${fens.length} fens from ${files.length} files`);

// ---- queue
const CHUNK = 512;
let queue = [];
for (let i = 0; i < fens.length; i += CHUNK) queue.push(fens.slice(i, i + CHUNK));
let done = 0, dropped = 0;

async function startEngine() {
  const p = spawn(pika, [], { stdio: ['pipe', 'pipe', 'ignore'] });
  const rl = readline.createInterface({ input: p.stdout, crlfDelay: Infinity });
  await new Promise((res, rej) => {
    const timer = setTimeout(() => rej(new Error('uciok timeout')), 30000);
    p.stdin.write('uci\n');
    rl.on('line', l => { if (l.startsWith('uciok')) { clearTimeout(timer); res(); } });
    p.once('exit', () => { clearTimeout(timer); rej(new Error('died at handshake')); });
  });
  return { p, rl };
}

async function labelChunk(eng, chunk) {
  const { p, rl } = eng;
  const matches = [];
  let settled = false;
  await new Promise(res => {
    const onLine = l => {
      const m = l.match(/NNUE evaluation\s+([+-]?\d+) \(side to move, internal units\)/);
      if (m) {
        matches.push(+m[1]);
        if (matches.length >= chunk.length) cleanup(true);
      }
    };
    const onExit = () => cleanup(false);
    const timer = setTimeout(() => cleanup(false), 120000);
    function cleanup(ok) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      rl.removeListener('line', onLine);
      p.removeListener('exit', onExit);
      res(ok);
    }
    rl.on('line', onLine);
    p.once('exit', onExit);
    p.stdin.write(chunk.map(f => `position fen ${f}\neval\n`).join(''));
  });
  return settled && matches.length === chunk.length ? matches : null;
}

// Label a chunk, isolating poison FENs (engine-killing positions) by binary
// splitting on failure down to singletons, which are dropped. The engine
// holder keeps one process alive across chunks; it is restarted only on death.
async function labelRobust(holder, chunk, sink) {
  const restart = async () => {
    if (holder.eng) { try { holder.eng.p.kill(); } catch {} holder.eng = null; }
    for (let t = 0; t < 3; t++) {
      try { holder.eng = await startEngine(); return true; } catch {}
      await new Promise(r => setTimeout(r, 500));
    }
    return false;
  };
  if (!holder.eng && !(await restart())) return false;
  const attempt = async c => {
    if (c.length === 0) return true;
    if (c.length === 1) {
      // singleton: try once, drop on failure
      const one = await labelChunk(holder.eng, c);
      if (one === null) {
        dropped += 1;
        if (!(await restart())) return false;
      } else {
        await sink(c, one);
      }
      return true;
    }
    const m = await labelChunk(holder.eng, c);
    if (m !== null) { await sink(c, m); return true; }
    const mid = c.length >> 1;
    if (!(await restart())) return false;
    if (!(await attempt(c.slice(0, mid)))) return false;
    return attempt(c.slice(mid));
  };
  return attempt(chunk);
}

async function worker(id) {
  const shardPath = `${outPath}.w${String(id).padStart(2, '0')}`;
  const ws = fs.createWriteStream(shardPath);
  const writeChunk = buf => new Promise(res => (ws.write(buf) ? res() : ws.once('drain', res)));
  const holder = { eng: null };
  const sink = async (chunk, matches) => {
    const batch = new Array(chunk.length);
    for (let i = 0; i < chunk.length; i++) batch[i] = fenToRecord(chunk[i], matches[i]);
    await writeChunk(Buffer.concat(batch));
    done += chunk.length;
  };
  while (queue.length > 0) {
    const chunk = queue.shift();
    const ok = await labelRobust(holder, chunk, sink);
    if (!ok) {
      queue.unshift(chunk);
      await new Promise(r => setTimeout(r, 1000));
    }
    if (done % 1000000 < CHUNK) console.log(`  labeled ${done} (queue ${queue.length}, dropped ${dropped})`);
  }
  if (holder.eng) { try { holder.eng.p.kill(); } catch {} }
  await new Promise(res => ws.end(res));
}

const t0 = Date.now();
await Promise.all(Array.from({ length: workers }, (_, i) => worker(i)));

// ---- merge shards
const out = fs.openSync(outPath, 'w');
let total = 0;
for (let i = 0; i < workers; i++) {
  const shard = `${outPath}.w${String(i).padStart(2, '0')}`;
  const buf = fs.readFileSync(shard);
  fs.writeFileSync(out, buf);
  total += buf.length / 96;
  fs.unlinkSync(shard);
}
fs.closeSync(out);
const dt = (Date.now() - t0) / 1000;
console.log(`labeled ${done}, dropped ${dropped}, wrote ${total} records -> ${outPath} (${dt.toFixed(1)}s, ${(done / dt).toFixed(0)}/s)`);
