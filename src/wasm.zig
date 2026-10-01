// wasm 导出层:C ABI、零导入、零运行时分配,浏览器 worker 直接加载(A3 模式)。
// 背后是本引擎的 NNUE 搜索 + 阵型级开局谱(跟谱窗口内直接返回谱着)。
//
// 坐标/编码翻译(协议侧保持 v0.1-js 约定,引擎侧用本引擎约定):
//   · 格子:协议 row0=黑方底线(上) ⇄ 引擎 row0=红方底线,一律 sq 翻转行:
//     conv(sq) = (9 - sq/9)*9 + sq%9(对合);
//   · 棋盘字节:(color<<3)|type,type:K=1 A=2 B=3 N=4 R=5 C=6 P=7,0 空,协议序;
//   · 线走法:(from<<7)|to,协议坐标 —— 与 UI 既有编码完全一致(无升变)。
//
// 结果码:0 进行中 / 1 将死 / 2 困毙(两者都是行棋方负)/ 3 三次重复 /
// 4 60 回合判和;3、4 时 winner=-1(worker 层按 UI 契约暂不转发为终局)。
const std = @import("std");
const types = @import("types.zig");
const board = @import("board.zig");
const nnue = @import("nnue.zig");
const book = @import("book.zig");
const tt = @import("tt.zig");
const search = @import("search.zig");

const Position = types.Position;
const Move = types.Move;
const moveEq = types.moveEq;
const no_move = types.no_move;
const None = types.None;

var pos: Position = .{};
var inited = false;

// ---- 静态资源(全部零分配)----
var ttBuf: [1 << 18]types.TTEntry = undefined; // 4 MB 运行时内存(零页)
var hhTable = std.mem.zeroes([2][2][90][90]i32);
var histBuf: [2048]u64 = undefined; // 对局历史 + 搜索路径
var hist: search.HistList = .{ .items = histBuf[0..0], .len = 0 };
var movesBuf: [256]Move = undefined;
var legalOut = [_]i32{0} ** 256; // 线格式(协议坐标)
var boardOut = [_]i8{0} ** 90; // 协议棋盘字节
var acc: nnue.Acc = undefined;

// 开局谱上下文:engineLoad 重演的完整着法序列(引擎坐标)+ 命名缓冲
var game_moves: [1024]Move = undefined;
var game_moves_len: usize = 0;
var opening_buf: [96]u8 = [_]u8{0} ** 96;

// state 回包事实
var legalCount: i32 = 0;
var checkOut: [2]i32 = .{ 0, 0 };
var overOut: i32 = 0;
var resultOut: i32 = 0;
var winnerOut: i32 = -1;
var lastNodes: u64 = 0;

fn ensureInit() void {
    if (inited) return;
    board.init(); // 攻击表 + Zobrist
    nnue.init(); // 内嵌 Rice 网
    tt.bindStatic(ttBuf[0..]);
    inited = true;
    resetGame();
}

fn resetGame() void {
    board.setFen(&pos, board.startpos_fen);
    search.cm_table = std.mem.zeroes([2][90][90]Move);
    search.cont_table = std.mem.zeroes([15][90][90]i16);
    hhTable = std.mem.zeroes([2][2][90][90]i32);
    @memset(tt.transposition_table, types.TTEntry{});
    hist = .{ .items = histBuf[0..], .len = 0 };
    game_moves_len = 0;
    opening_buf[0] = 0;
}

// ---------- 坐标/编码 ----------
inline fn conv(sq: u8) u8 {
    return @intCast(@as(usize, 9 - @as(usize, sq / 9)) * 9 + sq % 9);
}

/// 引擎类型序 P A B N R C K → 协议型值 K=1 A=2 B=3 N=4 R=5 C=6 P=7
const ui_type = [7]u8{ 7, 2, 3, 4, 5, 6, 1 };

fn wireMove(m: Move) i32 {
    return (@as(i32, conv(m.from)) << 7) | conv(m.to);
}

/// (from,to)(协议坐标)绑定到当前局面的合法着法
fn bindWire(from_w: i32, to_w: i32) ?Move {
    const n = board.movegen(&pos, &movesBuf, false);
    const from: u8 = conv(@intCast(from_w & 127));
    const to: u8 = conv(@intCast(to_w & 127));
    for (movesBuf[0..@intCast(n)]) |m| {
        if (m.from == from and m.to == to) return m;
    }
    return null;
}

// ---------- 生命周期 ----------
export fn engineInit() i32 {
    ensureInit();
    resetGame();
    return 0;
}
export fn engineNew() i32 {
    ensureInit();
    resetGame();
    return 0;
}

var inBuf = [_]i32{0} ** 512; // 输入走法序列(线格式)
export fn engineMovesBuf() i32 {
    ensureInit();
    return @intCast(@intFromPtr(&inBuf));
}

