# AetherXiangqi 工程计划(Zig 版)

> 本文取代旧版 JS 时代路线图(旧内容在 git 历史 `v0.1-js` 可查)。
> 方向:**用 Zig 全面移植 AetherChess3 的架构**,评估用 **NNUE(蒸馏 Pikafish 教师网络)**,
> **不做开局库**,JS 引擎在 P0 删除。每个阶段都有验收门槛,不做完不算完。

---

## 1. 定位与总原则

1. **逐模块对应移植 AetherChess3**(本机 Zig 同为 0.16.0,惯用法直接照抄):
   `types / board / see / search / tt / tunables / uci / main / nnue / wasm / out` 全部对应;
   `book.zig`、`book.bin` **不移植**。
2. **评估两步走**:P1 引擎先带**临时 HCE**(子力+PST,数值取自 v0.1-js)保证可下、可测、可对拍;
   P2 由本地 **Pikafish 的 NNUE(教师)静态评估**蒸馏出自训小网(学生)换入,随后删除 HCE。
   教师标注**不做任何深度搜索**。
3. **盘面数据:下载 Px0 为主,自产随机走子为辅/兜底**(详见 §5)。
4. **磁盘硬上限 100 GB**,单列预算与管控(§7)。
5. JS 引擎删除:规则正确性改用「公开 perft 值 + Pikafish 二进制对拍」双重 oracle(§4.6)。
6. 单线程搜索(与 A3 一致);多线程不做。

## 2. 现状与资产

| 资产 | 用途 |
|---|---|
| `../AetherChess3`(Zig 0.16.0,MIT + 4ku MIT) | 架构蓝本,逐文件参照移植 |
| `../Pikafish.2026-09-06/Pikafish-Linux-x86-64-universal` | 教师 eval 进程、UCI 方言与规则对拍 oracle、强度标尺 |
| `../Pikafish.2026-09-06/pikafish.nnue`(50.7 MB zstd → 66 MB raw) | 教师网络(只通过二进制使用,不解析进引擎) |
| 本仓库 `pages/` + `src/worker.js` | 保留的 Web UI;worker 改为驱动 wasm(§9) |
| 本仓库 `src/engine.js`(JS 引擎) | **P0 删除**(先打 tag),git 历史留作开发期备用对照 |
| 环境:Zig 0.16.0 / Rust 1.98.1 / Python 3.14.6 / 16 核 / zstd 1.5.7 | 工具链事实,写死在文档避免漂移 |

教师网络架构(已解析,仅备查,不进引擎):双特征集
`full_threats`(45,547 维)+ `HalfKAv2_hm`(16,536 维)→ FT 1024 → 16 层栈 ×(2048→32→32→1),
SCReLU/CReLU,输出 scale 600。

## 3. 模块对应表(AetherChess3 → AetherXiangqi)

| AetherChess3 | 移植方式 |
|---|---|
| `types.zig` | 90 格、7 类棋子;`Move{from,to,promo}` 仍 3 字节,promo 字节空置 |
| `board.zig` | **重写棋规**,框架保留(§4) |
| `see.zig` | 交换算法保留;炮的隔屏吃破坏 x-ray 假设 → 每步从当前占位**重算**攻击者(§8.2) |
| `search.zig` | 骨架全量移植 + 象棋化改动(§8) |
| `tt.zig` | 原样移植(游戏无关:16B 条目 `{key u64, Move 3B, flag u8, score i16, depth i16}`,双槽:深度优先 + 永远替换,默认 64 MiB) |
| `nnue.zig` | 特征集 1260、桶公式、SCReLU、量化、rice 解码器原样;去 M1 镜像(§6);P2 落地 |
| (新增) `eval.zig` | **临时 HCE**(子力 + PST,数值取自 v0.1-js git 历史),P1–P2 间过渡,P2 后删除 |
| `tunables.zig` | 同机制,环境变量 `A3X_SEARCH_PARAMS / A3X_STACK_PARAMS / A3X_MAT_PARAMS` |
| `uci.zig` / `main.zig` | 同命令集 + debug 命令;bench 子命令(§9.1) |
| `wasm.zig` | 同导出面,90 格棋盘,wire 走法 `from<<7|to`(§9.2) |
| `out.zig` | 原样(着法串格式改象棋) |
| `book.zig` / `book.bin` | **不移植** |
| `tools/training/trainer2.rs` | → `tools/training/trainer.rs`(§10) |
| `tools/gen_rice.py` | 参数化沿用(网络头不变) |
| `tools/build-wasm.sh`、`wasm_diff_test.mjs`、`worker-test.mjs` | 沿用思路,象棋化 |
| (无对应) | **新增**:`datagen.zig`(盘面生成子命令)、`tools/teacher_label.mjs`(教师标注)、`tools/match.mjs`(SPRT 自对弈) |

