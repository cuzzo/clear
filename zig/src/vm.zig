const std = @import("std");

pub const ChunkConstant = union(enum) {
    chunks: *Chunk,
    string: []const u8,
    number: f64,
};

pub const Chunk = struct {
    name: []const u8,
    code: []const []const []const u8,
    constants: []ChunkConstant = &.{},
};

pub const LoadedChunk = struct {
    parsed: std.json.Parsed(Chunk),
    raw_text: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: LoadedChunk) void {
        // 1. Free the parsed structs (Arena)
        self.parsed.deinit();
        // 2. Free the raw file text
        self.allocator.free(self.raw_text);
    }
};

pub fn readChunk(allocator: std.mem.Allocator) !LoadedChunk {
    const path = "/home/yahn/flux/prog.flux.json";

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.debug.print("Could not open {s}: {s}\n", .{path, @errorName(err)});
        return err;
    };
    defer file.close();

    // 1. Read file into a buffer (We know this works!)
    const file_contents = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);

    // 2. Parse it
    // Note: We use 'errdefer' to free the file_contents if parsing fails
    const parsed = std.json.parseFromSlice(Chunk, allocator, file_contents, .{
        .ignore_unknown_fields = true,
    }) catch |err| {
        allocator.free(file_contents);
        return err;
    };

    // 3. Return BOTH the data and the buffer owner
    return LoadedChunk{
        .parsed = parsed,
        .raw_text = file_contents,
        .allocator = allocator,
    };
}

// Return type is `!std.json.Parsed(Chunk)`
// The `!` means "The union of all possible errors thrown inside this function"
//pub fn readChunk(allocator: std.mem.Allocator) !std.json.Parsed(Chunk) {
//    const file = std.fs.cwd().openFile("/home/yahn/flux/prog.flux.json", .{}) catch |err| {
//        std.debug.print("Caught error: {s}\n", .{@errorName(err)});
//        return err;
//    };
//    defer file.close();
//
//    // This worked
//    // Use readToEndAlloc. We limit the file size to 100MB (100 * 1024 * 1024) to be safe.
//    //const file_contents = try file.readToEndAlloc(allocator, 100 * 1024 * 1024);
//
//    //// Parse
//    //const parsed = try std.json.parseFromSlice(Chunk, allocator, file_contents, .{
//
//
//    // TRY THIS
//    // 2. Create a buffered reader (faster than reading 1 byte at a time)
//    const reader = file.reader();
//    var json_reader = std.json.reader(allocator, reader);
//    defer json_reader.deinit();
//
//    // 3. Create a JSON Reader (this converts the file stream into JSON tokens)
//    //const json_reader = std.json.reader(allocator, reader);
//    //const parsed = try std.json.parseFromSlice(Chunk, allocator, json_reader, .{
//    const parsed = try std.json.parseFromTokenSource(Chunk, allocator, &json_reader, .{
//        .ignore_unknown_fields = true,
//    });
//
//    // Remember: Do NOT defer parsed.deinit() here, or you return dead pointers.
//    return parsed;
//}


/// Memory
pub const NanBoxedValue = packed struct {
    bits: u64,

    pub fn fromInt(val: i32) NanBoxedValue {
        const shifted: u64 = @as(u64, @bitCast(val)) | (0x7FF8 << 48);
        return .{ .bits = shifted };
    }

    pub fn fromFloat(val: f64) NanBoxedValue {
        return .{ .bits = @bitCast(val) };
    }

    pub fn isInt(self: NanBoxedValue) bool {
        return (self.bits & (0x7FF8 << 48)) == (0x7FF8 << 48);
    }
};

