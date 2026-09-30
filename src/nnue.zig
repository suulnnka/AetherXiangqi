// NNUE evaluation: 1260 features (2 colors x 7 types x 90 squares, no king
// feature) -> 64x2 -> SCReLU -> 8 material buckets -> 1. Net format: v4
// (FT int8 @ QA=101 with a lossless exception list, output i16 @ QV=160),
// arch 0 — ported from AetherChess3's nnue.zig with the M1 mirror removed
// (no king features) and the perspective rotation changed to sq -> 89-sq.
// SCALE=400 (cp per unit) is the search-side contract.
//
// The net is trained by tools/training/trainer.rs (distillation of Pikafish's
// static NNUE eval) and embedded raw; the Rice-compressed embedding lands
// with the wasm build (P3) where binary size matters.
//
// Accumulators live OUTSIDE Position, on a per-ply stack owned by the search
// (copy-make: each ply's accumulator is written from the parent's plus the
// feature deltas in one fused pass — never unmade). The board is made/unmade
// in place by board.make/board.unmake.
const std = @import("std");
const types = @import("types.zig");

const Position = types.Position;
const None = types.None;

pub const Acc = [2][HIDDEN]i32; // [red view, black view]

pub const QA_I8: i32 = 101;
pub const QV_I8: i32 = 160;
pub const SCALE: i32 = 400;

pub const INPUTS: usize = 2 * 7 * 90;
pub const HIDDEN: usize = 64;
pub const BUCKETS: usize = 8;

const NET_MAGIC: u32 = 0x4E4E4541; // "AENN"
const NET_VERSION_I8: u32 = 4;

const embedded_net = @embedFile("aetherx.nnue");

const Net = struct {
    ft_w: [INPUTS * HIDDEN]i16, // [feature][i]
    ft_b: [HIDDEN]i16,
    out_w: [BUCKETS][HIDDEN * 2]i16,
    out_b: [BUCKETS]i16,
    qa: i32, // FT scale = accumulator clamp
    qv: i32, // output scale
};

var net: Net = undefined;
// SCReLU activation table: act[a] = a*a/qa, indexed by the clamped
// accumulator value — replaces a per-element runtime division.
var act_lut: [256]i32 = undefined;
var net_ready: bool = false;

pub fn init() void {
    parseV4(embedded_net) catch @panic("embedded net parse failed");
    for (0..256) |a| {
        const ai: i32 = @intCast(a);
        act_lut[a] = @divTrunc(ai * ai, net.qa);
    }
    net_ready = true;
}

const ParseError = error{ BadMagic, BadVersion, SizeMismatch, BadException, EmptyNet };

/// v4 layout: header 6×u32 (magic, version=4, arch, qa, qv, n_exc) +
/// exceptions (u32 index + i16 true value, covering ft_w and ft_b overflows)
/// + ft_w int8 + ft_b int8 + out_w i16 + out_b i16 — the trainer's write_net
/// byte-for-byte.
fn parseV4(bytes: []const u8) ParseError!void {
    const ft: usize = INPUTS * HIDDEN;
    const want_len: usize = 24 + INPUTS * HIDDEN + HIDDEN + BUCKETS * HIDDEN * 2 * 2 + BUCKETS * 2;
    if (bytes.len < want_len) return error.SizeMismatch;
    if (std.mem.readInt(u32, bytes[0..4], .little) != NET_MAGIC) return error.BadMagic;
    if (std.mem.readInt(u32, bytes[4..8], .little) != NET_VERSION_I8) return error.BadVersion;
    if (std.mem.readInt(u32, bytes[8..12], .little) != 0) return error.BadVersion; // arch must be 0
    net.qa = @bitCast(std.mem.readInt(u32, bytes[12..16], .little));
    net.qv = @bitCast(std.mem.readInt(u32, bytes[16..20], .little));
    const n_exc = std.mem.readInt(u32, bytes[20..24], .little);
    if (n_exc > ft + HIDDEN) return error.BadException;

    var p: usize = 24;
    // exceptions first (raw i8 pass below would overwrite them; re-applied after)
    var exc: [64]struct { idx: u32, val: i16 } = undefined;
    if (n_exc > exc.len) return error.BadException;
    for (0..n_exc) |k| {
        exc[k] = .{
            .idx = std.mem.readInt(u32, bytes[p..][0..4], .little),
            .val = std.mem.readInt(i16, bytes[p + 4 ..][0..2], .little),
        };
        p += 6;
    }
    var i: usize = p;
    for (&net.ft_w) |*v| {
        v.* = @as(i8, @bitCast(bytes[i]));
        i += 1;
    }
    for (&net.ft_b) |*v| {
        v.* = @as(i8, @bitCast(bytes[i]));
        i += 1;
    }
    for (&net.out_w) |*row| {
        for (row) |*v| {
            v.* = std.mem.readInt(i16, bytes[i..][0..2], .little);
            i += 2;
        }
    }
    for (&net.out_b) |*v| {
        v.* = std.mem.readInt(i16, bytes[i..][0..2], .little);
        i += 2;
    }
    if (i != bytes.len) return error.SizeMismatch; // exact: header + exceptions + all layers
    // re-apply the exception overlay
    for (exc[0..n_exc]) |e| {
        if (e.idx < ft) {
            net.ft_w[e.idx] = e.val;
        } else if (e.idx < ft + HIDDEN) {
            net.ft_b[e.idx - ft] = e.val;
        } else return error.BadException;
    }
    var nonzero = false;
    for (net.ft_w) |v| {
        if (v != 0) nonzero = true;
    }
    if (!nonzero) return error.EmptyNet;
}

