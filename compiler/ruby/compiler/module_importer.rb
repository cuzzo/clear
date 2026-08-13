# typed: strict
require "sorbet-runtime"

require "set"
require_relative "package_source"
require_relative "../incremental/module_cache"

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
    :type_items,      # structural MIR type items for REQUIRE inlining
    :lifecycle_registry # immutable annotation lifecycle facts for re-lowering
  )

  # First-party stdlib packages live under <repo>/stdlib/<name>/src/lib.clear
  # and are auto-resolvable as `REQUIRE "pkg:<name>"` without an explicit
  # --pkg flag. Computed from this file's location:
  # compiler/ruby/compiler/module_importer.rb -> ../../../stdlib.
  STDLIB_ROOT = T.let(File.expand_path('../../../stdlib', __dir__), String)

  sig { returns(T::Hash[T.untyped, T.untyped]) }
  attr_reader :module_cache

  sig do
    params(
      base_dir: String,
      pkg_paths: T::Hash[String, String],
      use_mir: T::Boolean,
      stdlib_root: String,
      inline_packages: T::Set[String],
    ).void
  end
  def initialize(base_dir: Dir.pwd, pkg_paths: {}, use_mir: false, stdlib_root: STDLIB_ROOT,
                 inline_packages: Set.new)
    @base_dir     = T.let(File.expand_path(base_dir), String)
    @module_cache = T.let({}, T::Hash[T.untyped, T.untyped])  # abs_path => CompiledModule
    @compiling    = T.let(Set.new, T::Set[T.untyped])  # abs_paths currently being compiled (cycle detection)
    # pkg_paths: { "name" => "/abs/path/to/lib.clear" } -- registered package
    # sources. A comma-separated value registers a MULTI-FILE package: all
    # listed files compile together as ONE unit (Go model — the acyclic
    # import rule applies between packages, not between a package's files).
    @pkg_paths    = T.let(pkg_paths.transform_keys(&:to_s), T::Hash[T.untyped, T.untyped])
    @inline_packages = T.let(inline_packages.map(&:to_s).to_set, T::Set[String])
    @stdlib_root  = T.let(stdlib_root, String)
    # abs member file -> owning multi-file package name. Any compile of a
    # member file (directly or via its own single-file pkg name) is aliased
    # to the whole package so the unit is never split.
    @package_members = T.let({}, T::Hash[String, String])
    # Cross-run store for compiled units. Nil unless `clear` asked for one.
    @unit_cache = T.let(Incremental::ModuleCache.from_env, T.nilable(Incremental::ModuleCache))
    @pkg_paths.each do |name, value|
      next unless value.to_s.include?(",")

      value.to_s.split(",").each do |member|
        @package_members[File.expand_path(member.strip)] = name.to_s
      end
    end
  end

  # Compile a .clear package by name and return a CompiledModule.
  # Resolution order:
  #   1. Explicitly registered packages (via --pkg flag)
  #   2. First-party stdlib at <stdlib_root>/<name>/src/lib.clear
  #
  # @param pkg_name [String] Package name (e.g. "math", "testing")
  # The package that actually owns a required name. A single-file package whose
  # file belongs to a multi-file package IS that package -- and only the owner
  # is built, so the emitted Zig must import (and alias through) the owner.
  sig { params(pkg_name: String).returns(String) }
  def owning_package_name(pkg_name)
    path = @pkg_paths[pkg_name.to_s]
    return pkg_name.to_s if path.nil? || path.to_s.include?(",")

    @package_members[File.expand_path(path.to_s)] || pkg_name.to_s
  end

  sig { params(pkg_name: String, caller_dir: String).returns(T.nilable(ModuleImporter::CompiledModule)) }
  def compile_package(pkg_name, caller_dir: @base_dir)
    path = @pkg_paths[pkg_name.to_s] || resolve_stdlib_package(pkg_name)
    unless path
      raise ModuleImportError, "REQUIRE error: unknown package '#{pkg_name}'. " \
            "Register it with --pkg #{pkg_name}=/path/to/lib.clear " \
            "or place it under #{@stdlib_root}/#{pkg_name}/src/lib.clear"
    end
    return compile_package_group(pkg_name.to_s, path.to_s.split(",").map(&:strip)) if path.to_s.include?(",")

    # A single-file package whose file belongs to a multi-file package
    # compiles as that whole package — a unit is never split.
    owner = @package_members[File.expand_path(path)]
    return compile_package(owner, caller_dir: caller_dir) if owner && owner != pkg_name.to_s

    compile_file(path, caller_dir: File.dirname(File.expand_path(path)))
  end

  # Compile a multi-file package: all members merged into ONE compilation
  # unit (source-level, sibling REQUIREs dropped, externals deduplicated).
  # Cycles BETWEEN packages are still rejected by the ordinary @compiling
  # guard; references between members never re-enter the importer at all.
  sig { params(pkg_name: String, members: T::Array[String]).returns(T.nilable(ModuleImporter::CompiledModule)) }
  def compile_package_group(pkg_name, members)
    cache_key = "pkg-group:#{pkg_name}"
    if @module_cache.key?(cache_key)
      @unit_cache&.reuse(cache_key)
      return @module_cache[cache_key]
    end

    if @compiling.include?(cache_key)
      cycle = @compiling.to_a.map { |p| File.basename(p.to_s) }.join(" -> ")
      raise CircularDependencyError, "Circular dependency detected: #{cycle} -> pkg:#{pkg_name}"
    end

    members.each do |member|
      abs = File.expand_path(member)
      raise ModuleImportError, "REQUIRE error: package '#{pkg_name}' member not found: #{abs}" unless File.exist?(abs)
    end

    @compiling.add(cache_key)
    begin
      mod = with_unit_cache(cache_key, members) do
        merged = PackageSource.merge(members, resolve_pkg: ->(name) { @pkg_paths[name] || resolve_stdlib_package(name) })
        source_dir = File.dirname(T.must(merged.member_paths.first))

        saved_gradual = ClearParser.gradual_mode
        ClearParser.gradual_mode = false
        ast = begin
          budget = FrontendResourceBudget.new
          tokens = Lexer.new(merged.source, file: "pkg:#{pkg_name}", budget: budget).tokenize
          ClearParser.new(tokens, merged.source, budget: budget).parse
        ensure
          ClearParser.gradual_mode = saved_gradual
        end

        reject_auto_in_public_signatures!(ast, "pkg:#{pkg_name}")

        annotator = SemanticAnnotator.new(importer: self, source_dir: source_dir, source_code: merged.source)
        annotator.annotate!(ast)

        compile_module_mir(ast, annotator, source_dir)
      end

      @module_cache[cache_key] = mod
      mod
    ensure
      @compiling.delete(cache_key)
    end
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
    return true if @inline_packages.include?(pkg_name.to_s)

    !@pkg_paths.key?(pkg_name.to_s) && !resolve_stdlib_package(pkg_name).nil?
  end

  # Compile a .clear file and return a CompiledModule (cached after first call).
  #
  # @param path [String] Relative or absolute path to the .clear file
  # @param caller_dir [String] Directory of the file issuing the REQUIRE
  sig { params(path: String, caller_dir: String).returns(T.nilable(ModuleImporter::CompiledModule)) }
  def compile_file(path, caller_dir: @base_dir)
    abs_path = File.expand_path(path, caller_dir)

    # A member of a multi-file package always compiles as the whole package.
    owner = @package_members[abs_path]
    return compile_package(owner, caller_dir: caller_dir) if owner

    if @module_cache.key?(abs_path)
      @unit_cache&.reuse(abs_path)
      return @module_cache[abs_path]
    end

    if @compiling.include?(abs_path)
      cycle = @compiling.to_a.map { |p| File.basename(p) }.join(" -> ")
      raise CircularDependencyError, "Circular dependency detected: #{cycle} -> #{File.basename(path)}"
    end

    raise ModuleImportError, "REQUIRE error: file not found: #{abs_path}" unless File.exist?(abs_path)

    @compiling.add(abs_path)
    begin
      mod = with_unit_cache(abs_path, [abs_path]) do
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

        compile_module_mir(ast, annotator, source_dir)
      end

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

  # Route one compilation unit through the cross-run unit cache when one is
  # configured. Every REQUIRE the block issues re-enters the importer, so the
  # cache sees the unit's transitive source set without a second dependency scan.
  sig do
    params(unit_key: String, member_paths: T::Array[String], block: T.proc.returns(ModuleImporter::CompiledModule))
      .returns(ModuleImporter::CompiledModule)
  end
  def with_unit_cache(unit_key, member_paths, &block)
    cache = @unit_cache
    return block.call unless cache

    cache.fetch(unit_key, member_paths, &block)
  end

  sig { params(ast: AST::Program, annotator: SemanticAnnotator, source_dir: String).returns(ModuleImporter::CompiledModule) }
  def compile_module_mir(ast, annotator, source_dir)
    fn_nodes = prepare_module_mir!(ast, annotator)
    schema_lookup = ->(name) { annotator.lookup_type_schema(name) }
    lifecycle_registry = T.must(annotator.annotation_products.typed_program).lifecycle_registry

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

    fn_sigs = FunctionSignature.lowering_signatures(ast, annotator.semantic_root_scope)

    moved_guard_info = T.let({}, MIRLoweringInput::MovedGuardInfo)
    fn_nodes.each { |name, fn| moved_guard_info[name] = fn.moved_guard_info if fn.moved_guard_info }

    lowering = MIRLowering.new(input: MIRLoweringInput.new(
      struct_schemas: struct_schemas,
      enum_schemas: enum_schemas,
      union_schemas: union_schemas,
      schema_lookup: schema_lookup,
      lifecycle_registry: lifecycle_registry,
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
      result[:type_items],
      lifecycle_registry
    )
  end

  sig { params(ast: AST::Program, annotator: SemanticAnnotator).returns(T::Hash[String, AST::FunctionDef]) }
  def prepare_module_mir!(ast, annotator)
    require_relative "../mir/mir"
    require_relative "../mir/mir_lowering"
    require_relative "../backends/mir_emitter"
    require_relative "../mir/hoist"
    require_relative "../semantic/pass_state"
    require_relative "../mir/pre_mir_type_check"
    require_relative "../mir/rewriters/pipeline_rewriter"
    require_relative "../mir/rewriters/string_concat_rewriter"
    require_relative "compiler_frontend"

    state = MIRPassState.for!(ast)
    fn_nodes = T.let({}, T::Hash[String, AST::FunctionDef])
    ast.statements.each { |stmt| fn_nodes[stmt.name] = stmt if stmt.is_a?(AST::FunctionDef) }
    return fn_nodes if state.completed.include?(:mir_pass_complete)

    PipelineRewriter.new(annotator).rewrite!(ast)
    state.mark!(:pipeline_rewritten)
    StringConcatRewriter.new.rewrite!(ast)
    state.mark!(:string_concat_rewritten)
    schema_lookup = ->(name) { annotator.lookup_type_schema(name) }
    hoist_result = Hoist.apply!(ast, schema_lookup: schema_lookup)

    # Run MIRPass on the module AST (needed for cleanup stamps in function bodies).
    PreMirTypeCheck.verify!(ast)
    mir_pass = MIRPass.new(
      fn_nodes: fn_nodes,
      schema_lookup: schema_lookup,
      lifecycle_registry: T.must(annotator.annotation_products.typed_program).lifecycle_registry,
      body_summaries: T.must(annotator.semantic_index).body_summaries,
      hoist_bindings: hoist_result.bindings_by_function
    )
    mir_pass.transform!(ast)
    sync_global_scope_function_signatures!(ast, annotator)
    fn_nodes
  end

  sig { params(ast: AST::Program, annotator: SemanticAnnotator).void }
  def sync_global_scope_function_signatures!(ast, annotator)
    ast.statements.each do |stmt|
      next unless stmt.is_a?(AST::FunctionDef)
      entry = annotator.semantic_root_scope.resolve_entry(stmt.name)
      sig = entry&.fn_signature
      next unless sig
      sig.sync_from_function_def!(stmt)
    end
    nil
  end
  private :auto_type?
  private :reject_auto_in_public_signatures!
  private :resolve_stdlib_package

end
