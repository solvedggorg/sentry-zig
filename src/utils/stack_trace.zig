const std = @import("std");
const types = @import("types");
const sentry_build = @import("sentry_build");
const Frame = types.Frame;
const StackTrace = types.StackTrace;
const ArrayList = std.array_list.Managed;

/// Collects stack trace frames from the given initial address.
/// Allocates memory for frames and returns a StackTrace.
pub fn collectStackTrace(allocator: std.mem.Allocator, first_trace_addr: ?usize) !StackTrace {
    var frames_list = ArrayList(Frame).init(allocator);
    errdefer {
        for (frames_list.items) |*frame| {
            frame.deinit();
        }
        frames_list.deinit();
    }

    var addr_buf: [64]usize = undefined;
    const captured = std.debug.captureCurrentStackTrace(.{
        .first_address = first_trace_addr,
        .allow_unsafe_unwind = true,
    }, &addr_buf);

    const project_root = getProjectRoot(allocator);
    defer if (project_root) |root| allocator.free(root);

    for (captured.return_addresses) |return_address| {
        var frame = Frame{
            .allocator = allocator,
            .instruction_addr = try std.fmt.allocPrint(allocator, "0x{x}", .{return_address}),
        };

        // Best-effort: address-only frames; server-side symbolication fills the rest.
        categorizeFrame(&frame, project_root);

        if (isValidFrame(&frame) and !isPanicHandlerFrame(frame.filename, frame.function)) {
            try frames_list.append(frame);
        } else {
            frame.deinit();
        }
    }

    // captureCurrentStackTrace is innermost-first; Sentry expects outer→inner in some
    // clients, but the historical SDK reversed to match envelope tests. Keep reverse.
    const frames = try frames_list.toOwnedSlice();
    std.mem.reverse(Frame, frames);

    return StackTrace{
        .allocator = allocator,
        .frames = frames,
        .registers = null,
    };
}

/// Collects stack trace from an error's return trace if available.
pub fn collectErrorTrace(allocator: std.mem.Allocator, err_trace: ?*std.builtin.StackTrace) !?StackTrace {
    const trace = err_trace orelse return null;

    var frames_list = ArrayList(Frame).init(allocator);
    errdefer {
        for (frames_list.items) |*frame| {
            frame.deinit();
        }
        frames_list.deinit();
    }

    const project_root = getProjectRoot(allocator);
    defer if (project_root) |root| allocator.free(root);

    for (trace.instruction_addresses[0..trace.index]) |addr| {
        var frame = Frame{
            .allocator = allocator,
            .instruction_addr = try std.fmt.allocPrint(allocator, "0x{x}", .{addr}),
        };

        categorizeFrame(&frame, project_root);

        if (isValidFrame(&frame) and !isPanicHandlerFrame(frame.filename, frame.function)) {
            try frames_list.append(frame);
        } else {
            frame.deinit();
        }
    }

    if (frames_list.items.len == 0) return null;

    const frames = try frames_list.toOwnedSlice();
    std.mem.reverse(Frame, frames);

    return StackTrace{
        .allocator = allocator,
        .frames = frames,
        .registers = null,
    };
}

fn parseSymbolLine(allocator: std.mem.Allocator, line: []const u8, frame: *Frame) void {
    if (std.mem.indexOf(u8, line, ":")) |first_colon| {
        const file_part = line[0..first_colon];
        frame.filename = allocator.dupe(u8, file_part) catch null;
        frame.abs_path = allocator.dupe(u8, file_part) catch null;

        const rest = line[first_colon + 1 ..];
        if (std.mem.indexOf(u8, rest, ":")) |second_colon| {
            const line_str = rest[0..second_colon];
            frame.lineno = std.fmt.parseInt(u32, line_str, 10) catch null;

            const after_line = rest[second_colon + 1 ..];
            if (std.mem.indexOf(u8, after_line, ":")) |third_colon| {
                const col_str = after_line[0..third_colon];
                frame.colno = std.fmt.parseInt(u32, col_str, 10) catch null;

                const after_col = after_line[third_colon + 1 ..];
                if (std.mem.indexOf(u8, after_col, " in ")) |in_pos| {
                    const after_in = after_col[in_pos + 4 ..];
                    var func_name = after_in;

                    if (std.mem.lastIndexOf(u8, func_name, " (")) |last_space_paren| {
                        func_name = func_name[0..last_space_paren];
                    }

                    func_name = std.mem.trim(u8, func_name, " \t\r\n");
                    if (func_name.len > 0) {
                        frame.function = allocator.dupe(u8, func_name) catch null;
                    }
                }
            }
        }
    }
}

test "collectStackTrace creates frames with addresses" {
    const allocator = std.testing.allocator;

    var stacktrace = try collectStackTrace(allocator, @returnAddress());
    defer stacktrace.deinit();

    // May be empty if stack tracing is disabled for the target/config.
    for (stacktrace.frames) |frame| {
        try std.testing.expect(frame.instruction_addr != null);
    }
}

fn getProjectRoot(allocator: std.mem.Allocator) ?[]const u8 {
    if (sentry_build.sentry_project_root.len != 0) {
        return allocator.dupe(u8, sentry_build.sentry_project_root) catch null;
    }
    return null;
}

