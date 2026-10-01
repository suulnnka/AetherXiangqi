// Board representation, attack generation, movegen, make/unmake, FEN, perft
// and Zobrist hashing for Xiangqi (9x10, 90 squares). Ported in structure
// from AetherChess3's board.zig; all chess-specific logic replaced.
//
// Squares: sq = row*9 + col. Row 0 = Red's back rank (rank '0'), row 9 =
// Black's back rank (rank '9'); col 0 = file 'a' ... col 8 = file 'i'.
// Red moves toward increasing row ("north"), Black toward decreasing row.
// Bitboards are u128 (90 > 64). Absolute colours: colour[0] = Red, [1] = Black.
const std = @import("std");
const types = @import("types.zig");

const Position = types.Position;
const Move = types.Move;
const Pawn = types.Pawn;
const Advisor = types.Advisor;
const Elephant = types.Elephant;
const Knight = types.Knight;
const Rook = types.Rook;
const Cannon = types.Cannon;
const King = types.King;
const None = types.None;
const BB = types.BB;

pub const startpos_fen = "rnbakabnr/9/1c5c1/p1p1p1p1p/9/9/P1P1P1P1P/1C5C1/9/RNBAKABNR w - - 0 1";

// ---------------------------------------------------------------------------
// Globals: precomputed attack tables and Zobrist keys
// ---------------------------------------------------------------------------
pub var king_moves: [90]BB = undefined; // ortho 1-step inside the palace containing sq
pub var advisor_moves: [90]BB = undefined; // diag 1-step inside the palace containing sq
pub var elephant_moves: [2][90]BB = undefined; // diag 2-step, own half only (eye checked at use)
pub var horse_moves: [90]BB = undefined; // displacement-symmetric knight targets
pub var horse_leg: [90][90]u8 = undefined; // blocking leg square of the from->to horse move, 0xFF invalid
pub var pawn_moves: [2][90]BB = undefined; // moves a color-c pawn at sq may make
pub var pawn_att_from: [2][90]BB = undefined; // squares from which a color-c pawn attacks sq
pub var ray_sq: [4][90][9]u8 = undefined; // ordered squares along each orthogonal direction
pub var ray_n: [4][90]u8 = undefined;
pub var between: [90][90]BB = undefined; // squares strictly between two orthogonally aligned squares
pub var keys: [14 * 90]u64 = undefined; // Zobrist: (color*7+type)*90 + sq

// Direction indices for ray_sq: 0 = +row (north), 1 = -row, 2 = +col, 3 = -col.

pub inline fn bit(sq: u8) BB {
    return @as(BB, 1) << @intCast(sq);
}

inline fn bitRC(r: i32, c: i32) BB {
    return @as(BB, 1) << @intCast(r * 9 + c);
}

pub inline fn rowOf(sq: u8) u8 {
    return sq / 9;
}

pub inline fn colOf(sq: u8) u8 {
    return sq % 9;
}

/// Which palace contains (r, c): 0 Red (rows 0-2), 1 Black (rows 7-9), else -1.
fn inPalace(r: i32, c: i32) i32 {
    if (r < 0 or r > 9 or c < 0 or c > 8) return -1;
    if (c < 3 or c > 5) return -1;
    if (r <= 2) return 0;
    if (r >= 7) return 1;
    return -1;
}

// ---------------------------------------------------------------------------
// Attack queries
// ---------------------------------------------------------------------------
pub inline fn pieceOn(pos: *const Position, sq: u8) i32 {
    const id = pos.board[sq];
    return if (id == 0xFF) @intCast(None) else @intCast(types.idType(id));
}

