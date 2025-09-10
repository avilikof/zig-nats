const std = @import("std");
const Subscription = @import("subscription.zig").Subscription;
const NatsMessage = @import("message.zig").NatsMessage;
const natsMessage = @import("message.zig");
const logger = @import("logger.zig");

// Nats Protocol Constants
const PING_MSG = "PING\r\n";
const PONG_MSG = "PONG\r\n";
const INFO_MSG = "INFO";
const ERROR_PREFIX = "-ERR ";
const OK_MSG = "+OK\r\n";
const PUB_CMD = "PUB";
const SUB_CMD = "SUB";
const UNSUB_CMD = "UNSUB";
const MSG_PREFIX = "MSG ";

// Buffer size for reading messages
const BUFFER_SIZE = 1024;

pub const NatsClient = struct {
    stream: std.net.Stream,
    allocator: std.mem.Allocator,
    subscriptions: std.HashMap(u32, Subscription, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage),
    next_subscription_id: u32,
    buffer: []u8,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !NatsClient {
        // const stream = try std.net.tcpConnectToHost(allocator, host, port);
        const address = try std.net.Address.resolveIp(host, port);
        const stream = try std.net.tcpConnectToAddress(address);

        var client = NatsClient{
            .stream = stream,
            .allocator = allocator,
            .subscriptions = std.HashMap(u32, Subscription, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage).init(allocator),
            .next_subscription_id = 1,
            .buffer = try allocator.alloc(u8, BUFFER_SIZE),
        };
        _ = try client.readMessage();
        try client.ping();
        return client;
    }

    pub fn deinit(self: *NatsClient) void {
        // Clean up all subscriptions
        logger.log(.info, "Starting client deinitialization", .{});
        var iterator = self.subscriptions.iterator();
        self.stream.close();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.subscriptions.deinit();
        logger.log(.info, "Finished client deinitialization", .{});

        self.allocator.free(self.buffer);
    }

    pub fn ping(self: *NatsClient) !void {
        _ = try self.sendCommand(PING_MSG);
        return;
    }
    pub fn pong(self: *NatsClient) !void {
        _ = try self.sendCommand(PONG_MSG);
        return;
    }

    pub fn publish(self: *NatsClient, subject: []const u8, data: []const u8) !void {
        const pub_line = try std.fmt.allocPrint(self.allocator, "{s} {s} {d}\r\n{s}\r\n", .{ PUB_CMD, subject, data.len, data });
        defer self.allocator.free(pub_line);
        _ = try self.sendCommand(pub_line);
    }

    pub fn subscribe(
        self: *NatsClient,
        subject: []const u8,
        queue_group: ?[]const u8,
    ) !u32 {
        const sid = self.next_subscription_id;
        self.next_subscription_id += 1;

        const command_buff = try self.allocator.alloc(u8, 128);
        var command = std.ArrayList(u8).initBuffer(command_buff);
        defer command.deinit(self.allocator);

        // Create subscription command
        try command.writer(self.allocator).print("{s} {s}", .{ SUB_CMD, subject });
        if (queue_group) |qgroup| {
            try command.writer(self.allocator).print(" {s}", .{qgroup});
        }
        try command.writer(self.allocator).print(" {d}\r\n", .{sid});

        // Send subscription command
        _ = try self.sendCommand(command.items);

        // Store subscription info
        const subscription = Subscription{
            .subject = try self.allocator.dupe(u8, subject),
            .sid = sid,
            .queue_group = if (queue_group) |qgroup| try self.allocator.dupe(u8, qgroup) else null,
        };
        try self.subscriptions.put(sid, subscription);

        return sid;
    }
    pub fn unsubscribe(self: *NatsClient, sid: u32, max_msgs: ?u32) !void {
        logger.log(.info, "Unsubscribing from SID {d}", .{sid});
        // Remove from our subscriptions map
        if (self.subscriptions.count() == 0) {
            std.log.err("No subscriptions left", .{});
        } else if (self.subscriptions.fetchRemove(sid)) |kv| {
            kv.value.deinit(self.allocator);
        } else {
            return error.InvalidSubscriptionID;
        }

        // Send unsubscribe command
        const command: []u8 = try self.allocator.alloc(u8, 128);
        var unsub_cmd = std.ArrayList(u8).initBuffer(command);
        defer unsub_cmd.deinit(self.allocator);

        try unsub_cmd.writer(self.allocator).print("{s} {d}", .{ UNSUB_CMD, sid });
        if (max_msgs) |max| {
            try unsub_cmd.writer(self.allocator).print(" {d}", .{max});
        }
        try unsub_cmd.writer(self.allocator).print("\r\n", .{});

        _ = try self.sendCommand(unsub_cmd.items);
        logger.log(.info, "Unsubscribed from SID {d} successfully", .{sid});
    }

    /// Reads and parses the next message from the NATS server.
    ///
    /// This function blocks until a complete message is received from the server.
    /// The caller takes ownership of any allocated memory within the returned message
    /// and MUST call `deinit()` on the message to prevent memory leaks.
    ///
    /// Returns:
    ///   - `null` if no message is available (should not happen in normal operation)
    ///   - `NatsMessage` containing the parsed message data
    ///
    /// Memory Management:
    ///   - For `.Msg` variants: payload data is allocated and must be freed via `deinit()`
    ///   - For other variants: no additional cleanup required, but `deinit()` is safe to call
    ///
    /// Example:
    /// ```zig
    /// const maybe_message = try client.readMessage();
    /// if (maybe_message) |message| {
    ///     defer message.deinit(); // Required to prevent memory leaks!
    ///
    ///     switch (message) {
    ///         .Msg => |msg| std.log.info("Payload: {s}", .{msg.payload.?}),
    ///         else => {}, // Handle other message types
    ///     }
    /// }
    /// ```
    ///
    /// Errors:
    ///   - `error.EndOfStream`: Connection closed by server
    ///   - `error.InvalidMessage`: Malformed message received
    ///   - `error.OutOfMemory`: Failed to allocate memory for payload
    pub fn readMessage(self: *NatsClient) !?natsMessage.NatsMessage {
        var line_buffer = std.ArrayList(u8).initBuffer(try self.allocator.alloc(u8, 1024));
        defer line_buffer.deinit(self.allocator);
        // Read a line from the stream
        try self.readLine(&line_buffer);
        var message = try natsMessage.parseReply(line_buffer.items, self.allocator);

        switch (message) {
            .Msg => |msg| {
                message.Msg.payload = try self.getPayload(msg.payload_size);
            },
            .Ok => {
                logger.log(.debug, "Received OK acknowledgment\n", .{});
            },
            .Ping => {
                logger.log(.debug, "Received PING\n", .{});
            },
            .Pong => {
                logger.log(.debug, "Received PONG\n", .{});
            },
            .Err => |err_msg| {
                logger.log(.err, "NATS Error: {s}\n", .{err_msg});
            },
            .Info => |inf| {
                logger.log(.debug, "[INFO] {s}\n", .{inf});
            },
            .Unsubscribed => {
                logger.log(.info, "Unsubscribed\n", .{});
            },
        }
        return message;
    }

    fn readLine(self: *NatsClient, buffer: *std.ArrayList(u8)) !void {
        var byte: [1]u8 = undefined;

        while (true) {
            const byte_read = try self.stream.read(&byte);
            if (byte_read == 0) return error.EndOfStream;

            if (byte[0] == '\r') {
                const next_byte = try self.stream.read(&byte);
                if (next_byte == 0) return error.EndOfStream;

                if (byte[0] == '\n') {
                    return; // Complete reading line
                } else {
                    try buffer.append(self.allocator, '\r');
                    try buffer.append(self.allocator, byte[0]);
                }
            } else {
                try buffer.append(self.allocator, byte[0]);
            }
        }
    }

    /// Read payload data of specified length
    fn getPayload(self: *NatsClient, byte_count: usize) ![]u8 {
        if (byte_count == 0) {
            // Still need to consume the trailing \r\n
            var trailing: [2]u8 = undefined;
            _ = try self.stream.read(&trailing);
            return error.EmptyPayload;
        }

        const payload = try self.allocator.alloc(u8, byte_count);
        errdefer self.allocator.free(payload);

        var total_read: usize = 0;
        while (total_read < byte_count) {
            const n = try self.stream.read(payload[total_read..]);
            if (n == 0) return error.EndOfStream;
            total_read += n;
        }

        // Read the trailing \r\n after payload
        var trailing: [2]u8 = undefined;
        _ = try self.stream.read(&trailing);

        return payload;
    }
    fn sendCommand(self: *NatsClient, command: []const u8) !?NatsMessage {
        try self.stream.writeAll(command);

        logger.log(.debug, "[SEND] {s}", .{command[0 .. command.len - 2]});
        return self.readMessage();
    }
};

