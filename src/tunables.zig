// Search tunables exposed for SPSA tuning via the A3X_SEARCH_PARAMS /
// A3X_STACK_PARAMS / A3X_MAT_PARAMS environment variables — comma-separated
// lists in declaration order. Values are rounded to i32 and clamped to the
// per-param bounds; anything unparsable or of the wrong count falls back to
// the defaults. Structure ported from AetherChess3; defaults are the A3
// chess optima as a starting point (xiangqi retune happens in P4).
const std = @import("std");

pub const Param = struct { name: []const u8, def: i32, lo: i32, hi: i32 };

pub const Id = enum(usize) {
    rfp_margin, // reverse futility: static_eval - margin*(depth-improving) >= beta
    rfp_max_depth, // RFP only below this depth
    razoring, // static_eval + razoring*depth < alpha -> drop into qsearch
    qs_delta, // qsearch delta pruning margin
    ffp_margin, // forward futility: static_eval + margin*depth + gain < alpha
    ffp_max_depth, // FFP only below this depth
    nmp_base, // null depth = depth - base - depth/nmp_div - min(eval-beta)/nmp_eval_div, nmp_cap)
    nmp_div,
    nmp_eval_div,
    nmp_cap,
    lmr_move_div, // LMR reduction = moves/lmr_move_div + depth/lmr_depth_div + ...
    lmr_depth_div,
    hist_gravity, // history update divisor (depth*depth*hist/gravity)
    lmp_base, // quiet-move count limit = (base + depth*depth) >> !improving
    asp_base, // aspiration window base (window = base + score^2/16384)
};

const defs = [_]Param{
    .{ .name = "rfp_margin", .def = 71, .lo = 30, .hi = 140 },
    .{ .name = "rfp_max_depth", .def = 8, .lo = 2, .hi = 12 },
    .{ .name = "razoring", .def = 238, .lo = 100, .hi = 450 },
    .{ .name = "qs_delta", .def = 50, .lo = 0, .hi = 120 },
    .{ .name = "ffp_margin", .def = 105, .lo = 40, .hi = 220 },
    .{ .name = "ffp_max_depth", .def = 8, .lo = 3, .hi = 12 },
    .{ .name = "nmp_base", .def = 4, .lo = 0, .hi = 7 },
    .{ .name = "nmp_div", .def = 5, .lo = 3, .hi = 8 },
    .{ .name = "nmp_eval_div", .def = 196, .lo = 80, .hi = 400 },
    .{ .name = "nmp_cap", .def = 3, .lo = 1, .hi = 6 },
    .{ .name = "lmr_move_div", .def = 13, .lo = 8, .hi = 22 },
    .{ .name = "lmr_depth_div", .def = 14, .lo = 4, .hi = 24 },
    .{ .name = "hist_gravity", .def = 512, .lo = 256, .hi = 1024 },
    .{ .name = "lmp_base", .def = 1, .lo = 0, .hi = 4 },
    .{ .name = "asp_base", .def = 28, .lo = 10, .hi = 80 },
};

// Current values (defaults until init() overrides them from the env).
pub var val = blk: {
    var v: [defs.len]i32 = undefined;
    for (&v, &defs) |*x, p| x.* = p.def;
    break :blk v;
};

pub const Id2 = enum(usize) {
    sq_coef, // SEE quiets: prune when see < -sq_coef * min(d, sq_cap)^2
    sq_cap,
    se_depth, // SE minimum depth
    se_margin, // SE singular margin, x16 fixed point (16 = 1.0 x depth)
    se_vdiv, // SE verification depth divisor: (d-1)/se_vdiv
    mvv_scale, // MVV-LVA victim scale in ordering
    qs_fut_margin, // qsearch: SEE==0 captures pruned when static_eval + margin <= alpha
    demote_coef, // bad-capture demotion: see < -coef*order/1024 demotes below quiets
    demote_pen, // demotion score penalty (must exceed max capture score ~57k)
};

const defs2 = [_]Param{
    .{ .name = "sq_coef", .def = 18, .lo = 6, .hi = 40 },
    .{ .name = "sq_cap", .def = 12, .lo = 6, .hi = 26 },
    .{ .name = "se_depth", .def = 7, .lo = 4, .hi = 10 },
    .{ .name = "se_margin", .def = 32, .lo = 4, .hi = 48 },
    .{ .name = "se_vdiv", .def = 2, .lo = 2, .hi = 6 },
    .{ .name = "mvv_scale", .def = 16, .lo = 8, .hi = 32 },
    .{ .name = "qs_fut_margin", .def = 155, .lo = 60, .hi = 350 },
    .{ .name = "demote_coef", .def = 21, .lo = 5, .hi = 80 },
    .{ .name = "demote_pen", .def = 60000, .lo = 8192, .hi = 65535 },
};

