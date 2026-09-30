// Shared constants, core data types, and small utilities.
// Ported from AetherChess3's types.zig for Xiangqi: 90 squares (sq = row*9+col,
// row 0 = Red's back rank = rank '0', col 0 = file 'a'), 7 piece types,
// u128 bitboards. Absolute colours: colour[0] is always Red, [1] always Black.
const std = @import("std");
const linux = std.os.linux;

pub const mate_score: i32 = 30000;
pub const inf: i32 = 32000;

// Piece type order: ascending typical value, King last (A3 habit).
pub const Pawn: usize = 0; // 兵 / 卒
pub const Advisor: usize = 1; // 仕 / 士
pub const Elephant: usize = 2; // 相 / 象
pub const Knight: usize = 3; // 马 / 馬
pub const Rook: usize = 4; // 车 / 車
pub const Cannon: usize = 5; // 炮 / 砲
pub const King: usize = 6; // 帅 / 將
pub const None: usize = 7;

// Static eval using the TT and TT cutoffs rely on this specific ordering, do not change it.
pub const Upper: u8 = 0;
pub const Lower: u8 = 1;
pub const Exact: u8 = 2;

pub const BB = u128;

pub const Position = struct {
    colour: [2]BB = .{ 0, 0 }, // absolute: [0] Red, [1] Black
    pieces: [7]BB = .{ 0, 0, 0, 0, 0, 0, 0 },
    stm: u8 = 0, // side to move: 0 Red, 1 Black
    halfmove: u16 = 0, // plies since last capture (60-move rule + repetition window)
    king_sq: [2]u8 = .{ 4, 85 }, // e0 / e9
    board: [90]u8 = [_]u8{0xFF} ** 90, // mailbox: piece id (color*7+type), 0xFF empty
    hash: u64 = 0, // incremental Zobrist hash (maintained by make/unmake)
};

pub inline fn idColor(id: u8) usize {
    return id / 7;
}

pub inline fn idType(id: u8) usize {
    return id % 7;
}

pub const Move = extern struct {
    from: u8 = 0,
    to: u8 = 0,
    promo: u8 = 0, // always None in xiangqi; kept for layout parity with A3
};

// All-zero encoding, matching A3: zeroed memory (zeroes() stacks, zeroed TT
// and killer slots) then compares equal to no_move — a real move never has
// from == to, so {0,0,0} cannot collide with one.
pub const no_move = Move{};

pub fn moveEq(lhs: Move, rhs: Move) bool {
    return lhs.from == rhs.from and lhs.to == rhs.to and lhs.promo == rhs.promo;
}

pub const Stack = struct {
    moves: [256]Move = undefined,
    moves_evaluated: [256]Move = undefined,
    move_scores: [256]i32 = undefined,
    move: Move = no_move,
    killer: Move = no_move,
    current: Move = no_move, // move currently being searched at this ply
    se_ext: bool = false, // this line already used a singular extension (no back-to-back)
    current_pt: u8 = 0, // mover piece id (color*7+type) of `current` (conthist context)
    score: i32 = 0,
};

pub const TTEntry = extern struct {
    key: u64 = 0,
    move: Move = no_move,
    flag: u8 = 0,
    score: i16 = 0,
    depth: i16 = 0,
};

comptime {
    std.debug.assert(@sizeOf(Move) == 3);
    std.debug.assert(@sizeOf(TTEntry) == 16);
}

// ---------------------------------------------------------------------------
// Time — CLOCK_MONOTONIC in ms (wasm has no wall clock; callers use limits)
// ---------------------------------------------------------------------------
pub fn now() u64 {
    if (@import("builtin").target.cpu.arch == .wasm32)
        return 0;
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
    const v = @as(f64, @floatFromInt(ts.sec)) * 1000.0 + @as(f64, @floatFromInt(ts.nsec)) / 1e6;
    return @intFromFloat(@trunc(v));
}

pub const page_alloc = std.heap.page_allocator;
