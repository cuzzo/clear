# typed: true
require "set"

class CircularDependencyError < StandardError; end

# Orchestrates multi-file compilation with a shared module cache.
# Prevents circular dependencies and compiles each .cht file exactly once.
class ModuleImporter
  CompiledModule = Struct.new(
    :ast,
    :global_scope,    # annotator's global Scope (for importing symbols)
    :transpiled_body, # the Zig body string for inlining
    :source_dir,      # absolute directory containing the source file
    :struct_schemas,  # transpiler's @struct_schemas for RC cleanup propagation
    :union_schemas,   # transpiler's @union_schemas for MATCH dispatch
    :enum_schemas,    # transpiler's @enum_schemas for MATCH dispatch
    :type_defs        # Zig type definitions (structs/unions/enums) for file-scope emission
  )

  # First-party stdlib packages live under <repo>/stdlib/<name>/src/lib.cht
  # and are auto-resolvable as `REQUIRE "pkg:<name>"` without an explicit
  # --pkg flag. Computed from this file's location: src/backends/importer.rb
  # → ../../stdlib relative to __FILE__.
  STDLIB_ROOT = File.expand_path('../../stdlib', __dir__)

  def initialize(base_dir: Dir.pwd, pkg_paths: {}, use_mir: false, stdlib_root: STDLIB_ROOT)
    @base_dir     = File.expand_path(base_dir)
    @module_cache = {}  # abs_path => CompiledModule
    @compiling    = Set.new  # abs_paths currently being compiled (cycle detection)
    # pkg_paths: { "name" => "/abs/path/to/lib.cht" } -- registered package sources.
    @pkg_paths    = pkg_paths.transform_keys(&:to_s)
    @stdlib_root  = stdlib_root
  end

  # Compile a .cht package by name and return a CompiledModule.
  # Resolution order:
  #   1. Explicitly registered packages (via --pkg flag)
  #   2. First-party stdlib at <stdlib_root>/<name>/src/lib.cht
  #
  # @param pkg_name [String] Package name (e.g. "math", "testing")
  def compile_package(pkg_name, caller_dir: @base_dir)
    path = @pkg_paths[pkg_name.to_s] || resolve_stdlib_package(pkg_name)
    unless path
      raise "REQUIRE error: unknown package '#{pkg_name}'. " \
            "Register it with --pkg #{pkg_name}=/path/to/lib.cht " \
            "or place it under #{@stdlib_root}/#{pkg_name}/src/lib.cht"
    end
    compile_file(path, caller_dir: File.dirname(File.expand_path(path)))
  end

  def resolve_stdlib_package(pkg_name)
    return nil unless @stdlib_root
    candidate = File.join(@stdlib_root, pkg_name.to_s, 'src', 'lib.cht')
    File.exist?(candidate) ? candidate : nil
  end

  # True if `pkg_name` resolves to a first-party stdlib package
  # (lives under `<stdlib_root>/<name>/src/lib.cht`) rather than a
  # user-registered package. The distinction matters at lowering
  # time: stdlib packages must be inlined into single-binary builds
  # (no separate .zig file is produced for them), whereas
  # explicitly-registered packages are emitted as `@import("name.zig")`
  # so an outer `build.zig` can orchestrate per-package compilation.
  def stdlib_package?(pkg_name)
    !@pkg_paths.key?(pkg_name.to_s) && !resolve_stdlib_package(pkg_name).nil?
  end

  # Compile a .cht file and return a CompiledModule (cached after first call).
  #
  # @param path [String] Relative or absolute path to the .cht file
  # @param caller_dir [String] Directory of the file issuing the REQUIRE
  def compile_file(path, caller_dir: @base_dir)
    abs_path = File.expand_path(path, caller_dir)

    return @module_cache[abs_path] if @module_cache.key?(abs_path)

    if @compiling.include?(abs_path)
      cycle = @compiling.to_a.map { |p| File.basename(p) }.join(" -> ")
      raise CircularDependencyError, "Circular dependency detected: #{cycle} -> #{File.basename(path)}"
    end

    raise "REQUIRE error: file not found: #{abs_path}" unless File.exist?(abs_path)

    @compiling.add(abs_path)

    source     = File.read(abs_path)
    source_dir = File.dirname(abs_path)

    # STRICT-imports boundary (gradual-typing.md §7): imported modules
    # must export concrete types in their public surface. Force the
    # parser into strict mode (gradual=false) for the duration of the
    # imported module's parse so `--gradual` from the top-level build
    # never propagates across module boundaries. Explicit `Auto` in
    # source still tokenizes; the post-parse check below catches it.
    saved_gradual = Parser.gradual_mode
    Parser.gradual_mode = false
    begin
      tokens = Lexer.new(source).tokenize
      ast    = Parser.new(tokens, source).parse
    ensure
      Parser.gradual_mode = saved_gradual
    end

    reject_auto_in_public_signatures!(ast, abs_path)

    annotator = SemanticAnnotator.new(importer: self, source_dir: source_dir)
    annotator.annotate!(ast)

    mod = compile_module_mir(ast, annotator, source_dir)

    @module_cache[abs_path] = mod
    @compiling.delete(abs_path)
    mod
  end

  # STRICT-imports check (M1.5). Imported modules cannot expose
  # `Auto` in any function's public signature — params or return —
  # because cross-module inference is intentionally not supported
  # (gradual-typing.md §7). The importer rejects with a diagnostic
  # that points the user at running `clear fix --apply` on the
  # imported module before re-importing.
  def reject_auto_in_public_signatures!(ast, abs_path)
    rel_path = File.basename(abs_path)
    ast.statements.each do |stmt|
      next unless stmt.is_a?(AST::FunctionDef)
      vis = stmt.visibility || :package
      # `:private` functions are not visible across modules and may
      # keep Auto. Public surface is `:pub` and `:package`.
      next if vis == :private

      offending = []
      stmt.params.each do |p|
        offending << "param '#{p[:name]}'" if auto_type?(p[:type])
      end
      offending << "return type" if auto_type?(stmt.return_type)
      next if offending.empty?

      msg = "Imported function '#{stmt.name}' from module '#{rel_path}' has " \
            "`Auto` in its public signature (#{offending.join(', ')}). " \
            "Imported modules must export concrete types — cross-module " \
            "inference is not supported. Compile '#{rel_path}' WITHOUT " \
            "`--gradual` (or with each Auto resolved via " \
            "`clear fix --apply`), then re-import."
      raise CompilerError.new(stmt.token, msg, ast.respond_to?(:source_code) ? ast.source_code : nil)
    end
  end

  def auto_type?(t)
    t.is_a?(Type) && t.auto?
  end

  private

  def compile_module_mir(ast, annotator, source_dir)
    require_relative "../mir/mir"
    require_relative "../mir/mir_lowering"
    require_relative "../mir/mir_emitter"
    require_relative "compiler_frontend"

    # Run MIRPass on the module AST (needed for cleanup stamps in function bodies)
    schema_lookup = ->(name) { annotator.lookup_type_schema(name) }
    fn_nodes = {}
    ast.statements.each { |s| fn_nodes[s.name] = s if s.is_a?(AST::FunctionDef) }
    mir_pass = MIRPass.new(fn_nodes: fn_nodes, schema_lookup: schema_lookup)
    mir_pass.transform!(ast)

    # Collect schemas
    struct_schemas = {}
    enum_schemas = {}
    union_schemas = {}
    ast.statements.each do |stmt|
      case stmt
      when AST::StructDef then struct_schemas[stmt.name.to_sym] = Schemas::StructSchema.new(fields: stmt.fields)
      when AST::EnumDef   then enum_schemas[stmt.name.to_sym] = stmt.variants
      when AST::UnionDef  then union_schemas[stmt.name.to_sym] = Schemas::UnionSchema.new(variants: stmt.variants)
      end
    end

    fn_sigs = {}
    ast.statements.each do |stmt|
      next unless stmt.is_a?(AST::FunctionDef)
      sig = stmt.full_type
      if sig.is_a?(FunctionSignature)
        fn_sigs[stmt.name] = sig
      else
        fs = FunctionSignature.new(params: [], return_type: :Any)
        fs.needs_rt = stmt.needs_rt
        fs.can_fail = stmt.can_fail
        fs.effects = stmt.effects
        fn_sigs[stmt.name] = fs
      end
    end

    moved_guard_info = {}
    fn_nodes.each { |name, fn| moved_guard_info[name] = fn.moved_guard_info if fn.moved_guard_info }

    lowering = MIRLowering.new(
      struct_schemas: struct_schemas,
      enum_schemas: enum_schemas,
      union_schemas: union_schemas,
      fn_sigs: fn_sigs,
      moved_guard_info: moved_guard_info,
      importer: self,
      source_dir: source_dir
    )

    result = lowering.lower_module(ast)
    emitter = MIREmitter.new
    zig_body = result[:items].flatten.filter_map { |item| emitter.emit(item) }.join("\n\n")
    type_defs = result[:type_items].flatten.filter_map { |item| emitter.emit(item) }.join("\n\n")

    CompiledModule.new(
      ast,
      annotator.scope_stack.first,
      zig_body,
      source_dir,
      struct_schemas,
      union_schemas,
      enum_schemas,
      type_defs
    )
  end
end