/// Is `sq` attacked by colour `attacker`? Covers pawn / horse (leg-checked) /
/// rook / cannon (screen-checked) and the flying-general king line. The
/// king-line test only applies when sq is the defender's king square, which
/// is the only way this function is used (check detection + legality filter).
pub fn isAttacked(pos: *const Position, sq: i32, attacker: usize) i32 {
    const s: u8 = @intCast(sq);
    const att = pos.colour[attacker];
    const occ = pos.colour[0] | pos.colour[1];

    if (pawn_att_from[attacker][s] & att & pos.pieces[Pawn] != 0) return 1;

    var hs = horse_moves[s] & att & pos.pieces[Knight];
    while (hs != 0) {
        const f: u8 = @intCast(@ctz(hs));
        hs &= hs - 1;
        if (occ & bit(horse_leg[f][s]) == 0) return 1;
    }

    inline for (0..4) |dir| {
        var screened = false;
        for (ray_sq[dir][s][0..ray_n[dir][s]]) |q| {
            const qb = bit(q);
            if (occ & qb == 0) continue;
            if (!screened) {
                if (att & pos.pieces[Rook] & qb != 0) return 1;
                screened = true;
            } else {
                if (att & pos.pieces[Cannon] & qb != 0) return 1;
                break;
            }
        }
    }

    // Flying general: kings facing on an open file.
    if (pos.king_sq[attacker ^ 1] == s) {
        const eksq = pos.king_sq[attacker];
        if (colOf(eksq) == colOf(s) and between[eksq][s] & occ == 0) return 1;
    }
    return 0;
}

// ---------------------------------------------------------------------------
// make / unmake — board mutated in place (A3 scheme, minus castling/EP/promo)
// ---------------------------------------------------------------------------
pub const MoveInfo = struct {
    us: usize,
    piece: usize,
    from: u8,
    to: u8,
    victim_ty: usize, // None if no capture
    victim_sq: u8, // == to in xiangqi (no en passant)
};

pub const Undo = struct {
    captured_id: u8, // 0xFF if none
    hash: u64,
    halfmove: u16,
};

pub fn prepareMove(pos: *const Position, move: Move) MoveInfo {
    const us: usize = pos.stm;
    const piece: usize = types.idType(pos.board[move.from]);
    const captured = pos.board[move.to] != 0xFF;
    return .{
        .us = us,
        .piece = piece,
        .from = move.from,
        .to = move.to,
        .victim_ty = if (captured) types.idType(pos.board[move.to]) else None,
        .victim_sq = move.to,
    };
}

pub fn make(pos: *Position, info: MoveInfo, move: Move) Undo {
    const from_bit = bit(move.from);
    const to_bit = bit(move.to);
    const mask = from_bit | to_bit;
    const us = info.us;
    const them = us ^ 1;
    const captured = pos.board[move.to] != 0xFF;

    const undo = Undo{
        .captured_id = pos.board[move.to],
        .hash = pos.hash,
        .halfmove = pos.halfmove,
    };

    pos.colour[us] ^= mask;
    pos.pieces[info.piece] ^= mask;
    pos.board[move.from] = 0xFF;
    pos.board[move.to] = @intCast(us * 7 + info.piece);

    if (captured) {
        pos.colour[them] ^= to_bit;
        pos.pieces[info.victim_ty] ^= to_bit;
    }

    if (info.piece == King)
        pos.king_sq[us] = move.to;

    pos.stm = @intCast(them);

    // Xiangqi natural-draw clock: plies since the last capture (a position
    // can only repeat with unchanged material, so this also bounds the
    // repetition scan window).
    pos.halfmove = if (captured) 0 else pos.halfmove + 1;

    pos.hash ^= 1 ^ keyOf(us, info.piece, move.from) ^ keyOf(us, info.piece, move.to);
    if (captured)
        pos.hash ^= keyOf(them, info.victim_ty, info.victim_sq);

    return undo;
}

pub fn unmake(pos: *Position, move: Move, undo: Undo) void {
    const from_bit = bit(move.from);
    const to_bit = bit(move.to);
    const mask = from_bit | to_bit;

    const us: usize = pos.stm ^ 1; // the mover
    const them: usize = pos.stm;
    const ty = types.idType(pos.board[move.to]); // piece type at to (never promoted)

    pos.colour[us] ^= mask;
    pos.pieces[ty] ^= to_bit;
    pos.pieces[ty] ^= from_bit;
    pos.board[move.from] = @intCast(us * 7 + ty);

    if (undo.captured_id != 0xFF) {
        pos.colour[them] ^= to_bit;
        pos.pieces[types.idType(undo.captured_id)] ^= to_bit;
        pos.board[move.to] = undo.captured_id;
    } else {
        pos.board[move.to] = 0xFF;
    }

    if (ty == King)
        pos.king_sq[us] = move.from;

    pos.stm = @intCast(us);
    pos.halfmove = undo.halfmove;
    pos.hash = undo.hash;
}

