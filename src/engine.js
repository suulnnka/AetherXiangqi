/* ============================================================
 * AetherXiangqi —— 中国象棋引擎(规则 + 评估 + 搜索)
 *
 * 棋盘:90 格(10 行 × 9 列),idx = 行×9 + 列。
 *   行 0 是黑方底线(上),行 9 是红方底线(下),红先黑后。
 * 棋子:低 3 位是类型,bit3 是颜色(0 红 / 1 黑),0 是空格。
 * 走法:from<<7 | to(from/to ∈ 0..89,共 14 位)。
 *
 * 规则:车/炮直线(炮需翻山)、马蹩腿、象塞眼且不过河、士将限九宫、
 *      兵只进不退(过河后可横走)、将帅对脸算非法(等价于被将)。
 *
 * 搜索:negamax + alpha-beta + 迭代加深 + 置换表(Zobrist 双 32 位校验)
 *      + MVV-LVA / killer / history 排序 + 吃子静态搜索 + 将军延伸。
 * 评估:子力 + 位置表(PST,车/马/炮/兵)+ tempo。
 *      参数都是手调的初值,没有自对弈拟合 —— 见 docs/ROADMAP.md。
 *
 * 对外入口:
 *   newBoard() / replayMoves() / genLegal() / inCheck() / hasMove()
 *   moveToText()                 —— UI 侧规则、记谱
 *   searchBest(bd, side, opt)    —— Worker 侧搜索
 *   LEVELS                       —— 难度档(节点预算为主、墙上时间为辅)
 *
 * 本文件不碰 DOM、不 import 任何库 —— 浏览器、Worker、Node 通用。
 * ============================================================ */

export const RED = 0, BLACK = 1;

/* 棋子类型(低 3 位):将/帅、士、象、马、车、炮、兵 */
export const K = 1, A = 2, B = 3, N = 4, R = 5, C = 6, P = 7;
export const EMPTY = 0;

/** 取值:低 3 位类型 / 第 3 位颜色 */
export const typeOf = (p) => p & 7;
export const sideOf = (p) => (p >> 3) & 1;
export const mkPc = (side, t) => t | (side << 3);

export const mFrom = (mv) => mv >> 7;
export const mTo = (mv) => mv & 127;
/** 走法编码:UI 与 Worker 传的都是这个,别再造第二套 */
export const mkMove = (from, to) => (from << 7) | to;

/* ==================== 数据表 ==================== */

/* 子力价值(百分兵制)。帅给 6000:比任何子都贵,但远小于杀棋分,
 * 免得搜索引擎为了吃士而丢车。 */
const VAL = [0, 6000, 200, 200, 400, 900, 450, 100];

/* 位置表(红方视角,idx = 行×9+列,行 0 = 对方底线)。
 * 黑方用镜像行(9-行)查同一张表。数值是手调初值,不是拟合结果。 */
const PST_P = [
  // 兵:未过河几乎不值钱,过河后越深入越贵,中路最贵
  80, 80, 80, 90, 90, 90, 80, 80, 80, // 行 0(对方底线)
  70, 75, 80, 85, 90, 85, 80, 75, 70, // 行 1
  50, 55, 62, 70, 75, 70, 62, 55, 50, // 行 2
  30, 35, 42, 55, 60, 55, 42, 35, 30, // 行 3
  20, 22, 28, 40, 45, 40, 28, 22, 20, // 行 4(刚过河)
  0, 0, 0, 6, 10, 6, 0, 0, 0,         // 行 5(河界前)
  0, 0, 0, 0, 0, 0, 0, 0, 0,          // 行 6(兵的起点)
  0, 0, 0, 0, 0, 0, 0, 0, 0,          // 行 7~9:兵到不了,留 0
  0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0, 0, 0,
];
const PST_N = [
  // 马:中心与过河加分,原位(底线)扣分鼓励出子
  4, 8, 16, 24, 20, 24, 16, 8, 4,
  4, 12, 20, 28, 24, 28, 20, 12, 4,
  12, 20, 28, 32, 28, 32, 28, 20, 12,
  12, 24, 32, 36, 32, 36, 32, 24, 12,
  8, 20, 28, 34, 30, 34, 28, 20, 8,
  4, 16, 24, 28, 26, 28, 24, 16, 4,
  0, 8, 16, 20, 20, 20, 16, 8, 0,
  -4, 0, 8, 12, 12, 12, 8, 0, -4,
  -8, -8, 0, 4, 4, 4, 0, -8, -8,
  -12, -12, -8, -4, 0, -4, -8, -12, -12,
];
const PST_R = [
  // 车:压制对方阵地、占横线
  10, 14, 14, 16, 16, 16, 14, 14, 10,
  12, 16, 16, 20, 20, 20, 16, 16, 12,
  10, 14, 14, 16, 18, 16, 14, 14, 10,
  8, 12, 12, 14, 16, 14, 12, 12, 8,
  6, 10, 10, 12, 14, 12, 10, 10, 6,
  4, 8, 8, 10, 12, 10, 8, 8, 4,
  2, 6, 6, 8, 10, 8, 6, 6, 2,
  0, 2, 4, 6, 8, 6, 4, 2, 0,
  0, 0, 2, 4, 6, 4, 2, 0, 0,
  -2, 0, 0, 2, 4, 2, 0, 0, -2,
];
const PST_C = [
  // 炮:中炮与河界一线最有威慑
  0, 0, 2, 6, 10, 6, 2, 0, 0,
  0, 2, 4, 8, 12, 8, 4, 2, 0,
  0, 2, 4, 8, 12, 8, 4, 2, 0,
  0, 2, 6, 10, 14, 10, 6, 2, 0,
  2, 4, 8, 12, 16, 12, 8, 4, 2,
  2, 6, 10, 14, 18, 14, 10, 6, 2,
  0, 2, 6, 8, 10, 8, 6, 2, 0,
  0, 0, 2, 4, 6, 4, 2, 0, 0,
  0, 0, 0, 2, 4, 2, 0, 0, 0,
  -2, 0, 0, 0, 2, 0, 0, 0, -2,
];

