// 阵型级开局谱:双方各自跟一套 3–4 步的定型着法,互不干扰(前四步布局
// 基本是各摆各的),走完或被干扰即弃谱进搜索。设计:
//   · 开局表平铺直叙 —— 条目/线只存 canonical 右翼着法串,不做任何折叠;
//   · 镜像(左翼对局)与命名合成(顺炮/对兵局等同动作异名)由本模块判定;
//   · 选择概率在配对表里:行=红方阵型(红方选阵另有一行边际分布),
//     列=黑方应法,0 = 引擎不选(认谱专用条目整体 playable=false);
//   · 每行合计 100,comptime 校验,手改数字漏配额直接编译失败。
//
// 体积策略:entries_src 是**仅供编译期阅读/求值**的源数据 —— 着法串、
// slice 指针与 LineDef/EntryDef 结构一概不进二进制;CT 块在 comptime 把
// 它编译成紧凑表(u8 坐标对 + 字符串表索引),rodata 只留下运行期真正
// 要输出的开局名/变着名一份。
//
// 查询是无状态的:每次用对局着法序列重放识别(本方着法是某条线的
// 前缀 → 可跟谱),所以 uci 的 position/moves 与 wasm 的 engineLoad 天然
// 兼容,不需要引擎侧维护选阵状态。护栏:候选着先过 movegen 合法性过滤
// 再抽签(对方吃了谱里的子/堵了通路 → 该变着出局,权重落到其余变着;
// 全部非法 → 弃谱进搜索)。
const std = @import("std");
const types = @import("types.zig");
const board = @import("board.zig");

const Position = types.Position;
const Move = types.Move;

// ---------------------------------------------------------------------------
// 源数据(仅编译期,不进二进制)
// ---------------------------------------------------------------------------
const Tag = enum { main, secondary, weak, trap, passive };

const LineDef = struct {
    moves: []const []const u8, // "h2e2" 风格,canonical 右翼
    w: u16, // entry 内选择权重
    suffix: ?[]const u8 = null, // 变着名(挂在本方第 after 步之后)
    after: u8 = 0,
    replace: bool = false, // true: suffix 替换基础名(五七炮等炮名)
};

const EntryDef = struct {
    name: []const u8,
    side: u8, // 0 红 1 黑
    playable: bool,
    name_after: u8, // 本方第几步定名(显示时机)
    tag: Tag = .main,
    lines: []const LineDef,
};

