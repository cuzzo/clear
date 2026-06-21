const std = @import("std");

pub const ZigSyntaxFactsCore = struct {
    status: Status,
    count: usize,

    pub fn init(status: Status) ZigSyntaxFactsCore {
        return ZigSyntaxFactsCore{ .status = status, .count = 0 };
    }

    pub fn process(self: *ZigSyntaxFactsCore, user: anytype, items: []const Item, callback: anytype) ?[]const u8 {
        const name = user.profile.name;
        var result: ?[]const u8 = null;

        callback(user);

        switch (user.role) {
            .owner, .admin => self.escalate(user),
            .guest => self.fallback(user),
            else => self.defaultCase(user),
        }

        if (self.status == .idle and user.ready) {
            self.count += 1;
            self.publish(.busy);
        } else {
            std.debug.print("not ready", .{});
        }

        for (items) |item| {
            _ = item.children();
        }

        result = name;
        return result;
    }

    fn audit(self: *ZigSyntaxFactsCore, name: []const u8) void {
        std.debug.print("{s}", .{name});
        _ = self.status;
    }

    fn ready(self: *ZigSyntaxFactsCore) bool {
        return self.count > 0;
    }
};

const Status = enum {
    idle,
    busy,
};

const Item = struct {
    value: []const u8,
};

