#! /usr/bin/env ruby

require 'bundler/setup' # so `bundle exec` not needed
require "optparse"
require "logger"
require "set"

require_relative "./lexer"
require_relative "./parser"
require_relative "./ast"
require_relative "./annotator"
require_relative "./zig_type_mapper"
require_relative "./promotion_plan"
require_relative "./pipeline_rewriter"
require_relative "./string_concat_rewriter"
require_relative "./control_flow"
require_relative "./importer"
require_relative "./compiler_frontend"
require_relative "./mir"
require_relative "./mir_lowering"
require_relative "./mir_emitter"
require_relative "./mir_checker"

class ZigTranspiler
  include ZigTypeMapper

  attr_reader :struct_schemas, :union_schemas, :enum_schemas, :module_type_defs

  def initialize(importer: nil, source_dir: nil)
    @importer   = importer
    @source_dir = source_dir ? File.expand_path(source_dir) : Dir.pwd
  end

  # Single-file entry point (used by the CLI and simple callers).
  # pkg_paths: { "name" => "/abs/path/to/lib.cht" } for REQUIRE "pkg:name" resolution.
  def transpile(cheat_code, source_dir: @source_dir, pkg_paths: {}, use_c_allocator: false, test_mode: false, strict_test: false)
    transpile_mir(cheat_code, source_dir: source_dir, pkg_paths: pkg_paths,
                  use_c_allocator: use_c_allocator, test_mode: test_mode, strict_test: strict_test)
  end

  # MIR pipeline: front-end -> MIRLowering -> MIREmitter -> Zig output.
  def transpile_mir(cheat_code, source_dir: @source_dir, pkg_paths: {}, use_c_allocator: false, test_mode: false, strict_test: false)
    @source_dir = File.expand_path(source_dir)
    @test_mode = test_mode
    @importer ||= ModuleImporter.new(base_dir: @source_dir, pkg_paths: pkg_paths, use_mir: true)

    result = CompilerFrontend.compile(cheat_code, importer: @importer, source_dir: @source_dir, strict_test: strict_test)

    lowering = MIRLowering.new(
      struct_schemas: result.struct_schemas,
      enum_schemas: result.enum_schemas,
      union_schemas: result.union_schemas,
      fn_sigs: result.fn_sigs,
      moved_guard_info: result.moved_guard_info,
      importer: @importer,
      source_dir: @source_dir,
      debug_mode: @default_stack_size == "Large"
    )

    needs_c_alloc = use_c_allocator
    program = lowering.lower_program(result.ast, use_c_allocator: needs_c_alloc)

    # Post-MIR verification: check the ACTUAL code that will be emitted.
    checker = MIRChecker.new
    mir_errors = checker.check_program!(program)
    unless mir_errors.empty?
      raise "MIR ownership verification failed (post-lowering):\n\n#{mir_errors.join("\n")}"
    end

    emitter = MIREmitter.new
    body = emitter.emit(program)

    <<~ZIG
      #{body}

      // -------------------------------------------------------------------------
      // 3. Main Entry (Test Harness)
      // -------------------------------------------------------------------------
      #{File.read(File.join(File.dirname(__FILE__), '..', 'zig', 'runtime-footer.zig'))}
    ZIG
  end

  # Module entry point: transpile code as a Zig module (--module flag).
  # Emits @import("cheat_runtime") instead of runtime-header.zig, no runtime footer.
  def transpile_as_module(cheat_code, source_dir: @source_dir, pkg_paths: {})
    @source_dir = File.expand_path(source_dir)
    @importer ||= ModuleImporter.new(base_dir: @source_dir, pkg_paths: pkg_paths, use_mir: true)

    result = CompilerFrontend.compile(cheat_code, importer: @importer, source_dir: @source_dir)

    lowering = MIRLowering.new(
      struct_schemas: result.struct_schemas,
      enum_schemas: result.enum_schemas,
      union_schemas: result.union_schemas,
      fn_sigs: result.fn_sigs,
      moved_guard_info: result.moved_guard_info,
      importer: @importer,
      source_dir: @source_dir
    )

    mod_result = lowering.lower_module(result.ast)

    # Post-MIR verification on module functions.
    checker = MIRChecker.new
    mod_result[:items].flatten.each do |item|
      next unless item.is_a?(MIR::FnDef)
      mir_errors = checker.check_fn!(item)
      unless mir_errors.empty?
        raise "MIR ownership verification failed (post-lowering):\n\n#{mir_errors.join("\n")}"
      end
    end

    emitter = MIREmitter.new
    items_zig = mod_result[:items].flatten.filter_map { |item| emitter.emit(item) }.join("\n\n")
    type_defs_zig = mod_result[:type_items].flatten.filter_map { |item| emitter.emit(item) }.join("\n\n")

    body = [type_defs_zig, items_zig].reject(&:empty?).join("\n\n")
    safety_line = body.include?("safety.") ? "const safety = @import(\"safety.zig\");\n" : ""

    # If the module defines main, emit a Zig test block so the module
    # can be used directly as the root of `zig test` without a wrapper file.
    has_cheat_main = result.ast.statements.any? { |s| s.is_a?(AST::FunctionDef) && s.name == "main" }
    test_block = if has_cheat_main
      <<~ZIG_TEST

        test "cheat main" {
            var gpa = std.heap.GeneralPurposeAllocator(.{}){};
            defer _ = gpa.deinit();
            const allocator = gpa.allocator();
            var global_ctx = EbrContext{};
            defer global_ctx.deinit(allocator);
            var rt = try Runtime.init(allocator, 128 * 1024 * 1024, &global_ctx);
            defer rt.deinit();
            rt.wireAllocator();
            try clearMain(&rt);
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

$logger = Logger.new(STDOUT)
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
  end.parse!

  script_file = ARGV.first
  if script_file
    code       = File.read(script_file)
    source_dir = File.dirname(File.expand_path(script_file))
    transpiler = ZigTranspiler.new

    case options[:mode]
    when :module
      puts transpiler.transpile_as_module(code, source_dir: source_dir, pkg_paths: options[:pkg_paths])
    when :test
      puts transpiler.transpile(code, source_dir: source_dir, pkg_paths: options[:pkg_paths],
                                test_mode: true, strict_test: !!options[:strict])
    else
      puts transpiler.transpile(code, source_dir: source_dir, pkg_paths: options[:pkg_paths],
                                use_c_allocator: !!options[:use_c_allocator])
    end
  else
    $stderr.puts "Usage: ruby transpiler.rb [--module] [--pkg name=/path/to/lib.cht] <script.cht>"
  end
end
