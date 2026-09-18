/* 中国象棋引擎测试:规则用例 + perft + 记谱 + 搜索行为 + 随机对局模糊测试。
 *
 * 运行:node test/engine-test.mjs          全部
 *      node test/engine-test.mjs perft    只跑指定节(--list 看全部)
 *
 * 摆棋注意:双方将帅必须在盘上且**不能对脸** —— 缺帅或对脸会让整局
 * 判成非法(genLegal 返回空),用例就会莫名其妙地失败。这是踩过的坑。
 */
import {
  RED, BLACK, K, A, B, N, R, C, P, MATE,
  newBoard, syncPosition, genLegal, hasMove, inCheck, kingsFacing,
  make, unmake, mkMove, mFrom, mTo, moveToText, searchBest, perft, evaluate,
} from '../src/engine.js';

/* ---------- 断言框架 ---------- */
const sections = [];
const section = (name, fn) => sections.push({ name, fn });
let pass = 0, fail = 0;
const ok = (cond, msg, extra) => {
  if (cond) pass++;
  else { fail++; console.log(`  ✗ ${msg}${extra ? '  — ' + extra : ''}`); }
};
const eq = (got, want, msg) => ok(got === want, msg, `得到 ${got},期望 ${want}`);

/* ---------- 摆棋助手 ----------
 * 10 行 × 9 列,大写 = 红,小写 = 黑,'.' = 空
 * K 将帅 / A 士 / B 象 / N 马 / R 车 / C 炮 / P 兵卒 */
const CH = { K, A, B, N, R, C, P };
function boardFrom(rows) {
  const bd = new Int8Array(90);
  rows.forEach((row, r) => {
    for (let c = 0; c < 9; c++) {
      const ch = row[c];
      if (!ch || ch === '.') continue;
      const isRed = ch === ch.toUpperCase();
      bd[r * 9 + c] = CH[ch.toUpperCase()] | (isRed ? 0 : 8);
    }
  });
  syncPosition(bd);
  return bd;
}
const sq = (r, c) => r * 9 + c;
const has = (mvs, from, to) => mvs.some((m) => mFrom(m) === from && mTo(m) === to);

/* 底线:黑将 (0,3)、红帅 (9,4) —— 故意错开纵线,避免对脸 */
const BASE = ['...k.....', '.........', '.........', '.........', '.........',
              '.........', '.........', '.........', '.........', '....K....'];

/* ==================== 1. 初始局面 ==================== */
section('init', () => {
  const bd = newBoard();
  let red = 0, black = 0;
  for (let i = 0; i < 90; i++) { if (bd[i]) { if (bd[i] >> 3) black++; else red++; } }
  eq(red, 16, '初始局面红方 16 子');
  eq(black, 16, '初始局面黑方 16 子');
  eq(genLegal(bd, RED).length, 44, '初始局面红方 44 步合法着法');
  eq(evaluate(bd), 0, '初始局面评估对称(红黑抵消)');
  ok(!inCheck(bd, RED) && !inCheck(bd, BLACK), '初始局面双方均未被将');
});

