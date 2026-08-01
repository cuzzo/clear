#!/usr/bin/env ruby
# bc_run.rb: compile a CLEAR source file to bytecode and run it on the bytecode VM.
# Usage: ruby bc_run.rb program.clear [--run]
#
# Runs CompilerFrontend -> MIRLowering -> MIRChecker -> RegisterBcEmitter,
# writes ops/consts to temp files, then executes the compiled register VM
# binary. The runner is built once from vm.clear and cached.

src_root = File.expand_path("../../compiler/ruby", __dir__)
$LOAD_PATH.unshift(src_root)
$LOAD_PATH.unshift(File.join(src_root, "ast"))
$LOAD_PATH.unshift(File.join(src_root, "mir"))
$LOAD_PATH.unshift(File.join(src_root, "backends"))
$LOAD_PATH.unshift(File.join(src_root, "annotator-helpers"))

require "set"
require "open3"
require "digest"

# Resolves libjemalloc.so on the host. When present, LD_PRELOAD'ing
# it routes the binary's libc malloc/free through jemalloc, which
# is dramatically faster on the VM's hot allocation path
# (per-iteration ArrayList growth, hash-map bucket grows, key-string
# dupes). Returns "" if jemalloc isn't installed; the caller can
# safely concatenate it onto a command string. Mirrors the resolver
# in benchmarks/runner.rb.
def jemalloc_preload_path
  Dir.glob("/lib/x86_64-linux-gnu/libjemalloc.so*").first ||
    Dir.glob("/usr/lib/libjemalloc.so*").first ||
    Dir.glob("/usr/local/lib/libjemalloc.so*").first
end

def jemalloc_env
  return {} if ENV["NO_JEMALLOC"]
  path = jemalloc_preload_path
  path ? { "LD_PRELOAD" => path } : {}
end

def run_clear_build(project_root, build_args)
  clean_env = clear_build_env
  if defined?(Bundler)
    Bundler.with_unbundled_env { system(clean_env, "#{project_root}/clear", *build_args, out: File::NULL) }
  else
    system(clean_env, "#{project_root}/clear", *build_args, out: File::NULL)
  end
end

def clear_build_env
  clean_env = {
    "BUNDLE_BIN_PATH" => nil,
    "BUNDLE_GEMFILE" => nil,
    "BUNDLER_ORIG_BUNDLE_BIN_PATH" => nil,
    "BUNDLER_ORIG_BUNDLE_GEMFILE" => nil,
    "BUNDLER_ORIG_GEM_HOME" => nil,
    "BUNDLER_ORIG_GEM_PATH" => nil,
    "BUNDLER_ORIG_MANPATH" => nil,
    "BUNDLER_ORIG_PATH" => nil,
    "BUNDLER_ORIG_RB_USER_INSTALL" => nil,
    "BUNDLER_ORIG_RUBYLIB" => nil,
    "BUNDLER_ORIG_RUBYOPT" => nil,
    "RUBYLIB" => nil,
    "RUBYOPT" => nil,
  }
  clean_env["RUBYOPT"] = ENV["RUBYOPT"] if ENV["NIL_KILL_TRACE"] == "1" && ENV["RUBYOPT"] && !ENV["RUBYOPT"].empty?
  clean_env
end

if $PROGRAM_NAME == __FILE__ && ARGV.empty?
  $stderr.puts "Usage: ruby bc_run.rb <file.clear>"
  exit 1
end