// 条目顺序即配对表索引:红方 playable 0..5,黑方 playable 自 16 起(列 0..10)。
const entries_src = [_]EntryDef{
    // ---- 红方(走)----
    .{ .name = "中炮", .side = 0, .playable = true, .name_after = 1, .lines = &.{
        .{ .moves = &.{ "h2e2", "h0g2", "i0h0", "h0h6" }, .w = 20, .suffix = "过河车", .after = 4 },
        .{ .moves = &.{ "h2e2", "h0g2", "i0h0", "h0h4" }, .w = 12, .suffix = "巡河车", .after = 4 },
        .{ .moves = &.{ "h2e2", "h0g2", "i0h0", "c3c4" }, .w = 12, .suffix = "进七兵", .after = 4 },
        .{ .moves = &.{ "h2e2", "h0g2", "i0i1" }, .w = 8, .suffix = "横车", .after = 3 },
        .{ .moves = &.{ "h2e2", "h0g2", "b0c2" }, .w = 10 },
        .{ .moves = &.{ "h2e2", "h0g2", "b0c2", "e3e4" }, .w = 8, .suffix = "盘头马", .after = 4 },
        .{ .moves = &.{ "h2e2", "h0g2", "b2c2" }, .w = 10, .suffix = "五七炮", .after = 3, .replace = true },
        .{ .moves = &.{ "h2e2", "h0g2", "b2d2" }, .w = 7, .suffix = "五六炮", .after = 3, .replace = true },
        .{ .moves = &.{ "h2e2", "h0g2", "b2a2" }, .w = 6, .suffix = "五九炮", .after = 3, .replace = true },
    } },
    .{ .name = "飞相局", .side = 0, .playable = true, .name_after = 1, .lines = &.{
        .{ .moves = &.{ "g0e2", "b0c2", "a0b0" }, .w = 10 },
        .{ .moves = &.{ "g0e2", "b0c2", "g3g4" }, .w = 6 },
        .{ .moves = &.{ "g0e2", "h0g2", "i0h0" }, .w = 4 },
    } },
    .{ .name = "仙人指路", .side = 0, .playable = true, .name_after = 1, .lines = &.{
        .{ .moves = &.{ "c3c4", "b0c2", "a0b0" }, .w = 10 },
        .{ .moves = &.{ "c3c4", "h2e2", "h0g2", "i0h0" }, .w = 6, .suffix = "转中炮", .after = 2 },
    } },
    .{ .name = "起马局", .side = 0, .playable = true, .name_after = 1, .lines = &.{
        .{ .moves = &.{ "h0g2", "g3g4", "b0c2" }, .w = 8 },
        .{ .moves = &.{ "h0g2", "c3c4", "b0c2" }, .w = 6 },
    } },
    .{ .name = "过宫炮", .side = 0, .playable = true, .name_after = 1, .lines = &.{
        .{ .moves = &.{ "h2d2", "h0g2", "i0h0" }, .w = 10 },
        .{ .moves = &.{ "h2d2", "h0g2", "b0c2" }, .w = 5 },
    } },
    .{ .name = "仕角炮", .side = 0, .playable = true, .name_after = 1, .lines = &.{
        .{ .moves = &.{ "h2f2", "h0g2", "i0h0" }, .w = 10 },
    } },
    // ---- 红方(认谱不走)----
    .{ .name = "巡河炮", .side = 0, .playable = false, .name_after = 1, .tag = .secondary, .lines = &.{
        .{ .moves = &.{ "h2h4", "h0g2", "b0c2" }, .w = 0 },
    } },
    .{ .name = "上仕局", .side = 0, .playable = false, .name_after = 1, .tag = .passive, .lines = &.{
        .{ .moves = &.{ "f0e1", "h0g2", "b0c2" }, .w = 0 },
    } },
    .{ .name = "边马局", .side = 0, .playable = false, .name_after = 1, .tag = .secondary, .lines = &.{
        .{ .moves = &.{ "h0i2", "i0h0", "b0c2" }, .w = 0 },
    } },
    .{ .name = "边炮局", .side = 0, .playable = false, .name_after = 1, .tag = .secondary, .lines = &.{
        .{ .moves = &.{ "h2i2", "h0g2", "i0h0" }, .w = 0 },
    } },
    .{ .name = "挺边兵", .side = 0, .playable = false, .name_after = 1, .tag = .weak, .lines = &.{
        .{ .moves = &.{ "i3i4", "h0g2", "b0c2" }, .w = 0 },
    } },
    // ---- 黑方(走)----
    .{ .name = "屏风马", .side = 1, .playable = true, .name_after = 2, .lines = &.{
        .{ .moves = &.{ "h9g7", "b9c7", "g6g5" }, .w = 12 },
        .{ .moves = &.{ "h9g7", "b9c7", "c6c5" }, .w = 8 },
        .{ .moves = &.{ "h9g7", "b9c7", "i9h9" }, .w = 6 },
        .{ .moves = &.{ "h9g7", "b9c7", "a9b9" }, .w = 4 },
        .{ .moves = &.{ "b9c7", "h9g7", "g6g5" }, .w = 6 }, // 换序定型
    } },
    .{ .name = "左中炮", .side = 1, .playable = true, .name_after = 1, .lines = &.{
        .{ .moves = &.{ "h7e7", "h9g7", "i9h9" }, .w = 12 },
        .{ .moves = &.{ "h7e7", "h9g7", "b9c7" }, .w = 6 },
    } },
    .{ .name = "列炮", .side = 1, .playable = true, .name_after = 1, .lines = &.{
        .{ .moves = &.{ "b7e7", "h9g7", "b9c7" }, .w = 8 },
        .{ .moves = &.{ "b7e7", "h9g7", "i9h9" }, .w = 4 },
    } },
    .{ .name = "左炮封车", .side = 1, .playable = true, .name_after = 1, .lines = &.{
        .{ .moves = &.{ "h7h3", "b9c7", "a9b9" }, .w = 8 },
        .{ .moves = &.{ "h7h3", "b9c7", "h9g7" }, .w = 4 },
    } },
    .{ .name = "反宫马", .side = 1, .playable = true, .name_after = 2, .lines = &.{
        .{ .moves = &.{ "b9c7", "h7f7", "h9g7" }, .w = 12 },
        .{ .moves = &.{ "b9c7", "h7f7", "h9g7", "i9h9" }, .w = 6 },
        .{ .moves = &.{ "h7f7", "b9c7", "h9g7" }, .w = 6 }, // 换序定型
    } },
    .{ .name = "过宫炮", .side = 1, .playable = true, .name_after = 2, .lines = &.{
        .{ .moves = &.{ "b7f7", "b9c7", "h9g7" }, .w = 8 },
    } },
    .{ .name = "单提马", .side = 1, .playable = true, .name_after = 2, .lines = &.{
        .{ .moves = &.{ "b9c7", "h9i7", "i9h9" }, .w = 6 },
    } },
    .{ .name = "飞象", .side = 1, .playable = true, .name_after = 1, .lines = &.{
        .{ .moves = &.{ "c9e7", "b9c7", "h9g7" }, .w = 10 },
        .{ .moves = &.{ "g9e7", "b9c7", "h9g7" }, .w = 6 }, // 顺象/逆象双翼
        .{ .moves = &.{ "c9e7", "h9g7", "b9c7" }, .w = 6 },
    } },
    .{ .name = "挺卒", .side = 1, .playable = true, .name_after = 1, .lines = &.{
        .{ .moves = &.{ "g6g5", "h9g7", "b9c7" }, .w = 10 },
        .{ .moves = &.{ "c6c5", "b9c7", "h9g7" }, .w = 6 },
    } },
    .{ .name = "左三步虎", .side = 1, .playable = true, .name_after = 3, .lines = &.{
        .{ .moves = &.{ "h7i7", "h9g7", "i9h9" }, .w = 8 },
    } },
    .{ .name = "卒底炮", .side = 1, .playable = true, .name_after = 1, .lines = &.{
        .{ .moves = &.{ "b7c7", "c9e7", "h9g7" }, .w = 6 },
        .{ .moves = &.{ "b7c7", "h9g7", "c9e7" }, .w = 4 },
    } },
    // ---- 黑方(认谱不走)----
    .{ .name = "上士局", .side = 1, .playable = false, .name_after = 1, .tag = .passive, .lines = &.{
        .{ .moves = &.{ "d9e8", "b9c7", "h9g7" }, .w = 0 },
    } },
    .{ .name = "挺中卒", .side = 1, .playable = false, .name_after = 1, .tag = .weak, .lines = &.{
        .{ .moves = &.{ "e6e5", "h9g7", "b9c7" }, .w = 0 },
    } },
    .{ .name = "龟背炮", .side = 1, .playable = false, .name_after = 1, .tag = .trap, .lines = &.{
        .{ .moves = &.{ "h7h8", "b9c7", "h8c8" }, .w = 0 },
    } },
    .{ .name = "鸳鸯炮", .side = 1, .playable = false, .name_after = 1, .tag = .trap, .lines = &.{
        .{ .moves = &.{ "b7b8", "h9g7" }, .w = 0 },
    } },
};

