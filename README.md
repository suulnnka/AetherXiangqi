# AetherXiangqi

Zig 实现的中国象棋(Xiangqi)引擎,架构**全面移植自 [AetherChess3](https://github.com/suulnnka/AetherChess3)**
(Zig 0.16.0):合法走法生成、alpha-beta 全家桶搜索、NNUE 评估(由 Pikafish 教师网络蒸馏)、
WASM 导出与零构建 Web UI。**不做开局库。**

> **状态:引擎重写中(Zig)。** 旧的纯 JS 引擎 v0.1 已移除,终态封存于 tag
> [`v0.1-js`](https://github.com/suulnnka/AetherXiangqi/tree/v0.1-js)(规则完整、perft 对齐公开值,
> 仍可 `git show v0.1-js:src/engine.js` 取作对照)。
> 因此**在线对弈页的 AI 暂时下线**,待 Zig 引擎的 WASM 版落地后恢复。

工程计划(阶段、架构、训练与数据管线、磁盘预算、验收门槛)见
[`docs/ROADMAP.md`](docs/ROADMAP.md)。

## 布局

- `src/` — Zig 引擎(types / board / see / search / tt / nnue / eval / tunables / uci / main / wasm)
- `tools/` — wasm 构建、教师标注、对拍与 SPSA 脚本;`tools/training/` 为 NNUE 训练器(Rust)
- `pages/` `index.html` — 对弈页(SVG 棋盘 + 中文记谱,零构建,GitHub Pages 直接出页)
- `data/` `training/` — 本地训练数据(gitignore;磁盘预算 100 G,见 ROADMAP §7)

## 协议

UCI 方言兼容 [Pikafish](https://github.com/official-pikafish/Pikafish):文件 `a`–`i`、行 `0`–`9`
(0 = 红方底线),着法如 `h2e2`,FEN 如
`rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1`。

## License

MIT。盘面数据源自 Px0(ODbL,使用时注明);教师网络 pikafish.nnue 仅本地用于蒸馏标注,
不分发其权重(许可注记见 ROADMAP §13)。