if $PROGRAM_NAME == __FILE__
  ARGV.delete("--run")  # accepted but ignored (run is always the mode)
  # The register machine is the only VM. --vm= is accepted and ignored so
  # existing callers keep working.
  ARGV.reject! { |arg| arg == "--vm" || arg =~ /\A--vm=\w+\z/ }

  begin
    require_relative "register_bc_emitter"
    require "compiler/compiler_frontend"
    require "mir_lowering"
    require "mir_checker"
    require "compiler/module_importer"

    MiniVM::Register::OpcodeSpec.validate_vm_enum!
    MiniVM::Register::RegisterFileLimits.validate_vm_cht!

    project_root = File.expand_path("../../", __dir__)
    optimized = !ENV["BC_OPT"].nil? && ENV["BC_OPT"] != "0"
    runner_basename = optimized ? "vm_opt" : "vm"
    register_runner_path = File.join(__dir__, runner_basename)
    register_runner_template_src = File.join(__dir__, "vm.clear")
    register_packed_ops_file = File.join(__dir__, "_register_ops.rbc")
    register_consts_file = File.join(__dir__, "_register_consts.txt")
    register_lines_file = File.join(__dir__, "_register_lines.bin")
    register_columns_file = File.join(__dir__, "_register_columns.bin")
    # Debugger breakpoints file. One instruction-start IP per line.
    # Always read by the runner (an empty file disables the debugger
    # with zero overhead); written by the bc_run.rb path below when
    # `BC_PAUSE_ON=file:line` is set in the env.
    register_breakpoints_file = File.join(__dir__, "_register_breakpoints.txt")
    # Source path table: maps file_id -> CLEAR source path. Today only
    # one entry (the main file), so error messages render as
    # "<path>:<line>". Format: one path per line, file_id is the
    # 0-indexed line number. Future multi-file (module-imported)
    # attribution will append additional paths and stamp non-zero
    # file_ids on MIR statements.
    register_source_path_file = File.join(__dir__, "_register_source_paths.txt")
    # Names file is debug-only. Holds `entry_ip:kind:phys_idx:name`
    # per line, joining the emitter's virtual->name maps with the
    # allocator's virtual->physical mapping. Used by future debugger
    # work to render `total = X` instead of `r1 = X` in crash output.
    register_names_file = File.join(__dir__, "_register_names.txt")
    debug_mode = !ENV["BC_DEBUG"].nil? && ENV["BC_DEBUG"] != "0"

    # The cached register runner reads a fixed set of _register_* artifact
    # paths baked into vm_generated_*.clear. Parallel integration/fuzz runs can
    # otherwise overwrite or delete another runner's bytecode/source tables
    # mid-execution, surfacing as FileNotFound or mismatched breakpoints.
    artifact_lock_path = File.join(__dir__, "_register_artifacts.lock")
    $register_artifact_lock = File.open(artifact_lock_path, "w")
    $register_artifact_lock.flock(File::LOCK_EX)

    register_runner_stale = !File.exist?(register_runner_path) ||
                             File.mtime(register_runner_path) < File.mtime(register_runner_template_src)

    if register_runner_stale
      $stderr.puts "Building register vm runner (cached for subsequent tests)..."
      runner_src_text = File.read(register_runner_template_src)
      base = runner_src_text
      main_idx = runner_src_text.index(/^FN main\(\)/)
      base = runner_src_text[0...main_idx] if main_idx

      runner_main = "FN main() RETURNS !Void ->\n"
      runner_main += "    program = loadPackedRegisterProgram(\"#{register_packed_ops_file}\") OR_ELSE RAISE;\n"
      runner_main += "    consts = loadRegisterConsts(\"#{register_consts_file}\") OR_ELSE RAISE;\n"
      runner_main += "    sourceLines = loadRegisterSourceLines(\"#{register_lines_file}\") OR_ELSE RAISE;\n"
      runner_main += "    sourceColumns = loadRegisterSourceLines(\"#{register_columns_file}\") OR_ELSE RAISE;\n"
      runner_main += "    sourcePaths = loadRegisterSourcePaths(\"#{register_source_path_file}\") OR_ELSE RAISE;\n"
      runner_main += "    breakpoints = loadRegisterBreakpoints(\"#{register_breakpoints_file}\") OR_ELSE RAISE;\n"
      runner_main += "    varNames = loadRegisterVarNames(\"#{register_names_file}\") OR_ELSE RAISE;\n"
      runner_main += "    rootCaps: RegisterValue[]@list = List[];\n"
      runner_main += "    MUTABLE rootSharedCells: RegisterValue[]@list:shared:locked = List[];\n"
      runner_main += "    result = runRegisterBytecode(program.ops, program.opcodes, consts, sourceLines, sourceColumns, sourcePaths, breakpoints, varNames, 0_i64, rootCaps, &rootSharedCells) OR_ELSE RAISE;\n"
      runner_main += "    printRegisterResult(result) OR_ELSE RAISE;\n"
      runner_main += "    RETURN;\nEND\n"

      template_digest = Digest::SHA1.file(register_runner_template_src).hexdigest[0, 12]
      register_runner_src = File.join(__dir__, "vm_generated_#{template_digest}.clear")
      File.write(register_runner_src, base + runner_main)

      # `--stack-check` is the post-build verifier that parses
      # objdump and (a) errors when a function's stack frame
      # exceeds its tier budget, (b) auto-rebuilds with the
      # optimal tier when an upgrade is needed. We need it here
      # because runRegisterBytecode! is a giant stackful function
      # (~478 KB frame from iregs[512] / fregs[512] / sregs[256] /
      # 16 collections) and CLEAR's default Standard fiber stack
      # is 16 KB. Without stack-check the function silently
      # overflows into adjacent slab memory and the corruption
      # only surfaces at scheduler teardown as
      # `free(): invalid pointer`.
      #
      # NOTE: this should NOT be needed once vm.clear is moved to an
      # FSM-style dispatch (the giant locals become heap-resident
      # ctx fields). Today vm.clear is the one stackful task in the
      # tree; the rest of CLEAR runs FSM-compiled BG bodies that
      # don't carry function-frame stack pressure.
      build_args = ["build", "--use-c-allocator", "--stack-check"]
      build_args << "--optimized" if optimized
      build_args.concat([register_runner_src, "-o", register_runner_path])
      old_runner_mtime = File.exist?(register_runner_path) ? File.mtime(register_runner_path) : nil
      build_ok = run_clear_build(project_root, build_args)
      built_runner = File.exist?(register_runner_path) &&
                     (old_runner_mtime.nil? || File.mtime(register_runner_path) > old_runner_mtime)
      build_ok ||= built_runner
      File.delete(register_runner_src) if File.exist?(register_runner_src)
      unless build_ok
        $stderr.puts
        $stderr.puts "Failed to rebuild register VM runner from generated source #{register_runner_src}."
        $stderr.puts "Template source: #{register_runner_template_src}"
        exit 1
      end
    end

    source_file = File.expand_path(ARGV[0])
    source = File.read(source_file)
    source_dir = File.dirname(source_file)
    begin
      importer = ModuleImporter.new(base_dir: source_dir)
      fe_result = CompilerFrontend.compile(source, importer: importer, source_dir: source_dir)
      lowering = MIRLowering.new(input: MIRLoweringInput.new(
        struct_schemas: fe_result.struct_schemas,
        enum_schemas: fe_result.enum_schemas,
        union_schemas: fe_result.union_schemas,
        lifecycle_registry: fe_result.lifecycle_registry,
        fn_sigs: fe_result.fn_sigs,
        moved_guard_info: fe_result.moved_guard_info,
        importer: importer,
        source_dir: source_dir,
        target: :bc
      ))
      program = lowering.lower_program(fe_result.ast)
      mir_errors = MIRChecker.new.check_program!(program, strict: true)
      raise "MIR validation errors: #{mir_errors.first}" unless mir_errors.nil? || mir_errors.empty?

      emitter = RegisterBcEmitter.new(fe_result, source: source, importer: importer)
      bytecode = emitter.compile(program)
      File.binwrite(register_packed_ops_file, MiniVM::Register::OpcodeSpec.pack_ops(bytecode.ops).pack("C*"))
      File.write(register_consts_file, bytecode.consts.map { |c| emitter.serialize_const(c) }.join("\n"))
      # Source-line table: parallel to ops, packed as little-endian u32.
      # The runner consults this on error to print "vm.clear:LINE" instead
      # of "ip=N". Always-on: tiny (~4 bytes/op), zero runtime cost on
      # the success path.
      lines_blob = bytecode.source_lines.map { |l| [l.to_i].pack("V") }.join
      File.binwrite(register_lines_file, lines_blob)
      # Parallel column metadata: same shape (one little-endian u32 per
      # opcode/operand position). Visualizers and the debugger use the
      # column for byte-precise highlighting; the runner ignores it for
      # crash messages.
      cols = bytecode.source_columns || Array.new(bytecode.source_lines.length, 0)
      cols_blob = cols.map { |c| [c.to_i].pack("V") }.join
      File.binwrite(register_columns_file, cols_blob)
      # Source path table. Only the main source file today (file_id 0).
      # Multi-file programs that import modules will add their paths in
      # a follow-up; the format already supports it.
      File.write(register_source_path_file, "#{source_file}\n")
      # Breakpoints. `BC_PAUSE_ON=file:line[,file:line]*` translates each
      # location to an instruction-start IP using the source-line table
      # we just emitted. An empty result writes an empty file; the
      # runner sees no breakpoints and runs at full speed.
      bp_ips = []
      if (raw_pause_on = ENV["BC_PAUSE_ON"]) && !raw_pause_on.empty?
        raw_pause_on.split(",").each do |spec|
          # Format: `file:line` (file is informational today; matching is
          # by line only, since we have a single source file). Future
          # multi-file: lookup file_id from the path table.
          idx = spec.rindex(":")
          line = (idx ? spec[(idx + 1)..] : "").to_i
          next unless line > 0
          # First IP of the line only -- byebug-style "one pause per
          # line" semantics. Without this, every bytecode instruction
          # on the line re-fires the trap, so `:s` re-pauses on the
          # same source line and `:p NAME` shows "no variable" until
          # the binding's entry IP is reached.
          bytecode.source_lines.each_with_index do |source_line, ip|
            if source_line.to_i == line
              bp_ips << ip
              break
            end
          end
        end
      end
      File.write(register_breakpoints_file, bp_ips.uniq.join("\n") + (bp_ips.empty? ? "" : "\n"))
      # Names table: written when --debug is set OR_ELSE when any breakpoint
      # is requested via BC_PAUSE_ON (the REPL's `:p NAME` is useless
      # without it). Empty file in non-debug, non-paused runs keeps the
      # runner's `loadRegisterVarNames!` happy with zero artifact cost.
      pause_active = ENV["BC_PAUSE_ON"] && !ENV["BC_PAUSE_ON"].empty?
      if (debug_mode || pause_active) && bytecode.var_names
        # Format: <funcEntryIp>:<sourceLine>:<sourceColumn>:<endSourceLine>:<kind>:<phys>:<name>:<typeName>
        # One row per binding. Multiple rows can share `(kind, phys)`
        # because the linear-scan allocator reuses a physical register
        # across non-overlapping lifetimes. The runner picks the row
        # with the largest `sourceLine` strictly less than the current
        # pause line per `(kind, phys)` -- byebug's "visible after
        # assignment completes" semantic.
        # `sourceColumn` is the binding's column at decl. Used for
        # byte-precise highlighting in `:l`, `:bt`, and visualization.
        # `endSourceLine` is the last line where the binding is live
        # (the line before the next binding for the same `(kind, phys)`
        # slot, or `-1` meaning "until function return"). Used by
        # visualizers to draw lifetime bars and by `:info` to filter
        # out-of-scope bindings.
        # `typeName` is the user-facing CLEAR type ("Int64", "Float64",
        # "String", "Bool"). Empty string when the emitter didn't
        # resolve a type for this binding.
        names_lines = []
        bytecode.var_names.each do |fv|
          fv.bindings.each do |b|
            tn = (b.type_name || "").to_s
            els = (b.end_source_line || -1).to_s
            sc  = (b.source_column || 0).to_s
            names_lines << "#{fv.entry_ip}:#{b.source_line}:#{sc}:#{els}:#{b.kind}:#{b.virt}:#{b.name}:#{tn}"
          end
        end
        File.write(register_names_file, names_lines.join("\n") + (names_lines.empty? ? "" : "\n"))
      elsif File.exist?(register_names_file)
        File.delete(register_names_file)
      end

      # Inherit stdin so the in-process debugger REPL (registerDebugPause!
      # in vm.clear) can read commands from the user's terminal. With
      # popen2e+stdin.close the runner saw EOF immediately and the trap
      # arm spun forever on empty readLine results. Streaming stdout
      # line-by-line keeps tests' output deterministic; stderr is merged.
      pid = Process.spawn(jemalloc_env, register_runner_path, in: $stdin, out: $stdout, err: [:child, :out])
      _, status = Process.waitpid2(pid)
      exit(status.success? ? 0 : 1)
    rescue RegisterBcEmitter::Unsupported => e
      $stderr.puts "Register VM pending: #{e.message}"
      exit 2
    rescue => e
      $stderr.puts "Register VM error: #{e.message}"
      $stderr.puts e.backtrace.first(5).join("\n") if ENV["BC_DEBUG"]
      exit 1
    ensure
      unless ENV["BC_KEEP"]
        File.delete(register_packed_ops_file) if File.exist?(register_packed_ops_file)
        File.delete(register_consts_file) if File.exist?(register_consts_file)
        File.delete(register_lines_file) if File.exist?(register_lines_file)
        File.delete(register_columns_file) if File.exist?(register_columns_file)
        File.delete(register_names_file) if File.exist?(register_names_file)
        File.delete(register_source_path_file) if File.exist?(register_source_path_file)
        File.delete(register_breakpoints_file) if File.exist?(register_breakpoints_file)
      end
    end
  end

end