const RED_PLAYABLE: usize = 6;
const RED_RECOG: usize = 5;
const BLACK_FIRST: usize = RED_PLAYABLE + RED_RECOG; // 11:黑方 playable 起点
const BLACK_PLAYABLE: usize = 11;

// 红方选阵(边际分布)
const red_pct = [RED_PLAYABLE]u8{ 45, 15, 15, 10, 10, 5 };
// 黑方应法 | 红方阵型(条件分布;0 = 该组合不选)。列序 = 黑 playable 顺序
const reply_pct = [RED_PLAYABLE][BLACK_PLAYABLE]u8{
    .{ 36, 22, 6, 8, 14, 2, 3, 4, 3, 2, 0 }, // 中炮
    .{ 10, 24, 4, 0, 6, 8, 4, 20, 24, 0, 0 }, // 飞相局
    .{ 12, 8, 2, 0, 4, 0, 2, 16, 28, 0, 28 }, // 仙人指路
    .{ 18, 15, 0, 0, 10, 7, 0, 15, 35, 0, 0 }, // 起马局
    .{ 24, 28, 4, 0, 14, 6, 0, 10, 14, 0, 0 }, // 过宫炮
    .{ 22, 25, 0, 0, 8, 4, 0, 16, 25, 0, 0 }, // 仕角炮
};
// 红方阵型识别不上(罕见首着)时黑方的兜底分布
const marginal_pct = [BLACK_PLAYABLE]u8{ 22, 14, 6, 3, 12, 6, 4, 12, 14, 3, 4 };