// ---------------------------------------------------------------------------
// Movegen — pseudo-legal generation per piece, then a legality filter that
// plays each candidate and rejects moves leaving our king attacked (this
// includes the flying-general facing rule via isAttacked).
//
// Filter shortcut: when not in check, a non-king move only needs the test if
// its from-square shares a row or column with our king — every discovered or
// screen-changing attack (rook, cannon, flying general) lives on such a line,
// and landing on a line can only block, never create, an attack.
// ---------------------------------------------------------------------------
fn addMove(movelist: *[256]Move, n: *i32, from: u8, to: u8) void {
    movelist[@intCast(n.*)] = .{ .from = from, .to = to, .promo = @intCast(None) };
    n.* += 1;
}

pub fn movegen(pos: *Position, movelist: *[256]Move, only_captures: bool) i32 {
    var n: i32 = 0;
    const us: usize = pos.stm;
    const them: usize = us ^ 1;
    const own = pos.colour[us];
    const their = pos.colour[them];
    const occ = own | their;
    const to_mask: BB = if (only_captures) their else ~own;
    const ksq = pos.king_sq[us];

    // Pawns
    {
        var bbs = own & pos.pieces[Pawn];
        while (bbs != 0) {
            const from: u8 = @intCast(@ctz(bbs));
            bbs &= bbs - 1;
            var targets = pawn_moves[us][from] & to_mask;
            while (targets != 0) {
                const to: u8 = @intCast(@ctz(targets));
                targets &= targets - 1;
                addMove(movelist, &n, from, to);
            }
        }
    }

    // Advisors
    {
        var bbs = own & pos.pieces[Advisor];
        while (bbs != 0) {
            const from: u8 = @intCast(@ctz(bbs));
            bbs &= bbs - 1;
            var targets = advisor_moves[from] & to_mask;
            while (targets != 0) {
                const to: u8 = @intCast(@ctz(targets));
                targets &= targets - 1;
                addMove(movelist, &n, from, to);
            }
        }
    }

    // Elephants (eye square must be empty)
    {
        var bbs = own & pos.pieces[Elephant];
        while (bbs != 0) {
            const from: u8 = @intCast(@ctz(bbs));
            bbs &= bbs - 1;
            var targets = elephant_moves[us][from] & to_mask;
            while (targets != 0) {
                const to: u8 = @intCast(@ctz(targets));
                targets &= targets - 1;
                if (occ & bit(@intCast(@divTrunc(@as(i32, from) + to, 2))) == 0)
                    addMove(movelist, &n, from, to);
            }
        }
    }

    // Knights (leg square must be empty)
    {
        var bbs = own & pos.pieces[Knight];
        while (bbs != 0) {
            const from: u8 = @intCast(@ctz(bbs));
            bbs &= bbs - 1;
            var targets = horse_moves[from] & to_mask;
            while (targets != 0) {
                const to: u8 = @intCast(@ctz(targets));
                targets &= targets - 1;
                if (occ & bit(horse_leg[from][to]) == 0)
                    addMove(movelist, &n, from, to);
            }
        }
    }

    // Rooks
    {
        var bbs = own & pos.pieces[Rook];
        while (bbs != 0) {
            const from: u8 = @intCast(@ctz(bbs));
            bbs &= bbs - 1;
            inline for (0..4) |dir| {
                for (ray_sq[dir][from][0..ray_n[dir][from]]) |to| {
                    const tb = bit(to);
                    if (occ & tb == 0) {
                        if (!only_captures) addMove(movelist, &n, from, to);
                    } else {
                        if (their & tb != 0) addMove(movelist, &n, from, to);
                        break;
                    }
                }
            }
        }
    }

    // Cannons: quiet moves over empties before the first screen, captures of
    // the first enemy piece behind exactly one screen.
    {
        var bbs = own & pos.pieces[Cannon];
        while (bbs != 0) {
            const from: u8 = @intCast(@ctz(bbs));
            bbs &= bbs - 1;
            inline for (0..4) |dir| {
                var screened = false;
                for (ray_sq[dir][from][0..ray_n[dir][from]]) |to| {
                    const tb = bit(to);
                    if (!screened) {
                        if (occ & tb == 0) {
                            if (!only_captures) addMove(movelist, &n, from, to);
                        } else {
                            screened = true; // this piece is the screen, not a target
                        }
                    } else if (occ & tb != 0) {
                        if (their & tb != 0) addMove(movelist, &n, from, to);
                        break;
                    }
                }
            }
        }
    }

    // King
    {
        var targets = king_moves[ksq] & to_mask;
        while (targets != 0) {
            const to: u8 = @intCast(@ctz(targets));
            targets &= targets - 1;
            addMove(movelist, &n, ksq, to);
        }
    }

    // Legality filter
    const in_check = isAttacked(pos, ksq, them) != 0;
    // Squares whose evacuation would UNBLOCK an enemy horse check: an enemy
    // horse a horse-jump from our king attacks it exactly when its leg square
    // is empty, and that leg square need not sit on a row/col through our
    // king — so the alignment shortcut below cannot cover it.
    var leg_mask: BB = 0;
    {
        var eh = pos.colour[them] & pos.pieces[Knight];
        while (eh != 0) {
            const h: u8 = @intCast(@ctz(eh));
            eh &= eh - 1;
            const leg = horse_leg[h][ksq];
            if (leg != 0xFF) leg_mask |= bit(leg);
        }
    }
    // Squares whose OCCUPATION would CREATE an enemy cannon check: an enemy
    // cannon aligned with our king over an empty stretch attacks exactly when
    // one screen stands between — landing there hands it the screen (landing
    // on a line can build an attack, not only block one).
    var screen_mask: BB = 0;
    {
        var ec = pos.colour[them] & pos.pieces[Cannon];
        while (ec != 0) {
            const c: u8 = @intCast(@ctz(ec));
            ec &= ec - 1;
            if (rowOf(c) != rowOf(ksq) and colOf(c) != colOf(ksq)) continue;
            const btw = between[c][ksq];
            if (@popCount(btw & occ) == 0) screen_mask |= btw;
        }
    }
    var w: usize = 0;
    for (movelist[0..@intCast(n)]) |m| {
        const needs_test = in_check or m.from == ksq or
            rowOf(m.from) == rowOf(ksq) or colOf(m.from) == colOf(ksq) or
            bit(m.from) & leg_mask != 0 or bit(m.to) & screen_mask != 0;
        if (needs_test) {
            const minfo = prepareMove(pos, m);
            const undo = make(pos, minfo, m);
            const illegal = isAttacked(pos, pos.king_sq[us], them) != 0;
            unmake(pos, m, undo);
            if (illegal) continue;
        }
        movelist[w] = m;
        w += 1;
    }
    return @intCast(w);
}

