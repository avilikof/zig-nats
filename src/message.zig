const std = @import("std");

pub const NatsMessage = union(enum) {
    Msg: struct {
        subject: []const u8,
        sid: u32,
        reply_to: ?[]const u8,
        payload_size: u32,
        payload: ?[]u8,
        allocator: std.mem.Allocator,
    },
    Err: []const u8,
    Ok: void,
    Info: []const u8,
    Ping: void,
    Pong: void,
    Unsubscribed: void,

    pub fn deinit(self: *const NatsMessage) void {
        switch (self.*) {
            .Msg => |msg| {
                if (msg.payload) |payload| {
                    msg.allocator.free(payload);
                }
            },
            else => {},
        }
    }
};

pub fn parseReply(line: []const u8, allocator: std.mem.Allocator) !NatsMessage {
    if (std.mem.startsWith(u8, line, "MSG")) {
        return try parseMessage(line, allocator);
    } else if (std.mem.startsWith(u8, line, "PING")) {
        return NatsMessage{ .Ping = void{} };
    } else if (std.mem.startsWith(u8, line, "PONG")) {
        return NatsMessage{ .Pong = void{} };
    } else if (std.mem.eql(u8, line, "+OK")) {
        return NatsMessage{ .Ok = void{} };
    } else if (std.mem.startsWith(u8, line, "-ERR")) {
        const err_msg = line[5..]; // skip "-ERR "
        return NatsMessage{ .Err = err_msg };
    } else if (std.mem.startsWith(u8, line, "INFO")) {
        const json = line[5..];
        return NatsMessage{ .Info = json };
    } else if (std.mem.startsWith(u8, line, "UNSUB")) {
        return NatsMessage{ .Unsubscribed = void{} };
    }

    std.log.err("{s}", .{line});

    return error.UnknownMessage;
}
fn parseMessage(line: []const u8, allocator: std.mem.Allocator) !NatsMessage {
    const message = try tokenize(line);
    const tokens = message.tokens;

    // Skip MSG
    const subject = tokens[1] orelse return error.ParseError;
    const sid = tokens[2] orelse return error.ParseError;

    var reply_to: ?[]const u8 = undefined;
    var payload_size_str: []const u8 = undefined;

    if (message.size == 5) {
        reply_to = tokens[3] orelse return error.ParseError;
        payload_size_str = tokens[4] orelse return error.ParseError;
    } else {
        reply_to = null;
        payload_size_str = tokens[3] orelse return error.ParseError;
    }

    // Trim whitespace and \r\n from payload_size_str before parsing
    const trimmed_size = std.mem.trim(u8, payload_size_str, " \r\n");

    return NatsMessage{
        .Msg = .{
            .subject = subject,
            .sid = std.fmt.parseInt(u32, sid, 10) catch return error.ParseError,
            .reply_to = reply_to,
            .payload_size = std.fmt.parseInt(u32, trimmed_size, 10) catch return error.ParseError,
            .payload = null,
            .allocator = allocator, // Required for cleanup
        },
    };
}

fn tokenize(line: []const u8) !struct {
    tokens: [5]?[]const u8,
    size: usize,
} {
    var tokens: [5]?[]const u8 = .{null} ** 5;

    var message = std.mem.splitSequence(u8, line, " ");

    var size: usize = 0;

    while (message.next()) |token| : (size += 1) {
        if (size >= tokens.len) break;
        tokens[size] = token;
    }

    if (size < 4) {
        return error.InvalidMessage;
    }

    return .{ .tokens = tokens, .size = size };
}

const testing = std.testing;

test "parseReply - PING message" {
    const message = try parseReply("PING", testing.allocator);
    switch (message) {
        .Ping => {},
        else => return error.TestFailed,
    }
}

test "parseReply - PONG message" {
    const message = try parseReply("PONG", testing.allocator);
    switch (message) {
        .Pong => {},
        else => return error.TestFailed,
    }
}

test "parseReply - OK message" {
    const message = try parseReply("+OK", testing.allocator);
    switch (message) {
        .Ok => {},
        else => return error.TestFailed,
    }
}

test "parseReply - ERROR message" {
    const message = try parseReply("-ERR 'Permission Denied'", testing.allocator);
    switch (message) {
        .Err => |err_msg| {
            try testing.expectEqualStrings("'Permission Denied'", err_msg);
        },
        else => return error.TestFailed,
    }
}

