// Position datagen: multi-threaded random playouts from startpos, writing
// deduplicated FENs (one per line) to per-worker shard files.
// Sampling mix: uniform random games and capture-weighted games, game lengths
// 20..150 plies, 60-move rule termination — coverage from opening to deep
// endgame. Nothing here runs a search.
//
// Usage: aetherx datagen <out_prefix> <total_positions> <seed> [workers]
const std = @import("std");
const types = @import("types.zig");
const board = @import("board.zig");

const Position = types.Position;
const Move = types.Move;

// Minimal POSIX file IO (std's new Io interface needs a threaded instance;
// raw syscalls keep this simple, out.zig style).
const linux = std.os.linux;

fn openOut(path: []const u8) i32 {
    var buf: [4096]u8 = undefined;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const rc = linux.open(buf[0..path.len :0], .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    return @intCast(rc);
}

fn writeFd(fd: i32, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (@as(isize, @bitCast(n)) <= 0) return;
        off += @intCast(n);
    }
}

const Rng = struct {
    s: u64,
    fn next(self: *Rng) u64 {
        // xorshift64* (same family as AetherChess2's datagen)
        self.s ^= self.s >> 12;
        self.s ^= self.s << 25;
        self.s ^= self.s >> 27;
        return self.s *% 0x2545F4914F6CDD1D;
    }
    fn below(self: *Rng, n: u64) u64 {
        return self.next() % n;
    }
    fn frac(self: *Rng) u64 {
        return self.next() >> 11; // 53 bits
    }
};

fn weightedPick(moves: []const Move, pos: *const Position, rng: *Rng, capture_weight: bool) Move {
    if (!capture_weight)
        return moves[rng.below(moves.len)];
    // captures x4 weight (better material preservation and game-like lines)
    var total: u64 = 0;
    for (moves) |m| {
        total += if (pos.board[m.to] != 0xFF) 4 else 1;
    }
    var pick = rng.below(total);
    for (moves) |m| {
        const w: u64 = if (pos.board[m.to] != 0xFF) 4 else 1;
        if (pick < w) return m;
        pick -= w;
    }
    return moves[moves.len - 1];
}

const WorkerCtx = struct {
    id: usize,
    quota: u64,
    seed: u64,
    out_path: []const u8,
    written: u64 = 0,
};

fn workerRun(ctx: *WorkerCtx) void {
    var pos = Position{};
    board.setFen(&pos, board.startpos_fen);
    var rng = Rng{ .s = ctx.seed };
    var seen = std.AutoHashMap(u64, void).init(types.page_alloc);
    defer seen.deinit();

    const fd = openOut(ctx.out_path);
    if (fd < 0) @panic("datagen: create failed");
    defer _ = linux.close(fd);
    var buf: [1 << 16]u8 = undefined;
    var buf_len: usize = 0;
    var fen_buf: [128]u8 = undefined;

    var moves: [256]Move = undefined;
    while (ctx.written < ctx.quota) {
        // new random game
        board.setFen(&pos, board.startpos_fen);
        const target_plies: u32 = @intCast(20 + rng.below(131)); // 20..150
        const capture_weighted = rng.frac() % 10 < 3; // 30% weighted games
        var ply: u32 = 0;
        while (ply < target_plies) : (ply += 1) {
            const n = board.movegen(&pos, &moves, false);
            if (n == 0) break; // mate / 困毙
            if (pos.halfmove >= 118) break; // 60-move rule
            // record the position (before moving)
            if (!seen.contains(pos.hash)) {
                seen.put(pos.hash, {}) catch @panic("oom");
                const fen = board.fenStr(&pos, &fen_buf);
                if (buf_len + fen.len + 1 > buf.len) {
                    writeFd(fd, buf[0..buf_len]);
                    buf_len = 0;
                }
                @memcpy(buf[buf_len..][0..fen.len], fen);
                buf_len += fen.len;
                buf[buf_len] = '\n';
                buf_len += 1;
                ctx.written += 1;
                if (ctx.written >= ctx.quota) break;
            }
            const mv = weightedPick(moves[0..@intCast(n)], &pos, &rng, capture_weighted);
            const minfo = board.prepareMove(&pos, mv);
            _ = board.make(&pos, minfo, mv);
        }
    }
    if (buf_len > 0) writeFd(fd, buf[0..buf_len]);
}

pub fn run(args: []const []const u8) void {
    if (args.len < 3) {
        writeFd(2, "usage: aetherx datagen <out_prefix> <total_positions> <seed> [workers]\n");
        return;
    }
    const out_prefix = args[0];
    const total = std.fmt.parseInt(u64, args[1], 10) catch return;
    const seed = std.fmt.parseInt(u64, args[2], 10) catch return;
    const workers: usize = if (args.len > 3) (std.fmt.parseInt(usize, args[3], 10) catch 8) else 8;

    const per_worker = (total + workers - 1) / workers;
    var ctxs: [64]WorkerCtx = undefined;
    var threads: [64]std.Thread = undefined;
    var path_buf: [4096]u8 = undefined;
    for (0..workers) |i| {
        const path = std.fmt.bufPrint(&path_buf, "{s}.w{d:0>2}", .{ out_prefix, i }) catch unreachable;
        const owned = types.page_alloc.dupe(u8, path) catch @panic("oom");
        ctxs[i] = .{ .id = i, .quota = per_worker, .seed = seed +% i *% 0x9E3779B97F4A7C15, .out_path = owned };
        threads[i] = std.Thread.spawn(.{}, workerRun, .{&ctxs[i]}) catch @panic("thread spawn failed");
    }
    var total_written: u64 = 0;
    for (0..workers) |i| {
        threads[i].join();
        total_written += ctxs[i].written;
    }
    var num_buf: [64]u8 = undefined;
    const s = std.fmt.bufPrint(&num_buf, "datagen: done, positions: {d}\n", .{total_written}) catch unreachable;
    writeFd(1, s);
}
