// NNUE evaluation: 1260 features (2 colors x 7 types x 90 squares, no king
// feature) -> 64x2 -> SCReLU -> 8 material buckets -> 1. Net format: v4
// (FT int8 @ QA=101 with a lossless exception list, output i16 @ QV=160),
// arch 0 — ported from AetherChess3's nnue.zig with the M1 mirror removed
// (no king features) and the perspective rotation changed to sq -> 89-sq.
// SCALE=400 (cp per unit) is the search-side contract.
//
// The net is embedded raw; the Rice-compressed embedding lands with the wasm
// build (P3) where binary size matters.
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

const NET_MAGIC_RICE: u32 = 0x31524541; // "1REA" (LER1 = rice-coded v4 net)
const RICE_VERSION: u32 = 1;
const RICE_BLK: usize = 256; // ft_w 分块自适应 k 的块大小

// 网以 Golomb-Rice 压缩内嵌(tools/gen_rice.py 生成,自校验往返),
// init() 时解压到 RAM——解码器 ~150B,换 ~30KB 产物体积。
const embedded_net = @embedFile("aetherx.nnue.rice");

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
    parseRice(embedded_net) catch @panic("embedded net parse failed");
    for (0..256) |a| {
        const ai: i32 = @intCast(a);
        act_lut[a] = @divTrunc(ai * ai, net.qa);
    }
    net_ready = true;
}

const ParseError = error{ BadMagic, BadVersion, BadArch, SizeMismatch, BadException, EmptyNet };

/// MSB-first 位读取器,与 tools/gen_rice.py 的 BW 写入器互为镜像
const BitRd = struct {
    bytes: []const u8,
    pos: usize = 0,
    acc: u8 = 0,
    nb: u4 = 0,
    fn bit(self: *BitRd) u1 {
        if (self.nb == 0) {
            self.acc = self.bytes[self.pos];
            self.pos += 1;
            self.nb = 8;
        }
        self.nb -= 1;
        return @truncate(self.acc >> @as(u3, @intCast(self.nb)));
    }
    /// 读一个 Rice(zigzag) 值
    fn rice(self: *BitRd, k: u8) i32 {
        var q: u32 = 0;
        while (self.bit() == 0) q += 1;
        var r: u32 = 0;
        var i: u8 = 0;
        while (i < k) : (i += 1) r = (r << 1) | self.bit();
        const u = (q << @intCast(k)) | r;
        return @as(i32, @intCast(u >> 1)) ^ (-@as(i32, @intCast(u & 1)));
    }
};

/// LER1 布局见 tools/gen_rice.py 头注释:头部 6×u32 + ft_w 分块 k 表 +
/// 3 个全局 k + 异常表(原样)+ 4×u32 段长 + 四段 MSB-first Rice 位流。
/// 值集与 v4 相同:ft_w/ft_b 本为 i8 + 异常覆盖,其余 i16——解码后与
/// trainer 的 write_net 字节语义一致。
fn parseRice(bytes: []const u8) ParseError!void {
    const ft: usize = INPUTS * HIDDEN;
    if (bytes.len < 24) return error.SizeMismatch;
    if (std.mem.readInt(u32, bytes[0..4], .little) != NET_MAGIC_RICE) return error.BadMagic;
    if (std.mem.readInt(u32, bytes[4..8], .little) != RICE_VERSION) return error.BadVersion;
    const arch = std.mem.readInt(u32, bytes[8..12], .little);
    if (arch != 0) return error.BadArch;
    net.qa = @bitCast(std.mem.readInt(u32, bytes[12..16], .little));
    net.qv = @bitCast(std.mem.readInt(u32, bytes[16..20], .little));
    const n_exc = std.mem.readInt(u32, bytes[20..24], .little);
    if (n_exc > ft + HIDDEN) return error.BadException;

    var p: usize = 24;
    const n_blk = std.mem.readInt(u32, bytes[p..][0..4], .little);
    if (n_blk != (ft + RICE_BLK - 1) / RICE_BLK) return error.SizeMismatch;
    p += 4;
    const ks = bytes[p .. p + n_blk];
    p += n_blk;
    const k_ftb = bytes[p];
    const k_outw = bytes[p + 1];
    const k_outb = bytes[p + 2];
    p += 3;
    const exc = bytes[p .. p + @as(usize, n_exc) * 6];
    p += @as(usize, n_exc) * 6;
    const lens: [4]u32 = .{
        std.mem.readInt(u32, bytes[p..][0..4], .little),
        std.mem.readInt(u32, bytes[p + 4 ..][0..4], .little),
        std.mem.readInt(u32, bytes[p + 8 ..][0..4], .little),
        std.mem.readInt(u32, bytes[p + 12 ..][0..4], .little),
    };
    p += 16;
    if (p + @as(usize, lens[0]) + lens[1] + lens[2] + lens[3] != bytes.len) return error.SizeMismatch;

    // ft_w:一条连续位流,每 RICE_BLK 个值换一块的 k
    var r = BitRd{ .bytes = bytes[p .. p + lens[0]] };
    var idx: usize = 0;
    for (ks) |k| {
        const n = @min(RICE_BLK, ft - idx);
        for (0..n) |_| {
            net.ft_w[idx] = @intCast(r.rice(k));
            idx += 1;
        }
    }
    // ft_b / out_w / out_b:各段字节对齐,全局 k
    var q = BitRd{ .bytes = bytes[p + lens[0] ..][0..lens[1]] };
    for (&net.ft_b) |*v| v.* = @intCast(q.rice(k_ftb));
    var o = BitRd{ .bytes = bytes[p + lens[0] + lens[1] ..][0..lens[2]] };
    for (&net.out_w) |*b| {
        for (b) |*v| v.* = @intCast(o.rice(k_outw));
    }
    var ob = BitRd{ .bytes = bytes[p + lens[0] + lens[1] + lens[2] ..][0..lens[3]] };
    for (&net.out_b) |*v| v.* = @intCast(ob.rice(k_outb));

    // 异常覆盖(i16 真值,覆盖 ft_w/ft_b 的 i8 量化)
    var eo: usize = 0;
    for (0..n_exc) |_| {
        const e_idx = std.mem.readInt(u32, exc[eo..][0..4], .little);
        const val = std.mem.readInt(i16, exc[eo + 4 ..][0..2], .little);
        if (e_idx < ft) {
            net.ft_w[e_idx] = val;
        } else if (e_idx < ft + HIDDEN) {
            net.ft_b[e_idx - ft] = val;
        } else return error.BadException;
        eo += 6;
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