test "parseReply - INFO message" {
    const info_json = "{\"server_id\":\"test\",\"version\":\"2.9.0\"}";
    const full_line = try std.fmt.allocPrint(testing.allocator, "INFO {s}", .{info_json});
    defer testing.allocator.free(full_line);

    const message = try parseReply(full_line, testing.allocator);
    switch (message) {
        .Info => |json| {
            try testing.expectEqualStrings(info_json, json);
        },
        else => return error.TestFailed,
    }
}

test "parseReply - MSG without reply_to" {
    const message = try parseReply("MSG foo.bar 123 11", testing.allocator);
    defer message.deinit();

    switch (message) {
        .Msg => |msg| {
            try testing.expectEqualStrings("foo.bar", msg.subject);
            try testing.expectEqual(@as(u32, 123), msg.sid);
            try testing.expectEqual(@as(?[]const u8, null), msg.reply_to);
            try testing.expectEqual(@as(u32, 11), msg.payload_size);
            try testing.expect(msg.payload == null); // Payload not read yet
        },
        else => return error.TestFailed,
    }
}

test "parseReply - MSG with reply_to" {
    const message = try parseReply("MSG foo.bar 123 reply.subject 11", testing.allocator);
    defer message.deinit();

    switch (message) {
        .Msg => |msg| {
            try testing.expectEqualStrings("foo.bar", msg.subject);
            try testing.expectEqual(@as(u32, 123), msg.sid);
            try testing.expectEqualStrings("reply.subject", msg.reply_to.?);
            try testing.expectEqual(@as(u32, 11), msg.payload_size);
        },
        else => return error.TestFailed,
    }
}

test "parseReply - MSG with whitespace and CRLF in size" {
    const message = try parseReply("MSG foo.bar 123 reply.subject 11\r\n", testing.allocator);
    defer message.deinit();

    switch (message) {
        .Msg => |msg| {
            try testing.expectEqual(@as(u32, 11), msg.payload_size);
        },
        else => return error.TestFailed,
    }
}

test "parseReply - unknown message type" {
    const result = parseReply("UNKNOWN", testing.allocator);
    try testing.expectError(error.UnknownMessage, result);
}

test "parseMessage - invalid message with too few tokens" {
    const result = parseReply("MSG foo", testing.allocator);
    try testing.expectError(error.InvalidMessage, result);
}

test "parseMessage - invalid SID" {
    const result = parseReply("MSG foo.bar invalid_sid 11", testing.allocator);
    try testing.expectError(error.ParseError, result);
}

test "parseMessage - invalid payload size" {
    const result = parseReply("MSG foo.bar 123 invalid_size", testing.allocator);
    try testing.expectError(error.ParseError, result);
}

test "tokenize - valid message" {
    const result = try tokenize("MSG foo.bar 123 11");
    try testing.expectEqual(@as(usize, 4), result.size);
    try testing.expectEqualStrings("MSG", result.tokens[0].?);
    try testing.expectEqualStrings("foo.bar", result.tokens[1].?);
    try testing.expectEqualStrings("123", result.tokens[2].?);
    try testing.expectEqualStrings("11", result.tokens[3].?);
}

test "tokenize - message with reply_to" {
    const result = try tokenize("MSG foo.bar 123 reply.subject 11");
    try testing.expectEqual(@as(usize, 5), result.size);
    try testing.expectEqualStrings("reply.subject", result.tokens[3].?);
    try testing.expectEqualStrings("11", result.tokens[4].?);
}

test "tokenize - insufficient tokens" {
    const result = tokenize("MSG foo");
    try testing.expectError(error.InvalidMessage, result);
}

test "NatsMessage.deinit - with payload" {
    var message = NatsMessage{
        .Msg = .{
            .subject = "test.subject",
            .sid = 123,
            .reply_to = null,
            .payload_size = 5,
            .payload = try testing.allocator.dupe(u8, "hello"),
            .allocator = testing.allocator,
        },
    };

    // This should not leak memory
    message.deinit();
}

test "NatsMessage.deinit - without payload" {
    const message = NatsMessage{
        .Msg = .{
            .subject = "test.subject",
            .sid = 123,
            .reply_to = null,
            .payload_size = 0,
            .payload = null,
            .allocator = testing.allocator,
        },
    };

    // This should be safe to call
    message.deinit();
}