const PSTS = [null, null, null, null, PST_N, PST_R, PST_C, PST_P];

/* 方向表:正交 4 向 / 对角 4 向 */
const DR4 = [1, -1, 0, 0], DC4 = [0, 0, 1, -1];
const DG4 = [[-1, -1], [-1, 1], [1, -1], [1, 1]];
/* 马:8 个落点 + 对应的马腿(相对马的偏移) */
const HN8 = [[-2, -1, -1, 0], [-2, 1, -1, 0], [2, -1, 1, 0], [2, 1, 1, 0],
             [-1, -2, 0, -1], [1, -2, 0, -1], [-1, 2, 0, 1], [1, 2, 0, 1]];
/* 象:4 个落点 + 对应的象眼 */
const EL4 = [[-2, -2, -1, -1], [-2, 2, -1, 1], [2, -2, 1, -1], [2, 2, 1, 1]];

/* 九宫(红:行 7~9 / 黑:行 0~2,列 3~5)。
 * 行必须两头都卡死 —— 少了上界的话,士/将能"走出棋盘"
 * (写到 bd[9x] 越界被静默丢弃,子直接消失,perft 会多出 3 步)。 */
const inPalace = (side, r, c) =>
  c >= 3 && c <= 5 && (side === RED ? r >= 7 && r <= 9 : r >= 0 && r <= 2);
/** 己方半场(象不能过河):红 r>=5,黑 r<=4 */
const ownHalf = (side, r) => (side === RED ? r >= 5 : r <= 4);

/* ==================== 局面状态 ==================== */

export const MATE = 30000;
const INF = 1 << 28;
const MAXPLY = 96;
const MOVE_CAP = 128;                       // 单节点着法上限(实测最多 ~60)

/* 着法缓冲:按层数分槽,免得每个节点都 new 一个数组 */
const MB = new Int32Array(MOVE_CAP * (MAXPLY + 8));
const MS = new Int32Array(MOVE_CAP * (MAXPLY + 8));   // 与 MB 平行的排序分
const KILLER = new Int32Array(MAXPLY * 2);
const HIST = new Int32Array(90 * 128);      // history:走法 → 累计加分

/* 帅/将位置与 Zobrist 键:随 make/unmake 增量维护,
 * 换局面(新对局/摆棋)时必须 syncPosition() 重建 —— 否则查将位置会读到上一局的。 */
const KSQ = new Int32Array(2);
let HK1 = 0, HK2 = 0;

const Z1 = new Int32Array(16 * 90), Z2 = new Int32Array(16 * 90);
{
  let s = 0x2f6e2b1;
  const rnd = () => {
    s = (s + 0x6d2b79f5) | 0;
    let t = Math.imul(s ^ (s >>> 15), 1 | s);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return (t ^ (t >>> 14)) | 0;
  };
  for (let i = 0; i < Z1.length; i++) { Z1[i] = rnd(); Z2[i] = rnd(); }
}
const ZS1 = rndSideKey(0x9e3779b9), ZS2 = rndSideKey(0x85ebca6b);
function rndSideKey(seed) {
  let s = seed;
  const rnd = () => {
    s = (s + 0x6d2b79f5) | 0;
    let t = Math.imul(s ^ (s >>> 15), 1 | s);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return (t ^ (t >>> 14)) | 0;
  };
  for (let i = 0; i < 8; i++) rnd();
  return rnd();
}

