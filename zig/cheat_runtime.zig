// Module-root facade for the standalone cheat-runtime library. Keeping the
// root at zig/ lets runtime-header.zig import both runtime/ and lib/.
pub const CheatLib = @import("runtime/runtime-header.zig").CheatLib;