/// Feature index for one (perspective, piece) pair. Own pieces index the low
/// half, enemy the high half; the second perspective sees the board rotated
/// 180° (sq -> 89 - sq).
inline fn featIdx(persp: usize, color: usize, ty: usize, sq: u8) usize {
    const rel: usize = @intFromBool(color != persp);
    const sq2: u8 = if (persp == 0) sq else 89 - sq;
    return (rel * 7 + ty) * 90 + @as(usize, sq2);
}

/// Full accumulator rebuild for both perspectives (position setup).
pub fn refreshAcc(pos: *const Position, out: *Acc) void {
    if (!net_ready) @panic("nnue net not loaded");
    for (0..HIDDEN) |i| {
        out[0][i] = net.ft_b[i];
        out[1][i] = net.ft_b[i];
    }
    for (0..90) |sq| {
        const id = pos.board[sq];
        if (id == 0xFF) continue;
        const color = types.idColor(id);
        const ty = types.idType(id);
        addRow(&out[0], featIdx(0, color, ty, @intCast(sq)), 1);
        addRow(&out[1], featIdx(1, color, ty, @intCast(sq)), 1);
    }
}

inline fn addRow(a: *[HIDDEN]i32, f: usize, sign: i32) void {
    const row = net.ft_w[f * HIDDEN ..][0..HIDDEN];
    if (sign > 0) {
        for (0..HIDDEN) |i| a[i] += row[i];
    } else {
        for (0..HIDDEN) |i| a[i] -= row[i];
    }
}

/// Fused copy+delta: writes the child's accumulators from the parent's plus
/// the feature deltas in a single pass. Xiangqi has exactly two patterns:
/// quiet (-from +to) and capture (-from +to -victim).
pub fn applyMoveDeltasAcc(src: *const Acc, dst: *Acc, us: usize, piece: usize, from: u8, to: u8, victim_ty: usize, victim_sq: u8) void {
    const them = us ^ 1;
    if (victim_ty != None) {
        for (0..2) |p| {
            const f0 = featIdx(p, us, piece, from);
            const f1 = featIdx(p, us, piece, to);
            const f2 = featIdx(p, them, victim_ty, victim_sq);
            const r0 = net.ft_w[f0 * HIDDEN ..][0..HIDDEN];
            const r1 = net.ft_w[f1 * HIDDEN ..][0..HIDDEN];
            const r2 = net.ft_w[f2 * HIDDEN ..][0..HIDDEN];
            for (0..HIDDEN) |i| dst[p][i] = src[p][i] - r0[i] + r1[i] - r2[i];
        }
    } else {
        for (0..2) |p| {
            const f0 = featIdx(p, us, piece, from);
            const f1 = featIdx(p, us, piece, to);
            const r0 = net.ft_w[f0 * HIDDEN ..][0..HIDDEN];
            const r1 = net.ft_w[f1 * HIDDEN ..][0..HIDDEN];
            for (0..HIDDEN) |i| dst[p][i] = src[p][i] - r0[i] + r1[i];
        }
    }
}

/// Evaluation in centipawns from the stm's perspective: output layer over
/// the ply's accumulators (stm's view is the primary perspective).
pub fn evalAcc(pos: *const Position, acc: *const Acc) i32 {
    if (!net_ready) @panic("nnue net not loaded");

    // Material bucket over total piece count (2..32 -> 0..7)
    var n: i32 = 0;
    for (pos.board) |id| {
        if (id != 0xFF) n += 1;
    }
    const bucket: usize = @intCast(@min(@divTrunc((n - 2) * 7, 30), 7));

    const pa: usize = pos.stm;
    const pb: usize = pa ^ 1;
    const ow = &net.out_w[bucket];
    const qa = net.qa;

    var dot: i64 = 0;
    for (0..HIDDEN) |i| {
        const va: usize = @intCast(std.math.clamp(acc[pa][i], 0, qa));
        const vb: usize = @intCast(std.math.clamp(acc[pb][i], 0, qa));
        dot += @as(i64, ow[i]) * act_lut[va] + @as(i64, ow[HIDDEN + i]) * act_lut[vb];
    }
    const e: i64 = @divTrunc((dot + net.out_b[bucket]) * SCALE, @as(i64, qa) * @as(i64, net.qv));
    return @truncate(e);
}

/// Standalone full evaluation (position setup / UCI deval): rebuild + output.
pub fn evalFresh(pos: *const Position) i32 {
    var acc: Acc = undefined;
    refreshAcc(pos, &acc);
    return evalAcc(pos, &acc);
}
