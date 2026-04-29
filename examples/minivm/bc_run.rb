#!/usr/bin/env ruby
# bc_run.rb: compile a CLEAR source file to bytecode and run it on the bytecode VM.
# Usage: ruby bc_run.rb program.cht [--run]
#
# Runs CompilerFrontend -> MIRLowering -> MIRChecker -> BcEmitter,
# writes ops/consts to temp files, then executes the compiled _bc_runner binary.
# The _bc_runner binary is built once from _bc_runner.cht and cached.

src_root = File.expand_path("../../src", __dir__)
$LOAD_PATH.unshift(src_root)
$LOAD_PATH.unshift(File.join(src_root, "ast"))
$LOAD_PATH.unshift(File.join(src_root, "mir"))
$LOAD_PATH.unshift(File.join(src_root, "backends"))
$LOAD_PATH.unshift(File.join(src_root, "annotator-helpers"))

require "set"
require "open3"

if $PROGRAM_NAME == __FILE__ && ARGV.empty?
  $stderr.puts "Usage: ruby bc_run.rb <file.cht>"
  exit 1
end

if $PROGRAM_NAME == __FILE__
  ARGV.delete("--run")  # accepted but ignored (run is always the mode)

  project_root   = File.expand_path("../../", __dir__)
  optimized = !ENV["BC_OPT"].nil? && ENV["BC_OPT"] != "0"
  # BC_DEBUG_ALLOC=1 builds the runner with std.heap.DebugAllocator's safety
  # checks (double-free / UAF panic with stack trace). Cached separately so
  # normal runs aren't affected.
  debug_alloc = !ENV["BC_DEBUG_ALLOC"].nil? && ENV["BC_DEBUG_ALLOC"] != "0"
  runner_basename = if optimized then "_bc_runner_opt"
                    elsif debug_alloc then "_bc_runner_dbg"
                    else "_bc_runner"
                    end
  bc_runner_path = File.join(__dir__, runner_basename)
  bc_runner_src  = File.join(__dir__, "_bc_runner.cht")
  bc_ops_file    = File.join(__dir__, "_bc_ops.txt")
  bc_consts_file = File.join(__dir__, "_bc_consts.txt")
  completion_marker = "SCHEME: all expressions completed"

  bc_runner_stale = !File.exist?(bc_runner_path) ||
                    File.mtime(bc_runner_path) < File.mtime(bc_runner_src)

  if bc_runner_stale
    $stderr.puts "Building bc_runner (cached for subsequent tests)..."
    bc_runner_src_text = File.read(bc_runner_src)
    interp_base = bc_runner_src_text
    main_idx    = bc_runner_src_text.index(/^FN main\(\)/)
    interp_base = bc_runner_src_text[0...main_idx] if main_idx

    bc_runner_main  = "FN main() RETURNS Void ->\n"
    bc_runner_main += "    MUTABLE pool: Env[50000]@pool:shared:locked = [];\n"
    bc_runner_main += "    MUTABLE penv: HashMap<Value> = {};\n"
    bc_runner_main += "    rootId = setupEnv!(pool);\n"
    bc_runner_main += "    bcOps = loadBytecodeOps!(\"#{bc_ops_file}\", pool);\n"
    bc_runner_main += "    bcConsts = loadBytecodeConsts!(\"#{bc_consts_file}\", pool);\n"
    bc_runner_main += "    mainCaps: Value[] = [];\n"
    bc_runner_main += "    bcResult = exec!(bcOps, bcConsts, rootId, pool, 0_i64, mainCaps);\n"
    bc_runner_main += "    IF isError?(bcResult) THEN\n"
    bc_runner_main += "        print(\"SCHEME ASSERT FAILED: \" + getErrMsg(bcResult));\n"
    bc_runner_main += "    ELSE\n"
    bc_runner_main += "        print(prStr(bcResult, FALSE));\n"
    bc_runner_main += "        print(\"#{completion_marker}\");\n"
    bc_runner_main += "    END\n"
    bc_runner_main += "    RETURN;\nEND\n"

    File.write(bc_runner_src, interp_base + bc_runner_main)
    build_args = ["build"]
    # DebugAllocator + libc are mutually exclusive: the debug allocator is
    # the whole point — it's the source of truth for alloc/free pairing.
    if debug_alloc
      build_args << "--debug-allocator"
    else
      build_args << "--use-c-allocator"
    end
    build_args << "--optimized" if optimized
    build_args.concat([bc_runner_src, "-o", bc_runner_path])
    if debug_alloc
      # Surface compile errors when wiring the new flag through the build.
      system("#{project_root}/clear", *build_args)
    else
      system("#{project_root}/clear", *build_args, [:out, :err] => File::NULL)
    end
  end

  require_relative "bc_emitter"
  require "compiler_frontend"
  require "mir_lowering"
  require "mir_checker"
  require "importer"

  source_file = File.expand_path(ARGV[0])
  source      = File.read(source_file)
  source_dir  = File.dirname(source_file)

  bc_emitter = begin
    importer  = ModuleImporter.new(base_dir: source_dir)
    fe_result = CompilerFrontend.compile(source, importer: importer, source_dir: source_dir)
    lowering  = MIRLowering.new(
      struct_schemas:   fe_result.struct_schemas,
      enum_schemas:     fe_result.enum_schemas,
      union_schemas:    fe_result.union_schemas,
      fn_sigs:          fe_result.fn_sigs,
      moved_guard_info: fe_result.moved_guard_info,
      importer:         importer,
      source_dir:       source_dir,
      target:           :bc
    )
    program    = lowering.lower_program(fe_result.ast)
    mir_errors = MIRChecker.new.check_program!(program, strict: true)
    unless mir_errors.nil? || mir_errors.empty?
      $stderr.puts "MIR validation errors: #{mir_errors.first}"
      nil
    else
      e = BcEmitter.new(fe_result, source: source)
      e.compile(program)
      e
    end
  rescue => e
    $stderr.puts "Bytecode compilation error: #{e.message}"
    $stderr.puts e.backtrace.first(5).join("\n") if ENV["BC_DEBUG"]
    nil
  end

  if bc_emitter
    begin
      # Write ops and consts to separate files. Do NOT split serialize()'s
      # output by `\n` — string consts are length-prefixed and may embed
      # newline bytes, which a naive line-split would corrupt.
      File.write(bc_ops_file, bc_emitter.serialize_ops_blob)
      File.write(bc_consts_file, bc_emitter.serialize_consts_blob)
      output, _status = Open3.capture2e(bc_runner_path)
      print output
    ensure
      unless ENV["BC_KEEP"]
        File.delete(bc_ops_file)    if File.exist?(bc_ops_file)
        File.delete(bc_consts_file) if File.exist?(bc_consts_file)
      end
    end
  end
end
