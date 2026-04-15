#! /usr/bin/env ruby
require 'bundler/setup'
require_relative '../src/transpiler'

# Generates Zig test blocks from .cht files using MIRLowering + MIREmitter.
class TestGenerator
  def generate_test_block(filename, cheat_code, source_dir: Dir.pwd)
    source_dir = File.expand_path(source_dir)
    importer = ModuleImporter.new(base_dir: source_dir, use_mir: true)

    result = CompilerFrontend.compile(cheat_code, importer: importer, source_dir: source_dir)

    lowering = MIRLowering.new(
      struct_schemas: result.struct_schemas,
      enum_schemas: result.enum_schemas,
      union_schemas: result.union_schemas,
      fn_sigs: result.fn_sigs,
      moved_guard_info: result.moved_guard_info,
      importer: importer,
      source_dir: source_dir
    )
    program = lowering.lower_program(result.ast)

    # Post-MIR verification: catch allocator mismatches before emitting Zig.
    checker = MIRChecker.new
    mir_errors = checker.check_program!(program)
    unless mir_errors.empty?
      raise "MIR ownership verification failed (post-lowering):\n\n#{mir_errors.join("\n")}"
    end

    # Emit Zig - keep non-runtime imports/aliases inside the test harness so
    # local FFI modules and extern struct aliases still resolve without named modules.
    emitter = MIREmitter.new
    preamble_items = program.items.select { |item|
      case item
      when MIR::Import
        !(%w[std CheatHeader].include?(item.alias_name))
      when MIR::TypeAlias
        !(%w[CheatLib Runtime EbrContext].include?(item.name))
      else
        false
      end
    }
    body_items = program.items.reject { |item| preamble_items.include?(item) || item.is_a?(MIR::Import) || item.is_a?(MIR::TypeAlias) }
    preamble = preamble_items.filter_map { |item| emitter.emit(item) }.join("\n\n")
    transpiled_body = body_items.filter_map { |item| emitter.emit(item) }.join("\n\n")

    # Detect if test uses DO/BG blocks, TCP resources, or sharded EACH
    needs_scheduler = cheat_code.include?("DO {") || cheat_code.include?("BG {") ||
                      cheat_code.include?("BG STREAM {") ||
                      cheat_code.include?("TCPServer") || cheat_code.include?("TCPClient") ||
                      cheat_code.include?("@pinned") ||
                      transpiled_body.include?("WaitGroup")

    execution_block = if needs_scheduler
      <<~ZIG
          const fm = @import("runtime/fiber-memory.zig");
          const fp = @import("runtime/scheduler.zig");
          var stack_pool = fm.StackPool.init(t_alloc);
          defer stack_pool.deinit();
          var sched = try fp.Scheduler.init(t_alloc, &global_ctx, &stack_pool);
          defer {
              fp.scheduler_running = false;
              sched.deinit();
              fp.global_registry.deinit(t_alloc);
          }
          fp.active_scheduler = &sched;
          fp.scheduler_running = true;

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
      <<~ZIG
          if (@hasDecl(S, "clearMain")) {
             const result = try S.clearMain(&rt);
             const RType = @TypeOf(result);
             if (@typeInfo(RType) == .pointer) {
                 CheatLib.free(&rt, result);
             }
          }
      ZIG
    end

    <<~ZIG
      test "#{filename}" {
          #{preamble}
          const S = struct {
              #{transpiled_body}
          };

          const t_alloc = std.testing.allocator;

          var global_ctx = EbrContext{};
          defer global_ctx.deinit(t_alloc);

          var rt = try Runtime.init(
              t_alloc,
              1024 * 1024,
              &global_ctx,
          );
          defer rt.deinit();
          rt.wireAllocator();

          #{execution_block}
      }
    ZIG
  end

  # Generate a complete single-file zig test (header + one test block).
  def generate_single_test(filename, cheat_code, source_dir: Dir.pwd)
    block = generate_test_block(filename, cheat_code, source_dir: source_dir)
    frame_debug = ENV['CLEAR_FRAME_DEBUG'] == '1'
    <<~ZIG
      pub const CLEAR_FRAME_DEBUG = #{frame_debug};
      const std = @import("std");
      const CheatHeader = @import("runtime/runtime-header.zig");
      const CheatLib = CheatHeader.CheatLib;
      const Runtime = CheatHeader.Runtime;
      const EbrContext = CheatHeader.EbrContext;

      #{block}
    ZIG
  end
end

# --- Script Execution ---

# Accept --mir for backward compatibility (ignored, MIR is always used)
ARGV.delete('--mir')

# Single-file mode: ruby gen.rb --single foo.cht
# Outputs a complete zig test file to stdout.
if ARGV.delete('--single')
  test_file = ARGV.first
  unless test_file && File.exist?(test_file)
    $stderr.puts "Usage: ruby gen.rb --single <file.cht>"
    exit 1
  end
  code = File.read(test_file)
  source_dir = File.expand_path(File.dirname(test_file))
  generator = TestGenerator.new
  puts generator.generate_single_test(File.basename(test_file), code, source_dir: source_dir)
  exit 0
end

TEST_DIR = "transpile-tests"
OUTPUT_FILE = "zig/all-tests.zig"
HEADER_FILE = "zig/runtime/runtime-header.zig"

puts "Generating #{OUTPUT_FILE}..."

File.open(OUTPUT_FILE, "w") do |f|
  # 1. Write the Runtime Header (Once)
  if File.exist?(HEADER_FILE)
    f.puts "// --- RUNTIME HEADER ---"
    frame_debug = ENV['CLEAR_FRAME_DEBUG'] == '1'
    f.puts "pub const CLEAR_FRAME_DEBUG = #{frame_debug};"
    f.puts "const std = @import(\"std\");"
    f.puts "const CheatHeader = @import(\"runtime/runtime-header.zig\");"
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
