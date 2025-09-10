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
