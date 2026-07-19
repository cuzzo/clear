pub const MutationKind = enum {
    bool_literal_flip,
    comparison_flip,
    logical_flip,
    if_condition_negation,
    while_condition_negation,
    assertion_weakening,
    defer_removal,
    errdefer_removal,
    try_unwrap_unreachable,
    catch_fallback_unreachable,
    cleanup_call_removal,
    lock_call_removal,
    atomic_ordering_weakening,
    error_return_unreachable,
    bounds_guard_weakening,

    pub fn label(kind: MutationKind) []const u8 {
        return @tagName(kind);
    }
};