// ---------------------------------------------------------------------------
// Zobrist hashing. keys[(color*7+type)*90 + sq]; stm folds in as hash ^= 1.
// ---------------------------------------------------------------------------
inline fn keyOf(color: usize, ty: usize, sq: u8) u64 {
    return keys[(color * 7 + ty) * 90 + sq];
}

pub fn getHash(pos: *const Position) u64 {
    var hash: u64 = pos.stm;
    for (0..7) |ty| {
        for (0..2) |c| {
            var copy = pos.pieces[ty] & pos.colour[c];
            while (copy != 0) {
                const sq: u8 = @intCast(@ctz(copy));
                copy &= copy - 1;
                hash ^= keyOf(c, ty, sq);
            }
        }
    }
    return hash;
}

/// Recompute derived board state (king squares, mailbox, hash) after
/// building a position from scratch (FEN parse / startpos reset).
pub fn setupPosition(pos: *Position) void {
    const red_k = pos.colour[0] & pos.pieces[King];
    const black_k = pos.colour[1] & pos.pieces[King];
    if (red_k != 0) pos.king_sq[0] = @intCast(@ctz(red_k));
    if (black_k != 0) pos.king_sq[1] = @intCast(@ctz(black_k));
    @memset(&pos.board, 0xFF); // pos may carry stale mailbox entries from a previous position
    for (0..7) |ty| {
        var bb = pos.pieces[ty];
        while (bb != 0) {
            const sq: u8 = @intCast(@ctz(bb));
            bb &= bb - 1;
            pos.board[sq] = @intCast(@as(usize, @intFromBool(pos.colour[1] & bit(sq) != 0)) * 7 + ty);
        }
    }
    pos.hash = getHash(pos);
}