// 特殊对局名:同一套黑方动作因红方而异名(其余按"红名对黑名"拼接)
const NameOverride = struct { red: usize, black: usize, name: []const u8 };
const overrides = [_]NameOverride{
    .{ .red = 0, .black = 1, .name = "中炮对顺炮" },
    .{ .red = 1, .black = 2, .name = "飞相局对右中炮" },
    .{ .red = 2, .black = 8, .name = "对兵局" },
};

comptime {
    var s: u16 = 0;
    for (red_pct) |v| s += v;
    if (s != 100) @compileError("red_pct must sum to 100");
    for (reply_pct) |row| {
        var t: u16 = 0;
        for (row) |v| t += v;
        if (t != 100) @compileError("reply_pct rows must sum to 100");
    }
    var m: u16 = 0;
    for (marginal_pct) |v| m += v;
    if (m != 100) @compileError("marginal_pct must sum to 100");
}

// ---------------------------------------------------------------------------
// 编译期表生成:源数据 → 紧凑 u8 表(rodata 里只有坐标对/权重/索引 +
// 一份去重的开局名/变着名字符串)
// ---------------------------------------------------------------------------
const MAX_LINE_MOVES = 4;
const MAX_GAME = 16; // 跟谱窗口:8 个回合(线最深本方 4 步)

const LineCT = struct {
    len: u8,
    moves: [MAX_LINE_MOVES]Move,
    w: u16,
    suffix: u8 = 255, // 字符串表索引;255 = 无变着名
    after: u8 = 0,
    replace: bool = false,
    entry: u8,
};

const EntryCT = struct {
    name: u8, // 字符串表索引
    side: u8,
    playable: bool,
    name_after: u8,
    line_start: u8,
    line_count: u8,
};

fn parseMC(s: []const u8) Move {
    return .{
        .from = (s[1] - '0') * 9 + (s[0] - 'a'),
        .to = (s[3] - '0') * 9 + (s[2] - 'a'),
    };
}

const CT = blk: {
    @setEvalBranchQuota(200000);
    var strs: [64][]const u8 = undefined;
    var nstr: usize = 0;
    var lin: [64]LineCT = undefined;
    var nlin: usize = 0;
    var ent: [entries_src.len]EntryCT = undefined;
    for (entries_src, 0..) |e, ei| {
        var name_idx: u8 = 255;
        for (strs[0..nstr], 0..) |s, si| {
            if (std.mem.eql(u8, s, e.name)) name_idx = @intCast(si);
        }
        if (name_idx == 255) {
            strs[nstr] = e.name;
            name_idx = @intCast(nstr);
            nstr += 1;
        }
        const ls = nlin;
        for (e.lines) |ld| {
            var mvs: [MAX_LINE_MOVES]Move = undefined;
            for (ld.moves, 0..) |ms, k| mvs[k] = parseMC(ms);
            var sfx: u8 = 255;
            if (ld.suffix) |sf| {
                for (strs[0..nstr], 0..) |s, si| {
                    if (std.mem.eql(u8, s, sf)) sfx = @intCast(si);
                }
                if (sfx == 255) {
                    strs[nstr] = sf;
                    sfx = @intCast(nstr);
                    nstr += 1;
                }
            }
            lin[nlin] = .{
                .len = @intCast(ld.moves.len),
                .moves = mvs,
                .w = ld.w,
                .suffix = sfx,
                .after = ld.after,
                .replace = ld.replace,
                .entry = @intCast(ei),
            };
            nlin += 1;
        }
        ent[ei] = .{
            .name = name_idx,
            .side = e.side,
            .playable = e.playable,
            .name_after = e.name_after,
            .line_start = @intCast(ls),
            .line_count = @intCast(nlin - ls),
        };
    }
    break :blk .{
        .strs = strs[0..nstr].*,
        .ents = ent,
        .lins = lin[0..nlin].*,
    };
};