/* ==================== 局面构建 ==================== */

/** 初始局面:黑在行 0,红在行 9(红先) */
export function newBoard() {
  const bd = new Int8Array(90);
  const back = [R, N, B, A, K, A, B, N, R];
  for (let c = 0; c < 9; c++) {
    bd[c] = mkPc(BLACK, back[c]);              // 行 0 黑方底线
    bd[9 * 9 + c] = mkPc(RED, back[c]);        // 行 9 红方底线
  }
  bd[2 * 9 + 1] = mkPc(BLACK, C); bd[2 * 9 + 7] = mkPc(BLACK, C);
  bd[7 * 9 + 1] = mkPc(RED, C);   bd[7 * 9 + 7] = mkPc(RED, C);
  for (let c = 0; c < 9; c += 2) {
    bd[3 * 9 + c] = mkPc(BLACK, P);            // 行 3 黑卒
    bd[6 * 9 + c] = mkPc(RED, P);              // 行 6 红兵
  }
  syncPosition(bd);
  return bd;
}

/** 重算派生状态(帅位 + Zobrist);摆棋/改盘后必须调用 */
export function syncPosition(bd) {
  HK1 = 0; HK2 = 0;
  KSQ[0] = -1; KSQ[1] = -1;
  for (let i = 0; i < 90; i++) {
    const p = bd[i];
    if (!p) continue;
    const z = (p - 1) * 90 + i;
    HK1 ^= Z1[z]; HK2 ^= Z2[z];
    if ((p & 7) === K) KSQ[p >> 3] = i;
  }
}

/** 从初始局面按走法序列重演(Worker 用它还原 UI 的棋盘) */
export function replayMoves(bd, moves, side = RED) {
  let s = side;
  for (let i = 0; i < moves.length; i++) {
    const mv = moves[i];
    const from = mv >> 7, to = mv & 127;
    const p = bd[from];
    if (!p || (p >> 3) !== s) return -1;
    make(bd, mv);
    if (kingsFacing(bd)) { unmake(bd, mv, 0); return -1; }   // 传来的序列不合法
    s ^= 1;
  }
  return s;
}

/* ==================== 走子 ==================== */

/** 走子:顺带增量维护帅位与 Zobrist;返回被吃的子(0 表示没吃) */
export function make(bd, mv) {
  const from = mv >> 7, to = mv & 127;
  const p = bd[from], cap = bd[to];
  bd[to] = p; bd[from] = 0;
  if ((p & 7) === K) KSQ[p >> 3] = to;
  const z0 = (p - 1) * 90 + from, z1 = (p - 1) * 90 + to;
  HK1 ^= Z1[z0] ^ Z1[z1];
  HK2 ^= Z2[z0] ^ Z2[z1];
  if (cap) {
    const zc = (cap - 1) * 90 + to;
    HK1 ^= Z1[zc]; HK2 ^= Z2[zc];
  }
  return cap;
}

/** 撤销:异或是自逆的,所以键的维护与 make 完全对称 */
export function unmake(bd, mv, cap) {
  const from = mv >> 7, to = mv & 127;
  const p = bd[to];
  bd[from] = p; bd[to] = cap;
  if ((p & 7) === K) KSQ[p >> 3] = from;
  const z0 = (p - 1) * 90 + from, z1 = (p - 1) * 90 + to;
  HK1 ^= Z1[z0] ^ Z1[z1];
  HK2 ^= Z2[z0] ^ Z2[z1];
  if (cap) {
    const zc = (cap - 1) * 90 + to;
    HK1 ^= Z1[zc]; HK2 ^= Z2[zc];
  }
}

/* ==================== 攻击判定 ==================== */

/** 将帅对脸:同一列且中间无子 —— 这是非法局面,等价于被将 */
export function kingsFacing(bd) {
  const a = KSQ[RED], b = KSQ[BLACK];
  if (a < 0 || b < 0) return false;
  if ((a % 9) !== (b % 9)) return false;
  const lo = Math.min(a, b) + 9, hi = Math.max(a, b);
  for (let i = lo; i < hi; i += 9) if (bd[i]) return false;
  return true;
}

