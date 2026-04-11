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

pub fn main() void {
    @disableInstrumentation();

    parseArgs();

    const test_fn_list = builtin.test_functions;
    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;
    var leaks: usize = 0;
    var slowest_len: usize = 0;
    var slowest: [slowest_count]TimedResult = undefined;
    var suite_timer = startTimer("suite");

    for (test_fn_list, 0..) |test_fn, i| {
        testing.allocator_instance = .{};
        testing.log_level = .warn;

        var test_timer = startTimer(test_fn.name);
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

        const elapsed_ns = if (test_timer) |*timer| timer.read() else 0;
        insertSlowest(&slowest, &slowest_len, .{
            .name = test_fn.name,
            .elapsed_ns = elapsed_ns,
        });

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
                std.debug.dumpStackTrace(trace);
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

    const total_ns = if (suite_timer) |*timer| timer.read() else 0;

    std.debug.print("{d} passed; {d} skipped; {d} failed.\n", .{ ok_count, skip_count, fail_count });
    if (log_err_count != 0) {
        std.debug.print("{d} errors were logged.\n", .{log_err_count});
    }
    if (leaks != 0) {
        std.debug.print("{d} tests leaked memory.\n", .{leaks});
    }
    if (suite_timer != null) {
        std.debug.print("Total test time: {d:.3} ms\n", .{nsToMs(total_ns)});
    }

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

fn parseArgs() void {
    var args = std.process.argsWithAllocator(std.heap.page_allocator) catch
        @panic("unable to parse command line args");
    defer args.deinit();

    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--seed=")) {
            testing.random_seed = std.fmt.parseUnsigned(u32, arg["--seed=".len..], 0) catch
                @panic("unable to parse --seed command line argument");
        } else if (std.mem.startsWith(u8, arg, "--cache-dir=")) {
            continue;
        } else if (std.mem.eql(u8, arg, "--listen=-")) {
            continue;
        } else {
            @panic("unrecognized command line argument");
        }
    }
}

fn startTimer(label: []const u8) ?std.time.Timer {
    return std.time.Timer.start() catch |err| {
        std.debug.print("warning: timer unavailable for {s}: {s}\n", .{ label, @errorName(err) });
        return null;
    };
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
    return @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms);
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
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
