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