const strings = CT.strs; // 运行期要输出的名字,rodata 仅此一份
const ents = CT.ents;
const lines = CT.lins;

// 红方 canonical 首着集合(playable + 认谱);左翼对局靠镜像识别
const canon_first = blk: {
    var c: [16]Move = undefined;
    var n: usize = 0;
    for (ents) |e| {
        if (e.side != 0) continue;
        const f = lines[e.line_start].moves[0];
        var dup = false;
        for (c[0..n]) |x| {
            if (x.from == f.from and x.to == f.to) dup = true;
        }
        if (!dup) {
            c[n] = f;
            n += 1;
        }
    }
    break :blk c[0..n].*;
};

// ---------------------------------------------------------------------------
// 镜像
// ---------------------------------------------------------------------------
/// 左右镜像(象棋规则左右对称):file -> 8-file
inline fn mir(sq: u8) u8 {
    return sq - (sq % 9) + (8 - sq % 9);
}

inline fn mirM(m: Move) Move {
    return .{ .from = mir(m.from), .to = mir(m.to) };
}

var inited = false;

pub fn init() void {
    if (inited) return;
    board.init();
    inited = true;
}

fn isCanonicalFirst(m: Move) bool {
    for (canon_first) |c| {
        if (c.from == m.from and c.to == m.to) return true;
    }
    return false;
}

/// 红首着是某 canonical 首着的镜像(且自身不是 canonical)→ 整局为左翼
fn isMirrorFirst(m: Move) bool {
    if (isCanonicalFirst(m)) return false;
    const mm = mirM(m);
    return isCanonicalFirst(mm);
}

/// 线与已走着法的松匹配(短者为前缀;出谱后仍保留,使命名持续显示)
fn linePrefixLoose(li: usize, own: []const Move) bool {
    const n = @min(@as(usize, lines[li].len), own.len);
    for (0..n) |k| {
        if (lines[li].moves[k].from != own[k].from or lines[li].moves[k].to != own[k].to)
            return false;
    }
    return true;
}

/// 识别一方的阵型条目(含认谱);未匹配返回 255
fn identifySide(side: u8, own: []const Move) u8 {
    for (ents, 0..) |e, ei| {
        if (e.side != side) continue;
        for (0..e.line_count) |k| {
            if (linePrefixLoose(e.line_start + k, own)) return @intCast(ei);
        }
    }
    return 255;
}

// ---------------------------------------------------------------------------
// Mulberry32(与 A3 book 同款,可复现;不引入 std.Random)
// ---------------------------------------------------------------------------
pub const Mulberry32 = struct {
    s: u32,
    pub fn next(m: *Mulberry32) u32 {
        m.s +%= 0x6D2B79F5;
        var t: u32 = m.s ^ (m.s >> 15);
        t *%= 1 | m.s;
        const t2: u32 = t ^ (t >> 7);
        t = (t +% (t2 *% (61 | t))) ^ t;
        return t ^ (t >> 14);
    }
};

// ---------------------------------------------------------------------------
// 跟谱查询
// ---------------------------------------------------------------------------

