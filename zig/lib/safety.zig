const std = @import("std");
const builtin = @import("builtin");

// These calls must be inserted by LLVM AFTER optimization.
// They add ~30% overhead on extremely trivial functions
// However, the compiler optimizes away nearly all of these functions.
// If added BEFORE optimization, it destroys that optimization
// Causing the code to *actually* run, and essentially having infinite overhead.
//
// For *realisitic* workloads that can't be optimized away -> overhead is ~5%.
// We already add 2-3% overhead for stackoverflow prevenetion.
// Another ~5% in ~3% of code (recursive) to gain determinism
// and save substantial memory is *typically* worth it.
// Users can opt-out of this for hot-paths.

// Fiber schduler MUST move this on & off fibers BEFORE switching.
pub threadlocal var __min_depth: usize = std.math.maxInt(usize);

pub inline fn depthGuard() void {
    const sp = switch (builtin.cpu.arch) {
        .x86_64 => asm ("mov %%rsp, %[ret]" : [ret] "=r" (-> usize)),
        .aarch64, .arm => asm ("mov %[ret], sp" : [ret] "=r" (-> usize)),
        .riscv64 => asm ("mv %[ret], sp" : [ret] "=r" (-> usize)),
        else => @compileError("Unsupported"),
    };

    // Track the LOWEST address (deepest point in downward-growing stack)
    if (sp < __min_depth) {
        __min_depth = sp;
    }
}

/// This function creates a unique static boolean for every unique 'id' passed in.
/// We use 'anytype' or a string 'id' to differentiate call sites.
/// This protects general REENTRANCY GLOBALLY - not fiber recursion
pub fn GlobalReentrancyGuard(comptime id: anytype) type {
    _ = id;
    return struct {
        pub var locked: bool = false;
    };
}



/// The head of the guard list for the CURRENTLY ACTIVE stack.
/// Fiber scheduler MUST move this on and off fibers BEFORE switching.
pub threadlocal var stack_guard_head: ?*GuardNode = null;

pub const GuardNode = struct {
    id: usize,
    next: ?*GuardNode,
};

pub const StackGuard = struct {
    node: GuardNode,

    pub fn enter(comptime src: std.builtin.SourceLocation) !StackGuard {
        // Use the address of the source location as a unique identifier
        const uid = @intFromPtr(&src);

        var current = stack_guard_head;
        while (current) |node| {
            if (node.id == uid) return error.UnexpectedRecursion;
            current = node.next;
        }

        return StackGuard{
            .node = .{
                .id = uid,
                .next = stack_guard_head,
            },
        };
    }

    pub fn push(self: *StackGuard) void {
        stack_guard_head = &self.node;
    }

    pub fn pop(self: *StackGuard) void {
        _ = self;
        if (stack_guard_head) |head| {
            stack_guard_head = head.next;
        }
    }
};

/// Per-fn depth counter for `EFFECTS REENTRANT:MAX_DEPTH(N)`. Each
/// unique `src` (one per :MAX_DEPTH function definition site) gets
/// its own threadlocal counter via comptime parameterization. The
/// fiber scheduler MUST move depth state on/off fibers BEFORE
/// switching (same rule as stack_guard_head).
///
/// On entry: returns `error.MaxDepthExceeded` if the new depth would
/// exceed `max`; otherwise increments and returns. The caller is
/// responsible for calling `exitDepth(src)` on exit (typically via
/// `defer`).
pub fn DepthCounter(comptime src: std.builtin.SourceLocation) type {
    _ = src;
    return struct {
        pub threadlocal var depth: usize = 0;
    };
}

pub fn enterDepth(comptime src: std.builtin.SourceLocation, comptime max: usize) !void {
    const C = DepthCounter(src);
    if (C.depth >= max) return error.MaxDepthExceeded;
    C.depth += 1;
}

pub fn exitDepth(comptime src: std.builtin.SourceLocation) void {
    const C = DepthCounter(src);
    // The codegen always pairs `enterDepth(src, max)` at fn entry with
    // `defer exitDepth(src)`, so depth > 0 is a structural invariant
    // here. A debug-only assert catches future miswiring loudly while
    // compiling out in ReleaseFast (small win vs. the previous
    // `if (depth > 0)` runtime branch).
    std.debug.assert(C.depth > 0);
    C.depth -= 1;
}

