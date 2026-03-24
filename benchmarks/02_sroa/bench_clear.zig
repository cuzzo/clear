const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;

// -------------------------------------------------------------------------
// 2. User Types & Functions (Transpiled)
// -------------------------------------------------------------------------
const BigVec = struct {
    x1: f64,
    x2: f64,
    x3: f64,
    x4: f64,
    x5: f64,
    x6: f64,
    x7: f64,
    x8: f64,
    x9: f64,
    x10: f64,
    x11: f64,
    x12: f64,
    x13: f64,
    x14: f64,
    x15: f64,
    x16: f64,
    x17: f64,
    x18: f64,
    x19: f64,
    x20: f64,
    x21: f64,
    x22: f64,
    x23: f64,
    x24: f64,
    x25: f64,
    x26: f64,
    x27: f64,
    x28: f64,
    x29: f64,
    x30: f64,
    x31: f64,
    x32: f64,
    x33: f64,
    x34: f64,
    x35: f64,
    x36: f64,
    x37: f64,
    x38: f64,
    x39: f64,
    x40: f64,
    x41: f64,
    x42: f64,
    x43: f64,
    x44: f64,
    x45: f64,
    x46: f64,
    x47: f64,
    x48: f64,
    x49: f64,
    x50: f64,
    x51: f64,
    x52: f64,
    x53: f64,
    x54: f64,
    x55: f64,
    x56: f64,
    x57: f64,
    x58: f64,
    x59: f64,
    x60: f64,
    x61: f64,
    x62: f64,
    x63: f64,
    x64: f64,
    x65: f64,
    x66: f64,
    x67: f64,
    x68: f64,
    x69: f64,
    x70: f64,
    x71: f64,
    x72: f64,
    x73: f64,
    x74: f64,
    x75: f64,
    x76: f64,
    x77: f64,
    x78: f64,
    x79: f64,
    x80: f64,
    x81: f64,
    x82: f64,
    x83: f64,
    x84: f64,
    x85: f64,
    x86: f64,
    x87: f64,
    x88: f64,
    x89: f64,
    x90: f64,
    x91: f64,
    x92: f64,
    x93: f64,
    x94: f64,
    x95: f64,
    x96: f64,
    x97: f64,
    x98: f64,
    x99: f64,
    x100: f64,
    x101: f64,
    x102: f64,
    x103: f64,
    x104: f64,
    x105: f64,
    x106: f64,
    x107: f64,
    x108: f64,
    x109: f64,
    x110: f64,
    x111: f64,
    x112: f64,
    x113: f64,
    x114: f64,
    x115: f64,
    x116: f64,
    x117: f64,
    x118: f64,
    x119: f64,
    x120: f64,
    x121: f64,
    x122: f64,
    x123: f64,
    x124: f64,
    x125: f64,
    x126: f64,
    x127: f64,
    x128: f64,
    x129: f64,
    x130: f64,
};

fn sum3(v: BigVec) f64 {
    
    return ((v.x1 + v.x2) + v.x3);
}


