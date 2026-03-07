require "set"

# Orchestrates multi-file compilation with a shared module cache.
# Prevents circular dependencies and compiles each .cht file exactly once.
class ModuleImporter
  CompiledModule = Struct.new(
    :ast,
    :global_scope,   # annotator's global Scope (for importing symbols)
    :transpiled_body, # the Zig body string for inlining
    :source_dir,     # absolute directory containing the source file
    :struct_schemas  # transpiler's @struct_schemas for RC cleanup propagation
  )

  def initialize(base_dir: Dir.pwd, pkg_paths: {})
    @base_dir     = File.expand_path(base_dir)
    @module_cache = {}  # abs_path => CompiledModule
    @compiling    = Set.new  # abs_paths currently being compiled (cycle detection)
    # pkg_paths: { "name" => "/abs/path/to/lib.cht" } — registered package sources.
    @pkg_paths    = pkg_paths.transform_keys(&:to_s)
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
      raise "Circular dependency: '#{File.basename(path)}' is already being compiled"
    end

    raise "REQUIRE error: file not found: #{abs_path}" unless File.exist?(abs_path)

    @compiling.add(abs_path)

    source     = File.read(abs_path)
    source_dir = File.dirname(abs_path)

    tokens = Lexer.new(source).tokenize
    ast    = Parser.new(tokens, source).parse

    annotator = SemanticAnnotator.new(importer: self, source_dir: source_dir)
    annotator.annotate!(ast)

    transpiler = ZigTranspiler.new(importer: self, source_dir: source_dir)
    zig_body   = transpiler.transpile_module(ast)

    mod = CompiledModule.new(
      ast,
      annotator.scope_stack.first,
      zig_body,
      source_dir,
      transpiler.struct_schemas
    )

    @module_cache[abs_path] = mod
    @compiling.delete(abs_path)
    mod
  end
end
