// zlint-disable

const builtin = @import("builtin");
const std = @import("std");

const testing = std.testing;

pub const std_options: std.Options = .{
    .logFn = log,
};

const slowest_count = 10;

const TimedResult = struct {
    name: []const u8,
    elapsed_ns: u64,
};

var log_err_count: usize = 0;
const runner_io = std.Io.Threaded.global_single_threaded.io();

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();

    parseArgs(init.args);

    const test_fn_list = builtin.test_functions;
    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;
    var leaks: usize = 0;
    var slowest_len: usize = 0;
    var slowest: [slowest_count]TimedResult = undefined;
    const suite_start_ns = nowNs();

    for (test_fn_list, 0..) |test_fn, i| {
        testing.allocator_instance = .{};
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        testing.log_level = .warn;
        testing.environ = init.environ;

        const test_start_ns = nowNs();
        var failed = false;
        var skipped = false;
        var failure_trace: ?std.builtin.StackTrace = null;
        var failure_err_name: ?[]const u8 = null;

        test_fn.func() catch |err| switch (err) {
            error.SkipZigTest => skipped = true,
            else => {
                failed = true;
                failure_err_name = @errorName(err);
                if (@errorReturnTrace()) |trace| {
                    failure_trace = trace.*;
                }
            },
        };

        const elapsed_ns = nowNs() - test_start_ns;
        insertSlowest(&slowest, &slowest_len, .{
            .name = test_fn.name,
            .elapsed_ns = elapsed_ns,
        });

        testing.io_instance.deinit();
        const leaked = testing.allocator_instance.deinit() == .leak;
        if (leaked) {
            leaks += 1;
        }

        if (failed) {
            fail_count += 1;
            std.debug.print(
                "{d}/{d} {s}...FAIL ({d:.3} ms)\n",
                .{ i + 1, test_fn_list.len, test_fn.name, nsToMs(elapsed_ns) },
            );
            if (failure_trace) |trace| {
                std.debug.dumpErrorReturnTrace(&trace);
            }
            std.debug.print("failed with error.{s}\n", .{failure_err_name orelse "Unknown"});
            continue;
        }

        if (skipped) {
            skip_count += 1;
            std.debug.print(
                "{d}/{d} {s}...SKIP ({d:.3} ms)\n",
                .{ i + 1, test_fn_list.len, test_fn.name, nsToMs(elapsed_ns) },
            );
            continue;
        }

        if (leaked) {
            std.debug.print(
                "{d}/{d} {s}...LEAK ({d:.3} ms)\n",
                .{ i + 1, test_fn_list.len, test_fn.name, nsToMs(elapsed_ns) },
            );
            continue;
        }

        ok_count += 1;
    }

    const total_ns = nowNs() - suite_start_ns;

    std.debug.print("{d} passed; {d} skipped; {d} failed.\n", .{ ok_count, skip_count, fail_count });
    if (log_err_count != 0) {
        std.debug.print("{d} errors were logged.\n", .{log_err_count});
    }
    if (leaks != 0) {
        std.debug.print("{d} tests leaked memory.\n", .{leaks});
    }
    std.debug.print("Total test time: {d:.3} ms\n", .{nsToMs(total_ns)});

    if (slowest_len != 0) {
        std.debug.print("Top {d} slowest tests:\n", .{slowest_len});
        for (slowest[0..slowest_len], 0..) |result, i| {
            std.debug.print("{d}. {s} - {d:.3} ms\n", .{ i + 1, result.name, nsToMs(result.elapsed_ns) });
        }
    }

    if (leaks != 0 or log_err_count != 0 or fail_count != 0) {
        std.process.exit(1);
    }
}

fn parseArgs(init_args: std.process.Args) void {
    const args = init_args.toSlice(std.heap.page_allocator) catch @panic("unable to parse command line args");
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--seed=")) {
            testing.random_seed = std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0) catch
                @panic("unable to parse --seed command line argument");
        } else if (std.mem.startsWith(u8, arg, "--cache-dir=")) {
            continue;
        } else if (std.mem.eql(u8, arg, "--listen=-")) {
            continue;
        } else {
            continue;
        }
    }
}

fn nowNs() u64 {
    return @intCast(std.Io.Clock.awake.now(runner_io).toNanoseconds());
}

fn insertSlowest(slowest: []TimedResult, slowest_len: *usize, candidate: TimedResult) void {
    if (slowest.len == 0) return;

    var insert_at = slowest_len.*;
    if (insert_at < slowest.len) {
        slowest_len.* += 1;
    } else if (candidate.elapsed_ns <= slowest[slowest_len.* - 1].elapsed_ns) {
        return;
    } else {
        insert_at = slowest_len.* - 1;
    }

    while (insert_at > 0 and candidate.elapsed_ns > slowest[insert_at - 1].elapsed_ns) {
        slowest[insert_at] = slowest[insert_at - 1];
        insert_at -= 1;
    }
    slowest[insert_at] = candidate;
}

fn nsToMs(ns: u64) f64 {
    const ns_f: f64 = @floatFromInt(ns);
    const divisor: f64 = @floatFromInt(std.time.ns_per_ms);
    return ns_f / divisor;
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}
