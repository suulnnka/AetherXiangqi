/* ============================================================
 * AI Worker:wasm 引擎的门面(UI 不 import 引擎源码,一切经消息)。
 * 契约与 v0.1-js worker 完全一致,UI 零改动:
 *   ping                → { type:'pong', tag }
 *   { type:'levels' }   → { type:'levels', tag, engine, default, levels }
 *                         纯声明难度表,不触发 wasm 加载
 *   { type:'state', id, moves }
 *                       → { type:'state', id, board, stm, legal, checked,
 *                           over, winner, lastText }
 *   { id, moves, level }(think)
 *                       → { id, move, text, depth, nodes, ms, score, mate }
 * moves 是 (from<<7|to) 的走法序列(协议坐标:row0=黑方底线)。
 *
 * 搜索是同步的(wasm 无墙钟,难度=节点预算);UI 用请求序号丢弃过期结果,
 * 需要真正中断时 terminate 再造。
 * ============================================================ */
const ENGINE_TAG = 'xiangqi-engine-v2-wasm';
self.__engineTag = ENGINE_TAG;

/* 难度表:节点预算为主(wasm ~1M nps 量级,时间可预估) */
const LEVELS = [
  { name: '初级', nodes: 10000 },
  { name: '中级', nodes: 100000 },
  { name: '高级', nodes: 500000 },
  { name: '大师', nodes: 2000000 },
  { name: '特级', nodes: 8000000 },
];
const DEFAULT_LEVEL = 2;

/* ---------- wasm 懒加载 ---------- */
let api = null;
let booting = null;

async function boot() {
  if (api) return true;
  if (booting) return booting;
  booting = (async () => {
    try {
      const res = await fetch(new URL('../wasm/aetherx.wasm', self.location.href));
      const { instance } = await WebAssembly.instantiate(await res.arrayBuffer(), {});
      api = instance.exports;
      api.engineInit();
      return true;
    } catch (e) {
      api = null;
      return false;
    } finally {
      booting = null;
    }
  })();
  return booting;
}

const MEM = () => api.memory.buffer;
const i32ptr = (p, n) => new Int32Array(MEM(), p, n);

/* 走法序列写进 wasm 输入缓冲并重演。空序列重演为初始局面。 */
function loadMoves(moves) {
  const n = moves.length;
  const buf = i32ptr(api.engineMovesBuf(), n);
  buf.set(moves);
  return api.engineLoad(n) === 1;
}

/* 协议坐标棋盘字节数组(90) */
function boardArray() {
  return Array.from(new Int8Array(MEM(), api.engineBoardPtr(), 90));
}

/* 当前开局名(engineState 时更新;UTF-8 C 字符串) */
function openingName() {
  const p = api.engineOpeningPtr();
  if (!p) return null;
  const bytes = new Uint8Array(MEM(), p, 96);
  let n = bytes.indexOf(0);
  if (n < 0) n = 96;
  const s = new TextDecoder().decode(bytes.subarray(0, n));
  return s || null;
}

/* ---------- 中文记谱(v0.1-js moveToText 移植,读走子前的盘) ---------- */
const NAME_R = ['', '帅', '仕', '相', '马', '车', '炮', '兵'];
const NAME_B = ['', '将', '士', '象', '马', '车', '炮', '卒'];
const NUM_R = ['一', '二', '三', '四', '五', '六', '七', '八', '九'];
const NUM_B = ['1', '2', '3', '4', '5', '6', '7', '8', '9'];
const fileNo = (side, c) => (side === 0 ? 9 - c : c + 1);
const numOf = (side, n) => (side === 0 ? NUM_R[n - 1] : NUM_B[n - 1]);