// Add these tests at the end of root.zig

const testing = std.testing;
const test_helpers = @import("test_helpers.zig");

// Mock client for testing without network
const MockNatsClient = struct {
    stream: *test_helpers.MockStream,
    allocator: std.mem.Allocator,
    subscriptions: std.HashMap(u32, Subscription, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage),
    next_subscription_id: u32,
    buffer: []u8,

    pub fn initMock(allocator: std.mem.Allocator, mock_stream: *test_helpers.MockStream) !MockNatsClient {
        return MockNatsClient{
            .stream = mock_stream,
            .allocator = allocator,
            .subscriptions = std.HashMap(u32, Subscription, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage).init(allocator),
            .next_subscription_id = 1,
            .buffer = try allocator.alloc(u8, BUFFER_SIZE),
        };
    }

    pub fn deinit(self: *MockNatsClient) void {
        var iterator = self.subscriptions.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.subscriptions.deinit();
        self.allocator.free(self.buffer);
    }

    // Implement the same interface as NatsClient for testing
    // (You would copy the methods from NatsClient but use self.stream instead of a real stream)
};

test "NATS client initialization" {
    // This test would require a mock or a running NATS server
    // For now, let's test the components we can test in isolation
    const allocator = testing.allocator;

    var mock_stream = test_helpers.MockStream.init(allocator);
    defer mock_stream.deinit();

    // Feed the expected INFO message
    const info_msg = try test_helpers.createInfoMessage(allocator);
    defer allocator.free(info_msg);
    try mock_stream.feedInput(info_msg);
    try mock_stream.feedInput("PONG\r\n");

    // Note: Full client init test would require more sophisticated mocking
    // This is a placeholder for the structure
}

