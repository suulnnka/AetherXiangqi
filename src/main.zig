// AetherXiangqi — Xiangqi engine ported from AetherChess3's architecture
// (4ku-derived search, MIT). Modules: types.zig, board.zig (u128 bitboards,
// movegen, make/unmake, FEN, perft, hashing), eval.zig (temporary HCE until
// the distilled NNUE lands in P2), see.zig, tt.zig, search.zig, uci.zig,
// out.zig, tunables.zig.
const std = @import("std");
const board = @import("board.zig");
const tun = @import("tunables.zig");
const uci = @import("uci.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    // Tuned search constants from A3X_SEARCH_PARAMS (SPSA hook) — before
    // anything else so bench/search/uci all see the same values
    tun.init(init.environ);

    // Generate used attack tables and Zobrist keys
    board.init();

    // argv bench
    {
        var args = std.process.Args.Iterator.init(init.args);
        _ = args.next();
        if (args.next()) |a1| {
            if (std.mem.eql(u8, a1, "bench")) {
                uci.runBench();
                return;
            }
        }
    }

    uci.run();
}