## 4. 棋规与棋盘表示

### 4.1 坐标、FEN、着法

- **UCI 方言完全兼容 Pikafish**(GUI 即插即用):文件 `a`–`i`、行 `0`–`9`,**行 0 = 红方底线**,红大写。
  着法如 `h2e2`(炮二平五)。startpos FEN:
  `rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1`
- 棋子类型序:`P=0, A=1, B=2, N=3, R=4, C=5, K=6`(K 最后,同 A3 习惯);
  邮箱字节 `id = color*7 + type`(0..13),空 `0xFF`;color 0=红 1=黑。
- 现有 UI 内部坐标(第 0 行 = 黑方底线)与 UCI 坐标的换算只在 `wasm.zig` 一处完成(带单测)。

### 4.2 表示

- **u128 位棋盘**(Zig 原生):`colour[2]u128`(绝对色,不翻转)+ `pieces[7]u128` + `board[90]u8` 邮箱
  + `king_sq[2]u8` + 增量 `hash: u64` + `stm / halfmove`。结构对应 A3 `Position`。
- 预生成表:马可行点+蹩腿位、象可行点+塞眼位+过河限制、士/将宫内点、兵 `attacks[2][90]u128`
  (未过河直进 / 过河加横)、车四向射线、`between[90][90]u128`(将军掩码、照面、SEE 共用)。
- Zobrist:沿用 A3 的 MT19937_64(seed 5489,libstdc++ 淬火变体);键布局按 14×90 重排;
  行棋方 `hash ^= 1`。`make` 增量、`getHash` 全量重算,双通道对拍。

### 4.3 走法生成与 make/unmake

- **伪合法生成 + make 后验证**(与被删 JS 引擎同策略,正确性优先);
  A3 的 checkmask/pinmask 合法生成留作 P5 性能项。
- 将帅照面(飞将):进 `isAttacked`(王对王沿文件无阻挡视为受攻击)与走后合法性。
- `prepareMove / make / unmake` 两段式保留,删掉易位/EP/升变分支——象棋只有
  安静着(`-from +to`)与吃子(`-from +to -victim`)两种模式,累加器更新同样只有这两 pattern。

### 4.4 终局与和棋语义

- 无合法着法:**将死与困毙都 = `-mate + ply`**(规则上均为负)。
- 重复:搜索内 2-fold = 和(0);游戏层 3-fold 判定 + **简化长将规则**
  (循环窗口内单方每着均照将 → 该方负;双方均长将 → 和)。
- 60 回合无吃子判和;`halfmove` 与哈希历史窗口的清零点(吃子/兵着)
  以 **Pikafish 构造局面 `go depth 1` 对拍**为准,实施时校正。

### 4.5 perft 基准

startpos 逐层:**44 / 1,920 / 79,666 / 3,290,240**(d1–4,公开发表值)。
另构造专项 FEN:马腿、象眼、炮架、宫限、兵过河横走、照面、困毙、长将。
更深层(d5+)以 Pikafish `go perft N` 对拍为准。

### 4.6 规则 oracle(取代 JS 引擎)

1. 公开 perft 值(上表)。
2. **Pikafish 对拍**:我方引擎随机走子下完整随机对局,每个局面与 Pikafish 的
   `go perft 1`(合法着法数)比对;专项 FEN 上比对 `go perft 2..4`。
3. 开发期如需旧 JS 引擎对照,从 git 历史 `git show v0.1-js:src/engine.js` 取,不留在仓库。

## 5. 训练数据

### 5.1 来源 A:Px0 下载(主)

- Px0(Pika Xiangqi Zero,Pikafish 团队的 ODbL 数据)——**可以使用,注明许可即可**:
  - 下载源与分卷清单在实施首日定位(Pikafish README/Wiki 链接),先取最小分卷验证格式;
  - **合规**:README 与发布物注明「盘面数据源自 Px0(ODbL)」;本项目**只发布引擎与自训权重,
    不再分发数据库本身**,不触发 ODbL 的数据库再分发条款;
  - 自带的对局标签/搜索分仅作交叉校验,**评估标签一律由教师重打**(§6)。
