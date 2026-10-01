#!/usr/bin/env node
// Paired self-play match between two UCI engines (fixed node budget per
// move, colors alternated). Reports W-L-D and a rough Elo difference.
//
// Usage: node tools/match.mjs <engineA> <engineB> [games=100] [nodes=50000] [movetime=0]
//   movetime > 0 uses `go movetime` instead of `go nodes`.
import { spawn } from 'node:child_process';
import readline from 'node:readline';

const [engA, engB, gamesArg, nodesArg, mtArg] = process.argv.slice(2);
const games = +(gamesArg || 100);
const nodes = +(nodesArg || 50000);
const movetime = +(mtArg || 0);
if (!engA || !engB) {
  console.error('usage: node tools/match.mjs <engineA> <engineB> [games] [nodes] [movetime]');
  process.exit(1);
}

class Eng {
  constructor(path) {
    this.p = spawn(path, [], { stdio: ['pipe', 'pipe', 'ignore'] });
    this.rl = readline.createInterface({ input: this.p.stdout, crlfDelay: Infinity });
    this.queue = [];
    this.waiters = [];
    this.rl.on('line', l => {
      if (this.waiters.length) this.waiters.shift()(l);
      else this.queue.push(l);
    });
  }
  cmd(s) { this.p.stdin.write(s + '\n'); }
  async until(pred) {
    const test = typeof pred === 'string' ? l => l.startsWith(pred) : pred;
    while (true) {
      const l = this.queue.length ? this.queue.shift() : await new Promise(r => this.waiters.push(r));
      if (test(l)) return l;
    }
  }
  async bestmove(moves) {
    this.cmd(moves.length ? `position startpos moves ${moves.join(' ')}` : 'position startpos');
    this.cmd(movetime > 0 ? `go movetime ${movetime}` : `go nodes ${nodes}`);
    const l = await this.until('bestmove');
    return l.split(' ')[1];
  }
  kill() { try { this.p.kill(); } catch {} }
}

const A = new Eng(engA);
const B = new Eng(engB);
A.cmd('uci'); B.cmd('uci');
await A.until('uciok');
await B.until('uciok');
/* 测对要的是纯搜索强度:关掉开局谱的随机跟谱 */
A.cmd('setoption name OwnBook value false');
B.cmd('setoption name OwnBook value false');

let aWin = 0, bWin = 0, draw = 0;
const t0 = Date.now();
for (let g = 0; g < games; g++) {
  // alternate colors; fixed opening diversity via a short random prefix
  const aIsRed = g % 2 === 0;
  const moves = [];
  // tiny deterministic opening prefix from game index (2 plies, varied)
  const openers = [['h2e2', 'b9c7'], ['b0c2', 'h9g7'], ['b2e2', 'h9g7'], ['g0e2', 'h9g7']];
  moves.push(...openers[g % openers.length]);
  let result = null;
  for (let ply = 0; ply < 300; ply++) {
    const mover = moves.length % 2 === 0; // true = red
    const eng = (mover === aIsRed) ? A : B;
    const mv = await eng.bestmove(moves);
    if (!mv || mv === '(none)') {
      // mover has no move: if in check -> mate, else 困毙 — both lose
      result = mover === aIsRed ? 'b' : 'a';
      break;
    }
    moves.push(mv);
    // repetition / 60-move adjudication via ply cap on no-capture… keep simple:
    // long games are draws
    if (moves.length >= 240) { result = 'd'; break; }
  }
  if (result === null) result = 'd';
  if (result === 'a') aWin++;
  else if (result === 'b') bWin++;
  else draw++;
  if ((g + 1) % 20 === 0) console.log(`  ${g + 1}/${games}: A ${aWin} - B ${bWin} - D ${draw}`, `${((Date.now() - t0) / 1000).toFixed(0)}s`);
}
A.kill(); B.kill();
const n = aWin + bWin + draw;
const score = (aWin + draw / 2) / n;
const elo = -400 * Math.log10(1 / Math.max(Math.min(score, 0.99), 0.01) - 1);
console.log(`FINAL: A(${engA.split('/').pop()}) ${aWin} - ${draw} - ${bWin} B(${engB.split('/').pop()})  score ${(score * 100).toFixed(1)}%  ~${elo.toFixed(0)} Elo (${n} games, ${((Date.now() - t0) / 1000).toFixed(0)}s)`);
