// Static exchange evaluation — swap algorithm. Ported from AetherChess3's
// see.zig, but the cannon's screen requirement breaks the incremental x-ray
// assumption, so instead of revealing attackers behind removed pieces we
// recompute the attacker set from the current occupancy every swap step:
// screens appearing/disappearing and rook x-rays are then exact by
// construction. Slightly more work per step, SEE is only called for captures
// (qsearch prune / demotion) and hanging quiets.
const types = @import("types.zig");
const board = @import("board.zig");

const Position = types.Position;
const Move = types.Move;
const BB = types.BB;
const Pawn = types.Pawn;
const Advisor = types.Advisor;
const Elephant = types.Elephant;
const Knight = types.Knight;
const Rook = types.Rook;
const Cannon = types.Cannon;
const King = types.King;

// SEE piece values (v0.1-js HCE scale — the pruning thresholds in search are
// tuned against these via A3X_MAT_PARAMS).
pub const piece_val = [7]i32{ 100, 110, 110, 400, 900, 450, 10000 };

inline fn bit(s: u8) BB {
    return @as(BB, 1) << @intCast(s);
}

const Pick = struct { sq: u8, ty: usize };

/// All pieces of `side` attacking `to` under the given occupancy `occ`
/// (occupancy is passed separately because the mover has already been
/// removed). Kings never participate: the two kings can never be adjacent in
/// xiangqi and the flying-general line never ends on a capture target.
fn attackersTo(pos: *const Position, to: u8, occ: BB, side: usize) BB {
    const att = pos.colour[side];
    var a: BB = 0;

    a |= board.pawn_att_from[side][to] & att & pos.pieces[Pawn];

    // Horses: displacement-symmetric candidates, leg (near the horse) must be empty
    var hs = board.horse_moves[to] & att & pos.pieces[Knight];
    while (hs != 0) {
        const f: u8 = @intCast(@ctz(hs));
        hs &= hs - 1;
        if (occ & bit(board.horse_leg[f][to]) == 0) a |= bit(f);
    }

    // Advisors: palace-diagonal adjacency is symmetric
    a |= board.advisor_moves[to] & att & pos.pieces[Advisor];

    // Elephants: symmetric displacement, eye (midpoint) must be empty
    var es = board.elephant_moves[side][to] & att & pos.pieces[Elephant];
    while (es != 0) {
        const f: u8 = @intCast(@ctz(es));
        es &= es - 1;
        if (occ & bit(@intCast(@divTrunc(@as(i32, f) + to, 2))) == 0) a |= bit(f);
    }

    // Rooks (first blocker) and cannons (first piece behind one screen)
    inline for (0..4) |dir| {
        var screened = false;
        for (board.ray_sq[dir][to][0..board.ray_n[dir][to]]) |q| {
            const qb = bit(q);
            if (occ & qb == 0) continue;
            if (!screened) {
                if (att & pos.pieces[Rook] & qb != 0) a |= qb;
                screened = true;
            } else {
                if (att & pos.pieces[Cannon] & qb != 0) a |= qb;
                break;
            }
        }
    }

    return a;
}

fn lvaPick(pos: *const Position, to: u8, occ: BB, side: usize) ?Pick {
    const attackers = attackersTo(pos, to, occ, side);
    // ascending value order; King is never in the set (see above)
    const order = [6]usize{ Pawn, Advisor, Elephant, Knight, Cannon, Rook };
    inline for (order) |ty| {
        const b = attackers & pos.colour[side] & pos.pieces[ty];
        if (b != 0) return .{ .sq = @intCast(@ctz(b)), .ty = ty };
    }
    return null;
}

pub fn see(pos: *const Position, move: Move) i32 {
    const from = move.from;
    const to = move.to;

    const from_ty = types.idType(pos.board[from]);

    var occ = (pos.colour[0] | pos.colour[1]) & ~bit(from);
    var gain: [32]i32 = undefined;

    // Quiet moves (empty target) start the exchange at 0.
    gain[0] = if (pos.board[to] != 0xFF)
        piece_val[types.idType(pos.board[to])]
    else
        0;
    var attacker_ty = from_ty;
    var side: usize = pos.stm ^ 1;

    var d: usize = 0;
    while (d < 31) {
        const pick = lvaPick(pos, to, occ, side) orelse break;
        d += 1;
        gain[d] = piece_val[attacker_ty] - gain[d - 1];
        attacker_ty = pick.ty;
        occ &= ~bit(pick.sq);
        side ^= 1;
    }
    while (d > 0) {
        gain[d - 1] = -@max(-gain[d - 1], gain[d]);
        d -= 1;
    }
    return gain[0];
}