/* ==================== 2. 走子规则 ==================== */
section('rules', () => {
  /* 马腿 */
  {
    const rows = [...BASE]; rows[5] = '....N....';
    const free = boardFrom(rows);
    const blocked = boardFrom(rows.map((r, i) => (i === 4 ? '....p....' : r)));
    ok(has(genLegal(free, RED), sq(5, 4), sq(3, 3)), '马可走 (5,4)→(3,3)');
    ok(has(genLegal(free, RED), sq(5, 4), sq(3, 5)), '马可走 (5,4)→(3,5)');
    ok(!has(genLegal(blocked, RED), sq(5, 4), sq(3, 3)), '蹩马腿:(4,4) 有子时不能走 (3,3)');
    ok(!has(genLegal(blocked, RED), sq(5, 4), sq(3, 5)), '蹩马腿:(4,4) 有子时不能走 (3,5)');
    ok(has(genLegal(blocked, RED), sq(5, 4), sq(7, 3)), '蹩马腿只影响对应方向,(7,3) 仍可走');
  }
  /* 象眼 + 象不过河 */
  {
    const rows = [...BASE]; rows[9] = '..B.K....';
    const free = boardFrom(rows);
    ok(has(genLegal(free, RED), sq(9, 2), sq(7, 0)), '象可走 (9,2)→(7,0)');
    ok(has(genLegal(free, RED), sq(9, 2), sq(7, 4)), '象可走 (9,2)→(7,4)');
    const eye = boardFrom(rows.map((r, i) => (i === 8 ? '.P..K....' : r)));
    ok(!has(genLegal(eye, RED), sq(9, 2), sq(7, 0)), '塞象眼:(8,1) 有子时不能走 (7,0)');
    ok(has(genLegal(eye, RED), sq(9, 2), sq(7, 4)), '塞象眼只影响对应方向,(7,4) 仍可走');

    const rows2 = [...BASE]; rows2[5] = '..B......';
    const river = boardFrom(rows2);
    ok(has(genLegal(river, RED), sq(5, 2), sq(7, 0)), '象可退回 (5,2)→(7,0)');
    ok(!has(genLegal(river, RED), sq(5, 2), sq(3, 0)), '象不过河:不能走 (5,2)→(3,0)');
    ok(!has(genLegal(river, RED), sq(5, 2), sq(3, 4)), '象不过河:不能走 (5,2)→(3,4)');
  }
  /* 炮:直线走子,吃子必须隔一个 */
  {
    const rows = [...BASE];
    rows[7] = '.C.......';               // 红炮 (7,1)
    rows[5] = '.p.......';               // 炮架 (5,1)
    rows[2] = '.r.......';               // 隔山目标 (2,1)
    const mvs = genLegal(boardFrom(rows), RED);
    ok(has(mvs, sq(7, 1), sq(6, 1)), '炮可直线走到空格 (6,1)');
    ok(!has(mvs, sq(7, 1), sq(5, 1)), '炮不能吃紧邻的子(要翻山)');
    ok(!has(mvs, sq(7, 1), sq(4, 1)), '炮不能走到炮架之后的空格 (4,1)');
    ok(has(mvs, sq(7, 1), sq(2, 1)), '炮隔一子可吃 (2,1) 的黑车');
  }
  /* 士 / 将:限九宫 */
  {
    const rows = [...BASE]; rows[8] = '....A....';
    const mvs = genLegal(boardFrom(rows), RED).filter((m) => mFrom(m) === sq(8, 4));
    eq(mvs.length, 4, '九宫中心的士有 4 个落点');
    ok(mvs.every((m) => {
      const r = (mTo(m) / 9) | 0, c = mTo(m) % 9;
      return r >= 7 && r <= 9 && c >= 3 && c <= 5;
    }), '士的落点全在九宫内');

    /* 注意 BASE 的黑将在 (0,3):帅走 (9,3) 会与之同纵线对脸,所以只剩 2 步 */
    const km = genLegal(boardFrom(BASE), RED).filter((m) => mFrom(m) === sq(9, 4));
    eq(km.length, 2, '底线中位的将只有 2 个落点(纵线 3 会与黑将对脸)');
    ok(km.every((m) => (mTo(m) / 9 | 0) >= 7 && (mTo(m) % 9) >= 3 && (mTo(m) % 9) <= 5),
      '将的落点全在九宫内');
  }
  /* 兵:只进不退,过河后可横走 */
  {
    const rows = [...BASE]; rows[5] = '....P....';
    const before = boardFrom(rows);
    ok(has(genLegal(before, RED), sq(5, 4), sq(4, 4)), '未过河的兵可直进');
    ok(!has(genLegal(before, RED), sq(5, 4), sq(5, 3)), '未过河的兵不能横走');

    const rows2 = [...BASE]; rows2[3] = '....P....';
    const after = boardFrom(rows2);
    ok(has(genLegal(after, RED), sq(3, 4), sq(2, 4)), '过河兵可直进');
    ok(has(genLegal(after, RED), sq(3, 4), sq(3, 3)), '过河兵可横走');
    ok(!has(genLegal(after, RED), sq(3, 4), sq(4, 4)), '兵不能后退');
  }
  /* 将帅对脸 */
  {
    const face = ['....k....', '.........', '.........', '.........', '.........',
                  '.........', '....N....', '.........', '.........', '....K....'];
    const bd = boardFrom(face);
    ok(!kingsFacing(bd), '同一纵线中间有子:不算对脸');
    const moved = boardFrom(face.map((r, i) => (i === 6 ? '.........' : r)));
    ok(kingsFacing(moved), '同一纵线中间无子:对脸(非法局面)');
    /* 红马 (6,4) 正卡在两个将之间:它一离开纵线就对脸,所以只有帅能平移 */
    const mvs = genLegal(bd, RED);
    eq(mvs.length, 3, '对脸威胁下红方只剩帅的 3 步平移');
    ok(mvs.every((m) => mFrom(m) === sq(9, 4)), '红马一步都动不了(离开纵线即对脸)');
  }
});

