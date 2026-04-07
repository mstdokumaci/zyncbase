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
    // Sysroot option for cross-compiling (especially macOS frameworks)
    const sysroot = b.option([]const u8, "sysroot", "Path to sysroot");
    if (sysroot) |s| {
        b.sysroot = s;
    }

    // Add SQLite dependency
    const sqlite_dep = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });
    const sqlite_module = sqlite_dep.module("sqlite");

    // Use zig-msgpack dependency
    const msgpack_dep = b.dependency("zig_msgpack", .{
        .target = target,
        .optimize = optimize,
    });
    const msgpack_module = msgpack_dep.module("msgpack");

    // Add zwanzig dependency
    const zw = b.dependency("zwanzig", .{
        .target = target,
        .optimize = optimize,
    });
    const zw_exe = zw.artifact("zwanzig");

    const run_zw = b.addRunArtifact(zw_exe);
    run_zw.addArgs(&.{ "--format", "text", "src" });

    const lint_step = b.step("lint", "Run zwanzig code quality check");
    lint_step.dependOn(&run_zw.step);

    // Create the main executable
    const exe = b.addExecutable(.{
        .name = "zyncbase",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("sqlite", sqlite_module);
    exe.root_module.addImport("msgpack", msgpack_module);
    if (sanitize) |san| {
        if (std.mem.eql(u8, san, "thread")) {
            exe.root_module.sanitize_thread = true;
        }
    }
    linkUWS(b, exe, sysroot, sanitize);
    b.installArtifact(exe);

    // Setup Test Targets
    const test_step = b.step("test", "Run all tests");
    const test_filter = b.option([]const u8, "test-filter", "Filter tests by name");

    // 1. All Tests (Unified)
    const all_tests = setupTest(b, target, optimize, sqlite_module, msgpack_module, "src/test_all.zig", sanitize, test_filter, sysroot);
    const run_all_tests = b.addRunArtifact(all_tests);
    test_step.dependOn(&run_all_tests.step);

    // 2. Check Step (for ZLS)
    const check_step = b.step("check", "Check if the code compiles");

    const exe_check = b.addExecutable(.{
        .name = "zyncbase-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe_check.root_module.addImport("sqlite", sqlite_module);
    exe_check.root_module.addImport("msgpack", msgpack_module);
    linkUWS(b, exe_check, sysroot, sanitize);
    check_step.dependOn(&exe_check.step);

    const test_check = setupTest(b, target, optimize, sqlite_module, msgpack_module, "src/test_all.zig", sanitize, test_filter, sysroot);
    check_step.dependOn(&test_check.step);
}

fn setupTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sqlite_module: *std.Build.Module,
    msgpack_module: *std.Build.Module,
    root_file: []const u8,
    sanitize: ?[]const u8,
    test_filter: ?[]const u8,
    sysroot: ?[]const u8,
) *std.Build.Step.Compile {
    const t = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(root_file),
            .target = target,
            .optimize = optimize,
        }),
        .filters = if (test_filter) |filter|
            b.allocator.dupe([]const u8, &.{filter}) catch |err| @panic(b.fmt("Failed to dupe test filter: {s}", .{@errorName(err)}))
        else
            &.{},
    });

    t.root_module.addImport("sqlite", sqlite_module);
    t.root_module.addImport("msgpack", msgpack_module);
    if (sanitize) |san| {
        if (std.mem.eql(u8, san, "thread")) {
            t.root_module.sanitize_thread = true;
        }
    }
    linkUWS(b, t, sysroot, sanitize);
    return t;
}