// Simple arena allocator that grows in fixed-size chunks
pub const Arena = struct {
    const CHUNK_SIZE = 4096; // 4KB chunks
    
    chunks: std.ArrayList([]u8),
    current_chunk: []u8,
    offset: usize,
    backing_allocator: std.mem.Allocator,
    
    pub fn init(backing_allocator: std.mem.Allocator) !Arena {
        var chunks = std.ArrayList([]u8).init(backing_allocator);
        const first_chunk = try backing_allocator.alloc(u8, CHUNK_SIZE);
        try chunks.append(first_chunk);
        
        return Arena{
            .chunks = chunks,
            .current_chunk = first_chunk,
            .offset = 0,
            .backing_allocator = backing_allocator,
        };
    }
    
    pub fn deinit(self: *Arena) void {
        for (self.chunks.items) |chunk| {
            self.backing_allocator.free(chunk);
        }
        self.chunks.deinit();
    }
    
    pub fn allocator(self: *Arena) std.mem.Allocator {
        return std.mem.Allocator{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }
    
    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        _ = ret_addr;
        const self: *Arena = @ptrCast(@alignCast(ctx));
        
        const alignment = @as(usize, 1) << @as(std.mem.Allocator.Log2Align, @intCast(ptr_align));
        const aligned_offset = std.mem.alignForward(usize, self.offset, alignment);
        const new_offset = aligned_offset + len;
        
        // Check if allocation fits in current chunk
        if (new_offset <= self.current_chunk.len) {
            const result = self.current_chunk[aligned_offset..new_offset];
            self.offset = new_offset;
            return result.ptr;
        }
        
        // Need a new chunk
        const chunk_size = @max(CHUNK_SIZE, len);
        const new_chunk = self.backing_allocator.alloc(u8, chunk_size) catch return null;
        self.chunks.append(new_chunk) catch {
            self.backing_allocator.free(new_chunk);
            return null;
        };
        
        self.current_chunk = new_chunk;
        self.offset = len;
        return new_chunk[0..len].ptr;
    }
    
    fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = buf;
        _ = buf_align;
        _ = new_len;
        _ = ret_addr;
        // Arena allocators don't support resize
        return false;
    }
    
    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        _ = ctx;
        _ = buf;
        _ = buf_align;
        _ = ret_addr;
        // Arena allocators don't free individual allocations
    }
    
    // Reset the arena without freeing memory (for reuse)
    pub fn reset(self: *Arena) void {
        self.offset = 0;
        if (self.chunks.items.len > 0) {
            self.current_chunk = self.chunks.items[0];
        }
    }
    
    // Get total bytes allocated across all chunks
    pub fn totalAllocated(self: *Arena) usize {
        var total: usize = 0;
        for (self.chunks.items) |chunk| {
            total += chunk.len;
        }
        return total;
    }
    
    // Get bytes used in current allocation cycle
    pub fn bytesUsed(self: *Arena) usize {
        var used: usize = 0;
        for (self.chunks.items, 0..) |chunk, i| {
            if (i < self.chunks.items.len - 1) {
                used += chunk.len;
            } else {
                used += self.offset;
            }
        }
        return used;
    }
};

// Example: Simple VM value type using arena allocation
pub const Value = struct {
    tag: Tag,
    data: Data,
    
    pub const Tag = enum {
        int,
        float,
        string,
        list,
    };
    
    pub const Data = union {
        int: i64,
        float: f64,
        string: []const u8,
        list: []Value,
    };
    
    pub fn createInt(val: i64) Value {
        return .{ .tag = .int, .data = .{ .int = val } };
    }
    
    pub fn createFloat(val: f64) Value {
        return .{ .tag = .float, .data = .{ .float = val } };
    }
    
    pub fn createString(arena_alloc: std.mem.Allocator, str: []const u8) !Value {
        const owned_str = try arena_alloc.dupe(u8, str);
        return .{ .tag = .string, .data = .{ .string = owned_str } };
    }
    
    pub fn createList(arena_alloc: std.mem.Allocator, capacity: usize) !Value {
        const list = try arena_alloc.alloc(Value, capacity);
        return .{ .tag = .list, .data = .{ .list = list } };
    }
    
    pub fn print(self: Value) void {
        switch (self.tag) {
            .int => std.debug.print("{d}", .{self.data.int}),
            .float => std.debug.print("{d}", .{self.data.float}),
            .string => std.debug.print("\"{s}\"", .{self.data.string}),
            .list => {
                std.debug.print("[", .{});
                for (self.data.list, 0..) |item, i| {
                    if (i > 0) std.debug.print(", ", .{});
                    item.print();
                }
                std.debug.print("]", .{});
            },
        }
    }
};

