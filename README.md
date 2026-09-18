# AetherXiangqi

纯 JavaScript 中国象棋引擎:零依赖、无 DOM、浏览器 / Worker / Node 通用。
从 [WebOS](https://github.com/suulnnka/AetherWebOS)(纯前端网页操作系统)的中国象棋应用中抽离而来,全部自研。

**在线体验:** 打开 <https://suulnnka.github.io/AetherWebOS/> 启动「中国象棋」应用 —— 那里面跑的就是本引擎
(默认高级档,窗口信息行实时显示搜索深度 / 最佳着法 / 评分 / 节点数 / 耗时)。

> v0.1:规则完整(perft 对齐公认计数),搜索与评估都是**第一版、刻意做简单**的。
> 后续路线见 [`docs/ROADMAP.md`](docs/ROADMAP.md)。

## 棋盘与编码

- 90 格(10 行 × 9 列),`idx = 行×9 + 列`;行 0 是黑方底线(上),行 9 是红方底线(下),红先。
- 棋子:低 3 位为类型(`K` 将帅 / `A` 士 / `B` 象 / `N` 马 / `R` 车 / `C` 炮 / `P` 兵卒),bit3 为颜色(0 红 / 1 黑),0 为空。
- 走法:`from<<7 | to`(14 位)。UI 与 Worker 之间只传这一种编码,不搞两套。

## 引擎

`src/engine.js` 单文件(规则 + 评估 + 搜索),`src/worker.js` 只是 Worker 薄壳。

- **规则**:车炮直线(炮需翻山)、马蹩腿、象塞眼且不过河、士将限九宫、兵只进不退(过河可横走)、将帅对脸判非法。
- **搜索**:negamax + alpha-beta + 迭代加深 + 置换表(Zobrist 双 32 位校验)
  + MVV-LVA / killer / history 排序 + 吃子静态搜索 + 将军延伸。
- **评估**:子力 + 位置表(车 / 马 / 炮 / 兵)+ tempo。参数是手调初值,**没有**自对弈拟合。
- **难度四档**(节点预算为主、墙上时间为兜底,设备无关且可复现):

  | 档位 | 深度 | 节点预算 | 说明 |
  |---|---|---|---|
  | 初级 | 2 | 20k | 另加 root jitter:在最优解 60 分内随机挑,弱得可控 |
  | 中级 | 4 | 150k | 约 0.15s |
  | 高级 | 6 | 600k | 约 0.7s |
  | 大师 | 8 | 2M | 约 2.4s |

- 性能:约 **85 万节点/s**(Node 22 / 桌面级 CPU,数组棋盘)。

## 用法

```js
import { newBoard, genLegal, make, moveToText, searchBest, LEVELS } from './src/engine.js';

const bd = newBoard();                       // Int8Array(90)
const moves = genLegal(bd, 0);               // 红方合法着法(走法编码数组)
console.log(moveToText(bd, moves[0]));       // 中文记谱,如「炮二平五」——注意要在走子之前调用

const r = searchBest(bd, 0, { ...LEVELS[2], onProgress: (i) => console.log(i.depth, i.score) });
// r = { move, score, depth, nodes, ms, mate }
make(bd, r.move);                            // 走子;撤销用 unmake(bd, mv, cap)
```

Worker 侧收 `{ id, moves, nodes, ms, depth, jitter }`,回 `{ id, move, depth, nodes, ms, score, mate }`;
`moves` 是从初始局面起的走法序列,Worker 自己重演棋盘(结构化克隆最省,且不会有两份规则实现)。

## 测试与基准

```bash
npm test                          # 规则用例 + 记谱 + 搜索行为 + 随机对局模糊测试 + perft
node test/engine-test.mjs perft   # 只跑 perft(--list 看全部小节)

node bench/bench.mjs nps          # 各档位节点速度(初始局面)
node bench/bench.mjs moves 5      # 固定深度最佳着法(改搜索/改评估后对拍)
node bench/bench.mjs perft        # perft 计时
```

**perft 是规则实现的金标准**,初始局面公认计数:

| 深度 | 合法着法数 |
|---|---|
| 1 | 44 |
| 2 | 1,920 |
| 3 | 79,666 |
| 4 | 3,290,240 |

## 已知不做(v0.1 的边界)

- 重复局面 / 长将长捉判负、60 回合自然限着 —— 搜索里没有局面历史,留给 ROADMAP 第一期
- 子力机动性、将帅安全、「缺士怕炮」等中局知识(评估只有子力 + PST)

## 明确不做(已拍板,不是「还没做」)

- **开局库 / 残局库** —— 不内置任何着法表,开局与残局一律进搜索
- **UCCI 协议** —— 不接主流象棋 GUI、不与第三方引擎对打;棋力只靠自对弈 A/B 定方向
- **多线程** —— 单线程到底
- **WASM** —— 暂未启动,等 JS 侧优化到头再评估

> 体积预算 35 KB gzip(与国际象棋引擎 AetherChess 同档),由 WebOS 侧
> `tools/check-size.mjs` 在 `npm run build` 时拦;当前 3.5 KB。

## License

MIT