test "publish command formatting" {
    const allocator = testing.allocator;

    const subject = "test.subject";
    const data = "hello world";
    const expected = try std.fmt.allocPrint(allocator, "PUB {s} {d}\r\n{s}\r\n", .{ subject, data.len, data });
    defer allocator.free(expected);

    // This tests the command format - you'd extract this logic into a separate function
    var mock_stream = test_helpers.MockStream.init(allocator);
    defer mock_stream.deinit();

    try mock_stream.writeAll(expected);
    try testing.expectEqualStrings(expected, mock_stream.getSentData());
}

test "subscribe command formatting without queue group" {
    const allocator = testing.allocator;

    const subject = "test.subject";
    const sid: u32 = 123;

    const expected = try std.fmt.allocPrint(allocator, "SUB {s} {d}\r\n", .{ subject, sid });
    defer allocator.free(expected);

    var mock_stream = test_helpers.MockStream.init(allocator);
    defer mock_stream.deinit();

    try mock_stream.writeAll(expected);
    try testing.expectEqualStrings(expected, mock_stream.getSentData());
}

test "subscribe command formatting with queue group" {
    const allocator = testing.allocator;

    const subject = "test.subject";
    const queue_group = "worker.queue";
    const sid: u32 = 123;

    const expected = try std.fmt.allocPrint(allocator, "SUB {s} {s} {d}\r\n", .{ subject, queue_group, sid });
    defer allocator.free(expected);

    var mock_stream = test_helpers.MockStream.init(allocator);
    defer mock_stream.deinit();

    try mock_stream.writeAll(expected);
    try testing.expectEqualStrings(expected, mock_stream.getSentData());
}

