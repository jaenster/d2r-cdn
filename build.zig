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

    // example CLI that uses the library
    const fetch = b.addExecutable(.{
        .name = "d2r-fetch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fetch.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "tact", .module = tact }},
        }),
    });
    b.installArtifact(fetch);

    // zig build test
    const tests = b.addTest(.{ .root_module = tact });
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
