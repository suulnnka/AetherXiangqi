// NNUE consistency test: over random playouts, the incrementally-updated
// accumulator path (refreshAcc + applyMoveDeltasAcc per move) must produce
// exactly the same eval as a full rebuild (refreshAcc) after every move.
// Run: zig test src/nnue_test.zig
const std = @import("std");
const types = @import("types.zig");
const board = @import("board.zig");
const nnue = @import("nnue.zig");

const Position = types.Position;
const Move = types.Move;

var rng_s: u64 = 0x12345678;
fn rnd() u64 {
    rng_s ^= rng_s >> 12;
    rng_s ^= rng_s << 25;
    rng_s ^= rng_s >> 27;
    return rng_s *% 0x2545F4914F6CDD1D;
}

test "incremental accumulator == full rebuild" {
    board.init();
    nnue.init();

    var pos = Position{};
    var moves_history: [512]Move = undefined;
    var hist_n: usize = 0;
    var acc: nnue.Acc = undefined;
    nnue.refreshAcc(&pos, &acc);

    var checked: usize = 0;
    var games: usize = 0;
    while (games < 200) : (games += 1) {
        board.setFen(&pos, board.startpos_fen);
        hist_n = 0;
        nnue.refreshAcc(&pos, &acc);
        var ply: usize = 0;
        while (ply < 160) : (ply += 1) {
            var moves: [256]Move = undefined;
            const n = board.movegen(&pos, &moves, false);
            if (n == 0) break;
            if (pos.halfmove >= 118) break;
            const mv = moves[rnd() % @as(u64, @intCast(n))];
            const minfo = board.prepareMove(&pos, mv);
            _ = board.make(&pos, minfo, mv);
            nnue.applyMoveDeltasAcc(&acc, &acc, minfo.us, minfo.piece, minfo.from, minfo.to, minfo.victim_ty, minfo.victim_sq);
            moves_history[hist_n] = mv;
            hist_n += 1;

            // full rebuild from scratch must equal the incremental accumulator
            var fresh: nnue.Acc = undefined;
            nnue.refreshAcc(&pos, &fresh);
            const e_inc = nnue.evalAcc(&pos, &acc);
            const e_full = nnue.evalAcc(&pos, &fresh);
            if (e_inc != e_full) {
                std.debug.print("MISMATCH at game {d} ply {d}: inc {d} vs full {d}\n", .{ games, ply, e_inc, e_full });
                return error.Mismatch;
            }
            checked += 1;
        }
    }
    std.debug.print("nnue accumulator consistency: {d} positions OK\n", .{checked});
}
