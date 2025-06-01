const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wav_module = b.addModule("wav", .{
        .optimize = optimize,
        .target = target,
        .root_source_file = b.path("src/wav.zig"),
    });

    const wav_unit_tests = b.addTest(.{
        .target = target,
        .optimize = optimize,
        .root_module = wav_module,
    });

    const run_wav_unit_tests = b.addRunArtifact(wav_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_wav_unit_tests.step);
}