/** 必须在走子**之前**调用(要读 from 上的棋子)。bd 为协议棋盘字节。 */
function moveToText(bd, mv) {
  const from = mv >> 7, to = mv & 127;
  const p = bd[from];
  if (!p) return '';
  const side = p >> 3, t = p & 7;
  const name = (side === 0 ? NAME_R : NAME_B)[t];
  const fr = (from / 9) | 0, fc = from % 9;
  const tr = (to / 9) | 0, tc = to % 9;
  let twin = -1;
  for (let r = 0; r < 10; r++) {
    const sq = r * 9 + fc;
    if (sq !== from && bd[sq] === p) { twin = sq; break; }
  }
  let head;
  if (twin >= 0) {
    const front = side === 0 ? Math.min(fr, (twin / 9) | 0) : Math.max(fr, (twin / 9) | 0);
    head = (fr === front ? '前' : '后') + name;
  } else {
    head = name + numOf(side, fileNo(side, fc));
  }
  if (tr === fr) return head + '平' + numOf(side, fileNo(side, tc));
  const forward = side === 0 ? tr < fr : tr > fr;
  const act = forward ? '进' : '退';
  const straight = t === 5 || t === 6 || t === 7 || t === 1; /* 车炮兵将 */
  const tail = straight ? Math.abs(tr - fr) : fileNo(side, tc);
  return head + act + numOf(side, tail);
}

/* ---------- state:重演序列并回报全部规则事实 ---------- */
async function describeState(d) {
  if (!(await boot())) return { error: 'wasm-load-failed' };
  const last = d.moves.length ? d.moves[d.moves.length - 1] : -1;

  /* 记谱要在走子之前读局面,先重演到 n-1 */
  let text = null;
  if (d.moves.length) {
    if (!loadMoves(d.moves.slice(0, -1))) return { error: 'illegal-sequence' };
    text = moveToText(boardArray(), last);
  }
  if (!loadMoves(d.moves)) return { error: 'illegal-sequence' };

  api.engineState();
  const legal = Array.from(i32ptr(api.engineLegalPtr(), api.engineLegalCount()));
  /* 和棋类结果(重复/60 回合)暂不转发为终局:UI 无和棋流程,与 v0.1 行为一致 */
  const over = api.engineOver() === 1 && api.engineResult() <= 2 ? 1 : 0;
  return {
    board: boardArray(),
    stm: api.engineStm(),
    legal,
    checked: [api.engineCheck(0) === 1, api.engineCheck(1) === 1],
    over,
    winner: over ? api.engineWinner() : -1,
    lastText: text,
    opening: openingName(),
  };
}

/* ---------- 消息循环 ---------- */
self.onmessage = async (e) => {
  const d = e.data;
  if (!d) return;

  if (d.type === 'ping') {
    if (await boot()) self.postMessage({ type: 'pong', tag: ENGINE_TAG, evalCp: api.engineEvalCp() });
    else self.postMessage({ type: 'pong', tag: ENGINE_TAG, error: 'wasm-load-failed' });
    return;
  }

  if (d.type === 'levels') {
    /* 纯声明,不触发加载 */
    self.postMessage({ type: 'levels', tag: ENGINE_TAG, engine: 'wasm', default: DEFAULT_LEVEL, levels: LEVELS });
    return;
  }

  if (d.type === 'state') {
    const s = await describeState(d);
    self.postMessage(s.error
      ? { type: 'state', id: d.id, error: s.error }
      : { type: 'state', id: d.id, tag: ENGINE_TAG, ...s });
    return;
  }

  /* think:{ id, moves, level } */
  const t0 = Date.now();
  if (!(await boot())) { self.postMessage({ id: d.id, error: 'wasm-load-failed' }); return; }
  if (!loadMoves(d.moves)) { self.postMessage({ id: d.id, error: 'illegal-sequence' }); return; }
  const lv = LEVELS[d.level] ?? LEVELS[DEFAULT_LEVEL];
  /* 记谱读走子前盘面;seed 供开局谱抽签(wasm 无墙钟) */
  const before = boardArray();
  const mv = api.engineThink(0, lv.nodes, (Math.random() * 0x7fffffff) | 0);
  const lo = api.engineNodesLo() >>> 0, hi = api.engineNodesHi() >>> 0;
  const score = api.engineScore();
  self.postMessage({
    id: d.id,
    move: mv,
    text: mv ? moveToText(before, mv) : null,
    depth: api.engineDepth(),
    nodes: lo + hi * 4294967296,
    ms: Date.now() - t0,
    score,
    mate: Math.abs(score) > 29800,
  });
};
