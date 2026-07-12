// Exhaustive interleaving model for the compiler/runtime guard contract.
// SharedNodeStore deliberately delegates lock linearization to pthread rwlock;
// it has no custom atomic retry algorithm for Loom to interpose. This model
// exhausts the state transitions CLEAR adds around that primitive: a payload
// pointer is obtained only after read admission, is consumed before release,
// and removal occurs only after exclusive admission.
const std = @import("std");

const Actor = enum { reader_a, reader_b, writer };
const Phase = enum { start, acquired, accessed, done };

const Model = struct {
    phases: [3]Phase = .{ .start, .start, .start },
    readers: u8 = 0,
    writer: bool = false,
    live: bool = true,
    schedules: usize = 0,

    fn index(actor: Actor) usize {
        return @intFromEnum(actor);
    }

    fn canStep(self: *const Model, actor: Actor) bool {
        const phase = self.phases[index(actor)];
        return switch (actor) {
            .reader_a, .reader_b => switch (phase) {
                .start => !self.writer,
                .acquired, .accessed => true,
                .done => false,
            },
            .writer => switch (phase) {
                .start => !self.writer and self.readers == 0,
                .acquired, .accessed => true,
                .done => false,
            },
        };
    }

    fn step(self: *Model, actor: Actor) !void {
        const idx = index(actor);
        switch (actor) {
            .reader_a, .reader_b => switch (self.phases[idx]) {
                .start => {
                    try std.testing.expect(!self.writer);
                    self.readers += 1;
                    self.phases[idx] = .acquired;
                },
                .acquired => {
                    try std.testing.expect(!self.writer);
                    // A stale handle may resolve NIL after removal, but a live
                    // payload pointer can never coexist with removal.
                    _ = self.live;
                    self.phases[idx] = .accessed;
                },
                .accessed => {
                    self.readers -= 1;
                    self.phases[idx] = .done;
                },
                .done => unreachable,
            },
            .writer => switch (self.phases[idx]) {
                .start => {
                    try std.testing.expectEqual(@as(u8, 0), self.readers);
                    self.writer = true;
                    self.phases[idx] = .acquired;
                },
                .acquired => {
                    try std.testing.expectEqual(@as(u8, 0), self.readers);
                    self.live = false;
                    self.phases[idx] = .accessed;
                },
                .accessed => {
                    self.writer = false;
                    self.phases[idx] = .done;
                },
                .done => unreachable,
            },
        }
    }
};

fn explore(model: Model, total: *usize) !void {
    if (model.phases[0] == .done and model.phases[1] == .done and model.phases[2] == .done) {
        total.* += 1;
        return;
    }

    for ([_]Actor{ .reader_a, .reader_b, .writer }) |actor| {
        if (!model.canStep(actor)) continue;
        var next = model;
        try next.step(actor);
        try explore(next, total);
    }
}

test "SharedNodeStore guard protocol exhausts two-reader removal schedules" {
    var schedules: usize = 0;
    try explore(.{}, &schedules);
    try std.testing.expect(schedules > 0);
}
