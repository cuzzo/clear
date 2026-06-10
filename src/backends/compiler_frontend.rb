# typed: strict
# src/compiler_frontend.rb - Shared compilation front-end
#
# Extracts the common pipeline shared by transpile(), transpile_mir(),
# and gen.rb: lex -> parse -> annotate -> rewrite -> MIRPass -> collect metadata.
#
# Both the old visit-dispatch path and the new MIR lowering path consume
# the same CompilerFrontend::Result.

require "sorbet-runtime"

require_relative "../ast/lexer"
require_relative "../ast/parser"
require_relative "../ast/ast"
require_relative "../annotator"
require_relative "pipeline_rewriter"
require_relative "string_concat_rewriter"
require_relative "../mir/hoist"
require_relative "../semantic/pass_state"
require_relative "../mir/control_flow"
require_relative "../mir/pre_mir_type_check"

class CompilerFrontend
    extend T::Sig

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
  sig { params(cheat_code: String, importer: ModuleImporter, source_dir: String, strict_test: T::Boolean).returns(T.nilable(CompilerFrontend::Result)) }
  def self.compile(cheat_code, importer:, source_dir:, strict_test: false)
    tokens = Lexer.new(cheat_code).tokenize
    ast    = Parser.new(tokens, cheat_code).parse

    annotator = SemanticAnnotator.new(importer: importer, source_dir: source_dir, strict_test: strict_test, source_code: cheat_code)
    annotator.annotate!(T.must(ast))

    ast = T.must(ast)
    PipelineRewriter.new(annotator).rewrite!(ast)
    MIRPassState.for!(ast).mark!(:pipeline_rewritten)
    StringConcatRewriter.new.rewrite!(ast)
    MIRPassState.for!(ast).mark!(:string_concat_rewritten)
    schema_lookup = ->(name) { annotator.lookup_type_schema(name) }

    # Hoist after all annotation-preserving rewrites so escape analysis
    # only ever sees symbol-bearing declarations, including synthetic
    # allocation expressions introduced by those rewrites.
    hoist_result = Hoist.apply!(ast, schema_lookup: schema_lookup)

    fn_nodes = T.let({}, T::Hash[String, AST::FunctionDef])
    ast.statements.each { |s| fn_nodes[s.name] = s if s.is_a?(AST::FunctionDef) }

    # Synthesize a FunctionDef wrapper for every TEST THAT body so the
    # MIR pipeline (escape analysis, promotion, cleanup classification,
    # MIR-node insertion) processes test bodies the same way it
    # processes regular function bodies. Without this, locals declared
    # inside a TEST THAT (e.g. `x = Client{ host: "..." }`) never get
    # MIR::Drop / MIR::Cleanup nodes emitted, and the heap-allocated
    # string field leaks at end of test scope. The wrapper shares the
    # body array with the AST::TestThat so the inserted MIR nodes
    # appear at lower-time. The wrapper itself never reaches code
    # generation -- mir_lowering still walks the TestBlock directly.
    synthesize_test_body_wrappers!(ast, fn_nodes)

    # AST→MIR boundary invariant: every evaluatable node must carry a
    # resolved type by now. A nil full_type here is a compiler bug
    # (annotator failed to stamp it), surfaced before MIR consumes it.
    PreMirTypeCheck.verify!(ast)

    mir_pass = MIRPass.new(
      fn_nodes: fn_nodes,
      schema_lookup: schema_lookup,
      body_summaries: T.must(annotator.semantic_index).body_summaries,
      hoist_bindings: hoist_result.bindings_by_function
    )
    mir_pass.transform!(ast)

    struct_schemas = {}
    enum_schemas = {}
    union_schemas = {}
    ast.statements.each do |stmt|
      case stmt
      when AST::StructDef then struct_schemas[stmt.name.to_sym] = Schemas::StructSchema.new(fields: stmt.field_decls)
      when AST::EnumDef   then enum_schemas[stmt.name.to_sym] = stmt.variants
      when AST::UnionDef  then union_schemas[stmt.name.to_sym] = Schemas::UnionSchema.new(
        variants: stmt.variants,
        type_params: stmt.type_params&.any? ? stmt.type_params.map(&:to_sym) : nil,
        visibility: stmt.visibility || :package,
      )
      end
    end

    fn_sigs = {}
    ast.statements.each do |stmt|
      next unless stmt.is_a?(AST::FunctionDef)
      fn_sigs[stmt.name] = FunctionSignature.from_function_def(stmt)
    end

    # Include module-imported function signatures so MIRLowering can
    # determine needs_rt/can_fail for cross-module calls.
    annotator.semantic_root_scope.visible_entries.each do |name, entry|
      next if fn_sigs.key?(name)
      sig = entry.fn_signature
      next unless sig && sig.module_alias
      fn_sigs[name] = sig
    end

    moved_guard_info = {}
    fn_nodes.each { |name, fn| moved_guard_info[name] = fn.moved_guard_info if fn.moved_guard_info }

    Result.new(ast, annotator, fn_nodes, fn_sigs, struct_schemas, enum_schemas, union_schemas, moved_guard_info)
  end

  # Walk every TEST THAT body in the program and register a synthetic
  # FunctionDef for it under fn_nodes. The wrapper shares the body
  # array with the AST::TestThat (no copy), so MIRPass mutating the
  # body during analysis lands the inserted MIR::Drop / MIR::Cleanup /
  # MIR::SuppressCleanup nodes back on the test's original body. The
  # wrapper never reaches code generation -- it only carries enough
  # shape for the analysis passes to walk the body as if it were a
  # real `FN __test_X() RETURNS Void -> ... END`.
  sig { params(ast: AST::Program, fn_nodes: T::Hash[String, AST::FunctionDef]).returns(T::Array[AST::FunctionDef]) }
  def self.synthesize_test_body_wrappers!(ast, fn_nodes)
    wrappers = T.let([], T::Array[AST::FunctionDef])
    counter = 0
    ast.statements.each do |stmt|
      next unless stmt.is_a?(AST::TestBlock)
      stmt.whens&.each do |when_block|
        when_block.tests&.each do |test_that|
          counter += 1
          synth_name = "__test_body_#{counter}"
          synth_fn = AST::FunctionDef.new(
            test_that.token,
            synth_name,
            [],            # params
            nil,           # captures
            :Void,         # return_type
            nil,           # return_lifetime
            test_that.body, # body (shared reference)
            [],            # catch_clauses
            nil,           # default_catch
            :pub,          # visibility
            nil,           # deferred_drops
            false          # uses_frame
          )
          fn_nodes[synth_name] = synth_fn
          wrappers << synth_fn
          # Stamp the wrapper onto the AST::TestThat so mir_lowering can
          # reach the cleanup_bindings / promotion when it walks the
          # body. Without this, lower_test_block's @current_bindings
          # stays empty and the cleanup recipes never get applied.
          test_that.synthetic_fn = synth_fn
        end
      end
    end
    wrappers
  end
end
