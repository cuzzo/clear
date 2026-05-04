const std = @import("std");
const builtin = @import("builtin");
const sched_mod = @import("scheduler.zig");

// Verifies that `Scheduler.ensureSignalAltStack` actually causes a
// signal handler installed with SA_ONSTACK to run on the dedicated
// `sig_alt_stack` buffer rather than on the current thread's stack.
//
// Mechanism:
//   1. Install a SIGUSR1 handler with SA_ONSTACK.
//   2. Call ensureSignalAltStack() to register the alternate stack.
//   3. Raise SIGUSR1 from this thread.
//   4. The handler records the address of one of its own stack locals.
//   5. Assert that address falls within sig_alt_stack's range.
//
// Without sigaltstack (or without SA_ONSTACK), the recorded address
// would be on the test thread's pthread stack -- nowhere near the
// alt-stack range. This is the actual production-safety guarantee:
// any signal whose handler runs (real SIGSEGV, SIGBUS, debugger
// SIGTRAP, etc.) won't push a signal frame onto a small fiber stack.

var observed_handler_local_addr: usize = 0;

fn handlerSigUsr1(_: std.os.linux.SIG) callconv(.c) void {
    var marker: u8 = 0;
    observed_handler_local_addr = @intFromPtr(&marker);
    // touch marker so the optimizer can't elide it
    marker = 1;
    if (marker != 1) unreachable;
}

test "sigaltstack: SIGUSR1 handler runs on alternate signal stack" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    // Save and restore the original SIGUSR1 disposition so we don't
    // leak handler state into other tests in the same binary.
    var old: std.posix.Sigaction = undefined;
    var act = std.posix.Sigaction{
        .handler = .{ .handler = &handlerSigUsr1 },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.ONSTACK,
    };
    std.posix.sigaction(std.posix.SIG.USR1, &act, &old);
    defer std.posix.sigaction(std.posix.SIG.USR1, &old, null);

    // Install the alt stack. This is what production code (Scheduler.run)
    // calls; calling it here in the test thread proves the same path works.
    sched_mod.ensureSignalAltStack();

    // Sanity: kernel reports a non-zero alt stack now.
    var current_ss: std.posix.stack_t = undefined;
    try std.posix.sigaltstack(null, &current_ss);
    try std.testing.expect(current_ss.size > 0);
    try std.testing.expect((current_ss.flags & std.os.linux.SS.DISABLE) == 0);

    // Trigger the handler.
    observed_handler_local_addr = 0;
    try std.posix.raise(std.posix.SIG.USR1);

    // Handler must have run (would have set a non-zero address).
    try std.testing.expect(observed_handler_local_addr != 0);

    // The recorded local must lie within sig_alt_stack's bounds. This is
    // the load-bearing assertion: it proves the kernel actually used the
    // alternate stack, not just that we registered it.
    const range = sched_mod.sigAltStackRange();
    try std.testing.expect(observed_handler_local_addr >= range[0]);
    try std.testing.expect(observed_handler_local_addr < range[1]);
}

test "sigaltstack: handler WITHOUT SA_ONSTACK runs on caller stack (control)" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var old: std.posix.Sigaction = undefined;
    var act = std.posix.Sigaction{
        .handler = .{ .handler = &handlerSigUsr1 },
        .mask = std.posix.sigemptyset(),
        .flags = 0, // <-- no SA_ONSTACK
    };
    std.posix.sigaction(std.posix.SIG.USR1, &act, &old);
    defer std.posix.sigaction(std.posix.SIG.USR1, &old, null);

    sched_mod.ensureSignalAltStack();

    observed_handler_local_addr = 0;
    var test_local: u8 = 0;
    test_local = 1;
    if (test_local != 1) unreachable;
    try std.posix.raise(std.posix.SIG.USR1);

    try std.testing.expect(observed_handler_local_addr != 0);

    // Without SA_ONSTACK, handler ran on the caller stack -- it must NOT
    // be in the alt-stack range. (Sanity test: confirms the previous
    // test's success isn't a false positive from address aliasing.)
    const range = sched_mod.sigAltStackRange();
    try std.testing.expect(observed_handler_local_addr < range[0] or observed_handler_local_addr >= range[1]);
}
