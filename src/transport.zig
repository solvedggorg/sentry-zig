const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const types = @import("types");
const SentryOptions = types.SentryOptions;
const SentryEnvelope = types.SentryEnvelope;
const TransportResult = types.TransportResult;
const SentryEnvelopeItem = types.SentryEnvelopeItem;
const SentryEnvelopeHeader = types.SentryEnvelopeHeader;
const EventId = types.EventId;
const Event = types.Event;
const test_utils = @import("utils/test_utils.zig");

pub const HttpTransport = struct {
    client: std.http.Client,
    options: SentryOptions,
    allocator: Allocator,

    pub fn init(allocator: Allocator, io: Io, options: *const SentryOptions) HttpTransport {
        return HttpTransport{
            .client = .{
                .allocator = allocator,
                .io = io,
            },
            .options = options.*,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HttpTransport) void {
        self.client.deinit();
    }

    pub fn send(self: *HttpTransport, envelope: SentryEnvelope) !TransportResult {
        const payload = try self.envelopeToPayload(envelope);
        defer self.allocator.free(payload);

        const dsn = self.options.dsn orelse {
            return TransportResult{ .response_code = 0 };
        };

        const netloc = dsn.getNetloc(self.allocator) catch {
            return TransportResult{ .response_code = 0 };
        };
        defer self.allocator.free(netloc);

        const endpoint_url = std.fmt.allocPrint(self.allocator, "{s}://{s}/api/{s}/envelope/", .{
            dsn.scheme,
            netloc,
            dsn.project_id,
        }) catch {
            return TransportResult{ .response_code = 0 };
        };
        defer self.allocator.free(endpoint_url);

        const auth_header = std.fmt.allocPrint(self.allocator, "Sentry sentry_version=7,sentry_key={s},sentry_client=sentry-zig/0.1.1", .{
            dsn.public_key,
        }) catch {
            return TransportResult{ .response_code = 0 };
        };
        defer self.allocator.free(auth_header);

        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = "application/x-sentry-envelope" },
            .{ .name = "X-Sentry-Auth", .value = auth_header },
        };

        var response_aw: Io.Writer.Allocating = .init(self.allocator);
        defer response_aw.deinit();

        const result = self.client.fetch(.{
            .location = .{ .url = endpoint_url },
            .method = .POST,
            .extra_headers = &headers,
            .payload = payload,
            .response_writer = &response_aw.writer,
        }) catch {
            return TransportResult{ .response_code = 0 };
        };
        std.log.debug("sending payload {s}", .{payload});
        std.log.debug("http response {}", .{@as(i64, @intCast(@intFromEnum(result.status)))});

        return TransportResult{ .response_code = @intCast(@intFromEnum(result.status)) };
    }

    pub fn envelopeToPayload(self: *HttpTransport, envelope: SentryEnvelope) ![]u8 {
        var aw: Io.Writer.Allocating = .init(self.allocator);
        errdefer aw.deinit();

        try std.json.Stringify.value(envelope.header, .{}, &aw.writer);
        try aw.writer.writeByte('\n');

        for (envelope.items, 0..) |item, i| {
            try std.json.Stringify.value(item.header, .{}, &aw.writer);
            try aw.writer.writeByte('\n');
            try aw.writer.writeAll(item.data);
            if (i < envelope.items.len - 1) {
                try aw.writer.writeByte('\n');
            }
        }

        return try aw.toOwnedSlice();
    }

    pub fn envelopeFromEvent(self: *HttpTransport, event: Event) !SentryEnvelopeItem {
        const data = try std.json.Stringify.valueAlloc(self.allocator, event, .{});
        return SentryEnvelopeItem{
            .header = .{
                .type = .event,
                .length = @intCast(data.len),
            },
            .data = data,
        };
    }
};

