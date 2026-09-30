// FEN legality filter: reads a FEN-per-line file, keeps positions that are
// legal xiangqi states — both kings present and the side NOT to move is not
// in check (its king not attacked by the mover, flying-general included —
// which is exactly Pikafish's "King can be captured" rejection, plus facing
// kings). Uses the engine's differentially-verified isAttacked tables.
//
// Usage: aetherx fenfilter <in.fen> <out.fen>
const std = @import("std");
const types = @import("types.zig");
const board = @import("board.zig");

const Position = types.Position;
const King = types.King;
const linux = std.os.linux;

fn writeFd(fd: i32, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (@as(isize, @bitCast(n)) <= 0) return;
        off += @intCast(n);
    }
}

fn openPath(path: []const u8, write: bool) i32 {
    var nbuf: [4096]u8 = undefined;
    if (path.len + 1 > nbuf.len) return -1;
    @memcpy(nbuf[0..path.len], path);
    nbuf[path.len] = 0;
    const rc = if (write)
        linux.open(nbuf[0..path.len :0], .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644)
    else
        linux.open(nbuf[0..path.len :0], .{ .ACCMODE = .RDONLY }, 0);
    return @intCast(rc);
}

fn legalPosition(pos: *Position) bool {
    if (pos.colour[0] & pos.pieces[King] == 0) return false;
    if (pos.colour[1] & pos.pieces[King] == 0) return false;
    // the side that just moved must not have left its own king attacked
    const nm: usize = pos.stm ^ 1;
    return board.isAttacked(pos, pos.king_sq[nm], pos.stm) == 0;
}

pub fn run(args: []const []const u8) void {
    if (args.len < 2) {
        writeFd(2, "usage: aetherx fenfilter <in.fen> <out.fen>\n");
        return;
    }
    const in_fd = openPath(args[0], false);
    const out_fd = openPath(args[1], true);
    if (in_fd < 0 or out_fd < 0) {
        writeFd(2, "fenfilter: open failed\n");
        return;
    }

    var pos = Position{};
    var read_buf: [1 << 20]u8 = undefined;
    var line_buf: [256]u8 = undefined;
    var line_len: usize = 0;
    var out_buf: [1 << 20]u8 = undefined;
    var out_len: usize = 0;
    var total: u64 = 0;
    var kept: u64 = 0;

    var eof = false;
    while (!eof) {
        const n = linux.read(in_fd, read_buf[0..].ptr, read_buf.len);
        if (@as(isize, @bitCast(n)) <= 0) {
            eof = true;
            break;
        }
        const cnt: usize = @bitCast(@as(isize, @bitCast(n)));
        for (read_buf[0..cnt]) |ch| {
            if (ch != '\n') {
                if (line_len < line_buf.len) {
                    line_buf[line_len] = ch;
                    line_len += 1;
                }
                continue;
            }
            if (line_len > 0) {
                total += 1;
                const fen = line_buf[0..line_len];
                line_len = 0;
                board.setFen(&pos, fen);
                if (legalPosition(&pos)) {
                    kept += 1;
                    if (out_len + fen.len + 1 > out_buf.len) {
                        writeFd(out_fd, out_buf[0..out_len]);
                        out_len = 0;
                    }
                    @memcpy(out_buf[out_len..][0..fen.len], fen);
                    out_len += fen.len;
                    out_buf[out_len] = '\n';
                    out_len += 1;
                }
            }
        }
    }
    if (line_len > 0) {
        total += 1;
        board.setFen(&pos, line_buf[0..line_len]);
        if (legalPosition(&pos)) {
            kept += 1;
            const fen = line_buf[0..line_len];
            @memcpy(out_buf[out_len..][0..fen.len], fen);
            out_len += fen.len;
            out_buf[out_len] = '\n';
            out_len += 1;
        }
    }
    if (out_len > 0) writeFd(out_fd, out_buf[0..out_len]);
    _ = linux.close(in_fd);
    _ = linux.close(out_fd);
    var num_buf: [96]u8 = undefined;
    const s = std.fmt.bufPrint(&num_buf, "fenfilter: kept {d}/{d}\n", .{ kept, total }) catch unreachable;
    writeFd(1, s);
}