/** sq 是否被 by 方攻击(用于判将;不含将帅对脸,那个单独判) */
export function attackedBy(bd, sq, by) {
  const r = (sq / 9) | 0, c = sq % 9;

  /* 车 / 炮:向外扫,遇到的第一个子可能是车,第二个子可能是炮(炮架) */
  for (let d = 0; d < 4; d++) {
    let rr = r + DR4[d], cc = c + DC4[d], screen = false;
    while (rr >= 0 && rr < 10 && cc >= 0 && cc < 9) {
      const p = bd[rr * 9 + cc];
      if (p) {
        if (!screen) {
          if ((p >> 3) === by && (p & 7) === R) return true;
          screen = true;
        } else {
          if ((p >> 3) === by && (p & 7) === C) return true;
          break;
        }
      }
      rr += DR4[d]; cc += DC4[d];
    }
  }

  /* 马:从 sq 反推 8 个马位,腿位必须空(腿是「马朝 sq 走两步那一侧」的邻格) */
  for (let k = 0; k < 8; k++) {
    const dr = HN8[k][0], dc = HN8[k][1];
    const rr = r + dr, cc = c + dc;
    if (rr < 0 || rr > 9 || cc < 0 || cc > 8) continue;
    const p = bd[rr * 9 + cc];
    if (!p || (p >> 3) !== by || (p & 7) !== N) continue;
    const lr = rr - ((dr / 2) | 0), lc = cc - ((dc / 2) | 0);
    if (!bd[lr * 9 + lc]) return true;
  }

  /* 象:斜两格,象眼空;且象不能过河(sq 必须在象自己的半场) */
  if (ownHalf(by, r)) {
    for (let k = 0; k < 4; k++) {
      const rr = r + EL4[k][0], cc = c + EL4[k][1];
      if (rr < 0 || rr > 9 || cc < 0 || cc > 8) continue;
      const p = bd[rr * 9 + cc];
      if (!p || (p >> 3) !== by || (p & 7) !== B) continue;
      if (!bd[(r + EL4[k][2]) * 9 + (c + EL4[k][3])]) return true;
    }
  }

  /* 士:斜一格(士困在九宫,能走到 sq 说明 sq 也在九宫) */
  for (let k = 0; k < 4; k++) {
    const rr = r + DG4[k][0], cc = c + DG4[k][1];
    if (rr < 0 || rr > 9 || cc < 0 || cc > 8) continue;
    const p = bd[rr * 9 + cc];
    if (p && (p >> 3) === by && (p & 7) === A) return true;
  }

  /* 将/帅:正交一格(对脸另判) */
  for (let d = 0; d < 4; d++) {
    const rr = r + DR4[d], cc = c + DC4[d];
    if (rr < 0 || rr > 9 || cc < 0 || cc > 8) continue;
    const p = bd[rr * 9 + cc];
    if (p && (p >> 3) === by && (p & 7) === K) return true;
  }

  /* 兵:红兵向上吃(兵在 sq 下方),过河兵还能横吃;
   *     黑兵对称。过河条件看的是兵所在的行,不是目标行。 */
  if (by === RED) {
    if (r < 9) {
      const p = bd[(r + 1) * 9 + c];
      if (p && (p >> 3) === RED && (p & 7) === P) return true;
    }
    if (r <= 4) {
      if (c > 0) { const p = bd[r * 9 + c - 1]; if (p && (p >> 3) === RED && (p & 7) === P) return true; }
      if (c < 8) { const p = bd[r * 9 + c + 1]; if (p && (p >> 3) === RED && (p & 7) === P) return true; }
    }
  } else {
    if (r > 0) {
      const p = bd[(r - 1) * 9 + c];
      if (p && (p >> 3) === BLACK && (p & 7) === P) return true;
    }
    if (r >= 5) {
      if (c > 0) { const p = bd[r * 9 + c - 1]; if (p && (p >> 3) === BLACK && (p & 7) === P) return true; }
      if (c < 8) { const p = bd[r * 9 + c + 1]; if (p && (p >> 3) === BLACK && (p & 7) === P) return true; }
    }
  }
  return false;
}

/** side 是否被将军 */
export function inCheck(bd, side) {
  const k = KSQ[side];
  if (k < 0) return true;                 // 帅被吃了:判为被将,交给上层当非法/负
  return attackedBy(bd, k, side ^ 1) || kingsFacing(bd);
}

/* ==================== 着法生成 ==================== */