/// 从初始局面重演 n 步。1=成功 0=序列非法。对局历史全量 push
/// (本引擎的重复窗口由 halfmove——距上次吃子的步数——精确界定)。
export fn engineLoad(n: i32) i32 {
    ensureInit();
    resetGame();
    const cnt: usize = @intCast(@max(n, 0));
    if (cnt > inBuf.len) return 0;
    for (inBuf[0..cnt]) |line| {
        const mv = bindWire(line >> 7, line & 127) orelse return 0;
        const minfo = board.prepareMove(&pos, mv);
        _ = board.make(&pos, minfo, mv);
        hist.push(pos.hash);
        if (game_moves_len < game_moves.len) {
            game_moves[game_moves_len] = mv;
            game_moves_len += 1;
        }
    }
    return 1;
}

// ---------- state ----------
export fn engineState() i32 {
    ensureInit();
    const n = board.movegen(&pos, &movesBuf, false);
    var w: usize = 0;
    for (movesBuf[0..@intCast(n)]) |m| {
        legalOut[w] = wireMove(m);
        w += 1;
    }
    legalCount = @intCast(w);
    const nm = book.openingName(game_moves[0..game_moves_len], &opening_buf);
    opening_buf[nm.len] = 0;
    const stm: usize = pos.stm;
    checkOut[0] = board.isAttacked(&pos, pos.king_sq[0], 1);
    checkOut[1] = board.isAttacked(&pos, pos.king_sq[1], 0);
    overOut = 0;
    resultOut = 0;
    winnerOut = -1;
    if (w == 0) {
        // 将死与困毙:行棋方均负(winner 恒为 1-stm;UI 靠 checked 区分两者)
        overOut = 1;
        resultOut = if (checkOut[stm] != 0) 1 else 2;
        winnerOut = @intCast(1 - stm);
    } else if (threefold()) {
        overOut = 1;
        resultOut = 3;
    } else if (pos.halfmove >= 120) {
        overOut = 1;
        resultOut = 4; // 60 回合无吃子
    }
    return 1;
}

fn threefold() bool {
    var c: usize = 0;
    for (histBuf[0..hist.len]) |h| {
        if (h == pos.hash) c += 1;
    }
    return c >= 2; // 历史 2 次 + 当前
}

export fn engineBoardPtr() i32 {
    ensureInit();
    for (0..90) |i| {
        const id = pos.board[i];
        boardOut[conv(@intCast(i))] = if (id == 0xFF)
            0
        else
            @intCast((@as(usize, types.idColor(id)) << 3) | ui_type[types.idType(id)]);
    }
    return @intCast(@intFromPtr(&boardOut));
}
export fn engineStm() i32 {
    ensureInit();
    return pos.stm;
}
export fn engineLegalPtr() i32 {
    return @intCast(@intFromPtr(&legalOut));
}
export fn engineLegalCount() i32 {
    return legalCount;
}
export fn engineCheck(side: i32) i32 {
    return checkOut[@intCast(@as(u32, @bitCast(side)) & 1)];
}
export fn engineOver() i32 {
    return overOut;
}
export fn engineResult() i32 {
    return resultOut;
}
export fn engineWinner() i32 {
    return winnerOut;
}

export fn engineEvalCp() i32 {
    ensureInit();
    nnue.refreshAcc(&pos, &acc);
    return nnue.evalAcc(&pos, &acc);
}

/// 当前开局名(UTF-8 C 字符串;空串 = 未识别)。engineState 时更新。
export fn engineOpeningPtr() i32 {
    return @intCast(@intFromPtr(&opening_buf));
}

// ---------- 搜索 ----------
/// seed 由 worker 传入(wasm 无墙钟),保证对局间开局抽签有随机性
export fn engineThink(depthMax: i32, nodeLimit: i32, seed: i32) i32 {
    ensureInit();
    if (book.probe(&pos, game_moves[0..game_moves_len], @as(u32, @bitCast(seed)))) |bm| {
        search.last_nodes = 0;
        search.last_depth = 0;
        search.last_score = 0;
        lastNodes = 0;
        return wireMove(bm);
    }
    search.limits = .{ .depth = @max(depthMax, 0), .nodes = 0, .soft = false };
    if (nodeLimit > 0) search.limits.nodes = @intCast(nodeLimit);
    search.hard_stop = std.math.maxInt(u64); // 无墙钟:节点/深度是唯一上限
    var dummy: u64 = 0;
    const mv = search.iterativelyDeepen(&pos, &hist, &hhTable, 0, &dummy, 1 << 30, types.now());
    lastNodes = search.last_nodes;
    if (moveEq(mv, no_move)) return 0;
    return wireMove(mv);
}
export fn engineScore() i32 {
    return search.last_score;
}
export fn engineDepth() i32 {
    return search.last_depth;
}
export fn engineNodesLo() i32 {
    return @bitCast(@as(u32, @truncate(lastNodes)));
}
export fn engineNodesHi() i32 {
    return @bitCast(@as(u32, @truncate(lastNodes >> 32)));
}

export fn engineBind(from: i32, to: i32) i32 {
    ensureInit();
    const mv = bindWire(from, to) orelse return 0;
    return wireMove(mv);
}

// ---------- perft ----------
var lastPerft: u64 = 0;
export fn enginePerft(depth: i32) i32 {
    ensureInit();
    lastPerft = board.perft(&pos, @max(depth, 0));
    return @bitCast(@as(u32, @truncate(lastPerft)));
}
export fn enginePerftHi() i32 {
    return @bitCast(@as(u32, @truncate(lastPerft >> 32)));
}