- 若源不可用 / 格式无法解析 → 回退来源 B。

### 5.2 来源 B:自产随机走子(辅 + 兜底)

`aetherx datagen positions --n N --out pos.txt`(std.Thread 多 worker):
从 startpos 随机合法走子,混合两种采样:纯均匀随机、吃子/照将加权的随机;
走子数 0–~150 步混合覆盖开局/中局/残局;Zobrist 去重;跳过无合法着法的终局局面。

### 5.3 统一记录格式 `.aex2`(96 B/条,与 A3 的 72 B `.aet2` 同构)

| 偏移 | 字段 |
|---|---|
| 0–89 | `board[90]` 邮箱字节(`color*7+type`,`0xFF` 空) |
| 90 | `stm` |
| 91 | 保留 0 |
| 92–93 | `score` i16 LE(教师 cp,STM 视角,蒸馏主信号) |
| 94 | `result` u8(0 负 / 1 和 / 2 胜,STM 视角;蒸馏 λ=0 不用,留作未来 WDL) |
| 95 | 填充 0 |

P1 目标规模:**200 万 – 1000 万**条已标注记录(192–960 MB)。

## 6. 教师标注管线

- **教师 = 本地 Pikafish 二进制的静态 NNUE eval**,零搜索:
  UCI 流水 `position fen <X>` + `eval`,解析静态 NNUE 分值(白方视角 → STM 视角 cp)。
- `tools/teacher_label.mjs`:Node 进程池,每核一个 Pikafish 子进程,stdin 批量喂 FEN,
  汇总写出 `.aex2`(读 FEN 文本流 → 写 96B 记录)。
- **P0 首日验证项**(计划模式未能试跑,实施第一步):
  1. `eval` 输出格式、视角、精度(cp 粒度)、吞吐(单进程与 16 进程);
  2. 若精度/格式不足 → **B1**:`go depth 1`(准静态,仍非深搜);
  3. 终极兜底 **B2**:在 trainer.rs 内自行实现 pikafish.nnue 前向(布局已解析,§2,
     但 `full_threats` 特征抽取复杂,工作量大,非必要不做)。
- **尺度对齐**:教师 cp 空间 → 学生空间用 trainer 的 `--score-scale` 拟合
  (使学生网输出量级 ≈ 车 900、炮 450、马 400、兵 60;实施时对典型局面最小二乘拟合定值)。

## 7. 磁盘预算(硬上限 100 GB)

| 项 | 预算 |
|---|---|
| Px0 原始分卷(`data/raw_px0/`) | ≤ 60 G |
| `.aex2` 已标注数据(`data/aex2/`) | ≤ 25 G |
| 训练 checkpoint / 临时(`training/ckpt/`) | ≤ 5 G |
| 引擎构建、网络、工具产物 | < 1 G |
| 余量 | ≥ 9 G |

管控规则:

- 所有大数据放 `AetherXiangqi/data/` 与 `training/`(进 `.gitignore`,P0 添加)。
- **下载门禁**:取任何分卷前 `df` 查余量 + 确认分卷声明体积;总量超 60 G 即停。
- **转换即删**:`.aex2` 转换校验通过后立即删对应原始分卷。
- checkpoint 只保留最近 2 代,更旧的自动清理。
- 每阶段收尾汇报 `du -sh data/ training/`,超预算即触发清理流程。

## 8. 搜索移植(象棋化改动清单)

### 8.1 全量移植的技术(A3 `search.zig` 全家桶)

迭代加深、期望窗(宽度 = `asp_base + score²/16384`,失败倍增)、mate 距离剪枝、
检查延伸、ply 溢出保护、50/60 回合和棋、2-fold 重复、TT 取剪 + TT 修正静态分、
IIR、RFP、razoring、NMP(R = `4 + depth/5 + min((eval−beta)/196, 3)`,无验证搜索)、
单着延伸(SE,PV + depth≥7 + 排除键验证搜索)、着法定序(TT 着 → 历史 + 杀手/反着 +
MVV-LVA + 续着历史 + 坏吃子降级)、qsearch SEE 剪枝 / delta 剪枝、静着 SEE 剪枝、
FFP、LMR(`moves/13 + depth/14 + isPV + !improving − clamp(hist/128)` + 失败重搜)、
PVS、杀手、反着表、历史启发(深度² 加减分,重力 512)、LMP、
时间管理(预算 `time/3` + 稳定性伸缩 + 紧急 bestmove)、粘性停止标志。

