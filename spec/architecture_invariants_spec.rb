require "rspec"

ARCH_ROOT = File.expand_path("..", __dir__)

# Static-analysis guard for the placement-field architecture.
#
# Storage / allocator decisions flow through a staged pipeline, and EACH
# field has exactly ONE sanctioned writer. A write from anywhere else is
# a renegade escape/placement decision -- the architectural defect that
# produces the allocator-mismatch bug class (leaks, double-frees,
# invalid frees). This test fails the build if such a write exists.
#
#   node.storage        <- annotation ONLY
#   symbol.storage      <- escape analysis ONLY
#   CleanupEntry#alloc  <- cleanup classification ONLY
#   CleanupEntry#scope  <- cleanup classification ONLY
#
# These invariants are non-negotiable: fixing the compiler means making
# every placement decision in its one sanctioned pass, never beside it.
RSpec.describe "architecture invariants: placement-field writers" do
  SRC = File.join(ARCH_ROOT, "src")

  # ── the ONE sanctioned writer of each field ─────────────────────────

  # node.storage is expression-shape metadata. Annotation is the source for
  # parsed nodes; rewrite/lowering adapters may copy that metadata onto
  # synthetic nodes, but escape placement must not be written here.
  NODE_STORAGE_OK = lambda do |rel|
    rel == "annotator/annotator.rb" ||
      rel.start_with?("annotator/helpers/") ||
      rel.start_with?("annotator/domains/") ||
      rel == "ast/ast.rb" ||           # finalize_storage! -- the annotation mechanism
      rel == "ast/parser.rb" ||        # parse-time literal storage
      rel == "mir/alloc.rb" ||         # downgrade_frame_to_stack: mixed into SemanticAnnotator
      rel == "mir/lower/pipeline/pipeline_context.rb" ||
      rel == "mir/lower/pipeline/pipeline_host.rb" ||
      rel == "backends/pipeline_rewriter.rb" ||
      rel == "backends/string_concat_rewriter.rb" ||
      rel == "mir/mir_lowering.rb" ||
      rel.start_with?("mir/lowering/")
  end

  # symbol.storage is made DEFINITIVE by the shared semantic escape analysis.
  SYMBOL_STORAGE_OK = lambda do |rel|
    rel == "semantic/escape_analysis.rb"
  end

  # CleanupEntry#alloc is set once, by cleanup classification.
  CLEANUP_ALLOC_OK = lambda do |rel|
    rel == "mir/cleanup_classifier.rb" || rel == "mir/cleanup_entry.rb"
  end

  # ── scan every source file for placement-field writes ───────────────

  def self.scan
    node_w = []
    sym_w = []
    cleanup_w = []
    cleanup_scope_w = []
    Dir[File.join(SRC, "**", "*.rb")].sort.each do |path|
      rel = path.sub(SRC + "/", "")
      File.readlines(path).each_with_index do |line, idx|
        next if line.strip.start_with?("#")          # skip comment lines
        loc = "#{rel}:#{idx + 1}"
        code = line.strip

        if (m = line.match(/([\w.\[\]]*)\.storage\s*=(?![=~])/))
          recv = m[1]
          symbol_write = recv.end_with?(".symbol") ||
                         %w[sym symbol node_sym decl_sym entry sym_entry].include?(recv)
          (symbol_write ? sym_w : node_w) << [loc, code]
        end

        # CleanupEntry is a typed Hash-subclass written via [:alloc]=.
        # Restrict to entry/cleanup-named receivers so plain Hashes
        # (effects[:alloc], resolved_allocs[:alloc]) are not flagged.
        if line.match(/\b\w*(?:entry|cleanup)\w*\[:alloc\]\s*=(?![=~])/i)
          cleanup_w << [loc, code]
        end

        if line.match(/\b\w*(?:entry|cleanup)\w*\[:scope\]\s*=(?![=~])/i)
          cleanup_scope_w << [loc, code]
        end
      end
    end
    { node: node_w, symbol: sym_w, cleanup: cleanup_w, cleanup_scope: cleanup_scope_w }
  end

  WRITES = scan

  def renegades(list, sanctioned)
    list.reject { |loc, _| sanctioned.call(loc.split(":").first) }
  end

  def report(label, bad)
    "#{bad.size} renegade #{label} write(s) -- must move to the sanctioned pass:\n" +
      bad.map { |loc, code| "  #{loc}\n      #{code}" }.join("\n")
  end

  it "node.storage is written ONLY by annotation" do
    bad = renegades(WRITES[:node], NODE_STORAGE_OK)
    expect(bad).to be_empty, report("node.storage", bad)
  end

  it "symbol.storage is written ONLY by escape analysis" do
    bad = renegades(WRITES[:symbol], SYMBOL_STORAGE_OK)
    expect(bad).to be_empty, report("symbol.storage", bad)
  end

  it "CleanupEntry#alloc is written ONLY by cleanup classification" do
    bad = renegades(WRITES[:cleanup], CLEANUP_ALLOC_OK)
    expect(bad).to be_empty, report("CleanupEntry#alloc", bad)
  end

  it "CleanupEntry#scope is written ONLY by cleanup classification" do
    bad = renegades(WRITES[:cleanup_scope], CLEANUP_ALLOC_OK)
    expect(bad).to be_empty, report("CleanupEntry#scope", bad)
  end
end