pub var val2 = blk: {
    var v: [defs2.len]i32 = undefined;
    for (&v, &defs2) |*x, p| x.* = p.def;
    break :blk v;
};

pub const Id3 = enum(usize) {
    mat_p, // max_material values (delta/FFP/ordering gain scale)
    mat_a,
    mat_b,
    mat_n,
    mat_r,
    mat_c,
    ch_gravity, // conthist update divisor (also its +/-asymptote)
};

// Initial values are the v0.1-js HCE material values (Pawn=100 ... Rook=900);
// SPSA travels from there. These feed ordering gains / delta / FFP margins
// and SEE only — never the evaluation itself.
const defs3 = [_]Param{
    .{ .name = "mat_p", .def = 100, .lo = 30, .hi = 200 },
    .{ .name = "mat_a", .def = 110, .lo = 50, .hi = 300 },
    .{ .name = "mat_b", .def = 110, .lo = 50, .hi = 300 },
    .{ .name = "mat_n", .def = 400, .lo = 200, .hi = 700 },
    .{ .name = "mat_r", .def = 900, .lo = 400, .hi = 1300 },
    .{ .name = "mat_c", .def = 450, .lo = 200, .hi = 800 },
    .{ .name = "ch_gravity", .def = 512, .lo = 256, .hi = 1024 },
};

pub var val3 = blk: {
    var v: [defs3.len]i32 = undefined;
    for (&v, &defs3) |*x, p| x.* = p.def;
    break :blk v;
};

/// max_material mirrored from val3[0..6]; [6] King and [7] None stay 0.
pub var mat = [8]i32{ 100, 110, 110, 400, 900, 450, 0, 0 };

pub inline fn get3(id: Id3) i32 {
    return val3[@intFromEnum(id)];
}

pub inline fn get2(id: Id2) i32 {
    return val2[@intFromEnum(id)];
}

pub inline fn get(id: Id) i32 {
    return val[@intFromEnum(id)];
}

/// Scan the process environment for the A3X_*_PARAMS lists. On any malformed
/// input the whole set stays/becomes the defaults — never a partial mix.
pub fn init(environ: std.process.Environ) void {
    if (@TypeOf(environ.block) != std.process.Environ.PosixBlock)
        return; // freestanding/WASM: no env, defaults apply
    for (environ.block.view().slice) |entry| {
        const kv = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, kv[0..eq], "A3X_SEARCH_PARAMS")) {
            parseSpec(kv[eq + 1 ..]);
        } else if (std.mem.eql(u8, kv[0..eq], "A3X_STACK_PARAMS")) {
            parseSpec2(kv[eq + 1 ..]);
        } else if (std.mem.eql(u8, kv[0..eq], "A3X_MAT_PARAMS")) {
            parseSpec3(kv[eq + 1 ..]);
        }
    }
}

fn parseSpec3(spec: []const u8) void {
    var it = std.mem.splitScalar(u8, spec, ',');
    var parsed: [defs3.len]i32 = undefined;
    var n: usize = 0;
    while (it.next()) |tok| {
        if (n >= defs3.len)
            return;
        const f = std.fmt.parseFloat(f64, std.mem.trim(u8, tok, " ")) catch return;
        const lo: f64 = @floatFromInt(defs3[n].lo);
        const hi: f64 = @floatFromInt(defs3[n].hi);
        parsed[n] = @intFromFloat(@round(@min(@max(f, lo), hi)));
        n += 1;
    }
    if (n == defs3.len) {
        val3 = parsed;
        for (0..6) |i| mat[i] = val3[i];
    }
}

fn parseSpec2(spec: []const u8) void {
    var it = std.mem.splitScalar(u8, spec, ',');
    var parsed: [defs2.len]i32 = undefined;
    var n: usize = 0;
    while (it.next()) |tok| {
        if (n >= defs2.len)
            return;
        const f = std.fmt.parseFloat(f64, std.mem.trim(u8, tok, " ")) catch return;
        const lo: f64 = @floatFromInt(defs2[n].lo);
        const hi: f64 = @floatFromInt(defs2[n].hi);
        parsed[n] = @intFromFloat(@round(@min(@max(f, lo), hi)));
        n += 1;
    }
    if (n == defs2.len)
        val2 = parsed;
}

fn parseSpec(spec: []const u8) void {
    var it = std.mem.splitScalar(u8, spec, ',');
    var parsed: [defs.len]i32 = undefined;
    var n: usize = 0;
    while (it.next()) |tok| {
        if (n >= defs.len)
            return; // too many values: keep defaults
        const f = std.fmt.parseFloat(f64, std.mem.trim(u8, tok, " ")) catch return;
        const lo: f64 = @floatFromInt(defs[n].lo);
        const hi: f64 = @floatFromInt(defs[n].hi);
        parsed[n] = @intFromFloat(@round(@min(@max(f, lo), hi)));
        n += 1;
    }
    if (n == defs.len)
        val = parsed;
}
