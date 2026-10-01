# AetherXiangqi 工程纪要(Zig 版)

旧版纯 JS 引擎(v0.1)已删除,终态封存于 tag `v0.1-js`;本项目为 Zig 重写版,分五个阶段完成:

- **架构**:逐模块移植 [AetherChess3](https://github.com/suulnnka/AetherChess3)
  (Zig 0.16.0;搜索骨架派生自 4ku)——u128 位棋盘、伪合法生成 + make 后验证、
  PVS 全家桶搜索、NNUE 评估(v4 int8 网络,Rice 压缩嵌入)、置换表、环境变量可调参数。
- **阶段**:P0 棋规核心 → P1 搜索 + UCI(临时 HCE)→ P2 换入 NNUE(v1 最终网)
  → P3 WASM + Web(对弈页 AI 上线)→ P4 SPSA 调参一轮(无改进,不采纳)。全部完成。
- **验收基线**:startpos perft d1–5 = 44 / 1,920 / 79,666 / 3,290,240 / 133,312,995
  (对齐公开值);`bench` 431,086 节点位精确回归;wasm 与原生引擎逐局面一致。
- **数据**:盘面数据源自 Px0(ODbL,使用时注明)。
- **遗留可选项**:checkmask/pinmask 合法生成、长捉等《象棋竞赛规则》细则。