/* ==================== 3. 终局判定 ==================== */
section('terminal', () => {
  /* 黑将 (0,4) 单子:红车 (0,0) 照将,双马分别看住 (0,5) 与 (1,4),(0,3) 在车的射线上 */
  const MATEPOS = ['R...k....', '.........', '......N..', '.....N...', '.........',
                   '.........', '.........', '.........', '.........', '...K.....'];
  const bd = boardFrom(MATEPOS);
  ok(inCheck(bd, BLACK), '该局面黑方被将军');
  eq(genLegal(bd, BLACK).length, 0, '该局面黑方无合法着法 = 将死');
  ok(!hasMove(bd, BLACK), 'hasMove 与 genLegal 一致');
  const res = searchBest(bd, BLACK, { depth: 2, nodes: 50000, ms: 1000 });
  eq(res.move, 0, '无棋可走时 searchBest 返回 0');
  ok(res.mate, '无棋可走时标记为杀棋');
});

/* ==================== 4. 中文记谱 ==================== */
section('notation', () => {
  const bd = newBoard();
  eq(moveToText(bd, mkMove(sq(7, 7), sq(7, 4))), '炮二平五', '炮二平五');
  eq(moveToText(bd, mkMove(sq(9, 1), sq(7, 2))), '马八进七', '马八进七');
  eq(moveToText(bd, mkMove(sq(6, 2), sq(5, 2))), '兵七进一', '兵七进一');
  eq(moveToText(bd, mkMove(sq(2, 7), sq(2, 4))), '炮8平5', '黑方用阿拉伯数字:炮8平5');
  eq(moveToText(bd, mkMove(sq(9, 7), sq(7, 6))), '马二进三', '马二进三(斜线子记目标线号)');

  /* 同纵线两个同类子:用前/后消歧(红方「前」= 行号更小 = 更靠近对方) */
  const rows = [...BASE]; rows[2] = '....R....'; rows[5] = '....R....';
  const two = boardFrom(rows);
  eq(moveToText(two, mkMove(sq(2, 4), sq(1, 4))), '前车进一', '前车进一');
  eq(moveToText(two, mkMove(sq(5, 4), sq(4, 4))), '后车进一', '后车进一');
});

