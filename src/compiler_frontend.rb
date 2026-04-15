# src/compiler_frontend.rb - Shared compilation front-end
#
# Extracts the common pipeline shared by transpile(), transpile_mir(),
# and gen.rb: lex -> parse -> annotate -> rewrite -> MIRPass -> collect metadata.
#
# Both the old visit-dispatch path and the new MIR lowering path consume
# the same CompilerFrontend::Result.

require_relative "lexer"
require_relative "parser"
require_relative "ast"
require_relative "annotator"
require_relative "pipeline_rewriter"
require_relative "string_concat_rewriter"
require_relative "control_flow"

class CompilerFrontend
  Result = Struct.new(
    :ast,             # AST::Program with MIR nodes inserted by MIRPass
    :annotator,       # SemanticAnnotator (for ownership graph, schema lookup)
    :fn_nodes,        # { name => AST::FunctionDef }
    :fn_sigs,         # { name => FunctionSignature }
    :struct_schemas,  # { :Name => fields }
    :enum_schemas,    # { :Name => variants }
    :union_schemas,   # { :Name => variants }
    :moved_guard_info # { name => guard_info }
  )

  # Run the full front-end pipeline on CLEAR source code.
  #
  # Returns a Result with the annotated+MIR-stamped AST and all metadata
  # needed by either the old transpiler or the MIR lowering path.
  def self.compile(cheat_code, importer:, source_dir:, strict_test: false)
    tokens = Lexer.new(cheat_code).tokenize
    ast    = Parser.new(tokens, cheat_code).parse

    annotator = SemanticAnnotator.new(importer: importer, source_dir: source_dir, strict_test: strict_test)
    annotator.annotate!(ast)

    PipelineRewriter.new(annotator).rewrite!(ast)
    StringConcatRewriter.new.rewrite!(ast)

    schema_lookup = ->(name) { annotator.lookup_type_schema(name) }
    fn_nodes = {}
    ast.statements.each { |s| fn_nodes[s.name] = s if s.is_a?(AST::FunctionDef) }
    mir_pass = MIRPass.new(fn_nodes: fn_nodes, schema_lookup: schema_lookup)
    mir_pass.transform!(ast)

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
        fs = FunctionSignature.new(
          params: stmt.params || [],
          return_type: stmt.return_type || :Any,
          return_lifetime: stmt.return_lifetime,
          visibility: stmt.visibility,
          type_params: stmt.respond_to?(:type_params) ? stmt.type_params : nil,
          reentrant: stmt.respond_to?(:reentrant) && stmt.reentrant == :reentrant
        )
        fs.needs_rt = stmt.needs_rt
        fs.can_fail = stmt.can_fail
        fs.effects = stmt.effects
        fn_sigs[stmt.name] = fs
      end
    end

    # Include module-imported function signatures so MIRLowering can
    # determine needs_rt/can_fail for cross-module calls.
    annotator.scope_stack.first.locals.each do |name, entry|
      next if fn_sigs.key?(name)
      sig = entry.type
      next unless sig.is_a?(FunctionSignature) && sig.module_alias
      fn_sigs[name] = sig
    end

    moved_guard_info = {}
    fn_nodes.each { |name, fn| moved_guard_info[name] = fn.moved_guard_info if fn.moved_guard_info }

    Result.new(ast, annotator, fn_nodes, fn_sigs, struct_schemas, enum_schemas, union_schemas, moved_guard_info)
  end
end
