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

  def initialize(base_dir: Dir.pwd, pkg_paths: {}, use_mir: false)
    @base_dir     = File.expand_path(base_dir)
    @module_cache = {}  # abs_path => CompiledModule
    @compiling    = Set.new  # abs_paths currently being compiled (cycle detection)
    # pkg_paths: { "name" => "/abs/path/to/lib.cht" } -- registered package sources.
    @pkg_paths    = pkg_paths.transform_keys(&:to_s)
    @use_mir      = use_mir
  end

  # Compile a .cht package by name and return a CompiledModule.
  # Looks up the source path from @pkg_paths.
  #
  # @param pkg_name [String] Package name (e.g. "math")
  def compile_package(pkg_name, caller_dir: @base_dir)
    path = @pkg_paths[pkg_name.to_s]
    raise "REQUIRE error: unknown package '#{pkg_name}'. " \
          "Register it with --pkg #{pkg_name}=/path/to/lib.cht" unless path
    compile_file(path, caller_dir: File.dirname(File.expand_path(path)))
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

    tokens = Lexer.new(source).tokenize
    ast    = Parser.new(tokens, source).parse

    annotator = SemanticAnnotator.new(importer: self, source_dir: source_dir)
    annotator.annotate!(ast)

    mod = if @use_mir
      compile_module_mir(ast, annotator, source_dir)
    else
      compile_module_legacy(ast, annotator, source_dir)
    end

    @module_cache[abs_path] = mod
    @compiling.delete(abs_path)
    mod
  end

  private

  def compile_module_legacy(ast, annotator, source_dir)
    transpiler = ZigTranspiler.new(importer: self, source_dir: source_dir)
    zig_body   = transpiler.transpile_module(ast)

    CompiledModule.new(
      ast,
      annotator.scope_stack.first,
      zig_body,
      source_dir,
      transpiler.struct_schemas,
      transpiler.union_schemas,
      transpiler.enum_schemas,
      transpiler.module_type_defs
    )
  end

  def compile_module_mir(ast, annotator, source_dir)
    require_relative "mir"
    require_relative "mir_lowering"
    require_relative "mir_emitter"
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
      when AST::StructDef then struct_schemas[stmt.name.to_sym] = stmt.fields
      when AST::EnumDef   then enum_schemas[stmt.name.to_sym] = stmt.variants
      when AST::UnionDef  then union_schemas[stmt.name.to_sym] = stmt.variants
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
