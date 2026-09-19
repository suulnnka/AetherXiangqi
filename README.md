# AetherXiangqi

纯 JavaScript 中国象棋引擎:零依赖、无 DOM、浏览器 / Worker / Node 通用。
从 [WebOS](https://github.com/suulnnka/AetherWebOS)(纯前端网页操作系统)的中国象棋应用中抽离而来,全部自研。

**在线体验:** 打开 <https://suulnnka.github.io/AetherWebOS/> 启动「中国象棋」应用 —— 那里面跑的就是本引擎
(默认高级档,窗口信息行实时显示搜索深度 / 最佳着法 / 评分 / 节点数 / 耗时)。

## 在线对弈页(GitHub Pages,免 CI)

本仓库自带一个**开箱即玩的对弈页**:布局与交互取自 WebOS 的中国象棋应用,
同一份 Worker 契约接的也是本仓库的引擎 —— 纯 JS,alpha-beta 迭代加深 + 置换表 + 中文记谱。**没有构建、没有 CI**:站点即仓库本身,GitHub Pages 原样引用仓库文件直接出页面:

**<https://suulnnka.github.io/AetherXiangqi/>**

页面即仓库布局:`index.html`(根)+ `pages/`(页面资产),引擎入口在 `src/`、
wasm 在 `wasm/`,全部按相对路径引用 —— 本地预览无需构建,仓库根起任意静态
服务器即可:

```bash
python3 -m http.server 8000     # 仓库根起服
# 打开 http://localhost:8000/
```

线上开启只需一次:仓库 **Settings → Pages → Build and deployment → Source 选
「Deploy from a branch」,Branch 选默认分支 + `/(root)`**;此后每次推送自动更新,
不走任何 Actions。

功能与 WebOS 应用一致:新对局 / 难度(引擎自报表)/ 人机或双人 / 换边 / 悔棋
(选中子高亮走吃点,将军闪红,将死 / 困毙自动判终局),底栏左侧行棋状态、右侧实时引擎搜索信息。


> v0.1:规则完整(perft 对齐公认计数),搜索与评估都是**第一版、刻意做简单**的。
> 后续路线见 [`docs/ROADMAP.md`](docs/ROADMAP.md)。

## 棋盘与编码

- 90 格(10 行 × 9 列),`idx = 行×9 + 列`;行 0 是黑方底线(上),行 9 是红方底线(下),红先。
- 棋子:低 3 位为类型(`K` 将帅 / `A` 士 / `B` 象 / `N` 马 / `R` 车 / `C` 炮 / `P` 兵卒),bit3 为颜色(0 红 / 1 黑),0 为空。
- 走法:`from<<7 | to`(14 位)。UI 与 Worker 之间只传这一种编码,不搞两套。

## 引擎

`src/engine.js` 单文件(规则 + 评估 + 搜索),`src/worker.js` 只是 Worker 薄壳。
置换表、killer、history、着法缓冲全是模块级 `Int32Array`,搜索过程中**零分配**。

### 规则

车炮直线(炮需翻山)、马蹩腿、象塞眼且不过河、士将限九宫、兵只进不退(过河可横走)、
将帅对脸判非法。着法生成是「伪合法 + 逐个试走,剔除送将 / 对脸」。
终局:`-MATE + ply`,**将死与困毙都算负**(区分两者是 ROADMAP P0 的事)。

### 搜索(当前实际用了这些)

| 技术 | 现状 |
|---|---|
| negamax + alpha-beta | 有,但**全窗口** —— 还没做 PVS 零窗口试探 |
| 迭代加深 | 1..depth,每层回调 `onProgress` |
| 置换表 | 2^17 项;双 32 位 Zobrist 校验;存 着法/分数/深度/flag(精确/下界/上界);**总是替换**(还没做深度优先 + 世代替换) |
| 着法排序 | TT 着法 → MVV-LVA 吃子 → killer(每层 2 个)→ history(`+= depth²`) |
| killer / history 更新 | 只在**静着引发 beta 截断**时更新 |
| 静态搜索 | 只展开合法吃子 + stand-pat |
| 将军延伸 | 被将时 `depth + 1`(每个节点最多加一层,不递归叠加) |
| 根节点 | 用上一层分数排序;算到杀棋(分数绝对值 > `MATE-200`)就停止加深 |
| 中断 | 节点预算为主,每 1024 节点查一次墙上时间作兜底 |

**还没做**(见 ROADMAP P1):PVS、空着裁剪、LMR / futility、aspiration、杀棋搜索。

### 评估

子力(百分兵制,帅 6000)+ 4 张位置表(**车 / 马 / 炮 / 兵**;士象将没有 PST,黑方按镜像行查表)
+ tempo 8。参数是手调初值,**没有**自对弈拟合 / Texel 调参。

### 难度四档

节点预算为主、墙上时间为兜底(设备无关、可复现);初级另加 root jitter。
下表的「深度上限」是 `LEVELS[].depth`,**实测**是 `bench/bench.mjs nps` 在初始局面跑出来的:

| 档位 | 深度上限 | 节点预算 | 实测(初始局面) |
|---|---|---|---|
| 初级 | 2 | 20k | 1.1k 节点 / 25ms / **2 层**,jitter:最优解 60 分内随机挑 |
| 中级 | 4 | 150k | 36k 节点 / 129ms / **4 层** |
| 高级 | 6 | 600k | 600k(用满)/ 678ms / **5 层** |
| 大师 | 8 | 2M | 2M(用满)/ 2.30s / **6 层** |

性能:预算用满时约 **87 万节点/s**(Node 22 / 桌面级 CPU,数组棋盘)。
浅档 NPS 看着低是正常现象 —— 节点少,迭代与 TT 冷启动的开销占比高。

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
