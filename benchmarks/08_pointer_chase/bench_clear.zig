const std = @import("std");
const CheatHeader = @import("runtime-header.zig");
const CheatLib = CheatHeader.CheatLib;
const Runtime = CheatHeader.Runtime;
const EbrContext = CheatHeader.EbrContext;

// -------------------------------------------------------------------------
// 2. User Types & Functions (Transpiled)
// -------------------------------------------------------------------------
const Node = struct {
    val: i64,
    next: ?u64,
};

fn cheatMain(rt: *Runtime) !void {
    _ = &rt;
    const n_nodes: i64 = 2000000; 


const step: i64 = 999983; 


var pool = CheatLib.Pool(Node){}; 
defer pool.deinit(rt.heapAlloc());


var id_list = std.ArrayListUnmanaged(u64){}; 
defer id_list.deinit(rt.frameAlloc());


var i: i64 = 0; 


while ((i < n_nodes)) {
 const id = try pool.insert(rt.heapAlloc(), Node{ .val = i, .next = @as(?u64, null) }); 


try id_list.append(rt.frameAlloc(), id);
i = (i + 1);  
}
var j: i64 = 0; 


while ((j < n_nodes)) {
const __loop_mark_1 = rt.saveLoopMark(); defer rt.restoreLoopMark(__loop_mark_1);
 const next_pos: i64 = @mod((j + step), n_nodes); 


const next_id = CheatLib.getAt(id_list, next_pos); 


const cur_node = pool.get(CheatLib.getAt(id_list, j)); 


cur_node.?.next = @as(?u64, next_id);
j = (j + 1);  
}
var cur = @as(?u64, CheatLib.getAt(id_list, 0)); 


var steps: i64 = 0; 


var sum: i64 = 0; 


while ((steps < n_nodes)) {
const __loop_mark_2 = rt.saveLoopMark(); defer rt.restoreLoopMark(__loop_mark_2);
 const n = pool.get(cur.?); 


sum = (sum + n.?.val); 
cur = n.?.next; 
steps = (steps + 1);  
}
CheatLib.assert((sum > 0), "sum must be positive");
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