test "Envelope - Serialize empty envelope" {
    const allocator = testing.allocator;
    const io = testing.io;

    var transport = HttpTransport.init(allocator, io, &SentryOptions{});

    const cstr: [*:0]const u8 = "24f9202c3c9f44deabef9ed3132b41e4";
    var event_id: [32]u8 = undefined;
    @memcpy(event_id[0..32], cstr[0..32]);

    const payload = try transport.envelopeToPayload(SentryEnvelope{
        .header = SentryEnvelopeHeader{
            .event_id = EventId{
                .value = event_id,
            },
        },
        .items = &[_]SentryEnvelopeItem{},
    });
    defer allocator.free(payload);
    try testing.expectEqualStrings("{\"event_id\":\"24f9202c3c9f44deabef9ed3132b41e4\"}\n", payload);
}

test "Envelope - Serialize event-id header" {
    const allocator = testing.allocator;
    const io = testing.io;

    var transport = HttpTransport.init(allocator, io, &SentryOptions{});

    const cstr: [*:0]const u8 = "24f9202c3c9f44deabef9ed3132b41e4";
    var event_id: [32]u8 = undefined;
    @memcpy(event_id[0..32], cstr[0..32]);

    const payload = try transport.envelopeToPayload(SentryEnvelope{
        .header = SentryEnvelopeHeader{
            .event_id = EventId{
                .value = event_id,
            },
        },
        .items = &[_]SentryEnvelopeItem{},
    });
    defer allocator.free(payload);
    try testing.expectEqualStrings("{\"event_id\":\"24f9202c3c9f44deabef9ed3132b41e4\"}\n", payload);
}

test "Envelope - Serialize envelope with empty event" {
    const allocator = testing.allocator;
    const io = testing.io;

    const cstr: [*:0]const u8 = "24f9202c3c9f44deabef9ed3132b41e4";
    var event_id: [32]u8 = undefined;
    @memcpy(event_id[0..32], cstr[0..32]);

    var item_buf = [_]SentryEnvelopeItem{
        .{
            .header = .{
                .type = .event,
                .length = 0,
            },
            .data = "",
        },
    };

    var transport = HttpTransport.init(allocator, io, &SentryOptions{});

    const payload = try transport.envelopeToPayload(SentryEnvelope{
        .header = SentryEnvelopeHeader{
            .event_id = EventId{
                .value = event_id,
            },
        },
        .items = item_buf[0..],
    });
    defer allocator.free(payload);
    try testing.expectEqualStrings("{\"event_id\":\"24f9202c3c9f44deabef9ed3132b41e4\"}\n{\"type\":\"event\",\"length\":0}\n", payload);
}

test "Envelope - Serialize full envelope item from event" {
    const allocator = testing.allocator;
    const io = testing.io;

    var event = try test_utils.createFullTestEvent(allocator);
    defer event.deinit();

    event.event_id = EventId{ .value = "24f9202c3c9f44deabef9ed3132b41e4".* };
    event.timestamp = 1640995200.0;

    if (event.breadcrumbs) |*breadcrumbs| {
        for (breadcrumbs.values) |*breadcrumb| {
            breadcrumb.timestamp = 1640995200;
        }
    }

    var transport = HttpTransport.init(allocator, io, &SentryOptions{});
    const json_result = try transport.envelopeFromEvent(event);
    defer allocator.free(json_result.data);
    const json_string = json_result.data;

    const expected_json =
        \\{"event_id":"24f9202c3c9f44deabef9ed3132b41e4","timestamp":1640995200,"platform":"native","level":"error","logger":"test-logger","transaction":"test-transaction","server_name":"test-server","release":"1.0.0","dist":"1","environment":"test","fingerprint":["custom","fingerprint"],"tags":{"environment":"test","version":"1.0.0"},"modules":{"mymodule":"1.0.0"},"message":{"message":"Test error message","formatted":"Test error message"},"breadcrumbs":{"values":[{"message":"HTTP Request","type":"http","level":"info","timestamp":1640995200,"category":"http","data":{"url":"/api/test","method":"GET"}}]},"user":{"id":"123","username":"testuser","email":"test@example.com","name":"Test User","ip_address":"192.168.1.1"}}
    ;

    try testing.expectEqualStrings(expected_json, json_string);
}
