const std = @import("std");

/// Zig 0.16 moved wall/monotonic clocks into std.Io; libc-backed helpers for
/// code paths that do not yet thread an Io through (event IDs, envelope stamps).

pub fn nanoTimestamp() i128 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i128, @intCast(ts.sec)) * 1_000_000_000 + @as(i128, @intCast(ts.nsec));
}

pub fn timestamp() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    return @intCast(ts.sec);
}

pub fn sleep(ns: u64) void {
    const sec: i64 = @intCast(ns / 1_000_000_000);
    const nsec: i64 = @intCast(ns % 1_000_000_000);
    var req: std.c.timespec = .{ .sec = sec, .nsec = nsec };
    _ = std.c.nanosleep(&req, null);
}
