/* 基准:节点速度 / 固定深度最佳着法回归 / perft 计时。
 *
 *   node bench/bench.mjs nps      各档位在初始局面跑满预算,报节点数与 NPS
 *   node bench/bench.mjs moves    固定深度下的最佳着法与分数(改搜索后可对拍)
 *   node bench/bench.mjs perft    perft 计时(规则改动的回归哨兵)
 *
 * 口径与 webos 里的一致:节点预算为主、墙上时间为兜底,所以同一台机器上可复现。
 */
import { newBoard, replayMoves, searchBest, perft, LEVELS, mkMove, mFrom, mTo, moveToText, RED } from '../src/engine.js';

const mode = process.argv[2] || 'nps';
const fmt = (n) => n.toLocaleString('en-US');

/* 常见开局序列(红先),用来把引擎拉出初始局面的对称区 */
const OPENINGS = {
  中炮: [mkMove(7 * 9 + 7, 7 * 9 + 4), mkMove(2 * 9 + 7, 2 * 9 + 4)],       // 炮二平五 / 炮8平5
  屏风马: [mkMove(9 * 9 + 1, 7 * 9 + 2), mkMove(9 * 9 + 7, 7 * 9 + 6)],     // 马八进七 / 马二进三
};

function boardAfter(moves) {
  const bd = newBoard();
  replayMoves(bd, moves);
  return bd;
}

if (mode === 'nps') {
  console.log('档位        节点预算   实际节点      耗时     NPS        深度  最佳着法');
  for (const lv of LEVELS) {
    const bd = newBoard();
    const t = Date.now();
    const r = searchBest(bd, RED, { depth: lv.depth, nodes: lv.nodes, ms: lv.ms });
    const ms = Math.max(Date.now() - t, 1);
    console.log(
      `${lv.name.padEnd(6)} ${String(fmt(lv.nodes)).padStart(10)} ${String(fmt(r.nodes)).padStart(11)} ` +
      `${String(ms + 'ms').padStart(8)} ${String(fmt(Math.round(r.nodes / ms * 1000))).padStart(9)} ` +
      `${String(r.depth).padStart(6)}  ${moveToText(bd, r.move)}(${r.score})`);
  }
} else if (mode === 'moves') {
  const depth = Number(process.argv[3] || 5);
  console.log(`固定深度 ${depth} 的最佳着法(改搜索/改评估后用来对拍)\n`);
  for (const [name, mv] of [['初始局面', []], ...Object.entries(OPENINGS)]) {
    const bd = boardAfter(mv);
    const r = searchBest(bd, RED, { depth, nodes: 5_000_000, ms: 30000 });
    console.log(`  ${name.padEnd(8)} ${moveToText(bd, r.move).padEnd(8)} 分数 ${String(r.score).padStart(7)}` +
                `  ${fmt(r.nodes)} 节点 / ${r.ms}ms`);
  }
} else if (mode === 'perft') {
  const bd = newBoard();
  for (let d = 1; d <= 4; d++) {
    const t = Date.now();
    const n = perft(bd, RED, d);
    console.log(`  perft(${d}) = ${fmt(n)}  (${Date.now() - t}ms)`);
  }
} else {
  console.error('未知模式:' + mode + '(可用:nps / moves / perft)');
  process.exit(1);
}
