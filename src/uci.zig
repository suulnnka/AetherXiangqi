// UCI front-end (Pikafish dialect): stdin tokenizer, option handling, the
// command loop, the move-application branch, and the fixed-depth bench
// command. Ported from AetherChess3's uci.zig.
const std = @import("std");
const linux = std.os.linux;
const types = @import("types.zig");
const board = @import("board.zig");
const evalmod = @import("eval.zig");
const tt = @import("tt.zig");
const search = @import("search.zig");
const out = @import("out.zig");

const Position = types.Position;
const Move = types.Move;
const TTEntry = types.TTEntry;
const now = types.now;

const setFen = board.setFen;
const perft = board.perft;
const movegen = board.movegen;
const pieceOn = board.pieceOn;

const HistList = search.HistList;
const iterativelyDeepen = search.iterativelyDeepen;

const append = out.append;
const appendInt = out.appendInt;
const appendMoveStr = out.appendMoveStr;
const flushLine = out.flushLine;

// ---------------------------------------------------------------------------
// Bench — all positions differentially verified against Pikafish (identical
// legal move sets, tools/diff_vs_pikafish.py) before being added here.
// The node total is the bit-exact regression baseline for this engine.
// ---------------------------------------------------------------------------
const BenchPos = struct { fen: []const u8, depth: i32 };

const bench_positions = [_]BenchPos{
    .{ .fen = board.startpos_fen, .depth = 10 },
    .{ .fen = "rnbakabn1/7r1/7c1/pc2p2Cp/6p2/2p6/P1P1P1P1P/1CN3N1R/3RA4/2B1KAB2 w - - 0 1", .depth = 10 }, // middlegame
    .{ .fen = "rnbaka1nr/9/2c1bc3/p1p1p1p1p/9/9/P1P1P1P1P/1CN2C3/9/R1BAKABNR w - - 0 1", .depth = 10 }, // opening
    .{ .fen = "2r2k3/4an3/b2R5/p3p2CP/2p3b2/2C6/n1P1P1p2/B4r2N/3KN3R/3A1AB2 b - - 0 1", .depth = 10 },
    .{ .fen = "2ba1k3/9/8b/4n1r2/4P4/3N3R1/p4NC2/3K4B/9/3A1A3 w - - 0 1", .depth = 10 },
    .{ .fen = "3ak4/2r1a4/b8/6R2/6b2/3p2P2/P3N3p/B8/3KA4/2B2A3 w - - 0 1", .depth = 12 },
    .{ .fen = "3k2b2/4a4/b3P4/6r2/5N3/5NC2/3n5/9/p2K5/3A1AB1R w - - 0 1", .depth = 12 }, // endgame
    .{ .fen = "9/4k3C/3a1a3/4p4/6b2/2B5p/9/p8/4NK3/5AB2 w - - 0 1", .depth = 12 }, // endgame
    .{ .fen = "2Ck1a3/9/4ba3/4p4/9/7p1/p2N5/4B3B/5K3/5A3 w - - 0 1", .depth = 13 }, // endgame
    .{ .fen = "5a3/2N1k4/b2P5/8P/9/9/9/3K1A3/9/2BA2p2 w - - 0 1", .depth = 13 }, // endgame
    .{ .fen = "1n4b2/9/3a1k3/9/6bN1/C8/4N4/7R1/3K5/1p3A3 b - - 0 1", .depth = 14 }, // sparse endgame
    .{ .fen = "4k4/9/9/9/9/9/9/9/9/3K1R3 w - - 0 1", .depth = 14 }, // KRvK
    .{ .fen = "4k4/9/9/9/9/9/9/9/4C4/4K4 w - - 0 1", .depth = 13 }, // KCvK
};

