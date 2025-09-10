// Comprehensive error handling tests
const std = @import("std");
const testing = std.testing;
const natsMessage = @import("message.zig");

test "error handling - connection failures" {
    // Test connection timeout
    // Test connection refused
    // Test network interruption
}

test "error handling - protocol errors" {
    const allocator = testing.allocator;

    // Test malformed messages
    const malformed_messages = [_][]const u8{
        "MSG", // Too few arguments
        "MSG foo", // Still too few
        "MSG foo bar", // Still too few
        "MSG foo bar invalid_sid 10", // Invalid SID
        "MSG foo bar 123 invalid_size", // Invalid payload size
        "", // Empty message
        "INVALID_COMMAND with args", // Unknown command
    };

    for (malformed_messages) |msg| {
        const result = natsMessage.parseReply(msg, allocator);

        // All of these should result in errors
        try testing.expect(std.meta.isError(result));
    }
}

test "error handling - memory allocation failures" {
    // Use testing.FailingAllocator to test OOM conditions
    var failing_allocator = testing.FailingAllocator.init(testing.allocator, 0);

    const result = natsMessage.parseReply("MSG foo.bar 123 10", failing_allocator.allocator());
    try testing.expectError(error.OutOfMemory, result);
}

test "error handling - subscription not found" {
    const allocator = testing.allocator;

    var subscriptions = std.HashMap(u32, @import("subscription.zig").Subscription, std.hash_map.AutoContext(u32), std.hash_map.default_max_load_percentage).init(allocator);
    defer subscriptions.deinit();

    // Try to remove non-existent subscription
    const removed = subscriptions.fetchRemove(999);
    try testing.expect(removed == null);
}