/** 伪合法着法写入 MB[base..],返回个数;capsOnly 只留吃子(静态搜索用) */
function genPseudo(bd, side, base, capsOnly) {
  let n = 0;
  for (let i = 0; i < 90; i++) {
    const p = bd[i];
    if (!p || (p >> 3) !== side) continue;
    const r = (i / 9) | 0, c = i % 9;
    switch (p & 7) {
      case R: {
        for (let d = 0; d < 4; d++) {
          let rr = r + DR4[d], cc = c + DC4[d];
          while (rr >= 0 && rr < 10 && cc >= 0 && cc < 9) {
            const q = bd[rr * 9 + cc];
            if (!q) {
              if (!capsOnly) MB[base + n++] = (i << 7) | (rr * 9 + cc);
            } else {
              if ((q >> 3) !== side) MB[base + n++] = (i << 7) | (rr * 9 + cc);
              break;
            }
            rr += DR4[d]; cc += DC4[d];
          }
        }
        break;
      }
      case C: {
        for (let d = 0; d < 4; d++) {
          let rr = r + DR4[d], cc = c + DC4[d], jumped = false;
          while (rr >= 0 && rr < 10 && cc >= 0 && cc < 9) {
            const sq = rr * 9 + cc, q = bd[sq];
            if (!jumped) {
              if (!q) {
                if (!capsOnly) MB[base + n++] = (i << 7) | sq;
              } else jumped = true;        // 第一个子当炮架
            } else if (q) {
              if ((q >> 3) !== side) MB[base + n++] = (i << 7) | sq;
              break;
            }
            rr += DR4[d]; cc += DC4[d];
          }
        }
        break;
      }
      case N: {
        for (let k = 0; k < 8; k++) {
          const rr = r + HN8[k][0], cc = c + HN8[k][1];
          if (rr < 0 || rr > 9 || cc < 0 || cc > 8) continue;
          if (bd[(r + HN8[k][2]) * 9 + (c + HN8[k][3])]) continue;   // 蹩马腿
          const sq = rr * 9 + cc, q = bd[sq];
          if (!q) { if (!capsOnly) MB[base + n++] = (i << 7) | sq; }
          else if ((q >> 3) !== side) MB[base + n++] = (i << 7) | sq;
        }
        break;
      }
      case B: {
        for (let k = 0; k < 4; k++) {
          const rr = r + EL4[k][0], cc = c + EL4[k][1];
          if (rr < 0 || rr > 9 || cc < 0 || cc > 8) continue;
          if (!ownHalf(side, rr)) continue;                            // 象不过河
          if (bd[(r + EL4[k][2]) * 9 + (c + EL4[k][3])]) continue;     // 塞象眼
          const sq = rr * 9 + cc, q = bd[sq];
          if (!q) { if (!capsOnly) MB[base + n++] = (i << 7) | sq; }
          else if ((q >> 3) !== side) MB[base + n++] = (i << 7) | sq;
        }
        break;
      }
      case A: {
        for (let k = 0; k < 4; k++) {
          const rr = r + DG4[k][0], cc = c + DG4[k][1];
          if (!inPalace(side, rr, cc)) continue;
          const sq = rr * 9 + cc, q = bd[sq];
          if (!q) { if (!capsOnly) MB[base + n++] = (i << 7) | sq; }
          else if ((q >> 3) !== side) MB[base + n++] = (i << 7) | sq;
        }
        break;
      }
      case K: {
        for (let d = 0; d < 4; d++) {
          const rr = r + DR4[d], cc = c + DC4[d];
          if (!inPalace(side, rr, cc)) continue;
          const sq = rr * 9 + cc, q = bd[sq];
          if (!q) { if (!capsOnly) MB[base + n++] = (i << 7) | sq; }
          else if ((q >> 3) !== side) MB[base + n++] = (i << 7) | sq;
        }
        break;
      }
      case P: {
        /* 兵只进不退;过河(红 r<=4 / 黑 r>=5)后可横走一步 */
        const fwd = side === RED ? r - 1 : r + 1;
        if (fwd >= 0 && fwd <= 9) {
          const sq = fwd * 9 + c, q = bd[sq];
          if (!q) { if (!capsOnly) MB[base + n++] = (i << 7) | sq; }
          else if ((q >> 3) !== side) MB[base + n++] = (i << 7) | sq;
        }
        if (side === RED ? r <= 4 : r >= 5) {
          for (let dc = -1; dc <= 1; dc += 2) {
            const cc = c + dc;
            if (cc < 0 || cc > 8) continue;
            const sq = r * 9 + cc, q = bd[sq];
            if (!q) { if (!capsOnly) MB[base + n++] = (i << 7) | sq; }
            else if ((q >> 3) !== side) MB[base + n++] = (i << 7) | sq;
          }
        }
        break;
      }
    }
  }
  return n;
}

/** 合法着法写入 MB[base..] —— 伪合法逐个试走,送将/对脸的剔除 */
function genLegalBuf(bd, side, base, capsOnly) {
  const n = genPseudo(bd, side, base, capsOnly);
  let m = 0;
  for (let i = 0; i < n; i++) {
    const mv = MB[base + i];
    const cap = make(bd, mv);
    if (!inCheck(bd, side)) MB[base + m++] = mv;
    unmake(bd, mv, cap);
  }
  return m;
}