### 8.2 改动点

| 项 | 改法 |
|---|---|
| 易位 / EP / 升变 | 全部删除(movegen、make、定序、delta、NMP 相关分支) |
| NMP 守卫 | 「本方有 车/马/炮」(替代国际象棋的非兵子力守卫) |
| 无合法着法 | 将死与困毙同为 `-mate + ply`(§4.4) |
| 重复 / 60 回合 | §4.4;细节对拍 Pikafish 校正 |
| 子力值表(`max_material` / SEE `piece_val`) | 初始值 P=60 A=110 B=110 N=400 R=900 C=450 K=10000;归入 `A3X_MAT_PARAMS` 供 SPSA |
| SEE | 交换算法骨架不变;攻击者集合每步从占位**重算**(含炮:目标方向上隔恰好一屏的炮;马/象按蹩腿/塞眼判定),不用增量 x-ray |
| qsearch | 仍吃子 + 照将延伸照旧(被将时全生成,A3 传统) |

## 9. UCI / WASM / Web

### 9.1 原生 UCI

- `id name AetherXiangqi`,二进制名 `aetherx`;命令:`uci / isready / ucinewgame /
  position(startpos|fen + 着法)/ go(wtime btime winc binc movetime depth nodes infinite)/ perft / quit`;
  debug 命令:`d / dmoves / dhash / deval`;`bench` 走 argv(24 个固定局面,记录基准节点数,后续位精确回归)。
- 选项首期仅 `Hash`;调优期加 `A3X_*` 由环境变量注入(同 A3,wasm 侧恒为默认)。

### 9.2 WASM / Web

- `tools/build-wasm.sh` 同参数(`wasm32-freestanding`,`-fno-entry -rdynamic`,ReleaseFast,strip);
  导出面同 A3:`engineInit/New/MovesBuf/Load/State/BoardPtr(90B)/Stm/LegalPtr/LegalCount/
  Check/Over/Result/Winner/EvalCp/Think(depth+node 限制)/Score/Depth/NodesLo/Hi/Bind/Perft`;
  静态缓冲、零运行时分配(同 A3)。
- **wire 走法 `from<<7|to` 与现有 UI 完全兼容**,`pages/` 零改动;
  中文着法 `moveToText` 移植到 `worker.js`(纯展示逻辑,读 wasm 棋盘字节)。
- 结果码:`0` 进行中 / `1` 将死 / `2` 困毙 / `3` 重复(含长将负,`winner` 区分)/ `4` 60 回合和。
- 消息协议保持 `ping / levels / state / think` 不变;**JS 引擎删除后、wasm 上线前,
  Pages 对局页暂时无 AI**(P0→P3 的窗口期,接受)。
- 体积预期:wasm gzip ≈ 80–90 KB(内嵌 ~55 KB rice 压缩网),旧 35 KB 预算随 JS 引擎一并废止。

## 10. 训练器(trainer2.rs → trainer.rs)

- 无框架 Rust,照 trainer2.rs 结构:镜像学生网 master 参数(f32)、
  SigmoidMPE(2.6)损失(**λ=0 纯蒸馏**:目标 = `sigmoid(教师cp·score_scale/400)`)、
  AdamW(wd 0.01,β₁ 0.9 / β₂ 0.999,权重硬截断 ±1.98)、线性衰减 LR、batch 16384、
  16 epochs、1% 验证集、Spearman 择优、shard 目录流式加载、`--ckpt` f32 断点、`--requant`。
- 特征索引 `(color*7+type)*90 + sq`(1260);桶 `(pieceCount−2)*7/30` clamp 0..7(象棋同为 2..32 子,公式原样)。
- 导出 **v4 int8+异常表**(magic `AENN`,ver 4,头 6×u32 + `(u32 idx + i16 真值)` 异常表 +
  `ft_w` i8 + `ft_b` i8 + `out_w/out_b` i16;QA=101 QV=160 SCALE=400 沿用,必要时连同 `score_scale` 一并重拟);
  `gen_rice.py` 压缩(“1REA” 容器,值无损)→ `@embedFile`。
- 换网流程:训练 → Spearman/MAE 达标 → `match.mjs` 自对弈 SPRT(LLR 通过)→ rice 压缩嵌入 → bench 基线更新。

## 11. 测试与验收(贯穿)