RSpec.describe "architecture invariants: MIR pass order" do
  def source(rel)
    File.read(File.join(ARCH_ROOT, rel))
  end

  def expect_order(rel, *patterns)
    text = source(rel)
    positions = patterns.map do |pattern|
      idx = text.index(pattern)
      expect(idx).not_to be_nil, "#{rel} is missing #{pattern.inspect}"
      idx
    end
    expect(positions).to eq(positions.sort),
      "#{rel} has wrong pass order:\n  #{patterns.join("\n  ")}"
  end

  it "runs top-level rewrites before hoist, type check, and MIRPass" do
    expect_order(
      "src/backends/compiler_frontend.rb",
      "annotator.annotate!",
      "PipelineRewriter.new(annotator).rewrite!(ast)",
      "MIRPassState.for!(ast).mark!(:pipeline_rewritten)",
      "StringConcatRewriter.new.rewrite!(ast)",
      "MIRPassState.for!(ast).mark!(:string_concat_rewritten)",
      "schema_lookup = ->(name) { annotator.lookup_type_schema(name) }",
      "Hoist.apply!(ast, schema_lookup: schema_lookup)",
      "PreMirTypeCheck.verify!(ast)",
      "mir_pass = MIRPass.new",
      "mir_pass.transform!",
    )
  end

  it "runs imported modules through the same rewrite/hoist/typecheck/MIRPass boundary" do
    expect_order(
      "src/backends/importer.rb",
      "annotator.annotate!",
      "PipelineRewriter.new(annotator).rewrite!(ast)",
      "MIRPassState.for!(ast).mark!(:pipeline_rewritten)",
      "StringConcatRewriter.new.rewrite!(ast)",
      "MIRPassState.for!(ast).mark!(:string_concat_rewritten)",
      "schema_lookup = ->(name) { annotator.lookup_type_schema(name) }",
      "Hoist.apply!(ast, schema_lookup: schema_lookup)",
      "PreMirTypeCheck.verify!(ast)",
      "mir_pass = MIRPass.new",
      "mir_pass.transform!",
    )
  end

  it "runs MIR placement before cleanup classification, loop analysis, and lowering stamps" do
    expect_order(
      "src/mir/mir_pass.rb",
      "pass_state.require!(:premir_type_checked",
      "EscapeAnalysis.apply_with_facts!",
      "pass_state.mark!(:escape_analyzed)",
      "CleanupClassifier.classify",
      "pass_state.mark!(:cleanup_classified)",
      "LoopFrameAnalysis.analyze!",
      "pass_state.mark!(:loop_frame_analyzed)",
      "finalize_needs_rt!",
      "pass_state.mark!(:needs_rt_finalized)",
      "transform_function!",
      "pass_state.mark!(:mir_pass_complete)",
    )
  end

  it "requires each MIR consumer to assert the pass-state stage it consumes" do
    expect(source("src/mir/hoist.rb")).to include('MIRPassState.require!(ast, :string_concat_rewritten, consumer: "Hoist")')
    expect(source("src/mir/pre_mir_type_check.rb")).to include('MIRPassState.require!(program, :hoisted, consumer: "PreMirTypeCheck")')
    expect(source("src/mir/mir_lowering.rb")).to include('MIRPassState.require!(node, :mir_pass_complete, consumer: "MIRLowering")')
    expect(source("src/mir/mir_checker.rb")).to include('MIRPassState.require!(program, :mir_lowered, consumer: "MIRChecker")')
  end

  it "keeps pass stages registered as typed producer/requirement specs" do
    pass_state = source("src/semantic/pass_state.rb")
    expect(pass_state).to include("class StageSpec < T::Struct")
    expect(pass_state).to include("const :producer, String")
    expect(pass_state).to include("const :requires, T.nilable(Symbol)")
    expect(pass_state).to include("STAGE_BY_NAME")
    expect(pass_state).to include("next required stage")
  end

  it "aborts compilation on MIRChecker errors in emitted program paths" do
    expect(source("src/backends/transpiler.rb")).to include("MIR ownership verification failed")
    expect(source("src/backends/transpiler.rb")).to match(/raise\s+"MIR ownership verification failed/)
  end

	  it "does not use regexes or regex-driven text rewriting anywhere in MIR" do
	    paths = Dir[File.join(ARCH_ROOT, "src/mir/**/*.rb")]

    offenders = paths.uniq.sort.flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      File.readlines(path).filter_map.with_index do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.match?(/Regexp|\.match\?|\.match\(|\.scan\(|\.gsub\(\s*\//) ||
                    line.match?(/\.sub\(\s*\//) ||
                    line.match?(/=~\s*\//)

        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty, offenders.join("\n")
  end

  it "requires structural calls to carry typed callable contracts" do
    expect(source("src/mir/mir.rb")).to include("class CallableContract")
    expect(source("src/mir/mir.rb")).to include("attr_reader :signature")
    expect(source("src/mir/mir.rb")).to include("attr_reader :ownership_contract")
    expect(source("src/mir/mir.rb")).to include("attr_reader :checked_arg_count")
    expect(source("src/mir/mir_checker.rb")).to include("verify_callable_contract!")
    expect(source("src/mir/mir_checker.rb")).to include("MIR::CallableContract")
  end

  it "keeps ownership-significant MIR node classes in an explicit registry" do
    expect(source("src/mir/mir.rb")).to include("OWNERSHIP_SIGNIFICANT_NODE_TYPES")
    expect(source("src/mir/mir.rb")).to include("AllocMark, Cleanup, ErrCleanup, TransferMark, MoveMark")
    expect(source("src/mir/mir.rb")).to include("ReturnMark, DiscardOwned, RegistryCall")
    expect(source("src/mir/mir.rb")).to include("Call, TailCall, MethodCall")
  end

  it "keeps raw Zig statement nodes out of production source" do
    offenders = Dir.glob(File.join(ARCH_ROOT, "src", "**", "*.rb")).flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      File.readlines(path).filter_map.with_index do |line, idx|
        next unless line.include?("RawZig")

        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty, offenders.join("\n")
  end

  it "keeps linear MIR ownership traversal closed over statement node classes" do
    checker = source("src/mir/mir_checker.rb")
    expect(checker).to include("LINEAR_STATEMENT_NODE_TYPES")
    expect(checker).to include("LINEAR_STMT_NOT_REGISTERED")
    expect(checker).not_to match(/else\s*\n\s*check_linear_expr_uses!\(stmt, state\)/)
  end

  it "keeps escape analysis sinks registered with concrete handlers" do
    escape = source("src/semantic/escape_analysis.rb")
    expect(escape).to include("ESCAPE_SINK_HANDLERS")
    expect(escape).to include("DERIVED_PLACEMENT_HANDLERS")
    expect(escape).to include("validate_escape_sink_handlers!")
    expect(escape).to include("owning_return")
    expect(escape).to include("takes_or_mutable_arg")
    expect(escape).to include("execution_boundary_capture")
    expect(escape).to include("receiver_backing_storage")
    sink_registry = escape[/ESCAPE_SINK_HANDLERS = T\.let\(\{.*?\n  \}\.freeze, EscapeHandlerRegistry\)/m]
    expect(sink_registry).not_to include("assignment_ownership")
    expect(sink_registry).not_to include("hoist_dependency")
  end

  it "keeps escape heap placement explainable through typed facts" do
    escape = source("src/semantic/escape_analysis.rb")

    expect(escape).to include("class EscapePlacementFact < T::Struct")
    expect(escape).to include("class EscapePlacementFacts < T::Struct")
    expect(escape).to include("def self.apply_with_facts!")
    expect(escape).to include("result = apply_with_facts!(fn_nodes, schema_lookup)")
    expect(escape).to include("record_placement_phase!(placements, facts")
    expect(escape).to include("Result.new(heap_fns: placements.heap_function_names")
  end

  it "keeps WITH capability expansion behind typed fact records" do
    capabilities = source("src/annotator/helpers/capabilities.rb")
    execution = source("src/annotator/domains/execution_boundaries.rb")
    plan = source("src/semantic/capability_plan.rb")
    mir_caps = source("src/mir/lowering/capabilities.rb")
    deferred = source("src/annotator/phases/deferred_validation.rb")

    expect(plan).to include("class CapabilityRequest < T::Struct")
    expect(plan).to include("class CapabilityTargetFact < T::Struct")
    expect(plan).to include("class CapabilityTransition < T::Struct")
    expect(plan).to include("class WithCapabilityPlan < T::Struct")
    expect(capabilities).to include("WithCapabilityFact = CapabilityPlan::CapabilityTransition")
    expect(execution).to include("capability_expansion = CapabilityHelper::WithCapabilityExpansion.new")
    expect(execution).to include("node.capability_plan = capability_expansion")
    expect(deferred).to include("const :fact, CapabilityPlan::CapabilityTransition")
    expect(deferred).not_to include("const :var_node")
    expect(deferred).not_to include("const :capability")
    expect(mir_caps).to include("CapabilityPlan.require_for(node).all")
  end

  it "does not reach into removed annotator function-node ivars" do
    production_paths = [
      File.join(ARCH_ROOT, "clear"),
      *Dir[File.join(ARCH_ROOT, "src", "**", "*.rb")],
    ]

    offenders = production_paths.uniq.sort.flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      File.readlines(path).filter_map.with_index do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.include?("instance_variable_get(:@fn_nodes)") ||
                    line.include?("instance_variable_get('@fn_nodes')") ||
                    line.include?('instance_variable_get("@fn_nodes")')

        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "Production code must use SemanticAnnotator#semantic_function_nodes instead of stale @fn_nodes reach-ins:\n" \
      "#{offenders.join("\n")}"
  end

  it "keeps MIR capability lowering on typed plans, not raw source capability hashes" do
    sanctioned = [
      "src/mir/lower/pipeline/pipeline_context.rb",
    ]
    raw_field_reads = [
      "[:capability]",
      "[:var_node]",
      "[:alias]",
      "[:alias_mutable]",
      "[:guard_expr]",
      "[:resolved_type]",
      "[:old_scope]",
    ]

    offenders = Dir[File.join(ARCH_ROOT, "src/mir/**/*.rb")].sort.flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      next [] if sanctioned.include?(rel)

      source(rel).lines.each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.match?(/\b(?:node|stmt|with_node|with_stmt)\.capabilities\b/) ||
                    line.match?(/\bAST::Capability\b/) ||
                    line.include?("T::Array[AST::Capability]") ||
                    raw_field_reads.any? { |field| line.include?(field) }

        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "MIR must consume CapabilityPlan::WithCapabilityPlan facts instead of raw source capability hashes:\n" \
      "#{offenders.join("\n")}"
  end

  it "does not let production capability consumers rediscover raw lock facts" do
    offenders = Dir[File.join(ARCH_ROOT, "src/**/*.rb")].sort.flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      next [] if rel == "src/ast/ast.rb"

      source(rel).lines.each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.include?("lock_identity_of") || line.include?("T::Array[AST::Capability]")

        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "WITH capability consumers must use WithCapabilityFact/WithCapabilityExpansion, not raw AST capability rediscovery:\n" \
      "#{offenders.join("\n")}"
  end

  it "does not rediscover MIR ownership effects with respond_to? probes" do
    offenders = Dir[File.join(ARCH_ROOT, "src/mir/**/*.rb")].sort.flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      source(rel).lines.each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.include?("respond_to?(:ownership_effect)") ||
                    line.include?('respond_to?("ownership_effect")')

        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "MIR ownership consumers must use MIR::OwnershipEffect.of/typed facts, not optional protocol probes:\n" \
      "#{offenders.join("\n")}"
  end
end

RSpec.describe "architecture invariants: fail-closed MIR ownership facts" do
  def source(rel)
    File.read(File.join(ARCH_ROOT, rel))
  end

  def source_lines(rel)
    source(rel).lines.each_with_index
  end

  OWNERSHIP_SOURCE_FILES = [
    "src/mir/mir_lowering.rb",
    "src/mir/hoist.rb",
    "src/mir/fsm_lowering.rb",
    "src/mir/lower/pipeline/pipeline_host.rb",
    "src/mir/lower/pipeline/pipeline_materializer.rb",
  ].freeze

  OWNERSHIP_LOWERING_GLOBS = [
    "src/mir/mir_lowering.rb",
    "src/mir/lowering/**/*.rb",
    "src/mir/fsm_lowering.rb",
    "src/mir/lower/pipeline/pipeline_host.rb",
    "src/mir/lower/pipeline/pipeline_materializer.rb",
  ].freeze

  def ownership_lowering_files
    OWNERSHIP_LOWERING_GLOBS.flat_map { |glob| Dir[File.join(ARCH_ROOT, glob)] }.uniq.sort
  end

  def ownership_context?(line)
    line.match?(/ownership|consum|consume|transfer|MoveMark|TransferMark|owned_sink|target_alloc/)
  end

  it "does not provide MIR allocation whitelist APIs" do
    forbidden = /
      top_level_alloc_exprs|
      allow_top
    /x

    offenders = Dir[File.join(ARCH_ROOT, "src/mir/**/*.rb")].sort.flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      source_lines(rel).filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.match?(forbidden)
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "MIRChecker must verify explicit ownership positions; MIR nodes must not expose " \
      "allocation whitelist APIs that let untracked allocations bypass verification:\n" \
      "#{offenders.join("\n")}"
  end

  it "does not infer ownership transfers by walking arbitrary MIR subtrees" do
    forbidden_defs = %w[
      collect_mir_consumed_roots
      ownership_transfers_for_mir
    ]

    offenders = Dir[File.join(ARCH_ROOT, "src/mir/**/*.rb")].sort.flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      source_lines(rel).filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless forbidden_defs.any? { |name| line.match?(/\bdef\s+#{Regexp.escape(name)}\b/) }
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "MIR ownership transfer facts must be emitted at the consuming edge, not inferred later by MIR walkers:\n" \
      "#{offenders.join("\n")}"
  end

  it "does not derive ownership-consuming operands from structural MIR/name traversal" do
    structural_extractors = /
      mir_ident_names|
      ownership_source_exprs|
      child_exprs|
      each_node|
      each_surface_node|
      surface_nodes|
      collect_mir_|
      walk_expr
    /x

    offenders = ownership_lowering_files.flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      source_lines(rel).filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless ownership_context?(line)
        next unless line.match?(structural_extractors)
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "Ownership-consuming operands must be produced as explicit facts at the consuming edge; " \
      "structural MIR/name traversal cannot be ownership authority:\n#{offenders.join("\n")}"
  end

  it "does not use owner-name arrays as the ownership consumption protocol" do
    offenders = ownership_lowering_files.flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      source_lines(rel).filter_map do |line, idx|
        next if line.strip.start_with?("#")
        direct_names_protocol =
          line.match?(/\bwith_ownership_consumption\([^,\n]+,\s*(?:mir_ident_names|\w+_names|\w*consumed\w*)/) ||
          line.match?(/OwnershipContract\.consumes\((?:\[[^\]]*\]|\w*names|\w*consum)/) ||
          line.match?(/ownership_consumption\s*=\s*MIR::OwnershipConsumptionFact\.new\([^)]*names:/)
        next unless direct_names_protocol

        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "Ownership consumption must be an operand-fact protocol, not a list of inferred owner names:\n" \
      "#{offenders.join("\n")}"
  end

  it "does not emit transfer/move markers outside the fact-to-marker boundary" do
    allowed = [
      %r{\Asrc/mir/mir\.rb\z},
    ]

    offenders = ownership_lowering_files.flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      next [] if allowed.any? { |pattern| pattern.match?(rel) }

      source_lines(rel).filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.match?(/MIR::(?:TransferMark|MoveMark)\.new|MIR\.ownership_transfer_marks/)
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "TransferMark/MoveMark must be emitted only by the typed ownership-fact finalizer, " \
      "not by local lowering paths:\n#{offenders.join("\n")}"
  end

  it "does not use mir_ident_names as an ownership-consumption source" do
    ownership_context = /
      with_ownership_consumption|
      ownership_transfer|
      TransferMark|
      collect_mir_consumed_roots|
      consumed|
      consumes
    /x

    offenders = Dir[File.join(ARCH_ROOT, "src/**/*.rb")].sort.flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      source_lines(rel).filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.include?("mir_ident_names")
        next unless line.match?(ownership_context)
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "mir_ident_names is structural inspection; it must not decide ownership consumption/transfer:\n" \
      "#{offenders.join("\n")}"
  end

  it "does not synthesize transfer marks from AllocMark/name visibility fallbacks" do
    forbidden = [
      "visible_alloc_names",
      "current_binding_alloc_for_name",
      "alloc_mark_for_consumed_name",
      "transfer_target_alloc_for_consumed_name",
      "ensure_transfer_cleanup_guard_for_name!",
    ]

    offenders = ["src/mir/mir_lowering.rb", "src/mir/hoist.rb"].flat_map do |rel|
      source_lines(rel).filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless forbidden.any? { |term| line.include?(term) }
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "Ownership transfer validity must come from explicit operand facts, not name visibility / allocator fallback state:\n" \
      "#{offenders.join("\n")}"
  end

  it "requires ownership consumption facts to carry explicit operand provenance" do
    mir = source("src/mir/mir.rb")
    expect(mir).to include("class OwnershipOperandFact")
    expect(mir).to include("const :kind, Symbol")
    expect(mir).to include("const :name, T.nilable(String)")
    expect(mir).to include("const :borrowed, T::Boolean")
    expect(mir).to include("const :type_info, Type")
    expect(mir).to include("const :operands, T::Array[OwnershipOperandFact]")
    expect(mir).not_to include("const :names, T::Array[String]")
  end

  it "requires MIRChecker to reject missing or borrowed ownership operands" do
    checker = source("src/mir/mir_checker.rb")
    expect(checker).to include("OWNERSHIP_CONSUMPTION_FACT_MISSING")
    expect(checker).to include("OWNERSHIP_CONSUMPTION_OPERAND_MISSING")
    expect(checker).to include("OWNERSHIP_CONSUMPTION_BORROWED_OPERAND")
    expect(checker).to include("verify_ownership_consumption_operands!")
    expect(checker).not_to match(/fact\.names|ownership_contract\.consumes\.each/)
    expect(checker).not_to include("contract.operands.empty? && contract.covers_consuming_params")
  end

  it "does not exempt specific owned result classes from consuming-sink err cleanup" do
    offenders = source("src/mir/hoist.rb").lines.each_with_index.filter_map do |line, idx|
      next unless line.include?("effective_err_cleanup")
      next unless line.match?(/RcDowngrade|RcRetain|WeakUpgrade|expr\.is_a\?/)

      "src/mir/hoist.rb:#{idx + 1}: #{line.strip}"
    end

    expect(offenders).to be_empty,
      "consuming-sink err cleanup must be uniform for every owned result class:\n#{offenders.join("\n")}"
  end

  it "has negative coverage for borrowed access paths into every owned sink family" do
    fuzz = source("tools/fuzz/templates/owned_sink_destination_matrix.rb")
    expect(fuzz).to include("field_borrow")
    expect(fuzz).to include("index_borrow")
    expect(fuzz).to include("expected = %i[field_borrow index_borrow].include?(source) && sink == :takes_arg ? :compile_error : :pass")
    expect(fuzz).to include("expected = :compile_error if source == :index_borrow && sink == :struct_field")
  end
end

RSpec.describe "architecture invariants: post-annotation type access" do
  def source(rel)
    File.read(File.join(ARCH_ROOT, rel))
  end

  TYPE_CONTRACT_BURNDOWN_FILES = [
    "src/annotator/annotator.rb",
    "src/annotator/helpers/function_analysis.rb",
    "src/annotator/helpers/generic_analysis.rb",
    "src/annotator/helpers/pipe_analysis.rb",
    "src/mir/lower/pipeline/pipeline_host.rb",
    "src/backends/pipeline_rewriter.rb",
    "src/semantic/escape_analysis.rb",
    "src/mir/lowering/expressions.rb",
    "src/mir/lowering/variables.rb",
  ].freeze

  TYPE_CONTRACT_SOURCE_DIRS = [
    "src/annotator",
    "src/backends",
    "src/mir",
    "src/semantic",
  ].freeze

  def scoped_source_files
    TYPE_CONTRACT_SOURCE_DIRS.flat_map do |dir|
      Dir[File.join(ARCH_ROOT, dir, "**/*.rb")]
    end.sort.map { |path| path.sub(ARCH_ROOT + "/", "") }
  end

  it "does not re-derive whether AST nodes have full_type in burned-down consumers" do
    offenders = scoped_source_files.flat_map do |rel|
      source(rel).lines.each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.include?("respond_to?(:full_type)") || line.include?('respond_to?("full_type")')
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "post-annotation consumers must use Locatable#full_type!, not defensive full_type probes:\n" \
      "#{offenders.join("\n")}"
  end

  it "does not keep legacy full_type_or readers in scoped compiler code" do
    offenders = scoped_source_files.flat_map do |rel|
      source(rel).lines.each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.include?("full_type_or")
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "scoped compiler code must use Locatable#full_type! rather than full_type_or:\n" \
      "#{offenders.join("\n")}"
  end

  it "does not treat full_type as optional in scoped compiler code" do
    offenders = scoped_source_files.flat_map do |rel|
      source(rel).lines.each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.include?("full_type")
        optional_predicate =
          line.match?(/\b(?:return\s+)?(?:if|unless)\s+[^#\n]*\.full_type\s*(?:#.*)?$/) ||
          line.match?(/\.full_type&\./) ||
          line.match?(/&\.full_type(?![!\w])/)
        next unless optional_predicate
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "full_type is a fail-closed annotation fact, not an optional predicate:\n" \
      "#{offenders.join("\n")}"
  end

  it "does not use optional Type.from_node on post-annotation AST values in burned-down consumers" do
    offenders = scoped_source_files.flat_map do |rel|
      source(rel).lines.each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.match?(/Type\.from_node\((?![^\)]*,\s*context:)/)
        # Raw metadata is not an annotated AST value; it may still be
        # normalized optionally because absence has semantic meaning there.
        next if line.match?(/\b(?:variant_data|return_type|expected_type|current_expected_type|current_fn_return_type|type_info)\b/)
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "post-annotation AST values must use Locatable#full_type! or Type.from_node!, not optional Type.from_node:\n" \
      "#{offenders.join("\n")}"
  end

  it "keeps required AST type access as a hard contract" do
    ast = source("src/ast/ast.rb")
    expect(ast).to include("def full_type!(context: \"post-annotation AST\")")
    expect(ast).to include('raise "#{context}: unresolved type info')
    expect(source("src/mir/pre_mir_type_check.rb")).to include("full_type is the :Untyped")
  end

  it "keeps AST full_type writes inside annotation and synthetic-node producer boundaries" do
    allowed = [
      %r{\Asrc/ast/ast\.rb\z},
      %r{\Asrc/ast/parser\.rb\z},
      %r{\Asrc/annotator/},
      %r{\Asrc/mir/lower/pipeline/pipeline_context\.rb\z},
      %r{\Asrc/mir/lower/pipeline/pipeline_host\.rb\z},
      %r{\Asrc/backends/pipeline_rewriter\.rb\z},
      %r{\Asrc/backends/string_concat_rewriter\.rb\z},
      %r{\Asrc/mir/hoist\.rb\z},
      %r{\Asrc/mir/mir_pass\.rb\z},
      %r{\Asrc/mir/pre_mir_type_check\.rb\z},
      %r{\Asrc/mir/mir_lowering\.rb\z},
      %r{\Asrc/mir/lowering/},
      %r{\Asrc/mir/fsm_transform/segments\.rb\z},
    ]

    offenders = scoped_source_files.flat_map do |rel|
      next [] if allowed.any? { |pattern| pattern.match?(rel) }

      source(rel).lines.each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.match?(/\.full_type\s*=(?![=~])/)
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "AST full_type writes must stay in annotation or synthetic-node producer boundaries:\n" \
      "#{offenders.join("\n")}"
  end

  it "routes annotator full_type writes through the typed stamp helper" do
    offenders = Dir[File.join(ARCH_ROOT, "src/annotator/**/*.rb")].sort.flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      source(rel).lines.each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.match?(/\.full_type\s*=(?![=~])/)
        next if rel == "src/annotator/annotator.rb" && line.include?("node.full_type = T.cast(value, AST::SyntheticTypeInput)")
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "annotator type producers must call SemanticAnnotator#stamp_type!, not write .full_type directly:\n" \
      "#{offenders.join("\n")}"
  end

  it "keeps the annotator stamp boundary typed and fail-closed" do
    annotator = source("src/annotator/annotator.rb")
    expect(annotator).to include("def stamp_type!(node, value)")
    expect(annotator).to include("type_parameters(:Stamp)")
    expect(annotator).to include("value: T.type_parameter(:Stamp)")
    expect(annotator).to include("raise \"annotation stamp missing type")
    expect(annotator).to include("node.full_type = T.cast(value, AST::SyntheticTypeInput)")
    expect(annotator).to include('node.full_type!(context: "annotation stamp")')
    expect(annotator).to include("stamped.untyped?")
    expect(annotator).to include('raise "annotation stamp produced :Untyped')
  end

  it "keeps MIR/backend synthetic AST type writes behind one fail-closed helper" do
    offenders = (Dir[File.join(ARCH_ROOT, "src/mir/**/*.rb")] +
                 Dir[File.join(ARCH_ROOT, "src/backends/**/*.rb")]).sort.flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      File.readlines(path).each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.match?(/\.full_type\s*=/)
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "Synthetic AST nodes in MIR/backend code must use AST.stamp_synthetic_type!, not raw full_type=:\n" \
      "#{offenders.join("\n")}"
  end

  it "keeps the synthetic AST type stamp boundary typed and fail-closed" do
    ast = source("src/ast/ast.rb")
    expect(ast).to include("SyntheticTypeInput =")
    expect(ast).to include("def self.stamp_synthetic_type!(node, value, context:)")
    expect(ast).to include("node.full_type = value")
    expect(ast).to include("node.full_type!(context: context)")
    expect(ast).to include("stamped.untyped?")
  end

  it "uses hard AST type reads in annotator consumers" do
    offenders = Dir[File.join(ARCH_ROOT, "src/annotator/**/*.rb")].sort.flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      File.readlines(path).each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.match?(/\.full_type(?![!\w])/)
        # Annotation producers are the sanctioned place where AST nodes are
        # stamped or copied after the visitor has computed the authoritative type.
        if line.match?(/\.full_type\s*=/)
          rhs = line.split(/\.full_type\s*=/, 2).last || ""
          next unless rhs.match?(/\.full_type(?![!\w])/)
        end
        # OwnershipGraph::Node exposes its stored Type payload through
        # #full_type; this is not an AST annotation read.
        next if rel == "src/annotator/helpers/fixable_helpers.rb" && line.include?("og_node.full_type")
        # FunctionSignature.from_function_def is a raw signature producer. It
        # can be called before a FunctionDef has been annotation-stamped.
        next if rel == "src/annotator/helpers/function_signature.rb" && line.include?("fn.full_type")
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "Annotator consumers must use Locatable#full_type!; plain .full_type is only for producer writes or typed payloads:\n" \
      "#{offenders.join("\n")}"
  end

  it "does not use optional Type.from_node on MIR AST consumers" do
    allowed_raw_metadata = [
      /current_expected_type/,
      /current_fn_return_type/,
      /return_type/,
      /expected_type/,
      /variant_data/,
      /\btype_info\b/,
    ]
    offenders = Dir[File.join(ARCH_ROOT, "src/mir/**/*.rb")].sort.flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      File.readlines(path).each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.include?("Type.from_node(")
        next if allowed_raw_metadata.any? { |pattern| line.match?(pattern) }
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "MIR AST consumers must use Type.from_node! / Locatable#full_type!; optional Type.from_node is only for raw type metadata:\n" \
      "#{offenders.join("\n")}"
  end

  it "uses hard AST type reads in MIR consumers" do
    offenders = Dir[File.join(ARCH_ROOT, "src/mir/**/*.rb")].sort.flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      File.readlines(path).each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.match?(/\.full_type(?![!\w])/)
        # Producer writes/copies are the sanctioned place for synthetic nodes
        # to receive already-authoritative annotation facts.
        next if line.match?(/\.full_type\s*=/)
        # PreMirTypeCheck is the boundary that rejects the :Untyped sentinel.
        next if rel == "src/mir/pre_mir_type_check.rb"
        # MIR AllocMark exposes a Type payload through #full_type; this is not
        # an AST annotation read and has no bang accessor.
        next if rel == "src/mir/mir_checker.rb" && line.include?("alloc_marks.first.full_type")
        # OwnershipGraph::Node exposes its stored Type payload through
        # #full_type; this is not an AST annotation read.
        next if rel == "src/semantic/ownership_graph.rb" && line.include?("source.full_type")
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "MIR AST consumers must use Locatable#full_type!; plain .full_type is only for producer writes or MIR Type payloads:\n" \
      "#{offenders.join("\n")}"
  end

  it "uses hard AST type reads in backend consumers" do
    offenders = Dir[File.join(ARCH_ROOT, "src/backends/**/*.rb")].sort.flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      File.readlines(path).each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.match?(/\.full_type(?![!\w])/)
        next if line.match?(/\.full_type\s*=/)
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "Backend AST consumers must use Locatable#full_type!; plain .full_type is only for producer writes:\n" \
      "#{offenders.join("\n")}"
  end

  it "does not treat full_type! itself as an optional condition in MIR/backend code" do
    offenders = (Dir[File.join(ARCH_ROOT, "src/mir/**/*.rb")] +
                 Dir[File.join(ARCH_ROOT, "src/backends/**/*.rb")]).sort.flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      File.readlines(path).each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.match?(/\b(?:if|unless)\s+[\w.]+\.full_type!\s*(?:#.*)?$/) ||
                    line.match?(/&&\s*[\w.]+\.full_type!\s*(?:#.*)?$/)
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "full_type! is a hard post-annotation contract, not a nilable predicate:\n" \
      "#{offenders.join("\n")}"
  end

  it "does not manufacture untyped MIR/backend ownership facts" do
    offenders = (Dir[File.join(ARCH_ROOT, "src/mir/**/*.rb")] +
                 Dir[File.join(ARCH_ROOT, "src/backends/**/*.rb")]).sort.flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      next [] if rel == "src/mir/pre_mir_type_check.rb"

      File.readlines(path).each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.include?("Type.new(:Untyped)")
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "Post-annotation MIR/backend facts must carry authoritative Type payloads, never :Untyped:\n" \
      "#{offenders.join("\n")}"
  end

  it "does not emit AllocMark without authoritative type info" do
    offenders = Dir[File.join(ARCH_ROOT, "src/mir/**/*.rb")].sort.flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      File.readlines(path).each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next if line.include?("mir_alloc_mark_type_info(")
        next unless line.match?(/MIR::AllocMark\.new\([^#\n]*,\s*nil[,\)]/)
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "MIR::AllocMark must carry concrete Type info; nil makes ownership verification coincidental:\n" \
      "#{offenders.join("\n")}"
  end

  it "does not keep the old MIR::Alloc allocation marker path" do
    offenders = (Dir[File.join(ARCH_ROOT, "src/**/*.rb")] -
                 [File.join(ARCH_ROOT, "src/mir/mir_emitter.rb")]).sort.flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      File.readlines(path).each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.match?(/\bMIR::Alloc\b/) || line.match?(/\bAlloc\s*=\s*Struct\.new\(:token,\s*:name,\s*:alloc\)/)
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "MIRPass must emit final MIR::AllocMark facts directly; old MIR::Alloc is a dual allocation path:\n" \
      "#{offenders.join("\n")}"
  end

  it "keeps AllocMark construction fail-closed on concrete Type" do
    mir = source("src/mir/mir.rb")
    expect(mir).to include("def initialize(name, alloc, type_info, scope = nil)")
    expect(mir).to include("type_info: Type")
    expect(mir).to include("raise \"MIR::AllocMark requires concrete Type info\" if type_info.untyped?")
  end

  it "keeps MIRChecker fail-closed on missing AllocMark type facts" do
    checker = source("src/mir/mir_checker.rb")
    expect(checker).to include("INV-ALLOC-MARK-TYPE")
    expect(checker).to include("verify_alloc_marks_typed!(allocs)")
    expect(checker).to include("def verify_alloc_marks_typed!(allocs)")
    expect(checker).to include("ALLOC_MARK_TYPE_MISSING")
    expect(checker).to include("mark.type_info.untyped?")
    expect(source("src/ast/diagnostic_registry.rb")).to include("ALLOC_MARK_TYPE_MISSING")
  end

  it "keeps Auto inference slot identity in typed objects, not tuple arrays" do
    expect(source("src/annotator/helpers/auto_inference.rb")).to include("class AutoSlotId")
    offenders = [
      "src/annotator/helpers/auto_inference.rb",
      "src/annotator/helpers/fixable_helpers.rb",
      "src/annotator/annotator.rb",
    ].flat_map do |rel|
      source(rel).lines.each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.match?(/\[:(?:param|return|local|list_element|map_key|map_value)\b/)
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "Auto inference slot identity must use AutoSlotId/typed shape objects, not tuple arrays:\n" \
      "#{offenders.join("\n")}"
  end

  it "keeps Auto inference facts in typed structs, not anonymous Struct bags" do
    auto = source("src/annotator/helpers/auto_inference.rb")
    expect(auto).to include("class Slot < T::Struct")
    expect(auto).to include("class Resolution < T::Struct")
    expect(auto).to include("class Ambiguity < T::Struct")
    expect(auto).to include("class Result < T::Struct")

    offenders = auto.lines.each_with_index.filter_map do |line, idx|
      next if line.strip.start_with?("#")
      next unless line.match?(/\b(?:Slot|Result|Resolution|Ambiguity)\s*=\s*Struct\.new/)
      "src/annotator/helpers/auto_inference.rb:#{idx + 1}: #{line.strip}"
    end

    expect(offenders).to be_empty,
      "Auto inference protocol facts must be explicit T::Struct classes:\n" \
      "#{offenders.join("\n")}"
  end
end

RSpec.describe "architecture invariants: closed placement pipeline" do
  ForbiddenPattern = Struct.new(:name, :glob, :pattern, :allowed, keyword_init: true)

  FORBIDDEN = [
    ForbiddenPattern.new(
      name: "return/heap provenance as placement data",
      glob: "src/**/*.rb",
      pattern: /\b(?:return_provenance|heap_provenance)\b/,
      allowed: [
        %r{\Asrc/mir/mir_checker\.rb\z},
        %r{\Asrc/mir/mir\.rb\z},
        %r{\Asrc/ast/diagnostic_registry\.rb\z},
      ],
    ),
    ForbiddenPattern.new(
      name: "lowering-side heap/frame inference helpers",
      glob: "src/mir/{mir_lowering.rb,lowering/**/*.rb,hoist.rb,cleanup_classifier.rb}",
      pattern: /\b(?:node_is_heap\?|heap_owned_value\?|takes_arg_alloc|receiver_root_heap\?|storage_to_alloc|authoritative_storage|call_return_provenance|return_expr_provenance)\b/,
      allowed: [],
    ),
    ForbiddenPattern.new(
      name: "recursive cleanup shape used as allocator input downstream",
      glob: "src/mir/{mir_lowering.rb,lowering/**/*.rb,hoist.rb}",
      pattern: /\b(?:recursive_cleanup_shape\?|type_shape_needs_recursive_cleanup\?)\b/,
      allowed: [],
    ),
    ForbiddenPattern.new(
      name: "lowering/hoist context allocator state",
      glob: "src/mir/{mir_lowering.rb,lowering/**/*.rb,hoist.rb}",
      pattern: /@(?:decl_alloc|current_fn_return_alloc)\b/,
      allowed: [],
    ),
    ForbiddenPattern.new(
      name: "node storage used as downstream allocator authority",
      glob: "src/mir/{mir_lowering.rb,lowering/**/*.rb,hoist.rb,cleanup_classifier.rb}",
      pattern: /\bnode\.storage\s*(?:==|=~|!=|=)\s*:heap\b/,
      allowed: [],
    ),
    ForbiddenPattern.new(
      name: "inactive escape fuzz cells",
      glob: "tools/fuzz/templates/**/*.rb",
      pattern: /(?:expected\s*[:=]|\?\s*)\s*:in_dev\b/,
      allowed: [],
    ),
    ForbiddenPattern.new(
      name: "source-specific call metadata in escape analysis",
      glob: "src/semantic/escape_analysis.rb",
      pattern: /\bmatched_stdlib_def\b/,
      allowed: [],
    ),
    ForbiddenPattern.new(
      name: "loop-analysis special escape flags",
      glob: "src/**/*.rb",
      pattern: /\b(?:frame_alloc_escapes|stores_into_nonlocal_collection)\b/,
      allowed: [],
    ),
    ForbiddenPattern.new(
      name: "loop rewind decisions from collection mutator names",
      glob: "src/mir/{control_flow.rb,mir_checker.rb}",
      pattern: /\b(?:append|insert|push|put|ELEMENT_STORE)\b/,
      allowed: [],
    ),
    ForbiddenPattern.new(
      name: "loop rewind decisions from collection shape",
      glob: "src/mir/{control_flow.rb,mir_checker.rb}",
      pattern: /\b(?:collection\?|collection_value\?|list_collection\?|set_collection\?|pool\?|map\?|array\?)\b/,
      allowed: [],
    ),
    ForbiddenPattern.new(
      name: "defensive nil-array fallbacks in placement helpers",
      glob: "src/mir/{cleanup_classifier.rb,hoist.rb}",
      pattern: /\|\|\s*\[\]|\b&&\s*\w+\.any\?|\w+&\.any\?/,
      allowed: [],
    ),
    ForbiddenPattern.new(
      name: "pass-local MIR traversal helpers",
      glob: "src/mir/{mir_lowering.rb,lowering/**/*.rb}",
      pattern: /\bdef\s+(?:walk_mir_node|each_mir_surface_node|collect_ownership_surface_nodes|ownership_surface_nodes)\b/,
      allowed: [],
    ),
    ForbiddenPattern.new(
      name: "structural allocator metadata hash protocol",
      glob: "src/**/*.rb",
      pattern: /(?<!resolved_)allocs\.is_a\?\(Hash\)|\.allocs\.values|\.allocs\.key\?\(|\.allocs\[:|\.allocs\.transform_values|resolved_allocs\.is_a\?\(Hash\)|resolved_allocs\[:/,
      allowed: [],
    ),
  ].freeze

  def scan_for(pattern)
    files = Dir[File.join(ARCH_ROOT, pattern.glob)].uniq.sort
    files.each_with_object([]) do |path, hits|
      rel = path.sub(ARCH_ROOT + "/", "")
      next if pattern.allowed.any? { |allowed| allowed.match?(rel) }

      File.readlines(path).each_with_index do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.match?(pattern.pattern)

        hits << "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end
  end

  FORBIDDEN.each do |pattern|
    it "forbids #{pattern.name}" do
      hits = scan_for(pattern)
      expect(hits).to be_empty,
        "#{hits.size} forbidden #{pattern.name} hit(s):\n#{hits.join("\n")}"
    end
  end

  it "keeps VarDecl allocator placement behind the typed placement fact" do
    source = File.read(File.join(ARCH_ROOT, "src/mir/lowering/variables.rb"))
    expect(source).to include("def binding_placement_fact")
    expect(source).to include("placement = binding_placement_fact")
    expect(source).to include("base_decl_alloc = placement.alloc")
    expect(source).not_to include("base_decl_alloc = if")
  end

  it "routes production ownership transfer marks through the typed transfer plan" do
    offenders = (Dir[File.join(ARCH_ROOT, "src/mir/**/*.rb")] +
                 [File.join(ARCH_ROOT, "src/mir/lower/pipeline/pipeline_host.rb"),
                  File.join(ARCH_ROOT, "src/mir/lower/pipeline/pipeline_materializer.rb")]).sort.flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      next [] if rel == "src/mir/mir.rb"

      File.readlines(path).each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.include?("MIR::TransferMark.new")

        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "Ownership transfers must be emitted through MIR.ownership_transfer_marks / OwnershipTransferPlan:\n" \
      "#{offenders.join("\n")}"
  end

  it "routes function return transfers through ReturnOwnershipPlan" do
    source = File.read(File.join(ARCH_ROOT, "src/mir/lowering/control_flow.rb"))
    expect(source).to include("class ReturnOwnershipPlan < T::Struct")
    expect(source).to include("def return_lowering_plan")
    expect(source).to include("def return_with_transfer_marks")
    expect(source).to include("def synthetic_return_ownership_plan")

    expect(source).to include("MIR::OwnershipTransferPlan.new")
    expect(source).to include("target: :return")
    expect(source).not_to include("MIR.ownership_transfer_marks(name, :return")
  end

  it "keeps owned-sink source shape behind one typed source fact" do
    source = File.read(File.join(ARCH_ROOT, "src/mir/mir_lowering.rb"))
    expect(source).to include("class OwnedSinkSourceFact < T::Struct")
    expect(source).to include("def owned_sink_source_fact")
    expect(source).to include("source.satisfies_sink?")
    expect(source).not_to include("def owned_sink_source_satisfies?")
    expect(source).not_to include("def verifiable_owned_source?")
    expect(source).not_to include("def ownership_transfer_source?")
    expect(source).not_to include("def borrowed_union_sink_value?")
  end

  it "fences FSM/thunk memory-safety emission behind typed facts" do
    fsm = File.read(File.join(ARCH_ROOT, "src/mir/fsm_lowering.rb"))
    mir = File.read(File.join(ARCH_ROOT, "src/mir/mir.rb"))
    expect(mir).to include("class FsmResultTransferFact < T::Struct")
    expect(fsm).to include("def fsm_result_transfer_facts")

    offenders = (Dir[File.join(ARCH_ROOT, "src/mir/fsm_transform/**/*.rb")] +
                 Dir[File.join(ARCH_ROOT, "src/mir/thunk_transform/**/*.rb")] +
                 [File.join(ARCH_ROOT, "src/mir/fsm_ops.rb")]).sort.flat_map do |path|
      rel = path.sub(ARCH_ROOT + "/", "")
      File.readlines(path).each_with_index.filter_map do |line, idx|
        next if line.strip.start_with?("#")
        next unless line.match?(/MIR::(?:AllocMark|Cleanup|ErrCleanup|TransferMark|MoveMark)\.new|MIR\.ownership_transfer_marks/)
        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty,
      "FSM/thunk transforms must produce typed facts or structural MIR, not direct ownership markers:\n" \
      "#{offenders.join("\n")}"
  end
end