fn cheatMain(rt: *Runtime) !void {
    _ = &rt;
    var i: i64 = 0; 


var acc: f64 = 1; 


while ((i < 10000000)) {
 const bv = BigVec{ .x1 = acc, .x2 = (acc + 1), .x3 = (acc + 2), .x4 = 0, .x5 = 0, .x6 = 0, .x7 = 0, .x8 = 0, .x9 = 0, .x10 = 0, .x11 = 0, .x12 = 0, .x13 = 0, .x14 = 0, .x15 = 0, .x16 = 0, .x17 = 0, .x18 = 0, .x19 = 0, .x20 = 0, .x21 = 0, .x22 = 0, .x23 = 0, .x24 = 0, .x25 = 0, .x26 = 0, .x27 = 0, .x28 = 0, .x29 = 0, .x30 = 0, .x31 = 0, .x32 = 0, .x33 = 0, .x34 = 0, .x35 = 0, .x36 = 0, .x37 = 0, .x38 = 0, .x39 = 0, .x40 = 0, .x41 = 0, .x42 = 0, .x43 = 0, .x44 = 0, .x45 = 0, .x46 = 0, .x47 = 0, .x48 = 0, .x49 = 0, .x50 = 0, .x51 = 0, .x52 = 0, .x53 = 0, .x54 = 0, .x55 = 0, .x56 = 0, .x57 = 0, .x58 = 0, .x59 = 0, .x60 = 0, .x61 = 0, .x62 = 0, .x63 = 0, .x64 = 0, .x65 = 0, .x66 = 0, .x67 = 0, .x68 = 0, .x69 = 0, .x70 = 0, .x71 = 0, .x72 = 0, .x73 = 0, .x74 = 0, .x75 = 0, .x76 = 0, .x77 = 0, .x78 = 0, .x79 = 0, .x80 = 0, .x81 = 0, .x82 = 0, .x83 = 0, .x84 = 0, .x85 = 0, .x86 = 0, .x87 = 0, .x88 = 0, .x89 = 0, .x90 = 0, .x91 = 0, .x92 = 0, .x93 = 0, .x94 = 0, .x95 = 0, .x96 = 0, .x97 = 0, .x98 = 0, .x99 = 0, .x100 = 0, .x101 = 0, .x102 = 0, .x103 = 0, .x104 = 0, .x105 = 0, .x106 = 0, .x107 = 0, .x108 = 0, .x109 = 0, .x110 = 0, .x111 = 0, .x112 = 0, .x113 = 0, .x114 = 0, .x115 = 0, .x116 = 0, .x117 = 0, .x118 = 0, .x119 = 0, .x120 = 0, .x121 = 0, .x122 = 0, .x123 = 0, .x124 = 0, .x125 = 0, .x126 = 0, .x127 = 0, .x128 = 0, .x129 = 0, .x130 = 0 }; 


acc = sum3(bv); 
i = (i + 1);  
}
CheatLib.assert((acc > 0), "acc must be positive");
return ;
}


// -------------------------------------------------------------------------
// 3. Main Entry (Test Harness)
// -------------------------------------------------------------------------
// TODO: Make this depend on libc, use jemalloc
pub fn main() !void {
    // 1. Setup Allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 2. Setup Contexts (Required by your current runtime.zig)
    // We import EbrContext from ebr.zig (referenced in your runtime)
    var global_ctx = EbrContext{};
    defer global_ctx.deinit(allocator);

    // 3. Init Runtime (4 MB frame arena — carved off the heap for the main fiber).
    // Per-fiber runtimes use a 4 KB slice of their own stack (see entryWrapper).
    // 4 MB here is generous; the hot path (e.g. tcpRead loop) only ever holds
    // one buffer at a time thanks to per-iteration restoreLoopMark.
    var rt = try Runtime.init(
        allocator,
        4 * 1024 * 1024,
        &global_ctx,
    );
    defer rt.deinit();
    rt.wireAllocator();

    // 4. Setup Fiber Scheduler (required for BG {} / DO {} / NEXT)
    const fm = @import("fiber-memory.zig");
    const fp = @import("scheduler.zig");
    var stack_pool = fm.StackPool.init(allocator);
    defer stack_pool.deinit();
    var sched = try fp.Scheduler.init(allocator, &global_ctx, &stack_pool);
    defer {
        sched.deinit();
        fp.global_registry.deinit(allocator);
    }
    fp.active_scheduler = &sched;

    // 5. Run cheatMain inside a fiber so BG {} / NEXT can yield.
    //    We pass &rt (the 128 MB-frame runtime) via args so cheatMain has its
    //    full arena — the fiber-local runtime from entryWrapper is not used.
    const MainRunner = struct {
        outer_rt: *Runtime,
        fn run(_: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw_args.?));
            const result = try cheatMain(self.outer_rt);
            const RType = @TypeOf(result);
            if (@typeInfo(RType) == .pointer) {
                CheatLib.free(self.outer_rt, result);
            }
        }
    };
    var main_runner = MainRunner{ .outer_rt = &rt };
    try sched.submitSpawn(
        @intFromPtr(&Runtime.entryWrapper),
        @as(CheatHeader.TaskFn, @ptrCast(&MainRunner.run)),
        &main_runner,
        .{ .stack_size = .Large },
    );
    sched.run();
}

