(
  (builtin_function (builtin_identifier) @builtin) @hazard.zig_loom_atomic
  (#match? @builtin "^@(atomicLoad|atomicStore|atomicRmw|cmpxchgStrong|cmpxchgWeak|fence)$")
)

(
  (call_expression function: (field_expression member: (identifier) @method)) @hazard.zig_loom_atomic
  (#match? @method "^(load|store|swap|fetchAdd|fetchSub|fetchOr|fetchAnd|fetchXor|fetchMin|fetchMax)$")
)

(
  (builtin_function (builtin_identifier) @builtin) @hazard.zig_unsafe_memory
  (#match? @builtin "^@(ptrCast|alignCast|bitCast)$")
)

(
  (call_expression function: (field_expression member: (identifier) @method)) @hazard.zig_allocator
  (#match? @method "^(alloc|free|create|destroy|realloc|shrink)$")
)

(
  (call_expression function: (field_expression member: (identifier) @method)) @hazard.zig_vopr_time
  (#match? @method "^(milliTimestamp|nanoTimestamp|microTimestamp)$")
)

(
  (call_expression function: (identifier) @func) @hazard.zig_vopr_time
  (#match? @func "^(milliTimestamp|nanoTimestamp|microTimestamp)$")
)

(
  (call_expression function: (field_expression member: (identifier) @method)) @hazard.zig_vopr_time
  (#eq? @method "now")
)

(
  (identifier) @hazard.zig_vopr_time
  (#eq? @hazard.zig_vopr_time "Timer")
)

(
  (call_expression function: (identifier) @func) @hazard.zig_vopr_time
  (#eq? @func "clock_gettime")
)

(
  (field_expression member: (identifier) @field) @hazard.zig_vopr_random
  (#match? @field "^(random|rand|Random|Rand)$")
)

(
  (identifier) @hazard.zig_vopr_random
  (#match? @hazard.zig_vopr_random "^(random|rand|Random|Rand)$")
)

(
  (call_expression function: (identifier) @func) @hazard.zig_vopr_random
  (#eq? @func "getrandom")
)

(
  (call_expression function: (field_expression object: (_) @obj member: (identifier) @method)) @hazard.zig_vopr_net_io
  (#match? @obj "(^|\\.)(posix|IoUring)$")
  (#match? @method "^(recv|send|connect|accept|bind|listen|socket)$")
)

(
  (identifier) @hazard.zig_vopr_net_io
  (#eq? @hazard.zig_vopr_net_io "Stream")
)

(
  (call_expression function: (field_expression object: (_) @obj member: (identifier) @method)) @hazard.zig_vopr_fs_io
  (#match? @obj "(^|\\.)(posix|IoUring)$")
  (#match? @method "^(read|write|open|openat|close|fsync)$")
)

(
  (identifier) @hazard.zig_vopr_fs_io
  (#eq? @hazard.zig_vopr_fs_io "File")
)

(
  (call_expression function: (field_expression object: (_) @obj member: (identifier) @method)) @hazard.zig_vopr_ring_io
  (#match? @obj "(^|\\.)ring$")
  (#match? @method "^(read|write|recv|send|accept|connect|fsync|poll_add|poll_remove|cancel)$")
)
