# typed: strict
#!/usr/bin/env ruby
# frozen_string_literal: true

require "bundler/setup"
require "optparse"
require "sorbet-runtime"

ROOT = File.expand_path("..", __dir__)
SRC_ROOT = File.join(ROOT, "src")
$LOAD_PATH.unshift(SRC_ROOT)
$LOAD_PATH.unshift(File.join(SRC_ROOT, "ast"))
$LOAD_PATH.unshift(File.join(SRC_ROOT, "mir"))
$LOAD_PATH.unshift(File.join(SRC_ROOT, "backends"))

Options = T.type_alias { T::Hash[Symbol, T.untyped] }

options = T.let({ format: "table", unchecked: true }, Options)
parser = OptionParser.new do |opts|
  opts.banner = "Usage: bundle exec ruby tools/profile_pass_work.rb [--csv] [--checked] examples/minivm/vm.cht"
  opts.on("--csv", "Emit machine-readable CSV instead of the aligned table") { options[:format] = "csv" }
  opts.on("--checked", "Enable sorbet-runtime checks while profiling") { options[:unchecked] = false }
  opts.on("--unchecked", "Disable sorbet-runtime checks while profiling (default)") { options[:unchecked] = true }
end
parser.parse!(ARGV)

T::Configuration.default_checked_level = :never if options[:unchecked]

require "semantic/pass_work_profiler"
require "ast/lexer"
require "ast/parser"
require "ast/ast"
require "annotator"
require "backends/compiler_frontend"
require "backends/importer"
require "backends/pipeline_rewriter"
require "backends/string_concat_rewriter"
require "mir/hoist"
require "mir/control_flow"
require "mir/mir_lowering"
require "mir/mir_checker"
require "mir/mir_emitter"
require "mir/pre_mir_type_check"
require "semantic/pass_state"

