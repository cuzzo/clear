require "set"

# Orchestrates multi-file compilation with a shared module cache.
# Prevents circular dependencies and compiles each .cht file exactly once.
class ModuleCompiler
  CompiledModule = Struct.new(
    :ast,
    :global_scope,   # annotator's global Scope (for importing symbols)
    :transpiled_body, # the Zig body string for inlining
    :source_dir,     # absolute directory containing the source file
    :struct_schemas  # transpiler's @struct_schemas for RC cleanup propagation
  )

  def initialize(base_dir: Dir.pwd)
    @base_dir = File.expand_path(base_dir)
    @module_cache = {}  # abs_path => CompiledModule
    @compiling    = Set.new  # abs_paths currently being compiled (cycle detection)
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

    annotator = SemanticAnnotator.new(compiler: self, source_dir: source_dir)
    annotator.annotate!(ast)

    transpiler = ZigTranspiler.new(compiler: self, source_dir: source_dir)
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
