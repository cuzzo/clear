# typed: strict
#! /usr/bin/env ruby

require 'bundler/setup' # so `bundle exec` not needed
require "sorbet-runtime"
begin
  T::Configuration.default_checked_level = :never unless ENV["CLEAR_SORBET_RUNTIME"] == "1"
rescue RuntimeError
  # Embedded callers may have already loaded sigs. The standalone CLI path
  # reaches this before compiler files load, which is the performance-critical
  # case for `clear build`.
end
require "optparse"
require "logger"
require "set"

require_relative "../ast/lexer"
require_relative "../ast/parser"
require_relative "../ast/ast"
require_relative "../compiler/entrypoint"
require_relative "./importer"
require_relative "../annotator"
require_relative "./zig_type_mapper"
require_relative "../mir/cleanup_classifier"
require_relative "./pipeline_rewriter"
require_relative "./string_concat_rewriter"
require_relative "../mir/control_flow"
require_relative "./compiler_frontend"
require_relative "../mir/mir"
require_relative "../mir/mir_lowering"
require_relative "../mir/mir_emitter"
require_relative "../mir/mir_checker"

class ZigTranspiler
    extend T::Sig

  include ZigTypeMapper

  attr_reader :struct_schemas, :union_schemas, :enum_schemas, :module_type_defs

  sig { params(importer: T.nilable(ModuleImporter), source_dir: T.nilable(String)).void }
  def initialize(importer: nil, source_dir: nil)
    @importer            = T.let(importer, T.nilable(ModuleImporter))
    @source_dir          = T.let(source_dir ? File.expand_path(source_dir) : Dir.pwd, String)
    @test_mode           = T.let(false, T::Boolean)
    @default_stack_size  = T.let(nil, T.nilable(String))
    @struct_schemas      = T.let(nil, T.untyped)
    @union_schemas       = T.let(nil, T.untyped)
    @enum_schemas        = T.let(nil, T.untyped)
    @module_type_defs    = T.let(nil, T.untyped)
  end

  # Single-file entry point (used by the CLI and simple callers).
  # pkg_paths: { "name" => "/abs/path/to/lib.cht" } for REQUIRE "pkg:name" resolution.
  sig { params(cheat_code: String, source_dir: String, pkg_paths: T::Hash[String, String], use_c_allocator: T::Boolean, use_debug_allocator: T::Boolean, test_mode: T::Boolean, strict_test: T::Boolean, exact_tiers: T.nilable(T::Hash[Integer, Symbol]), main_tier: T.nilable(Symbol), default_stack: T.nilable(String)).returns(T.nilable(String)) }
  def transpile(cheat_code, source_dir: @source_dir, pkg_paths: {}, use_c_allocator: false, use_debug_allocator: false, test_mode: false, strict_test: false, exact_tiers: nil, main_tier: nil, default_stack: nil)
    transpile_mir(cheat_code, source_dir: source_dir, pkg_paths: pkg_paths,
                  use_c_allocator: use_c_allocator, use_debug_allocator: use_debug_allocator,
                  test_mode: test_mode, strict_test: strict_test,
                  exact_tiers: exact_tiers, main_tier: main_tier,
                  default_stack: default_stack)
  end

  # MIR pipeline: front-end -> MIRLowering -> MIREmitter -> Zig output.
  sig { params(cheat_code: String, source_dir: String, pkg_paths: T::Hash[String, String], use_c_allocator: T::Boolean, use_debug_allocator: T::Boolean, test_mode: T::Boolean, strict_test: T::Boolean, exact_tiers: T.nilable(T::Hash[Integer, Symbol]), main_tier: T.nilable(Symbol), default_stack: T.nilable(String)).returns(T.nilable(String)) }
  def transpile_mir(cheat_code, source_dir: @source_dir, pkg_paths: {}, use_c_allocator: false, use_debug_allocator: false, test_mode: false, strict_test: false, exact_tiers: nil, main_tier: nil, default_stack: nil)
    @source_dir = File.expand_path(source_dir)
    @test_mode = test_mode
    @default_stack_size = default_stack unless default_stack.nil?
    @importer ||= ModuleImporter.new(base_dir: @source_dir, pkg_paths: pkg_paths, use_mir: true)

    result = CompilerFrontend.compile(cheat_code, importer: @importer, source_dir: @source_dir, strict_test: strict_test)

    # Apply exact stack tier overrides (from post-build binary analysis).
    if exact_tiers && !exact_tiers.empty?
      bg_nodes = T.let([], T::Array[AST::BgBlock])
      T.must(result).ast.statements.each do |stmt|
        next unless stmt.is_a?(AST::FunctionDef)
        AST.each_bg_block(stmt.body) do |node|
          bg_nodes << node if node.is_a?(AST::BgBlock)
        end
      end
      exact_tiers.each do |idx, tier|
        bg_nodes[idx]&.tap { |n| n.computed_stack_tier = tier }
      end
    end

    lowering = MIRLowering.new(input: MIRLoweringInput.new(
      struct_schemas: T.must(result).struct_schemas,
      enum_schemas: T.must(result).enum_schemas,
      union_schemas: T.must(result).union_schemas,
      fn_sigs: T.must(result).fn_sigs,
      moved_guard_info: T.must(result).moved_guard_info,
      importer: @importer,
      source_dir: @source_dir,
      debug_mode: @default_stack_size == "Large"
    ))

    needs_c_alloc = use_c_allocator
    program = lowering.lower_program(T.must(result).ast, use_c_allocator: needs_c_alloc, use_debug_allocator: use_debug_allocator)

    # Post-MIR verification: check the ACTUAL code that will be emitted.
    checker = MIRChecker.new
    mir_errors = checker.check_program!(T.must(program), strict: true)
    unless mir_errors.empty?
      raise "MIR ownership verification failed (post-lowering):\n\n#{mir_errors.join("\n")}"
    end

    emitter = MIREmitter.new
    body = emitter.emit(program)
    error_name_enum = emit_error_name_enum

    main_variant = main_stack_variant(T.must(result).fn_nodes["main"], override: main_tier)
    footer = File.read(File.join(File.dirname(__FILE__), '..', '..', 'zig', 'runtime', 'runtime-footer.zig'))
    footer = footer.gsub('.{ .stack_size = .Large, .pinned = true }',
                         ".{ .stack_size = .#{main_variant}, .pinned = true }")

    <<~ZIG
      #{error_name_enum}

      #{body}

      // -------------------------------------------------------------------------
      // 3. Main Entry (Test Harness)
      // -------------------------------------------------------------------------
      #{footer}
    ZIG
  end

  # Emit the per-program ErrorName enum. Populated from AST::ERROR_TYPES
  # at the moment this is called (stdlib seed + whatever user types the
  # annotator registered). Each emitted value's integer id is stable
  # across runs and matches runtime.zig's ErrorName_<N> constants for
  # the stdlib-seeded entries.
  sig { returns(String) }
  def emit_error_name_enum
    lines = AST.enum_entries.map { |sym, id| "    #{sym} = #{id}," }
    <<~ZIG.chomp
      // Generated per-program: CLEAR error types. Stdlib ids (1..3) are
      // stable and match runtime.zig's ErrorName_<Name> constants.
      pub const ErrorName = enum(u32) {
      #{lines.join("\n")}
      };
    ZIG
  end

  MAIN_STACK_VARIANTS = T.let({
    micro: "Micro", standard: "Standard", large: "Large", xl: "Xl",
    service: "Huge", unbounded: "Huge"
  }.freeze, T::Hash[Symbol, String])

  sig { params(main_fn: T.nilable(AST::FunctionDef), override: T.untyped).returns(String) }
  def main_stack_variant(main_fn, override: nil)
    tier = override&.to_sym || main_fn&.stack_tier || :standard
    MAIN_STACK_VARIANTS.fetch(tier, "Standard")
  end

  # Module entry point: transpile code as a Zig module (--module flag).
  # Emits @import("cheat_runtime") instead of runtime-header.zig, no runtime footer.
  sig { params(cheat_code: String, source_dir: String, pkg_paths: T::Hash[T.untyped, T.untyped]).returns(T.nilable(String)) }
  def transpile_as_module(cheat_code, source_dir: @source_dir, pkg_paths: {})
    @source_dir = File.expand_path(source_dir)
    @importer ||= ModuleImporter.new(base_dir: @source_dir, pkg_paths: pkg_paths, use_mir: true)

    result = CompilerFrontend.compile(cheat_code, importer: @importer, source_dir: @source_dir)

    lowering = MIRLowering.new(input: MIRLoweringInput.new(
      struct_schemas: T.must(result).struct_schemas,
      enum_schemas: T.must(result).enum_schemas,
      union_schemas: T.must(result).union_schemas,
      fn_sigs: T.must(result).fn_sigs,
      moved_guard_info: T.must(result).moved_guard_info,
      importer: @importer,
      source_dir: @source_dir
    ))

    mod_result = lowering.lower_module(T.must(result).ast)

    # Post-MIR verification on module functions.
    checker = MIRChecker.new
    T.must(mod_result[:items]).flatten.each do |item|
      next unless item.is_a?(MIR::FnDef)
      mir_errors = checker.check_fn!(item, strict: true)
      unless mir_errors.empty?
        raise "MIR ownership verification failed (post-lowering):\n\n#{mir_errors.join("\n")}"
      end
    end

    # In module mode, EXTERN FN imports use named modules (e.g. -Mhttp=lib.zig).
    # Strip the .zig suffix from simple (non-path) module imports so @import("http")
    # matches the declared module name rather than looking for a file "http.zig".
    all_items = (T.must(mod_result[:items]) + T.must(mod_result[:type_items])).flatten
    all_items.each do |item|
      next unless item.is_a?(MIR::Import)
      next if item.module_path.include?("/")      # filesystem path, leave as-is
      item.module_path = item.module_path.delete_suffix(".zig")
    end

    emitter = MIREmitter.new
    items_zig = T.must(mod_result[:items]).flatten.filter_map { |item| emitter.emit(item) }.join("\n\n")
    type_defs_zig = T.must(mod_result[:type_items]).flatten.filter_map { |item| emitter.emit(item) }.join("\n\n")

    body = [type_defs_zig, items_zig].reject(&:empty?).join("\n\n")
    safety_line = body.include?("safety.") ? "const safety = @import(\"safety\");\n" : ""

    # If the module defines main, emit a Zig test block so the module
    # can be used directly as the root of `zig test` without a wrapper file.
    # Uses a single-threaded scheduler so BG blocks (spawnBest) work correctly.
    has_cheat_main = T.must(result).ast.statements.any? { |s| s.is_a?(AST::FunctionDef) && s.name == Compiler::Entrypoint::NAME }
    test_block = if has_cheat_main
      <<~ZIG_TEST

        test "cheat main" {
            const fp = CheatHeader.scheduler;
            var da = std.heap.DebugAllocator(.{}){};
            defer _ = da.deinit();
            const allocator = da.allocator();
            var global_ctx = EbrContext{};
            defer global_ctx.deinit(allocator);
            var rt = try Runtime.init(allocator, 128 * 1024 * 1024, &global_ctx);
            defer rt.deinit();
            rt.wireAllocator();
            var sched = try fp.Scheduler.init(allocator, &global_ctx, null);
            defer {
                sched.deinit();
                fp.global_registry.deinit(allocator);
            }
            fp.active_scheduler = &sched;
            fp.scheduler_running = true;
            const MainRunner = struct {
                outer_rt: *Runtime,
                fn run(_: *anyopaque, raw_args: ?*anyopaque) anyerror!void {
                    const self: *@This() = @ptrCast(@alignCast(raw_args.?));
                    try clearMain(self.outer_rt);
                }
            };
            var main_runner = MainRunner{ .outer_rt = &rt };
            try sched.submitSpawn(
                @intFromPtr(&Runtime.entryWrapper),
                @as(CheatHeader.TaskFn, @ptrCast(&MainRunner.run)),
                &main_runner,
                .{ .stack_size = .Large, .pinned = true },
            );
            sched.run();
        }
      ZIG_TEST
    else
      ""
    end

    <<~ZIG
      const std = @import("std");
      const CheatHeader = @import("cheat_runtime");
      const CheatLib = CheatHeader.CheatLib;
      const Runtime = CheatHeader.Runtime;
      const EbrContext = CheatHeader.EbrContext;
      #{safety_line}
      #{body}
      #{test_block}
    ZIG
  end
