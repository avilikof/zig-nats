const std = @import("std");

// Mock stream for testing network operations without actual network
pub const MockStream = struct {
    read_buffer: std.ArrayList(u8),
    write_buffer: std.ArrayList(u8),
    read_pos: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MockStream {
        return MockStream{
            .read_buffer = std.ArrayList(u8).init(allocator),
            .write_buffer = std.ArrayList(u8).init(allocator),
            .read_pos = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MockStream) void {
        self.read_buffer.deinit();
        self.write_buffer.deinit();
    }

    // Add data that will be "received" from server
    pub fn feedInput(self: *MockStream, data: []const u8) !void {
        try self.read_buffer.appendSlice(data);
    }

    // Get what was "sent" to server
    pub fn getSentData(self: *MockStream) []const u8 {
        return self.write_buffer.items;
    }

    pub fn clearSentData(self: *MockStream) void {
        self.write_buffer.clearRetainingCapacity();
    }

    // Implement stream interface
    pub fn read(self: *MockStream, buffer: []u8) !usize {
        const available = self.read_buffer.items.len - self.read_pos;
        if (available == 0) return 0;

        const to_read = @min(buffer.len, available);
        @memcpy(buffer[0..to_read], self.read_buffer.items[self.read_pos .. self.read_pos + to_read]);
        self.read_pos += to_read;
        return to_read;
    }

    pub fn writeAll(self: *MockStream, data: []const u8) !void {
        try self.write_buffer.appendSlice(data);
    }

    pub fn close(self: *MockStream) void {
        _ = self; // Mock doesn't need to do anything
    }
};

// Helper to create standard NATS INFO message
pub fn createInfoMessage(allocator: std.mem.Allocator) ![]u8 {
    return try std.fmt.allocPrint(allocator,
        \\INFO {{"server_id":"test-server","server_name":"test","version":"2.9.0","proto":1,"go":"go1.19","host":"127.0.0.1","port":4222,"headers":true,"max_payload":1048576,"auth_required":false,"tls_required":false,"tls_verify":false}}
        \\
    );
}