pub const ThreadSafeArena = struct {
    arena: Arena,
    mutex: std.Thread.Mutex,

    //pub fn allocator(self: *ThreadSafeArena) std.mem.Allocator {
    //    // Return allocator that locks/unlocks around operations
    //}
};


/// VM
// This example shows how to structure a VM bytecode loader
// To use with zigcc/zig-msgpack, add it to your build.zig.zon:
// zig fetch --save https://github.com/zigcc/zig-msgpack/archive/main.tar.gz

// Bytecode instruction representation
pub const OpCode = enum(u8) {
    LOAD_CONST = 0,
    LOAD_LOCAL = 1,
    STORE_LOCAL = 2,
    ADD = 3,
    SUB = 4,
    MUL = 5,
    DIV = 6,
    CALL = 7,
    RETURN = 8,
    JUMP = 9,
    JUMP_IF_FALSE = 10,
    PRINT = 11,
};

pub const Instruction = packed struct {
    op: OpCode, // 8 bits
    a:  u8,     // 8 bits (Target Register)
    b:  u8,     // 8 bits (Source 1)
    c:  u8,     // 8 bits (Source 2)
};

// Constant value types
pub const Constant = union(enum) {
    int: i64,
    float: f64,
    string: []const u8,
    bool: bool,
    
    pub fn print(self: *const Constant) void {
        switch (self.*) {
            .int => |val| std.debug.print("{d}", .{val}),
            .float => |val| std.debug.print("{d}", .{val}),
            .string => |val| std.debug.print("\"{s}\"", .{val}),
            .bool => |val| std.debug.print("{}", .{val}),
        }
    }
};

// Bytecode module structure (matches Ruby output)
pub const BytecodeModule = struct {
    version: u32,
    constants: []Constant,
    instructions: []Instruction,
    source_file: []const u8,
    
    pub fn deinit(self: *BytecodeModule, allocator: std.mem.Allocator) void {
        allocator.free(self.constants);
        allocator.free(self.instructions);
        allocator.free(self.source_file);
    }
};




