// Temporary hand-crafted eval: material + 4 PSTs, values carried over from
// the deleted v0.1-js engine (git tag v0.1-js). Exists only so the P1 engine
// is playable and testable — the distilled NNUE replaces this module in P2
// and the file is deleted.
//
// PST layout is the v0.1-js "red view": row 0 = the FAR side (Black's back
// rank) from Red's perspective. A Red piece at internal row r indexes
// (9-r)*9 + col; a Black piece at row r indexes r*9 + col directly (both
// sides share one table through that mirror).
const types = @import("types.zig");

const Position = types.Position;
const Pawn = types.Pawn;
const Knight = types.Knight;
const Rook = types.Rook;
const Cannon = types.Cannon;

// [P, A, B, N, R, C, K, None] — King is huge but far below mate score so the
// engine never trades a rook for an advisor "because the king is worth more".
const mat = [8]i32{ 100, 200, 200, 400, 900, 450, 6000, 0 };

const pst_p = [90]i32{
    80, 80, 80, 90,  90, 90,  80, 80, 80,
    70, 75, 80, 85,  90, 85,  80, 75, 70,
    50, 55, 62, 70,  75, 70,  62, 55, 50,
    30, 35, 42, 55,  60, 55,  42, 35, 30,
    20, 22, 28, 40,  45, 40,  28, 22, 20,
    0,  0,  0,  6,   10, 6,   0,  0,  0,
    0,  0,  0,  0,   0,  0,   0,  0,  0,
    0,  0,  0,  0,   0,  0,   0,  0,  0,
    0,  0,  0,  0,   0,  0,   0,  0,  0,
    0,  0,  0,  0,   0,  0,   0,  0,  0,
};
const pst_n = [90]i32{
    4,   8,  16, 24,  20, 24,  16, 8,   4,
    4,   12, 20, 28,  24, 28,  20, 12,  4,
    12,  20, 28, 32,  28, 32,  28, 20,  12,
    12,  24, 32, 36,  32, 36,  32, 24,  12,
    8,   20, 28, 34,  30, 34,  28, 20,  8,
    4,   16, 24, 28,  26, 28,  24, 16,  4,
    0,   8,  16, 20,  20, 20,  16, 8,   0,
    -4,  0,  8,  12,  12, 12,  8,  0,   -4,
    -8,  -8, 0,  4,   4,  4,   0,  -8,  -8,
    -12, -12, -8, -4, 0,  -4,  -8, -12, -12,
};
const pst_r = [90]i32{
    10, 14, 14, 16, 16, 16, 14, 14, 10,
    12, 16, 16, 20, 20, 20, 16, 16, 12,
    10, 14, 14, 16, 18, 16, 14, 14, 10,
    8,  12, 12, 14, 16, 14, 12, 12, 8,
    6,  10, 10, 12, 14, 12, 10, 10, 6,
    4,  8,  8,  10, 12, 10, 8,  8,  4,
    2,  6,  6,  8,  10, 8,  6,  6,  2,
    0,  2,  4,  6,  8,  6,  4,  2,  0,
    0,  0,  2,  4,  6,  4,  2,  0,  0,
    -2, 0,  0,  2,  4,  2,  0,  0,  -2,
};
const pst_c = [90]i32{
    0,  0,  2,  6,  10, 6,  2,  0,  0,
    0,  2,  4,  8,  12, 8,  4,  2,  0,
    0,  2,  4,  8,  12, 8,  4,  2,  0,
    0,  2,  6,  10, 14, 10, 6,  2,  0,
    2,  4,  8,  12, 16, 12, 8,  4,  2,
    2,  6,  10, 14, 18, 14, 10, 6,  2,
    0,  2,  6,  8,  10, 8,  6,  2,  0,
    0,  0,  2,  4,  6,  4,  2,  0,  0,
    0,  0,  0,  2,  4,  2,  0,  0,  0,
    -2, 0,  0,  0,  2,  0,  0,  0,  -2,
};

const psts = [8]*const [90]i32{ &pst_p, &zeros, &zeros, &pst_n, &pst_r, &pst_c, &zeros, &zeros };
const zeros = [1]i32{0} ** 90;

/// Static eval in centipawns from the side-to-move's point of view.
pub fn evaluate(pos: *const Position) i32 {
    var score: i32 = 0;
    for (0..90) |sq| {
        const id = pos.board[sq];
        if (id == 0xFF) continue;
        const c = types.idColor(id);
        const t = types.idType(id);
        const r = sq / 9;
        const idx = if (c == 0) (9 - r) * 9 + sq % 9 else sq;
        const v = mat[t] + psts[t][idx];
        score += if (c == 0) v else -v;
    }
    return if (pos.stm == 0) score + 8 else -score + 8;
}