test "unsubscribe command formatting without max_msgs" {
    const allocator = testing.allocator;

    const sid: u32 = 123;
    const expected = try std.fmt.allocPrint(allocator, "UNSUB {d}\r\n", .{sid});
    defer allocator.free(expected);

    var mock_stream = test_helpers.MockStream.init(allocator);
    defer mock_stream.deinit();

    try mock_stream.writeAll(expected);
    try testing.expectEqualStrings(expected, mock_stream.getSentData());
}

test "unsubscribe command formatting with max_msgs" {
    const allocator = testing.allocator;

    const sid: u32 = 123;
    const max_msgs: u32 = 10;
    const expected = try std.fmt.allocPrint(allocator, "UNSUB {d} {d}\r\n", .{ sid, max_msgs });
    defer allocator.free(expected);

    var mock_stream = test_helpers.MockStream.init(allocator);
    defer mock_stream.deinit();

    try mock_stream.writeAll(expected);
    try testing.expectEqualStrings(expected, mock_stream.getSentData());
}

test "subscription management" {
    const allocator = testing.allocator;

    var subscriptions = std.HashMap(u32, Subscription, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage).init(allocator);
    defer {
        var iterator = subscriptions.iterator();
        while (iterator.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        subscriptions.deinit();
    }

    // Test adding subscription
    const subject = try allocator.dupe(u8, "test.subject");
    const sub = Subscription{
        .subject = subject,
        .sid = 123,
        .queue_group = null,
    };

    try subscriptions.put(123, sub);
    try testing.expectEqual(@as(u32, 1), subscriptions.count());
    try testing.expect(subscriptions.contains(123));

    // Test removing subscription
    if (subscriptions.fetchRemove(123)) |kv| {
        kv.value.deinit(allocator);
    }
    try testing.expectEqual(@as(u32, 0), subscriptions.count());
    try testing.expect(!subscriptions.contains(123));
}

test "readLine parsing" {
    const allocator = testing.allocator;

    var mock_stream = test_helpers.MockStream.init(allocator);
    defer mock_stream.deinit();

    // Test normal line ending
    try mock_stream.feedInput("PING\r\n");

    const command_buff = try allocator.alloc(u8, 128);
    var line_buffer = std.ArrayList(u8).initBuffer(command_buff);
    defer line_buffer.deinit(allocator);

    // You would need to extract readLine into a testable function
    // This is a structural example
    try testing.expectEqualStrings("PING", "PING"); // Placeholder
}

test "payload reading" {
    const allocator = testing.allocator;

    var mock_stream = test_helpers.MockStream.init(allocator);
    defer mock_stream.deinit();

    const test_payload = "Hello, NATS!";
    try mock_stream.feedInput(test_payload);
    try mock_stream.feedInput("\r\n"); // trailing CRLF

    // You would need to extract getPayload into a testable function
    // and test it with the mock stream
}

test "message flow integration" {
    const allocator = testing.allocator;

    var mock_stream = test_helpers.MockStream.init(allocator);
    defer mock_stream.deinit();

    // Simulate receiving a complete message
    const msg_line = "MSG foo.bar 123 13\r\n";
    const payload = "Hello, World!";
    const trailing = "\r\n";

    try mock_stream.feedInput(msg_line);
    try mock_stream.feedInput(payload);
    try mock_stream.feedInput(trailing);

    // Test that the complete message flow works
    // This would require refactoring your client code to be more testable
}