/** 给 UI/测试用:合法着法数组 */
export function genLegal(bd, side) {
  const base = 0;
  const n = genLegalBuf(bd, side, base, false);
  const out = new Array(n);
  for (let i = 0; i < n; i++) out[i] = MB[base + i];
  return out;
}

/** 有没有合法着法(无棋可走 = 将死或困毙,象棋里都算负) */
export function hasMove(bd, side) {
  const mvs = genLegal(bd, side);
  return mvs.length > 0;
}

/* ==================== 评估 ==================== */

const TEMPO = 8;

/**
 * 静态评估,返回「红方视角」分。
 * 子力 + 位置表;黑方查表用镜像行(9-行)。
 */
export function evaluate(bd) {
  let s = 0;
  for (let i = 0; i < 90; i++) {
    const p = bd[i];
    if (!p) continue;
    const t = p & 7;
    if (p >> 3) {                        // 黑:镜像行查表
      const mir = (9 - ((i / 9) | 0)) * 9 + (i % 9);
      const pst = PSTS[t];
      s -= VAL[t] + (pst ? pst[mir] : 0);
    } else {
      const pst = PSTS[t];
      s += VAL[t] + (pst ? pst[i] : 0);
    }
  }
  return s;
}

/* ==================== 置换表 ==================== */

const TT_BITS = 17, TT_SIZE = 1 << TT_BITS, TT_MASK = TT_SIZE - 1;
const ttK1 = new Int32Array(TT_SIZE), ttK2 = new Int32Array(TT_SIZE);
const ttMv = new Int32Array(TT_SIZE), ttSc = new Int32Array(TT_SIZE);
const ttDp = new Int8Array(TT_SIZE), ttFl = new Int8Array(TT_SIZE);

/** 每次搜索前清空:保证同一局面重复搜索结果一致(测试对拍与复盘要可复现) */
export function clearTT() {
  ttK1.fill(0); ttK2.fill(0); ttMv.fill(0); ttDp.fill(0); ttFl.fill(0);
  KILLER.fill(0);
}

/* ==================== 搜索 ==================== */

let nodes = 0;
let t0 = 0, nodeBudget = 0, msBudget = 0, aborted = false;

function timeUp() {
  if (nodes > nodeBudget) { aborted = true; return true; }
  if ((nodes & 1023) === 0 && Date.now() - t0 > msBudget) { aborted = true; return true; }
  return false;
}

/** 排序分:TT 着法 → 吃子(MVV-LVA)→ killer → history */
function scoreMoves(bd, base, n, ttMove, ply) {
  for (let i = 0; i < n; i++) {
    const mv = MB[base + i];
    if (mv === ttMove) { MS[base + i] = 1 << 28; continue; }
    const victim = bd[mv & 127];
    if (victim) {
      MS[base + i] = 1000000 + VAL[victim & 7] * 16 - VAL[bd[mv >> 7] & 7];
    } else if (mv === KILLER[ply * 2] || mv === KILLER[ply * 2 + 1]) {
      MS[base + i] = 900000;
    } else {
      MS[base + i] = HIST[mv];
    }
  }
}

/** 主搜索(负极大 + alpha-beta) */
function search(bd, side, depth, alpha, beta, ply) {
  nodes++;
  if (timeUp()) return 0;

  const inChk = inCheck(bd, side);
  if (inChk && ply < MAXPLY - 2) depth++;            // 将军延伸:被将时多看一层
  if (depth <= 0) return qsearch(bd, side, alpha, beta, ply);

  /* 置换表键:局面键再异或行棋方 —— 同一副摆法换先手是另一个局面 */
  const k1 = HK1 ^ (side === BLACK ? ZS1 : 0);
  const idx = k1 & TT_MASK;
  let ttMove = 0;
  if (ttK1[idx] === k1 && ttK2[idx] === HK2) {
    ttMove = ttMv[idx];
    if (ttDp[idx] >= depth && ply > 0) {
      const sc = ttSc[idx], fl = ttFl[idx];
      if (fl === 0) return sc;
      if (fl === 2 && sc >= beta) return sc;
      if (fl === 3 && sc <= alpha) return sc;
    }
  }

  const base = ply * MOVE_CAP;
  const n = genLegalBuf(bd, side, base, false);
  if (n === 0) return -MATE + ply;                   // 将死 / 困毙都算负
  scoreMoves(bd, base, n, ttMove, ply);

  let best = -INF, bestMove = 0, flag = 3;           // 3 = 上界
  const a0 = alpha;
  for (let i = 0; i < n; i++) {
    /* 选择排序取当前最大分:着法数 ≤ 128,O(n²) 也比分配数组省 */
    let bi = i;
    for (let j = i + 1; j < n; j++) if (MS[base + j] > MS[base + bi]) bi = j;
    if (bi !== i) {
      const tmv = MB[base + i]; MB[base + i] = MB[base + bi]; MB[base + bi] = tmv;
      const tsc = MS[base + i]; MS[base + i] = MS[base + bi]; MS[base + bi] = tsc;
    }
    const mv = MB[base + i];
    const cap = make(bd, mv);
    const sc = -search(bd, side ^ 1, depth - 1, -beta, -alpha, ply + 1);
    unmake(bd, mv, cap);
    if (aborted) return 0;
    if (sc > best) {
      best = sc; bestMove = mv;
      if (sc > alpha) { alpha = sc; flag = 0; }      // 0 = 精确
      if (alpha >= beta) {
        flag = 2;                                    // 2 = 下界(截断)
        if (!cap) {
          if (KILLER[ply * 2] !== mv) { KILLER[ply * 2 + 1] = KILLER[ply * 2]; KILLER[ply * 2] = mv; }
          HIST[mv] += depth * depth;
        }
        break;
      }
    }
  }

  ttK1[idx] = k1; ttK2[idx] = HK2; ttMv[idx] = bestMove;
  ttSc[idx] = best; ttDp[idx] = Math.min(depth, 127); ttFl[idx] = flag;
  return best;
}

