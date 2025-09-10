const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get the logger dependency
    const logger_dep = b.dependency("logger", .{
        .target = target,
        .optimize = optimize,
    });

    const nats_module = b.addModule("nats_zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add the logger import to your module
    nats_module.addImport("logger", logger_dep.module("logger-zig"));
}