/// Check if a frame is valid and contains meaningful information
fn isValidFrame(frame: *const Frame) bool {
    if (frame.instruction_addr == null) return false;

    if (frame.instruction_addr) |addr_str| {
        if (addr_str.len < 3 or !std.mem.startsWith(u8, addr_str, "0x")) {
            return false;
        }
        if (std.mem.eql(u8, addr_str, "0x0")) {
            return false;
        }
    }

    if (frame.filename) |filename| {
        if (std.mem.eql(u8, filename, "???")) return false;
    }
    if (frame.function) |function| {
        if (std.mem.eql(u8, function, "???")) return false;
    }
    if (frame.abs_path) |abs_path| {
        if (std.mem.eql(u8, abs_path, "???")) return false;
    }

    return true;
}

/// Check if a frame belongs to panic handler infrastructure that should be filtered out
fn isPanicHandlerFrame(filename: ?[]const u8, function: ?[]const u8) bool {
    if (filename) |file| {
        if (std.mem.indexOf(u8, file, "panic_handler.zig") != null) {
            if (function) |func| {
                if (std.mem.eql(u8, func, "panicHandler") or
                    std.mem.eql(u8, func, "handlePanic") or
                    std.mem.eql(u8, func, "createSentryEvent") or
                    std.mem.eql(u8, func, "createEventWithFrames") or
                    std.mem.eql(u8, func, "createMinimalEvent")) return true;
            }
        }
    }

    return false;
}

fn isSystemFrame(filename: ?[]const u8, function: ?[]const u8) bool {
    _ = function;
    if (filename) |file| {
        const root = sentry_build.sentry_project_root;
        if (root.len > 0) {
            if (std.mem.startsWith(u8, file, root)) return false;
            return true;
        }
    }
    return true;
}

fn isApplicationFrame(filename: ?[]const u8, function: ?[]const u8, project_root: ?[]const u8) bool {
    if (filename) |file| {
        if (std.mem.eql(u8, file, "???")) return false;
    }
    if (function) |func| {
        if (std.mem.eql(u8, func, "???")) return false;
    }

    if (project_root) |root| {
        if (filename) |file| {
            if (std.mem.startsWith(u8, file, root)) return true;
        }
    }

    return false;
}

fn categorizeFrame(frame: *Frame, project_root: ?[]const u8) void {
    if (!isValidFrame(frame)) {
        frame.in_app = false;
        return;
    }

    if (isApplicationFrame(frame.filename, frame.function, project_root)) {
        frame.in_app = true;
    } else {
        frame.in_app = false;
    }
}

test "parseSymbolLine extracts file and line info" {
    const allocator = std.testing.allocator;

    var frame = Frame{
        .allocator = allocator,
    };
    defer frame.deinit();

    const test_line = "src/main.zig:42:13: 0x123456 in main (test.exe)";
    parseSymbolLine(allocator, test_line, &frame);

    try std.testing.expect(frame.filename != null);
    try std.testing.expectEqualStrings("src/main.zig", frame.filename.?);
    try std.testing.expect(frame.lineno != null);
    try std.testing.expectEqual(@as(u32, 42), frame.lineno.?);
    try std.testing.expect(frame.colno != null);
    try std.testing.expectEqual(@as(u32, 13), frame.colno.?);
    try std.testing.expect(frame.function != null);
    try std.testing.expectEqualStrings("main", frame.function.?);
}

test "frame detection: isValidFrame correctly validates frames" {
    var frame_valid = Frame{
        .instruction_addr = "0x1234567890abcdef",
        .filename = "src/main.zig",
        .function = "main",
    };
    try std.testing.expect(isValidFrame(&frame_valid));

    var frame_only_addr = Frame{
        .instruction_addr = "0x1234567890abcdef",
    };
    try std.testing.expect(isValidFrame(&frame_only_addr));

    var frame_invalid_addr = Frame{
        .instruction_addr = "invalid",
    };
    try std.testing.expect(!isValidFrame(&frame_invalid_addr));

    var frame_no_addr = Frame{
        .filename = "src/main.zig",
    };
    try std.testing.expect(!isValidFrame(&frame_no_addr));

    var frame_question_marks = Frame{
        .instruction_addr = "0x1234567890abcdef",
        .filename = "???",
        .function = "???",
        .abs_path = "???",
    };
    try std.testing.expect(!isValidFrame(&frame_question_marks));

    var frame_null_ptr = Frame{
        .instruction_addr = "0x0",
        .filename = "src/main.zig",
    };
    try std.testing.expect(!isValidFrame(&frame_null_ptr));
}

test "frame detection: isSystemFrame derived from build project root" {
    const root = sentry_build.sentry_project_root;
    if (root.len == 0) return error.SkipZigTest;

    const in_app = std.fmt.allocPrint(std.testing.allocator, "{s}/src/main.zig", .{root}) catch return error.SkipZigTest;
    defer std.testing.allocator.free(in_app);

    try std.testing.expect(!isSystemFrame(in_app, null));
    try std.testing.expect(isSystemFrame("/usr/lib/libc.so", null));
}