/** 静态搜索:只展开吃子,避免「车吃了兵下一步被反吃」这类地平线错觉 */
function qsearch(bd, side, alpha, beta, ply) {
  nodes++;
  if (timeUp()) return 0;
  let best = side === RED ? evaluate(bd) + TEMPO : -evaluate(bd) + TEMPO;
  if (best >= beta) return best;
  if (best > alpha) alpha = best;
  if (ply >= MAXPLY - 4) return best;

  const base = ply * MOVE_CAP;
  const n = genLegalBuf(bd, side, base, true);
  scoreMoves(bd, base, n, 0, ply);
  for (let i = 0; i < n; i++) {
    let bi = i;
    for (let j = i + 1; j < n; j++) if (MS[base + j] > MS[base + bi]) bi = j;
    if (bi !== i) {
      const tmv = MB[base + i]; MB[base + i] = MB[base + bi]; MB[base + bi] = tmv;
      const tsc = MS[base + i]; MS[base + i] = MS[base + bi]; MS[base + bi] = tsc;
    }
    const mv = MB[base + i];
    const cap = make(bd, mv);
    const sc = -qsearch(bd, side ^ 1, -beta, -alpha, ply + 1);
    unmake(bd, mv, cap);
    if (aborted) return 0;
    if (sc > best) {
      best = sc;
      if (sc > alpha) { alpha = sc; if (alpha >= beta) break; }
    }
  }
  return best;
}

/* ==================== 难度档 ==================== */
/* 节点预算为主(设备无关、可复现),墙上时间为兜底。
 * jitter:低难度在「最优着法 N 分以内」里随机挑一个 —— 比给评分加噪声正统,
 *         同一局面不会前后矛盾。 */
export const LEVELS = [
  { id: 'easy', name: '初级', desc: '1 层搜索 + 吃子静态搜索', depth: 2, nodes: 20000, ms: 300, jitter: 60 },
  { id: 'normal', name: '中级', desc: '4 层迭代加深', depth: 4, nodes: 150000, ms: 900, jitter: 0 },
  { id: 'hard', name: '高级', desc: '6 层迭代加深', depth: 6, nodes: 600000, ms: 2500, jitter: 0 },
  { id: 'master', name: '大师', desc: '8 层迭代加深', depth: 8, nodes: 2000000, ms: 6000, jitter: 0 },
];
export const DEFAULT_LEVEL = 2;

/**
 * 搜索最佳着法。
 * opt: { depth, nodes, ms, jitter, onProgress({depth, move, score, nodes, ms}) }
 * 返回 { move, score, depth, nodes, ms, mate }
 * move = 0 表示无棋可走(已被将死/困毙)。
 */