/// 当前行棋方的谱着:候选先过合法性过滤,再按权重抽签;全灭则 null(进搜索)。
pub fn probe(pos: *Position, game: []const Move, seed: u32) ?Move {
    init();
    if (game.len > MAX_GAME) return null;
    var gb: [MAX_GAME]Move = undefined;
    const flip = game.len > 0 and isMirrorFirst(game[0]);
    for (game, 0..) |m, i| gb[i] = if (flip) mirM(m) else m;
    const g = gb[0..game.len];

    const stm: u8 = @intCast(pos.stm & 1);
    var own: [MAX_LINE_MOVES]Move = undefined;
    var own_n: usize = 0;
    var i: usize = stm;
    while (i < g.len) : (i += 2) {
        own[own_n] = g[i];
        own_n += 1;
    }
    if (own_n >= MAX_LINE_MOVES) return null;

    // 黑方首应的配对权重行:识别红方阵型(仅 playable 红有专行)
    var pair_row: ?[]const u8 = null;
    if (stm == 1 and own_n == 0 and g.len >= 1) {
        var ro: [MAX_LINE_MOVES]Move = undefined;
        var rn: usize = 0;
        var j: usize = 0;
        while (j < g.len) : (j += 2) {
            ro[rn] = g[j];
            rn += 1;
        }
        const re = identifySide(0, ro[0..rn]);
        if (re != 255 and ents[re].playable)
            pair_row = reply_pct[re][0..]
        else
            pair_row = marginal_pct[0..];
    }

    // 候选收集 + 合法性过滤(movegen 输出即完全合法集)
    var legal: [256]Move = undefined;
    const legal_n: usize = @intCast(board.movegen(pos, &legal, false));

    const Cand = struct { m: Move, w: u32 };
    var cands: [64]Cand = undefined;
    var nc: usize = 0;
    for (ents, 0..) |e, ei| {
        if (e.side != stm or !e.playable) continue;
        const factor: u32 = if (stm == 0 and own_n == 0)
            red_pct[ei]
        else if (pair_row) |row|
            row[ei - BLACK_FIRST]
        else
            1;
        for (0..e.line_count) |k| {
            const li: usize = e.line_start + k;
            var next: ?Move = null;
            if (own_n == 0) {
                next = lines[li].moves[0];
            } else {
                const strict = own_n < lines[li].len and linePrefixLoose(li, own[0..own_n]);
                if (strict) next = lines[li].moves[own_n];
            }
            const m = next orelse continue;
            var ok = false;
            for (legal[0..legal_n]) |x| {
                if (x.from == m.from and x.to == m.to) ok = true;
            }
            if (!ok) continue;
            cands[nc] = .{ .m = m, .w = @as(u32, lines[li].w) * factor };
            nc += 1;
        }
    }
    if (nc == 0) return null;

    var sum: u32 = 0;
    for (cands[0..nc]) |c| sum += c.w;
    if (sum == 0) return null;
    var prng = Mulberry32{ .s = seed ^ @as(u32, @truncate(pos.hash)) };
    var t: i64 = @as(i64, prng.next() % sum);
    var pick: Move = cands[0].m;
    for (cands[0..nc]) |c| {
        t -= @as(i64, c.w);
        if (t < 0) {
            pick = c.m;
            break;
        }
    }
    return if (flip) mirM(pick) else pick;
}

// ---------------------------------------------------------------------------
// 开局命名(每步重算;name_after 决定显示时机)
// ---------------------------------------------------------------------------
fn put(buf: []u8, out: *usize, s: []const u8) bool {
    if (out.* + s.len > buf.len) return false;
    @memcpy(buf[out.*..][0..s.len], s);
    out.* += s.len;
    return true;
}

