const std = @import("std");

pub const Subscription = struct {
    subject: []const u8,
    sid: u32,
    queue_group: ?[]const u8,

    pub fn deinit(self: *const Subscription, allocator: std.mem.Allocator) void {
        allocator.free(self.subject);
        if (self.queue_group) |qg| allocator.free(qg);
    }
};

// Add these tests at the end of subscription.zig

const testing = std.testing;

test "Subscription.deinit - with queue group" {
    const subject = try testing.allocator.dupe(u8, "test.subject");
    const queue_group = try testing.allocator.dupe(u8, "test.queue");

    const sub = Subscription{
        .subject = subject,
        .sid = 123,
        .queue_group = queue_group,
    };

    sub.deinit(testing.allocator);
    // Memory should be freed without leaking
}

test "Subscription.deinit - without queue group" {
    const subject = try testing.allocator.dupe(u8, "test.subject");

    const sub = Subscription{
        .subject = subject,
        .sid = 123,
        .queue_group = null,
    };

    sub.deinit(testing.allocator);
    // Memory should be freed without leaking
}

test "Subscription creation and cleanup" {
    const original_subject = "test.subject.original";
    const original_queue = "test.queue.original";

    const subject = try testing.allocator.dupe(u8, original_subject);
    const queue_group = try testing.allocator.dupe(u8, original_queue);

    const sub = Subscription{
        .subject = subject,
        .sid = 42,
        .queue_group = queue_group,
    };

    // Verify the subscription was created correctly
    try testing.expectEqualStrings(original_subject, sub.subject);
    try testing.expectEqual(@as(u32, 42), sub.sid);
    try testing.expectEqualStrings(original_queue, sub.queue_group.?);

    sub.deinit(testing.allocator);
}