| 层 | 手段 | 门槛 |
|---|---|---|
| 棋规 | perft(d1–4 + 专项 FEN) | 与公开值 / Pikafish 逐位一致 |
| 棋规 | 随机对局对拍 | 每局面合法着法数与 Pikafish 一致,≥ 10⁴ 局面 |
| SEE/评估 | `see_test.zig` 象棋化;`deval` 增量 vs 全量重算 | 逐局面相等 |
| NNUE | 验证集 Spearman / MAE | Spearman ≥ 0.97(v0) |
| 搜索 | `bench` 固定节点数 | 位精确回归基线 |
| 对弈 | `match.mjs`(配对自对弈 SPRT)、vs Pikafish 限深 | 每次换网/换参过 SPRT |
| Web | `wasm_diff_test.mjs` + `worker-test.mjs` | 全绿 |

## 12. 阶段计划

### P0 —— 脚手架 + 棋规核心 + 管线验证 ✅(2026-09-30 完成)
- 建仓内结构:`build.zig`(默认 ReleaseFast;wasm 目标注释保留,P3 启用)、`src/types.zig`、`src/board.zig`;
  `.gitignore` 加 `data/`、`training/ckpt/`。
- **JS 引擎已删除**:tag `v0.1-js` → 删 `src/engine.js`/`src/worker.js`/`test/`/`bench/`;README/package.json 改版。
- 验收结果:startpos perft d1–5 = 44 / 1,920 / 79,666 / 3,290,240 / **133,312,995**(d5 与 Pikafish `go perft 5` 逐位一致,
  perft ≈ 41M nps);随机对局差分 **200 局 / 51,922 局面**合法着法集合与 Pikafish 完全一致
  (`tools/diff_vs_pikafish.py`;Pikafish 对 Rule60 超范围局面前会崩溃,脚本按 60 回合规则终局);
  增量 Zobrist 与全量重算 4,304 局面一致。过程中修复:FEN 颜色反转、九宫行越界、
  合法性捷径漏判(马腿揭将 / 炮架落点造将)、no_move 全零规范化。
- 教师管线首日验证(Pikafish `eval` 格式/吞吐)顺延至 P2 开工首日。

### P1 —— 引擎完整可用(搜索 + UCI,临时 HCE)✅(2026-09-30 完成,验收余一项)
- 已移植:`eval.zig(v0.1-js HCE)/ see(炮屏逐层重算)/ tt / search(A3 全家桶,NMP 守卫=有车马炮,
  困毙=负,60 回合=和)/ tunables(A3X_*)/ uci(Pikafish 方言 + dfen/dhash/dhashfull/dhm/deval/dmoves)/ main`。
- **bench 基线:968,907 节点 / ~1.5M nps**(13 局面,位精确回归;`./zig-out/bin/aetherx bench`)。
- ~~验收余项:vs Pikafish 限深对弈的等级差报告~~ → 已由 P2 后的对比覆盖:
  vs HCE(50k 节点)60-0-0;**vs 原版 JS 引擎 v0.1-js(tools/match_vs_js.mjs,等节点预算)
  50k 节点 100-0-0、200k 节点 40-0-0 —— 100% 胜率,差距 >400 Elo(碾压级)**。

### P2 —— 数据 + 学生网络(v0)→ 换入 NNUE ✅(2026-10-01 完成)
- **数据源(变更)**:Px0 Kaggle 源需凭据不可下;改用**用户提供的 Px0 对局包 archive.zip**
  (105 万盘 GBK PGN,ODbL 注明)。`tools/px0_extract.py` 重演中文着法(繁/简、全角数字、ICCS、
  前/后缀、士象同线进退消歧),105 万盘仅 0.02% 截断,提取 1740 万局面。
- **合法性过滤**:PGN 重演无完整规则校验,含污染局面(Pikafish 对其 CRITICAL ERROR 退出)。
  引擎新增 `fenfilter` 子命令(以已对拍的 isAttacked 判"非行棋方王不受攻击"+双王存在),
  33% 抽样后 5.75M → 5.19M(丢弃 9.7%);自产 20 万局面 100% 通过。
- **教师标注**:`tools/teacher_label.mjs`(14 进程持久管道 + 毒 FEN 二分隔离)产出 .aex2;
  教师单位标定:车≈1971、炮≈1367 units → `--score-scale 0.4565`(学生空间 车≈900)。
- **训练**:`tools/training/trainer.rs`(trainer2.rs 移植,1260 特征、λ=0 纯蒸馏、AdamW、
  v4 int8 导出)。v0:16 epochs / 1.6 分钟;v1:续训 100 epochs。**5.19M 记录,82.8 KB 网络**。
