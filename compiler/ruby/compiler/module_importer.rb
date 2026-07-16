# typed: strict
require "sorbet-runtime"

require "set"

class ModuleImportError < StandardError; end
class CircularDependencyError < ModuleImportError; end

# Orchestrates multi-file compilation with a shared module cache.
# Prevents circular dependencies and compiles each .clear file exactly once.
class ModuleImporter
    extend T::Sig

  CompiledModule = Struct.new(
    :ast,
    :global_scope,    # annotator's global Scope (for importing symbols)
    :transpiled_body, # the Zig body string for inlining
    :source_dir,      # absolute directory containing the source file
    :struct_schemas,  # transpiler's @struct_schemas for RC cleanup propagation
    :union_schemas,   # transpiler's @union_schemas for MATCH dispatch
    :enum_schemas,    # transpiler's @enum_schemas for MATCH dispatch
    :type_defs,       # Zig type definitions (structs/unions/enums) for file-scope emission
    :mir_items,       # full MIR items list, including FnDef bodies, for the bc emitter
    :type_items       # structural MIR type items for REQUIRE inlining
  )

  # First-party stdlib packages live under <repo>/stdlib/<name>/src/lib.clear
  # and are auto-resolvable as `REQUIRE "pkg:<name>"` without an explicit
  # --pkg flag. Computed from this file's location:
  # compiler/ruby/compiler/module_importer.rb -> ../../../stdlib.
  STDLIB_ROOT = T.let(File.expand_path('../../../stdlib', __dir__), String)

  sig { returns(T::Hash[T.untyped, T.untyped]) }
  attr_reader :module_cache

  sig { params(base_dir: String, pkg_paths: T::Hash[String, String], use_mir: T::Boolean, stdlib_root: String).void }
  def initialize(base_dir: Dir.pwd, pkg_paths: {}, use_mir: false, stdlib_root: STDLIB_ROOT)
    @base_dir     = T.let(File.expand_path(base_dir), String)
    @module_cache = T.let({}, T::Hash[T.untyped, T.untyped])  # abs_path => CompiledModule
    @compiling    = T.let(Set.new, T::Set[T.untyped])  # abs_paths currently being compiled (cycle detection)
    # pkg_paths: { "name" => "/abs/path/to/lib.clear" } -- registered package sources.
    @pkg_paths    = T.let(pkg_paths.transform_keys(&:to_s), T::Hash[T.untyped, T.untyped])
    @stdlib_root  = T.let(stdlib_root, String)
  end

  # Compile a .clear package by name and return a CompiledModule.
  # Resolution order:
  #   1. Explicitly registered packages (via --pkg flag)
  #   2. First-party stdlib at <stdlib_root>/<name>/src/lib.clear
  #
  # @param pkg_name [String] Package name (e.g. "math", "testing")
  sig { params(pkg_name: String, caller_dir: String).returns(T.nilable(ModuleImporter::CompiledModule)) }
  def compile_package(pkg_name, caller_dir: @base_dir)
    path = @pkg_paths[pkg_name.to_s] || resolve_stdlib_package(pkg_name)
    unless path
      raise ModuleImportError, "REQUIRE error: unknown package '#{pkg_name}'. " \
            "Register it with --pkg #{pkg_name}=/path/to/lib.clear " \
            "or place it under #{@stdlib_root}/#{pkg_name}/src/lib.clear"
    end
    compile_file(path, caller_dir: File.dirname(File.expand_path(path)))
  end

  sig { params(pkg_name: String).returns(T.nilable(String)) }
  def resolve_stdlib_package(pkg_name)
    return nil unless @stdlib_root
    candidate = File.join(@stdlib_root, pkg_name.to_s, 'src', 'lib.clear')
    File.exist?(candidate) ? candidate : nil
  end

  # True if `pkg_name` resolves to a first-party stdlib package
  # (lives under `<stdlib_root>/<name>/src/lib.clear`) rather than a
  # user-registered package. The distinction matters at lowering
  # time: stdlib packages must be inlined into single-binary builds
  # (no separate .zig file is produced for them), whereas
  # explicitly-registered packages are emitted as `@import("name.zig")`
  # so an outer `build.zig` can orchestrate per-package compilation.
  sig { params(pkg_name: String).returns(T.nilable(T::Boolean)) }
  def stdlib_package?(pkg_name)
    !@pkg_paths.key?(pkg_name.to_s) && !resolve_stdlib_package(pkg_name).nil?
  end

  # Compile a .clear file and return a CompiledModule (cached after first call).
  #
  # @param path [String] Relative or absolute path to the .clear file
  # @param caller_dir [String] Directory of the file issuing the REQUIRE
  sig { params(path: String, caller_dir: String).returns(T.nilable(ModuleImporter::CompiledModule)) }
  def compile_file(path, caller_dir: @base_dir)
    abs_path = File.expand_path(path, caller_dir)

    return @module_cache[abs_path] if @module_cache.key?(abs_path)

    if @compiling.include?(abs_path)
      cycle = @compiling.to_a.map { |p| File.basename(p) }.join(" -> ")
      raise CircularDependencyError, "Circular dependency detected: #{cycle} -> #{File.basename(path)}"
    end

    raise ModuleImportError, "REQUIRE error: file not found: #{abs_path}" unless File.exist?(abs_path)

    @compiling.add(abs_path)
    begin
      source     = File.read(abs_path)
      source_dir = File.dirname(abs_path)

      # STRICT-imports boundary (gradual-typing.md §7): imported modules
      # must export concrete types in their public surface. Force the
      # parser into strict mode (gradual=false) for the duration of the
      # imported module's parse so `--gradual` from the top-level build
      # never propagates across module boundaries. Explicit `Auto` in
      # source still tokenizes; the post-parse check below catches it.
      saved_gradual = ClearParser.gradual_mode
      ClearParser.gradual_mode = false
      ast = begin
        budget = FrontendResourceBudget.new
        tokens = Lexer.new(source, file: abs_path, budget: budget).tokenize
        ClearParser.new(tokens, source, budget: budget).parse
      ensure
        ClearParser.gradual_mode = saved_gradual
      end

      reject_auto_in_public_signatures!(ast, abs_path)

      annotator = SemanticAnnotator.new(importer: self, source_dir: source_dir, source_code: source)
      annotator.annotate!(ast)

      mod = compile_module_mir(ast, annotator, source_dir)

      @module_cache[abs_path] = mod
      mod
    ensure
      @compiling.delete(abs_path)
    end
  end

  # STRICT-imports check (M1.5). Imported modules cannot expose
  # `Auto` in any function's public signature — params or return —
  # because cross-module inference is intentionally not supported
  # (gradual-typing.md §7). The importer rejects with a diagnostic
  # that points the user at running `clear fix --apply` on the
  # imported module before re-importing.
  sig { params(ast: AST::Program, abs_path: String).void }
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
        offending << "param '#{p.name}'" if auto_type?(p.type)
      end
      offending << "return type" if auto_type?(stmt.return_type)
      next if offending.empty?

      msg = "Imported function '#{stmt.name}' from module '#{rel_path}' has " \
            "`Auto` in its public signature (#{offending.join(', ')}). " \
            "Imported modules must export concrete types — cross-module " \
            "inference is not supported. Compile '#{rel_path}' WITHOUT " \
            "`--gradual` (or with each Auto resolved via " \
            "`clear fix --apply`), then re-import."
      raise CompilerError.new(stmt.token, msg, ast.respond_to?(:source_code) ? T.unsafe(ast).source_code : nil)
    end
  end

  sig { params(t: Type).returns(T::Boolean) }
  def auto_type?(t)
    t.is_a?(Type) && t.auto?
  end

  private

  sig { params(ast: AST::Program, annotator: Annotator::Phases::TypeAnalysisSession, source_dir: String).returns(ModuleImporter::CompiledModule) }
  def compile_module_mir(ast, annotator, source_dir)
    require_relative "../mir/mir"
    require_relative "../mir/mir_lowering"
    require_relative "../backends/mir_emitter"
    require_relative "../mir/hoist"
    require_relative "../semantic/pass_state"
    require_relative "../mir/pre_mir_type_check"
    require_relative "../mir/rewriters/pipeline_rewriter"
    require_relative "../mir/rewriters/string_concat_rewriter"
    require_relative "compiler_frontend"

    PipelineRewriter.new(annotator).rewrite!(ast)
    MIRPassState.for!(ast).mark!(:pipeline_rewritten)
    StringConcatRewriter.new.rewrite!(ast)
    MIRPassState.for!(ast).mark!(:string_concat_rewritten)
    schema_lookup = ->(name) { annotator.lookup_type_schema(name) }
    hoist_result = Hoist.apply!(ast, schema_lookup: schema_lookup)

    # Run MIRPass on the module AST (needed for cleanup stamps in function bodies).
    PreMirTypeCheck.verify!(ast)
    fn_nodes = T.let({}, T::Hash[String, AST::FunctionDef])
    ast.statements.each { |s| fn_nodes[s.name] = s if s.is_a?(AST::FunctionDef) }
    mir_pass = MIRPass.new(
      fn_nodes: fn_nodes,
      schema_lookup: schema_lookup,
      body_summaries: T.must(annotator.semantic_index).body_summaries,
      hoist_bindings: hoist_result.bindings_by_function
    )
    mir_pass.transform!(ast)
    sync_global_scope_function_signatures!(ast, annotator)

    # Collect schemas
    struct_schemas = T.let({}, T::Hash[Symbol, Schemas::StructSchema])
    enum_schemas = T.let({}, T::Hash[Symbol, MIRLoweringSchemas::EnumVariants])
    union_schemas = T.let({}, T::Hash[Symbol, Schemas::UnionSchema])
    ast.statements.each do |stmt|
      case stmt
      when AST::StructDef then struct_schemas[stmt.name.to_sym] = Schemas::StructSchema.new(fields: stmt.field_decls)
      when AST::EnumDef   then enum_schemas[stmt.name.to_sym] = stmt.variants
      when AST::UnionDef  then union_schemas[stmt.name.to_sym] = Schemas::UnionSchema.new(variants: stmt.variants)
      end
    end

    fn_sigs = T.let({}, T::Hash[String, FunctionSignature])
    ast.statements.each do |stmt|
      next unless stmt.is_a?(AST::FunctionDef)
      fn_sigs[stmt.name] = FunctionSignature.from_function_def(stmt)
    end

    moved_guard_info = T.let({}, MIRLoweringInput::MovedGuardInfo)
    fn_nodes.each { |name, fn| moved_guard_info[name] = fn.moved_guard_info if fn.moved_guard_info }

    lowering = MIRLowering.new(input: MIRLoweringInput.new(
      struct_schemas: struct_schemas,
      enum_schemas: enum_schemas,
      union_schemas: union_schemas,
      fn_sigs: fn_sigs,
      moved_guard_info: moved_guard_info,
      importer: self,
      source_dir: source_dir
    ))

    result = lowering.lower_module(ast)
    emitter = MIREmitter.new
    zig_body = result[:items].flatten.filter_map { |item| emitter.emit(item) }.join("\n\n")
    type_defs = result[:type_items].flatten.filter_map { |item| emitter.emit(item) }.join("\n\n")

    CompiledModule.new(
      ast,
      annotator.semantic_root_scope,
      zig_body,
      source_dir,
      struct_schemas,
      union_schemas,
      enum_schemas,
      type_defs,
      result[:items],
      result[:type_items]
    )
  end

  sig { params(ast: AST::Program, annotator: Annotator::Phases::TypeAnalysisSession).void }
  def sync_global_scope_function_signatures!(ast, annotator)
    ast.statements.each do |stmt|
      next unless stmt.is_a?(AST::FunctionDef)
      entry = annotator.semantic_root_scope.resolve_entry(stmt.name)
      sig = entry&.fn_signature
      next unless sig
      FunctionSignature.sync_signature_from_function_def!(sig, stmt)
    end
    nil
  end
  private :auto_type?
  private :reject_auto_in_public_signatures!
  private :resolve_stdlib_package

end