pub fn runBench() void {
    // Initialise the TT
    tt.allocTT(tt.num_tt_entries);

    var pos = Position{};
    var hash_history = HistList{};
    var hh_table = std.mem.zeroes([2][2][90][90]i32);
    var total_nodes: u64 = 0;

    const start_time = now();
    for (bench_positions) |bp| {
        setFen(&pos, bp.fen);
        search.limits = .{};
        search.hard_stop = now() +% (1 << 20);
        _ = iterativelyDeepen(&pos, &hash_history, &hh_table, bp.depth, &total_nodes, 1 << 20, now());
    }
    const elapsed = now() - start_time;

    append("Bench: ");
    appendInt(elapsed);
    append(" ms ");
    appendInt(total_nodes);
    append(" nodes ");
    appendInt(total_nodes * 1000 / @max(elapsed, 1));
    append(" nps\n");
    flushLine();
}

// ---------------------------------------------------------------------------
// stdin tokenizer (mirrors cin >> word / cin >> i32 semantics)
// ---------------------------------------------------------------------------
const Reader = struct {
    buf: [1 << 16]u8 = undefined,
    start: usize = 0,
    end: usize = 0,
    pending_buf: [32]u8 = undefined,
    pending_len: usize = 0,

    fn next(self: *Reader) ?[]const u8 {
        if (self.pending_len > 0) {
            const s = self.pending_buf[0..self.pending_len];
            self.pending_len = 0;
            return s;
        }
        while (true) {
            var i = self.start;
            while (i < self.end and std.ascii.isWhitespace(self.buf[i])) i += 1;
            self.start = i;
            if (i == self.end) {
                if (!self.refill()) return null;
                continue;
            }
            var j = i;
            while (j < self.end and !std.ascii.isWhitespace(self.buf[j])) j += 1;
            if (j == self.end) {
                // Token may continue past the buffer; compact and refill once.
                if (!self.refill()) {
                    const tok = self.buf[self.start..self.end];
                    self.start = self.end;
                    return tok;
                }
                continue;
            }
            const tok = self.buf[i..j];
            self.start = j;
            return tok;
        }
    }

    /// Push one already-read token back (copied; UCI command words are short).
    fn unread(self: *Reader, tok: []const u8) void {
        const n = @min(tok.len, self.pending_buf.len);
        @memcpy(self.pending_buf[0..n], tok[0..n]);
        self.pending_len = n;
    }

    /// True when the current input line has been fully consumed (UCI is a
    /// line protocol — senders write whole commands per write()).
    fn atLineEnd(self: *Reader) bool {
        var i = self.start;
        while (i < self.end and (self.buf[i] == ' ' or self.buf[i] == '\t' or self.buf[i] == '\r')) i += 1;
        return i < self.end and self.buf[i] == '\n';
    }

    fn refill(self: *Reader) bool {
        const rem = self.end - self.start;
        std.mem.copyForwards(u8, self.buf[0..rem], self.buf[self.start..self.end]);
        self.start = 0;
        self.end = rem;
        const n = linux.read(0, self.buf[rem..].ptr, self.buf.len - rem);
        const cnt: usize = @bitCast(@as(isize, @bitCast(n)));
        if (cnt == 0 or @as(isize, @bitCast(n)) <= 0) return false;
        self.end = rem + cnt;
        return true;
    }

    fn nextInt(self: *Reader, comptime T: type) ?T {
        const tok = self.next() orelse return null;
        return std.fmt.parseInt(T, tok, 10) catch null;
    }
};

// move_str comparison for the UCI move-application branch
fn moveEqlUci(word: []const u8, move: Move) bool {
    var buf: [4]u8 = undefined;
    buf[0] = 'a' + move.from % 9;
    buf[1] = '0' + move.from / 9;
    buf[2] = 'a' + move.to % 9;
    buf[3] = '0' + move.to / 9;
    return std.mem.eql(u8, word, buf[0..4]);
}