// ---------------------------------------------------------------------------
// FEN (xiangqi UCI dialect): rows rank 9 -> 0, letters rnbakcp, uppercase Red;
// side 'w'/'r' = Red (moves first), 'b' = Black; then two ignored fields
// ("-", "-"), then the halfmove clock (plies since last capture).
// ---------------------------------------------------------------------------
fn pieceFromChar(ch: u8) ?struct { side: usize, ty: usize } {
    const lower = std.ascii.toLower(ch);
    const ty: usize = switch (lower) {
        'p' => Pawn,
        'a' => Advisor,
        'b' => Elephant,
        'n' => Knight,
        'r' => Rook,
        'c' => Cannon,
        'k' => King,
        else => return null,
    };
    // uppercase = Red (0), lowercase = Black (1)
    return .{ .side = @intFromBool(std.ascii.isLower(ch)), .ty = ty };
}

pub fn setFen(pos: *Position, fen: []const u8) void {
    if (std.mem.eql(u8, fen, "startpos")) {
        setFen(pos, startpos_fen);
        return;
    }

    pos.colour = .{ 0, 0 };
    pos.pieces = .{ 0, 0, 0, 0, 0, 0, 0 };
    pos.stm = 0;
    pos.halfmove = 0;

    var it = std.mem.tokenizeAny(u8, fen, " \t");
    const board_tok = it.next() orelse return;
    var row: i32 = 9;
    var col: i32 = 0;
    for (board_tok) |ch| {
        if (ch >= '1' and ch <= '9') {
            col += @as(i32, ch - '0');
        } else if (ch == '/') {
            row -= 1;
            col = 0;
        } else if (pieceFromChar(ch)) |p| {
            if (row >= 0 and row <= 9 and col >= 0 and col <= 8) {
                const sqb = bitRC(row, col);
                pos.colour[p.side] |= sqb;
                pos.pieces[p.ty] |= sqb;
            }
            col += 1;
        }
    }

    if (it.next()) |side_tok|
        pos.stm = @intFromBool(std.mem.eql(u8, side_tok, "b"));

    _ = it.next(); // castling placeholder, ignored
    _ = it.next(); // ep placeholder, ignored
    if (it.next()) |hm_tok| {
        if (std.fmt.parseInt(u16, hm_tok, 10)) |hm| {
            pos.halfmove = hm;
        } else |_| {}
    }

    setupPosition(pos);
}

/// Serialize the position to a xiangqi-UCI-dialect FEN (for dfen / datagen).
pub fn fenStr(pos: *const Position, buf: []u8) []const u8 {
    var len: usize = 0;
    var row: i32 = 9;
    while (row >= 0) : (row -= 1) {
        var empties: u8 = 0;
        var col: i32 = 0;
        while (col <= 8) : (col += 1) {
            const id = pos.board[@intCast(row * 9 + col)];
            if (id == 0xFF) {
                empties += 1;
            } else {
                if (empties > 0) {
                    buf[len] = '0' + empties;
                    len += 1;
                    empties = 0;
                }
                const letters = "pabnrck";
                const ch = letters[types.idType(id)];
                buf[len] = if (types.idColor(id) == 0) std.ascii.toUpper(ch) else ch;
                len += 1;
            }
        }
        if (empties > 0) {
            buf[len] = '0' + empties;
            len += 1;
        }
        if (row > 0) {
            buf[len] = '/';
            len += 1;
        }
    }
    buf[len] = ' ';
    buf[len + 1] = if (pos.stm == 0) 'w' else 'b';
    len += 2;
    const suffix = " - - ";
    @memcpy(buf[len..][0..suffix.len], suffix);
    len += suffix.len;
    const hm = std.fmt.bufPrint(buf[len..], "{d} 1", .{pos.halfmove}) catch unreachable;
    len += hm.len;
    return buf[0..len];
}

