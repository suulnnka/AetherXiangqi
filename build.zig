const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // 不用 standardOptimizeOption 的 Debug 默认:基准/对战数字会全废,
    // 原生一律 ReleaseFast,要调试显式 -Doptimize=Debug。
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "optimization mode") orelse .ReleaseFast;

    const exe = b.addExecutable(.{
        .name = "aetherx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the engine");
    run_step.dependOn(&run_cmd.step);

    // ── wasm 引擎(P3 接入 src/wasm.zig 后启用)──
    // const wasm = b.addExecutable(.{
    //     .name = "aetherx",
    //     .root_module = b.createModule(.{
    //         .root_source_file = b.path("src/wasm.zig"),
    //         .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
    //         .optimize = .ReleaseFast,
    //         .strip = true,
    //     }),
    // });
    // wasm.entry = .disabled;
    // wasm.rdynamic = true;
    // b.installArtifact(wasm);
}
