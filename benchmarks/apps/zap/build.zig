const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseFast });

    const zap_dep = b.dependency("zap", .{
        .target = target,
        .optimize = optimize,
        .openssl = false,
    });

    const exe = b.addExecutable(.{
        .name = "zap-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zap", .module = zap_dep.module("zap") },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the Zap benchmark app");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);
}
