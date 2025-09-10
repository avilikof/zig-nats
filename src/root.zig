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

        // var sub_cmd_buf: [256]u8 = undefined;
        // var command = std.ArrayList(u8).init(self.allocator);
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
