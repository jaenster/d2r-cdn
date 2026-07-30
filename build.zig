const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // the library, importable by other projects: `.imports = &.{ .{ .name = "tact", .module = dep } }`
    const tact = b.addModule("tact", .{
        .root_source_file = b.path("src/tact.zig"),
        .target = target,
        .optimize = optimize,
    });

    // the CLI: everything the library can do, from a shell
    const cli = b.addExecutable(.{
        .name = "d2r-cdn",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "tact", .module = tact }},
        }),
    });
    b.installArtifact(cli);

    const run = b.addRunArtifact(cli);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the CLI: zig build run -- info").dependOn(&run.step);

    // the smallest possible library user, kept building so the documented API stays honest
    const example = b.addExecutable(.{
        .name = "d2r-fetch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("example/fetch.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "tact", .module = tact }},
        }),
    });
    b.step("example", "Build the library example").dependOn(&b.addInstallArtifact(example, .{}).step);

    const tests = b.addTest(.{ .root_module = tact });
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