- **指标(如实记录,未达 0.97 门槛)**:独立 5 万 probe:Spearman **0.9296**、Pearson 0.942、
  MAE 132 cp;val loss 0.00139。Spearman 平台在 ~0.93,提升需更大数据量/更强采样(P5)。
- **换入**:nnue.zig(v4 解析 + 增量累加器 + SCReLU)接入搜索 ply 栈,eval.zig 已删除,NNUE-only。
- **Rice 嵌入(2026-10-01)**:`tools/gen_rice.py`(gen_rice.py 移植,1260 维)压缩 v4 网
  82,834B → **52,394B(63%)**,自校验往返;引擎 parseRice 解码器替换 raw 嵌入。
  验收:1000 局面 deval 与 raw 版逐值一致;bench 位精确 431,086。
- **验收结果**:`bench` 新基线 **431,086 节点**(HCE 968,907 的 44%,同深度搜索效率大增);
  perft 不变;一步杀/困毙正常;**自弈对拍 vs HCE(50k 节点/手):60 胜 0 负 0 和,全胜**。
- 磁盘:data/ 清理后 ~2.5 G(PGN 解压目录已按"转换即删"清理),预算内。

### P3 —— WASM + Web
- `wasm.zig` + 新 `worker.js`(懒加载 wasm,`moveToText` 移入)+ 结果码 + 差分/契约测试。
- **验收**:`wasm_diff_test` 全绿;Pages 对局页恢复 AI(wasm 后端);UI 零改动或仅换 levels 表。

### P4 —— SPSA 调优
- 移植三组 SPSA(search 15 / stack 9 / mat 6+),对弈后端用 `match.mjs`;
  采纳门槛:固定节点门 + 计时门。
- **验收**:首轮调优完成,基准 bench 更新,自对弈胜率提升有 SPRT 依据。

### P5 —— 可选增强(按需)
- 学生引导采样再蒸馏(90% 随机 + 10% 学生浅选,仍无深搜);
- 合法走法生成(checkmask/pinmask 化,照 A3 思路 + 照面/炮 pin 特例);
- 长将规则细化(长捉等《象棋竞赛规则》细则);
- 教师前向 B2 自实现(若吞吐成为再蒸馏瓶颈)。

## 13. 许可与合规

1. **引擎本体 MIT**(不变,含 4ku/MIT 派生搜索骨架的二次署名)。
2. **Px0 数据 ODbL**:使用时在 README/发布物注明来源与许可;不再分发数据库本身;
   若将来分发衍生数据集,按 ODbL 同许可发布。
3. **pikafish.nnue 教师**:其权重许可含「非商用」条款,蒸馏所得学生权重可能被视为衍生。
   自用 / 学习 / 非商用开源发布风险低;**若将来商用,需取得授权或改用自产数据重训**——在此明示。
   Pikafish 二进制(GPLv3)只作为本地工具运行,不复制其任何代码。

## 14. 风险与备选

| 风险 | 缓解 |
|---|---|
| `eval` 输出精度/格式不满足 | B1 `go depth 1`;B2 自实现前向(§6) |
| Px0 源失效或格式不解析 | 回退自产随机走子(§5.2),管线其余不变 |
| 炮/马腿在 SEE、将军判定中的边界错误 | 专项 FEN 单测 + Pikafish 对拍(§11) |
| 学生网太小,蒸馏上限不足 | hidden 64 起步,trainer 留参数;必要时 96/128 并按 SPRT 采纳 |
| 磁盘超 100 G | §7 门禁:下载前查量、转换即删、ckpt 只留 2 代 |
| Zig 0.16 stdlib 漂移 | 与 A3 同版本锁死,惯用法照抄 |

## 15. 交付物结构(完成后)

```
AetherXiangqi/
  build.zig  docs/ROADMAP.md  README.md
  src/            types board see search tt tunables uci main nnue datagen wasm out (.zig)
  src/aetherx.nnue(.rice)          # 自训学生网(嵌入)
  tools/         build-wasm.sh  gen_rice.py  teacher_label.mjs  match.mjs
                 wasm_diff_test.mjs  worker-test.mjs  spsa_*.py
  tools/training/  trainer.rs  Cargo.toml
  wasm/aetherx.wasm
  data/  training/                  # gitignore,受 §7 预算管控
  pages/ index.html                 # 原 UI 保留
```
