const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add sanitizer option
    const sanitize = b.option(
        []const u8,
        "sanitize",
        "Enable sanitizer: address, leak, or thread",
    );

    // Create the main executable
    const exe = b.addExecutable(.{
        .name = "zyncbase",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Apply sanitizer if specified
    if (sanitize) |san| {
        if (std.mem.eql(u8, san, "thread")) {
            exe.root_module.sanitize_thread = true;
        }
    }

    b.installArtifact(exe);

    // Create test step
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Apply sanitizer to tests if specified
    if (sanitize) |san| {
        if (std.mem.eql(u8, san, "thread")) {
            tests.root_module.sanitize_thread = true;
        }
    }

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