test "frame detection: isPanicHandlerFrame correctly identifies panic handler frames" {
    try std.testing.expect(!isPanicHandlerFrame(null, "panicHandler"));
    try std.testing.expect(!isPanicHandlerFrame(null, "handlePanic"));
    try std.testing.expect(!isPanicHandlerFrame(null, "createSentryEvent"));
    try std.testing.expect(!isPanicHandlerFrame(null, "createEventWithFrames"));
    try std.testing.expect(!isPanicHandlerFrame(null, "createMinimalEvent"));

    try std.testing.expect(isPanicHandlerFrame("/path/to/panic_handler.zig", "panicHandler"));
    try std.testing.expect(isPanicHandlerFrame("src/panic_handler.zig", "handlePanic"));

    try std.testing.expect(!isPanicHandlerFrame("src/main.zig", "main"));
    try std.testing.expect(!isPanicHandlerFrame(null, "myFunction"));
    try std.testing.expect(!isPanicHandlerFrame("panic_handler.zig", "userFunction"));
}

test "frame detection: isApplicationFrame correctly identifies app frames (build-root only)" {
    const project_root = "/home/user/myproject";

    try std.testing.expect(isApplicationFrame("/home/user/myproject/src/main.zig", null, project_root));
    try std.testing.expect(!isApplicationFrame("src/main.zig", null, null));
    try std.testing.expect(!isApplicationFrame("src/lib.zig", "myFunction", null));

    try std.testing.expect(!isApplicationFrame("/lib/zig/std/debug.zig", null, project_root));
    try std.testing.expect(!isApplicationFrame(null, "std.debug.print", project_root));
    try std.testing.expect(!isApplicationFrame("/usr/lib/libc.so", null, project_root));

    try std.testing.expect(!isApplicationFrame("???", null, project_root));
    try std.testing.expect(!isApplicationFrame(null, "???", project_root));
    try std.testing.expect(!isApplicationFrame("???", "???", project_root));
}

test "frame detection: categorizeFrame sets in_app correctly" {
    const allocator = std.testing.allocator;
    const project_root = "/home/user/myproject";

    var app_frame = Frame{
        .allocator = allocator,
        .instruction_addr = allocator.dupe(u8, "0x1234567890abcdef") catch unreachable,
        .filename = allocator.dupe(u8, "/home/user/myproject/src/main.zig") catch unreachable,
        .function = allocator.dupe(u8, "main") catch unreachable,
    };
    defer app_frame.deinit();

    categorizeFrame(&app_frame, project_root);
    try std.testing.expect(app_frame.in_app == true);

    var sys_frame = Frame{
        .allocator = allocator,
        .instruction_addr = allocator.dupe(u8, "0xabcdef1234567890") catch unreachable,
        .filename = allocator.dupe(u8, "/lib/zig/std/debug.zig") catch unreachable,
        .function = allocator.dupe(u8, "std.debug.print") catch unreachable,
    };
    defer sys_frame.deinit();

    categorizeFrame(&sys_frame, project_root);
    try std.testing.expect(sys_frame.in_app == false);

    var addr_only_frame = Frame{
        .allocator = allocator,
        .instruction_addr = std.fmt.allocPrint(allocator, "0x{x}", .{@returnAddress()}) catch return error.SkipZigTest,
    };
    defer addr_only_frame.deinit();

    categorizeFrame(&addr_only_frame, project_root);
    try std.testing.expect(addr_only_frame.in_app == false);
}

test "frame detection: Docker path handling" {
    const allocator = std.testing.allocator;
    const docker_project_root = "/app";

    var docker_app_frame = Frame{
        .allocator = allocator,
        .instruction_addr = allocator.dupe(u8, "0x1234567890abcdef") catch unreachable,
        .filename = allocator.dupe(u8, "/app/src/main.zig") catch unreachable,
        .function = allocator.dupe(u8, "main") catch unreachable,
    };
    defer docker_app_frame.deinit();

    categorizeFrame(&docker_app_frame, docker_project_root);
    try std.testing.expect(docker_app_frame.in_app == true);

    var docker_example_frame = Frame{
        .allocator = allocator,
        .instruction_addr = allocator.dupe(u8, "0xabcdef1234567890") catch unreachable,
        .filename = allocator.dupe(u8, "/app/examples/panic_handler.zig") catch unreachable,
        .function = allocator.dupe(u8, "main") catch unreachable,
    };
    defer docker_example_frame.deinit();

    categorizeFrame(&docker_example_frame, docker_project_root);
    try std.testing.expect(docker_example_frame.in_app == true);

    var docker_lib_frame = Frame{
        .allocator = allocator,
        .instruction_addr = allocator.dupe(u8, "0xfedcba0987654321") catch unreachable,
        .filename = allocator.dupe(u8, "/usr/local/lib/zig/std/debug.zig") catch unreachable,
        .function = allocator.dupe(u8, "std.debug.print") catch unreachable,
    };
    defer docker_lib_frame.deinit();

    categorizeFrame(&docker_lib_frame, docker_project_root);
    try std.testing.expect(docker_lib_frame.in_app == false);
}
