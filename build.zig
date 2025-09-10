const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module - this is what other packages will import
    const nats_module = b.addModule("nats-zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // === TESTING ===
    const lib_unit_tests = b.addTest(.{
        .name = "nats-zig-tests",
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // === EXAMPLES ===
    const examples_step = b.step("examples", "Build all examples");

    // Publisher example
    const publisher_exe = b.addExecutable(.{
        .name = "publisher",
        .root_source_file = b.path("examples/publisher.zig"),
        .target = target,
        .optimize = optimize,
    });
    publisher_exe.root_module.addImport("nats-zig", nats_module);
    b.installArtifact(publisher_exe);
    examples_step.dependOn(&publisher_exe.step);

    // Subscriber example
    const subscriber_exe = b.addExecutable(.{
        .name = "subscriber",
        .root_source_file = b.path("examples/subscriber.zig"),
        .target = target,
        .optimize = optimize,
    });
    subscriber_exe.root_module.addImport("nats-zig", nats_module);
    b.installArtifact(subscriber_exe);
    examples_step.dependOn(&subscriber_exe.step);

    // === BENCHMARKS ===
    const bench_step = b.step("bench", "Run benchmarks");
    const bench_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = .ReleaseFast, // Always optimize benchmarks
    });
    bench_exe.root_module.addImport("nats-zig", nats_module);
    const run_bench = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&run_bench.step);

    // === DEVELOPMENT TOOLS ===
    const fmt_step = b.step("fmt", "Format all source files");
    const fmt_cmd = b.addFmt(.{
        .paths = &.{ "src", "examples", "bench", "build.zig" },
        .check = false,
    });
    fmt_step.dependOn(&fmt_cmd.step);
}
