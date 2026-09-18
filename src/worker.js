/* ============================================================
 * AI Worker:只是一层薄壳
 *   收 { id, moves, nodes, ms, depth, jitter }
 *   回 { id, move, depth, nodes, ms, score, mate }
 *
 * moves 是 (from<<7|to) 的走法序列 —— 传序列而不是传棋盘:结构化克隆最省,
 * 且 UI 与 Worker 共用同一份 engine.js,走法编码天然一致,不存在两条解析路径。
 *
 * 搜索是同步的,Worker 收到新消息只会排队;UI 侧用请求序号丢弃过期结果,
 * 需要真正中断时直接 terminate 再造一个(见 index.js 的 abortEngine)。
 * ============================================================ */
import { newBoard, replayMoves, searchBest } from './engine.js';

/* ENGINE_TAG 让下游 webos 的体积闸门(check-size.mjs)能在 dist 里认出这个 chunk
 * (字符串不会被压缩改名)。 */
const ENGINE_TAG = 'xiangqi-engine-v1';
self.__engineTag = ENGINE_TAG;

self.onmessage = (e) => {
  const d = e.data;
  if (d && d.type === 'ping') { self.postMessage({ type: 'pong', tag: ENGINE_TAG }); return; }
  const t0 = Date.now();
  const bd = newBoard();
  const side = replayMoves(bd, d.moves);
  if (side < 0) { self.postMessage({ id: d.id, error: 'illegal-sequence' }); return; }
  const r = searchBest(bd, side, {
    nodes: d.nodes, ms: d.ms, depth: d.depth, jitter: d.jitter ?? 0,
  });
  self.postMessage({
    id: d.id, move: r.move, depth: r.depth, nodes: r.nodes,
    ms: Date.now() - t0, score: r.score, mate: !!r.mate,
  });
};
