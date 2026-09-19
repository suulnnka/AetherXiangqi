/* ============================================================
 * AI Worker:引擎的门面(UI 不 import 引擎源码,一切经消息)
 *   ping                     → { type:'pong', tag }
 *   { type:'levels' }        → { type:'levels', tag, engine, default, levels }
 *                              纯声明难度表,不触发任何引擎加载;
 *                              UI 只读 name/id,nodes/ms/depth 是实现细节
 *   { type:'state', id, moves }
 *                            → { type:'state', id, board, stm, legal, checked,
 *                                over, winner, lastText }
 *                              规则查询的单一入口:重演序列后回报棋盘、行棋方
 *                              全部合法着法、双方被将军态、将死/困毙与最后一手记谱
 *   { type:'think', id, moves, level }
 *                            → 逐层 { id, type:'progress', depth, move, score, nodes, ms }
 *                            → { id, move, text, depth, nodes, ms, score, mate }
 *                              level 是**本引擎难度表的下标**(表由 levels 自报);
 *                              text 是该手的中文记谱(引擎在读局面前算好)
 *
 * moves 是 (from<<7|to) 的走法序列 —— 传序列而不是传棋盘:结构化克隆最省,
 * 编码只有一套,不存在两条解析路径。
 *
 * 搜索是同步的,Worker 收到新消息只会排队;UI 侧用请求序号丢弃过期结果,
 * 需要真正中断时直接 terminate 再造一个(见 index.js 的 abortEngine)。
 * ============================================================ */
import {
  newBoard, replayMoves, searchBest, make, genLegal, hasMove, inCheck,
  moveToText, boardToArray, LEVELS, DEFAULT_LEVEL,
} from './engine.js';

/* ENGINE_TAG 让下游 webos 的体积闸门(check-size.mjs)能在 dist 里认出这个 chunk
 * (字符串不会被压缩改名)。 */
const ENGINE_TAG = 'xiangqi-engine-v1';
self.__engineTag = ENGINE_TAG;

/** 重演序列并产出「UI 渲染所需的全部规则事实」:棋盘、合法着法、双方将军态、
 *  将死/困毙终局与最后一手记谱。这是 state 消息的唯一事实源 —— UI 不复判规则。 */
function describeState(d) {
  const bd = newBoard();
  const last = d.moves.length ? d.moves[d.moves.length - 1] : -1;

  /* 记谱要在走子之前读局面(起始格才有子),所以先重演到 n-1 手再补最后一手 */
  const prev = d.moves.length ? newBoard() : null;
  let text = null;
  if (prev) {
    const s = replayMoves(prev, d.moves.slice(0, -1));
    if (s < 0) return { error: 'illegal-sequence' };
    text = moveToText(prev, last);
  }

  const side = replayMoves(bd, d.moves);
  if (side < 0) return { error: 'illegal-sequence' };

  const checked = [inCheck(bd, 0), inCheck(bd, 1)];
  const over = !hasMove(bd, side);            // 将死或困毙,象棋里都算负
  return {
    board: boardToArray(bd),
    stm: side,
    legal: genLegal(bd, side),
    checked,
    over,
    winner: over ? 1 - side : -1,
    lastText: text,
  };
}

self.onmessage = (e) => {
  const d = e.data;
  if (!d) return;

  if (d.type === 'ping') { self.postMessage({ type: 'pong', tag: ENGINE_TAG }); return; }

  if (d.type === 'levels') {
    /* 纯声明:难度表(含参数)是引擎的实现细节,UI 只拿 name/id 建下拉 */
    self.postMessage({ type: 'levels', tag: ENGINE_TAG, engine: 'js', default: DEFAULT_LEVEL, levels: LEVELS });
    return;
  }

  if (d.type === 'state') {
    const s = describeState(d);
    self.postMessage(s.error
      ? { type: 'state', id: d.id, error: s.error }
      : { type: 'state', id: d.id, tag: ENGINE_TAG, ...s });
    return;
  }

  const t0 = Date.now();
  const bd = newBoard();
  const side = replayMoves(bd, d.moves);
  if (side < 0) { self.postMessage({ id: d.id, error: 'illegal-sequence' }); return; }
  const lv = LEVELS[d.level] ?? LEVELS[DEFAULT_LEVEL] ?? LEVELS[0];
  const r = searchBest(bd, side, {
    nodes: lv.nodes, ms: lv.ms, depth: lv.depth, jitter: lv.jitter ?? 0,
  });
  self.postMessage({
    id: d.id, move: r.move,
    text: r.move ? moveToText(bd, r.move) : null,   // 记谱在引擎应用该手之前算
    depth: r.depth, nodes: r.nodes,
    ms: Date.now() - t0, score: r.score, mate: !!r.mate,
  });
};
