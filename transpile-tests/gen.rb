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

    # 1b. Rewrite pipeline operators into plain AST nodes.
    PipelineRewriter.new.rewrite!(ast)

    annotator = SemanticAnnotator.new(importer: @importer, source_dir: @source_dir)
    annotator.annotate!(ast)

    # 2b. Flatten chained string + into StringConcat nodes.
    StringConcatRewriter.new.rewrite!(ast)

    # 2. Pre-populate signature table.
    @fn_sigs = {}
    schema_lookup = ->(name) { annotator.lookup_type_schema(name) }
    fn_nodes = {}
    ast.statements.each { |s| fn_nodes[s.name] = s if s.is_a?(AST::FunctionDef) }
    fn_nodes.each do |name, fn|
      sig = fn.full_type
      if sig.is_a?(FunctionSignature)
        @fn_sigs[name] = sig
      else
        fs = FunctionSignature.new(params: [], return_type: :Any)
        fs.needs_rt = fn.needs_rt
        fs.can_fail = fn.can_fail
        fs.effects = fn.effects
        @fn_sigs[name] = fs
      end
    end

    # Compute plans + insert MIR nodes (Drop, Promote, SuppressCleanup).
    mir = MIRPass.new(fn_nodes: fn_nodes, schema_lookup: schema_lookup)
    mir.transform!(ast)
    @mir_pass_done = true
    @moved_guard_info = {}
    fn_nodes.each { |name, fn| @moved_guard_info[name] = fn.moved_guard_info if fn.moved_guard_info }

    # 3. Get Raw Zig Body
    @needs_safety_import = false
    transpiled_body = visit(ast)
    @_needs_safety = @needs_safety_import

    # 3. Detect if test uses DO/BG blocks, TCP resources, or sharded EACH (all need a running fiber scheduler).
    needs_scheduler = cheat_code.include?("DO {") || cheat_code.include?("BG {") ||
                      cheat_code.include?("BG STREAM {") ||
                      cheat_code.include?("TCPServer") || cheat_code.include?("TCPClient") ||
                      cheat_code.include?("@pinned") ||
                      transpiled_body.include?("WaitGroup")

    # 4. Wrap in a standard Zig Test Block.
    #    We wrap the code in a struct so 'fn main' doesn't collide
    #    between different tests.
    execution_block = if needs_scheduler
      # DO block tests: run main inside the fiber scheduler so that
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
              // Reset threadlocals BEFORE deinit so subsequent tests don't
              // see a dangling active_scheduler pointer.
              fp.scheduler_running = false;
              sched.deinit();
              // Free the global registry's id_map backing store.
              fp.global_registry.deinit(t_alloc);
          }
          fp.active_scheduler = &sched;
          fp.scheduler_running = true;

          // ---------------------------------------------------------
          // Execution (inside a fiber so WaitGroup.wait() can yield)
          // ---------------------------------------------------------
          if (@hasDecl(S, "clearMain")) {
              const MainRunner = struct {
                  fn run(raw_rt: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                      _ = raw_args;
                      const rt_ptr = @as(*Runtime, @ptrCast(@alignCast(raw_rt)));
                      try S.clearMain(rt_ptr);
                  }
              };
              try sched.submitSpawn(
                  @intFromPtr(&Runtime.entryWrapper),
                  @as(CheatHeader.TaskFn, @ptrCast(&MainRunner.run)),
                  null,
                  .{ .stack_size = .Large },
              );
              sched.run();
          }
      ZIG
    else
      # Standard tests: call main directly (no scheduler needed).
      <<~ZIG
          // ---------------------------------------------------------
          // Execution
          // ---------------------------------------------------------
          // We assume every test script defines 'main'
          if (@hasDecl(S, "clearMain")) {
             const result = try S.clearMain(&rt);

             // If result is an object pointer, we must simulate the
             // "Caller owns the return" rule to prevent false-positive leaks.
             const RType = @TypeOf(result);
             if (@typeInfo(RType) == .pointer) {
                 CheatLib.free(&rt, result);
             }
          }
      ZIG
    end

    safety_import = @_needs_safety ? "const safety = @import(\"safety.zig\");" : ""
    <<~ZIG
      test "#{filename}" {
          #{safety_import}
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
      $stderr.puts "    [ERROR] Failed to transpile #{filename}: #{e.message}"
      $stderr.puts e.backtrace.first(3).join("\n")
      @failed_tests ||= []
      @failed_tests << filename
    end
  end
end

if @failed_tests&.any?
  $stderr.puts "\n#{@failed_tests.size} test(s) FAILED to transpile:"
  @failed_tests.each { |f| $stderr.puts "  - #{f}" }
  exit 1
end

`zig fmt zig/all-tests.zig`
puts "Done. Run with: zig test #{OUTPUT_FILE} -lc"

