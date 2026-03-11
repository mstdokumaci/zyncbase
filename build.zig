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

    // Add SQLite dependency
    const sqlite_dep = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });
    const sqlite_module = sqlite_dep.module("sqlite");

    // Create the main executable
    const exe = b.addExecutable(.{
        .name = "zyncbase",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Add SQLite module to executable
    exe.root_module.addImport("sqlite", sqlite_module);

    // Apply sanitizer if specified
    if (sanitize) |san| {
        if (std.mem.eql(u8, san, "thread")) {
            exe.root_module.sanitize_thread = true;
        }
    }

    linkUWS(b, exe);
    b.installArtifact(exe);

    // Create test step
    const test_filter = b.option([]const u8, "test-filter", "Filter tests by name");

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = if (test_filter) |filter|
            b.allocator.dupe([]const u8, &.{filter}) catch unreachable
        else
            &.{},
    });

    // Add SQLite module to tests
    tests.root_module.addImport("sqlite", sqlite_module);

    linkUWS(b, tests);

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

fn linkUWS(b: *std.Build, step: *std.Build.Step.Compile) void {
    // Link C++ standard library for uWebSockets
    step.linkLibCpp();

    // Link system libraries
    step.linkSystemLibrary("pthread");

    const is_linux = step.root_module.resolved_target.?.result.os.tag == .linux;

    var b_b_path: []const u8 = "vendor/boringssl/build";
    var b_b_include: []const u8 = "vendor/boringssl/include";
    var is_absolute = false;

    if (is_linux) {
        if (std.process.getEnvVarOwned(b.allocator, "ZYNCBASE_LINUX_BORINGSSL_PATH")) |env_path| {
            b_b_path = env_path;
            is_absolute = true;
            b_b_include = b.fmt("{s}/../boringssl/include", .{b_b_path});
        } else |_| {}
    }

    // Add include paths - BoringSSL must come first to override system OpenSSL
    if (is_absolute) {
        step.addIncludePath(.{ .cwd_relative = b_b_include });
    } else {
        step.addIncludePath(b.path(b_b_include));
    }
    step.addIncludePath(b.path("vendor/bun/packages/bun-uws/src"));
    step.addIncludePath(b.path("vendor/bun/packages/bun-usockets/src"));
    step.addIncludePath(b.path("vendor/bun/src/deps"));
    step.addIncludePath(b.path("src")); // For uws_wrapper.h

    // Link BoringSSL (built separately with CMake)
    if (is_absolute) {
        step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/libdecrepit.a", .{b_b_path}) });
        step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/libssl.a", .{b_b_path}) });
        step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/libcrypto.a", .{b_b_path}) });
    } else {
        step.addObjectFile(b.path(b.fmt("{s}/libdecrepit.a", .{b_b_path})));
        step.addObjectFile(b.path(b.fmt("{s}/libssl.a", .{b_b_path})));
        step.addObjectFile(b.path(b.fmt("{s}/libcrypto.a", .{b_b_path})));
    }

    // BoringSSL's crypto library requires libdl on Linux for dynamic loading
    if (is_linux) {
        step.linkSystemLibrary("dl");
    }

    const linux_flags: []const []const u8 = if (is_linux) &.{
        "-D_GNU_SOURCE",
        "-D_POSIX_C_SOURCE=200809L",
    } else &.{};

    // Add Bun's C wrapper (libuwsockets.cpp) with C++20 compilation flags
    const uws_flags = std.mem.concat(b.allocator, []const u8, &.{ linux_flags, &.{
        "-std=c++20",
        "-fno-exceptions",
        "-fno-rtti",
        "-DUWS_NO_ZLIB",
        "-DUWS_USE_LIBDEFLATE=0",
        "-DLIBUS_USE_OPENSSL=1",
        "-DLIBUS_USE_BORINGSSL=1",
        "-DWITH_BORINGSSL=1",
        "-Wno-nullability-completeness",
        "-I",
        "vendor/bun/packages",
    } }) catch unreachable;

    step.addCSourceFile(.{
        .file = b.path("vendor/bun/src/deps/libuwsockets.cpp"),
        .flags = uws_flags,
    });

    // Add uSockets implementation files from Bun
    const usockets_flags = std.mem.concat(b.allocator, []const u8, &.{ linux_flags, &.{
        "-std=c11",
        "-DUWS_NO_ZLIB",
        "-DUWS_USE_LIBDEFLATE=0",
        "-DLIBUS_USE_OPENSSL=1",
        "-DLIBUS_USE_BORINGSSL=1",
        "-DWITH_BORINGSSL=1",
        "-Wno-nullability-completeness",
    } }) catch unreachable;

    step.addCSourceFiles(.{
        .files = &.{
            "vendor/bun/packages/bun-usockets/src/eventing/epoll_kqueue.c",
            "vendor/bun/packages/bun-usockets/src/crypto/openssl.c",
            "vendor/bun/packages/bun-usockets/src/context.c",
            "vendor/bun/packages/bun-usockets/src/loop.c",
            "vendor/bun/packages/bun-usockets/src/socket.c",
            "vendor/bun/packages/bun-usockets/src/bsd.c",
            "vendor/bun/packages/bun-usockets/src/udp.c",
        },
        .flags = usockets_flags,
    });

    // Add SNI tree implementation
    const sni_flags = std.mem.concat(b.allocator, []const u8, &.{ linux_flags, &.{
        "-std=c++20",
        "-fno-exceptions",
        "-fno-rtti",
        "-DLIBUS_USE_OPENSSL=1",
        "-DLIBUS_USE_BORINGSSL=1",
        "-DWITH_BORINGSSL=1",
    } }) catch unreachable;

    step.addCSourceFile(.{
        .file = b.path("vendor/bun/packages/bun-usockets/src/crypto/sni_tree.cpp"),
        .flags = sni_flags,
    });

    // Add stubs for Bun-specific functions
    const stubs_flags = std.mem.concat(b.allocator, []const u8, &.{ linux_flags, &.{
        "-std=c11",
    } }) catch unreachable;

    step.addCSourceFile(.{
        .file = b.path("src/uws_stubs.c"),
        .flags = stubs_flags,
    });
}
