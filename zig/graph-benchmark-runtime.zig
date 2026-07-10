// Module-root facade for the graph representation benchmark. Keeping the
// module root at zig/ lets runtime-header.zig import both runtime/ and lib/.
pub const CheatLib = @import("runtime/runtime-header.zig").CheatLib;