// ---------------------------------------------------------------------------
// UCI loop
// ---------------------------------------------------------------------------
pub fn run() void {
    var pos = Position{};
    setFen(&pos, board.startpos_fen);
    var hash_history = HistList{};
    var hh_table = std.mem.zeroes([2][2][90][90]i32);
    var reader = Reader{};

    // Wait for "uci"
    _ = reader.next();

    // Send UCI info
    append("id name AetherXiangqi 0.1\n");
    append("id author suulnnka\n");
    append("option name Hash type spin default ");
    appendInt(tt.num_tt_entries * @sizeOf(TTEntry) / (1024 * 1024));
    append(" min 1 max 65536\n");
    append("uciok\n");
    flushLine();

    // Initialise the TT
    tt.allocTTIfEmpty();

    while (true) {
        const word = reader.next() orelse break;
        if (std.mem.eql(u8, word, "quit")) {
            break;
        } else if (std.mem.eql(u8, word, "ucinewgame")) {
            hh_table = std.mem.zeroes([2][2][90][90]i32);
            search.cm_table = std.mem.zeroes([2][90][90]Move);
            search.cont_table = std.mem.zeroes([15][90][90]i16);
            @memset(tt.transposition_table, TTEntry{});
        } else if (std.mem.eql(u8, word, "isready")) {
            append("readyok\n");
            flushLine();
        } else if (std.mem.eql(u8, word, "setoption")) {
            _ = reader.next() orelse break; // "name"
            const opt = reader.next() orelse break;
            if (std.mem.eql(u8, opt, "Hash")) {
                var megabytes: i32 = 1;
                _ = reader.next() orelse break; // "value"
                if (reader.nextInt(i32)) |mb| {
                    megabytes = mb;
                }
                const clamped: u64 = @intCast(@max(1, @min(65536, megabytes)));
                tt.num_tt_entries = clamped * 1024 * 1024 / @sizeOf(TTEntry);
                tt.allocTT(tt.num_tt_entries);
            }
        } else if (std.mem.eql(u8, word, "go")) {
            // Full go parsing: wtime/btime/winc/binc, movetime, depth, nodes,
            // infinite (movestogo accepted and ignored, as in 4ku's spirit)
            var wtime: i64 = 0;
            var btime: i64 = 0;
            var winc: i64 = 0;
            var binc: i64 = 0;
            var movetime: i64 = 0;
            var depth_lim: i32 = 0;
            var nodes_lim: u64 = 0;
            var infinite = false;
            while (!reader.atLineEnd()) {
                const w = reader.next() orelse break;
                if (std.mem.eql(u8, w, "wtime")) {
                    wtime = reader.nextInt(i64) orelse 0;
                } else if (std.mem.eql(u8, w, "btime")) {
                    btime = reader.nextInt(i64) orelse 0;
                } else if (std.mem.eql(u8, w, "winc")) {
                    winc = reader.nextInt(i64) orelse 0;
                } else if (std.mem.eql(u8, w, "binc")) {
                    binc = reader.nextInt(i64) orelse 0;
                } else if (std.mem.eql(u8, w, "movetime")) {
                    movetime = reader.nextInt(i64) orelse 0;
                } else if (std.mem.eql(u8, w, "depth")) {
                    depth_lim = reader.nextInt(i32) orelse 0;
                } else if (std.mem.eql(u8, w, "nodes")) {
                    nodes_lim = reader.nextInt(u64) orelse 0;
                } else if (std.mem.eql(u8, w, "infinite")) {
                    infinite = true;
                } else if (std.mem.eql(u8, w, "movestogo")) {
                    _ = reader.nextInt(i32);
                } else {
                    // Not a go parameter: the next command — push it back
                    reader.unread(w);
                    break;
                }
                if (reader.atLineEnd())
                    break;
            }

            const start = now();

            // Time plan: optimum (soft base) / hard budget.
            //   clock: allocated = time/3 is both the hard stop and the
            //   soft-ladder base (4ku scheme); movetime: both = movetime;
            //   depth/nodes/infinite: unlimited
            var optimum: i32 = 1 << 20;
            var hard: i64 = 1 << 30;
            var soft = false;
            if (movetime > 0) {
                optimum = @intCast(movetime);
                hard = movetime;
            } else if (!infinite and depth_lim == 0 and nodes_lim == 0) {
                const t = if (pos.stm == 1) btime else wtime;
                if (t > 0) {
                    soft = true;
                    optimum = @intCast(@max(1, @divTrunc(t, 3)));
                    hard = optimum;
                }
            }
            search.limits = .{ .depth = depth_lim, .nodes = nodes_lim, .soft = soft };
            search.hard_stop = start +% @as(u64, @intCast(hard));

            var dummy_nodes: u64 = 0;
            const best_move = iterativelyDeepen(&pos, &hash_history, &hh_table, 0, &dummy_nodes, optimum, start);
            append("bestmove ");
            if (types.moveEq(best_move, types.no_move))
                append("(none)") // terminal position: mated or 困毙
            else
                appendMoveStr(best_move);
            append("\n");
            flushLine();
        } else if (std.mem.eql(u8, word, "position")) {
            // Set to startpos
            setFen(&pos, board.startpos_fen);
            hash_history.clear();

            var fen: [128]u8 = undefined;
            var fen_len: usize = 0;
            var fen_size: i32 = 0;

            // Try collect FEN string
            while (fen_size < 6) {
                if (reader.atLineEnd())
                    break;
                const tok = reader.next() orelse break;
                if (std.mem.eql(u8, tok, "moves") or std.mem.eql(u8, tok, "startpos"))
                    break;
                if (!std.mem.eql(u8, tok, "fen")) {
                    if (fen_len == 0) {
                        @memcpy(fen[0..tok.len], tok);
                        fen_len = tok.len;
                    } else {
                        fen[fen_len] = ' ';
                        @memcpy(fen[fen_len + 1 ..][0..tok.len], tok);
                        fen_len += 1 + tok.len;
                    }
                    fen_size += 1;
                }
            }

            if (fen_len > 0)
                setFen(&pos, fen[0..fen_len]);
        } else if (std.mem.eql(u8, word, "perft")) {
            const depth = reader.nextInt(i32) orelse 0;
            const t0 = now();
            const nodes = perft(&pos, depth);
            const dt = now() - t0;
            append("info");
            append(" depth ");
            appendInt(depth);
            append(" nodes ");
            appendInt(nodes);
            append(" time ");
            appendInt(dt);
            if (dt > 0) {
                append(" nps ");
                appendInt(1000 * nodes / dt);
            }
            append("\n");
            append("nodes ");
            appendInt(nodes);
            append("\n");
            flushLine();
        } else if (std.mem.eql(u8, word, "dfen")) {
            // Debug extension: print the current position's FEN.
            var buf: [128]u8 = undefined;
            append(board.fenStr(&pos, &buf));
            append("\n");
            flushLine();
        } else if (std.mem.eql(u8, word, "dhash")) {
            // Debug extension: incremental Zobrist hash, for port verification.
            appendInt(pos.hash);
            append("\n");
            flushLine();
        } else if (std.mem.eql(u8, word, "dhashfull")) {
            // Debug extension: hash recomputed from scratch; must equal dhash.
            appendInt(board.getHash(&pos));
            append("\n");
            flushLine();
        } else if (std.mem.eql(u8, word, "dhm")) {
            // Debug extension: halfmove clock, for differential verification.
            appendInt(pos.halfmove);
            append("\n");
            flushLine();
        } else if (std.mem.eql(u8, word, "deval")) {
            // Debug extension: fresh static eval, for port verification.
            appendInt(evalmod.evaluate(&pos));
            append("\n");
            flushLine();
        } else if (std.mem.eql(u8, word, "dmoves")) {
            // Debug extension: legal move dump, for port verification.
            var moves: [256]Move = undefined;
            const num_moves = movegen(&pos, &moves, false);
            for (moves[0..@intCast(num_moves)]) |m| {
                append(" ");
                appendMoveStr(m);
            }
            append("\n");
            flushLine();
        } else {
            var moves: [256]Move = undefined;
            const num_moves = movegen(&pos, &moves, false);
            for (moves[0..@intCast(num_moves)]) |move| {
                if (moveEqlUci(word, move)) {
                    const minfo = board.prepareMove(&pos, move);
                    _ = board.make(&pos, minfo, move);
                    // Every visited position enters the repetition history —
                    // the halfmove clock (plies since the last capture) bounds
                    // the scan window exactly in xiangqi.
                    hash_history.push(pos.hash);
                    break;
                }
            }
        }
    }
}