module PassWorkProfilerTool
  extend T::Sig

  module ASTWalkerInstrumentation
    extend T::Sig

    sig { params(root: T.untyped, descend_functions: T::Boolean, visitor: T.untyped).returns(T.untyped) }
    def each_locatable(root, descend_functions: false, &visitor)
      count = T.let(0, Integer)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      super(root, descend_functions: descend_functions) do |node|
        count += 1
        visitor.call(node)
      end
    ensure
      PassWorkProfiler.current&.record_walk(
        "AST.each_locatable",
        count,
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      )
    end

    sig { params(body: T.untyped, visitor: T.untyped).returns(T.untyped) }
    def walk_body(body, &visitor)
      count = T.let(0, Integer)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      super(body) do |node|
        count += 1
        visitor.call(node)
      end
    ensure
      PassWorkProfiler.current&.record_walk(
        "AST.walk_body",
        count,
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      )
    end

    sig { params(body: T.untyped, visitor: T.untyped).returns(T.untyped) }
    def each_bg_block(body, &visitor)
      count = T.let(0, Integer)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      super(body) do |node|
        count += 1
        visitor.call(node)
      end
    ensure
      PassWorkProfiler.current&.record_walk(
        "AST.each_bg_block",
        count,
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      )
    end
  end

  module MIRWalkerInstrumentation
    extend T::Sig

    sig { params(root: T.untyped, block: T.untyped).returns(T.untyped) }
    def each_node(root, &block)
      count = T.let(0, Integer)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      super(root) do |node|
        count += 1
        block.call(node)
      end
    ensure
      PassWorkProfiler.current&.record_walk(
        "MIR.each_node",
        count,
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      )
    end

    sig { params(root: T.untyped, block: T.untyped).returns(T.untyped) }
    def each_surface_node(root, &block)
      count = T.let(0, Integer)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      super(root) do |node|
        count += 1
        block.call(node)
      end
    ensure
      PassWorkProfiler.current&.record_walk(
        "MIR.each_surface_node",
        count,
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      )
    end

    sig { params(root: T.untyped).returns(T.untyped) }
    def nodes(root)
      out = T.let(nil, T.untyped)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out = super(root)
    ensure
      PassWorkProfiler.current&.record_walk(
        "MIR.nodes",
        out.respond_to?(:length) ? out.length : 0,
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      )
    end

    sig { params(root: T.untyped).returns(T.untyped) }
    def surface_nodes(root)
      out = T.let(nil, T.untyped)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out = super(root)
    ensure
      PassWorkProfiler.current&.record_walk(
        "MIR.surface_nodes",
        out.respond_to?(:length) ? out.length : 0,
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      )
    end
  end

  module AnnotatorInstrumentation
    extend T::Sig

    sig { params(scope: T.untyped, block: T.untyped).returns(T.untyped) }
    def with_new_scope(scope = nil, &block)
      stack = T.cast(instance_variable_get(:@scope_stack), T::Array[T.untyped])
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      super(scope, &block)
    ensure
      PassWorkProfiler.current&.record_walk(
        "Scope.with_new_scope",
        1,
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      )
      PassWorkProfiler.current&.record_walk("Scope.stack_depth_entered", stack.length, 0.0) if stack
    end

    sig { params(node: T.untyped).returns(T.untyped) }
    def visit(node)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      super
    ensure
      PassWorkProfiler.current&.record_walk(
        "AST.visit",
        node.nil? || node.is_a?(Symbol) ? 0 : 1,
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      )
    end

    sig { params(node: T.untyped).returns(T.untyped) }
    def visit_Program(node)
      PassWorkProfiler.current&.measure("annotator.visit_program", ast_root: node) { super }
    end

    sig { params(declarations: T.untyped).returns(T.untyped) }
    def register_type_declarations(declarations)
      PassWorkProfiler.current&.measure("annotator.register_types") { super }
    end

    sig { params(declarations: T.untyped).returns(T.untyped) }
    def register_program_signatures(declarations)
      PassWorkProfiler.current&.measure("annotator.register_signatures") { super }
    end

    sig { params(program_node: T.untyped).returns(T.untyped) }
    def bridge_reentrance!(program_node)
      PassWorkProfiler.current&.measure("annotator.bridge_reentrance", ast_root: program_node) { super }
    end

    sig { params(program_node: T.untyped).returns(T.untyped) }
    def seed_error_types_from_raises!(program_node)
      PassWorkProfiler.current&.measure("annotator.seed_error_types", ast_root: program_node) { super }
    end

    sig { params(program_node: T.untyped).returns(T.untyped) }
    def validate_and_resolve_sync_policy!(program_node)
      PassWorkProfiler.current&.measure("annotator.resolve_sync_policy", ast_root: program_node) { super }
    end

    sig { params(declarations: T.untyped, program: T.untyped).returns(T.untyped) }
    def analyze_program_bodies!(declarations, program)
      PassWorkProfiler.current&.measure("annotator.analyze_bodies", ast_root: program) { super }
    end

    sig { params(program: T.untyped).returns(T.untyped) }
    def finalize_program_semantics!(program)
      PassWorkProfiler.current&.measure("annotator.finalize_program_semantics", ast_root: program) { super }
    end

    sig { params(program: T.untyped).returns(T.untyped) }
    def finalize_auto_types!(program)
      PassWorkProfiler.current&.measure("annotator.finalize_auto_types", ast_root: program) { super }
    end

    sig { returns(T.untyped) }
    def run_whole_program_semantics!
      PassWorkProfiler.current&.measure("annotator.whole_program") { super }
    end

    sig { returns(T.untyped) }
    def run_deferred_validations!
      PassWorkProfiler.current&.measure("annotator.deferred_validations") { super }
    end

    sig { params(program: T.untyped).returns(T.untyped) }
    def mark_annotation_complete!(program)
      PassWorkProfiler.current&.measure("annotator.mark_annotation_complete", ast_root: program) { super }
    end
  end

  module ScopeInstrumentation
    extend T::Sig

    sig { returns(T.untyped) }
    def visible_entries
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      entries = T.let(super, T.untyped)
    ensure
      PassWorkProfiler.current&.record_walk(
        "Scope.visible_entries",
        entries.respond_to?(:length) ? entries.length : 0,
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      )
    end

    sig { returns(T.untyped) }
    def visible_names
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      names = T.let(super, T.untyped)
    ensure
      PassWorkProfiler.current&.record_walk(
        "Scope.visible_names",
        names.respond_to?(:length) ? names.length : 0,
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      )
    end

    sig { params(name: String).returns(T.untyped) }
    def entry_for_write(name)
      had_local = local_entry?(name)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      entry = T.let(super, T.untyped)
    ensure
      materialized = !had_local && !entry.nil?
      PassWorkProfiler.current&.record_walk(
        "Scope.entry_for_write",
        1,
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      )
      PassWorkProfiler.current&.record_walk("Scope.entries_materialized", 1, 0.0) if materialized
    end

    sig { params(entry: SymbolEntry).returns(SymbolEntry) }
    def clone_entry_for_scope(entry)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      super
    ensure
      PassWorkProfiler.current&.record_walk(
        "Scope.symbol_entry_clones",
        1,
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      )
    end
  end

  module EscapeAnalysisInstrumentation
    extend T::Sig

    sig { params(fn_nodes: T.untyped, schema_lookup: T.untyped).returns(T.untyped) }
    def apply!(fn_nodes, schema_lookup = nil)
      PassWorkProfiler.current&.measure("mir.escape_analysis", ast_root: fn_nodes) { super }
    end

    sig { params(fn_nodes: T.untyped).returns(T.untyped) }
    def propagate_caller_sync!(fn_nodes)
      label = PassWorkProfilerTool.current_stage_label == "mir.escape_analysis" ?
        "mir.caller_sync" :
        "annotator.caller_sync"
      PassWorkProfiler.current&.measure(label, ast_root: fn_nodes) { super }
    end
  end

  module BgCaptureInstrumentation
    extend T::Sig

    sig { params(fn_nodes: T.untyped, schema_lookup: T.untyped).returns(T.untyped) }
    def classify_all!(fn_nodes, schema_lookup: nil)
      label = caller_locations(1, 8).any? { |loc| loc.path.end_with?("mir_pass.rb") } ?
        "mir.bg_capture_classification" :
        "annotator.bg_capture_classification"
      PassWorkProfiler.current&.measure(label, ast_root: fn_nodes) { super }
    end
  end

  module EffectInferenceInstrumentation
    extend T::Sig

    sig { params(fn_nodes: T.untyped).returns(T.untyped) }
    def analyze!(fn_nodes)
      PassWorkProfiler.current&.measure("annotator.effect_inference", ast_root: fn_nodes) { super }
    end
  end

  module WithMatchInstrumentation
    extend T::Sig

    sig { params(fn: T.untyped, error_handler: T.untyped, warn_handler: T.untyped, policy_handlers: T.untyped).returns(T.untyped) }
    def check_function!(fn, error_handler, warn_handler: nil, policy_handlers: nil)
      PassWorkProfiler.current&.measure("annotator.with_match.functions", ast_root: fn) { super }
    end

    sig { params(fn: T.untyped, sig_lookup: T.untyped, error_handler: T.untyped).returns(T.untyped) }
    def check_call_sites!(fn, sig_lookup, error_handler)
      PassWorkProfiler.current&.measure("annotator.with_match.call_sites", ast_root: fn) { super }
    end
  end

  module ConcurrencyInstrumentation
    extend T::Sig

    sig { params(fn_nodes: T.untyped, sig_lookup: T.untyped, error_handler: T.untyped, lock_ranks: T.untyped).returns(T.untyped) }
    def check_all!(fn_nodes, sig_lookup, error_handler, lock_ranks: {})
      PassWorkProfiler.current&.measure("annotator.concurrency_checks", ast_root: fn_nodes) { super }
    end
  end

  module CleanupClassifierInstrumentation
    extend T::Sig

    sig { params(fn_node: T.untyped, schema_lookup: T.untyped).returns(T.untyped) }
    def classify(fn_node, schema_lookup:)
      PassWorkProfiler.current&.measure("mir.cleanup_classification", ast_root: fn_node) { super }
    end
  end

  module LoopFrameInstrumentation
    extend T::Sig

    sig { params(fn_nodes: T.untyped, schema_lookup: T.untyped).returns(T.untyped) }
    def analyze!(fn_nodes, schema_lookup = nil)
      PassWorkProfiler.current&.measure("mir.loop_frame_analysis", ast_root: fn_nodes) { super }
    end
  end

  module MIRPassInstrumentation
    extend T::Sig

    sig { returns(T.untyped) }
    def finalize_needs_rt!
      PassWorkProfiler.current&.measure("mir.finalize_needs_rt") { super }
    end

    sig { params(fn: T.untyped).returns(T.untyped) }
    def transform_function!(fn)
      PassWorkProfiler.current&.measure("mir.ast_stamping", ast_root: fn) { super }
    end
  end

  module OwnershipDataflowInstrumentation
    extend T::Sig

    sig { params(fn_node: T.untyped, can_fail_fns: T.untyped, schema_lookup: T.untyped).returns(T.untyped) }
    def analyze(fn_node, can_fail_fns: nil, schema_lookup: nil)
      PassWorkProfiler.current&.measure("mir.ownership_dataflow", ast_root: fn_node) { super }
    end
  end

  module CFGInstrumentation
    extend T::Sig

    sig { params(fn_node: T.untyped, can_fail_fns: T.untyped).returns(T.untyped) }
    def build(fn_node, can_fail_fns: nil)
      PassWorkProfiler.current&.measure("mir.cfg_build", ast_root: fn_node) { super }
    end
  end

  module OwnershipDataflowInstanceInstrumentation
    extend T::Sig

    sig { returns(T.untyped) }
    def analyze!
      PassWorkProfiler.current&.measure("mir.ownership_dataflow_fixpoint") { super }
    end

    sig { params(block: T.untyped, state: T.untyped).returns(T.untyped) }
    def apply_transfer(block, state)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      super
    ensure
      stmts = block.respond_to?(:stmts) ? block.stmts : []
      PassWorkProfiler.current&.record_walk(
        "CFG.transfer_stmts",
        stmts.respond_to?(:length) ? stmts.length : 0,
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      )
    end

    sig { params(block: T.untyped).returns(T.untyped) }
    def join_predecessors(block)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      super
    ensure
      predecessors = block.respond_to?(:predecessors) ? block.predecessors : []
      PassWorkProfiler.current&.record_walk(
        "CFG.join_predecessors",
        predecessors.respond_to?(:length) ? predecessors.length : 0,
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      )
    end

    sig { params(state: T.untyped).returns(T.untyped) }
    def dup_state(state)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      super
    ensure
      PassWorkProfiler.current&.record_walk(
        "CFG.state_entries_copied",
        state.respond_to?(:length) ? state.length : 0,
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      )
    end
  end

  sig { void }
  def self.install!
    AST.singleton_class.prepend(ASTWalkerInstrumentation)
    MIR.singleton_class.prepend(MIRWalkerInstrumentation)
    SemanticAnnotator.prepend(AnnotatorInstrumentation)
    EscapeAnalysis.singleton_class.prepend(EscapeAnalysisInstrumentation)
    BgCaptureClassifier.singleton_class.prepend(BgCaptureInstrumentation)
    EffectInference.singleton_class.prepend(EffectInferenceInstrumentation)
    WithMatchCheck.singleton_class.prepend(WithMatchInstrumentation)
    ConcurrencyChecks.singleton_class.prepend(ConcurrencyInstrumentation)
    CleanupClassifier.singleton_class.prepend(CleanupClassifierInstrumentation)
    LoopFrameAnalysis.singleton_class.prepend(LoopFrameInstrumentation)
    MIRPass.prepend(MIRPassInstrumentation)
    Scope.prepend(ScopeInstrumentation)
    OwnershipDataflow.singleton_class.prepend(OwnershipDataflowInstrumentation)
    FunctionCFG.singleton_class.prepend(CFGInstrumentation)
    OwnershipDataflow.prepend(OwnershipDataflowInstanceInstrumentation)
  end

  sig { returns(T.nilable(String)) }
  def self.current_stage_label
    profiler = PassWorkProfiler.current
    return nil unless profiler

    T.unsafe(profiler).send(:current_label)
  end

  class Runner
    extend T::Sig

    sig { params(source_path: String).void }
    def initialize(source_path)
      @source_path = source_path
      @source = T.let(File.read(source_path), String)
      @source_dir = T.let(File.dirname(source_path), String)
      @profiler = T.let(PassWorkProfiler::Profiler.new, PassWorkProfiler::Profiler)
    end

    sig { returns(PassWorkProfiler::Profiler) }
    attr_reader :profiler

    sig { returns(T::Hash[Symbol, Integer]) }
    def run
      PassWorkProfiler.current = @profiler
      tokens = T.let(nil, T.untyped)
      ast = T.let(nil, T.untyped)
      importer = ModuleImporter.new(base_dir: @source_dir, use_mir: true)

      @profiler.measure("lexer.tokenize") { tokens = Lexer.new(@source).tokenize }
      token_count = T.must(tokens).length

      @profiler.measure("parser.parse", token_count: token_count) do
        ast = Parser.new(T.must(tokens), @source).parse
      end
      ast = T.must(ast)
      parsed_ast_nodes = PassWorkProfiler.count_ast_nodes(ast)

      annotator = SemanticAnnotator.new(
        importer: importer,
        source_dir: @source_dir,
        strict_test: false,
        source_code: @source
      )
      @profiler.measure("annotator.annotate", ast_root: ast) { annotator.annotate!(ast) }

      @profiler.measure("pipeline.rewrite", ast_root: ast) do
        PipelineRewriter.new(annotator).rewrite!(ast)
        MIRPassState.for!(ast).mark!(:pipeline_rewritten)
      end

      @profiler.measure("string_concat.rewrite", ast_root: ast) do
        StringConcatRewriter.new.rewrite!(ast)
        MIRPassState.for!(ast).mark!(:string_concat_rewritten)
      end

      schema_lookup = lambda { |name| annotator.lookup_type_schema(name) }
      @profiler.measure("mir.hoist", ast_root: ast) { Hoist.apply!(ast, schema_lookup: schema_lookup) }

      fn_nodes = T.let({}, T::Hash[String, AST::FunctionDef])
      ast.statements.each { |stmt| fn_nodes[stmt.name] = stmt if stmt.is_a?(AST::FunctionDef) }
      CompilerFrontend.synthesize_test_body_wrappers!(ast, fn_nodes)

      @profiler.measure("mir.pre_mir_type_check", ast_root: ast) { PreMirTypeCheck.verify!(ast) }

      mir_pass = MIRPass.new(fn_nodes: fn_nodes, schema_lookup: schema_lookup)
      @profiler.measure("mir.pass", ast_root: ast) { mir_pass.transform!(ast) }

      struct_schemas = T.let({}, T::Hash[Symbol, T.untyped])
      enum_schemas = T.let({}, T::Hash[Symbol, T.untyped])
      union_schemas = T.let({}, T::Hash[Symbol, T.untyped])
      ast.statements.each do |stmt|
        case stmt
        when AST::StructDef then struct_schemas[stmt.name.to_sym] = Schemas::StructSchema.new(fields: stmt.field_decls)
        when AST::EnumDef then enum_schemas[stmt.name.to_sym] = stmt.variants
        when AST::UnionDef
          union_schemas[stmt.name.to_sym] = Schemas::UnionSchema.new(
            variants: stmt.variants,
            type_params: stmt.type_params&.any? ? stmt.type_params.map(&:to_sym) : nil,
            visibility: stmt.visibility || :package
          )
        end
      end

      fn_sigs = T.let({}, T::Hash[String, T.untyped])
      ast.statements.each do |stmt|
        fn_sigs[stmt.name] = FunctionSignature.from_function_def(stmt) if stmt.is_a?(AST::FunctionDef)
      end
      annotator.scope_stack.first.visible_entries.each do |name, entry|
        next if fn_sigs.key?(name)
        sig = entry.fn_signature
        fn_sigs[name] = sig if sig && sig.module_alias
      end

      moved_guard_info = T.let({}, T::Hash[String, T.untyped])
      fn_nodes.each { |name, fn| moved_guard_info[name] = fn.moved_guard_info if fn.moved_guard_info }

      lowering = MIRLowering.new(
        struct_schemas: struct_schemas,
        enum_schemas: enum_schemas,
        union_schemas: union_schemas,
        fn_sigs: fn_sigs,
        moved_guard_info: moved_guard_info,
        importer: importer,
        source_dir: @source_dir
      )
      mod = T.let(nil, T.untyped)
      @profiler.measure("mir.lower", ast_root: ast) { mod = lowering.lower_module(ast) }
      items = T.let((T.must(mod)[:items] + T.must(mod)[:type_items]).flatten, T::Array[T.untyped])
      lowered_mir_nodes = PassWorkProfiler.count_mir_nodes(items)

      checker = MIRChecker.new
      @profiler.measure("mir.check", mir_root: items) do
        items.grep(MIR::FnDef).each do |fn|
          errors = checker.check_fn!(fn, strict: true)
          raise errors.join("\n") unless errors.empty?
        end
      end

      emitter = MIREmitter.new
      @profiler.measure("mir.emit", mir_root: items) do
        items.each { |item| emitter.emit(item) }
      end

      {
        tokens: token_count,
        parsed_ast_nodes: parsed_ast_nodes,
        final_ast_nodes: PassWorkProfiler.count_ast_nodes(ast),
        lowered_mir_nodes: lowered_mir_nodes,
      }
    ensure
      PassWorkProfiler.current = nil
    end
  end
end

source_path = File.expand_path(ARGV.fetch(0) { "examples/minivm/vm.cht" }, ROOT)
PassWorkProfilerTool.install!
runner = PassWorkProfilerTool::Runner.new(source_path)
scale = runner.run

if options[:format] == "csv"
  puts "metric,value"
  scale.each { |name, value| puts "#{name},#{value}" }
  puts
  puts runner.profiler.to_csv
else
  puts "scale: tokens=#{PassWorkProfiler.format_count(scale.fetch(:tokens))} " \
       "parsed_ast_nodes=#{PassWorkProfiler.format_count(scale.fetch(:parsed_ast_nodes))} " \
       "final_ast_nodes=#{PassWorkProfiler.format_count(scale.fetch(:final_ast_nodes))} " \
       "lowered_mir_nodes=#{PassWorkProfiler.format_count(scale.fetch(:lowered_mir_nodes))}"
  ratio = scale.fetch(:tokens).zero? ? 0.0 : scale.fetch(:parsed_ast_nodes).to_f / scale.fetch(:tokens)
  puts "scale_ratio: parsed_ast_nodes_per_token=#{format("%.3f", ratio)}"
  puts
  puts runner.profiler.to_table
end