pub fn openingName(game: []const Move, buf: []u8) []const u8 {
    init();
    if (game.len == 0) return buf[0..0];
    const n = @min(game.len, MAX_GAME);
    var gb: [MAX_GAME]Move = undefined;
    const flip = isMirrorFirst(game[0]);
    for (game[0..n], 0..) |m, i| gb[i] = if (flip) mirM(m) else m;

    var ro: [MAX_LINE_MOVES]Move = undefined;
    var rn: usize = 0;
    var bo: [MAX_LINE_MOVES]Move = undefined;
    var bn: usize = 0;
    for (gb[0..n], 0..) |m, i| {
        if (i % 2 == 0) {
            ro[rn] = m;
            rn += 1;
        } else {
            bo[bn] = m;
            bn += 1;
        }
    }

    const re = identifySide(0, ro[0..rn]);
    const be = identifySide(1, bo[0..bn]);
    const red_ok = re != 255 and rn >= ents[re].name_after;
    const black_ok = be != 255 and bn >= ents[be].name_after;
    if (!red_ok and !black_ok) return buf[0..0];

    var out: usize = 0;

    // 特殊对名(顺炮/右中炮/对兵局:同动作异名)
    if (red_ok and black_ok and ents[re].playable and ents[be].playable) {
        const bcol = be - BLACK_FIRST;
        for (overrides) |o| {
            if (o.red == re and o.black == bcol) {
                _ = put(buf, &out, o.name);
                return buf[0..out];
            }
        }
    }

    if (red_ok) {
        // 变着名:仍在谱上的线若共享同一 suffix 且步数已到 → 显示
        var suf: u8 = 255;
        var agree = true;
        var replace = false;
        for (0..ents[re].line_count) |k| {
            const li: usize = ents[re].line_start + k;
            if (!linePrefixLoose(li, ro[0..rn])) continue;
            const ld = lines[li];
            if (ld.suffix == 255 or rn < ld.after) continue;
            if (suf != 255 and suf != ld.suffix) agree = false;
            suf = ld.suffix;
            replace = ld.replace;
        }
        if (suf != 255 and agree and replace) {
            _ = put(buf, &out, strings[suf]); // 炮名替换基础名
        } else {
            _ = put(buf, &out, strings[ents[re].name]);
            if (suf != 255 and agree)
                _ = put(buf, &out, strings[suf]);
        }
    }
    if (red_ok and black_ok)
        _ = put(buf, &out, "对");
    if (black_ok)
        _ = put(buf, &out, strings[ents[be].name]);
    return buf[0..out];
}

// ---------------------------------------------------------------------------
// 自检
// ---------------------------------------------------------------------------
const testing = std.testing;

test "所有谱线逐着合法(含镜像帧,交错对面垫着)" {
    init();
    // movegen 只生成行棋方的着法:黑方条目先垫红着再走本方;红方条目走完
    // 本方后垫黑着。垫着均为无害定型着,不与本方谱着争通路。
    const red_filler = [4][]const u8{ "h2e2", "h0g2", "i0h0", "c3c4" };
    const black_filler = [3][]const u8{ "h9g7", "b9c7", "g6g5" };
    for (ents, 0..) |e, ei| {
        _ = ei;
        for (0..e.line_count) |k| {
            const li: usize = e.line_start + k;
            for (0..2) |frame| {
                var pos: Position = undefined;
                board.setFen(&pos, board.startpos_fen);
                const fillers: []const []const u8 = if (e.side == 0) black_filler[0..] else red_filler[0..];
                for (0..lines[li].len) |mi| {
                    if (e.side == 1) {
                        var fm = parseMC(fillers[mi]);
                        if (frame == 1) fm = mirM(fm);
                        const finfo = board.prepareMove(&pos, fm);
                        _ = board.make(&pos, finfo, fm);
                    }
                    var m = lines[li].moves[mi];
                    if (frame == 1) m = mirM(m);
                    var list: [256]Move = undefined;
                    const n = board.movegen(&pos, &list, false);
                    var found = false;
                    for (list[0..@intCast(n)]) |x| {
                        if (x.from == m.from and x.to == m.to) found = true;
                    }
                    try testing.expect(found);
                    const minfo = board.prepareMove(&pos, m);
                    _ = board.make(&pos, minfo, m);
                    if (e.side == 0 and mi + 1 < lines[li].len) {
                        var fm = parseMC(fillers[mi]);
                        if (frame == 1) fm = mirM(fm);
                        const finfo = board.prepareMove(&pos, fm);
                        _ = board.make(&pos, finfo, fm);
                    }
                }
            }
        }
    }
}

fn gm(comptime ss: []const []const u8) [MAX_GAME]Move {
    var out: [MAX_GAME]Move = undefined;
    for (ss, 0..) |s, i| out[i] = parseMC(s);
    return out;
}