export function searchBest(bd, side, opt = {}) {
  t0 = Date.now();
  nodeBudget = opt.nodes ?? 400000;
  msBudget = opt.ms ?? 2000;
  const maxDepth = opt.depth ?? 6;
  nodes = 0; aborted = false;
  clearTT();

  const root = genLegal(bd, side).map((mv) => ({ mv, sc: 0 }));
  if (root.length === 0) return { move: 0, score: -MATE, depth: 0, nodes: 0, ms: 0, mate: true };
  if (root.length === 1) {
    return { move: root[0].mv, score: 0, depth: 1, nodes: 0, ms: Date.now() - t0, only: true, mate: false };
  }

  let best = root[0].mv, bestScore = 0, doneDepth = 0;
  for (let d = 1; d <= maxDepth; d++) {
    let alpha = -INF;
    let iterBest = 0, iterScore = -INF;
    for (const item of root) {
      const cap = make(bd, item.mv);
      const sc = -search(bd, side ^ 1, d - 1, -INF, -alpha, 1);
      unmake(bd, item.mv, cap);
      if (aborted) break;
      item.sc = sc;
      if (sc > iterScore) { iterScore = sc; iterBest = item.mv; if (sc > alpha) alpha = sc; }
    }
    if (aborted) break;
    best = iterBest; bestScore = iterScore; doneDepth = d;
    root.sort((a, b) => b.sc - a.sc);                // 上一层的分数当下一层的排序
    opt.onProgress?.({ depth: d, move: best, score: bestScore, nodes, ms: Date.now() - t0 });
    if (Math.abs(bestScore) > MATE - 200) break;     // 已经算到杀棋,不必再深
    if (Date.now() - t0 > msBudget) break;
  }

  /* 低难度:在最优解附近随机挑一个,弱得可控 */
  const jitter = opt.jitter ?? 0;
  if (jitter > 0 && bestScore > -MATE + 200) {
    const pool = root.filter((it) => it.sc >= bestScore - jitter);
    best = pool[(Math.random() * pool.length) | 0].mv;
  }

  return {
    move: best, score: bestScore, depth: doneDepth, nodes,
    ms: Date.now() - t0, mate: Math.abs(bestScore) > MATE - 200,
  };
}

/* ==================== 中文记谱 ==================== */

const NAME_R = ['', '帅', '仕', '相', '马', '车', '炮', '兵'];
const NAME_B = ['', '将', '士', '象', '马', '车', '炮', '卒'];
const NUM_R = ['一', '二', '三', '四', '五', '六', '七', '八', '九'];
const NUM_B = ['1', '2', '3', '4', '5', '6', '7', '8', '9'];

/** 纵线号:红从右往左 一~九,黑从左往右 1~9(各自视角的右手边为第一线) */
const fileNo = (side, c) => (side === RED ? 9 - c : c + 1);
const numOf = (side, n) => (side === RED ? NUM_R[n - 1] : NUM_B[n - 1]);

/**
 * 着法转中文记谱(如「炮二平五」「马八进七」)。
 * 同一纵线有两个同类子时用「前/后」代替线号(前 = 更靠近对方)。
 * 注意:必须在走子**之前**调用(要读 from 上的棋子)。
 */
export function moveToText(bd, mv) {
  const from = mv >> 7, to = mv & 127;
  const p = bd[from];
  if (!p) return '';
  const side = p >> 3, t = p & 7;
  const name = (side === RED ? NAME_R : NAME_B)[t];
  const fr = (from / 9) | 0, fc = from % 9;
  const tr = (to / 9) | 0, tc = to % 9;

  /* 同纵线上的同类子:用前/后消歧 */
  let twin = -1;
  for (let r = 0; r < 10; r++) {
    const sq = r * 9 + fc;
    if (sq !== from && bd[sq] === p) { twin = sq; break; }
  }

  let head;
  if (twin >= 0) {
    const front = side === RED ? Math.min(fr, (twin / 9) | 0) : Math.max(fr, (twin / 9) | 0);
    head = (fr === front ? '前' : '后') + name;
  } else {
    head = name + numOf(side, fileNo(side, fc));
  }

  if (tr === fr) {                                    // 平:横线移动,记目标线号
    return head + '平' + numOf(side, fileNo(side, tc));
  }
  const forward = side === RED ? tr < fr : tr > fr;   // 朝对方走 = 进
  const act = forward ? '进' : '退';
  /* 车/炮/兵/将走直线:记步数;马/象/士走斜线:记目标线号 */
  const straight = t === R || t === C || t === P || t === K;
  const tail = straight ? Math.abs(tr - fr) : fileNo(side, tc);
  return head + act + numOf(side, tail);
}

/* ==================== 测试钩子 ==================== */

/** perft:合法着法计数(规则实现的金标准,初始局面 44/1920/79666/3290240) */
export function perft(bd, side, depth) {
  if (depth <= 0) return 1;
  const mvs = genLegal(bd, side);
  if (depth === 1) return mvs.length;
  let n = 0;
  for (const mv of mvs) {
    const cap = make(bd, mv);
    n += perft(bd, side ^ 1, depth - 1);
    unmake(bd, mv, cap);
  }
  return n;
}

export function nodeCount() { return nodes; }
export function boardToArray(bd) { return Array.from(bd); }
export function arrayToBoard(arr) { const bd = new Int8Array(90); bd.set(arr); syncPosition(bd); return bd; }