/* ==================== 5. 搜索行为 ==================== */
section('search', () => {
  /* 一步杀:红车走到 (1,4) 即成杀(另一个车在同一行看住它,黑将三面无路) */
  {
    const M1 = ['....k....', 'R....R...', '..N...N..', '.........', '.........',
                '.........', '.........', '.........', '.........', '...K.....'];
    const bd = boardFrom(M1);
    const res = searchBest(bd, RED, { depth: 3, nodes: 300000, ms: 3000 });
    ok(res.score > MATE - 200, '一步杀:分数是杀棋分', `score=${res.score}`);
    const cap = make(bd, res.move);
    eq(genLegal(bd, BLACK).length, 0, '一步杀:走完之后黑方确实无棋可走');
    unmake(bd, res.move, cap);
  }
  /* 白送的车必须吃 */
  {
    const GIFT = ['.........', '....k....', '.........', '.........', '.........',
                  'R.......r', '.........', '.........', '.........', '...K.....'];
    const bd = boardFrom(GIFT);
    const res = searchBest(bd, RED, { depth: 4, nodes: 300000, ms: 3000 });
    eq(res.move, mkMove(sq(5, 0), sq(5, 8)), '能吃白送的车:车(5,0)→(5,8)');
    ok(res.score > 400, '吃车后优势明显', `score=${res.score}`);
  }
  /* 被将时只能应将 */
  {
    const rows = [...BASE];
    rows[0] = '....k....';               // 黑将 (0,4)
    rows[5] = '....R....';               // 红车 (5,4) 纵线照将
    const bd = boardFrom(rows);
    ok(inCheck(bd, BLACK), '黑方被纵线照将');
    const mvs = genLegal(bd, BLACK);
    eq(mvs.length, 2, '黑方只有 2 种应将手段(左右平移)');
    for (const mv of mvs) {
      const cap = make(bd, mv);
      ok(!inCheck(bd, BLACK), '应将之后不能再被将');
      unmake(bd, mv, cap);
    }
  }
  /* 迭代加深:逐层回调、统计非空 */
  {
    const bd = newBoard();
    const seen = [];
    const res = searchBest(bd, RED, { depth: 4, nodes: 400000, ms: 5000, onProgress: (i) => seen.push(i.depth) });
    ok(seen.length >= 2, '迭代加深逐层回调', `回调层数 ${seen.join(',')}`);
    ok(res.nodes > 0, '返回节点数', `${res.nodes} 节点 / ${res.ms}ms / ${res.depth} 层`);
    ok(res.move !== 0, '初始局面有最佳着法');
  }
});

/* ==================== 6. perft(规则金标准) ==================== */
section('perft', () => {
  const bd = newBoard();
  const expect = [44, 1920, 79666, 3290240];
  for (let d = 1; d <= expect.length; d++) {
    const t = Date.now();
    const got = perft(bd, RED, d);
    eq(got, expect[d - 1], `perft(${d})`);
    console.log(`    perft(${d}) = ${got}  (${Date.now() - t}ms)`);
  }
});

/* ==================== 7. 随机对局模糊测试 ==================== */
section('fuzz', () => {
  let seed = 20260918;
  const rnd = () => {
    seed = (Math.imul(seed, 1103515245) + 12345) & 0x7fffffff;
    return seed / 0x7fffffff;
  };
  let games = 0, plies = 0, mates = 0, bad = 0;
  for (let g = 0; g < 60; g++) {
    const bd = newBoard();
    let side = RED;
    for (let ply = 0; ply < 240; ply++) {
      const mvs = genLegal(bd, side);
      if (!mvs.length) { if (inCheck(bd, side)) mates++; break; }
      const mv = mvs[(rnd() * mvs.length) | 0];
      const cap = make(bd, mv);
      if (inCheck(bd, side) || kingsFacing(bd)) bad++;   // 合法着法不该走出送将/对脸
      plies++;
      side ^= 1;
    }
    let kr = 0, kb = 0;                                   // 双方将帅始终在盘上
    for (let i = 0; i < 90; i++) {
      const p = bd[i];
      if (p && (p & 7) === K) { if (p >> 3) kb++; else kr++; }
    }
    if (kr !== 1 || kb !== 1) bad++;
    games++;
  }
  eq(bad, 0, '随机对局中不出现非法局面(送将 / 对脸 / 丢帅)');
  console.log(`    ${games} 局 / ${plies} 步 / 其中 ${mates} 局走到将死`);
});

/* ---------- 执行 ---------- */
const args = process.argv.slice(2);
if (args.includes('--list')) {
  console.log('可用小节:' + sections.map((s) => ' ' + s.name).join(','));
  process.exit(0);
}
const only = args.filter((a) => !a.startsWith('--'));
const run = only.length ? sections.filter((s) => only.includes(s.name)) : sections;

for (const s of run) {
  const t = Date.now(), p0 = pass, f0 = fail;
  console.log(`\n[${s.name}]`);
  s.fn();
  console.log(`  ${fail === f0 ? '✓' : '✗'} ${pass - p0} 项 · ${Date.now() - t}ms`);
}
console.log(`\n${fail === 0 ? '✓ 全部通过' : '✗ 有失败'}  ${pass} 项通过 / ${fail} 项失败`);
process.exit(fail ? 1 : 0);