end

# --- RUN IT ---

$logger = T.let(Logger.new(STDOUT), Logger)
$logger.level = Logger::INFO
$logger.formatter = proc do |severity, datetime, progname, msg|
  "[#{severity}] #{msg}\n"
end

if __FILE__ == $0
  options = { mode: :standalone, pkg_paths: {} }

  OptionParser.new do |opts|
    opts.on('--log-level LEVEL', 'Set log level (DEBUG, INFO, WARN, ERROR)') do |level|
      $logger.level = Logger.const_get(level.upcase)
    end
    opts.on('--module', 'Emit as a Zig module (uses @import("cheat_runtime"), no runtime footer)') do
      options[:mode] = :module
    end
    opts.on('--pkg SPEC', 'Register a package path as "name=/abs/path/to/lib.cht"') do |spec|
      name, path = spec.split('=', 2)
      options[:pkg_paths][name] = File.expand_path(path)
    end
    opts.on('--use-c-allocator', 'Use the C allocator (jemalloc/mimalloc) instead of GPA') do
      options[:use_c_allocator] = true
    end
    opts.on('--debug-allocator', 'Use std.heap.DebugAllocator (catches double-free / UAF with stack traces)') do
      options[:use_debug_allocator] = true
    end
    opts.on('--test', 'Emit as test module') do
      options[:mode] = :test
    end
    opts.on('--default-stack SIZE', 'Default stack size class') do |size|
      options[:default_stack] = size
    end
    opts.on('--strict', 'Strict test mode') do
      options[:strict] = true
    end
    opts.on('--mir', 'Use MIR pipeline (ignored, MIR is now the only path)') do
      # No-op: MIR is always used. Flag kept for backward compatibility.
    end
    opts.on('--exact-tiers JSON', 'Override computed stack tiers for BG blocks {"index":"tier"}') do |json|
      require 'json'
      options[:exact_tiers] = JSON.parse(json).transform_keys(&:to_i).transform_values(&:to_sym)
    end
    opts.on('--main-tier TIER', 'Override computed stack tier for the main fiber') do |tier|
      options[:main_tier] = tier.downcase.to_sym
    end
  end.parse!

  script_file = ARGV.first
  if script_file
    code       = File.read(script_file)
    source_dir = File.dirname(File.expand_path(script_file))
    ENV["AUDIT_CURRENT_FILE"] = script_file
    transpiler = ZigTranspiler.new

    case options[:mode]
    when :module
      puts transpiler.transpile_as_module(code, source_dir: source_dir, pkg_paths: options[:pkg_paths])
    when :test
      puts transpiler.transpile(code, source_dir: source_dir, pkg_paths: options[:pkg_paths],
                                test_mode: true, strict_test: !!options[:strict],
                                default_stack: options[:default_stack])
    else
      puts transpiler.transpile(code, source_dir: source_dir, pkg_paths: options[:pkg_paths],
                                use_c_allocator: !!options[:use_c_allocator],
                                use_debug_allocator: !!options[:use_debug_allocator],
                                exact_tiers: options[:exact_tiers],
                                main_tier: options[:main_tier],
                                default_stack: options[:default_stack])
    end
  else
    $stderr.puts "Usage: ruby transpiler.rb [--module] [--pkg name=/path/to/lib.cht] <script.cht>"
  end
end