fn linkUWS(b: *std.Build, step: *std.Build.Step.Compile, sysroot: ?[]const u8, sanitize: ?[]const u8) void {
    const target = step.root_module.resolved_target.?.result;
    step.linkLibCpp();
    step.linkSystemLibrary("pthread");
    
    // Core Linkage fix: Ensure we link the library's static artifact to avoid needing external headers.
    const sqlite_dep = b.dependency("sqlite", .{
        .target = step.root_module.resolved_target.?,
        .optimize = step.root_module.optimize.?,
    });
    step.linkLibrary(sqlite_dep.artifact("sqlite"));

    const is_linux = step.root_module.resolved_target.?.result.os.tag == .linux;

    var b_b_path: []const u8 = "vendor/boringssl/build";
    var b_b_include: []const u8 = "vendor/boringssl/include";
    var is_absolute = false;

    if (std.process.getEnvVarOwned(b.allocator, "ZYNCBASE_BORINGSSL_PATH")) |env_path| {
        b_b_path = env_path;
        is_absolute = true;
        // In local builds, we might set an absolute path to a target-specific BoringSSL build.
        // We assume the include directory is a sibling to the build directory in the submodule structure.
        b_b_include = b.fmt("{s}/../include", .{b_b_path});
    } else |_| if (is_linux) {
        if (std.process.getEnvVarOwned(b.allocator, "ZYNCBASE_LINUX_BORINGSSL_PATH")) |env_path| {
            b_b_path = env_path;
            is_absolute = true;
            b_b_include = b.fmt("{s}/../include", .{b_b_path});
        } else |_| {}
    }

    if (is_absolute) {
        step.addIncludePath(.{ .cwd_relative = b_b_include });
    } else {
        step.addIncludePath(b.path(b_b_include));
    }
    step.addIncludePath(b.path("vendor/bun/packages/bun-uws/src"));
    step.addIncludePath(b.path("vendor/bun/packages/bun-usockets/src"));
    step.addIncludePath(b.path("vendor/bun/src/deps"));
    step.addIncludePath(b.path("src"));

    if (is_absolute) {
        step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/libdecrepit.a", .{b_b_path}) });
        step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/libssl.a", .{b_b_path}) });
        step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/libcrypto.a", .{b_b_path}) });
    } else {
        step.addObjectFile(b.path(b.fmt("{s}/libdecrepit.a", .{b_b_path})));
        step.addObjectFile(b.path(b.fmt("{s}/libssl.a", .{b_b_path})));
        step.addObjectFile(b.path(b.fmt("{s}/libcrypto.a", .{b_b_path})));
    }

    if (is_linux) {
        step.linkSystemLibrary("dl");
    }

    const linux_flags: []const []const u8 = if (is_linux) &.{
        "-D_GNU_SOURCE",
        "-D_POSIX_C_SOURCE=200809L",
    } else &.{};

    const sanitize_flags: []const []const u8 = if (sanitize) |san| (if (std.mem.eql(u8, san, "thread"))
        &.{"-fsanitize=thread"}
    else
        &.{}) else &.{};

    const uws_flags = std.mem.concat(b.allocator, []const u8, &.{ linux_flags, sanitize_flags, &.{
        "-std=c++20",
        "-fno-sanitize=undefined",
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
        b.fmt("-I{s}", .{b_b_include}),
    } }) catch |err| @panic(b.fmt("Failed to concat uws_flags: {s}", .{@errorName(err)}));

    step.addCSourceFile(.{
        .file = b.path("vendor/bun/src/deps/libuwsockets.cpp"),
        .flags = uws_flags,
    });

    const usockets_flags = std.mem.concat(b.allocator, []const u8, &.{
        linux_flags, sanitize_flags, &.{
            "-std=c11",
            "-fno-sanitize=undefined", // Avoid trapping on alignment/bitfield issues in bun-usockets
            "-DUWS_NO_ZLIB",
            "-DUWS_USE_LIBDEFLATE=0",
            "-DLIBUS_USE_OPENSSL=1",
            "-DLIBUS_USE_BORINGSSL=1",
            "-DWITH_BORINGSSL=1",
            "-Wno-nullability-completeness",
            b.fmt("-I{s}", .{b_b_include}),
        },
    }) catch |err| @panic(b.fmt("Failed to concat usockets_flags: {s}", .{@errorName(err)}));

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

    const sni_flags = std.mem.concat(b.allocator, []const u8, &.{ linux_flags, sanitize_flags, &.{
        "-std=c++20",
        "-fno-sanitize=undefined",
        "-fno-exceptions",
        "-fno-rtti",
        "-DLIBUS_USE_OPENSSL=1",
        "-DLIBUS_USE_BORINGSSL=1",
        "-DWITH_BORINGSSL=1",
        b.fmt("-I{s}", .{b_b_include}),
    } }) catch |err| @panic(b.fmt("Failed to concat sni_flags: {s}", .{@errorName(err)}));

    step.addCSourceFile(.{
        .file = b.path("vendor/bun/packages/bun-usockets/src/crypto/sni_tree.cpp"),
        .flags = sni_flags,
    });

    const stubs_flags = std.mem.concat(b.allocator, []const u8, &.{ linux_flags, sanitize_flags, &.{
        "-std=c11",
    } }) catch |err| @panic(b.fmt("Failed to concat stubs_flags: {s}", .{@errorName(err)}));

    step.addCSourceFile(.{
        .file = b.path("src/uws_stubs.c"),
        .flags = stubs_flags,
    });

    step.linkLibC();
    if (target.os.tag == .macos) {
        if (sysroot) |s| {
            step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation.tbd", .{s}) });
            step.addObjectFile(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks/Security.framework/Security.tbd", .{s}) });
        } else {
            step.root_module.linkFramework("CoreFoundation", .{});
            step.root_module.linkFramework("Security", .{});
        }
    }
}