// VM that executes loaded bytecode
pub const VM = struct {
    arena: std.heap.ArenaAllocator,
    module: ?BytecodeModule,
    stack: std.ArrayListUnmanaged(Constant),
    bp: usize, // base pointer
    ip: usize, // instruction pointer
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) VM {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .module = null,
            .stack = .{},
            .bp = 0,
            .ip = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VM) void {
        if (self.module) |*mod| {
            mod.deinit(self.allocator);
        }
        self.stack.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn loadModule(self: *VM, module: BytecodeModule) void {
        self.module = module;
        self.bp = 0;
    }

    pub fn execute(self: *VM) !void {
        const module = self.module orelse return error.NoModuleLoaded;

        std.debug.print("=== Executing Bytecode ===\n", .{});
        std.debug.print("Version: {d}\n", .{module.version});
        std.debug.print("Source: {s}\n", .{module.source_file});
        std.debug.print("Constants: {d}\n", .{module.constants.len});
        std.debug.print("Instructions: {d}\n\n", .{module.instructions.len});

        while (self.ip < module.instructions.len) {
            const instr = module.instructions[self.ip];

            std.debug.print("[{d:0>4}] {s} {d}\n", .{
                self.ip,
                @tagName(instr.op),
                instr.a, // TODO: Include b and target
            });

            try self.executeInstruction(instr);
            self.ip += 1;
        }

        std.debug.print("\n=== Execution Complete ===\n", .{});
    }

    fn executeInstruction(self: *VM, instr: Instruction) !void {
        const module = self.module orelse return error.NoModuleLoaded;

        switch (instr.op) {
            .LOAD_CONST => {
                const target_reg_index = self.bp + instr.a;
                const constant_index = instr.b;

                // Safety check
                if (constant_index >= module.constants.len) {
                    return error.InvalidConstantIndex;
                }

                // Ensure the register file (stack) is big enough
                // In a real VM, you allocate the whole "stack frame" when entering the function,
                // but for this simple demo, we might need to grow if we write to a high register.
                if (target_reg_index >= self.stack.items.len) {
                    // In a register VM, we usually pre-allocate, but here's a lazy fix:
                    try self.stack.resize(self.allocator, target_reg_index + 1);
                }

                // WRITE the value to the specific slot
                self.stack.items[target_reg_index] = module.constants[constant_index];
            },
            .PRINT => {
                // 1. Get the register index from operand A
                const reg_index = self.bp + instr.a;

                std.debug.print("  pb {d} : {d} : {d} \n", .{reg_index, self.bp, instr.a});

                // 2. Bounds check (crucial in register VMs)
                if (reg_index >= self.stack.items.len) {
                    return error.RegisterOutOfBounds;
                }

                // 3. Read (Do NOT pop)
                const val = self.stack.items[reg_index];

                std.debug.print("  Output: ", .{});
                val.print();
                std.debug.print("\n", .{});
            },
            .ADD => {
                // 1. Calculate Indices
                // Remember: In Register VM, operands are INDICES, not values.
                const target_idx = self.bp + instr.a;
                const src1_idx   = self.bp + instr.b;
                const src2_idx   = self.bp + instr.c;

                // Safety Check (Optional but recommended)
                if (target_idx >= self.stack.items.len or
                    src1_idx >= self.stack.items.len or
                    src2_idx >= self.stack.items.len)
                {

                    std.debug.print("  pb {d} : {d} : {d} : {d} \n", .{target_idx, self.bp, instr.b, instr.c});
                    return error.RegisterOutOfBounds;
                }

                // 2. Read Values from the "Register File" (Stack)
                const val_b = self.stack.items[src1_idx];
                const val_c = self.stack.items[src2_idx];

                // Simple integer addition for demo
                if (val_b == .int and val_c == .int) {
                    const result = val_b.int + val_c.int;
                    self.stack.items[target_idx] = .{ .int = result };
                } else {
                    return error.TypeMismatch;
                }
            },
           .RETURN => {
                // Optional: You could read register 'instr.a' here if you wanted 
                // to pass a return value back to the caller.
                // For now, just stop the loop.
                // End execution
                self.bp = module.instructions.len;
            },
            else => {
                std.debug.print("  Unimplemented opcode: {s}\n", .{@tagName(instr.op)});
            },
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const parsed_json = try readChunk(allocator);
    defer parsed_json.deinit();

    const main_chunk = parsed_json.parsed.value;
    std.debug.print("=== JSON Bytecode Loader Demo ===\n\n", .{});

    for (main_chunk.code, 0..) |instr_list, i| {
        std.debug.print("  [{d:0>3}] ", .{i});
        
        // Loop through the tokens in the instruction
        for (instr_list) |token| {
            std.debug.print("{s} ", .{token});
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("\n=== Simulated Bytecode Execution ===\n\n", .{});

    // Create a mock bytecode module (as if loaded from MsgPack)
    var constants = try allocator.alloc(Constant, 3);
    constants[0] = .{ .int = 42 };
    constants[1] = .{ .string = "Hello from VM!" };
    constants[2] = .{ .int = 10 };

    var instructions = try allocator.alloc(Instruction, 5);

    // 1. LOAD_CONST r0, const[0]
    // a=0 (Target Reg r0), b=0 (Constant Index 0)
    instructions[0] = .{ .op = .LOAD_CONST, .a = 0, .b = 0, .c = 0 };

    // 2. LOAD_CONST r1, const[2]
    // a=1 (Target Reg r1), b=2 (Constant Index 2)
    instructions[1] = .{ .op = .LOAD_CONST, .a = 1, .b = 2, .c = 0 };

    // 3. ADD r2, r0, r1
    // a=2 (Target Reg r2), b=0 (Source r0), c=1 (Source r1)
    instructions[2] = .{ .op = .ADD, .a = 2, .b = 0, .c = 1 };

    instructions[3] = .{ .op = .PRINT, .a = 2, .b = 0, .c = 0 };  // Print result (52)
    instructions[4] = .{ .op = .RETURN, .a = 2, .b = 0, .c = 0 };

    const source = try allocator.dupe(u8, "example.lang");

    const module = BytecodeModule{
        .version = 1,
        .constants = constants,
        .instructions = instructions,
        .source_file = source,
    };

    // Execute in VM
    var vm = VM.init(allocator);
    defer vm.deinit();

    try vm.stack.resize(allocator, 3);

    vm.loadModule(module);
    try vm.execute();
}