// ---------------------------------------------------------------------------
// Perft — make/unmake in place
// ---------------------------------------------------------------------------
pub fn perft(pos: *Position, depth: i32) u64 {
    if (depth == 0)
        return 1;

    var nodes: u64 = 0;
    var moves: [256]Move = undefined;
    const num_moves = movegen(pos, &moves, false);

    for (moves[0..@intCast(num_moves)]) |move| {
        const info = prepareMove(pos, move);
        const undo = make(pos, info, move);
        nodes += perft(pos, depth - 1);
        unmake(pos, move, undo);
    }

    return nodes;
}

// ---------------------------------------------------------------------------
// mt19937_64 (std::mt19937_64 default-seeded; libstdc++ tempering variant)
// ---------------------------------------------------------------------------
pub const MT19937_64 = struct {
    mt: [312]u64 = undefined,
    idx: usize = 312,

    fn seed(self: *MT19937_64, seed_val: u64) void {
        self.mt[0] = seed_val;
        var i: usize = 1;
        while (i < 312) : (i += 1) {
            self.mt[i] = 6364136223846793005 *% (self.mt[i - 1] ^ (self.mt[i - 1] >> 62)) +% i;
        }
        self.idx = 312;
    }

    fn next(self: *MT19937_64) u64 {
        if (self.idx == 312) {
            var i: usize = 0;
            while (i < 312) : (i += 1) {
                const x = (self.mt[i] & 0xFFFFFFFF80000000) | (self.mt[(i + 1) % 312] & 0x7FFFFFFF);
                var xa = x >> 1;
                if (x & 1 != 0)
                    xa ^= 0xB5026F5AA96619E9;
                self.mt[i] = self.mt[(i + 156) % 312] ^ xa;
            }
            self.idx = 0;
        }
        var y = self.mt[self.idx];
        self.idx += 1;
        y ^= (y >> 29) & 0x5555555555555555;
        y ^= (y << 17) & 0x71D67FFFEDA60000;
        // libstdc++ uses a LEFT shift here (differs from reference mt19937-64.c)
        y ^= (y << 37) & 0xFFF7EEE000000000;
        y ^= y >> 43;
        return y;
    }
};

const horse_offsets = [8][4]i32{
    .{ -2, -1, -1, 0 }, .{ -2, 1, -1, 0 }, .{ 2, -1, 1, 0 }, .{ 2, 1, 1, 0 },
    .{ -1, -2, 0, -1 }, .{ 1, -2, 0, -1 }, .{ -1, 2, 0, 1 },  .{ 1, 2, 0, 1 },
};

const ray_dirs = [4][2]i32{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } };

/// Build all attack tables and Zobrist keys (once from main).
pub fn init() void {
    for (&horse_leg) |*row| @memset(row, @as(u8, 0xFF));

    for (0..90) |sqi| {
        const sq: u8 = @intCast(sqi);
        const r: i32 = @intCast(sq / 9);
        const c: i32 = @intCast(sq % 9);

        // King / advisor: steps within the palace containing sq
        var km: BB = 0;
        var am: BB = 0;
        const palace = inPalace(r, c);
        if (palace >= 0) {
            const ortho = [4][2]i32{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } };
            const diag = [4][2]i32{ .{ 1, 1 }, .{ 1, -1 }, .{ -1, 1 }, .{ -1, -1 } };
            for (ortho) |d| {
                const nr = r + d[0];
                const nc = c + d[1];
                if (inPalace(nr, nc) == palace) km |= bitRC(nr, nc);
            }
            for (diag) |d| {
                const nr = r + d[0];
                const nc = c + d[1];
                if (inPalace(nr, nc) == palace) am |= bitRC(nr, nc);
            }
        }
        king_moves[sq] = km;
        advisor_moves[sq] = am;

        // Elephants: diag 2-step targets on own half (red rows 0-4, black 5-9)
        {
            const diag2 = [4][2]i32{ .{ 2, 2 }, .{ 2, -2 }, .{ -2, 2 }, .{ -2, -2 } };
            for (0..2) |color| {
                var em: BB = 0;
                for (diag2) |d| {
                    const nr = r + d[0];
                    const nc = c + d[1];
                    if (nr < 0 or nr > 9 or nc < 0 or nc > 8) continue;
                    if (color == 0 and nr > 4) continue; // red stays rows 0-4
                    if (color == 1 and nr < 5) continue; // black stays rows 5-9
                    em |= bitRC(nr, nc);
                }
                elephant_moves[color][sq] = em;
            }
        }

        // Horses: 8 targets with their leg squares
        {
            var hm: BB = 0;
            for (horse_offsets) |o| {
                const nr = r + o[0];
                const nc = c + o[1];
                if (nr < 0 or nr > 9 or nc < 0 or nc > 8) continue;
                const to: u8 = @intCast(nr * 9 + nc);
                const leg: u8 = @intCast((r + o[2]) * 9 + (c + o[3]));
                hm |= bit(to);
                horse_leg[sq][to] = leg;
            }
            horse_moves[sq] = hm;
        }

        // Pawns: moves a color-c pawn at sq may make, and the squares from
        // which a color-c pawn attacks sq (the inverse relation).
        for (0..2) |color| {
            var pm: BB = 0;
            const fwd: i32 = if (color == 0) 1 else -1;
            const nr = r + fwd;
            if (nr >= 0 and nr <= 9) pm |= bitRC(nr, c);
            const crossed = if (color == 0) r >= 5 else r <= 4;
            if (crossed) {
                if (c - 1 >= 0) pm |= bitRC(r, c - 1);
                if (c + 1 <= 8) pm |= bitRC(r, c + 1);
            }
            pawn_moves[color][sq] = pm;

            // inverse: pawn one step behind (its forward hits sq) + sideways
            // neighbours whose pawn has crossed the river (same row as sq)
            var pa: BB = 0;
            const br = r - fwd;
            if (br >= 0 and br <= 9) pa |= bitRC(br, c);
            const crossed_here = if (color == 0) r >= 5 else r <= 4;
            if (crossed_here) {
                if (c - 1 >= 0) pa |= bitRC(r, c - 1);
                if (c + 1 <= 8) pa |= bitRC(r, c + 1);
            }
            pawn_att_from[color][sq] = pa;
        }

        // Orthogonal rays
        for (0..4) |dir| {
            var cnt: u8 = 0;
            var nr = r + ray_dirs[dir][0];
            var nc = c + ray_dirs[dir][1];
            while (nr >= 0 and nr <= 9 and nc >= 0 and nc <= 8) {
                ray_sq[dir][sq][cnt] = @intCast(nr * 9 + nc);
                cnt += 1;
                nr += ray_dirs[dir][0];
                nc += ray_dirs[dir][1];
            }
            ray_n[dir][sq] = cnt;
        }
    }

    // between[a][b]: squares strictly between aligned a and b (walk each ray
    // accumulating the squares seen before each target)
    for (&between) |*row| @memset(row, @as(BB, 0));
    for (0..90) |sqi| {
        const sq: u8 = @intCast(sqi);
        for (0..4) |dir| {
            var acc: BB = 0;
            for (ray_sq[dir][sq][0..ray_n[dir][sq]]) |q| {
                between[sq][q] = acc;
                acc |= bit(q);
            }
        }
    }

    var mt = MT19937_64{};
    mt.seed(5489);
    for (&keys) |*k|
        k.* = mt.next();
}
