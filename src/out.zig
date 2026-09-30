// Output helpers (buffered writes to stdout)
const std = @import("std");
const linux = std.os.linux;
const types = @import("types.zig");

var line_buf: [16384]u8 = undefined;
var line_len: usize = 0;

pub fn flushLine() void {
    if (line_len > 0) {
        posixWrite(line_buf[0..line_len]);
        line_len = 0;
    }
}

fn posixWrite(bytes: []const u8) void {
    if (@import("builtin").target.cpu.arch == .wasm32)
        return; // wasm build has no stdout consumer; search output is discarded
    var off: usize = 0;
    while (off < bytes.len) {
        const n = linux.write(1, bytes.ptr + off, bytes.len - off);
        if (@as(isize, @bitCast(n)) <= 0) return;
        off += n;
    }
}

pub fn append(str: []const u8) void {
    @memcpy(line_buf[line_len..][0..str.len], str);
    line_len += str.len;
}

pub fn appendInt(v: anytype) void {
    // Hand-rolled integer formatting (4ku heritage) — std.fmt.bufPrint drags
    // formatting machinery into the wasm closure for lines discarded there.
    var tmp: [24]u8 = undefined;
    var n: usize = 0;
    var mag: u64 = 0;
    var neg = false;
    if (@typeInfo(@TypeOf(v)).int.signedness == .signed) {
        if (v < 0) {
            neg = true;
            mag = @intCast(-@as(i64, v));
        } else mag = @intCast(v);
    } else mag = @intCast(v);
    while (true) {
        tmp[n] = @intCast('0' + mag % 10);
        n += 1;
        mag /= 10;
        if (mag == 0) break;
    }
    if (neg) append("-");
    while (n > 0) {
        n -= 1;
        append(tmp[n .. n + 1]);
    }
}

// Xiangqi UCI square: file 'a'..'i' = col, rank '0'..'9' = row (row 0 = Red).
pub fn appendMoveStr(move: types.Move) void {
    line_buf[line_len] = 'a' + move.from % 9;
    line_buf[line_len + 1] = '0' + move.from / 9;
    line_buf[line_len + 2] = 'a' + move.to % 9;
    line_buf[line_len + 3] = '0' + move.to / 9;
    line_len += 4;
}
