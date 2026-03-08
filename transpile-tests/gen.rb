#! /usr/bin/env ruby
require 'bundler/setup'
require_relative '../src/transpiler'

# 1. Subclass to expose the raw 'visit' method
#    and bypass the standard header/footer logic.
class TestGenerator < ZigTranspiler
  # Make 'visit' public so we can grab the raw body
  public :visit

  def generate_test_block(filename, cheat_code, source_dir: Dir.pwd)
    @source_dir = File.expand_path(source_dir)
    @importer   = ModuleImporter.new(base_dir: @source_dir)

    # 1. Parse AST
    tokens = Lexer.new(cheat_code).tokenize
    ast = Parser.new(tokens, cheat_code).parse
    annotator = SemanticAnnotator.new(importer: @importer, source_dir: @source_dir)
    annotator.annotate!(ast)

    # 2. Get Raw Zig Body
    transpiled_body = visit(ast)

    # 3. Detect if test uses DO or BG blocks (needs a running fiber scheduler).
    needs_scheduler = cheat_code.include?("DO {") || cheat_code.include?("BG {")

    # 4. Wrap in a standard Zig Test Block.
    #    We wrap the code in a struct so 'fn cheatMain' doesn't collide
    #    between different tests.
    execution_block = if needs_scheduler
      # DO block tests: run cheatMain inside the fiber scheduler so that
      # WaitGroup.wait() can yield and submitSpawn() can enqueue fibers.
      <<~ZIG
          // ---------------------------------------------------------
          // Scheduler Setup (required for DO block fork-join)
          // ---------------------------------------------------------
          const fm = @import("fiber-memory.zig");
          const fp = @import("scheduler.zig");
          var stack_pool = fm.StackPool.init(t_alloc);
          defer stack_pool.deinit();
          var sched = try fp.Scheduler.init(t_alloc, &global_ctx, &stack_pool);
          defer {
              sched.deinit();
              // Free the global registry's hash map backing store.
              fp.global_registry.deinit(t_alloc);
          }
          fp.active_scheduler = &sched;

          // ---------------------------------------------------------
          // Execution (inside a fiber so WaitGroup.wait() can yield)
          // ---------------------------------------------------------
          if (@hasDecl(S, "cheatMain")) {
              const MainRunner = struct {
                  fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                      _ = raw_args;
                      const rt_ptr = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                      try S.cheatMain(rt_ptr);
                  }
              };
              try sched.submitSpawn(
                  @intFromPtr(&Runtime.entryWrapper),
                  @as(CheatHeader.TaskFn, @ptrCast(&MainRunner.run)),
                  null,
                  .{},
              );
              sched.run();
          }
      ZIG
    else
      # Standard tests: call cheatMain directly (no scheduler needed).
      <<~ZIG
          // ---------------------------------------------------------
          // Execution
          // ---------------------------------------------------------
          // We assume every test script defines 'cheatMain'
          if (@hasDecl(S, "cheatMain")) {
             const result = try S.cheatMain(&rt);

             // If result is an object pointer, we must simulate the
             // "Caller owns the return" rule to prevent false-positive leaks.
             const RType = @TypeOf(result);
             if (@typeInfo(RType) == .pointer) {
                 CheatLib.free(&rt, result);
             }
          }
      ZIG
    end

    <<~ZIG
      test "#{filename}" {
          // ---------------------------------------------------------
          // Namespace Isolation
          // ---------------------------------------------------------
          const S = struct {
              #{transpiled_body}
          };

          // ---------------------------------------------------------
          // Test Runtime Setup
          // ---------------------------------------------------------
          // Use std.testing.allocator to detect leaks automatically!
          const t_alloc = std.testing.allocator;

          var global_ctx = EbrContext{};
          defer global_ctx.deinit(t_alloc);

          // Initialize Runtime with the Testing Allocator
          var rt = try Runtime.init(
              t_alloc,      // Backing Allocator
              1024 * 1024,  // Frame Size
              &global_ctx,
          );
          defer rt.deinit();
          rt.wireAllocator();

          #{execution_block}
      }
    ZIG
  end
end

# --- Script Execution ---

TEST_DIR = "transpile-tests"
OUTPUT_FILE = "zig/all-tests.zig"
HEADER_FILE = "zig/runtime-header.zig"

puts "Generating #{OUTPUT_FILE}..."

File.open(OUTPUT_FILE, "w") do |f|
  # 1. Write the Runtime Header (Once)
  #    We strip the imports inside runtime-header if necessary,
  #    but usually it's fine. We definitely need 'std'.
  if File.exist?(HEADER_FILE)
    f.puts "// --- RUNTIME HEADER ---"
    f.puts "const std = @import(\"std\");"
    f.puts "const CheatHeader = @import(\"runtime-header.zig\");"
    f.puts "const CheatLib = CheatHeader.CheatLib;"
    f.puts "const Runtime = CheatHeader.Runtime;"
    f.puts "const EbrContext = CheatHeader.EbrContext;"
  else
    puts "Error: #{HEADER_FILE} not found."
    exit 1
  end

  # 2. Iterate through all .cht files in the test directory
  test_source_dir = File.expand_path(TEST_DIR)

  Dir.glob("#{TEST_DIR}/*.cht").sort.each do |test_file|
    filename = File.basename(test_file)
    puts "  - Processing #{filename}"

    code = File.read(test_file)
    generator = TestGenerator.new

    begin
      block = generator.generate_test_block(filename, code, source_dir: test_source_dir)
      f.puts "\n// --- TEST: #{filename} ---"
      f.puts block
    rescue => e
      puts "    [ERROR] Failed to transpile #{filename}: #{e.message}"
      puts e.backtrace.join("\n")
    end
  end
end

`zig fmt zig/all-tests.zig`
puts "Done. Run with: zig test #{OUTPUT_FILE} -lc"

