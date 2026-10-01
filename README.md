# AetherXiangqi

Zig 实现的中国象棋(Xiangqi)引擎,架构**全面移植自 [AetherChess3](https://github.com/suulnnka/AetherChess3)**
(Zig 0.16.0):合法走法生成、alpha-beta 全家桶搜索、NNUE 评估、
WASM 导出与零构建 Web UI。**不做开局库。**

**在线对弈**:[suulnnka.github.io/AetherXiangqi](https://suulnnka.github.io/AetherXiangqi/)
(对弈页 UI 移植自 [AetherWebOS](https://github.com/suulnnka/AetherWebOS) 的中国象棋应用,
[在线演示](https://suulnnka.github.io/AetherWebOS/))。

> 旧的纯 JS 引擎 v0.1 已移除,终态封存于 tag
> [`v0.1-js`](https://github.com/suulnnka/AetherXiangqi/tree/v0.1-js)
> (规则完整、perft 对齐公开值,仍可 `git show v0.1-js:src/engine.js` 取作对照)。
> **Zig 引擎已完成**:原生 UCI 二进制可用;WASM 版内嵌 NNUE,
> 在线对弈页 AI 已上线(GitHub Pages 零构建直接出页)。

工程纪要见 [`docs/ROADMAP.md`](docs/ROADMAP.md)。

## 布局

- `src/` — Zig 引擎(types / board / see / search / tt / nnue / tunables / uci / main / wasm / datagen / fenfilter / out)
- `tools/` — wasm 构建、对拍与调参脚本
- `pages/` `index.html` — 对弈页(SVG 棋盘 + 中文记谱,零构建)
- `wasm/` — 内嵌 NNUE 的 wasm 产物(随仓库提交,Pages 直接出页)
- `data/` `training/` — 本地数据(gitignore)

## 协议

UCI 象棋方言:文件 `a`–`i`、行 `0`–`9`
(0 = 红方底线),着法如 `h2e2`,FEN 如
`rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1`。

## License

MIT(见 [LICENSE](LICENSE);搜索骨架派生自 4ku,其 MIT 许可见
[LICENSE_4ku](LICENSE_4ku))。代码架构移植自
[AetherChess3](https://github.com/suulnnka/AetherChess3)(MIT)。盘面数据源自
Px0(ODbL,使用时注明)。