test "命名时机:中炮一步即显示,组合名随步数推进" {
    init();
    var buf: [96]u8 = undefined;

    const g1 = gm(&.{"h2e2"});
    try testing.expectEqualStrings("中炮", openingName(g1[0..1], &buf));

    const g2 = gm(&.{ "h2e2", "h7e7" });
    try testing.expectEqualStrings("中炮对顺炮", openingName(g2[0..2], &buf));

    const g3 = gm(&.{ "h2e2", "h9g7" });
    try testing.expectEqualStrings("中炮", openingName(g3[0..2], &buf)); // 屏风马未定型

    const g4 = gm(&.{ "h2e2", "h9g7", "h0g2", "b9c7" });
    try testing.expectEqualStrings("中炮对屏风马", openingName(g4[0..4], &buf));

    const g5 = gm(&.{ "h2e2", "h9g7", "h0g2", "b9c7", "i0h0", "g6g5", "h0h6" });
    try testing.expectEqualStrings("中炮过河车对屏风马", openingName(g5[0..7], &buf));

    const g6 = gm(&.{ "h2e2", "h9g7", "h0g2", "b9c7", "b2c2" });
    try testing.expectEqualStrings("五七炮对屏风马", openingName(g6[0..5], &buf));

    const g7 = gm(&.{ "c3c4", "g6g5" });
    try testing.expectEqualStrings("对兵局", openingName(g7[0..2], &buf));

    // 镜像对局:红走左中炮,名字一致
    const g8 = gm(&.{ "b2e2", "b7e7" });
    try testing.expectEqualStrings("中炮对顺炮", openingName(g8[0..2], &buf));

    // 认谱条目:黑上士局照常显示
    const g9 = gm(&.{ "h2e2", "d9e8" });
    try testing.expectEqualStrings("中炮对上士局", openingName(g9[0..2], &buf));
}

test "probe:红首着来自 playable 集合,黑首应受配对概率约束" {
    init();
    var pos: Position = undefined;
    board.setFen(&pos, board.startpos_fen);
    const legal_red_firsts = [_][2]u8{ .{ 25, 22 }, .{ 6, 22 }, .{ 29, 38 }, .{ 7, 24 }, .{ 25, 21 }, .{ 25, 23 } };
    var hits: [6]usize = .{ 0, 0, 0, 0, 0, 0 };
    for (0..200) |s| {
        const m = probe(&pos, &.{}, @as(u32, @truncate(s *% 2654435761))).?;
        var idx: ?usize = null;
        for (legal_red_firsts, 0..) |f, i| {
            if (f[0] == m.from and f[1] == m.to) idx = i;
        }
        try testing.expect(idx != null);
        hits[idx.?] += 1;
    }
    try testing.expect(hits[0] > 40); // 中炮 45% 权重应显著出现

    var pos2: Position = undefined;
    board.setFen(&pos2, board.startpos_fen);
    const m0 = parseMC("h2e2");
    const mi0 = board.prepareMove(&pos2, m0);
    _ = board.make(&pos2, mi0, m0);
    for (0..100) |s| {
        const m = probe(&pos2, &.{m0}, @as(u32, @truncate(s *% 7919 + 1))).?;
        // 对中炮,卒底炮配对为 0:黑炮 b7→c7 不该出现
        try testing.expect(!(m.from == 64 and m.to == 65));
    }
}

test "probe 护栏:谱着被挡时自动落到其余变着" {
    init();
    // 黑左炮封车 h7h3 压住红 h 线后,红的过河车 h0h6 / 巡河车 h0h4 均被
    // 炮挡住 → 候选只剩进七兵等仍合法的变着
    var pos: Position = undefined;
    board.setFen(&pos, board.startpos_fen);
    const seq = [_]Move{ parseMC("h2e2"), parseMC("h7h3"), parseMC("h0g2"), parseMC("b9c7"), parseMC("i0h0"), parseMC("h9g7") };
    for (seq) |m| {
        const minfo = board.prepareMove(&pos, m);
        _ = board.make(&pos, minfo, m);
    }
    const m = probe(&pos, &seq, 42).?;
    try testing.expect(!(m.from == 7 and m.to == 61)); // 过河车
    try testing.expect(!(m.from == 7 and m.to == 43)); // 巡河车
    try testing.expect(m.from == 29 and m.to == 38); // 进七兵
}
